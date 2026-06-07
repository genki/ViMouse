//
//  AppDelegate.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/19.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import CoreGraphics

@main
class AppDelegate: NSObject, NSApplicationDelegate, InputHookDelegate {
    var _inputHook = InputHook()
    var _speedSlower = false
    var _speedSlow = false
    var _speedFast = false
    var _speedFaster = false
    var _leftButton = false
    var _rightButton = false
    var _centerButton = false
    var _dx:CGFloat = 0.0, _dy:CGFloat = 0.0
    var _vx:CGFloat = 0.0, _vy:CGFloat = 0.0
    var _timer:Timer? = nil
    var _timestamp:CGEventTimestamp = 0
    var _click_state:Int64 = 1
    var _statusItem: NSStatusItem!
    var _wokenupAt:EventTime = 0
    var _eventNumber:Int64 = 0
    var _normalIcon:NSImage
    var _activeIcon:NSImage
    var _moveU = false
    var _moveD = false
    var _moveL = false
    var _moveR = false
    var _settingsWindowController: SettingsWindowController?
    
    override init() {
        let size = NSSize(width: 16, height: 16)
        _normalIcon = NSImage(named: NSImage.Name("MenuBarIcon"))!
        _normalIcon.isTemplate = true
        _normalIcon.resizingMode = .stretch
        _normalIcon.size = size
        
        _activeIcon = AppDelegate.activeStatusIcon(from: _normalIcon, iconSize: size)
        _activeIcon.isTemplate = false
    }

    private static func activeStatusIcon(from icon: NSImage, iconSize: NSSize) -> NSImage {
        let canvasSize = NSSize(width: 34, height: 24)
        let image = NSImage(size: canvasSize)
        let backgroundRect = NSRect(x: 1, y: 1, width: 32, height: 22)
        let iconRect = NSRect(
            x: (canvasSize.width - iconSize.width) / 2,
            y: (canvasSize.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )

        image.lockFocus()
        NSColor(calibratedRed: 0.0, green: 0.36, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 7, yRadius: 7).fill()

        let whiteIcon = icon.copy() as? NSImage ?? icon
        whiteIcon.size = iconSize
        whiteIcon.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: iconSize).fill(using: .sourceAtop)
        whiteIcon.unlockFocus()
        whiteIcon.draw(in: iconRect, from: NSRect(origin: .zero, size: iconSize), operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        return image
    }

    override func awakeFromNib() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier
        let appURL = bundle.executableURL
        for app in NSWorkspace.shared.runningApplications {
            if(app.processIdentifier == _inputHook.pid) { continue }
            if(app.executableURL == appURL) { app.terminate() }
            if(app.bundleIdentifier == bundleID) { app.terminate() }
        }
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !accessEnabled {
            print("Access Not Enabled")
            NSApp.terminate(self)
        }
        
        let statusBar = NSStatusBar.system
        _statusItem = statusBar.statusItem(withLength: 34)
        _statusItem.image = _normalIcon
        
        let menu = NSMenu()
        _statusItem.menu = menu
        
        let settings = NSMenuItem()
        settings.title = localized("menu.settings")
        settings.action = #selector(AppDelegate.showSettings(_:))
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem()
        quit.title = localized("menu.quit")
        quit.action = #selector(AppDelegate.quit(_:))
        menu.addItem(quit)
    }
    /*
    @IBAction func config(sender: NSButton){
        NSApp.mainWindow?.makeKeyAndOrderFront(self)
    }*/
    
    @IBAction func quit(_ sender: NSButton) {
        NSApp.terminate(self)
    }

