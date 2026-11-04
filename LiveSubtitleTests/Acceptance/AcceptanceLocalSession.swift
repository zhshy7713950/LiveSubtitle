import Foundation
@testable import LiveSubtitle

/// Counts calls at the SDK seam without retaining source or translated text.
actor AcceptanceLocalCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

actor AcceptanceLocalSession: LocalTranslationSession {
    private let calls: AcceptanceLocalCalls
    init(calls: AcceptanceLocalCalls) { self.calls = calls }
    func isReady() async throws -> Bool { true }
    func translate(_ text: String) async throws -> String {
        await calls.record()
        return "本地固定译文"
    }
    func cancel() async {}
}
