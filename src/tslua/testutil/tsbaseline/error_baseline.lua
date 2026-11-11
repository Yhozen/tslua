local tsbaseline = require("tslua.testutil.tsbaseline")
local ast = require("tslua.ast")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local diagnosticwriter = require("tslua.diagnosticwriter")
local testutil = require("tslua.testutil")
local tspath = require("tslua.tspath")

-- IO
local harnessNewLine = "\r\n"
tsbaseline.harnessNewLine = harnessNewLine

tsbaseline.formatOpts = {
    newLine = harnessNewLine,
    currentDirectory = "",
    useCaseSensitiveFileNames = false,
}

local function lowerAt(s, i, lit)
    return string.lower(string.sub(s, i, i + #lit - 1)) == lit
end

-- Matches `\d+` at position i (1-based); returns the position after the digits or nil.
local function digitsAt(s, i)
    local _, e = string.find(s, "^%d+", i)
    if e == nil then
        return nil
    end
    return e + 1
end

-- diagnosticsLocationPrefix = regexp.MustCompile(`(?im)^(lib.*\.d\.ts)\(\d+,\d+\)`)
tsbaseline.diagnosticsLocationPrefix = {
    -- Returns the end (exclusive, 1-based) of group 1 and of the whole match for a match starting
    -- at line start i, or nil.
    matchAt = function(s, i, lineEnd)
        if not lowerAt(s, i, "lib") then
            return nil
        end
        -- greedy `.*`: try the rightmost ".d.ts" first
        local k = lineEnd - 5
        while k >= i + 3 do
            if lowerAt(s, k, ".d.ts") and string.sub(s, k + 5, k + 5) == "(" then
                local p = digitsAt(s, k + 6)
                if p ~= nil and string.sub(s, p, p) == "," then
                    local q = digitsAt(s, p + 1)
                    if q ~= nil and string.sub(s, q, q) == ")" then
                        return k + 5, q + 1
                    end
                end
            end
            k = k - 1
        end
        return nil
    end,
    -- repl is "$1(--,--)"
    ReplaceAllString = function(self, s, repl)
        local out = {}
        local pos = 1
        local n = #s
        local lineStart = 1
        while lineStart <= n do
            local nl = string.find(s, "\n", lineStart, true)
            local lineEnd = nl or (n + 1)
            local g1End, mEnd = self.matchAt(s, lineStart, lineEnd)
            if g1End ~= nil then
                out[#out + 1] = string.sub(s, pos, g1End - 1)
                out[#out + 1] = string.sub(repl, 3)
                pos = mEnd
            end
            if nl == nil then
                break
            end
            lineStart = nl + 1
        end
        out[#out + 1] = string.sub(s, pos)
        return table.concat(out)
    end,
}

-- diagnosticsLocationPattern = regexp.MustCompile(`(?i)(lib.*\.d\.ts):\d+:\d+`)
tsbaseline.diagnosticsLocationPattern = {
    -- repl is "$1:--:--"
    ReplaceAllString = function(self, s, repl)
        local out = {}
        local pos = 1
        local i = 1
        local n = #s
        while i <= n - 2 do
            local matched = false
            if lowerAt(s, i, "lib") then
                local nl = string.find(s, "\n", i, true)
                local lineEnd = nl or (n + 1)
                local k = lineEnd - 5
                while k >= i + 3 do
                    if lowerAt(s, k, ".d.ts") and string.sub(s, k + 5, k + 5) == ":" then
                        local p = digitsAt(s, k + 6)
                        if p ~= nil and string.sub(s, p, p) == ":" then
                            local q = digitsAt(s, p + 1)
                            if q ~= nil then
                                out[#out + 1] = string.sub(s, pos, k + 4)
                                out[#out + 1] = string.sub(repl, 3)
                                pos = q
                                i = q
                                matched = true
                                break
                            end
                        end
                    end
                    k = k - 1
                end
            end
            if not matched then
                i = i + 1
            end
        end
        out[#out + 1] = string.sub(s, pos)
        return table.concat(out)
    end,
}

function tsbaseline.DoErrorBaseline(t, baselinePath, inputFiles, errors, pretty, opts)
    baselinePath = tsbaseline.tsExtension:ReplaceAllString(baselinePath, ".errors.txt")
    local errorBaseline
    if core.Len(errors) > 0 then
        errorBaseline = tsbaseline.GetErrorBaseline(t, inputFiles, diagnosticwriter.WrapASTDiagnostics(errors), diagnosticwriter.CompareASTDiagnostics, pretty)
    else
        errorBaseline = baseline.NoContent
    end
    baseline.Run(t, baselinePath, errorBaseline, opts)
    if core.Some(errors or {}, function(d)
        return d:Code() == -1
    end) then
        t:Fatalf("Found diagnostic with code -1, which is used to log critical assertion violations in the baseline. Inspect and fix those failures.")
    end
end

function tsbaseline.minimalDiagnosticsToString(diags, pretty)
    local output = core.NewStringBuilder()
    if pretty then
        diagnosticwriter.FormatDiagnosticsWithColorAndContext(output, diags, tsbaseline.formatOpts)
    else
        diagnosticwriter.WriteFormatDiagnostics(output, diags, tsbaseline.formatOpts)
    end
    return output:String()
end

function tsbaseline.GetErrorBaseline(t, inputFiles, diags, compareDiagnostics, pretty)
    t:Helper()
    local outputLines = tsbaseline.iterateErrorBaseline(t, inputFiles, diags, compareDiagnostics, pretty)

    if pretty then
        local summaryBuilder = core.NewStringBuilder()
        diagnosticwriter.WriteErrorSummaryText(
            summaryBuilder,
            diagnosticwriter.ToDiagnostics(diags),
            tsbaseline.formatOpts
        )
        local summary = tsbaseline.removeTestPathPrefixes(summaryBuilder:String(), false)
        outputLines[#outputLines + 1] = summary
    end
    return table.concat(outputLines, "")
end

-- slices.SortFunc is not stable; table.sort is not either. Sort with an index tiebreak so equal
-- diagnostics keep their relative order deterministically.
local function sortFunc(xs, cmp)
    local indexed = {}
    for i, x in ipairs(xs) do
        indexed[i] = { x = x, i = i }
    end
    table.sort(indexed, function(a, b)
        local c = cmp(a.x, b.x)
        if c ~= 0 then
            return c < 0
        end
        return a.i < b.i
    end)
    for i, e in ipairs(indexed) do
        xs[i] = e.x
    end
end

function tsbaseline.iterateErrorBaseline(t, inputFiles, inputDiagnostics, compareDiagnostics, pretty)
    t:Helper()
    local diags = {}
    for i, d in ipairs(inputDiagnostics or {}) do
        diags[i] = d
    end
    sortFunc(diags, compareDiagnostics)

    local outputLines = core.NewStringBuilder()
    -- Count up all errors that were found in files other than lib.d.ts so we don't miss any
    local totalErrorsReportedInNonLibraryNonTsconfigFiles = 0
    local errorsReported = 0

    local firstLine = true

    local function newLine()
        if firstLine then
            firstLine = false
            return ""
        end
        return "\r\n"
    end

    local result = {}

    local function outputErrorText(diag)
        local message = diagnosticwriter.FlattenDiagnosticMessage(diag, harnessNewLine, nil --[[locale.Default]])

        local errLines = {}
        for line in string.gmatch(tsbaseline.removeTestPathPrefixes(message, false) .. "\n", "([^\n]*)\n") do
            if string.sub(line, -1) == "\r" then
                line = string.sub(line, 1, -2)
            end
            if #line == 0 then
                goto continue
            end
            do
                local out = "!!! " .. diagnostics.Category_Name(diag:Category()) .. " TS" .. tostring(diag:Code()) .. ": " .. line
                errLines[#errLines + 1] = out
            end
            ::continue::
        end

        for _, info in ipairs(diag:RelatedInformation() or {}) do
            local location = ""
            if info:File() ~= nil then
                location = " " .. tsbaseline.formatLocation(info:File(), info:Pos(), tsbaseline.formatOpts, function(output, text, formatStyle)
                    output:WriteString(text)
                end)
            end
            location = tsbaseline.removeTestPathPrefixes(location, false)
            if #location > 0 and tsbaseline.isDefaultLibraryFile(info:File():FileName()) then
                location = tsbaseline.diagnosticsLocationPattern:ReplaceAllString(location, "$1:--:--")
            end
            errLines[#errLines + 1] = "!!! related TS" .. tostring(info:Code()) .. location .. ": " .. diagnosticwriter.FlattenDiagnosticMessage(info, harnessNewLine, nil --[[locale.Default]])
        end

        for _, e in ipairs(errLines) do
            outputLines:WriteString(newLine())
            outputLines:WriteString(e)
        end

        errorsReported = errorsReported + 1

        -- do not count errors from lib.d.ts here, they are computed separately as numLibraryDiagnostics
        -- if lib.d.ts is explicitly included in input files and there are some errors in it (i.e. because of duplicate identifiers)
        -- then they will be added twice thus triggering 'total errors' assertion with condition
        -- Similarly for tsconfig, which may be in the input files and contain errors.
        -- 'totalErrorsReportedInNonLibraryNonTsconfigFiles + numLibraryDiagnostics + numTsconfigDiagnostics, diagnostics.length

        if diag:File() == nil or not tsbaseline.isDefaultLibraryFile(diag:File():FileName()) and not tsbaseline.isTsConfigFile(diag:File():FileName()) then
            totalErrorsReportedInNonLibraryNonTsconfigFiles = totalErrorsReportedInNonLibraryNonTsconfigFiles + 1
        end
    end

    local topDiagnostics = tsbaseline.minimalDiagnosticsToString(diagnosticwriter.ToDiagnostics(diags), pretty)
    topDiagnostics = tsbaseline.removeTestPathPrefixes(topDiagnostics, false)
    topDiagnostics = tsbaseline.diagnosticsLocationPrefix:ReplaceAllString(topDiagnostics, "$1(--,--)")

    result[#result + 1] = topDiagnostics .. harnessNewLine .. harnessNewLine

    -- Report global errors
    for _, err in ipairs(diags) do
        if err:File() == nil then
            outputErrorText(err)
        end
    end

    result[#result + 1] = outputLines:String()
    outputLines:Reset()
    errorsReported = 0

    -- 'merge' the lines of each input file with any errors associated with it
    local dupeCase = {}
    for _, inputFile in ipairs(inputFiles or {}) do
        -- Filter down to the errors in the file
        local fileErrors = core.Filter(diags, function(e)
            return e:File() ~= nil and
                tspath.ComparePaths(tsbaseline.removeTestPathPrefixes(e:File():FileName(), false), tsbaseline.removeTestPathPrefixes(inputFile.unitName, false), {}) == 0
        end)

        -- Header
        outputLines:WriteString(newLine() .. "==== " .. tsbaseline.removeTestPathPrefixes(inputFile.unitName, false) .. " (" .. tostring(#fileErrors) .. " errors) ====")

        -- Make sure we emit something for every error
        local markedErrorCount = 0
        -- For each line, emit the line followed by any error squiggles matching this line

        local lineStarts = core.ComputeECMALineStarts(inputFile.content)
        local lines = tsbaseline.lineDelimiter:Split(inputFile.content, -1)

        for lineIndex1, line in ipairs(lines) do
            local lineIndex = lineIndex1 - 1
            if #line > 0 and string.byte(line, #line) == 13 then
                line = string.sub(line, 1, -2)
            end

            local thisLineStart = lineStarts[lineIndex + 1]
            local nextLineStart
            -- On the last line of the file, fake the next line start number so that we handle errors on the last character of the file correctly
            if lineIndex == #lines - 1 then
                nextLineStart = #inputFile.content
            else
                nextLineStart = lineStarts[lineIndex + 2]
            end
            -- Emit this line from the original file
            outputLines:WriteString(newLine())
            outputLines:WriteString("    ")
            outputLines:WriteString(line)
            for _, errDiagnostic in ipairs(fileErrors) do
                -- Does any error start or continue on to this line? Emit squiggles
                local errStart = errDiagnostic:Pos()
                local end_ = errStart + errDiagnostic:Len()
                if end_ >= thisLineStart and (errStart < nextLineStart or lineIndex == #lines - 1) then
                    -- How many characters from the start of this line the error starts at (could be positive or negative)
                    local relativeOffset = errStart - thisLineStart
                    -- How many characters of the error are on this line (might be longer than this line in reality)
                    local length = (end_ - errStart) - math.max(0, thisLineStart - errStart)
                    -- Calculate the start of the squiggle
                    local squiggleStart = math.max(0, relativeOffset)
                    -- TODO/REVIEW: this doesn't work quite right in the browser if a multi file test has files whose names are just the right length relative to one another
                    outputLines:WriteString(newLine())
                    outputLines:WriteString("    ")
                    outputLines:WriteString(tsbaseline.nonWhitespace:ReplaceAllString(string.sub(line, 1, squiggleStart), " "))
                    -- This was `new Array(count).join("~")`; which maps 0 to "", 1 to "", 2 to "~", 3 to "~~", etc.
                    local squiggleEnd = math.max(squiggleStart, math.min(squiggleStart + length, #line))
                    outputLines:WriteString(string.rep("~", core.RuneCount(string.sub(line, squiggleStart + 1, squiggleEnd))))
                    -- If the error ended here, or we're at the end of the file, emit its message
                    if lineIndex == #lines - 1 or nextLineStart > end_ then
                        outputErrorText(errDiagnostic)
                        markedErrorCount = markedErrorCount + 1
                    end
                end
            end
        end

        -- Verify we didn't miss any errors in this file
        testutil.CheckEqual(t, markedErrorCount, #fileErrors, "%s", "count of errors in " .. inputFile.unitName)
        local isDupe = dupeCase[tsbaseline.sanitizeTestFilePath(inputFile.unitName)] ~= nil
        result[#result + 1] = outputLines:String()
        if isDupe then
            -- Case-duplicated files on a case-insensitive build will have errors reported in both the dupe and the original
            -- thanks to the canse-insensitive path comparison on the error file path - We only want to count those errors once
            -- for the assert below, so we subtract them here.
            totalErrorsReportedInNonLibraryNonTsconfigFiles = totalErrorsReportedInNonLibraryNonTsconfigFiles - errorsReported
        end
        outputLines:Reset()
        errorsReported = 0
    end

    local numLibraryDiagnostics = core.CountWhere(
        diags,
        function(d)
            return d:File() ~= nil and (tsbaseline.isDefaultLibraryFile(d:File():FileName()) or tsbaseline.isBuiltFile(d:File():FileName()))
        end
    )
    local numTsconfigDiagnostics = core.CountWhere(
        diags,
        function(d)
            return d:File() ~= nil and tsbaseline.isTsConfigFile(d:File():FileName())
        end
    )
    local contentMapperSupplementalFileNames = {}
    for _, diagnostic in ipairs(diags) do
        local file = diagnostic:File()
        if file ~= nil and file.kind == ast.Kind.SourceFile and file.IsContentMapperSupplemental ~= nil and file:IsContentMapperSupplemental() then
            contentMapperSupplementalFileNames[file:FileName()] = true
        end
    end
    local numContentMapperSupplementalDiagnostics = core.CountWhere(
        diags,
        function(d)
            if d:File() == nil then
                return false
            end
            return contentMapperSupplementalFileNames[d:File():FileName()] ~= nil
        end
    )
    -- Verify we didn't miss any errors in total
    testutil.CheckEqual(t, totalErrorsReportedInNonLibraryNonTsconfigFiles + numLibraryDiagnostics + numTsconfigDiagnostics + numContentMapperSupplementalDiagnostics, #diags, "total number of errors")

    return result
end

function tsbaseline.formatLocation(file, pos, formatOpts, writeWithStyleAndReset)
    local output = core.NewStringBuilder()
    diagnosticwriter.WriteLocation(output, file, pos, formatOpts, writeWithStyleAndReset)
    return output:String()
end

return tsbaseline
