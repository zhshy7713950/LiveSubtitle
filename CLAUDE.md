# LiveSubtitle — Claude Code 项目入口

@AGENTS.md
@docs/project-constraints.md

开始任务前再阅读 `docs/architecture.md`、`docs/tasks/README.md` 和分配的任务卡。

- 与 Codex 使用同一份约束、同一套 Contracts，不另建 Claude 专属接口或实现副本。
- 一个会话只实现分配的任务；使用独立 worktree／分支，不和另一个 agent 共享工作目录。
- 当前仓库是框架交付，采集、识别、翻译和 PiP 尚未实现；不要把目录占位误当作已完成的功能。
- 不把字幕、真实服务响应、Key 或个人设备标识写入项目记忆、任务交接和公开报告。
- 提交前运行任务卡要求的检查；按 `docs/tasks/HANDOFF.md` 报告，未经执行的检查写明未执行。

入口依据：[Codex AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、[Claude Code 项目记忆](https://code.claude.com/docs/en/memory)。本项目使用显式导入共享规则，避免维护两套规则文本。
