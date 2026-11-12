local build = require("tslua.execute.build")
local collections = require("tslua.collections")

-- parseCacheEntry: { value = V } (the Go mutex is not needed in the sequential port)

local parseCache = {}
parseCache.__index = parseCache
build.parseCache = parseCache

-- keyOf maps a key to a Lua table key (Go uses comparable structs as map keys); nil means the
-- key is used as is.
function build.newParseCache(keyOf)
    return setmetatable({ entries = collections.NewSyncMap(), keyOf = keyOf }, parseCache)
end

function parseCache:mapKey(key)
    if self.keyOf ~= nil then
        return self.keyOf(key)
    end
    return key
end

function parseCache:loadOrStore(key, parse, allowZero)
    local newEntry = { value = nil }
    local entry, loaded = self.entries:LoadOrStore(self:mapKey(key), newEntry)
    if loaded then
        if allowZero or entry.value ~= nil then
            return entry.value
        end
        newEntry = entry
    end
    newEntry.value = parse(key)
    return newEntry.value
end

function parseCache:store(key, value)
    self.entries:Store(self:mapKey(key), { value = value })
end

function parseCache:delete(key)
    self.entries:Delete(self:mapKey(key))
end

function parseCache:reset()
    self.entries = collections.NewSyncMap()
end
