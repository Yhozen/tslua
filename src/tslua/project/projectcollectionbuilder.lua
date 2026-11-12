local project = require("tslua.project")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local lsproto = require("tslua.lsp.lsproto")
local dirty = require("tslua.project.dirty")
local logging = require("tslua.project.logging")
local tspath = require("tslua.tspath")

local Kind = project.Kind
local ProgramUpdateKind = project.ProgramUpdateKind
local LogTree = logging.LogTree

-- projectLoadKind (unexported Go enum)
project.projectLoadKind = {
    -- Project is not created or updated, only looked up in cache
    Find = 0,
    -- Project is created and then its graph is updated
    Create = 1,
}
local projectLoadKind = project.projectLoadKind

local ProjectCollectionBuilder = {}
ProjectCollectionBuilder.__index = ProjectCollectionBuilder
project.ProjectCollectionBuilder = ProjectCollectionBuilder

function project.newProjectCollectionBuilder(
    ctx,
    newSnapshotID,
    fs,
    oldProjectCollection,
    oldConfigFileRegistry,
    oldAPIState,
    compilerOptionsForInferredProjects,
    inferredContentMappers,
    inferredContentMapperExtensions,
    sessionOptions,
    customConfigFileName,
    parseCache,
    contentMappedParseCache,
    extendedConfigCache,
    contentMapperHost,
    client
)
    return setmetatable({
        ctx = ctx,
        fs = fs,
        toPath = fs.toPath,
        compilerOptionsForInferredProjects = compilerOptionsForInferredProjects,
        inferredContentMappers = inferredContentMappers,
        inferredContentMapperExtensions = inferredContentMapperExtensions,
        sessionOptions = sessionOptions,
        parseCache = parseCache,
        contentMappedParseCache = contentMappedParseCache,
        extendedConfigCache = extendedConfigCache,
        contentMapperHost = contentMapperHost,
        base = oldProjectCollection,
        configFileRegistryBuilder = project.newConfigFileRegistryBuilder(project.hasRelativePatternSupport(ctx), fs, oldConfigFileRegistry, extendedConfigCache, newSnapshotID, sessionOptions, customConfigFileName, nil),
        newSnapshotID = newSnapshotID,
        programStructureChanged = false,
        defaultProjectsInvalidated = false,
        openFilesChanged = false,
        fileDefaultProjects = nil,
        configuredProjects = dirty.NewSyncMap(oldProjectCollection.configuredProjects),
        inferredProject = dirty.NewBox(oldProjectCollection.inferredProject),
        apiState = project.APIState_clone(oldAPIState),
        client = client,
    }, ProjectCollectionBuilder)
end

-- Finalize returns (*ProjectCollection, *ConfigFileRegistry).
function ProjectCollectionBuilder:Finalize(logger)
    local changed = false
    local newProjectCollection = self.base
    local function ensureCloned()
        if not changed then
            newProjectCollection = newProjectCollection:clone()
            changed = true
        end
    end

    local configuredProjects, configuredProjectsChanged = self.configuredProjects:Finalize()
    if configuredProjectsChanged then
        ensureCloned()
        newProjectCollection.configuredProjects = configuredProjects
    end

    if self.openFilesChanged then
        ensureCloned()
        newProjectCollection.openFiles = project.openFilePaths(self.fs.overlays)
    end

    if not project.mapsEqual(self.fileDefaultProjects, self.base.fileDefaultProjects) then
        ensureCloned()
        newProjectCollection.fileDefaultProjects = self.fileDefaultProjects
    end

    local newInferredProject, inferredProjectChanged = self.inferredProject:Finalize()
    if inferredProjectChanged then
        ensureCloned()
        newProjectCollection.inferredProject = newInferredProject
    end

    local configFileRegistry = self.configFileRegistryBuilder:Finalize()
    if configFileRegistry ~= self.base.configFileRegistry then
        ensureCloned()
        newProjectCollection.configFileRegistry = configFileRegistry
    end

    if not project.APIState_equals(self.apiState, self.base.apiState) then
        ensureCloned()
        newProjectCollection.apiState = self.apiState
    end

    return newProjectCollection, configFileRegistry
end

function ProjectCollectionBuilder:forEachProject(fn)
    local keepGoing = true
    self.configuredProjects:Range(function(entry)
        keepGoing = fn(entry)
        return keepGoing
    end)
    if not keepGoing then
        return
    end
    if self.inferredProject:Value() ~= nil then
        fn(self.inferredProject)
    end
end

