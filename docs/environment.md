# 当前工程环境

核对日期：2026-11-02。

- Xcode：27.2，Build 27B52；`/Applications/Xcode.app`。
- Swift：Apple Swift 6.4.2；工程语言模式 Swift 6。
- iPhoneOS SDK：27.2；iPhoneSimulator SDK：27.2。
- Deployment target：iOS 27.0；目标设备族仅 iPhone。
- 工程：原生文件系统同步目录，一个 App target、一个纯逻辑单元测试 target，共享 `LiveSubtitle` scheme。
- 运行依赖：仅系统框架；无第三方包、生成器或服务端。

正式方案保留编写时“只有 Command Line Tools”的历史记录；本文件反映当前工具状态，不据此改写原方案的证据边界。

本次无签名构建结果见 [框架验证](reports/scaffold-verification.md)。尚未进行开发签名、真实 iPhone 安装、音频采集、模型下载、本地翻译、后台 PiP 或 G0 验证；测试 target 只有编译入口，无行为测试。

受限执行环境无法连接 CoreSimulatorService；可使用 generic simulator 目标检查编译，实际启动／测试需在可访问模拟器服务的环境执行。个人签名配置放 `Config/Local.xcconfig`，不提交仓库。
