#if DEBUG
import Foundation

struct G0Transcript: Sendable {
    let identity: SessionIdentity
    let key: Int64
    let text: String
    let isFinal: Bool
}

struct G0Caption: Sendable, Identifiable {
    let id: Int64
    var revision: UInt64
    var source: String
    var translation = ""
}

struct G0TranslationJob: Sendable {
    let id: UUID
    let identity: SessionIdentity
    let segment: Int64
    let revision: UInt64
    let text: String
    let deadline: MonotonicInstant
}

struct G0Clock: MonotonicClock {
    func now() -> MonotonicInstant { MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) }
    func sleep(until deadline: MonotonicInstant) async throws {
        let current = now().uptimeNanoseconds
        if deadline.uptimeNanoseconds > current {
            try await Task.sleep(for: .nanoseconds(Int64(deadline.uptimeNanoseconds - current)))
        }
        try Task.checkCancellation()
    }
}

/// Temporary G0 authority for identities and bounded translation scheduling.
actor G0RunState {
    private var identity: SessionIdentity?
    private var rows: [G0Caption] = []
    private var pending: [G0TranslationJob] = []
    private var active: G0TranslationJob?
    private var lastSubmission: UInt64 = 0
    private var submitted: [Int64: UInt64] = [:]
    private(set) var maximumPending = 0
    private(set) var translations = 0
    private(set) var staleResults = 0
    private let clock: any MonotonicClock
    init(clock: any MonotonicClock = G0Clock()) { self.clock = clock }

    func begin() -> SessionIdentity {
        let token = SessionIdentity(sessionID: UUID(), languageEpoch: 0, engineEpoch: 0, cloudConfigRevision: 0)
        identity = token
        rows = []; pending = []; active = nil; submitted = [:]
        maximumPending = 0; translations = 0; staleResults = 0; lastSubmission = 0
        return token
    }

    func receive(_ result: G0Transcript) -> Bool {
        guard identity == result.identity else { return true }
        if let index = rows.firstIndex(where: { $0.id == result.key }) {
            if rows[index].source != result.text {
                rows[index].revision += 1
                rows[index].source = result.text
                rows[index].translation = ""
            }
        } else {
            rows.append(G0Caption(id: result.key, revision: 0, source: result.text))
            rows.sort { $0.id < $1.id }
            if rows.count > RuntimePolicy.retainedSegmentLimit { rows.removeFirst(rows.count - RuntimePolicy.retainedSegmentLimit) }
        }
        let retained = Set(rows.map(\.id))
        submitted = submitted.filter { retained.contains($0.key) }
        pending.removeAll { !retained.contains($0.segment) }
        guard let row = rows.first(where: { $0.id == result.key }) else { return true }
        let now = clock.now()
        let interval = UInt64(RuntimePolicy.preferredSegmentDuration.components.seconds) * 1_000_000_000
        guard submitted[row.id] != row.revision,
              result.isFinal || now.uptimeNanoseconds - lastSubmission >= interval else { return true }
        pending.removeAll { $0.segment == row.id }
        guard pending.count < RuntimePolicy.pendingTranslationLimit else { return false }
        let lifetime = UInt64(RuntimePolicy.jobLifetime.components.seconds) * 1_000_000_000
        pending.append(G0TranslationJob(id: UUID(), identity: result.identity, segment: row.id, revision: row.revision,
                                        text: row.source, deadline: MonotonicInstant(uptimeNanoseconds: now.uptimeNanoseconds + lifetime)))
        submitted[row.id] = row.revision
        lastSubmission = now.uptimeNanoseconds
        maximumPending = max(maximumPending, pending.count)
        return true
    }

    func next(_ token: SessionIdentity) -> G0TranslationJob? {
        guard token == identity, active == nil else { return nil }
        while !pending.isEmpty {
            let job = pending.removeFirst()
            guard matches(job) else { continue }
            active = job
            return job
        }
        return nil
    }

    private func matches(_ job: G0TranslationJob) -> Bool {
        identity == job.identity && rows.contains { $0.id == job.segment && $0.revision == job.revision }
    }
    func isCurrent(_ job: G0TranslationJob) -> Bool { active?.id == job.id && matches(job) }
    func expired(_ job: G0TranslationJob) -> Bool {
        isCurrent(job) && clock.now().uptimeNanoseconds >= job.deadline.uptimeNanoseconds
    }
    enum Application: Sendable { case applied, stale, expired }
    func apply(_ text: String, to job: G0TranslationJob) -> Application {
        defer { if active?.id == job.id { active = nil } }
        guard isCurrent(job) else { staleResults += 1; return .stale }
        guard clock.now().uptimeNanoseconds < job.deadline.uptimeNanoseconds else { return .expired }
        guard let index = rows.firstIndex(where: { $0.id == job.segment }) else { return .stale }
        rows[index].translation = text
        translations += 1
        return .applied
    }
    func failureCode(for job: G0TranslationJob) -> FailureCode? {
        guard isCurrent(job) else { return nil }
        return clock.now().uptimeNanoseconds >= job.deadline.uptimeNanoseconds ? .deadlineExceeded : .localTranslationFailed
    }
    func finish(_ job: G0TranslationJob) { if active?.id == job.id { active = nil } }
    func snapshot() -> (rows: [G0Caption], pending: Int, maximumPending: Int, translations: Int, stale: Int) {
        (rows, pending.count, maximumPending, translations, staleResults)
    }
    func invalidate() {
        identity = nil
        rows = []; pending = []; active = nil; submitted = [:]
    }
}
#endif
