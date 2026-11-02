local Schema = require("zhihu_schema")
local Renderer = require("zhihu_renderer")
local JSON = require("json")

test("official hot fields and inferred content types", function()
    local result = assert(Schema.list(JSON.decode(fixture("hot"))))
    eq(#result.items, 2)
    eq(result.items[1].kind, "question")
    eq(result.items[2].kind, "article")
    eq(result.items[2].summary, "")
end)

test("search ContentText, AuthorName, EditTime and traced URL", function()
    local result = assert(Schema.list(JSON.decode(fixture("search"))))
    local item = result.items[1]
    eq(item.author, "示例作者")
    eq(item.kind, "answer")
    eq(item.time, "1700000000")
    assert(item.summary:find("保留原始来源。", 1, true))
    assert(item.url:find("?utm_source=fixture", 1, true))
end)

test("list normalization accepts lowercase aliases and enforces cap", function()
    local result = assert(Schema.list({ data = { items = {
        { title = "first", url = "https://www.zhihu.com/question/1", author = { name = "author" } },
        { title = "second" },
    } } }, 1))
    eq(#result.items, 1)
    eq(result.items[1].author, "author")
end)

test("empty result is distinct from malformed response", function()
    eq(#assert(Schema.list(JSON.decode(fixture("empty")))).items, 0)
    for _, payload in ipairs({ {}, { Data = {} }, { Data = { Items = "invalid" } },
        { Data = { Items = { unexpected = "object" } } }, { Data = { Items = { false, 1, {} } } } }) do
        eq(Schema.list(payload), nil)
    end
end)

test("safe URLs reject active schemes and embedded credentials", function()
    for _, value in ipairs({ "javascript:alert(1)", "file:///etc/passwd", "https://a@b/path", "https://a/\nfoo" }) do
        eq(Schema.safe_url(value), "")
    end
    eq(Schema.safe_url("https://www.zhihu.com/question/1"), "https://www.zhihu.com/question/1")
end)

test("HTML scripts stripped, entities decoded and paragraphs retained", function()
    local text = Renderer.text('<p>中文 &amp; &#x4E2D;&#25991;</p><SCRIPT>bad()</SCRIPT><p>第二段<br>换行</p>')
    eq(text, "中文 & 中文\n\n第二段\n换行")
end)

test("UTF-8 preview does not split Chinese characters", function()
    eq(Renderer.preview("中文阅读测试", 3), "中文阅…")
    eq(Renderer.preview("短文", 3), "短文")
end)

test("chat content normalized without reasoning text", function()
    local answer = assert(Schema.answer(JSON.decode(fixture("answer"))))
    assert(answer.answer:find("阅读建议", 1, true))
    assert(not answer.answer:find("此字段不展示", 1, true))
    eq(Schema.answer({ choices = { { message = { reasoning_content = "only reasoning" } } } }), nil)
    eq(Schema.answer({ choices = { { message = { content = "answer" }, finish_reason = "error" } } }), nil)
end)

test("truncated chat is marked", function()
    eq(assert(Schema.answer({ choices = { { message = { content = "partial" }, finish_reason = "length" } } })).truncated, true)
end)

test("detail explicitly distinguishes summary from full text", function()
    local item = assert(Schema.list(JSON.decode(fixture("hot")))).items[2]
    local detail = Renderer.detail(item)
    assert(detail:find("接口未提供摘要", 1, true))
    assert(detail:find("不代表原文全文", 1, true))
end)
