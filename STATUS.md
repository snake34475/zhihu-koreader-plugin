# 项目进度与试验记录

更新：2026-11-02。这里记录已经观察到的结果；代码存在不等于在 Kindle 上可用。公开仓库不保存凭证、二维码令牌、正文、设备地址或个人缓存。

## 当前交付

| 部分 | 状态 | 已验证范围 |
|---|---|---|
| `zhihu.koplugin` 0.2.1 | 摘要原型 | 热榜、搜索、直答、问题回答摘要分页、阅读导航、离线缓存；桌面模拟测试及 PW4 离屏控件预览 |
| 匿名单条回答探测 | 可选实验 | 用户点击后向知乎网页详情接口请求一次；PW4 对测试回答返回 403 人机验证，未取得正文 |
| `zhihu-qr-probe.koplugin` | 隔离 demo | 请求登录页、设备初始化、二维码、扫码状态；PW4 在登录页被转到人机验证，未完成扫码登录 |
| 回答全文、评论 | 未完成 | 没有在 PW4 上证明可稳定读取；不能把摘要当作全文 |

现有开放平台 Access Secret 流程与网页探测隔离。匿名探测不带 Cookie、Access Secret，不缓存正文；失败时摘要仍可读。扫码 demo 不保存登录态，也不接收密码。

本次 59 项正式插件离线测试在 Lua 5.4 通过；扫码 demo 的协议模拟测试和全部 Lua 文件语法检查也通过。0.2.1 尚未完成 LuaJIT 2.1 全量回归或 Kindle 连续操作验收。

## 已做试验及结论

1. **官方开放平台**：热榜、搜索、直答和问题回答摘要可以构成阅读原型；问题回答接口的摘要不等于通用回答全文。本人创作详情/评论接口不适用于任意他人的内容。接口契约见 [API_CONTRACT.md](zhihu.koplugin/API_CONTRACT.md)。
2. **直接读取知乎网页详情**：匿名请求 `www.zhihu.com/api/v4/answers/{id}`，PW4 对一条公开回答返回 HTTP 403，提取正文 0 字；原始页面和移动端详情也返回 403。此结果只代表该样例、设备和当时网络。
3. **知乎扫码登录**：普通 HTTP 请求曾取得二维码，但扫码状态接口返回环境验证 40352；随后 PW4 登录页直接进入人机验证，电脑上的普通请求和完整浏览器也遇到验证。现有 demo 在此处停止，没有登录态或全文结果。不能仅凭补请求头承诺解决。
4. **Search1API**：按[官方 Crawl 文档](https://s1.dev/docs/basic/crawl)用有效密钥调用 `POST /crawl`；通用网页返回 200，所测知乎回答与文档中的知乎回答示例返回 502。PW4 上同类回答请求也返回 502。说明请求形式可用，但该服务在这些样例上没有交付全文；不能接入正式阅读功能。
5. **其他候选**：开发机上 Jina Reader 对两条知乎回答链接返回了文本，但尚未核对与原文的完整性；PW4 连该服务超时。FXZhihu 在 PW4 上解析失败，不能当作可用来源。Qovia 端点可达，但缺少有效调用验证，未证明能返回全文。

这些记录不包含响应正文、凭证、二维码令牌或签名值。HTTP 状态与完整性判断是实验结果；第三方服务的内部抓取方式没有源码时属于推断。

## 可核对的开源路线

- [知乎++ Android](https://github.com/zhihu-plus/android/blob/master/shared/src/commonMain/kotlin/com/github/zly2006/zhihu/data/ContentDetailCache.kt) 请求回答详情的 `content` 与 `excerpt`；其[扫码代码](https://github.com/zhihu-plus/android/blob/master/shared/src/commonMain/kotlin/com/github/zly2006/zhihu/account/QrLogin.kt)还处理初始化、轮询和风控。它展示了具备浏览器组件的独立手机客户端路线，不证明 PW4 可复用。
- [知乎--](https://github.com/huamurui/zhihu-minus-minus/blob/main/src/api/zhihu/answer.ts) 也请求回答详情的 `content`；[导出实现](https://github.com/huamurui/zhihu-minus-minus/blob/main/src/features/content-export/resolveSource.ts)检查截断、登录和付费标志。该客户端用 WebView 完成登录。
- [zhihu-webbridge-research](https://github.com/p1lab/zhihu-webbridge-research/blob/main/scripts/fetch_zhihu_content.py) 在已登录的浏览器页面中同源请求回答详情，依赖桌面浏览器会话。
- [FXZhihu](https://github.com/frostming/fxzhihu/blob/main/src/answer.ts) 在服务端用登录 Cookie 请求并渲染 `content`，依赖服务端凭证。

这些项目提供了接口和字段的可核对实现。这里没有独立验证它们当前能读取任意指定回答，更没有证明 Kindle 能绕过登录验证。

## 下一步：按门槛推进

1. 在隔离扫码 demo 中对照知乎++ 补齐必要的登录初始化和状态分类，在 PW4 上记录每一步 HTTP 状态。若登录页仍直接进入人机验证，停止设备端扫码路线；不把电脑浏览器作为隐含依赖。
2. 只有 Kindle 自己取得并验证登录态，才用该登录态请求回答详情。分别测试短回答、长回答和登录后仍无权阅读的回答；记录 HTTP 状态、提取字数、截断/付费判断，不记录正文。用户在手机上完成扫码确认。
3. 两项都通过后，才设计登录态安全保存、按需「尝试获取全文」与离线缓存。断网、取消、过期和登录态失效都保留现有摘要。
4. 若第一项失败，单独验证可在 PW4 访问的第三方全文来源或用户主动导入的离线内容。先用指定回答证明完整性和费用，再决定是否接入；服务器和电脑常驻方案不符合当前“Kindle 独立阅读”目标。

## 远期展望

在可信正文来源通过设备验收后，逐步加入评论与回复分页、收藏或关注主题生成的阅读队列、阅读位置和离线重读。每条内容显示来源、获取时间和完整性状态；缺失正文或评论时仍提供摘要。产品继续以文字优先、少量按需请求和墨水屏分页为原则。

功能待办见 [TODO.md](TODO.md)，历史产品构想见 [IDEAS.md](IDEAS.md)。
