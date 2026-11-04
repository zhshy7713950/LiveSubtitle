import Foundation

enum StorageError: String, Error, Sendable, Equatable {
    case invalidPreferences
    case invalidProfile
    case persistenceFailed
    case revisionOverflow
    case credentialReadFailed
    case credentialWriteFailed
    case invalidCredentialData
}

actor PreferencesStore: PreferencesStoring {
    static let preferencesKey = "preferences.v1"
    static let profilesKey = "cloudProfiles.v1"

    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() async throws -> AppPreferences? {
        guard let data = defaults.data(forKey: Self.preferencesKey) else { return nil }
        do {
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
            guard Self.isValid(preferences) else {
                defaults.removeObject(forKey: Self.preferencesKey)
                return nil
            }
            return preferences
        } catch {
            defaults.removeObject(forKey: Self.preferencesKey)
            return nil
        }
    }

    func save(_ preferences: AppPreferences) async throws {
        guard Self.isValid(preferences) else { throw StorageError.invalidPreferences }
        try persist(preferences, forKey: Self.preferencesKey)
    }

    func profiles() async throws -> [CloudProfile] {
        loadProfiles()
    }

    func saveProfile(_ profile: CloudProfile) async throws {
        guard Self.isValid(profile) else { throw StorageError.invalidProfile }
        var profiles = loadProfiles()
        let revision: UInt64
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            let storedRevision = profiles[index].revision
            guard storedRevision < UInt64.max else { throw StorageError.revisionOverflow }
            revision = storedRevision + 1
            profiles[index] = profile.withRevision(revision)
        } else {
            revision = max(profile.revision, 1)
            profiles.append(profile.withRevision(revision))
        }
        try persist(profiles, forKey: Self.profilesKey)
    }

    func deleteProfile(id: UUID) async throws {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == id }
        try persist(profiles, forKey: Self.profilesKey)

        if let preferences = loadPreferences(), preferences.selectedCloudProfileID == id {
            let updated = AppPreferences(
                sourceLanguage: preferences.sourceLanguage,
                targetLanguage: preferences.targetLanguage,
                requestedMode: preferences.requestedMode,
                selectedCloudProfileID: nil,
                display: preferences.display
            )
            try persist(updated, forKey: Self.preferencesKey)
        }
    }

    private func loadPreferences() -> AppPreferences? {
        guard let data = defaults.data(forKey: Self.preferencesKey) else { return nil }
        guard let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data),
              Self.isValid(preferences) else {
            defaults.removeObject(forKey: Self.preferencesKey)
            return nil
        }
        return preferences
    }

    private func loadProfiles() -> [CloudProfile] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        guard let profiles = try? JSONDecoder().decode([CloudProfile].self, from: data),
              profiles.allSatisfy(Self.isValid) else {
            defaults.removeObject(forKey: Self.profilesKey)
            return []
        }
        return profiles
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) throws {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            throw StorageError.persistenceFailed
        }
    }

    private static func isValid(_ preferences: AppPreferences) -> Bool {
        let source = preferences.sourceLanguage.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = preferences.targetLanguage.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !source.isEmpty && !target.isEmpty
            && preferences.sourceLanguage != preferences.targetLanguage
            && RuntimePolicy.displayCountRange.contains(preferences.display.displayCount)
    }

    private static func isValid(_ profile: CloudProfile) -> Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && EndpointValidator.validationFailure(for: profile) == nil
    }
}

private extension CloudProfile {
    func withRevision(_ revision: UInt64) -> CloudProfile {
        CloudProfile(id: id, name: name, endpoint: endpoint, model: model, revision: revision)
    }
}
