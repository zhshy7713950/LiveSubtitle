import Foundation
#if FEATURES_HOST_CHECK
#else
import Testing
@testable import LiveSubtitle
#endif

@MainActor
func testModeChangeDuringPreparationCannotStartOldAIConfig() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id],
        assetStatus: LanguageAssetStatus(recognition: .missing, localTranslation: .missing)
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    setup.start()
    try await featureMainActorEventually("AI preparation did not begin") {
        rig.assets.prepareCount == 1
    }

    await setup.selectMode(.local)
    await rig.capability.setReport(CapabilityReport(
        sourceLanguages: [LanguageIdentifier(rawValue: "en")],
        targetLanguages: [LanguageIdentifier(rawValue: "zh-Hans")],
        assets: LanguageAssetStatus(recognition: .ready, localTranslation: .ready),
        blockers: []
    ))
    rig.assets.setStatus(LanguageAssetStatus(recognition: .ready, localTranslation: .ready))
    setup.start()
    rig.assets.emit(.finished)
    rig.assets.finish()

    try await featureEventually("latest local intent did not prepare a session") {
        await rig.session.preparedConfigs.count == 1
    }
    let config = try await featureUnwrapConfig(rig.session)
    try featureRequire(config.requestedMode == .local, "cancelled AI preparation overrode the latest local mode")
}

@MainActor
func testCancelledPreparationCanRetry() async throws {
    let rig = FeatureTestRig(
        assetStatus: LanguageAssetStatus(recognition: .missing, localTranslation: .missing)
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    setup.start()
    try await featureMainActorEventually("first preparation did not begin") {
        rig.assets.prepareCount == 1
    }
    setup.cancelPreparation()
    try await featureMainActorEventually("first cancellation did not clean up") {
        !setup.isPreparing
    }

    setup.start()
    try await featureMainActorEventually("same configuration could not retry after cancellation") {
        rig.assets.prepareCount == 2
    }
    setup.cancelPreparation()
    try await featureMainActorEventually("second cancellation did not clean up") {
        !setup.isPreparing
    }
    try featureRequire(!rig.log.values.contains("start"), "cancelled retry started capture")
}

@MainActor
func testRunningModeChangeUsesLatestIntent() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    await rig.session.emit(makeFeatureStatus(phase: .running))
    try await featureMainActorEventually("running state was not observed") {
        setup.sessionStatus?.phase == .running
    }

    await rig.credentials.suspendNextReadKey()
    let aiSelection = Task { await setup.selectMode(.ai) }
    try await featureEventually("AI validation did not read the Key") {
        await rig.credentials.readKeyCount == 1
    }
    let localSelection = Task { await setup.selectMode(.local) }
    await Task.yield()
    await rig.credentials.releaseReadKey()
    await aiSelection.value
    await localSelection.value

    try featureRequire(!rig.log.values.contains("selectMode.ai"), "stale AI validation re-enabled AI after local selection")
    try featureRequire(rig.log.values.last == "selectMode.local", "latest local mode was not the final session operation")
    let stored = await rig.preferences.currentPreferences()
    try featureRequire(stored?.requestedMode == .local, "stale AI validation overwrote stored local mode")
}

@MainActor
func testDisplayUpdatesApplyOnlyLatestIntentAfterAwait() async throws {
    let rig = FeatureTestRig()
    let setup = rig.makeSetupViewModel()
    await setup.load()
    await rig.preferences.suspendNextSave()

    let first = Task { await setup.updateDisplay(count: 1, style: .translationOnly) }
    try await featureEventually("first display save did not begin") {
        rig.log.values.contains("savePreferences")
    }
    let second = Task { await setup.updateDisplay(count: 10, style: .bilingual) }
    for _ in 0..<5 { await Task.yield() }
    await rig.preferences.releaseSave()
    await first.value
    await second.value

    let displays = await rig.session.displays
    try featureRequire(displays.map(\.displayCount) == [10], "stale display intent reached Session after a newer choice")
    let stored = await rig.preferences.currentPreferences()
    try featureRequire(stored?.display.displayCount == 10, "stale display intent was persisted last")
    try featureRequire(stored?.display.displayStyle == .bilingual, "latest display style was not persisted")
}

