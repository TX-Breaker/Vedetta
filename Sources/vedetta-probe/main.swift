import Foundation
import CoreMedia
import RTSPKit
import MediaKit
import ONVIFKit
import VigiKit
import VedettaCore

// vedetta-probe: diagnostics for streams and devices.
//   vedetta-probe rtsp <url> [seconds] [--record out.mp4] [--snapshot out.jpg]
// Credentials come from VEDETTA_USER / VEDETTA_PASS environment variables (never argv).

let args = CommandLine.arguments
func usage() -> Never {
    print("usage: vedetta-probe rtsp|discover|onvif|vigi|nvr|recorder|brand|ptz <target> … (credentials in VEDETTA_USER / VEDETTA_PASS)")
    exit(2)
}
guard args.count >= 3 else { usage() }
let env = ProcessInfo.processInfo.environment

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args[1] {
case "rtsp":
    guard let url = URL(string: args[2]) else { usage() }
    let seconds = args.count > 3 ? Double(args[3]) ?? 5 : 5
    let sem = DispatchSemaphore(value: 0)
    Task {
        await RTSPProbe.run(url: url, seconds: seconds, user: env["VEDETTA_USER"], pass: env["VEDETTA_PASS"],
                            recordPath: value(after: "--record"), snapshotPath: value(after: "--snapshot"))
        sem.signal()
    }
    sem.wait()
case "discover":
    let sem = DispatchSemaphore(value: 0)
    Task {
        let devices = await ONVIFDiscovery.probe(timeout: 3)
        for d in devices {
            print("\(d.ip)\t\(d.isRecorder ? "NVR " : "CAM ")\(d.name)\t\(d.serviceURL)\(d.hasPTZ ? "\tPTZ" : "")")
        }
        print("found: \(devices.count)")
        sem.signal()
    }
    sem.wait()
case "onvif":
    guard let url = URL(string: args[2]) else { usage() }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let c = ONVIFClient(deviceURL: url, username: env["VEDETTA_USER"] ?? "", password: env["VEDETTA_PASS"] ?? "")
        await c.syncTime()
        do {
            let info = try await c.deviceInformation()
            print("device: \(info.manufacturer) \(info.model) fw \(info.firmware)")
            let services = try await c.loadServices()
            print("services: \(services.keys.sorted().joined(separator: ", "))")
            for p in try await c.profiles() {
                let uri = (try? await c.streamURI(profile: p))?.absoluteString ?? "-"
                print("profile \(p.token) \(p.name) \(p.encoding ?? "?") \(p.width)x\(p.height) ptz=\(p.hasPTZ) -> \(uri)")
            }
        } catch { print("ERROR: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
case "vigi":
    let hostPort = args[2].split(separator: ":")
    let host = String(hostPort[0])
    let port = hostPort.count > 1 ? Int(hostPort[1]) ?? 443 : 443
    let sem = DispatchSemaphore(value: 0)
    Task {
        let c = VigiClient(host: host, port: port, username: env["VEDETTA_USER"] ?? "admin", password: env["VEDETTA_PASS"] ?? "")
        do {
            try await c.login()
            print("login ok")
            let info = try await c.deviceInfo()
            print("NVR: \(info.model ?? "-") \(info.name ?? "") fw \(info.firmware ?? "-")")
            let chans = try await c.channels()
            for ch in chans { print("channel \(ch.id): \(ch.name) \(ch.ip ?? "") online=\(ch.online)") }
            let now = Date()
            if let first = chans.first {
                let days = try await c.recordingDays(channel: first.id, from: now.addingTimeInterval(-40*86400), to: now)
                print("days with recordings (channel \(first.id)): \(days.sorted().suffix(10).joined(separator: " "))")
                let recs = try await c.recordings(channel: first.id, day: now.addingTimeInterval(-86400))
                print("segments yesterday: \(recs.count) \(recs.prefix(3).map { "\($0.start)-\($0.end) t\($0.videoType)" }.joined(separator: ", "))")
                let evs = try await c.events(channel: first.id, from: now.addingTimeInterval(-86400), to: now)
                print("events 24h: \(evs.count) types=\(Set(evs.map(\.eventType)).sorted())")
            }
        } catch { print("ERROR: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
case "brand":
    Task { @MainActor in
        let parts = args[2].split(separator: ":")
        do {
            let r = try await DeviceConnector.connectBrandRecorder(host: String(parts[0]), brand: RecorderBrand(rawValue: args[3])!,
                                                                   rtspPort: parts.count > 1 ? Int(parts[1])! : 554,
                                                                   username: env["VEDETTA_USER"] ?? "admin", password: env["VEDETTA_PASS"] ?? "")
            print("recorder: \(r.device.name) channels=\(r.device.channels.map { "\($0.number)" }) playback=\(r.device.supportsPlayback)")
            for ch in r.device.channels { print("  \(ch.number): \(ch.subURL ?? "")") }
            for w in r.warnings { print("warning: \(w)") }
        } catch { print("ERROR: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
case "nvr":
    Task { @MainActor in
        let hp = args[2].split(separator: ":")
        do {
            let r = try await DeviceConnector.connectNVR(address: String(hp[0]), httpPort: hp.count > 1 ? Int(hp[1])! : 443, rtspPort: Int(args[3]) ?? 554,
                                                         username: env["VEDETTA_USER"] ?? "admin", password: env["VEDETTA_PASS"] ?? "")
            print("name=\(r.device.name) model=\(r.device.model ?? "-") fw=\(r.device.firmware ?? "-") channels=\(r.device.channels.map(\.name)) warnings=\(r.warnings)")
        } catch { print("ERROR: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
case "ptz":
    Task { @MainActor in
        do {
            let r = try await DeviceConnector.connectONVIF(url: URL(string: args[2])!, username: env["VEDETTA_USER"] ?? "admin",
                                                           password: env["VEDETTA_PASS"] ?? "")
            guard let ch = r.device.channels.first(where: \.hasPTZ), let profile = ch.ptzProfile else { print("ERROR: no PTZ channel"); exit(1) }
            let c = ONVIFClient(deviceURL: URL(string: args[2])!, username: env["VEDETTA_USER"] ?? "", password: env["VEDETTA_PASS"] ?? "")
            try await c.continuousMove(profile: profile, pan: 0.5, tilt: -0.25, zoom: 0)
            try await c.stop(profile: profile)
            try await c.continuousMove(profile: profile, pan: 0, tilt: 0, zoom: 0.3)
            try await c.stop(profile: profile)
            let tok = try await c.setPreset(profile: profile, name: "Cancello")
            let presets = try await c.presets(profile: profile)
            try await c.gotoPreset(profile: profile, preset: tok ?? "")
            try await c.removePreset(profile: profile, preset: tok ?? "")
            let after = try await c.presets(profile: profile)
            print("ptz ok: channel \(ch.number) profile \(profile) presets=\(presets.map(\.name)) after=\(after.count)")
        } catch { print("ERROR: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
case "recorder":
    Task { @MainActor in
        let user = env["VEDETTA_USER"] ?? "admin", pass = env["VEDETTA_PASS"] ?? ""
        do {
            let r = try await DeviceConnector.connectRecorder(address: args[2], onvifURL: nil, brand: nil, rtspPort: 554,
                                                              username: user, password: pass)
            let d = r.device
            print("recorder: \(d.name) [\(d.kind.rawValue)] brand=\(d.brand?.rawValue ?? "-") onvif=\(d.onvifURL ?? "-")")
            for w in r.warnings { print("warning: \(w)") }
            for ch in d.channels { print("channel \(ch.number) \(ch.name) src=\(ch.sourceToken ?? "-") rec=\(ch.recordingToken ?? "-") main=\(ch.mainURL ?? "-")") }
            CredentialCache.shared.set(pass, for: d.id)
            defer { CredentialCache.shared.remove(d.id) }
            let now = Date()
            let days = try await PlaybackBackend.recordedDays(device: d, channels: d.channels, from: now.addingTimeInterval(-5 * 86400), to: now)
            print("days: \(days.map { $0.sorted().joined(separator: " ") } ?? "unknown")")
            if let ch = d.channels.first {
                let idx = try await PlaybackBackend.dayIndex(device: d, channel: ch, day: now)
                print("today: \(idx.segments.count) segments \(idx.segments.map { "\(Format.hm($0.start))-\(Format.hm($0.end))" }) events \(idx.events.map { "\($0.type)@\(Format.hm($0.start))" })")
                let targets = try await PlaybackBackend.replayTargets(device: d, channel: ch, from: now.addingTimeInterval(-600), to: now, export: false)
                for t in targets { print("replay: \(t.url) range=\(t.range ?? "-") headers=\(t.headers)") }
                if let t = targets.first {
                    var o = RTSPClient.Options(url: t.url, username: user, password: pass)
                    o.range = t.range; o.extraHeaders = t.headers; o.extraPlayHeaders = t.playHeaders
                    let c = RTSPClient(options: o)
                    final class N: @unchecked Sendable { var n = 0 }
                    let counter = N()
                    c.onVideo = { _ in counter.n += 1 }
                    do { try await c.start(); try await Task.sleep(nanoseconds: 3_000_000_000); print("replay frames in 3s: \(counter.n)") }
                    catch { print("replay error: \(error.localizedDescription)") }
                    c.stop()
                }
            }
        } catch { print("ERROR: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
default:
    usage()
}

enum Format {
    static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
}

enum RTSPProbe {
    static func run(url: URL, seconds: Double, user: String?, pass: String?, recordPath: String?, snapshotPath: String?) async {
        var opts = RTSPClient.Options(url: url, username: user, password: pass)
        opts.wantAudio = true
        let client = RTSPClient(options: opts)
        final class State: @unchecked Sendable {
            var desc: RTSPStreamDescription?
            var aus = 0, keyframes = 0, bytes = 0, audioFrames = 0
            var format: CMVideoFormatDescription?
            var decoder: FrameDecoder?
            var decoded = 0
            var recorder: MP4Recorder?
            var unwrap = RTPTimestampUnwrapper()
            var audioUnwrap = RTPTimestampUnwrapper()
            var firstTS: Int64?
            var videoAnchor: (rtp: Int64, wall: Double)?
            var audioAnchor: (rtp: Int64, wall: Double)?
            var gop: [CMSampleBuffer] = []
            var ps = VideoParameterSets()
        }
        let st = State()
        let recordURL = recordPath.map { URL(fileURLWithPath: $0) }
        client.onDescribed = { d in
            st.desc = d
            st.ps = d.videoParameterSets
            print("SDP ok: video=\(d.videoCodec?.rawValue ?? "-") audio=\(d.audio.map { "\($0.codec.rawValue) \($0.sampleRate)Hz" } ?? "-") scale=\(d.scaleAccepted.map { "\($0)" } ?? "-")")
        }
        client.onParameterSets = { ps in st.ps = ps; st.format = nil }
        client.onVideo = { au in
            st.aus += 1; st.bytes += au.byteCount
            if au.isKeyframe { st.keyframes += 1 }
            guard let codec = st.desc?.videoCodec else { return }
            if st.format == nil, st.ps.isComplete(for: codec) {
                st.format = VideoFormat.formatDescription(codec: codec, parameterSets: st.ps)
                if let f = st.format {
                    st.decoder = FrameDecoder(format: f)
                    print("format: \(codec.rawValue) \(Int(VideoFormat.dimensions(of: f).width))x\(Int(VideoFormat.dimensions(of: f).height)) HW=\(st.decoder?.hardwareAccelerated ?? false)")
                    if let recordURL {
                        do { st.recorder = try MP4Recorder(url: recordURL, videoFormat: f, audio: st.desc?.audio) }
                        catch { print("recorder: \(error.localizedDescription)") }
                    }
                }
            }
            guard let f = st.format else { return }
            let t = st.unwrap.unwrap(au.rtpTimestamp)
            if st.firstTS == nil { st.firstTS = t }
            if st.videoAnchor == nil { st.videoAnchor = (t, CFAbsoluteTimeGetCurrent()) }
            let secs = st.videoAnchor!.wall + Double(t - st.videoAnchor!.rtp) / Double(st.desc?.videoClockRate ?? 90000)
            if let s = VideoFormat.sampleBuffer(from: au, format: f, pts: CMTime(seconds: secs, preferredTimescale: 90000)) {
                if au.isKeyframe { st.gop = [] }
                st.gop.append(s)
                if st.decoder?.decode(s) == true { st.decoded += 1 }
            }
            st.recorder?.appendVideo(au, time: secs)
        }
        client.onAudio = { frame in
            st.audioFrames += 1
            guard let rate = st.desc?.audio?.sampleRate else { return }
            let t = st.audioUnwrap.unwrap(frame.rtpTimestamp)
            if st.audioAnchor == nil { st.audioAnchor = (t, CFAbsoluteTimeGetCurrent()) }
            let secs = st.audioAnchor!.wall + Double(t - st.audioAnchor!.rtp) / Double(rate)
            st.recorder?.appendAudio(frame, time: secs)
        }
        let start = Date()
        do {
            try await client.start()
        } catch {
            print("ERROR: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let elapsed = Date().timeIntervalSince(start)
        client.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let fps = Double(st.aus) / elapsed
        print(String(format: "received: %d frames (%.1f fps), %d keyframes, %.0f kbit/s, %d decoded, audio %d frames",
                     st.aus, fps, st.keyframes, Double(st.bytes * 8) / elapsed / 1000, st.decoded, st.audioFrames))
        if let snapshotPath, let f = st.format, let img = FrameDecoder.image(fromGOP: st.gop, format: f) {
            ImageWriter.write(img, to: URL(fileURLWithPath: snapshotPath))
            print("snapshot: \(snapshotPath) \(img.width)x\(img.height)")
        }
        if let rec = st.recorder {
            let sem = DispatchSemaphore(value: 0)
            client.queue.async {
                rec.finish { url, err in
                    print(url != nil ? "recording: \(url!.path) frames=\(rec.videoFrames)" : "recording failed: \(err?.localizedDescription ?? "")")
                    sem.signal()
                }
            }
            sem.wait()
        }
    }
}

