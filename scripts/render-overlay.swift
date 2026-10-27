// From the repository root (no app launch, Accessibility, or screen capture):
// mkdir -p .build/overlay-preview-support
// xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -emit-module -emit-library -static -module-name CheatSheetCore Sources/CheatSheetCore/Shortcut.swift -emit-module-path .build/overlay-preview-support/CheatSheetCore.swiftmodule -o .build/overlay-preview-support/libCheatSheetCore.a
// xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -I .build/overlay-preview-support -L .build/overlay-preview-support -lCheatSheetCore Sources/CheatSheetApp/ShortcutColumns.swift Sources/CheatSheetApp/OverlayView.swift Sources/CheatSheetApp/OverlayController.swift scripts/render-overlay.swift -o .build/render-overlay
// .build/render-overlay [--dark] [--compact]
import AppKit
import CheatSheetCore
import SwiftUI

// Use the real localization without constructing AppModel or requesting permissions.
func text(_ key: String) -> String {
    Bundle(path: "Resources/en.lproj")?.localizedString(forKey: key, value: key, table: nil) ?? key
}

@main
private enum OverlayPreview {
    @MainActor
    static func main() {
        do {
            try render()
        } catch {
            FileHandle.standardError.write(Data("Overlay checks failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func render() throws {
        try checkPacking()
        try checkKeyParts()
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let dark = CommandLine.arguments.contains("--dark")
        let compact = CommandLine.arguments.contains("--compact")
        let size = NSSize(width: compact ? 760 : 1000, height: compact ? 430 : 620)
        let model = OverlayModel()
        var settingsRequests = 0
        var pinRequests = 0
        model.onOpenSettings = { settingsRequests += 1 }
        model.onTogglePin = {
            pinRequests += 1
            model.isPinned.toggle()
        }
        model.applicationName = "Preview Editor"
        model.content = .snapshot(
            MenuSnapshot(
                applicationName: model.applicationName,
                processIdentifier: 0,
                sections: previewSections,
                isTruncated: false
            ))
        let view = OverlayView(model: model)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Never order the window on screen. Let SwiftUI finish its layout offscreen.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.layoutSubtreeIfNeeded()
        try checkScrolling(hosting: hosting, model: model)
        try clickButton("overlay-settings", hosting: hosting)
        try require(settingsRequests == 1, "The footer settings control must invoke its real action")
        try clickButton("overlay-pin", hosting: hosting)
        try require(pinRequests == 1 && model.isPinned, "The Command control must pin the sheet")
        try clickButton("overlay-pin", hosting: hosting)
        try require(pinRequests == 2 && !model.isPinned, "The Command control must unpin on a second click")
        print("Footer control checks passed: settings, pin, and unpin actions are connected.")
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CheckFailure(message: "Unable to allocate an offscreen bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(message: "Unable to encode preview PNG")
        }
        let suffix = (compact ? "-compact" : "") + (dark ? "-dark" : "")
        let path = ".build/overlay-preview\(suffix).png"
        try png.write(to: URL(fileURLWithPath: path))
        print("Rendered actual OverlayView to \(path) (\(Int(size.width)) × \(Int(size.height)) points).")
        withExtendedLifetime(window) {}
    }

    @MainActor
    private static func checkScrolling(hosting: NSView, model: OverlayModel) throws {
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        func settle() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let scroll = scrollView(in: hosting), let document = scroll.documentView else {
            throw CheckFailure(message: "Missing horizontal scroll view")
        }
        try require(!scroll.hasVerticalScroller, "The overlay must not install a vertical scroller")
        try require(document.frame.height <= scroll.contentView.bounds.height + 1, "No vertical document overflow")
        try require(document.frame.width > scroll.contentView.bounds.width, "Long menus must overflow horizontally")
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let offset = scroll.contentView.bounds.minX
        try require(offset > 0, "Horizontal overflow must be reachable")
        if case .snapshot(let snapshot) = model.content {
            model.content = .snapshot(snapshot)
        }
        settle()
        try require(
            scrollView(in: hosting)?.contentView.bounds.minX == offset,
            "Snapshot publication within a request must preserve the scroll position"
        )
        model.requestID = UUID()
        settle()
        try require(
            scrollView(in: hosting)?.contentView.bounds.minX == 0,
            "A new request must restart at the first column"
        )
        print("Scroll checks passed: horizontal overflow, no vertical overflow, snapshot stability, and request reset.")
    }

    private static func checkPacking() throws {
        // At this height a fresh column holds exactly five rows.
        let height = ShortcutColumnMetrics.headingHeight + 5 * ShortcutColumnMetrics.rowHeight
        let intact = packShortcutColumns(sections: sections(counts: [2, 4, 1]), height: height)
        try require(intact.count == 3, "Groups fitting a column must not split to backfill the previous one")
        try require(intact[1].fragments[0].range == 0..<4, "Four-row group must remain intact")
        let stacked = packShortcutColumns(sections: sections(counts: [1, 1]), height: height)
        try require(stacked.count == 1 && stacked[0].fragments.count == 2, "Short groups stack independently")
        let split = packShortcutColumns(sections: sections(counts: [12]), height: height)
        try require(
            split.map { $0.fragments[0].range } == [0..<5, 5..<10, 10..<12],
            "Every continuation reserves space for its heading")
        for fragment in split.flatMap(\.fragments) {
            try require(
                fragment.height == ShortcutColumnMetrics.headingHeight
                    + CGFloat(fragment.range.count) * ShortcutColumnMetrics.rowHeight,
                "Every column fragment includes its group heading and top padding"
            )
            try require(fragment.section.title == "Menu 0", "Continuation headings retain the original group title")
        }
        let minimumHeight = ShortcutColumnMetrics.headingHeight + ShortcutColumnMetrics.rowHeight
        let singleRows = packShortcutColumns(sections: sections(counts: [3]), height: minimumHeight)
        try require(singleRows.count == 3, "A one-row column still repeats the heading without overflowing")
        let remainder = packShortcutColumns(sections: sections(counts: [1, 12]), height: height)
        try require(remainder[0].fragments.count == 2, "Overlong group uses available space in the first column")
        try require(packShortcutColumns(sections: [], height: height)[0].fragments.isEmpty, "Empty menus have no rows")
        let emptyGroup = packShortcutColumns(sections: sections(counts: [0, 2, 0]), height: height)
        try require(emptyGroup[0].fragments.count == 1, "Empty groups consume no space")
        let repeated = packShortcutColumns(sections: sections(counts: [12]), height: height)
        try require(
            split.flatMap { $0.fragments.map(\.id) } == repeated.flatMap { $0.fragments.map(\.id) },
            "Fragment identity must be stable across equivalent snapshots"
        )

        // Deterministic varied menus: check positions, not IDs, so duplicate command
        // labels/keys cannot hide a dropped or repeated shortcut.
        var state: UInt64 = 71
        for sample in 0..<300 {
            var counts: [Int] = []
            for _ in 0..<(sample % 17) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                counts.append(Int((state >> 32) % 90))
            }
            let menu = sections(counts: counts)
            let available =
                ShortcutColumnMetrics.headingHeight + ShortcutColumnMetrics.rowHeight
                + CGFloat((sample * 37) % 610)
            let columns = packShortcutColumns(sections: menu, height: available)
            let expected = menu.enumerated().flatMap { sectionIndex, section in
                section.shortcuts.indices.map { "\(sectionIndex):\($0)" }
            }
            var actual: [String] = []
            for column in columns {
                var used: CGFloat = 0
                for (index, fragment) in column.fragments.enumerated() {
                    used += (index == 0 ? 0 : ShortcutColumnMetrics.groupSpacing) + fragment.height
                    actual += fragment.range.map { "\(fragment.id.sectionIndex):\($0)" }
                    try require(!fragment.range.isEmpty, "Never emit empty continuations")
                    if CGFloat(fragment.section.shortcuts.count) * ShortcutColumnMetrics.rowHeight
                        + ShortcutColumnMetrics.headingHeight <= available
                    {
                        try require(
                            fragment.range.count == fragment.section.shortcuts.count,
                            "A group that fits a full column must stay together"
                        )
                    }
                }
                try require(used == column.height && used <= available, "Column must fit its height budget")
            }
            try require(actual == expected, "Every shortcut must appear exactly once, in original menu order")
        }
        print(
            "Packing checks passed: intact groups, stacking, continuations, empty groups, identity, and 300 varied menus."
        )
    }

    @MainActor
    private static func clickButton(_ identifier: String, hosting: NSView) throws {
        func findButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
            return view.subviews.lazy.compactMap { findButton($0) }.first
        }
        guard let button = findButton(hosting) else {
            throw CheckFailure(message: "Missing footer button: \(identifier)")
        }
        button.performClick(nil)
    }

    private static func checkKeyParts() throws {
        for (value, modifiers, key) in [
            ("⌃⌥⇧⌘F12", "⌃⌥⇧⌘", "F12"),
            ("⌘N", "⌘", "N"),
            ("⌥⌘←", "⌥⌘", "←"),
            ("F1", "", "F1"),
            ("Space", "", "Space"),
            ("⌘É", "⌘", "É"),
        ] {
            let parts = ShortcutKeyParts(value)
            try require(parts.modifiers == modifiers && parts.key == key, "Key prefix parsing for \(value)")
        }
        print("Key-prefix checks passed: modifier and primary-key slots preserve the original shortcut.")
    }

    private static func sections(counts: [Int]) -> [ShortcutSection] {
        counts.enumerated().map { sectionIndex, count in
            ShortcutSection(
                id: "section-\(sectionIndex)", title: "Menu \(sectionIndex)",
                shortcuts: (0..<count).map { index in
                    Shortcut(
                        id: "\(sectionIndex)-\(index)", title: "Command", menuPath: ["Menu \(sectionIndex)"],
                        keys: "⌘A", isEnabled: true
                    )
                }
            )
        }
    }

    private static var previewSections: [ShortcutSection] {
        let menus: [(String, [String])] = [
            (
                "Preview Editor",
                ["About Preview Editor", "Settings…", "Hide Preview Editor", "Hide Others", "Quit Preview Editor"]
            ),
            (
                "File",
                [
                    "New File", "New Window", "Open…", "Open Recent", "Close Editor", "Close Window", "Save",
                    "Save As…", "Save All", "Revert File", "Export…", "Print…",
                ]
            ),
            ("Edit", ["Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All"]),
            (
                "Selection — an intentionally long menu title",
                (1...60).map { "Expand Selection to Matching Bracket \($0)" }
            ),
            ("View", ["Show Sidebar", "Show Inspector", "Toggle Full Screen", "Zoom In", "Zoom Out"]),
            ("Navigate", ["Go to File…", "Go to Symbol…", "Jump to Definition", "Go Back", "Go Forward"]),
            ("Window", ["Minimize", "Zoom", "Bring All to Front"]),
            ("Help", ["Search Documentation", "Keyboard Shortcuts"]),
        ]
        let combinations = ["⌘N", "⇧⌘N", "⌃⌥⇧⌘F12", "⌥⌘←", "⌘W", "⇧⌘W", "⌘S", "⇧⌘S", "⌃⌥⌘↩", "⌘⌫"]
        return menus.enumerated().map { sectionIndex, menu in
            ShortcutSection(
                id: "preview-\(sectionIndex)", title: menu.0,
                shortcuts: menu.1.enumerated().map { index, title in
                    Shortcut(
                        id: "preview-\(sectionIndex)-\(index)", title: title,
                        menuPath: index % 4 == 0 ? [menu.0, "Submenu"] : [menu.0],
                        keys: combinations[index % combinations.count], isEnabled: index % 11 != 7
                    )
                }
            )
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    private struct CheckFailure: Error {
        let message: String
    }
}
