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
    private var isHiding = false
    private var pendingClipboardPromotion: ClipboardItem?
    private let animationDuration: TimeInterval = 0.16
    private let windowSize = NSSize(width: 720, height: 480)

    private init() {}

    func configure(services: AppServices) {
        self.services = services

        if shouldShowWhenAvailable {
            showClipboardWindow()
        }
    }

    func showClipboardWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showClipboardWindow()
            }
            return
        }

        guard let window = window ?? makeWindow() else {
            shouldShowWhenAvailable = true
            return
        }

        shouldShowWhenAvailable = false
        isHiding = false

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        configureWindow(window)
        let targetFrame = window.frame
        let shouldAnimate = !window.isVisible || window.alphaValue < 1

        if shouldAnimate {
            window.alphaValue = 0
            window.setFrame(targetFrame.offsetBy(dx: 0, dy: -10), display: false)
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        if shouldAnimate {
            animate(window: window, toAlpha: 1, frame: targetFrame)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            self.configureWindow(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .showClipboardHistory, object: nil)
        }
    }

    func promoteClipboardItemAfterNextHide(_ item: ClipboardItem) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.promoteClipboardItemAfterNextHide(item)
            }
            return
        }

        guard let window, window.isVisible else {
            services?.clipboardStore.promoteItem(item)
            return
        }

        pendingClipboardPromotion = item
    }

    func hideClipboardWindow(_ window: NSWindow? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.hideClipboardWindow(window)
            }
            return
        }

        guard let window = window ?? self.window else { return }
        guard window.isVisible else { return }
        guard !isHiding else { return }

        isHiding = true
        let targetFrame = window.frame.offsetBy(dx: 0, dy: -8)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            window.setFrame(targetFrame.offsetBy(dx: 0, dy: 8), display: false)
            window.contentViewController = nil
            if self.window === window {
                self.window = nil
            }
            self.isHiding = false
            self.promotePendingClipboardItem()
        }
    }

    private func promotePendingClipboardItem() {
        guard let pendingClipboardPromotion else { return }
        self.pendingClipboardPromotion = nil
        services?.clipboardStore.promoteItem(pendingClipboardPromotion)
    }

    private func makeWindow() -> NSWindow? {
        guard let services else { return nil }

        let rootView = ContentView()
            .environmentObject(services.clipboardStore)
            .environmentObject(services.hotKeyManager)
            .environmentObject(services.windowManager)
            .environmentObject(services.screenCaptureService)
            .frame(width: windowSize.width, height: windowSize.height)
            .ignoresSafeArea()

        let window = MainClipboardWindow(
            contentRect: initialFrame(),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = NSHostingController(rootView: rootView)
        configureWindow(window)
        self.window = window
        return window
    }

    private func initialFrame() -> NSRect {
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
        window.level = .statusBar
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
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

private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        MainWindowPresenter.shared.hideClipboardWindow(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        MainWindowPresenter.shared.hideClipboardWindow(sender)
        return false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: 720, height: 480)
    }
}

private final class MainClipboardWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        MainWindowPresenter.shared.hideClipboardWindow(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
