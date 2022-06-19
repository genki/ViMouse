//
//  InputHook.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/24.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import CoreGraphics

protocol InputHookDelegate {
    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool
}

class InputHook {
    struct Flags {
        var ctrl = false
        var shift = false
        var opt = false
        var cmd = false
        var fnc = false
        var wheel = false
        
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
    let pid = ProcessInfo.processInfo.processIdentifier
    var wheel:Bool {
        get{return _flags.wheel}
        set(aWheel){_flags.wheel = aWheel}
    }
    var _port: CFMachPort?
    var _pressed = Dictionary<Int64, (Bool, Flags)>()
    var _flags = Flags()
    
    let _callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
        let this = Unmanaged<InputHook>.fromOpaque(_:arg!).takeUnretainedValue()
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if(Int32(pid) != this.pid){
            switch(type){
            case .keyDown: if(this.keyDown(event)){return nil}
            case .keyUp: if(this.keyUp(event)){return nil}
            case .flagsChanged: this._flags = Flags.from(event.flags)
            default: break
            }
        }
        return Unmanaged<CGEvent>.passUnretained(event)
    }
    
    var delegate: InputHookDelegate?

    func keyDown(_ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = _pressed[keycode]
        if(pressed == nil){
            let result = (self.delegate?.handleInput(keycode, _flags, true))!
            _pressed[keycode] = (result, _flags)
            return result
        }else{
            return pressed!.0
        }
    }
    func keyUp(_ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = _pressed.removeValue(forKey: keycode)
        if(pressed != nil){
            return (self.delegate?.handleInput(keycode, pressed!.1, false))!
        }
        return false
    }
    func setup(){
        let types:[CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(0){$0 | CGEventMask(1 << $1.rawValue)}
        //| CGEventMask(UInt64.max)
        _port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: _callback, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode)
    }
    func enable(){
        if(_port == nil){
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options:Dictionary = [key: NSNumber(value: true as Bool)]
            if(AXIsProcessTrustedWithOptions(options as CFDictionary) != false){
                setup()
            }else{
                return
            }
        }
        CGEvent.tapEnable(tap: _port!, enable: true)
    }
    func disable(){
        if(_port != nil){
            CGEvent.tapEnable(tap: _port!, enable: false)
        }
    }
}
