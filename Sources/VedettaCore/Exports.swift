import Foundation
import Observation
import CoreMedia
import RTSPKit
import MediaKit
import VedettaL10n

public struct ExportRecord: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled }
    public var id: UUID
    public var deviceID: UUID
    public var channelID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var fileURL: URL
    public var state: State
    public var progress: Double
    public var bytes: Int64
    public var message: String?
    public var createdAt: Date
    /// nil (older queues) = with audio.
    public var includeAudio: Bool?
}

/// Downloads NVR recordings to local MP4 files (no re-encoding), with a persistent queue.
@MainActor
@Observable
public final class ExportManager {
    public private(set) var jobs: [ExportRecord] = []
    public var maxConcurrent = 2
    @ObservationIgnored private var running: [UUID: ReplayStream] = [:]
    @ObservationIgnored private var boxes: [UUID: ExportBox] = [:]
    @ObservationIgnored private let store = JSONStore<[ExportRecord]>(filename: "exports.json")
    @ObservationIgnored public var deviceLookup: ((UUID) -> Device?)?
    @ObservationIgnored public var onCompleted: ((ExportRecord) -> Void)?
    @ObservationIgnored private var watchdog: Timer?

    public init() {
        jobs = (store.load() ?? []).map { r in
            var r = r
            if r.state == .running || r.state == .queued { r.state = .queued; r.progress = 0 }
            return r
        }
    }

    public var activeCount: Int { jobs.filter { $0.state == .running || $0.state == .queued }.count }

    nonisolated public static func fileName(device: Device, channel: Channel, start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        f.calendar = Calendar(identifier: .gregorian)
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.dateFormat = "HH.mm.ss"
        let raw = "\(channel.name) \(f.string(from: start))–\(g.string(from: end)).mp4"
        return raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    @discardableResult
    public func enqueue(device: Device, channel: Channel, start: Date, end: Date, folder: URL, includeAudio: Bool = true) -> ExportRecord {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent(Self.fileName(device: device, channel: channel, start: start, end: end))
        // " (2)", " (3)"… after the original name (which may itself contain parentheses).
        let base = first.deletingPathExtension().lastPathComponent
        var url = first
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || jobs.contains(where: { $0.fileURL == url && $0.state != .failed }) {
            url = folder.appendingPathComponent(base + " (\(n)).mp4")
            n += 1
        }
        let rec = ExportRecord(id: UUID(), deviceID: device.id, channelID: channel.id,
                               title: "\(channel.name) · \(device.name)", start: start, end: end, fileURL: url,
                               state: .queued, progress: 0, bytes: 0, message: nil, createdAt: Date(), includeAudio: includeAudio)
        jobs.insert(rec, at: 0)
        persist()
        pump()
        return rec
    }

    public func cancel(_ id: UUID) {
        if running[id] != nil {
            finish(id: id, success: false, message: L("Cancelled"), cancelled: true)
        } else {
            update(id) { $0.state = .cancelled; $0.message = L("Cancelled") }
            pump()
        }
    }

    /// Interrupts the running exports of a device (sign out): they can be retried later.
    public func interrupt(deviceID: UUID, message: String) {
        for job in jobs where job.deviceID == deviceID && job.state == .running {
            finish(id: job.id, success: false, message: message)
        }
    }

    /// false while a device is offline, refused, locked or signed out (its exports wait).
    public var canRun: ((UUID) -> Bool)?

    public func retry(_ id: UUID) {
        update(id) { $0.state = .queued; $0.progress = 0; $0.message = nil; $0.bytes = 0 }
        pump()
    }

    public func remove(_ id: UUID) {
        if running[id] != nil { cancel(id) }
        jobs.removeAll { $0.id == id }
        persist()
    }

    public func clearFinished() {
        jobs.removeAll { $0.state == .completed || $0.state == .cancelled }
        persist()
    }

    private func update(_ id: UUID, _ body: (inout ExportRecord) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[i])
        persist()
    }

    private func persist() { store.save(jobs) }

    public func pump() {
        let runningCount = jobs.filter { $0.state == .running }.count
        guard runningCount < maxConcurrent else { return }
        // Oldest queued first, only for devices Vedetta may connect to right now.
        guard let next = jobs.last(where: { $0.state == .queued && (canRun?($0.deviceID) ?? true) }) else { return }
        start(next)
        pump()
    }

    /// Per-job state shared between the main actor and the replay queue.
    final class ExportBox: @unchecked Sendable {
        var recorder: MP4Recorder?
        var bytes: Int64 = 0
        var lastReport = 0.0
        var done = false
        var lastAbs: Double = 0
        private let lock = NSLock()
        private var _lastDataAt = Date()
        var lastDataAt: Date {
            get { lock.withLock { _lastDataAt } }
            set { lock.withLock { _lastDataAt = newValue } }
        }
    }

