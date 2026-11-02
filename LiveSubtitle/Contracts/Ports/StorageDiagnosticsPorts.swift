import Foundation

protocol PreferencesStoring: Sendable {
    func load() async throws -> AppPreferences?
    func save(_ preferences: AppPreferences) async throws
    func profiles() async throws -> [CloudProfile]
    func saveProfile(_ profile: CloudProfile) async throws
    func deleteProfile(id: UUID) async throws
}

/// Plain key material is transient. Never log, serialize or embed it in a model.
protocol CredentialStoring: Sendable {
    func readKey(profileID: UUID) async throws -> String?
    func replaceKey(_ key: String, profileID: UUID) async throws
    func deleteKey(profileID: UUID) async throws
    func clearAppNamespace() async throws
}

protocol DiagnosticsRecording: Sendable {
    func record(_ event: DiagnosticEvent) async
    func clearSession() async
}
