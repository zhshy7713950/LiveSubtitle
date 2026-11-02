# TASK-04：全屏采音与有界音频管线

状态：未开始。原方案映射：T02 后生产化、T05 音频部分。参考：[正式方案](../development-spec.md) §§5.1、7、13。

前置／并行条件：G0 通过；与 TASK-03、05～12 并行，识别目标格式来自协议假实现。

## 文件所有权

- `LiveSubtitle/Capture/`
- `LiveSubtitle/Audio/`
- `LiveSubtitleTests/Audio/`

具体产物：创建 ScreenCaptureAudioSource.swift、AudioPipeline.swift、AudioTimeMapper.swift；测试 AudioPipelineTests.swift、AudioTimeMapperTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：AudioSource、AudioProcessing、CaptureConfig、AudioFormat、AudioChunk 和 AudioTimestamp；不自行调用识别或网络。
- 产出：@MainActor ScreenCaptureAudioSource: AudioSource；actor AudioPipeline: AudioProcessing；回调只复制与非阻塞交接。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testPCMOwnershipSurvivesCallbackReturn：源 buffer 释放／复用后 ownedPCM 内容不变；交错和非交错、整型和浮点均有夹具。
- [ ] testOverflowDropsOldestAndMarksDiscontinuity：待消费时长不超两秒，显式断点并清理未完成内容，不阻塞采集线程。
- [ ] testFormatChangeRebuildsConverter：采样率、声道、路由改变保持时间映射正确；无效样本拒绝。
- [ ] testControlEventsSurviveOverflow：持续填满缓冲后采集停止／错误仍可达，消费者退出关闭底层流。
- [ ] testSilenceAndNoSamplesDiffer：有静音 buffer 与无 buffer 的状态不同，不推断 DRM。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：返回用户取消用 CancellationError。Speech.inputFormat 查询的 AudioFormat 是转换目标。系统 API 代码从 G0 核对后实现，不复制 macOS-only 配置。实际 Chrome／音频路由回归在 TASK-14 记录。

提交建议：`feat(audio): 全屏采音与有界音频管线`。验收未通过时保留未完成状态，不把任务清单勾为成功。
