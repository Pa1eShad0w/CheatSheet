import AppKit
import CheatSheetCore
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Content {
        case loading
        case snapshot(MenuSnapshot)
        case failure(String)
    }

    @Published var applicationName = ""
    @Published var content: Content = .loading
    // Changes per gesture, not when loading is replaced by a snapshot.
    @Published var requestID = UUID()
    @Published var isPinned = false
    var onOpenSettings: (() -> Void)?
    var onTogglePin: (() -> Void)?
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(model.applicationName)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            OverlayPinButton(isPinned: model.isPinned) { model.onTogglePin?() }
                .frame(width: 25, height: 25)
                .padding(.leading, 20)
            // Keep the original attribution footprint without claiming its authorship.
            Text(text("app.name"))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .help(text("overlay.independent"))
                .frame(width: 107, height: 19, alignment: .leading)
                .padding(.leading, 8)
            Spacer(minLength: 12)

            OverlaySettingsButton { model.onOpenSettings?() }
                .frame(width: 28, height: 25)
                .padding(.trailing, 14)
        }
        .font(.system(size: 11))
        .frame(height: ShortcutColumnMetrics.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text("overlay.loading")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        case .failure(let message):
            ContentUnavailableView {
                Label(text("overlay.unavailable"), systemImage: "keyboard.badge.ellipsis")
            } description: {
                Text(message)
            }
        case .snapshot(let snapshot):
            if snapshot.sections.allSatisfy({ $0.shortcuts.isEmpty }) {
                ContentUnavailableView {
                    Label(text("overlay.empty"), systemImage: "keyboard")
                } description: {
                    Text(text(snapshot.isTruncated ? "overlay.partial" : "overlay.emptyDescription"))
                }
            } else {
                shortcutColumns(snapshot.sections)
            }
        }
    }

    private func shortcutColumns(_ sections: [ShortcutSection]) -> some View {
        GeometryReader { geometry in
            let height = max(0, geometry.size.height - ShortcutColumnMetrics.scrollerHeight)
            let width = ShortcutColumnMetrics.columnWidth(viewportWidth: geometry.size.width)
            let columns =
                height >= ShortcutColumnMetrics.headingHeight + ShortcutColumnMetrics.rowHeight
                ? packShortcutColumns(sections: sections, height: height) : []
            let count = max(ShortcutColumnMetrics.visibleColumnCount, columns.count)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: ShortcutColumnMetrics.columnSpacing) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(alignment: .leading, spacing: ShortcutColumnMetrics.groupSpacing) {
                            if index < columns.count {
                                ForEach(columns[index].fragments) { fragment in
                                    sectionView(fragment, width: width)
                                }
                            }
                        }
                        .frame(width: width, height: height, alignment: .topLeading)
                        .overlay(alignment: .trailing) {
                            if index < count - 1 {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: 1)
                                    .offset(x: ShortcutColumnMetrics.columnSpacing / 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, ShortcutColumnMetrics.horizontalInset)
                .padding(.bottom, ShortcutColumnMetrics.scrollerHeight)
            }
            .id(model.requestID)
        }
    }

    private func sectionView(_ fragment: ShortcutColumnFragment, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fragment.section.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(nsColor: .controlTextColor))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(fragment.section.title)
                .frame(width: nameWidth(in: width), alignment: .leading)
                .clipped()
                .frame(height: ShortcutColumnMetrics.rowHeight)
                .padding(.leading, ShortcutColumnMetrics.shortcutWidth + ShortcutColumnMetrics.shortcutSpacing)
                .padding(.top, ShortcutColumnMetrics.headingTopInset)
                .accessibilityAddTraits(.isHeader)

            ForEach(fragment.range, id: \.self) { index in
                shortcutRow(fragment.section.shortcuts[index], width: width)
            }
        }
    }

    private func nameWidth(in columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - ShortcutColumnMetrics.shortcutWidth - ShortcutColumnMetrics.shortcutSpacing)
    }

    private func shortcutRow(_ shortcut: Shortcut, width: CGFloat) -> some View {
        let keys = ShortcutKeyParts(shortcut.keys)
        let keyWidth = keys.key.count > 1 ? ShortcutColumnMetrics.longKeyWidth : ShortcutColumnMetrics.keyWidth
        return HStack(alignment: .firstTextBaseline, spacing: ShortcutColumnMetrics.shortcutSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(keys.modifiers)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: ShortcutColumnMetrics.shortcutWidth - keyWidth, alignment: .trailing)
                Text(keys.key)
                    .foregroundStyle(shortcut.isEnabled ? Color(nsColor: .controlTextColor) : .secondary)
                    .fixedSize()
                    .frame(width: keyWidth)
            }
            .font(.system(size: 13, weight: .bold))
            .frame(width: ShortcutColumnMetrics.shortcutWidth)
            .layoutPriority(1)

            Text(shortcut.title)
                .font(.system(size: 13))
                .foregroundStyle(shortcut.isEnabled ? Color(nsColor: .controlTextColor) : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: nameWidth(in: width), alignment: .leading)
                .clipped()
        }
        .frame(height: ShortcutColumnMetrics.rowHeight)
        .help((shortcut.menuPath + [shortcut.title]).joined(separator: " › ") + "  " + shortcut.keys)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.title + ", " + shortcut.keys)
    }
}

struct ShortcutKeyParts: Equatable {
    let modifiers: String
    let key: String

    init(_ value: String) {
        let prefix = value.prefix { "⌃⌥⇧⌘".contains($0) }
        modifiers = String(prefix)
        key = String(value.dropFirst(prefix.count))
    }
}

private struct OverlayPinButton: NSViewRepresentable {
    let isPinned: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "⌘", target: context.coordinator, action: #selector(Coordinator.togglePin))
        button.identifier = NSUserInterfaceItemIdentifier("overlay-pin")
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.font = .systemFont(ofSize: 18, weight: .medium)
        button.refusesFirstResponder = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = isPinned ? .on : .off
        button.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        let label = text(isPinned ? "overlay.unpin" : "overlay.pin")
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func togglePin() { action() }
    }
}

private struct OverlaySettingsButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "⌄", image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!,
            target: context.coordinator, action: #selector(Coordinator.openSettings)
        )
        button.identifier = NSUserInterfaceItemIdentifier("overlay-settings")
        button.isBordered = false
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11)
        button.refusesFirstResponder = true
        button.setAccessibilityLabel(text("menu.settings"))
        button.toolTip = text("menu.settings")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func openSettings() { action() }
    }
}
