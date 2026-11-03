local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local QRMessage = require("ui/widget/qrmessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local Protocol = require("protocol")

local Probe = WidgetContainer:extend{ name = "zhihu-qr-probe", is_doc_only = false }

function Probe:init()
    self.ui.menu:registerToMainMenu(self)
end

function Probe:message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Probe:stop()
    self.generation = (self.generation or 0) + 1
    self.session = nil
    local dialog = self.qr_dialog
    self.qr_dialog = nil
    if dialog then UIManager:close(dialog) end
end

function Probe:run(label, task, callback, on_error)
    local generation = self.generation
    Trapper:wrap(function()
        local loading = InfoMessage:new{ text = label .. "…\n轻触可取消" }
        UIManager:show(loading)
        UIManager:forceRePaint()
        local ok, completed, result, err = pcall(function()
            return Trapper:dismissableRunInSubprocess(function()
                local ran, value, failure = pcall(task)
                if not ran then return nil, "请求未完成" end
                return value, failure
            end, loading)
        end)
        UIManager:close(loading)
        if generation ~= self.generation then return end
        if not ok then
            if on_error then on_error("请求未完成") else self:message("请求未完成") end
            return
        end
        if not completed then self:stop() return end
        if not result then
            local message = type(err) == "table" and err.message or err or "请求未完成"
            if on_error then on_error(message) else self:message(message) end
            return
        end
        callback(result)
    end)
end

function Probe:poll(generation)
    if generation ~= self.generation or not self.session or not self.qr_dialog then return end
    if os.time() * 1000 >= self.session.expires_at then
        self:stop()
        self:message("二维码已过期，请重新打开实验入口。")
        return
    end
    local session = self.session
    self:run("查询扫码状态", function() return Protocol.poll(session) end, function(result)
        if generation ~= self.generation or not self.qr_dialog then return end
        self.session.jar = result.jar
        if result.confirmed then
            local confirmed_session = { jar = result.jar }
            self:run("校验知乎账号会话", function()
                return Protocol.verify_session(confirmed_session)
            end, function(verified)
                self:stop()
                self:message("扫码已确认，知乎账号接口校验通过：" .. verified.user.name
                    .. "。凭证只留在本次试验内存中，不会保存。")
            end, function(message)
                self:stop()
                self:message("手机已确认，但知乎账号接口未能校验会话：" .. message
                    .. "。本实验不会将扫码确认当作登录成功。")
            end)
            return
        end
        UIManager:scheduleIn(3, function() self:poll(generation) end)
    end, function(err)
        self:stop()
        self:message(err)
    end)
end

function Probe:start()
    self:stop()
    local generation = self.generation
    NetworkMgr:runWhenConnected(function()
        if generation ~= self.generation then return end
        self:run("获取知乎登录二维码", Protocol.create, function(session)
            if generation ~= self.generation then return end
            self.session = session
            local dialog
            dialog = QRMessage:new{
                text = session.link,
                dismiss_callback = function()
                    if self.qr_dialog == dialog then self:stop() end
                end,
            }
            self.qr_dialog = dialog
            UIManager:show(dialog)
            UIManager:scheduleIn(3, function() self:poll(generation) end)
        end)
    end)
end

function Probe:addToMainMenu(items)
    items.zhihu_qr_probe = {
        text = "知乎扫码实验（不保存登录）",
        sorting_hint = "tools",
        callback = function() self:start() end,
    }
end

return Probe
