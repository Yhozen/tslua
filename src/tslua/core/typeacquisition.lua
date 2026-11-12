local core = require("tslua.core")
local json = require("tslua.json")

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

-- Go encoding/json of the struct (all fields `json:",omitzero"`): members in field order, Tristate as
-- true/false, nil slices omitted. Returns (string, err).
function TypeAcquisition:MarshalJSON()
    local parts = {}
    local function add(name, raw)
        parts[#parts + 1] = json.QuoteString(name) .. ":" .. raw
    end
    if self.enable ~= Tristate.TSUnknown then
        add("enable", (core.Tristate_MarshalJSON(self.enable)))
    end
    for _, name in ipairs({ "include", "exclude" }) do
        if self[name] ~= nil then
            local raw, err = json.Marshal(self[name])
            if err ~= nil then
                return nil, err
            end
            add(name, raw)
        end
    end
    if self.disableFilenameBasedTypeAcquisition ~= Tristate.TSUnknown then
        add("disableFilenameBasedTypeAcquisition", (core.Tristate_MarshalJSON(self.disableFilenameBasedTypeAcquisition)))
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end
