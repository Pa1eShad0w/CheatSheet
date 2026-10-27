import ApplicationServices
import Carbon.HIToolbox
import XCTest

@testable import CheatSheetCore

final class MenuAttributeTests: XCTestCase {
    func testMenuItemUsesTwoAttributeRequests() throws {
        let transport = FakeMenuAttributes()
        let item = try read(transport)
        XCTAssertEqual(item?.title, "Open")
        XCTAssertEqual(item?.keys, "⌘O")
        XCTAssertEqual(item?.isEnabled, false)
        XCTAssertEqual(transport.singleRequests, [kAXRoleAttribute])
        XCTAssertEqual(
            transport.batchRequests,
            [
                [
                    kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
                    kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
                ]
            ])
        XCTAssertEqual(transport.timeouts, [0.2], "Do not repeat identical timeout setups within an item read")
    }

    func testNonMenuContainersOnlyReadRole() throws {
        for role: CFTypeRef in [kAXMenuRole as CFString, kAXMenuBarRole as CFString, NSNumber(value: 1), kCFNull!] {
            let transport = FakeMenuAttributes()
            transport.values[kAXRoleAttribute] = role
            XCTAssertNil(try read(transport))
            XCTAssertEqual(transport.singleRequests, [kAXRoleAttribute])
            XCTAssertTrue(transport.batchRequests.isEmpty)
        }
        let transport = FakeMenuAttributes()
        transport.values[kAXRoleAttribute] = kAXMenuBarItemRole as CFString
        XCTAssertEqual(try read(transport)?.keys, "⌘O")
        transport.values[kAXRoleAttribute] = nil
        XCTAssertNil(try read(transport))
    }

    func testUnavailableAttributesPreserveDefaults() throws {
        for unavailable: CFTypeRef in [errorValue(.noValue), errorValue(.attributeUnsupported), kCFNull!] {
            let transport = FakeMenuAttributes()
            for name in [
                kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdVirtualKeyAttribute,
                kAXEnabledAttribute,
            ] {
                transport.values[name] = unavailable
            }
            let item = try read(transport)
            XCTAssertEqual(item?.keys, "⌘O", "Missing modifiers default to Command")
            XCTAssertEqual(item?.isEnabled, true)
            transport.values[kAXTitleAttribute] = unavailable
            transport.values[kAXMenuItemCmdCharAttribute] = unavailable
            let empty = try read(transport)
            XCTAssertEqual(empty?.title, "")
            XCTAssertNil(empty?.keys, "Missing fields must not invent shortcuts")
        }
    }

    func testStrictTypesIntegerValidationAndKeyPrecedence() throws {
        let transport = FakeMenuAttributes()
        transport.values[kAXTitleAttribute] = NSNumber(value: 9)
        transport.values[kAXMenuItemCmdCharAttribute] = NSNumber(value: 9)
        transport.values[kAXMenuItemCmdGlyphAttribute] = kCFBooleanTrue!
        transport.values[kAXMenuItemCmdVirtualKeyAttribute] = NSNumber(value: kVK_F2)
        transport.values[kAXMenuItemCmdModifiersAttribute] = NSNumber(value: 1.5)
        transport.values[kAXEnabledAttribute] = NSNumber(value: 0)
        let item = try read(transport)
        XCTAssertEqual(item?.title, "")
        XCTAssertEqual(item?.keys, "⌘F2")
        XCTAssertEqual(item?.isEnabled, true, "Only CFBoolean controls enabled state")
        for modifiers in [NSNumber(value: -1), NSNumber(value: UInt64.max), kCFBooleanTrue!, "8" as CFString] {
            transport.values[kAXMenuItemCmdModifiersAttribute] = modifiers
            XCTAssertEqual(try read(transport)?.keys, "⌘F2")
        }
        transport.values[kAXMenuItemCmdCharAttribute] = "x" as CFString
        transport.values[kAXMenuItemCmdGlyphAttribute] = NSNumber(value: kMenuF1Glyph)
        transport.values[kAXMenuItemCmdModifiersAttribute] = NSNumber(value: 15)
        XCTAssertEqual(try read(transport)?.keys, "⌃⌥⇧X")
        transport.values[kAXMenuItemCmdCharAttribute] = errorValue(.noValue)
        XCTAssertEqual(try read(transport)?.keys, "⌃⌥⇧F1")
        var point = CGPoint.zero
        transport.values[kAXMenuItemCmdGlyphAttribute] = AXValueCreate(.cgPoint, &point)!
        XCTAssertEqual(try read(transport)?.keys, "⌃⌥⇧F2", "Other AXValue types are not numbers or error sentinels")
    }

