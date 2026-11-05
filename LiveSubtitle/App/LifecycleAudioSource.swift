import Foundation
import UIKit

/// MainActor mirror of an identity received from the coordinator, bound before the picker awaits.
@MainActor
final class CaptureLifecycleScope {
    private(set) var sessionID: UUID?
    func bind(_ id: UUID) { sessionID = id }
    func clear(_ id: UUID?) {
        if sessionID == id { sessionID = nil }
    }
}

@MainActor
final class LifecycleAudioSource: AudioSource {
    private let base: any AudioSource
    private let scope: CaptureLifecycleScope
    private let sampler: RuntimeResourceSampler?
    private let playbackSession: (any PlaybackAudioSessionManaging)?
    private var playbackOwner: UUID?
    private let clock: any MonotonicClock
    private let foregroundIsActive: @MainActor () -> Bool
    private let mayStart: @MainActor () -> Bool

    init(base: any AudioSource, scope: CaptureLifecycleScope, sampler: RuntimeResourceSampler? = nil,
         playbackSession: (any PlaybackAudioSessionManaging)? = nil,
         clock: any MonotonicClock = SystemMonotonicClock(),
         foregroundIsActive: @escaping @MainActor () -> Bool = { true },
         mayStart: @escaping @MainActor () -> Bool = {
             UIApplication.shared.isProtectedDataAvailable &&
             ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
         }) {
        self.clock = clock
        self.foregroundIsActive = foregroundIsActive
        self.playbackSession = playbackSession
        self.sampler = sampler
        self.base = base
        self.scope = scope
        self.mayStart = mayStart
    }

    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        guard mayStart() else { throw FailureCode.unavailable }
        let id = config.identity.sessionID
        scope.bind(id)
        var captureStarted = false
        do {
            try Task.checkCancellation()
            try playbackSession?.activate()
            playbackOwner = id
            await sampler?.start()
            try Task.checkCancellation()
            guard scope.sessionID == id else { throw CancellationError() }
            let stream = try await base.start(config: config)
            captureStarted = true
            // Capture can start while the system sharing panel still covers the app.
            // Keep this user-controlled phase cancellable; PiP's readiness deadline
            // begins only after returning to the foreground, not during user interaction.
            while !foregroundIsActive() {
                try Task.checkCancellation()
                guard scope.sessionID == id else { throw CancellationError() }
                let interval = RuntimePolicy.captureForegroundPollInterval
                let ticks = UInt64(interval.components.seconds) * 1_000_000_000
                    + UInt64(interval.components.attoseconds / 1_000_000_000)
                try await clock.sleep(until: .init(uptimeNanoseconds: clock.now().uptimeNanoseconds + ticks))
            }
            try Task.checkCancellation()
            guard scope.sessionID == id else { throw CancellationError() }
            return stream
        } catch {
            if scope.sessionID == id {
                if captureStarted { await base.stop() }
                await sampler?.stop()
                scope.clear(id)
                releasePlayback(owner: id)
            }
            throw error
        }
    }

    func stop() async {
        let id = scope.sessionID
        scope.clear(id)
        await sampler?.stop()
        await base.stop()
        if let id { releasePlayback(owner: id) }
    }

    private func releasePlayback(owner: UUID) {
        guard playbackOwner == owner else { return }
        playbackOwner = nil
        playbackSession?.deactivate()
    }
}
