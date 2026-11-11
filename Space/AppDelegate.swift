// Purpose: Handles macOS application lifecycle events and starts the shared app services.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Starting the services there would watch the real
        // pasteboard, write the user's history, and take the global shortcuts.
        guard !Self.isHostingUnitTests() else { return }

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

    static func isHostingUnitTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
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
