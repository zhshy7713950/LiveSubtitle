import Foundation
import Security
#if !TASK09_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private func task09Service(_ label: String) -> String {
    "LiveSubtitleTests.Storage.\(label).\(UUID().uuidString)"
}

private func task09WithCredentialStores(
    _ body: (KeychainCredentialStore, KeychainCredentialStore) async throws -> Void
) async throws {
    let appStore = KeychainCredentialStore(service: task09Service("app"))
    let otherStore = KeychainCredentialStore(service: task09Service("other"))
    try await appStore.clearAppNamespace()
    try await otherStore.clearAppNamespace()
    do {
        try await body(appStore, otherStore)
        try await appStore.clearAppNamespace()
        try await otherStore.clearAppNamespace()
    } catch {
        try? await appStore.clearAppNamespace()
        try? await otherStore.clearAppNamespace()
        throw error
    }
}

func task09ProfileRevisionAndKeyReplacement() async throws {
    try await task09WithDefaults { suite, _ in
        try await task09WithCredentialStores { credentials, _ in
            let preferences = PreferencesStore(suiteName: suite)
            let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            try await preferences.saveProfile(task09Profile(id: firstID))
            try await preferences.saveProfile(task09Profile(id: firstID))
            try task09Require(try await preferences.profiles().first?.revision == 2, "profile revision did not advance")

            try await credentials.replaceKey("fixture-key-a-1", profileID: firstID)
            try await credentials.replaceKey("fixture-key-b", profileID: secondID)
            try task09Require(try await credentials.readKey(profileID: firstID) == "fixture-key-a-1", "first key was not stored")
            try task09Require(try await credentials.readKey(profileID: secondID) == "fixture-key-b", "second key was not stored")

            try await credentials.replaceKey("fixture-key-a-2", profileID: firstID)
            try task09Require(try await credentials.readKey(profileID: firstID) == "fixture-key-a-2", "key replacement failed")
            try task09Require(try await credentials.readKey(profileID: secondID) == "fixture-key-b", "replacement affected another profile")
            try await credentials.deleteKey(profileID: firstID)
            try task09Require(try await credentials.readKey(profileID: firstID) == nil, "deleted key remains")
            try task09Require(try await credentials.readKey(profileID: secondID) == "fixture-key-b", "deletion affected another profile")
        }
    }
}

func task09FirstLaunchClearsOnlyAppNamespace() async throws {
    try await task09WithDefaults { suite, _ in
        try await task09WithCredentialStores { appStore, otherStore in
            let appProfile = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            let otherProfile = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            try await appStore.replaceKey("fixture-app-key", profileID: appProfile)
            try await otherStore.replaceKey("fixture-other-key", profileID: otherProfile)

            #if os(iOS)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: task09AppServiceForAttributes(appStore),
                kSecAttrAccount as String: appProfile.uuidString,
                kSecReturnAttributes as String: true
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            try task09Require(status == errSecSuccess, "could not inspect test credential attributes")
            let attributes = try task09Value(result as? [String: Any])
            try task09Require(
                attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                "credential is not WhenUnlockedThisDeviceOnly"
            )
            #endif

            let cleaner = FirstLaunchCredentialCleaner(suiteName: suite, credentials: appStore)
            try await cleaner.cleanIfNeeded()
            try task09Require(try await appStore.readKey(profileID: appProfile) == nil, "first launch retained app credential")
            try task09Require(try await otherStore.readKey(profileID: otherProfile) == "fixture-other-key", "first launch deleted another namespace")

            try await appStore.replaceKey("fixture-new-key", profileID: appProfile)
            try await cleaner.cleanIfNeeded()
            try task09Require(try await appStore.readKey(profileID: appProfile) == "fixture-new-key", "cleanup ran more than once")
            try task09Require(try await otherStore.readKey(profileID: otherProfile) == "fixture-other-key", "second cleanup affected another namespace")
        }
    }
}

private func task09AppServiceForAttributes(_ store: KeychainCredentialStore) -> String {
    store.service
}

func task09MissingKey() async throws {
    try await task09WithCredentialStores { credentials, _ in
        try task09Require(try await credentials.readKey(profileID: UUID()) == nil, "missing key did not return nil")
        try await credentials.deleteKey(profileID: UUID())
    }
}

actor Task09FailingCredentialStore: CredentialStoring {
    private var fails = true
    private(set) var clearCount = 0

    func readKey(profileID: UUID) async throws -> String? { nil }
    func replaceKey(_ key: String, profileID: UUID) async throws {}
    func deleteKey(profileID: UUID) async throws {}

    func clearAppNamespace() async throws {
        clearCount += 1
        if fails { throw StorageError.credentialWriteFailed }
    }

    func allowCleanup() { fails = false }
}

func task09FirstLaunchFailureRetries() async throws {
    try await task09WithDefaults { suite, defaults in
        let credentials = Task09FailingCredentialStore()
        let cleaner = FirstLaunchCredentialCleaner(suiteName: suite, credentials: credentials)
        try await task09ExpectError(.credentialWriteFailed) {
            try await cleaner.cleanIfNeeded()
        }
        try task09Require(!defaults.bool(forKey: FirstLaunchCredentialCleaner.flagKey), "failed cleanup set completion flag")
        await credentials.allowCleanup()
        try await cleaner.cleanIfNeeded()
        try task09Require(await credentials.clearCount == 2, "failed cleanup was not retried")
        try task09Require(defaults.bool(forKey: FirstLaunchCredentialCleaner.flagKey), "successful cleanup did not set flag")
        try await cleaner.cleanIfNeeded()
        try task09Require(await credentials.clearCount == 2, "successful cleanup repeated")
    }
}

#if !TASK09_HOST_CHECK
@Test func testProfileRevisionAndKeyReplacement() async throws {
    try await task09ProfileRevisionAndKeyReplacement()
}

@Test func testFirstLaunchClearsOnlyAppNamespace() async throws {
    try await task09FirstLaunchClearsOnlyAppNamespace()
}

@Test func testFirstLaunchFailureRetries() async throws {
    try await task09FirstLaunchFailureRetries()
}
#endif