-- HandleAPIRequest returns an error or nil.
function ProjectCollectionBuilder:HandleAPIRequest(apiRequest, logger)
    local projectsToClose = nil
    if apiRequest.closeProjects ~= nil then
        for _, projectPath in ipairs(project.sortedKeys(project.setKeys(apiRequest.closeProjects))) do
            -- Ref-counted close: only actually close the project once the last
            -- API client that opened it releases it.
            local count = self.apiState.openProjects ~= nil and self.apiState.openProjects[projectPath] or 0
            if count > 1 then
                self.apiState.openProjects[projectPath] = count - 1
            elseif count == 1 then
                self.apiState.openProjects[projectPath] = nil
                if projectsToClose == nil then
                    projectsToClose = {}
                end
                projectsToClose[projectPath] = true
            end
        end
    end

    if apiRequest.openProjects ~= nil then
        for _, configFileName in ipairs(project.sortedKeys(project.setKeys(apiRequest.openProjects))) do
            local configPath = self.toPath(configFileName)
            local entry = self:findOrCreateProject(configFileName, configPath, projectLoadKind.Create, logger)
            if entry ~= nil then
                if self.apiState.openProjects == nil then
                    self.apiState.openProjects = {}
                end
                self.apiState.openProjects[configPath] = (self.apiState.openProjects[configPath] or 0) + 1
                -- A project re-opened in the same request shouldn't be closed.
                if projectsToClose ~= nil then
                    projectsToClose[configPath] = nil
                end
            else
                return project.errorf("project not found for open: %s", configFileName)
            end
        end
    end

    if apiRequest.closeFiles ~= nil then
        for path in pairs(project.setKeys(apiRequest.closeFiles)) do
            -- Ref-counted close mirroring projects above.
            local entry = self.apiState.openFiles ~= nil and self.apiState.openFiles[path] or nil
            if entry ~= nil then
                if entry.refCount > 1 then
                    self.apiState.openFiles[path] = { fileName = entry.fileName, refCount = entry.refCount - 1 }
                else
                    self.apiState.openFiles[path] = nil
                end
            end
        end
    end

    if apiRequest.openFiles ~= nil then
        for _, uri in ipairs(project.sortedKeys(project.setKeys(apiRequest.openFiles))) do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local path = self.toPath(fileName)
            if self.apiState.openFiles == nil then
                self.apiState.openFiles = {}
            end
            local entry = self.apiState.openFiles[path] or { fileName = "", refCount = 0 }
            self.apiState.openFiles[path] = { fileName = fileName, refCount = entry.refCount + 1 }
        end
    end

    for _, configPath in ipairs(project.sortedKeys(self.apiState.openProjects)) do
        local entry, ok = self.configuredProjects:Load(configPath)
        if ok then
            self:updateProgram(entry, logger)
        else
            return project.errorf("project not found for update: %s", configPath)
        end
    end

    for _, path in ipairs(project.sortedKeys(self.fs.overlays)) do
        local overlay = self.fs.overlays[path]
        local entry = self:findDefaultConfiguredProject(overlay:FileName(), self.toPath(overlay:FileName()))
        if entry ~= nil and projectsToClose ~= nil then
            projectsToClose[entry:Value().configFilePath] = nil
        end
    end

    for _, projectPath in ipairs(project.sortedKeys(projectsToClose)) do
        local entry, ok = self.configuredProjects:Load(projectPath)
        if ok then
            self:deleteConfiguredProject(entry, logger)
        end
    end

    -- Ensure each API-opened file is placed like LSP's textDocument/didOpen: search
    -- up ancestor directories for a configured project that contains it, and only
    -- fall back to the inferred project if none is found. This also keeps already
    -- loaded configured projects up to date. Then run the same cleanup the LSP open
    -- path uses, so configured projects auto-loaded for files that are no longer open
    -- are torn down instead of leaking.
    if apiRequest.openFiles ~= nil or apiRequest.closeFiles ~= nil then
        local retain = collections.NewSet()
        for _, path in ipairs(project.sortedKeys(self.apiState.openFiles)) do
            local file = self.apiState.openFiles[path]
            if self.fs:isOpenFile(path) then
                -- Already an LSP overlay; its project membership is handled by the
                -- overlay pass in cleanupConfiguredProjects.
                goto continue
            end
            do
                local result = self:ensureConfiguredProjectAndAncestorsForFile(file.fileName, path, logger)
                retain:Union(result.retain)
            end
            ::continue::
        end
        self:cleanupConfiguredProjects(retain, logger)
    end
    if self.inferredProject:Value() ~= nil then
        self:updateProgram(self.inferredProject, logger)
    end

    return nil
end

