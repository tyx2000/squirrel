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

        MainWindowPresenter.shared.hideClipboardWindow()
        isPreparingCapture = true

        Task { @MainActor in
            defer { isPreparingCapture = false }

            do {
                guard let captureScreen = Self.screenContainingMouse(from: NSScreen.screens) else {
                    fail("Capture Area could not identify the selected screen.", onFailure: onFailure)
                    return
                }
                let snapshotsByDisplayID = try await Self.captureSnapshots(for: [captureScreen])
                guard !snapshotsByDisplayID.isEmpty else {
                    fail("Capture Area could not create the screenshot image.", onFailure: onFailure)
                    return
                }

                beginOverlay(with: snapshotsByDisplayID, onFailure: onFailure)
            } catch {
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

        isShowingPermissionGuide = true
        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Required"
        alert.informativeText = "Enable Squirrel in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the app."
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
        // Use the full-resolution image for pixel-perfect cropping, then release it.
        let cropSource = snapshot.fullResImage ?? snapshot.image

        guard let image = Self.croppedImage(from: cropSource, snapshotPointSize: snapshot.pointSize, selectionRect: localSelectionRect) else {
            fail("Capture Area could not create the screenshot image.", onFailure: onFailure)
            return
        }

        // croppedImage already returns a detached copy, so `image` is independent.
        // compositedImage reads (doesn't mutate) its input, so no second detach needed.
        let outputImage: CGImage
        if annotations.isEmpty {
            outputImage = image
        } else {
            outputImage = Self.compositedImage(
                baseImage: image,
                annotations: annotations,
                selectionRect: localSelectionRect
            )
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

    private static func croppedImage(from source: CGImage, snapshotPointSize: CGSize, selectionRect: CGRect) -> CGImage? {
        let cropRect = pixelCropRect(
            for: selectionRect,
            snapshotPointSize: snapshotPointSize,
            snapshotPixelSize: CGSize(width: source.width, height: source.height)
        )
        guard cropRect.width >= 1, cropRect.height >= 1 else { return nil }
        guard let croppedImage = source.cropping(to: cropRect) else { return nil }
        return detachedCopy(of: croppedImage)
    }

    private static func detachedCopy(of image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

    private static func compositedImage(
        baseImage: CGImage,
        annotations: [CaptureAnnotation],
        selectionRect: CGRect
    ) -> CGImage {
        guard !annotations.isEmpty else { return baseImage }

        let imageSize = CGSize(width: baseImage.width, height: baseImage.height)
        let scaleX = imageSize.width / max(selectionRect.width, 1)
        let scaleY = imageSize.height / max(selectionRect.height, 1)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSImage(cgImage: baseImage, size: imageSize).draw(in: CGRect(origin: .zero, size: imageSize))

        NSColor.systemRed.setStroke()
        for annotation in annotations {
            draw(
                annotation,
                selectionRect: selectionRect,
                scaleX: scaleX,
                scaleY: scaleY
            )
        }

        image.unlockFocus()
        var proposedRect = CGRect(origin: .zero, size: imageSize)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) ?? baseImage
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
