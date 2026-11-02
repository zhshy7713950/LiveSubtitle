# TASK-02：G0 真机链路报告

日期：2026-11-02。**状态：未完成；G0 尚未通过。** 临时探针已编译、签名、安装并由设备命令成功启动。用户本轮暂不能配合十五分钟 Chrome 播放测试，因此没有采音、识别、翻译、后台 PiP 或持续运行的通过证据。

基线：`bdee362f6ca5c86e2c567162a7635b5631a4e25b`（冻结框架 main）。分支：`codex/task-02-g0`，独立 worktree。TASK-01 的前置报告位于该任务提交 `199f40b` 的 `docs/reports/platform-baseline.md`；本任务未合并其分支或复制改写其报告。源码 commit 见本报告所属提交。

## 环境

| 项目 | 核对结果 |
| --- | --- |
| 构建配置 | 真机 Debug 启用 G0；Release 和模拟器显示原空壳 |
| Xcode / SDK / macOS | 27.2（27B52）/ iPhoneOS 与 Simulator SDK 27.2 / macOS 26.7.1（25G241）；工具基线承接 TASK-01，本轮用上述 SDK 编译 |
| iPhone | 实时设备列表：iPhone 17 Pro（iPhone18,1），USB connected；iOS 27.2（24B119）及开发者模式 enabled 见 TASK-01 实时详情 |
| Chrome | TASK-01 实测 version 156.8078.54 / bundleVersion 156.0.8078.54；本轮未重新查询版本 |
| 签名 / 安装 / 启动 | Personal Team 开发签名；最终签名构建、严格签名校验、devicectl 安装、启动退出码均为 0 |
| 语言对 | 固定英文 → 简体中文，标识 en / zh-Hans |
| 识别 / 翻译模型 | 尚未在新入口执行前台准备；是否已安装未知，不把 API 编译当作模型就绪 |
| 测试素材 | 待用户选择无敏感内容的英文公开视频；本轮未播放 |
| 模拟器运行时 | `simctl list runtimes` 为空，无可用于 `scripts/test.sh` 的 iOS 27 模拟器；generic simulator 仍可编译测试 bundle |

## API 核对与探针

代码全部位于 `LiveSubtitle/Validation/G0/`，仅为 Debug 真机 G0 验证，不遵守正式 Ports 冒充模块实现。用户已明确授权本任务兼任临时集成人，只接通 Debug App 入口及必要配置；实际没有提交 Config、工程或 Contracts 修改。

