#if DEBUG && !targetEnvironment(simulator)
import AVKit
import CoreText
import SwiftUI

/// Pixel buffers contain generated subtitle graphics, never captured screen frames.
@MainActor
final class G0PiPProbe: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @preconcurrency AVPictureInPictureControllerDelegate {
    let layer = AVSampleBufferDisplayLayer()
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var controller: AVPictureInPictureController?
    private var renderTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var origin = 0.0
    private var restoring = false
    private var lines = "等待声音"
    private var renderedLines = ""
    private var lastRenderUptime = 0.0
    private(set) var frames = 0
    private(set) var started = false
    var onEvent: ((UUID, String) -> Void)?

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func prepare(sessionID: UUID) throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { throw FailureCode.pipFailed }
        self.sessionID = sessionID
        origin = ProcessInfo.processInfo.systemUptime
        frames = 0
        restoring = false
        let synchronizer = AVSampleBufferRenderSynchronizer()
        self.synchronizer = synchronizer
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: .zero)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        try render()
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1_000 / RuntimePolicy.maximumRenderFPS)) } catch { return }
                guard let self, self.sessionID == sessionID else { return }
                // New text appears at the policy cadence; unchanged text only
                // needs a one-second heartbeat, avoiding constant frame work.
                guard self.lines != self.renderedLines || ProcessInfo.processInfo.systemUptime - self.lastRenderUptime >= 1 else { continue }
                do { try self.render() } catch { self.onEvent?(sessionID, "renderFailed"); return }
            }
        }
    }

    func start() throws {
        guard let controller, controller.isPictureInPicturePossible else { throw FailureCode.pipFailed }
        restoring = false
        controller.startPictureInPicture()
    }

    func update(_ lines: String) { self.lines = lines }
    var isActive: Bool { controller?.isPictureInPictureActive == true }

    func stop() async {
        sessionID = nil // Invalidate before controller callbacks or task cancellation.
        renderTask?.cancel()
        await renderTask?.value
        renderTask = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        if let receiver {
            await receiver.flush(removingDisplayedImage: true)
        }
        receiver = nil
        synchronizer?.setRate(0, time: .zero)
        synchronizer = nil // End the entire per-run renderer/synchronizer ownership graph.
        started = false
        lines = "等待声音"
    }

    private func render() throws {
        guard let receiver else { throw FailureCode.pipFailed }
        let time = CMTime(seconds: ProcessInfo.processInfo.systemUptime - origin, preferredTimescale: 600)
        switch receiver.enqueueImmediately(try Self.makeFrame(text: lines, time: time)) {
        case .enqueued:
            frames += 1
            renderedLines = lines
            lastRenderUptime = ProcessInfo.processInfo.systemUptime
        default: throw FailureCode.pipFailed
        }
    }

    private nonisolated static func makeFrame(text: String, time: CMTime) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let width = 960
        let height = 540
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                         kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                         kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else {
            throw FailureCode.pipFailed
        }
        do {
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw FailureCode.pipFailed
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 28, y: 24, width: width - 56, height: height - 48), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        } // Finish every pixel-buffer access before transferring ownership.
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                            formatDescriptionOut: &description) == noErr, let description else {
            throw FailureCode.pipFailed
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(RuntimePolicy.maximumRenderFPS)),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else {
            throw FailureCode.pipFailed
        }
        return CMReadySampleBuffer(unsafeBuffer: sample)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard let sessionID else { return }
        started = true
        onEvent?(sessionID, "started")
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        guard let sessionID else { return }
        onEvent?(sessionID, "startFailed")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard let sessionID else { return }
        started = false
        onEvent?(sessionID, restoring ? "restored" : "closed")
        restoring = false
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let sessionID else { completionHandler(false); return }
        restoring = true
        onEvent?(sessionID, "restoreRequested")
        completionHandler(true)
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) { completion() }
}

@MainActor
struct G0PiPPreview: UIViewRepresentable {
    let probe: G0PiPProbe
    func makeUIView(context: Context) -> UIView {
        let view = G0LayerView()
        view.videoLayer = probe.layer
        view.layer.addSublayer(probe.layer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class G0LayerView: UIView {
    var videoLayer: AVSampleBufferDisplayLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
    }
}
#endif
