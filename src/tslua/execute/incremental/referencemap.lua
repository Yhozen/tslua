local incremental = require("tslua.execute.incremental")
local collections = require("tslua.collections")

-- referenceMap: references is a SyncMap path -> *collections.Set[path]; referencedBy is built once.
local referenceMap = {}
referenceMap.__index = referenceMap
incremental.referenceMap = referenceMap

function incremental.newReferenceMap()
    return setmetatable({
        references = collections.NewSyncMap(),
        referencedBy = nil,
        referenceByDone = false,
    }, referenceMap)
end

function referenceMap:storeReferences(path, refs)
    self.references:Store(path, refs)
end

-- Returns (refs, ok).
function referenceMap:getReferences(path)
    return self.references:Load(path)
end

function referenceMap:getPathsWithReferences()
    local result = {}
    for k in self.references:Keys() do
        result[#result + 1] = k
    end
    return result
end

-- Returns a Lua iterator over the paths referencing path (sorted, for determinism; Go's order is
-- random).
function referenceMap:getReferencedBy(path)
    if not self.referenceByDone then
        self.referenceByDone = true
        self.referencedBy = {}
        incremental.rangeSorted(self.references, function(key, value)
            for ref in pairs(value:Keys() or {}) do
                local set = self.referencedBy[ref]
                if set == nil then
                    set = collections.NewSet()
                    self.referencedBy[ref] = set
                end
                set:Add(key)
            end
            return true
        end)
    end
    local refs = self.referencedBy[path]
    if refs ~= nil then
        return incremental.sortedKeysIter(refs:Keys())
    end
    return function() return nil end
end
