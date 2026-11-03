# 后续接手说明

本项目目标是在 Kindle + KOReader 上独立阅读知乎热榜、回答全文和评论，离线时重读已获得的内容。用户不希望依赖常驻电脑或自建服务器；手机扫码确认登录可以接受。推荐列表可来自收藏、关注主题或热榜，不要求复刻原生个性化首页。

2026-11-03 用户补充多平台需求：小黑盒、掘金、酷安、贴吧、微博、小红书等，并要求分析 KUAL/KOReader、EPUB 九宫格以及 PW4 Android/精简系统。先读 [MULTIPLATFORM_RESEARCH.md](MULTIPLATFORM_RESEARCH.md) 和 TODO 新章节。建议统一 KOReader 阅读插件加独立平台适配器，KUAL/EPUB 是辅助入口和导出；尚未实现或最终选定。其他平台探针无需等待知乎登录成功。开发机掘金列表可达但所测详情业务报错，空评论不构成可用证据；PW4 Android 未验证可用发布，PlainOS 说明仍标待发布。不要恢复时丢失这些需求或默认执行刷机。

同日后续：用户要求讲解 KUAL/KOReader/EPUB 原理、Lua/shell、PW4 移植障碍、AI 是否可帮助、知乎/微信读书/番茄兼容与 Aristotle，并提供小红书“墨卓”个人付费闭源项目线索。已写 [KINDLE_PLATFORM_EXPLAINED.md](KINDLE_PLATFORM_EXPLAINED.md)。须区分更换启动内核和共享原内核运行安卓；找到 PW4 fastboot 受限与签名门槛的社区记录，但未查明 PlainOS 延迟或墨卓不支持 PW4 的根因。墨卓原始笔记公开工具无法读取，二次 AIGC 介绍不作技术证据。未连接设备、未检查 APK 或安装 Aristotle，不要把推断写成实测。

用户随后决定准备另开项目并行研究 Android，已交付可独立复制的 [PW4_ANDROID_PROJECT_BRIEF.md](PW4_ANDROID_PROJECT_BRIEF.md)，建议项目名 `pw4-android-lab`。这里只准备了交接文档，未创建新项目/聊天，未启动设备实验；当前仓库继续做阅读插件。两个项目的设备操作要协调，不能同时接管同一台 PW4 的界面或服务。

开始前阅读 [README.md](README.md)、[STATUS.md](STATUS.md)、[TODO.md](TODO.md)；[PLAN.md](PLAN.md) 与 [IDEAS.md](IDEAS.md) 保留历史产品设计。先运行离线测试并查看 Git 工作区，再继续修改。仓库已包含 0.2.2 摘要插件（阅读页侧栏/滑动、标题栏时钟、夜间模式）、匿名单条回答探测及隔离的 `zhihu-qr-probe.koplugin` demo。

已知实测：PW4 对公开回答匿名网页详情返回 403 人机验证；扫码 demo 的登录页在 PW4 也直接进入人机验证，未取得登录态；Search1API 对所测知乎回答返回 502。详见 [STATUS.md](STATUS.md)。不要把 API 文档示例、其他项目的源码或接口 200 推断成“此设备已取得全文”。

下一步先对照开源客户端补齐隔离 demo 的登录初始化与状态分类，再在 PW4 上验证。若登录页仍进入验证，停止 Kindle 端扫码路线；若 Kindle 独立取得登录态，才请求短、长、无权回答详情并核对正文完整性。正式插件的全文按钮、登录态保存与缓存要等这几步实机通过后再规划。设备上需要用户用自己的手机扫码；demo 不收账号密码。

实际 Access Secret、Cookie、二维码令牌、签名值、设备地址、个人缓存和回答正文不得进入聊天、命令行参数、日志、截图或 Git。连接设备时从用户或本地私密配置取得地址及认证信息，不猜测。设备安装通常位于 `/mnt/us/koreader/plugins/zhihu.koplugin`，更新前应备份旧版并保留设置文件。
