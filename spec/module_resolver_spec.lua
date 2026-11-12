-- Port of internal/module/resolver_test.go: TestResolveModuleNameTrailingSlashRace,
-- TestResolveSubpathNilContentsRace, TestParseNodeModuleFromPath and
-- TestResolvePeerDependencyNilContentsRace (TestResolveModuleNameTrailingSlash is in
-- spec/module_spec.lua).
--
-- The race tests drive two goroutines through gated FS calls. The Lua port is sequential, so
-- goroutines are coroutines run by a small cooperative scheduler; channels and gates become
-- counters/flags that blocked coroutines poll by yielding. This reproduces the same interleaving
-- the Go test forces.
local core = require("tslua.core")
local module = require("tslua.module")
local vfstest = require("tslua.vfs.vfstest")

local ModuleKind = core.ModuleKind

local function newResolutionHostStub(fs, cwd)
    return {
        FS = function()
            return fs
        end,
        GetCurrentDirectory = function()
            return cwd
        end,
    }
end

-- Embeds a vfs.FS (Go struct embedding): methods not defined on the wrapper go to the inner FS.
local function embedFS(inner, wrapper)
    wrapper.inner = inner
    return setmetatable(wrapper, {
        __index = function(_, k)
            local v = inner[k]
            if type(v) == "function" then
                return function(_, ...)
                    return v(inner, ...)
                end
            end
            return v
        end,
    })
end

