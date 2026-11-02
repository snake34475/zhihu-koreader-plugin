local Config = require("zhihu_config")
local Errors = require("zhihu_errors")
local Schema = require("zhihu_schema")
local JSON = require("json")
local shown, closed, scheduled = {}, {}, {}
local function class()
    local c = {}
    function c:new(value)
        value = value or {}
        return setmetatable(value, { __index = self })
    end
    function c:extend(value)
        value = value or {}
        return setmetatable(value, { __index = self })
    end
    function c:onShowKeyboard() self.keyboard_shown = true end
    function c:getInputText() return self.input end
    function c:onClose()
        closed[#closed + 1] = self
        if self.close_callback then self.close_callback() end
    end
    function c:getSize() return { w = 600, h = 40 } end
    function c:generateVerticalLayout() return {} end
    return c
end
for _, name in ipairs({ "infomessage", "inputdialog", "textviewer", "menu", "buttondialog", "qrmessage",
    "titlebar", "buttontable", "verticalgroup" }) do
    package.loaded["ui/widget/" .. name] = class()
end
package.loaded["ui/widget/container/widgetcontainer"] = class()
local manager = {}
function manager:show(widget) shown[#shown + 1] = widget end
function manager:close(widget) closed[#closed + 1] = widget end
function manager:forceRePaint() end
function manager:scheduleIn(_, callback) scheduled[callback] = true end
function manager:unschedule(callback) scheduled[callback] = nil end
function manager:nextTick(callback) callback() end
package.loaded["ui/uimanager"] = manager
local clipboard, opened
local device = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
    input = { setClipboardText = function(value) clipboard = value end },
    canOpenLink = function() return false end,
    openLink = function(_, url) opened = url end,
}
package.loaded.device = device
local online_calls = 0
package.loaded["ui/network/manager"] = { runWhenConnected = function(_, callback)
    online_calls = online_calls + 1 callback()
end }
local trapper = { mode = "success" }
function trapper:wrap(callback) callback() end
function trapper:dismissableRunInSubprocess(task, widget)
    if self.mode == "cancel" then return false end
    if self.mode == "timeout" then
        widget.dismiss_callback = function() end
        for callback in pairs(scheduled) do callback() end
        return false
    end
    return true, task()
end
package.loaded["ui/trapper"] = trapper
local UI = require("zhihu_ui")
local config = Config.open(test_directory .. "/ui-config.json")
assert(config:set("access_secret", "fixture-ui-secret"))
local calls, saves = 0, 0
local hot_result = assert(Schema.list(JSON.decode(fixture("hot"))))
local cached_entry = { result = hot_result, query = "old query", saved_at = 1000 }
local cache = {
    save = function() saves = saves + 1 return true end,
    load = function() return cached_entry end,
    load_question = function() return nil end,
    save_question = function() return true end,
}
local api = { hot_list = function()
    calls = calls + 1
    return hot_result, nil, JSON.decode(fixture("hot"))
end }
local ui = UI.new(config, api, cache, {})

test("successful UI request caches once, clears busy and watchdog", function()
    local before = saves
    ui:request("hot")
    eq(saves, before + 1)
    eq(ui.busy, false)
    eq(next(scheduled), nil)
    assert(shown[#shown].title:find("知乎热榜", 1, true))
    shown[#shown].item_table[1].hold_callback()
    local actions = shown[#shown]
    eq(actions.buttons[4][1].enabled, true)
    actions.buttons[4][1].callback()
    eq(saves, before + 2)
end)

test("user cancellation never writes cache", function()
    local before = saves
    trapper.mode = "cancel"
    ui:request("hot")
    eq(saves, before)
    eq(ui.busy, false)
    eq(next(scheduled), nil)
    trapper.mode = "success"
end)

test("UI watchdog cancels and falls back to cached hot list", function()
    local before = saves
    trapper.mode = "timeout"
    ui:request("hot")
    eq(saves, before)
    assert(shown[#shown].text:find("请求超时", 1, true))
    assert(shown[#shown].text:find("已打开上次缓存", 1, true))
    eq(ui.busy, false)
    eq(next(scheduled), nil)
    trapper.mode = "success"
end)

test("offline cache display never asks for network", function()
    local before = online_calls
    ui:show_cached("hot")
    eq(online_calls, before)
    assert(shown[#shown].custom_title_bar[1].subtitle:find("缓存", 1, true))
end)

test("different failed query does not silently display unrelated results", function()
    ui:failed("search", "different", Errors.new("network"))
    assert(shown[#shown].text:find("对应其他查询", 1, true))
    ui:failed("search", "old query", Errors.new("network"))
    assert(shown[#shown].text:find("已打开上次缓存", 1, true))
end)

test("busy guard prevents duplicate network operations", function()
    local before = online_calls
    ui.busy = true
    ui:request("hot")
    eq(online_calls, before)
    ui.busy = false
end)

test("settings hide secret and provide a clear action", function()
    ui:settings()
    local menu = shown[#shown]
    local text = JSON.encode((function()
        local rows = {} for _, item in ipairs(menu.item_table) do rows[#rows + 1] = item.text end return rows
    end)())
    assert(not text:find(config:get("access_secret"), 1, true))
    assert(text:find("清除 Access Secret", 1, true))
    menu.item_table[2].callback()
    local dialog = shown[#shown]
    eq(dialog.text_type, "password")
    dialog.buttons[1][1].callback()
    eq(shown[#shown].text_type, nil)
    eq(shown[#shown].input, "fixture-ui-secret")
end)

test("link actions use clipboard, QR fallback and supported browser", function()
    local url = "https://www.zhihu.com/question/100"
    ui:copy_link(url)
    eq(clipboard, url)
    ui:open_link(url)
    eq(shown[#shown].text, url)
    device.canOpenLink = function() return true end
    ui:open_link(url)
    eq(opened, url)
end)

test("plugin registers global menu with tools hint and version", function()
    package.loaded.datastorage = { getDataDir = function() return test_directory end,
        getSettingsDir = function() return test_directory end }
    package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }
    package.loaded.logger = { info = function() end }
    local registered
    local plugin = require("main"):new{ ui = { menu = { registerToMainMenu = function(_, instance)
        registered = instance
    end } } }
    plugin:init()
    eq(registered, plugin)
    local items = {}
    plugin:addToMainMenu(items)
    eq(items.zhihu.text, "知乎")
    eq(items.zhihu.sorting_hint, "tools")
    eq(require("_meta").version, "0.2.0")
    items.zhihu.callback()
    assert(plugin.client)
end)

test("home shows cached headlines and persistent toolbar without a network call", function()
    local before = online_calls
    local client = UI.new(config, api, cache, {})
    client:home()
    local page = shown[#shown]
    eq(#page.item_table, 2)
    eq(page.custom_title_bar[2].buttons[1][2].text, "搜索")
    eq(page.custom_title_bar[2].buttons[2][1].text, "刷新热榜")
    eq(online_calls, before)
    page:onClose()
    eq(client.home_widget, nil)
end)

test("first launch has useful setup and refresh actions without requesting", function()
    local before = online_calls
    local client = UI.new(config, api, {load = function() return nil end}, {})
    client:home()
    assert(shown[#shown].item_table[1].text:find("还没有热榜", 1, true))
    eq(online_calls, before)
end)

test("question navigation follows cursor and previous batch reuses memory", function()
    local offsets = {}
    local question_api = {question_answers = function(_, _, offset)
        offsets[#offsets + 1] = offset
        local raw = JSON.decode(fixture("question_answers"))
        if offset == 17 then raw.Data.Paging = {IsEnd = true} end
        return assert(Schema.question_answers(raw, offset)), nil, raw
    end}
    local client = UI.new(config, question_api, cache, {})
    local context = client:open_question({title = "测试问题", url = "https://www.zhihu.com/question/100"})
    local first = shown[#shown]
    first.custom_title_bar[2].buttons[2][2].callback()
    eq(offsets[2], 17)
    local second = shown[#shown]
    eq(second.custom_title_bar[2].buttons[2][2].enabled, false)
    second.custom_title_bar[2].buttons[2][1].callback()
    eq(#offsets, 2)
    eq(context.index, 1)
    shown[#shown]:onClose()
    eq(context.active, false)
end)

test("answer reader moves to next answer and returns without closing list", function()
    local client = UI.new(config, api, cache, {})
    local raw = JSON.decode(fixture("question_answers"))
    local entry = {offset = 0, result = assert(Schema.question_answers(raw, 0)), raw = raw}
    local context = client:open_question({title = "测试问题", url = "https://www.zhihu.com/question/100"}, entry)
    local list = shown[#shown]
    list.item_table[1].callback()
    local reader = shown[#shown]
    eq(reader.buttons_table[1][1].enabled, false)
    reader.buttons_table[1][3].callback()
    eq(shown[#shown].buttons_table[1][3].enabled, false)
    eq(context.widget, list)
    eq(context.active, true)
    shown[#shown].buttons_table[1][2].callback()
    eq(context.active, true)
end)

test("empty nonfinal answer batch still offers next batch", function()
    local client = UI.new(config, api, cache, {})
    local result = {items = {}, is_end = false, next_offset = 50}
    client:open_question({title = "测试问题", url = "https://www.zhihu.com/question/100"}, {offset = 17, result = result})
    local page = shown[#shown]
    eq(page.custom_title_bar[2].buttons[2][2].enabled, true)
    assert(page.item_table[1].text:find("下一批", 1, true))
end)
