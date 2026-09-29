import Foundation
import Network
import VedettaL10n

public struct RTSPResponse: Sendable {
    public var statusCode: Int
    public var reason: String
    public var headers: [(String, String)]
    public var body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
    public func headers(named name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }
}

public enum RTSPError: LocalizedError, Sendable {
    case invalidURL
    case connectionFailed(String)
    /// The device did not accept the TCP connection (down, unplugged, wrong address).
    case unreachable(String)
    case timeout(String)
    case unauthorized
    case status(Int, String)
    case noSupportedTrack
    case closed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return L("Invalid stream address")
        case .connectionFailed(let s): return L("Connection failed: %@", s)
        case .unreachable(let s): return L("Device not reachable: %@", s)
        case .timeout(let what): return L("No response (%@)", what)
        case .unauthorized: return L("Wrong user name or password")
        case .status(let code, let reason): return L("Device error %@ %@", String(code), reason)
        case .noSupportedTrack: return L("Unsupported video format")
        case .closed: return L("Connection closed by the device")
        }
    }
}

public struct RTSPStreamDescription: Sendable {
    public var videoCodec: VideoCodec?
    public var videoClockRate: Int
    public var videoParameterSets: VideoParameterSets
    public var audio: AudioTrackInfo?
    public var sdp: String
    public var scaleAccepted: Double?
}

/// Minimal, efficient RTSP 1.0 client using RTP over TCP (interleaved).
/// All callbacks are delivered on `queue`.
public final class RTSPClient: @unchecked Sendable {
    public struct Options: Sendable {
        public var url: URL
        public var username: String?
        public var password: String?
        public var wantAudio: Bool = true
        /// `Range` header for the first PLAY (nil = omit).
        public var range: String? = "npt=0.000-"
        public var scale: Double?
        public var extraPlayHeaders: [String: String] = [:]
        /// Headers added to every request (e.g. `Require: onvif-replay`).
        public var extraHeaders: [String: String] = [:]
        public var connectTimeout: TimeInterval = 8
        public var requestTimeout: TimeInterval = 10
        public var userAgent = "Vedetta/1.0"

        public init(url: URL, username: String? = nil, password: String? = nil) {
            self.url = url
            self.username = username
            self.password = password
        }
    }

    public let options: Options
    public let queue: DispatchQueue

    public var onDescribed: ((RTSPStreamDescription) -> Void)?
    public var onVideo: ((AccessUnit) -> Void)?
    public var onParameterSets: ((VideoParameterSets) -> Void)?
    public var onAudio: ((AudioFrame) -> Void)?
    /// Called once when the session ends (nil error = orderly end of stream).
    public var onClosed: ((Error?) -> Void)?

    private var connection: NWConnection?
    private var cseq = 0
    private var pending: [Int: CheckedContinuation<RTSPResponse, Error>] = [:]
    private var inbox = Data()
    private var authenticator: Authenticator?
    private var sessionID: String?
    private var sessionTimeout: TimeInterval = 60
    private var keepAliveTimer: DispatchSourceTimer?
    private var supportsGetParameter = true
    private var contentBase: String?
    private var videoChannel: UInt8 = 0
    private var audioChannel: UInt8 = 2
    private var videoDepacketizer: VideoDepacketizer?
    private var audioDepacketizer: AudioDepacketizer?
    private var closed = false
    private var playing = false
    public private(set) var receivedBytes: Int = 0
    private let acceptLock = NSLock()
    private var _credentialsAccepted = false
    /// True once the device answered a request carrying our credentials with something other than 401.
    public var credentialsAccepted: Bool { acceptLock.withLock { _credentialsAccepted } }

    public init(options: Options, queue: DispatchQueue? = nil) {
        self.options = options
        self.queue = queue ?? DispatchQueue(label: "vedetta.rtsp", qos: .userInitiated)
        if let u = options.username, !u.isEmpty {
            authenticator = Authenticator(username: u, password: options.password ?? "")
        }
    }

    deinit { connection?.cancel() }

    // MARK: Public API

