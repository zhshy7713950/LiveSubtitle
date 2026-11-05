# TASK-14 正式验收报告

状态：**未通过，TASK-14 未完成**。首次记录：2026-11-04；续验更新：2026-11-05（Asia/Shanghai）。

## 版本与证据边界

| 项目 | 本轮记录 |
| --- | --- |
| 产品基线 | `a1c57879efbcb734ad5c3560385db72f15b6b7b3`，fetch 后的 `origin/main`，包含 TASK-13 |
| 验收分支 | `codex/task-14-validation`；续验起点 `cb12919`，报告绑定本提交；fetch 后 main 未更新，后续用户授权集成修复，当前实现含生产修改，见本轮续修记录 |
| App | 0.1.0（1），正式入口；真机测试使用 Debug 构建 |
| 工具 | Xcode 27.2（27B52），iPhoneOS / iPhoneSimulator SDK 27.2，Swift 6 完整并发检查 |
| 设备 | iPhone 17 Pro，iOS 27.2（24B119），物理连接；不提交设备标识 |
| Chrome | 156.8078.54（设备已安装版本；不等于本轮已完成 Chrome 播放） |
| 语言对 | 固定回归 en → zh-Hans；2026-11-05 用户在正式入口手选英语（美国）→简体中文（中国），存储标签为 en_US / zh-Hans-CN；两类资源均显示就绪 |
| 网络与 AI | 所有新增 AI 回归由 host 隔离的 URLProtocol 固定响应截获；未知请求在该 transport 内失败。无真实 AI endpoint / 模型 / Key，无真实服务性能样本 |
| 前置 | [TASK-13 交接](../tasks/handoffs/TASK-13.md)已合入；[G0 报告](g0-device-report.md)仍未完成，不能转记为通过 |

`pass` 仅表示该行全部标准已有证据；`fail` 表示已复现违反标准的行为；`blocked` 表示缺前置或执行条件；`not-run` 表示条件具备但本轮未执行。固定响应运行在真机上，仍然不证明 Chrome、真实 Speech / Translation SDK、真实 PiP 或性能达标。失败项不因同一行其他子项通过而改为 pass。

## A01–A24 矩阵

