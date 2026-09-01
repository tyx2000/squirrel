// Purpose: Manages the launch-at-login registration and the one-time prompt offering it.

import AppKit
import Combine
import Foundation
import ServiceManagement
import os.log

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastMessage: String?

    private static let hasPromptedKey = "Space.hasPromptedForLoginItem"

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        os_log("Login item status: %{public}@", log: .default, type: .info, Self.description(for: status))
    }

    func clearMessage() {
        lastMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastMessage = nil
        } catch {
            lastMessage = "Could not \(enabled ? "enable" : "disable") Open at Login: \(error.localizedDescription)"
            os_log(
                "Login item %{public}@ failed: %{public}@",
                log: .default,
                type: .error,
                enabled ? "register" : "unregister",
                error.localizedDescription
            )
        }

        refresh()

        // Once a user has switched the item off in System Settings, only System Settings
        // can switch it back on.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            lastMessage = "Open at Login needs to be approved in System Settings > General > Login Items."
            MainWindowPresenter.shared.hideClipboardWindow()
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Offers to enable the login item the first time the app runs, and never asks again.
    func promptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasPromptedKey) else { return }

        // A bundle that has never been registered reports notFound, not notRegistered.
        let status = SMAppService.mainApp.status
        guard status == .notRegistered || status == .notFound else {
            UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)
            return
        }

        UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)

        let alert = NSAlert()
        alert.messageText = "Open Space at Login?"
        alert.informativeText = "Space lives in the menu bar. Opening it at login keeps the shortcuts working after a restart. You can change this later on the Shortcuts tab."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setEnabled(true)
    }

    private static func description(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
