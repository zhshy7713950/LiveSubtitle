import Foundation

struct TranslationJobQueue {
    private let limit: Int
    private var storage: [TranslationJob] = []

    init(limit: Int = RuntimePolicy.pendingTranslationLimit) {
        self.limit = limit
    }

    var count: Int { storage.count }
    var all: [TranslationJob] { storage }

    mutating func enqueue(_ job: TranslationJob) -> [TranslationJob] {
        var removed = storage.filter { $0.segmentID == job.segmentID }
        storage.removeAll { $0.segmentID == job.segmentID }
        storage.append(job)
        while storage.count > limit {
            removed.append(storage.removeFirst())
        }
        return removed
    }

    mutating func popFirst(where predicate: (TranslationJob) -> Bool) -> TranslationJob? {
        guard let index = storage.firstIndex(where: predicate) else { return nil }
        return storage.remove(at: index)
    }

    mutating func remove(jobID: UUID) -> TranslationJob? {
        guard let index = storage.firstIndex(where: { $0.jobID == jobID }) else { return nil }
        return storage.remove(at: index)
    }

    mutating func remove(segmentID: UUID) -> [TranslationJob] {
        let removed = storage.filter { $0.segmentID == segmentID }
        storage.removeAll { $0.segmentID == segmentID }
        return removed
    }

    mutating func removeAll() -> [TranslationJob] {
        let removed = storage
        storage.removeAll()
        return removed
    }
}
