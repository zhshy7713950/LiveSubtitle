#if DEBUG
import Foundation
import Synchronization
#if !G0_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private struct G0CheckFailure: Error { let name: String }
private func require(_ condition: Bool, _ name: String) throws {
    if !condition { throw G0CheckFailure(name: name) }
}

private final class G0TestClock: MonotonicClock, Sendable {
    private let ticks = Mutex<UInt64>(10_000_000_000)
    func now() -> MonotonicInstant { MonotonicInstant(uptimeNanoseconds: ticks.withLock { $0 }) }
    func advance(seconds: UInt64) { ticks.withLock { $0 += seconds * 1_000_000_000 } }
    func sleep(until deadline: MonotonicInstant) async throws {
        while now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            try Task.checkCancellation()
            await Task.yield()
        }
        try Task.checkCancellation()
    }
}

private func fixturePacket(_ identity: SessionIdentity, seconds: Double) -> G0AudioPacket {
    let frames = Int(seconds * 16_000)
    let chunk = AudioChunk(sequence: 1, capturePTS: AudioTimestamp(value: 0, timescale: 16_000), frameCount: frames,
                           sampleRate: 16_000, channels: 1,
                           format: PCMFormat(sampleFormat: .float32, isInterleaved: false, isBigEndian: false, bytesPerFrame: 4),
                           ownedPCM: [Data(count: frames * 4)], discontinuity: false)
    return G0AudioPacket(identity: identity, chunk: chunk)
}

private func audioBudgetIncludesInFlight() async throws {
    let state = G0RunState()
    let token = await state.begin()
    let inbox = G0AudioInbox()
    inbox.activate(token)
    inbox.push(fixturePacket(token, seconds: 1))
    _ = inbox.pop(token)
    try require(inbox.snapshot().queuedSeconds == 1, "popped PCM remains charged until consumed")
    inbox.push(fixturePacket(token, seconds: 1))
    try require(inbox.snapshot().maximumQueuedSeconds == 2, "exact budget accepted")
    inbox.push(fixturePacket(token, seconds: 0.1))
    try require(inbox.snapshot().overflowCount == 1, "overflow reported")
    try require(inbox.failure(token) == .speechFailed, "overflow is explicit G0 failure")
}

private func consumedAudioReturnsBudget() async throws {
    let state = G0RunState()
    let token = await state.begin()
    let inbox = G0AudioInbox()
    inbox.activate(token)
    inbox.push(fixturePacket(token, seconds: 1))
    _ = inbox.pop(token)
    inbox.consumed(token, seconds: 1)
    inbox.push(fixturePacket(token, seconds: 2))
    try require(inbox.snapshot().queuedSeconds == 2 && inbox.snapshot().overflowCount == 0, "consumption returns budget")
}

private func oldCaptureIsRejected() async throws {
    let state = G0RunState()
    let old = await state.begin()
    let current = await state.begin()
    let inbox = G0AudioInbox()
    inbox.activate(current)
    inbox.push(fixturePacket(old, seconds: 1))
    inbox.fail(old, code: .captureFailed)
    inbox.consumed(old, seconds: 1)
    try require(inbox.snapshot().buffers == 0 && inbox.failure(current) == nil, "old capture cannot mutate new run")
}

private func oldTranslationIsRejectedAfterStop() async throws {
    let state = G0RunState()
    let token = await state.begin()
    _ = await state.receive(G0Transcript(identity: token, key: 1, text: "fixture", isFinal: true))
    guard let job = await state.next(token) else { throw G0CheckFailure(name: "job missing") }
    await state.invalidate()
    let application = await state.apply("fixture translation", to: job)
    let snapshot = await state.snapshot()
    try require(application == .stale && snapshot.rows.isEmpty, "stop invalidates late translation")
}

