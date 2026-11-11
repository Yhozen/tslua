local collections = require("tslua.collections")

-- CopyOnWriteMap is a map that defers cloning of an inherited backing map
-- until the first mutation, and supports nested scopes that share the parent's
-- map for reads but get their own clone on write.
--
-- collections.NewCopyOnWriteMap() is the zero value: an empty map ready to use.
local CopyOnWriteMap = {}
CopyOnWriteMap.__index = CopyOnWriteMap
collections.CopyOnWriteMap = CopyOnWriteMap

function collections.NewCopyOnWriteMap()
    return setmetatable({ m = nil, owned = false }, CopyOnWriteMap)
end

-- Get returns the value for k and whether it was present.
function CopyOnWriteMap:Get(k)
    if self.m == nil then
        return nil, false
    end
    local v = self.m[k]
    return v, v ~= nil
end

-- Has reports whether k is in the map.
function CopyOnWriteMap:Has(k)
    return self.m ~= nil and self.m[k] ~= nil
end

-- Set assigns v to k, cloning the inherited backing map first if necessary.
function CopyOnWriteMap:Set(k, v)
    self:ensureOwned()
    self.m[k] = v
end

function CopyOnWriteMap:ensureOwned()
    if self.owned then
        return
    end
    if self.m == nil then
        self.m = {}
    else
        local c = {}
        for k, v in pairs(self.m) do
            c[k] = v
        end
        self.m = c
    end
    self.owned = true
end

-- EnterScope returns a function that restores this map to its current state.
-- While the scope is active, the map shares its current backing storage with
-- the parent scope: reads see the inherited entries, and the first mutation
-- transparently clones the storage so the parent's view is not modified.
function CopyOnWriteMap:EnterScope()
    local savedM, savedOwned = self.m, self.owned
    self.owned = false
    return function()
        self.m = savedM
        self.owned = savedOwned
    end
end

local CopyOnWriteSet = {}
CopyOnWriteSet.__index = CopyOnWriteSet
collections.CopyOnWriteSet = CopyOnWriteSet

function collections.NewCopyOnWriteSet()
    return setmetatable({ m = collections.NewCopyOnWriteMap() }, CopyOnWriteSet)
end

-- Has reports whether k is in the set.
function CopyOnWriteSet:Has(k)
    local _, ok = self.m:Get(k)
    return ok
end

-- Set adds k to the set, cloning the inherited backing map first if necessary.
function CopyOnWriteSet:Add(k)
    self.m:Set(k, true)
end

-- EnterScope returns a function that restores this set to its current state.
function CopyOnWriteSet:EnterScope()
    return self.m:EnterScope()
end
