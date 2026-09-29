import Testing
import Foundation
@testable import VedettaCore
import ONVIFKit

@Suite struct RecorderTests {
    let dev = UUID()
    func ch(_ n: Int, src: String?) -> Channel { var c = Channel(deviceID: dev, number: n, name: "Canale \(n)"); c.sourceToken = src; return c }
    func rec(_ tok: String, _ src: String, _ name: String = "") -> ONVIFRecording {
        ONVIFRecording(token: tok, sourceID: src, sourceName: name, earliest: nil, latest: nil)
    }

    @Test func matchesBySourceToken() {
        let chans = [ch(1, src: "VideoSource_1"), ch(2, src: "VideoSource_2")]
        let m = DeviceConnector.matchRecordings([rec("B", "VideoSource_2"), rec("A", "VideoSource_1")], to: chans)
        #expect(m[chans[0].id] == "A")
        #expect(m[chans[1].id] == "B")
    }

    @Test func matchesByNumberThenOrder() {
        let chans = [ch(1, src: "vs-a"), ch(2, src: "vs-b"), ch(3, src: "vs-c")]
        let m = DeviceConnector.matchRecordings([rec("x", "", "Camera 03"), rec("y", "", "Camera 01"), rec("z", "", "Cortile")], to: chans)
        #expect(m[chans[2].id] == "x")
        #expect(m[chans[0].id] == "y")
        #expect(m[chans[1].id] == "z")
    }

    @Test func brandURLs() {
        let h = "10.0.0.5"
        #expect(RecorderBrand.hikvision.liveURL(host: h, channel: 3, main: true) == "rtsp://10.0.0.5/Streaming/Channels/301")
        #expect(RecorderBrand.hikvision.liveURL(host: h, channel: 3, main: false) == "rtsp://10.0.0.5/Streaming/Channels/302")
        #expect(RecorderBrand.dahua.liveURL(host: h, channel: 2, main: false) == "rtsp://10.0.0.5/cam/realmonitor?channel=2&subtype=1")
        #expect(RecorderBrand.reolink.liveURL(host: h, channel: 4, main: true) == "rtsp://10.0.0.5/h264Preview_04_main")
        #expect(RecorderBrand.uniview.liveURL(host: h, channel: 1, main: false) == "rtsp://10.0.0.5/unicast/c1/s1/live")
        #expect(RecorderBrand.vigi.liveURL(host: h, channel: 5, main: true) == "rtsp://10.0.0.5/live/5/1/avm")
        let from = Date(timeIntervalSince1970: 1_790_589_600)
        let dahua = RecorderBrand.dahua.replayURL(host: h, channel: 1, from: from, to: from.addingTimeInterval(60))!
        #expect(dahua.hasPrefix("rtsp://10.0.0.5/cam/playback?channel=1&starttime="))
        #expect(RecorderBrand.reolink.replayURL(host: h, channel: 1, from: from, to: from) == nil)
    }

    @Test func brandGuess() {
        #expect(RecorderBrand.guess(from: "Hikvision DS-7608NI-K2") == .hikvision)
        #expect(RecorderBrand.guess(from: "DS-7616NXI") == .hikvision)
        #expect(RecorderBrand.guess(from: "Dahua NVR4216-4KS2") == .dahua)
        #expect(RecorderBrand.guess(from: "Reolink RLN8-410") == .reolink)
        #expect(RecorderBrand.guess(from: "VIGI NVR2016H(UN)") == .vigi)
        #expect(RecorderBrand.guess(from: "Axis Q1615") == nil)
    }

    @Test func oldDeviceFilesStillDecode() throws {
        // devices.json written by version 1.0 (no brand / sourceToken / recordingToken fields).
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","kind":"vigiNVR","name":"NVR","host":"192.168.1.100","httpPort":443,"rtspPort":554,
          "username":"admin","addedAt":"2026-09-28T22:50:54Z","channels":[{"id":"11111111-2222-3333-4444-555555555555-1",
          "deviceID":"11111111-2222-3333-4444-555555555555","number":1,"name":"Entrance","isOnline":true,"isHidden":false,"supportsPlayback":true}]}]
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let devices = try d.decode([Device].self, from: Data(json.utf8))
        #expect(devices[0].supportsPlayback)
        #expect(devices[0].brand == nil)
    }
}
