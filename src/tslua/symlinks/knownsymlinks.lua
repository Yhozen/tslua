local symlinks = require("tslua.symlinks")
local collections = require("tslua.collections")
local tspath = require("tslua.tspath")

-- KnownDirectoryLink: {
--   real: Matches the casing returned by `realpath`. Used to compute the `realpath` of children.
--         Always has trailing directory separator
--   realPath: toPath(real). Stored to avoid repeated recomputation.
--         Always has trailing directory separator
-- }
function symlinks.NewKnownDirectoryLink(real, realPath)
    return { real = real or "", realPath = realPath or "" }
end

local KnownSymlinks = {}
KnownSymlinks.__index = KnownSymlinks
symlinks.KnownSymlinks = KnownSymlinks

function KnownSymlinks:HasDirectory(symlinkPath)
    local _, ok = self.directories:Load(tspath.Path_EnsureTrailingDirectorySeparator(symlinkPath))
    return ok
end

-- Gets a map from symlink to realpath. Keys have trailing directory separators.
function KnownSymlinks:Directories()
    return self.directories
end

function KnownSymlinks:DirectoriesByRealpath()
    return self.directoriesByRealpath
end

-- Gets a map from symlink to realpath
function KnownSymlinks:Files()
    return self.files
end

-- Gets a map from realpath to symlinks
function KnownSymlinks:FilesByRealpath()
    return self.filesByRealpath
end

function KnownSymlinks:SetDirectory(symlink, symlinkPath, realDirectory)
    if realDirectory ~= nil then
        local _, ok = self.directories:Load(symlinkPath)
        if not ok then
            local set = self.directoriesByRealpath:LoadOrStore(realDirectory.realPath, collections.NewSyncSet())
            set:Add(symlink)
        end
    end
    self.directories:Store(symlinkPath, realDirectory)
end

function KnownSymlinks:SetFile(symlink, symlinkPath, realpath)
    local _, ok = self.files:Load(symlinkPath)
    if not ok then
        local realpathPath = tspath.ToPath(realpath, self.cwd, self.useCaseSensitiveFileNames)
        local set = self.filesByRealpath:LoadOrStore(realpathPath, collections.NewSyncSet())
        set:Add(symlink)
    end
    self.files:Store(symlinkPath, realpath)
end

function symlinks.NewKnownSymlink(currentDirectory, useCaseSensitiveFileNames)
    return setmetatable({
        directories = collections.NewSyncMap(),
        directoriesByRealpath = collections.NewSyncMap(),
        files = collections.NewSyncMap(),
        filesByRealpath = collections.NewSyncMap(),
        cwd = currentDirectory,
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
    }, KnownSymlinks)
end

function KnownSymlinks:SetSymlinksFromResolutions(
    forEachResolvedModule,
    forEachResolvedTypeReferenceDirective
)
    forEachResolvedModule(function(resolution, moduleName, mode, filePath)
        self:ProcessResolution(resolution.originalPath, resolution.resolvedFileName)
    end, nil)
    forEachResolvedTypeReferenceDirective(function(resolution, moduleName, mode, filePath)
        self:ProcessResolution(resolution.originalPath, resolution.resolvedFileName)
    end, nil)
end

function KnownSymlinks:ProcessResolution(originalPath, resolvedFileName)
    if originalPath == "" or resolvedFileName == "" then
        return
    end
    self:SetFile(originalPath, tspath.ToPath(originalPath, self.cwd, self.useCaseSensitiveFileNames), resolvedFileName)
    local commonResolved, commonOriginal = self:guessDirectorySymlink(resolvedFileName, originalPath, self.cwd)
    if commonResolved ~= "" and commonOriginal ~= "" then
        local symlinkPath = tspath.ToPath(commonOriginal, self.cwd, self.useCaseSensitiveFileNames)
        if not tspath.ContainsIgnoredPath(symlinkPath) then
            self:SetDirectory(
                commonOriginal,
                tspath.Path_EnsureTrailingDirectorySeparator(symlinkPath),
                symlinks.NewKnownDirectoryLink(
                    tspath.EnsureTrailingDirectorySeparator(commonResolved),
                    tspath.Path_EnsureTrailingDirectorySeparator(tspath.ToPath(commonResolved, self.cwd, self.useCaseSensitiveFileNames))
                )
            )
        end
    end
end

-- Returns commonResolved, commonOriginal.
function KnownSymlinks:guessDirectorySymlink(a, b, cwd)
    local aParts = tspath.GetPathComponents(tspath.GetNormalizedAbsolutePath(a, cwd), "")
    local bParts = tspath.GetPathComponents(tspath.GetNormalizedAbsolutePath(b, cwd), "")
    local isDirectory = false
    while #aParts >= 2 and #bParts >= 2 and
        not self:isNodeModulesOrScopedPackageDirectory(aParts[#aParts - 1]) and
        not self:isNodeModulesOrScopedPackageDirectory(bParts[#bParts - 1]) and
        tspath.GetCanonicalFileName(aParts[#aParts], self.useCaseSensitiveFileNames) == tspath.GetCanonicalFileName(bParts[#bParts], self.useCaseSensitiveFileNames) do
        aParts[#aParts] = nil
        bParts[#bParts] = nil
        isDirectory = true
    end
    if isDirectory then
        return tspath.GetPathFromPathComponents(aParts), tspath.GetPathFromPathComponents(bParts)
    end
    return "", ""
end

function KnownSymlinks:isNodeModulesOrScopedPackageDirectory(s)
    return s ~= "" and (tspath.GetCanonicalFileName(s, self.useCaseSensitiveFileNames) == "node_modules" or string.sub(s, 1, 1) == "@")
end
