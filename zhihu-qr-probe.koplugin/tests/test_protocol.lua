-- Run with a Lua interpreter after placing the plugin directory on package.path.
package.preload.json = function()
    return { decode = function(body)
        if body == "qr" then
            return { token = "fixturetoken", link = "https://www.zhihu.com/account/scan/login/fixturetoken",
                expires_at = 9999999999999 }
        end
        if body == "risk" then return { error = { code = 40352 } } end
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
local result, err = Protocol.poll(session, request)
assert(result == nil and err:find("40352", 1, true))
local blocked, reason = Protocol.create(function(method, path)
    return 302, "", nil, { location = "https://www.zhihu.com/account/unhuman?session=fixture" }
end)
assert(blocked == nil and reason:find("人机验证", 1, true))
print("QR protocol test passed")
