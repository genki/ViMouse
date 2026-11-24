//
//  AppDelegate.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/19.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa
import Carbon
import CoreGraphics

private enum MissionControlMode: Int {
    case allWindows = 0
    case showDesktop = 1
    case frontApplicationWindows = 2
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, InputHookDelegate {
    var _inputHook = InputHook()
    var _speedSlower = false
    var _speedSlow = false
    var _speedFast = false
    var _speedFaster = false
    private var _windowNavigationLeaderPressed = false
    private var trackpadEdgeSwipeSession: TrackpadEdgeSwipeSession?
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
    private var remoteAgentMenuItem: NSMenuItem?
    private var inputStatusMenuItem: NSMenuItem?
    var _selfConversionWindowController: SelfConversionWindowController?
    var _selfConversionMenuItem: NSMenuItem?
    private var voiceInputController: AnyObject?
    private var voiceKeysDown = Set<Int>()
    private var voiceStatusReset: DispatchWorkItem?
    var _selfConversionStartKeyReleaseFilter = SelfConversionStartKeyReleaseFilter()
    private var _cursorRippleController: CursorRippleController?
    private var cursorShakeMonitor: CursorShakeMonitor?
    let _selfConversionDecisionClient = JapaneseConversionClient()
    
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

        AutoLaunchManager.shared.enable()

        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier
        let appURL = bundle.executableURL
        for app in NSWorkspace.shared.runningApplications {
            if(app.processIdentifier == _inputHook.pid) { continue }
            if(app.executableURL == appURL) { app.terminate() }
            if(app.bundleIdentifier == bundleID) { app.terminate() }
        }
        
        let statusBar = NSStatusBar.system
        _statusItem = statusBar.statusItem(withLength: 34)
        _statusItem.image = _normalIcon
        
        let menu = NSMenu()
        _statusItem.menu = menu

        let selfConversion = NSMenuItem()
        selfConversion.title = localized("menu.selfConversion")
        selfConversion.action = #selector(AppDelegate.toggleSelfConversion(_:))
        selfConversion.target = self
        selfConversion.state = SelfConversionSettings.enabled ? .on : .off
        _selfConversionMenuItem = selfConversion
        menu.addItem(selfConversion)

        let remoteAgent = NSMenuItem(title: localized("agent.menu"), action: #selector(toggleRemoteAgent(_:)), keyEquivalent: "")
        remoteAgent.target = self
        remoteAgentMenuItem = remoteAgent
        menu.addItem(remoteAgent)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteAgentChanged(_:)), name: RemoteAgentAPI.changed, object: nil)
        RemoteAgentAPI.shared.restore()

