local collections = require("tslua.collections")

-- Set: field m is a Lua table key -> true (Go `M map[T]struct{}`). Methods tolerate a nil
-- receiver where Go's do (call as collections.Set.Has(s, k) when s may be nil).
local Set = {}
Set.__index = Set
collections.Set = Set

-- NewSetWithSizeHint creates a new Set with a hint for the number of elements it will contain.
function collections.NewSetWithSizeHint(hint)
    return setmetatable({ m = {} }, Set)
end

-- Zero value (Go `&collections.Set[T]{}`).
function collections.NewSet()
    return setmetatable({ m = nil }, Set)
end

function Set:Has(key)
    if self == nil or self.m == nil then
        return false
    end
    return self.m[key] ~= nil
end

function Set:Add(key)
    if self.m == nil then
        self.m = {}
    end
    self.m[key] = true
end

function Set:Delete(key)
    if self.m ~= nil then
        self.m[key] = nil
    end
end

function Set:Len()
    if self == nil or self.m == nil then
        return 0
    end
    local n = 0
    for _ in pairs(self.m) do
        n = n + 1
    end
    return n
end

-- Returns the underlying table (key -> true); iterate with pairs.
function Set:Keys()
    if self == nil then
        return nil
    end
    return self.m
end

function Set:Clear()
    if self == nil then
        return
    end
    self.m = {}
end

-- Returns true if the key was not already present in the set.
function Set:AddIfAbsent(key)
    if Set.Has(self, key) then
        return false
    end
    self:Add(key)
    return true
end

local function cloneTable(t)
    if t == nil then
        return nil
    end
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return c
end

function Set:Clone()
    if self == nil then
        return nil
    end
    return setmetatable({ m = cloneTable(self.m) }, Set)
end

function Set:Union(other)
    if Set.Len(self) == 0 and Set.Len(other) == 0 then
        return
    end
    if self == nil then
        error("cannot modify nil Set", 0)
    end
    if self.m == nil then
        self.m = cloneTable(other.m)
        return
    end
    for k, v in pairs(other.m) do
        self.m[k] = v
    end
end

function Set:UnionedWith(other)
    if self == nil and other == nil then
        return nil
    end
    local result = Set.Clone(self)
    if other ~= nil then
        if result == nil then
            result = collections.NewSet()
        end
        if result.m == nil then
            result.m = {}
        end
        for k, v in pairs(other.m or {}) do
            result.m[k] = v
        end
    end
    return result
end

function Set:Equals(other)
    if self == other then
        return true
    end
    if self == nil or other == nil then
        return false
    end
    local a, b = self.m or {}, other.m or {}
    for k in pairs(a) do
        if b[k] == nil then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function Set:IsSubsetOf(other)
    if self == nil then
        return true
    end
    for key in pairs(self.m or {}) do
        if not Set.Has(other, key) then
            return false
        end
    end
    return true
end

function Set:Intersects(other)
    if self == nil or other == nil then
        return false
    end
    for key in pairs(self.m or {}) do
        if Set.Has(other, key) then
            return true
        end
    end
    return false
end

function collections.NewSetFromItems(...)
    local s = collections.NewSet()
    for i = 1, select("#", ...) do
        s:Add((select(i, ...)))
    end
    return s
end
