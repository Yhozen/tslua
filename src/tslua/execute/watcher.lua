local execute = require("tslua.execute")
local ast = require("tslua.ast")
local cachedvfs = require("tslua.vfs.cachedvfs")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local incremental = require("tslua.execute.incremental")
local trackingvfs = require("tslua.vfs.trackingvfs")
local tsc = require("tslua.execute.tsc")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local watchmanager = require("tslua.execute.watchmanager")


local function sortedKeys(m)
    local keys = {}
    for k in pairs(m or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- reflect.DeepEqual over Lua values (tables compared structurally, including metatables).
function execute.deepEqual(a, b, visited)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if getmetatable(a) ~= getmetatable(b) then
        return false
    end
    visited = visited or {}
    local seen = visited[a]
    if seen ~= nil and seen[b] then
        return true
    end
    if seen == nil then
        seen = {}
        visited[a] = seen
    end
    seen[b] = true
    for k, v in pairs(a) do
        if not execute.deepEqual(v, b[k], visited) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

-- cachedSourceFile: { file = *ast.SourceFile, modTime = time.Time }

-- watchCompilerHost embeds compiler.CompilerHost (compilerHost field) and caches source files by
-- modification time.
local watchCompilerHost = {}
watchCompilerHost.__index = watchCompilerHost
execute.watchCompilerHost = watchCompilerHost

function execute.newWatchCompilerHost(inner, cache)
    return setmetatable({ compilerHost = inner, cache = cache }, watchCompilerHost)
end

function watchCompilerHost:FS() return self.compilerHost:FS() end
function watchCompilerHost:DefaultLibraryPath() return self.compilerHost:DefaultLibraryPath() end
function watchCompilerHost:GetCurrentDirectory() return self.compilerHost:GetCurrentDirectory() end
function watchCompilerHost:Trace(msg, ...) return self.compilerHost:Trace(msg, ...) end
function watchCompilerHost:GetContentMappedSourceFiles(parseOptions, mapper)
    return self.compilerHost:GetContentMappedSourceFiles(parseOptions, mapper)
end
function watchCompilerHost:ContentMapperProject() return self.compilerHost:ContentMapperProject() end
function watchCompilerHost:GetResolvedProjectReference(fileName, path)
    return self.compilerHost:GetResolvedProjectReference(fileName, path)
end

function watchCompilerHost:GetSourceFile(opts)
    local info = self.compilerHost:FS():Stat(opts.fileName)

    local cached, ok = self.cache:Load(opts.path)
    if ok then
        if info ~= nil and info:ModTime() == cached.modTime then
            return cached.file
        end
    end

    local file = self.compilerHost:GetSourceFile(opts)
    if file ~= nil then
        if info ~= nil then
            self.cache:Store(opts.path, {
                file = file,
                modTime = info:ModTime(),
            })
        end
    else
        self.cache:Delete(opts.path)
    end
    return file
end

-- Watcher implements tsc.Watcher (DoCycle).
local Watcher = {}
Watcher.__index = Watcher
execute.Watcher = Watcher

function execute.createWatcher(
    sys,
    configParseResult,
    compilerOptionsFromCommandLine,
    commandLineRaw,
    reportDiagnostic,
    reportErrorSummary,
    testing
)
    local wm = watchmanager.NewWatchManager(sys:Writer(), function(p) return sys:FS():DirectoryExists(p) end)
    local t, ok = watchmanager.AsCommandLineTestingWithWatchBackend(testing)
    if ok then
        wm:SetBackend(t:WatchBackend())
    end
    local w = setmetatable({
        sys = sys,
        configFileName = "",
        config = configParseResult,
        compilerOptionsFromCommandLine = compilerOptionsFromCommandLine,
        commandLineRaw = commandLineRaw,
        reportDiagnostic = reportDiagnostic,
        reportErrorSummary = reportErrorSummary,
        reportWatchStatus = tsc.CreateWatchStatusReporter(sys, configParseResult:Locale(), configParseResult:CompilerOptions(), testing),
        testing = testing,

        -- contentMapperHost transforms content-mapped files; it is created once per watch session (when
        -- enabled) and reused across cycles.
        contentMapperHost = nil,
        contentMapperProject = nil,

        program = nil,
        extendedConfigCache = nil,
        configModified = false,
        configHasErrors = false,
        configFilePaths = nil,

        sourceFileCache = collections.NewSyncMap(),

        wm = wm,
        seenFiles = nil, -- all build dependencies (for event filtering)
        configMtimes = nil,
        watchSetDirty = false,
        -- forceFullRebuild records a reason that requires a full NewProgram rebuild
        -- (e.g. an event overflow, a mid-cycle watch failure, a newly appeared
        -- project file, or a changed non-source dependency). Unlike watchSetDirty,
        -- which is only raised to recheck wildcard roots and may be cleared once the
        -- file set is confirmed unchanged, this flag is preserved until a full
        -- rebuild actually runs so the single-file fast path cannot silently reuse a
        -- stale program.
        forceFullRebuild = false,
        programReady = false,

        -- Test-only observability of which build path was taken.
        fastPathBuilds = 0,
        fullBuilds = 0,
    }, Watcher)
    if configParseResult.configFile ~= nil then
        w.configFileName = configParseResult.configFile.sourceFile:FileName()
    end
    return w
end

function Watcher:start(ctx)
    self.contentMapperHost = tsc.NewContentMapperHost(ctx, self.sys, self.config:CompilerOptions())
    local closeContentMapperHost = self.contentMapperHost ~= nil and self.testing == nil
    self:replaceContentMapperProject(self.config)
    self.wm:Lock()
    self.extendedConfigCache = tsc.NewExtendedConfigCache()
    local host = compiler.NewCompilerHost(self.sys:GetCurrentDirectory(), self.sys:FS(), self.sys:DefaultLibraryPath(), self.extendedConfigCache, execute.getTraceFromSys(self.sys, self.config:Locale(), self.testing), self.contentMapperProject)
    self.program = incremental.ReadBuildInfoProgram(self.config, incremental.NewBuildInfoReader(host), host)

    if self.configFileName ~= "" then
        self.configFilePaths = { self.configFileName }
        for _, f in ipairs(self.config:ExtendedSourceFiles() or {}) do
            self.configFilePaths[#self.configFilePaths + 1] = f
        end
    end

    if self.sys:GetEnvironmentVariable("TS_WATCH_DEBUG") ~= "" then
        self.wm.debugLog = self.sys:Writer()
    end

    if self.testing == nil then
        self.wm:EnsureDefaultBackend()
    end

    self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Starting_compilation_in_watch_mode))
    self.watchSetDirty = true
    local err = self:doBuild()
    if err ~= nil then
        self.wm:ForceOverflow()
    end
    self.wm:Unlock()

    if self.testing == nil then
        -- The content mapper host closes itself when ctx is cancelled (see contentmapper.New).
        self.wm:RunLoop(ctx, function() self:DoCycle() end)
    end
    if closeContentMapperHost then
        self.contentMapperHost:Close()
    end