| 编号 | 场景 | pass/fail/blocked/not-run | 证据／实测值／缺陷 |
| --- | --- | --- | --- |
| A01 | 首次资源缺失与取消 | blocked | 正式 UI 本轮可见识别、本地备用翻译两行均为“已就绪”；未重置首次安装环境或删除模型。既有资源 blocker 自动回归通过，未验证首次系统下载及取消 |
| A02 | 不支持语言／语言对 | blocked | 既有 Capability / Features 自动回归已执行；真实不支持语言的前台提示仍欠操作。源/目标 Picker 的当前值为空，但菜单有候选，见 R04；不能据此宣称未返回任何语言 |
| A03 | 英文→简中本地 | blocked | 2026-11-05 正式 App 等用户关闭共享面板返回前台后，用户确认“持续显示小窗，并出现译文和原文”。R06 初始启动阻断已解除；运行状态约 116.75 秒后正常停止。仍欠 Chrome 声音正常、无重复追加及精确播放区间的独立核对，保留未完成，非启动失败 |
| A04 | 下载后断网本地 | blocked | 固定输入本地路径无字幕网络请求的自动回归通过；尚缺离线可播放非敏感英文素材及断网设备步骤 |
| A05 | MP4、HLS、嵌入、直播 | blocked | 四类真实素材本轮均未播放；未登记素材版本/时间范围，声音/字幕/延迟均无实测值 |
| A06 | 切站和切视频 | blocked | 尚无同一真实共享会话跨站证据；不泛化网站覆盖 |
| A07 | 页内、横屏和全屏 | blocked | 正式入口竖/横屏可见；未播放 Chrome 或核对字幕 PiP，不能以主页面旋转替代播放器全屏验收 |
| A08 | 扬声器、耳机、蓝牙 | blocked | AudioPipeline 格式/队列单元回归通过；真实路由切换未测 |
| A09 | AI 正常 SSE | pass | R01 已修复；完整小型 SSE 在 HTTP 保持打开时即可显示累计文本，无 padding/有 padding 对照均通过。固定响应，不证明真实服务性能 |
| A10 | SSE 随机分块和 Unicode | pass | 新增测试以种子 1、42、2026 将 UTF-8/CRLF/空 choices/注释分块，经真实 cloud → scheduler → store → 测试 snapshot sink 后均恰为单份累计译文；既有逐字节/每切点解码测试亦通过。HTTP 结束条件已提供；开放流问题另计 A09 |
| A11 | AI 故障后锁定本地 | pass | 新增跨模块用例实际验证 401、403、429、500、503、异常 JSON、空内容、refusal、断网；每例恰发一个 AI 请求，故障段及后续段本地完成。无首文本响应以测试时钟推进 3 秒触发一次 firstTextTimeout，推进至 6 秒后不重复增代 |
| A12 | 固定句手动恢复 | pass | 真实 CloudConnectionTester 通过固定句探测后恢复 AI；请求体仅含固定句，不含上一段；既有段仍保留 local provider，仅后续新段发送 AI。请求由 URLProtocol 截获 |
| A13 | 修订、错序、晚到、主动取消与有效超时 | pass | R02 已修复；store 删除被合并旧段，最终唯一行及旧结果拒收回归通过。新增旧故障在 snapshot 等待中被淘汰/修订的竞态回归，拒收后保留其余作业、deadline 和预算 |
| A14 | 长句、十分钟无 final、有界文字窗口 | blocked | R03 已修复，第 11 句 rollover 回归通过；600 次合成时间输入的窗口回归通过。仍欠十分钟真实设备无 final 压力，不能以合成输入替代 |
| A15 | N=3→1→10→3 | blocked | 新增真实 coordinator/store/layout 组合回归通过：保留 10 段、最新段可见、可见组数不超 N，不重启采音/识别，无网络请求；固定大尺寸下可见 ID 恰为最后 N 段，本地 SDK seam 调用数在设置前后均为 10。真实 PiP 尺寸/可读性仍未测 |
| A16 | 双语／仅译文 | blocked | 与 A15 同一回归切换两种 style；仅译文布局不出现 source 行，身份不变，本地翻译调用数不增加，也无网络请求；真实 PiP 即时呈现未测 |
| A17 | PiP 关闭与恢复 | blocked | 既有 Session / LifecyclePiP 自动回归通过；系统 PiP 的关闭/恢复入口及 completion 时机未实操 |
| A18 | 撤销采集、锁屏和来电 | blocked | 既有固定通知/撤销/作用域回归通过；没有物理锁屏/来电/撤销后的真实全链路清理证据 |
| A19 | 停止后旧回调及快速重启 | blocked | 新增真实 HTTP 在途取消后推进旧 deadline、重启新 session，只有新字幕、无误回退、无停止期间新请求；既有合成 PCM 清理回归通过。系统选择器/真实 capture 旧回调仍未测 |
| A20 | 其他视频 PiP 替换 | blocked | 既有 double 的 replaced 回归通过；真实另一视频 PiP 抢占未操作，不声称双 PiP |
| A21 | deadline 及队列压力 | blocked | 并发/总截止/修订预算回归通过；R05 已等待 fallback 消费同步，最新全量通过；新增首文本超时跨模块通过。真实 Chrome 音频/翻译积压的最大值、持续丢弃记录缺失 |
| A22 | 停止、重启无历史 | blocked | 新增及既有自动回归验证停止时 renderer/store 清空，重启只有新段；未执行正式设备 App 冷启动后历史/偏好人工检查 |
| A23 | 日志、缓存与网络内容边界 | blocked | 固定输入本地零请求、诊断无正文/Key/endpoint、请求仅当前段和禁缓存的既有测试通过；尚未对真实 Chrome 全链路做日志/网络/容器核查 |
| A24 | 连续三十分钟 | blocked | 正式入口小窗和双语已获用户确认；运行状态区间约 116.75 秒，精确 Chrome 连续播放时长未计量。有效延迟/人工质量样本仍为 0/100，三十分钟未执行；短区间数值见[性能报告](performance-report.md) |

