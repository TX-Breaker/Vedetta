import Foundation

public enum AudioCodec: String, Sendable, Codable {
    case pcmu = "G.711 µ-law"
    case pcma = "G.711 A-law"
    case aac = "AAC"
    case l16 = "PCM"
}

public struct AudioTrackInfo: Sendable {
    public var codec: AudioCodec
    public var sampleRate: Int
    public var channels: Int
    /// AudioSpecificConfig for AAC (from SDP `config=`).
    public var aacConfig: Data?
    public init(codec: AudioCodec, sampleRate: Int, channels: Int, aacConfig: Data? = nil) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels; self.aacConfig = aacConfig
    }
}

public struct AudioFrame: Sendable {
    public var data: Data
    public var rtpTimestamp: UInt32
    public init(data: Data, rtpTimestamp: UInt32) { self.data = data; self.rtpTimestamp = rtpTimestamp }
}

/// Depacketizes G.711, L16 and AAC (RFC 3640 mpeg4-generic, AAC-hbr) payloads.
public final class AudioDepacketizer {
    public let info: AudioTrackInfo
    private let sizeLength: Int
    private let indexLength: Int
    private let indexDeltaLength: Int

    public init(info: AudioTrackInfo, fmtp: [String: String] = [:]) {
        self.info = info
        sizeLength = Int(fmtp["sizelength"] ?? "13") ?? 13
        indexLength = Int(fmtp["indexlength"] ?? "3") ?? 3
        indexDeltaLength = Int(fmtp["indexdeltalength"] ?? "3") ?? 3
    }

    public static func trackInfo(for map: SDPMedia.RTPMap, fmtp: [String: String]) -> AudioTrackInfo? {
        switch map.encoding {
        case "PCMU": return AudioTrackInfo(codec: .pcmu, sampleRate: map.clockRate, channels: max(1, map.channels))
        case "PCMA": return AudioTrackInfo(codec: .pcma, sampleRate: map.clockRate, channels: max(1, map.channels))
        case "L16": return AudioTrackInfo(codec: .l16, sampleRate: map.clockRate, channels: max(1, map.channels))
        case "MPEG4-GENERIC":
            let mode = (fmtp["mode"] ?? "AAC-hbr").lowercased()
            guard mode.contains("aac") else { return nil }
            let config = fmtp["config"].flatMap(Data.init(hexString:))
            return AudioTrackInfo(codec: .aac, sampleRate: map.clockRate, channels: max(1, map.channels), aacConfig: config)
        default:
            return nil
        }
    }

    public func push(_ packet: RTPPacket) -> [AudioFrame] {
        switch info.codec {
        case .pcmu, .pcma, .l16:
            return [AudioFrame(data: packet.payload, rtpTimestamp: packet.timestamp)]
        case .aac:
            return parseAAC(packet)
        }
    }

    private func parseAAC(_ packet: RTPPacket) -> [AudioFrame] {
        let p = packet.payload
        guard p.count >= 2 else { return [] }
        let headersLengthBits = Int(p[p.startIndex]) << 8 | Int(p[p.startIndex + 1])
        let headersBytes = (headersLengthBits + 7) / 8
        guard p.count >= 2 + headersBytes else { return [] }
        let headerBits = sizeLength + indexLength
        guard headerBits > 0 else { return [] }
        var reader = BitReader(data: p.subdata(in: (p.startIndex + 2)..<(p.startIndex + 2 + headersBytes)))
        var sizes: [Int] = []
        var consumed = 0
        var first = true
        while consumed + (first ? sizeLength + indexLength : sizeLength + indexDeltaLength) <= headersLengthBits {
            let size = reader.read(sizeLength)
            _ = reader.read(first ? indexLength : indexDeltaLength)
            consumed += sizeLength + (first ? indexLength : indexDeltaLength)
            first = false
            sizes.append(size)
        }
        var frames: [AudioFrame] = []
        var offset = p.startIndex + 2 + headersBytes
        let samplesPerFrame: UInt32 = 1024
        for (k, size) in sizes.enumerated() {
            guard size > 0, offset + size <= p.endIndex else { break }
            frames.append(AudioFrame(data: p.subdata(in: offset..<(offset + size)),
                                     rtpTimestamp: packet.timestamp &+ UInt32(k) * samplesPerFrame))
            offset += size
        }
        return frames
    }
}

struct BitReader {
    let data: Data
    var bitPos = 0
    init(data: Data) { self.data = data }
    mutating func read(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let byteIndex = data.startIndex + bitPos / 8
            guard byteIndex < data.endIndex else { return v }
            let bit = (data[byteIndex] >> (7 - UInt8(bitPos % 8))) & 1
            v = (v << 1) | Int(bit)
            bitPos += 1
        }
        return v
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.trimmingCharacters(in: .whitespaces))
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }
}