- **全屏选择器**：使用 `SCContentSharingPicker.shared`，设置 `showsMicrophoneControl = false`、`showsCameraControl = false`，注册 observer、激活后 `present()`。没有调用只捕获本 App 的 `presentForCurrentApplication()`。SDK 的 `allowedPickerModes` 在 iOS 不可用，因此没有照搬 macOS 配置。
- **SCStream 音频**：返回 filter 后创建流，`capturesAudio = true`、`excludesCurrentProcessAudio = true`，只注册 `.audio` 输出。读取实际 PCM 格式，使用 iOS 27 的 `AVAudioFormat(formatDescription:)`，同步复制成自有 Data 后进入两秒预算队列；不持有回调交付的媒体缓冲，不注册录屏、麦克风或相机输出。是否能仅注册 audio 输出持续收到 Chrome 音频仍待真机验证。
- **后台与混音**：沿用现有 `screen-capture` / `audio` background modes，不添加特殊 entitlement。使用 playback / moviePlayback / mixWithOthers 音频会话，无麦克风权限、无静音音频保活。Chrome 是否正常出声及后台推理是否可持续均未验证。
- **Speech**：按设备能力选择 SpeechTranscriber，必要时才使用设备实际支持的 DictationTranscriber；启用 `volatileResults` / `audioTimeRange`。AssetInventory 查询、预留与下载在用户点准备后执行；nil installation request 视为可能无需安装，并重新查询 installed。最佳输入格式由 SpeechAnalyzer 查询，使用 SDK `AnalyzerInputConverter` 转换。SDK `start(inputSequence:)` 明确返回立即，输入为自有拉取 AsyncSequence，没有额外 AsyncStream 音频队列或每缓冲 Task。
- **输入所有权**：队列和应用持有的转换 / 在途音频共用 `RuntimePolicy.audioBufferDuration` 两秒预算；识别器下一次请求且转换输出用尽后才返还预算。溢出、非法样本、明显 PTS 不连续会明确结束 G0，不能靠反复丢弃掩盖积压。媒体 PTS 归零后用于连续识别；宿主时长单独用单调时间计量，本轮没有端到端延迟测量。
- **Translation**：前台 `.translationTask` 调用 `prepareTranslation()` 并重新查 installed，非 UI 任务使用 `TranslationSession(installedSource:target:)`。系统会话留在创建它的任务中，不跨 actor 存储或传递；每项本地翻译独占会话，结束时 cancel，只返回有界字符串。
- **PiP / Receiver**：`AVSampleBufferDisplayLayer` + sample-buffer PiP content source，使用 `AVSampleBufferRenderSynchronizer.sampleBufferReceiver(adding:)` 和 `Receiver.enqueueImmediately(CMReadySampleBuffer)`。字幕由 CoreText / CoreGraphics 生成内存帧；像素访问完成后才移交所有权。G0 以 1 fps 刷新，低于 RuntimePolicy 上限。检查 supported / possible 和代理开始结果；帧入队数不等于肉眼可见 PiP 证据。
- **会话与停止**：G0RunState actor 分配身份并管理有界段 / 翻译队列；每个 SDK/UI 回调先检查作用域。翻译结果检查当前作业、段版本及 deadline；到截止点明确返回 expired / deadlineExceeded，主动取消或旧结果不冒充本地故障。停止先失效身份，取消并等待启动 / 准备 / 翻译任务，结束 Speech，停止采集与 PiP，清空文字并释放本轮同步器和自己取得的 locale reservation。关闭与恢复 PiP 使用不同事件；锁屏、中断、后台无 PiP 走停止。上述系统场景尚未实测。

本机 **iPhoneSimulator SDK 不含 ScreenCaptureKit 模块**。六个 SDK/UI 探针及临时入口限定为 `DEBUG && !targetEnvironment(simulator)`，纯逻辑 G0RunState / G0AudioInbox 仍参与模拟器测试编译；未增加假成功采集器。Release 不含 G0 实现。

## 验证命令与证据

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 最终 `./scripts/verify.sh` | 退出码 0 | 文档 / plist / 工程检查、iOS Debug、iOS Release 和 generic simulator App / 测试 bundle 编译通过 |
| Swift 6 主机纯逻辑检查 | 8 项执行通过 | 自有队列与调度逻辑；不执行 iOS SDK / 模型 / 媒体路径 |
| `scripts/test.sh <UDID>` | 未执行 | 无模拟器运行时；测试 bundle 编译成功不等于 iOS 测试执行 |
| 最终真机 Debug 签名构建 | 退出码 0，BUILD SUCCEEDED | 本机忽略的 Local.xcconfig，未提交 Team、证书、profile 或 App 包 |
| `codesign --verify --deep --strict <App>` | 退出码 0 | 本次签名验证 |
| `devicectl device install app` | 退出码 0 | 当前探针版本安装成功 |
| `devicectl device process launch` | 退出码 0 | 启动命令成功；用户尚未确认新 G0 界面或点击准备 / 采集 |
| 独立只读审查与复核 | 已执行 | 修正启动重入、资源准备取消、代次捕获、超时边界与分类、PCM 能量计数；不是运行证据 |

八项主机检查覆盖：排队加在途音频预算、消耗后返还预算、旧采集拒收、停止后旧翻译拒收、原文修订后旧翻译拒收、六秒截止边界及超时分类、四项翻译等待上限、十段保留上限。截止测试推进测试时钟，不真实等待六秒。同一测试源码也作为 iOS Swift Testing 用例参与编译。

