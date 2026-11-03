import Foundation
#if SESSION_HOST_CHECK
#else
import Testing
@testable import LiveSubtitle
#endif

func testStopInvalidatesBeforeCancellation() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let identity = try await sessionUnwrapIdentity(rig.coordinator)
    let segment = makeCaptionSegment()
    await rig.segmenter.emit(.upsert(segment))
    try await sessionEventually("segment was not submitted") {
        await rig.scheduler.submittedSegments.count == 1
    }

    await rig.scheduler.suspendStop()
    let stopTask = Task { await rig.coordinator.stop(reason: .user) }
    try await sessionEventually("stop did not invalidate synchronously") {
        await rig.coordinator.currentStatus.phase == .stopping
    }
    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    let job = makeTranslationJob(identity: identity, segment: segment, cloudProfile: profile)
    await rig.scheduler.emit(.translation(job: job, update: makeTranslationUpdate(job: job, provider: .ai)))
    await Task.yield()
    try sessionRequire(await rig.scheduler.submittedSegments.count == 1, "stop accepted a new segment")
    try sessionRequire(await rig.store.appliedUpdates.isEmpty, "stop accepted a translation")
    try await sessionEventually("scheduler stop gate was not armed") {
        await rig.scheduler.stopCount == 1
    }

    await rig.scheduler.releaseStop()
    await stopTask.value
    try sessionRequire(await rig.coordinator.currentStatus.phase == .idle, "stop did not finish")
}

func testRepeatedStopReleasesOnce() async throws {
    let rig = await SessionTestRig.make()
    await rig.prepareAndStart()
    let identity = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.scheduler.suspendStop()
    let first = Task { await rig.coordinator.stop(reason: .user) }
    let second = Task { await rig.coordinator.stop(reason: .captureEnded) }
    try await sessionEventually("stop did not begin") {
        await rig.scheduler.stopCount == 1
    }
    await rig.speech.emit(.failed(.speechFailed))
    await rig.pip.emit(.closed(sessionID: identity.sessionID))
    await rig.scheduler.releaseStop()
    await first.value
    await second.value

    try sessionRequire(await rig.scheduler.stopCount == 1, "scheduler released more than once")
    try sessionRequire(await rig.audioSource.stopCount == 1, "capture released more than once")
    try sessionRequire(await rig.speech.cancelCount == 1, "speech released more than once")
    try sessionRequire(await rig.store.clearCount == 1, "store cleared more than once")
    try sessionRequire(await rig.pip.stoppedSessionIDs == [identity.sessionID], "PiP released more than once")
}

func testOldSessionCallbacksCannotAffectRestart() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let oldIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.scheduler.emit(.fallbackRequested(identity: oldIdentity, reason: .network))
    try await sessionEventually("fallback did not begin") {
        await rig.coordinator.currentStatus.effectiveMode == .localFallback
    }
    await rig.connectionTester.suspend()
    let oldRestore = Task { await rig.coordinator.restoreAI() }
    try await sessionEventually("connection test did not begin") {
        await rig.connectionTester.testedProfiles.count == 1
    }
    await rig.coordinator.stop(reason: .user)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let newIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    try sessionRequire(newIdentity.sessionID != oldIdentity.sessionID, "restart reused sessionID")

    await rig.pip.emit(.closed(sessionID: oldIdentity.sessionID), at: 0)
    await rig.speech.emit(.failed(.speechFailed), at: 0)
    await rig.scheduler.emit(.fallbackRequested(identity: oldIdentity, reason: .network), at: 0)
    await rig.connectionTester.release(.success(()))
    await oldRestore.value
    await Task.yield()

    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.phase == .running, "old callback stopped the new session")
    try sessionRequire(status.identity == newIdentity, "old callback changed the new identity")
    try sessionRequire(status.effectiveMode == .ai, "old test changed the new mode")
}

