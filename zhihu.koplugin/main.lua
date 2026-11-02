local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local Config = require("zhihu_config")
local API = require("zhihu_api")
local Cache = require("zhihu_cache")
local ZhihuUI = require("zhihu_ui")
local lfs = require("libs/libkoreader-lfs")

local Zhihu = WidgetContainer:extend{ name = "zhihu", is_doc_only = false }

function Zhihu:init()
    self.ui.menu:registerToMainMenu(self)
end

function Zhihu:initialize()
    if self.client then return true end
    local cache_directory = DataStorage:getDataDir() .. "/zhihu-cache"
    if not lfs.attributes(cache_directory, "mode") and not lfs.mkdir(cache_directory) then
        ZhihuUI.message("无法创建知乎缓存目录，请检查数据目录权限和空间。")
        return false
    end
    self.config = Config.open(DataStorage:getSettingsDir() .. "/zhihu_configuration.json")
    self.api = API.new(self.config, { logger = require("logger") })
    self.cache = Cache.new(cache_directory, function() return self.config:get("access_secret") end)
    self.client = ZhihuUI.new(self.config, self.api, self.cache, self.ui)
    if self.config.load_error then ZhihuUI.message("配置文件损坏，当前使用默认配置；缓存仍可读取。") end
    return true
end

function Zhihu:addToMainMenu(menu_items)
    menu_items.zhihu = {
        text = "知乎",
        sorting_hint = "tools",
        callback = function()
            if not self:initialize() then return end
            self.client:home()
        end,
    }
end

return Zhihu
