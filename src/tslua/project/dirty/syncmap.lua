local dirty = require("tslua.project.dirty")
local collections = require("tslua.collections")

-- Locks are no-ops in the sequential port; the proxy logic is kept since two entries for the
-- same key can be loaded before either is changed.

local lockedEntry = {}
lockedEntry.__index = lockedEntry
dirty.lockedEntry = lockedEntry

function lockedEntry:Value()
    return self.e:valueLocked()
end

function lockedEntry:Original()
    return self.e.original
end

function lockedEntry:Dirty()
    return self.e.dirty
end

function lockedEntry:Change(apply)
    self.e:changeLocked(apply)
end

function lockedEntry:ChangeIf(cond, apply)
    if cond(self.e:valueLocked()) then
        self.e:changeLocked(apply)
        return true
    end
    return false
end

function lockedEntry:Delete()
    self.e:deleteLocked()
end

function lockedEntry:Locked(fn)
    fn(self)
end

-- SyncMapEntry: { m, key, original, value, dirty, delete, proxyFor }
-- proxyFor is set when this entry loses a race to become the dirty entry
-- for a value. Since two holders reference two entries that
-- may try to mutate the same underlying value, all mutations are routed
-- through the one that actually exists in the dirty map.
local SyncMapEntry = setmetatable({}, { __index = dirty.mapEntry })
SyncMapEntry.__index = SyncMapEntry
dirty.SyncMapEntry = SyncMapEntry

local function newSyncMapEntry(m, key, original, value, isDirty, isDelete)
    return setmetatable({
        m = m,
        key = key,
        original = original,
        value = value,
        dirty = isDirty,
        delete = isDelete,
        proxyFor = nil,
    }, SyncMapEntry)
end

function SyncMapEntry:Value()
    if self.proxyFor ~= nil then
        return self.proxyFor:Value()
    end
    return self:valueLocked()
end

function SyncMapEntry:valueLocked()
    if self.delete then
        return nil
    end
    return self.value
end

function SyncMapEntry:Dirty()
    if self.proxyFor ~= nil then
        return self.proxyFor:Dirty()
    end
    return self.dirty
end

function SyncMapEntry:Locked(fn)
    if self.proxyFor ~= nil then
        self.proxyFor:Locked(fn)
        return
    end
    fn(setmetatable({ e = self }, lockedEntry))
end

function SyncMapEntry:Change(apply)
    if self.proxyFor ~= nil then
        self.proxyFor:Change(apply)
        return
    end
    self:changeLocked(apply)
end

function SyncMapEntry:changeLocked(apply)
    if self.dirty then
        apply(self.value)
        return
    end
    local entry, loaded = self.m.dirty:LoadOrStore(self.key, self)
    if not entry.dirty then
        entry.value = entry.value:Clone()
        entry.dirty = true
    end
    if loaded then
        self.proxyFor = entry
        self.value = entry.value
        self.dirty = true
        self.delete = entry.delete
    end
    apply(entry.value)
end

function SyncMapEntry:ChangeIf(cond, apply)
    if self.proxyFor ~= nil then
        return self.proxyFor:ChangeIf(cond, apply)
    end
    if cond(self.value) then
        self:changeLocked(apply)
        return true
    end
    return false
end

function SyncMapEntry:Delete()
    if self.proxyFor ~= nil then
        self.proxyFor:Delete()
        return
    end
    if self.dirty then
        self.delete = true
        return
    end
    local entry, loaded = self.m.dirty:LoadOrStore(self.key, self)
    if loaded then
        self.delete = true
    else
        entry.delete = true
    end
end

function SyncMapEntry:deleteLocked()
    if self.dirty then
        self.delete = true
        return
    end
    local entry, loaded = self.m.dirty:LoadOrStore(self.key, self)
    if loaded then
        self.proxyFor = entry
        self.value = entry.value
        self.delete = true
        self.dirty = entry.dirty
    end
    entry.delete = true
end

function SyncMapEntry:DeleteIf(cond)
    if self.proxyFor ~= nil then
        self.proxyFor:DeleteIf(cond)
        return
    end
    if cond(self.value) then
        self:deleteLocked()
    end
