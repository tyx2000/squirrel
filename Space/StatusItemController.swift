// Purpose: Keeps a menu bar entry that reopens the main window when no Dock icon is available.

import AppKit
import Foundation

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.hexagramImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Open Space"
        item.button?.setAccessibilityLabel("Open Space")
        item.button?.target = self
        item.button?.action = #selector(openMainWindow)
        statusItem = item
    }

    @objc private func openMainWindow() {
        NotificationCenter.default.post(name: .openClipboardWindow, object: nil)
    }

    /// Two overlapping equilateral triangles. Drawn as a template image so the menu bar
    /// tints it for light, dark, and highlighted states.
    private static func hexagramImage(
        size: CGFloat = 18,
        lineWidth: CGFloat = 1.1,
        inset: CGFloat = 1
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let center = CGPoint(x: size / 2, y: size / 2)
            // Half the stroke sits outside the path, and the inset keeps the points
            // from crowding neighbouring menu bar items.
            let radius = size / 2 - lineWidth / 2 - inset
            let path = NSBezierPath()

            // One triangle points up, the other points down; each vertex sits on the
            // same circle, 120 degrees apart.
            for startDegrees in [90.0, 270.0] {
                let vertices = (0..<3).map { index -> CGPoint in
                    let radians = (startDegrees + Double(index) * 120) * .pi / 180
                    return CGPoint(
                        x: center.x + radius * cos(radians),
                        y: center.y + radius * sin(radians)
                    )
                }

                path.move(to: vertices[0])
                path.line(to: vertices[1])
                path.line(to: vertices[2])
                path.close()
            }

            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }

        image.isTemplate = true
        return image
    }
}
