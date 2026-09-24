// Purpose: Keeps a menu bar entry that reopens the main window when no Dock icon is available,
// and turns it into a recording indicator with a stop button while the screen is recorded.

import AppKit
import Combine
import Foundation

@MainActor
final class StatusItemController {
    private let screenRecordingService: ScreenRecordingService
    private var statusItem: NSStatusItem?
    private var recordingObservation: AnyCancellable?
    private var recordingTimer: Timer?
    private var isRecordingDotVisible = true
    private let normalImage = StatusItemController.emojiImage("\u{1F303}")

    init(screenRecordingService: ScreenRecordingService) {
        self.screenRecordingService = screenRecordingService
    }

    func install() {
        guard statusItem == nil else { return }

        // variableLength sizes the slot to the glyph; squareLength pins it to the full
        // menu bar height, which leaves the glyph stranded in a wide empty button.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        showNormalState()

        recordingObservation = screenRecordingService.$isRecording
            .removeDuplicates()
            .sink { [weak self] isRecording in
                if isRecording {
                    self?.showRecordingState()
                } else {
                    self?.showNormalState()
                }
            }
    }

    private func showNormalState() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusItem?.button?.image = normalImage
        statusItem?.button?.toolTip = "Open Space"
        statusItem?.button?.setAccessibilityLabel("Open Space")
    }

    /// The system's own recording indicator is small and cannot be changed, so while
    /// recording this item becomes a blue pill with a blinking red dot and the elapsed
    /// time, and a click on it stops the recording.
    private func showRecordingState() {
        isRecordingDotVisible = true
        updateRecordingIndicator()
        statusItem?.button?.toolTip = "Click to stop recording"

        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRecordingDotVisible.toggle()
                self.updateRecordingIndicator()
            }
        }
        // Common modes keep it ticking while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func updateRecordingIndicator() {
        let elapsed = screenRecordingService.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let text = Self.elapsedText(elapsed)
        statusItem?.button?.image = Self.recordingIndicatorImage(elapsedText: text, dotVisible: isRecordingDotVisible)
        statusItem?.button?.setAccessibilityLabel("Recording, \(text). Click to stop.")
    }

    /// A click opens the panel, or stops the recording while one is running. A
    /// right-click or Control-click offers a menu, which is the only way to quit without
    /// opening the panel: an accessory app has no Dock icon to right-click and no main
    /// menu for Command-Q to act on.
    @objc private func handleClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if screenRecordingService.isRecording {
            stopRecording()
        } else {
            openMainWindow()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        if screenRecordingService.isRecording {
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(.separator())
        }
        let openItem = NSMenuItem(title: "Open Space", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Space", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Just below the button, whichever way its coordinates run.
        let gap: CGFloat = 5
        let location = NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + gap : button.bounds.minY - gap)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func openMainWindow() {
        NotificationCenter.default.post(name: .openClipboardWindow, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func stopRecording() {
        screenRecordingService.stopActiveRecording()
    }

    /// Minutes and seconds, with hours only once there are any.
    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// A blue pill holding a red dot, drawn or left out to blink, and the elapsed time.
    /// The dot's space is kept either way so the item does not shift as it blinks.
    static func recordingIndicatorImage(elapsedText: String, dotVisible: Bool) -> NSImage {
        let height: CGFloat = 22
        let pillHeight: CGFloat = 18
        let dotDiameter: CGFloat = 8
        let leading: CGFloat = 7
        let gap: CGFloat = 5
        let trailing: CGFloat = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = elapsedText as NSString
        let textSize = text.size(withAttributes: attributes)
        let width = (leading + dotDiameter + gap + textSize.width + trailing).rounded(.up)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let pillRect = CGRect(x: 0, y: (height - pillHeight) / 2, width: width, height: pillHeight)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

            if dotVisible {
                let dot = NSBezierPath(ovalIn: CGRect(
                    x: leading,
                    y: (height - dotDiameter) / 2,
                    width: dotDiameter,
                    height: dotDiameter
                ))
                NSColor.systemRed.setFill()
                dot.fill()
                // Red on blue is hard to separate at this size; a thin rim keeps it crisp.
                NSColor.white.withAlphaComponent(0.85).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }

            text.draw(
                at: NSPoint(x: leading + dotDiameter + gap, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The menu bar glyph. Emoji carry their own colour, so this is not a template
    /// image: as a template the menu bar would keep only the alpha channel and flatten
    /// it into a solid silhouette.
    private static func emojiImage(_ emoji: String, size: CGFloat = 22, inset: CGFloat = 3) -> NSImage {
        let font = NSFont(name: "Apple Color Emoji", size: size) ?? .systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: emoji, attributes: [.font: font])
        )

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // Centre on the glyph's drawn bounds rather than its typographic ones, which
            // include the line's ascent and descent and would sit it low in the box.
            let ink = CTLineGetImageBounds(line, context)
            guard ink.width > 0, ink.height > 0 else { return false }

            let available = size - inset * 2
            let scale = min(available / ink.width, available / ink.height)
            context.saveGState()
            context.translateBy(
                x: (size - ink.width * scale) / 2 - ink.minX * scale,
                y: (size - ink.height * scale) / 2 - ink.minY * scale
            )
            context.scaleBy(x: scale, y: scale)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            return true
        }

        image.isTemplate = false
        return image
    }
}
