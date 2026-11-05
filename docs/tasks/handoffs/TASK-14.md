# TASK-14 交接

- 基线 commit：`a1c57879efbcb734ad5c3560385db72f15b6b7b3`（fetch 后的 `origin/main`，TASK-13 已合入）。
- 任务分支 / commit：`codex/task-14-validation` / 本交接所属提交。
- 前置报告：[TASK-13](TASK-13.md)、[G0](../../reports/g0-device-report.md)。G0 仍未完成，不转写为通过。
- 状态：**未完成（验收有失败和阻塞）；本次测试及报告交付待审查**。2026-11-05 用户已配合授权，最小采音通过，正式入口被 PiP 启动失败阻断；详情见续验记录。

## 2026-11-04 执行计划与结果

依据 TASK-14 和正式方案 §§15–16.1 执行，不修改生产业务目录或新增产品设计。

- [x] fetch 最新 main，建立独立工作区／分支，记录基线；原目录的 main、工程改动和 .claude 内容保持原状。
- [x] 读取约束、任务、前置报告和模板，核对版本及真实设备。
- [x] 基线执行 verify 和真机当前全量，分别记录编译与实际行为测试。
- [x] 在 Acceptance 内增加固定 HTTP／SSE 跨模块回归，实际运行并保留缺陷，不越界修生产代码。
- [x] 核对正式 UI 与共享入口，填写 A01–A24、性能口径、缺陷和阻塞，按用户选择取消共享。
- [x] 独立只读审查并按建议强化测试；执行最终全量、工程检查及差异核查。
- [ ] 正式 Chrome A01–A24 全部通过、至少 100 段延迟/人工质量样本、三十分钟资源曲线。当前均未满足，不勾选任务卡成功。

## 改动

- `LiveSubtitleTests/Acceptance/AcceptanceCloudTests.swift`：6 个测试方法，含 9 种故障、3 种分块种子和 2 种开放 SSE 参数；覆盖故障锁定、真实固定句恢复、首文本超时、增量显示、主动 HTTP 取消和快速重启。
- `AcceptanceCaptionTests.swift`：3 个方法，验证 N=3→1→10→3 / 双语及仅译文的精确最新段布局、身份及采音/识别次数不变、本地翻译次数不增加；复现 checkpoint 第 11 句丢失及 final 合并残留行。
- `AcceptanceHTTP.swift`、`AcceptanceRig.swift`、`AcceptanceLocalSession.swift`：任务私有测试支持。真实 SessionCoordinator、AudioPipeline、CaptionSegmenter、TranslationScheduler、CaptionStore、CompatibleChatTranslator、AppleLocalTranslator、CloudConnectionTester 参与组合；捕获/识别、资源、PiP、显示接收器和本地 SDK seam 是明确 doubles。不是生产 SubtitleRenderer 或真实 SDK/PiP 的端到端测试。
- [验收报告](../../reports/acceptance-report.md)：24 项矩阵、版本、R01–R05、测试记录及后续责任。
- [性能报告](../../reports/performance-report.md)：有效端到端样本 0/100、人工质量 0/100、三十分钟 0 秒；P95、内存/队列曲线、热状态均 N/A。写明后续无正文采样字段和起点，不用自动测试耗时充数。

### 类型与 initializer

没有新增生产类型、公共协议遵守者或装配入口；无需 TASK-13 接入新的生产 constructor。

- `@MainActor AcceptanceRig(response: AcceptanceHTTP.Response = .json, mode: RequestedMode = .ai, pip: (any PiPControlling)? = nil)`；`start() async throws`、`emit(_:at:stream:) async`、`waitForTranslation(_:) async throws`、`cleanup() async`。
- `AcceptanceHTTP: URLProtocol`，`Response.sse(seed:staysOpen:padding:)` 产生固定字节分块。SDK 的 URLProtocol 要求重述继承的 `@unchecked Sendable`；所有自有共享状态均在 Mutex 中，不传媒体对象，不规避媒体所有权规则。
- `AcceptanceLocalSession(calls: AcceptanceLocalCalls): LocalTranslationSession`；只在测试中返回固定文本，计数器不保留正文。
- 复用现有 `Task10Clock`、Integration 和 Session 的测试边界工具；不修改公共 Support、其他 owner 测试或参数。

