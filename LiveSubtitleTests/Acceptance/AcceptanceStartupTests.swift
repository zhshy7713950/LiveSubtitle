import Foundation
import Testing
@testable import LiveSubtitle

@MainActor
private final class AcceptanceFailingPiP: PiPControlling {
    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        throw FailureCode.pipFailed
    }
    func stop(sessionID: UUID) async {}
}

@MainActor
struct AcceptanceStartupTests {
    // Spec §13.1 requires a failed state with a readable reason when startup cannot continue.
    // Reproduces the real device's startup error at the PiP boundary, without a system picker.
    @Test func testA03StartupFailureRemainsVisibleAfterCleanup() async {
        let rig = AcceptanceRig(mode: .local, pip: AcceptanceFailingPiP())
        await rig.session.prepare(config: rig.config)
        await rig.session.start()

        let status = await rig.session.currentStatus
        #expect(status.phase == .failed,
                "A03: cleanup must preserve a failed startup state")
        #expect(status.failure == .pipFailed,
                "A03: cleanup must preserve the safe PiP failure reason")
        #expect(status.identity == nil)
        #expect(rig.source.stopCount == 1)
        #expect(rig.renderer.latest == nil)
        await rig.cleanup()
    }
}
