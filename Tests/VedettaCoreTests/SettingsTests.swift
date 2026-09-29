import Testing
import Foundation
@testable import VedettaCore

/// Settings must survive app updates: older/newer files are read field by field, never thrown away.
@Suite struct SettingsTests {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: Data(json.utf8))
    }

    @Test func settingsFromVersion1KeepTheirValues() throws {
        // A 1.0 file: no tileFit/tileLabels/exportAudio/timelineWheel, and the old "fillTiles" switch.
        let s = try decode(AppSettings.self, """
        {"snapshotsPath":"/tmp/snap","recordingsPath":"/tmp/rec","exportsPath":"/tmp/exp","tourIntervalSeconds":45,
         "liveQuality":"high","showStreamInfo":true,"keepInMenuBar":false,"lockWithTouchID":false,
         "notificationsEnabled":true,"playLiveAudio":false,"fillTiles":true,"confirmBeforeQuit":false}
        """)
        #expect(s.snapshotsPath == "/tmp/snap" && s.tourIntervalSeconds == 45 && s.liveQuality == .high && !s.keepInMenuBar)
        #expect(s.tileFit == .fill)                 // migrated from fillTiles
        #expect(s.tileLabels == .always && s.exportAudio && s.timelineWheel == .zoom)
    }

    @Test func unknownOrBrokenFieldsFallBackOneByOne() throws {
        let s = try decode(AppSettings.self, """
        {"tourIntervalSeconds":"soon","liveQuality":"ultra","showStreamInfo":true,"futureOption":42}
        """)
        #expect(s.tourIntervalSeconds == AppSettings.defaults.tourIntervalSeconds)   // wrong type → default
        #expect(s.liveQuality == .auto)                                             // unknown value → default
        #expect(s.showStreamInfo)                                                   // the rest is kept
    }

    @Test func roundTrip() throws {
        var s = AppSettings.defaults
        s.tileFit = .stretch; s.tileLabels = .never; s.exportAudio = false; s.timelineWheel = .scroll
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)
    }

    @Test func aDamagedChannelDoesNotLoseTheDevice() throws {
        let id = UUID()
        let d = try decode(Device.self, """
        {"id":"\(id)","kind":"vigiNVR","name":"NVR","host":"192.168.1.100","httpPort":443,"rtspPort":554,"username":"viewer",
         "addedAt":"2026-09-29T10:00:00Z","channels":[
           {"id":"\(id)-1","deviceID":"\(id)","number":1,"name":"Entrance","isOnline":true,"isHidden":false,"supportsPlayback":true},
           {"id":"broken"},
           {"deviceID":"\(id)","number":3,"name":"Garage"}]}
        """)
        #expect(d.channels.map(\.name) == ["Entrance", "Garage"])
        #expect(d.channels[1].isOnline && !d.channels[1].isHidden)   // missing fields get their defaults
    }

    @Test func unreadableFileIsSetAsideAndTheBackupUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vedetta-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("layout.json")
        let store = JSONStore<LiveLayout>(url: url)
        var l = LiveLayout(); l.grid = .nine; l.slots = ["a", nil, "b"]
        store.save(l)
        JSONStore<LiveLayout>.flushAll()
        var l2 = l; l2.page = 1
        JSONStore<LiveLayout>(url: url).save(l2)          // next launch: the previous file is kept as .bak
        JSONStore<LiveLayout>.flushAll()
        #expect(store.load() == l2)
        try Data("{ damaged".utf8).write(to: url)
        #expect(JSONStore<LiveLayout>(url: url).load() == l)            // recovered from the backup
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        #expect(aside.count == 1)                                        // the damaged file is kept for inspection
    }

    @Test func backupContainsEverythingButPasswords() throws {
        var d = Device(kind: .vigiNVR, name: "NVR", host: "10.0.0.2", httpPort: 443, rtspPort: 554, username: "viewer")
        d.channels = [Channel(deviceID: d.id, number: 1, name: "Entrance")]
        var layout = LiveLayout(); layout.slots = [d.channels[0].id]
        let b = SettingsBackup(appVersion: "1.0.0", settings: .defaults, layout: layout, devices: [d], language: "it")
        let data = try b.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.lowercased().contains("password"))
        let back = try SettingsBackup.decode(data)
        #expect(back.devices.map(\.id) == [d.id] && back.devices[0].channels == d.channels && back.devices[0].username == "viewer")
        #expect(back.layout == layout && back.language == "it")
        #expect(throws: (any Error).self) { try SettingsBackup.decode(Data(#"{"format":"other","version":1}"#.utf8)) }
    }

    @Test func exportQueueFromVersion1KeepsAudio() throws {
        let r = try decode(ExportRecord.self, """
        {"id":"\(UUID())","deviceID":"\(UUID())","channelID":"x","title":"t","start":"2026-09-29T10:00:00Z",
         "end":"2026-09-29T10:01:00Z","fileURL":"file:///tmp/a.mp4","state":"queued","progress":0,"bytes":0,
         "createdAt":"2026-09-29T10:00:00Z"}
        """)
        #expect(r.includeAudio == nil)                   // nil = with audio, as before
    }
}
