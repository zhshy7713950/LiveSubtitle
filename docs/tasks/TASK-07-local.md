# TASK-07：端侧本地翻译适配

状态：未开始。原方案映射：T06 本地引擎部分。参考：[正式方案](../development-spec.md) §§8.2、10.2。

前置／并行条件：G0 通过；与资源管理和调度并行，测试以系统会话包装器注入。

## 文件所有权

- `LiveSubtitle/Translation/Local/`
- `LiveSubtitleTests/Translation/Local/`

具体产物：创建 AppleLocalTranslator.swift；测试 AppleLocalTranslatorTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：Translator、TranslationJob、TranslationUpdate；已安装语言资源；不负责弹 UI 下载。
- 产出：AppleLocalTranslator: Translator；每语言对生命周期明确的非 UI TranslationSession。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testPreservesJobIdentity：原样关联 jobID、完整 identity、段和版本，provider=local，输出是累计替换文本。
- [ ] testNoDownloadFromRuntime：模型缺失返回 assetsMissing，不在后台触发 UI 准备；在集成中升级为本地能力失败停止。
- [ ] testCancelReleasesAndDropsLateResult：cancelAll／消费者结束取消真实工作，晚到结果不继续产出。
- [ ] testSessionReuseAndPairChange：同语言对复用有生命周期的系统会话，换对重新建；系统失败输出安全 failure，流关闭。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：不能让测试依赖网络或用户安装资源。实际断网翻译和后台持续行为由 TASK-14 真机验收；适配器不自行决定全局 fallback 或修改 identity。

提交建议：`feat(local): 端侧本地翻译适配`。验收未通过时保留未完成状态，不把任务清单勾为成功。
