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
    var pointSize: CGSize
}

enum CaptureOutputAction {
    case pin
    case copy
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
    private let minimumSelectionSize: CGFloat = 6
    private let annotationColor = NSColor.systemRed
    private let toolbarSize = CGSize(width: 232, height: 36)
    private let toolbarGap: CGFloat = 12
    private let toolbarButtonSize = CGSize(width: 28, height: 28)
    private let toolbarButtonSpacing: CGFloat = 8
    private let toolbarBackgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.96)
    private let toolbarSelectedBackgroundColor = NSColor.systemRed.withAlphaComponent(0.16)

    init(
        screen: NSScreen,
        snapshot: CaptureScreenSnapshot,
        onComplete: @escaping (CaptureOutputAction, NSScreen, CaptureScreenSnapshot, CGRect, [CaptureAnnotation]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.captureScreen = screen
        self.snapshot = snapshot
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
            if selectionRect.contains(point) {
                if let activeTool {
                    annotationStart = point
                    annotationCurrent = point
                    self.activeTool = activeTool
                } else {
                    moveStart = point
                    moveOriginalRect = selectionRect
                    moveOriginalAnnotations = annotations
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
        if moveStart != nil {
            moveSelection(to: point)
        } else if selectionRect != nil, annotationStart != nil {
            annotationCurrent = point
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
            needsDisplay = true
            return
        }

        if moveStart != nil {
            moveSelection(to: point)
            moveStart = nil
            moveOriginalRect = nil
            moveOriginalAnnotations.removeAll()
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
        needsDisplay = true
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
                drawToolbar()
            }
        } else {
            NSColor.black.withAlphaComponent(0.26).setFill()
            bounds.fill()
        }
    }

    private func drawFrozenSnapshot() {
        NSImage(cgImage: snapshot.image, size: snapshot.pointSize).draw(
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
