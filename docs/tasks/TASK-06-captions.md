# TASK-06：有界转写、分段与字幕存储

状态：未开始。原方案映射：T05、T06 字幕部分。参考：[正式方案](../development-spec.md) §§6、9、10.1、12.1。

前置／并行条件：G0 通过；完全使用固定事件和 fake clock，可与所有正式模块并行。

## 文件所有权

- `LiveSubtitle/Captions/`
- `LiveSubtitleTests/Captions/`

具体产物：创建 TranscriptNormalizer.swift、CaptionSegmenter.swift、CaptionStore.swift；测试 CaptionSegmenterTests.swift、CaptionStoreTests.swift、TranscriptWindowTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：CaptionSegmenting、CaptionStoring；SpeechEvent、TranscriptSpan、SegmentEvent、TranslationJob／Update。
- 产出：actor CaptionSegmenter: CaptionSegmenting；actor CaptionStore: CaptionStoring；内部归一化器独立有界。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testRevisionReplacesSameSegment：临时结果缩短、范围合并、重复词、最终补标点不重复追加；同段 sourceRevision 递增。
- [ ] testTimedSegmentation：稳定前缀两次且 300ms、停顿约 450ms、约两秒／80字短段、三秒 provisional；无文字不能由计时器制造字幕。
- [ ] testNoNextSpeechCallbackStillEmits：最后一次Speech事件后仅推进fake clock，输出流仍能在适用截止时发段；reset后不再产生延迟段。
- [ ] testTenMinutesVolatileRemainBounded：模拟十分钟累计 volatile，无 final，窗口最多 30秒且2000用户可见字符，字幕最多十段，旧检查点文字不再追加。
- [ ] testRejectStaleUpdates：逐项改变 sessionID、三类 epoch／revision、段版本、jobID 或 deadline，结果均不写入；淘汰段不复活。
- [ ] testSnapshotOrderAndDisplayChange：按源时间排序；N=3→1→10→3 和仅译文只改变显示，不触发翻译；中文、emoji、组合字符按用户可见字符处理。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：final 文本冻结，除非明确范围替换产生新版本；旧译文可标 updating。snapshot 保留最多十段，renderer 决定可见数量；删除 ID 由协调器同步给 scheduler.retainOnly。

提交建议：`feat(captions): 有界转写、分段与字幕存储`。验收未通过时保留未完成状态，不把任务清单勾为成功。
