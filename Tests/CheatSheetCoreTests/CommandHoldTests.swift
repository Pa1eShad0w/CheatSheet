import CheatSheetCore
import XCTest

final class CommandHoldTests: XCTestCase {
    func testHoldShowsAfterDelayAndHidesOnRelease() {
        var hold = CommandHold()
        XCTAssertFalse(hold.isVisible)
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertFalse(hold.isVisible)
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertTrue(hold.isVisible)
        XCTAssertEqual(hold.handle(.modifiers(command: false, other: false)), [.cancel, .hide])
        XCTAssertFalse(hold.isVisible)
    }

    func testReleaseBeforeDelayCancelsAndIgnoresStaleTimer() {
        var hold = CommandHold()
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertEqual(hold.handle(.modifiers(command: false, other: false)), [.cancel])
        XCTAssertEqual(hold.handle(.delayElapsed), [])
        XCTAssertFalse(hold.isVisible)
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertTrue(hold.isVisible)
    }

    func testNormalCommandShortcutBlocksUntilCommandReleased() {
        assertSuppressionUntilRelease(.keyDown)
    }

    func testMouseDownBlocksUntilCommandReleased() {
        assertSuppressionUntilRelease(.mouseDown)
    }

    func testAddingOtherModifierBlocksUntilCommandReleased() {
        assertSuppressionUntilRelease(.modifiers(command: true, other: true))
    }

