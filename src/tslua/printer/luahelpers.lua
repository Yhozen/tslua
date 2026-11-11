-- Lua-only support code for the printer package (no Go counterpart).
--
-- Small stand-ins for Go standard library / generic containers used by the printer:
--   * strings.Builder       -> printer.newStringsBuilder()
--   * core.Stack[T]         -> printer.newStack()
--   * collections.Set[T]    -> printer.newSet()
--   * collections.OrderedSet[T] -> printer.newOrderedSet()
--   * iter.Seq[T] results   -> printer.collectSeq(seq) (accepts an array or a Lua iterator function)
--   * debug.Assert / debug.Fail -> printer.debugAssert / printer.debugFail
local printer = require("tslua.printer")

-- strings.Builder

local StringsBuilder = {}
StringsBuilder.__index = StringsBuilder
printer.StringsBuilder = StringsBuilder

function printer.newStringsBuilder()
    return setmetatable({ parts = {}, n = 0, len = 0 }, StringsBuilder)
end

function StringsBuilder:WriteString(s)
    if s ~= "" then
        local n = self.n + 1
        self.parts[n] = s
        self.n = n
        self.len = self.len + #s
    end
end

function StringsBuilder:WriteByte(b)
    self:WriteString(string.char(b))
end

function StringsBuilder:WriteRune(r)
    if r < 0 or r > 0x10FFFF or (r >= 0xD800 and r <= 0xDFFF) then
        r = 0xFFFD
    end
    self:WriteString(utf8.char(r))
end

function StringsBuilder:Len()
    return self.len
end

function StringsBuilder:String()
    if self.n == 0 then
        return ""
    end
    if self.n > 1 then
        local s = table.concat(self.parts, "", 1, self.n)
        self.parts = { s }
        self.n = 1
    end
    return self.parts[1]
end

function StringsBuilder:Reset()
    self.parts = {}
    self.n = 0
    self.len = 0
end

function StringsBuilder:Grow(_)
end

-- core.Stack[T]

local Stack = {}
Stack.__index = Stack
printer.Stack = Stack

function printer.newStack()
    return setmetatable({ data = {} }, Stack)
end

function Stack:Push(item)
    self.data[#self.data + 1] = item
end

function Stack:Pop()
    local l = #self.data
    if l == 0 then
        error("stack is empty", 0)
    end
    local item = self.data[l]
    self.data[l] = nil
    return item
end

function Stack:Peek()
    local l = #self.data
    if l == 0 then
        error("stack is empty", 0)
    end
    return self.data[l]
end

function Stack:Len()
    return #self.data
end

-- collections.Set[T]

local Set = {}
Set.__index = Set
printer.Set = Set

function printer.newSet()
    return setmetatable({ m = {}, n = 0 }, Set)
end

function Set:Has(key)
    return self.m[key] ~= nil
end

function Set:Add(key)
    if self.m[key] == nil then
        self.m[key] = true
        self.n = self.n + 1
    end
end

function Set:AddIfAbsent(key)
    if self.m[key] ~= nil then
        return false
    end
    self:Add(key)
    return true
end

function Set:Delete(key)
    if self.m[key] ~= nil then
        self.m[key] = nil
        self.n = self.n - 1
    end
end

function Set:Len()
    return self.n
end

function Set:Clear()
    self.m = {}
    self.n = 0
end

-- collections.OrderedSet[T]

local OrderedSet = {}
OrderedSet.__index = OrderedSet
printer.OrderedSet = OrderedSet

function printer.newOrderedSet()
    return setmetatable({ values = {}, index = {} }, OrderedSet)
end

function OrderedSet:Add(value)
    if self.index[value] == nil then
        self.values[#self.values + 1] = value
        self.index[value] = true
    end
end

function OrderedSet:Has(value)
    return self.index[value] ~= nil
end

function OrderedSet:Delete(value)
    if self.index[value] == nil then
        return false
    end
    self.index[value] = nil
    for i, v in ipairs(self.values) do
        if v == value then
            table.remove(self.values, i)
            break
        end
    end
    return true
end

-- Values returns a fresh array of the values in insertion order.
function OrderedSet:Values()
    local result = {}
    for i, v in ipairs(self.values) do
        result[i] = v
    end
    return result
end

function OrderedSet:Clear()
    self.values = {}
    self.index = {}
end

function OrderedSet:Size()
    return #self.values
end

-- iter.Seq[T]: dependencies may return either a materialized array or a Lua iterator function
-- (usable as `for v in seq do`). collectSeq always returns an array.
function printer.collectSeq(seq)
    if seq == nil then
        return {}
    end
    if type(seq) == "function" then
        local result = {}
        for v in seq do
            result[#result + 1] = v
        end
        return result
    end
    return seq
end

-- debug.Assert / debug.Fail

function printer.debugAssert(cond, msg)
    if not cond then
        error(msg or "assertion failed", 2)
    end
end

function printer.debugFail(msg)
    error(msg or "debug fail", 2)
end

-- slices.SortStableFunc(xs, cmp): in-place stable insertion sort; cmp returns <0, 0, >0.
function printer.sortStableFunc(xs, cmp)
    for i = 2, #xs do
        local v = xs[i]
        local j = i - 1
        while j >= 1 and cmp(xs[j], v) > 0 do
            xs[j + 1] = xs[j]
            j = j - 1
        end
        xs[j + 1] = v
    end
end
