import Foundation
import VedettaL10n
import NetKit

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case vigiNVR
    case onvifNVR
    case rtspRecorder
    case onvifCamera
    case rtspCamera

    public var label: String {
        switch self {
        case .vigiNVR: return L("VIGI recorder (TP-Link)")
        case .onvifNVR: return L("ONVIF recorder")
        case .rtspRecorder: return L("RTSP recorder")
        case .onvifCamera: return L("ONVIF camera")
        case .rtspCamera: return L("RTSP camera")
        }
    }

    public var symbol: String {
        switch self {
        case .vigiNVR, .onvifNVR, .rtspRecorder: return "externaldrive.connected.to.line.below"
        case .onvifCamera: return "video"
        case .rtspCamera: return "video.badge.ellipsis"
        }
    }

    public var isRecorder: Bool { self == .vigiNVR || self == .onvifNVR || self == .rtspRecorder }
}

/// RTSP URL layouts of common NVR brands (used when ONVIF is off or lacks recording search).
public enum RecorderBrand: String, Codable, Sendable, CaseIterable, Identifiable {
    case hikvision, dahua, reolink, uniview, vigi

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .hikvision: return "Hikvision / HiLook / Annke"
        case .dahua: return "Dahua / Imou / Amcrest"
        case .reolink: return "Reolink"
        case .uniview: return "Uniview (UNV)"
        case .vigi: return "TP-Link VIGI"
        }
    }

    public func liveURL(host: String, channel: Int, main: Bool) -> String {
        switch self {
        case .hikvision: return "rtsp://\(host)/Streaming/Channels/\(channel)0\(main ? 1 : 2)"
        case .dahua: return "rtsp://\(host)/cam/realmonitor?channel=\(channel)&subtype=\(main ? 0 : 1)"
        case .reolink: return "rtsp://\(host)/h264Preview_\(String(format: "%02d", channel))_\(main ? "main" : "sub")"
        case .uniview: return "rtsp://\(host)/unicast/c\(channel)/s\(main ? 0 : 1)/live"
        case .vigi: return "rtsp://\(host)/live/\(channel)/\(main ? 1 : 2)/avm"
        }
    }

    /// Playback URL for brands with a documented RTSP replay syntax (times in the recorder's local time).
    public func replayURL(host: String, channel: Int, from: Date, to: Date) -> String? {
        let cal = Calendar.current
        func c(_ d: Date) -> DateComponents { cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d) }
        switch self {
        case .hikvision:
            func f(_ d: Date) -> String { let x = c(d); return String(format: "%04d%02d%02dT%02d%02d%02dZ", x.year!, x.month!, x.day!, x.hour!, x.minute!, x.second!) }
            return "rtsp://\(host)/Streaming/tracks/\(channel)01?starttime=\(f(from))&endtime=\(f(to))"
        case .dahua:
            func f(_ d: Date) -> String { let x = c(d); return String(format: "%04d_%02d_%02d_%02d_%02d_%02d", x.year!, x.month!, x.day!, x.hour!, x.minute!, x.second!) }
            return "rtsp://\(host)/cam/playback?channel=\(channel)&starttime=\(f(from))&endtime=\(f(to))"
        case .vigi:
            return nil
        case .reolink, .uniview:
            return nil
        }
    }

    public var supportsReplay: Bool { self == .hikvision || self == .dahua }

    /// Best guess from a model/manufacturer string (ONVIF device info or discovery name).
    public static func guess(from text: String) -> RecorderBrand? {
        let t = text.lowercased()
        if t.contains("vigi") || t.contains("tp-link") { return .vigi }
        if t.contains("hikvision") || t.contains("hilook") || t.hasPrefix("ds-") || t.contains(" ds-") || t.contains("annke") { return .hikvision }
        if t.contains("dahua") || t.contains("imou") || t.contains("amcrest") || t.hasPrefix("dh-") || t.contains("nvr4") || t.contains("nvr5") { return .dahua }
        if t.contains("reolink") || t.contains("rln") { return .reolink }
        if t.contains("uniview") || t.contains("unv") { return .uniview }
        return nil
    }
}

public enum StreamQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, high, low
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return L("Automatic")
        case .high: return L("High")
        case .low: return L("Low")
        }
    }
}

