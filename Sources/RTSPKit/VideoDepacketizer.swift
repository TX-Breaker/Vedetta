import Foundation

public enum VideoCodec: String, Sendable, Codable {
    case h264 = "H.264"
    case h265 = "H.265"
}

/// One coded picture: its NAL units (without start codes) plus timing.
public struct AccessUnit: Sendable {
    public var nalus: [Data]
    public var rtpTimestamp: UInt32
    public var isKeyframe: Bool
    public var onvifTime: Date?
    public var byteCount: Int { nalus.reduce(0) { $0 + $1.count } }
    public init(nalus: [Data], rtpTimestamp: UInt32, isKeyframe: Bool, onvifTime: Date? = nil) {
        self.nalus = nalus; self.rtpTimestamp = rtpTimestamp; self.isKeyframe = isKeyframe; self.onvifTime = onvifTime
    }
}

/// Parameter sets needed to build a decoder configuration.
public struct VideoParameterSets: Equatable, Sendable {
    public var vps: Data?
    public var sps: Data?
    public var pps: Data?
    public init(vps: Data? = nil, sps: Data? = nil, pps: Data? = nil) { self.vps = vps; self.sps = sps; self.pps = pps }
    public var isComplete: Bool { sps != nil && pps != nil }
    public func isComplete(for codec: VideoCodec) -> Bool {
        codec == .h264 ? isComplete : (isComplete && vps != nil)
    }
}

/// RTP depacketizer for H.264 (RFC 6184) and H.265 (RFC 7798).
public final class VideoDepacketizer {
    public let codec: VideoCodec
    public private(set) var parameterSets = VideoParameterSets()
    public var onParameterSetsChanged: ((VideoParameterSets) -> Void)?

    private var currentNALs: [Data] = []
    private var currentTimestamp: UInt32?
    private var currentOnvifTime: Date?
    private var fragment: Data?
    private var lastSequence: UInt16?

    public init(codec: VideoCodec, sprop: VideoParameterSets? = nil) {
        self.codec = codec
        if let sprop { parameterSets = sprop }
    }

    /// Feeds one RTP packet; returns completed access units.
    public func push(_ packet: RTPPacket) -> [AccessUnit] {
        var output: [AccessUnit] = []
        if let last = lastSequence, packet.sequence != last &+ 1 {
            fragment = nil  // packet loss: drop the partial fragment
        }
        lastSequence = packet.sequence

        if let ts = currentTimestamp, ts != packet.timestamp, !currentNALs.isEmpty {
            if let au = flush() { output.append(au) }
        }
        currentTimestamp = packet.timestamp
        if let t = packet.onvifTime { currentOnvifTime = t }

        switch codec {
        case .h264: handleH264(packet.payload)
        case .h265: handleH265(packet.payload)
        }

        if packet.marker, let au = flush() { output.append(au) }
        return output
    }

    private func flush() -> AccessUnit? {
        defer { currentNALs.removeAll(keepingCapacity: true); currentOnvifTime = nil }
        guard let ts = currentTimestamp, !currentNALs.isEmpty else { return nil }
        let key = currentNALs.contains { isKeyframeNAL($0) }
        let vcl = currentNALs.filter { !isParameterSetOrAUD($0) }
        guard !vcl.isEmpty else { return nil }
        return AccessUnit(nalus: vcl, rtpTimestamp: ts, isKeyframe: key, onvifTime: currentOnvifTime)
    }

    // MARK: H.264

