local project = require("tslua.project")
local collections = require("tslua.collections")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local ls = require("tslua.ls")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local ata = require("tslua.project.ata")
local background = require("tslua.project.background")
local logging = require("tslua.project.logging")
local tspath = require("tslua.tspath")

local UpdateReason = project.UpdateReason
local Kind = project.Kind
local ProgramUpdateKind = project.ProgramUpdateKind
local FileChangeKind = project.FileChangeKind
local Tristate = core.Tristate

-- ErrNoProjectForUnknownScriptKind identifies requests for otherwise unsupported files.
project.ErrNoProjectForUnknownScriptKind = project.newError("no project for unknown script kind")

-- ContentMapperContributions: { mappers, extensions }

-- watchRequestTimeout is the maximum time to wait for the client to respond to
-- a WatchFiles or UnwatchFiles request while holding the watches mutex.
project.watchRequestTimeout = 1

-- SessionOptions are the immutable initialization options for a session.
-- Snapshots may reference them as a pointer since they never change.
--   currentDirectory, defaultLibraryPath, typingsLocation, positionEncoding, watchEnabled,
--   loggingEnabled, telemetryEnabled, pushDiagnosticsEnabled,
--   runExternalCode: allows configured content mappers to run their (external) processes,
--     gated on workspace trust by the client. It corresponds to the --runExternalCode CLI flag.
--   debounceDelay (seconds), checkerPoolOptions
function project.NewSessionOptions(fields)
    fields = fields or {}
    return {
        currentDirectory = fields.currentDirectory or "",
        defaultLibraryPath = fields.defaultLibraryPath or "",
        typingsLocation = fields.typingsLocation or "",
        positionEncoding = fields.positionEncoding or "",
        watchEnabled = fields.watchEnabled or false,
        loggingEnabled = fields.loggingEnabled or false,
        telemetryEnabled = fields.telemetryEnabled or false,
        pushDiagnosticsEnabled = fields.pushDiagnosticsEnabled or false,
        runExternalCode = fields.runExternalCode or false,
        debounceDelay = fields.debounceDelay or 0,
        checkerPoolOptions = project.NewCheckerPoolOptions(fields.checkerPoolOptions),
    }
end

-- SessionInit: { backgroundCtx, options, fs, client, logger, npmExecutor,
--   spawner (launches content mapper processes; nil when the host cannot spawn processes),
--   contentMapperLogger, parseCache, contentMappedParseCache }

-- Session manages the state of an LSP session. It receives textDocument
-- events and requests for LanguageService objects from the LPS server
-- and processes them into immutable snapshots as the data source for
-- LanguageServices. When Session transitions from one snapshot to the
-- next, it diffs them and updates file watchers and Automatic Type
-- Acquisition (ATA) state accordingly.
local Session = project.Session or {}
Session.__index = Session
project.Session = Session

-- newContentMapperHost creates the session's shared content mapper host when the workspace is trusted and
-- a spawner is available; otherwise it returns nil, and configured content mappers are rejected by the
-- config-file gate.
function project.newContentMapperHost(init)
    if not init.options.runExternalCode or init.spawner == nil then
        return nil
    end
    local diagnosticLocale = locale.Default
    if init.client ~= nil then
        diagnosticLocale = init.client:GetLocale()
    end
    return contentmapper.NewHostWithOptions(init.backgroundCtx, init.spawner, diagnosticLocale, { logger = init.contentMapperLogger })
end

function project.NewSession(init)
    local currentDirectory = init.options.currentDirectory
    local useCaseSensitiveFileNames = init.fs:UseCaseSensitiveFileNames()
    local toPath = function(fileName)
        return tspath.ToPath(fileName, currentDirectory, useCaseSensitiveFileNames)
    end
    local overlayFS = project.newOverlayFS(init.fs, {}, init.options.positionEncoding, toPath)
    local parseCache = init.parseCache
    if parseCache == nil then
        parseCache = project.NewParseCache(project.NewRefCountCacheOptions())
    end
    local contentMappedParseCache = init.contentMappedParseCache
    if contentMappedParseCache == nil then
        contentMappedParseCache = project.NewContentMappedParseCache(project.NewRefCountCacheOptions())
    end
    local extendedConfigCache = project.NewExtendedConfigCache()

    local sessionLogger = init.logger
    if sessionLogger == nil then
        sessionLogger = logging.NewNopLogger()
    end
    local session = setmetatable({
        backgroundCtx = init.backgroundCtx,
        options = init.options,
        toPath = toPath,
        client = init.client,
        logger = sessionLogger,
        npmExecutor = init.npmExecutor,
        contentMapperHost = project.newContentMapperHost(init),
        contentMapperTimings = nil,
        fs = overlayFS,

        registeredContentMapperExtensions = nil,
        registeredContentMapperSnapshotID = 0,

        parseCache = parseCache,
        contentMappedParseCache = contentMappedParseCache,
        extendedConfigCache = extendedConfigCache,
        programCounter = project.newProgramCounter(),

        initialUserPreferences = lsutil.NewDefaultUserPreferences(),
        workspaceUserPreferences = lsutil.NewDefaultUserPreferences(),
        compilerOptionsForInferredProjects = nil,
        typingsInstaller = nil,
        backgroundQueue = background.NewQueue(),

        snapshotID = 0,
        snapshot = nil,

        scheduledSnapshotUpdateCancel = nil,
        scheduledSnapshotUpdateGeneration = 0,

        pendingUserConfigChanges = false,

        pendingFileChanges = nil,
        pendingATAChanges = {},

        diagnosticsRefreshCancel = nil,
        diagnosticsRefreshGeneration = 0,

        warmAutoImportCancel = nil,

        idleCacheCleanTimer = nil,

        performanceTelemetryCancel = nil,

        seenProjects = collections.NewSyncSet(),

        watches = project.newWatchRegistry(),

        globalDiagPublishPending = false,
        startTime = project.now(),
    }, Session)
    session.snapshot = project.NewSnapshot(
        0,
        project.NewSnapshotFS({
            toPath = toPath,
            fs = init.fs,
        }),
        init.options,
        project.NewConfigFileRegistry(),
        nil,
        lsutil.NewDefaultUserPreferences(),
        nil,
        project.NewWatchedFiles(
            "auto-import",
            lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete,
            project.hasRelativePatternSupport(init.backgroundCtx),
            function(nodeModulesDirs)
                local patterns = {}
                for _, dir in pairs(nodeModulesDirs or {}) do
                    patterns[#patterns + 1] = project.getRecursiveGlobPattern(dir)
                end
                table.sort(patterns)
                return project.NewPatternsAndIgnored(nil, patterns, nil)
            end
        ),
        toPath
    )

    if init.options.typingsLocation ~= "" and init.npmExecutor ~= nil then
        session.typingsInstaller = ata.NewTypingsInstaller({
            typingsLocation = init.options.typingsLocation,
            throttleLimit = 5,
        }, session)
    end
    if session.contentMapperHost ~= nil then
        session.contentMapperTimings = session.contentMapperHost:Timings()
    end

    return session
end

-- FS implements module.ResolutionHost
function Session:FS()
    return self.fs.fs
end

-- GetCurrentDirectory implements module.ResolutionHost
function Session:GetCurrentDirectory()
    return self.options.currentDirectory
end

-- Gets copy of current configuration
function Session:Config()
    return project.copyValue(self.workspaceUserPreferences)
end

function Session:backgroundContext()
    return self:withCurrentLocale(self.backgroundCtx)
end

function Session:withCurrentLocale(ctx)
    if self.client == nil then
        return ctx
    end
    return locale.WithLocale(ctx, self.client:GetLocale())
end

-- Trace implements module.ResolutionHost
function Session:Trace(msg)
    error("ATA module resolution should not use tracing", 0)
end

function Session:Configure(config)
    -- UserPreferences is passed by value.
    config = project.copyValue(config)
    self.pendingUserConfigChanges = true
    local oldConfig = self.workspaceUserPreferences
    self.workspaceUserPreferences = config

    if (config.locale or "") ~= "" then
        local oldLocale = self.client:GetLocale()
        self.client:SetLocale(config.locale)
        local newLocale = self.client:GetLocale()
        if locale.Locale_String(oldLocale) ~= locale.Locale_String(newLocale) then
            if self.contentMapperHost ~= nil then
                self.contentMapperHost:SetLocale(newLocale)
            end
        end
    end

    -- Tell the client to re-request certain commands depending on user preference changes.
    self:refreshInlayHintsIfNeeded(oldConfig, config)
    self:refreshCodeLensIfNeeded(oldConfig, config)
    self:refreshDiagnosticsIfNeeded(oldConfig, config)
    self:refreshATAIfNeeded(oldConfig, config)
end

function Session:InitializeWithUserConfig(config)
    self.initialUserPreferences = config
    self:Configure(config)
end

function Session:DidOpenFile(ctx, uri, version, content, languageKind)
    self:cancelWarmAutoImportCache()
    self:scheduleIdleCacheClean()
    self:cancelScheduledSnapshotUpdate()
    self.pendingFileChanges = self.pendingFileChanges or {}
    self.pendingFileChanges[#self.pendingFileChanges + 1] = project.NewFileChange({
        kind = FileChangeKind.Open,
        uri = uri,
        version = version,
        content = content,
        languageKind = languageKind,
    })
    local changes, overlays = self:flushChangesLocked(ctx)
    self:UpdateSnapshot(ctx, overlays, project.newSnapshotChange({
        reason = UpdateReason.DidOpenFile,
        fileChanges = changes,
        documents = { uri },
    }))
end

-- SetContentMapperContributions atomically replaces extension-provided inferred-project mappers and
-- discovers configured projects for matching open documents. Configured projects never consume these mappers.
function Session:SetContentMapperContributions(ctx, contributions, documentURIs)
    if not self.options.runExternalCode then
        return
    end
    self:cancelScheduledSnapshotUpdate()
    local changes, overlays = self:flushChangesLocked(ctx)
    self:UpdateSnapshot(ctx, overlays, project.newSnapshotChange({
        reason = UpdateReason.DidChangeContentMapperContributions,
        fileChanges = changes,
        contentMapperContributions = contributions,
        configuredProjectDocuments = documentURIs,
    }))
    self:updateContentMapperRegistrations(ctx, self:Snapshot())
