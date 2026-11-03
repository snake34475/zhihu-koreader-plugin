local Renderer = require("zhihu_renderer")
local Schema = require("zhihu_schema")

local Feed = {}

local function text(value)
    if type(value) == "string" or type(value) == "number" then return Renderer.text(tostring(value)) end
    return ""
end

local function numeric_id(value)
    local id = tostring(value or "")
    return id:match("^%d+$") and id or nil
end

local function author_name(target, item)
    local author = type(target.author) == "table" and target.author
        or type(item.actors) == "table" and type(item.actors[1]) == "table" and item.actors[1]
    if not author then return "" end
    return text(author.name or author.name_cn)
end

local function item_from_feed(item)
    if type(item) ~= "table" then return nil end
    local target = type(item.target) == "table" and item.target or item
    local kind = tostring(target.type or ""):lower()
    local id = numeric_id(target.id)
    local question = type(target.question) == "table" and target.question or nil
    local question_id = numeric_id(question and question.id)
    local title, url, normalized_kind
    if kind == "answer" or (question and id) then
        if not id or not question_id then return nil end
        normalized_kind = "answer"
        title = text(question.title)
        url = "https://www.zhihu.com/question/" .. question_id .. "/answer/" .. id
    elseif kind == "question" or (not kind and id and type(target.title) == "string") then
        if not id then return nil end
        normalized_kind = "question"
        title = text(target.title)
        url = "https://www.zhihu.com/question/" .. id
    elseif kind == "article" then
        if not id then return nil end
        normalized_kind = "article"
        title = text(target.title)
        url = "https://www.zhihu.com/p/" .. id
    else
        return nil
    end
    local summary = text(target.excerpt or target.summary or target.content)
    if title == "" then title = normalized_kind == "answer" and "知乎回答" or "（无标题）" end
    return { title = title, summary = summary, url = url, kind = normalized_kind,
        author = author_name(target, item), time = text(target.updated_time or target.created_time) }
end

function Feed.list(payload, limit)
    if type(payload) ~= "table" or type(payload.data) ~= "table" or type(payload.paging) ~= "table"
        or type(payload.paging.is_end) ~= "boolean" then return nil end
    local data = payload.data
    local count = 0
    for key in pairs(data) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count ~= #data then return nil end
    local result = { items = {}, is_end = payload.paging.is_end }
    for _, entry in ipairs(data) do
        if #result.items < (limit or 30) then
            local normalized = item_from_feed(entry)
            if normalized then result.items[#result.items + 1] = normalized end
        end
    end
    if #data > 0 and #result.items == 0 then return nil end
    local next_cursor = payload.paging.next
    if not result.is_end then
        if type(next_cursor) ~= "string" or next_cursor == "" or #next_cursor > 4096
            or next_cursor:find("[%c%s#]") then return nil end
        result.next_cursor = next_cursor
    end
    return result
end

function Feed.cached(value, limit)
    if type(value) ~= "table" or type(value.items) ~= "table" then return nil end
    local items = {}
    for _, item in ipairs(value.items) do
        if type(item) ~= "table" or type(item.title) ~= "string" or item.title == ""
            or type(item.summary) ~= "string" or type(item.url) ~= "string"
            or not item.url:match("^https://www%.zhihu%.com/")
            or Schema.safe_url(item.url) == "" or type(item.kind) ~= "string" then return nil end
        items[#items + 1] = { title = item.title, summary = item.summary, url = item.url,
            kind = item.kind, author = type(item.author) == "string" and item.author or "",
            time = type(item.time) == "string" and item.time or "" }
        if #items > (limit or 30) then return nil end
    end
    if type(value.is_end) ~= "boolean" then return nil end
    return { items = items, is_end = value.is_end }
end

return Feed
