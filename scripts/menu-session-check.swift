import CheatSheetCore
import Darwin
import Foundation

@main
private enum MenuSessionCheck {
    @MainActor
    static func main() async {
        do {
            try await repeatedGesture()
            try await detachedCompletion()
            try await contextIsolation()
            try await cacheExpiryAndEmptyResults()
            try await transientRetry()
            try await warmRevalidationFailure()
            try await invalidateDuringRetry()
            try await fatalErrorsAndCancellation()
            try await progressiveRead()
            try await partialFailure()
            try await synchronousProgress()
            try await invalidation()
            try await boundedWork()
            try await normalChordGrace()
            print(
                "Menu session checks passed: reuse, warm revalidation, context/TTL isolation, progress, retry, fatal errors, detach, invalidation, deadlines, and grace."
            )
        } catch {
            print("Menu session check FAILED: \(error)")
            exit(1)
        }
    }

    @MainActor
    private static func repeatedGesture() async throws {
        let source = ControlledRead()
        // Keep exercising the original fake two-argument initializer.
        let session = MenuReadSession(grace: .zero) { pid, _ in try await source.read(pid) }
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        for _ in 0..<3 {
            session.cancel()
            try require(session.result == nil, "Release must clear presentation immediately")
            session.begin(processIdentifier: 1, applicationName: "Fixture")
        }
        await settle()
        let starts = await source.startCount
        try require(starts == 1, "Unchanged-context re-hold must reuse the ongoing read, not start over")
        await source.finish(1, snapshot: fixture("first"))
        try await until("Reattached ongoing read must publish") { title(session) == "first" }
        try require(publications == 1 && !session.isRefreshing, "Completion must publish exactly once")

        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(title(session) == "first", "A recent successful snapshot must publish immediately")
        try require(
            snapshot(session)?.isTruncated == true && session.isRefreshing,
            "Warm content must disclose provisional state during revalidation")
        try await source.waitForStart(2)
        await source.finish(2, snapshot: fixture("revalidated"))
        try await until("Warm content must be replaced by a fresh read") { title(session) == "revalidated" }
        try require(
            publications == 3 && snapshot(session)?.isTruncated == false && !session.isRefreshing,
            "Revalidation must publish final freshness, not silently keep the cache")
        session.invalidate()
    }

    @MainActor
    private static func detachedCompletion() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        session.cancel()
        await source.progress(1, snapshot: fixture("detached progress"))
        await source.finish(1, snapshot: fixture("warmed while detached"))
        await settle()
        try require(session.result == nil && publications == 0, "Detached work must never publish into UI")
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(title(session) == "warmed while detached", "Detached completion should warm the next gesture")
        try await source.waitForStart(2)
        await source.finish(2, snapshot: fixture("fresh"))
        try await until("Revalidation after detached completion must finish") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func contextIsolation() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        session.begin(processIdentifier: 1, applicationName: "Fixture", contextID: 1)
        try await source.waitForStart(1)
        session.begin(processIdentifier: 1, applicationName: "Fixture", contextID: 2)
        try await source.waitForStart(2)
        await source.progress(1, snapshot: fixture("old progress"))
        await source.finish(1, snapshot: fixture("old final"))
        await settle()
        try require(session.result == nil, "Old same-PID context must not publish progress or completion")
        await source.finish(2, snapshot: fixture("context two"))
        try await until("New context must publish") { title(session) == "context two" }
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture", contextID: 3)
        try require(session.result == nil, "A new context must exclude the previous warm snapshot")
        try await source.waitForStart(3)
        await source.finish(3, snapshot: fixture("context three"))
        try await until("Third context must complete") { !session.isRefreshing }
        session.begin(processIdentifier: 2, applicationName: "Other", contextID: 3)
        try require(session.result == nil, "A different PID must not reuse a context's snapshot")
        try await source.waitForStart(4)
        await source.finish(4, snapshot: fixture("other", pid: 2))
        try await until("Other PID must complete") { !session.isRefreshing }
        session.begin(processIdentifier: 1, applicationName: "Fixture", contextID: 3)
        try require(session.result == nil, "The single-entry cache must not retain older PID/context snapshots")
        try await source.waitForStart(5)
        await source.finish(5, snapshot: fixture("back"))
        try await until("Returning PID must complete") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func cacheExpiryAndEmptyResults() async throws {
        let source = ControlledRead()
        let session = MenuReadSession(grace: .zero, cacheLifetime: .milliseconds(30), progressRead: source.reader)
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.finish(1, snapshot: fixture("expires"))
        try await until("Initial cache fixture must finish") { !session.isRefreshing }
        session.cancel()
        try await Task.sleep(for: .milliseconds(50))
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Expired snapshots must not publish")
        try await source.waitForStart(2)
        let empty = MenuSnapshot(applicationName: "Fixture", processIdentifier: 1, sections: [], isTruncated: false)
        await source.finish(2, snapshot: empty)
        try await until("Empty final result must complete normally") { !session.isRefreshing }
        try require(snapshot(session) == empty, "An attached empty final snapshot is still a result")
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Empty success must never warm the cache")
        try await source.waitForStart(3)
        await source.finish(3, snapshot: fixture("fresh"))
        try await until("Fresh fixture must finish") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func transientRetry() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        let failedAt = ContinuousClock.now
        await source.fail(1, error: MenuReaderError.menuUnavailable)
        try await source.waitForStart(2)
        try require(failedAt.duration(to: .now) >= .milliseconds(80), "Transient retry should wait about 100ms")
        try require(session.result == nil && publications == 0, "First transient failure must not flash an error")
        await source.fail(2, error: MenuReaderError.menuUnavailable)
        try await until("Second transient failure must finish") { !session.isRefreshing }
        try require(
            isFailure(session, .menuUnavailable) && publications == 1, "Retry exhaustion must publish one failure")
        await settle()
        let starts = await source.startCount
        try require(starts == 2, "Transient errors get only one retry")
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Failures must not be cached")
        try await source.waitForStart(3)
        await source.finish(3, snapshot: fixture("recovered"))
        try await until("Later gestures may recover") { title(session) == "recovered" }
        session.invalidate()

        let recoveringSource = ControlledRead()
        let recovering = makeSession(recoveringSource)
        recovering.begin(processIdentifier: 1, applicationName: "Fixture")
        try await recoveringSource.waitForStart(1)
        await recoveringSource.fail(1, error: MenuReaderError.menuUnavailable)
        try await recoveringSource.waitForStart(2)
        await recoveringSource.finish(2, snapshot: fixture("retry success"))
        try await until("A single transient error should recover on retry") { title(recovering) == "retry success" }
        recovering.invalidate()
    }

