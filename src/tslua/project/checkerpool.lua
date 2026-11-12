local project = require("tslua.project")
local checker = require("tslua.checker")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local debug = require("tslua.debug")

-- checkerHeldAnonymous is a sentinel stored in heldBy when a checker is held
-- by a caller that has no request ID (e.g., context.Background()). This
-- distinguishes "held without ID" from "not held" (empty string).
project.checkerHeldAnonymous = "<anonymous>"

-- CheckerPoolOptions: { maxCheckers = int, idleTimeout = seconds }
-- MaxCheckers controls the total number of checker slots per project
-- (1 dedicated diagnostics checker + N-1 query checkers). Minimum 2.
-- Zero uses the default (4).
-- IdleTimeout controls how long an idle checker is kept
-- before being disposed. Zero uses the default (30s).
function project.NewCheckerPoolOptions(fields)
    fields = fields or {}
    return { maxCheckers = fields.maxCheckers or 0, idleTimeout = fields.idleTimeout or 0 }
end

-- A semaphore channel (chan struct{} with capacity). Sends block in Go when full; in the
-- sequential port nothing could ever release the slot, so a full send is a deadlock error.
local function newSem(capacity)
    return { capacity = capacity, count = 0 }
end

local function semAcquire(sem)
    if sem.count >= sem.capacity then
        error("checkerpool: deadlock: all slots are held (sequential port cannot block)", 0)
    end
    sem.count = sem.count + 1
end

local function semRelease(sem)
    sem.count = sem.count - 1
end

-- checkerPool manages three categories of type checkers for a project:
--
--   - Diagnostics (index 0): A single checker for LSP diagnostics, providing
--     consistent walk order. Idle-cleaned.
--   - Temporary (indices 1+): Ephemeral query checkers for LSP operations.
--     Idle-cleaned after a configurable timeout.
--   - API: A single checker for API operations, providing stable
--     instance identity for reference equality on type/symbol handles.
--     Never idle-cleaned.
--
-- Arrays checkers/heldBy/lastReleased/globalDiagCheckerCount are indexed by the 0-based
-- checker index (stored at index + 1). lastReleased[i] is nil for the zero time.
local checkerPool = {}
checkerPool.__index = checkerPool
project.checkerPool = checkerPool

function project.newCheckerPool(opts, program, log)
    opts = { maxCheckers = opts.maxCheckers or 0, idleTimeout = opts.idleTimeout or 0 }
    if opts.maxCheckers <= 0 then
        opts.maxCheckers = 4
    elseif opts.maxCheckers < 2 then
        opts.maxCheckers = 2 -- at least 1 diagnostics + 1 query checker
    end
    if opts.idleTimeout <= 0 then
        opts.idleTimeout = 30
    end
    local querySlots = opts.maxCheckers - 1
    local pool = setmetatable({
        program = program,
        opts = opts,
        discarded = false,
        checkers = {},
        heldBy = {},
        fileAssociations = {},
        requestAssociations = {},
        lastReleased = {},
        cleanupTimer = nil,
        persistentChecker = nil,
        persistentHeld = false,
        diagSem = newSem(1),
        querySem = newSem(querySlots),
        persistentSem = newSem(1),
        log = log,
        globalDiagAccumulated = nil,
        globalDiagChanged = false,
        globalDiagCheckerCount = {},
    }, checkerPool)
    for i = 1, opts.maxCheckers do
        pool.checkers[i] = false
        pool.heldBy[i] = ""
        pool.lastReleased[i] = false
        pool.globalDiagCheckerCount[i] = 0
    end

    if pool.log == nil then
        pool.log = function(msg) end
    end
    return pool
end

local function checkerAt(p, index)
    local c = p.checkers[index + 1]
    if c == false then
        return nil
    end
    return c
end

-- holdTag returns the value to store in heldBy for the given request ID.
function project.holdTag(requestID)
    if requestID == "" then
        return project.checkerHeldAnonymous
    end
    return requestID
end

-- GetChecker returns (checker, release).
function checkerPool:GetChecker(ctx, file)
    local lifetime = core.GetCheckerLifetime(ctx)
    local requestID = core.GetRequestID(ctx)

    -- Request affinity is cleaned up via context.AfterFunc when the request
    -- context is done. If the context can never be canceled (ctx.Done() == nil,
    -- e.g. context.Background()), that cleanup would never run and
    -- requestAssociations would grow unboundedly, so disable affinity entirely.
    if not core.ContextDone(ctx) then
        requestID = ""
    end

    if lifetime == core.CheckerLifetime.Diagnostics then
        return self:getDiagnosticsChecker(ctx, requestID)
    elseif lifetime == core.CheckerLifetime.API then
        return self:getPersistentChecker()
    end
    return self:getQueryChecker(ctx, requestID, file)
