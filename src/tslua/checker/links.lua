local checker = require("tslua.checker")

-- LinkStore is the Lua form of core.LinkStore[K, V], nodeLinkStore[V] and symbolArenaLinkStore[V]:
-- a links store keyed by the node / symbol / source file table itself. Go relies on the zero value
-- of V; here `newValue` (usually a checker.X_new constructor) creates a zero-valued V.
local LinkStore = {}
LinkStore.__index = LinkStore
checker.LinkStore = LinkStore

function checker.NewLinkStore(newValue)
    return setmetatable({ entries = {}, newValue = newValue }, LinkStore)
end

-- Get returns the links for key, creating zero-valued links on first access.
function LinkStore:Get(key)
    local value = self.entries[key]
    if value ~= nil then
        return value
    end
    value = self.newValue()
    self.entries[key] = value
    return value
end

function LinkStore:Has(key)
    return self.entries[key] ~= nil
end

function LinkStore:TryGet(key)
    return self.entries[key]
end

-- nodeLinkStore is a links store keyed by node references.
checker.nodeLinkStore = LinkStore

-- symbolArenaLinkStore is a links store keyed by symbol references.
checker.symbolArenaLinkStore = LinkStore
