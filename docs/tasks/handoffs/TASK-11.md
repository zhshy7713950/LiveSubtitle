# TASK-11 交接

- 基线 commit：`cb1cd6580350b0d8960aa1963410e04461732864`（`origin/main`）。
- 任务分支 / commit：`worktree-task-11-presentation`；实现、测试与本交接见本交接所属提交及后续审查修正提交。
- 前置报告：`docs/reports/g0-device-report.md` 仍标记 G0 未完成；本任务按明确指派使用固定 Contracts 和任务内 doubles 独立实现，不据此宣称完整链路或真机能力通过。
- 状态：待审查。

## 改动

- `LiveSubtitle/Presentation/SubtitleLayout.swift`：CoreText 按实际尺寸换行；译文突出、双语保留次要原文、仅译文不显示原文。空间不足优先保留最新段，不为塞入旧段无限缩字；覆盖中文长句、组合 emoji、显式换行和零尺寸。
- `SubtitleRenderer.swift`：实现 `@MainActor SubtitleRenderer: SubtitleRendering`。显示段数、样式和 PiP 尺寸变化只重排当前快照；最多 10 fps，待绘工作只有最新快照，未变化内容及重复快照约 1 秒心跳，视频 PTS 严格单调。renderer 由 PiP 绑定活动 sessionID，停止后或新会话中的迟到旧快照直接拒收。clear 取消旧工作并串行 flush；渲染失败显式上报，心跳不强持有 renderer。
- 生产帧使用自有 BGRA pixel buffer；Sendable 布局输入由单个 actor 构建器串行完成 CoreText 布局和像素／sample 创建，再将 `CMReadySampleBuffer` 交给 MainActor 的 iOS 27 Receiver `enqueueImmediately`。计算期间的新快照只保留最新一份，旧计算按 workID 丢弃。没有 `@unchecked Sendable`、媒体落盘或旧 enqueue 样板。
- Receiver 仅在首帧或 flush 后恢复时建立一次时间轴，后续帧不再把 synchronizer 时间重设为零。
- `PiPCoordinator.swift`：实现 `@MainActor PiPCoordinator: PiPControlling`。分别检查 supported／possible，处理异步启动失败、显式关闭、恢复界面、同会话重新启动和系统替换；旧 adapter 回调按对象及 generation 隔离，错误 sessionID 的 stop 不影响新会话。
- AVKit 适配器实现完整 sample-buffer playback delegate，使用 `isPictureInPictureSuspended` 及 stopped 回调识别替换；render-size 回调只更新布局。失败、关闭和替换均停止 PiP 并清理字幕帧，由既有 Session 消费事件结束采集和翻译。
- `LiveSubtitleTests/Presentation/`：五项任务卡具名验收及十一项边界检查，共 16 项同源行为测试；fake clock 不做真实等待，系统 adapter、帧输出与串行构建器 doubles 均在本任务测试目录。

## 类型与装配

- `SubtitleRenderer()`：MainActor 生产构造；`renderer.displayLayer` 是交给 PiP 的同一显示层。TASK-13 将 renderer 同时作为 `SubtitleRendering` 和 PiP 构造依赖。
- `PiPCoordinator(renderer: SubtitleRenderer)`：MainActor 生产构造，内部连接 renderer 的失败回调和 displayLayer。
- `SubtitleRenderer(output:clock:builder:renderSize:)`、`PiPCoordinator(renderer:systemFactory:)` 为模块内部测试注入点，不要求 TASK-13 使用。
- `activate(sessionID:)`／`deactivate(sessionID:)` 由 PiPCoordinator 绑定和解绑当前会话；`updateRenderSize(_:)` 由系统适配器调用；`waitForClear()` 用于 PiP stop 等待串行清理。公共 Contracts 无变化。

## 流、上限与取消

