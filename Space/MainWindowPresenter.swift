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
    private let animationDuration: TimeInterval = 0.16
    private let windowSize = NSSize(width: 1080, height: 720)

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidResignActive() {
        guard !isSuppressingWindowPresentation else { return }
        hideClipboardWindow()
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

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        if shouldAnimate {
            animate(window: window, toAlpha: 1, frame: targetFrame)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !self.isSuppressingWindowPresentation else { return }
            guard window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.configureWindow(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .showClipboardHistory, object: nil)
        }
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

    func hideClipboardWindow(_ window: NSWindow? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.hideClipboardWindow(window)
            }
            return
        }

        guard let window = window ?? self.window else { return }
        guard window.isVisible else { return }

        shouldShowWhenAvailable = false
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        window.orderOut(nil)
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
            .frame(width: windowSize.width, height: windowSize.height)
            .ignoresSafeArea()

        let window = MainWindow(
            contentRect: initialFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
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
        window.level = .normal
        window.collectionBehavior = [.transient, .ignoresCycle]
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

private final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            MainWindowPresenter.shared.hideClipboardWindow(self)
        } else {
            super.keyDown(with: event)
        }
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
}
