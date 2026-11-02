-- Run from KOReader's directory in a separate process. Uses fictional fixtures,
-- in-memory settings and an offscreen buffer; never reads the user's API secret.
require("setupkoenv")
plugin_root = assert(arg[1])
package.path = plugin_root .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local JSON = require("json")
local Schema = require("zhihu_schema")
local UI = require("zhihu_ui")
local Config = require("zhihu_config")
local BB = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
for file in lfs.dir(plugin_root) do
    if file:match("%.lua$") then assert(loadfile(plugin_root .. "/" .. file)) end
end
local function fixture(name)
    local file = assert(io.open(plugin_root .. "/tests/fixtures/" .. name .. ".json", "rb"))
    local raw = JSON.decode(file:read("*a"))
    file:close()
    return raw
end
local shown
UIManager.show = function(_, widget) shown = widget end
UIManager.close = function() end
local raw = fixture("hot")
local cache = { load = function() return {result = assert(Schema.list(raw)), raw = raw, saved_at = 1000} end }
local config = Config.open(plugin_root .. "/tests/absent-config.json")
local client = UI.new(config, {}, cache, {})
local function render(name)
    local buffer = BB.new(Device.screen:getWidth(), Device.screen:getHeight(), BB.TYPE_BB8)
    buffer:fill(BB.COLOR_WHITE)
    shown:paintTo(buffer, 0, 0)
    buffer:writePNG(plugin_root .. "/../" .. name .. ".png")
    buffer:free()
end
client:home()
assert(client.home_widget and #client.home_widget.item_table == 2)
render("home-preview")
local question_raw = fixture("question_answers")
local entry = {offset = 0, result = assert(Schema.question_answers(question_raw, 0)), raw = question_raw}
local context = client:open_question({title = "如何在墨水屏上阅读长文？", url = "https://www.zhihu.com/question/100"}, entry)
render("answers-preview")
client:read_answer(context, entry, 1)
render("reader-preview")
print("DEVICE_SMOKE_OK: native JSON, widgets, toolbar, answer reader and 3 offscreen PNGs")
