// Purpose: Provides the SwiftUI control used to capture and update custom keyboard shortcuts.

import SwiftUI

private enum ShortcutTypography {
    static let body = Font.system(size: 12)
    static let secondary = Font.system(size: 11)
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
                    KeyCaptureView { combo in
                        shortcut = combo
                        finishRecording()
                    }
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
                    KeyCaptureView { combo in
                        shortcut = combo
                        finishRecording()
                    }
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

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onCapture: onCapture)
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureView: NSView {
        var onCapture: (HotKeyCombo) -> Void

        init(onCapture: @escaping (HotKeyCombo) -> Void) {
            self.onCapture = onCapture
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
            guard let combo = HotKeyCombo(event: event) else {
                NSSound.beep()
                return
            }
            onCapture(combo)
        }
    }
}
