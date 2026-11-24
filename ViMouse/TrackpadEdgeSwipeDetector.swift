import Foundation

struct TrackpadEdgeSwipeDetector {
    enum Direction: Equatable {
        case left, right
    }

    enum Frame {
        case idle
        case approaching(id: Int32, position: CGPoint)
        case multipleOrInvalid
        case ended(id: Int32, position: CGPoint)
        case finger(id: Int32, position: CGPoint, began: Bool)
    }

    private enum State {
        case waiting, ready, blocked
        case tracking(Contact)
        case finished(id: Int32)
    }

    private struct Contact {
        let id: Int32
        let origin: CGPoint
        let startTime: TimeInterval
        let leftEdge: Bool
        let entryX: CGFloat
        var maySlideIn: Bool
        var maySlideOut = true
        var lastPosition: CGPoint
        var lastTime: TimeInterval
        var atExit = false
        var lastOutwardSample: TimeInterval?

        func isRecentRelease(at time: TimeInterval) -> Bool {
            (0...0.15).contains(time - lastTime)
        }

        func reachesExit(onReleaseAt time: TimeInterval) -> Bool {
            if atExit { return isRecentRelease(at: time) }
            guard let sample = lastOutwardSample else { return false }
            return (0...0.09).contains(time - sample)
        }
    }

    // A lift near the boundary completes an outward swipe. Allow contacts
    // starting close to the rim to leave with less travel than a slide-in.
    private static let outwardStartWidth: CGFloat = 0.25
    // The rim is measured in normalized sensor coordinates, with a small rounding tolerance.
    private static let rimTolerance: CGFloat = 0.005
    private static let minimumOutwardTravel: CGFloat = 0.012
    private static let minimumTravel: CGFloat = 0.13
    private static let outwardTolerance: CGFloat = 0.025
    private static let maximumVerticalTravel: CGFloat = 0.10
    private static let maximumDuration: TimeInterval = 0.80
    private static let maximumSampleGap: TimeInterval = 0.45

    // Keep actual evidence of the rim for the brief approach-to-touch transition.
    // A sample from a different finger, another edge, or an older approach cannot qualify.
    private struct RimSample {
        let id: Int32
        let position: CGPoint
        let time: TimeInterval

        func leadsTo(id: Int32, point: CGPoint, time: TimeInterval) -> Bool {
            let inward = (point.x - position.x) * (position.x < 0.5 ? 1 : -1)
            return id == self.id && (0...0.10).contains(time - self.time) &&
                (-0.005...0.35).contains(inward) && abs(point.y - position.y) <= 0.06
        }
    }

    private var pendingRim: RimSample?
    private var state = State.waiting

