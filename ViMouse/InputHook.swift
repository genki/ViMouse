//
//  InputHook.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/24.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import CoreGraphics
import Carbon

protocol InputHookDelegate: AnyObject {
    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool
    func handleRepeatedInput(_ keycode: Int64, _ flags: InputHook.Flags) -> Bool
    func inputHookDidReset()
}

extension InputHookDelegate {
    func inputHookDidReset() {}
    func handleRepeatedInput(_ keycode: Int64, _ flags: InputHook.Flags) -> Bool {
        true
    }
}

class InputHook {
    struct Flags {
        var ctrl = false
        var shift = false
        var opt = false
        var cmd = false
        var fnc = false
        var wheel = false
        // Physical device metadata is needed to distinguish JIS/ANSI/ISO layouts.
        var keyboardType: UInt32?
        
        static func from(_ flags:CGEventFlags?, aWheel:Bool = false) -> Flags{
            var result = Flags()
            if(flags != nil){
                result.ctrl = (flags!.rawValue & CGEventFlags.maskControl.rawValue) != 0
                result.shift = (flags!.rawValue & CGEventFlags.maskShift.rawValue) != 0
                result.opt = (flags!.rawValue & CGEventFlags.maskAlternate.rawValue) != 0
                result.cmd = (flags!.rawValue & CGEventFlags.maskCommand.rawValue) != 0
                result.fnc = (flags!.rawValue & CGEventFlags.maskSecondaryFn.rawValue) != 0
            }
            result.wheel = aWheel
            return result
        }
        func tuple() -> (Bool,Bool,Bool,Bool,Bool,Bool){
            return (ctrl, shift, opt, cmd, fnc, wheel)
        }
        func set(_ event:CGEvent?){
            var flags:UInt64 = 0
            if ctrl {flags |= CGEventFlags.maskControl.rawValue}
            if shift {flags |= CGEventFlags.maskShift.rawValue}
            if opt {flags |= CGEventFlags.maskAlternate.rawValue}
            if cmd {flags |= CGEventFlags.maskCommand.rawValue}
            if fnc {flags |= CGEventFlags.maskSecondaryFn.rawValue}
            event?.flags = CGEventFlags(rawValue: flags)
        }
    }
    enum Status {
        case disabled, running, accessibilityRequired, inputMonitoringRequired, secureInput, unavailable
    }

    // OSが監視を拒否する場合も、権限を変更せずに実処理を検証できるようにする。
    struct Environment {
        var hasAccessibility: (Bool) -> Bool = { prompt in
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        }
        var hasListenAccess: () -> Bool = {
            if #available(macOS 10.15, *) { return CGPreflightListenEventAccess() }
            return true
        }
        var requestListenAccess: () -> Void = {
            if #available(macOS 10.15, *) { _ = CGRequestListenEventAccess() }
        }
        var isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
        var createTap: (CGEventTapLocation, CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort? = {
            CGEvent.tapCreate(tap: $0, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: $1, callback: $2, userInfo: $3)
        }
        var isValid: (CFMachPort) -> Bool = { CFMachPortIsValid($0) }
        var isEnabled: (CFMachPort) -> Bool = { CGEvent.tapIsEnabled(tap: $0) }
        var setEnabled: (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) }
    }

    private let environment: Environment
    private var wantsEnabled = false
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var recoveryTimer: Timer?
    private(set) var status: Status = .disabled {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?
    let pid = ProcessInfo.processInfo.processIdentifier

    init(environment: Environment = Environment()) { self.environment = environment }

    deinit {
        recoveryTimer?.invalidate()
        removeTap()
    }
    var wheel:Bool {
        get{return _flags.wheel}
        set(aWheel){_flags.wheel = aWheel}
    }
    var _port: CFMachPort?
    var _pressed = Dictionary<Int64, (Bool, Flags)>()
    var _flags = Flags()
    
    let _callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
        guard let arg = arg else { return Unmanaged.passUnretained(event) }
        let this = Unmanaged<InputHook>.fromOpaque(arg).takeUnretainedValue()
        if this.handleTapEvent(type, event) { return nil }
        return Unmanaged<CGEvent>.passUnretained(event)
    }
    
    weak var delegate: InputHookDelegate?

