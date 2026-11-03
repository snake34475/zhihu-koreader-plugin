local Storage = require("zhihu_storage")
local Errors = require("zhihu_errors")
local Schema = require("zhihu_schema")
local FeedSchema = require("zhihu_feed_schema")
local Cache = {}
Cache.__index = Cache
local kinds = { hot = true, answer = true }
local web_kinds = { hot = true, recommend = true }

function Cache.new(directory, secret_provider, clock)
    return setmetatable({ directory = directory, secret = secret_provider or function() return "" end,
        clock = clock or os.time }, Cache)
end

function Cache:save(kind, query, raw)
    if not kinds[kind] or type(raw) ~= "table" then return nil, "format" end
    local clean = Errors.scrub(raw, self.secret())
    local result = kind == "answer" and Schema.answer(clean) or kind ~= "answer" and Schema.list(clean)
    if not result then return nil, "format" end
    return Storage.write(self.directory .. "/" .. kind .. ".json", {
        version = 1, kind = kind, query = Errors.scrub(query or "", self.secret()),
        saved_at = self.clock(), raw = clean,
    })
end

function Cache:load(kind)
    if not kinds[kind] then return nil, "format" end
    local entry, err = Storage.read(self.directory .. "/" .. kind .. ".json")
    if not entry then return nil, err end
    if entry.version ~= 1 or entry.kind ~= kind or type(entry.query) ~= "string"
        or type(entry.saved_at) ~= "number" or entry.saved_at < 0 or type(entry.raw) ~= "table" then
        return nil, "format"
    end
    local result = kind == "answer" and Schema.answer(entry.raw) or kind ~= "answer" and Schema.list(entry.raw)
    if not result then return nil, "format" end
    entry.result = result
    return entry
end

function Cache:load_question(url, offset)
    local entry = Storage.read(self.directory .. "/question.json")
    if not entry or entry.version ~= 1 or entry.url ~= url or type(entry.pages) ~= "table" then return nil end
    for _, page in ipairs(entry.pages) do
        if type(page) == "table" and (offset == nil or page.offset == offset)
            and type(page.offset) == "number" and page.offset >= 0
            and page.offset == math.floor(page.offset) and type(page.saved_at) == "number" then
            local result = Schema.question_answers(page.raw, page.offset, 10)
            if result then
                return { result = result, raw = page.raw, offset = page.offset,
                    saved_at = page.saved_at, title = type(entry.title) == "string" and entry.title or "最近问题", url = url }
            end
        end
    end
end

function Cache:recent_question()
    local entry = Storage.read(self.directory .. "/question.json")
    if not entry or type(entry.url) ~= "string" then return nil end
    return self:load_question(entry.url)
end

function Cache:save_question(url, title, offset, raw)
    if Schema.question_url(url) ~= url or type(offset) ~= "number" or offset < 0
        or offset ~= math.floor(offset) then return nil end
    raw = Errors.scrub(raw, self.secret())
    if not Schema.question_answers(raw, offset, 10) then return nil end
    local entry = Storage.read(self.directory .. "/question.json")
    if not entry or entry.version ~= 1 or entry.url ~= url or type(entry.pages) ~= "table" then
        entry = { version = 1, url = url, pages = {} }
    end
    entry.title = Errors.scrub(title, self.secret())
    local pages = { { offset = offset, saved_at = self.clock(), raw = raw } }
    for _, page in ipairs(entry.pages) do
        if type(page) == "table" and page.offset ~= offset and #pages < 10 then pages[#pages + 1] = page end
    end
    entry.pages = pages
    return Storage.write(self.directory .. "/question.json", entry)
end

local function feed_filename(kind)
    if kind == "hot" or kind == "recommend" then return "web-" .. kind .. ".json" end
end

function Cache:save_feed(kind, result)
    local filename = feed_filename(kind)
    local clean = FeedSchema.cached(result, kind == "hot" and 30 or 10)
    if not filename or not clean then return nil, "format" end
    return Storage.write(self.directory .. "/" .. filename, {
        version = 1, kind = kind, saved_at = self.clock(), result = clean,
    })
end

function Cache:load_feed(kind)
    local filename = feed_filename(kind)
    if not filename then return nil, "format" end
    local entry, err = Storage.read(self.directory .. "/" .. filename)
    if not entry then return nil, err end
    local result = entry.version == 1 and entry.kind == kind and type(entry.saved_at) == "number"
        and FeedSchema.cached(entry.result, kind == "hot" and 30 or 10) or nil
    if not result then return nil, "format" end
    return { kind = kind, saved_at = entry.saved_at, result = result }
end

function Cache:save_web_question(url, title, index, result)
    if Schema.question_url(url) ~= url or type(index) ~= "number" or index < 1
        or index ~= math.floor(index) then return nil end
    local clean = FeedSchema.cached(result, 10)
    if not clean then return nil end
    local entry = Storage.read(self.directory .. "/web-question.json")
    if not entry or entry.version ~= 1 or entry.url ~= url or type(entry.pages) ~= "table" then
        entry = { version = 1, url = url, pages = {} }
    end
    entry.title = Errors.scrub(title or "", self.secret())
    local pages = { { index = index, saved_at = self.clock(), result = clean } }
    for _, page in ipairs(entry.pages) do
        if type(page) == "table" and page.index ~= index and #pages < 10 then pages[#pages + 1] = page end
    end
    entry.pages = pages
    return Storage.write(self.directory .. "/web-question.json", entry)
end

function Cache:load_web_question(url, index)
    local entry = Storage.read(self.directory .. "/web-question.json")
    if not entry or entry.version ~= 1 or entry.url ~= url or type(entry.pages) ~= "table" then return nil end
    local found
    for _, page in ipairs(entry.pages) do
        if type(page) == "table" and (index == nil or page.index == index)
            and type(page.index) == "number" and page.index >= 1
            and page.index == math.floor(page.index) and type(page.saved_at) == "number" then
            local result = FeedSchema.cached(page.result, 10)
            if result then
                local candidate = { index = page.index, saved_at = page.saved_at, result = result,
                    title = type(entry.title) == "string" and entry.title or "最近问题", url = url }
                if index ~= nil then return candidate end
                if not found or candidate.saved_at > found.saved_at then found = candidate end
            end
        end
    end
    return found
end

function Cache:recent_web_question()
    local entry = Storage.read(self.directory .. "/web-question.json")
    if not entry or type(entry.url) ~= "string" then return nil end
    local latest = type(entry.pages) == "table" and entry.pages[1]
    if type(latest) == "table" and type(latest.index) == "number" then
        return self:load_web_question(entry.url, latest.index)
    end
    return self:load_web_question(entry.url)
end

return Cache
