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
    func handleInput(keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool
}

class InputHook {
    struct Flags {
        var ctrl = false
        var shift = false
        var opt = false
        var cmd = false
        var wheel = false
        
        static func from(flags:CGEventFlags?, aWheel:Bool = false) -> Flags{
            var result = Flags()
            if(flags != nil){
                result.ctrl = (flags!.rawValue & CGEventFlags.FlagMaskControl.rawValue) != 0
                result.shift = (flags!.rawValue & CGEventFlags.FlagMaskShift.rawValue) != 0
                result.opt = (flags!.rawValue & CGEventFlags.FlagMaskAlternate.rawValue) != 0
                result.cmd = (flags!.rawValue & CGEventFlags.FlagMaskCommand.rawValue) != 0
            }
            result.wheel = aWheel
            return result
        }
        func tuple() -> (Bool,Bool,Bool,Bool,Bool){return (ctrl, shift, opt, cmd, wheel)}
    }
    let pid = NSProcessInfo.processInfo().processIdentifier
    var wheel:Bool {
        get{return _flags.wheel}
        set(aWheel){_flags.wheel = aWheel}
    }
    var _port: CFMachPort?
    var _pressed = Dictionary<Int64, (Bool, Flags)>()
    var _flags = Flags()
    
    let _callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
        let this = Unmanaged<InputHook>.fromOpaque(COpaquePointer(arg)).takeUnretainedValue()
        let pid = CGEventGetIntegerValueField(event, .EventSourceUnixProcessID)
        if(Int32(pid) != this.pid){
            switch(type){
            case .KeyDown: if(this.keyDown(event)){return nil}
            case .KeyUp: if(this.keyUp(event)){return nil}
            case .FlagsChanged: this._flags = Flags.from(CGEventGetFlags(event))
            default: break
            }
        }
        return Unmanaged<CGEvent>.passUnretained(event)
    }
    
    var delegate: InputHookDelegate?

    func keyDown(event: CGEvent) -> Bool {
        let keycode = CGEventGetIntegerValueField(event, .KeyboardEventKeycode)
        let pressed = _pressed[keycode]
        if(pressed == nil){
            let result = (self.delegate?.handleInput(keycode, _flags, true))!
            _pressed[keycode] = (result, _flags)
            return result
        }else{
            return pressed!.0
        }
    }
    func keyUp(event: CGEvent) -> Bool {
        let keycode = CGEventGetIntegerValueField(event, .KeyboardEventKeycode)
        let pressed = _pressed.removeValueForKey(keycode)
        if(pressed != nil){
            return (self.delegate?.handleInput(keycode, pressed!.1, false))!
        }
        return false
    }
    func setup(){
        let types:[CGEventType] = [.KeyDown, .KeyUp, .FlagsChanged]
        let mask = types.reduce(0){$0 | CGEventMask(1 << $1.rawValue)}
        //let mask = CGEventMask(UInt64.max)
        _port = CGEventTapCreate(.CGHIDEventTap, .HeadInsertEventTap, .Default,
            mask, _callback, UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()))!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode)
    }
    func enable(){
        if(_port == nil){
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options:Dictionary = [key: NSNumber(bool: true)]
            if(AXIsProcessTrustedWithOptions(options as CFDictionary) != 0){
                setup()
            }else{
                return
            }
        }
        CGEventTapEnable(_port!, true)
    }
    func disable(){
        if(_port != nil){
            CGEventTapEnable(_port!, false)
        }
    }
}