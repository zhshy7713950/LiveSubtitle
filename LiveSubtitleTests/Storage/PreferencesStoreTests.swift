import Foundation
#if !TASK09_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

struct Task09CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func task09Require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Task09CheckFailure(message: message) }
}

func task09ExpectError(
    _ expected: StorageError,
    _ operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw Task09CheckFailure(message: "expected \(expected.rawValue)")
    } catch let error as StorageError {
        try task09Require(error == expected, "unexpected storage error: \(error.rawValue)")
    }
}

func task09Preferences(
    displayCount: Int = 3,
    source: String = "en",
    target: String = "zh-Hans",
    selectedProfileID: UUID? = nil
) -> AppPreferences {
    AppPreferences(
        sourceLanguage: LanguageIdentifier(rawValue: source),
        targetLanguage: LanguageIdentifier(rawValue: target),
        requestedMode: .local,
        selectedCloudProfileID: selectedProfileID,
        display: DisplayPreferences(displayCount: displayCount, displayStyle: .bilingual)
    )
}

func task09Profile(
    id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    revision: UInt64 = 1,
    endpoint: URL = URL(string: "https://provider.example/v1/chat/completions")!
) -> CloudProfile {
    CloudProfile(id: id, name: "Test profile", endpoint: endpoint, model: "test-model", revision: revision)
}

func task09WithDefaults(_ body: (String, UserDefaults) async throws -> Void) async throws {
    let suite = "LiveSubtitleTests.Storage.\(UUID().uuidString)"
    let defaults = try task09Value(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(suite, defaults)
}

func task09Value<T>(_ value: T?) throws -> T {
    guard let value else { throw Task09CheckFailure(message: "missing value") }
    return value
}

func task09PreferencesContainNoContentOrKey() async throws {
    try await task09WithDefaults { suite, defaults in
        let store = PreferencesStore(suiteName: suite)
        let profile = task09Profile()
        try await store.save(task09Preferences(selectedProfileID: profile.id))
        try await store.saveProfile(profile)

        let preferencesData = try task09Value(defaults.data(forKey: PreferencesStore.preferencesKey))
        let profilesData = try task09Value(defaults.data(forKey: PreferencesStore.profilesKey))
        let preferencesObject = try JSONSerialization.jsonObject(with: preferencesData)
        let profilesObject = try JSONSerialization.jsonObject(with: profilesData)
        let preferencesJSON = try task09Value(preferencesObject as? [String: Any])
        let profilesJSON = try task09Value(profilesObject as? [[String: Any]])

        try task09Require(
            Set(preferencesJSON.keys) == [
                "sourceLanguage", "targetLanguage", "requestedMode", "selectedCloudProfileID", "display"
            ],
            "preferences persisted an unexpected field"
        )
        try task09Require(profilesJSON.count == 1, "profile was not persisted")
        try task09Require(
            Set(profilesJSON[0].keys) == ["id", "name", "endpoint", "model", "revision"],
            "profile persisted content or a credential field"
        )
    }
}

func task09BoundsAndRecovery() async throws {
    try await task09WithDefaults { suite, defaults in
        let store = PreferencesStore(suiteName: suite)
        let valid = task09Preferences()
        try task09Require(valid.display.displayCount == 3, "default display count is not 3")
        try await store.save(valid)
        try task09Require(try await store.load() == valid, "valid preferences did not round trip")

        for count in [0, 11] {
            try await task09ExpectError(.invalidPreferences) {
                try await store.save(task09Preferences(displayCount: count))
            }
        }
        try await task09ExpectError(.invalidPreferences) {
            try await store.save(task09Preferences(target: "en"))
        }
        try task09Require(try await store.load() == valid, "rejected preferences replaced valid data")

        try await task09ExpectError(.invalidProfile) {
            try await store.saveProfile(task09Profile(endpoint: URL(string: "http://provider.example/chat")!))
        }
        try await task09ExpectError(.invalidProfile) {
            try await store.saveProfile(CloudProfile(
                id: UUID(), name: "Test", endpoint: URL(string: "https://provider.example/chat")!,
                model: "", revision: 1
            ))
        }
        try task09Require(try await store.profiles().isEmpty, "invalid profile was persisted")

        defaults.set(Data("broken".utf8), forKey: PreferencesStore.preferencesKey)
        defaults.set(Data("broken".utf8), forKey: PreferencesStore.profilesKey)
        try task09Require(try await store.load() == nil, "corrupt preferences were not recoverable")
        try task09Require(try await store.profiles().isEmpty, "corrupt profiles were not recoverable")
        try await store.save(valid)
        try await store.saveProfile(task09Profile())
        try task09Require(try await store.load() == valid, "valid preferences could not be restored")
        try task09Require(try await store.profiles().count == 1, "valid profile could not be restored")
    }
}

func task09ProfileRevisionAndDeletion() async throws {
    try await task09WithDefaults { suite, defaults in
        let store = PreferencesStore(suiteName: suite)
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try await store.saveProfile(task09Profile(id: firstID, revision: 7))
        try task09Require(try await store.profiles().first?.revision == 7, "new profile revision changed")
        try await store.saveProfile(task09Profile(id: firstID, revision: 1))
        try task09Require(try await store.profiles().first?.revision == 8, "revision did not use stored version")
        try await store.saveProfile(task09Profile(id: firstID, revision: 0))
        try task09Require(try await store.profiles().first?.revision == 9, "stale input lowered revision")

        try await store.saveProfile(task09Profile(id: secondID, revision: 2))
        try await store.save(task09Preferences(selectedProfileID: firstID))
        try await store.deleteProfile(id: secondID)
        try task09Require(try await store.profiles().map(\.id) == [firstID], "delete removed the wrong profile")
        try task09Require(try await store.load()?.selectedCloudProfileID == firstID, "unrelated selection was cleared")
        try await store.deleteProfile(id: firstID)
        try task09Require(try await store.profiles().isEmpty, "target profile was not deleted")
        try task09Require(try await store.load()?.selectedCloudProfileID == nil, "deleted profile remained selected")

        try await store.saveProfile(task09Profile(id: firstID, revision: UInt64.max))
        try await task09ExpectError(.revisionOverflow) {
            try await store.saveProfile(task09Profile(id: firstID, revision: 1))
        }
        try task09Require(try await store.profiles().first?.revision == UInt64.max, "overflow replaced valid profile")
    }
}

#if !TASK09_HOST_CHECK
@Test func testPreferencesContainNoContentOrKey() async throws {
    try await task09PreferencesContainNoContentOrKey()
}

@Test func testBoundsAndMissingKey() async throws {
    try await task09BoundsAndRecovery()
    try await task09MissingKey()
}

@Test func testProfileRevisionAndDeletion() async throws {
    try await task09ProfileRevisionAndDeletion()
}
#endif

#if TASK09_HOST_CHECK
@main
struct Task09HostChecks {
    static func main() async {
        do {
            try await task09PreferencesContainNoContentOrKey()
            try await task09BoundsAndRecovery()
            try await task09MissingKey()
            try await task09ProfileRevisionAndDeletion()
            try await task09ProfileRevisionAndKeyReplacement()
            try await task09FirstLaunchClearsOnlyAppNamespace()
            try await task09FirstLaunchFailureRetries()
            print("TASK-09 host checks: 7 passed")
        } catch {
            print("TASK-09 host checks failed: \(error)")
            exit(1)
        }
    }
}
#endif
