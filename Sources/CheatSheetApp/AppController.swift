import AppKit
import CheatSheetCore
import SwiftUI

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let model = AppModel()
    private let overlay = OverlayController()
    private var gesture = CommandHold()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var delayTask: Task<Void, Never>?
    private let menuRead = MenuReadSession()
    private var visibilityTask: Task<Void, Never>?
    private var targetPID: Int32?
    private var contextID: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "command.square", accessibilityDescription: text("app.name"))
            image?.isTemplate = true
            button.image = image
            button.toolTip = text("app.name")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        model.onMonitoringChange = { [weak self] in self?.configureMonitoring() }
        menuRead.onCompletion = { [weak self] in self?.publishReadResult() }
        overlay.model.onOpenSettings = { [weak self] in self?.showSettings() }
        overlay.model.onTogglePin = { [weak self] in self?.togglePin() }
        configureMonitoring()

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.workspaceChanged(name) }
                })
        }
        let hasShownWelcome = UserDefaults.standard.bool(forKey: "hasShownWelcome")
        if !hasShownWelcome || !model.isTrusted {
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            showSettings()
        }
    }

    func stop() {
        invalidateReadContext()
        invalidateGesture()
        removeMonitors()
        permissionTimer?.invalidate()
        permissionTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func showSettings() {
        invalidateReadContext()
        invalidateGesture()
        model.refreshPermissions()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = text("app.name")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        invalidateReadContext()
        invalidateGesture()
        model.refreshPermissions()
        menu.removeAllItems()
        let status = NSMenuItem(
            title: text(
                !model.isTrusted ? "menu.permissionRequired" : (model.isEnabled ? "menu.ready" : "menu.paused")),
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        addItem(to: menu, title: text(model.isEnabled ? "menu.pause" : "menu.resume"), action: #selector(toggleEnabled))
        addItem(to: menu, title: text("menu.settings"), action: #selector(openSettings), key: ",")
        if !model.isTrusted {
            addItem(to: menu, title: text("permission.allow"), action: #selector(requestPermission))
        }
        menu.addItem(.separator())
        addItem(to: menu, title: text("menu.quit"), action: #selector(quit), key: "q")
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleEnabled() { model.isEnabled.toggle() }
    @objc private func openSettings() { showSettings() }
    @objc private func requestPermission() { model.requestAccessibility() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configureMonitoring() {
        invalidateReadContext()
        invalidateGesture()
        removeMonitors()
        model.monitorUnavailable = false
        guard model.isEnabled, model.isTrusted else { return }
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        model.monitorUnavailable = globalMonitor == nil || localMonitor == nil
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard model.isEnabled, model.isTrusted else { return }
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags
            let other = !flags.intersection([.shift, .option, .control, .function]).isEmpty
            if other && !gesture.isPinned { invalidateReadContext() }
            process(.modifiers(command: flags.contains(.command), other: other))
        case .keyDown:
            if !gesture.isPinned { invalidateReadContext() }
            process(.keyDown)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Screenshot window-selection events can belong to a system overlay.
            guard !overlay.owns(event), !(gesture.isPinned && overlay.containsPointer) else { return }
            invalidateReadContext()
            if gesture.isPinned {
                invalidateGesture()
            } else {
                process(.mouseDown)
            }
        case .scrollWheel:
            if !gesture.isPinned && !overlay.owns(event) {
                invalidateReadContext()
                invalidateGesture()
            }
        default: break
        }
    }

    private func workspaceChanged(_ name: Notification.Name) {
        // A screenshot utility may activate without an outside click. Keep the
        // pinned snapshot visible; mouse-down outside remains the dismissal rule.
        if name == NSWorkspace.didActivateApplicationNotification && gesture.isPinned { return }
        invalidateReadContext()
        invalidateGesture()
    }

    private func invalidateReadContext() {
        contextID &+= 1
        menuRead.invalidate()
    }

    private func togglePin() {
        if gesture.isPinned {
            // Input may have changed the target while the pinned snapshot was kept still.
            invalidateReadContext()
            let command = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            process(.unpin(command: command))
            if gesture.isVisible, let targetPID,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
            {
                menuRead.begin(
                    processIdentifier: targetPID, applicationName: overlay.model.applicationName, contextID: contextID
                )
            }
        } else {
            process(.pin)
        }
    }

    private func invalidateGesture() {
        let command = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        process(.invalidate(command: command))
    }

    private func process(_ event: CommandHold.Event) {
        let wasPinned = gesture.isPinned
        for effect in gesture.handle(event) {
            switch effect {
            case .schedule: schedule()
            case .cancel:
                delayTask?.cancel()
                delayTask = nil
                menuRead.cancel()
                visibilityTask?.cancel()
                visibilityTask = nil
                targetPID = nil
            case .show: showShortcuts()
            case .hide: overlay.hide()
            }
        }
        overlay.model.isPinned = gesture.isPinned
        if gesture.isPinned {
            visibilityTask?.cancel()
            visibilityTask = nil
        } else if wasPinned && gesture.isVisible {
            watchVisibility()
        }
    }

    private func schedule() {
        guard NSEvent.pressedMouseButtons == 0 else {
            process(.mouseDown)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            invalidateGesture()
            return
        }
        targetPID = application.processIdentifier
        menuRead.begin(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? text("overlay.application"),
            contextID: contextID
        )
        let delay = model.holdDelay
        delayTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.process(.delayElapsed)
            } catch { return }
        }
    }

    // Recover when secure input or a session transition hides the release event.
    // Poll only while the panel is visible, never while idle.
    private func watchVisibility() {
        visibilityTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard let self, self.gesture.isVisible, !self.gesture.isPinned else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if !flags.contains(.maskCommand)
                    || !flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty
                    || (NSEvent.pressedMouseButtons != 0 && !self.overlay.containsPointer)
                    || NSWorkspace.shared.frontmostApplication?.processIdentifier != self.targetPID
                {
                    self.invalidateGesture()
                    return
                }
            }
        }
    }

    private func showShortcuts() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard NSEvent.pressedMouseButtons == 0,
            flags.contains(.maskCommand),
            flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty,
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier == targetPID
        else {
            invalidateGesture()
            return
        }
        let name = application.localizedName ?? text("overlay.application")
        overlay.model.content = .loading
        publishReadResult()
        overlay.show(applicationName: name)
        watchVisibility()
    }

    private func publishReadResult() {
        guard gesture.isVisible, let targetPID,
            gesture.isPinned || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
            let result = menuRead.result
        else { return }
        switch result {
        case .success(let snapshot):
            overlay.model.content = .snapshot(snapshot)
        case .failure(let error):
            let message: String
            switch error {
            case .permissionRequired: message = text("error.permission")
            case .applicationUnavailable: message = text("error.application")
            case .menuUnavailable: message = text("error.menu")
            }
            overlay.model.content = .failure(message)
        }
    }
}
