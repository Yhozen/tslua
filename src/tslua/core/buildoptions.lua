local core = require("tslua.core")

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
