import AVFoundation
import Foundation

/// Copies PCM planes before returning to the SDK callback. No media buffer crosses this boundary.
enum AudioPCMBufferCopy {
    static func chunk(
        from buffer: AVAudioPCMBuffer,
        sequence: UInt64,
        capturePTS: AudioTimestamp,
        discontinuity: Bool
    ) throws -> AudioChunk {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard frameCount > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, bytesPerFrame > 0,
              capturePTS.timescale > 0, capturePTS.value >= 0 else {
            throw FailureCode.captureFailed
        }
        let sampleFormat: PCMSampleFormat
        switch format.commonFormat {
        case .pcmFormatFloat32: sampleFormat = .float32
        case .pcmFormatFloat64: sampleFormat = .float64
        case .pcmFormatInt16: sampleFormat = .signedInt16
        case .pcmFormatInt32: sampleFormat = .signedInt32
        default: throw FailureCode.captureFailed
        }
        let expectedPlanes = format.isInterleaved ? 1 : Int(format.channelCount)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard audioBuffers.count == expectedPlanes else { throw FailureCode.captureFailed }
        var planes: [Data] = []
        planes.reserveCapacity(audioBuffers.count)
        for plane in audioBuffers {
            let byteCount = Int(plane.mDataByteSize)
            guard byteCount == frameCount * bytesPerFrame, let bytes = plane.mData else {
                throw FailureCode.captureFailed
            }
            planes.append(Data(bytes: bytes, count: byteCount))
        }
        let pcm = PCMFormat(
            sampleFormat: sampleFormat,
            isInterleaved: format.isInterleaved,
            isBigEndian: format.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            bytesPerFrame: bytesPerFrame
        )
        return AudioChunk(
            sequence: sequence,
            capturePTS: capturePTS,
            frameCount: frameCount,
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            format: pcm,
            ownedPCM: planes,
            discontinuity: discontinuity
        )
    }
}

@MainActor
protocol ScreenCaptureDriving: AnyObject {
    func start(buffer: BoundedAudioEventBuffer, identity: SessionIdentity) async throws
    func stop() async
}

@MainActor
final class ScreenCaptureAudioSource: AudioSource {
    private let driver: (any ScreenCaptureDriving)?
    private var activeBuffer: BoundedAudioEventBuffer?
    private var isActive = false

    init() {
#if os(iOS) && !targetEnvironment(simulator)
        driver = ScreenCaptureDriver()
#else
        driver = nil
#endif
    }

    init(driver: (any ScreenCaptureDriving)?) {
        self.driver = driver
    }

    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        if isActive || activeBuffer != nil { await stop() }
        guard let driver else { throw FailureCode.unavailable }
        let buffer = BoundedAudioEventBuffer()
        activeBuffer = buffer
        do {
            try await driver.start(buffer: buffer, identity: config.identity)
            isActive = true
        } catch {
            buffer.close()
            activeBuffer = nil
            await driver.stop()
            if let error = error as? CancellationError { throw error }
            if let error = error as? FailureCode { throw error }
            throw FailureCode.captureFailed
        }
        return AsyncStream<AudioSourceEvent>(unfolding: {
            await buffer.next()
        }, onCancel: {
            buffer.close()
            Task { await self.stop() }
        })
    }

    func stop() async {
        let shouldStopDriver = isActive || activeBuffer != nil
        activeBuffer?.finish(.ended)
        activeBuffer = nil
        isActive = false
        if shouldStopDriver { await driver?.stop() }
    }
}

#if os(iOS) && !targetEnvironment(simulator)
import ScreenCaptureKit
import Synchronization

private enum ScreenCaptureCoreEvent: Sendable {
    case started(Int?)
    case cancelled
    case failed
    case stopped(Int?)
}

@MainActor
private final class ScreenCaptureDriver: ScreenCaptureDriving {
    private var core: ScreenCaptureCore?
    private var startContinuation: CheckedContinuation<Void, Error>?

    func start(buffer: BoundedAudioEventBuffer, identity: SessionIdentity) async throws {
        if core != nil { await stop() }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw FailureCode.unavailable }
        let core = ScreenCaptureCore(buffer: buffer)
        self.core = core
        core.setHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(core)
        picker.isActive = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            picker.present()
        }
    }

    func stop() async {
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        guard let core else { return }
        let picker = SCContentSharingPicker.shared
        picker.remove(core)
        picker.isActive = false
        await withCheckedContinuation { continuation in
            core.stop { continuation.resume() }
        }
        self.core = nil
    }

    private func handle(_ event: ScreenCaptureCoreEvent) {
        guard let core else { return }
        switch event {
        case .started(let code):
            let started = core.startCompleted(code)
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            if started {
                continuation.resume()
            } else {
                continuation.resume(throwing: FailureCode.captureFailed)
            }
        case .cancelled:
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        case .failed:
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume(throwing: FailureCode.captureFailed)
        case .stopped(let code):
            core.stopCompleted(code)
            self.core = nil
        }
    }
}

