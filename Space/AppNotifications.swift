// Purpose: Centralizes internal notification names used to decouple services, windows, and shortcut UI.

import Foundation

/// Keyboard navigation for the history list, routed from the window's responder
/// chain so the keys work as soon as the window is up, without clicking into the list.
enum HistoryNavigationCommand {
    case previous
    case next
    case copy
}

extension Notification.Name {
    static let historyNavigation = Notification.Name("Space.historyNavigation")
    static let showClipboardHistory = Notification.Name("Space.showClipboardHistory")
    static let openClipboardWindow = Notification.Name("Space.openClipboardWindow")
    static let cancelShortcutRecording = Notification.Name("Space.cancelShortcutRecording")
}
