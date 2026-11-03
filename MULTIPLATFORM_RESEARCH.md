# 多平台阅读、KUAL 与 PW4 系统路线调研

调研日期：2026-11-03。范围：仓库代码审阅、公开文档与开源源码核对，以及开发机上的少量匿名请求。本文是设计建议，不代表已接入平台、已验证设备网络、已部署服务或已完成系统适配。

同日后续补充：用户要求进一步解释原理，并提供“墨卓”付费闭源安卓环境线索。见 [KINDLE_PLATFORM_EXPLAINED.md](KINDLE_PLATFORM_EXPLAINED.md)。Android 必须分开评估“替换/双启动目标内核”和“共享 Kindle 原内核运行安卓用户空间”；本文件先前以完整系统移植为主，不能把其启动链限制直接套用到第二类。后续已找到 PW4 受限 fastboot 的社区原始记录，但墨卓实现及其不支持 PW4 的原因仍未核实。

## 1. 需求与建议结论

用户补充希望阅读小黑盒、掘金、酷安、贴吧、微博、小红书，以及其他适合的平台；需要统一入口、热门/推荐列表、正文、评论与回复，并考虑九宫格、独立插件、EPUB、KUAL 和 Android/精简系统路线。

已有约束继续有效：设备为 Kindle Paperwhite 4（2018，第 10 代，简称 PW4），已经能运行 KOReader；日常阅读不依赖常驻电脑或自建服务器，允许联网时主动获取、断网时重读，以及手机扫码确认。当前设备固件版本、本次运行内存和可用空间没有重新读取。

建议采用 **一个 KOReader 阅读插件 + 每个平台独立适配模块 + 共用内容模型、缓存和阅读界面**。KUAL 可增加启动入口；EPUB 用于导出已取得的内容和评论快照。先验证两个不同结构的平台，再抽取公共代码，避免先为所有平台重写框架。

平台适配与阅读载体是两件事。换 KUAL、浏览器、EPUB 或操作系统，均不能自动补齐正文、评论接口和账号权限。若最终最重要的是直接使用各平台原生个性化首页、登录与完整互动，那么现代 Android 设备运行官方 App 是另一条产品路线，不能要求当前只读聚合器等价实现。

## 2. 当前代码能复用什么

已经存在的模块有清晰边界，但仍与知乎语义紧密绑定：

| 现有模块 | 可复用部分 | 扩展前需要改变的部分 |
|---|---|---|
| `main.lua` | KOReader 菜单注册、延迟初始化 | 当前仅初始化一个知乎客户端，未来增加平台注册表和入口 |
| `zhihu_api.lua` | 有界 HTTP 响应、错误分类、可替换传输 | 请求默认携带知乎鉴权，不能直接用于其他域名 |
| `zhihu_schema.lua` | 统一字段、文本与链接校验思路 | 当前 `Data.Items`、问题/回答结构和知乎 URL 校验需留在知乎适配器内 |
| `zhihu_ui.lua` | 取消、超时、列表分页、导航流程 | 当前问题→回答和评论提示写在控制流程中，需要按内容类型分发 |
| `zhihu_page.lua`、`zhihu_reader.lua`、`zhihu_clock.lua` | 原生列表、侧栏、时钟、手势 | 阅读页当前以纯文本为主，不是完整图文/代码排版器 |
| `zhihu_cache.lua` | 有界缓存、离线读取与校验思路 | 当前按 hot/search/answer 和最近问题保存，需按平台、对象、账户和分页隔离 |
| `zhihu_storage.lua`、`zhihu_renderer.lua` | 原子写入、文本清洗 | 长正文、图片、代码块、评论引用需明确转换规则和大小上限 |

不建议现在复制出六七份 `zhihu.koplugin`。这会让同一个时钟、阅读位置、翻页或缓存修复重复维护多次。也不建议一次性改名和搬移整个现有插件；应保留已有安装与配置路径，先通过适配层接入第二个平台。

## 3. 各平台的接入证据与缺口

下表的“有实现”只表示可以核对源码，并不代表该路由当前在 PW4 可用，更不表示是平台承诺支持的公开 API。

