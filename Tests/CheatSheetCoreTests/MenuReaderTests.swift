import Carbon.HIToolbox
import XCTest

@testable import CheatSheetCore

final class MenuReaderTests: XCTestCase {
    func testModifierOrderAndDefaultCommand() {
        XCTAssertEqual(key("o", modifiers: 0), "⌘O")
        XCTAssertEqual(key("o", modifiers: nil), "⌘O")
        XCTAssertEqual(key("o", modifiers: 1), "⇧⌘O")
        XCTAssertEqual(key("o", modifiers: 2), "⌥⌘O")
        XCTAssertEqual(key("o", modifiers: 4), "⌃⌘O")
        XCTAssertEqual(key("o", modifiers: 7), "⌃⌥⇧⌘O")
        XCTAssertEqual(key("o", modifiers: 8), "O")
        XCTAssertEqual(key("o", modifiers: 15), "⌃⌥⇧O")
        XCTAssertEqual(key("o", modifiers: 0x100), "⌘O", "Unknown bits must not become modifiers")
    }

    func testFunctionKeysFromCharactersGlyphsAndVirtualKeys() {
        for function in 1...35 {
            let character = String(UnicodeScalar(0xF704 + function - 1)!)
            XCTAssertEqual(key(character, modifiers: 8), "F\(function)")
        }
        let glyphs =
            Array(Int(kMenuF1Glyph)...Int(kMenuF12Glyph))
            + Array(Int(kMenuF13Glyph)...Int(kMenuF15Glyph))
            + Array(Int(kMenuF16Glyph)...Int(kMenuF19Glyph))
        for (index, glyph) in glyphs.enumerated() {
            XCTAssertEqual(key(nil, modifiers: 8, glyph: glyph), "F\(index + 1)")
        }
        let virtualKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, virtualKey) in virtualKeys.enumerated() {
            XCTAssertEqual(key(nil, modifiers: 8, virtualKey: Int(virtualKey)), "F\(index + 1)")
        }
    }

    func testSpecialCharacters() {
        let examples = [
            ("\r", "↩"), ("\n", "↩"), ("\u{03}", "⌤"), ("\t", "⇥"),
            ("\u{19}", "⇤"), ("\u{1B}", "⎋"), ("\u{08}", "⌫"), ("\u{7F}", "⌫"),
            (" ", "Space"), ("\u{F700}", "↑"), ("\u{F701}", "↓"),
            ("\u{F702}", "←"), ("\u{F703}", "→"), ("\u{F728}", "⌦"),
            ("\u{F729}", "↖"), ("\u{F72B}", "↘"), ("\u{F72C}", "⇞"),
            ("\u{F72D}", "⇟"), ("\u{F739}", "⌧"),
        ]
        for (character, expected) in examples {
            XCTAssertEqual(key(character, modifiers: 8), expected)
        }
        XCTAssertEqual(key("/", modifiers: 7), "⌃⌥⇧⌘/")
        XCTAssertEqual(key("é", modifiers: 0), "⌘É")
    }

    func testSpecialGlyphsAndVirtualKeyFallback() {
        let examples = [
            (kMenuTabRightGlyph, kVK_Tab, "⇥"),
            (kMenuReturnGlyph, kVK_Return, "↩"),
            (kMenuEnterGlyph, kVK_ANSI_KeypadEnter, "⌤"),
            (kMenuEscapeGlyph, kVK_Escape, "⎋"),
            (kMenuDeleteLeftGlyph, kVK_Delete, "⌫"),
            (kMenuDeleteRightGlyph, kVK_ForwardDelete, "⌦"),
            (kMenuLeftArrowGlyph, kVK_LeftArrow, "←"),
            (kMenuRightArrowGlyph, kVK_RightArrow, "→"),
            (kMenuUpArrowGlyph, kVK_UpArrow, "↑"),
            (kMenuDownArrowGlyph, kVK_DownArrow, "↓"),
            (kMenuNorthwestArrowGlyph, kVK_Home, "↖"),
            (kMenuSoutheastArrowGlyph, kVK_End, "↘"),
            (kMenuPageUpGlyph, kVK_PageUp, "⇞"),
            (kMenuPageDownGlyph, kVK_PageDown, "⇟"),
            (kMenuSpaceGlyph, kVK_Space, "Space"),
            (kMenuClearGlyph, kVK_ANSI_KeypadClear, "⌧"),
        ]
        for (glyph, virtualKey, expected) in examples {
            XCTAssertEqual(key(nil, modifiers: 8, glyph: Int(glyph)), expected)
            XCTAssertEqual(key("", modifiers: 8, virtualKey: Int(virtualKey)), expected)
        }
        XCTAssertEqual(key("x", modifiers: 0, glyph: Int(kMenuF1Glyph), virtualKey: Int(kVK_F2)), "⌘X")
        XCTAssertEqual(key(nil, modifiers: 0, glyph: Int(kMenuF1Glyph), virtualKey: Int(kVK_F2)), "⌘F1")
    }

    func testMissingAndUnknownKeysDoNotProduceModifierOnlyShortcuts() {
        XCTAssertNil(key(nil, modifiers: 7))
        XCTAssertNil(key("", modifiers: 0))
        XCTAssertNil(key("\0", modifiers: 0))
        XCTAssertNil(key("\u{F8FF}", modifiers: 0))
        XCTAssertNil(key("  ", modifiers: 0))
        XCTAssertNil(key(nil, modifiers: 0, glyph: Int(kMenuNullGlyph)))
        XCTAssertNil(key(nil, modifiers: 0, glyph: 999, virtualKey: 999))
        XCTAssertNil(key(nil, modifiers: 0, virtualKey: Int(kVK_ANSI_A)), "Do not assume a keyboard layout")
        XCTAssertEqual(key("\0", modifiers: 8, virtualKey: Int(kVK_F1)), "F1")
    }

    func testGroupingDeduplicationPathsAndDisabledItems() throws {
        let snapshot = try readFixture()
        XCTAssertEqual(snapshot.applicationName, "Fixture")
        XCTAssertEqual(snapshot.processIdentifier, 42)
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections.map(\.title), ["File", "Edit"])
        let file = snapshot.sections[0].shortcuts
        XCTAssertEqual(file.map(\.title), ["Open", "Other", "Open", "Open"])
        XCTAssertEqual(file.map(\.keys), ["⌘O", "⌘O", "⌘P", "⌘O"])
        XCTAssertEqual(file.map(\.menuPath), [["File"], ["File"], ["File"], ["File", "Recent"]])
        XCTAssertEqual(file.map(\.isEnabled), [true, false, true, true])
        XCTAssertEqual(snapshot.sections[1].shortcuts[0].keys, "⌘O", "The same key in another menu is retained")
        let shortcuts = snapshot.sections.flatMap(\.shortcuts)
        XCTAssertEqual(Set(shortcuts.map(\.id)).count, shortcuts.count)
        XCTAssertEqual(snapshot, try readFixture(), "Snapshot identities are stable between reads")
    }

    func testDisabledAncestorsDisableDescendants() throws {
        let source = FixtureSource(nodes: [
            0: .container([1]),
            1: .item("File", enabled: false, children: [2]),
            2: .item("Open", keys: "⌘O"),
        ])
        let snapshot = try readFixture(source: source)
        XCTAssertFalse(try XCTUnwrap(snapshot.sections.first?.shortcuts.first).isEnabled)
    }

    func testIdentityDoesNotCollideForTitlesContainingSeparators() throws {
        let source = FixtureSource(nodes: [
            0: .container([1, 3]),
            1: .item("A/B", children: [2]),
            2: .item("C", keys: "⌘O"),
            3: .item("A", children: [4]),
            4: .item("B/C", keys: "⌘O"),
        ])
        let shortcuts = try readFixture(source: source).sections.flatMap(\.shortcuts)
        XCTAssertEqual(shortcuts.count, 2)
        XCTAssertNotEqual(shortcuts[0].id, shortcuts[1].id)
    }

    func testNodeBudgetReturnsPartialSnapshot() throws {
        let snapshot = try readFixture(budget: MenuReadBudget(maximumNodes: 4))
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections.flatMap(\.shortcuts).map(\.title), ["Open"])
        let empty = try readFixture(budget: MenuReadBudget(maximumNodes: 0))
        XCTAssertTrue(empty.isTruncated)
        XCTAssertTrue(empty.sections.isEmpty)
    }

    func testDepthBudgetAndCyclesAreBounded() throws {
        let source = FixtureSource(nodes: [
            0: .container([1]),
            1: .item("File", children: [2, 3]),
            2: .item("Open", keys: "⌘O"),
            3: .container([3]),
        ])
        let snapshot = try readFixture(source: source, budget: MenuReadBudget(maximumDepth: 2))
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections.flatMap(\.shortcuts).count, 1)
    }

    func testExpiredDeadlineReturnsTruncatedSnapshot() throws {
        let snapshot = try readFixture(budget: MenuReadBudget(duration: .zero))
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertTrue(snapshot.sections.isEmpty)
    }

    func testExactlySufficientNodeBudgetDoesNotTruncate() throws {
        let source = FixtureSource(nodes: [0: .container([1]), 1: .item("Open", keys: "⌘O")])
        let snapshot = try readFixture(source: source, budget: MenuReadBudget(maximumNodes: 2))
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections.first?.title, "Fixture")
    }

    func testCancellationPropagatesInsteadOfReturningSnapshot() {
        let finished = expectation(description: "Cancelled traversal finishes")
        Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(
                try readMenuTree(
                    source: FixtureSource.standard, root: 0,
                    applicationName: "Fixture", processIdentifier: 42
                )
            ) { error in
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testDisappearingDescendantPreservesEarlierAndLaterShortcuts() throws {
        for error in [MenuReaderError.menuUnavailable, .applicationUnavailable] {
            for failsOnChildren in [false, true] {
                let source = DisappearingSource(error: error, failsOnChildren: failsOnChildren)
                let snapshot = try readMenuTree(
                    source: source, root: 0, applicationName: "Fixture", processIdentifier: 42
                )
                XCTAssertTrue(snapshot.isTruncated)
                XCTAssertEqual(snapshot.sections.map(\.title), ["File", "Edit"])
                XCTAssertEqual(snapshot.sections.flatMap(\.shortcuts).map(\.title), ["Open", "Save", "Copy"])
                XCTAssertEqual(snapshot.sections[0].shortcuts.map(\.isEnabled), [false, false])
            }
        }
    }

    func testRootAndPermissionFailuresRemainFatal() {
        for failsOnChildren in [false, true] {
            for error in [MenuReaderError.menuUnavailable, .applicationUnavailable, .permissionRequired] {
                let source = DisappearingSource(error: error, failsOnChildren: failsOnChildren, failureElement: 0)
                XCTAssertThrowsError(
                    try readMenuTree(
                        source: source, root: 0, applicationName: "Fixture", processIdentifier: 42
                    )
                ) { actual in
                    switch (error, actual) {
                    case (.menuUnavailable, MenuReaderError.menuUnavailable),
                        (.applicationUnavailable, MenuReaderError.applicationUnavailable),
                        (.permissionRequired, MenuReaderError.permissionRequired):
                        break
                    default: XCTFail("Unexpected root error: \(actual)")
                    }
                }
            }
            let source = DisappearingSource(error: .permissionRequired, failsOnChildren: failsOnChildren)
            XCTAssertThrowsError(
                try readMenuTree(
                    source: source, root: 0, applicationName: "Fixture", processIdentifier: 42
                )
            ) { error in
                guard case MenuReaderError.permissionRequired = error else {
                    return XCTFail("Unexpected permission error: \(error)")
                }
            }
        }
    }

    func testArbitraryErrorsAndSourceCancellationRemainFatal() {
        for failsOnChildren in [false, true] {
            let unexpected = ProbedSource(onRead: { element, children in
                if element == 3 && children == failsOnChildren { throw UnexpectedSourceError() }
            })
            XCTAssertThrowsError(
                try readMenuTree(
                    source: unexpected, root: 0, applicationName: "Fixture", processIdentifier: 42
                )
            ) { XCTAssertTrue($0 is UnexpectedSourceError) }
            let cancelled = ProbedSource(onRead: { element, children in
                if element == 3 && children == failsOnChildren { throw CancellationError() }
            })
            XCTAssertThrowsError(
                try readMenuTree(
                    source: cancelled, root: 0, applicationName: "Fixture", processIdentifier: 42
                )
            ) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    func testFirstProgressPrecedesLaterBlockingFailure() throws {
        var progress: [MenuSnapshot] = []
        var progressBeforeBlocking = false
        let source = ProbedSource(onRead: { element, children in
            if element == 4 && !children {
                progressBeforeBlocking =
                    progress.count == 1
                    && progress[0].sections.flatMap(\.shortcuts).map(\.title) == ["Open"]
                Thread.sleep(forTimeInterval: 0.06)
                throw MenuReaderError.menuUnavailable
            }
        })
        let snapshot = try readMenuTree(
            source: source, root: 0, applicationName: "Fixture", processIdentifier: 42,
            onProgress: { progress.append($0) }
        )
        XCTAssertTrue(progressBeforeBlocking)
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(
            snapshot.sections.flatMap(\.shortcuts).map(\.title), ["Open", "Other", "Open", "Open", "Another Action"])
        for partial in progress {
            XCTAssertTrue(partial.isTruncated)
            XCTAssertFalse(partial.sections.isEmpty)
            let shortcuts = partial.sections.flatMap(\.shortcuts)
            XCTAssertEqual(shortcuts, Array(snapshot.sections.flatMap(\.shortcuts).prefix(shortcuts.count)))
            XCTAssertEqual(Set(shortcuts.map(\.id)).count, shortcuts.count)
        }
    }

    func testProgressRetainsNodeShortcutWhenItsChildrenDisappear() throws {
        let source = ProbedSource(onRead: { element, children in
            if element == 3 && children { throw MenuReaderError.applicationUnavailable }
        })
        var progress: [MenuSnapshot] = []
        let snapshot = try readMenuTree(
            source: source, root: 0, applicationName: "Fixture", processIdentifier: 42,
            onProgress: { progress.append($0) }
        )
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections[0].shortcuts.first?.title, "Open")
        XCTAssertEqual(progress.first?.sections.first?.shortcuts.first?.title, "Open")
    }

    func testProgressIsThrottledAndFlushesAtSectionCompletion() throws {
        var nodes: [Int: FixtureSource.Node] = [0: .container([1]), 1: .item("File", children: Array(2...97))]
        for element in 2...97 { nodes[element] = .item("Action \(element)", keys: "⌘O") }
        var progress: [MenuSnapshot] = []
        let snapshot = try readMenuTree(
            source: FixtureSource(nodes: nodes), root: 0, applicationName: "Fixture", processIdentifier: 42,
            onProgress: { progress.append($0) }
        )
        let counts = progress.map { $0.sections.flatMap(\.shortcuts).count }
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts.last, 96)
        XCTAssertLessThan(counts.count, 20, "Do not publish for every item")
        for (before, after) in zip(counts, counts.dropFirst()) {
            XCTAssertGreaterThan(after, before)
            XCTAssertLessThanOrEqual(after - before, 32)
        }
        XCTAssertTrue(progress.allSatisfy(\.isTruncated))
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.sections[0].shortcuts.map(\.title), (2...97).map { "Action \($0)" })
    }

    func testElapsedTimePublishesBeforeSectionCompletion() throws {
        var progress: [MenuSnapshot] = []
        var deliveredBeforeNextRead = false
        let source = ProbedSource(onRead: { element, children in
            if element == 5 && !children { Thread.sleep(forTimeInterval: 0.06) }
            if element == 5 && children { deliveredBeforeNextRead = progress.count >= 2 }
        })
        _ = try readMenuTree(
            source: source, root: 0, applicationName: "Fixture", processIdentifier: 42,
            onProgress: { progress.append($0) }
        )
        XCTAssertTrue(deliveredBeforeNextRead)
    }

    func testEmptyAndExpiredReadsDoNotPublishProgress() throws {
        var count = 0
        for budget in [MenuReadBudget(), MenuReadBudget(duration: .zero)] {
            _ = try readMenuTree(
                source: FixtureSource(nodes: [0: .container([])]), root: 0,
                applicationName: "Fixture", processIdentifier: 42, budget: budget,
                onProgress: { _ in count += 1 }
            )
        }
        XCTAssertEqual(count, 0)
    }

    func testCancellationStopsProgressAndFurtherReads() async {
        for stage in 0...3 {
            let passed = await Task.detached {
                var callbacks = 0
                var cancelled = false
                var readsAfterCancellation = 0
                let source = ProbedSource(onRead: { element, children in
                    if cancelled { readsAfterCancellation += 1 }
                    if stage == 0 && element == 3 && !children
                        || stage == 2 && element == 3 && !children
                        || stage == 3 && element == 3 && children
                    {
                        withUnsafeCurrentTask { $0?.cancel() }
                        cancelled = true
                        if stage == 2 { throw MenuReaderError.menuUnavailable }
                    }
                })
                do {
                    _ = try readMenuTree(
                        source: source, root: 0, applicationName: "Fixture", processIdentifier: 42,
                        onProgress: { _ in
                            callbacks += 1
                            if stage == 1 {
                                withUnsafeCurrentTask { $0?.cancel() }
                                cancelled = true
                            }
                        }
                    )
                    return false
                } catch is CancellationError {
                    return callbacks == (stage == 1 || stage == 3 ? 1 : 0) && readsAfterCancellation == 0
                } catch { return false }
            }.value
            XCTAssertTrue(passed, "Cancellation at stage \(stage)")
        }
    }

    func testSourceFailurePropagates() {
        XCTAssertThrowsError(
            try readMenuTree(
                source: FailingSource(), root: 0, applicationName: "Fixture", processIdentifier: 42
            )
        ) { error in
            guard case MenuReaderError.menuUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidProcessDoesNotRequireAccessibilityPermission() {
        for pid: Int32 in [0, -1] {
            XCTAssertThrowsError(try MenuReader().read(processIdentifier: pid, applicationName: "Invalid")) { error in
                guard case MenuReaderError.applicationUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testErrorsHaveDescriptiveEnglishMessages() {
        for error in [MenuReaderError.permissionRequired, .applicationUnavailable, .menuUnavailable] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }

    private func key(
        _ character: String?, modifiers: UInt32?, glyph: Int? = nil, virtualKey: Int? = nil
    ) -> String? {
        MenuKeyFormatter.format(character: character, modifiers: modifiers, glyph: glyph, virtualKey: virtualKey)
    }

    private func readFixture(
        source: FixtureSource = .standard, budget: MenuReadBudget = MenuReadBudget()
    ) throws -> MenuSnapshot {
        try readMenuTree(
            source: source, root: 0, applicationName: "Fixture", processIdentifier: 42, budget: budget
        )
    }
}

private struct FixtureSource: MenuTreeSource {
    struct Node {
        let item: MenuTreeItem?
        let children: [Int]

        static func container(_ children: [Int]) -> Node { Node(item: nil, children: children) }

        static func item(_ title: String, keys: String? = nil, enabled: Bool = true, children: [Int] = []) -> Node {
            Node(item: MenuTreeItem(title: title, keys: keys, isEnabled: enabled), children: children)
        }
    }

    let nodes: [Int: Node]

    static var standard: FixtureSource {
        FixtureSource(nodes: [
            0: .container([1, 10, 13]),
            1: .item("File", children: [2]),
            2: .container([3, 4, 5, 6, 7]),
            3: .item("Open", keys: "⌘O"),
            4: .item("Open", keys: "⌘O"),
            5: .item("Other", keys: "⌘O", enabled: false),
            6: .item("Open", keys: "⌘P"),
            7: .item("Recent", children: [8]),
            8: .container([9]),
            9: .item("Open", keys: "⌘O"),
            10: .item("Edit", children: [11]),
            11: .container([12]),
            12: .item("Another Action", keys: "⌘O"),
            13: .item("Help", children: [14]),
            14: .item("No shortcut"),
        ])
    }

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? { nodes[element]?.item }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        let children = nodes[element]?.children ?? []
        return MenuTreeChildren(elements: Array(children.prefix(limit)), hasMore: children.count > limit)
    }
}

private struct DisappearingSource: MenuTreeSource {
    let error: MenuReaderError
    let failsOnChildren: Bool
    var failureElement = 3
    private let fixture = FixtureSource(nodes: [
        0: .container([1, 6]),
        1: .item("File", enabled: false, children: [2, 3, 4, 5]),
        2: .item("Open", keys: "⌘O"),
        3: .container([8]),
        4: .item("Save", keys: "⌘S"),
        5: .item("Open", keys: "⌘O"),
        6: .item("Edit", children: [7]),
        7: .item("Copy", keys: "⌘C"),
        8: .item("Lost", keys: "⌘L"),
    ])

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        if element == failureElement && !failsOnChildren { throw error }
        return try fixture.item(for: element, budget: budget)
    }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        if element == failureElement && failsOnChildren { throw error }
        return try fixture.children(of: element, limit: limit, budget: budget)
    }
}

private struct UnexpectedSourceError: Error {}

private struct ProbedSource: MenuTreeSource {
    let onRead: (Int, Bool) throws -> Void

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        try onRead(element, false)
        return try FixtureSource.standard.item(for: element, budget: budget)
    }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        try onRead(element, true)
        return try FixtureSource.standard.children(of: element, limit: limit, budget: budget)
    }
}

private struct FailingSource: MenuTreeSource {
    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        throw MenuReaderError.menuUnavailable
    }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        MenuTreeChildren(elements: [], hasMore: false)
    }
}