end

function Watcher:replaceContentMapperProject(config)
    if self.contentMapperHost == nil then
        return
    end
    local project = self.contentMapperHost:Project({
        configFileName = config:ConfigName(),
        mappers = config:ContentMappers(),
        compilerOptions = config:CompilerOptions(),
    })
    if self.contentMapperProject ~= nil then
        self.contentMapperProject:Close()
    end
    self.contentMapperProject = project
end

function Watcher:contentMapperWatchedFiles()
    local files = nil
    for _, mapper in ipairs(self.config:ContentMappers() or {}) do
        if (mapper.packageDirectory or "") ~= "" and (mapper.contributionID or "") == "" then
            files = core.Append(files, tspath.CombinePaths(mapper.packageDirectory, "package.json"))
        end
    end
    if self.contentMapperProject ~= nil then
        local dynamicFiles, err = self.contentMapperProject:WatchedFiles()
        if err ~= nil then
            self.reportDiagnostic(compiler.ContentMapperProjectDiagnostic(err))
            return files
        end
        for _, f in ipairs(dynamicFiles or {}) do
            files = core.Append(files, f)
        end
    end
    if files == nil then
        return nil
    end
    table.sort(files)
    -- slices.Compact
    local compacted = {}
    for _, f in ipairs(files) do
        if compacted[#compacted] ~= f then
            compacted[#compacted + 1] = f
        end
    end
    return compacted
end

function Watcher:computeDesiredWatches(seenFilePaths)
    local cwd = self.sys:GetCurrentDirectory()
    local fs = self.sys:FS()

    local desiredDirs = {} -- dir → recursive

    -- Wildcard directories from tsconfig (recursive or non-recursive)
    if self.config.configFile ~= nil then
        local wildcardDirectories = self.config:WildcardDirectories()
        for _, dir in ipairs(sortedKeys(wildcardDirectories)) do
            local realDir = fs:Realpath(dir)
            desiredDirs[realDir] = wildcardDirectories[dir]
        end
    end

    -- For no-config CLI mode, ensure CWD is watched
    if self.config.configFile == nil and next(desiredDirs) == nil then
        local dir = fs:Realpath(cwd)
        desiredDirs[dir] = false
    end

    -- Config file parent directories as non-recursive watches
    for _, cfgPath in ipairs(self.configFilePaths or {}) do
        local realPath = fs:Realpath(cfgPath)
        local dir = tspath.GetDirectoryPath(realPath)
        if desiredDirs[dir] == nil then
            desiredDirs[dir] = false
        end
    end

    -- For no-config CLI mode, also watch the CLI-specified files' directories
    if self.config.configFile == nil then
        for _, fileName in ipairs(self.config:FileNames() or {}) do
            local absPath = tspath.GetNormalizedAbsolutePath(fileName, cwd)
            local realPath = fs:Realpath(absPath)
            local dir = tspath.GetDirectoryPath(realPath)
            if desiredDirs[dir] == nil then
                desiredDirs[dir] = false
            end
        end
    end

    -- Add parent directories for seen files not covered by existing dir watches.
    -- Resolve ancestor fallbacks first so coverage checks use final dirs.
    local resolvedDirs = self.wm:ResolveDesiredDirs(desiredDirs)

    local coverage = watchmanager.NewDirWatchSet(self:comparePathsOptions())
    for _, dir in ipairs(sortedKeys(resolvedDirs)) do
        coverage:Set(dir, resolvedDirs[dir])
    end
    for _, filePath in ipairs(seenFilePaths or {}) do
        local dir = tspath.GetDirectoryPath(filePath)
        if not coverage:Covered(dir) and watchmanager.CanWatchDirectory(dir) then
            coverage:Set(dir, false)
        end
    end

    -- Re-resolve in case newly added dirs don't exist
    return self.wm:ResolveDesiredDirs(coverage:Dirs())
end

function Watcher:reconcileWatches(seenFilePaths)
    local desiredDirs = self:computeDesiredWatches(seenFilePaths)
    return self.wm:ReconcileWatches(desiredDirs)
end

function Watcher:comparePathsOptions()
    return tspath.NewComparePathsOptions(self.sys:FS():UseCaseSensitiveFileNames(), self.sys:GetCurrentDirectory())
end

function Watcher:DoCycle()
    self.wm:Lock()
    self:doCycle()
    self.wm:Unlock()
end

-- The body of Go's DoCycle (between the deferred Lock/Unlock).
function Watcher:doCycle()
    local changedPaths, overflow = self.wm:DrainEvents()
    local hasEvents = (changedPaths ~= nil and next(changedPaths) ~= nil) or overflow

    if self:recheckTsConfig(self:contentMapperManifestChanged(changedPaths)) then
        return
    end

    if hasEvents and not overflow and not self.configModified then
        -- Filter fswatch events against known dependencies
        if self:isRelevantChange(changedPaths) then
            self:evictChangedSourceFiles(changedPaths)
            local caseSensitive = self.sys:FS():UseCaseSensitiveFileNames()
            local cwd = self.sys:GetCurrentDirectory()
            local programFiles = self.program:GetProgram():FilesByPath()
            local contentMapperWatchedFiles = collections.NewSet()
            for _, fileName in ipairs(self:contentMapperWatchedFiles() or {}) do
                contentMapperWatchedFiles:Add(tspath.ToPath(fileName, cwd, caseSensitive))
            end
            local contentMapperConfigChanged = false
            for _, eventPath in ipairs(sortedKeys(changedPaths)) do
                if self.sys:FS():DirectoryExists(eventPath) then
                    -- A watched directory changed: the wildcard file set may have
                    -- changed, so reload file names on the next build.
                    self.watchSetDirty = true
                    goto continue
                end
                do
                    local p = tspath.ToPath(eventPath, cwd, caseSensitive)
                    if contentMapperWatchedFiles:Has(p) then
                        contentMapperConfigChanged = true
                        self.forceFullRebuild = true
                    end
                    if self.config.configFile ~= nil and self.config:PossiblyMatchesFileName(eventPath) then
                        if not collections.Set.Has(self.seenFiles, p) then
                            -- A file that matches the project but was not previously
                            -- seen appeared: a structural change that requires a full
                            -- rebuild, not the single-file fast path.
                            self.watchSetDirty = true
                            self.forceFullRebuild = true
                            goto continue
                        end
                    end
                    local sourceFile = programFiles[p]
                    if sourceFile ~= nil and sourceFile:ContentMapper() ~= "" then
                        -- Canonical mapped files must be transformed again, and supplemental paths are failed
                        -- physical lookups reserved for virtual files. Neither can use single-file AST reuse.
                        self.forceFullRebuild = true
                    elseif sourceFile == nil and collections.Set.Has(self.seenFiles, p) then
                        -- A non-source build dependency changed. Such dependencies
                        -- (e.g. package.json or a previously-missing module path) are
                        -- tracked in seenFiles but are not program source files, so a
                        -- missing sourceFileCache entry would not account for them.
                        -- Module resolution may now differ, so the single-file fast
                        -- path is unsafe; force a full rebuild.
                        self.forceFullRebuild = true
                    end
                end
                ::continue::
            end
            if contentMapperConfigChanged and self.contentMapperProject ~= nil then
                local err = self.contentMapperProject:Refresh()
                if err ~= nil then
                    self.reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_process_could_not_be_started_or_initialized))
                    return
                end
            end
        else
            if self.wm.debugLog ~= nil then
                local n = 0
                for _ in pairs(changedPaths) do
                    n = n + 1
                end
                self.wm.debugLog:WriteString("[watch] DoCycle: " .. n .. " event(s) not relevant to compilation, skipping rebuild\n")
            end
            if self.testing ~= nil then
                self.testing:OnProgram(self.program)
            end
            return
        end
    elseif overflow then
        -- Overflow: evict the entire source file cache and force a full rebuild.
        -- The fast path must not run here: after clearing the cache a one-file
        -- program would present exactly one cache miss and be misread as a
        -- single-file content edit, silently reusing a stale (e.g. unresolved
        -- import) program instead of rediscovering the file graph.
        self.sourceFileCache = collections.NewSyncMap()
        self.watchSetDirty = true
        self.forceFullRebuild = true
    elseif not hasEvents and not self.configModified then
        -- No events and no config change
        if self.wm.debugLog ~= nil then
            self.wm.debugLog:WriteString("[watch] DoCycle: no events, skipping\n")
        end
        if self.testing ~= nil then
            self.testing:OnProgram(self.program)
        end
        return
    end

    self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.File_change_detected_Starting_incremental_compilation))
    local err = self:doBuild()
    if err ~= nil then
        -- Mid-cycle watch failure; force a full rebuild on the next event
        self.wm:ForceOverflow()
    end
