local JSON = require("json")
local Protocol = {}
local BASE = "https://www.zhihu.com"
local MAX_BYTES = 256 * 1024
local COOKIE_NAMES = { _xsrf = true, _zap = true, d_c0 = true, BEC = true, sec_token = true, z_c0 = true }

local function failure(kind, status, message, stage, diagnostic)
    return { kind = kind, status = status, message = message, stage = stage, diagnostic = diagnostic }
end

local function cookie_header(jar)
    local entries = {}
    for name, value in pairs(jar or {}) do
        if COOKIE_NAMES[name] and type(value) == "string" and value ~= "" then
            entries[#entries + 1] = name .. "=" .. value
        end
    end
    table.sort(entries)
    return table.concat(entries, "; ")
end

local function merge_cookies(jar, headers)
    local value = headers and (headers["set-cookie"] or headers["Set-Cookie"])
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return end
    for _, line in ipairs(value) do
        if type(line) == "string" then
            for name, item in line:gmatch("([%w_]+)=([^;,%s]+)") do
                if COOKIE_NAMES[name] and #item <= 4096 then jar[name] = item end
            end
        end
    end
end

function Protocol.request(method, path, jar, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local chunks, size, too_large = {}, 0, false
    local headers = {
        ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = BASE .. "/signin",
        ["Origin"] = BASE,
        ["X-Requested-With"] = "fetch",
    }
    local cookies = cookie_header(jar)
    if cookies ~= "" then headers["Cookie"] = cookies end
    if jar and jar._xsrf then headers["X-Xsrftoken"] = jar._xsrf end
    if body then
        headers["Content-Type"] = "application/json;charset=UTF-8"
        headers["Content-Length"] = tostring(#body)
    end
    local request = {
        url = BASE .. path, method = method, redirect = false, headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = function(chunk)
            if chunk then
                size = size + #chunk
                if size > MAX_BYTES then too_large = true return nil, "size" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    }
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    socketutil:set_timeout(timeout or 10, timeout or 10)
    local ok, success, status, response_headers = pcall(http.request, request)
    socketutil:set_timeout(old_block, old_total)
    if too_large then return nil, nil, "size" end
    if not ok or not success then
        local timed_out = status == "timeout" or status == "wantread" or status == "wantwrite"
        return nil, nil, timed_out and "timeout" or "network"
    end
    merge_cookies(jar, response_headers)
    return tonumber(status), table.concat(chunks), nil, response_headers
end

local function decode(body)
    local ok, data = pcall(JSON.decode, body or "")
    return ok and type(data) == "table" and data or nil
end

local function valid_qr_link(link, token)
    if type(link) ~= "string" then return false end
    if link == BASE .. "/account/scan/login/" .. token then return true end
    local query = link:match("^https://www%.zhihu%.com/account/qrcode/scan%?([^#]+)$")
    if not query then return false end
    for key, value in query:gmatch("([^&=]+)=([^&]*)") do
        if key == "token" and value == token then return true end
    end
    return false
end

local function qr_shape(data)
    local token = data and (data.token or data.qrcode_token or data.qrcodeToken)
    local link = data and data.link
    local path = type(link) == "string" and link:match("^https://www%.zhihu%.com([^?#]*)") or nil
    return "token_type=" .. type(token) .. " token_format="
        .. tostring(type(token) == "string" and token:match("^[%w_%-]+$") ~= nil)
        .. " link_path=" .. tostring(path or "unrecognized")
end

local function challenge(status, body, headers)
    local location = headers and (headers.location or headers.Location) or ""
    local data = decode(body)
    local code = data and type(data.error) == "table" and tonumber(data.error.code)
    local body_text = type(body) == "string" and body or ""
    if (status and status >= 300 and status < 400 and type(location) == "string"
        and location:find("/account/unhuman", 1, true))
        or body_text:find("/account/unhuman", 1, true)
        or body_text:find("人机验证", 1, true)
        or code == 40352 or code == 40362 then
        return failure("verification_required", status, "知乎要求人机验证；扫码实验已停止。")
    end
end

local function positive_expiry(value, now)
    value = tonumber(value)
    if not value or value <= 0 then return now + 120000 end
    if value > now then return value end
    -- WeRead-style QR services commonly return a TTL under expires_at.
    if value < 86400 then return now + value * 1000 end
    if value < 86400000 then return now + value end
    return now + 120000
end

function Protocol.create(request, now_ms)
    request = request or Protocol.request
    now_ms = now_ms or function() return os.time() * 1000 end
    local jar = {}
    local status, body, err, page_headers = request("GET", "/signin", jar)
    if not status then return nil, failure("network_error", nil, "登录页请求失败。", "login_page") end
    local denied = challenge(status, body, page_headers)
    if denied then denied.stage = "login_page" return nil, denied end
    if status ~= 200 then return nil, failure("invalid_response", status, "登录页 HTTP " .. tostring(status) .. "。", "login_page") end
    local login_page_status = status

    status, body, err = request("POST", "/udid", jar, "{}")
    if not status then return nil, failure("network_error", nil, "设备初始化请求失败。", "device_init") end
    denied = challenge(status, body)
    if denied then denied.stage = "device_init" return nil, denied end
    local device = decode(body)
    if status ~= 200 or (not jar.d_c0 and not (device and type(device.udid) == "string" and device.udid ~= "")) then
        return nil, failure(status == 403 and "forbidden" or "invalid_response", status, "设备初始化未完成。", "device_init")
    end
    local device_status = status

    status, body, err = request("POST", "/api/v3/account/api/login/qrcode", jar, "{}")
    if not status then return nil, failure("network_error", nil, "二维码请求失败。", "qr_create") end
    denied = challenge(status, body)
    if denied then denied.stage = "qr_create" return nil, denied end
    if status ~= 200 then return nil, failure(status == 403 and "forbidden" or "invalid_response", status, "二维码接口 HTTP " .. tostring(status) .. "。", "qr_create") end
    local data = decode(body)
    local token = data and (data.token or data.qrcode_token or data.qrcodeToken)
    if type(token) ~= "string" or not token:match("^[%w_%-]+$")
        or not valid_qr_link(data.link, token) then
        local issue = qr_shape(data)
        return nil, failure("invalid_response", status, "二维码响应格式异常。", "qr_create", issue)
    end
    return { link = data.link, token = token, expires_at = positive_expiry(data.expires_at, now_ms()), jar = jar,
        http = { login_page = login_page_status, device_init = device_status, qr_create = status } }
end

function Protocol.poll(session, request)
    request = request or Protocol.request
    if type(session) ~= "table" or type(session.token) ~= "string"
        or not session.token:match("^[%w_%-]+$") or type(session.jar) ~= "table" then
        return nil, failure("invalid_response", nil, "二维码会话无效。")
    end
    local status, body, err, headers = request("GET", "/api/v3/account/api/login/qrcode/" .. session.token .. "/scan_info", session.jar)
    if not status then return nil, failure("network_error", nil, err == "timeout" and "扫码状态查询超时。" or "扫码状态查询失败。", "scan_poll") end
    local denied = challenge(status, body, headers)
    if denied then denied.stage = "scan_poll" return nil, denied end
    local data = decode(body)
    local code = data and type(data.error) == "table" and tonumber(data.error.code)
    if status == 403 and code == 40352 then return nil, failure("verification_required", status, "知乎要求人机验证；扫码实验已停止。", "scan_poll") end
    if status == 401 then return nil, failure("login_required", status, "扫码会话已失效。", "scan_poll") end
    if status == 403 then return nil, failure("forbidden", status, "知乎拒绝了扫码状态请求。", "scan_poll") end
    if status ~= 200 or not data or type(data.status) ~= "number" then
        return nil, failure("invalid_response", status, "扫码状态响应格式异常。", "scan_poll")
    end
    merge_cookies(session.jar, headers)
    merge_cookies(session.jar, { ["set-cookie"] = data.cookie or data.cookies })
    if type(data.z_c0) == "string" and #data.z_c0 <= 4096 then session.jar.z_c0 = data.z_c0 end
    local login_status = type(data.login_status) == "string" and data.login_status:upper() or ""
    if data.status == 2 or login_status == "EXPIRED" or login_status == "QR_CODE_EXPIRED" then
        return nil, failure("qr_expired", status, "二维码已过期，请重新发起登录。", "scan_poll")
    end
    return { status = data.status, confirmed = login_status == "CONFIRMED"
        or login_status == "LOGIN_SUCCESS" or data.success == true or data.logged_in == true
        or data.loggedIn == true or data.user_id ~= nil or data.userId ~= nil,
        jar = session.jar, http_status = status }
end

function Protocol.verify_session(session, request)
    request = request or Protocol.request
    if type(session) ~= "table" or type(session.jar) ~= "table" or not session.jar.z_c0 then
        return nil, failure("login_required", nil, "扫码已确认，但尚未取得登录凭据。", "session_verify")
    end
    local status, body, err, headers = request("GET", "/api/v4/me", session.jar)
    if not status then return nil, failure("network_error", nil, "登录态校验请求失败。", "session_verify") end
    local denied = challenge(status, body, headers)
    if denied then denied.stage = "session_verify" return nil, denied end
    if status == 401 then return nil, failure("login_required", status, "知乎登录态无效。", "session_verify") end
    if status == 403 then return nil, failure("forbidden", status, "知乎拒绝了登录态校验。", "session_verify") end
    local data = decode(body)
    if status ~= 200 or not data or not (data.id or data.url_token or data.name or data.name_cn) then
        return nil, failure("invalid_response", status, "无法确认知乎登录态。", "session_verify")
    end
    session.user = { id = tostring(data.id or data.url_token or ""), name = tostring(data.name or data.name_cn or "知乎用户") }
    session.http_status = status
    return session
end

Protocol.failure = failure
Protocol.cookie_header = cookie_header
return Protocol
