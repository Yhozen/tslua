local tspath = require("tslua.tspath")

local ExtensionTs = tspath.ExtensionTs
local ExtensionTsx = tspath.ExtensionTsx
local ExtensionDts = tspath.ExtensionDts
local ExtensionJs = tspath.ExtensionJs
local ExtensionJsx = tspath.ExtensionJsx
local ExtensionJson = tspath.ExtensionJson
local ExtensionMjs = tspath.ExtensionMjs
local ExtensionMts = tspath.ExtensionMts
local ExtensionDmts = tspath.ExtensionDmts
local ExtensionCjs = tspath.ExtensionCjs
local ExtensionCts = tspath.ExtensionCts
local ExtensionDcts = tspath.ExtensionDcts

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

tspath.SupportedDeclarationExtensions = { ExtensionDts, ExtensionDcts, ExtensionDmts }
tspath.SupportedTSImplementationExtensions = { ExtensionTs, ExtensionTsx, ExtensionMts, ExtensionCts }
tspath.supportedTSExtensionsForExtractExtension = { ExtensionDts, ExtensionDcts, ExtensionDmts, ExtensionTs, ExtensionTsx, ExtensionMts, ExtensionCts }
tspath.AllSupportedExtensions = { { ExtensionTs, ExtensionTsx, ExtensionDts, ExtensionJs, ExtensionJsx }, { ExtensionCts, ExtensionDcts, ExtensionCjs }, { ExtensionMts, ExtensionDmts, ExtensionMjs } }
tspath.SupportedTSExtensions = { { ExtensionTs, ExtensionTsx, ExtensionDts }, { ExtensionCts, ExtensionDcts }, { ExtensionMts, ExtensionDmts } }
tspath.SupportedTSExtensionsFlat = { ExtensionTs, ExtensionTsx, ExtensionDts, ExtensionCts, ExtensionDcts, ExtensionMts, ExtensionDmts }
tspath.SupportedJSExtensions = { { ExtensionJs, ExtensionJsx }, { ExtensionMjs }, { ExtensionCjs } }
tspath.SupportedJSExtensionsFlat = { ExtensionJs, ExtensionJsx, ExtensionMjs, ExtensionCjs }
tspath.AllSupportedExtensionsWithJson = { tspath.AllSupportedExtensions[1], tspath.AllSupportedExtensions[2], tspath.AllSupportedExtensions[3], { ExtensionJson } }
tspath.SupportedTSExtensionsWithJson = { tspath.SupportedTSExtensions[1], tspath.SupportedTSExtensions[2], tspath.SupportedTSExtensions[3], { ExtensionJson } }
tspath.SupportedTSExtensionsWithJsonFlat = { ExtensionTs, ExtensionTsx, ExtensionDts, ExtensionCts, ExtensionDcts, ExtensionMts, ExtensionDmts, ExtensionJson }
tspath.ExtensionsNotSupportingExtensionlessResolution = { ExtensionMts, ExtensionDmts, ExtensionMjs, ExtensionCts, ExtensionDcts, ExtensionCjs }

function tspath.ExtensionIsTs(ext)
    return ext == ExtensionTs or ext == ExtensionTsx or ext == ExtensionDts or ext == ExtensionMts or ext == ExtensionDmts or ext == ExtensionCts or ext == ExtensionDcts or #ext >= 7 and string.sub(ext, 1, 3) == ".d." and string.sub(ext, -3) == ".ts"
end

tspath.extensionsToRemove = { ExtensionDts, ExtensionDmts, ExtensionDcts, ExtensionMjs, ExtensionMts, ExtensionCjs, ExtensionCts, ExtensionTs, ExtensionJs, ExtensionTsx, ExtensionJsx, ExtensionJson }

