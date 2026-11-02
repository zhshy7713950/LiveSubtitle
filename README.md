# LiveSubtitle

面向 iOS 27 的跨 App 实时音频翻译与悬浮字幕项目。首版优先验证 Chrome；两种模式均端侧识别，本地翻译或用户配置的 BYOK 文本接口翻译。

## 当前状态

2026-11-02：基础框架阶段。已有 iOS App／单元测试 targets、共享 scheme、Swift 6 数据契约、模块协议和集中初始参数。App 只有说明性空壳，**尚未实现采集、识别、翻译、PiP 或正式设置界面**。

模块实现目录只有占位文件。测试 target 目前只有编译入口，没有行为用例；构建成功不能当作真机链路或产品功能验证通过。

## 从这里开始

- [正式开发方案 v1.0](docs/development-spec.md)：产品、技术、初始参数、G0、A01–A24；后续开发的事实来源。
- [本次框架边界](docs/scaffold-design.md) · [架构与契约](docs/architecture.md) · [项目约束](docs/project-constraints.md)。
- [15个开发任务、依赖和多 agent 使用方法](docs/tasks/README.md) · [后续开发计划](docs/plans/2026-11-02-development.md) · [交接模板](docs/tasks/HANDOFF.md)。
- [Codex 入口 AGENTS.md](AGENTS.md) · [AGENT.md 兼容入口](AGENT.md) · [Claude Code 入口 CLAUDE.md](CLAUDE.md)。
- [当前环境](docs/environment.md) · [框架验证记录](docs/reports/scaffold-verification.md)。

## 打开与构建

需要包含 iOS 27 SDK 的完整 Xcode。打开 `LiveSubtitle.xcodeproj`，选择共享 `LiveSubtitle` scheme。

```bash
./scripts/verify.sh
```

脚本检查文档／工程，并无签名构建设备 Debug、设备 Release、模拟器 App 和测试 bundle；日志位于被忽略的 `build/logs/`。这不执行行为测试，也不验证 G0。

未来增加测试后，选取已安装的 iOS 27+ 模拟器 UDID 运行：

```bash
xcrun simctl list devices available
./scripts/test.sh '<simulator-UDID>'
```

真机安装：复制 `Config/Local.xcconfig.example` 为被忽略的 `Config/Local.xcconfig`，填写个人 DEVELOPMENT_TEAM，在 Xcode 确认 bundle identifier 可签名后 Build & Run。不把个人签名材料提交仓库。正式采集与后台能力必须先完成 TASK-01、TASK-02/G0。

## 目录

```text
Config/                    集中构建配置与 Info.plist
LiveSubtitle/App/          SwiftUI 入口和说明空壳
LiveSubtitle/Contracts/    Sendable 模型、协议和 RuntimePolicy
LiveSubtitle/<模块>/       后续任务的独立实现目录
LiveSubtitleTests/         纯逻辑测试入口和模块测试目录
docs/tasks/               任务卡、依赖、所有权、交接
docs/reports/             框架实测和后续真机报告模板
scripts/                  框架检查与测试运行入口
```

新增 Swift 文件自动进入对应 target，普通模块任务无需修改 Xcode 工程。Codex 与 Claude Code 使用不同 worktree／分支；先通过 G0，再冻结契约并按任务卡并行开发。

仓库：[zhshy7713950/LiveSubtitle](https://github.com/zhshy7713950/LiveSubtitle)，SSH remote：`git@github.com:zhshy7713950/LiveSubtitle.git`。
