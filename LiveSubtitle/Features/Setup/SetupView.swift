import SwiftUI

struct SetupView: View {
    @StateObject private var viewModel: SetupViewModel

    init(viewModel: SetupViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("源语言", selection: sourceBinding) {
                        ForEach(viewModel.availableSourceLanguages, id: \.self) { language in
                            Text(language.featureDisplayName).tag(language)
                        }
                    }
                    Picker("目标语言", selection: targetBinding) {
                        ForEach(viewModel.availableTargetLanguages, id: \.self) { language in
                            Text(language.featureDisplayName).tag(language)
                        }
                    }
                }

                Section("翻译模式") {
                    Picker("模式", selection: modeBinding) {
                        Text("本地翻译").tag(RequestedMode.local)
                        Text("AI 翻译").tag(RequestedMode.ai)
                    }
                    .pickerStyle(.segmented)
                    if viewModel.requestedMode == .ai {
                        Text("AI 模式只发送当前识别文字到你所配置的服务；语音识别和本地备用翻译仍在设备上。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("本地资源") {
                    LabeledContent("语音识别", value: viewModel.assetStatus.recognition.featureDisplayName)
                    LabeledContent("本地备用翻译", value: viewModel.assetStatus.localTranslation.featureDisplayName)
                    if viewModel.isPreparing {
                        HStack {
                            ProgressView()
                            Text("正在准备，没有准确进度时请稍候")
                                .font(.footnote)
                        }
                        Button("取消准备", role: .cancel) {
                            viewModel.cancelPreparation()
                        }
                    }
                }

                Section {
                    Button("开始翻译") {
                        viewModel.start()
                    }
                    .disabled(viewModel.isPreparing)
                    Button("停止翻译", role: .destructive) {
                        Task { await viewModel.stop() }
                    }
                    NavigationLink("字幕设置") {
                        SubtitleSettingsView(display: viewModel.display) { display in
                            Task {
                                await viewModel.updateDisplay(
                                    count: display.displayCount,
                                    style: display.displayStyle
                                )
                            }
                        }
                    }
                }

                Section("当前状态") {
                    Text(viewModel.statusText)
                    if viewModel.sessionStatus?.effectiveMode == .localFallback {
                        Button("恢复 AI") {
                            Task { await viewModel.restoreAI() }
                        }
                    }
                }
            }
            .navigationTitle("实时字幕")
            .task { await viewModel.load() }
        }
    }

    private var sourceBinding: Binding<LanguageIdentifier> {
        Binding(
            get: { viewModel.sourceLanguage },
            set: { language in Task { await viewModel.selectSourceLanguage(language) } }
        )
    }

    private var targetBinding: Binding<LanguageIdentifier> {
        Binding(
            get: { viewModel.targetLanguage },
            set: { language in Task { await viewModel.selectTargetLanguage(language) } }
        )
    }

    private var modeBinding: Binding<RequestedMode> {
        Binding(
            get: { viewModel.requestedMode },
            set: { mode in Task { await viewModel.selectMode(mode) } }
        )
    }
}

private extension LanguageIdentifier {
    var featureDisplayName: String {
        switch rawValue {
        case "en": return "英语"
        case "en-US": return "英语（美国）"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁体中文"
        default: return Locale.current.localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }
}

private extension AssetState {
    var featureDisplayName: String {
        switch self {
        case .unsupported: return "不支持"
        case .missing: return "需要准备"
        case .preparing: return "正在准备"
        case .ready: return "已就绪"
        }
    }
}
