import Foundation
import RTSPKit
import ONVIFKit
import VigiKit
import NetKit
import VedettaL10n

public enum ConnectError: LocalizedError {
    case invalidAddress
    case noChannels
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return L("Invalid address. Enter the device IP address, for example 192.168.1.100.")
        case .noChannels: return L("Connected, but the device has no cameras.")
        case .message(let s): return NetworkHint.explain(s)
        }
    }
}

public struct ConnectResult: Sendable {
    public var device: Device
    public var warnings: [String]
    /// VIGI session opened while connecting: the app adopts it (no second login) or closes it with `discardSession`.
    public var session: VigiClient?
    /// The recorder reported an administrator account.
    public var isAdministrator = false

    public init(device: Device, warnings: [String], session: VigiClient? = nil) {
        self.device = device
        self.warnings = warnings
        self.session = session
    }

    /// Closes the session on the recorder when the result is not used.
    public func discardSession() async { await session?.logout() }
}

/// Discovers what a device offers and builds a ready-to-use Device configuration.
public enum DeviceConnector {
    public static func normalizeHost(_ raw: String) -> (host: String, port: Int?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return nil }
        return (host, comps.port)
    }

    // MARK: Credential-safe helpers

    /// A connection step that sends the credentials, explicitly requested by the user (one attempt, serialized
    /// with any other attempt on the same device).
    static func manualRTSP<T>(_ g: AccessGuard?, _ action: String, _ body: () async throws -> T) async throws -> T {
        guard let g else { return try await body() }
        return try await g.credentialed(action, manual: true, body) { r in
            switch r {
            case .success: return .confirmed
            case .failure(RTSPError.unauthorized): return .rejected(L("The device refused the user name or password (video)."))
            case .failure(RTSPError.unreachable(let m)): return .network(m)
            default: return .neutral
            }
        }
    }

    // MARK: VIGI NVR

    public static func connectNVR(address: String, httpPort: Int = 443, rtspPort: Int = 554,
                                  username: String, password: String, id: UUID = UUID(),
                                  accessGuard: AccessGuard? = nil, client existing: VigiClient? = nil) async throws -> ConnectResult {
        guard let (host, port) = normalizeHost(address) else { throw ConnectError.invalidAddress }
        let apiPort = port ?? httpPort
        var warnings: [String] = []
        var device = Device(id: id, kind: .vigiNVR, name: L("Recorder"), host: host, httpPort: apiPort,
                            rtspPort: rtspPort, username: username)
        var channels: [Channel] = []

        let vigi = existing ?? VigiClient(host: host, port: apiPort, username: username, password: password, accessGuard: accessGuard)
        var apiWorked = false
        var isAdmin = false
        do {
            // Reuse the running session when there is one (refresh): no new login.
            if !(await vigi.hasSession) { try await vigi.login() }
            apiWorked = true
            isAdmin = await vigi.isAdministrator
            if let info = try? await vigi.deviceInfo() {
                device.model = info.model
                device.firmware = info.firmware
                if let name = info.name ?? info.model { device.name = name }
            }
            if let list = try? await vigi.channels() {
                channels = list.map { vc in
                    var c = Channel(deviceID: id, number: vc.id, name: vc.name)
                    c.isOnline = vc.online
                    c.supportsPlayback = true
                    return c
                }
            }
        } catch VigiError.wrongCredentials(let left) {
            throw ConnectError.message(left.map { L("Wrong recorder user name or password.") + " " + L("%@ attempts left before the recorder locks the user.", String($0)) }
                                       ?? L("Wrong recorder user name or password."))
        } catch VigiError.locked(let s) {
            throw ConnectError.message(VigiError.locked(seconds: s).localizedDescription + " " + L("Vedetta will not try again: wait, or unlock the user on the recorder."))
        } catch let e as AccessBlocked {
            throw ConnectError.message(e.localizedDescription)
        } catch {
            warnings.append(L("Recorder management interface not available: using ONVIF/RTSP only."))
        }

        // ONVIF only when the VIGI API is not available (names and channels); stop at the first refusal.
        if !apiWorked {
            let onvifCandidates = [URL(string: "https://\(host):2443/onvif/device_service"),
                                   URL(string: "http://\(host)/onvif/device_service")].compactMap { $0 }
            for url in onvifCandidates {
                let client = ONVIFClient(deviceURL: url, username: username, password: password)
                await client.syncTime()
                let info: ONVIFDeviceInfo
                do {
                    info = try await manualONVIF(accessGuard, "ONVIF GetDeviceInformation") { try await client.deviceInformation() }
                } catch ONVIFError.notAuthorized {
                    throw ConnectError.message(L("Wrong recorder user name or password."))
                } catch {
                    continue
                }
                device.onvifURL = url.absoluteString
                if device.model == nil { device.model = info.model }
                if device.firmware == nil { device.firmware = info.firmware }
                if device.name == L("Recorder") { device.name = info.model }
                if channels.isEmpty, let profiles = try? await client.profiles() {
                    let sources = Array(Set(profiles.compactMap(\.videoSourceToken))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    for (i, _) in sources.enumerated() {
                        var c = Channel(deviceID: id, number: i + 1, name: L("Channel %@", String(i + 1)))
                        c.supportsPlayback = true
                        channels.append(c)
                    }
                }
                break
            }
        }

        if channels.isEmpty {
            channels = try await probeRTSPChannels(host: host, rtspPort: rtspPort, username: username, password: password,
                                                   deviceID: id, accessGuard: accessGuard)
        }
        guard !channels.isEmpty else {
            if existing == nil { await vigi.logout() }
            if !apiWorked { throw ConnectError.message(L("Cannot communicate with the recorder at %@. Check address, user and password.", host)) }
            throw ConnectError.noChannels
        }
        device.channels = channels

        // Verify streaming credentials on the first online channel (substream = light).
        if let first = channels.first(where: \.isOnline) ?? channels.first,
           let url = StreamURLs.live(device: device, channel: first, kind: .sub) {
            do {
                _ = try await manualRTSP(accessGuard, "RTSP check ch \(first.number)") {
                    try await verifyRTSP(url: url, username: username, password: password)
                }
            } catch RTSPError.unauthorized {
                if existing == nil { await vigi.logout() }
                throw ConnectError.message(L("The recorder rejected the video (RTSP) credentials. Check user and password."))
            } catch {
                warnings.append(L("Video not verified yet: %@. Make sure RTSP is enabled on the recorder (port %@).", error.localizedDescription, String(rtspPort)))
            }
        }
        if isAdmin { warnings.append(L("You are using an administrator account. A dedicated user with view-only permissions is safer: if the account gets locked you also lose the recorder management.")) }
        var result = ConnectResult(device: device, warnings: warnings, session: apiWorked ? vigi : nil)
        result.isAdministrator = isAdmin
        return result
    }

    static func manualONVIF<T>(_ g: AccessGuard?, _ action: String, _ body: () async throws -> T) async throws -> T {
        guard let g else { return try await body() }
        return try await g.credentialed(action, manual: true, body) { r in
            switch r {
            case .success: return .confirmed
            case .failure(ONVIFError.notAuthorized): return .rejected(L("The device refused the user name or password (ONVIF)."))
            case .failure(ONVIFError.unreachable(let m)): return .network(m)
            default: return .neutral
            }
        }
    }

    /// Finds the channels of an RTSP-only recorder. Credentials are tried on one channel at a time until the
    /// device accepts them; only then the others are probed in parallel (parallel wrong passwords lock accounts).
    static func probeRTSPChannels(host: String, rtspPort: Int, username: String, password: String, deviceID: UUID,
                                  accessGuard: AccessGuard? = nil) async throws -> [Channel] {
        let hp = StreamURLs.hostPort(host: host, rtspPort: rtspPort)
        let found = try await probeChannels(count: 16, accessGuard: accessGuard, url: { URL(string: "rtsp://\(hp)/live/\($0)/2/avm") },
                                            username: username, password: password)
        return found.map { n in
            var c = Channel(deviceID: deviceID, number: n, name: L("Channel %@", String(n)))
            c.supportsPlayback = true
            return c
        }
    }

    static func probeChannels(count: Int, accessGuard: AccessGuard?, url: @escaping @Sendable (Int) -> URL?,
                              username: String, password: String) async throws -> [Int] {
        var found: [Int] = []
        var next = 1
        var confirmed = false
        // Sequential phase: stop at the first refusal, switch to parallel once the credentials are accepted.
        while next <= min(count, 4), !confirmed {
            guard let u = url(next) else { next += 1; continue }
            do {
                let r = try await manualRTSP(accessGuard, "RTSP probe ch \(next)") { try await describeOnly(url: u, username: username, password: password) }
                if r.exists { found.append(next) }
                confirmed = r.credentialsOK
            } catch RTSPError.unauthorized {
                throw RTSPError.unauthorized
            } catch RTSPError.unreachable(let m) {
                throw RTSPError.unreachable(m)
            } catch {}
            next += 1
        }
        guard confirmed, next <= count else { return found }
        let rest: [Int] = await withTaskGroup(of: Int?.self) { group in
            for n in next...count {
                group.addTask {
                    guard let u = url(n) else { return nil }
                    return (try? await describeOnly(url: u, username: username, password: password))?.exists == true ? n : nil
                }
            }
            var list: [Int] = []
            for await n in group { if let n { list.append(n) } }
            return list
        }
        return (found + rest).sorted()
    }

    /// Opens the stream briefly: whether it exists and whether the device accepted the credentials.
    static func describeOnly(url: URL, username: String, password: String) async throws -> (exists: Bool, credentialsOK: Bool) {
        let opts = RTSPClient.Options(url: url, username: username, password: password)
        let c = RTSPClient(options: opts)
        defer { c.stop() }
        let ok: Bool = try await withThrowingTaskGroup(of: Bool.self) { g in
            g.addTask {
                do { try await c.start(); return true }
                catch RTSPError.unauthorized { throw RTSPError.unauthorized }
                catch RTSPError.unreachable(let m) { throw RTSPError.unreachable(m) }
                catch { return false }
            }
            g.addTask {
                try await Task.sleep(nanoseconds: 6_000_000_000)
                return false
            }
            let r = try await g.next() ?? false
            g.cancelAll()
            return r
        }
        return (ok, ok || c.credentialsAccepted)
    }

    /// Full RTSP setup to confirm credentials and codec; returns the stream description.
    public static func verifyRTSP(url: URL, username: String, password: String) async throws -> RTSPStreamDescription {
        let opts = RTSPClient.Options(url: url, username: username, password: password)
        let c = RTSPClient(options: opts)
        final class Box: @unchecked Sendable { var desc: RTSPStreamDescription? }
        let box = Box()
        c.onDescribed = { box.desc = $0 }
        defer { c.stop() }
        try await c.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let d = box.desc else { throw RTSPError.noSupportedTrack }
        return d
    }

    // MARK: ONVIF cameras (any brand)

    public static func connectONVIF(url: URL, username: String, password: String, id: UUID = UUID(),
                                    asRecorder: Bool = false, brand: RecorderBrand? = nil,
                                    accessGuard: AccessGuard? = nil) async throws -> ConnectResult {
        let client = ONVIFClient(deviceURL: url, username: username, password: password)
        await client.syncTime()
        let info: ONVIFDeviceInfo
        do {
            info = try await manualONVIF(accessGuard, "ONVIF GetDeviceInformation") { try await client.deviceInformation() }
        } catch ONVIFError.notAuthorized {
            throw ConnectError.message(asRecorder
                ? L("Wrong recorder user name or password (ONVIF). On many recorders ONVIF access must be enabled and has its own user.")
                : L("Wrong camera user name or password (ONVIF). On some cameras the ONVIF user must be enabled in the settings."))
        } catch {
            throw ConnectError.message(error.localizedDescription)
        }
        _ = try? await client.loadServices()
        let profiles = try await client.profiles()
        guard !profiles.isEmpty else { throw ConnectError.noChannels }

        var groups: [String: [ONVIFProfile]] = [:]
        for p in profiles { groups[p.videoSourceToken ?? p.token, default: []].append(p) }
        let ordered = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let displayName = [info.manufacturer, info.model].filter { !$0.isEmpty }.joined(separator: " ")
        let isRecorder = asRecorder || ordered.count > 1
        var device = Device(id: id, kind: isRecorder ? .onvifNVR : .onvifCamera,
                            name: info.model.isEmpty ? (url.host ?? (isRecorder ? L("Recorder") : L("Camera"))) : info.model,
                            host: url.host ?? "", httpPort: url.port ?? (url.scheme == "https" ? 443 : 80), rtspPort: 554,
                            username: username)
        device.onvifURL = url.absoluteString
        device.model = displayName
        device.firmware = info.firmware
        device.brand = brand ?? RecorderBrand.guess(from: displayName)
        var channels: [Channel] = []
        var warnings: [String] = []
        for (i, key) in ordered.enumerated() {
            let list = groups[key]!.sorted { $0.pixels > $1.pixels }
            let main = list.first!
            let sub = list.count > 1 ? list.last! : nil
            let name = ordered.count == 1 && !isRecorder ? device.name : L("Channel %@", String(i + 1))
            var ch = Channel(deviceID: id, number: i + 1, name: name)
            ch.sourceToken = key
            ch.mainURL = (try? await client.streamURI(profile: main))?.absoluteString
            if let sub { ch.subURL = (try? await client.streamURI(profile: sub))?.absoluteString }
            if list.contains(where: \.hasPTZ) { ch.ptzProfile = (list.first(where: \.hasPTZ) ?? main).token }
            if ch.mainURL != nil || ch.subURL != nil { channels.append(ch) }
        }
        guard !channels.isEmpty else { throw ConnectError.message(L("The device did not provide any streaming address.")) }
        if let port = channels.first?.mainURL.flatMap(URL.init(string:))?.port { device.rtspPort = port }

        // Profile G: link each channel to its recording so the timeline and exports work.
        if await client.searchServiceURL != nil, let recordings = try? await client.findRecordings(), !recordings.isEmpty {
            let map = matchRecordings(recordings, to: channels)
            for i in channels.indices {
                if let token = map[channels[i].id] {
                    channels[i].recordingToken = token
                    channels[i].supportsPlayback = true
                }
            }
        }
        if !channels.contains(where: \.supportsPlayback), device.brand?.supportsReplay == true, isRecorder {
            for i in channels.indices { channels[i].supportsPlayback = true }
        }
        if isRecorder && !channels.contains(where: \.supportsPlayback) {
            warnings.append(L("The recorder does not expose recordings over ONVIF (Profile G): live view works, playback does not. If it is Hikvision or Dahua, choose the brand in the advanced options."))
        }
        device.channels = channels
        if let u = (channels[0].subURL ?? channels[0].mainURL).flatMap(URL.init(string:)) {
            do { _ = try await manualRTSP(accessGuard, "RTSP check") { try await verifyRTSP(url: u, username: username, password: password) } }
            catch RTSPError.unauthorized { throw ConnectError.message(L("The device rejected the video (RTSP) credentials.")) }
            catch { warnings.append(L("Video not verified yet: %@", error.localizedDescription)) }
        }
        return ConnectResult(device: device, warnings: warnings)
    }

    /// Pairs ONVIF recordings with channels (by source token, by channel number in the name, or by order).
    static func matchRecordings(_ recordings: [ONVIFRecording], to channels: [Channel]) -> [String: String] {
        var result: [String: String] = [:]
        var used = Set<String>()
        func digits(_ s: String) -> Int? {
            let d = s.reversed().prefix { $0.isNumber }
            return d.isEmpty ? nil : Int(String(d.reversed()))
        }
        for ch in channels {
            guard let src = ch.sourceToken else { continue }
            if let r = recordings.first(where: { !used.contains($0.token) && ($0.sourceID == src || $0.sourceName == src) }) {
                result[ch.id] = r.token; used.insert(r.token)
            }
        }
        for ch in channels where result[ch.id] == nil {
            if let r = recordings.first(where: { !used.contains($0.token) &&
                (digits($0.sourceID) == ch.number || digits($0.sourceName) == ch.number || digits($0.token) == ch.number) }) {
                result[ch.id] = r.token; used.insert(r.token)
            }
        }
        let remaining = recordings.filter { !used.contains($0.token) }
        let missing = channels.filter { result[$0.id] == nil }
        if !missing.isEmpty, remaining.count == missing.count || recordings.count == channels.count {
            for (ch, r) in zip(missing, remaining) { result[ch.id] = r.token }
        }
        return result
    }

    // MARK: Recorders of any brand

    /// Connects an NVR of any brand: ONVIF first (live + Profile G playback), then brand RTSP layouts.
    public static func connectRecorder(address: String, onvifURL: String?, brand: RecorderBrand?, rtspPort: Int = 554,
                                       username: String, password: String, id: UUID = UUID(),
                                       accessGuard: AccessGuard? = nil) async throws -> ConnectResult {
        guard let (host, port) = normalizeHost(address) else { throw ConnectError.invalidAddress }
        var candidates: [URL] = []
        if let s = onvifURL, let u = URL(string: s), u.host != nil { candidates.append(u) }
        let ports = port.map { [$0] } ?? []
        for p in ports + [80, 8000, 8080, 2020] {
            candidates.append(URL(string: "http://\(host)\(p == 80 ? "" : ":\(p)")/onvif/device_service")!)
        }
        candidates.append(URL(string: "https://\(host)/onvif/device_service")!)
        candidates.append(URL(string: "https://\(host):2443/onvif/device_service")!)
        var seen = Set<String>()
        var authError: Error?
        for url in candidates where seen.insert(url.absoluteString).inserted {
            let probe = ONVIFClient(deviceURL: url, username: "", password: "", timeout: 3)
            // Cheap unauthenticated check before trying credentials.
            guard (try? await probe.soap("<GetSystemDateAndTime xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>", authenticated: false)) != nil else { continue }
            do {
                return try await connectONVIF(url: url, username: username, password: password, id: id, asRecorder: true, brand: brand,
                                              accessGuard: accessGuard)
            } catch {
                authError = error
                break
            }
        }
        if let brand {
            return try await connectBrandRecorder(host: host, brand: brand, rtspPort: rtspPort, username: username, password: password, id: id,
                                                  accessGuard: accessGuard)
        }
        if let authError { throw authError }
        throw ConnectError.message(L("Cannot find the ONVIF service on %@. Enable ONVIF in the recorder settings, or choose the brand in the advanced options to connect it over RTSP.", host))
    }

    /// RTSP-only recorder using the brand's URL layout; channels found by probing.
    public static func connectBrandRecorder(host: String, brand: RecorderBrand, rtspPort: Int, username: String, password: String,
                                            id: UUID = UUID(), accessGuard: AccessGuard? = nil) async throws -> ConnectResult {
        let hp = StreamURLs.hostPort(host: host, rtspPort: rtspPort)
        let found: [Int]
        do {
            found = try await probeChannels(count: 32, accessGuard: accessGuard, url: { URL(string: brand.liveURL(host: hp, channel: $0, main: false)) },
                                            username: username, password: password)
        } catch RTSPError.unauthorized {
            throw ConnectError.message(L("Wrong recorder user name or password."))
        } catch {
            throw ConnectError.message(L("No camera found on %@ with the %@ layout: %@", host, brand.label, error.localizedDescription))
        }
        guard !found.isEmpty else {
            throw ConnectError.message(L("No camera found on %@ with the %@ layout: %@", host, brand.label, L("no stream answered")))
        }
        var device = Device(id: id, kind: .rtspRecorder, name: L("Recorder %@", brand.label.components(separatedBy: " /").first ?? ""),
                            host: host, httpPort: 80, rtspPort: rtspPort, username: username)
        device.brand = brand
        device.model = brand.label
        device.channels = found.map { n in
            var c = Channel(deviceID: id, number: n, name: L("Channel %@", String(n)))
            c.mainURL = brand.liveURL(host: hp, channel: n, main: true)
            c.subURL = brand.liveURL(host: hp, channel: n, main: false)
            c.supportsPlayback = brand.supportsReplay
            return c
        }
        var warnings: [String] = []
        if !brand.supportsReplay { warnings.append(L("For %@ over RTSP only live view is available. Enable ONVIF on the recorder to review recordings.", brand.label)) }
        return ConnectResult(device: device, warnings: warnings)
    }

    // MARK: Plain RTSP

    public static func connectRTSP(url: URL, name: String, username: String, password: String, id: UUID = UUID(),
                                   accessGuard: AccessGuard? = nil) async throws -> ConnectResult {
        do {
            _ = try await manualRTSP(accessGuard, "RTSP check") { try await verifyRTSP(url: url, username: username, password: password) }
        } catch RTSPError.unauthorized {
            throw ConnectError.message(L("Wrong user name or password."))
        } catch {
            throw ConnectError.message(error.localizedDescription)
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.user = nil; comps?.password = nil
        let clean = comps?.url ?? url
        var d = Device(id: id, kind: .rtspCamera, name: name.isEmpty ? (url.host ?? L("Camera")) : name,
                       host: url.host ?? "", httpPort: 80, rtspPort: url.port ?? 554, username: username)
        var ch = Channel(deviceID: id, number: 1, name: d.name)
        ch.mainURL = clean.absoluteString
        d.channels = [ch]
        return ConnectResult(device: d, warnings: [])
    }

    /// Re-reads channel names/status keeping user customisations (hidden flags, renamed channels).
    /// Uses the device's shared session: no new login when it is still valid.
    @MainActor
    public static func refresh(_ device: Device) async throws -> ConnectResult {
        guard let creds = device.storedCredentials else { throw AccessBlocked(state: .missingPassword) }
        let g = DeviceClients.shared.accessGuard(for: device)
        if g.state.needsUser || g.state.isOffline { throw AccessBlocked(state: g.state) }
        var result: ConnectResult
        switch device.kind {
        case .vigiNVR:
            result = try await connectNVR(address: device.host, httpPort: device.httpPort, rtspPort: device.rtspPort,
                                          username: creds.username, password: creds.password, id: device.id,
                                          accessGuard: g, client: DeviceClients.shared.vigi(for: device))
        case .onvifCamera, .onvifNVR:
            guard let s = device.onvifURL, let u = URL(string: s) else { return ConnectResult(device: device, warnings: []) }
            result = try await connectONVIF(url: u, username: creds.username, password: creds.password, id: device.id,
                                            asRecorder: device.kind == .onvifNVR, brand: device.brand, accessGuard: g)
        case .rtspRecorder:
            guard let brand = device.brand else { return ConnectResult(device: device, warnings: []) }
            result = try await connectBrandRecorder(host: device.host, brand: brand, rtspPort: device.rtspPort,
                                                    username: creds.username, password: creds.password, id: device.id, accessGuard: g)
        case .rtspCamera:
            return ConnectResult(device: device, warnings: [])
        }
        result.device.name = device.name
        result.device.replayTimeSuffix = device.replayTimeSuffix
        result.device.addedAt = device.addedAt
        for i in result.device.channels.indices {
            if let old = device.channels.first(where: { $0.number == result.device.channels[i].number }) {
                result.device.channels[i].isHidden = old.isHidden
                if !Channel.isDefaultName(old.name, number: old.number) { result.device.channels[i].name = old.name }
            }
        }
        return result
    }
}
