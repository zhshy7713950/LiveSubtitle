import Combine
import Foundation

@MainActor
final class SetupViewModel: ObservableObject {
    @Published private(set) var sourceLanguage = LanguageIdentifier(rawValue: "en")
    @Published private(set) var targetLanguage = LanguageIdentifier(rawValue: "zh-Hans")
    @Published private(set) var requestedMode: RequestedMode = .local
    @Published private(set) var availableSourceLanguages = [LanguageIdentifier(rawValue: "en")]
    @Published private(set) var availableTargetLanguages = [LanguageIdentifier(rawValue: "zh-Hans")]
    @Published private(set) var assetStatus = LanguageAssetStatus(recognition: .missing, localTranslation: .missing)
    @Published private(set) var display = DisplayPreferences(displayCount: RuntimePolicy.defaultDisplayCount, displayStyle: .bilingual)
    @Published private(set) var sessionStatus: SessionStatus?
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?

    private let session: SessionCoordinating
    private let capability: CapabilityChecking
    private let assets: LanguageAssetManaging
    private let preferences: FeaturePreferencesCoordinator
    private let credentials: CredentialStoring
    private var profiles: [CloudProfile] = []
    private var selectedCloudProfileID: UUID?
    private var preparationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var configurationGeneration: UInt64 = 0
    private var modeGeneration: UInt64 = 0
    private var modeOperationTail: Task<Void, Never>?
    private var displayGeneration: UInt64 = 0
    private var displayOperationTail: Task<Void, Never>?
    private var didLoad = false

    init(
        session: SessionCoordinating,
        capability: CapabilityChecking,
        assets: LanguageAssetManaging,
        preferences: FeaturePreferencesCoordinator,
        credentials: CredentialStoring
    ) {
        self.session = session
        self.capability = capability
        self.assets = assets
        self.preferences = preferences
        self.credentials = credentials
    }

    deinit {
        preparationTask?.cancel()
        statusTask?.cancel()
    }

    var statusText: String {
        if let message { return message }
        guard let sessionStatus else { return "选择语言和模式后开始翻译" }
        switch sessionStatus.phase {
        case .idle:
            return "已停止，可以重新开始"
        case .preparing:
            return "正在准备本地资源"
        case .ready:
            return "资源已就绪，可以开始翻译"
        case .requestingCapture:
            return "请确认共享整个屏幕"
        case .starting:
            return "正在启动字幕"
        case .running:
            if sessionStatus.effectiveMode == .localFallback {
                return "AI 暂不可用，已切换为本地翻译"
            }
            return "等待声音"
        case .stopping:
            return "正在停止并清空字幕"
        case .failed:
            return sessionStatus.failure?.featureMessage ?? "翻译未能开始，请重试"
        }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        statusTask = Task { [weak self] in
            let statuses = await self?.session.statuses()
            guard let statuses else { return }
            for await status in statuses {
                if Task.isCancelled { return }
                self?.sessionStatus = status
                if status.phase == .running || status.phase == .failed {
                    self?.message = nil
                }
            }
        }
        do {
            let stored = try await preferences.load()
            profiles = try await preferences.profiles()
            if let stored {
                sourceLanguage = stored.sourceLanguage
                targetLanguage = stored.targetLanguage
                requestedMode = stored.requestedMode
                display = stored.display
            }
            if let stored {
                selectedCloudProfileID = stored.selectedCloudProfileID
            } else {
                selectedCloudProfileID = profiles.first?.id
            }
        } catch {
            message = "设置读取失败，当前使用默认设置"
        }
        await reloadCapabilities()
    }

    func selectSourceLanguage(_ language: LanguageIdentifier) async {
        guard language != sourceLanguage else { return }
        sourceLanguage = language
        await languageSelectionChanged()
    }

    func selectTargetLanguage(_ language: LanguageIdentifier) async {
        guard language != targetLanguage else { return }
        targetLanguage = language
        await languageSelectionChanged()
    }

