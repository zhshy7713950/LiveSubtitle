import Foundation
import Synchronization
#if !TASK10_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

func checkFallbackLocksAndEpochAcknowledgement() async throws {
    let rig = try await task10MakeRig()
    let first = task10Segment()
    await rig.scheduler.submit(first)
    try await task10Eventually("initial AI job did not start") { await rig.ai.receivedJobs.count == 1 }
    let failedJob = await rig.ai.receivedJobs[0]
    await rig.ai.fail(failedJob, reason: .network)
    try await task10Eventually("current failure did not request fallback") {
        await task10Fallbacks(rig.collector.events).count == 1
    }

    let latest = task10Segment(text: "latest pending segment")
    rig.clock.advance(toMilliseconds: 100)
    await rig.scheduler.submit(latest)
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 1, "AI started while fallback acknowledgement was pending")
    try task10Require(await rig.local.receivedJobs.isEmpty, "local job started before identity acknowledgement")

    let fallbackIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 3)
    try await rig.scheduler.setMode(.localFallback, identity: fallbackIdentity, config: rig.config, profile: nil)
    try await task10Eventually("acknowledged fallback did not start the latest local segment") {
        await rig.local.receivedJobs.count == 1
    }
    let localJob = await rig.local.receivedJobs[0]
    try task10Require(localJob.segmentID == latest.segmentID && localJob.identity == fallbackIdentity,
                      "fallback used an old segment or unacknowledged identity")
    try task10Require(localJob.cloudProfile == nil, "localFallback job retained a cloud target")
    await rig.local.succeed(localJob)

    let afterFallback = task10Segment()
    await rig.scheduler.submit(afterFallback)
    try await task10Eventually("new segment did not stay local after fallback") { await rig.local.receivedJobs.count == 2 }
    try task10Require(await rig.ai.receivedJobs.count == 1, "a new segment automatically restored AI")

    let restoredIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 4)
    try await rig.scheduler.setMode(.ai, identity: restoredIdentity, config: rig.config, profile: rig.profile)
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 1, "explicit AI restore replayed old segments")
    await rig.scheduler.submit(task10Segment())
    try await task10Eventually("explicit AI restore did not enable a future segment") { await rig.ai.receivedJobs.count == 2 }
    try task10Require(await task10Fallbacks(rig.collector.events).count == 1, "fallback was requested more than once")
    await task10Stop(rig)
}

func checkStopLeavesZeroNewJobs() async throws {
    let rig = try await task10MakeRig()
    for _ in 0..<4 { await rig.scheduler.submit(task10Segment()) }
    try await task10Eventually("jobs did not start before stop") { await rig.ai.receivedJobs.count == 2 }
    await rig.scheduler.stop()
    await rig.consumer.value
    let stoppedCount = await rig.ai.receivedJobs.count
    await rig.scheduler.submit(task10Segment())
    rig.clock.advance(toMilliseconds: 10_000)
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == stoppedCount, "stop allowed a queued or new job to start")
    try task10Require(await rig.collector.finished, "stop did not finish the scheduling stream")
    try task10Require(await rig.ai.cancelAllCount > 0, "stop did not cancel AI translator work")
    await rig.scheduler.stop()

    let newIdentity = task10Identity(sessionID: UUID(), engineEpoch: 0)
    let newStream = try await rig.scheduler.start(identity: newIdentity, config: rig.config, profile: rig.profile)
    let newCollector = Task10EventCollector()
    let newConsumer = Task { await newCollector.consume(newStream) }
    rig.clock.advance(toMilliseconds: 20_000)
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == stoppedCount, "a new session replayed expired old work")
    await rig.scheduler.submit(task10Segment())
    try await task10Eventually("new session did not accept new work") { await rig.ai.receivedJobs.count == stoppedCount + 1 }
    await rig.scheduler.stop()
    await newConsumer.value
}

