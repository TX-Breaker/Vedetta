import Foundation
import Security
import CryptoKit
import NetKit
import VedettaL10n

public enum VigiError: LocalizedError {
    case badResponse
    /// Login refused (`attemptsLeft` when the recorder tells how many tries remain before the lock).
    case wrongCredentials(attemptsLeft: Int?)
    /// Account locked by the recorder (0 = duration unknown).
    case locked(seconds: Int)
    case api(code: Int)
    case transport(String)
    case notSupported
    /// The recorder closed the new session right away (same user signed in elsewhere?): not retried immediately.
    case sessionConflict(retryAt: Date)

    public var errorDescription: String? {
        switch self {
        case .badResponse: return L("Invalid recorder response")
        case .wrongCredentials(let left):
            if let left { return L("Wrong user name or password") + " — " + L("%@ attempts left before the recorder locks the user.", String(left)) }
            return L("Wrong user name or password")
        case .locked(let s):
            if s > 0 { return L("Too many login attempts. Try again in %@ minutes.", String(max(1, (s + 59) / 60))) }
            return L("The recorder locked this user after too many attempts.")
        case .api(let code): return L("The recorder returned error %@", String(code))
        case .transport(let s): return s
        case .notSupported: return L("Feature not supported by this device")
        case .sessionConflict: return L("The recorder closed the session: the same user is probably signed in from another app. Use a dedicated user for Vedetta.")
        }
    }
}

/// HTTP transport of the VIGI API (replaced by a simulated recorder in tests).
public protocol VigiTransport: Sendable {
    /// POSTs JSON and returns the body and HTTP status. Network problems throw.
    func post(_ url: URL, body: Data, timeout: TimeInterval?) async throws -> (Data, Int)
}

/// Test hook: when set, new clients use this transport (a simulated recorder).
public enum VigiTesting {
    nonisolated(unsafe) public static var transport: VigiTransport?
}

struct URLSessionVigiTransport: VigiTransport {
    let session: URLSession
    func post(_ url: URL, body: Data, timeout: TimeInterval?) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("vigi_web", forHTTPHeaderField: "SourceType")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct VigiChannel: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var model: String?
    public var ip: String?
    public var online: Bool
    public var firmware: String?
}

public struct VigiDeviceInfo: Sendable {
    public var model: String?
    public var name: String?
    public var firmware: String?
    public var mac: String?
    public var serial: String?
}

public struct VigiRecording: Sendable, Hashable {
    public var start: Date
    public var end: Date
    /// 1 = continuous/scheduled, 2 = motion/event, 3 = alarm (as used by the NVR timeline colours).
    public var videoType: Int
}

public struct VigiEvent: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var eventType: Int
}

