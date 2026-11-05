import Foundation
import Synchronization
#if !TASK10_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

struct Task10CheckFailure: Error {
    let message: String
}

func task10Require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Task10CheckFailure(message: message) }
}

func task10Eventually(_ message: String, condition: () async -> Bool) async throws {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw Task10CheckFailure(message: message)
}

func task10Flush() async {
    for _ in 0..<20 { await Task.yield() }
}

func task10Instant(_ milliseconds: UInt64) -> MonotonicInstant {
    MonotonicInstant(uptimeNanoseconds: milliseconds * 1_000_000)
}

func task10Identity(
    sessionID: UUID = UUID(),
    languageEpoch: UInt64 = 1,
    engineEpoch: UInt64 = 2,
    cloudConfigRevision: UInt64 = 3
) -> SessionIdentity {
    SessionIdentity(sessionID: sessionID, languageEpoch: languageEpoch,
                    engineEpoch: engineEpoch, cloudConfigRevision: cloudConfigRevision)
}

func task10Config(
    mode: RequestedMode = .ai,
    profileID: UUID? = nil,
    source: String = "en",
    target: String = "zh-Hans"
) -> SessionConfig {
    SessionConfig(sourceLanguage: LanguageIdentifier(rawValue: source),
                  targetLanguage: LanguageIdentifier(rawValue: target), requestedMode: mode,
                  cloudProfileID: profileID, displayCount: 3, displayStyle: .bilingual)
}

func task10Profile(id: UUID = UUID(), revision: UInt64 = 3) -> CloudProfile {
    CloudProfile(id: id, name: "synthetic", endpoint: URL(string: "https://example.invalid/v1/chat/completions")!,
                 model: "synthetic-model", revision: revision)
}

func task10Segment(
    id: UUID = UUID(),
    revision: UInt64 = 0,
    stability: CaptionStability = .provisional,
    text: String = "synthetic source"
) -> CaptionSegment {
    CaptionSegment(segmentID: id, utteranceID: UUID(),
                   audioRange: AudioRange(start: AudioTimestamp(value: 0, timescale: 1_000),
                                          end: AudioTimestamp(value: 1_000, timescale: 1_000)),
                   sourceRevision: revision, sourceText: text, stability: stability, translationState: .pending)
}

func task10Dropped(_ events: [SchedulingEvent]) -> [TranslationJob] {
    events.compactMap { event in
        if case .dropped(let job) = event { return job }
        return nil
    }
}

func task10Failed(_ events: [SchedulingEvent]) -> [(job: TranslationJob, reason: FailureCode)] {
    events.compactMap { event in
        if case .failed(let job, let reason) = event { return (job, reason) }
        return nil
    }
}

func task10Fallbacks(_ events: [SchedulingEvent]) -> [(identity: SessionIdentity, reason: FailureCode)] {
    events.compactMap { event in
        if case .fallbackRequested(let identity, let reason) = event { return (identity, reason) }
        return nil
    }
}

func task10Translations(_ events: [SchedulingEvent]) -> [(job: TranslationJob, update: TranslationUpdate)] {
    events.compactMap { event in
        if case .translation(let job, let update) = event { return (job, update) }
        return nil
    }
}

