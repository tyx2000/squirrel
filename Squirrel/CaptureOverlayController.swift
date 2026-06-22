// Purpose: Presents temporary full-screen overlays for drag-select screenshot capture and simple annotations.

import AppKit
import Foundation

enum CaptureAnnotationTool: Equatable {
    case rectangle
    case line
    case arrow
}

struct CaptureAnnotation {
    var tool: CaptureAnnotationTool
    var start: CGPoint
    var end: CGPoint
}

struct CaptureScreenSnapshot {
    var displayID: CGDirectDisplayID
    var image: CGImage
    /// Full-resolution image retained only until the crop is complete, then nil'd to free memory.
    var fullResImage: CGImage?
    var pointSize: CGSize
}

enum CaptureOutputAction {
    case pin
    case copy
}

enum CaptureResizeHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

struct CaptureResizeHandleMetrics {
    var cornerSize: CGSize
    var edgeThickness: CGFloat
    var edgeLength: CGFloat
    var hitOutset: CGFloat
}

enum CaptureResizeHandleGeometry {
    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        metrics: CaptureResizeHandleMetrics
    ) -> CaptureResizeHandle? {
        handleRects(for: rect, metrics: metrics)
            .filter { _, handleRect in
                handleRect.insetBy(dx: -metrics.hitOutset, dy: -metrics.hitOutset).contains(point)
            }
            .min { lhs, rhs in
                distanceSquared(from: point, to: center(of: lhs.rect))
                    < distanceSquared(from: point, to: center(of: rhs.rect))
            }?
            .handle
    }

    static func handleRects(
        for rect: CGRect,
        metrics: CaptureResizeHandleMetrics
    ) -> [(handle: CaptureResizeHandle, rect: CGRect)] {
        [
            (.topLeft, cornerHandleRect(center: CGPoint(x: rect.minX, y: rect.maxY), metrics: metrics)),
            (.top, edgeHandleRect(center: CGPoint(x: rect.midX, y: rect.maxY), horizontal: true, metrics: metrics)),
            (.topRight, cornerHandleRect(center: CGPoint(x: rect.maxX, y: rect.maxY), metrics: metrics)),
            (.right, edgeHandleRect(center: CGPoint(x: rect.maxX, y: rect.midY), horizontal: false, metrics: metrics)),
            (.bottomRight, cornerHandleRect(center: CGPoint(x: rect.maxX, y: rect.minY), metrics: metrics)),
            (.bottom, edgeHandleRect(center: CGPoint(x: rect.midX, y: rect.minY), horizontal: true, metrics: metrics)),
            (.bottomLeft, cornerHandleRect(center: CGPoint(x: rect.minX, y: rect.minY), metrics: metrics)),
            (.left, edgeHandleRect(center: CGPoint(x: rect.minX, y: rect.midY), horizontal: false, metrics: metrics))
        ]
    }

    private static func cornerHandleRect(center: CGPoint, metrics: CaptureResizeHandleMetrics) -> CGRect {
        CGRect(
            x: center.x - metrics.cornerSize.width / 2,
            y: center.y - metrics.cornerSize.height / 2,
            width: metrics.cornerSize.width,
            height: metrics.cornerSize.height
        )
    }

    private static func edgeHandleRect(
        center: CGPoint,
        horizontal: Bool,
        metrics: CaptureResizeHandleMetrics
    ) -> CGRect {
        let size = horizontal
            ? CGSize(width: metrics.edgeLength, height: metrics.edgeThickness)
            : CGSize(width: metrics.edgeThickness, height: metrics.edgeLength)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distanceSquared(from point: CGPoint, to target: CGPoint) -> CGFloat {
        let dx = point.x - target.x
        let dy = point.y - target.y
        return dx * dx + dy * dy
    }
}

@MainActor
final class CaptureOverlayController {
    private var windows: [CaptureOverlayWindow] = []
    private let snapshotsByDisplayID: [CGDirectDisplayID: CaptureScreenSnapshot]
    private let onComplete: (CaptureOutputAction, NSScreen, CaptureScreenSnapshot, CGRect, [CaptureAnnotation]) -> Void
    private let onCancel: () -> Void
    private var isFinished = false

