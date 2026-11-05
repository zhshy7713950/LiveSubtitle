import Foundation
import Synchronization

struct SchedulingSystemClock: MonotonicClock {
    private let nowProvider: @Sendable () -> MonotonicInstant

    init(nowProvider: @escaping @Sendable () -> MonotonicInstant = {
        MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }) {
        self.nowProvider = nowProvider
    }

    func now() -> MonotonicInstant {
        nowProvider()
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let current = now().uptimeNanoseconds
        let remaining = deadline.uptimeNanoseconds > current ? deadline.uptimeNanoseconds - current : 0
        if remaining > 0 {
            try await Task.sleep(for: .nanoseconds(Int64(remaining)))
        }
        try Task.checkCancellation()
    }
}

actor TranslationScheduler: TranslationScheduling {
    private struct Submission {
        let segment: CaptionSegment
        let createdAt: MonotonicInstant
    }

    private struct JobState {
        let job: TranslationJob
        let startAfter: MonotonicInstant
        var firstTextReceived = false
    }

    private struct RunningJob {
        let job: TranslationJob
        let task: Task<Void, Never>
    }

    private struct AIUsage {
        var provisionalCount = 0
        var finalCount = 0
        var lastSubmission: MonotonicInstant?
    }

    private let aiTranslator: any Translator
    private let localTranslator: any Translator
    private let clock: any MonotonicClock
    // Invoked synchronously without locks or unstructured delivery tasks.
    private let onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)?

    private var lifecycle: UInt64 = 0
    private var accepting = false
    private var identity: SessionIdentity?
    private var config: SessionConfig?
    private var mode: EffectiveMode?
    private var profile: CloudProfile?
    private var output: SchedulingEventOutput?

    private var queue = TranslationJobQueue() {
        didSet {
            if queue.count != oldValue.count {
                onDiagnostic?(.translationQueued(count: queue.count))
            }
        }
    }
    private var jobs: [UUID: JobState] = [:]
    private var running: [UUID: RunningJob] = [:]
    private var submissions: [UUID: Submission] = [:]
    private var retainedSegmentIDs: Set<UUID>?
    private var retentionVersion: UInt64 = 0
    private var aiUsage: [UUID: AIUsage] = [:]
    private var lifetimeTasks: [UUID: Task<Void, Never>] = [:]
    private var firstTextTasks: [UUID: Task<Void, Never>] = [:]
    private var readyTasks: [UUID: Task<Void, Never>] = [:]
    private var aiLocked = true
    private var fallbackCandidate: Submission?

    init(
        aiTranslator: any Translator,
        localTranslator: any Translator,
        clock: any MonotonicClock = SchedulingSystemClock(),
        onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)? = nil
    ) {
        self.aiTranslator = aiTranslator
        self.localTranslator = localTranslator
        self.clock = clock
        self.onDiagnostic = onDiagnostic
    }

    func start(
        identity: SessionIdentity,
        config: SessionConfig,
        profile: CloudProfile?
    ) async throws -> AsyncStream<SchedulingEvent> {
        let mode: EffectiveMode = config.requestedMode == .ai ? .ai : .local
        try validate(identity: identity, config: config, mode: mode, profile: profile)
        let mutation = beginMutation()
        let previousOutput = output
        output = nil
        previousOutput?.finish()
        await clearGeneration()
        guard lifecycle == mutation else { throw CancellationError() }

        self.identity = identity
        self.config = config
        self.mode = mode
        self.profile = profile
        aiLocked = mode != .ai
        let eventOutput = SchedulingEventOutput()
        output = eventOutput
        accepting = true
        return eventOutput.makeStream { [weak self, weak eventOutput] in
            Task { await self?.stop(ifOutput: eventOutput) }
        }
    }

    func submit(_ segment: CaptionSegment) async {
        guard accepting, let mode, identity != nil, config != nil else { return }
        if let retainedSegmentIDs, !retainedSegmentIDs.contains(segment.segmentID) { return }
        guard !segment.sourceText.isEmpty,
              segment.sourceText.count <= RuntimePolicy.sourceCharacterLimit else { return }
        if let previous = submissions[segment.segmentID],
           previous.segment.sourceRevision >= segment.sourceRevision { return }

        let submission = Submission(segment: segment, createdAt: clock.now())
        submissions[segment.segmentID] = submission
        cancelWork(for: segment.segmentID, emitDropped: true)

        if mode == .ai && aiLocked {
            fallbackCandidate = submission
            return
        }
        let useAI = mode == .ai && allowsAI(segment)
        enqueue(submission, useAI: useAI)
    }

    func retainOnly(segmentIDs: Set<UUID>) async {
        retentionVersion &+= 1
        retainedSegmentIDs = segmentIDs
        submissions = submissions.filter { segmentIDs.contains($0.key) }
        aiUsage = aiUsage.filter { segmentIDs.contains($0.key) }
        if let fallbackCandidate, !segmentIDs.contains(fallbackCandidate.segment.segmentID) {
            self.fallbackCandidate = nil
        }
        for job in jobs.values.map(\.job) where !segmentIDs.contains(job.segmentID) {
            drop(job)
        }
        for work in running.values where !segmentIDs.contains(work.job.segmentID) {
            retire(work.job.jobID)
            work.task.cancel()
            emit(.dropped(job: work.job))
        }
    }

    func setMode(
        _ mode: EffectiveMode,
        identity: SessionIdentity,
        config: SessionConfig,
        profile: CloudProfile?
    ) async throws {
        guard self.identity != nil, output != nil else { throw FailureCode.invalidConfiguration }
        if let current = self.identity,
           current.sessionID != identity.sessionID || current.languageEpoch != identity.languageEpoch {
            throw FailureCode.invalidConfiguration
        }
        if let current = self.config,
           current.sourceLanguage != config.sourceLanguage || current.targetLanguage != config.targetLanguage {
            throw FailureCode.invalidConfiguration
        }
        try validate(identity: identity, config: config, mode: mode, profile: profile)
        let candidate = fallbackCandidate
        let candidateRetentionVersion = retentionVersion
        let mutation = beginMutation()
        await clearGeneration()
        guard lifecycle == mutation else { throw CancellationError() }

        self.identity = identity
        self.config = config
        self.mode = mode
        self.profile = profile
        aiLocked = mode != .ai
        accepting = true
        if let candidate, mode != .ai,
           candidateRetentionVersion == retentionVersion || retainedSegmentIDs?.contains(candidate.segment.segmentID) == true,
           clock.now().uptimeNanoseconds < deadline(for: candidate.createdAt).uptimeNanoseconds {
            submissions[candidate.segment.segmentID] = candidate
            enqueue(candidate, useAI: false)
        }
    }

    func stop() async {
        let mutation = beginMutation()
        await clearGeneration()
        guard lifecycle == mutation else { return }
        let previousOutput = output
        output = nil
        identity = nil
        config = nil
        mode = nil
        profile = nil
        previousOutput?.finish()
    }

    private func stop(ifOutput expected: SchedulingEventOutput?) async {
        guard let expected, output === expected else { return }
        await stop()
    }

    private func validate(
        identity: SessionIdentity,
        config: SessionConfig,
        mode: EffectiveMode,
        profile: CloudProfile?
    ) throws {
        guard config.sourceLanguage != config.targetLanguage else {
            throw FailureCode.invalidConfiguration
        }
        if mode == .ai {
            guard config.requestedMode == .ai, let profile,
                  config.cloudProfileID == profile.id,
                  identity.cloudConfigRevision == profile.revision else {
                throw FailureCode.invalidConfiguration
            }
        }
    }

    private func beginMutation() -> UInt64 {
        lifecycle += 1
        accepting = false
        return lifecycle
    }

    private func clearQueue() {
        let wasEmpty = queue.count == 0
        _ = queue.removeAll()
        if wasEmpty { onDiagnostic?(.translationQueued(count: 0)) }
    }

    private func clearGeneration() async {
        clearQueue()
        jobs.removeAll()
        submissions.removeAll()
        aiUsage.removeAll()
        retainedSegmentIDs = nil
        fallbackCandidate = nil
        for task in lifetimeTasks.values { task.cancel() }
        for task in firstTextTasks { task.value.cancel() }
        for task in readyTasks.values { task.cancel() }
        lifetimeTasks.removeAll()
        firstTextTasks.removeAll()
        readyTasks.removeAll()

        let oldRunning = running
        running.removeAll()
        for work in oldRunning.values { work.task.cancel() }
        await aiTranslator.cancelAll()
        await localTranslator.cancelAll()
        for work in oldRunning.values { await work.task.value }
    }

    private func allowsAI(_ segment: CaptionSegment) -> Bool {
        allowsAI(segmentID: segment.segmentID, stability: segment.stability)
    }

    private func allowsAI(segmentID: UUID, stability: CaptionStability) -> Bool {
        let usage = aiUsage[segmentID] ?? AIUsage()
        if usage.finalCount >= RuntimePolicy.aiFinalRequestLimit { return false }
        switch stability {
        case .provisional:
            return usage.provisionalCount < RuntimePolicy.aiProvisionalRequestLimit
        case .final:
            return usage.finalCount < RuntimePolicy.aiFinalRequestLimit
        }
    }

    private func enqueue(_ submission: Submission, useAI: Bool) {
        guard accepting, let identity, let config else { return }
        let now = clock.now()
        let startAfter: MonotonicInstant
        if useAI, let last = aiUsage[submission.segment.segmentID]?.lastSubmission {
            startAfter = maxInstant(now, adding(RuntimePolicy.aiSubmissionInterval, to: last))
        } else {
            startAfter = now
        }
        let job = TranslationJob(
            jobID: UUID(), identity: identity, segmentID: submission.segment.segmentID,
            sourceRevision: submission.segment.sourceRevision, sourceText: submission.segment.sourceText,
            sourceLanguage: config.sourceLanguage, targetLanguage: config.targetLanguage,
            stability: submission.segment.stability, cloudProfile: useAI ? profile : nil,
            createdAt: submission.createdAt, deadline: deadline(for: submission.createdAt)
        )
        jobs[job.jobID] = JobState(job: job, startAfter: startAfter)
        for removed in queue.enqueue(job) {
            guard jobs[removed.jobID] != nil else { continue }
            if clock.now().uptimeNanoseconds >= removed.deadline.uptimeNanoseconds {
                handleFailure(removed, reason: .deadlineExceeded)
            } else {
                retire(removed.jobID)
                emit(.dropped(job: removed))
            }
        }
        scheduleLifetime(for: job)
        if startAfter.uptimeNanoseconds > now.uptimeNanoseconds {
            scheduleReady(for: job, at: startAfter)
        }
        pump()
    }

    private func pump() {
        guard accepting else { return }
        let now = clock.now()
        while accepting, let job = queue.popFirst(where: { job in
            guard let state = jobs[job.jobID], state.startAfter.uptimeNanoseconds <= now.uptimeNanoseconds else {
                return false
            }
            if job.cloudProfile != nil && aiLocked { return false }
            return runningCount(cloud: job.cloudProfile != nil) < concurrencyLimit(cloud: job.cloudProfile != nil)
        }) {
            start(job, now: now)
        }
    }

    private func start(_ job: TranslationJob, now: MonotonicInstant) {
        guard jobs[job.jobID] != nil else { return }
        guard now.uptimeNanoseconds < job.deadline.uptimeNanoseconds else {
            handleFailure(job, reason: .deadlineExceeded)
            return
        }
        if job.cloudProfile != nil {
            guard !aiLocked, allowsAI(segmentID: job.segmentID, stability: job.stability) else {
                retire(job.jobID)
                return
            }
            var usage = aiUsage[job.segmentID] ?? AIUsage()
            switch job.stability {
            case .provisional: usage.provisionalCount += 1
            case .final: usage.finalCount += 1
            }
            usage.lastSubmission = now
            aiUsage[job.segmentID] = usage
        }

        let translator = job.cloudProfile == nil ? localTranslator : aiTranslator
        let task = Task { [weak self] in
            let stream = await translator.translate(job)
            for await update in stream {
                await self?.receive(update, for: job)
            }
            await self?.streamFinished(job: job, wasCancelled: Task.isCancelled)
        }
        running[job.jobID] = RunningJob(job: job, task: task)
        if job.cloudProfile != nil {
            scheduleFirstText(for: job, startedAt: now)
        }
    }

    private func receive(_ update: TranslationUpdate, for job: TranslationJob) {
        guard var state = jobs[job.jobID], accepting, identity == job.identity,
              update.jobID == job.jobID, update.identity == job.identity,
              update.segmentID == job.segmentID, update.sourceRevision == job.sourceRevision,
              submissions[job.segmentID]?.segment.sourceRevision == job.sourceRevision,
              isRetained(job.segmentID) else { return }
        guard clock.now().uptimeNanoseconds < job.deadline.uptimeNanoseconds else {
            handleFailure(job, reason: .deadlineExceeded)
            return
        }
        guard providerMatches(job: job, update: update) else {
            handleFailure(job, reason: .invalidOutput)
            return
        }
        if let failure = update.failure {
            handleFailure(job, reason: failure)
            return
        }
        guard update.text.count <= RuntimePolicy.translationCharacterLimit else {
            handleFailure(job, reason: .invalidOutput)
            return
        }
        if !update.text.isEmpty && !state.firstTextReceived {
            state.firstTextReceived = true
            jobs[job.jobID] = state
            firstTextTasks.removeValue(forKey: job.jobID)?.cancel()
        }
        emit(.translation(job: job, update: update))
        if update.isFinal {
            retire(job.jobID)
        }
    }

    private func streamFinished(job: TranslationJob, wasCancelled: Bool) {
        running.removeValue(forKey: job.jobID)
        if !wasCancelled, jobs[job.jobID] != nil {
            handleFailure(job, reason: job.cloudProfile == nil ? .localTranslationFailed : .incompatibleResponse)
        }
        pump()
    }

    private func scheduleLifetime(for job: TranslationJob) {
        let clock = self.clock
        lifetimeTasks[job.jobID] = Task { [weak self] in
            do {
                try await clock.sleep(until: job.deadline)
                await self?.timeout(job.jobID, firstText: false)
            } catch {
                return
            }
        }
    }

    private func scheduleFirstText(for job: TranslationJob, startedAt: MonotonicInstant) {
        let firstDeadline = minInstant(job.deadline, adding(RuntimePolicy.aiFirstTextTimeout, to: startedAt))
        let clock = self.clock
        firstTextTasks[job.jobID] = Task { [weak self] in
            do {
                try await clock.sleep(until: firstDeadline)
                await self?.timeout(job.jobID, firstText: true)
            } catch {
                return
            }
        }
    }

    private func scheduleReady(for job: TranslationJob, at startAfter: MonotonicInstant) {
        let clock = self.clock
        readyTasks[job.jobID] = Task { [weak self] in
            do {
                try await clock.sleep(until: startAfter)
                await self?.jobBecameReady(job.jobID)
            } catch {
                return
            }
        }
    }

    private func jobBecameReady(_ jobID: UUID) {
        readyTasks.removeValue(forKey: jobID)
        pump()
    }

    private func timeout(_ jobID: UUID, firstText: Bool) {
        guard let state = jobs[jobID] else { return }
        let job = state.job
        let now = clock.now().uptimeNanoseconds
        if now >= job.deadline.uptimeNanoseconds {
            handleFailure(job, reason: .deadlineExceeded)
            return
        }
        guard firstText, !state.firstTextReceived else { return }
        handleFailure(job, reason: .firstTextTimeout)
    }

    private func handleFailure(_ job: TranslationJob, reason: FailureCode) {
        guard jobs[job.jobID] != nil, identity == job.identity, isRetained(job.segmentID),
              submissions[job.segmentID]?.segment.sourceRevision == job.sourceRevision else { return }
        if job.cloudProfile != nil {
            let candidate = latestCandidate()
            aiLocked = true
            fallbackCandidate = candidate
            emit(.failed(job: job, reason: reason))
            emit(.fallbackRequested(identity: job.identity, reason: reason))
            for other in jobs.values.map(\.job) {
                _ = queue.remove(jobID: other.jobID)
                retire(other.jobID)
                if other.jobID != job.jobID {
                    running[other.jobID]?.task.cancel()
                    emit(.dropped(job: other))
                }
            }
            running[job.jobID]?.task.cancel()
        } else {
            accepting = false
            clearQueue()
            for other in jobs.values.map(\.job) {
                retire(other.jobID)
                running[other.jobID]?.task.cancel()
            }
            emit(.failed(job: job, reason: reason))
        }
    }

    private func latestCandidate() -> Submission? {
        jobs.values.compactMap { submissions[$0.job.segmentID] }.max { lhs, rhs in
            if lhs.createdAt.uptimeNanoseconds == rhs.createdAt.uptimeNanoseconds {
                return lhs.segment.sourceRevision < rhs.segment.sourceRevision
            }
            return lhs.createdAt.uptimeNanoseconds < rhs.createdAt.uptimeNanoseconds
        }
    }

    private func cancelWork(for segmentID: UUID, emitDropped: Bool) {
        for job in queue.remove(segmentID: segmentID) {
            retire(job.jobID)
            if emitDropped { emit(.dropped(job: job)) }
        }
        for work in running.values where work.job.segmentID == segmentID {
            retire(work.job.jobID)
            work.task.cancel()
            if emitDropped { emit(.dropped(job: work.job)) }
        }
    }

    private func drop(_ job: TranslationJob) {
        _ = queue.remove(jobID: job.jobID)
        retire(job.jobID)
        running[job.jobID]?.task.cancel()
        emit(.dropped(job: job))
    }

    private func retire(_ jobID: UUID) {
        jobs.removeValue(forKey: jobID)
        lifetimeTasks.removeValue(forKey: jobID)?.cancel()
        firstTextTasks.removeValue(forKey: jobID)?.cancel()
        readyTasks.removeValue(forKey: jobID)?.cancel()
    }

    private func runningCount(cloud: Bool) -> Int {
        running.values.count { ($0.job.cloudProfile != nil) == cloud }
    }

    private func concurrencyLimit(cloud: Bool) -> Int {
        cloud ? RuntimePolicy.aiConcurrency : RuntimePolicy.localConcurrency
    }

    private func isRetained(_ segmentID: UUID) -> Bool {
        retainedSegmentIDs?.contains(segmentID) ?? true
    }

    private func providerMatches(job: TranslationJob, update: TranslationUpdate) -> Bool {
        switch (job.cloudProfile == nil, update.provider) {
        case (true, .local), (false, .ai): return true
        default: return false
        }
    }

    private func deadline(for createdAt: MonotonicInstant) -> MonotonicInstant {
        adding(RuntimePolicy.jobLifetime, to: createdAt)
    }

    private func adding(_ duration: Duration, to instant: MonotonicInstant) -> MonotonicInstant {
        let components = duration.components
        let nanoseconds = UInt64(components.seconds) * 1_000_000_000 + UInt64(components.attoseconds / 1_000_000_000)
        let result = instant.uptimeNanoseconds.addingReportingOverflow(nanoseconds)
        return MonotonicInstant(uptimeNanoseconds: result.overflow ? UInt64.max : result.partialValue)
    }

    private func minInstant(_ lhs: MonotonicInstant, _ rhs: MonotonicInstant) -> MonotonicInstant {
        lhs.uptimeNanoseconds <= rhs.uptimeNanoseconds ? lhs : rhs
    }

    private func maxInstant(_ lhs: MonotonicInstant, _ rhs: MonotonicInstant) -> MonotonicInstant {
        lhs.uptimeNanoseconds >= rhs.uptimeNanoseconds ? lhs : rhs
    }

    private func emit(_ event: SchedulingEvent) {
        if case .dropped = event { onDiagnostic?(.droppedJob) }
        guard let output else { return }
        if output.emit(event) { return }
        closeAfterOutputOverload(event, output: output)
    }

    private func closeAfterOutputOverload(_ event: SchedulingEvent, output: SchedulingEventOutput) {
        guard accepting else { return }
        accepting = false
        clearQueue()
        let currentJobs = jobs.values.map(\.job)
        for job in currentJobs {
            retire(job.jobID)
            running[job.jobID]?.task.cancel()
        }
        let eventJob: TranslationJob?
        switch event {
        case .translation(let job, _), .dropped(let job), .failed(let job, _): eventJob = job
        case .fallbackRequested: eventJob = nil
        }
        guard let job = eventJob ?? currentJobs.first ?? running.values.first?.job else { return }
        _ = output.emit(.failed(job: job, reason: .unavailable))
        if job.cloudProfile != nil {
            _ = output.emit(.fallbackRequested(identity: job.identity, reason: .unavailable))
        }
    }
}