复现主机检查：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -D DEBUG -D G0_HOST_CHECK \
  LiveSubtitle/Contracts/Models/*.swift LiveSubtitle/Contracts/Ports/PreparationPorts.swift \
  LiveSubtitle/Contracts/RuntimePolicy.swift LiveSubtitle/Validation/G0/G0RunState.swift \
  LiveSubtitle/Validation/G0/G0AudioInbox.swift LiveSubtitleTests/Validation/G0/G0StateTests.swift \
  -o build/g0-host-checks
./build/g0-host-checks
```

原始编译日志和设备结果仅在本机忽略的 `build/logs/`；不提交个人路径、设备名称 / 标识、Team、签名材料、媒体或转写。没有添加正文日志、网络请求或 AI 配置。

## 分项真机证据

| 项目 | pass/fail/blocked/not-run | 观察 / 无内容指标 |
| --- | --- | --- |
| Chrome 正常出声、有效非静音自有音频 | not-run | 未开始全屏共享，样本格式 / 数量 / 能量未测 |
| 本机连续识别得到可理解文字 | not-run | 资源及真实输入待验证 |
| 本机翻译输出 | not-run | 资源及非 UI 翻译待验证 |
| 返回 Chrome 后 PiP 持续刷新 | not-run | Receiver 编译通过，实际小窗待验证 |
| 连续十五分钟无持续积压 / 进程终止 | blocked | 用户本轮暂不能配合播放；没有有效时长、内存或队列实测值 |
| 用户关闭、恢复 App、系统撤销、锁屏分别清理 | not-run | 已提供相应路径，未操作系统场景 |

屏幕上的指标包含采集时长、音频 / 非静音数量、实际输入及识别采样率、原文事件和译文数、视频帧数、音频预算峰值、溢出 / 无效 / 断流、翻译等待峰值 / 旧结果、RSS 起始 / 当前 / 每秒采样峰值与热状态。指标仅在内存中，用户可主动复制不含正文的指标。采集时长不等于 Chrome 后台播放时长，后者须另行记录。

## 待继续的设备步骤

1. 打开手机 LiveSubtitle，确认出现“LiveSubtitle · G0”。点“1. 准备本地资源”，只在前台按系统提示准备英文识别与简体中文翻译模型；失败时记录安全状态文字，不上传内容或改走云识别。
2. 点“2. 开始全屏共享”，在系统界面授权整个屏幕。开始后点“3. 开启字幕小窗”，确认小窗真实出现；未就绪可在前台稍后重试，不把调用成功当作小窗已显示。
3. 切到 Chrome 播放无敏感英文语音，分别确认正常出声、有非静音样本、有可理解原文、有本地译文、有持续刷新的 PiP。任一失败记录当时无内容指标，不写完整链路通过。
4. 从实际 Chrome 后台播放开始计时，持续至少十五分钟。结束后复制无内容指标，记录真实播放时长、最大队列、输入丢弃 / 断流、RSS 及热状态；持续积压视为失败。
5. 每轮重新准备并开始，分别测试用户关闭 PiP、恢复 App 后重新打开 PiP、系统撤销共享、锁屏及 App 停止按钮。确认停止清空文字、不再发起新作业，旧回调不影响下一轮。
6. 把真实指标和结论补入本报告，满足全部 G0 要求后才能启动 TASK-03～12 的正式模块扩展。

## 结论与契约请求

**G0：未完成，不能写 pass。** 目前只证明本机 SDK 探针可编译、可签名安装并由设备命令启动，及八项自有逻辑边界执行通过。没有发现已实测的平台能力失败，因为媒体链路尚未执行。

无 Contracts 变更请求。临时 App 入口经用户授权；TASK-13 须移除该入口并清理 G0 样板。若真机暴露额外 entitlement、后台推理或采集配置限制，先记录证据并由集成人修订，不切换旧系统路线、不新增广播扩展、不上传声音。

参考：[Apple iOS 采集示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、[SpeechAnalyzer.start](https://developer.apple.com/documentation/speech/speechanalyzer/start(inputsequence:))、[AVSampleBufferVideoRenderer.Receiver](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver)；具体可用签名已与本机 iOS 27.2 SDK 和 Swift 6 编译结果交叉核对。
