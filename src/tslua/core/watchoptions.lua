local core = require("tslua.core")

local Tristate = core.Tristate

-- WatchOptions: interval is a nil-able integer (Go *int); excludeDir/excludeFiles nil-able arrays.
local WatchOptions = {}
WatchOptions.__index = WatchOptions
core.WatchOptions = WatchOptions

function core.NewWatchOptions(init)
    local w = setmetatable({
        interval = nil,
        fileKind = core.WatchFileKind.None,
        directoryKind = core.WatchDirectoryKind.None,
        fallbackPolling = core.PollingKind.None,
        syncWatchDir = Tristate.TSUnknown,
        excludeDir = nil,
        excludeFiles = nil,
    }, WatchOptions)
    if init ~= nil then
        for k, v in pairs(init) do
            w[k] = v
        end
    end
    return w
end

-- Returns the interval in milliseconds (Go returns a time.Duration). Callable on nil as
-- core.WatchOptions.WatchInterval(w).
function WatchOptions.WatchInterval(w)
    local watchInterval = 2000
    if w ~= nil and w.interval ~= nil then
        watchInterval = w.interval
    end
    return watchInterval
end
