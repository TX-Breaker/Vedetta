import Foundation
import CoreMedia
import Observation
import RTSPKit
import MediaKit
import VigiKit
import NetKit
import VedettaL10n

/// One channel of NVR playback: RTSP replay → samples stamped with absolute time (seconds since 1970).
final class ReplayStream: @unchecked Sendable {
    let channel: Channel
    private let credentials: Credentials
    private let accessGuard: AccessGuard?
    private var guardObserver: UUID?
    let start: Date
    let end: Date
    private let scale: Double?
    private let queue: DispatchQueue
    private let targetsProvider: @Sendable () async throws -> [ReplayTarget]
    private var client: RTSPClient?
    private var sinks: [WeakSink] = []
    private var codec: VideoCodec?
    private var clockRate = 90000
    private var paramSets = VideoParameterSets()
    private var format: CMVideoFormatDescription?
    private var unwrap = RTPTimestampUnwrapper()
    private var anchor: (rtp: Int64, abs: Double)?
    private var lastAbs: Double = 0
    private var lastRTP: Int64 = 0
    private var needKeyframe = true
    private var stopped = false

    var onFirstFrame: ((Double) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onEnded: ((Error?) -> Void)?
    /// Reports the tag of the target that worked (e.g. the VIGI time suffix).
    var onTargetWorked: ((String?) -> Void)?
    var onScale: ((Double?) -> Void)?
    /// Raw access units with absolute times (used by exports).
    var onAccessUnit: ((AccessUnit, Double, CMVideoFormatDescription, AudioTrackInfo?) -> Void)?
    var onAudioFrame: ((AudioFrame, Double, AudioTrackInfo) -> Void)?
    private var audioInfo: AudioTrackInfo?
    private var audioUnwrap = RTPTimestampUnwrapper()
    private var audioAnchor: (rtp: Int64, abs: Double)?
    private var firstFrameSent = false

    init(channel: Channel, credentials: Credentials, start: Date, end: Date, scale: Double? = nil,
         accessGuard: AccessGuard? = nil, targets: @escaping @Sendable () async throws -> [ReplayTarget]) {
        self.channel = channel
        self.credentials = credentials
        self.accessGuard = accessGuard
        self.start = start
        self.end = end
        self.scale = scale
        self.targetsProvider = targets
        queue = DispatchQueue(label: "vedetta.replay.\(channel.id)", qos: .userInitiated)
    }

    func attach(_ sink: VideoSink) { queue.async { self.sinks.append(WeakSink(sink)) } }
    func detachAll() { queue.async { self.sinks.removeAll() } }

    func begin() {
        if let g = accessGuard {
            // Refused credentials, locked account or sign out: close the stream at once.
            guardObserver = g.observe { [weak self] state in
                guard state.needsUser, let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    self.stopped = true
                    self.client?.stop()
                    self.client = nil
                    self.onEnded?(AccessBlocked(state: state))
                }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let targets = try await self.targetsProvider()
                self.queue.async { self.open(targets, index: 0, lastError: nil) }
            } catch {
                self.queue.async { if !self.stopped { self.onEnded?(error) } }
            }
        }
    }