end

-- SyncMap: base (key -> value table, may be nil), dirty (collections.SyncMap key -> *SyncMapEntry).
local SyncMap = {}
SyncMap.__index = SyncMap
dirty.SyncMap = SyncMap

function dirty.NewSyncMap(base)
    return setmetatable({ base = base, dirty = collections.NewSyncMap() }, SyncMap)
end

local function baseValue(m, key)
    if m.base == nil then
        return nil
    end
    return m.base[key]
end

-- Load returns (entry, ok).
function SyncMap:Load(key)
    local entry, ok = self.dirty:Load(key)
    if ok then
        if entry.delete then
            return nil, false
        end
        return entry, true
    end
    local val = baseValue(self, key)
    if val ~= nil then
        return newSyncMapEntry(self, key, val, val, false, false), true
    end
    return nil, false
end

-- LoadOrStore returns (entry, loaded).
function SyncMap:LoadOrStore(key, value)
    -- Check for existence in the base map first so the sync map access is atomic.
    local base = baseValue(self, key)
    if base ~= nil then
        local d, ok = self.dirty:Load(key)
        if ok then
            if d.delete then
                return nil, false
            end
            return d, true
        end
        return newSyncMapEntry(self, key, base, base, false, false), true
    end
    local entry, loaded = self.dirty:LoadOrStore(key, newSyncMapEntry(self, key, nil, value, true, false))
    if loaded then
        if entry.delete then
            return nil, false
        end
    end
    return entry, loaded
end

function SyncMap:Delete(key)
    local entry, loaded = self.dirty:LoadOrStore(key, newSyncMapEntry(self, key, baseValue(self, key), nil, false, true))
    if loaded then
        entry:Delete()
    end
end

local function dirtyEntries(m)
    local keys, entries = {}, {}
    m.dirty:Range(function(key, entry)
        keys[#keys + 1] = key
        entries[#entries + 1] = entry
        return true
    end)
    return keys, entries
end

-- Range snapshots the maps before iterating, since fn may add dirty entries.
function SyncMap:Range(fn)
    local seenInDirty = {}
    local keys, entries = dirtyEntries(self)
    for i, key in ipairs(keys) do
        local entry = entries[i]
        seenInDirty[key] = true
        local deleted = entry.delete
        if not deleted and not fn(entry) then
            break
        end
    end
    if self.base ~= nil then
        local baseKeys = {}
        for key in pairs(self.base) do
            baseKeys[#baseKeys + 1] = key
        end
        for _, key in ipairs(baseKeys) do
            if seenInDirty[key] then
                goto continue -- already processed in dirty entries
            end
            local value = self.base[key]
            if not fn(newSyncMapEntry(self, key, value, value, false, false)) then
                break
            end
            ::continue::
        end
    end
end

-- FinalizationHooks: { onDelete = func(key, value), onChange = func(key, oldValue, newValue), onAdd = func(key, value) }

function SyncMap:finalize(hooks)
    local changed = false
    local result = self.base
    local function ensureCloned()
        if not changed then
            local clone = {}
            if self.base ~= nil then
                for k, v in pairs(self.base) do
                    clone[k] = v
                end
            end
            result = clone
            changed = true
        end
    end
    local keys, entries = dirtyEntries(self)
    for i, key in ipairs(keys) do
        local entry = entries[i]
        if entry.delete then
            ensureCloned()
            if hooks.onDelete ~= nil then
                hooks.onDelete(key, entry.value)
            end
            result[key] = nil
        elseif entry.dirty then
            ensureCloned()
            if hooks.onChange ~= nil or hooks.onAdd ~= nil then
                if baseValue(self, key) ~= nil then
                    if hooks.onChange ~= nil then
                        hooks.onChange(key, entry.original, entry.value)
                    end
                elseif hooks.onAdd ~= nil then
                    hooks.onAdd(key, entry.value)
                end
            end
            result[key] = entry.value
        end
    end
    return result, changed
end

-- Finalize returns (map, changed).
function SyncMap:Finalize()
    return self:finalize({})
end

function SyncMap:FinalizeWith(hooks)
    return self:finalize(hooks)
end
