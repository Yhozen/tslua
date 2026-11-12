local project = require("tslua.project")
local collections = require("tslua.collections")
local core = require("tslua.core")
local dirty = require("tslua.project.dirty")
local logging = require("tslua.project.logging")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local lsproto = require("tslua.lsp.lsproto")

local PendingReload = project.PendingReload
local LogTree = logging.LogTree

-- configFileRegistryBuilder tracks changes made on top of a previous
-- configFileRegistry, producing a new clone with `finalize()` after
-- all changes have been made.
-- Implements tsoptions.ParseConfigHost and tsoptions.ExtendedConfigCache.
local configFileRegistryBuilder = {}
configFileRegistryBuilder.__index = configFileRegistryBuilder
project.configFileRegistryBuilder = configFileRegistryBuilder

function project.newConfigFileRegistryBuilder(
    hasRelativePatternCapability,
    fs,
    oldConfigFileRegistry,
    extendedConfigCache,
    snapshotID,
    sessionOptions,
    customConfigFileName,
    logger
)
    return setmetatable({
        hasRelativePatternCapability = hasRelativePatternCapability,
        fs = project.newSourceFS(false, fs, fs.toPath),
        isOpenFile = function(path)
            return fs:isOpenFile(path)
        end,
        base = oldConfigFileRegistry,
        sessionOptions = sessionOptions,
        extendedConfigCache = extendedConfigCache,
        snapshotID = snapshotID,
        customConfigFileName = customConfigFileName,
        customConfigFileNameChanged = customConfigFileName ~= oldConfigFileRegistry.customConfigFileName,
        allConfiguredContentMappers = oldConfigFileRegistry:contentMappers(),

        configs = dirty.NewSyncMap(oldConfigFileRegistry.configs),
        configFileNames = dirty.NewMap(oldConfigFileRegistry.configFileNames),
    }, configFileRegistryBuilder)
end

-- Finalize creates a new configFileRegistry based on the changes made in the builder.
-- If no changes were made, it returns the original base registry.
function configFileRegistryBuilder:Finalize()
    local changed = false
    local newRegistry = self.base
    local function ensureCloned()
        if not changed then
            newRegistry = newRegistry:clone()
            changed = true
        end
    end

    local configs, changedConfigs = self.configs:Finalize()
    if changedConfigs then
        ensureCloned()
        newRegistry.configs = configs
        newRegistry.allConfiguredContentMappers = self:contentMappers()
    end

    local configFileNames, changedNames = self.configFileNames:Finalize()
    if changedNames then
        ensureCloned()
        newRegistry.configFileNames = configFileNames
    end

    if self.customConfigFileNameChanged then
        ensureCloned()
        newRegistry.customConfigFileName = self.customConfigFileName
    end

    return newRegistry
end

function configFileRegistryBuilder:contentMappers()
    if self.allConfiguredContentMappers == nil then
        local commandLines = {}
        self.configs:Range(function(entry)
            local commandLine = entry:Value().commandLine
            if commandLine ~= nil then
                commandLines[#commandLines + 1] = commandLine
            end
            return true
        end)
        self.allConfiguredContentMappers = project.collectConfiguredContentMappers(commandLines)
    end
    return self.allConfiguredContentMappers
end

function configFileRegistryBuilder:invalidateContentMappers()
    self.allConfiguredContentMappers = nil
end

function configFileRegistryBuilder:findOrAcquireConfigForFile(configFileName, configFilePath, filePath, loadKind, logger)
    if loadKind == project.projectLoadKind.Find then
        local entry, ok = self.configs:Load(configFilePath)
        if ok then
            return entry:Value().commandLine
        end
        return nil
    elseif loadKind == project.projectLoadKind.Create then
        return self:acquireConfigForFile(configFileName, configFilePath, filePath, logger)
    end
    error(string.format("unknown project load kind: %d", loadKind), 0)
end

-- reloadIfNeeded updates the command line of the config file entry based on its
-- pending reload state. This function should only be called from within the
-- Change() method of a dirty map entry.
function configFileRegistryBuilder:reloadIfNeeded(entry, fileName, path, logger)
    local oldCommandLine = entry.commandLine
    if entry.pendingReload == PendingReload.FileNames then
        LogTree.Log(logger, "Reloading file names for config: " .. fileName)
        entry.commandLine = entry.commandLine:ReloadFileNamesOfParsedCommandLine(self.fs)
    elseif entry.pendingReload == PendingReload.Full then
        LogTree.Log(logger, "Loading config file: " .. fileName)
        -- When the workspace is trusted, enable external content mappers so a config's contentMappers pass
        -- the runExternalCode gate and register, as they would with the CLI flag.
        local existingOptions = nil
        if self.sessionOptions.runExternalCode then
            existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue })
        end
        entry.commandLine = tsoptions.GetParsedCommandLineOfConfigFilePath(fileName, path, existingOptions, nil, self, self)
        self:updateExtendingConfigs(path, entry.commandLine, oldCommandLine)
        self:updateRootFilesWatch(fileName, entry)
        LogTree.Log(logger, "Finished loading config file")
    else
        return false
    end
    entry.pendingReload = PendingReload.None
    return oldCommandLine ~= entry.commandLine
