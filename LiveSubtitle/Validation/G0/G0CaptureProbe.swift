#if DEBUG && !targetEnvironment(simulator)
import AVFoundation
import ScreenCaptureKit
import Synchronization

/// All SDK buffers are copied synchronously on the serial output queue.
final class G0CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let inbox: G0AudioInbox
    let identity: SessionIdentity
    private let sequence = Mutex<UInt64>(0)
    init(inbox: G0AudioInbox, identity: SessionIdentity) {
        self.inbox = inbox
        self.identity = identity
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        inbox.fail(identity, code: .captureFailed)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, inbox.accepts(identity) else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferIsValid(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(formatDescription: description) else {
            inbox.fail(identity, code: .captureFailed, invalid: true)
            return
        }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, format.sampleRate > 0,
              Double(count) / format.sampleRate <= Double(RuntimePolicy.audioBufferDuration.components.seconds),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            inbox.fail(identity, code: .captureFailed, invalid: true)
            return
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
            inbox.fail(identity, code: .captureFailed, invalid: true)
            return
        }
        let kind: PCMSampleFormat
        switch format.commonFormat {
        case .pcmFormatFloat32: kind = .float32
        case .pcmFormatFloat64: kind = .float64
        case .pcmFormatInt16: kind = .signedInt16
        case .pcmFormatInt32: kind = .signedInt32
        default:
            inbox.fail(identity, code: .captureFailed, invalid: true)
            return
        }
        var planes: [Data] = []
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let bytes = plane.mData else {
                inbox.fail(identity, code: .captureFailed, invalid: true)
                return
            }
            planes.append(Data(bytes: bytes, count: Int(plane.mDataByteSize)))
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else {
            inbox.fail(identity, code: .captureFailed, invalid: true)
            return
        }
        let pcm = PCMFormat(sampleFormat: kind, isInterleaved: format.isInterleaved,
                            isBigEndian: format.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
                            bytesPerFrame: Int(format.streamDescription.pointee.mBytesPerFrame))
        let next = sequence.withLock { value in value += 1; return value }
        let chunk = AudioChunk(sequence: next, capturePTS: AudioTimestamp(value: pts.value, timescale: pts.timescale),
                               frameCount: count, sampleRate: format.sampleRate, channels: Int(format.channelCount),
                               format: pcm, ownedPCM: planes, discontinuity: false)
        inbox.push(G0AudioPacket(identity: identity, chunk: chunk))
    }
}

/// The picker is a UI callback bridge; the audio delegate above is nonisolated.
@MainActor
final class G0CaptureProbe: NSObject, @preconcurrency SCContentSharingPickerObserver {
    private let inbox: G0AudioInbox
    private let identity: SessionIdentity
    private let output: G0CaptureOutput
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private var active = true
    var onStarted: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onFailure: ((FailureCode) -> Void)?

    init(inbox: G0AudioInbox, identity: SessionIdentity) {
        self.inbox = inbox
        self.identity = identity
        output = G0CaptureOutput(inbox: inbox, identity: identity)
    }

    func present() throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw FailureCode.unavailable }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present() // Full display, never presentForCurrentApplication().
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard active, inbox.accepts(identity) else { return }
        onCancelled?()
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        guard active, inbox.accepts(identity) else { return }
        onFailure?(.captureFailed)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard active, inbox.accepts(identity), self.stream == nil else { return }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 320
        configuration.height = 180
        let capture = SCStream(filter: filter, configuration: configuration, delegate: output)
        self.stream = capture
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "LiveSubtitle.G0.audio"))
                try await capture.startCapture()
                guard active, inbox.accepts(identity), !Task.isCancelled else {
                    try? await capture.stopCapture()
                    return
                }
                onStarted?()
            } catch {
                if active, inbox.accepts(identity), !Task.isCancelled { onFailure?(.captureFailed) }
            }
        }
    }

    func stop() async {
        active = false
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        startTask?.cancel()
        await startTask?.value
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        startTask = nil
    }
}
#endif
