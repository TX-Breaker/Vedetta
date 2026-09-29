import Foundation
import CoreMedia
import AppKit
import Observation
import RTSPKit
import MediaKit
import NetKit
import VedettaL10n

@Observable
public final class StreamStatus {
    public enum Phase: Equatable {
        case idle, connecting, playing
        case reconnecting(String)
        case failed(String)
    }
    public var phase: Phase = .idle
    public var fps: Double = 0
    public var kbps: Double = 0
    public var resolution: CGSize = .zero
    public var codec: String = ""
    public var audioCodec: String?
    public var isRecording = false
    public var recordingStarted: Date?
    public var audioEnabled = false

    public init() {}

    public var isPlaying: Bool { phase == .playing }
    public var message: String? {
        switch phase {
        case .idle: return nil
        case .connecting: return L("Connecting to camera…")
        case .playing: return nil
        case .reconnecting(let s): return s
        case .failed(let s): return s
        }
    }
}

final class WeakSink {
    weak var sink: VideoSink?
    init(_ s: VideoSink) { sink = s }
}

/// One live RTSP stream shared by any number of video views. Reconnects automatically.
public final class LiveStream: @unchecked Sendable {
    public let key: String
    public let url: URL
    public let title: String
    private let credentials: Credentials
    public let status = StreamStatus()

    private let queue: DispatchQueue
    private var client: RTSPClient?
    private var sinks: [WeakSink] = []
    private var codec: VideoCodec?
    private var clockRate = 90000
    private var paramSets = VideoParameterSets()
    private var format: CMVideoFormatDescription?
    private var needKeyframe = true
    private var gop: [CMSampleBuffer] = []
    private var gopAUs: [(AccessUnit, Double)] = []
    private var recorder: MP4Recorder?
    private var audioInfo: AudioTrackInfo?
    private var audioPlayer: AudioPlayer?
    private var audioEnabled = false
    private var volume: Float = 1
    private var videoUnwrap = RTPTimestampUnwrapper()
    private var audioUnwrap = RTPTimestampUnwrapper()
    private var videoAnchor: (rtp: Int64, wall: Double)?
    private var audioAnchor: (rtp: Int64, wall: Double)?
    private var running = false
    private var attempt = 0
    private var lastFrameAt: CFAbsoluteTime = 0
    private var connectedAt: CFAbsoluteTime = 0
    private var watchdog: DispatchSourceTimer?
    private var frameCounter = 0
    private var byteCounter = 0
    private var lastStatsAt = CFAbsoluteTimeGetCurrent()
    private var generation = 0
    private var gotFirstFrame = false
    private var pendingReconnect: DispatchWorkItem?

