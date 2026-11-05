import Foundation
import Synchronization
#if !FEATURES_HOST_CHECK
@testable import LiveSubtitle
#endif

struct FeatureTestFailure: Error {
    let message: String
}

func featureRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw FeatureTestFailure(message: message) }
}

@MainActor
func featureEventually(
    _ message: String,
    condition: @MainActor () async -> Bool
) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        await Task.yield()
    }
    throw FeatureTestFailure(message: message)
}

func makeFeatureProfile(
    id: UUID = UUID(),
    name: String = "Test profile",
    revision: UInt64 = 1
) -> CloudProfile {
    CloudProfile(
        id: id,
        name: name,
        endpoint: URL(string: "https://provider.example/v1/chat/completions")!,
        model: "test-model",
        revision: revision
    )
}

func makeFeaturePreferences(
    source: String = "en",
    target: String = "zh-Hans",
    mode: RequestedMode = .local,
    profileID: UUID? = nil,
    displayCount: Int = 3,
    displayStyle: DisplayStyle = .bilingual
) -> AppPreferences {
    AppPreferences(
        sourceLanguage: LanguageIdentifier(rawValue: source),
        targetLanguage: LanguageIdentifier(rawValue: target),
        requestedMode: mode,
        selectedCloudProfileID: profileID,
        display: DisplayPreferences(displayCount: displayCount, displayStyle: displayStyle)
    )
}

func makeFeatureStatus(
    phase: SessionPhase,
    requestedMode: RequestedMode = .local,
    effectiveMode: EffectiveMode = .local,
    failure: FailureCode? = nil
) -> SessionStatus {
    SessionStatus(
        phase: phase,
        identity: nil,
        requestedMode: requestedMode,
        effectiveMode: effectiveMode,
        failure: failure
    )
}

final class FeatureMutationLog: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] { storage.withLock { $0 } }
    func append(_ value: String) { storage.withLock { $0.append(value) } }
    func reset() { storage.withLock { $0.removeAll() } }
}

