local tsc = require("tslua.execute.tsc")
local compiler = require("tslua.compiler")

-- tableRow: { name, value }
local statTable = {}
statTable.__index = statTable
tsc.statTable = statTable

local function newTable()
    return setmetatable({ rows = {} }, statTable)
end

-- Values marked as durations (float seconds) are formatted with formatDuration.
local Duration = {}
Duration.__index = Duration
function tsc.Duration(seconds)
    return setmetatable({ seconds = seconds }, Duration)
end

-- fmt.Sprint of the (integer or string) table values.
local function sprint(value)
    return tostring(value)
end

function statTable:add(name, value)
    if getmetatable(value) == Duration then
        value = tsc.formatDuration(value.seconds)
    end
    self.rows[#self.rows + 1] = { name = name, value = sprint(value) }
end

function statTable:print(w)
    local nameWidth = 0
    local valueWidth = 0
    for _, r in ipairs(self.rows) do
        nameWidth = math.max(nameWidth, #r.name)
        valueWidth = math.max(valueWidth, #r.value)
    end

    for _, r in ipairs(self.rows) do
        local name = r.name .. ":"
        local value = r.value
        w:WriteString(name .. string.rep(" ", nameWidth + 1 - #name) .. " " .. string.rep(" ", valueWidth - #value) .. value .. "\n")
    end
end

function tsc.formatDuration(d)
    return string.format("%.3fs", d)
end

function tsc.identifierCount(p)
    local count = 0
    for _, file in ipairs(p:SourceFiles()) do
        count = count + file.identifierCount
    end
    return count
end

local Statistics = {}
Statistics.__index = Statistics
tsc.Statistics = Statistics

function tsc.NewStatistics()
    return setmetatable({
        isAggregate = false,
        projects = 0,
        projectsBuilt = 0,
        timestampUpdates = 0,
        files = 0,
        lines = 0,
        identifiers = 0,
        symbols = 0,
        types = 0,
        instantiations = 0,
        memoryUsed = 0,
        memoryAllocs = 0,
        compileTimes = nil,
    }, Statistics)
end

-- memStats: { alloc = bytes in use, mallocs = allocation count (unavailable in Lua: 0) }
function tsc.statisticsFromProgram(input, memStats)
    local s = tsc.NewStatistics()
    s.files = #input.program:SourceFiles()
    s.lines = input.program:LineCount()
    s.identifiers = input.program:IdentifierCount()
    s.symbols = input.program:SymbolCount()
    s.types = input.program:TypeCount()
    s.instantiations = input.program:InstantiationCount()
    s.memoryUsed = memStats.alloc
    s.memoryAllocs = memStats.mallocs
    s.compileTimes = input.compileTimes
    return s
end

function Statistics:Report(w, testing)
    if testing ~= nil then
        testing:OnStatisticsStart(w)
    end
    local t = newTable()
    local prefix = ""

    if self.isAggregate then
        prefix = "Aggregate "
        t:add("Projects in scope", self.projects)
        t:add("Projects built", self.projectsBuilt)
        t:add("Timestamps only updates", self.timestampUpdates)
    end
    t:add(prefix .. "Files", self.files)
    t:add(prefix .. "Lines", self.lines)
    t:add(prefix .. "Identifiers", self.identifiers)
    t:add(prefix .. "Symbols", self.symbols)
    t:add(prefix .. "Types", self.types)
    t:add(prefix .. "Instantiations", self.instantiations)
    t:add(prefix .. "Memory used", tostring(self.memoryUsed // 1024) .. "K")
    t:add(prefix .. "Memory allocs", tostring(self.memoryAllocs))
    local times = self.compileTimes
    if times.configTime ~= 0 then
        t:add(prefix .. "Config time", tsc.Duration(times.configTime))
    end
    if times.buildInfoReadTime ~= 0 then
        t:add(prefix .. "BuildInfo read time", tsc.Duration(times.buildInfoReadTime))
    end
    t:add(prefix .. "Parse time", tsc.Duration(times.parseTime))
    if times.bindTime ~= 0 then
        t:add(prefix .. "Bind time", tsc.Duration(times.bindTime))
    end
    if times.checkTime ~= 0 then
        t:add(prefix .. "Check time", tsc.Duration(times.checkTime))
    end
    if times.emitTime ~= 0 then
        t:add(prefix .. "Emit time", tsc.Duration(times.emitTime))
    end
    if times.changesComputeTime ~= 0 then
        t:add(prefix .. "Changes compute time", tsc.Duration(times.changesComputeTime))
    end
    self:addContentMapperStatistics(t, prefix)
    t:add(prefix .. "Total time", tsc.Duration(times.totalTime))
    t:print(w)
    if testing ~= nil then
        testing:OnStatisticsEnd(w)
    end
end

function Statistics:addContentMapperStatistics(t, prefix)
    local timings = self.compileTimes.contentMapperTimes
    if timings == nil then
        return
    end
    if (timings.requestWait or 0) ~= 0 then
        t:add(prefix .. "Content mapper request wait time", tsc.Duration(timings.requestWait))
    end
    for _, identity in ipairs(compiler.sortedKeys(timings.mappers)) do
        local mapper = timings.mappers[identity]
        local initializationCount = mapper.spawn.count
        if initializationCount ~= 0 then
            t:add(prefix .. identity .. " initialization time", tsc.Duration(mapper.spawn.duration + mapper.initialize.duration))
        end
        if mapper.transform.count ~= 0 then
            t:add(prefix .. identity .. " transform time", tsc.Duration(mapper.transform.duration))
        end
        if mapper.openProject.count ~= 0 then
            t:add(prefix .. identity .. " openProject time", tsc.Duration(mapper.openProject.duration))
        end
        if mapper.closeProject.count ~= 0 then
            t:add(prefix .. identity .. " closeProject time", tsc.Duration(mapper.closeProject.duration))
        end
    end
end

function Statistics:Aggregate(stat)
    self.isAggregate = true
    if self.compileTimes == nil then
        self.compileTimes = tsc.NewCompileTimes()
    end
    -- Aggregate statistics
    self.files = self.files + stat.files
    self.lines = self.lines + stat.lines
    self.identifiers = self.identifiers + stat.identifiers
    self.symbols = self.symbols + stat.symbols
    self.types = self.types + stat.types
    self.instantiations = self.instantiations + stat.instantiations
    self.memoryUsed = self.memoryUsed + stat.memoryUsed
    self.memoryAllocs = self.memoryAllocs + stat.memoryAllocs
    local a, b = self.compileTimes, stat.compileTimes
    a.configTime = a.configTime + b.configTime
    a.buildInfoReadTime = a.buildInfoReadTime + b.buildInfoReadTime
    a.parseTime = a.parseTime + b.parseTime
    a.bindTime = a.bindTime + b.bindTime
    a.checkTime = a.checkTime + b.checkTime
    a.emitTime = a.emitTime + b.emitTime
    a.changesComputeTime = a.changesComputeTime + b.changesComputeTime
end

function Statistics:SetTotalTime(totalTime)
    if self.compileTimes == nil then
        self.compileTimes = tsc.NewCompileTimes()
    end
    self.compileTimes.totalTime = totalTime
end
