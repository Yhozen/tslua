local tsc = require("tslua.execute.tsc")
local core = require("tslua.core")
local diagnosticwriter = require("tslua.diagnosticwriter")

function tsc.getFormatOptsOfSys(sys, locale)
    return {
        newLine = "\n",
        comparePathsOptions = {
            currentDirectory = sys:GetCurrentDirectory(),
            useCaseSensitiveFileNames = sys:FS():UseCaseSensitiveFileNames(),
        },
        locale = locale,
    }
end

-- DiagnosticReporter = func(*ast.Diagnostic)

function tsc.QuietDiagnosticReporter(diagnostic) end

function tsc.CreateDiagnosticReporter(sys, w, locale, options)
    if core.Tristate_IsTrue(options.quiet) then
        return tsc.QuietDiagnosticReporter
    end
    local formatOpts = tsc.getFormatOptsOfSys(sys, locale)
    if tsc.shouldBePretty(sys, options) then
        return function(diagnostic)
            diagnosticwriter.FormatDiagnosticWithColorAndContext(w, diagnosticwriter.WrapASTDiagnostic(diagnostic), formatOpts)
            w:WriteString(formatOpts.newLine)
        end
    end
    return function(diagnostic)
        diagnosticwriter.WriteFormatDiagnostic(w, diagnosticwriter.WrapASTDiagnostic(diagnostic), formatOpts)
    end
end

function tsc.defaultIsPretty(sys)
    if sys:GetEnvironmentVariable("NO_COLOR") ~= "" then
        return false
    end
    if sys:GetEnvironmentVariable("FORCE_COLOR") ~= "" then
        return true
    end
    return sys:WriteOutputIsTTY()
end

function tsc.shouldBePretty(sys, options)
    if options == nil or core.Tristate_IsUnknown(options.pretty) then
        return tsc.defaultIsPretty(sys)
    end
    return core.Tristate_IsTrue(options.pretty)
end

local colors = {}
colors.__index = colors
tsc.colors = colors

function tsc.createColors(sys)
    if not tsc.defaultIsPretty(sys) then
        return setmetatable({ showColors = false, isWindows = false, isWindowsTerminal = false, isVSCode = false, supportsRicherColors = false }, colors)
    end

    local os_ = sys:GetEnvironmentVariable("OS")
    local isWindows = string.find(string.lower(os_), "windows", 1, true) ~= nil
    local isWindowsTerminal = sys:GetEnvironmentVariable("WT_SESSION") ~= ""
    local isVSCode = sys:GetEnvironmentVariable("TERM_PROGRAM") == "vscode"
    local supportsRicherColors = sys:GetEnvironmentVariable("COLORTERM") == "truecolor" or sys:GetEnvironmentVariable("TERM") == "xterm-256color"

    return setmetatable({
        showColors = true,
        isWindows = isWindows,
        isWindowsTerminal = isWindowsTerminal,
        isVSCode = isVSCode,
        supportsRicherColors = supportsRicherColors,
    }, colors)
end

function colors:bold(str)
    if not self.showColors then
        return str
    end
    return "\27[1m" .. str .. "\27[22m"
end

function colors:blue(str)
    if not self.showColors then
        return str
    end

    -- Effectively Powershell and Command prompt users use cyan instead
    -- of blue because the default theme doesn't show blue with enough contrast.
    if self.isWindows and not self.isWindowsTerminal and not self.isVSCode then
        return self:brightWhite(str)
    end
    return "\27[94m" .. str .. "\27[39m"
end

function colors:blueBackground(str)
    if not self.showColors then
        return str
    end
    if self.supportsRicherColors then
        return "\27[48;5;68m" .. str .. "\27[39;49m"
    else
        return "\27[44m" .. str .. "\27[39;49m"
    end
end

function colors:brightWhite(str)
    if not self.showColors then
        return str
    end
    return "\27[97m" .. str .. "\27[39m"
end

-- DiagnosticsReporter = func(diagnostics []*ast.Diagnostic)

function tsc.QuietDiagnosticsReporter(diags) end

function tsc.CreateReportErrorSummary(sys, locale, options)
    if tsc.shouldBePretty(sys, options) then
        local formatOpts = tsc.getFormatOptsOfSys(sys, locale)
        return function(diags)
            diagnosticwriter.WriteErrorSummaryText(sys:Writer(), diagnosticwriter.FromASTDiagnostics(diags), formatOpts)
        end
    end
    return tsc.QuietDiagnosticsReporter
end

-- Go time.Format("03:04:05 PM") of a time given in seconds since the epoch.
local function formatClock(t)
    return os.date("%I:%M:%S %p", math.floor(t))
end
tsc.formatClock = formatClock

function tsc.CreateBuilderStatusReporter(sys, w, locale, options, testing)
    if core.Tristate_IsTrue(options.quiet) then
        return tsc.QuietDiagnosticReporter
    end

    local formatOpts = tsc.getFormatOptsOfSys(sys, locale)
    local writeStatus
    if tsc.shouldBePretty(sys, options) then
        writeStatus = diagnosticwriter.FormatDiagnosticsStatusWithColorAndTime
    else
        writeStatus = diagnosticwriter.FormatDiagnosticsStatusAndTime
    end
    return function(diagnostic)
        local writerDiagnostic = diagnosticwriter.WrapASTDiagnostic(diagnostic)
        if testing ~= nil then
            testing:OnBuildStatusReportStart(w)
        end
        writeStatus(w, formatClock(sys:Now()), writerDiagnostic, formatOpts)
        w:WriteString(formatOpts.newLine .. formatOpts.newLine)
        if testing ~= nil then
            testing:OnBuildStatusReportEnd(w)
        end
    end
end

function tsc.CreateWatchStatusReporter(sys, locale, options, testing)
    local formatOpts = tsc.getFormatOptsOfSys(sys, locale)
    local writeStatus
    if tsc.shouldBePretty(sys, options) then
        writeStatus = diagnosticwriter.FormatDiagnosticsStatusWithColorAndTime
    else
        writeStatus = diagnosticwriter.FormatDiagnosticsStatusAndTime
    end
    return function(diagnostic)
        local writerDiagnostic = diagnosticwriter.WrapASTDiagnostic(diagnostic)
        local writer = sys:Writer()
        if testing ~= nil then
            testing:OnWatchStatusReportStart()
        end
        diagnosticwriter.TryClearScreen(writer, writerDiagnostic, options)
        writeStatus(writer, formatClock(sys:Now()), writerDiagnostic, formatOpts)
        writer:WriteString(formatOpts.newLine .. formatOpts.newLine)
        if testing ~= nil then
            testing:OnWatchStatusReportEnd()
        end
    end
end