    init(
        snapshotsByDisplayID: [CGDirectDisplayID: CaptureScreenSnapshot],
        onComplete: @escaping (CaptureOutputAction, NSScreen, CaptureScreenSnapshot, CGRect, [CaptureAnnotation]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshotsByDisplayID = snapshotsByDisplayID
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    func begin() {
        let mouseLocation = NSEvent.mouseLocation
        NSApp.activate(ignoringOtherApps: true)
        windows = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID,
                  let snapshot = snapshotsByDisplayID[displayID] else {
                return nil
            }
            let view = CaptureOverlayView(
                screen: screen,
                snapshot: snapshot,
                onComplete: { [weak self] action, selectedScreen, selectedSnapshot, selectionRect, annotations in
                    self?.finish(
                        action: action,
                        screen: selectedScreen,
                        snapshot: selectedSnapshot,
                        selectionRect: selectionRect,
                        annotations: annotations
                    )
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            let window = CaptureOverlayWindow(screen: screen)
            window.contentView = view
            window.orderFrontRegardless()
            window.displayIfNeeded()
            return window
        }
        let keyWindow = windows.first { $0.frame.contains(mouseLocation) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
    }

    private func finish(
        action: CaptureOutputAction,
        screen: NSScreen,
        snapshot: CaptureScreenSnapshot,
        selectionRect: CGRect,
        annotations: [CaptureAnnotation]
    ) {
        guard !isFinished else { return }
        isFinished = true
        closeWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [onComplete] in
            onComplete(action, screen, snapshot, selectionRect, annotations)
        }
    }

    private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        closeWindows()
        onCancel()
    }

    private func closeWindows() {
        NSCursor.arrow.set()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureOverlayView: NSView {
    private enum ToolbarAction: Equatable {
        case tool(CaptureAnnotationTool)
        case pin
        case copy
        case cancel
    }

    private struct ToolbarButton {
        var action: ToolbarAction
        var symbolName: String
        var rect: CGRect
    }

    private let captureScreen: NSScreen
    private let snapshot: CaptureScreenSnapshot
    private let snapshotImage: NSImage
    private let onComplete: (CaptureOutputAction, NSScreen, CaptureScreenSnapshot, CGRect, [CaptureAnnotation]) -> Void
    private let onCancel: () -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var selectionRect: CGRect?
    private var activeTool: CaptureAnnotationTool?
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var annotations: [CaptureAnnotation] = []
    private var pressedToolbarAction: ToolbarAction?
    private var moveStart: CGPoint?
    private var moveOriginalRect: CGRect?
    private var moveOriginalAnnotations: [CaptureAnnotation] = []
    private var resizeHandle: CaptureResizeHandle?
    private var resizeOriginalRect: CGRect?
    private var resizeOriginalAnnotations: [CaptureAnnotation] = []
    private let minimumSelectionSize: CGFloat = 6
    private let annotationColor = NSColor.systemRed
    private let cornerHandleSize = CGSize(width: 4, height: 4)
    private let edgeHandleThickness: CGFloat = 4
    private let edgeHandleLength: CGFloat = 28
    private let resizeHitOutset: CGFloat = 8
    private let toolbarSize = CGSize(width: 232, height: 36)
    private let toolbarGap: CGFloat = 12
    private let toolbarButtonSize = CGSize(width: 28, height: 28)
    private let toolbarButtonSpacing: CGFloat = 8
    private let toolbarBackgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.96)
    private let toolbarSelectedBackgroundColor = NSColor.systemRed.withAlphaComponent(0.16)
    private static let diagonalResizeDownCursor = makeDiagonalResizeCursor(flipped: false)
    private static let diagonalResizeUpCursor = makeDiagonalResizeCursor(flipped: true)

    init(
        screen: NSScreen,
        snapshot: CaptureScreenSnapshot,
        onComplete: @escaping (CaptureOutputAction, NSScreen, CaptureScreenSnapshot, CGRect, [CaptureAnnotation]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.captureScreen = screen
        self.snapshot = snapshot
        self.snapshotImage = NSImage(cgImage: snapshot.image, size: snapshot.pointSize)
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let toolbarButton = toolbarButtons.first(where: { $0.rect.contains(point) }) {
            pressedToolbarAction = toolbarButton.action
            needsDisplay = true
            return
        }

        if let selectionRect {
            if let handle = resizeHandle(at: point, in: selectionRect) {
                resizeHandle = handle
                resizeOriginalRect = selectionRect
                resizeOriginalAnnotations = annotations
                cursor(for: handle).set()
            } else if selectionRect.contains(point) {
                if let activeTool {
                    annotationStart = point
                    annotationCurrent = point
                    self.activeTool = activeTool
                    NSCursor.crosshair.set()
                } else {
                    moveStart = point
                    moveOriginalRect = selectionRect
                    moveOriginalAnnotations = annotations
                    NSCursor.closedHand.set()
                }
            } else {
                clearSelectionState()
                dragStart = point
                dragCurrent = point
            }
        } else {
            dragStart = point
            dragCurrent = point
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedToolbarAction == nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        if resizeHandle != nil {
            resizeSelection(to: point)
            if let resizeHandle {
                cursor(for: resizeHandle).set()
            }
        } else if moveStart != nil {
            moveSelection(to: point)
            NSCursor.closedHand.set()
        } else if selectionRect != nil, annotationStart != nil {
            annotationCurrent = point
            NSCursor.crosshair.set()
        } else {
            dragCurrent = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let pressedToolbarAction {
            self.pressedToolbarAction = nil
            if toolbarButtons.contains(where: { $0.action == pressedToolbarAction && $0.rect.contains(point) }) {
                handle(pressedToolbarAction)
            }
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        if selectionRect != nil, let activeTool, annotationStart != nil {
            annotationCurrent = point
            if let annotation = currentAnnotation(tool: activeTool),
               distance(from: annotation.start, to: annotation.end) >= minimumSelectionSize {
                annotations.append(annotation)
            }
            self.annotationStart = nil
            annotationCurrent = nil
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        if resizeHandle != nil {
            resizeSelection(to: point)
            resizeHandle = nil
            resizeOriginalRect = nil
            resizeOriginalAnnotations.removeAll()
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        if moveStart != nil {
            moveSelection(to: point)
            moveStart = nil
            moveOriginalRect = nil
            moveOriginalAnnotations.removeAll()
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        dragCurrent = point
        guard let draftSelectionRect, draftSelectionRect.width >= minimumSelectionSize, draftSelectionRect.height >= minimumSelectionSize else {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }

        selectionRect = draftSelectionRect
        dragStart = nil
        dragCurrent = nil
        activeTool = nil
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closeCapture()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFrozenSnapshot()

        let selectedRect = selectionRect ?? draftSelectionRect
        if let selectedRect {
            drawDimmedBackground(around: selectedRect, exposingToolbar: selectionRect != nil)
            drawSelectionBorder(selectedRect)
            drawAnnotations()
            if let activeTool, let annotation = currentAnnotation(tool: activeTool) {
                draw(annotation)
            }
            drawSizeLabel(for: selectedRect)
            if selectionRect != nil {
                drawResizeHandles(for: selectedRect)
                drawToolbar()
            }
        } else {
            NSColor.black.withAlphaComponent(0.26).setFill()
            bounds.fill()
        }
    }

    private func drawFrozenSnapshot() {
        snapshotImage.draw(
            in: bounds,
            from: CGRect(origin: .zero, size: snapshot.pointSize),
            operation: .sourceOver,
            fraction: 1
        )
    }

    private var draftSelectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
    }

    private var toolbarRect: CGRect {
        guard let selectionRect else { return .zero }
        let preferredX = selectionRect.maxX - toolbarSize.width
        let preferredY = selectionRect.minY - toolbarGap - toolbarSize.height
        return CGRect(
            x: min(max(preferredX, 8), max(bounds.maxX - toolbarSize.width - 8, 8)),
            y: max(preferredY, 8),
            width: toolbarSize.width,
            height: toolbarSize.height
        )
    }

    private var toolbarButtons: [ToolbarButton] {
        guard selectionRect != nil else { return [] }
        let actions: [(ToolbarAction, String)] = [
            (.tool(.rectangle), "rectangle"),
            (.tool(.line), "line.diagonal"),
            (.tool(.arrow), "arrow.up.right"),
            (.pin, "pin"),
            (.copy, "doc.on.doc"),
            (.cancel, "xmark")
        ]
        let totalButtonWidth = CGFloat(actions.count) * toolbarButtonSize.width
            + CGFloat(actions.count - 1) * toolbarButtonSpacing
        var x = toolbarRect.midX - totalButtonWidth / 2
        return actions.map { action, symbolName in
            defer { x += toolbarButtonSize.width + toolbarButtonSpacing }
            return ToolbarButton(
                action: action,
                symbolName: symbolName,
                rect: CGRect(
                    x: x,
                    y: toolbarRect.midY - toolbarButtonSize.height / 2,
                    width: toolbarButtonSize.width,
                    height: toolbarButtonSize.height
                )
            )
        }
    }

    private func updateCursor(at point: CGPoint) {
        if let resizeHandle {
            cursor(for: resizeHandle).set()
            return
        }

        if moveStart != nil {
            NSCursor.closedHand.set()
            return
        }

        if annotationStart != nil {
            NSCursor.crosshair.set()
            return
        }

        guard let selectionRect else {
            NSCursor.crosshair.set()
            return
        }

        if let handle = resizeHandle(at: point, in: selectionRect) {
            cursor(for: handle).set()
        } else if toolbarButtons.contains(where: { $0.rect.contains(point) }) {
            NSCursor.arrow.set()
        } else if selectionRect.contains(point) {
            if activeTool != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .tool(let tool):
            activeTool = activeTool == tool ? nil : tool
        case .pin:
            guard let selectionRect else { return }
            onComplete(.pin, captureScreen, snapshot, selectionRect, annotations)
        case .copy:
            guard let selectionRect else { return }
            onComplete(.copy, captureScreen, snapshot, selectionRect, annotations)
        case .cancel:
            closeCapture()
        }
        needsDisplay = true
    }

    private func closeCapture() {
        NSCursor.arrow.set()
        dragStart = nil
        dragCurrent = nil
        clearSelectionState()
        needsDisplay = true
        onCancel()
    }

    private func clearSelectionState() {
        selectionRect = nil
        activeTool = nil
        annotationStart = nil
        annotationCurrent = nil
        annotations.removeAll()
        moveStart = nil
        moveOriginalRect = nil
        moveOriginalAnnotations.removeAll()
        resizeHandle = nil
        resizeOriginalRect = nil
        resizeOriginalAnnotations.removeAll()
    }

    private func currentAnnotation(tool: CaptureAnnotationTool) -> CaptureAnnotation? {
        guard let annotationStart, let annotationCurrent, let selectionRect else { return nil }
        return CaptureAnnotation(
            tool: tool,
            start: clamp(annotationStart, to: selectionRect),
            end: clamp(annotationCurrent, to: selectionRect)
        )
    }

    private func moveSelection(to point: CGPoint) {
        guard let moveStart, let moveOriginalRect else { return }
        let delta = CGPoint(x: point.x - moveStart.x, y: point.y - moveStart.y)
        let unclampedRect = moveOriginalRect.offsetBy(dx: delta.x, dy: delta.y)
        let clampedRect = clamp(unclampedRect, to: bounds)
        let appliedDelta = CGPoint(
            x: clampedRect.minX - moveOriginalRect.minX,
            y: clampedRect.minY - moveOriginalRect.minY
        )

        selectionRect = clampedRect
        annotations = moveOriginalAnnotations.map { annotation in
            CaptureAnnotation(
                tool: annotation.tool,
                start: annotation.start.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y),
                end: annotation.end.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y)
            )
        }
    }

    private func resizeSelection(to point: CGPoint) {
        guard let resizeHandle, let resizeOriginalRect else { return }
        let resizedRect = resizedSelectionRect(from: resizeOriginalRect, handle: resizeHandle, to: point)
        selectionRect = resizedRect
        annotations = resizeOriginalAnnotations.map { annotation in
            CaptureAnnotation(
                tool: annotation.tool,
                start: clamp(annotation.start, to: resizedRect),
                end: clamp(annotation.end, to: resizedRect)
            )
        }
    }

    private func resizedSelectionRect(from originalRect: CGRect, handle: CaptureResizeHandle, to point: CGPoint) -> CGRect {
        var minX = originalRect.minX
        var maxX = originalRect.maxX
        var minY = originalRect.minY
        var maxY = originalRect.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .left:
            minX = point.x
        }

        minX = max(bounds.minX, minX)
        maxX = min(bounds.maxX, maxX)
        minY = max(bounds.minY, minY)
        maxY = min(bounds.maxY, maxY)

        if maxX - minX < minimumSelectionSize {
            switch handle {
            case .left, .topLeft, .bottomLeft:
                minX = max(bounds.minX, maxX - minimumSelectionSize)
            default:
                maxX = min(bounds.maxX, minX + minimumSelectionSize)
            }
        }

        if maxY - minY < minimumSelectionSize {
            switch handle {
            case .bottom, .bottomLeft, .bottomRight:
                minY = max(bounds.minY, maxY - minimumSelectionSize)
            default:
                maxY = min(bounds.maxY, minY + minimumSelectionSize)
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawDimmedBackground(around rect: CGRect, exposingToolbar: Bool) {
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(rect: rect))
        if exposingToolbar {
            dimPath.append(NSBezierPath(roundedRect: toolbarRect.insetBy(dx: -2, dy: -2), xRadius: 9, yRadius: 9))
        }
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.26).setFill()
        dimPath.fill()
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawResizeHandles(for rect: CGRect) {
        for handleRect in resizeHandleRects(for: rect).map(\.rect) {
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1).fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1)
            border.lineWidth = 1
            border.stroke()
        }
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> CaptureResizeHandle? {
        CaptureResizeHandleGeometry.handle(at: point, in: rect, metrics: resizeHandleMetrics)
    }

    private func resizeHandleRects(for rect: CGRect) -> [(handle: CaptureResizeHandle, rect: CGRect)] {
        CaptureResizeHandleGeometry.handleRects(for: rect, metrics: resizeHandleMetrics)
    }

    private var resizeHandleMetrics: CaptureResizeHandleMetrics {
        CaptureResizeHandleMetrics(
            cornerSize: cornerHandleSize,
            edgeThickness: edgeHandleThickness,
            edgeLength: edgeHandleLength,
            hitOutset: resizeHitOutset
        )
    }

    private func cursor(for handle: CaptureResizeHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return Self.diagonalResizeDownCursor
        case .topRight, .bottomLeft:
            return Self.diagonalResizeUpCursor
        }
    }

    private static func makeDiagonalResizeCursor(flipped: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 2
        if flipped {
            path.move(to: NSPoint(x: 4, y: 4))
            path.line(to: NSPoint(x: 14, y: 14))
        } else {
            path.move(to: NSPoint(x: 4, y: 14))
            path.line(to: NSPoint(x: 14, y: 4))
        }
        path.stroke()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }

    private func drawAnnotations() {
        for annotation in annotations {
            draw(annotation)
        }
    }

    private func draw(_ annotation: CaptureAnnotation) {
        annotationColor.setStroke()
        switch annotation.tool {
        case .rectangle:
            let path = NSBezierPath(rect: rect(from: annotation.start, to: annotation.end))
            path.lineWidth = 3
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: annotation.start)
            path.line(to: annotation.end)
            path.lineWidth = 3
            path.stroke()
        case .arrow:
            drawArrow(from: annotation.start, to: annotation.end)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 3
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 13
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
        head.lineWidth = 3
        head.stroke()
    }

    private func drawToolbar() {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()

        toolbarBackgroundColor.setFill()
        NSBezierPath(roundedRect: toolbarRect, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()

        for button in toolbarButtons {
            let isSelected = {
                if case .tool(let tool) = button.action {
                    return tool == activeTool
                }
                return false
            }()
            (isSelected ? toolbarSelectedBackgroundColor : toolbarBackgroundColor).setFill()
            NSBezierPath(roundedRect: button.rect, xRadius: 6, yRadius: 6).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let image = NSImage(systemSymbolName: button.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            (isSelected ? NSColor.systemRed : NSColor.labelColor).set()
            image?.draw(
                in: button.rect.insetBy(dx: 6, dy: 6),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: rect.minX,
            y: max(rect.minY - textSize.height - 10, 8),
            width: textSize.width + 14,
            height: textSize.height + 8
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        text.draw(
            in: labelRect.insetBy(dx: 7, dy: 4),
            withAttributes: attributes
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - rect.width),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
