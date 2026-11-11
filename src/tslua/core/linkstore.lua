local core = require("tslua.core")

-- Links store. newValue (optional) constructs the zero value of V (default: an empty table);
-- callers whose V has numeric/bool/string fields must pass a constructor that initializes them.
local LinkStore = {}
LinkStore.__index = LinkStore
core.LinkStore = LinkStore

function core.NewLinkStore(newValue)
    return setmetatable({ entries = nil, newValue = newValue }, LinkStore)
end

function LinkStore:Get(key)
    local entries = self.entries
    local value = entries and entries[key]
    if value ~= nil then
        return value
    end
    if entries == nil then
        entries = {}
        self.entries = entries
    end
    if self.newValue ~= nil then
        value = self.newValue()
    else
        value = {}
    end
    entries[key] = value
    return value
end

function LinkStore:Has(key)
    return self.entries ~= nil and self.entries[key] ~= nil
end

function LinkStore:TryGet(key)
    if self.entries == nil then
        return nil
    end
    return self.entries[key]
end

core.pageShift = 8
core.pageSize = 1 << core.pageShift
core.pageMask = core.pageSize - 1
core.maxPageCount = 65536

-- Implements a sparse-array-like structure for storing elements keyed by dense uint64 keys. Elements are
-- stored in fixed-size pages of 256 entries. In Lua a page is a table created on demand; entries in an
-- existing page are created (zero-valued via newValue) on first access, matching Go's semantics where
-- TryGet returns a pointer to a zero element once its page exists.
local PagedLinkStore = {}
PagedLinkStore.__index = PagedLinkStore
core.PagedLinkStore = PagedLinkStore

function core.NewPagedLinkStore(newValue)
    return setmetatable({ pages = {}, newValue = newValue }, PagedLinkStore)
end

function PagedLinkStore:newEntry()
    if self.newValue ~= nil then
        return self.newValue()
    end
    return {}
end

function PagedLinkStore:Get(key)
    local pageIndex = key >> core.pageShift
    local page = self.pages[pageIndex]
    if page == nil then
        page = {}
        self.pages[pageIndex] = page
    end
    local index = key & core.pageMask
    local value = page[index]
    if value == nil then
        value = self:newEntry()
        page[index] = value
    end
    return value
end

function PagedLinkStore:Has(key)
    return self:TryGet(key) ~= nil
end

function PagedLinkStore:TryGet(key)
    local page = self.pages[key >> core.pageShift]
    if page ~= nil then
        local index = key & core.pageMask
        local value = page[index]
        if value == nil then
            value = self:newEntry()
            page[index] = value
        end
        return value
    end
    return nil
end
