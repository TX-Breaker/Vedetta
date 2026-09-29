import Foundation
import Network
import Security
import CryptoKit
import NetKit
@testable import VigiKit

/// Virtual time: sleepers wake only when the test advances the clock.
final class ManualClock: AccessClock, @unchecked Sendable {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (wake: Date, cont: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled = Set<UUID>()

    init() { current = start }

    func now() -> Date { lock.withLock { current } }
    var elapsed: Double { now().timeIntervalSince(start) }

    func sleep(seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let cancelNow: Bool = lock.withLock {
                    if cancelled.remove(id) != nil { return true }
                    sleepers[id] = (current.addingTimeInterval(seconds), c)
                    return false
                }
                if cancelNow { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                if let e = sleepers.removeValue(forKey: id) { return e.cont }
                cancelled.insert(id)
                return nil
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward, waking the sleepers in order and letting them run.
    func advance(by seconds: Double) async {
        let target = now().addingTimeInterval(seconds)
        while true {
            let next: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let (id, e) = sleepers.filter({ $0.value.wake <= target }).min(by: { $0.value.wake < $1.value.wake }) else { return nil }
                sleepers[id] = nil
                current = max(current, e.wake)
                return e.cont
            }
            guard let next else { break }
            next.resume()
            await settle()
        }
        lock.withLock { current = target }
        await settle()
    }

    /// Lets woken tasks run (they only wait on in-memory fakes).
    func settle() async {
        for _ in 0..<6 { try? await Task.sleep(nanoseconds: 3_000_000) }
    }
}

/// Simulated TP-Link VIGI recorder API: single login nonce, sessions, lockout after repeated failures.
final class FakeNVR: VigiTransport, @unchecked Sendable {
    private let lock = NSLock()
    let clock: AccessClock
    var users: [String: String]
    /// Real recorders lock the user after a few consecutive failures (and sound the buzzer).
    var lockThreshold = 5
    var lockSeconds = 1800
    var lockReportsSeconds = true
    var channelCount = 4

    private let privateKey: SecKey
    private let publicKeyBase64: String
    private var nonce: String?
    private var failures = 0
    private var offlineUntil: Date?
    private var lockedUntil: Date?
    private var lockedForever = false

    private(set) var loginAttempts = 0
    private(set) var failedLogins = 0
    private(set) var requestsWhileOffline = 0
    private(set) var loginsWhileOffline = 0
    private(set) var logouts = 0
    private(set) var sessions: [String: String] = [:]   // stok -> user
    private(set) var buzzerAlarms = 0

    init(clock: AccessClock, users: [String: String]) {
        self.clock = clock
        self.users = users
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
        var error: Unmanaged<CFError>?
        privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        let pub = SecKeyCopyPublicKey(privateKey)!
        publicKeyBase64 = (SecKeyCopyExternalRepresentation(pub, &error) as Data?)!.base64EncodedString()
    }

    // MARK: Control

    func goOffline(for seconds: Double) { lock.withLock { offlineUntil = clock.now().addingTimeInterval(seconds) } }
    func goOnline() { lock.withLock { offlineUntil = nil } }
    var reachable: Bool { lock.withLock { isOnline } }
    private var isOnline: Bool { offlineUntil.map { clock.now() >= $0 } ?? true }
    func expireSessions() { lock.withLock { sessions.removeAll() } }
    func lockUser(seconds: Int?, reportSeconds: Bool) {
        lock.withLock {
            if let seconds { lockedUntil = clock.now().addingTimeInterval(TimeInterval(seconds)) } else { lockedForever = true }
            lockReportsSeconds = reportSeconds
        }
    }
    var isLocked: Bool { lock.withLock { lockedNow } }
    private var lockedNow: Bool { lockedForever || (lockedUntil.map { clock.now() < $0 } ?? false) }
    func activeUsers() -> [String] { lock.withLock { sessions.values.sorted() } }

    // MARK: Transport

    func post(_ url: URL, body: Data, timeout: TimeInterval?) async throws -> (Data, Int) {
        let req = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let reply: [String: Any] = try lock.withLock {
            guard isOnline else {
                requestsWhileOffline += 1
                if req["login"] != nil { loginsWhileOffline += 1 }
                throw URLError(.timedOut)
            }
            return url.path == "/" ? anonymous(req) : authenticated(url.path, req)
        }
        return (try JSONSerialization.data(withJSONObject: reply), 200)
    }

    private func remaining() -> Int { lockedUntil.map { max(1, Int($0.timeIntervalSince(clock.now()))) } ?? 0 }

    private func anonymous(_ req: [String: Any]) -> [String: Any] {
        if (req["user_management"] as? [String: Any])?["get_encrypt_info"] != nil {
            nonce = UUID().uuidString.prefix(8).description
            return ["error_code": -40401, "data": ["code": -40401, "encrypt_type": ["2"], "key": publicKeyBase64, "nonce": nonce!]]
        }
        guard let login = req["login"] as? [String: Any], login["password"] != nil else { return ["error_code": -40101] }
        loginAttempts += 1
        if lockedNow {
            buzzerAlarms += 1
            var data: [String: Any] = ["code": -40404]
            if lockReportsSeconds, lockedUntil != nil { data["sec_left"] = remaining() }
            return ["error_code": -40404, "data": data]
        }
        let user = (login["username"] as? String)?.removingPercentEncoding ?? ""
        var plain = ""
        if let field = (login["password"] as? String)?.removingPercentEncoding, let blob = Data(base64Encoded: field),
           let dec = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, blob as CFData, nil) as Data? {
            plain = String(decoding: dec, as: UTF8.self)
        }
        let used = nonce
        nonce = nil   // single nonce: a parallel login makes this one fail
        if let pass = users[user], let used, plain == VigiTestsCrypto.hash(pass) + ":" + used {
            failures = 0
            let stok = UUID().uuidString
            sessions[stok] = user
            return ["error_code": 0, "stok": stok, "user_group": user == "admin" ? "root" : "user"]
        }
        failedLogins += 1
        failures += 1
        buzzerAlarms += 1
        if failures >= lockThreshold {
            lockedUntil = clock.now().addingTimeInterval(TimeInterval(lockSeconds))
            return ["error_code": -40404, "data": ["code": -40404, "sec_left": lockSeconds]]
        }
        return ["error_code": -40210, "data": ["code": -40210, "attempts": lockThreshold - failures]]
    }

    private func authenticated(_ path: String, _ req: [String: Any]) -> [String: Any] {
        let token = path.replacingOccurrences(of: "/stok=", with: "").replacingOccurrences(of: "/ds", with: "")
        guard sessions[token] != nil else { return ["error_code": -40401] }
        if let system = req["system"] as? [String: Any] {
            if system["logout"] != nil { sessions[token] = nil; logouts += 1; return ["error_code": 0] }
            if system["get_user_id"] != nil { return ["error_code": 0, "user_id": 3] }
        }
        if req["device_info"] != nil {
            return ["error_code": 0, "device_info": ["info": ["device_model": "VIGI NVR2016H(UN)", "device_name": "Fake%20NVR", "sw_version": "1.6.0"]]]
        }
        if req["chm"] != nil {
            let list = (1...channelCount).map { ["added_dev_\($0)": ["id": "\($0)", "alias": "Cam \($0)", "online": "1"]] }
            return ["error_code": 0, "chm": ["added_dev": list]]
        }
        return ["error_code": 0, "playback": ["search_video_results": [] as [Any], "search_results": [] as [Any]]]
    }
}

enum VigiTestsCrypto {
    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }
}

