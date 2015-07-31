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
    var _wheelMode = false
    var _speedSlower = false
    var _speedSlow = false
    var _speedFast = false
    var _speedFaster = false
    var _leftButton = false
    var _rightButton = false
    var _centerButton = false
    var _dx:CGFloat = 0.0, _dy:CGFloat = 0.0
    var _vx:CGFloat = 0.0, _vy:CGFloat = 0.0
    var _ax:CGFloat = 2.0, _ay:CGFloat = -2.0
    var _timer:NSTimer? = nil
    var _timestamp:CGEventTimestamp = 0
    var _click_state:Int64 = 1
    var _statusItem: NSStatusItem!
    var _wokenupAt:EventTime = 0

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
        
        //_statusItem.title = "ViMouse"
        _statusItem.image = icon
        //_statusItem.target = self
        //_statusItem.action = Selector("open:")
    }
    
    func applicationDidFinishLaunching(aNotification: NSNotification) {
        // Insert code here to initialize your application
        _inputHook.delegate = self
        _inputHook.enable()        
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }

    // MARK: - Core Data stack

    lazy var applicationDocumentsDirectory: NSURL = {
        // The directory the application uses to store the Core Data store file. This code uses a directory named "com.s21g.ViMouse" in the user's Application Support directory.
        let urls = NSFileManager.defaultManager().URLsForDirectory(.ApplicationSupportDirectory, inDomains: .UserDomainMask)
        let appSupportURL = urls[urls.count - 1]
        return appSupportURL.URLByAppendingPathComponent("com.s21g.ViMouse")
    }()

    lazy var managedObjectModel: NSManagedObjectModel = {
        // The managed object model for the application. This property is not optional. It is a fatal error for the application not to be able to find and load its model.
        let modelURL = NSBundle.mainBundle().URLForResource("ViMouse", withExtension: "momd")!
        return NSManagedObjectModel(contentsOfURL: modelURL)!
    }()

    lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator = {
        // The persistent store coordinator for the application. This implementation creates and returns a coordinator, having added the store for the application to it. (The directory for the store is created, if necessary.) This property is optional since there are legitimate error conditions that could cause the creation of the store to fail.
        let fileManager = NSFileManager.defaultManager()
        var failError: NSError? = nil
        var shouldFail = false
        var failureReason = "There was an error creating or loading the application's saved data."

        // Make sure the application files directory is there
        do {
            let properties = try self.applicationDocumentsDirectory.resourceValuesForKeys([NSURLIsDirectoryKey])
            if !properties[NSURLIsDirectoryKey]!.boolValue {
                failureReason = "Expected a folder to store application data, found a file \(self.applicationDocumentsDirectory.path)."
                shouldFail = true
            }
        } catch  {
            let nserror = error as NSError
            if nserror.code == NSFileReadNoSuchFileError {
                do {
                    try fileManager.createDirectoryAtPath(self.applicationDocumentsDirectory.path!, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    failError = nserror
                }
            } else {
                failError = nserror
            }
        }
        
        // Create the coordinator and store
        var coordinator: NSPersistentStoreCoordinator? = nil
        if failError == nil {
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
            let url = self.applicationDocumentsDirectory.URLByAppendingPathComponent("CocoaAppCD.storedata")
            do {
                try coordinator!.addPersistentStoreWithType(NSXMLStoreType, configuration: nil, URL: url, options: nil)
            } catch {
                failError = error as NSError
            }
        }
        
        if shouldFail || (failError != nil) {
            // Report any error we got.
            var dict = [String: AnyObject]()
            dict[NSLocalizedDescriptionKey] = "Failed to initialize the application's saved data"
            dict[NSLocalizedFailureReasonErrorKey] = failureReason
            if failError != nil {
                dict[NSUnderlyingErrorKey] = failError
            }
            let error = NSError(domain: "YOUR_ERROR_DOMAIN", code: 9999, userInfo: dict)
            NSApplication.sharedApplication().presentError(error)
            abort()
        } else {
            return coordinator!
        }
    }()

    lazy var managedObjectContext: NSManagedObjectContext = {
        // Returns the managed object context for the application (which is already bound to the persistent store coordinator for the application.) This property is optional since there are legitimate error conditions that could cause the creation of the context to fail.
        let coordinator = self.persistentStoreCoordinator
        var managedObjectContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        managedObjectContext.persistentStoreCoordinator = coordinator
        return managedObjectContext
    }()

    // MARK: - Core Data Saving and Undo support

    @IBAction func saveAction(sender: AnyObject!) {
        // Performs the save action for the application, which is to send the save: message to the application's managed object context. Any encountered errors are presented to the user.
        if !managedObjectContext.commitEditing() {
            NSLog("\(NSStringFromClass(self.dynamicType)) unable to commit editing before saving")
        }
        if managedObjectContext.hasChanges {
            do {
                try managedObjectContext.save()
            } catch {
                let nserror = error as NSError
                NSApplication.sharedApplication().presentError(nserror)
            }
        }
    }

    func windowWillReturnUndoManager(window: NSWindow) -> NSUndoManager? {
        // Returns the NSUndoManager for the application. In this case, the manager returned is that of the managed object context for the application.
        return managedObjectContext.undoManager
    }

    func applicationShouldTerminate(sender: NSApplication) -> NSApplicationTerminateReply {
        // Save changes in the application's managed object context before the application terminates.
        
        if !managedObjectContext.commitEditing() {
            NSLog("\(NSStringFromClass(self.dynamicType)) unable to commit editing to terminate")
            return .TerminateCancel
        }
        
        if !managedObjectContext.hasChanges {
            return .TerminateNow
        }
        
        do {
            try managedObjectContext.save()
        } catch {
            let nserror = error as NSError
            // Customize this code block to include application-specific recovery steps.
            let result = sender.presentError(nserror)
            if (result) {
                return .TerminateCancel
            }
            
            let question = NSLocalizedString("Could not save changes while quitting. Quit anyway?", comment: "Quit without saves error question message")
            let info = NSLocalizedString("Quitting now will lose any changes you have made since the last successful save", comment: "Quit without saves error question info");
            let quitButton = NSLocalizedString("Quit anyway", comment: "Quit anyway button title")
            let cancelButton = NSLocalizedString("Cancel", comment: "Cancel button title")
            let alert = NSAlert()
            alert.messageText = question
            alert.informativeText = info
            alert.addButtonWithTitle(quitButton)
            alert.addButtonWithTitle(cancelButton)
            
            let answer = alert.runModal()
            if answer == NSAlertFirstButtonReturn {
                return .TerminateCancel
            }
        }
        // If we got here, it is time to quit.
        return .TerminateNow
    }

    func applicationDidBecomeActive(notification: NSNotification) {
        _inputHook.disable()
        NSApp.activateIgnoringOtherApps(true)
        NSApp.mainWindow?.makeKeyAndOrderFront(self)
    }
    
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
        
        var vx = _vx, vy = _vy
        if(_speedFaster){ vx *= 4; vy *= 4 }
        if(_speedFast){ vx *= 2; vy *= 2 }
        if(_speedSlow){ vx /= 2; vy /= 2 }
        if(_speedSlower){ vx /= 4; vy /= 4 }
        
        if(_wheelMode){
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
    private func press(keycode:Int, _ flags: CGEventFlags...){
        let flag = CGEventFlags(rawValue: flags.reduce(0){$0 | $1.rawValue})!
        for pressed in [true, false]{
            let event = CGEventCreateKeyboardEvent(nil, CGKeyCode(keycode), pressed)
            CGEventSetFlags(event, flag)
            postEvent(event)
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
        }
        CGEventSetIntegerValueField(event, .MouseEventNumber, _click_state)
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
    func move(dx: Int, _ dy: Int, _ flags: CGEventFlags, _ pressed: Bool){
        let ctrl = (flags.rawValue & rawFlag(.FlagMaskControl)) != 0
        let shift = (flags.rawValue & rawFlag(.FlagMaskShift)) != 0
        let opt = (flags.rawValue & rawFlag(.FlagMaskAlternate)) != 0
        let cmd = (flags.rawValue & rawFlag(.FlagMaskCommand)) != 0
        switch(ctrl, shift, opt, cmd, _wheelMode){
        case (true, false, false, false, false):
            if(pressed && GetCurrentEventTime() - _wokenupAt >= 0.5){
                pressArrow(dx, dy, .FlagMaskControl)
            }
            reset()
        case (true, true, false, true, false):
            if(pressed){pressArrow(dx, dy, .FlagMaskCommand)}
        case (true, true, false, false, false):
            if(pressed){ pressArrow(dx, dy, .FlagMaskNonCoalesced) }
        default:
            if(pressed){ _dx += CGFloat(dx); _dy += CGFloat(dy) }
            else{ _dx -= CGFloat(dx); _dy -= CGFloat(dy) }
        }
    }
    private func enableMouseMode(){
        NSLog("mouse mode enabled")
        let op = NSBlockOperation(){self.tick()}
        _timer = NSTimer.scheduledTimerWithTimeInterval(0.015, target: op,
            selector: "main", userInfo: nil, repeats: true)
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
    func handleInput(keycode: Int64, _ flags: CGEventFlags, _ pressed: Bool) -> Bool{
        let ctrl = flags.rawValue & rawFlag(.FlagMaskControl) != 0
        let shift = (flags.rawValue & rawFlag(.FlagMaskShift)) != 0
        let opt = (flags.rawValue & rawFlag(.FlagMaskAlternate)) != 0
        let cmd = (flags.rawValue & rawFlag(.FlagMaskCommand)) != 0
        if(_timer != nil){
            switch(Int(keycode)){
            case kVK_ANSI_I:
                if(!pressed){
                    click(.LeftMouseDown, .Left, true)
                    click(.LeftMouseUp, .Left, false)
                    disableMouseMode()
                }
            case kVK_ANSI_O: if(!pressed){ disableMouseMode() }
            case kVK_ANSI_G: self._wheelMode = pressed
            case kVK_ANSI_H: move(-1, 0, flags, pressed)
            case kVK_ANSI_J: move(0, 1, flags, pressed)
            case kVK_ANSI_K: move(0, -1, flags, pressed)
            case kVK_ANSI_L: move(1, 0, flags, pressed)
            case kVK_ANSI_A: _speedSlower = pressed
            case kVK_ANSI_S: _speedSlow = pressed
            case kVK_ANSI_D: _speedFast = pressed
            case kVK_ANSI_F: _speedFaster = pressed
            case kVK_Space:
                _leftButton = pressed
                click(pressed ? .LeftMouseDown : .LeftMouseUp, .Left, pressed)
            case kVK_ANSI_Semicolon:
                if(!ctrl){
                    _rightButton = pressed
                    click(pressed ? .RightMouseDown : .RightMouseUp, .Right, pressed)
                }
            case kVK_ANSI_N:
                _centerButton = pressed
                click(pressed ? .OtherMouseDown : .OtherMouseUp, .Center, pressed)
            case kVK_ANSI_Y: if(pressed){ press(kVK_ANSI_C, .FlagMaskCommand) }
            case kVK_ANSI_P: if(pressed){ press(kVK_ANSI_V, .FlagMaskCommand) }
            case kVK_ANSI_X: if(pressed){ press(kVK_ANSI_X, .FlagMaskCommand) }
            case kVK_ANSI_R:
                if(pressed){
                    if(ctrl){press(kVK_ANSI_Z, .FlagMaskCommand, .FlagMaskShift)}
                    else{press(kVK_ANSI_R, .FlagMaskCommand)}
                }
            case kVK_ANSI_U: if(pressed){ press(kVK_ANSI_Z, .FlagMaskCommand) }
            case kVK_ANSI_Slash: if(pressed){ press(kVK_ANSI_F, .FlagMaskCommand) }
            case kVK_JIS_Kana, kVK_JIS_Eisu:
                if(!pressed){ disableMouseMode() }
                return false
            default: return false
            }
            return true
        }else{
            switch(Int(keycode)){
            case kVK_ANSI_Semicolon:
                if(ctrl && !shift && !opt && !cmd){
                    if(!pressed){enableMouseMode()}
                    return true
                }
            default: break
            }
            return false
        }
    }
}