    func testRoleErrorsStopBeforeBatch() {
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement] {
            let transport = FakeMenuAttributes()
            transport.singleErrors[kAXRoleAttribute] = error
            assertError(error) { _ = try self.read(transport) }
            XCTAssertTrue(transport.batchRequests.isEmpty)
        }
    }

    func testPerAttributeErrorsAreNotTreatedAsMissingValues() {
        for name in [
            kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
        ] {
            for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure, .notImplemented, .success]
            {
                let transport = FakeMenuAttributes()
                transport.values[name] = errorValue(error)
                assertError(error) { _ = try self.read(transport) }
                XCTAssertEqual(transport.singleRequests, [kAXRoleAttribute], "No fallback concealing per-field errors")
            }
        }
    }

    func testPerAttributeTransientFailureSkipsOnlyItsDescendant() throws {
        for name in [
            kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
            kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
        ] {
            for error in [AXError.cannotComplete, .invalidUIElement] {
                let transport = FakeMenuAttributes()
                transport.values[name] = errorValue(error)
                let snapshot = try readMenuTree(
                    source: AttributeTraversalSource(transport: transport), root: 0,
                    applicationName: "Fixture", processIdentifier: 42
                )
                XCTAssertTrue(snapshot.isTruncated)
                XCTAssertEqual(snapshot.sections[0].shortcuts.map(\.title), ["Before", "After"])
                XCTAssertEqual(snapshot.sections[0].shortcuts.map(\.isEnabled), [false, false])
                XCTAssertEqual(transport.singleRequests, [kAXRoleAttribute], "No retry or silent defaults")
                XCTAssertEqual(transport.batchRequests.count, 1)
            }
        }
    }

    func testPerAttributePermissionFailureStillAbortsTraversal() {
        let transport = FakeMenuAttributes()
        transport.values[kAXMenuItemCmdGlyphAttribute] = errorValue(.apiDisabled)
        assertError(.apiDisabled) {
            _ = try readMenuTree(
                source: AttributeTraversalSource(transport: transport), root: 0,
                applicationName: "Fixture", processIdentifier: 42
            )
        }
    }

    func testRealBatchErrorsAreNotRetried() {
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            let transport = FakeMenuAttributes()
            transport.batchReply = (error, nil)
            assertError(error) { _ = try self.read(transport) }
            XCTAssertEqual(transport.singleRequests, [kAXRoleAttribute])
        }
    }

    func testUnsupportedAndMalformedBatchesFallBackToSingleReads() throws {
        let replies: [(AXError, CFArray?)] = [
            (.notImplemented, nil), (.attributeUnsupported, nil), (.noValue, nil), (.illegalArgument, nil),
            (.success, nil), (.success, [] as CFArray), (.success, ["short"] as CFArray),
            (.success, Array(repeating: "extra", count: 7) as CFArray),
        ]
        for reply in replies {
            let transport = FakeMenuAttributes()
            transport.batchReply = reply
            transport.values[kAXMenuItemCmdModifiersAttribute] = nil
            transport.singleErrors[kAXMenuItemCmdGlyphAttribute] = .attributeUnsupported
            let item = try read(transport)
            XCTAssertEqual(item?.title, "Open")
            XCTAssertEqual(item?.keys, "⌘O")
            XCTAssertEqual(item?.isEnabled, false)
            XCTAssertEqual(transport.singleRequests.count, 7)
            XCTAssertEqual(transport.batchRequests.count, 1)
            XCTAssertEqual(transport.timeouts, [0.2])
            transport.singleErrors[kAXTitleAttribute] = .cannotComplete
            assertError(.cannotComplete) { _ = try self.read(transport) }
        }
    }

    func testTimeoutSetupFailureStopsRequests() {
        let transport = FakeMenuAttributes()
        transport.timeoutError = .apiDisabled
        assertError(.apiDisabled) { _ = try self.read(transport) }
        XCTAssertTrue(transport.singleRequests.isEmpty)
        XCTAssertTrue(transport.batchRequests.isEmpty)
    }

    func testDeadlineStopsRequestsAndRefreshesTimeoutBelowCap() throws {
        let expired = FakeMenuAttributes()
        let expiredBudget = MenuReadBudget(duration: .zero)
        XCTAssertThrowsError(try read(expired, budget: expiredBudget))
        XCTAssertTrue(expiredBudget.isTruncated)
        XCTAssertTrue(expired.timeouts.isEmpty)
        XCTAssertTrue(expired.singleRequests.isEmpty)

        let transport = FakeMenuAttributes()
        transport.onSingle = { _ in Thread.sleep(forTimeInterval: 0.01) }
        _ = try read(transport, budget: MenuReadBudget(duration: .milliseconds(100)))
        XCTAssertEqual(transport.timeouts.count, 2)
        XCTAssertTrue(transport.timeouts.allSatisfy { $0 > 0 && $0 <= 0.2 })
        if transport.timeouts.count == 2 { XCTAssertLessThan(transport.timeouts[1], transport.timeouts[0]) }
    }

    func testDeadlineIsCheckedAfterBatchReply() {
        let transport = FakeMenuAttributes()
        transport.onBatch = { Thread.sleep(forTimeInterval: 0.03) }
        let budget = MenuReadBudget(duration: .milliseconds(20))
        XCTAssertThrowsError(try read(transport, budget: budget))
        XCTAssertTrue(budget.isTruncated)
        XCTAssertEqual(transport.batchRequests.count, 1)
    }

    func testCancellationStopsBeforeAndAfterReadsIncludingFallback() async {
        for stage in 0...3 {
            let passed = await Task.detached {
                let transport = FakeMenuAttributes()
                switch stage {
                case 0: withUnsafeCurrentTask { $0?.cancel() }
                case 1: transport.onSingle = { _ in withUnsafeCurrentTask { $0?.cancel() } }
                case 2: transport.onBatch = { withUnsafeCurrentTask { $0?.cancel() } }
                default:
                    transport.batchReply = (.notImplemented, nil)
                    transport.onSingle = { name in
                        if name == kAXTitleAttribute { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                do {
                    _ = try AccessibilityMenuSource(attributes: transport).item(
                        for: AXUIElementCreateApplication(42), budget: MenuReadBudget()
                    )
                    return false
                } catch is CancellationError {
                    return transport.singleRequests.count == [0, 1, 1, 2][stage]
                        && transport.batchRequests.count == [0, 0, 1, 1][stage]
                } catch { return false }
            }.value
            XCTAssertTrue(passed, "Cancellation at stage \(stage)")
        }
    }

    private func read(_ transport: FakeMenuAttributes, budget: MenuReadBudget = MenuReadBudget()) throws
        -> MenuTreeItem?
    {
        try AccessibilityMenuSource(attributes: transport).item(for: AXUIElementCreateApplication(42), budget: budget)
    }

    private func assertError(
        _ expected: AXError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            switch (expected, error) {
            case (.apiDisabled, MenuReaderError.permissionRequired),
                (.invalidUIElement, MenuReaderError.applicationUnavailable):
                break
            default:
                guard expected != .apiDisabled && expected != .invalidUIElement,
                    case MenuReaderError.menuUnavailable = error
                else { return XCTFail("Incorrect AX error classification: \(error)", file: file, line: line) }
            }
        }
    }
}

private struct AttributeTraversalSource: MenuTreeSource {
    let transport: FakeMenuAttributes

    func item(for element: Int, budget: MenuReadBudget) throws -> MenuTreeItem? {
        switch element {
        case 0: return nil
        case 1: return MenuTreeItem(title: "File", keys: nil, isEnabled: false)
        case 3:
            return try AccessibilityMenuSource(attributes: transport).item(
                for: AXUIElementCreateApplication(42), budget: budget)
        default:
            return MenuTreeItem(title: element == 2 ? "Before" : "After", keys: "⌘O", isEnabled: true)
        }
    }

    func children(of element: Int, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Int> {
        let children: [Int]
        switch element {
        case 0: children = [1]
        case 1: children = [2, 3, 4]
        default: children = []
        }
        return MenuTreeChildren(elements: Array(children.prefix(limit)), hasMore: children.count > limit)
    }
}

private final class FakeMenuAttributes: MenuAttributeTransport {
    var singleRequests: [String] = []
    var batchRequests: [[String]] = []
    var timeouts: [Float] = []
    var timeoutError = AXError.success
    var singleErrors: [String: AXError] = [:]
    var batchReply: (AXError, CFArray?)?
    var onSingle: ((String) -> Void)?
    var onBatch: (() -> Void)?
    var values: [String: CFTypeRef] = [
        kAXRoleAttribute: kAXMenuItemRole as CFString,
        kAXTitleAttribute: "Open" as CFString,
        kAXMenuItemCmdCharAttribute: "o" as CFString,
        kAXMenuItemCmdGlyphAttribute: NSNumber(value: 0),
        kAXMenuItemCmdVirtualKeyAttribute: NSNumber(value: 0),
        kAXMenuItemCmdModifiersAttribute: NSNumber(value: 0),
        kAXEnabledAttribute: kCFBooleanFalse!,
    ]

    func setMessagingTimeout(_ timeout: Float, for element: AXUIElement) -> AXError {
        timeouts.append(timeout)
        return timeoutError
    }

    func copyAttribute(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        singleRequests.append(name)
        onSingle?(name)
        if let error = singleErrors[name] { return (error, nil) }
        guard let value = values[name] else { return (.noValue, nil) }
        return (.success, value)
    }

    func copyMultipleAttributes(_ names: [String], of element: AXUIElement) -> (AXError, CFArray?) {
        batchRequests.append(names)
        onBatch?()
        if let batchReply { return batchReply }
        return (.success, names.map { values[$0] ?? errorValue(.noValue) } as CFArray)
    }
}

private func errorValue(_ error: AXError) -> AXValue {
    var error = error
    return AXValueCreate(.axError, &error)!
}
