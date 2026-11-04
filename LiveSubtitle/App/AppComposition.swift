import Combine
import Foundation

/// The only production dependency graph. Constructors perform no subtitle requests.
@MainActor
final class AppComposition: ObservableObject {
    let session: SessionCoordinator
    let assets: LanguageAssetManager
    let renderer: SubtitleRenderer
    let diagnostics: DiagnosticsRecorder
    let cloudSettings: CloudSettingsViewModel
    @Published private(set) var setup: SetupViewModel
    @Published private(set) var setupID = UUID()
    @Published private(set) var isReady = false
    @Published private(set) var startupFailed = false
    private let capability: CapabilityService
    private let preferences: FeaturePreferencesCoordinator
    private let credentials: KeychainCredentialStore
    private let cleaner: FirstLaunchCredentialCleaner
    private let lifecycle: LifecycleBridge
    private var bootstrapping = false

    init() {
        let clock = SystemMonotonicClock()
        let diagnostics = DiagnosticsRecorder(clock: clock)
        let credentials = KeychainCredentialStore()
        let store = PreferencesStore()
        let preferences = FeaturePreferencesCoordinator(store: store)
        let capability = CapabilityService()
        let assets = LanguageAssetManager()
        let captureScope = CaptureLifecycleScope()
        let renderer = SubtitleRenderer()
        let pip = LifecyclePiPController(base: PiPCoordinator(renderer: renderer))
        let connection = CloudConnectionTester(credentials: credentials)
        let scheduler = TranslationScheduler(
            aiTranslator: CompatibleChatTranslator(credentials: credentials, clock: clock),
            localTranslator: AppleLocalTranslator(), clock: clock)
        let session = SessionCoordinator(dependencies: SessionDependencies(
            capability: capability, assets: assets, audioSource: LifecycleAudioSource(base: ScreenCaptureAudioSource(), scope: captureScope),
            audioProcessing: AudioPipeline(), speech: SpeechService(),
            segmenter: CaptionSegmenter(clock: clock), scheduler: scheduler, captions: CaptionStore(),
            renderer: renderer, pip: pip, preferences: store, connectionTester: connection,
            diagnostics: diagnostics, clock: clock))
        self.session = session
        self.assets = assets
        self.renderer = renderer
        self.diagnostics = diagnostics
        self.capability = capability
        self.preferences = preferences
        self.credentials = credentials
        self.cleaner = FirstLaunchCredentialCleaner(credentials: credentials)
        self.lifecycle = LifecycleBridge(session: session, diagnostics: diagnostics, clock: clock, pip: pip, captureScope: captureScope)
        self.setup = SetupViewModel(session: session, capability: capability, assets: assets,
                                   preferences: preferences, credentials: credentials)
        self.cloudSettings = CloudSettingsViewModel(session: session, preferences: preferences,
                                                    credentials: credentials, connectionTester: connection)
    }

    func bootstrap() async {
        guard !isReady, !bootstrapping else { return }
        bootstrapping = true
        defer { bootstrapping = false }
        startupFailed = false
        do {
            try await cleaner.cleanIfNeeded()
            lifecycle.startObserving()
            isReady = true
        } catch {
            startupFailed = true
            await diagnostics.record(.failure(.unavailable))
        }
    }

    static func settleSetupBeforeReplacement(_ setup: SetupViewModel) async {
        if setup.isPreparing { await setup.stop() }
    }

    /// Re-read configuration after the settings tab; never rebuild the running graph.
    func refreshSetup() async {
        let previous = setup
        await Self.settleSetupBeforeReplacement(previous)
        guard setup === previous else { return }
        setup = SetupViewModel(session: session, capability: capability, assets: assets,
                               preferences: preferences, credentials: credentials)
        setupID = UUID()
    }
}
