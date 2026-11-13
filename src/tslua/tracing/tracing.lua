local tracing = require("tslua.tracing")
local ast = require("tslua.ast")
local json = require("tslua.json")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")
local xxh3 = require("tslua.xxh3")

-- Tracer is an interface for recording types during type checking.
-- Each checker should have its own Tracer instance to avoid sharing types between checkers.
--   RecordType(t TracedType) records a type for later dumping.
--   DumpTypes() error writes all recorded types to disk.

-- TracedType is an interface that represents a type that can be traced.
-- This allows the tracing package to work with types from the checker package
-- without creating a circular dependency. Methods: Id, FormatFlags, IsConditional, Symbol,
-- AliasSymbol, AliasTypeArguments, IntrinsicName, UnionTypes, IntersectionTypes, IndexType,
-- IndexedAccessObjectType, IndexedAccessIndexType, ConditionalCheckType, ConditionalExtendsType,
-- ConditionalTrueType, ConditionalFalseType, SubstitutionBaseType, SubstitutionConstraintType,
-- ReferenceTarget, ReferenceTypeArguments, ReferenceNode, ReverseMappedSourceType,
-- ReverseMappedMappedType, ReverseMappedConstraintType, EvolvingArrayElementType,
-- EvolvingArrayFinalType, IsTuple, Pattern, RecursionIdentity, Display (see checker/tracer.lua).

-- TraceRecord represents metadata about a single trace file
-- { configFilePath, tracePath, typesPath (strings), checkerID (int) }
local TraceRecord = {}
TraceRecord.__index = TraceRecord
tracing.TraceRecord = TraceRecord

local function quote(s)
    return json.QuoteString(s)
end

-- Encodes a Go int or float64 like encoding/json (whole floats print without a fraction).
local function number(n)
    local s, err = json.Marshal(n)
    if err ~= nil then
        error(err, 0)
    end
    return s
end

