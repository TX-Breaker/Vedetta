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

    // MARK: VIGI NVR

    public static func connectNVR(address: String, httpPort: Int = 443, rtspPort: Int = 554,
                                  username: String, password: String, id: UUID = UUID()) async throws -> ConnectResult {
        guard let (host, port) = normalizeHost(address) else { throw ConnectError.invalidAddress }
        let apiPort = port ?? httpPort
        var warnings: [String] = []
        var device = Device(id: id, kind: .vigiNVR, name: L("Recorder"), host: host, httpPort: apiPort,
                            rtspPort: rtspPort, username: username)
        var channels: [Channel] = []

        let vigi = VigiClient(host: host, port: apiPort, username: username, password: password)
        var apiWorked = false
        do {
            try await vigi.login()
            apiWorked = true
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
            await vigi.logout()
        } catch VigiError.wrongCredentials {
            throw ConnectError.message(L("Wrong recorder user name or password."))
        } catch VigiError.locked(let s) {
            throw ConnectError.message(VigiError.locked(seconds: s).localizedDescription)
        } catch {
            warnings.append(L("Recorder management interface not available: using ONVIF/RTSP only."))
        }

        // ONVIF (also used for names when the VIGI API is not available).
        let onvifCandidates = [URL(string: "https://\(host):2443/onvif/device_service"),
                               URL(string: "http://\(host)/onvif/device_service")].compactMap { $0 }
        for url in onvifCandidates {
            let client = ONVIFClient(deviceURL: url, username: username, password: password)
            await client.syncTime()
            if let info = try? await client.deviceInformation() {
                device.onvifURL = url.absoluteString
                if device.model == nil { device.model = info.model }
                if device.firmware == nil { device.firmware = info.firmware }
                if !apiWorked, device.name == L("Recorder") { device.name = info.model }
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
            channels = await probeRTSPChannels(host: host, rtspPort: rtspPort, username: username, password: password, deviceID: id)
        }
        guard !channels.isEmpty else {
            if !apiWorked { throw ConnectError.message(L("Cannot communicate with the recorder at %@. Check address, user and password.", host)) }
            throw ConnectError.noChannels
        }
        device.channels = channels

        // Verify streaming credentials on the first online channel (substream = light).
        if let first = channels.first(where: \.isOnline) ?? channels.first,
           let url = StreamURLs.live(device: device, channel: first, kind: .sub) {
            do {
                _ = try await verifyRTSP(url: url, username: username, password: password)
            } catch RTSPError.unauthorized {
                throw ConnectError.message(L("The recorder rejected the video (RTSP) credentials. Check user and password."))
            } catch {
                warnings.append(L("Video not verified yet: %@. Make sure RTSP is enabled on the recorder (port %@).", error.localizedDescription, String(rtspPort)))
            }
        }
        return ConnectResult(device: device, warnings: warnings)
    }

    static func probeRTSPChannels(host: String, rtspPort: Int, username: String, password: String, deviceID: UUID) async -> [Channel] {
        await withTaskGroup(of: Int?.self) { group in
            for n in 1...16 {
                group.addTask {
                    let hp = rtspPort == 554 ? host : "\(host):\(rtspPort)"
                    guard let url = URL(string: "rtsp://\(hp)/live/\(n)/2/avm") else { return nil }
                    return (try? await describeOnly(url: url, username: username, password: password)) == true ? n : nil
                }
            }
            var found: [Int] = []
            for await n in group { if let n { found.append(n) } }
            return found.sorted().map { n in
                var c = Channel(deviceID: deviceID, number: n, name: L("Channel %@", String(n)))
                c.supportsPlayback = true
                return c
            }
        }
    }

    /// DESCRIBE only (no SETUP/PLAY): true if the stream exists.
    static func describeOnly(url: URL, username: String, password: String) async throws -> Bool {
        let opts = RTSPClient.Options(url: url, username: username, password: password)
        let c = RTSPClient(options: opts)
        defer { c.stop() }
        return try await withThrowingTaskGroup(of: Bool.self) { g in
            g.addTask {
                try await c.start()
                return true
            }
            g.addTask {
                try await Task.sleep(nanoseconds: 6_000_000_000)
                return false
            }
            let r = try await g.next() ?? false
            g.cancelAll()
            return r
        }
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
                                    asRecorder: Bool = false, brand: RecorderBrand? = nil) async throws -> ConnectResult {
        let client = ONVIFClient(deviceURL: url, username: username, password: password)
        await client.syncTime()
        let info: ONVIFDeviceInfo
        do {
            info = try await client.deviceInformation()
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
            do { _ = try await verifyRTSP(url: u, username: username, password: password) }
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
                                       username: String, password: String, id: UUID = UUID()) async throws -> ConnectResult {
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
                return try await connectONVIF(url: url, username: username, password: password, id: id, asRecorder: true, brand: brand)
            } catch {
                authError = error
                break
            }
        }
        if let brand {
            return try await connectBrandRecorder(host: host, brand: brand, rtspPort: rtspPort, username: username, password: password, id: id)
        }
        if let authError { throw authError }
        throw ConnectError.message(L("Cannot find the ONVIF service on %@. Enable ONVIF in the recorder settings, or choose the brand in the advanced options to connect it over RTSP.", host))
    }

    /// RTSP-only recorder using the brand's URL layout; channels found by probing.
    public static func connectBrandRecorder(host: String, brand: RecorderBrand, rtspPort: Int, username: String, password: String,
                                            id: UUID = UUID()) async throws -> ConnectResult {
        let hp = rtspPort == 554 ? host : "\(host):\(rtspPort)"
        let found: [Int] = await withTaskGroup(of: (Int, Bool).self) { group in
            for n in 1...32 {
                group.addTask {
                    guard let url = URL(string: brand.liveURL(host: hp, channel: n, main: false)) else { return (n, false) }
                    let ok = (try? await describeOnly(url: url, username: username, password: password)) == true
                    return (n, ok)
                }
            }
            var list: [Int] = []
            for await (n, ok) in group where ok { list.append(n) }
            return list.sorted()
        }
        guard !found.isEmpty else {
            // Distinguish wrong credentials from wrong brand/address.
            if let url = URL(string: brand.liveURL(host: hp, channel: 1, main: false)) {
                do { _ = try await verifyRTSP(url: url, username: username, password: password) }
                catch RTSPError.unauthorized { throw ConnectError.message(L("Wrong recorder user name or password.")) }
                catch { throw ConnectError.message(L("No camera found on %@ with the %@ layout: %@", host, brand.label, error.localizedDescription)) }
            }
            throw ConnectError.noChannels
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

    public static func connectRTSP(url: URL, name: String, username: String, password: String, id: UUID = UUID()) async throws -> ConnectResult {
        do {
            _ = try await verifyRTSP(url: url, username: username, password: password)
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
    public static func refresh(_ device: Device) async throws -> ConnectResult {
        let creds = device.credentials
        var result: ConnectResult
        switch device.kind {
        case .vigiNVR:
            result = try await connectNVR(address: device.host, httpPort: device.httpPort, rtspPort: device.rtspPort,
                                          username: creds.username, password: creds.password, id: device.id)
        case .onvifCamera, .onvifNVR:
            guard let s = device.onvifURL, let u = URL(string: s) else { return ConnectResult(device: device, warnings: []) }
            result = try await connectONVIF(url: u, username: creds.username, password: creds.password, id: device.id,
                                            asRecorder: device.kind == .onvifNVR, brand: device.brand)
        case .rtspRecorder:
            guard let brand = device.brand else { return ConnectResult(device: device, warnings: []) }
            result = try await connectBrandRecorder(host: device.host, brand: brand, rtspPort: device.rtspPort,
                                                    username: creds.username, password: creds.password, id: device.id)
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
