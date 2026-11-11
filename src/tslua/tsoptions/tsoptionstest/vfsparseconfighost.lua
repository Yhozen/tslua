local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

function tsoptionstest.fixRoot(path)
    local rootLength = tspath.GetRootLength(path)
    if rootLength == 0 then
        return path
    end
    if #path == rootLength then
        return "."
    end
    return string.sub(path, rootLength + 1)
end

-- VfsParseConfigHost implements tsoptions.ParseConfigHost: { vfs = vfs.FS, currentDirectory = "" }
local VfsParseConfigHost = {}
VfsParseConfigHost.__index = VfsParseConfigHost
tsoptionstest.VfsParseConfigHost = VfsParseConfigHost

function VfsParseConfigHost:FS()
    return self.vfs
end

function VfsParseConfigHost:GetCurrentDirectory()
    return self.currentDirectory
end

function tsoptionstest.NewVFSParseConfigHost(files, currentDirectory, useCaseSensitiveFileNames)
    return setmetatable({
        vfs = vfstest.FromMap(files, useCaseSensitiveFileNames),
        currentDirectory = currentDirectory,
    }, VfsParseConfigHost)
end

-- NewVFSParseConfigHostWithSymlinks builds a parse-config host whose vfs also contains the given symlinks
-- (link path -> target path), so config parsing resolves packages through symlinks as it would on disk.
function tsoptionstest.NewVFSParseConfigHostWithSymlinks(files, symlinks, currentDirectory, useCaseSensitiveFileNames)
    if symlinks == nil or next(symlinks) == nil then
        return tsoptionstest.NewVFSParseConfigHost(files, currentDirectory, useCaseSensitiveFileNames)
    end
    local entries = {}
    for name, content in pairs(files) do
        entries[name] = content
    end
    for link, target in pairs(symlinks) do
        entries[tspath.GetNormalizedAbsolutePath(link, currentDirectory)] = vfstest.Symlink(tspath.GetNormalizedAbsolutePath(target, currentDirectory))
    end
    return setmetatable({
        vfs = vfstest.FromMap(entries, useCaseSensitiveFileNames),
        currentDirectory = currentDirectory,
    }, VfsParseConfigHost)
end

return tsoptionstest
