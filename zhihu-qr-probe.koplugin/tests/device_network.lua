-- Run in a separate process from KOReader's directory with the plugin path as arg[1].
-- No QR is shown, no account is accessed, and no token/cookie is printed or saved.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local root = assert(arg[1])
package.path = root .. "/?.lua;" .. package.path
local Protocol = require("protocol")

local function safe_error(prefix, err)
    local kind = type(err) == "table" and tostring(err.kind or "unknown") or "unknown"
    local status = type(err) == "table" and tonumber(err.status) or nil
    local stage = type(err) == "table" and tostring(err.stage or "unknown") or "unknown"
    print(prefix .. " stage=" .. stage .. " kind=" .. kind .. " status=" .. (status and tostring(status) or "none"))
    if type(err) == "table" and err.diagnostic then print("SAFE_RESPONSE_SHAPE: " .. err.diagnostic) end
end

local session, err = Protocol.create()
if not session then
    safe_error("QR_CREATE_FAILED", err)
    return
end
print("QR_CREATE_OK: signin_http=" .. tostring(session.http.login_page)
    .. " udid_http=" .. tostring(session.http.device_init)
    .. " qr_http=" .. tostring(session.http.qr_create))
local result, poll_error = Protocol.poll(session)
if not result then
    safe_error("QR_POLL_FAILED", poll_error)
    return
end
print("QR_POLL_OK: status=" .. tostring(result.status)
    .. " http=" .. tostring(result.http_status)
    .. " scanned=" .. tostring(result.status == 1)
    .. " confirmed=" .. tostring(result.confirmed == true))
