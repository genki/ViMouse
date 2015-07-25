//
//  InputHook.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/24.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import CoreGraphics

class InputHook {
    var _port: CFMachPort?
    
    func keyDown(event: CGEvent){
        
    }
    func keyUp(event: CGEvent){
        
    }
    func flagChanged(event: CGEvent){
        
    }
    func setup(){
        let callback: CGEventTapCallBack = {(proxy, type, event, arg) -> Unmanaged<CGEvent>? in
            let this = Unmanaged<InputHook>.fromOpaque(COpaquePointer(arg)).takeUnretainedValue()
            switch(type){
            case .KeyDown: this.keyDown(event)
            case .KeyUp: this.keyUp(event)
            case .FlagsChanged: this.flagChanged(event)
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