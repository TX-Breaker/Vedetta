import Foundation
import Security
import CryptoKit
import NetKit
import VedettaL10n

public enum VigiError: LocalizedError {
    case badResponse
    case wrongCredentials
    case locked(seconds: Int)
    case api(code: Int)
    case transport(String)
    case notSupported

    public var errorDescription: String? {
        switch self {
        case .badResponse: return L("Invalid recorder response")
        case .wrongCredentials: return L("Wrong user name or password")
        case .locked(let s): return L("Too many login attempts. Try again in %@ minutes.", String(max(1, s / 60)))
        case .api(let code): return L("The recorder returned error %@", String(code))
        case .transport(let s): return s
        case .notSupported: return L("Feature not supported by this device")
        }
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
public actor VigiClient {
    public nonisolated let host: String
    public nonisolated let port: Int
    private let username: String
    private let password: String
    private let session: URLSession
    private var stok: String?
    private var userID: Int?
    private var loginTask: Task<Void, Error>?

    public init(host: String, port: Int = 443, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.session = DeviceSessionDelegate.makeSession(timeout: 12)
    }

    private var baseURL: String { port == 443 ? "https://\(host)" : "https://\(host):\(port)" }

    // MARK: Transport

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw VigiError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("vigi_web", forHTTPHeaderField: "SourceType")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            if let host = TrustStore.shared.lastMismatchHost, host == self.host { throw TrustError.certificateChanged(host: host) }
            throw VigiError.transport(L("Recorder not reachable (%@): %@", host, error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { stok = nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VigiError.badResponse }
        return obj
    }

    /// Authenticated call. Re-logins once when the session expired.
    public func call(_ method: String, _ payload: [String: Any]) async throws -> [String: Any] {
        if stok == nil { try await ensureLogin() }
        var body = payload
        body["method"] = method
        var result = try await post(path: "/stok=\(stok ?? "")/ds", body: body)
        var code = JSONAccess.int(result["error_code"]) ?? -1
        if code == -40401 {
            stok = nil
            try await ensureLogin()
            result = try await post(path: "/stok=\(stok ?? "")/ds", body: body)
            code = JSONAccess.int(result["error_code"]) ?? -1
        }
        guard code == 0 else { throw VigiError.api(code: code) }
        return result
    }

    // MARK: Login

    /// Coalesces concurrent logins: a second login could invalidate the first session on some firmware.
    private func ensureLogin() async throws {
        if stok != nil { return }
        if let t = loginTask { return try await t.value }
        let t = Task { try await self.login() }
        loginTask = t
        defer { loginTask = nil }
        try await t.value
    }

    public func login() async throws {
        let info = try await post(path: "/", body: ["method": "do", "user_management": ["get_encrypt_info": NSNull()]])
        var params = JSONAccess.dict(info["data"]) ?? [:]
        if params["key"] == nil, let result = JSONAccess.dict(info["result"]) { params = result }
        if params["key"] == nil {
            // Older firmware: the challenge comes back from a bare login attempt.
            let probe = try await post(path: "/", body: ["method": "do", "login": ["username": username]])
            params = JSONAccess.dict(probe["data"]) ?? [:]
        }
        if let secLeft = JSONAccess.int(params["sec_left"]), secLeft > 0 { throw VigiError.locked(seconds: secLeft) }

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
            return
        }
        let data = JSONAccess.dict(result["data"]) ?? [:]
        if let secLeft = JSONAccess.int(data["sec_left"]), secLeft > 0 { throw VigiError.locked(seconds: secLeft) }
        throw VigiError.wrongCredentials
    }

    public func logout() async {
        guard stok != nil else { return }
        _ = try? await call("do", ["system": ["logout": "null"]])
        stok = nil
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
