import Foundation
import Testing
import UIKit
@testable import LiveSubtitle

@MainActor
struct CompositionRaceTests {
    @Test func testNotificationBeforeStatusObservationStillStopsCapture() async throws {
        let rig = IntegrationRig()
        let diagnostics = IntegrationBlockedDiagnostics()
        let bridge = LifecycleBridge(session: rig.session, diagnostics: diagnostics, captureScope: rig.captureScope)
        bridge.startObserving()
        try await integrationEventually("status observation did not suspend") { await diagnostics.isBlocked }
        try await rig.start()
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        do {
            try await integrationEventually("lock notification was lost before status cache updated") {
                await rig.session.currentStatus.phase == .idle
            }
        } catch {
            await diagnostics.release()
            bridge.stopObserving()
            await rig.cleanup()
            throw error
        }
        #expect(rig.source.stopCount == 1)
        await diagnostics.release()
        bridge.stopObserving()
        await rig.cleanup()
    }
}

@MainActor
struct SetupReplacementTests {
    @Test func testReplacingSetupCancelsAndJoinsOldPreparation() async throws {
        let rig = FeatureTestRig(assetStatus: .init(recognition: .missing, localTranslation: .missing))
        let setup = rig.makeSetupViewModel()
        await setup.load()
        setup.start()
        try await integrationEventually("old preparation did not start") { rig.assets.prepareCount == 1 }
        await AppComposition.settleSetupBeforeReplacement(setup)
        #expect(!setup.isPreparing)
        rig.assets.emit(.finished)
        rig.assets.finish()
        #expect(!rig.log.values.contains("start"))
        #expect(rig.assets.cancelCount > 0)
    }

    @Test func testReplacingRunningSetupDoesNotStopSession() async throws {
        let rig = FeatureTestRig()
        let setup = rig.makeSetupViewModel()
        await setup.load()
        await rig.session.emit(makeFeatureStatus(phase: .running))
        try await integrationEventually("running status missing") { setup.sessionStatus?.phase == .running }
        await AppComposition.settleSetupBeforeReplacement(setup)
        #expect(await rig.session.stopReasons.isEmpty)
    }
}
