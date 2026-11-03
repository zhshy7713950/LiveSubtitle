# TASK-05 交接

- 基线 commit：`9881c69eed686a98b68b34f608fab6acd58d72b1`
- 任务分支 / commit：`worktree-task05-speech-assets` / `b92e6d8`（实现）＋`daa19dd`（独立审查修复）
- 前置报告：`docs/reports/g0-device-report.md`；报告仍明确为 G0 未完成。用户直接指派本任务，因此仅按任务卡用合成 PCM 与 doubles 开发，不把本模块证据当作 G0 通过。
- 状态：待审查

## 改动

- `CapabilityService.swift`：当次查询 SpeechTranscriber／本机 Dictation 回退、AssetInventory 和 LanguageAvailability；同语种、识别或翻译对不支持、资源未就绪均产生开始阻断，local 与 AI 共用本地备用要求。
- `LanguageAssetManager.swift`：分别报告识别与本地翻译资源；识别安装请求为空视为无需安装；准备使用代次隔离并保存提前到达的翻译完成，取消使旧完成无效，不生成百分比；新准备前等待旧释放，provider 按 locale 集合管理自有 reservation。
- `LanguagePreparationHost.swift`：供 Features 以 `LanguagePreparationHost(manager:content:)` 嵌入；TranslationSession 只留在系统 `.translationTask` 闭包的原任务中。
- `SpeechService.swift`：查询 `bestAvailableAudioFormat`；连续拉取自有 PCM，验证并复制到 AnalyzerInput，启用 volatileResults／audioTimeRange；归一化 utterance、revision、final 和 grapheme span，保留已有 utterance 的空 final；正常 finish 与立即 cancel 分离；start／stop 过渡和结果流绑定生命周期代次；无完整连续时序时在 30 秒或 2,000 字边界发 discontinuity 并重建，生产音频断裂推进代次并重投触发 chunk。
- 测试：能力／资源 5 项，识别 10 项；额外覆盖非法 PCM、饱和队列取消、快速重启、提前翻译完成、reservation 顺序、生产断裂重投、部分时序和空 final。

对外及装配入口：

- `CapabilityService(speech:translation:)`，两个参数均有系统默认实现。
- `LanguageAssetManager(recognition:translation:)`，两个参数均有系统默认实现；视图使用 `LanguagePreparationHost(manager:content:)`。
- `SpeechService()`；测试另用 `SpeechService(backendFactory:clock:)`。
- `inputFormat(source:)` 应在 AudioPipeline 启动前查询；`finish()` 用于正常输入结束，`cancelAndFinish()` 用于会话停止。调用方仍须按 Contracts 校验 sessionID＋languageEpoch。
- 停止准备或会话时调用 `releaseReservations()`；不在本模块保存字幕、音频或 ready 偏好。

流与释放：

- 准备流使用最多 8 个状态事件的有界缓冲，仅发送有限状态，不包含伪造进度。
- SDK 原始事件和公共 SpeechEvent 都经过 32 项有界 FIFO；生产端在满队列上背压且等待可取消，外层只缓冲 1 项，被挤出的未交付事件重新入队。cancel 先清空并唤醒生产／消费等待者，再等待任务释放。
- Analyzer 输入采用拉取式 AsyncSequence，不新增音频队列；PCM 在输入迭代器中转换，媒体对象不进入公共 Contracts。
- 输出提前终止会取消生产；正常结束调用 `finalizeAndFinishThroughEndOfInput()`，主动停止调用 `cancelAndFinishNow()` 并释放任务和 analyzer。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| `./scripts/verify.sh` | 文档、iOS Debug／Release、模拟器 App 与测试 bundle | 通过 | 不构成行为测试或签名证据 |
| 真机 `xcodebuild ... test -only-testing:LiveSubtitleTests/CapabilityServiceTests` | 5 项 | 全部执行通过 | 无 |
| 真机 `xcodebuild ... test -only-testing:LiveSubtitleTests/SpeechServiceTests` | 10 项 | 全部执行通过 | 无 |
| 真机 `xcodebuild ... test -only-testing:LiveSubtitleTests` | 33 项发现 | 最终复核 33 项全部执行通过 | 无；中间轮次的模型条件跳过我按跳过记录，未计入通过 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | 无可用模拟器运行时 | 未执行 | `simctl list devices available` 为空 |
| 任务卡逐项验收 | 6 个具名验收场景，另有 9 个边界／审查回归 | doubles／合成输入行为通过 | 真机连续识别、前台下载 UI 与完整链路未验收 |

## 契约请求

- 无。未修改 Contracts、工程、Config、脚本、App 装配或其他任务目录。

## 未验证与已知问题

- G0 总前置仍未完成；没有宣称 Chrome 有效采音、十五分钟连续识别、后台 PiP 或生命周期已通过。
- 未在真实前台 `.translationTask` 中验证本任务 host 的下载取消和系统面板行为；生产 SpeechAnalyzer 长时间运行及 Dictation 回退仍需设备场景验证。
- 模拟器行为测试未执行；最终真机复核 33 项全部实际执行，中间轮次出现的模型条件跳过已单独记录，未当作通过。
- 集成人需要在 Features 嵌入准备 host，在启动时先准备资源并查询输入格式，停止时按会话代次调用取消及释放；不得省略协调器端身份校验。