func checkProfileSnapshotAtSubmission() async throws {
    let ai = Task10Translator()
    let local = Task10Translator()
    let scheduler = TranslationScheduler(aiTranslator: ai, localTranslator: local, clock: Task10Clock())
    let identity = task10Identity()
    let profile = task10Profile()
    let config = task10Config(profileID: profile.id)

    do {
        _ = try await scheduler.start(identity: identity, config: config, profile: nil)
        throw Task10CheckFailure(message: "AI start accepted a missing profile")
    } catch let code as FailureCode {
        try task10Require(code == .invalidConfiguration, "missing profile returned the wrong safe error")
    }
    do {
        _ = try await scheduler.start(identity: identity, config: config, profile: task10Profile(revision: 99))
        throw Task10CheckFailure(message: "AI start accepted a profile ID mismatch")
    } catch let code as FailureCode {
        try task10Require(code == .invalidConfiguration, "profile ID mismatch returned the wrong safe error")
    }
    do {
        _ = try await scheduler.start(identity: identity, config: config, profile: task10Profile(id: profile.id, revision: 99))
        throw Task10CheckFailure(message: "AI start accepted a revision mismatch")
    } catch let code as FailureCode {
        try task10Require(code == .invalidConfiguration, "profile revision mismatch returned the wrong safe error")
    }

    let stream = try await scheduler.start(identity: identity, config: config, profile: profile)
    let collector = Task10EventCollector()
    let consumer = Task { await collector.consume(stream) }
    await scheduler.submit(task10Segment())
    try await task10Eventually("snapshotted AI job did not start") { await ai.receivedJobs.count == 1 }
    let first = await ai.receivedJobs[0]
    try task10Require(first.cloudProfile == profile, "AI job did not freeze the submitted profile")

    let replacementProfile = task10Profile(revision: 4)
    let replacementIdentity = task10Identity(sessionID: identity.sessionID, engineEpoch: 3, cloudConfigRevision: 4)
    let replacementConfig = task10Config(profileID: replacementProfile.id)
    try await scheduler.setMode(.ai, identity: replacementIdentity, config: replacementConfig, profile: replacementProfile)
    try task10Require(await ai.receivedJobs[0].cloudProfile == profile, "later configuration mutated an existing job")
    do {
        try await scheduler.setMode(.ai, identity: replacementIdentity, config: replacementConfig, profile: profile)
        throw Task10CheckFailure(message: "setMode accepted a mismatched profile")
    } catch let code as FailureCode {
        try task10Require(code == .invalidConfiguration, "setMode mismatch returned the wrong safe error")
    }
    await scheduler.submit(task10Segment())
    try await task10Eventually("replacement profile job did not start") { await ai.receivedJobs.count == 2 }
    try task10Require(await ai.receivedJobs[1].cloudProfile == replacementProfile,
                      "new submission did not use the acknowledged replacement profile")
    try task10Require(await task10Failed(collector.events).isEmpty, "configuration errors emitted unowned failed events")

    let localIdentity = task10Identity(sessionID: identity.sessionID, engineEpoch: 4, cloudConfigRevision: 4)
    try await scheduler.setMode(.local, identity: localIdentity,
                                config: task10Config(mode: .local, profileID: replacementProfile.id), profile: nil)
    await scheduler.submit(task10Segment())
    try await task10Eventually("local job did not start") { await local.receivedJobs.count == 1 }
    try task10Require(await local.receivedJobs[0].cloudProfile == nil, "local job was bound to a cloud profile")
    await scheduler.stop()
    await consumer.value
}

func checkQueuedFailureCarriesJob() async throws {
    let ai = Task10Translator()
    let local = Task10Translator()
    let scheduler = TranslationScheduler(aiTranslator: ai, localTranslator: local, clock: Task10Clock())
    let identity = task10Identity()
    let profile = task10Profile()
    let config = task10Config(profileID: profile.id)
    let stream = try await scheduler.start(identity: identity, config: config, profile: profile)
    let collector = Task10EventCollector()
    let consumer = Task { await collector.consume(stream) }
    let segment = task10Segment(revision: 7)
    await scheduler.submit(segment)
    try await task10Eventually("job for buffered failure did not start") { await ai.receivedJobs.count == 1 }
    let failedJob = await ai.receivedJobs[0]
    await ai.fail(failedJob, reason: .server)
    try await task10Eventually("failure was not processed before mode change") {
        await task10Failed(collector.events).count == 1
    }
    let localIdentity = task10Identity(sessionID: identity.sessionID, engineEpoch: 3)
    try await scheduler.setMode(.local, identity: localIdentity,
                                config: task10Config(mode: .local, profileID: profile.id), profile: nil)
    await scheduler.submit(task10Segment(id: segment.segmentID, revision: 8))
    try await task10Eventually("local job for dropped event did not start") {
        await local.receivedJobs.contains { $0.sourceRevision == 8 }
    }
    let droppedJob = await local.receivedJobs.first { $0.sourceRevision == 8 }!
    await scheduler.submit(task10Segment(id: segment.segmentID, revision: 9))
    try await task10Eventually("replacement local job did not start") {
        await local.receivedJobs.contains { $0.sourceRevision == 9 }
    }

    try await task10Eventually("buffered dropped event was not consumed") {
        let events = await collector.events
        return task10Dropped(events).contains {
            $0.jobID == droppedJob.jobID && $0.identity == localIdentity
        }
    }
    let failures = await task10Failed(collector.events)
    try task10Require(failures.count == 1 && failures[0].job.jobID == failedJob.jobID,
                      "buffered failure lost its original job")
    try task10Require(failures[0].job.identity == identity && failures[0].job.sourceRevision == 7,
                      "buffered failure lost identity or source revision")
    let fallbacks = await task10Fallbacks(collector.events)
    try task10Require(fallbacks.count == 1 && fallbacks[0].identity == identity,
                      "buffered fallback did not carry the failed identity")
    let drops = await task10Dropped(collector.events)
    try task10Require(drops.contains { $0.jobID == droppedJob.jobID && $0.identity == localIdentity },
                      "buffered dropped event lost its original job")
    await scheduler.stop()
    await consumer.value
}

