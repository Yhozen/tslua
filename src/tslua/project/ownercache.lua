local project = require("tslua.project")
local collections = require("tslua.collections")

-- ownerCacheEntry: { value, owners = set of owner ids }

-- OwnerCache is like RefCountCache, but each entry tracks the set of its
-- owners instead of a count. We use this to associate extended config cache
-- entries with each snapshot that contains them, since the same config can
-- be Acquired multiple times during config parsing while only appearing once in
-- the ParsedCommandLine's list of extended files. When updating this code, check
-- if the same changes should be made to RefCountCache as well.
local OwnerCache = {}
OwnerCache.__index = OwnerCache
project.OwnerCache = OwnerCache

function project.NewOwnerCache(parse, isExpired)
    return setmetatable({
        entries = collections.NewSyncMap(),
        isExpired = isExpired,
        parse = parse,
    }, OwnerCache)
end

function OwnerCache:LoadAndAcquire(identity, owner, loadArgs)
    local entry, loaded = self:loadOrStoreLockedEntry(identity)
    if not loaded or self.isExpired ~= nil and self.isExpired(identity, entry.value, loadArgs) then
        entry.value = self.parse(identity, loadArgs)
    end
    entry.owners[owner] = true
    return entry.value
end

function OwnerCache:Acquire(identity, owner, value)
    local entry, loaded = self:loadOrStoreLockedEntry(identity)
    if not loaded then
        entry.value = value
    end
    entry.owners[owner] = true
end

-- AddOwner adds an owner to an existing live entry. The entry must exist
-- and have at least one current owner; callers must ensure the entry is
-- kept alive (e.g. via snapshot ref counting).
function OwnerCache:AddOwner(identity, owner)
    local entry, ok = self.entries:Load(identity)
    if not ok then
        error("OwnerCache.AddOwner: entry not found", 0)
    end
    if next(entry.owners) == nil then
        error("OwnerCache.AddOwner: entry has no owners", 0)
    end
    entry.owners[owner] = true
end

function OwnerCache:Has(identity)
    local _, ok = self.entries:Load(identity)
    return ok
end

function OwnerCache:Release(identity, owner)
    local entry, ok = self.entries:Load(identity)
    if not ok then
        return
    end
    entry.owners[owner] = nil
    if next(entry.owners) == nil then
        self.entries:Delete(identity)
    end
end

-- loadOrStoreLockedEntry returns (entry, loaded).
function OwnerCache:loadOrStoreLockedEntry(key)
    local entry = { value = nil, owners = {} }
    local existing, loaded = self.entries:LoadOrStore(key, entry)
    if loaded then
        if next(existing.owners) == nil then
            -- An entry without owners is being deleted.
            self.entries:Delete(key)
            return self:loadOrStoreLockedEntry(key)
        end
        return existing, true
    end
    return entry, false
end