    /// Connects, negotiates and starts playing. Throws on setup failure.
    public func start() async throws {
        try await connect()
        let describe = try await request("DESCRIBE", url: options.url.absoluteString, headers: ["Accept": "application/sdp"])
        guard describe.statusCode == 200 else { throw statusError(describe) }
        if let base = describe.header("Content-Base") ?? describe.header("Content-Location") {
            contentBase = base
        }
        if let pub = describe.header("Public") { supportsGetParameter = pub.uppercased().contains("GET_PARAMETER") }
        let sdpText = String(decoding: describe.body, as: UTF8.self)
        let sdp = SDPSession.parse(sdpText)

        var desc = RTSPStreamDescription(videoCodec: nil, videoClockRate: 90000,
                                         videoParameterSets: .init(), audio: nil, sdp: sdpText)
        var setupCount = 0

        if let video = sdp.media.first(where: { m in m.type == "video" && m.payloadTypes.contains { pt in
            let e = m.map(for: pt)?.encoding ?? ""; return e == "H264" || e == "H265" || e == "HEVC" } }) {
            let pt = video.payloadTypes.first { let e = video.map(for: $0)?.encoding ?? ""; return e == "H264" || e == "H265" || e == "HEVC" }!
            let map = video.map(for: pt)!
            let codec: VideoCodec = map.encoding == "H264" ? .h264 : .h265
            let sprop = VideoDepacketizer.parameterSets(codec: codec, fmtp: video.fmtp[pt] ?? [:])
            let dep = VideoDepacketizer(codec: codec, sprop: sprop)
            dep.onParameterSetsChanged = { [weak self] ps in self?.onParameterSets?(ps) }
            let channels = try await setupTrack(control: video.control, sdpControl: sdp.control, interleaved: 0)
            videoChannel = channels
            videoDepacketizer = dep
            desc.videoCodec = codec
            desc.videoClockRate = map.clockRate
            desc.videoParameterSets = sprop
            setupCount += 1
        }

        if options.wantAudio,
           let audio = sdp.media.first(where: { $0.type == "audio" }),
           let pt = audio.payloadTypes.first(where: { audio.map(for: $0) != nil }),
           let map = audio.map(for: pt),
           let info = AudioDepacketizer.trackInfo(for: map, fmtp: audio.fmtp[pt] ?? [:]) {
            do {
                let channels = try await setupTrack(control: audio.control, sdpControl: sdp.control, interleaved: 2)
                audioChannel = channels
                audioDepacketizer = AudioDepacketizer(info: info, fmtp: audio.fmtp[pt] ?? [:])
                desc.audio = info
                setupCount += 1
            } catch {
                // Audio is optional; continue with video only.
            }
        }

        guard setupCount > 0, desc.videoCodec != nil else { throw RTSPError.noSupportedTrack }

        storedSDPControl = sdp.control
        var playHeaders = options.extraPlayHeaders
        if let range = options.range { playHeaders["Range"] = range }
        if let scale = options.scale { playHeaders["Scale"] = String(format: "%.1f", scale) }
        let play = try await request("PLAY", url: aggregateURL(sdpControl: sdp.control), headers: playHeaders)
        guard play.statusCode == 200 else { throw statusError(play) }
        if let s = play.header("Scale") { desc.scaleAccepted = Double(s.trimmingCharacters(in: .whitespaces)) }
        playing = true
        queue.async { [weak self] in
            self?.onDescribed?(desc)
            self?.startKeepAlive()
        }
    }

    private var storedSDPControl: String?

    /// Sends PAUSE (keeps the session alive).
    public func pause() async throws {
        let r = try await request("PAUSE", url: aggregateURL(sdpControl: storedSDPControl), headers: [:])
        guard r.statusCode == 200 else { throw statusError(r) }
        playing = false
    }

