local tsbaseline = require("tslua.testutil.tsbaseline")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local diagnosticwriter = require("tslua.diagnosticwriter")

-- ansiEscape = regexp.MustCompile("\x1b\\[[0-9;]*m")
local function removeAnsiEscapes(s)
    return (string.gsub(s, "\27%[[0-9;]*m", ""))
end

tsbaseline.contentMapperFormatOpts = { newLine = "\n", currentDirectory = "", useCaseSensitiveFileNames = false }

-- DoContentMapperBaseline writes a baseline for content-mapped files that shows the original source, the
-- transformed source the compiler actually checks, and the file's diagnostics. Diagnostics are rendered
-- with the standard diagnostic writer, which maps each one to the text it belongs to: mapper-produced
-- diagnostics render against the original source, compiler diagnostics on mappable code render against the
-- original source, and compiler diagnostics on synthesized code render against the transformed source. If
-- the program has no content-mapped files, no baseline is written.
function tsbaseline.DoContentMapperBaseline(t, baselinePath, program, diags, opts)
    local content = tsbaseline.getContentMapperBaseline(program, diags)
    if content == "" then
        return
    end
    baseline.Run(t, tsbaseline.tsExtension:ReplaceAllString(baselinePath, ".contentmapper"), content, opts)
end

-- Go fmt %v of a []string: "[a b c]".
local function formatStringSlice(xs)
    return "[" .. table.concat(xs or {}, " ") .. "]"
end

function tsbaseline.getContentMapperBaseline(program, diags)
    local prog = program:Program()
    local mapped = {}
    local files = {}
    for _, file in ipairs(program:GetSourceFiles()) do
        local mapper = prog:GetContentMapper(file)
        if mapper ~= nil then
            mapped[file:FileName()] = mapper
            files[#files + 1] = file
        end
    end
    if #files == 0 then
        return ""
    end

    local b = core.NewStringBuilder()
    for _, file in ipairs(files) do
        local mapper = mapped[file:FileName()]
        b:WriteString("//// [" .. tsbaseline.removeTestPathPrefixes(file:FileName(), false) .. "] (ScriptKind: " .. core.ScriptKind_String(file.scriptKind) .. ", ContentMapper: " .. formatStringSlice(mapper.definition.extensions) .. ")\n")
        b:WriteString("--- Original ---\n")
        b:WriteString(tsbaseline.ensureTrailingNewline(file:OriginalText()))
        b:WriteString("--- Transformed ---\n")
        b:WriteString(tsbaseline.ensureTrailingNewline(file:Text()))
        b:WriteString("\n")
    end

    local fileDiagnostics = {}
    for _, d in ipairs(diags or {}) do
        if d:File() ~= nil and mapped[d:File():FileName()] ~= nil then
            fileDiagnostics[#fileDiagnostics + 1] = d
        end
    end

    b:WriteString("=== Diagnostics ===\n\n")
    if #fileDiagnostics == 0 then
        b:WriteString(baseline.NoContent .. "\n")
        return b:String()
    end
    local rendered = core.NewStringBuilder()
    diagnosticwriter.FormatDiagnosticsWithColorAndContext(
        rendered,
        diagnosticwriter.ToDiagnostics(diagnosticwriter.WrapASTDiagnostics(fileDiagnostics)),
        tsbaseline.contentMapperFormatOpts
    )
    b:WriteString(tsbaseline.removeTestPathPrefixes(removeAnsiEscapes(rendered:String()), false))
    return b:String()
end

function tsbaseline.ensureTrailingNewline(s)
    if s == "" or string.sub(s, -1) == "\n" then
        return s
    end
    return s .. "\n"
end

return tsbaseline
