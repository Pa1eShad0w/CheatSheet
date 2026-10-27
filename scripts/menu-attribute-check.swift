// Run separately from core-check.swift (each has its own @main):
// swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors Sources/CheatSheetCore/*.swift scripts/menu-attribute-check.swift -o .build/menu-attribute-check
// .build/menu-attribute-check
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@main
private enum MenuAttributeCheck {
    static func main() async {
        do {
            try checkRequests()
            try checkContainersAndRoleErrors()
            try checkMissingAndTypedValues()
            try checkErrorsAndFallback()
            try checkBudgets()
            try await checkCancellation()
            print(
                "Menu attribute checks passed: request counts, containers, AX error sentinels, types/defaults, fallback, budgets, cancellation."
            )
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func checkRequests() throws {
        let transport = CheckAttributes()
        let item = try read(transport)
        try require(item?.title == "Open" && item?.keys == "⌘O" && item?.isEnabled == false, "Item semantics")
        let requests = transport.singleRequests.count + transport.batchRequests.count
        print(
            "Menu-item attribute requests: \(requests) (single=\(transport.singleRequests.count), batch=\(transport.batchRequests.count)); timeout setups=\(transport.timeouts.count)"
        )
        try require(requests == 2, "Expected one role request plus one item-field batch, not seven single reads")
        try require(transport.singleRequests == [kAXRoleAttribute], "Read role separately")
        try require(
            transport.batchRequests == [
                [
                    kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
                    kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
                ]
            ], "Batch all six item fields in order")
        try require(transport.timeouts == [0.2], "Do not repeat an identical timeout setup for the same item")
    }

    private static func checkContainersAndRoleErrors() throws {
        for role: CFTypeRef in [kAXMenuRole as CFString, kAXMenuBarRole as CFString, NSNumber(value: 1), kCFNull!] {
            let transport = CheckAttributes()
            transport.values[kAXRoleAttribute] = role
            try require(try read(transport) == nil, "Non-item role must not produce a shortcut")
            try require(
                transport.singleRequests.count == 1 && transport.batchRequests.isEmpty, "Containers stay role-only")
        }
        let barItem = CheckAttributes()
        barItem.values[kAXRoleAttribute] = kAXMenuBarItemRole as CFString
        try require(try read(barItem)?.keys == "⌘O", "Menu bar items still supported")
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement] {
            let transport = CheckAttributes()
            transport.singleErrors[kAXRoleAttribute] = error
            try expectError(error) { _ = try read(transport) }
            try require(transport.batchRequests.isEmpty, "A role error must not trigger an item-field batch")
        }
    }

    private static func checkMissingAndTypedValues() throws {
        for missing: CFTypeRef in [axError(.noValue), axError(.attributeUnsupported), kCFNull!] {
            let transport = CheckAttributes()
            transport.values[kAXMenuItemCmdModifiersAttribute] = missing
            transport.values[kAXMenuItemCmdGlyphAttribute] = missing
            transport.values[kAXMenuItemCmdVirtualKeyAttribute] = missing
            transport.values[kAXEnabledAttribute] = missing
            let item = try read(transport)
            try require(item?.keys == "⌘O" && item?.isEnabled == true, "Unavailable optional fields retain defaults")
            transport.values[kAXTitleAttribute] = missing
            transport.values[kAXMenuItemCmdCharAttribute] = missing
            let empty = try read(transport)
            try require(empty?.title == "" && empty?.keys == nil, "Missing title/key does not invent a shortcut")
        }
        let transport = CheckAttributes()
        transport.values[kAXTitleAttribute] = NSNumber(value: 9)
        transport.values[kAXMenuItemCmdCharAttribute] = NSNumber(value: 9)
        transport.values[kAXMenuItemCmdGlyphAttribute] = kCFBooleanTrue!
        transport.values[kAXMenuItemCmdVirtualKeyAttribute] = NSNumber(value: kVK_F2)
        transport.values[kAXMenuItemCmdModifiersAttribute] = NSNumber(value: 1.5)
        transport.values[kAXEnabledAttribute] = NSNumber(value: 0)
        let item = try read(transport)
        try require(
            item?.title == "" && item?.keys == "⌘F2" && item?.isEnabled == true,
            "Preserve strict CF type checks and integer validation")
        for modifiers in [NSNumber(value: -1), NSNumber(value: UInt64.max), kCFBooleanTrue!, "8" as CFString] {
            transport.values[kAXMenuItemCmdModifiersAttribute] = modifiers
            try require(try read(transport)?.keys == "⌘F2", "Invalid modifiers use default Command")
        }
        transport.values[kAXMenuItemCmdCharAttribute] = "x" as CFString
        transport.values[kAXMenuItemCmdGlyphAttribute] = NSNumber(value: kMenuF1Glyph)
        transport.values[kAXMenuItemCmdModifiersAttribute] = NSNumber(value: 15)
        try require(try read(transport)?.keys == "⌃⌥⇧X", "Character precedence and no-Command modifier semantics")
        transport.values[kAXMenuItemCmdCharAttribute] = axError(.noValue)
        try require(try read(transport)?.keys == "⌃⌥⇧F1", "Glyph precedes virtual key")
        var point = CGPoint.zero
        transport.values[kAXMenuItemCmdGlyphAttribute] = AXValueCreate(.cgPoint, &point)!
        try require(try read(transport)?.keys == "⌃⌥⇧F2", "Other AXValue types are not numbers or error sentinels")
    }

    private static func checkErrorsAndFallback() throws {
        for field in [
            kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
        ] {
            for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure, .notImplemented, .success]
            {
                let transport = CheckAttributes()
                transport.values[field] = axError(error)
                try expectError(error) { _ = try read(transport) }
                try require(
                    transport.singleRequests == [kAXRoleAttribute], "Do not hide per-field errors behind fallback")
            }
        }
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            let transport = CheckAttributes()
            transport.batchReply = (error, nil)
            try expectError(error) { _ = try read(transport) }
            try require(transport.singleRequests.count == 1, "Do not retry real batch failures")
        }
        let fallbackReplies: [(AXError, CFArray?)] = [
            (.notImplemented, nil), (.attributeUnsupported, nil), (.noValue, nil), (.illegalArgument, nil),
            (.success, nil), (.success, [] as CFArray), (.success, ["incorrect"] as CFArray),
            (.success, Array(repeating: "extra", count: 7) as CFArray),
        ]
        for reply in fallbackReplies {
            let transport = CheckAttributes()
            transport.batchReply = reply
            transport.values[kAXMenuItemCmdModifiersAttribute] = nil
            let item = try read(transport)
            try require(
                item?.title == "Open" && item?.keys == "⌘O" && item?.isEnabled == false,
                "Single-read fallback preserves semantics")
            try require(
                transport.singleRequests.count == 7 && transport.batchRequests.count == 1,
                "Fallback is one batch then six singles")
            try require(transport.timeouts == [0.2], "Fallback must not reset identical timeouts")
            transport.singleErrors[kAXTitleAttribute] = .cannotComplete
            try expectError(.cannotComplete) { _ = try read(transport) }
        }
        let timeoutFailure = CheckAttributes()
        timeoutFailure.timeoutError = .apiDisabled
        try expectError(.apiDisabled) { _ = try read(timeoutFailure) }
        try require(
            timeoutFailure.singleRequests.isEmpty && timeoutFailure.batchRequests.isEmpty,
            "Timeout setup failure stops requests")
    }

    private static func checkBudgets() throws {
        let expired = CheckAttributes()
        let expiredBudget = MenuReadBudget(duration: .zero)
        try expectTruncation(expiredBudget) { _ = try read(expired, budget: expiredBudget) }
        try require(
            expired.timeouts.isEmpty && expired.singleRequests.isEmpty, "Expired budget must not issue AX requests")

        let transport = CheckAttributes()
        transport.onSingle = { _ in Thread.sleep(forTimeInterval: 0.01) }
        _ = try read(transport, budget: MenuReadBudget(duration: .milliseconds(100)))
        try require(transport.timeouts.count == 2, "Refresh timeout when remaining budget shrinks below the cap")
        try require(transport.timeouts.allSatisfy { $0 > 0 && $0 <= 0.2 }, "Never use AX's unbounded zero timeout")
        try require(
            transport.timeouts[1] < transport.timeouts[0], "Second request is bounded by the remaining deadline")

        let overrun = CheckAttributes()
        overrun.onBatch = { Thread.sleep(forTimeInterval: 0.03) }
        let budget = MenuReadBudget(duration: .milliseconds(20))
        try expectTruncation(budget) { _ = try read(overrun, budget: budget) }
        try require(overrun.batchRequests.count == 1, "Exercise post-batch deadline check")
    }

    private static func checkCancellation() async throws {
        for stage in 0...3 {
            let passed = await Task.detached {
                let transport = CheckAttributes()
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
                    _ = try read(transport)
                    return false
                } catch is CancellationError {
                    return transport.singleRequests.count == [0, 1, 1, 2][stage]
                        && transport.batchRequests.count == [0, 0, 1, 1][stage]
                } catch { return false }
            }.value
            try require(passed, "Cancellation must propagate and stop requests at stage \(stage)")
        }
    }

    private static func read(_ transport: CheckAttributes, budget: MenuReadBudget = MenuReadBudget()) throws
        -> MenuTreeItem?
    {
        try AccessibilityMenuSource(attributes: transport).item(for: AXUIElementCreateApplication(42), budget: budget)
    }
}

private final class CheckAttributes: MenuAttributeTransport {
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
        return (.success, names.map { values[$0] ?? axError(.noValue) } as CFArray)
    }
}

private func axError(_ error: AXError) -> AXValue {
    var error = error
    return AXValueCreate(.axError, &error)!
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}

private func expectTruncation(_ budget: MenuReadBudget, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        try require(budget.isTruncated, "Deadline failure must mark truncation")
        return
    }
    throw CheckFailure(description: "Expired budget must throw")
}

private func expectError(_ error: AXError, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let actual as MenuReaderError {
        switch (error, actual) {
        case (.apiDisabled, .permissionRequired), (.invalidUIElement, .applicationUnavailable): return
        default:
            if error != .apiDisabled && error != .invalidUIElement, case .menuUnavailable = actual { return }
            throw CheckFailure(description: "Incorrect AX error classification")
        }
    }
    throw CheckFailure(description: "AX error must propagate rather than invent an item")
}
