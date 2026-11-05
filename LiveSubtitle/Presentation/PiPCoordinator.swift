import CoreGraphics
import Foundation
#if !TASK11_HOST_CHECK
import AVKit
#endif

@MainActor
enum PiPSystemEvent {
    case started
    case stopped
    case restoreRequested((Bool) -> Void)
    case suspended(Bool)
    case failed
    case renderSize(CGSize)
}

@MainActor
protocol PiPSystemAdapting: AnyObject {
    var isSupported: Bool { get }
    var isPossible: Bool { get }
    var isSuspended: Bool { get }
    var eventHandler: ((PiPSystemEvent) -> Void)? { get set }
    func waitUntilPossible() async throws
    func start()
    func stop()
}

@MainActor
func waitForPiPReadiness(clock: any MonotonicClock, isPossible: () -> Bool) async throws {
    func nanoseconds(_ duration: Duration) -> UInt64 {
        UInt64(duration.components.seconds) * 1_000_000_000 + UInt64(duration.components.attoseconds / 1_000_000_000)
    }
    let deadline = clock.now().uptimeNanoseconds + nanoseconds(RuntimePolicy.pipReadinessTimeout)
    while true {
        try Task.checkCancellation()
        let now = clock.now().uptimeNanoseconds
        guard now < deadline else { throw FailureCode.pipFailed }
        if isPossible() { return }
        try await clock.sleep(until: .init(uptimeNanoseconds: min(deadline, now + nanoseconds(RuntimePolicy.pipReadinessPollInterval))))
    }
}

@MainActor
extension PiPSystemAdapting {
    func waitUntilPossible() async throws {
        guard isPossible else { throw FailureCode.pipFailed }
    }
}

@MainActor
final class PiPEventOutput {
    private let limit = 16
    private var continuation: AsyncStream<PiPEvent>.Continuation?
    private var queue: [PiPEvent] = []
    private var draining = false
    private var finishWhenDrained = false
    private var terminated = false

    func makeStream(onCancel: @escaping @MainActor () -> Void) -> AsyncStream<PiPEvent> {
        let (stream, continuation) = AsyncStream<PiPEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.continuation = continuation
        continuation.onTermination = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.invalidate(finish: false)
                if case .cancelled = reason { onCancel() }
            }
        }
        return stream
    }

    func emit(_ event: PiPEvent) -> Bool {
        guard !terminated, !finishWhenDrained else { return false }
        if !event.isTerminal, queue.contains(where: { $0.hasSameKind(as: event) }) {
            return true
        }
        if queue.count >= limit {
            guard event.isTerminal else { return false }
            queue.removeAll()
        }
        queue.append(event)
        if event.isTerminal { finishWhenDrained = true }
        startDrain()
        return true
    }

    func finish() {
        invalidate(finish: true)
    }

    private func startDrain() {
        guard !draining, !terminated else { return }
        draining = true
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !terminated {
            guard let continuation else {
                invalidate(finish: false)
                return
            }
            guard let event = queue.first else {
                draining = false
                if finishWhenDrained { invalidate(finish: true) }
                return
            }
            switch continuation.yield(event) {
            case .enqueued:
                queue.removeFirst()
            case .dropped:
                await Task.yield()
            case .terminated:
                invalidate(finish: false)
                return
            @unknown default:
                invalidate(finish: false)
                return
            }
        }
    }

    private func invalidate(finish: Bool) {
        guard !terminated else { return }
        terminated = true
        draining = false
        queue.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        if finish { continuation?.finish() }
    }
}

private extension PiPEvent {
    var isTerminal: Bool {
        switch self {
        case .closed, .replaced, .failed: true
        case .started, .restoringInterface, .restoredInterface: false
        }
    }

    func hasSameKind(as other: PiPEvent) -> Bool {
        switch (self, other) {
        case (.started, .started),
             (.restoringInterface, .restoringInterface),
             (.restoredInterface, .restoredInterface):
            true
        default:
            false
        }
    }
}

@MainActor
final class PiPCoordinator: PiPControlling {
    private let renderer: SubtitleRenderer
    private let systemFactory: (SubtitleRenderer) -> any PiPSystemAdapting
    private var system: (any PiPSystemAdapting)?
    private var output: PiPEventOutput?
    private var sessionID: UUID?
    private var generation: UInt64 = 0
    private var restoring = false
    private var terminal = false

    #if !TASK11_HOST_CHECK
    convenience init(renderer: SubtitleRenderer) {
        self.init(renderer: renderer, systemFactory: { AVPiPSystemAdapter(layer: $0.displayLayer) })
    }
    #endif

    init(
        renderer: SubtitleRenderer,
        systemFactory: @escaping (SubtitleRenderer) -> any PiPSystemAdapting
    ) {
        self.renderer = renderer
        self.systemFactory = systemFactory
        renderer.onFailure = { [weak self] reason in
            self?.rendererFailed(reason)
        }
    }

    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        generation &+= 1
        let generation = self.generation
        let replacingSameSession = self.sessionID == sessionID
        invalidateCurrent(clearRenderer: !replacingSameSession)

