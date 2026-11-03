import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
#if !TASK11_HOST_CHECK
import AVFoundation
#endif

struct PresentationSystemClock: MonotonicClock {
    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let current = now().uptimeNanoseconds
        if deadline.uptimeNanoseconds > current {
            let difference = deadline.uptimeNanoseconds - current
            try await Task.sleep(for: .nanoseconds(Int64(min(difference, UInt64(Int64.max)))))
        }
        try Task.checkCancellation()
    }
}

@MainActor
struct SubtitleFrame {
    let layout: SubtitleLayout
    let presentationTimeStamp: CMTime
    #if !TASK11_HOST_CHECK
    let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    #endif

    init(layout: SubtitleLayout, presentationTimeStamp: CMTime) throws {
        self.layout = layout
        self.presentationTimeStamp = presentationTimeStamp
        #if !TASK11_HOST_CHECK
        sample = try Self.makeSample(layout: layout, presentationTimeStamp: presentationTimeStamp)
        #endif
    }

    #if !TASK11_HOST_CHECK
    private nonisolated static func makeSample(
        layout: SubtitleLayout,
        presentationTimeStamp: CMTime
    ) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let width = Int(layout.size.width.rounded())
        let height = Int(layout.size.height.rounded())
        guard width > 0, height > 0 else { throw FailureCode.pipFailed }
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixel
        ) == kCVReturnSuccess, let pixel else {
            throw FailureCode.pipFailed
        }
        do {
            CVPixelBufferLockBaseAddress(pixel, [])
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixel),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw FailureCode.pipFailed
            }
            layout.draw(in: context)
        }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescriptionOut: &description
        ) == noErr, let description else {
            throw FailureCode.pipFailed
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(RuntimePolicy.maximumRenderFPS)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw FailureCode.pipFailed
        }
        return CMReadySampleBuffer(unsafeBuffer: sample)
    }
    #endif
}

@MainActor
protocol SubtitleFrameOutput: AnyObject {
    func enqueue(_ frame: SubtitleFrame) throws
    func flush() async
}

#if !TASK11_HOST_CHECK
@MainActor
final class ReceiverSubtitleFrameOutput: SubtitleFrameOutput {
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let receiver: AVSampleBufferVideoRenderer.Receiver

    init(layer: AVSampleBufferDisplayLayer) {
        synchronizer = AVSampleBufferRenderSynchronizer()
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: .zero)
    }

    func enqueue(_ frame: SubtitleFrame) throws {
        synchronizer.setRate(1, time: .zero)
        switch receiver.enqueueImmediately(frame.sample) {
        case .enqueued:
            return
        default:
            throw FailureCode.pipFailed
        }
    }

    func flush() async {
        await receiver.flush(removingDisplayedImage: true)
        synchronizer.setRate(0, time: .zero)
    }
}
#endif

@MainActor
final class SubtitleRenderer: SubtitleRendering {
    #if !TASK11_HOST_CHECK
    let displayLayer: AVSampleBufferDisplayLayer
    #endif

    private let output: any SubtitleFrameOutput
    private let clock: any MonotonicClock
    private var renderSize: CGSize
    private var currentSnapshot: SubtitleSnapshot?
    private var pendingSnapshot: SubtitleSnapshot?
    private var currentLayout: SubtitleLayout?
    private var renderTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var workID: UInt64 = 0
    private var lastRenderUptime: UInt64?
    private var ptsOrigin: UInt64?
    private var lastPTSTick: Int64?

    var onFailure: ((FailureCode) -> Void)?

