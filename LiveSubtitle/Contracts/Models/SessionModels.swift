import Foundation

struct LanguageIdentifier: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

enum RequestedMode: String, Codable, Sendable {
    case local, ai
}

enum EffectiveMode: String, Sendable {
    case local, ai, localFallback
}

enum DisplayStyle: String, Codable, Sendable {
    case bilingual, translationOnly
}

struct SessionConfig: Sendable, Equatable {
    let sourceLanguage: LanguageIdentifier
    let targetLanguage: LanguageIdentifier
    let requestedMode: RequestedMode
    let cloudProfileID: UUID?
    let displayCount: Int
    let displayStyle: DisplayStyle
}

struct SessionIdentity: Sendable, Hashable {
    let sessionID: UUID
    let languageEpoch: UInt64
    let engineEpoch: UInt64
    let cloudConfigRevision: UInt64
}

/// Host uptime only. Wall-clock Date must not be substituted for this type.
struct MonotonicInstant: Sendable, Equatable, Hashable {
    let uptimeNanoseconds: UInt64
}

enum SessionPhase: String, Sendable {
    case idle, preparing, ready, requestingCapture, starting, running, stopping, failed
}

enum StopReason: Sendable {
    case user, pipClosed, pipReplaced, captureEnded, deviceLocked, interrupted
    case languageChanged, thermalPressure, sustainedBacklog, componentFailure
}

/// Safe categories only: no body text, credentials, endpoint query or raw Error.
enum FailureCode: String, Error, Sendable, Codable {
    case unavailable, unsupportedLanguage, assetsMissing, preparationCancelled
    case captureFailed, speechFailed, localTranslationFailed, pipFailed
    case invalidConfiguration, unauthorized, rateLimited, network, server
    case incompatibleResponse, refused, invalidOutput, firstTextTimeout, deadlineExceeded
}

struct SessionStatus: Sendable {
    let phase: SessionPhase
    let identity: SessionIdentity?
    let requestedMode: RequestedMode
    let effectiveMode: EffectiveMode
    let failure: FailureCode?
}
