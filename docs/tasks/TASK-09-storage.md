# TASK-09：偏好、配置与 Keychain

状态：未开始。原方案映射：T07 凭证部分。参考：[正式方案](../development-spec.md) §§4.2、11.3、14。

前置／并行条件：G0 通过；可与其他模块并行，测试用隔离 UserDefaults suite 和专用 Keychain 测试命名空间。

## 文件所有权

- `LiveSubtitle/Storage/`
- `LiveSubtitleTests/Storage/`

具体产物：创建 PreferencesStore.swift、KeychainCredentialStore.swift、FirstLaunchCredentialCleaner.swift；测试 PreferencesStoreTests.swift、KeychainCredentialStoreTests.swift。

只写以上范围；不修改其他任务实现或公共文件。共享文件变更交给集成人。测试假实现放自己的测试目录，避免争抢公共 Support。

## 接口

- 消费：PreferencesStoring、CredentialStoring、AppPreferences、CloudProfile。
- 产出：PreferencesStore: PreferencesStoring；KeychainCredentialStore: CredentialStoring；首次容器初始化时清理本 App 遗留凭证的入口。
- 端口准确签名以 `LiveSubtitle/Contracts/Ports` 为准；不得复制修改模型。运行参数引用 RuntimePolicy；构造器签名在任务交接中列出，供 TASK-13 装配。

## 验收

- [ ] testPreferencesContainNoContentOrKey：持久化仅允许语言／模式／显示、endpoint／model等profile元数据，无字幕／Key字段。
- [ ] testProfileRevisionAndKeyReplacement：保存变更生成新revision，替换／删除Key只影响目标profile，通知协调器由Features负责。
- [ ] testFirstLaunchClearsOnlyAppNamespace：清理旧安装命名空间，不删除其他 App／测试数据；锁屏访问属性为合适的 ThisDeviceOnly。
- [ ] testBoundsAndMissingKey：N仅1～10、默认3；坏配置可恢复，不静默保存无效URL或泄露原始系统错误。

## 执行步骤

- [ ] 读取 AGENTS.md、project-constraints、architecture 和上述正式方案章节；确认前置报告通过。
- [ ] 从同一已冻结契约的 main 创建独立 worktree／分支，记录任务与基线 commit。
- [ ] 对业务逻辑先写上述具名行为测试，运行确认因缺少行为失败；环境／设备任务先记录当前基线。
- [ ] 只在本任务范围实现最小交付，不代写其他任务；需要生产依赖时先用任务内协议假实现。
- [ ] 完成验收并执行检查：`./scripts/verify.sh`；`./scripts/test.sh '<simulator-UDID>' -only-testing:LiveSubtitleTests`。可缩小到本任务测试类迭代，但提交前执行当前全套测试。
- [ ] 完成独立commit；按 HANDOFF.md 记录命令结果、未验证项、initializer 和契约请求，由集成人审查合并。

补充：Keychain 集成测试独立标注环境要求，不操作真实用户凭证。Key 错误用安全类别；未选 team 时不伪造 entitlement 或签名通过。

提交建议：`feat(storage): 偏好、配置与 Keychain`。验收未通过时保留未完成状态，不把任务清单勾为成功。
