local dirty = require("tslua.project.dirty")

-- CloneableMap is a Go map type with a Clone method. In Lua it is a plain key -> value table
-- whose metatable provides Clone; iterate it with pairs (keys never collide with "Clone"
-- since they are paths).
local CloneableMap = {}
CloneableMap.__index = CloneableMap
dirty.CloneableMap = CloneableMap

function dirty.NewCloneableMap(m)
    return setmetatable(m or {}, CloneableMap)
end

function CloneableMap:Clone()
    local clone = {}
    for k, v in pairs(self) do
        clone[k] = v
    end
    return setmetatable(clone, CloneableMap)
end