        let settings = NSMenuItem()
        settings.title = localized("menu.settings")
        settings.action = #selector(AppDelegate.showSettings(_:))
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())

        let inputStatus = NSMenuItem(title: localized("input.status.disabled"), action: nil, keyEquivalent: "")
        inputStatus.isEnabled = false
        inputStatusMenuItem = inputStatus
        menu.addItem(inputStatus)
        _inputHook.onStatusChange = { [weak self] status in self?.updateInputStatus(status) }
        let reconnect = NSMenuItem(title: localized("input.reconnect"), action: #selector(reconnectInput(_:)), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)
        let accessibility = NSMenuItem(title: localized("input.openAccessibility"), action: #selector(openAccessibility(_:)), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        let monitoring = NSMenuItem(title: localized("input.openMonitoring"), action: #selector(openInputMonitoring(_:)), keyEquivalent: "")
        monitoring.target = self
        menu.addItem(monitoring)
        menu.addItem(NSMenuItem.separator())

        let version = NSMenuItem()
        version.title = AppDelegate.versionMenuTitle()
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem()
        quit.title = localized("menu.quit")
        quit.action = #selector(AppDelegate.quit(_:))
        menu.addItem(quit)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(AppDelegate.selfConversionSettingsChanged(_:)),
            name: SelfConversionSettings.changedNotification,
            object: nil
        )
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
    }

    @objc func toggleSelfConversion(_ sender: NSMenuItem) {
        setSelfConversionEnabled(!SelfConversionSettings.enabled, settingsSender: sender)
    }

    @objc private func toggleRemoteAgent(_ sender: NSMenuItem) {
        RemoteAgentAPI.shared.setEnabled(!RemoteAgentAPI.shared.enabled)
    }

    @objc private func remoteAgentChanged(_ notification: Notification) {
        remoteAgentMenuItem?.state = RemoteAgentAPI.shared.enabled ? .on : .off
    }

    private func updateInputStatus(_ status: InputHook.Status) {
        let key: String
        switch status {
        case .disabled: key = "input.status.disabled"
        case .running: key = "input.status.running"
        case .accessibilityRequired: key = "input.status.accessibilityRequired"
        case .inputMonitoringRequired: key = "input.status.monitoringRequired"
        case .secureInput: key = "input.status.secureInput"
        case .unavailable: key = "input.status.unavailable"
        }
        inputStatusMenuItem?.title = localized(key)
    }

    @objc private func reconnectInput(_ sender: Any) { _inputHook.reconnect() }

    @objc private func openAccessibility(_ sender: Any) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoring(_ sender: Any) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func inputHookDidReset() {
        // 監視中断時にキーの離し忘れを残さず、モード切替のkeyupも合成しない。
        if _leftButton { click(.leftMouseUp, .left, false) }
        if _rightButton { click(.rightMouseUp, .right, false) }
        if _centerButton { click(.otherMouseUp, .center, false) }
        // 変換途中の文字列は保持し、監視復帰後に編集・確定できるようにする。
        _selfConversionStartKeyReleaseFilter = SelfConversionStartKeyReleaseFilter()
        voiceKeysDown.removeAll()
        if #available(macOS 26.0, *) {
            MainActor.assumeIsolated { (voiceInputController as? VoiceInput)?.cancel() }
        }
        disableMouseMode()
    }

    fileprivate func setSelfConversionEnabled(_ enabled: Bool, settingsSender: Any) {
        guard enabled else {
            SelfConversionSettings.enabled = false
            return
        }

        guard SelfConversionSettings.hasConversionBackend else {
            SelfConversionSettings.enabled = false
            showSettings(settingsSender)
            return
        }

        SelfConversionSettings.enabled = true
    }

    @objc func selfConversionSettingsChanged(_ notification: Notification) {
        _selfConversionMenuItem?.state = SelfConversionSettings.enabled ? .on : .off
        if !SelfConversionSettings.enabled, let controller = _selfConversionWindowController, controller.isActive {
            runSelfConversionUI { controller.cancel() }
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        _cursorRippleController = CursorRippleController()
        let shakeMonitor = CursorShakeMonitor { [weak self] point in
            self?._cursorRippleController?.show(at: point)
        }
        cursorShakeMonitor = shakeMonitor
        shakeMonitor.start()
        startTrackpadEdgeSwipes()
        _inputHook.delegate = self
        _inputHook.enable()
        if ProcessInfo.processInfo.environment["VIMOUSE_SHOW_SETTINGS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async {
                self.showSettings(self)
            }
        }
        if ProcessInfo.processInfo.environment["VIMOUSE_SHOW_SELF_CONVERSION_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let controller = self.selfConversionWindowController()
                controller.begin()
                controller.append("korehahenkanmodedesu")
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        RemoteAgentAPI.shared.stop()
        // Insert code here to tear down your application
        stopTrackpadEdgeSwipes()
        cursorShakeMonitor?.stop()
        _cursorRippleController?.hide()
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
    func postText(_ text: String) {
        for character in text.map(String.init) {
            postUnicodeString(character)
        }
    }

    private func postUnicodeString(_ text: String) {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }

        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: pressed)
            units.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            postEvent(event)
        }
    }
    fileprivate func reset(){
        // A key-up may be consumed by conversion/keyboard mode after a switch.
        // Clear the held-direction state as well as its derived deltas, so a
        // later movement key cannot revive a direction from the previous mode.
        _moveL = false
        _moveR = false
        _moveU = false
        _moveD = false
        _dx = 0
        _dy = 0
        _vx = 0
        _vy = 0
        _timestamp = 0
        _click_state = 1
        _leftButton = false
        _rightButton = false
        _centerButton = false
        _speedFast = false
        _speedFaster = false
        _speedSlow = false
        _speedSlower = false
        _windowNavigationLeaderPressed = false
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
        guard _timer == nil else { return }
        reset()
        NSLog("mouse mode enabled")
        _cursorRippleController?.hide()
        let op = BlockOperation(){self.tick()}
        _timer = MouseModeScheduler.scheduleTimer(
            timeInterval: 0.015,
            target: op,
            selector: #selector(Operation.main)
        )
        _statusItem.image = _activeIcon
        _wokenupAt = GetCurrentEventTime()
        // Show the same locator feedback when entering mouse mode, so the
        // current pointer position is immediately visible after the switch.
        showCursorRipple()
    }
    fileprivate func disableMouseMode(){
        _timer?.invalidate()
        _timer = nil
        _cursorRippleController?.hide()
        reset()
        NSLog("mouse mode disabled")
        _statusItem?.image = _normalIcon
    }
    fileprivate func selfConversionWindowController() -> SelfConversionWindowController {
        if _selfConversionWindowController == nil {
            _selfConversionWindowController = SelfConversionWindowController()
        }
        return _selfConversionWindowController!
    }
    fileprivate func runSelfConversionUI(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.sync(execute: action)
        }
    }
    fileprivate func readSelfConversionUI<T>(_ action: () -> T) -> T {
        if Thread.isMainThread {
            return action()
        }

        var result: T!
        DispatchQueue.main.sync {
            result = action()
        }
        return result
    }
    fileprivate func handleSelfConversionInput(_ key: Int, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool {
        if let controller = _selfConversionWindowController, controller.isActive {
            if SelfConversionKeyInterpreter.shouldPassThroughActiveConversion(flags) {
                return false
            }

            if !pressed && _selfConversionStartKeyReleaseFilter.shouldIgnoreRelease(for: key) {
                NSLog("self conversion ignored start key release key=%d", key)
                return true
            }

            if SelfConversionKeyInterpreter.isSuffixInputShortcut(for: key, flags: flags) {
                if pressed { runSelfConversionUI { controller.beginSuffixInput() } }
                return true
            }

            if flags.ctrl && !flags.shift && !flags.opt && !flags.cmd {
                switch key {
                case kVK_ANSI_G:
                    if pressed { runSelfConversionUI { controller.splitInputAfterFirstCharacter() } }
                    return true
                case kVK_ANSI_H:
                    if pressed { runSelfConversionUI { controller.moveLastInputCharacterToNextSession() } }
                    return true
                case kVK_ANSI_J:
                    if pressed { runSelfConversionUI { controller.selectNext() } }
                    return true
                case kVK_ANSI_K:
                    if pressed { runSelfConversionUI { controller.selectPrevious() } }
                    return true
                case kVK_ANSI_N:
                    if pressed { runSelfConversionUI { controller.selectPunctuationCombination(forward: true) } }
                    return true
                case kVK_ANSI_P:
                    if pressed { runSelfConversionUI { controller.selectPunctuationCombination(forward: false) } }
                    return true
                case kVK_ANSI_L:
                    if pressed { runSelfConversionUI { controller.moveFirstNextSessionCharacterToInput() } }
                    return true
                case kVK_ANSI_Semicolon:
                    if !pressed {
                        runSelfConversionUI { controller.cancel() }
                        enableMouseMode()
                    }
                    return true
                default:
                    break
                }
            }

            switch key {
            case kVK_LeftArrow:
                if pressed && !flags.ctrl && !flags.shift && !flags.opt && !flags.cmd && !flags.fnc {
                    runSelfConversionUI { controller.moveLastInputCharacterToNextSession() }
                }
            case kVK_RightArrow:
                if pressed && !flags.ctrl && !flags.shift && !flags.opt && !flags.cmd && !flags.fnc {
                    runSelfConversionUI { controller.moveFirstNextSessionCharacterToInput() }
                }
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if !pressed {
                    if readSelfConversionUI({ controller.hasNextSessionInput }) {
                        partialCommitSelfConversion(controller)
                    } else {
                        let snapshot = readSelfConversionUI { controller.confirmAndClose() }
                        let text = snapshot.composedText
                        logSelfConversionDecision(action: "final_commit", snapshot: snapshot, committedOutput: text)
                        postText(text)
                    }
                }
            case _ where SelfConversionKeyInterpreter.isPartialCommitKey(for: key):
                if !pressed && !flags.ctrl && !flags.opt && !flags.cmd && !flags.fnc {
                    partialCommitSelfConversion(controller)
                }
            case kVK_JIS_Kana:
                if pressed { runSelfConversionUI { controller.forceStartCurrentConversion() } }
            case kVK_JIS_Eisu:
                if !pressed { runSelfConversionUI { controller.cancel() } }
            case kVK_Escape:
                if !pressed { runSelfConversionUI { controller.cancel() } }
            case kVK_Delete, kVK_ForwardDelete:
                if pressed { runSelfConversionUI { controller.backspace() } }
            default:
                if pressed && !flags.ctrl && !flags.opt && !flags.cmd && !flags.fnc,
                   let character = SelfConversionKeyInterpreter.character(for: key, flags: flags) {
                    if let snapshot = readSelfConversionUI({ controller.append(character) }) {
                        logSelfConversionDecision(
                            action: "partial_commit",
                            snapshot: snapshot,
                            committedOutput: snapshot.selectedCandidate?.text ?? snapshot.input
                        )
                    }
                }
            }
            return true
        }

        guard SelfConversionSettings.enabled else {
            return false
        }

        if SelfConversionKeyInterpreter.startsConversion(for: key) {
            guard SelfConversionSettings.hasConversionBackend else {
                SelfConversionSettings.enabled = false
                if pressed {
                    DispatchQueue.main.async {
                        self.showSettings(self)
                    }
                }
                return true
            }
            if pressed {
                startSelfConversion(from: key)
            }
            return true
        }

        return false
    }
    func handleRepeatedInput(_ keycode: Int64, _ flags: InputHook.Flags) -> Bool {
        guard let controller = _selfConversionWindowController, controller.isActive else {
            return true
        }

        switch Int(keycode) {
        case kVK_ANSI_G where flags.ctrl && !flags.shift && !flags.opt && !flags.cmd:
            runSelfConversionUI { controller.splitInputAfterFirstCharacter() }
        case kVK_Delete, kVK_ForwardDelete:
            runSelfConversionUI { controller.backspace() }
        case kVK_ANSI_H where flags.ctrl && !flags.shift && !flags.opt && !flags.cmd:
            runSelfConversionUI { controller.moveLastInputCharacterToNextSession() }
        case let key where SelfConversionKeyInterpreter.isSuffixInputShortcut(for: key, flags: flags):
            runSelfConversionUI { controller.beginSuffixInput() }
        case kVK_ANSI_L where flags.ctrl && !flags.shift && !flags.opt && !flags.cmd:
            runSelfConversionUI { controller.moveFirstNextSessionCharacterToInput() }
        case kVK_ANSI_N where flags.ctrl && !flags.shift && !flags.opt && !flags.cmd:
            runSelfConversionUI { controller.selectPunctuationCombination(forward: true) }
        case kVK_ANSI_P where flags.ctrl && !flags.shift && !flags.opt && !flags.cmd:
            runSelfConversionUI { controller.selectPunctuationCombination(forward: false) }
        case kVK_LeftArrow:
            runSelfConversionUI { controller.moveLastInputCharacterToNextSession() }
        case kVK_RightArrow:
            runSelfConversionUI { controller.moveFirstNextSessionCharacterToInput() }
        default:
            break
        }
        return true
    }
    fileprivate func logSelfConversionDecision(
        action: String,
        snapshot: SelfConversionDecisionSnapshot,
        committedOutput: String?
    ) {
        guard !(snapshot.learningInput ?? snapshot.input).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _selfConversionDecisionClient.submitDecision(SelfConversionDecisionEvent(
            action: action,
            snapshot: snapshot,
            committedOutput: committedOutput
        ))
    }
    fileprivate func partialCommitSelfConversion(_ controller: SelfConversionWindowController) {
        let snapshot = readSelfConversionUI { controller.commitCurrentCandidateForContinuation() }
        let committedOutput = snapshot.selectedCandidate?.text ?? snapshot.input
        logSelfConversionDecision(
            action: "partial_commit",
            snapshot: snapshot,
            committedOutput: committedOutput
        )
    }
    fileprivate func startSelfConversion(from key: Int) {
        NSLog("self conversion start requested key=%d mouseMode=%@", key, _timer != nil ? "true" : "false")
        _selfConversionStartKeyReleaseFilter.rememberStartKey(key)
        if _timer != nil {
            disableMouseMode()
        }
        runSelfConversionUI {
            let controller = self.selfConversionWindowController()
            controller.begin()
            NSLog("self conversion window began visible=%@", controller.isActive ? "true" : "false")
        }
    }
    private func showCursorRipple() {
        let point = NSEvent.mouseLocation
        let show = { [weak self] in
            guard let self = self, self._timer != nil else { return }
            self._cursorRippleController?.show(at: point)
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }
    private func startTrackpadEdgeSwipes() {
        let session = TrackpadEdgeSwipeSession()
        trackpadEdgeSwipeSession = session
        VMStartTrackpadMonitoring { [weak self] device, kind, id, x, y, timestamp in
            let frame: TrackpadEdgeSwipeDetector.Frame
            switch kind {
            case .idle:
                frame = .idle
            case .approaching:
                frame = .approaching(id: id, position: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            case .ended:
                frame = .ended(id: id, position: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            case .began, .moved:
                frame = .finger(id: id, position: CGPoint(x: CGFloat(x), y: CGFloat(y)), began: kind == .began)
            default:
                frame = .multipleOrInvalid
            }
            guard let (direction, display) = session.record(device: device, frame: frame, at: timestamp,
                                                            pointerDisplay: { vm_pointer_display() }) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.trackpadEdgeSwipeSession === session,
                      !self._leftButton, !self._rightButton, !self._centerButton else { return }
                vm_swipe_to_adjacent_space(direction == .left ? 1 : -1, display)
            }
        }
    }

    private func stopTrackpadEdgeSwipes() {
        guard trackpadEdgeSwipeSession != nil else { return }
        trackpadEdgeSwipeSession = nil
        VMStopTrackpadMonitoring()
    }

    private func performWindowNavigationAction(_ action: WindowNavigationAction) {
        switch action {
        case .previousSpace:
            vm_swipe_to_adjacent_space(-1, vm_pointer_display())
        case .nextSpace:
            vm_swipe_to_adjacent_space(1, vm_pointer_display())
        case .frontApplicationWindows:
            _ = vm_mission_control_action(MissionControlMode.frontApplicationWindows.rawValue)
        case .allWindows:
            _ = vm_mission_control_action(MissionControlMode.allWindows.rawValue)
        }
    }

    private func handleWindowNavigationInput(
        _ key: Int,
        _ flags: InputHook.Flags,
        _ pressed: Bool
    ) -> Bool {
        let hasModifier = flags.ctrl || flags.shift || flags.opt || flags.cmd || flags.fnc
        guard !hasModifier else { return false }

        if key == kVK_ANSI_B {
            _windowNavigationLeaderPressed = pressed
            return true
        }

        guard _windowNavigationLeaderPressed,
              let action = WindowNavigationAction.action(for: key) else {
            return false
        }

        if pressed { performWindowNavigationAction(action) }
        return true
    }
    @available(macOS 26.0, *)
    @MainActor
    private func handleVoiceInput(_ key: Int, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool {
        if !pressed { return voiceKeysDown.remove(key) != nil }
        if key == kVK_Escape, let voice = voiceInputController as? VoiceInput,
            voice.isActive, !flags.ctrl, !flags.shift, !flags.opt, !flags.cmd, !flags.fnc {
            voiceKeysDown.insert(key)
            voice.cancel()
            return true
        }
        guard VoiceInputShortcut.matches(key, flags: flags, mouseMode: _timer != nil)
            else { return false }
        voiceKeysDown.insert(key)
        if voiceInputController == nil {
            voiceInputController = VoiceInput(update: { [weak self] status in
                self?.showVoiceStatus(status)
            }, insert: { [weak self] text in self?.postText(text) })
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.async { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            (self?.voiceInputController as? VoiceInput)?.toggle(frontmostPID: pid)
        }
        return true
    }

    @available(macOS 26.0, *)
    private func showVoiceStatus(_ state: VoiceInput.Status) {
        voiceStatusReset?.cancel()
        voiceStatusReset = nil
        guard let button = _statusItem?.button else { return }
        let key: String
        switch state {
        case .idle: key = ""
        case .preparing: key = "preparing"
        case .recording: key = "recording"
        case .recognizing: key = "recognizing"
        case .microphone: key = "microphone"
        case .targetChanged: key = "targetChanged"
        case .model: key = "model"
        case .noSpeech: key = "noSpeech"
        case .failed: key = "failed"
        }
        switch state {
        case .idle: button.title = ""
        case .recording: button.title = "●"
        case .preparing, .recognizing: button.title = "…"
        default:
            button.title = "!"
            let reset = DispatchWorkItem { [weak self] in self?.showVoiceStatus(.idle) }
            voiceStatusReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: reset)
        }
        _statusItem.length = key.isEmpty ? 34 : 50
        button.imagePosition = key.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = key.isEmpty ? nil : localized("voiceInput." + key)
    }

    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool{
        let key = Int(keycode)
        if #available(macOS 26.0, *),
            MainActor.assumeIsolated({ handleVoiceInput(key, flags, pressed) }) {
            return true
        }
        if SelfConversionKeyInterpreter.isSelfConversionToggleShortcut(for: key, flags: flags) {
            if !pressed {
                setSelfConversionEnabled(!SelfConversionSettings.enabled, settingsSender: self)
            }
            return true
        }

        if _selfConversionWindowController?.isActive == true ||
            (SelfConversionSettings.enabled && SelfConversionKeyInterpreter.startsConversion(for: key)) ||
            _timer == nil {
            if handleSelfConversionInput(key, flags, pressed) {
                return true
            }
        }
        if(_timer != nil){
            // mouse mode
            if handleWindowNavigationInput(key, flags, pressed) {
                return true
            }
            if(flags.cmd){return false}
            if(flags.ctrl && flags.shift){return false}
            if key == kVK_ANSI_Semicolon && flags.fnc && !flags.ctrl && !flags.shift && !flags.opt {
                if pressed { showCursorRipple() }
                return true
            }
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
                if !flags.ctrl && !(key == kVK_ANSI_Semicolon && flags.fnc) {
                    _rightButton = pressed
                    click(pressed ? .rightMouseDown : .rightMouseUp, .right, pressed)
                }
            case KeyMapping.keyCode(for: .middleClick):
                _centerButton = pressed
                click(pressed ? .otherMouseDown : .otherMouseUp, .center, pressed)
            case KeyMapping.keyCode(for: .cursorRipple):
                guard CursorRippleTrigger.isEligible(keycode: key, flags: flags) else { return false }
                if pressed { showCursorRipple() }
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

private extension AppDelegate {
    static func versionMenuTitle() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
