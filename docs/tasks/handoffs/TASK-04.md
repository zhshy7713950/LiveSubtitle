# TASK-04 交接

- 基线 commit：`9881c69eed686a98b68b34f608fab6acd58d72b1`
- 任务分支 / commit：`worktree-task-04-audio` / 本交接所属提交
- 前置报告：`docs/reports/g0-device-report.md` 仍标记 G0 未通过；用户明确指派本任务，先完成独立模块与逻辑验证，不宣称完整链路验收。
- 状态：待审查

## 实施计划

> 使用 `superpowers:executing-plans` 在当前会话逐项执行；每步先写失败测试，再写最小实现。

**目标：** 交付全屏音频采集、自有 PCM、格式转换、连续时间映射和两秒有界音频管线。

**约束：** 仅修改 `Capture`、`Audio`、`LiveSubtitleTests/Audio` 及本交接文件；不修改 Contracts、App 装配或脚本。系统采集不支持模拟器时明确抛错，不返回假成功。

### Task 1: PCM 所有权与时间映射

- [x] 在 `AudioTimeMapperTests.swift` 先覆盖连续帧时钟、一帧采集时钟漂移、真实 PTS 断流和无效输入。
- [x] 在 `AudioPipelineTests.swift` 的 `testPCMOwnershipSurvivesCallbackReturn` 中覆盖交错／非交错、整型／浮点源复用后的数据不变性。
- [x] 实现 `AudioTimeMapper.swift` 与内部 PCM 深拷贝／校验，保持媒体对象不跨 actor。
- [x] 运行本任务测试，确认先失败后通过。

### Task 2: 有界流与转换管线

- [x] 先写 `testOverflowDropsOldestAndMarksDiscontinuity`、`testControlEventsSurviveOverflow`、`testSilenceAndNoSamplesDiffer`。
- [x] 先写 `testFormatChangeRebuildsConverter`，覆盖采样率、声道、显式路由／断流变化及非法样本。
- [x] 实现 `AudioPipeline.swift`：分离终端控制事件、drop-oldest、断点传播、AVAudioConverter 重建、消费者取消向上游传播。
- [x] 运行本任务测试并检查边界，不用真实等待验证队列行为。

### Task 3: 系统采集与整体验证

- [x] 实现 `ScreenCaptureAudioSource.swift`，复用 G0 的 iOS 27 SDK 路径；选择器取消抛 `CancellationError`，SDK／非法样本错误使用 `FailureCode`。
- [x] 执行 `./scripts/verify.sh`；当前没有可用 iOS 模拟器，分别记录编译、执行和未验证项。
- [x] 审查文件范围、取消与资源释放，填写初始化方式和验证结果后独立提交。

## 改动

- `Capture/ScreenCaptureAudioSource.swift`：实现 `@MainActor ScreenCaptureAudioSource: AudioSource`。默认初始化在 iOS 真机使用 `SCContentSharingPicker` 全屏选择器和 `SCStream` 音频输出；模拟器及非 iOS 默认构造抛 `unavailable`。选择器取消抛 `CancellationError`，不返回假活动流。
- `Audio/AudioPipeline.swift`：实现 `actor AudioPipeline: AudioProcessing`。使用 `AVAudioConverter` 适配识别目标格式；采样率、声道、序号、显式断点或实际 PTS 断流变化时重建转换并标记 discontinuity。内部 `AudioActivity` 区分无样本、全零静音和有非零数据，不推断 DRM。
- `Audio/AudioTimeMapper.swift`：按实际输出帧数推进连续识别时钟，容忍不超过一个源帧的采集时钟漂移；真实断流显式重建时间线。
- `LiveSubtitleTests/Audio/`：包含任务卡五项具名验收、取消、非法元数据、采集生命周期和时间映射测试；`TASK04_HOST_CHECK` 入口执行同一生产源码，不是另一份实现。
- 对外初始化：`@MainActor ScreenCaptureAudioSource()`、`AudioPipeline()`。`ScreenCaptureAudioSource(driver:)` 是任务内测试装配入口；Contracts 无变化。

## 流与资源边界

- 采集回调只验证样本、复制 PCM 平面并同步交给 `BoundedAudioEventBuffer`，不等待 actor，不持有回调媒体缓冲。SDK filter／stream 留在带锁的非隔离所有权岛，不进入 Task。
- 队列使用 `RuntimePolicy.audioBufferDuration` 两秒预算，包含已取出但尚未继续消费的 PCM；溢出丢弃最旧可回收音频，给新时间线首块设置 discontinuity。ended／failed 使用独立终端槽，不被音频溢出覆盖。
- 输出使用按需拉取的 `AsyncStream` 和显式有界队列；等待支持取消。消费者取消会停止输入迭代任务，采集源与协调器仍可显式 `stop()` 释放 SDK。
- 停止结束输出、取消消费、释放转换器及采集 stream，并清空临时 PCM；不上传、不落盘、不记录音频内容。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 修改前 `scripts/verify.sh` | 基线 `9881c69` | 退出码 0 | 仅框架／编译检查 |
| 最终 `scripts/verify.sh` | iOS Debug、Release、generic simulator App／测试 bundle | 退出码 0 | 不执行行为测试 |
| `TASK04_HOST_CHECK` 主机测试 | Swift 6 完整并发检查，14 项 | 14 项执行通过 | 不包含 iOS 采集／设备行为 |
| 既有 `G0_HOST_CHECK` 回归 | 13 项 | 13 项执行通过 | 不包含 SDK／设备行为 |
| `scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list devices available` 无设备 | 未执行 | 无可用 iOS 27 模拟器运行时 |
| 任务卡五项具名验收 | 主机逻辑／AVFoundation | 均执行通过 | 真实系统采集另行验证 |
| `git diff --check` | 当前差异 | 退出码 0 | 无空白错误 |

## 契约请求

- 无。

## 未验证与已知问题

- G0 尚未通过；本任务没有真机采音、Chrome、音频路由、系统选择器或完整链路的新执行证据。真实 SDK 代码仅完成 iOS Debug／Release 编译。
- 无模拟器运行时，未执行 iOS 测试 target；主机测试和 generic simulator 测试 bundle 编译不能替代该执行。
- 集成人使用上述两个默认 initializer 装配；会话停止时必须同时显式调用 `ScreenCaptureAudioSource.stop()` 与 `AudioPipeline.stop()`，不能只依赖流取消。