final class Task10Clock: MonotonicClock, Sendable {
    private struct Waiter: Sendable {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var ticks: UInt64 = 0
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())

    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: state.withLock { $0.ticks })
    }

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func advance(toMilliseconds milliseconds: UInt64) {
        advanceHoldingWaiters(toMilliseconds: milliseconds)
        resumeWaiters()
    }

    func advanceHoldingWaiters(toMilliseconds milliseconds: UInt64) {
        state.withLock { $0.ticks = milliseconds * 1_000_000 }
    }

    func resumeWaiters() {
        let resumed = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            let ready = state.waiters.filter { $0.value.deadline <= state.ticks }
            for id in ready.keys { state.waiters.removeValue(forKey: id) }
            return Array(ready.values.map(\.continuation))
        }
        for continuation in resumed { continuation.resume() }
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeImmediately = state.withLock { state -> Bool in
                    if Task.isCancelled || state.ticks >= deadline.uptimeNanoseconds { return true }
                    state.waiters[id] = Waiter(deadline: deadline.uptimeNanoseconds, continuation: continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.waiters.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}

actor Task10Translator: Translator {
    private var continuations: [UUID: AsyncStream<TranslationUpdate>.Continuation] = [:]
    private var activeIDs: Set<UUID> = []
    private(set) var receivedJobs: [TranslationJob] = []
    private(set) var maximumActive = 0
    private(set) var cancelAllCount = 0
    private var cancelAllSuspensionArmed = false
    private var cancelAllContinuation: CheckedContinuation<Void, Never>?

    var activeCount: Int { activeIDs.count }

    func translate(_ job: TranslationJob) async -> AsyncStream<TranslationUpdate> {
        receivedJobs.append(job)
        activeIDs.insert(job.jobID)
        maximumActive = max(maximumActive, activeIDs.count)
        let (stream, continuation) = AsyncStream<TranslationUpdate>.makeStream(bufferingPolicy: .bufferingOldest(16))
        continuations[job.jobID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.streamTerminated(job.jobID) }
        }
        return stream
    }

    func cancelAll() async {
        cancelAllCount += 1
        for continuation in continuations.values { continuation.finish() }
        if cancelAllSuspensionArmed {
            cancelAllSuspensionArmed = false
            await withCheckedContinuation { continuation in
                cancelAllContinuation = continuation
            }
        }
    }

    func suspendCancelAll() {
        cancelAllSuspensionArmed = true
    }

    func releaseCancelAll() {
        cancelAllContinuation?.resume()
        cancelAllContinuation = nil
    }

    func emit(_ job: TranslationJob, text: String = "synthetic translation", isFinal: Bool,
              failure: FailureCode? = nil) {
        let provider: TranslationProvider = job.cloudProfile == nil ? .local : .ai
        continuations[job.jobID]?.yield(TranslationUpdate(
            jobID: job.jobID, identity: job.identity, segmentID: job.segmentID,
            sourceRevision: job.sourceRevision, text: failure == nil ? text : "", isFinal: isFinal,
            provider: provider, failure: failure
        ))
    }

    func succeed(_ job: TranslationJob, text: String = "synthetic translation") {
        emit(job, text: text, isFinal: true)
        continuations[job.jobID]?.finish()
    }

    func fail(_ job: TranslationJob, reason: FailureCode) {
        emit(job, isFinal: false, failure: reason)
        continuations[job.jobID]?.finish()
    }

    private func streamTerminated(_ jobID: UUID) {
        activeIDs.remove(jobID)
    }
}

actor Task10EventCollector {
    private(set) var events: [SchedulingEvent] = []
    private(set) var finished = false

    func consume(_ stream: AsyncStream<SchedulingEvent>) async {
        for await event in stream { events.append(event) }
        finished = true
    }
}

struct Task10Rig {
    let scheduler: TranslationScheduler
    let ai: Task10Translator
    let local: Task10Translator
    let clock: Task10Clock
    let identity: SessionIdentity
    let config: SessionConfig
    let profile: CloudProfile
    let collector: Task10EventCollector
    let consumer: Task<Void, Never>
}

func task10MakeRig(
    mode: RequestedMode = .ai,
    onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)? = nil
) async throws -> Task10Rig {
    let ai = Task10Translator()
    let local = Task10Translator()
    let clock = Task10Clock()
    let scheduler = TranslationScheduler(aiTranslator: ai, localTranslator: local, clock: clock, onDiagnostic: onDiagnostic)
    let profile = task10Profile()
    let identity = task10Identity()
    let config = task10Config(mode: mode, profileID: profile.id)
    let stream = try await scheduler.start(identity: identity, config: config, profile: mode == .ai ? profile : nil)
    let collector = Task10EventCollector()
    let consumer = Task { await collector.consume(stream) }
    return Task10Rig(scheduler: scheduler, ai: ai, local: local, clock: clock, identity: identity,
                     config: config, profile: profile, collector: collector, consumer: consumer)
}

func task10Stop(_ rig: Task10Rig) async {
    await rig.scheduler.stop()
    await rig.consumer.value
}

final class Task10DiagnosticRecorder: Sendable {
    private struct State {
        var queueCounts: [Int] = []
        var droppedJobs = 0
        var unexpectedEvents = 0
    }

    private let state = Mutex(State())

    var queueCounts: [Int] { state.withLock { $0.queueCounts } }
    var droppedJobs: Int { state.withLock { $0.droppedJobs } }
    var unexpectedEvents: Int { state.withLock { $0.unexpectedEvents } }

    func record(_ event: DiagnosticEvent) {
        state.withLock { state in
            switch event {
            case .translationQueued(let count): state.queueCounts.append(count)
            case .droppedJob: state.droppedJobs += 1
            default: state.unexpectedEvents += 1
            }
        }
    }
}

