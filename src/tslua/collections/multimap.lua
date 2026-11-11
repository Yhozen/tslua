local collections = require("tslua.collections")

-- MultiMap: field m is a Lua table key -> array of values (Go `M map[K][]V`).
local MultiMap = {}
MultiMap.__index = MultiMap
collections.MultiMap = MultiMap

function collections.NewMultiMapWithSizeHint(hint)
    return setmetatable({ m = {} }, MultiMap)
end

-- Zero value (Go `&collections.MultiMap[K, V]{}`).
function collections.NewMultiMap()
    return setmetatable({ m = nil }, MultiMap)
end

function collections.GroupBy(items, groupId)
    local m = collections.NewMultiMap()
    for _, item in ipairs(items or {}) do
        m:Add(groupId(item), item)
    end
    return m
end

function MultiMap:Has(key)
    return self.m ~= nil and self.m[key] ~= nil
end

function MultiMap:Get(key)
    if self.m == nil then
        return nil
    end
    return self.m[key]
end

function MultiMap:Add(key, value)
    if self.m == nil then
        self.m = {}
    end
    local values = self.m[key]
    if values == nil then
        values = {}
        self.m[key] = values
    end
    values[#values + 1] = value
end

function MultiMap:Remove(key, value)
    if self.m == nil then
        return
    end
    local values = self.m[key]
    if values ~= nil then
        local i = -1
        for j = 1, #values do
            if values[j] == value then
                i = j
                break
            end
        end
        if i >= 1 then
            if #values == 1 then
                self.m[key] = nil
            else
                local newValues = {}
                for j = 1, #values do
                    if j ~= i then
                        newValues[#newValues + 1] = values[j]
                    end
                end
                self.m[key] = newValues
            end
        end
    end
end

function MultiMap:RemoveAll(key)
    if self.m ~= nil then
        self.m[key] = nil
    end
end

function MultiMap:Len()
    local n = 0
    for _ in pairs(self.m or {}) do
        n = n + 1
    end
    return n
end

-- Returns a Lua iterator over the keys (unordered, like Go maps.Keys).
function MultiMap:Keys()
    local k = nil
    local m = self.m or {}
    return function()
        k = next(m, k)
        return k
    end
end

-- Returns a Lua iterator over the value arrays (unordered, like Go maps.Values).
function MultiMap:Values()
    local k = nil
    local m = self.m or {}
    return function()
        local v
        k, v = next(m, k)
        return v
    end
end

function MultiMap:Clear()
    self.m = {}
end