end

function Watcher:isRelevantChange(changedPaths)
    local caseSensitive = self.sys:FS():UseCaseSensitiveFileNames()
    local cwd = self.sys:GetCurrentDirectory()
    local opts = self:comparePathsOptions()
    local contentMapperWatchedFiles = collections.NewSet()
    for _, fileName in ipairs(self:contentMapperWatchedFiles() or {}) do
        contentMapperWatchedFiles:Add(tspath.ToPath(fileName, cwd, caseSensitive))
    end
    for _, eventPath in ipairs(sortedKeys(changedPaths)) do
        local p = tspath.ToPath(eventPath, cwd, caseSensitive)
        if contentMapperWatchedFiles:Has(p) then
            return true
        end
        if collections.Set.Has(self.seenFiles, p) then
            return true
        end
        if self.config.configFile ~= nil and self.config:PossiblyMatchesFileName(eventPath) then
            return true
        end
        if self.config.configFile ~= nil and self.config:PossiblyMatchesDirectoryName(p) then
            return true
        end
        if self.sys:FS():DirectoryExists(eventPath) then
            if self.wm:IsPathUnderWatch(eventPath, opts) then
                return true
            end
        end
    end
    return false
end

local function fileNamesEqual(a, b)
    if core.Len(a) ~= core.Len(b) then
        return false
    end
    for i = 1, core.Len(a) do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function hasWildcardDirectories(config)
    return next(config:WildcardDirectories() or {}) ~= nil
