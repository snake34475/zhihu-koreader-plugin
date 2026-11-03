-- Private, isolated cache for validated logged-in content. Session cookies are never stored here.
local Storage = require("zhihu_storage")
local Cache = {}
Cache.__index = Cache

local function answer_id(value)
    value = tostring(value or "")
    return value:match("^%d+$") and value or nil
end

local function cursor_key(value)
    local text = tostring(value or "0")
    local hash = 5381
    for index = 1, #text do hash = (hash * 33 + text:byte(index)) % 4294967296 end
    return string.format("%08x", hash), text
end

function Cache.new(directory, clock)
    return setmetatable({ directory = directory, clock = clock or os.time }, Cache)
end

function Cache:save_answer(answer)
    if type(answer) ~= "table" or not answer_id(answer.answer_id)
        or type(answer.content) ~= "string" or answer.content == ""
        or type(answer.fetched_at) ~= "number" then return nil, "format" end
    return Storage.write(self.directory .. "/answer-" .. answer.answer_id .. ".json", {
        version = 1, kind = "answer", answer_id = answer.answer_id,
        content = answer.content, fetched_at = answer.fetched_at,
    })
end

function Cache:load_answer(id)
    id = answer_id(id)
    if not id then return nil, "format" end
    local entry, err = Storage.read(self.directory .. "/answer-" .. id .. ".json")
    if not entry then return nil, err end
    if entry.version ~= 1 or entry.kind ~= "answer" or entry.answer_id ~= id
        or type(entry.content) ~= "string" or entry.content == "" or type(entry.fetched_at) ~= "number" then
        return nil, "format"
    end
    return entry
end

function Cache:save_comments(id, cursor, page)
    id = answer_id(id)
    local key
    key, cursor = cursor_key(cursor)
    if not id or #cursor > 2048 or type(page) ~= "table"
        or type(page.items) ~= "table" or type(page.is_end) ~= "boolean"
        or type(page.fetched_at) ~= "number" then return nil, "format" end
    return Storage.write(self.directory .. "/comments-" .. id .. "-" .. key .. ".json", {
        version = 1, kind = "comments", answer_id = id, cursor = cursor,
        items = page.items, next_cursor = page.next_cursor, is_end = page.is_end,
        fetched_at = page.fetched_at, range = page.range,
    })
end

function Cache:load_comments(id, cursor)
    id = answer_id(id)
    local key
    key, cursor = cursor_key(cursor)
    if not id or #cursor > 2048 then return nil, "format" end
    local entry, err = Storage.read(self.directory .. "/comments-" .. id .. "-" .. key .. ".json")
    if not entry then return nil, err end
    if entry.version ~= 1 or entry.kind ~= "comments" or entry.answer_id ~= id
        or entry.cursor ~= cursor or type(entry.items) ~= "table"
        or type(entry.is_end) ~= "boolean" or type(entry.fetched_at) ~= "number"
        or (entry.range ~= nil and type(entry.range) ~= "string") then return nil, "format" end
    return entry
end

return Cache
