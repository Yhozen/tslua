local project = require("tslua.project")
local collections = require("tslua.collections")

-- refCountCacheEntry: { value, refCount }

-- RefCountCacheOptions: { disableDeletion = bool }
-- DisableDeletion prevents entries from being removed from the cache.
-- Used for testing.
function project.NewRefCountCacheOptions(fields)
    return { disableDeletion = (fields ~= nil and fields.disableDeletion) or false }
end

-- Keys are compared by their cacheKey string when they are key structs (ParseCacheKey,
-- ContentMappedParseCacheKey), or directly otherwise.
local function keyOf(identity)
    if type(identity) == "table" and identity.cacheKey ~= nil then
        return identity.cacheKey
    end
    return identity
end

local RefCountCache = {}
RefCountCache.__index = RefCountCache
project.RefCountCache = RefCountCache

function project.NewRefCountCache(options, parse)
    return setmetatable({
        options = project.NewRefCountCacheOptions(options),
        entries = collections.NewSyncMap(),
        parse = parse,
    }, RefCountCache)
end

-- Acquire retrieves or creates a cache entry for the given identity and hash.
-- If an entry exists with matching identity and hash, its refcount is incremented
-- and the cached value is returned. Otherwise, parse() is called to create the
-- value, which is stored and returned with refcount 1.
--
-- The caller is responsible for calling Deref when done with the value.
function RefCountCache:Acquire(identity, acquireArgs)
    local entry, loaded = self:loadOrStoreNewLockedEntry(identity)
    if not loaded then
        -- New entry - parse the value
        entry.value = self.parse(identity, acquireArgs)
        return entry.value
    end
    return entry.value
end

function RefCountCache:Has(identity)
    local _, ok = self.entries:Load(keyOf(identity))
    return ok
end

-- AcquireOrError retrieves an existing entry (incrementing its refcount) or produces a new one via
-- produce. If produce returns an error, no entry is stored and the error is returned, so callers can
-- cache only successful results.
--
-- The caller is responsible for calling Deref when a value is returned without error.
function RefCountCache:AcquireOrError(identity, produce)
    local entry, loaded = self:loadOrStoreNewLockedEntry(identity)
    if loaded then
        return entry.value, nil
    end
    local value, err = produce()
    if err ~= nil then
        -- Undo the speculative entry so failures are not cached.
        entry.refCount = 0
        self.entries:Delete(keyOf(identity))
        return value, err
    end
    entry.value = value
    return value, nil
end

-- Ref increments the reference count for an existing entry.
-- Panics if the entry does not exist.
function RefCountCache:Ref(identity)
    local entry, ok = self.entries:Load(keyOf(identity))
    if not ok then
        error("cache entry not found", 0)
    end
    if entry.refCount <= 0 and not self.options.disableDeletion then
        -- Entry was deleted while we were acquiring the lock
        local newEntry = self:loadOrStoreNewLockedEntry(identity)
        newEntry.value = entry.value
        return
    end
    entry.refCount = entry.refCount + 1
end

-- Deref decrements the reference count for an entry.
-- When the refcount reaches zero, the entry is removed from the cache
-- (unless DisableDeletion is set).
function RefCountCache:Deref(identity)
    local entry, ok = self.entries:Load(keyOf(identity))
    if not ok then
        return
    end
    entry.refCount = entry.refCount - 1
    if entry.refCount <= 0 and not self.options.disableDeletion then
        self.entries:Delete(keyOf(identity))
    end
end

-- loadOrStoreNewLockedEntry loads an existing entry or creates a new one.
-- The returned entry's refCount is incremented (or initialized to 1 in the case of a new entry).
-- Returns (entry, loaded).
function RefCountCache:loadOrStoreNewLockedEntry(key)
    local entry = { value = nil, refCount = 1 }
    local existing, loaded = self.entries:LoadOrStore(keyOf(key), entry)
    if loaded then
        if existing.refCount <= 0 and not self.options.disableDeletion then
            -- Existing entry was deleted while we were acquiring the lock
            self.entries:Delete(keyOf(key))
            return self:loadOrStoreNewLockedEntry(key)
        end
        existing.refCount = existing.refCount + 1
        return existing, true
    end
    return entry, false
end
