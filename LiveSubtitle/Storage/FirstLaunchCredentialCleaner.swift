import Foundation

actor FirstLaunchCredentialCleaner {
    static let flagKey = "firstLaunchCredentialCleanup.complete.v1"

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring

    init(suiteName: String? = nil, credentials: any CredentialStoring) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.credentials = credentials
    }

    func cleanIfNeeded() async throws {
        guard !defaults.bool(forKey: Self.flagKey) else { return }
        try await credentials.clearAppNamespace()
        defaults.set(true, forKey: Self.flagKey)
    }
}
