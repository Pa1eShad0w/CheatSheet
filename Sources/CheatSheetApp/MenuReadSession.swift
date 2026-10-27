import CheatSheetCore
import Foundation
import OSLog

/// Presentation can detach while one bounded read warms an in-memory, context-scoped snapshot.
/// The caller must invalidate on real input, focus, application, or permission changes.
@MainActor
final class MenuReadSession {
    typealias Read = @Sendable (Int32, String) async throws -> MenuSnapshot
    typealias Progress = @Sendable (MenuSnapshot) -> Void
    typealias ProgressRead = @Sendable (Int32, String, @escaping Progress) async throws -> MenuSnapshot

    private struct Key: Equatable {
        let processIdentifier: Int32
        let contextID: UInt64
    }

    private struct CachedSnapshot {
        let snapshot: MenuSnapshot
        let expiresAt: ContinuousClock.Instant
    }

    private enum ReadEvent: Sendable {
        case attempt(UUID)
        case progress(UUID, MenuSnapshot)
        case retry
        case success(MenuSnapshot)
        case failure(MenuReaderError)
        case cancelled
    }

    private let read: ProgressRead
    private let grace: Duration
    private let cacheLifetime: Duration
    private let retryDelay: Duration
    private let maximumReadDuration: Duration
    private let logger = Logger(subsystem: "local.cheatsheet.modern", category: "MenuReading")
    private var key: Key?
    private var attached = false
    private var task: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cacheExpiryTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeAttempt: UUID?
    private var startedAt: ContinuousClock.Instant?
    private var latestProgress: MenuSnapshot?
    private var cached: CachedSnapshot?
    private(set) var result: Result<MenuSnapshot, MenuReaderError>?
    /// Warm and progressive results are provisional until background revalidation finishes.
    private(set) var isRefreshing = false
    /// Called for attached warm results, progress, and completion, not just once per read.
    var onCompletion: (() -> Void)?

    // Preserve the original two-argument injectable reader.
    convenience init(
        grace: Duration = .milliseconds(80),
        read: @escaping Read
    ) {
        self.init(grace: grace, progressRead: { pid, name, _ in try await read(pid, name) })
    }