    private func handleH264(_ p: Data) {
        guard let first = p.first else { return }
        let type = first & 0x1F
        switch type {
        case 1...23:
            addNAL(p)
        case 24: // STAP-A
            var i = p.startIndex + 1
            while i + 2 <= p.endIndex {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.endIndex else { break }
                addNAL(p.subdata(in: i..<(i + size)))
                i += size
            }
        case 28: // FU-A
            guard p.count >= 2 else { return }
            let fuHeader = p[p.startIndex + 1]
            let start = fuHeader & 0x80 != 0
            let end = fuHeader & 0x40 != 0
            let nalHeader = (first & 0xE0) | (fuHeader & 0x1F)
            let body = p.subdata(in: (p.startIndex + 2)..<p.endIndex)
            if start {
                var d = Data([nalHeader]); d.append(body); fragment = d
            } else if fragment != nil {
                fragment!.append(body)
            }
            if end, let f = fragment { addNAL(f); fragment = nil }
        default:
            break
        }
    }

    // MARK: H.265

    private func handleH265(_ p: Data) {
        guard p.count >= 2 else { return }
        let b0 = p[p.startIndex], b1 = p[p.startIndex + 1]
        let type = (b0 >> 1) & 0x3F
        switch type {
        case 48: // Aggregation packet
            var i = p.startIndex + 2
            while i + 2 <= p.endIndex {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.endIndex else { break }
                addNAL(p.subdata(in: i..<(i + size)))
                i += size
            }
        case 49: // Fragmentation unit
            guard p.count >= 3 else { return }
            let fu = p[p.startIndex + 2]
            let start = fu & 0x80 != 0
            let end = fu & 0x40 != 0
            let fuType = fu & 0x3F
            let h0 = (b0 & 0x81) | (fuType << 1)
            let body = p.subdata(in: (p.startIndex + 3)..<p.endIndex)
            if start {
                var d = Data([h0, b1]); d.append(body); fragment = d
            } else if fragment != nil {
                fragment!.append(body)
            }
            if end, let f = fragment { addNAL(f); fragment = nil }
        case 50: // PACI - unsupported
            break
        default:
            addNAL(p)
        }
    }

    // MARK: NAL helpers

    private func addNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let t = nalType(nal)
        var changed = false
        switch codec {
        case .h264:
            if t == 7, parameterSets.sps != nal { parameterSets.sps = nal; changed = true }
            if t == 8, parameterSets.pps != nal { parameterSets.pps = nal; changed = true }
        case .h265:
            if t == 32, parameterSets.vps != nal { parameterSets.vps = nal; changed = true }
            if t == 33, parameterSets.sps != nal { parameterSets.sps = nal; changed = true }
            if t == 34, parameterSets.pps != nal { parameterSets.pps = nal; changed = true }
        }
        if changed { onParameterSetsChanged?(parameterSets) }
        currentNALs.append(nal)
    }

    public func nalType(_ nal: Data) -> UInt8 {
        guard let f = nal.first else { return 0 }
        return codec == .h264 ? (f & 0x1F) : ((f >> 1) & 0x3F)
    }

    private func isKeyframeNAL(_ nal: Data) -> Bool {
        let t = nalType(nal)
        return codec == .h264 ? t == 5 : (16...21).contains(t)
    }

    private func isParameterSetOrAUD(_ nal: Data) -> Bool {
        let t = nalType(nal)
        switch codec {
        case .h264: return t == 7 || t == 8 || t == 9
        case .h265: return t == 32 || t == 33 || t == 34 || t == 35
        }
    }

    /// Decodes `sprop-parameter-sets` (H.264) or `sprop-vps/sps/pps` (H.265) from SDP fmtp.
    public static func parameterSets(codec: VideoCodec, fmtp: [String: String]) -> VideoParameterSets {
        func b64(_ s: String?) -> Data? {
            guard let s, !s.isEmpty else { return nil }
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
        var ps = VideoParameterSets()
        switch codec {
        case .h264:
            let sets = (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap { b64(String($0)) }
            for s in sets {
                switch (s.first ?? 0) & 0x1F {
                case 7: ps.sps = s
                case 8: ps.pps = s
                default: break
                }
            }
        case .h265:
            ps.vps = b64(fmtp["sprop-vps"])
            ps.sps = b64(fmtp["sprop-sps"])
            ps.pps = b64(fmtp["sprop-pps"])
        }
        return ps
    }
}
