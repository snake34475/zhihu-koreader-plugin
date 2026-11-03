local Config = require("zhihu_config")
local Errors = require("zhihu_errors")
local Schema = require("zhihu_schema")
local JSON = require("json")
local shown, closed, scheduled, broadcasts = {}, {}, {}, {}
local function class()
    local c = {}
    function c:new(value)
        value = value or {}
        local object = setmetatable(value, { __index = self })
        if object.init then object:init() end
        return object
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
    function c:getHeight() return 40 end
    function c:generateVerticalLayout() return {} end
    function c:setTitle(value) self.title = value end
    function c:setSubTitle(value) self.subtitle = value end
    function c:setLeftIcon(value) self.left_icon = value end
    function c:enable() self.enabled = true end
    function c:disable() self.enabled = false end
    function c:scrollText() end
    function c:updateScrollBar() end
    return c
end
for _, name in ipairs({ "infomessage", "inputdialog", "textviewer", "menu", "buttondialog", "qrmessage",
    "titlebar", "buttontable", "verticalgroup", "horizontalgroup", "button" }) do
    package.loaded["ui/widget/" .. name] = class()
end
package.loaded["ui/widget/container/widgetcontainer"] = class()
package.loaded["ui/widget/container/inputcontainer"] = class()
package.loaded["ui/widget/container/framecontainer"] = class()
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 8, default = 6 }, margin = { small = 4 }, radius = { window = 4 } }
package.loaded["ui/geometry"] = class()
package.loaded["ui/gesturerange"] = class()
package.loaded["ui/bidi"] = { flipDirectionIfMirroredUILayout = function(direction) return direction end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 255 }
package.loaded["ui/event"] = { new = function(_, name) return { name = name } end }
local scroll_class = class()
function scroll_class:new(value)
    value = value or {}
    value.text_widget = value.text_widget or {
        virtual_line_num = value.top_line_num or 1,
        getVisLineCount = function() return 10 end,
        getAllLineCount = function() return 30 end,
        scrollLines = function() end,
    }
    return setmetatable(value, { __index = self })
