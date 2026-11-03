local JSON = require("json")
local Config = require("zhihu_config")
local Schema = require("zhihu_schema")
local Errors = require("zhihu_errors")
local API = {}
API.__index = API
API.MAX_RESPONSE_BYTES = 1024 * 1024

local function encode_query(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Uses KOReader's LuaSocket/LuaSec stack. Redirects are disabled so credentials
-- cannot be forwarded to an address supplied by a response.
function API.transport(request, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local chunks, size, sink_error = {}, 0, nil
    local started = os.time()
    request.redirect = false
    request.sink = function(chunk, err)
        if err then return nil, err end
        if os.time() - started >= timeout then
            sink_error = "timeout"
            return nil, "timeout"
        end
        if chunk then
            size = size + #chunk
            if size > API.MAX_RESPONSE_BYTES then
                sink_error = "size"
                return nil, "size"
            end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    if request.body then
        request.source = ltn12.source.string(request.body)
        request.headers["Content-Length"] = tostring(#request.body)
        request.body = nil
    end
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    socketutil:set_timeout(timeout, timeout)
    local ok, success, status = pcall(http.request, request)
    socketutil:set_timeout(old_block, old_total)
    if sink_error then return nil, nil, sink_error end
    if not ok or not success then
        local timed_out = status == "timeout" or status == "wantread" or status == "wantwrite" or status == "sink timeout"
        return nil, nil, timed_out and "timeout" or "network"
    end
    return tonumber(status), table.concat(chunks)
end

function API.new(config, options)
    options = options or {}
    return setmetatable({ config = config, send = options.transport or API.transport,
        clock = options.clock or os.time, logger = options.logger }, API)
end

function API:request(method, path, params, body)
    local base = Config.validate("base_url", self.config:get("base_url"))
    local secret = Config.validate("access_secret", self.config:get("access_secret"))
    if not base or not secret or secret == "" then return nil, Errors.new("config") end
    local query = {}
    for key, value in pairs(params or {}) do query[#query + 1] = key .. "=" .. encode_query(value) end
    table.sort(query)
    local url = base .. path .. (#query > 0 and "?" .. table.concat(query, "&") or "")
    local request = { url = url, method = method, redirect = false, headers = {
        ["Authorization"] = "Bearer " .. secret,
        ["X-Request-Timestamp"] = tostring(math.floor(self.clock())),
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    } }
    if body then
        local encoded, content = pcall(JSON.encode, body)
        if not encoded then return nil, Errors.new("input") end
        request.body = content
    end
    local started = self.clock()
    local ok, status, content, transport_error = pcall(self.send, request,
        Config.clamp(self.config:get("timeout"), 30, 120, 5))
    if self.logger then
        -- Only numeric status and elapsed seconds leave this module.
        self.logger.info("Zhihu request", tonumber(status) or 0, math.max(0, self.clock() - started))
    end
    if not ok or not status then
        return nil, Errors.new(transport_error == "timeout" and "timeout"
            or transport_error == "size" and "size" or "network")
    end
    if type(content) ~= "string" or #content > API.MAX_RESPONSE_BYTES then return nil, Errors.new("size", status) end
    local decoded, payload = pcall(JSON.decode, content)
    local err = Errors.response(status, decoded and payload or nil)
    if err then return nil, err end
    if not decoded or type(payload) ~= "table" then return nil, Errors.new("format", status) end
    -- The only response handed to the cache/UI has already been scrubbed.
    return Errors.scrub(payload, secret)
end

function API:hot_list()
    local limit = Config.clamp(self.config:get("hot_limit"), 30, 30)
    local raw, err = self:request("GET", "/api/v1/content/hot_list", { Limit = limit })
    if not raw then return nil, err end
    local result = Schema.list(raw, limit)
    if not result then return nil, Errors.new("format") end
    return result, nil, raw
end

local function nonempty(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

function API:ask(question)
    question = nonempty(question)
    if question == "" then return nil, Errors.new("input") end
    local model = Config.validate("model", self.config:get("model")) or Config.defaults.model
    local raw, err = self:request("POST", "/v1/chat/completions", nil, {
        model = model, messages = { { role = "user", content = question } }, stream = false,
    })
    if not raw then return nil, err end
    local result = Schema.answer(raw)
    if not result then return nil, Errors.new("format") end
    return result, nil, raw
end

function API:question_answers(url, offset)
    url = Schema.question_url(url)
    offset = offset or 0
    if not url or type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset)
        or offset > 9007199254740991 then return nil, Errors.new("input") end
    local limit = 10
    local raw, err = self:request("GET", "/api/v1/content/question_answers", {
        QuestionUrl = url, Offset = offset, Limit = limit,
    })
    if not raw then return nil, err end
    local result = Schema.question_answers(raw, offset, limit)
    if not result then return nil, Errors.new("format") end
    return result, nil, raw
end

return API
