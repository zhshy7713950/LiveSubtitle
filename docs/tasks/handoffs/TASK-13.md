# TASK-13 交接

- 基线 commit：`d0aad669815e4776b25fe5f830f6432192480f97`（fetch 后的 `origin/main`）。原工作目录本地 main 落后且有用户未提交修改，均未搬入或改动。
- 任务分支 / commit：`codex/task-13-integration` / 本交接所属提交。
- 前置报告：TASK-03～12 已合入该 main，已读各任务交接及正式方案 §§5–6、13–15；模块已有单元测试证据，G0 报告仍为未完成。
- 状态：待审查。代码装配和固定输入验收有证据；完整产品验收仍受 G0、真实系统联调及下述前置问题限制。

## 改动

- `AppComposition.swift`：唯一生产依赖图，构造所有真实模块；两个 Features ViewModel 共享同一 `FeaturePreferencesCoordinator`，PiP 与预览共用同一 `SubtitleRenderer` 和 displayLayer。生产构造不调用真实 AI 或启动采集。
- `LiveSubtitleApp.swift`、`AppRootView.swift`：正式字幕/AI 设置标签页、资源准备 `LanguagePreparationHost`、真实显示层预览。先执行首次安装 Keychain 清理，成功后才开放功能；失败仅显示安全文案和重试。返回字幕页重读已保存配置，替换前取消并等待旧准备；已运行的会话不因切页而停止。
- `SystemMonotonicClock.swift`：统一装配层的 uptime 时钟，sleep 响应取消和已经到达的 deadline。注入协调器、分段器、调度器、云适配器及诊断；各模块其他默认时钟仍使用其自身的系统实现。
- `LifecycleAudioSource.swift`：在 MainActor 的采集 start 入口、任何 picker await 之前绑定协调器提供的 sessionID。与通知桥共享 `CaptureLifecycleScope`，不依赖可能延迟/合并的 UI 状态流。锁屏或严重热状态下拒绝新采集；身份仍由协调器唯一生成。
- `LifecycleBridge.swift`：观察 iOS 27 `AVAudioSession.didBecomeInactiveNotification`、受保护数据即将不可用、严重/临界热状态及进入后台。通知仅传 Sendable 事件和原 sessionID；在协调器 actor 内再次检查身份后停止。普通后台不停止；不会解锁后自动重启。
- `LifecyclePiPController.swift`：协调器只消费一个连续流，恢复界面后再次进入后台可为同一 sessionID 重新创建底层 PiP。旧 forwarding Task/取消均检查代次；意外 EOF 转安全失败。复用 Presentation 的 `PiPEventOutput` 有界控制队列，终态可靠交付，避免满缓冲只结束流而遗漏停止。
- `DiagnosticsRecorder.swift`：`DiagnosticsRecording` actor，仅收封闭枚举和数值；输出只由枚举常量、临时随机编号、单调时间及数字组成。内存环最多 256 项，无持久化/上传/自动导出；clearSession 清空并轮换随机编号。生命周期接入阶段、安全故障和可观察到的停止耗时。
- `RuntimePolicy.diagnosticEventLimit = 256`：新增诊断内存上限的唯一初始参数，测试覆盖超过上限后的严格有界性；未更改其他方案参数或 Ports。
- 删除 `ScaffoldView` 和全部 G0 生产 Swift。六个仍被既有 G0 测试引用的支持文件移至 `LiveSubtitleTests/Support/G0`，仅编译进测试 target；删除不再使用的 G0 UI、模型、Speech/PiP 样板。生产没有 G0 可选入口。
- `LiveSubtitleTests/Integration`、`Support/Integration*`：新增 13 项测试。集成使用真实 AudioPipeline、CaptionSegmenter、CaptionStore、TranslationScheduler、AppleLocalTranslator 和 CompatibleChatTranslator；采音/识别后端、渲染/PiP 系统及本地 SDK 翻译会话使用明确的 doubles，云请求全部由隔离 URLProtocol 截获。

### 初始化与装配接口

