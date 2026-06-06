import Carbon
import Foundation

enum KeyMappingAction: String, CaseIterable {
    case enterMouseMode
    case exitMouseMode
    case moveLeft
    case moveDown
    case moveUp
    case moveRight
    case wheel
    case leftClick
    case rightClick
    case middleClick
    case verySlow
    case slow
    case fast
    case veryFast
    case yank
    case paste
    case cut
    case reload
    case undo
    case find

    var title: String {
        switch self {
        case .enterMouseMode: return localized("keyMapping.enterMouseMode.title")
        case .exitMouseMode: return localized("keyMapping.exitMouseMode.title")
        case .moveLeft: return localized("keyMapping.moveLeft.title")
        case .moveDown: return localized("keyMapping.moveDown.title")
        case .moveUp: return localized("keyMapping.moveUp.title")
        case .moveRight: return localized("keyMapping.moveRight.title")
        case .wheel: return localized("keyMapping.wheel.title")
        case .leftClick: return localized("keyMapping.leftClick.title")
        case .rightClick: return localized("keyMapping.rightClick.title")
        case .middleClick: return localized("keyMapping.middleClick.title")
        case .verySlow: return localized("keyMapping.verySlow.title")
        case .slow: return localized("keyMapping.slow.title")
        case .fast: return localized("keyMapping.fast.title")
        case .veryFast: return localized("keyMapping.veryFast.title")
        case .yank: return localized("keyMapping.yank.title")
        case .paste: return localized("keyMapping.paste.title")
        case .cut: return localized("keyMapping.cut.title")
        case .reload: return localized("keyMapping.reload.title")
        case .undo: return localized("keyMapping.undo.title")
        case .find: return localized("keyMapping.find.title")
        }
    }

    var detail: String {
        switch self {
        case .enterMouseMode: return localized("keyMapping.enterMouseMode.detail")
        case .exitMouseMode: return localized("keyMapping.mouseMode.detail")
        case .moveLeft, .moveDown, .moveUp, .moveRight: return localized("keyMapping.movement.detail")
        case .wheel: return localized("keyMapping.mouseMode.detail")
        case .leftClick, .rightClick, .middleClick: return localized("keyMapping.mouseMode.detail")
        case .verySlow, .slow, .fast, .veryFast: return localized("keyMapping.speed.detail")
        case .yank, .paste, .cut, .reload, .undo, .find: return localized("keyMapping.command.detail")
        }
    }

    var defaultKeyCode: Int {
        switch self {
        case .enterMouseMode: return kVK_ANSI_Semicolon
        case .exitMouseMode: return kVK_ANSI_I
        case .moveLeft: return kVK_ANSI_H
        case .moveDown: return kVK_ANSI_J
        case .moveUp: return kVK_ANSI_K
        case .moveRight: return kVK_ANSI_L
        case .wheel: return kVK_ANSI_G
        case .leftClick: return kVK_Space
        case .rightClick: return kVK_ANSI_Semicolon
        case .middleClick: return kVK_ANSI_N
        case .verySlow: return kVK_ANSI_A
        case .slow: return kVK_ANSI_S
        case .fast: return kVK_ANSI_D
        case .veryFast: return kVK_ANSI_F
        case .yank: return kVK_ANSI_Y
        case .paste: return kVK_ANSI_P
        case .cut: return kVK_ANSI_X
        case .reload: return kVK_ANSI_R
        case .undo: return kVK_ANSI_U
        case .find: return kVK_ANSI_Slash
        }
    }
}

struct KeyChoice {
    let title: String
    let keyCode: Int
}

enum KeyMapping {
    static let changedNotification = Notification.Name("KeyMappingChanged")
    static let choices: [KeyChoice] = [
        KeyChoice(title: "A", keyCode: kVK_ANSI_A),
        KeyChoice(title: "B", keyCode: kVK_ANSI_B),
        KeyChoice(title: "C", keyCode: kVK_ANSI_C),
        KeyChoice(title: "D", keyCode: kVK_ANSI_D),
        KeyChoice(title: "E", keyCode: kVK_ANSI_E),
        KeyChoice(title: "F", keyCode: kVK_ANSI_F),
        KeyChoice(title: "G", keyCode: kVK_ANSI_G),
        KeyChoice(title: "H", keyCode: kVK_ANSI_H),
        KeyChoice(title: "I", keyCode: kVK_ANSI_I),
        KeyChoice(title: "J", keyCode: kVK_ANSI_J),
        KeyChoice(title: "K", keyCode: kVK_ANSI_K),
        KeyChoice(title: "L", keyCode: kVK_ANSI_L),
        KeyChoice(title: "M", keyCode: kVK_ANSI_M),
        KeyChoice(title: "N", keyCode: kVK_ANSI_N),
        KeyChoice(title: "O", keyCode: kVK_ANSI_O),
        KeyChoice(title: "P", keyCode: kVK_ANSI_P),
        KeyChoice(title: "Q", keyCode: kVK_ANSI_Q),
        KeyChoice(title: "R", keyCode: kVK_ANSI_R),
        KeyChoice(title: "S", keyCode: kVK_ANSI_S),
        KeyChoice(title: "T", keyCode: kVK_ANSI_T),
        KeyChoice(title: "U", keyCode: kVK_ANSI_U),
        KeyChoice(title: "V", keyCode: kVK_ANSI_V),
        KeyChoice(title: "W", keyCode: kVK_ANSI_W),
        KeyChoice(title: "X", keyCode: kVK_ANSI_X),
        KeyChoice(title: "Y", keyCode: kVK_ANSI_Y),
        KeyChoice(title: "Z", keyCode: kVK_ANSI_Z),
        KeyChoice(title: ";", keyCode: kVK_ANSI_Semicolon),
        KeyChoice(title: "/", keyCode: kVK_ANSI_Slash),
        KeyChoice(title: localized("keyChoice.space"), keyCode: kVK_Space),
    ]

    static func keyCode(for action: KeyMappingAction) -> Int {
        let key = defaultsKey(for: action)
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        return stored ?? action.defaultKeyCode
    }

    static func setKeyCode(_ keyCode: Int, for action: KeyMappingAction) {
        UserDefaults.standard.set(keyCode, forKey: defaultsKey(for: action))
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func resetDefaults() {
        for action in KeyMappingAction.allCases {
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: action))
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func title(for keyCode: Int) -> String {
        choices.first(where: { $0.keyCode == keyCode })?.title ?? "\(keyCode)"
    }

    private static func defaultsKey(for action: KeyMappingAction) -> String {
        "KeyMapping.\(action.rawValue)"
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
