// Purpose: Centralizes internal notification names used to decouple services, windows, and shortcut UI.

import Foundation

extension Notification.Name {
    static let showClipboardHistory = Notification.Name("Space.showClipboardHistory")
    static let openClipboardWindow = Notification.Name("Space.openClipboardWindow")
    static let cancelShortcutRecording = Notification.Name("Space.cancelShortcutRecording")
}
