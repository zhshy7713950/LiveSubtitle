import Combine
import Foundation

@MainActor
final class CloudSettingsViewModel: ObservableObject {
    @Published var name = ""
    @Published var endpoint = ""
    @Published var model = ""
    @Published var keyInput = ""
    @Published private(set) var profiles: [CloudProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var hasStoredKey = false
    @Published private(set) var isTesting = false
    @Published private(set) var isMutating = false
    @Published private(set) var message: String?

    private let session: SessionCoordinating
    private let preferences: FeaturePreferencesCoordinator
    private let credentials: CredentialStoring
    private let connectionTester: ConnectionTesting
    private var currentPreferences: AppPreferences?
    private var mutationTail: Task<Bool, Never>?
    private var queuedMutationCount = 0
    private var connectionGeneration: UInt64 = 0

    init(
        session: SessionCoordinating,
        preferences: FeaturePreferencesCoordinator,
        credentials: CredentialStoring,
        connectionTester: ConnectionTesting
    ) {
        self.session = session
        self.preferences = preferences
        self.credentials = credentials
        self.connectionTester = connectionTester
    }

    func load() async {
        do {
            currentPreferences = try await preferences.load()
            profiles = try await preferences.profiles()
            if let currentPreferences {
                selectedProfileID = currentPreferences.selectedCloudProfileID
            } else {
                selectedProfileID = profiles.first?.id
            }
            showSelectedProfile()
            await refreshKeyState()
        } catch {
            message = "AI 配置读取失败，请稍后重试"
        }
    }

    func newProfile() {
        connectionGeneration &+= 1
        isTesting = false
        Task { await connectionTester.cancel() }
        selectedProfileID = nil
        name = ""
        endpoint = ""
        model = ""
        keyInput = ""
        hasStoredKey = false
        message = nil
    }

    func selectProfile(id: UUID) async {
        guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
        let succeeded = await performMutation {
            try await self.saveSelection(id)
        }
        guard succeeded else { return }
        selectedProfileID = id
        await reloadProfiles()
        showSelectedProfile()
        await refreshKeyState()
        message = "已选择配置，AI 仍保持本地"
    }

    func saveProfile() async {
        guard let draft = validatedProfile() else { return }
        let isNewSelection = selectedProfileID == nil || currentPreferences?.selectedCloudProfileID != draft.id
        let succeeded = await performMutation {
            try await self.preferences.saveProfile(draft)
            if isNewSelection {
                try await self.saveSelection(draft.id)
            }
        }
        guard succeeded else { return }
        selectedProfileID = draft.id
        await reloadProfiles()
        showSelectedProfile()
        await refreshKeyState()
        message = "配置已保存，AI 仍保持本地，需手动启用"
    }

    func replaceKey() async {
        guard let profile = selectedProfile else {
            message = "请先保存并选择 AI 配置"
            return
        }
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            message = "请输入新的 API Key"
            return
        }
        let succeeded = await performMutation {
            try await self.preferences.saveProfile(profile)
            try await self.credentials.replaceKey(key, profileID: profile.id)
        }
        guard succeeded else { return }
        keyInput = ""
        await reloadProfiles()
        await refreshKeyState()
        message = "Key 已替换，AI 仍保持本地"
    }

    func deleteKey() async {
        guard let profile = selectedProfile else {
            message = "请先选择 AI 配置"
            return
        }
        let succeeded = await performMutation {
            try await self.preferences.saveProfile(profile)
            try await self.credentials.deleteKey(profileID: profile.id)
        }
        guard succeeded else { return }
        keyInput = ""
        await reloadProfiles()
        await refreshKeyState()
        message = "Key 已删除，AI 仍保持本地"
    }

    func deleteProfile() async {
        guard let profile = selectedProfile else {
            message = "请先选择 AI 配置"
            return
        }
        let succeeded = await performMutation {
            try await self.credentials.deleteKey(profileID: profile.id)
            try await self.preferences.deleteProfile(id: profile.id)
            try await self.saveSelection(nil)
        }
        guard succeeded else { return }
        selectedProfileID = nil
        keyInput = ""
        await reloadProfiles()
        showSelectedProfile()
        hasStoredKey = false
        message = "配置和对应 Key 已删除"
    }