end

-- Returns err (nil on success).
function Watcher:doBuild()
    if self.configModified then
        self.sourceFileCache = collections.NewSyncMap()
        self.watchSetDirty = true
    end

    local reloadedFileNames = false
    if self.watchSetDirty then
        if self.config.configFile ~= nil and hasWildcardDirectories(self.config) then
            local newConfig = self.config:ReloadFileNamesOfParsedCommandLine(self.sys:FS())
            reloadedFileNames = true
            if not fileNamesEqual(self.config:FileNames(), newConfig:FileNames()) then
                self.config = newConfig
            else
                self.watchSetDirty = false
                self.config = newConfig
            end
        elseif not self.configModified then
            self.watchSetDirty = false
        end
    end

    if self.program ~= nil and self.programReady and not self.configModified and not self.watchSetDirty and not self.forceFullRebuild then
        local cached = cachedvfs.From(self.sys:FS())
        local innerHost = compiler.NewCompilerHost(self.sys:GetCurrentDirectory(), cached, self.sys:DefaultLibraryPath(), self.extendedConfigCache, execute.getTraceFromSys(self.sys, self.config:Locale(), self.testing), self.contentMapperProject)
        local host = execute.newWatchCompilerHost(innerHost, self.sourceFileCache)

        if self:tryUpdateProgram(host) then
            self.fastPathBuilds = self.fastPathBuilds + 1
            local result = self:compileAndEmit()
            cached:DisableAndClearCache()

            self.configMtimes = {}
            for _, cfgPath in ipairs(self.configFilePaths or {}) do
                local s = self.sys:FS():Stat(cfgPath)
                if s ~= nil then
                    self.configMtimes[cfgPath] = s:ModTime()
                end
            end
            self.configModified = false

            local errorCount = core.Len(result.diagnostics)
            if errorCount == 1 then
                self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_1_error_Watching_for_file_changes))
            else
                self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_0_errors_Watching_for_file_changes, errorCount))
            end
            if self.testing ~= nil then
                self.testing:OnProgram(self.program)
            end
            return nil
        end
        cached:DisableAndClearCache()
    end

    local cached = cachedvfs.From(self.sys:FS())
    local tfs = trackingvfs.NewFS(cached)
    local innerHost = compiler.NewCompilerHost(self.sys:GetCurrentDirectory(), tfs, self.sys:DefaultLibraryPath(), self.extendedConfigCache, execute.getTraceFromSys(self.sys, self.config:Locale(), self.testing), self.contentMapperProject)
    local host = execute.newWatchCompilerHost(innerHost, self.sourceFileCache)

    if self.config.configFile ~= nil then
        for _, dir in ipairs(sortedKeys(self.config:WildcardDirectories())) do
            tfs.seenFiles:Add(dir)
        end
        if not reloadedFileNames and not self.watchSetDirty and hasWildcardDirectories(self.config) then
            self.config = self.config:ReloadFileNamesOfParsedCommandLine(self.sys:FS())
        end
    end
    for _, path in ipairs(self.configFilePaths or {}) do
        tfs.seenFiles:Add(path)
    end
    for _, path in ipairs(self:contentMapperWatchedFiles() or {}) do
        tfs.seenFiles:Add(path)
    end

    self.program = incremental.NewProgram(compiler.NewProgram(compiler.NewProgramOptions({
        config = self.config,
        host = host,
    })), self.program, nil, function() return self.sys:Now() end, self.testing ~= nil)
    self.programReady = true
    self.fullBuilds = self.fullBuilds + 1

    local result = self:compileAndEmit()
    cached:DisableAndClearCache()

    local caseSensitive = self.sys:FS():UseCaseSensitiveFileNames()
    local cwd = self.sys:GetCurrentDirectory()
    local seenSlice = tfs.seenFiles:ToSlice()
    table.sort(seenSlice)
    self.seenFiles = collections.NewSetWithSizeHint(#seenSlice)
    for _, p in ipairs(seenSlice) do
        self.seenFiles:Add(tspath.ToPath(p, cwd, caseSensitive))
    end

    self.configMtimes = {}
    for _, cfgPath in ipairs(self.configFilePaths or {}) do
        local s = self.sys:FS():Stat(cfgPath)
        if s ~= nil then
            self.configMtimes[cfgPath] = s:ModTime()
        end
    end

    local err = self:reconcileWatches(seenSlice)
    if err ~= nil then
        self.sys:Writer():WriteString(watchmanager.errorString(err) .. "\n")
        return err
    end
    self.watchSetDirty = false
    self.configModified = false
    self.forceFullRebuild = false

    local programFiles = self.program:GetProgram():FilesByPath()
    for _, path in ipairs(sortedKeys(self.sourceFileCache:ToMap())) do
        if programFiles[path] == nil then
            self.sourceFileCache:Delete(path)
        end
    end

    local errorCount = core.Len(result.diagnostics)
    if errorCount == 1 then
        self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_1_error_Watching_for_file_changes))
    else
        self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_0_errors_Watching_for_file_changes, errorCount))
    end

    if self.testing ~= nil then
        self.testing:OnProgram(self.program)
    end
    return nil
