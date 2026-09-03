// Purpose: Sends a paste keystroke to whichever app is frontmost after a history pick.

import AppKit
import ApplicationServices
import Carbon
import Foundation

enum PasteService {
    /// The panel is ordered out first, so the source app needs a moment to take key
    /// status back before the keystroke arrives.
    private static let focusHandoverDelay: TimeInterval = 0.12

    /// Posts Command-V to the frontmost app. Requires Accessibility access; without it
    /// synthetic events are dropped, and the entry is still on the pasteboard to paste
    /// by hand, so this reports whether it could try.
    @discardableResult
    static func pasteIntoFrontmostApplication() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + focusHandoverDelay) {
            postPasteShortcut()
        }
        return true
    }

    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