public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var deviceID: UUID
    /// NVR channel number (1-based) or index of the video source for cameras.
    public var number: Int
    public var name: String
    public var mainURL: String?
    public var subURL: String?
    /// ONVIF profile token used for PTZ commands (nil = no PTZ).
    public var ptzProfile: String?
    public var isOnline: Bool = true
    public var isHidden: Bool = false
    public var supportsPlayback: Bool = false
    /// ONVIF video source token (to match recordings to channels).
    public var sourceToken: String?
    /// ONVIF Profile G recording token for this channel.
    public var recordingToken: String?

    public init(deviceID: UUID, number: Int, name: String) {
        self.id = "\(deviceID.uuidString)-\(number)"
        self.deviceID = deviceID
        self.number = number
        self.name = name
    }

    public var hasPTZ: Bool { ptzProfile != nil }

    /// True for automatically generated names ("Channel 3", "Canale 3", "Canal 3"), in any language.
    public static func isDefaultName(_ name: String, number: Int) -> Bool {
        ["Channel", "Canale", "Canal"].contains { name == "\($0) \(number)" } || name == L("Channel %@", String(number))
    }
}

public struct Device: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DeviceKind
    public var name: String
    public var host: String
    /// NVR API port (HTTPS) or ONVIF HTTP port.
    public var httpPort: Int
    public var rtspPort: Int
    public var onvifURL: String?
    public var username: String
    public var model: String?
    public var firmware: String?
    public var channels: [Channel]
    public var addedAt: Date
    /// "z" (UTC) or "l" (local) for VIGI replay URLs; learned at runtime.
    public var replayTimeSuffix: String?
    /// URL layout used for RTSP recorders (and as playback fallback for ONVIF recorders).
    public var brand: RecorderBrand?

    public init(id: UUID = UUID(), kind: DeviceKind, name: String, host: String, httpPort: Int, rtspPort: Int,
                username: String, channels: [Channel] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.username = username
        self.channels = channels
        self.addedAt = Date()
    }

    public var visibleChannels: [Channel] { channels.filter { !$0.isHidden } }
    public var supportsPlayback: Bool { channels.contains(where: \.supportsPlayback) }
}

public enum GridKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case one, four, six, eight, nine, sixteen

    public var id: String { rawValue }
    public var capacity: Int {
        switch self {
        case .one: return 1
        case .four: return 4
        case .six: return 6
        case .eight: return 8
        case .nine: return 9
        case .sixteen: return 16
        }
    }
    public var label: String {
        switch self {
        case .one: return L("1 tile")
        case .four: return L("4 tiles")
        case .six: return L("6 tiles (1+5)")
        case .eight: return L("8 tiles (1+7)")
        case .nine: return L("9 tiles")
        case .sixteen: return L("16 tiles")
        }
    }
    public var symbol: String {
        switch self {
        case .one: return "rectangle"
        case .four: return "square.grid.2x2"
        case .six: return "rectangle.grid.1x2"
        case .eight: return "rectangle.split.3x3"
        case .nine: return "square.grid.3x3"
        case .sixteen: return "square.grid.4x3.fill"
        }
    }

    /// Tile frames in unit coordinates (0...1).
    public var frames: [CGRect] {
        func grid(_ n: Int) -> [CGRect] {
            let s = 1.0 / Double(n)
            return (0..<(n * n)).map { i in CGRect(x: Double(i % n) * s, y: Double(i / n) * s, width: s, height: s) }
        }
        switch self {
        case .one: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .four: return grid(2)
        case .nine: return grid(3)
        case .sixteen: return grid(4)
        case .six:
            let s = 1.0 / 3.0
            var r = [CGRect(x: 0, y: 0, width: 2 * s, height: 2 * s)]
            r.append(CGRect(x: 2 * s, y: 0, width: s, height: s))
            r.append(CGRect(x: 2 * s, y: s, width: s, height: s))
            for i in 0..<3 { r.append(CGRect(x: Double(i) * s, y: 2 * s, width: s, height: s)) }
            return r
        case .eight:
            let s = 0.25
            var r = [CGRect(x: 0, y: 0, width: 3 * s, height: 3 * s)]
            for i in 0..<3 { r.append(CGRect(x: 3 * s, y: Double(i) * s, width: s, height: s)) }
            for i in 0..<4 { r.append(CGRect(x: Double(i) * s, y: 3 * s, width: s, height: s)) }
            return r
        }
    }

    public static func fitting(_ count: Int) -> GridKind {
        switch count {
        case ...1: return .one
        case 2...4: return .four
        case 5...6: return .six
        case 7...8: return .eight
        case 9: return .nine
        default: return .sixteen
        }
    }
}

