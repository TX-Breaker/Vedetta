import Foundation
import VigiKit
import ONVIFKit
import VedettaL10n

/// One way of opening a recording stream; several are tried in order until one works.
public struct ReplayTarget: Sendable {
    public var url: URL
    /// `Range` header for PLAY (nil = omit).
    public var range: String?
    /// Headers for every RTSP request (e.g. `Require: onvif-replay`).
    public var headers: [String: String] = [:]
    /// Extra headers for PLAY only (e.g. `Rate-Control: no` for fast exports).
    public var playHeaders: [String: String] = [:]
    /// Opaque tag reported back when this target works (VIGI time-zone suffix).
    public var tag: String?
}

/// Recordings of one channel on one day, in a brand-independent shape.
public struct DayIndex: Sendable {
    public var segments: [TimelineSegment]
    public var events: [TimelineEvent]
    /// false when the recorder cannot list its recordings (playback still works by picking a time).
    public var indexed: Bool
}

/// Brand-specific recording access behind a single interface (VIGI API, ONVIF Profile G, RTSP URL layouts).
@MainActor
public enum PlaybackBackend {

    // MARK: Calendar

    /// Days ("YYYYMMDD") with recordings, or nil when the recorder cannot tell.
    public static func recordedDays(device: Device, channels: [Channel], from: Date, to: Date) async throws -> Set<String>? {
        switch device.kind {
        case .vigiNVR:
            let client = DeviceClients.shared.vigi(for: device)
            var days = Set<String>()
            var lastError: Error?
            for ch in channels {
                do { days.formUnion(try await client.recordingDays(channel: ch.number, from: from, to: to)) }
                catch { lastError = error }
            }
            if days.isEmpty, let lastError { throw lastError }
            return days
        case .onvifNVR, .onvifCamera:
            guard channels.contains(where: { $0.recordingToken != nil }), let client = DeviceClients.shared.onvif(for: device) else { return nil }
            let tokens = Set(channels.compactMap(\.recordingToken))
            let recordings = try await client.findRecordings().filter { tokens.contains($0.token) }
            var days = Set<String>()
            let cal = Calendar.current
            for r in recordings {
                guard let e = r.earliest, let l = r.latest else { continue }
                var d = cal.startOfDay(for: max(e, from))
                let last = min(l, to)
                while d <= last {
                    days.insert(RecordingIndex.dayKey(d))
                    d = cal.date(byAdding: .day, value: 1, to: d)!
                }
            }
            return days
        case .rtspRecorder, .rtspCamera:
            return nil
        }
    }

    // MARK: Day timeline

    public static func dayIndex(device: Device, channel: Channel, day: Date) async throws -> DayIndex {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        switch device.kind {
        case .vigiNVR:
            let client = DeviceClients.shared.vigi(for: device)
            let recs = try await client.recordings(channel: channel.number, day: day)
            let segs = recs.map { r in
                TimelineSegment(start: max(r.start, dayStart), end: min(r.end, dayEnd),
                                kind: TimelineSegment.Kind(rawValue: r.videoType) ?? .continuous)
            }.filter { $0.end > $0.start }
            var evs: [TimelineEvent] = []
            if !segs.isEmpty {
                let raw = (try? await client.events(channel: channel.number, from: dayStart, to: dayEnd)) ?? []
                evs = raw.map { TimelineEvent(start: $0.start, end: $0.end, type: $0.eventType, channelID: channel.id) }
            }
            return DayIndex(segments: segs, events: evs, indexed: true)

        case .onvifNVR, .onvifCamera:
            guard let token = channel.recordingToken, let client = DeviceClients.shared.onvif(for: device) else {
                return DayIndex(segments: [], events: [], indexed: false)
            }
            let events = (try? await client.findEvents(recording: token, from: dayStart, to: dayEnd)) ?? []
            var intervals = ONVIFClient.dataIntervals(from: events, dayStart: dayStart, dayEnd: dayEnd)
            if intervals.isEmpty {
                // No RecordingHistory events: fall back to the recording's overall span.
                if let rec = try? await client.findRecordings().first(where: { $0.token == token }),
                   let e = rec.earliest, let l = rec.latest, l > dayStart, e < dayEnd {
                    intervals = [DateInterval(start: max(e, dayStart), end: min(l, dayEnd))]
                }
            }
            let segs = intervals.map { TimelineSegment(start: $0.start, end: $0.end, kind: .continuous) }
            return DayIndex(segments: segs, events: detections(events, channelID: channel.id), indexed: true)

        case .rtspRecorder, .rtspCamera:
            return DayIndex(segments: [], events: [], indexed: false)
        }
    }