@MainActor
func testSetupAndCloudDoNotOverwriteProfileSelection() async throws {
    let first = makeFeatureProfile(name: "First")
    let second = makeFeatureProfile(name: "Second")
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: first.id),
        profiles: [first, second],
        keyedProfileIDs: [first.id, second.id]
    )
    let setup = rig.makeSetupViewModel()
    let cloud = rig.makeCloudViewModel()
    await setup.load()
    await cloud.load()
    await cloud.selectProfile(id: second.id)
    await setup.updateDisplay(count: 4, style: .bilingual)

    let stored = await rig.preferences.currentPreferences()
    try featureRequire(stored?.selectedCloudProfileID == second.id, "display update restored the stale profile selection")
    setup.start()
    try await featureEventually("AI session did not start after profile refresh") {
        await rig.session.preparedConfigs.count == 1
    }
    let config = try await featureUnwrapConfig(rig.session)
    try featureRequire(config.cloudProfileID == second.id, "AI start validated a stale cached profile")
}

@MainActor
func testNilProfileSelectionIsNotImplicitlyPersisted() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(profileID: nil),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    await setup.updateDisplay(count: 2, style: .translationOnly)
    let stored = await rig.preferences.currentPreferences()
    try featureRequire(stored?.selectedCloudProfileID == nil, "display-only save implicitly selected a profile")
}

@MainActor
func testCloudMutationsAreSerialized() async throws {
    let first = makeFeatureProfile(name: "First")
    let second = makeFeatureProfile(name: "Second")
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: first.id),
        profiles: [first, second],
        keyedProfileIDs: [first.id, second.id]
    )
    let cloud = rig.makeCloudViewModel()
    await cloud.load()
    await rig.session.suspendNextWillChange()
    cloud.keyInput = "test-key-new"
    let replacement = Task { await cloud.replaceKey() }
    try await featureEventually("first mutation did not reach barrier") {
        rig.log.values.contains("willChange")
    }

    let selection = Task { await cloud.selectProfile(id: second.id) }
    for _ in 0..<5 { await Task.yield() }
    try featureRequire(!rig.log.values.contains("savePreferences"), "second mutation persisted while first was blocked")
    try featureRequire(rig.log.values.filter { $0 == "willChange" }.count == 1, "second mutation crossed the barrier concurrently")
    await rig.session.releaseWillChange()
    await replacement.value
    await selection.value
    try featureRequire(cloud.selectedProfileID == second.id, "serialized selection did not finish with latest profile")
}

@MainActor
func testCloudFailureOrderKeepsKeyAndRevisionConsistent() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let cloud = rig.makeCloudViewModel()
    await cloud.load()

    await rig.preferences.failNext("saveProfile")
    cloud.keyInput = "test-key-new"
    await cloud.replaceKey()
    var key = try await rig.credentials.readKey(profileID: profile.id)
    try featureRequire(key == "test-key", "Key changed even though its new revision could not be saved")
    try featureRequire(cloud.profiles.first?.revision == 1, "failed profile save changed revision unexpectedly")

    await rig.credentials.failNext("replaceKey")
    cloud.keyInput = "test-key-new"
    await cloud.replaceKey()
    key = try await rig.credentials.readKey(profileID: profile.id)
    try featureRequire(key == "test-key", "failed Key replacement changed the stored Key")
    try featureRequire(cloud.profiles.first?.revision == 2, "recoverable profile-first order did not preserve revision before Key failure")
    try featureRequire(cloud.hasStoredKey, "failure refresh misreported the existing Key")

    await rig.preferences.failNext("deleteProfile")
    await cloud.deleteProfile()
    key = try await rig.credentials.readKey(profileID: profile.id)
    try featureRequire(key == nil, "failed profile deletion left an orphaned credential strategy inconsistent")
    try featureRequire(cloud.profiles.contains(where: { $0.id == profile.id }), "failed profile deletion removed the profile")
    try featureRequire(!cloud.hasStoredKey, "failure refresh did not reflect actual deleted Key state")
}

