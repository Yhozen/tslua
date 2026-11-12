local fswatch = require("tslua.fswatch")
local osvfs = require("tslua.vfs.osvfs")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- Errors are vfs.iofs error objects (Error() method, `unwrap` chain); use fswatch.errorsIs
-- (errors.Is) to distinguish them.
fswatch.errorsIs = iofs.Is

fswatch.errNilCallback = iofs.NewError("fswatch: callback must not be nil")

-- errRootPath is returned by WatchFile when the supplied path is a
-- filesystem root with no parent directory to watch.
fswatch.errRootPath = iofs.NewError("fswatch: cannot watch a root path")

-- errNotAbsolute is returned by [Watcher.WatchDirectory] and
-- [Watcher.WatchFile] when the supplied path is not absolute.
fswatch.errNotAbsolute = iofs.NewError("fswatch: path must be absolute")

-- ErrOverflow indicates that the kernel event queue overflowed and
-- some filesystem changes were missed. The watch remains
-- active; further events will continue to be delivered. Callers
-- should treat this as a signal to rescan the watched directory.
fswatch.ErrOverflow = iofs.NewError("fswatch: event overflow; some changes were missed")

-- ErrWatchTerminated indicates that the watch was terminated due to
-- an unrecoverable error (e.g. the watched directory was deleted or
-- the watch descriptor was revoked). No further events will be
-- delivered. Call Close to release remaining state.
fswatch.ErrWatchTerminated = iofs.NewError("fswatch: watch terminated")

-- ErrUnavailable indicates that a requested watcher is not
-- available on the current platform.
fswatch.ErrUnavailable = iofs.NewError("fswatch: watcher not available on this platform")

-- ErrFilesystemUnsupported indicates that the active watcher backend cannot
-- operate on the target filesystem, even though the backend is available on
-- the current platform.
fswatch.ErrFilesystemUnsupported = iofs.NewError("fswatch: watcher backend unsupported on this filesystem")

-- fmt.Errorf("%w: %w", a, b) / fmt.Errorf("%w: msg", a): the result unwraps to `wrapped`.
function fswatch.wrapError(wrapped, message)
    return iofs.NewError(wrapped:Error() .. ": " .. message, wrapped)
end

-- Watcher represents a filesystem watching implementation (a Go interface):
--   Name() -> string, Available() -> bool, HasFastRecursiveBackend() -> bool,
--   WatchDirectory(dir, fn, ...opts) -> Watch, err,
--   WatchDirectories(requests) -> []Watch, err,
--   WatchFile(path, fn) -> Watch, err.
--
-- WatchOption configures a watch: an object with applyWatchOption(opts).
--
-- WatchDirectoryRequest: { dir = string, callback = WatchCallback, options = []WatchOption }.
--
-- Watch represents a live watch: Close() -> err. Close is idempotent.
--
-- WatchCallback: function(events []Event, err) receiving batched filesystem events. Rapid
-- changes are coalesced before delivery.

function fswatch.NewWatchDirectoryRequest(dir, callback, options)
    return { dir = dir, callback = callback, options = options }
end

local function newWatchOptions()
    return { ignore = nil, recursive = false }
end

local ignoreOption = {}
ignoreOption.__index = ignoreOption

function ignoreOption:applyWatchOption(opts)
    opts.ignore = self.fn
end

-- WithIgnore returns a [WatchOption] that filters events before delivery.
-- If the function returns true for a path, events for that path are
-- silently dropped. The filtering is per-subscriber; multiple watches
-- on the same directory may have different ignore functions.
function fswatch.WithIgnore(fn)
    return setmetatable({ fn = fn }, ignoreOption)
end

local recursiveOption = {}
recursiveOption.__index = recursiveOption

function recursiveOption:applyWatchOption(opts)
    opts.recursive = true
end

-- WithRecursive returns a [WatchOption] that enables recursive watching
-- of the entire directory tree. Without this option,
-- [Watcher.WatchDirectory] watches only direct children of dir.
function fswatch.WithRecursive()
    return setmetatable({}, recursiveOption)
end

-- watcher is the concrete implementation of [Watcher]. Each platform
-- watcher is a package-level *watcher whose factory is set by the
-- platform's init() function.
local watcher = {}
watcher.__index = watcher
fswatch.watcher = watcher

