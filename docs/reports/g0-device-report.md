# TASK-02：G0 真机链路报告

日期：2026-11-02。**状态：未完成；G0 尚未通过。** 用户已确认一次字幕测试成功，提供的小窗截图可见原文与本地译文；不保存截图或正文。共享回调崩溃与音频时间重叠已修复。最新真机回归实际执行 16 项通过、2 项模型条件测试跳过；上一轮 17 项全部执行通过并取得合成短句耗时。十五分钟稳定性、Chrome 后台持续刷新与生命周期仍未完成。

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
| 识别 / 翻译模型 | 本次真机实际完成准备：系统下载英语（美国）及简体中文翻译资源，installed / 非 UI 会话 isReady 检查返回，随后英文 SpeechTranscriber 资源及输入格式检查通过；另有用户本轮原文 / 译文小窗观察证据，持续性仍需验证 |
| 测试素材 | 用户已进行一次字幕测试并确认成功；未提供网站、精确播放时长或无内容指标，不记录其字幕内容 |
| 模拟器运行时 | `simctl list runtimes` 为空，无可用于 `scripts/test.sh` 的 iOS 27 模拟器；generic simulator 仍可编译测试 bundle |

## API 核对与探针

代码全部位于 `LiveSubtitle/Validation/G0/`，仅为 Debug 真机 G0 验证，不遵守正式 Ports 冒充模块实现。用户已明确授权本任务兼任临时集成人，只接通 Debug App 入口及必要配置；实际没有提交 Config、工程或 Contracts 修改。

- **全屏选择器**：使用 `SCContentSharingPicker.shared`，设置 `showsMicrophoneControl = false`、`showsCameraControl = false`，注册 observer、激活后 `present()`。没有调用只捕获本 App 的 `presentForCurrentApplication()`。SDK 的 `allowedPickerModes` 在 iOS 不可用，因此没有照搬 macOS 配置。
- **SCStream 音频**：返回 filter 后创建流，`capturesAudio = true`、`excludesCurrentProcessAudio = true`，只注册 `.audio` 输出。读取实际 PCM 格式，使用 iOS 27 的 `AVAudioFormat(formatDescription:)`，同步复制成自有 Data 后进入两秒预算队列；不持有回调交付的媒体缓冲，不注册录屏、麦克风或相机输出。已有用户字幕链路成功反馈；Chrome 非静音计数和持续运行指标仍待核对。
- **后台与混音**：沿用现有 `screen-capture` / `audio` background modes，不添加特殊 entitlement。使用 playback / moviePlayback / mixWithOthers 音频会话，无麦克风权限、无静音音频保活。用户本轮确认字幕测试成功；Chrome 出声、后台持续时长及内存队列仍未逐项记录。
- **Speech**：按设备能力选择 SpeechTranscriber，必要时才使用设备实际支持的 DictationTranscriber；启用 `volatileResults` / `audioTimeRange`。AssetInventory 查询、预留与下载在用户点准备后执行；nil installation request 视为可能无需安装，并重新查询 installed。最佳输入格式由 SpeechAnalyzer 查询，使用 SDK `AnalyzerInputConverter` 转换。SDK `start(inputSequence:)` 明确返回立即，输入为自有拉取 AsyncSequence，没有额外 AsyncStream 音频队列或每缓冲 Task。
- **输入所有权**：队列和应用持有的转换 / 在途音频共用 `RuntimePolicy.audioBufferDuration` 两秒预算；识别器下一次请求且转换输出用尽后才返还预算。溢出、非法样本、明显 PTS 不连续会明确结束 G0，不能靠反复丢弃掩盖积压。保留原始 PTS 作断流检查及映射，以首个 PTS 为锚，识别样本时钟按实际 PCM 帧数连续推进；宿主时长另用单调时间，本轮没有端到端延迟测量。
- **Translation**：前台 `.translationTask` 调用 `prepareTranslation()` 并重新查 installed，前台配置、LanguageAvailability 和非 UI `TranslationSession(installedSource:target:preferredStrategy:)` 均选择 `.lowLatency`。系统会话留在创建它的任务中，不跨 actor 存储或传递；每项本地翻译独占会话，结束时 cancel，只返回有界字符串。
- **PiP / Receiver**：`AVSampleBufferDisplayLayer` + sample-buffer PiP content source，使用 `AVSampleBufferRenderSynchronizer.sampleBufferReceiver(adding:)` 和 `Receiver.enqueueImmediately(CMReadySampleBuffer)`。字幕由 CoreText / CoreGraphics 生成内存帧；像素访问完成后才移交所有权。G0 在文字变化时按 RuntimePolicy.maximumRenderFPS（当前 10）限频刷新，不变文字保留约 1 fps 心跳；移除原每秒刷新造成的额外显示等待。检查 supported / possible 和代理开始结果；帧入队数不等于肉眼可见 PiP 证据。
- **会话与停止**：G0RunState actor 分配身份并管理有界段 / 翻译队列；每个 SDK/UI 回调先检查作用域。翻译结果检查当前作业、段版本及 deadline；到截止点明确返回 expired / deadlineExceeded，主动取消或旧结果不冒充本地故障。停止先失效身份，取消并等待启动 / 准备 / 翻译任务，结束 Speech，停止采集与 PiP，清空文字并释放本轮同步器和自己取得的 locale reservation。关闭与恢复 PiP 使用不同事件；锁屏、中断、后台无 PiP 走停止。上述系统场景尚未实测。

