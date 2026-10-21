// Purpose: Defines the trackpad gestures a command can be bound to, and recognises them from raw touches.

import CoreGraphics
import Foundation

nonisolated enum TrackpadGesture: String, CaseIterable, Codable, Identifiable {
    case threeFingerTap
    case fourFingerTap
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case fourFingerSwipeLeft
    case fourFingerSwipeRight
    case fourFingerSwipeUp
    case fourFingerSwipeDown
    case oneFingerSwipeFromLeftEdge
    case oneFingerSwipeFromRightEdge
    case oneFingerSwipeFromTopEdge
    case oneFingerSwipeFromBottomEdge
    case twoFingerSwipeFromLeftEdge
    case twoFingerSwipeFromRightEdge
    case twoFingerSwipeFromTopEdge
    case twoFingerSwipeFromBottomEdge

    enum Direction {
        case left
        case right
        case up
        case down
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeFingerTap: "Three-Finger Tap"
        case .fourFingerTap: "Four-Finger Tap"
        case .threeFingerSwipeLeft: "Three-Finger Swipe Left"
        case .threeFingerSwipeRight: "Three-Finger Swipe Right"
        case .threeFingerSwipeUp: "Three-Finger Swipe Up"
        case .threeFingerSwipeDown: "Three-Finger Swipe Down"
        case .fourFingerSwipeLeft: "Four-Finger Swipe Left"
        case .fourFingerSwipeRight: "Four-Finger Swipe Right"
        case .fourFingerSwipeUp: "Four-Finger Swipe Up"
        case .fourFingerSwipeDown: "Four-Finger Swipe Down"
        case .oneFingerSwipeFromLeftEdge: "One-Finger Swipe from Left Edge"
        case .oneFingerSwipeFromRightEdge: "One-Finger Swipe from Right Edge"
        case .oneFingerSwipeFromTopEdge: "One-Finger Swipe from Top Edge"
        case .oneFingerSwipeFromBottomEdge: "One-Finger Swipe from Bottom Edge"
        case .twoFingerSwipeFromLeftEdge: "Two-Finger Swipe from Left Edge"
        case .twoFingerSwipeFromRightEdge: "Two-Finger Swipe from Right Edge"
        case .twoFingerSwipeFromTopEdge: "Two-Finger Swipe from Top Edge"
        case .twoFingerSwipeFromBottomEdge: "Two-Finger Swipe from Bottom Edge"
        }
    }

    /// Menu sections: taps, swipes by finger count, then swipes in from an edge.
    static let groups: [[TrackpadGesture]] = [
        [.threeFingerTap, .fourFingerTap],
        [.threeFingerSwipeLeft, .threeFingerSwipeRight, .threeFingerSwipeUp, .threeFingerSwipeDown],
        [.fourFingerSwipeLeft, .fourFingerSwipeRight, .fourFingerSwipeUp, .fourFingerSwipeDown],
        [.oneFingerSwipeFromLeftEdge, .oneFingerSwipeFromRightEdge, .oneFingerSwipeFromTopEdge, .oneFingerSwipeFromBottomEdge],
        [.twoFingerSwipeFromLeftEdge, .twoFingerSwipeFromRightEdge, .twoFingerSwipeFromTopEdge, .twoFingerSwipeFromBottomEdge]
    ]

    static func tap(fingers: Int) -> TrackpadGesture? {
        switch fingers {
        case 3: .threeFingerTap
        case 4: .fourFingerTap
        default: nil
        }
    }

    static func swipe(fingers: Int, direction: Direction) -> TrackpadGesture? {
        switch (fingers, direction) {
        case (3, .left): .threeFingerSwipeLeft
        case (3, .right): .threeFingerSwipeRight
        case (3, .up): .threeFingerSwipeUp
        case (3, .down): .threeFingerSwipeDown
        case (4, .left): .fourFingerSwipeLeft
        case (4, .right): .fourFingerSwipeRight
        case (4, .up): .fourFingerSwipeUp
        case (4, .down): .fourFingerSwipeDown
        default: nil
        }
    }

    /// A swipe in from an edge, named by the edge it starts from: moving right starts
    /// from the left edge.
    static func edgeSwipe(fingers: Int, direction: Direction) -> TrackpadGesture? {
        switch (fingers, direction) {
        case (1, .right): .oneFingerSwipeFromLeftEdge
        case (1, .left): .oneFingerSwipeFromRightEdge
        case (1, .down): .oneFingerSwipeFromTopEdge
        case (1, .up): .oneFingerSwipeFromBottomEdge
        case (2, .right): .twoFingerSwipeFromLeftEdge
        case (2, .left): .twoFingerSwipeFromRightEdge
        case (2, .down): .twoFingerSwipeFromTopEdge
        case (2, .up): .twoFingerSwipeFromBottomEdge
        default: nil
        }
    }
}

/// One finger on the trackpad. Positions are normalised to the surface, 0 to 1 on each
/// axis, with the origin at the bottom left: y grows away from the user.
nonisolated struct TrackpadTouch {
    var identifier: Int
    var position: CGPoint
}