    /// Resumes playback, optionally with a new scale. Returns the scale echoed by the server, if any.
    @discardableResult
    public func resume(scale: Double? = nil) async throws -> Double? {
        var h: [String: String] = [:]
        if let scale { h["Scale"] = String(format: "%.1f", scale) }
        let r = try await request("PLAY", url: aggregateURL(sdpControl: storedSDPControl), headers: h)
        guard r.statusCode == 200 else { throw statusError(r) }
        playing = true
        return r.header("Scale").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Tears down the session and closes the socket. Safe to call multiple times.
    /// (Holds the client until done: callers usually drop their reference right after calling stop.)
    public func stop() {
        queue.async { [self] in
            guard !self.closed else { return }
            if self.sessionID != nil, let conn = self.connection {
                let req = self.buildRequest("TEARDOWN", url: self.aggregateURL(sdpControl: self.storedSDPControl), headers: [:])
                // Keep the socket until TEARDOWN is out: otherwise the recorder keeps the session (and a stream
                // slot) until it times out.
                self.close(error: nil, notify: false, cancelConnection: false)
                self.connection = nil   // deinit must not cut the TEARDOWN: the closures below own the socket
                conn.send(content: req, completion: .contentProcessed { _ in conn.cancel() })
                self.queue.asyncAfter(deadline: .now() + 1) { conn.cancel() }
            } else {
                self.close(error: nil, notify: false)
            }
        }
    }

    // MARK: Setup helpers

    private func setupTrack(control: String?, sdpControl: String?, interleaved: UInt8) async throws -> UInt8 {
        var headers = ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(interleaved)-\(interleaved + 1)"]
        if let s = sessionID { headers["Session"] = s }
        var r = try await request("SETUP", url: resolve(control: control), headers: headers)
        if r.statusCode != 200, r.statusCode != 401, let alt = alternateResolve(control: control) {
            // Some servers expect the track before the query string ("…/avm/trackID=1?starttime=…").
            let second = try await request("SETUP", url: alt, headers: headers)
            if second.statusCode == 200 { r = second; queryInsertedControls = true }
        }
        guard r.statusCode == 200 else { throw statusError(r) }
        if let session = r.header("Session") {
            let parts = session.split(separator: ";")
            sessionID = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
            for p in parts.dropFirst() {
                let kv = p.trimmingCharacters(in: .whitespaces)
                if kv.lowercased().hasPrefix("timeout="), let t = TimeInterval(kv.dropFirst(8)) { sessionTimeout = max(10, t) }
            }
        }
        if let transport = r.header("Transport"), let range = transport.range(of: "interleaved=") {
            let rest = transport[range.upperBound...]
            let first = rest.prefix { $0.isNumber }
            if let ch = UInt8(first) { return ch }
        }
        return interleaved
    }

    /// Relative controls are appended to the base URL, query string included (live555/ffmpeg behaviour).
    private var queryInsertedControls = false

    private func resolve(control: String?) -> String {
        if queryInsertedControls, let alt = alternateResolve(control: control) { return alt }
        let base = contentBase ?? options.url.absoluteString
        guard let control, !control.isEmpty, control != "*" else { return base }
        if control.lowercased().hasPrefix("rtsp://") || control.lowercased().hasPrefix("rtsps://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    /// Alternative form with the control inserted before the query string (only when there is one).
    private func alternateResolve(control: String?) -> String? {
        let base = contentBase ?? options.url.absoluteString
        guard let control, !control.isEmpty, control != "*",
              !control.lowercased().hasPrefix("rtsp"), let q = base.firstIndex(of: "?") else { return nil }
        var path = String(base[..<q])
        if !path.hasSuffix("/") { path += "/" }
        return path + control + String(base[q...])
    }

    private func aggregateURL(sdpControl: String?) -> String {
        if let c = sdpControl, !c.isEmpty, c != "*" { return resolve(control: c) }
        return contentBase.map { b in b } ?? options.url.absoluteString
    }

    private func statusError(_ r: RTSPResponse) -> RTSPError {
        r.statusCode == 401 ? .unauthorized : .status(r.statusCode, r.reason)
    }

    // MARK: Connection

    private func connect() async throws {
        guard let host = options.url.host, !host.isEmpty else { throw RTSPError.invalidURL }
        // stop() may have been called before start() ran: never open a socket nobody will close.
        let alreadyClosed: Bool = await withCheckedContinuation { c in queue.async { c.resume(returning: self.closed) } }
        if alreadyClosed { throw RTSPError.closed }
        let port = options.url.port ?? 554
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(options.connectTimeout)
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: params)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let timeout = DispatchWorkItem { [weak conn] in
                guard !resumed else { return }
                resumed = true
                conn?.cancel()
                cont.resume(throwing: RTSPError.unreachable(L("no response from %@", "\(host):\(port)")))
            }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    timeout.cancel()
                    cont.resume()
                case .failed(let err), .waiting(let err):
                    if !resumed {
                        resumed = true
                        timeout.cancel()
                        conn.cancel()
                        cont.resume(throwing: RTSPError.unreachable(err.localizedDescription))
                    } else {
                        self?.close(error: RTSPError.connectionFailed(err.localizedDescription), notify: true)
                    }
                case .cancelled:
                    if !resumed { resumed = true; timeout.cancel(); cont.resume(throwing: RTSPError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + options.connectTimeout, execute: timeout)
        }
        let closedMeanwhile: Bool = await withCheckedContinuation { c in queue.async { c.resume(returning: self.closed) } }
        if closedMeanwhile {
            conn.cancel()
            throw RTSPError.closed
        }
        queue.async { self.receiveLoop() }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receivedBytes += data.count
                self.inbox.append(data)
                self.processInbox()
            }
            if let error {
                self.close(error: RTSPError.connectionFailed(error.localizedDescription), notify: true)
                return
            }
            if isComplete {
                self.close(error: nil, notify: true)
                return
            }
            if !self.closed { self.receiveLoop() }
        }
    }