func checkDiagnosticsReflectQueueMutationsSynchronously() async throws {
    let diagnostics = Task10DiagnosticRecorder()
    let rig = try await task10MakeRig(onDiagnostic: diagnostics.record)
    try task10Require(diagnostics.queueCounts == [0], "start did not synchronously report the empty queue")
    for _ in 0..<7 { await rig.scheduler.submit(task10Segment()) }
    try await task10Eventually("diagnostic fixture did not reach AI concurrency") { await rig.ai.receivedJobs.count == 2 }
    try task10Require(diagnostics.queueCounts.last == 4, "submission returned without reporting four pending jobs")
    try task10Require(diagnostics.droppedJobs == 1, "queue overflow did not synchronously report exactly one dropped job")
    try task10Require(diagnostics.queueCounts.allSatisfy { (0...RuntimePolicy.pendingTranslationLimit).contains($0) },
                      "diagnostics reported an out-of-bounds waiting queue")
    let first = await rig.ai.receivedJobs[0]
    await rig.ai.succeed(first)
    try await task10Eventually("finishing a job did not start a queued job") { await rig.ai.receivedJobs.count == 3 }
    try task10Require(diagnostics.queueCounts.last == 3, "dequeue did not report the remaining pending count")
    await task10Stop(rig)
    try task10Require(diagnostics.queueCounts.last == 0, "stop returned before the waiting queue reported zero")
    try task10Require(diagnostics.unexpectedEvents == 0, "scheduler diagnostic hook emitted unrelated event types")
}

func checkDiagnosticsReportClearedQueueForModeAndFailure() async throws {
    let diagnostics = Task10DiagnosticRecorder()
    let rig = try await task10MakeRig(onDiagnostic: diagnostics.record)
    for _ in 0..<6 { await rig.scheduler.submit(task10Segment()) }
    let localIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 3)
    try await rig.scheduler.setMode(.local, identity: localIdentity,
                                    config: task10Config(mode: .local, profileID: rig.profile.id), profile: nil)
    try task10Require(diagnostics.queueCounts.last == 0, "mode change did not report its cleared queue")
    for _ in 0..<5 { await rig.scheduler.submit(task10Segment()) }
    try await task10Eventually("local diagnostic fixture did not start") { await rig.local.receivedJobs.count == 1 }
    try task10Require(diagnostics.queueCounts.last == 4, "local pending queue was not reported")
    await rig.local.fail(await rig.local.receivedJobs[0], reason: .localTranslationFailed)
    try await task10Eventually("local failure was not processed") { await task10Failed(rig.collector.events).count == 1 }
    try task10Require(diagnostics.queueCounts.last == 4, "unacknowledged failure destroyed pending work")
    let beforeStop = diagnostics.queueCounts.count
    await task10Stop(rig)
    try task10Require(diagnostics.queueCounts.count > beforeStop && diagnostics.queueCounts.last == 0,
                      "stopping an empty queue did not publish a final zero")
    try task10Require(diagnostics.queueCounts.allSatisfy { (0...RuntimePolicy.pendingTranslationLimit).contains($0) },
                      "mode/failure diagnostics exceeded the queue limit")
}

func checkConcurrencyAndQueueBounds() async throws {
    let rig = try await task10MakeRig()
    let segments = (0..<7).map { _ in task10Segment() }
    for segment in segments.prefix(6) { await rig.scheduler.submit(segment) }
    try await task10Eventually("AI concurrency did not reach two") { await rig.ai.receivedJobs.count == 2 }
    await rig.scheduler.submit(segments[6])
    try await task10Eventually("oldest pending job was not dropped") {
        await task10Dropped(rig.collector.events).contains { $0.segmentID == segments[2].segmentID }
    }
    await rig.scheduler.submit(task10Segment(id: segments[3].segmentID, revision: 1, text: "latest revision"))
    try await task10Eventually("superseded pending revision was not dropped") {
        await task10Dropped(rig.collector.events).contains {
            $0.segmentID == segments[3].segmentID && $0.sourceRevision == 0
        }
    }
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 2, "pending replacement started above AI concurrency")

    await rig.scheduler.retainOnly(segmentIDs: [segments[0].segmentID, segments[1].segmentID])
    await rig.scheduler.submit(task10Segment(id: segments[4].segmentID, revision: 9))
    let initialJobs = await rig.ai.receivedJobs
    await rig.ai.succeed(initialJobs[0])
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 2, "an evicted segment was translated")
    try task10Require(await rig.ai.maximumActive <= 2, "AI concurrency exceeded two")
    await rig.ai.succeed(initialJobs[1])

    let nextIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 3)
    let localConfig = task10Config(mode: .local, profileID: rig.profile.id)
    try await rig.scheduler.setMode(.local, identity: nextIdentity, config: localConfig, profile: nil)
    let localSegments = [task10Segment(), task10Segment()]
    await rig.scheduler.retainOnly(segmentIDs: Set(localSegments.map(\.segmentID)))
    for segment in localSegments { await rig.scheduler.submit(segment) }
    try await task10Eventually("local translation did not start") { await rig.local.receivedJobs.count == 1 }
    await task10Flush()
    try task10Require(await rig.local.receivedJobs.count == 1, "local concurrency exceeded one")
    let firstLocal = await rig.local.receivedJobs.first!
    await rig.local.succeed(firstLocal)
    try await task10Eventually("next local job did not start") { await rig.local.receivedJobs.count == 2 }
    try task10Require(await rig.local.maximumActive == 1, "local maximum concurrency exceeded one")
    await task10Stop(rig)
}

