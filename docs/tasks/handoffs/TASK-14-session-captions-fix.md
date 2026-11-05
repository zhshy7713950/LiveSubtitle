# TASK-14 R02／R03／R07 修复交接

- 基线 commit：`1c74d3c`。
- 分支：`codex/task14-session-captions-fix`；代码及本交接同一提交，SHA 由集成交接消息提供。
- 前置报告：[TASK-14 验收报告](../../reports/acceptance-report.md)，保留原失败与真机证据。
- 状态：待集成审查。用户本轮授权覆盖原 TASK-14 目录限制；未修改验收／性能报告。

## 改动

- R02：`CaptionStoring` 新增 `remove(segmentID:) async`；真实 store 及唯一 Session 测试 conformer 实现删除。协调器清除保留索引、模式切换待处理段、store 和 scheduler 引用并刷新显示；翻译和故障消费检查段版本，防止旧作业影响已移除段。
- R03：保持最多十个逐 utterance checkpoint。淘汰的最早 checkpoint 合并到单调音频 watermark，晚到文字仍按真实 span 裁剪或拒收；无法映射的粗 span 仍请求 discontinuity。普通 rollover 不再把触发上限的有效 upsert 改写为 discontinuity；reset 清除 watermark。不调整 RuntimePolicy 上限。
- R07：启动故障通过 `beginStop(..., failure: code)` 保留安全原因，清理后为 failed／原 FailureCode。停止先取消 startupTask 再等待；旧启动代次不能清除新启动任务引用，停止清理负责释放引用。主动选择器取消仍 ready，生命周期停止仍 idle／nil。
- 新增六个测试方法：Session 三项；Captions 的删除拒收、25 句逐句输出、watermark 跨界裁剪三项；既有 checkpoint 有界检查加强为 100 句及旧音频拒收。
- Session 异步条件等待由固定 500 次 yield 改为两秒单调测试保护期限，避免主机负载导致尚未被调度便提前断言。生产 deadline 仍使用注入测试时钟，不增加真实六秒等待。

## 验证

| 命令／步骤 | 结果 | 证据边界 |
| --- | --- | --- |
| 新增 Session 回归，修复前主机执行 | 启动故障保留、等待选择器时停止、段删除三项均失败 | RED，直接执行真实 coordinator |
| checkpoint normalizer／25 句 segmenter，修复前主机执行 | 分别因 rollover discontinuity／有效句丢失失败 | RED，真实 Captions 源码 |
| `SESSION_HOST_CHECK`，Swift 6 完整并发、警告即错误 | 最终 20／20，退出 0 | 纯逻辑执行，无设备／SDK 行为 |
| `TASK06_HOST_CHECK`，同上 | 最终 31／31，退出 0 | 真实 normalizer／segmenter／store；纯逻辑执行 |
| `./scripts/verify.sh` | Debug、Release、generic simulator 测试 bundle 编译成功，退出 0 | 不执行行为测试，不证明 G0 |
| `git diff --check` | 退出 0 | 差异空白检查 |

初次并行编译／执行主机套件时，Session 的 fixed-yield 等待使新增停止用例及既有 fallback、modeChange 等检查提前耗尽；另有真实删除边界检查缺失。删除边界已修复，等待改成有单调期限的条件轮询；最终上述 Session 全部执行通过。不把中间失败抹为从未失败。

复现主机命令沿用 TASK-03／06 交接：合入全部 Contracts／RuntimePolicy，再分别编译 `Session/*.swift` + `LiveSubtitleTests/Session/*.swift`（`-D SESSION_HOST_CHECK`），或 `Captions/*.swift` + `LiveSubtitleTests/Captions/*.swift`（`-D TASK06_HOST_CHECK`），并实际运行生成的可执行文件。

## 契约

- 已按本轮集成人授权新增 `CaptionStoring.remove(segmentID: UUID) async`，消费者为 SessionCoordinator，生产实现为 CaptionStore；无其他签名／initializer 变化。
- 不涉及 Presentation、Cloud、Features、RuntimePolicy、App 或工程修改。

## 未验证

- 本分支未运行设备或模拟器 XCTest；原 AcceptanceCaptionTests 两项与 AcceptanceStartupTests 一项需根集成人执行集成后真机回归。
- 没有真实系统选择器取消、Chrome、PiP 或 G0 新证据；不得由主机结果推断产品可用。
- 未推送、未合并其他分支。