    func handleTapEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // 無効化通知には通常の入力元PID判定を適用しない。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetInputState()
            if wantsEnabled { status = .unavailable }
            recoverIfNeeded()
            return false
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(pid) else { return false }
        switch type {
        case .keyDown: return keyDown(event)
        case .keyUp: return keyUp(event)
        case .flagsChanged: _flags = Flags.from(event.flags)
        default: break
        }
        return false
    }

    func keyDown(_ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = _pressed[keycode]
        if(pressed == nil){
            var flags = Flags.from(event.flags, aWheel: _flags.wheel)
            let type = event.getIntegerValueField(.keyboardEventKeyboardType)
            flags.keyboardType = type > 0 ? UInt32(exactly: type) : nil
            let result = delegate?.handleInput(keycode, flags, true) ?? false
            _pressed[keycode] = (result, flags)
            return result
        }else{
            if pressed!.0 {
                return (self.delegate?.handleRepeatedInput(keycode, pressed!.1)) ?? true
            }
            return pressed!.0
        }
    }
    func keyUp(_ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = _pressed.removeValue(forKey: keycode)
        if(pressed != nil){
            return delegate?.handleInput(keycode, pressed!.1, false) ?? false
        }
        return false
    }
    @discardableResult
    private func setup() -> Bool {
        let types:[CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(0){$0 | CGEventMask(1 << $1.rawValue)}
        // HID入口のroot権限に依存せず、ログイン中のユーザーセッションで監視する。
        guard let port = environment.createTap(.cgSessionEventTap, mask, _callback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else { return false }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        _port = port
        source = newSource
        runLoop = CFRunLoopGetMain()
        for mode in modes { CFRunLoopAddSource(runLoop, newSource, mode) }
        return true
    }

    private var modes: [CFRunLoopMode] {
        [.commonModes, CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString),
         CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString)]
    }

    private func removeTap() {
        if let source = source {
            if let runLoop = runLoop { for mode in modes { CFRunLoopRemoveSource(runLoop, source, mode) } }
            CFRunLoopSourceInvalidate(source)
        }
        if let port = _port { CFMachPortInvalidate(port) }
        source = nil
        runLoop = nil
        _port = nil
    }

    private func resetInputState() {
        _pressed.removeAll()
        _flags = Flags()
        // 欠落したkeyupを通常入力として再生すると、逆にモード切替を発火してしまう。
        delegate?.inputHookDidReset()
    }

    func enable(promptForPermissions: Bool = true) {
        wantsEnabled = true
        recoverIfNeeded(promptForPermissions: promptForPermissions)
        if recoveryTimer == nil {
            let target = InputHookRecoveryTarget(self)
            let timer = Timer(timeInterval: 2, target: target, selector: #selector(InputHookRecoveryTarget.poll), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            recoveryTimer = timer
        }
    }

    // Explicit recovery must discard stale key state and even an apparently
    // healthy tap. Ordinary enable/polling remains idempotent.
    func reconnect(promptForPermissions: Bool = true) {
        disable()
        removeTap()
        enable(promptForPermissions: promptForPermissions)
    }

    func recoverIfNeeded(promptForPermissions: Bool = false) {
        guard wantsEnabled else { return }
        guard environment.hasAccessibility(promptForPermissions) else {
            if status == .running { resetInputState() }
            removeTap()
            status = .accessibilityRequired
            return
        }
        if environment.isSecureInputEnabled() {
            if status == .running { resetInputState() }
            status = .secureInput
            return
        }
        if let port = _port, !environment.isValid(port) {
            resetInputState()
            removeTap()
        }
        if _port == nil && !setup() {
            markUnavailable(promptForPermissions: promptForPermissions)
            return
        }
        guard let port = _port else { return }
        if !environment.isEnabled(port) {
            if status == .running { resetInputState() }
            environment.setEnabled(port, true)
        }
        if environment.isEnabled(port) { status = .running }
        else { markUnavailable(promptForPermissions: promptForPermissions) }
    }

    private func markUnavailable(promptForPermissions: Bool) {
        let missingListenAccess = !environment.hasListenAccess()
        status = missingListenAccess ? .inputMonitoringRequired : .unavailable
        if missingListenAccess && promptForPermissions { environment.requestListenAccess() }
    }

    func disable() {
        wantsEnabled = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        if let port = _port { environment.setEnabled(port, false) }
        resetInputState()
        status = .disabled
    }
}

// Timerはtargetを保持するため、アプリ本体への参照は弱参照にして循環を避ける。
private final class InputHookRecoveryTarget: NSObject {
    weak var hook: InputHook?
    init(_ hook: InputHook) { self.hook = hook; super.init() }
    @objc func poll() { hook?.recoverIfNeeded() }
}
