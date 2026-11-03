# 项目进度与试验记录

更新：2026-11-03。这里记录已经观察到的结果；代码存在不等于在 Kindle 上可用。公开仓库不保存凭证、二维码令牌、正文、设备地址或个人缓存。

## 当前交付

| 部分 | 状态 | 已验证范围 |
|---|---|---|
| `zhihu.koplugin` 0.2.6（已部署，待重启加载） | 回答页底部操作栏与整页刷新修复；移除侧边导航按钮 | 设备文件核对为 0.2.6；实机显示和触摸验收待 KOReader 重启 |
| 匿名单条回答探测 | 可选实验 | 用户点击后向知乎网页详情接口请求一次；PW4 对测试回答返回 403 人机验证，未取得正文 |
| `zhihu-qr-probe.koplugin` | PW4 登录门槛失败 | 2026-11-03 在 PW4 运行新版设备探针，登录页 HTTP 302，被分类为 `verification_required`；按停止门槛结束，未请求 `/udid`、未生成二维码 |
| 手工 Cookie 单次探针 | 内容读取通过初步门槛 | 用户在本机隐藏输入 Cookie，经 SSH stdin 临时送入 PW4；热榜 HTTP 200/30 条，指定回答详情 HTTP 200，正文 1,478 字节（规范化文本 1,198 字节），回答 ID 匹配，未见付费/截断标记；评论第一页与第二页均 HTTP 200、各 10 条非空且均有下一游标 |
| KOReader 临时会话导入 | PW4 导入成功 | 一次性交接文件在 `/tmp` 有效 10 分钟，设置页消费即删除；`/api/v4/me` 校验通过后只存 KOReader 内存。另新增只需 Cookie 的快速导入脚本，尚待本机运行验收 |
| 可选保持登录 | 已实现并部署，待重启和实机验收 | 开关默认关闭；开启后白名单 Cookie 存入设置目录 `zhihu_session.json`，通过 LuaJIT FFI 将文件权限设为 0600；恢复时先校验 `/api/v4/me`。尚未在 PW4 验证文件权限与重启恢复 |

开放平台 Access Secret 与知乎网页登录会话相互独立。临时导入文件在 PW4 `/tmp` 有效 10 分钟，插件导入时立即删除。登录 Cookie 默认只在 KOReader 内存；用户开启“保持登录”后，白名单 Cookie 以明文保存在设置目录单独文件，权限 0600，KOReader 重启后会在首次登录请求前校验 `/api/v4/me`。关闭保持登录、账号会话过期或手动退出时删除文件。KOReader 设置目录备份也可能包含可用会话凭证。匿名探测不带 Cookie 或 Access Secret，也不缓存正文；失败时摘要仍可读。

网页列表迁移前的 82 项正式插件离线测试在 LuaJIT 2.1 通过；迁移后工作树未重新运行测试。扫码 demo 的协议模拟测试也通过。模拟覆盖二维码过期、挑战、扫码与会话分离、Cookie 更新、回答付费/截断、评论游标、临时 Cookie 白名单/过期、缓存和 UI 会话清理。PW4 上的登录页扫码路线因 302 `verification_required` 停止；用户自有浏览器 Cookie 的回答详情和评论两页实机探针已通过初步门槛。

## 已做试验及结论

