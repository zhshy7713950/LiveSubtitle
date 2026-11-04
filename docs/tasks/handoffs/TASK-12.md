# TASK-12 交接

- 基线 commit：`29aae8d76ca7465f827f98a430fe5864e7af5a8f`（本地 `main`）
- 任务分支 / commit：`worktree-task12` / 本提交（实现与交接同一 commit）
- 前置报告：`docs/reports/g0-device-report.md` 仍明确为“未完成；G0 尚未通过”；本任务按任务卡允许的方式使用 Ports 和任务内 doubles 独立开发，不宣称完整链路可用。
- 状态：待审查（独立审查的 Critical/Important 已逐项 RED→GREEN 修复；等待集成人审查）

## 改动

- `Setup/SetupView.swift`、`Setup/SetupViewModel.swift`：默认本地模式、英文到简体中文建议及可修改语言列表；能力检查、本地识别/翻译资源准备、取消、开始/停止、会话状态、显式 AI 恢复。AI 模式同样要求本地备用资源 ready，不显示虚构百分比。
- `CloudSettings/CloudSettingsView.swift`、`CloudSettings/CloudSettingsViewModel.swift`：非秘密 profile 编辑/选择/删除、完整 HTTPS endpoint 与 model 校验、Key 替换/删除、显式固定短句连接测试。保存和连接测试不自动启用 AI。
- `FeaturePreferencesCoordinator.swift`：Features 内部的共享偏好写入协调器；两个 ViewModel 必须注入同一实例，串行完成读取最新值、字段合并和保存，避免跨页面整份覆盖旧快照。
- `SubtitleSettings/SubtitleSettingsView.swift`：1～10 段、默认 3 段及双语/仅译文入口；只回调 SetupViewModel 更新显示，不重启会话或补译。
- `LiveSubtitleTests/Features/`：七项具名验收及十一项审查回归、独立 doubles；覆盖准备取消/重试、latest-wins 模式与显示、跨 ViewModel 偏好、mutation 串行/部分失败、连接测试归属和安全用户状态。

### 装配接口（均为模块 internal，供 TASK-13 使用）

- `FeaturePreferencesCoordinator(store:)`：`store` 为 `PreferencesStoring`。TASK-13 必须创建同一个 coordinator 并注入下列两个 ViewModel，不能分别创建。
- `SetupViewModel(session:capability:assets:preferences:credentials:)`
  - 参数依次是 `SessionCoordinating`、`CapabilityChecking`、`LanguageAssetManaging`、`FeaturePreferencesCoordinator`、`CredentialStoring`。
- `CloudSettingsViewModel(session:preferences:credentials:connectionTester:)`
  - 参数依次是 `SessionCoordinating`、`FeaturePreferencesCoordinator`、`CredentialStoring`、`ConnectionTesting`。
- `SetupView(viewModel:)`、`CloudSettingsView(viewModel:)`。
- `SubtitleSettingsView(display:onDisplayChange:)`；SetupView 已展示如何回调 `SetupViewModel.updateDisplay(count:style:)`。
- 未修改 `LiveSubtitleApp`；TASK-05 的 `LanguagePreparationHost` 由集成人嵌入。

### 流、取消与资源释放

