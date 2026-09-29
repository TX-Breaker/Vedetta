import Foundation
import CryptoKit
import NetKit
import VedettaL10n

public enum ONVIFError: LocalizedError {
    case unreachable(String)
    case notAuthorized
    case fault(String)
    case badResponse
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let s): return L("Device not reachable: %@", s)
        case .notAuthorized: return L("Wrong user name or password (ONVIF)")
        case .fault(let s): return L("ONVIF error: %@", s)
        case .badResponse: return L("Invalid ONVIF response")
        case .unsupported(let s): return L("Feature not supported: %@", s)
        }
    }
}

public struct ONVIFDeviceInfo: Sendable, Codable {
    public var manufacturer: String
    public var model: String
    public var firmware: String
    public var serial: String
}

public struct ONVIFProfile: Sendable, Codable, Hashable {
    public var token: String
    public var name: String
    public var videoSourceToken: String?
    public var encoding: String?
    public var width: Int
    public var height: Int
    public var frameRate: Int?
    public var hasPTZ: Bool
    public var usesMedia2: Bool
    public var pixels: Int { width * height }
}

public struct ONVIFPreset: Sendable, Hashable, Identifiable {
    public var token: String
    public var name: String
    public var id: String { token }
}

/// Stateless-ish ONVIF SOAP client (WS-UsernameToken digest + HTTP digest fallback).
public actor ONVIFClient {
    public nonisolated let deviceURL: URL
    private let username: String
    private let password: String
    private let session: URLSession
    private var timeOffset: TimeInterval = 0
    private var didSyncTime = false
    public private(set) var services: [String: URL] = [:]   // namespace -> XAddr

    static let nsDevice = "http://www.onvif.org/ver10/device/wsdl"
    static let nsMedia = "http://www.onvif.org/ver10/media/wsdl"
    static let nsMedia2 = "http://www.onvif.org/ver20/media/wsdl"
    static let nsPTZ = "http://www.onvif.org/ver20/ptz/wsdl"
    static let nsEvents = "http://www.onvif.org/ver10/events/wsdl"
    static let nsImaging = "http://www.onvif.org/ver20/imaging/wsdl"
    static let nsSchema = "http://www.onvif.org/ver10/schema"

    public init(deviceURL: URL, username: String, password: String, timeout: TimeInterval = 10) {
        self.deviceURL = deviceURL
        self.username = username
        self.password = password
        self.session = DeviceSessionDelegate.makeSession(username: username, password: password, timeout: timeout)
    }

    // MARK: SOAP

    private func securityHeader() -> String {
        guard !username.isEmpty else { return "" }
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let created = ISO8601DateFormatter.onvif.string(from: Date().addingTimeInterval(timeOffset))
        var digestInput = nonce
        digestInput.append(Data(created.utf8))
        digestInput.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: digestInput)).base64EncodedString()
        return """
        <s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
        <UsernameToken><Username>\(username.xmlEscaped)</Username>\
        <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</Password>\
        <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</Nonce>\
        <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(created)</Created>\
        </UsernameToken></Security></s:Header>
        """
    }

    /// Sends a SOAP 1.2 request and returns the Body element.
    public func soap(_ body: String, to url: URL? = nil, authenticated: Bool = true) async throws -> XNode {
        if authenticated && !didSyncTime { await syncTime() }
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:tt="http://www.onvif.org/ver10/schema">\(authenticated ? securityHeader() : "")<s:Body>\(body)</s:Body></s:Envelope>
        """
        var req = URLRequest(url: url ?? deviceURL)
        req.httpMethod = "POST"
        req.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(envelope.utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw ONVIFError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let root = XMLTree.parse(data), let bodyNode = root.first("Body") else {
            if status == 401 { throw ONVIFError.notAuthorized }
            throw ONVIFError.badResponse
        }
        if let fault = bodyNode.child("Fault") {
            let reason = fault.first("Text")?.trimmedText ?? fault.first("faultstring")?.trimmedText ?? L("unknown error")
            let subcodes = fault.descendants("Value").map(\.trimmedText).joined(separator: " ")
            if subcodes.contains("NotAuthorized") || reason.lowercased().contains("not authorized") || status == 401
                || subcodes.contains("FailedAuthentication") {
                throw ONVIFError.notAuthorized
            }
            throw ONVIFError.fault(reason)
        }
        if status == 401 { throw ONVIFError.notAuthorized }
        return bodyNode
    }

    // MARK: Device service

    /// Aligns WS-Security timestamps with the device clock (many cameras reject skewed tokens).
    public func syncTime() async {
        didSyncTime = true
        guard let body = try? await soap("<GetSystemDateAndTime xmlns=\"\(Self.nsDevice)\"/>", authenticated: false),
              let utc = body.first("UTCDateTime") else { return }
        func v(_ n: String) -> Int { Int(utc.first(n)?.trimmedText ?? "") ?? 0 }
        var comps = DateComponents()
        comps.year = v("Year"); comps.month = v("Month"); comps.day = v("Day")
        comps.hour = v("Hour"); comps.minute = v("Minute"); comps.second = v("Second")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        if let deviceDate = cal.date(from: comps) {
            let offset = deviceDate.timeIntervalSinceNow
            timeOffset = abs(offset) > 5 ? offset : 0
        }
    }

    public func deviceInformation() async throws -> ONVIFDeviceInfo {
        let body = try await soap("<GetDeviceInformation xmlns=\"\(Self.nsDevice)\"/>")
        let r = body.first("GetDeviceInformationResponse")
        func t(_ n: String) -> String { r?.child(n)?.trimmedText ?? "" }
        return ONVIFDeviceInfo(manufacturer: t("Manufacturer"), model: t("Model"), firmware: t("FirmwareVersion"), serial: t("SerialNumber"))
    }

    /// Discovers service endpoints (GetServices, falling back to GetCapabilities).
    @discardableResult
    public func loadServices() async throws -> [String: URL] {
        if let body = try? await soap("<GetServices xmlns=\"\(Self.nsDevice)\"><IncludeCapability>false</IncludeCapability></GetServices>") {
            for s in body.descendants("Service") {
                if let ns = s.child("Namespace")?.trimmedText, let x = s.child("XAddr")?.trimmedText, let url = fixHost(x) {
                    services[ns] = url
                }
            }
        }
        if services[Self.nsMedia] == nil && services[Self.nsMedia2] == nil {
            let body = try await soap("<GetCapabilities xmlns=\"\(Self.nsDevice)\"><Category>All</Category></GetCapabilities>")
            let caps = body.first("Capabilities")
            func addr(_ n: String) -> URL? { caps?.child(n)?.child("XAddr").flatMap { fixHost($0.trimmedText) } }
            if let u = addr("Media") { services[Self.nsMedia] = u }
            if let u = addr("PTZ") { services[Self.nsPTZ] = u }
            if let u = addr("Events") { services[Self.nsEvents] = u }
            if let u = addr("Imaging") { services[Self.nsImaging] = u }
            let ext = caps?.child("Extension")
            func extAddr(_ n: String) -> URL? { ext?.child(n)?.child("XAddr").flatMap { fixHost($0.trimmedText) } }
            if let u = extAddr("Search") { services[Self.nsSearch] = u }
            if let u = extAddr("Replay") { services[Self.nsReplay] = u }
            if let u = extAddr("Recording") { services[Self.nsRecording] = u }
        }
        return services
    }

    /// Devices behind NAT/port-forward often report internal addresses: keep path, use our host/port.
    private func fixHost(_ xaddr: String) -> URL? {
        guard let u = URL(string: xaddr.split(separator: " ").first.map(String.init) ?? xaddr),
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.host = deviceURL.host
        c.port = deviceURL.port
        c.scheme = deviceURL.scheme
        return c.url
    }

    // MARK: Media

    public func profiles() async throws -> [ONVIFProfile] {
        if services.isEmpty { try await loadServices() }
        if let m2 = services[Self.nsMedia2],
           let body = try? await soap("<GetProfiles xmlns=\"\(Self.nsMedia2)\"><Type>All</Type></GetProfiles>", to: m2) {
            let profiles = body.descendants("Profiles").compactMap { p -> ONVIFProfile? in
                guard let token = p.attribute("token") else { return nil }
                let conf = p.child("Configurations")
                let enc = conf?.child("VideoEncoder")
                let res = enc?.child("Resolution")
                return ONVIFProfile(token: token, name: p.attribute("Name") ?? token,
                                    videoSourceToken: conf?.child("VideoSource")?.child("SourceToken")?.trimmedText,
                                    encoding: enc?.child("Encoding")?.trimmedText,
                                    width: Int(res?.child("Width")?.trimmedText ?? "") ?? 0,
                                    height: Int(res?.child("Height")?.trimmedText ?? "") ?? 0,
                                    frameRate: Int(Double(enc?.child("RateControl")?.child("FrameRateLimit")?.trimmedText ?? "") ?? 0),
                                    hasPTZ: conf?.child("PTZ") != nil, usesMedia2: true)
            }.filter { $0.width > 0 || $0.encoding != nil }
            if !profiles.isEmpty { return profiles }
        }
        let url = services[Self.nsMedia] ?? deviceURL
        let body = try await soap("<GetProfiles xmlns=\"\(Self.nsMedia)\"/>", to: url)
        return body.descendants("Profiles").compactMap { p -> ONVIFProfile? in
            guard let token = p.attribute("token") else { return nil }
            let enc = p.child("VideoEncoderConfiguration")
            let res = enc?.child("Resolution")
            return ONVIFProfile(token: token, name: p.child("Name")?.trimmedText ?? token,
                                videoSourceToken: p.child("VideoSourceConfiguration")?.child("SourceToken")?.trimmedText,
                                encoding: enc?.child("Encoding")?.trimmedText,
                                width: Int(res?.child("Width")?.trimmedText ?? "") ?? 0,
                                height: Int(res?.child("Height")?.trimmedText ?? "") ?? 0,
                                frameRate: Int(enc?.child("RateControl")?.child("FrameRateLimit")?.trimmedText ?? ""),
                                hasPTZ: p.child("PTZConfiguration") != nil, usesMedia2: false)
        }
    }

    public func streamURI(profile: ONVIFProfile) async throws -> URL {
        let body: XNode
        if profile.usesMedia2, let m2 = services[Self.nsMedia2] {
            body = try await soap("<GetStreamUri xmlns=\"\(Self.nsMedia2)\"><Protocol>RtspUnicast</Protocol><ProfileToken>\(profile.token.xmlEscaped)</ProfileToken></GetStreamUri>", to: m2)
        } else {
            body = try await soap("""
            <GetStreamUri xmlns="\(Self.nsMedia)"><StreamSetup><Stream xmlns="\(Self.nsSchema)">RTP-Unicast</Stream>\
            <Transport xmlns="\(Self.nsSchema)"><Protocol>RTSP</Protocol></Transport></StreamSetup>\
            <ProfileToken>\(profile.token.xmlEscaped)</ProfileToken></GetStreamUri>
            """, to: services[Self.nsMedia] ?? deviceURL)
        }
        guard let text = body.first("Uri")?.trimmedText, var comps = URLComponents(string: text) else { throw ONVIFError.badResponse }
        // Use the address we reached the device on (reported URIs may carry internal IPs).
        comps.host = deviceURL.host
        comps.user = nil
        comps.password = nil
        guard let url = comps.url else { throw ONVIFError.badResponse }
        return url
    }

    public func snapshotURI(profile: ONVIFProfile) async throws -> URL? {
        let body: XNode
        if profile.usesMedia2, let m2 = services[Self.nsMedia2] {
            body = try await soap("<GetSnapshotUri xmlns=\"\(Self.nsMedia2)\"><ProfileToken>\(profile.token.xmlEscaped)</ProfileToken></GetSnapshotUri>", to: m2)
        } else {
            body = try await soap("<GetSnapshotUri xmlns=\"\(Self.nsMedia)\"><ProfileToken>\(profile.token.xmlEscaped)</ProfileToken></GetSnapshotUri>",
                                  to: services[Self.nsMedia] ?? deviceURL)
        }
        return body.first("Uri").flatMap { URL(string: $0.trimmedText) }
    }

    // MARK: PTZ

    private var ptzURL: URL { services[Self.nsPTZ] ?? services[Self.nsMedia] ?? deviceURL }

    public func continuousMove(profile: String, pan: Double, tilt: Double, zoom: Double) async throws {
        if services.isEmpty { try await loadServices() }
        var velocity = ""
        if pan != 0 || tilt != 0 {
            velocity += "<PanTilt xmlns=\"\(Self.nsSchema)\" x=\"\(String(format: "%.2f", pan))\" y=\"\(String(format: "%.2f", tilt))\"/>"
        }
        if zoom != 0 { velocity += "<Zoom xmlns=\"\(Self.nsSchema)\" x=\"\(String(format: "%.2f", zoom))\"/>" }
        _ = try await soap("<ContinuousMove xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken><Velocity>\(velocity)</Velocity></ContinuousMove>", to: ptzURL)
    }

    public func stop(profile: String) async throws {
        if services.isEmpty { try await loadServices() }
        _ = try await soap("<Stop xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>", to: ptzURL)
    }

    public func presets(profile: String) async throws -> [ONVIFPreset] {
        if services.isEmpty { try await loadServices() }
        let body = try await soap("<GetPresets xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken></GetPresets>", to: ptzURL)
        return body.descendants("Preset").compactMap { p in
            guard let token = p.attribute("token") else { return nil }
            let name = p.child("Name")?.trimmedText ?? ""
            return ONVIFPreset(token: token, name: name.isEmpty ? L("Preset %@", token) : name)
        }
    }

    public func gotoPreset(profile: String, preset: String) async throws {
        if services.isEmpty { try await loadServices() }
        _ = try await soap("<GotoPreset xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken><PresetToken>\(preset.xmlEscaped)</PresetToken></GotoPreset>", to: ptzURL)
    }

    @discardableResult
    public func setPreset(profile: String, name: String) async throws -> String? {
        if services.isEmpty { try await loadServices() }
        let body = try await soap("<SetPreset xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken><PresetName>\(name.xmlEscaped)</PresetName></SetPreset>", to: ptzURL)
        return body.first("PresetToken")?.trimmedText
    }

    public func removePreset(profile: String, preset: String) async throws {
        if services.isEmpty { try await loadServices() }
        _ = try await soap("<RemovePreset xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(profile.xmlEscaped)</ProfileToken><PresetToken>\(preset.xmlEscaped)</PresetToken></RemovePreset>", to: ptzURL)
    }
}

extension ISO8601DateFormatter {
    static let onvif: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
