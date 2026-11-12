local build = require("tslua.execute.build")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local incremental = require("tslua.execute.incremental")
local tsc = require("tslua.execute.tsc")
local tspath = require("tslua.tspath")

local isTrue = core.Tristate_IsTrue
local upToDateStatusType = build.upToDateStatusType

-- buildKind (unexported Go enum, iota order)
local buildKind = {
    None = 0,
    Pseudo = 1,
    Program = 2,
}
build.buildKind = buildKind

-- Go channels used as completion signals (`chan struct{}` that is only ever closed). The build
-- runs sequentially in build order, so a receive must always find the channel closed already.
local chan = {}
chan.__index = chan

function build.newChan()
    return setmetatable({ closed = false }, chan)
end

function chan:close()
    if self.closed then
        error("close of closed channel", 0)
    end
    self.closed = true
end

function chan:receive()
    if not self.closed then
        error("all goroutines are asleep - deadlock!", 0)
    end
end

-- upstreamTask: { task = *BuildTask, refIndex = int }
function build.newUpstreamTask(task, refIndex)
    return { task = task, refIndex = refIndex }
end

-- buildInfoEntry: { buildInfo = *incremental.BuildInfo, path = tspath.Path, mTime = time.Time,
--   dtsTime = *time.Time (number or nil) }
function build.newBuildInfoEntry(fields)
    return {
        buildInfo = fields.buildInfo,
        path = fields.path or "",
        mTime = fields.mTime or 0,
        dtsTime = fields.dtsTime,
    }
end

-- taskResult: { builder = strings.Builder, reportStatus, diagnosticReporter, exitStatus, statistics,
--   program = *incremental.Program, buildKind, filesToDelete }
function build.newTaskResult()
    return {
        builder = core.NewStringBuilder(),
        reportStatus = nil,
        diagnosticReporter = nil,
        exitStatus = tsc.ExitStatus.Success,
        statistics = nil,
        program = nil,
        buildKind = buildKind.None,
        filesToDelete = nil,
    }
end

local BuildTask = {}
BuildTask.__index = BuildTask
build.BuildTask = BuildTask

function build.newBuildTask(config, isInitialCycle)
    return setmetatable({
        config = config,
        resolved = nil,
        upStream = nil,
        downStream = nil, -- Only set and used in watch mode
        status = nil,
        done = nil,

        -- task reporting
        result = nil,
        prevReporter = nil,
        reportDone = nil,

        buildInfoEntry = nil,
        packageJsons = nil,

        errors = nil,
        pending = false,
        isInitialCycle = isInitialCycle or false,
        dirty = false,

        contentMapperProjectOnce = false,
        contentMapperProject = nil,
        contentMapperProjectErr = nil,
    }, BuildTask)
end

-- Returns (contentmapper.Project, err).
function BuildTask:getContentMapperProject(orchestrator)
    if not self.contentMapperProjectOnce then
        self.contentMapperProjectOnce = true
        if not (orchestrator.contentMapperHost == nil or self.resolved == nil or core.Len(self.resolved:ContentMappers()) == 0) then
            self.contentMapperProject = orchestrator.contentMapperHost:Project({
                configFileName = self.resolved:ConfigName(),
                mappers = self.resolved:ContentMappers(),
                compilerOptions = self.resolved:CompilerOptions(),
            })
        end
    end
    return self.contentMapperProject, self.contentMapperProjectErr
end

function BuildTask:refreshContentMapperProject(orchestrator)
    if self.contentMapperProject ~= nil then
        self.contentMapperProjectErr = self.contentMapperProject:Refresh()
    end
end

function BuildTask:waitOnUpstream()
    for _, upstream in ipairs(self.upStream or {}) do
        upstream.task.done:receive()
    end
end

function BuildTask:unblockDownstream()
    self.pending = false
    self.isInitialCycle = false
    self.done:close()
end

function BuildTask:reportDiagnostic(err)
    self.errors = core.Append(self.errors, err)
    self.result.diagnosticReporter(err)
end

