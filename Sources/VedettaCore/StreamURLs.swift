import Foundation

public enum StreamKind: Hashable, Sendable {
    case main, sub
}

public enum StreamURLs {
    /// Live URL for a channel (VIGI NVR layout: rtsp://host/live/<ch>/<1|2>/avm).
    public static func live(device: Device, channel: Channel, kind: StreamKind) -> URL? {
        switch device.kind {
        case .vigiNVR:
            let s = kind == .main ? 1 : 2
            return URL(string: "rtsp://\(hostPort(device))/live/\(channel.number)/\(s)/avm")
        case .onvifNVR, .onvifCamera, .rtspCamera, .rtspRecorder:
            let str = kind == .main ? (channel.mainURL ?? channel.subURL) : (channel.subURL ?? channel.mainURL)
            return str.flatMap(URL.init(string:))
        }
    }

    /// Replay URL for NVR recordings between two instants.
    public static func replay(device: Device, channel: Channel, from: Date, to: Date,
                              kind: StreamKind = .main, suffix: String) -> URL? {
        guard device.kind == .vigiNVR else { return nil }
        let s = kind == .main ? 1 : 2
        let st = format(from, suffix: suffix)
        let et = format(to, suffix: suffix)
        return URL(string: "rtsp://\(hostPort(device))/replay/\(channel.number)/\(s)/avm?starttime=\(st)&endtime=\(et)")
    }

    static func hostPort(_ d: Device) -> String { hostPort(host: d.host, rtspPort: d.rtspPort) }

    /// "host" or "host:port" for an RTSP URL (IPv6 addresses in brackets).
    static func hostPort(host: String, rtspPort: Int) -> String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return rtspPort == 554 ? h : "\(h):\(rtspPort)"
    }

    /// `YYYYMMDDtHHMMSSz` (UTC) or `YYYYMMDDtHHMMSSl` (local time).
    public static func format(_ date: Date, suffix: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = suffix == "z" ? TimeZone(identifier: "UTC")! : .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dt%02d%02d%02d%@", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, suffix)
    }
}
