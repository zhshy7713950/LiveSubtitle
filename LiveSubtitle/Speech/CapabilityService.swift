import Foundation
import Speech
import Translation

protocol SpeechCapabilityProviding: Sendable {
    func supportedLanguages() async -> [LanguageIdentifier]
    func recognitionStatus(source: LanguageIdentifier) async -> AssetState
}

protocol TranslationCapabilityProviding: Sendable {
    func supportedLanguages() async -> [LanguageIdentifier]
    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> AssetState
}

struct CapabilityService: CapabilityChecking {
    private let speech: any SpeechCapabilityProviding
    private let translation: any TranslationCapabilityProviding

    init(
        speech: any SpeechCapabilityProviding = SystemSpeechCapabilityProvider(),
        translation: any TranslationCapabilityProviding = SystemTranslationCapabilityProvider()
    ) {
        self.speech = speech
        self.translation = translation
    }

    func check(config: SessionConfig) async -> CapabilityReport {
        async let sourceLanguages = speech.supportedLanguages()
        async let targetLanguages = translation.supportedLanguages()

        guard config.sourceLanguage != config.targetLanguage else {
            return CapabilityReport(
                sourceLanguages: await sourceLanguages,
                targetLanguages: await targetLanguages,
                assets: LanguageAssetStatus(recognition: .unsupported, localTranslation: .unsupported),
                blockers: [.unsupportedLanguage]
            )
        }

        async let recognition = speech.recognitionStatus(source: config.sourceLanguage)
        async let localTranslation = translation.status(
            source: config.sourceLanguage,
            target: config.targetLanguage
        )
        let assets = await LanguageAssetStatus(
            recognition: recognition,
            localTranslation: localTranslation
        )
        var blockers: [FailureCode] = []
        if assets.recognition == .unsupported || assets.localTranslation == .unsupported {
            blockers.append(.unsupportedLanguage)
        }
        if assets.recognition != .ready && assets.recognition != .unsupported ||
            assets.localTranslation != .ready && assets.localTranslation != .unsupported {
            blockers.append(.assetsMissing)
        }
        return CapabilityReport(
            sourceLanguages: await sourceLanguages,
            targetLanguages: await targetLanguages,
            assets: assets,
            blockers: blockers
        )
    }
}

struct SystemSpeechCapabilityProvider: SpeechCapabilityProviding {
    func supportedLanguages() async -> [LanguageIdentifier] {
        let locales: [Locale]
        if SpeechTranscriber.isAvailable {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = await DictationTranscriber.supportedLocales
        }
        return locales.map { LanguageIdentifier(rawValue: $0.identifier) }
    }

    func recognitionStatus(source: LanguageIdentifier) async -> AssetState {
        guard let module = await SpeechModuleFactory.makeModule(source: source) else {
            return .unsupported
        }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .downloading: return .preparing
        case .supported: return .missing
        case .unsupported: return .unsupported
        default: return .unsupported
        }
    }
}

struct SystemTranslationCapabilityProvider: TranslationCapabilityProviding {
    func supportedLanguages() async -> [LanguageIdentifier] {
        await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages.map {
            LanguageIdentifier(rawValue: $0.maximalIdentifier)
        }
    }

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> AssetState {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        switch await availability.status(
            from: Locale.Language(identifier: source.rawValue),
            to: Locale.Language(identifier: target.rawValue)
        ) {
        case .installed: return .ready
        case .supported: return .missing
        case .unsupported: return .unsupported
        default: return .unsupported
        }
    }
}

enum SpeechModuleFactory {
    static func makeModule(source: LanguageIdentifier) async -> (any SpeechModule)? {
        let requested = Locale(identifier: source.rawValue)
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            return nil
        }
        return DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }
}