    private func open(_ targets: [ReplayTarget], index: Int, lastError: Error?) {
        guard !stopped else { return }
        guard index < targets.count else { onEnded?(lastError ?? RTSPError.noSupportedTrack); return }
        let target = targets[index]
        var opts = RTSPClient.Options(url: target.url, username: credentials.username, password: credentials.password)
        opts.range = target.range
        opts.scale = scale
        opts.extraPlayHeaders = target.playHeaders
        opts.extraHeaders = target.headers
        opts.wantAudio = onAudioFrame != nil
        let c = RTSPClient(options: opts, queue: queue)
        client = c
        c.onDescribed = { [weak self] d in
            guard let self else { return }
            self.codec = d.videoCodec
            self.clockRate = d.videoClockRate
            self.paramSets = d.videoParameterSets
            self.audioInfo = d.audio
            self.onScale?(d.scaleAccepted)
        }
        c.onParameterSets = { [weak self] ps in
            guard let self else { return }
            if ps != self.paramSets { self.paramSets = ps; self.format = nil }
        }
        c.onVideo = { [weak self] au in self?.handle(au) }
        c.onAudio = { [weak self] f in self?.handleAudio(f) }
        c.onClosed = { [weak self] err in
            guard let self, !self.stopped else { return }
            self.onEnded?(err)
        }
        let g = accessGuard
        let title = channel.name
        Task { [weak self] in
            do {
                if let g {
                    try await g.credentialed("RTSP replay \(title)", important: false, { try await c.start() }) { r in
                        LiveStream.outcome(r, client: c)
                    }
                } else {
                    try await c.start()
                }
                self?.queue.async { self?.onTargetWorked?(target.tag) }
            } catch {
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    c.stop()
                    // Never try the other addresses with credentials that were just refused, nor when blocked/offline.
                    if case RTSPError.unauthorized = error { self.onEnded?(error); return }
                    if case RTSPError.unreachable = error { self.onEnded?(error); return }
                    if error is AccessBlocked { self.onEnded?(error); return }
                    self.open(targets, index: index + 1, lastError: error)
                }
            }
        }
    }

    func pause() async -> Bool {
        guard let c = client else { return false }
        do { try await c.pause(); return true } catch { return false }
    }

    func resume() async -> Bool {
        guard let c = client else { return false }
        do { try await c.resume(); return true } catch { return false }
    }

    /// Stops the stream; `then` runs on the stream queue after the last sample was delivered.
    func stop(then: (@Sendable () -> Void)? = nil) {
        if let o = guardObserver { accessGuard?.removeObserver(o); guardObserver = nil }
        queue.async {
            self.stopped = true
            self.client?.stop()
            self.client = nil
            self.sinks.removeAll()
            then?()
        }
    }

    private func absTime(_ au: AccessUnit) -> Double {
        let t = unwrap.unwrap(au.rtpTimestamp)
        if let onvif = au.onvifTime {
            anchor = (t, onvif.timeIntervalSince1970)
            lastRTP = t
            return onvif.timeIntervalSince1970
        }
        if anchor == nil { anchor = (t, start.timeIntervalSince1970) }
        let delta = Double(t - lastRTP) / Double(clockRate)
        if lastRTP != 0, delta < -1 || delta > 3600 {
            // Timestamp discontinuity: continue from the last known time.
            anchor = (t, lastAbs + 0.04)
        }
        lastRTP = t
        return anchor!.abs + Double(t - anchor!.rtp) / Double(clockRate)
    }

    private func handle(_ au: AccessUnit) {
        guard let codec, !stopped else { return }
        if format == nil, paramSets.isComplete(for: codec) {
            format = VideoFormat.formatDescription(codec: codec, parameterSets: paramSets)
            needKeyframe = true
        }
        let abs = absTime(au)
        guard let format else { return }
        if needKeyframe {
            guard au.isKeyframe else { return }
            needKeyframe = false
        }
        lastAbs = abs
        onAccessUnit?(au, abs, format, audioInfo)
        if !sinks.isEmpty, let sample = VideoFormat.sampleBuffer(from: au, format: format, pts: CMTime(seconds: abs, preferredTimescale: 90000)) {
            for s in sinks { s.sink?.enqueue(sample) }
        }
        if !firstFrameSent {
            firstFrameSent = true
            onFirstFrame?(abs)
        }
        onProgress?(abs)
    }

    private func handleAudio(_ f: AudioFrame) {
        guard !stopped, let info = audioInfo, anchor != nil else { return }
        let t = audioUnwrap.unwrap(f.rtpTimestamp)
        if audioAnchor == nil { audioAnchor = (t, lastAbs) }
        let abs = audioAnchor!.abs + Double(t - audioAnchor!.rtp) / Double(max(1, info.sampleRate))
        onAudioFrame?(f, abs, info)
    }
}

