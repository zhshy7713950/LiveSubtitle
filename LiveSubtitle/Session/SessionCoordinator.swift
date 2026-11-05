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
    private var startupGeneration: UInt64 = 0
    private var operationGeneration: UInt64 = 0
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
        if let stopTask { await stopTask.value }
        operationGeneration += 1
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
        startupGeneration += 1
        operationGeneration += 1
        let generation = startupGeneration
        startOutcome = nil
        phase = .starting
        publishStatus()
        let task = Task { await self.performStart(generation: generation, config: config) }
        startupTask = task
        await task.value
        guard startupGeneration == generation else { return }
        startupTask = nil

        guard let outcome = startOutcome, stopTask == nil, startupGeneration == generation else { return }
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
            if identity == nil {
                terminalFailure = code
                phase = .failed
                publishStatus()
            } else {
                await beginStop(reason: .componentFailure, failure: code)?.value
            }
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
        guard phase == .running, acceptsEvents, let boundIdentity = identity, var newConfig = config else { return }
        let operation = reserveOperation()
        let profile: CloudProfile?
        if mode == .ai {
            do {
                profile = try await loadCloudProfile(for: newConfig)
            } catch {
                guard isOperationCurrent(boundIdentity, operation: operation) else { return }
                failure = .invalidConfiguration
                publishStatus()
                return
            }
        } else {
            profile = nil
        }
        guard isOperationCurrent(boundIdentity, operation: operation) else { return }
        newConfig = replacingMode(in: newConfig, mode: mode)
        config = newConfig
        requestedMode = mode
        cloudProfile = profile
        failure = nil
        if mode == .ai, let profile { cloudConfigRevision = profile.revision }
        await changeMode(
            mode == .ai ? .ai : .local,
            config: newConfig,
            profile: profile,
            advanceEngine: true,
            operation: operation
        )
    }

    func cloudProfileWillChange() async {
        guard phase == .running, acceptsEvents, let boundIdentity = identity, let config else { return }
        let operation = reserveOperation()
        connectionTestGeneration += 1
        await dependencies.connectionTester.cancel()
        guard isOperationCurrent(boundIdentity, operation: operation) else { return }
        cloudConfigRevision += 1
        cloudProfile = nil
        let suspendAI = effectiveMode == .ai || effectiveMode == .localFallback
        await changeMode(.local, config: config, profile: nil, advanceEngine: suspendAI, operation: operation)
    }

    func cloudProfileDidChange() async {
        guard phase == .running, acceptsEvents, let boundIdentity = identity, var newConfig = config else { return }
        let operation = reserveOperation()
        let storedPreferences = try? await dependencies.preferences.load()
        guard isOperationCurrent(boundIdentity, operation: operation) else { return }
        let selectedID = storedPreferences?.selectedCloudProfileID ?? newConfig.cloudProfileID
        newConfig = SessionConfig(
            sourceLanguage: newConfig.sourceLanguage,
            targetLanguage: newConfig.targetLanguage,
            requestedMode: newConfig.requestedMode,
            cloudProfileID: selectedID,
            displayCount: newConfig.displayCount,
            displayStyle: newConfig.displayStyle
        )
        let profile: CloudProfile?
        do {
            profile = try await loadCloudProfile(for: newConfig, required: false)
        } catch {
            guard isOperationCurrent(boundIdentity, operation: operation) else { return }
            cloudProfile = nil
            failure = .invalidConfiguration
            publishStatus()
            return
        }
        guard isOperationCurrent(boundIdentity, operation: operation) else { return }
        config = newConfig
        cloudProfile = profile
        if let profile { cloudConfigRevision = profile.revision }
        await changeMode(.local, config: newConfig, profile: nil, advanceEngine: false, operation: operation)
    }

    func restoreAI() async {
        guard phase == .running, acceptsEvents, let boundIdentity = identity, let config,
              requestedMode == .ai, effectiveMode == .localFallback else { return }
        let operation = reserveOperation()
        let profile: CloudProfile?
        do {
            profile = try await loadCloudProfile(for: config)
        } catch {
            guard isOperationCurrent(boundIdentity, operation: operation) else { return }
            failure = .invalidConfiguration
            publishStatus()
            return
        }
        guard isOperationCurrent(boundIdentity, operation: operation) else { return }
        guard let profile, profile.revision == boundIdentity.cloudConfigRevision else {
            failure = .invalidConfiguration
            publishStatus()
            return
        }
        connectionTestGeneration += 1
        let generation = connectionTestGeneration
        let result = await dependencies.connectionTester.test(profile: profile)
        guard generation == connectionTestGeneration, isOperationCurrent(boundIdentity, operation: operation),
              effectiveMode == .localFallback else { return }
        switch result {
        case .success:
            failure = nil
            cloudProfile = profile
            await changeMode(.ai, config: config, profile: profile, advanceEngine: true, operation: operation)
        case .failure(let code):
            failure = code
            publishStatus()
        }
    }

    private func performStart(generation: UInt64, config: SessionConfig) async {
        var captureStarted = false
        var startupFailure: FailureCode = .captureFailed
        do {
            let loadedProfile = try await loadCloudProfile(for: config)
            guard isStartCurrent(generation) else { return }
            let activeProfile = config.requestedMode == .ai ? loadedProfile : nil
            if let activeProfile { cloudConfigRevision = activeProfile.revision }
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
            phase = .requestingCapture
            publishStatus()

            let source = try await dependencies.mainActor.startAudio(
                config: CaptureConfig(identity: sessionIdentity, sourceLanguage: config.sourceLanguage)
            )
            captureStarted = true
            startupFailure = .speechFailed
            guard isCurrent(sessionIdentity) else { return }
            let format = try await dependencies.speech.inputFormat(source: config.sourceLanguage)
            let processed = await dependencies.audioProcessing.process(source, target: format)
            let speechEvents = try await dependencies.speech.start(input: processed, source: config.sourceLanguage)
            guard isCurrent(sessionIdentity) else { return }

            let relay = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
            speechRelayContinuation = relay.continuation
            let segmentEvents = await dependencies.segmenter.start(input: relay.stream)
            let schedulingEvents = try await dependencies.scheduler.start(
                identity: sessionIdentity,
                config: config,
                profile: activeProfile
            )
            await dependencies.captions.begin(
                identity: sessionIdentity,
                display: DisplayPreferences(displayCount: config.displayCount, displayStyle: config.displayStyle)
            )
            guard isCurrent(sessionIdentity) else { return }
            startupFailure = .pipFailed
            let pipEvents = try await dependencies.mainActor.startPiP(sessionID: sessionIdentity.sessionID)
            guard isCurrent(sessionIdentity) else { return }

            registerConsumers(
                identity: sessionIdentity,
                speech: speechEvents,
                segments: segmentEvents,
                scheduling: schedulingEvents,
                pip: pipEvents
            )
            phase = .running
            publishStatus()
            await refreshCaptions(status: .waitingForAudio)
        } catch is CancellationError {
            if isStartCurrent(generation) {
                startOutcome = captureStarted ? .failed(startupFailure) : .pickerCancelled
            }
        } catch let code as FailureCode {
            if isStartCurrent(generation) { startOutcome = .failed(code) }
        } catch {
            if isStartCurrent(generation) { startOutcome = .failed(.captureFailed) }
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
                pendingSegments.removeAll { $0.segmentID == segmentID }
                await dependencies.captions.remove(segmentID: segmentID)
                guard isValid(identity, scope: .speech) else { return }
                await dependencies.scheduler.retainOnly(segmentIDs: Set(retainedOrder))
                guard isValid(identity, scope: .speech) else { return }
                await refreshCaptions()
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
            case .fallbackRequested:
                // Advisory only: the paired failed(job:) supplies the revision and retention scope.
                continue
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
              job.sourceRevision == update.sourceRevision,
              retainedRevisions[job.segmentID] == job.sourceRevision else { return }
        await dependencies.captions.apply(update, for: job, now: dependencies.clock.now())
        guard isCurrent(job.identity) else { return }
        await refreshCaptions()
    }

    private func receiveFallback(eventIdentity: SessionIdentity, reason: FailureCode) async {
        guard phase == .running, isCurrent(eventIdentity), effectiveMode == .ai, let config else { return }
        let operation = reserveOperation()
        failure = reason
        await changeMode(.localFallback, config: config, profile: nil, advanceEngine: true, operation: operation)
    }

    private func receiveSchedulerFailure(job: TranslationJob, reason: FailureCode, eventIdentity: SessionIdentity) async {
        guard isValid(eventIdentity, scope: .speech), isCurrent(job.identity),
              retainedRevisions[job.segmentID] == job.sourceRevision else {
            await dependencies.scheduler.discardFailure(for: job)
            return
        }
        let mode = effectiveMode
        guard let snapshot = await dependencies.captions.snapshot(
            mode: mode,
            status: mode == .localFallback ? .localFallback : .listening
        ) else {
            await dependencies.scheduler.discardFailure(for: job)
            return
        }
        guard isValid(eventIdentity, scope: .speech), isCurrent(job.identity),
              retainedRevisions[job.segmentID] == job.sourceRevision,
              snapshot.segments.contains(where: {
                  $0.segmentID == job.segmentID && $0.sourceRevision == job.sourceRevision
              }) else {
            await dependencies.scheduler.discardFailure(for: job)
            return
        }
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
        advanceEngine: Bool,
        operation: UInt64
    ) async {
        guard let oldIdentity = identity, isOperationCurrent(oldIdentity, operation: operation) else { return }
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
            guard isOperationCurrent(newIdentity, operation: operation), schedulerMutation == mutation else { return }
            await dependencies.captions.advanceIdentity(newIdentity)
            guard isOperationCurrent(newIdentity, operation: operation), schedulerMutation == mutation else { return }
            schedulerMutation = nil
            let pending = pendingSegments
            pendingSegments.removeAll()
            for segment in pending where retainedRevisions[segment.segmentID] == segment.sourceRevision {
                guard isOperationCurrent(newIdentity, operation: operation) else { return }
                await dependencies.scheduler.submit(segment)
            }
        } catch is CancellationError {
            guard isOperationCurrent(newIdentity, operation: operation) else { return }
            _ = beginStop(reason: .componentFailure, failure: .unavailable)
        } catch let code as FailureCode {
            guard isOperationCurrent(newIdentity, operation: operation) else { return }
            _ = beginStop(reason: .componentFailure, failure: code)
        } catch {
            guard isOperationCurrent(newIdentity, operation: operation) else { return }
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

    private func reserveOperation() -> UInt64 {
        operationGeneration += 1
        return operationGeneration
    }

    private func isOperationCurrent(_ candidate: SessionIdentity, operation: UInt64) -> Bool {
        phase == .running && operationGeneration == operation && isCurrent(candidate)
    }

    private func isStartCurrent(_ generation: UInt64) -> Bool {
        startupGeneration == generation && stopTask == nil && (phase == .starting || phase == .requestingCapture)
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
        guard acceptsEvents || identity != nil || startupTask != nil || phase == .preparing || phase == .starting else { return nil }
        acceptsEvents = false
        preparationGeneration += 1
        connectionTestGeneration += 1
        startupGeneration += 1
        operationGeneration += 1
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
        startupTask?.cancel()
        await startupTask?.value
        startupTask = nil
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
        for task in tasks { await task.value }
        await dependencies.mainActor.clearRenderer()
        await dependencies.captions.clear()
        await dependencies.diagnostics.clearSession()
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