/// How a video fits its tile.
public enum TileFit: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Whole picture, black bars when the shapes differ.
    case fit
    /// Fills the tile, cropping the edges (may hide the camera's clock).
    case fill
    /// Fills the tile without cropping, stretching the picture (e.g. 4:3 sub-streams in 16:9 tiles).
    case stretch
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fit: return L("Whole picture (black bars)")
        case .fill: return L("Fill (crop the edges)")
        case .stretch: return L("Stretch (no cropping)")
        }
    }
}

/// When the camera name is shown on live tiles.
public enum TileLabelMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case always, hover, never
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .always: return L("Always")
        case .hover: return L("When the pointer is over the tile")
        case .never: return L("Never")
        }
    }
}

/// What the mouse wheel does over the recordings timeline.
public enum TimelineWheel: String, Codable, Sendable, CaseIterable, Identifiable {
    case zoom, scroll
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .zoom: return L("Zoom (Shift + wheel scrolls)")
        case .scroll: return L("Scroll (⌘ + wheel zooms)")
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var snapshotsPath: String
    public var recordingsPath: String
    public var exportsPath: String
    public var tourIntervalSeconds: Int = 30
    public var liveQuality: StreamQuality = .auto
    public var showStreamInfo: Bool = false
    public var keepInMenuBar: Bool = true
    public var lockWithTouchID: Bool = false
    public var notificationsEnabled: Bool = true
    public var playLiveAudio: Bool = false
    public var tileFit: TileFit = .fit
    public var tileLabels: TileLabelMode = .always
    public var confirmBeforeQuit: Bool = false
    /// Include the audio track when saving recordings from the recorder.
    public var exportAudio: Bool = true
    public var timelineWheel: TimelineWheel = .zoom

    public static var defaults: AppSettings {
        // Test runs keep their media inside the isolated support folder, never in ~/Movies or ~/Pictures.
        let devMedia = AppPaths.isIsolated ? AppPaths.supportDirectory.appendingPathComponent("Media", isDirectory: true) : nil
        let movies = devMedia ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Vedetta", isDirectory: true)
        let pictures = devMedia?.appendingPathComponent("Snapshots") ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Vedetta", isDirectory: true)
        return AppSettings(snapshotsPath: pictures.path,
                           recordingsPath: movies.appendingPathComponent(L("Recordings")).path,
                           exportsPath: movies.appendingPathComponent(L("Exports")).path)
    }

    public var snapshotsURL: URL { URL(fileURLWithPath: snapshotsPath, isDirectory: true) }
    public var recordingsURL: URL { URL(fileURLWithPath: recordingsPath, isDirectory: true) }
    public var exportsURL: URL { URL(fileURLWithPath: exportsPath, isDirectory: true) }
}

public struct LiveLayout: Codable, Sendable, Equatable {
    public var grid: GridKind = .four
    /// Channel IDs per tile across pages (page size = grid capacity).
    public var slots: [String?] = []
    public var page: Int = 0
    public init() {}
}

// MARK: - Tolerant decoding
// Settings files written by older or newer versions must never be discarded: every field falls back to its
// default when missing or unreadable, instead of making the whole file unreadable.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case snapshotsPath, recordingsPath, exportsPath, tourIntervalSeconds, liveQuality, showStreamInfo, keepInMenuBar,
             lockWithTouchID, notificationsEnabled, playLiveAudio, tileFit, tileLabels, confirmBeforeQuit, exportAudio,
             timelineWheel, fillTiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        self = d
        snapshotsPath = c.value(.snapshotsPath, d.snapshotsPath)
        recordingsPath = c.value(.recordingsPath, d.recordingsPath)
        exportsPath = c.value(.exportsPath, d.exportsPath)
        tourIntervalSeconds = c.value(.tourIntervalSeconds, d.tourIntervalSeconds)
        liveQuality = c.value(.liveQuality, d.liveQuality)
        showStreamInfo = c.value(.showStreamInfo, d.showStreamInfo)
        keepInMenuBar = c.value(.keepInMenuBar, d.keepInMenuBar)
        lockWithTouchID = c.value(.lockWithTouchID, d.lockWithTouchID)
        notificationsEnabled = c.value(.notificationsEnabled, d.notificationsEnabled)
        playLiveAudio = c.value(.playLiveAudio, d.playLiveAudio)
        // 1.0 files had a "fill the tiles" switch.
        tileFit = c.value(.tileFit, c.value(.fillTiles, false) ? TileFit.fill : d.tileFit)
        tileLabels = c.value(.tileLabels, d.tileLabels)
        confirmBeforeQuit = c.value(.confirmBeforeQuit, d.confirmBeforeQuit)
        exportAudio = c.value(.exportAudio, d.exportAudio)
        timelineWheel = c.value(.timelineWheel, d.timelineWheel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(snapshotsPath, forKey: .snapshotsPath)
        try c.encode(recordingsPath, forKey: .recordingsPath)
        try c.encode(exportsPath, forKey: .exportsPath)
        try c.encode(tourIntervalSeconds, forKey: .tourIntervalSeconds)
        try c.encode(liveQuality, forKey: .liveQuality)
        try c.encode(showStreamInfo, forKey: .showStreamInfo)
        try c.encode(keepInMenuBar, forKey: .keepInMenuBar)
        try c.encode(lockWithTouchID, forKey: .lockWithTouchID)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(playLiveAudio, forKey: .playLiveAudio)
        try c.encode(tileFit, forKey: .tileFit)
        try c.encode(tileLabels, forKey: .tileLabels)
        try c.encode(confirmBeforeQuit, forKey: .confirmBeforeQuit)
        try c.encode(exportAudio, forKey: .exportAudio)
        try c.encode(timelineWheel, forKey: .timelineWheel)
    }
}

