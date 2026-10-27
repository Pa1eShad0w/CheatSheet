import AppKit
import CheatSheetCore
import SwiftUI

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?

    func show(applicationName: String) {
        model.applicationName = applicationName
        model.requestID = UUID()
        if panel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovable = false
            panel.title = text("app.name")
            let hosting = NSHostingView(rootView: OverlayView(model: model))
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 12
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
            self.panel = panel
        }
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let width = min(1000, frame.width - min(48, frame.width * 0.08))
        let height = min(620, frame.height - min(64, frame.height * 0.1))
        let rect = NSRect(
            x: frame.midX - width / 2, y: frame.midY - height / 2,
            width: width, height: height
        )
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    func owns(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        return event.window === panel
    }

    var containsPointer: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