    /// Pairs detection start/stop notifications into timeline events.
    public static func detections(_ events: [ONVIFRecordingEvent], channelID: String) -> [TimelineEvent] {
        var open: [String: (Date, Int)] = [:]
        var out: [TimelineEvent] = []
        for e in events {
            guard let active = e.detectionActive, let code = ONVIFClient.eventCode(forTopic: e.topic, items: e.items) else { continue }
            let key = e.topic
            if active {
                if open[key] == nil { open[key] = (e.time, code) }
            } else if let (start, c) = open.removeValue(forKey: key) {
                out.append(TimelineEvent(start: start, end: max(e.time, start.addingTimeInterval(1)), type: c, channelID: channelID))
            }
        }
        for (_, (start, c)) in open {
            out.append(TimelineEvent(start: start, end: start.addingTimeInterval(10), type: c, channelID: channelID))
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Replay

    public static func replayTargets(device: Device, channel: Channel, from: Date, to: Date, export: Bool) async throws -> [ReplayTarget] {
        let fast: [String: String] = ["Rate-Control": "no"]
        var targets: [ReplayTarget] = []
        switch device.kind {
        case .vigiNVR:
            let order = device.replayTimeSuffix.map { [$0] } ?? ["z", "l"]
            for suffix in order {
                guard let url = StreamURLs.replay(device: device, channel: channel, from: from, to: to, suffix: suffix) else { continue }
                if export { targets.append(ReplayTarget(url: url, playHeaders: fast, tag: suffix)) }
                targets.append(ReplayTarget(url: url, tag: suffix))
            }
        case .onvifNVR, .onvifCamera:
            if let token = channel.recordingToken, let client = DeviceClients.shared.onvif(for: device),
               let url = try? await client.replayURI(recording: token) {
                let range = "clock=\(onvifClock(from))-"
                let base = ReplayTarget(url: url, range: range, headers: ["Require": "onvif-replay"])
                if export { var t = base; t.playHeaders = fast; targets.append(t) }
                targets.append(base)
            }
            targets += brandTargets(device: device, channel: channel, from: from, to: to)
        case .rtspRecorder, .rtspCamera:
            targets += brandTargets(device: device, channel: channel, from: from, to: to)
        }
        guard !targets.isEmpty else { throw ConnectError.message(L("This device does not allow reviewing recordings.")) }
        return targets
    }

    static func brandTargets(device: Device, channel: Channel, from: Date, to: Date) -> [ReplayTarget] {
        guard let brand = device.brand, brand.supportsReplay else { return [] }
        let host = StreamURLs.hostPort(device)
        var out: [ReplayTarget] = []
        if let s = brand.replayURL(host: host, channel: channel.number, from: from, to: to), let u = URL(string: s) {
            out.append(ReplayTarget(url: u))
        }
        if brand == .hikvision {
            // Some firmware expects real UTC instead of local time.
            let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: from))
            if let s = brand.replayURL(host: host, channel: channel.number, from: from.addingTimeInterval(-offset), to: to.addingTimeInterval(-offset)),
               let u = URL(string: s) { out.append(ReplayTarget(url: u)) }
        }
        return out
    }

    static func onvifClock(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
