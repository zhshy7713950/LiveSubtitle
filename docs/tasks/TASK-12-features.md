# TASK-12：语言、AI 与字幕设置界面

状态：未开始。原方案映射：T04 UI、T06 UI、T07 UI、T08 UI。参考：[正式方案](../development-spec.md) §§1.2、4、8.2、14。

前置／并行条件：G0 通过；依赖Ports可用任务内 ViewModel doubles 并行，正式App入口由TASK-13接入。

## 文件所有权

- `LiveSubtitle/Features/`
- `LiveSubtitleTests/Features/`

具体产物：创建 Setup/SetupView.swift、Setup/SetupViewModel.swift、CloudSettings/CloudSettingsView.swift、CloudSettings/CloudSettingsViewModel.swift、SubtitleSettings/SubtitleSettingsView.swift；测试对应ViewModelTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：SessionCoordinating、CapabilityChecking、LanguageAssetManaging、PreferencesStoring、CredentialStoring、ConnectionTesting；TASK-05 的准备host在集成时嵌入。
- 产出：可注入协议依赖的三个SwiftUI功能入口和MainActor ViewModel，不修改LiveSubtitleApp。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testInitialSetupAndResources：默认local、英文→zh-Hans建议可见可改；不支持／同语种阻止开始，AI也要求本地备用。
- [ ] testCancelledPreparationNeverStartsCapture：准备可取消；无准确进度只显示准备中，不制造百分比。
- [ ] testCloudSaveIsNotEnableAI：完整endpoint／model／Key验证，保存增revision并通知会话先本地；固定句连接测试仅由按钮发起。
- [ ] testCloudMutationOrder：编辑／选择profile、替换／删除Key都先await cloudProfileWillChange再持久化并调用didChange；Key变更也更新profile revision，保存后不恢复AI。
- [ ] testDisplayOnlyUpdate：N从1到10默认3和双语／仅译文只setDisplay，不start或补译。
- [ ] testLanguageChangeStopsAndRequiresRestart：换语种停止清空；查看设置不停止，网络恢复不自动启AI。
- [ ] testUserFacingStates：空等／回退／本地失败原因可理解，不显示内部队列或SDK名称；Key输入受保护。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：保存普通profile和保存Key是不同操作，提交和展示不得带真实Key。具体布局遵循正式流程，不提前扩账户、历史和导出。

提交建议：`feat(features): 语言、AI 与字幕设置界面`。验收未通过时保留未完成状态，不把任务清单勾为成功。
