import Foundation
import VigiKit
import ONVIFKit
import NetKit
import VedettaL10n

/// One shared session per device: the API clients every feature uses (so a single login serves live view,
/// playback, events and exports) and the AccessGuard that protects the account from lockouts.
@MainActor
public final class DeviceClients {
    public static let shared = DeviceClients()
    private var guards: [UUID: (guard: AccessGuard, signature: String)] = [:]
    private var vigi: [UUID: VigiClient] = [:]
    private var onvif: [UUID: ONVIFClient] = [:]
    private var known: [UUID: Device] = [:]
    /// Called on the main actor whenever a device's access state changes.
    public var onStateChange: ((UUID, AccessState) -> Void)?
    /// Test hooks: reachability check and clock used by new guards.
    public var probeOverride: ((Device) -> @Sendable () async -> Bool)?
    public var clockOverride: AccessClock?

    // MARK: Guards

    private static func signature(_ d: Device) -> String {
        "\(d.kind.rawValue)|\(d.host)|\(d.httpPort)|\(d.rtspPort)|\(d.onvifURL ?? "")"
    }

    public func accessGuard(for d: Device) -> AccessGuard {
        let sig = Self.signature(d)
        known[d.id] = d
        if let g = guards[d.id], g.signature == sig { return g.guard }
        guards[d.id]?.guard.retire()
        let g = AccessGuard(label: "\(d.name) (\(d.host))",
                            initial: d.storedCredentials == nil ? .missingPassword : .unverified,
                            clock: clockOverride ?? SystemAccessClock(),
                            probe: probeOverride?(d) ?? Self.probe(for: d))
        let id = d.id
        g.observe { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onStateChange?(id, state) } }
        }
        if d.kind == .vigiNVR {
            let (host, port) = (d.host, d.httpPort)
            g.setLockProbe { await VigiClient(host: host, port: port, username: "", password: "").lockStatus() }
        }
        // Always the device's current session (never one that was signed out).
        g.setCredentialCheck { [weak self] in await self?.checkCredentials(id) }
        // First check = a request every user may make, before any video stream (see verify).
        if d.kind == .vigiNVR || d.onvifURL != nil { g.setVerifier { [weak self] in await self?.verify(id) } }
        guards[d.id] = (g, sig)
        if d.storedCredentials != nil { g.verifyIfNeeded() }
        return g
    }

    /// The device's first check with the slot reserved: VIGI API login (or a light request on the open
    /// session), ONVIF GetDeviceInformation. Never with a missing password.
    func verify(_ id: UUID) async {
        guard let d = known[id], d.storedCredentials != nil else { return }
        if d.kind == .vigiNVR {
            try? await vigi(for: d).ensureSession(reserved: true)
        } else if let c = onvif(for: d) {
            await c.verifyCredentials(reserved: true)
        }
    }

    public func existingGuard(for id: UUID) -> AccessGuard? { guards[id]?.guard }

    public func state(of d: Device) -> AccessState { accessGuard(for: d).state }

    /// Unauthenticated check used while the device is unreachable.
    nonisolated static func probe(for d: Device) -> @Sendable () async -> Bool {
        switch d.kind {
        case .vigiNVR:
            let url = URL(string: d.httpPort == 443 ? "https://\(d.host)/" : "https://\(d.host):\(d.httpPort)/")
            return { guard let url else { return false }; return await Reachability.http(url) }
        case .onvifNVR, .onvifCamera:
            if let s = d.onvifURL, let u = URL(string: s) { return { await Reachability.http(u) } }
            let (host, port) = (d.host, d.rtspPort)
            return { await Reachability.rtsp(host: host, port: port) }
        case .rtspRecorder, .rtspCamera:
            let (host, port) = (d.host, d.rtspPort)
            return { await Reachability.rtsp(host: host, port: port) }
        }
    }

    /// true = the credentials still work (a refusal was only a missing permission), false = refused, nil = unknown.
    func checkCredentials(_ id: UUID) async -> Bool? {
        if let c = vigi[id] { return await c.credentialsStillValid() }
        if let c = onvif[id] { return await c.credentialsStillValid() }
        return nil
    }

    // MARK: Clients

    public func vigi(for d: Device) -> VigiClient {
        if let c = vigi[d.id], c.host == d.host, c.port == d.httpPort, c.username == d.username { return c }
        let creds = d.credentials
        let g = accessGuard(for: d)
        let c = VigiClient(host: d.host, port: d.httpPort, username: creds.username, password: creds.password, accessGuard: g)
        replaceVigi(d.id, with: c)
        return c
    }

    public func onvif(for d: Device) -> ONVIFClient? {
        guard let s = d.onvifURL, let url = URL(string: s) else { return nil }
        if let c = onvif[d.id], c.deviceURL == url { return c }
        let creds = d.credentials
        let c = ONVIFClient(deviceURL: url, username: creds.username, password: creds.password, accessGuard: accessGuard(for: d))
        onvif[d.id] = c
        return c
    }

    private func replaceVigi(_ id: UUID, with c: VigiClient?) {
        let old = vigi[id]
        vigi[id] = c
        // Never leave an orphan session on the recorder.
        if let old, old !== c {
            let reachable = existingGuard(for: id)?.state.isOffline != true
            Task { if reachable { await old.logout() } else { await old.dropSession() } }
        }
    }

    /// Takes over the session opened while connecting (no second login) and marks the credentials as confirmed.
    public func adopt(_ result: ConnectResult) {
        let d = result.device
        let g = accessGuard(for: d)
        onvif[d.id] = nil
        result.session?.bind(to: g)       // sessions opened by the wizard had no guard yet
        replaceVigi(d.id, with: result.session)
        g.reset(verified: true)
    }

    /// New password or user: forget the clients (the previous session is closed on the recorder).
    public func invalidate(_ id: UUID) {
        replaceVigi(id, with: nil)
        onvif[id] = nil
    }

    /// "Sign out" (also the first half of "Switch user"): stops every attempt and retry, closes the device's
    /// streams (RTSP TEARDOWN), ends the session on the recorder — never logging in to do so, and only locally
    /// when the recorder is unreachable or the account refused/locked — and deletes the saved password.
    public func signOut(_ d: Device, pool: StreamPool) async {
        let g = accessGuard(for: d)
        let previous = g.state
        g.signOut()
        pool.restart(keysWithPrefix: d.id.uuidString)
        await endSession(d, previousState: previous)
        CredentialCache.shared.remove(d.id)
    }

    /// Ends the session after a sign out (the guard is already signed out, so nothing reconnects):
    /// logs out on the recorder when it was reachable — never logging in to do so — otherwise only
    /// clears the local state (unreachable recorder, refused or locked account).
    public func endSession(_ d: Device, previousState: AccessState) async {
        let client = vigi.removeValue(forKey: d.id)
        onvif[d.id] = nil
        guard let client else { return }
        if previousState.isUsable {
            await client.logout(timeout: 4)
        } else {
            await client.dropSession()
            existingGuard(for: d.id)?.note("logout \(client.username)", "local only", AccessGuard.describe(previousState).0)
        }
    }

    /// Quitting: ends the recorder sessions (best effort, bounded) so none is left open on the recorder.
    public func logoutAll(timeout: TimeInterval = 1.5) {
        let clients = vigi.compactMap { id, c in existingGuard(for: id)?.state.isUsable == true ? c : nil }
        guard !clients.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { g in
                for c in clients { g.addTask { await c.logout(timeout: timeout) } }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout + 0.5)
    }

    /// Removes everything about a device (after "Remove").
    public func forget(_ id: UUID) {
        replaceVigi(id, with: nil)
        onvif[id] = nil
        guards[id]?.guard.retire()
        guards[id] = nil
    }
}
