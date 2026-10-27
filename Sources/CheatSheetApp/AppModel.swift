import AppKit
import ApplicationServices
import Combine
import ServiceManagement

func text(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            onMonitoringChange?()
        }
    }
    @Published var holdDelay: Double {
        didSet {
            UserDefaults.standard.set(holdDelay, forKey: "holdDelay")
            onMonitoringChange?()
        }
    }
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published var loginError: String?
    @Published var monitorUnavailable = false
    var onMonitoringChange: (() -> Void)?

    init() {
        UserDefaults.standard.register(defaults: ["isEnabled": true, "holdDelay": 1.0])
        isEnabled = UserDefaults.standard.bool(forKey: "isEnabled")
        let delay = UserDefaults.standard.double(forKey: "holdDelay")
        holdDelay = delay.isFinite ? min(2.0, max(0.4, delay)) : 1.0
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            onMonitoringChange?()
        }
        let status = SMAppService.mainApp.status
        if status != loginStatus { loginStatus = status }
    }

    func requestAccessibility() {
        // This displays the system's permission prompt; it does not grant access.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginStatus = SMAppService.mainApp.status
            loginError = nil
            if loginStatus == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            loginError = error.localizedDescription
            loginStatus = SMAppService.mainApp.status
        }
    }
}
