import Foundation
import Testing
@testable import LiveSubtitle

/// Real orchestration/segmentation/scheduling/store/adapters; only system boundaries are doubles.
@MainActor
struct AcceptanceRig {
    let clock = Task10Clock()
    let session: SessionCoordinator
    let source = IntegrationAudioSource()
    let speech = IntegrationSpeech()
    let renderer = IntegrationRenderer()
    let captions = CaptionStore()
    let localCalls: AcceptanceLocalCalls
    let profile: CloudProfile
    let config: SessionConfig
    var host: String { profile.endpoint.host! }

    init(response: AcceptanceHTTP.Response = .json, mode: RequestedMode = .ai) {
        let profile = CloudProfile(id: UUID(), name: "验收固定响应",
            endpoint: URL(string: "https://\(UUID().uuidString).invalid/v1/chat/completions")!,
            model: "acceptance-fixture", revision: 1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AcceptanceHTTP.self]
        let credentials = IntegrationCredentials()
        let localCalls = AcceptanceLocalCalls()
        let cloud = CompatibleChatTranslator(credentials: credentials, configuration: configuration, clock: clock)
        let scheduler = TranslationScheduler(aiTranslator: cloud,
            localTranslator: AppleLocalTranslator(sessionFactory: { _, _ in AcceptanceLocalSession(calls: localCalls) }), clock: clock)
        let config = SessionConfig(sourceLanguage: .init(rawValue: "en"), targetLanguage: .init(rawValue: "zh-Hans"),
            requestedMode: mode, cloudProfileID: profile.id,
            displayCount: RuntimePolicy.defaultDisplayCount, displayStyle: .bilingual)
        session = SessionCoordinator(dependencies: SessionDependencies(
            capability: IntegrationCapability(blocker: nil), assets: FakeLanguageAssetManaging(),
            audioSource: source, audioProcessing: AudioPipeline(), speech: speech,
            segmenter: CaptionSegmenter(clock: clock), scheduler: scheduler, captions: captions,
            renderer: renderer, pip: FakePiPControlling(), preferences: FakePreferencesStoring(profiles: [profile]),
            connectionTester: CloudConnectionTester(credentials: credentials, configuration: configuration),
            diagnostics: DiagnosticsRecorder(clock: clock), clock: clock))
        self.localCalls = localCalls
        self.profile = profile
        self.config = config
        AcceptanceHTTP.install(response, host: profile.endpoint.host!)
    }

    func start() async throws {
        await session.prepare(config: config)
        await session.start()
        #expect(await session.currentStatus.phase == .running)
    }
    func emit(_ text: String, at time: Int64 = 0, stream: Int = 0) async {
        await speech.emit(.transcript(TranscriptEvent(utteranceID: UUID(),
            audioRange: AudioRange(start: .init(value: time, timescale: 1_000),
                                   end: .init(value: time + 1_000, timescale: 1_000)),
            revision: 1, text: text, spans: [], isFinal: true, receivedAt: clock.now())), at: stream)
    }
    func translated(_ source: String) -> (text: String, provider: TranslationProvider)? {
        guard let segment = renderer.latest?.segments.first(where: { $0.sourceText == source }),
              case .translated(let text, true, let provider) = segment.translationState else { return nil }
        return (text, provider)
    }
    func waitForTranslation(_ source: String) async throws {
        try await integrationEventually("Acceptance translation did not reach the renderer") { translated(source) != nil }
    }
    func cleanup() async {
        await session.stop(reason: .user)
        AcceptanceHTTP.remove(host: host)
    }
}

@MainActor
func withAcceptanceRig(response: AcceptanceHTTP.Response = .json, mode: RequestedMode = .ai,
    body: (AcceptanceRig) async throws -> Void) async throws {
    let rig = AcceptanceRig(response: response, mode: mode)
    do {
        try await rig.start()
        try await body(rig)
        await rig.cleanup()
    } catch {
        await rig.cleanup()
        throw error
    }
}
