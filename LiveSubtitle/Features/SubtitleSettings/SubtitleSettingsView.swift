import SwiftUI

struct SubtitleSettingsView: View {
    let display: DisplayPreferences
    let onDisplayChange: (DisplayPreferences) -> Void

    init(
        display: DisplayPreferences,
        onDisplayChange: @escaping (DisplayPreferences) -> Void
    ) {
        self.display = display
        self.onDisplayChange = onDisplayChange
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: countBinding, in: RuntimePolicy.displayCountRange) {
                    LabeledContent("最近字幕段数", value: "\(display.displayCount)")
                }
            } footer: {
                Text("实际可见数量还受小窗尺寸和可读字号限制，优先保留最新字幕。")
            }

            Section("显示方式") {
                Picker("显示方式", selection: styleBinding) {
                    Text("双语，译文为主").tag(DisplayStyle.bilingual)
                    Text("仅译文").tag(DisplayStyle.translationOnly)
                }
                .pickerStyle(.inline)
            }
        }
        .navigationTitle("字幕设置")
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { display.displayCount },
            set: { count in
                onDisplayChange(DisplayPreferences(displayCount: count, displayStyle: display.displayStyle))
            }
        )
    }

    private var styleBinding: Binding<DisplayStyle> {
        Binding(
            get: { display.displayStyle },
            set: { style in
                onDisplayChange(DisplayPreferences(displayCount: display.displayCount, displayStyle: style))
            }
        )
    }
}
