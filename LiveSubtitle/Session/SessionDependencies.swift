import Foundation

@MainActor
final class SessionMainActorDependencies {
    let assets: any LanguageAssetManaging
    let audioSource: any AudioSource
    let renderer: any SubtitleRendering
    let pip: any PiPControlling

    init(
        assets: any LanguageAssetManaging,
        audioSource: any AudioSource,
        renderer: any SubtitleRendering,
        pip: any PiPControlling
    ) {
        self.assets = assets
        self.audioSource = audioSource
        self.renderer = renderer
        self.pip = pip
    }

    func assetStatus(source: LanguageIdentifier, target: LanguageIdentifier) async -> LanguageAssetStatus {
        await assets.status(source: source, target: target)
    }

    func prepareAssets(source: LanguageIdentifier, target: LanguageIdentifier) -> AsyncStream<AssetEvent> {
        assets.prepare(source: source, target: target)
    }

    func cancelPreparation() {
        assets.cancelPreparation()
    }

    func releaseAssets() async {
        await assets.releaseReservations()
    }

    func startAudio(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        try await audioSource.start(config: config)
    }

    func stopAudio() async {
        await audioSource.stop()
    }

    func present(_ snapshot: SubtitleSnapshot) {
        renderer.present(snapshot)
    }

    func clearRenderer() {
        renderer.clear()
    }

    func startPiP(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        try await pip.start(sessionID: sessionID)
    }

    func stopPiP(sessionID: UUID) async {
        await pip.stop(sessionID: sessionID)
    }
}

struct SessionDependencies: Sendable {
    let capability: any CapabilityChecking
    let mainActor: SessionMainActorDependencies
    let audioProcessing: any AudioProcessing
    let speech: any SpeechRecognizing
    let segmenter: any CaptionSegmenting
    let scheduler: any TranslationScheduling
    let captions: any CaptionStoring
    let preferences: any PreferencesStoring
    let connectionTester: any ConnectionTesting
    let diagnostics: any DiagnosticsRecording
    let clock: any MonotonicClock

    @MainActor
    init(
        capability: any CapabilityChecking,
        assets: any LanguageAssetManaging,
        audioSource: any AudioSource,
        audioProcessing: any AudioProcessing,
        speech: any SpeechRecognizing,
        segmenter: any CaptionSegmenting,
        scheduler: any TranslationScheduling,
        captions: any CaptionStoring,
        renderer: any SubtitleRendering,
        pip: any PiPControlling,
        preferences: any PreferencesStoring,
        connectionTester: any ConnectionTesting,
        diagnostics: any DiagnosticsRecording,
        clock: any MonotonicClock
    ) {
        self.capability = capability
        self.mainActor = SessionMainActorDependencies(
            assets: assets,
            audioSource: audioSource,
            renderer: renderer,
            pip: pip
        )
        self.audioProcessing = audioProcessing
        self.speech = speech
        self.segmenter = segmenter
        self.scheduler = scheduler
        self.captions = captions
        self.preferences = preferences
        self.connectionTester = connectionTester
        self.diagnostics = diagnostics
        self.clock = clock
    }
}
