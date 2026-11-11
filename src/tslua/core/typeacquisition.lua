local core = require("tslua.core")

local Tristate = core.Tristate

local TypeAcquisition = {}
TypeAcquisition.__index = TypeAcquisition
core.TypeAcquisition = TypeAcquisition

-- include/exclude are nil-able string arrays.
function core.NewTypeAcquisition(init)
    local ta = setmetatable({
        enable = Tristate.TSUnknown,
        include = nil,
        exclude = nil,
        disableFilenameBasedTypeAcquisition = Tristate.TSUnknown,
    }, TypeAcquisition)
    if init ~= nil then
        for k, v in pairs(init) do
            ta[k] = v
        end
    end
    return ta
end

local function slicesEqual(a, b)
    local na, nb = core.Len(a), core.Len(b)
    if na ~= nb then
        return false
    end
    for i = 1, na do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Go method on a possibly-nil pointer: call as core.TypeAcquisition.Equals(ta, other).
function TypeAcquisition.Equals(ta, other)
    if ta == other then
        return true
    end
    if ta == nil or other == nil then
        return false
    end

    return (ta.enable == other.enable and
        slicesEqual(ta.include, other.include) and
        slicesEqual(ta.exclude, other.exclude) and
        ta.disableFilenameBasedTypeAcquisition == other.disableFilenameBasedTypeAcquisition)
end
