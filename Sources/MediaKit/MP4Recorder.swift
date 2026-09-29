import Foundation
import AVFoundation
import CoreMedia
import RTSPKit
import VedettaL10n

public enum RecorderError: LocalizedError {
    case cannotCreate(String)
    public var errorDescription: String? {
        switch self { case .cannotCreate(let s): return L("Cannot create the video file: %@", s) }
    }
}

/// Writes H.264/H.265 access units to MP4 without re-encoding.
/// Audio is passed through for AAC and encoded to AAC for G.711/PCM.
/// Call all methods from the same serial queue.
public final class MP4Recorder {
    public let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private let videoFormat: CMVideoFormatDescription
    private let audioInfo: AudioTrackInfo?
    private var audioFormat: CMAudioFormatDescription?
    private var origin: Double?
    private var lastVideoTime: Double = -1
    private var lastAudioTime: Double = -1
    private(set) public var isFinished = false
    public private(set) var videoFrames = 0
    public var duration: Double { origin.map { max(0, lastVideoTime - $0) } ?? 0 }

    private let realTime: Bool

    /// `realTime` = live recording (short waits); false = exports (waits longer for the writer instead of dropping frames).
    /// Inputs are always real-time: non-real-time interleaving can stall a producer that feeds audio and video from one queue.
    public init(url: URL, videoFormat: CMVideoFormatDescription, audio: AudioTrackInfo?, realTime: Bool = true) throws {
        self.url = url
        self.realTime = realTime
        self.videoFormat = videoFormat
        self.audioInfo = audio
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecorderError.cannotCreate(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotCreate(L("video track not supported")) }
        writer.add(videoInput)

        if let audio {
            switch audio.codec {
            case .aac:
                if let fmt = Self.aacFormatDescription(audio) {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
                    input.expectsMediaDataInRealTime = true
                    if writer.canAdd(input) { writer.add(input); audioInput = input; audioFormat = fmt }
                }
            case .pcmu, .pcma, .l16:
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                               AVSampleRateKey: audio.sampleRate,
                                               AVNumberOfChannelsKey: max(1, audio.channels),
                                               AVEncoderBitRateKey: audio.sampleRate <= 8000 ? 24000 : 48000]
                if writer.canApply(outputSettings: settings, forMediaType: .audio) {
                    var asbd = AudioStreamBasicDescription(mSampleRate: Double(audio.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                           mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                           mBytesPerPacket: UInt32(2 * max(1, audio.channels)), mFramesPerPacket: 1,
                                                           mBytesPerFrame: UInt32(2 * max(1, audio.channels)),
                                                           mChannelsPerFrame: UInt32(max(1, audio.channels)), mBitsPerChannel: 16, mReserved: 0)
                    var fmt: CMAudioFormatDescription?
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmt)
                    input.expectsMediaDataInRealTime = true
                    if let fmt, writer.canAdd(input) { writer.add(input); audioInput = input; audioFormat = fmt }
                }
            }
        }
        guard writer.startWriting() else {
            throw RecorderError.cannotCreate(writer.error?.localizedDescription ?? L("unknown error"))
        }
    }

    private static func aacFormatDescription(_ info: AudioTrackInfo) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(info.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, info.channels)),
                                               mBitsPerChannel: 0, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let cookie = info.aacConfig ?? Data()
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: cookie.isEmpty ? nil : raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    /// `time` is in seconds on any monotonic timeline shared with audio.
    public func appendVideo(_ au: AccessUnit, time: Double) {
        guard !isFinished else { return }
        if origin == nil {
            guard au.isKeyframe else { return }
            origin = time
            writer.startSession(atSourceTime: .zero)
        }
        guard let origin, time > lastVideoTime else { return }
        let pts = CMTime(seconds: time - origin, preferredTimescale: 90000)
        guard let sample = VideoFormat.sampleBuffer(from: au, format: videoFormat, pts: pts) else { return }
        // Dropping a frame would corrupt every following frame up to the next keyframe: wait instead.
        guard waitUntilReady(videoInput) else { return }
        if videoInput.append(sample) { videoFrames += 1; lastVideoTime = time }
    }

    public func appendAudio(_ frame: AudioFrame, time: Double) {
        guard !isFinished, let input = audioInput, let info = audioInfo, let fmt = audioFormat,
              let origin, time >= origin, time > lastAudioTime else { return }
        let pts = CMTime(seconds: time - origin, preferredTimescale: CMTimeScale(info.sampleRate))
        var sample: CMSampleBuffer?
        switch info.codec {
        case .aac:
            sample = Self.makeAACSample(frame.data, format: fmt, pts: pts)
        case .pcmu, .pcma, .l16:
            let pcm: [Int16]
            if info.codec == .l16 {
                pcm = stride(from: 0, to: frame.data.count - 1, by: 2).map {
                    Int16(bitPattern: UInt16(frame.data[frame.data.startIndex + $0]) << 8 | UInt16(frame.data[frame.data.startIndex + $0 + 1]))
                }
            } else {
                pcm = G711.decode(frame.data, alaw: info.codec == .pcma)
            }
            sample = Self.makePCMSample(pcm, channels: max(1, info.channels), format: fmt, pts: pts)
        }
        if let sample, waitUntilReady(input), input.append(sample) { lastAudioTime = time }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        let limit = realTime ? 0.25 : 10
        let start = CFAbsoluteTimeGetCurrent()
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || CFAbsoluteTimeGetCurrent() - start > limit { return false }
            usleep(2000)
        }
        return true
    }

    private static func makeAACSample(_ data: Data, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                         formatDescription: format, sampleCount: 1,
                                                                         presentationTimeStamp: pts, packetDescriptions: &desc,
                                                                         sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    private static func makePCMSample(_ pcm: [Int16], channels: Int, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let byteCount = pcm.count * 2
        guard byteCount > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        var sample: CMSampleBuffer?
        let frames = pcm.count / channels
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                         formatDescription: format, sampleCount: frames,
                                                                         presentationTimeStamp: pts, packetDescriptions: nil,
                                                                         sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    public func finish(completion: @escaping @Sendable (URL?, Error?) -> Void) {
        guard !isFinished else { return }
        isFinished = true
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        guard origin != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(nil, RecorderError.cannotCreate(L("no frames received")))
            return
        }
        let url = self.url
        let lastTime = lastVideoTime - (origin ?? 0)
        writer.endSession(atSourceTime: CMTime(seconds: max(0, lastTime), preferredTimescale: 90000))
        writer.finishWriting { [writer] in
            if writer.status == .completed { completion(url, nil) }
            else { completion(nil, writer.error ?? RecorderError.cannotCreate(L("writing not completed"))) }
        }
    }
}