-- `json:"configFilePath,omitzero"`, `json:"tracePath,omitzero"`, `json:"typesPath,omitzero"`,
-- `json:"checkerId"`
function TraceRecord:MarshalJSON()
    local parts = {}
    if self.configFilePath ~= "" then
        parts[#parts + 1] = quote("configFilePath") .. ":" .. quote(self.configFilePath)
    end
    if self.tracePath ~= "" then
        parts[#parts + 1] = quote("tracePath") .. ":" .. quote(self.tracePath)
    end
    if self.typesPath ~= "" then
        parts[#parts + 1] = quote("typesPath") .. ":" .. quote(self.typesPath)
    end
    parts[#parts + 1] = quote("checkerId") .. ":" .. number(self.checkerID)
    return "{" .. table.concat(parts, ",") .. "}", nil
end

-- traceEvent: { pid, tid (int), ph, cat (string), ts (float64), name, s (string, omitzero; s is the
-- scope, only set for instant events ("g" = global)), dur (*float64, omitzero), args (map[string]any,
-- omitzero) }. Marshaled with json.Deterministic(true): args keys are sorted.
local function marshalArgs(args)
    local keys = {}
    for k in pairs(args) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do
        local v, err = json.Marshal(args[k])
        if err ~= nil then
            error(err, 0)
        end
        parts[i] = quote(k) .. ":" .. v
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function marshalTraceEvent(event)
    local b = {
        '{"pid":', number(event.pid),
        ',"tid":', number(event.tid),
        ',"ph":', quote(event.ph),
        ',"cat":', quote(event.cat),
        ',"ts":', number(event.ts),
    }
    if event.name ~= nil and event.name ~= "" then
        b[#b + 1] = ',"name":'
        b[#b + 1] = quote(event.name)
    end
    if event.s ~= nil and event.s ~= "" then
        b[#b + 1] = ',"s":'
        b[#b + 1] = quote(event.s)
    end
    if event.dur ~= nil then
        b[#b + 1] = ',"dur":'
        b[#b + 1] = number(event.dur)
    end
    if event.args ~= nil then
        b[#b + 1] = ',"args":'
        b[#b + 1] = marshalArgs(event.args)
    end
    b[#b + 1] = "}"
    return table.concat(b)
end

-- sampleInterval matches TypeScript's 10ms sampling interval (in microseconds here).
-- Events with separateBeginAndEnd=false are only recorded if their
-- duration crosses a 10ms sampling boundary.
tracing.sampleInterval = 10 * 1000

tracing.traceFileName = "trace.json"

tracing.mainThreadID = 1
tracing.firstSyntheticThreadID = 2
tracing.firstFileThreadID = 1000000
tracing.fileThreadIDHashRange = 1000000000

tracing.traceThreadArgKeys = { "path", "fileName", "containingFileName", "jsFilePath", "declarationFilePath" }

-- flushThreshold is the size at which buffered trace content is flushed to disk
-- via AppendFile. Keeps peak memory bounded for long-running compilations while
-- avoiding a syscall per event.
tracing.flushThreshold = 256 * 1024

-- Go time.Now()/time.Since: pure Lua has no monotonic wall clock, so elapsed times are measured
-- with os.clock() (processor time), in seconds.
function tracing.now()
    return os.clock()
end

-- Tracing manages the overall tracing session including all checkers.
-- traceContent is a strings.Builder (buffer array plus its byte length).
local Tracing = {}
Tracing.__index = Tracing
tracing.Tracing = Tracing

-- Phase represents a tracing phase
tracing.PhaseParse = "parse"
tracing.PhaseProgram = "program"
tracing.PhaseBind = "bind"
tracing.PhaseCheck = "check"
tracing.PhaseCheckTypes = "checkTypes"
tracing.PhaseEmit = "emit"
tracing.PhaseSession = "session"

function Tracing:contentWrite(s)
    local c = self.traceContent
    c[#c + 1] = s
    self.traceContentLen = self.traceContentLen + #s
end

function Tracing:contentString()
    return table.concat(self.traceContent)
end

function Tracing:contentReset()
    self.traceContent = {}
    self.traceContentLen = 0
end

-- StartTracing creates a new tracing session.
-- When deterministic is true, timestamps use a monotonic counter instead of
-- real wall-clock time, producing stable output for test baselines.
-- Returns (tracing, err).
function tracing.StartTracing(fs, traceDir, configFilePath, deterministic)
    local tr = setmetatable({
        fs = fs,
        traceDir = traceDir,
        tracePath = tspath.CombinePaths(traceDir, tracing.traceFileName),
        configFilePath = configFilePath,
        legend = {},
        tracers = {},
        traceContent = {},
        traceContentLen = 0,
        traceStarted = false,
        threadIDs = {},
        threadKeys = {},
        metadataTS = 0,
        deterministic = deterministic,
        timestampCounter = 0,
        startTime = tracing.now(),
        flushErr = nil,
    }, Tracing)
    tr.traceStarted = true

    -- Write the trace file header with metadata events
    tr:contentWrite("[\n")

    -- Write metadata events (matching TypeScript's format)
    local metaTs = tr:timestamp()
    tr.metadataTS = metaTs
    tr:writeEvent({ pid = 1, tid = tracing.mainThreadID, ph = "M", cat = "__metadata", ts = metaTs, name = "process_name", args = { name = "tsgo" } })
    tr:contentWrite(",\n")
    tr:writeEvent({ pid = 1, tid = tracing.mainThreadID, ph = "M", cat = "__metadata", ts = metaTs, name = "thread_name", args = { name = "Main" } })
    tr:contentWrite(",\n")
    tr:writeEvent({ pid = 1, tid = tracing.mainThreadID, ph = "M", cat = "disabled-by-default-devtools.timeline", ts = metaTs, name = "TracingStartedInBrowser" })

    -- Truncate any existing trace file with the header so subsequent AppendFile
    -- calls extend a clean file.
    local err = tr.fs:WriteFile(tr.tracePath, tr:contentString())
    if err ~= nil then
        return nil, "failed to write trace file header: " .. tostring(err)
    end
    tr:contentReset()

    return tr, nil
end

-- timestamp returns the current timestamp in microseconds.
-- In deterministic mode it returns a monotonically increasing counter;
-- otherwise it returns the real elapsed wall-clock time since tracing started,
-- matching TypeScript's 1000 * timestamp() (microseconds).
function Tracing:timestamp()
    if self.deterministic then
        self.timestampCounter = self.timestampCounter + 1
        return self.timestampCounter + 0.0
    end
    return (tracing.now() - self.startTime) * 1000000.0
end

function tracing.writeEventTo(buf, event)
    buf:contentWrite(marshalTraceEvent(event))
end

function Tracing:writeEvent(event)
    tracing.writeEventTo(self, event)
end

-- maybeFlushLocked appends the buffered trace content to disk if it has grown
-- past the flush threshold. If a previous flush failed,
-- or this flush fails, the error is recorded in tr.flushErr and subsequent
-- writes become no-ops; the error is surfaced from StopTracing.
function Tracing:maybeFlushLocked()
    if self.flushErr ~= nil then
        self:contentReset()
        return
    end
    if self.traceContentLen < tracing.flushThreshold then
        return
    end
    local err = self.fs:AppendFile(self.tracePath, self:contentString())
    if err ~= nil then
        self.flushErr = "failed to flush trace file: " .. tostring(err)
    end
    self:contentReset()
end

-- Instant records an instant event in the trace.
-- Safe to call on nil receiver (as tracing.Tracing.Instant(nil, ...)).
function Tracing.Instant(tr, phase, name, args)
    if tr == nil or not tr.traceStarted then
        return
    end

    local ts = tr:timestamp()
    local tid = tr:threadIDLocked(args)
    tr:contentWrite(",\n")
    tr:writeEvent({ pid = 1, tid = tid, ph = "I", cat = phase, ts = ts, name = name, s = "g", args = args })
    tr:maybeFlushLocked()
end

local function noop() end

local function cloneMap(m)
    if m == nil then
        return nil
    end
    local c = {}
    for k, v in pairs(m) do
        c[k] = v
    end
    return c
end

-- Push starts a trace event block on the shared trace buffer.
-- Safe to call on nil receiver (as tracing.Tracing.Push(nil, ...)).
--
-- When separateBeginAndEnd is true, a "B" (begin) event is written immediately and
-- the returned function writes a matching "E" (end) event. This is used for events
-- that must always appear in the trace (e.g. checkSourceFile, createProgram, emit).
--
-- When separateBeginAndEnd is false (the default in TypeScript), the event is only
-- recorded if its duration crosses a 10ms sampling boundary, matching TypeScript's
-- behavior of sampling short-lived events to avoid trace bloat.
--
-- Returns a function that should be called (Go: deferred) to end the event.
-- Each returned function is self-contained and does not depend on a shared stack.
function Tracing.Push(tr, phase, name, args, separateBeginAndEnd)
    if tr == nil or not tr.traceStarted then
        return noop
    end

    if separateBeginAndEnd then
        local ts = tr:timestamp()
        local tid = tr:threadIDLocked(args)
        tr:contentWrite(",\n")
        tr:writeEvent({ pid = 1, tid = tid, ph = "B", cat = phase, ts = ts, name = name, args = args })
        tr:maybeFlushLocked()

        return function()
            if not tr.traceStarted then
                return
            end
            local endTs = tr:timestamp()
            tr:contentWrite(",\n")
            tr:writeEvent({ pid = 1, tid = tid, ph = "E", cat = phase, ts = endTs, name = name, args = args })
            tr:maybeFlushLocked()
        end
    end

    -- Sampled event: only record if duration crosses a sampling boundary.
    -- In deterministic mode, sampled events are skipped entirely to avoid flaky baselines,
    -- so avoid the cost of cloning args / capturing the start time.
    if tr.deterministic then
        return noop
    end
    local startTime = tracing.now()
    args = cloneMap(args)
    return function()
        local dur = (tracing.now() - startTime) * 1000000.0
        local startMicros = (startTime - tr.startTime) * 1000000.0
        local intervalMicros = tracing.sampleInterval + 0.0
        if intervalMicros - math.fmod(startMicros, intervalMicros) > dur then
            return
        end
        if not tr.traceStarted then
            return
        end
        local tid = tr:threadIDLocked(args)
        tr:contentWrite(",\n")
        tr:writeEvent({ pid = 1, tid = tid, ph = "X", cat = phase, ts = startMicros, name = name, dur = dur, args = args })
        tr:maybeFlushLocked()
    end
end

-- traceThreadKey is a value struct { kind, text, index, hasIndex }; maps are keyed by
-- tracing.traceThreadKey_mapKey(key).
function tracing.traceThreadKey_mapKey(key)
    if key.hasIndex then
        return key.kind .. "\0#" .. key.index
    end
    return key.kind .. "\0" .. key.text
end

function Tracing:threadIDLocked(args)
    local key, ok = tracing.traceThreadKeyFromArgs(args)
    if not ok then
        return tracing.mainThreadID
    end

    local mapKey = tracing.traceThreadKey_mapKey(key)
    local existing = self.threadIDs[mapKey]
    if existing ~= nil then
        return existing
    end

    local tid = tracing.traceThreadKey_defaultThreadID(key)
    while true do
        local existingKey = self.threadKeys[tid]
        if existingKey == nil or existingKey == mapKey then
            break
        end
        tid = tid + 1
    end
    self.threadIDs[mapKey] = tid
    self.threadKeys[tid] = mapKey
    self:writeThreadNameEventLocked(tid, tracing.traceThreadKey_displayName(key))
    return tid
end

function Tracing:writeThreadNameEventLocked(tid, name)
    self:contentWrite(",\n")
    self:writeEvent({ pid = 1, tid = tid, ph = "M", cat = "__metadata", ts = self.metadataTS, name = "thread_name", args = { name = name } })
end

tracing.traceThreadKindChecker = "checker"
tracing.traceThreadKindFile = "file"

-- Returns (traceThreadKey, ok).
function tracing.traceThreadKeyFromArgs(args)
    if args == nil or next(args) == nil then
        return { kind = "", text = "", index = 0, hasIndex = false }, false
    end

    local checkerID = args["checkerId"]
    if math.type(checkerID) == "integer" then
        return { kind = tracing.traceThreadKindChecker, text = "", index = checkerID, hasIndex = true }, true
    end

    for _, key in ipairs(tracing.traceThreadArgKeys) do
        local value = args[key]
        if type(value) == "string" and value ~= "" then
            return { kind = tracing.traceThreadKindFile, text = value, index = 0, hasIndex = false }, true
        end
    end

    return { kind = "", text = "", index = 0, hasIndex = false }, false
end

function tracing.traceThreadKey_defaultThreadID(key)
    if key.kind == tracing.traceThreadKindChecker and key.hasIndex and key.index >= 0 then
        return tracing.firstSyntheticThreadID + key.index
    end
    return tracing.stableTraceThreadID(key)
end

function tracing.traceThreadKey_displayName(key)
    if key.hasIndex then
        return key.kind .. ":" .. tostring(key.index)
    end
    return key.kind .. ":" .. key.text
end

-- uint64 x % m for a Lua integer holding uint64 bits and a positive m < 2^62.
local function umod(x, m)
    return ((x >> 1) % m * 2 + (x & 1)) % m
end

function tracing.stableTraceThreadID(key)
    local hash = xxh3.New()
    hash:WriteString(key.kind)
    hash:WriteString(":")
    if key.hasIndex then
        hash:WriteString(tostring(key.index))
    else
        hash:WriteString(key.text)
    end
    return tracing.firstFileThreadID + umod(hash:Sum64(), tracing.fileThreadIDHashRange)
end

-- typeTracer is the per-checker tracer implementation
local typeTracer = {}
typeTracer.__index = typeTracer
tracing.typeTracer = typeTracer

-- NewTypeTracer creates a new tracer for a specific checker.
-- The checkerIndex is used to create unique filenames for each checker's output.
function Tracing:NewTypeTracer(checkerIndex)
    local typesPath = tspath.CombinePaths(self.traceDir, "types_" .. tostring(checkerIndex) .. ".json")
    local tracer = setmetatable({
        fs = self.fs,
        checkerIndex = checkerIndex,
        typesPath = typesPath,
        types = {},
    }, typeTracer)
    self.tracers[#self.tracers + 1] = tracer
    self.legend[#self.legend + 1] = setmetatable({
        configFilePath = self.configFilePath,
        tracePath = self.tracePath,
        typesPath = typesPath,
        checkerID = checkerIndex,
    }, TraceRecord)
    return tracer
end

-- StopTracing finalizes the tracing session and writes all output files. Returns err or nil.
function Tracing:StopTracing()
    -- Dump types from all tracers first: DumpTypes → buildTypeDescriptor → Display() →
    -- TypeToString can re-enter the checker which calls Push/Pop.
    for _, tracer in ipairs(self.tracers) do
        local err = tracer:DumpTypes()
        if err ~= nil then
            return "failed to dump types for checker " .. tostring(tracer.checkerIndex) .. ": " .. tostring(err)
        end
    end

    -- Close the trace file(s)
    if self.traceStarted then
        -- Surface any buffered flush failure before attempting the final write.
        if self.flushErr ~= nil then
            self:contentReset()
            self.traceStarted = false
            return self.flushErr
        end
        -- Flush any remaining buffered content and close the JSON array.
        local err = self.fs:AppendFile(self.tracePath, self:contentString() .. "\n]\n")
        if err ~= nil then
            return "failed to write trace file: " .. tostring(err)
        end
        self:contentReset()
        self.traceStarted = false
    end

    -- Sort legend entries by typesPath for deterministic output
    table.sort(self.legend, function(a, b)
        return a.typesPath < b.typesPath
    end)

    -- Write the legend file
    local legendPath = tspath.CombinePaths(self.traceDir, "legend.json")
    local legendData, err = json.MarshalIndent(self.legend, "", "  ")
    if err ~= nil then
        return "failed to marshal legend file: " .. tostring(err)
    end
    err = self.fs:WriteFile(legendPath, legendData)
    if err ~= nil then
        return "failed to write legend file: " .. tostring(err)
    end

    return nil
end

function typeTracer:RecordType(typ)
    self.types[#self.types + 1] = typ
end

-- Returns err or nil.
function typeTracer:DumpTypes()
    -- Copy the types slice, so Display() calls during buildTypeDescriptor can create new types
    local types = table.move(self.types, 1, #self.types, 1, {})

    if #types == 0 then
        return nil
    end

    local sb = {}
    -- Write opening bracket (no newline so type ID matches line number)
    sb[#sb + 1] = "["

    local recursionIdentityMap = { size = 0, tokens = {} }

    for i, typ in ipairs(types) do
        local descriptor = self:buildTypeDescriptor(typ, recursionIdentityMap)

        local s, err = json.Marshal(descriptor)
        if err ~= nil then
            return "failed to marshal type " .. tostring(typ:Id()) .. ": " .. tostring(err)
        end
        sb[#sb + 1] = s

        if i < #types then
            sb[#sb + 1] = ",\n"
        end
    end

    sb[#sb + 1] = "]\n"

    return self.fs:WriteFile(self.typesPath, table.concat(sb))
end

-- TypeDescriptor represents a type in the output JSON. Fields (Go json names, all omitzero except
-- id and flags): id, intrinsicName, symbolName, recursionId, isTuple, unionTypes,
-- intersectionTypes, aliasTypeArguments, keyofType, indexedAccessObjectType, indexedAccessIndexType,
-- conditionalCheckType, conditionalExtendsType, conditionalTrueType, conditionalFalseType
-- (ConditionalTrueType and ConditionalFalseType are int32 because unresolved conditional branches
-- are serialized as -1, matching TypeScript's behavior), substitutionBaseType, constraintType,
-- instantiatedType, typeArguments, referenceLocation, reverseMappedSourceType,
-- reverseMappedMappedType, reverseMappedConstraintType, evolvingArrayElementType,
-- evolvingArrayFinalType, destructuringPattern, firstDeclaration, flags, display.
-- Lua: nil stands for Go's nil pointer / slice and "" / false for the zero string / bool.
local TypeDescriptor = {}
TypeDescriptor.__index = TypeDescriptor
tracing.TypeDescriptor = TypeDescriptor

local typeDescriptorFields = {
    { "id", "iD", "always" },
    { "intrinsicName", "intrinsicName", "string" },
    { "symbolName", "symbolName", "string" },
    { "recursionId", "recursionID", "ptr" },
    { "isTuple", "isTuple", "bool" },
    { "unionTypes", "unionTypes", "ptr" },
    { "intersectionTypes", "intersectionTypes", "ptr" },
    { "aliasTypeArguments", "aliasTypeArguments", "ptr" },
    { "keyofType", "keyofType", "ptr" },
    { "indexedAccessObjectType", "indexedAccessObjectType", "ptr" },
    { "indexedAccessIndexType", "indexedAccessIndexType", "ptr" },
    { "conditionalCheckType", "conditionalCheckType", "ptr" },
    { "conditionalExtendsType", "conditionalExtendsType", "ptr" },
    { "conditionalTrueType", "conditionalTrueType", "ptr" },
    { "conditionalFalseType", "conditionalFalseType", "ptr" },
    { "substitutionBaseType", "substitutionBaseType", "ptr" },
    { "constraintType", "constraintType", "ptr" },
    { "instantiatedType", "instantiatedType", "ptr" },
    { "typeArguments", "typeArguments", "ptr" },
    { "referenceLocation", "referenceLocation", "ptr" },
    { "reverseMappedSourceType", "reverseMappedSourceType", "ptr" },
    { "reverseMappedMappedType", "reverseMappedMappedType", "ptr" },
    { "reverseMappedConstraintType", "reverseMappedConstraintType", "ptr" },
    { "evolvingArrayElementType", "evolvingArrayElementType", "ptr" },
    { "evolvingArrayFinalType", "evolvingArrayFinalType", "ptr" },
    { "destructuringPattern", "destructuringPattern", "ptr" },
    { "firstDeclaration", "firstDeclaration", "ptr" },
    { "flags", "flags", "slice" },
    { "display", "display", "string" },
}

function TypeDescriptor:MarshalJSON()
    local parts = {}
    for _, f in ipairs(typeDescriptorFields) do
        local jsonName, field, kind = f[1], f[2], f[3]
        local v = self[field]
        local include
        if kind == "always" then
            include = true
        elseif kind == "string" then
            include = v ~= nil and v ~= ""
        elseif kind == "bool" then
            include = v == true
        elseif kind == "slice" then
            include = true
            if v == nil then
                v = {}
            end
        else
            include = v ~= nil
        end
        if include then
            local s, err = json.Marshal(v)
            if err ~= nil then
                return nil, err
            end
            parts[#parts + 1] = quote(jsonName) .. ":" .. s
        end
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end

-- Location represents a source code location: { path, start (*LineAndChar, omitzero), end_ }
local Location = {}
Location.__index = Location
tracing.Location = Location

function Location:MarshalJSON()
    local parts = { quote("path") .. ":" .. quote(self.path) }
    if self.start ~= nil then
        parts[#parts + 1] = quote("start") .. ":" .. self.start:MarshalJSON()
    end
    if self.end_ ~= nil then
        parts[#parts + 1] = quote("end") .. ":" .. self.end_:MarshalJSON()
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end

-- LineAndChar represents a line and character position (1-indexed)
local LineAndChar = {}
LineAndChar.__index = LineAndChar
tracing.LineAndChar = LineAndChar

function LineAndChar:MarshalJSON()
    return '{"line":' .. number(self.line) .. ',"character":' .. number(self.character) .. "}", nil
end

function typeTracer:buildTypeDescriptor(typ, recursionIdentityMap)
    local symbol = typ:Symbol()
    local aliasSymbol = typ:AliasSymbol()

    local desc = setmetatable({
        iD = typ:Id(),
        intrinsicName = "",
        symbolName = "",
        isTuple = false,
        flags = typ:FormatFlags(),
        display = "",
    }, TypeDescriptor)

    -- Assign a unique integer token per recursion identity, matching TypeScript's behavior.
    -- This lets trace analysis tools detect which types share the same recursion identity.
    local identity = typ:RecursionIdentity()
    if identity ~= nil then
        local token = recursionIdentityMap.tokens[identity]
        if token == nil then
            token = recursionIdentityMap.size
            recursionIdentityMap.tokens[identity] = token
            recursionIdentityMap.size = recursionIdentityMap.size + 1
        end
        desc.recursionID = token
    end

    -- Intrinsic name
    local name = typ:IntrinsicName()
    if name ~= "" then
        desc.intrinsicName = name
    end

    -- Symbol name - escape the internal symbol name prefix for valid JSON
    if aliasSymbol ~= nil then
        desc.symbolName = ast.EscapeAllInternalSymbolNames(aliasSymbol.name)
    elseif symbol ~= nil then
        desc.symbolName = ast.EscapeAllInternalSymbolNames(symbol.name)
    end

    -- Tuple flag
    if typ:IsTuple() then
        desc.isTuple = true
    end

    -- Union types
    local types = typ:UnionTypes()
    if types ~= nil and #types > 0 then
        desc.unionTypes = tracing.mapTypeIds(types)
    end

    -- Intersection types
    types = typ:IntersectionTypes()
    if types ~= nil and #types > 0 then
        desc.intersectionTypes = tracing.mapTypeIds(types)
    end

    -- Alias type arguments
    local args = typ:AliasTypeArguments()
    if args ~= nil and #args > 0 then
        desc.aliasTypeArguments = tracing.mapTypeIds(args)
    end

    -- Index type (keyof)
    local indexType = typ:IndexType()
    if indexType ~= nil then
        desc.keyofType = indexType:Id()
    end

    -- Indexed access type
    local objType = typ:IndexedAccessObjectType()
    if objType ~= nil then
        desc.indexedAccessObjectType = objType:Id()
    end
    local idxType = typ:IndexedAccessIndexType()
    if idxType ~= nil then
        desc.indexedAccessIndexType = idxType:Id()
    end

    -- Conditional type
    if typ:IsConditional() then
        local checkType = typ:ConditionalCheckType()
        if checkType ~= nil then
            desc.conditionalCheckType = checkType:Id()
        end
        local extendsType = typ:ConditionalExtendsType()
        if extendsType ~= nil then
            desc.conditionalExtendsType = extendsType:Id()
        end
        local trueType = typ:ConditionalTrueType()
        if trueType ~= nil then
            desc.conditionalTrueType = trueType:Id()
        else
            desc.conditionalTrueType = -1
        end
        local falseType = typ:ConditionalFalseType()
        if falseType ~= nil then
            desc.conditionalFalseType = falseType:Id()
        else
            desc.conditionalFalseType = -1
        end
    end

    -- Substitution type
    local baseType = typ:SubstitutionBaseType()
    if baseType ~= nil then
        desc.substitutionBaseType = baseType:Id()
    end
    local constraint = typ:SubstitutionConstraintType()
    if constraint ~= nil then
        desc.constraintType = constraint:Id()
    end

    -- Reference type
    local target = typ:ReferenceTarget()
    if target ~= nil then
        desc.instantiatedType = target:Id()
    end
    args = typ:ReferenceTypeArguments()
    if args ~= nil and #args > 0 then
        desc.typeArguments = tracing.mapTypeIds(args)
    end
    local node = typ:ReferenceNode()
    if node ~= nil then
        desc.referenceLocation = tracing.getLocation(node)
    end

    -- Reverse mapped type
    local sourceType = typ:ReverseMappedSourceType()
    if sourceType ~= nil then
        desc.reverseMappedSourceType = sourceType:Id()
    end
    local mappedType = typ:ReverseMappedMappedType()
    if mappedType ~= nil then
        desc.reverseMappedMappedType = mappedType:Id()
    end
    local constraintType = typ:ReverseMappedConstraintType()
    if constraintType ~= nil then
        desc.reverseMappedConstraintType = constraintType:Id()
    end

    -- Evolving array type
    local elemType = typ:EvolvingArrayElementType()
    if elemType ~= nil then
        desc.evolvingArrayElementType = elemType:Id()
    end
    local finalType = typ:EvolvingArrayFinalType()
    if finalType ~= nil then
        desc.evolvingArrayFinalType = finalType:Id()
    end

    -- Pattern (destructuring)
    local pattern = typ:Pattern()
    if pattern ~= nil then
        desc.destructuringPattern = tracing.getLocation(pattern)
    end

    -- First declaration - prefer aliasSymbol, matching TypeScript's `aliasSymbol ?? symbol`
    local firstDeclSymbol = aliasSymbol
    if firstDeclSymbol == nil then
        firstDeclSymbol = symbol
    end
    if firstDeclSymbol ~= nil and firstDeclSymbol.declarations ~= nil and #firstDeclSymbol.declarations > 0 then
        desc.firstDeclaration = tracing.getLocation(firstDeclSymbol.declarations[1])
    end

    -- Display text
    local display = typ:Display()
    if display ~= "" then
        desc.display = display
    end

    return desc
end

function tracing.mapTypeIds(types)
    if types == nil or #types == 0 then
        return nil
    end
    local ids = {}
    for i, t in ipairs(types) do
        if t ~= nil and t ~= false then
            ids[i] = t:Id()
        else
            ids[i] = 0
        end
    end
    return ids
end

function tracing.getLocation(node)
    if node == nil then
        return nil
    end
    local file = ast.GetSourceFileOfNode(node)
    if file == nil then
        return nil
    end

    local startPos = scanner.GetTokenPosOfNode(node, file, false)
    local startLine, startChar = scanner.GetECMALineAndUTF16CharacterOfPosition(file, startPos)
    local endLine, endChar = scanner.GetECMALineAndUTF16CharacterOfPosition(file, node:End())

    return setmetatable({
        path = tspath.ToPath(file:FileName(), "", false),
        start = setmetatable({
            line = startLine + 1,
            character = startChar + 1,
        }, LineAndChar),
        end_ = setmetatable({
            line = endLine + 1,
            character = endChar + 1,
        }, LineAndChar),
    }, Location)
end