end

function Watcher:tryUpdateProgram(host)
    local oldProgram = self.program:GetProgram()

    local changedPath = ""
    local changedCount = 0
    local filesByPath = oldProgram:FilesByPath()
    for _, path in ipairs(sortedKeys(filesByPath)) do
        local file = filesByPath[path]
        if file:ContentMapper() == "" then
            local _, ok = self.sourceFileCache:Load(path)
            if not ok then
                changedPath = path
                changedCount = changedCount + 1
                if changedCount > 1 then
                    return false
                end
            end
        end
    end
    if changedCount == 0 then
        return false
    end

    local oldFile = filesByPath[changedPath]
    if oldFile ~= nil then
        local newFile = host:GetSourceFile(oldFile:ParseOptions())
        if newFile ~= nil then
            if not execute.equalJSXImplicitImport(oldProgram:Options(), oldFile, newFile) then
                return false
            end
        end
    end

    local newProgram, _, reused = oldProgram:ReuseProgram(changedPath, host, nil)
    if reused then
        self.program = incremental.NewProgram(newProgram, self.program, nil, function() return self.sys:Now() end, self.testing ~= nil)
    end
    return reused
end

-- FastPathBuilds reports how many builds reused an existing program via the
-- UpdateProgram single-file fast path. It is intended for tests that need to
-- verify which build path was taken.
function Watcher:FastPathBuilds() return self.fastPathBuilds end

