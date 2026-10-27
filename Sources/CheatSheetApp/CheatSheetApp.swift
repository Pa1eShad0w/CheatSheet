import AppKit

@main
@MainActor
struct CheatSheetApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runningCopies = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.cheatsheet.modern"
        )
        guard runningCopies.count <= 1 else {
            runningCopies.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate()
            NSApp.terminate(nil)
            return
        }
        controller = AppController()
        controller?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
