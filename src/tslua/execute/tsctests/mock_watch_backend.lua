local tsctests = require("tslua.execute.tsctests")
local tspath = require("tslua.tspath")

-- fswatch.Event: { kind = fswatch.EventKind, path = "" }. The fswatch package is required lazily (it is
-- only needed once a watcher runs).
local function fswatch()
    return require("tslua.fswatch")
end

-- MockWatchBackend implements watchmanager.WatchBackend for testing. It
-- records all WatchDirectory calls so tests can verify that
-- the correct watches are registered.  Events can be delivered through
-- SendEvents, which routes them only through watches whose paths
-- match, enforcing that tests fail if the wrong watches are set up.
--
-- Fields: dirs (map dir -> MockWatch), directoryExists (func(string) bool or nil; if set,
-- WatchDirectory fails for non-existent dirs), useCaseSensitiveFileNames.
local MockWatchBackend = {}
MockWatchBackend.__index = MockWatchBackend
tsctests.MockWatchBackend = MockWatchBackend

-- NewMockWatchBackend creates a ready-to-use mock backend.
function tsctests.NewMockWatchBackend()
    return setmetatable({
        dirs = {},
        directoryExists = nil,
        useCaseSensitiveFileNames = false,
    }, MockWatchBackend)
end

-- HasWatches reports whether any watches have been registered.
function MockWatchBackend:HasWatches()
    return next(self.dirs) ~= nil
end

-- MockWatch records a single registered watch.
-- { path = "", callback = fswatch.WatchCallback, recursive = false, ignore = func(string) bool or nil, closed = false }
local MockWatch = {}
MockWatch.__index = MockWatch
tsctests.MockWatch = MockWatch

function MockWatch:Close()
    self.closed = true
    return nil
end

-- Returns (io.Closer, err).
function MockWatchBackend:WatchDirectory(dir, fn, recursive, ignore)
    local closers, err = self:WatchDirectories({ {
        dir = dir,
        callback = fn,
        recursive = recursive,
        ignore = ignore,
    } })
    if err ~= nil then
        return nil, err
    end
    return closers[1], nil
end

-- requests: []watchmanager.WatchDirectoryRequest { dir, callback, recursive, ignore }.
-- Returns ([]io.Closer, err).
function MockWatchBackend:WatchDirectories(requests)
    for _, request in ipairs(requests) do
        if self.directoryExists ~= nil and not self.directoryExists(request.dir) then
            return nil, "directory does not exist: " .. request.dir
        end
    end
    local closers = {}
    for i, request in ipairs(requests) do
        local w = setmetatable({ path = request.dir, callback = request.callback, recursive = request.recursive or false, ignore = request.ignore, closed = false }, MockWatch)
        self.dirs[request.dir] = w
        closers[i] = w
    end
    return closers, nil
end

local function sortedDirs(dirs)
    local keys = {}
    for k in pairs(dirs) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- SendEvents routes events through the registered watch callbacks