function BuildTask:report(orchestrator, configPath, buildResult)
    if self.prevReporter ~= nil then
        self.prevReporter.reportDone:receive()
    end
    if core.Len(self.errors) > 0 then
        local errs = buildResult.errors or {}
        for _, e in ipairs(self.errors) do
            errs[#errs + 1] = e
        end
        buildResult.errors = errs
    end
    orchestrator.opts.sys:Writer():WriteString(self.result.builder:String())
    if self.result.exitStatus > buildResult.result.status then
        buildResult.result.status = self.result.exitStatus
    end
    if self.result.statistics ~= nil then
        buildResult.statistics:Aggregate(self.result.statistics)
    end
    -- If we built the program, or updated timestamps, or had errors, we need to
    -- delete files that are no longer needed
    if self.result.buildKind == buildKind.Program then
        if orchestrator.opts.testing ~= nil then
            orchestrator.opts.testing:OnProgram(self.result.program)
        end
        buildResult.statistics.projectsBuilt = buildResult.statistics.projectsBuilt + 1
    elseif self.result.buildKind == buildKind.Pseudo then
        buildResult.statistics.timestampUpdates = buildResult.statistics.timestampUpdates + 1
    end
    if self.result.filesToDelete ~= nil then
        buildResult.filesToDelete = buildResult.filesToDelete or {}
        for _, f in ipairs(self.result.filesToDelete) do
            buildResult.filesToDelete[#buildResult.filesToDelete + 1] = f
        end
    end
    self.result = nil
    self.reportDone:close()
end

function BuildTask:buildProject(orchestrator, path)
    -- Wait on upstream tasks to complete
    self:waitOnUpstream()
    if self.pending then
        self.status = self:getUpToDateStatus(orchestrator, path)
        self:reportUpToDateStatus(orchestrator)
        if not self:handleStatusThatDoesntRequireBuild(orchestrator) then
            self:compileAndEmit(orchestrator, path)
            self:updateDownstream(orchestrator, path)
        else
            if self.resolved ~= nil then
                for _, diagnostic in ipairs(self.resolved:GetConfigFileParsingDiagnostics() or {}) do
                    self:reportDiagnostic(diagnostic)
                end
            end
            if core.Len(self.errors) > 0 then
                self.result.exitStatus = tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped
            end
        end
    else
        if core.Len(self.errors) > 0 then
            self:reportUpToDateStatus(orchestrator)
            for _, err in ipairs(self.errors) do
                -- Should not add the diagnostics so just reporting
                self.result.diagnosticReporter(err)
            end
        end
    end
    self:unblockDownstream()
end

function BuildTask:updateDownstream(orchestrator, path)
    if self.isInitialCycle then
        return
    end
    if isTrue(orchestrator.opts.command.buildOptions.stopBuildOnErrors) and self.status:isError() then
        return
    end
    if self.result.program == nil then
        for _, downStream in ipairs(self.downStream or {}) do
            downStream:resetStatus()
            downStream.pending = true
        end
        return
    end

    for _, downStream in ipairs(self.downStream or {}) do
        if downStream.status ~= nil then
            local kind = downStream.status.kind
            local fallthrough = false
            if kind == upToDateStatusType.UpToDate then
                if not self.result.program:HasChangedDtsFile() then
                    downStream.status = build.newUpToDateStatus(upToDateStatusType.UpToDateWithUpstreamTypes, downStream.status.data)
                else
                    fallthrough = true
                end
            end
            if fallthrough or kind == upToDateStatusType.UpToDateWithUpstreamTypes or kind == upToDateStatusType.UpToDateWithInputFileText then
                if self.result.program:HasChangedDtsFile() then
                    downStream.status = build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(self.config, downStream.status:oldestOutputFileName()))
                end
            elseif kind == upToDateStatusType.UpstreamErrors then
                local upstreamErrors = downStream.status:upstreamErrors()
                local refConfig = core.ResolveConfigFileNameOfProjectReference(upstreamErrors.ref)
                if orchestrator:toPath(refConfig) == path then
                    downStream:resetStatus()
                end
            end
        end
        downStream.pending = true
    end
end

local function firstOfSeq(seq)
    if seq == nil then
        return ""
    end
    if type(seq) == "table" then
        return seq[1] or ""
    end
    return seq() or ""
end

function BuildTask:compileAndEmit(orchestrator, path)
    self.errors = nil
    if isTrue(orchestrator.opts.command.buildOptions.verbose) then
        self.result.reportStatus(ast.NewCompilerDiagnostic(diagnostics.Building_project_0, orchestrator:relativeFileName(self.config)))
    end

    -- Real build
    local compileTimes = tsc.NewCompileTimes()
    local configTime = orchestrator.host.configTimes:Load(path)
    compileTimes.configTime = configTime or 0
    local sys = orchestrator.opts.sys
    local buildInfoReadStart = sys:Now()
    local oldProgram = nil
    local contentMapperProject, err = self:getContentMapperProject(orchestrator)
    if err ~= nil then
        self:reportDiagnostic(compiler.ContentMapperProjectDiagnostic(err))
        self.status = build.newUpToDateStatus(upToDateStatusType.BuildErrors)
        self.result.exitStatus = tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped
        return
    end
    local host = build.newCompilerHost(
        orchestrator.host,
        tsc.GetTraceWithWriterFromSys(self.result.builder, orchestrator.opts.command:Locale(), orchestrator.opts.testing),
        contentMapperProject
    )
    if not isTrue(orchestrator.opts.command.buildOptions.force) then
        oldProgram = incremental.ReadBuildInfoProgram(self.resolved, orchestrator.host, host)
    end
    compileTimes.buildInfoReadTime = sys:Now() - buildInfoReadStart
    local parseStart = sys:Now()
    local program = compiler.NewProgram(compiler.NewProgramOptions({
        config = self.resolved,
        host = host,
    }))
    compileTimes.parseTime = sys:Now() - parseStart
    local changesComputeStart = sys:Now()
    self.result.program = incremental.NewProgram(program, oldProgram, orchestrator.host, function() return sys:Now() end, orchestrator.opts.testing ~= nil)
    compileTimes.changesComputeTime = sys:Now() - changesComputeStart

    local result, statistics = tsc.EmitAndReportStatistics({
        sys = sys,
        programLike = self.result.program,
        program = program,
        config = self.resolved,
        reportDiagnostic = function(d) self:reportDiagnostic(d) end,
        reportErrorSummary = tsc.QuietDiagnosticsReporter,
        writer = self.result.builder,
        writeFile = function(fileName, text, data)
            return self:writeFile(orchestrator, fileName, text, data)
        end,
        compileTimes = compileTimes,
        testing = orchestrator.opts.testing,
        testingMTimesCache = orchestrator.host.mTimes,
    })
    self.result.exitStatus = result.status
    self.result.statistics = statistics
    self.packageJsons = self.result.program:PackageJsonLookupPaths()
    local emittedFiles = result.emitResult and result.emitResult.emittedFiles
    if (not isTrue(program:Options().noEmitOnError) or core.Len(result.diagnostics) == 0) and
        (core.Len(emittedFiles) > 0 or self.status.kind ~= upToDateStatusType.OutOfDateBuildInfoWithErrors) then
        -- Update time stamps for rest of the outputs
        self:updateTimeStamps(orchestrator, emittedFiles, diagnostics.Updating_unchanged_output_timestamps_of_project_0)
    end
    self.result.buildKind = buildKind.Program
    if result.status == tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped or result.status == tsc.ExitStatus.DiagnosticsPresent_OutputsGenerated then
        self.status = build.newUpToDateStatus(upToDateStatusType.BuildErrors)
    else
        local oldestOutputFileName
        if core.Len(emittedFiles) > 0 then
            oldestOutputFileName = emittedFiles[1]
        else
            oldestOutputFileName = firstOfSeq(self.resolved:GetOutputFileNames())
        end
        self.status = build.newUpToDateStatus(upToDateStatusType.UpToDate, oldestOutputFileName)
    end
end

function BuildTask:handleStatusThatDoesntRequireBuild(orchestrator)
    local buildOptions = orchestrator.opts.command.buildOptions
    local kind = self.status.kind
    if kind == upToDateStatusType.UpToDate then
        if isTrue(buildOptions.dry) then
            self.result.reportStatus(ast.NewCompilerDiagnostic(diagnostics.Project_0_is_up_to_date, self.config))
        end
        return true
    elseif kind == upToDateStatusType.UpstreamErrors then
        local upstreamStatus = self.status:upstreamErrors()
        if isTrue(buildOptions.verbose) then
            self.result.reportStatus(ast.NewCompilerDiagnostic(
                core.IfElse(
                    upstreamStatus.refHasUpstreamErrors,
                    diagnostics.Skipping_build_of_project_0_because_its_dependency_1_was_not_built,
                    diagnostics.Skipping_build_of_project_0_because_its_dependency_1_has_errors
                ),
                orchestrator:relativeFileName(self.config),
                orchestrator:relativeFileName(upstreamStatus.ref)
            ))
        end
        return true
    elseif kind == upToDateStatusType.Solution then
        return true
    elseif kind == upToDateStatusType.ConfigFileNotFound then
        self:reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.File_0_not_found, self.config))
        return true
    end

    -- update timestamps
    if self.status:isPseudoBuild() then
        if isTrue(buildOptions.dry) then
            self.result.reportStatus(ast.NewCompilerDiagnostic(diagnostics.A_non_dry_build_would_update_timestamps_for_output_of_project_0, self.config))
            self.status = build.newUpToDateStatus(upToDateStatusType.UpToDate)
            return true
        end

        self:updateTimeStamps(orchestrator, nil, diagnostics.Updating_output_timestamps_of_project_0)
        self.status = build.newUpToDateStatus(upToDateStatusType.UpToDate, self.status.data)
        self.result.buildKind = buildKind.Pseudo
        return true
    end

    if isTrue(buildOptions.dry) then
        self.result.reportStatus(ast.NewCompilerDiagnostic(diagnostics.A_non_dry_build_would_build_project_0, self.config))
        self.status = build.newUpToDateStatus(upToDateStatusType.UpToDate)
        return true
    end
    return false
