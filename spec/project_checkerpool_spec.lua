-- Ported from internal/project/checkerpool_test.go. Go's synctest fake time is emulated with
-- project.UseFakeClock/AdvanceFakeTime; the contention tests (which need a blocked goroutine)
-- are not portable to the sequential port.
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local logging = require("tslua.project.logging")
local vfstest = require("tslua.vfs.vfstest")

local Lifetime = core.CheckerLifetime

local function setupCheckerPoolSession(opts)
    local files = {
        ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
        ["/src/index.ts"] = "export const x: number = 1;",
    }
    local fs = bundled.WrapFS(vfstest.FromMap(files, false))
    local session = project.NewSession({
        backgroundCtx = nil,
        options = project.NewSessionOptions({
            currentDirectory = "/",
            defaultLibraryPath = bundled.LibPath(),
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = false,
            loggingEnabled = true,
            checkerPoolOptions = opts,
        }),
        fs = fs,
        logger = logging.NewTestLogger(),
    })
    session:DidOpenFile(nil, "file:///src/index.ts", 1, "export const x: number = 1;", lsproto.LanguageKind.TypeScript)
    local p = session:Snapshot().projectCollection:ConfiguredProject("/src/tsconfig.json")
    assert.is_not_nil(p)
    assert.is_not_nil(p.checkerPool)
    return session, p.checkerPool
end

local function programOf(session)
    local ls, err = session:GetLanguageService(nil, "file:///src/index.ts")
    assert.is_nil(err)
    return ls:GetProgram()
end

local function newTestCheckerPool(program, opts)
    return project.newCheckerPool(opts, program, function() end)
end

local function requestCtx(parent, id, lifetime)
    return core.WithCheckerLifetime(core.WithRequestID(parent, id), lifetime)
end

local function checkerAt(pool, index)
    local c = pool.checkers[index + 1]
    if c == false then
        return nil
    end
    return c
end