    private func close(error: Error?, notify: Bool, cancelConnection: Bool = true) {
        guard !closed else { return }
        closed = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        connection?.stateUpdateHandler = nil
        if cancelConnection { connection?.cancel() }
        let failure = error ?? RTSPError.closed
        for (_, c) in pending { c.resume(throwing: failure) }
        pending.removeAll()
        if notify { onClosed?(error) }
    }

    // MARK: Requests

    private func buildRequest(_ method: String, url: String, headers: [String: String]) -> Data {
        cseq += 1
        var lines = ["\(method) \(url) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: \(options.userAgent)"]
        if let auth = authenticator?.authorization(method: method, uri: url) { lines.append("Authorization: \(auth)") }
        if let s = sessionID, headers["Session"] == nil, method != "DESCRIBE", method != "OPTIONS" {
            lines.append("Session: \(s)")
        }
        for (k, v) in headers { lines.append("\(k): \(v)") }
        for (k, v) in options.extraHeaders where headers[k] == nil { lines.append("\(k): \(v)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    public func request(_ method: String, url: String, headers: [String: String], allowAuthRetry: Bool = true) async throws -> RTSPResponse {
        let response: RTSPResponse = try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard !closed, let conn = connection else { cont.resume(throwing: RTSPError.closed); return }
                let data = buildRequest(method, url: url, headers: headers)
                let id = cseq
                pending[id] = cont
                conn.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self, let err else { return }
                    self.queue.async {
                        if let c = self.pending.removeValue(forKey: id) { c.resume(throwing: RTSPError.connectionFailed(err.localizedDescription)) }
                    }
                })
                queue.asyncAfter(deadline: .now() + options.requestTimeout) { [weak self] in
                    if let c = self?.pending.removeValue(forKey: id) { c.resume(throwing: RTSPError.timeout(method)) }
                }
            }
        }
        if response.statusCode != 401, authenticator?.hasChallenge == true { acceptLock.withLock { _credentialsAccepted = true } }
        if response.statusCode == 401, allowAuthRetry {
            guard let auth = authenticator else { throw RTSPError.unauthorized }
            let challenges = response.headers(named: "WWW-Authenticate")
            let hadChallenge = auth.hasChallenge
            let accepted = credentialsAccepted
            guard auth.update(withHeaders: challenges) else { throw RTSPError.unauthorized }
            let stale = challenges.contains { $0.lowercased().contains("stale=true") }
            if hadChallenge && !stale && !accepted {
                // Credentials sent and refused: never repeat them (NVRs lock accounts after a few failures).
                throw RTSPError.unauthorized
            }
            // First challenge, expired nonce, or a device that rotates nonces after accepting us.
            let retry = try await request(method, url: url, headers: headers, allowAuthRetry: false)
            if retry.statusCode == 401 { throw RTSPError.unauthorized }
            return retry
        }
        return response
    }

    // MARK: Keep-alive

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let interval = max(5, sessionTimeout / 2)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            let method = self.supportsGetParameter ? "GET_PARAMETER" : "OPTIONS"
            let url = self.aggregateURL(sdpControl: self.storedSDPControl)
            Task { _ = try? await self.request(method, url: url, headers: [:]) }
        }
        t.resume()
        keepAliveTimer = t
    }

    // MARK: Inbound parsing

    private static let crlfcrlf = Data([13, 10, 13, 10])

    private func processInbox() {
        var pos = 0
        let total = inbox.count
        while pos < total {
            let b0 = inbox[inbox.startIndex + pos]
            if b0 == 0x24 { // '$' interleaved frame
                guard total - pos >= 4 else { break }
                let ch = inbox[inbox.startIndex + pos + 1]
                let len = Int(inbox[inbox.startIndex + pos + 2]) << 8 | Int(inbox[inbox.startIndex + pos + 3])
                guard total - pos >= 4 + len else { break }
                let start = inbox.startIndex + pos + 4
                handleInterleaved(channel: ch, payload: inbox.subdata(in: start..<(start + len)))
                pos += 4 + len
            } else if b0 >= 0x41 && b0 <= 0x5A { // 'A'...'Z': RTSP message
                let searchStart = inbox.startIndex + pos
                guard let headerEnd = inbox.range(of: Self.crlfcrlf, in: searchStart..<inbox.endIndex) else {
                    if total - pos > 64 * 1024 { pos = total } // garbage; drop
                    break
                }
                let headerData = inbox.subdata(in: searchStart..<headerEnd.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                var lines = headerText.components(separatedBy: "\r\n")
                let startLine = lines.removeFirst()
                var headers: [(String, String)] = []
                var contentLength = 0
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers.append((name, value))
                    if name.caseInsensitiveCompare("Content-Length") == .orderedSame { contentLength = Int(value) ?? 0 }
                }
                let bodyStart = headerEnd.upperBound
                guard inbox.endIndex - bodyStart >= contentLength else { break }
                let body = inbox.subdata(in: bodyStart..<(bodyStart + contentLength))
                pos = (bodyStart + contentLength) - inbox.startIndex
                if startLine.hasPrefix("RTSP/") {
                    let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
                    let code = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    let reason = parts.count > 2 ? parts[2] : ""
                    let cseqValue = headers.first { $0.0.caseInsensitiveCompare("CSeq") == .orderedSame }.flatMap { Int($0.1) } ?? -1
                    let response = RTSPResponse(statusCode: code, reason: reason, headers: headers, body: body)
                    if let c = pending.removeValue(forKey: cseqValue) { c.resume(returning: response) }
                } else {
                    // Server-to-client request (e.g. ANNOUNCE/SET_PARAMETER): acknowledge.
                    if let cs = headers.first(where: { $0.0.caseInsensitiveCompare("CSeq") == .orderedSame })?.1 {
                        let reply = "RTSP/1.0 200 OK\r\nCSeq: \(cs)\r\n\r\n"
                        connection?.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                    }
                }
            } else {
                pos += 1 // resynchronise
            }
        }
        if pos >= total {
            inbox.removeAll(keepingCapacity: true)
        } else if pos > 0 {
            inbox = inbox.subdata(in: (inbox.startIndex + pos)..<inbox.endIndex)
        }
    }

    private func handleInterleaved(channel: UInt8, payload: Data) {
        if channel == videoChannel, let dep = videoDepacketizer {
            guard let packet = RTPPacket.parse(payload) else { return }
            for au in dep.push(packet) { onVideo?(au) }
        } else if channel == audioChannel, let dep = audioDepacketizer {
            guard let packet = RTPPacket.parse(payload) else { return }
            for f in dep.push(packet) { onAudio?(f) }
        } else if channel == videoChannel + 1 || channel == audioChannel + 1 {
            // RTCP: detect BYE (PT 203) as end of stream.
            if payload.count >= 2 {
                var i = 0
                while i + 4 <= payload.count {
                    let pt = payload[payload.startIndex + i + 1]
                    let words = (Int(payload[payload.startIndex + i + 2]) << 8) | Int(payload[payload.startIndex + i + 3])
                    let len = (words + 1) * 4
                    if pt == 203 { close(error: nil, notify: true); return }
                    i += len
                }
            }
        }
    }
}
