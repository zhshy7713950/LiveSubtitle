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

enum SubtitleTimebaseAction {
    case start
    case none
}

struct SubtitleTimebaseState {
    private var needsStart = true

    mutating func nextEnqueueAction() -> SubtitleTimebaseAction {
        guard needsStart else { return .none }
        needsStart = false
        return .start
    }

    mutating func didFlush() {
        needsStart = true
    }
}

struct SubtitleFrame: Sendable {
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

protocol SubtitleFrameBuilding: Sendable {
    func make(
        input: SubtitleLayoutInput,
        size: CGSize,
        presentationTimeStamp: CMTime
    ) async throws -> SubtitleFrame
}

actor SubtitleFrameBuilder: SubtitleFrameBuilding {
    func make(
        input: SubtitleLayoutInput,
        size: CGSize,
        presentationTimeStamp: CMTime
    ) async throws -> SubtitleFrame {
        try SubtitleFrame(
            layout: SubtitleLayout(input: input, size: size),
            presentationTimeStamp: presentationTimeStamp
        )
    }
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
    private var timebase = SubtitleTimebaseState()

    init(layer: AVSampleBufferDisplayLayer) {
        synchronizer = AVSampleBufferRenderSynchronizer()
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: .zero)
    }

    func enqueue(_ frame: SubtitleFrame) throws {
        if timebase.nextEnqueueAction() == .start {
            synchronizer.setRate(1, time: .zero)
        }
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
        timebase.didFlush()
    }
}
#endif

@MainActor
final class SubtitleRenderer: SubtitleRendering {
    private struct RenderJob {
        let sessionID: UUID
        let input: SubtitleLayoutInput
        let size: CGSize
        let presentationTimeStamp: CMTime
    }

    #if !TASK11_HOST_CHECK
    let displayLayer: AVSampleBufferDisplayLayer
    #endif

    private let output: any SubtitleFrameOutput
    private let clock: any MonotonicClock
    private let builder: any SubtitleFrameBuilding
    private var renderSize: CGSize
    private var activeSessionID: UUID?
    private var acceptedInput: SubtitleLayoutInput?
    private var pendingInput: SubtitleLayoutInput?
    private var renderedInput: SubtitleLayoutInput?
    private var renderTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var workID: UInt64 = 0
    private var isComputing = false
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

    init(
        output: any SubtitleFrameOutput,
        clock: any MonotonicClock,
        builder: any SubtitleFrameBuilding = SubtitleFrameBuilder(),
        displayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        renderSize: CGSize = CGSize(width: 960, height: 540)
    ) {
        self.output = output
        self.clock = clock
        self.builder = builder
        self.renderSize = renderSize
        self.displayLayer = displayLayer
    }
    #else
    init(
        output: any SubtitleFrameOutput,
        clock: any MonotonicClock,
        builder: any SubtitleFrameBuilding = SubtitleFrameBuilder(),
        renderSize: CGSize = CGSize(width: 960, height: 540)
    ) {
        self.output = output
        self.clock = clock
        self.builder = builder
        self.renderSize = renderSize
    }
    #endif

    func activate(sessionID: UUID) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        clear()
    }

    func deactivate(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        clear()
    }

    func present(_ snapshot: SubtitleSnapshot) {
        guard activeSessionID == snapshot.identity.sessionID else { return }
        let input = SubtitleLayoutInput(snapshot: snapshot)
        guard input != acceptedInput else { return }
        acceptedInput = input
        pendingInput = input
        schedulePending()
    }

    func updateRenderSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != renderSize else { return }
        renderSize = size
        guard let acceptedInput else { return }
        pendingInput = acceptedInput
        schedulePending()
    }

    func clear() {
        workID &+= 1
        if !isComputing {
            renderTask?.cancel()
            renderTask = nil
        }
        acceptedInput = nil
        pendingInput = nil
        renderedInput = nil
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
        let clearTask = self.clearTask
        let renderTask = self.renderTask
        await clearTask?.value
        await renderTask?.value
    }

    private func schedulePending() {
        guard pendingInput != nil else {
            scheduleHeartbeat()
            return
        }
        if isComputing {
            workID &+= 1
            return
        }
        let now = clock.now().uptimeNanoseconds
        let deadline: UInt64
        if let lastRenderUptime {
            let interval = UInt64(1_000_000_000 / max(RuntimePolicy.maximumRenderFPS, 1))
            deadline = max(now, lastRenderUptime &+ interval)
        } else {
            deadline = now
        }
        startTask(deadline: deadline)
    }

    private func scheduleHeartbeat() {
        guard renderedInput != nil, pendingInput == nil, !isComputing, let lastRenderUptime else { return }
        startTask(deadline: lastRenderUptime &+ 1_000_000_000)
    }

    private func startTask(deadline: UInt64) {
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
            guard let self, self.workID == expectedWork, let job = self.makeJob() else { return }
            self.isComputing = true
            do {
                let frame = try await self.builder.make(
                    input: job.input,
                    size: job.size,
                    presentationTimeStamp: job.presentationTimeStamp
                )
                self.finish(frame, job: job, workID: expectedWork)
            } catch {
                self.finishBuildFailure(error, workID: expectedWork)
            }
        }
    }

    private func makeJob() -> RenderJob? {
        guard let activeSessionID, let input = pendingInput ?? renderedInput else { return nil }
        return RenderJob(
            sessionID: activeSessionID,
            input: input,
            size: renderSize,
            presentationTimeStamp: nextPTS(now: clock.now().uptimeNanoseconds)
        )
    }

    private func finish(_ frame: SubtitleFrame, job: RenderJob, workID: UInt64) {
        isComputing = false
        guard self.workID == workID, activeSessionID == job.sessionID else {
            schedulePending()
            return
        }
        do {
            try output.enqueue(frame)
            renderedInput = job.input
            if pendingInput == job.input { pendingInput = nil }
            lastRenderUptime = clock.now().uptimeNanoseconds
            if pendingInput == nil {
                scheduleHeartbeat()
            } else {
                schedulePending()
            }
        } catch {
            let failure = error as? FailureCode ?? .pipFailed
            clear()
            onFailure?(failure)
        }
    }

    private func finishBuildFailure(_ error: any Error, workID: UInt64) {
        isComputing = false
        guard self.workID == workID else {
            schedulePending()
            return
        }
        let failure = error as? FailureCode ?? .pipFailed
        clear()
        onFailure?(failure)
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
