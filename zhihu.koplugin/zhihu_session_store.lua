-- Optional persistent Zhihu login session. The file is plaintext but restricted
-- to the KOReader user; it is separate from plugin code, config, and content cache.
local JSON = require("json")
local Store = {}
Store.__index = Store
Store.MAX_BYTES = 24 * 1024
local COOKIE_NAMES = { _xsrf = true, _zap = true, d_c0 = true, BEC = true, sec_token = true, z_c0 = true }
local PRIVATE_MODE = 384 -- 0600

local function chmod_private(path)
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    pcall(ffi.cdef, "int chmod(const char *pathname, unsigned int mode);")
    local called, result = pcall(function() return ffi.C.chmod(path, PRIVATE_MODE) end)
    return called and result == 0
end

local function clean_jar(jar)
    if type(jar) ~= "table" then return nil end
    local clean = {}
    for name, value in pairs(jar) do
        if COOKIE_NAMES[name] and type(value) == "string" and value ~= ""
            and #value <= 4096 and not value:find("[%c;]") then
            clean[name] = value
        end
    end
    if not clean.z_c0 then return nil end
    return clean
end

function Store.new(path, clock)
    return setmetatable({ path = path, clock = clock or os.time }, Store)
end

function Store:save(session)
    local jar = type(session) == "table" and clean_jar(session.jar)
    if not jar then return nil, "format" end
    local ok, encoded = pcall(JSON.encode, { version = 1, saved_at = self.clock(), jar = jar })
    if not ok or type(encoded) ~= "string" or #encoded > Store.MAX_BYTES then return nil, "encode" end

    local temporary = self.path .. ".tmp"
    os.remove(temporary)
    local file = io.open(temporary, "wb")
    if not file then return nil, "write" end
    if not chmod_private(temporary) then
        file:close()
        os.remove(temporary)
        return nil, "permissions"
    end
    local written = file:write(encoded)
    local closed = file:close()
    if not written or not closed or not os.rename(temporary, self.path) then
        os.remove(temporary)
        return nil, "write"
    end
    if not chmod_private(self.path) then
        os.remove(self.path)
        return nil, "permissions"
    end
    return true
end

function Store:load()
    local file = io.open(self.path, "rb")
    if not file then return nil, "missing" end
    if not chmod_private(self.path) then
        file:close()
        os.remove(self.path)
        return nil, "permissions"
    end
    local content = file:read(Store.MAX_BYTES + 1)
    file:close()
    if type(content) ~= "string" or #content > Store.MAX_BYTES then
        os.remove(self.path)
        return nil, "size"
    end
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" or data.version ~= 1 then
        os.remove(self.path)
        return nil, "format"
    end
    local jar = clean_jar(data.jar)
    if not jar then
        os.remove(self.path)
        return nil, "format"
    end
    return { jar = jar }, nil, tonumber(data.saved_at)
end

function Store:has_saved()
    local file = io.open(self.path, "rb")
    if not file then return false end
    file:close()
    return true
end

function Store:clear()
    local ok = os.remove(self.path)
    os.remove(self.path .. ".tmp")
    return ok ~= nil
end

return Store