/// Minimal RTSP server (Basic auth, H.264 SDP, interleaved TCP) that records who connects.
final class FakeRTSPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake.rtsp")
    var users: [String: String]
    /// Paths each user may open (nil = all), like a recorder user limited to some cameras.
    var permissions: [String: [String]] = [:]
    private(set) var port: UInt16 = 0
    private(set) var connections = 0
    private(set) var refusedCredentials = 0
    private(set) var teardowns = 0
    private var playing: [ObjectIdentifier: String] = [:]

    init(users: [String: String]) { self.users = users }

    var activeUsers: [String] { lock.withLock { playing.values.sorted() } }
    var stats: (connections: Int, refused: Int, teardowns: Int) { lock.withLock { (connections, refusedCredentials, teardowns) } }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                if case .ready = state, !resumed { resumed = true; c.resume() }
            }
            l.start(queue: queue)
        }
        port = l.port?.rawValue ?? 0
    }

    func stop() { listener?.cancel() }

    private func accept(_ c: NWConnection) {
        lock.withLock { connections += 1 }
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed(c)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func closed(_ c: NWConnection) { _ = lock.withLock { playing.removeValue(forKey: ObjectIdentifier(c)) } }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                buf.removeSubrange(..<r.upperBound)
                self.handle(head, on: c)
            }
            if done || error != nil { self.closed(c); c.cancel(); return }
            self.receive(c, buffer: buf)
        }
    }

    private func handle(_ head: String, on c: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return }
        let method = String(parts[0]), url = String(parts[1])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let cseq = headers["cseq"] ?? "0"
        func send(_ status: String, _ extra: [String] = [], body: String = "") {
            var out = ["RTSP/1.0 \(status)", "CSeq: \(cseq)"] + extra
            if !body.isEmpty { out.append("Content-Length: \(body.utf8.count)") }
            c.send(content: Data((out.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8), completion: .contentProcessed { _ in })
        }
        if method == "OPTIONS" { return send("200 OK", ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"]) }
        guard let auth = headers["authorization"], auth.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(auth.dropFirst(6))).map({ String(decoding: $0, as: UTF8.self) }),
              let colon = decoded.firstIndex(of: ":") else {
            return send("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"fake\""])
        }
        let user = String(decoded[..<colon]), pass = String(decoded[decoded.index(after: colon)...])
        let allowed = permissions[user].map { list in list.contains { url.contains($0) } } ?? true
        guard users[user] == pass, allowed else {
            lock.withLock { refusedCredentials += 1 }
            return send("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"fake\""])
        }
        switch method {
        case "DESCRIBE":
            let sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Fake\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:trackID=1\r\n"
            send("200 OK", ["Content-Type: application/sdp", "Content-Base: \(url)/"], body: sdp)
        case "SETUP":
            send("200 OK", ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1", "Session: 4242;timeout=60"])
        case "PLAY":
            lock.withLock { playing[ObjectIdentifier(c)] = user }
            send("200 OK", ["Session: 4242", "Range: npt=0.000-"])
        case "TEARDOWN":
            lock.withLock { teardowns += 1; playing[ObjectIdentifier(c)] = nil }
            send("200 OK", ["Session: 4242"])
        default:
            send("200 OK", ["Session: 4242"])
        }
    }
}
