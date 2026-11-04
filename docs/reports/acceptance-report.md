# TASK-14 正式验收报告

状态：**未通过，TASK-14 未完成**。记录日期：2026-11-04（Asia/Shanghai）。

## 版本与证据边界

| 项目 | 本轮记录 |
| --- | --- |
| 产品基线 | `a1c57879efbcb734ad5c3560385db72f15b6b7b3`，fetch 后的 `origin/main`，包含 TASK-13 |
| 验收分支 | `codex/task-14-validation`；报告绑定本提交，生产代码与上述基线一致 |
| App | 0.1.0（1），正式入口；真机测试使用 Debug 构建 |
| 工具 | Xcode 27.2（27B52），iPhoneOS / iPhoneSimulator SDK 27.2，Swift 6 完整并发检查 |
| 设备 | iPhone 17 Pro，iOS 27.2（24B119），物理连接；不提交设备标识 |
| Chrome | 156.8078.54（设备已安装版本；不等于本轮已完成 Chrome 播放） |
| 语言对 | 固定回归 en → zh-Hans；正式入口显示两类本地资源均已就绪 |
| 网络与 AI | 所有新增 AI 回归由 host 隔离的 URLProtocol 固定响应截获；未知请求在该 transport 内失败。无真实 AI endpoint / 模型 / Key，无真实服务性能样本 |
| 前置 | [TASK-13 交接](../tasks/handoffs/TASK-13.md)已合入；[G0 报告](g0-device-report.md)仍未完成，不能转记为通过 |

`pass` 仅表示该行全部标准已有证据；`fail` 表示已复现违反标准的行为；`blocked` 表示缺前置或执行条件；`not-run` 表示条件具备但本轮未执行。固定响应运行在真机上，仍然不证明 Chrome、真实 Speech / Translation SDK、真实 PiP 或性能达标。失败项不因同一行其他子项通过而改为 pass。

## A01–A24 矩阵

