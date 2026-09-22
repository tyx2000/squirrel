// Purpose: Provides the SwiftUI control used to capture and update custom keyboard shortcuts.

import SwiftUI

private enum ShortcutTypography {
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
}

struct ShortcutRecorderView: View {
    @EnvironmentObject private var hotKeyManager: HotKeyManager

    let title: String
    @Binding var shortcut: HotKeyCombo

    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(isRecording ? "Press New Shortcut" : shortcut.displayString) {
                startRecording()
            }
            .buttonStyle(.bordered)
            .monospaced()
            .background {
                if isRecording {
                    KeyCaptureView(
                        onCapture: { combo in
                            shortcut = combo
                            finishRecording()
                        },
                        onCancel: { cancelRecording() }
                    )
                    .frame(width: 1, height: 1)
                }
            }
        }
        .font(ShortcutTypography.body)
        .onDisappear {
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelShortcutRecording)) { _ in
            cancelRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        // Hotkey suspension is shared, so a second recorder finishing would re-register
        // every hotkey while this one still waits for keys. End any other recorder first;
        // this one is not recording yet, so it ignores the notification itself.
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        hotKeyManager.suspendHotKeys()
        isRecording = true
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        hotKeyManager.resumeHotKeys()
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        hotKeyManager.resumeHotKeys()
    }
}

struct CompactShortcutRecorderView: View {
    @EnvironmentObject private var hotKeyManager: HotKeyManager

    let title: String
    @Binding var shortcut: HotKeyCombo

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(ShortcutTypography.secondary)
                .foregroundStyle(.secondary)
            Button(isRecording ? "Press New Shortcut" : shortcut.displayString) {
                startRecording()
            }
            .buttonStyle(.bordered)
            .monospaced()
            .background {
                if isRecording {
                    KeyCaptureView(
                        onCapture: { combo in
                            shortcut = combo
                            finishRecording()
                        },
                        onCancel: { cancelRecording() }
                    )
                    .frame(width: 1, height: 1)
                }
            }
        }
        .font(ShortcutTypography.body)
        .onDisappear {
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelShortcutRecording)) { _ in
            cancelRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        // Hotkey suspension is shared, so a second recorder finishing would re-register
        // every hotkey while this one still waits for keys. End any other recorder first;
        // this one is not recording yet, so it ignores the notification itself.
        NotificationCenter.default.post(name: .cancelShortcutRecording, object: nil)
        hotKeyManager.suspendHotKeys()
        isRecording = true
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        hotKeyManager.resumeHotKeys()
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        hotKeyManager.resumeHotKeys()
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (HotKeyCombo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onCapture: onCapture, onCancel: onCancel)
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureView: NSView {
        private static let escapeKeyCode: UInt16 = 53

        var onCapture: (HotKeyCombo) -> Void
        var onCancel: () -> Void

        init(onCapture: @escaping (HotKeyCombo) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            // This view takes every key while recording, so Escape never reaches the
            // window. A bare Escape backs out and leaves the existing shortcut alone.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty {
                onCancel()
                return
            }

            guard let combo = HotKeyCombo(event: event) else {
                NSSound.beep()
                return
            }
            onCapture(combo)
        }
    }
}
