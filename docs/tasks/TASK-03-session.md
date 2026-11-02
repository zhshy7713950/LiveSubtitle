# TASK-03：会话状态机与停止协议

状态：未开始。原方案映射：T03、T08。参考：[正式方案](../development-spec.md) §§4.4、5–6、10.3、13。

前置／并行条件：G0 通过；可与 TASK-04～12 并行，使用任务内假实现。

## 文件所有权

- `LiveSubtitle/Session/`
- `LiveSubtitleTests/Session/`

具体产物：创建 SessionCoordinator.swift、SessionDependencies.swift；测试 SessionCoordinatorTests.swift 和本任务私有 doubles。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：SessionCoordinating 及其他 Ports；SessionIdentity、SessionStatus、PiPEvent、SchedulingEvent、注入的 MonotonicClock。
- 产出：actor SessionCoordinator: SessionCoordinating；依赖装配接口及准确 initializer 签名写入交接。拥有全部 identity 递增和生命周期。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testStopInvalidatesBeforeCancellation：入口关闭先于任何 await；之后新音频／结果不能启动翻译。
- [ ] testRepeatedStopReleasesOnce：同时用户关闭、采集撤销与错误只清理一次，无死锁。
- [ ] testOldSessionCallbacksCannotAffectRestart：旧 PiP close、旧错误和旧连接测试不停止／回退新会话。
- [ ] testPickerCancellationReturnsReady：取消共享后回 ready，不启动识别／PiP；语言变化则停会话并清空。
- [ ] testFallbackAndManualRecovery：回退只增一次 engineEpoch；新段和网络恢复不自动启用 AI；手动固定句成功后仅后续段走 AI。
- [ ] testProfileChangeRequiresExplicitAI：profile 变更取消旧代次并切本地，保存配置不发送当前字幕。
- [ ] testConfigurationMutationBarrier：cloudProfileWillChange 完成前不写新profile／Key；完成后旧作业不能取得新目标或新凭证，didChange只重读不启用AI。
- [ ] testModeChangeKeepsSpeechStreamAlive：local→AI、AI→local、故障fallback后原采音／Speech／分段流继续处理；新engineEpoch只使旧翻译失效，不丢后续原文或有效采集终止。
- [ ] testBufferedOldSchedulerFailureIsIgnored：错误入队后切模式再消费，按job身份／段版本拒绝旧failed；新的有效本地失败仍停止会话。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：先以 fake clock 和各端口 doubles 验证调用顺序，不依赖实际 SDK 和其他任务的具体类。停止时按方案顺序释放，local 失败保留可读错误后清空会话。

提交建议：`feat(session): 会话状态机与停止协议`。验收未通过时保留未完成状态，不把任务清单勾为成功。
