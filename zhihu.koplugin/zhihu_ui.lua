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
local UI = {}
UI.__index = UI
local titles = { hot = "知乎热榜", search = "知乎搜索", answer = "知乎直答" }
local types = { question = "问题", answer = "回答", article = "文章", content = "内容" }

function UI.new(config, api, cache, reader_ui)
    return setmetatable({ config = config, api = api, cache = cache, reader_ui = reader_ui }, UI)
end

function UI.message(text)
    UIManager:show(InfoMessage:new{ text = text })
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

function UI:home_buttons(owner)
    return {
        {
            { text = "热榜", callback = function()
                local page = owner and owner()
                if page and page ~= self.home_widget then UIManager:close(page) end
                self:home()
            end },
            { text = "搜索", callback = function() self:prompt("search") end },
            { text = "直答", callback = function() self:prompt("answer") end },
        },
        {
            { text = "刷新热榜", callback = function() self:request("hot") end },
            { text = "离线", callback = function() self:offline_menu() end },
            { text = "设置", callback = function() self:settings() end },
        },
    }
end

function UI:home()
    if self.home_widget then return end
    local entry = self.cache:load("hot")
    if entry then self:show_entry("hot", entry) return end
    local menu
    menu = self:menu("知乎热榜", {
        { text = "还没有热榜内容\n点击上方“刷新热榜”获取，成功后会自动缓存。",
            callback = function() self:request("hot") end },
        { text = "首次使用：先设置 Access Secret\n密钥只需在设备上填写；断网时可阅读已缓存内容。",
            callback = function() self:settings() end },
    }, { buttons = self:home_buttons(function() return menu end), subtitle = "打开即读缓存 · 手动刷新联网",
        close_callback = function() if self.home_widget == menu then self.home_widget = nil end end })
    self.home_widget = menu
end

function UI:offline_menu()
    local items = {
        { text = "最近热榜", callback = function() self:show_cached("hot") end },
        { text = "最近搜索", callback = function() self:show_cached("search") end },
        { text = "最近直答", callback = function() self:show_cached("answer") end },
        { text = "最近问题的回答摘要", callback = function()
            local entry = self.cache:recent_question()
            if not entry then UI.message("暂无问题回答缓存。") return end
            self:open_question({ title = entry.title, url = entry.url }, entry)
        end },
    }
    return self:menu("离线阅读", items)
end

function UI:menu_items()
    return {
        { text = "刷新热榜（最多 30 条）", callback = function() self:request("hot") end },
        { text = "搜索知乎（最多 10 条）", callback = function() self:prompt("search") end },
        { text = "知乎直答", callback = function() self:prompt("answer") end },
        { text = "离线缓存", sub_item_table = {
            { text = "最近热榜", callback = function() self:show_cached("hot") end },
            { text = "最近搜索", callback = function() self:show_cached("search") end },
            { text = "最近直答", callback = function() self:show_cached("answer") end },
        } },
        { text = "设置", callback = function() self:settings() end },
        { text = "关于 · 0.2.0", callback = function()
            UI.message("知乎 0.2.0\n热榜首页、问题回答摘要、搜索、直答与离线阅读。\n当前为文字摘要；他人回答全文与完整评论不在官方接口能力内。")
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
    self:input(kind == "search" and "搜索知乎：请输入关键词" or "知乎直答：请输入问题", "", function(value)
        local query = value:match("^%s*(.-)%s*$")
        if query == "" then return nil, "请输入非空的关键词或问题。" end
        UIManager:nextTick(function() self:request(kind, query) end)
        return true
    end)
end

function UI:run_request(label, task, success, failure)
    if self.busy then UI.message("已有请求进行中，请等待或取消。") return end
    if self.config:get("access_secret") == "" then UI.message(Errors.new("config").message) return end
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
            if not completed then return end -- User cancellation never writes a cache.
            if not result then failure(err or Errors.new("network")) return end
            success(result, raw)
        end)
    end)
end