    func testCommandPressedWithOtherModifierDoesNotSchedule() {
        var hold = CommandHold()
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: true)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: true)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [])
        XCTAssertEqual(hold.handle(.delayElapsed), [])
        XCTAssertFalse(hold.isVisible)
        // Command's release re-arms even if another modifier remains down.
        XCTAssertEqual(hold.handle(.modifiers(command: false, other: true)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertTrue(hold.isVisible)
    }

    func testOtherModifierWithoutCommandDoesNotBlockNextHold() {
        var hold = CommandHold()
        XCTAssertEqual(hold.handle(.modifiers(command: false, other: true)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: false, other: false)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertTrue(hold.isVisible)
    }

    func testRepeatedFlagsAndTimerEventsDoNotRescheduleOrReshow() {
        var hold = CommandHold()
        let command = CommandHold.Event.modifiers(command: true, other: false)
        let release = CommandHold.Event.modifiers(command: false, other: false)
        XCTAssertEqual(hold.handle(command), [.schedule])
        XCTAssertEqual(hold.handle(command), [])
        XCTAssertEqual(hold.handle(command), [])
        XCTAssertFalse(hold.isVisible)
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertEqual(hold.handle(command), [])
        XCTAssertEqual(hold.handle(.delayElapsed), [])
        XCTAssertTrue(hold.isVisible)
        XCTAssertEqual(hold.handle(release), [.cancel, .hide])
        XCTAssertEqual(hold.handle(release), [])
        XCTAssertEqual(hold.handle(.delayElapsed), [])
        XCTAssertFalse(hold.isVisible)
    }

    func testResetFromEveryPhaseIgnoresStaleTimerAndAllowsFreshHold() {
        let arrangements: [(String, [CommandHold.Event], [CommandHold.Effect])] = [
            ("idle", [], []),
            ("waiting", [.modifiers(command: true, other: false)], [.cancel]),
            ("visible", [.modifiers(command: true, other: false), .delayElapsed], [.cancel, .hide]),
            ("blocked", [.modifiers(command: true, other: false), .keyDown], []),
        ]
        for (phase, events, expected) in arrangements {
            var hold = CommandHold()
            for event in events { _ = hold.handle(event) }
            XCTAssertEqual(hold.handle(.reset), expected, "Reset from \(phase)")
            XCTAssertFalse(hold.isVisible, "Reset from \(phase)")
            XCTAssertEqual(hold.handle(.reset), [], "Repeated reset from \(phase)")
            XCTAssertEqual(hold.handle(.delayElapsed), [], "Stale timer after reset from \(phase)")
            XCTAssertEqual(
                hold.handle(.modifiers(command: true, other: false)), [.schedule], "Fresh hold after \(phase)")
            XCTAssertEqual(hold.handle(.delayElapsed), [.show])
            XCTAssertTrue(hold.isVisible)
        }
    }

    func testLifecycleInvalidationWhileCommandHeldRequiresRelease() {
        for events in [[], [.modifiers(command: true, other: false)], [.modifiers(command: true, other: true)]]
            as [[CommandHold.Event]]
        {
            var hold = CommandHold()
            for event in events { _ = hold.handle(event) }
            _ = hold.handle(.invalidate(command: true))
            XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [])
            XCTAssertEqual(hold.handle(.delayElapsed), [])
            XCTAssertFalse(hold.isVisible)
            XCTAssertEqual(hold.handle(.modifiers(command: false, other: false)), [])
            XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        }
    }

    func testLifecycleInvalidationDismissesVisibleOverlay() {
        var hold = CommandHold()
        _ = hold.handle(.modifiers(command: true, other: false))
        _ = hold.handle(.delayElapsed)
        XCTAssertEqual(hold.handle(.invalidate(command: true)), [.cancel, .hide])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [])
        XCTAssertEqual(hold.handle(.invalidate(command: false)), [])
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
    }

    func testPinnedSheetSurvivesReleaseAndScreenshotChord() {
        var hold = CommandHold()
        _ = hold.handle(.modifiers(command: true, other: false))
        _ = hold.handle(.delayElapsed)
        XCTAssertEqual(hold.handle(.pin), [])
        for event in [
            CommandHold.Event.modifiers(command: false, other: false),
            .modifiers(command: true, other: true), .keyDown,
            .modifiers(command: false, other: false),
        ] {
            XCTAssertEqual(hold.handle(event), [])
            XCTAssertTrue(hold.isPinned)
            XCTAssertTrue(hold.isVisible)
        }
        XCTAssertEqual(hold.handle(.invalidate(command: false)), [.cancel, .hide])
        XCTAssertFalse(hold.isPinned)
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
    }

    func testUnpinRespectsPhysicalCommandState() {
        for command in [false, true] {
            var hold = CommandHold()
            _ = hold.handle(.modifiers(command: true, other: false))
            _ = hold.handle(.delayElapsed)
            _ = hold.handle(.pin)
            XCTAssertEqual(hold.handle(.unpin(command: command)), command ? [] : [.cancel, .hide])
            XCTAssertFalse(hold.isPinned)
            XCTAssertEqual(hold.isVisible, command)
        }
    }

    func testIdleKeyMouseAndTimerEventsDoNotInterfereWithNextHold() {
        var hold = CommandHold()
        for event in [CommandHold.Event.keyDown, .mouseDown, .delayElapsed] {
            XCTAssertEqual(hold.handle(event), [])
            XCTAssertFalse(hold.isVisible)
        }
        XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [.schedule])
        XCTAssertEqual(hold.handle(.delayElapsed), [.show])
        XCTAssertTrue(hold.isVisible)
    }

    private func assertSuppressionUntilRelease(
        _ event: CommandHold.Event, file: StaticString = #filePath, line: UInt = #line
    ) {
        for visible in [false, true] {
            var hold = CommandHold()
            let context = "Event \(event), initially visible: \(visible)"
            XCTAssertEqual(
                hold.handle(.modifiers(command: true, other: false)), [.schedule], context, file: file, line: line)
            if visible {
                XCTAssertEqual(hold.handle(.delayElapsed), [.show], context, file: file, line: line)
            }
            XCTAssertEqual(hold.handle(event), visible ? [.cancel, .hide] : [.cancel], context, file: file, line: line)
            XCTAssertFalse(hold.isVisible, context, file: file, line: line)
            XCTAssertEqual(hold.handle(event), [], context, file: file, line: line)
            XCTAssertEqual(hold.handle(.modifiers(command: true, other: false)), [], context, file: file, line: line)
            XCTAssertEqual(hold.handle(.delayElapsed), [], context, file: file, line: line)
            XCTAssertFalse(hold.isVisible, context, file: file, line: line)
            XCTAssertEqual(hold.handle(.modifiers(command: false, other: false)), [], context, file: file, line: line)
            XCTAssertEqual(
                hold.handle(.modifiers(command: true, other: false)), [.schedule], context, file: file, line: line)
            XCTAssertEqual(hold.handle(.delayElapsed), [.show], context, file: file, line: line)
            XCTAssertTrue(hold.isVisible, context, file: file, line: line)
        }
    }
}
