local autoimport = require("tslua.ls.autoimport")
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local module = require("tslua.module")
local dirty = require("tslua.project.dirty")
local tspath = require("tslua.tspath")

local Set = collections.Set

autoimport.knownRecursiveSearchPackages = collections.NewSetFromItems(
    "@material-ui/core",
    "@material-ui/icons",
    "@sap/cds",
    "@testing-library/react-native",
    "ajv",
    "asap",
    "async",
    "aws-sdk",
    "braintree-web",
    "core-js",
    "core-js-pure",
    "crypto-js",
    "cypress-mochawesome-reporter",
    "dd-trace",
    "dumi",
    "dva",
    "egg-mock",
    "electron-log",
    "es-abstract",
    "es6-promise",
    "eslint-config-taro",
    "expo",
    "expo-router",
    "flow-remove-types",
    "gatsby",
    "glamor",
    "gluegun",
    "graphology-indices",
    "graphology-traversal",
    "graphology-utils",
    "jest-expo",
    "lodash",
    "lodash-es",
    "moment",
    "mz",
    "next",
    "pdfjs-dist",
    "protobufjs",
    "react-app-polyfill",
    "react-dev-utils",
    "react-devtools-inline",
    "recast",
    "semver",
    "stylelint-config-html",
    "umi",
    "web3-provider-engine",
    "webpack"
)

-- Unexported Go enum `newProgramStructure` (iota values; not emitted by the constants generator).
autoimport.newProgramStructure = {
    False = 0,
    SameFileNames = 1,
    DifferentFileNames = 2,
}
local newProgramStructure = autoimport.newProgramStructure

-- Go time.Now / time.Since, only used for log messages. Durations are formatted like Go's
-- time.Duration.String.
function autoimport.timeNow()
    return os.clock()
end

local function trimFraction(s)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    return s
end

function autoimport.durationString(seconds)
    local ns = math.floor(seconds * 1e9 + 0.5)
    if ns == 0 then
        return "0s"
    end
    if ns < 1000 then
        return string.format("%dns", ns)
    end
    if ns < 1000000 then
        return trimFraction(string.format("%.3f", ns / 1e3)) .. "µs"
    end
    if ns < 1000000000 then
        return trimFraction(string.format("%.6f", ns / 1e6)) .. "ms"
    end
    local totalSeconds = ns / 1e9
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds - hours * 3600) / 60)
    local secs = totalSeconds - hours * 3600 - minutes * 60
    local out = trimFraction(string.format("%.9f", secs)) .. "s"
    if hours > 0 then
        return string.format("%dh%dm", hours, minutes) .. out
    end
    if minutes > 0 then
        return string.format("%dm", minutes) .. out
    end
    return out
end

function autoimport.timeSince(start)
    return autoimport.durationString(os.clock() - start)
end

-- Go ctx.Err() != nil.
function autoimport.ctxErr(ctx)
    if ctx ~= nil and ctx.Err ~= nil then
        return ctx:Err()
    end
    return nil
end

-- Go (*LogTree).Fork is nil-receiver safe.
local function fork(logger, message)
    if logger == nil then
        return nil
    end
    return logger:Fork(message)
end

local function mapGet(m, k)
    if m == nil then
        return nil
    end
    return m[k]
end

local function mapLen(m)
    local n = 0
    for _ in pairs(m or {}) do
        n = n + 1
    end
    return n
end

local function setKeys(s)
    return autoimport.sortedKeys(Set.Keys(s))
end

-- bucketBuildPreferences holds user preferences that affect how a bucket is
-- built. When any of these change between builds, the bucket must be rebuilt.
-- Adding a new preference here automatically integrates it into the rebuild
-- checks via Equal.
-- Go value struct { fileExcludePatterns, autoImportEntrypointDirectorySearch }.
function autoimport.newBucketBuildPreferences(fileExcludePatterns, autoImportEntrypointDirectorySearch)
    return {
        fileExcludePatterns = fileExcludePatterns,
        autoImportEntrypointDirectorySearch = autoImportEntrypointDirectorySearch or core.Tristate.TSUnknown,
    }
end

function autoimport.bucketBuildPreferencesFromUserPreferences(prefs)
    return autoimport.newBucketBuildPreferences(
        prefs.autoImportFileExcludePatterns,
        prefs.autoImportEntrypointDirectorySearch
    )
end

function autoimport.bucketBuildPreferences_Equal(p, other)
    return core.UnorderedEqual(p.fileExcludePatterns, other.fileExcludePatterns) and
        p.autoImportEntrypointDirectorySearch == other.autoImportEntrypointDirectorySearch
end

