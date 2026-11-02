import SwiftUI

/// Framework landing screen. No service is constructed or started here.
struct ScaffoldView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LiveSubtitle")
                .font(.largeTitle.bold())
            Text("基础框架")
                .font(.title2)
            Text("采集、识别、翻译与悬浮字幕尚未实现。开发任务见 docs/tasks/README.md。")
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