-- FullBuilds reports how many builds constructed a full program via NewProgram.
-- It is intended for tests that need to verify which build path was taken.
function Watcher:FullBuilds() return self.fullBuilds end

function execute.equalJSXImplicitImport(options, oldFile, newFile)
    local function isJSX(file)
        return file.scriptKind == core.ScriptKind.JSX or file.scriptKind == core.ScriptKind.TSX
    end
    if not isJSX(oldFile) and not isJSX(newFile) then
        return true
    end
    local oldImport = ast.GetJSXRuntimeImport(ast.GetJSXImplicitImportBase(options, oldFile), options)
    local newImport = ast.GetJSXRuntimeImport(ast.GetJSXImplicitImportBase(options, newFile), options)
    return oldImport == newImport
end

function Watcher:evictChangedSourceFiles(changedPaths)
    local caseSensitive = self.sys:FS():UseCaseSensitiveFileNames()
    local cwd = self.sys:GetCurrentDirectory()
    for _, eventPath in ipairs(sortedKeys(changedPaths)) do
        local p = tspath.ToPath(eventPath, cwd, caseSensitive)
        local _, ok = self.sourceFileCache:Load(p)
        if ok then
            if self.wm.debugLog ~= nil then
                self.wm.debugLog:WriteString("[watch] evicting cached source file: " .. p .. "\n")
            end
            self.sourceFileCache:Delete(p)
        end
    end
