import Foundation
import Synchronization
#if !TASK07_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private struct Task07CheckFailure: Error {
    let message: String
}

private func task07Require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Task07CheckFailure(message: message) }
}

private func task07Eventually(
    _ message: String,
    condition: () async -> Bool
) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw Task07CheckFailure(message: message)
}

private func task07Job(
    jobID: UUID = UUID(),
    identity: SessionIdentity = SessionIdentity(
        sessionID: UUID(), languageEpoch: 1, engineEpoch: 2, cloudConfigRevision: 3
    ),
    segmentID: UUID = UUID(),
    sourceRevision: UInt64 = 7,
    sourceText: String = "synthetic source",
    sourceLanguage: LanguageIdentifier = LanguageIdentifier(rawValue: "en"),
    targetLanguage: LanguageIdentifier = LanguageIdentifier(rawValue: "zh-Hans")
) -> TranslationJob {
    TranslationJob(
        jobID: jobID,
        identity: identity,
        segmentID: segmentID,
        sourceRevision: sourceRevision,
        sourceText: sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        stability: .provisional,
        cloudProfile: nil,
        createdAt: MonotonicInstant(uptimeNanoseconds: 10),
        deadline: MonotonicInstant(uptimeNanoseconds: 6_000_000_010)
    )
}

private func task07Collect(_ stream: AsyncStream<TranslationUpdate>) async -> [TranslationUpdate] {
    var updates: [TranslationUpdate] = []
    for await update in stream { updates.append(update) }
    return updates
}

private func checkPreservesJobIdentity() async throws {
    let session = LocalSessionStub(result: .success("累计替换译文"))
    let factory = LocalSessionFactoryStub(sessions: [session])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)
    let job = task07Job()

    let updates = await task07Collect(await translator.translate(job))

    try task07Require(updates.count == 1, "one local response must close the per-job stream")
    guard let update = updates.first else { return }
    try task07Require(update.jobID == job.jobID, "job identity changed")
    try task07Require(update.identity == job.identity, "full session identity changed")
    try task07Require(update.segmentID == job.segmentID, "segment identity changed")
    try task07Require(update.sourceRevision == job.sourceRevision, "source revision changed")
    try task07Require(update.text == "累计替换译文", "local text is not a cumulative replacement")
    try task07Require(update.isFinal, "the only local response must be final")
    try task07Require(update.failure == nil, "successful local response contains a failure")
    if case .local = update.provider {
        // The caption store relies on the actual provider.
    } else {
        throw Task07CheckFailure(message: "local output must be marked local")
    }
    try task07Require(await session.receivedTexts == ["synthetic source"], "source text was not forwarded exactly")
}

private func checkNoDownloadFromRuntime() async throws {
    let session = LocalSessionStub(ready: false)
    let factory = LocalSessionFactoryStub(sessions: [session])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)

    let updates = await task07Collect(await translator.translate(task07Job()))

    try task07Require(updates.count == 1, "missing assets must terminate the stream")
    try task07Require(updates.first?.failure == .assetsMissing, "missing assets returned the wrong failure")
    try task07Require(updates.first?.text.isEmpty == true, "missing assets produced subtitle text")
    try task07Require(await session.receivedTexts.isEmpty, "runtime attempted translation without installed assets")
}

private func checkCancelReleasesAndDropsLateResult() async throws {
    let cancelledSession = LocalSessionStub(waitsForRelease: true, result: .success("late"))
    let cancelledFactory = LocalSessionFactoryStub(sessions: [cancelledSession])
    let cancelledTranslator = AppleLocalTranslator(sessionFactory: cancelledFactory.makeSession)
    let cancelledStream = await cancelledTranslator.translate(task07Job())
    try await task07Eventually("translation did not start") {
        await cancelledSession.receivedTexts.count == 1
    }

    await cancelledTranslator.cancelAll()
    let cancelledUpdates = await task07Collect(cancelledStream)
    await cancelledSession.releasePendingTranslation()

    try task07Require(await cancelledSession.cancelCount == 1, "cancelAll did not cancel the system session")
    try task07Require(cancelledUpdates.isEmpty, "cancelAll emitted a late result")

    let consumerSession = LocalSessionStub(waitsForRelease: true, result: .success("late"))
    let consumerFactory = LocalSessionFactoryStub(sessions: [consumerSession])
    let consumerTranslator = AppleLocalTranslator(sessionFactory: consumerFactory.makeSession)
    let consumerStream = await consumerTranslator.translate(task07Job())
    let consumer = Task { await task07Collect(consumerStream) }
    try await task07Eventually("consumer translation did not start") {
        await consumerSession.receivedTexts.count == 1
    }

    consumer.cancel()
    let consumerUpdates = await consumer.value
    try await task07Eventually("consumer termination did not cancel the system session") {
        await consumerSession.cancelCount == 1
    }
    await consumerSession.releasePendingTranslation()

    try task07Require(consumerUpdates.isEmpty, "consumer cancellation emitted a late result")
}