function tspath.RemoveFileExtension(path)
    -- Remove any known extension even if it has more than one dot
    for _, ext in ipairs(tspath.extensionsToRemove) do
        if hasSuffix(path, ext) then
            return string.sub(path, 1, #path - #ext)
        end
    end

    return path
end

function tspath.RemoveAnyFileExtension(path)
    local withoutExtension = tspath.RemoveFileExtension(path)
    if withoutExtension ~= path then
        return withoutExtension
    end
    local extension = tspath.GetAnyExtensionFromPath(path, nil, false)
    if extension ~= "" then
        return tspath.RemoveExtension(path, extension)
    end
    return path
end

function tspath.TryGetExtensionFromPath(p)
    for _, ext in ipairs(tspath.extensionsToRemove) do
        if tspath.FileExtensionIs(p, ext) then
            return ext
        end
    end
    return ""
end

function tspath.RemoveExtension(path, extension)
    return string.sub(path, 1, #path - #extension)
end

function tspath.FileExtensionIsOneOf(path, extensions)
    if extensions == nil then
        return false
    end
    for _, ext in ipairs(extensions) do
        if tspath.FileExtensionIs(path, ext) then
            return true
        end
    end
    return false
end

function tspath.TryExtractTSExtension(fileName)
    for _, ext in ipairs(tspath.supportedTSExtensionsForExtractExtension) do
        if tspath.FileExtensionIs(fileName, ext) then
            return ext
        end
    end
    return ""
end

function tspath.HasTSFileExtension(path)
    return tspath.FileExtensionIsOneOf(path, tspath.SupportedTSExtensionsFlat)
end

function tspath.HasImplementationTSFileExtension(path)
    return tspath.FileExtensionIsOneOf(path, tspath.SupportedTSImplementationExtensions) and not tspath.IsDeclarationFileName(path)
end

function tspath.HasJSFileExtension(path)
    return tspath.FileExtensionIsOneOf(path, tspath.SupportedJSExtensionsFlat)
end

function tspath.HasJSONFileExtension(path)
    return tspath.FileExtensionIs(path, ExtensionJson)
end

function tspath.IsDeclarationFileName(fileName)
    return tspath.GetDeclarationFileExtension(fileName) ~= ""
end

function tspath.ExtensionIsOneOf(ext, extensions)
    if extensions == nil then
        return false
    end
    for _, e in ipairs(extensions) do
        if e == ext then
            return true
        end
    end
    return false
end

function tspath.GetDeclarationFileExtension(fileName)
    local base = tspath.GetBaseFileName(fileName)
    for _, ext in ipairs(tspath.SupportedDeclarationExtensions) do
        if hasSuffix(base, ext) then
            return ext
        end
    end
    if hasSuffix(base, ExtensionTs) then
        local index = string.find(base, ".d.", 1, true)
        if index ~= nil then
            return string.sub(base, index)
        end
    end
    return ""
end

function tspath.GetDeclarationEmitExtensionForPath(path)
    if tspath.FileExtensionIsOneOf(path, { ExtensionMjs, ExtensionMts }) then
        return ExtensionDmts
    elseif tspath.FileExtensionIsOneOf(path, { ExtensionCjs, ExtensionCts }) then
        return ExtensionDcts
    elseif tspath.FileExtensionIsOneOf(path, { ExtensionTs, ExtensionTsx, ExtensionJs, ExtensionJsx }) then
        return ExtensionDts
    else
        local ext = tspath.GetAnyExtensionFromPath(path, nil, false)
        if ext ~= "" then
            return ".d" .. ext .. ".ts"
        end
        return ExtensionDts
    end
end

-- ChangeAnyExtension changes the extension of a path to the provided extension if it has one of the provided extensions.
--
-- ChangeAnyExtension("/path/to/file.ext", ".js", ".ext") === "/path/to/file.js"
-- ChangeAnyExtension("/path/to/file.ext", ".js", ".ts") === "/path/to/file.ext"
-- ChangeAnyExtension("/path/to/file.ext", ".js", [".ext", ".ts"]) === "/path/to/file.js"
function tspath.ChangeAnyExtension(path, ext, extensions, ignoreCase)
    local pathext = tspath.GetAnyExtensionFromPath(path, extensions, ignoreCase)
    if pathext ~= "" then
        local result = string.sub(path, 1, #path - #pathext)
        if ext == "" then
            return result
        end
        if hasPrefix(ext, ".") then
            return result .. ext
        end
        return result .. "." .. ext
    end
    return path
end

function tspath.ChangeExtension(path, newExtension)
    return tspath.ChangeAnyExtension(path, newExtension, tspath.extensionsToRemove, false --[[ignoreCase]])
end

-- Like `changeAnyExtension`, but declaration file extensions are recognized
-- and replaced starting from the `.d`.
--
--	changeAnyExtension("file.d.ts", ".js") === "file.d.js"
--	changeFullExtension("file.d.ts", ".js") === "file.js"
function tspath.ChangeFullExtension(path, newExtension)
    local declarationExtension = tspath.GetDeclarationFileExtension(path)
    if declarationExtension ~= "" then
        local ext = newExtension
        if not hasPrefix(ext, ".") then
            ext = "." .. ext
        end
        return string.sub(path, 1, #path - #declarationExtension) .. ext
    end
    return tspath.ChangeExtension(path, newExtension)
end

function tspath.GetPossibleOriginalInputExtensionForExtension(path)
    if tspath.FileExtensionIsOneOf(path, { ExtensionDmts, ExtensionMjs, ExtensionMts }) then
        return { ExtensionMts, ExtensionMjs }
    end
    if tspath.FileExtensionIsOneOf(path, { ExtensionDcts, ExtensionCjs, ExtensionCts }) then
        return { ExtensionCts, ExtensionCjs }
    end
    -- Handle any custom .d.x.ts extension (e.g., .d.json.ts -> .json, .d.css.ts -> .css)
    local ext = tspath.GetDeclarationFileExtension(path)
    if ext ~= "" and ext ~= ExtensionDts then
        local inner = string.sub(ext, #".d." + 1, #ext - #".ts")
        return { "." .. inner }
    end
    return { ExtensionTsx, ExtensionTs, ExtensionJsx, ExtensionJs }
end
