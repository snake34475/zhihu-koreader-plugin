# Zhihu KOReader Plugin

面向 Kindle + KOReader 的知乎只读客户端原型。已加入扫码会话校验及按需正文/评论读取代码；离线模拟通过，仍需在 PW4 逐关验收，不能据此承诺设备端登录或全文可用。

2026-11-03 已补充多平台阅读需求及 KUAL、EPUB、PW4 系统路线调研，见 [MULTIPLATFORM_RESEARCH.md](MULTIPLATFORM_RESEARCH.md) 和 [TODO.md](TODO.md)。目前尚未接入小黑盒、掘金、酷安、贴吧、微博或小红书。

关于 KUAL/KOReader 插件的工作原理、Lua 与 shell、EPUB 限制、PW4 Android 与墨卓线索，以及 Aristotle 的解释，见 [KINDLE_PLATFORM_EXPLAINED.md](KINDLE_PLATFORM_EXPLAINED.md)。

准备独立并行研究 Android 时，将 [PW4_ANDROID_PROJECT_BRIEF.md](PW4_ANDROID_PROJECT_BRIEF.md) 复制到新项目作为启动说明；其中包含可直接使用的开场提示。

## 目标

最终期望：在 Kindle 上刷推荐列表、看热榜，点击后阅读回答全文，并浏览评论与回复。推荐列表接受按收藏、关注主题生成，不强求复刻知乎登录后的个性化首页。

允许探索预抓取、收藏夹同步及自有后端，前提是先验证实际能取得全文与评论，不能把摘要当作全文。完整需求和待验证方案见 [IDEAS.md](IDEAS.md)。

工作树当前版本为 `0.2.6`。热榜、推荐、问题回答列表使用知乎网页端接口；知乎直答继续使用开放平台，实现：

- 知乎热榜、个性化推荐与问题回答摘要列表
- 知乎直答
- 结果缓存与离线重读
- 对单条回答手动尝试匿名网页正文探测（实验功能，历史 PW4 实测遇到人机验证）

另有独立的 [`zhihu-qr-probe.koplugin`](zhihu-qr-probe.koplugin/README.md) 扫码可行性 demo。网页登录态默认只留在内存；开启“保持登录”后 Cookie 以权限 0600 的明文文件保存在设备，启动后会重新验证。网页列表端点已在 PW4 探针通过，完整阅读流程仍待实机验收。收藏夹同步、预抓取和后端未实现。点赞、评论发布、关注操作、私信和视频播放不在只读目标中。

## 目标设备

- Kindle Paperwhite 4（用户设备）
- KOReader 2026.07.x
- Lua KOReader plugin API

## 重要安全边界

- 热榜、推荐、问题回答列表使用网页登录 Cookie；知乎直答单独使用开放平台 Access Secret。两类凭证互不混用。
- Access Secret 不得提交到 Git、日志、截图或命令行。
- 阅读内容不会后台轮询；只有用户主动登录并显示二维码期间，插件才轮询扫码状态，取消、挑战或过期后停止。
- 配置文件和缓存需要在设备上单独备份，仓库只保存示例配置。

## 当前状态

工作树代码版本为 `0.2.6`：移除搜索；热榜、推荐、问题回答列表改用网页端会话客户端和独立缓存，直答保留开放平台；回答正文使用底部固定操作栏，左右滑动切换回答。网页登录会话可选择“保持登录”，正文/评论缓存独立保存并通过完整性检查。

网页登录列表迁移前的 82 项测试在 LuaJIT 2.1 通过；持久会话变更尚待回归验证。桌面测试以模拟网络和 KOReader 控件运行。2026-11-03 PW4 登录页返回 HTTP 302 `verification_required`，扫码路线按门槛停止；用户 Cookie 探针验证热榜、推荐和问题回答端点均 HTTP 200，详见 [STATUS.md](STATUS.md)。

插件说明与安装步骤见 [zhihu.koplugin/README.md](zhihu.koplugin/README.md)。已建立 SSH 安装流程，更新会备份旧插件并保留设备配置；测试只使用虚构内容，不读取或展示用户密钥。

PW4 接口验证、Cookie 导入和插件部署的常见误区见 [PITFALLS.md](PITFALLS.md)。

搜索入口已按用户需求移除。当前已知缺口：官方问题回答接口提供摘要；官方创作全文和创作评论接口限制为账号本人的内容。切换 CLI/MCP 本身不解决通用全文、评论缺口。

当前进度、失败尝试与下一道验证门槛见 [STATUS.md](STATUS.md)；待办见 [TODO.md](TODO.md)，历史设计与扩展想法见 [PLAN.md](PLAN.md) 和 [IDEAS.md](IDEAS.md)。新对话先阅读 [NEXT_PROMPT.md](NEXT_PROMPT.md)。

## 凭证与隐私

仓库只包含空密钥示例与虚构测试数据，不包含设备真实配置、Access Secret、Cookie、SSH 私钥、缓存、部署包或设备截图。运行配置保存到设备 KOReader 数据目录的 `settings/zhihu_configuration.json`，不要提交该文件。

Git 忽略规则是辅助措施，提交前仍需检查暂存文件。手机扫码填写密钥只是设计方案，当前没有此功能；可通过设备设置页填写，或自行使用加密 SSH/SCP 编辑配置。

## 本地测试

开发机需要 Python 3 和 `lupa`，设备端无需安装它们。在项目根目录运行：

```sh
python3 -m pip install lupa
python3 zhihu.koplugin/tests/run.py
```

测试优先使用 LuaJIT 2.1，若本机 `lupa` 未提供该运行时则使用 Lua 5.4。测试只使用自行编写的虚构 JSON fixture，不发送网络请求，不读取真实配置。覆盖范围和运行方式见插件说明。
