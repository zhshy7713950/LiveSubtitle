# TASK-10 交接

- 基线 commit：`4302386fd263ed7a5564c3a186bd8ded856474ff`（`origin/main`）。
- 任务分支 / commit：`worktree-task10`；实现、测试与本交接见本交接所属提交。
- 前置报告：`docs/reports/g0-device-report.md` 仍标记 G0 未完成；本任务按明确指派使用固定 Contracts 和任务内 doubles 独立实现，不据此宣称完整链路或真机能力通过。
- 状态：待审查。

## 改动

- `LiveSubtitle/Translation/Scheduling/TranslationJobQueue.swift`：待执行队列同段只保留最新版本，溢出优先移除最旧项，未开始任务最多 4 个；段淘汰同步清理 job 和版本索引。
- `TranslationScheduler.swift`：实现 `TranslationScheduling`。AI 并发最多 2、本地最多 1；运行中旧版本先取消并保留槽位到任务退出，避免取消期间超并发。
- job 在提交时固定 `createdAt` 和六秒总 deadline，排队及 800 ms 限频等待不重置；AI 实际启动后首文本最多三秒且不越过总 deadline。当前有效作业在队列溢出、启动或回调时到期都产生一次 timeout，迟到成功和旧 identity／revision 错误无副作用。
- 同段 AI 请求至少间隔 800 ms，按实际启动计数最多 2 次 provisional 和 1 次 final；预算耗尽仅该段改用 local job，`cloudProfile=nil`、provider 为 local，不触发全局回退。
- 当前有效 AI 故障发出携带原 job 的 `failed` 及一次 `fallbackRequested`，立即锁定 AI 新任务；仅保留最新候选，协调器通过 `setMode` 增代确认后重新校验保留版本、保留集合和 deadline，再以 local/localFallback 处理。显式恢复 AI 前不因新段自动恢复。
- `start`／`setMode` 校验语言对、profile ID 和 revision；AI job 固定不可变 profile 快照。stop 先关闭入口、失效状态，再取消并等待流；重复 stop 安全，stop 后 setMode 拒绝，旧输出流的取消回调不会停止新会话。本地终端故障取消同代全部工作，只发一次 failed。
- 单段输入防御性限制 120 个用户可见字符；译文上限 800 个用户可见字符，超限按 `.invalidOutput` 处理。
- `LiveSubtitleTests/Translation/Scheduling/`：任务卡八项具名验收，加上时钟下溢、消费者未启动的控制交付、控制保留区饱和、旧流取消 restart、stop 后 setMode、本地故障整代取消、await 期间候选淘汰和 deadline 同刻队列溢出，共 16 项同源行为检查。 fake clock 使用 continuation 按 deadline 唤醒，不真实等待三秒或六秒。

## 类型与装配

- `TranslationScheduler(aiTranslator: any Translator, localTranslator: any Translator, clock: any MonotonicClock = SchedulingSystemClock())`：actor，遵守 `TranslationScheduling`；TASK-13 可只传 AI／local translator 使用默认系统 uptime 时钟。
- `SchedulingSystemClock(nowProvider:)` 为模块内部时钟实现，默认参数使用 `DispatchTime.now().uptimeNanoseconds`；测试可注入两次读取跨 deadline 的序列。
- `TranslationJobQueue(limit: Int = RuntimePolicy.pendingTranslationLimit)` 为模块内部值类型，不改变公共 Contracts。
- `SchedulingEventOutput` 为模块内部有界交付类型；未新增公共模型、密钥、配置或真实服务。

## 流、上限与取消

- 调度输出使用内部最多 64 项队列和 `AsyncStream.bufferingOldest(1)`：最多 56 项数据，给 failed／fallbackRequested 预留 8 项；同 job provisional 合并为最新累计文本。`yield` 返回 dropped 时保留该项并重试，不将 enqueued 误当作慢消费者已处理。
- 数据满时优先淘汰旧 provisional／dropped；控制事件可淘汰数据。控制保留区也满时 `emit` 显式拒绝，调度器关闭当前代次并取消任务，尽可能以 `.unavailable` failed／fallback 结束，不静默继续。
- 每个 job 都有总 deadline 任务；AI 启动后另有首文本任务，限频等待另有 ready 任务。修订、淘汰、回退、setMode 和 stop 都取消对应计时器；setMode／stop 调用两个 translator 的 `cancelAll` 并等待旧 running task。
- 输出 continuation 的取消绑定其所属 output 身份；旧代次回调不能关闭新 output。测试 doubles 全部位于本任务测试目录，流均有显式有界策略。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 修改前 `./scripts/verify.sh` | 基线 `4302386` | 退出码 0 | 基线编译检查，不执行行为测试 |
| `swiftc -warnings-as-errors -swift-version 6 -strict-concurrency=complete -D TASK10_HOST_CHECK ... && ./build/task10/task10-host-checks` | macOS 主机同源检查 | 16 项通过；最终另连续 200 次全量运行通过 | 不证明 iOS SDK、设备或真实服务行为 |
| 同一 host checks，`-sanitize=address` | Swift 6 完整并发检查 | 16 项通过，退出码 0 | 不证明设备行为 |
| 同一 host checks，`-sanitize=thread` | Swift 6 完整并发检查 | 16 项通过，退出码 0 | 不证明设备行为 |
| 既有 TASK-06／TASK-07 host checks | 28 + 8 项 | 全部通过 | 共享基线纯逻辑回归，不替代全量测试 |
| 最终 `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0；文档、plist、iOS Debug、Release、generic simulator App 与测试 bundle 编译通过 | 不执行行为测试 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list devices available` 为空 | 未执行 | 无可用 iOS 模拟器运行时；不以测试 bundle 编译代替测试执行 |
| 真机全量 `xcodebuild ... test -only-testing:LiveSubtitleTests` | 修复前测试版本 | 旧版 TASK-10 多项因 fake clock 并行忙等失败；已停止该次过期运行 | 不是最终源码结果，不据此判定最终用例失败 |
| 最终源码真机重试 | 最终十六项版本 | 未执行 | 重试时设备已不在可用 destination 中，xcodebuild 退出码 70；没有最终真机行为证据 |
| 任务卡逐项验收 | 固定 doubles / fake clock | 八项具名验收均有主机行为证据；另加八项对抗性回归 | 最终模拟器／真机全量行为测试未执行 |
| 独立只读审查及修复回归 | 全任务新文件 | 时钟、旧流、stop、本地故障、候选淘汰和 deadline 溢出回归均 RED→GREEN；输出少量控制丢失指控由直接测试否定，另补控制饱和显式拒绝 | 未做第二轮独立复审；按修复回归和全套主机检查验证 |

## 契约请求

- 无。未修改 Contracts、Config、App 装配、工程、scheme、脚本或其他任务实现。

## 未验证与已知问题

- G0 仍未完成；未连接真实 AI 服务，未验证真实本地模型、采集、识别、PiP 或设备生命周期。最终源码没有模拟器／真机全量测试证据。
- `retainOnly` 对正在运行的淘汰 job 可能发出重复 dropped；不会启动新工作或触发回退，消费者仅将其作作用域校验后的清理事件。此非阻断项留待集成人评估。
- TASK-13 装配时需保证协调器先写 store 保留集合再调用 submit，并在回退确认时传入增代 identity；配置变更和显式恢复 AI 继续由协调器统一处理。
- 未推送、未合并 main。