extension LiveLayout {
    enum CodingKeys: String, CodingKey { case grid, slots, page }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        grid = c.value(.grid, .four)
        slots = c.value(.slots, [])
        page = c.value(.page, 0)
    }
}

extension Channel {
    enum CodingKeys: String, CodingKey {
        case id, deviceID, number, name, mainURL, subURL, ptzProfile, isOnline, isHidden, supportsPlayback, sourceToken, recordingToken
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try c.decode(UUID.self, forKey: .deviceID)
        let number = try c.decode(Int.self, forKey: .number)
        self.init(deviceID: deviceID, number: number, name: c.value(.name, L("Channel %@", String(number))))
        id = c.value(.id, id)
        mainURL = c.value(.mainURL, nil)
        subURL = c.value(.subURL, nil)
        ptzProfile = c.value(.ptzProfile, nil)
        isOnline = c.value(.isOnline, true)
        isHidden = c.value(.isHidden, false)
        supportsPlayback = c.value(.supportsPlayback, false)
        sourceToken = c.value(.sourceToken, nil)
        recordingToken = c.value(.recordingToken, nil)
    }
}

extension Device {
    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, httpPort, rtspPort, onvifURL, username, model, firmware, channels, addedAt, replayTimeSuffix, brand
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(DeviceKind.self, forKey: .kind)
        let host = try c.decode(String.self, forKey: .host)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: kind, name: c.value(.name, host), host: host,
                  httpPort: c.value(.httpPort, kind == .vigiNVR ? 443 : 80), rtspPort: c.value(.rtspPort, 554),
                  username: c.value(.username, ""))
        onvifURL = c.value(.onvifURL, nil)
        model = c.value(.model, nil)
        firmware = c.value(.firmware, nil)
        // A single unreadable channel must not lose the others.
        if var list = try? c.nestedUnkeyedContainer(forKey: .channels) {
            var out: [Channel] = []
            while !list.isAtEnd {
                if let ch = try? list.decode(Channel.self) { out.append(ch) } else { _ = try? list.decode(Skip.self) }
            }
            channels = out
        }
        addedAt = c.value(.addedAt, Date())
        replayTimeSuffix = c.value(.replayTimeSuffix, nil)
        brand = c.value(.brand, nil)
    }
}

/// Consumes one element of an unkeyed container that could not be decoded.
struct Skip: Decodable { init(from decoder: Decoder) throws {} }

/// Everything about the app and the devices, without passwords (they stay in the Keychain).
public struct SettingsBackup: Codable, Sendable {
    public static let formatID = "it.vedetta.settings"
    public var format = SettingsBackup.formatID
    public var version = 1
    public var appVersion: String
    public var exportedAt: Date
    public var settings: AppSettings
    public var layout: LiveLayout
    public var devices: [Device]
    public var language: String?

    public init(appVersion: String, settings: AppSettings, layout: LiveLayout, devices: [Device], language: String?) {
        self.appVersion = appVersion
        self.exportedAt = Date()
        self.settings = settings
        self.layout = layout
        self.devices = devices
        self.language = language
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SettingsBackup {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let b = try d.decode(SettingsBackup.self, from: data)
        guard b.format == formatID else { throw CocoaError(.fileReadCorruptFile) }
        return b
    }
}
