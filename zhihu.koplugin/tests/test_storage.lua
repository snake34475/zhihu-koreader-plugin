local Config = require("zhihu_config")
local Cache = require("zhihu_cache")
local LoggedCache = require("zhihu_logged_cache")
local Storage = require("zhihu_storage")
local JSON = require("json")

test("settings persist across reopen and clear secret on disk", function()
    local path = test_directory .. "/settings.json"
    local config = Config.open(path)
    assert(config:set("access_secret", "fixture-settings-secret"))
    assert(config:set("hot_limit", 12))
    config = Config.open(path)
    eq(config:get("access_secret"), "fixture-settings-secret")
    eq(config:get("hot_limit"), 12)
    assert(config:set("access_secret", ""))
    eq(Config.open(path):get("access_secret"), "")
    local f = assert(io.open(path, "rb"))
    assert(not f:read("*a"):find("fixture-settings-secret", 1, true))
    f:close()
    eq(io.open(path .. ".tmp", "rb"), nil)
end)

test("settings reject invalid ranges and unsafe URLs", function()
    for _, pair in ipairs({ { "hot_limit", 31 }, { "timeout", 0 },
        { "timeout", 121 }, { "hot_limit", 1.5 }, { "base_url", "http://example.com" },
        { "base_url", "https://user:pass@example.com" }, { "base_url", "https://a?secret=x" },
        { "base_url", "https://a/#fragment" }, { "access_secret", "a\r\nb" },
        { "model", "unknown" }, { "download_images", true }, { "reader_side", "top" } }) do
        eq(Config.validate(pair[1], pair[2]), nil)
    end
    eq(Config.validate("base_url", " https://developer.zhihu.com/ "), "https://developer.zhihu.com")
end)

test("corrupt config uses defaults and signals damage", function()
    local path = test_directory .. "/broken-settings.json"
    write(path, "{broken")
    local config = Config.open(path)
    eq(config:get("hot_limit"), 30)
    eq(config:get("access_secret"), "")
    eq(config.load_error, "format")
end)

test("failed write leaves in-memory settings unchanged", function()
    local config = Config.open(test_directory .. "/missing-directory/settings.json")
    local ok = config:set("hot_limit", 2)
    eq(ok, nil)
    eq(config:get("hot_limit"), 30)
end)

test("all cache categories survive reopening without network", function()
    local cache = Cache.new(test_directory, nil, function() return 1000 end)
    for _, item in ipairs({ {"hot", "hot"}, {"answer", "answer"} }) do
        assert(cache:save(item[1], "查询", JSON.decode(fixture(item[2]))))
        local loaded = assert(Cache.new(test_directory):load(item[1]))
        eq(loaded.query, "查询") eq(loaded.saved_at, 1000)
        assert(loaded.result)
    end
end)

test("invalid cache save preserves previous successful result", function()
    local cache = Cache.new(test_directory)
    assert(cache:save("hot", "old", JSON.decode(fixture("hot"))))
    eq(cache:save("hot", "new", { Data = {} }), nil)
    eq(assert(cache:load("hot")).query, "old")
end)

test("cache redacts echoed secrets before writing query and raw response", function()
    local secret = "fixture-cache-secret"
    local cache = Cache.new(test_directory, function() return secret end)
    local raw = JSON.decode(fixture("hot"))
    raw.Data.Items[1].Summary = secret
    raw.AccessSecret = secret
    assert(cache:save("hot", secret, raw))
    local file = assert(io.open(test_directory .. "/hot.json", "rb"))
    assert(not file:read("*a"):find(secret, 1, true))
    file:close()
end)

test("cache rejects path traversal, corrupt JSON and incompatible envelope", function()
    local cache = Cache.new(test_directory)
    eq(cache:load("../escape"), nil)
    write(test_directory .. "/hot.json", "not json")
    local _, err = cache:load("hot") eq(err, "format")
    assert(Storage.write(test_directory .. "/hot.json", {version = 99}))
    _, err = cache:load("hot") eq(err, "format")
end)

test("bounded file read rejects oversized cache", function()
    local path = test_directory .. "/oversize.json"
    write(path, string.rep("x", Storage.MAX_BYTES + 1))
    local _, err = Storage.read(path)
    eq(err, "size")
end)

test("logged content uses a separate cache and rejects incomplete records", function()
    local directory = test_directory .. "/logged"
    assert(os.execute("mkdir \"" .. directory .. "\""))
    local cache = LoggedCache.new(directory, function() return 1700000000 end)
    eq(cache:save_answer({ answer_id = "301", content = "", fetched_at = 1700000000 }), nil)
    assert(cache:save_answer({ answer_id = "301", content = "已核验正文", fetched_at = 1700000000 }))
    local answer = assert(cache:load_answer("301"))
    eq(answer.content, "已核验正文")
    eq(cache:load_answer("../301"), nil)
    local page = { items = { { id = "c1", author = "甲", content = "评论" } },
        next_cursor = "20", is_end = false, fetched_at = 1700000000, range = "本页 1 条" }
    assert(cache:save_comments("301", "0", page))
    local saved = assert(cache:load_comments("301", "0"))
    eq(saved.next_cursor, "20") eq(saved.items[1].content, "评论")
    local file = assert(io.open(directory .. "/answer-301.json", "rb"))
    local raw = file:read("*a") file:close()
    assert(not raw:find("z_c0", 1, true) and not raw:find("fixture-cookie", 1, true))
end)
