import Foundation
import CoreMedia
import CoreImage
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

/// Synchronous VideoToolbox decoder used on demand (snapshots, thumbnails, self-tests).
/// Live display never uses this path: it goes through AVSampleBufferDisplayLayer.
public final class FrameDecoder {
    private var session: VTDecompressionSession?
    private let format: CMVideoFormatDescription
    public private(set) var lastImage: CVPixelBuffer?
    public private(set) var decodedFrames = 0
    public private(set) var hardwareAccelerated = false

    public init?(format: CMVideoFormatDescription) {
        self.format = format
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        session = s
        var hw: CFBoolean?
        if VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                 allocator: kCFAllocatorDefault, valueOut: &hw) == noErr, let hw {
            hardwareAccelerated = CFBooleanGetValue(hw)
        }
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    @discardableResult
    public func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let session else { return false }
        var ok = false
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            if status == noErr, let image {
                self?.lastImage = image
                self?.decodedFrames += 1
                ok = true
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr && ok
    }

    /// Decodes a GOP (keyframe first) and returns the final picture as a CGImage.
    public static func image(fromGOP samples: [CMSampleBuffer], format: CMVideoFormatDescription) -> CGImage? {
        guard let decoder = FrameDecoder(format: format) else { return nil }
        for s in samples { decoder.decode(s) }
        guard let pb = decoder.lastImage else { return nil }
        return cgImage(from: pb)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}

public enum ImageWriter {
    public enum Kind { case jpeg, png }
    @discardableResult
    public static func write(_ image: CGImage, to url: URL, kind: Kind = .jpeg, quality: Double = 0.92) -> Bool {
        let type = kind == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
