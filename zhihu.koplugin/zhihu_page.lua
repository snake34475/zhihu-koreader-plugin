-- A full-screen paginated Menu with a persistent title and action toolbar.
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local ButtonTable = require("ui/widget/buttontable")
local VerticalGroup = require("ui/widget/verticalgroup")
local Clock = require("zhihu_clock")
local Page = {}

function Page.new(options)
    local menu
    local base_subtitle = options.subtitle or ""
    local function subtitle()
        return base_subtitle ~= "" and (Clock.time() .. " · " .. base_subtitle) or Clock.time()
    end
    local title = TitleBar:new{
        width = options.width, title = options.title, subtitle = subtitle(),
        title_shrink_font_to_fit = true,
        close_callback = function() if menu then menu:onClose() end end,
    }
    local toolbar = ButtonTable:new{ width = options.width, buttons = options.buttons, zero_sep = true }
    local header = VerticalGroup:new{ align = "left", title, toolbar }
    function header:getHeight() return self:getSize().h end
    function header:setTitle(...) return title:setTitle(...) end
    function header:setSubTitle(...) return title:setSubTitle(...) end
    function header:setLeftIcon(...) return title:setLeftIcon(...) end
    function header:generateVerticalLayout()
        local rows = title:generateVerticalLayout()
        for _, row in ipairs(toolbar.layout or {}) do rows[#rows + 1] = row end
        return rows
    end
    options.custom_title_bar = header
    options.buttons = nil
    local close_callback, stop_clock = options.close_callback, nil
    options.close_callback = function()
        if stop_clock then stop_clock() stop_clock = nil end
        if close_callback then close_callback() end
    end
    menu = Menu:new(options)
    local menu_on_close_widget = menu.onCloseWidget
    function menu:onCloseWidget()
        if stop_clock then stop_clock() stop_clock = nil end
        if menu_on_close_widget then return menu_on_close_widget(self) end
    end
    stop_clock = Clock.start(function() title:setSubTitle(subtitle()) end)
    title.show_parent, toolbar.show_parent = menu, menu
    return menu
end

return Page
