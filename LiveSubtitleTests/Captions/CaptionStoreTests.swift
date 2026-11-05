import Foundation
#if !TASK06_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

func task06Identity(
    sessionID: UUID = UUID(),
    languageEpoch: UInt64 = 1,
    engineEpoch: UInt64 = 2,
    cloudConfigRevision: UInt64 = 3
) -> SessionIdentity {
    SessionIdentity(sessionID: sessionID, languageEpoch: languageEpoch,
                    engineEpoch: engineEpoch, cloudConfigRevision: cloudConfigRevision)
}

func task06Segment(
    id: UUID = UUID(),
    utteranceID: UUID = UUID(),
    range: AudioRange,
    sourceRevision: UInt64 = 0,
    text: String = "source",
    stability: CaptionStability = .provisional,
    translationState: CaptionTranslationState = .pending
) -> CaptionSegment {
    CaptionSegment(segmentID: id, utteranceID: utteranceID, audioRange: range,
                   sourceRevision: sourceRevision, sourceText: text, stability: stability,
                   translationState: translationState)
}

func task06Job(
    jobID: UUID = UUID(),
    identity: SessionIdentity,
    segmentID: UUID,
    sourceRevision: UInt64 = 0,
    sourceText: String = "source",
    deadline: MonotonicInstant = MonotonicInstant(uptimeNanoseconds: 6_000_000_000)
) -> TranslationJob {
    TranslationJob(jobID: jobID, identity: identity, segmentID: segmentID,
                   sourceRevision: sourceRevision, sourceText: sourceText,
                   sourceLanguage: LanguageIdentifier(rawValue: "en"),
                   targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
                   stability: .provisional, cloudProfile: nil,
                   createdAt: MonotonicInstant(uptimeNanoseconds: 0), deadline: deadline)
}

func task06Update(
    jobID: UUID,
    identity: SessionIdentity,
    segmentID: UUID,
    sourceRevision: UInt64 = 0,
    text: String = "translated",
    isFinal: Bool = true,
    failure: FailureCode? = nil
) -> TranslationUpdate {
    TranslationUpdate(jobID: jobID, identity: identity, segmentID: segmentID,
                      sourceRevision: sourceRevision, text: text, isFinal: isFinal,
                      provider: .ai, failure: failure)
}

