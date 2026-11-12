local project = require("tslua.project")
local collections = require("tslua.collections")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local tspath = require("tslua.tspath")

project.minWatchLocationDepth = 2

-- fileSystemWatcherKey: pattern .. "\0" .. kind (string encoding of the Go struct key)
-- fileSystemWatcherValue: { count, id }

-- watchRegistry tracks the current watch globs and how many individual
-- WatchedFiles reference each glob. It provides ref-count helpers so callers
-- don't manipulate the map directly.
local watchRegistry = {}
watchRegistry.__index = watchRegistry
project.watchRegistry = watchRegistry

function project.newWatchRegistry()
    return setmetatable({ entries = {}, pending = {} }, watchRegistry)
end

-- Acquire increments the ref count for a watcher. If this is the first
-- reference (count goes from 0 to 1), it returns true so the caller knows
-- to register the watcher with the client.
function watchRegistry:Acquire(watcher, id)
    local key = project.toFileSystemWatcherKey(watcher)
    local value = self.entries[key]
    if value == nil then
        value = { count = 0, id = id }
        self.entries[key] = value
    end
    value.count = value.count + 1
    return value.count == 1
end

-- Release decrements the ref count for a watcher. If no references remain,
-- the entry is removed and the function returns the WatcherID and true so
-- the caller knows to unregister the watcher from the client.
-- Returns (id, removed).
function watchRegistry:Release(watcher)
    local key = project.toFileSystemWatcherKey(watcher)
    local value = self.entries[key]
    if value == nil then
        return "", false
    end
    if value.count <= 1 then
        self.entries[key] = nil
        return value.id, true
    end
    value.count = value.count - 1
    return "", false
end

-- MarkPending records that a watcher's registration failed and needs retry.
function watchRegistry:MarkPending(id)
    self.pending[id] = true
end

-- ClearPending removes a watcher from the pending set after successful registration.
function watchRegistry:ClearPending(id)
    self.pending[id] = nil
end

-- IsPending returns true if the watcher needs retry due to a previous failure.
function watchRegistry:IsPending(id)
    return self.pending[id] ~= nil
end

-- PatternsAndIgnored: { directoriesOutsideWorkspace, patternsInsideWorkspace, ignored (set) }
function project.NewPatternsAndIgnored(directoriesOutsideWorkspace, patternsInsideWorkspace, ignored)
    return {
        directoriesOutsideWorkspace = directoriesOutsideWorkspace,
        patternsInsideWorkspace = patternsInsideWorkspace,
        ignored = ignored,
    }
end

-- toFileSystemWatcherKey produces a deduplication key for a file system watcher.
-- Note: this key is a simple string concatenation of the base and pattern, so
-- structurally different watchers (Pattern vs RelativePattern, URI vs WorkspaceFolder)
-- could theoretically collide. In practice, workspace watchers use plain Pattern
-- with filesystem paths while outside-workspace watchers use RelativePattern with
-- file:// URIs, so collisions don't occur.
function project.toFileSystemWatcherKey(w)
    local kind = w.kind
    if kind == nil then
        kind = lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete
    end
    local pattern = ""
    if w.globPattern.pattern ~= nil then
        pattern = w.globPattern.pattern
    elseif w.globPattern.relativePattern ~= nil then
        local base = ""
        if w.globPattern.relativePattern.baseUri.uri ~= nil then
            base = w.globPattern.relativePattern.baseUri.uri
        elseif w.globPattern.relativePattern.baseUri.workspaceFolder ~= nil then
            error("workspace folder-based relative patterns not implemented", 0)
        end
        pattern = base .. "/" .. w.globPattern.relativePattern.pattern
    end
    return pattern .. "\0" .. tostring(kind)
end

function project.fileSystemWatcherGlobString(w)
    if w.globPattern.pattern ~= nil then
        return w.globPattern.pattern
    end
    if w.globPattern.relativePattern ~= nil then
        local base = ""
        if w.globPattern.relativePattern.baseUri.uri ~= nil then
            base = w.globPattern.relativePattern.baseUri.uri
        elseif w.globPattern.relativePattern.baseUri.workspaceFolder ~= nil then
            error("workspace folder-based relative patterns not implemented", 0)
        end
        return base .. "/" .. w.globPattern.relativePattern.pattern
    end
    return ""
end

-- WatcherID is a string.

project.watcherID = 0

local function nextWatcherID()
    project.watcherID = project.watcherID + 1
    return project.watcherID
end

