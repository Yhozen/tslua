local logging = require("tslua.project.logging")
local collections = require("tslua.collections")

-- Logger interface: Error/Errorf/Warn/Warnf/Info/Infof/Log/Logf, Verbose() (Logger or nil),
-- IsVerbose(), SetVerbose(verbose). Implemented by logger (below) and LogTree.

-- fmtValue formats v like Go's %v for the values the project package logs.
function logging.fmtValue(v)
    local tv = type(v)
    if v == nil then
        return "<nil>"
    elseif tv == "string" then
        return v
    elseif tv == "number" then
        if math.type(v) == "integer" then
            return tostring(v)
        end
        if v == math.floor(v) and v > -1e15 and v < 1e15 then
            return string.format("%d", math.floor(v))
        end
        return string.format("%g", v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "table" then
        if type(v.Error) == "function" then
            return v:Error()
        end
        if type(v.String) == "function" then
            return v:String()
        end
        if getmetatable(v) == collections.Set then
            -- Go prints a Set value as its struct: {map[k:{} ...]} with sorted keys.
            local keys = {}
            for k in pairs(v.m or {}) do
                keys[#keys + 1] = logging.fmtValue(k)
            end
            table.sort(keys)
            for i, k in ipairs(keys) do
                keys[i] = k .. ":{}"
            end
            return "{map[" .. table.concat(keys, " ") .. "]}"
        end
        local parts = {}
        for i, e in ipairs(v) do
            parts[i] = logging.fmtValue(e)
        end
        return "[" .. table.concat(parts, " ") .. "]"
    end
    return tostring(v)
end

-- Sprint is Go's fmt.Sprint: operands are concatenated, with a space between operands when
-- neither is a string.
function logging.Sprint(...)
    local n = select("#", ...)
    local parts = {}
    local prevString = true
    for i = 1, n do
        local v = select(i, ...)
        local isString = type(v) == "string"
        if i > 1 and not isString and not prevString then
            parts[#parts + 1] = " "
        end
        parts[#parts + 1] = logging.fmtValue(v)
        prevString = isString
    end
    return table.concat(parts)
end

-- Sprintf is Go's fmt.Sprintf for the verbs used by the project package: %v %s %d %q %%, with an
-- optional width for %d (e.g. %6d).
function logging.Sprintf(format, ...)
    local args = table.pack(...)
    local argIndex = 0
    return (string.gsub(format, "%%(%-?%d*)([%%vsdq])", function(width, verb)
        if verb == "%" then
            return "%"
        end
        argIndex = argIndex + 1
        local v = args[argIndex]
        local s
        if verb == "d" and type(v) == "number" then
            s = string.format("%d", math.tointeger(v) or math.floor(v))
        elseif verb == "q" and type(v) == "string" then
            s = string.format("%q", v)
        else
            s = logging.fmtValue(v)
        end
        if width ~= "" then
            s = string.format("%" .. width .. "s", s)
        end
        return s
    end))
end

-- Writers are tables with Write(s), or core.StringBuilder-like objects with WriteString(s).
local function write(w, s)
    if w.WriteString ~= nil then
        w:WriteString(s)
    else
        w:Write(s)
    end
end

-- logger: { verbose, writer, prefix = func() string }. A nil logger (NewNopLogger) is represented
-- by a logger with isNil = true, on which every method is a no-op like Go's nil receiver.
local logger = {}
logger.__index = logger
logging.logger = logger

function logger:Log(...)
    if self.isNil then
        return
    end
    write(self.writer, self.prefix() .. " " .. logging.Sprint(...) .. "\n")
end

function logger:Logf(format, ...)
    if self.isNil then
        return
    end
    write(self.writer, self.prefix() .. " " .. logging.Sprintf(format, ...) .. "\n")
end

function logger:Verbose()
    if self.isNil then
        return nil
    end
    if not self.verbose then
        return nil
    end
    return self
end

function logger:IsVerbose()
    if self.isNil then
        return false
    end
    return self.verbose
end

function logger:SetVerbose(verbose)
    if self.isNil then
        return
    end
    self.verbose = verbose
end

function logger:Error(...)
    self:Log(...)
end

function logger:Errorf(format, ...)
    self:Logf(format, ...)
end

function logger:Warn(...)
    self:Log(...)
end

function logger:Warnf(format, ...)
    self:Logf(format, ...)
end

function logger:Info(...)
    self:Log(...)
end

function logger:Infof(format, ...)
    self:Logf(format, ...)
end

function logging.NewLogger(output)
    return setmetatable({
        isNil = false,
        verbose = false,
        writer = output,
        prefix = function()
            return logging.formatTime(logging.timeNow())
        end,
    }, logger)
end

-- NewNopLogger returns a no-op Logger that discards all log messages.
-- It is safe to call any method on the returned Logger.
function logging.NewNopLogger()
    return setmetatable({ isNil = true, verbose = false }, logger)
end

-- Times are seconds since the Unix epoch (possibly fractional).
function logging.timeNow()
    return os.time()
end

function logging.formatTime(t)
    local secs = math.floor(t)
    local millis = math.floor((t - secs) * 1000)
    return "[" .. os.date("%H:%M:%S", secs) .. string.format(".%03d", millis) .. "]"
end
