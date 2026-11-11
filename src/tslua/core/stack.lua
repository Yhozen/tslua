local core = require("tslua.core")

local Stack = {}
Stack.__index = Stack
core.Stack = Stack

function core.NewStack()
    return setmetatable({ data = {} }, Stack)
end

function Stack:Push(item)
    if self.data == nil then
        self.data = {}
    end
    self.data[#self.data + 1] = item
end

function Stack:Pop()
    local l = core.Len(self.data)
    if l == 0 then
        error("stack is empty", 0)
    end
    local item = self.data[l]
    self.data[l] = nil
    return item
end

function Stack:Peek()
    local l = core.Len(self.data)
    if l == 0 then
        error("stack is empty", 0)
    end
    return self.data[l]
end

function Stack:Len()
    return core.Len(self.data)
end
