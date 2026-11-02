-- Bounded JSON reads and atomic replacement; never log file contents or errors.
local JSON = require("json")
local Storage = {}
Storage.MAX_BYTES = 4 * 1024 * 1024

function Storage.read(path)
    local file = io.open(path, "rb")
    if not file then return nil, "missing" end
    local content = file:read(Storage.MAX_BYTES + 1)
    file:close()
    if not content or #content > Storage.MAX_BYTES then return nil, "size" end
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then return nil, "format" end
    return data
end

function Storage.write(path, data)
    local ok, content = pcall(JSON.encode, data)
    if not ok or type(content) ~= "string" or #content > Storage.MAX_BYTES then
        return nil, "encode"
    end
    local file = io.open(path .. ".tmp", "wb")
    if not file then return nil, "write" end
    local written = file:write(content)
    local closed = file:close()
    if not written or not closed then
        os.remove(path .. ".tmp")
        return nil, "write"
    end
    -- On the target Linux device rename replaces the old file atomically.
    if not os.rename(path .. ".tmp", path) then
        os.remove(path .. ".tmp")
        return nil, "rename"
    end
    return true
end

return Storage
