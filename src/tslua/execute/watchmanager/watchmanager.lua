local watchmanager = require("tslua.execute.watchmanager")
local fswatch = require("tslua.fswatch")
local tspath = require("tslua.tspath")

-- Go's fmt "%v" of an error value.
function watchmanager.errorString(err)
    if type(err) == "table" and err.Error ~= nil then
        return err:Error()
    end
    return tostring(err)
end

-- watchedDir: { closer = io.Closer, recursive = bool }

-- dirWatchUpdate: { dir = string, recursive = bool }

-- WatchManager manages fswatch directory watches, event accumulation,
-- and DoCycle signaling. It is shared by the CLI watcher and the build
-- mode orchestrator.
--
-- Locking contract (Go): Lock/Unlock around the entire DoCycle body; the Lua port is single
-- threaded, so Lock and Unlock are no-ops.
local WatchManager = {}
WatchManager.__index = WatchManager
watchmanager.WatchManager = WatchManager

-- dirExists: func(string) bool. warnWriter: io.Writer.
function watchmanager.NewWatchManager(warnWriter, dirExists)
    return setmetatable({
        backend = nil,
        watchedDirs = {},
        -- doCycleCh is a buffered channel of capacity 1 in Go; here a pending flag.
        doCyclePending = false,
        -- DebugLog receives verbose watch diagnostics when non-nil
        debugLog = nil,
        warnWriter = warnWriter,
        dirExists = dirExists,
        changedPaths = nil,
        changedOverflow = false,
    }, WatchManager)
end

function WatchManager:SetBackend(b) self.backend = b end

function WatchManager:Backend() return self.backend end

function WatchManager:EnsureDefaultBackend()
    if self.backend == nil then
        local fsw = fswatch.Default()
        self.backend = watchmanager.NewFSWatchBackend(fsw)
        if self.debugLog ~= nil then
            self.debugLog:WriteString("[watch] using " .. fsw:Name() .. " backend\n")
        end
    end
end

function WatchManager:Lock() end

function WatchManager:Unlock() end

-- DoCycleCh returns a receive function standing in for the channel: it returns true (and
-- consumes the signal) when a DoCycle was signalled.
function WatchManager:DoCycleCh()
    return function()
        if self.doCyclePending then
            self.doCyclePending = false
            return true
        end
        return false
    end
end

-- Returns (changed map[string]fswatch.EventKind or nil, overflow bool).
function WatchManager:DrainEvents()
    local changed = self.changedPaths
    local overflow = self.changedOverflow
    self.changedPaths = nil
    self.changedOverflow = false
    return changed, overflow
end

function WatchManager:ForceOverflow()
    self.changedOverflow = true
end

function WatchManager:signalDoCycle()
    -- A signal that is already pending is coalesced.
    self.doCyclePending = true
end

