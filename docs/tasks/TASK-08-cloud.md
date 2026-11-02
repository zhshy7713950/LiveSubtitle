# TASK-08：BYOK 文本接口与 SSE

状态：未开始。原方案映射：T07 网络部分。参考：[正式方案](../development-spec.md) §§4.2、11。

前置／并行条件：G0 通过；使用 URLProtocol 固定响应和本任务 CredentialStoring 假实现，与 TASK-09 并行。

## 文件所有权

- `LiveSubtitle/Translation/Cloud/`
- `LiveSubtitleTests/Translation/Cloud/`

具体产物：创建 CompatibleChatTranslator.swift、SSEDecoder.swift、CloudConnectionTester.swift、EndpointValidator.swift；测试 SSEDecoderTests.swift、CompatibleChatTranslatorTests.swift、EndpointValidatorTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：Translator、ConnectionTesting、CredentialStoring、CloudProfile、TranslationJob／Update。
- 产出：CompatibleChatTranslator: Translator；CloudConnectionTester: ConnectionTesting；严格 HTTPS endpoint 校验和有界 SSE 解码器。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testRequestContract：完整 URL 不重复拼接，Bearer 只在头；只发 model/messages/stream，源文字只入 user，不带历史／音频／图片／工具。
- [ ] testEndpointRejectsUnsafeConfiguration：拒绝 HTTP、URL 内凭证和密钥配置；跨地址重定向不转发 Key；使用 ephemeral session 且禁内容缓存／Cookie。
- [ ] testEveryUTF8SplitAndSSEBoundary：逐字节分块、多行data、CRLF、注释、role-only、空choices、usage-only均不丢字不崩溃。
- [ ] testFinishRules：DONE 或正常 finish_reason 定稿；截断、拒绝、异常输出失败；忽略 reasoning_content／工具／音频；JSON fallback 只取 message.content。
- [ ] testLimitsAndHTTPFailures：事件64KiB、响应256KiB、译文800用户可见字符边界；401/403/429/5xx和不兼容均失败，绝不自动重试。
- [ ] testConnectionProbeIsFixedText：连接测试只发固定非敏感短句，不读取当前字幕；取消与 late callback 不假造故障。
- [ ] testJobDestinationIsFrozen：发送前更改全局所选profile，job仍仅使用自身cloudProfile；缺失／revision不匹配拒绝，不静默选择另一地址。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：Cloud 层返回服务错误，Scheduler 决定 fallback。每100ms以内节流的累计译文；first-text／总deadline由调度任务的 fake clock 覆盖。固定响应不默认消耗 API 额度。

提交建议：`feat(cloud): BYOK 文本接口与 SSE`。验收未通过时保留未完成状态，不把任务清单勾为成功。
