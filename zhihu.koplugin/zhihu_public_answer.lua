local JSON = require("json")
local API = require("zhihu_api")
local Renderer = require("zhihu_renderer")

local PublicAnswer = {}
PublicAnswer.__index = PublicAnswer

local function failure(kind, status)
    local messages = {
        input = "这条内容没有可识别的知乎回答链接，摘要仍可阅读。",
        network = "网页请求失败，摘要仍可阅读。",
        timeout = "网页请求超时，摘要仍可阅读。",
        size = "网页响应过大，摘要仍可阅读。",
        verification = "知乎要求人机验证，摘要仍可阅读。",
        auth = "该回答需要登录或当前无权阅读，摘要仍可阅读。",
        paid = "该回答包含付费内容，当前请求无法读取全文；摘要仍可阅读。",
        truncated = "网页返回的正文仍有截断提示，摘要仍可阅读。",
        redirect = "知乎将请求转到了其他页面，摘要仍可阅读。",
        unreadable = "未能确认回答正文完整，摘要仍可阅读。",
    }
    return { kind = kind, status = status, message = messages[kind] or messages.unreadable }
end

function PublicAnswer.answer_id(url)
    if type(url) ~= "string" or url:find("[%c%s]") then return nil end
    local path = url:match("^([^%?#]+)")
    if not path then return nil end
    local question_id, answer_id = path:match("^https://www%.zhihu%.com/question/(%d+)/answer/(%d+)/?$")
    if not question_id or not answer_id then return nil end
    return answer_id
end

function PublicAnswer.new(options)
    options = options or {}
    return setmetatable({ send = options.transport or API.transport, timeout = options.timeout or 20 }, PublicAnswer)
end

local function blocked(payload, status)
    local error = type(payload) == "table" and payload.error
    local code = type(error) == "table" and tonumber(error.code)
    if code == 40352 or code == 40362 then return failure("verification", status) end
    if status == 401 or status == 403 then return failure("auth", status) end
    return nil
end

local function restriction(payload, content)
    if payload.is_paid == true or payload.is_payed == true or payload.is_purchased == false then return "paid" end
    local paid = payload.paid_info
    if type(paid) == "table" and (paid.is_paid == true or paid.is_payed == true
        or paid.is_purchased == false or paid.has_purchased == false or paid.need_pay == true
        or (tonumber(paid.price) or 0) > 0) then return "paid" end
    if payload.content_need_truncated == true or payload.force_login_when_click_read_more == true then
        return "truncated"
    end
    if content:find("阅读全文", 1, true) or content:find("查看完整回答", 1, true)
        or content:find("购买后查看", 1, true) then return "truncated" end
end

function PublicAnswer:fetch(url, summary)
    local answer_id = PublicAnswer.answer_id(url)
    if not answer_id then return nil, failure("input") end
    -- Exactly one anonymous GET. No redirects, credentials, retry, or cache write.
    local request = {
        url = "https://www.zhihu.com/api/v4/answers/" .. answer_id .. "?include=content,excerpt,paid_info",
        method = "GET", redirect = false,
        headers = { Accept = "application/json", ["User-Agent"] = "Mozilla/5.0 (KOReader; Zhihu reading probe)" },
    }
    local ok, status, body, transport_error = pcall(self.send, request, self.timeout)
    if not ok or not status then
        return nil, failure(transport_error == "timeout" and "timeout" or transport_error == "size" and "size" or "network")
    end
    if type(body) ~= "string" or #body > API.MAX_RESPONSE_BYTES then return nil, failure("size", status) end
    local decoded, payload = pcall(JSON.decode, body)
    if not decoded or type(payload) ~= "table" then payload = nil end
    local denied = blocked(payload, status)
    if denied then return nil, denied end
    if status >= 300 and status < 400 then return nil, failure("redirect", status) end
    if status ~= 200 or not payload then return nil, failure("unreadable", status) end
    if tostring(payload.id or "") ~= answer_id or type(payload.content) ~= "string"
        or payload.content == "" then
        return nil, failure("unreadable", status)
    end
    local restricted = restriction(payload, payload.content)
    if restricted then return nil, failure(restricted, status) end
    local content = Renderer.text(payload.content)
    if content == "" then return nil, failure("unreadable", status) end
    -- When the official summary ends in an ellipsis, a no-longer-than-summary
    -- response cannot be evidence that the missing part was obtained.
    local preview = Renderer.text(summary or "")
    if (preview:find("…", 1, true) or preview:find("...", 1, true)) and #content <= #preview then
        return nil, failure("unreadable", status)
    end
    return { content = content, answer_id = answer_id, url = url, status = status }
end

return PublicAnswer