| 编号 | 场景 | pass/fail/blocked/not-run | 证据／实测值／缺陷 |
| --- | --- | --- | --- |
| A01 | 首次资源缺失与取消 | blocked | 正式 UI 本轮可见识别、本地备用翻译两行均为“已就绪”；未重置首次安装环境或删除模型。既有资源 blocker 自动回归通过，未验证首次系统下载及取消 |
| A02 | 不支持语言／语言对 | blocked | 既有 Capability / Features 自动回归已执行；真实不支持语言的前台提示仍欠操作。源/目标 Picker 的当前值为空，但菜单有候选，见 R04；不能据此宣称未返回任何语言 |
| A03 | 英文→简中本地 | blocked | 本轮正式 App 已到系统全屏共享确认页；用户明确暂不授权，已取消选择器；尚无 Chrome 声音、真实识别/翻译及持续显示证据。G0 未完成 |
| A04 | 下载后断网本地 | blocked | 固定输入本地路径无字幕网络请求的自动回归通过；尚缺离线可播放非敏感英文素材及断网设备步骤 |
| A05 | MP4、HLS、嵌入、直播 | blocked | 四类真实素材本轮均未播放；未登记素材版本/时间范围，声音/字幕/延迟均无实测值 |
| A06 | 切站和切视频 | blocked | 尚无同一真实共享会话跨站证据；不泛化网站覆盖 |
| A07 | 页内、横屏和全屏 | blocked | 正式入口竖/横屏可见；未播放 Chrome 或核对字幕 PiP，不能以主页面旋转替代播放器全屏验收 |
| A08 | 扬声器、耳机、蓝牙 | blocked | AudioPipeline 格式/队列单元回归通过；真实路由切换未测 |
| A09 | AI 正常 SSE | fail | R01：完整的小 SSE 事件已送到 URLSession，HTTP 保持打开，两秒观察窗内未显示任何 AI 文本；EOF 后的同类内容可以显示。没有调用真实服务 |
| A10 | SSE 随机分块和 Unicode | pass | 新增测试以种子 1、42、2026 将 UTF-8/CRLF/空 choices/注释分块，经真实 cloud → scheduler → store → 测试 snapshot sink 后均恰为单份累计译文；既有逐字节/每切点解码测试亦通过。HTTP 结束条件已提供；开放流问题另计 A09 |
| A11 | AI 故障后锁定本地 | pass | 新增跨模块用例实际验证 401、403、429、500、503、异常 JSON、空内容、refusal、断网；每例恰发一个 AI 请求，故障段及后续段本地完成。无首文本响应以测试时钟推进 3 秒触发一次 firstTextTimeout，推进至 6 秒后不重复增代 |
| A12 | 固定句手动恢复 | pass | 真实 CloudConnectionTester 通过固定句探测后恢复 AI；请求体仅含固定句，不含上一段；既有段仍保留 local provider，仅后续新段发送 AI。请求由 URLProtocol 截获 |
| A13 | 修订、错序、晚到、主动取消与有效超时 | fail | R02：同一 utterance 的两个 provisional 最终合并时，显示同时留有最终行与第二条旧行。既有版本/晚到/取消回归及新增主动 HTTP 取消/超时回归通过，不能覆盖此失败 |
| A14 | 长句、十分钟无 final、有界文字窗口 | fail | R03：第 11 个独立 final 语句不产生字幕，第 12 个恢复。既有“十分钟无 final”仅以 600 次合成时间输入检查 normalizer 的 30 秒/2000 字窗口；通过但不是十分钟设备压力运行 |
| A15 | N=3→1→10→3 | blocked | 新增真实 coordinator/store/layout 组合回归通过：保留 10 段、最新段可见、可见组数不超 N，不重启采音/识别，无网络请求；固定大尺寸下可见 ID 恰为最后 N 段，本地 SDK seam 调用数在设置前后均为 10。真实 PiP 尺寸/可读性仍未测 |
| A16 | 双语／仅译文 | blocked | 与 A15 同一回归切换两种 style；仅译文布局不出现 source 行，身份不变，本地翻译调用数不增加，也无网络请求；真实 PiP 即时呈现未测 |
| A17 | PiP 关闭与恢复 | blocked | 既有 Session / LifecyclePiP 自动回归通过；系统 PiP 的关闭/恢复入口及 completion 时机未实操 |
| A18 | 撤销采集、锁屏和来电 | blocked | 既有固定通知/撤销/作用域回归通过；没有物理锁屏/来电/撤销后的真实全链路清理证据 |
| A19 | 停止后旧回调及快速重启 | blocked | 新增真实 HTTP 在途取消后推进旧 deadline、重启新 session，只有新字幕、无误回退、无停止期间新请求；既有合成 PCM 清理回归通过。系统选择器/真实 capture 旧回调仍未测 |
| A20 | 其他视频 PiP 替换 | blocked | 既有 double 的 replaced 回归通过；真实另一视频 PiP 抢占未操作，不声称双 PiP |
| A21 | deadline 及队列压力 | blocked | 并发/总截止/修订预算回归通过；最终全量的既有队列溢出测试出现 R05 波动，不写全部通过；新增首文本超时跨模块通过。真实 Chrome 音频/翻译积压的最大值、持续丢弃记录缺失 |
| A22 | 停止、重启无历史 | blocked | 新增及既有自动回归验证停止时 renderer/store 清空，重启只有新段；未执行正式设备 App 冷启动后历史/偏好人工检查 |
| A23 | 日志、缓存与网络内容边界 | blocked | 固定输入本地零请求、诊断无正文/Key/endpoint、请求仅当前段和禁缓存的既有测试通过；尚未对真实 Chrome 全链路做日志/网络/容器核查 |
| A24 | 连续三十分钟 | blocked | 实际连续播放时长 0 分钟；有效性能样本 0/100，人工双语质量样本 0/100。P95、RSS 曲线、队列曲线及热状态均 N/A，见[性能报告](performance-report.md) |

