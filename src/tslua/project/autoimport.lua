local project = require("tslua.project")
local collections = require("tslua.collections")
local ast = require("tslua.ast")
local tspath = require("tslua.tspath")
local packagejson = require("tslua.packagejson")

-- autoImportBuilderFS implements FileSource.
local autoImportBuilderFS = {}
autoImportBuilderFS.__index = autoImportBuilderFS
project.autoImportBuilderFS = autoImportBuilderFS

function project.newAutoImportBuilderFS(snapshotFSBuilder)
    return setmetatable({ snapshotFSBuilder = snapshotFSBuilder, untrackedFiles = collections.NewSyncMap() }, autoImportBuilderFS)
end

-- FS implements FileSource.
function autoImportBuilderFS:FS()
    return self.snapshotFSBuilder.fs
end

-- GetFile implements FileSource.
function autoImportBuilderFS:GetFile(fileName)
    local path = self.snapshotFSBuilder.toPath(fileName)
    return self:GetFileByPath(fileName, path)
end

-- GetFileByPath implements FileSource.
function autoImportBuilderFS:GetFileByPath(fileName, path)
    -- We want to avoid long-term caching of files referenced only by auto-imports, so we
    -- override GetFileByPath to avoid collecting more files into the snapshotFSBuilder's
    -- diskFiles. (Note the reason we can't just use the finalized SnapshotFS is that changed
    -- files not read during other parts of the snapshot clone will be marked as dirty, but
    -- not yet refreshed from disk.)
    local overlay = self.snapshotFSBuilder.overlays[path]
    if overlay ~= nil then
        return overlay
    end
    local diskFile, ok = self.snapshotFSBuilder.diskFiles:Load(path)
    if ok then
        return self.snapshotFSBuilder:reloadEntryIfNeeded(diskFile)
    end
    local fh
    fh, ok = self.untrackedFiles:Load(path)
    if ok then
        return fh
    end
    fh = nil
    local content
    content, ok = self.snapshotFSBuilder.fs:ReadFile(fileName)
    if ok then
        fh = project.newDiskFile(fileName, content)
    end
    fh = self.untrackedFiles:LoadOrStore(path, fh)
    return fh
end

function autoImportBuilderFS:GetAccessibleEntries(path)
    return self.snapshotFSBuilder:GetAccessibleEntries(path)
end

-- FileExists implements FileSource.
function autoImportBuilderFS:FileExists(fileName, path)
    return self.snapshotFSBuilder:FileExists(fileName, path)
end

-- autoImportRegistryCloneHost implements autoimport.RegistryCloneHost.
local autoImportRegistryCloneHost = {}
autoImportRegistryCloneHost.__index = autoImportRegistryCloneHost
project.autoImportRegistryCloneHost = autoImportRegistryCloneHost

function project.newAutoImportRegistryCloneHost(projectCollection, parseCache, snapshotFSBuilder, currentDirectory, toPath)
    return setmetatable({
        projectCollection = projectCollection,
        parseCache = parseCache,
        fs = project.newSourceFS(false, project.newAutoImportBuilderFS(snapshotFSBuilder), toPath),
        currentDirectory = currentDirectory,
        files = {},
    }, autoImportRegistryCloneHost)
end

-- FS implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:FS()
    return self.fs
end

-- GetCurrentDirectory implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:GetCurrentDirectory()
    return self.currentDirectory
end

-- GetDefaultProject implements autoimport.RegistryCloneHost. Returns (projectPath, program).
function autoImportRegistryCloneHost:GetDefaultProject(path)
    local p = self.projectCollection:GetDefaultProject(path)
    if p == nil then
        return "", nil
    end
    return p.configFilePath, p:GetProgram()
end

-- GetPackageJson implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:GetPackageJson(fileName)
    -- !!! ref-counted shared cache
    local fh = self.fs:GetFile(fileName)
    local packageDirectory = tspath.GetDirectoryPath(fileName)
    if fh == nil then
        return packagejson.NewInfoCacheEntry(packageDirectory, self.fs:DirectoryExists(packageDirectory), nil)
    end
    local fields, err = packagejson.Parse(fh:Content())
    if err ~= nil then
        return packagejson.NewInfoCacheEntry(tspath.GetDirectoryPath(fileName), true, packagejson.NewPackageJson(packagejson.NewFields(), false))
    end
    return packagejson.NewInfoCacheEntry(tspath.GetDirectoryPath(fileName), true, packagejson.NewPackageJson(fields, true))
end

-- GetProgramForProject implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:GetProgramForProject(projectPath)
    local p = self.projectCollection:GetProjectByPath(projectPath)
    if p == nil then
        return nil
    end
    return p:GetProgram()
end

-- GetSourceFile implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:GetSourceFile(fileName, path)
    local fh = self.fs:GetFile(fileName)
    if fh == nil then
        return nil
    end
    local opts = ast.NewSourceFileParseOptions(fileName, path)
    local key = project.NewParseCacheKey(opts, fh:Hash(), fh:Kind())
    local result = self.parseCache:Acquire(key, fh)

    self.files[#self.files + 1] = key

    return result
end

-- Dispose implements autoimport.RegistryCloneHost.
function autoImportRegistryCloneHost:Dispose()
    for _, key in ipairs(self.files) do
        self.parseCache:Deref(key)
    end
end