    @IBAction func showSettings(_ sender: Any) {
        if _settingsWindowController == nil {
            _settingsWindowController = SettingsWindowController()
        }

        guard let window = _settingsWindowController?.window else { return }
        _settingsWindowController?.reloadControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(sender)
        NSApp.runModal(for: window)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        _inputHook.delegate = self
        _inputHook.enable()
        if ProcessInfo.processInfo.environment["VIMOUSE_SHOW_SETTINGS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async {
                self.showSettings(self)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        _inputHook.disable()
    }
    /*
    func applicationDidBecomeActive(notification: NSNotification) {
        _inputHook.disable()
        NSApp.activateIgnoringOtherApps(true)
        NSApp.mainWindow?.makeKeyAndOrderFront(self)
    }*/
    
    func applicationDidResignActive(_ notification: Notification) {
        _inputHook.enable()
    }
    func tick() {
        let current = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        var dx = _dx, dy = _dy
        
        // normalize deltas
        let s = sqrt(dx*dx + dy*dy)
        if(s < 0.5) {
            _vx = 0
            _vy = 0
            return
        }
        dx /= s
        dy /= s
        
        // accelerate
        let acceleration = CGFloat(MovementSettings.acceleration)
        _vx += acceleration*dx
        _vy -= acceleration*dy
        
        // slowdown
        let damping = CGFloat(MovementSettings.damping)
        _vx *= damping
        _vy *= damping
        
        let baseSpeed = CGFloat(MovementSettings.baseSpeed)
        var vx = _vx*baseSpeed, vy = _vy*baseSpeed
        if(_speedFaster){ vx *= 4; vy *= 4 }
        if(_speedFast){ vx *= 2; vy *= 2 }
        if(_speedSlow){ vx /= 2; vy /= 2 }
        if(_speedSlower){ vx /= 4; vy /= 4 }
        
        if(_inputHook.wheel) {
            let wv = Int(vy*2), wh = Int(-vx*2)
            let event = VMCreateMouseWheelEvent(wv, wh)
            postEvent(event?.takeUnretainedValue())
            event?.release()
            return
        }

        // move
        let delta = CGVector(dx: vx, dy: -vy)
        let pos = MouseMovementBounds.nextPosition(
            current: current,
            delta: delta,
            displays: MouseMovementBounds.activeDisplays()
        )
        
        // post event
        var button = CGMouseButton.left
        var type = CGEventType.mouseMoved
        if(_leftButton) {
            type = .leftMouseDragged
        } else if(_rightButton) {
            type = .rightMouseDragged
            button = .right
        } else if(_centerButton) {
            type = .otherMouseDragged
            button = .center
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: button)
        postEvent(event)
        
        _timestamp = 0
        _click_state = 1
    }
    fileprivate func withFlags(_ flags:CGEventFlags, fn:() -> Void){
        let oldFlags = NSEvent.modifierFlags
        let event = CGEvent(source: nil)
        event?.type = .flagsChanged
        event?.flags = flags
        postEvent(event)
        fn()
        event?.flags = CGEventFlags(rawValue: UInt64(oldFlags.rawValue))
        postEvent(event)
    }
    fileprivate func press(_ keycode:Int, _ flags: CGEventFlags...){
        let flag = CGEventFlags(rawValue: flags.reduce(0){$0 | $1.rawValue})
        withFlags(flag){
            for pressed in [true, false]{
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keycode), keyDown: pressed)
                event?.flags = flag
                self.postEvent(event)
            }
        }
    }
    fileprivate func doublePress(_ doubled: () -> Void, _ singled: () -> Void){
        let timestamp = UInt64(1000000000*GetCurrentEventTime())
        if(timestamp - _timestamp < 500000000){ doubled() }
        else{ singled() }
        _timestamp = timestamp
    }
    func click(_ type:CGEventType, _ button:CGMouseButton, _ pressed:Bool){
        guard let locationEvent = CGEvent(source: nil) else { return }
        let pos = locationEvent.location
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: button)
        if(pressed){
            doublePress({self._click_state += 1}, {self._click_state = 1})
            _eventNumber += 1
        }
        event?.setIntegerValueField(.mouseEventNumber, value: _eventNumber)
        event?.setIntegerValueField(.mouseEventClickState, value: _click_state)
        postEvent(event)
    }
    fileprivate func postEvent(_ event:CGEvent?){
        event?.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(_inputHook.pid))
        event?.post(tap: .cghidEventTap)
    }
    fileprivate func reset(){
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
        _inputHook.wheel = false
    }
    fileprivate func rawFlag(_ flag:CGEventFlags) -> UInt64 {return flag.rawValue}
    fileprivate func pressArrow(_ dx:Int, _ dy:Int, _ flags:CGEventFlags) {
        switch(dx, dy){
        case (-1, 0): press(kVK_LeftArrow, flags)
        case (1, 0): press(kVK_RightArrow, flags)
        case (0, 1): press(kVK_DownArrow, flags)
        case (0, -1): press(kVK_UpArrow, flags)
        default: break
        }
    }
    func runMissionControl(_ args:[String]){
        let task = Process()
        task.launchPath = "/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        task.arguments = args
        task.launch()
    }
    func move(_ dx: Int, _ dy: Int, _ flags: InputHook.Flags, _ pressed: Bool){
        switch(flags.tuple()){
        //   (ctrl, shift, opt  , cmd  , fnc  , wheel)
        case (true, false, false, false, false, false):
            if(pressed && GetCurrentEventTime() - _wokenupAt >= 0.2){
                pressArrow(dx, dy, .maskControl)
                /*switch(dx,dy){
                case (0, -1):
                    press(kVK_Tab, CGEventFlags(rawValue:CGEventFlags.MaskControl.rawValue | CGEventFlags.MaskShift.rawValue))
                case (0, 1): press(kVK_Tab, .MaskControl)
                default: break
                }*/
                /*switch(dx, dy){
                case (-1, 0): spaces_movetospace(-1)
                case(1, 0): spaces_movetospace(1)
                case (0, 1): runMissionControl(["2"])
                case (0, -1): runMissionControl(["3"])
                default: break
                }*/
            }
            reset()
        case (true, true, false, true, false, false):
            if(pressed){pressArrow(dx, dy, .maskCommand)}
        //case (true, false, false, true, false):
        //    if(pressed){pressArrow(dx, dy, .MaskNonCoalesced)}
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
    fileprivate func enableMouseMode(){
        NSLog("mouse mode enabled")
        let op = BlockOperation(){self.tick()}
        _timer = MouseModeScheduler.scheduleTimer(
            timeInterval: 0.015,
            target: op,
            selector: #selector(Operation.main)
        )
        _statusItem.image = _activeIcon
        _wokenupAt = GetCurrentEventTime()
        reset()
    }
    fileprivate func disableMouseMode(){
        _timer!.invalidate()
        _timer = nil
        reset()
        NSLog("mouse mode disabled")
        _statusItem.image = _normalIcon
    }
    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool{
        let key = Int(keycode)
        if(_timer != nil){
            // mouse mode
            if(flags.cmd){return false}
            if(flags.ctrl && flags.shift){return false}
            switch key {
            case KeyMapping.keyCode(for: .exitMouseMode): if(!pressed){ disableMouseMode() }
            case KeyMapping.keyCode(for: .wheel): _inputHook.wheel = pressed
            case KeyMapping.keyCode(for: .moveLeft): move(-1, 0, flags, pressed)
            case KeyMapping.keyCode(for: .moveDown): move(0, 1, flags, pressed)
            case KeyMapping.keyCode(for: .moveUp): move(0, -1, flags, pressed)
            case KeyMapping.keyCode(for: .moveRight): move(1, 0, flags, pressed)
            case KeyMapping.keyCode(for: .verySlow): _speedSlower = pressed
            case KeyMapping.keyCode(for: .slow): _speedSlow = pressed
            case KeyMapping.keyCode(for: .fast): _speedFast = pressed
            case KeyMapping.keyCode(for: .veryFast): _speedFaster = pressed
            case KeyMapping.keyCode(for: .leftClick):
                if(flags.ctrl){return false}
                _leftButton = pressed
                click(pressed ? .leftMouseDown : .leftMouseUp, .left, pressed)
            case KeyMapping.keyCode(for: .rightClick):
                if(!flags.ctrl){
                    _rightButton = pressed
                    click(pressed ? .rightMouseDown : .rightMouseUp, .right, pressed)
                }
            case KeyMapping.keyCode(for: .middleClick):
                _centerButton = pressed
                click(pressed ? .otherMouseDown : .otherMouseUp, .center, pressed)
            case KeyMapping.keyCode(for: .yank): if(pressed){ press(kVK_ANSI_C, .maskCommand) }
            case KeyMapping.keyCode(for: .paste): if(pressed){ press(kVK_ANSI_V, .maskCommand) }
            case KeyMapping.keyCode(for: .cut): if(pressed){ press(kVK_ANSI_X, .maskCommand) }
            case KeyMapping.keyCode(for: .reload):
                if(!pressed){
                    if(flags.ctrl){press(kVK_ANSI_Z, .maskCommand, .maskShift)}
                    else{press(kVK_ANSI_R, .maskCommand)}
                }
            case KeyMapping.keyCode(for: .undo): if(pressed){ press(kVK_ANSI_Z, .maskCommand) }
            case KeyMapping.keyCode(for: .find):
                if(pressed){ press(kVK_ANSI_F, .maskCommand) }
                else{ disableMouseMode() }
            case kVK_JIS_Kana, kVK_JIS_Eisu:
                if(!pressed){ disableMouseMode() }
                return false
            default: return false
            }
            return true
        }else{
            // keyboard mode
            switch(key, flags.ctrl, flags.shift, flags.opt, flags.cmd, flags.fnc){
            case (KeyMapping.keyCode(for: .enterMouseMode), true, false, false, false, false): fallthrough
            case (KeyMapping.keyCode(for: .enterMouseMode), false, false, false, false, true):
                if(!pressed){enableMouseMode()}
            case (KeyMapping.keyCode(for: .moveLeft), true, true, false, false, false):
                if(!pressed){press(kVK_LeftArrow)}
            case (KeyMapping.keyCode(for: .moveRight), true, true, false, false, false): if(!pressed){press(kVK_RightArrow)}
            case (KeyMapping.keyCode(for: .moveDown), true, true, false, false, false): if(!pressed){press(kVK_DownArrow)}
            case (KeyMapping.keyCode(for: .moveUp), true, true, false, false, false): if(!pressed){press(kVK_UpArrow)}
            default: return false
            }
            return true
        }
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