/// SDK callbacks enter this locked ownership island directly; SDK objects never enter a Task.
private final class ScreenCaptureCore: NSObject, SCContentSharingPickerObserver {
    private enum Phase { case idle, starting, running, stopping, stopped }

    private let lock = NSLock()
    private let output: ScreenCaptureOutput
    private var stream: SCStream?
    private var phase = Phase.idle
    private var active = true
    private var handler: (@Sendable (ScreenCaptureCoreEvent) -> Void)?
    private var stopWaiters: [@Sendable () -> Void] = []

    init(buffer: BoundedAudioEventBuffer) {
        output = ScreenCaptureOutput(buffer: buffer)
    }

    func setHandler(_ handler: @escaping @Sendable (ScreenCaptureCoreEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        emit(.cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        emit(.failed)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for oldStream: SCStream?
    ) {
        let callback = lock.withLock { () -> (@Sendable (ScreenCaptureCoreEvent) -> Void)? in
            guard active, phase == .idle else { return nil }
            phase = .starting
            return handler
        }
        guard let callback else { return }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 320
        configuration.height = 180
        let capture = SCStream(filter: filter, configuration: configuration, delegate: output)
        lock.withLock { stream = capture }
        do {
            try capture.addStreamOutput(output, type: .audio,
                                        sampleHandlerQueue: DispatchQueue(label: "LiveSubtitle.Audio.capture"))
        } catch {
            callback(.started((error as NSError).code))
            return
        }
        capture.startCapture { error in
            callback(.started((error as NSError?)?.code))
        }
    }

    func startCompleted(_ code: Int?) -> Bool {
        var waiters: [@Sendable () -> Void] = []
        let started = lock.withLock { () -> Bool in
            guard phase == .starting else { return false }
            if code != nil {
                stream = nil
                phase = .stopped
                waiters = stopWaiters
                stopWaiters = []
                return false
            }
            phase = .running
            return active
        }
        waiters.forEach { $0() }
        if code == nil, !started { stopIfNeeded() }
        return started
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        lock.withLock {
            active = false
            stopWaiters.append(completion)
        }
        stopIfNeeded()
    }

    private func stopIfNeeded() {
        var waiters: [@Sendable () -> Void] = []
        let command = lock.withLock { () -> (SCStream, @Sendable (ScreenCaptureCoreEvent) -> Void)? in
            switch phase {
            case .starting, .stopping:
                return nil
            case .running:
                guard let stream, let handler else { return nil }
                phase = .stopping
                return (stream, handler)
            case .idle, .stopped:
                phase = .stopped
                stream = nil
                waiters = stopWaiters
                stopWaiters = []
                handler = nil
                return nil
            }
        }
        waiters.forEach { $0() }
        guard let (capture, callback) = command else { return }
        capture.stopCapture { error in
            callback(.stopped((error as NSError?)?.code))
        }
    }

    func stopCompleted(_ code: Int?) {
        let waiters = lock.withLock {
            stream = nil
            phase = .stopped
            handler = nil
            let waiters = stopWaiters
            stopWaiters = []
            return waiters
        }
        waiters.forEach { $0() }
    }

    private func emit(_ event: ScreenCaptureCoreEvent) {
        let callback = lock.withLock { active ? handler : nil }
        callback?(event)
    }
}

private final class ScreenCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let buffer: BoundedAudioEventBuffer
    private let sequence = Mutex<UInt64>(0)

    init(buffer: BoundedAudioEventBuffer) {
        self.buffer = buffer
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        buffer.finish(.failed(.captureFailed))
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, !buffer.isClosed,
              CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferIsValid(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(formatDescription: description) else {
            buffer.finish(.failed(.captureFailed))
            return
        }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let duration = Double(count) / format.sampleRate
        let limit = Double(RuntimePolicy.audioBufferDuration.components.seconds)
        guard count > 0, format.sampleRate > 0, duration <= limit,
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
              ) else {
            buffer.finish(.failed(.captureFailed))
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(count),
            into: pcmBuffer.mutableAudioBufferList
        ) == noErr else {
            buffer.finish(.failed(.captureFailed))
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else {
            buffer.finish(.failed(.captureFailed))
            return
        }
        do {
            let next = sequence.withLock { value in
                value += 1
                return value
            }
            let chunk = try AudioPCMBufferCopy.chunk(
                from: pcmBuffer,
                sequence: next,
                capturePTS: AudioTimestamp(value: pts.value, timescale: pts.timescale),
                discontinuity: false
            )
            buffer.push(chunk)
        } catch {
            buffer.finish(.failed(.captureFailed))
        }
    }
}
#endif