end

function configFileRegistryBuilder:updateExtendingConfigs(extendingConfigPath, newCommandLine, oldCommandLine)
    local newExtendedConfigPaths = collections.NewSet()
    if newCommandLine ~= nil then
        for _, extendedConfig in ipairs(newCommandLine:ExtendedSourceFiles() or {}) do
            local extendedConfigPath = self.fs.toPath(extendedConfig)
            newExtendedConfigPaths:Add(extendedConfigPath)
            local entry, loaded = self.configs:LoadOrStore(extendedConfigPath, project.newExtendedConfigFileEntry(extendedConfig, extendingConfigPath))
            if loaded then
                entry:ChangeIf(
                    function(config)
                        local alreadyRetaining = config.retainingConfigs ~= nil and config.retainingConfigs[extendingConfigPath] ~= nil
                        return not alreadyRetaining
                    end,
                    function(config)
                        if config.retainingConfigs == nil then
                            config.retainingConfigs = {}
                        end
                        config.retainingConfigs[extendingConfigPath] = true
                    end
                )
            end
        end
    end
    if oldCommandLine ~= nil then
        for _, extendedConfig in ipairs(oldCommandLine:ExtendedSourceFiles() or {}) do
            local extendedConfigPath = self.fs.toPath(extendedConfig)
            if newExtendedConfigPaths:Has(extendedConfigPath) then
                goto continue
            end
            do
                local entry, ok = self.configs:Load(extendedConfigPath)
                if ok then
                    entry:ChangeIf(
                        function(config)
                            return config.retainingConfigs ~= nil and config.retainingConfigs[extendingConfigPath] ~= nil
                        end,
                        function(config)
                            config.retainingConfigs[extendingConfigPath] = nil
                        end
                    )
                end
            end
            ::continue::
        end
    end
end

