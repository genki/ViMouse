import Foundation

enum MovementSetting: String, CaseIterable {
    case baseSpeed
    case acceleration
    case damping

    var title: String {
        switch self {
        case .baseSpeed: return localized("movement.baseSpeed.title")
        case .acceleration: return localized("movement.acceleration.title")
        case .damping: return localized("movement.damping.title")
        }
    }

    var detail: String {
        switch self {
        case .baseSpeed: return localized("movement.baseSpeed.detail")
        case .acceleration: return localized("movement.acceleration.detail")
        case .damping: return localized("movement.damping.detail")
        }
    }

    var defaultValue: Double {
        switch self {
        case .baseSpeed: return 1.33
        case .acceleration: return 2.0
        case .damping: return 0.8
        }
    }

    var minimumValue: Double {
        switch self {
        case .baseSpeed: return 0.1
        case .acceleration: return 0.1
        case .damping: return 0.1
        }
    }

    var maximumValue: Double {
        switch self {
        case .baseSpeed: return 5.0
        case .acceleration: return 8.0
        case .damping: return 0.95
        }
    }
}

enum MovementSettings {
    static let changedNotification = Notification.Name("MovementSettingsChanged")

    static var baseSpeed: Double {
        value(for: .baseSpeed)
    }

    static var acceleration: Double {
        value(for: .acceleration)
    }

    static var damping: Double {
        value(for: .damping)
    }

    static func value(for setting: MovementSetting) -> Double {
        let key = defaultsKey(for: setting)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return setting.defaultValue
        }
        return clamped(UserDefaults.standard.double(forKey: key), for: setting)
    }

    static func setValue(_ value: Double, for setting: MovementSetting) {
        UserDefaults.standard.set(clamped(value, for: setting), forKey: defaultsKey(for: setting))
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func resetDefaults() {
        for setting in MovementSetting.allCases {
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: setting))
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func clamped(_ value: Double, for setting: MovementSetting) -> Double {
        min(max(value, setting.minimumValue), setting.maximumValue)
    }

    private static func defaultsKey(for setting: MovementSetting) -> String {
        "MovementSettings.\(setting.rawValue)"
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
