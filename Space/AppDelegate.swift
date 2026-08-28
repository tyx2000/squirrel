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

        openClipboardWindow()
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