function autoimport.bucketBuildPreferences_Clone(p)
    local patterns = nil
    if p.fileExcludePatterns ~= nil then
        patterns = table.move(p.fileExcludePatterns, 1, #p.fileExcludePatterns, 1, {})
    end
    return autoimport.newBucketBuildPreferences(patterns, p.autoImportEntrypointDirectorySearch)
end

-- BucketState represents the dirty state of a bucket.
-- In general, a bucket can be used for an auto-imports request if it is clean
-- or if the only edited file is the one that was requested for auto-imports.
-- Most edits within a file will not change the imports available to that file.
-- However, one exception causes the bucket to be rebuilt after a change to a
-- single file: local files are newly added to the project by a manual import.
-- This can only happen after a full (non-clone) program update. When this
-- happens, the `newProgramStructure` flag is set until the next time the bucket
-- is rebuilt, when this condition will be checked.
-- Fields:
--   dirtyFile: the file that was edited last, if any. It does not necessarily
--     indicate that no other files have been edited, so it should be ignored if
--     `multipleFilesDirty` is set. It should not be used for node_modules buckets,
--     which rely on `dirtyPackages` instead.
--   multipleFilesDirty, newProgramStructure
--   buildPreferences: the user preferences that were in effect when
--     the bucket was built. If changed, the bucket should be rebuilt.
--   dirtyPackages: the set of package names that need to be re-indexed.
--     This is used for granular updates: when a file in a local workspace package
--     changes, only that package needs to be re-extracted rather than rebuilding
--     the entire node_modules bucket.
--     If nil, no granular updates are pending.
--     If set but multipleFilesDirty is true, the entire bucket needs to be rebuilt.
--   recursiveSearchPackages: tracks which packages were recursively directory-searched
--     when the bucket was built. nil means all non-exports packages were searched
--     (e.g. when the autoImportEntrypointDirectorySearch preference is enabled).
--     A non-nil set lists only the specific packages that were searched.
--     Used for rebuild detection: a rebuild is triggered when target packages are
--     not a subset of the currently searched packages.
local BucketState = {}
BucketState.__index = BucketState
autoimport.BucketState = BucketState

function autoimport.newBucketState(init)
    local s = setmetatable({
        dirtyFile = "",
        multipleFilesDirty = false,
        newProgramStructure = newProgramStructure.False,
        buildPreferences = autoimport.newBucketBuildPreferences(nil, core.Tristate.TSUnknown),
        dirtyPackages = nil,
        recursiveSearchPackages = nil,
    }, BucketState)
    if init ~= nil then
        for k, v in pairs(init) do
            s[k] = v
        end
    end
    return s
end

function BucketState:Clone()
    return autoimport.newBucketState({
        dirtyFile = self.dirtyFile,
        multipleFilesDirty = self.multipleFilesDirty,
        newProgramStructure = self.newProgramStructure,
        buildPreferences = autoimport.bucketBuildPreferences_Clone(self.buildPreferences),
        dirtyPackages = Set.Clone(self.dirtyPackages),
        recursiveSearchPackages = Set.Clone(self.recursiveSearchPackages),
    })
end

function BucketState:Dirty()
    return self.multipleFilesDirty or self.dirtyFile ~= "" or self.newProgramStructure > 0 or Set.Len(self.dirtyPackages) > 0
end

function BucketState:DirtyFile()
    if self.multipleFilesDirty then
        return ""
    end
    return self.dirtyFile
end

function BucketState:DirtyPackages()
    if self.multipleFilesDirty then
        return nil
    end
    return self.dirtyPackages
end

function BucketState:RecursiveSearchPackages()
    return self.recursiveSearchPackages
end

function BucketState:possiblyNeedsRebuildForFile(file, preferences)
    return self.newProgramStructure > 0 or
        self:hasDirtyFileBesides(file) or
        not autoimport.bucketBuildPreferences_Equal(self.buildPreferences, autoimport.bucketBuildPreferencesFromUserPreferences(preferences)) or
        Set.Len(self.dirtyPackages) > 0
end

function BucketState:hasDirtyFileBesides(file)
    return self.multipleFilesDirty or self.dirtyFile ~= "" and self.dirtyFile ~= file
end

-- recursiveSearchSubset reports whether target is a subset of current.
-- nil represents "all packages" — a superset of every concrete set.
-- Returns true if the current set already covers everything the target needs,
-- meaning no rebuild is required for recursive search purposes.
function autoimport.recursiveSearchSubset(target, current)
    if target == nil then
        -- Target wants all packages searched — only satisfied if current is also all.
        return current == nil
    end
    if current == nil then
        -- Current searched all packages, so any concrete target is satisfied.
        return true
    end
    return target:IsSubsetOf(current)
end

-- RegistryBucket fields:
--   state (BucketState)
--   paths: maps file paths to package names. For project buckets, the package name
--     is always empty string. For node_modules buckets, this enables reverse lookup
--     from path to package for granular updates. Only paths for local workspace
--     packages (symlinked and within the workspace root) have entries here, since
--     their realpaths are outside node_modules and need reverse lookup for dirty
--     detection.
--     Paths is considered immutable after the bucket is finalized.
--     It should be fully replaced rather than mutated while changing a bucket.
--   packageFiles: maps package names to their file paths and file names.
--     All package directory names in node_modules are keys; indexed packages have
--     non-nil maps with path→fileName entries, unindexed packages have nil maps
--     (represented in Lua by autoimport.nilPackageFiles, since Lua tables cannot hold nil).
--     This enables efficient removal of a package's files during granular updates
--     without iterating through all entries. Only defined for node_modules buckets.
--     PackageFiles is considered immutable after the bucket is finalized.
--     It should be fully replaced rather than mutated while changing a bucket.
--   resolvedPackageNames: only defined for project buckets. It is the set of
--     package names that were resolved from imports in the project's program files.
--     This is passed to node_modules buckets so they include packages that are
--     directly imported even if not listed in package.json dependencies.
--     ResolvedPackageNames is considered immutable after the bucket is finalized.
--     It should be fully replaced rather than mutated while changing a bucket.
--   dependencyNames: only defined for node_modules buckets. It is the set of
--     package names that will be included in the bucket if present in the directory,
--     computed from package.json dependencies plus resolved package names from
--     active programs. If nil, all packages are included because at least one open
--     file has access to this node_modules directory without being filtered by a
--     package.json.
--     DependencyNames is considered immutable after the bucket is finalized.
--     It should be fully replaced rather than mutated while changing a bucket.
--   ambientModuleNames: only defined for node_modules buckets. It is the set of
--     ambient module names found while extracting exports in the bucket.
--     AmbientModuleNames is considered immutable after the bucket is finalized.
--     It should be fully replaced rather than mutated while changing a bucket.
--   index: Index is considered immutable after the bucket is finalized.
--     It should be cloned and replaced rather than mutated while changing a bucket.
local RegistryBucket = {}
RegistryBucket.__index = RegistryBucket
autoimport.RegistryBucket = RegistryBucket

-- Sentinel for a Go nil map[tspath.Path]string stored as a value of PackageFiles.
autoimport.nilPackageFiles = setmetatable({}, { __newindex = function() error("nilPackageFiles is immutable", 2) end })

function autoimport.newRegistryBucketStruct(init)
    local b = setmetatable({
        state = autoimport.newBucketState(nil),
        paths = nil,
        packageFiles = nil,
        resolvedPackageNames = nil,
        dependencyNames = nil,
        ambientModuleNames = nil,
        index = nil,
    }, RegistryBucket)
    if init ~= nil then
        for k, v in pairs(init) do
            b[k] = v
        end
    end
    return b
end

function autoimport.newRegistryBucket()
    return autoimport.newRegistryBucketStruct({
        state = autoimport.newBucketState({
            multipleFilesDirty = true,
            newProgramStructure = newProgramStructure.DifferentFileNames,
        }),
    })
end

function RegistryBucket:Clone()
    return autoimport.newRegistryBucketStruct({
        state = self.state:Clone(),
        paths = self.paths,
        packageFiles = self.packageFiles,
        resolvedPackageNames = self.resolvedPackageNames,
        dependencyNames = self.dependencyNames,
        ambientModuleNames = self.ambientModuleNames,
        index = self.index,
    })
end

-- markProjectFileDirty should only be called within a Change call on the dirty map.
-- Buckets are considered immutable once in a finalized registry. Should only
-- be used for project buckets.
function RegistryBucket:markProjectFileDirty(file)
    if self.state:hasDirtyFileBesides(file) then
        self.state.multipleFilesDirty = true
    else
        self.state.dirtyFile = file
    end
end

-- markNodeModulesDirty should only be called within a Change call on the dirty map.
-- Buckets are considered immutable once in a finalized registry. If packageName is
-- non-empty, that package is marked for granular update. Otherwise, the entire bucket
-- is marked dirty.
function RegistryBucket:markNodeModulesDirty(packageName)
    if self.state.multipleFilesDirty then
        return
    end
    if packageName == "" then
        self.state.multipleFilesDirty = true
        return
    end
    -- Track the package for granular updates
    if self.state.dirtyPackages == nil then
        self.state.dirtyPackages = collections.NewSet()
    end
    self.state.dirtyPackages:Add(packageName)
end

-- directory { name, packageJson, hasNodeModules }
local directory = {}
directory.__index = directory
autoimport.directory = directory

function autoimport.newDirectory(name, packageJson, hasNodeModules)
    return setmetatable({
        name = name or "",
        packageJson = packageJson,
        hasNodeModules = hasNodeModules or false,
    }, directory)
end

function directory:Clone()
    return autoimport.newDirectory(self.name, self.packageJson, self.hasNodeModules)
end

-- Registry fields: toPath, userPreferences, directories, nodeModules, projects,
-- uniquePackageCount, entrypoints (path -> []*module.ResolvedEntrypoint, shared across all
-- node_modules buckets), specifierCache (importing file -> SyncMap target file -> specifier).
local Registry = {}
Registry.__index = Registry
autoimport.Registry = Registry

function autoimport.NewRegistry(toPath, preferences)
    return setmetatable({
        toPath = toPath,
        userPreferences = preferences,
        directories = {},
        nodeModules = nil,
        projects = nil,
        uniquePackageCount = 0,
        entrypoints = nil,
        specifierCache = nil,
    }, Registry)
end

-- Callable as autoimport.Registry.IsPreparedForImportingFile(r, ...) when r may be nil.
function Registry:IsPreparedForImportingFile(fileName, projectPath, preferences)
    if self == nil then
        return false
    end
    local projectBucket = mapGet(self.projects, projectPath)
    if projectBucket == nil then
        return false
    end
    local path = self.toPath(fileName)
    if projectBucket.state:possiblyNeedsRebuildForFile(path, preferences) then
        return false
    end

    local dirPath = tspath.Path_GetDirectoryPath(path)
    while true do
        local dirBucket = mapGet(self.nodeModules, dirPath)
        if dirBucket ~= nil then
            if dirBucket.state:possiblyNeedsRebuildForFile(path, preferences) then
                return false
            end
        end
        local parent = tspath.Path_GetDirectoryPath(dirPath)
        if parent == dirPath then
            break
        end
        dirPath = parent
    end
    return true
end

function Registry:NodeModulesDirectories()
    local dirs = {}
    for dirPath, dir in pairs(self.directories or {}) do
        if dir.hasNodeModules then
            dirs[tspath.CombinePaths(dirPath, "node_modules")] = tspath.CombinePaths(dir.name, "node_modules")
        end
    end
    return dirs
end

-- Returns (*Registry, error).
function Registry:Clone(ctx, change, host, logger)
    local start = autoimport.timeNow()
    if logger ~= nil then
        logger = logger:Fork("Building autoimport registry")
    end
    local builder = autoimport.newRegistryBuilder(self, host)
    if change.userPreferences ~= nil then
        builder.userPreferences = change.userPreferences
        if not core.UnorderedEqual(builder.userPreferences.autoImportSpecifierExcludeRegexes, self.userPreferences.autoImportSpecifierExcludeRegexes) then
            builder.specifierCache:Clear()
        end
    end
    builder:updateBucketAndDirectoryExistence(change, logger)
    builder:markBucketsDirty(change, logger)
    if change.requestedFile ~= "" then
        builder:updateIndexes(ctx, change, logger)
    end
    if logger ~= nil then
        logger:Logf("Built autoimport registry in %s", autoimport.timeSince(start))
    end
    local registry = builder:Build()
    return registry, nil
end

-- BucketStats { path, exportCount, fileCount, state, dependencyNames, packageNames }
-- CacheStats { projectBuckets, nodeModulesBuckets, uniquePackageCount }

function Registry:GetCacheStats()
    local stats = {
        projectBuckets = {},
        nodeModulesBuckets = {},
        uniquePackageCount = self.uniquePackageCount,
    }

    for path, bucket in pairs(self.projects or {}) do
        local exportCount = 0
        if bucket.index ~= nil then
            exportCount = core.Len(bucket.index.entries)
        end
        stats.projectBuckets[#stats.projectBuckets + 1] = {
            path = path,
            exportCount = exportCount,
            fileCount = mapLen(bucket.paths),
            state = bucket.state,
            dependencyNames = bucket.dependencyNames,
            packageNames = nil,
        }
    end

    for path, bucket in pairs(self.nodeModules or {}) do
        local exportCount = 0
        if bucket.index ~= nil then
            exportCount = core.Len(bucket.index.entries)
        end
        -- Derive PackageNames from PackageFiles keys
        local packageNames = nil
        local fileCount = 0
        if bucket.packageFiles ~= nil then
            packageNames = collections.NewSetWithSizeHint(mapLen(bucket.packageFiles))
            for name, paths in pairs(bucket.packageFiles) do
                packageNames:Add(name)
                fileCount = fileCount + mapLen(paths)
            end
        end
        stats.nodeModulesBuckets[#stats.nodeModulesBuckets + 1] = {
            path = path,
            exportCount = exportCount,
            fileCount = fileCount,
            state = bucket.state,
            dependencyNames = bucket.dependencyNames,
            packageNames = packageNames,
        }
    end

    local byPath = function(a, b)
        if a.path < b.path then
            return -1
        elseif a.path > b.path then
            return 1
        end
        return 0
    end
    core.SortFunc(stats.projectBuckets, byPath)
    core.SortFunc(stats.nodeModulesBuckets, byPath)

    return stats
end

-- RegistryChange {
--   requestedFile: tspath.Path ("" if none)
--   openFiles: map path -> fileName
--   changed, created, deleted: collections.Set of lsproto.DocumentUri (may be nil = empty)
--   rebuiltPrograms: maps from project path to:
--     - true: the program was rebuilt with a different set of file names
--     - false: the program was rebuilt but the set of file names is unchanged
--   userPreferences: *lsutil.UserPreferences (nil if unchanged)
-- }
function autoimport.NewRegistryChange(init)
    local c = {
        requestedFile = "",
        openFiles = nil,
        changed = nil,
        created = nil,
        deleted = nil,
        rebuiltPrograms = nil,
        userPreferences = nil,
    }
    if init ~= nil then
        for k, v in pairs(init) do
            c[k] = v
        end
    end
    return c
end

-- RegistryCloneHost interface:
--   module.ResolutionHost (GetCurrentDirectory, FS)
--   FS() vfs.FS
--   GetDefaultProject(path) -> projectPath, *compiler.Program
--   GetProgramForProject(projectPath) -> *compiler.Program
--   GetPackageJson(fileName) -> *packagejson.InfoCacheEntry
--   GetSourceFile(fileName, path) -> *ast.SourceFile
--   Dispose()

local registryBuilder = {}
registryBuilder.__index = registryBuilder
autoimport.registryBuilder = registryBuilder

function autoimport.newRegistryBuilder(registry, host)
    return setmetatable({
        host = host,
        base = registry,

        userPreferences = registry.userPreferences,
        directories = dirty.NewMap(registry.directories),
        nodeModules = dirty.NewMap(registry.nodeModules),
        projects = dirty.NewMap(registry.projects),
        specifierCache = dirty.NewMapBuilder(registry.specifierCache, core.Identity, core.Identity),
        resolverOptions = {},

        uniquePackageCount = registry.uniquePackageCount,
        entrypoints = dirty.NewMapBuilder(registry.entrypoints, core.Identity, core.Identity),
    }, registryBuilder)
end

function registryBuilder:Build()
    return setmetatable({
        toPath = self.base.toPath,
        userPreferences = self.userPreferences,
        directories = (self.directories:Finalize()),
        nodeModules = (self.nodeModules:Finalize()),
        projects = (self.projects:Finalize()),
        specifierCache = (self.specifierCache:Build()),
        uniquePackageCount = self.uniquePackageCount,
        entrypoints = (self.entrypoints:Build()),
    }, Registry)
end

function registryBuilder:updateBucketAndDirectoryExistence(change, logger)
    local start = autoimport.timeNow()
    local neededProjects = {}
    local neededDirectories = {}
    for _, path in ipairs(autoimport.sortedKeys(change.openFiles)) do
        local fileName = change.openFiles[path]
        neededProjects[(self.host:GetDefaultProject(path))] = true
        if not tspath.IsDynamicFileName(fileName) then
            local dir = fileName
            local dirPath = path
            while true do
                dir = tspath.GetDirectoryPath(dir)
                local lastDirPath = dirPath
                dirPath = tspath.Path_GetDirectoryPath(dirPath)
                if dirPath == lastDirPath then
                    break
                end
                if neededDirectories[dirPath] ~= nil then
                    break
                end
                neededDirectories[dirPath] = dir
            end

            if not self.specifierCache:Has(path) then
                self.specifierCache:Set(path, collections.NewSyncMap())
            end
        end
    end

    if change.requestedFile ~= "" then
        neededProjects[(self.host:GetDefaultProject(change.requestedFile))] = true
        if not self.specifierCache:Has(change.requestedFile) then
            self.specifierCache:Set(change.requestedFile, collections.NewSyncMap())
        end
    end

    for _, path in ipairs(autoimport.sortedKeys(self.base.specifierCache)) do
        if mapGet(change.openFiles, path) == nil and path ~= change.requestedFile then
            self.specifierCache:Delete(path)
        end
    end

    local addedProjects, removedProjects = {}, {}
    core.DiffMapsFunc(
        self.base.projects,
        neededProjects,
        function()
            error("never called because onChanged is nil", 0)
        end,
        function(projectPath)
            -- Need and don't have
            self.projects:Add(projectPath, autoimport.newRegistryBucket())
            addedProjects[#addedProjects + 1] = projectPath
        end,
        function(projectPath)
            -- Have and don't need
            self.projects:Delete(projectPath)
            removedProjects[#removedProjects + 1] = projectPath
        end,
        nil
    )
    if logger ~= nil then
        for _, projectPath in ipairs(addedProjects) do
            logger:Logf("Added project: %s", projectPath)
        end
        for _, projectPath in ipairs(removedProjects) do
            logger:Logf("Removed project: %s", projectPath)
        end
    end

    local updateDirectory = function(dirPath, dirName, packageJsonChanged)
        local packageJsonFileName = tspath.CombinePaths(dirName, "package.json")
        local hasNodeModules = self.host:FS():DirectoryExists(tspath.CombinePaths(dirName, "node_modules"))
        local entry, ok = self.directories:Get(dirPath)
        if ok then
            entry:ChangeIf(function(dir)
                return packageJsonChanged or dir.hasNodeModules ~= hasNodeModules
            end, function(dir)
                dir.packageJson = self.host:GetPackageJson(packageJsonFileName)
                dir.hasNodeModules = hasNodeModules
            end)
        else
            self.directories:Add(dirPath, autoimport.newDirectory(
                dirName,
                self.host:GetPackageJson(packageJsonFileName),
                hasNodeModules
            ))
        end

        if hasNodeModules then
            local _, has = self.nodeModules:Get(dirPath)
            if not has then
                self.nodeModules:Add(dirPath, autoimport.newRegistryBucket())
            end
        else
            self.nodeModules:TryDelete(dirPath)
        end
    end

    local addedNodeModulesDirs, removedNodeModulesDirs = {}, {}
    local packageJsonChanged = function(dirName)
        local uri = lsconv.FileNameToDocumentURI(tspath.CombinePaths(dirName, "package.json"))
        return Set.Has(change.changed, uri) or Set.Has(change.deleted, uri) or Set.Has(change.created, uri)
    end
    core.DiffMapsFunc(
        self.base.directories,
        neededDirectories,
        function(dir, dirName)
            return not packageJsonChanged(dirName) and dir.hasNodeModules == self.host:FS():DirectoryExists(tspath.CombinePaths(dirName, "node_modules"))
        end,
        function(dirPath, dirName)
            -- Need and don't have
            local hadNodeModules = mapGet(self.base.nodeModules, dirPath) ~= nil
            updateDirectory(dirPath, dirName, false)
            if logger ~= nil then
                logger:Logf("Added directory: %s", dirPath)
            end
            local _, hasNow = self.nodeModules:Get(dirPath)
            if hasNow and not hadNodeModules then
                addedNodeModulesDirs[#addedNodeModulesDirs + 1] = dirPath
            end
        end,
        function(dirPath)
            -- Have and don't need
            local hadNodeModules = mapGet(self.base.nodeModules, dirPath) ~= nil
            self.directories:Delete(dirPath)
            self.nodeModules:TryDelete(dirPath)
            if logger ~= nil then
                logger:Logf("Removed directory: %s", dirPath)
            end
            if hadNodeModules then
                removedNodeModulesDirs[#removedNodeModulesDirs + 1] = dirPath
            end
        end,
        function(dirPath, _, dirName)
            updateDirectory(dirPath, dirName, packageJsonChanged(dirName))
            if logger ~= nil then
                logger:Logf("Changed directory: %s", dirPath)
            end
        end
    )

    if logger ~= nil then
        for _, dirPath in ipairs(addedNodeModulesDirs) do
            logger:Logf("Added node_modules bucket: %s", dirPath)
        end
        for _, dirPath in ipairs(removedNodeModulesDirs) do
            logger:Logf("Removed node_modules bucket: %s", dirPath)
        end
        logger:Logf("Updated buckets and directories in %s", autoimport.timeSince(start))
    end
end

function registryBuilder:markBucketsDirty(change, logger)
    -- Mark new program structures
    for _, projectPath in ipairs(autoimport.sortedKeys(change.rebuiltPrograms)) do
        local newFileNames = change.rebuiltPrograms[projectPath]
        local bucket, ok = self.projects:Get(projectPath)
        if ok then
            bucket:Change(function(b)
                b.state.newProgramStructure = core.IfElse(newFileNames, newProgramStructure.DifferentFileNames, newProgramStructure.SameFileNames)
            end)
        end
    end

    -- Mark files dirty, bailing out if all buckets already have multiple files dirty
    local cleanNodeModulesBuckets = {}
    local cleanProjectBuckets = {}
    self.nodeModules:Range(function(entry)
        if not entry:Value().state.multipleFilesDirty then
            cleanNodeModulesBuckets[entry:Key()] = true
        end
        return true
    end)
    self.projects:Range(function(entry)
        if not entry:Value().state.multipleFilesDirty then
            cleanProjectBuckets[entry:Key()] = true
        end
        return true
    end)

    local markFilesDirty = function(uris)
        if next(cleanNodeModulesBuckets) == nil and next(cleanProjectBuckets) == nil then
            return
        end
        for _, uri in ipairs(autoimport.sortedKeys(uris)) do
            local path = self.base.toPath(lsproto.DocumentUri_FileName(uri))
            if next(cleanNodeModulesBuckets) ~= nil then
                -- For node_modules, mark the bucket dirty if anything changes in the directory.
                -- The path could be either a symlink path (containing /node_modules/) or a realpath
                -- (for symlinked project references). Both are recorded in Paths for granular updates.
                local nodeModulesIndex = string.find(path, "/node_modules/", 1, true)
                if nodeModulesIndex ~= nil then
                    local dirPath = string.sub(path, 1, nodeModulesIndex - 1)
                    if cleanNodeModulesBuckets[dirPath] then
                        local entry = self.nodeModules:Get(dirPath)
                        -- Look up the package name for granular updates
                        local packageName = mapGet(entry:Value().paths, path) or ""
                        entry:Change(function(bucket) bucket:markNodeModulesDirty(packageName) end)
                        if not entry:Value().state.multipleFilesDirty then
                            cleanNodeModulesBuckets[dirPath] = nil
                        end
                    end
                else
                    -- Check if this path (possibly a realpath of a workspace package) is in any bucket's Paths.
                    -- This handles local workspace packages where the realpath doesn't contain /node_modules/.
                    for _, bucketDirPath in ipairs(autoimport.sortedKeys(cleanNodeModulesBuckets)) do
                        local entry = self.nodeModules:Get(bucketDirPath)
                        local packageName = mapGet(entry:Value().paths, path)
                        if packageName ~= nil then
                            -- Use the package name for granular updates
                            entry:Change(function(bucket) bucket:markNodeModulesDirty(packageName) end)
                            if not entry:Value().state.multipleFilesDirty then
                                cleanNodeModulesBuckets[bucketDirPath] = nil
                            end
                        end
                    end
                end
            end

            -- For projects, mark the bucket dirty if the bucket contains the file directly.
            -- Any other significant change, like a created failed lookup location, is
            -- handled by newProgramStructure.
            for _, projectDirPath in ipairs(autoimport.sortedKeys(cleanProjectBuckets)) do
                local entry = self.projects:Get(projectDirPath)
                if mapGet(entry:Value().paths, path) ~= nil then
                    -- Project buckets don't use package-based granular updates
                    entry:Change(function(bucket) bucket:markProjectFileDirty(path) end)
                    if not entry:Value().state.multipleFilesDirty then
                        cleanProjectBuckets[projectDirPath] = nil
                    end
                end
            end
        end
    end

    markFilesDirty(Set.Keys(change.created))
    markFilesDirty(Set.Keys(change.deleted))
    markFilesDirty(Set.Keys(change.changed))
end

function registryBuilder:updateIndexes(ctx, change, logger)
    -- nodeModulesBucketTask {
    --   entry, dependencyNames, dirName, dirPath,
    --   -- For granular updates.
    --   isUpdate, existingBucket, dirtyPackages,
    --   -- Filled by discovery.
    --   packageNames, directoryPackageNames, discovered
    -- }

    local projectPath = self.host:GetDefaultProject(change.requestedFile)
    if projectPath == "" then
        return
    end

    -- Compute resolved package names and project reference output mappings for all projects upfront.
    -- Resolved package names are needed to compute node_modules dependencies so packages that are
    -- directly imported by programs are included even if not listed in package.json.
    -- Project reference output mappings are needed to redirect extraction from output .d.ts files
    -- to source files for packages that are project references.
    -- We need all projects because a node_modules directory can be used by multiple projects.
    local allResolvedPackageNames = {}
    local projectReferenceOutputs = {}
    -- Compute which packages have implicit deep imports (subpath imports in packages
    -- without exports). These packages need recursive directory search to discover
    -- all auto-importable files, even when the preference is disabled.
    local allDeepImportPackages = collections.NewSet()
    self.projects:Range(function(entry)
        local program = self.host:GetProgramForProject(entry:Key())
        if program ~= nil then
            allResolvedPackageNames[entry:Key()] = autoimport.getResolvedPackageNames(ctx, program)
            autoimport.addProjectReferenceOutputMappings(program, projectReferenceOutputs)
            for _, name in ipairs(setKeys(program:DeepImportPackageNames())) do
                allDeepImportPackages:Add(name)
            end
        end
        return true
    end)

    local fileExcludePatterns = self.userPreferences:ParsedAutoImportFileExcludePatterns(self.host:FS():UseCaseSensitiveFileNames())

    -- Determine which packages need recursive directory search for this build.
    -- nil means all packages (preference is enabled for all).
    local targetRecursivePackages = nil
    if not core.Tristate_IsTrue(self.userPreferences.autoImportEntrypointDirectorySearch) then
        targetRecursivePackages = allDeepImportPackages
    end

    -- --- Collect node_modules tasks ---
    local nodeModulesTasks = {}
    tspath.ForEachAncestorDirectoryPath(change.requestedFile, function(dirPath)
        local nodeModulesBucket, ok = self.nodeModules:Get(dirPath)
        if ok then
            local dirName = (self.directories:Get(dirPath)):Value().name
            local dependencies = self:computeDependenciesForNodeModulesDirectory(change, allResolvedPackageNames, dirName, dirPath)
            local bucketState = nodeModulesBucket:Value().state
            -- !!! Optimization: handle different dependency set via granular updates
            local needsFullRebuild = bucketState.multipleFilesDirty or
                not Set.Equals(nodeModulesBucket:Value().dependencyNames, dependencies) or
                not autoimport.bucketBuildPreferences_Equal(bucketState.buildPreferences, autoimport.bucketBuildPreferencesFromUserPreferences(self.userPreferences)) or
                not autoimport.recursiveSearchSubset(targetRecursivePackages, bucketState.recursiveSearchPackages)
            local dirtyPackages = bucketState:DirtyPackages()
            local canDoGranularUpdate = not needsFullRebuild and Set.Len(dirtyPackages) > 0

            if needsFullRebuild then
                nodeModulesTasks[#nodeModulesTasks + 1] = {
                    entry = nodeModulesBucket,
                    dependencyNames = dependencies,
                    dirName = dirName,
                    dirPath = dirPath,
                    isUpdate = false,
                }
            elseif canDoGranularUpdate then
                nodeModulesTasks[#nodeModulesTasks + 1] = {
                    entry = nodeModulesBucket,
                    dependencyNames = dependencies,
                    dirName = dirName,
                    dirPath = dirPath,
                    isUpdate = true,
                    existingBucket = nodeModulesBucket:Value(),
                    dirtyPackages = dirtyPackages,
                }
            end
        end
        return nil, false
    end)

    local nodeModulesLogger = nil
    if logger ~= nil and #nodeModulesTasks > 0 then
        nodeModulesLogger = logger:Fork("Building node_modules indexes")
    end

    -- --- Phase 1: Discovery (parallel per bucket) ---
    -- Resolve package.json and realpath for each package in each bucket.
    local discoveryStart = autoimport.timeNow()
    for _, task in ipairs(nodeModulesTasks) do
        if task.isUpdate then
            task.packageNames = task.dirtyPackages
        else
            task.directoryPackageNames = autoimport.getPackageNamesInNodeModules(tspath.CombinePaths(task.dirName, "node_modules"), self.host:FS())
            task.packageNames = core.Coalesce(task.dependencyNames, task.directoryPackageNames)
        end
        task.discovered = self:discoverBucketPackages(task.packageNames, task.dirName, task.dirPath)
    end
    if nodeModulesLogger ~= nil then
        nodeModulesLogger:Logf("Discovered packages: %s", autoimport.timeSince(discoveryStart))
    end

    -- --- Phase 2: Extraction (parallel per unique realpath) ---
    -- Extract from main packages first. If a main package has no TypeScript entrypoints,
    -- we fall back to extracting from @types in a second pass. Packages with no main
    -- package extract directly from @types in the primary pass.
    local extractionStart = autoimport.timeNow()
    local seen = {}
    local seenCount = 0
    local extractionCache = {}
    -- Collect all packages that have an @types fallback. After the primary pass, we
    -- filter to only those whose main extraction failed, then deduplicate by typesRealpath.
    local typesFallbackCandidates = {}
    for _, task in ipairs(nodeModulesTasks) do
        for _, pkg in ipairs(task.discovered) do
            if pkg.realpath ~= "" then
                if not seen[pkg.realpath] then
                    seen[pkg.realpath] = true
                    seenCount = seenCount + 1
                    local enableDirSearch = targetRecursivePackages == nil or
                        targetRecursivePackages:Has(pkg.packageName) or
                        autoimport.knownRecursiveSearchPackages:Has(pkg.packageName)
                    -- Record actual directory-searched packages so the stored set
                    -- reflects reality for rebuild detection and stats.
                    if enableDirSearch and targetRecursivePackages ~= nil then
                        targetRecursivePackages:Add(pkg.packageName)
                    end
                    if autoimport.ctxErr(ctx) == nil then
                        local result = self:extractPackage(ctx, pkg.packageJson, pkg.packageName, projectReferenceOutputs, fileExcludePatterns, enableDirSearch)
                        if result ~= nil then
                            extractionCache[pkg.realpath] = result
                        end
                    end
                end
                if pkg.typesRealpath ~= "" then
                    typesFallbackCandidates[#typesFallbackCandidates + 1] = pkg
                end
            elseif pkg.typesRealpath ~= "" then
                if not seen[pkg.typesRealpath] then
                    seen[pkg.typesRealpath] = true
                    seenCount = seenCount + 1
                    -- @types packages always get directory search
                    if targetRecursivePackages ~= nil then
                        targetRecursivePackages:Add(pkg.packageName)
                    end
                    if autoimport.ctxErr(ctx) == nil then
                        local result = self:extractPackage(ctx, pkg.typesPackageJson, pkg.packageName, projectReferenceOutputs, fileExcludePatterns, true --[[enableDirectorySearch]])
                        if result ~= nil then
                            extractionCache[pkg.typesRealpath] = result
                        end
                    end
                end
            end
        end
    end

    -- For packages whose main extraction yielded nothing, fall back to @types.
    for _, pkg in ipairs(typesFallbackCandidates) do
        local mainExtracted = extractionCache[pkg.realpath] ~= nil
        if mainExtracted or seen[pkg.typesRealpath] then
            goto continue
        end
        seen[pkg.typesRealpath] = true
        seenCount = seenCount + 1
        -- @types fallback packages always get directory search
        if targetRecursivePackages ~= nil then
            targetRecursivePackages:Add(pkg.packageName)
        end
        if autoimport.ctxErr(ctx) == nil then
            local result = self:extractPackage(ctx, pkg.typesPackageJson, pkg.packageName, projectReferenceOutputs, fileExcludePatterns, true --[[enableDirectorySearch]])
            if result ~= nil then
                extractionCache[pkg.typesRealpath] = result
            end
        end
        ::continue::
    end
    if nodeModulesLogger ~= nil then
        nodeModulesLogger:Logf("Extracted exports: %s (%d packages)", autoimport.timeSince(extractionStart), seenCount)
    end
    self.uniquePackageCount = seenCount

    -- --- Phase 3: Bucket building (parallel per bucket) ---
    -- Each bucket installs the shared extraction results and builds its index.
    local allResults = {}

    for _, task in ipairs(nodeModulesTasks) do
        local br = autoimport.newBucketBuildResult(task.entry)
        allResults[#allResults + 1] = br
        if task.isUpdate then
            self:updateNodeModulesBucket(
                ctx, br, task.existingBucket, task.dirtyPackages, task.discovered, extractionCache,
                targetRecursivePackages, fork(nodeModulesLogger, task.dirName)
            )
        else
            self:buildNodeModulesBucket(
                ctx, br, task.dependencyNames, task.dirPath, task.discovered, task.directoryPackageNames, extractionCache,
                targetRecursivePackages, fork(nodeModulesLogger, task.dirName)
            )
        end
    end

    -- Project bucket (not part of the three-phase pipeline — no cross-bucket dedup needed).
    local project, hasProject = self.projects:Get(projectPath)
    if hasProject then
        local program = self.host:GetProgramForProject(projectPath)
        local resolvedPackageNames = allResolvedPackageNames[projectPath]
        local shouldRebuild = project:Value().state:hasDirtyFileBesides(change.requestedFile) or
            not autoimport.bucketBuildPreferences_Equal(project:Value().state.buildPreferences, autoimport.bucketBuildPreferencesFromUserPreferences(self.userPreferences))
        if not shouldRebuild and project:Value().state.newProgramStructure > 0 then
            if not Set.Equals(project:Value().resolvedPackageNames, resolvedPackageNames) or autoimport.hasNewNonNodeModulesFiles(program, project:Value()) then
                shouldRebuild = true
            else
                project:Change(function(b) b.state.newProgramStructure = newProgramStructure.False end)
            end
        end
        if shouldRebuild then
            local br = autoimport.newBucketBuildResult(project)
            allResults[#allResults + 1] = br
            self:buildProjectBucket(
                ctx, br, projectPath, resolvedPackageNames,
                fork(logger, "Building project bucket " .. projectPath)
            )
        end
    end

    for _, br in ipairs(allResults) do
        if br.err ~= nil then
            goto continue
        end
        for _, path in ipairs(br.removedEntrypointPaths or {}) do
            self.entrypoints:Delete(path)
        end
        for _, path in ipairs(autoimport.sortedKeys(br.entrypoints)) do
            self.entrypoints:Set(path, br.entrypoints[path])
        end
        br.entry:Replace(br.bucket)
        ::continue::
    end

    -- If we failed to resolve any alias exports by ending up at a non-relative module specifier
    -- that didn't resolve to another package, it's probably an ambient module declared in another package.
    -- We recorded these failures, along with the name of every ambient module declared elsewhere, so we
    -- can do a second pass on the failed files, this time including the ambient modules declarations that
    -- were missing the first time. Example: node_modules/fs-extra/index.d.ts is simply `export * from "fs"`,
    -- but when trying to resolve the `export *`, we don't know where "fs" is declared. The aliasResolver
    -- tries to find packages named "fs" on the file system, but after failing, records "fs" as a failure
    -- for fs-extra/index.d.ts. Meanwhile, if we also processed node_modules/@types/node/fs.d.ts, we
    -- recorded that file as declaring the ambient module "fs". In the second pass, we combine those two
    -- files and reprocess fs-extra/index.d.ts, this time finding "fs" declared in @types/node.
    local secondPassStart = autoimport.timeNow()
    local secondPassFileCount = 0
    for _, br in ipairs(allResults) do
        if br.err ~= nil then
            goto continue
        end
        if br.possibleFailedAmbientModuleLookupTargets == nil then
            goto continue
        end
        do
            -- Go collects a map fileName -> file and takes its values; files are kept in insertion
            -- order here (nil files, which Go would keep as nil entries, are skipped).
            local rootFileNames = {}
            local rootFiles = {}
            local targets = br.possibleFailedAmbientModuleLookupTargets:ToSlice()
            table.sort(targets)
            for _, target in ipairs(targets) do
                for _, fileName in ipairs(self:resolveAmbientModuleName(target, br.entry:Key()) or {}) do
                    if rootFileNames[fileName] then
                        goto nextFile
                    end
                    rootFileNames[fileName] = true
                    do
                        local file = self.host:GetSourceFile(fileName, self.base.toPath(fileName))
                        if file ~= nil then
                            rootFiles[#rootFiles + 1] = file
                        end
                    end
                    secondPassFileCount = secondPassFileCount + 1
                    ::nextFile::
                end
            end
            if next(rootFileNames) ~= nil then
                local moduleResolver = module.NewResolverWithOptions(self.host, core.EmptyCompilerOptions, "", "", self.resolverOptions)
                local aliasResolver = autoimport.newAliasResolver(
                    rootFiles,
                    nil,
                    self.host,
                    moduleResolver,
                    self.base.toPath,
                    function()
                        -- no-op
                    end
                )
                local ch = checker.NewChecker(aliasResolver, nil)
                local fs = self.host:FS()
                local sources = {}
                br.possibleFailedAmbientModuleLookupSources:Range(function(path, source)
                    sources[#sources + 1] = { path = path, source = source }
                    return true
                end)
                table.sort(sources, function(a, b) return a.path < b.path end)
                for _, item in ipairs(sources) do
                    local source = item.source
                    local sourceFile = aliasResolver:GetSourceFile(source.fileName)
                    local extractor = self:newExportExtractor(source.packageName, ch, moduleResolver, function(p) return fs:Realpath(p) end)
                    local fileExports = extractor:extractFromFile(sourceFile)
                    for _, exp in ipairs(fileExports or {}) do
                        br.bucket.index:insertAsWords(exp)
                    end
                end
            end
        end
        ::continue::
    end

    if nodeModulesLogger ~= nil then
        if secondPassFileCount > 0 then
            nodeModulesLogger:Logf("%d files required second pass, took %s", secondPassFileCount, autoimport.timeSince(secondPassStart))
        end
        nodeModulesLogger:Logf("Total: %s", autoimport.timeSince(discoveryStart))
    end
end

function autoimport.hasNewNonNodeModulesFiles(program, bucket)
    if bucket.state.newProgramStructure ~= newProgramStructure.DifferentFileNames then
        return false
    end
    for _, file in ipairs(program:GetSourceFiles()) do
        if string.find(file:FileName(), "/node_modules/", 1, true) ~= nil or autoimport.isIgnoredFile(program, file) then
            goto continue
        end
        if mapGet(bucket.paths, file:Path()) == nil then
            return true
        end
        ::continue::
    end
    return false
end

function autoimport.isIgnoredFile(program, file)
    return program:IsSourceFileDefaultLibrary(file:Path()) or program:IsGlobalTypingsFile(file:FileName())
end

-- hasSymlinkToNodeModules checks if a file's realpath has a symlink that points
-- to a node_modules directory. This is used to skip files in the project bucket
-- that would be duplicated by the node_modules bucket via their symlink.
function autoimport.hasSymlinkToNodeModules(filePath, projectRootPath, symlinkCache)
    if symlinkCache == nil then
        return false
    end
    -- Keep files inside this project indexed in project buckets even if they are
    -- reachable through a node_modules symlink from elsewhere.
    if tspath.Path_ContainsPath(projectRootPath, filePath) then
        return false
    end

    -- First check if the file itself has a symlink to node_modules
    local filesByRealpath = symlinkCache:FilesByRealpath()
    if filesByRealpath ~= nil then
        local symlinkPaths, ok = filesByRealpath:Load(filePath)
        if ok then
            local found = false
            symlinkPaths:Range(function(symlinkPath)
                if string.find(symlinkPath, "/node_modules/", 1, true) ~= nil then
                    found = true
                    return false -- stop ranging
                end
                return true
            end)
            if found then
                return true
            end
        end
    end

    -- Fall back to checking ancestor directories
    local directoriesByRealpath = symlinkCache:DirectoriesByRealpath()
    if directoriesByRealpath == nil then
        return false
    end
    local found = false
    tspath.ForEachAncestorDirectoryPath(filePath, function(dirPath)
        local symlinkPaths, ok = directoriesByRealpath:Load(tspath.Path_EnsureTrailingDirectorySeparator(dirPath))
        if not ok then
            return nil, false
        end
        -- Check if any of the symlinks point to a node_modules directory
        symlinkPaths:Range(function(symlinkPath)
            if string.find(symlinkPath, "/node_modules/", 1, true) ~= nil then
                found = true
                return false -- stop ranging
            end
            return true
        end)
        return nil, found -- stop if we found a match
    end)
    return found
end

-- failedAmbientModuleLookupSource { fileName, packageName }
function autoimport.newFailedAmbientModuleLookupSource(fileName)
    return { fileName = fileName or "", packageName = "" }
end

-- bucketBuildResult {
--   entry, err, bucket,
--   entrypoints: the resolved entrypoints from this bucket's packages,
--     to be merged into the registry-level entrypoints map.
--   removedEntrypointPaths: lists paths whose entrypoints should be removed from
--     the registry-level map before merging new entrypoints. Used for granular updates.
--   possibleFailedAmbientModuleLookupSources: File path to filename and package name
--   possibleFailedAmbientModuleLookupTargets: Likely ambient module name
-- }
function autoimport.newBucketBuildResult(entry)
    return {
        entry = entry,
        err = nil,
        bucket = nil,
        entrypoints = nil,
        removedEntrypointPaths = nil,
        possibleFailedAmbientModuleLookupSources = nil,
        possibleFailedAmbientModuleLookupTargets = nil,
    }
end

function registryBuilder:buildProjectBucket(ctx, result, projectPath, resolvedPackageNames, logger)
    if autoimport.ctxErr(ctx) ~= nil then
        result.err = autoimport.ctxErr(ctx)
        return
    end

    local start = autoimport.timeNow()
    local fileExcludePatterns = self.userPreferences:ParsedAutoImportFileExcludePatterns(self.host:FS():UseCaseSensitiveFileNames())
    result.bucket = autoimport.newRegistryBucketStruct(nil)
    local moduleResolver = module.NewResolverWithOptions(self.host, core.EmptyCompilerOptions, "", "", self.resolverOptions)
    local program = self.host:GetProgramForProject(projectPath)
    local projectRootPath = self.base.toPath(program:GetCurrentDirectory())
    local symlinkCache = program:GetSymlinkCache()
    local getChecker, closePool, checkerCount = autoimport.createCheckerPool(program)
    -- exports: path -> []*Export; exportPaths keeps the program's file order.
    local exports = {}
    local exportPaths = {}
    local skippedFileCount = 0
    local combinedExports, combinedUsedChecker = 0, 0

    for _, file in ipairs(program:GetSourceFiles()) do
        if autoimport.isIgnoredFile(program, file) then
            goto continue
        end
        if fileExcludePatterns ~= nil and fileExcludePatterns:MatchString(file:FileName()) then
            skippedFileCount = skippedFileCount + 1
            goto continue
        end
        -- Ordinary node_modules files are owned by node_modules buckets. Content-mapped files are not
        -- discovered by those buckets, but files already transformed in the Program can be indexed here.
        if file:ContentMapper() == "" and
            (string.find(file:FileName(), "/node_modules/", 1, true) ~= nil or autoimport.hasSymlinkToNodeModules(file:Path(), projectRootPath, symlinkCache)) then
            goto continue
        end
        if autoimport.ctxErr(ctx) == nil then
            local ch, done = getChecker()
            local extractor = self:newExportExtractor("", ch, moduleResolver, nil)
            local fileExports = extractor:extractFromFile(file)
            done()
            if exports[file:Path()] == nil then
                exportPaths[#exportPaths + 1] = file:Path()
            end
            exports[file:Path()] = fileExports or {}
            local stats = extractor:Stats()
            combinedExports = combinedExports + stats.exports
            combinedUsedChecker = combinedUsedChecker + stats.usedChecker
        end
        ::continue::
    end
    closePool()

    local indexStart = autoimport.timeNow()
    local idx = autoimport.NewIndex()
    local paths = {}
    for _, path in ipairs(exportPaths) do
        paths[path] = "" -- Empty string for project buckets
        for _, exp in ipairs(exports[path]) do
            idx:insertAsWords(exp)
        end
    end

    result.bucket.paths = paths
    result.bucket.index = idx
    result.bucket.resolvedPackageNames = resolvedPackageNames
    result.bucket.state.buildPreferences = autoimport.bucketBuildPreferencesFromUserPreferences(self.userPreferences)

    if logger ~= nil then
        logger:Logf("Extracted exports: %s (%d exports, %d used checker, %d created checkers)", autoimport.durationString(indexStart - start), combinedExports, combinedUsedChecker, checkerCount())
        if skippedFileCount > 0 then
            logger:Logf("Skipped %d files due to exclude patterns", skippedFileCount)
        end
        logger:Logf("Built index: %s", autoimport.timeSince(indexStart))
        logger:Logf("Bucket total: %s", autoimport.timeSince(start))
    end
end

function registryBuilder:computeDependenciesForNodeModulesDirectory(change, allResolvedPackageNames, dirName, dirPath)
    -- If any open files are in scope of this directory but not in scope of any package.json,
    -- we need to add all packages in this node_modules directory.
    for _, path in ipairs(autoimport.sortedKeys(change.openFiles)) do
        if tspath.Path_ContainsPath(dirPath, path) and self:getNearestAncestorDirectoryWithPackageJson(path) == nil then
            return nil
        end
    end

    -- Get all package.jsons that have this node_modules directory in their spine
    local dependencies = collections.NewSet()
    self.directories:Range(function(entry)
        local packageJson = entry:Value().packageJson
        if packageJson ~= nil and packageJson:Exists() and tspath.Path_ContainsPath(dirPath, entry:Key()) then
            autoimport.addPackageJsonDependencies(packageJson.contents, dependencies)
        end
        return true
    end)

    -- Add packages that are directly imported by programs but not listed in package.json.
    -- This ensures node_modules files are always in node_modules buckets.
    -- Include packages from all projects that have this node_modules directory in their spine.
    for _, resolvedPackageNames in pairs(allResolvedPackageNames) do
        for name in pairs(Set.Keys(resolvedPackageNames) or {}) do
            dependencies:Add(name)
        end
    end

    return dependencies
end

-- discoveredPackage represents a package found during the discovery phase.
-- It holds the resolved package.json and realpath for deduplication.
-- When both a real package and a corresponding @types package exist (e.g., react + @types/react),
-- both are stored so extraction can fall back to the @types package if the real package has no
-- TypeScript entrypoints.
-- { packageName, packageJson, realpath, typesPackageJson, typesRealpath,
--   dirPath (bucket directory path, used as extraction context),
--   isLocal (true if realpath is within the workspace root) }

-- perPackageExtractionResult holds the extraction output for one physical package.
-- Produced once per unique realpath during the extraction phase, then installed
-- into every bucket that needs it during the bucket-building phase.
-- { packageFiles, entrypoints, exports, ambientModules, statsExports, statsUsedChecker,
--   skippedEntrypoints, isSymlinked, failedAmbientModuleLookupSources,
--   failedAmbientModuleLookupTargets }

-- packageExtractionResult holds the results of extracting exports from a set of packages.
-- { exports, packageFiles, ambientModuleNames, entrypoints, workspacePackages,
--   possibleFailedAmbientModuleLookupSources, possibleFailedAmbientModuleLookupTargets,
--   stats, skippedEntrypointsCount }

-- discoverBucketPackages resolves the package.json and realpath for each package name
-- in a node_modules directory. This is the discovery phase of the three-phase extraction pipeline.
function registryBuilder:discoverBucketPackages(packageNames, dirName, dirPath)
    local result = {}
    for _, packageName in ipairs(setKeys(packageNames)) do
        local typesPackageName = module.GetTypesPackageName(packageName)
        local packageJson = self.host:GetPackageJson(tspath.CombinePaths(dirName, "node_modules", packageName, "package.json"))
        local typesPackageJson = nil
        if packageName ~= typesPackageName then
            local typesJson = self.host:GetPackageJson(tspath.CombinePaths(dirName, "node_modules", typesPackageName, "package.json"))
            if typesJson.directoryExists then
                typesPackageJson = typesJson
            end
        end
        local realpath = ""
        if packageJson.directoryExists then
            realpath = self.host:FS():Realpath(packageJson.packageDirectory)
        end
        local typesRealpath = ""
        if typesPackageJson ~= nil then
            typesRealpath = self.host:FS():Realpath(typesPackageJson.packageDirectory)
        end
        local isLocal = realpath ~= "" and
            string.find(realpath, "/node_modules/", 1, true) == nil and
            tspath.ContainsPath(
                self.host:GetCurrentDirectory(),
                realpath,
                tspath.NewComparePathsOptions(self.host:FS():UseCaseSensitiveFileNames(), "")
            )
        result[#result + 1] = {
            packageName = packageName,
            packageJson = packageJson,
            realpath = realpath,
            typesPackageJson = typesPackageJson,
            typesRealpath = typesRealpath,
            dirPath = dirPath,
            isLocal = isLocal,
        }
    end
    return result
end

-- extractPackage extracts exports from a single package.json.
-- This runs once per unique realpath during the extraction phase.
-- Returns nil if the package has no extractable entrypoints.
function registryBuilder:extractPackage(ctx, packageJson, packageName, projectReferenceOutputs, fileExcludePatterns, enableDirectorySearch)
    if packageJson == nil or not packageJson.directoryExists then
        return nil
    end
    local toRealpath, toSymlink = autoimport.getPackageRealpathFuncs(self.host:FS(), packageJson.packageDirectory)
    local resolver = autoimport.getModuleResolver(self.host, toRealpath, self.resolverOptions)
    local packageEntrypoints = resolver:GetEntrypointsFromPackageJsonInfo(packageJson, packageName, enableDirectorySearch)
    if packageEntrypoints == nil then
        return nil
    end

    local skippedEntrypoints = 0
    if fileExcludePatterns ~= nil then
        local count = #packageEntrypoints
        packageEntrypoints = core.Filter(packageEntrypoints, function(entrypoint)
            return not fileExcludePatterns:MatchString(entrypoint.resolvedFileName)
        end)
        skippedEntrypoints = count - core.Len(packageEntrypoints)
    end
    if core.Len(packageEntrypoints) == 0 then
        return nil
    end

    local result = {
        packageFiles = {},
        entrypoints = packageEntrypoints,
        exports = {},
        exportPaths = {},
        ambientModules = {},
        statsExports = 0,
        statsUsedChecker = 0,
        skippedEntrypoints = skippedEntrypoints,
        isSymlinked = false,
        failedAmbientModuleLookupSources = {},
        failedAmbientModuleLookupTargets = collections.NewSet(),
    }

    -- Resolve entrypoint source files and build the alias resolver.
    local seenFiles = collections.NewSetWithSizeHint(#packageEntrypoints)
    local rootFiles = {}
    local symlinks = {}
    for _, entrypoint in ipairs(packageEntrypoints) do
        local fileName = entrypoint:SymlinkOrRealpath()
        local realpathFileName = entrypoint.resolvedFileName
        local realpathPath = self.base.toPath(realpathFileName)

        local inputFileName = projectReferenceOutputs[realpathPath]
        if inputFileName ~= nil then
            fileName = toSymlink(inputFileName)
            realpathFileName = inputFileName
            realpathPath = self.base.toPath(realpathFileName)
        end

        if seenFiles:Has(realpathPath) then
            goto continue
        end
        seenFiles:Add(realpathPath)
        if fileName ~= realpathFileName then
            local symlinkPath = self.base.toPath(fileName)
            symlinks[realpathPath] = { path = symlinkPath, fileName = fileName }
            result.isSymlinked = true
        end
        do
            local file = self.host:GetSourceFile(realpathFileName, realpathPath)
            if file ~= nil then
                binder.BindSourceFile(file)
                rootFiles[#rootFiles + 1] = file
            end
        end
        ::continue::
    end

    local aliasResolver = autoimport.newAliasResolver(rootFiles, symlinks, self.host, resolver, self.base.toPath, function(source, moduleName)
        result.failedAmbientModuleLookupTargets:Add(moduleName)
        if result.failedAmbientModuleLookupSources[source:Path()] == nil then
            result.failedAmbientModuleLookupSources[source:Path()] = autoimport.newFailedAmbientModuleLookupSource(source:FileName())
        end
    end)

    local ch = checker.NewChecker(aliasResolver, nil)
    local extractor = self:newExportExtractor(packageName, ch, resolver, toRealpath)

    local nonModuleFiles = collections.NewSet()
    for _, entrypoint in ipairs(aliasResolver.rootFiles) do
        if autoimport.ctxErr(ctx) ~= nil then
            return nil
        end
        local fileExports = extractor:extractFromFile(entrypoint)
        for _, name in ipairs(entrypoint.ambientModuleNames or {}) do
            local list = result.ambientModules[name]
            if list == nil then
                list = {}
                result.ambientModules[name] = list
            end
            list[#list + 1] = entrypoint:FileName()
        end
        result.packageFiles[entrypoint:Path()] = entrypoint:FileName()
        local symlink = aliasResolver.symlinks and aliasResolver.symlinks[entrypoint:Path()]
        local hasSymlink = symlink ~= nil
        if hasSymlink then
            result.packageFiles[symlink.path] = symlink.fileName
        end

        local hasExports = core.Len(fileExports) > 0 and entrypoint.externalModuleIndicator ~= nil
        local source = result.failedAmbientModuleLookupSources[entrypoint:Path()]
        if source == nil then
            if result.exports[entrypoint:Path()] == nil then
                result.exportPaths[#result.exportPaths + 1] = entrypoint:Path()
            end
            result.exports[entrypoint:Path()] = fileExports or {}
        else
            source.packageName = packageName
            hasExports = entrypoint.externalModuleIndicator ~= nil
        end

        if not hasExports then
            nonModuleFiles:Add(entrypoint:Path())
            if hasSymlink then
                nonModuleFiles:Add(symlink.path)
            end
        end
    end

    -- Discard entrypoints for non-module files and empty modules.
    result.entrypoints = core.Filter(result.entrypoints, function(ep)
        return not nonModuleFiles:Has(self.base.toPath(ep.resolvedFileName))
    end)

    local stats = extractor:Stats()
    result.statsExports = stats.exports
    result.statsUsedChecker = stats.usedChecker
    return result
end

-- installExtractions aggregates pre-extracted per-package results into a single
-- packageExtractionResult for one bucket. This is the install phase of the three-phase pipeline.
function autoimport.installExtractions(discovered, extractionCache)
    local result = {
        exports = {},
        exportPaths = {},
        packageFiles = {},
        ambientModuleNames = {},
        entrypoints = nil,
        workspacePackages = collections.NewSet(),
        possibleFailedAmbientModuleLookupSources = collections.NewSyncMap(),
        possibleFailedAmbientModuleLookupTargets = collections.NewSyncSet(),
        stats = { exports = 0, usedChecker = 0 },
        skippedEntrypointsCount = 0,
    }

    for _, pkg in ipairs(discovered) do
        local extraction = extractionCache[pkg.realpath]
        if extraction == nil then
            extraction = extractionCache[pkg.typesRealpath]
        end
        if extraction == nil then
            goto continue
        end
        for _, path in ipairs(extraction.exportPaths) do
            if result.exports[path] == nil then
                result.exportPaths[#result.exportPaths + 1] = path
            end
            result.exports[path] = extraction.exports[path]
        end
        if result.packageFiles[pkg.packageName] == nil then
            result.packageFiles[pkg.packageName] = {}
        end
        for path, fileName in pairs(extraction.packageFiles) do
            result.packageFiles[pkg.packageName][path] = fileName
        end
        for _, name in ipairs(autoimport.sortedKeys(extraction.ambientModules)) do
            local list = result.ambientModuleNames[name]
            if list == nil then
                list = {}
                result.ambientModuleNames[name] = list
            end
            for _, fileName in ipairs(extraction.ambientModules[name]) do
                list[#list + 1] = fileName
            end
        end
        if extraction.entrypoints ~= nil then
            result.entrypoints = result.entrypoints or {}
            result.entrypoints[#result.entrypoints + 1] = extraction.entrypoints
        end
        for _, path in ipairs(autoimport.sortedKeys(extraction.failedAmbientModuleLookupSources)) do
            result.possibleFailedAmbientModuleLookupSources:LoadOrStore(path, extraction.failedAmbientModuleLookupSources[path])
        end
        for _, target in ipairs(setKeys(extraction.failedAmbientModuleLookupTargets)) do
            result.possibleFailedAmbientModuleLookupTargets:Add(target)
        end
        if extraction.isSymlinked and pkg.isLocal then
            result.workspacePackages:Add(pkg.packageName)
        end
        result.stats.exports = result.stats.exports + extraction.statsExports
        result.stats.usedChecker = result.stats.usedChecker + extraction.statsUsedChecker
        result.skippedEntrypointsCount = result.skippedEntrypointsCount + extraction.skippedEntrypoints
        ::continue::
    end

    return result
end

function registryBuilder:buildNodeModulesBucket(ctx, result, dependencies, dirPath, discovered, directoryPackageNames, extractionCache, recursiveSearchPackages, logger)
    if autoimport.ctxErr(ctx) ~= nil then
        result.err = autoimport.ctxErr(ctx)
        return
    end

    local extraction = autoimport.installExtractions(discovered, extractionCache)

    local indexStart = autoimport.timeNow()
    -- Build PackageFiles with all directory package names; indexed packages have
    -- non-nil maps, unindexed packages have nil maps.
    local allPackageFiles = {}
    for _, pkgName in ipairs(setKeys(directoryPackageNames)) do
        allPackageFiles[pkgName] = extraction.packageFiles[pkgName] or autoimport.nilPackageFiles
    end

    -- Build Paths as reverse mapping from path to package name.
    -- Only include paths for local workspace packages (eligible for granular updates).
    local paths = {}
    for _, pkgName in ipairs(setKeys(extraction.workspacePackages)) do
        local files = extraction.packageFiles[pkgName]
        if files ~= nil then
            for path in pairs(files) do
                paths[path] = pkgName
            end
        end
    end

    result.bucket = autoimport.newRegistryBucketStruct({
        index = autoimport.NewIndex(),
        dependencyNames = dependencies,
        packageFiles = allPackageFiles,
        ambientModuleNames = extraction.ambientModuleNames,
        paths = paths,
        state = autoimport.newBucketState({
            buildPreferences = autoimport.bucketBuildPreferencesFromUserPreferences(self.userPreferences),
            recursiveSearchPackages = Set.Clone(recursiveSearchPackages),
        }),
    })
    result.entrypoints = {}
    result.possibleFailedAmbientModuleLookupSources = extraction.possibleFailedAmbientModuleLookupSources
    result.possibleFailedAmbientModuleLookupTargets = extraction.possibleFailedAmbientModuleLookupTargets
    for _, path in ipairs(extraction.exportPaths) do
        for _, exp in ipairs(extraction.exports[path]) do
            result.bucket.index:insertAsWords(exp)
        end
    end
    for _, entrypointSet in ipairs(extraction.entrypoints or {}) do
        for _, entrypoint in ipairs(entrypointSet) do
            local path = self.base.toPath(entrypoint.resolvedFileName)
            local list = result.entrypoints[path]
            if list == nil then
                list = {}
                result.entrypoints[path] = list
            end
            list[#list + 1] = entrypoint
        end
    end

    -- Compute old entrypoint paths to remove from the registry-level map.
    -- For a full rebuild, all entrypoints belonging to the old bucket's packages must be removed.
    local oldEntry, ok = self.nodeModules:Get(dirPath)
    if ok then
        local oldBucket = oldEntry:Value()
        for _, pkgName in ipairs(autoimport.sortedKeys(oldBucket.packageFiles)) do
            for _, path in ipairs(autoimport.sortedKeys(oldBucket.packageFiles[pkgName])) do
                if mapGet(self.base.entrypoints, path) ~= nil then
                    result.removedEntrypointPaths = result.removedEntrypointPaths or {}
                    result.removedEntrypointPaths[#result.removedEntrypointPaths + 1] = path
                end
            end
        end
    end

    if logger ~= nil then
        logger:Logf("Installed %d exports (%d used checker)", extraction.stats.exports, extraction.stats.usedChecker)
        if extraction.skippedEntrypointsCount > 0 then
            logger:Logf("Skipped %d entrypoints due to exclude patterns", extraction.skippedEntrypointsCount)
        end
        logger:Logf("Built index: %s", autoimport.timeSince(indexStart))
    end

    result.err = autoimport.ctxErr(ctx)
end

-- updateNodeModulesBucket performs a granular update of the node_modules bucket,
-- re-extracting only the dirty packages and merging with the existing bucket.
function registryBuilder:updateNodeModulesBucket(ctx, result, existingBucket, dirtyPackages, discovered, extractionCache, recursiveSearchPackages, logger)
    if autoimport.ctxErr(ctx) ~= nil then
        result.err = autoimport.ctxErr(ctx)
        return
    end

    local start = autoimport.timeNow()
    local extraction = autoimport.installExtractions(discovered, extractionCache)

    local indexStart = autoimport.timeNow()

    -- Clone the existing index, excluding exports from dirty packages
    local newIndex = autoimport.Index.Clone(existingBucket.index, function(exp)
        return not dirtyPackages:Has(exp.packageName)
    end)

    -- Clone PackageFiles, removing dirty packages
    local newPackageFiles = {}
    for k, v in pairs(existingBucket.packageFiles or {}) do
        newPackageFiles[k] = v
    end
    for _, pkgName in ipairs(setKeys(dirtyPackages)) do
        newPackageFiles[pkgName] = nil
    end
    -- Add newly extracted package files
    for k, v in pairs(extraction.packageFiles) do
        newPackageFiles[k] = v
    end

    -- Clone Paths, removing dirty package paths
    local newPaths = {}
    for path, pkgName in pairs(existingBucket.paths or {}) do
        if not dirtyPackages:Has(pkgName) then
            newPaths[path] = pkgName
        end
    end
    -- Add paths for newly extracted workspace packages
    for _, pkgName in ipairs(setKeys(extraction.workspacePackages)) do
        local files = extraction.packageFiles[pkgName]
        if files ~= nil then
            for path in pairs(files) do
                newPaths[path] = pkgName
            end
        end
    end

    -- Clone AmbientModuleNames, removing dirty package entries
    local newAmbientModuleNames = {}
    for _, moduleName in ipairs(autoimport.sortedKeys(existingBucket.ambientModuleNames)) do
        local fileNames = existingBucket.ambientModuleNames[moduleName]
        -- Filter out files from dirty packages
        local filtered = {}
        for _, fileName in ipairs(fileNames) do
            local path = self.base.toPath(fileName)
            local pkgName = mapGet(existingBucket.paths, path)
            if not (pkgName ~= nil and dirtyPackages:Has(pkgName)) then
                filtered[#filtered + 1] = fileName
            end
        end
        if #filtered > 0 then
            newAmbientModuleNames[moduleName] = filtered
        end
    end
    -- Add newly extracted ambient module names
    for _, moduleName in ipairs(autoimport.sortedKeys(extraction.ambientModuleNames)) do
        local list = newAmbientModuleNames[moduleName]
        if list == nil then
            list = {}
            newAmbientModuleNames[moduleName] = list
        end
        for _, fileName in ipairs(extraction.ambientModuleNames[moduleName]) do
            list[#list + 1] = fileName
        end
    end

    -- Collect entrypoint paths that need to be removed from the registry-level map
    -- (paths belonging to dirty packages)
    local removedEntrypointPaths = nil
    for _, path in ipairs(autoimport.sortedKeys(self.base.entrypoints)) do
        local pkgName = mapGet(existingBucket.paths, path)
        if pkgName ~= nil and dirtyPackages:Has(pkgName) then
            removedEntrypointPaths = removedEntrypointPaths or {}
            removedEntrypointPaths[#removedEntrypointPaths + 1] = path
        end
    end
    -- Build new entrypoints from extraction
    local newEntrypoints = {}
    for _, entrypointSet in ipairs(extraction.entrypoints or {}) do
        for _, entrypoint in ipairs(entrypointSet) do
            local path = self.base.toPath(entrypoint.resolvedFileName)
            local list = newEntrypoints[path]
            if list == nil then
                list = {}
                newEntrypoints[path] = list
            end
            list[#list + 1] = entrypoint
        end
    end

    -- Insert newly extracted exports into the index
    for _, path in ipairs(extraction.exportPaths) do
        for _, exp in ipairs(extraction.exports[path]) do
            newIndex:insertAsWords(exp)
        end
    end

    result.bucket = autoimport.newRegistryBucketStruct({
        index = newIndex,
        dependencyNames = existingBucket.dependencyNames,
        packageFiles = newPackageFiles,
        ambientModuleNames = newAmbientModuleNames,
        paths = newPaths,
        state = autoimport.newBucketState({
            buildPreferences = autoimport.bucketBuildPreferencesFromUserPreferences(self.userPreferences),
            recursiveSearchPackages = Set.Clone(recursiveSearchPackages),
        }),
    })
    result.entrypoints = newEntrypoints
    result.removedEntrypointPaths = removedEntrypointPaths
    result.possibleFailedAmbientModuleLookupSources = extraction.possibleFailedAmbientModuleLookupSources
    result.possibleFailedAmbientModuleLookupTargets = extraction.possibleFailedAmbientModuleLookupTargets

    if logger ~= nil then
        logger:Logf("Granular update of %d packages: %s (%d exports)", dirtyPackages:Len(), autoimport.durationString(indexStart - start), extraction.stats.exports)
        logger:Logf("Built index: %s", autoimport.timeSince(indexStart))
    end

    result.err = autoimport.ctxErr(ctx)
end

function registryBuilder:getNearestAncestorDirectoryWithPackageJson(filePath)
    return (tspath.ForEachAncestorDirectoryPath(tspath.Path_GetDirectoryPath(filePath), function(dirPath)
        local dirEntry, ok = self.directories:Get(dirPath)
        if ok and dirEntry:Value().packageJson ~= nil and dirEntry:Value().packageJson:Exists() then
            return dirEntry:Value(), true
        end
        return nil, false
    end))
end

function registryBuilder:resolveAmbientModuleName(moduleName, fromPath)
    return (tspath.ForEachAncestorDirectoryPath(fromPath, function(dirPath)
        local bucket, ok = self.nodeModules:Get(dirPath)
        if ok then
            local fileNames = mapGet(bucket:Value().ambientModuleNames, moduleName)
            if fileNames ~= nil then
                return fileNames, true
            end
        end
        return nil, false
    end))
end