func testPickerCancellationReturnsReady() async throws {
    let rig = await SessionTestRig.make()
    await MainActor.run { rig.audioSource.cancelStart = true }
    await rig.coordinator.prepare(config: makeSessionConfig())
    await rig.coordinator.start()
    try sessionRequire(await rig.coordinator.currentStatus.phase == .ready, "picker cancellation did not return ready")
    try sessionRequire(await rig.speech.startCount == 0, "picker cancellation started speech")
    try sessionRequire(await rig.pip.startedSessionIDs.isEmpty, "picker cancellation started PiP")

    await MainActor.run { rig.audioSource.cancelStart = false }
    await rig.coordinator.start()
    let oldIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.coordinator.prepare(config: makeSessionConfig(source: "en-US"))
    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.phase == .ready, "language change did not prepare the new selection")
    try sessionRequire(await rig.store.clearCount == 1, "language change retained old captions")
    try sessionRequire(status.identity == nil, "language change kept the old identity active")
    try sessionRequire(oldIdentity.languageEpoch == 1, "initial language epoch should be one")
}

func testFallbackAndManualRecovery() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let initial = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.scheduler.emit(.fallbackRequested(identity: initial, reason: .network))
    try await sessionEventually("fallback did not complete") {
        await rig.coordinator.currentStatus.effectiveMode == .localFallback
    }
    let fallback = try await sessionUnwrapIdentity(rig.coordinator)
    try sessionRequire(fallback.engineEpoch == initial.engineEpoch + 1, "fallback did not increment once")
    try sessionRequire(fallback.languageEpoch == initial.languageEpoch, "fallback changed language epoch")

    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    try await sessionEventually("fallback segment was not submitted") {
        await rig.scheduler.submittedSegments.count == 1
    }
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .localFallback, "new segment re-enabled AI")
    let submittedBeforeRecovery = await rig.scheduler.submittedSegments.count
    await rig.coordinator.restoreAI()
    let recovered = try await sessionUnwrapIdentity(rig.coordinator)
    try sessionRequire(recovered.engineEpoch == fallback.engineEpoch + 1, "manual recovery did not advance engine")
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .ai, "manual recovery did not enable AI")
    try sessionRequire(await rig.scheduler.submittedSegments.count == submittedBeforeRecovery, "recovery replayed old captions")

    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    try await sessionEventually("post-recovery segment was not submitted") {
        await rig.scheduler.submittedSegments.count == submittedBeforeRecovery + 1
    }
}

func testProfileChangeRequiresExplicitAI() async throws {
    let profile = makeCloudProfile(revision: 1)
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let oldIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    let segment = makeCaptionSegment()
    await rig.segmenter.emit(.upsert(segment))
    try await sessionEventually("segment was not stored") {
        await rig.scheduler.submittedSegments.count == 1
    }

    await rig.coordinator.cloudProfileWillChange()
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .local, "profile change did not suspend AI")
    let newProfile = makeCloudProfile(revision: 2)
    try await rig.preferences.saveProfile(newProfile)
    await rig.coordinator.cloudProfileDidChange()
    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.requestedMode == .ai && status.effectiveMode == .local, "didChange enabled AI")
    try sessionRequire(status.identity?.cloudConfigRevision == 2, "new profile revision was not loaded")

    let oldJob = makeTranslationJob(identity: oldIdentity, segment: segment, cloudProfile: profile)
    await rig.scheduler.emit(.translation(job: oldJob, update: makeTranslationUpdate(job: oldJob, provider: .ai)))
    await Task.yield()
    try sessionRequire(await rig.store.appliedUpdates.isEmpty, "old profile job wrote a translation")
}

func testConfigurationMutationBarrier() async throws {
    let profile = makeCloudProfile(revision: 1)
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    await rig.scheduler.suspendSetMode()
    let newProfile = makeCloudProfile(revision: 2)
    let mutation = Task {
        await rig.coordinator.cloudProfileWillChange()
        try await rig.preferences.saveProfile(newProfile)
        await rig.coordinator.cloudProfileDidChange()
    }
    try await sessionEventually("willChange did not reach scheduler") {
        await rig.scheduler.modeCalls.count == 1
    }
    try sessionRequire(await rig.preferences.savedProfiles.isEmpty, "profile saved before cancellation completed")
    await rig.scheduler.releaseSetMode()
    try await mutation.value
    try sessionRequire(await rig.preferences.savedProfiles == [newProfile], "profile did not save after the barrier")
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .local, "didChange restarted AI")
    let modes = await rig.scheduler.modeCalls
    try sessionRequire(modes.allSatisfy { $0.mode == .local && $0.profile == nil }, "mutation exposed a new AI target")
}

