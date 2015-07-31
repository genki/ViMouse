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
    func handleInput(keycode: Int64, _ flags: CGEventFlags, _ pressed: Bool) -> Bool
}

class InputHook {
    let pid = NSProcessInfo.processInfo().processIdentifier
    var _port: CFMachPort?
    var _pressed = Dictionary<Int64, (Bool, CGEventFlags)>()
    var _flags = CGEventFlags(rawValue: 0)
    
    let _callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
        let this = Unmanaged<InputHook>.fromOpaque(COpaquePointer(arg)).takeUnretainedValue()
        let pid = CGEventGetIntegerValueField(event, .EventSourceUnixProcessID)
        if(Int32(pid) != this.pid){
            switch(type){
            case .KeyDown: if(this.keyDown(event)){return nil}
            case .KeyUp: if(this.keyUp(event)){return nil}
            case .FlagsChanged: this._flags = CGEventGetFlags(event)
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
            let result = (self.delegate?.handleInput(keycode, _flags!, true))!
            _pressed[keycode] = (result, _flags!)
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