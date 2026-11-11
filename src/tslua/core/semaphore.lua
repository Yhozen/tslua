local core = require("tslua.core")

-- Semaphores are no-ops in the sequential Lua port.
local function noop()
end

local UnlimitedSemaphore = {}
UnlimitedSemaphore.__index = UnlimitedSemaphore
core.UnlimitedSemaphore = UnlimitedSemaphore

function UnlimitedSemaphore:Acquire()
    return noop
end

function UnlimitedSemaphore:TryAcquire(ctx)
    return noop, true
end

local LimitedSemaphore = {}
LimitedSemaphore.__index = LimitedSemaphore
core.LimitedSemaphore = LimitedSemaphore

function core.NewLimitedSemaphore(maxConcurrency)
    if maxConcurrency <= 0 then
        error("maxConcurrency must be positive", 0)
    end
    local s = setmetatable({ count = 0, max = maxConcurrency }, LimitedSemaphore)
    s.release = function()
        s.count = s.count - 1
    end
    return s
end

function LimitedSemaphore:Acquire()
    if self.count >= self.max then
        error("LimitedSemaphore: Acquire would block forever in sequential code", 0)
    end
    self.count = self.count + 1
    return self.release
end

function LimitedSemaphore:TryAcquire(ctx)
    if self.count < self.max then
        self.count = self.count + 1
        return self.release, true
    end
    return noop, false
end