end

function Session:DidCloseFile(ctx, uri)
    self:cancelWarmAutoImportCache()
    self:scheduleIdleCacheClean()
    self.pendingFileChanges = self.pendingFileChanges or {}
    self.pendingFileChanges[#self.pendingFileChanges + 1] = project.NewFileChange({
        kind = FileChangeKind.Close,
        uri = uri,
    })
    self:ScheduleSnapshotUpdate(UpdateReason.DidCloseFile)
end

function Session:DidChangeFile(ctx, uri, version, changes)
    self:cancelWarmAutoImportCache()
    self:scheduleIdleCacheClean()
    self.pendingFileChanges = self.pendingFileChanges or {}
    self.pendingFileChanges[#self.pendingFileChanges + 1] = project.NewFileChange({
        kind = FileChangeKind.Change,
        uri = uri,
        version = version,
        changes = changes,
    })

    -- Editing a content-mapped file changes the program like any source edit, but the client's
    -- pull-diagnostics machinery won't re-request diagnostics for dependent files: the content-mapped file is not
    -- in the diagnostic provider's document selector, so a change to it never triggers the client's
    -- inter-file re-pull. Prompt a workspace refresh so dependents update. We skip the debounce here so the
    -- edit doesn't feel sluggish (normal source edits are pulled per-keystroke client-side); the refresh is
    -- still coalesced. Ordinary source files are handled entirely client-side, so we cancel any pending
    -- refresh for them as before.
    if self:isContentMapperFile(uri) then
        self:scheduleDiagnosticsRefresh(0)
    else
        self:cancelDiagnosticsRefresh()
    end
end