local function newWatcher(name)
    return setmetatable({
        name = name,
        impl = nil,
        factory = nil, -- nil if not available on this platform
        dirWatches = nil,
        debounce = nil, -- lazily created in getOrCreateDirWatch
        sequence = nil,
    }, watcher)
end

-- fallbackWatcher keeps the primary backend for supported filesystems while
-- routing individual unsupported watches to the secondary backend.
local fallbackWatcher = {}
fallbackWatcher.__index = fallbackWatcher
fswatch.fallbackWatcher = fallbackWatcher

-- Package-level watcher instances. Platform init() functions set the factory.
-- The native backends (inotify, fanotify, FSEvents, kqueue, ReadDirectoryChangesW) need syscalls
-- that pure Lua does not have, so none of them gets a factory: they all report Available() ==
-- false. The Lua-only "poll" watcher (poll.lua) is the only available backend.
fswatch.inotifyWatcher = newWatcher("inotify")
fswatch.fseventsWatcher = newWatcher("fsevents")
fswatch.kqueueWatcher = newWatcher("kqueue")
fswatch.windowsWatcher = newWatcher("windows")
fswatch.fanotifyWatcher = newWatcher("fanotify")
fswatch.fanotifyFallbackWatcher = setmetatable({
    primary = fswatch.fanotifyWatcher,
    secondary = fswatch.inotifyWatcher,
}, fallbackWatcher)
fswatch.pollWatcher = newWatcher("poll")

-- AllWatchers returns a fresh slice listing every watcher backend the package
-- knows about. Use [Watcher.Available] to check which ones work on the current
-- OS.
function fswatch.AllWatchers()
    return {
        fswatch.inotifyWatcher,
        fswatch.fseventsWatcher,
        fswatch.kqueueWatcher,
        fswatch.windowsWatcher,
        fswatch.fanotifyFallbackWatcher,
        fswatch.pollWatcher,
    }
end

-- Inotify returns the inotify watcher (Linux and Android).
function fswatch.Inotify() return fswatch.inotifyWatcher end

-- FSEvents returns the FSEvents watcher (macOS).
function fswatch.FSEvents() return fswatch.fseventsWatcher end

-- Kqueue returns the kqueue watcher (macOS, FreeBSD, and other BSDs).
function fswatch.Kqueue() return fswatch.kqueueWatcher end

-- Windows returns the ReadDirectoryChangesW watcher (Windows).
function fswatch.Windows() return fswatch.windowsWatcher end

-- Fanotify returns the fanotify watcher (Linux, kernel ≥ 5.13). Directories on
-- filesystems that don't support fanotify watches automatically use inotify instead.
function fswatch.Fanotify() return fswatch.fanotifyFallbackWatcher end

-- Poll returns the stat-polling watcher (Lua-only, see poll.lua).
function fswatch.Poll() return fswatch.pollWatcher end

-- Default returns the recommended watcher for the current OS. Go picks the native backend for
-- runtime.GOOS; in the Lua port no native backend is available, so this returns the polling
-- watcher whenever the native default is unavailable (always, in practice).
function fswatch.Default()
    local native
    if package.config:sub(1, 1) == "\\" then
        native = fswatch.Windows()
    elseif fswatch.Fanotify():Available() then
        native = fswatch.Fanotify()
    else
        native = fswatch.Inotify()
    end
    if native:Available() then
        return native
    end
    return fswatch.Poll()
end

function fallbackWatcher:Name() return self.primary:Name() end
function fallbackWatcher:Available() return self.primary:Available() end
function fallbackWatcher:HasFastRecursiveBackend() return self.primary:HasFastRecursiveBackend() end

function fallbackWatcher:WatchDirectory(dir, fn, ...)
    local watches, err = self:WatchDirectories({ fswatch.NewWatchDirectoryRequest(dir, fn, { ... }) })
    if err ~= nil then
        return nil, err
    end
    return watches[1], nil
end

