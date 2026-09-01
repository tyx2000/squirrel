// Purpose: Creates, presents, animates, and releases the clipboard management window on demand.

import AppKit
import Foundation
import QuartzCore
import SwiftUI

final class MainWindowPresenter {
    static let shared = MainWindowPresenter()

    private var window: NSWindow?
    private weak var services: AppServices?
    private let windowDelegate = MainWindowDelegate()
    private var shouldShowWhenAvailable = false
    private var isSuppressingWindowPresentation = false
    private var isAutoHideSuspended = false
    private let animationDuration: TimeInterval = 0.16
    private let windowSize = NSSize(width: 1080, height: 720)

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// Keeps the window on screen across the next deactivation, for flows that hand focus
    /// to another app on the user's behalf (opening System Settings, for example).
    func suspendAutoHideUntilReactivated() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.suspendAutoHideUntilReactivated()
            }
            return
        }

        isAutoHideSuspended = true
    }

    @objc private func applicationDidResignActive() {
        guard !isSuppressingWindowPresentation, !isAutoHideSuspended else { return }
        hideClipboardWindow()
    }

    @objc private func applicationDidBecomeActive() {
        isAutoHideSuspended = false
    }

    /// The suspension lasts until the user comes back to the panel. Relying on
    /// didBecomeActive alone would strand it, since this app no longer activates.
    func handleWindowBecameKey() {
        isAutoHideSuspended = false
    }

    func configure(services: AppServices) {
        self.services = services

        if shouldShowWhenAvailable {
            showClipboardWindow()
        }
    }

    func toggleClipboardWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.toggleClipboardWindow()
            }
            return
        }

        showClipboardWindow()
    }

    func showClipboardWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showClipboardWindow()
            }
            return
        }

        guard !isSuppressingWindowPresentation else { return }
        guard let window = window ?? makeWindow() else {
            shouldShowWhenAvailable = true
            return
        }

        shouldShowWhenAvailable = false

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        configureWindow(window)
        if !window.isVisible {
            window.setFrame(centeredFrame(), display: false)
        }
        let targetFrame = window.frame
        let shouldAnimate = !window.isVisible || window.alphaValue < 1

        if shouldAnimate {
            window.alphaValue = 0
            window.setFrame(targetFrame.offsetBy(dx: 0, dy: -10), display: false)
        }

        // Deliberately no NSApp.activate: a non-activating panel takes key status
        // without making Space the active app, so whatever text field the user was
        // typing in keeps its insertion point and gets it back when the panel hides.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        if shouldAnimate {
            animate(window: window, toAlpha: 1, frame: targetFrame)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !self.isSuppressingWindowPresentation else { return }
            guard window.isVisible else { return }
            self.configureWindow(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .showClipboardHistory, object: nil)
        }
    }

    /// Called when the panel stops being the key window.
    func handleWindowResignedKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard !self.isSuppressingWindowPresentation, !self.isAutoHideSuspended else { return }

            // Only the panel's own sheet, or an app-modal alert, may keep it on screen.
            // Testing NSApp.keyWindow for nil was too broad: clicking the menu bar item
            // makes the status bar's window key, which silently cancelled the hide and
            // left the panel stuck visible with no further resign-key to recover from.
            if let modalWindow = NSApp.modalWindow, modalWindow !== window { return }
            if let keyWindow = NSApp.keyWindow, keyWindow === window || keyWindow.sheetParent === window {
                return
            }

            self.hideClipboardWindow()
        }
    }

    /// Key status is not a reliable signal on its own: the panel can end up visible but
    /// not key, and then never resigns anything. Another app coming forward is.
    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard application?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !isSuppressingWindowPresentation, !isAutoHideSuspended else { return }
        hideClipboardWindow()
    }

    func beginCapturePresentation() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginCapturePresentation()
            }
            return
        }

        isSuppressingWindowPresentation = true
    }

    func endCapturePresentation() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.endCapturePresentation()
            }
            return
        }

        isSuppressingWindowPresentation = false
    }

    /// Returns whether a visible window was taken off screen. Callers that need the
    /// answer must be on the main thread; off-thread calls hide asynchronously and report false.
    @discardableResult
    func hideClipboardWindow(_ window: NSWindow? = nil) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.hideClipboardWindow(window)
            }
            return false
        }

        guard let window = window ?? self.window else { return false }
        guard window.isVisible else { return false }

        shouldShowWhenAvailable = false
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        window.orderOut(nil)
        return true
    }

    private func makeWindow() -> NSWindow? {
        guard let services else { return nil }

        let rootView = ContentView()
            .environmentObject(services.clipboardStore)
            .environmentObject(services.hotKeyManager)
            .environmentObject(services.windowManager)
            .environmentObject(services.screenCaptureService)
            .environmentObject(services.screenRecordingService)
            .environmentObject(services.diskVacuumService)
            .environmentObject(services.loginItemService)
            .frame(width: windowSize.width, height: windowSize.height)
            .ignoresSafeArea()

        let window = MainWindow(
            contentRect: initialFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = NSHostingController(rootView: rootView)
        configureWindow(window)
        self.window = window
        return window
    }

    private func initialFrame() -> NSRect {
        centeredFrame()
    }

    private func centeredFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = windowDelegate
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.969, blue: 0.976, alpha: 1)
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.minSize = windowSize
        window.maxSize = windowSize
        window.setContentSize(windowSize)
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Floating so it stays above the window of the app that is still active.
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
    }

    private func animate(window: NSWindow, toAlpha alpha: CGFloat, frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
            window.animator().setFrame(frame, display: true)
        }
    }
}

private final class MainWindow: NSPanel {
    private enum Key {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Key.escape:
            MainWindowPresenter.shared.hideClipboardWindow(self)
        case Key.upArrow:
            post(.previous)
        case Key.downArrow:
            post(.next)
        case Key.returnKey, Key.keypadEnter:
            post(.copy)
        default:
            super.keyDown(with: event)
        }
    }

    private func post(_ command: HistoryNavigationCommand) {
        NotificationCenter.default.post(name: .historyNavigation, object: command)
    }

    override func cancelOperation(_ sender: Any?) {
        MainWindowPresenter.shared.hideClipboardWindow(self)
    }
}

private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        return true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: 1080, height: 720)
    }

    func windowDidResignKey(_ notification: Notification) {
        MainWindowPresenter.shared.handleWindowResignedKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MainWindowPresenter.shared.handleWindowBecameKey()
    }

}
