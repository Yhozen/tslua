-- Lua-only helpers for the sequential port of the project package (no Go counterpart file).
local project = require("tslua.project")
local collections = require("tslua.collections")
local xxh3 = require("tslua.xxh3")
local lsproto = require("tslua.lsp.lsproto")

-- Hashes (Go xxh3.Uint128) are represented by their 32-digit hex string; the zero hash is "".
function project.hashString(s)
    return xxh3.HashString128(s):Hex()
end

-- hashLittleEndianBytes returns the 16 bytes of binary.LittleEndian.PutUint64(Hi) followed by
-- binary.LittleEndian.PutUint64(Lo) for a hex hash.
function project.hashLittleEndianBytes(hex)
    if hex == "" then
        return string.rep("\0", 16)
    end
    local hi = tonumber(string.sub(hex, 1, 8), 16) << 32 | tonumber(string.sub(hex, 9, 16), 16)
    local lo = tonumber(string.sub(hex, 17, 24), 16) << 32 | tonumber(string.sub(hex, 25, 32), 16)
    return string.pack("<i8<i8", hi, lo)
end

-- Time values are seconds (float, see project.now); durations are seconds wrapped in a Duration
-- so that %v formats them like Go's time.Duration.

local Duration = {}
Duration.__index = Duration
project.Duration = Duration

function project.since(start)
    return setmetatable({ seconds = project.now() - start }, Duration)
end

local function trimFloat(v)
    local s = string.format("%.3f", v)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    return s
end

-- String formats like Go's time.Duration.String (rounded to microseconds).
function Duration:String()
    local s = self.seconds
    if s == 0 then
        return "0s"
    elseif s < 1e-3 then
        return trimFloat(s * 1e6) .. "µs"
    elseif s < 1 then
        return trimFloat(s * 1e3) .. "ms"
    end
    return trimFloat(s) .. "s"
end

-- newFileChangeSummary returns the zero FileChangeSummary.
function project.newFileChangeSummary()
    return {
        opened = "",
        reopened = "",
        closed = collections.NewSet(),
        changed = collections.NewSet(),
        created = collections.NewSet(),
        deleted = collections.NewSet(),
        includesWatchChangeOutsideNodeModules = false,
        invalidateAll = false,
    }
end

