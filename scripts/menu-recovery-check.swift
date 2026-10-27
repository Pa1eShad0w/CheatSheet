// Run from the repository root (separate @main from the other checks):
// swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors Sources/CheatSheetCore/*.swift scripts/menu-recovery-check.swift -o .build/menu-recovery-check
// .build/menu-recovery-check
import ApplicationServices
import Foundation

@main
private enum MenuRecoveryCheck {
    static func main() async {
        do {
            try checkDisappearingDescendants()
            try checkMissingNodesAndChildrenFailure()
            try checkFatalErrors()
            try checkAttributeSentinels()
            try checkProgressBeforeBlockingFailure()
            try checkProgressCadenceAndOrder()
            try checkProgressBudgets()
            try await checkCancellation()
            print(
                "Menu recovery checks passed: mixed branches, missing descendants, AX sentinels, fatal boundaries, progressive ordering/throttling, budgets, cancellation."
            )
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func checkDisappearingDescendants() throws {
        for error in [MenuReaderError.menuUnavailable, .applicationUnavailable] {
            for stage in [FailureStage.item, .children] {
                let source = RecoveryTree()
                source.failure = (3, stage, error)
                let snapshot: MenuSnapshot
                do {
                    snapshot = try readMenuTree(
                        source: source, root: 0, applicationName: "Fixture", processIdentifier: 42)
                } catch {
                    throw CheckFailure(
                        description:
                            "A disappearing descendant discarded earlier Open and later Save/Copy siblings (\(stage)): \(error)"
                    )
                }
                try require(snapshot.isTruncated, "Missing descendants must mark the snapshot truncated")
                try require(snapshot.sections.map(\.title) == ["File", "Edit"], "Keep section order")
                try require(
                    snapshot.sections.flatMap(\.shortcuts).map(\.title) == ["Open", "Save", "Copy"],
                    "Keep earlier shortcuts and continue later siblings/sections")
                try require(
                    snapshot.sections[0].shortcuts.map(\.isEnabled) == [false, false], "Keep disabled ancestors")
                try require(snapshot.sections[1].shortcuts[0].menuPath == ["Edit"], "Keep menu paths")
            }
        }
    }

    private static func read(
        _ source: RecoveryTree, budget: MenuReadBudget = MenuReadBudget(),
        onProgress: ((MenuSnapshot) -> Void)? = nil
    ) throws -> MenuSnapshot {
        try readMenuTree(
            source: source, root: 0, applicationName: "Fixture", processIdentifier: 42,
            budget: budget, onProgress: onProgress)
    }

    private static func checkMissingNodesAndChildrenFailure() throws {
        let missing = RecoveryTree()
        missing.nodes[3] = nil
        let partial = try read(missing)
        try require(partial.isTruncated, "A removed descendant marks truncation")
        try require(titles(partial) == ["Open", "Save", "Copy"], "Removed nodes do not discard siblings")

        let source = RecoveryTree()
        source.nodes[3] = (MenuTreeItem(title: "Recent", keys: "⌘R", isEnabled: true), [8])
        source.failure = (3, .children, MenuReaderError.menuUnavailable)
        let snapshot = try read(source)
        try require(snapshot.isTruncated, "Children failure marks truncation")
        try require(
            titles(snapshot) == ["Open", "Recent", "Save", "Copy"],
            "Keep the node's own shortcut when its children fail")
    }

    private static func checkFatalErrors() throws {
        for stage in [FailureStage.item, .children] {
            for error in [MenuReaderError.menuUnavailable, .applicationUnavailable, .permissionRequired] {
                let source = RecoveryTree()
                source.failure = (0, stage, error)
                try expect(error) { _ = try read(source) }
            }
            for node in [0, 3] {
                let source = RecoveryTree()
                source.failure = (node, stage, MenuReaderError.permissionRequired)
                try expect(.permissionRequired) { _ = try read(source) }
                source.failure = (node, stage, UnexpectedFailure())
                do {
                    _ = try read(source)
                    throw CheckFailure(description: "Arbitrary source errors must propagate")
                } catch is UnexpectedFailure {}
                source.failure = (node, stage, CancellationError())
                do {
                    _ = try read(source)
                    throw CheckFailure(description: "Source cancellation must propagate")
                } catch is CancellationError {}
            }
        }
    }

    private static func checkAttributeSentinels() throws {
        for field in 0..<6 {
            let transport = SentinelAttributes(field: field, error: .cannotComplete)
            let source = SentinelTree(transport: transport)
            let snapshot = try readMenuTree(
                source: source, root: 0, applicationName: "Fixture", processIdentifier: 42)
            try require(snapshot.isTruncated, "Per-field failure must mark truncation, not use a default")
            try require(titles(snapshot) == ["Before", "After"], "Per-field failure skips only its descendant")
            try require(transport.batchCount == 1, "Do not retry a per-field failure")
        }
        let denied = SentinelTree(transport: SentinelAttributes(field: 2, error: .apiDisabled))
        try expect(.permissionRequired) {
            _ = try readMenuTree(source: denied, root: 0, applicationName: "Fixture", processIdentifier: 42)
        }
    }

    private static func checkProgressBeforeBlockingFailure() throws {
        let source = RecoveryTree()
        source.failure = (3, .item, MenuReaderError.menuUnavailable)
        var progress: [MenuSnapshot] = []
        var progressBeforeBlock = false
        source.onRead = { node, stage in
            if node == 3 && stage == .item {
                progressBeforeBlock = progress.count == 1 && titles(progress[0]) == ["Open"]
                Thread.sleep(forTimeInterval: 0.06)
            }
        }
        let snapshot = try read(source) { progress.append($0) }
        try require(progressBeforeBlock, "First usable progress must precede the later blocking AX failure")
        try require(titles(snapshot) == ["Open", "Save", "Copy"], "Final recovered ordering")
        try checkProgress(progress, final: snapshot)
    }

    private static func checkProgressCadenceAndOrder() throws {
        let source = RecoveryTree()
        source.nodes = [0: (nil, [1]), 1: (MenuTreeItem(title: "File", keys: nil, isEnabled: false), Array(2...97))]
        for node in 2...97 {
            source.nodes[node] = (MenuTreeItem(title: "Action \(node)", keys: "⌘O", isEnabled: true), [])
        }
        var progress: [MenuSnapshot] = []
        let snapshot = try read(source) { progress.append($0) }
        let counts = progress.map { titles($0).count }
        try require(counts.first == 1 && counts.last == 96, "First shortcut and section completion both publish")
        // Time-based delivery may add callbacks on a slow machine; count-based delivery cannot be later than 32.
        try require(
            zip(counts, counts.dropFirst()).allSatisfy { $1 > $0 && $1 - $0 <= 32 },
            "Progress is changed and at most 32 new shortcuts apart")
        try require(progress.count < 20, "Fast traversal must not publish for every shortcut")
        try require(titles(snapshot) == (2...97).map { "Action \($0)" }, "Final menu order")
        try require(!snapshot.isTruncated, "Complete final result clears the provisional truncation flag")
        try checkProgress(progress, final: snapshot)

        let timed = RecoveryTree()
        var timedProgress: [MenuSnapshot] = []
        var deliveredBeforeNextRead = false
        timed.onRead = { node, stage in
            if node == 8 && stage == .item { Thread.sleep(forTimeInterval: 0.06) }
            if node == 8 && stage == .children { deliveredBeforeNextRead = timedProgress.count >= 2 }
        }
        _ = try read(timed) { timedProgress.append($0) }
        try require(deliveredBeforeNextRead, "Elapsed 50ms publishes before the count/section threshold")

        let empty = RecoveryTree()
        empty.nodes = [0: (nil, [])]
        var emptyCount = 0
        _ = try read(empty) { _ in emptyCount += 1 }
        try require(emptyCount == 0, "Never publish empty progress")
    }

    private static func checkProgressBudgets() throws {
        for budget in [
            MenuReadBudget(duration: .zero), MenuReadBudget(maximumNodes: 3), MenuReadBudget(maximumDepth: 1),
        ] {
            let source = RecoveryTree()
            var progress: [MenuSnapshot] = []
            let snapshot = try read(source, budget: budget) { progress.append($0) }
            try require(snapshot.isTruncated, "Progress preserves deadline/node/depth truncation")
            try checkProgress(progress, final: snapshot)
        }
        let source = RecoveryTree()
        source.onRead = { node, stage in
            if node == 3 && stage == .item { Thread.sleep(forTimeInterval: 0.03) }
        }
        var progress: [MenuSnapshot] = []
        let snapshot = try read(source, budget: MenuReadBudget(duration: .milliseconds(20))) { progress.append($0) }
        try require(
            snapshot.isTruncated && titles(snapshot) == ["Open"], "A slow later read retains only pre-deadline output")
        try require(progress.count == 1, "No progress delivery after the deadline")
    }

    private static func checkCancellation() async throws {
        for stage in 0...4 {
            let passed = await Task.detached {
                let source = RecoveryTree()
                var progressCount = 0
                var readsAfterCancellation = 0
                var cancelled = false
                if stage == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                    cancelled = true
                }
                source.onRead = { node, phase in
                    if cancelled { readsAfterCancellation += 1 }
                    if (stage == 1 || stage == 3) && node == 2 && phase == .item
                        || stage == 4 && node == 2 && phase == .children
                    {
                        withUnsafeCurrentTask { $0?.cancel() }
                        cancelled = true
                    }
                }
                if stage == 3 { source.failure = (2, .item, MenuReaderError.menuUnavailable) }
                do {
                    _ = try read(source) { _ in
                        progressCount += 1
                        if stage == 2 {
                            withUnsafeCurrentTask { $0?.cancel() }
                            cancelled = true
                        }
                    }
                    return false
                } catch is CancellationError {
                    return progressCount == (stage == 2 || stage == 4 ? 1 : 0) && readsAfterCancellation == 0
                } catch { return false }
            }.value
            try require(
                passed,
                "Cancellation must stop reads/progress, including recoverable-error and callback cancellation (stage \(stage))"
            )
        }
    }

    private static func checkProgress(_ progress: [MenuSnapshot], final: MenuSnapshot) throws {
        let finalShortcuts = final.sections.flatMap(\.shortcuts)
        for partial in progress {
            try require(partial.isTruncated && !partial.sections.isEmpty, "Progress is usable and provisional")
            try require(partial.applicationName == "Fixture" && partial.processIdentifier == 42, "Progress identity")
            let shortcuts = partial.sections.flatMap(\.shortcuts)
            try require(
                shortcuts == Array(finalShortcuts.prefix(shortcuts.count)),
                "Progress retains order, paths, IDs, and enabled state")
            try require(Set(shortcuts.map(\.id)).count == shortcuts.count, "Progress is deduplicated")
        }
    }
}

private func titles(_ snapshot: MenuSnapshot) -> [String] { snapshot.sections.flatMap(\.shortcuts).map(\.title) }

private struct UnexpectedFailure: Error {}

private enum FailureStage { case item, children }

private final class RecoveryTree: MenuTreeSource {
    var failure: (Int, FailureStage, any Error)?
    var onRead: ((Int, FailureStage) -> Void)?
    var nodes: [Int: (MenuTreeItem?, [Int])] = [
        0: (nil, [1, 6]),
        1: (MenuTreeItem(title: "File", keys: nil, isEnabled: false), [2, 3, 4, 5]),
        2: (MenuTreeItem(title: "Open", keys: "⌘O", isEnabled: true), []),
        3: (nil, [8]),
        4: (MenuTreeItem(title: "Save", keys: "⌘S", isEnabled: true), []),
        5: (MenuTreeItem(title: "Open", keys: "⌘O", isEnabled: true), []),
        6: (MenuTreeItem(title: "Edit", keys: nil, isEnabled: true), [7]),
        7: (MenuTreeItem(title: "Copy", keys: "⌘C", isEnabled: true), []),
        8: (MenuTreeItem(title: "Lost", keys: "⌘L", isEnabled: true), []),
    ]

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        try read(element, stage: .item)
        return nodes[element]?.0
    }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        try read(element, stage: .children)
        let children = nodes[element]?.1 ?? []
        return MenuTreeChildren(elements: Array(children.prefix(limit)), hasMore: children.count > limit)
    }

    private func read(_ element: Int, stage: FailureStage) throws {
        onRead?(element, stage)
        guard nodes[element] != nil else { throw MenuReaderError.applicationUnavailable }
        if let failure, failure.0 == element, failure.1 == stage { throw failure.2 }
    }
}

