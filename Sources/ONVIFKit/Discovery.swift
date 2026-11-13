import Foundation
import Darwin

public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    public var ip: String
    public var serviceURL: URL
    public var name: String
    public var hardware: String
    public var isRecorder: Bool
    public var hasPTZ: Bool
    public var id: String { ip }

    public var isVigi: Bool { (name + hardware).uppercased().contains("VIGI") }
}

/// ONVIF WS-Discovery (multicast probe on 239.255.255.250:3702).
public enum ONVIFDiscovery {
    public static func probe(timeout: TimeInterval = 3) async -> [DiscoveredDevice] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runProbe(timeout: timeout))
            }
        }
    }

    private static func probeMessage(types: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>\
        <e:Body><d:Probe><d:Types>\(types)</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    private static func runProbe(timeout: TimeInterval) -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(3702).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        for types in ["dn:NetworkVideoTransmitter", ""] {
            let msg = Array(probeMessage(types: types).utf8)
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }

        var found: [String: DiscoveredDevice] = [:]
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            // inet_ntop, not inet_ntoa: the latter returns a shared static buffer (not thread-safe).
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
            let ip = String(cString: text)
            let data = Data(buffer[0..<n])
            guard let root = XMLTree.parse(data), let match = root.first("ProbeMatch") else { continue }
            let xaddrs = (match.child("XAddrs")?.trimmedText ?? "").split(separator: " ").map(String.init)
            guard !xaddrs.isEmpty else { continue }
            // Prefer an XAddr that uses the responding IP.
            let chosen = xaddrs.first { $0.contains(ip) } ?? xaddrs.first!
            guard let url = URL(string: chosen) else { continue }
            let scopes = (match.child("Scopes")?.trimmedText ?? "").split(separator: " ").map(String.init)
            func scope(_ key: String) -> String? {
                scopes.first { $0.contains("/\(key)/") }.flatMap { $0.components(separatedBy: "/\(key)/").last?.removingPercentEncoding }
            }
            let types = match.child("Types")?.trimmedText ?? ""
            let isONVIF = types.contains("NetworkVideoTransmitter") || types.contains("NetworkVideoRecorder")
                || types.contains("Device") && chosen.lowercased().contains("onvif") || chosen.lowercased().contains("/onvif/")
            guard isONVIF else { continue }
            let name = scope("name") ?? scope("hardware") ?? ip
            let hardware = scope("hardware") ?? ""
            let scopeText = scopes.joined(separator: " ").lowercased()
            let recorder = types.contains("NetworkVideoRecorder") || scopeText.contains("/type/nvr")
            let ptz = scopeText.contains("/type/ptz")
            if var existing = found[ip] {
                if url.scheme == "https" && existing.serviceURL.scheme != "https" { existing.serviceURL = url }
                found[ip] = existing
            } else {
                found[ip] = DiscoveredDevice(ip: ip, serviceURL: url, name: name, hardware: hardware,
                                             isRecorder: recorder, hasPTZ: ptz)
            }
        }
        return found.values.sorted { lhs, rhs in
            if lhs.isRecorder != rhs.isRecorder { return lhs.isRecorder }
            return lhs.ip.compare(rhs.ip, options: .numeric) == .orderedAscending
        }
    }
}
