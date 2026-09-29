import Foundation
import VedettaL10n

/// ONVIF Profile G: recording search and replay (works with NVRs of any brand that implement it).
public struct ONVIFRecording: Sendable, Codable, Hashable {
    public var token: String
    public var sourceID: String
    public var sourceName: String
    public var earliest: Date?
    public var latest: Date?

    public init(token: String, sourceID: String, sourceName: String, earliest: Date?, latest: Date?) {
        self.token = token; self.sourceID = sourceID; self.sourceName = sourceName
        self.earliest = earliest; self.latest = latest
    }
}

public struct ONVIFRecordingEvent: Sendable, Hashable {
    public var recordingToken: String
    public var time: Date
    public var topic: String
    /// Values of the SimpleItems in the event data (e.g. IsDataPresent, State, IsMotion).
    public var items: [String: String]
    public var isStartState: Bool

    /// true/false when the event describes data availability of a track/recording.
    public var dataPresent: Bool? {
        guard topic.contains("RecordingHistory") else { return nil }
        let v = items["IsDataPresent"] ?? items["State"] ?? items["IsRecording"]
        return v.map { $0.lowercased() == "true" || $0 == "1" }
    }

    /// true when a detection starts (motion, person, line crossing…).
    public var detectionActive: Bool? {
        guard !topic.contains("RecordingHistory") else { return nil }
        for key in ["State", "IsMotion", "IsInside", "IsTamper", "Active", "Value"] {
            if let v = items[key] { return v.lowercased() == "true" || v == "1" }
        }
        return nil
    }
}

extension ONVIFClient {
    static let nsSearch = "http://www.onvif.org/ver10/search/wsdl"
    static let nsReplay = "http://www.onvif.org/ver10/replay/wsdl"
    static let nsRecording = "http://www.onvif.org/ver10/recording/wsdl"

    public var searchServiceURL: URL? { services[Self.nsSearch] }
    public var replayServiceURL: URL? { services[Self.nsReplay] }