end

-- tryReacquireForRequest checks whether the given request already has an
-- associated checker. If so, it either returns the checker directly (still held)
-- or reacquires it by claiming a semaphore slot. The caller must provide the
-- appropriate semaphore channel and indicate whether this is a diagnostics
-- request (isDiag). If the associated checker is in the wrong category
-- (e.g. a diagnostics index for a query request), the association is deleted
-- and normal acquisition proceeds.
--
-- Returns (checker, release, true) if the request was served (either still held
-- or reclaimed). Returns (nil, nil, false) if the caller must proceed with
-- normal acquisition — in this case, a semaphore slot has already been claimed.
function checkerPool:tryReacquireForRequest(requestID, sem, isDiag)
    if requestID == "" then
        semAcquire(sem)
        return nil, nil, false
    end

    local index = self.requestAssociations[requestID]
    if index == nil then
        semAcquire(sem)
        return nil, nil, false
    end

    -- Validate that the associated index matches the expected category.
    -- Index 0 is for diagnostics; indices 1+ are for queries.
    if (isDiag and index ~= 0) or (not isDiag and index == 0) then
        self.requestAssociations[requestID] = nil
        semAcquire(sem)
        return nil, nil, false
    end

    local c = checkerAt(self, index)
    if c == nil then
        self.requestAssociations[requestID] = nil
        semAcquire(sem)
        return nil, nil, false
    end

    local held = self.heldBy[index + 1]
    if held == requestID then
        -- Same request, checker still held — return without claiming a slot.
        return c, project.noop, true
    end

    if held == "" then
        -- Same request reacquiring after release — need a semaphore slot.
        semAcquire(sem)
        -- Re-check: checker may have been disposed while waiting for the slot.
        if checkerAt(self, index) == c and self.heldBy[index + 1] == "" then
            self.heldBy[index + 1] = requestID
            return c, self:createRelease(requestID, index, c), true
        end
        -- Checker was replaced/disposed while waiting for the slot.
        -- The slot is still claimed; the caller will use it for normal acquisition.
        return nil, nil, false
    end

    -- Checker held by another request — claim a slot normally.
    semAcquire(sem)
    return nil, nil, false
end

-- getDiagnosticsChecker returns the dedicated diagnostics checker (index 0).
-- Creates it on first use. Blocks on diagSem if it's currently in use.
function checkerPool:getDiagnosticsChecker(ctx, requestID)
    local diagIndex = 0

    local c, release, ok = self:tryReacquireForRequest(requestID, self.diagSem, true)
    if ok then
        return c, release
    end

    -- Token consumed — proceed with normal acquisition.
    if checkerAt(self, diagIndex) == nil then
        self.log("checkerpool: Creating diagnostics checker")
        local nc = checker.NewChecker(self.program, nil)
        self.checkers[diagIndex + 1] = nc
    end

    c = checkerAt(self, diagIndex)
    self.heldBy[diagIndex + 1] = project.holdTag(requestID)
    self.log("checkerpool: Acquired diagnostics checker for request " .. project.holdTag(requestID))
    if requestID ~= "" then
        if self.requestAssociations[requestID] == nil then
            self.requestAssociations[requestID] = diagIndex
            self:registerRequestCleanup(ctx, requestID)
        end
    end
    return c, self:createRelease(requestID, diagIndex, c)
end

-- getQueryChecker returns an ephemeral query checker from indices 1+.
-- Uses request affinity, then file affinity, then finds/creates.
-- Blocks on querySem if all query slots are in use.
function checkerPool:getQueryChecker(ctx, requestID, file)
    local c, release, ok = self:tryReacquireForRequest(requestID, self.querySem, false)
    if ok then
        return c, release
    end

    -- Token consumed — proceed with normal acquisition.

    -- Try file affinity.
    if file ~= nil then
        local index = self.fileAssociations[file]
        if index ~= nil and index > 0 then
            c = checkerAt(self, index)
            if c ~= nil and self.heldBy[index + 1] == "" then
                self.heldBy[index + 1] = project.holdTag(requestID)
                if requestID ~= "" then
                    if self.requestAssociations[requestID] == nil then
                        self.requestAssociations[requestID] = index
                        self:registerRequestCleanup(ctx, requestID)
                    end
                end
                return c, self:createRelease(requestID, index, c)
            end
        end
    end

    -- Find any available query checker or create one.
    local index
    c, index = self:findOrCreateQueryCheckerLocked()
    self.heldBy[index + 1] = project.holdTag(requestID)
    self.log(string.format("checkerpool: Acquired query checker %d for request %s", index, project.holdTag(requestID)))
    if requestID ~= "" then
        if self.requestAssociations[requestID] == nil then
            self.requestAssociations[requestID] = index
            self:registerRequestCleanup(ctx, requestID)
        end
    end
    if file ~= nil then
        self.fileAssociations[file] = index
    end
    return c, self:createRelease(requestID, index, c)
