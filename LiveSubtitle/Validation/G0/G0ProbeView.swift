#if DEBUG && !targetEnvironment(simulator)
import SwiftUI
import Translation
import AVFoundation

/// Temporary Debug entry point. Remove during TASK-13 integration.
struct G0ProbeView: View {
    @State private var model = G0ProbeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LiveSubtitle · G0").font(.title.bold())
                Text("临时真机验证，不代表功能已通过").foregroundStyle(.secondary)
                Text(model.status).accessibilityIdentifier("g0.status")
                HStack {
                    Button("1. 准备本地资源") { model.beginPreparation() }
                        .disabled(model.preparing || model.running || model.starting || model.ready || model.stopping)
                    if model.preparing { ProgressView() }
                }
                Button("2. 开始全屏共享") { model.start() }
                    .disabled(!model.ready || model.running || model.starting || model.stopping)
                Button("3. 开启字幕小窗") { model.startPiP() }.disabled(!model.running || model.stopping)
                Button("停止并清空", role: .destructive) { model.requestStop() }
                    .disabled(model.stopping || (!model.running && !model.starting && !model.preparing && !model.ready))
                G0PiPPreview(probe: model.pip).id(model.previewID).frame(height: 180)
                Text(model.metricsText).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).accessibilityIdentifier("g0.metrics")
                Button("复制无内容指标") { UIPasteboard.general.string = model.metricsText }
                Text("音频、画面、字幕只在内存中；不使用麦克风、不上传。资源准备可能由系统下载模型。测试时只播放无敏感内容。").font(.caption).foregroundStyle(.secondary)
                ForEach(model.rows) { row in
                    VStack(alignment: .leading) {
                        Text(row.translation.isEmpty ? "本地翻译中…" : row.translation).font(.headline)
                        Text(row.source).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(20)
        }
        .translationTask(model.translationConfiguration, action: G0TranslationProbe.preparationAction(
            token: model.preparationID,
            completed: { await model.finishPreparation($0) },
            failed: { await model.preparationFailed($0) }
        ))
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.backgrounded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            if model.running || model.starting || model.preparing { model.requestStop("锁屏") }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            if model.running || model.starting { model.requestStop("系统音频中断") }
        }
    }
}
#endif