当前矩阵：pass 5 项（A09–A13），fail 0 项，blocked 19 项，not-run 0 项。A03 已获双语小窗证据，但其余标准尚待补验。这里的 pass 严格限定为相应固定响应/逻辑验收，不构成完整产品通过。

## 已复现缺陷与责任归属

| ID | 严重性 / owner | 复现与实际结果 | 处理请求 |
| --- | --- | --- | --- |
| R01 | 高 / TASK-08 Cloud | `AcceptanceCloudTests.testA09CompleteSSEEventsAppearBeforeResponseEnds`；HTTP 留开，三个完整 content 事件总量小于 4096 字节，显示无 AI 文本。相同 UTF-8 内容附 DONE/EOF 的测试通过 | `CompatibleChatTranslator.consumeSSE` 仅在 `buffer.count == 4096` 或流结束时调用 consume；应及时消费完整 SSE 事件并保留事件/响应上限。补开放流/首文本计时回归 |
| R02 | 高 / 集成人 Contracts + TASK-03 + TASK-06 | `AcceptanceCaptionTests.testA13MergedFinalRemovesSupersededRowsFromDisplay`；输出为最终合并行加第二条旧临时行，期望只有最终行 | `consumeSegments(.remove)` 仅更新 retained 索引和 scheduler，CaptionStoring 无 remove 端口；沿用 TASK-03/13 请求新增 `remove(segmentID:) async`，生产 store 删除并刷新，保证旧作业拒收 |
| R03 | 高 / TASK-06 Captions | `AcceptanceCaptionTests.testA14CheckpointRolloverDoesNotLoseAnUtterance`；前 10 段可见，第 11 段缺失，第 12 段又可见 | `TranscriptNormalizer.consume` 在新增第 11 个 checkpoint 时要求 discontinuity；`CaptionSegmenter.closeActive` 将本次 upsert 改为 discontinuity，协调器忽略该事件，导致本句丢失。保留有界性同时处理触发上限的有效文字，不能靠增大阈值掩盖 |
| R04 | 中 / TASK-12 Features | 正式 App 的源/目标行均无当前值；打开源菜单可见语言候选，返回后默认配置仍可进共享选择器；运行日志亦有默认标签未关联 Picker tag 的系统提示 | 2026-11-04 未修改语言选择；2026-11-05 用户手选后可显示具体语言。核对默认/加载阶段的 locale tag 匹配，不把候选列表写成空 |
| R05 | 中 / TASK-10 测试同步待核对 | 2026-11-04 全量曾失败，独立 6/6 及该日最后全量通过；2026-11-05 全量中 `TranslationSchedulerTests.testQueueOverflowAtDeadline` 又因 fallback 数量失败 | 与 TASK-13 已记录波动一致。源码只等待 failed 被消费便断言随后 fallback 的数量，存在异步消费竞态的解释；尚未证明唯一根因。由 owner 加入 fallback 消费条件，保留当前失败记录，不据此声称生产 timeout 丢失 |
| R06 | 高 / TASK-11 + TASK-13 集成人 | 真实正式入口重复出现：picker 更新回调 → 采集启动 code=nil → capture 返回 → startPiP → pipFailed → componentFailure 停止；最小真实采音测试 1/1 通过 | PiPCoordinator.start 在新建 system adapter 后立即要求 isSupported && isPossible，renderer.activate 和首个 snapshot 在其后；需协调首帧、可用性等待、取消与装配顺序。当前仅确认同步 PiP 启动失败，未分别测出两个布尔值，不宣称设备不支持 PiP |
| R07 | 高 / TASK-03 Session | 新增 AcceptanceStartupTests.testA03StartupFailureRemainsVisibleAfterCleanup：PiP 边界抛 pipFailed，清理完成后的 phase 实为 idle、failure 实为 nil；两条断言失败，资源清理断言通过 | startOutcome.failed 在已有 identity 时只写 failure，随后 stop 以 nil 新故障进入清理；performStop 用 terminalFailure 覆盖状态，丢失原因。应在对应启动代次内保留安全故障并呈现 failed；主动取消仍应保持正常取消语义 |

