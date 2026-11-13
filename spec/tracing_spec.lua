-- Port of typescript-go internal/tracing/tracing_test.go.
local json = require("tslua.json")
local tracing = require("tslua.tracing")
local vfs = require("tslua.vfs")
local vfstest = require("tslua.vfs.vfstest")

local iofs = vfs.iofs
local fstest = iofs.fstest

local function newFS()
    return vfstest.FromMap({
        ["/trace"] = fstest.NewMapFile({ mode = iofs.ModeDir }),
    }, true)
end

local function readEvents(fsys)
    local traceText, ok = fsys:ReadFile("/trace/trace.json")
    assert.is_true(ok)
    local events, err = json.Unmarshal(traceText)
    assert.is_nil(err)
    return events
end

local function findEvent(events, phase, name, argName, argValue)
    for _, event in ipairs(events) do
        if event.ph == phase and event.name == name and event.args ~= nil and event.args[argName] == argValue then
            return event
        end
    end
    error(string.format("failed to find %s event %q with %s=%s", phase, name, argName, tostring(argValue)))
end

local function assertThreadName(events, tid, name)
    for _, event in ipairs(events) do
        if event.ph == "M" and event.name == "thread_name" and event.tid == tid and event.args ~= nil and event.args["name"] == name then
            return
        end
    end
    error(string.format("failed to find thread_name metadata for thread %d named %q", tid, name))
end

local function assertDurationEventsAreWellNestedByThread(events)
    local stacks = {}
    for _, event in ipairs(events) do
        if event.ph == "B" then
            stacks[event.tid] = stacks[event.tid] or {}
            table.insert(stacks[event.tid], event)
        elseif event.ph == "E" then
            local stack = stacks[event.tid] or {}
            assert.is_true(#stack > 0, "unmatched end event " .. event.name)
            local begin = table.remove(stack)
            assert.are.equal(begin.cat, event.cat)
            assert.are.equal(begin.name, event.name)
        end
    end
    for _, stack in pairs(stacks) do
        assert.are.equal(0, #stack)
    end
end

describe("tracing", function()
    it("TestConcurrentDurationEventsUseSeparateThreadIDs", function()
        local fsys = newFS()
        local tr, err = tracing.StartTracing(fsys, "/trace", "", true --[[deterministic]])
        assert.is_nil(err)

        local endA = tr:Push(tracing.PhaseParse, "createSourceFile", { path = "/a.ts" }, true)
        local endB = tr:Push(tracing.PhaseParse, "createSourceFile", { path = "/b.ts" }, true)
        endA()
        endB()

        local endCheck = tr:Push(tracing.PhaseCheck, "checkSourceFile", { checkerId = 0, path = "/a.ts" }, true)
        local endVariance = tr:Push(tracing.PhaseCheckTypes, "getVariancesWorker", { checkerId = 0, id = 1 }, true)
        endVariance()
        endCheck()

        assert.is_nil(tr:StopTracing())

        local events = readEvents(fsys)

        local aBegin = findEvent(events, "B", "createSourceFile", "path", "/a.ts")
        local aEnd = findEvent(events, "E", "createSourceFile", "path", "/a.ts")
        local bBegin = findEvent(events, "B", "createSourceFile", "path", "/b.ts")
        local bEnd = findEvent(events, "E", "createSourceFile", "path", "/b.ts")
        assert.are.equal(aBegin.tid, aEnd.tid)
        assert.are.equal(bBegin.tid, bEnd.tid)
        assert.are_not.equal(aBegin.tid, bBegin.tid)
        assertThreadName(events, aBegin.tid, "file:/a.ts")
        assertThreadName(events, bBegin.tid, "file:/b.ts")

        local checkBegin = findEvent(events, "B", "checkSourceFile", "path", "/a.ts")
        local varianceBegin = findEvent(events, "B", "getVariancesWorker", "id", 1.0)
        assert.are.equal(checkBegin.tid, varianceBegin.tid)
        assertThreadName(events, checkBegin.tid, "checker:0")

        assertDurationEventsAreWellNestedByThread(events)
    end)

    local function traceThreadIDsForPaths(paths)
        local fsys = newFS()
        local tr, err = tracing.StartTracing(fsys, "/trace", "", true --[[deterministic]])
        assert.is_nil(err)
        for _, path in ipairs(paths) do
            local finish = tr:Push(tracing.PhaseParse, "createSourceFile", { path = path }, true)
            finish()
        end
        assert.is_nil(tr:StopTracing())
        local events = readEvents(fsys)
        local threadIDs = {}
        for _, path in ipairs(paths) do
            threadIDs[path] = findEvent(events, "B", "createSourceFile", "path", path).tid
        end
        return threadIDs
    end

    it("TestThreadIDsAreStableAcrossFirstSeenOrder", function()
        local first = traceThreadIDsForPaths({ "/a.ts", "/b.ts" })
        local second = traceThreadIDsForPaths({ "/b.ts", "/a.ts" })
        assert.are.same(first, second)
    end)

    it("writes the legend and samples nothing in deterministic mode", function()
        local fsys = newFS()
        local tr = tracing.StartTracing(fsys, "/trace", "/p/tsconfig.json", true)
        tr:NewTypeTracer(0)
        local finish = tr:Push(tracing.PhaseCheck, "checkExpression", { path = "/a.ts" }, false)
        finish()
        tracing.Tracing.Instant(tr, tracing.PhaseCheckTypes, "x_DepthLimit", { depth = 3 })
        assert.is_nil(tr:StopTracing())
        local legend = fsys:ReadFile("/trace/legend.json")
        assert.are.equal('[\n  {\n    "configFilePath": "/p/tsconfig.json",\n    "tracePath": "/trace/trace.json",\n    "typesPath": "/trace/types_0.json",\n    "checkerId": 0\n  }\n]', legend)
        local events = readEvents(fsys)
        for _, event in ipairs(events) do
            assert.are_not.equal("X", event.ph)
        end
        assert.are.equal("I", events[#events].ph)
        assert.are.equal("g", events[#events].s)
    end)
end)