    func selectMode(_ mode: RequestedMode) async {
        guard mode != requestedMode else { return }
        modeGeneration &+= 1
        configurationGeneration &+= 1
        let generation = modeGeneration
        let previousMode = requestedMode
        requestedMode = mode
        let previousOperation = modeOperationTail
        let operation = Task { @MainActor [self] in
            await previousOperation?.value
            guard generation == modeGeneration else { return }
            if let task = preparationTask {
                task.cancel()
                assets.cancelPreparation()
                await task.value
                await assets.releaseReservations()
                preparationTask = nil
                isPreparing = false
            }
            guard generation == modeGeneration else { return }
            if mode == .ai, sessionStatus?.phase == .running {
                let valid = await hasValidCloudConfiguration()
                guard generation == modeGeneration else { return }
                guard valid else {
                    requestedMode = previousMode
                    message = FailureCode.invalidConfiguration.featureMessage
                    return
                }
            }
            await persistPreferences()
            guard generation == modeGeneration else { return }
            if sessionStatus?.phase == .running {
                await session.selectMode(mode)
            }
        }
        modeOperationTail = operation
        await operation.value
    }

    func updateDisplay(count: Int, style: DisplayStyle) async {
        guard RuntimePolicy.displayCountRange.contains(count) else {
            message = "字幕段数需在 1 到 10 之间"
            return
        }
        displayGeneration &+= 1
        let generation = displayGeneration
        let updatedDisplay = DisplayPreferences(displayCount: count, displayStyle: style)
        display = updatedDisplay
        let previousOperation = displayOperationTail
        let operation = Task { @MainActor [self] in
            await previousOperation?.value
            guard generation == displayGeneration else { return }
            await persistPreferences()
            guard generation == displayGeneration else { return }
            await session.setDisplay(updatedDisplay)
        }
        displayOperationTail = operation
        await operation.value
    }

    func start() {
        guard preparationTask == nil, !isPreparing else { return }
        let generation = configurationGeneration
        isPreparing = true
        message = "正在检查语言和本地资源"
        preparationTask = Task { [weak self] in
            await self?.prepareAndStart(generation: generation)
        }
    }

    func cancelPreparation() {
        guard let task = preparationTask else { return }
        configurationGeneration &+= 1
        task.cancel()
        assets.cancelPreparation()
        message = "正在取消准备"
        Task { @MainActor [weak self, assets] in
            await task.value
            await assets.releaseReservations()
            self?.isPreparing = false
            self?.message = "已取消准备，未开始采集"
        }
    }

    func stop() async {
        let hadPreparation = preparationTask != nil
        if let task = preparationTask {
            configurationGeneration &+= 1
            task.cancel()
            assets.cancelPreparation()
            await task.value
            await assets.releaseReservations()
            preparationTask = nil
            isPreparing = false
        }
        await session.stop(reason: .user)
        if !hadPreparation {
            await assets.releaseReservations()
        }
    }

    func restoreAI() async {
        await session.restoreAI()
    }

    private func prepareAndStart(generation: UInt64) async {
        defer {
            preparationTask = nil
            if configurationGeneration == generation {
                isPreparing = false
            }
        }
        guard sourceLanguage != targetLanguage else {
            message = "源语言和目标语言不能相同"
            return
        }
        if requestedMode == .ai, !(await hasValidCloudConfiguration()) {
            message = FailureCode.invalidConfiguration.featureMessage
            return
        }
        let config = currentConfig
        var report = await capability.check(config: config)
        guard isCurrent(generation) else { return }
        apply(report)
        if let blocker = report.blockers.first(where: { $0 != .assetsMissing && $0 != .preparationCancelled }) {
            message = blocker.featureMessage
            return
        }

        if report.assets.recognition != .ready || report.assets.localTranslation != .ready {
            message = "正在准备本地识别和翻译资源"
            var finished = false
            let events = assets.prepare(source: config.sourceLanguage, target: config.targetLanguage)
            for await event in events {
                guard isCurrent(generation) else { return }
                switch event {
                case .status(let status):
                    assetStatus = status
                case .finished:
                    finished = true
                case .cancelled:
                    message = "已取消准备，未开始采集"
                    return
                case .failed(let code):
                    message = code.featureMessage
                    return
                }
                if finished { break }
            }
            guard finished else {
                if !Task.isCancelled { message = FailureCode.assetsMissing.featureMessage }
                return
            }
        }

        let currentAssets = await assets.status(source: config.sourceLanguage, target: config.targetLanguage)
        report = await capability.check(config: config)
        guard isCurrent(generation) else { return }
        apply(report)
        assetStatus = currentAssets
        guard currentAssets.recognition == .ready, currentAssets.localTranslation == .ready,
              report.blockers.isEmpty else {
            message = FailureCode.assetsMissing.featureMessage
            return
        }

        message = nil
        await session.prepare(config: config)
        guard isCurrent(generation) else { return }
        await session.start()
    }

