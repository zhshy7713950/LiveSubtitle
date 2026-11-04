import Foundation
import Testing
@testable import LiveSubtitle

@MainActor
struct IntegrationTests {
    @Test func testLocalModeHasNoSubtitleNetworkTraffic() async throws {
        let rig = IntegrationRig()
        try await rig.start()
        await rig.emit("Local fixture.")
        try await rig.waitForTranslation("Local fixture.")
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == 0)
        #expect(await rig.local.texts == ["Local fixture."])
        await rig.cleanup()

        let blocked = IntegrationRig(blocker: .assetsMissing)
        await blocked.session.prepare(config: blocked.config)
        await blocked.session.start()
        #expect(await blocked.session.currentStatus.failure == .assetsMissing)
        #expect(blocked.source.startCount == 0)
        #expect(blocked.pip.startedSessionIDs.isEmpty)
        #expect(IntegrationTransport.count(host: blocked.profile.endpoint.host!) == 0)
        await blocked.cleanup()
    }

    @Test func testWholeStopAndRapidRestart() async throws {
        let rig = IntegrationRig()
        try await rig.start()
        let old = try #require(await rig.session.currentStatus.identity)
        rig.source.feedPCM()
        try await integrationEventually("PCM did not cross the real audio pipeline") { await rig.speech.receivedFrames > 0 }
        await rig.emit("Before stop.")
        try await rig.waitForTranslation("Before stop.")
        await rig.session.stop(reason: .user)
        #expect(rig.renderer.latest == nil)
        #expect(await rig.captions.snapshot(mode: .local, status: .listening) == nil)
        #expect(await rig.local.texts.isEmpty)
        #expect(await rig.speech.retainedPCM.isEmpty)
        #expect(rig.source.bufferedDuration == 0)
        #expect(rig.source.stopCount == 1)
        #expect(await rig.speech.cancelCount == 1)
        let count = IntegrationTransport.count(host: rig.profile.endpoint.host!)
        await rig.emit("After stop.")
        try await rig.start()
        let new = try #require(await rig.session.currentStatus.identity)
        #expect(old.sessionID != new.sessionID)
        rig.pip.emit(.closed(sessionID: old.sessionID), at: 0)
        await rig.speech.emit(.failed(.speechFailed), at: 0)
        await rig.emit("New session.", stream: 1)
        try await rig.waitForTranslation("New session.")
        #expect(rig.renderer.latest?.segments.count == 1)
        #expect(await rig.session.currentStatus.identity == new)
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == count)
        await rig.cleanup()
    }

    @Test func testLiveDisplayAndProfileChange() async throws {
        let rig = IntegrationRig(mode: .ai)
        try await rig.start()
        await rig.emit("First cloud fixture.")
        try await rig.waitForTranslation("First cloud fixture.")
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == 1)
        let id = try #require(await rig.session.currentStatus.identity?.sessionID)
        await rig.session.setDisplay(.init(displayCount: 1, displayStyle: .translationOnly))
        #expect(rig.renderer.latest?.displayCount == 1)
        #expect(rig.source.startCount == 1)
        await rig.session.cloudProfileWillChange()
        try await rig.credentials.replaceKey("replacement-synthetic-value", profileID: rig.profile.id)
        let newEndpoint = rig.profile.endpoint.deletingLastPathComponent().appendingPathComponent("reconfigured")
        try await rig.preferences.saveProfile(.init(id: rig.profile.id, name: rig.profile.name,
            endpoint: newEndpoint, model: rig.profile.model, revision: 2))
        await rig.session.cloudProfileDidChange()
        #expect(await rig.session.currentStatus.effectiveMode == .local)
        await rig.emit("During local fixture.", at: 2000)
        try await rig.waitForTranslation("During local fixture.")
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == 1)
        await rig.session.selectMode(.ai)
        #expect(await rig.session.currentStatus.effectiveMode == .ai)
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == 1)
        await rig.emit("After explicit AI fixture.", at: 4000)
        try await rig.waitForTranslation("After explicit AI fixture.")
        #expect(IntegrationTransport.count(host: rig.profile.endpoint.host!) == 2)
        #expect(IntegrationTransport.latestURL(host: rig.profile.endpoint.host!) == newEndpoint)
        #expect(await rig.session.currentStatus.identity?.sessionID == id)
        #expect(rig.source.startCount == 1)
        await rig.cleanup()
    }

    @Test func testResourceAndPiPFailuresStopSafely() async throws {
        for event in [LifecycleEvent.deviceLocked, .interrupted, .thermalPressure] {
            let rig = IntegrationRig()
            try await rig.start()
            let id = try #require(await rig.session.currentStatus.identity?.sessionID)
            await rig.lifecycle.handle(event, sessionID: id)
            #expect(await rig.session.currentStatus.phase == .idle)
            #expect(rig.source.stopCount == 1)
            #expect(rig.renderer.latest == nil)
            await rig.cleanup()
        }
        let local = IntegrationRig()
        try await local.start()
        await local.local.fail()
        await local.emit("Failure fixture.")
        try await integrationEventually("local failure did not end session") { await local.session.currentStatus.phase == .failed }
        #expect(local.renderer.latest == nil)
        await local.cleanup()

        let speech = IntegrationRig()
        try await speech.start()
        await speech.speech.emit(.failed(.speechFailed))
        try await integrationEventually("speech failure did not end session") { await speech.session.currentStatus.phase == .failed }
        await speech.cleanup()

        let capture = IntegrationRig()
        try await capture.start()
        capture.source.revoke()
        try await integrationEventually("capture revocation did not stop the real pipeline") {
            await capture.session.currentStatus.phase == .failed
        }
        #expect(await capture.session.currentStatus.failure == .captureFailed)
        #expect(capture.renderer.latest == nil)
        await capture.cleanup()

        for replaced in [true, false] {
            let rig = IntegrationRig()
            try await rig.start()
            let id = try #require(await rig.session.currentStatus.identity?.sessionID)
            rig.pip.emit(replaced ? .replaced(sessionID: id) : .failed(sessionID: id, reason: .pipFailed))
            try await integrationEventually("PiP failure did not end session") {
                let phase = await rig.session.currentStatus.phase
                return phase == .idle || phase == .failed
            }
            #expect(rig.source.stopCount == 1)
            await rig.cleanup()
        }
    }

    @Test func testDiagnosticsHaveNoContent() async throws {
        let rig = IntegrationRig()
        try await rig.start()
        let content = "PRIVATE_CAPTION_SENTINEL."
        await rig.emit(content)
        try await rig.waitForTranslation(content)
        await rig.diagnostics.record(.phase(.running))
        await rig.diagnostics.record(.failure(.network))
        await rig.diagnostics.record(.translationQueued(count: 2))
        await rig.diagnostics.record(.stageLatency(stage: .sourceVisible, nanoseconds: 42))
        let samples = await rig.diagnostics.snapshot()
        let output = samples.map(\.line).joined(separator: "\n")
        #expect(!output.contains(content))
        #expect(!output.contains("本地固定译文"))
        #expect(!output.contains("synthetic-integration-value"))
        #expect(!output.contains(rig.profile.endpoint.absoluteString))
        #expect(output.contains("network"))
        #expect(output.contains("42"))
        for _ in 0..<(RuntimePolicy.diagnosticEventLimit + 10) { await rig.diagnostics.record(.droppedJob) }
        #expect(await rig.diagnostics.snapshot().count == RuntimePolicy.diagnosticEventLimit)
        await rig.session.stop(reason: .user)
        #expect(await rig.diagnostics.snapshot().isEmpty)
        await rig.cleanup()
    }

    @Test func testOldLifecycleEventCannotStopRestart() async throws {
        let rig = IntegrationRig()
        try await rig.start()
        let old = try #require(await rig.session.currentStatus.identity?.sessionID)
        await rig.session.stop(reason: .user)
        try await rig.start()
        await rig.lifecycle.handle(.deviceLocked, sessionID: old)
        #expect(await rig.session.currentStatus.phase == .running)
        await rig.cleanup()
    }

    @Test func testMonotonicClockCancellationAndPastDeadline() async throws {
        let clock = SystemMonotonicClock()
        let first = clock.now()
        try await clock.sleep(until: .init(uptimeNanoseconds: 0))
        #expect(clock.now().uptimeNanoseconds >= first.uptimeNanoseconds)
        let task = Task { try await clock.sleep(until: .init(uptimeNanoseconds: UInt64.max)) }
        task.cancel()
        do { try await task.value; Issue.record("clock ignored cancellation") }
        catch is CancellationError {} catch { Issue.record("unexpected clock error") }
    }
}
