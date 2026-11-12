-- Port of contentmapper_watch_test.go: imperative (non-baseline) tests of the content mapper process
-- lifecycle under tsc --build / --watch. Each Test* function takes a testutil.T; run them with
-- `bin/tslua-tsctest --unit`. Atomic counters become plain numbers; the buffered `closed` channel
-- becomes a counter of pending close signals (closes happen synchronously in the sequential port).
local tsctests = require("tslua.execute.tsctests")
local core = require("tslua.core")
local execute = require("tslua.execute")
local testutil = require("tslua.testutil")
local tsc = require("tslua.execute.tsc")

local function contentmappertest()
    return require("tslua.testutil.contentmappertest")
end

local function fswatch()
    return require("tslua.fswatch")
end

local function eventUpdate(path)
    return { kind = fswatch().EventKind.EventUpdate, path = path }
end

local assertEqual = testutil.AssertEqual
local assertTrue = testutil.Assert

-- recordingContentMapperSystem embeds *TestSys and overrides Spawn.
local recordingContentMapperSystem = {}
tsctests.recordingContentMapperSystem = recordingContentMapperSystem

recordingContentMapperSystem.__index = function(self, key)
    local own = rawget(recordingContentMapperSystem, key)
    if own ~= nil then
        return own
    end
    local v = rawget(self, "testSys")[key]
    if type(v) == "function" then
        -- promoted method of the embedded *TestSys
        return function(_, ...)
            return v(rawget(self, "testSys"), ...)
        end
    end
    return v
end

function tsctests.newRecordingContentMapperSystem(testSys, spawner)
    return setmetatable({ testSys = testSys, spawner = spawner }, recordingContentMapperSystem)
end

function recordingContentMapperSystem:Spawn(command, dir, stderr)
    return self.spawner:Spawn(command, dir, stderr)
end

-- recordingContentMapperSpawner: { inner = contentmapper.Spawner, spawns = 0, closes = 0, closed = channel or nil }
local recordingContentMapperSpawner = {}
recordingContentMapperSpawner.__index = recordingContentMapperSpawner
tsctests.recordingContentMapperSpawner = recordingContentMapperSpawner

function tsctests.newRecordingContentMapperSpawner(inner, closed)
    return setmetatable({ inner = inner, spawns = 0, closes = 0, closed = closed }, recordingContentMapperSpawner)
end

function recordingContentMapperSpawner:Spawn(command, dir, stderr)
    local process, err = self.inner:Spawn(command, dir, stderr)
    if err ~= nil then
        return nil, err
    end
    self.spawns = self.spawns + 1
    return tsctests.newRecordingContentMapperProcess(process, self, self.closed), nil
end

-- recordingContentMapperProcess embeds io.ReadWriteCloser; Close runs once.
local recordingContentMapperProcess = {}
recordingContentMapperProcess.__index = recordingContentMapperProcess
tsctests.recordingContentMapperProcess = recordingContentMapperProcess

function tsctests.newRecordingContentMapperProcess(rwc, counters, closed)
    return setmetatable({ readWriteCloser = rwc, counters = counters, closed = closed, once = false }, recordingContentMapperProcess)
end

function recordingContentMapperProcess:Read(...)
    return self.readWriteCloser:Read(...)
end

function recordingContentMapperProcess:Write(...)
    return self.readWriteCloser:Write(...)
end

function recordingContentMapperProcess:Close()
    local err = nil
    if not self.once then
        self.once = true
        self.counters.closes = self.counters.closes + 1
        err = self.readWriteCloser:Close()
        if self.closed ~= nil then
            self.closed.pending = self.closed.pending + 1
        end
    end
    return err
end

-- A `chan struct{}` the test receives from: receive() consumes one pending signal.
local function newClosedChannel()
    return { pending = 0 }
end

local function receive(t, ch, what)
    assertTrue(t, ch.pending > 0, what or "expected a content mapper process close")
    ch.pending = ch.pending - 1
end

function tsctests.TestContentMapperBuildLifecycle(t)
    t:Parallel()
    local cmt = contentmappertest()
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "composite": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        ["/home/src/workspaces/project/app.vue"] = "export const app = 1;",
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.VerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), nil)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)

    local result = execute.CommandLine(t:Context(), sys, { "--build", "--runExternalCode" }, testSys)
    assertTrue(t, result.watcher == nil)
    assertEqual(t, spawner.spawns, 1)
    assertEqual(t, spawner.closes, 1)