    private func languageSelectionChanged() async {
        configurationGeneration &+= 1
        if let task = preparationTask {
            task.cancel()
            assets.cancelPreparation()
            await task.value
            preparationTask = nil
            isPreparing = false
        }
        await session.stop(reason: .languageChanged)
        await assets.releaseReservations()
        await persistPreferences()
        await reloadCapabilities()
        message = "语言已更改，请重新开始翻译"
    }

    private func reloadCapabilities() async {
        let report = await capability.check(config: currentConfig)
        apply(report)
    }

    private func apply(_ report: CapabilityReport) {
        availableSourceLanguages = report.sourceLanguages.isEmpty ? [sourceLanguage] : report.sourceLanguages
        availableTargetLanguages = report.targetLanguages.isEmpty ? [targetLanguage] : report.targetLanguages
        assetStatus = report.assets
    }

    private func hasValidCloudConfiguration() async -> Bool {
        do {
            let stored = try await preferences.load()
            profiles = try await preferences.profiles()
            if let stored {
                selectedCloudProfileID = stored.selectedCloudProfileID
            } else if selectedCloudProfileID == nil {
                selectedCloudProfileID = profiles.first?.id
            }
        } catch {
            return false
        }
        guard let selectedCloudProfileID,
              let profile = profiles.first(where: { $0.id == selectedCloudProfileID }),
              FeatureEndpointValidator.isValid(profile.endpoint),
              !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let key = try? await credentials.readKey(profileID: profile.id) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentConfig: SessionConfig {
        SessionConfig(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            requestedMode: requestedMode,
            cloudProfileID: selectedCloudProfileID,
            displayCount: display.displayCount,
            displayStyle: display.displayStyle
        )
    }

    private func persistPreferences() async {
        do {
            let updated = try await preferences.saveSetup(
                source: sourceLanguage,
                target: targetLanguage,
                mode: requestedMode,
                fallbackSelectedProfileID: selectedCloudProfileID,
                display: display
            )
            selectedCloudProfileID = updated.selectedCloudProfileID
        } catch {
            message = "设置保存失败，请稍后重试"
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && configurationGeneration == generation
    }
}

enum FeatureEndpointValidator {
    static func isValid(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}

extension FailureCode {
    var featureMessage: String {
        switch self {
        case .unavailable:
            return "当前功能不可用"
        case .unsupportedLanguage:
            return "当前设备不支持所选语言"
        case .assetsMissing:
            return "本地识别或翻译资源尚未就绪"
        case .preparationCancelled:
            return "已取消准备，未开始采集"
        case .captureFailed:
            return "屏幕共享采音失败，请重新开始"
        case .speechFailed:
            return "本地语音识别失败，请重新开始"
        case .localTranslationFailed:
            return "本地翻译失败，请重新开始"
        case .pipFailed:
            return "字幕小窗启动失败，请重试"
        case .invalidConfiguration:
            return "请先完整配置 AI 接口、模型和 Key"
        case .unauthorized:
            return "AI 接口授权失败，请检查 Key"
        case .rateLimited:
            return "AI 服务请求过于频繁，请稍后重试"
        case .network:
            return "网络连接失败，请稍后重试"
        case .server:
            return "AI 服务暂时不可用"
        case .incompatibleResponse, .refused, .invalidOutput:
            return "AI 服务返回了无法使用的结果"
        case .firstTextTimeout, .deadlineExceeded:
            return "AI 翻译超时"
        }
    }
}