end

function BuildTask:getUpToDateStatus(orchestrator, configPath)
    if self.status ~= nil then
        return self.status
    end
    -- Config file not found
    if self.resolved == nil then
        return build.newUpToDateStatus(upToDateStatusType.ConfigFileNotFound)
    end

    -- Solution - nothing to build
    if core.Len(self.resolved:FileNames()) == 0 and self.resolved:ProjectReferences() ~= nil then
        return build.newUpToDateStatus(upToDateStatusType.Solution)
    end

    local buildOptions = orchestrator.opts.command.buildOptions
    for _, upstream in ipairs(self.upStream or {}) do
        if isTrue(buildOptions.stopBuildOnErrors) and upstream.task.status:isError() then
            -- Upstream project has errors, so we cannot build this project
            return build.newUpToDateStatus(upToDateStatusType.UpstreamErrors, build.newUpstreamErrors(self.resolved:ProjectReferences()[upstream.refIndex + 1].path, upstream.task.status.kind == upToDateStatusType.UpstreamErrors))
        end
    end

    if isTrue(buildOptions.force) then
        return build.newUpToDateStatus(upToDateStatusType.ForceBuild)
    end

    -- Check the build info
    local buildInfoPath = self.resolved:GetBuildInfoFileName()
    local getBuildInfoDirectory = core.Memoize(function()
        return tspath.GetDirectoryPath(tspath.GetNormalizedAbsolutePath(buildInfoPath, orchestrator.comparePathsOptions.currentDirectory))
    end)
    local buildInfo, buildInfoTime = self:loadOrStoreBuildInfo(orchestrator, configPath, buildInfoPath)
    if buildInfo == nil then
        return build.newUpToDateStatus(upToDateStatusType.OutputMissing, buildInfoPath)
    end

    -- build info version
    if not buildInfo:IsValidVersion() then
        return build.newUpToDateStatus(upToDateStatusType.TsVersionOutputOfDate, buildInfo.version)
    end

    -- If a configured content mapper's identity has changed, files it produced may be stale.
    local contentMapperProject, err = self:getContentMapperProject(orchestrator)
    local contentMapperIdentities, identityErr = incremental.ContentMapperIdentities(contentMapperProject)
    if identityErr ~= nil then
        self.contentMapperProjectErr = identityErr
    end
    if err ~= nil or identityErr ~= nil or not buildInfo:ContentMapperIdentitiesMatch(contentMapperIdentities) then
        return build.newUpToDateStatus(upToDateStatusType.OutOfDateOptions, buildInfoPath)
    end

    local options = self.resolved:CompilerOptions()
    -- Report errors if build info indicates errors
    if buildInfo.errors or -- Errors that need to be reported irrespective of "--noCheck"
        (not isTrue(options.noCheck) and (buildInfo.semanticErrors or buildInfo.checkPending)) then -- Errors without --noCheck
        return build.newUpToDateStatus(upToDateStatusType.OutOfDateBuildInfoWithErrors, buildInfoPath)
    end

    if options:IsIncremental() then
        if not buildInfo:IsIncremental() then
            -- Program options out of date
            return build.newUpToDateStatus(upToDateStatusType.OutOfDateOptions, buildInfoPath)
        end

        -- Errors need to be reported if build info has errors
        if (options:GetEmitDeclarations() and buildInfo.emitDiagnosticsPerFile ~= nil) or -- Always reported errors
            (not isTrue(options.noCheck) and -- Semantic errors if not --noCheck
                (buildInfo.changeFileSet ~= nil or buildInfo.semanticDiagnosticsPerFile ~= nil)) then
            return build.newUpToDateStatus(upToDateStatusType.OutOfDateBuildInfoWithErrors, buildInfoPath)
        end

        -- Pending emit files
        if not isTrue(options.noEmit) and
            (buildInfo.changeFileSet ~= nil or buildInfo.affectedFilesPendingEmit ~= nil) then
            return build.newUpToDateStatus(upToDateStatusType.OutOfDateBuildInfoWithPendingEmit, buildInfoPath)
        end

        -- Some of the emit files like source map or dts etc are not yet done
        if buildInfo:IsEmitPending(self.resolved, getBuildInfoDirectory()) then
            return build.newUpToDateStatus(upToDateStatusType.OutOfDateOptions, buildInfoPath)
        end
    end
    local inputTextUnchanged = false
    local oldestOutputFileAndTime = build.newFileAndTime(buildInfoPath, buildInfoTime)
    local newestInputFileAndTime = build.newFileAndTime()
    local seenRoots = collections.NewSet()
    local getBuildInfoRootInfoReader = core.Memoize(function()
        return buildInfo:GetBuildInfoRootInfoReader(getBuildInfoDirectory(), orchestrator.comparePathsOptions)
    end)
    for _, inputFile in ipairs(self.resolved:FileNames() or {}) do
        local inputTime = orchestrator.host:GetMTime(inputFile)
        if inputTime == 0 then
            return build.newUpToDateStatus(upToDateStatusType.InputFileMissing, inputFile)
        end
        local inputPath = orchestrator:toPath(inputFile)
        if inputTime > oldestOutputFileAndTime.time then
            local version = ""
            local currentVersion = ""
            if buildInfo:IsIncremental() then
                local buildInfoFileInfo, resolvedInputPath = getBuildInfoRootInfoReader():GetBuildInfoFileInfo(inputPath)
                local fileInfo = nil
                if buildInfoFileInfo ~= nil then
                    fileInfo = buildInfoFileInfo:GetFileInfo()
                end
                if fileInfo ~= nil and fileInfo:Version() ~= "" then
                    version = fileInfo:Version()
                    local text, ok = orchestrator.host:FS():ReadFile(resolvedInputPath)
                    if ok then
                        currentVersion = incremental.ComputeHash(text, orchestrator.opts.testing ~= nil)
                        if version == currentVersion then
                            inputTextUnchanged = true
                        end
                    end
                end
            end

            if version == "" or version ~= currentVersion then
                return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(inputFile, buildInfoPath))
            end
        end
        if inputTime > newestInputFileAndTime.time then
            newestInputFileAndTime = build.newFileAndTime(inputFile, inputTime)
        end
        seenRoots:Add(inputPath)
    end

    for root in getBuildInfoRootInfoReader():Roots() do
        if not seenRoots:Has(root) then
            -- File was root file when project was built but its not any more
            return build.newUpToDateStatus(upToDateStatusType.OutOfDateRoots, build.newInputOutputName(root, buildInfoPath))
        end
    end

    if buildInfo:IsIncremental() then
        local resolvedRoots = collections.NewSet()
        for root in getBuildInfoRootInfoReader():Roots() do
            local _, resolved = getBuildInfoRootInfoReader():GetBuildInfoFileInfo(root)
            if resolved ~= "" then
                resolvedRoots:Add(resolved)
            end
        end
        for index1, buildInfoFileInfo in ipairs(buildInfo.fileInfos or {}) do
            local buildInfoFileName = buildInfo.fileNames[index1]
            -- Lib files bundled with the compiler can change only with the version of the compiler,
            -- which is already verified with buildInfo.Version
            if incremental.IsBuildInfoFileNameDefaultLibrary(buildInfoFileName) then
                goto continue
            end
            do
                local inputFile = tspath.GetNormalizedAbsolutePath(buildInfoFileName, getBuildInfoDirectory())
                local inputPath = orchestrator:toPath(inputFile)
                -- Root files are already checked
                if seenRoots:Has(inputPath) or resolvedRoots:Has(inputPath) then
                    goto continue
                end
                if build.isContentMapperSupplementalBuildInfoPath(inputPath, getBuildInfoRootInfoReader():Roots()) then
                    goto continue
                end
                local inputTime = orchestrator.host:GetMTime(inputFile)
                if inputTime == 0 then
                    -- Input file that was part of the program is missing (eg: dependency was removed)
                    return build.newUpToDateStatus(upToDateStatusType.InputFileMissing, inputFile)
                end

                if inputTime > oldestOutputFileAndTime.time then
                    local currentVersion = ""
                    local version = buildInfoFileInfo:GetFileInfo():Version()
                    if version ~= "" then
                        local text, ok = orchestrator.host:FS():ReadFile(inputFile)
                        if ok then
                            currentVersion = incremental.ComputeHash(text, orchestrator.opts.testing ~= nil)
                        end
                    end
                    if version == "" or version ~= currentVersion then
                        return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(inputFile, buildInfoPath))
                    end
                    inputTextUnchanged = true
                end
            end
            ::continue::
        end
    end

    if not options:IsIncremental() then
        -- Check output file stamps
        for outputFile in self.resolved:GetOutputFileNames() do
            local outputTime = orchestrator.host:GetMTime(outputFile)
            if outputTime == 0 then
                -- Output file missing
                return build.newUpToDateStatus(upToDateStatusType.OutputMissing, outputFile)
            end

            if outputTime < newestInputFileAndTime.time then
                -- Output file is older than input file
                return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(newestInputFileAndTime.file, outputFile))
            end

            if outputTime < oldestOutputFileAndTime.time then
                oldestOutputFileAndTime = build.newFileAndTime(outputFile, outputTime)
            end
        end
    end

    local refDtsUnchanged = false
    for _, upstream in ipairs(self.upStream or {}) do
        if upstream.task.status.kind == upToDateStatusType.Solution then
            -- Not dependent on the status or this upstream project
            -- (eg: expected cycle was detected and hence skipped, or is solution)
            goto continueUpstream
        end

        do
            -- If the upstream project's newest file is older than our oldest output,
            -- we can't be out of date because of it
            -- inputTime will not be present if we just built this project or updated timestamps
            -- - in that case we do want to either build or update timestamps
            local refInputOutputFileAndTime = upstream.task.status:inputOutputFileAndTime()
            if refInputOutputFileAndTime ~= nil and refInputOutputFileAndTime.input.time ~= 0 and refInputOutputFileAndTime.input.time < oldestOutputFileAndTime.time then
                goto continueUpstream
            end

            -- Check if tsbuildinfo path is shared, then we need to rebuild
            if self:hasConflictingBuildInfo(orchestrator, upstream.task) then
                -- We have an output older than an upstream output - we are out of date
                return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(self.resolved:ProjectReferences()[upstream.refIndex + 1].path, oldestOutputFileAndTime.file))
            end

            -- If the upstream project has only change .d.ts files, and we've built
            -- *after* those files, then we're "pseudo up to date" and eligible for a fast rebuild
            local newestDtsChangeTime = upstream.task:getLatestChangedDtsMTime(orchestrator)
            if newestDtsChangeTime ~= 0 and newestDtsChangeTime < oldestOutputFileAndTime.time then
                refDtsUnchanged = true
                goto continueUpstream
            end

            -- We have an output older than an upstream output - we are out of date
            return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(self.resolved:ProjectReferences()[upstream.refIndex + 1].path, oldestOutputFileAndTime.file))
        end
        ::continueUpstream::
    end

    local function checkInputFileTime(inputFile)
        local inputTime = orchestrator.host:GetMTime(inputFile)
        if inputTime > oldestOutputFileAndTime.time then
            -- Output file is older than input file
            return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(inputFile, oldestOutputFileAndTime.file))
        end
        return nil
    end

    local configStatus = checkInputFileTime(self.config)
    if configStatus ~= nil then
        return configStatus
    end

    for _, extendedConfig in ipairs(self.resolved:ExtendedSourceFiles() or {}) do
        local extendedConfigStatus = checkInputFileTime(extendedConfig)
        if extendedConfigStatus ~= nil then
            return extendedConfigStatus
        end
    end

    for packageJson in buildInfo:GetPackageJsons(getBuildInfoDirectory()) do
        local packageJsonTime = orchestrator.host:GetMTime(packageJson)
        if packageJsonTime == 0 then
            return build.newUpToDateStatus(upToDateStatusType.InputFileMissing, packageJson)
        end
        if packageJsonTime > oldestOutputFileAndTime.time then
            return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(packageJson, oldestOutputFileAndTime.file))
        end
    end
    for packageJson in buildInfo:GetMissingPackageJsons(getBuildInfoDirectory()) do
        if orchestrator.host:GetMTime(packageJson) ~= 0 then
            return build.newUpToDateStatus(upToDateStatusType.InputFileNewer, build.newInputOutputName(packageJson, oldestOutputFileAndTime.file))
        end
    end
    local packageJsons = {}
    for packageJson in buildInfo:GetPackageJsons(getBuildInfoDirectory()) do
        packageJsons[#packageJsons + 1] = packageJson
    end
    for packageJson in buildInfo:GetMissingPackageJsons(getBuildInfoDirectory()) do
        packageJsons[#packageJsons + 1] = packageJson
    end
    if #packageJsons == 0 then
        -- slices.Collect of an empty sequence is nil, and append of nothing keeps it nil.
        packageJsons = nil
    end
    self.packageJsons = packageJsons

    return build.newUpToDateStatus(
        core.IfElse(
            refDtsUnchanged,
            upToDateStatusType.UpToDateWithUpstreamTypes,
            core.IfElse(inputTextUnchanged, upToDateStatusType.UpToDateWithInputFileText, upToDateStatusType.UpToDate)
        ),
        build.newInputOutputFileAndTime(newestInputFileAndTime, oldestOutputFileAndTime, buildInfoPath)
    )
end

-- roots is a Lua iterator (iter.Seq).
function build.isContentMapperSupplementalBuildInfoPath(inputPath, roots)
    for root in roots do
        local prefix = root .. "."
        if string.sub(inputPath, 1, #prefix) ~= prefix then
            goto continue
        end
        do
            local suffix = string.sub(inputPath, #prefix + 1)
            local dot = string.find(suffix, ".", 1, true)
            if dot == nil then
                goto continue
            end
            local index = string.sub(suffix, 1, dot - 1)
            local extension = string.sub(suffix, dot + 1)
            if extension == "" then
                goto continue
            end
            -- strconv.Atoi
            if string.match(index, "^[+-]?%d+$") ~= nil and require("tslua.contentmapper").IsSupportedVirtualExtension("." .. extension) then
                return true
            end
        end
        ::continue::
    end
    return false
end

function BuildTask:reportUpToDateStatus(orchestrator)
    if not isTrue(orchestrator.opts.command.buildOptions.verbose) then
        return
    end
    local kind = self.status.kind
    local rel = function(f) return orchestrator:relativeFileName(f) end
    local reportStatus = self.result.reportStatus
    if kind == upToDateStatusType.ConfigFileNotFound then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_config_file_does_not_exist,
            rel(self.config)
        ))
    elseif kind == upToDateStatusType.UpstreamErrors then
        local upstreamStatus = self.status:upstreamErrors()
        reportStatus(ast.NewCompilerDiagnostic(
            core.IfElse(
                upstreamStatus.refHasUpstreamErrors,
                diagnostics.Project_0_can_t_be_built_because_its_dependency_1_was_not_built,
                diagnostics.Project_0_can_t_be_built_because_its_dependency_1_has_errors
            ),
            rel(self.config),
            rel(upstreamStatus.ref)
        ))
    elseif kind == upToDateStatusType.BuildErrors then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_it_has_errors,
            rel(self.config)
        ))
    elseif kind == upToDateStatusType.UpToDate then
        -- This is to ensure skipping verbose log for projects that were built,
        -- and then some other package changed but this package doesnt need update
        local inputOutputFileAndTime = self.status:inputOutputFileAndTime()
        if inputOutputFileAndTime ~= nil then
            reportStatus(ast.NewCompilerDiagnostic(
                diagnostics.Project_0_is_up_to_date_because_newest_input_1_is_older_than_output_2,
                rel(self.config),
                rel(inputOutputFileAndTime.input.file),
                rel(inputOutputFileAndTime.output.file)
            ))
        end
    elseif kind == upToDateStatusType.UpToDateWithUpstreamTypes then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_up_to_date_with_d_ts_files_from_its_dependencies,
            rel(self.config)
        ))
    elseif kind == upToDateStatusType.UpToDateWithInputFileText then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_up_to_date_but_needs_to_update_timestamps_of_output_files_that_are_older_than_input_files,
            rel(self.config)
        ))
    elseif kind == upToDateStatusType.InputFileMissing then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_input_1_does_not_exist,
            rel(self.config),
            rel(self.status.data)
        ))
    elseif kind == upToDateStatusType.OutputMissing then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_output_file_1_does_not_exist,
            rel(self.config),
            rel(self.status.data)
        ))
    elseif kind == upToDateStatusType.InputFileNewer then
        local inputOutput = self.status:inputOutputName()
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_output_1_is_older_than_input_2,
            rel(self.config),
            rel(inputOutput.output),
            rel(inputOutput.input)
        ))
    elseif kind == upToDateStatusType.OutOfDateBuildInfoWithPendingEmit then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_buildinfo_file_1_indicates_that_some_of_the_changes_were_not_emitted,
            rel(self.config),
            rel(self.status.data)
        ))
    elseif kind == upToDateStatusType.OutOfDateBuildInfoWithErrors then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_buildinfo_file_1_indicates_that_program_needs_to_report_errors,
            rel(self.config),
            rel(self.status.data)
        ))
    elseif kind == upToDateStatusType.OutOfDateOptions then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_buildinfo_file_1_indicates_there_is_change_in_compilerOptions,
            rel(self.config),
            rel(self.status.data)
        ))
    elseif kind == upToDateStatusType.OutOfDateRoots then
        local inputOutput = self.status:inputOutputName()
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_buildinfo_file_1_indicates_that_file_2_was_root_file_of_compilation_but_not_any_more,
            rel(self.config),
            rel(inputOutput.output),
            rel(inputOutput.input)
        ))
    elseif kind == upToDateStatusType.TsVersionOutputOfDate then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_out_of_date_because_output_for_it_was_generated_with_version_1_that_differs_with_current_version_2,
            rel(self.config),
            rel(self.status.data),
            core.Version()
        ))
    elseif kind == upToDateStatusType.ForceBuild then
        reportStatus(ast.NewCompilerDiagnostic(
            diagnostics.Project_0_is_being_forcibly_rebuilt,
            rel(self.config)
        ))
    elseif kind == upToDateStatusType.Solution then
        -- Does not need to report status
        return
    else
        error("Unknown up to date status kind: " .. tostring(kind), 0)
    end
