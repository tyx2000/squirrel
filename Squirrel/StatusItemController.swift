// Purpose: Manages the menu bar status item, including left-click window opening and right-click Quit.

import AppKit

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }()

    override init() {
        super.init()

        if let button = statusItem.button {
            if let image = Self.makeMenuBarIcon() {
                image.isTemplate = true
                button.image = image
                button.imageScaling = .scaleProportionallyDown
            } else {
                button.title = "S"
            }
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.isVisible = true
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            openWindow()
        }
    }

    @objc private func openWindow() {
        NotificationCenter.default.post(name: .openClipboardWindow, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func makeMenuBarIcon() -> NSImage? {
        ["watermelon", "cherries", "leaf.fill", "circle.fill"]
            .lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Squirrel") }
            .first
    }
}