function ProjectCollectionBuilder:DidChangeFiles(summary, logger)
    self.openFilesChanged = self.openFilesChanged or summary.opened ~= "" or summary.closed:Len() > 0

    local function toPaths(uris)
        local paths = {}
        for _, uri in ipairs(project.sortedKeys(project.setKeys(uris))) do
            paths[#paths + 1] = self.toPath(lsproto.DocumentUri_FileName(uri))
        end
        return paths
    end
    local changedFiles = toPaths(summary.changed)
    local deletedFiles = toPaths(summary.deleted)
    local createdFiles = toPaths(summary.created)
    if self.contentMapperHost ~= nil then
        local allWatchChanges = {}
        for _, list in ipairs({ changedFiles, deletedFiles, createdFiles }) do
            for _, p in ipairs(list) do
                allWatchChanges[#allWatchChanges + 1] = p
            end
        end
        self:forEachProject(function(entry)
            self:refreshContentMapperProjectForChanges(entry, allWatchChanges, project.FileChangeSummary_HasExcessiveNonCreateWatchEvents(summary), logger)
            return true
        end)
    end

    local configChangeLogger = LogTree.Fork(logger, "Checking for changes affecting config files")
    local configChangeResult = self.configFileRegistryBuilder:DidChangeFiles(summary, configChangeLogger)
    project.logChangeFileResult(configChangeResult, configChangeLogger)

    self.programStructureChanged = self:markProjectsAffectedByConfigChanges(configChangeResult, logger)

    self:forEachProject(function(entry)
        -- Only consider change/delete; creates are handled by the config file registry
        if project.FileChangeSummary_HasExcessiveNonCreateWatchEvents(summary) then
            entry:Change(function(p)
                p.dirty = true
                p.dirtyFilePath = ""
                if logger ~= nil then
                    LogTree.Logf(logger, "Marking project as dirty due to excessive watch changes: %s", p.configFilePath)
                end
            end)
            return true
        end

        -- Handle closed and changed files
        self:markFilesChanged(entry, changedFiles, lsproto.FileChangeType.Changed, logger)
        if entry:Value().kind == Kind.Inferred and summary.closed:Len() > 0 then
            local rootFilesMap = entry:Value().commandLine:FileNamesByPath()
            local newRootFiles = core.Slice(entry:Value().commandLine:FileNames() or {})
            for _, uri in ipairs(project.sortedKeys(project.setKeys(summary.closed))) do
                local fileName = lsproto.DocumentUri_FileName(uri)
                local path = self.toPath(fileName)
                if rootFilesMap[path] ~= nil then
                    for i, name in ipairs(newRootFiles) do
                        if name == fileName then
                            table.remove(newRootFiles, i)
                            break
                        end
                    end
                end
            end
            self:updateInferredProjectRoots(newRootFiles, logger)
        end

        -- Handle deleted files
        if summary.deleted:Len() > 0 then
            self:markFilesChanged(entry, deletedFiles, lsproto.FileChangeType.Deleted, logger)
        end

        -- Handle created files
        if summary.created:Len() > 0 then
            self:markFilesChanged(entry, createdFiles, lsproto.FileChangeType.Created, logger)
        end

        return true
    end)

    -- Handle opened file
    if summary.opened ~= "" or summary.reopened ~= "" then
        local fileName = lsproto.DocumentUri_FileName(core.FirstNonZero(summary.opened, summary.reopened))
        local path = self.toPath(fileName)
        local openFileResult = self:ensureConfiguredProjectAndAncestorsForFile(fileName, path, logger)
        self:cleanupConfiguredProjects(openFileResult.retain, logger)
    end
end

function ProjectCollectionBuilder:refreshContentMapperProjectForChanges(entry, paths, refreshAll, logger)
    local p = entry:Value()
    if p.program == nil or p.contentMapperWatchedFiles == nil then
        return
    end
    local affected = refreshAll
    if not affected then
        for _, path in ipairs(paths) do
            if p.contentMapperWatchedFiles:Has(path) then
                affected = true
                break
            end
        end
    end
    if not affected then
        return
    end
    local contentMapperProject = p.program:ContentMapperProject()
    if contentMapperProject ~= nil then
        contentMapperProject:Refresh()
    end
    entry:Change(function(proj)
        proj.dirty = true
        proj.dirtyFilePath = ""
        if logger ~= nil then
            LogTree.Logf(logger, "Marking project as dirty due to content mapper configuration changes: %s", proj.configFilePath)
        end
    end)
end

-- cleanupConfiguredProjects sweeps the loaded configured projects and unloads those
-- that are no longer needed. Starting from the set of all configured projects, it
-- retains any project that is the default project (along with its references and
-- ancestor configs) of an open overlay file or an API-opened file, any project
-- explicitly opened through the API, and any project in retain (e.g. the ancestor
-- solution tree built for a freshly opened overlay file). Every other configured
-- project is deleted, the inferred project roots are recomputed, and the config file
-- registry is cleaned up. This is the shared mechanism that keeps the set of loaded
-- projects minimal for both LSP file opens and API file opens/closes.
function ProjectCollectionBuilder:cleanupConfiguredProjects(retain, logger)
    local toRemoveProjects = collections.NewSet()
    self.configuredProjects:Range(function(entry)
        toRemoveProjects:Add(entry:Key())
        return true
    end)

    local function retainProjectAndReferences(p)
        -- Retain project
        toRemoveProjects:Delete(p.configFilePath)
        local program = p:GetProgram()
        if program ~= nil then
            program:RangeResolvedProjectReference(function(referencePath)
                local _, ok = self.configuredProjects:Load(referencePath)
                if ok then
                    toRemoveProjects:Delete(referencePath)
                end
                return true
            end)
        end
    end

    local function retainDefaultConfiguredProject(openFilePath, p)
        -- Retain project and its references
        retainProjectAndReferences(p)

        -- Retain all the ancestor projects
        self.configFileRegistryBuilder:forEachConfigFileNameFor(openFilePath, function(configFileName)
            local ancestor = self:findOrCreateProject(configFileName, self.toPath(configFileName), projectLoadKind.Find, logger)
            if ancestor ~= nil then
                retainProjectAndReferences(ancestor:Value())
            end
        end)
    end

    local inferredProjectFiles = {}
    for _, path in ipairs(project.sortedKeys(self.fs.overlays)) do
        local overlay = self.fs.overlays[path]
        local openFile = overlay:FileName()
        local openFilePath = self.toPath(openFile)
        local p = self:findDefaultConfiguredProject(openFile, openFilePath)
        if p ~= nil then
            retainDefaultConfiguredProject(openFilePath, p:Value())
        else
            inferredProjectFiles[#inferredProjectFiles + 1] = openFile
        end
    end
    -- Treat API-opened files like open files: retain their configured project (so
    -- an LSP-driven open doesn't close it), or keep them as inferred project roots.
    for _, path in ipairs(project.sortedKeys(self.apiState.openFiles)) do
        local file = self.apiState.openFiles[path]
        if self.fs:isOpenFile(path) then
            goto continue
        end
        do
            local p = self:findDefaultConfiguredProject(file.fileName, path)
            if p ~= nil then
                retainDefaultConfiguredProject(path, p:Value())
            else
                inferredProjectFiles[#inferredProjectFiles + 1] = file.fileName
            end
        end
        ::continue::
    end

    for _, projectPath in ipairs(project.sortedKeys(project.setKeys(toRemoveProjects))) do
        if retain:Has(projectPath) then
            goto continue
        end
        if self.apiState.openProjects ~= nil and self.apiState.openProjects[projectPath] ~= nil then
            goto continue
        end
        do
            local p, ok = self.configuredProjects:Load(projectPath)
            if ok then
                self:deleteConfiguredProject(p, logger)
            end
        end
        ::continue::
    end
    self:updateInferredProjectRoots(inferredProjectFiles, logger)
    self.configFileRegistryBuilder:Cleanup()
end

function project.logChangeFileResult(result, logger)
    if next(result.affectedProjects or {}) ~= nil then
        LogTree.Logf(logger, "Config file change affected projects: %v", project.sortedKeys(result.affectedProjects))
    end
    if next(result.affectedFiles or {}) ~= nil then
        LogTree.Logf(logger, "Config file change affected config file lookups for %d files", project.mapLen(result.affectedFiles))
    end
end

function ProjectCollectionBuilder:collectInferredProjectRoots()
    local inferredProjectFiles = {}
    for _, path in ipairs(project.sortedKeys(self.fs.overlays)) do
        local overlay = self.fs.overlays[path]
        if self:findDefaultConfiguredProject(overlay:FileName(), path) == nil then
            inferredProjectFiles[#inferredProjectFiles + 1] = overlay:FileName()
        end
    end
    return self:appendAPIOpenedInferredRoots(inferredProjectFiles)
end

-- appendAPIOpenedInferredRoots appends API-opened files that aren't open in an
-- overlay and have no configured project, so they're kept as inferred project
-- roots and persist across snapshots.
function ProjectCollectionBuilder:appendAPIOpenedInferredRoots(inferredProjectFiles)
    for _, path in ipairs(project.sortedKeys(self.apiState.openFiles)) do
        local file = self.apiState.openFiles[path]
        if self.fs:isOpenFile(path) then
            goto continue
        end
        if self:findDefaultConfiguredProject(file.fileName, path) == nil then
            inferredProjectFiles[#inferredProjectFiles + 1] = file.fileName
        end
        ::continue::
    end
    return inferredProjectFiles
end

function ProjectCollectionBuilder:cleanupInferredProject(logger)
    self:updateInferredProjectRoots(self:collectInferredProjectRoots(), logger)
end

function ProjectCollectionBuilder:DidChangeContentMapperContributions(logger)
    self:cleanupInferredProject(logger)
    if self.inferredProject:Value() ~= nil then
        self:updateProgram(self.inferredProject, logger)
    end
end

function ProjectCollectionBuilder:ensureInferredProjectIncludesClosedFile(fileName, logger)
    -- Collect existing inferred project roots (open files not in configured projects)
    -- plus this closed file.
    local inferredProjectFiles = self:collectInferredProjectRoots()
    inferredProjectFiles[#inferredProjectFiles + 1] = fileName
    self:updateInferredProjectRoots(inferredProjectFiles, logger)
    if self.inferredProject:Value() ~= nil then
        self:updateProgram(self.inferredProject, logger)
    end
end

-- DidRequestFile ensures projects are loaded for the given URI.
-- If configuredProjectsOnly is true, only configured projects are loaded; no inferred project is created
-- and it is not guaranteed that there will be any project containing the file in the resulting snapshot.
function ProjectCollectionBuilder:DidRequestFile(uri, configuredProjectsOnly, logger)
    local startTime = project.now()
    local fileName = lsproto.DocumentUri_FileName(uri)
    local path = self.toPath(fileName)
    if self.defaultProjectsInvalidated then
        self:ensureConfiguredProjectAndAncestorsForFile(fileName, path, logger)
        if not self.fs:isOpenFile(path) then
            return
        end
    end
    if self.fs:isOpenFile(path) then
        local hasChanges = self.programStructureChanged

        -- See if we can find a default project without updating a bunch of stuff.
        local result = self:findDefaultProject(fileName, path)
        if result ~= nil then
            hasChanges = self:updateProgram(result, logger) or hasChanges
            if result:Value() ~= nil and result:Value():containsFile(path) then
                if hasChanges then
                    self:cleanupInferredProject(logger)
                    if self.inferredProject:Value() ~= nil then
                        self:updateProgram(self.inferredProject, logger)
                    end
                end
                return
            end
        end

        -- Make sure all projects we know about are up to date...
        self.configuredProjects:Range(function(entry)
            hasChanges = self:updateProgram(entry, logger) or hasChanges
            return true
        end)
        if hasChanges then
            -- If the structure of other projects changed, we might need to move files
            -- in/out of the inferred project.
            self:cleanupInferredProject(logger)
        end

        if self.inferredProject:Value() ~= nil then
            self:updateProgram(self.inferredProject, logger)
        end

        -- At this point we should be able to find the default project for the file without
        -- creating anything else. Initially, I verified that and panicked if nothing was found,
        -- but that panic was getting triggered by fourslash infrastructure when it told us to
        -- open a package.json file. This is something the VS Code client would never do, but
        -- it seems possible that another client would. There's no point in panicking; we don't
        -- really even have an error condition until it tries to ask us language questions about
        -- a non-TS-handleable file.
    else
        local result = self:ensureConfiguredProjectAndAncestorsForFile(fileName, path, logger)
        if result.project == nil and not configuredProjectsOnly then
            -- No configured project found for this closed file.
            -- Add it to the inferred project so language service requests can be served.
            self:ensureInferredProjectIncludesClosedFile(fileName, logger)
        end
    end

    if logger ~= nil then
        local elapsed = project.since(startTime)
        LogTree.Log(logger, "Completed file request for " .. fileName .. " in " .. elapsed:String())
    end
end

function ProjectCollectionBuilder:DidRequestProject(projectId, logger)
    local startTime = project.now()
    if projectId == project.inferredProjectName then
        -- Update inferred project
        if self.inferredProject:Value() ~= nil then
            self:updateProgram(self.inferredProject, logger)
        end
    else
        local entry, ok = self.configuredProjects:Load(projectId)
        if ok then
            self:updateProgram(entry, logger)
        end
    end

    if logger ~= nil then
        local elapsed = project.since(startTime)
        LogTree.Log(logger, "Completed project update request for " .. projectId .. " in " .. elapsed:String())
    end
end

function ProjectCollectionBuilder:DidRequestProjectTrees(projectTreeRequest, logger)
    local startTime = project.now()

    local currentProjects = {}
    self.configuredProjects:Range(function(sme)
        currentProjects[#currentProjects + 1] = sme:Key()
        return true
    end)
    table.sort(currentProjects)

    local seenProjects = collections.NewSyncSet()
    local wg = core.NewWorkGroup(false)
    for _, projectId in ipairs(currentProjects) do
        wg:Queue(function()
            local entry, ok = self.configuredProjects:Load(projectId)
            if ok then
                -- If this project has potential project reference for any of the project we are loading ancestor tree for
                -- load this project first
                local p = entry:Value()
                if p ~= nil and (projectTreeRequest:IsAllProjects() or p:hasPotentialProjectReference(projectTreeRequest)) then
                    self:updateProgram(entry, logger)
                end
                self:ensureProjectTree(wg, entry, projectTreeRequest, seenProjects, logger)
            end
        end)
    end
    wg:RunAndWait()

    if logger ~= nil then
        local elapsed = project.since(startTime)
        LogTree.Log(logger, "Completed project tree request for " .. logging.fmtValue(projectTreeRequest:Projects()) .. " in " .. elapsed:String())
    end
end

function ProjectCollectionBuilder:ensureProjectTree(wg, entry, projectTreeRequest, seenProjects, logger)
    if not seenProjects:AddIfAbsent(entry:Key()) then
        return
    end

    local p = entry:Value()
    if p == nil then
        return
    end

    local program = p:GetProgram()
    if program == nil then
        return
    end

    -- If this project disables child load ignore it
    if core.Tristate_IsTrue(program:CommandLine():CompilerOptions().disableReferencedProjectLoad) then
        return
    end

    local children = program:GetResolvedProjectReferences()
    if children == nil then
        return
    end
    for _, childConfig in ipairs(children) do
        if childConfig == nil or childConfig == false then
            goto continue
        end
        wg:Queue(function()
            if not projectTreeRequest:IsAllProjects() and program:RangeResolvedProjectReferenceInChildConfig(
                childConfig,
                function(referencePath)
                    return not projectTreeRequest:IsProjectReferenced(referencePath)
                end
            ) then
                return
            end

            -- Load this child project since this is referenced
            local childProjectEntry = self:findOrCreateProject(childConfig:ConfigName(), childConfig.configFile.sourceFile:Path(), projectLoadKind.Create, logger)
            self:updateProgram(childProjectEntry, logger)

            -- Ensure children for this project
            self:ensureProjectTree(wg, childProjectEntry, projectTreeRequest, seenProjects, logger)
        end)
        ::continue::
    end
end

function ProjectCollectionBuilder:DidUpdateATAState(ataChanges, logger)
    local function updateProject(p, ataChange)
        p:ChangeIf(
            function(proj)
                if proj == nil then
                    return false
                end
                -- Consistency check: the ATA demands (project options, unresolved imports) of this project
                -- has not changed since the time the ATA request was dispatched; the change can still be
                -- applied to this project in its current state.
                return ataChange.typingsInfo:Equals(proj:ComputeTypingsInfo())
            end,
            function(proj)
                -- We checked before triggering this change (in Session.triggerATAForUpdatedProjects) that
                -- the set of typings files is actually different.
                proj.installedTypingsInfo = ataChange.typingsInfo
                proj.typingsFiles = ataChange.typingsFiles
                local typingsWatchGlobs = project.getTypingsLocationsGlobs(
                    ataChange.typingsFilesToWatch,
                    self.sessionOptions.typingsLocation,
                    self.sessionOptions.currentDirectory,
                    proj.currentDirectory,
                    self.fs.fs:UseCaseSensitiveFileNames()
                )
                proj.typingsWatch = proj.typingsWatch:Clone(typingsWatchGlobs)
                proj.dirty = true
                proj.dirtyFilePath = ""
            end
        )
    end

    for _, projectPath in ipairs(project.sortedKeys(ataChanges)) do
        local ataChange = ataChanges[projectPath]
        LogTree.Embed(logger, ataChange.logs)
        if projectPath == project.inferredProjectName then
            updateProject(self.inferredProject, ataChange)
        else
            local p, ok = self.configuredProjects:Load(projectPath)
            if ok then
                updateProject(p, ataChange)
            end
        end

        if logger ~= nil then
            LogTree.Log(logger, "Updated ATA state for project " .. projectPath)
        end
    end
end

-- if customConfigFileName changes, invalidate default projects.
function ProjectCollectionBuilder:DidChangeCustomConfigFileName(logger)
    if not self.configFileRegistryBuilder:DidChangeCustomConfigFileName(logger) then
        return
    end

    self.fileDefaultProjects = nil
    self.defaultProjectsInvalidated = true
    self.programStructureChanged = true
end

function ProjectCollectionBuilder:DidChangeUserPreferences(oldPreferences, newPreferences, logger)
    if oldPreferences.locale == newPreferences.locale then
        return
    end
    self:forEachProject(function(entry)
        entry:Change(function(p)
            p.dirty = true
            p.dirtyFilePath = ""
            if logger ~= nil then
                LogTree.Logf(logger, "Marking project as dirty due to locale change: %s", p.configFilePath)
            end
        end)
        return true
    end)
end

function ProjectCollectionBuilder:markProjectsAffectedByConfigChanges(configChangeResult, logger)
    for _, projectPath in ipairs(project.sortedKeys(configChangeResult.affectedProjects)) do
        local p, ok = self.configuredProjects:Load(projectPath)
        if not ok then
            error("project " .. projectPath .. " affected by config change not found", 0)
        end
        p:ChangeIf(
            function(proj) return not proj.dirty or proj.dirtyFilePath ~= "" end,
            function(proj)
                proj.dirty = true
                proj.dirtyFilePath = ""
                if logger ~= nil then
                    LogTree.Logf(logger, "Marking project %s as dirty due to change affecting config", projectPath)
                end
            end
        )
    end

    -- Recompute default projects for open files that now have different config file presence.
    local hasChanges = false
    for _, path in ipairs(project.sortedKeys(configChangeResult.affectedFiles)) do
        local fileName = self.fs.overlays[path]:FileName()
        self:ensureConfiguredProjectAndAncestorsForFile(fileName, path, logger)
        hasChanges = true
    end

    return hasChanges
end

function ProjectCollectionBuilder:findDefaultProject(fileName, path)
    local configuredProject = self:findDefaultConfiguredProject(fileName, path)
    if configuredProject ~= nil then
        return configuredProject
    end
    local key = self.fileDefaultProjects ~= nil and self.fileDefaultProjects[path] or nil
    if key ~= nil and key == project.inferredProjectName then
        return self.inferredProject
    end
    local inferredProject = self.inferredProject:Value()
    if inferredProject ~= nil and inferredProject:containsFile(path) then
        if self.fileDefaultProjects == nil then
            self.fileDefaultProjects = {}
        end
        self.fileDefaultProjects[path] = project.inferredProjectName
        return self.inferredProject
    end
    return nil
end

function ProjectCollectionBuilder:findDefaultConfiguredProject(fileName, path)
    local key = self.fileDefaultProjects ~= nil and self.fileDefaultProjects[path] or nil
    if key ~= nil and key ~= project.inferredProjectName then
        local entry, ok = self.configuredProjects:Load(key)
        if ok then
            return entry
        end
    end
    -- Sort configured projects so we can use a deterministic "first" as a last resort.
    local configuredProjectPaths = {}
    local configuredProjects = {}
    self.configuredProjects:Range(function(entry)
        configuredProjectPaths[#configuredProjectPaths + 1] = entry:Key()
        configuredProjects[entry:Key()] = entry
        return true
    end)
    table.sort(configuredProjectPaths)

    local p, multipleCandidates = project.findDefaultConfiguredProjectFromProgramInclusion(fileName, path, configuredProjectPaths, function(projectPath)
        return configuredProjects[projectPath]:Value()
    end)

    if multipleCandidates then
        local found = self:findOrCreateDefaultConfiguredProjectForFile(fileName, path, projectLoadKind.Find, nil).project
        if found ~= nil then
            return found
        end
    end

    return configuredProjects[p]
end

function ProjectCollectionBuilder:ensureConfiguredProjectAndAncestorsForFile(fileName, path, logger)
    local result = self:findOrCreateDefaultConfiguredProjectForFile(fileName, path, projectLoadKind.Create, logger)
    if result.project ~= nil and self.fs:isOpenFile(path) then
        self:createAncestorTree(fileName, path, result, logger)
    end
    return result
end

function ProjectCollectionBuilder:createAncestorTree(fileName, path, openResult, logger)
    local p = openResult.project:Value()
    while true do
        -- Skip if project is not composite and we are only looking for solution
        if p.commandLine ~= nil and
            (not core.Tristate_IsTrue(p.commandLine:CompilerOptions().composite) or
                core.Tristate_IsTrue(p.commandLine:CompilerOptions().disableSolutionSearching)) then
            return
        end

        -- Get config file name
        local ancestorConfigName = self.configFileRegistryBuilder:getAncestorConfigFileName(fileName, path, p.configFileName, logger)
        if ancestorConfigName == "" then
            return
        end

        -- find or delay load the project
        local ancestorPath = self.toPath(ancestorConfigName)
        local ancestor = self:findOrCreateProject(ancestorConfigName, ancestorPath, projectLoadKind.Create, logger)
        if ancestor == nil then
            return
        end

        openResult.retain:Add(ancestorPath)

        -- If this ancestor is new and was not updated because we are just creating it for future loading
        -- eg when invoking find all references or rename that could span multiple projects
        -- we would make the current project as its potential project reference
        if ancestor:Value().commandLine == nil and
            (p.commandLine == nil or core.Tristate_IsTrue(p.commandLine:CompilerOptions().composite)) then
            local childPath = p.configFilePath
            ancestor:Change(function(ancestorProject)
                ancestorProject:setPotentialProjectReference(childPath)
            end)
        end

        p = ancestor:Value()
    end
end

-- searchNode: { configFileName, loadKind, logger }
-- searchNodeKey: configFileName .. "\0" .. loadKind (string encoding of the Go struct key)
local function searchNodeKey(configFileName, loadKind)
    return configFileName .. "\0" .. tostring(loadKind)
end

local function searchNodeKeyConfigFileName(key)
    return string.match(key, "^(.*)%z[^%z]*$")
end

-- searchResult: { project = *dirty.SyncMapEntry or nil, retain = collections.Set }
local function newSearchResult(p, retain)
    return { project = p, retain = retain or collections.NewSet() }
end

function ProjectCollectionBuilder:findOrCreateDefaultConfiguredProjectWorker(fileName, path, configFileName, loadKind, visited, fallback, logger)
    local configs = collections.NewSyncMap()
    if visited == nil then
        visited = collections.NewSyncSet()
    end

    local search = core.BreadthFirstSearchParallelEx(
        { configFileName = configFileName, loadKind = loadKind, logger = logger },
        function(node)
            local config, ok = configs:Load(self.toPath(node.configFileName))
            if ok and core.Len(config:ProjectReferences()) > 0 then
                local referenceLoadKind = node.loadKind
                if core.Tristate_IsTrue(config:CompilerOptions().disableReferencedProjectLoad) then
                    referenceLoadKind = projectLoadKind.Find
                end

                local refLogger = nil
                local references = config:ResolvedProjectReferencePaths()
                if core.Len(references) > 0 and node.logger ~= nil then
                    refLogger = LogTree.Fork(node.logger, string.format("Searching %d project references of %s", #references, node.configFileName))
                end
                return core.Map(references, function(refConfigFileName)
                    return { configFileName = refConfigFileName, loadKind = referenceLoadKind, logger = LogTree.Fork(refLogger, "Searching project reference " .. refConfigFileName) }
                end)
            end
            return nil
        end,
        function(node)
            local configFilePath = self.toPath(node.configFileName)
            local config = self.configFileRegistryBuilder:findOrAcquireConfigForFile(node.configFileName, configFilePath, path, node.loadKind, LogTree.Fork(node.logger, "Acquiring config for open file"))
            if config == nil then
                LogTree.Log(node.logger, "Config file for project does not already exist")
                return false, false
            end
            configs:Store(configFilePath, config)
            if core.Len(config:FileNames()) == 0 then
                -- Likely a solution tsconfig.json - the search will fan out to its references.
                LogTree.Log(node.logger, "Project does not contain file (no root files)")
                return false, false
            end

            if config:CompilerOptions().composite == core.Tristate.TSTrue then
                -- For composite projects, we can get an early negative result.
                -- !!! what about declaration files in node_modules? wouldn't it be better to
                --     check project inclusion if the project is already loaded?
                if config:FileNamesByPath()[path] == nil then
                    LogTree.Log(node.logger, "Project does not contain file (by composite config inclusion)")
                    return false, false
                end
            end

            local p = self:findOrCreateProject(node.configFileName, configFilePath, node.loadKind, node.logger)
            if p == nil then
                LogTree.Log(node.logger, "Project does not already exist")
                return false, false
            end

            if node.loadKind == projectLoadKind.Create then
                -- Ensure project is up to date before checking for file inclusion
                self:updateProgram(p, node.logger)
            end

            if p:Value():containsFile(path) then
                local isDirectInclusion = not p:Value():IsSourceFromProjectReference(path)
                if node.logger ~= nil then
                    LogTree.Logf(node.logger, "Project contains file %s", core.IfElse(isDirectInclusion, "directly", "as a source of a referenced project"))
                end
                return true, isDirectInclusion
            end

            LogTree.Log(node.logger, "Project does not contain file")
            return false, false
        end,
        {
            visited = visited,
            preprocessLevel = function(level)
                level:Range(function(node)
                    if node.loadKind == projectLoadKind.Find and level:Has(searchNodeKey(node.configFileName, projectLoadKind.Create)) then
                        -- Remove find requests when a create request for the same project is already present.
                        level:Delete(searchNodeKey(node.configFileName, node.loadKind))
                    end
                    return true
                end)
            end,
        },
        function(node)
            return searchNodeKey(node.configFileName, node.loadKind)
        end
    )

    local retain = collections.NewSet()
    local p = nil
    if core.Len(search.path) > 0 then
        p = self.configuredProjects:Load(self.toPath(search.path[1].configFileName))
        -- If we found a project, we retain each project along the BFS path.
        -- We don't want to retain everything we visited since BFS can terminate
        -- early, and we don't want to retain nondeterministically.
        for _, node in ipairs(search.path) do
            retain:Add(self.toPath(node.configFileName))
        end
    end

    if search.stopped then
        -- Found a project that directly contains the file.
        return newSearchResult(p, retain)
    end

    if p ~= nil then
        -- If we found a project that contains the file, but it is a source from
        -- a project reference, record it as a fallback.
        fallback = newSearchResult(p, retain)
    end

    -- Look for tsconfig.json files higher up the directory tree and do the same. This handles
    -- the common case where a higher-level "solution" tsconfig.json contains all projects in a
    -- workspace.
    local config, ok = configs:Load(self.toPath(configFileName))
    if ok and core.Tristate_IsTrue(config:CompilerOptions().disableSolutionSearching) then
        if fallback ~= nil then
            return fallback
        end
    end
    local ancestorConfigName = self.configFileRegistryBuilder:getAncestorConfigFileName(fileName, path, configFileName, logger)
    if ancestorConfigName ~= "" then
        return self:findOrCreateDefaultConfiguredProjectWorker(
            fileName,
            path,
            ancestorConfigName,
            loadKind,
            visited,
            fallback,
            LogTree.Fork(logger, "Searching ancestor config file at " .. ancestorConfigName)
        )
    end
    if fallback ~= nil then
        return fallback
    end
    -- If we didn't find anything, we can retain everything we visited,
    -- since the whole graph must have been traversed (i.e., the set of
    -- retained projects is guaranteed to be deterministic).
    visited:Range(function(nodeKey)
        retain:Add(self.toPath(searchNodeKeyConfigFileName(nodeKey)))
        return true
    end)
    return newSearchResult(nil, retain)
end

function ProjectCollectionBuilder:findOrCreateDefaultConfiguredProjectForFile(fileName, path, loadKind, logger)
    local key = self.fileDefaultProjects ~= nil and self.fileDefaultProjects[path] or nil
    if key ~= nil then
        if key == project.inferredProjectName then
            -- The file belongs to the inferred project
            return newSearchResult(nil, nil)
        end
        local entry = self.configuredProjects:Load(key)
        return newSearchResult(entry, nil)
    end
    local configFileName = self.configFileRegistryBuilder:getConfigFileNameForFile(fileName, path, logger)
    if configFileName ~= "" then
        local startTime = project.now()
        local result = self:findOrCreateDefaultConfiguredProjectWorker(
            fileName,
            path,
            configFileName,
            loadKind,
            nil,
            nil,
            LogTree.Fork(logger, "Searching for default configured project for " .. fileName)
        )
        if result.project ~= nil then
            if self.fileDefaultProjects == nil then
                self.fileDefaultProjects = {}
            end
            self.fileDefaultProjects[path] = result.project:Value().configFilePath
        end
        if logger ~= nil then
            local elapsed = project.since(startTime)
            if result.project ~= nil then
                LogTree.Log(logger, "Found default configured project for " .. fileName .. ": " .. result.project:Value().configFileName .. " (in " .. elapsed:String() .. ")")
            else
                LogTree.Log(logger, "No default configured project found for " .. fileName .. " (searched in " .. elapsed:String() .. ")")
            end
        end
        return result
    end
    return newSearchResult(nil, nil)
end

function ProjectCollectionBuilder:findOrCreateProject(configFileName, configFilePath, loadKind, logger)
    if loadKind == projectLoadKind.Find then
        local entry = self.configuredProjects:Load(configFilePath)
        return entry
    end
    local entry = self.configuredProjects:LoadOrStore(configFilePath, project.NewConfiguredProject(configFileName, configFilePath, self, logger))
    return entry
end

function ProjectCollectionBuilder:updateInferredProjectRoots(rootFileNames, logger)
    rootFileNames = core.Filter(rootFileNames, function(fileName)
        return self:isSupportedInInferredProject(fileName)
    end)
    if core.Len(rootFileNames) == 0 then
        if self.inferredProject:Value() ~= nil then
            if logger ~= nil then
                LogTree.Log(logger, "Deleting inferred project")
            end
            self.inferredProject:Delete()
            return true
        end
        return false
    end

    table.sort(rootFileNames)
    local contentMappers = self.inferredContentMappers
    if self.inferredProject:Value() == nil then
        self.inferredProject:Set(project.NewInferredProject(self.sessionOptions.currentDirectory, self.compilerOptionsForInferredProjects, rootFileNames, contentMappers, self, logger))
    else
        local newCompilerOptions = self.inferredProject:Value().commandLine:CompilerOptions()
        if self.compilerOptionsForInferredProjects ~= nil then
            newCompilerOptions = self.compilerOptionsForInferredProjects
        end
        local newCommandLine = project.newInferredProjectCommandLine(newCompilerOptions, rootFileNames, contentMappers, {
            useCaseSensitiveFileNames = self.fs.fs:UseCaseSensitiveFileNames(),
            currentDirectory = self.sessionOptions.currentDirectory,
        })
        local changed = self.inferredProject:ChangeIf(
            function(p)
                return not project.mapsEqual(p.commandLine:FileNamesByPath(), newCommandLine:FileNamesByPath()) or
                    not project.slicesEqual(p.commandLine:ContentMappers(), newCommandLine:ContentMappers())
            end,
            function(p)
                if logger ~= nil then
                    LogTree.Log(logger, string.format("Updating inferred project config with %d root files", #rootFileNames))
                end
                p:SetCommandLine(newCommandLine)
            end
        )
        if not changed then
            return false
        end
    end
    return true
end

function ProjectCollectionBuilder:isSupportedInInferredProject(fileName)
    if tspath.IsDynamicFileName(fileName) or core.GetScriptKindFromFileName(fileName) ~= core.ScriptKind.Unknown then
        return true
    end
    local file = self.fs:GetFile(fileName)
    if file ~= nil and file:IsOverlay() and tspath.GetAnyExtensionFromPath(fileName, nil, false) == "" then
        return true
    end
    return tspath.FileExtensionIsOneOf(fileName, self.inferredContentMapperExtensions or {})
end

-- updateProgram updates the program for the given project entry if necessary. It returns
-- a boolean indicating whether the update could have caused any structure-affecting changes.
function ProjectCollectionBuilder:updateProgram(entry, logger)
    local updateProgram = false
    local deleteProject = false
    local filesChanged = false
    local configFileName = entry:Value().configFileName
    local startTime = project.now()
    local notifiedLoading = false
    local displayName = ""
    entry:Locked(function(e)
        if e:Value().kind == Kind.Configured then
            local commandLine = self.configFileRegistryBuilder:acquireConfigForProject(
                e:Value().configFileName,
                e:Value().configFilePath,
                e:Value(),
                LogTree.Fork(logger, "Acquiring config for project")
            )
            if commandLine == nil then
                deleteProject = true
                filesChanged = true
                return
            end
            if e:Value().commandLine ~= commandLine then
                updateProgram = true
                e:Change(function(p)
                    p:SetCommandLine(commandLine)
                end)
            end
        end
        if not updateProgram then
            updateProgram = e:Value().dirty
        end
        if updateProgram then
            if self.client ~= nil then
                displayName = e:Value():DisplayName(self.sessionOptions.currentDirectory)
                notifiedLoading = true
            end
        end
    end)
    if notifiedLoading and self.client ~= nil then
        self.client:ProgressStart(diagnostics.Project_0, displayName)
    end
    if deleteProject then
        self:deleteConfiguredProject(entry, logger)
    end
    if updateProgram then
        entry:Locked(function(e)
            e:Change(function(p)
                local oldHost = p.host
                local oldProgram = p.program
                local oldCheckerPool = p.checkerPool
                p.host = project.newCompilerHost(p.currentDirectory, p, self, LogTree.Fork(logger, "CompilerHost"))
                local result = p:CreateProgram()
                local watchedFiles = {}
                for _, mapper in ipairs(p.commandLine:ContentMappers() or {}) do
                    if (mapper.package or "") ~= "" and (mapper.contributionID or "") == "" and (mapper.packageDirectory or "") ~= "" then
                        watchedFiles[#watchedFiles + 1] = tspath.CombinePaths(mapper.packageDirectory, "package.json")
                    end
                end
                if core.Some(result.program:SourceFiles(), function(file)
                    return file:ContentMapper() ~= ""
                end) then
                    p.host:ensureContentMapperProject()
                end
                local contentMapperProject = p.host:ContentMapperProject()
                if contentMapperProject ~= nil then
                    local dynamicWatchedFiles = contentMapperProject:WatchedFiles()
                    for _, f in ipairs(dynamicWatchedFiles or {}) do
                        watchedFiles[#watchedFiles + 1] = f
                    end
                end
                watchedFiles = project.sortedCompact(watchedFiles)
                p.contentMapperWatch = p.contentMapperWatch:Clone(watchedFiles)
                p.contentMapperWatchedFiles = collections.NewSetWithSizeHint(#watchedFiles)
                for _, fileName in ipairs(watchedFiles) do
                    p.contentMapperWatchedFiles:Add(self.toPath(fileName))
                end
                p.program = result.program
                p.checkerPool = result.program:GetCheckerPool()
                p.programUpdateKind = result.updateKind
                p.programLastUpdate = self.newSnapshotID
                if result.updateKind == ProgramUpdateKind.Cloned then
                    p.host.sourceFS.seenFiles = oldHost.sourceFS.seenFiles
                end
                if result.updateKind == ProgramUpdateKind.NewFiles then
                    filesChanged = true
                    p.programFilesWatch = p:CloneWatchers()
                end
                p.dirty = false
                p.dirtyFilePath = ""
                self:releaseDroppedProjectReferences(oldProgram, result.program, p.configFilePath)
                if oldCheckerPool ~= nil then
                    oldCheckerPool:Discard()
                end
            end)
        end)
    end
    if notifiedLoading and self.client ~= nil then
        self.client:ProgressFinish(diagnostics.Project_0, displayName)
    end
    if updateProgram and logger ~= nil then
        local elapsed = project.since(startTime)
        LogTree.Log(logger, "Program update for " .. configFileName .. " completed in " .. elapsed:String())
    end
    return filesChanged
end

function ProjectCollectionBuilder:markFilesChanged(entry, paths, changeType, logger)
    local isDirty = false
    local dirtyFilePath = ""
    entry:ChangeIf(
        function(p)
            if p.program == nil or p.dirty and p.dirtyFilePath == "" then
                return false
            end

            dirtyFilePath = p.dirtyFilePath
            for _, path in ipairs(paths) do
                if p:containsFile(path) then
                    isDirty = true
                    if changeType == lsproto.FileChangeType.Deleted then
                        dirtyFilePath = ""
                        break
                    end
                    -- package.json changes can affect module resolution and package
                    -- identity (e.g. dedup decisions), so they must always trigger
                    -- a full rebuild rather than a single-file clone.
                    if tspath.GetBaseFileName(path) == "package.json" then
                        dirtyFilePath = ""
                        break
                    end
                    if dirtyFilePath == "" then
                        dirtyFilePath = path
                    elseif dirtyFilePath ~= path then
                        dirtyFilePath = ""
                        break
                    end
                elseif p.host ~= nil and
                    (changeType == lsproto.FileChangeType.Created and p.host.sourceFS:SeenFileOrMissingParentDirectory(path) or
                        changeType ~= lsproto.FileChangeType.Created and p.host.sourceFS:SeenFile(path)) then
                    isDirty = true
                    dirtyFilePath = ""
                    break
                end
            end
            return isDirty or p.dirtyFilePath ~= dirtyFilePath
        end,
        function(p)
            p.dirty = true
            p.dirtyFilePath = dirtyFilePath
            if logger ~= nil then
                if dirtyFilePath ~= "" then
                    LogTree.Logf(logger, "Marking project %s as dirty due to changes in %s", p.configFileName, dirtyFilePath)
                else
                    LogTree.Logf(logger, "Marking project %s as dirty", p.configFileName)
                end
            end
        end
    )
end

function ProjectCollectionBuilder:deleteConfiguredProject(p, logger)
    local projectPath = p:Value().configFilePath
    if logger ~= nil then
        LogTree.Log(logger, "Deleting configured project: " .. p:Value().configFileName)
    end
    local program = p:Value().program
    if program ~= nil then
        program:RangeResolvedProjectReference(function(referencePath)
            self.configFileRegistryBuilder:releaseConfigForProject(referencePath, projectPath)
            return true
        end)
    end
    self.configFileRegistryBuilder:releaseConfigForProject(projectPath, projectPath)
    p:Delete()
end

-- releaseDroppedProjectReferences releases the config entries for project references
-- that were present in oldProgram but are no longer referenced by newProgram. Creating
-- newProgram already re-acquires the config for every reference it still resolves, so
-- only the dropped references need to be released here.
function ProjectCollectionBuilder:releaseDroppedProjectReferences(oldProgram, newProgram, projectPath)
    if oldProgram == nil or oldProgram == newProgram then
        return
    end
    local newReferences = collections.NewSet()
    if newProgram ~= nil then
        newProgram:RangeResolvedProjectReference(function(referencePath)
            newReferences:Add(referencePath)
            return true
        end)
    end
    oldProgram:RangeResolvedProjectReference(function(referencePath)
        if not newReferences:Has(referencePath) then
            self.configFileRegistryBuilder:releaseConfigForProject(referencePath, projectPath)
        end
        return true
    end)
end