end

function Watcher:compileAndEmit()
    return tsc.EmitFilesAndReportErrors({
        sys = self.sys,
        programLike = self.program,
        program = self.program:GetProgram(),
        config = self.config,
        reportDiagnostic = self.reportDiagnostic,
        reportErrorSummary = self.reportErrorSummary,
        writer = self.sys:Writer(),
        compileTimes = tsc.NewCompileTimes(),
        testing = self.testing,
    })
end

function Watcher:contentMapperManifestChanged(changedPaths)
    for _, mapper in ipairs(self.config:ContentMappers() or {}) do
        if (mapper.packageDirectory or "") ~= "" and (mapper.contributionID or "") == "" then
            if changedPaths ~= nil and changedPaths[self.sys:FS():Realpath(tspath.CombinePaths(mapper.packageDirectory, "package.json"))] ~= nil then
                return true
            end
        end
    end
    return false
end

function Watcher:recheckTsConfig(force)
    if self.configFileName == "" then
        return false
    end

    if not force and not self.configHasErrors and core.Len(self.configFilePaths) > 0 then
        local changed = false
        for _, path in ipairs(self.configFilePaths) do
            local oldMtime = self.configMtimes and self.configMtimes[path]
            local s = self.sys:FS():Stat(path)
            if oldMtime == nil then
                if s ~= nil then
                    changed = true
                    break
                end
            elseif s == nil or s:ModTime() ~= oldMtime then
                changed = true
                break
            end
        end
        if not changed then
            return false
        end
    end

    local configParseResult = self:parseConfigFile()
    if configParseResult == nil then
        return true
    end
    if self.configHasErrors then
        self.configModified = true
    end
    self.configHasErrors = false
    self.configFilePaths = { self.configFileName }
    for _, f in ipairs(configParseResult:ExtendedSourceFiles() or {}) do
        self.configFilePaths[#self.configFilePaths + 1] = f
    end
    if not execute.deepEqual(self.config.parsedConfig, configParseResult.parsedConfig) then
        self.configModified = true
    end
    self:replaceContentMapperProject(configParseResult)
    self.config = configParseResult
    return false
end

function Watcher:parseConfigFile()
    local extendedConfigCache = tsc.NewExtendedConfigCache()
    local configParseResult, errors = tsoptions.GetParsedCommandLineOfConfigFile(self.configFileName, self.compilerOptionsFromCommandLine, self.commandLineRaw, self.sys, extendedConfigCache)
    if core.Len(errors) > 0 then
        for _, e in ipairs(errors) do
            self.reportDiagnostic(e)
        end
        self.configHasErrors = true
        local errorCount = #errors
        if errorCount == 1 then
            self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_1_error_Watching_for_file_changes))
        else
            self.reportWatchStatus(ast.NewCompilerDiagnostic(diagnostics.Found_0_errors_Watching_for_file_changes, errorCount))
        end
        return nil
    end
    self.extendedConfigCache = extendedConfigCache
    return configParseResult
end