final class SchedulingEventOutput: Sendable {
    private struct Entry: Sendable {
        let id: UInt64
        let event: SchedulingEvent
    }

    private struct State: Sendable {
        var continuation: AsyncStream<SchedulingEvent>.Continuation?
        var queue: [Entry] = []
        var nextID: UInt64 = 0
        var draining = false
        var terminated = false
    }

    private let state = Mutex(State())

    func makeStream(onCancel: @escaping @Sendable () -> Void) -> AsyncStream<SchedulingEvent> {
        let (stream, continuation) = AsyncStream<SchedulingEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        state.withLock { $0.continuation = continuation }
        continuation.onTermination = { [weak self] reason in
            self?.invalidate(finishStream: false)
            if case .cancelled = reason { onCancel() }
        }
        return stream
    }

    func emit(_ event: SchedulingEvent) -> Bool {
        let result = state.withLock { state -> (accepted: Bool, shouldDrain: Bool) in
            guard !state.terminated else { return (false, false) }
            if let jobID = Self.provisionalJobID(event),
               let index = state.queue.firstIndex(where: { Self.provisionalJobID($0.event) == jobID }) {
                state.queue[index] = Entry(id: state.nextID, event: event)
                state.nextID += 1
                if state.draining { return (true, false) }
                state.draining = true
                return (true, true)
            }

            let control = Self.isControl(event)
            let limit = control ? 64 : 56
            if state.queue.count >= limit {
                var removal = state.queue.firstIndex { Self.provisionalJobID($0.event) != nil }
                if removal == nil {
                    removal = state.queue.firstIndex {
                        if case .dropped = $0.event { return true }
                        return false
                    }
                }
                if removal == nil && control {
                    removal = state.queue.firstIndex { !Self.isControl($0.event) }
                }
                guard let removal else { return (false, false) }
                state.queue.remove(at: removal)
            }
            state.queue.append(Entry(id: state.nextID, event: event))
            state.nextID += 1
            if state.draining { return (true, false) }
            state.draining = true
            return (true, true)
        }
        if result.shouldDrain {
            Task.detached { [weak self] in await self?.drain() }
        }
        return result.accepted
    }