end

function tsctests.TestContentMapperBuildIdentityFailureExitStatus(t)
    t:Parallel()
    local cmt = contentmappertest()
    local packageJSONPath = "/home/src/workspaces/project/node_modules/mapper/package.json"
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "composite": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        ["/home/src/workspaces/project/app.vue"] = "export const app = 1;",
        [packageJSONPath] = cmt.PackageJSON(cmt.DynamicVerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), nil))
    local args = { "--build", "--runExternalCode" }
    local result = execute.CommandLine(t:Context(), sys, args, testSys)
    assertEqual(t, result.status, tsc.ExitStatus.Success)

    testSys:writeFileNoError(packageJSONPath, [[{
		"name": "mapper",
		"version": "1.0.0",
		"typescript": { "contentMapper": { "exec": ["missing-mapper"], "dynamicConfig": true } }
	}]])
    result = execute.CommandLine(t:Context(), sys, args, testSys)
    assertEqual(t, result.status, tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped)
end

function tsctests.TestContentMapperWatchLifecycle(t)
    t:Parallel()
    for _, test in ipairs({
        { name = "watch", args = { "--watch", "--runExternalCode" } },
        { name = "build watch", args = { "--build", "--watch", "--runExternalCode" } },
    }) do
        t:Run(test.name, function(t2)
            t2:Parallel()
            local cmt = contentmappertest()
            local configFileName = "/home/src/workspaces/project/tsconfig.json"
            local input = tsctests.newTscInput({ files = {
                [configFileName] = [[{
					"compilerOptions": { "composite": true },
					"contentMappers": [{ "package": "mapper-a", "extensions": [".vue"] }]
				}]],
                ["/home/src/workspaces/project/app.vue"] = "export const app = 1;",
                ["/home/src/workspaces/project/node_modules/mapper-a/package.json"] = cmt.PackageJSON(cmt.VerbatimMapper),
                ["/home/src/workspaces/project/node_modules/mapper-b/package.json"] = tsctests.replaceOnce(cmt.PackageJSON(cmt.VerbatimMapper), [["version": "1.0.0"]], [["version": "2.0.0"]]),
            } })
            local testSys = tsctests.newTestSys(input, false)
            local closed = newClosedChannel()
            local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), closed)
            local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)
            local ctx, cancel = core.WithCancel(t2:Context())

            local ok, err = pcall(function()
                local result = execute.CommandLine(ctx, sys, test.args, testSys)
                assertTrue(t2, result.watcher ~= nil)
                assertEqual(t2, spawner.spawns, 1)
                assertEqual(t2, spawner.closes, 0)

                testSys:writeFileNoError(configFileName, [[{
				"compilerOptions": { "composite": true },
				"contentMappers": [{ "package": "mapper-b", "extensions": [".vue"] }]
			}]])
                testSys.mockWatchBackend:SendEvents({ eventUpdate(configFileName) })
                result.watcher:DoCycle()

                assertEqual(t2, spawner.spawns, 2)
                assertEqual(t2, spawner.closes, 1)
                receive(t2, closed)

                testSys:writeFileNoError(configFileName, [[{ "compilerOptions": { "composite": true } }]])
                testSys.mockWatchBackend:SendEvents({ eventUpdate(configFileName) })
                result.watcher:DoCycle()

                assertEqual(t2, spawner.closes, 2)
                receive(t2, closed)

                testSys:writeFileNoError(configFileName, [[{
				"compilerOptions": { "composite": true },
				"contentMappers": [{ "package": "mapper-a", "extensions": [".vue"] }]
			}]])
                testSys.mockWatchBackend:SendEvents({ eventUpdate(configFileName) })
                result.watcher:DoCycle()

                assertEqual(t2, spawner.spawns, 3)
                assertEqual(t2, spawner.closes, 2)
                cancel()
                -- Go waits up to a second for the close; here the close happens during cancel().
                local closedAfterCancellation = closed.pending > 0
                if closedAfterCancellation then
                    closed.pending = closed.pending - 1
                end
                assertTrue(t2, closedAfterCancellation, "content mapper process was not closed after cancellation")
                assertEqual(t2, spawner.closes, 3)
            end)
            cancel() -- defer cancel()
            if not ok then
                error(err, 0)
            end
        end)
    end