function UI:request(kind, query)
    self:run_request(titles[kind], function()
        if kind == "hot" then return self.api:hot_list() end
        if kind == "search" then return self.api:search(query) end
        return self.api:ask(query)
    end, function(result, raw)
        local saved = self.cache:save(kind, query, raw)
        self:show_result(kind, result, query, nil, raw)
        if not saved then UI.message("结果已获取，但缓存写入失败，请检查剩余空间。") end
    end, function(err) self:failed(kind, query, err) end)
end

function UI:failed(kind, query, err)
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

function UI:show_entry(kind, entry)
    local stamp = "未知时间"
    local ok, date = pcall(os.date, "%Y-%m-%d %H:%M", entry.saved_at)
    if ok and date then stamp = date end
    -- Expired content remains readable offline and is clearly marked as cached.
    self:show_result(kind, entry.result, entry.query, "缓存 · " .. stamp, entry.raw)
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
    local maximum = self.config:get(kind == "hot" and "hot_limit" or "search_count")
    for index, item in ipairs(result.items) do
        if index > maximum then break end
        local entry = item
        items[#items + 1] = {
            text = string.format("%d. [%s] %s\n%s%s", index, types[item.kind] or "内容", item.title,
                item.author ~= "" and item.author .. " · " or "", Renderer.preview(item.summary)),
            callback = function()
                if entry.kind == "question" and Schema.question_url(entry.url) then self:open_question(entry)
                else self:detail(entry) end
            end,
            hold_callback = function() self:actions(entry, kind, query, raw) end,
        }
    end
    if #items == 0 then items[1] = { text = "暂无结果。" .. (result.empty_reason or "") } end
    local menu
    local options = { buttons = self:home_buttons(function() return menu end), subtitle = cache_label or "刚刚更新 · 点击标题阅读" }
    if kind == "hot" then
        local old = self.home_widget
        if old then UIManager:close(old) end
        options.close_callback = function() if self.home_widget == menu then self.home_widget = nil end end
        menu = self:menu(title, items, options)
        self.home_widget = menu
    else
        menu = self:menu(title .. " · " .. Renderer.preview(query, 16), items, options)
    end
    return menu
end

function UI:open_question(item, cached)
    local url = Schema.question_url(item.url)
    if not url then self:detail(item) return end
    local context = { question = item, url = url, offsets = { cached and cached.offset or 0 },
        index = 1, pages = {}, active = true }
    if cached then context.pages[cached.offset] = cached end
    self:question_page(context, context.offsets[1], 1)
    return context
end

function UI:question_page(context, offset, index, force)
    if not context.active then return end
    local entry = not force and (context.pages[offset] or self.cache:load_question(context.url, offset))
    local function display(page)
        if not context.active then return end
        context.pages[offset] = page
        context.index = index
        context.offsets[index] = offset
        self:show_question(context, page)
    end
    if entry then display(entry) return end
    self:run_request("问题回答摘要", function() return self.api:question_answers(context.url, offset) end,
        function(result, raw)
            local saved = self.cache:save_question(context.url, context.question.title, offset, raw)
            display({ result = result, raw = raw, offset = offset, cached = false })
            if not saved then UI.message("回答已获取，但离线缓存写入失败。") end
        end, function(err)
            local previous = context.pages[offset] or self.cache:load_question(context.url, offset)
            if previous then display(previous) end
            UI.message(err.message .. (previous and "\n已保留本页缓存。" or "\n返回后可继续阅读原列表。"))
        end)
end

