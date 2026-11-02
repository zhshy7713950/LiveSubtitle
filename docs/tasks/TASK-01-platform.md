# TASK-01：环境、签名与真机基线

状态：未开始。原方案映射：T01。参考：[正式方案](../development-spec.md) §§3、15 T01。

前置／并行条件：框架已合入即可开始；本次仅完成无签名编译，签名和真机安装仍待执行。

## 文件所有权

- `docs/reports/platform-baseline.md`
- `个人 Config/Local.xcconfig（不提交）`

具体产物：记录 Xcode、SDK、macOS、测试 iPhone／iOS 和 Chrome 版本，以及开发签名可用性。需要改 Config 或工程时由集成人提交。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：现有 LiveSubtitle scheme 和 Config。
- 产出：可签名安装的空 App 与环境报告；不宣称任何媒体能力。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] 设备安装并打开空壳，确认没有授权弹窗、联网、采集或模型下载。
- [ ] 报告区分无签名构建、签名、安装和启动；设备标识与证书不进入公开仓库。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：按下列验收和补充要求执行，并如实记录命令、环境和结果。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：执行 ./scripts/verify.sh；在 Xcode 选择个人 team 和真实 iPhone 后 Build & Run。缺少设备或开发者账号时记录阻塞，不写通过。

提交建议：`docs(platform): 环境、签名与真机基线`。验收未通过时保留未完成状态，不把任务清单勾为成功。
