import Cocoa
import Carbon
import CoreGraphics

// 実際のInputHookへOS障害を注入する。グローバルな入力監視・権限変更・キー送出は行わない。
private final class Fixture {
    var trusted = true
    var listening = true
    var secureInput = false
    var creationFails = false
    var enableFails = false
    var enabled = false
    var prompts = 0
    var listenRequests = 0
    var locations: [CGEventTapLocation] = []
    var masks: [CGEventMask] = []
    var enableCalls = 0
    func environment() -> InputHook.Environment {
        var environment = InputHook.Environment()
        environment.hasAccessibility = { [self] prompt in
            if prompt { prompts += 1 }
            return trusted
        }
        environment.hasListenAccess = { [self] in listening }
        environment.requestListenAccess = { [self] in listenRequests += 1 }
        environment.isSecureInputEnabled = { [self] in secureInput }
        environment.createTap = { [self] location, mask, _, _ in
            locations.append(location)
            masks.append(mask)
            guard !creationFails else { return nil }
            enabled = false
            return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
        }
        environment.isEnabled = { [self] _ in enabled }
        environment.setEnabled = { [self] _, value in
            enableCalls += 1
            enabled = value && !enableFails
        }
        return environment
    }
}

private final class Delegate: InputHookDelegate {
    var calls: [(Int64, InputHook.Flags, Bool)] = []
    var resets = 0
    var repeats = 0
    var activations = 0
    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool {
        calls.append((keycode, flags, pressed))
        if keycode == Int64(kVK_ANSI_Semicolon) && flags.ctrl && !pressed { activations += 1 }
        return true
    }
    func handleRepeatedInput(_ keycode: Int64, _ flags: InputHook.Flags) -> Bool {
        repeats += 1
        return true
    }
    func inputHookDidReset() { resets += 1 }
}

