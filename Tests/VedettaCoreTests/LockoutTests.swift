import Testing
import Foundation
import CoreGraphics
import NetKit
import RTSPKit
@testable import VigiKit
@testable import VedettaCore

/// The recorder must never see a burst of logins: these scenarios reproduce the reported lockout
/// (network drop → 5-10 logins a minute → "User has been locked" + buzzer) and the sign-out flows.
@Suite(.serialized) struct LockoutTests {

    func makeGuard(_ clock: ManualClock, _ nvr: FakeNVR) -> AccessGuard {
        AccessGuard(label: "test NVR", clock: clock, random: { 0.5 }, log: nil, probe: { nvr.reachable })
    }

    /// 10 cameras + the event monitor asking at once.
    func burst(_ c: VigiClient, _ n: Int = 10) async {
        await withTaskGroup(of: Void.self) { g in
            for ch in 1...n { g.addTask { _ = try? await c.events(channel: ch, from: Date(), to: Date()) } }
        }
    }

    // MARK: NVR offline for 2 minutes

    @Test func offlineTwoMinutesMakesNoLoginsAndReusesTheSession() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        try await c.ensureSession()
        #expect(nvr.loginAttempts == 1 && g.state == .online)

        nvr.goOffline(for: 120)
        await burst(c)
        await clock.settle()
        #expect(g.state.isOffline)

        // Two minutes of cameras and event polling trying again every 10 s.
        for _ in 0..<12 {
            await clock.advance(by: 10)
            await burst(c)
        }
        #expect(nvr.loginsWhileOffline == 0)
        #expect(nvr.loginAttempts == 1)
        #expect((1...10).contains(nvr.requestsWhileOffline))  // only the first burst reached the network
        // Unauthenticated checks with backoff: right after the failure, then 5, 15, 35, 75 s.
        #expect(g.probes == 5, "probes \(g.probes)")

