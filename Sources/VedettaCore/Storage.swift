import Foundation
import Security
import NetKit
import VedettaL10n

/// Device passwords live only in the macOS Keychain.
public enum Keychain {
    static var service: String { AppPaths.isIsolated ? "it.vedetta.devices.dev" : "it.vedetta.devices" }

    public static func setPassword(_ password: String, for id: UUID) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = Data(password.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel] = L("Vedetta – device credentials")
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func password(for id: UUID) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: id.uuidString, kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(for id: UUID) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

/// JSON persistence for non-secret configuration.
/// Writes are atomic and off the main thread; the previous version is kept as `.bak` (once per launch) and an
/// unreadable file is set aside instead of being overwritten, so settings are never silently lost.
public final class JSONStore<Value: Codable>: @unchecked Sendable {
    private let url: URL
    private static var queue: DispatchQueue { StoreQueue.shared }
    private let lock = NSLock()
    private var backedUp = false

    public init(filename: String) {
        url = AppPaths.supportDirectory.appendingPathComponent(filename)
    }

    public init(url: URL) { self.url = url }

    public var fileURL: URL { url }
    private var backupURL: URL { url.appendingPathExtension("bak") }

    public func load() -> Value? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return decode(try? Data(contentsOf: backupURL)) }
        if let v = decode(data) { return v }
        // Unreadable (damaged, or written by an incompatible version): keep it aside and use the backup.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json"))
        return decode(try? Data(contentsOf: backupURL))
    }

    private func decode(_ data: Data?) -> Value? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        let url = self.url
        let backup = lock.withLock { () -> Bool in
            defer { backedUp = true }
            return !backedUp
        }
        let backupURL = self.backupURL
        Self.queue.async {
            let fm = FileManager.default
            if backup, fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: url, to: backupURL)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Waits until every pending write of every store is on disk (quit, export).
    public static func flushAll() { StoreQueue.shared.sync {} }
}

enum StoreQueue {
    static let shared = DispatchQueue(label: "vedetta.store", qos: .utility)
}

public struct Credentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

/// In-memory copy of device passwords, loaded from the Keychain off the main thread.
/// (A Keychain read can wait for a macOS authorization prompt, e.g. after an app update:
/// doing it on the main thread would freeze the interface.)
public final class CredentialCache: @unchecked Sendable {
    public static let shared = CredentialCache()
    private var values: [UUID: String] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vedetta.keychain", qos: .userInitiated)

    public func password(for id: UUID) -> String? { lock.withLock { values[id] } }

    public func set(_ password: String, for id: UUID) {
        lock.withLock { values[id] = password }
        queue.async { Keychain.setPassword(password, for: id) }
    }

    public func remove(_ id: UUID) {
        _ = lock.withLock { values.removeValue(forKey: id) }
        queue.async { Keychain.deletePassword(for: id) }
    }

    /// Reads all passwords in the background; `completion` runs on the main queue.
    public func preload(_ ids: [UUID], completion: @escaping @Sendable () -> Void) {
        queue.async {
            for id in ids {
                if let p = Keychain.password(for: id) { self.lock.withLock { self.values[id] = p } }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

extension Device {
    /// Credentials for connecting. Callers must not use them when `storedCredentials` is nil
    /// (the AccessGuard of the device is then in `.missingPassword` and blocks every attempt).
    public var credentials: Credentials {
        Credentials(username: username, password: CredentialCache.shared.password(for: id) ?? "")
    }

    /// nil when no password is saved (never try to log in with an empty one).
    public var storedCredentials: Credentials? {
        CredentialCache.shared.password(for: id).map { Credentials(username: username, password: $0) }
    }
}
