// Purpose: Centralizes internal notification names used to decouple services, windows, and shortcut UI.

import Foundation

extension Notification.Name {
    static let showClipboardHistory = Notification.Name("Squirrel.showClipboardHistory")
    static let openClipboardWindow = Notification.Name("Squirrel.openClipboardWindow")
    static let cancelShortcutRecording = Notification.Name("Squirrel.cancelShortcutRecording")
}