    @MainActor
    private static func warmRevalidationFailure() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.finish(1, snapshot: fixture("warm content"))
        try await until("Warm fixture must complete") { !session.isRefreshing }
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(2)
        await source.fail(2, error: MenuReaderError.menuUnavailable)
        try await source.waitForStart(3)
        await source.fail(3, error: MenuReaderError.menuUnavailable)
        try await until("Warm revalidation failure must finish") { !session.isRefreshing }
        try require(
            title(session) == "warm content" && snapshot(session)?.isTruncated == true,
            "A transient revalidation failure must retain the provisional warm content")
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(4)
        await source.fail(4, error: MenuReaderError.permissionRequired)
        try await until("Permission failure during revalidation must finish") { !session.isRefreshing }
        try require(isFailure(session, .permissionRequired), "Permission failure must override and evict warm content")
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Permission failure must leave no warm snapshot")
        try await source.waitForStart(5)
        await source.finish(5, snapshot: fixture("restored"))
        try await until("Warm-failure cleanup must finish") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func invalidateDuringRetry() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.fail(1, error: MenuReaderError.menuUnavailable)
        await settle()
        session.cancel()
        session.invalidate()
        try await Task.sleep(for: .milliseconds(140))
        let starts = await source.startCount
        try require(
            starts == 1 && session.result == nil && publications == 0,
            "Invalidation must cancel the delayed retry even after presentation detaches")
    }

    @MainActor
    private static func fatalErrorsAndCancellation() async throws {
        for error in [MenuReaderError.permissionRequired, .applicationUnavailable] {
            let source = ControlledRead()
            let session = makeSession(source)
            session.begin(processIdentifier: 1, applicationName: "Fixture")
            try await source.waitForStart(1)
            await source.progress(1, snapshot: fixture("partial before fatal"))
            try await until("Progress must publish before fatal error") { session.result != nil }
            await source.fail(1, error: error)
            try await until("Fatal error must finish") { !session.isRefreshing }
            try require(
                isFailure(session, error), "Permission/application errors must remain typed and override partial data")
            await settle()
            let starts = await source.startCount
            try require(starts == 1, "Permission/application errors must never retry")
            session.cancel()
            session.begin(processIdentifier: 1, applicationName: "Fixture")
            try require(session.result == nil, "Fatal errors must not cache partial data")
            try await source.waitForStart(2)
            await source.finish(2, snapshot: fixture("fresh"))
            try await until("Fatal-error fixture cleanup must finish") { !session.isRefreshing }
            session.invalidate()
        }
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.fail(1, error: CancellationError())
        try await until("Reader cancellation must stop refreshing") { !session.isRefreshing }
        try require(session.result == nil && publications == 0, "CancellationError must not become a user failure")
        let starts = await source.startCount
        try require(starts == 1, "Cancellation must not retry")
        session.invalidate()
    }

    @MainActor
    private static func progressiveRead() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.progress(1, snapshot: fixture("partial"))
        try await until("Progress must be visible before final completion") { title(session) == "partial" }
        try require(
            session.isRefreshing && snapshot(session)?.isTruncated == true && publications == 1,
            "Progress must be provisional and notify presentation")
        session.cancel()
        await source.progress(1, snapshot: fixture("detached partial"))
        await settle()
        try require(session.result == nil && publications == 1, "Detached progress must not notify presentation")
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(title(session) == "detached partial", "Reattachment should expose the latest ongoing progress")
        await source.finish(1, snapshot: fixture("complete"))
        try await until("Final snapshot must replace partial content") { title(session) == "complete" }
        try require(
            !session.isRefreshing && snapshot(session)?.isTruncated == false && publications == 3,
            "Completion must clear provisional state and notify presentation")
        session.invalidate()
    }

    @MainActor
    private static func partialFailure() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.progress(1, snapshot: fixture("usable partial"))
        try await until("First attempt progress must publish") { title(session) == "usable partial" }
        await source.fail(1, error: MenuReaderError.menuUnavailable)
        try await source.waitForStart(2)
        await source.progress(1, snapshot: fixture("late failed-attempt progress"))
        await settle()
        try require(title(session) == "usable partial", "A superseded retry attempt must not deliver late progress")
        await source.progress(2, snapshot: fixture("newer partial"))
        try await until("Retry may improve partial content") { title(session) == "newer partial" }
        await source.fail(2, error: MenuReaderError.menuUnavailable)
        try await until("Partial failure must complete") { !session.isRefreshing }
        try require(
            title(session) == "newer partial" && snapshot(session)?.isTruncated == true,
            "Final transient failure must preserve usable content, not replace it with an error")
        session.cancel()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Partial failure must not create a successful warm cache entry")
        try await source.waitForStart(3)
        await source.finish(3, snapshot: fixture("fresh"))
        try await until("Partial-failure fixture cleanup must finish") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func synchronousProgress() async throws {
        // Progress and final failure can arrive before MainActor has processed any callbacks.
        let session = MenuReadSession(
            grace: .zero, retryDelay: .zero,
            progressRead: { _, _, progress in
                progress(fixture("synchronous partial"))
                throw MenuReaderError.menuUnavailable
            })
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await until("Synchronous progress/failure must finish") { !session.isRefreshing }
        try require(
            title(session) == "synchronous partial" && snapshot(session)?.isTruncated == true,
            "FIFO progress delivery must preserve a partial result even before immediate final failure")
        session.invalidate()
    }

    @MainActor
    private static func invalidation() async throws {
        let source = ControlledRead()
        let session = makeSession(source)
        var publications = 0
        session.onCompletion = { publications += 1 }
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        session.cancel()
        session.invalidate()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(2)
        await source.progress(1, snapshot: fixture("invalidated progress"))
        await source.finish(1, snapshot: fixture("invalidated completion"))
        await settle()
        try require(
            session.result == nil && publications == 0, "Invalidated detached work must not publish or warm a cache")
        let cancellations = await source.cancelledCalls
        try require(cancellations.contains(1), "Invalidate must cancel even a detached worker")
        await source.finish(2, snapshot: fixture("new owner"))
        try await until("Replacement worker must publish") { title(session) == "new owner" }
        await source.progress(1, snapshot: fixture("very late old progress"))
        await settle()
        try require(
            title(session) == "new owner" && publications == 1, "Cancelled old callbacks must not replace new results")
        session.cancel()
        session.invalidate()
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try require(session.result == nil, "Invalidation must clear successful warm snapshots, even after detach")
        try await source.waitForStart(3)
        await source.finish(3, snapshot: fixture("clean"))
        try await until("Invalidation fixture cleanup must finish") { !session.isRefreshing }
        session.invalidate()
    }

    @MainActor
    private static func boundedWork() async throws {
        let source = ControlledRead()
        let session = MenuReadSession(grace: .zero, maximumReadDuration: .milliseconds(60), progressRead: source.reader)
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        try await until("An unresponsive worker must have a session deadline") { !session.isRefreshing }
        try require(isFailure(session, .menuUnavailable), "A bounded stalled read should report unavailable")
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(2)
        await source.progress(1, snapshot: fixture("expired progress"))
        await source.finish(1, snapshot: fixture("expired completion"))
        await source.finish(2, snapshot: fixture("within budget"))
        try await until("A new worker must replace timed-out ownership") { title(session) == "within budget" }
        session.invalidate()

        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(3)
        session.cancel()
        try await Task.sleep(for: .milliseconds(90))
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(4)
        try require(session.result == nil, "Detached work must also expire, not live until another release")
        await source.finish(3, snapshot: fixture("expired detached"))
        await source.finish(4, snapshot: fixture("new bounded worker"))
        try await until("Detached timeout fixture must complete") { title(session) == "new bounded worker" }
        session.invalidate()
    }

    @MainActor
    private static func normalChordGrace() async throws {
        let source = ControlledRead()
        let session = MenuReadSession(grace: .milliseconds(60), read: { pid, _ in try await source.read(pid) })
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        session.cancel()
        try await Task.sleep(for: .milliseconds(90))
        let starts = await source.startCount
        try require(starts == 0 && session.result == nil, "A normal chord cancelled during grace must not read menus")
        session.begin(processIdentifier: 1, applicationName: "Fixture")
        try await source.waitForStart(1)
        await source.finish(1, snapshot: fixture("held"))
        try await until("A later sustained hold must still work") { title(session) == "held" }
        session.invalidate()
    }

    @MainActor
    private static func makeSession(_ source: ControlledRead) -> MenuReadSession {
        MenuReadSession(grace: .zero, progressRead: source.reader)
    }

    @MainActor
    private static func snapshot(_ session: MenuReadSession) -> MenuSnapshot? {
        guard case .success(let snapshot) = session.result else { return nil }
        return snapshot
    }

    @MainActor
    private static func title(_ session: MenuReadSession) -> String? {
        snapshot(session)?.sections.first?.shortcuts.first?.title
    }

    @MainActor
    private static func isFailure(_ session: MenuReadSession, _ expected: MenuReaderError) -> Bool {
        guard case .failure(let error) = session.result else { return false }
        switch (error, expected) {
        case (.permissionRequired, .permissionRequired), (.applicationUnavailable, .applicationUnavailable),
            (.menuUnavailable, .menuUnavailable):
            return true
        default: return false
        }
    }

    @MainActor
    private static func until(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            try require(ContinuousClock.now < deadline, message)
            await Task.yield()
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private actor ControlledRead {
    private var pending: [Int: CheckedContinuation<MenuSnapshot, any Error>] = [:]
    private var callbacks: [Int: MenuReadSession.Progress] = [:]
    private(set) var startCount = 0
    private(set) var cancelledCalls: Set<Int> = []

    nonisolated var reader: MenuReadSession.ProgressRead {
        { pid, _, progress in try await self.read(pid, progress: progress) }
    }

    func read(_ pid: Int32, progress: @escaping MenuReadSession.Progress = { _ in }) async throws -> MenuSnapshot {
        startCount += 1
        let call = startCount
        callbacks[call] = progress
        // Deliberately ignore cancellation so actual session ownership rejects late responses.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[call] = $0 }
        } onCancel: {
            Task { await self.recordCancellation(call) }
        }
    }

    private func recordCancellation(_ call: Int) { cancelledCalls.insert(call) }

    func waitForStart(_ call: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pending[call] == nil {
            try require(ContinuousClock.now < deadline, "Read invocation \(call) must start")
            await Task.yield()
        }
    }

    func progress(_ call: Int, snapshot: MenuSnapshot) { callbacks[call]?(snapshot) }

    func finish(_ call: Int, snapshot: MenuSnapshot) {
        pending.removeValue(forKey: call)?.resume(returning: snapshot)
    }

    func fail(_ call: Int, error: any Error) {
        pending.removeValue(forKey: call)?.resume(throwing: error)
    }
}

private func fixture(_ title: String, pid: Int32 = 1) -> MenuSnapshot {
    MenuSnapshot(
        applicationName: "Fixture", processIdentifier: pid,
        sections: [
            ShortcutSection(
                id: "file", title: "File",
                shortcuts: [
                    Shortcut(id: title, title: title, menuPath: ["File", title], keys: "⌘F", isEnabled: true)
                ])
        ], isTruncated: false
    )
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}
