# 项目约束

适用于 Codex、Claude Code 和人工开发者。正式方案优先于本文件的实现细化；任务卡不能自行扩大产品范围。若用户明确更改范围，先更新对应设计及契约并记录影响。

## 产品与隐私

1. 基线 iOS 27.0，仅 iPhone；首轮英文→简体中文、Chrome 跨网站验证。不能把未测试的平台或语种写成支持。
2. 两种模式均端侧识别，不上传音频、画面，不新增麦克风、相机、照片权限；不用静音播放伪造后台保活。
3. 本地翻译模型与识别资源开始前分别确认，即使 AI 模式也要准备本地备用。语言手选、保留脚本标识、源目标不能相同。
4. AI 为用户配置完整 HTTPS endpoint、模型、Key 的 Chat Completions 文本兼容接口；无默认真实服务、无自动扣费连接测试。源文只进 user 消息，不进系统指令；不发送历史段。
5. 只存语言／界面偏好和非秘密 profile。Keychain 使用本 App 命名空间和适合锁屏结束语义的 ThisDeviceOnly 保护；首次安装清理遗留凭证。禁止把 Key 放 URL、UserDefaults、配置、测试夹具或日志。
6. 音频、画面、字幕不落盘；最多十段字幕及有界可修订文字窗口；停止清空，不开发历史、导出、录制、账户、收费或自建服务端。

## 并发与一致性

- `SessionCoordinator` 是状态和 `SessionIdentity` 的唯一写者。engine、language、cloud-config 版本独立；sessionID 每次开始更新。调度器发回退请求，由协调器确认归属后增代引擎并通知调度器和存储。
- 收到的成功、失败、PiP 回调、连接测试结果都先检查所属作用域。采音／识别／分段绑定 sessionID+languageEpoch，PiP绑定sessionID，翻译作业／错误和连接测试绑定完整identity（测试还绑定profile）；模式切换不使现有采音／识别流失效。字幕译文写入同时检查全部代次、段保留状态、sourceRevision、deadline。停止先失效身份，再取消并释放。
- deadline 到达时，对仍属当前作业的超时产生一次故障；不能用“过期丢弃”吞掉 timeout。旧任务错误和主动 cancellation 不触发回退。
- requestedMode 与 effectiveMode 分离；localFallback 锁定到用户手动固定短句检测通过。配置变更先落本地，不能自动把当前字幕发往新地址。
- 单段修订超 AI 预算后仅该段转本地，不改变全局模式；字幕保留实际 provider。本地失败结束会话，不上传声音补救。
- Swift 6 完整并发检查。UI、系统选择器、显示层、PiP 属 MainActor；计算和串行状态按职责使用 actor。不得新增逃避检查的全局可变状态或无依据的 `@unchecked Sendable`。
- 捕获回调只校验、取得数据所有权、交给有界队列，不能做推理、网络、绘制、落盘或等待队列。`AudioChunk.ownedPCM` 必须是自有数据。
- 所有 `AsyncStream` 实现必须显式选择有界缓冲、处理 yield 丢弃和终止、释放任务；默认无界流不合格。音频按时长而非简单元素个数限制；控制事件不得被丢弃的音频覆盖。
- 使用单调时间和显式 PTS 映射。生产时钟和测试时钟都遵守 `MonotonicClock`，禁止用 sleep 的真实等待测试六秒超时。

## 参数和代码边界

- `LiveSubtitle/Contracts/RuntimePolicy.swift` 集中方案初始参数；这些声明当前不执行上限检查。调整需附测试依据并更新设计记录。
- `LiveSubtitle/Contracts/Models` 是跨模块 Sendable 值；`Ports` 是固定接口。各实现不得重新声明同名模型，不将 AVFoundation／ScreenCaptureKit 对象混入共享契约。
- 只有集成人修改 Contracts、App 装配、Config、工程、共享 scheme、脚本和根约束。普通任务提交接口变更请求，由集成人先合入契约再让消费者更新。
- 原生 Xcode 文件系统同步目录自动收录 Swift 文件，不给每个新文件编辑 pbxproj。不引入生成器、第三方运行依赖或多个 Package。
- 单 App + 单测试 target；测试代码按任务目录划分，SDK 桥接留在模块内，测试假实现留在测试目录。
- 禁止提交 `fatalError("TODO")` 或返回假成功的占位服务。未实现只保留协议和空目录；测试夹具明确标为测试。
- 源文件采用英文类型／API 名；用户文案和交接文档用中文。每个文件职责明确，优先小文件；不为预想扩展提前设计复杂插件系统。

## 工程与验证

- `Config/Shared.xcconfig` 管 iOS、Swift、并发；App／Tests 分别配置；个人签名放被忽略的 `Config/Local.xcconfig`，不提交私钥和 provision。
- 工程已声明 `screen-capture`、`audio` 和屏幕用途文字，尚未证明采集可用；不预填未经确认的特殊 entitlement。G0 核对 SDK、签名和设备实际要求。
- 基础检查为 `./scripts/verify.sh`：文档完整性、plist／scheme、iOS Debug、iOS Release、模拟器 App 和测试 bundle 的编译。它不执行行为测试、不证明签名或后台能力。
- 真正行为改变应先写能复现约束的测试，再实现；验证实际行为及边界，不为目录、常量或假对象写凑数的测试。
- 网络测试用固定本地响应／URLProtocol，不默认访问用户的真实接口。禁止用真实内容、真实 Key 做自动化夹具。
- 报告分别写清编译、单元测试执行、设备安装、G0、验收矩阵。没有设备证据就保持未验证；不得把测试 target 编译或零测试执行称为测试通过。
- 不覆盖来源文档以美化未达标结果。延迟、内存、断流和丢弃必须可核对，连续积压是失败，不反复丢弃后写成功。

## 多 agent 协作

一个任务一个分支／worktree。所有权和可并行阶段见 `tasks/README.md`。任务各自附测试与交接；集成人负责公共文件和合并后的全量验证。不要共用 DerivedData；脚本默认放当前 worktree 的 `build/`。

各任务除任务卡所有权范围外，还可创建自己的 `docs/tasks/handoffs/TASK-XX.md`，不能改写其他任务的交接文件或总表。

当前授权仅搭框架并拆任务；未来收到具体 TASK 指派即按该任务执行，不逐步重复请求许可。涉及改变已确认产品边界、上传声音或公开分发等新增行为时，由负责人按实际范围处理。