    /// Parses xs:dateTime values (with or without fractional seconds / time zone).
    public static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: t) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: t) { return d }
        // No time zone designator: assume UTC.
        if !t.hasSuffix("Z"), !t.contains("+"), t.count >= 19 { return parseDate(t + "Z") }
        return nil
    }

    static func xsDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    public func recordingSummary() async throws -> (from: Date?, until: Date?, count: Int) {
        if services.isEmpty { try await loadServices() }
        guard let url = searchServiceURL else { throw ONVIFError.unsupported(L("recording search")) }
        let body = try await soap("<GetRecordingSummary xmlns=\"\(Self.nsSearch)\"/>", to: url)
        let summary = body.first("Summary")
        return (summary?.child("DataFrom").flatMap { Self.parseDate($0.trimmedText) },
                summary?.child("DataUntil").flatMap { Self.parseDate($0.trimmedText) },
                Int(summary?.child("NumberRecordings")?.trimmedText ?? "") ?? 0)
    }

    public func findRecordings() async throws -> [ONVIFRecording] {
        if services.isEmpty { try await loadServices() }
        guard let url = searchServiceURL else { throw ONVIFError.unsupported(L("recording search")) }
        let start = try await soap("""
        <FindRecordings xmlns="\(Self.nsSearch)"><Scope/><MaxMatches>256</MaxMatches><KeepAliveTime>PT20S</KeepAliveTime></FindRecordings>
        """, to: url)
        guard let token = start.first("SearchToken")?.trimmedText else { throw ONVIFError.badResponse }
        var out: [String: ONVIFRecording] = [:]
        for _ in 0..<10 {
            let r = try await soap("""
            <GetRecordingSearchResults xmlns="\(Self.nsSearch)"><SearchToken>\(token.xmlEscaped)</SearchToken>\
            <MinResults>1</MinResults><MaxResults>256</MaxResults><WaitTime>PT5S</WaitTime></GetRecordingSearchResults>
            """, to: url)
            for info in r.descendants("RecordingInformation") {
                guard let tok = info.child("RecordingToken")?.trimmedText, !tok.isEmpty else { continue }
                let src = info.child("Source")
                out[tok] = ONVIFRecording(
                    token: tok,
                    sourceID: src?.child("SourceId")?.trimmedText ?? "",
                    sourceName: src?.child("Name")?.trimmedText ?? "",
                    earliest: info.child("EarliestRecording").flatMap { Self.parseDate($0.trimmedText) },
                    latest: info.child("LatestRecording").flatMap { Self.parseDate($0.trimmedText) })
            }
            let state = r.first("SearchState")?.trimmedText ?? "Completed"
            if state == "Completed" { break }
        }
        _ = try? await soap("<EndSearch xmlns=\"\(Self.nsSearch)\"><SearchToken>\(token.xmlEscaped)</SearchToken></EndSearch>", to: url)
        return out.values.sorted { $0.token.localizedStandardCompare($1.token) == .orderedAscending }
    }

    /// All events stored with a recording between two instants (data availability + detections).
    public func findEvents(recording: String, from: Date, to: Date, maxMatches: Int = 2000) async throws -> [ONVIFRecordingEvent] {
        if services.isEmpty { try await loadServices() }
        guard let url = searchServiceURL else { throw ONVIFError.unsupported(L("event search")) }
        let start = try await soap("""
        <FindEvents xmlns="\(Self.nsSearch)"><StartPoint>\(Self.xsDate(from))</StartPoint><EndPoint>\(Self.xsDate(to))</EndPoint>\
        <Scope><IncludedRecordings xmlns="\(Self.nsSchema)">\(recording.xmlEscaped)</IncludedRecordings></Scope>\
        <SearchFilter/><IncludeStartState>true</IncludeStartState><MaxMatches>\(maxMatches)</MaxMatches>\
        <KeepAliveTime>PT20S</KeepAliveTime></FindEvents>
        """, to: url)
        guard let token = start.first("SearchToken")?.trimmedText else { throw ONVIFError.badResponse }
        var events: [ONVIFRecordingEvent] = []
        for _ in 0..<40 {
            let r = try await soap("""
            <GetEventSearchResults xmlns="\(Self.nsSearch)"><SearchToken>\(token.xmlEscaped)</SearchToken>\
            <MinResults>1</MinResults><MaxResults>500</MaxResults><WaitTime>PT5S</WaitTime></GetEventSearchResults>
            """, to: url)
            for result in r.descendants("Result") {
                guard let time = result.child("Time").flatMap({ Self.parseDate($0.trimmedText) }) else { continue }
                let topic = result.first("Topic")?.trimmedText ?? ""
                var items: [String: String] = [:]
                for item in result.descendants("SimpleItem") {
                    if let n = item.attribute("Name"), let v = item.attribute("Value") { items[n] = v }
                }
                let startState = (result.child("StartStateEvent")?.trimmedText ?? "false").lowercased() == "true"
                events.append(ONVIFRecordingEvent(recordingToken: result.child("RecordingToken")?.trimmedText ?? recording,
                                                  time: time, topic: topic, items: items, isStartState: startState))
            }
            let state = r.first("SearchState")?.trimmedText ?? "Completed"
            if state == "Completed" || events.count >= maxMatches { break }
        }
        _ = try? await soap("<EndSearch xmlns=\"\(Self.nsSearch)\"><SearchToken>\(token.xmlEscaped)</SearchToken></EndSearch>", to: url)
        return events.sorted { $0.time < $1.time }
    }

    public func replayURI(recording: String) async throws -> URL {
        if services.isEmpty { try await loadServices() }
        guard let url = replayServiceURL else { throw ONVIFError.unsupported(L("playback")) }
        let body = try await soap("""
        <GetReplayUri xmlns="\(Self.nsReplay)"><StreamSetup><Stream xmlns="\(Self.nsSchema)">RTP-Unicast</Stream>\
        <Transport xmlns="\(Self.nsSchema)"><Protocol>RTSP</Protocol></Transport></StreamSetup>\
        <RecordingToken>\(recording.xmlEscaped)</RecordingToken></GetReplayUri>
        """, to: url)
        guard let text = body.first("Uri")?.trimmedText, var comps = URLComponents(string: text) else { throw ONVIFError.badResponse }
        comps.host = deviceURL.host
        comps.user = nil
        comps.password = nil
        guard let u = comps.url else { throw ONVIFError.badResponse }
        return u
    }

    /// Turns RecordingHistory data-present transitions into continuous intervals.
    public static func dataIntervals(from events: [ONVIFRecordingEvent], dayStart: Date, dayEnd: Date) -> [DateInterval] {
        var intervals: [DateInterval] = []
        var openedAt: Date?
        var sawHistory = false
        for e in events {
            guard let present = e.dataPresent else { continue }
            sawHistory = true
            if present {
                if openedAt == nil { openedAt = max(e.time, dayStart) }
            } else if let o = openedAt {
                let end = min(e.time, dayEnd)
                if end > o { intervals.append(DateInterval(start: o, end: end)) }
                openedAt = nil
            }
        }
        if let o = openedAt, dayEnd > o { intervals.append(DateInterval(start: o, end: min(dayEnd, Date()))) }
        return sawHistory ? intervals : []
    }

    /// Maps detection topics to VIGI-compatible event codes (so the UI treats all brands alike).
    public static func eventCode(forTopic topic: String, items: [String: String]) -> Int? {
        let t = topic.lowercased()
        let classes = (items["ClassTypes"] ?? items["Type"] ?? items["ObjectType"] ?? "").lowercased()
        if t.contains("human") || t.contains("people") || t.contains("person") || classes.contains("human") || classes.contains("person") { return 12 }
        if t.contains("vehicle") || classes.contains("vehicle") || classes.contains("car") { return 13 }
        if t.contains("linedetector") || t.contains("crossed") || t.contains("linecross") || t.contains("tripwire") { return 3 }
        if t.contains("fielddetector") || t.contains("intrusion") || t.contains("regionentr") { return 4 }
        if t.contains("tamper") || t.contains("globalscenechange") { return 26 }
        if t.contains("audio") && (t.contains("detect") || t.contains("alarm")) { return 25 }
        if t.contains("digitalinput") || t.contains("alarmin") { return 27 }
        if t.contains("motion") { return 1 }
        return nil
    }
}
