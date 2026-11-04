#if DEBUG && !targetEnvironment(simulator)
#if !G0_HOST_CHECK
@testable import LiveSubtitle
#endif
import Foundation
import ScreenCaptureKit
import OSLog

enum G0CaptureEvent: Sendable {
    case startCompleted(Int?)
    case stopCompleted(Int?)
    case cancelled
    case failed(Int?)
}

/// Nonisolated SDK ownership island. The SDK calls this NSObject directly on
/// its XPC queue. It is deliberately NOT Sendable and never enters a Task.
/// All mutable state is locked. Completion blocks capture only Sendable values.
final class G0CaptureCore: NSObject, SCContentSharingPickerObserver {
    private enum Phase { case idle, starting, running, stopping, stopped }
    private let lock = NSLock()
    private var stream: SCStream?
    private var phase = Phase.idle
    private var active = true
    private var handler: (@Sendable (G0CaptureEvent) -> Void)?
    private var stopWaiters: [@Sendable () -> Void] = []
    private let inbox: G0AudioInbox
    private let identity: SessionIdentity
    private let output: G0CaptureOutput

    init(inbox: G0AudioInbox, identity: SessionIdentity) {
        self.inbox = inbox
        self.identity = identity
        output = G0CaptureOutput(inbox: inbox, identity: identity)
    }

    func setHandler(_ handler: @escaping @Sendable (G0CaptureEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        emit(.cancelled)
    }
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        emit(.failed((error as NSError).code))
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for oldStream: SCStream?) {
        let callback = lock.withLock { () -> (@Sendable (G0CaptureEvent) -> Void)? in
            guard active, phase == .idle, inbox.accepts(identity) else { return nil }
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
                                        sampleHandlerQueue: DispatchQueue(label: "LiveSubtitle.G0.audio"))
        } catch {
            callback(.startCompleted((error as NSError).code))
            return
        }
        Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Capture").notice("stream_start_requested")
        capture.startCapture { error in
            callback(.startCompleted((error as NSError?)?.code))
        }
    }

    /// Called synchronously by the UI driver after receiving a value event.
    /// Always process this even if the UI session has already been invalidated.
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
            return active && inbox.accepts(identity)
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
        let command = lock.withLock { () -> (SCStream, @Sendable (G0CaptureEvent) -> Void)? in
            switch phase {
            case .starting, .stopping:
                return nil // Wait for the pending SDK completion.
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
            callback(.stopCompleted((error as NSError?)?.code))
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
        if let code {
            Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Capture").error("stream_stop_error code=\(code)")
        }
        waiters.forEach { $0() }
    }

    private func emit(_ event: G0CaptureEvent) {
        let callback = lock.withLock { active && inbox.accepts(identity) ? handler : nil }
        callback?(event)
    }
}
#endif
