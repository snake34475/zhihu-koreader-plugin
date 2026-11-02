local Errors = {}
local messages = {
    config = "请先在设置中填写有效的 Base URL 和 Access Secret。",
    input = "请输入非空的关键词或问题。",
    network = "网络请求失败，请检查 Wi-Fi、设备时间和 HTTPS 连接后手动重试。",
    timeout = "请求超时，请稍后手动重试。",
    auth = "鉴权失败或权限不足，请检查 Access Secret 和设备时间。",
    quota = "额度或余额不足，请在知乎开放平台检查用量。",
    rate = "调用频率、并发或当日额度超限，请检查用量后稍后重试。",
    format = "接口返回格式异常，已保留上次缓存。",
    http = "服务请求失败，请稍后手动重试。",
    redirect = "接口返回重定向，请检查 Base URL。",
    size = "响应过大，已停止接收并保留上次缓存。",
    internal = "操作未完成，请检查配置或重启插件后重试。",
}

function Errors.new(kind, status, code)
    -- Never propagate untrusted error strings or HTTP bodies into logs/UI.
    return { kind = kind, message = messages[kind] or messages.internal,
        status = tonumber(status), code = tonumber(code) }
end

function Errors.response(status, payload)
    local code, nested
    if type(payload) == "table" then
        code = payload.Code or payload.code
        nested = payload.error
    end
    local name = type(nested) == "table" and (nested.code or nested.type) or ""
    local number = tonumber(code)
    if status == 401 or status == 403 or number == 20001 or name == "invalid_api_key" then
        return Errors.new("auth", status, number)
    elseif status == 402 or number == 30002 or name == "insufficient_quota" or name == "insufficient_balance" then
        return Errors.new("quota", status, number)
    elseif status == 429 or number == 30001 or name == "rate_limit_exceeded" then
        return Errors.new("rate", status, number)
    elseif status >= 300 and status < 400 then
        return Errors.new("redirect", status, number)
    elseif status < 200 or status >= 300 or (number and number ~= 0) or nested ~= nil then
        return Errors.new("http", status, number)
    elseif code ~= nil and number == nil then
        return Errors.new("format", status)
    end
end

function Errors.scrub(value, secret, depth)
    depth = depth or 0
    if depth > 32 then return "[省略]" end
    if type(value) == "string" then
        if type(secret) == "string" and secret ~= "" then
            local pattern = secret:gsub("(%W)", "%%%1")
            value = value:gsub(pattern, "[已隐藏]")
        end
        return value:gsub("[Bb][Ee][Aa][Rr][Ee][Rr]%s+[%w%._~%+/%-=]+", "Bearer [已隐藏]")
    elseif type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do
            local name = tostring(key):lower():gsub("[^%w]", "")
            if name == "authorization" or name == "accesssecret" or name == "token" or name == "apikey"
                or name == "accesstoken" or name == "cookie" then
                result[key] = "[已隐藏]"
            else
                result[Errors.scrub(key, secret, depth + 1)] = Errors.scrub(item, secret, depth + 1)
            end
        end
        return result
    end
    if type(value) == "number" or type(value) == "boolean" then return value end
    -- JSON null may be a userdata/cdata sentinel in the bundled JSON library.
    -- Omit it so subprocess serialization only sees ordinary Lua values.
    return nil
end

return Errors