    public init(key: String, url: URL, credentials: Credentials, title: String) {
        self.key = key
        self.url = url
        self.credentials = credentials
        self.title = title
        queue = DispatchQueue(label: "vedetta.live.\(key)", qos: .userInitiated)
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempt = 0
            startWatchdog()
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            pendingReconnect?.cancel()
            watchdog?.cancel(); watchdog = nil
            client?.stop(); client = nil
            generation += 1
            finishRecording(completion: nil)
            audioPlayer?.stop(); audioPlayer = nil
            gop.removeAll(); gopAUs.removeAll()
            setPhase(.idle)
        }
    }

    private func connect() {
        guard running else { return }
        generation += 1
        let gen = generation
        needKeyframe = true
        gotFirstFrame = false
        videoUnwrap.reset(); audioUnwrap.reset()
        videoAnchor = nil; audioAnchor = nil
        format = nil
        setPhase(attempt == 0 ? .connecting : .reconnecting(L("Reconnecting…")))

        var opts = RTSPClient.Options(url: url, username: credentials.username, password: credentials.password)
        opts.wantAudio = true
        let c = RTSPClient(options: opts, queue: queue)
        client = c
        connectedAt = CFAbsoluteTimeGetCurrent()
        lastFrameAt = connectedAt
        c.onDescribed = { [weak self] d in
            guard let self, gen == self.generation else { return }
            self.codec = d.videoCodec
            self.clockRate = d.videoClockRate
            self.paramSets = d.videoParameterSets
            self.audioInfo = d.audio
            if self.audioEnabled { self.ensureAudioPlayer() }
            let codecName = d.videoCodec?.rawValue ?? ""
            let audioName = d.audio?.codec.rawValue
            DispatchQueue.main.async { self.status.codec = codecName; self.status.audioCodec = audioName }
        }
        c.onParameterSets = { [weak self] ps in
            guard let self, gen == self.generation else { return }
            if ps != self.paramSets { self.paramSets = ps; self.format = nil }
        }
        c.onVideo = { [weak self] au in
            guard let self, gen == self.generation else { return }
            self.handleVideo(au)
        }
        c.onAudio = { [weak self] f in
            guard let self, gen == self.generation else { return }
            self.handleAudio(f)
        }
        c.onClosed = { [weak self] error in
            guard let self, gen == self.generation else { return }
            self.scheduleReconnect(reason: error?.localizedDescription ?? L("Connection interrupted"))
        }
        Task { [weak self] in
            do {
                try await c.start()
            } catch {
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    if case RTSPError.unauthorized = error {
                        self.client?.stop()
                        self.setPhase(.failed(L("Wrong user name or password")))
                        // Do not retry quickly: NVRs lock accounts after repeated failures.
                        self.scheduleReconnect(reason: nil, delay: 300)
                    } else {
                        let msg = error.localizedDescription
                        self.scheduleReconnect(reason: NetworkHint.looksLikeLocalNetworkBlock(msg)
                                               ? L("Network unreachable: check Vedetta's Local Network permission") : msg)
                    }
                }
            }
        }
    }

    private func scheduleReconnect(reason: String?, delay: Double? = nil) {
        guard running else { return }
        client?.stop()
        client = nil
        generation += 1
        let wait = delay ?? min(30, pow(2, Double(attempt)))
        attempt += 1
        if let reason { setPhase(.reconnecting(reason)) }
        pendingReconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        pendingReconnect = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        if client != nil, now - lastFrameAt > 10 {
            scheduleReconnect(reason: L("No video signal"))
            return
        }
        let dt = now - lastStatsAt
        if dt >= 1 {
            let fps = Double(frameCounter) / dt
            let kbps = Double(byteCounter * 8) / dt / 1000
            frameCounter = 0; byteCounter = 0; lastStatsAt = now
            let res = format.map { VideoFormat.dimensions(of: $0) } ?? .zero
            DispatchQueue.main.async {
                self.status.fps = fps
                self.status.kbps = kbps
                if self.status.resolution != res { self.status.resolution = res }
            }
        }
    }

    private func setPhase(_ p: StreamStatus.Phase) {
        DispatchQueue.main.async { if self.status.phase != p { self.status.phase = p } }
    }

    // MARK: Media

    private func time(forVideo ts: UInt32) -> Double {
        let t = videoUnwrap.unwrap(ts)
        if videoAnchor == nil { videoAnchor = (t, CFAbsoluteTimeGetCurrent()) }
        return videoAnchor!.wall + Double(t - videoAnchor!.rtp) / Double(clockRate)
    }

    private func handleVideo(_ au: AccessUnit) {
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        frameCounter += 1
        byteCounter += au.byteCount
        guard let codec else { return }
        if format == nil, paramSets.isComplete(for: codec) {
            format = VideoFormat.formatDescription(codec: codec, parameterSets: paramSets)
            needKeyframe = true
            if let f = format {
                let size = VideoFormat.dimensions(of: f)
                DispatchQueue.main.async { self.status.resolution = size }
            }
        }
        let t = time(forVideo: au.rtpTimestamp)
        guard let format else { return }
        if needKeyframe {
            guard au.isKeyframe else { return }
            needKeyframe = false
        }
        guard let sample = VideoFormat.sampleBuffer(from: au, format: format, pts: CMTime(seconds: t, preferredTimescale: 90000)) else { return }
        VideoFormat.setDisplayImmediately(sample)
        if au.isKeyframe { gop.removeAll(keepingCapacity: true); gopAUs.removeAll(keepingCapacity: true) }
        if gop.count < 900 { gop.append(sample); gopAUs.append((au, t)) }
        for w in sinks { w.sink?.enqueue(sample) }
        sinks.removeAll { $0.sink == nil }
        recorder?.appendVideo(au, time: t)
        if !gotFirstFrame {
            gotFirstFrame = true
            attempt = 0
            setPhase(.playing)
        }
    }

    private func handleAudio(_ f: AudioFrame) {
        guard let info = audioInfo else { return }
        let t = audioUnwrap.unwrap(f.rtpTimestamp)
        if audioAnchor == nil { audioAnchor = (t, CFAbsoluteTimeGetCurrent()) }
        let secs = audioAnchor!.wall + Double(t - audioAnchor!.rtp) / Double(max(1, info.sampleRate))
        recorder?.appendAudio(f, time: secs)
        if audioEnabled { audioPlayer?.enqueue(f) }
    }

    private func ensureAudioPlayer() {
        guard audioPlayer == nil, let info = audioInfo else { return }
        audioPlayer = AudioPlayer(info: info)
        audioPlayer?.volume = volume
    }

    // MARK: Sinks

    public func attach(_ sink: VideoSink) {
        queue.async { [self] in
            guard !sinks.contains(where: { $0.sink === sink }) else { return }
            sinks.append(WeakSink(sink))
            // Instant picture: replay the current GOP into the new view.
            for s in gop { sink.enqueue(s) }
        }
    }

    public func detach(_ sink: VideoSink) {
        queue.async { [self] in sinks.removeAll { $0.sink === sink || $0.sink == nil } }
    }

    // MARK: Audio

    public func setAudio(enabled: Bool, volume: Float = 1) {
        queue.async { [self] in
            audioEnabled = enabled
            self.volume = volume
            if enabled { ensureAudioPlayer(); audioPlayer?.volume = volume }
            else { audioPlayer?.stop(); audioPlayer = nil }
            DispatchQueue.main.async { self.status.audioEnabled = enabled }
        }
    }

    // MARK: Recording & snapshots

    public func startRecording(to url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard let format else { completion(RecorderError.cannotCreate(L("waiting for video"))); return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let r = try MP4Recorder(url: url, videoFormat: format, audio: audioInfo)
                for (au, t) in gopAUs { r.appendVideo(au, time: t) }
                recorder = r
                DispatchQueue.main.async { self.status.isRecording = true; self.status.recordingStarted = Date() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    public func stopRecording(completion: @escaping @Sendable (URL?, Error?) -> Void) {
        queue.async { [self] in finishRecording(completion: completion) }
    }

    private func finishRecording(completion: (@Sendable (URL?, Error?) -> Void)?) {
        guard let r = recorder else { completion?(nil, nil); return }
        recorder = nil
        DispatchQueue.main.async { self.status.isRecording = false; self.status.recordingStarted = nil }
        r.finish { url, err in completion?(url, err) }
    }

    /// Current picture as CGImage (decoded on demand from the last GOP).
    public func snapshot(completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [self] in
            guard let format, !gop.isEmpty else { completion(nil); return }
            let samples = gop
            DispatchQueue.global(qos: .userInitiated).async {
                completion(FrameDecoder.image(fromGOP: samples, format: format))
            }
        }
    }
}

/// Shares live streams between views and stops them shortly after the last viewer leaves.
@MainActor
public final class StreamPool {
    private struct Entry {
        var stream: LiveStream
        var refs: Int
        var stopWork: DispatchWorkItem?
    }
    private var entries: [String: Entry] = [:]
    public private(set) var isSuspended = false

    public init() {}

    public func acquire(key: String, url: URL, credentials: Credentials, title: String) -> LiveStream {
        if var e = entries[key], e.stream.url == url {
            e.refs += 1
            e.stopWork?.cancel()
            e.stopWork = nil
            entries[key] = e
            return e.stream
        }
        if let old = entries[key] { old.stream.stop() }
        let s = LiveStream(key: key, url: url, credentials: credentials, title: title)
        entries[key] = Entry(stream: s, refs: 1, stopWork: nil)
        if !isSuspended { s.start() }
        return s
    }

    public func release(_ stream: LiveStream, linger: TimeInterval = 4) {
        guard var e = entries[stream.key], e.stream === stream else { return }
        e.refs -= 1
        if e.refs <= 0 {
            let key = stream.key
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let cur = self.entries[key], cur.refs <= 0 else { return }
                    cur.stream.stop()
                    self.entries[key] = nil
                }
            }
            e.stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
        }
        entries[stream.key] = e
    }

    public func existing(key: String) -> LiveStream? { entries[key]?.stream }

    /// Stops network activity while nothing is visible (window hidden, screen locked).
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for e in entries.values where !e.stream.status.isRecording { e.stream.stop() }
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for e in entries.values where e.refs > 0 { e.stream.start() }
    }

    public func stopAll() {
        for e in entries.values { e.stream.stop() }
        entries.removeAll()
    }

    public func restart(keysWithPrefix prefix: String) {
        for (k, e) in entries where k.hasPrefix(prefix) {
            e.stream.stop()
            entries[k] = nil
        }
    }

    public var activeCount: Int { entries.values.filter { $0.refs > 0 }.count }
    /// Streams currently held by at least one viewer (diagnostics / self-test).
    public var activeStreams: [LiveStream] { entries.values.filter { $0.refs > 0 }.map(\.stream) }
    public var allStreams: [LiveStream] { entries.values.map(\.stream) }
}
