import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

public enum MenuReaderError: Error, LocalizedError, Sendable {
    case permissionRequired
    case applicationUnavailable
    case menuUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Accessibility permission is required to read application menu shortcuts. Enable it in System Settings > Privacy & Security > Accessibility."
        case .applicationUnavailable:
            "The application is no longer available. Select a running application and try again."
        case .menuUnavailable:
            "The application's menu could not be read. It may be unresponsive or may not expose its menus through Accessibility."
        }
    }
}

public struct MenuReader: Sendable {
    public init() {}

    /// Blocking: call from a background task, not the main actor.
    /// Only reads exposed Accessibility attributes; never opens or activates menus.
    /// Progress is synchronous on the reading thread, nonempty, and provisional
    /// (`isTruncated == true`). Only the returned snapshot reports completion.
    /// Keep callbacks brief; they share the read's deadline and must marshal UI updates.
    public func read(
        processIdentifier: Int32, applicationName: String,
        onProgress: (@Sendable (MenuSnapshot) -> Void)? = nil
    ) throws -> MenuSnapshot {
        try Task.checkCancellation()
        guard processIdentifier > 0,
            kill(processIdentifier, 0) == 0 || errno == EPERM
        else {
            throw MenuReaderError.applicationUnavailable
        }
        guard AXIsProcessTrusted() else { throw MenuReaderError.permissionRequired }

        let budget = MenuReadBudget()
        let source = AccessibilityMenuSource()
        let application = AXUIElementCreateApplication(processIdentifier)
        let menuBar: AXUIElement
        do {
            guard let value = try source.attribute(kAXMenuBarAttribute, of: application, budget: budget),
                CFGetTypeID(value) == AXUIElementGetTypeID()
            else {
                throw MenuReaderError.menuUnavailable
            }
            menuBar = value as! AXUIElement  // Type checked above; AX objects do not support a conditional cast.
        } catch is MenuBudgetExceeded {
            return MenuSnapshot(
                applicationName: applicationName,
                processIdentifier: processIdentifier,
                sections: [],
                isTruncated: true
            )
        }
        return try readMenuTree(
            source: source, root: menuBar, applicationName: applicationName,
            processIdentifier: processIdentifier, budget: budget, onProgress: onProgress
        )
    }
}

// A synchronous, typed seam keeps AX handles local to the reading thread and lets
// traversal tests supply a tree without requesting Accessibility permission.
internal protocol MenuTreeSource {
    associatedtype Element
    func item(for element: Element, budget: MenuReadBudget) throws -> MenuTreeItem?
    func children(of element: Element, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<Element>
}

internal struct MenuTreeItem {
    let title: String
    let keys: String?
    let isEnabled: Bool
}

internal struct MenuTreeChildren<Element> {
    let elements: [Element]
    let hasMore: Bool
}

private struct MenuBudgetExceeded: Error {}

internal final class MenuReadBudget {
    private let deadline: ContinuousClock.Instant
    private let maximumNodes: Int
    let maximumDepth: Int
    private var visitedNodes = 0
    private(set) var isTruncated = false

    init(duration: Duration = .seconds(3), maximumNodes: Int = 4_096, maximumDepth: Int = 16) {
        deadline = ContinuousClock.now.advanced(by: duration)
        self.maximumNodes = max(0, maximumNodes)
        self.maximumDepth = max(0, maximumDepth)
    }

    var remainingNodes: Int { max(0, maximumNodes - visitedNodes) }

    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            markTruncated()
            throw MenuBudgetExceeded()
        }
    }

    func visit() throws {
        try check()
        guard remainingNodes > 0 else {
            markTruncated()
            throw MenuBudgetExceeded()
        }
        visitedNodes += 1
    }

    func markTruncated() { isTruncated = true }

    func messagingTimeout() throws -> Float {
        try check()
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        // Never pass zero: AX interprets it as restoring the unbounded default.
        guard seconds > 0 else { throw MenuBudgetExceeded() }
        return min(0.2, max(Float.leastNonzeroMagnitude, Float(seconds)))
    }
}

