# TASK-02：G0 真实完整链路可行性

状态：未开始。原方案映射：T02 / G0。参考：[正式方案](../development-spec.md) §§2–3、7–8、12、15 G0。

前置／并行条件：TASK-01 已记录可用真机和签名；本任务单独执行，正式模块开发尚不并行启动。

## 文件所有权

- `LiveSubtitle/Validation/G0/`
- `docs/reports/g0-device-report.md`
- `App／Config 的临时验证入口只由本任务期间的集成人修改`

具体产物：创建最小验证用 G0CaptureProbe.swift、G0SpeechProbe.swift、G0TranslationProbe.swift、G0PiPProbe.swift。验证入口仅 Debug 使用，标明待 TASK-13 清理。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：本机 iOS 27 SDK 与真实 iPhone，参考 Contracts 但不把验证样板冒充正式实现。
- 产出：按 ../reports/G0-template.md 填写的十五分钟证据、SDK 签名核对和 G0 pass/fail 结论。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] 分别验证有自有音频样本、有可理解原文、有本地译文、Chrome 后台 PiP 持续刷新；四项不得合并成“能运行”。
- [ ] SCContentSharingPicker 全屏授权，Chrome 正常出声；采集、后台和 Receiver 入队 API 以本机 SDK 为准。
- [ ] 连续十五分钟无持续积压、模型停止、进程终止；记录机型、版本、时长、最大队列和内存。
- [ ] 区分关闭 PiP、恢复界面、系统采集撤销、锁屏；停止后没有新作业。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：按下列验收和补充要求执行，并如实记录命令、环境和结果。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：本任务以真机证据为主，不要求给 SDK 可行性样板写镜像测试。G0 失败时停止正式模块扩展，报告实际平台限制，不切旧系统或云端采音。

提交建议：`feat(g0): G0 真实完整链路可行性`。验收未通过时保留未完成状态，不把任务清单勾为成功。
