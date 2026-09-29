import Foundation

public struct RTPPacket: Sendable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data
    /// Absolute capture time from the ONVIF replay header extension (profile 0xABAC), if present.
    public var onvifTime: Date?

    public static func parse(_ data: Data) -> RTPPacket? {
        let count = data.count
        guard count >= 12 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RTPPacket? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b[0] >> 6 == 2 else { return nil }
            let padding = (b[0] & 0x20) != 0
            let hasExt = (b[0] & 0x10) != 0
            let csrc = Int(b[0] & 0x0F)
            let marker = (b[1] & 0x80) != 0
            let pt = b[1] & 0x7F
            let seq = UInt16(b[2]) << 8 | UInt16(b[3])
            let ts = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
            var offset = 12 + csrc * 4
            var onvifTime: Date?
            if hasExt {
                guard count >= offset + 4 else { return nil }
                let profile = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
                let words = Int(UInt16(b[offset + 2]) << 8 | UInt16(b[offset + 3]))
                let extStart = offset + 4
                if profile == 0xABAC, words >= 2, count >= extStart + 8 {
                    var sec: UInt32 = 0, frac: UInt32 = 0
                    for k in 0..<4 { sec = sec << 8 | UInt32(b[extStart + k]) }
                    for k in 4..<8 { frac = frac << 8 | UInt32(b[extStart + k]) }
                    // NTP epoch (1900) -> Unix epoch (1970)
                    let unix = Double(sec) - 2_208_988_800 + Double(frac) / 4_294_967_296.0
                    if unix > 946_684_800 { onvifTime = Date(timeIntervalSince1970: unix) }
                }
                offset = extStart + words * 4
            }
            var end = count
            if padding, count > offset {
                end -= Int(b[count - 1])
            }
            guard end > offset else { return nil }
            let payload = Data(bytes: raw.baseAddress!.advanced(by: offset), count: end - offset)
            return RTPPacket(payloadType: pt, marker: marker, sequence: seq, timestamp: ts, ssrc: ssrc,
                             payload: payload, onvifTime: onvifTime)
        }
    }
}

/// Converts wrapping 32-bit RTP timestamps into a monotonic 64-bit timeline.
public struct RTPTimestampUnwrapper: Sendable {
    private var last: UInt32?
    private var high: Int64 = 0
    public init() {}
    public mutating func unwrap(_ ts: UInt32) -> Int64 {
        if let last {
            let diff = Int32(bitPattern: ts &- last)
            if diff < 0, ts > last { high -= 1 << 32 }          // backwards across wrap
            else if diff > 0, ts < last { high += 1 << 32 }     // forward across wrap
        }
        last = ts
        return high + Int64(ts)
    }
    public mutating func reset() { last = nil; high = 0 }
}
