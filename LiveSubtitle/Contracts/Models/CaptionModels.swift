import Foundation

enum CaptionStability: Sendable {
    case provisional, final
}

enum TranslationProvider: Sendable {
    case local, ai
}

enum CaptionTranslationState: Sendable {
    case pending
    case updating(previousText: String?, previousProvider: TranslationProvider?)
    case translated(text: String, isFinal: Bool, provider: TranslationProvider)
    case failed(FailureCode)
}

struct CaptionSegment: Sendable {
    let segmentID: UUID
    let utteranceID: UUID
    let audioRange: AudioRange
    let sourceRevision: UInt64
    let sourceText: String
    let stability: CaptionStability
    let translationState: CaptionTranslationState
}

enum SegmentEvent: Sendable {
    case upsert(CaptionSegment)
    case remove(segmentID: UUID)
    case discontinuity(AudioTimestamp)
}

enum SubtitleStatus: Sendable {
    case waitingForAudio, listening, processingSlowly, localFallback, stopping
    case failed(FailureCode)
}

struct SubtitleSnapshot: Sendable {
    let identity: SessionIdentity
    /// Source-time order, never network completion order.
    let segments: [CaptionSegment]
    let displayCount: Int
    let displayStyle: DisplayStyle
    let effectiveMode: EffectiveMode
    let status: SubtitleStatus
}
