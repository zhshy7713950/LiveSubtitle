import Foundation
#if FEATURES_HOST_CHECK
#else
import Testing
@testable import LiveSubtitle
#endif

@MainActor
func testCloudSaveIsNotEnableAI() async throws {
    let rig = FeatureTestRig()
    let cloud = rig.makeCloudViewModel()
    cloud.newProfile()
    cloud.name = "Example"
    cloud.endpoint = "http://provider.example/v1/chat/completions"
    cloud.model = "test-model"
    cloud.keyInput = "test-key"

    await cloud.saveProfile()
    try featureRequire(cloud.profiles.isEmpty, "non-HTTPS endpoint was saved")
    cloud.endpoint = "https://provider.example/v1/chat/completions"
    cloud.model = "   "
    await cloud.saveProfile()
    try featureRequire(cloud.profiles.isEmpty, "empty model was saved")

    cloud.model = "test-model"
    await cloud.saveProfile()
    try featureRequire(cloud.profiles.count == 1, "complete non-secret profile was not saved")
    try featureRequire(cloud.profiles.first?.revision == 1, "stored profile revision was not reloaded")
    try featureRequire(await rig.connectionTester.testedProfiles.isEmpty, "saving triggered a connection test")
    try featureRequire(!rig.log.values.contains("restoreAI"), "saving restored AI")
    try featureRequire(!rig.log.values.contains("selectMode.ai"), "saving enabled AI")

    cloud.keyInput = "   "
    await cloud.replaceKey()
    try featureRequire(await rig.credentials.hasKey(profileID: cloud.profiles[0].id) == false, "blank Key reached storage")
    cloud.keyInput = "test-key"
    await cloud.replaceKey()
    try featureRequire(await rig.credentials.hasKey(profileID: cloud.profiles[0].id), "valid Key was not stored")
    try featureRequire(cloud.profiles.first?.revision == 2, "Key replacement did not advance profile revision")
    try featureRequire(cloud.keyInput.isEmpty, "Key input remained visible after replacement")
    try featureRequire(cloud.hasStoredKey, "stored Key state was not exposed without exposing the Key")
    try featureRequire(!rig.log.values.contains("restoreAI"), "Key replacement restored AI")
    try featureRequire(!rig.log.values.contains("selectMode.ai"), "Key replacement enabled AI")
}

@MainActor
func testCloudMutationOrder() async throws {
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
    let selection = Task { await cloud.selectProfile(id: second.id) }
    try await featureEventually("selection did not reach mutation barrier") {
        rig.log.values.contains("willChange")
    }
    try featureRequire(!rig.log.values.contains("savePreferences"), "selection persisted before willChange returned")
    try featureRequire(!rig.log.values.contains("didChange"), "selection notified didChange before persistence")
    await rig.session.releaseWillChange()
    await selection.value
    try featureRequire(rig.log.values == ["cancelConnectionTest", "willChange", "savePreferences", "didChange"], "profile selection mutation order was wrong")

    rig.log.reset()
    cloud.name = "Second edited"
    await cloud.saveProfile()
    try featureRequire(rig.log.values == ["cancelConnectionTest", "willChange", "saveProfile", "didChange"], "profile edit mutation order was wrong")
    try featureRequire(cloud.profiles.first(where: { $0.id == second.id })?.revision == 2, "profile edit did not reload incremented revision")

    rig.log.reset()
    cloud.keyInput = "test-key"
    await cloud.replaceKey()
    try featureRequire(rig.log.values == ["cancelConnectionTest", "willChange", "saveProfile", "replaceKey", "didChange"], "Key replacement mutation order was wrong")
    try featureRequire(cloud.profiles.first(where: { $0.id == second.id })?.revision == 3, "Key replacement did not increment revision")

    rig.log.reset()
    await cloud.deleteKey()
    try featureRequire(rig.log.values == ["cancelConnectionTest", "willChange", "saveProfile", "deleteKey", "didChange"], "Key deletion mutation order was wrong")
    try featureRequire(cloud.profiles.first(where: { $0.id == second.id })?.revision == 4, "Key deletion did not increment revision")
    try featureRequire(!cloud.hasStoredKey, "deleted Key still appeared present")
    try featureRequire(!rig.log.values.contains("restoreAI"), "profile mutations restored AI")
    try featureRequire(!rig.log.values.contains("selectMode.ai"), "profile mutations enabled AI")

    rig.log.reset()
    await cloud.deleteProfile()
    try featureRequire(rig.log.values == ["cancelConnectionTest", "willChange", "deleteKey", "deleteProfile", "savePreferences", "didChange"], "profile deletion mutation order was wrong")
    try featureRequire(cloud.profiles.isEmpty || cloud.profiles.contains(where: { $0.id == second.id }) == false, "deleted profile remained available")
}

#if !FEATURES_HOST_CHECK
struct CloudSettingsViewModelTests {
    @Test @MainActor func cloudSaveIsNotEnableAI() async throws { try await testCloudSaveIsNotEnableAI() }
    @Test @MainActor func cloudMutationOrder() async throws { try await testCloudMutationOrder() }
}
#endif