func checkDeadlineIncludesQueueTime() async throws {
    let rig = try await task10MakeRig()
    let segments = [task10Segment(), task10Segment(), task10Segment()]
    for segment in segments { await rig.scheduler.submit(segment) }
    try await task10Eventually("initial AI jobs did not start") { await rig.ai.receivedJobs.count == 2 }
    let initial = await rig.ai.receivedJobs
    await rig.ai.emit(initial[0], isFinal: false)
    await rig.ai.emit(initial[1], isFinal: false)
    try await task10Eventually("initial first text was not processed") {
        await task10Translations(rig.collector.events).count == 2
    }
    rig.clock.advance(toMilliseconds: 5_000)
    await rig.ai.succeed(initial[0])
    try await task10Eventually("queued job did not start after five seconds") { await rig.ai.receivedJobs.count == 3 }
    let queued = await rig.ai.receivedJobs[2]
    try task10Require(queued.createdAt == task10Instant(0) && queued.deadline == task10Instant(6_000),
                      "queue wait reset the job lifetime")
    rig.clock.advance(toMilliseconds: 5_999)
    await task10Flush()
    try task10Require(await task10Fallbacks(rig.collector.events).isEmpty, "deadline fired before six seconds")
    rig.clock.advance(toMilliseconds: 6_000)
    try await task10Eventually("total deadline did not request fallback") {
        await task10Fallbacks(rig.collector.events).contains { $0.reason == .deadlineExceeded }
    }
    let beforeLate = await task10Translations(rig.collector.events).count
    await rig.ai.succeed(queued, text: "late")
    await task10Flush()
    try task10Require(await task10Fallbacks(rig.collector.events).count == 1, "deadline requested fallback more than once")
    try task10Require(await task10Translations(rig.collector.events).count == beforeLate, "late success was emitted")
    await task10Stop(rig)

    let firstTextRig = try await task10MakeRig()
    await firstTextRig.scheduler.submit(task10Segment())
    try await task10Eventually("first-text job did not start") { await firstTextRig.ai.receivedJobs.count == 1 }
    firstTextRig.clock.advance(toMilliseconds: 2_999)
    await task10Flush()
    try task10Require(await task10Fallbacks(firstTextRig.collector.events).isEmpty, "first-text timeout fired early")
    firstTextRig.clock.advance(toMilliseconds: 3_000)
    do {
        try await task10Eventually("first-text timeout did not request fallback") {
            await task10Fallbacks(firstTextRig.collector.events).contains { $0.reason == .firstTextTimeout }
        }
    } catch {
        let events = await firstTextRig.collector.events
        let jobs = await firstTextRig.ai.receivedJobs
        throw Task10CheckFailure(message: "first-text wait failed: fallbacks=\(task10Fallbacks(events).map(\.reason)), failures=\(task10Failed(events).map(\.reason)), translations=\(task10Translations(events).count), jobs=\(jobs.count)")
    }
    await task10Stop(firstTextRig)
}

