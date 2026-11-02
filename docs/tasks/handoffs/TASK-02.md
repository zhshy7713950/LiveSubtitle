# TASK-02 交接

- 基线 commit：`bdee362f6ca5c86e2c567162a7635b5631a4e25b`
- 任务分支 / commit：`codex/task-02-g0`；本交接与实现同一提交，可用 `git log -1 -- docs/tasks/handoffs/TASK-02.md` 查询。
- 前置报告：TASK-01 提交 `199f40b` 中的 `docs/reports/platform-baseline.md`，真机签名和空壳已验证；未擅自合并该任务分支。
- 状态：**未完成**。探针已签名安装并启动，G0 媒体链路及十五分钟实测待用户方便时继续。

## 改动

- [G0 真机报告](../../reports/g0-device-report.md) 含 SDK 核对、编译 / 主机检查 / 签名安装结果和续测步骤。
- `LiveSubtitle/Validation/G0/`：四个 SDK 探针、G0AudioInbox、G0RunState、G0ProbeModel、G0ProbeView；全部为临时验证，不是正式 Ports 实现。
- 用户明确授权本任务兼任临时集成人。`LiveSubtitleApp` 仅真机 Debug 接 G0ProbeView；Release / 模拟器保留原空壳。未提交 Config、Contracts、工程、scheme 或脚本变更。
- 本地复用已验证的个人 `Config/Local.xcconfig`，仍被 Git 忽略。
- `LiveSubtitleTests/Validation/G0/G0StateTests.swift`：八项真实边界检查，同源支持主机可执行检查及 iOS Swift Testing；不镜像 SDK 或伪造媒体结果。

## 类型与装配

- `G0ProbeView()` 为临时 Debug 根视图，无参数；由其持有 `G0ProbeModel()`。
- `G0CaptureProbe(inbox: G0AudioInbox, identity: SessionIdentity)`、`G0SpeechProbe()`、`G0PiPProbe()`、`G0RunState(clock: any MonotonicClock = G0Clock())`；G0TranslationProbe 为任务局部异步静态操作集合。
- G0ProbeModel 持有 SDK 生命周期；G0RunState actor 是临时身份与调度权威，Speech actor 管转换与识别。跨域媒体只传自有值或 SDK 的 Sendable AnalyzerInput，无 `@unchecked Sendable`。
- 音频队列加在途 PCM 共用两秒预算，输入为按需拉取序列；控制故障不与音频争抢可丢弃缓冲。超限明确失败。
- 翻译一个执行中、最多四个等待；最多十段文字、每段及译文按 RuntimePolicy 有界。段修订 / 保留状态 / 完整身份 / 截止检查均在 actor 内执行。
- 停止失效身份，取消并等待启动、资源准备、翻译、指标任务；取消识别并释放自己的 locale reservation，停止采集 / PiP，释放本轮渲染同步器，清空全部字幕。仍需系统场景实测。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未验证范围 |
| --- | --- | --- | --- |
| 最终 `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0；Debug、Release、simulator App / 测试 bundle 编译通过 | 不执行测试或媒体链路 |
| 主机纯逻辑检查 | Swift 6，8 项 | 执行通过；截止测试推进时钟、不真实等待 | 不含 SDK、模型或设备行为 |
| `scripts/test.sh ...` | 无 simulator runtime | 未执行 | 不能称为 iOS 单元测试通过 |
| 真机 Debug 签名及严格 codesign 校验 | 已连接 iPhone 17 Pro | 退出码均为 0 | 不证明媒体能力 |
| devicectl 安装 / 启动 | 最终 G0 构建 | 退出码均为 0 | 尚无用户对 G0 画面及运行链路的确认 |
| 独立只读审查 | 代码与 SDK 边界 | 已修复发现的启动、准备、超时和指标问题；重点修复已复核 | 不是运行证据 |
| TASK-02 四项媒体证据 / 十五分钟 / 生命周期 | 真机 | 未执行 | 用户表示稍后才能配合，未写 G0 pass |

## 契约请求

- 无。没有改动公共接口。
- iPhoneSimulator SDK 没有 ScreenCaptureKit，探针仅真机 Debug 编译；模拟器只编译纯逻辑和空壳。此边界已写入报告。
- 后续真机如要求额外 entitlement / 后台能力，先记录证据并提出请求；当前不擅加。

## 未验证与已知问题

- 识别 / 翻译资源、真实采音、Chrome 出声、原文、译文、PiP 显示、十五分钟稳定性、RSS / 热状态、关闭 / 恢复 / 撤销 / 锁屏场景均待实测。
- PiP 使用 MainActor UI 代理桥接；系统实际回调、渲染启动和释放行为仍须真机执行，不以编译代替。
- 未推送、未合并 main；保留工作树和本地构建产物供继续测试。
- TASK-13 必须删除临时 Debug 入口并清理 G0 样板；当前 G0 未通过，不能启动正式模块扩展。
