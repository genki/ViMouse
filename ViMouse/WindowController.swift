//
//  WindowController.swift
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/24.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Cocoa

class WindowController : NSWindowController, NSWindowDelegate {
    
    func windowShouldClose(sender: AnyObject) -> Bool {
        NSApplication.sharedApplication().hide(self)
        return false
    }
}