@main
private enum InputHookRecoverySmoke {
    static func key(_ down: Bool, code: Int = kVK_ANSI_Semicolon, ownPID: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = down ? .maskControl : []
        event.setIntegerValueField(.eventSourceUnixProcessID, value: ownPID ? Int64(ProcessInfo.processInfo.processIdentifier) : 0)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 40)
        return event
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func main() {
        var cases = 0
        func run(_ name: String, _ body: () -> Void) {
            body(); cases += 1; print("PASS \(name)")
        }
        run("nil tap is recoverable without a crash") {
            let f = Fixture(); f.creationFails = true
            let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false)
            check(hook.status == .unavailable, "nil tap must be visible")
            check(hook._port == nil, "no fake success")
            f.creationFails = false; hook.recoverIfNeeded()
            check(hook.status == .running, "transient creation failure must recover")
        }
        run("session tap and keyboard event mask") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false)
            check(f.locations == [.cgSessionEventTap], "must not depend on HID entry")
            let expected = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            check(f.masks == [expected], "must preserve key down/up/modifiers")
        }
        run("AX permission denied then granted") {
            let f = Fixture(); f.trusted = false
            let hook = InputHook(environment: f.environment())
            hook.enable()
            check(hook.status == .accessibilityRequired && f.locations.isEmpty, "denial must not terminate or start a tap")
            f.trusted = true; hook.recoverIfNeeded()
            check(hook.status == .running && f.prompts == 1, "grant must recover without repeated prompts")
        }
        run("listen permission prompt only on explicit request") {
            let f = Fixture(); f.listening = false; f.creationFails = true
            let hook = InputHook(environment: f.environment())
            hook.enable()
            check(hook.status == .inputMonitoringRequired && f.listenRequests == 1, "permission diagnosis")
            hook.recoverIfNeeded(); hook.recoverIfNeeded()
            check(f.listenRequests == 1, "background polling must not prompt")
            f.listening = true; f.creationFails = false; hook.recoverIfNeeded()
            check(hook.status == .running, "listen access recovery")
        }
        run("a working AX filter needs no extra listen grant") {
            let f = Fixture(); f.listening = false
            let hook = InputHook(environment: f.environment()); hook.enable()
            check(hook.status == .running && f.listenRequests == 0, "do not require unnecessary privileges")
        }
        run("Ctrl semicolon keyup preserves keydown modifiers") {
            let hook = InputHook(environment: Fixture().environment()); let d = Delegate(); hook.delegate = d
            check(hook.handleTapEvent(.keyDown, key(true)), "keydown delivery")
            check(hook.handleTapEvent(.keyUp, key(false)), "keyup delivery")
            check(d.calls.count == 2 && d.calls[0].0 == Int64(kVK_ANSI_Semicolon), "physical key preserved")
            check(d.calls[1].1.ctrl && !d.calls[1].2 && d.calls[1].1.keyboardType == 40, "keyup must retain Ctrl and keyboard layout")
        }
        run("timeout notification before source PID filter") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false)
            _ = hook.handleTapEvent(.keyDown, key(true)); hook.wheel = true
            f.enabled = false
            _ = hook.handleTapEvent(.tapDisabledByTimeout, key(true, ownPID: true))
            check(hook.status == .running && f.enabled, "timeout must reenable the tap")
            check(hook._pressed.isEmpty && !hook.wheel && d.resets == 1, "held state cleared once")
            check(d.calls.count == 1, "never replay shortcut keyup on reset")
            check(!hook.handleTapEvent(.keyUp, key(false)), "orphan keyup must not activate a mode")
            _ = hook.handleTapEvent(.keyDown, key(true)); _ = hook.handleTapEvent(.keyUp, key(false))
            check(d.calls.count == 3 && !d.calls[2].2, "shortcut works again after timeout")
        }
        run("user-input disable notification recovers") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false); f.enabled = false
            _ = hook.handleTapEvent(.tapDisabledByUserInput, key(true))
            check(hook.status == .running && d.resets == 1, "user-input disabled tap must recover")
        }
        run("watchdog detects a silently disabled tap") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false); f.enabled = false; hook.recoverIfNeeded()
            check(hook.status == .running && d.resets == 1, "watchdog recovery")
        }
        run("invalidated port is recreated") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false); let old = hook._port!
            CFMachPortInvalidate(old); hook.recoverIfNeeded()
            check(hook.status == .running && f.locations.count == 2 && CFMachPortIsValid(hook._port), "invalid port recovery")
        }
        run("explicit disable cannot be undone by recovery") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false); hook.disable(); let count = f.enableCalls
            hook.recoverIfNeeded(); _ = hook.handleTapEvent(.tapDisabledByTimeout, key(true))
            check(hook.status == .disabled && !f.enabled && f.enableCalls == count, "intentional stop must remain stopped")
        }
        run("AX revocation clears held state without prompting") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false); _ = hook.keyDown(key(true))
            f.trusted = false; hook.recoverIfNeeded()
            check(hook.status == .accessibilityRequired && hook._pressed.isEmpty && d.resets == 1, "revocation state")
            check(hook._port == nil && f.prompts == 0, "revocation teardown must not prompt")
            f.trusted = true; hook.recoverIfNeeded(); check(hook.status == .running, "regrant recovery")
        }
        run("secure input is respected and recovery clears stale keys") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false); _ = hook.keyDown(key(true))
            f.secureInput = true; hook.recoverIfNeeded()
            check(hook.status == .secureInput && hook._pressed.isEmpty && d.resets == 1, "secure input state")
            check(f.listenRequests == 0 && f.secureInput, "do not disable secure input or request unrelated permissions")
            f.secureInput = false; hook.recoverIfNeeded(); check(hook.status == .running, "secure input exit recovery")
        }
        run("missing delegate passes through instead of crashing") {
            let hook = InputHook()
            check(!hook.keyDown(key(true)) && !hook.keyUp(key(false)), "no delegate must pass through")
        }
        run("key repeat remains bounded by initial decision") {
            let hook = InputHook(); let d = Delegate(); hook.delegate = d
            _ = hook.keyDown(key(true)); _ = hook.keyDown(key(true)); _ = hook.keyUp(key(false))
            check(d.calls.count == 2 && d.repeats == 1, "repeat delivery")
        }
        run("repeated enable does not duplicate a valid tap") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false); hook.enable(promptForPermissions: false); hook.recoverIfNeeded()
            check(f.locations.count == 1, "one tap only")
        }
        run("explicit reconnect clears a missing keyup and recognizes the first fresh chord") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false)
            let old = hook._port!
            let unmodified = key(true); unmodified.flags = []
            _ = hook.handleTapEvent(.keyDown, unmodified) // key-up intentionally lost
            hook.wheel = true
            hook.reconnect(promptForPermissions: false)
            check(!CFMachPortIsValid(old) && f.locations.count == 2, "replace even an enabled valid tap")
            check(hook.status == .running && hook._pressed.isEmpty && !hook.wheel && d.resets == 1, "release held state once")
            check(d.activations == 0 && d.calls.count == 1, "never synthesize a missing shortcut release")
            check(!hook.handleTapEvent(.keyUp, key(false)), "orphan keyup must pass through")
            _ = hook.handleTapEvent(.keyDown, key(true)); _ = hook.handleTapEvent(.keyUp, key(false))
            check(d.activations == 1 && d.repeats == 0 && d.calls.count == 3, "first fresh Ctrl semicolon must work")
            check(f.prompts == 0 && f.listenRequests == 0, "nonprompting reconnect must not request permissions")
        }
        run("failed explicit reconnect discards the old tap and remains recoverable") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false); let old = hook._port!
            f.creationFails = true; hook.reconnect(promptForPermissions: false)
            check(!CFMachPortIsValid(old) && hook._port == nil && hook.status == .unavailable && d.resets == 1, "failed creation must not preserve stale tap")
            f.creationFails = false; hook.recoverIfNeeded()
            check(hook.status == .running && f.locations.count == 3, "watchdog must recover after reconnect failure")
        }
        run("explicit reconnect respects missing Accessibility permission") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false); let old = hook._port!
            f.trusted = false; hook.reconnect(promptForPermissions: false)
            check(!CFMachPortIsValid(old) && hook._port == nil && hook.status == .accessibilityRequired && f.prompts == 0, "permission denial after teardown")
            f.trusted = true; hook.recoverIfNeeded()
            check(hook.status == .running && f.locations.count == 2, "grant must create a fresh tap")
        }
        run("explicit reconnect waits for secure input without retaining the old tap") {
            let f = Fixture(); let hook = InputHook(environment: f.environment())
            hook.enable(promptForPermissions: false); let old = hook._port!
            f.secureInput = true; hook.reconnect(promptForPermissions: false)
            check(!CFMachPortIsValid(old) && hook._port == nil && hook.status == .secureInput, "respect protected input")
            check(f.secureInput && f.listenRequests == 0, "do not disable protection or request unrelated access")
            f.secureInput = false; hook.recoverIfNeeded()
            check(hook.status == .running && f.locations.count == 2, "secure input exit must recreate the tap")
        }
        run("repeated explicit reconnect invalidates every replaced port") {
            let f = Fixture(); let hook = InputHook(environment: f.environment()); let d = Delegate(); hook.delegate = d
            hook.enable(promptForPermissions: false)
            for _ in 0..<3 {
                let old = hook._port!
                hook.reconnect(promptForPermissions: false)
                check(!CFMachPortIsValid(old) && hook.status == .running, "no stale callback after each replacement")
            }
            check(f.locations.count == 4 && d.resets == 3, "exactly one new tap and reset per explicit reconnect")
        }
        run("deinit releases the timer and invalidates the port") {
            let f = Fixture(); var hook: InputHook? = InputHook(environment: f.environment()); weak var weakHook = hook
            hook?.enable(promptForPermissions: false); let port = hook!._port!; hook = nil
            check(weakHook == nil && !CFMachPortIsValid(port), "no timer cycle or live callback after destruction")
        }
        run("failed reenable reports a missing permission") {
            let f = Fixture(); f.enableFails = true; f.listening = false
            let hook = InputHook(environment: f.environment()); hook.enable()
            check(hook.status == .inputMonitoringRequired && f.listenRequests == 1, "failed enable diagnostic")
        }
        print("InputHook recovery smoke: \(cases) cases passed")
    }
}
