import Foundation
import Synchronization
@testable import LiveSubtitle

/// Isolated per-host URLProtocol transport; no real endpoint is contacted.
final class IntegrationTransport: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String: [URLRequest]]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.requests.withLock { $0[host, default: []].append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"固定译文"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count(host: String) -> Int { requests.withLock { $0[host]?.count ?? 0 } }
    static func latestURL(host: String) -> URL? { requests.withLock { $0[host]?.last?.url } }
    static func clear(host: String) { _ = requests.withLock { $0.removeValue(forKey: host) } }
}

actor IntegrationCredentials: CredentialStoring {
    private var key = "synthetic-integration-value"
    func readKey(profileID: UUID) async throws -> String? { key }
    func replaceKey(_ key: String, profileID: UUID) async throws { self.key = key }
    func deleteKey(profileID: UUID) async throws { key = "" }
    func clearAppNamespace() async throws { key = "" }
}

actor IntegrationLocalSession: LocalTranslationSession {
    private var failure = false
    private(set) var texts: [String] = []
    func isReady() async throws -> Bool { true }
    func translate(_ text: String) async throws -> String {
        texts.append(text)
        if failure { throw FailureCode.localTranslationFailed }
        return "本地固定译文"
    }
    func cancel() async { texts.removeAll() }
    func fail() { failure = true }
}

struct IntegrationCapability: CapabilityChecking {
    let blocker: FailureCode?
    func check(config: SessionConfig) async -> CapabilityReport {
        CapabilityReport(sourceLanguages: [config.sourceLanguage], targetLanguages: [config.targetLanguage],
                         assets: .init(recognition: .ready, localTranslation: .ready),
                         blockers: blocker.map { [$0] } ?? [])
    }
}

@MainActor
final class IntegrationRenderer: SubtitleRendering {
    private(set) var latest: SubtitleSnapshot?
    func present(_ snapshot: SubtitleSnapshot) { latest = snapshot }
    func clear() { latest = nil }
}

@MainActor
struct IntegrationRig {
    let session: SessionCoordinator
    let source: IntegrationAudioSource
    let speech: IntegrationSpeech
    let pip: FakePiPControlling
    let renderer: IntegrationRenderer
    let captions: CaptionStore
    let preferences: FakePreferencesStoring
    let credentials: IntegrationCredentials
    let local: IntegrationLocalSession
    let diagnostics: DiagnosticsRecorder
    let lifecycle: LifecycleBridge
    let captureScope: CaptureLifecycleScope
    let profile: CloudProfile
    let config: SessionConfig

    init(mode: RequestedMode = .local, blocker: FailureCode? = nil) {
        let clock = SystemMonotonicClock()
        let diagnostics = DiagnosticsRecorder(clock: clock)
        let credentials = IntegrationCredentials()
        let local = IntegrationLocalSession()
        let source = IntegrationAudioSource()
        let captureScope = CaptureLifecycleScope()
        let speech = IntegrationSpeech()
        let pip = FakePiPControlling()
        let renderer = IntegrationRenderer()
        let profile = CloudProfile(id: UUID(), name: "测试", endpoint: URL(string: "https://\(UUID().uuidString).invalid/v1/chat/completions")!, model: "fixture", revision: 1)
        let preferences = FakePreferencesStoring(profiles: [profile])
        let captions = CaptionStore()
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [IntegrationTransport.self]
        let cloud = CompatibleChatTranslator(credentials: credentials, configuration: transport, clock: clock)
        let scheduler = TranslationScheduler(aiTranslator: cloud,
            localTranslator: AppleLocalTranslator(sessionFactory: { _, _ in local }), clock: clock)
        let session = SessionCoordinator(dependencies: SessionDependencies(
            capability: IntegrationCapability(blocker: blocker), assets: FakeLanguageAssetManaging(),
            audioSource: LifecycleAudioSource(base: source, scope: captureScope, mayStart: { true }), audioProcessing: AudioPipeline(), speech: speech,
            segmenter: CaptionSegmenter(clock: clock), scheduler: scheduler, captions: captions,
            renderer: renderer, pip: pip, preferences: preferences,
            connectionTester: FakeConnectionTesting(), diagnostics: diagnostics, clock: clock))
        self.session = session
        self.source = source
        self.speech = speech
        self.pip = pip
        self.renderer = renderer
        self.captions = captions
        self.preferences = preferences
        self.credentials = credentials
        self.local = local
        self.diagnostics = diagnostics
        self.lifecycle = LifecycleBridge(session: session, diagnostics: diagnostics, clock: clock, captureScope: captureScope)
        self.captureScope = captureScope
        self.profile = profile
        self.config = SessionConfig(sourceLanguage: .init(rawValue: "en"), targetLanguage: .init(rawValue: "zh-Hans"),
            requestedMode: mode, cloudProfileID: profile.id, displayCount: RuntimePolicy.defaultDisplayCount, displayStyle: .bilingual)
    }

    func start() async throws {
        await session.prepare(config: config)
        await session.start()
        try sessionRequire(await session.currentStatus.phase == .running, "integration session did not start")
    }
    func emit(_ text: String, at time: Int64 = 0, stream: Int = 0) async {
        await speech.emit(.transcript(TranscriptEvent(utteranceID: UUID(),
            audioRange: AudioRange(start: .init(value: time, timescale: 1000), end: .init(value: time + 1000, timescale: 1000)),
            revision: 1, text: text, spans: [], isFinal: true, receivedAt: SystemMonotonicClock().now())), at: stream)
    }
    func waitForTranslation(_ text: String) async throws {
        try await integrationEventually("integrated translation was not displayed") {
            await MainActor.run {
                self.renderer.latest?.segments.contains { segment in
                    guard segment.sourceText == text else { return false }
                    if case .translated = segment.translationState { return true }
                    return false
                } ?? false
            }
        }
    }
    func cleanup() async {
        await session.stop(reason: .user)
        IntegrationTransport.clear(host: profile.endpoint.host!)
    }
}

@MainActor
func integrationEventually(_ message: String, condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    throw SessionTestFailure(message: message)
}

@MainActor
final class IntegrationPiPBase: PiPControlling {
    private(set) var starts: [UUID] = []
    private(set) var stops: [UUID] = []
    private var continuations: [AsyncStream<PiPEvent>.Continuation] = []
    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        starts.append(sessionID)
        let pair = AsyncStream<PiPEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuations.append(pair.continuation)
        return pair.stream
    }
    func stop(sessionID: UUID) async { stops.append(sessionID) }
    func emit(_ event: PiPEvent, stream: Int = 0) { continuations[stream].yield(event) }
    func finish(stream: Int = 0) { continuations[stream].finish() }
}

actor IntegrationBlockedDiagnostics: DiagnosticsRecording {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false
    func record(_ event: DiagnosticEvent) async {
        guard !isBlocked else { return }
        isBlocked = true
        await withCheckedContinuation { waiter = $0 }
    }
    func clearSession() async {}
    func release() { waiter?.resume(); waiter = nil }
}
