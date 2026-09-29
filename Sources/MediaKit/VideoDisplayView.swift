import AppKit
import AVFoundation
import CoreMedia
import QuartzCore

/// Receives decoded-for-display video samples.
public protocol VideoSink: AnyObject {
    func enqueue(_ sample: CMSampleBuffer)
    func flush()
    func setTimebase(_ timebase: CMTimebase?)
}

/// NSView hosting an AVSampleBufferDisplayLayer: hardware decode + Metal composition, zero CPU copies.
/// Digital zoom is a layer transform (no pixel work).
public final class VideoDisplayView: NSView, VideoSink {
    public let displayLayer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()

    public var zoom: CGFloat = 1 { didSet { applyTransform() } }
    /// Pan in normalized units (-1...1 of the extra area created by zoom).
    public var pan: CGPoint = .zero { didSet { applyTransform() } }
    public var fillsFrame: Bool = false {
        didSet { gravity = fillsFrame ? .resizeAspectFill : .resizeAspect }
    }
    /// .resizeAspect (black bars), .resizeAspectFill (crop) or .resize (stretch, nothing cropped).
    public var gravity: AVLayerVideoGravity = .resizeAspect {
        didSet { if displayLayer.videoGravity != gravity { displayLayer.videoGravity = gravity } }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(displayLayer)
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Display only: clicks, drags, hover and gestures go to the SwiftUI views around it.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.transform = CATransform3DIdentity
        displayLayer.frame = bounds
        applyTransform()
        CATransaction.commit()
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let z = max(1, min(zoom, 8))
        let maxOffsetX = bounds.width * (z - 1) / 2
        let maxOffsetY = bounds.height * (z - 1) / 2
        var t = CATransform3DMakeTranslation(-pan.x * maxOffsetX, pan.y * maxOffsetY, 0)
        t = CATransform3DScale(t, z, z, 1)
        displayLayer.transform = t
        CATransaction.commit()
    }

    // MARK: VideoSink

    public func enqueue(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
        }
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    public func setTimebase(_ timebase: CMTimebase?) {
        lock.lock(); defer { lock.unlock() }
        displayLayer.controlTimebase = timebase
    }

    /// The currently displayed picture (nil while a timebase is running).
    public func currentImage() -> CGImage? {
        guard let pb = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        return FrameDecoder.cgImage(from: pb)
    }
}