func testModeChangeKeepsSpeechStreamAlive() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .local, profileID: profile.id)
    try sessionRequire(await rig.scheduler.startProfiles.count == 1, "local scheduler did not start")
    try sessionRequire(await rig.scheduler.startProfiles[0] == nil, "local scheduler received an AI profile")
    await rig.coordinator.selectMode(.ai)
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .ai, "local to AI failed")
    await rig.coordinator.selectMode(.local)
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .local, "AI to local failed")
    await rig.coordinator.selectMode(.ai)
    let aiIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.scheduler.emit(.fallbackRequested(identity: aiIdentity, reason: .network))
    try await sessionEventually("fallback did not finish") {
        await rig.coordinator.currentStatus.effectiveMode == .localFallback
    }
    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    try await sessionEventually("segment after mode changes was lost") {
        await rig.scheduler.submittedSegments.count == 1
    }
    try sessionRequire(await rig.speech.startCount == 1, "mode change restarted speech")
    try sessionRequire(await rig.segmenter.startCount == 1, "mode change restarted segmenting")
    try sessionRequire(await rig.audioProcessing.processCount == 1, "mode change restarted audio processing")
    await rig.speech.emit(.ended)
    try await sessionEventually("valid speech termination was dropped") {
        await rig.coordinator.currentStatus.phase == .idle
    }
}

func testBufferedOldSchedulerFailureIsIgnored() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let oldIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    let segment = makeCaptionSegment()
    await rig.segmenter.emit(.upsert(segment))
    try await sessionEventually("segment was not submitted") {
        await rig.scheduler.submittedSegments.count == 1
    }
    let oldJob = makeTranslationJob(identity: oldIdentity, segment: segment, cloudProfile: profile)
    await rig.store.suspendSnapshot()
    await rig.scheduler.emit(.failed(job: oldJob, reason: .network))
    await Task.yield()
    await rig.coordinator.selectMode(.local)
    await rig.store.releaseSnapshot()
    await Task.yield()
    let currentIdentity = try await sessionUnwrapIdentity(rig.coordinator)
    try sessionRequire(currentIdentity.engineEpoch == oldIdentity.engineEpoch + 1, "old failure triggered fallback")
    try sessionRequire(await rig.coordinator.currentStatus.phase == .running, "old failure stopped the session")

    let localJob = makeTranslationJob(identity: currentIdentity, segment: segment)
    await rig.scheduler.emit(.failed(job: localJob, reason: .localTranslationFailed))
    try await sessionEventually("valid local failure did not stop") {
        await rig.coordinator.currentStatus.phase == .failed
    }
    try sessionRequire(await rig.coordinator.currentStatus.failure == .localTranslationFailed, "local failure was not readable")
}

func testCurrentSchedulerFailureAfterModeChangeFallsBack() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let segment = makeCaptionSegment()
    await rig.segmenter.emit(.upsert(segment))
    try await sessionEventually("segment was not submitted") {
        await rig.scheduler.submittedSegments.count == 1
    }
    await rig.coordinator.selectMode(.local)
    await rig.coordinator.selectMode(.ai)
    let current = try await sessionUnwrapIdentity(rig.coordinator)
    let job = makeTranslationJob(identity: current, segment: segment, cloudProfile: profile)
    await rig.scheduler.emit(.translation(job: job, update: makeTranslationUpdate(job: job, provider: .ai)))
    try await sessionEventually("current translation was rejected after mode change") {
        await rig.store.appliedUpdates.count == 1
    }
    await rig.scheduler.emit(.failed(job: job, reason: .network))
    try await sessionEventually("current AI failure did not fall back") {
        await rig.coordinator.currentStatus.effectiveMode == .localFallback
    }
    let fallback = try await sessionUnwrapIdentity(rig.coordinator)
    try sessionRequire(fallback.engineEpoch == current.engineEpoch + 1, "current failure did not advance engine")
}