end

-- findOrCreateQueryCheckerLocked returns an idle query checker or creates one
-- in the first empty slot. The semaphore guarantees at least one slot is
-- available. Returns (checker, index).
function checkerPool:findOrCreateQueryCheckerLocked()
    -- Prefer an existing idle checker.
    for i = 1, #self.checkers - 1 do
        local c = checkerAt(self, i)
        if c ~= nil and self.heldBy[i + 1] == "" then
            return c, i
        end
    end
    -- Create in the first empty slot.
    for i = 1, #self.checkers - 1 do
        if checkerAt(self, i) == nil then
            self.log(string.format("checkerpool: Creating query checker %d", i))
            local c = checker.NewChecker(self.program, nil)
            self.checkers[i + 1] = c
            return c, i
        end
    end
    error("checkerpool: no available query slot despite holding semaphore token", 0)
end

function checkerPool:getPersistentChecker()
    semAcquire(self.persistentSem)

    if self.persistentChecker == nil then
        self.log("checkerpool: Creating persistent checker")
        local nc = checker.NewChecker(self.program, nil)
        self.persistentChecker = nc
    end

    local c = self.persistentChecker
    self.persistentHeld = true

    return c, project.onceFunc(function()
        self.persistentHeld = false
        if c:WasCanceled() then
            -- A canceled checker panics on reuse, so drop it; the next API
            -- acquisition will create a fresh persistent checker.
            self.log("checkerpool: Persistent checker was canceled, disposing")
            if self.persistentChecker == c then
                self.persistentChecker = nil
            end
        end
        semRelease(self.persistentSem)
    end)
end

function checkerPool:createRelease(requestID, index, c)
    return project.onceFunc(function()
        if c:WasCanceled() then
            -- Canceled checkers must be disposed.
            self.log(string.format("checkerpool: Checker %d for request %s was canceled, disposing", index, project.holdTag(requestID)))
            self:disposeCheckerLocked(index, c)
        else
            self:mergeGlobalDiagnosticsFromCheckerLocked(index, c)
            self.heldBy[index + 1] = ""
            self.lastReleased[index + 1] = project.now()
            if not self.discarded then
                self:scheduleCleanupLocked()
            end
            -- If discarded, skip scheduling cleanup — checkers stay alive
            -- until the pool is garbage collected so that API clients can
            -- continue resolving type/symbol handles.
        end

        -- Release the semaphore slot.
        if index == 0 then
            semRelease(self.diagSem)
        else
            semRelease(self.querySem)
        end
    end)
end

-- registerRequestCleanup uses context.AfterFunc to delete the request
-- association when the request context is done. This prevents the map
-- from growing unboundedly with completed request IDs.
function checkerPool:registerRequestCleanup(ctx, requestID)
    core.AfterFunc(ctx, function()
        self.requestAssociations[requestID] = nil
    end)
end

-- scheduleCleanupLocked resets (or starts) the cleanup timer so it fires at
-- the earliest pending checker-expiration deadline among all currently idle,
-- unheld checkers.
-- Must NOT be called on discarded pools.
function checkerPool:scheduleCleanupLocked()
    local earliestDeadline = nil
    for i = 1, #self.checkers do
        if self.checkers[i] == false or self.heldBy[i] ~= "" or self.lastReleased[i] == false then
            goto continue
        end
        do
            local deadline = self.lastReleased[i] + self.opts.idleTimeout
            if earliestDeadline == nil or deadline < earliestDeadline then
                earliestDeadline = deadline
            end
        end
        ::continue::
    end
    if earliestDeadline == nil then
        -- No idle checkers remain — stop the timer if it exists.
        if self.cleanupTimer ~= nil then
            self.cleanupTimer:Stop()
            self.cleanupTimer = nil
        end
        return
    end
    local delay = earliestDeadline - project.now()
    if delay <= 0 then
        delay = 0.001
    end
    if self.cleanupTimer ~= nil then
        self.cleanupTimer:Reset(delay)
    else
        self.cleanupTimer = project.afterFunc(delay, function()
            self:cleanupIdleCheckers()
        end)
    end
