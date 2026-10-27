// Run from the repository root:
// swiftc -swift-version 6 -strict-concurrency=complete Sources/CheatSheetCore/*.swift scripts/core-check.swift -o .build/core-check
// .build/core-check
import Carbon.HIToolbox
import Foundation

@main
private enum CoreCheck {
    static func main() async throws {
        try checkCommandHold()
        try checkPinning()
        try checkKeys()
        try checkTraversal()
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try readMenuTree(source: CheckTree.sample, root: 0, applicationName: "Check", processIdentifier: 42)
                return false
            } catch is CancellationError {
                return true
            }
        }
        try require(try await cancelled.value, "Traversal must propagate task cancellation")
        print("Core checks passed: CommandHold, key formatting, menu traversal, budgets, and cancellation.")
    }

    private static func checkCommandHold() throws {
        let command = CommandHold.Event.modifiers(command: true, other: false)
        let release = CommandHold.Event.modifiers(command: false, other: false)
        var hold = HoldCheck()
        try hold.expect(.delayElapsed, [], "Idle timer")
        try hold.expect(.keyDown, [], "Idle key")
        try hold.expect(.mouseDown, [], "Idle mouse")
        try hold.expect(command, [.schedule], "Begin hold")
        try hold.expect(command, [], "Repeated waiting flags")
        try hold.expect(release, [.cancel], "Release before delay")
        try hold.expect(.delayElapsed, [], "Stale timer after release")
        try hold.expect(command, [.schedule], "Fresh hold")
        try hold.expect(.delayElapsed, [.show], "Hold delay", visible: true)
        try hold.expect(command, [], "Repeated visible flags", visible: true)
        try hold.expect(.delayElapsed, [], "Repeated timer", visible: true)
        try hold.expect(release, [.cancel, .hide], "Release visible hold")
        try hold.expect(release, [], "Repeated release")

        for event in [CommandHold.Event.keyDown, .mouseDown, .modifiers(command: true, other: true)] {
            for visible in [false, true] {
                var gesture = HoldCheck()
                let label = "Suppression by \(event), initially visible: \(visible)"
                try gesture.expect(command, [.schedule], label)
                if visible { try gesture.expect(.delayElapsed, [.show], label, visible: true) }
                try gesture.expect(event, visible ? [.cancel, .hide] : [.cancel], label)
                try gesture.expect(event, [], "\(label): repeated event")
                try gesture.expect(command, [], "\(label): blocked until release")
                try gesture.expect(.delayElapsed, [], "\(label): stale timer")
                try gesture.expect(release, [], "\(label): release")
                try gesture.expect(command, [.schedule], "\(label): re-arm")
                try gesture.expect(.delayElapsed, [.show], "\(label): fresh delay", visible: true)
            }
        }
        for events in [[], [command], [command, .keyDown], [command, .delayElapsed]] {
            var lifecycle = HoldCheck()
            for event in events { _ = lifecycle.hold.handle(event) }
            _ = lifecycle.hold.handle(.invalidate(command: true))
            try lifecycle.expect(command, [], "Lifecycle change while Command is held")
            try lifecycle.expect(.delayElapsed, [], "Stale timer after lifecycle change")
            try lifecycle.expect(release, [], "Release after lifecycle change")
            try lifecycle.expect(command, [.schedule], "Fresh hold after lifecycle change")
        }
        var chord = HoldCheck()
        try chord.expect(.modifiers(command: true, other: true), [], "Command chord starts suppressed")
        try chord.expect(command, [], "Removing other modifiers must not re-arm")
        try chord.expect(.delayElapsed, [], "Suppressed chord timer")
        try chord.expect(.modifiers(command: false, other: true), [], "Release Command while other modifier remains")
        try chord.expect(command, [.schedule], "Hold after chord release")

        let setups: [([CommandHold.Event], [CommandHold.Effect])] = [
            ([], []), ([command], [.cancel]),
            ([command, .delayElapsed], [.cancel, .hide]), ([command, .keyDown], []),
        ]
        for (events, expected) in setups {
            var gesture = HoldCheck()
            for event in events { _ = gesture.hold.handle(event) }
            try gesture.expect(.reset, expected, "Reset after \(events)")
            try gesture.expect(.reset, [], "Repeated reset")
            try gesture.expect(.delayElapsed, [], "Stale timer after reset")
            try gesture.expect(command, [.schedule], "Fresh hold after reset")
            try gesture.expect(.delayElapsed, [.show], "Fresh delay after reset", visible: true)
        }
    }

    private static func checkPinning() throws {
        let command = CommandHold.Event.modifiers(command: true, other: false)
        let release = CommandHold.Event.modifiers(command: false, other: false)
        var hold = CommandHold()
        try equal(hold.handle(.pin), [], "Cannot pin a hidden sheet")
        try require(!hold.isPinned, "Hidden sheet stays unpinned")
        _ = hold.handle(command)
        _ = hold.handle(.delayElapsed)
        try equal(hold.handle(.pin), [], "Pin the visible sheet without rereading")
        try require(hold.isPinned && hold.isVisible, "Pinned sheet remains visible")
        for event in [release, .modifiers(command: true, other: true), .keyDown, release] {
            try equal(hold.handle(event), [], "Screenshot modifiers and Command release must not dismiss a pin")
            try require(hold.isPinned && hold.isVisible, "Screenshot gesture preserves the pinned sheet")
        }
        try equal(hold.handle(.invalidate(command: false)), [.cancel, .hide], "Outside click closes the pinned sheet")
        try require(!hold.isPinned && !hold.isVisible, "Outside click fully clears pin state")
        try equal(hold.handle(command), [.schedule], "The very next hold works after an outside click")
        _ = hold.handle(.delayElapsed)
        _ = hold.handle(.pin)
        try equal(hold.handle(.unpin(command: false)), [.cancel, .hide], "Unpin without Command returns to normal")
        try equal(hold.handle(command), [.schedule], "Hold works after unpinning")
        _ = hold.handle(.delayElapsed)
        _ = hold.handle(.pin)
        try equal(hold.handle(.unpin(command: true)), [], "Unpin while holding Command retains normal visibility")
        try require(!hold.isPinned && hold.isVisible, "Unpinned sheet follows the held Command key")
        try equal(hold.handle(release), [.cancel, .hide], "Release closes an unpinned sheet")
        print("Pin checks passed: persistence, screenshot keys, outside dismissal, unpinning, and next-hold recovery.")
    }

    private static func checkKeys() throws {
        let cases: [(String?, UInt32?, Int?, Int?, String?)] = [
            ("o", 7, nil, nil, "⌃⌥⇧⌘O"), ("o", nil, nil, nil, "⌘O"),
            ("o", 8, nil, nil, "O"), ("o", 15, nil, nil, "⌃⌥⇧O"),
            ("\u{F704}", 8, nil, nil, "F1"), (nil, 8, Int(kMenuF19Glyph), nil, "F19"),
            (nil, 8, nil, Int(kVK_F20), "F20"), ("\r", 0, nil, nil, "⌘↩"),
            (nil, 8, Int(kMenuDeleteRightGlyph), nil, "⌦"),
            (nil, 8, nil, Int(kVK_LeftArrow), "←"), (" ", 8, nil, nil, "Space"),
            ("x", 0, Int(kMenuF1Glyph), Int(kVK_F2), "⌘X"),
            (nil, 7, nil, nil, nil), ("", 0, 0, 0, nil),
            ("\0", 0, nil, nil, nil), (nil, 0, nil, Int(kVK_ANSI_A), nil),
        ]
        for (index, entry) in cases.enumerated() {
            let (character, modifiers, glyph, virtualKey, expected) = entry
            try equal(
                MenuKeyFormatter.format(
                    character: character, modifiers: modifiers, glyph: glyph, virtualKey: virtualKey
                ), expected, "Key-format case \(index)")
        }
    }

    private static func checkTraversal() throws {
        func read(_ budget: MenuReadBudget = MenuReadBudget()) throws -> MenuSnapshot {
            try readMenuTree(
                source: CheckTree.sample, root: 0, applicationName: "Check", processIdentifier: 42, budget: budget
            )
        }
        let snapshot = try read()
        try equal(snapshot.sections.map(\.title), ["File", "Edit"], "Top-level menu grouping")
        let file = snapshot.sections[0].shortcuts
        try equal(file.map(\.title), ["Open", "Other", "Open"], "Deduplicate identical path/title/key only")
        try equal(file.map(\.menuPath), [["File"], ["File"], ["File", "Recent"]], "Container and submenu paths")
        try equal(file.map(\.isEnabled), [true, false, true], "Preserve disabled shortcuts")
        let shortcuts = snapshot.sections.flatMap(\.shortcuts)
        try equal(shortcuts.count, 4, "Retain shared keys in different menus")
        try equal(Set(shortcuts.map(\.id)).count, 4, "Distinct shortcut identities")
        try equal(snapshot, read(), "Stable snapshot identity")
        try require(!snapshot.isTruncated, "Ordinary tree must not be truncated")
        try require(try read(MenuReadBudget(maximumNodes: 10)).isTruncated == false, "Exact node budget must suffice")
        let limited = try read(MenuReadBudget(maximumNodes: 4))
        try require(limited.isTruncated, "Node limit must mark truncation")
        try equal(limited.sections.flatMap(\.shortcuts).count, 1, "Node limit preserves partial results")
        let expired = try read(MenuReadBudget(duration: .zero))
        try require(expired.isTruncated && expired.sections.isEmpty, "Expired deadline must stop traversal")
        let cycle = try readMenuTree(
            source: CheckTree(nodes: [(nil, [0])]), root: 0, applicationName: "Cycle", processIdentifier: 42,
            budget: MenuReadBudget(maximumDepth: 2)
        )
        try require(cycle.isTruncated, "Depth limit must stop cycles")
    }
}

