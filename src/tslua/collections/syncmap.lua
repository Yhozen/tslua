local collections = require("tslua.collections")

-- SyncMap is a plain map in the sequential Lua port. nil values are stored as a sentinel.
local SyncMap = {}
SyncMap.__index = SyncMap
collections.SyncMap = SyncMap

local NIL = {}

function collections.NewSyncMap()
    return setmetatable({ m = {} }, SyncMap)
end

-- Returns (value, ok).
function SyncMap:Load(key)
    local val = self.m[key]
    if val == nil then
        return nil, false
    end
    if val == NIL then
        return nil, true
    end
    return val, true
end

function SyncMap:Store(key, value)
    if value == nil then
        value = NIL
    end
    self.m[key] = value
end

-- Returns (actual, loaded).
function SyncMap:LoadOrStore(key, value)
    local actual, ok = self:Load(key)
    if ok then
        return actual, true
    end
    self:Store(key, value)
    return value, false
end

function SyncMap:Delete(key)
    self.m[key] = nil
end

function SyncMap:Clear()
    self.m = {}
end

-- f(key, value) returns false to stop.
function SyncMap:Range(f)
    for k, v in pairs(self.m) do
        if v == NIL then
            v = nil
        end
        if not f(k, v) then
            return
        end
    end
end

-- Size returns the number of items in the map.
function SyncMap:Size()
    local count = 0
    for _ in pairs(self.m) do
        count = count + 1
    end
    return count
end

function SyncMap:ToMap()
    local m = {}
    for k, v in pairs(self.m) do
        if v ~= NIL then
            m[k] = v
        end
    end
    return m
end

-- Returns a Lua iterator over the keys.
function SyncMap:Keys()
    local k = nil
    local m = self.m
    return function()
        k = next(m, k)
        return k
    end
end

function SyncMap:Clone()
    local clone = collections.NewSyncMap()
    for k, v in pairs(self.m) do
        clone.m[k] = v
    end
    return clone
end
