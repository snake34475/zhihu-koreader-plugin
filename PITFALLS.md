# 踩坑记录

更新：2026-11-03。这里只记录已遇到的问题与可复现处理，不记录凭证或个人内容。

## Feed 探针通过，但 Kindle 提示没有临时会话

`tools/zhihu_feed_probe.py` 只做接口诊断：Cookie 经 SSH stdin 传到 PW4 的 Lua 进程内存，验证 `/api/v4/me`、热榜、推荐和问题回答端点；进程结束后 Cookie 清除。它**不会**创建 `/tmp/zhihu-cookie-import`，所以 `profile_valid=true` 只代表账号校验成功，不代表 KOReader 已导入会话。

需要单独运行 `tools/zhihu_cookie_import.py`。脚本隐藏读取 Cookie，校验 `/api/v4/me` 后才写入 PW4 临时交接文件。随后在 KOReader 知乎插件“设置”中选择“导入电脑临时传入的浏览器会话”。临时文件 10 分钟后过期，插件读取时立即删除；默认会话只在 KOReader 进程内存。若在插件设置中开启“保持登录”，Cookie 会保存到设置目录的 `zhihu_session.json`，文件权限 0600，并在下次联网时重新校验。Cookie 是明文 bearer 凭证；设置目录备份也可能包含该账号会话。

## Cookie 导入脚本要求

`tools/zhihu_cookie_import.py` 使用系统自带 OpenSSH 和 Python 标准库，不再依赖 `pw4-android` 项目或 Paramiko。默认连接 `root@192.168.31.104:2222`，可通过 `ZHIHU_DEVICE_HOST` / `ZHIHU_DEVICE_PORT` 覆盖。运行 `python3 tools/zhihu_cookie_import.py` 后，完整 Cookie 只在隐藏提示中输入；发送前会筛选白名单并检查 `z_c0`。远端 `/api/v4/me` 校验通过后，脚本才在设备 `/tmp` 创建 600 秒交接文件。

## 更新插件文件后界面没有变化

SFTP 部署替换磁盘上的插件目录，不会热重载已运行的 KOReader Lua 模块。重启 KOReader 后新版本才会加载。未开启“保持登录”时，重启会清除内存中的网页登录会话，需再次运行 Cookie 导入脚本并从插件设置导入。已开启时，普通插件更新只替换插件目录，`settings/zhihu_session.json` 会保留；重启后首次联网时会重新校验它。若账号会话已被知乎撤销或过期，需在浏览器重新登录并导入新 Cookie。

## Access Secret 和网页登录 Cookie 不是一套凭证

网页登录 Cookie 用于热榜、推荐、问题回答、正文和评论读取；开放平台 Access Secret 只用于知乎直答。一个凭证有效或额度充足，不代表另一类请求可用。

## HTTP 200 不等于回答全文

列表接口的 HTTP 200 只能证明列表响应可读。回答详情还需核对回答 ID、正文非空，并检查付费/截断字段；摘要 `excerpt` 不应标作全文。当前接口没有可靠的通用全文完整性标记。

## 人机验证是停止状态

遇到 `verification_required` 时停止对应请求。不要通过自动解题、伪装浏览器或反复更换请求头继续尝试；保留摘要和已缓存内容供阅读。
