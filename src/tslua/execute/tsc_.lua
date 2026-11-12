-- Port of execute/tsc.go (non-watch, non-build paths).
local execute = require("tslua.execute")
local ast = require("tslua.ast")
local build = require("tslua.execute.build")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local incremental = require("tslua.execute.incremental")
local tsc = require("tslua.execute.tsc")
local json = require("tslua.json")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local ExitStatus = tsc.ExitStatus
local isTrue = core.Tristate_IsTrue

function execute.startTracingIfNeeded(sys, config, testing)
    local traceDir = config:CompilerOptions().generateTrace
    if traceDir == "" then
        return nil
    end
    error("not implemented: startTracingIfNeeded (--generateTrace)")
end

function execute.stopTracing(sys, tr)
    if tr == nil then
        return
    end
    error("not implemented: stopTracing (--generateTrace)")
end

-- ctx is unused (Go context.Context); pass nil.
function execute.CommandLine(ctx, sys, commandLineArgs, testing)
    if #commandLineArgs > 0 then
        local first = string.lower(commandLineArgs[1])
        if first == "-b" or first == "--b" or first == "-build" or first == "--build" then
            return execute.tscBuildCompilation(ctx, sys, tsoptions.ParseBuildCommandLine(commandLineArgs, sys), testing)
            -- case "-f":
            -- 	return fmtMain(sys, commandLineArgs[1], commandLineArgs[1])
        end
    end

    return execute.tscCompilation(ctx, sys, tsoptions.ParseCommandLine(commandLineArgs, sys), testing)
end

function execute.fmtMain(sys, input, output)
    error("not implemented: fmtMain (format package is out of scope)")
end

function execute.tscBuildCompilation(ctx, sys, buildCommand, testing)
    local locale = buildCommand:Locale()
    local reportDiagnostic = tsc.CreateDiagnosticReporter(sys, sys:Writer(), locale, buildCommand.compilerOptions)

    if core.Len(buildCommand.errors) > 0 then
        for _, err in ipairs(buildCommand.errors) do
            reportDiagnostic(err)
        end
        return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
    end

    if buildCommand.compilerOptions.pprofDir ~= "" then
        error("not implemented: --pprofDir")
    end

    if isTrue(buildCommand.compilerOptions.help) then
        tsc.PrintVersion(sys, locale)
        tsc.PrintBuildHelp(sys, locale, tsoptions.BuildOpts)
        return tsc.NewCommandLineResult(ExitStatus.Success)
    end

    local orchestrator = build.NewOrchestrator({
        sys = sys,
        command = buildCommand,
        testing = testing,
    })
    return orchestrator:Start(ctx)
end

