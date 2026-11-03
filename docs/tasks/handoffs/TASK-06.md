# TASK-06 交接

- 基线 commit：`29aae8d76ca7465f827f98a430fe5864e7af5a8f`
- 任务分支 / commit：`worktree-feat+task-06-captions` / 本交接所属提交
- 前置报告：`docs/reports/g0-device-report.md` 仍标记 G0 未通过；用户明确指派本任务，先完成独立模块与逻辑验证，不宣称完整链路验收。
- 状态：待审查

## 实施计划

> 在当前会话按 TDD 逐项执行；每个行为先写失败测试，再实现并回归。

**目标：** 交付有界转写归一化、可计时修订分段和最近十段字幕存储。

**约束：** 仅修改 `Captions`、`LiveSubtitleTests/Captions` 及本交接文件；不修改 Contracts、App 装配、工程或脚本。使用固定事件和 fake clock，不访问真实字幕、设备或网络。

### Task 1：转写窗口

- [x] 以用户可见字符验证中文、emoji、组合字符和 2,000 字上限。
- [x] 验证单事件及多事件 30 秒窗口、音频检查点、全量已消费空段和 final 冻结。
- [x] 缺少可用时序映射且达到窗口上限时显式请求 discontinuity。

### Task 2：字幕存储

- [x] 逐项拒绝 sessionID、languageEpoch、engineEpoch、cloudConfigRevision、jobID、段版本和 deadline 不匹配结果。
- [x] 验证淘汰段不复活、源时间排序、显示切换、修订 updating、十段上限和停止清空。

### Task 3：分段与整体验证

- [x] 验证缩短、范围合并、重复词、final 补标点及 sourceRevision 递增。
- [x] 验证稳定前缀、停顿、两秒／80 字短段、三秒 provisional、无下一回调发段及 reset 取消。
- [x] 模拟十分钟累计 volatile；运行全套主机测试、既有主机回归、工程检查和 sanitizer。

## 改动

- `TranscriptNormalizer.swift`：维护按 utterance 修订的有界转写快照；保留有理数音频时间和 spans，以 30 秒／2,000 个用户可见字符裁剪；按音频检查点排除已消费前缀，final 仅接受明确范围替换。
- `CaptionSegmenter.swift`：实现 `actor CaptionSegmenter: CaptionSegmenting`。同段修订替换文本并递增 sourceRevision；支持稳定前缀、停顿、短段和 provisional 截止；计时器不依赖下一次 Speech 回调。
- `CaptionStore.swift`：实现 `actor CaptionStore: CaptionStoring`。按源时间保留最近十段；写入译文前核对完整 identity、job、段保留状态、sourceRevision 和 deadline；显示设置不改变源版本或触发翻译。
- `LiveSubtitleTests/Captions/`：包含任务卡六项具名验收及窗口、空段、清空、代次推进、故障和无文字计时器回归。`TASK06_HOST_CHECK` 执行同一生产源码，不访问 SDK／设备。

## 对外装配

- `CaptionSegmenter()`：使用生产单调时钟；`CaptionSegmenter(clock: any MonotonicClock)` 用于 fake clock。
- `CaptionStore()`：随后调用 `begin(identity:display:)`；停止时调用 `clear()`。
- `TranscriptNormalizer()` 为模块内部组件，不要求 TASK-13 直接装配。
- Contracts 无变化。

## 流与资源边界

- 分段输出使用按需拉取的 `AsyncStream` 和最多 32 个事件的内部队列；队满时生产者等待，不丢弃 remove／discontinuity，也不使用无界缓冲。
- 输入消费和计时任务均绑定内部 generation；reset 取消任务、关闭输出、清空转写及 active 段。旧输出取消只影响其所属 generation。
- actor 在输出 await 前提交检查点和 active 状态，避免旧关闭操作擦除新回调；测试时钟只推进单调时间，不真实等待分段阈值。
- 字幕、原文和译文只在内存中处理；没有落盘、网络、日志正文或新权限。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 修改前 `scripts/verify.sh` | 基线 `29aae8d` | 退出码 0 | 仅框架／编译检查 |
| `TASK06_HOST_CHECK` 失败先行 | Swift 6 完整并发 | 窗口、存储、分段分别因缺少实现失败；空段及音频起点回归也先失败后通过 | 保留红绿证据 |
| 最终 `TASK06_HOST_CHECK` | 28 项，警告即错误 | 28 项执行通过；普通构建连续 100 轮通过 | 不包含 iOS SDK／设备行为 |
| AddressSanitizer / ThreadSanitizer | 各 28 项，各连续 20 轮 | 均执行通过 | 不包含 iOS SDK／设备行为 |
| 既有 `G0_HOST_CHECK` | 13 项 | 13 项执行通过 | 不包含 SDK／设备行为 |
| 既有 `TASK04_HOST_CHECK` | 21 项 | 21 项执行通过 | 不包含 iOS 采集／设备行为 |
| 最终 `scripts/verify.sh` | Xcode 27.2；iOS Debug、Release、generic simulator App／测试 bundle | 退出码 0 | 不执行行为测试 |
| `scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list devices available` 无设备 | 未执行 | 无可用 iOS 27 模拟器运行时 |
| 任务卡逐项验收 | 固定事件、fake clock、十分钟压力输入 | 主机逻辑均执行通过 | 真机完整链路不属于本轮证据 |

主机复现命令：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path build/task06-module-cache -D TASK06_HOST_CHECK \
  LiveSubtitle/Contracts/Models/*.swift LiveSubtitle/Contracts/Ports/*.swift \
  LiveSubtitle/Contracts/RuntimePolicy.swift LiveSubtitle/Captions/*.swift \
  LiveSubtitleTests/Captions/*.swift -o build/task06-host-checks
./build/task06-host-checks
```

## 独立审查

- 独立 reviewer 判定初版不 ready：1 项 Critical 为 reset/restart 后旧 actor continuation 污染新代次；5 项 Important 分别为已关闭 provisional 的 final 协调、粗粒度 spans、长 remainder 超限、checkpoint 索引增长、增长前缀稳定年龄；另有 1 项前导空白 Minor。
- 已全部修复：generation 在任何 await 前失效，await 后重新校验；保留最近十个 closed provisional 并协调 final；跨 checkpoint／切点的粗 span 显式 discontinuity；循环切分长段；checkpoint 索引有界；增长前缀重新计时；稳定前缀仅去尾部空白。
- 背压 reset/restart、相同／补标点 final、250 字 final、100 个 utterance checkpoint、增长前缀、粗 span 和 discontinuity 生命周期均有回归。修复后 28 项连续 100 轮及 ASan／TSan 各 20 轮通过；未进行第二轮 reviewer 复审，最终由集成人审查。

## 契约请求

- 无。

## 未验证与已知问题

- G0 尚未通过；本轮没有真实识别、翻译、采集、PiP、Chrome 或设备生命周期执行证据。
- 无模拟器运行时，未执行 iOS 测试 target；主机测试和 generic simulator 测试 bundle 编译不能替代该执行。
- 集成人需把 SegmentEvent 同步到 store／scheduler，并在段淘汰后按 snapshot 将保留 ID 交给 `retainOnly`；停止时同时调用 `CaptionSegmenter.reset()` 与 `CaptionStore.clear()`。
