local ipc = require("tslua.ipc")
local json = require("tslua.json")

-- Method names for the generic connection-level timing feature, handled by the connection itself rather
-- than the handler when timing collection is enabled.
ipc.MethodGetServerTiming = "getServerTiming"
ipc.MethodResetServerTiming = "resetServerTiming"

-- serverRecentRequestCapacity is the number of most-recent requests retained in
-- the server-side timing ring buffer.
ipc.serverRecentRequestCapacity = 5

-- now returns the current time in seconds (time.Now stand-in).
function ipc.now()
    return os.clock()
end

-- serverRequestTiming is a single server-side request's processing-time sample:
-- { method, processingTimeMs, timestamp }.
local function marshalRequestTiming(t)
    local ms, err = json.Marshal(t.processingTimeMs + 0.0)
    if err ~= nil then
        return nil, err
    end
    return '{"method":' .. json.QuoteString(t.method) .. ',"processingTimeMs":' .. ms .. ',"timestamp":' .. string.format("%d", t.timestamp) .. "}", nil
end

-- serverTimingInfo is a point-in-time snapshot of collected server timing,
-- returned to clients in response to a getServerTiming request.
local serverTimingInfo = {}
serverTimingInfo.__index = serverTimingInfo

function serverTimingInfo:MarshalJSON()
    local total, err = json.Marshal(self.totals.totalProcessingTimeMs + 0.0)
    if err ~= nil then
        return nil, err
    end
    local recent = {}
    for i, t in ipairs(self.recentRequests) do
        local raw, rerr = marshalRequestTiming(t)
        if rerr ~= nil then
            return nil, rerr
        end
        recent[i] = raw
    end
    return '{"enabled":' .. tostring(self.enabled) ..
        ',"totals":{"requestCount":' .. string.format("%d", self.totals.requestCount) .. ',"totalProcessingTimeMs":' .. total .. "}" ..
        ',"recentRequests":[' .. table.concat(recent, ",") .. "]}", nil
end

-- timingCollector accumulates per-request server processing times into running
-- totals and a fixed-size ring buffer of the most recent requests.
local timingCollector = {}
timingCollector.__index = timingCollector
ipc.timingCollector = timingCollector

function ipc.newTimingCollector()
    return setmetatable({ totals = { requestCount = 0, totalProcessingTimeMs = 0 }, ring = {}, head = 0 }, timingCollector)
end

-- record adds a single request's processing time (seconds) to the totals and ring buffer.
function timingCollector:record(method, d)
    local processingMs = ipc.durationToMillis(d)

    self.totals = {
        requestCount = self.totals.requestCount + 1,
        totalProcessingTimeMs = self.totals.totalProcessingTimeMs + processingMs,
    }

    local entry = {
        method = method,
        processingTimeMs = processingMs,
        timestamp = math.floor(os.time() * 1000),
    }
    if #self.ring < ipc.serverRecentRequestCapacity then
        self.ring[#self.ring + 1] = entry
    else
        self.ring[self.head + 1] = entry
        self.head = (self.head + 1) % ipc.serverRecentRequestCapacity
    end
end

-- snapshot returns a copy of the currently collected timing information, with
-- recent requests ordered from oldest to newest.
function timingCollector:snapshot()
    local recent = {}
    for i = 0, #self.ring - 1 do
        recent[#recent + 1] = self.ring[(self.head + i) % #self.ring + 1]
    end
    return setmetatable({
        enabled = true,
        totals = self.totals,
        recentRequests = recent,
    }, serverTimingInfo)
end

-- reset clears all accumulated totals and recent-request history.
function timingCollector:reset()
    self.totals = { requestCount = 0, totalProcessingTimeMs = 0 }
    self.ring = {}
    self.head = 0
end

-- serverTimingSnapshot returns the collector's snapshot, or a disabled snapshot
-- when timing collection is not enabled (collector is nil).
function ipc.serverTimingSnapshot(c)
    if c == nil then
        return ipc.disabledServerTimingInfo()
    end
    return c:snapshot()
end

-- disabledServerTimingInfo is the snapshot returned when timing collection is
-- not enabled.
function ipc.disabledServerTimingInfo()
    return setmetatable({
        enabled = false,
        totals = { requestCount = 0, totalProcessingTimeMs = 0 },
        recentRequests = {},
    }, serverTimingInfo)
end

-- durationToMillis converts a duration (seconds) to fractional milliseconds, clamped to be non-negative.
function ipc.durationToMillis(d)
    if d < 0 then
        return 0
    end
    return d * 1000
end
