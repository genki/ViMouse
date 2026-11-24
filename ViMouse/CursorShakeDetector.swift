import Foundation

/// Recognizes three short back-and-forth trips along the same axis.
/// Coordinates are screen points, and timestamps are monotonic seconds.
struct CursorShakeDetector {
    private static let minimumStroke: CGFloat = 14
    private static let maximumStroke: CGFloat = 88
    private static let lateralTolerance: CGFloat = 20
    private static let maximumPause: TimeInterval = 0.32
    private static let maximumDuration: TimeInterval = 1.4
    private static let cooldown: TimeInterval = 0.9
    private static let requiredTurns = 5

    private var origin: CGPoint?
    private var startedAt: TimeInterval = 0
    private var lastEventAt: TimeInterval?
    private var axis: CGPoint?
    private var direction: CGFloat = 1
    private var extreme: CGFloat = 0
    private var strokeStart: CGFloat = 0
    private var turns = 0
    private var returnTarget: CGFloat = 0
    private var nextAllowedAt: TimeInterval = 0

    mutating func reset() {
        origin = nil
        lastEventAt = nil
        axis = nil
        direction = 1
        extreme = 0
        strokeStart = 0
        turns = 0
        returnTarget = 0
    }

    mutating func record(_ point: CGPoint, at time: TimeInterval) -> Bool {
        guard time >= nextAllowedAt else { return false }
        guard let origin = origin, let lastEventAt = lastEventAt,
              time >= lastEventAt, time - lastEventAt <= Self.maximumPause,
              time - startedAt <= Self.maximumDuration else {
            begin(at: point, time: time)
            return false
        }
        self.lastEventAt = time

        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let distance = hypot(dx, dy)
        guard distance <= Self.maximumStroke else {
            begin(at: point, time: time)
            return false
        }
        guard let axis = axis else {
            if distance >= Self.minimumStroke {
                self.axis = CGPoint(x: dx / distance, y: dy / distance)
                extreme = distance
            }
            return false
        }

        let position = dx * axis.x + dy * axis.y
        let lateralOffset = dx * axis.y - dy * axis.x
        // Smaller strokes need a narrower corridor so a small loop does not
        // look like alternating movement along the original axis.
        let reach = max(abs(position), abs(extreme), abs(strokeStart))
        let corridor = min(Self.lateralTolerance, max(9, reach * 0.45))
        guard abs(lateralOffset) <= corridor,
              abs(position - strokeStart) <= Self.maximumStroke else {
            begin(at: point, time: time)
            return false
        }

        if (position - extreme) * direction > 0 {
            extreme = position
        } else if (extreme - position) * direction >= Self.minimumStroke {
            guard turns < Self.requiredTurns else {
                begin(at: point, time: time)
                return false
            }
            // Measure the reversal from the furthest point in the stroke.
            // Tiny changes in direction between mouse events do not count.
            returnTarget = strokeStart
            strokeStart = extreme
            direction = -direction
            extreme = position
            turns += 1
        }

        // Five turns followed by a return to the starting side of the third
        // trip. Do not fire as soon as the final change of direction is seen.
        guard turns == Self.requiredTurns else { return false }
        let returnDistance = abs(returnTarget - strokeStart)
        let requiredReturn = max(Self.minimumStroke, returnDistance - 10)
        guard (position - strokeStart) * direction >= requiredReturn else { return false }
        reset()
        nextAllowedAt = time + Self.cooldown
        return true
    }

    private mutating func begin(at point: CGPoint, time: TimeInterval) {
        reset()
        origin = point
        startedAt = time
        lastEventAt = time
    }
}
