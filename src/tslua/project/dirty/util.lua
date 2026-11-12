local dirty = require("tslua.project.dirty")

function dirty.CloneMapIfNil(dirty_, original, getMap)
    local dirtyMap = getMap(dirty_)
    if dirtyMap == nil then
        if original == nil then
            return {}
        end
        local originalMap = getMap(original)
        if originalMap == nil then
            return {}
        end
        local clone = {}
        for k, v in pairs(originalMap) do
            clone[k] = v
        end
        return clone
    end
    return dirtyMap
end
