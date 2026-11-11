local tsc = require("tslua.execute.tsc")
local tsoptions = require("tslua.tsoptions")

-- ExtendedConfigCache is a minimal implementation of tsoptions.ExtendedConfigCache.
-- It stores cached entries permanently. This implementation should not be used for long-running
-- processes where configuration changes over the course of multiple compilations.
local ExtendedConfigCache = {}
ExtendedConfigCache.__index = ExtendedConfigCache
tsc.ExtendedConfigCache = ExtendedConfigCache

function tsc.NewExtendedConfigCache()
    return setmetatable({ m = {} }, ExtendedConfigCache)
end

-- GetExtendedConfig implements tsoptions.ExtendedConfigCache.
function ExtendedConfigCache:GetExtendedConfig(fileName, path, resolutionStack, host)
    local entry, loaded = self:loadOrStoreNewLockedEntry(path)
    if not loaded then
        entry.extendedConfigCacheEntry = tsoptions.ParseExtendedConfig(fileName, path, resolutionStack, host, self)
    end
    return entry.extendedConfigCacheEntry
end

-- loadOrStoreNewLockedEntry loads an existing entry or creates a new one.
function ExtendedConfigCache:loadOrStoreNewLockedEntry(path)
    local existing = self.m[path]
    if existing ~= nil then
        return existing, true
    end
    local entry = { extendedConfigCacheEntry = nil }
    self.m[path] = entry
    return entry, false
end
