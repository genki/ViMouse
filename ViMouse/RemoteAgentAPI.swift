import Cocoa
import Security
import Darwin

struct AgentLANAddress: Equatable {
    let address: UInt32
    let mask: UInt32
    var text: String { [24, 16, 8, 0].map { String((address >> $0) & 255) }.joined(separator: ".") }
    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xac1 || ip >> 16 == 0xc0a8 || ip >> 16 == 0xa9fe
    }
    func accepts(_ peer: UInt32) -> Bool {
        if address >> 24 == 127 { return peer >> 24 == 127 }
        return Self.isPrivate(peer) && mask != 0 && (peer & mask) == (address & mask)
    }
    static func current() -> [AgentLANAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result = [AgentLANAddress(address: 0x7f000001, mask: 0xff000000)]
        var item = head
        while let pointer = item {
            defer { item = pointer.pointee.ifa_next }
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_POINTOPOINT) == 0,
                  name.hasPrefix("en") || name.hasPrefix("bridge"),
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let candidate = AgentLANAddress(address: ip, mask: mask)
            if isPrivate(ip), !result.contains(candidate) { result.append(candidate) }
        }
        return result.sorted { $0.address < $1.address }
    }
}

struct AgentHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let query: [URLQueryItem]
    let body: Data
    static let limit = 65536

    // nil means incomplete. Reject ambiguous HTTP framing; one request per connection.
    static func parse(_ data: Data) throws -> AgentHTTPRequest? {
        guard data.count <= limit else { throw AgentAPIError(413, "Request too large") }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw AgentAPIError(413, "Headers too large") }
            return nil
        }
        guard end.lowerBound <= 8192,
              let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw AgentAPIError(400, "Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"),
              !first[1].hasPrefix("//"), let url = URLComponents(string: first[1]), url.fragment == nil else {
            throw AgentAPIError(400, "Invalid request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { throw AgentAPIError(400, "Invalid header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else { throw AgentAPIError(400, "Duplicate/invalid header") }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil,
              headers["expect"] == nil else { throw AgentAPIError(400, "Unsupported framing") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(rawLength), count <= limit - end.upperBound else { throw AgentAPIError(413, "Invalid body size") }
        if data.count < end.upperBound + count { return nil }
        guard data.count == end.upperBound + count else { throw AgentAPIError(400, "Pipelining is unsupported") }
        return AgentHTTPRequest(method: first[0], path: url.path, headers: headers,
                                query: url.queryItems ?? [], body: Data(data[end.upperBound...]))
    }

    func authenticated(with token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let tokens = query.filter { $0.name == "token" }
        guard tokens.count <= 1 else { return false }
        let bearer = headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        if headers["authorization"] != nil && bearer == nil { return false }
        if let bearer, let value = tokens.first?.value, bearer != value { return false }
        let supplied = Array((bearer ?? tokens.first?.value ?? "").utf8)
        let expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct AgentAPIError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// Socket lifecycle and action execution are serialized on the main queue.
/// Blocking, bounded HTTP I/O runs off the main queue.
final class RemoteAgentAPI {
    static let shared = RemoteAgentAPI()
    static let changed = Notification.Name("ViMouseRemoteAgentChanged")
    static let port: UInt16 = 8766
    private(set) var enabled = false
    private(set) var status = ""
    private(set) var addresses: [AgentLANAddress] = []
    private var token = ""
    private var listeners: [DispatchSourceRead] = []
    private var clients: Set<Int32> = []
    private var generation = 0
    private var listenerGeneration = 0
    private var timer: Timer?
    private var held: Set<String> = []
    private var lastAction = Date.distantPast
    private let defaults: UserDefaults
    // Injectable storage and actions allow tests to exercise real sockets without moving the user's cursor.
    private let tokenStore: ((String?) throws -> String)?
    private let actionOverride: ((String, [String: Any]) throws -> [String: Any])?
    private let hasAccessibility: () -> Bool
    private let eventSink: ((CGEvent) -> Void)?

    init(defaults: UserDefaults = .standard,
         tokenStore: ((String?) throws -> String)? = nil,
         actionOverride: ((String, [String: Any]) throws -> [String: Any])? = nil,
         hasAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         eventSink: ((CGEvent) -> Void)? = nil) {
        self.defaults = defaults; self.tokenStore = tokenStore; self.actionOverride = actionOverride
        self.hasAccessibility = hasAccessibility; self.eventSink = eventSink
    }

    var urls: [String] {
        guard !token.isEmpty else { return [] }
        return displayAddresses.map { "http://\($0.text):\(Self.port)/agent/docs?token=\(token)" }
    }

    var displayAddresses: [AgentLANAddress] { enabled ? addresses : AgentLANAddress.current() }

    func prepareSettings() {
        guard token.isEmpty else { return }
        do { token = try tokenStore?(nil) ?? Self.storedToken(nil) }
        catch { status = String(describing: error) }
    }

    func restore() { setEnabled(defaults.bool(forKey: "remoteAgent.enabled")) }

    func setEnabled(_ value: Bool) {
        stop()
        enabled = value
        defaults.set(value, forKey: "remoteAgent.enabled")
        if value {
            do {
                token = try tokenStore?(nil) ?? Self.storedToken(nil)
                try listen()
                timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
                RunLoop.main.add(timer!, forMode: .common)
            } catch {
                stop(); enabled = false
                defaults.set(false, forKey: "remoteAgent.enabled")
                status = String(describing: error)
            }
        } else { status = NSLocalizedString("agent.disabled", comment: "") }
        notify()
    }

    func rotateToken() {
        do {
            let newToken = try Self.randomToken()
            token = try tokenStore?(newToken) ?? Self.storedToken(newToken)
            generation += 1
            releaseButtons()
            for fd in clients { Darwin.shutdown(fd, SHUT_RDWR) }
            notify()
        } catch { status = String(describing: error); notify() }
    }

    func stop() {
        generation += 1
        listenerGeneration += 1
        timer?.invalidate(); timer = nil
        for source in listeners { source.cancel(); Darwin.close(Int32(source.handle)) }
        listeners.removeAll(); addresses.removeAll()
        for fd in clients { Darwin.shutdown(fd, SHUT_RDWR) }
        releaseButtons()
        enabled = false
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }

    @objc private func tick() {
        if !held.isEmpty && Date().timeIntervalSince(lastAction) > 5 { releaseButtons() }
        if AgentLANAddress.current() != addresses {
            // Interface changes invalidate accepted requests and held drags as well.
            setEnabled(true)
        }
    }

    private func listen() throws {
        let candidates = AgentLANAddress.current()
        for address in candidates {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AgentAPIError(503, "socket failed") }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = Self.port.bigEndian
            local.sin_addr.s_addr = address.address.bigEndian
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); throw AgentAPIError(503, "Port \(Self.port) unavailable on \(address.text)") }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw AgentAPIError(503, "Cannot configure listener") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            let listenerGeneration = self.listenerGeneration
            source.setEventHandler { [weak self] in
                guard let self, self.listenerGeneration == listenerGeneration else { return }
                self.acceptClients(fd, address: address)
            }
            listeners.append(source); source.resume()
        }
        addresses = candidates
        status = NSLocalizedString("agent.enabled", comment: "")
    }

    private func acceptClients(_ listener: Int32, address: AgentLANAddress) {
        // Bounded work per run-loop turn, even under a connection flood.
        for _ in 0..<16 {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &length) }
            }
            guard fd >= 0 else { break }
            guard enabled, clients.count < 16, address.accepts(peer.sin_addr.s_addr.bigEndian) else { Darwin.close(fd); continue }
            guard fcntl(fd, F_SETFL, 0) == 0 else { Darwin.close(fd); continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            clients.insert(fd)
            let acceptedGeneration = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { Darwin.close(fd); return }
                var response: (Int, [String: Any])
                do {
                    let request = try Self.read(fd)
                    response = DispatchQueue.main.sync {
                        guard self.enabled, self.generation == acceptedGeneration,
                              AgentLANAddress.current().contains(address) else { return (403, ["error": "API disabled or connection expired"]) }
                        return self.handle(request)
                    }
                } catch {
                    let error = error as? AgentAPIError ?? AgentAPIError(400, "Invalid request")
                    response = (error.status, ["error": error.message])
                }
                Self.write(fd, status: response.0, body: response.1)
                DispatchQueue.main.async {
                    self.clients.remove(fd)
                    Darwin.close(fd)
                }
            }
        }
    }

    private static func read(_ fd: Int32) throws -> AgentHTTPRequest {
        var data = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw AgentAPIError(400, "Incomplete request") }
            data.append(contentsOf: bytes.prefix(count))
            if let request = try AgentHTTPRequest.parse(data) { return request }
        }
        throw AgentAPIError(408, "Request timed out")
    }

    private static func write(_ fd: Int32, status: Int, body: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) else { return }
        var data = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        data.append(json)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var sent = 0
            let deadline = Date().addingTimeInterval(3)
            while sent < buffer.count && Date() < deadline {
                let count = send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    func handle(_ request: AgentHTTPRequest) -> (Int, [String: Any]) {
        guard enabled else { return (403, ["error": "API disabled"]) }
        guard request.authenticated(with: token) else { return (401, ["error": "Invalid token"]) }
        guard request.headers["origin"] == nil else { return (403, ["error": "Cross-origin browser requests are unsupported"]) }
        do {
            if request.method == "GET", request.body.isEmpty {
                if request.path == "/agent/docs" { return (200, documentation) }
                if request.path == "/agent/api/state" { return (200, try action("state", [:])) }
            }
            guard request.path == "/agent/api/commands" else { return (404, ["error": "Not found"]) }
            guard request.method == "POST" else { return (405, ["error": "POST required"]) }
            guard request.headers["content-type"]?.components(separatedBy: ";")[0].lowercased() == "application/json",
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let command = body["command"] as? String,
                  Set(body.keys).isSubset(of: ["command", "params"]),
                  body["params"] == nil || body["params"] is [String: Any] else { throw AgentAPIError(400, "JSON {command, params} required") }
            return (200, ["ok": true, "result": try action(command, body["params"] as? [String: Any] ?? [:])])
        } catch {
            let error = error as? AgentAPIError ?? AgentAPIError(400, "Invalid JSON")
            return (error.status, ["error": error.message])
        }
    }

    private var documentation: [String: Any] { [
        "name": "ViMouse Agent API", "version": 1,
        "authentication": "Authorization: Bearer <token> or ?token=<token>. Rotation immediately revokes the old token. No expiry.",
        "scope": "IPv4 loopback and same-subnet private IPv4 LAN on en*/bridge* interfaces only; no IPv6/public/VPN listener. HTTP, not TLS.",
        "endpoints": ["GET /agent/docs", "GET /agent/api/state", "POST /agent/api/commands"],
        "request": ["command": "cursor.move", "params": ["x": 100, "y": 200]],
        "commands": ["cursor.move": "{x,y} absolute OR {dx,dy} relative; finite coordinates on an active display",
                     "mouse.click": "{button:left|right|middle, count:1|2}; defaults left,1",
                     "mouse.down": "{button:left|right|middle}; defaults left",
                     "mouse.up": "{button:left|right|middle}; defaults left",
                     "mouse.release": "{} releases API-held buttons",
                     "scroll": "{dx,dy}, signed integer pixels, each -10000...10000"],
        "coordinates": "CoreGraphics global points: primary display top-left is (0,0), x right, y down. Other displays may have negative coordinates. See state.displays.",
        "limits": "One HTTP/1.1 request per connection; 64KiB; 5s receive deadline; 16 clients. No browser CORS. Held buttons release after 5s without an action, on disable, token rotation, network changes, and exit.",
        "permissions": "Mouse operations require macOS Accessibility permission for ViMouse."
    ] }

    private func action(_ command: String, _ params: [String: Any]) throws -> [String: Any] {
        if let actionOverride { return try actionOverride(command, params) }
        let displays = Self.displays()
        let position = CGEvent(source: nil)?.location ?? .zero
        if command == "state" {
            return ["cursor": ["x": position.x, "y": position.y], "heldButtons": held.sorted(),
                    "accessibility": hasAccessibility(), "displays": displays.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }]
        }
        guard hasAccessibility() else { throw AgentAPIError(403, "Accessibility permission required") }
        func fields(_ allowed: Set<String>) throws {
            guard Set(params.keys).isSubset(of: allowed) else { throw AgentAPIError(400, "Unknown parameters") }
        }
        func number(_ key: String) throws -> Double {
            guard let value = params[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw AgentAPIError(400, "Finite number required: \(key)") }
            return value.doubleValue
        }
        switch command {
        case "cursor.move":
            let absolute = params["x"] != nil || params["y"] != nil
            try fields(absolute ? ["x", "y"] : ["dx", "dy"])
            let target = try absolute ? CGPoint(x: number("x"), y: number("y")) : CGPoint(x: position.x + number("dx"), y: position.y + number("dy"))
            guard displays.contains(where: { $0.contains(target) }) else { throw AgentAPIError(400, "Point is outside active displays") }
            let button = held.sorted().first ?? "left"
            let type: CGEventType = held.isEmpty ? .mouseMoved : (button == "left" ? .leftMouseDragged : button == "right" ? .rightMouseDragged : .otherMouseDragged)
            try post(type, button: button, at: target)
        case "mouse.click", "mouse.down", "mouse.up":
            try fields(command == "mouse.click" ? ["button", "count"] : ["button"])
            let button = params["button"] as? String ?? "left"
            guard params["button"] == nil || params["button"] is String,
                  ["left", "right", "middle"].contains(button) else { throw AgentAPIError(400, "Invalid button") }
            let down: CGEventType = button == "left" ? .leftMouseDown : button == "right" ? .rightMouseDown : .otherMouseDown
            let up: CGEventType = button == "left" ? .leftMouseUp : button == "right" ? .rightMouseUp : .otherMouseUp
            if command == "mouse.click" {
                let count = try params["count"] == nil ? 1 : number("count")
                guard count == 1 || count == 2, held.isEmpty else { throw AgentAPIError(400, "Click requires count 1 or 2 and no held buttons") }
                for index in 1...Int(count) { try post(down, button: button, at: position, count: index); try post(up, button: button, at: position, count: index) }
            } else if command == "mouse.down" {
                guard held.isEmpty else { throw AgentAPIError(409, "Release the held button first") }
                try post(down, button: button, at: position); held.insert(button)
            } else if held.contains(button) {
                try post(up, button: button, at: position); held.remove(button)
            }
        case "mouse.release":
            try fields([]); releaseButtons()
        case "scroll":
            try fields(["dx", "dy"])
            let x = try number("dx"), y = try number("dy")
            guard abs(x) <= 10000, abs(y) <= 10000, x.rounded() == x, y.rounded() == y else { throw AgentAPIError(400, "Scroll must be integer pixels in -10000...10000") }
            let scroll: CGEvent?
            if #available(macOS 10.13, *) {
                scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0)
            } else {
                scroll = CGEvent(source: nil)
                scroll?.type = .scrollWheel
                scroll?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                scroll?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
                scroll?.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
                scroll?.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
                scroll?.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
                scroll?.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(y) << 16)
                scroll?.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(x) << 16)
            }
            guard let event = scroll else { throw AgentAPIError(503, "Cannot create event") }
            emit(event)
        default: throw AgentAPIError(400, "Unknown command")
        }
        lastAction = Date()
        return try action("state", [:])
    }

    private func post(_ type: CGEventType, button: String, at point: CGPoint, count: Int = 1) throws {
        let buttonValue: CGMouseButton = button == "left" ? .left : button == "right" ? .right : .center
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: buttonValue) else { throw AgentAPIError(503, "Cannot create event") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        emit(event)
    }
    private func emit(_ event: CGEvent) {
        if let eventSink { eventSink(event) } else { event.post(tap: .cghidEventTap) }
    }
    private func releaseButtons() {
        for button in held {
            try? post(button == "left" ? .leftMouseUp : button == "right" ? .rightMouseUp : .otherMouseUp,
                      button: button, at: CGEvent(source: nil)?.location ?? .zero)
        }
        held.removeAll()
    }
    private static func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentAPIError(503, "Token generation failed") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func storedToken(_ replacement: String?) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.s21g.ViMouse.remote-agent",
                                    kSecAttrAccount as String: "LAN API"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        // A newly signed build may need the user's one-time approval to access
        // an existing login-keychain item. Allow SecurityAgent to present that
        // prompt instead of failing silently with errSecInteractionNotAllowed.
        read[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
        read[kSecUseOperationPrompt as String] = NSLocalizedString(
            "agent.keychain.prompt",
            comment: "Keychain access prompt"
        )
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentAPIError(503, "Keychain read failed (\(status))") }
        if replacement == nil, let data = result as? Data, let value = String(data: data, encoding: .utf8),
           value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return value }
        let value = try replacement ?? randomToken()
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var add = query.merging(values) { _, new in new }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
        add[kSecUseOperationPrompt as String] = NSLocalizedString(
            "agent.keychain.prompt",
            comment: "Keychain access prompt"
        )
        let saved = status == errSecItemNotFound ? SecItemAdd(add as CFDictionary, nil) : SecItemUpdate(query as CFDictionary, values as CFDictionary)
        guard saved == errSecSuccess else { throw AgentAPIError(503, "Keychain write failed (\(saved))") }
        return value
    }
}