-- that match each event's path. Directory watches match if the event
-- path is a child (or recursive descendant) of the watched directory.
-- Events that match no watch are silently dropped — this is by design
-- so that tests fail when the production code doesn't register the
-- needed watches.
function MockWatchBackend:SendEvents(events)
    -- Go iterates maps (random order); iterate watches sorted by path for determinism.
    local targets = {}
    local targetOrder = {}
    local dirKeys = sortedDirs(self.dirs)

    for _, e in ipairs(events) do
        -- Check directory watches.
        for _, dir in ipairs(dirKeys) do
            local w = self.dirs[dir]
            if w.closed then
                goto continue
            end
            if w.ignore ~= nil and w.ignore(e.path) then
                goto continue
            end
            if not tsctests.pathIsUnder(e.path, w.path, w.recursive, self.useCaseSensitiveFileNames) then
                goto continue
            end
            do
                local t = targets[w]
                if t ~= nil then
                    t.events[#t.events + 1] = e
                else
                    targets[w] = { cb = w.callback, events = { e } }
                    targetOrder[#targetOrder + 1] = w
                end
            end
            ::continue::
        end
    end

    for _, w in ipairs(targetOrder) do
        local t = targets[w]
        t.cb(t.events, nil)
    end
end

-- SendOverflow simulates a kernel event-queue overflow by invoking every
-- active watch callback with fswatch.ErrOverflow. The watch manager treats
-- this as a signal that events were dropped and a full rebuild is required.
function MockWatchBackend:SendOverflow()
    local cbs = {}
    for _, dir in ipairs(sortedDirs(self.dirs)) do
        local w = self.dirs[dir]
        if not w.closed then
            cbs[#cbs + 1] = w.callback
        end
    end
    for _, cb in ipairs(cbs) do
        cb(nil, fswatch().ErrOverflow)
    end
end

-- Go path.Dir
local function pathDir(p)
    local dir = string.match(p, "^(.*)/[^/]*$")
    if dir == nil then
        return "."
    end
    if dir == "" then
        return "/"
    end
    -- path.Dir cleans the result; inputs here are clean absolute paths
    return dir
end

-- SendChangedPaths converts a list of file changes into fswatch
-- events with appropriate event kinds and routes them through
-- registered watches via SendEvents. For new/modified files, it also
-- emits update events for their parent directories, simulating how
-- real filesystem watchers report directory events.
function MockWatchBackend:SendChangedPaths(changes)
    local events = {}
    local seenDirs = {}
    for _, c in ipairs(changes or {}) do
        local kind = fswatch().EventKind.Update
        if c.deleted then
            kind = fswatch().EventKind.Delete
        end
        events[#events + 1] = { kind = kind, path = c.path }
        -- Emit update events for parent directories of changed files.
        -- Real filesystem watchers deliver events to non-recursive watches
        -- when a child directory is created, which the mock must replicate.
        local dir = pathDir(c.path)
        while dir ~= "" and dir ~= "/" and dir ~= "." do
            if seenDirs[dir] then
                break
            end
            seenDirs[dir] = true
            events[#events + 1] = { kind = fswatch().EventKind.Update, path = dir }
            local parent = pathDir(dir)
            if parent == dir then
                break
            end
            dir = parent
        end
    end
    self:SendEvents(events)
end

-- pathIsUnder reports whether eventPath is inside dir. If recursive is
-- false, only direct children match.
function tsctests.pathIsUnder(eventPath, dir, recursive, useCaseSensitiveFileNames)
    if not useCaseSensitiveFileNames then
        eventPath = tspath.GetCanonicalFileName(eventPath, false)
        dir = tspath.GetCanonicalFileName(dir, false)
    end
    if string.sub(eventPath, 1, #dir) ~= dir then
        return false
    end
    local rest = string.sub(eventPath, #dir + 1)
    if #rest == 0 then
        return false -- exact match = the dir itself, not a child
    end
    if string.sub(rest, 1, 1) ~= "/" then
        return false -- e.g. dir="/foo", path="/foobar"
    end
    if not recursive then
        -- Direct child only: no further '/' after the separator.
        return not string.find(rest, "/", 2, true)
    end
    return true
end

-- WatchState returns a deterministic, human-readable summary of all
-- active watches. This is intended to be included in test baselines
-- so that watch registration correctness is verified via snapshot diffs.
function MockWatchBackend:WatchState()
    local b = {}
    b[#b + 1] = "Watch Registrations::\n"

    -- Directory watches, sorted by path.
    local dirs = {}
    for _, dir in ipairs(sortedDirs(self.dirs)) do
        if not self.dirs[dir].closed then
            dirs[#dirs + 1] = dir
        end
    end

    b[#b + 1] = "Directory watches::\n"
    if #dirs == 0 then
        b[#b + 1] = "  (none)\n"
    end
    for _, d in ipairs(dirs) do
        local w = self.dirs[d]
        if w.recursive then
            b[#b + 1] = "  " .. d .. " (recursive)\n"
        else
            b[#b + 1] = "  " .. d .. "\n"
        end
    end

    return table.concat(b)
end