func checkOutputDeliversControlsWithoutConsumer() async throws {
    let output = SchedulingEventOutput()
    let stream = output.makeStream { }
    let identity = task10Identity()
    let profile = task10Profile()
    let segment = task10Segment()
    let first = TranslationJob(jobID: UUID(), identity: identity, segmentID: segment.segmentID,
                               sourceRevision: 0, sourceText: segment.sourceText,
                               sourceLanguage: LanguageIdentifier(rawValue: "en"),
                               targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
                               stability: .provisional, cloudProfile: profile,
                               createdAt: task10Instant(0), deadline: task10Instant(6_000))
    let second = TranslationJob(jobID: UUID(), identity: identity, segmentID: UUID(),
                                sourceRevision: 0, sourceText: segment.sourceText,
                                sourceLanguage: LanguageIdentifier(rawValue: "en"),
                                targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
                                stability: .provisional, cloudProfile: profile,
                                createdAt: task10Instant(0), deadline: task10Instant(6_000))
    _ = output.emit(.failed(job: first, reason: .network))
    _ = output.emit(.fallbackRequested(identity: identity, reason: .network))
    _ = output.emit(.dropped(job: second))
    await task10Flush()

    let collector = Task10EventCollector()
    let consumer = Task { await collector.consume(stream) }
    try await task10Eventually("pre-consumer control events were lost") {
        let events = await collector.events
        return task10Failed(events).contains { $0.job.jobID == first.jobID }
            && task10Fallbacks(events).contains { $0.identity == identity }
            && task10Dropped(events).contains { $0.jobID == second.jobID }
    }
    output.finish()
    await consumer.value
}

func checkOutputControlSaturationIsExplicit() async throws {
    let output = SchedulingEventOutput()
    let identity = task10Identity()
    for _ in 0..<64 {
        let accepted = output.emit(.fallbackRequested(identity: identity, reason: .network))
        try task10Require(accepted, "control reserve filled before its documented capacity")
    }
    let segment = task10Segment()
    let job = TranslationJob(jobID: UUID(), identity: identity, segmentID: segment.segmentID,
                             sourceRevision: 0, sourceText: segment.sourceText,
                             sourceLanguage: LanguageIdentifier(rawValue: "en"),
                             targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
                             stability: .provisional, cloudProfile: task10Profile(),
                             createdAt: task10Instant(0), deadline: task10Instant(6_000))
    let accepted = output.emit(.failed(job: job, reason: .network))
    try task10Require(!accepted, "control saturation silently discarded a terminal event")
    output.finish()
}

func checkClockDeadlineRace() async throws {
    let reads = Mutex(0)
    let clock = SchedulingSystemClock {
        let read = reads.withLock { value -> Int in
            value += 1
            return value
        }
        return MonotonicInstant(uptimeNanoseconds: read == 1 ? 999 : 1_001)
    }
    try await clock.sleep(until: MonotonicInstant(uptimeNanoseconds: 1_000))
}

func checkOldStreamCancellationDoesNotStopRestart() async throws {
    let ai = Task10Translator()
    let scheduler = TranslationScheduler(aiTranslator: ai, localTranslator: Task10Translator(), clock: Task10Clock())
    let profile = task10Profile()
    for _ in 0..<20 {
        let identityA = task10Identity()
        let streamA = try await scheduler.start(identity: identityA, config: task10Config(profileID: profile.id), profile: profile)
        let collectorA = Task10EventCollector()
        let consumerA = Task { await collectorA.consume(streamA) }
        await task10Flush()
        consumerA.cancel()
        let identityB = task10Identity()
        let streamB = try await scheduler.start(identity: identityB, config: task10Config(profileID: profile.id), profile: profile)
        let collectorB = Task10EventCollector()
        let consumerB = Task { await collectorB.consume(streamB) }
        let expected = await ai.receivedJobs.count + 1
        await scheduler.submit(task10Segment())
        try await task10Eventually("old stream cancellation stopped the replacement session") {
            await ai.receivedJobs.count == expected
        }
        await scheduler.stop()
        await consumerA.value
        await consumerB.value
    }
}

