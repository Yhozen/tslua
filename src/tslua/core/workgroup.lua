local core = require("tslua.core")

-- WorkGroup: Queue(fn) queues a function to run; RunAndWait() runs all queued functions.
-- Both the single-threaded and the parallel Go variants are the sequential single-threaded
-- group in Lua (functions run LIFO, like Go's singleThreadedWorkGroup).
local singleThreadedWorkGroup = {}
singleThreadedWorkGroup.__index = singleThreadedWorkGroup
core.singleThreadedWorkGroup = singleThreadedWorkGroup

function core.NewWorkGroup(singleThreaded)
    return setmetatable({ done = false, fns = {} }, singleThreadedWorkGroup)
end

function singleThreadedWorkGroup:Queue(fn)
    if self.done then
        error("Queue called after RunAndWait returned", 0)
    end

    self.fns[#self.fns + 1] = fn
end

function singleThreadedWorkGroup:RunAndWait()
    while true do
        local fn = self:pop()
        if fn == nil then
            self.done = true
            return
        end
        fn()
    end
end

function singleThreadedWorkGroup:pop()
    local n = #self.fns
    if n == 0 then
        return nil
    end
    local fn = self.fns[n]
    self.fns[n] = nil
    return fn
end

-- ThrottleGroup is like errgroup.Group but with global concurrency limiting via a semaphore.
-- Sequential in Lua: Go runs fn immediately and records the first error.
local ThrottleGroup = {}
ThrottleGroup.__index = ThrottleGroup
core.ThrottleGroup = ThrottleGroup

-- NewThrottleGroup creates a new ThrottleGroup with the given context and semaphore for concurrency limiting.
function core.NewThrottleGroup(ctx, semaphore)
    return setmetatable({ semaphore = semaphore, err = nil }, ThrottleGroup)
end

-- Go runs the given function (immediately, in Lua).
function ThrottleGroup:Go(fn)
    local err = fn()
    if err ~= nil and self.err == nil then
        self.err = err
    end
end

-- Wait returns the first error encountered, if any.
function ThrottleGroup:Wait()
    return self.err
end
