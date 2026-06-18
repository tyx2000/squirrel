// Purpose: Owns long-lived services and wires global shortcuts to clipboard, window, and lock actions.

import Carbon
import Combine
import Foundation

final class AppServices: ObservableObject {
    let clipboardStore: ClipboardHistoryStore
    let hotKeyManager: HotKeyManager
    let windowManager: WindowManager
    let screenCaptureService: ScreenCaptureService
    let screenRecordingService: ScreenRecordingService
    let statusItemController: StatusItemController
    private var latestLockScreenRequestID = UUID()

    init() {
        clipboardStore = ClipboardHistoryStore()
        hotKeyManager = HotKeyManager()
        windowManager = WindowManager()
        screenCaptureService = ScreenCaptureService(clipboardStore: clipboardStore)
        screenRecordingService = ScreenRecordingService()
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

        hotKeyManager.setAction(.lockScreen) { [weak self, weak hotKeyManager] in
            let requestID = UUID()
            self?.latestLockScreenRequestID = requestID
            Self.lockScreen { didLock in
                guard self?.latestLockScreenRequestID == requestID else { return }
                if !didLock {
                    hotKeyManager?.reportActionFailure(
                        "Lock Screen shortcut was triggered, but macOS did not accept the lock request.",
                        for: .lockScreen
                    )
                }
            }
        }

        hotKeyManager.setAction(.captureArea) { [screenCaptureService, weak hotKeyManager] in
            screenCaptureService.startAreaCapture { message in
                hotKeyManager?.reportActionFailure(message, for: .captureArea)
            }
        }

        hotKeyManager.setAction(.recordWindow) { [screenRecordingService, weak hotKeyManager] in
            screenRecordingService.toggleScreenRecording { message in
                hotKeyManager?.reportActionFailure(message, for: .recordWindow)
            }
        }

        MainWindowPresenter.shared.configure(services: self)
    }

    private static func lockScreen(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let didLock = performLockScreenRequest()
            DispatchQueue.main.async {
                completion(didLock)
            }
        }
    }

    private nonisolated static func performLockScreenRequest() -> Bool {
        if launchCGSessionLock() {
            return true
        }

        return postSystemLockShortcut()
    }

    private nonisolated static func launchCGSessionLock() -> Bool {
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
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated static func postSystemLockShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        let keyCode = CGKeyCode(kVK_ANSI_Q)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = flags
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = flags
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