    mutating func record(_ frame: Frame, at time: TimeInterval, onStart: () -> Void = {}) -> Direction? {
        let id: Int32
        let rawPosition: CGPoint
        let began: Bool
        switch frame {
        case let .approaching(fingerID, point):
            // A finger approaching the sensor starts a new sequence. It cannot
            // confirm a pending exit belonging to the previous touch.
            if case .tracking = state { pendingRim = nil }
            if (-0.05...1.05).contains(point.x), (0...1).contains(point.y),
               !(point.x == 0 && point.y == 0), min(point.x, 1 - point.x) <= Self.rimTolerance {
                // Capture the screen before fast pointer motion can cross a display boundary.
                if pendingRim?.leadsTo(id: fingerID, point: point, time: time) != true { onStart() }
                pendingRim = RimSample(id: fingerID, position: point, time: time)
            } else if pendingRim?.leadsTo(id: fingerID, point: point, time: time) != true {
                pendingRim = nil
            }
            state = .ready
            return nil
        case .idle:
            if case let .tracking(contact) = state, time < contact.lastTime { return nil }
            defer {
                state = .ready
                pendingRim = nil
            }
            if case let .tracking(contact) = state, contact.reachesExit(onReleaseAt: time),
               (0...Self.maximumDuration).contains(time - contact.startTime) {
                return contact.leftEdge ? .left : .right
            }
            return nil
        case .multipleOrInvalid:
            pendingRim = nil
            state = .blocked
            return nil
        case let .ended(fingerID, point):
            if case let .tracking(contact) = state, (contact.id != fingerID || time < contact.lastTime) { return nil }
            if case let .finished(id) = state, id != fingerID { return nil }
            defer {
                state = .ready
                pendingRim = nil
            }
            guard case let .tracking(contact) = state,
                  (0...Self.maximumDuration).contains(time - contact.startTime) else { return nil }
            // A lift frame can lose its coordinates as the contact disappears.
            // Prefer an exit already observed while the finger was on the surface.
            guard contact.isRecentRelease(at: time) else { return nil }
            if contact.atExit { return contact.leftEdge ? .left : .right }
            let hasLiftPosition = point.x.isFinite && point.y.isFinite && (point.x != 0 || point.y != 0)
            let retreat = (point.x - contact.lastPosition.x) * (contact.leftEdge ? 1 : -1)
            if contact.reachesExit(onReleaseAt: time),
               !hasLiftPosition || (retreat <= 0.005 && abs(point.y - contact.lastPosition.y) <= 0.025) {
                return contact.leftEdge ? .left : .right
            }
            let observedTravel = contact.lastPosition.x - contact.origin.x
            let finalTravel = point.x - contact.origin.x
            let inwardSign: CGFloat = contact.leftEdge ? 1 : -1
            let confirmedFastEntry = contact.maySlideIn && observedTravel * inwardSign >= 0.04 &&
                abs(contact.lastPosition.y - contact.origin.y) <= abs(observedTravel) / 1.6 &&
                time - contact.lastTime <= 0.09
            guard hasLiftPosition,
                  abs(observedTravel) >= Self.minimumOutwardTravel, observedTravel * finalTravel > 0,
                  abs(point.x - contact.lastPosition.x) <= (confirmedFastEntry ? 0.55 : 0.25),
                  abs(point.y - contact.lastPosition.y) <= Self.maximumVerticalTravel else { return nil }
            if let direction = update(contact, position: point, time: time) { return direction }
            if case let .tracking(updated) = state, updated.reachesExit(onReleaseAt: time) {
                return updated.leftEdge ? .left : .right
            }
            return nil
        case let .finger(fingerID, point, isBeginning):
            id = fingerID
            rawPosition = point
            began = isBeginning
        }
        var entry = pendingRim.flatMap { $0.leadsTo(id: id, point: rawPosition, time: time) ? $0 : nil }
        pendingRim = nil
        if case .blocked = state {
            // A remaining finger moving after multitouch cannot start a swipe.
            // A fresh single-finger touch-down can, even without an idle frame.
            guard began else { return nil }
            state = .ready
        }
        if case let .tracking(contact) = state, began, entry != nil {
            let continuingBegin = contact.id == id && (0...0.035).contains(time - contact.lastTime) &&
                abs(rawPosition.x - contact.lastPosition.x) <= 0.10
            if !continuingBegin { entry = nil }
        }
        // A begin sample sets the origin; it never supplies travel for an older contact.
        switch state {
        case let .tracking(contact):
            guard time >= contact.lastTime else { return nil }
            if began || id != contact.id { state = .ready }
        case let .finished(previousID):
            if began || id != previousID { state = .ready }
        default: break
        }
        guard time.isFinite, (-0.05...1.05).contains(rawPosition.x), (-0.05...1.05).contains(rawPosition.y) else {
            state = .finished(id: id)
            return nil
        }
        let position = CGPoint(x: min(max(rawPosition.x, 0), 1), y: min(max(rawPosition.y, 0), 1))
        switch state {
        case .waiting where !began:
            // 監視開始時点ですでに触れている指は追跡しない。
            state = .finished(id: id)
        case .waiting, .ready:
            let distance = min(position.x, 1 - position.x)
            guard distance <= Self.outwardStartWidth || entry != nil else {
                state = .finished(id: id)
                return nil
            }
            let entryX = entry?.position.x ?? position.x
            let atRim = distance <= Self.rimTolerance
            if began {
                pendingRim = entry ?? (atRim ? RimSample(id: id, position: position, time: time) : nil)
            }
            if entry == nil { onStart() }
            state = .tracking(Contact(id: id, origin: position, startTime: time,
                                      leftEdge: position.x < 0.5, entryX: entryX,
                                      maySlideIn: atRim || entry != nil,
                                      lastPosition: position, lastTime: time))
        case .blocked, .finished:
            break
        case let .tracking(contact):
            return update(contact, position: rawPosition, time: time)
        }
        return nil
    }