-- isContentMapperFile reports whether uri is a content-mapped file handled by a configured content mapper, based
-- on the extensions currently registered with the client for text document synchronization.
function Session:isContentMapperFile(uri)
    local snapshot = self:Snapshot()
    local configured = snapshot.configFileRegistry:contentMappers()
    local extensions = {}
    for _, ext in ipairs(configured.extensions or {}) do
        extensions[#extensions + 1] = ext
    end
    for _, ext in ipairs(snapshot.inferredProjectContentMapperExtensions or {}) do
        extensions[#extensions + 1] = ext
    end
    return tspath.FileExtensionIsOneOf(lsproto.DocumentUri_FileName(uri), extensions)
end

function Session:DidSaveFile(ctx, uri)
    self:scheduleIdleCacheClean()
    self.pendingFileChanges = self.pendingFileChanges or {}
    self.pendingFileChanges[#self.pendingFileChanges + 1] = project.NewFileChange({
        kind = FileChangeKind.Save,
        uri = uri,
    })
end

function Session:DidChangeWatchedFiles(ctx, changes)
    local fileChanges = {}
    local hasRelevantChange = false
    local hasConfigChange = false
    local snapshot = self:Snapshot()
    local configFileRegistry = snapshot.configFileRegistry
    local contentMapperExtensions, contentMapperWatchedFiles = snapshot:contentMapperWatchState()
    for _, change in ipairs(changes or {}) do
        local kind
        if change.type == lsproto.FileChangeType.Created then
            kind = FileChangeKind.WatchCreate
        elseif change.type == lsproto.FileChangeType.Changed then
            kind = FileChangeKind.WatchChange
        elseif change.type == lsproto.FileChangeType.Deleted then
            kind = FileChangeKind.WatchDelete
        else
            goto continue -- Ignore unknown change types.
        end
        fileChanges[#fileChanges + 1] = project.NewFileChange({
            kind = kind,
            uri = change.uri,
        })

        if not hasConfigChange and configFileRegistry:isTracked(self.toPath(lsproto.DocumentUri_FileName(change.uri))) then
            hasConfigChange = true
        end

        if not hasRelevantChange then
            local fileName = lsproto.DocumentUri_FileName(change.uri)
            local path = tspath.Path_RemoveTrailingDirectorySeparator(self.toPath(fileName))
            local pathStr = path
            if contentMapperWatchedFiles:Has(path) then
                hasRelevantChange = true
                goto continue
            end
            local i = project.lastIndexByte(pathStr, ".")
            if i < 0 or project.lastIndexByte(pathStr, "/") > i then
                -- Extensionless paths might be directories.
                -- For creations/changes, we can check the file system.
                -- For deletions, consult the current snapshot cache to avoid treating extensionless file deletions as relevant.
                if kind ~= FileChangeKind.WatchDelete then
                    hasRelevantChange = self.fs.fs:DirectoryExists(fileName)
                else
                    local current = self.snapshot
                    if (current.fs.diskDirectories ~= nil and current.fs.diskDirectories[path] ~= nil) or project.isNodeModulesPath(path) then
                        hasRelevantChange = true
                    end
                end
            else
                if project.isRelevantExtension(string.sub(pathStr, i + 1)) or
                    tspath.FileExtensionIsOneOf(pathStr, contentMapperExtensions or {}) then
                    hasRelevantChange = true
                end
            end
        end
        ::continue::
    end

    self.pendingFileChanges = self.pendingFileChanges or {}
    for _, fc in ipairs(fileChanges) do
        self.pendingFileChanges[#self.pendingFileChanges + 1] = fc
    end

    if hasRelevantChange then
        -- Schedule a debounced diagnostics refresh only for paths
        -- that can affect the TypeScript program (relevant extensions or directories).
        self:ScheduleDiagnosticsRefresh()
    end
    if hasConfigChange then
        -- Config file diagnostics are pushed on snapshot updates rather than pulled,
        -- so they must not depend on the client re-pulling diagnostics in response to
        -- the refresh request above.
        self:ScheduleSnapshotUpdate(UpdateReason.DidChangeConfigFile)
    end
    self:cancelWarmAutoImportCache()
    self:scheduleIdleCacheClean()
end

function Session:DidChangeCompilerOptionsForInferredProjects(ctx, options)
    self.compilerOptionsForInferredProjects = options
    self:UpdateSnapshot(ctx, self.fs:Overlays(), project.newSnapshotChange({
        reason = UpdateReason.DidChangeCompilerOptionsForInferredProjects,
        compilerOptionsForInferredProjects = options,
    }))
end

function Session:ScheduleDiagnosticsRefresh()
    self:scheduleDiagnosticsRefresh(self.options.debounceDelay)
end

-- scheduleDiagnosticsRefresh schedules a coalesced workspace diagnostics refresh after delay. A delay of
-- 0 refreshes as soon as the background queue runs the task; it is used for interactive edits (e.g. a
-- content-mapped file) where the debounce would make dependent-file diagnostics feel sluggish.
-- In the sequential port the debounce window has elapsed when the background queue runs the task,
-- unless a newer event canceled it.
function Session:scheduleDiagnosticsRefresh(delay)
    -- Cancel any existing scheduled diagnostics refresh
    if self.diagnosticsRefreshCancel ~= nil then
        self.diagnosticsRefreshCancel()
        self.logger:Log("Delaying scheduled diagnostics refresh...")
    else
        self.logger:Log("Scheduling new diagnostics refresh...")
    end

    -- Create a new cancellable context for the debounce task
    local debounceCtx, cancel = core.WithCancel(self:backgroundContext())
    self.diagnosticsRefreshGeneration = self.diagnosticsRefreshGeneration + 1
    local generation = self.diagnosticsRefreshGeneration
    self.diagnosticsRefreshCancel = cancel

    -- Enqueue the (optionally debounced) diagnostics refresh
    self.backgroundQueue:Enqueue(debounceCtx, function(ctx)
        if core.ContextErr(ctx) ~= nil then
            cancel()
            return
        end

        -- Clear the cancel function since we're about to execute the refresh
        if self.diagnosticsRefreshGeneration ~= generation then
            cancel()
            return
        end
        self.diagnosticsRefreshCancel = nil

        if self.options.loggingEnabled then
            self.logger:Log("Running scheduled diagnostics refresh")
        end
        local err = self.client:RefreshDiagnostics(self:backgroundContext())
        if err ~= nil and self.options.loggingEnabled then
            self.logger:Logf("Error refreshing diagnostics: %v", err)
        end
        cancel()
    end)
end

function Session:cancelDiagnosticsRefresh()
    if self.diagnosticsRefreshCancel ~= nil then
        self.diagnosticsRefreshCancel()
        self.logger:Log("Canceled scheduled diagnostics refresh")
        self.diagnosticsRefreshCancel = nil
        self.diagnosticsRefreshGeneration = self.diagnosticsRefreshGeneration + 1
    end
end

function Session:ScheduleSnapshotUpdate(reason)
    -- Cancel any existing scheduled snapshot update
    if self.scheduledSnapshotUpdateCancel ~= nil then
        self.scheduledSnapshotUpdateCancel()
        if self.options.loggingEnabled then
            self.logger:Log("Delaying scheduled snapshot update...")
        end
    elseif self.options.loggingEnabled then
        self.logger:Log("Scheduling new snapshot update...")
    end

    -- Create a new cancellable context for the debounce task
    local debounceCtx, cancel = core.WithCancel(self:backgroundContext())
    self.scheduledSnapshotUpdateGeneration = self.scheduledSnapshotUpdateGeneration + 1
    local generation = self.scheduledSnapshotUpdateGeneration
    self.scheduledSnapshotUpdateCancel = cancel

    -- Enqueue the debounced snapshot update
    self.backgroundQueue:Enqueue(debounceCtx, function(ctx)
        -- The debounce delay has elapsed when the queue runs the task, unless it was canceled
        -- (newer events arrived or another snapshot update ran).
        if core.ContextErr(ctx) ~= nil then
            cancel()
            return
        end

        -- Clear the cancel function since we're about to execute the update
        if self.scheduledSnapshotUpdateGeneration ~= generation then
            cancel()
            return
        end
        self.scheduledSnapshotUpdateCancel = nil

        if self.options.loggingEnabled then
            self.logger:Log("Running scheduled snapshot update")
        end

        local fileChanges, overlays, ataChanges, newConfig = self:flushChanges(ctx)
        if project.FileChangeSummary_IsEmpty(fileChanges) and next(ataChanges) == nil and newConfig == nil then
            cancel()
            return
        end

        self:UpdateSnapshot(ctx, overlays, project.newSnapshotChange({
            reason = reason,
            fileChanges = fileChanges,
            ataChanges = ataChanges,
            newConfig = newConfig,
        }))
        cancel()
    end)
end

function Session:cancelScheduledSnapshotUpdate()
    if self.scheduledSnapshotUpdateCancel ~= nil then
        self.scheduledSnapshotUpdateCancel()
        if self.options.loggingEnabled then
            self.logger:Log("Canceled scheduled snapshot update")
        end
        self.scheduledSnapshotUpdateCancel = nil
        self.scheduledSnapshotUpdateGeneration = self.scheduledSnapshotUpdateGeneration + 1
    end
end

function Session:cancelWarmAutoImportCache()
    if self.warmAutoImportCancel ~= nil then
        self.warmAutoImportCancel()
        self.warmAutoImportCancel = nil
    end
end

project.idleCacheCleanDelay = 30

function Session:scheduleIdleCacheClean()
    if self.idleCacheCleanTimer ~= nil then
        self.idleCacheCleanTimer:Stop()
    end

    self.idleCacheCleanTimer = project.afterFunc(project.idleCacheCleanDelay, function()
        self.idleCacheCleanTimer = nil

        self:cancelScheduledSnapshotUpdate()

        local ctx = self:backgroundContext()
        local fileChanges, overlays, ataChanges, newConfig = self:flushChanges(ctx)
        self:UpdateSnapshot(ctx, overlays, project.newSnapshotChange({
            reason = UpdateReason.IdleCleanDiskCache,
            fileChanges = fileChanges,
            ataChanges = ataChanges,
            newConfig = newConfig,
            cleanDiskCache = true,
        }))

        collectgarbage()
    end)
end

function Session:cancelIdleCacheClean()
    if self.idleCacheCleanTimer ~= nil then
        self.idleCacheCleanTimer:Stop()
        self.idleCacheCleanTimer = nil
    end
end

project.performanceTelemetryInterval = 5 * 60

-- StartPerformanceTelemetry begins periodic collection and sending of performance
-- telemetry. It should be called once after the session is initialized.
-- (Go runs a ticker goroutine; the port re-arms a timer every interval.)
function Session:StartPerformanceTelemetry()
    if not self.options.telemetryEnabled then
        return
    end
    local ctx, cancel = core.WithCancel(self:backgroundContext())
    local timer
    local function tick()
        if core.ContextErr(ctx) ~= nil then
            return
        end
        if self.client ~= nil and self.client:IsActive() then
            self:sendPerformanceTelemetry(ctx)
        end
        timer = project.afterFunc(project.performanceTelemetryInterval, tick)
    end
    timer = project.afterFunc(project.performanceTelemetryInterval, tick)
    self.performanceTelemetryCancel = function()
        cancel()
        if timer ~= nil then
            timer:Stop()
        end
    end
end

function Session:stopPerformanceTelemetry()
    if self.performanceTelemetryCancel ~= nil then
        self.performanceTelemetryCancel()
        self.performanceTelemetryCancel = nil
    end
end

function Session:sendPerformanceTelemetry(ctx)
    if self.client == nil or not self.options.telemetryEnabled then
        return
    end
    local snapshot = self.snapshot

    -- Go runtime metrics (heap, GC, goroutines, system memory) have no Lua equivalent; the
    -- memory measurement uses the Lua heap size and the others stay 0.
    local measurements = {
        openFileCount = project.mapLen(snapshot.fs.overlays),
        uptimeSeconds = project.now() - self.startTime,
        projectCount = #snapshot.projectCollection:Projects(),
        configCount = project.mapLen(snapshot.configFileRegistry.configs),
        cachedDiskFileCount = project.mapLen(snapshot.fs.diskFiles),
        memoryUsedBytes = collectgarbage("count") * 1024,
        goMemLimit = 0,
        goGCPercent = 0,
        heapGoalBytes = 0,
        heapLiveBytes = 0,
        heapObjectCount = 0,
        heapStackBytes = 0,
        heapReleasedBytes = 0,
        heapFreeBytes = 0,
        gcScanHeapBytes = 0,
        goMaxProcs = 0,
        goroutineCount = 0,
        gcCyclesTotal = 0,
        gcCPUSeconds = 0,
        userCPUSeconds = os.clock(),
        systemMemTotal = 0,
        systemMemUsed = 0,
        autoImportProjectBucketCount = 0,
        autoImportNodeModulesBucketCount = 0,
        autoImportUniquePackageCount = 0,
        autoImportProjectExportCount = 0,
        autoImportProjectFileCount = 0,
        autoImportNodeModulesExportCount = 0,
        autoImportNodeModulesFileCount = 0,
        autoImportNodeModulesUnfilteredBucketCount = 0,
    }

    -- Read auto-import registry stats
    local registry = snapshot:AutoImportRegistry()
    if registry ~= nil then
        local autoImportStats = registry:GetCacheStats()
        measurements.autoImportProjectBucketCount = core.Len(autoImportStats.projectBuckets)
        measurements.autoImportNodeModulesBucketCount = core.Len(autoImportStats.nodeModulesBuckets)
        measurements.autoImportUniquePackageCount = autoImportStats.uniquePackageCount
        for _, b in ipairs(autoImportStats.projectBuckets or {}) do
            measurements.autoImportProjectExportCount = measurements.autoImportProjectExportCount + b.exportCount
            measurements.autoImportProjectFileCount = measurements.autoImportProjectFileCount + b.fileCount
        end
        for _, b in ipairs(autoImportStats.nodeModulesBuckets or {}) do
            measurements.autoImportNodeModulesExportCount = measurements.autoImportNodeModulesExportCount + b.exportCount
            measurements.autoImportNodeModulesFileCount = measurements.autoImportNodeModulesFileCount + b.fileCount
            if b.dependencyNames == nil then
                measurements.autoImportNodeModulesUnfilteredBucketCount = measurements.autoImportNodeModulesUnfilteredBucketCount + 1
            end
        end
    end

    local err = self.client:SendTelemetry(ctx, {
        performanceStatsTelemetryEvent = {
            measurements = measurements,
        },
    })
    if err ~= nil and self.options.loggingEnabled then
        self.logger:Logf("Error sending performance telemetry: %v", err)
    end
end

function Session:sendProjectInfoTelemetryForNewProjects(oldSnapshot, newSnapshot)
    if not self.options.telemetryEnabled then
        return
    end
    local ctx = self:backgroundContext()
    collections.DiffOrderedMaps(
        oldSnapshot.projectCollection:ProjectsByPath(),
        newSnapshot.projectCollection:ProjectsByPath(),
        function(_, addedProject)
            self:sendProjectInfoTelemetry(ctx, addedProject)
        end,
        function() end,
        function() end
    )
end

function Session:sendProjectInfoTelemetry(ctx, p)
    if self.client == nil or not self.options.telemetryEnabled then
        return
    end
    if self.seenProjects:Has(p.configFilePath) then
        return
    end

    if p.program == nil or p.commandLine == nil then
        return
    end

    local info = self:collectProjectInfoTelemetry(p)
    local err = self.client:SendTelemetry(ctx, info)
    if err ~= nil then
        if self.options.loggingEnabled then
            self.logger:Logf("Error sending project info telemetry: %v", err)
        end
        return
    end

    self.seenProjects:Add(p.configFilePath)
end

local function jsonString(s)
    return '"' .. string.gsub(s, '[%c"\\]', function(c)
        if c == '"' then
            return '\\"'
        elseif c == "\\" then
            return "\\\\"
        end
        return string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

function Session:collectProjectInfoTelemetry(p)
    local opts = p.commandLine:CompilerOptions()
    if opts == nil then
        opts = core.NewCompilerOptions()
    end

    local configFileName = "other"
    if p.kind == Kind.Configured then
        local baseName = tspath.GetBaseFileName(p.configFileName)
        if baseName == "tsconfig.json" or baseName == "jsconfig.json" then
            configFileName = baseName
        end
    end

    local projectType = "inferred"
    if p.kind == Kind.Configured then
        projectType = "configured"
    end

    local props = {
        configFileName = configFileName,
        projectType = projectType,
        version = core.Version(),
    }

    -- Compiler options — same approach as Strada's convertCompilerOptionsForTelemetry:
    -- booleans and enum string names, no paths.
    local compilerOptions = {}
    project.setTristate(compilerOptions, "strict", opts.strict)
    project.setTristate(compilerOptions, "noImplicitAny", opts.noImplicitAny)
    project.setTristate(compilerOptions, "noImplicitThis", opts.noImplicitThis)
    project.setTristate(compilerOptions, "strictNullChecks", opts.strictNullChecks)
    project.setTristate(compilerOptions, "strictFunctionTypes", opts.strictFunctionTypes)
    project.setTristate(compilerOptions, "strictBindCallApply", opts.strictBindCallApply)
    project.setTristate(compilerOptions, "strictPropertyInitialization", opts.strictPropertyInitialization)
    project.setTristate(compilerOptions, "strictBuiltinIteratorReturn", opts.strictBuiltinIteratorReturn)
    project.setTristate(compilerOptions, "useUnknownInCatchVariables", opts.useUnknownInCatchVariables)
    project.setTristate(compilerOptions, "exactOptionalPropertyTypes", opts.exactOptionalPropertyTypes)
    project.setTristate(compilerOptions, "allowJs", opts.allowJs)
    project.setTristate(compilerOptions, "checkJs", opts.checkJs)
    project.setTristate(compilerOptions, "noEmit", opts.noEmit)
    project.setTristate(compilerOptions, "declaration", opts.declaration)
    project.setTristate(compilerOptions, "composite", opts.composite)
    project.setTristate(compilerOptions, "isolatedModules", opts.isolatedModules)
    project.setTristate(compilerOptions, "skipLibCheck", opts.skipLibCheck)
    project.setTristate(compilerOptions, "incremental", opts.incremental)
    if opts.target ~= core.ScriptTarget.None then
        compilerOptions["target"] = core.ScriptTarget_String(opts.target)
    end
    if opts.module ~= core.ModuleKind.None then
        compilerOptions["module"] = core.ModuleKind_String(opts.module)
    end
    if opts.moduleResolution ~= core.ModuleResolutionKind.Unknown then
        compilerOptions["moduleResolution"] = core.ModuleResolutionKind_String(opts.moduleResolution)
    end
    if opts.jsx ~= core.JsxEmit.None then
        compilerOptions["jsx"] = core.JsxEmit_String(opts.jsx)
    end
    -- json.Marshal of a map sorts the keys.
    local parts = {}
    for _, key in ipairs(project.sortedKeys(compilerOptions)) do
        local v = compilerOptions[key]
        local encoded
        if type(v) == "boolean" then
            encoded = v and "true" or "false"
        else
            encoded = jsonString(v)
        end
        parts[#parts + 1] = jsonString(key) .. ":" .. encoded
    end
    props["compilerOptions"] = "{" .. table.concat(parts, ",") .. "}"

    -- Config file shape
    local raw = p.commandLine.raw
    if raw ~= nil and getmetatable(raw) == collections.OrderedMap then
        props["extends"] = project.boolTelemetry(raw:Has("extends"))
        props["files"] = project.boolTelemetry(raw:Has("files"))
        props["include"] = project.boolTelemetry(raw:Has("include"))
        props["exclude"] = project.boolTelemetry(raw:Has("exclude"))
    end

    return {
        projectInfoTelemetryEvent = {
            properties = props,
            measurements = project.countFileStats(p.program:GetSourceFiles()),
        },
    }
end

function project.setTristate(m, key, v)
    if v == Tristate.TSTrue then
        m[key] = true
    elseif v == Tristate.TSFalse then
        m[key] = false
    end
end

function project.boolTelemetry(v)
    if v then
        return "true"
    end
    return "false"
end

function project.countFileStats(sourceFiles)
    local stats = {
        jsFileCount = 0, jsFileSize = 0,
        jsxFileCount = 0, jsxFileSize = 0,
        dtsFileCount = 0, dtsFileSize = 0,
        tsFileCount = 0, tsFileSize = 0,
        tsxFileCount = 0, tsxFileSize = 0,
    }
    for _, sf in ipairs(sourceFiles or {}) do
        local size = sf:End()
        local kind = sf.scriptKind
        if kind == core.ScriptKind.JS then
            stats.jsFileCount = stats.jsFileCount + 1
            stats.jsFileSize = stats.jsFileSize + size
        elseif kind == core.ScriptKind.JSX then
            stats.jsxFileCount = stats.jsxFileCount + 1
            stats.jsxFileSize = stats.jsxFileSize + size
        elseif kind == core.ScriptKind.TS then
            if tspath.IsDeclarationFileName(sf:FileName()) then
                stats.dtsFileCount = stats.dtsFileCount + 1
                stats.dtsFileSize = stats.dtsFileSize + size
            else
                stats.tsFileCount = stats.tsFileCount + 1
                stats.tsFileSize = stats.tsFileSize + size
            end
        elseif kind == core.ScriptKind.TSX then
            stats.tsxFileCount = stats.tsxFileCount + 1
            stats.tsxFileSize = stats.tsxFileSize + size
        end
    end
    return stats
end

function Session:Snapshot()
    return self.snapshot
end

-- getSnapshot flushes pending changes and updates the session's snapshot
-- if needed for the given request. When callerRef is true, the returned
-- snapshot has an extra reference for the caller, guaranteeing it stays
-- alive until the caller calls Deref.
function Session:getSnapshot(ctx, request, callerRef)
    self:cancelScheduledSnapshotUpdate()

    local fileChanges, overlays, ataChanges, newConfig = self:flushChanges(ctx)
    local updateSnapshot = not project.FileChangeSummary_IsEmpty(fileChanges) or next(ataChanges) ~= nil or newConfig ~= nil
    if updateSnapshot then
        -- If there are pending file changes, we need to update the snapshot.
        -- Sending the requested URI ensures that the project for this URI is loaded.
        local change = project.newSnapshotChange(request)
        change.reason = UpdateReason.RequestedLanguageServicePendingChanges
        change.fileChanges = fileChanges
        change.ataChanges = ataChanges
        change.newConfig = newConfig
        return self:updateSnapshot(ctx, overlays, change, callerRef)
    end
    -- If there are no pending file changes, we can try to use the current snapshot.
    local snapshot = self.snapshot
    local updateReason = UpdateReason.Unknown
    if core.Len(request.projects) > 0 then
        updateReason = UpdateReason.RequestedLanguageServiceProjectDirty
    elseif request.projectTree ~= nil then
        updateReason = UpdateReason.RequestedLoadProjectTree
    elseif (request.autoImports or "") ~= "" then
        updateReason = UpdateReason.RequestedLanguageServiceWithAutoImports
    else
        for _, document in ipairs(request.documents or {}) do
            local p = snapshot:GetDefaultProject(document)
            if p == nil then
                updateReason = UpdateReason.RequestedLanguageServiceProjectNotLoaded
            elseif p.dirty then
                updateReason = UpdateReason.RequestedLanguageServiceProjectDirty
            end
        end
        if updateReason == UpdateReason.Unknown then
            for _, document in ipairs(request.configuredProjectDocuments or {}) do
                if snapshot.fs:isOpenFile(lsproto.DocumentUri_FileName(document)) then
                    local p = snapshot:GetDefaultProject(document)
                    if p == nil then
                        updateReason = UpdateReason.RequestedLanguageServiceProjectNotLoaded
                    elseif p.dirty then
                        updateReason = UpdateReason.RequestedLanguageServiceProjectDirty
                    end
                else
                    updateReason = UpdateReason.RequestedLanguageServiceForFileNotOpen
                end
            end
        end
    end
    if updateReason == UpdateReason.Unknown then
        if callerRef then
            snapshot:ref()
        end
        return snapshot
    end

    local change = project.newSnapshotChange(request)
    change.reason = updateReason
    return self:updateSnapshot(ctx, overlays, change, callerRef)
end

-- getSnapshotAndDefaultProject returns (snapshot, project, languageService, error).
function Session:getSnapshotAndDefaultProject(ctx, uri, callerRef)
    local snapshot = self:getSnapshot(
        ctx,
        { documents = { uri } },
        callerRef
    )
    local p = snapshot:GetDefaultProject(uri)
    if p == nil then
        if callerRef then
            snapshot:Deref(self)
        end
        local file = snapshot:GetFile(lsproto.DocumentUri_FileName(uri))
        if file ~= nil and file:Kind() == core.ScriptKind.Unknown then
            return nil, nil, nil, project.errorf("%w: no project found for URI %s", project.ErrNoProjectForUnknownScriptKind, uri)
        end
        return nil, nil, nil, project.errorf("no project found for URI %s", uri)
    end
    return snapshot, p, ls.NewLanguageService(p.configFilePath, p:GetProgram(), snapshot, lsproto.DocumentUri_FileName(uri)), nil
end

-- GetLanguageService returns (languageService, error).
function Session:GetLanguageService(ctx, uri)
    local _, _, languageService, err = self:getSnapshotAndDefaultProject(ctx, uri, false)
    if err ~= nil then
        return nil, err
    end
    return languageService, nil
end

-- GetLanguageServiceAndProjectsForFile returns (project, languageService, allProjects, error).
function Session:GetLanguageServiceAndProjectsForFile(ctx, uri)
    local snapshot, p, defaultLs, err = self:getSnapshotAndDefaultProject(ctx, uri, false)
    if err ~= nil then
        return nil, nil, nil, err
    end
    -- !!! TODO: sheetal:  Get other projects that contain the file with symlink
    local allProjects = snapshot:GetProjectsContainingFile(uri)
    return p, defaultLs, allProjects, nil
end

-- GetProjectsForFile returns (projects, error).
function Session:GetProjectsForFile(ctx, uri)
    local snapshot = self:getSnapshot(
        ctx,
        { configuredProjectDocuments = { uri } },
        false
    )

    -- !!! TODO: sheetal:  Get other projects that contain the file with symlink
    local allProjects = snapshot:GetProjectsContainingFile(uri)
    return allProjects, nil
end

-- GetLanguageServicesForDocumentsLoadingProjectTree returns language services for
-- every project in the snapshot, loading all project trees first so that projects
-- that were never opened but reference the given documents are included. Loading the
-- trees is expensive, so this should only be used by operations that need to touch
-- every project in a solution, like file rename.
function Session:GetLanguageServicesForDocumentsLoadingProjectTree(ctx, uris)
    local snapshot = self:getSnapshot(
        ctx,
        {
            documents = uris,
            projectTree = project.NewProjectTreeRequest(nil),
        },
        false
    )

    local activeFile = ""
    if core.Len(uris) > 0 then
        activeFile = lsproto.DocumentUri_FileName(uris[1])
    end

    local projects = snapshot.projectCollection:Projects()
    local services = {}
    for _, p in ipairs(projects) do
        local program = p:GetProgram()
        if program ~= nil then
            services[#services + 1] = ls.NewLanguageService(p.configFilePath, program, snapshot, activeFile)
        end
    end
    return services
end

function Session:GetLanguageServiceForProjectWithFile(ctx, p, uri)
    local snapshot = self:getSnapshot(
        ctx,
        { projects = { p:Id() } },
        false
    )
    -- Ensure we have updated project
    p = snapshot.projectCollection:GetProjectByPath(p:Id())
    if p == nil then
        return nil
    end
    -- if program doesnt contain this file any more ignore it
    if not p:HasFile(lsproto.DocumentUri_FileName(uri)) then
        return nil
    end
    return ls.NewLanguageService(p.configFilePath, p:GetProgram(), snapshot, lsproto.DocumentUri_FileName(uri))
end

-- runWithSnapshot calls fn(snapshot) and Derefs snapshot afterwards, also when fn raises.
local function runWithSnapshot(session, snapshot, fn)
    local ok, err = pcall(fn, snapshot)
    snapshot:Deref(session)
    if not ok then
        error(err, 0)
    end
end

-- WithSnapshotLoadingProjectTree acquires a ref'd snapshot with the
-- requested project trees loaded, then calls fn. The snapshot stays alive
-- for the duration of fn.
function Session:WithSnapshotLoadingProjectTree(ctx, requestedProjectTrees, fn)
    local snapshot = self:getSnapshot(
        ctx,
        { projectTree = project.NewProjectTreeRequest(requestedProjectTrees) },
        true
    )
    runWithSnapshot(self, snapshot, fn)
end

function Session:WithSnapshotForDocument(ctx, uri, fn)
    local snapshot = self:getSnapshot(
        ctx,
        { documents = { uri } },
        true
    )
    runWithSnapshot(self, snapshot, fn)
end

-- GetCurrentLanguageServiceWithAutoImports flushes pending file changes, clones the
-- current snapshot with auto-import preparation for the given URI, then returns a
-- LanguageService for the default project. Use this only outside of request handling
-- (e.g. cache warming). For request handlers, use GetLanguageServiceWithAutoImports
-- with the request-level snapshot instead.
function Session:GetCurrentLanguageServiceWithAutoImports(ctx, uri)
    local snapshot = self:getSnapshot(ctx, {
        documents = { uri },
        autoImports = uri,
    }, false)
    local p = snapshot:GetDefaultProject(uri)
    if p == nil then
        return nil, project.errorf("no project found for URI %s", uri)
    end
    return ls.NewLanguageService(p.configFilePath, p:GetProgram(), snapshot, lsproto.DocumentUri_FileName(uri)), nil
end

-- WithLanguageServiceAndSnapshot synchronously acquires a ref'd snapshot and
-- creates a language service for the given URI. fn receives both the language
-- service and the backing snapshot so it can clone the snapshot (e.g. to
-- enable auto-imports). The snapshot is kept alive until the async work
-- completes.
--
-- Only use this method when the callback needs direct access to the snapshot.
-- For handlers that only need a LanguageService, use GetLanguageService
-- directly—language services continue to work even after their backing
-- snapshot has been disposed.
-- fn returns (asyncWork, error); this returns (asyncWork wrapper, error).
function Session:WithLanguageServiceAndSnapshot(ctx, uri, fn)
    local snapshot, _, languageService, err = self:getSnapshotAndDefaultProject(ctx, uri, true)
    if err ~= nil then
        return nil, err
    end
    local asyncWork
    asyncWork, err = fn(languageService, snapshot)
    if err ~= nil or asyncWork == nil then
        snapshot:Deref(self)
        return nil, err
    end
    return function()
        local ok, result = pcall(asyncWork)
        snapshot:Deref(self)
        if not ok then
            error(result, 0)
        end
        return result
    end, nil
end

-- GetLanguageServiceWithAutoImports clones the given snapshot with auto-import
-- preparation for the given URI, without flushing pending file changes.
-- The cloned snapshot will be adopted as the session's current snapshot in the background
-- if other changes haven't been adopted in the meantime.
function Session:GetLanguageServiceWithAutoImports(ctx, baseSnapshot, uri)
    local newSnapshot = self:cloneWithAutoImports(ctx, baseSnapshot, uri, false)
    local p = newSnapshot:GetDefaultProject(uri)
    if p == nil then
        -- Clone's initial ref (1) is released since we won't use this snapshot.
        newSnapshot:Deref(self)
        return nil, project.errorf("no project found for URI %s", uri)
    end

    self:adoptSnapshotChangeInBackground(baseSnapshot, newSnapshot)

    return ls.NewLanguageService(p.configFilePath, p:GetProgram(), newSnapshot, lsproto.DocumentUri_FileName(uri)), nil
end

-- GetSnapshotWithAutoImports clones the given snapshot with auto-import
-- preparation for the given URI, without flushing pending file changes.
-- The returned snapshot is ref'd for the caller, which must call Deref when done.
-- The cloned snapshot will also be adopted as the session's current snapshot in
-- the background if other changes haven't been adopted in the meantime.
function Session:GetSnapshotWithAutoImports(ctx, baseSnapshot, uri)
    local newSnapshot = self:cloneWithAutoImports(ctx, baseSnapshot, uri, true)
    self:adoptSnapshotChangeInBackground(baseSnapshot, newSnapshot)
    return newSnapshot
end

function Session:cloneWithAutoImports(ctx, baseSnapshot, uri, callerRef)
    local change = project.newSnapshotChange({
        reason = UpdateReason.RequestedLanguageServiceWithAutoImports,
        documents = { uri },
        autoImports = uri,
    })
    local newSnapshot = baseSnapshot:Clone(ctx, change, baseSnapshot.fs.overlays, self)
    if callerRef then
        newSnapshot:ref()
    end
    return newSnapshot
end

function Session:adoptSnapshotChangeInBackground(baseSnapshot, newSnapshot)
    -- The clone's initial ref (1) is transferred to adoptSnapshotChange,
    -- which will either promote it as the session's current snapshot or
    -- release it if the session has moved on.
    self.backgroundQueue:Enqueue(self:backgroundContext(), function(ctx)
        self:adoptSnapshotChange(baseSnapshot, newSnapshot)
    end)
end

-- adoptSnapshotChange promotes a cloned snapshot as the session's current
-- snapshot so future requests benefit from the work already done. If the
-- session has moved on, the snapshot is discarded; the next request needing
-- auto-imports will redo the work on the latest snapshot.
function Session:adoptSnapshotChange(baseSnapshot, newSnapshot)
    local oldSnapshot = self.snapshot
    if oldSnapshot == baseSnapshot then
        -- Session hasn't moved on; adopt the new snapshot. The clone's initial
        -- ref is transferred to become the session's ref for its current snapshot.
        self.snapshot = newSnapshot
        oldSnapshot:Deref(self)
        local contentMapperTimings = self:takeContentMapperTimingDelta()
        if self.options.loggingEnabled then
            self.logger:Logf("Adopted snapshot %d (parent %d) as current session snapshot (replacing %d)", newSnapshot.id, newSnapshot.parentId, oldSnapshot.id)
            self.logger:Log(newSnapshot.builderLogs:String())
            self:logContentMapperTimings(contentMapperTimings)
        end
    else
        -- Session has moved on to a newer snapshot; discard this one.
        -- Release the clone's initial ref. If a handler is still using
        -- the snapshot, its own ref keeps it alive.
        if self.options.loggingEnabled then
            self.logger:Logf("Discarded snapshot %d (parent %d); session has moved on to snapshot %d", newSnapshot.id, newSnapshot.parentId, oldSnapshot.id)
            local logs = newSnapshot.builderLogs:String()
            if logs ~= "" then
                self.logger:Logf("--- Discarded snapshot %d builder logs (NOT adopted) ---", newSnapshot.id)
                self.logger:Log(logs)
                self.logger:Logf("--- End discarded snapshot %d builder logs ---", newSnapshot.id)
            end
        end
        newSnapshot:Deref(self)
    end
end

function Session:UpdateSnapshot(ctx, overlays, change)
    self:updateSnapshot(ctx, overlays, change, false)
end

-- updateSnapshotRef is like UpdateSnapshot but returns the created snapshot
-- with an extra reference for the caller. The caller must call snapshot.Deref(s) when done.
function Session:updateSnapshotRef(ctx, overlays, change)
    return self:updateSnapshot(ctx, overlays, change, true)
end

function Session:updateSnapshot(ctx, overlays, change, callerRef)
    local oldSnapshot = self.snapshot
    local newSnapshot = oldSnapshot:Clone(ctx, change, overlays, self)
    self.snapshot = newSnapshot
    if callerRef then
        newSnapshot:ref()
    end
    local contentMapperTimings = nil
    if newSnapshot ~= oldSnapshot then
        -- Release the session's reference to the old snapshot. The new snapshot's
        -- clone ref (1) is transferred to become the session's ref for its current
        -- snapshot. Other holders (e.g. active handlers) keep the old snapshot alive
        -- via their own refs until they complete.
        oldSnapshot:Deref(self)
        contentMapperTimings = self:takeContentMapperTimingDelta()
    end

    -- Enqueue ATA updates if needed
    if self.typingsInstaller ~= nil and not self:Config():IsATADisabled() then
        self:triggerATAForUpdatedProjects(newSnapshot)
    end

    -- Enqueue logging, watch updates, and diagnostic refresh tasks
    -- !!! userPreferences/configuration updates
    self.backgroundQueue:Enqueue(self:backgroundContext(), function(bgCtx)
        if self.options.loggingEnabled then
            self.logger:Logf("Adopted snapshot %d (parent %d) as current session snapshot (replacing %d)", newSnapshot.id, newSnapshot.parentId, oldSnapshot.id)
            self.logger:Log(newSnapshot.builderLogs:String())
            self:logProjectChanges(oldSnapshot, newSnapshot)
            self:logContentMapperTimings(contentMapperTimings)
            self.logger:Log("")
        end
        if self.options.watchEnabled then
            local err = self:updateWatches(oldSnapshot, newSnapshot)
            if err ~= nil and self.options.loggingEnabled then
                self.logger:Log(err)
            end
        end
        self:updateContentMapperRegistrations(bgCtx, newSnapshot)
        self:publishProgramDiagnostics(oldSnapshot, newSnapshot)
        self:sendProjectInfoTelemetryForNewProjects(oldSnapshot, newSnapshot)
        self:warmAutoImportCache(bgCtx, change, oldSnapshot, newSnapshot)
    end)

    return newSnapshot
end

function Session:takeContentMapperTimingDelta()
    if self.contentMapperHost == nil then
        return nil
    end
    local current = self.contentMapperHost:Timings()
    local delta = current:Since(self.contentMapperTimings)
    self.contentMapperTimings = current
    return delta
end

-- logContentMapperTimings logs a contentmapper.Timings delta (nil for the zero value).
function Session:logContentMapperTimings(timings)
    if timings == nil or (timings.requestWait or 0) == 0 then
        return
    end
    self.logger:Log("Content mapper timings since previous snapshot adoption:")
    if timings.requestWait ~= 0 then
        self.logger:Logf("  Request wait time: %v", project.Duration.String({ seconds = timings.requestWait }))
    end
    for _, identity in ipairs(project.sortedKeys(timings.mappers)) do
        local mapper = timings.mappers[identity]
        if mapper.spawn.count == 0 and mapper.openProject.count == 0 and mapper.closeProject.count == 0 and mapper.transform.count == 0 then
            goto continue
        end
        self.logger:Logf("  %s:", identity)
        if mapper.spawn.count ~= 0 then
            self.logger:Logf("    Initializations: %d (%v)", mapper.spawn.count, project.Duration.String({ seconds = mapper.spawn.duration + mapper.initialize.duration }))
        end
        if mapper.openProject.count ~= 0 then
            self.logger:Logf("    openProject requests: %d (%v)", mapper.openProject.count, project.Duration.String({ seconds = mapper.openProject.duration }))
        end
        if mapper.closeProject.count ~= 0 then
            self.logger:Logf("    closeProject requests: %d (%v)", mapper.closeProject.count, project.Duration.String({ seconds = mapper.closeProject.duration }))
        end
        if mapper.transform.count ~= 0 then
            self.logger:Logf("    Transforms: %d (%v)", mapper.transform.count, project.Duration.String({ seconds = mapper.transform.duration }))
        end
        ::continue::
    end
end

-- WaitForBackgroundTasks waits for all background tasks to complete.
-- This is intended to be used only for testing purposes.
function Session:WaitForBackgroundTasks()
    self:cancelIdleCacheClean()
    self.backgroundQueue:Wait()
end

-- updateWatch returns a list of errors (possibly empty).
function project.updateWatch(ctx, session, logger, oldWatcher, newWatcher)
    local errors = {}
    if newWatcher ~= nil then
        local w = newWatcher:Watchers()
        local watchers = {}
        for _, x in ipairs(w.workspaceWatchers or {}) do
            watchers[#watchers + 1] = x
        end
        for _, x in ipairs(w.outsideWorkspaceWatchers or {}) do
            watchers[#watchers + 1] = x
        end
        if #watchers > 0 then
            local newWatchers = collections.NewOrderedMap()
            for i1, watcher in ipairs(watchers) do
                local globId = w.watcherID .. "." .. tostring(i1 - 1)
                if session.watches:Acquire(watcher, globId) then
                    newWatchers:Set(globId, watcher)
                end
            end
            local watchErrors = {}
            for id, watcher in newWatchers:Entries() do
                -- Create a fresh timeout per client call so earlier calls
                -- don't consume the deadline for later ones.
                local callCtx, callCancel = core.WithTimeout(ctx, project.watchRequestTimeout)
                local err = session.client:WatchFiles(callCtx, id, { watcher })
                callCancel()
                if err ~= nil then
                    watchErrors[#watchErrors + 1] = err
                elseif logger ~= nil then
                    if oldWatcher == nil then
                        logger:Log("Added new watch: " .. id)
                    else
                        logger:Log("Updated watch: " .. id)
                    end
                    logger:Log("\t" .. project.fileSystemWatcherGlobString(watcher))
                    logger:Log("")
                end
            end
            if #watchErrors > 0 then
                -- Roll back ALL newly-acquired watchers on any failure to keep
                -- refcounts clean. On retry, Acquire will see them as new again.
                -- Re-registering an already-registered watcher with the client
                -- is harmless (registerCapability with the same ID replaces it).
                for _, watcher in newWatchers:Entries() do
                    session.watches:Release(watcher)
                end
                session.watches:MarkPending(w.watcherID)
                for _, e in ipairs(watchErrors) do
                    errors[#errors + 1] = e
                end
            else
                session.watches:ClearPending(w.watcherID)
            end
            if next(w.ignoredPaths or {}) ~= nil then
                logger:Logf("%d paths ineligible for watching", project.mapLen(w.ignoredPaths))
                if logger:IsVerbose() then
                    for _, path in ipairs(project.sortedKeys(w.ignoredPaths)) do
                        logger:Log("\t" .. path)
                    end
                end
            end
        end
    end
    if oldWatcher ~= nil then
        local w = oldWatcher:Watchers()
        local watchers = {}
        for _, x in ipairs(w.workspaceWatchers or {}) do
            watchers[#watchers + 1] = x
        end
        for _, x in ipairs(w.outsideWorkspaceWatchers or {}) do
            watchers[#watchers + 1] = x
        end
        if #watchers > 0 then
            local removedIDs = {}
            for _, watcher in ipairs(watchers) do
                local id, removed = session.watches:Release(watcher)
                if removed then
                    removedIDs[#removedIDs + 1] = id
                end
            end
            for _, id in ipairs(removedIDs) do
                local callCtx, callCancel = core.WithTimeout(ctx, project.watchRequestTimeout)
                local err = session.client:UnwatchFiles(callCtx, id)
                callCancel()
                if err ~= nil then
                    errors[#errors + 1] = err
                elseif logger ~= nil and newWatcher == nil then
                    logger:Log("Removed watch: " .. id)
                end
            end
        end
    end
    return errors
end

-- updateContentMapperRegistrations computes the union of content mapper extensions across all loaded
-- configs in the new snapshot and, when the set changes, asks the client to synchronize text documents
-- with those extensions. This is how an otherwise unsupported file (e.g. a `.vue`) begins flowing to the server once a
-- config that maps it is discovered.
function Session:updateContentMapperRegistrations(ctx, snapshot)
    if self.client == nil then
        return nil
    end
    local contentMappers = snapshot.configFileRegistry:contentMappers()
    local extensions = {}
    for _, ext in ipairs(contentMappers.extensions or {}) do
        extensions[#extensions + 1] = ext
    end
    for _, ext in ipairs(snapshot.inferredProjectContentMapperExtensions or {}) do
        extensions[#extensions + 1] = ext
    end
    extensions = project.sortedCompact(extensions)

    -- Background tasks may finish out of order; never let an older snapshot's task overwrite the
    -- registration derived from a newer one.
    if snapshot:ID() <= self.registeredContentMapperSnapshotID then
        return nil
    end
    if project.slicesEqual(extensions, self.registeredContentMapperExtensions) then
        self.registeredContentMapperSnapshotID = snapshot:ID()
        return nil
    end
    -- RegisterContentMapperExtensions replaces the prior registration wholesale (unregistering extensions
    -- that are no longer mapped and registering the current set), so an empty set removes the registration
    -- once the last mapping config unloads. On failure we leave the state unadvanced so the next snapshot
    -- update retries.
    local err = self.client:RegisterContentMapperExtensions(ctx, extensions)
    if err ~= nil then
        if self.options.loggingEnabled then
            self.logger:Log(err)
        end
        return err
    end
    self.registeredContentMapperExtensions = extensions
    self.registeredContentMapperSnapshotID = snapshot:ID()
    return nil
end

function Session:updateWatches(oldSnapshot, newSnapshot)
    local errors = {}
    local function appendErrors(errs)
        for _, e in ipairs(errs) do
            errors[#errors + 1] = e
        end
    end
    local start = project.now()
    local ctx = self:backgroundContext()
    local WatchedFiles = project.WatchedFiles
    core.DiffMapsFunc(
        oldSnapshot.configFileRegistry.configs,
        newSnapshot.configFileRegistry.configs,
        function(a, b)
            return WatchedFiles.ID(a.rootFilesWatch) == WatchedFiles.ID(b.rootFilesWatch)
        end,
        function(_, addedEntry)
            appendErrors(project.updateWatch(ctx, self, self.logger, nil, addedEntry.rootFilesWatch))
        end,
        function(_, removedEntry)
            appendErrors(project.updateWatch(ctx, self, self.logger, removedEntry.rootFilesWatch, nil))
        end,
        function(_, oldEntry, newEntry)
            appendErrors(project.updateWatch(ctx, self, self.logger, oldEntry.rootFilesWatch, newEntry.rootFilesWatch))
        end
    )
    -- Retry config watchers whose IDs didn't change but whose previous registration failed.
    for _, path in ipairs(project.sortedKeys(newSnapshot.configFileRegistry.configs)) do
        local newEntry = newSnapshot.configFileRegistry.configs[path]
        local oldEntry = oldSnapshot.configFileRegistry.configs ~= nil and oldSnapshot.configFileRegistry.configs[path] or nil
        if oldEntry ~= nil then
            if WatchedFiles.ID(oldEntry.rootFilesWatch) == WatchedFiles.ID(newEntry.rootFilesWatch) then
                if self.watches:IsPending(WatchedFiles.ID(newEntry.rootFilesWatch)) then
                    appendErrors(project.updateWatch(ctx, self, self.logger, nil, newEntry.rootFilesWatch))
                end
            end
        end
    end

    collections.DiffOrderedMaps(
        oldSnapshot.projectCollection:ProjectsByPath(),
        newSnapshot.projectCollection:ProjectsByPath(),
        function(_, addedProject)
            appendErrors(project.updateWatch(ctx, self, self.logger, nil, addedProject.programFilesWatch))
            appendErrors(project.updateWatch(ctx, self, self.logger, nil, addedProject.typingsWatch))
            appendErrors(project.updateWatch(ctx, self, self.logger, nil, addedProject.contentMapperWatch))
        end,
        function(_, removedProject)
            appendErrors(project.updateWatch(ctx, self, self.logger, removedProject.programFilesWatch, nil))
            appendErrors(project.updateWatch(ctx, self, self.logger, removedProject.typingsWatch, nil))
            appendErrors(project.updateWatch(ctx, self, self.logger, removedProject.contentMapperWatch, nil))
        end,
        function(_, oldProject, newProject)
            if WatchedFiles.ID(oldProject.programFilesWatch) ~= WatchedFiles.ID(newProject.programFilesWatch) then
                appendErrors(project.updateWatch(ctx, self, self.logger, oldProject.programFilesWatch, newProject.programFilesWatch))
            else
                if self.watches:IsPending(WatchedFiles.ID(newProject.programFilesWatch)) then
                    appendErrors(project.updateWatch(ctx, self, self.logger, nil, newProject.programFilesWatch))
                end
            end
            if WatchedFiles.ID(oldProject.typingsWatch) ~= WatchedFiles.ID(newProject.typingsWatch) then
                appendErrors(project.updateWatch(ctx, self, self.logger, oldProject.typingsWatch, newProject.typingsWatch))
            else
                if self.watches:IsPending(WatchedFiles.ID(newProject.typingsWatch)) then
                    appendErrors(project.updateWatch(ctx, self, self.logger, nil, newProject.typingsWatch))
                end
            end
            if WatchedFiles.ID(oldProject.contentMapperWatch) ~= WatchedFiles.ID(newProject.contentMapperWatch) then
                appendErrors(project.updateWatch(ctx, self, self.logger, oldProject.contentMapperWatch, newProject.contentMapperWatch))
            elseif self.watches:IsPending(WatchedFiles.ID(newProject.contentMapperWatch)) then
                appendErrors(project.updateWatch(ctx, self, self.logger, nil, newProject.contentMapperWatch))
            end
        end
    )

    if WatchedFiles.ID(oldSnapshot.autoImportsWatch) ~= WatchedFiles.ID(newSnapshot.autoImportsWatch) then
        appendErrors(project.updateWatch(ctx, self, self.logger, oldSnapshot.autoImportsWatch, newSnapshot.autoImportsWatch))
    else
        if self.watches:IsPending(WatchedFiles.ID(newSnapshot.autoImportsWatch)) then
            appendErrors(project.updateWatch(ctx, self, self.logger, nil, newSnapshot.autoImportsWatch))
        end
    end

    if #errors > 0 then
        local messages = {}
        for i, e in ipairs(errors) do
            messages[i] = logging.fmtValue(e)
        end
        return project.newError("errors updating watches: [" .. table.concat(messages, " ") .. "]")
    elseif self.options.loggingEnabled then
        self.logger:Log("Updated watches in " .. project.since(start):String())
    end
    return nil
end

function Session:Close()
    -- Cancel any pending scheduled snapshot update
    self:cancelScheduledSnapshotUpdate()
    -- Cancel any pending diagnostics refresh
    self:cancelDiagnosticsRefresh()
    -- Cancel any pending auto-import cache warming
    self:cancelWarmAutoImportCache()
    -- Cancel any pending idle cache clean
    self:cancelIdleCacheClean()
    -- Cancel periodic performance telemetry
    self:stopPerformanceTelemetry()
    self.backgroundQueue:Close()
    if self.contentMapperHost ~= nil then
        self.contentMapperHost:Close()
    end
end

-- flushChanges returns (FileChangeSummary, overlays, ataChanges, newPrefs or nil).
function Session:flushChanges(ctx)
    local pendingATAChanges = self.pendingATAChanges
    self.pendingATAChanges = {}
    local fileChanges, overlays = self:flushChangesLocked(ctx)
    local newPrefs = nil
    if self.pendingUserConfigChanges then
        newPrefs = project.copyValue(self.workspaceUserPreferences)
    end
    self.pendingUserConfigChanges = false
    return fileChanges, overlays, pendingATAChanges, newPrefs
end

-- flushChangesLocked returns (FileChangeSummary, overlays).
function Session:flushChangesLocked(ctx)
    if self.pendingFileChanges == nil or #self.pendingFileChanges == 0 then
        return project.newFileChangeSummary(), self.fs:Overlays()
    end

    local start = project.now()
    local changes, overlays = self.fs:processChanges(self.pendingFileChanges)
    if self.options.loggingEnabled then
        self.logger:Log(string.format("Processed %d file changes in %s", #self.pendingFileChanges, project.since(start):String()))
    end
    self.pendingFileChanges = nil
    return changes, overlays
end

-- logProjectChanges logs information about projects that have changed between snapshots
function Session:logProjectChanges(oldSnapshot, newSnapshot)
    local loggedProjectChanges = false
    local function logProject(p)
        local builder = core.NewStringBuilder()
        p:print(self.logger:IsVerbose(), self.logger:IsVerbose(), builder)
        self.logger:Log(builder:String())
        loggedProjectChanges = true
    end
    collections.DiffOrderedMaps(
        oldSnapshot.projectCollection:ProjectsByPath(),
        newSnapshot.projectCollection:ProjectsByPath(),
        function(path, addedProject)
            -- New project added
            logProject(addedProject)
        end,
        function(path, removedProject)
            -- Project removed
            self.logger:Logf("\nProject '%s' removed\n%s", removedProject:Name(), project.hr)
        end,
        function(path, oldProject, newProject)
            -- Project updated
            if newProject.programUpdateKind == ProgramUpdateKind.NewFiles then
                logProject(newProject)
            end
        end
    )

    if loggedProjectChanges or self.logger:IsVerbose() then
        self:logCacheStats(newSnapshot)
    end
end

function Session:logCacheStats(snapshot)
    local parseCacheSize = 0
    local extendedConfigCount = 0
    if self.logger:IsVerbose() then
        self.parseCache.entries:Range(function()
            parseCacheSize = parseCacheSize + 1
            return true
        end)
        self.extendedConfigCache.entries:Range(function()
            extendedConfigCount = extendedConfigCount + 1
            return true
        end)
    end
    self.logger:Log("\n======== Cache Statistics ========")
    self.logger:Logf("Open file count:   %6d", project.mapLen(snapshot.fs.overlays))
    self.logger:Logf("Cached disk files: %6d", project.mapLen(snapshot.fs.diskFiles))
    self.logger:Logf("Realpath aliases:  %6d", project.mapLen(snapshot.fs.nodeModulesRealpathAliases))
    self.logger:Logf("Project count:     %6d", #snapshot.projectCollection:Projects())
    self.logger:Logf("Config count:      %6d", project.mapLen(snapshot.configFileRegistry.configs))
    if self.logger:IsVerbose() then
        self.logger:Logf("Parse cache size:           %6d", parseCacheSize)
        self.logger:Logf("Program count:              %6d", self.programCounter:Len())
        self.logger:Logf("Extended config cache size: %6d", extendedConfigCount)

        self.logger:Log("Auto Imports:")
        local autoImportStats = snapshot:AutoImportRegistry():GetCacheStats()
        self.logger:Logf("\tUnique packages (by realpath): %d", autoImportStats.uniquePackageCount)
        if core.Len(autoImportStats.projectBuckets) > 0 then
            self.logger:Log("\tProject buckets:")
            for _, bucket in ipairs(autoImportStats.projectBuckets) do
                self.logger:Logf("\t\t%s%s:", bucket.path, core.IfElse(bucket.state:Dirty(), " (dirty)", ""))
                self.logger:Logf("\t\t\tFiles: %d", bucket.fileCount)
                self.logger:Logf("\t\t\tExports: %d", bucket.exportCount)
            end
        end
        if core.Len(autoImportStats.nodeModulesBuckets) > 0 then
            self.logger:Log("\tnode_modules buckets:")
            for _, bucket in ipairs(autoImportStats.nodeModulesBuckets) do
                self.logger:Logf("\t\t%s%s:", bucket.path, core.IfElse(bucket.state:Dirty(), " (dirty)", ""))
                for _, packageName in ipairs(project.sortedKeys(project.setKeys(bucket.state:DirtyPackages()))) do
                    self.logger:Logf("\t\t\tNeeds granular update: %s", packageName)
                end
                if bucket.dependencyNames ~= nil then
                    self.logger:Logf("\t\t\tCollected packages: %d", bucket.dependencyNames:Len())
                else
                    self.logger:Logf("\t\t\tCollected packages: all, due to no package.json!")
                end
                self.logger:Logf("\t\t\tTotal packages: %d", bucket.packageNames:Len())
                self.logger:Logf("\t\t\tFiles: %d", bucket.fileCount)
                self.logger:Logf("\t\t\tExports: %d", bucket.exportCount)
                if bucket.state:RecursiveSearchPackages() == nil then
                    self.logger:Log("\t\t\tRecursive search: all")
                elseif bucket.state:RecursiveSearchPackages():Len() > 0 then
                    self.logger:Logf("\t\t\tRecursive search: %d packages", bucket.state:RecursiveSearchPackages():Len())
                else
                    self.logger:Log("\t\t\tRecursive search: none")
                end
            end
        end
    end
end

-- NpmInstall returns (output, error).
function Session:NpmInstall(cwd, npmInstallArgs)
    return self.npmExecutor:NpmInstall(cwd, npmInstallArgs)
end

-- shallowEqual compares two Go value structs (tables of scalar fields) like Go's ==.
function project.shallowEqual(a, b)
    if a == b then
        return true
    end
    if a == nil or b == nil then
        return false
    end
    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then
            return false
        end
    end
    return true
end

function Session:refreshInlayHintsIfNeeded(oldPrefs, newPrefs)
    if not project.shallowEqual(oldPrefs.inlayHints, newPrefs.inlayHints) then
        local err = self.client:RefreshInlayHints(self:backgroundContext())
        if err ~= nil and self.options.loggingEnabled then
            self.logger:Logf("Error refreshing inlay hints: %v", err)
        end
    end
end

function Session:refreshCodeLensIfNeeded(oldPrefs, newPrefs)
    if not project.shallowEqual(oldPrefs.codeLens, newPrefs.codeLens) then
        local err = self.client:RefreshCodeLens(self:backgroundContext())
        if err ~= nil and self.options.loggingEnabled then
            self.logger:Logf("Error refreshing code lens: %v", err)
        end
    end
end

function Session:refreshDiagnosticsIfNeeded(oldPrefs, newPrefs)
    if oldPrefs.customConfigFileName ~= newPrefs.customConfigFileName or
        oldPrefs.reportStyleChecksAsWarnings ~= newPrefs.reportStyleChecksAsWarnings or
        oldPrefs.enableValidation ~= newPrefs.enableValidation then
        self:ScheduleDiagnosticsRefresh()
    end
end

function Session:refreshATAIfNeeded(oldPrefs, newPrefs)
    if oldPrefs:IsATADisabled() and not newPrefs:IsATADisabled() then
        -- ATA was re-enabled; schedule a diagnostics refresh so the next snapshot update
        -- re-triggers ATA for existing projects with the new setting.
        self:ScheduleDiagnosticsRefresh()
    end
end

function Session:publishProgramDiagnostics(oldSnapshot, newSnapshot)
    if not self.options.pushDiagnosticsEnabled then
        return
    end
    if core.Tristate_IsFalse(newSnapshot:UserPreferences().enableValidation) then
        if core.Tristate_IsFalse(oldSnapshot:UserPreferences().enableValidation) then
            return
        end
        for configFilePath, oldProject in oldSnapshot.projectCollection:ProjectsByPath():Entries() do
            if oldProject.kind == Kind.Configured and oldSnapshot.projectCollection:GetOpenConfiguredProjects():Has(configFilePath) then
                self:publishProjectDiagnostics(self:backgroundContext(), configFilePath, nil, oldSnapshot.converters)
            end
        end
        return
    end

    local ctx = self:backgroundContext()
    local oldProjects = oldSnapshot.projectCollection:ProjectsByPath()
    local newProjects = newSnapshot.projectCollection:ProjectsByPath()
    local oldOpenProjects = oldSnapshot.projectCollection:GetOpenConfiguredProjects()
    local newOpenProjects = newSnapshot.projectCollection:GetOpenConfiguredProjects()
    collections.DiffOrderedMaps(
        oldProjects,
        newProjects,
        function(configFilePath, addedProject)
            if not project.shouldPublishProgramDiagnostics(addedProject, newSnapshot:ID()) or not newOpenProjects:Has(configFilePath) then
                return
            end
            self:publishProjectDiagnostics(ctx, configFilePath, addedProject:GetProjectDiagnostics(ctx), newSnapshot.converters)
        end,
        function(configFilePath, removedProject)
            if removedProject.kind ~= Kind.Configured then
                return
            end
            self:publishProjectDiagnostics(ctx, configFilePath, nil, oldSnapshot.converters)
        end,
        function(configFilePath, oldProject, newProject)
            if not project.shouldPublishProgramDiagnostics(newProject, newSnapshot:ID()) or not newOpenProjects:Has(configFilePath) then
                return
            end
            self:publishProjectDiagnostics(ctx, configFilePath, newProject:GetProjectDiagnostics(ctx), newSnapshot.converters)
        end
    )
    -- Sync diagnostics for projects whose open-file state changed without a program update.
    for configFilePath, newProject in newProjects:Entries() do
        if newProject.kind ~= Kind.Configured then
            goto continue
        end
        if not oldProjects:Has(configFilePath) then
            goto continue -- Handled by added project case above
        end
        do
            local oldProject = oldProjects:Get(configFilePath)
            local newHasOpenFiles = newOpenProjects:Has(configFilePath)
            local oldHasOpenFiles = oldOpenProjects:Has(configFilePath)
            if newHasOpenFiles and not oldHasOpenFiles and
                (newProject == oldProject or not project.shouldPublishProgramDiagnostics(newProject, newSnapshot:ID())) then
                -- Project reopened without a program update
                self:publishProjectDiagnostics(ctx, configFilePath, newProject:GetProjectDiagnostics(ctx), newSnapshot.converters)
            elseif not newHasOpenFiles and oldHasOpenFiles then
                -- Project closed
                self:publishProjectDiagnostics(ctx, configFilePath, nil, newSnapshot.converters)
            end
        end
        ::continue::
    end
end

function project.shouldPublishProgramDiagnostics(p, snapshotID)
    if p.kind ~= Kind.Configured or p.program == nil or p.programLastUpdate ~= snapshotID then
        return false
    end
    return p.programUpdateKind > ProgramUpdateKind.Cloned
end

function Session:publishProjectDiagnostics(ctx, configFilePath, diags, converters)
    if core.Tristate_IsFalse(self:Config().enableValidation) then
        diags = nil
    end
    ctx = self:withCurrentLocale(ctx)
    local lspDiagnostics = {}
    for _, diag in ipairs(diags or {}) do
        lspDiagnostics[#lspDiagnostics + 1] = lsconv.DiagnosticToLSPPush(ctx, converters, diag)
    end

    local err = self.client:PublishDiagnostics(ctx, {
        uri = lsconv.FileNameToDocumentURI(configFilePath),
        diagnostics = lspDiagnostics,
    })
    if err ~= nil and self.options.loggingEnabled then
        self.logger:Logf("Error publishing diagnostics: %v", err)
    end
end

-- EnqueuePublishGlobalDiagnostics schedules a background check for new accumulated
-- global diagnostics from checker pools, re-publishing tsconfig diagnostics if changed.
-- Multiple calls are coalesced into a single background task.
function Session:EnqueuePublishGlobalDiagnostics()
    if not self.options.pushDiagnosticsEnabled or core.Tristate_IsFalse(self:Config().enableValidation) then
        return
    end
    if not self.globalDiagPublishPending then
        self.globalDiagPublishPending = true
        self.backgroundQueue:Enqueue(self:backgroundContext(), function(ctx)
            self:publishGlobalDiagnostics(ctx)
        end)
    end
end

function Session:publishGlobalDiagnostics(ctx)
    local snapshot = self.snapshot
    snapshot:ref()
    local ok, err = pcall(function()
        for _, p in ipairs(snapshot.projectCollection:Projects()) do
            if p.kind ~= Kind.Configured or p.checkerPool == nil then
                goto continue
            end
            if p.checkerPool:TakeNewGlobalDiagnostics() then
                self:publishProjectDiagnostics(ctx, p.configFilePath, p:GetProjectDiagnostics(ctx), snapshot.converters)
            end
            ::continue::
        end
    end)
    snapshot:Deref(self)
    self.globalDiagPublishPending = false
    if not ok then
        error(err, 0)
    end
end

function Session:triggerATAForUpdatedProjects(newSnapshot)
    for _, p in ipairs(newSnapshot.projectCollection:Projects()) do
        if p:ShouldTriggerATA(newSnapshot:ID()) then
            self.backgroundQueue:Enqueue(self:backgroundContext(), function(ctx)
                local logTree = nil
                if self.options.loggingEnabled then
                    logTree = logging.NewLogTree("Triggering ATA for project " .. p:Name())
                end

                local typingsInfo = p:ComputeTypingsInfo()
                local fileNames = {}
                for i, file in ipairs(p.program:GetSourceFiles()) do
                    fileNames[i] = file:FileName()
                end
                local request = {
                    projectID = p.configFilePath,
                    typingsInfo = typingsInfo,
                    fileNames = fileNames,
                    projectRootPath = p.currentDirectory,
                    compilerOptions = p.commandLine:CompilerOptions(),
                    currentDirectory = self.options.currentDirectory,
                    getScriptKind = core.GetScriptKindFromFileName,
                    fs = self.fs.fs,
                    logger = logTree,
                }

                local projectDisplayName = p:DisplayName(self.options.currentDirectory)
                if self.client ~= nil then
                    self.client:ProgressStart(diagnostics.Installing_types_for_0, projectDisplayName)
                end
                local result, err = self.typingsInstaller:InstallTypings(request)
                if self.client ~= nil then
                    self.client:ProgressFinish(diagnostics.Installing_types_for_0, projectDisplayName)
                end
                if err ~= nil then
                    if logTree ~= nil then
                        self.logger:Log("ATA installation failed for project " .. p:Name() .. ": " .. logging.fmtValue(err))
                        self.logger:Log(logTree:String())
                    end
                else
                    if not project.slicesEqual(result.typingsFiles, p.typingsFiles) then
                        self.pendingATAChanges[p.configFilePath] = {
                            typingsInfo = typingsInfo,
                            typingsFiles = result.typingsFiles,
                            typingsFilesToWatch = result.filesToWatch,
                            logs = logTree,
                        }
                        self:ScheduleDiagnosticsRefresh()
                    end
                end
            end)
        end
    end
end

function Session:warmAutoImportCache(ctx, change, oldSnapshot, newSnapshot)
    if change.fileChanges.changed:Len() == 1 then
        local changedFile = ""
        for uri in pairs(project.setKeys(change.fileChanges.changed)) do
            changedFile = uri
        end
        if not newSnapshot.fs:isOpenFile(lsproto.DocumentUri_FileName(changedFile)) then
            return
        end
        local prefs = newSnapshot:UserPreferences()
        if core.Tristate_IsFalse(prefs.includeCompletionsForModuleExports) then
            return
        end
        local p = newSnapshot:GetDefaultProject(changedFile)
        if p == nil then
            return
        end
        if newSnapshot.autoImports:IsPreparedForImportingFile(
            lsproto.DocumentUri_FileName(changedFile),
            p.configFilePath,
            prefs
        ) then
            return
        end

        -- Cancel any previous auto-import warming and create a new cancellable context.
        -- Only publish the new cancel func if the derived context is still active,
        -- and make the stored cancel func a no-op once that warming task is done.
        if self.warmAutoImportCancel ~= nil then
            self.warmAutoImportCancel()
        end
        local warmCtx, cancel = core.WithCancel(ctx)
        if core.ContextErr(warmCtx) == nil then
            self.warmAutoImportCancel = function()
                if core.ContextErr(warmCtx) ~= nil then
                    return
                end
                self.logger:Logf("Cancelling auto-import warming for file %s", lsproto.DocumentUri_FileName(changedFile))
                cancel()
            end
        end

        if core.ContextErr(warmCtx) ~= nil then
            cancel()
            return
        end

        -- Clone the snapshot with auto-imports using warmCtx so the expensive
        -- extraction work is cancelled if a file change arrives.
        if not newSnapshot:tryRef() then
            cancel()
            return
        end

        local warmChange = project.newSnapshotChange({
            reason = UpdateReason.RequestedLanguageServiceWithAutoImports,
            documents = { changedFile },
            autoImports = changedFile,
        })
        local clonedSnapshot = newSnapshot:Clone(warmCtx, warmChange, newSnapshot.fs.overlays, self)

        -- If cancelled during clone, discard the incomplete result.
        if core.ContextErr(warmCtx) ~= nil then
            clonedSnapshot:Deref(self)
            newSnapshot:Deref(self)
            cancel()
            return
        end

        -- Conditionally adopt: if the session hasn't moved past newSnapshot,
        -- promote the clone so future requests benefit from the warmed cache.
        self:adoptSnapshotChange(newSnapshot, clonedSnapshot)
        newSnapshot:Deref(self)
        cancel()
    end
end

