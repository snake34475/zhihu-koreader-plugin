-- Run in a separate process from KOReader's directory with the plugin path as arg[1].
-- No QR is shown, no account is accessed, and no token/cookie is printed or saved.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local root = assert(arg[1])
package.path = root .. "/?.lua;" .. package.path
local Protocol = require("protocol")

local session, err = Protocol.create()
if not session then
    print("QR_CREATE_FAILED: " .. tostring(err))
    return
end
print("QR_CREATE_OK: official link, token and expiry received")
local result, poll_error = Protocol.poll(session)
if not result then
    print("QR_POLL_FAILED: " .. tostring(poll_error))
    return
end
print("QR_POLL_OK: unauthenticated status received")
