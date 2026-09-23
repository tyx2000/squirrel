// Purpose: Keeps a menu bar entry that reopens the main window when no Dock icon is available.

import AppKit
import Foundation

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }

        // variableLength sizes the slot to the glyph; squareLength pins it to the full
        // menu bar height, which leaves the glyph stranded in a wide empty button.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.emojiImage("\u{1F303}")
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Open Space"
        item.button?.setAccessibilityLabel("Open Space")
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// A click opens the panel. A right-click or Control-click offers a menu, which is
    /// the only way to quit without opening the panel: an accessory app has no Dock icon
    /// to right-click and no main menu for Command-Q to act on.
    @objc private func handleClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            openMainWindow()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Space", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Space", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Just below the button, whichever way its coordinates run.
        let gap: CGFloat = 5
        let location = NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + gap : button.bounds.minY - gap)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func openMainWindow() {
        NotificationCenter.default.post(name: .openClipboardWindow, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The menu bar glyph. Emoji carry their own colour, so this is not a template
    /// image: as a template the menu bar would keep only the alpha channel and flatten
    /// it into a solid silhouette.
    private static func emojiImage(_ emoji: String, size: CGFloat = 22, inset: CGFloat = 3) -> NSImage {
        let font = NSFont(name: "Apple Color Emoji", size: size) ?? .systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: emoji, attributes: [.font: font])
        )

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // Centre on the glyph's drawn bounds rather than its typographic ones, which
            // include the line's ascent and descent and would sit it low in the box.
            let ink = CTLineGetImageBounds(line, context)
            guard ink.width > 0, ink.height > 0 else { return false }

            let available = size - inset * 2
            let scale = min(available / ink.width, available / ink.height)
            context.saveGState()
            context.translateBy(
                x: (size - ink.width * scale) / 2 - ink.minX * scale,
                y: (size - ink.height * scale) / 2 - ink.minY * scale
            )
            context.scaleBy(x: scale, y: scale)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            return true
        }

        image.isTemplate = false
        return image
    }
}
