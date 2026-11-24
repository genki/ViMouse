import AppKit
import QuartzCore

/// Decides whether a key event is eligible to show the cursor locator.
///
/// InputHook calls the delegate only once for the initial key-down and routes
/// subsequent repeats through handleRepeatedInput. Keeping this predicate
/// pure makes the modifier policy independently testable.
enum CursorRippleTrigger {
    static func isEligible(keycode: Int, flags: InputHook.Flags) -> Bool {
        keycode == KeyMapping.keyCode(for: .cursorRipple)
            && !flags.ctrl
            && !flags.opt
            && !flags.cmd
            && !flags.fnc
    }

    static func shouldTrigger(keycode: Int, flags: InputHook.Flags, pressed: Bool) -> Bool {
        pressed && isEligible(keycode: keycode, flags: flags)
    }
}

/// Keep observing cursor motion while ViMouse is in either keyboard mode.
final class CursorShakeMonitor {
    private static let eventMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]

    private var detector = CursorShakeDetector()
    private let onShake: (NSPoint) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(onShake: @escaping (NSPoint) -> Void) {
        self.onShake = onShake
    }

    func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
                self?.observe(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
                self?.observe(event)
                return event
            }
        }
    }

    func stop() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        globalMonitor = nil
        detector.reset()
    }

    private func observe(_ event: NSEvent) {
        guard event.type == .mouseMoved else {
            detector.reset()
            return
        }
        let location = event.locationInWindow
        let point = event.window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? location
        if detector.record(point, at: event.timestamp) {
            onShake(point)
        }
    }
}

/// Displays a short-lived, click-through marker at the current pointer.
///
/// This is intentionally a separate window instead of an application view:
/// ViMouse is a menu-bar application and the pointer can be over any other
/// application, Space, or full-screen window.
final class CursorRippleController: NSObject {
    private let window: NSPanel
    private let rippleView: CursorRippleView
    // The ring radius is enlarged tenfold; keep enough room around it so the
    // outer edge is not clipped by the click-through panel.
    private static let windowSize = NSSize(width: 320, height: 320)
    private var hideWorkItem: DispatchWorkItem?

    override init() {
        let view = CursorRippleView(frame: NSRect(origin: .zero, size: Self.windowSize))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        rippleView = view
        window = panel
        super.init()

        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.orderOut(nil)
    }

    deinit {
        hideWorkItem?.cancel()
    }

    func show(at point: NSPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(at: point)
            }
            return
        }

        hideWorkItem?.cancel()

        window.setFrameOrigin(NSPoint(
            x: point.x - Self.windowSize.width / 2,
            y: point.y - Self.windowSize.height / 2
        ))
        window.orderFrontRegardless()
        rippleView.play()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.86, execute: workItem)
    }

    func hide() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hide()
            }
            return
        }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        rippleView.stop()
        window.orderOut(nil)
    }
}

private final class CursorRippleView: NSView {
    private var rings: [CAShapeLayer] = []
    private let ringRadius: CGFloat = 130
    private let ringCount = 3
    private let animationDuration: TimeInterval = 0.62
    private let ringDelay: TimeInterval = 0.08

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        updatePaths()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    func play() {
        guard let rootLayer = layer else { return }

        updatePaths()
        rootLayer.removeAllAnimations()

        let reduceMotion: Bool
        if #available(macOS 10.12, *) {
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        } else {
            reduceMotion = false
        }

        let newRings = (0..<(reduceMotion ? 1 : ringCount)).map { _ in makeRing() }
        for ring in newRings {
            rings.append(ring)
            rootLayer.addSublayer(ring)
        }
        updatePaths()

        if reduceMotion {
            // Leave a static, high-contrast marker briefly when the user has
            // requested reduced motion instead of silently removing feedback.
            if let first = newRings.first {
                first.opacity = 1
                first.transform = CATransform3DMakeScale(0.85, 0.85, 1)
                scheduleRemoval(of: first, after: 0.86)
            }
            return
        }

        let now = CACurrentMediaTime()
        for (index, ring) in newRings.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.18
            scale.toValue = 1.0

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.98, 0.72, 0.0]
            opacity.keyTimes = [0.0, 0.34, 1.0]

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = animationDuration
            group.beginTime = ring.convertTime(now, from: nil) + Double(index) * ringDelay
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "cursorRipple")
            scheduleRemoval(
                of: ring,
                after: animationDuration + Double(index) * ringDelay
            )
        }
    }

    func stop() {
        for ring in rings {
            ring.removeAllAnimations()
            ring.removeFromSuperlayer()
        }
        rings.removeAll(keepingCapacity: true)
    }

    private func makeRing() -> CAShapeLayer {
        // A dark shadow around the bright stroke keeps the marker legible on
        // both light and dark application content without sampling the screen.
        let ring = CAShapeLayer()
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor(calibratedRed: 0.15, green: 0.72, blue: 1.0, alpha: 0.98).cgColor
        ring.lineWidth = 3.5
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 2.5
        ring.shadowOffset = .zero
        ring.opacity = 0
        return ring
    }

    private func scheduleRemoval(of ring: CAShapeLayer, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak ring] in
            guard let self = self, let ring = ring else { return }
            guard let index = self.rings.firstIndex(where: { $0 === ring }) else { return }
            ring.removeAllAnimations()
            ring.removeFromSuperlayer()
            self.rings.remove(at: index)
        }
    }

    private func updatePaths() {
        guard let rootLayer = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        for ring in rings {
            ring.frame = rootLayer.bounds
            ring.path = CGPath(
                ellipseIn: CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ),
                transform: nil
            )
        }

        CATransaction.commit()
    }
}
