local dirty = require("tslua.project.dirty")

local MapEntry = setmetatable({}, { __index = dirty.mapEntry })
MapEntry.__index = MapEntry
dirty.MapEntry = MapEntry

local function newMapEntry(m, key, original, value, isDirty)
    return setmetatable({ m = m, key = key, original = original, value = value, dirty = isDirty, delete = false }, MapEntry)
end

function MapEntry:Change(apply)
    if self.delete then
        error("tried to change a deleted entry", 0)
    end
    if not self.dirty then
        self.value = self.value:Clone()
        self.dirty = true
        self.m.dirty[self.key] = self
    end
    apply(self.value)
end

function MapEntry:Replace(newValue)
    if self.delete then
        error("tried to change a deleted entry", 0)
    end
    if not self.dirty then
        self.dirty = true
        self.m.dirty[self.key] = self
    end
    self.value = newValue
end

function MapEntry:ChangeIf(cond, apply)
    if cond(self:Value()) then
        self:Change(apply)
        return true
    end
    return false
end

function MapEntry:Delete()
    if not self.dirty then
        self.m.dirty[self.key] = self
    end
    self.delete = true
end

function MapEntry:Locked(fn)
    fn(self)
end

-- Map: base (key -> value table, may be nil), dirty (key -> *MapEntry).
local Map = {}
Map.__index = Map
dirty.Map = Map

function dirty.NewMap(base)
    return setmetatable({ base = base, dirty = {} }, Map)
end

-- Get returns (entry, ok).
function Map:Get(key)
    local entry = self.dirty[key]
    if entry ~= nil then
        if entry.delete then
            return nil, false
        end
        return entry, true
    end
    local value = self.base ~= nil and self.base[key] or nil
    if value == nil then
        return nil, false
    end
    return newMapEntry(self, key, value, value, false), true
end

-- Add sets a new entry in the dirty map without checking if it exists
-- in the base map. The entry added is considered dirty, so it should
-- be a fresh value, mutable until finalized (i.e., it will not be cloned
-- before changing if a change is made). If modifying an entry that may
-- exist in the base map, use `Change` instead.
function Map:Add(key, value)
    self.dirty[key] = newMapEntry(self, key, nil, value, true)
end

function Map:Change(key, apply)
    local entry, ok = self:Get(key)
    if ok then
        entry:Change(apply)
    else
        error("tried to change a non-existent entry", 0)
    end
end

function Map:TryDelete(key)
    local entry, ok = self:Get(key)
    if ok then
        entry:Delete()
        return true
    end
    return false
end

function Map:Delete(key)
    if not self:TryDelete(key) then
        error("tried to delete a non-existent entry", 0)
    end
end

-- Range snapshots the maps before iterating, since fn may add dirty entries.
function Map:Range(fn)
    local seenInDirty = {}
    local dirtyEntries = {}
    for _, entry in pairs(self.dirty) do
        dirtyEntries[#dirtyEntries + 1] = entry
    end
    for _, entry in ipairs(dirtyEntries) do
        seenInDirty[entry.key] = true
        if not entry.delete and not fn(entry) then
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
            if not fn(newMapEntry(self, key, value, value, false)) then
                break
            end
            ::continue::
        end
    end
end

function Map:Clear()
    self.dirty = {}
    self.base = {}
end

-- Finalize returns (result, changed).
function Map:Finalize()
    if next(self.dirty) == nil then
        return self.base, false -- no changes, return base map
    end
    local result = {}
    if self.base ~= nil then
        for k, v in pairs(self.base) do
            result[k] = v
        end
    end
    for key, entry in pairs(self.dirty) do
        if entry.delete then
            result[key] = nil
        else
            result[key] = entry.value
        end
    end
    return result, true
end