    #if !TASK11_HOST_CHECK
    convenience init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        self.init(output: ReceiverSubtitleFrameOutput(layer: layer), clock: PresentationSystemClock(), displayLayer: layer)
    }
    #endif

    #if !TASK11_HOST_CHECK
    init(
        output: any SubtitleFrameOutput,
        clock: any MonotonicClock,
        displayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        renderSize: CGSize = CGSize(width: 960, height: 540)
    ) {
        self.output = output
        self.clock = clock
        self.renderSize = renderSize
        self.displayLayer = displayLayer
    }
    #else
    init(
        output: any SubtitleFrameOutput,
        clock: any MonotonicClock,
        renderSize: CGSize = CGSize(width: 960, height: 540)
    ) {
        self.output = output
        self.clock = clock
        self.renderSize = renderSize
    }
    #endif

    func present(_ snapshot: SubtitleSnapshot) {
        if let currentSnapshot, currentSnapshot.identity.sessionID != snapshot.identity.sessionID {
            clear()
        }
        currentSnapshot = snapshot
        pendingSnapshot = snapshot
        if lastRenderUptime == nil, clearTask == nil {
            if drawPending() { scheduleHeartbeat() }
        } else {
            schedulePending()
        }
    }

    func updateRenderSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != renderSize else { return }
        renderSize = size
        guard let currentSnapshot else { return }
        pendingSnapshot = currentSnapshot
        schedulePending()
    }

    func clear() {
        workID &+= 1
        renderTask?.cancel()
        renderTask = nil
        currentSnapshot = nil
        pendingSnapshot = nil
        currentLayout = nil
        lastRenderUptime = nil
        ptsOrigin = nil
        lastPTSTick = nil
        let previousClear = clearTask
        clearTask = Task { [output] in
            await previousClear?.value
            await output.flush()
        }
    }

    func waitForClear() async {
        await clearTask?.value
    }

    private func schedulePending() {
        let interval = UInt64(1_000_000_000 / max(RuntimePolicy.maximumRenderFPS, 1))
        let deadline = max(clock.now().uptimeNanoseconds, (lastRenderUptime ?? 0) &+ interval)
        schedule(deadline: deadline, heartbeat: false)
    }

    private func scheduleHeartbeat() {
        guard currentLayout != nil, let lastRenderUptime else { return }
        schedule(deadline: lastRenderUptime &+ 1_000_000_000, heartbeat: true)
    }

    private func schedule(deadline: UInt64, heartbeat: Bool) {
        workID &+= 1
        let expectedWork = workID
        renderTask?.cancel()
        let clearTask = self.clearTask
        renderTask = Task { [clock, weak self] in
            if let clearTask { await clearTask.value }
            guard self?.workID == expectedWork else { return }
            do {
                try await clock.sleep(until: MonotonicInstant(uptimeNanoseconds: deadline))
            } catch {
                return
            }
            guard let self, self.workID == expectedWork else { return }
            let drewFrame = heartbeat ? self.draw(self.currentLayout) : self.drawPending()
            if drewFrame { self.scheduleHeartbeat() }
        }
    }

    private func drawPending() -> Bool {
        guard let pendingSnapshot else { return false }
        return draw(SubtitleLayout(snapshot: pendingSnapshot, size: renderSize))
    }

    private func draw(_ layout: SubtitleLayout?) -> Bool {
        guard let layout else { return false }
        do {
            let now = clock.now().uptimeNanoseconds
            let frame = try SubtitleFrame(layout: layout, presentationTimeStamp: nextPTS(now: now))
            try output.enqueue(frame)
            currentLayout = layout
            pendingSnapshot = nil
            lastRenderUptime = now
            return true
        } catch {
            let failure = error as? FailureCode ?? .pipFailed
            clear()
            onFailure?(failure)
            return false
        }
    }

    private func nextPTS(now: UInt64) -> CMTime {
        if ptsOrigin == nil { ptsOrigin = now }
        let elapsed = now >= (ptsOrigin ?? now) ? now - (ptsOrigin ?? now) : 0
        let candidate = Int64(clamping: elapsed)
        let next = max(candidate, (lastPTSTick ?? -1) &+ 1)
        lastPTSTick = next
        return CMTime(value: next, timescale: 1_000_000_000)
    }
}