internal func readMenuTree<Source: MenuTreeSource>(
    source: Source,
    root: Source.Element,
    applicationName: String,
    processIdentifier: Int32,
    budget: MenuReadBudget = MenuReadBudget(),
    onProgress: ((MenuSnapshot) -> Void)? = nil
) throws -> MenuSnapshot {

    var sections: [ShortcutSection] = []
    var sectionIndices: [String: Int] = [:]
    var shortcutsBySection: [[Shortcut]] = []
    var seen = Set<String>()
    var lastProgressCount = 0
    var lastProgressTime: ContinuousClock.Instant?

    func snapshot(isTruncated: Bool) -> MenuSnapshot {
        MenuSnapshot(
            applicationName: applicationName,
            processIdentifier: processIdentifier,
            sections: sections.enumerated().map { index, section in
                ShortcutSection(id: section.id, title: section.title, shortcuts: shortcutsBySection[index])
            },
            isTruncated: isTruncated
        )
    }

    func emitProgress(sectionCompleted: Bool = false) throws {
        guard let onProgress, seen.count > lastProgressCount else { return }
        try budget.check()
        let now = ContinuousClock.now
        guard
            lastProgressCount == 0 || sectionCompleted || seen.count - lastProgressCount >= 32
                || lastProgressTime.map({ $0.duration(to: now) >= .milliseconds(50) }) == true
        else { return }
        try Task.checkCancellation()
        onProgress(snapshot(isTruncated: true))
        lastProgressCount = seen.count
        lastProgressTime = now
        try Task.checkCancellation()
    }

    func visit(_ element: Source.Element, path: [String], depth: Int, ancestorsEnabled: Bool) throws {
        try budget.visit()
        let item = try source.item(for: element, budget: budget)
        try budget.check()
        let enabled = ancestorsEnabled && (item?.isEnabled ?? true)
        if let item, !item.title.isEmpty, let keys = item.keys {
            let identity = menuIdentity(path + [item.title, keys])
            if seen.insert(identity).inserted {
                let sectionTitle = path.first ?? applicationName
                let sectionID = menuIdentity([sectionTitle])
                let sectionIndex: Int
                if let existing = sectionIndices[sectionID] {
                    sectionIndex = existing
                } else {
                    sectionIndex = sections.count
                    sectionIndices[sectionID] = sectionIndex
                    sections.append(ShortcutSection(id: sectionID, title: sectionTitle, shortcuts: []))
                    shortcutsBySection.append([])
                }
                shortcutsBySection[sectionIndex].append(
                    Shortcut(
                        id: identity, title: item.title, menuPath: path, keys: keys, isEnabled: enabled
                    ))
                try emitProgress()
            }
        }

        let children = try source.children(of: element, limit: budget.remainingNodes, budget: budget)
        try budget.check()
        if children.hasMore { budget.markTruncated() }
        guard !children.elements.isEmpty else { return }
        guard depth < budget.maximumDepth else {
            budget.markTruncated()
            return
        }
        let childPath = item.map { $0.title.isEmpty ? path : path + [$0.title] } ?? path
        for child in children.elements {
            do {
                try visit(child, path: childPath, depth: depth + 1, ancestorsEnabled: enabled)
            } catch let error as MenuReaderError {
                try Task.checkCancellation()
                switch error {
                case .menuUnavailable, .applicationUnavailable:
                    // AX descendants can disappear while their siblings remain readable.
                    // Root reads never pass through this recovery boundary.
                    budget.markTruncated()
                case .permissionRequired:
                    throw error
                }
            }
            if depth == 0 { try emitProgress(sectionCompleted: true) }
        }
    }

    do {
        try visit(root, path: [], depth: 0, ancestorsEnabled: true)
    } catch is MenuBudgetExceeded {
        budget.markTruncated()
    }
    try Task.checkCancellation()
    return snapshot(isTruncated: budget.isTruncated)
}