上表描述原始复现及 owner 请求；当前 R01–R05/R07 已实施修复。R01–R03 保留为正常、未跳过的回归，最新全量通过；不使用 expected-failure 或降低断言隐藏缺陷。用户随后明确授权集成修复，生产目录及必要共享接口已在独立分支中修改，详见文末。R04 是人工观察，不冒充新增自动回归。TASK-13 已记录的“选择器等待中停止”已有修复和 stop/cancel/换语言/模式参数回归；本轮已把真实 PiP 启动失败收敛为 R06。R07 另有普通失败回归，未设 expected-failure。

## 2026-11-05 续验

- 真实 iPhone、iOS、Chrome 和工具版本与环境表一致；fetch 后 main 仍是 a1c5787，没有擅自合并其他任务分支。
- 验收套件复测：9 方法 / 2 suites，6 通过、3 失败、0 跳过，退出 65；R01–R03 仍可复现。
- 以命令行临时编译条件 DEBUG TASK04_INTERACTIVE 打开已有 ScreenCaptureAudioSourceDeviceTests，不修改 TASK-04 测试或工程。真实用户授权后 1/1 实际执行通过，0 跳过，退出 0；收到非空自有 PCM、元数据有效，stop 后流结束。17.321 秒测试时间包含等待授权，不是 Chrome 播放时长、非静音或延迟指标。
- 正式入口用户手动授权仍停留在共享页。为定位原因，在本 App 的采集/会话源代码处设置自动继续的诊断断点，只观察固定阶段和安全枚举。多次实际回调顺序均为采集成功后同步 pipFailed 并停止，见 R06；没有记录媒体、转写或 Key。调试断点会扰动时序，因此不计入性能样本；结束时删除全部断点并成功脱离调试器。
- 新增 R07 跨模块回归：1 方法实际执行，2 条状态/故障断言失败，identity/source/renderer 的清理断言通过；退出 65。该用例使用真实 coordinator/pipeline/segmenter/scheduler/store 和明确失败的 PiP double，不弹系统选择器。
- 最终 `./scripts/verify.sh` 退出 0，Debug、Release、generic simulator App/测试 bundle 均编译成功；文档检查及差异空白检查通过。没有模拟器 runtime，不执行模拟器行为测试。
- 本轮完整真机回归 full-acceptance-20261105.xcresult：202 方法 / 30 suites，**197 通过、5 失败、0 跳过、0 expected failure，退出 65**；共 6 个断言问题。失败方法为 R01、R02、R03、R07，以及既有 TranslationSchedulerTests.testQueueOverflowAtDeadline 的 R05 波动；不把 6 条断言写成 6 个失败测试。
- 本轮公开素材登记为 [Apple WWDC25 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2025/102/)。用户选择该素材，但正式入口未通过，尚未在 Chrome 播放；不能填 MP4/HLS/直播覆盖或 100 段样本。
- 资源采样预检中 Instruments 可列设备/模板，但按 App 名称及明确 PID 附加 Activity Monitor 均未获得进程，未产生有效资源数据；这不是内存超标证据。停止真实长时验收的主要阻断仍为 R06。
- iPhone 镜像已连接，键盘可打开 App；本次坐标点按工具返回 noWindowsAvailable。共享选择由用户手动完成，不能把该工具问题写成 iPhone 不支持控制或 App 权限拒绝。诊断会话已结束，系统共享页已退出。

