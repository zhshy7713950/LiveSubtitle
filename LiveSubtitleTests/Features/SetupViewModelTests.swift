import Foundation
#if FEATURES_HOST_CHECK
#else
import Testing
@testable import LiveSubtitle
#endif

@MainActor
func featureMainActorEventually(
    _ message: String,
    condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<500 {
        if condition() { return }
        await Task.yield()
    }
    throw FeatureTestFailure(message: message)
}

@MainActor
func testInitialSetupAndResources() async throws {
    let profile = makeFeatureProfile()
    let defaults = FeatureTestRig(profiles: [profile], keyedProfileIDs: [profile.id])
    let setup = defaults.makeSetupViewModel()
    await setup.load()
    try featureRequire(setup.requestedMode == .local, "initial mode was not local")
    try featureRequire(setup.sourceLanguage.rawValue == "en", "English suggestion was not visible")
    try featureRequire(setup.targetLanguage.rawValue == "zh-Hans", "zh-Hans suggestion was not visible")
    try featureRequire(setup.availableSourceLanguages.map(\.rawValue) == ["en", "en-US"], "source choices were not editable")
    try featureRequire(setup.availableTargetLanguages.map(\.rawValue) == ["zh-Hans", "zh-Hant"], "target choices were not editable")

    await setup.selectTargetLanguage(LanguageIdentifier(rawValue: "en"))
    setup.start()
    for _ in 0..<5 { await Task.yield() }
    try featureRequire(await defaults.session.preparedConfigs.isEmpty, "same-language selection started preparation")

    await setup.selectTargetLanguage(LanguageIdentifier(rawValue: "zh-Hans"))
    await defaults.capability.setReport(CapabilityReport(
        sourceLanguages: [LanguageIdentifier(rawValue: "en")],
        targetLanguages: [LanguageIdentifier(rawValue: "zh-Hans")],
        assets: LanguageAssetStatus(recognition: .unsupported, localTranslation: .ready),
        blockers: [.unsupportedLanguage]
    ))
    setup.start()
    for _ in 0..<5 { await Task.yield() }
    try featureRequire(defaults.assets.prepareCount == 0, "unsupported language attempted asset preparation")

    let aiProfile = makeFeatureProfile()
    let aiRig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: aiProfile.id),
        profiles: [aiProfile],
        keyedProfileIDs: [aiProfile.id],
        assetStatus: LanguageAssetStatus(recognition: .missing, localTranslation: .missing)
    )
    let aiSetup = aiRig.makeSetupViewModel()
    await aiSetup.load()
    aiSetup.start()
    try await featureMainActorEventually("AI did not prepare local fallback assets") {
        aiRig.assets.prepareCount == 1
    }
    try featureRequire(!aiSetup.statusText.contains("%"), "preparation invented percentage progress")

    await aiRig.capability.setReport(CapabilityReport(
        sourceLanguages: [LanguageIdentifier(rawValue: "en")],
        targetLanguages: [LanguageIdentifier(rawValue: "zh-Hans")],
        assets: LanguageAssetStatus(recognition: .ready, localTranslation: .ready),
        blockers: []
    ))
    aiRig.assets.setStatus(LanguageAssetStatus(recognition: .ready, localTranslation: .ready))
    aiRig.assets.emit(.finished)
    aiRig.assets.finish()
    try await featureEventually("prepared AI session did not start") {
        await aiRig.session.preparedConfigs.count == 1
    }
    let config = try await featureUnwrapConfig(aiRig.session)
    try featureRequire(config.requestedMode == .ai, "start lost the requested AI mode")
    try featureRequire(aiRig.log.values.contains("start"), "ready resources did not lead to capture start")

    let blockedRig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: aiProfile.id),
        profiles: [aiProfile],
        keyedProfileIDs: [aiProfile.id],
        assetStatus: LanguageAssetStatus(recognition: .ready, localTranslation: .missing)
    )
    let blockedSetup = blockedRig.makeSetupViewModel()
    await blockedSetup.load()
    blockedSetup.start()
    try await featureMainActorEventually("missing local translation did not enter preparation") {
        blockedRig.assets.prepareCount == 1
    }
    blockedRig.assets.emit(.finished)
    blockedRig.assets.finish()
    try await featureMainActorEventually("missing local fallback did not leave preparing state") {
        !blockedSetup.isPreparing
    }
    try featureRequire(await blockedRig.session.preparedConfigs.isEmpty, "AI started without local fallback resources")
}