    private func start(_ job: ExportRecord) {
        guard let device = deviceLookup?(job.deviceID),
              let channel = device.channels.first(where: { $0.id == job.channelID }) else {
            update(job.id) { $0.state = .failed; $0.message = L("Device no longer available") }
            return
        }
        update(job.id) { $0.state = .running; $0.message = L("Connecting to the recorder…") }
        let id = job.id
        let (jStart, jEnd) = (job.start, job.end)
        let rs = ReplayStream(channel: channel, credentials: device.credentials, start: job.start, end: job.end,
                              accessGuard: DeviceClients.shared.accessGuard(for: device)) {
            try await PlaybackBackend.replayTargets(device: device, channel: channel, from: jStart, to: jEnd, export: true)
        }
        let total = max(1, job.end.timeIntervalSince(job.start))
        let jobStart = job.start.timeIntervalSince1970
        let jobEnd = job.end.timeIntervalSince1970
        let box = ExportBox()
        let url = job.fileURL
        let withAudio = job.includeAudio ?? true
        // All recorder calls happen on the replay queue (AVAssetWriter is not thread-safe).
        rs.onAccessUnit = { [weak self] au, abs, format, audioInfo in
            guard !box.done else { return }
            box.lastDataAt = Date()
            if box.recorder == nil {
                guard au.isKeyframe else { return }
                do {
                    box.recorder = try MP4Recorder(url: url, videoFormat: format, audio: withAudio ? audioInfo : nil, realTime: false)
                } catch {
                    box.done = true
                    DispatchQueue.main.async { self?.finish(id: id, success: false, message: error.localizedDescription) }
                    return
                }
            }
            guard abs <= jobEnd + 0.5 else {
                box.done = true
                DispatchQueue.main.async { self?.finish(id: id, success: true, message: nil) }
                return
            }
            box.recorder?.appendVideo(au, time: abs)
            box.bytes += Int64(au.byteCount)
            box.lastAbs = abs
            let p = min(1, max(0, (abs - jobStart) / total))
            if p - box.lastReport >= 0.005 {
                box.lastReport = p
                let bytes = box.bytes
                DispatchQueue.main.async {
                    self?.update(id) { $0.progress = p; $0.bytes = bytes; $0.message = nil }
                }
            }
        }
        if withAudio {
            rs.onAudioFrame = { au, abs, _ in
                guard !box.done, abs <= jobEnd else { return }
                box.recorder?.appendAudio(au, time: abs)
            }
        }
        rs.onEnded = { [weak self] err in
            guard !box.done else { return }
            box.done = true
            let hasData = box.recorder != nil
            let partial = hasData && box.lastAbs < jobEnd - 5
            let reached = box.lastAbs
            DispatchQueue.main.async {
                guard let self else { return }
                if !hasData {
                    self.finish(id: id, success: false, message: err?.localizedDescription ?? L("No recordings in the range"))
                } else {
                    self.finish(id: id, success: true, message: partial ? Self.partialMessage(reached) : nil)
                }
            }
        }
        running[id] = rs
        boxes[id] = box
        rs.begin()
        startWatchdog()
    }

    static func partialMessage(_ abs: Double) -> String {
        L("Recordings available until %@: the file contains the part that was found.", DateFormatter.localizedString(from: Date(timeIntervalSince1970: abs), dateStyle: .none, timeStyle: .medium))
    }

    /// Ends a job. The recorder is finalised (or discarded) on the replay queue after the stream stops.
    private func finish(id: UUID, success: Bool, message: String?, cancelled: Bool = false) {
        guard let rs = running.removeValue(forKey: id), let box = boxes.removeValue(forKey: id) else { return }
        if !cancelled { update(id) { $0.message = L("Finalizing the file…") } }
        rs.stop { [weak self] in
            box.done = true
            let complete: @Sendable (Bool, String?) -> Void = { ok, msg in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if cancelled {
                        self.update(id) { $0.state = .cancelled; $0.message = L("Cancelled") }
                    } else if ok {
                        self.update(id) { $0.state = .completed; $0.progress = 1; $0.message = msg }
                        if let r = self.jobs.first(where: { $0.id == id }) { self.onCompleted?(r) }
                    } else {
                        self.update(id) { $0.state = .failed; $0.message = msg ?? L("Export failed") }
                    }
                    self.pump()
                }
            }
            guard let recorder = box.recorder else { complete(false, message); return }
            let url = recorder.url
            recorder.finish { written, err in
                if success && !cancelled && written != nil {
                    complete(true, message)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    complete(false, message ?? err?.localizedDescription)
                }
            }
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                for (id, box) in self.boxes where now.timeIntervalSince(box.lastDataAt) > 45 {
                    // No data for a while: keep what was downloaded, if anything.
                    let hasData = box.recorder != nil
                    self.finish(id: id, success: hasData,
                                message: hasData ? Self.partialMessage(box.lastAbs) : L("The recorder did not send any data"))
                }
                if self.running.isEmpty { self.watchdog?.invalidate(); self.watchdog = nil }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }
}
