import Foundation
import VedettaL10n

/// Turns low-level network failures into actionable advice.
public enum NetworkHint {
    public static let localNetwork = L("If you denied Vedetta access to the local network, turn it back on in System Settings › Privacy & Security › Local Network.")

    /// true for errors typical of a blocked Local Network permission (or an unreachable LAN host).
    public static func looksLikeLocalNetworkBlock(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("no route to host") || t.contains("network is unreachable") || t.contains("offline")
            || t.contains("non è disponibile") || t.contains("host is down") || t.contains("local network")
            || t.contains("rete locale") || t.contains("policy") || t.contains("-1009")
    }

    public static func explain(_ message: String) -> String {
        looksLikeLocalNetworkBlock(message) ? "\(message)\n\(localNetwork)" : message
    }
}
