import Foundation
import Testing
@testable import LiveSubtitle

@MainActor
struct LifecyclePiPTests {
    @Test func testSlowPiPConsumerReceivesTerminalEvent() async throws {
        let base = IntegrationPiPBase()
        let pip = LifecyclePiPController(base: base)
        let id = UUID()
        let stream = try await pip.start(sessionID: id)
        for _ in 0..<32 { base.emit(.started(sessionID: id)) }
        base.emit(.closed(sessionID: id))
        try await integrationEventually("PiP terminal did not release base") { base.stops.count == 1 }
        var terminal = false
        for await event in stream {
            switch event {
            case .closed, .failed: terminal = true
            default: break
            }
        }
        #expect(terminal, "slow consumer lost the only stop/failure signal")
        await pip.stop(sessionID: id)
    }

    @Test func testUnexpectedPiPEOFIsFailure() async throws {
        let base = IntegrationPiPBase()
        let pip = LifecyclePiPController(base: base)
        let id = UUID()
        let stream = try await pip.start(sessionID: id)
        base.finish()
        // The stream must finish with a failure even if no final system callback arrives.
        let reader = Task { () -> Bool in
            for await event in stream { if case .failed = event { return true } }
            return false
        }
        // Bound the test using an observed base release, without waiting on an open stream forever.
        do { try await integrationEventually("unexpected PiP EOF was ignored") { !base.stops.isEmpty } }
        catch { reader.cancel(); await pip.stop(sessionID: id); throw error }
        #expect(await reader.value)
        await pip.stop(sessionID: id)
    }

    @Test func testRestoredPiPResumesSameSession() async throws {
        let base = IntegrationPiPBase()
        let pip = LifecyclePiPController(base: base)
        let id = UUID()
        let stream = try await pip.start(sessionID: id)
        var restored = false
        var startedAgain = false
        let reader = Task {
            for await event in stream {
                if case .restoredInterface = event { restored = true }
                if case .started = event { startedAgain = true }
            }
        }
        base.emit(.restoringInterface(sessionID: id))
        base.emit(.restoredInterface(sessionID: id))
        try await integrationEventually("restoration was not forwarded") { restored }
        await pip.resumeAfterRestoration(sessionID: id)
        #expect(base.starts == [id, id])
        base.emit(.closed(sessionID: id), stream: 0)
        base.emit(.started(sessionID: id), stream: 1)
        try await integrationEventually("replacement PiP stream was not consumed") { startedAgain }
        await pip.resumeAfterRestoration(sessionID: UUID())
        await pip.resumeAfterRestoration(sessionID: id)
        #expect(base.starts.count == 2)
        await pip.stop(sessionID: id)
        await reader.value
    }
}
