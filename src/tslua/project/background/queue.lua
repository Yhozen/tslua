local background = require("tslua.project.background")
local core = require("tslua.core")

-- Queue manages background tasks execution. In the sequential port, enqueued tasks are deferred
-- and run in FIFO order by Wait (tasks enqueued while waiting are run too), which is the order Go
-- observes when each task finishes before the next is started.
local Queue = {}
Queue.__index = Queue
background.Queue = Queue

-- NewQueue creates a new background queue for managing background tasks execution.
function background.NewQueue()
    return setmetatable({ tasks = {}, head = 1, closed = false }, Queue)
end

function Queue:Enqueue(ctx, fn)
    if self.closed then
        return
    end

    -- Don't start new tasks if context is already cancelled
    if core.ContextErr(ctx) ~= nil then
        return
    end

    self.tasks[#self.tasks + 1] = { ctx = ctx, fn = fn }
end

-- Wait waits for all active tasks to complete.
-- It does not prevent new tasks from being enqueued while waiting.
function Queue:Wait()
    while self.head <= #self.tasks do
        local task = self.tasks[self.head]
        self.tasks[self.head] = false
        self.head = self.head + 1
        -- Check context again before executing
        if core.ContextErr(task.ctx) == nil then
            task.fn(task.ctx)
        end
    end
    self.tasks = {}
    self.head = 1
end

-- Len returns the number of tasks that have not run yet (Lua-only, for tests).
function Queue:Len()
    return #self.tasks - self.head + 1
end

function Queue:Close()
    self.closed = true
end
