import Foundation
import Translation

protocol LocalTranslationSession: Sendable {
    func isReady() async throws -> Bool
    func translate(_ text: String) async throws -> String
    func cancel() async
}

typealias LocalTranslationSessionFactory = @Sendable (
    _ source: LanguageIdentifier,
    _ target: LanguageIdentifier
) -> any LocalTranslationSession

actor AppleLocalTranslator: Translator {
    private struct LanguagePair: Hashable {
        let source: LanguageIdentifier
        let target: LanguageIdentifier
    }

    private struct JobWork {
        let job: TranslationJob
        let pair: LanguagePair
        let continuation: AsyncStream<TranslationUpdate>.Continuation
    }

    private let sessionFactory: LocalTranslationSessionFactory
    private var session: (pair: LanguagePair, value: any LocalTranslationSession)?
    private var jobs: [UUID: JobWork] = [:]
    private var queue: [UUID] = []
    private var runningJobID: UUID?
    private var runningTask: Task<Void, Never>?

    init(sessionFactory: @escaping LocalTranslationSessionFactory = { source, target in
        SystemLocalTranslationSession(source: source, target: target)
    }) {
        self.sessionFactory = sessionFactory
    }

    func translate(_ job: TranslationJob) async -> AsyncStream<TranslationUpdate> {
        let pair = LanguagePair(source: job.sourceLanguage, target: job.targetLanguage)
        let (stream, continuation) = AsyncStream<TranslationUpdate>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        jobs[job.jobID] = JobWork(job: job, pair: pair, continuation: continuation)
        queue.append(job.jobID)
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancelJob(job.jobID) }
        }
        startNextIfNeeded()
        return stream
    }

    func cancelAll() async {
        let cancelled = Array(jobs.values)
        jobs.removeAll()
        queue.removeAll()
        for work in cancelled { work.continuation.finish() }
        let task = runningTask
        runningJobID = nil
        runningTask = nil
        task?.cancel()
        let previous = session
        session = nil
        if let previous { await previous.value.cancel() }
        await task?.value
    }

    private func startNextIfNeeded() {
        while runningJobID == nil && !queue.isEmpty {
            let jobID = queue.removeFirst()
            guard let work = jobs[jobID] else { continue }
            runningJobID = jobID
            runningTask = Task { [weak self] in
                guard let self else { return }
                await self.run(work.job, pair: work.pair)
            }
        }
    }

    private func run(_ job: TranslationJob, pair: LanguagePair) async {
        defer { finish(job.jobID) }
        guard isActive(job.jobID) else { return }
        guard let session = await session(for: pair, jobID: job.jobID) else { return }
        guard isActive(job.jobID) else { return }
        do {
            guard try await session.isReady() else {
                emit(TranslationUpdate(
                    jobID: job.jobID,
                    identity: job.identity,
                    segmentID: job.segmentID,
                    sourceRevision: job.sourceRevision,
                    text: "",
                    isFinal: false,
                    provider: .local,
                    failure: .assetsMissing
                ), for: job.jobID)
                return
            }
            guard isActive(job.jobID) else { return }
            let text = try await session.translate(job.sourceText)
            guard isActive(job.jobID) else { return }
            emit(TranslationUpdate(
                jobID: job.jobID,
                identity: job.identity,
                segmentID: job.segmentID,
                sourceRevision: job.sourceRevision,
                text: text.count <= RuntimePolicy.translationCharacterLimit ? text : "",
                isFinal: text.count <= RuntimePolicy.translationCharacterLimit,
                provider: .local,
                failure: text.count <= RuntimePolicy.translationCharacterLimit ? nil : .invalidOutput
            ), for: job.jobID)
        } catch is CancellationError {
            return
        } catch {
            guard isActive(job.jobID) else { return }
            emit(TranslationUpdate(
                jobID: job.jobID,
                identity: job.identity,
                segmentID: job.segmentID,
                sourceRevision: job.sourceRevision,
                text: "",
                isFinal: false,
                provider: .local,
                failure: .localTranslationFailed
            ), for: job.jobID)
        }
    }

    private func session(for pair: LanguagePair, jobID: UUID) async -> (any LocalTranslationSession)? {
        if let session, session.pair == pair { return session.value }
        let previous = session
        session = nil
        if let previous { await previous.value.cancel() }
        guard isActive(jobID) else { return nil }
        let value = sessionFactory(pair.source, pair.target)
        session = (pair, value)
        return value
    }

    private func isActive(_ jobID: UUID) -> Bool {
        jobs[jobID] != nil && runningJobID == jobID && !Task.isCancelled
    }

    private func emit(_ update: TranslationUpdate, for jobID: UUID) {
        guard isActive(jobID), let work = jobs[jobID] else { return }
        work.continuation.yield(update)
    }

    private func finish(_ jobID: UUID) {
        guard let work = jobs.removeValue(forKey: jobID) else { return }
        work.continuation.finish()
        if runningJobID == jobID {
            runningJobID = nil
            runningTask = nil
            startNextIfNeeded()
        }
    }

    private func cancelJob(_ jobID: UUID) async {
        guard let work = jobs.removeValue(forKey: jobID) else { return }
        work.continuation.finish()
        queue.removeAll { $0 == jobID }
        guard runningJobID == jobID else { return }
        let task = runningTask
        task?.cancel()
        let previous = session
        session = nil
        if let previous { await previous.value.cancel() }
        await task?.value
        if runningJobID == jobID {
            runningJobID = nil
            runningTask = nil
            startNextIfNeeded()
        }
    }
}