function UI:show_question(context, entry)
    local result = entry.result
    local items, menu = {}, nil
    for index, answer in ipairs(result.items) do
        local selected = index
        items[#items + 1] = { text = string.format("%d. %s\n%s", index, answer.title, Renderer.preview(answer.summary, 90)),
            callback = function() self:read_answer(context, entry, selected) end,
            hold_callback = function() self:actions(answer) end }
    end
    if #items == 0 then
        items[1] = { text = result.is_end and "本批没有可展示的回答摘要，已到末尾。"
            or "本批没有可展示的摘要；可点击“下一批”继续。" }
    end
    local offset = entry.offset
    local function close()
        context.active = false
        if context.widget then context.widget:onClose() end
    end
    local buttons = {
        {
            { text = "返回", callback = close },
            { text = "问题摘要", callback = function() self:detail(context.question) end },
            { text = "刷新本批", callback = function() self:question_page(context, offset, context.index, true) end },
        },
        {
            { text = "上一批", enabled = context.index > 1, callback = function()
                if context.index > 1 then self:question_page(context, context.offsets[context.index - 1], context.index - 1) end
            end },
            { text = "下一批", enabled = not result.is_end, callback = function()
                if result.next_offset then self:question_page(context, result.next_offset, context.index + 1) end
            end },
        },
    }
    if context.widget then UIManager:close(context.widget) end
    menu = self:menu("回答摘要 · " .. Renderer.preview(context.question.title, 24), items, {
        buttons = buttons, subtitle = string.format("第 %d 批 · %s · 摘要非全文", context.index,
            entry.saved_at and "已缓存" or "刚刚更新"),
        close_callback = function() context.active = false end,
    })
    context.widget = menu
end

function UI:read_answer(context, entry, index)
    local answer = entry.result.items[index]
    if not answer then return end
    local viewer
    local function move(target)
        UIManager:close(viewer)
        self:read_answer(context, entry, target)
    end
    viewer = TextViewer:new{
        title = string.format("回答摘要 %d / %d", index, #entry.result.items),
        text = context.question.title .. "\n\n" .. Renderer.detail(answer), force_txt = true,
        width = Device.screen:getWidth(), height = Device.screen:getHeight(), text_type = "general",
        add_default_buttons = true,
        buttons_table = {
            {
                { text = "上一条", enabled = index > 1, callback = function() if index > 1 then move(index - 1) end end },
                { text = "返回列表", callback = function() UIManager:close(viewer) end },
                { text = "下一条", enabled = index < #entry.result.items,
                    callback = function() if index < #entry.result.items then move(index + 1) end end },
            },
            {
                { text = "原始链接", enabled = answer.url ~= "", callback = function() self:open_link(answer.url) end },
                { text = "评论说明", callback = function()
                    UI.message("当前官方接口不提供任意他人回答的完整评论，因此本版不展示评论列表。\n可通过原始链接查看。")
                end },
            },
        },
    }
    UIManager:show(viewer)
end

function UI:detail(item)
    UIManager:show(TextViewer:new{
        title = item.title, text = Renderer.detail(item),
        width = Device.screen:getWidth(), height = Device.screen:getHeight(),
        text_type = "general", force_txt = true, add_default_buttons = true,
        buttons_table = { {
            { text = "原始链接", enabled = item.url ~= "", callback = function() self:open_link(item.url) end },
            { text = "复制链接", enabled = item.url ~= "", callback = function() self:copy_link(item.url) end },
        } },
    })
end

function UI:actions(item, kind, query, raw)
    local dialog
    local function action(callback)
        return function() UIManager:close(dialog) callback() end
    end
    dialog = ButtonDialog:new{
        title = item.title, buttons = {
            { { text = "阅读摘要", callback = action(function() self:detail(item) end) } },
            { { text = "打开原始链接", enabled = item.url ~= "", callback = action(function() self:open_link(item.url) end) } },
            { { text = "复制链接", enabled = item.url ~= "", callback = action(function() self:copy_link(item.url) end) } },
            { { text = "缓存本次结果", enabled = raw ~= nil, callback = action(function()
                local ok = self.cache:save(kind, query, raw)
                UI.message(ok and "本次结果已缓存；每类只保留最近一次。" or "缓存写入失败，请检查剩余空间。")
            end) } },
            { { text = "关闭", callback = function() UIManager:close(dialog) end } },
        },
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
        { "hot_limit", "热榜数量（1～30）" }, { "search_count", "搜索数量（1～10）" },
        { "timeout", "请求超时秒数（5～120）" },
    }
    local items, settings_menu = {}
    local function refresh()
        UIManager:close(settings_menu)
        self:settings()
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
    settings_menu = self:menu("知乎设置", items)
end

return UI
