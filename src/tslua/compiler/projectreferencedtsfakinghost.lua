local compiler = require("tslua.compiler")
local core = require("tslua.core")
local module = require("tslua.module")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate

-- projectReferenceDtsFakingHost implements module.ResolutionHost.
local projectReferenceDtsFakingHost = {}
projectReferenceDtsFakingHost.__index = projectReferenceDtsFakingHost
compiler.projectReferenceDtsFakingHost = projectReferenceDtsFakingHost

local projectReferenceDtsFakingVfs = {}
projectReferenceDtsFakingVfs.__index = projectReferenceDtsFakingVfs
compiler.projectReferenceDtsFakingVfs = projectReferenceDtsFakingVfs

function compiler.newProjectReferenceDtsFakingHost(loader)
    local symlinks = require("tslua.symlinks")
    -- Create a new host that will fake the dts files
    local fs = setmetatable({
        projectReferenceFileMapper = loader.projectReferenceFileMapper,
        dtsDirectories = loader.dtsDirectories,
        knownSymlinks = symlinks.NewKnownSymlink("", false),
    }, projectReferenceDtsFakingVfs)
    -- cachedvfs only memoizes lookups; when it is unavailable the uncached FS behaves identically.
    local ok, cachedvfs = pcall(require, "tslua.vfs.cachedvfs")
    if ok and cachedvfs ~= nil and cachedvfs.From ~= nil then
        fs = cachedvfs.From(fs)
    end
    local host = setmetatable({
        host = loader.opts.host,
        fs = fs,
    }, projectReferenceDtsFakingHost)
    return host
end

-- FS implements module.ResolutionHost.
function projectReferenceDtsFakingHost:FS()
    return self.fs
end

-- GetCurrentDirectory implements module.ResolutionHost.
function projectReferenceDtsFakingHost:GetCurrentDirectory()
    return self.host:GetCurrentDirectory()
end

local function hostFS(fs)
    return fs.projectReferenceFileMapper.opts.host:FS()
end

-- UseCaseSensitiveFileNames implements vfs.FS.
function projectReferenceDtsFakingVfs:UseCaseSensitiveFileNames()
    return hostFS(self):UseCaseSensitiveFileNames()
end

-- FileExists implements vfs.FS.
function projectReferenceDtsFakingVfs:FileExists(path)
    if hostFS(self):FileExists(path) then
        return true
    end
    if not tspath.IsDeclarationFileName(path) then
        return false
    end
    -- Project references go to source file instead of .d.ts file
    return self:fileOrDirectoryExistsUsingSource(path, true)
end

-- ReadFile implements vfs.FS.
function projectReferenceDtsFakingVfs:ReadFile(path)
    -- Dont need to override as we cannot mimick read file
    return hostFS(self):ReadFile(path)
end

-- WriteFile implements vfs.FS.
function projectReferenceDtsFakingVfs:WriteFile(path, data)
    error("should not be called by resolver", 0)
end

-- AppendFile implements vfs.FS.
function projectReferenceDtsFakingVfs:AppendFile(path, data)
    error("should not be called by resolver", 0)
end

-- Remove implements vfs.FS.
function projectReferenceDtsFakingVfs:Remove(path)
    error("should not be called by resolver", 0)
end

-- Chtimes implements vfs.FS.
function projectReferenceDtsFakingVfs:Chtimes(path, aTime, mTime)
    error("should not be called by resolver", 0)
end

-- DirectoryExists implements vfs.FS.
function projectReferenceDtsFakingVfs:DirectoryExists(path)
    if hostFS(self):DirectoryExists(path) then
        self:handleDirectoryCouldBeSymlink(path)
        return true
    end
    return self:fileOrDirectoryExistsUsingSource(path, false)
end

-- GetAccessibleEntries implements vfs.FS.
function projectReferenceDtsFakingVfs:GetAccessibleEntries(path)
    error("should not be called by resolver", 0)
end

-- Stat implements vfs.FS.
function projectReferenceDtsFakingVfs:Stat(path)
    error("should not be called by resolver", 0)
end

-- WalkDir implements vfs.FS.
function projectReferenceDtsFakingVfs:WalkDir(root, walkFn)
    error("should not be called by resolver", 0)
end

-- Realpath implements vfs.FS.
function projectReferenceDtsFakingVfs:Realpath(path)
    local result, ok = self.knownSymlinks:Files():Load(self:toPath(path))
    if ok then
        return result
    end
    return hostFS(self):Realpath(path)
end