// Length-prefixing avoids ambiguous IDs when titles contain separators.
private func menuIdentity(_ components: [String]) -> String {
    components.map { "\($0.utf8.count):\($0)" }.joined()
}

// The AX boundary is injectable so request counts and raw AX replies can be
// checked without permission or a live application's menus.
internal protocol MenuAttributeTransport {
    func setMessagingTimeout(_ timeout: Float, for element: AXUIElement) -> AXError
    func copyAttribute(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?)
    func copyMultipleAttributes(_ names: [String], of element: AXUIElement) -> (AXError, CFArray?)
}

private struct SystemMenuAttributeTransport: MenuAttributeTransport {
    func setMessagingTimeout(_ timeout: Float, for element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    func copyAttribute(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    func copyMultipleAttributes(_ names: [String], of element: AXUIElement) -> (AXError, CFArray?) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        return (error, values)
    }
}

internal struct AccessibilityMenuSource: MenuTreeSource {
    private let attributes: any MenuAttributeTransport

    init(attributes: any MenuAttributeTransport = SystemMenuAttributeTransport()) {
        self.attributes = attributes
    }

    func attribute(_ name: String, of element: AXUIElement, budget: MenuReadBudget) throws -> CFTypeRef? {
        var reader = MenuAttributeReader(element: element, transport: attributes, budget: budget)
        return try reader.attribute(name)
    }

    func item(for element: AXUIElement, budget: MenuReadBudget) throws -> MenuTreeItem? {
        var reader = MenuAttributeReader(element: element, transport: attributes, budget: budget)
        guard let role = try reader.attribute(kAXRoleAttribute) as? String,
            role == kAXMenuItemRole || role == kAXMenuBarItemRole
        else { return nil }
        // Keep container reads role-only: their item attributes may be unsupported.
        let values = try reader.multipleAttributes([
            kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
            kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute,
        ])
        let title = values[0] as? String ?? ""
        let character = values[1] as? String
        let glyph = number(values[2])
        let virtualKey = number(values[3])
        let modifiers = number(values[4])
        let enabledValue = values[5]
        let enabled: Bool
        if let enabledValue, CFGetTypeID(enabledValue) == CFBooleanGetTypeID() {
            enabled = CFBooleanGetValue((enabledValue as! CFBoolean))
        } else {
            enabled = true
        }
        return MenuTreeItem(
            title: title,
            keys: MenuKeyFormatter.format(
                character: character, modifiers: modifiers.flatMap(UInt32.init(exactly:)),
                glyph: glyph, virtualKey: virtualKey
            ),
            isEnabled: enabled
        )
    }

    func children(of element: AXUIElement, limit: Int, budget: MenuReadBudget) throws -> MenuTreeChildren<AXUIElement> {
        try prepare(element, budget: budget)
        var count = 0
        let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        try budget.check()
        switch countError {
        case .attributeUnsupported, .noValue:
            return MenuTreeChildren(elements: [], hasMore: false)
        case .success: break
        default: throw classifiedMenuError(countError)
        }
        let requested = min(max(0, limit), count)
        guard requested > 0 else { return MenuTreeChildren(elements: [], hasMore: count > 0) }
        try prepare(element, budget: budget)
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, requested, &values)
        try budget.check()
        guard error == .success else { throw classifiedMenuError(error) }
        guard let values else { throw MenuReaderError.menuUnavailable }
        var elements: [AXUIElement] = []
        for value in values as [AnyObject] {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            elements.append(value as! AXUIElement)
        }
        return MenuTreeChildren(elements: elements, hasMore: count > requested)
    }

    private func number(_ value: CFTypeRef?) -> Int? {
        guard let value,
            CFGetTypeID(value) == CFNumberGetTypeID(),
            let number = value as? NSNumber
        else { return nil }
        let integer = number.int64Value
        guard number.doubleValue == Double(integer) else { return nil }
        return Int(exactly: integer)
    }

