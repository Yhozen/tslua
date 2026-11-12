local project = require("tslua.project")
local collections = require("tslua.collections")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local autoimport = require("tslua.ls.autoimport")
local logging = require("tslua.project.logging")
local vfsmatch = require("tslua.vfs.vfsmatch")

local UpdateReason = project.UpdateReason
local LogTree = logging.LogTree

-- Snapshot:
--   id, parentId, refCount
--   sessionOptions: session options are immutable for the server lifetime, so can be a pointer.
--   toPath, converters
--   Immutable state, cloned between snapshots: fs, projectCollection, configFileRegistry,
--   autoImports, autoImportsWatch, compilerOptionsForInferredProjects, inferredProjectContentMappers,
--   inferredProjectContentMapperExtensions, userPreferences, contentMapperWatchStateOnce,
--   contentMapperExtensions, contentMapperWatchedFiles
--   builderLogs, apiError
local Snapshot = {}
Snapshot.__index = Snapshot
project.Snapshot = Snapshot

-- contentMapperWatchState returns (extensions, watchedFiles).
function Snapshot:contentMapperWatchState()
    if not self.contentMapperWatchStateOnce then
        self.contentMapperWatchStateOnce = true
        local extensions = {}
        local configured = self.configFileRegistry:contentMappers()
        if configured ~= nil then
            for _, ext in ipairs(configured.extensions or {}) do
                extensions[#extensions + 1] = ext
            end
        end
        for _, ext in ipairs(self.inferredProjectContentMapperExtensions or {}) do
            extensions[#extensions + 1] = ext
        end
        self.contentMapperExtensions = project.sortedCompact(extensions)

        self.contentMapperWatchedFiles = collections.NewSet()
        for _, p in ipairs(self.projectCollection:Projects()) do
            if p.contentMapperWatchedFiles ~= nil then
                for path in pairs(project.setKeys(p.contentMapperWatchedFiles)) do
                    self.contentMapperWatchedFiles:Add(path)
                end
            end
        end
    end
    return self.contentMapperExtensions, self.contentMapperWatchedFiles
end

-- NewSnapshot initializes a snapshot with refCount 1.
-- The caller is responsible for calling Deref when done.
function project.NewSnapshot(
    id,
    fs,
    sessionOptions,
    configFileRegistry,
    compilerOptionsForInferredProjects,
    userPreferences,
    autoImports,
    autoImportsWatch,
    toPath
)
    local s = setmetatable({
        id = id,
        parentId = 0,
        refCount = 0,

        sessionOptions = sessionOptions,
        toPath = toPath,
        converters = nil,

        fs = fs,
        configFileRegistry = configFileRegistry,
        projectCollection = project.newProjectCollection({ toPath = toPath, openFiles = project.openFilePaths(fs.overlays) }),
        compilerOptionsForInferredProjects = compilerOptionsForInferredProjects,
        userPreferences = userPreferences,
        autoImports = autoImports,
        autoImportsWatch = autoImportsWatch,
        inferredProjectContentMappers = nil,
        inferredProjectContentMapperExtensions = nil,
        contentMapperWatchStateOnce = false,
        contentMapperExtensions = nil,
        contentMapperWatchedFiles = nil,

        builderLogs = nil,
        apiError = nil,
    }, Snapshot)
    s.refCount = 1
    s.converters = lsconv.NewConverters(s.sessionOptions.positionEncoding, function(fileName)
        return s:LSPLineMap(fileName)
    end)
    return s
end

function Snapshot:GetDefaultProject(uri)
    return self.projectCollection:GetDefaultProject(lsproto.DocumentUri_Path(uri, self:UseCaseSensitiveFileNames()))
end

function Snapshot:GetProjectsContainingFile(uri)
    local fileName = lsproto.DocumentUri_FileName(uri)
    local path = self.toPath(fileName)
    -- TODO!! sheetal may be change this to handle symlinks!!
    return self.projectCollection:GetProjectsContainingFile(path)
end

function Snapshot:GetFile(fileName)
    return self.fs:GetFile(fileName)
end

function Snapshot:LSPLineMap(fileName)
    local file = self.fs:GetFile(fileName)
    if file ~= nil then
        return file:LSPLineMap()
    end
    return nil
end

function Snapshot:GetECMALineInfo(fileName)
    local file = self.fs:GetFile(fileName)
    if file ~= nil then
        return file:ECMALineInfo()
    end
    return nil
end

function Snapshot:GetPreferences(activeFile)
    return self.userPreferences
end

function Snapshot:UserPreferences()
    return self.userPreferences
end

function Snapshot:Converters()
    return self.converters
end

function Snapshot:AutoImportRegistry()
    return self.autoImports
end

function Snapshot:ID()
    return self.id
end

function Snapshot:UseCaseSensitiveFileNames()
    return self.fs.fs:UseCaseSensitiveFileNames()
end

-- ReadFile returns (contents, ok).
function Snapshot:ReadFile(fileName)
    local handle = self:GetFile(fileName)
    if handle == nil then
        return "", false
    end
    return handle:Content(), true
end

function Snapshot:DirectoryExists(path)
    return self.fs.fs:DirectoryExists(path)
end

function Snapshot:FileExists(path)
    return self.fs.fs:FileExists(path)
end

function Snapshot:GetDirectories(path)
    return self.fs.fs:GetAccessibleEntries(path).directories
end

function Snapshot:ReadDirectory(currentDir, path, extensions, excludes, includes, depth)
    return vfsmatch.ReadDirectory(self.fs.fs, currentDir, path, extensions, excludes, includes, depth)
end

-- APISnapshotRequest: { openProjects (Set of config file names), closeProjects (Set of paths),
--   openFiles (Set of DocumentUri), closeFiles (Set of paths) }

-- ProjectTreeRequest: referencedProjects — if nil, all project trees need to be loaded, otherwise
-- only those that are referenced.
local ProjectTreeRequest = {}
ProjectTreeRequest.__index = ProjectTreeRequest
project.ProjectTreeRequest = ProjectTreeRequest

function project.NewProjectTreeRequest(referencedProjects)
    return setmetatable({ referencedProjects = referencedProjects }, ProjectTreeRequest)
end

function ProjectTreeRequest:IsAllProjects()
    return self.referencedProjects == nil
end

function ProjectTreeRequest:IsProjectReferenced(projectID)
    return collections.Set.Has(self.referencedProjects, projectID)
end

function ProjectTreeRequest:Projects()
    if self.referencedProjects == nil then
        return nil
    end
    return project.sortedKeys(project.setKeys(self.referencedProjects))
end

-- ResourceRequest (embedded in SnapshotChange):
--   documents: URIs that were requested by the client.
--     The new snapshot should ensure projects for these URIs have loaded programs.
--   configuredProjectDocuments: URIs for which configured projects should be loaded
--     (if disableSolutionSearching/disableReferencedProjectLoad settings allow),
--     but no inferred project should be created if no configured project is found.
--     This is used by cross-project operations like find-all-references.
--   projects: update requested Projects.
--     this is used when we want to get LS and from all the Projects the file can be part of
--   projectTree: update and ensure project trees that reference the projects
--     This is used to compute the solution and project tree so that
--     we can find references across all the projects in the solution irrespective of which project is open
--   autoImports: the document URI for which auto imports should be prepared.
--
-- SnapshotChange:
--   reason, fileChanges: the changes that have occurred since the last snapshot.
--   compilerOptionsForInferredProjects: the compiler options to use for inferred projects.
--     It should only be set the value in the next snapshot should be changed. If nil, the
--     value from the previous snapshot will be copied to the new snapshot.
--   contentMapperContributions, newConfig,
--   ataChanges: ATA-related changes to apply to projects in the new snapshot.
--   apiRequest,
--   cleanDiskCache: triggers cleaning of cached disk files not referenced by any open project.
function project.newSnapshotChange(fields)
    return {
        documents = fields.documents,
        configuredProjectDocuments = fields.configuredProjectDocuments,
        projects = fields.projects,
        projectTree = fields.projectTree,
        autoImports = fields.autoImports or "",
        reason = fields.reason or UpdateReason.Unknown,
        fileChanges = fields.fileChanges or project.newFileChangeSummary(),
        compilerOptionsForInferredProjects = fields.compilerOptionsForInferredProjects,
        contentMapperContributions = fields.contentMapperContributions,
        newConfig = fields.newConfig,
        ataChanges = fields.ataChanges,
        apiRequest = fields.apiRequest,
        cleanDiskCache = fields.cleanDiskCache or false,
    }
end

-- ATAStateChange: { projectID, typingsInfo, typingsFiles, typingsFilesToWatch, logs }

function Snapshot:Clone(ctx, change, overlays, session)
    -- SnapshotChange is passed by value.
    local c = {}
    for k, v in pairs(change) do
        c[k] = v
    end
    change = c
    change.fileChanges = project.copyFileChangeSummary(change.fileChanges)

    local logger = nil
    if session.options.loggingEnabled then
        -- Print in-progress logs immediately if cloning fails
        local results
        local ok, err = xpcall(function()
            results = self:clone(ctx, change, overlays, session, function(l)
                logger = l
            end)
        end, function(e)
            return e
        end)
        if not ok then
            if logger ~= nil then
                session.logger:Log(logger:String())
            end
            error(err, 0)
        end
        return results
    end
    return self:clone(ctx, change, overlays, session, function() end)
end

function Snapshot:clone(ctx, change, overlays, session, setLogger)
    local logger = nil

    if session.options.loggingEnabled then
        logger = logging.NewLogTree(string.format("Cloning snapshot %d", self.id))
        setLogger(logger)
        local function getDetails()
            local details = ""
            if project.sliceLen(change.documents) ~= 0 then
                details = details .. " Documents: " .. logging.fmtValue(change.documents)
            end
            if project.sliceLen(change.configuredProjectDocuments) ~= 0 then
                details = details .. " ConfiguredProjectDocuments: " .. logging.fmtValue(change.configuredProjectDocuments)
            end
            if project.sliceLen(change.projects) ~= 0 then
                details = details .. " Projects: " .. logging.fmtValue(change.projects)
            end
            if change.projectTree ~= nil then
                details = details .. " ProjectTree: " .. logging.fmtValue(change.projectTree:Projects())
            end
            return details
        end
        local reason = change.reason
        if reason == UpdateReason.DidOpenFile then
            logger:Logf("Reason: DidOpenFile - %s", change.fileChanges.opened)
        elseif reason == UpdateReason.DidCloseFile then
            logger:Logf("Reason: DidCloseFile - %v", change.fileChanges.closed)
        elseif reason == UpdateReason.DidChangeCompilerOptionsForInferredProjects then
            logger:Logf("Reason: DidChangeCompilerOptionsForInferredProjects")
        elseif reason == UpdateReason.RequestedLanguageServicePendingChanges then
            logger:Logf("Reason: RequestedLanguageService (pending file changes) - %v", getDetails())
        elseif reason == UpdateReason.RequestedLanguageServiceProjectNotLoaded then
            logger:Logf("Reason: RequestedLanguageService (project not loaded) - %v", getDetails())
        elseif reason == UpdateReason.RequestedLanguageServiceForFileNotOpen then
            logger:Logf("Reason: RequestedLanguageService (file not open) - %v", getDetails())
        elseif reason == UpdateReason.RequestedLanguageServiceProjectDirty then
            logger:Logf("Reason: RequestedLanguageService (project dirty) - %v", getDetails())
        elseif reason == UpdateReason.RequestedLoadProjectTree then
            logger:Logf("Reason: RequestedLoadProjectTree - %v", getDetails())
        elseif reason == UpdateReason.IdleCleanDiskCache then
            logger:Logf("Reason: IdleCleanDiskCache")
        elseif reason == UpdateReason.DidChangeConfigFile then
            logger:Logf("Reason: DidChangeConfigFile - %v", getDetails())
        elseif reason == UpdateReason.DidChangeContentMapperContributions then
            logger:Logf("Reason: DidChangeContentMapperContributions - %v", getDetails())
        end
    end

    local start = project.now()
    local configuredContentMappers = self.configFileRegistry:contentMappers()
    local inferredContentMappers = self.inferredProjectContentMappers
    local inferredContentMapperExtensions = self.inferredProjectContentMapperExtensions
    if change.contentMapperContributions ~= nil then
        inferredContentMappers = change.contentMapperContributions.mappers
        inferredContentMapperExtensions = change.contentMapperContributions.extensions
    end
    local fs = project.newSnapshotFSBuilder(session.fs.fs, self.fs.overlays, overlays, self.fs.diskFiles, self.fs.diskDirectories, self.fs.nodeModulesRealpathAliases, session.options.positionEncoding, self.toPath)
    if project.FileChangeSummary_HasExcessiveWatchEvents(change.fileChanges) then
        local invalidateStart = project.now()
        if change.fileChanges.invalidateAll then
            fs:invalidateCache()
            LogTree.Logf(logger, "InvalidateAll: invalidated file cache in %v", project.since(invalidateStart))
        elseif not fs:watchChangesOverlapCache(change.fileChanges) then
            -- All watch changes/deletes are files we haven't seen; should be irrelevant to us (probably an external tool's build or something)
            change.fileChanges.changed = collections.NewSet()
            change.fileChanges.deleted = collections.NewSet()
        elseif change.fileChanges.includesWatchChangeOutsideNodeModules then
            fs:invalidateCache()
            LogTree.Logf(logger, "Excessive watch changes detected, invalidated file cache in %v", project.since(invalidateStart))
        else
            fs:invalidateNodeModulesCache()
            LogTree.Logf(logger, "npm install detected, invalidated node_modules cache in %v", project.since(invalidateStart))
        end
    else
        local contentMapperExtensions = nil
        if change.contentMapperContributions == nil then
            contentMapperExtensions = self:contentMapperWatchState()
        else
            contentMapperExtensions = {}
            if configuredContentMappers ~= nil then
                for _, ext in ipairs(configuredContentMappers.extensions or {}) do
                    contentMapperExtensions[#contentMapperExtensions + 1] = ext
                end
            end
            for _, ext in ipairs(inferredContentMapperExtensions or {}) do
                contentMapperExtensions[#contentMapperExtensions + 1] = ext
            end
        end
        local _, contentMapperWatchedFiles = self:contentMapperWatchState()
        change.fileChanges = fs:expandAndFilterWatchEvents(change.fileChanges, contentMapperExtensions, contentMapperWatchedFiles)
        change.fileChanges = self.fs:expandRealpathAliases(change.fileChanges)
        change.fileChanges = fs:markDirtyFiles(change.fileChanges)
        change.fileChanges = fs:convertOpenAndCloseToChanges(change.fileChanges)
    end

    local compilerOptionsForInferredProjects = self.compilerOptionsForInferredProjects
    if change.compilerOptionsForInferredProjects ~= nil then
        -- !!! mark inferred projects as dirty?
        compilerOptionsForInferredProjects = change.compilerOptionsForInferredProjects
    end

    -- Compute effective customConfigFileName from user preferences
    local customConfigFileName = self.configFileRegistry.customConfigFileName
    if change.newConfig ~= nil then
        customConfigFileName = change.newConfig.customConfigFileName or ""
    end

    session.snapshotID = session.snapshotID + 1
    local newSnapshotID = session.snapshotID
    local projectCollectionBuilder = project.newProjectCollectionBuilder(
        ctx,
        newSnapshotID,
        fs,
        self.projectCollection,
        self.configFileRegistry,
        self.projectCollection.apiState,
        compilerOptionsForInferredProjects,
        inferredContentMappers,
        inferredContentMapperExtensions,
        self.sessionOptions,
        customConfigFileName,
        session.parseCache,
        session.contentMappedParseCache,
        session.extendedConfigCache,
        session.contentMapperHost,
        session.client
    )

    if next(change.ataChanges or {}) ~= nil then
        projectCollectionBuilder:DidUpdateATAState(change.ataChanges, LogTree.Fork(logger, "DidUpdateATAState"))
    end

    projectCollectionBuilder:DidChangeCustomConfigFileName(LogTree.Fork(logger, "DidChangeCustomConfigFileName"))
    if change.contentMapperContributions ~= nil then
        projectCollectionBuilder:DidChangeContentMapperContributions(LogTree.Fork(logger, "DidChangeContentMapperContributions"))
    end
    if change.newConfig ~= nil then
        projectCollectionBuilder:DidChangeUserPreferences(self.userPreferences, change.newConfig, LogTree.Fork(logger, "DidChangeUserPreferences"))
    end

    if not project.FileChangeSummary_IsEmpty(change.fileChanges) then
        projectCollectionBuilder:DidChangeFiles(change.fileChanges, LogTree.Fork(logger, "DidChangeFiles"))
    end

    local apiError = nil
    if change.apiRequest ~= nil then
        apiError = projectCollectionBuilder:HandleAPIRequest(change.apiRequest, LogTree.Fork(logger, "HandleAPIRequest"))
    end

    for _, uri in ipairs(change.documents or {}) do
        projectCollectionBuilder:DidRequestFile(uri, false, LogTree.Fork(logger, "DidRequestFile"))
    end

    for _, uri in ipairs(change.configuredProjectDocuments or {}) do
        projectCollectionBuilder:DidRequestFile(uri, true, LogTree.Fork(logger, "DidRequestFile (optional)"))
    end

    for _, projectId in ipairs(change.projects or {}) do
        projectCollectionBuilder:DidRequestProject(projectId, LogTree.Fork(logger, "DidRequestProject"))
    end

    if change.projectTree ~= nil then
        projectCollectionBuilder:DidRequestProjectTrees(change.projectTree, LogTree.Fork(logger, "DidRequestProjectTrees"))
    end

    local projectCollection, configFileRegistry = projectCollectionBuilder:Finalize(logger)

    local projectsWithNewProgramStructure = {}
    for _, p in ipairs(projectCollection:Projects()) do
        if p.programLastUpdate == newSnapshotID and p.programUpdateKind ~= project.ProgramUpdateKind.Cloned then
            projectsWithNewProgramStructure[p.configFilePath] = p.programUpdateKind == project.ProgramUpdateKind.NewFiles
        end
    end

    -- Clean cached disk files not touched by any open project on file open, close, delete,
    -- or when explicitly requested (e.g. by an idle timer).
    local shouldCleanDiskCache = change.cleanDiskCache or
        change.fileChanges.opened ~= "" or
        change.fileChanges.reopened ~= "" or
        change.fileChanges.closed:Len() > 0 or
        change.fileChanges.deleted:Len() > 0
    if shouldCleanDiskCache then
        -- The set of seen files can change only if a program was constructed (not cloned) during this snapshot.
        -- When cleanDiskCache is explicitly set, always attempt cleaning.
        if next(projectsWithNewProgramStructure) ~= nil or change.cleanDiskCache then
            local cleanFilesStart = project.now()
            local removedFiles = 0
            local projects = projectCollection:Projects()
            fs.diskFiles:Range(function(entry)
                for _, p in ipairs(projects) do
                    if p.host ~= nil and p.host.sourceFS:SeenFile(entry:Key()) then
                        return true
                    end
                end
                entry:Delete()
                removedFiles = removedFiles + 1
                return true
            end)
            if session.options.loggingEnabled then
                logger:Logf("Removed %d cached file(s) in %v", removedFiles, project.since(cleanFilesStart))
            end
        end
    end

    local config = self.userPreferences
    if change.newConfig ~= nil then
        config = change.newConfig
    end

    local autoImportHost = project.newAutoImportRegistryCloneHost(
        projectCollection,
        session.parseCache,
        fs,
        self.sessionOptions.currentDirectory,
        self.toPath
    )
    local openFiles = {}
    for path, overlay in pairs(overlays) do
        openFiles[path] = overlay:FileName()
    end
    local prepareAutoImports = ""
    if change.autoImports ~= "" then
        prepareAutoImports = lsproto.DocumentUri_Path(change.autoImports, self:UseCaseSensitiveFileNames())
    end
    local oldAutoImports = self.autoImports
    if oldAutoImports == nil then
        oldAutoImports = autoimport.NewRegistry(self.toPath, self.userPreferences)
    end
    local autoImportsWatch = nil
    local autoImports, err = oldAutoImports:Clone(ctx, {
        requestedFile = prepareAutoImports,
        openFiles = openFiles,
        changed = change.fileChanges.changed,
        created = change.fileChanges.created,
        deleted = change.fileChanges.deleted,
        rebuiltPrograms = projectsWithNewProgramStructure,
        userPreferences = change.newConfig,
    }, autoImportHost, LogTree.Fork(logger, "UpdateAutoImports"))
    if err == nil then
        autoImportsWatch = project.WatchedFiles.Clone(self.autoImportsWatch, autoImports:NodeModulesDirectories())
    end

    local snapshotFS = fs:Finalize()
    local newSnapshot = project.NewSnapshot(
        newSnapshotID,
        snapshotFS,
        self.sessionOptions,
        nil,
        compilerOptionsForInferredProjects,
        config,
        autoImports,
        autoImportsWatch,
        self.toPath
    )
    newSnapshot.parentId = self.id
    newSnapshot.projectCollection = projectCollection
    newSnapshot.configFileRegistry = configFileRegistry
    newSnapshot.inferredProjectContentMappers = inferredContentMappers
    newSnapshot.inferredProjectContentMapperExtensions = inferredContentMapperExtensions
    newSnapshot.builderLogs = logger
    newSnapshot.apiError = apiError

    for _, p in ipairs(newSnapshot.projectCollection:Projects()) do
        if p.program ~= nil then
            session.programCounter:Ref(p.program)
            if p.programLastUpdate == newSnapshotID then
                -- If the program was updated during this clone, the project and its host are new
                -- and still retain references to the builder. Freezing clears the builder reference
                -- so it's GC'd and to ensure the project can't access any data not already in the
                -- snapshot during use. This is pretty kludgy, but it's an artifact of Program design:
                -- Program has a single host, which is expected to implement a full vfs.FS, among
                -- other things. That host is *mostly* only used during program *construction*, but a
                -- few methods may get exercised during program *use*. So, our compiler host is allowed
                -- to access caches and perform mutating effects (like acquire referenced project
                -- config files) during snapshot building, and then we call `freeze` to ensure those
                -- mutations don't happen afterwards. In the future, we might improve things by
                -- separating what it takes to build a program from what it takes to use a program,
                -- and only pass the former into NewProgram instead of retaining it indefinitely.
                p.host:freeze(snapshotFS, newSnapshot.configFileRegistry)
            end
        end
    end
    for _, path in ipairs(project.sortedKeys(newSnapshot.configFileRegistry.configs)) do
        local cfg = newSnapshot.configFileRegistry.configs[path]
        if cfg.commandLine ~= nil and cfg.commandLine.configFile ~= nil then
            for _, file in ipairs(cfg.commandLine.configFile.extendedSourceFiles or {}) do
                session.extendedConfigCache:AddOwner(newSnapshot.toPath(file), newSnapshot.id)
            end
        end
    end

    autoImportHost:Dispose()

    LogTree.Logf(logger, "Finished cloning snapshot %d into snapshot %d in %v", self.id, newSnapshot.id, project.since(start))
    return newSnapshot
end

function project.sliceLen(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

-- ref increments the snapshot's reference count, preventing it from being
-- disposed until a corresponding Deref is called. The snapshot must still
-- be alive (refCount > 0) when ref is called. Only the project Session
-- should call ref().
function Snapshot:ref()
    self.refCount = self.refCount + 1
    if self.refCount <= 1 then
        error(string.format("snapshot %d: ref on disposed snapshot, parentId=%d", self.id, self.parentId), 0)
    end
end

-- tryRef attempts to increment the snapshot's reference count. If the
-- snapshot is already disposed (refCount == 0), it returns false without
-- modifying the count. On success the caller must eventually call Deref.
function Snapshot:tryRef()
    if self.refCount <= 0 then
        return false
    end
    self.refCount = self.refCount + 1
    return true
end

-- Deref decrements the snapshot's reference count. When the count reaches
-- zero, the snapshot is disposed and its resources are released.
function Snapshot:Deref(session)
    self.refCount = self.refCount - 1
    local rc = self.refCount
    if rc < 0 then
        error(string.format("snapshot %d: ref count below zero, parentId=%d", self.id, self.parentId), 0)
    end
    if rc == 0 then
        self:dispose(session)
    end
end

function Snapshot:dispose(session)
    for _, p in ipairs(self.projectCollection:Projects()) do
        if p.program ~= nil and session.programCounter:Deref(p.program) then
            local contentMapperProject = p.program:ContentMapperProject()
            if contentMapperProject ~= nil then
                contentMapperProject:Close()
            end
            -- This program is no longer referenced by any snapshot.
            -- Mark its checker pool as discarded so its idle-cleanup timer stops
            -- keeping the pool alive, allowing the pool and any idle checkers it
            -- still references to be reclaimed when the pool is garbage-collected.
            if p.checkerPool ~= nil then
                p.checkerPool:Discard()
            end
            for _, file in ipairs(p.program:SourceFiles()) do
                if not file:IsContentMapperFailureStub() and not file:IsContentMapperSupplemental() then
                    if file:ContentMapper() ~= "" then
                        session.contentMappedParseCache:Deref(project.contentMappedParseCacheKeyForFile(file))
                    else
                        session.parseCache:Deref(project.parseCacheKeyForFile(file))
                    end
                end
            end
            for _, file in ipairs(p.program:DuplicateSourceFiles() or {}) do
                if not file.isContentMapperFailureStub then
                    if file.contentMapper ~= "" then
                        session.contentMappedParseCache:Deref(project.contentMappedParseCacheKeyForDuplicate(file))
                    else
                        session.parseCache:Deref(project.parseCacheKeyForDuplicate(file))
                    end
                end
            end
        end
    end
    for _, path in ipairs(project.sortedKeys(self.configFileRegistry.configs)) do
        local cfg = self.configFileRegistry.configs[path]
        if cfg.commandLine ~= nil then
            for _, file in ipairs(cfg.commandLine:ExtendedSourceFiles() or {}) do
                session.extendedConfigCache:Release(session.toPath(file), self.id)
            end
        end
    end
end
