import Foundation

/// Each stream belongs to exactly one job. Cancellation must release its work.
protocol Translator: Sendable {
    func translate(_ job: TranslationJob) async -> AsyncStream<TranslationUpdate>
    func cancelAll() async
}

protocol ConnectionTesting: Sendable {
    /// Uses a fixed harmless sentence; must never consume current subtitles.
    func test(profile: CloudProfile) async -> Result<Void, FailureCode>
    func cancel() async
}

protocol TranslationScheduling: Sendable {
    func start(identity: SessionIdentity, config: SessionConfig, profile: CloudProfile?) async throws -> AsyncStream<SchedulingEvent>
    func submit(_ segment: CaptionSegment) async
    /// Remove job references and revision indexes when the store evicts a segment.
    func retainOnly(segmentIDs: Set<UUID>) async
    /// Caller owns epoch increments. Only explicit user action enables AI.
    func setMode(_ mode: EffectiveMode, identity: SessionIdentity, config: SessionConfig, profile: CloudProfile?) async throws
    func stop() async
}

protocol CaptionStoring: Sendable {
    func begin(identity: SessionIdentity, display: DisplayPreferences) async
    func advanceIdentity(_ identity: SessionIdentity) async
    func upsert(_ segment: CaptionSegment) async
    /// Delete a superseded row before accepting further translation results.
    func remove(segmentID: UUID) async
    func apply(_ update: TranslationUpdate, for job: TranslationJob, now: MonotonicInstant) async
    func setDisplay(_ preferences: DisplayPreferences) async
    func snapshot(mode: EffectiveMode, status: SubtitleStatus) async -> SubtitleSnapshot?
    func clear() async
}