### 有界、取消与隐私

本任务没有新增 AsyncStream 实现；生产流沿用原实现。HTTP 按每个 rig 的唯一 .invalid host 隔离，所有未知请求在 transport 内失败，配置只用于隔离 URLSession，不访问真实服务。测试响应/请求体只在内存；正常结束及抛错都先 await session.stop，再移除该 host 的记录。开放响应随真实 translator 取消关闭，不用阻塞 semaphore。

超时使用注入时钟推进，不真实等待三秒/六秒；SSE 两秒真实窗口只是异步观测 watchdog，虚拟作业时钟保持不变。补 4096 字节注释的阳性对照，以区分传输未交付和小流未解析；断言首个非空前缀，避免把 100ms 累计文本限频混入此缺陷。

网络和文本都是合成夹具，未读取/使用用户 AI Key，未调用付费服务，未录制屏幕/音频或保存真实字幕。只读取得设备/Chrome 版本；设备标识、签名参数和本机长日志不进提交。

## 2026-11-04 验证

环境：2026-11-04，Xcode 27.2（27B52）、SDK 27.2、Swift 6；iPhone 17 Pro / iOS 27.2（24B119），Chrome 156.8078.54，App 0.1.0（1）。没有 simulator runtime 或有效 simulator UDID。

真机命令以下述形式执行，设备标识已脱敏；测试全部串行 target 执行，不把 XCTest 空入口的 0 tests 当作 Swift Testing 结果。

```sh
xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -configuration Debug \
  -destination 'platform=iOS,id=<本机设备UDID>' -derivedDataPath build/acceptance-device \
  -resultBundlePath build/reviewed-tests.xcresult -parallel-testing-enabled NO \
  -only-testing:LiveSubtitleTests test
```

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 / 限制 |
| --- | --- | --- | --- |
| 基线 scripts/verify.sh | Debug / Release / generic simulator App 与测试 bundle | 退出 0 | 仅编译，无行为/G0证据 |
| 基线真机全量，baseline-tests.xcresult | 192 方法 / 27 suites | 192 通过，0 跳过，退出 0 | 固定输入/模块回归 |
| 新增首轮，acceptance-first.xcresult | 8 方法 / 2 suites | 3 失败，退出 65 | 显示测试超时暴露第 11 句问题，SSE 和 final 合并失败 |
| 新增复核，acceptance-second.xcresult | 9 方法 / 19 参数展开实例 | 6 方法通过，3 失败，退出 65 | 将第 11 句拆为 A14；时间对齐合并样本后依然失败 |
| 开放流阳性对照后全量，final-tests.xcresult | 201 方法 / 29 suites | 197 通过，4 失败，0 跳过，退出 65 | R01–R03；额外既有 testQueueOverflowAtDeadline 波动 R05 |
| 调度套件复核，scheduler-recheck.xcresult | 6 方法 / 1 suite | 6/6 通过，退出 0 | 不推翻首轮全量失败；未修改其他 owner 的测试 |
| 最终全量，reviewed-tests.xcresult | 201 方法 / 29 suites；新增 9 方法展开 20 实例 | **198 通过，3 失败，0 跳过、0 expected failure；退出 65** | R01–R03 稳定复现；既有 192 项这轮全部通过 |
| 最终 scripts/verify.sh | 文档/plist/scheme、Debug、Release、generic simulator App 与测试 bundle | 退出 0 | 不等于测试通过 |
| scripts/test.sh '' | 无有效 simulator UDID | usage / 退出 2 | 未执行模拟器行为测试，未伪造目标 |
| 正式 App 启动与 Device Hub 观察 | 本轮测试构建实际部署，前台打开至共享系统选择器 | 入口可达；两类资源均显示就绪；源/目标当前值为空，候选菜单有内容 | 用户明确暂不授权共享，取消后返回 App；未验证 Chrome/PiP |
| git diff --check、scripts/check_docs.py | 本任务全部差异 / 文档链接 | 通过 | 全部新文件在 TASK-14 所有权和自己的交接范围内 |

