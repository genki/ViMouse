import Foundation

enum SelfConversionSettings {
    enum Backend: String { case local, server }
    static var backend: Backend {
        get { Backend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .local }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: backendKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }
    static var hasConversionBackend: Bool { backend == .local ? localUnavailableReason == nil : hasAPIEndpoint }

    // 設定画面と実行時に同じ条件を使い、サーバー方式へ自動変更しない。
    static func localUnavailableReason(appleSilicon: Bool, majorVersion: Int, resourcesPresent: Bool) -> String? {
        guard appleSilicon else { return "ローカル変換にはApple Siliconが必要です。サーバー変換は方式を選択した場合だけ使用します。" }
        guard majorVersion >= 14 else { return "ローカル変換にはmacOS 14以降が必要です。" }
        guard resourcesPresent else { return "ローカル変換のSDK・辞書が見つかりません。アプリを再インストールしてください。" }
        return nil
    }

    static var localUnavailableReason: String? {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let bundle = Bundle.main
        let files = [bundle.bundleURL.appendingPathComponent("Contents/Frameworks/libvimouse_ime.dylib"),
            bundle.resourceURL?.appendingPathComponent("LocalConversion/mozc.data"),
            bundle.resourceURL?.appendingPathComponent("LocalConversion/lexicon")]
        return localUnavailableReason(appleSilicon: appleSilicon,
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            resourcesPresent: files.allSatisfy { $0.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false })
    }

    static let changedNotification = Notification.Name("SelfConversionSettingsChanged")

    static var inputHistoryLimit: Int {
        get { min(max(UserDefaults.standard.object(forKey: historyLimitKey) as? Int ?? 10, 0), 1000) }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 1000), forKey: historyLimitKey)
            UserDefaults.standard.set(Array(inputHistory.prefix(inputHistoryLimit)), forKey: historyKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var inputHistory: [String] {
        Array((UserDefaults.standard.stringArray(forKey: historyKey) ?? []).prefix(inputHistoryLimit))
    }

    static func rememberInput(_ input: String) {
        guard inputHistoryLimit > 0, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var history = inputHistory
        // Reopening and closing the same input should not fill the history.
        guard history.first != input else { return }
        history.insert(input, at: 0)
        UserDefaults.standard.set(Array(history.prefix(inputHistoryLimit)), forKey: historyKey)
    }

    static var learningEnabled: Bool {
        get { UserDefaults.standard.object(forKey: learningKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: learningKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var enabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var apiEndpoint: String {
        get {
            let endpoint = UserDefaults.standard.string(forKey: apiEndpointKey) ?? ""
            return normalizedEndpoint(endpoint.isEmpty ? defaultAPIEndpoint : endpoint)
        }
        set {
            UserDefaults.standard.set(normalizedEndpoint(newValue), forKey: apiEndpointKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var hasAPIEndpoint: Bool {
        !apiEndpoint.isEmpty
    }

    static var apiEndpointURL: URL? {
        let endpoint = apiEndpoint
        guard !endpoint.isEmpty else { return nil }
        return URL(string: endpoint)
    }

    static var feedbackEndpointURL: URL? {
        guard let endpoint = apiEndpointURL else { return nil }
        var base = endpoint
        if endpoint.lastPathComponent == "convert" {
            base.deleteLastPathComponent()
        }
        return base.appendingPathComponent("feedback")
    }

    static var requestTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: requestTimeoutKey)
        if value > 0 {
            let clamped = min(max(value, 0.4), 10.0)
            if apiEndpoint == defaultAPIEndpoint && abs(clamped - legacyWinVRRequestTimeout) < 0.0001 {
                return defaultRequestTimeout
            }
            return clamped
        }
        return defaultRequestTimeout
    }

    static func setRequestTimeout(_ value: TimeInterval) {
        UserDefaults.standard.set(min(max(value, 0.4), 10.0), forKey: requestTimeoutKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: backendKey)
        UserDefaults.standard.removeObject(forKey: learningKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: apiEndpointKey)
        UserDefaults.standard.removeObject(forKey: requestTimeoutKey)
        UserDefaults.standard.removeObject(forKey: historyLimitKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func normalizedEndpoint(_ value: String) -> String {
        let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            return defaultAPIEndpoint
        } else if ["http://127.0.0.1:11434/api/generate",
                   "http://127.0.0.1:8766/api/generate",
                   "http://127.0.0.1:18768/convert"].contains(endpoint) {
            return defaultAPIEndpoint
        }
        return endpoint
    }

    private static let backendKey = "SelfConversionSettings.backend"
    private static let historyLimitKey = "SelfConversionSettings.inputHistoryLimit"
    private static let historyKey = "SelfConversionSettings.inputHistory"
    private static let enabledKey = "SelfConversionSettings.enabled"
    private static let learningKey = "SelfConversionSettings.learningEnabled"
    private static let apiEndpointKey = "SelfConversionSettings.apiEndpoint"
    private static let requestTimeoutKey = "SelfConversionSettings.requestTimeout"
    private static let defaultAPIEndpoint = "http://127.0.0.1:8767/convert"
    private static let defaultRequestTimeout: TimeInterval = 10.0
    private static let legacyWinVRRequestTimeout: TimeInterval = 5.0
}