private func checkSessionReuseAndPairChange() async throws {
    let first = LocalSessionStub(result: .success("first"))
    let second = LocalSessionStub(result: .success("second"))
    let factory = LocalSessionFactoryStub(sessions: [first, second])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)

    _ = await task07Collect(await translator.translate(task07Job()))
    _ = await task07Collect(await translator.translate(task07Job()))
    try task07Require(factory.createdCount == 1, "same language pair did not reuse its session")
    try task07Require(await first.cancelCount == 0, "normal stream completion cancelled the reusable session")

    _ = await task07Collect(await translator.translate(task07Job(
        sourceLanguage: LanguageIdentifier(rawValue: "ja")
    )))
    _ = await task07Collect(await translator.translate(task07Job(
        sourceLanguage: LanguageIdentifier(rawValue: "ja")
    )))
    try task07Require(factory.createdCount == 2, "language pair change did not recreate exactly one session")
    try task07Require(await first.cancelCount == 1, "language pair change did not release the old session")

    let failingSession = LocalSessionStub(result: .failure(.systemFailure))
    let failingFactory = LocalSessionFactoryStub(sessions: [failingSession])
    let failingTranslator = AppleLocalTranslator(sessionFactory: failingFactory.makeSession)
    let failures = await task07Collect(await failingTranslator.translate(task07Job()))
    try task07Require(failures.count == 1, "system failure did not close the stream")
    try task07Require(failures.first?.failure == .localTranslationFailed, "system failure leaked an unsafe error")
    try task07Require(failures.first?.text.isEmpty == true, "system failure emitted subtitle text")
}

private func checkOversizedTranslationFails() async throws {
    let session = LocalSessionStub(result: .success(String(
        repeating: "a", count: RuntimePolicy.translationCharacterLimit + 1
    )))
    let factory = LocalSessionFactoryStub(sessions: [session])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)

    let updates = await task07Collect(await translator.translate(task07Job()))

    try task07Require(updates.count == 1, "oversized output did not close the stream")
    try task07Require(updates.first?.failure == .invalidOutput, "oversized output was not rejected")
    try task07Require(updates.first?.text.isEmpty == true, "oversized output leaked into captions")
}

private func checkReadinessFailureDoesNotReportMissingAssets() async throws {
    let session = LocalSessionStub(readinessError: .systemFailure)
    let factory = LocalSessionFactoryStub(sessions: [session])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)

    let updates = await task07Collect(await translator.translate(task07Job()))

    try task07Require(updates.count == 1, "readiness failure did not close the stream")
    try task07Require(
        updates.first?.failure == .localTranslationFailed,
        "readiness transport failure was misreported as missing assets"
    )
    try task07Require(updates.first?.text.isEmpty == true, "readiness failure emitted subtitle text")
}

private func checkConsumerCancellationRetiresSessionBeforeReplacement() async throws {
    let first = LocalSessionStub(
        waitsForRelease: true,
        waitsForFirstCancelRelease: true,
        result: .success("late")
    )
    let second = LocalSessionStub(result: .success("replacement"))
    let factory = LocalSessionFactoryStub(sessions: [first, second])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)
    let oldStream = await translator.translate(task07Job(sourceText: "old"))
    let oldConsumer = Task { await task07Collect(oldStream) }
    try await task07Eventually("old translation did not start") {
        await first.receivedTexts.count == 1
    }

    oldConsumer.cancel()
    try await task07Eventually("old session cancellation did not start") {
        await first.cancelCount == 1
    }
    let replacementStream = await translator.translate(task07Job(sourceText: "new"))
    for _ in 0..<100 { await Task.yield() }
    await first.releaseCancellation()
    await first.releasePendingTranslation()
    let oldUpdates = await oldConsumer.value
    try await task07Eventually("replacement did not use a new session") {
        await second.receivedTexts.count == 1
    }
    let replacementUpdates = await task07Collect(replacementStream)

    try task07Require(oldUpdates.isEmpty, "cancelled revision emitted a late result")
    try task07Require(factory.createdCount == 2, "replacement reused the session being cancelled")
    try task07Require(replacementUpdates.count == 1, "replacement did not finish")
    try task07Require(replacementUpdates.first?.text == "replacement", "replacement used the old translation")
    try task07Require(replacementUpdates.first?.failure == nil, "replacement inherited a cancellation failure")
}

