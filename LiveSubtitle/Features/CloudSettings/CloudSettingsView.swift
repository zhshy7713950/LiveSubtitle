import SwiftUI

struct CloudSettingsView: View {
    @StateObject private var viewModel: CloudSettingsViewModel
    @State private var confirmsProfileDeletion = false

    init(viewModel: CloudSettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section("AI 配置") {
                if !viewModel.profiles.isEmpty {
                    Picker("当前配置", selection: profileBinding) {
                        ForEach(viewModel.profiles, id: \.id) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                }
                Button("新建配置") {
                    viewModel.newProfile()
                }
            }

            Section("接口信息") {
                TextField("配置名称", text: $viewModel.name)
                TextField("完整请求 URL", text: $viewModel.endpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型名称", text: $viewModel.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $viewModel.keyInput)
                    .textContentType(.password)
                if viewModel.hasStoredKey {
                    Text("Key 已保存；输入新值可替换，界面不会显示原 Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("地址需包含完整的 HTTPS 请求路径，不会自动拼接接口路径。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("保存配置") {
                    Task { await viewModel.saveProfile() }
                }
                Button("替换 Key") {
                    Task { await viewModel.replaceKey() }
                }
                Button("删除 Key", role: .destructive) {
                    Task { await viewModel.deleteKey() }
                }
                .disabled(!viewModel.hasStoredKey)
                Button("删除当前配置", role: .destructive) {
                    confirmsProfileDeletion = true
                }
                .disabled(viewModel.selectedProfileID == nil)
            } footer: {
                Text("保存配置或修改 Key 不会自动启用 AI；运行中的会话会先保持本地翻译。")
            }

            Section {
                Button(viewModel.isTesting ? "正在测试连接" : "测试连接") {
                    Task { await viewModel.testConnection() }
                }
                .disabled(viewModel.isTesting)
                if let message = viewModel.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("测试只发送固定的无敏感短句，不会发送当前字幕。")
            }
        }
        .navigationTitle("AI 设置")
        .task { await viewModel.load() }
        .confirmationDialog("删除当前配置和对应 Key？", isPresented: $confirmsProfileDeletion) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteProfile() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var profileBinding: Binding<UUID?> {
        Binding(
            get: { viewModel.selectedProfileID },
            set: { id in
                guard let id else { return }
                Task { await viewModel.selectProfile(id: id) }
            }
        )
    }
}
