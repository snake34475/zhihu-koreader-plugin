-- 回答摘要阅读页：侧边竖向高频按钮、可反转左右、正文可上下滚动、左右滑动切回答。
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Clock = require("zhihu_clock")

local Screen = Device.screen
local Reader = InputContainer:extend{
    title = "",
    subtitle = "",
    text = "",
    side = "left",
    actions = nil,
    on_prev = nil,
    on_next = nil,
    on_side_change = nil,
}

function Reader:init()
    self.screen_w, self.screen_h = Screen:getWidth(), Screen:getHeight()
    self.region = Geom:new{ w = self.screen_w, h = self.screen_h }
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.region } },
            -- 吞掉按钮之外的点击和长按，避免穿透到下层列表，造成“点了没反应”。
            Tap = { GestureRange:new{ ges = "tap", range = self.region } },
            Hold = { GestureRange:new{ ges = "hold", range = self.region } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.region } },
        }
    end
    self:build()
end

function Reader:subtitle_text()
    local time = Clock.time()
    return self.subtitle ~= "" and (time .. " · " .. self.subtitle) or time
end

function Reader:startClock()
    if self.stop_clock then self.stop_clock() end
    self.stop_clock = Clock.start(function()
        if self.titlebar then self.titlebar:setSubTitle(self:subtitle_text()) end
    end)
end

local function page_scroll(widget, direction)
    local text = widget.text_widget
    local lines = math.max(1, (text:getVisLineCount() or 1) - 1)
    text:scrollLines(direction * lines)
    widget:updateScrollBar(true)
end

function Reader:build(top_line)
    local screen_w, screen_h = self.screen_w, self.screen_h
    local side_width = math.min(math.max(math.floor(screen_w * 0.2), Screen:scaleBySize(60)), Screen:scaleBySize(120))
    local padding, margin = Size.padding.large, Size.margin.small

    self.titlebar = TitleBar:new{
        width = screen_w, align = "left", with_bottom_line = true,
        title = self.title, subtitle = self:subtitle_text(),
        title_shrink_font_to_fit = true,
        close_callback = function() UIManager:close(self) end,
        show_parent = self,
    }
    self.actions_table = ButtonTable:new{
        width = screen_w, buttons = self.actions or {},
        zero_sep = true, show_parent = self,
    }
    local body_h = screen_h - self.titlebar:getHeight() - self.actions_table:getSize().h
    local text_h = math.max(body_h - 2 * (padding + margin), Screen:scaleBySize(40))

    local side_buttons = {
        { text = "上一条", enabled = self.on_prev ~= nil, callback = function() if self.on_prev then self.on_prev() end end },
        { text = "下一条", enabled = self.on_next ~= nil, callback = function() if self.on_next then self.on_next() end end },
        { text = "反转", enabled = true, callback = function() self:toggleSide() end },
    }
    local slot = math.floor(body_h / #side_buttons)
    local column = VerticalGroup:new{ align = "center" }
    self.buttons = {}
    for index, item in ipairs(side_buttons) do
        local button = Button:new{
            text = item.text, width = side_width,
            height = math.max(slot - 2 * margin, Screen:scaleBySize(36)),
            enabled = item.enabled, callback = item.callback,
            show_parent = self,
        }
        column[#column + 1] = button
        local name = index == 1 and "prev" or index == 2 and "next" or "flip"
        self.buttons[name] = button
    end

    local content_width = screen_w - side_width
    self.scroll_widget = ScrollTextWidget:new{
        text = self.text,
        top_line_num = top_line,
        face = Font:getFace("x_smallinfofont", 22),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = content_width - 2 * (padding + margin),
        height = text_h,
        dialog = self,
        scroll_by_pan = true,
        alignment = "left",
    }
    -- 上下滑动整屏滚动；左右滑动交给阅读页切换回答。
    self.scroll_widget.onScrollText = function(widget, _, ges)
        if ges.direction == "north" then page_scroll(widget, 1) return true end
        if ges.direction == "south" then page_scroll(widget, -1) return true end
        return false
    end

    local textw = FrameContainer:new{ padding = padding, margin = margin, bordersize = 0, self.scroll_widget }
    local body = HorizontalGroup:new{ align = "top" }
    if self.side == "right" then
        body[1], body[2] = textw, column
    else
        body[1], body[2] = column, textw
    end

    self.frame = FrameContainer:new{
        radius = Size.radius.window, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ self.titlebar, body, self.actions_table },
    }
    self[1] = WidgetContainer:new{ align = "center", dimen = self.region, self.frame }
    self:startClock()
end

function Reader:toggleSide()
    self.side = self.side == "right" and "left" or "right"
    if self.on_side_change then self.on_side_change(self.side) end
    local top_line = self.scroll_widget and self.scroll_widget.text_widget
        and self.scroll_widget.text_widget.virtual_line_num or 1
    if self.stop_clock then self.stop_clock() self.stop_clock = nil end
    self[1] = nil
    self.titlebar, self.scroll_widget, self.frame = nil, nil, nil
    self:build(top_line)
    UIManager:setDirty(self, "ui")
    return self
end

function Reader:onSwipe(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" and self.on_next then
        self.on_next()
        return true
    end
    if direction == "east" and self.on_prev then
        self.on_prev()
        return true
    end
    -- 其余方向也留在阅读页，避免滑动穿透到下层列表。
    return true
end

function Reader:onTap(_, ges)
    return true
end

function Reader:onHold()
    return true
end

function Reader:onHoldRelease()
    return true
end

function Reader:onCloseWidget()
    logger.info("zhihu reader: onCloseWidget")
    if self.stop_clock then self.stop_clock() self.stop_clock = nil end
end

return Reader
