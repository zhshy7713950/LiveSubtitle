import Foundation
import Synchronization
#if !SESSION_HOST_CHECK
@testable import LiveSubtitle
#endif

struct SessionTestFailure: Error {
    let message: String
}

func sessionRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw SessionTestFailure(message: message) }
}

func sessionEventually(
    _ message: String,
    condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    throw SessionTestFailure(message: message)
}

final class SessionTestClock: MonotonicClock, Sendable {
    private let ticks = Mutex<UInt64>(1_000_000_000)

    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: ticks.withLock { $0 })
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        while now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            try Task.checkCancellation()
            await Task.yield()
        }
        try Task.checkCancellation()
    }
}

final class SessionStreamBox<Event: Sendable>: Sendable {
    private struct State {
        var order: [UUID] = []
        var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func makeStream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            state.withLock {
                $0.order.append(id)
                $0.continuations[id] = continuation
            }
        }
    }

    func emit(_ event: Event, at index: Int = 0) {
        let continuation = state.withLock { state -> AsyncStream<Event>.Continuation? in
            guard state.order.indices.contains(index) else { return nil }
            return state.continuations[state.order[index]]
        }
        continuation?.yield(event)
    }

    func finishAll() {
        let continuations = state.withLock { Array($0.continuations.values) }
        continuations.forEach { $0.finish() }
    }
}

struct FakeCapabilityChecking: CapabilityChecking {
    func check(config: SessionConfig) async -> CapabilityReport {
        CapabilityReport(
            sourceLanguages: [config.sourceLanguage],
            targetLanguages: [config.targetLanguage],
            assets: LanguageAssetStatus(recognition: .ready, localTranslation: .ready),
            blockers: []
        )
    }
}

@MainActor
final class FakeLanguageAssetManaging: LanguageAssetManaging {
    private let events = SessionStreamBox<AssetEvent>()
    private(set) var releaseCount = 0
    private(set) var cancelCount = 0

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> LanguageAssetStatus {
        LanguageAssetStatus(recognition: .ready, localTranslation: .ready)
    }

    func prepare(source: LanguageIdentifier, target: LanguageIdentifier) -> AsyncStream<AssetEvent> {
        events.makeStream()
    }

    func cancelPreparation() { cancelCount += 1 }
    func releaseReservations() async { releaseCount += 1 }
}

@MainActor
final class FakeAudioSource: AudioSource {
    var cancelStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var configurations: [CaptureConfig] = []
    private var shouldSuspendStart = false
    private var startContinuation: CheckedContinuation<Void, any Error>?

    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        startCount += 1
        configurations.append(config)
        if cancelStart { throw CancellationError() }
        if shouldSuspendStart {
            shouldSuspendStart = false
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    startContinuation = continuation
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor in self.releaseStart() }
            }
        }
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { _ in }
    }

    func stop() async { stopCount += 1 }
    func suspendNextStart() { shouldSuspendStart = true }
    func releaseStart() {
        startContinuation?.resume(returning: ())
        startContinuation = nil
    }
}

actor FakeAudioProcessing: AudioProcessing {
    private(set) var processCount = 0
    private(set) var stopCount = 0

    func process(_ input: AsyncStream<AudioSourceEvent>, target: AudioFormat) async -> AsyncStream<AudioSourceEvent> {
        processCount += 1
        return input
    }

    func stop() async { stopCount += 1 }
}

actor FakeSpeechRecognizing: SpeechRecognizing {
    private let events = SessionStreamBox<SpeechEvent>()
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat {
        AudioFormat(
            sampleRate: 16_000,
            channels: 1,
            pcm: PCMFormat(sampleFormat: .float32, isInterleaved: true, isBigEndian: false, bytesPerFrame: 2)
        )
    }

    func start(input: AsyncStream<AudioSourceEvent>, source: LanguageIdentifier) async throws -> AsyncStream<SpeechEvent> {
        startCount += 1
        return events.makeStream()
    }

    func emit(_ event: SpeechEvent, at index: Int = 0) { events.emit(event, at: index) }
    func finish() async { finishCount += 1 }
    func cancelAndFinish() async { cancelCount += 1 }
}

actor FakeCaptionSegmenting: CaptionSegmenting {
    private let events = SessionStreamBox<SegmentEvent>()
    private(set) var startCount = 0
    private(set) var resetCount = 0

    func start(input: AsyncStream<SpeechEvent>) async -> AsyncStream<SegmentEvent> {
        startCount += 1
        return events.makeStream()
    }

    func emit(_ event: SegmentEvent, at index: Int = 0) { events.emit(event, at: index) }
    func reset() async { resetCount += 1 }
}