    private mutating func update(_ previous: Contact, position: CGPoint, time: TimeInterval) -> Direction? {
        var contact = previous
        let inward = (position.x - contact.origin.x) * (contact.leftEdge ? 1 : -1)
        let vertical = abs(position.y - contact.origin.y)
        guard (0...Self.maximumDuration).contains(time - contact.startTime),
              (0...Self.maximumSampleGap).contains(time - contact.lastTime),
              vertical <= Self.maximumVerticalTravel,
              (-0.05...1.05).contains(position.x), (-0.05...1.05).contains(position.y) else {
            state = .finished(id: contact.id)
            return nil
        }
        if inward < -Self.outwardTolerance { contact.maySlideIn = false }
        if inward > Self.outwardTolerance { contact.maySlideOut = false }
        let totalInward = (position.x - contact.entryX) * (contact.leftEdge ? 1 : -1)
        if contact.maySlideIn && totalInward >= Self.minimumTravel && inward >= 0.04 && inward >= 1.6 * vertical {
            state = .finished(id: contact.id)
            return contact.leftEdge ? .right : .left
        }
        let edgeDistance = contact.leftEdge ? position.x : 1 - position.x
        contact.atExit = contact.maySlideOut && edgeDistance <= Self.rimTolerance && -inward >= Self.minimumOutwardTravel &&
            -inward >= 1.6 * vertical
        // Near the physical edge the sensor can lose the finger before sampling
        // the rim. Require two outward segments and a trajectory that would
        // cross it shortly; a pause, retreat or single jump cannot qualify.
        let sign: CGFloat = contact.leftEdge ? -1 : 1
        let previousTravel = (contact.lastPosition.x - contact.origin.x) * sign
        let step = (position.x - contact.lastPosition.x) * sign
        let dt = time - contact.lastTime
        if contact.maySlideOut && edgeDistance <= 0.045 &&
            previousTravel >= 0.006 && -inward >= Self.minimumOutwardTravel &&
            -inward >= 1.6 * vertical && step > 0 && dt > 0 &&
            edgeDistance * CGFloat(dt) <= step * 0.065 {
            contact.lastOutwardSample = time
        } else if position.x != contact.lastPosition.x || position.y != contact.lastPosition.y {
            contact.lastOutwardSample = nil
        }
        // Identical trailing samples neither cancel an exit nor extend its deadline.
        contact.lastTime = time
        contact.lastPosition = position
        state = .tracking(contact)
        return nil
    }
}

/// MultitouchSupportはデバイスごとのスレッドでフレームを通知する。
final class TrackpadEdgeSwipeSession {
    private let lock = NSLock()
    private var detectors: [UInt: TrackpadEdgeSwipeDetector] = [:]

    private var displays: [UInt: UInt32] = [:]

    func record(device: UInt, frame: TrackpadEdgeSwipeDetector.Frame, at time: TimeInterval,
                pointerDisplay: () -> UInt32?) -> (TrackpadEdgeSwipeDetector.Direction, UInt32)? {
        lock.lock()
        defer { lock.unlock() }
        let direction = detectors[device, default: TrackpadEdgeSwipeDetector()].record(frame, at: time) {
            displays[device] = pointerDisplay()
        }
        guard let result = direction, let display = displays[device] else { return nil }
        return (result, display)
    }
}
