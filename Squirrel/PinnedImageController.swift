// Purpose: Keeps screenshot pins alive as draggable always-on-top image windows.

import AppKit
import Foundation

@MainActor
final class PinnedImageController {
    private var windows: [PinnedImageWindow] = []

    func pin(image: CGImage, screen: NSScreen, selectionRect: CGRect) {
        let windowSize = displaySize(for: selectionRect.size)
        let frame = CGRect(
            x: screen.frame.minX + selectionRect.minX,
            y: screen.frame.minY + selectionRect.minY,
            width: windowSize.width,
            height: windowSize.height
        )
        let window = PinnedImageWindow(image: NSImage(cgImage: image, size: selectionRect.size), frame: frame)
        window.onClose = { [weak self, weak window] in
            guard let window else { return }
            self?.windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.orderFrontRegardless()
    }

    private func displaySize(for pointSize: CGSize) -> CGSize {
        let maxSize = CGSize(width: 720, height: 520)
        let scale = min(1, maxSize.width / max(pointSize.width, 1), maxSize.height / max(pointSize.height, 1))
        return CGSize(width: max(pointSize.width * scale, 80), height: max(pointSize.height * scale, 60))
    }
}

final class PinnedImageWindow: NSPanel {
    var onClose: (() -> Void)?

    init(image: NSImage, frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = PinnedImageView(image: image)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        super.close()
        onClose?()
    }
}

final class PinnedImageView: NSImageView {
    private var dragStartLocation: CGPoint?
    private var dragStartFrameOrigin: CGPoint?

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStartLocation = NSEvent.mouseLocation
        dragStartFrameOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let dragStartLocation,
              let dragStartFrameOrigin else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let newOrigin = CGPoint(
            x: dragStartFrameOrigin.x + currentLocation.x - dragStartLocation.x,
            y: dragStartFrameOrigin.y + currentLocation.y - dragStartLocation.y
        )
        window.setFrameOrigin(newOrigin)
    }
}
