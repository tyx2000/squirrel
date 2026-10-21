// Purpose: Registers Carbon global hotkeys and trackpad gestures, persists them, and dispatches triggered actions.

import AppKit
import Carbon
import Combine
import Foundation

final class HotKeyManager: ObservableObject {
    @Published private(set) var shortcuts: [HotKeyCommand: HotKeyCombo]
    @Published private(set) var gestures: [HotKeyCommand: TrackpadGesture]
    @Published private(set) var registrationError: String?
    @Published private(set) var trackpadError: String?
    @Published private(set) var lastEventMessage: String?

    private var refs: [HotKeyCommand: EventHotKeyRef] = [:]
    private var actions: [HotKeyCommand: () -> Void] = [:]
    private var isSuspended = false
    private var lastPerformedCommand: HotKeyCommand?
    private var lastPerformedAt = Date.distantPast
    private var eventHandlerRef: EventHandlerRef?
    private let trackpadMonitor = TrackpadGestureMonitor()

    private static weak var activeManager: HotKeyManager?
    private static let signature = OSType(0x5351524C)
    private static let defaultsKey = "Space.Shortcuts"
    private static let legacyDefaultsKey = "Squirrel.Shortcuts"
    private static let gesturesDefaultsKey = "Space.TrackpadGestures"
    private static let duplicateEventInterval: TimeInterval = 0.18

    init() {
        self.shortcuts = Self.loadShortcuts()
        self.gestures = Self.gestures(from: UserDefaults.standard.data(forKey: Self.gesturesDefaultsKey))
        installEventHandlerIfNeeded()
        registerAll()

        trackpadMonitor.onGesture = { [weak self] gesture in
            guard let self,
                  let command = HotKeyCommand.allCases.first(where: { self.gestures[$0] == gesture }) else {
                return
            }
            self.perform(command)
        }
        updateTrackpadMonitor()
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
        let previous = shortcut(for: command)
        let result = Self.assigning(combo, to: command, in: shortcuts)
        shortcuts = result.shortcuts
        if let displaced = result.displaced {
            lastEventMessage = "\(combo.displayString) was used by \(displaced.title), which now uses \(previous.displayString)."
        }

        saveShortcuts()
        if !isSuspended {
            registerAll()
        }
    }

    /// Assigns `combo` to `command`. A combination another command already holds would
    /// make its second registration fail and silently disable one of the two, so they
    /// swap: the other command takes over `command`'s previous combination.
    static func assigning(
        _ combo: HotKeyCombo,
        to command: HotKeyCommand,
        in shortcuts: [HotKeyCommand: HotKeyCombo]
    ) -> (shortcuts: [HotKeyCommand: HotKeyCombo], displaced: HotKeyCommand?) {
        func current(_ command: HotKeyCommand) -> HotKeyCombo? {
            shortcuts[command] ?? HotKeyCombo.defaultShortcuts[command]
        }

        var updated = shortcuts
        var displaced: HotKeyCommand?
        if let conflicting = HotKeyCommand.allCases.first(where: { $0 != command && current($0) == combo }),
           let previous = current(command) {
            updated[conflicting] = previous
            displaced = conflicting
        }
        updated[command] = combo
        return (updated, displaced)
    }

    func shortcut(for command: HotKeyCommand) -> HotKeyCombo {
        shortcuts[command] ?? HotKeyCombo.defaultShortcuts[command]!
    }

    func gesture(for command: HotKeyCommand) -> TrackpadGesture? {
        gestures[command]
    }

    /// Binds `gesture` to `command`, or unbinds it with nil.
    func updateGesture(_ gesture: TrackpadGesture?, for command: HotKeyCommand) {
        let previous = gestures[command]
        let result = Self.assigning(gesture, to: command, in: gestures)
        gestures = result.gestures
        if let gesture, let displaced = result.displaced {
            lastEventMessage = previous.map {
                "\(gesture.title) was used by \(displaced.fullTitle), which now uses \($0.title)."
            } ?? "\(gesture.title) was used by \(displaced.fullTitle), which now has no gesture."
        }

        saveGestures()
        updateTrackpadMonitor()
    }

    /// A gesture can only run one command, so one another command holds swaps the same
    /// way a keyboard shortcut does: that command takes `command`'s previous gesture, or
    /// none if it had none.
    static func assigning(
        _ gesture: TrackpadGesture?,
        to command: HotKeyCommand,
        in gestures: [HotKeyCommand: TrackpadGesture]
    ) -> (gestures: [HotKeyCommand: TrackpadGesture], displaced: HotKeyCommand?) {
        var updated = gestures
        var displaced: HotKeyCommand?
        if let gesture,
           let conflicting = HotKeyCommand.allCases.first(where: { $0 != command && gestures[$0] == gesture }) {
            updated[conflicting] = gestures[command]
            displaced = conflicting
        }
        updated[command] = gesture
        return (updated, displaced)
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
        var failures: [String] = []

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
                failures.append("\(command.title) (\(status))")
            }
        }

        registrationError = failures.isEmpty
            ? nil
            : "Shortcut registration failed for \(failures.joined(separator: ", ")). It may conflict with the system or another app."
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

    /// Reading raw touches has a cost, so the monitor only runs while a gesture is bound.
    private func updateTrackpadMonitor() {
        guard !gestures.isEmpty else {
            trackpadMonitor.stop()
            trackpadError = nil
            return
        }

        trackpadError = trackpadMonitor.start()
            ? nil
            : "Trackpad gestures are unavailable: this version of macOS did not provide the Multi-Touch framework."
    }

    private func saveGestures() {
        let rawGestures = Dictionary(uniqueKeysWithValues: gestures.map { ($0.key.rawValue, $0.value.rawValue) })
        guard let data = try? JSONEncoder().encode(rawGestures) else { return }
        UserDefaults.standard.set(data, forKey: Self.gesturesDefaultsKey)
    }

    /// Saved by raw value, so a command or gesture a later version drops is skipped
    /// rather than losing every other binding. No gestures are bound by default: they
    /// would compete with the trackpad gestures macOS already has.
    static func gestures(from data: Data?) -> [HotKeyCommand: TrackpadGesture] {
        guard let data,
              let rawGestures = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        var gestures: [HotKeyCommand: TrackpadGesture] = [:]
        for command in HotKeyCommand.allCases {
            guard let rawGesture = rawGestures[command.rawValue],
                  let gesture = TrackpadGesture(rawValue: rawGesture),
                  !gestures.values.contains(gesture) else {
                continue
            }
            gestures[command] = gesture
        }
        return gestures
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

        for (command, combo) in shortcuts where !combo.isSafeGlobalShortcut {
            shortcuts[command] = HotKeyCombo.defaultShortcuts[command]
        }

        if shortcuts[.clipboardWindow] == HotKeyCombo.legacyClipboardWindowShortcut {
            shortcuts[.clipboardWindow] = HotKeyCombo.defaultShortcuts[.clipboardWindow]
        }

        for (command, legacyShortcut) in HotKeyCombo.legacyWindowShortcuts where shortcuts[command] == legacyShortcut {
            shortcuts[command] = HotKeyCombo.defaultShortcuts[command]
        }

        return shortcuts
    }
}
