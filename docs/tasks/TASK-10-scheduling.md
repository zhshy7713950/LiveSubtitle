# TASK-10：有界调度、修订预算与回退请求

状态：未开始。原方案映射：T05 调度、T08。参考：[正式方案](../development-spec.md) §§6.1、9.3、10、11.2。

前置／并行条件：G0 通过；用 Translator 和 MonotonicClock 假实现可独立开发，无须等待真实本地／云端适配。

## 文件所有权

- `LiveSubtitle/Translation/Scheduling/`
- `LiveSubtitleTests/Translation/Scheduling/`

具体产物：创建 TranslationScheduler.swift、TranslationJobQueue.swift；测试 TranslationSchedulerTests.swift、FallbackTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：TranslationScheduling、Translator、MonotonicClock；CaptionSegment、SchedulingEvent；由协调器传入的新identity。
- 产出：actor TranslationScheduler: TranslationScheduling；事件携带原job，所有全局回退通过 fallbackRequested 请求协调器处理。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testConcurrencyAndQueueBounds：AI≤2、本地≤1、未开始≤4；保留最新待执行版本、优先丢最旧、段淘汰同步清job／索引。
- [ ] testDeadlineIncludesQueueTime：创建起六秒，不因等待重置；首文本三秒且不超总时限；有效timeout恰好一次请求回退，迟到成功丢弃。
- [ ] testStaleErrorAndCancellationDoNotFallback：旧session／epoch／revision错误与主动取消无副作用；当前有效服务故障才回退。
- [ ] testRevisionBudget：同段AI间隔≥800ms、最多2 provisional+1 final；预算耗尽只本地更新该段、provider=local、不全局回退。
- [ ] testFallbackLocksAndEpochAcknowledgement：发请求后暂停AI新任务，协调器确认增代后处理仍有效最新段；新段／网络恢复不自动启AI。
- [ ] testStopLeavesZeroNewJobs：stop先关闭入口，取消队列和流；重复stop安全，过期段不补发。
- [ ] testProfileSnapshotAtSubmission：start／setMode的profile ID与revision必须匹配，AI job固定快照；local／单段预算回退job不绑定云目标。
- [ ] testQueuedFailureCarriesJob：failed／dropped均携原job，消费者能对缓冲期间已失效的事件重新校验；无job的无效配置由start／setMode抛安全错误，不发无归属failed。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：不要让旧作业的deadline守卫吞掉当前timeout事件。输出上限120字输入由分段器保证并在边界防御；不实现分段器。所有时间测试使用可推进的fake clock，无真实六秒sleep。

提交建议：`feat(scheduling): 有界调度、修订预算与回退请求`。验收未通过时保留未完成状态，不把任务清单勾为成功。