function WatchManager:onWatchEvents(events, err)
    if err ~= nil then
        if fswatch.errorsIs(err, fswatch.ErrOverflow) then
            if self.debugLog ~= nil then
                self.debugLog:WriteString("[watch] event overflow, triggering rebuild\n")
            end
            self.changedOverflow = true
            self:signalDoCycle()
            return
        end
        self.warnWriter:WriteString("Warning: File watch error: " .. watchmanager.errorString(err) .. "\n")
        return
    end

    if events ~= nil and #events > 0 then
        if self.debugLog ~= nil then
            local parts = { "[watch] " .. #events .. " event(s): " }
            for i1, e in ipairs(events) do
                local i = i1 - 1
                if i > 0 then
                    parts[#parts + 1] = ", "
                end
                if i >= 5 then
                    parts[#parts + 1] = "... and " .. (#events - i) .. " more"
                    break
                end
                parts[#parts + 1] = fswatch.EventKind_String(e.kind) .. " " .. e.path
            end
            parts[#parts + 1] = "\n"
            self.debugLog:WriteString(table.concat(parts))
        end
        if self.changedPaths == nil then
            self.changedPaths = {}
        end
        for _, e in ipairs(events) do
            self.changedPaths[e.path] = e.kind
        end
        self:signalDoCycle()
    end
end

function WatchManager:handleWatchTerminated(dir, identity)
    if self.debugLog ~= nil then
        self.debugLog:WriteString("[watch] watch terminated: " .. dir .. "\n")
    end
    local staleCloser = nil
    local wd = self.watchedDirs[dir]
    if wd ~= nil and wd == identity then
        staleCloser = wd.closer
        self.watchedDirs[dir] = nil
    end
    if staleCloser ~= nil then
        staleCloser:Close()
    end
    self.changedOverflow = true
    self:signalDoCycle()
end

function WatchManager:CloseAllWatches()
    local closers = {}
    for _, dir in ipairs(watchmanager.sortedKeys(self.watchedDirs)) do
        closers[#closers + 1] = self.watchedDirs[dir].closer
        self.watchedDirs[dir] = nil
    end
    for _, c in ipairs(closers) do
        c:Close()
    end
end

function watchmanager.sortedKeys(m)
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

function WatchManager:createDirWatchRequest(dir, entry)
    return watchmanager.NewWatchDirectoryRequest(dir, function(events, err)
        if err ~= nil and fswatch.errorsIs(err, fswatch.ErrWatchTerminated) then
            self:handleWatchTerminated(dir, entry)
            return
        end
        self:onWatchEvents(events, err)
    end, entry.recursive, watchmanager.ShouldIgnoreWatchPath)
end

-- desiredDirs: map dir -> recursive. Returns a new map.
function WatchManager:ResolveDesiredDirs(desiredDirs)
    local resolved = {}
    for _, dir in ipairs(watchmanager.sortedKeys(desiredDirs)) do
        local recursive = desiredDirs[dir]
        local watchDir = dir
        local watchRecursive = recursive
        while not self.dirExists(watchDir) do
            local parent = tspath.GetDirectoryPath(watchDir)
            if parent == watchDir then
                break
            end
            watchDir = parent
            watchRecursive = false -- ancestor fallbacks are always non-recursive
        end
        if not self.dirExists(watchDir) or not watchmanager.CanWatchDirectory(watchDir) then
            if self.debugLog ~= nil then
                self.debugLog:WriteString("[watch] no watchable ancestor for " .. dir .. "\n")
            end
            goto continue
        end
        if watchDir ~= dir and self.debugLog ~= nil then
            self.debugLog:WriteString("[watch] resolved " .. dir .. " to ancestor " .. watchDir .. "\n")
        end
        do
            local existing = resolved[watchDir]
            if existing ~= nil then
                resolved[watchDir] = existing or watchRecursive
            else
                resolved[watchDir] = watchRecursive
            end
        end
        ::continue::
    end
    return resolved
end

-- Lua iteration over maps is in sorted key order where Go's is random, so that watches are
-- created and closed deterministically.
local function diffMapsSorted(m1, m2, equalValues, onAdded, onRemoved, onChanged)
    for _, k in ipairs(watchmanager.sortedKeys(m2)) do
        if m1[k] == nil then
            onAdded(k, m2[k])
        end
    end
    for _, k in ipairs(watchmanager.sortedKeys(m1)) do
        local v1 = m1[k]
        local v2 = m2[k]
        if v2 ~= nil then
            if not equalValues(v1, v2) then
                onChanged(k, v1, v2)
            end
        else
            onRemoved(k, v1)
        end
    end
end

function WatchManager:ReconcileWatches(desiredDirs)
    if self.backend == nil then
        return nil
    end

    local additions = {}
    local changes = {}

    -- core.DiffMapsFunc, iterating in sorted key order.
    diffMapsSorted(
        self.watchedDirs,
        desiredDirs,
        function(wd, recursive) return wd.recursive == recursive end,
        function(dir, recursive)
            if self.debugLog ~= nil then
                self.debugLog:WriteString("[watch] watching directory " .. dir .. " (recursive=" .. tostring(recursive) .. ")\n")
            end
            additions[#additions + 1] = { dir = dir, recursive = recursive }
        end,
        function(dir, wd)
            if self.debugLog ~= nil then
                self.debugLog:WriteString("[watch] closing stale dir watch: " .. dir .. "\n")
            end
            wd.closer:Close()
            self.watchedDirs[dir] = nil
        end,
        function(dir, wd, recursive)
            if self.debugLog ~= nil then
                self.debugLog:WriteString("[watch] recreating dir watch " .. dir .. " (recursive " .. tostring(wd.recursive) .. "→" .. tostring(recursive) .. ")\n")
            end
            wd.closer:Close()
            self.watchedDirs[dir] = nil
            changes[#changes + 1] = { dir = dir, recursive = recursive }
        end
    )
    for _, c in ipairs(changes) do
        additions[#additions + 1] = c
    end
    return self:createDirWatches(additions)
end

function WatchManager:createDirWatches(updates)
    if #updates == 0 then
        return nil
    end
    local requests = {}
    local entries = {}
    for i, update in ipairs(updates) do
        local entry = { closer = nil, recursive = update.recursive }
        entries[i] = entry
        requests[i] = self:createDirWatchRequest(update.dir, entry)
    end
    local closers, err = self.backend:WatchDirectories(requests)
    if err == nil then
        for i, update in ipairs(updates) do
            entries[i].closer = closers[i]
            self.watchedDirs[update.dir] = entries[i]
        end
        return nil
    end
    if self.debugLog ~= nil then
        for _, update in ipairs(updates) do
            self.debugLog:WriteString("[watch] failed to watch directory " .. update.dir .. ": " .. watchmanager.errorString(err) .. "\n")
        end
    end
    return err
end

-- DirWatchSet accumulates the set of directories that should be watched while
-- answering coverage queries efficiently. A directory is "covered" when it is
-- already present in the set, or when it is contained within a recursive watch
-- directory already in the set.
local DirWatchSet = {}
DirWatchSet.__index = DirWatchSet
watchmanager.DirWatchSet = DirWatchSet

function watchmanager.NewDirWatchSet(opts)
    return setmetatable({
        opts = opts,
        dirs = {},
    }, DirWatchSet)
end

function DirWatchSet:canonical(dir)
    return tspath.GetCanonicalFileName(dir, self.opts.useCaseSensitiveFileNames)
end

function DirWatchSet:Set(dir, recursive)
    dir = self:canonical(dir)
    self.dirs[dir] = (self.dirs[dir] == true) or recursive
end

function DirWatchSet:Covered(dir)
    dir = self:canonical(dir)
    if self.dirs[dir] ~= nil then
        return true
    end
    local rootLength = tspath.GetRootLength(dir)
    while #dir > rootLength do
        dir = tspath.GetDirectoryPath(dir)
        if self.dirs[dir] == true then
            return true
        end
    end
    return false
end

function DirWatchSet:Dirs()
    return self.dirs
end

function WatchManager:IsPathUnderWatch(path, opts)
    for dir in pairs(self.watchedDirs) do
        if tspath.ContainsPath(dir, path, opts) then
            return true
        end
    end
    return false
end

-- RunLoop runs doCycle whenever file changes were signalled, until ctx is done.
--
-- Go blocks on ctx.Done() and doCycleCh. The Lua port polls: each iteration runs fswatch.Tick
-- (poll the polling backend, advance the debouncers, which deliver events to onWatchEvents) and
-- then runs doCycle if it was signalled, sleeping between iterations (fswatch.Sleep, i.e.
-- os.execute("sleep ...")). ctx may be nil (never done) or a table with a Done() method that
-- returns true once cancelled. The loop also ends when a sleep is interrupted by a signal
-- (Ctrl-C).
function WatchManager:RunLoop(ctx, doCycle)
    local receive = self:DoCycleCh()
    while true do
        if ctx ~= nil and ctx.Done ~= nil and ctx:Done() then
            self:CloseAllWatches()
            return
        end
        fswatch.Tick()
        if receive() then
            doCycle()
        end
        local interval = fswatch.PollInterval
        for _, d in ipairs(fswatch.debounces) do
            if d.notified then
                interval = fswatch.minWaitTime
                break
            end
        end
        if not fswatch.Sleep(interval) then
            self:CloseAllWatches()
            return
        end
    end
end
