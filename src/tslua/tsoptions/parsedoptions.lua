local tsoptions = require("tslua.tsoptions")

-- ParsedOptions: { compilerOptions, watchOptions, typeAcquisition, fileNames, projectReferences, contentMappers }
local ParsedOptions = {}
ParsedOptions.__index = ParsedOptions
tsoptions.ParsedOptions = ParsedOptions

function tsoptions.NewParsedOptions(init)
    local o = setmetatable({
        compilerOptions = nil,
        watchOptions = nil,
        typeAcquisition = nil,
        fileNames = nil,
        projectReferences = nil,
        contentMappers = nil,
    }, ParsedOptions)
    if init ~= nil then
        for k, v in pairs(init) do
            o[k] = v
        end
    end
    return o
end

-- Go `*p` copy of the struct.
function ParsedOptions:copy()
    return tsoptions.NewParsedOptions(self)
end