end

function BuildTask:canUpdateJsDtsOutputTimestamps()
    return not isTrue(self.resolved:CompilerOptions().noEmit) and not self.resolved:CompilerOptions():IsIncremental()
end

function BuildTask:updateTimeStamps(orchestrator, emittedFiles, verboseMessage)
    local emitted = collections.NewSet()
    for _, f in ipairs(emittedFiles or {}) do
        emitted:Add(f)
    end
    local verboseMessageReported = false
    local buildInfoName = self.resolved:GetBuildInfoFileName()
    local now = orchestrator.opts.sys:Now()
    local function updateTimeStamp(file)
        if emitted:Has(file) then
            return
        end
        if not verboseMessageReported and isTrue(orchestrator.opts.command.buildOptions.verbose) then
            self.result.reportStatus(ast.NewCompilerDiagnostic(verboseMessage, orchestrator:relativeFileName(self.config)))
            verboseMessageReported = true
        end
        local err = orchestrator.host:SetMTime(file, now)
        if err == nil then
            if file == buildInfoName then
                if self.buildInfoEntry ~= nil then
                    self.buildInfoEntry.mTime = now
                end
            elseif self:storeOutputTimeStamp(orchestrator) then
                orchestrator.host:storeMTime(file, now)
            end
        end
    end

    if self:canUpdateJsDtsOutputTimestamps() then
        for outputFile in self.resolved:GetOutputFileNames() do
            updateTimeStamp(outputFile)
        end
    end
    updateTimeStamp(self.resolved:GetBuildInfoFileName())
