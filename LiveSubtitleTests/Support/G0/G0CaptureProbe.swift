#if DEBUG && !targetEnvironment(simulator)
#if !G0_HOST_CHECK
@testable import LiveSubtitle
#endif
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

/// MainActor owns only UI presentation and a synchronous reference to the
/// nonisolated SDK observer. Tasks transport value events, never SDK objects.
@MainActor
final class G0CaptureProbe: NSObject {
    private let inbox: G0AudioInbox
    private let identity: SessionIdentity
    private let core: G0CaptureCore
    var onStarted: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onFailure: ((FailureCode) -> Void)?

    init(inbox: G0AudioInbox, identity: SessionIdentity) {
        self.inbox = inbox
        self.identity = identity
        core = G0CaptureCore(inbox: inbox, identity: identity)
        super.init()
        core.setHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Complete SDK lifecycle transitions before filtering UI events;
                // a cancelled start must still be stopped and release waiters.
                switch event {
                case .stopCompleted(let code):
                    self.core.stopCompleted(code)
                    return
                case .startCompleted(let code):
                    let started = self.core.startCompleted(code)
                    guard self.inbox.accepts(self.identity) else { return }
                    if started { self.onStarted?() }
                    else if code != nil { self.onFailure?(.captureFailed) }
                case .cancelled:
                    guard self.inbox.accepts(self.identity) else { return }
                    self.onCancelled?()
                case .failed:
                    guard self.inbox.accepts(self.identity) else { return }
                    self.onFailure?(.captureFailed)
                }
            }
        }
    }

    func present() throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw FailureCode.unavailable }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(core)
        picker.isActive = true
        picker.present()
    }

    func stop() async {
        let picker = SCContentSharingPicker.shared
        picker.remove(core)
        picker.isActive = false
        await withCheckedContinuation { continuation in
            core.stop { continuation.resume() }
        }
    }
}
#endif
