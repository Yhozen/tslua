local lsp = require("tslua.lsp")
local core = require("tslua.core")

-- Inspired by Brian C. Mills' "Rethinking Classical Concurrency Patterns" talk:
-- https://www.youtube.com/watch?v=5zXAHh5tJqQ
--
-- In Go this queue is a state machine of channels so that Get blocks until an item is put.
-- The sequential port is a plain FIFO: Get on an empty queue cannot wait for another goroutine,
-- so it returns lsp.errQueueEmpty (callers check Len first).

lsp.errQueueEmpty = "dynamicQueue: empty"

local dynamicQueue = {}
dynamicQueue.__index = dynamicQueue
lsp.dynamicQueue = dynamicQueue

function lsp.newDynamicQueue()
    return setmetatable({ items = {}, head = 1 }, dynamicQueue)
end

-- Returns err.
function dynamicQueue:Put(ctx, item)
    local err = core.ContextErr(ctx)
    if err ~= nil then
        return err
    end

    self.items[#self.items + 1] = item
    return nil
end

-- Returns (item, err).
function dynamicQueue:Get(ctx)
    local err = core.ContextErr(ctx)
    if err ~= nil then
        return nil, err
    end

    if self.head > #self.items then
        return nil, lsp.errQueueEmpty
    end

    local item = self.items[self.head]
    self.items[self.head] = false
    self.head = self.head + 1

    if self.head > #self.items then
        self.items = {}
        self.head = 1
    end
    return item, nil
end

-- Len returns the number of queued items (Lua-only).
function dynamicQueue:Len()
    return #self.items - self.head + 1
end
