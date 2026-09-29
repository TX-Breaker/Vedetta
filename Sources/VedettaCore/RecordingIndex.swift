import Foundation
import Observation
import VigiKit
import ONVIFKit
import VedettaL10n

public struct TimelineSegment: Hashable, Sendable {
    public enum Kind: Int, Sendable { case continuous = 1, event = 2, alarm = 3 }
    public var start: Date
    public var end: Date
    public var kind: Kind
}

public struct TimelineEvent: Hashable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    public var type: Int
    public var channelID: String
    public var id: String { "\(channelID)-\(start.timeIntervalSince1970)-\(type)" }
    public var info: EventType { EventType(code: type) }
}

/// Human-readable VIGI event types.
public struct EventType: Hashable, Sendable {
    public let code: Int
    public init(code: Int) { self.code = code }

    public enum Family: String, CaseIterable, Sendable, Identifiable {
        case motion, person, vehicle, line, area, other
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .motion: return L("Motion")
            case .person: return L("People")
            case .vehicle: return L("Vehicles")
            case .line: return L("Lines and intrusions")
            case .area: return L("Areas")
            case .other: return L("Other events")
            }
        }
        public var symbol: String {
            switch self {
            case .motion: return "figure.walk.motion"
            case .person: return "person.fill"
            case .vehicle: return "car.fill"
            case .line: return "line.diagonal.arrow"
            case .area: return "square.dashed"
            case .other: return "exclamationmark.triangle.fill"
            }
        }
    }

    public var name: String {
        switch code {
        case 1: return L("Motion")
        case 3: return L("Line crossing")
        case 4: return L("Intrusion")
        case 5: return L("Motion (person)")
        case 6: return L("Line crossing (person)")
        case 7: return L("Intrusion (person)")
        case 8: return L("Motion (vehicle)")
        case 9: return L("Line crossing (vehicle)")
        case 10: return L("Intrusion (vehicle)")
        case 12: return L("Person")
        case 13: return L("Vehicle")
        case 14: return L("Area entering")
        case 15: return L("Area entering (person)")
        case 16: return L("Area entering (vehicle)")
        case 17: return L("Area exiting")
        case 18: return L("Area exiting (person)")
        case 19: return L("Area exiting (vehicle)")
        case 20: return L("Abandoned object")
        case 21: return L("Loitering")
        case 22: return L("Loitering (person)")
        case 23: return L("Loitering (vehicle)")
        case 24: return L("Scene change")
        case 25: return L("Abnormal sound")
        case 26: return L("Tampering")
        case 27: return L("Alarm input")
        case 28: return L("Queue (people)")
        case 29: return L("Queue")
        case 30: return L("Animal")
        case 36: return L("Tracking")
        default: return L("Event %@", String(code))
        }
    }

    public var family: Family {
        switch code {
        case 5, 7, 12, 15, 18, 22, 28: return .person
        case 8, 10, 13, 16, 19, 23: return .vehicle
        case 1: return .motion
        case 3, 4, 6, 9: return .line
        case 14, 17, 21, 20: return .area
        default: return .other
        }
    }
}

/// Loads which days have recordings, the recording segments of a day and its events.
@MainActor
@Observable
public final class RecordingIndex {
    public private(set) var recordedDays: Set<String> = []
    public private(set) var segments: [String: [TimelineSegment]] = [:]
    public private(set) var events: [String: [TimelineEvent]] = [:]
    public private(set) var isLoadingDay = false
    public private(set) var isLoadingMonth = false
    /// The recorder cannot list recording days (e.g. RTSP-only brands).
    public private(set) var daysUnknown = false
    /// Channels whose recorder cannot list recordings: playback works by choosing a time.
    public private(set) var unindexed: Set<String> = []
    public var error: String?

    @ObservationIgnored private var dayCache: [String: ([TimelineSegment], [TimelineEvent], Date, Bool)] = [:]
    @ObservationIgnored private var monthCache: [String: (Set<String>?, Date)] = [:]

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    public func loadMonth(device: Device, channels: [Channel], month: Date) async {
        guard device.supportsPlayback, !channels.isEmpty else { recordedDays = []; daysUnknown = false; return }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return }
        // Search a window around the month so neighbouring days in the calendar grid are marked too.
        let from = interval.start.addingTimeInterval(-7 * 86400)
        let to = min(Date(), interval.end.addingTimeInterval(7 * 86400))
        let key = "\(device.id)-\(channels.map(\.number).sorted())-\(Self.dayKey(interval.start))"
        if let cached = monthCache[key], Date().timeIntervalSince(cached.1) < 300 {
            recordedDays = cached.0 ?? []
            daysUnknown = cached.0 == nil
            return
        }
        isLoadingMonth = true
        defer { isLoadingMonth = false }
        do {
            let days = try await PlaybackBackend.recordedDays(device: device, channels: channels, from: from, to: to)
            monthCache[key] = (days, Date())
            recordedDays = days ?? []
            daysUnknown = days == nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            recordedDays = []
            daysUnknown = true
        }
    }

    public func loadDay(device: Device, channels: [Channel], day: Date, force: Bool = false) async {
        guard device.supportsPlayback else { segments = [:]; events = [:]; return }
        isLoadingDay = true
        defer { isLoadingDay = false }
        let cal = Calendar.current
        var newSegments: [String: [TimelineSegment]] = [:]
        var newEvents: [String: [TimelineEvent]] = [:]
        var newUnindexed = Set<String>()
        error = nil
        for ch in channels {
            let key = "\(ch.id)-\(Self.dayKey(day))"
            let isToday = cal.isDateInToday(day)
            if !force, let cached = dayCache[key], !isToday || Date().timeIntervalSince(cached.2) < 60 {
                newSegments[ch.id] = cached.0
                newEvents[ch.id] = cached.1
                if cached.3 == false { newUnindexed.insert(ch.id) }
                continue
            }
            do {
                let idx = try await PlaybackBackend.dayIndex(device: device, channel: ch, day: day)
                newSegments[ch.id] = Self.merge(idx.segments)
                newEvents[ch.id] = idx.events
                if !idx.indexed { newUnindexed.insert(ch.id) }
                dayCache[key] = (newSegments[ch.id]!, idx.events, Date(), idx.indexed)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                newSegments[ch.id] = []
                newEvents[ch.id] = []
            }
        }
        // Keep entries of other devices (the Events view loads several recorders).
        for (k, v) in newSegments { segments[k] = v }
        for (k, v) in newEvents { events[k] = v }
        let ids = Set(channels.map(\.id))
        unindexed = unindexed.subtracting(ids).union(newUnindexed)
        segments = segments.filter { ids.contains($0.key) || !isChannel($0.key, of: device) }
        events = events.filter { ids.contains($0.key) || !isChannel($0.key, of: device) }
    }

    private func isChannel(_ channelID: String, of device: Device) -> Bool {
        channelID.hasPrefix(device.id.uuidString)
    }

    /// Merges touching segments of the same kind to keep the timeline light.
    static func merge(_ segs: [TimelineSegment]) -> [TimelineSegment] {
        var out: [TimelineSegment] = []
        for s in segs.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.kind == s.kind, s.start.timeIntervalSince(last.end) <= 2 {
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    public func intervals(for channel: Channel) -> [DateInterval] {
        (segments[channel.id] ?? []).map { DateInterval(start: $0.start, end: $0.end) }
    }

    public func allEvents(for channels: [Channel]) -> [TimelineEvent] {
        channels.flatMap { events[$0.id] ?? [] }.sorted { $0.start < $1.start }
    }

    public func clearCache() {
        dayCache.removeAll()
        monthCache.removeAll()
    }
}