end

function tsctests.TestContentMapperSupplementalCollisionWatch(t)
    t:Parallel()
    local cmt = contentmappertest()
    local supplementalFileName = "/home/src/workspaces/project/app.vue.0.ts"
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "noLib": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        ["/home/src/workspaces/project/app.vue"] = "declare const value: number;",
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.SupplementalMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), nil)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)
    local ctx, cancel = core.WithCancel(t:Context())

    local ok, err = pcall(function()
        local result = execute.CommandLine(ctx, sys, { "--watch", "--runExternalCode" }, testSys)
        local w = result.watcher
        local fullBuilds = w:FullBuilds()

        testSys:writeFileNoError(supplementalFileName, "export {};\n")
        testSys.mockWatchBackend:SendEvents({ eventUpdate(supplementalFileName) })
        w:DoCycle()
        assertEqual(t, w:FullBuilds(), fullBuilds + 1, "creating a supplemental filename collision must force a full rebuild")

        assertTrue(t, testSys:fsFromFileMap():Remove(supplementalFileName) == nil)
        testSys.mockWatchBackend:SendEvents({ eventUpdate(supplementalFileName) })
        w:DoCycle()
        assertEqual(t, w:FullBuilds(), fullBuilds + 2, "removing a supplemental filename collision must force a full rebuild")
    end)
    cancel()
    if not ok then
        error(err, 0)
    end
end

function tsctests.TestDynamicContentMapperWatchDependency(t)
    t:Parallel()
    local cmt = contentmappertest()
    local mapperConfigFileName = "/home/src/workspaces/project/mapper.config.json"
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "composite": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        [mapperConfigFileName] = [[{ "version": 1 }]],
        ["/home/src/workspaces/project/app.vue"] = "export const app = 1;",
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.DynamicVerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local lifecycle = cmt.NewProjectLifecycle()
    local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawnerWithProjectLifecycle(lifecycle), nil)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)
    local ctx, cancel = core.WithCancel(t:Context())

    local ok, err = pcall(function()
        local result = execute.CommandLine(ctx, sys, { "--watch", "--runExternalCode" }, testSys)
        local w = result.watcher
        local fullBuilds = w:FullBuilds()

        testSys:writeFileNoError(mapperConfigFileName, [[{ "version": 2 }]])
        testSys.mockWatchBackend:SendEvents({ eventUpdate(mapperConfigFileName) })
        w:DoCycle()

        assertEqual(t, w:FullBuilds(), fullBuilds + 1)
        assertEqual(t, lifecycle.opens, 2)
        assertEqual(t, lifecycle.closes, 1)
        assertEqual(t, spawner.spawns, 1)
        assertEqual(t, spawner.closes, 0)
    end)
    cancel()
    if not ok then
        error(err, 0)
    end
end

function tsctests.TestContentMapperMixedWatchBatchForcesFullRebuild(t)
    t:Parallel()
    local cmt = contentmappertest()
    local mappedFileName = "/home/src/workspaces/project/app.vue"
    local mainFileName = "/home/src/workspaces/project/main.ts"
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "noLib": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        [mappedFileName] = "export const marker = 1 as const;",
        [mainFileName] = [[import { marker } from "./app.vue"; const check: 1 = marker;]],
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.VerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    testSys.currentWrite:Reset()
    local sys = tsctests.newRecordingContentMapperSystem(testSys, tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), nil))
    local ctx, cancel = core.WithCancel(t:Context())

    local ok, err = pcall(function()
        local result = execute.CommandLine(ctx, sys, { "--watch", "--pretty", "false", "--runExternalCode" }, testSys)
        local w = result.watcher
        local fastBuilds, fullBuilds = w:FastPathBuilds(), w:FullBuilds()
        testSys.currentWrite:Reset()
        testSys:writeFileNoError(mappedFileName, "export const marker = 2 as const;")
        testSys:writeFileNoError(mainFileName, [[import { marker } from "./app.vue"; const check: 2 = marker;]])
        testSys.mockWatchBackend:SendEvents({
            eventUpdate(mappedFileName),
            eventUpdate(mainFileName),
        })
        w:DoCycle()

        assertEqual(t, w:FullBuilds(), fullBuilds + 1)
        assertEqual(t, w:FastPathBuilds(), fastBuilds)
        assertTrue(t, not string.find(testSys.currentWrite:String(), "Type '1' is not assignable to type '2'", 1, true), testSys.currentWrite:String())
    end)
    cancel()
    if not ok then
        error(err, 0)
    end