/// Client for the TP-Link VIGI NVR JSON API (`/stok=<token>/ds`), the same API used by the NVR web interface.
/// One instance per recorder is shared by the whole app, so every feature uses the same session.
public actor VigiClient {
    public nonisolated let host: String
    public nonisolated let port: Int
    public nonisolated let username: String
    private let password: String
    private let transport: VigiTransport
    private nonisolated let guardRef: GuardRef
    private nonisolated var accessGuard: AccessGuard? { guardRef.value }
    private var stok: String?
    private var userID: Int?
    private var loginTask: Task<Void, Error>?
    private var lastLogin: Date?
    private var conflicts = 0
    private var nextLoginAllowed: Date?
    private var loginFailures = 0
    /// Session opened by an explicit sign-in while the device is still blocked for everything else:
    /// it may be used (to read the channels) until the app adopts it.
    private var manualToken: String?
    /// User group reported at login ("root" = administrator).
    public private(set) var userGroup: String?

    public init(host: String, port: Int = 443, username: String, password: String,
                accessGuard: AccessGuard? = nil, transport: VigiTransport? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.guardRef = GuardRef(accessGuard)
        self.transport = transport ?? VigiTesting.transport ?? URLSessionVigiTransport(session: DeviceSessionDelegate.makeSession(timeout: 12))
    }

    /// Puts a session opened by the connection wizard under the device's AccessGuard when the app adopts it.
    public nonisolated func bind(to g: AccessGuard) { guardRef.value = g }

    final class GuardRef: @unchecked Sendable {
        private let lock = NSLock()
        private var g: AccessGuard?
        init(_ g: AccessGuard?) { self.g = g }
        var value: AccessGuard? {
            get { lock.withLock { g } }
            set { lock.withLock { g = newValue } }
        }
    }

    private var baseURL: String { port == 443 ? "https://\(host)" : "https://\(host):\(port)" }
    private var now: Date { accessGuard?.clock.now() ?? Date() }

    public var hasSession: Bool { stok != nil }
    public var isAdministrator: Bool { ["root", "admin", "administrator"].contains(userGroup?.lowercased() ?? "") }

    // MARK: Transport

    private func post(path: String, body: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw VigiError.badResponse }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.post(url, body: payload, timeout: timeout)
        } catch {
            // A refused (changed) certificate surfaces as a cancelled request: check it first.
            if TrustStore.shared.refusedCertificate(host: host, port: port, error: error) { throw TrustError.certificateChanged(host: host) }
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw VigiError.transport(L("Recorder not reachable (%@): %@", host, error.localizedDescription))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 401 { return ["error_code": -40401] }   // session expired
            throw VigiError.badResponse
        }
        return obj
    }

    /// A request with the session token: network failures are reported to the guard (never a new login).
    private func send(_ body: [String: Any], token: String?) async throws -> [String: Any] {
        do {
            return try await post(path: "/stok=\(token ?? "")/ds", body: body)
        } catch VigiError.transport(let why) {
            accessGuard?.report(.network(why), action: "API")
            throw VigiError.transport(why)
        }
    }

    /// Authenticated call. Logs in only when there is no session yet or the recorder says it expired.
    public func call(_ method: String, _ payload: [String: Any]) async throws -> [String: Any] {
        if let g = accessGuard {
            if g.state.isUsable { manualToken = nil }
            if manualToken == nil || stok != manualToken { try g.admitRequest() }
        }
        if stok == nil { try await ensureLogin() }
        var body = payload
        body["method"] = method
        let token = stok
        var result = try await send(body, token: token)
        var code = JSONAccess.int(result["error_code"]) ?? -1
        if code == -40401 {
            // Only the first request that finds this session closed handles it (parallel requests share the result).
            if stok == token {
                stok = nil
                if let last = lastLogin {
                    // Sessions that keep dying soon after the login: another client with the same user is
                    // probably taking over. Do not ping-pong: re-login with growing pauses (5 s … 5 min).
                    let lived = now.timeIntervalSince(last)
                    conflicts = lived < 300 ? conflicts + 1 : 0
                    if lived < 30 || conflicts >= 2 {
                        let wait = (accessGuard?.backoff ?? .standard).delay(attempt: max(0, conflicts - 1), random: Double.random(in: 0...1))
                        nextLoginAllowed = now.addingTimeInterval(wait)
                        accessGuard?.note("session", "closed by the recorder",
                                          "\(Int(lived)) s after login (same user signed in elsewhere?); new login not before \(Int(wait)) s")
                    }
                }
            }
            if conflicts > 0, let next = nextLoginAllowed, now < next { throw VigiError.sessionConflict(retryAt: next) }
            try await ensureLogin()
            result = try await send(body, token: stok)
            code = JSONAccess.int(result["error_code"]) ?? -1
        }
        guard code == 0 else { throw VigiError.api(code: code) }
        // The pause grows while sessions keep being closed; it resets once a session lasts.
        if let last = lastLogin, now.timeIntervalSince(last) > 120 { conflicts = 0 }
        accessGuard?.report(.confirmed)
        return result
    }

    // MARK: Login

    /// Coalesces concurrent logins: every feature waits for the same attempt.
    private func ensureLogin() async throws {
        if stok != nil { return }
        if let t = loginTask { return try await t.value }
        if let next = nextLoginAllowed, now < next {
            if conflicts > 0 { throw VigiError.sessionConflict(retryAt: next) }
            throw VigiError.transport(L("Recorder not responding. Next attempt at %@.", DateFormatter.localizedString(from: next, dateStyle: .none, timeStyle: .medium)))
        }
        let t = Task { try await self.performLogin(manual: false) }
        loginTask = t
        defer { loginTask = nil }
        try await t.value
    }

    /// Logs in only if there is no session yet (automatic attempt, subject to the guard).
    /// `reserved`: called as the device's first check (the guard reserved the slot for it); with a session
    /// already open it only confirms it with a light request.
    public func ensureSession(reserved: Bool = false) async throws {
        guard reserved else { return try await ensureLogin() }
        if stok != nil {
            _ = try await call("get", ["device_info": ["name": ["info"]]])
            return
        }
        if loginTask != nil { return }   // a login already waits for the slot: let it go first
        let t = Task { try await self.performLogin(manual: false, reserved: true) }
        loginTask = t
        defer { loginTask = nil }
        try await t.value
    }

    /// Explicit login requested by the user (connection wizard, sign-in): one attempt,
    /// allowed even when automatic attempts are stopped.
    public func login() async throws { try await performLogin(manual: true) }

    private func performLogin(manual: Bool, reserved: Bool = false) async throws {
        do {
            if let g = accessGuard {
                try await g.credentialed("login \(username)", manual: manual, reserved: reserved, {
                    try await g.loginMutex.withLock { try await self.exchange() }
                }, outcome: Self.outcome)
            } else {
                try await exchange()
            }
            loginFailures = 0
            nextLoginAllowed = nil
            lastLogin = now
            if manual, let g = accessGuard, !g.state.isUsable { manualToken = stok }
        } catch {
            if case VigiError.transport = error {
                // Unanswered login: pace the next automatic one.
                loginFailures += 1
                nextLoginAllowed = now.addingTimeInterval((accessGuard?.backoff ?? .standard).delay(attempt: loginFailures - 1, random: Double.random(in: 0...1)))
            } else if case VigiError.badResponse = error {
                loginFailures += 1
                nextLoginAllowed = now.addingTimeInterval((accessGuard?.backoff ?? .standard).delay(attempt: loginFailures - 1, random: Double.random(in: 0...1)))
            }
            throw error
        }
    }

    static func outcome(_ r: Result<Void, Error>) -> AccessOutcome {
        switch r {
        case .success: return .confirmed
        case .failure(let e):
            switch e {
            case VigiError.wrongCredentials(let left):
                return .rejected(left.map { L("The recorder refused the user name or password (%@ attempts left before the lock). Automatic attempts are stopped.", String($0)) }
                                 ?? L("The recorder refused the user name or password. Automatic attempts are stopped to avoid locking the account."))
            case VigiError.locked(let s): return .locked(seconds: s > 0 ? s : nil)
            case VigiError.transport(let m): return .network(m)
            default: return .neutral
            }
        }
    }

    /// Challenge + encrypted login (VIGI firmware keeps a single nonce: callers serialize this).
    private func exchange() async throws {
        let info = try await post(path: "/", body: ["method": "do", "user_management": ["get_encrypt_info": NSNull()]])
        var params = JSONAccess.dict(info["data"]) ?? [:]
        if params["key"] == nil, let result = JSONAccess.dict(info["result"]) { params = result }
        if params["key"] == nil {
            // Older firmware: the challenge comes back from a bare login attempt.
            let probe = try await post(path: "/", body: ["method": "do", "login": ["username": username]])
            params = JSONAccess.dict(probe["data"]) ?? [:]
        }
        // Locked: stop before sending the password.
        if let secLeft = Self.lockSeconds(in: info), secLeft > 0 { throw VigiError.locked(seconds: secLeft) }

        let types = (JSONAccess.array(params["encrypt_type"]) ?? []).compactMap(JSONAccess.string)
        let encryptType = types.compactMap(Int.init).max().map(String.init) ?? "2"
        let nonce = JSONAccess.string(params["nonce"]) ?? ""
        let keyString = (JSONAccess.string(params["key_2"]) ?? JSONAccess.string(params["key"]) ?? "").removingPercentEncoding ?? ""
        let usesKey2 = params["key_2"] != nil

        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        var passwordField = hash
        if encryptType == "2" || types.contains("2") {
            guard !keyString.isEmpty else { throw VigiError.badResponse }
            let plain = nonce.isEmpty ? hash : "\(hash):\(nonce)"
            passwordField = try Self.rsaEncrypt(plain, publicKeyBase64: keyString)
        }
        var login: [String: Any] = [
            "encrypt_type": encryptType,
            "passwdType": "sha256",
            "password": Self.encodeURIComponent(passwordField),
            "username": Self.encodeURIComponent(username),
        ]
        if usesKey2 { login["keyType"] = "1" }
        let result = try await post(path: "/", body: ["method": "do", "login": login])
        let code = JSONAccess.int(result["error_code"]) ?? -1
        if code == 0, let token = JSONAccess.string(result["stok"]) ?? JSONAccess.string(JSONAccess.value(result, "result", "stok")) {
            stok = token
            userGroup = JSONAccess.string(result["user_group"]) ?? JSONAccess.string(JSONAccess.value(result, "result", "user_group"))
            return
        }
        throw Self.loginFailure(result)
    }

    /// Error codes the VIGI/TP-Link firmware uses for a locked account.
    static let lockCodes: Set<Int> = [-40404, -40407]

    /// Seconds until the account unlocks, wherever the firmware puts it.
    static func lockSeconds(in response: [String: Any]) -> Int? {
        let places = [response, JSONAccess.dict(response["data"]) ?? [:], JSONAccess.dict(response["result"]) ?? [:]]
        for p in places {
            for k in ["sec_left", "lock_time", "left_time", "unlock_time", "remain_time"] {
                if let v = JSONAccess.int(p[k]), v > 0 { return v }
            }
        }
        return nil
    }

    /// The recorder answered a login with an error: locked, or credentials refused.
    static func loginFailure(_ result: [String: Any]) -> VigiError {
        let data = JSONAccess.dict(result["data"]) ?? [:]
        if let s = lockSeconds(in: result) { return .locked(seconds: s) }
        let codes = [JSONAccess.int(result["error_code"]), JSONAccess.int(data["code"])].compactMap { $0 }
        if codes.contains(where: lockCodes.contains) { return .locked(seconds: 0) }
        let text = (JSONAccess.string(result["msg"]) ?? JSONAccess.string(data["msg"]) ?? "").lowercased()
        if text.contains("lock") { return .locked(seconds: 0) }
        var left: Int?
        for k in ["attempts", "remain_times", "left_times", "attempts_left", "remaining_attempts"] {
            if let v = JSONAccess.int(data[k]) ?? JSONAccess.int(result[k]) { left = v; break }
        }
        return .wrongCredentials(attemptsLeft: left)
    }

    /// Ends the session on the recorder. Never logs in; gives up quickly when the recorder does not answer.
    @discardableResult
    public func logout(timeout: TimeInterval = 4) async -> Bool {
        loginTask?.cancel()
        guard let token = stok else { return false }
        stok = nil
        userID = nil
        do {
            let r = try await post(path: "/stok=\(token)/ds", body: ["method": "do", "system": ["logout": "null"]], timeout: timeout)
            let ok = (JSONAccess.int(r["error_code"]) ?? -1) == 0
            accessGuard?.note("logout \(username)", ok ? "ok" : "error", ok ? nil : "code \(JSONAccess.int(r["error_code"]) ?? -1)")
            return ok
        } catch {
            accessGuard?.note("logout \(username)", "not reached", error.localizedDescription)
            return false
        }
    }

    /// Forgets the session locally (the recorder is unreachable or the account is locked).
    public func dropSession() {
        loginTask?.cancel()
        stok = nil
        userID = nil
    }

    /// Asks the recorder, without credentials, whether the account is locked; returns the seconds left.
    public func lockStatus() async -> Int? {
        guard let info = try? await post(path: "/", body: ["method": "do", "user_management": ["get_encrypt_info": NSNull()]], timeout: 5) else { return nil }
        return Self.lockSeconds(in: info)
    }

    /// true = the session (or a new login) works, false = credentials refused, nil = cannot tell.
    public func credentialsStillValid() async -> Bool? {
        do {
            _ = try await call("get", ["device_info": ["name": ["info"]]])
            return true
        } catch VigiError.wrongCredentials {
            return false
        } catch let e as AccessBlocked {
            if case .rejected = e.state { return false }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Crypto helpers

    static func encodeURIComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// RSA PKCS#1 v1.5 encryption with a base64 SubjectPublicKeyInfo (as JSEncrypt does).
    static func rsaEncrypt(_ plain: String, publicKeyBase64: String) throws -> String {
        let cleaned = publicKeyBase64
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: cleaned) else { throw VigiError.badResponse }
        let pkcs1 = DER.rsaPublicKeyFromSPKI(der) ?? der
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else { throw VigiError.badResponse }
        guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(plain.utf8) as CFData, &error) as Data? else {
            throw VigiError.badResponse
        }
        return enc.base64EncodedString()
    }

    // MARK: Device

    public func deviceInfo() async throws -> VigiDeviceInfo {
        let r = try await call("get", ["device_info": ["name": ["info"]]])
        let info = JSONAccess.dict(JSONAccess.value(r, "device_info", "info")) ?? [:]
        func s(_ keys: String...) -> String? {
            for k in keys { if let v = JSONAccess.string(info[k]), !v.isEmpty { return v.removingPercentEncoding ?? v } }
            return nil
        }
        return VigiDeviceInfo(model: s("device_model", "model", "dev_model", "hw_model"),
                              name: s("device_name", "dev_name", "device_alias", "name"),
                              firmware: s("sw_version", "firmware_version", "fw_version"),
                              mac: s("mac", "device_mac"), serial: s("serial_number", "sn", "dev_id"))
    }

    public func channels() async throws -> [VigiChannel] {
        let r = try await call("get", ["chm": ["table": ["added_dev"]]])
        let items = JSONAccess.flattenKeyedList(JSONAccess.value(r, "chm", "added_dev"))
        var channels: [VigiChannel] = []
        for item in items {
            guard let id = JSONAccess.int(item["id"]) ?? JSONAccess.int(item["chn_id"]) ?? JSONAccess.int(item["channel"]) else { continue }
            func str(_ k: String) -> String? {
                guard let v = JSONAccess.string(item[k]), !v.isEmpty else { return nil }
                return v.removingPercentEncoding ?? v
            }
            let alias = str("alias")
            let name = str("name")
            let online = (JSONAccess.string(item["online"]) ?? "1") == "1"
            channels.append(VigiChannel(id: id, name: alias ?? name ?? L("Channel %@", String(id)), model: name,
                                        ip: str("ip"), online: online, firmware: str("firmware_version")))
        }
        return channels.sorted { $0.id < $1.id }
    }

    public func currentUserID() async throws -> Int {
        if let userID { return userID }
        let r = try await call("do", ["system": ["get_user_id": NSNull()]])
        let id = JSONAccess.int(r["user_id"]) ?? JSONAccess.int(JSONAccess.value(r, "system", "user_id")) ?? 1
        userID = id
        return id
    }

    // MARK: Recordings

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    /// Days ("YYYYMMDD") with recordings for the channel between two dates.
    public func recordingDays(channel: Int, from: Date, to: Date, calendar: Calendar = .current) async throws -> Set<String> {
        let r = try await call("do", ["playback": ["search_year_utility": [
            "channel": [channel],
            "start_date": Self.dayString(from, calendar: calendar),
            "end_date": Self.dayString(to, calendar: calendar),
        ]]])
        var days = Set<String>()
        for item in JSONAccess.flattenKeyedList(JSONAccess.value(r, "playback", "search_results")) {
            if let d = JSONAccess.string(item["date"]) { days.insert(d.replacingOccurrences(of: "-", with: "")) }
        }
        return days
    }

    /// Recording segments of one channel for the local day containing `day`.
    public func recordings(channel: Int, day: Date, calendar: Calendar = .current) async throws -> [VigiRecording] {
        let uid = try await currentUserID()
        let date = Self.dayString(day, calendar: calendar)
        var all: [VigiRecording] = []
        var start = 0
        for _ in 0..<40 {
            let r = try await call("do", ["playback": ["search_video_utility": [
                "id": uid, "channel": channel, "date": date, "dst_type": 1,
                "start_index": start, "end_index": start + 49, "stream": 2, "pre_search": 1,
            ] as [String: Any]]])
            let items = JSONAccess.flattenKeyedList(JSONAccess.value(r, "playback", "search_video_results"))
            for item in items {
                guard let s = JSONAccess.double(item["startTime"] ?? item["start_time"]),
                      let e = JSONAccess.double(item["endTime"] ?? item["end_time"]), e > s else { continue }
                let type = JSONAccess.int(item["videoType"] ?? item["vedio_type"] ?? item["video_type"] ?? item["type"]) ?? 1
                all.append(VigiRecording(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e), videoType: type))
            }
            if items.count < 50 { break }
            start += 50
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Event-tagged segments (motion, person, vehicle...) between two instants.
    public func events(channel: Int, from: Date, to: Date) async throws -> [VigiEvent] {
        let uid = try await currentUserID()
        let searchID = Int.random(in: 1...10000)
        var all: [VigiEvent] = []
        var start = 0
        for _ in 0..<20 {
            let r = try await call("do", ["playback": ["search_video_event_playback": [
                "client_id": uid, "search_id": searchID,
                "event_type_high32": 4294967295, "event_type_low32": 4294967295,
                "channel_map": [channel],
                "start_time": Int(from.timeIntervalSince1970), "end_time": Int(to.timeIntervalSince1970),
                "start_index": start, "end_index": start + 99,
            ] as [String: Any]]])
            let items = JSONAccess.flattenKeyedList(JSONAccess.value(r, "playback", "search_video_results"))
            for item in items {
                guard let s = JSONAccess.double(item["startTime"] ?? item["start_time"]),
                      let e = JSONAccess.double(item["endTime"] ?? item["end_time"]) else { continue }
                let type = JSONAccess.int(item["eventType"] ?? item["event_type"]) ?? 1
                all.append(VigiEvent(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: max(e, s + 1)), eventType: type))
            }
            if items.count < 100 { break }
            start += 100
        }
        return all.sorted { $0.start < $1.start }
    }
}

/// Minimal DER reader to extract the PKCS#1 RSAPublicKey from a SubjectPublicKeyInfo.
enum DER {
    static func rsaPublicKeyFromSPKI(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var i = 0
        func readLength() -> Int? {
            guard i < bytes.count else { return nil }
            var len = Int(bytes[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, i + n <= bytes.count else { return nil }
                len = 0
                for _ in 0..<n { len = len << 8 | Int(bytes[i]); i += 1 }
            }
            return len
        }
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }   // SEQUENCE
        i += 1; guard readLength() != nil else { return nil }
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }   // AlgorithmIdentifier
        i += 1; guard let algLen = readLength() else { return nil }
        i += algLen
        guard i < bytes.count, bytes[i] == 0x03 else { return nil }   // BIT STRING
        i += 1; guard let bitLen = readLength(), i + bitLen <= bytes.count, bitLen > 1 else { return nil }
        i += 1 // unused-bits byte
        return Data(bytes[i..<(i + bitLen - 1)])
    }
}