        await clock.advance(by: 60)                           // next check at 155 s: back online
        #expect(g.state == .online)
        _ = try await c.channels()
        #expect(nvr.loginAttempts == 1)                       // same session, no new login
        #expect(nvr.failedLogins == 0 && !nvr.isLocked)
    }

    @Test func expiredSessionAfterOutageNeedsExactlyOneLogin() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        try await c.ensureSession()
        nvr.goOffline(for: 120)
        nvr.expireSessions()
        await burst(c)
        await clock.settle()
        await clock.advance(by: 200)
        #expect(g.state == .online)
        await burst(c)                                        // 10 requests find the session expired
        #expect(nvr.loginAttempts == 2)
        #expect(nvr.activeUsers() == ["viewer"])
    }

    @Test func backoffGrowsToFiveMinutesWithJitter() {
        let b = Backoff.standard
        #expect((0..<7).map { b.delay(attempt: $0, random: 0.5) } == [5, 10, 20, 40, 80, 160, 300])
        #expect(b.delay(attempt: 20, random: 1) == 300)
        for a in 0..<10 {
            let lo = b.delay(attempt: a, random: 0), hi = b.delay(attempt: a, random: 1)
            #expect(lo < hi || hi == 300)
            #expect(lo >= min(300, 5 * pow(2, Double(a))) * 0.8 - 0.001)
        }
    }

    // MARK: Wrong credentials

    @Test func wrongPasswordIsTriedOnceThenNeverAgain() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "wrong", accessGuard: g, transport: nvr)

        await burst(c)                                        // 10 features want the recorder at once
        #expect(nvr.loginAttempts == 1)
        guard case .rejected = g.state else { Issue.record("state \(g.state)"); return }

        for _ in 0..<60 {                                     // one hour of polling every minute
            await clock.advance(by: 60)
            await burst(c)
        }
        #expect(nvr.loginAttempts == 1 && nvr.failedLogins == 1)
        #expect(!nvr.isLocked && nvr.buzzerAlarms == 1)

        // Only an explicit user action tries again (once).
        g.retryNow()
        await burst(c)
        #expect(nvr.loginAttempts == 2)
    }

    @Test func parallelLoginsWouldBreakTheSingleNonceButAreSerialized() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        // Two clients on the same recorder (shared session + the "Edit" form) logging in together.
        let a = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        let b = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        async let x: Void = a.login()
        async let y: Void = b.login()
        _ = try await (x, y)
        #expect(nvr.failedLogins == 0 && nvr.loginAttempts == 2)
    }

    // MARK: Locked account

    @Test func lockedAccountStopsUntilTheUnlockTimeThenOneAttempt() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        nvr.lockUser(seconds: 600, reportSeconds: true)
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)

        await burst(c)
        #expect(nvr.loginAttempts == 1)
        guard case .locked(let until?) = g.state else { Issue.record("state \(g.state)"); return }
        #expect(abs(until.timeIntervalSince(clock.now()) - 600) < 2)

        for _ in 0..<9 {                                      // 9 minutes: nothing is sent
            await clock.advance(by: 60)
            await burst(c)
        }
        #expect(nvr.loginAttempts == 1)

        await clock.advance(by: 80)                           // unlock time (+ margin) reached
        #expect(g.state == .unverified)
        await burst(c)
        #expect(nvr.loginAttempts == 2 && g.state == .online)
    }

    @Test func lockWithoutUnlockTimeWaitsForTheUser() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        nvr.lockUser(seconds: nil, reportSeconds: false)
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        await burst(c)
        #expect(g.state == .locked(until: nil))
        for _ in 0..<24 { await clock.advance(by: 300); await burst(c) }   // two hours
        #expect(nvr.loginAttempts == 1)
    }

    @Test func wrongPasswordAloneNeverReachesTheLockThreshold() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "old-password", accessGuard: g, transport: nvr)
        for _ in 0..<30 { await burst(c); await clock.advance(by: 60) }
        #expect(nvr.failedLogins == 1 && !nvr.isLocked)
        guard case .rejected = g.state else { Issue.record("state \(g.state)"); return }
    }

    // MARK: Sign out with the recorder offline

    @MainActor
    @Test func signOutWithRecorderOfflineOnlyClearsLocalState() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        VigiTesting.transport = nvr
        DeviceClients.shared.probeOverride = { _ in { nvr.reachable } }
        DeviceClients.shared.clockOverride = clock
        defer { VigiTesting.transport = nil; DeviceClients.shared.probeOverride = nil; DeviceClients.shared.clockOverride = nil }

        let d = Device(id: UUID(), kind: .vigiNVR, name: "NVR", host: "nvr-offline.test", httpPort: 443, rtspPort: 554, username: "viewer")
        CredentialCache.shared.set("right", for: d.id)
        let g = DeviceClients.shared.accessGuard(for: d)
        let c = DeviceClients.shared.vigi(for: d)
        try await c.ensureSession()
        nvr.goOffline(for: 3600)
        _ = try? await c.channels()
        await clock.settle()
        #expect(g.state.isOffline)
        let sent = nvr.requestsWhileOffline, probes = g.probes

        let t0 = Date()
        await DeviceClients.shared.signOut(d, pool: StreamPool())
        #expect(Date().timeIntervalSince(t0) < 1)            // nothing waited for the network
        #expect(g.state == .signedOut)
        #expect(nvr.requestsWhileOffline == sent)             // no logout request, no login
        #expect(nvr.loginAttempts == 1)
        #expect(CredentialCache.shared.password(for: d.id) == nil)
        await clock.advance(by: 3600)
        #expect(g.probes == probes)                           // retries stopped
        DeviceClients.shared.forget(d.id)
    }

    @MainActor
    @Test func signOutWhileLockedSendsNothing() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        nvr.lockUser(seconds: 900, reportSeconds: true)
        VigiTesting.transport = nvr
        DeviceClients.shared.probeOverride = { _ in { nvr.reachable } }
        DeviceClients.shared.clockOverride = clock
        defer { VigiTesting.transport = nil; DeviceClients.shared.probeOverride = nil; DeviceClients.shared.clockOverride = nil }

        let d = Device(id: UUID(), kind: .vigiNVR, name: "NVR", host: "nvr-locked.test", httpPort: 443, rtspPort: 554, username: "viewer")
        CredentialCache.shared.set("right", for: d.id)
        let g = DeviceClients.shared.accessGuard(for: d)
        _ = try? await DeviceClients.shared.vigi(for: d).ensureSession()
        guard case .locked = g.state else { Issue.record("state \(g.state)"); return }
        await DeviceClients.shared.signOut(d, pool: StreamPool())
        await clock.advance(by: 1000)                         // the unlock timer must not fire a login
        #expect(nvr.loginAttempts == 1 && nvr.logouts == 0 && g.state == .signedOut)
        DeviceClients.shared.forget(d.id)
    }

    // MARK: Switch user with streams running

    @MainActor
    @Test func switchUserWithActiveStreamsLeavesNoOrphanSessions() async throws {
        let nvr = FakeNVR(clock: SystemAccessClock(), users: ["alice": "a-pass", "bob": "b-pass"])
        let rtsp = FakeRTSPServer(users: ["alice": "a-pass", "bob": "b-pass"])
        try await rtsp.start()
        defer { rtsp.stop() }
        VigiTesting.transport = nvr
        DeviceClients.shared.probeOverride = { _ in { true } }
        defer { VigiTesting.transport = nil; DeviceClients.shared.probeOverride = nil }

        let id = UUID()
        var d = Device(id: id, kind: .vigiNVR, name: "NVR", host: "127.0.0.1", httpPort: 443, rtspPort: Int(rtsp.port), username: "alice")
        d.channels = (1...4).map { Channel(deviceID: id, number: $0, name: "Cam \($0)") }
        CredentialCache.shared.set("a-pass", for: id)
        let pool = StreamPool()
        let g = DeviceClients.shared.accessGuard(for: d)
        try await DeviceClients.shared.vigi(for: d).ensureSession()

        func startStreams(_ dev: Device) -> [LiveStream] {
            dev.channels.compactMap { ch in
                guard let url = StreamURLs.live(device: dev, channel: ch, kind: .sub) else { return nil }
                return pool.acquire(key: "\(id.uuidString)|\(ch.id)|sub", url: url, credentials: dev.credentials,
                                    title: ch.name, accessGuard: DeviceClients.shared.accessGuard(for: dev))
            }
        }
        func waitFor(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<100 { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }

        _ = startStreams(d)
        #expect(await waitFor { rtsp.activeUsers == ["alice", "alice", "alice", "alice"] })
        #expect(nvr.activeUsers() == ["alice"])

        // 1. Complete sign out first.
        await DeviceClients.shared.signOut(d, pool: pool)
        #expect(nvr.logouts == 1 && nvr.activeUsers().isEmpty)          // session ended on the recorder
        #expect(await waitFor { rtsp.activeUsers.isEmpty })               // streams closed
        #expect(rtsp.stats.teardowns >= 4)
        #expect(CredentialCache.shared.password(for: id) == nil)
        #expect(g.state == .signedOut)
        let connectionsAfterSignOut = rtsp.stats.connections
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(rtsp.stats.connections == connectionsAfterSignOut)       // nothing reconnects

        // 2. Then the new user signs in (same path as the sign-in screen).
        let r = try await DeviceConnector.connectNVR(address: "127.0.0.1", httpPort: 443, rtspPort: Int(rtsp.port),
                                                     username: "bob", password: "b-pass", id: id, accessGuard: g)
        #expect(r.device.channels.count == 4)                            // read from the recorder with the new session
        #expect(g.state == .signedOut)                                    // nothing else may use the recorder yet
        CredentialCache.shared.set("b-pass", for: id)
        DeviceClients.shared.adopt(r)
        d = r.device
        #expect(g.state == .online)
        let bobStreams = startStreams(d)
        let bobUp = await waitFor { rtsp.activeUsers == ["bob", "bob", "bob", "bob"] }
        #expect(bobUp, "phases \(bobStreams.map { "\($0.status.phase)" }), rtsp \(rtsp.activeUsers), guard \(g.state)")
        #expect(nvr.activeUsers() == ["bob"])                              // exactly one session: no orphans
        #expect(nvr.loginAttempts == 2 && nvr.failedLogins == 0)
        #expect(rtsp.stats.refused == 0)

        pool.stopAll()
        await DeviceClients.shared.signOut(d, pool: pool)
        DeviceClients.shared.forget(id)
    }

    /// A device added with the wizard: the session it opened must come under the guard once adopted.
    @MainActor
    @Test func sessionFromTheWizardIsProtectedAfterAdoption() async throws {
        let nvr = FakeNVR(clock: SystemAccessClock(), users: ["viewer": "right"])
        let rtsp = FakeRTSPServer(users: ["viewer": "right"])
        try await rtsp.start()
        defer { rtsp.stop() }
        VigiTesting.transport = nvr
        DeviceClients.shared.probeOverride = { _ in { true } }
        defer { VigiTesting.transport = nil; DeviceClients.shared.probeOverride = nil }

        let r = try await DeviceConnector.connectNVR(address: "127.0.0.1", rtspPort: Int(rtsp.port), username: "viewer", password: "right")
        CredentialCache.shared.set("right", for: r.device.id)
        DeviceClients.shared.adopt(r)
        let c = DeviceClients.shared.vigi(for: r.device)
        #expect(c === r.session)

        // The password is changed on the recorder and the session ends: one refused login, then nothing.
        nvr.users["viewer"] = "changed"
        await c.logout()
        await burst(c)
        await burst(c)
        #expect(nvr.failedLogins == 1 && nvr.loginAttempts == 2)
        guard case .rejected = DeviceClients.shared.state(of: r.device) else { Issue.record("\(DeviceClients.shared.state(of: r.device))"); return }
        DeviceClients.shared.forget(r.device.id)
    }

    @Test func sessionClosedRightAfterLoginIsNotReopenedAtOnce() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        try await c.ensureSession()
        nvr.expireSessions()                                  // e.g. the same user signed in from another app
        await burst(c)
        #expect(nvr.loginAttempts == 1)                        // no ping-pong of logins
        await clock.advance(by: 10)
        await burst(c)
        #expect(nvr.loginAttempts == 2 && nvr.failedLogins == 0)
    }

    /// A dedicated user allowed to see only some cameras: the others stop, the device keeps working.
    @MainActor
    @Test func dedicatedUserWithoutPermissionForSomeCamerasKeepsTheOthers() async throws {
        let nvr = FakeNVR(clock: SystemAccessClock(), users: ["viewer": "pw"])
        let rtsp = FakeRTSPServer(users: ["viewer": "pw"])
        rtsp.permissions = ["viewer": ["/live/1/", "/live/2/"]]
        try await rtsp.start()
        defer { rtsp.stop() }
        VigiTesting.transport = nvr
        DeviceClients.shared.probeOverride = { _ in { true } }
        defer { VigiTesting.transport = nil; DeviceClients.shared.probeOverride = nil }

        let id = UUID()
        var d = Device(id: id, kind: .vigiNVR, name: "NVR", host: "127.0.0.1", httpPort: 443, rtspPort: Int(rtsp.port), username: "viewer")
        d.channels = (1...4).map { Channel(deviceID: id, number: $0, name: "Cam \($0)") }
        CredentialCache.shared.set("pw", for: id)
        let g = DeviceClients.shared.accessGuard(for: d)     // launch: the API login goes first
        let pool = StreamPool()
        let streams = d.channels.map { ch in
            pool.acquire(key: "\(id.uuidString)|\(ch.id)", url: StreamURLs.live(device: d, channel: ch, kind: .sub)!,
                         credentials: d.credentials, title: ch.name, accessGuard: g)
        }
        func failed(_ s: LiveStream) -> Bool { if case .failed = s.status.phase { return true } else { return false } }
        for _ in 0..<100 {
            if rtsp.activeUsers.count == 2, streams.filter(failed).count == 2 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(rtsp.activeUsers == ["viewer", "viewer"])
        #expect(streams.filter(failed).count == 2)
        #expect(g.state == .online)                              // not "password refused" for the whole recorder
        #expect(nvr.loginAttempts == 1 && nvr.failedLogins == 0)
        #expect(rtsp.stats.refused == 2)                         // one refusal per forbidden camera, no retries
        pool.stopAll()
        await DeviceClients.shared.signOut(d, pool: pool)
        DeviceClients.shared.forget(id)
    }

    /// Another app with the same user takes the session over every minute: Vedetta must not log in every minute.
    @Test func sessionsTakenOverRepeatedlySlowDownTheLogins() async throws {
        let clock = ManualClock()
        let nvr = FakeNVR(clock: clock, users: ["viewer": "right"])
        let g = makeGuard(clock, nvr)
        let c = VigiClient(host: "nvr.test", username: "viewer", password: "right", accessGuard: g, transport: nvr)
        try await c.ensureSession()
        for _ in 0..<30 {                                    // 30 minutes, event polling every minute
            await clock.advance(by: 50)
            nvr.expireSessions()                             // the other app logs in and closes ours
            await clock.advance(by: 10)
            await burst(c, 3)
        }
        #expect(nvr.failedLogins == 0 && g.state == .online)
        #expect(nvr.loginAttempts <= 15, "logins \(nvr.loginAttempts)")   // not 31
    }

    // MARK: Streams

    /// Window closed (suspend) and reopened before the stream was dropped: the stream must start again.
    @MainActor
    @Test func streamReacquiredAfterSuspendStartsAgain() async throws {
        let rtsp = FakeRTSPServer(users: ["viewer": "right"])
        try await rtsp.start()
        defer { rtsp.stop() }
        let pool = StreamPool()
        let url = URL(string: "rtsp://127.0.0.1:\(rtsp.port)/live/1/2/avm")!
        let creds = Credentials(username: "viewer", password: "right")
        func waitFor(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<80 { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }
        var s = pool.acquire(key: "k", url: url, credentials: creds, title: "Cam")
        #expect(await waitFor { rtsp.activeUsers.count == 1 })
        pool.suspend()                                         // window closed
        pool.release(s)                                        // its tiles go away (stream lingers a few seconds)
        #expect(await waitFor { rtsp.activeUsers.isEmpty })
        pool.resume()                                          // window reopened…
        s = pool.acquire(key: "k", url: url, credentials: creds, title: "Cam")   // …and its tile comes back
        #expect(await waitFor { rtsp.activeUsers.count == 1 }, "phase \(s.status.phase)")
        // Reverse order: the tile comes back while still suspended, then the window becomes visible.
        pool.suspend(); pool.release(s)
        #expect(await waitFor { rtsp.activeUsers.isEmpty })
        s = pool.acquire(key: "k", url: url, credentials: creds, title: "Cam")
        pool.resume()
        #expect(await waitFor { rtsp.activeUsers.count == 1 }, "phase \(s.status.phase)")
        pool.stopAll()
    }

    /// The recorder refuses the HD stream for bandwidth (RTSP 509): the stream says so at once,
    /// a pending recording fails immediately (to fall back to the light stream) and snapshots give up.
    @MainActor
    @Test func bandwidthLimitIsReportedAndCapturesGiveUpQuickly() async throws {
        let rtsp = FakeRTSPServer(users: ["viewer": "right"])
        rtsp.refusePlay = ["/live/1/1/": "509 Bandwidth Limit Exceeded"]
        try await rtsp.start()
        defer { rtsp.stop() }
        let pool = StreamPool()
        let creds = Credentials(username: "viewer", password: "right")
        let hd = pool.acquire(key: "hd", url: URL(string: "rtsp://127.0.0.1:\(rtsp.port)/live/1/1/avm")!, credentials: creds, title: "Street")
        let t0 = Date()
        let recErr: Error? = await withCheckedContinuation { c in
            hd.startRecording(to: FileManager.default.temporaryDirectory.appendingPathComponent("hd-\(UUID()).mp4"), wait: 15) { c.resume(returning: $0) }
        }
        #expect(Date().timeIntervalSince(t0) < 5, "recording waited \(Date().timeIntervalSince(t0)) s")
        guard case LiveStreamError.bandwidthLimited(509)? = recErr else { Issue.record("error \(String(describing: recErr))"); return }
        #expect(hd.isBandwidthLimited)
        for _ in 0..<40 where !hd.status.bandwidthLimited { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(hd.status.bandwidthLimited)
        let t1 = Date()
        let img: CGImage? = await withCheckedContinuation { c in hd.snapshotWhenReady(wait: 8) { c.resume(returning: $0) } }
        #expect(img == nil && Date().timeIntervalSince(t1) < 2)
        // The light stream of the same camera still plays.
        _ = pool.acquire(key: "sd", url: URL(string: "rtsp://127.0.0.1:\(rtsp.port)/live/1/2/avm")!, credentials: creds, title: "Street")
        var playing = false
        for _ in 0..<60 { if rtsp.activeUsers.count == 1 { playing = true; break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(playing)
        pool.stopAll()
    }

    @MainActor
    @Test func camerasStartingTogetherWithAWrongPasswordFailOnlyOnce() async throws {
        let rtsp = FakeRTSPServer(users: ["viewer": "right"])
        try await rtsp.start()
        defer { rtsp.stop() }
        let g = AccessGuard(label: "cams", log: nil, probe: { true })
        let pool = StreamPool()
        let streams = (1...8).map { n in
            pool.acquire(key: "k\(n)", url: URL(string: "rtsp://127.0.0.1:\(rtsp.port)/live/\(n)/2/avm")!,
                         credentials: Credentials(username: "viewer", password: "wrong"), title: "Cam \(n)", accessGuard: g)
        }
        for _ in 0..<60 {
            if case .rejected = g.state, streams.allSatisfy({ if case .failed = $0.status.phase { return true } else { return false } }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .rejected = g.state else { Issue.record("state \(g.state)"); return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(rtsp.stats.refused == 1)                      // one refused attempt, not 8 (nor 16)
        pool.stopAll()
    }
}
