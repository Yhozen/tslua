-- Package lspwatcher implements an in-process file watcher used as a
-- drop-in replacement for LSP-based file watching when the client does not
-- support dynamic registration of file watchers.
--
-- Go delivers batches from a time.AfterFunc debounce timer; the sequential port arms a deadline
-- and delivers the batch when the watcher is polled after it (Watcher:Poll, called by the LSP
-- server while idle, or directly by callers such as tests).
local lspwatcher = require("tslua.lsp.lspwatcher")
local fswatch = require("tslua.fswatch")
local jsonrpc = require("tslua.jsonrpc")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local tspath = require("tslua.tspath")

local WatchKind = lsproto.WatchKind
local FileChangeType = lsproto.FileChangeType
local EventKind = fswatch.EventKind

-- throttleWindow mirrors VS Code's parcel watcher integration: give the
-- first batch a short grace window so adjacent filesystem bursts coalesce.
lspwatcher.throttleWindow = 0.075 -- seconds

-- The clock used for the flush deadline (seconds).
function lspwatcher.now()
    return project.now()
end

-- watcherBackend: WatchDirectory(dir, fn, ...opts) -> (io.Closer, err)

local defaultWatcherBackend = {}
defaultWatcherBackend.__index = defaultWatcherBackend
lspwatcher.defaultWatcherBackend = defaultWatcherBackend

function defaultWatcherBackend:WatchDirectory(dir, fn, ...)
    return self.watcher:WatchDirectory(dir, fn, ...)
end