function configFileRegistryBuilder:updateRootFilesWatch(fileName, entry)
    if entry.rootFilesWatch == nil then
        return
    end

    local ignored = nil
    local globs = {}
    local externalDirectories = {}
    local includeWorkspace = false
    local includeTsconfigDir = false
    local tsconfigDir = tspath.GetDirectoryPath(fileName)
    local wildcardDirectories = tsoptions.ParsedCommandLine.WildcardDirectories(entry.commandLine)
    local comparePathsOptions = {
        currentDirectory = self.sessionOptions.currentDirectory,
        useCaseSensitiveFileNames = self:FS():UseCaseSensitiveFileNames(),
    }
    for _, dir in ipairs(project.sortedKeys(wildcardDirectories)) do
        if tspath.ContainsPath(self.sessionOptions.currentDirectory, dir, comparePathsOptions) then
            includeWorkspace = true
        elseif tspath.ContainsPath(tsconfigDir, dir, comparePathsOptions) then
            includeTsconfigDir = true
        else
            externalDirectories[#externalDirectories + 1] = dir
        end
    end
    for _, literalFileName in ipairs(tsoptions.ParsedCommandLine.LiteralFileNames(entry.commandLine) or {}) do
        if tspath.ContainsPath(self.sessionOptions.currentDirectory, literalFileName, comparePathsOptions) then
            includeWorkspace = true
        elseif tspath.ContainsPath(tsconfigDir, literalFileName, comparePathsOptions) then
            includeTsconfigDir = true
        else
            externalDirectories[#externalDirectories + 1] = tspath.GetDirectoryPath(literalFileName)
        end
    end

    if includeWorkspace then
        globs[#globs + 1] = project.getRecursiveGlobPattern(self.sessionOptions.currentDirectory)
    end
    if includeTsconfigDir then
        globs[#globs + 1] = project.getRecursiveGlobPattern(tsconfigDir)
    end
    for _, extendedFileName in ipairs(tsoptions.ParsedCommandLine.ExtendedSourceFiles(entry.commandLine) or {}) do
        if includeWorkspace and tspath.ContainsPath(self.sessionOptions.currentDirectory, extendedFileName, comparePathsOptions) then
            goto continue
        end
        globs[#globs + 1] = extendedFileName
        ::continue::
    end
    if #externalDirectories > 0 then
        local commonParents, ignoredExternalDirs = tspath.GetCommonParents(externalDirectories, project.minWatchLocationDepth, project.getPathComponentsForWatching, comparePathsOptions)
        for _, parent in ipairs(commonParents or {}) do
            globs[#globs + 1] = project.getRecursiveGlobPattern(parent)
        end
        ignored = ignoredExternalDirs
    end

    table.sort(globs)
    entry.rootFilesWatch = entry.rootFilesWatch:Clone(project.NewPatternsAndIgnored(nil, globs, ignored))
end

-- acquireConfigForProject loads a config file entry from the cache, or parses it if not already
-- cached, then adds the project (if provided) to `retainingProjects` to keep it alive
-- in the cache. Each `acquireConfigForProject` call that passes a `project` should be accompanied
-- by an eventual `releaseConfigForProject` call with the same project.
function configFileRegistryBuilder:acquireConfigForProject(fileName, path, p, logger)
    local entry = self.configs:LoadOrStore(path, project.newConfigFileEntry(self.hasRelativePatternCapability, fileName))
    local needsRetainProject = false
    local contentMappersChanged = false
    entry:ChangeIf(
        function(config)
            local alreadyRetaining = config.retainingProjects ~= nil and config.retainingProjects[p.configFilePath] ~= nil
            needsRetainProject = not alreadyRetaining
            return needsRetainProject or config.pendingReload ~= PendingReload.None
        end,
        function(config)
            if needsRetainProject then
                if config.retainingProjects == nil then
                    config.retainingProjects = {}
                end
                config.retainingProjects[p.configFilePath] = true
            end
            contentMappersChanged = self:reloadIfNeeded(config, fileName, path, logger)
        end
    )
    if contentMappersChanged then
        self:invalidateContentMappers()
    end
    return entry:Value().commandLine
end

-- acquireConfigForFile loads a config file entry from the cache, or parses it if not already
-- cached, then adds the open file to `retainingOpenFiles` to keep it alive in the cache.
-- Each `acquireConfigForFile` call that passes an `openFilePath`
-- should be accompanied by an eventual `releaseConfigForOpenFile` call with the same open file.
function configFileRegistryBuilder:acquireConfigForFile(configFileName, configFilePath, filePath, logger)
    local entry = self.configs:LoadOrStore(configFilePath, project.newConfigFileEntry(self.hasRelativePatternCapability, configFileName))
    local needsRetainOpenFile = false
    local contentMappersChanged = false
    entry:ChangeIf(
        function(config)
            if self.isOpenFile(filePath) then
                local alreadyRetaining = config.retainingOpenFiles ~= nil and config.retainingOpenFiles[filePath] ~= nil
                needsRetainOpenFile = not alreadyRetaining
            end
            return needsRetainOpenFile or config.pendingReload ~= PendingReload.None
        end,
        function(config)
            if needsRetainOpenFile then
                if config.retainingOpenFiles == nil then
                    config.retainingOpenFiles = {}
                end
                config.retainingOpenFiles[filePath] = true
            end
            contentMappersChanged = self:reloadIfNeeded(config, configFileName, configFilePath, logger)
        end
    )
    if contentMappersChanged then
        self:invalidateContentMappers()
    end
    return entry:Value().commandLine
end

-- releaseConfigForProject removes the project from the config entry. Once no projects
-- or files are associated with the config entry, it will be removed on the next call to `cleanup`.
function configFileRegistryBuilder:releaseConfigForProject(configFilePath, projectPath)
    local entry, ok = self.configs:Load(configFilePath)
    if ok then
        entry:ChangeIf(
            function(config)
                return config.retainingProjects ~= nil and config.retainingProjects[projectPath] ~= nil
            end,
            function(config)
                config.retainingProjects[projectPath] = nil
            end
        )
    end
end

-- didCloseFile removes the open file from the config entry. Once no projects
-- or files are associated with the config entry, it will be removed on the next call to `cleanup`.
function configFileRegistryBuilder:didCloseFile(path)
    if tspath.IsDynamicFileName(path) then
        return
    end
    self.configFileNames:Delete(path)
    self.configs:Range(function(entry)
        entry:ChangeIf(
            function(config)
                return config.retainingOpenFiles ~= nil and config.retainingOpenFiles[path] ~= nil
            end,
            function(config)
                config.retainingOpenFiles[path] = nil
            end
        )
        return true
    end)
end

-- changeFileResult: { affectedProjects = path set or nil, affectedFiles = path set or nil }
function project.changeFileResult_IsEmpty(r)
    return next(r.affectedProjects or {}) == nil and next(r.affectedFiles or {}) == nil
end

function configFileRegistryBuilder:DidChangeCustomConfigFileName(logger)
    if not self.customConfigFileNameChanged then
        return false
    end

    self.configFileNames:Clear()
    return true
end

function configFileRegistryBuilder:invalidateCache(logger)
    local affectedProjects = nil
    local affectedFiles = nil

    LogTree.Log(logger, "Too many files changed; marking all configs for reload")
    self.configFileNames:Range(function(entry)
        if affectedFiles == nil then
            affectedFiles = {}
        end
        affectedFiles[entry:Key()] = true
        return true
    end)
    self.configFileNames:Clear()

    self.configs:Range(function(e)
        e:Change(function(entry)
            affectedProjects = core.CopyMapInto(affectedProjects, entry.retainingProjects)
            if entry.pendingReload ~= PendingReload.Full then
                local text, ok = self:FS():ReadFile(entry.fileName)
                if not ok or entry.commandLine == nil or text ~= entry.commandLine.configFile.sourceFile:Text() then
                    entry.pendingReload = PendingReload.Full
                else
                    entry.pendingReload = PendingReload.FileNames
                end
            end
        end)
        return true
    end)

    return {
        affectedProjects = affectedProjects,
        affectedFiles = affectedFiles,
    }
end

function configFileRegistryBuilder:isConfigBaseName(baseName)
    return baseName == "tsconfig.json" or baseName == "jsconfig.json" or
        (self.customConfigFileName ~= "" and baseName == self.customConfigFileName)
end

function configFileRegistryBuilder:DidChangeFiles(summary, logger)
    local affectedProjects = nil
    local affectedFiles = nil
    local shouldInvalidateCache = false

    LogTree.Log(logger, "Summarizing file changes")
    local hasExcessiveChanges = project.FileChangeSummary_HasExcessiveWatchEvents(summary) and summary.includesWatchChangeOutsideNodeModules
    local createdFiles = {}
    local deletedFiles = {}
    local createdOrDeletedConfigFiles = {}
    local createdOrChangedOrDeletedFiles = {}
    for uri in pairs(project.setKeys(summary.changed)) do
        if tspath.ContainsIgnoredPath(uri) then
            goto continue
        end
        do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local path = self.fs.toPath(fileName)
            local baseName = tspath.GetBaseFileName(path)
            if self:isConfigBaseName(baseName) then
                createdOrDeletedConfigFiles[path] = true
            end
            createdOrChangedOrDeletedFiles[path] = true
        end
        ::continue::
    end
    for uri in pairs(project.setKeys(summary.deleted)) do
        if tspath.ContainsIgnoredPath(uri) then
            goto continue
        end
        do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local path = self.fs.toPath(fileName)
            deletedFiles[path] = fileName
            local baseName = tspath.GetBaseFileName(path)
            if self:isConfigBaseName(baseName) then
                createdOrDeletedConfigFiles[path] = true
            end
            createdOrChangedOrDeletedFiles[path] = true
        end
        ::continue::
    end
    for uri in pairs(project.setKeys(summary.created)) do
        if tspath.ContainsIgnoredPath(uri) then
            goto continue
        end
        do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local path = self.fs.toPath(fileName)
            createdFiles[path] = fileName
            local baseName = tspath.GetBaseFileName(path)
            if self:isConfigBaseName(baseName) then
                createdOrDeletedConfigFiles[path] = true
            end
            createdOrChangedOrDeletedFiles[path] = true
        end
        ::continue::
    end

    -- Handle closed files - this ranges over config entries and could be combined
    -- with the file change handling, but a separate loop is simpler and a snapshot
    -- change with both closing and watch changes seems rare.
    for uri in pairs(project.setKeys(summary.closed)) do
        local fileName = lsproto.DocumentUri_FileName(uri)
        local path = self.fs.toPath(fileName)
        self:didCloseFile(path)
    end

    -- Handle changes to stored config files and their content mapper package manifests.
    LogTree.Log(logger, "Checking if any changed files are configuration files")
    for _, path in ipairs(project.sortedKeys(createdOrChangedOrDeletedFiles)) do
        local entry, ok = self.configs:Load(path)
        if ok then
            if hasExcessiveChanges then
                return self:invalidateCache(logger)
            end

            affectedProjects = core.CopyMapInto(affectedProjects, self:handleConfigChange(entry, logger))
            for extendingConfigPath in pairs(entry:Value().retainingConfigs or {}) do
                local extendingConfigEntry, ok2 = self.configs:Load(extendingConfigPath)
                if ok2 then
                    affectedProjects = core.CopyMapInto(affectedProjects, self:handleConfigChange(extendingConfigEntry, logger))
                end
            end
            -- This was a config file, so assume it's not also a root file
            createdFiles[path] = nil
        elseif tspath.GetBaseFileName(path) == "package.json" then
            local manifestChanged = false
            self.configs:Range(function(e)
                if project.contentMapperManifestPath(e:Value().commandLine, self.fs.toPath, path) then
                    affectedProjects = core.CopyMapInto(affectedProjects, self:handleConfigChange(e, logger))
                    manifestChanged = true
                end
                return true
            end)
            if manifestChanged then
                self:invalidateContentMappers()
            end
        end
    end

    -- Handle created/deleted files named "tsconfig.json" or "jsconfig.json"
    for _, path in ipairs(project.sortedKeys(createdOrDeletedConfigFiles)) do
        if hasExcessiveChanges then
            return self:invalidateCache(logger)
        end
        local directoryPath = tspath.Path_GetDirectoryPath(path)
        self.configFileNames:Range(function(entry)
            if tspath.Path_ContainsPath(directoryPath, entry:Key()) then
                if affectedFiles == nil then
                    affectedFiles = {}
                end
                affectedFiles[entry:Key()] = true
                entry:Delete()
            end
            return true
        end)
    end

    -- Handle deletions of wildcard-included root files
    for _, path in ipairs(project.sortedKeys(deletedFiles)) do
        local fileName = deletedFiles[path]
        self.configs:Range(function(entry)
            entry:ChangeIf(
                function(config)
                    if config.pendingReload ~= PendingReload.None or config.commandLine == nil then
                        return false
                    end
                    if config.commandLine:FileNamesByPath()[path] ~= nil then
                        -- If the file is included in FileNames() but not matched by literal "files", it must be
                        -- included via wildcard, which means a reload of filenames will remove it from the list.
                        -- (Files explicitly specified in "files" are always included in the ParsedCommandLine,
                        -- triggering a missing root file error during program construction.)
                        return config.commandLine:GetMatchedFileSpec(fileName) == ""
                    end
                    return false
                end,
                function(config)
                    config.pendingReload = PendingReload.FileNames
                    if affectedProjects == nil then
                        affectedProjects = {}
                    end
                    for k in pairs(config.retainingProjects or {}) do
                        affectedProjects[k] = true
                    end
                    LogTree.Logf(logger, "Root files for config %s changed", entry:Key())
                    shouldInvalidateCache = hasExcessiveChanges
                end
            )
            return not shouldInvalidateCache
        end)
        if shouldInvalidateCache then
            return self:invalidateCache(logger)
        end
    end

    -- Handle possible root file creation
    if next(createdFiles) ~= nil then
        local createdPaths = project.sortedKeys(createdFiles)
        self.configs:Range(function(entry)
            entry:ChangeIf(
                function(config)
                    if config.commandLine == nil or config.rootFilesWatch == nil or config.pendingReload ~= PendingReload.None then
                        return false
                    end
                    LogTree.Logf(logger, "Checking if any of %d created files match root files for config %s", #createdPaths, entry:Key())
                    for _, path in ipairs(createdPaths) do
                        local fileName = createdFiles[path]
                        if config.commandLine:PossiblyMatchesFileName(fileName) then
                            return true
                        end
                        if config.commandLine:PossiblyMatchesDirectoryName(path) and self.fs:DirectoryExists(fileName) then
                            -- If we got a creation event for a directory, it's probably a symlink. We don't need to
                            -- test realpath here; this is enough confidence to trigger a filename reload.
                            return true
                        end
                    end
                    return false
                end,
                function(config)
                    config.pendingReload = PendingReload.FileNames
                    if affectedProjects == nil then
                        affectedProjects = {}
                    end
                    for k in pairs(config.retainingProjects or {}) do
                        affectedProjects[k] = true
                    end
                    LogTree.Logf(logger, "Root files for config %s changed", entry:Key())
                    shouldInvalidateCache = hasExcessiveChanges
                end
            )
            return not shouldInvalidateCache
        end)
        if shouldInvalidateCache then
            return self:invalidateCache(logger)
        end
    end

    return {
        affectedProjects = affectedProjects,
        affectedFiles = affectedFiles,
    }
end

function configFileRegistryBuilder:handleConfigChange(entry, logger)
    local affectedProjects = nil
    local changed = entry:ChangeIf(
        function(config) return config.pendingReload ~= PendingReload.Full end,
        function(config) config.pendingReload = PendingReload.Full end
    )
    if changed then
        LogTree.Logf(logger, "Config file %s changed", entry:Key())
        affectedProjects = project.cloneMap(entry:Value().retainingProjects)
    end

    return affectedProjects
end

function project.contentMapperManifestPath(commandLine, toPath, path)
    if commandLine == nil then
        return false
    end
    for _, mapper in ipairs(commandLine:ContentMappers() or {}) do
        if (mapper.package or "") ~= "" and (mapper.contributionID or "") == "" and (mapper.packageDirectory or "") ~= "" and
            toPath(tspath.CombinePaths(mapper.packageDirectory, "package.json")) == path then
            return true
        end
    end
    return false
end

function configFileRegistryBuilder:computeConfigFileName(fileName, skipSearchInDirectoryOfFile, logger)
    local searchPath = tspath.GetDirectoryPath(fileName)
    -- Prefer custom config file if provided; search ancestors with correct skip behavior.
    if self.customConfigFileName ~= "" then
        local skip = skipSearchInDirectoryOfFile
        local result = tspath.ForEachAncestorDirectory(searchPath, function(directory)
            if not skip then
                local customPath = tspath.CombinePaths(directory, self.customConfigFileName)
                if self:FS():FileExists(customPath) then
                    return customPath, true
                end
            end
            if project.hasSuffix(directory, "/node_modules") then
                return "", true
            end
            skip = false
            return "", false
        end)
        if result ~= "" then
            LogTree.Logf(logger, "computeConfigFileName:: File: %s:: Result: %s", fileName, result)
            return result
        end
    end

    -- When searching for ancestor of a config file, determine which config types to skip
    -- in the starting directory. This matches TSServer's forEachConfigFileLocation behavior:
    -- - For ancestor of tsconfig.json: skip tsconfig.json but still check jsconfig.json
    -- - For ancestor of jsconfig.json: skip both tsconfig.json and jsconfig.json
    local skipTsconfig = skipSearchInDirectoryOfFile
    local skipJsconfig = skipSearchInDirectoryOfFile and not project.hasSuffix(fileName, "/tsconfig.json")
    local result = tspath.ForEachAncestorDirectory(searchPath, function(directory)
        if not skipTsconfig then
            local tsconfigPath = tspath.CombinePaths(directory, "tsconfig.json")
            if self:FS():FileExists(tsconfigPath) then
                return tsconfigPath, true
            end
        end
        if not skipJsconfig then
            local jsconfigPath = tspath.CombinePaths(directory, "jsconfig.json")
            if self:FS():FileExists(jsconfigPath) then
                return jsconfigPath, true
            end
        end
        if project.hasSuffix(directory, "/node_modules") then
            return "", true
        end
        skipTsconfig = false
        skipJsconfig = false
        return "", false
    end)
    LogTree.Logf(logger, "computeConfigFileName:: File: %s:: Result: %s", fileName, result)
    return result
end

function configFileRegistryBuilder:getConfigFileNameForFile(fileName, path, logger)
    if tspath.IsDynamicFileName(fileName) then
        return ""
    end

    local entry, ok = self.configFileNames:Get(path)
    if ok then
        return entry:Value().nearestConfigFileName
    end

    local configName = self:computeConfigFileName(fileName, false, logger)
    if self.isOpenFile(path) then
        self.configFileNames:Add(path, project.newConfigFileNames(configName, nil))
    end
    return configName
end

function configFileRegistryBuilder:forEachConfigFileNameFor(path, cb)
    if tspath.IsDynamicFileName(path) then
        return
    end

    local entry, ok = self.configFileNames:Get(path)
    if ok then
        local configFileName = entry:Value().nearestConfigFileName
        while configFileName ~= "" do
            cb(configFileName)
            local ancestors = entry:Value().ancestors
            local ancestorConfigName = ancestors ~= nil and ancestors[configFileName] or nil
            if ancestorConfigName ~= nil then
                configFileName = ancestorConfigName
            else
                return
            end
        end
    end
end

function configFileRegistryBuilder:getAncestorConfigFileName(fileName, path, configFileName, logger)
    if tspath.IsDynamicFileName(fileName) then
        return ""
    end

    local entry, ok = self.configFileNames:Get(path)
    if not ok then
        return ""
    end

    local ancestors = entry:Value().ancestors
    local ancestorConfigName = ancestors ~= nil and ancestors[configFileName] or nil
    if ancestorConfigName ~= nil then
        return ancestorConfigName
    end

    -- Look for config in parent folders of config file
    local result = self:computeConfigFileName(configFileName, true, logger)

    if self.isOpenFile(path) then
        entry:Change(function(value)
            if value.ancestors == nil then
                value.ancestors = {}
            end
            value.ancestors[configFileName] = result
        end)
    end
    return result
end

-- FS implements tsoptions.ParseConfigHost.
function configFileRegistryBuilder:FS()
    return self.fs
end

-- GetCurrentDirectory implements tsoptions.ParseConfigHost.
function configFileRegistryBuilder:GetCurrentDirectory()
    return self.sessionOptions.currentDirectory
end

-- GetExtendedConfig implements tsoptions.ExtendedConfigCache.
function configFileRegistryBuilder:GetExtendedConfig(fileName, path, resolutionStack, host)
    local content = ""
    local fh = self.fs:GetFileByPath(fileName, path)
    if fh ~= nil then
        content = fh:Content()
    end

    return self.extendedConfigCache:LoadAndAcquire(path, self.snapshotID, {
        fileName = fileName,
        content = content,
        fs = self.fs.source,
        resolutionStack = resolutionStack,
        host = host,
        cache = self,
    }).extendedConfigCacheEntry
end

function configFileRegistryBuilder:Cleanup()
    local changed = false
    self.configs:Range(function(entry)
        entry:DeleteIf(function(value)
            local shouldDelete = next(value.retainingProjects or {}) == nil and next(value.retainingOpenFiles or {}) == nil and next(value.retainingConfigs or {}) == nil
            changed = changed or shouldDelete
            return shouldDelete
        end)
        return true
    end)
    if changed then
        self:invalidateContentMappers()
    end
end
