local build = require("tslua.execute.build")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local fswatch = require("tslua.fswatch")
local incremental = require("tslua.execute.incremental")
local tsc = require("tslua.execute.tsc")
local tspath = require("tslua.tspath")
local watchmanager = require("tslua.execute.watchmanager")

local isTrue = core.Tristate_IsTrue

-- Options: { sys = tsc.System, command = *tsoptions.ParsedBuildCommandLine, testing = tsc.CommandLineTesting }

-- atomic.Bool
local atomicBool = {}
atomicBool.__index = atomicBool

local function newAtomicBool()
    return setmetatable({ v = false }, atomicBool)
end

function atomicBool:Store(v) self.v = v end
function atomicBool:Load() return self.v end

local function slicesEqual(a, b)
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

local function sortedKeys(m)
    local keys = {}
    for k in pairs(m or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- orchestratorResult: { result = tsc.CommandLineResult, errors, statistics = tsc.Statistics, filesToDelete }
local orchestratorResult = {}
orchestratorResult.__index = orchestratorResult
build.orchestratorResult = orchestratorResult

function build.newOrchestratorResult()
    return setmetatable({
        result = tsc.NewCommandLineResult(tsc.ExitStatus.Success),
        errors = nil,
        statistics = tsc.NewStatistics(),
        filesToDelete = nil,
    }, orchestratorResult)
end

function orchestratorResult:report(o)
    if isTrue(o.opts.command.compilerOptions.watch) then
        o.watchStatusReporter(ast.NewCompilerDiagnostic(core.IfElse(core.Len(self.errors) == 1, diagnostics.Found_1_error_Watching_for_file_changes, diagnostics.Found_0_errors_Watching_for_file_changes), core.Len(self.errors)))
    else
        o.errorSummaryReporter(self.errors)
    end
    if self.filesToDelete ~= nil then
        o:createBuilderStatusReporter(nil)(
            ast.NewCompilerDiagnostic(
                diagnostics.A_non_dry_build_would_delete_the_following_files_Colon_0,
                table.concat(core.Map(self.filesToDelete, function(f)
                    return "\r\n * " .. f
                end), "")
            )
        )
    end
    if not isTrue(o.opts.command.compilerOptions.diagnostics) and not isTrue(o.opts.command.compilerOptions.extendedDiagnostics) then
        return
    end
    self.statistics:SetTotalTime(o.opts.sys:SinceStart())
    self.statistics:Report(o.opts.sys:Writer(), o.opts.testing)
end

-- Orchestrator implements tsc.Watcher (DoCycle).
local Orchestrator = {}
Orchestrator.__index = Orchestrator
build.Orchestrator = Orchestrator

function Orchestrator:relativeFileName(fileName)
    return tspath.ConvertToRelativePath(fileName, self.comparePathsOptions)
end

function Orchestrator:toPath(fileName)
    return tspath.ToPath(fileName, self.comparePathsOptions.currentDirectory, self.comparePathsOptions.useCaseSensitiveFileNames)
end

function Orchestrator:resolveBuildInfoFileName(fileName, buildInfoDir)
    if incremental.IsBuildInfoFileNameDefaultLibrary(fileName) then
        return tspath.CombinePaths(self.host:DefaultLibraryPath(), fileName)
    end
    return tspath.GetNormalizedAbsolutePath(fileName, buildInfoDir)
end

function Orchestrator:Order()
    return self.order
end

function Orchestrator:Upstream(configName)
    local path = self:toPath(configName)
    local task = self:getTask(path)
    return core.Map(task.upStream, function(t)
        return t.task.config
    end)
end

function Orchestrator:Downstream(configName)
    local path = self:toPath(configName)
    local task = self:getTask(path)
    return core.Map(task.downStream, function(t)
        return t.config
    end)
end

function Orchestrator:getTask(path)
    local task, ok = self.tasks:Load(path)
    if not ok then
        error("No build task found for " .. path, 0)
    end
    return task
end

function Orchestrator:createBuildTasks(oldTasks, configs, wg)
    for _, config in ipairs(configs or {}) do
        wg:Queue(function()
            local path = self:toPath(config)
            local task = nil
            local buildInfo = nil
            if oldTasks ~= nil then
                local existing, ok = oldTasks:Load(path)
                if ok then
                    if not existing.dirty then
                        -- Reuse existing task if config is same
                        task = existing
                    else
                        if existing.contentMapperProject ~= nil then
                            existing.contentMapperProject:Close()
                        end
                        buildInfo = existing.buildInfoEntry
                    end
                end
            end
            if task == nil then
                task = build.newBuildTask(config, oldTasks == nil)
                task.pending = true
                task.buildInfoEntry = buildInfo
            end
            local _, loaded = self.tasks:LoadOrStore(path, task)
            if loaded then
                return
            end
            task.resolved = self.host:GetResolvedProjectReference(config, path)
            task.upStream = nil
            if task.resolved ~= nil then
                self:createBuildTasks(oldTasks, task.resolved:ResolvedProjectReferencePaths(), wg)
            end
        end)
    end
end

function Orchestrator:setupBuildTask(configName, downStream, inCircularContext, completed, analyzing, circularityStack)
    local path = self:toPath(configName)
    local task = self:getTask(path)
    if not completed:Has(path) then
        if analyzing:Has(path) then
            if not inCircularContext then
                self.errors = core.Append(self.errors, ast.NewCompilerDiagnostic(
                    diagnostics.Project_references_may_not_form_a_circular_graph_Cycle_detected_Colon_0,
                    table.concat(circularityStack, "\n")
                ))
            end
            return nil
        end
        analyzing:Add(path)
        circularityStack[#circularityStack + 1] = configName
        if task.resolved ~= nil then
            for index1, subReference in ipairs(task.resolved:ResolvedProjectReferencePaths() or {}) do
                local index = index1 - 1
                local upstream = self:setupBuildTask(subReference, task, inCircularContext or task.resolved:ProjectReferences()[index1].circular, completed, analyzing, circularityStack)
                if upstream ~= nil then
                    task.upStream = core.Append(task.upStream, build.newUpstreamTask(upstream, index))
                end
            end
        end
        circularityStack[#circularityStack] = nil
        completed:Add(path)
        task.reportDone = build.newChan()
        local prev = core.LastOrNil(self.order)
        if prev ~= nil and prev ~= "" then
            task.prevReporter = self:getTask(self:toPath(prev))
        end
        task.done = build.newChan()
        self.order = core.Append(self.order, configName)
    end
    if isTrue(self.opts.command.compilerOptions.watch) and downStream ~= nil then
        task.downStream = core.Append(task.downStream, downStream)
    end
    return task
end

function Orchestrator:GenerateGraphReusingOldTasks()
    local tasks = self.tasks
    self.tasks = collections.NewSyncMap()
    self.order = nil
    self.errors = nil
    self:GenerateGraph(tasks)
end

function Orchestrator:GenerateGraph(oldTasks)
    local projects = self.opts.command:ResolvedProjectPaths()
    -- Parse all config files in parallel
    local wg = core.NewWorkGroup(isTrue(self.opts.command.compilerOptions.singleThreaded))
    self:createBuildTasks(oldTasks, projects, wg)
    wg:RunAndWait()

    -- Generate the graph
    local completed = collections.NewSet()
    local analyzing = collections.NewSet()
    local circularityStack = {}
    for _, project in ipairs(projects or {}) do
        self:setupBuildTask(project, nil, false, completed, analyzing, circularityStack)
    end
    if oldTasks ~= nil then
        for _, path in ipairs(sortedKeys(oldTasks:ToMap())) do
            local oldTask = oldTasks:Load(path)
            local task, ok = self.tasks:Load(path)
            if not (ok and task == oldTask) then
                if oldTask.contentMapperProject ~= nil then
                    oldTask.contentMapperProject:Close()
                end
            end
        end
    end
end

function Orchestrator:Start(ctx)
    self.contentMapperHost = tsc.NewContentMapperHost(ctx, self.opts.sys, self.opts.command.compilerOptions)
    local closeContentMapperHost = self.contentMapperHost ~= nil and (not isTrue(self.opts.command.compilerOptions.watch) or self.opts.testing == nil)
    if isTrue(self.opts.command.compilerOptions.watch) then
        self.watchStatusReporter(ast.NewCompilerDiagnostic(diagnostics.Starting_compilation_in_watch_mode))
    end
    self:GenerateGraph(nil)
    local result = self:buildOrClean()
    if isTrue(self.opts.command.compilerOptions.watch) then
        self:Watch(ctx)
        result.watcher = self
    end
    if closeContentMapperHost then
        self.contentMapperHost:Close()
    end
    return result
end

function Orchestrator:Watch(ctx)
    self.wm:Lock()

    if self.opts.testing == nil then
        if self.opts.sys:GetEnvironmentVariable("TS_WATCH_DEBUG") ~= "" then
            self.wm.debugLog = self.opts.sys:Writer()
        end
        self.wm:EnsureDefaultBackend()
    end

    self:updateWatch()
    local desiredDirs = self:computeDesiredWatches()
    local err = self.wm:ReconcileWatches(desiredDirs)
    if err ~= nil then
        self.opts.sys:Writer():WriteString(watchmanager.errorString(err) .. "\n")
        self.wm:ForceOverflow()
    end
    self:resetCaches()

    self.wm:Unlock()

    if self.opts.testing == nil then
        self.wm:RunLoop(ctx, function() self:DoCycle() end)
    end
end

function Orchestrator:updateWatch()
    local oldCache = self.host.mTimes
    self.host.mTimes = collections.NewSyncMap()
    self:rangeTask(function(path, task)
        task:updateWatch(self, oldCache)
    end)
end

function Orchestrator:resetCaches()
    -- Clean out all the caches
    local cachesVfs = self.host.host:FS()
    cachesVfs:ClearCache()
    self.host.extendedConfigCache = tsc.NewExtendedConfigCache()
    self.host.sourceFiles:reset()
    self.host.configTimes = collections.NewSyncMap()
end

function Orchestrator:checkTasksForEventChanges(changedPaths, needsConfigUpdate, needsUpdate)
    local normalizedPaths = {}
    for _, eventPath in ipairs(sortedKeys(changedPaths)) do
        normalizedPaths[self:toPath(eventPath)] = changedPaths[eventPath]
    end

    for _, config in ipairs(self.order or {}) do
        local path = self:toPath(config)
        local task = self:getTask(path)

        local configPath = self:toPath(task.config)
        if normalizedPaths[configPath] ~= nil then
            task:resetConfig(self, path)
            needsConfigUpdate:Store(true)
            needsUpdate:Store(true)
            goto continue
        end

        if task.resolved == nil then
            goto continue
        end

        do
            local configChanged = false
            for _, file in ipairs(task.resolved:ExtendedSourceFiles() or {}) do
                local fp = self:toPath(file)
                if normalizedPaths[fp] ~= nil then
                    task:resetConfig(self, path)
                    needsConfigUpdate:Store(true)
                    needsUpdate:Store(true)
                    configChanged = true
                    break
                end
            end
            if configChanged then
                goto continue
            end
            for _, mapper in ipairs(task.resolved:ContentMappers() or {}) do
                if (mapper.packageDirectory or "") ~= "" and (mapper.contributionID or "") == "" then
                    local manifestPath = self:toPath(tspath.CombinePaths(mapper.packageDirectory, "package.json"))
                    if normalizedPaths[manifestPath] ~= nil then
                        task:resetConfig(self, path)
                        needsConfigUpdate:Store(true)
                        needsUpdate:Store(true)
                        configChanged = true
                        break
                    end
                end
            end
            if configChanged then
                goto continue
            end
        end

        do
            local rootChanged = false
            if task.contentMapperProject ~= nil then
                local watchedFiles, err = task.contentMapperProject:WatchedFiles()
                if err ~= nil then
                    task.contentMapperProjectErr = err
                    task:resetStatus()
                    needsUpdate:Store(true)
                    rootChanged = true
                end
                for _, fileName in ipairs(watchedFiles or {}) do
                    if normalizedPaths[self:toPath(fileName)] ~= nil then
                        task:refreshContentMapperProject(self)
                        task:resetStatus()
                        needsUpdate:Store(true)
                        rootChanged = true
                        break
                    end
                end
            end
            local fileNames = task.resolved:FileNames()
            local roots = collections.NewSetWithSizeHint(core.Len(fileNames))
            for _, file in ipairs(fileNames or {}) do
                local fp = self:toPath(file)
                roots:Add(fp)
                if not rootChanged then
                    if normalizedPaths[fp] ~= nil then
                        task:resetStatus()
                        needsUpdate:Store(true)
                        rootChanged = true
                    end
                end
            end

            if not rootChanged then
                local bi = task.buildInfoEntry
                if bi ~= nil and bi.buildInfo ~= nil then
                    local buildInfoDir = tspath.GetDirectoryPath(bi.path)
                    for _, fileName in ipairs(bi.buildInfo.fileNames or {}) do
                        local fp = self:toPath(self:resolveBuildInfoFileName(fileName, buildInfoDir))
                        if not roots:Has(fp) then
                            if normalizedPaths[fp] ~= nil then
                                task:resetStatus()
                                needsUpdate:Store(true)
                                break
                            end
                        end
                    end
                    for packageJson in bi.buildInfo:GetPackageJsons(buildInfoDir) do
                        if self:packageJsonLookupChanged(packageJson, normalizedPaths) then
                            task:resetStatus()
                            needsUpdate:Store(true)
                            break
                        end
                    end
                    for packageJson in bi.buildInfo:GetMissingPackageJsons(buildInfoDir) do
                        if self:packageJsonLookupChanged(packageJson, normalizedPaths) then
                            task:resetStatus()
                            needsUpdate:Store(true)
                            break
                        end
                    end
                end
                for _, packageJson in ipairs(task.packageJsons or {}) do
                    if self:packageJsonLookupChanged(packageJson, normalizedPaths) then
                        task:resetStatus()
                        needsUpdate:Store(true)
                        break
                    end
                end
            end

            task.reportDone = build.newChan()
            task.done = build.newChan()

            local newConfig = task.resolved:ReloadFileNamesOfParsedCommandLine(self.host:FS())
            if not slicesEqual(task.resolved:FileNames(), newConfig:FileNames()) then
                self.host.resolvedReferences:store(path, newConfig)
                task.resolved = newConfig
                task:resetStatus()
                needsUpdate:Store(true)
            end
        end
        ::continue::
    end

    if not needsUpdate:Load() then
        local opts = self.comparePathsOptions
        for _, eventPath in ipairs(sortedKeys(changedPaths)) do
            if self.host:FS():DirectoryExists(eventPath) then
                if self.wm:IsPathUnderWatch(eventPath, opts) then
                    self:rangeTask(function(path, task)
                        task:resetStatus()
                        task.reportDone = build.newChan()
                        task.done = build.newChan()
                    end)
                    needsUpdate:Store(true)
                    break
                end
            end
        end
    end
end

function Orchestrator:packageJsonLookupChanged(packageJson, changedPaths)
    local packageJsonPath = self:toPath(packageJson)
    if changedPaths[packageJsonPath] ~= nil then
        return true
    end
    for _, changedPath in ipairs(sortedKeys(changedPaths)) do
        local kind = changedPaths[changedPath]
        if kind == fswatch.EventKind.EventDelete and tspath.ContainsPath(changedPath, packageJsonPath, self.comparePathsOptions) then
            return true
        end
    end
    return false
end

function Orchestrator:computeDesiredWatches()
    local desiredDirs = watchmanager.NewDirWatchSet(self.comparePathsOptions)
    local fs = self.host:FS()

    for _, config in ipairs(self.order or {}) do
        local path = self:toPath(config)
        local task = self:getTask(path)

        -- Watch config file directory
        local configDir = tspath.GetDirectoryPath(task.config)
        local realConfigDir = fs:Realpath(configDir)
        desiredDirs:Set(realConfigDir, false)

        if task.resolved == nil then
            goto continue
        end

        -- Extended config file directories
        for _, cfgPath in ipairs(task.resolved:ExtendedSourceFiles() or {}) do
            local realPath = fs:Realpath(cfgPath)
            local dir = tspath.GetDirectoryPath(realPath)
            desiredDirs:Set(dir, false)
        end

        do
            -- Wildcard directories from tsconfig
            local wildcardDirectories = task.resolved:WildcardDirectories()
            for _, dir in ipairs(sortedKeys(wildcardDirectories)) do
                local recursive = wildcardDirectories[dir]
                local realDir = fs:Realpath(dir)
                desiredDirs:Set(realDir, recursive)
            end

            -- Input file directories not already covered
            for _, fileName in ipairs(task.resolved:FileNames() or {}) do
                local absPath = tspath.GetNormalizedAbsolutePath(fileName, self.opts.sys:GetCurrentDirectory())
                local dir = tspath.GetDirectoryPath(absPath)
                if not desiredDirs:Covered(dir) and watchmanager.CanWatchDirectory(dir) then
                    desiredDirs:Set(dir, false)
                end
                for _, mapper in ipairs(task.resolved:ContentMappers() or {}) do
                    if (mapper.packageDirectory or "") ~= "" and (mapper.contributionID or "") == "" then
                        local manifestPath = fs:Realpath(tspath.CombinePaths(mapper.packageDirectory, "package.json"))
                        local mdir = tspath.GetDirectoryPath(manifestPath)
                        if not desiredDirs:Covered(mdir) and watchmanager.CanWatchDirectory(mdir) then
                            desiredDirs:Set(mdir, false)
                        end
                    end
                end
            end
            if task.contentMapperProject ~= nil then
                local watchedFiles, err = task.contentMapperProject:WatchedFiles()
                if err ~= nil then
                    task.contentMapperProjectErr = err
                end
                for _, fileName in ipairs(watchedFiles or {}) do
                    local absPath = fs:Realpath(fileName)
                    local dir = tspath.GetDirectoryPath(absPath)
                    if not desiredDirs:Covered(dir) and watchmanager.CanWatchDirectory(dir) then
                        desiredDirs:Set(dir, false)
                    end
                end
            end

            -- Non-root dependency directories from buildinfo (e.g. node_modules .d.ts files).
            local bi = task.buildInfoEntry
            if bi ~= nil and bi.buildInfo ~= nil then
                local buildInfoDir = tspath.GetDirectoryPath(bi.path)
                local roots = collections.NewSet()
                for _, f in ipairs(task.resolved:FileNames() or {}) do
                    roots:Add(self:toPath(f))
                end
                for _, fileName in ipairs(bi.buildInfo.fileNames or {}) do
                    local absPath = fs:Realpath(self:resolveBuildInfoFileName(fileName, buildInfoDir))
                    local fp = self:toPath(absPath)
                    if not roots:Has(fp) then
                        local dir = tspath.GetDirectoryPath(absPath)
                        if not desiredDirs:Covered(dir) and watchmanager.CanWatchDirectory(dir) then
                            desiredDirs:Set(dir, false)
                        end
                    end
                end
                for packageJson in bi.buildInfo:GetPackageJsons(buildInfoDir) do
                    self:addPackageJsonWatchDirs(desiredDirs, packageJson)
                end
                for packageJson in bi.buildInfo:GetMissingPackageJsons(buildInfoDir) do
                    self:addPackageJsonWatchDirs(desiredDirs, packageJson)
                end
            end
            for _, packageJson in ipairs(task.packageJsons or {}) do
                self:addPackageJsonWatchDirs(desiredDirs, packageJson)
            end
        end
        ::continue::
    end

    return self.wm:ResolveDesiredDirs(desiredDirs:Dirs())
end

function Orchestrator:addWatchDir(desiredDirs, dir)
    if not desiredDirs:Covered(dir) and watchmanager.CanWatchDirectory(dir) then
        desiredDirs:Set(dir, false)
    end
end

function Orchestrator:addPackageJsonWatchDirs(desiredDirs, packageJson)
    local dir = tspath.GetDirectoryPath(packageJson)
    local dirs = { dir }
    local foundNodeModules = false
    local current = dir
    while true do
        local parent = tspath.GetDirectoryPath(current)
        if parent == "" or parent == current then
            break
        end
        dirs[#dirs + 1] = parent
        if tspath.GetBaseFileName(parent) == "node_modules" then
            foundNodeModules = true
            local grandparent = tspath.GetDirectoryPath(parent)
            if grandparent ~= "" and grandparent ~= parent then
                dirs[#dirs + 1] = grandparent
            end
            break
        end
        current = parent
    end

    if not foundNodeModules then
        self:addWatchDir(desiredDirs, dir)
        return
    end
    for _, d in ipairs(dirs) do
        self:addWatchDir(desiredDirs, d)
    end
end

function Orchestrator:DoCycle()
    self.wm:Lock()

    local changedPaths, overflow = self.wm:DrainEvents()
    local hasEvents = (changedPaths ~= nil and next(changedPaths) ~= nil) or overflow

    if not hasEvents then
        if self.wm.debugLog ~= nil then
            self.wm.debugLog:WriteString("[watch] DoCycle: no events, skipping\n")
        end
        self.wm:Unlock()
        return
    end

    local needsConfigUpdate = newAtomicBool()
    local needsUpdate = newAtomicBool()

    if overflow then
        -- Overflow: reset all tasks to force a full rebuild.
        self:rangeTask(function(path, task)
            task:resetConfig(self, path)
            task.reportDone = build.newChan()
            task.done = build.newChan()
        end)
        needsConfigUpdate:Store(true)
        needsUpdate:Store(true)
    else
        -- Event-driven: check only tasks affected by changed paths
        self:checkTasksForEventChanges(changedPaths, needsConfigUpdate, needsUpdate)
    end

    if not needsUpdate:Load() then
        self:resetCaches()
        self.wm:Unlock()
        return
    end

    self.watchStatusReporter(ast.NewCompilerDiagnostic(diagnostics.File_change_detected_Starting_incremental_compilation))
    if needsConfigUpdate:Load() then
        -- Generate new tasks
        self:GenerateGraphReusingOldTasks()
    end

    self:buildOrClean()
    self:updateWatch()
    local desiredDirs = self:computeDesiredWatches()
    local err = self.wm:ReconcileWatches(desiredDirs)
    if err ~= nil then
        self.opts.sys:Writer():WriteString(watchmanager.errorString(err) .. "\n")
        -- Mark overflow so the next event triggers a full rebuild
        self.wm:ForceOverflow()
    end
    self:resetCaches()
    self.wm:Unlock()
end

function Orchestrator:buildOrClean()
    local buildOptions = self.opts.command.buildOptions
    if not isTrue(buildOptions.clean) and isTrue(buildOptions.verbose) then
        self:createBuilderStatusReporter(nil)(ast.NewCompilerDiagnostic(
            diagnostics.Projects_in_this_build_Colon_0,
            table.concat(core.Map(self:Order(), function(p)
                return "\r\n    * " .. self:relativeFileName(p)
            end), "")
        ))
    end
    local buildResult = build.newOrchestratorResult()
    if core.Len(self.errors) == 0 then
        buildResult.statistics.projects = core.Len(self:Order())
        self:rangeTask(function(path, task)
            self:buildOrCleanProject(task, path, buildResult)
        end)
    else
        -- Circularity errors prevent any project from being built
        buildResult.result.status = tsc.ExitStatus.ProjectReferenceCycle_OutputsSkipped
        local reportDiagnostic = self:createDiagnosticReporter(nil)
        for _, err in ipairs(self.errors) do
            reportDiagnostic(err)
        end
        buildResult.errors = self.errors
    end
    buildResult:report(self)
    return buildResult.result
end

-- Go runs f on up to --builders goroutines (4 by default) that pick tasks in build order; tasks
-- wait on their upstream tasks and report in order. The Lua port runs them one after the other in
-- build order, which is what --singleThreaded does.
function Orchestrator:rangeTask(f)
    for _, config in ipairs(self.order or {}) do
        local path = self:toPath(config)
        local task = self:getTask(path)
        f(path, task)
    end
end

function Orchestrator:buildOrCleanProject(task, path, buildResult)
    task.result = build.newTaskResult()
    task.result.reportStatus = self:createBuilderStatusReporter(task)
    task.result.diagnosticReporter = self:createDiagnosticReporter(task)
    if not isTrue(self.opts.command.buildOptions.clean) then
        task:buildProject(self, path)
    else
        task:cleanProject(self, path)
    end
    task:report(self, path, buildResult)
end

function Orchestrator:getWriter(task)
    if task == nil then
        return self.opts.sys:Writer()
    end
    return task.result.builder
end

function Orchestrator:createBuilderStatusReporter(task)
    return tsc.CreateBuilderStatusReporter(self.opts.sys, self:getWriter(task), self.opts.command:Locale(), self.opts.command.compilerOptions, self.opts.testing)
end

function Orchestrator:createDiagnosticReporter(task)
    return tsc.CreateDiagnosticReporter(self.opts.sys, self:getWriter(task), self.opts.command:Locale(), self.opts.command.compilerOptions)
end

-- opts: { sys, command, testing }
function build.NewOrchestrator(opts)
    local sys = opts.sys
    local wm = watchmanager.NewWatchManager(sys:Writer(), function(p) return sys:FS():DirectoryExists(p) end)
    local orchestrator = setmetatable({
        opts = opts,
        comparePathsOptions = tspath.NewComparePathsOptions(
            sys:FS():UseCaseSensitiveFileNames(),
            sys:GetCurrentDirectory()
        ),
        host = nil,

        -- contentMapperHost transforms content-mapped files; it is created once per build session (when
        -- enabled) and shared across all projects so mapper processes are consolidated.
        contentMapperHost = nil,

        -- order generation result
        tasks = collections.NewSyncMap(),
        order = nil,
        errors = nil,

        errorSummaryReporter = nil,
        watchStatusReporter = nil,

        -- fswatch event-based watching
        wm = wm,
    }, Orchestrator)
    orchestrator.host = build.newHost(
        orchestrator,
        compiler.NewCachedFSCompilerHost(
            sys:GetCurrentDirectory(),
            sys:FS(),
            sys:DefaultLibraryPath(),
            nil,
            nil,
            nil
        ),
        collections.NewSyncMap()
    )
    if isTrue(opts.command.compilerOptions.watch) then
        orchestrator.watchStatusReporter = tsc.CreateWatchStatusReporter(sys, opts.command:Locale(), opts.command.compilerOptions, opts.testing)
        local t, ok = watchmanager.AsCommandLineTestingWithWatchBackend(opts.testing)
        if ok then
            wm:SetBackend(t:WatchBackend())
        end
    else
        orchestrator.errorSummaryReporter = tsc.CreateReportErrorSummary(sys, opts.command:Locale(), opts.command.compilerOptions)
    end
    return orchestrator
end
