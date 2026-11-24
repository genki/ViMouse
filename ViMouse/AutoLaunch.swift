//
//  AutoLaunch.swift
//  ViMouse
//
//  Registers ViMouse as a login item for the current user.
//

import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

enum ViMouseLaunchAgent {
    static let label = "com.s21g.ViMouse"
    static let fileName = "\(label).plist"

    static func launchAgentURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func propertyList(executablePath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }
}

final class AutoLaunchManager {
    static let shared = AutoLaunchManager()

    private static let registrationAttemptedKey = "ViMouse.autoLaunchRegistrationAttempted"
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func enable() {
        // A test target may load the application delegate. Never modify the
        // user's login items as a side effect of running tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        if #available(macOS 13.0, *) {
            enableWithServiceManagement()
        } else {
            enableWithLaunchAgent()
        }
    }

    private func enableWithLaunchAgent() {
        guard let executableURL = Bundle.main.executableURL else {
            NSLog("ViMouse auto-launch: application executable URL is unavailable")
            return
        }

        let agentURL = ViMouseLaunchAgent.launchAgentURL(
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
        let agentDirectory = agentURL.deletingLastPathComponent()
        let propertyList = ViMouseLaunchAgent.propertyList(executablePath: executableURL.path)

        do {
            try fileManager.createDirectory(
                at: agentDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )

            if !fileManager.fileExists(atPath: agentURL.path)
                || fileManager.contents(atPath: agentURL.path) != data {
                try data.write(to: agentURL, options: .atomic)
            }
            NSLog("ViMouse auto-launch: LaunchAgent installed at %@", agentURL.path)
        } catch {
            NSLog("ViMouse auto-launch: could not install LaunchAgent: %@", error.localizedDescription)
        }
    }

    @available(macOS 13.0, *)
    private func enableWithServiceManagement() {
#if canImport(ServiceManagement)
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            defaults.set(true, forKey: Self.registrationAttemptedKey)
        case .requiresApproval:
            // Registration has already happened. The user can approve the
            // item in System Settings > General > Login Items.
            defaults.set(true, forKey: Self.registrationAttemptedKey)
            NSLog("ViMouse auto-launch: login item requires user approval")
        case .notRegistered:
            // Do not re-register on every launch after the user has disabled
            // the login item in System Settings.
            guard !defaults.bool(forKey: Self.registrationAttemptedKey) else {
                return
            }
            do {
                try service.register()
                defaults.set(true, forKey: Self.registrationAttemptedKey)
                NSLog("ViMouse auto-launch: login item registered")
            } catch {
                NSLog("ViMouse auto-launch: could not register login item: %@", error.localizedDescription)
            }
        case .notFound:
            // The running application is the main service, so this should
            // only be transient (for example while LaunchServices refreshes).
            do {
                try service.register()
                defaults.set(true, forKey: Self.registrationAttemptedKey)
                NSLog("ViMouse auto-launch: login item registered after refresh")
            } catch {
                NSLog("ViMouse auto-launch: login item is unavailable: %@", error.localizedDescription)
            }
        @unknown default:
            NSLog("ViMouse auto-launch: unknown login item status")
        }
#else
        NSLog("ViMouse auto-launch: ServiceManagement is unavailable")
#endif
    }
}
