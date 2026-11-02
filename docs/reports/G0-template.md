# G0 真机链路报告模板

状态：**未执行**。复制为 `g0-device-report.md` 后填写；不要把模板当成通过记录。

## 环境

| 项目 | 实测值 |
| --- | --- |
| 源码commit / 构建配置 | 待填写 |
| Xcode / SDK / macOS | 待填写 |
| iPhone机型 / iOS完整版本 / Chrome版本 | 待填写 |
| 签名是否安装成功 | 待填写（不记录证书或设备标识） |
| 语言对 / 模型资源就绪状态 / 测试素材类型 | 待填写 |

## API 核对

- 系统全屏共享选择器的可用签名、取消和撤销：待填写。
- SCStream音频输出及后台screen-capture配置：待填写。
- Speech实际输入格式、volatileResults、audioTimeRange、结束API：待填写。
- 前台Translation资源准备和非UI已安装会话：待填写。
- sample-buffer PiP及Receiver入队、音频混音、是否需额外能力：待填写。

## 分项证据

| 项目 | pass/fail/blocked/not-run | 观察／无内容指标 |
| --- | --- | --- |
| Chrome正常出声、采集有效非静音音频 | not-run | |
| 本机连续识别得到可理解文字 | not-run | |
| 本机翻译输出 | not-run | |
| 返回Chrome后PiP持续刷新 | not-run | |
| 连续十五分钟无持续积压／进程终止 | not-run | |
| 用户关闭、恢复App、系统撤销、锁屏分别清理 | not-run | |

记录真实时长、最大音频积压／待翻译数、断流／丢弃数、内存起止与峰值、热状态。报告不附字幕、音频或真实服务响应。

## 结论

G0：未执行。阻断项：待填写。需要修改的SDK假设／契约：待填写。没有完整链路证据时不启动正式模块扩展。
