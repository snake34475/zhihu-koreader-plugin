local PublicAnswer = require("zhihu_public_answer")
local JSON = require("json")

test("anonymous answer probe makes one credential-free request", function()
    local requests = {}
    local probe = PublicAnswer.new{ transport = function(request)
        requests[#requests + 1] = request
        return 200, JSON.encode({ id = 301, content = "<p>第一段。</p><p>第二段，补足摘要省略的内容。</p>" })
    end }
    local result = assert(probe:fetch("https://www.zhihu.com/question/100/answer/301?utm_source=test", "第一段…"))
    eq(#requests, 1)
    eq(requests[1].method, "GET")
    eq(requests[1].redirect, false)
    eq(requests[1].headers.Authorization, nil)
    eq(requests[1].headers.Cookie, nil)
    eq(requests[1].url, "https://www.zhihu.com/api/v4/answers/301?include=content,excerpt,paid_info")
    eq(result.content, "第一段。\n\n第二段，补足摘要省略的内容。")
end)

test("invalid answer links never trigger a request", function()
    local probe = PublicAnswer.new{ transport = function() error("unexpected request") end }
    for _, url in ipairs({ "http://www.zhihu.com/question/1/answer/2",
        "https://www.zhihu.com.evil.test/question/1/answer/2",
        "https://www.zhihu.com/question/1/answer/2/extra",
        "https://www.zhihu.com/question/1/answer/2\nCookie: x",
        "https://www.zhihu.com/question/1" }) do
        local result, err = probe:fetch(url, "摘要")
        eq(result, nil) eq(err.kind, "input")
    end
end)

test("verification, login and redirect keep the summary", function()
    for _, case in ipairs({
        {403, '{"error":{"code":40352}}', "verification"},
        {403, '{}', "auth"},
        {302, '<html>login</html>', "redirect"},
        {200, '{"error":{"code":40362}}', "verification"},
    }) do
        local probe = PublicAnswer.new{ transport = function() return case[1], case[2] end }
        local result, err = probe:fetch("https://www.zhihu.com/question/1/answer/2", "摘要")
        eq(result, nil) eq(err.kind, case[3])
    end
end)

test("mismatched, paid and short truncated payloads are never marked as body", function()
    local cases = {
        { { id = 999, content = "<p>错误回答</p>" }, "unreadable" },
        { { id = 2, content = "<p>预览内容</p>", paid_info = { is_paid = true } }, "paid" },
        { { id = 2, content = "<p>摘要…</p>" }, "unreadable" },
        { { id = 2, content = "<p>请点击阅读全文</p>" }, "truncated" },
        { { id = 2, content = "<p>看似完整的内容</p>", content_need_truncated = true }, "truncated" },
        { { id = 2, content = "<p>看似完整的内容</p>", force_login_when_click_read_more = true }, "truncated" },
    }
    for _, case in ipairs(cases) do
        local probe = PublicAnswer.new{ transport = function() return 200, JSON.encode(case[1]) end }
        local result, err = probe:fetch("https://www.zhihu.com/question/1/answer/2", "摘要…")
        eq(result, nil) eq(err.kind, case[2])
    end
end)
