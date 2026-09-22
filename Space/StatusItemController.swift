// Purpose: Keeps a menu bar entry that reopens the main window when no Dock icon is available.

import AppKit
import Foundation

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }

        // variableLength sizes the slot to the glyph; squareLength pins it to the full
        // menu bar height, which leaves the star stranded in a wide empty button.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.starImage()
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

    /// A Star of Bethlehem: four main rays, four shorter diagonal rays, and an
    /// elongated lower ray. Drawn as a template image so the menu bar tints it for
    /// light, dark, and highlighted states.
    /// 22pt rather than the usual 18: measured against neighbouring menu bar icons,
    /// whose ink runs 14-16.5pt tall, an 18pt box left this glyph at 13pt.
    private static func starImage(size: CGFloat = 22) -> NSImage {
        // Ray lengths as a fraction of the radius, chosen by rasterising candidates at
        // the 2x size the menu bar actually uses.
        let cardinalLength: CGFloat = 0.78
        let diagonalLength: CGFloat = 0.52
        let tailLength: CGFloat = 1.0
        let waistLength: CGFloat = 0.28
        let rayCount = 8
        let degreesPerRay = 360.0 / Double(rayCount)

        // Unit-space outline: a tip for each ray, a waist point between neighbours.
        var unitPoints: [CGPoint] = []
        for index in 0..<rayCount {
            let degrees = 90 - Double(index) * degreesPerRay
            let normalized = ((Int(degrees.rounded()) % 360) + 360) % 360
            let length: CGFloat
            if normalized == 270 {
                length = tailLength
            } else if normalized % 90 == 0 {
                length = cardinalLength
            } else {
                length = diagonalLength
            }

            for (angle, radius) in [(degrees, length), (degrees - degreesPerRay / 2, waistLength)] {
                let radians = angle * .pi / 180
                unitPoints.append(CGPoint(x: radius * cos(radians), y: radius * sin(radians)))
            }
        }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            // Scale the star's own bounding box to fill the image. Without this the
            // shorter rays leave the glyph looking small inside its button.
            let minX = unitPoints.map(\.x).min() ?? -1
            let maxX = unitPoints.map(\.x).max() ?? 1
            let minY = unitPoints.map(\.y).min() ?? -1
            let maxY = unitPoints.map(\.y).max() ?? 1
            let width = max(maxX - minX, 0.001)
            let height = max(maxY - minY, 0.001)
            let scale = min(size / width, size / height)
            let offsetX = -minX * scale + (size - width * scale) / 2
            let offsetY = -minY * scale + (size - height * scale) / 2

            let path = NSBezierPath()
            for (index, point) in unitPoints.enumerated() {
                let mapped = CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY)
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.line(to: mapped)
                }
            }
            path.close()

            NSColor.black.setFill()
            path.fill()
            return true
        }

        image.isTemplate = true
        return image
    }
}
