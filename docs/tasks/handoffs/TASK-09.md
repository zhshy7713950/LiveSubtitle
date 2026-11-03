# TASK-09 交接

- 基线 commit：`4302386fd263ed7a5564c3a186bd8ded856474ff`（`origin/main`）。
- 任务分支 / commit：`worktree-task-09-storage`；实现与独立审查修正均在该分支，最终 commit 以分支 HEAD 为准。
- 前置报告：`docs/reports/g0-device-report.md` 仍为 **G0 未通过**。本轮按用户明确的 TASK-09 指派完成隔离模块交付，不据此宣称完整链路可用。
- 状态：**待审查**。实现、主机行为检查及工程编译已有证据；模拟器行为测试、iOS Keychain 属性断言和真实首次安装流程尚未执行。

## 改动

- `LiveSubtitle/Storage/PreferencesStore.swift`：actor 实现 `PreferencesStoring`，以 Codable 保存语言／模式／显示偏好和非秘密 profile；不保存字幕或 Key。校验语言及 `RuntimePolicy.displayCountRange`，复用 Cloud 的 `EndpointValidator` 统一拒绝无效 HTTPS endpoint、fragment、用户信息和规范化后的秘密查询字段，Storage 额外校验 profile name；损坏数据清除后可重新保存。
- 新 profile 使用至少为 1 的传入 revision；已有 profile 每次保存按已存版本加一，忽略旧输入版本并检查溢出。删除 profile 只移除目标 ID，若它正被选中则清除选择；调用方保存后须重新读取实际 revision。
- `LiveSubtitle/Storage/KeychainCredentialStore.swift`：actor 实现 `CredentialStoring`，使用 generic password、profile UUID account 和独立 service 命名空间；替换、删除只影响目标 profile，`clearAppNamespace` 只查询自己的 service。访问级别为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，不同步到 iCloud。
- `LiveSubtitle/Storage/FirstLaunchCredentialCleaner.swift`：容器标志不存在时清理本 App 凭证，成功后才写完成标志；失败可由下次调用重试，已成功清理后不重复删除。
- `StorageError` 仅暴露无关联值的安全类别，不透传 OSStatus、原始系统错误、URL 或 Key。
- 测试只使用随机 UserDefaults suite、随机 Keychain service 和明确的 fixture Key；清理自己的测试数据，不读取或修改真实用户凭证。

## 类型与装配

- `PreferencesStore(suiteName: String? = nil)`；nil 使用 `UserDefaults.standard`，suite 名称传入后在 actor 内创建 `UserDefaults`，避免跨域发送非 Sendable 实例。
- `KeychainCredentialStore(service: String = "com.zhshy7713950.LiveSubtitle.credentials")`。
- `FirstLaunchCredentialCleaner(suiteName: String? = nil, credentials: any CredentialStoring)`；入口为 `cleanIfNeeded() async throws`，由 TASK-13 在首次容器初始化、读取授权配置前调用。
- `KeychainCredentialStore` 不直接修改 profile。Features／集成人替换或删除 Key 时，仍须先完成 `cloudProfileWillChange` 屏障，再按既有配置流程调用 `saveProfile` 生成新 revision，最后通过 `cloudProfileDidChange` 重读。
- 无 AsyncStream、媒体缓冲或后台任务；actor 串行化存储操作，无额外流缓冲、取消协议或资源下载。

## 验证

| 命令或设备步骤 | 环境 / 用例数 | 结果 | 未通过原因 / 边界 |
| --- | --- | --- | --- |
| 基线 `./scripts/verify.sh` | 基线 `4302386` | 退出码 0；Debug、Release、模拟器 App／测试 bundle 编译通过 | 不执行行为测试 |
| RED：TASK09_HOST_CHECK 编译 | 偏好、Keychain 生产类型尚不存在 | 分别因缺少 `PreferencesStore`／`StorageError`、`KeychainCredentialStore`／`FirstLaunchCredentialCleaner` 失败 | 已确认是缺少实现而非测试通过 |
| 独立审查回归 RED | `apiKey`、`access-token`、`signature`、fragment endpoint | 新增回归在旧实现上以 `expected invalidProfile` 失败 | 复用 `EndpointValidator` 后转绿，且已有有效 profile 不变 |
| 最终 TASK09_HOST_CHECK：`swiftc -swift-version 6 -strict-concurrency=complete` 后运行本机检查 | macOS 主机，7 项同源行为检查 | 实际运行，7 项通过、0 失败 | 覆盖偏好字段、边界／坏数据、revision／删除、两个 profile 的 Key 替换／删除、missing key、首次清理及失败重试；macOS 不执行 iOS 访问级别属性断言 |
| 最终 `./scripts/verify.sh` | Xcode／iOS SDK 27.2 | 退出码 0；device-debug、device-release、simulator-tests 均 build succeeded | 仅编译，不等于模拟器测试执行 |
| `xcrun simctl list devices available` | 本机最终检查 | 无可用设备，未得到 UDID | 因此未执行 `./scripts/test.sh '<UDID>' -only-testing:LiveSubtitleTests`，不声称全量 Swift Testing 通过 |
| 任务卡四项指定验收 | 同源 Swift Testing 与主机辅助函数 | 四项测试均已建立；对应主机行为已执行通过 | iOS-only `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 查询断言仅完成编译，未实际运行 |

主机检查复现命令：

```sh
swiftc -swift-version 6 -strict-concurrency=complete \
  -module-cache-path build/task09-module-cache -D TASK09_HOST_CHECK \
  LiveSubtitle/Contracts/Models/*.swift \
  LiveSubtitle/Contracts/Ports/StorageDiagnosticsPorts.swift \
  LiveSubtitle/Contracts/RuntimePolicy.swift \
  LiveSubtitle/Translation/Cloud/EndpointValidator.swift \
  LiveSubtitle/Storage/*.swift \
  LiveSubtitleTests/Storage/PreferencesStoreTests.swift \
  LiveSubtitleTests/Storage/KeychainCredentialStoreTests.swift \
  -o build/task09-host-checks
./build/task09-host-checks
```

## 契约请求

- 无。未修改 Contracts、Config、App 装配、工程、scheme、脚本或任务总表。

## 未验证与已知问题

- 没有可用模拟器，完整 `LiveSubtitleTests` 及本任务 Swift Testing wrapper 未在 iOS runtime 执行；测试 bundle 编译通过不能替代行为测试。
- macOS 普通 Keychain 不返回 `kSecAttrAccessible`；Data Protection Keychain 主机探针因缺少 entitlement 返回 -34018，因此访问级别属性断言仅保留在 iOS 路径，需后续在模拟器或真机执行。锁屏拒绝读取也未做设备验证。
- 未执行真实卸载／重装后的首次启动清理，只验证了隔离命名空间、容器标志和失败重试逻辑。
- 额外测试增强暂未覆盖 N=1、10 的独立往返及 `RuntimePolicy.defaultDisplayCount` 的直接断言；本轮已执行默认夹具 3、0／11 拒绝和无效写入不覆盖有效数据。
- G0 仍未通过；本交付不证明采集、识别、翻译、PiP、后台或完整产品链路可用。
- 未推送、未合并；等待集成人审查及全量验证。