| 平台 | 已查到的入口与正文参考 | 评论/推荐仍需验证的内容 | 建议 |
|---|---|---|---|
| 小黑盒 | RSSHub 有游戏新闻、用户动态，以及另行请求分享详情正文的实现 | 游戏新闻≠社区综合热门；社区频道、个人推荐、评论/回复分页尚无本次实测 | 作为用户重点平台尽早做独立可行性探针，先限定游戏新闻与公开分享 |
| 掘金 | RSSHub 有分类、热门、标签等路由，并从文章网页另取正文，失败可能回退摘要 | 当前详情访问可能遇到校验；评论必须证明非空、分页与回复，不能由 `comment_count` 推断可读 | 首批候选，先验证全文再做正式界面 |
| 酷安 | RSSHub 有今日热门、多个榜单、用户动态；对摘要动态再取详情，并处理图文块 | 使用 App token 与版本相关请求头；热评、评论和回复需独立接入，未在 PW4 实测 | 第二批；按用户兴趣也可提前做小探针 |
| 贴吧 | RSSHub 有吧列表、精品、帖子动态和只看楼主；客户端接口实现涉及签名，部分页面需要 Cookie | 帖子楼层、楼中楼是两层分页；“最新回复订阅”不等于从首楼完整读帖；吧内列表不等于全站推荐 | 适合文字阅读，但必须保留论坛层级 |
| 微博 | RSSHub 有热搜、博主、关键词等路由；热搜的 `fulltext` 选项明确只取相关摘要 | 访客会话、登录限制、长文、根评论与回复可能分别请求；参考路由带浏览器自动化依赖 | 可先做热搜发现/指定博主，完整阅读后续验证 |
| 小红书 | RSSHub 有用户笔记/收藏；Cookie 分支尝试正文，普通分支可能只有标题和封面 | Cookie、浏览器环境、笔记链接上下文、图片完整性、评论与回复；这些路由不能证明发现页推荐可取 | 后期实验，优先指定链接/用户主动导入 |
| 知乎 | 仓库已实现官方热榜、搜索、回答摘要与缓存 | PW4 既往全文及登录探测被验证拦截；完整评论未完成 | 保留现有能力，按既有验证门槛继续推进 |

