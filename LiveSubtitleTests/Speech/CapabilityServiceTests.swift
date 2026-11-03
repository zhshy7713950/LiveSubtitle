import Testing
@testable import LiveSubtitle

private let testEnglish = LanguageIdentifier(rawValue: "en")
private let testChinese = LanguageIdentifier(rawValue: "zh-Hans")

struct CapabilityServiceTests {
    @Test
    func testUnsupportedPairBlocksBothModes() async {
        let speech = SpeechCapabilityStub(languages: [testEnglish], status: .ready)
        let translation = TranslationCapabilityStub(languages: [testEnglish, testChinese], pairStatus: .unsupported)
        let service = CapabilityService(speech: speech, translation: translation)

        for mode in [RequestedMode.local, .ai] {
            let report = await service.check(config: Self.config(mode: mode))
            #expect(report.blockers.contains(.unsupportedLanguage))
            #expect(report.assets.localTranslation == .unsupported)
        }

        let sameLanguage = await service.check(config: Self.config(source: "en", target: "en"))
        #expect(sameLanguage.blockers.contains(.unsupportedLanguage))
    }

    @Test
    func testReadinessIsQueriedAgain() async {
        let speech = SpeechCapabilityStub(languages: [testEnglish], statuses: [.ready, .missing])
        let translation = TranslationCapabilityStub(languages: [testEnglish, testChinese], pairStatuses: [.ready, .missing])
        let service = CapabilityService(speech: speech, translation: translation)

        let first = await service.check(config: Self.config())
        let second = await service.check(config: Self.config())

        #expect(first.assets.recognition == .ready)
        #expect(first.assets.localTranslation == .ready)
        #expect(second.assets.recognition == .missing)
        #expect(second.assets.localTranslation == .missing)
        #expect(second.blockers.contains(.assetsMissing))
    }

    @MainActor
    @Test
    func testMissingAssetsAndCancellation() async {
        let recognition = RecognitionAssetStub(statuses: [.missing], waitsForCancellation: true)
        let translation = TranslationAssetStub(status: .missing)
        let manager = LanguageAssetManager(recognition: recognition, translation: translation)
        var iterator = manager.prepare(source: testEnglish, target: testChinese).makeAsyncIterator()

        let initial = await iterator.next()
        expectAssetEvent(initial, recognition: .missing, translation: .missing)
        let preparing = await iterator.next()
        expectAssetEvent(preparing, recognition: .preparing, translation: .preparing)
        #expect(manager.translationConfiguration != nil)

        manager.cancelPreparation()
        var sawCancelled = false
        while let event = await iterator.next() {
            switch event {
            case .cancelled:
                sawCancelled = true
            case .finished:
                Issue.record("取消准备后不得发出 finished")
            default:
                break
            }
        }
        #expect(sawCancelled)
        #expect(manager.translationConfiguration == nil)

        let noInstallRecognition = RecognitionAssetStub(statuses: [.missing, .ready])
        let readyTranslation = TranslationAssetStub(status: .ready)
        let noInstallManager = LanguageAssetManager(
            recognition: noInstallRecognition,
            translation: readyTranslation
        )
        var didFinish = false
        for await event in noInstallManager.prepare(source: testEnglish, target: testChinese) {
            if case .finished = event { didFinish = true }
        }
        #expect(didFinish)
    }

    @MainActor
    @Test
    func testTranslationCompletionBeforeRecognitionFinishes() async {
        let recognition = RecognitionAssetStub(statuses: [.missing, .ready], waitsForRelease: true)
        let translation = TranslationAssetStub(statuses: [.missing, .ready])
        let manager = LanguageAssetManager(recognition: recognition, translation: translation)
        let stream = manager.prepare(source: testEnglish, target: testChinese)
        while manager.translationConfiguration == nil { await Task.yield() }
        while await recognition.prepareCallCount() == 0 { await Task.yield() }

        manager.completeTranslationPreparation(token: manager.preparationToken)
        await recognition.releasePreparation()
        let finished = await withCapabilityTimeout {
            for await event in stream {
                if case .finished = event { return true }
                if case .failed = event { return false }
            }
            return false
        }
        manager.cancelPreparation()
        #expect(finished)
    }

