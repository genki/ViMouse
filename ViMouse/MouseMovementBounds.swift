import CoreGraphics

struct MouseMovementBounds {
    static func nextPosition(current: CGPoint, delta: CGVector, displays: [CGRect]) -> CGPoint {
        let proposed = CGPoint(x: current.x + delta.dx, y: current.y + delta.dy)
        if displays.contains(where: { $0.contains(proposed) }) {
            return proposed
        }

        guard let currentDisplay = displays.first(where: { $0.contains(current) }) else {
            return proposed
        }

        return clamp(proposed, to: currentDisplay)
    }

    static func activeDisplays() -> [CGRect] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
    }

    private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX - 1),
            y: min(max(point.y, rect.minY), rect.maxY - 1)
        )
    }
}
