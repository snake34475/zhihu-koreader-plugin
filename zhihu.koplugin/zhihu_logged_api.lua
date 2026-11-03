local JSON = require("json")
local Renderer = require("zhihu_renderer")
local FeedSchema = require("zhihu_feed_schema")
local Schema = require("zhihu_schema")

local Client = {}
Client.__index = Client
Client.MAX_RESPONSE_BYTES = 1024 * 1024
Client.PAGE_SIZE = 20
Client.COOKIE_IMPORT_PATH = "/tmp/zhihu-cookie-import"
Client.COOKIE_IMPORT_TTL = 600
local BASE = "https://www.zhihu.com"
local COOKIE_NAMES = { _xsrf = true, _zap = true, d_c0 = true, BEC = true, sec_token = true, z_c0 = true }

local function err(kind, status, message)
    return { kind = kind, status = status, message = message }
end

local function session_from_cookie_header(header)
    if type(header) ~= "string" or #header == 0 or #header > 16384 or header:find("[%c]") then
        return nil, err("invalid_response", nil, "临时 Cookie 格式无效。")
    end
    header = header:match("^%s*(.-)%s*$")
    if header:sub(1, 7):lower() == "cookie:" then header = header:sub(8):match("^%s*(.-)%s*$") end
    local jar = {}
    for pair in header:gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if name and COOKIE_NAMES[name] and value ~= "" and #value <= 4096 then jar[name] = value end
    end
    if not jar.z_c0 then return nil, err("login_required", nil, "临时 Cookie 中没有知乎登录凭据。") end
    return { jar = jar }
end

function Client.cookie_session_from_header(header)
    return session_from_cookie_header(header)
end

function Client:consume_cookie_import(path, now)
    path = path or Client.COOKIE_IMPORT_PATH
    local file = io.open(path, "rb")
    if not file then return nil, err("login_required", nil, "没有待导入的临时浏览器会话。") end
    local created_at = tonumber(file:read("*l"))
    local header = (file:read(16386) or ""):gsub("\r\n$", ""):gsub("[\r\n]$", "")
    file:close()
    os.remove(path)
    if not created_at or #header > 16384 or header == "" then
        return nil, err("invalid_response", nil, "临时会话文件无效，已删除。")
    end
    now = tonumber(now) or os.time()
    local age = now - created_at
    if age < 0 or age > Client.COOKIE_IMPORT_TTL then
        return nil, err("login_required", nil, "临时会话已过期，请重新运行导入探针。")
    end
    return session_from_cookie_header(header)
end

