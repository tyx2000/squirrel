// Purpose: Centralizes shortcut window geometry so runtime behavior and tests share the same layout contract.

import CoreGraphics
import Foundation

enum WindowLayoutCalculator {
    // Shortcut names promise two-thirds placement; keeping the math here prevents UI labels,
    // tests, and Accessibility window movement from drifting into different behavior.
    static func targetFrame(for mode: WindowLayoutMode, in visibleFrame: CGRect) -> CGRect {
        let targetWidth = floor(visibleFrame.width * 2 / 3)

        switch mode {
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: targetWidth, height: visibleFrame.height)
        case .rightHalf:
            return CGRect(x: visibleFrame.maxX - targetWidth, y: visibleFrame.minY, width: targetWidth, height: visibleFrame.height)
        case .centerHalf:
            return CGRect(x: visibleFrame.midX - targetWidth / 2, y: visibleFrame.minY, width: targetWidth, height: visibleFrame.height)
        }
    }
}
