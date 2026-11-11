local collections = require("tslua.collections")

-- SyncSet is a plain set in the sequential Lua port.
local SyncSet = {}
SyncSet.__index = SyncSet
collections.SyncSet = SyncSet

function collections.NewSyncSet()
    return setmetatable({ m = collections.NewSyncMap() }, SyncSet)
end

function SyncSet:Has(key)
    local _, ok = self.m:Load(key)
    return ok
end

function SyncSet:Add(key)
    self:AddIfAbsent(key)
end

-- AddIfAbsent adds the key to the set if it is not already present
-- using LoadOrStore. It returns true if the key was not already present
-- (opposite of the return value of LoadOrStore).
function SyncSet:AddIfAbsent(key)
    local _, loaded = self.m:LoadOrStore(key, true)
    return not loaded
end

function SyncSet:Delete(key)
    self.m:Delete(key)
end

function SyncSet:Range(fn)
    self.m:Range(function(key, value)
        return fn(key)
    end)
end

-- Size returns the number of items in the set.
function SyncSet:Size()
    return self.m:Size()
end

function SyncSet:IsEmpty()
    return next(self.m.m) == nil
end

function SyncSet:ToSlice()
    local arr = {}
    self.m:Range(function(key, value)
        arr[#arr + 1] = key
        return true
    end)
    return arr
end

-- Returns a Lua iterator over the keys.
function SyncSet:Keys()
    return self.m:Keys()
end
