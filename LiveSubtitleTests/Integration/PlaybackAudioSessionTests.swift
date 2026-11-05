import Foundation
import Testing
@testable import LiveSubtitle

@MainActor
private final class PlaybackSessionProbe: PlaybackAudioSessionManaging {
    var active = false
    var activations = 0
    var deactivations = 0
    var failure = false
    func activate() throws {
        activations += 1
        if failure { throw FailureCode.unavailable }
        active = true
    }
    func deactivate() { deactivations += 1; active = false }
}

@MainActor
private final class PlaybackCaptureProbe: AudioSource {
    let playback: PlaybackSessionProbe
    var stops = 0
    var starts = 0
    var activeAtStart = false
    var failure = false
    init(_ playback: PlaybackSessionProbe) { self.playback = playback }
    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        starts += 1
        activeAtStart = playback.active
        if failure { throw CancellationError() }
        return AsyncStream(bufferingPolicy: .bufferingOldest(1)) { $0.finish() }
    }
    func stop() async { stops += 1 }
}

@MainActor
struct PlaybackAudioSessionTests {
    private func config() -> CaptureConfig {
        CaptureConfig(identity: task11Identity(), sourceLanguage: .init(rawValue: "en-US"))
    }
    @Test func testPlaybackActiveBeforePickerAndReleasedOnStop() async throws {
        let playback = PlaybackSessionProbe()
        let capture = PlaybackCaptureProbe(playback)
        let scope = CaptureLifecycleScope()
        let source = LifecycleAudioSource(base: capture, scope: scope, playbackSession: playback, mayStart: { true })
        _ = try await source.start(config: config())
        #expect(capture.activeAtStart)
        #expect(playback.active)
        await source.stop()
        #expect(!playback.active)
        #expect(playback.deactivations == 1)
        #expect(scope.sessionID == nil)
        await source.stop()
        #expect(playback.deactivations == 1)
    }
    @Test func testPickerCancellationReleasesPlayback() async throws {
        let playback = PlaybackSessionProbe()
        let capture = PlaybackCaptureProbe(playback)
        capture.failure = true
        let scope = CaptureLifecycleScope()
        let source = LifecycleAudioSource(base: capture, scope: scope, playbackSession: playback, mayStart: { true })
        do { _ = try await source.start(config: config()); Issue.record("Expected picker cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(playback.activations == 1)
        #expect(playback.deactivations == 1)
        #expect(!playback.active)
        #expect(scope.sessionID == nil)
    }
    @Test(arguments: [false, true])
    func testCaptureWaitsForForegroundAndCanBeStopped(stopWhileWaiting: Bool) async throws {
        let playback = PlaybackSessionProbe()
        let capture = PlaybackCaptureProbe(playback)
        let scope = CaptureLifecycleScope()
        let clock = Task10Clock()
        var active = false
        let source = LifecycleAudioSource(base: capture, scope: scope, playbackSession: playback,
            clock: clock, foregroundIsActive: { active }, mayStart: { true })
        var completed = false
        let start = Task { @MainActor in
            do { _ = try await source.start(config: config()); completed = true; return true }
            catch { return false }
        }
        try await task10Eventually("capture waits for foreground") { @Sendable in clock.waiterCount == 1 }
        #expect(capture.starts == 1)
        #expect(!completed)
        if stopWhileWaiting { await source.stop() }
        active = true
        clock.advance(toMilliseconds: 50)
        let succeeded = await start.value
        #expect(succeeded == !stopWhileWaiting)
        #expect(completed == !stopWhileWaiting)
        if !stopWhileWaiting { await source.stop() }
        #expect(capture.stops == 1)
        #expect(playback.deactivations == 1)
        #expect(scope.sessionID == nil)
        #expect(clock.waiterCount == 0)
    }

    @Test func testTaskCancellationWhileWaitingReleasesStartedCapture() async throws {
        let playback = PlaybackSessionProbe()
        let capture = PlaybackCaptureProbe(playback)
        let scope = CaptureLifecycleScope()
        let clock = Task10Clock()
        let source = LifecycleAudioSource(base: capture, scope: scope, playbackSession: playback,
            clock: clock, foregroundIsActive: { false }, mayStart: { true })
        let start = Task { @MainActor in
            do { _ = try await source.start(config: config()); return false }
            catch { return error is CancellationError }
        }
        try await task10Eventually("capture waiter installed") { @Sendable in clock.waiterCount == 1 }
        start.cancel()
        #expect(await start.value)
        #expect(capture.stops == 1)
        #expect(playback.deactivations == 1)
        #expect(scope.sessionID == nil)
        #expect(clock.waiterCount == 0)
    }

    @Test func testActivationFailureDoesNotStartCapture() async throws {
        let playback = PlaybackSessionProbe()
        playback.failure = true
        let capture = PlaybackCaptureProbe(playback)
        let scope = CaptureLifecycleScope()
        let source = LifecycleAudioSource(base: capture, scope: scope, playbackSession: playback, mayStart: { true })
        do { _ = try await source.start(config: config()); Issue.record("Expected activation failure") }
        catch let code as FailureCode { #expect(code == .unavailable) }
        #expect(capture.starts == 0)
        #expect(scope.sessionID == nil)
    }
}