    @MainActor
    @Test
    func testNewLanguageWaitsForPreviousReservationRelease() async {
        let recognition = RecognitionAssetStub(statuses: [.missing, .ready, .missing, .ready])
        let translation = TranslationAssetStub(status: .ready)
        let manager = LanguageAssetManager(recognition: recognition, translation: translation)
        for await _ in manager.prepare(source: testEnglish, target: testChinese) {}
        let secondLanguage = LanguageIdentifier(rawValue: "zh-Hant")
        for await _ in manager.prepare(source: secondLanguage, target: testChinese) {}

        let events = await recognition.eventLog()
        #expect(Array(events.suffix(3)) == ["prepare:en", "release", "prepare:zh-Hant"])
    }

    private func expectAssetEvent(
        _ event: AssetEvent?,
        recognition: AssetState,
        translation: AssetState
    ) {
        guard case .status(let status) = event else {
            Issue.record("缺少资源状态事件")
            return
        }
        #expect(status.recognition == recognition)
        #expect(status.localTranslation == translation)
    }
}

private extension CapabilityServiceTests {
    static func config(
        source: String = "en",
        target: String = "zh-Hans",
        mode: RequestedMode = .local
    ) -> SessionConfig {
        SessionConfig(
            sourceLanguage: LanguageIdentifier(rawValue: source),
            targetLanguage: LanguageIdentifier(rawValue: target),
            requestedMode: mode,
            cloudProfileID: nil,
            displayCount: 3,
            displayStyle: .bilingual
        )
    }
}

private actor SpeechCapabilityStub: SpeechCapabilityProviding {
    let languages: [LanguageIdentifier]
    var statuses: [AssetState]

    init(languages: [LanguageIdentifier], status: AssetState) {
        self.languages = languages
        self.statuses = [status]
    }

    init(languages: [LanguageIdentifier], statuses: [AssetState]) {
        self.languages = languages
        self.statuses = statuses
    }

    func supportedLanguages() async -> [LanguageIdentifier] { languages }

    func recognitionStatus(source: LanguageIdentifier) async -> AssetState {
        guard languages.contains(source) else { return .unsupported }
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }
}

private actor TranslationCapabilityStub: TranslationCapabilityProviding {
    let languages: [LanguageIdentifier]
    var statuses: [AssetState]

    init(languages: [LanguageIdentifier], pairStatus: AssetState) {
        self.languages = languages
        self.statuses = [pairStatus]
    }

    init(languages: [LanguageIdentifier], pairStatuses: [AssetState]) {
        self.languages = languages
        self.statuses = pairStatuses
    }

    func supportedLanguages() async -> [LanguageIdentifier] { languages }

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> AssetState {
        guard languages.contains(source), languages.contains(target) else { return .unsupported }
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }
}

private actor RecognitionAssetStub: RecognitionAssetProviding {
    var statuses: [AssetState]
    let waitsForCancellation: Bool
    let waitsForRelease: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var prepareCalls = 0
    private var events: [String] = []

    init(
        statuses: [AssetState],
        waitsForCancellation: Bool = false,
        waitsForRelease: Bool = false
    ) {
        self.statuses = statuses
        self.waitsForCancellation = waitsForCancellation
        self.waitsForRelease = waitsForRelease
    }

    func status(source: LanguageIdentifier) async -> AssetState {
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }

    func prepare(source: LanguageIdentifier) async throws {
        prepareCalls += 1
        events.append("prepare:\(source.rawValue)")
        if waitsForCancellation {
            try await Task.sleep(for: .seconds(10))
        }
        if waitsForRelease {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func releasePreparation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func prepareCallCount() -> Int { prepareCalls }
    func eventLog() -> [String] { events }

    func releaseReservations() async {
        events.append("release")
    }
}

private actor TranslationAssetStub: TranslationAssetProviding {
    var statuses: [AssetState]

    init(status: AssetState) {
        self.statuses = [status]
    }

    init(statuses: [AssetState]) {
        self.statuses = statuses
    }

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> AssetState {
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }
}

private func withCapabilityTimeout(
    operation: @escaping @Sendable () async -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
