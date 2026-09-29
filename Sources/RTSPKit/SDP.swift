import Foundation

public struct SDPMedia: Sendable {
    public var type: String              // "video", "audio", "application"
    public var payloadTypes: [Int]
    public var rtpmap: [Int: RTPMap] = [:]
    public var fmtp: [Int: [String: String]] = [:]
    public var control: String?
    public var attributes: [String: String] = [:]

    public struct RTPMap: Sendable {
        public var encoding: String      // uppercased, e.g. "H264", "H265", "PCMU", "MPEG4-GENERIC"
        public var clockRate: Int
        public var channels: Int
    }

    /// The first payload type with a known mapping (static PTs are mapped implicitly).
    public var primaryPayloadType: Int? { payloadTypes.first }

    public func map(for pt: Int) -> RTPMap? {
        if let m = rtpmap[pt] { return m }
        switch pt {
        case 0: return RTPMap(encoding: "PCMU", clockRate: 8000, channels: 1)
        case 8: return RTPMap(encoding: "PCMA", clockRate: 8000, channels: 1)
        case 26: return RTPMap(encoding: "JPEG", clockRate: 90000, channels: 0)
        case 96...127: return nil
        default: return nil
        }
    }
}

public struct SDPSession: Sendable {
    public var control: String?
    public var range: String?
    public var media: [SDPMedia] = []

    public static func parse(_ text: String) -> SDPSession {
        var session = SDPSession()
        var current: SDPMedia?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, line[line.index(line.startIndex, offsetBy: 1)] == "=" else { continue }
            let kind = line.first!
            let value = String(line.dropFirst(2))
            switch kind {
            case "m":
                if let m = current { session.media.append(m) }
                let parts = value.split(separator: " ").map(String.init)
                let pts = parts.dropFirst(3).compactMap { Int($0) }
                current = SDPMedia(type: parts.first?.lowercased() ?? "", payloadTypes: pts)
            case "a":
                let (name, attr) = splitAttribute(value)
                if var m = current {
                    switch name {
                    case "rtpmap":
                        if let (pt, rest) = splitPayload(attr) {
                            let comps = rest.split(separator: "/").map(String.init)
                            let enc = comps.first?.uppercased() ?? ""
                            let clock = comps.count > 1 ? Int(comps[1]) ?? 90000 : 90000
                            let ch = comps.count > 2 ? Int(comps[2]) ?? 1 : 1
                            m.rtpmap[pt] = .init(encoding: enc, clockRate: clock, channels: ch)
                        }
                    case "fmtp":
                        if let (pt, rest) = splitPayload(attr) {
                            var params: [String: String] = [:]
                            for p in rest.split(separator: ";") {
                                let kv = p.trimmingCharacters(in: .whitespaces)
                                if let eq = kv.firstIndex(of: "=") {
                                    params[kv[..<eq].lowercased()] = String(kv[kv.index(after: eq)...])
                                }
                            }
                            m.fmtp[pt] = params
                        }
                    case "control":
                        m.control = attr
                    default:
                        m.attributes[name] = attr
                    }
                    current = m
                } else {
                    if name == "control" { session.control = attr }
                    if name == "range" { session.range = attr }
                }
            default:
                break
            }
        }
        if let m = current { session.media.append(m) }
        return session
    }

    private static func splitAttribute(_ v: String) -> (String, String) {
        guard let colon = v.firstIndex(of: ":") else { return (v.lowercased(), "") }
        return (v[..<colon].lowercased(), String(v[v.index(after: colon)...]))
    }

    private static func splitPayload(_ v: String) -> (Int, String)? {
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "), let pt = Int(trimmed[..<space]) else { return nil }
        return (pt, trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces))
    }
}