本机 **iPhoneSimulator SDK 不含 ScreenCaptureKit 模块**。六个 SDK/UI 探针及临时入口限定为 `DEBUG && !targetEnvironment(simulator)`，纯逻辑 G0RunState / G0AudioInbox 仍参与模拟器测试编译；未增加假成功采集器。Release 不含 G0 实现。

## 验证命令与证据

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 最终 `./scripts/verify.sh` | 退出码 0 | 文档 / plist / 工程检查、iOS Debug、iOS Release 和 generic simulator App / 测试 bundle 编译通过 |
| Swift 6 主机纯逻辑检查 | 13 项执行通过 | 自有队列、调度与有理数样本时钟；不执行 iOS SDK / 模型 / 媒体路径 |
| `scripts/test.sh <UDID>` | 未执行 | 无模拟器运行时；不把 generic simulator 测试编译当作测试执行 |
| 真实 iPhone `xcodebuild ... test` | 退出码 0，18 项发现 / 4 suites，实际执行 16 项通过、2 项跳过 | 13 项纯逻辑、1 项后台 selector 回调、2 项合成 PCM / Speech SDK 交接；模型条件测试因当前会话未 ready 明确跳过。前一轮 17 项全执行通过并完成翻译对照；不是完整 G0 媒体验收 |
| 最终真机 Debug 签名构建 | 退出码 0，BUILD SUCCEEDED | 本机忽略的 Local.xcconfig，未提交 Team、证书、profile 或 App 包 |
| `codesign --verify --deep --strict <App>` | 退出码 0 | 本次签名验证 |
| `devicectl device install app` | 退出码 0 | 当前探针版本安装成功 |
| `devicectl device process launch` | 退出码 0 | Device Hub 已实际观察 G0 界面、翻译下载面板及系统全屏共享选择器 |
| 独立只读审查与复核 | 已执行 | 修正启动重入、资源准备取消、代次捕获、超时边界与分类、PCM 能量计数；不是运行证据 |

十三项主机检查覆盖：偏移时间的同段修订合并、相同最终稿保留译文且不重复请求、离散时间重复话语保留、多临时行合并最终行及旧译文失效，以及有理数 PTS 保留准确样本位置、排队加在途音频预算、消耗后返还预算、旧采集拒收、停止后旧翻译拒收、原文修订后旧翻译拒收、六秒截止边界及超时分类、四项翻译等待上限、十段保留上限。截止测试推进测试时钟，不真实等待六秒。同源用例已在 iPhone Swift Testing 执行。测试日志的 XCTest 空入口会显示 0 tests，但随后的 Swift Testing 有真实逐项执行结果，须另行核对执行及跳过数，不能只据前者误判为零测试。