- `@MainActor AppComposition()`；`bootstrap() async`、`refreshSetup() async`；`AppRootView(composition:)`。
- `SystemMonotonicClock(): MonotonicClock`。
- `DiagnosticsRecorder(clock: any MonotonicClock = SystemMonotonicClock()): DiagnosticsRecording`；`snapshot() -> [DiagnosticSample]` 仅供内存检查，没有用户导出入口。
- `@MainActor CaptureLifecycleScope()`；`LifecycleAudioSource(base:scope:mayStart:): AudioSource`；测试可注入开始条件，生产使用真实锁屏/热状态。
- `@MainActor LifecyclePiPController(base:): PiPControlling`；`resumeAfterRestoration(sessionID:)`。
- `@MainActor LifecycleBridge(session:diagnostics:clock:pip:captureScope:)`；`startObserving()`、`stopObserving()`。生产必须与 LifecycleAudioSource 共享 captureScope。
- `SessionCoordinator.stop(reason:ifSessionID:)` 位于 App 内 extension；身份检查与进入既有停止协议在同一 actor 上完成，没有改写 Session 模块实现。

### 有界、取消与隐私

- PiP 桥复用最多 16 项内部队列、公共 bufferingOldest(1) 的可靠控制输出。非终态同类事件合并，终态优先；不以丢弃最后的失败/关闭事件维持运行。
- 生命周期状态订阅沿用 Ports 的 bufferingNewest(1)，用于观测；系统停止身份由采集入口同步绑定。通知先转自有枚举，不把 Notification/媒体对象跨域。
- 停止调用原协调器协议，测试验证停止后 source 队列时长为零、输入 PCM 与本地会话文字释放、字幕 store/显示清空，旧识别/PiP 回调不影响快速重启。
- 诊断不接收 String、Error、URL、profile、字幕、响应或凭证；样本不含完整 endpoint。端口中的缓冲/队列/分阶段指标可接收，但本次未声称已完成真实设备性能采样或 P95 验收。

## 验证

环境：2026-11-04，Xcode 27.2、Swift 6 完整并发；连接的 iPhone 17 Pro / iOS 27.2。设备标识、个人路径和签名参数不进入交接，原始长日志仅留在忽略的 build/。

| 命令或步骤 | 环境 / 用例数 | 结果 | 限制 |
| --- | --- | --- | --- |
| 基线 `./scripts/verify.sh` | Debug/Release、generic simulator App/测试 bundle | 退出码 0 | 只证明编译 |
| 新增测试先行 RED | 新时钟/诊断/生命周期尚缺失 | 编译按预期失败 | 不把缺类型的编译失败描述为行为执行 |
| PiP 慢消费者/EOF 回归 RED→GREEN | 真机 3 项 | 修复前 2 项失败；修复后 3/3 通过 | 系统 adapter 为 double |
| 状态订阅挂起时锁屏通知 RED→GREEN | 真机 1 项 | 修复前真实失败，采集入口同步绑定后通过 | NotificationCenter 路径真实执行，未物理锁屏 |
| 设置页替换回归 | 入口缺失先编译失败，补实现后真机 2 项 | 2/2 通过 | 取消准备并等待；运行中不停止 |
| 首轮完整真机 `xcodebuild ... test -parallel-testing-enabled NO -only-testing:LiveSubtitleTests` | 192 项 / 27 suites | 191 通过、1 失败 | 既有 `TranslationSchedulerTests.testQueueOverflowAtDeadline` 断言 fallback 数量失败；不隐去该结果 |
| 单项筛选尝试 | 调度测试函数名称筛选 | 未匹配到测试，执行 0 项 | **不计为通过证据**，随后改套件筛选 |
| 调度套件单独复核 | 6 项 / 1 suite | 6/6 实际执行通过 | 既有失败未复现，未修改其源码/测试 |
| 最终全量真机 `xcodebuild ... test -parallel-testing-enabled NO -only-testing:LiveSubtitleTests` | 192 项 / 27 suites | 全部实际执行通过，0 跳过；TEST SUCCEEDED | 固定文本/合成 PCM/本地响应，不代表完整真实媒体链路 |
| 最终 `./scripts/verify.sh` | 文档/plist/scheme、iOS Debug、Release、generic simulator App/测试 bundle | 退出码 0，三种 build 全成功 | 不等于行为执行；无源码 warning，仅未使用 AppIntents 的 metadata 提示 |
| `xcrun simctl list devices available`、`list runtimes` | 无 runtime、无可用 simulator UDID | 无可执行目标 | 不能编造 UDID |
| `./scripts/test.sh '' -only-testing:LiveSubtitleTests` | 无有效 simulator UDID | 脚本参数校验返回 usage，未执行行为测试 | 仍欠模拟器 scripts/test.sh 全量执行 |
| `codesign --verify --deep --strict`、`devicectl install app`、`process launch --terminate-existing --activate` | 最终已签名 Debug App | 三项命令成功，正式 bundle 进程前台启动 | 只证明签名/安装/进程启动，不证明 UI 人工验收 |
| `git diff --check` | 最终差异 | 无空白错误 | — |

