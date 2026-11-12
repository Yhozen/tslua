local logging = require("tslua.project.logging")
local core = require("tslua.core")

-- LogCollector: a Logger with String().
local logCollector = setmetatable({}, { __index = logging.logger })
logCollector.__index = logCollector
logging.logCollector = logCollector

function logCollector:String()
    return self.builder:String()
end

function logging.NewTestLogger()
    local builder = core.NewStringBuilder()
    return setmetatable({
        isNil = false,
        verbose = false,
        writer = builder,
        prefix = function()
            return logging.formatTime(1349085672)
        end,
        builder = builder,
    }, logCollector)
end