struct SchedulerModeCall: Sendable {
    let mode: EffectiveMode
    let identity: SessionIdentity
    let profile: CloudProfile?
}

actor FakeTranslationScheduling: TranslationScheduling {
    private let events = SessionStreamBox<SchedulingEvent>()
    private(set) var startIdentities: [SessionIdentity] = []
    private(set) var startProfiles: [CloudProfile?] = []
    private(set) var modeCalls: [SchedulerModeCall] = []
    private(set) var submittedSegments: [CaptionSegment] = []
    private(set) var retainedIDs: [Set<UUID>] = []
    private(set) var discardedFailures: [TranslationJob] = []
    private(set) var stopCount = 0
    private var setModeContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendSetMode = false
    private var shouldSuspendStop = false
    private var setModeError: Error?

    func start(identity: SessionIdentity, config: SessionConfig, profile: CloudProfile?) async throws -> AsyncStream<SchedulingEvent> {
        startIdentities.append(identity)
        startProfiles.append(profile)
        return events.makeStream()
    }

    func submit(_ segment: CaptionSegment) async { submittedSegments.append(segment) }
    func retainOnly(segmentIDs: Set<UUID>) async { retainedIDs.append(segmentIDs) }
    func discardFailure(for job: TranslationJob) async { discardedFailures.append(job) }

    func setMode(_ mode: EffectiveMode, identity: SessionIdentity, config: SessionConfig, profile: CloudProfile?) async throws {
        modeCalls.append(SchedulerModeCall(mode: mode, identity: identity, profile: profile))
        if let setModeError { throw setModeError }
        if shouldSuspendSetMode {
            await withCheckedContinuation { continuation in
                setModeContinuation = continuation
            }
        }
    }

    func stop() async {
        stopCount += 1
        if shouldSuspendStop {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
    }

    func emit(_ event: SchedulingEvent, at index: Int = 0) { events.emit(event, at: index) }
    func suspendSetMode() { shouldSuspendSetMode = true }
    func throwSetMode(_ error: Error) { setModeError = error }
    func releaseSetMode() {
        shouldSuspendSetMode = false
        setModeContinuation?.resume()
        setModeContinuation = nil
    }
    func suspendStop() { shouldSuspendStop = true }
    func releaseStop() {
        shouldSuspendStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

actor FakeCaptionStoring: CaptionStoring {
    private(set) var identity: SessionIdentity?
    private var display = DisplayPreferences(displayCount: 3, displayStyle: .bilingual)
    private var segments: [UUID: CaptionSegment] = [:]
    private var order: [UUID] = []
    private(set) var appliedUpdates: [TranslationUpdate] = []
    private(set) var advancedIdentities: [SessionIdentity] = []
    private(set) var clearCount = 0
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendSnapshot = false
    private var upsertContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendUpsert = false
    private var releaseUpsertOnClear = false
    private(set) var upsertCount = 0

    func begin(identity: SessionIdentity, display: DisplayPreferences) async {
        self.identity = identity
        self.display = display
    }

    func advanceIdentity(_ identity: SessionIdentity) async {
        self.identity = identity
        advancedIdentities.append(identity)
    }

    func upsert(_ segment: CaptionSegment) async {
        upsertCount += 1
        if shouldSuspendUpsert {
            shouldSuspendUpsert = false
            await withCheckedContinuation { continuation in
                upsertContinuation = continuation
            }
        }
        if segments[segment.segmentID] == nil { order.append(segment.segmentID) }
        segments[segment.segmentID] = segment
        while order.count > RuntimePolicy.retainedSegmentLimit {
            let removed = order.removeFirst()
            segments.removeValue(forKey: removed)
        }
    }

    func remove(segmentID: UUID) async {
        segments.removeValue(forKey: segmentID)
        order.removeAll { $0 == segmentID }
    }

    func apply(_ update: TranslationUpdate, for job: TranslationJob, now: MonotonicInstant) async {
        appliedUpdates.append(update)
    }

    func setDisplay(_ preferences: DisplayPreferences) async { display = preferences }

    func snapshot(mode: EffectiveMode, status: SubtitleStatus) async -> SubtitleSnapshot? {
        if shouldSuspendSnapshot {
            shouldSuspendSnapshot = false
            await withCheckedContinuation { continuation in
                snapshotContinuation = continuation
            }
        }
        guard let identity else { return nil }
        return SubtitleSnapshot(
            identity: identity,
            segments: order.compactMap { segments[$0] },
            displayCount: display.displayCount,
            displayStyle: display.displayStyle,
            effectiveMode: mode,
            status: status
        )
    }

    func clear() async {
        if releaseUpsertOnClear {
            upsertContinuation?.resume()
            upsertContinuation = nil
        }
        segments.removeAll()
        order.removeAll()
        clearCount += 1
    }

    func suspendNextUpsert(releaseOnClear: Bool = false) {
        shouldSuspendUpsert = true
        releaseUpsertOnClear = releaseOnClear
    }
    func releaseUpsert() {
        upsertContinuation?.resume()
        upsertContinuation = nil
    }
    var snapshotWaiting: Bool { snapshotContinuation != nil }
    func suspendSnapshot() { shouldSuspendSnapshot = true }
    func releaseSnapshot() {
        shouldSuspendSnapshot = false
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }
}

@MainActor
final class FakeSubtitleRendering: SubtitleRendering {
    private(set) var snapshots: [SubtitleSnapshot] = []
    private(set) var clearCount = 0
    func present(_ snapshot: SubtitleSnapshot) { snapshots.append(snapshot) }
    func clear() { clearCount += 1 }
}

@MainActor
final class FakePiPControlling: PiPControlling {
    var startFailure: FailureCode?
    private let events = SessionStreamBox<PiPEvent>()
    private(set) var startedSessionIDs: [UUID] = []
    private(set) var stoppedSessionIDs: [UUID] = []

    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        startedSessionIDs.append(sessionID)
        if let startFailure { throw startFailure }
        return events.makeStream()
    }

    func stop(sessionID: UUID) async { stoppedSessionIDs.append(sessionID) }
    func emit(_ event: PiPEvent, at index: Int = 0) { events.emit(event, at: index) }
}

actor FakePreferencesStoring: PreferencesStoring {
    private var storedProfiles: [CloudProfile]
    private(set) var savedProfiles: [CloudProfile] = []
    private(set) var profileLoadCount = 0
    private var shouldSuspendProfileLoads = false
    private var profileContinuations: [CheckedContinuation<Void, Never>] = []

    init(profiles: [CloudProfile]) { storedProfiles = profiles }
    func load() async throws -> AppPreferences? { nil }
    func save(_ preferences: AppPreferences) async throws {}
    func profiles() async throws -> [CloudProfile] {
        profileLoadCount += 1
        if shouldSuspendProfileLoads {
            await withCheckedContinuation { continuation in
                profileContinuations.append(continuation)
            }
        }
        return storedProfiles
    }
    func saveProfile(_ profile: CloudProfile) async throws {
        savedProfiles.append(profile)
        storedProfiles.removeAll { $0.id == profile.id }
        storedProfiles.append(profile)
    }
    func deleteProfile(id: UUID) async throws { storedProfiles.removeAll { $0.id == id } }
    func suspendProfileLoads() { shouldSuspendProfileLoads = true }
    func allowNewProfileLoads() { shouldSuspendProfileLoads = false }
    func releaseProfileLoads() {
        shouldSuspendProfileLoads = false
        profileContinuations.forEach { $0.resume() }
        profileContinuations.removeAll()
    }
}

actor FakeConnectionTesting: ConnectionTesting {
    private var result: Result<Void, FailureCode> = .success(())
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false
    private(set) var testedProfiles: [CloudProfile] = []
    private(set) var cancelCount = 0

    func test(profile: CloudProfile) async -> Result<Void, FailureCode> {
        testedProfiles.append(profile)
        if suspended {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return result
    }

    func cancel() async { cancelCount += 1 }
    func suspend() { suspended = true }
    func release(_ result: Result<Void, FailureCode>) {
        self.result = result
        continuation?.resume()
        continuation = nil
    }
}

actor FakeDiagnosticsRecording: DiagnosticsRecording {
    private(set) var clearCount = 0
    func record(_ event: DiagnosticEvent) async {}
    func clearSession() async { clearCount += 1 }
}

struct SessionTestRig: Sendable {
    let coordinator: SessionCoordinator
    let assets: FakeLanguageAssetManaging
    let audioSource: FakeAudioSource
    let audioProcessing: FakeAudioProcessing
    let speech: FakeSpeechRecognizing
    let segmenter: FakeCaptionSegmenting
    let scheduler: FakeTranslationScheduling
    let store: FakeCaptionStoring
    let renderer: FakeSubtitleRendering
    let pip: FakePiPControlling
    let preferences: FakePreferencesStoring
    let connectionTester: FakeConnectionTesting
    let diagnostics: FakeDiagnosticsRecording

    static func make(profile: CloudProfile? = nil) async -> SessionTestRig {
        let assets = await MainActor.run { FakeLanguageAssetManaging() }
        let audioSource = await MainActor.run { FakeAudioSource() }
        let audioProcessing = FakeAudioProcessing()
        let speech = FakeSpeechRecognizing()
        let segmenter = FakeCaptionSegmenting()
        let scheduler = FakeTranslationScheduling()
        let store = FakeCaptionStoring()
        let renderer = await MainActor.run { FakeSubtitleRendering() }
        let pip = await MainActor.run { FakePiPControlling() }
        let preferences = FakePreferencesStoring(profiles: profile.map { [$0] } ?? [])
        let connectionTester = FakeConnectionTesting()
        let diagnostics = FakeDiagnosticsRecording()
        let dependencies = await MainActor.run {
            SessionDependencies(
                capability: FakeCapabilityChecking(),
                assets: assets,
                audioSource: audioSource,
                audioProcessing: audioProcessing,
                speech: speech,
                segmenter: segmenter,
                scheduler: scheduler,
                captions: store,
                renderer: renderer,
                pip: pip,
                preferences: preferences,
                connectionTester: connectionTester,
                diagnostics: diagnostics,
                clock: SessionTestClock()
            )
        }
        return SessionTestRig(
            coordinator: SessionCoordinator(dependencies: dependencies),
            assets: assets,
            audioSource: audioSource,
            audioProcessing: audioProcessing,
            speech: speech,
            segmenter: segmenter,
            scheduler: scheduler,
            store: store,
            renderer: renderer,
            pip: pip,
            preferences: preferences,
            connectionTester: connectionTester,
            diagnostics: diagnostics
        )
    }

    func prepareAndStart(mode: RequestedMode = .local, profileID: UUID? = nil) async {
        await coordinator.prepare(config: makeSessionConfig(mode: mode, profileID: profileID))
        await coordinator.start()
    }
}

func makeSessionConfig(
    mode: RequestedMode = .local,
    profileID: UUID? = nil,
    source: String = "en",
    target: String = "zh-Hans"
) -> SessionConfig {
    SessionConfig(
        sourceLanguage: LanguageIdentifier(rawValue: source),
        targetLanguage: LanguageIdentifier(rawValue: target),
        requestedMode: mode,
        cloudProfileID: profileID,
        displayCount: RuntimePolicy.defaultDisplayCount,
        displayStyle: .bilingual
    )
}

func makeCloudProfile(id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, revision: UInt64 = 1) -> CloudProfile {
    CloudProfile(
        id: id,
        name: "Fixture",
        endpoint: URL(string: "https://example.invalid/v1/chat/completions")!,
        model: "fixture-model",
        revision: revision
    )
}

func makeCaptionSegment(id: UUID = UUID(), revision: UInt64 = 1) -> CaptionSegment {
    CaptionSegment(
        segmentID: id,
        utteranceID: UUID(),
        audioRange: AudioRange(
            start: AudioTimestamp(value: 0, timescale: 16_000),
            end: AudioTimestamp(value: 16_000, timescale: 16_000)
        ),
        sourceRevision: revision,
        sourceText: "Fixture source",
        stability: .final,
        translationState: .pending
    )
}

func makeTranslationJob(
    identity: SessionIdentity,
    segment: CaptionSegment,
    cloudProfile: CloudProfile? = nil
) -> TranslationJob {
    TranslationJob(
        jobID: UUID(),
        identity: identity,
        segmentID: segment.segmentID,
        sourceRevision: segment.sourceRevision,
        sourceText: segment.sourceText,
        sourceLanguage: LanguageIdentifier(rawValue: "en"),
        targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
        stability: segment.stability,
        cloudProfile: cloudProfile,
        createdAt: MonotonicInstant(uptimeNanoseconds: 1_000_000_000),
        deadline: MonotonicInstant(uptimeNanoseconds: 7_000_000_000)
    )
}

func makeTranslationUpdate(job: TranslationJob, provider: TranslationProvider) -> TranslationUpdate {
    TranslationUpdate(
        jobID: job.jobID,
        identity: job.identity,
        segmentID: job.segmentID,
        sourceRevision: job.sourceRevision,
        text: "Fixture translation",
        isFinal: true,
        provider: provider,
        failure: nil
    )
}
