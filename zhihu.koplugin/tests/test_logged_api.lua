local Client = require("zhihu_logged_api")
local JSON = require("json")

local function json(value) return JSON.encode(value) end
local current, requests = nil, {}
local api = Client.new({ clock = function() return 1700000000 end, transport = function(request)
    requests[#requests + 1] = request
    if type(current) == "function" then return current(request) end
    return current.status or 200, current.body or json(current), nil, current.headers
end })
local session = { jar = { z_c0 = "fixture-cookie" } }

test("logged API sends only explicit user initiated request metadata", function()
    current = { id = "301", content = "<p>完整正文内容</p>" }
    local answer = assert(api:fetch_answer("301", session, "短摘要…"))
    eq(answer.content, "完整正文内容")
    assert(requests[#requests].url:find("/api/v4/answers/301", 1, true))
    eq(requests[#requests].headers.Cookie, "z_c0=fixture-cookie")
    eq(requests[#requests].headers["User-Agent"], "Zhihu-KOReader/0.3 (user-initiated reader)")
end)

test("answer validates id, empty body, truncation, and paywall", function()
    local bad = api:fetch_answer("301/evil", session)
    eq(bad, nil)
    current = { id = "301", content = "" }
    local empty, empty_err = api:fetch_answer("301", session)
    eq(empty, nil) eq(empty_err.kind, "invalid_response")
    current = { id = "301", content = "短摘要…", content_need_truncated = true }
    local cut, cut_err = api:fetch_answer("301", session)
    eq(cut, nil) eq(cut_err.kind, "paid_or_truncated")
    current = { id = "301", content = "正文", paid_info = { need_pay = true } }
    local paid, paid_err = api:fetch_answer("301", session)
    eq(paid, nil) eq(paid_err.kind, "paid_or_truncated")
end)

test("comment pages use opaque server cursor and stop at end", function()
    current = { data = { { id = 1, content = "<p>评论一</p>", author = { name = "甲" } } },
        paging = { is_end = false, next = "https://www.zhihu.com/api/v4/comment_v5/answers/301/root_comment?offset=next-token&limit=10" } }
    local first = assert(api:fetch_comments("301", "0", session))
    eq(first.items[1].content, "评论一")
    eq(first.next_cursor, "https://www.zhihu.com/api/v4/comment_v5/answers/301/root_comment?offset=next-token&limit=10")
    eq(first.is_end, false)
    assert(requests[#requests].url:find("offset=", 1, true))
    current = { data = {}, paging = { is_end = true } }
    local last = assert(api:fetch_comments("301", first.next_cursor, session))
    eq(#last.items, 0) eq(last.next_cursor, nil) eq(last.is_end, true)
    assert(requests[#requests].url:find("offset=next-token&limit=10", 1, true))
    local _, bad_cursor = api:fetch_comments("301", "https://example.com/comments", session)
    eq(bad_cursor.kind, "invalid_response")
end)

test("login separates QR scan from account session verification", function()
    local login = Client.new({ clock = function() return 1700000000 end, transport = function(request)
        if request.url:find("/signin", 1, true) then return 200, "signin", nil, { ["set-cookie"] = "_xsrf=token; Path=/" } end
        if request.url:find("/udid", 1, true) then return 200, json({ udid = "fixture-device" }) end
        if request.url:find("/scan_info", 1, true) then return 200, json({ status = 1, cookie = "z_c0=logged; Path=/" }) end
        if request.url:find("/login/qrcode?", 1, true) or request.url:match("/login/qrcode$") then
            return 200, json({ token = "fixture", link = "https://www.zhihu.com/account/qrcode/scan?token=fixture", expires_at = 120 })
        end
        if request.url:find("/api/v4/me", 1, true) then return 200, json({ id = "42", name = "测试用户" }) end
        return 500, "{}"
    end })
    local qr = assert(login:create_qr())
    eq(qr.jar.d_c0, nil)
    local polled = assert(login:poll_login(qr))
    eq(polled.scanned, true) eq(polled.confirmed, false) eq(qr.jar.z_c0, "logged")
    local verified, verify_err = login:verify_session(qr)
    assert(verified, verify_err and verify_err.message)
    eq(verified.user.name, "测试用户")
end)

test("login reports verification challenge and expired QR distinctly", function()
    local challenge = Client.new({ transport = function(request)
        if request.url:find("/signin", 1, true) then return 403, json({ error = { code = 40352 } }) end
    end })
    local qr, challenge_err = challenge:create_qr()
    eq(qr, nil) eq(challenge_err.kind, "verification_required")
    local expired = Client.new({ transport = function() return 200, json({ status = 2 }) end })
    local state, expired_err = expired:poll_login({ token = "fixture", jar = {} })
    eq(state, nil) eq(expired_err.kind, "qr_expired")
end)

test("temporary Cookie import filters, expires, and removes its RAM handoff", function()
    local parsed = assert(Client.cookie_session_from_header(
        "Cookie: z_c0=fixture-session; _xsrf=fixture-xsrf; tracking=discard-me"))
    eq(parsed.jar.z_c0, "fixture-session")
    eq(parsed.jar._xsrf, "fixture-xsrf")
    eq(parsed.jar.tracking, nil)
    local missing, missing_err = Client.cookie_session_from_header("_xsrf=only-xsrf")
    eq(missing, nil) eq(missing_err.kind, "login_required")

    local path = test_directory .. "/temporary-cookie-import"
    write(path, "1700000000\nz_c0=fixture-session; _xsrf=fixture-xsrf\n")
    local imported = assert(api:consume_cookie_import(path, 1700000001))
    eq(imported.jar.z_c0, "fixture-session")
    eq(io.open(path, "rb"), nil)

    write(path, "1700000000\nz_c0=expired-session\n")
    local expired, expired_err = api:consume_cookie_import(path, 1700000700)
    eq(expired, nil) eq(expired_err.kind, "login_required")
    eq(io.open(path, "rb"), nil)
end)

test("temporary Cookie session must pass the account endpoint", function()
    current = function(request)
        assert(request.url:find("/api/v4/me", 1, true))
        eq(request.headers.Cookie, "_xsrf=fixture-xsrf; z_c0=fixture-session")
        return 200, json({ id = "4242", name = "临时会话用户" })
    end
    local imported = assert(Client.cookie_session_from_header("z_c0=fixture-session; _xsrf=fixture-xsrf"))
    local verified = assert(api:verify_session(imported))
    eq(verified.user.name, "临时会话用户")
end)

test("logged API classifies forbidden, rate limit, session loss, and network errors", function()
    current = function() return 403, json({ error = { code = 40352 } }) end
    local _, verification = api:fetch_comments("301", "0", session)
    eq(verification.kind, "verification_required")
    current = function() return 403, json({}) end
    local _, forbidden = api:fetch_comments("301", "0", session)
    eq(forbidden.kind, "forbidden")
    current = function() return 401, "{}" end
    local _, login_required = api:fetch_comments("301", "0", session)
    eq(login_required.kind, "login_required")
    current = function() return nil, nil, "timeout" end
    local _, network = api:fetch_comments("301", "0", session)
    eq(network.kind, "network_error")
end)
