local project = require("tslua.project")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")

local PendingReload = project.PendingReload

local ConfigFileRegistry = {}
ConfigFileRegistry.__index = ConfigFileRegistry
project.ConfigFileRegistry = ConfigFileRegistry

-- NewConfigFileRegistry returns the zero ConfigFileRegistry (Go &ConfigFileRegistry{}).
--   configs: map of config file paths to their entries.
--   configFileNames: map of open file paths to information about their ancestor config file names.
--   customConfigFileName: the custom config file name preference that was
--     used when building this registry's configFileNames cache.
function project.NewConfigFileRegistry()
    return setmetatable({
        configs = nil,
        configFileNames = nil,
        customConfigFileName = "",
        allConfiguredContentMappers = nil,
    }, ConfigFileRegistry)
end

-- configuredContentMappers: { extensions []string }
function project.collectConfiguredContentMappers(commandLines)
    local seenExtensions = collections.NewSet()
    local extensions = nil
    for _, commandLine in ipairs(commandLines or {}) do
        for _, mapper in ipairs(commandLine:ContentMappers() or {}) do
            for _, extension in ipairs(mapper.extensions or {}) do
                if seenExtensions:AddIfAbsent(extension) then
                    extensions = extensions or {}
                    extensions[#extensions + 1] = extension
                end
            end
        end
    end
    if extensions ~= nil then
        table.sort(extensions)
    end
    return { extensions = extensions }
end

function ConfigFileRegistry:contentMappers()
    if self.allConfiguredContentMappers ~= nil then
        return self.allConfiguredContentMappers
    end
    local commandLines = {}
    for _, path in ipairs(project.sortedKeys(self.configs)) do
        local entry = self.configs[path]
        if entry.commandLine ~= nil then
            commandLines[#commandLines + 1] = entry.commandLine
        end
    end
    return project.collectConfiguredContentMappers(commandLines)
end

-- configFileEntry:
--   fileName, pendingReload, commandLine
--   retainingProjects: the set of projects that have called acquireConfig
--     without releasing it. A config file entry may be acquired by a project
--     either because it is the config for that project or because it is the
--     config for a referenced project.
--   retainingOpenFiles: the set of open files that caused this config to
--     load during project collection building. This config file may or may not
--     end up being the config for the default project for these files, but
--     determining the default project loaded this config as a candidate, so
--     subsequent calls to `projectCollectionBuilder.findDefaultConfiguredProject`
--     will use this config as part of the search, so it must be retained.
--   retainingConfigs: the set of config files that extend this one. This
--     provides a cheap reverse mapping for a project config's
--     `commandLine.ExtendedSourceFiles()` that can be used to notify the
--     extending projects when this config changes. An extended config file may
--     or may not also be used directly by a project, so it's possible that
--     when this is set, no other fields will be used.
--   rootFilesWatch: a watch for the root files of this config file.
-- The retaining* sets are tables path -> true (nil for an empty Go nil map).
local configFileEntry = {}
configFileEntry.__index = configFileEntry
project.configFileEntry = configFileEntry

function project.newConfigFileEntry(hasRelativePatternCapability, fileName)
    return setmetatable({
        fileName = fileName,
        pendingReload = PendingReload.Full,
        commandLine = nil,
        retainingProjects = nil,
        retainingOpenFiles = nil,
        retainingConfigs = nil,
        rootFilesWatch = project.NewWatchedFiles(
            "root files for " .. fileName,
            lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete,
            hasRelativePatternCapability,
            core.Identity
        ),
    }, configFileEntry)
end

function project.newExtendedConfigFileEntry(fileName, extendingConfigPath)
    return setmetatable({
        fileName = fileName,
        pendingReload = PendingReload.Full,
        commandLine = nil,
        retainingProjects = nil,
        retainingOpenFiles = nil,
        retainingConfigs = { [extendingConfigPath] = true },
        rootFilesWatch = nil,
    }, configFileEntry)
end

function configFileEntry:Clone()
    return setmetatable({
        fileName = self.fileName,
        pendingReload = self.pendingReload,
        commandLine = self.commandLine,
        -- !!! eagerly cloning these maps makes everything more convenient,
        -- but it could be avoided if needed.
        retainingProjects = project.cloneMap(self.retainingProjects),
        retainingOpenFiles = project.cloneMap(self.retainingOpenFiles),
        retainingConfigs = project.cloneMap(self.retainingConfigs),
        rootFilesWatch = self.rootFilesWatch,
    }, configFileEntry)
end

function ConfigFileRegistry:GetConfig(path)
    local entry = self.configs ~= nil and self.configs[path] or nil
    if entry ~= nil then
        return entry.commandLine
    end
    return nil
end

function ConfigFileRegistry:isTracked(path)
    return self.configs ~= nil and self.configs[path] ~= nil
end

function ConfigFileRegistry:GetConfigFileName(path)
    local entry = self.configFileNames ~= nil and self.configFileNames[path] or nil
    if entry ~= nil then
        return entry.nearestConfigFileName
    end
    return ""
end

function ConfigFileRegistry:GetAncestorConfigFileName(path, higherThanConfig)
    local entry = self.configFileNames ~= nil and self.configFileNames[path] or nil
    if entry ~= nil then
        return entry.ancestors ~= nil and entry.ancestors[higherThanConfig] or ""
    end
    return ""
end

-- clone creates a shallow copy of the configFileRegistry.
function ConfigFileRegistry:clone()
    return setmetatable({
        configs = project.cloneMap(self.configs),
        configFileNames = project.cloneMap(self.configFileNames),
        customConfigFileName = self.customConfigFileName,
        allConfiguredContentMappers = self.allConfiguredContentMappers,
    }, ConfigFileRegistry)
end

-- TestConfigEntry (for testing): { fileName, retainingProjects, retainingOpenFiles, retainingConfigs }
-- where the retaining* fields are sorted arrays of paths (Go: iter.Seq).
local function newTestConfigEntry(entry)
    return {
        fileName = entry.fileName,
        retainingProjects = project.sortedKeys(entry.retainingProjects),
        retainingOpenFiles = project.sortedKeys(entry.retainingOpenFiles),
        retainingConfigs = project.sortedKeys(entry.retainingConfigs),
    }
end

-- For testing
function ConfigFileRegistry.ForEachTestConfigEntry(self, cb)
    if self ~= nil then
        for _, path in ipairs(project.sortedKeys(self.configs)) do
            cb(path, newTestConfigEntry(self.configs[path]))
        end
    end
end

-- For testing
function ConfigFileRegistry.GetTestConfigEntry(self, path)
    if self ~= nil then
        local entry = self.configs ~= nil and self.configs[path] or nil
        if entry ~= nil then
            return newTestConfigEntry(entry)
        end
    end
    return nil
end

-- TestConfigFileNamesEntry: { nearestConfigFileName, ancestors }

-- For testing
function ConfigFileRegistry.ForEachTestConfigFileNamesEntry(self, cb)
    if self ~= nil then
        for _, path in ipairs(project.sortedKeys(self.configFileNames)) do
            local entry = self.configFileNames[path]
            cb(path, {
                nearestConfigFileName = entry.nearestConfigFileName,
                ancestors = entry.ancestors,
            })
        end
    end
end

-- For testing
function ConfigFileRegistry.GetTestConfigFileNamesEntry(self, path)
    if self ~= nil then
        local entry = self.configFileNames ~= nil and self.configFileNames[path] or nil
        if entry ~= nil then
            return {
                nearestConfigFileName = entry.nearestConfigFileName,
                ancestors = entry.ancestors,
            }
        end
    end
    return nil
end

-- configFileNames:
--   nearestConfigFileName: the file name of the nearest ancestor config file.
--   ancestors: a map from one ancestor config file path to the next.
--   For example, if `/a`, `/a/b`, and `/a/b/c` all contain config files,
--   the fully loaded map will look like:
--		{
--			"/a/b/c/tsconfig.json": "/a/b/tsconfig.json",
--			"/a/b/tsconfig.json": "/a/tsconfig.json"
--		}
local configFileNames = {}
configFileNames.__index = configFileNames
project.configFileNames = configFileNames

function project.newConfigFileNames(nearestConfigFileName, ancestors)
    return setmetatable({ nearestConfigFileName = nearestConfigFileName or "", ancestors = ancestors }, configFileNames)
end

function configFileNames:Clone()
    return project.newConfigFileNames(self.nearestConfigFileName, project.cloneMap(self.ancestors))
end