private struct HoldCheck {
    var hold = CommandHold()

    mutating func expect(
        _ event: CommandHold.Event, _ effects: [CommandHold.Effect], _ context: String, visible: Bool = false
    ) throws {
        try equal(hold.handle(event), effects, "\(context): effects")
        try equal(hold.isVisible, visible, "\(context): visibility")
    }
}

private struct CheckTree: MenuTreeSource {
    let nodes: [(item: MenuTreeItem?, children: [Int])]

    static var sample: CheckTree {
        CheckTree(nodes: [
            (nil, [1, 7]),
            (MenuTreeItem(title: "File", keys: nil, isEnabled: true), [2]),
            (nil, [3, 4, 5, 6]),
            (MenuTreeItem(title: "Open", keys: "⌘O", isEnabled: true), []),
            (MenuTreeItem(title: "Open", keys: "⌘O", isEnabled: true), []),
            (MenuTreeItem(title: "Other", keys: "⌘O", isEnabled: false), []),
            (MenuTreeItem(title: "Recent", keys: nil, isEnabled: true), [8]),
            (MenuTreeItem(title: "Edit", keys: nil, isEnabled: true), [9]),
            (MenuTreeItem(title: "Open", keys: "⌘O", isEnabled: true), []),
            (MenuTreeItem(title: "Another", keys: "⌘O", isEnabled: true), []),
        ])
    }

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? { nodes[element].item }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        let children = nodes[element].children
        return MenuTreeChildren(elements: Array(children.prefix(limit)), hasMore: children.count > limit)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}

private func equal<Value: Equatable>(_ actual: Value, _ expected: Value, _ context: String) throws {
    try require(actual == expected, "\(context): expected \(expected), got \(actual)")
}