function execute.tscCompilation(ctx, sys, commandLine, testing)
    local configFileName = ""
    local locale = commandLine:Locale()
    local reportDiagnostic = tsc.CreateDiagnosticReporter(sys, sys:Writer(), locale, commandLine:CompilerOptions())

    if core.Len(commandLine.errors) > 0 then
        for _, e in ipairs(commandLine.errors) do
            reportDiagnostic(e)
        end
        return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
    end

    if commandLine:CompilerOptions().pprofDir ~= "" then
        error("not implemented: --pprofDir")
    end

    if isTrue(commandLine:CompilerOptions().init) then
        tsc.WriteConfigFile(sys, locale, reportDiagnostic, commandLine.raw)
        return tsc.NewCommandLineResult(ExitStatus.Success)
    end

    if isTrue(commandLine:CompilerOptions().version) then
        tsc.PrintVersion(sys, locale)
        return tsc.NewCommandLineResult(ExitStatus.Success)
    end

    if isTrue(commandLine:CompilerOptions().help) or isTrue(commandLine:CompilerOptions().all) then
        tsc.PrintHelp(sys, locale, commandLine)
        return tsc.NewCommandLineResult(ExitStatus.Success)
    end

    if isTrue(commandLine:CompilerOptions().watch) and isTrue(commandLine:CompilerOptions().listFilesOnly) then
        reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.Options_0_and_1_cannot_be_combined, "watch", "listFilesOnly"))
        return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
    end

    if commandLine:CompilerOptions().project ~= "" then
        if core.Len(commandLine:FileNames()) ~= 0 then
            reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.Option_project_cannot_be_mixed_with_source_files_on_a_command_line))
            return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
        end

        local fileOrDirectory = tspath.NormalizePath(commandLine:CompilerOptions().project)
        if sys:FS():DirectoryExists(fileOrDirectory) then
            configFileName = tspath.CombinePaths(fileOrDirectory, "tsconfig.json")
            if not sys:FS():FileExists(configFileName) then
                reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.Cannot_find_a_tsconfig_json_file_at_the_current_directory_Colon_0, configFileName))
                return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
            end
        else
            configFileName = fileOrDirectory
            if not sys:FS():FileExists(configFileName) then
                reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.The_specified_path_does_not_exist_Colon_0, fileOrDirectory))
                return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
            end
        end
    elseif not isTrue(commandLine:CompilerOptions().ignoreConfig) or core.Len(commandLine:FileNames()) == 0 then
        local searchPath = tspath.NormalizePath(sys:GetCurrentDirectory())
        configFileName = execute.findConfigFile(searchPath, function(f) return sys:FS():FileExists(f) end, "tsconfig.json")
        if core.Len(commandLine:FileNames()) ~= 0 then
            if configFileName ~= "" then
                -- Error to not specify config file
                reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.X_tsconfig_json_is_present_but_will_not_be_loaded_if_files_are_specified_on_commandline_Use_ignoreConfig_to_skip_this_error))
                return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
            end
        elseif configFileName == "" then
            if isTrue(commandLine:CompilerOptions().showConfig) then
                reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.Cannot_find_a_tsconfig_json_file_at_the_current_directory_Colon_0, tspath.NormalizePath(sys:GetCurrentDirectory())))
            else
                tsc.PrintVersion(sys, locale)
                tsc.PrintHelp(sys, locale, commandLine)
            end
            return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsSkipped)
        end
    end

    -- !!! convert to options with absolute paths is usually done here, but for ease of implementation, it's done in `tsoptions.ParseCommandLine()`
    local compilerOptionsFromCommandLine = commandLine:CompilerOptions()
    local configForCompilation = commandLine
    local extendedConfigCache = tsc.NewExtendedConfigCache()
    local compileTimes = tsc.NewCompileTimes()
    local commandLineRaw = nil
    if configFileName ~= "" then
        local configStart = sys:Now()
        local raw = commandLine.raw
        if raw ~= nil and getmetatable(raw) == collections.OrderedMap then
            -- Wrap command line options in a "compilerOptions" key to match tsconfig.json structure
            local wrapped = collections.NewOrderedMapWithSizeHint(1)
            wrapped:Set("compilerOptions", raw)
            commandLineRaw = wrapped
        end
        local configParseResult, errors = tsoptions.GetParsedCommandLineOfConfigFile(configFileName, compilerOptionsFromCommandLine, commandLineRaw, sys, extendedConfigCache)
        compileTimes.configTime = sys:Now() - configStart
        if core.Len(errors) ~= 0 then
            -- these are unrecoverable errors--exit to report them as diagnostics
            for _, e in ipairs(errors) do
                reportDiagnostic(e)
            end
            return tsc.NewCommandLineResult(ExitStatus.DiagnosticsPresent_OutputsGenerated)
        end
        configForCompilation = configParseResult
        -- Updater to reflect pretty
        reportDiagnostic = tsc.CreateDiagnosticReporter(sys, sys:Writer(), locale, commandLine:CompilerOptions())
    end

    local reportErrorSummary = tsc.CreateReportErrorSummary(sys, locale, configForCompilation:CompilerOptions())
    if isTrue(compilerOptionsFromCommandLine.showConfig) then
        execute.showConfig(sys, configForCompilation, configFileName)
        return tsc.NewCommandLineResult(ExitStatus.Success)
    end
    if isTrue(configForCompilation:CompilerOptions().watch) then
        local watcher = execute.createWatcher(
            sys,
            configForCompilation,
            compilerOptionsFromCommandLine,
            commandLineRaw,
            reportDiagnostic,
            reportErrorSummary,
            testing
        )
        watcher:start(ctx)
        return tsc.NewCommandLineResult(ExitStatus.Success, watcher)
    elseif configForCompilation:CompilerOptions():IsIncremental() then
        return execute.performIncrementalCompilation(
            ctx,
            sys,
            configForCompilation,
            reportDiagnostic,
            reportErrorSummary,
            extendedConfigCache,
            compileTimes,
            testing
        )
    end
    return execute.performCompilation(
        ctx,
        sys,
        configForCompilation,
        reportDiagnostic,
        reportErrorSummary,
        extendedConfigCache,
        compileTimes,
        testing
    )
end