- Features 不创建新的生产 AsyncStream；只消费 Ports 提供的资源事件和会话状态流，测试 doubles 使用有界缓冲。
- 准备任务支持取消；取消或换语言后同时依靠 Task cancellation 和配置代次阻止旧任务开始采集。语言变化先停止会话、释放语言预留并保存偏好，由用户重新开始。
- ViewModel deinit 取消准备和状态订阅 Task；停止/取消路径释放资源预留。
- profile 选择、保存、删除以及 Key 替换/删除均先 `await cloudProfileWillChange()`，再持久化，最后 `cloudProfileDidChange()`；失败路径也通知 didChange 并保持本地。
- 保存 profile 后重新读取存储返回的 revision，UI 不自行增代；Key 变更通过再次 `saveProfile` 增加 revision。Key 输入替换后清空，SwiftUI 使用 `SecureField`，不写入 CloudProfile 或日志。
- 模式与显示操作分别使用 generation + 串行操作链，await 后只让最新用户意图生效；取消清理完成前不能重新开始，旧准备不能覆盖本地选择。
- Cloud mutation 在 ViewModel 内串行；Key 替换/删除先保存新 profile revision 再执行 Key 操作，删除 profile 先删 Key 再删 profile。部分失败后重读实际状态并明确提示未完全变更，不伪称全部回滚。
- 连接测试要求当前草稿已保存，绑定 generation、profileID、revision 和草稿状态；mutation、新测试或新建配置会取消并失效旧测试，旧结果不能覆盖新上下文。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 基线 `./scripts/verify.sh` | Xcode 27.2；Debug/Release 与 generic simulator App、测试 bundle 编译 | 退出码 0 | 仅编译，不执行行为测试 |
| `bash build/features-host-check.sh` | Swift 6 strict-concurrency + warnings-as-errors；macOS 主机直接编译真实 ViewModel 与 Contracts；七项任务卡具名检查 + 十一项审查回归 | 18/18 通过；最终代码另重复运行 20/20 轮通过 | 不覆盖 iOS SwiftUI 渲染、系统资源或设备行为；脚本与日志位于本机忽略的 `build/` |
| 既有 Session host checks | Swift 6 strict-concurrency；17 项纯逻辑回归 | 17/17 通过 | 不是 iOS 测试执行或 SDK/设备证据 |
| 既有 G0 host checks | Swift 6 strict-concurrency；13 项纯逻辑回归 | 13/13 通过 | 不代表 G0 真机验收通过 |
| 最终 `./scripts/verify.sh` | 文档/plist/scheme 检查；iOS Debug、iOS Release、generic simulator App 和测试 bundle 编译 | 退出码 0，全部 build succeeded | 仅编译，不证明签名、测试执行或 G0 |
| `xcodebuild ... analyze`（generic iOS Simulator） | 本 worktree 独立 `build/analyze` | `ANALYZE SUCCEEDED`；无源码 warning/error | 仅有未使用 AppIntents 的 metadata 跳过提示，不是行为测试 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | 本机 `simctl list runtimes` 为空 | 未执行 | 无可用 iOS 27+ 模拟器运行时；不能提供有效 UDID |
| 任务卡逐项验收 | 七项具名 ViewModel 行为检查，另加十一项竞态/故障回归 | 主机逻辑 18/18 通过 | iOS 测试 target 中的同一批测试尚未实际执行 |
| SwiftUI 手动交互、真实 Keychain/网络/语言资源、真机/G0 | — | 未执行 | 本任务不修改 App 装配；无模拟器，G0 前置报告未完成 |

## 契约请求

- 无。未修改 Contracts、Config、工程、App、共享脚本或其他任务目录。

## 未验证与已知问题

- 没有实际 iOS 测试执行、SwiftUI 交互、真实资源下载、Keychain、连接服务或设备证据；不得将 generic simulator `build-for-testing` 或主机 18/18 写成这些场景已通过。
- G0 尚未通过；本交付不证明采集、识别、翻译、PiP 或十五分钟持续运行可用。
- TASK-13 需完成真实依赖装配、语言准备 host 嵌入、CloudSettings 导航入口、生命周期与系统事件处理，并在有 iOS 27+ 模拟器后执行全量 `scripts/test.sh`。
- 独立只读审查提出 1 项 Critical、6 项 Important，均已添加确定性失败测试并修复，最终 18/18；未进行第二次独立审查。三项 Minor 延后：读取/刷新失败的文案与状态可更准确；配置变更后的“启用 AI”操作可更直接；running 等活跃 phase 的开始按钮仍应禁用，当前由协调器防御重复 start。
