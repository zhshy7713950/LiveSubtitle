# TASK-13：模块装配、生命周期和无内容诊断

状态：未开始。原方案映射：T06～T08 集成。参考：[正式方案](../development-spec.md) §§5–6、13–15。

前置／并行条件：TASK-03～12分别验证并合入后执行；只由一个集成人负责。

## 文件所有权

- `LiveSubtitle/App/`
- `LiveSubtitle/Diagnostics/`
- `LiveSubtitleTests/Support/`
- `LiveSubtitleTests/Integration/`
- `Config／Contracts／工程／scripts由集成人统一维护`
- `清理LiveSubtitle/Validation/G0/`

具体产物：创建 AppComposition.swift、SystemMonotonicClock.swift、LifecycleBridge.swift、DiagnosticsRecorder.swift、IntegrationTests.swift；移除ScaffoldView占位及G0临时入口。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：全部生产实现与冻结Ports；审阅各任务交接initializer。
- 产出：唯一生产依赖装配、无内容DiagnosticsRecording实现、前后台／锁屏／系统中断桥接；正式主界面取代说明空壳。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testLocalModeHasNoSubtitleNetworkTraffic：本地路径严格不创建云端请求；开始前资源失败不创建采集／PiP。
- [ ] testWholeStopAndRapidRestart：先失效再取消、清空所有文字／PCM／帧；旧回调不串新会话，停止后新job=0。
- [ ] testLiveDisplayAndProfileChange：显示设置不重启；profile／Key变更只本地；用户恢复AI仅发送后续段。
- [ ] testResourceAndPiPFailuresStopSafely：本地翻译失败／识别持续失败、锁屏、采集撤销、严重过热、PiP被替换均按协议结束。
- [ ] testDiagnosticsHaveNoContent：采集诊断输出中无原文／译文／Key／完整URL查询／原始响应，保留时间、数量、安全错误类别。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：按下列验收和补充要求执行，并如实记录命令、环境和结果。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：完整运行./scripts/verify.sh和./scripts/test.sh；共享接口发生冲突先在Contracts修正并全量编译，不在适配器里静默改语义。G0样板不保留生产可选捷径。

提交建议：`feat(integration): 模块装配、生命周期和无内容诊断`。验收未通过时保留未完成状态，不把任务清单勾为成功。