当前矩阵：pass 3 项（A10–A12），fail 3 项（A09/A13/A14），blocked 18 项，not-run 0 项。这里的 pass 严格限定为相应固定响应/逻辑验收，不构成完整产品通过。

## 已复现缺陷与责任归属

| ID | 严重性 / owner | 复现与实际结果 | 处理请求 |
| --- | --- | --- | --- |
| R01 | 高 / TASK-08 Cloud | `AcceptanceCloudTests.testA09CompleteSSEEventsAppearBeforeResponseEnds`；HTTP 留开，三个完整 content 事件总量小于 4096 字节，显示无 AI 文本。相同 UTF-8 内容附 DONE/EOF 的测试通过 | `CompatibleChatTranslator.consumeSSE` 仅在 `buffer.count == 4096` 或流结束时调用 consume；应及时消费完整 SSE 事件并保留事件/响应上限。补开放流/首文本计时回归 |
| R02 | 高 / 集成人 Contracts + TASK-03 + TASK-06 | `AcceptanceCaptionTests.testA13MergedFinalRemovesSupersededRowsFromDisplay`；输出为最终合并行加第二条旧临时行，期望只有最终行 | `consumeSegments(.remove)` 仅更新 retained 索引和 scheduler，CaptionStoring 无 remove 端口；沿用 TASK-03/13 请求新增 `remove(segmentID:) async`，生产 store 删除并刷新，保证旧作业拒收 |
| R03 | 高 / TASK-06 Captions | `AcceptanceCaptionTests.testA14CheckpointRolloverDoesNotLoseAnUtterance`；前 10 段可见，第 11 段缺失，第 12 段又可见 | `TranscriptNormalizer.consume` 在新增第 11 个 checkpoint 时要求 discontinuity；`CaptionSegmenter.closeActive` 将本次 upsert 改为 discontinuity，协调器忽略该事件，导致本句丢失。保留有界性同时处理触发上限的有效文字，不能靠增大阈值掩盖 |
| R04 | 中 / TASK-12 Features | 正式 App 的源/目标行均无当前值；打开源菜单可见语言候选，返回后默认配置仍可进共享选择器；运行日志亦有默认标签未关联 Picker tag 的系统提示 | 核对默认 `en` / `zh-Hans` 与 SDK 返回的带地区 locale 的 tag 匹配和当前值展示；本轮没有修改用户的语言选择，也没有证明所有候选为空 |

| R05 | 中 / TASK-10 测试同步待核对 | 首轮最终全量的 `TranslationSchedulerTests.testQueueOverflowAtDeadline` 断言 fallback 数量失败；单独复核 6/6 通过，最后全量中该项亦通过 | 与 TASK-13 已记录波动一致。源码只等待 failed 被消费便断言随后 fallback 的数量，存在异步消费竞态的解释；尚未证明唯一根因。由 owner 加入 fallback 消费条件，保留当前失败记录，不据此声称生产 timeout 丢失 |

R01–R03 保留为正常、未跳过、会失败的回归；不使用 expected-failure 或降低断言隐藏缺陷。TASK-14 不拥有这些生产目录，未修复或修改共享接口。R04 是人工观察，不冒充新增自动回归。TASK-13 已记录的“选择器等待中停止”及真实 PiP 问题也未解决。

## 执行证据

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

## 真实设备观察与后续关卡

本轮已通过 Device Hub 看到正式设置入口及系统全屏共享确认页；用户已明确“暂不授权，记录为阻塞”，选择器已取消。尚未把共享确认后的采音、识别、翻译、字幕 PiP 或 Chrome 视为通过。首次安装资源场景未重置；没有录制屏幕/音频或保存字幕正文。

集成人先处理 R01–R03 并运行本分支保留的回归，再核对 R04 与生产采样接线，重跑 G0 十五分钟链路。随后登记 MP4/HLS/嵌入/直播的非敏感英文素材、URL 与版本/时间范围、真实语言标签和网络条件；逐项补足 A01–A24、100 段延迟/质量及三十分钟记录。TASK-15 内测门槛仍不满足。
