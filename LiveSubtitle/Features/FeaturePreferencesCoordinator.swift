import Foundation

@MainActor
final class FeaturePreferencesCoordinator {
    private let store: PreferencesStoring
    private var isWriting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: PreferencesStoring) {
        self.store = store
    }

    func load() async throws -> AppPreferences? {
        try await store.load()
    }

    func profiles() async throws -> [CloudProfile] {
        try await store.profiles()
    }

    func saveProfile(_ profile: CloudProfile) async throws {
        try await withWriteLock {
            try await store.saveProfile(profile)
        }
    }

    func deleteProfile(id: UUID) async throws {
        try await withWriteLock {
            try await store.deleteProfile(id: id)
        }
    }

    func saveSelection(_ id: UUID?) async throws -> AppPreferences {
        try await withWriteLock {
            let base = try await store.load() ?? Self.defaultPreferences
            let updated = AppPreferences(
                sourceLanguage: base.sourceLanguage,
                targetLanguage: base.targetLanguage,
                requestedMode: base.requestedMode,
                selectedCloudProfileID: id,
                display: base.display
            )
            try await store.save(updated)
            return updated
        }
    }

    func saveSetup(
        source: LanguageIdentifier,
        target: LanguageIdentifier,
        mode: RequestedMode,
        fallbackSelectedProfileID: UUID?,
        display: DisplayPreferences
    ) async throws -> AppPreferences {
        try await withWriteLock {
            let stored = try await store.load()
            let selectedProfileID = stored?.selectedCloudProfileID ?? (stored == nil ? fallbackSelectedProfileID : nil)
            let updated = AppPreferences(
                sourceLanguage: source,
                targetLanguage: target,
                requestedMode: mode,
                selectedCloudProfileID: selectedProfileID,
                display: display
            )
            try await store.save(updated)
            return updated
        }
    }

    private static var defaultPreferences: AppPreferences {
        AppPreferences(
            sourceLanguage: LanguageIdentifier(rawValue: "en"),
            targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
            requestedMode: .local,
            selectedCloudProfileID: nil,
            display: DisplayPreferences(displayCount: RuntimePolicy.defaultDisplayCount, displayStyle: .bilingual)
        )
    }

    private func withWriteLock<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        if isWriting {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isWriting = true
        }
        defer {
            if waiters.isEmpty {
                isWriting = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation()
    }
}