end

function BuildTask:cleanProject(orchestrator, path)
    if self.resolved == nil then
        self:reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.File_0_not_found, self.config))
        self.result.exitStatus = tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped
        return
    end

    local inputs = collections.NewSet()
    for _, f in ipairs(self.resolved:FileNames() or {}) do
        inputs:Add(orchestrator:toPath(f))
    end
    for outputFile in self.resolved:GetOutputFileNames() do
        self:cleanProjectOutput(orchestrator, outputFile, inputs)
    end
    self:cleanProjectOutput(orchestrator, self.resolved:GetBuildInfoFileName(), inputs)
end

function BuildTask:cleanProjectOutput(orchestrator, outputFile, inputs)
    local outputPath = orchestrator:toPath(outputFile)
    -- If output name is same as input file name, do not delete and ignore the error
    if inputs:Has(outputPath) then
        return
    end
    if orchestrator.host:FS():FileExists(outputFile) then
        if not isTrue(orchestrator.opts.command.buildOptions.dry) then
            local err = orchestrator.host:FS():Remove(outputFile)
            if err ~= nil then
                self:reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.Failed_to_delete_file_0, outputFile))
            end
        else
            self.result.filesToDelete = core.Append(self.result.filesToDelete, outputFile)
        end
    end
end

function BuildTask:updateWatch(orchestrator, oldCache)
    if self.resolved ~= nil then
        if self:canUpdateJsDtsOutputTimestamps() then
            for outputFile in self.resolved:GetOutputFileNames() do
                orchestrator.host:storeMTimeFromOldCache(outputFile, oldCache)
            end
        end
    end