## 2026-11-04 历史执行证据

- 基线 `./scripts/verify.sh`：退出码 0，Debug/Release/generic simulator 测试 bundle 编译通过。
- 基线真机全量：192 个测试方法、27 suites 全部实际执行通过，0 跳过；`TEST SUCCEEDED`。
- 首轮新增：8 个测试方法 / 2 suites，3 个失败；显示设置用例在第 11 句处等待超时，随后拆成独立 A14 用例。
- 第二轮新增：9 个测试方法 / 2 suites（参数展开共 19 个实例），6 个方法通过、3 个失败；失败恰为 R01–R03。显示设置用例改用 10 条以单独验证 N，A14 继续完整保留第 11 句失败；合并样本改为逐字符时间对齐的两段。
- 增加开放 SSE 对照后的首轮全量：201 个方法 / 29 suites，197 通过、4 失败、0 跳过；R01–R03 加 R05。R01 的无 padding 参数失败，4096 字节注释 padding 参数通过，证明同一开放 transport 可以交付首个增量。
- 调度套件独立复核：6/6 实际执行通过，退出码 0；不抹去上述 R05 失败。
- 独立只读审查后强化布局精确 ID 与本地调用次数断言；最终全量 `reviewed-tests.xcresult`：201 个方法 / 29 suites，198 通过、3 失败、0 跳过、0 expected failure，退出码 65。失败恰为 R01–R03；新增 9 方法的参数展开为 20 个实例（17 通过、3 失败）。三个生产问题没有修复，不把最终全量称为通过。
- `./scripts/verify.sh`：最终 Debug / Release / generic simulator App 与测试 bundle 编译通过，退出码 0。`./scripts/test.sh ''`：无可用 simulator runtime / UDID，参数校验退出 2，未执行模拟器行为测试。
- 独立只读审查确认 R01–R03 来源充分；已修正冻结测试时钟下的 SSE 前缀断言，补阳性对照，并收紧布局和本地调用次数。没有第二轮独立审查，最后全量覆盖最终测试代码。
- 真机回归存在系统 Translation 能力/Picker tag、既有 G0 测试中主线程音频会话 API 等运行提示；Xcode 自动收集设备诊断报错，未阻止测试结果生成。不把这些提示改写为无警告验证或产品平台限制。
- 原始 `.xcresult` / 长日志和自动产生的本机诊断仅在忽略的 build 或临时目录，不提交设备标识、签名信息或系统诊断。

## 真实设备观察与后续关卡（早期状态，已由文末更新）

2026-11-04 用户暂不授权，初轮只看到共享确认页。2026-11-05 用户已经配合选择语言和授权；最小真实采音通过，正式 App 因 R06 在 PiP 启动处失败。当前未获得 Chrome 声音、真实连续识别/翻译、PiP 持续刷新或十五分钟 G0 证据。不得继续沿用“用户未授权”作为本轮原因。

集成人先协调 R06 的首帧/可用性/装配启动顺序和 R07 的错误保留，并处理 R01–R03，再复跑失败回归及完整真机链路。R05 的异步测试同步、R04 的默认语言标签问题一并归原 owner。随后登记各类素材及实际播放区间，补足 A01–A24、100 段延迟/质量及三十分钟记录；本轮生产代码未修改，TASK-14 和 TASK-15 内测门槛仍未通过。

## 2026-11-05 授权集成续修（阶段记录）

用户在原“开发 task14”对话明确授权“授权集成修复并继续验收”。续修分支保留早期缺陷历史，以下为当前结论：R01 小型开放 SSE、R02 final 合并旧行、R03 checkpoint 丢句、R04 locale tag、R05 回退事件测试同步、R07 启动错误保留均已实施修复；R04 真机默认语言呈现仍需人工复核。R06 首帧和 readiness 修复有自动证据，但正式 App 仍无小窗，不得标解决。

