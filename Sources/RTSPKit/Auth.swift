import Foundation
import CryptoKit

/// A parsed `WWW-Authenticate` challenge (RFC 7235 / 7616).
public struct AuthChallenge: Equatable, Sendable {
    public enum Scheme: String, Sendable { case basic, digest }
    public var scheme: Scheme
    public var params: [String: String]

    public var realm: String { params["realm"] ?? "" }
    public var nonce: String { params["nonce"] ?? "" }
    public var opaque: String? { params["opaque"] }
    public var algorithm: String { (params["algorithm"] ?? "MD5").uppercased() }
    public var qop: [String] {
        (params["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Parses a single header value such as `Digest realm="vigi", nonce="a25f", stale="FALSE"`.
    public static func parse(_ header: String) -> AuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else {
            if trimmed.lowercased() == "basic" { return AuthChallenge(scheme: .basic, params: [:]) }
            return nil
        }
        let schemeName = trimmed[..<space].lowercased()
        guard let scheme = Scheme(rawValue: schemeName) else { return nil }
        return AuthChallenge(scheme: scheme, params: parseParams(String(trimmed[space...])))
    }

    static func parseParams(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = s.startIndex
        func skipSpacesAndCommas() {
            while i < s.endIndex, s[i] == " " || s[i] == "," || s[i] == "\t" { i = s.index(after: i) }
        }
        while i < s.endIndex {
            skipSpacesAndCommas()
            guard i < s.endIndex else { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=" , s[i] != "," { i = s.index(after: i) }
            let key = s[keyStart..<i].trimmingCharacters(in: .whitespaces).lowercased()
            guard i < s.endIndex, s[i] == "=" else { continue }
            i = s.index(after: i)
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i])
                    i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let vStart = i
                while i < s.endIndex, s[i] != "," { i = s.index(after: i) }
                value = s[vStart..<i].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

/// Builds `Authorization` headers for RTSP/HTTP requests using Basic or Digest (MD5, SHA-256, -sess).
public final class Authenticator: @unchecked Sendable {
    public let username: String
    public let password: String
    private var challenge: AuthChallenge?
    private var nonceCount: UInt32 = 0
    private let lock = NSLock()

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var hasChallenge: Bool { lock.withLock { challenge != nil } }

    /// Picks the strongest supported challenge among the `WWW-Authenticate` headers.
    @discardableResult
    public func update(withHeaders headers: [String]) -> Bool {
        let parsed = headers.compactMap(AuthChallenge.parse)
        func rank(_ c: AuthChallenge) -> Int {
            switch c.scheme {
            case .basic: return 1
            case .digest:
                switch c.algorithm {
                case "SHA-256", "SHA-256-SESS": return 4
                case "MD5", "MD5-SESS": return 3
                default: return 0
                }
            }
        }
        guard let best = parsed.filter({ rank($0) > 0 }).max(by: { rank($0) < rank($1) }) else { return false }
        lock.withLock {
            if challenge?.nonce != best.nonce { nonceCount = 0 }
            challenge = best
        }
        return true
    }

    public func authorization(method: String, uri: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let c = challenge else { return nil }
        switch c.scheme {
        case .basic:
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return "Basic \(token)"
        case .digest:
            nonceCount += 1
            return Self.digestHeader(challenge: c, username: username, password: password,
                                     method: method, uri: uri, nc: nonceCount,
                                     cnonce: Self.randomHex(8))
        }
    }

    static func digestHeader(challenge c: AuthChallenge, username: String, password: String,
                             method: String, uri: String, nc: UInt32, cnonce: String) -> String {
        let algo = c.algorithm
        let hash: (String) -> String = algo.hasPrefix("SHA-256") ? Hash.sha256Hex : Hash.md5Hex
        var ha1 = hash("\(username):\(c.realm):\(password)")
        if algo.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(c.nonce):\(cnonce)") }
        let ha2 = hash("\(method):\(uri)")
        let useQop = c.qop.contains("auth")
        let ncString = String(format: "%08x", nc)
        let response = useQop
            ? hash("\(ha1):\(c.nonce):\(ncString):\(cnonce):auth:\(ha2)")
            : hash("\(ha1):\(c.nonce):\(ha2)")
        var parts = [
            "username=\"\(username)\"",
            "realm=\"\(c.realm)\"",
            "nonce=\"\(c.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\"",
        ]
        if c.params["algorithm"] != nil { parts.append("algorithm=\(c.params["algorithm"]!)") }
        if let opaque = c.opaque { parts.append("opaque=\"\(opaque)\"") }
        if useQop { parts += ["qop=auth", "nc=\(ncString)", "cnonce=\"\(cnonce)\""] }
        return "Digest " + parts.joined(separator: ", ")
    }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

public enum Hash {
    public static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