end

function tsctests.TestDynamicContentMapperBuildWatchDependency(t)
    t:Parallel()
    local cmt = contentmappertest()
    local mapperConfigFileName = "/home/src/workspaces/project/mapper.config.json"
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"compilerOptions": { "composite": true },
			"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
		}]],
        [mapperConfigFileName] = [[{ "version": 1 }]],
        ["/home/src/workspaces/project/app.vue"] = "export const app = 1;",
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.DynamicVerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local lifecycle = cmt.NewProjectLifecycle()
    local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawnerWithProjectLifecycle(lifecycle), nil)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)
    local ctx, cancel = core.WithCancel(t:Context())

    local ok, err = pcall(function()
        local result = execute.CommandLine(ctx, sys, { "--build", "--watch", "--runExternalCode" }, testSys)
        assertEqual(t, lifecycle.opens, 1)

        testSys:writeFileNoError(mapperConfigFileName, [[{ "version": 2 }]])
        testSys.mockWatchBackend:SendEvents({ eventUpdate(mapperConfigFileName) })
        result.watcher:DoCycle()

        assertEqual(t, lifecycle.opens, 2)
        assertEqual(t, lifecycle.closes, 1)
        assertEqual(t, spawner.spawns, 1)
        assertEqual(t, spawner.closes, 0)
    end)
    cancel()
    if not ok then
        error(err, 0)
    end
end

function tsctests.TestContentMapperBuildWatchSharedLifecycle(t)
    t:Parallel()
    local cmt = contentmappertest()
    local mapperConfig = [[{
		"compilerOptions": { "composite": true },
		"contentMappers": [{ "package": "mapper", "extensions": [".vue"] }]
	}]]
    local input = tsctests.newTscInput({ files = {
        ["/home/src/workspaces/project/tsconfig.json"] = [[{
			"files": [],
			"references": [{ "path": "a" }, { "path": "b" }]
		}]],
        ["/home/src/workspaces/project/a/tsconfig.json"] = mapperConfig,
        ["/home/src/workspaces/project/a/app.vue"] = "export const a = 1;",
        ["/home/src/workspaces/project/b/tsconfig.json"] = mapperConfig,
        ["/home/src/workspaces/project/b/app.vue"] = "export const b = 1;",
        ["/home/src/workspaces/project/node_modules/mapper/package.json"] = cmt.PackageJSON(cmt.VerbatimMapper),
    } })
    local testSys = tsctests.newTestSys(input, false)
    local spawner = tsctests.newRecordingContentMapperSpawner(cmt.NewSpawner(), nil)
    local sys = tsctests.newRecordingContentMapperSystem(testSys, spawner)
    local ctx, cancel = core.WithCancel(t:Context())

    local ok, err = pcall(function()
        local result = execute.CommandLine(ctx, sys, { "--build", "--watch", "--runExternalCode" }, testSys)
        assertTrue(t, result.watcher ~= nil)
        assertEqual(t, spawner.spawns, 1)
        assertEqual(t, spawner.closes, 0)

        for _, project in ipairs({ "a", "b" }) do
            local configFileName = "/home/src/workspaces/project/" .. project .. "/tsconfig.json"
            testSys:writeFileNoError(configFileName, [[{ "compilerOptions": { "composite": true } }]])
            testSys.mockWatchBackend:SendEvents({ eventUpdate(configFileName) })
            result.watcher:DoCycle()
            if project == "a" then
                assertEqual(t, spawner.closes, 0)
            else
                assertEqual(t, spawner.closes, 1)
            end
        end
    end)
    cancel()
    if not ok then
        error(err, 0)
    end
end

-- The Test* functions of this file, in Go source order.
tsctests.contentMapperWatchTests = {
    "TestContentMapperBuildLifecycle",
    "TestContentMapperBuildIdentityFailureExitStatus",
    "TestContentMapperWatchLifecycle",
    "TestContentMapperSupplementalCollisionWatch",
    "TestDynamicContentMapperWatchDependency",
    "TestContentMapperMixedWatchBatchForcesFullRebuild",
    "TestDynamicContentMapperBuildWatchDependency",
    "TestContentMapperBuildWatchSharedLifecycle",
}

return tsctests