1. **官方开放平台**：仅知乎直答继续使用开放平台；热榜、问题回答和推荐列表已切换为网页端会话接口，搜索已移除。问题回答摘要不等于通用回答全文。本人创作详情/评论接口不适用于任意他人的内容。接口契约见 [API_CONTRACT.md](zhihu.koplugin/API_CONTRACT.md)。
2. **直接读取知乎网页详情**：匿名请求 `www.zhihu.com/api/v4/answers/{id}`，PW4 对一条公开回答返回 HTTP 403，提取正文 0 字；原始页面和移动端详情也返回 403。此结果只代表该样例、设备和当时网络。
3. **知乎扫码登录**：此前普通 HTTP 请求曾取得二维码，但扫码状态接口返回环境验证 40352。2026-11-03 用新版探针在 PW4 复测，登录页返回 HTTP 302 并分类为 `verification_required`；没有继续设备初始化或二维码步骤。按计划停止设备端登录路线，不通过改头、浏览器伪装或自动解题继续尝试。
4. **Search1API**：按[官方 Crawl 文档](https://s1.dev/docs/basic/crawl)用有效密钥调用 `POST /crawl`；通用网页返回 200，所测知乎回答与文档中的知乎回答示例返回 502。PW4 上同类回答请求也返回 502。说明请求形式可用，但该服务在这些样例上没有交付全文；不能接入正式阅读功能。
5. **其他候选**：开发机上 Jina Reader 对两条知乎回答链接返回了文本，但尚未核对与原文的完整性；PW4 连该服务超时。FXZhihu 在 PW4 上解析失败，不能当作可用来源。Qovia 端点可达，但缺少有效调用验证，未证明能返回全文。
6. **手工 Cookie 单次探针**：2026-11-03 用户主动在本机隐藏输入浏览器 Cookie，由临时脚本经 SSH stdin 发给 PW4 进程内存。PW4 对 `api.zhihu.com/topstory/hot-list` 返回 HTTP 200、30 条，对问题回答列表返回 HTTP 200、1 条；该条 `content` 非空、393 字节，`excerpt` 缺失、`is_normal=true`。请求退出后 Cookie 未保留。短正文和列表接口不能证明指定回答的详情完整，也未测试评论；下一步需用用户提供的长回答 URL 做详情与评论第一页探测。日志未包含 Cookie、正文或标题。
7. **指定回答详情探针首次尝试**：用户给出长回答链接并在本机重新输入 Cookie 后，PW4 对 `www.zhihu.com/api/v4/answers/{id}` 返回 HTTP 200。探针错误地期待响应有 `data` 包装层，未提取正文且停止在解析阶段；没有请求评论。已根据插件现有 API 实现修正为顶层对象解析，需要用户在本机对同一链接重跑；此前响应正文未记录。
8. **指定回答与评论两页**：用户最近一次完整详情探针结果：回答 HTTP 200，原始 `content` 1,478 字节，规范化纯文本 1,198 字节，ID 匹配且未见付费/截断标记。评论前两页均 HTTP 200、各 10 条非空，仍有下一游标。随后用户报告 KOReader 会话导入成功，故账号校验与临时交接已通过。接口没有可靠全文标记，不能据此断言任意回答完整。

这些记录不包含响应正文、凭证、二维码令牌或签名值。HTTP 状态与完整性判断是实验结果；第三方服务的内部抓取方式没有源码时属于推断。

## 可核对的开源路线

- [知乎++ Android](https://github.com/zhihu-plus/android/blob/master/shared/src/commonMain/kotlin/com/github/zly2006/zhihu/data/ContentDetailCache.kt) 请求回答详情的 `content` 与 `excerpt`；其[扫码代码](https://github.com/zhihu-plus/android/blob/master/shared/src/commonMain/kotlin/com/github/zly2006/zhihu/account/QrLogin.kt)还处理初始化、轮询和风控。它展示了具备浏览器组件的独立手机客户端路线，不证明 PW4 可复用。
- [知乎--](https://github.com/huamurui/zhihu-minus-minus/blob/main/src/api/zhihu/answer.ts) 也请求回答详情的 `content`；[导出实现](https://github.com/huamurui/zhihu-minus-minus/blob/main/src/features/content-export/resolveSource.ts)检查截断、登录和付费标志。该客户端用 WebView 完成登录。
- [zhihu-webbridge-research](https://github.com/p1lab/zhihu-webbridge-research/blob/main/scripts/fetch_zhihu_content.py) 在已登录的浏览器页面中同源请求回答详情，依赖桌面浏览器会话。
- [FXZhihu](https://github.com/frostming/fxzhihu/blob/main/src/answer.ts) 在服务端用登录 Cookie 请求并渲染 `content`，依赖服务端凭证。

这些项目提供了接口和字段的可核对实现。这里没有独立验证它们当前能读取任意指定回答，更没有证明 Kindle 能绕过登录验证。

## 当前接口切换范围

- 搜索入口、API 方法、设置项与缓存类型已从工作树代码移除；知乎直答继续使用 `POST /v1/chat/completions` 和独立 Access Secret。
- 热榜、问题回答列表、推荐均已接入网页端会话请求；推荐是单独频道，搜索已移除，知乎直答不变。
- 新增 `tools/zhihu_feed_probe.py`：隐藏输入 Cookie，仅送到 PW4 进程内存；输出账号校验、HTTP 状态、条目计数、字段形状和分页标记，不输出标题、正文或游标。端点若要求挑战或签名则停止，并记录拒绝类型。
- 2026-11-03 用户的 PW4 探针：账号校验 200；热榜 200/30、无下一页；推荐 200/6、有下一页；问题回答 200/10、有下一页。网页列表缓存与旧开放平台摘要缓存分别存储。

## 下一步：按门槛推进

1. 已完成新版探针 PW4 登录页复测；HTTP 302 `verification_required`，扫码路线按门槛停止，不继续请求 `/udid` 或生成二维码。
2. 用户的网页登录 Cookie 已在 PW4 探针验证 `/api/v3/feed/topstory/hot-lists/total`、`/api/v3/feed/topstory/recommend` 和 `/api/v4/questions/{id}/feeds`，均为 HTTP 200，分页字段已确认。
3. 指定回答详情及评论前两页已 HTTP 200；用户随后报告新版临时会话已在 KOReader 导入成功。0.2.6 已部署到设备，但 KOReader 尚未重启；重启后验收回答页底部“查看评论/查看摘要/刷新正文”可见且触发整页刷新，并确认侧栏已删除、左右滑动仍切换回答。
4. 0.2.6 已更新到 `/mnt/us/koreader/plugins/zhihu.koplugin`，设备文件核对版本号为 0.2.6；旧版备份位于 `/mnt/us/koreader/backups/zhihu.koplugin-20261103-195619`。普通插件升级只覆盖插件目录时，已保存的 `settings/zhihu_session.json` 会保留；重置 KOReader 设置目录或手动删除会话文件会清除它。重启 KOReader 后新代码才会加载。

## 远期展望

在可信正文来源通过设备验收后，逐步加入评论与回复分页、收藏或关注主题生成的阅读队列、阅读位置和离线重读。每条内容显示来源、获取时间和完整性状态；缺失正文或评论时仍提供摘要。产品继续以文字优先、少量按需请求和墨水屏分页为原则。

功能待办见 [TODO.md](TODO.md)，历史产品构想见 [IDEAS.md](IDEAS.md)。
