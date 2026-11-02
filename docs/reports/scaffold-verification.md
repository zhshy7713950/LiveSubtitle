# 基础框架验证记录

日期：2026-11-02。验证范围为框架和文档；不属于 G0 或产品功能验收。

执行环境：Xcode 27.2（27B52）、Apple Swift 6.4.2、iPhoneOS / iPhoneSimulator SDK 27.2，工程部署目标 iOS 27.0，Swift 6 完整并发检查。

执行命令：`./scripts/verify.sh`，退出码 **0**。

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| 文档链接、15张任务卡、共享scheme | 通过 | `scripts/check_docs.py` |
| Info.plist、project.pbxproj语法 | 通过 | `plutil -lint` |
| iOS Debug，无签名 | BUILD SUCCEEDED | `build/logs/device-debug.log` |
| iOS Release，无签名 | BUILD SUCCEEDED | `build/logs/device-release.log` |
| generic iOS Simulator App + 测试bundle | TEST BUILD SUCCEEDED | `build/logs/simulator-tests.log` |
| shell脚本语法 | 通过 | `bash -n scripts/verify.sh scripts/test.sh` |

完整日志保留在本机 `build/logs/`，不提交长日志。测试bundle实际生成在模拟器App的 `PlugIns/LiveSubtitleTests.xctest`，并有 `.xctestrun` 清单；这只证明测试入口能编译。

环境输出含受限沙箱无法连接 CoreSimulatorService 的诊断；generic 构建仍成功。未启动模拟器，未执行行为测试。Xcode 另提示未依赖 AppIntents 而跳过其元数据提取；本框架未提供 AppIntents 功能。

首轮构建发现文件系统同步组会把各目录同名 `.gitkeep` 复制为资源，造成重复输出；已在 Shared.xcconfig 显式排除 `.gitkeep`，后续三项构建均通过。

完成一次独立只读审查，接口缺口已修正并加入后续任务验收：分段定时输出流、AI目的地快照、按资源划分身份检查、调度错误携带原作业、配置／Key写入前关闭AI入口。没有剩余阻断项；修改后重新执行上述框架检查。审查只覆盖框架和任务可集成性，不替代后续行为测试。

尚未执行：签名／真机安装、模型准备、系统采集、识别、翻译、PiP、G0、A01–A24。当前没有行为测试，因此不声称单元测试通过。
