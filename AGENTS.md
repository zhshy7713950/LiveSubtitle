# LiveSubtitle — Codex 项目入口

先读本文件，再读 `docs/project-constraints.md`、`docs/architecture.md`、当前分配的 `docs/tasks/TASK-*.md` 和其中引用的正式方案章节。

- 产品事实来源：`docs/development-spec.md`；`docs/environment.md` 记录环境事实。缺少真机证据时不得宣称可用。
- 当前交付是基础框架，业务尚未实现；没有明确指派任务时，不顺便开发功能。
- iOS 27.0、Swift 6、单 App 和单测试 target；无第三方运行时依赖、服务端或广播扩展。
- 只修改任务卡列出的目录。公共 `Contracts`、`Config`、Xcode 工程和 App 装配由集成人统一修改；需求通过任务交接提出。
- 多 agent 使用独立 worktree／分支；禁止在同一工作目录并发切分支、改索引或提交。不要覆盖其他 agent 的工作。
- 媒体/转写不落盘、不上传；AI 只发当前段文字，且由用户显式启用。Key 只在 Keychain；日志不含内容和密钥。
- 所有异步事件先校验所属作用域：采音／识别／分段绑定 sessionID+languageEpoch，PiP绑定sessionID；翻译结果及故障额外校验完整代次、段版本和截止时间。主动取消不是 AI 故障；有效 deadline 必须触发超时事件。
- MainActor 管 UI／PiP，actor 管会话和调度；跨域只传 Sendable 自有值。禁止用 `@unchecked Sendable` 掩盖媒体对象所有权。
- `RuntimePolicy` 是初始参数唯一来源；协议只是接口，不能返回假成功冒充实现。
- 检查：`./scripts/verify.sh`；有测试后用 `./scripts/test.sh '<iOS 27+ simulator UDID>'`。构建、测试执行、G0 真机三种证据分别报告。
- 结束时按 `docs/tasks/HANDOFF.md` 交接：提交、改动、验证结果、未验证项、契约请求。不得擅自推送、合并其他 agent 分支。

Codex 使用标准文件名 `AGENTS.md`。`AGENT.md` 仅是兼容阅读入口，不是另一份规则。