@MainActor
func testConnectionRequiresSavedDraft() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let cloud = rig.makeCloudViewModel()
    await cloud.load()
    cloud.endpoint = "https://provider.example/v2/chat/completions"
    await cloud.testConnection()
    try featureRequire(await rig.connectionTester.testedProfiles.isEmpty, "unsaved draft tested the old saved endpoint")
}

@MainActor
func testConnectionResultCannotOverwriteNewProfile() async throws {
    let first = makeFeatureProfile(name: "First")
    let second = makeFeatureProfile(name: "Second")
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: first.id),
        profiles: [first, second],
        keyedProfileIDs: [first.id, second.id]
    )
    let cloud = rig.makeCloudViewModel()
    await cloud.load()
    await rig.connectionTester.suspendNextTest()
    let test = Task { await cloud.testConnection() }
    try await featureEventually("connection test did not begin") {
        await rig.connectionTester.testedProfiles.count == 1
    }
    await cloud.selectProfile(id: second.id)
    await rig.connectionTester.releaseTest(.success(()))
    await test.value

    try featureRequire(cloud.message?.contains("连接测试成功") != true, "old profile result overwrote the new selection")
    try featureRequire(rig.log.values.contains("cancelConnectionTest"), "profile mutation did not cancel the old connection test")
}

@MainActor
func testConnectionResultCannotOverwriteNewRevision() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let cloud = rig.makeCloudViewModel()
    await cloud.load()
    await rig.connectionTester.suspendNextTest()
    let test = Task { await cloud.testConnection() }
    try await featureEventually("connection test did not begin") {
        await rig.connectionTester.testedProfiles.count == 1
    }
    await cloud.saveProfile()
    await rig.connectionTester.releaseTest(.success(()))
    await test.value

    try featureRequire(cloud.message?.contains("连接测试成功") != true, "old revision result overwrote the saved profile state")
}

#if !FEATURES_HOST_CHECK
struct FeatureConcurrencyRegressionTests {
    @Test @MainActor func connectionRequiresSavedDraft() async throws {
        try await testConnectionRequiresSavedDraft()
    }
    @Test @MainActor func connectionResultCannotOverwriteNewProfile() async throws {
        try await testConnectionResultCannotOverwriteNewProfile()
    }
    @Test @MainActor func connectionResultCannotOverwriteNewRevision() async throws {
        try await testConnectionResultCannotOverwriteNewRevision()
    }
    @Test @MainActor func cloudMutationsAreSerialized() async throws {
        try await testCloudMutationsAreSerialized()
    }
    @Test @MainActor func cloudFailureOrderKeepsKeyAndRevisionConsistent() async throws {
        try await testCloudFailureOrderKeepsKeyAndRevisionConsistent()
    }
    @Test @MainActor func displayUpdatesApplyOnlyLatestIntentAfterAwait() async throws {
        try await testDisplayUpdatesApplyOnlyLatestIntentAfterAwait()
    }
    @Test @MainActor func setupAndCloudDoNotOverwriteProfileSelection() async throws {
        try await testSetupAndCloudDoNotOverwriteProfileSelection()
    }
    @Test @MainActor func nilProfileSelectionIsNotImplicitlyPersisted() async throws {
        try await testNilProfileSelectionIsNotImplicitlyPersisted()
    }
    @Test @MainActor func cancelledPreparationCanRetry() async throws {
        try await testCancelledPreparationCanRetry()
    }
    @Test @MainActor func modeChangeDuringPreparationCannotStartOldAIConfig() async throws {
        try await testModeChangeDuringPreparationCannotStartOldAIConfig()
    }
    @Test @MainActor func runningModeChangeUsesLatestIntent() async throws {
        try await testRunningModeChangeUsesLatestIntent()
    }
}
#endif