end

function BuildTask:resetStatus()
    self.status = nil
    self.pending = true
    self.errors = nil
end

function BuildTask:resetConfig(orchestrator, path)
    self.dirty = true
    orchestrator.host.resolvedReferences:delete(path)
end

-- Returns (*incremental.BuildInfo, time.Time).
function BuildTask:loadOrStoreBuildInfo(orchestrator, configPath, buildInfoFileName)
    local path = orchestrator:toPath(buildInfoFileName)
    if self.buildInfoEntry ~= nil and self.buildInfoEntry.path == path then
        return self.buildInfoEntry.buildInfo, self.buildInfoEntry.mTime
    end
    self.buildInfoEntry = build.newBuildInfoEntry({
        buildInfo = incremental.NewBuildInfoReader(orchestrator.host):ReadBuildInfo(self.resolved),
        path = path,
    })
    local mTime = 0
    if self.buildInfoEntry.buildInfo ~= nil then
        mTime = orchestrator.host:GetMTime(buildInfoFileName)
    end
    self.buildInfoEntry.mTime = mTime
    return self.buildInfoEntry.buildInfo, mTime
end

function BuildTask:onBuildInfoEmit(orchestrator, buildInfoFileName, buildInfo, hasChangedDtsFile)
    local dtsTime = nil
    local mTime = orchestrator.opts.sys:Now()
    if hasChangedDtsFile then
        dtsTime = mTime
    elseif self.buildInfoEntry ~= nil then
        dtsTime = self.buildInfoEntry.dtsTime
    end
    self.buildInfoEntry = build.newBuildInfoEntry({
        buildInfo = buildInfo,
        path = orchestrator:toPath(buildInfoFileName),
        mTime = mTime,
        dtsTime = dtsTime,
    })