- 渲染只有一个待绘 snapshot 和一个可取消调度任务；新快照覆盖旧待绘工作，不按中间版本排队视频帧。布局和像素由单个 actor 构建器串行执行，计算中到达的新输入不会启动额外构建器。新内容在旧 flush 完成后才能入队，避免清帧串代。
- PiP 事件内部队列最多 16 项，AsyncStream 显式使用 `.bufferingOldest(1)`；yield dropped 时保留原事件并重试。同类非终态回调合并，队列饱和时优先交付终态；terminal 事件在剩余事件排空后结束流，主动 stop 立即失效并结束。
- renderer／PiP adapter／事件输出回调均避免强引用循环；旧 session 停止和晚到回调不能关闭新 output。
- 字幕文字仅用于内存布局和像素帧；没有正文日志、网络、历史、导出或持久化。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 修改前 `./scripts/verify.sh` | 基线 `cb1cd65` | 退出码 0 | 仅基线编译检查 |
| TASK-11 RED→GREEN | Swift 6 完整并发、warnings-as-errors | 布局、renderer、PiP 分别因缺少实现失败；审查新增时间轴、重复快照、旧会话准入和串行构建器用例也先失败后通过；iOS sample 隔离和 NSObject 初始化编译错误修正后通过 | 保留红绿证据 |
| `TASK11_HOST_CHECK` 同源行为检查 | 16 项 | 全部通过；另连续 100 轮全部通过 | 不执行真实 AVKit／设备行为 |
| 同一 host checks，`-sanitize=address` | 16 项 | 全部通过，退出码 0 | 不包含真实媒体对象 |
| 同一 host checks，`-sanitize=thread` | 16 项 | 全部通过，退出码 0 | 不包含真实媒体对象 |
| 既有 TASK-04／06／10 host checks | 21 + 28 + 16 项 | 全部通过；TASK-04 在一次并行负载运行中出现 consumerCancellation 失败，随后单独复跑及连续 20 轮均通过 | 未修改该模块，保留此次波动记录 |
| 既有 G0 host checks | 13 项 | 全部通过 | 不替代 G0 真机链路 |
| 最终 `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0；文档、plist、iOS Debug、Release、generic simulator App 与测试 bundle 编译通过 | 不执行行为测试 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list devices available` 为空 | 未执行 | 无可用 iOS 27 模拟器；不以测试 bundle 编译代替测试执行 |
| 真机 `xcodebuild ... test -only-testing:` 两个 Presentation 套件 | iOS 27.2 / Xcode 27.2；2 suites／16 tests | 16 项实际执行通过，0 跳过 | 测试 target 行为证据，不等同真实 PiP 界面验收 |
| 真机 `xcodebuild ... -parallel-testing-enabled NO -only-testing:LiveSubtitleTests test` | 同一设备；20 suites／161 tests | 161 项实际执行通过，0 失败、0 跳过 | 默认并行下 Cloud `testProvisionalThrottle` 曾失败，单项及禁用并行后的全量均通过 |
| 任务卡逐项验收 | 固定 snapshot、fake clock、系统 doubles 及真机测试 target | 五项具名验收均有主机及真机行为证据，另有十一项边界回归 | 真实设备 PiP 界面与 Chrome 链路未验证 |

主机复现命令：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path build/task11/module-cache -D TASK11_HOST_CHECK \
  LiveSubtitle/Contracts/Models/*.swift LiveSubtitle/Contracts/Ports/*.swift \
  LiveSubtitle/Contracts/RuntimePolicy.swift LiveSubtitle/Presentation/*.swift \
  LiveSubtitleTests/Presentation/*.swift -o build/task11/task11-host-checks
./build/task11/task11-host-checks
```

## 独立审查与修复

- fresh reviewer 初审为 No：1 项 Critical 为每帧重设 synchronizer 时间轴；3 项 Important 为重复快照持续重绘、旧会话快照缺少准入、布局／像素同步占用 MainActor。四项均新增失败测试后修复，最终 16 项同源检查、100 轮重复运行、ASan／TSan、完整工程检查及真机 161 项测试通过。
- 暂缓 Minor：慢消费者下 PiP 事件输出会以 `Task.yield` 重试 dropped，内存有界但可能产生调度轮询；后续应改为消费进展显式唤醒。
- 暂缓 Minor：空间严重不足且带状态行时，partial group 的 8 点组间距可能侵入状态行或底部留白；需补短高度布局用例并统一 fitting／positioning 高度计算。
- 设备判断：保留 supported／possible 一次性前置检查，若真机证明 possible 依赖首帧，可能导致启动失败，需在 TASK-14 调整为观察或等待机制。
- 设备判断：恢复请求目前立即 `completion(true)`，若 TASK-13 还需要额外 UI 恢复工作，可能过早完成系统握手，需在联调时核对。
- 设备判断：replaced 同时依赖 suspended KVO 和 didStop 时的状态；若真实回调时序不同，可能误分类关闭／替换，必须保留真机验收。

## 契约请求

- 无。未修改 Contracts、Config、App 装配、工程、scheme、脚本或其他任务实现。

## 未验证与已知问题

- G0 仍未完成；未验证真实 iPhone 上 PiP 启动、恢复、替换、拖动、缩放、Chrome 播放器冲突、后台持续显示或完整停止链路。`isPictureInPictureSuspended` 的真实系统时序必须由 TASK-14 核对。
- 没有模拟器测试 target 执行证据；已有真机 20 suites／161 tests 全部通过的测试 target 证据。真实 Receiver／AVKit 界面、Chrome 采音和完整 G0 仍只有 SDK 编译及固定输入测试证据，未做人工场景验收。
- 默认并行的全量真机运行中，既有 Cloud `testProvisionalThrottle` 出现两次 `throttling dropped final completion`，单独复跑及 Cloud 主机测试通过；使用 `-parallel-testing-enabled NO` 后全量 161 项通过。该跨 suite 并行波动未在本任务修改，集成人后续应核查测试隔离。
- TASK-13 需在 start 抛出或收到 failed／closed／replaced 时沿用 Session 停止协议；恢复界面后再次离开 App 时，可对同一 sessionID 调用 start，保留当前字幕并更换旧 PiP adapter。
- 不把本任务的固定输入、编译和 sanitizer 结果写成 Chrome、双 PiP 或十五分钟后台能力通过。
