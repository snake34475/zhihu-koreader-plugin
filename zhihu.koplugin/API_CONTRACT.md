# 已用接口与迁移目标

开放平台接口核验日期：2026-11-02。读取了知乎官方[文档页面](https://developer.zhihu.com/docs)及页面使用的[公开文档数据](https://developer.zhihu.com/console/api/v3/docs)，未提供凭证、未调用付费内容接口。搜索已从产品与代码中移除；直答仍保留开放平台接口。热榜和问题回答列表的当前 UI 请求已切换到网页登录接口，旧开放平台缓存保留作离线兼容。

| 能力 | 请求 | 本插件采用的响应字段 |
| --- | --- | --- |
| 热榜（旧接口，仅旧缓存兼容） | `GET /api/v1/content/hot_list`，`Limit` 上限 30 | `Data.Items[]` 内的 `Title/Url/Summary` |
| 直答 | `POST /v1/chat/completions`，`model/messages/stream` | `choices[1].message.content`，`model`，`finish_reason` |
| 问题回答摘要（旧接口，仅旧缓存兼容） | `GET /api/v1/content/question_answers`，`QuestionUrl/Offset/Limit` | `Data.Items[].Summary/Url/ContentType`，`Data.Paging.IsEnd/NextOffset` |

问题回答接口支持分页，摘要不代表全文。本插件每批最多取 10 条；下一批严格采用服务端游标，空批次仍可继续，缺失或不递增的游标视为格式异常。`/api/v1/user/content_detail` 与 `/api/v1/user/content_comments` 仅支持本人已发布的创作，不能用于任意他人的全文与完整评论。

知乎直答默认使用 `https://developer.zhihu.com`，每次请求使用 Bearer 认证和新的 Unix 秒时间戳头 `X-Request-Timestamp`。网页列表和已登录正文/评论请求使用固定的 `https://www.zhihu.com`，携带经白名单筛选的网页登录 Cookie，不发送开放平台 Access Secret。

## 网页端列表接口（PW4 探针通过）

- 网页热榜：`GET https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=30&desktop=true`，PW4 返回 200/30 条，`paging.is_end=true`。
- 个性化推荐：`GET https://www.zhihu.com/api/v3/feed/topstory/recommend?limit=10&desktop=true`，PW4 返回 200/6 条，`paging.next` 存在且 `is_end=false`。
- 问题回答：`GET https://www.zhihu.com/api/v4/questions/{question_id}/feeds?limit=10&order=default&offset=0`，PW4 返回 200/10 条，均为回答，`paging.next` 存在且 `is_end=false`。
- 2026-11-03 探针使用隐藏输入的用户 Cookie 在 PW4 上只读请求，只输出状态、条数和字段形状，没有输出内容、标题、凭证或游标。正式插件仍使用固定域名、Cookie 白名单和禁止跳转策略。

路径和字段参考第三方开源协议笔记，并经用户本人的 PW4 会话探针验证；接口仍非官方且可能变化：[信息流接口说明](https://github.com/zly2006/zhurl/blob/main/docs/apis/feeds-search-history.md)、[内容接口说明](https://github.com/zly2006/zhurl/blob/main/docs/apis/content.md)。

直答默认 `zhida-fast-1p5`，可选 `zhida-thinking-1p5`、`zhida-agent`；固定 `stream=false`。不展示推理字段，不添加官方尚未保证的生成参数。

通用业务响应使用 `Code/Message/Data`。实现对 `20001` 提示鉴权失败，对 `30001` 提示频率、并发或当日额度超限，对 `30002` 提示额度不足；同时处理 HTTP 401/403/402/429、直答的结构化错误和未知错误。错误正文不直接进入日志或界面。

Fixtures 是按核验字段自行编写的虚构数据，不含真实用户数据、密钥或账号响应。

## 匿名回答正文探测（实验功能）

此请求不属于上表的开放平台接口。用户点击单条回答的“尝试获取正文”时，插件对固定域名 `www.zhihu.com` 发起一次 `GET /api/v4/answers/{回答 ID}?include=content,excerpt,paid_info`。只接受回答 ID 匹配、正文非空、且未检测到付费或截断提示的 HTTP 200 JSON；不发送 Access Secret、Cookie，不跟随跳转，不重试，不缓存正文。接口没有可靠的全文标记，界面只称“回答正文”。

2026-11-02 在 PW4 上以一条公开回答测试：该详情接口 HTTP 403，响应被识别为人机验证，未取得正文。原始回答页面和 `api.zhihu.com/answers/{id}` 同样返回 HTTP 403。此记录仅说明当时的设备与网络结果，不代表所有回答始终不可访问。

KOReader 对接参考的是官方仓库的 [socketutil](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua)、[Trapper](https://github.com/koreader/koreader/blob/master/frontend/ui/trapper.lua)、[Menu](https://github.com/koreader/koreader/blob/master/frontend/ui/widget/menu.lua)、[InputDialog](https://github.com/koreader/koreader/blob/master/frontend/ui/widget/inputdialog.lua) 和 [DataStorage](https://github.com/koreader/koreader/blob/master/datastorage.lua)。这些在线源码用于核对调用方式，尚未在目标设备的 2026.07.x 版本验证。


## 临时浏览器会话导入（实验）

用户可在本机运行 `tools/zhihu_cookie_import.py`，只需隐藏输入 Cookie，即验证 `GET /api/v4/me` 并临时交接；详细内容诊断仍可运行 `tools/zhihu_cookie_probe.py`，该脚本另需回答链接。两者都仅白名单保留 `_xsrf`、`_zap`、`d_c0`、`BEC`、`sec_token`、`z_c0`，通过 SSH stdin 发给 PW4；先验证热榜、`GET /api/v4/me`、单条回答详情和评论两页。任何挑战或探针失败时，不创建会话交接文件。

所有探针阶段通过后，脚本把带 Unix 时间戳的白名单 Cookie 原子写入设备 `/tmp/zhihu-cookie-import`，有效期 600 秒，文件权限为 0600。PW4 的 `/tmp` 是临时 RAM 文件系统；KOReader 设置页的“导入电脑临时传入的浏览器会话”会读取并立即删除交接文件，再请求 `/api/v4/me`。仅校验通过后，Cookie 存入当前插件对象内存；退出登录或离开插件主页后清除。Cookie 不写入配置、内容缓存或 Git。此机制尚需在 PW4 上完成插件部署和交互验收。

回答字段检查不能证明知乎已返回任意回答的全部文字或媒体；正文与评论读取必须由用户逐条主动触发。出现 `verification_required` 即停止，不自动解题、不伪装设备或重试。