    private func prepare(_ element: AXUIElement, budget: MenuReadBudget) throws {
        let error = attributes.setMessagingTimeout(try budget.messagingTimeout(), for: element)
        guard error == .success else { throw classifiedMenuError(error) }
    }
}

private struct MenuAttributeReader {
    let element: AXUIElement
    let transport: any MenuAttributeTransport
    let budget: MenuReadBudget
    private var preparedTimeout: Float?

    init(element: AXUIElement, transport: any MenuAttributeTransport, budget: MenuReadBudget) {
        self.element = element
        self.transport = transport
        self.budget = budget
    }

    mutating func attribute(_ name: String) throws -> CFTypeRef? {
        try prepare()
        let (error, value) = transport.copyAttribute(name, of: element)
        try budget.check()
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: throw classifiedMenuError(error)
        }
    }

    mutating func multipleAttributes(_ names: [String]) throws -> [CFTypeRef?] {
        try prepare()
        let (error, values) = transport.copyMultipleAttributes(names, of: element)
        try budget.check()
        switch error {
        case .success:
            // A malformed/short reply has no reliable positional mapping. Re-read
            // individually rather than treating absent slots as missing attributes.
            guard let values, CFArrayGetCount(values) == names.count else {
                return try names.map { try attribute($0) }
            }
            return try (values as [AnyObject]).map { value in
                if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
                guard CFGetTypeID(value) == AXValueGetTypeID() else { return value }
                let axValue = value as! AXValue  // Type checked above.
                guard AXValueGetType(axValue) == .axError else { return value }
                var attributeError = AXError.failure
                guard AXValueGetValue(axValue, .axError, &attributeError) else {
                    throw MenuReaderError.menuUnavailable
                }
                switch attributeError {
                case .attributeUnsupported, .noValue: return nil
                default: throw classifiedMenuError(attributeError)
                }
            }
        case .notImplemented, .attributeUnsupported, .noValue, .illegalArgument:
            // Some providers support single reads but not this batch operation.
            // Single reads retain the original error handling and budget checks.
            return try names.map { try attribute($0) }
        default:
            throw classifiedMenuError(error)
        }
    }

    private mutating func prepare() throws {
        let timeout = try budget.messagingTimeout()
        // Cache only within this item's read, never across elements or snapshots.
        // Recompute before every request so a nearly exhausted budget still bounds AX.
        guard preparedTimeout != timeout else { return }
        let error = transport.setMessagingTimeout(timeout, for: element)
        guard error == .success else { throw classifiedMenuError(error) }
        preparedTimeout = timeout
    }
}

private func classifiedMenuError(_ error: AXError) -> MenuReaderError {
    switch error {
    case .apiDisabled: .permissionRequired
    case .invalidUIElement: .applicationUnavailable
    default: .menuUnavailable
    }
}

internal enum MenuKeyFormatter {
    static func format(character: String?, modifiers: UInt32?, glyph: Int?, virtualKey: Int?) -> String? {
        guard
            let key = character.flatMap(characterLabel)
                ?? glyph.flatMap(glyphLabel)
                ?? virtualKey.flatMap({ virtualKeyLabels[$0] })
        else { return nil }
        // AX's zero/default mask includes Command; bit 3 explicitly removes it.
        let flags = AXMenuItemModifiers(rawValue: modifiers ?? 0)
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if !flags.contains(.noCommand) { prefix += "⌘" }
        return prefix + key
    }