完整原始结果只留本机忽略的 build；Xcode 自动诊断收集有报错，未影响 xcresult 生成。既有 G0 SDK 测试产生主线程音频会话提示，正式入口有 Picker 标签提示；不声称零运行警告。

## 审查与处理

使用 `superpowers:requesting-code-review` 独立只读审查一次。审查确认 R01–R03 有生产来源，新增交付无 Critical / Important 问题。根据建议修正测试显示 sink 的措辞、SSE 冻结时钟/限频夹具，补开放流阳性对照、最后 N 段精确 ID 和本地调用次数断言；最终全量验证这些修改。没有第二轮独立复审或未处理的审查小项。

既有 R05 在本轮全量失败、独立套件及最后全量通过。源码只等 failed 后就断言下一事件 fallback 的数量，可能受异步消费调度影响；这一解释与 TASK-13 交接一致，尚未证明唯一原因，不越界改测试或生产代码。

## 契约请求与 owner 交接

1. **R01 → TASK-08**：修复小型开放 SSE 在 4096 字节/EOF 前不解析的问题，保持字节上限、首文本超时与取消语义；运行 A09 无 padding/有 padding 对照及全量。
2. **R02 → 集成人 + TASK-03/06**：沿用既有请求，`CaptionStoring` 当前没有删除段方法；建议增加 `func remove(segmentID: UUID) async`，在已校验事件作用域的协调器中删除 store、同步 scheduler 并刷新显示。补 remove 后晚到翻译拒收/最终合并唯一行回归。公共契约和消费者由集成人统一变更。
3. **R03 → TASK-06**：有界 checkpoint rollover 不得吞掉触发上限的有效语句。保留窗口与队列限制，不能只增大 RuntimePolicy；运行第 11 句回归和长时无 final 边界。
4. **R04 → TASK-12**：核对 SDK locale 与默认 en / zh-Hans 的 tag 显示。当前只证明空当前值、菜单有候选和日志 tag 提示，不断言唯一根因。
5. **R05 → TASK-10**：稳定既有队列截止测试的事件消费同步，保留本轮波动证据；不能简单删除数量断言。
6. **性能采样 → TASK-13 协调 04/05/06/10/11**：现有诊断只有状态/故障/stop 耗时，尚无完整生产阶段指标。接入无正文、统一单调时钟/PTS、段修订及结果关联的采样；stop 清空和 256 项环不能冒充完整 100 段数据。详见性能报告；需要新字段/出口时由集成人评审，TASK-14 未改公共文件。

## 未验证与已知问题

- G0 未完成；Chrome MP4/HLS/嵌入/直播、切站、路由、真实 Speech / Translation、PiP 关闭恢复替换、锁屏/来电及三十分钟未测。初轮用户不授权；2026-11-05 已授权，但 R06 阻断完整链路。
- 真实延迟、RSS/队列曲线、热状态、100 段双语质量没有有效样本；无真实 AI 服务性能结论。
- TASK-13 已记录的启动选择器等待中停止、真实 PiP completion 时机等仍待原 owner 处理，不能以本次运行中停止回归覆盖。
- 当前四项普通失败回归（初轮三项及本轮 R07）未跳过、未标 expected-failure；TASK-14 和 TASK-15 内测门槛未通过。分支应作为缺陷证据审查，不能据此发布“验收完成”。
- 独立分支/worktree保留供审查；按项目要求未推送、未合并，未修改原目录未提交文件。

## 2026-11-05 续验交接

- 本轮起点：cb12919；fetch 后 origin/main 仍为 a1c5787。真机与系统/Chrome 版本未变；没有合并其他分支。
- 用户选择公开 Apple WWDC25 Platforms State of the Union，并实际配合系统授权。最小采音通过；正式 App 采集启动返回成功后，在 startPiP 同步抛 pipFailed，随后 componentFailure 停止。安全阶段/枚举断点多次复现同一顺序；已删除全部断点并成功 detach，诊断会话与共享页已退出。
- 当前 A01–A24：3 pass、4 fail、17 blocked；A03 由未授权 blocked 改为有真实失败证据的 fail。Chrome 播放、100 段延迟/质量、三十分钟仍无有效数据，不能把采音测试的等待授权时间计为播放或性能。