private func checkCancelDuringPairChangeDoesNotCreateSession() async throws {
    let first = LocalSessionStub(waitsForFirstCancelRelease: true)
    let factory = LocalSessionFactoryStub(sessions: [first])
    let translator = AppleLocalTranslator(sessionFactory: factory.makeSession)
    _ = await task07Collect(await translator.translate(task07Job()))
    let changedPairStream = await translator.translate(task07Job(
        sourceLanguage: LanguageIdentifier(rawValue: "ja")
    ))
    try await task07Eventually("language pair change did not start old-session cancellation") {
        await first.cancelCount == 1
    }

    let changedPairUpdates = Task { await task07Collect(changedPairStream) }
    let cancellation = Task { await translator.cancelAll() }
    _ = await changedPairUpdates.value
    await first.releaseCancellation()
    await cancellation.value

    try task07Require(
        factory.createdCount == 1,
        "a cancelled language-pair change created a replacement session"
    )
}

#if TASK07_HOST_CHECK
@main
private struct Task07HostChecks {
    static func main() async throws {
        try await checkPreservesJobIdentity()
        try await checkNoDownloadFromRuntime()
        try await checkCancelReleasesAndDropsLateResult()
        try await checkSessionReuseAndPairChange()
        try await checkOversizedTranslationFails()
        try await checkReadinessFailureDoesNotReportMissingAssets()
        try await checkConsumerCancellationRetiresSessionBeforeReplacement()
        try await checkCancelDuringPairChangeDoesNotCreateSession()
        print("8 TASK-07 host checks passed; no SDK/device behavior tested.")
    }
}
#else
struct AppleLocalTranslatorTests {
    @Test func testPreservesJobIdentity() async throws { try await checkPreservesJobIdentity() }
    @Test func testNoDownloadFromRuntime() async throws { try await checkNoDownloadFromRuntime() }
    @Test func testCancelReleasesAndDropsLateResult() async throws { try await checkCancelReleasesAndDropsLateResult() }
    @Test func testSessionReuseAndPairChange() async throws { try await checkSessionReuseAndPairChange() }
    @Test func testOversizedTranslationFails() async throws { try await checkOversizedTranslationFails() }
    @Test func testReadinessFailureDoesNotReportMissingAssets() async throws {
        try await checkReadinessFailureDoesNotReportMissingAssets()
    }
    @Test func testConsumerCancellationRetiresSessionBeforeReplacement() async throws {
        try await checkConsumerCancellationRetiresSessionBeforeReplacement()
    }
    @Test func testCancelDuringPairChangeDoesNotCreateSession() async throws {
        try await checkCancelDuringPairChangeDoesNotCreateSession()
    }
}
#endif

private enum LocalSessionStubError: Error, Sendable {
    case systemFailure
}

private actor LocalSessionStub: LocalTranslationSession {
    private let ready: Bool
    private let readinessError: LocalSessionStubError?
    private let waitsForRelease: Bool
    private let waitsForFirstCancelRelease: Bool
    private let result: Result<String, LocalSessionStubError>
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private(set) var receivedTexts: [String] = []
    private(set) var cancelCount = 0

    init(
        ready: Bool = true,
        readinessError: LocalSessionStubError? = nil,
        waitsForRelease: Bool = false,
        waitsForFirstCancelRelease: Bool = false,
        result: Result<String, LocalSessionStubError> = .success("translation")
    ) {
        self.ready = ready
        self.readinessError = readinessError
        self.waitsForRelease = waitsForRelease
        self.waitsForFirstCancelRelease = waitsForFirstCancelRelease
        self.result = result
    }

    func isReady() async throws -> Bool {
        if let readinessError { throw readinessError }
        return ready
    }

    func translate(_ text: String) async throws -> String {
        receivedTexts.append(text)
        if waitsForRelease {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return try result.get()
    }

    func cancel() async {
        cancelCount += 1
        if waitsForFirstCancelRelease && cancelCount == 1 {
            await withCheckedContinuation { continuation in
                cancellationContinuation = continuation
            }
        }
        releasePendingTranslation()
    }

    func releasePendingTranslation() {
        for continuation in releaseContinuations { continuation.resume() }
        releaseContinuations.removeAll()
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private final class LocalSessionFactoryStub: Sendable {
    private struct State {
        var remaining: [LocalSessionStub]
        var created: [LocalSessionStub] = []
    }

    private let state: Mutex<State>

    init(sessions: [LocalSessionStub]) {
        state = Mutex(State(remaining: sessions))
    }

    var createdCount: Int { state.withLock { $0.created.count } }

    func makeSession(
        source: LanguageIdentifier,
        target: LanguageIdentifier
    ) -> any LocalTranslationSession {
        state.withLock { state in
            let session = state.remaining.isEmpty ? LocalSessionStub() : state.remaining.removeFirst()
            state.created.append(session)
            return session
        }
    }
}
