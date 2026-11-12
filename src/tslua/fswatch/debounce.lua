local fswatch = require("tslua.fswatch")

-- Durations are float seconds.
fswatch.defaultMinWaitTime = 0.050
fswatch.defaultMaxWaitTime = 0.500

fswatch.minWaitTime = fswatch.defaultMinWaitTime
fswatch.maxWaitTime = fswatch.defaultMaxWaitTime

-- Time and sleeping (Lua-specific: Go uses time.Now, time.After and goroutines).
--
-- The port is single threaded, so there is no background goroutine per debounce instance. Instead
-- the polling run loop (fswatch.RunPollingLoop / watchmanager RunLoop) repeatedly calls
-- fswatch.Tick(), which polls the polling backend and then advances every debounce instance
-- (debounce:tick replaces debounce.loop/notifyIfReady/coalesceWait).
--
-- fswatch.now() is a monotonic clock in seconds: the total time slept through fswatch.Sleep plus
-- the processor time used (os.clock). Sleeping is done with os.execute("sleep <seconds>") (POSIX
-- sleep(1) with fractional seconds, as provided by GNU coreutils and busybox).
fswatch.sleptTime = 0

function fswatch.now()
    return fswatch.sleptTime + os.clock()
end

-- Sleep blocks for d seconds. It returns false when the sleep was interrupted by a signal (for
-- example Ctrl-C), in which case the caller should stop its loop.
function fswatch.Sleep(d)
    local ok, how = os.execute("sleep " .. string.format("%.3f", d))
    fswatch.sleptTime = fswatch.sleptTime + d
    if ok ~= true and how == "signal" then
        return false
    end
    return true
end

-- debounce batches filesystem events for one backend. Each *watcher
-- owns one debounce instance, created lazily on first subscribe and
-- living for the process lifetime.
--
-- Per-backend (rather than process-wide) isolation means a slow user
-- callback on one backend cannot starve event delivery on the others.
--
-- Internally uses a resettable latch: the loop blocks until trigger()
-- is called, then coalesces for minWaitTime before firing callbacks.
local debounce = {}
debounce.__index = debounce
fswatch.debounce = debounce

-- All debounce instances, ticked by fswatch.Tick.
fswatch.debounces = {}

function fswatch.newDebounce()
    local d = setmetatable({
        -- callbacks is an insertion-ordered list of { key = any, cb = func() } (a Go map keyed by
        -- the dirWatch; kept ordered so callbacks fire deterministically).
        callbacks = {},
        lastTime = 0,
        notified = false,
        triggerTime = 0,
    }, debounce)
    -- Go starts `go d.loop()` here; the Lua loop is driven by fswatch.Tick.
    fswatch.debounces[#fswatch.debounces + 1] = d
    return d
end

-- add registers a callback under key.
function debounce:add(key, cb)
    for _, entry in ipairs(self.callbacks) do
        if entry.key == key then
            entry.cb = cb
            return
        end
    end
    self.callbacks[#self.callbacks + 1] = { key = key, cb = cb }
end

-- remove deregisters the callback for key.
function debounce:remove(key)
    for i, entry in ipairs(self.callbacks) do
        if entry.key == key then
            table.remove(self.callbacks, i)
            return
        end
    end
end

-- trigger wakes the debounce loop.
function debounce:trigger()
    if not self.notified then
        self.notified = true
    end
    -- Replaces closing triggerCh: a new trigger restarts the coalescing wait.
    self.triggerTime = fswatch.now()
end

-- tick runs one step of Go's loop: when the latch is signalled, fire immediately if more than
-- maxWaitTime passed since the last delivery (notifyIfReady), otherwise fire once no new trigger
-- arrived for minWaitTime (coalesceWait).
function debounce:tick(now)
    if not self.notified then
        return
    end
    self:notifyIfReady(now)
end

function debounce:notifyIfReady(now)
    local gap = now - self.lastTime
    if gap > fswatch.maxWaitTime then
        self.lastTime = now
        self:fireCallbacks()
        return
    end
    self:coalesceWait(now)
end

function debounce:coalesceWait(now)
    if now - self.triggerTime >= fswatch.minWaitTime then
        self:fireCallbacks()
    end
    -- Otherwise keep waiting; the next tick checks again.
end

-- fireCallbacks snapshots and invokes all registered callbacks.
function debounce:fireCallbacks()
    self.lastTime = fswatch.now()
    local cbs = {}
    for _, entry in ipairs(self.callbacks) do
        cbs[#cbs + 1] = entry.cb
    end

    self:latchReset()

    for _, cb in ipairs(cbs) do
        cb()
    end
end

-- ----- latch helpers (replace signal_) ------------------------------------

function debounce:latchReset()
    if self.notified then
        self.notified = false
    end
end
