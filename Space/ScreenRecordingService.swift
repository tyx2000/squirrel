// Purpose: Coordinates screen/window recording options and streamed MP4 output.

import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenRecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var outputURL: URL?

    private var activeRecording: ActiveRecording?
    private var isPreparingRecording = false
    private var isShowingPermissionGuide = false

    func clearMessage() {
        lastMessage = nil
    }

    func toggleScreenRecording(onFailure: @escaping (String) -> Void) {
        guard #available(macOS 15.0, *) else {
            fail("Screen recording requires macOS 15 or later.", onFailure: onFailure)
            return
        }

        if activeRecording != nil {
            stopRecording(onFailure: onFailure)
            return
        }

        guard !isPreparingRecording else {
            fail("Screen recording is still preparing.", onFailure: onFailure)
            return
        }

        startRecording(onFailure: onFailure)
    }

    private func startRecording(onFailure: @escaping (String) -> Void) {
        guard !isPreparingRecording, activeRecording == nil else { return }

        guard hasScreenCaptureAccess() else {
            showScreenRecordingGuide(onFailure: onFailure)
            return
        }

        MainWindowPresenter.shared.hideClipboardWindow()
        isPreparingRecording = true

        Task { @MainActor in
            defer { isPreparingRecording = false }

            do {
                let content = try await Self.loadRecordableContent()
                guard !content.displays.isEmpty || !content.windows.isEmpty else {
                    fail("Screen recording found no screens or windows to record.", onFailure: onFailure)
                    return
                }

                guard let request = presentRecordingRequest(for: content) else {
                    return
                }

                try await beginRecording(request)
            } catch {
                fail("Screen recording failed: \(error.localizedDescription)", onFailure: onFailure)
            }
        }
    }

    private func stopRecording(onFailure: @escaping (String) -> Void) {
        guard let recording = activeRecording else { return }

        Task { @MainActor in
            do {
                try await recording.stop()
            } catch {
                // The stream is already unusable, so drop it rather than leaving the
                // toggle stuck in its stop branch forever.
                if activeRecording === recording {
                    activeRecording = nil
                    isRecording = false
                }
                fail("Screen recording could not stop: \(error.localizedDescription)", onFailure: onFailure)
            }
        }
    }

    private func beginRecording(_ request: RecordingRequest) async throws {
        let filter: SCContentFilter
        switch request.target {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = Self.streamConfiguration(for: filter, recordsAudio: request.recordsAudio)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let outputURL = Self.makeRecordingURL()
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let delegate = RecordingOutputDelegate()
        let recordingOutput = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
        let recording = ActiveRecording(
            stream: stream,
            recordingOutput: recordingOutput,
            delegate: delegate,
            outputURL: outputURL
        )

        delegate.onStart = { [weak self, weak recording] in
            Task { @MainActor in
                guard let self, self.activeRecording === recording else { return }
                self.isRecording = true
                self.outputURL = outputURL
                self.lastMessage = "Recording started: \(outputURL.lastPathComponent)"
            }
        }

        delegate.onFinish = { [weak self, weak recording] in
            Task { @MainActor in
                guard let self, self.activeRecording === recording else { return }
                self.activeRecording = nil
                self.isRecording = false
                self.outputURL = outputURL
                self.lastMessage = "Recording saved to Downloads: \(outputURL.lastPathComponent)"
            }
        }

        delegate.onFailure = { [weak self, weak recording] error in
            Task { @MainActor in
                guard let self, self.activeRecording === recording else { return }
                self.activeRecording = nil
                self.isRecording = false
                self.outputURL = nil
                self.lastMessage = "Screen recording failed: \(error.localizedDescription)"
            }
        }

        try stream.addRecordingOutput(recordingOutput)

        activeRecording = recording
        self.outputURL = outputURL
        do {
            try await stream.startCapture()
        } catch {
            activeRecording = nil
            self.outputURL = nil
            throw error
        }
    }

    private static func streamConfiguration(for filter: SCContentFilter, recordsAudio: Bool) -> SCStreamConfiguration {
        let contentInfo = SCShareableContent.info(for: filter)
        let scale = max(CGFloat(contentInfo.pointPixelScale), 1)
        let contentSize = contentInfo.contentRect.size
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(contentSize.width * scale))
        configuration.height = max(1, Int(contentSize.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = recordsAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
    }

    private static func loadRecordableContent() async throws -> RecordableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let processID = ProcessInfo.processInfo.processIdentifier
                let windows = (content?.windows ?? [])
                    .filter { window in
                        guard window.isOnScreen, window.windowLayer == 0 else { return false }
                        guard window.owningApplication?.processID != processID else { return false }
                        guard window.frame.width >= 80, window.frame.height >= 60 else { return false }
                        return window.title?.isEmpty == false || window.owningApplication != nil
                    }
                    .sorted { lhs, rhs in
                        displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
                    }

                let mainDisplayID = CGMainDisplayID()
                let displays = (content?.displays ?? [])
                    .sorted { lhs, rhs in
                        if lhs.displayID == mainDisplayID {
                            return true
                        }
                        if rhs.displayID == mainDisplayID {
                            return false
                        }
                        return lhs.displayID < rhs.displayID
                    }

                continuation.resume(returning: RecordableContent(displays: displays, windows: windows))
            }
        }
    }

    private func presentRecordingRequest(for content: RecordableContent) -> RecordingRequest? {
        NSApp.activate(ignoringOtherApps: true)

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 360, height: 28), pullsDown: false)
        let options = Self.recordingOptions(for: content)
        for (index, option) in options.enumerated() {
            popup.addItem(withTitle: option.title)
            popup.item(at: index)?.representedObject = index
        }
        popup.selectItem(at: 0)

        let audioCheckbox = NSButton(checkboxWithTitle: "Record system audio", target: nil, action: nil)
        audioCheckbox.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        audioCheckbox.state = .off

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 66))
        accessoryView.addSubview(popup)
        accessoryView.addSubview(audioCheckbox)

        let alert = NSAlert()
        alert.messageText = "Record Screen"
        alert.informativeText = "Choose full screen or a window to record. Audio is off by default. The MP4 will be saved to Downloads."
        alert.alertStyle = .informational
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = max(0, popup.indexOfSelectedItem)
        guard options.indices.contains(selectedIndex) else { return nil }
        return RecordingRequest(
            target: options[selectedIndex].target,
            recordsAudio: audioCheckbox.state == .on
        )
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func showScreenRecordingGuide(onFailure: @escaping (String) -> Void) {
        let message = "Screen recording requires Screen Recording access in System Settings."
        fail(message, onFailure: onFailure)
        guard !isShowingPermissionGuide else { return }

        isShowingPermissionGuide = true
        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Required"
        alert.informativeText = "Enable Space in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        isShowingPermissionGuide = false
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        MainWindowPresenter.shared.suspendAutoHideUntilReactivated()
        NSWorkspace.shared.open(url)
    }

    private func fail(_ message: String, onFailure: @escaping (String) -> Void) {
        lastMessage = message
        onFailure(message)
    }

    private static func makeRecordingURL() -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let fileName = "Space-\(formatter.string(from: Date())).mp4"
        return downloadsURL.appendingPathComponent(fileName)
    }

    nonisolated private static func displayName(for window: SCWindow) -> String {
        let appName = window.owningApplication?.applicationName ?? "Unknown App"
        guard let title = window.title, !title.isEmpty else {
            return appName
        }
        return "\(appName) - \(title)"
    }

    nonisolated private static func displayName(for display: SCDisplay) -> String {
        let mainSuffix = display.displayID == CGMainDisplayID() ? " (Main)" : ""
        let bounds = CGDisplayBounds(display.displayID)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else {
            return "Full Screen\(mainSuffix)"
        }
        return "Full Screen\(mainSuffix) - \(width)x\(height)"
    }

    private static func recordingOptions(for content: RecordableContent) -> [RecordingOption] {
        let displayOptions = content.displays.map { display in
            RecordingOption(title: displayName(for: display), target: .display(display))
        }
        let windowOptions = content.windows.map { window in
            RecordingOption(title: displayName(for: window), target: .window(window))
        }
        return displayOptions + windowOptions
    }
}

private struct RecordingRequest {
    var target: RecordingTarget
    var recordsAudio: Bool
}

private struct RecordableContent {
    var displays: [SCDisplay]
    var windows: [SCWindow]
}

private struct RecordingOption {
    var title: String
    var target: RecordingTarget
}

private enum RecordingTarget {
    case display(SCDisplay)
    case window(SCWindow)
}

private final class ActiveRecording {
    let stream: SCStream
    let recordingOutput: SCRecordingOutput
    let delegate: RecordingOutputDelegate
    let outputURL: URL

    init(
        stream: SCStream,
        recordingOutput: SCRecordingOutput,
        delegate: RecordingOutputDelegate,
        outputURL: URL
    ) {
        self.stream = stream
        self.recordingOutput = recordingOutput
        self.delegate = delegate
        self.outputURL = outputURL
    }

    func stop() async throws {
        try await stream.stopCapture()
    }
}

private final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            onStart?()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            onFinish?()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            onFailure?(error)
        }
    }
}
