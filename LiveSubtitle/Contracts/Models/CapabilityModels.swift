import Foundation

enum AssetState: Sendable {
    case unsupported, missing, preparing, ready
}

struct LanguageAssetStatus: Sendable {
    let recognition: AssetState
    let localTranslation: AssetState
}

struct CapabilityReport: Sendable {
    let sourceLanguages: [LanguageIdentifier]
    let targetLanguages: [LanguageIdentifier]
    let assets: LanguageAssetStatus
    let blockers: [FailureCode]
}

enum AssetEvent: Sendable {
    case status(LanguageAssetStatus)
    case finished
    case cancelled
    case failed(FailureCode)
}

/// Content-free values only. Dynamic free-form strings are deliberately absent.
enum DiagnosticEvent: Sendable {
    case phase(SessionPhase)
    case failure(FailureCode)
    case audioBuffered(milliseconds: Int)
    case translationQueued(count: Int)
    case droppedAudio(frames: Int)
    case droppedJob
    case stageLatency(stage: DiagnosticStage, nanoseconds: UInt64)
    case residentMemory(bytes: UInt64)
    case thermalState(DiagnosticThermalState)
}

enum DiagnosticThermalState: String, Sendable {
    case nominal, fair, serious, critical, unknown
}

enum DiagnosticStage: Sendable {
    case captureToSpeech, sourceVisible, localTranslationVisible, aiTranslationVisible, stop
}
