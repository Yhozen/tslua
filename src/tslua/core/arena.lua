local core = require("tslua.core")

-- Arena allocator. In Lua an arena just creates fresh values: New() returns a new table built by
-- the optional newValue constructor (default: an empty table). Zero value: core.NewArena().
local Arena = {}
Arena.__index = Arena
core.Arena = Arena

function core.NewArena(newValue)
    return setmetatable({ newValue = newValue }, Arena)
end

-- Allocate a single element in the arena and return a pointer to the element.
function Arena:New()
    if self.newValue ~= nil then
        return self.newValue()
    end
    return {}
end

-- Allocate a slice of the given size. Elements are filled with newValue() when a constructor was
-- given; otherwise the slice is an empty array for the caller to fill (Lua arrays have no nil slots).
function Arena:NewSlice(size)
    if size == 0 then
        return nil
    end
    local slice = {}
    if self.newValue ~= nil then
        for i = 1, size do
            slice[i] = self.newValue()
        end
    end
    return slice
end

function Arena:NewSlice1(t)
    return { t }
end

function Arena:Clone(t)
    if t == nil or #t == 0 then
        return nil
    end
    local slice = {}
    for i = 1, #t do
        slice[i] = t[i]
    end
    return slice
end

function core.nextArenaSize(size)
    size = math.max(size, 1)
    size = math.min(size * 2, 256)
    return size
end
