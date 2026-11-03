-- Run with a Lua interpreter after placing the plugin directory on package.path.
package.preload.json = function()
    return { decode = function(body)
        if body == "qr" then
            return { token = "fixturetoken", link = "https://www.zhihu.com/account/qrcode/scan?token=fixturetoken",
                expires_at = 9999999999999 }
        end
        if body == '{"token":"fixturetoken","link":"https://www.zhihu.com/account/qrcode/scan?token=fixturetoken&source=fixture","expires_at":9999999999999}' then
            return { token = "fixturetoken", link = "https://www.zhihu.com/account/qrcode/scan?token=fixturetoken&source=fixture",
                expires_at = 9999999999999 }
        end
        if body == "risk" then return { error = { code = 40352 } } end
        if body == '{"id":"1","name":"fixture"}' then return { id = "1", name = "fixture" } end
        if body == '{"status":1}' then return { status = 1 } end
        if body == '{"status":2}' then return { status = 2 } end
        return {}
    end }
end

local Protocol = require("protocol")
local calls = {}
local function request(method, path, jar)
    calls[#calls + 1] = method .. " " .. path
    if path == "/signin" then jar._xsrf = "fixture-xsrf" return 200, "" end
    if path == "/udid" then jar.d_c0 = "fixture-device" return 200, "{}" end
    if path:find("/scan_info", 1, true) then return 403, "risk" end
    return 200, "qr"
end

local session = assert(Protocol.create(request))
assert(#calls == 3 and calls[2] == "POST /udid")
assert(session.http.login_page == 200 and session.http.device_init == 200 and session.http.qr_create == 200)
local result, err = Protocol.poll(session, request)
assert(result == nil and err.kind == "verification_required" and err.stage == "scan_poll" and err.status == 403)
local blocked, reason = Protocol.create(function(method, path)
    return 302, "", nil, { location = "https://www.zhihu.com/account/unhuman?session=fixture" }
end)
assert(blocked == nil and reason.kind == "verification_required")

local scanned, scan_err = Protocol.poll({ token = "fixturetoken", jar = {} }, function()
    return 200, '{"status":1}'
end)
assert(scanned and scanned.status == 1 and scanned.http_status == 200 and not scanned.confirmed and not scan_err)
local expired, expired_err = Protocol.poll({ token = "fixturetoken", jar = {} }, function()
    return 200, '{"status":2}'
end)
assert(expired == nil and expired_err.kind == "qr_expired" and expired_err.stage == "scan_poll")

local unverified, unverified_err = Protocol.verify_session({ token = "fixturetoken", jar = {} }, function()
    return 200, '{}'
end)
assert(unverified == nil and unverified_err.kind == "login_required" and unverified_err.stage == "session_verify")
local verified = Protocol.verify_session({ token = "fixturetoken", jar = { z_c0 = "fixture" } }, function()
    return 200, '{"id":"1","name":"fixture"}'
end)
assert(verified and verified.user.name == "fixture")
local link_with_query = Protocol.create(function(method, path, jar)
    if path == "/signin" then return 200, "" end
    if path == "/udid" then jar.d_c0 = "fixture" return 200, "{}" end
    return 200, '{"token":"fixturetoken","link":"https://www.zhihu.com/account/qrcode/scan?token=fixturetoken&source=fixture","expires_at":9999999999999}'
end)
assert(link_with_query and link_with_query.link:find("source=fixture", 1, true))
print("QR protocol test passed")
