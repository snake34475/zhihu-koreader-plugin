local Renderer = require("zhihu_renderer")
local Schema = {}

local function first(object, names)
    for _, name in ipairs(names) do
        local value = object[name]
        if type(value) == "string" and value ~= "" then return value end
        if type(value) == "number" then return tostring(value) end
    end
    return ""
end

function Schema.safe_url(value)
    if type(value) ~= "string" or value:find("[%c%s]") then return "" end
    local host = value:match("^https?://([^/]+)")
    if not host or host:find("@", 1, true) then return "" end
    return value
end

function Schema.list(payload, limit)
    if type(payload) ~= "table" then return nil, "format" end
    local data = payload.Data or payload.data
    if type(data) ~= "table" then return nil, "format" end
    local items = data.Items or data.items
    if type(items) ~= "table" then return nil, "format" end
    -- A nonempty object is not an array. Reject it rather than cache an empty success.
    local count = 0
    for key in pairs(items) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "format" end
        count = count + 1
    end
    if count ~= #items then return nil, "format" end
    local result = { items = {}, empty_reason = Renderer.text(first(data, { "EmptyReason", "empty_reason" })) }
    for _, raw in ipairs(items) do
        if #result.items >= (limit or 30) then break end
        if type(raw) == "table" then
            local title = Renderer.text(first(raw, { "Title", "title" }))
            local url = Schema.safe_url(first(raw, { "Url", "url" }))
            local summary = Renderer.text(first(raw, { "ContentText", "Summary", "summary", "excerpt" }))
            if title ~= "" or summary ~= "" or url ~= "" then
                local author = first(raw, { "AuthorName", "author_name" })
                if author == "" and type(raw.author) == "table" then author = first(raw.author, { "name", "Name" }) end
                local kind = first(raw, { "ContentType", "type" }):lower()
                if kind == "" then
                    kind = url:find("/answer/", 1, true) and "answer"
                        or url:find("/question/", 1, true) and "question"
                        or url:find("/p/", 1, true) and "article" or "content"
                end
                result.items[#result.items + 1] = {
                    title = title ~= "" and title or "（无标题）",
                    summary = summary, url = url, kind = kind,
                    author = Renderer.text(author),
                    time = Renderer.text(first(raw, { "EditTime", "CreateTime", "updated_time", "created_time" })),
                }
            end
        end
    end
    if #items > 0 and #result.items == 0 then return nil, "format" end
    return result
end

function Schema.answer(payload)
    if type(payload) ~= "table" then return nil, "format" end
    local choices = payload.choices
    local choice = type(choices) == "table" and choices[1]
    local message = type(choice) == "table" and choice.message
    if type(message) ~= "table" or type(message.content) ~= "string" or choice.finish_reason == "error" then
        return nil, "format"
    end
    local content = Renderer.text(message.content)
    if content == "" then return nil, "format" end
    return { answer = content, model = first(payload, { "model" }), truncated = choice.finish_reason == "length" }
end

function Schema.question_url(value)
    if Schema.safe_url(value) == "" then return nil end
    local id, tail = value:match("^https://www%.zhihu%.com/question/(%d+)(.*)$")
    if not id or (tail ~= "" and not tail:match("^[/%?#]")) then return nil end
    return "https://www.zhihu.com/question/" .. id
end

function Schema.question_answers(payload, offset, limit)
    local result = Schema.list(payload, limit or 10)
    if not result then return nil, "format" end
    local data = payload.Data or payload.data
    local paging = data.Paging
    if type(paging) ~= "table" or type(paging.IsEnd) ~= "boolean" then return nil, "format" end
    result.is_end = paging.IsEnd
    if not paging.IsEnd then
        local next_offset = paging.NextOffset
        if type(next_offset) ~= "number" or next_offset ~= math.floor(next_offset)
            or next_offset <= (offset or 0) or next_offset > 9007199254740991 then
            return nil, "format"
        end
        result.next_offset = next_offset
    end
    for index, item in ipairs(result.items) do
        if item.title == "（无标题）" then item.title = "回答摘要 " .. tostring((offset or 0) + index) end
        item.kind = "answer"
    end
    return result
end

return Schema
