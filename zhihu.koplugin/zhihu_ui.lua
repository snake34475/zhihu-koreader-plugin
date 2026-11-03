local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local Config = require("zhihu_config")
local Errors = require("zhihu_errors")
local Renderer = require("zhihu_renderer")
local Schema = require("zhihu_schema")
local Page = require("zhihu_page")
local Reader = require("zhihu_reader")
local PublicAnswer = require("zhihu_public_answer")
local LoggedAPI = require("zhihu_logged_api")
local UI = {}
UI.__index = UI
local titles = { hot = "知乎热榜", recommend = "知乎推荐", answer = "知乎直答" }
local types = { question = "问题", answer = "回答", article = "文章", content = "内容" }

local function night_mode_enabled()
    local settings = rawget(_G, "G_reader_settings")
    return settings ~= nil and settings:isTrue("night_mode") or false
end

function UI.new(config, api, cache, reader_ui, logged_api, logged_cache)
    return setmetatable({ config = config, api = api, cache = cache, reader_ui = reader_ui,
        public_answer = PublicAnswer.new(), logged_api = logged_api or LoggedAPI.new(),
        logged_cache = logged_cache, zhihu_session = nil }, UI)
end

function UI.message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function cache_stamp(epoch)
    local ok, value = pcall(os.date, "%Y-%m-%d %H:%M", epoch or 0)
    return ok and value or "未知时间"
end

function UI:menu(title, items, options)
    options = options or {}
    local properties = {
        title = title, item_table = items, width = Device.screen:getWidth(),
        height = Device.screen:getHeight(), is_popout = false, is_borderless = true,
        items_per_page = 5, items_max_lines = 4,
    }
    for key, value in pairs(options) do properties[key] = value end
    local menu = properties.buttons and Page.new(properties) or Menu:new(properties)
    -- Keep the list below detail/settings dialogs, preserving its current page.
    menu.onMenuSelect = function(_, item)
        if item.callback then item.callback() end
        return true
    end
    menu.onMenuHold = function(_, item)
        if item.hold_callback then item.hold_callback() end
        return true
    end
    UIManager:show(menu)
    return menu
end

function UI:home_buttons(owner, active_kind)
    return {
        {
            { text = "热榜", callback = function()
                local page = owner and owner()
                if page and page ~= self.home_widget then UIManager:close(page) end
                self:home()
            end },
            { text = "推荐", callback = function() self:request("recommend") end },
            { text = "直答", callback = function() self:prompt("answer") end },
        },
        {
            { text = active_kind == "recommend" and "刷新推荐" or "刷新热榜",
                callback = function() self:request(active_kind == "recommend" and "recommend" or "hot") end },
            { text = "离线", callback = function() self:offline_menu() end },
            { text = "设置", callback = function() self:settings() end },
        },
    }
end

function UI:on_home_close(menu)
    if self.home_widget ~= menu then return end
    self.home_widget = nil
    if self.replacing_home == menu then return end
    self.zhihu_session = nil
    self:stop_login_flow()
end

function UI:home()
    if self.home_widget then return end
    local entry = self.cache:load_feed("hot")
    if entry then self:show_feed("hot", entry.result, "缓存于 " .. cache_stamp(entry.saved_at), nil, true) return end
    local legacy = self.cache:load("hot")
    if legacy then self:show_entry("hot", legacy, "旧接口缓存") return end
    local menu
    menu = self:menu("知乎热榜", {
        { text = "还没有热榜内容\n点击“刷新热榜”获取；网页端列表需要先导入知乎浏览器会话。",
            callback = function() self:request("hot") end },
        { text = "Access Secret 只供知乎直答使用\n列表读取使用网页登录会话；断网时可阅读已缓存内容。",
            callback = function() self:settings() end },
    }, { buttons = self:home_buttons(function() return menu end), subtitle = "打开即读缓存 · 手动刷新联网",
        close_callback = function() self:on_home_close(menu) end })
    self.home_widget = menu
end

function UI:offline_menu()
    local items = {
        { text = "旧版开放平台热榜缓存", callback = function() self:show_cached("hot") end },
        { text = "最近网页热榜", callback = function() self:show_cached_feed("hot") end },
        { text = "最近推荐", callback = function() self:show_cached_feed("recommend") end },
        { text = "最近直答", callback = function() self:show_cached("answer") end },
        { text = "最近问题的回答摘要", callback = function()
            local entry = self.cache:recent_web_question() or self.cache:recent_question()
            if not entry then UI.message("暂无问题回答缓存。") return end
            self:open_question({ title = entry.title, url = entry.url }, entry)
        end },
    }
    return self:menu("离线阅读", items)
end

