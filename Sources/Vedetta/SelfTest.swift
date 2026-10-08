import Foundation
import AppKit
import AVFoundation
import ImageIO
import VedettaCore
import NetKit
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
    /// What the test is doing (reported with UI freezes).
    private var phase = "start"
    private var maxLagPhase = ""
    private var keyWindowLost = 0
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
        phase = "after " + name
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
                if lag > self.maxMainLag { self.maxMainLag = lag; self.maxLagPhase = self.phase }
                if lag > 1.5 { self.hangs.append(String(format: "freeze of %.1fs at t=%.0fs (%@)", lag, Date().timeIntervalSince(self.started), self.phase)) }
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
        if env["VEDETTA_SELFTEST_SCENARIO"] == "resilience" {
            await runResilience(dev: dev)
            return finish(rss0: rss0)
        }

        await testLive(dev: dev, online: online)
        await testWindowReopen()
        if env["VEDETTA_SELFTEST_SCENARIO"] == "reopen" { return finish(rss0: rss0) }
        await testLiveUI(dev: dev)
        await testSections()
        if dev.supportsPlayback {
            await testIndex(dev: dev)
            await testPlayback(dev: dev)
            await testPlaybackKeys()
            await testExports(dev: dev)
        }
        await testDeviceOps(dev: dev)
        await testConnectForm(dev: dev)
        await testSettingsPersistence(dev: dev)
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

    // MARK: Live view interaction and full-quality capture

    private func videoViews(in v: NSView) -> [VideoDisplayView] {
        (v as? VideoDisplayView).map { [$0] } ?? v.subviews.flatMap(videoViews)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { w in w.isVisible && w.contentView.map { !videoViews(in: $0).isEmpty } == true }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private func post(_ e: NSEvent?) { if let e { NSApp.postEvent(e, atStart: false) } }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in w: NSWindow) {
        post(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func key(_ chars: String, code: UInt16, shift: Bool = false, in w: NSWindow) {
        if !w.isKeyWindow { keyWindowLost += 1; w.makeKeyAndOrderFront(nil) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            post(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                  characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
    }

    private func newestFile(in dir: URL, ext: String, after date: Date) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == ext }
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d >= date else { return nil }
                return (u, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func testLiveUI(dev: Device) async {
        model.section = .live
        model.setGrid(.four)
        model.layout.page = 0
        await sleep(3)
        guard let w = mainWindow else { return check("live-window", false, "no window") }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 1. The grid stays below the toolbar (the top tiles' names and buttons are visible).
        let area = w.contentLayoutRect
        let frames = videoViews(in: w.contentView!).map { $0.convert($0.bounds, to: nil) }.filter { $0.width > 20 }
        let hidden = frames.filter { $0.maxY > area.maxY + 1 }
        check("live-tiles-below-toolbar", !frames.isEmpty && hidden.isEmpty,
              "\(frames.count) tiles, content top \(Int(area.maxY)), highest tile top \(Int(frames.map(\.maxY).max() ?? 0))")

        // 2. Drag a tile onto another with the mouse (real mouse events): the camera moves there.
        if let t0 = model.channelID(atTile: 0),
           let a = frames.min(by: { ($0.minX - $0.maxY) < ($1.minX - $1.maxY) }),
           let b = frames.max(by: { ($0.minX - $0.maxY) < ($1.minX - $1.maxY) }) {
            let p0 = NSPoint(x: a.midX, y: a.midY), p3 = NSPoint(x: b.midX, y: b.midY)
            var sawDrag = false, moved = false, attempts = 0, userMouse = false
            // Synthetic events: the real mouse, if someone is using the Mac, can interrupt a drag — retry then.
            while attempts < 3, !moved {
                attempts += 1
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                await sleep(0.3)
                mouse(.leftMouseDown, p0, in: w)
                await sleep(0.1)
                for i in 1...15 {
                    let f = CGFloat(i) / 15
                    mouse(.leftMouseDragged, NSPoint(x: p0.x + (p3.x - p0.x) * f, y: p0.y + (p3.y - p0.y) * f), in: w)
                    await sleep(0.05)
                    if model.tileDrag != nil { sawDrag = true }
                }
                mouse(.leftMouseUp, p3, in: w)
                moved = await waitUntil(3) { self.model.channelID(atTile: 0) != t0 && self.model.layout.slots.contains(t0) }
                if CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 3 { userMouse = true }
            }
            let target = model.layout.slots.firstIndex(of: t0).map(String.init) ?? "-"
            check("live-tile-drag", moved, "gesture \(sawDrag ? "seen" : "not seen"), camera now in tile \(target), attempts \(attempts)\(userMouse ? ", real mouse in use" : "")")
            if moved { model.assign(channelID: t0, toTile: 0) }
        }

        // 3. Labels: always / pointer / never are stored.
        let savedLabels = model.settings.tileLabels
        model.settings.tileLabels = .never
        model.settings.tileLabels = savedLabels
        check("live-label-modes", model.settings.tileLabels == savedLabels)

        // 4. Snapshot and recording at full quality while the tiles show the light stream.
        let quality = model.settings.liveQuality
        model.settings.liveQuality = .low
        defer { model.settings.liveQuality = quality }
        await sleep(4)
        guard let ch = dev.visibleChannels.first(where: { $0.isOnline }) else { return }
        let sub = model.pool.existing(key: AppModel.streamKey(dev, ch, .sub))?.status.resolution ?? .zero
        let t = Date().addingTimeInterval(-1)
        model.saveFullQualitySnapshot(channel: ch, device: dev, current: nil, currentIsMain: false)
        let shot = await waitUntilValue(15) { self.newestFile(in: self.model.settings.snapshotsURL, ext: "jpg", after: t) }
        var shotSize = CGSize.zero
        if let shot, let src = CGImageSourceCreateWithURL(shot as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            shotSize = CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        check("live-snapshot-full-quality", shotSize.width > max(sub.width, 700),
              "snapshot \(Int(shotSize.width))×\(Int(shotSize.height)), tile stream \(Int(sub.width))×\(Int(sub.height))")

        let t2 = Date().addingTimeInterval(-1)
        model.toggleLiveRecording(channel: ch, device: dev)
        let started = await waitUntil(20) { self.model.liveRecordings[ch.id]?.started != nil }
        await sleep(5)
        model.toggleLiveRecording(channel: ch, device: dev)
        let file = await waitUntilValue(15) { self.newestFile(in: self.model.settings.recordingsURL, ext: "mp4", after: t2) }
        await sleep(1)
        var recSize = CGSize.zero
        var recDur = 0.0
        if let file {
            let asset = AVURLAsset(url: file)
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize) { recSize = size }
            recDur = await duration(of: file)
        }
        check("live-recording-full-quality", started && recSize.width > max(sub.width, 700) && recDur >= 3,
              String(format: "recording %d×%d, %.1f s, tile stream %d×%d", Int(recSize.width), Int(recSize.height), recDur, Int(sub.width), Int(sub.height)))
        await sleep(6)
        let released = model.pool.existing(key: AppModel.streamKey(dev, ch, .main)) == nil || model.layout.grid == .one
        check("live-hd-stream-released", released, "main stream closed after the capture")
    }

    // MARK: Close the window with the red button, reopen it from the Dock

    /// The Dock sends this Apple event when its icon is clicked; sent to this process only.
    private func reopenFromDock() {
        let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                        targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                        transactionID: AETransactionID(kAnyTransactionID))
        _ = try? ev.sendEvent(options: [.noReply], timeout: 5)
    }

    private func playingCount() -> Int { model.pool.activeStreams.filter { $0.status.isPlaying }.count }

    private func testWindowReopen() async {
        model.section = .live
        guard await waitUntil(20, { self.playingCount() > 0 }) else { return check("window-reopen", false, "no stream playing before the test") }
        let before = playingCount()
        model.autoSuspendEnabled = true          // as for the user: closing the window pauses the video
        defer { model.autoSuspendEnabled = false }
        for (name, pause) in [("window-reopen", 8.0), ("window-reopen-quick", 1.5)] {
            guard let w = mainWindow else { check(name, false, "no window"); continue }
            w.performClose(nil)
            let closed = await waitUntil(5) { !w.isVisible }
            let paused = await waitUntil(5) { self.model.pool.isSuspended }
            await sleep(pause)
            reopenFromDock()
            let reopened = await waitUntil(10) { self.mainWindow?.isVisible == true }
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let back = await waitUntil(40) { self.playingCount() >= before }
            let phases = model.pool.activeStreams.map { "\($0.title): \($0.status.phase)" }.joined(separator: "; ")
            check(name, closed && paused && reopened && back,
                  "closed \(closed), paused \(paused), reopened \(reopened), playing \(playingCount())/\(before), suspended \(model.pool.isSuspended) — \(phases)")
        }
    }

    private func waitUntilValue<T>(_ timeout: Double, _ get: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = get() { return v }
            await sleep(0.25)
        }
        return get()
    }

    /// Recordings keyboard shortcuts, sent as real key presses.
    private func testPlaybackKeys() async {
        model.section = .playback
        let ready = await waitUntil(25) { (self.model.activePlayback?.isPlaying ?? false) && !(self.model.activePlayback?.isBuffering ?? true) }
        guard ready, let s = model.activePlayback, let w = mainWindow else { return check("playback-keys", false, "playback not ready") }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await sleep(1)
        key(" ", code: 49, in: w)
        let paused = await waitUntil(3) { !s.isPlaying }
        key(" ", code: 49, in: w)
        let playing = await waitUntil(3) { s.isPlaying }
        await waitUntil(5) { !s.isBuffering }
        let before = s.currentTime
        let arrow = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        key(arrow, code: 124, in: w)                  // →: +10 s
        let jumped = await waitUntil(10) { s.currentTime.timeIntervalSince(before) >= 8 }
        let delta = s.currentTime.timeIntervalSince(before)
        await waitUntil(10) { !s.isBuffering }
        await sleep(1)
        let t = Date().addingTimeInterval(-1)
        key("s", code: 1, in: w)
        let shot = await waitUntilValue(8) { self.newestFile(in: self.model.settings.snapshotsURL, ext: "jpg", after: t) }
        check("playback-keys", paused && playing && jumped && shot != nil,
              String(format: "space pause %@, space play %@, → %+.1f s, S snapshot %@, buffering %@, notice %@, window not key %d×, app active %@",
                     "\(paused)", "\(playing)", delta, "\(shot != nil)", "\(s.isBuffering)", s.notice ?? "-", keyWindowLost, "\(NSApp.isActive)"))
        model.section = .live
        await sleep(2)
    }

    /// Settings survive: saved to disk as they change, readable by older/newer versions, exported without passwords.
    private func testSettingsPersistence(dev: Device) async {
        let saved = model.settings
        model.settings.tileLabels = .never
        model.settings.tileFit = .stretch
        model.settings.exportAudio = false
        JSONStore<AppSettings>.flushAll()
        let onDisk = JSONStore<AppSettings>(filename: "settings.json").load()
        check("settings-saved-to-disk", onDisk?.tileLabels == .never && onDisk?.tileFit == .stretch && onDisk?.exportAudio == false)
        model.settings = saved

        let url = work.appendingPathComponent("vedetta-settings.json")
        do {
            try model.exportSettings(to: url)
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let pass = CredentialCache.shared.password(for: dev.id) ?? "-"
            let b = try SettingsBackup.decode(data)
            check("settings-export", b.devices.count == model.devices.count && b.devices.first?.channels.count == dev.channels.count
                  && !text.contains(pass), "\(b.devices.count) devices, \(data.count) bytes, no password")
            model.importSettings(b)
            let back = await waitUntil(40) { self.model.pool.activeStreams.contains { $0.status.isPlaying } && self.model.devices.count == b.devices.count }
            check("settings-import", back, "devices \(model.devices.count), streams playing \(back)")
        } catch {
            check("settings-export", false, error.localizedDescription)
        }
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

        // Without audio: the MP4 must have no sound track (the first export, with audio, has one if the stream does).
        let silent = model.exports.enqueue(device: dev, channel: ch, start: end.addingTimeInterval(-40), end: end.addingTimeInterval(-25),
                                           folder: work, includeAudio: false)
        let silentDone = await waitUntil(90) { self.model.exports.jobs.first { $0.id == silent.id }?.state == .completed }
        var silentAudio = -1, withAudio = -1
        if silentDone {
            silentAudio = (try? await AVURLAsset(url: silent.fileURL).loadTracks(withMediaType: .audio).count) ?? -1
            if let first = model.exports.jobs.first(where: { $0.id == rec.id }), first.state == .completed {
                withAudio = (try? await AVURLAsset(url: first.fileURL).loadTracks(withMediaType: .audio).count) ?? -1
            }
        }
        check("export-audio-choice", silentDone && silentAudio == 0 && withAudio != 0,
              "without audio: \(silentAudio) sound tracks; with audio: \(withAudio)")
        model.exports.remove(silent.id)

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
                _ = try await DeviceConnector.connectNVR(address: dev.host, httpPort: dev.httpPort, rtspPort: dev.rtspPort, username: dev.username, password: "wrong-password")
            default:
                _ = try await DeviceConnector.connectRecorder(address: dev.onvifURL.flatMap { URL(string: $0) }.map { "\($0.host!):\($0.port ?? 80)" } ?? dev.host,
                                                              onvifURL: dev.onvifURL, brand: nil, rtspPort: dev.rtspPort, username: dev.username, password: "wrong-password")
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
        await r?.discardSession()
        let bad = form(password: "wrong-password")
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
        await re?.discardSession()
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

    // MARK: Account protection (recorder offline, refused password, locked user, sign out, switch user)

    private func mock(_ command: [String: Any]? = nil) async -> [String: Any] {
        guard let base = env["VEDETTA_MOCK_CONTROL"], let url = URL(string: base + (command == nil ? "/stats" : "/control")) else { return [:] }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if let command { req.httpMethod = "POST"; req.httpBody = try? JSONSerialization.data(withJSONObject: command) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func n(_ d: [String: Any], _ k: String) -> Int { d[k] as? Int ?? -1 }
    private func list(_ d: [String: Any], _ k: String) -> String { (d[k] as? [String])?.joined(separator: ",") ?? "-" }

    /// Asks the regression script to stop/start the video server (the recorder's RTSP side).
    private func video(_ command: String) {
        guard let marker = env["VEDETTA_SELFTEST_RESTART_MARKER"] else { return }
        FileManager.default.createFile(atPath: marker, contents: Data(command.utf8))
    }

    private func playing() -> Int { model.pool.activeStreams.filter { $0.status.isPlaying }.count }
    private func current(_ dev: Device) -> Device { model.devices.first { $0.id == dev.id } ?? dev }
    private func state(_ dev: Device) -> AccessState { model.accessState(dev) }
    private func isRejected(_ s: AccessState) -> Bool { if case .rejected = s { return true } else { return false } }
    private func isLocked(_ s: AccessState) -> Bool { if case .locked = s { return true } else { return false } }

    private func runResilience(dev: Device) async {
        model.section = .live
        let ready = await waitUntil(45) { self.playing() > 0 && self.state(dev) == .online }
        let s0 = await mock()
        check("res-baseline", ready && !s0.isEmpty, "playing \(playing()), \(state(dev)), mock \(s0.isEmpty ? "unreachable" : "ok")")
        guard ready, !s0.isEmpty else { return }
        let logins0 = n(s0, "logins")

        // 1. The recorder stops answering (API and video) for two minutes.
        let t0 = Date()
        _ = await mock(["offline": true])
        video("stop")
        let off = await waitUntil(60) { self.state(dev).isOffline }
        let tDetect = Date().timeIntervalSince(t0)
        let t1 = Date()
        await model.index.loadDay(device: dev, channels: dev.visibleChannels, day: Date(), force: true)
        let fast = Date().timeIntervalSince(t1)
        check("res-offline-detected", off && fast < 3,
              String(format: "offline after %.0f s; timeline request answered in %.1f s: %@", tDetect, fast, model.index.error ?? "-"))
        let left = 120 - Date().timeIntervalSince(t0)
        if left > 0 { await sleep(left) }
        let s1 = await mock()
        check("res-offline-no-logins", n(s1, "logins") == logins0 && n(s1, "logins_while_offline") == 0,
              "logins \(logins0) → \(n(s1, "logins")), logins sent while offline \(n(s1, "logins_while_offline")), unauthenticated checks \(n(s1, "requests_while_offline"))")
        check("res-offline-banner", state(dev).isOffline && !model.everyDeviceNeedsSignIn, state(dev).message)
        _ = await mock(["offline": false])
        video("start")
        let tBack = Date()
        let back = await waitUntil(170) { self.state(dev) == .online && self.playing() > 0 }
        await model.index.loadDay(device: dev, channels: dev.visibleChannels, day: Date(), force: true)
        let s2 = await mock()
        check("res-offline-recovery", back && n(s2, "logins") == logins0 && model.index.error == nil,
              String(format: "video back %.0f s after the recorder; logins %d → %d (session reused)", Date().timeIntervalSince(tBack), logins0, n(s2, "logins")))

        // 2. The password was changed on the recorder: one refused login, then nothing.
        let b2 = await mock(["password": "changed-on-the-recorder", "expire": true])
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<5 {
                g.addTask { @MainActor in await self.model.index.loadDay(device: dev, channels: dev.visibleChannels, day: Date(), force: true) }
            }
        }
        let rejected = await waitUntil(20) { self.isRejected(self.state(dev)) }
        await sleep(30)
        let a2 = await mock()
        check("res-wrong-password-once", rejected && n(a2, "failed") - n(b2, "failed") == 1 && a2["locked"] as? Bool == false,
              "refused logins \(n(a2, "failed") - n(b2, "failed")), locked \(a2["locked"] ?? "-"), buzzer \(n(a2, "buzzer") - n(b2, "buzzer"))")
        check("res-wrong-password-signin-screen", model.everyDeviceNeedsSignIn && playing() == 0, state(dev).message)

        // 3. The user is locked: stop until the unlock time the recorder gave, then one attempt.
        let b3 = await mock(["password": "", "lock": 90])
        model.retryAccess(current(dev))
        let locked = await waitUntil(20) { self.isLocked(self.state(dev)) }
        await sleep(40)
        let m3 = await mock()
        check("res-locked-stops", locked && n(m3, "logins") - n(b3, "logins") == 1,
              "\(state(dev).message) — logins while locked \(n(m3, "logins") - n(b3, "logins"))")
        let unlocked = await waitUntil(120) { self.state(dev) == .online && self.playing() > 0 }
        let a3 = await mock()
        check("res-locked-resumes", unlocked && n(a3, "locked_replies") - n(b3, "locked_replies") == 1 && n(a3, "failed") == n(b3, "failed"),
              "online again: \(unlocked), locked replies \(n(a3, "locked_replies") - n(b3, "locked_replies"))")

        // 4. Sign out while the recorder is unreachable: local only, immediately.
        _ = await mock(["offline": true])
        video("stop")
        let off4 = await waitUntil(60) { self.state(dev).isOffline }
        let t4 = Date()
        await model.signOut(current(dev))
        let dt = Date().timeIntervalSince(t4)
        let b4 = await mock()
        await sleep(12)
        let a4 = await mock()
        check("res-signout-offline", off4 && dt < 3 && n(a4, "logouts_while_offline") == 0 && n(a4, "logins_while_offline") == 0
              && CredentialCache.shared.password(for: dev.id) == nil && state(dev) == .signedOut && model.everyDeviceNeedsSignIn,
              String(format: "done in %.1f s, nothing sent (logout %d, login %d), sign-in screen %@", dt, n(a4, "logouts_while_offline"),
                     n(a4, "logins_while_offline"), model.everyDeviceNeedsSignIn ? "shown" : "missing"))
        check("res-signout-stops-retries", n(a4, "requests_while_offline") == n(b4, "requests_while_offline") && model.pool.activeStreams.isEmpty,
              "requests after sign out: \(n(a4, "requests_while_offline") - n(b4, "requests_while_offline"))")
        _ = await mock(["offline": false])
        video("start")
        await sleep(6)

        // 5. Sign in again, then switch user while the video is playing.
        let userA = env["VEDETTA_USER"] ?? "", passA = env["VEDETTA_PASS"] ?? ""
        let userB = env["VEDETTA_VUSER"] ?? "", passB = env["VEDETTA_VPASS"] ?? ""
        let f = ConnectFormModel(editing: current(dev))
        f.username = userA
        f.password = passA
        let r = await f.connect()
        if let r { model.addOrUpdate(r, password: passA) }
        let playingA = await waitUntil(45) { self.playing() > 0 }
        let sA = await mock()
        // A session open when signing out offline cannot be closed (the recorder lets it expire): count from here.
        let base = (b4["sessions"] as? [String]) ?? []
        func sessions(_ d: [String: Any]) -> [String] { (d["sessions"] as? [String]) ?? ["?"] }
        check("res-signin", r != nil && playingA && sessions(sA) == (base + [userA]).sorted(),
              f.error ?? "sessions [\(list(sA, "sessions"))], left by the offline sign out [\(base.joined(separator: ","))]")

        await model.signOut(current(dev), switchUser: true)
        let stopped = await waitUntil(5) { self.playing() == 0 && self.model.pool.activeStreams.isEmpty }
        let sMid = await mock()
        check("res-switch-signs-out-first", stopped && n(sMid, "logouts") == n(sA, "logouts") + 1 && sessions(sMid) == base.sorted()
              && model.signIn?.clearUser == true && CredentialCache.shared.password(for: dev.id) == nil,
              "logouts +\(n(sMid, "logouts") - n(sA, "logouts")), sessions [\(list(sMid, "sessions"))], user field cleared \(model.signIn?.clearUser == true)")
        let g = ConnectFormModel(editing: current(dev))
        g.username = userB
        g.password = passB
        let r2 = await g.connect()
        if let r2 { model.addOrUpdate(r2, password: passB) }
        let playingB = await waitUntil(45) { self.playing() > 0 }
        let sB = await mock()
        check("res-switch-new-user", r2 != nil && playingB && sessions(sB) == (base + [userB]).sorted() && n(sB, "failed") == n(sA, "failed")
              && current(dev).username == userB,
              g.error ?? "sessions [\(list(sB, "sessions"))], user \(current(dev).username), logins [\(list(sB, "login_log"))]")
        let log = AccessLog.shared.lines()
        check("res-connection-log", log.contains { $0.contains("\trejected\t") } && log.contains { $0.contains("probe (no password)") } && !log.contains { $0.contains(passA) || $0.contains(passB) },
              "\(log.count) lines, no passwords")
    }

    private func finish(rss0: Double) {
        let rss1 = residentMB()
        check("no-ui-hangs", hangs.isEmpty, hangs.isEmpty ? String(format: "max main-thread lag %.2fs (%@)", maxMainLag, maxLagPhase) : hangs.joined(separator: ", "))
        check("memory", rss1 < 600, String(format: "memory %.0f → %.0f MB", rss0, rss1))
        struct Report: Codable { var passed: Int; var failed: Int; var results: [Result] }
        let report = Report(passed: results.filter(\.ok).count, failed: results.filter { !$0.ok }.count, results: results)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(report).write(to: out)
        // Keep the connection log next to the report (the test data folder is deleted afterwards).
        AccessLog.shared.flush()
        try? FileManager.default.removeItem(at: out.deletingPathExtension().appendingPathExtension("connections.log"))
        try? FileManager.default.copyItem(at: AccessLog.shared.fileURL, to: out.deletingPathExtension().appendingPathExtension("connections.log"))
        try? FileManager.default.removeItem(at: work)
        model.pool.stopAll()
        exit(report.failed == 0 ? 0 : 1)
    }
}