    init(
        grace: Duration = .milliseconds(80),
        cacheLifetime: Duration = .seconds(3),
        retryDelay: Duration = .milliseconds(100),
        maximumReadDuration: Duration = .seconds(7),
        progressRead: @escaping ProgressRead = { pid, name, progress in
            let worker = Task.detached(priority: .userInitiated) {
                try MenuReader().read(processIdentifier: pid, applicationName: name, onProgress: progress)
            }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    ) {
        self.grace = grace
        self.cacheLifetime = cacheLifetime
        self.retryDelay = retryDelay
        self.maximumReadDuration = maximumReadDuration
        self.read = progressRead
    }

    func begin(processIdentifier: Int32, applicationName: String, contextID: UInt64 = 0) {
        let nextKey = Key(processIdentifier: processIdentifier, contextID: contextID)
        if key != nextKey {
            invalidate()
            key = nextKey
        }
        attached = true
        result = nil
        if task == nil {
            start(processIdentifier: processIdentifier, applicationName: applicationName)
        }
        isRefreshing = true
        if let snapshot = latestProgress ?? warmSnapshot() {
            // The existing overlay already uses truncation to disclose provisional content.
            result = .success(partial(snapshot))
            onCompletion?()
        }
    }

    /// Command release detaches presentation, but does not throw away an already-started read.
    func cancel() {
        attached = false
        result = nil
        isRefreshing = false
        // Normal Command chords still avoid any AX work during the grace period.
        if startedAt == nil { stopWork() }
    }

    /// A context change must also cancel detached work and discard all reusable content.
    func invalidate() {
        attached = false
        result = nil
        isRefreshing = false
        stopWork()
        key = nil
        clearCache()
    }

    private func start(processIdentifier: Int32, applicationName: String) {
        let generation = generation
        let read = read
        let grace = grace
        let retryDelay = retryDelay
        let events = AsyncStream<ReadEvent>.makeStream()
        // FIFO delivery keeps progress before terminal events, even for a synchronous reader.
        deliveryTask = Task { [weak self] in
            for await event in events.stream {
                guard let self, self.generation == generation else { return }
                self.receive(event)
            }
        }
        task = Task { [weak self] in
            defer { events.continuation.finish() }
            do {
                try await Task.sleep(for: grace)
                try Task.checkCancellation()
                guard self?.generation == generation else { return }
                self?.didStart(generation: generation)
                for attempt in 0..<2 {
                    try Task.checkCancellation()
                    let attemptID = UUID()
                    events.continuation.yield(.attempt(attemptID))
                    do {
                        let snapshot = try await read(processIdentifier, applicationName) { snapshot in
                            events.continuation.yield(.progress(attemptID, snapshot))
                        }
                        try Task.checkCancellation()
                        events.continuation.yield(.success(snapshot))
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MenuReaderError {
                        try Task.checkCancellation()
                        if case .menuUnavailable = error, attempt == 0 {
                            events.continuation.yield(.retry)
                            try await Task.sleep(for: retryDelay)
                        } else {
                            events.continuation.yield(.failure(error))
                            return
                        }
                    }
                }
            } catch is CancellationError {
                events.continuation.yield(.cancelled)
            } catch {
                if !Task.isCancelled { events.continuation.yield(.failure(.menuUnavailable)) }
            }
        }
    }

    private func didStart(generation: UUID) {
        startedAt = .now
        let maximumReadDuration = maximumReadDuration
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: maximumReadDuration)
                guard let self, self.generation == generation else { return }
                self.receive(.failure(.menuUnavailable))
            } catch {
                // Cancellation of the deadline is normal completion/invalidation.
            }
        }
    }

    private func receive(_ event: ReadEvent) {
        switch event {
        case .attempt(let attempt):
            activeAttempt = attempt
        case .progress(let attempt, let snapshot):
            guard activeAttempt == attempt, hasShortcuts(snapshot) else { return }
            latestProgress = partial(snapshot)
            if attached {
                result = .success(partial(snapshot))
                onCompletion?()
            }
        case .retry:
            // Ignore late callbacks from the failed attempt while waiting to retry.
            activeAttempt = nil
            log("retry", snapshot: latestProgress)
        case .success(let snapshot):
            let snapshot = !hasShortcuts(snapshot) ? latestProgress ?? snapshot : snapshot
            log("success", snapshot: snapshot)
            stopWork()
            if hasShortcuts(snapshot) {
                storeCache(snapshot)
            } else {
                clearCache()
            }
            if attached {
                isRefreshing = false
                result = .success(snapshot)
                onCompletion?()
            }
        case .failure(let error):
            let fallback: MenuSnapshot?
            if case .menuUnavailable = error {
                fallback = latestProgress ?? warmSnapshot()
            } else {
                fallback = nil
                clearCache()
            }
            log("failure", snapshot: fallback, error: error)
            stopWork()
            if attached {
                isRefreshing = false
                result = fallback.map { .success(partial($0)) } ?? .failure(error)
                onCompletion?()
            }
        case .cancelled:
            stopWork()
            isRefreshing = false
        }
    }

    private func stopWork() {
        // Rotate ownership before cancellation: an uncooperative old reader cannot publish or cache.
        generation = UUID()
        task?.cancel()
        deliveryTask?.cancel()
        timeoutTask?.cancel()
        task = nil
        deliveryTask = nil
        timeoutTask = nil
        activeAttempt = nil
        startedAt = nil
        latestProgress = nil
    }

    private func storeCache(_ snapshot: MenuSnapshot) {
        clearCache()
        let expiresAt = ContinuousClock.now.advanced(by: cacheLifetime)
        cached = CachedSnapshot(snapshot: snapshot, expiresAt: expiresAt)
        cacheExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(until: expiresAt, clock: .continuous)
                guard let self, self.cached?.expiresAt == expiresAt else { return }
                self.clearCache()
            } catch {
                // Replacement and invalidation cancel the old expiration timer.
            }
        }
    }

    private func clearCache() {
        cached = nil
        cacheExpiryTask?.cancel()
        cacheExpiryTask = nil
    }

    private func warmSnapshot() -> MenuSnapshot? {
        guard let cached else { return nil }
        guard ContinuousClock.now < cached.expiresAt else {
            clearCache()
            return nil
        }
        return cached.snapshot
    }

    private func hasShortcuts(_ snapshot: MenuSnapshot) -> Bool {
        snapshot.sections.contains { !$0.shortcuts.isEmpty }
    }

    private func partial(_ snapshot: MenuSnapshot) -> MenuSnapshot {
        MenuSnapshot(
            applicationName: snapshot.applicationName, processIdentifier: snapshot.processIdentifier,
            sections: snapshot.sections, isTruncated: true
        )
    }

    private func log(_ outcome: String, snapshot: MenuSnapshot?, error: MenuReaderError? = nil) {
        let elapsed = (startedAt ?? .now).duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let count = snapshot?.sections.reduce(0) { $0 + $1.shortcuts.count } ?? 0
        // Fixed categories and performance metadata only; never app/menu/input strings.
        if let error {
            let category: String
            switch error {
            case .permissionRequired: category = "permission-required"
            case .applicationUnavailable: category = "application-unavailable"
            case .menuUnavailable: category = "menu-unavailable"
            }
            logger.error(
                "Menu read failed (\(category, privacy: .public)): \(milliseconds) ms, \(count) shortcuts retained")
        } else {
            logger.debug("Menu read \(outcome, privacy: .public): \(milliseconds) ms, \(count) shortcuts")
        }
    }
}