-- Cooperative scheduler standing in for goroutines, channels and sync.WaitGroup.
local function newScheduler()
    local s = { routines = {} }

    function s.Go(fn)
        s.routines[#s.routines + 1] = coroutine.create(fn)
    end

    -- Resumes every live goroutine once. Returns the number still alive.
    function s.step()
        local alive = 0
        for _, co in ipairs(s.routines) do
            if coroutine.status(co) ~= "dead" then
                local ok, err = coroutine.resume(co)
                if not ok then
                    error(err, 0)
                end
                if coroutine.status(co) ~= "dead" then
                    alive = alive + 1
                end
            end
        end
        return alive
    end

    -- Runs goroutines until cond() holds; returns false on deadlock (Go: test context timeout).
    function s.runUntil(cond)
        for _ = 1, 10000 do
            if cond() then
                return true
            end
            if s.step() == 0 then
                return cond()
            end
        end
        return cond()
    end

    function s.Wait()
        assert.is_true(s.runUntil(function()
            for _, co in ipairs(s.routines) do
                if coroutine.status(co) ~= "dead" then
                    return false
                end
            end
            return true
        end), "goroutines deadlocked")
    end

    return s
end

local function newChan()
    return { count = 0, closed = false }
end

local function send(ch)
    ch.count = ch.count + 1
end

local function close(ch)
    ch.closed = true
end

-- Blocks the current goroutine until ch can be received from.
local function recv(ch)
    while not ch.closed and ch.count == 0 do
        coroutine.yield()
    end
    if not ch.closed then
        ch.count = ch.count - 1
    end
end

-- waitForSignal waits for a synchronization point in these race regression
-- tests and converts deadlocks into deterministic test failures.
local function waitForSignal(sched, ch, description)
    local ok = sched.runUntil(function()
        return ch.closed or ch.count > 0
    end)
    if not ok then
        error("timed out waiting for " .. description, 2)
    end
    if not ch.closed then
        ch.count = ch.count - 1
    end
end

-- blockingFS wraps a vfs.FS and forces FileExists calls for `targetPath` to
-- block on `gate` until released. Each caller sends on `arrived` when it
-- reaches the gate.
local function newBlockingFS(fs, targetPath)
    local f
    f = embedFS(fs, {
        targetPath = targetPath,
        gate = newChan(),
        arrived = newChan(),
        FileExists = function(_, path)
            if path == f.targetPath then
                send(f.arrived)
                recv(f.gate)
            end
            return fs:FileExists(path)
        end,
    })
    return f
end

-- flipFileExistsFS wraps a vfs.FS and returns false for the first
-- FileExists call to `targetPath`, then true for the second. Both calls
-- signal arrival via channel then block until released via their respective
-- gate channels. ReadFile for the target path also signals arrival then
-- blocks, so the "file doesn't exist" Set completes before the "file exists"
-- Set (reproducing the LoadOrStore race).
local function newFlipFileExistsFS(fs, targetPath)
    local f
    f = embedFS(fs, {
        targetPath = targetPath,
        callCount = 0,
        firstArrived = newChan(),
        secondArrived = newChan(),
        firstGate = newChan(),
        secondGate = newChan(),
        readArrived = newChan(),
        readGate = newChan(),
        FileExists = function(_, path)
            if path == f.targetPath then
                f.callCount = f.callCount + 1
                local n = f.callCount
                if n == 1 then
                    close(f.firstArrived)
                    recv(f.firstGate)
                    return false -- first caller: simulate "file not yet visible"
                end
                if n == 2 then
                    close(f.secondArrived)
                    recv(f.secondGate)
                    return fs:FileExists(path) -- second caller: file is visible
                end
            end
            return fs:FileExists(path)
        end,
        ReadFile = function(_, path)
            if path == f.targetPath then
                close(f.readArrived)
                recv(f.readGate)
            end
            return fs:ReadFile(path)
        end,
    })
    return f
end

local function bundlerOptions()
    return core.NewCompilerOptions({
        moduleResolution = core.ModuleResolutionKind.Bundler,
        module = ModuleKind.ESNext,
        target = core.ScriptTarget.ESNext,
    })
end

-- Regression test for https://github.com/microsoft/typescript-go/issues/3526.
describe("TestResolveModuleNameTrailingSlashRace", function()
    it("TestResolveModuleNameTrailingSlashRace", function()
        local pkgJSONPath = "/repo/node_modules/pkg/package.json"
        local files = {
            -- `types` points at a file that is not discoverable through any
            -- fallback path: there is no `index.*` and no `main`. The only way
            -- to resolve `pkg` (or `pkg/`) is via the package.json `types` field
            -- inside `loadNodeModuleFromDirectoryWorker`, which is exactly the
            -- step that the bug skips when `candidate` and
            -- `packageInfo.PackageDirectory` mismatch.
            [pkgJSONPath] = '{"name":"pkg","types":"./typings/index.d.ts"}',
            ["/repo/node_modules/pkg/typings/index.d.ts"] = "export const x: number;",
            -- Distinct containing files so each `ResolveModuleName` call has a
            -- unique module-resolution-cache key.
            ["/repo/src/a/file.ts"] = "",
            ["/repo/src/b/file.ts"] = "",
        }
        local fs = newBlockingFS(vfstest.FromMap(files, true), pkgJSONPath)
        local host = newResolutionHostStub(fs, "/repo")
        local resolver = module.NewResolver(host, bundlerOptions(), "", "", nil)

        local results = {}
        local sched = newScheduler()
        for _, name in ipairs({ "pkg", "pkg/" }) do
            local containingFile = "/repo/src/a/file.ts"
            if string.sub(name, -1) == "/" then
                containingFile = "/repo/src/b/file.ts"
            end
            sched.Go(function()
                local r = resolver:ResolveModuleName(name, containingFile, ModuleKind.ESNext, nil)
                results[#results + 1] = { name = name, resolved = r:IsResolved() }
            end)
        end

        -- Wait for both goroutines to reach the FileExists gate, guaranteeing
        -- both have observed a package.json info-cache miss.
        waitForSignal(sched, fs.arrived, "first FileExists gate arrival")
        waitForSignal(sched, fs.arrived, "second FileExists gate arrival")
        close(fs.gate)

        sched.Wait()
        assert.are.equal(2, #results)
        for _, r in ipairs(results) do
            assert.is_true(r.resolved, r.name .. " failed to resolve")
        end
    end)
end)

-- Regression test for https://github.com/microsoft/typescript-go/issues/1290.
describe("TestResolveSubpathNilContentsRace", function()
    it("TestResolveSubpathNilContentsRace", function()
        local rootPkgJSON = "/repo/node_modules/pkg/package.json"
        local files = {
            [rootPkgJSON] = '{"name":"pkg","version":"1.0.0"}',
            ["/repo/node_modules/pkg/sub/index.d.ts"] = "export declare const sub: number;",
            ["/repo/node_modules/pkg/sub/index.js"] = "exports.sub = 1;",
            ["/repo/src/a/file.ts"] = "",
            ["/repo/src/b/file.ts"] = "",
        }
        local fs = newFlipFileExistsFS(vfstest.FromMap(files, true), rootPkgJSON)
        local host = newResolutionHostStub(fs, "/repo")
        local resolver = module.NewResolver(host, bundlerOptions(), "", "", nil)

        local panicked = false
        local results = {}
        local sched = newScheduler()
        -- Two goroutines both resolve "pkg/sub". Each calls getPackageJsonInfo
        -- for the root package directory, reaching FileExists for rootPkgJSON.
        for _, containingFile in ipairs({ "/repo/src/a/file.ts", "/repo/src/b/file.ts" }) do
            sched.Go(function()
                local resolved = false
                local ok = pcall(function()
                    local r = resolver:ResolveModuleName("pkg/sub", containingFile, ModuleKind.ESNext, nil)
                    resolved = r:IsResolved()
                end)
                if not ok then
                    panicked = true
                end
                results[#results + 1] = { containingFile = containingFile, resolved = resolved }
            end)
        end

        -- Phase 1: Wait for both goroutines to reach FileExists for the root
        -- package.json, guaranteeing both have observed a cache miss.
        waitForSignal(sched, fs.firstArrived, "first root package.json FileExists arrival")
        waitForSignal(sched, fs.secondArrived, "second root package.json FileExists arrival")

        -- Phase 2: Release the first FileExists caller (returns false).
        close(fs.firstGate)

        -- Phase 3: Release the second FileExists caller (returns true).
        close(fs.secondGate)

        -- Phase 4: Wait for the second goroutine to reach ReadFile, then release.
        waitForSignal(sched, fs.readArrived, "root package.json ReadFile arrival")
        close(fs.readGate)

        sched.Wait()
        assert.is_false(panicked, "resolver panicked due to nil Contents dereference in loadModuleFromSpecificNodeModulesDirectory")
        assert.are.equal(2, #results)
        for _, r in ipairs(results) do
            assert.is_true(r.resolved, r.containingFile .. " failed to resolve pkg/sub")
        end
    end)
end)

describe("TestParseNodeModuleFromPath", function()
    local tests = {
        { "file in package", "/a/node_modules/b/lib/index.d.ts", false, "/a/node_modules/b" },
        { "file in scoped package", "/a/node_modules/@scope/b/lib/index.d.ts", false, "/a/node_modules/@scope/b" },
        { "folder subpath", "/a/node_modules/b/lib/File", true, "/a/node_modules/b" },
        { "folder subpath scoped", "/a/node_modules/@scope/b/lib/File", true, "/a/node_modules/@scope/b" },
        { "package root folder", "/a/node_modules/b", true, "/a/node_modules/b" },
        { "scoped package root folder", "/a/node_modules/@scope/b", true, "/a/node_modules/@scope/b" },
        -- A bare scope directory has no package name; must not panic (https://github.com/microsoft/typescript-go/issues/4373).
        { "scope-only folder", "/a/node_modules/@scope", true, "/a/node_modules/@scope" },
        { "types scope-only folder", "/a/node_modules/@types", true, "/a/node_modules/@types" },
        { "not in node_modules", "/a/src/index.ts", false, "" },
    }

    for _, tt in ipairs(tests) do
        it(tt[1], function()
            assert.are.equal(tt[4], module.ParseNodeModuleFromPath(tt[2], tt[3]))
        end)
    end
end)

-- Regression test for https://github.com/microsoft/typescript-go/issues/4478.
describe("TestResolvePeerDependencyNilContentsRace", function()
    it("TestResolvePeerDependencyNilContentsRace", function()
        local peerPkgJSON = "/repo/node_modules/peer/package.json"
        local files = {
            ["/repo/node_modules/pkg/package.json"] = '{"name":"pkg","version":"1.0.0","types":"index.d.ts","peerDependencies":{"peer":"*"}}',
            ["/repo/node_modules/pkg/index.d.ts"] = "export declare const x: number;",
            [peerPkgJSON] = '{"name":"peer","version":"2.0.0"}',
            ["/repo/src/a/file.ts"] = "",
            ["/repo/src/b/file.ts"] = "",
        }
        local fs = newFlipFileExistsFS(vfstest.FromMap(files, true), peerPkgJSON)
        local host = newResolutionHostStub(fs, "/repo")
        local resolver = module.NewResolver(host, bundlerOptions(), "", "", nil)

        local panicked = false
        local results = {}
        local sched = newScheduler()
        for _, containingFile in ipairs({ "/repo/src/a/file.ts", "/repo/src/b/file.ts" }) do
            sched.Go(function()
                local resolved = false
                local ok = pcall(function()
                    local r = resolver:ResolveModuleName("pkg", containingFile, ModuleKind.ESNext, nil)
                    resolved = r:IsResolved()
                end)
                if not ok then
                    panicked = true
                end
                results[#results + 1] = { containingFile = containingFile, resolved = resolved }
            end)
        end

        waitForSignal(sched, fs.firstArrived, "first peer package.json FileExists arrival")
        waitForSignal(sched, fs.secondArrived, "second peer package.json FileExists arrival")
        close(fs.firstGate)
        assert.is_true(sched.runUntil(function()
            return #results > 0
        end), "timed out waiting for first peer package.json lookup to finish")
        local firstResult = table.remove(results, 1)
        close(fs.secondGate)
        waitForSignal(sched, fs.readArrived, "peer package.json ReadFile arrival")
        close(fs.readGate)

        sched.Wait()
        assert.is_false(panicked, "resolver panicked due to nil Contents dereference in readPackageJsonPeerDependencies")
        assert.is_true(firstResult.resolved, firstResult.containingFile .. " failed to resolve pkg")
        for _, r in ipairs(results) do
            assert.is_true(r.resolved, r.containingFile .. " failed to resolve pkg")
        end
    end)
end)
