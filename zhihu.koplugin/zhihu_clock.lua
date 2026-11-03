-- 标题栏时钟：创建时立即显示当前时间，之后每分钟刷新，关闭页面时停止。
local UIManager = require("ui/uimanager")
local Clock = {}
Clock.INTERVAL = 60

function Clock.time()
    return os.date("%H:%M")
end

-- setter 接收当前时间字符串；返回停止函数。
function Clock.start(setter)
    local stopped = false
    local function tick()
        if stopped then return end
        setter(Clock.time())
        UIManager:scheduleIn(Clock.INTERVAL, tick)
    end
    setter(Clock.time())
    UIManager:scheduleIn(Clock.INTERVAL, tick)
    return function()
        stopped = true
        UIManager:unschedule(tick)
    end
end

return Clock
