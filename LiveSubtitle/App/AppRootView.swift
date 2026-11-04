import SwiftUI

struct AppRootView: View {
    @ObservedObject var composition: AppComposition
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if composition.isReady {
                LanguagePreparationHost(manager: composition.assets) {
                    VStack(spacing: 0) {
                        SubtitleSurface(renderer: composition.renderer)
                            .frame(height: 120)
                            .background(.black)
                            .accessibilityLabel("当前字幕预览")
                        TabView(selection: $selectedTab) {
                            SetupView(viewModel: composition.setup)
                                .id(composition.setupID)
                                .tabItem { Label("字幕", systemImage: "captions.bubble") }.tag(0)
                            NavigationStack { CloudSettingsView(viewModel: composition.cloudSettings) }
                                .tabItem { Label("AI 设置", systemImage: "gearshape") }.tag(1)
                        }
                        .onChange(of: selectedTab) { _, tab in
                            if tab == 0 { Task { await composition.refreshSetup() } }
                        }
                    }
                }
            } else if composition.startupFailed {
                ContentUnavailableView {
                    Label("无法准备安全存储", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text("请解锁设备后重试，完成安全存储准备后才能开始翻译。")
                } actions: {
                    Button("重试") { Task { await composition.bootstrap() } }
                }
            } else {
                ProgressView("正在准备安全存储")
            }
        }
        .task { await composition.bootstrap() }
    }
}

/// Attach the exact layer used by PiP to a visible UIKit surface before starting it.
private struct SubtitleSurface: UIViewRepresentable {
    let renderer: SubtitleRenderer
    func makeUIView(context: Context) -> SubtitleSurfaceView { SubtitleSurfaceView(renderer: renderer) }
    func updateUIView(_ uiView: SubtitleSurfaceView, context: Context) {}
}

private final class SubtitleSurfaceView: UIView {
    private let renderer: SubtitleRenderer
    init(renderer: SubtitleRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        layer.addSublayer(renderer.displayLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.displayLayer.frame = bounds
    }
}
