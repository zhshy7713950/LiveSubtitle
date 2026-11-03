# TASK-07 交接

- 基线 commit：`70eebed4f24c96779146db83f4555f82434178e0`
- 任务分支 / commit：`worktree-task07-local`；本交接与实现同一提交，可用 `git log -1 -- docs/tasks/handoffs/TASK-07.md` 查询。
- 前置报告：`docs/reports/g0-device-report.md` 仍明确为未完成；本任务按负责人明确指派独立开发，未把此前置写成通过。
- 状态：待审查。八项主机与真机测试、完整 107 项真机测试及工程编译通过；模拟器和默认系统包装器的直接端到端行为未验证。

## 改动

- `LiveSubtitle/Translation/Local/AppleLocalTranslator.swift`：实现 `AppleLocalTranslator: Translator`。保留作业的完整 identity、jobID、segmentID 和 sourceRevision；成功输出单次累计替换文本、`isFinal=true`、`provider=.local`。缺资源返回 `assetsMissing`，系统错误返回 `localTranslationFailed`，超过 `RuntimePolicy.translationCharacterLimit` 的输出返回 `invalidOutput`，均关闭该作业流。
- 同一语言对复用非 UI 系统会话；语言对改变时取消旧会话并创建新会话。运行路径只调用 `installedSource` 初始化和 `isReady`，不调用 `prepareTranslation()`、不弹出下载 UI、不自行修改 identity 或决定全局 fallback。
- 真实 `TranslationSession` 仅在长期拥有者任务内创建和使用；外部句柄只持有 Sendable 命令流与任务句柄，没有 `@unchecked Sendable`、`nonisolated(unsafe)` 或 `@preconcurrency` 绕过。
- `LiveSubtitleTests/Translation/Local/AppleLocalTranslatorTests.swift`：任务卡四项具名验收，另加超长译文、就绪通道故障、消费者取消后立即替换，以及换语言对期间 `cancelAll` 的竞态回归。测试只使用固定合成文字与任务内会话假实现，不访问网络或用户模型资源；同一源码支持 Swift Testing 和 `TASK07_HOST_CHECK`。

## 类型与装配

