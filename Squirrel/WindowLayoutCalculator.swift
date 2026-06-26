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

    static func targetFrame(for position: WindowMovePosition, currentFrame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let targetX: CGFloat
        switch position {
        case .left:
            targetX = visibleFrame.minX
        case .center:
            targetX = visibleFrame.midX - currentFrame.width / 2
        case .right:
            targetX = visibleFrame.maxX - currentFrame.width
        }

        return CGRect(
            x: targetX,
            y: clamped(currentFrame.minY, minimum: visibleFrame.minY, maximum: visibleFrame.maxY - currentFrame.height),
            width: currentFrame.width,
            height: currentFrame.height
        )
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard minimum <= maximum else { return minimum }
        return min(max(value, minimum), maximum)
    }
}