-- Watcher manages a set of file system subscriptions identified by
-- WatcherID strings (matching the LSP server's project.WatcherID type).
-- Events are delivered to onChanges in batches as `*lsproto.FileEvent`,
-- shaped exactly like a `workspace/didChangeWatchedFiles` notification.
local Watcher = {}
Watcher.__index = Watcher
lspwatcher.Watcher = Watcher

-- watch represents one FileSystemWatcher from the LSP registration.
--
-- The directory the session asks to watch may not exist yet (common in
-- granular mode, where each probed-but-missing package directory becomes a
-- watch) or may be deleted while watched. To honor the watch across those
-- transitions, a watch maintains either:
--
--   - a "target" subscription rooted directly at the requested directory, once
--     it exists, or
--   - an "ancestor" subscription on the nearest existing ancestor
--     (non-recursive), used to detect the requested directory — or an
--     intermediate path component — being created, after which the watch
--     descends toward and eventually promotes to the target.
--
-- When the target materializes, synthetic create events are emitted for it
-- (and, depending on whether the watch is recursive, its immediate children or
-- its whole subtree) so the session re-resolves files that appeared in the gap
-- before the real subscription was installed.
--
-- All path fields are tspath-style (forward-slash) absolute paths.
local watch = {}
watch.__index = watch
lspwatcher.watch = watch

-- New constructs a Watcher backed by internal/fswatch's platform-default
-- watcher implementation.
function lspwatcher.New(fs, onChanges, logger)
    return lspwatcher.NewWithFSWatcher(fs, fswatch.Default(), onChanges, logger)
end

-- NewWithFSWatcher constructs a Watcher backed by the provided fswatch.Watcher.
-- Use this to select a specific backend (e.g. fswatch.Kqueue()) instead of the
-- platform default.
function lspwatcher.NewWithFSWatcher(fs, watcher, onChanges, logger)
    return lspwatcher.newWithBackend(fs, setmetatable({ watcher = watcher }, defaultWatcherBackend), onChanges, logger)
end

function lspwatcher.newWithBackend(fs, backend, onChanges, logger)
    return setmetatable({
        fs = fs,
        backend = backend,
        onChanges = onChanges,
        logger = logger,
        -- watches holds the watches associated with each LSP WatcherID. A single id
        -- may map to more than one watch because each FileSystemWatcher in the
        -- registration becomes its own watch (different roots and kinds).
        watches = {},
        closed = false,
        -- Pending batch state: uri -> FileEvent, plus the keys in insertion order.
        pending = nil,
        pendingOrder = nil,
        flushDeadline = nil,
    }, Watcher)
end

-- WatchFiles subscribes to each FileSystemWatcher under the given id.
--
-- A watcher whose directory does not exist yet is not an error: an ancestor
-- watch is installed on the nearest existing ancestor and the subscription is
-- reported as successful, so the session's notion of "this watcher is alive"
-- stays true for the subscription's whole lifetime. Only a genuine backend
-- failure (e.g. resource exhaustion while watching an existing directory)
-- causes WatchFiles to roll back the whole id and return an error, so the
-- session's pending/retry path re-registers it on the next reevaluation.
function Watcher:WatchFiles(id, fileSystemWatchers)
    if self.closed then
        return jsonrpc.NewError("lspwatcher: closed")
    end
    if self.watches[id] ~= nil then
        return jsonrpc.NewError("lspwatcher: watcher " .. jsonrpc.goQuote(id) .. " already exists")
    end
    -- Mark the id as existing before installing any watches so a concurrent
    -- WatchFiles for the same id is rejected above.
    self.watches[id] = {}

    local failed = false
    for _, fileSystemWatcher in ipairs(fileSystemWatchers or {}) do
        local directory, ok = lspwatcher.watchRoot(fileSystemWatcher)
        if not ok or directory == "" then
            self.logger:Logf("lspwatcher: skipping watcher %q: unrecognized pattern %q", id, lspwatcher.watchPatternString(fileSystemWatcher))
        else
            local newWatch = setmetatable({
                watcher = self,
                requestedDirectory = directory, -- directory requested by the LSP layer (possibly a symlink)
                kind = lspwatcher.effectiveKind(fileSystemWatcher),
                recursive = lspwatcher.isRecursiveGlob(fileSystemWatcher), -- whether the target subscription should be recursive
                subscription = nil, -- current subscription (target or ancestor); nil if none
                watchedDirectory = "", -- canonicalized directory 'subscription' is rooted at
                watchingTarget = false, -- whether 'subscription' is rooted at the target directory
                closed = false,
            }, watch)
            local err = newWatch:reconcile(false --[[emitSynthetic]])
            if err ~= nil then
                self.logger:Logf("lspwatcher: failed to register watcher %q for %q: %v", id, directory, err)
                newWatch:close()
                failed = true
                break
            end
            if self.closed then
                newWatch:close()
                return jsonrpc.NewError("lspwatcher: closed")
            end
            local list = self.watches[id]
            list[#list + 1] = newWatch
        end
    end

    if failed then
        -- Roll back the whole id so the session's retry (MarkPending) can
        -- cleanly re-register it. The session treats an id as a single unit.
        self:UnwatchFiles(id)
        return jsonrpc.NewError("lspwatcher: failed to register one or more watchers for " .. jsonrpc.goQuote(id))
    end
    return nil
end

-- UnwatchFiles tears down all subscriptions associated with id.
function Watcher:UnwatchFiles(id)
    local watches = self.watches ~= nil and self.watches[id] or nil
    if watches == nil then
        return jsonrpc.NewError("lspwatcher: no watcher with id " .. jsonrpc.goQuote(id))
    end
    self.watches[id] = nil
    for _, w in ipairs(watches) do
        w:close()
    end
    return nil
end

-- Close removes every subscription. Safe to call multiple times.
function Watcher:Close()
    if self.closed then
        return
    end
    self.closed = true
    local watchesByID = self.watches
    self.watches = nil
    self.flushDeadline = nil
    self.pending = nil
    self.pendingOrder = nil
    local ids = {}
    for id in pairs(watchesByID) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        for _, w in ipairs(watchesByID[id]) do
            w:close()
        end
    end
end

-- close tears down the watch's current subscription and prevents any in-flight
-- reconcile from reinstalling one.
function watch:close()
    self.closed = true
    local subscription = self.subscription
    self.subscription = nil
    self.watchedDirectory = ""
    if subscription ~= nil then
        subscription:Close()
    end
end

-- reconcile installs or advances this watch toward the target directory based
-- on the current filesystem state. It is called at registration, whenever a
-- ancestor watch observes activity, and after a target watch is terminated by
-- deletion.
--
-- emitSynthetic controls whether promoting to the target emits synthetic
-- create events: false for the initial install when the target already exists
-- (the session already knows about those files), true for any missing→present
-- recovery.
--
-- It returns a non-nil error only on a genuine backend failure to install a
-- watch; a missing target directory is handled by installing an ancestor watch
-- and returns nil.
function watch:reconcile(emitSyntheticCreates)
    local watcher = self.watcher
    while true do
        if self.closed then
            return nil
        end
        if watcher.fs:DirectoryExists(self.requestedDirectory) then
            if self.watchingTarget and self.subscription ~= nil then
                return nil -- already watching the target
            end
            local targetDirectory = self.requestedDirectory
            local options = {}
            if self.recursive then
                options[#options + 1] = fswatch.WithRecursive()
            end
            local subscription, err = watcher.backend:WatchDirectory(targetDirectory, self:targetCallback(targetDirectory), table.unpack(options))
            if err ~= nil then
                return err
            end
            local previous = self.subscription
            self.subscription = subscription
            self.watchedDirectory = targetDirectory
            self.watchingTarget = true
            if previous ~= nil then
                previous:Close()
            end
            if emitSyntheticCreates then
                watcher:emitSyntheticCreates(targetDirectory, self.kind, self.recursive)
            end
            return nil
        end

        local ancestor, ok = lspwatcher.nearestExistingAncestor(watcher.fs, self.requestedDirectory)
        if not ok then
            -- Nothing exists to watch (even the root is gone); drop any subscription.
            if self.subscription ~= nil then
                local previous = self.subscription
                self.subscription = nil
                self.watchedDirectory = ""
                self.watchingTarget = false
                previous:Close()
            end
            return nil
        end
        local ancestorDirectory = ancestor
        if not self.watchingTarget and self.subscription ~= nil and self.watchedDirectory == ancestorDirectory then
            return nil -- already watching the correct ancestor
        end
        local subscription, err = watcher.backend:WatchDirectory(ancestorDirectory, self:ancestorCallback())
        if err ~= nil then
            return err
        end
        local previous = self.subscription
        self.subscription = subscription
        self.watchedDirectory = ancestorDirectory
        self.watchingTarget = false
        if previous ~= nil then
            previous:Close()
        end
        -- The target may have appeared between the DirectoryExists check above
        -- and installing this ancestor subscription (e.g. an atomic tree
        -- creation), so loop to descend further or promote immediately. Any
        -- promotion from here on is a missing→present transition, so synthesize
        -- creates.
        emitSyntheticCreates = true
    end
end

-- targetCallback returns the fswatch callback for a target watch rooted at
-- watchedReal. It forwards events to the session and, on ErrWatchTerminated
-- (the watched directory was deleted), falls back to watching the nearest
-- existing ancestor so the watch re-attaches when the directory is recreated.
function watch:targetCallback(watchedDirectory)
    local watcher = self.watcher
    return function(events, err)
        local terminated = false
        if err ~= nil then
            if jsonrpc.ErrorsIs(err, fswatch.ErrOverflow) then
                watcher.logger:Logf("lspwatcher: watch overflow in %q (some events may have been dropped): %v", watchedDirectory, err)
            elseif jsonrpc.ErrorsIs(err, fswatch.ErrWatchTerminated) then
                terminated = true
                watcher.logger:Logf("lspwatcher: watch terminated in %q (directory removed): %v", watchedDirectory, err)
            else
                watcher.logger:Logf("lspwatcher: watch error in %q: %v", watchedDirectory, err)
            end
        end
        if events ~= nil and #events > 0 then
            watcher:forwardEvents(self.kind, events)
        end
        if terminated then
            -- The delete event for the directory was forwarded above; now
            -- re-attach to the nearest existing ancestor.
            self:handleTerminated()
        end
    end
end

-- handleTerminated clears the dead target watch (the backend has already
-- removed it) and re-evaluates, falling back to an ancestor watch on the nearest
-- existing ancestor so the watch re-attaches when the directory reappears.
-- Clearing the state first is essential: reconcile would otherwise see
-- watchingTarget && subscription != nil and conclude the target is already
-- watched, even though the subscription is dead — losing recovery if the
-- directory is recreated before reconcile runs.
function watch:handleTerminated()
    if self.closed then
        return
    end
    local previous = self.subscription
    self.subscription = nil
    self.watchedDirectory = ""
    self.watchingTarget = false
    if previous ~= nil then
        previous:Close()
    end
    self:reconcile(true --[[emitSyntheticCreates]])
end

-- ancestorCallback returns the fswatch callback for an ancestor watch. Ancestor
-- watches exist only to detect the target — or an intermediate path component —
-- being created; their events are about ancestor directories the session
-- doesn't track, so they are ignored and the watch is simply re-evaluated.
function watch:ancestorCallback()
    return function(events, err)
        self:reconcile(true --[[emitSyntheticCreates]])
    end
end

-- nearestExistingAncestor returns the deepest existing directory that is dir or
-- an ancestor of dir, walking upward. ok is false only if nothing in the chain
-- (including the root) exists. Returns (dir, ok).
function lspwatcher.nearestExistingAncestor(fs, dir)
    while true do
        if fs:DirectoryExists(dir) then
            return dir, true
        end
        local parent = tspath.GetDirectoryPath(dir)
        if parent == dir then
            return "", false
        end
        dir = parent
    end
end

-- Adds a pending event for uri (Go: w.pending[uri] = event); map order is not observable in Go,
-- the Lua batch keeps first-insertion order.
function Watcher:setPending(uri, event)
    if self.pending[uri] == nil then
        self.pendingOrder[#self.pendingOrder + 1] = uri
    end
    self.pending[uri] = event
end

-- forwardEvents translates fswatch events into LSP file events and enqueues
-- them for the next debounced flush.
function Watcher:forwardEvents(kind, events)
    if self.closed then
        return
    end
    if self.pending == nil then
        self.pending = {}
        self.pendingOrder = {}
    end
    for _, event in ipairs(events) do
        local changeType
        if event.kind == EventKind.EventUpdate then
            -- fswatch intentionally doesn't distinguish create vs update.
            -- For LSP consumers this is fine: callers infer create/update
            -- from their own cache and both should invalidate stale state.
            if kind & (WatchKind.Create | WatchKind.Change) ~= 0 then
                changeType = FileChangeType.Changed
            end
        elseif event.kind == EventKind.EventDelete then
            if kind & WatchKind.Delete ~= 0 then
                changeType = FileChangeType.Deleted
            end
        end

        if changeType ~= nil then
            local path = tspath.NormalizeSlashes(event.path)
            local uri = lsconv.FileNameToDocumentURI(path)
            self:setPending(uri, lsproto.FileEvent({
                uri = uri,
                type = changeType,
            }))
        end
    end
    self:scheduleFlushLocked()
end

-- emitSyntheticCreates enqueues synthetic create events after a target watch is
-- (re)installed following a missing→present transition, so the session
-- re-resolves files that appeared before the real watch existed. The target
-- directory itself is always included; for a non-recursive watch its immediate
-- children are added, and for a recursive watch its whole subtree is walked.
-- Nothing is emitted if the watch doesn't request create notifications.
function Watcher:emitSyntheticCreates(directory, kind, recursive)
    if kind & WatchKind.Create == 0 then
        return
    end
    local paths = { directory }
    if recursive then
        self.fs:WalkDir(directory, function(path, entry, err)
            if err ~= nil then
                return nil
            end
            local normalizedPath = tspath.NormalizeSlashes(path)
            if normalizedPath == directory then
                return nil
            end
            paths[#paths + 1] = normalizedPath
            return nil
        end)
    else
        local entries = self.fs:GetAccessibleEntries(directory)
        for _, name in ipairs(entries.files or {}) do
            paths[#paths + 1] = tspath.CombinePaths(directory, name)
        end
        for _, name in ipairs(entries.directories or {}) do
            paths[#paths + 1] = tspath.CombinePaths(directory, name)
        end
    end
    self:enqueueSyntheticCreates(paths)
end

-- enqueueSyntheticCreates adds synthetic create events for paths, without
-- clobbering a more specific event already pending for the same path (e.g. a
-- real delete).
function Watcher:enqueueSyntheticCreates(paths)
    if self.closed then
        return
    end
    if self.pending == nil then
        self.pending = {}
        self.pendingOrder = {}
    end
    for _, path in ipairs(paths) do
        local uri = lsconv.FileNameToDocumentURI(path)
        if self.pending[uri] == nil then
            self:setPending(uri, lsproto.FileEvent({
                uri = uri,
                type = FileChangeType.Created,
            }))
        end
    end
    self:scheduleFlushLocked()
end

-- scheduleFlushLocked arms the debounce flush timer if it isn't already armed.
function Watcher:scheduleFlushLocked()
    if self.flushDeadline == nil then
        self.flushDeadline = lspwatcher.now() + lspwatcher.throttleWindow
    end
end

-- Poll runs the flush timer if it has expired (Lua-only; Go's time.AfterFunc fires on its own).
-- With force, the batch is flushed without waiting for the throttle window.
function Watcher:Poll(force)
    if self.flushDeadline ~= nil and (force or lspwatcher.now() >= self.flushDeadline) then
        self:flush()
    end
end

function Watcher:flush()
    if self.closed then
        return
    end
    local pending = self.pending
    local order = self.pendingOrder
    self.pending = nil
    self.pendingOrder = nil
    self.flushDeadline = nil

    if pending == nil or #order == 0 then
        return
    end
    local changes = {}
    for _, uri in ipairs(order) do
        changes[#changes + 1] = pending[uri]
    end
    self.onChanges(changes)
end

-- watchRoot extracts the directory the fswatch subscription should be
-- rooted at from a FileSystemWatcher. The patterns the project layer
-- produces are of the form `<dir>/**/*` (recursive) or `<dir>/*`
-- (non-recursive, used by granular watch mode), either as a Pattern
-- with a fully-qualified directory or as a RelativePattern with a
-- file:// BaseUri, so the heuristic of "everything before the first
-- glob meta character" is reliable. Use isRecursiveGlob to determine
-- whether the subscription should be recursive.
--
-- Returned roots are tspath-normalized (forward-slash) absolute paths.
-- Returns (root, ok).
function lspwatcher.watchRoot(fileSystemWatcher)
    if fileSystemWatcher.globPattern.pattern ~= nil then
        return lspwatcher.rootFromGlob(fileSystemWatcher.globPattern.pattern), true
    end
    local relativePattern = fileSystemWatcher.globPattern.relativePattern
    if relativePattern ~= nil then
        local base
        if relativePattern.baseUri.uri ~= nil then
            base = lsproto.DocumentUri_FileName(relativePattern.baseUri.uri)
        else
            return "", false
        end
        local pattern = tspath.CombinePaths(base, relativePattern.pattern)
        return lspwatcher.rootFromGlob(pattern), true
    end
    return "", false
end

local function trimRightSlashes(s)
    return (string.gsub(s, "/+$", ""))
end

function lspwatcher.rootFromGlob(pattern)
    pattern = tspath.NormalizeSlashes(pattern)
    local metaIndex = -1
    for i = 0, #pattern - 1 do
        local c = string.sub(pattern, i + 1, i + 1)
        if c == "*" or c == "?" or c == "[" or c == "{" then
            metaIndex = i
        end
        if metaIndex ~= -1 then
            break
        end
    end
    if metaIndex == -1 then
        return tspath.NormalizePath(trimRightSlashes(pattern))
    end
    local directory = trimRightSlashes(string.sub(pattern, 1, metaIndex))
    if directory == "" then
        return ""
    end
    return tspath.NormalizePath(directory)
end

function lspwatcher.watchPatternString(fileSystemWatcher)
    if fileSystemWatcher.globPattern.pattern ~= nil then
        return fileSystemWatcher.globPattern.pattern
    end
    local relativePattern = fileSystemWatcher.globPattern.relativePattern
    if relativePattern ~= nil then
        local base = ""
        if relativePattern.baseUri.uri ~= nil then
            base = relativePattern.baseUri.uri
        end
        return base .. "/" .. relativePattern.pattern
    end
    return ""
end

-- isRecursiveGlob reports whether a FileSystemWatcher's pattern requests
-- recursive watching (contains a `**` segment). Granular watch mode emits
-- non-recursive `<dir>/*` patterns, which watch only the immediate directory.
function lspwatcher.isRecursiveGlob(fileSystemWatcher)
    return string.find(lspwatcher.watchPatternString(fileSystemWatcher), "**", 1, true) ~= nil
end

function lspwatcher.effectiveKind(fileSystemWatcher)
    if fileSystemWatcher.kind ~= nil then
        return fileSystemWatcher.kind
    end
    return WatchKind.Create | WatchKind.Change | WatchKind.Delete
end
