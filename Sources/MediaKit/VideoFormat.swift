import Foundation
import CoreMedia
import VideoToolbox
import RTSPKit

/// Builds CoreMedia objects (format descriptions, sample buffers) from depacketized NAL units.
public enum VideoFormat {
    public static func formatDescription(codec: VideoCodec, parameterSets ps: VideoParameterSets) -> CMVideoFormatDescription? {
        guard let sps = ps.sps, let pps = ps.pps else { return nil }
        var format: CMVideoFormatDescription?
        switch codec {
        case .h264:
            let sets = [sps, pps]
            let status = withPointers(sets) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
            return status == noErr ? format : nil
        case .h265:
            guard let vps = ps.vps else { return nil }
            let sets = [vps, sps, pps]
            let status = withPointers(sets) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
            return status == noErr ? format : nil
        }
    }

    private static func withPointers(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> OSStatus) -> OSStatus {
        let buffers = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let ptrs = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return ptrs.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
        }
    }

    /// Length-prefixes NAL units (AVCC/HVCC) and wraps them in a ready CMSampleBuffer.
    public static func sampleBuffer(from au: AccessUnit, format: CMVideoFormatDescription,
                                    pts: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        let total = au.nalus.reduce(0) { $0 + 4 + $1.count }
        guard total > 0 else { return nil }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        var offset = 0
        for nal in au.nalus {
            var len = UInt32(nal.count).bigEndian
            status = CMBlockBufferReplaceDataBytes(with: &len, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4)
            offset += 4
            status = nal.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: nal.count)
            }
            offset += nal.count
            guard status == kCMBlockBufferNoErr else { return nil }
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = total
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                           formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                           sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        if !au.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    public static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    public static func dimensions(of format: CMVideoFormatDescription) -> CGSize {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }
}