final class FeatureStreamBox<Event: Sendable>: Sendable {
    private struct State {
        var ids: [UUID] = []
        var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func makeStream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(16)) { continuation in
            state.withLock {
                $0.ids.append(id)
                $0.continuations[id] = continuation
            }
            continuation.onTermination = { _ in
                self.state.withLock {
                    $0.ids.removeAll { $0 == id }
                    $0.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    func emit(_ event: Event, at index: Int = 0) {
        let continuation = state.withLock { state -> AsyncStream<Event>.Continuation? in
            guard state.ids.indices.contains(index) else { return nil }
            return state.continuations[state.ids[index]]
        }
        continuation?.yield(event)
    }
}

actor FeatureSessionDouble: SessionCoordinating {
    let log: FeatureMutationLog
    private let statusEvents = FeatureStreamBox<SessionStatus>()
    private var willChangeContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendWillChange = false
    private(set) var preparedConfigs: [SessionConfig] = []
    private(set) var stopReasons: [StopReason] = []
    private(set) var displays: [DisplayPreferences] = []

    init(log: FeatureMutationLog) {
        self.log = log
    }

    func statuses() async -> AsyncStream<SessionStatus> { statusEvents.makeStream() }

    func prepare(config: SessionConfig) async {
        preparedConfigs.append(config)
        log.append("prepare")
    }

    func start() async { log.append("start") }

    func stop(reason: StopReason) async {
        stopReasons.append(reason)
        log.append("stop")
    }

    func setDisplay(_ preferences: DisplayPreferences) async {
        displays.append(preferences)
        log.append("setDisplay")
    }

    func selectMode(_ mode: RequestedMode) async {
        log.append("selectMode.\(mode.rawValue)")
    }

    func cloudProfileWillChange() async {
        log.append("willChange")
        if shouldSuspendWillChange {
            shouldSuspendWillChange = false
            await withCheckedContinuation { continuation in
                willChangeContinuation = continuation
            }
        }
    }

    func cloudProfileDidChange() async { log.append("didChange") }
    func restoreAI() async { log.append("restoreAI") }

    func emit(_ status: SessionStatus) { statusEvents.emit(status) }

    func suspendNextWillChange() { shouldSuspendWillChange = true }

    func releaseWillChange() {
        willChangeContinuation?.resume()
        willChangeContinuation = nil
    }
}

actor FeaturePreferencesDouble: PreferencesStoring {
    private let log: FeatureMutationLog
    private var preferences: AppPreferences?
    private var storedProfiles: [CloudProfile]
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendSave = false
    private var failures: Set<String> = []

    init(
        preferences: AppPreferences?,
        profiles: [CloudProfile],
        log: FeatureMutationLog
    ) {
        self.preferences = preferences
        self.storedProfiles = profiles
        self.log = log
    }

    func load() async throws -> AppPreferences? { preferences }

    func save(_ preferences: AppPreferences) async throws {
        log.append("savePreferences")
        if shouldSuspendSave {
            shouldSuspendSave = false
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
            }
        }
        self.preferences = preferences
    }

    func suspendNextSave() { shouldSuspendSave = true }
    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func profiles() async throws -> [CloudProfile] { storedProfiles }

    func saveProfile(_ profile: CloudProfile) async throws {
        try checkFailure("saveProfile")
        let revision: UInt64
        if let index = storedProfiles.firstIndex(where: { $0.id == profile.id }) {
            revision = storedProfiles[index].revision + 1
            storedProfiles[index] = CloudProfile(
                id: profile.id,
                name: profile.name,
                endpoint: profile.endpoint,
                model: profile.model,
                revision: revision
            )
        } else {
            revision = 1
            storedProfiles.append(CloudProfile(
                id: profile.id,
                name: profile.name,
                endpoint: profile.endpoint,
                model: profile.model,
                revision: revision
            ))
        }
        log.append("saveProfile")
    }

    func deleteProfile(id: UUID) async throws {
        try checkFailure("deleteProfile")
        storedProfiles.removeAll { $0.id == id }
        if preferences?.selectedCloudProfileID == id, let current = preferences {
            preferences = makeFeaturePreferences(
                source: current.sourceLanguage.rawValue,
                target: current.targetLanguage.rawValue,
                mode: current.requestedMode,
                profileID: nil,
                displayCount: current.display.displayCount,
                displayStyle: current.display.displayStyle
            )
        }
        log.append("deleteProfile")
    }

    func currentPreferences() -> AppPreferences? { preferences }
    func failNext(_ operation: String) { failures.insert(operation) }
    private func checkFailure(_ operation: String) throws {
        if failures.remove(operation) != nil {
            throw FeatureTestFailure(message: "injected \(operation) failure")
        }
    }
}

actor FeatureCredentialsDouble: CredentialStoring {
    private let log: FeatureMutationLog
    private var keys: [UUID: String]
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendRead = false
    private var failures: Set<String> = []
    private(set) var readKeyCount = 0

    init(keys: [UUID: String], log: FeatureMutationLog) {
        self.keys = keys
        self.log = log
    }

    func readKey(profileID: UUID) async throws -> String? {
        readKeyCount += 1
        if shouldSuspendRead {
            shouldSuspendRead = false
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return keys[profileID]
    }

    func replaceKey(_ key: String, profileID: UUID) async throws {
        try checkFailure("replaceKey")
        keys[profileID] = key
        log.append("replaceKey")
    }

    func deleteKey(profileID: UUID) async throws {
        try checkFailure("deleteKey")
        keys.removeValue(forKey: profileID)
        log.append("deleteKey")
    }

    func clearAppNamespace() async throws {
        keys.removeAll()
        log.append("clearAppNamespace")
    }

    func hasKey(profileID: UUID) -> Bool { keys[profileID]?.isEmpty == false }
    func failNext(_ operation: String) { failures.insert(operation) }
    func suspendNextReadKey() { shouldSuspendRead = true }
    func releaseReadKey() {
        readContinuation?.resume()
        readContinuation = nil
    }
    private func checkFailure(_ operation: String) throws {
        if failures.remove(operation) != nil {
            throw FeatureTestFailure(message: "injected \(operation) failure")
        }
    }
}

actor FeatureConnectionTesterDouble: ConnectionTesting {
    private let log: FeatureMutationLog
    private var result: Result<Void, FailureCode> = .success(())
    private var testContinuation: CheckedContinuation<Result<Void, FailureCode>, Never>?
    private var shouldSuspendTest = false
    private(set) var testedProfiles: [CloudProfile] = []

    init(log: FeatureMutationLog) {
        self.log = log
    }

    func test(profile: CloudProfile) async -> Result<Void, FailureCode> {
        testedProfiles.append(profile)
        log.append("testConnection")
        if shouldSuspendTest {
            shouldSuspendTest = false
            return await withCheckedContinuation { continuation in
                testContinuation = continuation
            }
        }
        return result
    }

    func cancel() async { log.append("cancelConnectionTest") }
    func setResult(_ result: Result<Void, FailureCode>) { self.result = result }
    func suspendNextTest() { shouldSuspendTest = true }
    func releaseTest(_ result: Result<Void, FailureCode>) {
        testContinuation?.resume(returning: result)
        testContinuation = nil
    }
}

actor FeatureCapabilityDouble: CapabilityChecking {
    private var report: CapabilityReport
    private var checkContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendCheck = false
    private(set) var checkedConfigs: [SessionConfig] = []

    init(report: CapabilityReport) {
        self.report = report
    }

    func check(config: SessionConfig) async -> CapabilityReport {
        checkedConfigs.append(config)
        if shouldSuspendCheck {
            shouldSuspendCheck = false
            await withCheckedContinuation { checkContinuation = $0 }
        }
        return report
    }

    func setReport(_ report: CapabilityReport) { self.report = report }
    func suspendNextCheck() { shouldSuspendCheck = true }
    func releaseCheck() {
        checkContinuation?.resume()
        checkContinuation = nil
    }
}

@MainActor
final class FeatureAssetsDouble: LanguageAssetManaging {
    private var continuation: AsyncStream<AssetEvent>.Continuation?
    private(set) var statusValue: LanguageAssetStatus
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var releaseCount = 0

    init(status: LanguageAssetStatus) {
        statusValue = status
    }

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> LanguageAssetStatus {
        statusValue
    }

    func prepare(source: LanguageIdentifier, target: LanguageIdentifier) -> AsyncStream<AssetEvent> {
        prepareCount += 1
        return AsyncStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            self.continuation = continuation
        }
    }

    func cancelPreparation() {
        cancelCount += 1
        continuation?.yield(.cancelled)
        continuation?.finish()
    }

    func releaseReservations() async { releaseCount += 1 }

    func emit(_ event: AssetEvent) { continuation?.yield(event) }
    func finish() { continuation?.finish() }
    func setStatus(_ status: LanguageAssetStatus) { statusValue = status }
}

@MainActor
final class FeatureTestRig {
    let log = FeatureMutationLog()
    let session: FeatureSessionDouble
    let preferences: FeaturePreferencesDouble
    let preferenceCoordinator: FeaturePreferencesCoordinator
    let credentials: FeatureCredentialsDouble
    let connectionTester: FeatureConnectionTesterDouble
    let capability: FeatureCapabilityDouble
    let assets: FeatureAssetsDouble

    init(
        preferences: AppPreferences? = nil,
        profiles: [CloudProfile] = [],
        keyedProfileIDs: [UUID] = [],
        capabilityReport: CapabilityReport? = nil,
        assetStatus: LanguageAssetStatus = LanguageAssetStatus(recognition: .ready, localTranslation: .ready)
    ) {
        session = FeatureSessionDouble(log: log)
        let preferencesStore = FeaturePreferencesDouble(preferences: preferences, profiles: profiles, log: log)
        self.preferences = preferencesStore
        preferenceCoordinator = FeaturePreferencesCoordinator(store: preferencesStore)
        credentials = FeatureCredentialsDouble(
            keys: Dictionary(uniqueKeysWithValues: keyedProfileIDs.map { ($0, "test-key") }),
            log: log
        )
        connectionTester = FeatureConnectionTesterDouble(log: log)
        capability = FeatureCapabilityDouble(report: capabilityReport ?? CapabilityReport(
            sourceLanguages: [LanguageIdentifier(rawValue: "en"), LanguageIdentifier(rawValue: "en-US")],
            targetLanguages: [LanguageIdentifier(rawValue: "zh-Hans"), LanguageIdentifier(rawValue: "zh-Hant")],
            assets: assetStatus,
            blockers: assetStatus.recognition == .ready && assetStatus.localTranslation == .ready ? [] : [.assetsMissing]
        ))
        assets = FeatureAssetsDouble(status: assetStatus)
    }

    func makeSetupViewModel() -> SetupViewModel {
        SetupViewModel(
            session: session,
            capability: capability,
            assets: assets,
            preferences: preferenceCoordinator,
            credentials: credentials
        )
    }

    func makeCloudViewModel() -> CloudSettingsViewModel {
        CloudSettingsViewModel(
            session: session,
            preferences: preferenceCoordinator,
            credentials: credentials,
            connectionTester: connectionTester
        )
    }
}