    private static func provisionalJobID(_ event: SchedulingEvent) -> UUID? {
        guard case .translation(let job, let update) = event, !update.isFinal else { return nil }
        return job.jobID
    }

    private static func isControl(_ event: SchedulingEvent) -> Bool {
        switch event {
        case .failed, .fallbackRequested: return true
        case .translation, .dropped: return false
        }
    }

    func finish() {
        invalidate(finishStream: true)
    }

    private func drain() async {
        while true {
            guard let attempt = state.withLock({ state -> (Entry, AsyncStream<SchedulingEvent>.Continuation)? in
                guard !state.terminated, let continuation = state.continuation else { return nil }
                guard let entry = state.queue.first else {
                    state.draining = false
                    return nil
                }
                return (entry, continuation)
            }) else { return }

            switch attempt.1.yield(attempt.0.event) {
            case .enqueued:
                state.withLock { state in
                    if let index = state.queue.firstIndex(where: { $0.id == attempt.0.id }) {
                        state.queue.remove(at: index)
                    }
                }
            case .dropped:
                await Task.yield()
            case .terminated:
                invalidate(finishStream: false)
                return
            @unknown default:
                invalidate(finishStream: false)
                return
            }
        }
    }

    private func invalidate(finishStream: Bool) {
        let continuation = state.withLock { state -> AsyncStream<SchedulingEvent>.Continuation? in
            guard !state.terminated else { return nil }
            state.terminated = true
            state.queue.removeAll()
            let continuation = state.continuation
            state.continuation = nil
            state.draining = false
            return continuation
        }
        if finishStream { continuation?.finish() }
    }
}
