# 官方接口核验记录

核验日期：2026-11-02。读取了知乎官方[文档页面](https://developer.zhihu.com/docs)及页面使用的[公开文档数据](https://developer.zhihu.com/console/api/v3/docs)，未提供凭证、未调用付费内容接口。以下仅记录本插件采用的字段，不是完整文档副本。

| 能力 | 请求 | 本插件采用的响应字段 |
| --- | --- | --- |
| 热榜 | `GET /api/v1/content/hot_list`，`Limit` 上限 30 | `Data.Items[]` 内的 `Title/Url/Summary` |
| 站内搜索 | `GET /api/v1/content/zhihu_search`，`Query` 必填，`Count` 上限 10 | `Data.Items[]` 内的 `Title/ContentType/ContentText/Url/AuthorName/EditTime/CreateTime` |
| 直答 | `POST /v1/chat/completions`，`model/messages/stream` | `choices[1].message.content`，`model`，`finish_reason` |
| 问题回答摘要 | `GET /api/v1/content/question_answers`，`QuestionUrl/Offset/Limit` | `Data.Items[].Summary/Url/ContentType`，`Data.Paging.IsEnd/NextOffset` |

问题回答接口支持分页，摘要不代表全文。本插件每批最多取 10 条；下一批严格采用服务端游标，空批次仍可继续，缺失或不递增的游标视为格式异常。`/api/v1/user/content_detail` 与 `/api/v1/user/content_comments` 仅支持本人已发布的创作，不能用于任意他人的全文与完整评论。

默认域名 `https://developer.zhihu.com`。每次请求使用 Bearer 认证和新的 Unix 秒时间戳头 `X-Request-Timestamp`；不发送 Cookie。

直答默认 `zhida-fast-1p5`，可选 `zhida-thinking-1p5`、`zhida-agent`；固定 `stream=false`。不展示推理字段，不添加官方尚未保证的生成参数。

通用业务响应使用 `Code/Message/Data`。实现对 `20001` 提示鉴权失败，对 `30001` 提示频率、并发或当日额度超限，对 `30002` 提示额度不足；同时处理 HTTP 401/403/402/429、直答的结构化错误和未知错误。错误正文不直接进入日志或界面。

Fixtures 是按核验字段自行编写的虚构数据，不含真实用户数据、密钥或账号响应。

KOReader 对接参考的是官方仓库的 [socketutil](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua)、[Trapper](https://github.com/koreader/koreader/blob/master/frontend/ui/trapper.lua)、[Menu](https://github.com/koreader/koreader/blob/master/frontend/ui/widget/menu.lua)、[InputDialog](https://github.com/koreader/koreader/blob/master/frontend/ui/widget/inputdialog.lua) 和 [DataStorage](https://github.com/koreader/koreader/blob/master/datastorage.lua)。这些在线源码用于核对调用方式，尚未在目标设备的 2026.07.x 版本验证。