end
package.loaded["ui/widget/scrolltextwidget"] = scroll_class
package.loaded["zhihu_clock"] = {
    time = function() return "12:34" end,
    start = function(setter) setter("12:34") return function() end end,
}
G_reader_settings = { isTrue = function() return false end }
local manager = {}
function manager:show(widget) shown[#shown + 1] = widget end
function manager:close(widget)
    closed[#closed + 1] = widget
    if widget.onClose then widget:onClose() end
end
function manager:forceRePaint() end
function manager:setDirty() end
function manager:broadcastEvent(event) broadcasts[#broadcasts + 1] = event end
function manager:scheduleIn(_, callback) scheduled[callback] = true end
function manager:unschedule(callback) scheduled[callback] = nil end
function manager:nextTick(callback) callback() end
package.loaded["ui/uimanager"] = manager
local clipboard, opened
local device = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
        scaleBySize = function(_, value) return value end },
    input = { setClipboardText = function(value) clipboard = value end },
    canOpenLink = function() return false end,
    isTouchDevice = function() return true end,
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
package.loaded.logger = { info = function() end, dbg = function() end }
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
    ui:failed("question", "different", Errors.new("network"))
    assert(shown[#shown].text:find("对应其他查询", 1, true))
    ui:failed("question", "old query", Errors.new("network"))
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
    local secret_row
    for _, row in ipairs(menu.item_table) do if row.text:find("Access Secret：", 1, true) then secret_row = row break end end
    assert(secret_row)
    secret_row.callback()
    local dialog = shown[#shown]
    eq(dialog.text_type, "password")
    dialog.buttons[1][1].callback()
    eq(shown[#shown].text_type, nil)
    eq(shown[#shown].input, "fixture-ui-secret")
end)

test("settings toggle night mode through KOReader", function()
    local before = #broadcasts
    local client = UI.new(config, api, cache, {})
    client:settings()
    local night
    for _, item in ipairs(shown[#shown].item_table) do
        if item.text:find("夜间模式", 1, true) then night = item end
    end
    assert(night)
    night.callback()
    eq(#broadcasts, before + 1)
    eq(broadcasts[#broadcasts].name, "ToggleNightMode")
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
    eq(require("_meta").version, "0.2.3")
    items.zhihu.callback()
    assert(plugin.client)
end)

test("home shows cached headlines and persistent toolbar without a network call", function()
    local before = online_calls
    local client = UI.new(config, api, cache, {})
    client:home()
    local page = shown[#shown]
    eq(#page.item_table, 2)
    eq(page.custom_title_bar[2].buttons[1][2].text, "直答")
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
    eq(context.active, true)
    eq(second.custom_title_bar[2].buttons[2][2].enabled, false)
    second.custom_title_bar[2].buttons[2][1].callback()
    eq(#offsets, 2)
    eq(context.index, 1)
    eq(context.active, true)
    shown[#shown]:onClose()
    eq(context.active, false)
end)

local function open_reader()
    local client = UI.new(config, api, cache, {})
    local raw = JSON.decode(fixture("question_answers"))
    local entry = {offset = 0, result = assert(Schema.question_answers(raw, 0)), raw = raw}
    local context = client:open_question({title = "测试问题", url = "https://www.zhihu.com/question/100"}, entry)
    local list = shown[#shown]
    client:read_answer(context, entry, 1)
    return client, context, list, shown[#shown]
end

test("tapping an answer summary requests its body directly", function()
    local client = UI.new(config, api, cache, {})
    local raw = JSON.decode(fixture("question_answers"))
    local entry = { offset = 0, result = assert(Schema.question_answers(raw, 0)), raw = raw }
    local context = client:open_question({ title = "测试问题", url = "https://www.zhihu.com/question/100" }, entry)
    local requested
    client.fetch_logged_answer = function(_, answer) requested = answer end
    context.widget.item_table[1].callback()
    eq(requested.url, "https://www.zhihu.com/question/100/answer/301")
end)

test("long press on an answer exposes logged body and comment actions", function()
    local client = UI.new(config, api, cache, {})
    local raw = JSON.decode(fixture("question_answers"))
    local entry = { offset = 0, result = assert(Schema.question_answers(raw, 0)), raw = raw }
    client:open_question({ title = "测试问题", url = "https://www.zhihu.com/question/100" }, entry)
    shown[#shown].item_table[1].hold_callback()
    local actions = shown[#shown]
    eq(actions.buttons[1][1].text, "获取正文")
    eq(actions.buttons[2][1].text, "查看评论")
end)

test("answer reader shows time and omits source footer", function()
    local _, context, list, reader = open_reader()
    assert(reader.text:find("先从简短的内容开始阅读", 1, true))
    assert(not reader.text:find("来源：", 1, true))
    assert(not reader.text:find("以上为开放平台返回的摘要", 1, true))
    assert(reader.titlebar.subtitle:find("12:34", 1, true))
    eq(reader.buttons.prev.enabled, false)
    eq(reader.buttons.next.enabled, true)
    eq(reader.buttons.flip.text, "反转")
    eq(context.widget, list)
    eq(context.active, true)
end)

test("side buttons switch answers and keep the list open", function()
    local _, context, list, reader = open_reader()
    reader.buttons.next.callback()
    local second = shown[#shown]
    eq(second.buttons.prev.enabled, true)
    eq(second.buttons.next.enabled, false)
    eq(context.widget, list)
    eq(context.active, true)
end)

test("horizontal swipe switches answers", function()
    local _, _, _, reader = open_reader()
    reader:onSwipe(nil, { direction = "west" })
    local second = shown[#shown]
    eq(second.title, "回答摘要 2 / 2")
    second:onSwipe(nil, { direction = "east" })
    eq(shown[#shown].title, "回答摘要 1 / 2")
end)

test("reader flips button column and persists the side", function()
    local _, _, _, reader = open_reader()
    reader.buttons.flip.callback()
    eq(reader.side, "right")
    eq(config:get("reader_side"), "right")
    reader.buttons.flip.callback()
    eq(reader.side, "left")
    eq(config:get("reader_side"), "left")
end)

test("list pages show the current time", function()
    local client = UI.new(config, api, cache, {})
    client:home()
    assert(shown[#shown].custom_title_bar[1].subtitle:find("12:34", 1, true))
    shown[#shown]:onClose()
end)

test("empty nonfinal answer batch still offers next batch", function()
    local client = UI.new(config, api, cache, {})
    local result = {items = {}, is_end = false, next_offset = 50}
    client:open_question({title = "测试问题", url = "https://www.zhihu.com/question/100"}, {offset = 17, result = result})
    local page = shown[#shown]
    eq(page.custom_title_bar[2].buttons[2][2].enabled, true)
    assert(page.item_table[1].text:find("下一批", 1, true))
end)

test("answer body is fetched only on tap and leaves the summary available", function()
    local client = UI.new(config, api, cache, {})
    local attempts, before_saves = 0, saves
    local item = { kind = "answer", title = "测试回答", author = "", time = "", summary = "摘要…",
        url = "https://www.zhihu.com/question/100/answer/301" }
    client.public_answer = { fetch = function(_, url, summary)
        attempts = attempts + 1
        eq(url, item.url) eq(summary, item.summary)
        return { content = "经核对的回答正文", url = url }
    end }
    assert(config:set("access_secret", ""))
    client:detail(item)
    local summary = shown[#shown]
    eq(attempts, 0)
    summary.buttons_table[1][5].callback()
    eq(attempts, 1)
    eq(saves, before_saves)
    assert(shown[#shown].text:find("经核对的回答正文", 1, true))
    shown[#shown].buttons_table[1][1].callback()
    eq(closed[#closed], shown[#shown])
    assert(config:set("access_secret", "fixture-ui-secret"))
end)

test("blocked answer probe preserves summary and reports the reason", function()
    local client = UI.new(config, api, cache, {})
    local item = { kind = "answer", title = "测试回答", author = "", time = "", summary = "摘要…",
        url = "https://www.zhihu.com/question/100/answer/301" }
    client.public_answer = { fetch = function()
        return nil, { kind = "verification", message = "知乎要求人机验证，摘要仍可阅读。" }
    end }
    client:detail(item)
    local summary = shown[#shown]
    summary.buttons_table[1][5].callback()
    assert(shown[#shown].text:find("人机验证", 1, true))
    eq(closed[#closed] == summary, false)
end)

test("logged answer uses local cache and prefetches only the next answer", function()
    local stored, fetched = {}, {}
    local logged_api = { fetch_answer = function(_, id)
        fetched[#fetched + 1] = id
        return { answer_id = id, content = "正文 " .. id, fetched_at = 1700000000 }
    end }
    local logged_cache = {
        load_answer = function(_, id) return stored[id] end,
        save_answer = function(_, answer) stored[answer.answer_id] = answer return true end,
    }
    local client = UI.new(config, api, cache, {}, logged_api, logged_cache)
    client.zhihu_session = { jar = { z_c0 = "fixture" } }
    local first = { title = "第一条", summary = "摘要一", url = "https://www.zhihu.com/question/100/answer/301" }
    local second = { title = "第二条", summary = "摘要二", url = "https://www.zhihu.com/question/100/answer/302" }
    local navigation = { items = { first, second }, index = 1, title = "测试问题" }
    client:fetch_logged_answer(first, navigation)
    eq(#fetched, 2)
    eq(fetched[1], "301") eq(fetched[2], "302")
    assert(stored["301"] and stored["302"])
    local reader
    for i = #shown, 1, -1 do
        if shown[i].actions_table then reader = shown[i] break end
    end
    assert(reader)
    eq(reader.text, "正文 301")
    eq(reader.actions[1][1].text, "查看评论")
    reader:onSwipe(nil, { direction = "west" })
    eq(shown[#shown].text, "正文 302")

    local offline = UI.new(config, api, cache, {}, logged_api, logged_cache)
    local before = #fetched
    offline:fetch_logged_answer(second, { items = { first, second }, index = 2 })
    eq(#fetched, before)
end)

test("comment pages load from cache before requesting the network", function()
    local network_calls = 0
    local cached = { items = { { author = "本地作者", content = "缓存评论" } },
        is_end = true, fetched_at = 1700000000, range = "本页 1 条" }
    local logged_api = { fetch_comments = function() network_calls = network_calls + 1 end }
    local logged_cache = {
        load_comments = function(_, id, cursor)
            eq(id, "301") eq(cursor, "0")
            return cached
        end,
    }
    local client = UI.new(config, api, cache, {}, logged_api, logged_cache)
    client:fetch_comments({ title = "测试回答", url = "https://www.zhihu.com/question/100/answer/301" }, "0")
    eq(network_calls, 0)
    assert(shown[#shown].item_table[1].text:find("缓存评论", 1, true))
    assert(shown[#shown].custom_title_bar[1].subtitle:find("缓存", 1, true))
end)

test("QR login keeps scanned state separate from verified session and logout clears memory", function()
    local polls, verified = 0, 0
    local logged_api = {
        create_qr = function() return { link = "https://www.zhihu.com/account/scan/login/test", token = "test", expires_at = os.time() * 1000 + 60000, jar = {} } end,
        poll_login = function()
            polls = polls + 1
            if polls == 1 then return { scanned = true, confirmed = false, jar = { d_c0 = "device" } } end
            return { scanned = true, confirmed = true, jar = { z_c0 = "session" } }
        end,
        verify_session = function(_, session)
            verified = verified + 1
            eq(session.jar.z_c0, "session")
            return { jar = session.jar, user = { name = "fixture" } }
        end,
    }
    local client = UI.new(config, api, cache, {}, logged_api)
    client:start_login()
    assert(client.login_flow and client.login_flow.widget)
    local tick
    for callback in pairs(scheduled) do tick = callback end
    assert(tick)
    scheduled[tick] = nil
    tick()
    eq(polls, 1) eq(verified, 0) eq(client.zhihu_session, nil)
    for callback in pairs(scheduled) do if callback ~= tick then tick = callback end end
    scheduled[tick] = nil
    tick()
    eq(polls, 2) eq(verified, 1)
    eq(client.zhihu_session.user.name, "fixture")
    eq(client.login_flow, nil)
    client:settings()
    local logout
    for _, row in ipairs(shown[#shown].item_table) do if row.text == "退出知乎登录" then logout = row break end end
    assert(logout)
    logout.callback()
    eq(client.zhihu_session, nil)
end)

test("temporary browser session is consumed, verified, and kept only in UI memory", function()
    local imported = { jar = { z_c0 = "temporary" } }
    local logged_api = {
        consume_cookie_import = function()
            return imported
        end,
        verify_session = function(_, session)
            eq(session, imported)
            return { jar = session.jar, user = { name = "browser fixture" } }
        end,
    }
    local client = UI.new(config, api, cache, {}, logged_api)
    client:import_cookie_session()
    eq(client.zhihu_session.user.name, "browser fixture")
    eq(client.zhihu_session.jar.z_c0, "temporary")
    local widget = {}
    client.home_widget = widget
    client:on_home_close(widget)
    eq(client.zhihu_session, nil)
end)

test("comments pages show timestamp and follow opaque server cursor", function()
    local cursors = {}
    local logged_api = { fetch_comments = function(_, id, cursor)
        eq(id, "301")
        cursors[#cursors + 1] = cursor
        return { items = cursor == "0" and { { author = "甲", content = "评论一" } } or {},
            next_cursor = cursor == "0" and "https://www.zhihu.com/api/v4/comment_v5/answers/301/root_comment?offset=next" or nil,
            is_end = cursor ~= "0", fetched_at = 1700000000, range = cursor == "0" and "本页 1 条" or "本页 0 条" }
    end }
    local client = UI.new(config, api, cache, {}, logged_api)
    client.zhihu_session = { jar = { z_c0 = "fixture" } }
    local item = { kind = "answer", title = "测试回答", url = "https://www.zhihu.com/question/100/answer/301" }
    client:fetch_comments(item, "0")
    local first = shown[#shown]
    eq(first.item_table[1].text:find("评论一", 1, true) ~= nil, true)
    assert(first.custom_title_bar[1].subtitle:find("取得于", 1, true))
    first.custom_title_bar[2].buttons[1][3].callback()
    eq(cursors[2], "https://www.zhihu.com/api/v4/comment_v5/answers/301/root_comment?offset=next")
    assert(shown[#shown].item_table[1].text:find("本页没有评论", 1, true))
    eq(shown[#shown].custom_title_bar[2].buttons[1][3].enabled, false)
end)

test("cancelling QR initialization clears the pending login flow", function()
    local logged_api = { create_qr = function() return { link = "https://www.zhihu.com/account/qrcode/scan?token=test", token = "test" } end }
    local client = UI.new(config, api, cache, {}, logged_api)
    trapper.mode = "cancel"
    client:start_login()
    eq(client.login_flow, nil)
    eq(client.busy, false)
    eq(next(scheduled), nil)
    trapper.mode = "success"
end)

test("leaving the plugin home clears its session while refreshing home preserves it", function()
    local client = UI.new(config, api, cache, {})
    client.zhihu_session = { jar = { z_c0 = "fixture" }, user = { name = "fixture" } }
    client:home()
    client:request("hot")
    assert(client.zhihu_session)
    manager:close(client.home_widget)
    eq(client.zhihu_session, nil)
end)