private func checkRejectStaleUpdates() async throws {
    let store = CaptionStore()
    let sessionID = UUID()
    let identity = task06Identity(sessionID: sessionID)
    let segmentID = UUID()
    let segment = task06Segment(id: segmentID, range: task06Range(0, 1_000))
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(segment)
    let baseJob = task06Job(identity: identity, segmentID: segmentID)
    let baseUpdate = task06Update(jobID: baseJob.jobID, identity: identity, segmentID: segmentID)

    let wrongIdentities = [
        task06Identity(sessionID: UUID()),
        task06Identity(sessionID: sessionID, languageEpoch: 9),
        task06Identity(sessionID: sessionID, engineEpoch: 9),
        task06Identity(sessionID: sessionID, cloudConfigRevision: 9)
    ]
    for wrongIdentity in wrongIdentities {
        let job = task06Job(identity: wrongIdentity, segmentID: segmentID)
        let update = task06Update(jobID: job.jobID, identity: wrongIdentity, segmentID: segmentID)
        await store.apply(update, for: job, now: MonotonicInstant(uptimeNanoseconds: 1))
    }
    await store.apply(task06Update(jobID: UUID(), identity: identity, segmentID: segmentID),
                      for: baseJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    await store.apply(task06Update(jobID: baseJob.jobID, identity: identity, segmentID: UUID()),
                      for: baseJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    await store.apply(task06Update(jobID: baseJob.jobID, identity: identity, segmentID: segmentID, sourceRevision: 1),
                      for: baseJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    let wrongJob = task06Job(identity: identity, segmentID: segmentID, sourceRevision: 1)
    await store.apply(task06Update(jobID: wrongJob.jobID, identity: identity, segmentID: segmentID, sourceRevision: 1),
                      for: wrongJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    await store.apply(baseUpdate, for: baseJob, now: MonotonicInstant(uptimeNanoseconds: 6_000_000_001))

    let snapshot = try await task06Value(store.snapshot(mode: .ai, status: .listening))
    let retained = try task06Value(snapshot.segments.first)
    if case .pending = retained.translationState {
        // Every mismatched identity, job and revision was ignored.
    } else {
        throw Task06CheckFailure(message: "a stale translation changed the retained segment")
    }

    for index in 1...10 {
        await store.upsert(task06Segment(range: task06Range(Int64(index) * 2_000, Int64(index) * 2_000 + 1_000),
                                         text: "segment \(index)"))
    }
    await store.apply(baseUpdate, for: baseJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    let afterEviction = try await task06Value(store.snapshot(mode: .ai, status: .listening))
    try task06Require(!afterEviction.segments.contains { $0.segmentID == segmentID },
                      "a late result must not resurrect an evicted segment")
}

private func checkSnapshotOrderAndDisplayChange() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    let early = task06Segment(range: task06Range(0, 1_000), text: "early")
    let middle = task06Segment(range: task06Range(1_000, 2_000), text: "middle")
    let late = task06Segment(range: task06Range(2_000, 3_000), text: "late")
    for segment in [late, early, middle] { await store.upsert(segment) }
    let job = task06Job(identity: identity, segmentID: early.segmentID, sourceText: early.sourceText)
    await store.apply(task06Update(jobID: job.jobID, identity: identity, segmentID: early.segmentID),
                      for: job, now: MonotonicInstant(uptimeNanoseconds: 1))

    let initial = try await task06Value(store.snapshot(mode: .ai, status: .listening))
    try task06Require(initial.segments.map(\.sourceText) == ["early", "middle", "late"],
                      "snapshot order must follow source audio time, not completion order")
    for count in [1, 10, 3] {
        await store.setDisplay(DisplayPreferences(displayCount: count, displayStyle: .translationOnly))
        let snapshot = try await task06Value(store.snapshot(mode: .local, status: .listening))
        try task06Require(snapshot.displayCount == count && snapshot.displayStyle == .translationOnly,
                          "display preferences must update immediately")
        try task06Require(snapshot.segments.map(\.sourceRevision) == [0, 0, 0],
                          "a display-only change must not create source revisions or translation work")
        if case .translated(let text, _, _) = snapshot.segments[0].translationState {
            try task06Require(text == "translated", "display changes must preserve existing translations")
        } else {
            throw Task06CheckFailure(message: "display changes discarded a translation")
        }
    }
}

private func checkRevisionMarksPreviousTranslationUpdating() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    let segment = task06Segment(range: task06Range(0, 1_000))
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(segment)
    let job = task06Job(identity: identity, segmentID: segment.segmentID)
    await store.apply(task06Update(jobID: job.jobID, identity: identity, segmentID: segment.segmentID),
                      for: job, now: MonotonicInstant(uptimeNanoseconds: 1))
    await store.upsert(task06Segment(id: segment.segmentID, utteranceID: segment.utteranceID,
                                     range: segment.audioRange, sourceRevision: 1, text: "revised"))
    let snapshot = try await task06Value(store.snapshot(mode: .ai, status: .listening))
    if case .updating(let previousText, let previousProvider) = snapshot.segments[0].translationState {
        try task06Require(previousText == "translated" && previousProvider == .ai,
                          "a source revision should retain the old translation only as updating context")
    } else {
        throw Task06CheckFailure(message: "a source revision did not invalidate the current translation")
    }
}

private func checkStoreRetainsOnlyTenSegments() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    for index in 0..<12 {
        await store.upsert(task06Segment(range: task06Range(Int64(index) * 1_000, Int64(index) * 1_000 + 500),
                                         text: "segment \(index)"))
    }
    let snapshot = try await task06Value(store.snapshot(mode: .local, status: .listening))
    try task06Require(snapshot.segments.count == 10 && snapshot.segments.first?.sourceText == "segment 2",
                      "retained captions must be the latest ten source-time segments")
}

private func checkClearRemovesSessionContent() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(task06Segment(range: task06Range(0, 1_000)))
    await store.clear()
    let snapshot = await store.snapshot(mode: .local, status: .stopping)
    try task06Require(snapshot == nil, "clear must remove every retained caption and its session identity")
}

private func checkAdvanceIdentityAcceptsOnlyNewGeneration() async throws {
    let store = CaptionStore()
    let oldIdentity = task06Identity()
    let newIdentity = task06Identity(sessionID: oldIdentity.sessionID, languageEpoch: oldIdentity.languageEpoch,
                                     engineEpoch: oldIdentity.engineEpoch + 1,
                                     cloudConfigRevision: oldIdentity.cloudConfigRevision)
    let segment = task06Segment(range: task06Range(0, 1_000))
    await store.begin(identity: oldIdentity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(segment)
    await store.advanceIdentity(newIdentity)
    let oldJob = task06Job(identity: oldIdentity, segmentID: segment.segmentID)
    await store.apply(task06Update(jobID: oldJob.jobID, identity: oldIdentity, segmentID: segment.segmentID),
                      for: oldJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    let newJob = task06Job(identity: newIdentity, segmentID: segment.segmentID)
    await store.apply(task06Update(jobID: newJob.jobID, identity: newIdentity, segmentID: segment.segmentID),
                      for: newJob, now: MonotonicInstant(uptimeNanoseconds: 1))
    let snapshot = try await task06Value(store.snapshot(mode: .localFallback, status: .localFallback))
    if case .translated = snapshot.segments[0].translationState {
        // Only the advanced identity may write.
    } else {
        throw Task06CheckFailure(message: "identity advancement did not isolate old and new translation generations")
    }
}

private func checkFailureUpdatesRetainedSegment() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    let segment = task06Segment(range: task06Range(0, 1_000))
    await store.begin(identity: identity, display: DisplayPreferences(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(segment)
    let job = task06Job(identity: identity, segmentID: segment.segmentID)
    let update = task06Update(jobID: job.jobID, identity: identity, segmentID: segment.segmentID,
                              failure: .localTranslationFailed)
    await store.apply(update, for: job, now: MonotonicInstant(uptimeNanoseconds: 1))
    let snapshot = try await task06Value(store.snapshot(mode: .local, status: .failed(.localTranslationFailed)))
    if case .failed(let code) = snapshot.segments[0].translationState {
        try task06Require(code == .localTranslationFailed, "a current failure must replace pending state")
    } else {
        throw Task06CheckFailure(message: "a current translation failure was not stored")
    }
}

private func checkRemovalRejectsLateUpdates() async throws {
    let store = CaptionStore()
    let identity = task06Identity()
    let removed = task06Segment(range: task06Range(0, 1_000))
    let retained = task06Segment(range: task06Range(1_000, 2_000), text: "retained")
    await store.begin(identity: identity, display: .init(displayCount: 3, displayStyle: .bilingual))
    await store.upsert(removed)
    await store.upsert(retained)
    await store.remove(segmentID: removed.segmentID)
    await store.remove(segmentID: UUID())
    let job = task06Job(identity: identity, segmentID: removed.segmentID)
    for failure in [nil, FailureCode.localTranslationFailed] {
        await store.apply(task06Update(jobID: job.jobID, identity: identity, segmentID: removed.segmentID,
                                       failure: failure), for: job, now: task06Instant(1))
    }
    let snapshot = try await task06Value(store.snapshot(mode: .local, status: .listening))
    try task06Require(snapshot.segments.map(\.segmentID) == [retained.segmentID],
                      "removed rows reappeared after late successful/failed translation")
    if case .pending = snapshot.segments[0].translationState {} else {
        throw Task06CheckFailure(message: "removal modified another retained row")
    }
}

func runCaptionStoreChecks() async throws {
    try await checkRemovalRejectsLateUpdates()
    try await checkRejectStaleUpdates()
    try await checkSnapshotOrderAndDisplayChange()
    try await checkRevisionMarksPreviousTranslationUpdating()
    try await checkStoreRetainsOnlyTenSegments()
    try await checkClearRemovesSessionContent()
    try await checkAdvanceIdentityAcceptsOnlyNewGeneration()
    try await checkFailureUpdatesRetainedSegment()
}

#if !TASK06_HOST_CHECK
struct CaptionStoreTests {
    @Test func testRemovalRejectsLateUpdates() async throws { try await checkRemovalRejectsLateUpdates() }
    @Test func testRejectStaleUpdates() async throws { try await checkRejectStaleUpdates() }
    @Test func testSnapshotOrderAndDisplayChange() async throws { try await checkSnapshotOrderAndDisplayChange() }
    @Test func testRevisionMarksPreviousTranslationUpdating() async throws { try await checkRevisionMarksPreviousTranslationUpdating() }
    @Test func testStoreRetainsOnlyTenSegments() async throws { try await checkStoreRetainsOnlyTenSegments() }
    @Test func testClearRemovesSessionContent() async throws { try await checkClearRemovesSessionContent() }
    @Test func testAdvanceIdentityAcceptsOnlyNewGeneration() async throws { try await checkAdvanceIdentityAcceptsOnlyNewGeneration() }
    @Test func testFailureUpdatesRetainedSegment() async throws { try await checkFailureUpdatesRetainedSegment() }
}
#endif
