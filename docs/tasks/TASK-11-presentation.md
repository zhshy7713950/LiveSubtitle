# TASK-11：字幕帧、布局与 PiP

状态：未开始。原方案映射：T06 PiP部分。参考：[正式方案](../development-spec.md) §§4.3、12–13。

前置／并行条件：G0 通过；用固定 SubtitleSnapshot 和 PiP 系统包装器可独立开发。

## 文件所有权

- `LiveSubtitle/Presentation/`
- `LiveSubtitleTests/Presentation/`

具体产物：创建 SubtitleRenderer.swift、SubtitleLayout.swift、PiPCoordinator.swift；测试 SubtitleLayoutTests.swift、PiPCoordinatorTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：SubtitleRendering、PiPControlling、SubtitleSnapshot、PiPEvent；系统媒体对象留在MainActor适配器。
- 产出：@MainActor SubtitleRenderer: SubtitleRendering；@MainActor PiPCoordinator: PiPControlling；同一显示层连接通过任务内 initializer 暴露给集成。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testNewestReadableLinesWin：实际尺寸、中文长句、emoji下换行；双语译文主导、仅译文无原文；不足空间裁旧段，不无限缩字号。
- [ ] testDisplayChangesDoNotRestartPipeline：N和样式只重排已有snapshot，不采音／翻译／重启PiP。
- [ ] testFrameCoalescingAndPTS：最多10fps、旧待绘帧被最新快照合并、单调视频PTS，无无限帧排队。
- [ ] testCloseRestoreAndReplacementDiffer：显式关闭发closed，恢复按钮只发恢复过程事件；旧session停止回调带原ID，PiP被替换可识别。
- [ ] testUnsupportedOrImpossiblePiPFails：支持与possible分别检查；失败不保留无字幕的后台采集；clear删除文字和帧。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：Receiver入队按G0和本机SDK核对。真机拖动／缩放／Chrome播放器PiP冲突由TASK-14验证。返回App后的可恢复性必须和Session联调，不声称双PiP。

提交建议：`feat(presentation): 字幕帧、布局与 PiP`。验收未通过时保留未完成状态，不把任务清单勾为成功。
