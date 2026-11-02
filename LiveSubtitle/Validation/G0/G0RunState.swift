#if DEBUG
import Foundation

struct G0Transcript: Sendable {
    let identity: SessionIdentity
    let key: Int64
    let text: String
    let isFinal: Bool
    let end: Int64?

    init(identity: SessionIdentity, key: Int64, text: String, isFinal: Bool, end: Int64? = nil) {
        self.identity = identity; self.key = key; self.text = text; self.isFinal = isFinal; self.end = end
    }
}

struct G0Caption: Sendable, Identifiable {
    let id: Int64
    var revision: UInt64
    var source: String
    var translation = ""
    var audioStart: Int64 = 0
    var audioEnd: Int64?
    var isFinal = false

    var displayText: String { translation.isEmpty ? source : translation + "\n" + source }
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
    private var lastTranslationSeconds = 0.0
    private var maximumTranslationSeconds = 0.0
    private var lastQueueSeconds = 0.0
    private let clock: any MonotonicClock
    init(clock: any MonotonicClock = G0Clock()) { self.clock = clock }

    func begin() -> SessionIdentity {
        let token = SessionIdentity(sessionID: UUID(), languageEpoch: 0, engineEpoch: 0, cloudConfigRevision: 0)
        identity = token
        rows = []; pending = []; active = nil; submitted = [:]
        maximumPending = 0; translations = 0; staleResults = 0; lastSubmission = 0
        lastTranslationSeconds = 0; maximumTranslationSeconds = 0; lastQueueSeconds = 0
        return token
    }

    func receive(_ result: G0Transcript) -> Bool {
        guard identity == result.identity else { return true }
        let overlapping = rows.indices.filter { index in
            let row = rows[index]
            // G0 range reconciliation: a volatile result can move its start time.
            // Require substantial audio overlap; equal words at disjoint times
            // remain separate. Formal segmentation belongs to TASK-06.
            guard let end = result.end, let previousEnd = row.audioEnd,
                  end > result.key, previousEnd > row.audioStart else { return false }
            let overlap = min(end, previousEnd) - max(result.key, row.audioStart)
            let shorter = min(end - result.key, previousEnd - row.audioStart)
            guard Double(overlap) >= Double(shorter) * 0.8 else { return false }
            return !row.isFinal || row.source.hasPrefix(result.text) || result.text.contains(row.source)
        }
        let index = rows.firstIndex(where: { $0.id == result.key }) ?? overlapping.first
        let segment: Int64
        if let index {
            segment = rows[index].id
            if rows[index].source != result.text {
                rows[index].revision += 1
                rows[index].source = result.text
                rows[index].translation = ""
            }
            rows[index].audioStart = result.key
            rows[index].audioEnd = result.end
            rows[index].isFinal = rows[index].isFinal || result.isFinal
            // A final result may combine several provisional ranges. Remove
            // every covered superseded row, not just the chosen canonical row.
            let superseded = Set(overlapping.filter { $0 != index }.map { rows[$0].id })
            rows.removeAll { superseded.contains($0.id) }
        } else {
            segment = result.key
            rows.append(G0Caption(id: segment, revision: 0, source: result.text,
                                  audioStart: result.key, audioEnd: result.end, isFinal: result.isFinal))
            rows.sort { $0.id < $1.id }
            if rows.count > RuntimePolicy.retainedSegmentLimit { rows.removeFirst(rows.count - RuntimePolicy.retainedSegmentLimit) }
        }
        let retained = Set(rows.map(\.id))
        submitted = submitted.filter { retained.contains($0.key) }
        pending.removeAll { !retained.contains($0.segment) }
        guard let row = rows.first(where: { $0.id == segment }) else { return true }
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
    func apply(_ text: String, to job: G0TranslationJob, startedAt: MonotonicInstant? = nil) -> Application {
        defer { if active?.id == job.id { active = nil } }
        guard isCurrent(job) else { staleResults += 1; return .stale }
        guard clock.now().uptimeNanoseconds < job.deadline.uptimeNanoseconds else { return .expired }
        guard let index = rows.firstIndex(where: { $0.id == job.segment }) else { return .stale }
        rows[index].translation = text
        translations += 1
        if let startedAt {
            let now = clock.now().uptimeNanoseconds
            lastTranslationSeconds = Double(now - min(now, startedAt.uptimeNanoseconds)) / 1_000_000_000
            maximumTranslationSeconds = max(maximumTranslationSeconds, lastTranslationSeconds)
            let lifetime = UInt64(RuntimePolicy.jobLifetime.components.seconds) * 1_000_000_000
            let submittedAt = job.deadline.uptimeNanoseconds - lifetime
            lastQueueSeconds = Double(startedAt.uptimeNanoseconds - min(startedAt.uptimeNanoseconds, submittedAt)) / 1_000_000_000
        }
        return .applied
    }
    func failureCode(for job: G0TranslationJob) -> FailureCode? {
        guard isCurrent(job) else { return nil }
        return clock.now().uptimeNanoseconds >= job.deadline.uptimeNanoseconds ? .deadlineExceeded : .localTranslationFailed
    }
    func finish(_ job: G0TranslationJob) { if active?.id == job.id { active = nil } }
    func snapshot() -> (rows: [G0Caption], pending: Int, maximumPending: Int, translations: Int, stale: Int,
                        lastTranslationSeconds: Double, maximumTranslationSeconds: Double, lastQueueSeconds: Double) {
        (rows, pending.count, maximumPending, translations, staleResults,
         lastTranslationSeconds, maximumTranslationSeconds, lastQueueSeconds)
    }
    func invalidate() {
        identity = nil
        rows = []; pending = []; active = nil; submitted = [:]
    }
}
#endif