describe("project checkerPool", function()
    after_each(function()
        project.UseRealClock()
    end)

    it("DiagnosticsRouting", function()
        local _, pool = setupCheckerPoolSession({ maxCheckers = 4, idleTimeout = 10 })
        -- Diagnostics requests should get checker at index 0.
        local c, release = pool:GetChecker(requestCtx(nil, "diag-req-1", Lifetime.Diagnostics), nil)
        assert.is_not_nil(c)
        assert.are.equal(c, checkerAt(pool, 0))
        release()
    end)

    it("QueryRouting", function()
        local _, pool = setupCheckerPoolSession({ maxCheckers = 4, idleTimeout = 10 })
        -- Query requests should get a checker at index > 0.
        local c, release = pool:GetChecker(requestCtx(nil, "query-req-1", Lifetime.Temporary), nil)
        assert.is_not_nil(c)
        assert.are_not.equal(c, checkerAt(pool, 0))
        release()
    end)

    it("RequestAffinity", function()
        local _, pool = setupCheckerPoolSession({ maxCheckers = 4, idleTimeout = 10 })
        local base, cancel = core.WithCancel(nil)
        local ctx = requestCtx(base, "req-affinity", Lifetime.Temporary)

        -- First call acquires.
        local c1, release1 = pool:GetChecker(ctx, nil)
        -- Second call with same request ID while still held returns same checker (noop release).
        local c2, release2 = pool:GetChecker(ctx, nil)
        release2()
        release1()
        assert.are.equal(c1, c2)

        -- After release, same request should still get the same checker (cross-release affinity).
        local c3, release3 = pool:GetChecker(ctx, nil)
        release3()
        assert.are.equal(c1, c3)
        cancel()
    end)

    it("IdleCleanup", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 5 })

        -- Create a checker via a diagnostics request.
        local c, release = pool:GetChecker(requestCtx(nil, "diag-cleanup", Lifetime.Diagnostics), nil)
        assert.is_not_nil(c)
        release()

        -- Create a query checker as well.
        local c2, release2 = pool:GetChecker(requestCtx(nil, "query-cleanup", Lifetime.Temporary), nil)
        assert.is_not_nil(c2)
        release2()

        -- Both checkers should exist.
        assert.is_not_nil(checkerAt(pool, 0))
        local queryIdx = 0
        for i = 1, #pool.checkers - 1 do
            if checkerAt(pool, i) ~= nil then
                queryIdx = i
                break
            end
        end
        assert.is_true(queryIdx > 0)

        -- Advance past idle timeout.
        project.AdvanceFakeTime(5)

        -- After cleanup, both checkers should be disposed.
        assert.is_nil(checkerAt(pool, 0))
        assert.is_nil(checkerAt(pool, queryIdx))
    end)

    it("FileAssociationCleanup", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)
        local sourceFile = program:GetSourceFile("/src/index.ts")
        assert.is_not_nil(sourceFile)

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 5 })

        -- Create a query checker with file affinity.
        local c, release = pool:GetChecker(requestCtx(nil, "file-assoc-req", Lifetime.Temporary), sourceFile)
        assert.is_not_nil(c)
        release()

        -- File association should exist.
        assert.is_not_nil(pool.fileAssociations[sourceFile])

        -- Advance past idle timeout.
        project.AdvanceFakeTime(5)

        -- File association should be cleared.
        assert.is_nil(pool.fileAssociations[sourceFile])
    end)

    it("MinCheckers", function()
        -- Requesting maxCheckers=1 should be clamped to 2.
        local _, pool = setupCheckerPoolSession({ maxCheckers = 1, idleTimeout = 10 })
        assert.are.equal(2, pool.opts.maxCheckers)
        assert.are.equal(2, #pool.checkers)
    end)

    it("DefaultIdleTimeout", function()
        -- Zero idle timeout should default to 30s.
        local _, pool = setupCheckerPoolSession({ maxCheckers = 4 })
        assert.are.equal(30, pool.opts.idleTimeout)
    end)

    it("CanceledCheckerDisposal", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)
        local sourceFile = program:GetSourceFile("/src/index.ts")

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 30 })

        -- Acquire a query checker and cancel it.
        local c, release = pool:GetChecker(requestCtx(nil, "cancel-test", Lifetime.Temporary), nil)
        assert.is_not_nil(c)

        local canceledCtx, cancel = core.WithCancel(nil)
        cancel()
        c:GetDiagnostics(canceledCtx, sourceFile)
        assert.is_true(c:WasCanceled())

        -- Release should dispose the canceled checker.
        release()

        -- Next request should get a fresh checker.
        local c2, release2 = pool:GetChecker(requestCtx(nil, "after-cancel", Lifetime.Temporary), nil)
        assert.are_not.equal(c, c2)
        release2()
    end)

    it("RequestAssociationCleanupOnDisposal", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 5 })

        local reqCtx, reqCancel = core.WithCancel(nil)
        local c, release = pool:GetChecker(requestCtx(reqCtx, "assoc-cleanup-req", Lifetime.Temporary), nil)
        assert.is_not_nil(c)

        -- Cancel the checker to trigger disposal on release.
        local canceledCtx, cancel = core.WithCancel(nil)
        cancel()
        c:GetDiagnostics(canceledCtx, program:GetSourceFile("/src/index.ts"))
        assert.is_true(c:WasCanceled())

        release()

        -- Request association should be cleared after checker disposal.
        assert.is_nil(pool.requestAssociations["assoc-cleanup-req"])
        reqCancel()
    end)

    it("RequestAssociationCleanupOnContextDone", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 30 })

        local reqCtx, reqCancel = core.WithCancel(nil)
        local c, release = pool:GetChecker(requestCtx(reqCtx, "ctx-cleanup-req", Lifetime.Temporary), nil)
        assert.is_not_nil(c)
        release()

        -- Association should still exist after release.
        assert.is_not_nil(pool.requestAssociations["ctx-cleanup-req"])

        -- Cancel the request context — association should be cleaned up.
        reqCancel()
        assert.is_nil(pool.requestAssociations["ctx-cleanup-req"])
    end)

    it("DiagnosticsRecreatedAfterIdleDisposal", function()
        local session = setupCheckerPoolSession({ maxCheckers = 2, idleTimeout = 10 })
        local program = programOf(session)

        project.UseFakeClock()
        local pool = newTestCheckerPool(program, { maxCheckers = 4, idleTimeout = 5 })

        local c1, release1 = pool:GetChecker(requestCtx(nil, "diag-recreate-1", Lifetime.Diagnostics), nil)
        assert.is_not_nil(c1)
        release1()

        -- Advance past idle timeout — diagnostics checker should be disposed.
        project.AdvanceFakeTime(5)
        assert.is_nil(checkerAt(pool, 0))

        -- Request diagnostics checker again — should get a fresh one.
        local c2, release2 = pool:GetChecker(requestCtx(nil, "diag-recreate-2", Lifetime.Diagnostics), nil)
        assert.is_not_nil(c2)
        assert.are_not.equal(c1, c2)
        release2()
    end)
end)
