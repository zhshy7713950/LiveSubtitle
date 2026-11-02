import Foundation

actor SessionCoordinator: SessionCoordinating {
    private enum StartOutcome {
        case pickerCancelled
        case failed(FailureCode)
    }

    private let dependencies: SessionDependencies
    private var config: SessionConfig?
    private var cloudProfile: CloudProfile?
    private var identity: SessionIdentity?
    private var phase: SessionPhase = .idle
    private var requestedMode: RequestedMode = .local
    private var effectiveMode: EffectiveMode = .local
    private var failure: FailureCode?
    private var terminalFailure: FailureCode?
    private var languageEpoch: UInt64 = 1
    private var engineEpoch: UInt64 = 0
    private var cloudConfigRevision: UInt64 = 0
    private var acceptsEvents = false
    private var preparationGeneration: UInt64 = 0
    private var connectionTestGeneration: UInt64 = 0
    private var restoringSessionIDs: Set<UUID> = []
    private var statusContinuations: [UUID: AsyncStream<SessionStatus>.Continuation] = [:]
    private var consumerTasks: [UUID: Task<Void, Never>] = [:]
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startOutcome: StartOutcome?
    private var speechRelayContinuation: AsyncStream<SpeechEvent>.Continuation?
    private var schedulerMutation: UUID?
    private var pendingSegments: [CaptionSegment] = []
    private var retainedRevisions: [UUID: UInt64] = [:]
    private var retainedOrder: [UUID] = []

    init(dependencies: SessionDependencies) {
        self.dependencies = dependencies
    }

    var currentStatus: SessionStatus {
        SessionStatus(
            phase: phase,
            identity: identity,
            requestedMode: requestedMode,
            effectiveMode: effectiveMode,
            failure: failure
        )
    }

    func statuses() async -> AsyncStream<SessionStatus> {
        let id = UUID()
        let pair = AsyncStream<SessionStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusContinuations[id] = pair.continuation
        pair.continuation.onTermination = { _ in
            Task { await self.removeStatusContinuation(id) }
        }
        pair.continuation.yield(currentStatus)
        return pair.stream
    }

    func prepare(config newConfig: SessionConfig) async {
        let languageChanged = config.map {
            $0.sourceLanguage != newConfig.sourceLanguage || $0.targetLanguage != newConfig.targetLanguage
        } ?? false
        if languageChanged && (acceptsEvents || identity != nil) {
            await stop(reason: .languageChanged)
        } else if acceptsEvents {
            return
        }
        if languageChanged { languageEpoch += 1 }

        preparationGeneration += 1
        let generation = preparationGeneration
        config = newConfig
        requestedMode = newConfig.requestedMode
        effectiveMode = .local
        failure = nil
        terminalFailure = nil
        phase = .preparing
        publishStatus()

        let report = await dependencies.capability.check(config: newConfig)
        guard generation == preparationGeneration else { return }
        if let blocker = report.blockers.first {
            phase = .failed
            failure = blocker
            publishStatus()
            return
        }

        let assets = await dependencies.mainActor.assetStatus(
            source: newConfig.sourceLanguage,
            target: newConfig.targetLanguage
        )
        guard generation == preparationGeneration else { return }
        if assets.recognition == .unsupported || assets.localTranslation == .unsupported {
            phase = .failed
            failure = .unsupportedLanguage
            publishStatus()
            return
        }

        if assets.recognition != .ready || assets.localTranslation != .ready {
            let events = await dependencies.mainActor.prepareAssets(
                source: newConfig.sourceLanguage,
                target: newConfig.targetLanguage
            )
            for await event in events {
                guard generation == preparationGeneration else { return }
                switch event {
                case .status:
                    continue
                case .finished:
                    phase = .ready
                    publishStatus()
                    return
                case .cancelled:
                    phase = .idle
                    publishStatus()
                    return
                case .failed(let code):
                    phase = .failed
                    failure = code
                    publishStatus()
                    return
                }
            }
            guard generation == preparationGeneration else { return }
        }

        phase = .ready
        publishStatus()
    }

    func start() async {
        guard phase == .ready, startupTask == nil, stopTask == nil, let config else { return }
        let profile: CloudProfile?
        do {
            profile = try await loadCloudProfile(for: config)
        } catch let code as FailureCode {
            phase = .failed
            failure = code
            publishStatus()
            return
        } catch {
            phase = .failed
            failure = .invalidConfiguration
            publishStatus()
            return
        }

        let activeProfile = config.requestedMode == .ai ? profile : nil
        let sessionIdentity = SessionIdentity(
            sessionID: UUID(),
            languageEpoch: languageEpoch,
            engineEpoch: engineEpoch,
            cloudConfigRevision: cloudConfigRevision
        )
        identity = sessionIdentity
        cloudProfile = activeProfile
        requestedMode = config.requestedMode
        effectiveMode = config.requestedMode == .ai ? .ai : .local
        failure = nil
        terminalFailure = nil
        acceptsEvents = true
        startOutcome = nil
        phase = .requestingCapture
        publishStatus()

        let task = Task { await self.performStart(identity: sessionIdentity, config: config, profile: activeProfile) }
        startupTask = task
        await task.value
        startupTask = nil

        guard let outcome = startOutcome, stopTask == nil, isCurrent(sessionIdentity) else { return }
        startOutcome = nil
        switch outcome {
        case .pickerCancelled:
            acceptsEvents = false
            identity = nil
            cloudProfile = nil
            effectiveMode = .local
            phase = .ready
            publishStatus()
        case .failed(let code):
            failure = code
            await stop(reason: .componentFailure)
        }
    }

    func stop(reason: StopReason) async {
        guard let task = beginStop(reason: reason, failure: nil) else { return }
        await task.value
    }

    func setDisplay(_ preferences: DisplayPreferences) async {
        guard let config else { return }
        self.config = SessionConfig(
            sourceLanguage: config.sourceLanguage,
            targetLanguage: config.targetLanguage,
            requestedMode: config.requestedMode,
            cloudProfileID: config.cloudProfileID,
            displayCount: preferences.displayCount,
            displayStyle: preferences.displayStyle
        )
        await dependencies.captions.setDisplay(preferences)
        await refreshCaptions()
    }

    func selectMode(_ mode: RequestedMode) async {
        if mode == .ai && effectiveMode == .localFallback {
            await restoreAI()
            return
        }
        guard var newConfig = config else { return }
        let profile: CloudProfile?
        if mode == .ai {
            do {
                profile = try await loadCloudProfile(for: newConfig)
            } catch {
                failure = .invalidConfiguration
                publishStatus()
                return
            }
        } else {
            profile = nil
        }
        newConfig = replacingMode(in: newConfig, mode: mode)
        config = newConfig
        requestedMode = mode
        cloudProfile = profile
        if mode == .ai, let profile { cloudConfigRevision = profile.revision }
        guard acceptsEvents, identity != nil else {
            effectiveMode = .local
            publishStatus()
            return
        }
        await changeMode(mode == .ai ? .ai : .local, config: newConfig, profile: profile, advanceEngine: true)
    }

    func cloudProfileWillChange() async {
        connectionTestGeneration += 1
        await dependencies.connectionTester.cancel()
        cloudConfigRevision += 1
        cloudProfile = nil
        guard acceptsEvents, identity != nil, let config else {
            publishStatus()
            return
        }
        let suspendAI = effectiveMode == .ai || effectiveMode == .localFallback
        await changeMode(.local, config: config, profile: nil, advanceEngine: suspendAI)
    }

    func cloudProfileDidChange() async {
        guard var config else { return }
        let storedPreferences = try? await dependencies.preferences.load()
        let selectedID = storedPreferences?.selectedCloudProfileID ?? config.cloudProfileID
        config = SessionConfig(
            sourceLanguage: config.sourceLanguage,
            targetLanguage: config.targetLanguage,
            requestedMode: config.requestedMode,
            cloudProfileID: selectedID,
            displayCount: config.displayCount,
            displayStyle: config.displayStyle
        )
        self.config = config
        do {
            cloudProfile = try await loadCloudProfile(for: config, required: false)
            if let cloudProfile { cloudConfigRevision = cloudProfile.revision }
        } catch {
            cloudProfile = nil
            failure = .invalidConfiguration
        }
        guard acceptsEvents, identity != nil else {
            effectiveMode = .local
            publishStatus()
            return
        }
        await changeMode(.local, config: config, profile: nil, advanceEngine: false)
    }

    func restoreAI() async {
        guard acceptsEvents, let boundIdentity = identity, let config,
              requestedMode == .ai, effectiveMode == .localFallback else { return }
        let profile: CloudProfile?
        do {
            profile = try await loadCloudProfile(for: config)
        } catch {
            failure = .invalidConfiguration
            publishStatus()
            return
        }
        guard let profile, profile.revision == boundIdentity.cloudConfigRevision else {
            failure = .invalidConfiguration
            publishStatus()
            return
        }
        connectionTestGeneration += 1
        let generation = connectionTestGeneration
        let result = await dependencies.connectionTester.test(profile: profile)
        guard generation == connectionTestGeneration, isCurrent(boundIdentity),
              effectiveMode == .localFallback else { return }
        switch result {
        case .success:
            failure = nil
            cloudProfile = profile
            await changeMode(.ai, config: config, profile: profile, advanceEngine: true)
        case .failure(let code):
            failure = code
            publishStatus()
        }
    }

    private func performStart(identity: SessionIdentity, config: SessionConfig, profile: CloudProfile?) async {
        do {
            let source = try await dependencies.mainActor.startAudio(
                config: CaptureConfig(identity: identity, sourceLanguage: config.sourceLanguage)
            )
            guard isCurrent(identity) else { return }
            let format = try await dependencies.speech.inputFormat(source: config.sourceLanguage)
            let processed = await dependencies.audioProcessing.process(source, target: format)
            let speechEvents = try await dependencies.speech.start(input: processed, source: config.sourceLanguage)
            guard isCurrent(identity) else { return }

            let relay = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
            speechRelayContinuation = relay.continuation
            let segmentEvents = await dependencies.segmenter.start(input: relay.stream)
            let schedulingEvents = try await dependencies.scheduler.start(
                identity: identity,
                config: config,
                profile: profile
            )
            await dependencies.captions.begin(
                identity: identity,
                display: DisplayPreferences(displayCount: config.displayCount, displayStyle: config.displayStyle)
            )
            guard isCurrent(identity) else { return }
            let pipEvents = try await dependencies.mainActor.startPiP(sessionID: identity.sessionID)
            guard isCurrent(identity) else { return }

            registerConsumers(
                identity: identity,
                speech: speechEvents,
                segments: segmentEvents,
                scheduling: schedulingEvents,
                pip: pipEvents
            )
            phase = .running
            publishStatus()
            await refreshCaptions(status: .waitingForAudio)
        } catch is CancellationError {
            if isCurrent(identity) { startOutcome = .pickerCancelled }
        } catch let code as FailureCode {
            if isCurrent(identity) { startOutcome = .failed(code) }
        } catch {
            if isCurrent(identity) { startOutcome = .failed(.captureFailed) }
        }
    }

    private func registerConsumers(
        identity: SessionIdentity,
        speech: AsyncStream<SpeechEvent>,
        segments: AsyncStream<SegmentEvent>,
        scheduling: AsyncStream<SchedulingEvent>,
        pip: AsyncStream<PiPEvent>
    ) {
        let speechID = UUID()
        consumerTasks[speechID] = Task { await self.consumeSpeech(speech, identity: identity) }
        let segmentID = UUID()
        consumerTasks[segmentID] = Task { await self.consumeSegments(segments, identity: identity) }
        let schedulingID = UUID()
        consumerTasks[schedulingID] = Task { await self.consumeScheduling(scheduling, identity: identity) }
        let pipID = UUID()
        consumerTasks[pipID] = Task { await self.consumePiP(pip, identity: identity) }
    }

    private func consumeSpeech(_ stream: AsyncStream<SpeechEvent>, identity: SessionIdentity) async {
        for await event in stream {
            guard isValid(identity, scope: .speech) else { return }
            switch event {
            case .transcript, .discontinuity:
                if relaySpeech(event) { return }
            case .ended:
                _ = relaySpeech(event)
                speechRelayContinuation?.finish()
                _ = beginStop(reason: .captureEnded, failure: nil)
                return
            case .failed(let code):
                _ = relaySpeech(event)
                speechRelayContinuation?.finish()
                _ = beginStop(reason: .componentFailure, failure: code)
                return
            }
        }
    }

    /// Returns true when bounded relay overflow requires an explicit session failure.
    private func relaySpeech(_ event: SpeechEvent) -> Bool {
        guard let continuation = speechRelayContinuation else { return true }
        if case .dropped = continuation.yield(event) {
            _ = beginStop(reason: .sustainedBacklog, failure: .unavailable)
            return true
        }
        return false
    }

    private func consumeSegments(_ stream: AsyncStream<SegmentEvent>, identity: SessionIdentity) async {
        for await event in stream {
            guard isValid(identity, scope: .speech) else { return }
            switch event {
            case .upsert(let segment):
                await receiveSegment(segment, eventIdentity: identity)
            case .remove(let segmentID):
                retainedRevisions.removeValue(forKey: segmentID)
                retainedOrder.removeAll { $0 == segmentID }
                await dependencies.scheduler.retainOnly(segmentIDs: Set(retainedOrder))
            case .discontinuity:
                continue
            }
        }
    }

    private func receiveSegment(_ segment: CaptionSegment, eventIdentity: SessionIdentity) async {
        await dependencies.captions.upsert(segment)
        guard isValid(eventIdentity, scope: .speech) else { return }
        if retainedRevisions[segment.segmentID] == nil { retainedOrder.append(segment.segmentID) }
        retainedRevisions[segment.segmentID] = segment.sourceRevision
        while retainedOrder.count > RuntimePolicy.retainedSegmentLimit {
            let removed = retainedOrder.removeFirst()
            retainedRevisions.removeValue(forKey: removed)
        }
        await dependencies.scheduler.retainOnly(segmentIDs: Set(retainedOrder))
        guard isValid(eventIdentity, scope: .speech) else { return }
        if schedulerMutation != nil {
            pendingSegments.append(segment)
        } else {
            await dependencies.scheduler.submit(segment)
        }
        await refreshCaptions()
    }

    private func consumeScheduling(_ stream: AsyncStream<SchedulingEvent>, identity: SessionIdentity) async {
        for await event in stream {
            switch event {
            case .translation(let job, let update):
                await receiveTranslation(job: job, update: update, eventIdentity: identity)
            case .fallbackRequested(let eventIdentity, let reason):
                await receiveFallback(eventIdentity: eventIdentity, reason: reason)
            case .dropped(let job):
                guard isValid(identity, scope: .speech), isCurrent(job.identity) else { continue }
            case .failed(let job, let reason):
                await receiveSchedulerFailure(job: job, reason: reason, eventIdentity: identity)
            }
        }
    }

    private func receiveTranslation(job: TranslationJob, update: TranslationUpdate, eventIdentity: SessionIdentity) async {
        guard isValid(eventIdentity, scope: .speech), isCurrent(job.identity), isCurrent(update.identity),
              job.jobID == update.jobID, job.segmentID == update.segmentID,
              job.sourceRevision == update.sourceRevision else { return }
        await dependencies.captions.apply(update, for: job, now: dependencies.clock.now())
        guard isCurrent(job.identity) else { return }
        await refreshCaptions()
    }

    private func receiveFallback(eventIdentity: SessionIdentity, reason: FailureCode) async {
        guard isCurrent(eventIdentity), effectiveMode == .ai, let config else { return }
        failure = reason
        await changeMode(.localFallback, config: config, profile: nil, advanceEngine: true)
    }

    private func receiveSchedulerFailure(job: TranslationJob, reason: FailureCode, eventIdentity: SessionIdentity) async {
        guard isValid(eventIdentity, scope: .speech), isCurrent(job.identity) else { return }
        let mode = effectiveMode
        guard let snapshot = await dependencies.captions.snapshot(
            mode: mode,
            status: mode == .localFallback ? .localFallback : .listening
        ) else { return }
        guard isValid(eventIdentity, scope: .speech), isCurrent(job.identity),
              snapshot.segments.contains(where: {
                  $0.segmentID == job.segmentID && $0.sourceRevision == job.sourceRevision
              }) else { return }
        if job.cloudProfile != nil && mode == .ai {
            await receiveFallback(eventIdentity: job.identity, reason: reason)
        } else {
            _ = beginStop(reason: .componentFailure, failure: reason)
        }
    }

    private func consumePiP(_ stream: AsyncStream<PiPEvent>, identity: SessionIdentity) async {
        for await event in stream {
            let sessionID: UUID
            switch event {
            case .started(let id), .restoringInterface(let id), .restoredInterface(let id),
                 .closed(let id), .replaced(let id), .failed(let id, _):
                sessionID = id
            }
            guard acceptsEvents, identity.sessionID == sessionID,
                  self.identity?.sessionID == sessionID else { continue }
            switch event {
            case .started:
                phase = .running
                publishStatus()
            case .restoringInterface:
                restoringSessionIDs.insert(sessionID)
            case .restoredInterface:
                restoringSessionIDs.remove(sessionID)
            case .closed:
                if !restoringSessionIDs.contains(sessionID) {
                    _ = beginStop(reason: .pipClosed, failure: nil)
                    return
                }
            case .replaced:
                if !restoringSessionIDs.contains(sessionID) {
                    _ = beginStop(reason: .pipReplaced, failure: nil)
                    return
                }
            case .failed(_, let reason):
                _ = beginStop(reason: .componentFailure, failure: reason)
                return
            }
        }
    }

    private func changeMode(
        _ mode: EffectiveMode,
        config: SessionConfig,
        profile: CloudProfile?,
        advanceEngine: Bool
    ) async {
        guard acceptsEvents, let oldIdentity = identity else { return }
        let mutation = UUID()
        schedulerMutation = mutation
        if advanceEngine { engineEpoch += 1 }
        let newIdentity = SessionIdentity(
            sessionID: oldIdentity.sessionID,
            languageEpoch: oldIdentity.languageEpoch,
            engineEpoch: engineEpoch,
            cloudConfigRevision: cloudConfigRevision
        )
        identity = newIdentity
        effectiveMode = mode
        requestedMode = config.requestedMode
        self.config = config
        publishStatus()
        do {
            try await dependencies.scheduler.setMode(mode, identity: newIdentity, config: config, profile: profile)
            guard isCurrent(newIdentity), schedulerMutation == mutation else { return }
            await dependencies.captions.advanceIdentity(newIdentity)
            guard isCurrent(newIdentity), schedulerMutation == mutation else { return }
            schedulerMutation = nil
            let pending = pendingSegments
            pendingSegments.removeAll()
            for segment in pending where retainedRevisions[segment.segmentID] == segment.sourceRevision {
                guard isCurrent(newIdentity) else { return }
                await dependencies.scheduler.submit(segment)
            }
        } catch is CancellationError {
            return
        } catch let code as FailureCode {
            guard isCurrent(newIdentity) else { return }
            _ = beginStop(reason: .componentFailure, failure: code)
        } catch {
            guard isCurrent(newIdentity) else { return }
            _ = beginStop(reason: .componentFailure, failure: .invalidConfiguration)
        }
    }

    private func refreshCaptions(status: SubtitleStatus? = nil) async {
        guard acceptsEvents, let boundIdentity = identity else { return }
        let mode = effectiveMode
        let subtitleStatus = status ?? (mode == .localFallback ? .localFallback : .listening)
        guard let snapshot = await dependencies.captions.snapshot(mode: mode, status: subtitleStatus) else { return }
        guard acceptsEvents, identity == boundIdentity else { return }
        await dependencies.mainActor.present(snapshot)
    }

    private func loadCloudProfile(for config: SessionConfig, required: Bool = true) async throws -> CloudProfile? {
        guard let profileID = config.cloudProfileID else {
            if config.requestedMode == .ai && required { throw FailureCode.invalidConfiguration }
            return nil
        }
        let profile = try await dependencies.preferences.profiles().first { $0.id == profileID }
        if let profile {
            cloudConfigRevision = profile.revision
            return profile
        }
        if config.requestedMode == .ai && required { throw FailureCode.invalidConfiguration }
        return nil
    }

    private func replacingMode(in config: SessionConfig, mode: RequestedMode) -> SessionConfig {
        SessionConfig(
            sourceLanguage: config.sourceLanguage,
            targetLanguage: config.targetLanguage,
            requestedMode: mode,
            cloudProfileID: config.cloudProfileID,
            displayCount: config.displayCount,
            displayStyle: config.displayStyle
        )
    }

    private enum IdentityScope {
        case speech
    }

    private func isCurrent(_ candidate: SessionIdentity) -> Bool {
        acceptsEvents && identity == candidate
    }

    private func isValid(_ candidate: SessionIdentity, scope: IdentityScope) -> Bool {
        guard acceptsEvents, let current = identity else { return false }
        switch scope {
        case .speech:
            return current.sessionID == candidate.sessionID && current.languageEpoch == candidate.languageEpoch
        }
    }

    private func beginStop(reason: StopReason, failure newFailure: FailureCode?) -> Task<Void, Never>? {
        if let stopTask { return stopTask }
        guard acceptsEvents || identity != nil || phase == .preparing else { return nil }
        acceptsEvents = false
        preparationGeneration += 1
        connectionTestGeneration += 1
        schedulerMutation = nil
        pendingSegments.removeAll()
        if let newFailure {
            failure = newFailure
            terminalFailure = newFailure
        }
        phase = .stopping
        publishStatus()
        let sessionID = identity?.sessionID
        let task = Task { await self.performStop(sessionID: sessionID) }
        stopTask = task
        return task
    }

    private func performStop(sessionID: UUID?) async {
        await startupTask?.value
        await dependencies.mainActor.cancelPreparation()
        let tasks = Array(consumerTasks.values)
        tasks.forEach { $0.cancel() }
        speechRelayContinuation?.finish()
        speechRelayContinuation = nil
        await dependencies.connectionTester.cancel()
        await dependencies.scheduler.stop()
        await dependencies.mainActor.stopAudio()
        await dependencies.audioProcessing.stop()
        await dependencies.speech.cancelAndFinish()
        await dependencies.segmenter.reset()
        await dependencies.mainActor.releaseAssets()
        if let sessionID { await dependencies.mainActor.stopPiP(sessionID: sessionID) }
        await dependencies.mainActor.clearRenderer()
        await dependencies.captions.clear()
        await dependencies.diagnostics.clearSession()
        for task in tasks { await task.value }
        consumerTasks.removeAll()
        retainedRevisions.removeAll()
        retainedOrder.removeAll()
        restoringSessionIDs.removeAll()
        identity = nil
        cloudProfile = nil
        effectiveMode = .local
        phase = terminalFailure == nil ? .idle : .failed
        failure = terminalFailure
        stopTask = nil
        publishStatus()
    }

    private func publishStatus() {
        let status = currentStatus
        for continuation in statusContinuations.values { continuation.yield(status) }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }
}