end

-- cleanupIdleCheckers disposes checkers that have been idle for longer than
-- the idle timeout. The API checker is separate and never idle-cleaned.
function checkerPool:cleanupIdleCheckers()
    -- The timer callback may already have been in flight when Discard() called
    -- Stop() (which does not guarantee the callback won't run). Bail out without
    -- rescheduling so a discarded pool doesn't keep itself alive via a new timer.
    if self.discarded then
        return
    end
    local now = project.now()
    for i = 1, #self.checkers do
        local c = self.checkers[i]
        if c == false or self.heldBy[i] ~= "" then
            goto continue
        end
        if self.lastReleased[i] == false then
            goto continue
        end
        do
            local idle = now - self.lastReleased[i]
            if idle >= self.opts.idleTimeout then
                self.log("checkerpool: Disposing idle checker " .. (i - 1) .. " (idle " .. project.Duration.String({ seconds = idle }) .. ")")
                self:disposeCheckerLocked(i - 1, c)
            end
        end
        ::continue::
    end
    -- Reschedule for any remaining idle-but-not-yet-expired checkers.
    -- scheduleCleanupLocked will Reset the existing timer rather than
    -- creating a new one, avoiding goroutine leaks.
    self:scheduleCleanupLocked()
end

-- disposeCheckerLocked removes a checker from the pool and clears all associations
-- (file and request) that reference it.
function checkerPool:disposeCheckerLocked(index, c)
    debug.Assert(checkerAt(self, index) == c)
    self.checkers[index + 1] = false
    self.heldBy[index + 1] = ""
    self.globalDiagCheckerCount[index + 1] = 0
    self.lastReleased[index + 1] = false
    for file, idx in pairs(self.fileAssociations) do
        if idx == index then
            self.fileAssociations[file] = nil
        end
    end
    for req, idx in pairs(self.requestAssociations) do
        if idx == index then
            self.requestAssociations[req] = nil
        end
    end
end

-- mergeGlobalDiagnosticsFromCheckerLocked checks if the given checker has produced new global
-- diagnostics since the last time we looked, and if so merges them into the accumulated set.
function checkerPool:mergeGlobalDiagnosticsFromCheckerLocked(index, c)
    local globals = c:GetGlobalDiagnostics()
    if core.Len(globals) == self.globalDiagCheckerCount[index + 1] then
        return
    end
    self.globalDiagCheckerCount[index + 1] = core.Len(globals)
    local before = core.Len(self.globalDiagAccumulated)
    local combined = {}
    for _, d in ipairs(self.globalDiagAccumulated or {}) do
        combined[#combined + 1] = d
    end
    for _, d in ipairs(globals or {}) do
        combined[#combined + 1] = d
    end
    self.globalDiagAccumulated = compiler.SortAndDeduplicateDiagnostics(combined)
    if core.Len(self.globalDiagAccumulated) ~= before then
        self.globalDiagChanged = true
    end
end

-- GetGlobalDiagnostics returns the accumulated global diagnostics collected from
-- all checkers that have been used so far in this pool's lifetime.
function checkerPool:GetGlobalDiagnostics()
    if self.globalDiagAccumulated == nil then
        return nil
    end
    return core.Slice(self.globalDiagAccumulated)
end

-- TakeNewGlobalDiagnostics reports whether new global diagnostics have been
-- accumulated since the last call, and resets the flag.
function checkerPool:TakeNewGlobalDiagnostics()
    local changed = self.globalDiagChanged
    self.globalDiagChanged = false
    return changed
end

-- Discard signals that this pool's program has been replaced. The pool
-- remains functional but stops its idle-cleanup timer so that checkers
-- are not disposed until the pool is GC'd. The API checker is unaffected
-- since it is never idle-cleaned.
function checkerPool:Discard()
    if self.discarded then
        return -- already discarded
    end
    self.log("checkerpool: Discarding pool, stopping idle cleanup")
    self.discarded = true
    if self.cleanupTimer ~= nil then
        self.cleanupTimer:Stop()
        self.cleanupTimer = nil
    end
end

function project.noop() end