func testConcurrentStartSharesOneStartup() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.coordinator.prepare(config: makeSessionConfig(mode: .ai, profileID: profile.id))
    await rig.preferences.suspendProfileLoads()
    let first = Task { await rig.coordinator.start() }
    let second = Task { await rig.coordinator.start() }
    try await sessionEventually("first profile load did not begin") {
        await rig.preferences.profileLoadCount >= 1
    }
    await rig.preferences.releaseProfileLoads()
    await first.value
    await second.value
    try sessionRequire(await rig.audioSource.startCount == 1, "concurrent start created two capture streams")
    try sessionRequire(await rig.speech.startCount == 1, "concurrent start created two speech streams")
    try sessionRequire(await rig.scheduler.startIdentities.count == 1, "concurrent start created two schedulers")
    try sessionRequire(await rig.pip.startedSessionIDs.count == 1, "concurrent start created two PiP controllers")
    try sessionRequire(await rig.coordinator.currentStatus.phase == .running, "concurrent start did not finish")
}

func testModeChangeDuringStartupDoesNotAbortPipeline() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.coordinator.prepare(config: makeSessionConfig(mode: .ai, profileID: profile.id))
    await MainActor.run { rig.audioSource.suspendNextStart() }
    let start = Task { await rig.coordinator.start() }
    try await sessionEventually("capture start gate was not armed") {
        await rig.audioSource.startCount == 1
    }
    await rig.coordinator.selectMode(.local)
    await MainActor.run { rig.audioSource.releaseStart() }
    await start.value
    try sessionRequire(await rig.coordinator.currentStatus.phase == .running, "startup mode call aborted startup")
    try sessionRequire(await rig.coordinator.currentStatus.effectiveMode == .ai, "startup accepted a mode mutation")
    try sessionRequire(await rig.speech.startCount == 1, "startup left speech unstarted")
    try sessionRequire(await rig.scheduler.startIdentities.count == 1, "startup left scheduler unstarted")
    try sessionRequire(await rig.pip.startedSessionIDs.count == 1, "startup left PiP unstarted")
}

func testOldModeChangeCannotAffectRestart() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .local, profileID: profile.id)
    await rig.preferences.suspendProfileLoads()
    let loadCount = await rig.preferences.profileLoadCount
    let oldOperation = Task { await rig.coordinator.selectMode(.ai) }
    try await sessionEventually("old mode operation did not begin") {
        await rig.preferences.profileLoadCount > loadCount
    }
    await rig.coordinator.stop(reason: .user)
    await rig.preferences.allowNewProfileLoads()
    await rig.prepareAndStart(mode: .local, profileID: profile.id)
    let current = try await sessionUnwrapIdentity(rig.coordinator)
    await rig.preferences.releaseProfileLoads()
    await oldOperation.value
    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.identity == current, "old mode operation changed the restarted identity")
    try sessionRequire(status.requestedMode == .local && status.effectiveMode == .local, "old mode operation changed the restarted mode")
}

func testOldProfileDidChangeCannotAffectRestart() async throws {
    let profile = makeCloudProfile(revision: 1)
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    await rig.preferences.suspendProfileLoads()
    let loadCount = await rig.preferences.profileLoadCount
    let oldOperation = Task { await rig.coordinator.cloudProfileDidChange() }
    try await sessionEventually("old profile operation did not begin") {
        await rig.preferences.profileLoadCount > loadCount
    }
    await rig.coordinator.stop(reason: .user)
    await rig.preferences.allowNewProfileLoads()
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    let current = try await sessionUnwrapIdentity(rig.coordinator)
    try await rig.preferences.saveProfile(makeCloudProfile(revision: 2))
    await rig.preferences.releaseProfileLoads()
    await oldOperation.value
    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.identity == current, "old didChange changed the restarted identity")
    try sessionRequire(status.effectiveMode == .ai, "old didChange forced the restarted session local")
    try sessionRequire(status.identity?.cloudConfigRevision == 1, "old didChange changed the restarted revision")
}

