public struct Shortcut: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let menuPath: [String]
    public let keys: String
    public let isEnabled: Bool

    public init(id: String, title: String, menuPath: [String], keys: String, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.menuPath = menuPath
        self.keys = keys
        self.isEnabled = isEnabled
    }
}

public struct ShortcutSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let shortcuts: [Shortcut]

    public init(id: String, title: String, shortcuts: [Shortcut]) {
        self.id = id
        self.title = title
        self.shortcuts = shortcuts
    }
}

public struct MenuSnapshot: Equatable, Sendable {
    public let applicationName: String
    public let processIdentifier: Int32
    public let sections: [ShortcutSection]
    public let isTruncated: Bool

    public init(
        applicationName: String,
        processIdentifier: Int32,
        sections: [ShortcutSection],
        isTruncated: Bool
    ) {
        self.applicationName = applicationName
        self.processIdentifier = processIdentifier
        self.sections = sections
        self.isTruncated = isTruncated
    }
}