end

function BuildTask:hasConflictingBuildInfo(orchestrator, upstream)
    if self.buildInfoEntry ~= nil and upstream.buildInfoEntry ~= nil then
        return self.buildInfoEntry.path == upstream.buildInfoEntry.path
    end
    return false
end

function BuildTask:getLatestChangedDtsMTime(orchestrator)
    if self.buildInfoEntry.dtsTime ~= nil then
        return self.buildInfoEntry.dtsTime
    end
    local dtsTime = orchestrator.host:GetMTime(
        tspath.GetNormalizedAbsolutePath(
            self.buildInfoEntry.buildInfo.latestChangedDtsFile,
            tspath.GetDirectoryPath(self.buildInfoEntry.path)
        )
    )
    self.buildInfoEntry.dtsTime = dtsTime
    return dtsTime
end

function BuildTask:storeOutputTimeStamp(orchestrator)
    return isTrue(orchestrator.opts.command.compilerOptions.watch) and not self.resolved:CompilerOptions():IsIncremental()
end

function BuildTask:writeFile(orchestrator, fileName, text, data)
    local err = orchestrator.host:FS():WriteFile(fileName, text)
    if err == nil then
        if data ~= nil and data.buildInfo ~= nil then
            self:onBuildInfoEmit(orchestrator, fileName, data.buildInfo, self.result.program:HasChangedDtsFile())
        elseif self:storeOutputTimeStamp(orchestrator) then
            -- Store time stamps
            orchestrator.host:storeMTime(fileName, orchestrator.opts.sys:Now())
        end
    end
    return err
end