func testStopClearsAfterInflightSegmentWrite() async throws {
    let rig = await SessionTestRig.make()
    await rig.prepareAndStart()
    await rig.store.suspendNextUpsert(releaseOnClear: true)
    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    try await sessionEventually("upsert gate was not armed") {
        await rig.store.upsertCount == 1
    }
    let stop = Task { await rig.coordinator.stop(reason: .user) }
    try await sessionEventually("stop did not begin") {
        await rig.scheduler.stopCount == 1
    }
    for _ in 0..<100 { await Task.yield() }
    await rig.store.releaseUpsert()
    await stop.value
    let oldSnapshot = await rig.store.snapshot(mode: .local, status: .listening)
    try sessionRequire(oldSnapshot?.segments.isEmpty == true, "old upsert completed after final clear")
    await rig.prepareAndStart()
    let newSnapshot = await rig.store.snapshot(mode: .local, status: .listening)
    try sessionRequire(newSnapshot?.segments.isEmpty == true, "old segment polluted the restarted store")
}

func testSetModeCancellationStopsAndReleasesBarrier() async throws {
    let profile = makeCloudProfile()
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .local, profileID: profile.id)
    await rig.scheduler.throwSetMode(CancellationError())
    await rig.coordinator.selectMode(.ai)
    try await sessionEventually("setMode cancellation left the session running") {
        await rig.coordinator.currentStatus.phase == .failed
    }
    await rig.segmenter.emit(.upsert(makeCaptionSegment()))
    await Task.yield()
    try sessionRequire(await rig.scheduler.submittedSegments.isEmpty, "cancelled mode change left a pending-job barrier")
}

func testProfileChangeThenExplicitAIUsesNewRevision() async throws {
    let profile = makeCloudProfile(revision: 1)
    let rig = await SessionTestRig.make(profile: profile)
    await rig.prepareAndStart(mode: .ai, profileID: profile.id)
    await rig.coordinator.cloudProfileWillChange()
    let newProfile = makeCloudProfile(revision: 2)
    try await rig.preferences.saveProfile(newProfile)
    await rig.coordinator.cloudProfileDidChange()
    try sessionRequire(await rig.coordinator.currentStatus.identity?.cloudConfigRevision == 2, "didChange retained stale revision")
    await rig.coordinator.selectMode(.ai)
    let status = await rig.coordinator.currentStatus
    try sessionRequire(status.effectiveMode == .ai, "explicit AI rejected the new profile")
    try sessionRequire(status.identity?.cloudConfigRevision == 2, "explicit AI used stale revision")
    let calls = await rig.scheduler.modeCalls
    try sessionRequire(calls.last?.profile == newProfile, "explicit AI used the old profile")
}

func sessionUnwrapIdentity(_ coordinator: SessionCoordinator) async throws -> SessionIdentity {
    guard let identity = await coordinator.currentStatus.identity else {
        throw SessionTestFailure(message: "missing active identity")
    }
    return identity
}