        let system = systemFactory(renderer)
        guard system.isSupported else { throw FailureCode.pipFailed }
        self.system = system
        self.sessionID = sessionID
        renderer.activate(sessionID: sessionID)
        do {
            if !replacingSameSession {
                try await renderer.prepareFirstFrame(sessionID: sessionID)
            }
            try await system.waitUntilPossible()
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
        } catch {
            if self.generation == generation { invalidateCurrent(clearRenderer: true) }
            throw error
        }

        let output = PiPEventOutput()
        let stream = output.makeStream { [weak self] in
            self?.outputCancelled(generation: generation)
        }
        self.system = system
        self.output = output
        self.sessionID = sessionID
        restoring = false
        terminal = false
        renderer.activate(sessionID: sessionID)
        system.eventHandler = { [weak self, weak system] event in
            guard let system else { return }
            self?.receive(event, from: system, generation: generation)
        }
        system.start()
        return stream
    }

    func stop(sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }
        generation &+= 1
        invalidateCurrent(clearRenderer: true)
        await renderer.waitForClear()
    }

    private func invalidateCurrent(clearRenderer: Bool) {
        let previousSessionID = sessionID
        system?.eventHandler = nil
        system?.stop()
        system = nil
        output?.finish()
        output = nil
        sessionID = nil
        restoring = false
        terminal = true
        if clearRenderer {
            if let previousSessionID {
                renderer.deactivate(sessionID: previousSessionID)
            } else {
                renderer.clear()
            }
        }
    }

    private func receive(
        _ event: PiPSystemEvent,
        from system: any PiPSystemAdapting,
        generation: UInt64
    ) {
        guard self.generation == generation, self.system === system,
              let sessionID, !terminal else { return }
        switch event {
        case .started:
            emit(.started(sessionID: sessionID))
        case .renderSize(let size):
            renderer.updateRenderSize(size)
        case .restoreRequested(let completion):
            restoring = true
            guard output?.emit(.restoringInterface(sessionID: sessionID)) == true else {
                restoring = false
                completion(false)
                terminate(.failed(sessionID: sessionID, reason: .pipFailed))
                return
            }
            completion(true)
        case .stopped:
            if restoring {
                restoring = false
                emit(.restoredInterface(sessionID: sessionID))
            } else {
                terminate(system.isSuspended ? .replaced(sessionID: sessionID) : .closed(sessionID: sessionID))
            }
        case .suspended(let suspended):
            if suspended && !restoring {
                terminate(.replaced(sessionID: sessionID))
            }
        case .failed:
            terminate(.failed(sessionID: sessionID, reason: .pipFailed))
        }
    }

    private func emit(_ event: PiPEvent) {
        guard let sessionID else { return }
        if output?.emit(event) == false {
            terminate(.failed(sessionID: sessionID, reason: .pipFailed))
        }
    }

    private func terminate(_ event: PiPEvent?) {
        guard !terminal else { return }
        terminal = true
        restoring = false
        system?.eventHandler = nil
        system?.stop()
        if let sessionID {
            renderer.deactivate(sessionID: sessionID)
        } else {
            renderer.clear()
        }
        if let event {
            _ = output?.emit(event)
        } else {
            output?.finish()
        }
    }

    private func rendererFailed(_ reason: FailureCode) {
        guard let sessionID, !terminal else { return }
        terminate(.failed(sessionID: sessionID, reason: reason))
    }

    private func outputCancelled(generation: UInt64) {
        guard self.generation == generation else { return }
        terminate(nil)
    }
}

#if !TASK11_HOST_CHECK
@MainActor
final class AVPiPSystemAdapter: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate,
                                @preconcurrency AVPictureInPictureControllerDelegate, PiPSystemAdapting {
    private var controller: AVPictureInPictureController?
    private let clock: any MonotonicClock
    private var suspensionObservation: NSKeyValueObservation?
    var eventHandler: ((PiPSystemEvent) -> Void)?

    init(layer: AVSampleBufferDisplayLayer, clock: any MonotonicClock = PresentationSystemClock()) {
        self.clock = clock
        super.init()
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
            controller = AVPictureInPictureController(contentSource: source)
        }
        controller?.delegate = self
        controller?.requiresLinearPlayback = true
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        suspensionObservation = controller?.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, change in
            let suspended = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.eventHandler?(.suspended(suspended))
            }
        }
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    // Initial capture waits for the sharing panel in LifecycleAudioSource.
    // Restored PiP must also be able to restart during the background transition.
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }
    var isSuspended: Bool { controller?.isPictureInPictureSuspended ?? false }

    func waitUntilPossible() async throws {
        try await waitForPiPReadiness(clock: clock) { self.isPossible }
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        eventHandler?(.started)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--validation-metrics") {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            // Closed domain classification and numeric codes only; never localized text/userInfo.
            let domain = failure.domain == AVKitErrorDomain ? "avkit" : "other"
            print("TASK14_METRIC pip_start_domain=\(domain) code=\(failure.code) underlying_code=\(underlying?.code ?? 0)")
        }
        #endif
        eventHandler?(.failed)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        eventHandler?(.stopped)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let eventHandler else {
            completionHandler(false)
            return
        }
        eventHandler(.restoreRequested(completionHandler))
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        let size = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        Task { @MainActor [weak self] in
            self?.eventHandler?(.renderSize(size))
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        completion()
    }
}
#endif
