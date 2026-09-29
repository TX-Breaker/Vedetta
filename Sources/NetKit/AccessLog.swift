import Foundation
import Network
import os

/// Local log of every connection attempt (time, device, action, result, error code) for diagnosis.
/// Never contains passwords or session tokens. Rotated at about 1 MB.
public final class AccessLog: @unchecked Sendable {
    public static let shared = AccessLog(directory: AppPaths.supportDirectory.appendingPathComponent("Logs", isDirectory: true))

    public let fileURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "vedetta.accesslog", qos: .utility)
    private let logger = Logger(subsystem: "it.vedetta.app", category: "access")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public init(directory: URL, maxBytes: Int = 1_000_000) {
        fileURL = directory.appendingPathComponent("connections.log")
        self.maxBytes = maxBytes
    }

    /// One line: time, device, action, result, detail (tab separated).
    public func record(_ device: String, _ action: String, _ result: String, _ detail: String? = nil) {
        let when = Date()
        queue.async { [self] in
            let fields = [formatter.string(from: when), device, action, result, detail ?? ""]
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            let line = fields.joined(separator: "\t") + "\n"
            logger.info("\(line, privacy: .public)")
            append(line)
        }
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes {
            let old = fileURL.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Waits until the pending lines are written (tests, "Show log").
    public func flush() { queue.sync {} }

    public func lines() -> [String] {
        flush()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

/// Unauthenticated reachability checks: they never send credentials, so they can never lock an account.
public enum Reachability {
    /// An HTTP answer, whatever the status, means the device is up. A device that accepts the connection but
    /// never answers (hung web server) counts as down. Nothing is sent but `GET /`, so the self-signed
    /// certificate is accepted for this check only.
    public static func http(_ url: URL, timeout: TimeInterval = 4) async -> Bool {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: ProbeDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: req)
            return true
        } catch let e as URLError {
            switch e.code {
            case .clientCertificateRejected, .clientCertificateRequired, .badServerResponse,
                 .userAuthenticationRequired, .userCancelledAuthentication:
                return true   // the device answered
            default:
                return false
            }
        } catch {
            return false
        }
    }

    private final class ProbeDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: t))
            } else {
                // Never answer an authentication request: this check sends no credentials.
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// RTSP `OPTIONS` without credentials: any RTSP answer (even 401) means the device is up.
    public static func rtsp(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            func done(_ ok: Bool) { if once.take() { conn.cancel(); c.resume(returning: ok) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "OPTIONS rtsp://\(host):\(port)/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Vedetta\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 5, maximumLength: 512) { data, _, _, _ in
                        done(data.map { String(decoding: $0, as: UTF8.self).hasPrefix("RTSP/") } ?? false)
                    }
                case .failed, .waiting, .cancelled: done(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { done(false) }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    public static func tcp(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { conn.cancel(); c.resume(returning: true) }
                case .failed, .waiting, .cancelled: if once.take() { conn.cancel(); c.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.take() { conn.cancel(); c.resume(returning: false) }
            }
        }
    }
}