/// Synchronised multi-channel playback of NVR recordings.
@MainActor
@Observable
public final class PlaybackSession {
    public private(set) var device: Device
    public private(set) var channels: [Channel] = []
    public private(set) var currentTime: Date
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var speed: Double = 1
    public var notice: String?
    public private(set) var endedChannels: Set<String> = []

    @ObservationIgnored private let timebase: CMTimebase
    @ObservationIgnored private var streams: [String: ReplayStream] = [:]
    @ObservationIgnored private var sinks: [String: WeakSink] = [:]
    @ObservationIgnored private var clockStarted = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pauseFailed = false
    @ObservationIgnored public var segmentsProvider: ((Channel) -> [DateInterval])?
    @ObservationIgnored public var onDeviceUpdated: ((Device) -> Void)?

    public init(device: Device, start: Date) {
        self.device = device
        self.currentTime = start
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        timebase = tb!
        CMTimebaseSetRate(timebase, rate: 0)
    }

    public func setChannels(_ list: [Channel]) {
        channels = Array(list.prefix(4))
    }

    public func updateDevice(_ d: Device) { device = d }

    public func attach(_ sink: VideoSink, for channelID: String) {
        sinks[channelID] = WeakSink(sink)
        sink.setTimebase(timebase)
        streams[channelID]?.attach(sink)
    }

    public func detach(channelID: String) {
        sinks[channelID]?.sink?.setTimebase(nil)
        sinks[channelID] = nil
    }

    // MARK: Transport controls

