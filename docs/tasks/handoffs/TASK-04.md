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

- [x] 覆盖连续帧时钟、一帧采集时钟漂移、真实 PTS 断流和无效输入。
- [x] `testPCMOwnershipSurvivesCallbackReturn` 覆盖交错／非交错、整型／浮点源复用后的数据不变性。
- [x] 实现 PCM 深拷贝／校验与时间映射，保持媒体对象不跨 actor。

### Task 2: 有界流与转换管线

- [x] 实现任务卡五项具名行为测试，以及取消、非法元数据、正常 EOF、converter 尾帧排空测试。
- [x] 实现两秒队列、drop-oldest、断点传播、AVAudioConverter 重建与消费者取消。
- [x] 独立审查指出的正常结束清队列、converter 未排空、旧输出误停新一代问题均以修复前 RED／修复后 GREEN 验证。

### Task 3: 系统采集与整体验证

- [x] 实现 `ScreenCaptureAudioSource.swift`；选择器取消及启动 Task 取消使用 `CancellationError`，SDK／非法样本使用安全 `FailureCode`。
- [x] core／start／output 回调携带生命周期 token；旧 core 事件只完成旧 core 收尾，不恢复新 continuation。
- [x] 执行完整工程检查；无模拟器运行时，主机执行与真机未验证项分别记录。

## 改动

- `Capture/ScreenCaptureAudioSource.swift`：实现 `@MainActor ScreenCaptureAudioSource: AudioSource`。默认初始化在 iOS 真机使用 `SCContentSharingPicker` 全屏选择器和 `SCStream` 音频输出；模拟器及非 iOS 默认构造抛 `unavailable`。选择器取消抛 `CancellationError`，不返回假活动流。
- `Audio/AudioPipeline.swift`：实现 `actor AudioPipeline: AudioProcessing`。使用 `AVAudioConverter` 适配识别目标格式；采样率、声道、序号、显式断点或实际 PTS 断流变化时重建转换并标记 discontinuity。正常 EOF 先交付排队音频并以 `.endOfStream` 排空 converter；故障和主动停止立即清空。
- `Audio/AudioTimeMapper.swift`：按实际输出帧数推进连续识别时钟，容忍不超过一个源帧的采集时钟漂移；converter 尾帧沿用同一样本时钟。
- `LiveSubtitleTests/Audio/`：包含任务卡五项具名验收、取消、非法元数据、采集生命周期、快速重启、正常 EOF 与尾部排空测试。`TASK04_HOST_CHECK` 入口执行同一生产源码，可按名称筛选用例。
- 对外初始化：`@MainActor ScreenCaptureAudioSource()`、`AudioPipeline()`。`ScreenCaptureAudioSource(driver:)` 是任务内测试装配入口；Contracts 无变化。

## 流与资源边界

- 采集回调只验证样本、复制 PCM 平面并同步交给 `BoundedAudioEventBuffer`，不等待 actor，不持有回调媒体缓冲。SDK filter／stream 留在带锁的非隔离所有权岛，不进入 Task。
- 队列使用 `RuntimePolicy.audioBufferDuration` 两秒预算，包含已取出但尚未继续消费的 PCM；溢出丢弃最旧可回收音频，给新时间线首块设置 discontinuity。ended 在排队音频后排空，failed 使用独立终端槽立即送达。
- 输出使用按需拉取的 `AsyncStream` 和显式有界队列；等待支持取消。取消回调捕获所属 token 和 buffer，只停止仍属当前代次的资源。
- 主动停止直接关闭并清空输出、取消消费、释放转换器及采集 stream；不依赖正常 EOF drain，不上传、不落盘、不记录音频内容。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| 修改前 `scripts/verify.sh` | 基线 `9881c69` | 退出码 0 | 仅框架／编译检查 |
| 最终 `scripts/verify.sh` | Xcode 27.2；iOS Debug、Release、generic simulator App／测试 bundle | 退出码 0，无编译警告 | 不执行行为测试 |
| `TASK04_HOST_CHECK` 主机测试 | Swift 6 完整并发、警告即错误，21 项 | 21 项执行通过 | 不包含 iOS 采集／设备行为 |
| 审查回归红绿对照 | 正常 EOF、converter drain、旧 pipeline／capture 取消、pending picker 取消 | 修复前 5 项分别失败，修复后全部通过 | core 真机时序仍无设备执行证据 |
| AddressSanitizer／ThreadSanitizer | 修复后主机版本，各 20 项 | 均执行通过 | 不含新增主动停止用例及 iOS SDK |
| 既有 `G0_HOST_CHECK` 回归 | 13 项 | 13 项执行通过 | 不包含 SDK／设备行为 |
| `scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list devices available` 无设备 | 未执行 | 无可用 iOS 27 模拟器运行时 |
| 任务卡五项具名验收 | 主机逻辑／AVFoundation | 均执行通过 | 真实系统采集另行验证 |
| `git diff --check` | 最终差异 | 退出码 0 | 无空白错误 |

## 独立审查与保留事项

- 独立 reviewer 的 5 项 Important 已全部修复：旧输出误停新代次、旧 core 事件污染、正常 EOF 清队列、converter 未排空、选择器启动不响应 Task 取消。未进行第二轮 reviewer 复审；最终由集成人审查。
- 保留 Minor：真实路由通知没有新真机验证，当前测试证明的是 pipeline 响应显式 discontinuity；TASK-14 仍需实际路由回归。
- 保留 Minor：目标格式非法时输出返回 `.speechFailed`，集成人必须显式停止上游 source。
- 保留 Minor：采集 SDK 的极端 `count > Int32.max` 尚未加显式边界，真实系统样本未出现该输入。
- 保留 Minor：全为浮点 `-0.0` 的 PCM 当前按非零字节计为 audible，不据此推断 DRM；后续可改为按浮点数值判断。

## 契约请求

- 无。

## 未验证与已知问题

- G0 尚未通过；本任务没有真机采音、Chrome、音频路由、系统选择器或完整链路的新执行证据。真实 SDK 代码仅完成 iOS Debug／Release 编译。
- 无模拟器运行时，未执行 iOS 测试 target；主机测试和 generic simulator 测试 bundle 编译不能替代该执行。
- 集成人使用上述两个默认 initializer 装配；会话停止时必须同时显式调用 `ScreenCaptureAudioSource.stop()` 与 `AudioPipeline.stop()`，不能只依赖流取消。
