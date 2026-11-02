local JSON = require("json")
local Protocol = {}
local BASE = "https://www.zhihu.com"
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/135.0.0.0 Safari/537.36"
local MAX_BYTES = 128 * 1024
local COOKIE_NAMES = { _xsrf = true, _zap = true, d_c0 = true, BEC = true, sec_token = true, z_c0 = true }

local function cookie_header(jar)
    local entries = {}
    for name, value in pairs(jar) do
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
            -- Each cookie begins at the start of a header or after a comma.
            -- Restrict names so Expires/Path/Domain cannot become cookies.
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
        ["User-Agent"] = UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = BASE .. "/signin",
        ["Origin"] = BASE,
        ["X-Requested-With"] = "fetch",
    }
    local cookies = cookie_header(jar)
    if cookies ~= "" then headers["Cookie"] = cookies end
    if jar._xsrf then headers["X-Xsrftoken"] = jar._xsrf end
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
    if too_large then return nil, nil, "响应过大" end
    if not ok or not success then return nil, nil, "网络请求失败" end
    merge_cookies(jar, response_headers)
    return tonumber(status), table.concat(chunks), nil, response_headers
end

local function decode(body)
    local ok, data = pcall(JSON.decode, body or "")
    return ok and type(data) == "table" and data or nil
end

function Protocol.create(request)
    request = request or Protocol.request
    local jar = {}
    local status, _, _, page_headers = request("GET", "/signin", jar)
    local location = page_headers and (page_headers.location or page_headers.Location)
    if status == 302 and type(location) == "string"
        and location:find("^https://www%.zhihu%.com/account/unhuman") then
        return nil, "知乎要求人机验证，设备端扫码实验已停止。"
    end
    if status ~= 200 then return nil, "登录页 HTTP " .. tostring(status or 0) end
    status = request("POST", "/udid", jar, "{}")
    if status ~= 200 or not jar.d_c0 then return nil, "设备初始化失败（HTTP " .. tostring(status or 0) .. "）" end
    local body
    status, body = request("POST", "/api/v3/account/api/login/qrcode", jar, "{}")
    if status ~= 200 then return nil, "二维码接口 HTTP " .. tostring(status or 0) end
    local data = decode(body)
    if not data or type(data.token) ~= "string" or not data.token:match("^[%w_%-]+$")
        or type(data.link) ~= "string"
        or data.link:match("^https://www%.zhihu%.com/account/scan/login/[%w_%-]+$") == nil
        or not data.link:find(data.token, 1, true) then
        return nil, "二维码响应格式异常"
    end
    local expires = tonumber(data.expires_at)
    if not expires then return nil, "二维码缺少有效期" end
    return { link = data.link, token = data.token, expires_at = expires, jar = jar }
end

function Protocol.poll(session, request)
    request = request or Protocol.request
    if type(session) ~= "table" or type(session.token) ~= "string"
        or not session.token:match("^[%w_%-]+$") then return nil, "无效会话" end
    local path = "/api/v3/account/api/login/qrcode/" .. session.token .. "/scan_info"
    local status, body, err = request("GET", path, session.jar)
    if not status then return nil, err end
    local data = decode(body)
    if status == 403 and data and type(data.error) == "table" and data.error.code == 40352 then
        return nil, "知乎要求环境验证（40352），本次实验到此停止。"
    end
    if status ~= 200 then return nil, "扫码状态 HTTP " .. tostring(status) end
    if not data or data.status == nil then return nil, "扫码状态格式异常" end
    return { status = data.status, confirmed = data.login_status == "CONFIRMED", jar = session.jar }
end

return Protocol