local function comment_path(answer_id, cursor)
    local base = "/api/v4/comment_v5/answers/" .. answer_id .. "/root_comment"
    if cursor == nil or cursor == "0" then return base .. "?order_by=score&limit=" .. Client.PAGE_SIZE .. "&offset=" end
    if type(cursor) ~= "string" or #cursor > 2048 then return nil end
    if cursor:find("[%c%s#]") then return nil end
    local prefix = BASE .. base .. "?"
    if cursor:sub(1, #prefix) == prefix then return cursor:sub(#BASE + 1) end
    -- Some server responses expose only the opaque query string. Accept it only
    -- when it cannot change the endpoint or answer ID.
    if cursor:sub(1, 1) == "?" and not cursor:find("#", 1, true) then return base .. cursor end
    return nil
end

local function child_comment_path(comment_id, cursor)
    local base = "/api/v4/comment_v5/comment/" .. comment_id .. "/child_comment"
    if cursor == nil or cursor == "0" then return base .. "?order_by=score&limit=" .. Client.PAGE_SIZE .. "&offset=" end
    if type(cursor) ~= "string" or #cursor > 2048 or cursor:find("[%c%s#]") then return nil end
    local prefix = BASE .. base .. "?"
    if cursor:sub(1, #prefix) == prefix then return cursor:sub(#BASE + 1) end
    if cursor:sub(1, #base + 1) == base .. "?" then return cursor end
    if cursor:sub(1, 1) == "?" then return base .. cursor end
    return nil
end

local function comment_author(value)
    return Renderer.text(type(value) == "table" and (value.name or value.name_cn) or "")
end

local function comment_item(item, depth)
    if type(item) ~= "table" then return nil end
    local text = Renderer.text(item.content or "")
    if text == "" then return nil end
    local count = tonumber(item.child_comment_count) or 0
    local children = {}
    if (depth or 0) < 1 then
        for _, child in ipairs(type(item.child_comments) == "table" and item.child_comments or {}) do
            local parsed = comment_item(child, (depth or 0) + 1)
            if parsed then children[#children + 1] = parsed end
        end
    end
    return { id = tostring(item.id or ""), author = comment_author(item.author), content = text,
        reply_to_author = comment_author(item.reply_to_author), child_comment_count = math.max(0, count),
        child_comments = children }
end

local function feed_path(base, cursor)
    if cursor == nil or cursor == "" then return base end
    if type(cursor) ~= "string" or #cursor > 4096 or cursor:find("[%c%s#]") then return nil end
    local prefix = BASE .. base .. "?"
    if cursor:sub(1, #prefix) == prefix then return cursor:sub(#BASE + 1) end
    if cursor:sub(1, #base + 1) == base .. "?" then return cursor end
    if cursor:sub(1, 1) == "?" then return base .. cursor end
    return nil
end

local function feed_failure(kind, status)
    local message = kind == "verification_required" and "知乎要求人机验证，列表读取已停止。"
        or kind == "login_required" and "尚未登录或知乎会话已失效，请重新导入 Cookie。"
        or kind == "forbidden" and "知乎拒绝访问列表。"
        or kind == "rate_limited" and "知乎请求过于频繁，请稍后再试。"
        or "知乎列表读取失败，已保留最近缓存。"
    return err(kind, status, message)
end

local function decode(raw)
    local ok, value = pcall(JSON.decode, raw or "")
    return ok and type(value) == "table" and value or nil
end

local function valid_qr_link(link, token)
    if type(link) ~= "string" then return false end
    return link == BASE .. "/account/qrcode/scan?token=" .. token
        or link == BASE .. "/account/scan/login/" .. token
end

local function cookies(jar)
    local parts = {}
    for key, value in pairs(jar or {}) do
        if COOKIE_NAMES[key] and type(value) == "string" and value ~= "" then parts[#parts + 1] = key .. "=" .. value end
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

local function merge_cookies(jar, headers)
    local values = headers and (headers["set-cookie"] or headers["Set-Cookie"])
    if type(values) == "string" then values = { values } end
    for _, header in ipairs(type(values) == "table" and values or {}) do
        for name, value in header:gmatch("([%w_]+)=([^;,%s]+)") do
            if COOKIE_NAMES[name] and #value <= 4096 then jar[name] = value end
        end
    end
end

function Client.transport(request, timeout)
    local http, ltn12, socketutil = require("socket.http"), require("ltn12"), require("socketutil")
    local data, size, sink_error = {}, 0, nil
    local headers = request.headers or {}
    request.redirect = false
    request.headers = headers
    request.sink = function(chunk)
        if chunk then
            size = size + #chunk
            if size > Client.MAX_RESPONSE_BYTES then sink_error = "size" return nil, "size" end
            data[#data + 1] = chunk
        end
        return 1
    end
    if request.body then
        request.source = ltn12.source.string(request.body)
        headers["Content-Length"] = tostring(#request.body)
        request.body = nil
    end
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    socketutil:set_timeout(timeout or 20, timeout or 20)
    local ok, success, status, response_headers = pcall(http.request, request)
    socketutil:set_timeout(old_block, old_total)
    if sink_error then return nil, nil, sink_error end
    if not ok or not success then
        local timeout_error = status == "timeout" or status == "wantread" or status == "wantwrite"
        return nil, nil, timeout_error and "timeout" or "network"
    end
    return tonumber(status), table.concat(data), nil, response_headers
end

function Client.new(options)
    options = options or {}
    return setmetatable({ send = options.transport or Client.transport, clock = options.clock or os.time,
        timeout = options.timeout or 20, timeout_provider = options.timeout_provider }, Client)
end

function Client:request_timeout()
    local value = self.timeout_provider and self.timeout_provider() or self.timeout
    value = tonumber(value) or self.timeout
    return math.max(5, math.min(120, value))
end

function Client:request(method, path, session, body)
    if type(path) ~= "string" or not path:match("^/") or path:match("^//") then return nil, nil, "invalid_response" end
    local jar = session and session.jar or {}
    local headers = {
        ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = BASE .. "/signin",
    }
    local cookie = cookies(jar)
    if cookie ~= "" then headers.Cookie = cookie end
    if jar._xsrf then headers["x-xsrftoken"] = jar._xsrf end
    if body then headers["Content-Type"] = "application/json;charset=UTF-8" end
    local ok, status, raw, transport_error, response_headers = pcall(self.send, {
        url = BASE .. path, method = method, headers = headers, body = body, redirect = false,
    }, self:request_timeout())
    if not ok or not status then
        local kind = transport_error == "size" and "invalid_response"
            or transport_error == "timeout" and "network_error" or "network_error"
        return nil, nil, kind
    end
    merge_cookies(jar, response_headers)
    local location = response_headers and (response_headers.location or response_headers.Location) or ""
    if type(location) == "string" and location:find("/account/unhuman", 1, true) then
        return nil, status, "verification_required"
    end
    if type(raw) == "string" and (raw:find("/account/unhuman", 1, true) or raw:find("人机验证", 1, true)) then
        return nil, status, "verification_required"
    end
    if status == 401 then return nil, status, "login_required" end
    if status == 403 then
        local payload = decode(raw)
        local code = payload and type(payload.error) == "table" and tonumber(payload.error.code)
        return nil, status, (code == 40352 or code == 40362) and "verification_required" or "forbidden"
    end
    if status == 429 then return nil, status, "rate_limited" end
    if status >= 300 and status < 400 then return nil, status, "login_required" end
    -- Zhihu IDs can exceed LuaJIT's exact integer range. Preserve numeric JSON
    -- values under the `id` key as strings before decoding feed responses.
    local decode_raw = raw
    if method == "GET" and (path:find("/api/v3/feed/topstory/", 1, true)
        or path:find("/api/v4/questions/", 1, true)) then
        decode_raw = raw:gsub('("id"%s*:%s*)(%d+)', '%1"%2"')
    end
    local payload = decode(decode_raw)
    if status ~= 200 or not payload then return nil, status, "invalid_response" end
    return payload, status
end

function Client:login_request(method, path, jar, body)
    local headers = { ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
        ["Accept"] = "application/json, text/plain, */*", ["Referer"] = BASE .. "/signin",
        ["Origin"] = BASE, ["X-Requested-With"] = "fetch" }
    local cookie = cookies(jar)
    if cookie ~= "" then headers.Cookie = cookie end
    if jar and jar._xsrf then headers["x-xsrftoken"] = jar._xsrf end
    if body then headers["Content-Type"] = "application/json;charset=UTF-8" end
    local ok, status, raw, transport_error, response_headers = pcall(self.send,
        { url = BASE .. path, method = method, headers = headers, body = body, redirect = false }, self:request_timeout())
    if not ok or not status then return nil, nil, transport_error == "size" and "invalid_response" or "network_error" end
    merge_cookies(jar, response_headers)
    local location = response_headers and (response_headers.location or response_headers.Location) or ""
    if type(location) == "string" and location:find("/account/unhuman", 1, true) then
        return nil, status, "verification_required"
    end
    if status >= 300 and status < 400 then return nil, status, "login_required" end
    if type(raw) == "string" and (raw:find("/account/unhuman", 1, true) or raw:find("人机验证", 1, true)) then
        return nil, status, "verification_required"
    end
    if status == 403 then
        local payload = decode(raw)
        local code = payload and type(payload.error) == "table" and tonumber(payload.error.code)
        return nil, status, (code == 40352 or code == 40362) and "verification_required" or "forbidden"
    end
    if status == 401 then return nil, status, "login_required" end
    if status == 429 then return nil, status, "rate_limited" end
    return raw, status
end

function Client:create_qr()
    local jar = {}
    local raw, status, kind = self:login_request("GET", "/signin", jar)
    if not raw then return nil, err(kind, status, "无法打开知乎登录页，扫码登录已停止。") end
    if status ~= 200 then return nil, err("invalid_response", status, "知乎登录页返回异常状态。") end
    if raw:find("/account/unhuman", 1, true) or raw:find("人机验证", 1, true) then
        return nil, err("verification_required", status, "知乎要求人机验证，扫码登录已停止。")
    end
    raw, status, kind = self:login_request("POST", "/udid", jar, "{}")
    if not raw then return nil, err(kind, status, "设备初始化失败。") end
    local device = decode(raw)
    if status ~= 200 or (not jar.d_c0 and not (device and type(device.udid) == "string" and device.udid ~= "")) then
        return nil, err("invalid_response", status, "设备初始化未完成。")
    end
    raw, status, kind = self:login_request("POST", "/api/v3/account/api/login/qrcode", jar, "{}")
    if not raw then return nil, err(kind, status, "无法生成知乎登录二维码。") end
    local data = decode(raw)
    local token = data and (data.token or data.qrcode_token or data.qrcodeToken)
    if status ~= 200 or type(token) ~= "string" or not token:match("^[%w_%-]+$")
        or not valid_qr_link(data.link, token) then
        return nil, err("invalid_response", status, "知乎二维码响应格式异常。")
    end
    local now = self.clock() * 1000
    local ttl = tonumber(data.expires_at)
    local expiry
    if not ttl or ttl <= 0 then expiry = now + 120000
    elseif ttl > now then expiry = ttl
    elseif ttl < 86400 then expiry = now + ttl * 1000
    elseif ttl < 86400000 then expiry = now + ttl
    else expiry = now + 120000 end
    return { link = data.link, token = token, expires_at = expiry, jar = jar }
end

function Client:poll_login(session)
    if type(session) ~= "table" or type(session.jar) ~= "table"
        or type(session.token) ~= "string" or not session.token:match("^[%w_%-]+$") then
        return nil, err("invalid_response", nil, "二维码会话无效。")
    end
    local raw, status, kind = self:login_request("GET", "/api/v3/account/api/login/qrcode/"
        .. session.token .. "/scan_info", session.jar)
    if not raw then return nil, err(kind, status, kind == "verification_required" and "知乎要求人机验证，扫码实验已停止。"
        or "扫码状态请求失败。") end
    if status ~= 200 then return nil, err(status == 401 and "login_required"
        or status == 429 and "rate_limited" or "forbidden", status, "扫码状态请求被拒绝。") end
    local data = decode(raw)
    if not data then return nil, err("invalid_response", status, "扫码状态响应格式异常。") end
    local cookie_list = { data.cookie, data.cookies }
    for _, line in ipairs(cookie_list) do
        if type(line) == "string" then merge_cookies(session.jar, { ["set-cookie"] = line }) end
    end
    if type(data.z_c0) == "string" and #data.z_c0 <= 4096 then session.jar.z_c0 = data.z_c0 end
    local login_status = type(data.login_status) == "string" and data.login_status:upper() or ""
    if data.status == 2 or login_status == "EXPIRED" or login_status == "QR_CODE_EXPIRED" then
        return nil, err("qr_expired", status, "二维码已过期，请重新登录。")
    end
    local confirmed = login_status == "CONFIRMED" or login_status == "LOGIN_SUCCESS"
        or data.success == true or data.logged_in == true or data.loggedIn == true
        or data.user_id ~= nil or data.userId ~= nil or data.access_token ~= nil or data.accessToken ~= nil
    return { confirmed = confirmed, scanned = data.status == 1, jar = session.jar }
end

function Client:verify_session(session)
    if type(session) ~= "table" or type(session.jar) ~= "table" or not session.jar.z_c0 then
        return nil, err("login_required", nil, "扫码已确认，但知乎尚未返回登录凭据。")
    end
    local profile, status, kind = self:request("GET", "/api/v4/me", session)
    if not profile then return nil, err(kind, status, "扫码已确认，但登录态校验失败。") end
    if not (profile.id or profile.url_token or profile.name or profile.name_cn) then
        return nil, err("invalid_response", status, "知乎个人资料响应无效。")
    end
    session.user = { name = tostring(profile.name or profile.name_cn or "知乎用户") }
    return session
end

function Client:fetch_feed(kind, cursor, session, hot_limit)
    if type(session) ~= "table" or type(session.jar) ~= "table" or not session.jar.z_c0 then
        return nil, feed_failure("login_required")
    end
    local route, initial, limit
    if kind == "hot" then
        limit = math.max(1, math.min(30, tonumber(hot_limit) or 30))
        route = "/api/v3/feed/topstory/hot-lists/total"
        initial = route .. "?limit=" .. tostring(limit) .. "&desktop=true"
    elseif kind == "recommend" then
        limit = 10
        route = "/api/v3/feed/topstory/recommend"
        initial = route .. "?limit=10&desktop=true"
    else
        return nil, err("invalid_response", nil, "列表类型无效。")
    end
    local path = cursor and feed_path(route, cursor) or initial
    if not path then return nil, err("invalid_response", nil, "列表分页游标无效，已停止翻页。") end
    local payload, status, failure = self:request("GET", path, session)
    if not payload then return nil, feed_failure(failure, status) end
    local result = FeedSchema.list(payload, limit)
    if not result or (result.next_cursor and (result.next_cursor == cursor
        or not feed_path(route, result.next_cursor))) then
        return nil, err("invalid_response", status, "列表响应或分页游标格式异常，已停止翻页。")
    end
    result.kind = kind
    return result
end

function Client:fetch_question_answers(question_url, cursor, session)
    if type(session) ~= "table" or type(session.jar) ~= "table" or not session.jar.z_c0 then
        return nil, feed_failure("login_required")
    end
    local clean_url = Schema.question_url(question_url)
    local question_id = clean_url and clean_url:match("/question/(%d+)$")
    if not question_id then return nil, err("invalid_response", nil, "问题链接无效。") end
    local base = "/api/v4/questions/" .. question_id .. "/feeds?limit=10&order=default&offset=0"
    local path = feed_path("/api/v4/questions/" .. question_id .. "/feeds", cursor)
    if cursor == nil or cursor == "" then path = base end
    if not path then return nil, err("invalid_response", nil, "回答分页游标无效，已停止翻页。") end
    local payload, status, failure = self:request("GET", path, session)
    if not payload then return nil, feed_failure(failure, status) end
    local result = FeedSchema.list(payload, 10)
    if not result then return nil, err("invalid_response", status, "问题回答列表格式异常。") end
    for _, item in ipairs(result.items) do
        if item.kind ~= "answer" or not item.url:find("/question/" .. question_id .. "/answer/", 1, true) then
            return nil, err("invalid_response", status, "问题回答列表包含无法核对的问题或回答。")
        end
    end
    local expected = "/api/v4/questions/" .. question_id .. "/feeds"
    if result.next_cursor and (result.next_cursor == cursor or not feed_path(expected, result.next_cursor)) then
        return nil, err("invalid_response", status, "回答分页游标不属于当前问题，已停止翻页。")
    end
    result.kind = "question"
    result.question_id = question_id
    return result
end

function Client:fetch_answer(answer_id, session, summary)
    answer_id = tostring(answer_id or "")
    if not answer_id:match("^%d+$") then return nil, err("invalid_response", nil, "回答 ID 无效。") end
    local payload, status, kind = self:request("GET", "/api/v4/answers/" .. answer_id
        .. "?include=content,excerpt,paid_info,content_need_truncated,force_login_when_click_read_more", session)
    if not payload then return nil, err(kind, status, kind == "verification_required" and "知乎要求人机验证，仍可阅读摘要。"
        or kind == "login_required" and "知乎登录态已失效，请重新登录。"
        or kind == "forbidden" and "知乎拒绝访问此回答。"
        or kind == "rate_limited" and "知乎请求过于频繁，请稍后再试。"
        or "回答获取失败，仍可阅读摘要。") end
    if tostring(payload.id or "") ~= answer_id or type(payload.content) ~= "string" or payload.content == "" then
        return nil, err("invalid_response", status, "未能核对回答正文，仍可阅读摘要。")
    end
    local paid = payload.paid_info
    if payload.is_paid == true or payload.is_payed == true or payload.is_purchased == false
        or (type(paid) == "table" and (paid.is_paid == true or paid.is_payed == true
        or paid.is_purchased == false or paid.has_purchased == false or paid.need_pay == true
        or (tonumber(paid.price) or 0) > 0)) then
        return nil, err("paid_or_truncated", status, "该回答包含付费内容，仍可阅读摘要。")
    end
    local raw = payload.content
    if payload.content_need_truncated == true or payload.force_login_when_click_read_more == true
        or raw:find("阅读全文", 1, true) or raw:find("查看完整回答", 1, true) or raw:find("购买后查看", 1, true) then
        return nil, err("paid_or_truncated", status, "知乎返回的正文可能不完整，仍可阅读摘要。")
    end
    local content = Renderer.text(raw)
    if content == "" then return nil, err("invalid_response", status, "正文为空，仍可阅读摘要。") end
    local preview = Renderer.text(summary or "")
    if (preview:find("…", 1, true) or preview:find("...", 1, true)) and #content <= #preview then
        return nil, err("paid_or_truncated", status, "无法确认正文超过摘要范围，仍可阅读摘要。")
    end
    return { answer_id = answer_id, content = content, fetched_at = self.clock() }
end

function Client:fetch_comments(answer_id, cursor, session)
    answer_id = tostring(answer_id or "")
    if not answer_id:match("^%d+$") then return nil, err("invalid_response", nil, "回答 ID 无效。") end
    cursor = cursor == nil and "0" or tostring(cursor)
    local path = comment_path(answer_id, cursor)
    if not path then return nil, err("invalid_response", nil, "评论分页游标不属于当前回答，已停止翻页。") end
    local payload, status, kind = self:request("GET", path, session)
    if not payload then return nil, err(kind, status, kind == "verification_required" and "知乎要求人机验证。"
        or kind == "login_required" and "知乎登录态已失效，请重新登录。"
        or kind == "forbidden" and "知乎拒绝访问评论。"
        or kind == "rate_limited" and "知乎请求过于频繁，请稍后再试。" or "评论获取失败。") end
    local data = payload.data
    local paging = payload.paging
    if type(data) ~= "table" or type(paging) ~= "table" or type(paging.is_end) ~= "boolean" then
        return nil, err("invalid_response", status, "评论分页响应格式异常。")
    end
    local comments = {}
    for _, item in ipairs(data) do
        local parsed = comment_item(item)
        if parsed then comments[#comments + 1] = parsed end
    end
    local next_cursor = type(paging.next) == "string" and paging.next or ""
    if not paging.is_end and (next_cursor == "" or next_cursor == cursor
        or not comment_path(answer_id, next_cursor)) then
        return nil, err("invalid_response", status, "评论分页游标无效，已停止翻页。")
    end
    return { items = comments, next_cursor = not paging.is_end and next_cursor or nil,
        is_end = paging.is_end, fetched_at = self.clock(), range = "本页 " .. #comments .. " 条" }
end

function Client:fetch_child_comments(comment_id, cursor, session)
    comment_id = tostring(comment_id or "")
    if not comment_id:match("^%d+$") then return nil, err("invalid_response", nil, "评论 ID 无效。") end
    cursor = cursor == nil and "0" or tostring(cursor)
    local path = child_comment_path(comment_id, cursor)
    if not path then return nil, err("invalid_response", nil, "子评论分页游标无效，已停止翻页。") end
    local payload, status, kind = self:request("GET", path, session)
    if not payload then return nil, err(kind, status, kind == "verification_required" and "知乎要求人机验证。"
        or kind == "login_required" and "知乎登录态已失效，请重新登录。"
        or kind == "forbidden" and "知乎拒绝访问子评论。"
        or kind == "rate_limited" and "知乎请求过于频繁，请稍后再试。" or "子评论获取失败。") end
    local data, paging = payload.data, payload.paging
    if type(data) ~= "table" or type(paging) ~= "table" or type(paging.is_end) ~= "boolean" then
        return nil, err("invalid_response", status, "子评论分页响应格式异常。")
    end
    local comments = {}
    for _, item in ipairs(data) do
        local parsed = comment_item(item)
        if parsed then comments[#comments + 1] = parsed end
    end
    local next_cursor = type(paging.next) == "string" and paging.next or ""
    if not paging.is_end and (next_cursor == "" or next_cursor == cursor or not child_comment_path(comment_id, next_cursor)) then
        return nil, err("invalid_response", status, "子评论分页游标无效，已停止翻页。")
    end
    return { items = comments, next_cursor = not paging.is_end and next_cursor or nil,
        is_end = paging.is_end, fetched_at = self.clock(), range = "本页 " .. #comments .. " 条" }
end

Client.error = err
Client._decode = decode
return Client
