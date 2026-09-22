// Purpose: Handles macOS application lifecycle events and starts the shared app services.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar resident: the status item is the entry point, so no Dock icon
        // and no Cmd-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        services = AppServices()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openClipboardWindow),
            name: .openClipboardWindow,
            object: nil
        )

        // After the first run the app starts quietly in the menu bar, which matters now
        // that it can open at login: otherwise the panel would appear at every login.
        if Self.isFirstLaunch() {
            openClipboardWindow()
        }
        services?.loginItemService.promptIfNeeded()
    }

    private static let hasLaunchedKey = "Space.hasPresentedAtFirstLaunch"

    /// True the first time only, and records that it has been answered.
    static func isFirstLaunch(recordingIn defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: hasLaunchedKey) else { return false }
        defaults.set(true, forKey: hasLaunchedKey)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openClipboardWindow()
        return true
    }

    @objc private func openClipboardWindow() {
        MainWindowPresenter.shared.showClipboardWindow()
    }
}
