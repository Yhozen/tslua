local tsc = require("tslua.execute.tsc")
local core = require("tslua.core")

-- System interface (a table with methods):
--   Writer() -> io.Writer, ErrorWriter() -> io.Writer, FS() -> vfs.FS, DefaultLibraryPath(),
--   GetCurrentDirectory(), WriteOutputIsTTY(), GetWidthOfTerminal(), GetEnvironmentVariable(name),
--   Spawn(command, dir, stderr), Now() -> seconds (float), SinceStart() -> seconds (float).
-- io.Writer: a table with WriteString(s) (and Write(s), used by tslua.json).
-- time.Duration values are float seconds.

function tsc.newContentMapperLogger(sys)
    if sys:GetEnvironmentVariable("TS_CONTENT_MAPPER_DEBUG") == "" then
        return nil
    end
    local writer = sys:ErrorWriter()
    return function(message)
        writer:WriteString(message .. "\n")
    end
end

tsc.ExitStatus = {
    Success = 0,
    DiagnosticsPresent_OutputsSkipped = 1,
    DiagnosticsPresent_OutputsGenerated = 2,
    InvalidProject_OutputsSkipped = 3,
    ProjectReferenceCycle_OutputsSkipped = 4,
    NotImplemented = 5,
}
tsc.ExitStatus_names = {}
for k, v in pairs(tsc.ExitStatus) do
    tsc.ExitStatus_names[v] = k
end

-- Watcher interface: DoCycle()

-- CommandLineResult: { status = ExitStatus, watcher = Watcher }
function tsc.NewCommandLineResult(status, watcher)
    return { status = status or tsc.ExitStatus.Success, watcher = watcher }
end

-- CommandLineTesting interface: OnEmittedFiles(result, mTimesCache), OnListFilesStart(w), OnListFilesEnd(w),
-- OnStatisticsStart(w), OnStatisticsEnd(w), OnBuildStatusReportStart(w), OnBuildStatusReportEnd(w),
-- OnWatchStatusReportStart(), OnWatchStatusReportEnd(), GetTrace(w, locale), OnProgram(program).

-- NewContentMapperHost creates a content mapper host when content mappers are enabled via the
-- --runExternalCode flag. It returns nil otherwise, in which case no content-mapped files can be loaded.
function tsc.NewContentMapperHost(ctx, sys, options)
    if not core.Tristate_IsTrue(options.runExternalCode) then
        return nil
    end
    error("not implemented: NewContentMapperHost (content mappers / --runExternalCode)")
end

-- CompileTimes: durations in seconds.
function tsc.NewCompileTimes()
    return {
        configTime = 0,
        parseTime = 0,
        contentMapperTimes = { requestWait = 0, mappers = {} },
        bindTime = 0,
        checkTime = 0,
        totalTime = 0,
        emitTime = 0,
        buildInfoReadTime = 0,
        changesComputeTime = 0,
    }
end

-- CompileAndEmitResult: { diagnostics, emitResult, status, times }
function tsc.newCompileAndEmitResult()
    return {
        diagnostics = nil,
        emitResult = nil,
        status = tsc.ExitStatus.Success,
        times = nil,
    }
end
