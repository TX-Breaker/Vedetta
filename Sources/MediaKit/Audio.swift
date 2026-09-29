import Foundation
import AVFoundation
import RTSPKit

public enum G711 {
    private static let ulawTable: [Int16] = (0..<256).map { i -> Int16 in
        let u = ~UInt8(i)
        let sign = u & 0x80
        let exponent = Int((u >> 4) & 0x07)
        let mantissa = Int(u & 0x0F)
        var sample = ((mantissa << 3) + 0x84) << exponent
        sample -= 0x84
        return Int16(sign != 0 ? -sample : sample)
    }
    private static let alawTable: [Int16] = (0..<256).map { i -> Int16 in
        let a = UInt8(i) ^ 0x55
        let sign = a & 0x80
        let exponent = Int((a >> 4) & 0x07)
        let mantissa = Int(a & 0x0F)
        var sample: Int
        if exponent == 0 { sample = (mantissa << 4) + 8 }
        else { sample = ((mantissa << 4) + 0x108) << (exponent - 1) }
        return Int16(sign != 0 ? sample : -sample)
    }

    public static func decode(_ data: Data, alaw: Bool) -> [Int16] {
        let table = alaw ? alawTable : ulawTable
        return data.map { table[Int($0)] }
    }
}

/// Decodes AAC/G.711/L16 frames into float PCM.
public final class AudioDecoder {
    public let info: AudioTrackInfo
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var aacFormat: AVAudioFormat?

    public init?(info: AudioTrackInfo) {
        self.info = info
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(info.sampleRate),
                                      channels: AVAudioChannelCount(max(1, info.channels)), interleaved: false) else { return nil }
        outputFormat = out
        if info.codec == .aac {
            var asbd = AudioStreamBasicDescription(mSampleRate: Double(info.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                                   mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                   mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, info.channels)),
                                                   mBitsPerChannel: 0, mReserved: 0)
            guard let inFmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
            aacFormat = inFmt
            converter = AVAudioConverter(from: inFmt, to: out)
            if let cookie = info.aacConfig { converter?.magicCookie = cookie }
        }
    }

    public func decode(_ frame: AudioFrame) -> AVAudioPCMBuffer? {
        switch info.codec {
        case .pcmu, .pcma:
            let samples = G711.decode(frame.data, alaw: info.codec == .pcma)
            return pcm(fromInt16: samples)
        case .l16:
            let count = frame.data.count / 2
            var samples = [Int16](repeating: 0, count: count)
            frame.data.withUnsafeBytes { raw in
                for i in 0..<count { samples[i] = Int16(bigEndian: raw.load(fromByteOffset: i * 2, as: Int16.self)) }
            }
            return pcm(fromInt16: samples)
        case .aac:
            return decodeAAC(frame.data)
        }
    }

    private func pcm(fromInt16 samples: [Int16]) -> AVAudioPCMBuffer? {
        let ch = Int(outputFormat.channelCount)
        let frames = samples.count / ch
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<ch {
            let dst = buf.floatChannelData![c]
            for f in 0..<frames { dst[f] = Float(samples[f * ch + c]) / 32768.0 }
        }
        return buf
    }

    private func decodeAAC(_ data: Data) -> AVAudioPCMBuffer? {
        guard let converter, let aacFormat else { return nil }
        let compressed = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: data.count)
        data.withUnsafeBytes { raw in compressed.data.copyMemory(from: raw.baseAddress!, byteCount: data.count) }
        compressed.byteLength = UInt32(data.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                              mDataByteSize: UInt32(data.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided { inputStatus.pointee = .noDataNow; return nil }
            provided = true
            inputStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// Low-latency audio output for one stream.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder: AudioDecoder
    private var queuedFrames: Int = 0
    private let lock = NSLock()
    private let maxQueued: Int

    public var volume: Float {
        get { node.volume }
        set { node.volume = newValue }
    }

    public init?(info: AudioTrackInfo) {
        guard let d = AudioDecoder(info: info) else { return nil }
        decoder = d
        maxQueued = info.sampleRate / 2 // ~500 ms
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: d.outputFormat)
        do { try engine.start() } catch { return nil }
        node.play()
    }

    public func enqueue(_ frame: AudioFrame) {
        guard let buf = decoder.decode(frame) else { return }
        let n = Int(buf.frameLength)
        let skip = lock.withLock { queuedFrames + n > maxQueued }
        if skip { return }
        lock.withLock { queuedFrames += n }
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queuedFrames -= n }
        }
    }

    public func stop() {
        node.stop()
        engine.stop()
    }
}
