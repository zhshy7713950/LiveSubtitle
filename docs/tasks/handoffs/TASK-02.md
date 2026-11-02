# TASK-02 交接

- 基线 commit：`bdee362f6ca5c86e2c567162a7635b5631a4e25b`
- 任务分支 / commit：`codex/task-02-g0`；本交接与实现同一提交，可用 `git log -1 -- docs/tasks/handoffs/TASK-02.md` 查询。
- 前置报告：TASK-01 提交 `199f40b` 中的 `docs/reports/platform-baseline.md`，真机签名和空壳已验证；未擅自合并该任务分支。
- 状态：**未完成**。资源准备、真实共享回调及自有缓冲已验证；用户已确认一次字幕测试成功并提供原文 / 译文小窗观察。回调、样本时钟、字幕去重与显示等待已修正；最新真机 16 项执行通过、2 项模型条件测试跳过，完整 G0 及十五分钟仍待实测。

## 改动

- [G0 真机报告](../../reports/g0-device-report.md) 含 SDK 核对、编译 / 主机检查 / 签名安装结果和续测步骤。
- `LiveSubtitle/Validation/G0/`：四个 SDK 探针、G0AudioInbox、G0RunState、G0ProbeModel、G0ProbeView；全部为临时验证，不是正式 Ports 实现。
- 用户明确授权本任务兼任临时集成人。`LiveSubtitleApp` 仅真机 Debug 接 G0ProbeView；Release / 模拟器保留原空壳。未提交 Config、Contracts、工程、scheme 或脚本变更。
- 本地复用已验证的个人 `Config/Local.xcconfig`，仍被 Git 忽略。
- `LiveSubtitleTests/Validation/G0/G0StateTests.swift`：十三项真实边界检查，同源支持主机可执行检查及 iOS Swift Testing；不镜像 SDK 或伪造媒体结果。

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
| 主机纯逻辑检查 | Swift 6，13 项 | 执行通过；含有理数样本时钟回归，截止推进时钟不真实等待 | 不含 SDK、模型或设备行为 |
| `scripts/test.sh ...` | 无 simulator runtime | 未执行 | 不把 simulator 编译称为执行 |
| 真实 iPhone `xcodebuild ... test` | Swift Testing 18 项发现 / 4 suites | 退出码 0，16 项实际执行通过、2 项未 ready 跳过；前一轮 17 项全执行通过并完成短句翻译对照 | 含后台 observer 回调、两项合成 PCM / Speech 交接；不代表完整 G0 通过 |
| 真机 Debug 签名及严格 codesign 校验 | 已连接 iPhone 17 Pro | 退出码均为 0 | 不证明媒体能力 |
| devicectl 安装 / 启动 | 修复后的 G0 构建 | 退出码均为 0，Device Hub 观察到资源和共享流程 | 另有用户原文 / 译文小窗短轮观察，后台持续性未验收 |
| 独立只读审查 | 代码与 SDK 边界 | 已修复发现的启动、准备、超时和指标问题；重点修复已复核 | 不是运行证据 |
| TASK-02 四项媒体证据 / 十五分钟 / 生命周期 | 真机 | 部分短轮观察 | 用户已确认字幕测试成功；无十五分钟及生命周期完整证据，未写 G0 pass |

## 契约请求

- 无。没有改动公共接口。
- iPhoneSimulator SDK 没有 ScreenCaptureKit，探针仅真机 Debug 编译；模拟器只编译纯逻辑和空壳。此边界已写入报告。
- 后续真机如要求额外 entitlement / 后台能力，先记录证据并提出请求；当前不擅加。

## 未验证与已知问题

- 翻译及英文识别资源已在真机完成准备；已有自有缓冲与用户原文 / 译文 / PiP 显示观察；Chrome 非静音指标、后台持续刷新、十五分钟稳定性、RSS / 热状态、关闭 / 恢复 / 撤销 / 锁屏仍待实测。
- PiP 使用 MainActor UI 代理桥接；系统实际回调、渲染启动和释放行为仍须真机执行，不以编译代替。
- 未推送、未合并 main；保留工作树和本地构建产物供继续测试。
- TASK-13 必须删除临时 Debug 入口并清理 G0 样板；当前 G0 未通过，不能启动正式模块扩展。

## 本次故障续修

- 将统一的资源准备转圈细分为翻译系统会话、语言下载、安装核对、非 UI 就绪检查和英文识别资源阶段；系统首次下载本次约 72 秒完成，没有伪造进度百分比。
- 真机确认共享时发现原 observer 的 MainActor 假设错误，崩溃栈为后台 XPC 回调的 Swift executor 断言。新 `G0CaptureCore` 是 NSLock 保护的非隔离 NSObject，不声明 Sendable；SDK 对象留在其内部，只有值事件进入主线程任务。
- MainActor driver 对迟到 start / stop completion 先完成 SDK 生命周期收尾，再过滤 UI 事件，避免取消后的等待者无法释放。
- 新增 `G0CaptureCallbackTests` 真机回归，覆盖实际 observer 在后台接收协议回调；原失败与最终验证结果分别见 G0 报告。本次没有改动公共契约、工程或 Config。
- 回调修复后收到缓冲，发现 Speech 结果流报错 17；合成对照证明浮点截断会导致一帧重叠，真实元数据又证实采集时钟本身存在一帧偏差。最终 `G0AudioTiming` 以实际 PCM 帧数连续推进识别时钟，CoreMedia 有理数 PTS 仅用于锚点、断流和偏差观测；生产与带偏差回归同源使用。没有丢弃音频或猜测权限 / category；偏差峰值可在指标核对。
- 新增 `G0SpeechInputTests` 两项真机合成静音对照，串行操作音频会话；原文 / 音频不存储、不上传。该时钟修复阶段的 12 项 iPhone Swift Testing 与 9 项主机检查已实际通过，剩余正式 G0 证据仍按报告分别保留。

## 本次字幕交互续修

- 移除主界面 / PiP 的待译占位，原文只显示一次；音频范围修订保留同一行，最终稿合并多个临时行后清理旧行和作业，离散时间的相同话语仍分开。四项新增回归红→绿；原有截止和旧结果校验保留。
- 准备 / 安装核对 / 翻译全部采用 `.lowLatency`，PiP 按 RuntimePolicy 上限处理文字变化，稳定文字约 1 fps 心跳；新增有效译文及排队耗时指标。
- 三条合成短句的热态中位耗时默认 0.034 秒、低延迟 0.025 秒；不是实际视频端到端数字。资源就绪在不同测试启动间有变化，已明确记录一次 notInstalled 失败、一次完整成功对照和最终两项条件跳过，未静默下载或伪造测试通过。
- 本轮最终 verify / 主机 13 项 / 真机 16 项通过（另 2 项模型检查跳过）；签名安装启动退出码均为 0。交互修正版仍需用户视频复测；完整过程见 G0 报告。不修改公共契约、Config 或工程。