func featureUnwrapConfig(_ session: FeatureSessionDouble) async throws -> SessionConfig {
    guard let config = await session.preparedConfigs.first else {
        throw FeatureTestFailure(message: "missing prepared config")
    }
    return config
}

@MainActor
func testCancelledPreparationNeverStartsCapture() async throws {
    let rig = FeatureTestRig(
        assetStatus: LanguageAssetStatus(recognition: .missing, localTranslation: .missing)
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    setup.start()
    try await featureMainActorEventually("preparation did not begin") {
        rig.assets.prepareCount == 1 && setup.isPreparing
    }
    try featureRequire(!setup.statusText.contains("%"), "indeterminate preparation displayed a percentage")
    setup.cancelPreparation()
    try await featureMainActorEventually("cancelled preparation remained busy") {
        !setup.isPreparing
    }
    for _ in 0..<10 { await Task.yield() }
    try featureRequire(await rig.session.preparedConfigs.isEmpty, "cancelled preparation prepared a session")
    try featureRequire(!rig.log.values.contains("start"), "cancelled preparation started capture")
    try featureRequire(rig.assets.cancelCount == 1, "cancellation did not reach the asset manager")
}

@MainActor
func testDisplayOnlyUpdate() async throws {
    let rig = FeatureTestRig()
    let setup = rig.makeSetupViewModel()
    await setup.load()
    try featureRequire(setup.display.displayCount == 3, "default display count was not three")
    try featureRequire(setup.display.displayStyle == .bilingual, "default style was not bilingual")

    await setup.updateDisplay(count: 1, style: .translationOnly)
    await setup.updateDisplay(count: 10, style: .bilingual)
    let displays = await rig.session.displays
    try featureRequire(displays.map(\.displayCount) == [1, 10], "display count did not cover the 1...10 bounds")
    try featureRequire(displays.first?.displayStyle == .translationOnly, "translation-only style was not applied")
    try featureRequire(!rig.log.values.contains("start"), "display update started a session")
    try featureRequire(!rig.log.values.contains("prepare"), "display update reprepared a session")
    try featureRequire(!rig.log.values.contains { $0.hasPrefix("selectMode") }, "display update changed translation mode")

    await setup.updateDisplay(count: 0, style: .translationOnly)
    await setup.updateDisplay(count: 11, style: .translationOnly)
    try featureRequire(await rig.session.displays.count == 2, "out-of-range display count reached the session")
}

@MainActor
func testLanguageChangeStopsAndRequiresRestart() async throws {
    let profile = makeFeatureProfile()
    let rig = FeatureTestRig(
        preferences: makeFeaturePreferences(mode: .ai, profileID: profile.id),
        profiles: [profile],
        keyedProfileIDs: [profile.id]
    )
    let setup = rig.makeSetupViewModel()
    await setup.load()
    await rig.session.emit(makeFeatureStatus(phase: .running, requestedMode: .ai, effectiveMode: .ai))
    try await featureMainActorEventually("running status was not observed") {
        setup.sessionStatus?.phase == .running
    }

    await setup.selectSourceLanguage(LanguageIdentifier(rawValue: "en-US"))
    try featureRequire(await rig.session.stopReasons.count == 1, "language change did not stop exactly once")
    try featureRequire(rig.assets.releaseCount == 1, "language change retained old reservations")
    try featureRequire(!rig.log.values.contains("start"), "language change restarted capture")

    let cloud = rig.makeCloudViewModel()
    await cloud.load()
    try featureRequire(await rig.session.stopReasons.count == 1, "viewing settings stopped the session")
    await cloud.testConnection()
    try featureRequire(await rig.connectionTester.testedProfiles.count == 1, "explicit connection test did not run")
    try featureRequire(!rig.log.values.contains("restoreAI"), "successful connectivity automatically restored AI")
    try featureRequire(!rig.log.values.contains("selectMode.ai"), "successful connectivity selected AI")

    await rig.session.emit(makeFeatureStatus(phase: .running, requestedMode: .ai, effectiveMode: .localFallback))
    await setup.restoreAI()
    try featureRequire(rig.log.values.contains("restoreAI"), "explicit recovery did not restore AI")
    await setup.stop()
    try featureRequire(await rig.session.stopReasons.count == 2, "user stop did not reach the session")
}

@MainActor
func testUserFacingStates() async throws {
    let rig = FeatureTestRig()
    let setup = rig.makeSetupViewModel()
    await setup.load()

    await rig.session.emit(makeFeatureStatus(phase: .running))
    try await featureMainActorEventually("waiting state was not presented") {
        setup.statusText.contains("等待声音")
    }
    await rig.session.emit(makeFeatureStatus(phase: .running, requestedMode: .ai, effectiveMode: .localFallback))
    try await featureMainActorEventually("fallback state was not understandable") {
        setup.statusText.contains("本地翻译")
    }
    await rig.session.emit(makeFeatureStatus(phase: .failed, failure: .localTranslationFailed))
    try await featureMainActorEventually("local failure was not understandable") {
        setup.statusText.contains("本地翻译失败")
    }
    let forbiddenTerms = ["SpeechTranscriber", "DictationTranscriber", "SDK", "queue"]
    for term in forbiddenTerms {
        try featureRequire(!setup.statusText.contains(term), "user state leaked internal term \(term)")
    }
}

#if FEATURES_HOST_CHECK
@main
private struct FeaturesHostChecks {
    static func main() async throws {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("testInitialSetupAndResources", testInitialSetupAndResources),
            ("testCancelledPreparationNeverStartsCapture", testCancelledPreparationNeverStartsCapture),
            ("testCloudSaveIsNotEnableAI", testCloudSaveIsNotEnableAI),
            ("testCloudMutationOrder", testCloudMutationOrder),
            ("testDisplayOnlyUpdate", testDisplayOnlyUpdate),
            ("testLanguageChangeStopsAndRequiresRestart", testLanguageChangeStopsAndRequiresRestart),
            ("testUserFacingStates", testUserFacingStates),
            ("testModeChangeDuringPreparationCannotStartOldAIConfig", testModeChangeDuringPreparationCannotStartOldAIConfig),
            ("testRunningModeChangeUsesLatestIntent", testRunningModeChangeUsesLatestIntent),
            ("testCancelledPreparationCanRetry", testCancelledPreparationCanRetry),
            ("testSetupAndCloudDoNotOverwriteProfileSelection", testSetupAndCloudDoNotOverwriteProfileSelection),
            ("testNilProfileSelectionIsNotImplicitlyPersisted", testNilProfileSelectionIsNotImplicitlyPersisted),
            ("testDisplayUpdatesApplyOnlyLatestIntentAfterAwait", testDisplayUpdatesApplyOnlyLatestIntentAfterAwait),
            ("testCloudMutationsAreSerialized", testCloudMutationsAreSerialized),
            ("testCloudFailureOrderKeepsKeyAndRevisionConsistent", testCloudFailureOrderKeepsKeyAndRevisionConsistent),
            ("testConnectionRequiresSavedDraft", testConnectionRequiresSavedDraft),
            ("testConnectionResultCannotOverwriteNewProfile", testConnectionResultCannotOverwriteNewProfile),
            ("testConnectionResultCannotOverwriteNewRevision", testConnectionResultCannotOverwriteNewRevision)
        ]
        var failures: [String] = []
        for (name, check) in checks {
            print("RUN \(name)")
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                print("FAIL \(name): \(error)")
                failures.append(name)
            }
        }
        print("\(checks.count - failures.count)/\(checks.count) Features host checks passed; no iOS UI/device behavior tested.")
        if !failures.isEmpty {
            throw FeatureTestFailure(message: "failed: \(failures.joined(separator: ", "))")
        }
    }
}
#else
struct SetupViewModelTests {
    @Test @MainActor func initialSetupAndResources() async throws { try await testInitialSetupAndResources() }
    @Test @MainActor func cancelledPreparationNeverStartsCapture() async throws { try await testCancelledPreparationNeverStartsCapture() }
    @Test @MainActor func displayOnlyUpdate() async throws { try await testDisplayOnlyUpdate() }
    @Test @MainActor func languageChangeStopsAndRequiresRestart() async throws { try await testLanguageChangeStopsAndRequiresRestart() }
    @Test @MainActor func userFacingStates() async throws { try await testUserFacingStates() }
}
#endif