function execute.findConfigFile(searchPath, fileExists, configName)
    local result, ok = tspath.ForEachAncestorDirectory(searchPath, function(ancestor)
        local fullConfigName = tspath.CombinePaths(ancestor, configName)
        if fileExists(fullConfigName) then
            return fullConfigName, true
        end
        return fullConfigName, false
    end)
    if not ok then
        return ""
    end
    return result
end

function execute.getTraceFromSys(sys, locale, testing)
    return tsc.GetTraceWithWriterFromSys(sys:Writer(), locale, testing)
end

function execute.performIncrementalCompilation(ctx, sys, config, reportDiagnostic, reportErrorSummary, extendedConfigCache, compileTimes, testing)
    local contentMapperHost = tsc.NewContentMapperHost(ctx, sys, config:CompilerOptions())
    local contentMapperProject = execute.getContentMapperProject(contentMapperHost, config)
    local host = compiler.NewCachedFSCompilerHost(sys:GetCurrentDirectory(), sys:FS(), sys:DefaultLibraryPath(), extendedConfigCache, execute.getTraceFromSys(sys, config:Locale(), testing), contentMapperProject)
    local buildInfoReadStart = sys:Now()
    local oldProgram = incremental.ReadBuildInfoProgram(config, incremental.NewBuildInfoReader(host), host)
    compileTimes.buildInfoReadTime = sys:Now() - buildInfoReadStart

    local tr = execute.startTracingIfNeeded(sys, config, testing)

    local parseStart = sys:Now()
    local program = compiler.NewProgram(compiler.NewProgramOptions({
        config = config,
        host = host,
        tracing = tr,
    }))
    compileTimes.parseTime = sys:Now() - parseStart
    local changesComputeStart = sys:Now()
    local incrementalProgram = incremental.NewProgram(program, oldProgram, incremental.CreateHost(host), function() return sys:Now() end, testing ~= nil)
    compileTimes.changesComputeTime = sys:Now() - changesComputeStart
    if contentMapperHost ~= nil then
        compileTimes.contentMapperTimes = contentMapperHost:Timings()
    end
    local result = tsc.EmitAndReportStatistics({
        sys = sys,
        programLike = incrementalProgram,
        program = incrementalProgram:GetProgram(),
        config = config,
        reportDiagnostic = reportDiagnostic,
        reportErrorSummary = reportErrorSummary,
        writer = sys:Writer(),
        compileTimes = compileTimes,
        testing = testing,
        tracing = tr,
    })

    execute.stopTracing(sys, tr)

    if testing ~= nil then
        testing:OnProgram(incrementalProgram)
    end
    if contentMapperProject ~= nil then
        contentMapperProject:Close()
    end
    return tsc.NewCommandLineResult(result.status)
end

function execute.performCompilation(ctx, sys, config, reportDiagnostic, reportErrorSummary, extendedConfigCache, compileTimes, testing)
    local contentMapperHost = tsc.NewContentMapperHost(ctx, sys, config:CompilerOptions())
    local contentMapperProject = execute.getContentMapperProject(contentMapperHost, config)
    local host = compiler.NewCachedFSCompilerHost(sys:GetCurrentDirectory(), sys:FS(), sys:DefaultLibraryPath(), extendedConfigCache, execute.getTraceFromSys(sys, config:Locale(), testing), contentMapperProject)

    local tr = execute.startTracingIfNeeded(sys, config, testing)

    local parseStart = sys:Now()
    local program = compiler.NewProgram(compiler.NewProgramOptions({
        config = config,
        host = host,
        tracing = tr,
    }))
    compileTimes.parseTime = sys:Now() - parseStart
    local result = tsc.EmitAndReportStatistics({
        sys = sys,
        programLike = program,
        program = program,
        config = config,
        reportDiagnostic = reportDiagnostic,
        reportErrorSummary = reportErrorSummary,
        writer = sys:Writer(),
        compileTimes = compileTimes,
        testing = testing,
        tracing = tr,
    })

    execute.stopTracing(sys, tr)

    if contentMapperProject ~= nil then
        contentMapperProject:Close()
    end
    return tsc.NewCommandLineResult(result.status)
end

function execute.getContentMapperProject(host, config)
    if host == nil or core.Len(config:ContentMappers()) == 0 then
        return nil
    end
    error("not implemented: getContentMapperProject (content mappers)")
end

function execute.showConfig(sys, config, configFileName)
    local tsConfig = tsoptions.ConvertToTSConfig(config, configFileName)
    json.MarshalIndentWrite(sys:Writer(), tsConfig, "", "    ")
end