func checkSetModeAfterStopRejected() async throws {
    let rig = try await task10MakeRig()
    await task10Stop(rig)
    do {
        try await rig.scheduler.setMode(.ai, identity: rig.identity, config: rig.config, profile: rig.profile)
        throw Task10CheckFailure(message: "setMode reopened a stopped scheduler")
    } catch let code as FailureCode {
        try task10Require(code == .invalidConfiguration, "stopped setMode returned the wrong error")
    }
    await rig.scheduler.submit(task10Segment())
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.isEmpty, "stopped setMode submitted new translator work")
}

func checkLocalFailureCancelsGeneration() async throws {
    let rig = try await task10MakeRig(mode: .local)
    for _ in 0..<3 { await rig.scheduler.submit(task10Segment()) }
    try await task10Eventually("initial local job did not start") { await rig.local.receivedJobs.count == 1 }
    rig.clock.advance(toMilliseconds: 6_000)
    try await task10Eventually("local deadline did not fail") {
        await !task10Failed(rig.collector.events).isEmpty
    }
    await task10Flush()
    try task10Require(await task10Failed(rig.collector.events).count == 1,
                      "one local terminal failure produced multiple failures")
    try task10Require(await rig.local.receivedJobs.count == 1,
                      "local terminal failure started additional queued work")
    await task10Stop(rig)
}

func checkFallbackCandidateRevalidated() async throws {
    let rig = try await task10MakeRig()
    let segment = task10Segment()
    await rig.scheduler.submit(segment)
    try await task10Eventually("candidate AI job did not start") { await rig.ai.receivedJobs.count == 1 }
    await rig.ai.fail(await rig.ai.receivedJobs[0], reason: .network)
    try await task10Eventually("candidate failure did not request fallback") {
        await task10Fallbacks(rig.collector.events).count == 1
    }
    await rig.ai.suspendCancelAll()
    await rig.local.suspendCancelAll()
    let aiCancelBaseline = await rig.ai.cancelAllCount
    let localCancelBaseline = await rig.local.cancelAllCount
    let nextIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 3)
    let modeTask = Task {
        try await rig.scheduler.setMode(.localFallback, identity: nextIdentity, config: rig.config, profile: nil)
    }
    try await task10Eventually("setMode did not suspend in AI cleanup") {
        await rig.ai.cancelAllCount == aiCancelBaseline + 1
    }
    await rig.scheduler.retainOnly(segmentIDs: [])
    await rig.ai.releaseCancelAll()
    try await task10Eventually("setMode did not suspend in local cleanup") {
        await rig.local.cancelAllCount == localCancelBaseline + 1
    }
    await rig.local.releaseCancelAll()
    try await modeTask.value
    await task10Flush()
    try task10Require(await rig.local.receivedJobs.isEmpty,
                      "setMode revived a candidate evicted during cleanup")
    await task10Stop(rig)
}

#if !TASK10_HOST_CHECK
struct FallbackTests {
    @Test func testFallbackLocksAndEpochAcknowledgement() async throws {
        try await checkFallbackLocksAndEpochAcknowledgement()
    }
    @Test func testStopLeavesZeroNewJobs() async throws { try await checkStopLeavesZeroNewJobs() }
    @Test func testProfileSnapshotAtSubmission() async throws { try await checkProfileSnapshotAtSubmission() }
    @Test func testQueuedFailureCarriesJob() async throws { try await checkQueuedFailureCarriesJob() }
    @Test func testOutputDeliversControlsWithoutConsumer() async throws {
        try await checkOutputDeliversControlsWithoutConsumer()
    }
    @Test func testOldStreamCancellationDoesNotStopRestart() async throws {
        try await checkOldStreamCancellationDoesNotStopRestart()
    }
    @Test func testSetModeAfterStopRejected() async throws { try await checkSetModeAfterStopRejected() }
    @Test func testLocalFailureCancelsGeneration() async throws { try await checkLocalFailureCancelsGeneration() }
    @Test func testOutputControlSaturationIsExplicit() async throws {
        try await checkOutputControlSaturationIsExplicit()
    }
    @Test func testFallbackCandidateRevalidated() async throws { try await checkFallbackCandidateRevalidated() }
}
#endif