复现主机检查：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -module-cache-path build/mac-module-cache -D DEBUG -D G0_HOST_CHECK \
  LiveSubtitle/Contracts/Models/*.swift LiveSubtitle/Contracts/Ports/PreparationPorts.swift \
  LiveSubtitle/Contracts/RuntimePolicy.swift LiveSubtitle/Validation/G0/G0RunState.swift \
  LiveSubtitle/Validation/G0/G0AudioInbox.swift LiveSubtitle/Validation/G0/G0AudioTiming.swift \
  LiveSubtitleTests/Validation/G0/G0StateTests.swift \
  -o build/g0-host-checks
./build/g0-host-checks
```

原始编译日志和设备结果仅在本机忽略的 `build/logs/`；不提交个人路径、设备名称 / 标识、Team、签名材料、媒体或转写。没有添加正文日志、网络请求或 AI 配置。

## 分项真机证据

| 项目 | pass/fail/blocked/not-run | 观察 / 无内容指标 |
| --- | --- | --- |
| 翻译 / 英文识别资源准备 | pass | 真机系统下载结束后状态与格式检查返回；已有用户本轮原文 / 译文观察，资源准备本项通过 |
| 系统共享选择结果回调 | pass（此单项） | 修复后正常返回 App，启动采集并收到缓冲，未再发生 selector 的 executor 断言退出 |
| Chrome 正常出声、有效非静音自有音频 | not-run | 已实测收到 5 个自有缓冲，输入 48 kHz / 2 声道，未获得 Chrome 非静音证据；不能只凭 buffer 数判定通过 |
| 本机识别得到可理解文字 | pass（用户观察，短轮） | 用户确认测试成功，提供的小窗截图可见原文；不据此推断十五分钟连续识别 |
| 本机翻译输出 | pass（用户观察，短轮） | 用户截图可见与原文对应的本地译文；同时指出重复与延迟，已进行交互修正，修正版待视频复测 |
| PiP 显示 / 返回 Chrome 后持续刷新 | 部分观察，持续性 not-run | 用户已提供字幕小窗截图；Chrome 后台持续刷新时长、关闭 / 恢复场景尚未独立核对 |
| 连续十五分钟无持续积压 / 进程终止 | not-run | 用户已完成一次短轮测试，但没有十五分钟播放时长、内存或队列实测值 |
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

**G0：未完成，不能写 pass。** 已有资源准备、系统共享入口、自有音频缓冲以及用户原文 / 译文 / 小窗的短轮观察证据；原共享确认回调发生实现层崩溃，不能把它当作平台不支持的结论。仍需逐项核对 Chrome 有效采音指标、后台 PiP 持续刷新、生命周期及十五分钟运行；本轮交互修正不能替代这些验收。

## 字幕交互与翻译延迟续修

- 用户本轮指出待译占位、同句重复与本地翻译慢。主页面及 PiP 移除“本地翻译中”占位：待译只显示一次原文，译文就绪后在同一行组显示译文与原文。
- SDK volatile / final 结果此前仅按起始毫秒分行，起点修订或多个临时片段合成一个最终范围时可能留下重复。G0 现在携带完整音频范围，对至少覆盖较短范围 80% 的修订保留稳定行标识，清理被覆盖的临时行和等待作业；已最终确定的行另检查正文前缀 / 包含关系。没有仅按文本全局去重，离散时间重复说同一句仍分开显示。这只是 G0 范围协调，不冒充 TASK-06 的完整分段实现。
- 新增四项回归先失败后通过，包含偏移修订、多旧行合并及迟到译文拒收；既有代次、版本、截止、队列与保留上限不变。独立只读审查发现多行合并遗漏后已修正并复核。
- 资源准备和实际翻译统一使用 SDK 低延迟策略，仍只使用已安装资源，每个作业的非 Sendable 会话留在本任务并在结束时 cancel；没有上传或云回退。PiP 文字变更刷新从约 1 秒改为当前参数下约 100 毫秒轮询；这是显示等待上界，不是模型耗时承诺。
- 一轮合成短句真机对照（每种 3 条，交替顺序，包含会话创建 / isReady / translate）测得热态中位耗时默认 0.034 秒、lowLatency 0.025 秒，最大 0.041 / 0.033 秒；单独首条 lowLatency 检查耗时约 0.543 秒。样本很小且已有热缓存，不代表真实音视频端到端延迟或持续速度提升。
- 翻译测试首轮默认会话未 ready 并返回 notInstalled，真实失败已保留本机；后续完整对照 17 项均执行通过。最终含多行合并回归的一轮发现 18 项：16 项执行通过，2 项翻译测试因就绪条件未满足明确跳过。不能把跳过写作模型验证通过；不在测试中静默下载资源。
- 无内容指标增加成功应用译文的最近 / 峰值耗时及最近排队时间，明确标作“有效译文耗时”；不统计旧结果 / 故障任务，不是端到端延迟。修正版已重新编译、签名校验、安装启动，仍需用户播放同一类视频确认重复消失及体感延迟。

## 资源准备等待与共享崩溃定位

- 用户报告“准备本地资源”持续转圈。只增加无内容阶段标记后在同一真机复现：系统翻译任务实际开始，显示英语（美国）和简体中文下载面板；约 72 秒后 `prepareTranslation()` 返回，installed / isReady 检查返回，随后 SpeechTranscriber 资源检查完成。原通用状态文字无法区分系统下载和识别准备，已改成逐阶段显示。此次没有复现持续死锁，不把此前没有可见面板的具体原因写成已证实。
- 用户随后确认点“共享整个屏幕”仍停在系统面板。进程查询发现 App 已退出；仅获取本 App 一份最新崩溃诊断，本地符号栈为 `EXC_BREAKPOINT / SIGTRAP` → `_dispatch_assert_queue_fail` → Swift executor 检查 → `G0CaptureProbe.contentSharingPicker(_:didUpdateWith:for:)`，来自 ScreenCaptureKit / ReplayKit 的后台 XPC 回调。根因是旧 `@MainActor` + `@preconcurrency` observer 错误假设回调在主线程。
- 修复采用非隔离 NSObject `G0CaptureCore` 实现系统 observer，以 NSLock 保护 SDK 控制状态。SDK filter / stream 保留在此所有权岛中，不进入 Task 或 actor，不声明 Sendable。MainActor 只负责选择器显示及处理 Sendable 值事件；start / stop completion 只捕获值回调，取消后仍先完成 SDK 收尾再过滤 UI 事件。没有使用 `@unchecked Sendable`、`nonisolated(unsafe)` 或兼容导入掩盖隔离问题。
- 回归用例先确认旧桥接不能从后台调用；新增真机测试在后台任务内创建实际 observer、触发协议错误回调并验证值事件送回 MainActor。测试构建通过不替代共享确认后进程存活及真实音频验证。
- 共享回调修复后，实际收到 5 个音频缓冲，识别结果流抛 `SFSpeechErrorDomain#17`。已确认不匹配公开的 `cannotConfigureAudioSystem`，没有据数字擅自增加权限或调整音频类别。独立的 80 ms 合成静音 / 连续整数样本时钟 fixture 在 iPhone 通过；使用原生产 PTS 浮点换算的同样输入则复现错误 17，其纯合成错误信息明确是音频输入时间戳重叠或倒退。
- 首先确认大 PTS 经 Double 相减再截断，会把连续 16 ms / 768 帧变成 767 帧；有理数换算修复了这一误差。但真实采集仍出现重叠：首批每包 960 帧 / 48 kHz，约 0.68 秒处新输入开始 `32639/48000`，前一输入结束 `10880/16000`，差一帧。可见采集时间域与 PCM 采样时钟还存在微小偏差，不能把每次 PTS 重算当作连续 PCM 的输入时钟。
- 最终 `G0AudioTiming` 保留 `CMTimeSubtract` / `CMTimeConvertScale` 得出的采集位置作映射和偏差观测，识别输入位置按每包实际 `frameCount` 累加；没有丢弃、重排或重用音频。校验采样率稳定、timescale / 数值、非负位置与帧数溢出；每次开始重置锚点。既有原始 PTS 断流检查仍保留，新增偏差峰值（源采样率帧数）供实测核对。
- 修复前主机回归因一帧偏差失败；iPhone 整数时钟 fixture pass、原浮点映射 fixture fail。有理数换算后，精确 PTS fixture pass，但加入实测同类的一帧采集时钟偏差又复现相同错误 17。最终连续 PCM 时钟使所有这些场景通过，该阶段真机 12 项全部执行通过。合成夹具只有新建的静音 PCM，不使用用户媒体；后续用户已提供原文、译文小窗观察，十五分钟持续运行仍须独立验收。
- 原始崩溃诊断只留在忽略的本机 `build/logs/`，不提交设备标识、地址或全文。阶段日志仅含固定状态、错误码及是否接受该代次，不含内容、Key 或实际 UUID。

无 Contracts 变更请求。临时 App 入口经用户授权；TASK-13 须移除该入口并清理 G0 样板。若真机暴露额外 entitlement、后台推理或采集配置限制，先记录证据并由集成人修订，不切换旧系统路线、不新增广播扩展、不上传声音。

参考：[Apple iOS 采集示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、[SpeechAnalyzer.start](https://developer.apple.com/documentation/speech/speechanalyzer/start(inputsequence:))、[AVSampleBufferVideoRenderer.Receiver](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver)；具体可用签名已与本机 iOS 27.2 SDK 和 Swift 6 编译结果交叉核对。