private final class SentinelAttributes: MenuAttributeTransport {
    let field: Int
    let error: AXError
    var batchCount = 0

    init(field: Int, error: AXError) {
        self.field = field
        self.error = error
    }

    func setMessagingTimeout(_ timeout: Float, for element: AXUIElement) -> AXError { .success }
    func copyAttribute(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        (.success, kAXMenuItemRole as CFString)
    }
    func copyMultipleAttributes(_ names: [String], of element: AXUIElement) -> (AXError, CFArray?) {
        batchCount += 1
        var values: [CFTypeRef] = [
            "Lost" as CFString, "l" as CFString, NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0),
            kCFBooleanTrue!,
        ]
        var error = error
        values[field] = AXValueCreate(.axError, &error)!
        return (.success, values as CFArray)
    }
}

private struct SentinelTree: MenuTreeSource {
    let transport: SentinelAttributes
    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        switch element {
        case 0: return nil
        case 2:
            return try AccessibilityMenuSource(attributes: transport).item(
                for: AXUIElementCreateApplication(42), budget: budget)
        default: return MenuTreeItem(title: element == 1 ? "Before" : "After", keys: "⌘O", isEnabled: true)
        }
    }
    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        MenuTreeChildren(elements: element == 0 ? Array([1, 2, 3].prefix(limit)) : [], hasMore: false)
    }
}

private func expect(_ expected: MenuReaderError, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let actual as MenuReaderError {
        switch (expected, actual) {
        case (.permissionRequired, .permissionRequired), (.menuUnavailable, .menuUnavailable),
            (.applicationUnavailable, .applicationUnavailable):
            return
        default: throw CheckFailure(description: "Wrong fatal error classification")
        }
    }
    throw CheckFailure(description: "Fatal error must propagate")
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}
