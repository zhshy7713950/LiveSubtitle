# TASK-05：能力、语言资源与连续识别

状态：未开始。原方案映射：T04 资源及 T05 识别部分。参考：[正式方案](../development-spec.md) §§3、8、9.4。

前置／并行条件：G0 通过；可并行，输入用合成自有 PCM、资源状态用任务内 doubles。

## 文件所有权

- `LiveSubtitle/Speech/`
- `LiveSubtitleTests/Speech/`

具体产物：创建 CapabilityService.swift、LanguageAssetManager.swift、LanguagePreparationHost.swift、SpeechService.swift；测试 CapabilityServiceTests.swift、SpeechServiceTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：CapabilityChecking、LanguageAssetManaging、SpeechRecognizing；AudioFormat、SpeechEvent、TranscriptSpan。
- 产出：CapabilityService: CapabilityChecking；@MainActor LanguageAssetManager: LanguageAssetManaging；SpeechService: SpeechRecognizing；供 Features 嵌入的 LanguagePreparationHost（具体参数在交接说明）。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testUnsupportedPairBlocksBothModes：识别不可用／翻译对不支持时阻止 local 和 AI；源目标相同不启动。
- [ ] testMissingAssetsAndCancellation：分别显示识别与翻译缺失；取消下载不启动采集；空安装请求视为无需安装。
- [ ] testReadinessIsQueriedAgain：曾下载的模型被移除后不使用缓存的 ready 标志；无准确进度不造百分比。
- [ ] testVolatileTimingEvents：启用 volatileResults 和 audioTimeRange，归一化 revision／utterance／span，final 与临时结果可区分。
- [ ] testExplicitAnalyzerTermination：finish 正常收尾；cancelAndFinish 立即释放，不仅关闭 AsyncStream。
- [ ] testFallbackWithoutTimingResetsAtWindowLimit：Dictation 必须本机支持；不足时序信息在 30 秒或 2000 字窗口处明确重建并发 discontinuity。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：前台 Translation.prepareTranslation 的 UI 桥接由本任务交付，非 UI 已安装模型翻译由 TASK-07 负责。连续识别不因两秒分段而重建；查询 bestAvailableAudioFormat 给 AudioPipeline。

提交建议：`feat(speech-assets): 能力、语言资源与连续识别`。验收未通过时保留未完成状态，不把任务清单勾为成功。
