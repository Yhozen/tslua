local dirty = require("tslua.project.dirty")

-- mapEntry fields: key, original, value, dirty, delete. Its methods are shared by MapEntry
-- and SyncMapEntry (embedded struct).
local mapEntry = {}
mapEntry.__index = mapEntry
dirty.mapEntry = mapEntry

function mapEntry:Key()
    return self.key
end

function mapEntry:Original()
    return self.original
end

function mapEntry:Value()
    if self.delete then
        return nil
    end
    return self.value
end

function mapEntry:Dirty()
    return self.dirty
end
