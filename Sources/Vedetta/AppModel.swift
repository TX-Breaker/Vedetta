import SwiftUI
import AppKit
import Observation
import UserNotifications
import ServiceManagement
import VedettaCore
import ONVIFKit
import NetKit
import VedettaL10n

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case live, playback, events, exports, album, devices
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return L("Live")
        case .playback: return L("Recordings")
        case .events: return L("Events")
        case .exports: return L("Exports")
        case .album: return L("Album")
        case .devices: return L("Devices")
        }
    }
    var symbol: String {
        switch self {
        case .live: return "play.rectangle.on.rectangle.fill"
        case .playback: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .events: return "bell.badge.fill"
        case .exports: return "square.and.arrow.down.on.square.fill"
        case .album: return "photo.stack.fill"
        case .devices: return "externaldrive.connected.to.line.below.fill"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, warning, error }
    let id = UUID()
    var style: Style
    var title: String
    var detail: String?
    var fileURL: URL?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class AppModel {
    // Persistent state
    var devices: [Device] = [] { didSet { devicesStore.save(devices) } }
    var settings: AppSettings = .defaults { didSet { if settings != oldValue { settingsStore.save(settings); applySettings(old: oldValue) } } }
    var layout = LiveLayout() { didSet { layoutStore.save(layout) } }

    // UI state
    /// The last section is remembered — not by test/dev runs, which share the app's preferences domain.
    var section: AppSection = .live {
        didSet { if !AppPaths.isIsolated { UserDefaults.standard.set(section.rawValue, forKey: "LastSection") } }
    }
    var selectedTile: Int? = nil
    var singleTileRestore: GridKind? = nil
    var tourRunning = false
    var toasts: [Toast] = []
    var showAddDevice = false
    var isLocked = false
    var playbackRequest: PlaybackRequest?
    var discovered: [DiscoveredDevice] = []
    var isDiscovering = false
    var reloadToken = UUID()
    var newEventCount = 0
    /// false until device passwords have been read from the Keychain.
    var credentialsReady = false
    /// Account protection state of each device (see AccessGuard).
    var access: [UUID: AccessState] = [:]
    /// Sign-in requested for a device (sheet), e.g. after "Switch user".
    var signIn: SignInRequest?

    struct SignInRequest: Identifiable, Equatable {
        let id = UUID()
        var deviceID: UUID
        var clearUser = false
    }

    struct PlaybackRequest: Equatable {
        var channelIDs: [String]
        var time: Date
    }

    // Services
    @ObservationIgnored let pool = StreamPool()
    let exports = ExportManager()
    let index = RecordingIndex()
    @ObservationIgnored private let devicesStore = JSONStore<[Device]>(filename: "devices.json")
    @ObservationIgnored private let settingsStore = JSONStore<AppSettings>(filename: "settings.json")
    @ObservationIgnored private let layoutStore = JSONStore<LiveLayout>(filename: "layout.json")
    @ObservationIgnored private var tourTimer: Timer?
    @ObservationIgnored private var eventMonitor: EventMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var visibleWindows = Set<ObjectIdentifier>()

    init() {
        devices = devicesStore.load() ?? []
        settings = settingsStore.load() ?? .defaults
        layout = layoutStore.load() ?? LiveLayout()
        if !AppPaths.isIsolated, let last = UserDefaults.standard.string(forKey: "LastSection"),
           let sec = AppSection(rawValue: last), sec != .devices { section = sec }
        isLocked = settings.lockWithTouchID
        exports.deviceLookup = { [weak self] id in self?.devices.first { $0.id == id } }
        exports.onCompleted = { [weak self] rec in
            self?.toast(.success, L("Export completed"), rec.title, file: rec.fileURL)
            if !Self.isDevMode { Notifier.post(title: L("Export completed"), body: rec.title) }
        }
        loadDevConfigIfRequested()
        if Self.isDevMode, let s = ProcessInfo.processInfo.environment["VEDETTA_DEV_SECTION"], let sec = AppSection(rawValue: s) { section = sec }
        SelfTest.startIfRequested(model: self)
        observeSystem()
        eventMonitor = EventMonitor(model: self)
        DeviceClients.shared.onStateChange = { [weak self] id, state in self?.accessChanged(id, state) }
        exports.canRun = { [weak self] id in
            MainActor.assumeIsolated {
                guard let d = self?.devices.first(where: { $0.id == id }) else { return true }
                return DeviceClients.shared.state(of: d).isUsable
            }
        }
        CredentialCache.shared.preload(devices.map(\.id)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.credentialsReady = true
                self.startSessions()
                self.exports.pump()
                // Dev / self-test runs must never post notifications to the user.
                if self.settings.notificationsEnabled && !Self.isDevMode { self.eventMonitor?.start() }
            }
        }
    }

    // MARK: Lookup

    var hasDevices: Bool { !devices.isEmpty }
    var allChannels: [Channel] { devices.flatMap(\.visibleChannels) }
    var playbackChannels: [Channel] { devices.flatMap(\.visibleChannels).filter(\.supportsPlayback) }

    func device(for channel: Channel) -> Device? { devices.first { $0.id == channel.deviceID } }
    func channel(id: String) -> Channel? {
        for d in devices { if let c = d.channels.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Accounts (lockout protection)

    func accessState(_ d: Device) -> AccessState { access[d.id] ?? .unverified }
    var devicesNeedingSignIn: [Device] { devices.filter { accessState($0).needsUser } }
    /// Every device needs the user: show the sign-in screen instead of the main window.
    var everyDeviceNeedsSignIn: Bool { hasDevices && devicesNeedingSignIn.count == devices.count }

    /// One verification per device at launch (VIGI: the single login whose session every feature then shares;
    /// ONVIF: GetDeviceInformation). Streams wait for its result, so refused credentials are never retried.
    private func startSessions() {
        for d in devices {
            let g = DeviceClients.shared.accessGuard(for: d)
            // A guard created before the Keychain was read may think the password is missing.
            if g.state == .missingPassword, d.storedCredentials != nil { g.reset(verified: false) }
            if g.state != .missingPassword, d.storedCredentials == nil { g.markMissingPassword() }
            access[d.id] = g.state
            g.verifyIfNeeded()
        }
    }

    private func accessChanged(_ id: UUID, _ state: AccessState) {
        let old = access[id]
        access[id] = state
        guard let d = devices.first(where: { $0.id == id }) else { return }
        if state.isUsable { exports.pump() }
        guard old != state, !Self.isDevMode else { return }
        switch state {
        case .rejected, .locked:
            if !(old?.needsUser ?? false) {
                Notifier.post(title: L("Vedetta stopped connecting to %@", d.name), body: state.message, id: "access-\(id)")
            }
        default: break
        }
    }

    /// "Sign out" / "Switch user": closes every stream, ends the session on the recorder (only when it can be
    /// reached, never logging in), stops every retry, deletes the saved password and shows the sign-in screen.
    func signOut(_ d: Device, switchUser: Bool = false) async {
        access[d.id] = .signedOut
        stopLiveRecordings(of: d.id)
        await DeviceClients.shared.signOut(d, pool: pool)
        exports.interrupt(deviceID: d.id, message: L("Interrupted: signed out of the recorder"))
        index.clearCache()
        reloadToken = UUID()
        if switchUser || !everyDeviceNeedsSignIn { signIn = SignInRequest(deviceID: d.id, clearUser: switchUser) }
    }

    /// "Try again" after a refusal/lock (one attempt with the saved password) or while offline (immediate check).
    func retryAccess(_ d: Device) {
        guard d.storedCredentials != nil else { signIn = SignInRequest(deviceID: d.id); return }
        DeviceClients.shared.accessGuard(for: d).retryNow()   // the device's first check runs by itself
        reloadToken = UUID()
    }

    // MARK: Devices

    func addOrUpdate(_ result: ConnectResult, password: String) {
        let d = result.device
        CredentialCache.shared.set(password, for: d.id)
        DeviceClients.shared.adopt(result)
        access[d.id] = .online
        if signIn?.deviceID == d.id { signIn = nil }
        if let i = devices.firstIndex(where: { $0.id == d.id }) {
            devices[i] = d
            stopLiveRecordings(of: d.id)
            pool.restart(keysWithPrefix: d.id.uuidString)
            reloadToken = UUID()
        } else {
            devices.append(d)
            let newIDs = d.visibleChannels.map(\.id)
            var slots = layout.slots.compactMap { $0 }
            slots.append(contentsOf: newIDs.filter { !slots.contains($0) })
            layout.slots = slots
            if devices.count == 1 || layout.slots.count <= 16 {
                layout.grid = GridKind.fitting(min(16, slots.count))
                layout.page = 0
            }
        }
        index.clearCache()
        for w in result.warnings { toast(.warning, L("Warning"), w) }
        eventMonitor?.restart()
        exports.pump()
    }

    func updateDevice(_ d: Device) {
        guard let i = devices.firstIndex(where: { $0.id == d.id }) else { return }
        devices[i] = d
    }

    func remove(_ d: Device) {
        stopLiveRecordings(of: d.id)
        pool.restart(keysWithPrefix: d.id.uuidString)
        CredentialCache.shared.remove(d.id)
        TrustStore.shared.forget(host: d.host)
        DeviceClients.shared.forget(d.id)
        access[d.id] = nil
        if signIn?.deviceID == d.id { signIn = nil }
        let ids = Set(d.channels.map(\.id))
        layout.slots = layout.slots.map { $0.flatMap { ids.contains($0) ? nil : $0 } }
        while layout.slots.last == .some(nil) { layout.slots.removeLast() }
        devices.removeAll { $0.id == d.id }
        eventMonitor?.restart()
    }

    func renameChannel(_ ch: Channel, to name: String) {
        guard let di = devices.firstIndex(where: { $0.id == ch.deviceID }),
              let ci = devices[di].channels.firstIndex(where: { $0.id == ch.id }) else { return }
        devices[di].channels[ci].name = name
    }

    func setHidden(_ ch: Channel, _ hidden: Bool) {
        guard let di = devices.firstIndex(where: { $0.id == ch.deviceID }),
              let ci = devices[di].channels.firstIndex(where: { $0.id == ch.id }) else { return }
        devices[di].channels[ci].isHidden = hidden
        if hidden { layout.slots = layout.slots.map { $0 == ch.id ? nil : $0 } }
    }

    static let isDevMode = ProcessInfo.processInfo.environment["VEDETTA_DEV"] == "1"

    func discover() async {
        guard !Self.isDevMode else { return }
        isDiscovering = true
        discovered = await ONVIFDiscovery.probe(timeout: 3)
        isDiscovering = false
    }

    // MARK: Live layout

    var pageCount: Int {
        let cap = layout.grid.capacity
        let used = (layout.slots.lastIndex { $0 != nil } ?? -1) + 1
        return max(1, Int(ceil(Double(used) / Double(cap))))
    }

    /// Current page, clamped (channels may have been hidden or removed since it was chosen).
    var currentPage: Int { min(max(0, layout.page), pageCount - 1) }

    func slotIndex(tile: Int) -> Int { currentPage * layout.grid.capacity + tile }

    func channelID(atTile tile: Int) -> String? {
        let i = slotIndex(tile: tile)
        return i < layout.slots.count ? layout.slots[i] : nil
    }

    func assign(channelID: String?, toTile tile: Int) {
        let i = slotIndex(tile: tile)
        if let channelID, let existing = layout.slots.firstIndex(of: channelID) {
            // Swap with the tile that currently shows the channel.
            if existing == i { return }
            while layout.slots.count <= i { layout.slots.append(nil) }
            layout.slots[existing] = layout.slots[i]
            layout.slots[i] = channelID
            return
        }
        while layout.slots.count <= i { layout.slots.append(nil) }
        layout.slots[i] = channelID
        while layout.slots.last == .some(nil) { layout.slots.removeLast() }
    }

    func setGrid(_ g: GridKind) {
        // Keep the first visible channel on the new page.
        let firstSlot = currentPage * layout.grid.capacity
        layout.grid = g
        layout.page = min(firstSlot / g.capacity, max(0, pageCount - 1))
        singleTileRestore = nil
        selectedTile = nil
    }

    func toggleSingle(tile: Int) {
        if let restore = singleTileRestore {
            let slot = currentPage // in single mode page == slot
            layout.grid = restore
            layout.page = slot / restore.capacity
            selectedTile = slot % restore.capacity
            singleTileRestore = nil
        } else {
            let slot = slotIndex(tile: tile)
            singleTileRestore = layout.grid
            layout.grid = .one
            layout.page = slot
            selectedTile = 0
        }
    }

    func showChannelLive(_ id: String) {
        section = .live
        if let i = layout.slots.firstIndex(of: id) {
            layout.page = i / layout.grid.capacity
            selectedTile = i % layout.grid.capacity
        } else {
            layout.slots.append(id)
            layout.page = (layout.slots.count - 1) / layout.grid.capacity
            selectedTile = (layout.slots.count - 1) % layout.grid.capacity
        }
    }

    func nextPage() { layout.page = (currentPage + 1) % pageCount }
    func previousPage() { layout.page = (currentPage - 1 + pageCount) % pageCount }

    func toggleTour() {
        tourRunning.toggle()
        tourTimer?.invalidate()
        guard tourRunning else { return }
        let t = Timer(timeInterval: TimeInterval(max(5, settings.tourIntervalSeconds)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.pageCount > 1 { self.nextPage() } }
        }
        RunLoop.main.add(t, forMode: .common)
        tourTimer = t
    }

    /// Channels whose HD stream the recorder refused for bandwidth (509/453): light stream until that date.
    var hdLimitedUntil: [String: Date] = [:]

    func isHDLimited(_ ch: Channel) -> Bool { (hdLimitedUntil[ch.id] ?? .distantPast) > Date() }

    /// The recorder refused the HD stream of a channel: use the light one for 10 minutes, then try HD again.
    func noteBandwidthLimit(_ ch: Channel) {
        guard !isHDLimited(ch) else { return }
        hdLimitedUntil[ch.id] = Date().addingTimeInterval(600)
        if let d = device(for: ch) {
            DeviceClients.shared.accessGuard(for: d).note("RTSP \(ch.name)", "bandwidth limit", "HD refused by the recorder (509): light stream for 10 minutes")
        }
    }

    func streamKind(for ch: Channel, tileWidth width: CGFloat) -> StreamKind {
        isHDLimited(ch) ? .sub : streamKind(forTileWidth: width)
    }

    func streamKind(forTileWidth width: CGFloat) -> StreamKind {
        switch settings.liveQuality {
        case .high: return .main
        case .low: return .sub
        case .auto:
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return width * scale >= 1400 ? .main : .sub
        }
    }

    // MARK: Playback navigation

    func openPlayback(channelIDs: [String], at time: Date) {
        playbackRequest = PlaybackRequest(channelIDs: channelIDs, time: time)
        section = .playback
    }

    // MARK: Files

    func snapshotURL(for channel: Channel) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(channel.name) \(f.string(from: Date())).jpg".replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.createDirectory(at: settings.snapshotsURL, withIntermediateDirectories: true)
        return settings.snapshotsURL.appendingPathComponent(name)
    }

    func recordingURL(for channel: Channel) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(channel.name) \(f.string(from: Date())).mp4".replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.createDirectory(at: settings.recordingsURL, withIntermediateDirectories: true)
        return settings.recordingsURL.appendingPathComponent(name)
    }

    // MARK: Live streams, full-quality recording and snapshots

    static func streamKey(_ d: Device, _ ch: Channel, _ kind: StreamKind) -> String {
        "\(d.id.uuidString)|\(ch.id)|\(kind == .main ? "main" : "sub")"
    }

    /// Shared live stream of a channel (one connection however many viewers); balance with `pool.release`.
    func acquireStream(device: Device, channel: Channel, kind: StreamKind) -> LiveStream? {
        guard let url = StreamURLs.live(device: device, channel: channel, kind: kind) else { return nil }
        return pool.acquire(key: Self.streamKey(device, channel, kind), url: url, credentials: device.credentials,
                            title: channel.name, accessGuard: DeviceClients.shared.accessGuard(for: device))
    }

    struct LiveRecording {
        let stream: LiveStream
        let url: URL
        var started: Date?
    }
    /// Recordings on this Mac, by channel. Always from the main (full quality) stream, whatever the tile shows.
    var liveRecordings: [String: LiveRecording] = [:]

    func toggleLiveRecording(channel: Channel, device: Device) {
        if let rec = liveRecordings.removeValue(forKey: channel.id) {
            rec.stream.stopRecording { url, err in
                DispatchQueue.main.async {
                    self.pool.release(rec.stream)
                    if let url { self.toast(.success, L("Recording saved"), channel.name, file: url) }
                    else if let err { self.toast(.error, L("Recording not saved"), err.localizedDescription) }
                }
            }
            return
        }
        guard let s = acquireStream(device: device, channel: channel, kind: .main) else { return }
        let url = recordingURL(for: channel)
        liveRecordings[channel.id] = LiveRecording(stream: s, url: url, started: nil)
        s.startRecording(to: url, wait: 15) { err in
            DispatchQueue.main.async {
                if let err {
                    if self.liveRecordings[channel.id]?.url == url { self.liveRecordings[channel.id] = nil }
                    self.pool.release(s)
                    if case LiveStreamError.bandwidthLimited = err {
                        // HD refused by the recorder: record the light stream rather than nothing.
                        self.noteBandwidthLimit(channel)
                        self.startReducedRecording(channel: channel, device: device, url: url)
                    } else {
                        self.toast(.error, L("Cannot record"), err.localizedDescription)
                    }
                } else {
                    self.liveRecordings[channel.id]?.started = Date()
                    let res = s.status.resolution
                    self.toast(.info, L("Recording started"), res == .zero
                               ? L("%@ — the file is being saved on this Mac", channel.name)
                               : L("%@ — full quality (%@), saved on this Mac", channel.name, "\(Int(res.width))×\(Int(res.height))"))
                }
            }
        }
    }

    private func startReducedRecording(channel: Channel, device: Device, url: URL) {
        guard liveRecordings[channel.id] == nil, let s = acquireStream(device: device, channel: channel, kind: .sub) else { return }
        liveRecordings[channel.id] = LiveRecording(stream: s, url: url, started: nil)
        s.startRecording(to: url, wait: 15) { err in
            DispatchQueue.main.async {
                if let err {
                    if self.liveRecordings[channel.id]?.url == url { self.liveRecordings[channel.id] = nil }
                    self.pool.release(s)
                    self.toast(.error, L("Cannot record"), err.localizedDescription)
                } else {
                    self.liveRecordings[channel.id]?.started = Date()
                    self.toast(.warning, L("Recording at reduced quality"),
                               L("%@: the recorder has reached its bandwidth limit, so the HD stream is not available now.", channel.name))
                }
            }
        }
    }

    /// Quitting: finalizes every recording file, then calls `done` (at most after 5 s).
    func finishAllRecordings(done: @escaping @MainActor () -> Void) {
        let list = Array(liveRecordings.values)
        liveRecordings.removeAll()
        guard !list.isEmpty else { return done() }
        var left = list.count
        var called = false
        func finish() { if !called { called = true; done() } }
        for rec in list {
            rec.stream.stopRecording { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { left -= 1; if left == 0 { finish() } } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { finish() } }
    }

    func stopLiveRecordings(of deviceID: UUID) {
        for (id, _) in liveRecordings where channel(id: id)?.deviceID == deviceID {
            if let ch = channel(id: id), let d = device(for: ch) { toggleLiveRecording(channel: ch, device: d) }
        }
    }

    /// Snapshot at the camera's full resolution: taken from the main stream even when the tile shows the light one.
    func saveFullQualitySnapshot(channel: Channel, device: Device, current: CGImage?, currentIsMain: Bool) {
        if currentIsMain, let current { return saveSnapshot(current, channel: channel) }
        guard let s = acquireStream(device: device, channel: channel, kind: .main) else { return saveSnapshot(current, channel: channel) }
        s.snapshotWhenReady(wait: 8) { img in
            let limited = s.isBandwidthLimited
            DispatchQueue.main.async {
                self.pool.release(s)
                if img == nil, limited {
                    self.noteBandwidthLimit(channel)
                    if current != nil {
                        self.toast(.warning, L("Snapshot at reduced quality"),
                                   L("%@: the recorder has reached its bandwidth limit, so the HD stream is not available now.", channel.name))
                    }
                }
                self.saveSnapshot(img ?? current, channel: channel)
            }
        }
    }

    // MARK: Tiles

    /// Drag of a live tile onto another one (swaps them, or moves into an empty tile).
    struct TileDrag: Equatable {
        var from: Int
        var channelID: String
        var name: String
        var location: CGPoint
    }
    var tileDrag: TileDrag?
    /// The playback on screen (Recordings section), for diagnostics and the self test.
    @ObservationIgnored weak var activePlayback: PlaybackSession?

    // MARK: Settings backup

    func exportSettings(to url: URL) throws {
        JSONStore<AppSettings>.flushAll()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let lang = AppLanguage.override == .system ? nil : AppLanguage.override.rawValue
        let backup = SettingsBackup(appVersion: version, settings: settings, layout: layout, devices: devices, language: lang)
        try backup.encoded().write(to: url, options: .atomic)
    }

    /// Replaces devices, layout and settings. Passwords are not in the file: devices without a saved password
    /// ask to sign in (nothing is attempted with an empty password).
    func importSettings(_ b: SettingsBackup) {
        for d in devices where !b.devices.contains(where: { $0.id == d.id }) { remove(d) }
        for d in devices { stopLiveRecordings(of: d.id); pool.restart(keysWithPrefix: d.id.uuidString); DeviceClients.shared.forget(d.id) }
        devices = b.devices
        layout = b.layout
        settings = b.settings
        if let l = b.language.flatMap(AppLanguage.init(rawValue:)) { AppLanguage.override = l }
        access = [:]
        index.clearCache()
        CredentialCache.shared.preload(devices.map(\.id)) { [weak self] in
            MainActor.assumeIsolated {
                self?.startSessions()
                self?.reloadToken = UUID()
            }
        }
    }

    func saveSnapshot(_ image: CGImage?, channel: Channel) {
        guard let image else { toast(.error, L("Snapshot not available"), L("Wait until the video is visible.")); return }
        let url = snapshotURL(for: channel)
        if ImageWriterBridge.write(image, to: url) {
            NSSound(named: "Tink")?.play()
            toast(.success, L("Snapshot saved"), channel.name, file: url)
        } else {
            toast(.error, L("Cannot save the snapshot"), url.deletingLastPathComponent().path)
        }
    }

    // MARK: Toasts

    func toast(_ style: Toast.Style, _ title: String, _ detail: String? = nil, file: URL? = nil) {
        let t = Toast(style: style, title: title, detail: detail, fileURL: file)
        withAnimation(.spring(duration: 0.35)) { toasts.append(t) }
        if toasts.count > 4 { toasts.removeFirst() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == .error ? 7 : 4)) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.toasts.removeAll { $0.id == t.id } }
        }
    }

    // MARK: Settings side effects

    private func applySettings(old: AppSettings) {
        if old.notificationsEnabled != settings.notificationsEnabled, !Self.isDevMode {
            settings.notificationsEnabled ? eventMonitor?.start() : eventMonitor?.stop()
            if settings.notificationsEnabled { Notifier.requestAuthorization() }
        }
        if old.liveQuality != settings.liveQuality { reloadToken = UUID() }
        if old.tourIntervalSeconds != settings.tourIntervalSeconds, tourRunning { toggleTour(); toggleTour() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { toast(.error, L("Cannot change the login item"), error.localizedDescription) }
        }
    }

    // MARK: System integration (save CPU when nothing is visible)

    /// Automatic pause of streams when no window is visible (disabled by the self-test).
    @ObservationIgnored var autoSuspendEnabled = !(isDevMode && ProcessInfo.processInfo.environment["VEDETTA_KEEP_STREAMS"] == "1")

    func windowVisibilityChanged(_ window: NSWindow, visible: Bool) {
        guard autoSuspendEnabled else { return }
        let id = ObjectIdentifier(window)
        if visible { visibleWindows.insert(id) } else { visibleWindows.remove(id) }
        if visibleWindows.isEmpty { pool.suspend() } else { pool.resume() }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pool.suspend() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pool.suspend() }
        })
        let wake: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.visibleWindows.isEmpty else { return }
                self.pool.resume()
            }
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: wake))
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: wake))
    }

    // MARK: Development hook (test bench only)

    private func loadDevConfigIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["VEDETTA_DEV"] == "1", let path = env["VEDETTA_DEV_CONFIG"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              devices.isEmpty,
              let address = cfg["address"] as? String, let user = cfg["user"] as? String, let pass = cfg["pass"] as? String else { return }
        let http = cfg["httpPort"] as? Int ?? 443
        let rtsp = cfg["rtspPort"] as? Int ?? 554
        let kind = cfg["kind"] as? String ?? "vigi"
        Task {
            let r: ConnectResult?
            if kind == "onvif" {
                r = try? await DeviceConnector.connectRecorder(address: address, onvifURL: nil, brand: nil, rtspPort: rtsp, username: user, password: pass)
            } else {
                r = try? await DeviceConnector.connectNVR(address: address, httpPort: http, rtspPort: rtsp, username: user, password: pass)
            }
            if let r { addOrUpdate(r, password: pass) }
        }
    }
}

enum ImageWriterBridge {
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    static func post(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
