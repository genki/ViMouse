//
//  AppDelegate.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/19.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import CoreGraphics

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, InputHookDelegate {
    var _inputHook = InputHook()
    var _speedSlower = false
    var _speedSlow = false
    var _speedFast = false
    var _speedFaster = false
    var _leftButton = false
    var _rightButton = false
    var _centerButton = false
    var _baseSpeed:CGFloat = 1.33
    var _dx:CGFloat = 0.0, _dy:CGFloat = 0.0
    var _vx:CGFloat = 0.0, _vy:CGFloat = 0.0
    let _ax:CGFloat = 2.0, _ay:CGFloat = -2.0
    var _timer:NSTimer? = nil
    var _timestamp:CGEventTimestamp = 0
    var _click_state:Int64 = 1
    var _statusItem: NSStatusItem!
    var _wokenupAt:EventTime = 0
    var _eventNumber:Int64 = 0
    var _moveU = false
    var _moveD = false
    var _moveL = false
    var _moveR = false

    override func awakeFromNib(){
        let bundle = NSBundle.mainBundle()
        let bundleID = bundle.bundleIdentifier
        let appURL = bundle.executableURL
        for app in NSWorkspace.sharedWorkspace().runningApplications {
            if(app.processIdentifier == _inputHook.pid){ continue }
            if(app.executableURL == appURL){ NSApp.terminate(self) }
            if(app.bundleIdentifier == bundleID){ NSApp.terminate(self) }
        }
        
        let statusBar = NSStatusBar.systemStatusBar()
        _statusItem = statusBar.statusItemWithLength(CGFloat(NSVariableStatusItemLength))
        let icon = NSImage(named:"Icon")!
        icon.template = true
        icon.resizingMode = .Stretch
        icon.size = NSSize(width: 16, height: 16)
        _statusItem.image = icon
        
        let menu = NSMenu()
        _statusItem.menu = menu
        
        /*let pref = NSMenuItem()
        pref.title = "Preferences"
        pref.action = Selector("config:")
        menu.addItem(pref)*/

        let quit = NSMenuItem()
        quit.title = "Quit"
        quit.action = #selector(AppDelegate.quit(_:))
        menu.addItem(quit)
    }
    /*
    @IBAction func config(sender: NSButton){
        NSApp.mainWindow?.makeKeyAndOrderFront(self)
    }*/
    
    @IBAction func quit(sender: NSButton) {
        NSApp.terminate(self)
    }
    
    func applicationDidFinishLaunching(aNotification: NSNotification) {
        // Insert code here to initialize your application
        _inputHook.delegate = self
        _inputHook.enable()        
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
        _inputHook.disable()
    }
    /*
    func applicationDidBecomeActive(notification: NSNotification) {
        _inputHook.disable()
        NSApp.activateIgnoringOtherApps(true)
        NSApp.mainWindow?.makeKeyAndOrderFront(self)
    }*/
    
    func applicationDidResignActive(notification: NSNotification) {
        _inputHook.enable()
    }
    func tick(){
        var displayID = CGMainDisplayID()
        var rect = CGDisplayBounds(displayID)
        var p = NSEvent.mouseLocation()
        var dx = _dx, dy = _dy
        
        // normalize deltas
        let s = sqrt(dx*dx + dy*dy);
        if(s < 0.5){
            _vx = 0
            _vy = 0
            return
        }
        dx /= s
        dy /= s
        
        // accelerate
        _vx += _ax*dx
        _vy += _ay*dy
        
        // slowdown
        _vx *= 0.8
        _vy *= 0.8
        
        var vx = _vx*_baseSpeed, vy = _vy*_baseSpeed
        if(_speedFaster){ vx *= 4; vy *= 4 }
        if(_speedFast){ vx *= 2; vy *= 2 }
        if(_speedSlow){ vx /= 2; vy /= 2 }
        if(_speedSlower){ vx /= 4; vy /= 4 }
        
        if(_inputHook.wheel){
            let wv = Int(vy*2), wh = Int(-vx*2)
            let event = VMCreateMouseWheelEvent(wv, wh)
            postEvent(event.takeUnretainedValue())
            event.release()
            return
        }

        // move
        var pos = CGPoint(x:p.x + vx, y:rect.size.height - p.y - vy);
        p.x += vx;
        p.y += vy;
        
        // check boundary
        var displayCount:UInt32 = 0;
        CGGetDisplaysWithPoint(pos, 1, &displayID, &displayCount);
        if (displayCount == 0) {
            CGGetDisplaysWithPoint(CGPointMake(p.x, p.y), 1, &displayID, &displayCount)
            rect = CGDisplayBounds(displayID)
            if (pos.x < rect.origin.x) {
                pos.x = rect.origin.x;
            } else if (pos.x > rect.origin.x + rect.size.width - 1) {
                pos.x = rect.origin.x + rect.size.width - 1;
            }
            if (pos.y < rect.origin.y) {
                pos.y = rect.origin.y;
            } else if (pos.y > rect.origin.y + rect.size.height - 1) {
                pos.y = rect.origin.y + rect.size.height - 1;
            }
        }
        
        // post event
        var button = CGMouseButton.Left;
        var type = CGEventType.MouseMoved;
        if(_leftButton){
            type = .LeftMouseDragged;
        }else if(_rightButton){
            type = .RightMouseDragged;
            button = .Right;
        }else if(_centerButton){
            type = .OtherMouseDragged;
            button = .Center;
        }
        let event = CGEventCreateMouseEvent(nil, type, pos, button)
        postEvent(event)
        
        _timestamp = 0
        _click_state = 1
    }
    private func withFlags(flags:CGEventFlags, fn:() -> Void){
        let oldFlags = NSEvent.modifierFlags()
        let event = CGEventCreate(nil)
        CGEventSetType(event, .FlagsChanged)
        CGEventSetFlags(event, flags)
        postEvent(event)
        fn()
        CGEventSetFlags(event, CGEventFlags(rawValue: UInt64(oldFlags.rawValue)))
        postEvent(event)
    }
    private func press(keycode:Int, _ flags: CGEventFlags...){
        let flag = CGEventFlags(rawValue: flags.reduce(0){$0 | $1.rawValue})
        withFlags(flag){
            for pressed in [true, false]{
                let event = CGEventCreateKeyboardEvent(nil, CGKeyCode(keycode), pressed)
                CGEventSetFlags(event, flag)
                self.postEvent(event)
            }
        }
    }
    private func doublePress(doubled: () -> Void, _ singled: () -> Void){
        let timestamp = UInt64(1000000000*GetCurrentEventTime())
        if(timestamp - _timestamp < 500000000){ doubled() }
        else{ singled() }
        _timestamp = timestamp
    }
    func click(type:CGEventType, _ button:CGMouseButton, _ pressed:Bool){
        let p = NSEvent.mouseLocation()
        var displayID:CGDirectDisplayID = 0
        var displayCount:CGDisplayCount = 0
        CGGetActiveDisplayList(1, &displayID, &displayCount)
        let rect = CGDisplayBounds(displayID)
        let pos = CGPointMake(p.x, rect.size.height - p.y)
        let event = CGEventCreateMouseEvent(nil, type, pos, button)
        if(pressed){
            doublePress({++self._click_state}, {self._click_state = 1})
            _eventNumber += 1
        }
        CGEventSetIntegerValueField(event, .MouseEventNumber, _eventNumber)
        CGEventSetIntegerValueField(event, .MouseEventClickState, _click_state)
        postEvent(event)
    }
    private func postEvent(event:CGEvent?){
        CGEventSetIntegerValueField(event, .EventSourceUnixProcessID, Int64(_inputHook.pid))
        CGEventPost(.CGHIDEventTap, event)
    }
    private func reset(){
        _dx = 0
        _dy = 0
        _timestamp = 0
        _click_state = 1
        _leftButton = false
        _rightButton = false
        _centerButton = false
        _speedFast = false
        _speedFaster = false
        _speedSlow = false
        _speedSlower = false
    }
    private func rawFlag(flag:CGEventFlags) -> UInt64 {return flag.rawValue}
    private func pressArrow(dx:Int, _ dy:Int, _ flags:CGEventFlags) {
        switch(dx, dy){
        case (-1, 0): press(kVK_LeftArrow, flags)
        case (1, 0): press(kVK_RightArrow, flags)
        case (0, 1): press(kVK_DownArrow, flags)
        case (0, -1): press(kVK_UpArrow, flags)
        default: break
        }
    }
    func move(dx: Int, _ dy: Int, _ flags: InputHook.Flags, _ pressed: Bool){
        switch(flags.tuple()){
        case (true, false, false, false, false):
            if(pressed && GetCurrentEventTime() - _wokenupAt >= 0.2){
                pressArrow(dx, dy, .MaskControl)
            }
            reset()
        case (true, true, false, true, false):
            if(pressed){pressArrow(dx, dy, .MaskCommand)}
        case (true, true, false, false, false):
            if(pressed){pressArrow(dx, dy, .MaskNonCoalesced)}
        default:
            switch(dx, dy){
            case (-1, 0): _moveL = pressed
            case (1, 0): _moveR = pressed
            case (0, -1): _moveU = pressed
            case (0, 1): _moveD = pressed
            default: break
            }
            _dx = (_moveR ? 1:0) - (_moveL ? 1:0)
            _dy = (_moveD ? 1:0) - (_moveU ? 1:0)
    //        if(pressed){ _dx += CGFloat(dx); _dy += CGFloat(dy) }
      //      else{ _dx -= CGFloat(dx); _dy -= CGFloat(dy) }
        }
    }
    private func enableMouseMode(){
        NSLog("mouse mode enabled")
        let op = NSBlockOperation(){self.tick()}
        _timer = NSTimer.scheduledTimerWithTimeInterval(0.015, target: op,
            selector: #selector(NSOperation.main), userInfo: nil, repeats: true)
        _statusItem.button!.highlighted = true
        _wokenupAt = GetCurrentEventTime()
        reset()
    }
    private func disableMouseMode(){
        _timer!.invalidate()
        _timer = nil
        reset()
        NSLog("mouse mode disabled")
        _statusItem.button!.highlighted = false
    }
    func handleInput(keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool{
        if(_timer != nil){
            if(flags.cmd){return false}
            switch(Int(keycode)){
            case kVK_ANSI_I: if(!pressed){ disableMouseMode() }
            case kVK_ANSI_G: _inputHook.wheel = pressed
            case kVK_ANSI_H: move(-1, 0, flags, pressed)
            case kVK_ANSI_J: move(0, 1, flags, pressed)
            case kVK_ANSI_K: move(0, -1, flags, pressed)
            case kVK_ANSI_L: move(1, 0, flags, pressed)
            case kVK_ANSI_A: _speedSlower = pressed
            case kVK_ANSI_S: _speedSlow = pressed
            case kVK_ANSI_D: _speedFast = pressed
            case kVK_ANSI_F: _speedFaster = pressed
            case kVK_Space:
                if(flags.ctrl){return false}
                _leftButton = pressed
                click(pressed ? .LeftMouseDown : .LeftMouseUp, .Left, pressed)
            case kVK_ANSI_Semicolon:
                if(!flags.ctrl){
                    _rightButton = pressed
                    click(pressed ? .RightMouseDown : .RightMouseUp, .Right, pressed)
                }
            case kVK_ANSI_N:
                _centerButton = pressed
                click(pressed ? .OtherMouseDown : .OtherMouseUp, .Center, pressed)
            case kVK_ANSI_Y: if(pressed){ press(kVK_ANSI_C, .MaskCommand) }
            case kVK_ANSI_P: if(pressed){ press(kVK_ANSI_V, .MaskCommand) }
            case kVK_ANSI_X: if(pressed){ press(kVK_ANSI_X, .MaskCommand) }
            case kVK_ANSI_R:
                if(!pressed){
                    if(flags.ctrl){press(kVK_ANSI_Z, .MaskCommand, .MaskShift)}
                    else{press(kVK_ANSI_R, .MaskCommand)}
                }
            case kVK_ANSI_U: if(pressed){ press(kVK_ANSI_Z, .MaskCommand) }
            case kVK_ANSI_Slash:
                if(pressed){ press(kVK_ANSI_F, .MaskCommand) }
                else{ disableMouseMode() }
            case kVK_JIS_Kana, kVK_JIS_Eisu:
                if(!pressed){ disableMouseMode() }
                return false
            default: return false
            }
            return true
        }else{
            switch(Int(keycode), flags.ctrl, flags.shift, flags.opt, flags.cmd){
            case (kVK_ANSI_Semicolon, true, false, false, false): if(!pressed){enableMouseMode()}
            case (kVK_ANSI_H, true, true, false, false): if(!pressed){press(kVK_LeftArrow)}
            case (kVK_ANSI_L, true, true, false, false): if(!pressed){press(kVK_RightArrow)}
            case (kVK_ANSI_J, true, true, false, false): if(!pressed){press(kVK_DownArrow)}
            case (kVK_ANSI_K, true, true, false, false): if(!pressed){press(kVK_UpArrow)}
            default: return false
            }
            return true
        }
    }
}