/// Turns a stream of touch frames into at most one gesture per touch session, which runs
/// from the first finger landing until the last one lifts.
///
/// A swipe fires as soon as the fingers have travelled far enough, so it feels immediate.
/// A tap can only be told apart from the start of a swipe or a rest once every finger has
/// lifted, so it fires then.
nonisolated struct TrackpadGestureRecognizer {
    /// Centroid travel, as a fraction of the surface, before a swipe fires.
    static let swipeDistance: CGFloat = 0.12
    /// How much longer the swipe's main axis must be than the other one, so a diagonal
    /// drag fires nothing rather than a guess.
    static let swipeDominance: CGFloat = 1.5
    /// A tap is quick: the first finger down to the last one up.
    static let tapMaxDuration: TimeInterval = 0.3
    /// How far any one finger may drift during a tap.
    static let tapMaxTravel: CGFloat = 0.04
    /// How close to an edge, as a fraction of the surface, a finger must land for its
    /// swipe inward to start from that edge.
    static let edgeZone: CGFloat = 0.05

    private var sessionStart: TimeInterval?
    private var fingerCount = 0
    private var peakFingerCount = 0
    private var anchor: CGPoint = .zero
    private var landingPositions: [Int: CGPoint] = [:]
    private var largestTravel: CGFloat = 0
    private var didRecognize = false
    /// The current set of fingers has already moved clearly one way, whether or not that
    /// made a gesture. Moving the pointer down and then right from the left edge is not a
    /// swipe from that edge.
    private var isDirectionSettled = false

    mutating func process(_ touches: [TrackpadTouch], at timestamp: TimeInterval) -> TrackpadGesture? {
        guard !touches.isEmpty else {
            return endSession(at: timestamp)
        }

        if sessionStart == nil {
            sessionStart = timestamp
        }

        for touch in touches {
            let landing = landingPositions[touch.identifier] ?? touch.position
            landingPositions[touch.identifier] = landing
            largestTravel = max(largestTravel, Self.distance(from: landing, to: touch.position))
        }

        // Fingers land and lift a few milliseconds apart, and each change moves the
        // centroid. Measure a swipe only from when the current set of fingers came down.
        let centroid = Self.centroid(of: touches)
        if touches.count != fingerCount {
            fingerCount = touches.count
            peakFingerCount = max(peakFingerCount, fingerCount)
            anchor = centroid
            isDirectionSettled = false
            return nil
        }

        guard !didRecognize,
              !isDirectionSettled,
              let direction = Self.swipeDirection(from: anchor, to: centroid) else {
            return nil
        }

        isDirectionSettled = true
        guard let gesture = swipeGesture(moving: direction, with: touches) else { return nil }
        didRecognize = true
        return gesture
    }

    private func swipeGesture(moving direction: TrackpadGesture.Direction, with touches: [TrackpadTouch]) -> TrackpadGesture? {
        if fingerCount >= 3 {
            return TrackpadGesture.swipe(fingers: fingerCount, direction: direction)
        }

        // One and two fingers also point and scroll, which can start anywhere. Only
        // fingers that landed right at the edge they move away from count, and only
        // when no other fingers were down in this session.
        guard peakFingerCount == fingerCount,
              touches.allSatisfy({ touch in
                  landingPositions[touch.identifier].map { Self.isAtEdge($0, movingAwayToward: direction) } ?? false
              }) else {
            return nil
        }
        return TrackpadGesture.edgeSwipe(fingers: fingerCount, direction: direction)
    }

    private static func isAtEdge(_ point: CGPoint, movingAwayToward direction: TrackpadGesture.Direction) -> Bool {
        switch direction {
        case .right: point.x <= edgeZone
        case .left: point.x >= 1 - edgeZone
        case .up: point.y <= edgeZone
        case .down: point.y >= 1 - edgeZone
        }
    }

    private mutating func endSession(at timestamp: TimeInterval) -> TrackpadGesture? {
        defer { self = TrackpadGestureRecognizer() }

        guard let sessionStart,
              !didRecognize,
              timestamp - sessionStart <= Self.tapMaxDuration,
              largestTravel <= Self.tapMaxTravel else {
            return nil
        }
        return TrackpadGesture.tap(fingers: peakFingerCount)
    }

    private static func swipeDirection(from start: CGPoint, to end: CGPoint) -> TrackpadGesture.Direction? {
        let dx = end.x - start.x
        let dy = end.y - start.y

        if abs(dx) >= swipeDistance, abs(dx) >= abs(dy) * swipeDominance {
            return dx < 0 ? .left : .right
        }
        if abs(dy) >= swipeDistance, abs(dy) >= abs(dx) * swipeDominance {
            return dy < 0 ? .down : .up
        }
        return nil
    }

    private static func centroid(of touches: [TrackpadTouch]) -> CGPoint {
        let sum = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y) }
        let count = CGFloat(touches.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private static func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}
