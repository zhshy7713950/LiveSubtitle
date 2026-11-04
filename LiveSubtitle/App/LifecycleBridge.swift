import AVFAudio
import Foundation
import UIKit

enum LifecycleEvent: Sendable {
    case deviceLocked, interrupted, thermalPressure, background
}

extension SessionCoordinator {
    /// The check and entry into stop run on the coordinator's own actor.
    func stop(reason: StopReason, ifSessionID sessionID: UUID) async {
        guard currentStatus.identity?.sessionID == sessionID else { return }
        await stop(reason: reason)
    }
}

@MainActor
final class LifecycleBridge {
    private let session: SessionCoordinator
    private let diagnostics: any DiagnosticsRecording
    private let clock: any MonotonicClock
    private let pip: LifecyclePiPController?
    private var statusTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let captureScope: CaptureLifecycleScope
    private var stoppingAt: MonotonicInstant?

    init(session: SessionCoordinator, diagnostics: any DiagnosticsRecording,
         clock: any MonotonicClock = SystemMonotonicClock(), pip: LifecyclePiPController? = nil,
         captureScope: CaptureLifecycleScope = CaptureLifecycleScope()) {
        self.session = session
        self.diagnostics = diagnostics
        self.clock = clock
        self.pip = pip
        self.captureScope = captureScope
    }

    func startObserving() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self, session] in
            let statuses = await session.statuses()
            for await status in statuses {
                guard !Task.isCancelled, let self else { return }
                await self.diagnostics.record(.phase(status.phase))
                if let failure = status.failure { await self.diagnostics.record(.failure(failure)) }
                if status.phase == .stopping { self.stoppingAt = self.clock.now() }
                if status.phase == .idle || status.phase == .failed, let start = self.stoppingAt {
                    self.stoppingAt = nil
                    let end = self.clock.now().uptimeNanoseconds
                    await self.diagnostics.record(.stageLatency(stage: .stop,
                        nanoseconds: end >= start.uptimeNanoseconds ? end - start.uptimeNanoseconds : 0))
                }
                if status.phase == .running, ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical,
                   let id = status.identity?.sessionID {
                    await self.handle(.thermalPressure, sessionID: id)
                }
            }
        }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { _ in .deviceLocked }
        observe(AVAudioSession.didBecomeInactiveNotification) { _ in .interrupted }
        observe(ProcessInfo.thermalStateDidChangeNotification) { _ in
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical: .thermalPressure
            default: nil
            }
        }
        observe(UIApplication.didEnterBackgroundNotification) { _ in .background }
    }

    func handle(_ event: LifecycleEvent, sessionID: UUID) async {
        switch event {
        case .background:
            await pip?.resumeAfterRestoration(sessionID: sessionID)
        case .deviceLocked: await session.stop(reason: .deviceLocked, ifSessionID: sessionID)
        case .interrupted: await session.stop(reason: .interrupted, ifSessionID: sessionID)
        case .thermalPressure: await session.stop(reason: .thermalPressure, ifSessionID: sessionID)
        }
    }

    private func observe(_ name: Notification.Name, map: @escaping @Sendable (Notification) -> LifecycleEvent?) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard let event = map(notification) else { return }
            // Only the Sendable event enters MainActor; Notification remains in its callback.
            MainActor.assumeIsolated {
                guard let self, let id = self.captureScope.sessionID else { return }
                Task { [weak self] in await self?.handle(event, sessionID: id) }
            }
        }
        observers.append(observer)
    }

    func stopObserving() {
        statusTask?.cancel()
        statusTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    isolated deinit {
        statusTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
