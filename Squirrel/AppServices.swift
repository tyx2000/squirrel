// Purpose: Owns long-lived services and wires global shortcuts to clipboard, window, and lock actions.

import Carbon
import Combine
import Foundation

final class AppServices: ObservableObject {
    let clipboardStore: ClipboardHistoryStore
    let hotKeyManager: HotKeyManager
    let windowManager: WindowManager
    let statusItemController: StatusItemController

    init() {
        clipboardStore = ClipboardHistoryStore()
        hotKeyManager = HotKeyManager()
        windowManager = WindowManager()
        statusItemController = StatusItemController()

        configure()
    }

    private func configure() {
        clipboardStore.startMonitoring()

        hotKeyManager.setAction(.clipboardWindow) {
            NotificationCenter.default.post(name: .openClipboardWindow, object: nil)
        }

        hotKeyManager.setAction(.leftHalf) { [windowManager] in
            windowManager.apply(.leftHalf)
        }

        hotKeyManager.setAction(.rightHalf) { [windowManager] in
            windowManager.apply(.rightHalf)
        }

        hotKeyManager.setAction(.centerHalf) { [windowManager] in
            windowManager.apply(.centerHalf)
        }

        hotKeyManager.setAction(.lockScreen) {
            Self.lockScreen()
        }

        MainWindowPresenter.shared.configure(services: self)
    }

    private static func lockScreen() {
        if launchCGSessionLock() {
            return
        }

        postSystemLockShortcut()
    }

    private static func launchCGSessionLock() -> Bool {
        let candidatePaths = [
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            "/System/Library/CoreServices/CGSession"
        ]

        guard let executablePath = candidatePaths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-suspend"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func postSystemLockShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        let keyCode = CGKeyCode(kVK_ANSI_Q)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