- 最终正常 Debug 真机全量 resume-full2.xcresult：232 方法 / 33 suites，参数展开 248 实例，0 失败、0 跳过、0 expected failure，退出 0。
- ./scripts/verify.sh 退出 0；设备 Debug/Release、generic simulator App/测试 bundle 编译通过，没有 simulator runtime，未执行模拟器行为测试。
- 新增竞态 RED 后 GREEN：旧故障被段删除/修订后不再锁住调度器；确认严格匹配完整身份和作业，单项确认不解除其他故障，保留 AI 修订预算和剩余 deadline；每个有效 deadline 均产生故障。启动取消在采集前/后分类正确，UI 停止不等待启动才能取消。
- 正式 App 已重新安装，用户重复执行全屏共享，仍无小窗；AVKit failedToStart 回调 code=-1001、无 underlying code。会话经过 running 后立即 failed/pipFailed，不能以请求已返回宣称小窗成功。
- 独立真实 PiP 探针不启用 capture/Speech/Translation/网络，1/1 实际通过并收到 started；加入真实 capture 后则失败，采集完成时 applicationState=inactive。正在验证前台活跃状态与 PiP 启动的时序。

真实 Chrome 连续播放、G0、100 段延迟/双语质量和三十分钟仍未完成。无正文 RSS/热状态/队列输出已经接线；阶段延迟/CPU/音频积压尚未齐备，详见性能报告。历史“生产未修改/指标未接线”描述仅适用于早期验收，不能作为当前状态。

## 2026-11-05 收工记录（当前结论）

用户完成正式 App 共享操作后确认：“持续显示小窗，并出现译文和原文。可以了，今天就到这吧，提交代码到远程，明天继续验收”。今天结束设备操作，已获原文、译文及持续 PiP 的人工证据。原先“出现小窗后 App 退出”来自成功探针结束后测试宿主收尾，本次正式入口未再报告退出。不能把约 117 秒短会话当作 G0 十五分钟或 A24 三十分钟通过。

R06 根因证据：采集成功回调到达时系统共享面板仍在前台、applicationState=inactive；此时 AVKit 返回 -1001。无采集探针 1/1 通过，带采集但 inactive 探针失败，等待用户关闭面板回到 active 后采集+PiP 探针 1/1 通过。正式 LifecycleAudioSource 现等 active 后继续 Speech/PiP，等待可取消，不把用户操作时间计入 PiP 三秒 readiness。正式 UI 提示先返回本 App，待小窗出现再开视频。

提交前移除 AVPiPSystemAdapter 中重复的全局 active 限制：初次等待留在 LifecycleAudioSource，避免背景恢复被同一限制阻断。此最终清理已跑自动回归和编译，尚未重做人工设备操作；明天优先复验首次启动与 A17 恢复。

- foreground-full2.xcresult：234 方法 / 33 suites，展开 251 实例，0 失败、0 跳过。
- final-20261105.xcresult：234 方法总数，232 通过、2 条件跳过、0 失败、0 expected failure；展开 249 通过、2 跳过，退出 0。跳过 installedLowLatencyTranslation / installedStrategiesReturnTranslation，系统 installed-resource ready 前置为 false；不下载资源、不放宽条件。此前全量通过不替代这次跳过的证据。
- 最终 ./scripts/verify.sh 退出 0，设备 Debug/Release 与 generic simulator App/测试 bundle 编译通过；无 simulator 行为执行。既有 G0SpeechInputTests 四条主线程音频会话提示仍在。
- TASK-14 保持未完成。下一轮先确认本地资源 readiness 与 A03/A17，再补 G0 十五分钟、A01–A24 剩余场景、100 段延迟/质量和三十分钟资源记录。真实 AI 性能未测。
