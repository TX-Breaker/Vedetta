import Foundation
import AppKit
import AVFoundation
import VedettaCore
import MediaKit
import VedettaL10n

/// End-to-end self test, enabled only with VEDETTA_DEV=1 VEDETTA_SELFTEST=1 (used by scripts/regression.sh).
/// Drives the real app model and views against the local test bench and writes a JSON report.
@MainActor
final class SelfTest {
    struct Result: Codable { var name: String; var ok: Bool; var detail: String; var seconds: Double }

    private let model: AppModel
    private var results: [Result] = []
    private var hangs: [String] = []
    private var maxMainLag: Double = 0
    private let out: URL
    private let work: URL
    private let started = Date()
    private let env = ProcessInfo.processInfo.environment

    init(model: AppModel) {
        self.model = model
        out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEDETTA_SELFTEST_OUT"] ?? "/tmp/vedetta-selftest.json")
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vedetta-selftest-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    static func startIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["VEDETTA_DEV"] == "1", env["VEDETTA_SELFTEST"] == "1" else { return }
        let t = SelfTest(model: model)
        Task { await t.run() }
    }

    // MARK: Helpers

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append(Result(name: name, ok: ok, detail: detail, seconds: Date().timeIntervalSince(started)))
        NSLog("SELFTEST %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    @discardableResult
    private func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await sleep(0.25)
        }
        return cond()
    }

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// Detects main-thread stalls (UI freezes): a 0.2 s timer that fires late means the main thread was blocked.
    /// (A permanent freeze never ends the test: the regression script's timeout reports it.)
    private func startHangWatchdog() {
        var last = CFAbsoluteTimeGetCurrent()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                let lag = now - last - 0.2
                last = now
                guard let self else { return }
                self.maxMainLag = max(self.maxMainLag, lag)
                if lag > 1.5 { self.hangs.append(String(format: "freeze of %.1fs at t=%.0fs", lag, Date().timeIntervalSince(self.started))) }
            }
        }
    }

    private func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        return d.seconds
    }

    // MARK: Scenario

    func run() async {
        // The test window may be covered by other windows: keep streams running regardless.
        model.autoSuspendEnabled = false
        model.pool.resume()
        startHangWatchdog()
        let rss0 = residentMB()
        testLocalization()
        let ready = await waitUntil(30) { self.model.hasDevices && self.model.credentialsReady }
        check("device-connected", ready, "devices: \(model.devices.map { "\($0.name) [\($0.kind.rawValue)]" })")
        guard ready, let dev = model.devices.first else { return finish(rss0: rss0) }
        let online = dev.visibleChannels.filter(\.isOnline)
        check("channels-found", !online.isEmpty, "\(dev.channels.count) channels, \(online.count) online")

        await testLive(dev: dev, online: online)
        await testSections()
        if dev.supportsPlayback {
            await testIndex(dev: dev)
            await testPlayback(dev: dev)
            await testExports(dev: dev)
        }
        await testDeviceOps(dev: dev)
        await testConnectForm(dev: dev)
        await testSuspend()
        await testReconnect()
        model.section = .live
        await sleep(3)
        finish(rss0: rss0)
    }

    /// The interface language follows macOS / -AppleLanguages and every piece is translated.
    private func testLocalization() {
        let lang = AppLanguage.current
        let expected: [String: (live: String, rec: String, month: String)] = [
            "it": ("Dal vivo", "Registrazioni", "gennaio"), "en": ("Live", "Recordings", "January"), "fr": ("En direct", "Enregistrements", "janvier"),
        ]
        guard let e = expected[lang] else { check("localization", false, "language \(lang)"); return }
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("LLLL")
        let january = f.string(from: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 1, day: 15).date!)
        let info = Bundle.main.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist")
        let infoOK = lang == "en" ? info.hasPrefix("Vedetta connects") : (lang == "it" ? info.hasPrefix("Vedetta si collega") : info.hasPrefix("Vedetta se connecte"))
        check("localization-\(lang)", L("Live") == e.live && AppSection.playback.title == e.rec && january.lowercased() == e.month.lowercased() && infoOK,
              "\(L("Live")) / \(AppSection.playback.title) / \(january) / \(info.prefix(24))")
        check("localization-format", L("%@ of %@ cameras online", "2", "3").contains("2") && L("%@ of %@ cameras online", "2", "3").contains("3"),
              L("%@ of %@ cameras online", "2", "3"))
    }

    private func testLive(dev: Device, online: [Channel]) async {
        model.section = .live
        for g in GridKind.allCases {
            model.setGrid(g)
            await sleep(1.2)
        }
        model.setGrid(GridKind.fitting(dev.visibleChannels.count))
        let playing = await waitUntil(20) {
            self.model.pool.activeStreams.filter { $0.status.isPlaying }.count >= min(online.count, 4)
        }
        let states = model.pool.activeStreams.map { "\($0.title): \($0.status.phase)" }
        check("live-streams-playing", playing, states.joined(separator: "; "))

        // Paging and single-tile mode.
        model.setGrid(.one)
        let pages = model.pageCount
        var seen = Set<Int>()
        for _ in 0..<pages { seen.insert(model.currentPage); model.nextPage(); await sleep(0.5) }
        check("live-paging", seen.count == pages && model.currentPage == 0, "pages \(pages), visited \(seen.sorted())")
        model.setGrid(.four)
        model.toggleSingle(tile: 0)
        let single = model.layout.grid == .one
        model.toggleSingle(tile: 0)
        check("live-single-toggle", single && model.layout.grid == .four)
        model.toggleTour(); await sleep(0.5); let tourOn = model.tourRunning; model.toggleTour()
        check("live-tour-toggle", tourOn && !model.tourRunning)

        // Hide / show a channel keeps the layout consistent.
        if let ch = dev.visibleChannels.last {
            model.setHidden(ch, true)
            let hidden = !model.layout.slots.contains(ch.id) && !model.allChannels.contains { $0.id == ch.id }
            model.setHidden(ch, false)
            model.showChannelLive(ch.id)
            check("channel-hide-show", hidden && model.layout.slots.contains(ch.id))
        }
        // Drag & drop equivalent: move the first channel to tile 3 and back.
        if let first = model.channelID(atTile: 0) {
            model.assign(channelID: first, toTile: 3)
            let moved = model.channelID(atTile: 3) == first
            model.assign(channelID: first, toTile: 0)
            check("tile-assign-swap", moved && model.channelID(atTile: 0) == first)
        }
        await sleep(3)

        guard let stream = model.pool.activeStreams.first(where: { $0.status.isPlaying }) else {
            check("live-recording", false, "no active stream"); return
        }
        // Snapshot.
        let img: CGImage? = await withCheckedContinuation { c in stream.snapshot { c.resume(returning: $0) } }
        check("live-snapshot", (img?.width ?? 0) > 0, "\(img?.width ?? 0)x\(img?.height ?? 0)")
        // Local recording.
        let recURL = work.appendingPathComponent("rec.mp4")
        let startErr: Error? = await withCheckedContinuation { c in stream.startRecording(to: recURL) { c.resume(returning: $0) } }
        await sleep(5)
        let saved: URL? = await withCheckedContinuation { c in stream.stopRecording { u, _ in c.resume(returning: u) } }
        let d = saved != nil ? await duration(of: recURL) : 0
        check("live-recording", startErr == nil && saved != nil && d >= 3, String(format: "duration %.1fs", d))
        // Audio on/off must not disturb the stream.
        stream.setAudio(enabled: true, volume: 0)
        await sleep(1.5)
        stream.setAudio(enabled: false)
        await sleep(1)
        check("live-audio-toggle", stream.status.isPlaying)
    }

    private func testSections() async {
        for s in AppSection.allCases {
            model.section = s
            await sleep(2)
        }
        model.section = .live
        await sleep(1)
        check("sections-render", hangs.isEmpty, hangs.joined(separator: ", "))
    }

    private func testIndex(dev: Device) async {
        let chans = Array(dev.visibleChannels.filter(\.supportsPlayback).prefix(2))
        await model.index.loadMonth(device: dev, channels: chans, month: Date())
        check("index-month", !model.index.recordedDays.isEmpty || model.index.daysUnknown,
              "\(model.index.recordedDays.count) days, unknown=\(model.index.daysUnknown) \(model.index.error ?? "")")
        await model.index.loadDay(device: dev, channels: chans, day: Date(), force: true)
        let segs = chans.map { model.index.segments[$0.id]?.count ?? 0 }
        let evs = chans.map { model.index.events[$0.id]?.count ?? 0 }
        check("index-day", segs.contains { $0 > 0 } || chans.allSatisfy { model.index.unindexed.contains($0.id) },
              "segments \(segs), events \(evs) \(model.index.error ?? "")")
    }

    private func testPlayback(dev: Device) async {
        let chans = Array(dev.visibleChannels.filter { $0.supportsPlayback && $0.isOnline }.prefix(2))
        guard !chans.isEmpty else { return }
        let session = PlaybackSession(device: dev, start: Date())
        session.segmentsProvider = { [index = model.index] ch in index.intervals(for: ch) }
        session.setChannels(chans)
        let views = chans.map { _ in VideoDisplayView() }
        for (v, ch) in zip(views, chans) { session.attach(v, for: ch.id) }
        let t0 = Date().addingTimeInterval(-1800)
        session.play(from: t0)
        let started = await waitUntil(20) { !session.isBuffering && session.currentTime > t0.addingTimeInterval(1) }
        check("playback-starts", started, "time \(session.currentTime) notice=\(session.notice ?? "-")")
        session.pause()
        await sleep(1)
        let tPaused = session.currentTime
        await sleep(2)
        check("playback-pause", abs(session.currentTime.timeIntervalSince(tPaused)) < 0.3, String(format: "drift %.2fs", session.currentTime.timeIntervalSince(tPaused)))
        session.stepForward()
        check("playback-step", session.currentTime > tPaused)
        session.resume()
        let resumed = await waitUntil(10) { session.currentTime > tPaused.addingTimeInterval(1.5) }
        check("playback-resume", resumed)
        let target = t0.addingTimeInterval(600)
        session.seek(to: target)
        let sought = await waitUntil(20) { !session.isBuffering && session.currentTime >= target && session.currentTime < target.addingTimeInterval(30) }
        check("playback-seek", sought, "time \(session.currentTime)")
        session.setSpeed(4)
        await sleep(6)
        check("playback-speed", session.speed == 4 || session.notice != nil, "speed \(session.speed) notice \(session.notice ?? "-")")
        session.setSpeed(1)
        await sleep(2)
        session.stop()
        check("playback-stop", !session.isPlaying)
    }

    private func testExports(dev: Device) async {
        guard let ch = dev.visibleChannels.first(where: { $0.supportsPlayback && $0.isOnline }) else { return }
        let end = Date().addingTimeInterval(-60)
        let rec = model.exports.enqueue(device: dev, channel: ch, start: end.addingTimeInterval(-20), end: end, folder: work)
        let done = await waitUntil(90) {
            let s = self.model.exports.jobs.first { $0.id == rec.id }?.state
            return s == .completed || s == .failed
        }
        let job = model.exports.jobs.first { $0.id == rec.id }
        let d = job?.state == .completed ? await duration(of: rec.fileURL) : 0
        check("export-complete", done && job?.state == .completed && d >= 15,
              "state \(job?.state.rawValue ?? "-") duration \(String(format: "%.1f", d)) \(job?.message ?? "")")

        let rec2 = model.exports.enqueue(device: dev, channel: ch, start: end.addingTimeInterval(-120), end: end, folder: work)
        await sleep(6)
        model.exports.cancel(rec2.id)
        let cancelled = await waitUntil(15) { self.model.exports.jobs.first { $0.id == rec2.id }?.state == .cancelled }
        await sleep(1)
        check("export-cancel", cancelled && !FileManager.default.fileExists(atPath: rec2.fileURL.path))
        model.exports.remove(rec.id)
        model.exports.remove(rec2.id)
    }

    private func testDeviceOps(dev: Device) async {
        do {
            let r = try await DeviceConnector.refresh(dev)
            check("device-refresh", r.device.channels.count == dev.channels.count, "\(r.device.channels.count) channels")
        } catch {
            check("device-refresh", false, error.localizedDescription)
        }
        // Wrong password must fail cleanly with a readable message.
        let wrong: String
        do {
            switch dev.kind {
            case .vigiNVR:
                _ = try await DeviceConnector.connectNVR(address: dev.host, httpPort: dev.httpPort, rtspPort: dev.rtspPort, username: dev.username, password: "sbagliata")
            default:
                _ = try await DeviceConnector.connectRecorder(address: dev.onvifURL.flatMap { URL(string: $0) }.map { "\($0.host!):\($0.port ?? 80)" } ?? dev.host,
                                                              onvifURL: dev.onvifURL, brand: nil, rtspPort: dev.rtspPort, username: dev.username, password: "sbagliata")
            }
            wrong = ""
        } catch {
            wrong = error.localizedDescription
        }
        check("wrong-password-message", wrong.lowercased().contains(L("Password").lowercased()), wrong)
    }

    /// The onboarding / "add device" form, exactly as the user fills it in.
    private func testConnectForm(dev: Device) async {
        let pass = CredentialCache.shared.password(for: dev.id) ?? ""
        func form(password: String) -> ConnectFormModel {
            let f = ConnectFormModel()
            f.username = dev.username
            f.password = password
            switch dev.kind {
            case .vigiNVR:
                f.choice = .vigi
                f.address = dev.host
                f.httpPort = "\(dev.httpPort)"
                f.rtspPort = "\(dev.rtspPort)"
            default:
                f.choice = .otherRecorder
                let u = dev.onvifURL.flatMap(URL.init(string:))
                f.address = u.map { "\($0.host ?? ""):\($0.port ?? 80)" } ?? dev.host
                f.rtspPort = "\(dev.rtspPort)"
            }
            return f
        }
        let good = form(password: pass)
        check("form-can-connect", good.canConnect)
        let r = await good.connect()
        check("form-connect", r != nil && r?.device.channels.count == dev.channels.count, good.error ?? "\(r?.device.channels.count ?? 0) channels")
        let bad = form(password: "sbagliata")
        let rb = await bad.connect()
        check("form-wrong-password", rb == nil && (bad.error ?? "").lowercased().contains(L("Password").lowercased()), bad.error ?? "")
        let empty = form(password: "")
        check("form-requires-password", !empty.canConnect)
        // Editing keeps user-chosen channel names.
        var renamed = dev
        if !renamed.channels.isEmpty { renamed.channels[0].name = "Custom name" }
        let edit = ConnectFormModel(editing: renamed)
        edit.password = pass
        let re = await edit.connect()
        check("form-edit-keeps-names", re?.device.channels.first?.name == "Custom name" && re?.device.id == dev.id,
              edit.error ?? (re?.device.channels.first?.name ?? "-"))
    }

    /// CPU saving: streams stop when nothing is visible and come back afterwards.
    private func testSuspend() async {
        model.section = .live
        await waitUntil(15) { self.model.pool.activeStreams.contains { $0.status.isPlaying } }
        let before = model.pool.activeStreams.filter { $0.status.isPlaying }.count
        model.pool.suspend()
        let stopped = await waitUntil(5) { self.model.pool.activeStreams.allSatisfy { !$0.status.isPlaying } }
        model.pool.resume()
        let back = await waitUntil(20) { self.model.pool.activeStreams.filter { $0.status.isPlaying }.count >= before }
        check("live-suspend-resume", before > 0 && stopped && back, "before \(before), stopped \(stopped), back \(back)")
    }

    private func testReconnect() async {
        guard let marker = env["VEDETTA_SELFTEST_RESTART_MARKER"] else { return }
        model.section = .live
        await sleep(2)
        let before = model.pool.activeStreams.filter { $0.status.isPlaying }.count
        FileManager.default.createFile(atPath: marker, contents: Data("restart".utf8))
        let dropped = await waitUntil(40) { self.model.pool.activeStreams.allSatisfy { !$0.status.isPlaying } }
        let back = await waitUntil(60) { self.model.pool.activeStreams.filter { $0.status.isPlaying }.count >= before }
        check("live-reconnect", before > 0 && dropped && back, "before \(before), dropped \(dropped), back \(back)")
    }

    private func finish(rss0: Double) {
        let rss1 = residentMB()
        check("no-ui-hangs", hangs.isEmpty, hangs.isEmpty ? String(format: "max main-thread lag %.2fs", maxMainLag) : hangs.joined(separator: ", "))
        check("memory", rss1 < 600, String(format: "memory %.0f → %.0f MB", rss0, rss1))
        struct Report: Codable { var passed: Int; var failed: Int; var results: [Result] }
        let report = Report(passed: results.filter(\.ok).count, failed: results.filter { !$0.ok }.count, results: results)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(report).write(to: out)
        try? FileManager.default.removeItem(at: work)
        model.pool.stopAll()
        exit(report.failed == 0 ? 0 : 1)
    }
}