private func revisedSourceRejectsOldTranslation() async throws {
    let state = G0RunState()
    let token = await state.begin()
    _ = await state.receive(G0Transcript(identity: token, key: 1, text: "first", isFinal: true))
    guard let job = await state.next(token) else { throw G0CheckFailure(name: "job missing") }
    _ = await state.receive(G0Transcript(identity: token, key: 1, text: "revised", isFinal: true))
    let application = await state.apply("old translation", to: job)
    let snapshot = await state.snapshot()
    try require(application == .stale && snapshot.translations == 0, "revision check rejects stale output")
}

private func deadlineBoundaryIsExplicit() async throws {
    let clock = G0TestClock()
    let state = G0RunState(clock: clock)
    let token = await state.begin()
    _ = await state.receive(G0Transcript(identity: token, key: 1, text: "fixture", isFinal: true))
    guard let job = await state.next(token) else { throw G0CheckFailure(name: "job missing") }
    clock.advance(seconds: 6)
    let failure = await state.failureCode(for: job)
    try require(failure == .deadlineExceeded, "deadline-triggered cancellation retains timeout classification")
    let application = await state.apply("late", to: job)
    let snapshot = await state.snapshot()
    try require(application == .expired && snapshot.translations == 0, "deadline is explicit, never silently stale")
}

private func pendingQueueIsBounded() async throws {
    let state = G0RunState()
    let token = await state.begin()
    for key in 0..<RuntimePolicy.pendingTranslationLimit {
        let accepted = await state.receive(G0Transcript(identity: token, key: Int64(key), text: "fixture", isFinal: true))
        try require(accepted, "queue slot accepted")
    }
    let accepted = await state.receive(G0Transcript(identity: token, key: 99, text: "fixture", isFinal: true))
    let snapshot = await state.snapshot()
    try require(!accepted && snapshot.maximumPending == RuntimePolicy.pendingTranslationLimit, "pending cap fails explicitly")
}

private func retainedCaptionsAreBounded() async throws {
    let state = G0RunState()
    let token = await state.begin()
    for key in 0..<20 {
        _ = await state.receive(G0Transcript(identity: token, key: Int64(key), text: "fixture", isFinal: true))
        guard let job = await state.next(token) else { throw G0CheckFailure(name: "job missing") }
        _ = await state.apply("translated", to: job)
    }
    let snapshot = await state.snapshot()
    try require(snapshot.rows.count == RuntimePolicy.retainedSegmentLimit && snapshot.rows.first?.id == 10, "old captions evicted")
}

#if G0_HOST_CHECK
@main
private struct G0HostChecks {
    static func main() async throws {
        let checks: [(String, () async throws -> Void)] = [
            ("audioBudgetIncludesInFlight", audioBudgetIncludesInFlight),
            ("consumedAudioReturnsBudget", consumedAudioReturnsBudget),
            ("oldCaptureIsRejected", oldCaptureIsRejected),
            ("oldTranslationIsRejectedAfterStop", oldTranslationIsRejectedAfterStop),
            ("revisedSourceRejectsOldTranslation", revisedSourceRejectsOldTranslation),
            ("deadlineBoundaryIsExplicit", deadlineBoundaryIsExplicit),
            ("pendingQueueIsBounded", pendingQueueIsBounded),
            ("retainedCaptionsAreBounded", retainedCaptionsAreBounded)
        ]
        for (name, check) in checks { try await check(); print("PASS \(name)") }
        print("8 G0 host logic checks passed; no SDK/device behavior tested.")
    }
}
#else
struct G0StateTests {
    @Test func audioBudget() async throws { try await audioBudgetIncludesInFlight() }
    @Test func returnedBudget() async throws { try await consumedAudioReturnsBudget() }
    @Test func oldCapture() async throws { try await oldCaptureIsRejected() }
    @Test func stoppedTranslation() async throws { try await oldTranslationIsRejectedAfterStop() }
    @Test func sourceRevision() async throws { try await revisedSourceRejectsOldTranslation() }
    @Test func deadline() async throws { try await deadlineBoundaryIsExplicit() }
    @Test func pendingLimit() async throws { try await pendingQueueIsBounded() }
    @Test func retainedLimit() async throws { try await retainedCaptionsAreBounded() }
}
#endif
#endif