function fallbackWatcher:WatchDirectories(requests)
    local watches, err = self.primary:WatchDirectories(requests)
    if err == nil or not fswatch.errorsIs(err, fswatch.ErrFilesystemUnsupported) then
        return watches, err
    end

    watches = {}
    local function rollback()
        for i = #watches, 1, -1 do
            watches[i]:Close()
        end
    end
    for _, request in ipairs(requests) do
        local watch, werr = self.primary:WatchDirectory(request.dir, request.callback, table.unpack(request.options or {}))
        if fswatch.errorsIs(werr, fswatch.ErrFilesystemUnsupported) then
            watch, werr = self.secondary:WatchDirectory(request.dir, request.callback, table.unpack(request.options or {}))
        end
        if werr ~= nil then
            rollback()
            return nil, iofs.NewError("fswatch: failed to watch directory \"" .. request.dir .. "\": " .. werr:Error(), werr)
        end
        watches[#watches + 1] = watch
    end
    return watches, nil
end

function fallbackWatcher:WatchFile(path, fn)
    local watch, err = self.primary:WatchFile(path, fn)
    if fswatch.errorsIs(err, fswatch.ErrFilesystemUnsupported) then
        return self.secondary:WatchFile(path, fn)
    end
    return watch, err
end

fswatch.recursiveConsolidateThreshold = 10

function watcher:Name() return self.name end
function watcher:String() return self.name end
function watcher:Available() return self.factory ~= nil end

-- HasFastRecursiveBackend implements [Watcher.HasFastRecursiveBackend].
function watcher:HasFastRecursiveBackend()
    if self.name == "windows" or self.name == "fsevents" then
        return true
    end
    return false
end

function watcher:canShareRecursiveDirWatches()
    -- TODO: Re-enable this for Windows once coalesced recursive watches have
    -- more real-world bake time.
    return self.name == "fsevents"
end

function watcher:getImpl()
    if self.impl ~= nil then
        return self.impl, nil
    end
    local factory = self.factory

    if factory == nil then
        return nil, fswatch.ErrUnavailable
    end

    local impl = factory()
    local err = impl:run()
    if err ~= nil then
        return nil, err
    end

    self.impl = impl
    return impl, nil
end

function watcher:keyForDirWatch(dir, recursive)
    if recursive then
        return dir .. "\0recursive"
    end
    return dir
end

-- filepath.Dir / filepath.Clean / filepath.IsAbs for the POSIX separator.
function fswatch.filepathClean(p)
    if p == "" then
        return "."
    end
    local rooted = string.sub(p, 1, 1) == "/"
    local parts = {}
    for part in string.gmatch(p, "[^/]+") do
        if part == "." then
            -- skip
        elseif part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif not rooted then
                parts[#parts + 1] = ".."
            end
        else
            parts[#parts + 1] = part
        end
    end
    local out = table.concat(parts, "/")
    if rooted then
        return "/" .. out
    end
    if out == "" then
        return "."
    end
    return out
end

function fswatch.filepathDir(p)
    local i = #p
    while i > 0 and string.byte(p, i) ~= 47 do
        i = i - 1
    end
    return fswatch.filepathClean(string.sub(p, 1, i))
end

function fswatch.filepathIsAbs(p)
    return string.sub(p, 1, 1) == "/"
end

-- canonicalize_other.go: canonicalizePath is a no-op on platforms whose watchers report paths
-- using the same bytes the caller provided.
function fswatch.canonicalizePath(p)
    return p
end

function watcher:findCoveringRecursiveWatchLocked(dir, physicalDir)
    local best = nil
    for _, key in ipairs(self:dirWatchKeys()) do
        local dw = self.dirWatches[key]
        if dw.recursive and fswatch.isInDirectoryOrSelf(dw.dir, dir) and fswatch.isInDirectoryOrSelf(dw.physicalDir, physicalDir) then
            if best == nil or #dw.dir > #best.dir then
                best = dw
            end
        end
    end
    return best
end

-- Sorted keys of dirWatches (Go iterates the map in random order).
function watcher:dirWatchKeys()
    local keys = {}
    if self.dirWatches ~= nil then
        for k in pairs(self.dirWatches) do
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

function watcher:findConsolidationDirLocked(dir, physicalDir)
    if not self:canShareRecursiveDirWatches() then
        return ""
    end
    local parent = fswatch.filepathDir(dir)
    while parent ~= dir and parent ~= "." do
        if fswatch.filepathDir(parent) == parent then
            break
        end
        local physicalParent = fswatch.physicalDirFor(parent)
        if not fswatch.isInDirectoryOrSelf(physicalParent, physicalDir) then
            return ""
        end
        local count = 1
        for _, key in ipairs(self:dirWatchKeys()) do
            local dw = self.dirWatches[key]
            if fswatch.isInDirectoryOrSelf(parent, dw.dir) and fswatch.isInDirectoryOrSelf(physicalParent, dw.physicalDir) then
                count = count + 1
                if count >= fswatch.recursiveConsolidateThreshold then
                    return parent
                end
            end
        end
        local next_ = fswatch.filepathDir(parent)
        if next_ == parent then
            break
        end
        dir = parent
        parent = next_
    end
    return ""
end

function watcher:getOrCreateDirWatch(dir, physicalDir, recursive)
    if self.dirWatches == nil then
        self.dirWatches = {}
    end
    if self.debounce == nil then
        self.debounce = fswatch.newDebounce()
    end

    if self:canShareRecursiveDirWatches() then
        local dw = self:findCoveringRecursiveWatchLocked(dir, physicalDir)
        if dw ~= nil then
            return dw
        end
        local consolidationDir = self:findConsolidationDirLocked(dir, physicalDir)
        if consolidationDir ~= "" then
            dir = consolidationDir
            physicalDir = fswatch.physicalDirFor(dir)
            recursive = true
            dw = self:findCoveringRecursiveWatchLocked(dir, physicalDir)
            if dw ~= nil then
                return dw
            end
        end
    end

    local key = self:keyForDirWatch(dir, recursive)
    local existing = self.dirWatches[key]
    if existing ~= nil then
        return existing
    end
    local dw = fswatch.newDirWatch(dir, physicalDir, self.debounce)
    dw.sequence = self.sequence
    dw.recursive = recursive
    self.dirWatches[key] = dw
    return dw
end

function watcher:removeDirWatch(dw)
    local key = self:keyForDirWatch(dw.dir, dw.recursive)
    local existing = self.dirWatches and self.dirWatches[key]
    if existing ~= nil and existing == dw then
        self.dirWatches[key] = nil
        dw:destroyDebounce()
    end
end

function watcher:WatchDirectory(dir, fn, ...)
    local watches, err = self:WatchDirectories({ fswatch.NewWatchDirectoryRequest(dir, fn, { ... }) })
    if err ~= nil then
        return nil, err
    end
    return watches[1], nil
end

function watcher:WatchDirectories(requests)
    if not self:Available() then
        return nil, fswatch.ErrUnavailable
    end
    if #requests == 0 then
        return nil, nil
    end

    local prepared = {}
    local uniqueDirWatches = {}
    local seenDirWatches = {}
    local function rollback()
        for i = #prepared, 1, -1 do
            local p = prepared[i]
            p.dw:unwatch(p.id)
            p.dw:unref(self)
        end
    end

    for _, request in ipairs(requests) do
        local dir = request.dir
        local fn = request.callback
        if fn == nil then
            rollback()
            return nil, fswatch.errNilCallback
        end
        dir = fswatch.filepathClean(dir)
        if not fswatch.filepathIsAbs(dir) then
            rollback()
            return nil, fswatch.errNotAbsolute
        end
        dir = fswatch.canonicalizePath(dir)
        if self:canShareRecursiveDirWatches() then
            local err = fswatch.validateWatchDirectory(dir)
            if err ~= nil then
                rollback()
                return nil, err
            end
        end
        local physicalDir = fswatch.physicalDirFor(dir)

        local sopts = newWatchOptions()
        for _, o in ipairs(request.options or {}) do
            o:applyWatchOption(sopts)
        end

        local dw = self:getOrCreateDirWatch(dir, physicalDir, sopts.recursive)
        local id = dw:watch(dir, physicalDir, sopts.recursive, fn, sopts.ignore)
        prepared[#prepared + 1] = { dw = dw, id = id, recursive = sopts.recursive, dir = dir }
        if not seenDirWatches[dw] then
            seenDirWatches[dw] = true
            uniqueDirWatches[#uniqueDirWatches + 1] = dw
        end
    end

    local impl, err = self:getImpl()
    if err ~= nil then
        rollback()
        return nil, err
    end
    local aerr = impl:watchAddMany(uniqueDirWatches)
    if aerr ~= nil then
        rollback()
        return nil, aerr
    end

    local watches = {}
    for i, p in ipairs(prepared) do
        watches[i] = fswatch.newWatch(self, p.dw, impl, p.id)
    end
    return watches, nil
end

function fswatch.validateWatchDirectory(dir)
    local info, err = osvfs.osStat(dir)
    if err ~= nil then
        return err
    end
    if not info:IsDir() then
        return fswatch.ENOTDIR
    end
    return nil
end

function watcher:WatchFile(path, fn)
    if fn == nil then
        return nil, fswatch.errNilCallback
    end
    if not self:Available() then
        return nil, fswatch.ErrUnavailable
    end
    path = fswatch.filepathClean(path)
    if not fswatch.filepathIsAbs(path) then
        return nil, fswatch.errNotAbsolute
    end
    path = fswatch.canonicalizePath(path)
    local dir = fswatch.filepathDir(path)
    if dir == path then
        return nil, fswatch.errRootPath
    end

    return self:WatchDirectory(dir, fswatch.fileCallback(path, fn))
end

-- fileCallback wraps a WatchCallback so it only sees events for the
-- specific target path. Errors are always forwarded (with any matching
-- events delivered alongside) so callers don't lose overflow signals
-- just because their target wasn't in the same batch.
function fswatch.fileCallback(target, fn)
    return function(events, err)
        local filtered = nil
        for _, e in ipairs(events or {}) do
            if e.path == target then
                filtered = filtered or {}
                filtered[#filtered + 1] = e
            end
        end
        if (filtered ~= nil and #filtered > 0) or err ~= nil then
            fn(filtered, err)
        end
    end
end

local watch = {}
watch.__index = watch
fswatch.watch = watch

function fswatch.newWatch(w, dw, impl, id)
    return setmetatable({ w = w, dw = dw, impl = impl, id = id, cancelled = false }, watch)
end

function watch:Close()
    if self.cancelled then
        return nil
    end
    self.cancelled = true
    local last = self.dw:unwatch(self.id)
    if last then
        self.impl:watchRemove(self.dw)
        self.dw:unref(self.w)
    end
    return nil
end

-- watcherImpl is the internal interface implemented by each platform watcher:
--   start() -> err, run() -> err, shutdown(), watchAdd(w) -> err, watchAddMany(watches) -> err,
--   watchRemove(w), handleWatcherError(err), subscribe(w) -> err, closeWatch(w) -> err.

-- watcherBase provides shared watch-tracking and lifecycle logic.
-- Concrete backends embed it and override subscribe/closeWatch/start.
local watcherBase = {}
watcherBase.__index = watcherBase
fswatch.watcherBase = watcherBase

function watcherBase:init(self_)
    self.self = self_
    -- subscriptions is a set of dirWatch, kept as an insertion-ordered list plus a lookup table.
    self.subscriptions = {}
    self.subscriptionList = {}
    self.started = false
    self.startErr = nil
end

function watcherBase:notifyStarted()
    if not self.started then
        self.started = true
    end
end

function watcherBase:shutdown() end

-- Go runs start() on a goroutine and waits for notifyStarted; the Lua port calls it directly.
function watcherBase:run()
    local ok, perr = pcall(function()
        local err = self.self:start()
        if err ~= nil then
            self:handleStartError(err)
        end
    end)
    if not ok then
        local err = perr
        if type(err) ~= "table" then
            err = iofs.NewError(tostring(perr))
        end
        self:handleStartError(err)
    end
    return self.startErr
end

function watcherBase:handleStartError(err)
    self.startErr = err
    local subs = {}
    for _, w in ipairs(self.subscriptionList) do
        subs[#subs + 1] = w
    end
    for _, w in ipairs(subs) do
        w:notifyError(err)
    end
    self:notifyStarted()
end

function watcherBase:watchAdd(w)
    return self:watchAddMany({ w })
end

function watcherBase:addSubscription(w)
    if not self.subscriptions[w] then
        self.subscriptions[w] = true
        self.subscriptionList[#self.subscriptionList + 1] = w
    end
end

function watcherBase:deleteSubscription(w)
    if self.subscriptions[w] then
        self.subscriptions[w] = nil
        for i, s in ipairs(self.subscriptionList) do
            if s == w then
                table.remove(self.subscriptionList, i)
                break
            end
        end
    end
end

function watcherBase:watchAddMany(watches)
    local toAdd = {}
    for _, w in ipairs(watches) do
        if not self.subscriptions[w] then
            toAdd[#toAdd + 1] = w
        end
    end
    if #toAdd == 0 then
        return nil
    end

    if self.self.subscribeMany ~= nil then
        local err = self.self:subscribeMany(toAdd)
        if err ~= nil then
            return err
        end
        for _, w in ipairs(toAdd) do
            self:addSubscription(w)
        end
        return nil
    end

    local added = {}
    for _, w in ipairs(toAdd) do
        local err = self.self:subscribe(w)
        if err ~= nil then
            for _, addedWatch in ipairs(added) do
                self:deleteSubscription(addedWatch)
                self.self:closeWatch(addedWatch)
            end
            return err
        end
        self:addSubscription(w)
        added[#added + 1] = w
    end
    return nil
end

function watcherBase:watchRemove(w)
    if not self.subscriptions[w] then
        return
    end
    self:deleteSubscription(w)
    self.self:closeWatch(w)
end

function watcherBase:handleWatcherError(werr)
    self:watchRemove(werr.dirWatch)
    werr.dirWatch:notifyError(iofs.NewError(fswatch.ErrWatchTerminated:Error() .. ": " .. werr:Error(), fswatch.ErrWatchTerminated))
end

-- ----- dirWatch: per-directory watch state -------------------------

-- callback: { id, dir, physicalDir, watchDir, watchPhysicalDir, recursive, fn, ignore, sinceSeq,
--   terminal, delivered }
local callback = {}
callback.__index = callback
fswatch.callback = callback

-- dirWatchError associates an error with a specific directory watch.
local dirWatchError = {}
dirWatchError.__index = dirWatchError
fswatch.dirWatchError = dirWatchError

function fswatch.newDirWatchError(err, dw)
    return setmetatable({ err = err, dirWatch = dw, unwrap = err }, dirWatchError)
end

function dirWatchError:Error() return self.err:Error() end
function dirWatchError:Unwrap() return self.err end

-- dirWatch holds per-directory state: pending events, registered callbacks,
-- and a reference to the shared debouncer. Each watched directory has one.
local dirWatch = {}
dirWatch.__index = dirWatch
fswatch.dirWatch = dirWatch

function fswatch.newDirWatch(dir, physicalDir, db)
    local dw = setmetatable({
        -- dir is the caller-visible watch root used in delivered event paths.
        dir = dir,
        -- physicalDir is the path passed to OS watcher APIs. It differs from dir
        -- when dir or an ancestor is a symlink or reparse point to a directory.
        physicalDir = physicalDir,
        recursive = false,
        events = fswatch.newEventList(),
        -- state stores per-directory platform-specific bookkeeping.
        state = nil,
        -- sequence returns a backend event sequence cutoff for new logical callbacks.
        sequence = nil,
        callbacks = {},
        debounce = nil,
        nextCBID = 0,
    }, dirWatch)
    dw.debounce = db
    dw.debounce:add(dw, function() dw:triggerCallbacks() end)
    return dw
end

-- physicalDirFor returns the physical path to watch for dir. If dir, or an
-- ancestor of dir, is a symlink or reparse point, events are subscribed on its
-- realpath while callbacks still use dir.
function fswatch.physicalDirFor(dir)
    local realpath = fswatch.nativeRealpath(dir)
    if realpath == nil then
        return dir
    end
    if realpath == dir then
        return dir
    end
    return fswatch.canonicalizePath(fswatch.filepathClean(realpath))
end

-- nativepath.Realpath: returns nil on error.
function fswatch.nativeRealpath(path)
    local p = io.popen("realpath -e -- " .. osvfs.shellQuote(path) .. " 2>/dev/null")
    if p == nil then
        return nil
    end
    local resolved = p:read("l")
    p:close()
    if resolved == nil or resolved == "" then
        return nil
    end
    return resolved
end

-- displayPath maps a physical event path back under the caller-visible
-- watch root.
function dirWatch:displayPath(watchPath)
    return fswatch.rebasePath(watchPath, self.physicalDir, self.dir)
end

-- physicalPath maps a caller-visible path to the physical watched root.
function dirWatch:physicalPath(displayPath)
    return fswatch.rebasePath(displayPath, self.dir, self.physicalDir)
end

local function isPathSeparator(c)
    return c == 47 -- '/'
end

-- rebasePath replaces the from root in path with to, preserving any child
-- suffix. Prefix matches must end at a path separator so sibling paths like
-- "/foo2" are not rebased from "/foo".
function fswatch.rebasePath(path, from, to)
    if from == to then
        return path
    end
    if path == from then
        return to
    end
    if string.sub(path, 1, #from) ~= from then
        return path
    end
    local suffix = string.sub(path, #from + 1)
    if #from > 0 and isPathSeparator(string.byte(from, #from)) then
        return fswatch.joinPathSuffix(to, suffix)
    end
    if #suffix == 0 or not isPathSeparator(string.byte(suffix, 1)) then
        return path
    end
    return fswatch.joinPathSuffix(to, suffix)
end

function fswatch.joinPathSuffix(root, suffix)
    if suffix == "" then
        return root
    end
    if isPathSeparator(string.byte(suffix, 1)) then
        if #root > 0 and isPathSeparator(string.byte(root, #root)) then
            return root .. string.sub(suffix, 2)
        end
        return root .. suffix
    end
    if #root > 0 and isPathSeparator(string.byte(root, #root)) then
        return root .. suffix
    end
    return root .. "/" .. suffix
end

function dirWatch:destroyDebounce()
    local db = self.debounce
    self.debounce = nil
    if db ~= nil then
        db:remove(self)
    end
end

function dirWatch:notify()
    local hasPendingCBs = false
    local hasTerminal = false
    for _, cb in ipairs(self.callbacks) do
        if not cb.delivered then
            hasPendingCBs = true
            if cb.terminal ~= nil then
                hasTerminal = true
            end
        end
    end
    local hasEvents = self.events:size() > 0
    local hasError = self.events:hasError()
    local db = self.debounce

    if hasPendingCBs and (hasEvents or hasError or hasTerminal) and db ~= nil then
        db:trigger()
    end
end

function dirWatch:notifyError(err)
    local cbs = {}
    for i, cb in ipairs(self.callbacks) do
        cbs[i] = cb
    end
    self.callbacks = {}
    for _, cb in ipairs(cbs) do
        cb.fn(nil, err)
    end
end

function dirWatch:triggerCallbacks()
    local hasError = self.events:hasError()
    local hasEvents = self.events:size() > 0
    local cbs = {}
    local hasTerminal = false
    for _, cb in ipairs(self.callbacks) do
        if not cb.delivered then
            if cb.terminal ~= nil then
                hasTerminal = true
            end
            -- Go copies the callback struct.
            cbs[#cbs + 1] = setmetatable({
                id = cb.id, dir = cb.dir, physicalDir = cb.physicalDir, watchDir = cb.watchDir,
                watchPhysicalDir = cb.watchPhysicalDir, recursive = cb.recursive, fn = cb.fn,
                ignore = cb.ignore, sinceSeq = cb.sinceSeq, terminal = cb.terminal, delivered = cb.delivered,
            }, callback)
        end
    end
    if #cbs == 0 then
        if hasEvents or hasError then
            self.events:drain()
        end
        return
    end
    if not hasEvents and not hasError and not hasTerminal then
        return
    end
    local startSeqs = {}
    for i, cb in ipairs(cbs) do
        startSeqs[i] = cb.sinceSeq
    end
    local eventsByCallback, err = self.events:drainForSequences(startSeqs)
    for _, cb in ipairs(cbs) do
        if cb.terminal ~= nil then
            for _, orig in ipairs(self.callbacks) do
                if orig.id == cb.id then
                    orig.delivered = true
                    break
                end
            end
        end
    end

    for i, cb in ipairs(cbs) do
        local cbEvents = eventsByCallback[i]
        if cb.ignore ~= nil or not cb.recursive or cb.dir ~= self.dir then
            local filtered = {}
            for _, e in ipairs(cbEvents) do
                e = cb:mapEvent(e)
                local skip = false
                if cb.ignore ~= nil and cb.ignore(e.path) then
                    skip = true
                elseif cb.dir ~= self.dir and not e.includedWatchRoot and e.path == cb.dir and e.kind == fswatch.EventKind.EventUpdate then
                    skip = true
                elseif cb.recursive then
                    if cb.dir ~= self.dir and not fswatch.isInDirectoryOrSelf(cb.dir, e.path) then
                        skip = true
                    end
                elseif not fswatch.isDirectChild(cb.dir, e.path) and not (cb.dir ~= self.dir and e.path == cb.dir) then
                    skip = true
                end
                if not skip then
                    filtered[#filtered + 1] = e
                end
            end
            cbEvents = filtered
        end
        local cbErr = err
        if cb.terminal ~= nil then
            cbErr = cb.terminal
        end
        if #cbEvents > 0 or cbErr ~= nil then
            cb.fn(cbEvents, cbErr)
        end
    end
end

function callback:mapEvent(e)
    if self.physicalDir ~= "" and self.physicalDir ~= self.dir then
        local physicalPath = self:eventPhysicalPath(e.path)
        if fswatch.isInDirectoryOrSelf(self.physicalDir, physicalPath) then
            e = fswatch.NewEvent(e.kind, fswatch.rebasePath(physicalPath, self.physicalDir, self.dir), e.includedWatchRoot)
        end
    end
    return e
end

function callback:eventPhysicalPath(path)
    if self.watchPhysicalDir ~= "" and self.watchDir ~= "" and self.watchPhysicalDir ~= self.watchDir and fswatch.isInDirectoryOrSelf(self.watchDir, path) then
        return fswatch.rebasePath(path, self.watchDir, self.watchPhysicalDir)
    end
    return path
end

function dirWatch:terminateCallbacksForDeletedRoot(path, seq, err)
    local changed = false
    for _, cb in ipairs(self.callbacks) do
        if not (cb.delivered or cb.terminal ~= nil or cb.sinceSeq >= seq) then
            local physicalPath = cb:eventPhysicalPath(path)
            if fswatch.isInDirectoryOrSelf(path, cb.dir) or (cb.physicalDir ~= cb.dir and fswatch.isInDirectoryOrSelf(physicalPath, cb.physicalDir)) then
                cb.terminal = err
                changed = true
            end
        end
    end
    return changed
end

function fswatch.isInDirectoryOrSelf(dir, path)
    if dir == "" then
        return false
    end
    if path == dir then
        return true
    end
    if string.sub(path, 1, #dir) ~= dir then
        return false
    end
    local rest = string.sub(path, #dir + 1)
    if #rest == 0 then
        return false
    end
    if isPathSeparator(string.byte(dir, #dir)) then
        return true
    end
    return isPathSeparator(string.byte(rest, 1))
end

-- isDirectChild reports whether path is an immediate child of dir.
-- Both paths must be absolute. Returns false for path == dir.
function fswatch.isDirectChild(dir, path)
    if string.sub(path, 1, #dir) ~= dir then
        return false
    end
    local rest = string.sub(path, #dir + 1)
    if #rest == 0 then
        return false
    end
    if string.byte(rest, 1) ~= 47 then
        return false
    end
    rest = string.sub(rest, 2)
    return #rest > 0 and string.find(rest, "/", 1, true) == nil
end

-- Returns (id, ok).
function dirWatch:watch(dir, physicalDir, recursive, fn, ignore)
    self.nextCBID = self.nextCBID + 1
    local id = self.nextCBID
    local sinceSeq = self.events:sequence()
    if self.sequence ~= nil then
        sinceSeq = self.sequence()
    end
    self.callbacks[#self.callbacks + 1] = setmetatable({
        id = id,
        dir = dir,
        physicalDir = physicalDir,
        watchDir = self.dir,
        watchPhysicalDir = self.physicalDir,
        recursive = recursive,
        fn = fn,
        ignore = ignore,
        sinceSeq = sinceSeq,
        terminal = nil,
        delivered = false,
    }, callback)
    return id, true
end

function dirWatch:unwatch(id)
    for i, cb in ipairs(self.callbacks) do
        if cb.id == id then
            table.remove(self.callbacks, i)
            return #self.callbacks == 0
        end
    end
    return false
end

function dirWatch:unref(w)
    local empty = #self.callbacks == 0
    if empty then
        w:removeDirWatch(self)
    end
end

