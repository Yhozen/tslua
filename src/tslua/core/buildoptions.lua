local core = require("tslua.core")
local json = require("tslua.json")

local Tristate = core.Tristate

local BuildOptions = {}
BuildOptions.__index = BuildOptions
core.BuildOptions = BuildOptions

-- builders is a nil-able integer (Go *int). CompilerOptions are not parsed here and will be
-- available on ParsedBuildCommandLine.
function core.NewBuildOptions(init)
    local o = setmetatable({
        dry = Tristate.TSUnknown,
        force = Tristate.TSUnknown,
        verbose = Tristate.TSUnknown,
        builders = nil,
        stopBuildOnErrors = Tristate.TSUnknown,
        -- Internal fields
        clean = Tristate.TSUnknown,
    }, BuildOptions)
    if init ~= nil then
        for k, v in pairs(init) do
            o[k] = v
        end
    end
    return o
end

-- Go encoding/json of the struct (all fields `json:",omitzero"`): members in field order, Tristate as
-- true/false, nil *int omitted. Returns (string, err).
function BuildOptions:MarshalJSON()
    local parts = {}
    for _, name in ipairs({ "dry", "force", "verbose", "builders", "stopBuildOnErrors", "clean" }) do
        local v = self[name]
        if name == "builders" then
            if v ~= nil then
                local raw, err = json.Marshal(v)
                if err ~= nil then
                    return nil, err
                end
                parts[#parts + 1] = json.QuoteString(name) .. ":" .. raw
            end
        elseif v ~= Tristate.TSUnknown then
            parts[#parts + 1] = json.QuoteString(name) .. ":" .. (core.Tristate_MarshalJSON(v))
        end
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end