### 新增改动

- AcceptanceRig 仅增加可选 PiP 测试边界注入，默认仍使用原来的 FakePiPControlling，既有调用不变。
- AcceptanceStartupTests.testA03StartupFailureRemainsVisibleAfterCleanup 使用真实会话及字幕/调度模块，在 PiP 边界明确抛 pipFailed；验证清理后应保留 failed 和安全故障原因，同时 identity/source/renderer 必须清空。当前实际为 idle/nil，普通断言稳定失败，未设 expected-failure。
- 两份报告追加当日设备与测试事实，并保留 2026-11-04 的历史失败/复核记录；没有覆盖失败或修改生产目录。

### 本轮验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 限制 |
| --- | --- | --- | --- |
| 真机验收套件，acceptance-20261105.xcresult | 9 方法 / 2 suites | 6 通过、3 失败、0 跳过；退出 65 | R01–R03 未修复 |
| 现有 TASK04_INTERACTIVE 最小采音 | 1 方法 / 1 suite | 1/1 实际通过、0 跳过；退出 0 | 收到有效非空自有 PCM，stop 后流结束；不等于非静音 Chrome / Speech / Translation / PiP |
| 正式入口与安全枚举诊断 | 用户手选 en_US → zh-Hans-CN，本地模式 | 选择回调、采集成功返回，继而 pipFailed / componentFailure | R06；两个 PiP 可用性布尔值及首帧状态尚未分别测量，不能宣称硬件不支持 |
| R07 新回归，startup-failure-20261105.xcresult | 1 方法 | 2 条错误保留断言失败，清理断言通过；退出 65 | 未越界修复 Session |
| 本轮完整真机，full-acceptance-20261105.xcresult | 202 方法 / 30 suites | 197 通过、5 失败，0 跳过、0 expected failure；退出 65 | R01/R02/R03/R07 加既有 R05，合计 6 条断言问题；未重跑以掩盖波动 |
| Activity Monitor 资源预检 | App 名称/PID 附加 | 未获得有效 trace | 不作为内存/CPU 超限结论 |
| 最终 scripts/verify.sh、check_docs.py、git diff --check | Debug / Release / generic simulator App 和测试 bundle；文档及差异 | 退出 0 / 检查通过 | 仅编译，不抵消行为测试失败 |

最小采音测试只通过命令行 SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG TASK04_INTERACTIVE 打开已有交互测试；没有编辑 TASK-04 测试、工程或 Config。完整真机随后恢复正常 Debug 条件，不包含该交互测试；本轮无有效 simulator runtime，未执行模拟器行为测试。原始结果和诊断仅在忽略的 build/ 或临时目录，提交不含设备标识、签名参数、正文或媒体。

### 新的 owner 请求

- **R06 → TASK-11 + TASK-13 集成人**：真实采集已启动，PiP start 同步失败。核对 isSupported/isPossible 及 renderer 首帧、挂载、激活和 Session 刷新顺序；对尚未 ready 的情况设计有界等待与取消，新增参数由集成人放入 RuntimePolicy，不能返回假成功绕过系统状态。修复后重新执行本次真实授权步骤，确认 PiP 实际显示，才进入 Chrome 播放。
- **R07 → TASK-03**：启动失败的安全 FailureCode 必须跨资源清理保留，并使最终状态为 failed；当前已有 identity 时未设置 terminalFailure，stop 的 nil 新故障在 performStop 后覆盖了 pipFailed。运行新增用例，并保留主动取消的正常 ready/无故障语义以及旧代次隔离。
- **R04**：手动选择后界面可以显示具体语言；默认/异步能力加载时仍出现 tag 提示，保留原 owner 核对，不断言候选列表为空。

本轮未修改生产实现，下一阶段先由相应 owner 修复启动阻断与已知失败，再继续剩余验收。无需用户再改权限设置或重复点击共享。

本轮独立只读审查复核了 R07 的真实 coordinator 清理路径、PiP 注入默认行为及 R06 的证据边界；已修正缺陷表断行和历史/当日记录措辞。未发现新增测试/报告的 Critical 或 Important 问题；生产失败保持未修复并按 owner 请求交接。
