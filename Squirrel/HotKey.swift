// Purpose: Defines supported shortcut commands and serializable key-combination metadata.

import AppKit
import Carbon
import Foundation

enum HotKeyCommand: String, CaseIterable, Codable, Identifiable {
    case clipboardWindow
    case leftHalf
    case rightHalf
    case centerHalf
    case lockScreen
    case captureArea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboardWindow: "Show Clipboard History"
        case .leftHalf: "Window Left Two Thirds"
        case .rightHalf: "Window Right Two Thirds"
        case .centerHalf: "Window Center Two Thirds"
        case .lockScreen: "Lock Screen"
        case .captureArea: "Capture Area"
        }
    }

    var carbonID: UInt32 {
        switch self {
        case .clipboardWindow: 1
        case .leftHalf: 2
        case .rightHalf: 3
        case .centerHalf: 4
        case .lockScreen: 5
        case .captureArea: 6
        }
    }
}

struct HotKeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcuts: [HotKeyCommand: HotKeyCombo] = [
        .clipboardWindow: HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)),
        .leftHalf: HotKeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .rightHalf: HotKeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .centerHalf: HotKeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .lockScreen: HotKeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .captureArea: HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey | cmdKey))
    ]

    static let legacyClipboardWindowShortcut = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    static let legacyWindowShortcuts: [HotKeyCommand: HotKeyCombo] = [
        .leftHalf: HotKeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey)),
        .rightHalf: HotKeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey)),
        .centerHalf: HotKeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | optionKey))
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        var carbonModifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        guard carbonModifiers != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbonModifiers
    }

    var displayString: String {
        modifierDisplay + keyDisplay
    }

    private var modifierDisplay: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "^" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        return output
    }

    private var keyDisplay: String {
        switch Int(keyCode) {
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Escape: "Esc"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        default: "Key \(keyCode)"
        }
    }
}
