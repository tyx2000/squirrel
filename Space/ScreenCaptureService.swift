// Purpose: Coordinates area capture, writes screenshots to the pasteboard, and stores them in history.

import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenCaptureService: ObservableObject {
    @Published private(set) var lastMessage: String?

    private let clipboardStore: ClipboardHistoryStore
    private let pinnedImageController = PinnedImageController()
    private var overlayController: CaptureOverlayController?
    private var isPreparingCapture = false
    private var isShowingPermissionGuide = false
    private static let windowHideSettleNanoseconds: UInt64 = 120_000_000

    init(clipboardStore: ClipboardHistoryStore) {
        self.clipboardStore = clipboardStore
    }

    func clearMessage() {
        lastMessage = nil
    }

    func startAreaCapture(onFailure: @escaping (String) -> Void) {
        guard overlayController == nil, !isPreparingCapture else { return }

        guard hasScreenCaptureAccess() else {
            showScreenRecordingGuide(onFailure: onFailure)
            return
        }

        MainWindowPresenter.shared.beginCapturePresentation()
        let didHideWindow = MainWindowPresenter.shared.hideClipboardWindow()
        isPreparingCapture = true

        Task { @MainActor in
            defer { isPreparingCapture = false }

            do {
                // orderOut only reaches the display on the next flush, so let the window
                // leave the screen before it gets frozen into the snapshot.
                if didHideWindow {
                    try? await Task.sleep(nanoseconds: Self.windowHideSettleNanoseconds)
                }

                guard let captureScreen = Self.screenContainingMouse(from: NSScreen.screens) else {
                    MainWindowPresenter.shared.endCapturePresentation()
                    fail("Capture Area could not identify the selected screen.", onFailure: onFailure)
                    return
                }
                let snapshotsByDisplayID = try await Self.captureSnapshots(for: [captureScreen])
                guard !snapshotsByDisplayID.isEmpty else {
                    MainWindowPresenter.shared.endCapturePresentation()
                    fail("Capture Area could not create the screenshot image.", onFailure: onFailure)
                    return
                }

                beginOverlay(with: snapshotsByDisplayID, onFailure: onFailure)
            } catch {
                MainWindowPresenter.shared.endCapturePresentation()
                fail("Capture Area failed: \(error.localizedDescription)", onFailure: onFailure)
            }
        }
    }

    private static func screenContainingMouse(from screens: [NSScreen]) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? screens.first
    }

    private func beginOverlay(
        with snapshotsByDisplayID: [CGDirectDisplayID: CaptureScreenSnapshot],
        onFailure: @escaping (String) -> Void
    ) {
        let controller = CaptureOverlayController(
            snapshotsByDisplayID: snapshotsByDisplayID,
            onComplete: { [weak self] action, screen, snapshot, localSelectionRect, annotations in
                self?.overlayController = nil
                MainWindowPresenter.shared.endCapturePresentation()
                self?.completeCapture(
                    action: action,
                    screen: screen,
                    snapshot: snapshot,
                    localSelectionRect: localSelectionRect,
                    annotations: annotations,
                    onFailure: onFailure
                )
            },
            onCancel: { [weak self] in
                self?.overlayController = nil
                MainWindowPresenter.shared.endCapturePresentation()
            }
        )
        overlayController = controller
        controller.begin()
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func showScreenRecordingGuide(onFailure: @escaping (String) -> Void) {
        let message = "Capture Area requires Screen Recording access in System Settings."
        fail(message, onFailure: onFailure)
        guard !isShowingPermissionGuide else { return }

        MainWindowPresenter.shared.hideClipboardWindow()

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
        NSWorkspace.shared.open(url)
    }

    private func completeCapture(
        action: CaptureOutputAction,
        screen: NSScreen,
        snapshot: CaptureScreenSnapshot,
        localSelectionRect: CGRect,
        annotations: [CaptureAnnotation],
        onFailure: @escaping (String) -> Void
    ) {
        let cropSource = snapshot.fullResImage ?? snapshot.image

        // A copied screenshot goes to the pasteboard and to history, and history refuses
        // anything over its pixel cap, so size it to fit rather than let the two disagree.
        // A pin never enters history and keeps full resolution.
        guard let region = Self.croppedRegion(
            from: cropSource,
            snapshotPointSize: snapshot.pointSize,
            selectionRect: localSelectionRect
        ), let outputImage = Self.renderedCapture(
            from: region,
            annotations: annotations,
            selectionRect: localSelectionRect,
            maxPixelCount: action == .pin ? nil : ClipboardHistoryStore.maxImagePixelCount
        ) else {
            fail("Capture Area could not create the screenshot image.", onFailure: onFailure)
            return
        }

        if action == .pin {
            let result = pinnedImageController.pin(image: outputImage, screen: screen, selectionRect: localSelectionRect)
            if result.didEvict {
                lastMessage = "Pinned images capped at 5 — oldest pin removed (\(result.count) remaining)."
            } else {
                lastMessage = nil
            }
            return
        }

        guard let pngData = Self.pngData(from: outputImage) else {
            fail("Capture Area could not create the screenshot image.", onFailure: onFailure)
            return
        }

        clipboardStore.setPasteboardImageData(pngData)
        if clipboardStore.addImageData(pngData, sourceApplicationName: "Screenshot") {
            lastMessage = nil
        } else {
            lastMessage = clipboardStore.lastError ?? "Screenshot was not saved to history."
        }
    }

    private static func captureSnapshots(for screens: [NSScreen]) async throws -> [CGDirectDisplayID: CaptureScreenSnapshot] {
        var snapshotsByDisplayID: [CGDirectDisplayID: CaptureScreenSnapshot] = [:]

        for screen in screens {
            guard let displayID = screen.displayID else {
                continue
            }

            let captureRect = displaySpaceRect(
                for: CGRect(origin: .zero, size: screen.frame.size),
                screen: screen,
                displayID: displayID
            )
            let fullResImage = try await captureImage(in: captureRect)
            snapshotsByDisplayID[displayID] = CaptureScreenSnapshot(
                displayID: displayID,
                image: fullResImage,
                fullResImage: fullResImage,
                pointSize: screen.frame.size
            )
        }

        return snapshotsByDisplayID
    }

    private static func displaySpaceRect(for localRect: CGRect, screen: NSScreen, displayID: CGDirectDisplayID) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + localRect.minX,
            y: displayBounds.minY + (screen.frame.height - localRect.maxY),
            width: localRect.width,
            height: localRect.height
        )
    }

    static func pixelCropRect(
        for selectionRect: CGRect,
        snapshotPointSize: CGSize,
        snapshotPixelSize: CGSize
    ) -> CGRect {
        let scaleX = snapshotPixelSize.width / max(snapshotPointSize.width, 1)
        let scaleY = snapshotPixelSize.height / max(snapshotPointSize.height, 1)
        return CGRect(
            x: selectionRect.minX * scaleX,
            y: (snapshotPointSize.height - selectionRect.maxY) * scaleY,
            width: selectionRect.width * scaleX,
            height: selectionRect.height * scaleY
        ).integral
    }

    /// The selected region of the snapshot. `cropping(to:)` shares the full-screen
    /// snapshot's storage; renderedCapture copies it out so the snapshot can be freed.
    private static func croppedRegion(from source: CGImage, snapshotPointSize: CGSize, selectionRect: CGRect) -> CGImage? {
        let cropRect = pixelCropRect(
            for: selectionRect,
            snapshotPointSize: snapshotPointSize,
            snapshotPixelSize: CGSize(width: source.width, height: source.height)
        )
        guard cropRect.width >= 1, cropRect.height >= 1 else { return nil }
        return source.cropping(to: cropRect)
    }

    private static func captureImage(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CaptureError.emptyImage)
                }
            }
        }
    }

    private enum CaptureError: LocalizedError {
        case emptyImage

        var errorDescription: String? {
            "ScreenCaptureKit returned an empty image."
        }
    }

    private func fail(_ message: String, onFailure: @escaping (String) -> Void) {
        lastMessage = message
        onFailure(message)
    }

    /// Renders a captured region into an independent, opaque image, drawing any
    /// annotations on top. This is the only copy of the pixels the capture makes.
    ///
    /// Everything is drawn in the region's own pixel coordinates. When `maxPixelCount`
    /// is set and the region exceeds it, the context is scaled down so image and
    /// annotations shrink together.
    static func renderedCapture(
        from region: CGImage,
        annotations: [CaptureAnnotation],
        selectionRect: CGRect,
        maxPixelCount: Int? = nil
    ) -> CGImage? {
        let sourceWidth = region.width
        let sourceHeight = region.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let outputSize = fittedPixelSize(width: sourceWidth, height: sourceHeight, maxPixelCount: maxPixelCount)
        guard let context = makeOpaqueContext(
            width: outputSize.width,
            height: outputSize.height,
            preferring: region.colorSpace
        ) else {
            return nil
        }

        let sourceRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        if outputSize.width != sourceWidth || outputSize.height != sourceHeight {
            context.interpolationQuality = .high
            context.scaleBy(
                x: CGFloat(outputSize.width) / CGFloat(sourceWidth),
                y: CGFloat(outputSize.height) / CGFloat(sourceHeight)
            )
        }
        context.draw(region, in: sourceRect)

        if !annotations.isEmpty {
            let scaleX = CGFloat(sourceWidth) / max(selectionRect.width, 1)
            let scaleY = CGFloat(sourceHeight) / max(selectionRect.height, 1)

            // The annotation drawing is written against AppKit, so hand it this context.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.systemRed.setStroke()
            for annotation in annotations {
                draw(
                    annotation,
                    selectionRect: selectionRect,
                    scaleX: scaleX,
                    scaleY: scaleY
                )
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        return context.makeImage()
    }

    /// The largest size with the same aspect ratio that fits within `maxPixelCount`.
    static func fittedPixelSize(width: Int, height: Int, maxPixelCount: Int?) -> (width: Int, height: Int) {
        guard let maxPixelCount, maxPixelCount > 0, width * height > maxPixelCount else {
            return (width, height)
        }

        let scale = (Double(maxPixelCount) / Double(width * height)).squareRoot()
        return (
            max(1, Int((Double(width) * scale).rounded(.down))),
            max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }

    /// An 8-bit, opaque context. Screenshots are opaque, so an alpha plane would only
    /// make the PNG bigger. The capture's own colour space is kept when possible, so a
    /// wide-gamut display stays Display P3 instead of being clipped to sRGB; an 8-bit
    /// context cannot hold an extended-range space, and those fall back to sRGB rather
    /// than failing and losing the annotations.
    private static func makeOpaqueContext(width: Int, height: Int, preferring preferred: CGColorSpace?) -> CGContext? {
        var candidates: [CGColorSpace] = []
        if let preferred, preferred.model == .rgb {
            candidates.append(preferred)
        }
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            candidates.append(sRGB)
        }

        for space in candidates {
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) {
                return context
            }
        }
        return nil
    }

    private static func draw(
        _ annotation: CaptureAnnotation,
        selectionRect: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        let start = imagePoint(annotation.start, selectionRect: selectionRect, scaleX: scaleX, scaleY: scaleY)
        let end = imagePoint(annotation.end, selectionRect: selectionRect, scaleX: scaleX, scaleY: scaleY)

        switch annotation.tool {
        case .rectangle:
            let path = NSBezierPath(rect: CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ))
            path.lineWidth = 3 * max(scaleX, scaleY)
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = 3 * max(scaleX, scaleY)
            path.stroke()
        case .arrow:
            drawArrow(from: start, to: end, scale: max(scaleX, scaleY))
        }
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        let lineWidth = 3 * scale
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = 13 * scale
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.move(to: end)
        head.line(to: right)
        head.lineWidth = lineWidth
        head.stroke()
    }

    private static func imagePoint(
        _ point: CGPoint,
        selectionRect: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: (point.x - selectionRect.minX) * scaleX,
            y: (point.y - selectionRect.minY) * scaleY
        )
    }

    private static func pngData(from image: CGImage) -> Data? {
        autoreleasepool {
            let bitmap = NSBitmapImageRep(cgImage: image)
            return bitmap.representation(using: .png, properties: [:])
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
