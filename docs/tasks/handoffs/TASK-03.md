# TASK-03 交接

- 基线 commit：`9881c69eed686a98b68b34f608fab6acd58d72b1`
- 任务分支 / commit：`worktree-task03` / `494306c`（交接文档见随后提交）
- 前置报告：`docs/reports/g0-device-report.md`；报告仍明确为“未完成，G0 尚未通过”。本任务由用户直接指派，未把前置报告改写为通过。
- 状态：待审查

## 改动

- 实现 `actor SessionCoordinator: SessionCoordinating`：准备、共享选择器启动、运行、幂等停止、显示设置、模式切换、AI 故障回退、手动恢复和 cloud profile 变更屏障。
- `SessionCoordinator` 独占 `SessionIdentity` 的 sessionID／languageEpoch／engineEpoch／cloudConfigRevision 更新；采音、识别、分段事件按 sessionID+languageEpoch 接收，PiP 按 sessionID，翻译事件按完整 identity、job、段版本接收。
- 停止入口先关闭事件与作业接收、失效准备和连接测试代次，再等待清理；并发停止共享同一清理任务。本地翻译或端侧识别失败保留 `FailureCode`，清空会话内容后进入 failed。
- `SessionDependencies` 注入现有 Ports；`SessionMainActorDependencies` 把 UI 端口留在 MainActor，不使用 `@unchecked Sendable`。
- Speech 输出由协调器单消费者读取，通过容量 64 的有界中继交给分段器；中继溢出显式停止，不静默丢控制事件。状态流使用 `.bufferingNewest(1)`。
- 测试包含任务卡九项具名场景，另加八项跨代次、并发启动、启动中操作、旧配置操作、在途写入清库和取消回归；全部使用任务内 doubles 和虚构 profile，无真实服务、Key、媒体或字幕。

### 装配接口

```swift
let dependencies = SessionDependencies(
    capability: CapabilityChecking,
    assets: LanguageAssetManaging,
    audioSource: AudioSource,
    audioProcessing: AudioProcessing,
    speech: SpeechRecognizing,
    segmenter: CaptionSegmenting,
    scheduler: TranslationScheduling,
    captions: CaptionStoring,
    renderer: SubtitleRendering,
    pip: PiPControlling,
    preferences: PreferencesStoring,
    connectionTester: ConnectionTesting,
    diagnostics: DiagnosticsRecording,
    clock: MonotonicClock
)
let coordinator = SessionCoordinator(dependencies: dependencies)
```

`SessionDependencies.init` 为 `@MainActor`；`SessionCoordinator.init` 为非隔离 actor initializer。上述协议名表示对应 existential 注入，不是新增具体生产适配器。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 |
| --- | --- | --- | --- |
| `./scripts/verify.sh` | Xcode 27.2；文档、iOS Debug、iOS Release、generic simulator App／测试 bundle | 退出码 0，全部编译成功 | 不执行行为测试，不证明设备能力 |
| Session host checks（Swift 6 `-strict-concurrency=complete`） | 17 项纯逻辑行为检查 | 17/17 通过 | 无 SDK、模拟器或真机行为证据 |
| 既有 G0 host checks | 13 项纯逻辑回归 | 13/13 通过 | 不代表 G0 真机验收通过 |
| `./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests` | 当前 `simctl list devices available` 无可用模拟器 | 未执行 | 无 iOS 27 模拟器运行时；只完成测试 bundle 编译 |
| 任务卡逐项验收 | 九项均有对应可执行主机测试 | 主机逻辑通过 | 真机生命周期、系统 PiP 和实际 SDK 未验证 |
| 独立只读审查与修复回归 | 启动／配置重入、清库顺序、取消 barrier | 六项新增回归 RED→GREEN，最终 17/17 | 两项测试强化建议留作后续，不涉及已知生产错误 |

## 契约请求

- `CaptionStoring` 当前没有单段删除接口。`SegmentEvent.remove(segmentID:)` 到来时，协调器只能更新自己的保留索引并调用 `TranslationScheduling.retainOnly`，无法要求 store 删除该段。建议由集成人评估新增 `func remove(segmentID: UUID) async`（消费者：SessionCoordinator；生产者：TASK-06 CaptionStore），或明确以其他现有接口表达删除。新增接口需覆盖删除后旧 job 失败／成功不再产生副作用、段序号有界及显示刷新。TASK-03 未直接修改 Contracts。

## 未验证与已知问题

- 未执行 iOS 模拟器行为测试、真实设备安装或 G0；实际 ScreenCaptureKit、Speech、Translation、PiP 组合与系统生命周期均未由本任务验证。
- 前置 G0 的十五分钟 Chrome 后台链路、有效非静音音频和系统停止场景仍未完成，不能据本任务测试宣称产品可用。
- Speech 中继容量是本任务内部有界策略；真实事件速率与分段消费速度需在 TASK-05／06 合并后做积压验证，持续积压必须失败，不能反复丢弃后报成功。
- TASK-13 需要在 MainActor 构造依赖并装配全部真实端口；本任务未修改 App 入口或共享工程文件。
