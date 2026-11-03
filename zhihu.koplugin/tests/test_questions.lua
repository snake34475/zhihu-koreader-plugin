local JSON = require("json")
local Schema = require("zhihu_schema")
local API = require("zhihu_api")
local Cache = require("zhihu_cache")
local Config = require("zhihu_config")
local url = "https://www.zhihu.com/question/100"

test("question answers normalize missing titles and exact server cursor", function()
    local result = assert(Schema.question_answers(JSON.decode(fixture("question_answers")), 0, 10))
    eq(#result.items, 2)
    eq(result.items[1].title, "回答摘要 1")
    eq(result.next_offset, 17)
    eq(result.is_end, false)
end)

test("question paging rejects absent, repeated or malformed next cursor", function()
    for _, paging in ipairs({ {}, {IsEnd = false}, {IsEnd = false, NextOffset = 17},
        {IsEnd = false, NextOffset = "20"}, {IsEnd = false, NextOffset = 18.5} }) do
        eq(Schema.question_answers({ Data = { Items = {}, Paging = paging } }, 17), nil)
    end
end)

test("empty nonfinal page retains next cursor and final page requires none", function()
    local result = assert(Schema.question_answers({Data = {Items = {}, Paging = {IsEnd = false, NextOffset = 50}}}, 17))
    eq(#result.items, 0) eq(result.next_offset, 50)
    eq(assert(Schema.question_answers({Data = {Items = {}, Paging = {IsEnd = true}}}, 50)).is_end, true)
end)

test("canonical question links strip answer and tracking paths safely", function()
    eq(Schema.question_url(url .. "/answer/301?utm_source=fixture"), url)
    eq(Schema.question_url("https://evil.example/question/100"), nil)
    eq(Schema.question_url("https://www.zhihu.com/question/100evil"), nil)
end)

test("question API sends canonical URL and fixed count with exact offset", function()
    local config = Config.open(test_directory .. "/question-config.json")
    config.values.access_secret = "fixture-question-secret"
    local calls = 0
    local api = API.new(config, {transport = function(request)
        calls = calls + 1
        assert(request.url:find("/api/v1/content/question_answers?", 1, true))
        assert(request.url:find("Offset=0", 1, true))
        assert(request.url:find("Limit=10", 1, true))
        assert(request.url:find("QuestionUrl=https%3A%2F%2Fwww.zhihu.com%2Fquestion%2F100", 1, true))
        return 200, fixture("question_answers")
    end})
    assert(api:question_answers(url))
    local _, err = api:question_answers(url, -1)
    eq(err.kind, "input") eq(calls, 1)
end)

test("question disk cache retains visited batches and never mixes questions", function()
    local cache = Cache.new(test_directory)
    local raw = JSON.decode(fixture("question_answers"))
    assert(cache:save_question(url, "示例问题", 0, raw))
    raw.Data.Paging = {IsEnd = true}
    assert(cache:save_question(url, "示例问题", 17, raw))
    eq(assert(cache:load_question(url, 0)).result.next_offset, 17)
    eq(assert(cache:recent_question()).offset, 17)
    eq(cache:load_question(url .. "1", 0), nil)
    assert(cache:save_question(url .. "1", "其他问题", 0, raw))
    eq(cache:load_question(url, 0), nil)
end)

test("invalid question page cannot overwrite good offline cache", function()
    local cache = Cache.new(test_directory)
    assert(cache:save_question(url, "示例问题", 0, JSON.decode(fixture("question_answers"))))
    eq(cache:save_question(url, "示例问题", 0, {Data = {Items = {}}}), nil)
    eq(assert(cache:load_question(url, 0)).result.next_offset, 17)
end)

test("question cache remains bounded to ten recently read batches", function()
    local cache = Cache.new(test_directory)
    local raw = JSON.decode(fixture("question_answers"))
    raw.Data.Paging = {IsEnd = true}
    for offset = 0, 11 do assert(cache:save_question(url, "示例问题", offset, raw)) end
    eq(cache:load_question(url, 0), nil)
    assert(cache:load_question(url, 11))
end)
