import Foundation
import Security
import CryptoKit
import VedettaL10n

public enum TrustError: LocalizedError {
    case certificateChanged(host: String)
    public var errorDescription: String? {
        switch self {
        case .certificateChanged(let host):
            return L("The security certificate of %@ has changed. If you replaced or reset the device, accept the new certificate in Settings › Advanced › Device certificates › Forget.", host)
        }
    }
}

/// Trust-on-first-use pinning for devices with self-signed certificates.
/// The first certificate seen for host:port is remembered; a later mismatch is rejected.
public final class TrustStore: @unchecked Sendable {
    public static let shared = TrustStore()
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    /// host:port keys whose last certificate did not match the pinned one (until a matching one is seen or the pin is forgotten).
    private var mismatched = Set<String>()
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? AppPaths.supportDirectory
        fileURL = dir.appendingPathComponent("trusted-certificates.json")
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            pins = dict
        }
    }

    public static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true if the server should be trusted.
    public func evaluate(host: String, port: Int, trust: SecTrust) -> Bool {
        if SecTrustEvaluateWithError(trust, nil) { return true }
        guard let fp = fingerprint(of: trust) else { return false }
        let k = Self.key(host: host, port: port)
        return lock.withLock {
            if let pinned = pins[k] {
                if pinned == fp { mismatched.remove(k); return true }
                mismatched.insert(k)
                return false
            }
            pins[k] = fp
            mismatched.remove(k)
            save()
            return true
        }
    }

    /// True when `error` comes from a certificate this store refused for host:port. A refused certificate makes
    /// URLSession report a cancelled (or TLS-failed) request: only those errors are attributed to it, so a later
    /// timeout of the same device is still reported as a network problem.
    public func refusedCertificate(host: String?, port: Int, error: Error) -> Bool {
        guard let host, let code = (error as? URLError)?.code,
              [.cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
               .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(code) else { return false }
        let k = Self.key(host: host, port: port)
        return lock.withLock { mismatched.contains(k) }
    }

    public func forget(host: String) {
        lock.withLock {
            pins = pins.filter { !$0.key.hasPrefix(host.lowercased() + ":") }
            mismatched = mismatched.filter { !$0.hasPrefix(host.lowercased() + ":") }
            save()
        }
    }

    public func forgetAll() {
        lock.withLock { pins.removeAll(); mismatched.removeAll(); save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pins) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// URLSession delegate that applies TrustStore pinning and answers HTTP Basic/Digest challenges.
public final class DeviceSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustStore: TrustStore
    private let credential: URLCredential?

    public init(trustStore: TrustStore = .shared, username: String? = nil, password: String? = nil) {
        self.trustStore = trustStore
        if let username, let password {
            credential = URLCredential(user: username, password: password, persistence: .forSession)
        } else {
            credential = nil
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return completion(.performDefaultHandling, nil) }
            if trustStore.evaluate(host: space.host, port: space.port, trust: trust) {
                completion(.useCredential, URLCredential(trust: trust))
            } else {
                completion(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault:
            if let credential, challenge.previousFailureCount == 0 {
                completion(.useCredential, credential)
            } else {
                completion(.rejectProtectionSpace, nil)
            }
        default:
            completion(.performDefaultHandling, nil)
        }
    }

    public static func makeSession(username: String? = nil, password: String? = nil, timeout: TimeInterval = 15) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config,
                          delegate: DeviceSessionDelegate(username: username, password: password),
                          delegateQueue: nil)
    }
}

public enum AppPaths {
    /// Development, self-test and command line runs never touch the user's real data.
    public static var isIsolated: Bool {
        ProcessInfo.processInfo.environment["VEDETTA_DEV"] == "1" || Bundle.main.bundleIdentifier != "it.vedetta.app"
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(isIsolated ? "Vedetta-Dev" : "Vedetta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