证据分别见 RSSHub 的[小黑盒新闻](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/xiaoheihe/news.ts)、[用户动态](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/xiaoheihe/user.ts)、[掘金分类](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/juejin/category.ts)、[热门](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/juejin/trending.ts)、[正文处理](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/juejin/utils.ts)、[酷安热榜](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/coolapk/hot.ts)、[详情处理](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/coolapk/utils.ts)、[贴吧帖子](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/baidu/tieba/post.ts)、[贴吧请求](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/baidu/tieba/common.ts)、[微博热搜](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/weibo/search/hot.tsx)、[博主路由](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/weibo/user.ts)和[小红书用户路由](https://github.com/DIYgod/RSSHub/blob/master/lib/routes/xiaohongshu/user.ts)。这些是随上游变化的参考，不能直接作为接口稳定性承诺。

没有在本次核对到上述六个平台均提供面向普通个人聚合阅读器、覆盖任意内容和完整评论的稳定官方通用 API。这个表述是本次调研范围内的结论，不能推断平台不存在其他合作能力。

### 可补充的平台

- **V2EX**：官方 API 2.0 文档列有节点主题、主题详情、分页回复，使用 Personal Access Token；适合验证“列表→正文→评论”整体链路，但仍需真实令牌和 PW4 验收。节点主题也不能直接标成全站热榜。[官方文档](https://www.v2ex.com/help/api)
- **Hacker News**：官方 API 有热门 ID、条目与评论树，适合测试异构内容模型；外链新闻正文通常还要去原站获取，HN API 不提供那些站点的全文。优先用 Ask HN 等站内文本主题测试。[官方文档](https://github.com/HackerNews/API)
- **RSS/Atom 和独立博客**：适合订阅和离线阅读，但 feed 可能只有摘要，评论也不是通用字段。可先复用 KOReader 自带新闻下载器验证订阅体验，当前上游实现会生成 EPUB；设备的 2026.07.x 版本行为仍需单独核对。[上游源码](https://github.com/koreader/koreader/blob/master/plugins/newsdownloader.koplugin/main.lua)

### RSSHub 应处于什么位置

它可以用作接口研究参考，或作为可选的 feed 来源。直接访问 RSSHub 实例，仍依赖外部服务；公共实例不保证目标路由可用，也不应承载用户的私有 Cookie。自建 RSSHub 会增加服务器依赖，与当前日常使用约束不一致。它输出 RSS 并不自动提供评论树、历史分页或真正的个人推荐。

此外，当前 RSSHub 仓库标注 AGPL-3.0，不能沿用旧资料中的 MIT 假设。若后续复制代码或部署修改版，再针对实际使用方式核对许可要求；本次仅参考并链接源码。[项目仓库](https://github.com/DIYgod/RSSHub)

## 4. 本次开发机匿名请求结果

仅做少量公开请求，不登录、不处理挑战、不输出正文或凭证。所有结果只证明开发机和当时网络的单次响应。

| 请求 | 实际结果 | 能够支持的判断 |
|---|---|---|
| 掘金分类 `GET /tag_api/v1/query_category_briefs` | HTTP 200，`err_no=0`，8 个分类 | 有可解析分类入口 |
| 掘金前端分类 `POST /recommend_api/v1/article/recommend_cate_feed`，limit=3 | HTTP 200，`err_no=0`，3 条，`has_more=true` | 列表入口可响应；未验证下一页连续性 |
| 上述列表中一个条目的文本长度 | 摘要 51 字符；`content`、`mark_content`、`web_html_content`、`app_html_content` 均为 0 | 字段存在不等于有正文 |
| 对该条目 `POST /content_api/v1/article/detail` | HTTP 200，`err_no=2`，`data=null` | 本次详情失败；不推断具体原因，也不推断所有文章均不可取 |
| 同一条目 `POST /interact_api/v1/comment/list`，limit=3 | HTTP 200，`err_no=0`，空数组，`has_more=false` | 没有证明非空评论或分页可读，可能确实无评论 |
| HN `GET /v0/topstories.json` | HTTP 200，500 个 ID | 仅证明热门 ID 列表可达，正文/评论未实测 |

本次未在 PW4 发起这些请求，未测试其他平台的实时内容，未验证任何平台完整登录和评论闭环。下一阶段应记录指定样例的稳定 ID、时间、状态和长度，但不将真实正文、个人数据或凭证写入仓库。

## 5. 独立插件、统一插件、KUAL 与 EPUB 选型

| 方案 | 优势 | 主要代价 | 适用判断 |
|---|---|---|---|
| 每个平台一个 KOReader 插件 | 可独立发布；实验故障较容易隔离 | 阅读页、缓存、设置、升级反复维护；跨平台队列难统一 | 初期可隔离探针，不作为最终默认布局 |
| 一个 KOReader 插件，多个适配模块 | 一次安装；共用分页、缓存、阅读位置；可有统一队列 | 需要合理模型，平台异常不能拖垮首页 | 当前推荐 |
| KUAL 菜单扩展直接获取内容 | 适合启动、同步、导出或少量固定命令；不用进入 KOReader 菜单 | KUAL 菜单不是正文排版、评论树和触摸阅读框架 | 适合作为辅助入口或离线生成工具 |
| KUAL 启动独立原生阅读 App | 完全掌控启动和界面，可摆脱 KOReader 插件 API | 字体/中文排版、触摸、墨水刷新、网络取消、休眠恢复、构建和升级均需负责 | 项目确实受 KOReader 限制后再评估 |
| 纯 EPUB | 易传输、易离线、可目录/九宫格链接、可固定评论快照 | 不具备通用实时获取、登录、刷新和评论分页能力 | 作为导出格式 |
| EPUB + KOReader 链接扩展 | 书架中可有一个入口“书” | 行为依赖插件；更新 EPUB 还需处理位置与缓存一致性 | 可选外观，不作为核心架构 |
| HTML 网站/浏览器 | 手机电脑可共用，适合有服务的方案 | PW4 浏览器兼容性、动态网站、离线和自有服务依赖都需测试 | 当前不优先 |

### KUAL 为什么可以配合 KOReader

KUAL 扩展通过 `config.xml`、`menu.json` 描述菜单，并执行 shell action。KOReader 自己就提供 KUAL 菜单，包含正常启动及 `--framework_stop` 启动方式，因此两者可以处于同一条启动链中。[KUAL 菜单开发文档](https://wiki.mobileread.com/wiki/KUAL_What's_New)、[KOReader KUAL 配置](https://github.com/koreader/koreader/blob/master/platform/kindle/extensions/koreader/menu.json)

如果所谓“KUAL 插件”只是点一个按钮启动 KOReader，开发量很小，但内容获取和阅读仍由 KOReader 插件完成。如果要从 KUAL 直接进自制九宫格并在其中读评论，那么实际上需要另做原生 App。可以参考 [FBInk](https://github.com/NiLuJe/FBInk)处理文字/图片和墨水屏输出，但它不等于已经提供完整的可交互文章阅读器。

相较当前项目，独立 App 能获得更多界面控制，却不会自动拥有 WebView、Android APK 兼容层或更高的平台接口权限。性能也不能仅凭“少一层 KOReader”判断，需要对同一 PW4 上的启动、内存、翻页和耗电进行测量。

可以规划 KUAL 中的“综合阅读”“打开最近离线内容”入口。若需要启动时直达特定平台，必须实现入口参数或本地请求文件与插件启动处理的协议；不能把它写成 KOReader 现成支持的能力。

### EPUB 九宫格能实现到什么程度

可以做“平台按钮→该平台的已下载目录→正文→已下载评论”，全部为书内静态链接。三列布局可以尝试简单表格/块排版，不应默认 KOReader 支持浏览器 CSS Grid；必须检查 PW4 竖屏、大字体和触摸命中区域。

“点击平台后请求最新榜单”“继续拉下一页评论”“保持登录”需要额外程序。EPUB 标准并不要求阅读系统支持 JavaScript、表单和 DOM，且阅读器可限制网络，不能把 EPUB 当通用 Web App。[W3C EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)

KOReader 上游有外链操作及注册 URL scheme 的扩展接口，因此“入口 EPUB + 插件处理链接”值得做可选验证；但这时功能来自插件，其他阅读器不会自动获得同样行为。[ReaderLink 源码](https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerlink.lua)

EPUB 中的评论应写清获取时间、排序和收录范围，例如“已保存根评论 20 条及部分回复”，并用章节/返回链接浏览。持续更新时生成新快照并保留旧版阅读状态，避免打开的文件被原地替换。日常实时缓存适合按对象保存，导出时再打包 EPUB。

## 6. PW4 上 Android、精简与系统改造

### 结论边界

不能笼统地说“Kindle 都不能刷 Android”，也不能由 PW3/Voyage 的教程推断 PW4 可刷。到本次调研时，**未核实到可为这台 PW4 推荐的、公开发布且具备明确兼容和回退证据的 Android 方案**。这是证据不足的判断，不是声称硬件绝对无法移植。

PlainOS 的 2026-08-20 发布说明页在适配表中把 PW4 列为“近期发布”，没有在本次查到的页面中交付 PW4 版本；页面顶部又写公测仅支持 PW3，而表内写 Voyage 已发布，说明页面自身也需核对更新。不能仅凭“近期发布”执行刷机。[发布说明](https://fuquan.moe/posts/005-PlainOS-Release-Note.html)

Quill OS 公布的支持列表中有 Kindle Touch，没有 PW4；该项目的存在不能作为 PW4 可用系统镜像的证明。[项目 Wiki](https://github.com/Quill-OS/quill/wiki)

### 按改造深度区分

| 深度 | 实际做的事 | 对本项目的价值 | 当前判断 |
|---|---|---|---|
| 现有系统加 KOReader/KUAL | 保留底层系统，运行用户态应用 | 已具备开发基础 | 优先 |
| KOReader 运行期间停止原生 framework | 暂时释放部分原生界面资源，退出后恢复 | 可能改善可用内存和干扰 | 上游有启动选项；实际节电、恢复行为需同固件实测 |
| 自启动或替代首页 | 启动后进入阅读环境，减少菜单层级 | 可做出接近专用信息阅读器的体验 | 先保证退出、故障恢复、休眠和 USB 行为，再考虑持久化 |
| 原生独立界面 | 用自己的 App 替代阅读时的交互界面 | 产品自由度高 | 成本明显高于现有插件，不会直接解决数据源 |
| Linux chroot | 共用 Kindle 内核，附加另一套 Linux 用户空间 | 可做工具实验 | 不等于换内核、双系统或支持 APK；不推荐为浏览平台引入庞大运行时 |
| 全系统替换/Android 双启动 | 需要本机启动链、内核和驱动适配 | 可能运行特定版本 APK | PW4 本次未验证可用发布，不作为交付前提 |

KOReader 上游启动脚本包含 framework 停止与恢复处理，但需要按当前设备固件核验，不能把暂停原生界面等同于刷成另一个系统。[启动脚本](https://github.com/koreader/koreader/blob/master/platform/kindle/koreader.sh)

有两个可核对的 PW4 实验参考：

- [Aristotle](https://github.com/piotrkowski/aristotle)明确面向 PW4，运行时替代原生界面、退出时恢复；其 README 声明 alpha、要求 5.13.x，耗电仍未验证。它说明替代界面路线有实践，但不能推出适合当前未知固件，也不能直接搬用其内存成绩。README 给出的 PW4 内存为 512 MB，可用约 490 MB；这不是本次读取用户设备的结果。
- [Debian_kindle](https://github.com/Ooonana/Debian_kindle)声明在 PW4 上做 Debian chroot，明确 beta、有显示/稳定性问题。它仍使用 Kindle 内核。README 中一句“正在用 Android”的个人表述没有对应可核验 PW4 Android 包，不作为刷机成功证据。

### 为什么“阉割 Android”也不保证能刷这些平台

裁减系统可以减轻资源开销，却不能增加物理内存、补出驱动或满足 App 的最低系统/指令集/WebView 要求。移植 Android 还涉及启动链、设备树、触摸、墨水屏刷新、Wi-Fi、休眠、电源与用户空间兼容。仅有 root 权限不意味着这些已完成。

即使某个旧 Android 成功启动，还要逐个平台核实 APK 能否安装、能否登录、服务器是否接受旧客户端、图片与评论是否可用，以及持续使用和待机功耗。旧 App 可安装和今天仍能正常刷内容是两个验收项。目前没有为用户核验上述平台当前 APK 的最低 Android 版本，不给出“刷后全都能用”的承诺。

为了当前阅读目标，更合理的改造是可恢复地优化启动和阅读界面；永久删除系统服务、改分区、写启动镜像或尝试其他机型刷机包不属于本次调研操作。

## 7. 建议架构

```text
Kindle 原系统
  └─ KUAL / 现有启动入口（可选快捷入口）
      └─ KOReader
          └─ 综合阅读插件
              ├─ 首页：常用平台网格 / 列表、离线、稍后阅读
              ├─ 共用阅读：列表 → 主题/文章 → 评论 → 回复
              ├─ 内容服务：去重、缓存、位置、请求取消、导出
              └─ 平台适配器：知乎 / 掘金 / 小黑盒 / 酷安 / ...
```

一个仓库、一个主要插件包、每个平台独立模块和测试；先不引入微服务或独立的平台间进程。平台设置与数据分别隔离，首页只加载启用的平台，某一平台需要登录或解析失败时，其他平台仍能使用。

### 能力与模型

统一的是操作流程，不是强迫所有平台都有相同功能。能力应细分为 `feeds`、`content`、`children`、`comments`、`replies`、`search`、`auth`，并记录验证级别，例如“仅源码参考 / 开发机单例通过 / PW4 通过”，而不是一个笼统的 `supported=true`。

建议提供 `list_feeds()`、`fetch_feed(feed_id, cursor)`、`fetch_content(ref)`、`fetch_children(ref, cursor)`、`fetch_comments(ref, sort, cursor)`、`fetch_replies(comment_ref, cursor)` 等少量接口；不支持的能力明确返回不支持。`fetch_children` 容纳知乎问题下回答、贴吧帖子楼层等差异，避免把所有子内容都塞成评论。

统一对象至少记录：

- 标识：`platform`、`kind`、字符串 `id`、可选 `parent_ref`、原始链接。超长 ID 和分页游标不能转浮点数。
- 展示：标题、作者、时间、摘要、正文块。块类型先支持文本、标题、引用、代码、链接和图片占位；图片按需获取。
- 正文状态：`full / partial / excerpt / unavailable / unknown`，与 `login_required / challenge / forbidden / deleted / network_error` 等原因分别保存。
- 评论覆盖：排序、已缓存根评论数、回复范围、不透明游标、当前页是否结束、抓取时间；“当前根评论页结束”不等于所有回复都已完整。
- 发现来源：`hot / latest / topic / following / saved / platform_personalized`。只有实际取得用户原生推荐时，才使用最后一种标签。
- 缓存与位置：获取时间、结构版本、账户命名空间、列表位置、正文位置和评论返回位置。账户切换后不串读私有缓存。

传输层只提供通用 HTTP 能力，鉴权由各适配器绑定允许的域名。知乎 Access Secret 不能发到酷安或 RSSHub，跨域重定向不能继承敏感头；凭证和可包含令牌的原始 URL 不出日志。抓到的 HTML 还需清洗脚本、事件和不支持的链接，不能直接作为可信 UI 内容执行。

### 首页与刷内容体验

九宫格可以作为常用入口，最多九个、允许排序与隐藏，平台更多时分页；同时提供大字体列表模式。网格与列表共用同一数据结构，布局由 PW4 实测决定。

选择平台后只展示它已经验证的频道，例如游戏新闻、分类热门、关注用户或指定吧。信息流采用小批量分页、主动刷新；阅读正文时前后切换，返回保留列表位置，评论/回复返回保留正文位置。先保存用户明确打开的内容，再提供有限数量的主动离线保存，不默认常驻轮询。

统一“推荐”先做透明规则：用户选择的主题/来源 + 时间与热度 + 已读去重 + 每平台数量限制。它不冒充平台首页算法。跨平台不直接比较点赞绝对数；先按各来源内排序，再轮流混排。离线页面明确显示可读缓存范围，未下载的下一页仍需要网络。

## 8. 推进顺序与验收

1. **先做探针，不先大重构。** 掘金验证指定文章正文、一个有评论的帖子和评论/回复两页；小黑盒验证公开新闻与公开分享各一条，区分是否全文、是否有图文块、是否确有评论入口。两者均先开发机、后 PW4；失败就记录原因，不先做空壳平台首页。
2. **选择可闭环的第二来源。** 若上述来源暂不满足要求，可用用户愿意使用的 V2EX，或 HN 的站内文本主题，验证异构模型。替代来源只用于证明架构，不能标成用户最喜欢的平台已经完成。
3. **抽取最小公共层。** 保持知乎配置、缓存和安装兼容；把知乎特有接口留在适配器内，加平台注册、通用内容状态及按来源隔离的缓存。
4. **统一首页与阅读流程。** 在 PW4 验证网格/列表、长正文、代码、图片占位、列表返回、评论展开、断网、取消和休眠恢复。不要把离屏截图当完整触屏验收。
5. **逐个平台扩展。** 酷安/贴吧优先于依赖较重的微博/小红书实验；实际顺序可随用户兴趣与探针结果调整，不预承诺六个平台同时支持全部功能。
6. **再加 KUAL 快捷启动与 EPUB 导出。** 两者复用同一缓存与获取管线，不复制平台实现。系统优化独立于内容适配；PW4 Android 只在有明确发布、机型与固件兼容和恢复证据后另开验证。

各平台通过门槛：列表能连续翻页；至少一篇长文与原网页核对完整性；至少一个真实非空评论样例和回复分页；错误有清楚状态；已读位置可恢复；断网能重读已保存内容；无账号数据泄漏。只有完成哪些门槛，就宣称支持哪些能力。

本次未修改运行代码、未安装 KUAL/系统包、未连接设备、未执行刷机或部署；仓库原有未提交改动保留。
