import Foundation

struct TranslationJob: Sendable {
    let jobID: UUID
    let identity: SessionIdentity
    let segmentID: UUID
    let sourceRevision: UInt64
    let sourceText: String
    let sourceLanguage: LanguageIdentifier
    let targetLanguage: LanguageIdentifier
    let stability: CaptionStability
    /// Frozen non-secret AI destination for this job; nil for local work.
    let cloudProfile: CloudProfile?
    let createdAt: MonotonicInstant
    let deadline: MonotonicInstant
}

struct TranslationUpdate: Sendable {
    let jobID: UUID
    let identity: SessionIdentity
    let segmentID: UUID
    let sourceRevision: UInt64
    /// Cumulative replacement text for this job, not a delta to append.
    let text: String
    let isFinal: Bool
    let provider: TranslationProvider
    let failure: FailureCode?
}

enum SchedulingEvent: Sendable {
    case translation(job: TranslationJob, update: TranslationUpdate)
    case fallbackRequested(identity: SessionIdentity, reason: FailureCode)
    case dropped(job: TranslationJob)
    case failed(job: TranslationJob, reason: FailureCode)
}

/// Non-secret persisted metadata. Never add an API-key field here.
struct CloudProfile: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let endpoint: URL
    let model: String
    let revision: UInt64
}

struct DisplayPreferences: Codable, Sendable, Equatable {
    let displayCount: Int
    let displayStyle: DisplayStyle
}

struct AppPreferences: Codable, Sendable, Equatable {
    let sourceLanguage: LanguageIdentifier
    let targetLanguage: LanguageIdentifier
    let requestedMode: RequestedMode
    let selectedCloudProfileID: UUID?
    let display: DisplayPreferences
}
