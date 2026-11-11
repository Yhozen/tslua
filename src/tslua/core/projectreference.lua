local core = require("tslua.core")
local tspath = require("tslua.tspath")

-- ProjectReference: { path = string, originalPath = string, circular = bool }
-- path is a normalized path on disk; originalPath is the path as it was originally written;
-- circular indicates that this reference is intended to form a circularity.
local ProjectReference = {}
ProjectReference.__index = ProjectReference
core.ProjectReference = ProjectReference

function core.NewProjectReference(init)
    local ref = setmetatable({ path = "", originalPath = "", circular = false }, ProjectReference)
    if init ~= nil then
        for k, v in pairs(init) do
            ref[k] = v
        end
    end
    return ref
end

function core.ResolveProjectReferencePath(ref)
    return core.ResolveConfigFileNameOfProjectReference(ref.path)
end

function core.ResolveConfigFileNameOfProjectReference(path)
    if tspath.FileExtensionIs(path, tspath.ExtensionJson) then
        return path
    end
    return tspath.CombinePaths(path, "tsconfig.json")
end