func checkStaleErrorAndCancellationDoNotFallback() async throws {
    let rig = try await task10MakeRig()
    let segment = task10Segment()
    await rig.scheduler.submit(segment)
    try await task10Eventually("old AI job did not start") { await rig.ai.receivedJobs.count == 1 }
    let oldAI = await rig.ai.receivedJobs[0]
    let localIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 3)
    try await rig.scheduler.setMode(.local, identity: localIdentity,
                                    config: task10Config(mode: .local, profileID: rig.profile.id), profile: nil)
    await rig.ai.fail(oldAI, reason: .network)
    await task10Flush()
    try task10Require(await task10Failed(rig.collector.events).isEmpty, "old-epoch error produced a failure")
    try task10Require(await task10Fallbacks(rig.collector.events).isEmpty, "old-epoch error triggered fallback")

    await rig.scheduler.retainOnly(segmentIDs: [segment.segmentID])
    await rig.scheduler.submit(segment)
    try await task10Eventually("local job did not start") { await rig.local.receivedJobs.count == 1 }
    let oldLocal = await rig.local.receivedJobs[0]
    let currentIdentity = task10Identity(sessionID: rig.identity.sessionID, engineEpoch: 4)
    try await rig.scheduler.setMode(.ai, identity: currentIdentity, config: rig.config, profile: rig.profile)
    await rig.local.fail(oldLocal, reason: .localTranslationFailed)
    await rig.scheduler.retainOnly(segmentIDs: [segment.segmentID])
    await rig.scheduler.submit(task10Segment(id: segment.segmentID, revision: 1))
    try await task10Eventually("current AI revision did not start") { await rig.ai.receivedJobs.count == 2 }
    let current = await rig.ai.receivedJobs[1]
    await rig.scheduler.submit(task10Segment(id: segment.segmentID, revision: 2))
    rig.clock.advance(toMilliseconds: 800)
    try await task10Eventually("replacement AI revision did not start") { await rig.ai.receivedJobs.count == 3 }
    let replacement = await rig.ai.receivedJobs[2]
    await rig.ai.fail(current, reason: .network)
    await task10Flush()
    try task10Require(await task10Fallbacks(rig.collector.events).isEmpty, "cancelled revision triggered fallback")
    await rig.ai.fail(replacement, reason: .network)
    try await task10Eventually("current service failure did not request fallback") {
        await task10Fallbacks(rig.collector.events).count == 1
    }
    try task10Require(await task10Failed(rig.collector.events).count == 1, "only the current failure should be emitted")
    await task10Stop(rig)
}

func checkQueueOverflowAtDeadline() async throws {
    let rig = try await task10MakeRig()
    let segments = (0..<7).map { _ in task10Segment() }
    for segment in segments.prefix(6) { await rig.scheduler.submit(segment) }
    try await task10Eventually("deadline overflow jobs did not start") { await rig.ai.receivedJobs.count == 2 }
    let running = await rig.ai.receivedJobs
    await rig.ai.emit(running[0], isFinal: false)
    await rig.ai.emit(running[1], isFinal: false)
    try await task10Eventually("deadline overflow first text was not processed") {
        await task10Translations(rig.collector.events).count == 2
    }

    rig.clock.advanceHoldingWaiters(toMilliseconds: 6_000)
    await rig.scheduler.submit(segments[6])
    rig.clock.resumeWaiters()
    try await task10Eventually("queue overflow swallowed a current deadline") {
        await task10Failed(rig.collector.events).contains {
            $0.job.segmentID == segments[2].segmentID && $0.reason == .deadlineExceeded
        }
    }
    try task10Require(await !task10Dropped(rig.collector.events).contains {
        $0.segmentID == segments[2].segmentID
    }, "expired current job was reported as dropped instead of timeout")
    try await task10Eventually("deadline overflow fallback was not consumed") {
        await !task10Fallbacks(rig.collector.events).isEmpty
    }
    try task10Require(await task10Fallbacks(rig.collector.events).count == 1,
                      "deadline overflow did not produce exactly one fallback")
    await task10Stop(rig)
}

