// Purpose: Registers Carbon global hotkeys, persists user shortcuts, and dispatches triggered actions.

import AppKit
import Carbon
import Combine
import Foundation

final class HotKeyManager: ObservableObject {
    @Published private(set) var shortcuts: [HotKeyCommand: HotKeyCombo]
    @Published private(set) var registrationError: String?
    @Published private(set) var lastEventMessage: String?

    private var refs: [HotKeyCommand: EventHotKeyRef] = [:]
    private var actions: [HotKeyCommand: () -> Void] = [:]
    private var isSuspended = false
    private var lastPerformedCommand: HotKeyCommand?
    private var lastPerformedAt = Date.distantPast
    private var eventHandlerRef: EventHandlerRef?

    private static weak var activeManager: HotKeyManager?
    private static let signature = OSType(0x5351524C)
    private static let defaultsKey = "Space.Shortcuts"
    private static let legacyDefaultsKey = "Squirrel.Shortcuts"
    private static let duplicateEventInterval: TimeInterval = 0.18

    init() {
        self.shortcuts = Self.loadShortcuts()
        installEventHandlerIfNeeded()
        registerAll()
    }

    deinit {
        unregisterAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func setAction(_ command: HotKeyCommand, action: @escaping () -> Void) {
        actions[command] = action
    }

    func updateShortcut(_ combo: HotKeyCombo, for command: HotKeyCommand) {
        shortcuts[command] = combo
        saveShortcuts()
        if !isSuspended {
            registerAll()
        }
    }

    func shortcut(for command: HotKeyCommand) -> HotKeyCombo {
        shortcuts[command] ?? HotKeyCombo.defaultShortcuts[command]!
    }

    func suspendHotKeys() {
        isSuspended = true
        unregisterAll()
    }

    func resumeHotKeys() {
        isSuspended = false
        registerAll()
    }

    func reportActionFailure(_ message: String, for command: HotKeyCommand? = nil) {
        if let command, lastPerformedCommand != command {
            return
        }
        lastEventMessage = message
    }

    private func perform(commandID: UInt32) {
        guard let command = HotKeyCommand.allCases.first(where: { $0.carbonID == commandID }) else { return }
        perform(command)
    }

    private func perform(_ command: HotKeyCommand) {
        DispatchQueue.main.async {
            let now = Date()
            if self.lastPerformedCommand == command,
               now.timeIntervalSince(self.lastPerformedAt) < Self.duplicateEventInterval {
                return
            }

            self.lastPerformedCommand = command
            self.lastPerformedAt = now
            guard let action = self.actions[command] else {
                self.lastEventMessage = "\(command.title) shortcut was triggered, but its action is not initialized."
                return
            }

            self.lastEventMessage = nil
            action()
        }
    }

    private func registerAll() {
        unregisterAll()
        registrationError = nil

        for command in HotKeyCommand.allCases {
            let combo = shortcut(for: command)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: command.carbonID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                combo.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                refs[command] = ref
            } else {
                registrationError = "\(command.title) shortcut registration failed (\(status)). It may conflict with the system or another app."
            }
        }
    }

    private func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        Self.activeManager = self
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }

            HotKeyManager.activeManager?.perform(commandID: hotKeyID.id)
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
        if status != noErr {
            registrationError = "Shortcut event handler installation failed (\(status))."
        }
    }

    private func saveShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func loadShortcuts() -> [HotKeyCommand: HotKeyCombo] {
        shortcutsByMergingDefaults(
            from: UserDefaults.standard.data(forKey: defaultsKey)
                ?? UserDefaults.standard.data(forKey: legacyDefaultsKey)
        )
    }

    static func shortcutsByMergingDefaults(from data: Data?) -> [HotKeyCommand: HotKeyCombo] {
        guard let data else {
            return HotKeyCombo.defaultShortcuts
        }

        let decoded: [HotKeyCommand: HotKeyCombo]
        if let commandKeyedShortcuts = try? JSONDecoder().decode([HotKeyCommand: HotKeyCombo].self, from: data) {
            decoded = commandKeyedShortcuts
        } else if let rawKeyedShortcuts = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data) {
            decoded = rawKeyedShortcuts.reduce(into: [:]) { result, item in
                guard let command = HotKeyCommand(rawValue: item.key) else { return }
                result[command] = item.value
            }
        } else {
            return HotKeyCombo.defaultShortcuts
        }

        var shortcuts = decoded.merging(HotKeyCombo.defaultShortcuts) { current, _ in current }

        if shortcuts[.clipboardWindow] == HotKeyCombo.legacyClipboardWindowShortcut {
            shortcuts[.clipboardWindow] = HotKeyCombo.defaultShortcuts[.clipboardWindow]
        }

        for (command, legacyShortcut) in HotKeyCombo.legacyWindowShortcuts where shortcuts[command] == legacyShortcut {
            shortcuts[command] = HotKeyCombo.defaultShortcuts[command]
        }

        return shortcuts
    }
}
