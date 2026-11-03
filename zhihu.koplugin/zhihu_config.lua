local Storage = require("zhihu_storage")
local Config = {}
Config.__index = Config
Config.defaults = {
    base_url = "https://developer.zhihu.com",
    access_secret = "",
    hot_limit = 30,
    timeout = 30,
    model = "zhida-fast-1p5",
    reader_side = "left", -- 阅读页高频按钮列位置：left / right
    download_images = false, -- Reserved for P1; MVP never fetches images.
}
Config.models = { "zhida-fast-1p5", "zhida-thinking-1p5", "zhida-agent" }

function Config.clamp(value, fallback, maximum, minimum)
    local number = tonumber(value)
    if not number or number ~= number then number = fallback end
    return math.max(minimum or 1, math.min(maximum, math.floor(number)))
end

function Config.validate(key, value)
    if key == "base_url" then
        if type(value) ~= "string" then return nil, "请输入 HTTPS Base URL。" end
        value = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
        local authority, path = value:match("^https://([^/]+)(.*)$")
        if not authority or authority:find("[^%w%.:%-]", 1) or authority:sub(1, 1) == ":"
            or value:find("[%c%s%?#]") or path:find("//", 1, true) then
            return nil, "Base URL 必须是 HTTPS 地址，且不能含凭证、查询参数或片段。"
        end
    elseif key == "access_secret" then
        if type(value) ~= "string" then return nil, "密钥格式无效。" end
        value = value:match("^%s*(.-)%s*$")
        if value:find("[%c%s]") then return nil, "密钥不能包含空白或控制字符。" end
    elseif key == "hot_limit" or key == "timeout" then
        local maximum = key == "hot_limit" and 30 or 120
        local minimum = key == "timeout" and 5 or 1
        local number = tonumber(value)
        if not number or number ~= math.floor(number) or number < minimum or number > maximum then
            return nil, string.format("请输入 %d～%d 之间的整数。", minimum, maximum)
        end
        value = number
    elseif key == "model" then
        local found = false
        for _, model in ipairs(Config.models) do if value == model then found = true end end
        if not found then return nil, "不支持的直答模型。" end
    elseif key == "reader_side" then
        if value ~= "left" and value ~= "right" then return nil, "按钮列只能位于左侧或右侧。" end
    elseif key == "download_images" then
        if value ~= false then return nil, "图片下载将在 P1 加入，当前仅显示文字。" end
    else
        return nil, "未知配置项。"
    end
    return value
end

function Config.open(path)
    local stored, err = Storage.read(path)
    local self = setmetatable({ path = path, values = {}, load_error = err ~= "missing" and err or nil }, Config)
    for key, default in pairs(Config.defaults) do
        local value = stored and Config.validate(key, stored[key])
        if value == nil then value = default end
        self.values[key] = value
    end
    return self
end

function Config:get(key)
    return self.values[key]
end

function Config:set(key, value)
    local clean, err = Config.validate(key, value)
    if clean == nil then return nil, err end
    local updated = {}
    for name, current in pairs(self.values) do updated[name] = current end
    updated[key] = clean
    if not Storage.write(self.path, updated) then return nil, "配置写入失败，请检查数据目录空间和权限。" end
    self.values = updated
    self.load_error = nil
    return true
end

return Config