- TASK-13 使用 `AppleLocalTranslator()`；类型为 actor，遵守既有 `Translator`，无新增公共 Contracts。
- 任务内注入点为 `AppleLocalTranslator(sessionFactory:)`；工厂类型为 `LocalTranslationSessionFactory`，会话抽象为 `LocalTranslationSession: Sendable`，供固定假实现验证生命周期。真实系统包装器为私有实现。
- 每个作业输出流使用 `.bufferingOldest(1)`，只承载一个成功或安全失败终态；正常完成关闭流但保留可复用会话。适配器同时只运行一个作业，等待队列只保存 jobID；消费者提前取消排队作业只移除队列引用，取消运行作业则先退役会话、取消并等待真实工作退出，再启动后续修订。
- 系统命令流使用 `.bufferingOldest(4)`，响应流使用 `.bufferingOldest(1)`；入队失败和通道终止不会伪造成功或误报 `assetsMissing`。`cancelAll` 先失效全部作业并完成输出，再取消运行任务、退役会话并等待任务退出；拥有者任务退出时调用 `TranslationSession.cancel()`。换对取消与 `cancelAll` 交错时，不创建已失效的新会话。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 / 边界 |
| --- | --- | --- | --- |
| 基线 `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0 | 仅基线编译 |
| 最终 `./scripts/verify.sh` | Xcode / SDK 27.2 | 退出码 0；Debug、Release、simulator App / 测试 bundle 编译通过 | 不执行行为测试或证明签名、模型能力 |
| `TASK07_HOST_CHECK` 失败先行 | Swift 6 完整并发、警告即错误 | 初版因适配器和会话抽象不存在而编译失败；换对取消、取消后立即替换均实际复现审查问题；就绪故障测试先因协议不可抛错失败 | 保留红绿证据；测试同步本身另经压力运行修正 |
| 最终 `TASK07_HOST_CHECK` | macOS 27.2 SDK，目标 26.4；8 项 | 8 项执行通过；连续 1000 轮通过；AddressSanitizer / UndefinedBehaviorSanitizer 一轮、ThreadSanitizer 连续 20 轮通过 | 不执行真实 TranslationSession、下载、设备或后台行为 |
| 既有主机回归 | G0 13 项、TASK-04 21 项、TASK-06 28 项、Session 17 项 | 79 项执行通过 | 不包含 iOS SDK／设备行为 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | `simctl list runtimes` 与 available devices 均为空 | 未执行 | 无可用 iOS 27 模拟器；不把测试 bundle 编译称为测试通过 |
| 真机 `xcodebuild ... test -only-testing:LiveSubtitleTests/AppleLocalTranslatorTests` | 已连接 iPhone／iOS 27.2；1 suite／8 tests | 8 项实际执行通过，0 跳过 | 使用注入会话，不直接执行默认系统包装器 |
| 真机 `xcodebuild ... test -only-testing:LiveSubtitleTests` | 同一设备；13 suites／107 tests | 107 项实际执行通过，0 跳过；G0 翻译条件测试实际执行通过 | 有 4 条既有 `AVAudioSession Hang Risk` 主线程警告；不代表完整 G0 媒体链路通过 |
| 任务卡逐项验收 | identity / assetsMissing / cancelAll 与消费者取消 / 会话复用、换对和安全 failure | 通过注入会话的主机行为检查 | 真实 SDK 对应行为待设备或模拟器执行 |

主机检查复现命令：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx26.4 -module-cache-path build/task07-module-cache \
  -D TASK07_HOST_CHECK LiveSubtitle/Contracts/Models/*.swift \
  LiveSubtitle/Contracts/Ports/TranslationPorts.swift LiveSubtitle/Contracts/RuntimePolicy.swift \
  LiveSubtitle/Translation/Local/AppleLocalTranslator.swift \
  LiveSubtitleTests/Translation/Local/AppleLocalTranslatorTests.swift \
  -o build/task07-host-checks
./build/task07-host-checks
```

## 独立审查

- 独立 reviewer 判定初版不 ready：三项 Important 分别为取消等待期间复用旧会话／误清替代会话、立即替换使旧真实工作继续执行，以及就绪命令故障误报 `assetsMissing`；另指出换对测试的完成同步存在假绿窗口。
- 已改为单运行作业与 jobID 等待队列；运行取消先退役会话并等待任务退出，不再因新作业到场而保留旧命令流。就绪检查改为可抛错，只有系统明确返回未就绪才映射 `assetsMissing`。
- 新增取消后立即替换、就绪故障两项回归；换对测试通过输出关闭和 `cancelAll` 返回确认真实工作结束。最终八项连续 1000 轮及 Sanitizer 检查通过；未进行第二轮 reviewer 复审，最终由集成人审查。

## 契约请求

- 无。未修改 Contracts、App 装配、Config、工程、scheme、脚本或其他任务目录。

## 未验证与已知问题

- `AppleLocalTranslator()` 的默认私有系统包装器尚未直接执行；真机 TASK-07 测试使用注入会话。全套中的 G0 翻译测试已在真机实际执行通过，但不能据此宣称本适配器的默认系统包装器已完成端到端验证。
- 实际模型缺失时不触发系统下载、断网翻译及后台持续行为仍需设备验收；本任务没有自行下载或宣称 G0 通过。
- Swift Testing 已在真机执行；当前没有模拟器 runtime，模拟器矩阵仍未验证。
- 完整真机测试出现 4 条 `AVAudioSession Hang Risk` 主线程警告；107 项仍全部通过。该警告属于既有音频路径，本任务未修改，集成人应结合 TASK-04 证据核查。
- TASK-13 需按 `RuntimePolicy.localConcurrency` 的调度约束装配，并在本地失败时由协调器停止会话；适配器自身不改变全局模式。
- 未推送、未合并 main。