    public func play(from requested: Date, scale: Double? = nil) {
        stopStreams()
        notice = nil
        endedChannels = []
        let start = snapToRecording(requested)
        currentTime = start
        clockStarted = false
        pauseFailed = false
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: start.timeIntervalSince1970, preferredTimescale: 90000))
        for s in sinks.values { s.sink?.flush() }
        guard !channels.isEmpty else { return }
        let end = min(start.addingTimeInterval(12 * 3600), Date())
        guard end > start.addingTimeInterval(1) else { notice = L("No recordings after this time"); return }
        isBuffering = true
        isPlaying = true
        let creds = device.credentials
        let dev = device
        generation += 1
        let gen = generation
        for ch in channels {
            let rs = ReplayStream(channel: ch, credentials: creds, start: start, end: end, scale: scale,
                                  accessGuard: DeviceClients.shared.accessGuard(for: dev)) {
                try await PlaybackBackend.replayTargets(device: dev, channel: ch, from: start, to: end, export: false)
            }
            let id = ch.id
            rs.onFirstFrame = { [weak self] abs in
                DispatchQueue.main.async { if self?.generation == gen { self?.firstFrame(abs: abs) } }
            }
            rs.onEnded = { [weak self] err in
                DispatchQueue.main.async { if self?.generation == gen { self?.streamEnded(channelID: id, error: err) } }
            }
            rs.onTargetWorked = { [weak self] tag in
                DispatchQueue.main.async {
                    guard let self, let suffix = tag, self.device.kind == .vigiNVR, self.device.replayTimeSuffix == nil else { return }
                    self.device.replayTimeSuffix = suffix
                    self.onDeviceUpdated?(self.device)
                }
            }
            if let scale {
                rs.onScale = { [weak self] accepted in
                    DispatchQueue.main.async {
                        guard let self, self.generation == gen else { return }
                        if accepted == nil || abs((accepted ?? 1) - scale) > 0.01 {
                            self.speed = 1
                            self.play(from: self.currentTime)
                            // After play(), which clears notices.
                            self.notice = L("The recorder does not support speed %@", Self.speedLabel(scale))
                        }
                    }
                }
            }
            if let s = sinks[id]?.sink { rs.attach(s) }
            streams[id] = rs
            rs.begin()
        }
        startTimer()
    }

    private func firstFrame(abs: Double) {
        isBuffering = false
        guard !clockStarted else { return }
        clockStarted = true
        let now = CMTimebaseGetTime(timebase).seconds
        // If the requested instant was in a gap, jump the clock to the first available picture.
        if abs > now + 0.5 || abs < now - 5 {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: abs, preferredTimescale: 90000))
        }
        CMTimebaseSetRate(timebase, rate: isPlaying ? speed : 0)
    }

    private func streamEnded(channelID: String, error: Error?) {
        guard streams[channelID] != nil else { return }
        if let blocked = error as? AccessBlocked {
            // Signed out, refused or locked: stop everything and say why.
            stop()
            notice = blocked.localizedDescription
            isBuffering = false
            return
        }
        endedChannels.insert(channelID)
        if let error, !clockStarted {
            notice = error.localizedDescription
            isBuffering = false
        }
        if endedChannels.count == streams.count {
            isBuffering = false
            if clockStarted {
                // Let the buffered frames finish, then stop the clock.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.endedChannels.count == self.streams.count else { return }
                    CMTimebaseSetRate(self.timebase, rate: 0)
                    self.isPlaying = false
                    if self.notice == nil { self.notice = L("End of available recordings") }
                }
            } else if notice == nil {
                notice = L("No recordings in this range")
                isPlaying = false
            }
        }
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        CMTimebaseSetRate(timebase, rate: 0)
        let list = Array(streams.values)
        Task {
            var ok = true
            for s in list { if !(await s.pause()) { ok = false } }
            await MainActor.run { self.pauseFailed = !ok }
        }
    }

    public func resume() {
        guard !isPlaying else { return }
        if streams.isEmpty || pauseFailed || endedChannels.count == streams.count {
            play(from: currentTime, scale: speed == 1 ? nil : speed)
            return
        }
        isPlaying = true
        let list = Array(streams.values)
        Task {
            var ok = true
            for s in list { if !(await s.resume()) { ok = false } }
            await MainActor.run {
                if ok { CMTimebaseSetRate(self.timebase, rate: self.clockStarted ? self.speed : 0) }
                else { self.play(from: self.currentTime) }
            }
        }
    }

    public func togglePlay() { isPlaying ? pause() : resume() }

    public func seek(to date: Date) {
        play(from: date, scale: speed == 1 ? nil : speed)
    }

    public func jump(by seconds: TimeInterval) {
        seek(to: currentTime.addingTimeInterval(seconds))
    }

    public func setSpeed(_ s: Double) {
        guard s != speed else { return }
        speed = s
        play(from: currentTime, scale: s == 1 ? nil : s)
    }

    /// Advances one frame while paused.
    public func stepForward() {
        if isPlaying { pause() }
        let t = CMTimebaseGetTime(timebase).seconds + 0.04
        CMTimebaseSetTime(timebase, time: CMTime(seconds: t, preferredTimescale: 90000))
        currentTime = Date(timeIntervalSince1970: t)
    }

    /// Snapshot helper: freezes the clock briefly so the display layer exposes its picture.
    public func withFrozenClock<T>(_ body: () -> T) -> T {
        let rate = CMTimebaseGetRate(timebase)
        CMTimebaseSetRate(timebase, rate: 0)
        defer { CMTimebaseSetRate(timebase, rate: rate) }
        return body()
    }

    public func stop() {
        stopStreams()
        timer?.invalidate(); timer = nil
        isPlaying = false
        CMTimebaseSetRate(timebase, rate: 0)
    }

    private func stopStreams() {
        generation += 1
        for s in streams.values { s.stop() }
        streams.removeAll()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.clockStarted else { return }
                let secs = CMTimebaseGetTime(self.timebase).seconds
                if secs.isFinite { self.currentTime = Date(timeIntervalSince1970: secs) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func snapToRecording(_ t: Date) -> Date {
        guard let provider = segmentsProvider else { return t }
        var best: Date?
        for ch in channels {
            let segs = provider(ch)
            if segs.contains(where: { $0.contains(t) }) { return t }
            if let next = segs.first(where: { $0.start > t })?.start {
                best = min(best ?? next, next)
            }
        }
        return best ?? t
    }

    public static func speedLabel(_ s: Double) -> String {
        s < 1 ? "\(String(format: "%.2g", s))×" : "\(Int(s))×"
    }
}
