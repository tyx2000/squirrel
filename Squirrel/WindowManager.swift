// Purpose: Applies accessibility-driven window layouts to the last active regular application.

import AppKit
import ApplicationServices
import Combine
import Foundation

enum WindowLayoutMode: String {
    case leftHalf
    case rightHalf
    case centerHalf
}

enum WindowMovePosition: String {
    case left
    case center
    case right
}

final class WindowManager: ObservableObject {
    @Published private(set) var lastMessage: String?
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    var currentAppPath: String {
        Bundle.main.bundleURL.path
    }

    private var lastTargetApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let layoutAnimationDuration: TimeInterval = 0.18
    private let layoutAnimationSteps = 9

    init() {
        captureCurrentTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.updateTargetIfNeeded(application)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityTrust()
        openAccessibilitySettings()
        updateAccessibilityMessageIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshAccessibilityTrust()
            self?.updateAccessibilityMessageIfNeeded()
        }
    }

    func refreshPermissionStatus() {
        refreshAccessibilityTrust()
        updateAccessibilityMessageIfNeeded()
    }

    func apply(_ mode: WindowLayoutMode) {
        refreshAccessibilityTrust()

        guard isAccessibilityTrusted else {
            updateAccessibilityMessageIfNeeded()
            return
        }

        guard let application = targetApplication() else {
            lastMessage = "No frontmost app was found."
            return
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(in: appElement) else {
            lastMessage = "The current app has no adjustable front window."
            return
        }

        guard let screen = screen(for: window) ?? NSScreen.main else {
            lastMessage = "No available screen was found."
            return
        }

        let targetFrame = WindowLayoutCalculator.targetFrame(for: mode, in: screen.visibleFrame)
        let axTargetFrame = accessibilityFrame(fromAppKitFrame: targetFrame, on: screen)
        let result = animate(window: window, to: axTargetFrame) ?? set(window: window, frame: axTargetFrame)
        if result.succeeded {
            lastMessage = "Applied \(mode.title) to \(application.localizedName ?? "current app")."
        } else {
            lastMessage = "\(application.localizedName ?? "The current app") does not allow adjusting this window (size: \(result.sizeStatus.rawValue), position: \(result.positionStatus.rawValue))."
        }
    }

    func move(_ position: WindowMovePosition) {
        refreshAccessibilityTrust()

        guard isAccessibilityTrusted else {
            updateAccessibilityMessageIfNeeded()
            return
        }

        guard let application = targetApplication() else {
            lastMessage = "No frontmost app was found."
            return
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(in: appElement) else {
            lastMessage = "The current app has no adjustable front window."
            return
        }

        guard let screen = screen(for: window) ?? NSScreen.main,
              let currentFrame = appKitFrame(of: window) else {
            lastMessage = "No available screen was found."
            return
        }

        let targetFrame = WindowLayoutCalculator.targetFrame(
            for: position,
            currentFrame: currentFrame,
            in: screen.visibleFrame
        )
        let axTargetFrame = accessibilityFrame(fromAppKitFrame: targetFrame, on: screen)
        let result = animatePosition(window: window, to: axTargetFrame.origin) ?? set(
            window: window,
            position: axTargetFrame.origin
        )
        if result.succeeded {
            lastMessage = "Moved \(application.localizedName ?? "current app") to \(position.title)."
        } else {
            lastMessage = "\(application.localizedName ?? "The current app") does not allow moving this window (position: \(result.positionStatus.rawValue))."
        }
    }

    private func refreshAccessibilityTrust() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    private func updateAccessibilityMessageIfNeeded() {
        if isAccessibilityTrusted {
            lastMessage = nil
        } else {
            lastMessage = "This Squirrel build does not have Accessibility access. In System Settings > Privacy & Security > Accessibility, remove any old Squirrel entry, then add and enable: \(currentAppPath)"
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func captureCurrentTarget() {
        guard let application = NSWorkspace.shared.frontmostApplication else { return }
        updateTargetIfNeeded(application)
    }

    private func updateTargetIfNeeded(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != ownBundleIdentifier else { return }
        guard application.activationPolicy == .regular else { return }
        lastTargetApplication = application
    }

    private func targetApplication() -> NSRunningApplication? {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.bundleIdentifier != ownBundleIdentifier,
           application.activationPolicy == .regular {
            updateTargetIfNeeded(application)
            return application
        }

        guard let lastTargetApplication, lastTargetApplication.isTerminated == false else {
            return nil
        }
        return lastTargetApplication
    }

    private func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }

        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &main) == .success,
           let main,
           CFGetTypeID(main) == AXUIElementGetTypeID() {
            return (main as! AXUIElement)
        }

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        return windows.first
    }

    private func screen(for window: AXUIElement) -> NSScreen? {
        guard let frame = appKitFrame(of: window) else { return NSScreen.main }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func appKitFrame(of window: AXUIElement) -> CGRect? {
        guard let accessibilityFrame = accessibilityFrame(of: window) else { return nil }
        let center = CGPoint(x: accessibilityFrame.midX, y: accessibilityFrame.midY)
        let screen = NSScreen.screens.first {
            accessibilityBounds(for: $0).contains(center)
        } ?? NSScreen.main

        guard let screen else { return nil }
        return appKitFrame(fromAccessibilityFrame: accessibilityFrame, on: screen)
    }

    private func accessibilityFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func animate(window: AXUIElement, to targetFrame: CGRect) -> (succeeded: Bool, sizeStatus: AXError, positionStatus: AXError)? {
        guard let startFrame = accessibilityFrame(of: window) else { return nil }
        guard startFrame != targetFrame else { return nil }

        let firstProgress = 1.0 / Double(layoutAnimationSteps)
        let firstFrame = interpolate(from: startFrame, to: targetFrame, progress: easeOutCubic(firstProgress))
        let firstResult = set(window: window, frame: firstFrame)

        for step in 2...layoutAnimationSteps {
            let progress = Double(step) / Double(layoutAnimationSteps)
            let frame = interpolate(from: startFrame, to: targetFrame, progress: easeOutCubic(progress))
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutAnimationDuration * progress) { [weak self] in
                _ = self?.set(window: window, frame: frame)
            }
        }

        return firstResult
    }

    private func animatePosition(window: AXUIElement, to targetOrigin: CGPoint) -> (succeeded: Bool, positionStatus: AXError)? {
        guard let startFrame = accessibilityFrame(of: window) else { return nil }
        guard startFrame.origin != targetOrigin else { return nil }

        let firstProgress = 1.0 / Double(layoutAnimationSteps)
        let firstOrigin = interpolate(from: startFrame.origin, to: targetOrigin, progress: easeOutCubic(firstProgress))
        let firstResult = set(window: window, position: firstOrigin)

        for step in 2...layoutAnimationSteps {
            let progress = Double(step) / Double(layoutAnimationSteps)
            let origin = interpolate(from: startFrame.origin, to: targetOrigin, progress: easeOutCubic(progress))
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutAnimationDuration * progress) { [weak self] in
                _ = self?.set(window: window, position: origin)
            }
        }

        return firstResult
    }

    private func interpolate(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private func interpolate(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func easeOutCubic(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    private func accessibilityFrame(fromAppKitFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func appKitFrame(fromAccessibilityFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func accessibilityBounds(for screen: NSScreen) -> CGRect {
        accessibilityFrame(fromAppKitFrame: screen.frame, on: screen)
    }

    private func set(window: AXUIElement, frame: CGRect) -> (succeeded: Bool, sizeStatus: AXError, positionStatus: AXError) {
        var origin = frame.origin
        var size = frame.size

        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return (false, .failure, .failure)
        }

        let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return (sizeStatus == .success && positionStatus == .success, sizeStatus, positionStatus)
    }

    private func set(window: AXUIElement, position: CGPoint) -> (succeeded: Bool, positionStatus: AXError) {
        var origin = position

        guard let positionValue = AXValueCreate(.cgPoint, &origin) else {
            return (false, .failure)
        }

        let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return (positionStatus == .success, positionStatus)
    }
}

private extension WindowLayoutMode {
    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .centerHalf: "Center Half"
        }
    }
}

private extension WindowMovePosition {
    var title: String {
        switch self {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        }
    }
}