    private static func characterLabel(_ character: String) -> String? {
        guard !character.isEmpty else { return nil }
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first {
            switch scalar.value {
            case 0x03: return "⌤"
            case 0x08, 0x7F: return "⌫"
            case 0x09: return "⇥"
            case 0x0A, 0x0D: return "↩"
            case 0x19: return "⇤"
            case 0x1B: return "⎋"
            case 0x20: return "Space"
            case 0xF700: return "↑"
            case 0xF701: return "↓"
            case 0xF702: return "←"
            case 0xF703: return "→"
            case 0xF704...0xF726: return "F\(scalar.value - 0xF704 + 1)"
            case 0xF727: return "Insert"
            case 0xF728: return "⌦"
            case 0xF729: return "↖"
            case 0xF72B: return "↘"
            case 0xF72C: return "⇞"
            case 0xF72D: return "⇟"
            case 0xF739: return "⌧"
            case 0xF746: return "Help"
            default: break
            }
        }
        guard
            !character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .privateUse
            }), !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return character.uppercased()
    }

    private static func glyphLabel(_ glyph: Int) -> String? {
        switch glyph {
        case Int(kMenuF1Glyph)...Int(kMenuF12Glyph): return "F\(glyph - Int(kMenuF1Glyph) + 1)"
        case Int(kMenuF13Glyph)...Int(kMenuF15Glyph): return "F\(glyph - Int(kMenuF13Glyph) + 13)"
        case Int(kMenuF16Glyph)...Int(kMenuF19Glyph): return "F\(glyph - Int(kMenuF16Glyph) + 16)"
        default: return glyphLabels[glyph]
        }
    }

    private static let glyphLabels: [Int: String] = [
        Int(kMenuTabRightGlyph): "⇥", Int(kMenuTabLeftGlyph): "⇤",
        Int(kMenuEnterGlyph): "⌤", Int(kMenuSpaceGlyph): "Space",
        Int(kMenuDeleteRightGlyph): "⌦", Int(kMenuDeleteLeftGlyph): "⌫",
        Int(kMenuReturnGlyph): "↩", Int(kMenuReturnR2LGlyph): "↩",
        Int(kMenuNonmarkingReturnGlyph): "↩", Int(kMenuEscapeGlyph): "⎋",
        Int(kMenuClearGlyph): "⌧", Int(kMenuPageUpGlyph): "⇞", Int(kMenuPageDownGlyph): "⇟",
        Int(kMenuLeftArrowGlyph): "←", Int(kMenuRightArrowGlyph): "→",
        Int(kMenuUpArrowGlyph): "↑", Int(kMenuDownArrowGlyph): "↓",
        Int(kMenuNorthwestArrowGlyph): "↖", Int(kMenuSoutheastArrowGlyph): "↘",
        Int(kMenuHelpGlyph): "Help", Int(kMenuEjectGlyph): "⏏",
    ]

    // Only layout-independent keys are safe to infer from a virtual key code.
    private static let virtualKeyLabels: [Int: String] = [
        Int(kVK_Return): "↩", Int(kVK_Tab): "⇥", Int(kVK_Space): "Space",
        Int(kVK_Delete): "⌫", Int(kVK_ForwardDelete): "⌦", Int(kVK_Escape): "⎋",
        Int(kVK_ANSI_KeypadEnter): "⌤", Int(kVK_ANSI_KeypadClear): "⌧",
        Int(kVK_Home): "↖", Int(kVK_End): "↘", Int(kVK_PageUp): "⇞", Int(kVK_PageDown): "⇟",
        Int(kVK_LeftArrow): "←", Int(kVK_RightArrow): "→",
        Int(kVK_UpArrow): "↑", Int(kVK_DownArrow): "↓", Int(kVK_Help): "Help",
        Int(kVK_F1): "F1", Int(kVK_F2): "F2", Int(kVK_F3): "F3", Int(kVK_F4): "F4",
        Int(kVK_F5): "F5", Int(kVK_F6): "F6", Int(kVK_F7): "F7", Int(kVK_F8): "F8",
        Int(kVK_F9): "F9", Int(kVK_F10): "F10", Int(kVK_F11): "F11", Int(kVK_F12): "F12",
        Int(kVK_F13): "F13", Int(kVK_F14): "F14", Int(kVK_F15): "F15", Int(kVK_F16): "F16",
        Int(kVK_F17): "F17", Int(kVK_F18): "F18", Int(kVK_F19): "F19", Int(kVK_F20): "F20",
    ]
}