function projectReferenceDtsFakingVfs:toPath(path)
    return tspath.ToPath(path, self.projectReferenceFileMapper.opts.host:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
end

function projectReferenceDtsFakingVfs:handleDirectoryCouldBeSymlink(directory)
    if tspath.ContainsIgnoredPath(directory) then
        return
    end

    -- Because we already watch node_modules, handle symlinks in there
    if not compiler.contains(directory, "/node_modules/") then
        return
    end

    local directoryPath = tspath.EnsureTrailingDirectorySeparator(self:toPath(directory))
    local _, ok = self.knownSymlinks:Directories():Load(directoryPath)
    if ok then
        return
    end

    local realDirectory = self:Realpath(directory)
    if realDirectory == directory then
        -- not symlinked
        return
    end
    local realPath = tspath.EnsureTrailingDirectorySeparator(self:toPath(realDirectory))
    if realPath == directoryPath then
        -- not symlinked
        return
    end
    -- symlinks.KnownDirectoryLink
    self.knownSymlinks:SetDirectory(directory, directoryPath, {
        real = tspath.EnsureTrailingDirectorySeparator(realDirectory),
        realPath = realPath,
    })
end

function projectReferenceDtsFakingVfs:fileOrDirectoryExistsUsingSource(fileOrDirectory, isFile)
    local fileOrDirectoryExistsUsingSource
    if isFile then
        fileOrDirectoryExistsUsingSource = function(p) return self:fileExistsIfProjectReferenceDts(p) end
    else
        fileOrDirectoryExistsUsingSource = function(p) return self:directoryExistsIfProjectReferenceDeclDir(p) end
    end
    -- Check current directory or file
    local result = fileOrDirectoryExistsUsingSource(fileOrDirectory)
    if result ~= Tristate.TSUnknown then
        return result == Tristate.TSTrue
    end

    local fileOrDirectoryPath = self:toPath(fileOrDirectory)
    if not compiler.contains(fileOrDirectoryPath, "/node_modules/") then
        return false
    end
    -- Check if the directory or file is a symlinked package
    local packageRoot = module.ParseNodeModuleFromPath(fileOrDirectory, true)
    if packageRoot ~= "" then
        self:handleDirectoryCouldBeSymlink(packageRoot)
    end
    local knownDirectoryLinks = self.knownSymlinks:Directories()
    if knownDirectoryLinks:Size() == 0 then
        return false
    end
    if isFile then
        local _, ok = self.knownSymlinks:Files():Load(fileOrDirectoryPath)
        if ok then
            return true
        end
    end

    -- If it contains node_modules check if its one of the symlinked path we know of
    local exists = false
    knownDirectoryLinks:Range(function(directoryPath, knownDirectoryLink)
        if not compiler.hasPrefix(fileOrDirectoryPath, directoryPath) then
            return true
        end
        local relative = string.sub(fileOrDirectoryPath, #directoryPath + 1)
        exists = core.Tristate_IsTrue(fileOrDirectoryExistsUsingSource(knownDirectoryLink.realPath .. relative))
        if exists then
            if isFile then
                -- Store the real path for the file
                local absolutePath = tspath.GetNormalizedAbsolutePath(fileOrDirectory, self.projectReferenceFileMapper.opts.host:GetCurrentDirectory())
                self.knownSymlinks:SetFile(
                    absolutePath,
                    fileOrDirectoryPath,
                    knownDirectoryLink.real .. string.sub(absolutePath, #directoryPath + 1)
                )
            end
            return false
        end
        return true
    end)
    return exists
end

function projectReferenceDtsFakingVfs:fileExistsIfProjectReferenceDts(file)
    local source = self.projectReferenceFileMapper:getProjectReferenceFromOutputDts(self:toPath(file))
    if source ~= nil then
        if hostFS(self):FileExists(source.source) then
            return Tristate.TSTrue
        end
        return Tristate.TSFalse
    end
    return Tristate.TSUnknown
end

function projectReferenceDtsFakingVfs:directoryExistsIfProjectReferenceDeclDir(dir)
    local dirPath = self:toPath(dir)
    local dirPathWithTrailingDirectorySeparator = dirPath .. "/"
    for _, declDirPath in ipairs(compiler.sortedKeys(self.dtsDirectories)) do
        if dirPath == declDirPath or
            -- Any parent directory of declaration dir
            compiler.hasPrefix(declDirPath, dirPathWithTrailingDirectorySeparator) or
            -- Any directory inside declaration dir
            compiler.hasPrefix(dirPath, declDirPath .. "/") then
            return Tristate.TSTrue
        end
    end
    return Tristate.TSUnknown
end
