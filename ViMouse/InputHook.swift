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
    var _port: CFMachPort?
    var _pressed = Dictionary<Int64, Bool>()
    var _flags = CGEventFlags(rawValue: 0)
    
    var delegate: InputHookDelegate?
    
    func keyDown(event: CGEvent) -> Bool {
        let keycode = CGEventGetIntegerValueField(event, CGEventField.KeyboardEventKeycode)
        let pressed = _pressed[keycode]
        if(pressed == nil){
            let result = (self.delegate?.handleInput(keycode, _flags!, true))!
            _pressed[keycode] = result
            return result
        }else{
            return pressed!
        }
    }
    func keyUp(event: CGEvent) -> Bool {
        let keycode = CGEventGetIntegerValueField(event, CGEventField.KeyboardEventKeycode)
        if((_pressed.removeValueForKey(keycode)) != nil){
            return (self.delegate?.handleInput(keycode, _flags!, false))!
        }
        return false
    }
    func flagsChanged(event: CGEvent){
        _flags = CGEventGetFlags(event)
    }
    func setup(){
        let callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
            let this = Unmanaged<InputHook>.fromOpaque(COpaquePointer(arg)).takeUnretainedValue()
            switch(type){
            case .KeyDown: if(this.keyDown(event)){return nil}
            case .KeyUp: if(this.keyUp(event)){return nil}
            case .FlagsChanged: this.flagsChanged(event)
            default: break
            }
            return Unmanaged<CGEvent>.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.KeyDown.rawValue)
            | CGEventMask(1 << CGEventType.KeyUp.rawValue)
            | CGEventMask(1 << CGEventType.FlagsChanged.rawValue)
        _port = CGEventTapCreate(CGEventTapLocation.CGSessionEventTap,
            CGEventTapPlacement.HeadInsertEventTap, CGEventTapOptions.Default,
            mask, callback, UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()))!
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