# 踩坑记录

更新：2026-11-03。这里只记录已遇到的问题与可复现处理，不记录凭证或个人内容。

## Feed 探针通过，但 Kindle 提示没有临时会话

`tools/zhihu_feed_probe.py` 只做接口诊断：Cookie 经 SSH stdin 传到 PW4 的 Lua 进程内存，验证 `/api/v4/me`、热榜、推荐和问题回答端点；进程结束后 Cookie 清除。它**不会**创建 `/tmp/zhihu-cookie-import`，所以 `profile_valid=true` 只代表账号校验成功，不代表 KOReader 已导入会话。

需要单独运行 `tools/zhihu_cookie_import.py`。脚本隐藏读取 Cookie，校验 `/api/v4/me` 后才写入 PW4 临时交接文件。随后在 KOReader 知乎插件“设置”中选择“导入电脑临时传入的浏览器会话”。临时文件 10 分钟后过期，插件读取时立即删除；会话最终只保存在 KOReader 进程内存。

## PowerShell 提示 Paramiko 缺失

项目的系统 Python 可能没有 Paramiko。工具会转到 `pw4-android` 虚拟环境重新运行，因此隐藏 Cookie 提示会在“retrying with pw4-android virtualenv”之后出现。应在该提示出现后粘贴完整的单行 Cookie。若错误发生在 SSH 连接之前，Cookie 尚未发送到 Kindle。

## 更新插件文件后界面没有变化

SFTP 部署替换磁盘上的插件目录，不会热重载已运行的 KOReader Lua 模块。重启 KOReader 后新版本才会加载。重启会清除插件内存中的网页登录会话，因此重启后需再次运行 Cookie 导入脚本并从插件设置导入。

## Access Secret 和网页登录 Cookie 不是一套凭证

网页登录 Cookie 用于热榜、推荐、问题回答、正文和评论读取；开放平台 Access Secret 只用于知乎直答。一个凭证有效或额度充足，不代表另一类请求可用。

## HTTP 200 不等于回答全文

列表接口的 HTTP 200 只能证明列表响应可读。回答详情还需核对回答 ID、正文非空，并检查付费/截断字段；摘要 `excerpt` 不应标作全文。当前接口没有可靠的通用全文完整性标记。

## 人机验证是停止状态

遇到 `verification_required` 时停止对应请求。不要通过自动解题、伪装浏览器或反复更换请求头继续尝试；保留摘要和已缓存内容供阅读。
