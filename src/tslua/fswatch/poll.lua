local fswatch = require("tslua.fswatch")
local osvfs = require("tslua.vfs.osvfs")

-- Lua-only: the stat-polling backend (no Go counterpart file).
--
-- Go's fswatch has only native backends (inotify, fanotify, FSEvents, kqueue,
-- ReadDirectoryChangesW); none of them can be implemented without syscalls. This backend
-- implements the same watcherImpl contract by periodically listing every subscribed directory with
-- find(1) (type, modification time, size of each entry) and diffing consecutive snapshots:
--   - an entry that appears          → events.create (→ EventUpdate)
--   - a file whose mtime/size changed → events.update (directory mtime changes are not reported,
--                                       like inotify, which only reports IN_MODIFY for files)
--   - an entry that disappears        → events.remove
--   - the watch root disappears       → events.remove(root) + ErrWatchTerminated
-- Non-recursive watches list the direct children only; recursive watches list the whole tree.
-- After each poll, touched dirWatches are notified, which triggers the debouncer, exactly as the
-- native backends do after reading a batch of kernel events.
--
-- Polling happens in fswatch.Tick (called by the run loop of watchmanager, see RunLoop).

fswatch.PollInterval = 0.25

local pollBackend = setmetatable({}, { __index = fswatch.watcherBase })
pollBackend.__index = pollBackend
fswatch.pollBackend = pollBackend

-- Active polling backends, polled by fswatch.Tick.
fswatch.pollBackends = {}

function fswatch.newPollBackend()
    local b = setmetatable({
        -- snapshots: dirWatch -> map path -> { isDir, mtime, size } (display paths)
        snapshots = {},
    }, pollBackend)
    b:init(b)
    return b
end

fswatch.pollWatcher.factory = function()
    return fswatch.newPollBackend()
end

function pollBackend:start()
    fswatch.pollBackends[#fswatch.pollBackends + 1] = self
    self:notifyStarted()
    return nil
end

function pollBackend:shutdown()
    for i, b in ipairs(fswatch.pollBackends) do
        if b == self then
            table.remove(fswatch.pollBackends, i)
            return
        end
    end
end

-- scan lists dir (and, when recursive, its whole subtree). Returns (entries, rootExists) where
-- entries maps each physical path below dir to { isDir, mtime, size }.
function fswatch.pollScan(dir, recursive)
    local cmd = "find -H " .. osvfs.shellQuote(dir)
    if not recursive then
        cmd = cmd .. " -maxdepth 1"
    end
    cmd = cmd .. " -printf '%d\\t%y\\t%T@\\t%s\\t%p\\n' 2>/dev/null"
    local p = io.popen(cmd)
    if p == nil then
        return {}, false
    end
    local entries = {}
    local rootExists = false
    for line in p:lines() do
        local depth, t, mtime, size, path = string.match(line, "^(%d+)\t(%a)\t([^\t]*)\t(%d+)\t(.*)$")
        if depth ~= nil then
            if depth == "0" then
                rootExists = t == "d"
            else
                entries[path] = { isDir = t == "d", mtime = mtime, size = size }
            end
        end
    end
    p:close()
    return entries, rootExists
end

function pollBackend:snapshot(w)
    local entries, rootExists = fswatch.pollScan(w.physicalDir, w.recursive)
    local snap = {}
    for physicalPath, info in pairs(entries) do
        snap[w:displayPath(physicalPath)] = info
    end
    return snap, rootExists
end

function pollBackend:subscribe(w)
    local snap, rootExists = self:snapshot(w)
    if not rootExists then
        return fswatch.newDirWatchError(fswatch.wrapError(fswatch.ENOTDIR, "watching '" .. w.dir .. "' failed"), w)
    end
    self.snapshots[w] = snap
    return nil
end

function pollBackend:closeWatch(w)
    self.snapshots[w] = nil
    return nil
end

local function sortedKeys(m)
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- poll rescans every subscription and records the differences as events.
function pollBackend:poll()
    local touched = {}
    local terminated = {}
    for _, w in ipairs(self.subscriptionList) do
        local old = self.snapshots[w]
        if old ~= nil then
            local snap, rootExists = self:snapshot(w)
            local changed = false
            if not rootExists then
                for _, path in ipairs(sortedKeys(old)) do
                    w.events:remove(path)
                end
                w.events:remove(w.dir)
                w.events:setError(fswatch.wrapError(fswatch.ErrWatchTerminated, "watched directory removed"))
                self.snapshots[w] = nil
                terminated[#terminated + 1] = w
                changed = true
            else
                for _, path in ipairs(sortedKeys(snap)) do
                    local info = snap[path]
                    local prev = old[path]
                    if prev == nil or prev.isDir ~= info.isDir then
                        if prev ~= nil then
                            w.events:remove(path)
                        end
                        w.events:create(path)
                        changed = true
                    elseif not info.isDir and (prev.mtime ~= info.mtime or prev.size ~= info.size) then
                        w.events:update(path)
                        changed = true
                    end
                end
                for _, path in ipairs(sortedKeys(old)) do
                    if snap[path] == nil then
                        w.events:remove(path)
                        changed = true
                    end
                end
                self.snapshots[w] = snap
            end
            if changed then
                touched[#touched + 1] = w
            end
        end
    end
    for _, w in ipairs(terminated) do
        self:deleteSubscription(w)
    end
    for _, w in ipairs(touched) do
        w:notify()
    end
end

-- Tick polls every polling backend once and advances every debouncer; callbacks whose
-- debounce window elapsed are invoked.
function fswatch.Tick()
    for _, b in ipairs(fswatch.pollBackends) do
        b:poll()
    end
    local now = fswatch.now()
    for _, d in ipairs(fswatch.debounces) do
        d:tick(now)
    end
end