-- WatchedFiles: { name, watchKind, hasRelativePatternCapability, computeGlobPatterns, input,
--   computeWatchersOnce, workspaceWatchers, outsideWorkspaceWatchers, ignored, id }
local WatchedFiles = {}
WatchedFiles.__index = WatchedFiles
project.WatchedFiles = WatchedFiles

function project.NewWatchedFiles(name, watchKind, hasRelativePatternCapability, computeGlobPatterns)
    return setmetatable({
        id = nextWatcherID(),
        name = name,
        watchKind = watchKind,
        hasRelativePatternCapability = hasRelativePatternCapability,
        computeGlobPatterns = computeGlobPatterns,
        input = nil,
        computeWatchersOnce = false,
        workspaceWatchers = nil,
        outsideWorkspaceWatchers = nil,
        ignored = nil,
    }, WatchedFiles)
end

-- NewWatchedFilesForPaths creates a watcher for exact file paths, routing files outside the workspace
-- through directory-based external watchers so clients can use URI-based RelativePatterns when supported.
function project.NewWatchedFilesForPaths(name, watchKind, hasRelativePatternCapability, workspaceDirectory, currentDirectory, useCaseSensitiveFileNames)
    local comparePathsOptions = {
        currentDirectory = currentDirectory,
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
    }
    return project.NewWatchedFiles(name, watchKind, hasRelativePatternCapability, function(files)
        local result = project.NewPatternsAndIgnored(nil, nil, nil)
        for _, file in ipairs(files or {}) do
            if tspath.ContainsPath(workspaceDirectory, file, comparePathsOptions) then
                result.patternsInsideWorkspace = result.patternsInsideWorkspace or {}
                result.patternsInsideWorkspace[#result.patternsInsideWorkspace + 1] = file
            else
                result.directoriesOutsideWorkspace = result.directoriesOutsideWorkspace or {}
                result.directoriesOutsideWorkspace[#result.directoriesOutsideWorkspace + 1] = tspath.GetDirectoryPath(file)
            end
        end
        return result
    end)
end

-- Watchers: { watcherID, workspaceWatchers, outsideWorkspaceWatchers, ignoredPaths }
function WatchedFiles:Watchers()
    if not self.computeWatchersOnce then
        self.computeWatchersOnce = true
        -- A nil result is the zero PatternsAndIgnored (core.Identity of a zero input).
        local result = self.computeGlobPatterns(self.input) or project.NewPatternsAndIgnored(nil, nil, nil)
        local globs = project.sortedCompact(result.patternsInsideWorkspace)

        local ignored = result.ignored
        -- ignored is only used for logging and doesn't affect watcher identity
        self.ignored = ignored
        local changed = false
        local sameWorkspace = project.equalFunc(self.workspaceWatchers, globs, function(a, b)
            return a.globPattern.pattern == b
        end)
        if not sameWorkspace then
            local watchKind = self.watchKind
            self.workspaceWatchers = {}
            for i, glob in ipairs(globs) do
                self.workspaceWatchers[i] = {
                    globPattern = { pattern = glob },
                    kind = watchKind,
                }
            end
            changed = true
        end
        local dirsOutside = project.sortedCompact(result.directoriesOutsideWorkspace)
        local sameOutside = project.equalFunc(self.outsideWorkspaceWatchers, dirsOutside, function(a, b)
            return project.fileSystemWatcherGlobString(a) == project.recursiveDirectoryGlobPattern(b, self.hasRelativePatternCapability)
        end)
        if not sameOutside then
            self.outsideWorkspaceWatchers = {}
            for i, dir in ipairs(dirsOutside) do
                self.outsideWorkspaceWatchers[i] = project.newRecursiveDirectoryWatcher(dir, self.watchKind, self.hasRelativePatternCapability)
            end
            changed = true
        end
        if changed then
            self.id = nextWatcherID()
        end
    end

    return {
        watcherID = self.name .. " watcher " .. tostring(self.id),
        workspaceWatchers = self.workspaceWatchers,
        outsideWorkspaceWatchers = self.outsideWorkspaceWatchers,
        ignoredPaths = self.ignored,
    }
end

-- equalFunc is slices.EqualFunc (nil and empty slices are equal).
function project.equalFunc(a, b, eq)
    local na, nb = a ~= nil and #a or 0, b ~= nil and #b or 0
    if na ~= nb then
        return false
    end
    for i = 1, na do
        if not eq(a[i], b[i]) then
            return false
        end
    end
    return true
end

-- ID is callable on nil as project.WatchedFiles.ID(w).
function WatchedFiles.ID(w)
    if w == nil then
        return ""
    end
    return w:Watchers().watcherID
end

function WatchedFiles:Name()
    return self.name
end

function WatchedFiles:WatchKind()
    return self.watchKind
end

-- Clone is callable on nil as project.WatchedFiles.Clone(w, input).
function WatchedFiles.Clone(w, input)
    if w == nil then
        return nil
    end
    return setmetatable({
        id = 0,
        name = w.name,
        watchKind = w.watchKind,
        hasRelativePatternCapability = w.hasRelativePatternCapability,
        computeGlobPatterns = w.computeGlobPatterns,
        workspaceWatchers = w.workspaceWatchers,
        outsideWorkspaceWatchers = w.outsideWorkspaceWatchers,
        input = input,
        computeWatchersOnce = false,
        ignored = nil,
    }, WatchedFiles)
end

function project.createResolutionLookupGlobMapper(workspaceDirectory, libDirectory, currentDirectory, useCaseSensitiveFileNames)
    local workspaceDirectoryPath = tspath.ToPath(workspaceDirectory, currentDirectory, useCaseSensitiveFileNames)
    local currentDirectoryPath = tspath.ToPath(currentDirectory, currentDirectory, useCaseSensitiveFileNames)
    local libDirectoryPath = tspath.ToPath(libDirectory, currentDirectory, useCaseSensitiveFileNames)

    return function(data)
        local ignored = nil
        local seenDirs = collections.NewSet()
        local includeWorkspace, includeRoot, includeLib = false, false, false
        local nodeModulesDirectories = collections.NewSet()
        local externalDirectories = collections.NewSet()

        if data ~= nil then
            data:Range(function(path)
                if tspath.IsDynamicFileName(path) then
                    return true
                end
                -- Assuming all of the input paths are file paths, we can avoid
                -- duplicate work by only taking one file per dir, since their outputs
                -- will always be the same.
                if not seenDirs:AddIfAbsent(tspath.Path_GetDirectoryPath(path)) then
                    return true
                end

                if tspath.Path_ContainsPath(workspaceDirectoryPath, path) then
                    includeWorkspace = true
                elseif tspath.Path_ContainsPath(currentDirectoryPath, path) then
                    includeRoot = true
                elseif tspath.Path_ContainsPath(libDirectoryPath, path) then
                    includeLib = true
                else
                    local idx = string.find(path, "/node_modules/", 1, true)
                    if idx ~= nil then
                        nodeModulesDirectories:Add(string.sub(path, 1, idx - 1 + #"/node_modules"))
                    else
                        externalDirectories:Add(tspath.Path_GetDirectoryPath(path))
                    end
                end
                return true
            end)
        end

        local globs = nil
        local function appendGlob(g)
            globs = globs or {}
            globs[#globs + 1] = g
        end
        if includeWorkspace then
            appendGlob(project.getRecursiveGlobPattern(workspaceDirectoryPath))
        end
        if includeRoot then
            appendGlob(project.getRecursiveGlobPattern(currentDirectoryPath))
        end
        if includeLib then
            appendGlob(project.getRecursiveGlobPattern(libDirectoryPath))
        end
        if nodeModulesDirectories:Len() > 0 then
            local nodeModulesGlobs = {}
            for dir in pairs(project.setKeys(nodeModulesDirectories)) do
                nodeModulesGlobs[#nodeModulesGlobs + 1] = project.getRecursiveGlobPattern(dir)
            end
            table.sort(nodeModulesGlobs)
            for _, g in ipairs(nodeModulesGlobs) do
                appendGlob(g)
            end
        end
        local outsideDirs = nil
        if externalDirectories:Len() > 0 then
            local externalDirStrings = project.sortedKeys(project.setKeys(externalDirectories))
            local externalDirectoryParents, ignoredExternalDirs = tspath.GetCommonParents(
                externalDirStrings,
                project.minWatchLocationDepth,
                project.getPathComponentsForWatching,
                { useCaseSensitiveFileNames = true, currentDirectory = "" } -- Already using tspath.Path
            )
            if externalDirectoryParents ~= nil then
                table.sort(externalDirectoryParents)
            end
            ignored = ignoredExternalDirs
            outsideDirs = externalDirectoryParents
        end

        return project.NewPatternsAndIgnored(outsideDirs, globs, ignored)
    end
end

function project.getTypingsLocationsGlobs(typingsFiles, typingsLocation, workspaceDirectory, currentDirectory, useCaseSensitiveFileNames)
    local includeTypingsLocation, includeWorkspace = false, false
    local externalDirectories = {}
    local globs = {}
    local comparePathsOptions = {
        currentDirectory = currentDirectory,
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
    }
    for _, file in ipairs(typingsFiles or {}) do
        if tspath.ContainsPath(typingsLocation, file, comparePathsOptions) then
            includeTypingsLocation = true
        elseif not tspath.ContainsPath(workspaceDirectory, file, comparePathsOptions) then
            local directory = tspath.GetDirectoryPath(file)
            externalDirectories[tspath.ToPath(directory, currentDirectory, useCaseSensitiveFileNames)] = directory
        else
            includeWorkspace = true
        end
    end
    local externalDirectoryValues = {}
    for _, k in ipairs(project.sortedKeys(externalDirectories)) do
        externalDirectoryValues[#externalDirectoryValues + 1] = externalDirectories[k]
    end
    local externalDirectoryParents, ignored = tspath.GetCommonParents(
        externalDirectoryValues,
        project.minWatchLocationDepth,
        project.getPathComponentsForWatching,
        comparePathsOptions
    )
    if externalDirectoryParents ~= nil then
        table.sort(externalDirectoryParents)
    end
    if includeWorkspace then
        globs[tspath.ToPath(workspaceDirectory, currentDirectory, useCaseSensitiveFileNames)] = project.getRecursiveGlobPattern(workspaceDirectory)
    end
    if includeTypingsLocation then
        globs[tspath.ToPath(typingsLocation, currentDirectory, useCaseSensitiveFileNames)] = project.getRecursiveGlobPattern(typingsLocation)
    end
    local patterns = nil
    for _, k in ipairs(project.sortedKeys(globs)) do
        patterns = patterns or {}
        patterns[#patterns + 1] = globs[k]
    end
    return project.NewPatternsAndIgnored(externalDirectoryParents, patterns, ignored)
end

function project.getPathComponentsForWatching(path, currentDirectory)
    local components = tspath.GetPathComponents(path, currentDirectory)
    local rootLength = project.perceivedOsRootLengthForWatching(components)
    if rootLength <= 1 then
        return components
    end
    local rest = {}
    for i = 2, rootLength do
        rest[#rest + 1] = components[i]
    end
    local newRoot = tspath.CombinePaths(components[1], table.unpack(rest))
    local result = { newRoot }
    for i = rootLength + 1, #components do
        result[#result + 1] = components[i]
    end
    return result
end

function project.perceivedOsRootLengthForWatching(pathComponents)
    local length = #pathComponents
    if length <= 1 then
        return length
    end
    if project.hasPrefix(pathComponents[1], "//") then
        -- Group UNC roots (//server/share) into a single component
        return 2
    end
    local first = pathComponents[1]
    if #first == 3 and tspath.IsVolumeCharacter(string.byte(first, 1)) and string.sub(first, 2, 2) == ":" and string.sub(first, 3, 3) == "/" then
        -- Windows-style volume
        if string.lower(pathComponents[2]) == "users" then
            -- Group C:/Users/username into a single component
            return math.min(3, length)
        end
        return 1
    end
    if pathComponents[2] == "home" then
        -- Group /home/username into a single component
        return math.min(3, length)
    end
    return 1
end

function project.getRecursiveGlobPattern(directory)
    return tspath.RemoveTrailingDirectorySeparator(directory) .. "/" .. "**/*"
end

-- recursiveDirectoryGlobPattern returns the string form of a recursive watcher
-- for the given directory that would be produced by newRecursiveDirectoryWatcher.
function project.recursiveDirectoryGlobPattern(directory, useRelativePattern)
    if useRelativePattern then
        return lsconv.FileNameToDocumentURI(directory) .. "/**/*"
    end
    return project.getRecursiveGlobPattern(directory)
end

-- newRecursiveDirectoryWatcher creates a FileSystemWatcher for recursively
-- watching a directory. When useRelativePattern is true, a RelativePattern with
-- a file:// base URI is used; otherwise a plain glob Pattern is used.
function project.newRecursiveDirectoryWatcher(directory, kind, useRelativePattern)
    if useRelativePattern then
        local baseUri = lsconv.FileNameToDocumentURI(directory)
        return {
            globPattern = {
                relativePattern = {
                    baseUri = { uri = baseUri },
                    pattern = "**/*",
                },
            },
            kind = kind,
        }
    end
    local glob = project.getRecursiveGlobPattern(directory)
    return {
        globPattern = { pattern = glob },
        kind = kind,
    }
end
