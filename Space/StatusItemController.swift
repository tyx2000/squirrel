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
        item.button?.image = Self.piImage()
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

    /// The mathematical constant's symbol, drawn from the system font's glyph outline
    /// as a template image so the menu bar tints it for light, dark, and highlighted
    /// states.
    private static func piImage(size: CGFloat = 22, inset: CGFloat = 2) -> NSImage {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            guard let path = glyphPath(for: "\u{03C0}", font: font) else {
                // Without the outline, lay the character out instead of drawing nothing.
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let text = "\u{03C0}" as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                    withAttributes: attributes
                )
                return true
            }

            // Scale the glyph's outline into the box. Filling the box entirely left it
            // noticeably heavier than its neighbours, whose ink measures 14 to 16.5pt.
            let bounds = path.boundingBoxOfPath
            let available = size - inset * 2
            let scale = min(available / bounds.width, available / bounds.height)

            context.saveGState()
            context.translateBy(
                x: (size - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size - bounds.height * scale) / 2 - bounds.minY * scale
            )
            context.scaleBy(x: scale, y: scale)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            return true
        }

        image.isTemplate = true
        return image
    }

    private static func glyphPath(for character: String, font: NSFont) -> CGPath? {
        var unichar = Array(character.utf16)
        guard unichar.count == 1 else { return nil }

        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font as CTFont, &unichar, &glyph, 1) else { return nil }
        return CTFontCreatePathForGlyph(font as CTFont, glyph, nil)
    }
}
