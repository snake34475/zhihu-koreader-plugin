local Renderer = {}
local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function utf8(number)
    if not number or number < 1 or number > 0x10FFFF or (number >= 0xD800 and number <= 0xDFFF) then return "" end
    if number < 0x80 then return string.char(number) end
    if number < 0x800 then return string.char(0xC0 + math.floor(number / 64), 0x80 + number % 64) end
    if number < 0x10000 then
        return string.char(0xE0 + math.floor(number / 4096), 0x80 + math.floor(number / 64) % 64, 0x80 + number % 64)
    end
    return string.char(0xF0 + math.floor(number / 262144), 0x80 + math.floor(number / 4096) % 64,
        0x80 + math.floor(number / 64) % 64, 0x80 + number % 64)
end

function Renderer.text(value)
    if type(value) ~= "string" then return "" end
    -- Rendering is plain text: no external resources or executable markup.
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    value = value:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
        :gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>", "")
        :gsub("<[bB][rR]%s*/?>", "\n"):gsub("</[pP]%s*>", "\n\n")
        :gsub("</[dD][iI][vV]%s*>", "\n"):gsub("</[lL][iI]%s*>", "\n")
        :gsub("<[^>]+>", "")
    value = value:gsub("&#[xX]([%da-fA-F]+);", function(n) return utf8(tonumber(n, 16)) end)
        :gsub("&#(%d+);", function(n) return utf8(tonumber(n)) end)
        :gsub("&(%a+);", function(n) return entities[n] or "&" .. n .. ";" end)
    value = value:gsub("!%[([^%]]*)%]%([^%)]+%)", "[图片：%1]")
        :gsub("%[([^%]]+)%]%((https?://[^%)]+)%)", "%1（%2）")
        :gsub("```[^\n]*\n", ""):gsub("```", "")
        :gsub("^#+%s+", ""):gsub("\n#+%s+", "\n")
        :gsub("%*%*([^*]+)%*%*", "%1")
        :gsub("[%z\1-\8\11\12\14-\31]", "")
        :gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
    return value:match("^%s*(.-)%s*$")
end

function Renderer.preview(value, maximum)
    local text = Renderer.text(value):gsub("%s+", " ")
    local limit, index, count = maximum or 64, 1, 0
    while index <= #text and count < limit do
        local byte = text:byte(index)
        index = index + (byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4)
        count = count + 1
    end
    return index <= #text and text:sub(1, index - 1) .. "…" or text
end

function Renderer.summary(item)
    local lines = { item.title }
    if item.author ~= "" then lines[#lines + 1] = "作者：" .. item.author end
    if item.time ~= "" then lines[#lines + 1] = "时间：" .. item.time end
    lines[#lines + 1] = "\n" .. (item.summary ~= "" and item.summary or "接口未提供摘要。")
    return table.concat(lines, "\n")
end

function Renderer.detail(item)
    return Renderer.summary(item) .. "\n\n来源：" .. (item.url ~= "" and item.url or "未提供链接")
        .. "\n以上为开放平台返回的摘要，不代表原文全文。"
end

return Renderer
