local Config = require("zhihu_config")
local API = require("zhihu_api")
local Errors = require("zhihu_errors")
local JSON = require("json")
local config = Config.open(test_directory .. "/api-config.json")
local secret = "fixture-secret.with+symbols"
assert(config:set("access_secret", secret))
local function api_for(status, content)
    return API.new(config, { transport = function() return status, content end })
end

test("Bearer headers, fresh timestamps and hot cap", function()
    local calls, now = {}, 1000
    config.values.hot_limit = 100
    local api = API.new(config, { clock = function() now = now + 1 return now end,
        transport = function(request)
            calls[#calls + 1] = request
            return 200, fixture("hot")
        end })
    assert(api:hot_list())
    assert(api:hot_list())
    eq(calls[1].url, "https://developer.zhihu.com/api/v1/content/hot_list?Limit=30")
    eq(calls[1].headers.Authorization, "Bearer " .. secret)
    eq(calls[1].headers["Content-Type"], "application/json")
    assert(calls[1].headers["X-Request-Timestamp"] ~= calls[2].headers["X-Request-Timestamp"])
    eq(calls[1].redirect, false)
    assert(not calls[1].url:find(secret, 1, true))
end)

test("search percent encoding and request/response count limits", function()
    config.values.search_count = 99
    local seen
    local many = { Code = 0, Data = { Items = {} } }
    for i = 1, 20 do many.Data.Items[i] = { Title = "item " .. i } end
    local api = API.new(config, { transport = function(request)
        seen = request
        return 200, JSON.encode(many)
    end })
    local result = assert(api:search("人工智能 &x=1"))
    eq(#result.items, 10)
    assert(seen.url:find("Count=10", 1, true))
    assert(seen.url:find("%E4%BA%BA", 1, true))
    assert(seen.url:find("%26x%3D1", 1, true))
    config.values.search_count = 10
end)

test("chat uses supported non-streaming contract", function()
    local api = API.new(config, { transport = function(request)
        eq(request.method, "POST")
        eq(request.url, "https://developer.zhihu.com/v1/chat/completions")
        local body = JSON.decode(request.body)
        eq(body.model, "zhida-fast-1p5")
        eq(body.stream, false)
        eq(body.messages[1].content, "question")
        return 200, fixture("answer")
    end })
    assert(api:ask("question"))
end)

test("empty input never calls transport", function()
    local api = API.new(config, { transport = function() error("should not send") end })
    local result, err = api:search("  ")
    eq(result, nil) eq(err.kind, "input")
    result, err = api:ask(nil)
    eq(result, nil) eq(err.kind, "input")
end)

test("missing secret and invalid base fail locally", function()
    local empty = Config.open(test_directory .. "/absent.json")
    local api = API.new(empty, { transport = function() error("should not send") end })
    local _, err = api:hot_list()
    eq(err.kind, "config")
    empty.values.access_secret = "fake"
    empty.values.base_url = "http://insecure.example"
    _, err = api:hot_list()
    eq(err.kind, "config")
end)

test("HTTP and business errors classified", function()
    local cases = {
        { 401, "{}", "auth" }, { 403, "{}", "auth" },
        { 200, fixture("auth_error"), "auth" },
        { 402, "{}", "quota" }, { 200, fixture("quota_error"), "quota" },
        { 200, '{"Code":30002}', "quota" }, { 200, '{"Code":30001}', "rate" },
        { 429, "{}", "rate" }, { 500, "not json", "http" },
        { 302, "{}", "redirect" }, { 200, "not json", "format" },
        { 200, '{"Data":{}}', "format" }, { 200, '{"Code":"broken"}', "format" },
    }
    for _, case in ipairs(cases) do
        local result, err = api_for(case[1], case[2]):hot_list()
        eq(result, nil) eq(err.kind, case[3])
    end
end)

test("transport exceptions and timeouts do not expose errors", function()
    local api = API.new(config, { transport = function() error(secret) end })
    local _, err = api:hot_list()
    eq(err.kind, "network")
    assert(not JSON.encode(err):find(secret, 1, true))
    api = API.new(config, { transport = function() return nil, nil, "timeout" end })
    _, err = api:hot_list()
    eq(err.kind, "timeout")
end)

test("oversized response rejected", function()
    local _, err = api_for(200, string.rep("x", API.MAX_RESPONSE_BYTES + 1)):hot_list()
    eq(err.kind, "size")
end)

test("logs contain only numeric status and duration", function()
    local captured
    local api = API.new(config, { logger = { info = function(...) captured = {...} end },
        transport = function() return 500, secret end })
    api:hot_list()
    eq(#captured, 3)
    eq(captured[2], 500)
    eq(type(captured[3]), "number")
    assert(not JSON.encode(captured):find(secret, 1, true))
end)

test("scrub literal secrets, nested credentials and bearer tokens", function()
    local clean = Errors.scrub({ note = secret, Authorization = "Bearer unknown-value", nested = {
        AccessSecret = "another", text = "Bearer other-token", [secret] = "value",
    } }, secret)
    local encoded = JSON.encode(clean)
    assert(not encoded:find(secret, 1, true))
    assert(not encoded:find("another", 1, true))
    assert(not encoded:find("other-token", 1, true))
end)

test("transport restores socket timeouts even on exceptions", function()
    local util = { block_timeout = 11, total_timeout = 22 }
    function util:set_timeout(a, b) self.block_timeout = a self.total_timeout = b end
    package.loaded.socketutil = util
    package.loaded.ltn12 = { source = { string = function(body) return function() return body end end } }
    package.loaded["socket.http"] = { request = function(request)
        eq(util.block_timeout, 30)
        eq(request.redirect, false)
        assert(request.sink("part"))
        error("fixture exception")
    end }
    local status, _, err = API.transport({ method = "GET", headers = {} }, 30)
    eq(status, nil) eq(err, "network")
    eq(util.block_timeout, 11) eq(util.total_timeout, 22)
end)

test("transport handles body bytes, HTTP status and sink cap", function()
    package.loaded["socket.http"].request = function(request)
        eq(request.headers["Content-Length"], tostring(#"中文"))
        eq(request.source(), "中文")
        request.sink("{}")
        return 1, 200
    end
    local status, body = API.transport({ method = "POST", headers = {}, body = "中文" }, 30)
    eq(status, 200) eq(body, "{}")
    package.loaded["socket.http"].request = function(request)
        local ok = request.sink(string.rep("x", API.MAX_RESPONSE_BYTES + 1))
        eq(ok, nil)
        return nil, "size"
    end
    local _, _, err = API.transport({ headers = {} }, 30)
    eq(err, "size")
end)