#if SESSION_HOST_CHECK
@main
private struct SessionHostChecks {
    static func main() async throws {
        let checks: [(String, () async throws -> Void)] = [
            ("testStopInvalidatesBeforeCancellation", testStopInvalidatesBeforeCancellation),
            ("testRepeatedStopReleasesOnce", testRepeatedStopReleasesOnce),
            ("testOldSessionCallbacksCannotAffectRestart", testOldSessionCallbacksCannotAffectRestart),
            ("testPickerCancellationReturnsReady", testPickerCancellationReturnsReady),
            ("testFallbackAndManualRecovery", testFallbackAndManualRecovery),
            ("testProfileChangeRequiresExplicitAI", testProfileChangeRequiresExplicitAI),
            ("testConfigurationMutationBarrier", testConfigurationMutationBarrier),
            ("testModeChangeKeepsSpeechStreamAlive", testModeChangeKeepsSpeechStreamAlive),
            ("testBufferedOldSchedulerFailureIsIgnored", testBufferedOldSchedulerFailureIsIgnored),
            ("testCurrentSchedulerFailureAfterModeChangeFallsBack", testCurrentSchedulerFailureAfterModeChangeFallsBack),
            ("testConcurrentStartSharesOneStartup", testConcurrentStartSharesOneStartup),
            ("testModeChangeDuringStartupDoesNotAbortPipeline", testModeChangeDuringStartupDoesNotAbortPipeline),
            ("testOldModeChangeCannotAffectRestart", testOldModeChangeCannotAffectRestart),
            ("testOldProfileDidChangeCannotAffectRestart", testOldProfileDidChangeCannotAffectRestart),
            ("testStopClearsAfterInflightSegmentWrite", testStopClearsAfterInflightSegmentWrite),
            ("testSetModeCancellationStopsAndReleasesBarrier", testSetModeCancellationStopsAndReleasesBarrier),
            ("testProfileChangeThenExplicitAIUsesNewRevision", testProfileChangeThenExplicitAIUsesNewRevision)
        ]
        var failures: [String] = []
        for (name, check) in checks {
            print("RUN \(name)")
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                print("FAIL \(name): \(error)")
                failures.append(name)
            }
        }
        print("\(checks.count - failures.count)/\(checks.count) Session host checks passed; no SDK/device behavior tested.")
        if !failures.isEmpty {
            throw SessionTestFailure(message: "failed: \(failures.joined(separator: ", "))")
        }
    }
}
#else
struct SessionCoordinatorTests {
    @Test func stopInvalidatesBeforeCancellation() async throws { try await testStopInvalidatesBeforeCancellation() }
    @Test func repeatedStopReleasesOnce() async throws { try await testRepeatedStopReleasesOnce() }
    @Test func oldSessionCallbacksCannotAffectRestart() async throws { try await testOldSessionCallbacksCannotAffectRestart() }
    @Test func pickerCancellationReturnsReady() async throws { try await testPickerCancellationReturnsReady() }
    @Test func fallbackAndManualRecovery() async throws { try await testFallbackAndManualRecovery() }
    @Test func profileChangeRequiresExplicitAI() async throws { try await testProfileChangeRequiresExplicitAI() }
    @Test func configurationMutationBarrier() async throws { try await testConfigurationMutationBarrier() }
    @Test func modeChangeKeepsSpeechStreamAlive() async throws { try await testModeChangeKeepsSpeechStreamAlive() }
    @Test func bufferedOldSchedulerFailureIsIgnored() async throws { try await testBufferedOldSchedulerFailureIsIgnored() }
    @Test func currentSchedulerFailureAfterModeChangeFallsBack() async throws { try await testCurrentSchedulerFailureAfterModeChangeFallsBack() }
    @Test func concurrentStartSharesOneStartup() async throws { try await testConcurrentStartSharesOneStartup() }
    @Test func modeChangeDuringStartupDoesNotAbortPipeline() async throws { try await testModeChangeDuringStartupDoesNotAbortPipeline() }
    @Test func oldModeChangeCannotAffectRestart() async throws { try await testOldModeChangeCannotAffectRestart() }
    @Test func oldProfileDidChangeCannotAffectRestart() async throws { try await testOldProfileDidChangeCannotAffectRestart() }
    @Test func stopClearsAfterInflightSegmentWrite() async throws { try await testStopClearsAfterInflightSegmentWrite() }
    @Test func setModeCancellationStopsAndReleasesBarrier() async throws { try await testSetModeCancellationStopsAndReleasesBarrier() }
    @Test func profileChangeThenExplicitAIUsesNewRevision() async throws { try await testProfileChangeThenExplicitAIUsesNewRevision() }
}
#endif
