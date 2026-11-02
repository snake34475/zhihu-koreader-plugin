local passed = 0

function test(name, callback)
    local ok, err = pcall(callback)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err)) end
    passed = passed + 1
    print("PASS " .. name)
end

function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

function fixture(name)
    local file = assert(io.open(plugin_root .. "/tests/fixtures/" .. name .. ".json", "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

function write(path, text)
    local file = assert(io.open(path, "wb"))
    assert(file:write(text))
    assert(file:close())
end

dofile(plugin_root .. "/tests/test_schema.lua")
dofile(plugin_root .. "/tests/test_api.lua")
dofile(plugin_root .. "/tests/test_storage.lua")
dofile(plugin_root .. "/tests/test_questions.lua")
dofile(plugin_root .. "/tests/test_ui.lua")
print(string.format("%d tests passed in %s (%s)", passed, jit.version, jit.arch))
