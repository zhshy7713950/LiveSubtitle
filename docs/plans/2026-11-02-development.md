# LiveSubtitle 后续开发计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 仅在工具具备这些技能时使用；项目约束、文件所有权和用户指定的执行方式始终优先。当前只交付计划，不执行业务开发。

**Goal:** 在现有框架上完成 iOS 27 跨 App 端侧识别、本地／BYOK 文本翻译与 PiP 字幕，并取得真实设备验收证据。

**Architecture:** 一个 App、一个纯逻辑测试 target。固定 Sendable 模型和 Ports 隔离任务；会话身份由 SessionCoordinator 拥有，各模块独立开发，最后单一集成人装配。

**Tech Stack:** Swift 6、SwiftUI、ScreenCaptureKit、Speech、Translation、URLSession、AVKit、Keychain、XCTest。

**Spec:** [正式开发方案](../development-spec.md)。本次框架范围另见 [框架边界](../scaffold-design.md)。

## Global Constraints

- Deployment target：iOS 27.0；不兼容 iOS 26。
- 两种模式均本地识别，不上传音频和屏幕画面；无历史和导出。
- 默认 local、英文→zh-Hans 可修改建议、双语、最近三段；N 范围1～10。
- 音频最多两秒；字幕最多十段；AI并发2、本地1、待执行4；总deadline六秒，首文本三秒，自动重试0。
- 同段AI提交至少800ms间隔，最多2 provisional＋1 final；输入120、有效译文800用户可见字符。
- 可回改窗口30秒／2000用户可见字符先到为准；SSE64KiB／响应256KiB；渲染上限10fps。
- AI故障锁定本地，用户固定句验证后手动恢复；所有结果与错误副作用前检查归属和代次。
- 私人签名不提交，未做的真机验证不写通过。详见 [统一约束](../project-constraints.md)。

## Review Focus

1. 快速停止重启、旧PiP／AI错误、有效deadline：TASK-03/06/10必须各自验证，不吞真正timeout。
2. 十分钟volatile累计增长和最终范围跨检查点：TASK-05/06验证文字、字幕、版本索引有界。
3. UTF-8任意拆分、空SSE、拒绝／截断／超大响应：TASK-08逐类验证；不展示reasoning。
4. PiP恢复、被替换与明确关闭：TASK-03/11区分事件并校验sessionID，不能后台无字幕继续采集。
5. 修改profile／Key、本地模式、首次重装：TASK-09/12/13验证不偷发字幕、不保留凭证或正文。

## 任务步骤

精确文件、消费／产出接口、具名验收、逐步执行和提交要求见 [15张任务卡](../tasks/README.md)，不在这里复制接口签名。

- [ ] TASK-01：完成设备与签名基线；无签名构建不能替代安装。
- [ ] TASK-02：G0真实完整链路十五分钟，失败先报告并修正平台假设。
- [ ] TASK-03～12：冻结契约后独立worktree并行，各自测试和交接，不相互改目录。
- [ ] TASK-13：按交接装配、移除验证空壳、全量测试和生命周期联调。
- [ ] TASK-14：A01–A24、100段性能／质量、三十分钟稳定性报告。
- [ ] TASK-15：干净checkout复现安装与内测交接；不默认公开发行。

集成人先确认每个任务的前置证据，再分配任务卡；不因计划已存在就执行后续业务。所有步骤当前保持未勾选。