func checkRevisionBudget() async throws {
    let rig = try await task10MakeRig()
    let id = UUID()
    await rig.scheduler.submit(task10Segment(id: id, revision: 0))
    try await task10Eventually("first provisional did not start") { await rig.ai.receivedJobs.count == 1 }
    await rig.ai.succeed(await rig.ai.receivedJobs[0])

    rig.clock.advance(toMilliseconds: 100)
    await rig.scheduler.submit(task10Segment(id: id, revision: 1))
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 1, "same-segment revision ignored the 800 ms interval")
    rig.clock.advance(toMilliseconds: 799)
    await task10Flush()
    try task10Require(await rig.ai.receivedJobs.count == 1, "throttled revision started before the boundary")
    rig.clock.advance(toMilliseconds: 800)
    try await task10Eventually("second provisional did not start at 800 ms") { await rig.ai.receivedJobs.count == 2 }
    await rig.ai.succeed(await rig.ai.receivedJobs[1])

    rig.clock.advance(toMilliseconds: 1_600)
    await rig.scheduler.submit(task10Segment(id: id, revision: 2, stability: .final))
    try await task10Eventually("allowed final did not start") { await rig.ai.receivedJobs.count == 3 }
    await rig.ai.succeed(await rig.ai.receivedJobs[2])
    let aiJobs = await rig.ai.receivedJobs
    try task10Require(aiJobs.map(\.stability).count == 3, "unexpected AI request count")
    try task10Require({
        if case .provisional = aiJobs[0].stability, case .provisional = aiJobs[1].stability,
           case .final = aiJobs[2].stability { return true }
        return false
    }(), "AI budget did not preserve two provisional plus one final")

    rig.clock.advance(toMilliseconds: 2_400)
    await rig.scheduler.submit(task10Segment(id: id, revision: 3, stability: .final))
    try await task10Eventually("budget-exhausted revision did not use local") { await rig.local.receivedJobs.count == 1 }
    let localJob = await rig.local.receivedJobs[0]
    try task10Require(localJob.segmentID == id && localJob.sourceRevision == 3 && localJob.cloudProfile == nil,
                      "single-segment local fallback retained an AI target")
    await rig.local.succeed(localJob, text: "local revision")
    try await task10Eventually("local provider update was not emitted") {
        await task10Translations(rig.collector.events).contains { pair in
            guard pair.job.jobID == localJob.jobID else { return false }
            if case .local = pair.update.provider { return true }
            return false
        }
    }
    try task10Require(await task10Fallbacks(rig.collector.events).isEmpty, "revision budget caused global fallback")

    rig.clock.advance(toMilliseconds: 3_200)
    await rig.scheduler.submit(task10Segment())
    try await task10Eventually("a new segment did not remain in AI mode") { await rig.ai.receivedJobs.count == 4 }
    await task10Stop(rig)
}

#if TASK10_HOST_CHECK
@main
private struct Task10HostChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--candidate-only") {
            try await checkFallbackCandidateRevalidated()
            print("candidate revalidation check passed")
            return
        }
        if CommandLine.arguments.contains("--clock-only") {
            try await checkClockDeadlineRace()
            print("clock race check passed")
            return
        }
        if CommandLine.arguments.contains("--output-only") {
            try await checkOutputDeliversControlsWithoutConsumer()
            print("output control check passed")
            return
        }
        try await checkDiagnosticsReflectQueueMutationsSynchronously()
        try await checkDiagnosticsReportClearedQueueForModeAndFailure()
        try await checkConcurrencyAndQueueBounds()
        try await checkDeadlineIncludesQueueTime()
        try await checkStaleErrorAndCancellationDoNotFallback()
        try await checkRevisionBudget()
        try await checkFallbackLocksAndEpochAcknowledgement()
        try await checkStopLeavesZeroNewJobs()
        try await checkProfileSnapshotAtSubmission()
        try await checkQueuedFailureCarriesJob()
        try await checkOutputDeliversControlsWithoutConsumer()
        try await checkClockDeadlineRace()
        try await checkOldStreamCancellationDoesNotStopRestart()
        try await checkSetModeAfterStopRejected()
        try await checkLocalFailureCancelsGeneration()
        try await checkFallbackCandidateRevalidated()
        try await checkQueueOverflowAtDeadline()
        try await checkOutputControlSaturationIsExplicit()
        print("18 TASK-10 host checks passed; no SDK/device behavior tested.")
    }
}
#else
struct TranslationSchedulerTests {
    @Test func diagnosticsReflectQueueMutationsSynchronously() async throws { try await checkDiagnosticsReflectQueueMutationsSynchronously() }
    @Test func diagnosticsReportClearedQueueForModeAndFailure() async throws { try await checkDiagnosticsReportClearedQueueForModeAndFailure() }
    @Test func testConcurrencyAndQueueBounds() async throws { try await checkConcurrencyAndQueueBounds() }
    @Test func testDeadlineIncludesQueueTime() async throws { try await checkDeadlineIncludesQueueTime() }
    @Test func testStaleErrorAndCancellationDoNotFallback() async throws {
        try await checkStaleErrorAndCancellationDoNotFallback()
    }
    @Test func testRevisionBudget() async throws { try await checkRevisionBudget() }
    @Test func testClockDeadlineRace() async throws { try await checkClockDeadlineRace() }
    @Test func testQueueOverflowAtDeadline() async throws { try await checkQueueOverflowAtDeadline() }
}
#endif