private final class SystemLocalTranslationSession: LocalTranslationSession {
    private enum Command: Sendable {
        case isReady(AsyncStream<Bool>.Continuation)
        case translate(String, AsyncStream<Result<String, FailureCode>>.Continuation)
    }

    private let commands: AsyncStream<Command>.Continuation
    private let ownerTask: Task<Void, Never>

    init(source: LanguageIdentifier, target: LanguageIdentifier) {
        let (stream, continuation) = AsyncStream<Command>.makeStream(
            bufferingPolicy: .bufferingOldest(4)
        )
        commands = continuation
        ownerTask = Task.detached {
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: source.rawValue),
                target: Locale.Language(identifier: target.rawValue),
                preferredStrategy: .lowLatency
            )
            defer { session.cancel() }
            for await command in stream {
                if Task.isCancelled { break }
                switch command {
                case .isReady(let response):
                    response.yield(await session.isReady)
                    response.finish()
                case .translate(let text, let response):
                    do {
                        let translated = try await session.translate(text).targetText
                        response.yield(.success(translated))
                    } catch {
                        response.yield(.failure(.localTranslationFailed))
                    }
                    response.finish()
                }
            }
        }
    }

    deinit {
        commands.finish()
        ownerTask.cancel()
    }

    func isReady() async throws -> Bool {
        let (stream, response) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        switch commands.yield(.isReady(response)) {
        case .enqueued:
            break
        case .dropped:
            response.finish()
            throw FailureCode.localTranslationFailed
        case .terminated:
            response.finish()
            throw CancellationError()
        @unknown default:
            response.finish()
            throw FailureCode.localTranslationFailed
        }
        var iterator = stream.makeAsyncIterator()
        guard let ready = await iterator.next() else { throw CancellationError() }
        return ready
    }

    func translate(_ text: String) async throws -> String {
        let (stream, response) = AsyncStream<Result<String, FailureCode>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        switch commands.yield(.translate(text, response)) {
        case .enqueued:
            break
        case .dropped:
            response.finish()
            throw FailureCode.localTranslationFailed
        case .terminated:
            response.finish()
            throw CancellationError()
        @unknown default:
            response.finish()
            throw FailureCode.localTranslationFailed
        }
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        return try result.get()
    }

    func cancel() async {
        commands.finish()
        ownerTask.cancel()
    }
}
