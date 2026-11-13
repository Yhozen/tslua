local tsc = require("tslua.execute.tsc")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local incremental = require("tslua.execute.incremental")
local tracing = require("tslua.tracing")
local tspath = require("tslua.tspath")

function tsc.GetTraceWithWriterFromSys(w, locale, testing)
    if testing == nil then
        return function(msg, ...)
            w:WriteString(msg:Localize(locale, ...) .. "\n")
        end
    else
        return testing:GetTrace(w, locale)
    end
end

-- EmitInput: { sys, programLike, program, config, reportDiagnostic, reportErrorSummary, writer, writeFile,
--   compileTimes, testing, testingMTimesCache, tracing }

-- Returns (CompileAndEmitResult, *Statistics).
function tsc.EmitAndReportStatistics(input)
    local statistics = nil
    local result = tsc.EmitFilesAndReportErrors(input)
    if result.status ~= tsc.ExitStatus.Success then
        -- compile exited early
        return result, nil
    end
    result.times.totalTime = input.sys:SinceStart()

    if core.Tristate_IsTrue(input.config:CompilerOptions().diagnostics) or core.Tristate_IsTrue(input.config:CompilerOptions().extendedDiagnostics) then
        -- GC must be called twice to allow things to settle.
        collectgarbage("collect")
        collectgarbage("collect")
        local memStats = { alloc = math.floor(collectgarbage("count") * 1024), mallocs = 0 }

        statistics = tsc.statisticsFromProgram(input, memStats)
        statistics:Report(input.writer, input.testing)
    end

    if result.emitResult.emitSkipped and #result.diagnostics > 0 then
        result.status = tsc.ExitStatus.DiagnosticsPresent_OutputsSkipped
    elseif #result.diagnostics > 0 then
        result.status = tsc.ExitStatus.DiagnosticsPresent_OutputsGenerated
    end
    return result, statistics
end

function tsc.EmitFilesAndReportErrors(input)
    local result = tsc.newCompileAndEmitResult()
    result.times = input.compileTimes
    local ctx = nil

    local allDiagnostics = compiler.GetDiagnosticsOfAnyProgram(
        ctx,
        input.programLike,
        nil,
        false,
        function(c, file)
            -- Options diagnostics include global diagnostics (even though we collect them separately),
            -- and global diagnostics create checkers, which then bind all of the files. Do this binding
            -- early so we can track the time.
            local pop = nil
            local tr = input.tracing
            if tr ~= nil then
                -- Go: deferred until return
                pop = tr:Push(tracing.PhaseBind, "bindSourceFiles", nil, true)
            end
            local bindStart = input.sys:Now()
            local diags = input.programLike:GetBindDiagnostics(c, file)
            result.times.bindTime = input.sys:Now() - bindStart
            if pop ~= nil then
                pop()
            end
            return diags
        end,
        function(c, file)
            local pop = nil
            local tr = input.tracing
            if tr ~= nil then
                -- Go: deferred until return
                pop = tr:Push(tracing.PhaseCheck, "checkSourceFiles", nil, true)
            end
            local checkStart = input.sys:Now()
            local diags = input.programLike:GetSemanticDiagnostics(c, file)
            result.times.checkTime = input.sys:Now() - checkStart
            if getmetatable(input.programLike) == incremental.Program then
                local nestedEmitTime = input.programLike:TakeNestedEmitTime()
                if nestedEmitTime > result.times.checkTime then
                    result.times.checkTime = 0
                else
                    result.times.checkTime = result.times.checkTime - nestedEmitTime
                end
                result.times.emitTime = result.times.emitTime + nestedEmitTime
            end
            if pop ~= nil then
                pop()
            end
            return diags
        end
    )

    local emitResult = compiler.newEmitResult({ emitSkipped = true, diagnostics = {} })
    if not core.Tristate_IsTrue(input.programLike:Options().listFilesOnly) then
        local emitStart = input.sys:Now()
        emitResult = input.programLike:Emit(ctx, compiler.NewEmitOptions({
            writeFile = input.writeFile,
        }))
        result.times.emitTime = result.times.emitTime + (input.sys:Now() - emitStart)
    end
    if emitResult ~= nil then
        allDiagnostics = core.AppendAll(allDiagnostics, emitResult.diagnostics)
    end
    if input.testing ~= nil then
        input.testing:OnEmittedFiles(emitResult, input.testingMTimesCache)
    end

    allDiagnostics = compiler.SortAndDeduplicateDiagnostics(allDiagnostics)
    for _, diagnostic in ipairs(allDiagnostics) do
        input.reportDiagnostic(diagnostic)
    end

    tsc.listFiles(input, emitResult)

    input.reportErrorSummary(allDiagnostics)
    result.diagnostics = allDiagnostics
    result.emitResult = emitResult
    result.status = tsc.ExitStatus.Success
    return result
end

function tsc.listFiles(input, emitResult)
    if input.testing ~= nil then
        input.testing:OnListFilesStart(input.writer)
    end
    local options = input.program:Options()
    if core.Tristate_IsTrue(options.listEmittedFiles) then
        for _, file in ipairs(emitResult.emittedFiles or {}) do
            input.writer:WriteString("TSFILE: " .. tspath.GetNormalizedAbsolutePath(file, input.program:GetCurrentDirectory()) .. "\n")
        end
    end
    if core.Tristate_IsTrue(options.explainFiles) then
        input.program:ExplainFiles(input.writer, input.config:Locale())
    elseif core.Tristate_IsTrue(options.listFiles) or core.Tristate_IsTrue(options.listFilesOnly) then
        for _, file in ipairs(input.program:GetSourceFiles()) do
            input.writer:WriteString(file:FileName() .. "\n")
        end
    end
    if input.testing ~= nil then
        input.testing:OnListFilesEnd(input.writer)
    end
end