    func testConnection() async {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isTesting = true
        await connectionTester.cancel()
        guard let profile = selectedProfile, FeatureEndpointValidator.isValid(profile.endpoint),
              !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draftMatches(profile) else {
            if generation == connectionGeneration {
                isTesting = false
                message = "请先保存当前配置和 Key，再测试连接"
            }
            return
        }
        guard let key = try? await credentials.readKey(profileID: profile.id),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if generation == connectionGeneration {
                isTesting = false
                message = "请先保存 API Key"
            }
            return
        }
        guard isConnectionCurrent(generation, profile: profile) else {
            if generation == connectionGeneration { isTesting = false }
            return
        }
        let result = await connectionTester.test(profile: profile)
        if generation == connectionGeneration { isTesting = false }
        guard isConnectionCurrent(generation, profile: profile) else { return }
        switch result {
        case .success:
            message = "连接测试成功；不会自动启用 AI"
        case .failure(let code):
            message = code.featureMessage
        }
    }

    private var selectedProfile: CloudProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == selectedProfileID })
    }

    private func draftMatches(_ profile: CloudProfile) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) == profile.name &&
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines) == profile.endpoint.absoluteString &&
        model.trimmingCharacters(in: .whitespacesAndNewlines) == profile.model &&
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isConnectionCurrent(_ generation: UInt64, profile: CloudProfile) -> Bool {
        generation == connectionGeneration &&
        selectedProfile?.id == profile.id &&
        selectedProfile?.revision == profile.revision &&
        draftMatches(profile)
    }

    private func validatedProfile() -> CloudProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            message = "请输入配置名称"
            return nil
        }
        guard let url = URL(string: trimmedEndpoint), FeatureEndpointValidator.isValid(url) else {
            message = "请输入完整、有效的 HTTPS 请求地址"
            return nil
        }
        guard !trimmedModel.isEmpty else {
            message = "请输入模型名称"
            return nil
        }
        return CloudProfile(
            id: selectedProfileID ?? UUID(),
            name: trimmedName,
            endpoint: url,
            model: trimmedModel,
            revision: selectedProfile?.revision ?? 0
        )
    }

    private func performMutation(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        connectionGeneration &+= 1
        isTesting = false
        queuedMutationCount += 1
        isMutating = true
        let previousMutation = mutationTail
        let mutation = Task { @MainActor [self] in
            defer {
                queuedMutationCount -= 1
                isMutating = queuedMutationCount > 0
            }
            _ = await previousMutation?.value
            await connectionTester.cancel()
            await session.cloudProfileWillChange()
            do {
                try await operation()
                await session.cloudProfileDidChange()
                await reloadProfiles()
                await refreshKeyState()
                return true
            } catch {
                await session.cloudProfileDidChange()
                await reloadProfiles()
                await refreshKeyState()
                message = "配置未完全变更，已重新读取当前状态；AI 仍保持本地"
                return false
            }
        }
        mutationTail = mutation
        return await mutation.value
    }

    private func saveSelection(_ id: UUID?) async throws {
        currentPreferences = try await preferences.saveSelection(id)
    }

    private func reloadProfiles() async {
        do {
            profiles = try await preferences.profiles()
        } catch {
            message = "配置已变更，但重新读取失败"
        }
    }

    private func refreshKeyState() async {
        guard let selectedProfileID else {
            hasStoredKey = false
            return
        }
        let key = try? await credentials.readKey(profileID: selectedProfileID)
        hasStoredKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func showSelectedProfile() {
        guard let profile = selectedProfile else {
            name = ""
            endpoint = ""
            model = ""
            keyInput = ""
            return
        }
        name = profile.name
        endpoint = profile.endpoint.absoluteString
        model = profile.model
        keyInput = ""
    }
}