-- copyFileChangeSummary copies a FileChangeSummary value (Go struct copy; the sets are shared
-- like Go's map-backed Set values).
function project.copyFileChangeSummary(f)
    local c = {}
    for k, v in pairs(f) do
        c[k] = v
    end
    return c
end

-- setKeys returns the keys of a collections.Set (nil-safe) for iteration with pairs.
function project.setKeys(s)
    if s == nil then
        return {}
    end
    return collections.Set.Keys(s) or {}
end

-- sortedKeys returns the keys of a Lua table, sorted.
function project.sortedKeys(m)
    local keys = {}
    for k in pairs(m or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- mapLen returns len(m) for a Go map (nil-safe).
function project.mapLen(m)
    local n = 0
    for _ in pairs(m or {}) do
        n = n + 1
    end
    return n
end

function project.cloneMap(m)
    if m == nil then
        return nil
    end
    local c = {}
    for k, v in pairs(m) do
        c[k] = v
    end
    return c
end

function project.mapsEqual(a, b)
    for k, v in pairs(a or {}) do
        if b == nil or b[k] ~= v then
            return false
        end
    end
    for k in pairs(b or {}) do
        if a == nil or a[k] == nil then
            return false
        end
    end
    return true
end

function project.slicesEqual(a, b)
    local na, nb = a ~= nil and #a or 0, b ~= nil and #b or 0
    if na ~= nb then
        return false
    end
    for i = 1, na do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- sortedCompact is slices.Compact(slices.Sorted(values)).
function project.sortedCompact(values)
    local sorted = {}
    for i, v in ipairs(values or {}) do
        sorted[i] = v
    end
    table.sort(sorted)
    local result = {}
    for _, v in ipairs(sorted) do
        if #result == 0 or result[#result] ~= v then
            result[#result + 1] = v
        end
    end
    return result
end

-- hasRelativePatternSupport reads
-- lsproto.GetClientCapabilities(ctx).Workspace.DidChangeWatchedFiles.RelativePatternSupport.
function project.hasRelativePatternSupport(ctx)
    local caps = lsproto.GetClientCapabilities(ctx)
    local workspace = caps ~= nil and caps.workspace or nil
    local didChangeWatchedFiles = workspace ~= nil and workspace.didChangeWatchedFiles or nil
    return didChangeWatchedFiles ~= nil and didChangeWatchedFiles.relativePatternSupport == true
end

-- Clock and timers (Go time.Now / time.AfterFunc). Timers never fire on their own in the
-- sequential port: with a fake clock (tests, like Go's synctest), AdvanceFakeTime fires the timers
-- that became due; with the real clock, RunDueTimers fires them.
project.clock = { fake = false, now = 0, timers = {} }

function project.UseFakeClock()
    project.clock = { fake = true, now = 0, timers = {} }
end

function project.UseRealClock()
    project.clock = { fake = false, now = 0, timers = {} }
end

local Timer = {}
Timer.__index = Timer
project.Timer = Timer

-- afterFunc is Go's time.AfterFunc(delay, fn).
function project.afterFunc(delay, fn)
    local t = setmetatable({ deadline = project.now() + delay, fn = fn, stopped = false }, Timer)
    local timers = project.clock.timers
    timers[#timers + 1] = t
    return t
end

function Timer:Stop()
    local wasActive = not self.stopped
    self.stopped = true
    return wasActive
end

function Timer:Reset(delay)
    local wasActive = not self.stopped
    self.stopped = false
    self.deadline = project.now() + delay
    local timers = project.clock.timers
    local found = false
    for _, t in ipairs(timers) do
        if t == self then
            found = true
        end
    end
    if not found then
        timers[#timers + 1] = self
    end
    return wasActive
end

-- now returns the current time in seconds.
function project.now()
    if project.clock.fake then
        return project.clock.now
    end
    return os.clock()
end

-- RunDueTimers fires (in deadline order) every active timer whose deadline has passed.
function project.RunDueTimers()
    while true do
        local now = project.now()
        local due, dueIndex = nil, nil
        for i, t in ipairs(project.clock.timers) do
            if not t.stopped and t.deadline <= now and (due == nil or t.deadline < due.deadline) then
                due, dueIndex = t, i
            end
        end
        if due == nil then
            return
        end
        table.remove(project.clock.timers, dueIndex)
        due.stopped = true
        due.fn()
    end
end

-- AdvanceFakeTime moves the fake clock forward by d seconds, firing due timers on the way.
function project.AdvanceFakeTime(d)
    local target = project.clock.now + d
    while true do
        local nextTimer = nil
        for _, t in ipairs(project.clock.timers) do
            if not t.stopped and t.deadline <= target and (nextTimer == nil or t.deadline < nextTimer.deadline) then
                nextTimer = t
            end
        end
        if nextTimer == nil then
            break
        end
        if nextTimer.deadline > project.clock.now then
            project.clock.now = nextTimer.deadline
        end
        project.RunDueTimers()
    end
    project.clock.now = target
end

-- onceFunc is Go's sync.OnceFunc.
function project.onceFunc(f)
    local done = false
    return function()
        if done then
            return
        end
        done = true
        f()
    end
end

-- strings.HasPrefix / strings.HasSuffix / strings.Contains / strings.LastIndexByte.
function project.hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function project.hasSuffix(s, suffix)
    return suffix == "" or string.sub(s, -#suffix) == suffix
end

function project.contains(s, substr)
    return string.find(s, substr, 1, true) ~= nil
end

-- lastIndexByte returns the 0-based index of the last occurrence of the byte c, or -1.
function project.lastIndexByte(s, c)
    local b = string.byte(c)
    for i = #s, 1, -1 do
        if string.byte(s, i) == b then
            return i - 1
        end
    end
    return -1
end

-- Go errors: tables with Error() (and Unwrap() for %w wrapping, compatible with errors.Is walkers).
local errorValue = {}
errorValue.__index = errorValue
project.errorValue = errorValue

function errorValue:Error()
    return self.msg
end

function errorValue:Unwrap()
    return self.wrapped
end

errorValue.__tostring = errorValue.Error

-- newError is errors.New.
function project.newError(msg)
    return setmetatable({ msg = msg, wrapped = nil }, errorValue)
end

-- errorf is fmt.Errorf; a %w operand is wrapped (and formatted like %v).
function project.errorf(format, ...)
    local logging = require("tslua.project.logging")
    local args = table.pack(...)
    local wrapped = nil
    local argIndex = 0
    for verb in string.gmatch(format, "%%%-?%d*([%%vsdqw])") do
        if verb ~= "%" then
            argIndex = argIndex + 1
            if verb == "w" then
                wrapped = args[argIndex]
            end
        end
    end
    local msg = logging.Sprintf((string.gsub(format, "%%w", "%%v")), ...)
    return setmetatable({ msg = msg, wrapped = wrapped }, errorValue)
end
