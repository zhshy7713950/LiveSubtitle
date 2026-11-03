import Foundation
import Observation
import Speech
import Translation

protocol RecognitionAssetProviding: Sendable {
    func status(source: LanguageIdentifier) async -> AssetState
    func prepare(source: LanguageIdentifier) async throws
    func releaseReservations() async
}

protocol TranslationAssetProviding: Sendable {
    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> AssetState
}

extension SystemTranslationCapabilityProvider: TranslationAssetProviding {}

@MainActor
@Observable
final class LanguageAssetManager: LanguageAssetManaging {
    private let recognition: any RecognitionAssetProviding
    private let translation: any TranslationAssetProviding

    private(set) var translationConfiguration: TranslationSession.Configuration?

    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<AssetEvent>.Continuation?
    @ObservationIgnored private var translationContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var completedTranslationID: UUID?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    init(
        recognition: any RecognitionAssetProviding = SystemRecognitionAssetProvider(),
        translation: any TranslationAssetProviding = SystemTranslationCapabilityProvider()
    ) {
        self.recognition = recognition
        self.translation = translation
    }

    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> LanguageAssetStatus {
        async let recognition = recognition.status(source: source)
        async let translation = translation.status(source: source, target: target)
        return await LanguageAssetStatus(recognition: recognition, localTranslation: translation)
    }

    func prepare(source: LanguageIdentifier, target: LanguageIdentifier) -> AsyncStream<AssetEvent> {
        cancelPreparation()
        scheduleReservationRelease()
        let id = UUID()
        preparationID = id
        let stream = AsyncStream<AssetEvent>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard self?.preparationID == id else { return }
                    self?.cancelPreparation()
                }
            }
        }
        preparationTask = Task { @MainActor [weak self] in
            await self?.runPreparation(id: id, source: source, target: target)
        }
        return stream
    }

    func cancelPreparation() {
        guard preparationID != nil else { return }
        preparationID = nil
        translationConfiguration = nil
        preparationTask?.cancel()
        preparationTask = nil
        translationContinuation?.resume(returning: false)
        translationContinuation = nil
        completedTranslationID = nil
        continuation?.yield(.cancelled)
        continuation?.finish()
        continuation = nil
        scheduleReservationRelease()
    }

    func releaseReservations() async {
        cancelPreparation()
        scheduleReservationRelease()
        await releaseTask?.value
        releaseTask = nil
    }

    var preparationToken: UUID? { preparationID }

    func completeTranslationPreparation(token: UUID?) {
        guard preparationID != nil, preparationID == token else { return }
        completedTranslationID = token
        translationContinuation?.resume(returning: true)
        translationContinuation = nil
    }

    func failTranslationPreparation(token: UUID?, cancelled: Bool) {
        guard let id = preparationID, id == token else { return }
        if cancelled {
            cancelPreparation()
        } else {
            failPreparation(id: id, code: .assetsMissing)
        }
    }

    private func runPreparation(id: UUID, source: LanguageIdentifier, target: LanguageIdentifier) async {
        do {
            await releaseTask?.value
            releaseTask = nil
            try Task.checkCancellation()
            var current = await status(source: source, target: target)
            guard preparationID == id else { return }
            continuation?.yield(.status(current))
            guard current.recognition != .unsupported, current.localTranslation != .unsupported else {
                throw FailureCode.unsupportedLanguage
            }
            guard current.recognition != .ready || current.localTranslation != .ready else {
                completePreparation(id: id)
                return
            }

            current = LanguageAssetStatus(
                recognition: current.recognition == .missing ? .preparing : current.recognition,
                localTranslation: current.localTranslation == .missing ? .preparing : current.localTranslation
            )
            continuation?.yield(.status(current))
            if current.localTranslation == .preparing {
                translationConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: source.rawValue),
                    target: Locale.Language(identifier: target.rawValue),
                    preferredStrategy: .lowLatency
                )
            }
            if current.recognition == .preparing {
                try await recognition.prepare(source: source)
            }
            try Task.checkCancellation()
            if current.localTranslation == .preparing {
                let prepared: Bool
                if completedTranslationID == id {
                    completedTranslationID = nil
                    prepared = true
                } else {
                    prepared = await withCheckedContinuation { continuation in
                        translationContinuation = continuation
                    }
                }
                guard prepared else { throw FailureCode.preparationCancelled }
            }
            try Task.checkCancellation()
            let final = await status(source: source, target: target)
            guard preparationID == id else { return }
            continuation?.yield(.status(final))
            guard final.recognition == .ready, final.localTranslation == .ready else {
                throw FailureCode.assetsMissing
            }
            completePreparation(id: id)
        } catch {
            guard preparationID == id else { return }
            if Task.isCancelled || error is CancellationError {
                cancelPreparation()
            } else {
                failPreparation(id: id, code: (error as? FailureCode) ?? .assetsMissing)
            }
        }
    }

    private func completePreparation(id: UUID) {
        guard preparationID == id else { return }
        preparationID = nil
        translationConfiguration = nil
        completedTranslationID = nil
        preparationTask = nil
        continuation?.yield(.finished)
        continuation?.finish()
        continuation = nil
    }

    private func failPreparation(id: UUID, code: FailureCode) {
        guard preparationID == id else { return }
        preparationID = nil
        translationConfiguration = nil
        completedTranslationID = nil
        preparationTask = nil
        translationContinuation?.resume(returning: false)
        translationContinuation = nil
        continuation?.yield(.failed(code))
        continuation?.finish()
        continuation = nil
        scheduleReservationRelease()
    }

    private func scheduleReservationRelease() {
        guard releaseTask == nil else { return }
        releaseTask = Task { await recognition.releaseReservations() }
    }
}

actor SystemRecognitionAssetProvider: RecognitionAssetProviding {
    private var ownedReservations: Set<Locale> = []

    func status(source: LanguageIdentifier) async -> AssetState {
        await SystemSpeechCapabilityProvider().recognitionStatus(source: source)
    }

    func prepare(source: LanguageIdentifier) async throws {
        guard let module = await SpeechModuleFactory.makeModule(source: source),
              let locale = (module as? any LocaleDependentSpeechModule)?.selectedLocales.first else {
            throw FailureCode.unsupportedLanguage
        }
        try Task.checkCancellation()
        let existing = await AssetInventory.reservedLocales
        if !existing.contains(locale) {
            _ = try await AssetInventory.reserve(locale: locale)
            ownedReservations.insert(locale)
        }
        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw FailureCode.assetsMissing
        }
    }

    func releaseReservations() async {
        let reservations = ownedReservations
        ownedReservations.removeAll()
        for locale in reservations {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }
}
