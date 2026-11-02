# 正式验收报告模板

状态：**未执行**。复制为 `acceptance-report.md`，逐行填写；口径来自正式方案 §16，不以本模板替代完整标准。

环境：commit、App版本、Xcode／SDK、iPhone机型、iOS完整版本、Chrome版本、语言对、网络条件、AI服务及模型（不含Key和URL查询）。

| 编号 | 场景 | pass/fail/blocked/not-run | 证据／实测值／缺陷 |
| --- | --- | --- | --- |
| A01 | 首次资源缺失与取消 | not-run | |
| A02 | 不支持语言／语言对 | not-run | |
| A03 | 英文→简中本地 | not-run | |
| A04 | 下载后断网本地 | not-run | |
| A05 | MP4、HLS、嵌入、直播 | not-run | |
| A06 | 切站和切视频 | not-run | |
| A07 | 页内、横屏和全屏 | not-run | |
| A08 | 扬声器、耳机、蓝牙 | not-run | |
| A09 | AI正常SSE | not-run | |
| A10 | SSE随机分块和Unicode | not-run | |
| A11 | AI故障后锁定本地 | not-run | |
| A12 | 固定句手动恢复 | not-run | |
| A13 | 修订、错序、晚到、主动取消与有效超时 | not-run | |
| A14 | 长句、十分钟无final、有界文字窗口 | not-run | |
| A15 | N=3→1→10→3 | not-run | |
| A16 | 双语／仅译文 | not-run | |
| A17 | PiP关闭与恢复 | not-run | |
| A18 | 撤销采集、锁屏和来电 | not-run | |
| A19 | 停止后旧回调及快速重启 | not-run | |
| A20 | 其他视频PiP替换 | not-run | |
| A21 | deadline及队列压力 | not-run | |
| A22 | 停止、重启无历史 | not-run | |
| A23 | 日志、缓存与网络内容边界 | not-run | |
| A24 | 连续三十分钟 | not-run | |

性能另存 `performance-report.md`：至少100段固定非敏感素材，记录计时起点、样本数、P95、最大积压、内存起止／峰值／趋势及热状态。目标：排队≤250ms、原文≤1.5s、本地译文≤3s、AI首译≤4s；停止后新job=0。AI结果绑定实际服务和网络。

质量至少100段人工双语抽样，区分识别、翻译、重复／漏段、数字专名和修订闪动。无原文正文的汇总进仓库，敏感素材和原始内容不提交。

结论与已知限制：待填写。未通过项、未测项及负责人处理决定：待填写。
