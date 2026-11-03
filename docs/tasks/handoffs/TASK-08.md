# TASK-08 交接

- 基线 commit：`f09aaa529675060e5d2463a3606587cf4a4aeb89`（`origin/main`）。
- 任务分支 / commit：`worktree-task08-cloud`；实现与测试提交 `d126e4d`，最终修正及本交接见分支后续提交。
- 前置报告：`docs/reports/g0-device-report.md` 仍标记 G0 未完成；本任务按明确指派独立实现，不据此宣称完整链路或真机能力通过。
- 状态：待审查。

## 改动

- `LiveSubtitle/Translation/Cloud/CompatibleChatTranslator.swift`：实现 `Translator`。每作业只使用冻结的 `job.cloudProfile`、匹配 identity revision 的对应 Key；完整 HTTPS endpoint 原样 POST，请求仅含 `model/messages/stream`，源文仅进入 user 消息。支持累计 SSE 译文、正常 finish／`[DONE]`、JSON `message.content` fallback、失败分类、无自动重试、100 ms provisional 节流及 800 用户可见字符上限。
- `SSEDecoder.swift`：字节级增量解析，支持 UTF-8／SSE 行任意分块、CRLF、注释和多行 data；事件 64 KiB、响应 256 KiB 上限生效。
- `EndpointValidator.swift`：拒绝非 HTTPS、URL user/password、敏感凭证 query、fragment 和空模型。
- `CloudConnectionTester.swift`：实现 `ConnectionTesting`，只发送固定非敏感短句；取消返回 `.preparationCancelled`，不伪造成服务故障。
- ephemeral session 禁用内容缓存和 Cookie；跨源重定向不继续请求，同源重定向只保留同源 Authorization。401／403、429、5xx 分别映射为 `.unauthorized`、`.rateLimited`、`.server`。
- `LiveSubtitleTests/Translation/Cloud/`：固定 `URLProtocol` 响应和任务内 CredentialStoring 假实现；不访问真实接口，不含真实 Key、字幕或设备标识。

## 类型与装配

- `CompatibleChatTranslator(credentials: any CredentialStoring)`：生产默认构造，内部使用 ephemeral session。
- `CompatibleChatTranslator(credentials: any CredentialStoring, configuration: URLSessionConfiguration)`：固定响应测试构造；传入配置也会被强制禁用缓存／Cookie。
- `CloudConnectionTester(credentials: any CredentialStoring)` 与 `CloudConnectionTester(credentials: any CredentialStoring, configuration: URLSessionConfiguration)`。
- `EndpointValidator.validationFailure(for: CloudProfile) -> FailureCode?`、`SSEDecoder.append(_:) / finish()` 为模块内部实现，不改变公共 Contracts。
- 每个 `TranslationUpdate` 保留原 job 的完整 identity、segmentID、sourceRevision，provider 为 `.ai`；text 是累计替换文本，失败时为空。

## 流、上限与取消

- 每作业一个 `AsyncStream<TranslationUpdate>`，显式 `.bufferingOldest(1)`，只保留最新累计 provisional；最终成功或失败随后结束流。
- 消费者取消触发对应 URLSession 任务取消；`cancelAll` 先结束并失效全部作业，再取消、等待网络任务。主动取消不发出 AI 故障。
- SSE 单事件 64 KiB、SSE／JSON 响应累计 256 KiB、累计译文 800 个 Swift 用户可见字符；超限返回 `.invalidOutput`，不保留 provisional AI 文本。
- 不读取全局所选 profile，不读取字幕存储；连接测试没有字幕输入参数。作业 deadline／first-text 超时由 TASK-10 调度负责，本层不真实等待六秒。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0；文档、plist、iOS Debug、Release、generic simulator App 与测试 bundle 编译通过 | 不执行行为测试 |
| macOS 同源 host checks | Swift 6 完整并发检查 | 14 组通过：endpoint 2、SSE 2、translator／connection 10；含逐字节、边界、取消与 late callback | 不证明 iOS 运行时行为 |
| macOS AddressSanitizer / ThreadSanitizer host checks | translator／connection 各 10 组 | 退出码均为 0 | 不证明真实服务或 iOS 行为 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list runtimes` 为空 | 未执行 | 无可用 iOS 模拟器运行时；不以测试 bundle 编译代替测试执行 |
| 任务卡逐项验收 | 固定本地响应 | 七项具名测试均有主机行为证据；HTTP 状态均核对单请求、无自动重试 | iOS 全套测试和真实服务未验证 |

## 契约请求

- 无。未修改 Contracts、Config、App 装配、工程、scheme 或脚本。

## 未验证与已知问题

- 未连接任何真实 Chat Completions 服务；不同厂商的实际鉴权、SSE、finish_reason 和错误响应兼容性仍需集成验证，不自动重试真实字幕请求。
- 无 iOS 模拟器运行时，因此当前全量 Swift Testing 未在 iOS 执行；没有真机网络、后台生命周期或完整 G0 证据。
- TASK-13 需用同一 CredentialStoring 实现分别装配 translator 与 connection tester；模式切换、配置变更、调度取消及 identity 失效由对应模块负责。
- 未推送、未合并 main。