### 任务卡五项验收

- `testLocalModeHasNoSubtitleNetworkTraffic`：真实 scheduler/local/cloud 组合下固定字幕本地完成，URLProtocol 请求数为 0；开始前资源 blocker 阻止 source/PiP start。
- `testWholeStopAndRapidRestart`：合成 PCM 经过真实 AudioPipeline，停止后 PCM/文字/store/显示清空；旧流错误和关闭不串新会话，本地路径无新增网络请求。
- `testLiveDisplayAndProfileChange`：显示设置不重启采集；Key/profile revision/endpoint 变更屏障后只本地；显式启用 AI 后才对后续段向新地址发请求，不重发保留段。
- `testResourceAndPiPFailuresStopSafely`：本地翻译/识别失败、真实 AudioPipeline 的采集撤销控制、PiP 失败/替换及作用域内锁屏/中断/过热停止。
- `testDiagnosticsHaveNoContent`：经过固定字幕链路后诊断检查无原文/译文/测试凭证/endpoint；保留安全类别、时间和数量，256 项上限及 clearSession 生效。

## 审查与修复

- 使用 `superpowers:requesting-code-review` 进行一次独立只读审查。PiP 控制终态、通知身份缓存、旧 Setup 准备任务三项均在本任务 App 范围修复并回归；未进行第二轮独立复审。
- 最终另作自查，收紧旧 PiP 消费者 onCancel 的异步代次检查，且最终 192 项全量回归通过。
- 既有调度波动的源码证据：测试只等待 failed 被 collector 接收，随后立即断言下一条 fallback 已到达；生产将二者按顺序但分别放入异步输出。这可以解释首轮现象，尚未证明唯一原因。建议 TASK-10 owner 等待 fallback 的消费条件再作精确数量断言；本任务未越界修改。

## 契约与前置修复请求

1. 沿用 TASK-03 的 `CaptionStoring.remove(segmentID:)` 请求：当前协调器处理 remove 只维护保留索引，store 无删除端口。需由 Contracts/Session/Captions 所有者联动实现和测试，不能用 App 适配器隐藏缺口。本任务未改变 Ports 或其他任务源码。
2. 待核对 TASK-03 启动中停止：`performStop` 先 await startupTask，再调用 source.stop；beginStop 未取消 startupTask。共享选择器若仍等待用户，可能使停止等到用户结束选择器。应先失效、取消/释放 pending capture，再等待启动退出。此项为源码审查发现，本次没有新增设备交互验证；不把已运行状态的 stop 测试外推到这一场景。
3. TASK-11 的真实 PiP `isPossible` 首次检查、系统恢复 completion 时机和 replaced 分类仍需设备联调。本任务通过可见层挂载与连续事件桥装配，未越界改 Presentation 私有系统适配器。

## 未验证与已知问题

- G0 未完成；未操作本次正式 UI 的真实共享确认、Chrome 多站点声音、真实连续识别/翻译、PiP 启动/关闭/恢复/替换、锁屏/来电、严重过热或十五分钟后台链路。保持产品未验收状态。
- 没有 iOS 模拟器 runtime，因此 scripts/test.sh 全量执行仍未完成；模拟器测试 bundle 编译与真机 192 项实际执行分别列证。
- 真机测试期间系统 Translation 能力查询偶有 XPC/语言不可用消息，并出现 Setup Picker 当前选择不在 capability 返回列表中的系统提示；Features 的空能力列表展示需其 owner 核对。没有据此扩大语言支持声明。
- 诊断当前用于无内容状态/故障观测，没有真实延迟、内存、缓冲及 P95 的设备测量证据；这些属于 TASK-14 设备验收。
- 原工作目录未提交的工程格式修改和 .claude 内容保持原状。未推送、未创建 PR、未合并任何分支；独立 worktree 保留供审查。