function UI:menu_items()
    return {
        { text = "刷新热榜（最多 30 条）", callback = function() self:request("hot") end },
        { text = "知乎推荐", callback = function() self:request("recommend") end },
        { text = "知乎直答", callback = function() self:prompt("answer") end },
        { text = "离线缓存", sub_item_table = {
            { text = "最近网页热榜", callback = function() self:show_cached_feed("hot") end },
            { text = "最近推荐", callback = function() self:show_cached_feed("recommend") end },
            { text = "旧版开放平台热榜", callback = function() self:show_cached("hot") end },
            { text = "最近直答", callback = function() self:show_cached("answer") end },
        } },
        { text = "设置", callback = function() self:settings() end },
        { text = "关于 · 0.2.4", callback = function()
            UI.message("知乎 0.2.4\n热榜、推荐、问题回答、直答与离线阅读。\n回答正文支持左右滑动切换，评论可分页查看。")
        end },
    }
end

function UI:input(title, value, callback, password, visible)
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = { {
        { text = "取消", id = "close", callback = close },
        { text = "确定", is_enter_default = true, callback = function()
            local accepted, err = callback(dialog:getInputText())
            if accepted then close() elseif err then UI.message(err) end
        end },
    } }
    if password then
        table.insert(buttons, 1, { {
            text = visible and "隐藏 Access Secret" or "显示 Access Secret",
            callback = function()
                local current = dialog:getInputText()
                close()
                self:input(title, current, callback, true, not visible)
            end,
        } })
    end
    dialog = InputDialog:new{
        title = title, input = value or "", text_type = password and not visible and "password" or nil,
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function UI:prompt(kind)
    self:input("知乎直答：请输入问题", "", function(value)
        local query = value:match("^%s*(.-)%s*$")
        if query == "" then return nil, "请输入非空的关键词或问题。" end
        UIManager:nextTick(function() self:request(kind, query) end)
        return true
    end)
end

function UI:run_request(label, task, success, failure, require_secret, cancelled)
    if self.busy then UI.message("已有请求进行中，请等待或取消。") return end
    if require_secret ~= false and self.config:get("access_secret") == "" then
        UI.message(Errors.new("config").message) return
    end
    NetworkMgr:runWhenConnected(function()
        if self.busy then return end
        self.busy = true
        Trapper:wrap(function()
            local loading = InfoMessage:new{ text = "正在加载" .. label .. "…\n轻触可取消" }
            local expired = false
            local watchdog = function()
                expired = true
                if loading.dismiss_callback then loading.dismiss_callback() end
            end
            UIManager:show(loading)
            UIManager:forceRePaint()
            UIManager:scheduleIn(self.config:get("timeout"), watchdog)
            -- Catch errors here so Trapper never logs an exception containing credentials.
            local ok, completed, result, err, raw = pcall(function()
                return Trapper:dismissableRunInSubprocess(function()
                    local ran, data, failure, response = pcall(task)
                    if not ran then return nil, Errors.new("internal") end
                    return data, failure, response
                end, loading)
            end)
            UIManager:unschedule(watchdog)
            UIManager:close(loading)
            self.busy = false
            if expired then failure(Errors.new("timeout")) return end
            if not ok then failure(Errors.new("internal")) return end
            if not completed then
                if cancelled then cancelled() end
                return -- User cancellation never writes a cache.
            end
            if not result then failure(err or Errors.new("network")) return end
            success(result, raw)
        end)
    end)
end

function UI:request(kind, query)
    if kind == "hot" or kind == "recommend" then return self:request_feed(kind) end
    self:run_request(titles[kind], function()
        return self.api:ask(query)
    end, function(result, raw)
        local saved = self.cache:save(kind, query, raw)
        self:show_result(kind, result, query, nil, raw)
        if not saved then UI.message("结果已获取，但缓存写入失败，请检查剩余空间。") end
    end, function(err) self:failed(kind, query, err) end)
end

function UI:request_feed(kind, cursor, context, index, force)
    context = context or { kind = kind, pages = {}, cursors = {}, index = 1 }
    index = index or context.index or 1
    local cached = not force and context.pages[index]
    if force and index == 1 then
        context.pages, context.cursors = {}, {}
    end
    if cached then return self:show_feed(kind, cached, nil, context, false) end
    local session = self.zhihu_session
    self:run_request(kind == "hot" and "知乎热榜" or "知乎推荐", function()
        return self.logged_api:fetch_feed(kind, cursor, session, self.config:get("hot_limit"))
    end, function(result)
        result.kind = kind
        context.pages[index] = result
        context.cursors[index] = cursor
        context.index = index
        if result.next_cursor then context.cursors[index + 1] = result.next_cursor end
        local saved = index == 1 and self.cache:save_feed(kind, result)
        self:show_feed(kind, result, nil, context, false)
        if index == 1 and not saved then UI.message("列表已获取，但离线缓存写入失败。") end
    end, function(err)
        if err.kind == "login_required" then self.zhihu_session = nil end
        local saved = self.cache:load_feed(kind)
        if index == 1 and saved then
            self:show_feed(kind, saved.result, "缓存于 " .. cache_stamp(saved.saved_at), context, true)
            UI.message((err.message or "列表读取失败。") .. "\n已打开最近一次网页列表缓存。")
        else
            UI.message((err.message or "列表读取失败。") .. "\n网页列表需要有效的知乎会话；摘要缓存仍可从离线菜单打开。")
        end
    end, false, function()
        -- Canceled requests do not alter the feed cache or page cursor.
    end)
end

function UI:failed(kind, query, err)
    if kind == "hot" or kind == "recommend" then
        local entry = self.cache:load_feed(kind)
        if entry then
            self:show_feed(kind, entry.result, "缓存于 " .. cache_stamp(entry.saved_at), nil, true)
            UI.message(err.message .. "\n已打开上次网页列表缓存。")
        else
            UI.message(err.message .. "\n暂无网页列表缓存。")
        end
        return
    end
    local entry = self.cache:load(kind)
    if entry and (kind == "hot" or entry.query == (query or "")) then
        self:show_entry(kind, entry)
        UI.message(err.message .. "\n已打开上次缓存。")
    else
        UI.message(err.message .. (entry and "\n最近缓存对应其他查询，可从“离线缓存”打开。" or "\n暂无可用缓存。"))
    end
end

function UI:show_cached(kind)
    local entry, err = self.cache:load(kind)
    if not entry then
        UI.message(err == "missing" and "暂无缓存，请先联网获取一次。" or "缓存损坏或格式不兼容，请联网刷新。")
        return
    end
    self:show_entry(kind, entry)
end

function UI:show_cached_feed(kind)
    local entry, err = self.cache:load_feed(kind)
    if not entry then
        UI.message(err == "missing" and "暂无网页列表缓存，请先导入知乎会话并联网获取。"
            or "网页列表缓存损坏或格式不兼容，请联网刷新。")
        return
    end
    self:show_feed(kind, entry.result, "缓存于 " .. cache_stamp(entry.saved_at), nil, true)
end

function UI:show_entry(kind, entry, source_label)
    local stamp = "未知时间"
    local ok, date = pcall(os.date, "%Y-%m-%d %H:%M", entry.saved_at)
    if ok and date then stamp = date end
    -- Expired content remains readable offline and is clearly marked as cached.
    self:show_result(kind, entry.result, entry.query,
        (source_label and source_label .. " · " or "缓存 · ") .. stamp, entry.raw)
end

function UI:show_result(kind, result, query, cache_label, raw)
    local title = titles[kind]
    if kind == "answer" then
        UIManager:show(TextViewer:new{
            title = title .. (cache_label and "（" .. cache_label .. "）" or ""), text = (query or "") .. "\n\n" .. result.answer
                .. (result.truncated and "\n\n回答因长度限制而截断。" or ""),
            width = Device.screen:getWidth(), height = Device.screen:getHeight(),
            text_type = "general", force_txt = true,
        })
        return
    end
    local items = {}
    local maximum = self.config:get("hot_limit")
    for index, item in ipairs(result.items) do
        if index > maximum then break end
        local selected = index
        local entry = item
        items[#items + 1] = {
            text = string.format("%d. [%s] %s\n%s%s", index, types[item.kind] or "内容", item.title,
                item.author ~= "" and item.author .. " · " or "", Renderer.preview(item.summary)),
            callback = function()
                if entry.kind == "question" and Schema.question_url(entry.url) then self:open_question(entry)
                elseif entry.kind == "answer" and PublicAnswer.answer_id(entry.url) then
                    self:fetch_logged_answer(entry, { items = result.items, index = selected, title = query or title })
                else self:detail(entry) end
            end,
            hold_callback = function()
                self:actions(entry, kind, query, raw,
                    { items = result.items, index = selected, title = query or title })
            end,
        }
    end
    if #items == 0 then items[1] = { text = "暂无结果。" .. (result.empty_reason or "") } end
    local menu
    local options = { buttons = self:home_buttons(function() return menu end), subtitle = cache_label or "刚刚更新 · 点击标题阅读" }
    if kind == "hot" then
        local old = self.home_widget
        if old then
            self.replacing_home = old
            UIManager:close(old)
            self.replacing_home = nil
        end
        options.close_callback = function() self:on_home_close(menu) end
        menu = self:menu(title, items, options)
        self.home_widget = menu
    else
        menu = self:menu(title .. " · " .. Renderer.preview(query, 16), items, options)
    end
    return menu
end

function UI:show_feed(kind, result, cache_label, context, cached)
    local title = titles[kind] or "知乎列表"
    local items = {}
    for index, item in ipairs(result.items or {}) do
        local selected, entry = index, item
        items[#items + 1] = {
            text = string.format("%d. [%s] %s\n%s%s", index, types[item.kind] or "内容", item.title,
                item.author ~= "" and item.author .. " · " or "", Renderer.preview(item.summary)),
            callback = function()
                local navigation = { items = result.items, index = selected, title = title }
                if entry.kind == "question" and Schema.question_url(entry.url) then self:open_question(entry)
                elseif entry.kind == "answer" and PublicAnswer.answer_id(entry.url) then
                    self:fetch_logged_answer(entry, navigation)
                else self:detail(entry) end
            end,
            hold_callback = function()
                self:actions(entry, kind, nil, nil,
                    { items = result.items, index = selected, title = title })
            end,
        }
    end
    if #items == 0 then items[1] = { text = "暂无可展示内容。" } end
    if kind == "recommend" then
        if context and context.index and context.index > 1 then
            table.insert(items, 1, { text = "上一批推荐", callback = function()
                local previous = context.pages[context.index - 1]
                if previous then
                    context.index = context.index - 1
                    self:show_feed(kind, previous, nil, context, false)
                end
            end })
        end
        if not cached and result.next_cursor then
            items[#items + 1] = { text = "下一批推荐", callback = function()
                self:request_feed(kind, result.next_cursor, context, (context.index or 1) + 1)
            end }
        end
        items[#items + 1] = { text = "刷新推荐", callback = function()
            self:request_feed(kind, nil, context, 1, true)
        end }
    end
    local menu
    local options = { buttons = self:home_buttons(function() return menu end, kind),
        subtitle = (cache_label and cache_label .. " · " or "")
            .. (kind == "recommend" and context and context.index > 1 and ("第 " .. context.index .. " 批 · ") or "")
            .. (cached and "离线阅读" or "网页列表 · 点击标题阅读") }
    if kind == "hot" then
        local old = self.home_widget
        if old then
            self.replacing_home = old
            UIManager:close(old)
            self.replacing_home = nil
        end
        options.close_callback = function() self:on_home_close(menu) end
        menu = self:menu(title, items, options)
        self.home_widget = menu
    else
        menu = self:menu(title, items, options)
    end
    return menu
end

function UI:open_question(item, cached)
    local url = Schema.question_url(item.url)
    if not url then self:detail(item) return end
    local index = cached and cached.index or 1
    local context = { question = item, url = url, cursors = {},
        index = index, pages = {}, active = true }
    if cached then context.pages[index] = cached end
    self:question_page(context, nil, index)
    return context
end

function UI:question_page(context, cursor, index, force)
    if not context.active then return end
    local entry = not force and (context.pages[index] or self.cache:load_web_question(context.url, index))
    local function display(page)
        if not context.active then return end
        context.pages[index] = page
        context.index = index
        if page.result.next_cursor then context.cursors[index + 1] = page.result.next_cursor end
        self:show_question(context, page)
    end
    if entry then display(entry) return end
    local session = self.zhihu_session
    self:run_request("问题回答列表", function()
        return self.logged_api:fetch_question_answers(context.url, cursor or context.cursors[index], session)
    end, function(result)
            local saved = self.cache:save_web_question(context.url, context.question.title, index, result)
            display({ result = result, index = index, fetched_at = os.time() })
            if not saved then UI.message("回答已获取，但离线缓存写入失败。") end
        end, function(err)
            if err.kind == "login_required" then self.zhihu_session = nil end
            local previous = context.pages[index] or self.cache:load_web_question(context.url, index)
            if previous then display(previous) end
            UI.message(err.message .. (previous and "\n已保留本页缓存。" or "\n返回后可继续阅读已缓存摘要。"))
        end, false)
end

function UI:show_question(context, entry)
    local result = entry.result
    local items, menu = {}, nil
    for index, answer in ipairs(result.items) do
        local selected = index
        local selected_answer = answer
        items[#items + 1] = { text = string.format("%d. %s\n%s", index, answer.title, Renderer.preview(answer.summary, 90)),
            callback = function()
                if PublicAnswer.answer_id(selected_answer.url) then
                    self:fetch_logged_answer(selected_answer, { items = result.items, index = selected, title = context.question.title })
                else self:read_answer(context, entry, selected) end
            end,
            hold_callback = function() self:actions(selected_answer, nil, nil, nil,
                { items = result.items, index = selected, title = context.question.title }) end }
    end
    if #items == 0 then
        items[1] = { text = result.is_end and "本批没有可展示的回答摘要，已到末尾。"
            or "本批没有可展示的摘要；可点击“下一批”继续。" }
    end
    local page_index = entry.index or context.index
    local function close()
        context.active = false
        if context.widget then context.widget:onClose() end
    end
    local buttons = {
        {
            { text = "返回", callback = close },
            { text = "问题摘要", callback = function() self:detail(context.question) end },
            { text = "刷新本批", enabled = page_index == 1 or context.cursors[page_index] ~= nil, callback = function()
                self:question_page(context, context.cursors[page_index], page_index, true)
            end },
        },
        {
            { text = "上一批", enabled = context.index > 1, callback = function()
                if context.index > 1 then
                    self:question_page(context, context.cursors[context.index - 1], context.index - 1)
                end
            end },
            { text = "下一批", enabled = not result.is_end and (result.next_cursor ~= nil
                or context.pages[page_index + 1] ~= nil
                or self.cache:load_web_question(context.url, page_index + 1) ~= nil), callback = function()
                local next_index = page_index + 1
                self:question_page(context, context.cursors[next_index] or result.next_cursor, next_index)
            end },
        },
    }
    if context.widget then
        local previous = context.widget
        context.widget = nil -- Replacing a page must not end the question session.
        UIManager:close(previous)
    end
    menu = self:menu("回答摘要 · " .. Renderer.preview(context.question.title, 24), items, {
        buttons = buttons, subtitle = string.format("第 %d 批 · %s · 摘要非全文", page_index,
            entry.saved_at and "已缓存" or "刚刚更新"),
        close_callback = function()
            if context.widget == menu then
                context.widget = nil
                context.active = false
            end
        end,
    })
    context.widget = menu
end

function UI:read_answer(context, entry, index)
    local answer = entry.result.items[index]
    if not answer then return end
    local viewer
    local function move(target)
        if viewer then UIManager:close(viewer) end
        self:read_answer(context, entry, target)
    end
    local actions = { {
        { text = "原始链接", enabled = answer.url ~= "", callback = function() self:open_link(answer.url) end },
        { text = "获取正文（需知乎登录）", enabled = PublicAnswer.answer_id(answer.url) ~= nil,
            callback = function() self:fetch_logged_answer(answer) end },
        { text = "查看评论（需知乎登录）", enabled = PublicAnswer.answer_id(answer.url) ~= nil,
            callback = function() self:fetch_comments(answer, "0") end },
        { text = "匿名尝试获取正文", enabled = PublicAnswer.answer_id(answer.url) ~= nil,
            callback = function() self:try_answer_body(answer) end },
    } }
    viewer = Reader:new{
        title = string.format("回答摘要 %d / %d", index, #entry.result.items),
        subtitle = Renderer.preview(context.question.title, 18),
        text = context.question.title .. "\n\n" .. Renderer.summary(answer),
        side = self.config:get("reader_side"),
        on_prev = index > 1 and function() move(index - 1) end or nil,
        on_next = index < #entry.result.items and function() move(index + 1) end or nil,
        actions = actions,
        on_side_change = function(side) self.config:set("reader_side", side) end,
    }
    UIManager:show(viewer)
    return viewer
end

function UI:detail(item)
    local buttons = {
        { text = "原始链接", enabled = item.url ~= "", callback = function() self:open_link(item.url) end },
        { text = "复制链接", enabled = item.url ~= "", callback = function() self:copy_link(item.url) end },
    }
    if item.kind == "answer" and PublicAnswer.answer_id(item.url) then
        buttons[#buttons + 1] = { text = "获取正文（需知乎登录）", callback = function() self:fetch_logged_answer(item) end }
        buttons[#buttons + 1] = { text = "查看评论（需知乎登录）", callback = function() self:fetch_comments(item, "0") end }
        buttons[#buttons + 1] = { text = "匿名尝试获取正文", callback = function() self:try_answer_body(item) end }
    end
    UIManager:show(TextViewer:new{
        title = item.title, text = Renderer.detail(item),
        width = Device.screen:getWidth(), height = Device.screen:getHeight(),
        text_type = "general", force_txt = true, add_default_buttons = true,
        buttons_table = { buttons },
    })
end

function UI:try_answer_body(item)
    self:run_request("回答正文", function() return self.public_answer:fetch(item.url, item.summary) end,
        function(result)
            local viewer
            viewer = TextViewer:new{
                title = "回答正文 · 网页接口",
                text = item.title .. "\n\n" .. result.content .. "\n\n来源：" .. result.url
                    .. "\n回答 ID 已核对；网页接口未提供可独立验证的全文标记。",
                width = Device.screen:getWidth(), height = Device.screen:getHeight(),
                text_type = "general", force_txt = true, add_default_buttons = true,
                buttons_table = { { { text = "返回摘要", callback = function() UIManager:close(viewer) end } } },
            }
            UIManager:show(viewer)
        end,
        function(err) UI.message(err.message) end, false)
end

local function adjacent_answer(navigation, direction)
    if type(navigation) ~= "table" or type(navigation.items) ~= "table" then return nil end
    local index = tonumber(navigation.index)
    if not index then return nil end
    local candidate = index + direction
    while candidate >= 1 and candidate <= #navigation.items do
        local item = navigation.items[candidate]
        if item and PublicAnswer.answer_id(item.url) then return candidate, item end
        candidate = candidate + direction
    end
    return nil
end

function UI:show_logged_body(item, result, cached, navigation)
    local previous = adjacent_answer(navigation, -1)
    local following = adjacent_answer(navigation, 1)
    local stamp = cached and os.date("%Y-%m-%d %H:%M", result.fetched_at) or nil
    local viewer
    local function move(index, next_item)
        if viewer then UIManager:close(viewer) end
        local next_navigation = { items = navigation.items, index = index, title = navigation.title }
        self:fetch_logged_answer(next_item, next_navigation)
    end
    local actions = { {
        { text = "查看评论", callback = function() self:fetch_comments(item, "0", navigation) end },
        { text = "查看摘要", callback = function() self:detail(item) end },
        { text = "刷新正文", callback = function() self:fetch_logged_answer(item, navigation, true) end },
    } }
    viewer = Reader:new{
        title = item.title or "回答正文",
        subtitle = (cached and ("缓存于 " .. (stamp or "未知时间")) or "已校验正文")
            .. (navigation and navigation.title and (" · " .. Renderer.preview(navigation.title, 18)) or ""),
        text = result.content,
        side = self.config:get("reader_side"),
        on_prev = previous and function() move(previous, navigation.items[previous]) end or nil,
        on_next = following and function() move(following, navigation.items[following]) end or nil,
        actions = actions,
        on_side_change = function(side) self.config:set("reader_side", side) end,
    }
    UIManager:show(viewer)
    self:prefetch_next_answer(navigation)
    return viewer
end

function UI:prefetch_next_answer(navigation)
    if not navigation or not self.zhihu_session or not self.logged_cache then return end
    local index, item = adjacent_answer(navigation, 1)
    local id = item and PublicAnswer.answer_id(item.url)
    if not id or self.logged_cache:load_answer(id) then return end
    local session = self.zhihu_session
    self:run_request("缓存下一条回答", function()
        return self.logged_api:fetch_answer(id, session, item.summary)
    end, function(result)
        if self.logged_cache then self.logged_cache:save_answer(result) end
    end, function(err)
        if err.kind == "login_required" and self.zhihu_session == session then self.zhihu_session = nil end
    end, false)
end

function UI:fetch_logged_answer(item, navigation, force_refresh)
    local id = PublicAnswer.answer_id(item.url)
    if not id then UI.message("无法从回答链接核对回答 ID。") return end
    local cached = not force_refresh and self.logged_cache and self.logged_cache:load_answer(id)
    if cached then return self:show_logged_body(item, cached, true, navigation) end
    if not self.zhihu_session then
        local saved = self.logged_cache and self.logged_cache:load_answer(id)
        if saved then self:show_logged_body(item, saved, true, navigation)
        else UI.message("尚未登录知乎。请先在“设置”中扫码登录或导入浏览器会话，再点击获取正文。摘要仍可阅读。") end
        return
    end
    self:run_request("已登录回答正文", function()
        return self.logged_api:fetch_answer(id, self.zhihu_session, item.summary)
    end, function(result)
        if self.logged_cache then self.logged_cache:save_answer(result) end
        self:show_logged_body(item, result, false, navigation)
    end, function(err)
        if err.kind == "login_required" then self.zhihu_session = nil end
        local saved = self.logged_cache and self.logged_cache:load_answer(id)
        if saved then
            self:show_logged_body(item, saved, true, navigation)
            UI.message((err.message or "回答获取失败。") .. "\n已打开最近一次通过校验的正文缓存。")
        else UI.message(err.message or "回答获取失败，摘要仍可阅读。") end
    end, false)
end

function UI:comments_page(item, id, cursor, page, cached, navigation)
    local items = {}
    for index, comment in ipairs(page.items or {}) do
        items[#items + 1] = { text = string.format("%d. %s\n%s", index,
            comment.author ~= "" and comment.author or "匿名用户", comment.content) }
    end
    if #items == 0 then items[1] = { text = "本页没有评论。" } end
    local stamp = os.date("%Y-%m-%d %H:%M", page.fetched_at or os.time())
    local menu
    local buttons = { {
        { text = "返回回答", callback = function()
            if menu then UIManager:close(menu) end
            if navigation then self:fetch_logged_answer(item, navigation)
            else self:detail(item) end
        end },
        { text = "刷新本页", callback = function()
            if menu then UIManager:close(menu) end
            self:fetch_comments(item, cursor, navigation, true)
        end },
        { text = "下一页", enabled = not page.is_end, callback = function()
            if page.next_cursor then
                if menu then UIManager:close(menu) end
                self:fetch_comments(item, page.next_cursor, navigation)
            end
        end },
    } }
    menu = self:menu("回答评论", items, { buttons = buttons,
        subtitle = string.format("%s取得于 %s · %s%s", cached and "缓存 · " or "", stamp, page.range or ("本页 " .. #page.items .. " 条"),
            page.is_end and " · 已到末尾" or "") })
end

function UI:fetch_comments(item, cursor, navigation, force_refresh)
    local id = PublicAnswer.answer_id(item.url)
    if not id then UI.message("无法从回答链接核对回答 ID。") return end
    cursor = cursor or "0"
    local cached = not force_refresh and self.logged_cache and self.logged_cache:load_comments(id, cursor)
    if cached then return self:comments_page(item, id, cursor, cached, true, navigation) end
    if not self.zhihu_session then
        local saved = self.logged_cache and self.logged_cache:load_comments(id, cursor)
        if saved then self:comments_page(item, id, cursor, saved, true, navigation)
        else UI.message("尚未登录知乎。请先在“设置”中扫码登录或导入浏览器会话，再查看评论。摘要仍可阅读。") end
        return
    end
    self:run_request("回答评论", function()
        return self.logged_api:fetch_comments(id, cursor, self.zhihu_session)
    end, function(page)
        if self.logged_cache then self.logged_cache:save_comments(id, cursor, page) end
        self:comments_page(item, id, cursor, page, false, navigation)
    end, function(err)
        if err.kind == "login_required" then self.zhihu_session = nil end
        local saved = self.logged_cache and self.logged_cache:load_comments(id, cursor)
        if saved then
            self:comments_page(item, id, cursor, saved, true, navigation)
            UI.message((err.message or "评论获取失败。") .. "\n已打开最近一次评论缓存。")
        else UI.message((err.message or "评论获取失败。") .. "\n评论读取已停止，摘要仍可阅读。") end
    end, false)
end

function UI:stop_login_flow(message)
    local flow = self.login_flow
    if flow then
        flow.active = false
        if flow.timer then UIManager:unschedule(flow.timer) flow.timer = nil end
        local widget = flow.widget
        flow.widget = nil
        self.login_flow = nil
        if widget then UIManager:close(widget) end
    end
    if message then UI.message(message) end
end

function UI:poll_login(flow)
    if self.login_flow ~= flow or not flow.active then return end
    if flow.expires_at and os.time() * 1000 >= flow.expires_at then
        self:stop_login_flow("二维码已过期，请重新发起登录。")
        return
    end
    self:run_request("扫码登录状态", function()
        return self.logged_api:poll_login(flow.session)
    end, function(state)
        if self.login_flow ~= flow or not flow.active then return end
        if state.jar then flow.session.jar = state.jar end
        if state.confirmed then
            self:run_request("知乎会话校验", function()
                return self.logged_api:verify_session(flow.session)
            end, function(session)
                if self.login_flow ~= flow or not flow.active then return end
                self.zhihu_session = session
                self:stop_login_flow("知乎账号会话校验通过。会话仅保存在内存中，退出插件或 KOReader 后需重新登录。")
            end, function(err)
                if self.login_flow == flow and flow.active then
                    self:stop_login_flow((err.message or "登录态校验失败。") .. "\n扫码确认不代表登录成功；请重新登录或返回摘要阅读。")
                end
            end, false, function()
                if self.login_flow == flow then self:stop_login_flow("知乎会话校验已取消，登录未完成。") end
            end)
            return
        end
        flow.scanned = state.scanned or flow.scanned
        if flow.widget and flow.widget.setSubTitle then
            flow.widget:setSubTitle(flow.scanned and "手机已扫码，等待知乎确认登录…" or "请用知乎手机客户端扫码；确认后还会校验账号会话。")
        end
        flow.timer = function() self:poll_login(flow) end
        UIManager:scheduleIn(4, flow.timer)
    end, function(err)
        if self.login_flow ~= flow or not flow.active then return end
        local kind = err.kind
        if kind == "verification_required" or kind == "qr_expired" or kind == "login_required" or kind == "rate_limited"
            or kind == "forbidden" or kind == "invalid_response" then
            self:stop_login_flow((err.message or "扫码登录停止。") .. "\n仍可继续阅读已缓存摘要。")
            return
        end
        -- Transient network errors are retryable; the challenge path above is terminal.
        if flow.widget and flow.widget.setSubTitle then flow.widget:setSubTitle("网络暂时不可用，4 秒后重试扫码状态…") end
        flow.timer = function() self:poll_login(flow) end
        UIManager:scheduleIn(4, flow.timer)
    end, false, function()
        if self.login_flow == flow then self:stop_login_flow("扫码状态查询已取消，登录流程已停止。") end
    end)
end

function UI:start_login()
    if self.busy then UI.message("当前有请求正在运行，请稍后再发起登录。") return end
    self:stop_login_flow()
    local flow = { active = true }
    self.login_flow = flow
    self:run_request("知乎登录初始化", function() return self.logged_api:create_qr() end,
        function(session)
            if self.login_flow ~= flow or not flow.active then return end
            flow.session, flow.expires_at = session, session.expires_at
            local QRMessage = require("ui/widget/qrmessage")
            flow.widget = QRMessage:new{ text = session.link,
                dismiss_callback = function()
                    if self.login_flow == flow then self:stop_login_flow() end
                end }
            UIManager:show(flow.widget)
            flow.timer = function() self:poll_login(flow) end
            UIManager:scheduleIn(4, flow.timer)
        end,
        function(err)
            if self.login_flow == flow then self.login_flow = nil end
            UI.message((err.message or "知乎扫码登录初始化失败。") .. "\n登录未完成，摘要阅读仍可用。")
        end, false, function()
            if self.login_flow == flow then self:stop_login_flow("知乎扫码登录已取消。") end
        end)
end

function UI:import_cookie_session(refresh)
    if self.busy then UI.message("当前有请求正在运行，请稍后再导入会话。") return end
    local session, import_err = self.logged_api:consume_cookie_import()
    if not session then
        UI.message((import_err and import_err.message or "临时浏览器会话无法读取。")
            .. "\n请在电脑上重新运行一次性探针，再于 10 分钟内导入。")
        return
    end
    self:run_request("验证临时浏览器会话", function()
        return self.logged_api:verify_session(session)
    end, function(verified)
        self.zhihu_session = verified
        if refresh then UIManager:nextTick(refresh) end
        UI.message("知乎会话校验通过。Cookie 只保存在当前 KOReader 内存中，退出插件或 KOReader 后会清除。")
    end, function(err)
        UI.message((err.message or "临时浏览器会话校验失败。") .. "\n会话未导入，摘要仍可阅读。")
    end, false)
end

function UI:actions(item, kind, query, raw, navigation)
    local dialog
    local function action(callback)
        return function() UIManager:close(dialog) callback() end
    end
    local answer_id = PublicAnswer.answer_id(item.url)
    local buttons = {}
    if answer_id then
        buttons[#buttons + 1] = { { text = "获取正文", callback = action(function() self:fetch_logged_answer(item, navigation) end) } }
        buttons[#buttons + 1] = { { text = "查看评论", callback = action(function() self:fetch_comments(item, "0", navigation) end) } }
    end
    buttons[#buttons + 1] = { { text = "阅读摘要", callback = action(function() self:detail(item) end) } }
    buttons[#buttons + 1] = { { text = "打开原始链接", enabled = item.url ~= "", callback = action(function() self:open_link(item.url) end) } }
    buttons[#buttons + 1] = { { text = "复制链接", enabled = item.url ~= "", callback = action(function() self:copy_link(item.url) end) } }
    buttons[#buttons + 1] = { { text = "缓存本次结果", enabled = raw ~= nil, callback = action(function()
        local ok = self.cache:save(kind, query, raw)
        UI.message(ok and "本次结果已缓存；每类只保留最近一次。" or "缓存写入失败，请检查剩余空间。")
    end) } }
    buttons[#buttons + 1] = { { text = "关闭", callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{
        title = item.title, buttons = buttons,
    }
    UIManager:show(dialog)
end

function UI:copy_link(url)
    if Schema.safe_url(url) == "" then return end
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(url)
        UI.message("已复制链接。")
    else
        UIManager:show(TextViewer:new{ title = "来源链接", text = url, force_txt = true })
    end
end

function UI:open_link(url)
    if Schema.safe_url(url) == "" then UI.message("没有可打开的 HTTP/HTTPS 链接。") return end
    if Device:canOpenLink() then
        Device:openLink(url)
    else
        -- Kindle's KOReader does not provide a general browser. QR is the
        -- portable fallback; webbrowser.koplugin integration belongs to P1.
        local QRMessage = require("ui/widget/qrmessage")
        UIManager:show(QRMessage:new{ text = url })
    end
end

function UI:settings()
    local fields = {
        { "base_url", "API Base URL" }, { "access_secret", "Access Secret" },
        { "hot_limit", "热榜数量（1～30）" },
        { "timeout", "请求超时秒数（5～120）" },
    }
    local items, settings_menu = {}
    local function refresh()
        UIManager:close(settings_menu)
        self:settings()
    end
    items[#items + 1] = { text = "导入电脑临时传入的浏览器会话", callback = function()
        self:import_cookie_session(refresh)
    end }
    items[#items + 1] = { text = "知乎扫码登录" .. (self.zhihu_session and ("：已登录 · " .. (self.zhihu_session.user.name or "知乎用户")) or "：未登录"),
        callback = function() self:start_login() end }
    if self.zhihu_session then
        items[#items + 1] = { text = "退出知乎登录", callback = function()
            self:stop_login_flow()
            self.zhihu_session = nil
            refresh()
            UI.message("知乎会话已从内存清除。")
        end }
    end
    for _, field in ipairs(fields) do
        local key, label = field[1], field[2]
        local value = self.config:get(key)
        local shown = key == "access_secret" and (value ~= "" and "已设置（隐藏）" or "未设置") or tostring(value)
        items[#items + 1] = { text = label .. "：" .. shown, callback = function()
            self:input(label, tostring(self.config:get(key)), function(input)
                local ok, err = self.config:set(key, input)
                if ok then UIManager:nextTick(refresh) end
                return ok, err
            end, key == "access_secret")
        end }
    end
    items[#items + 1] = { text = "清除 Access Secret", callback = function()
        local ok, err = self.config:set("access_secret", "")
        if ok then refresh() UI.message("Access Secret 已清除。") else UI.message(err) end
    end }
    items[#items + 1] = { text = "直答模型：" .. self.config:get("model"), callback = function()
        local models, model_menu = {}, nil
        for _, name in ipairs(Config.models) do
            local model = name
            models[#models + 1] = { text = model, callback = function()
                local ok, err = self.config:set("model", model)
                if ok then UIManager:close(model_menu) refresh() else UI.message(err) end
            end }
        end
        model_menu = self:menu("选择直答模型", models)
    end }
    items[#items + 1] = { text = "图片下载：关闭（P1 待实现）", callback = function()
        UI.message("当前版本仅阅读文字，不下载缩略图或正文图片。")
    end }
    items[#items + 1] = { text = "夜间模式：" .. (night_mode_enabled() and "开" or "关"), callback = function()
        local ok, Event = pcall(require, "ui/event")
        if ok and UIManager.broadcastEvent then
            UIManager:broadcastEvent(Event:new("ToggleNightMode"))
            UIManager:nextTick(refresh)
        else
            UI.message("当前环境不支持夜间模式切换，请在 KOReader 屏幕设置中开启。")
        end
    end }
    settings_menu = self:menu("知乎设置", items)
end

return UI
