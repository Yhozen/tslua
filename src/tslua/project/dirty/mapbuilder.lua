local dirty = require("tslua.project.dirty")

local MapBuilder = {}
MapBuilder.__index = MapBuilder
dirty.MapBuilder = MapBuilder

function dirty.NewMapBuilder(base, toBuilder, build)
    return setmetatable({
        base = base,
        dirty = {},
        deleted = nil,
        toBuilder = toBuilder,
        build = build,
    }, MapBuilder)
end

function MapBuilder:Set(key, value)
    self.dirty[key] = value
    if self.deleted ~= nil then
        self.deleted[key] = nil
    end
end

function MapBuilder:Delete(key)
    if self.deleted == nil then
        self.deleted = {}
    end
    self.deleted[key] = true
    self.dirty[key] = nil
end

function MapBuilder:Clear()
    self.dirty = {}
    self.deleted = {}
    if self.base ~= nil then
        for key in pairs(self.base) do
            self.deleted[key] = true
        end
    end
end

function MapBuilder:Has(key)
    if self.deleted ~= nil and self.deleted[key] then
        return false
    end
    if self.dirty[key] ~= nil then
        return true
    end
    return self.base ~= nil and self.base[key] ~= nil
end

function MapBuilder:Build()
    if next(self.dirty) == nil and (self.deleted == nil or next(self.deleted) == nil) then
        return self.base
    end
    local result = {}
    if self.base ~= nil then
        for k, v in pairs(self.base) do
            result[k] = v
        end
    end
    if self.deleted ~= nil then
        for key in pairs(self.deleted) do
            result[key] = nil
        end
    end
    for key, value in pairs(self.dirty) do
        result[key] = self.build(value)
    end
    return result
end
