//
//  ViMouseTests.swift
//  ViMouseTests
//
//  Created by TakiuchiGenki on 2015/07/19.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

import Carbon
import XCTest

class ViMouseTests: XCTestCase {
    func testAllowsMovementAcrossAdjacentDisplays() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        let position = MouseMovementBounds.nextPosition(
            current: CGPoint(x: 99, y: 50),
            delta: CGVector(dx: 2, dy: 0),
            displays: displays
        )

        XCTAssertEqual(position, CGPoint(x: 101, y: 50))
    }

    func testClampsToCurrentDisplayWhenMovingIntoGapBetweenDisplays() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 120, y: 0, width: 100, height: 100),
        ]

        let position = MouseMovementBounds.nextPosition(
            current: CGPoint(x: 99, y: 50),
            delta: CGVector(dx: 2, dy: 0),
            displays: displays
        )

        XCTAssertEqual(position, CGPoint(x: 99, y: 50))
    }

    func testInputHookPassesThroughKeysTheDelegateDoesNotConsume() {
        let hook = InputHook()
        let delegate = InputHookDelegateStub(results: [false, false])
        hook.delegate = delegate

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!

        XCTAssertFalse(hook.keyDown(down))
        XCTAssertFalse(hook.keyUp(up))
        XCTAssertEqual(delegate.calls.map(\.pressed), [true, false])
    }

    func testInputHookKeepsRepeatKeyEventsConsistentWithInitialDecision() {
        let hook = InputHook()
        let delegate = InputHookDelegateStub(results: [false, false])
        hook.delegate = delegate

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!

        XCTAssertFalse(hook.keyDown(down))
        XCTAssertFalse(hook.keyDown(down))
        XCTAssertEqual(delegate.calls.map(\.pressed), [true])
    }

    func testKeyMappingStoresAndResetsCustomKeyCodes() {
        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_H)

        KeyMapping.setKeyCode(kVK_ANSI_A, for: .moveLeft)
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_A)

        KeyMapping.resetDefaults()
        XCTAssertEqual(KeyMapping.keyCode(for: .moveLeft), kVK_ANSI_H)
    }
}

private final class InputHookDelegateStub: InputHookDelegate {
    struct Call {
        let keycode: Int64
        let pressed: Bool
    }

    private var results: [Bool]
    private(set) var calls: [Call] = []

    init(results: [Bool]) {
        self.results = results
    }

    func handleInput(_ keycode: Int64, _ flags: InputHook.Flags, _ pressed: Bool) -> Bool {
        calls.append(Call(keycode: keycode, pressed: pressed))
        return results.removeFirst()
    }
}
