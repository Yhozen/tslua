local diagnosticwriter = require("tslua.diagnosticwriter")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

-- Go io.Writer -> any object with a WriteString(s) method (e.g. core.StringBuilder).
-- Go locale.Locale -> any value passed through to diagnostics Localize (nil is the default locale).

-- FileLike interface: FileName(), Text(), ECMALineMap().

-- Diagnostic interface abstracts over ast.Diagnostic and LSP diagnostics:
--   File() -> FileLike, Pos(), End(), Len(), Code(), Category(),
--   Source() -- a custom prefix shown before the code instead of "TS" (empty means "TS"). A non-empty
--               value marks the diagnostic as coming from an external source (e.g. a content mapper).
--   Localize(locale) -> string, MessageChain() -> []Diagnostic, RelatedInformation() -> []Diagnostic

-- ASTDiagnostic wraps ast.Diagnostic to implement the Diagnostic interface. The embedded
-- *ast.Diagnostic is the `diagnostic` field; its other methods are promoted through __index.
local ASTDiagnostic = {}
diagnosticwriter.ASTDiagnostic = ASTDiagnostic
ASTDiagnostic.__index = function(self, key)
    local m = ASTDiagnostic[key]
    if m ~= nil then
        return m
    end
    local inner = rawget(self, "diagnostic")
    local v = inner[key]
    if type(v) == "function" then
        return function(_, ...)
            return v(inner, ...)
        end
    end
    return v
end

function ASTDiagnostic:RelatedInformation()
    local related = self.diagnostic:RelatedInformation()
    local result = {}
    for i, r in ipairs(related or {}) do
        result[i] = diagnosticwriter.WrapASTDiagnostic(r)
    end
    return result
end

function ASTDiagnostic:File()
    local file = self.diagnostic:File()
    if file == nil then
        return nil
    end
    if self:resolve().useOriginal then
        -- The mapper's own diagnostics (Source != "") already carry original ranges; compiler
        -- diagnostics have their transformed ranges mapped back. Both render against the original,
        -- untransformed text. Diagnostics in synthesized code (see resolve) keep the virtual text.
        return diagnosticwriter.newOriginalTextFile(file)
    end
    return file
end

function ASTDiagnostic:Source()
    return self.diagnostic:Source()
end

function ASTDiagnostic:Pos() return self:resolve().loc:Pos() end
function ASTDiagnostic:End() return self:resolve().loc:End() end
function ASTDiagnostic:Len() return self:resolve().loc:Len() end

-- resolvedLocation describes how a diagnostic on a content-mapped file should be reported:
-- { loc = core.TextRange, useOriginal = bool, synthesized = bool }
--   useOriginal -- render against the file's original, untransformed text
--   synthesized -- the range is in virtual code with no corresponding original location

-- spanmap.FidelityNone (the spanmap package is not ported; content mappers are out of scope).
local spanmapFidelityNone = 0

-- resolve determines where and against which text a diagnostic should be reported. A content mapper's
-- own diagnostics already carry original ranges. A compiler diagnostic on a content-mapped file has its
-- virtual range mapped back to the original; if it falls entirely within synthesized code, there is no
-- original location, so it is shown against the virtual text and flagged as synthesized.
function ASTDiagnostic:resolve()
    local d = self.diagnostic
    local loc = d:Loc()
    local file = d:File()
    if file == nil then
        return { loc = loc, useOriginal = false, synthesized = false }
    elseif d:Source() ~= "" then
        return { loc = loc, useOriginal = true, synthesized = false }
    elseif file.SpanMap ~= nil and file:SpanMap() ~= nil then
        local mapped, fidelity = file:SpanMap():VirtualToOriginalSpan(loc)
        if fidelity == spanmapFidelityNone then
            return { loc = loc, useOriginal = false, synthesized = true }
        end
        return { loc = mapped, useOriginal = true, synthesized = false }
    end
    return { loc = loc, useOriginal = false, synthesized = false }
end

-- originalTextFile presents a source file's original (untransformed) text as a FileLike, so that
-- diagnostics whose ranges point into that text render at the correct locations.
local originalTextFile = {}
originalTextFile.__index = originalTextFile
diagnosticwriter.originalTextFile = originalTextFile

function diagnosticwriter.newOriginalTextFile(file)
    local text = file:OriginalText()
    return setmetatable({
        fileName = file:FileName(),
        text = text,
        lineMap = core.ComputeECMALineStarts(text),
    }, originalTextFile)
end

function originalTextFile:FileName() return self.fileName end
function originalTextFile:Text() return self.text end
function originalTextFile:ECMALineMap() return self.lineMap end

function ASTDiagnostic:MessageChain()
    local chain = self.diagnostic:MessageChain()
    local result = {}
    for _, c in ipairs(chain or {}) do
        result[#result + 1] = diagnosticwriter.WrapASTDiagnostic(c)
    end
    if self:resolve().synthesized then
        -- The diagnostic points into synthesized virtual code; make clear the shown location is not in the
        -- original file, and which content mapper produced it.
        local note = ast.NewCompilerDiagnostic(
            diagnostics.This_location_is_in_virtual_code_produced_by_the_content_mapper_0_and_has_no_corresponding_location_in_the_original_file,
            self.diagnostic:File():ContentMapper()
        )
        result[#result + 1] = diagnosticwriter.WrapASTDiagnostic(note)
    end
    return result
end

function diagnosticwriter.WrapASTDiagnostic(d)
    return setmetatable({ diagnostic = d }, ASTDiagnostic)
end

function diagnosticwriter.WrapASTDiagnostics(diags)
    local result = {}
    for i, d in ipairs(diags or {}) do
        result[i] = diagnosticwriter.WrapASTDiagnostic(d)
    end
    return result
end

function diagnosticwriter.FromASTDiagnostics(diags)
    local result = {}
    for i, d in ipairs(diags or {}) do
        result[i] = diagnosticwriter.WrapASTDiagnostic(d)
    end
    return result
end

function diagnosticwriter.ToDiagnostics(diags)
    local result = {}
    for i, d in ipairs(diags or {}) do
        result[i] = d
    end
    return result
end

function diagnosticwriter.CompareASTDiagnostics(a, b)
    return ast.CompareDiagnostics(a.diagnostic, b.diagnostic)
end

-- FormattingOptions: { locale = locale.Locale, currentDirectory = "", useCaseSensitiveFileNames = bool,
-- newLine = "" } (the embedded tspath.ComparePathsOptions fields are flattened).

local foregroundColorEscapeGrey = "\27[90m"
local foregroundColorEscapeRed = "\27[91m"
local foregroundColorEscapeYellow = "\27[93m"
local foregroundColorEscapeBlue = "\27[94m"
local foregroundColorEscapeCyan = "\27[96m"

local gutterStyleSequence = "\27[7m"
local gutterSeparator = " "
local resetEscapeSequence = "\27[0m"
local ellipsis = "..."

-- fmt "%*s" / "%*d": right-aligned in a field of the given width.
local function padLeft(s, width)
    s = tostring(s)
    if #s >= width then
        return s
    end
    return string.rep(" ", width - #s) .. s
end

-- unicode.IsSpace
local unicodeSpaces = {
    [0x85] = true, [0xA0] = true, [0x1680] = true, [0x2028] = true, [0x2029] = true,
    [0x202F] = true, [0x205F] = true, [0x3000] = true,
}
local function isSpaceRune(r)
    return r == 32 or (r >= 9 and r <= 13) or unicodeSpaces[r] == true or (r >= 0x2000 and r <= 0x200A)
end

-- strings.TrimRightFunc(s, unicode.IsSpace)
local function trimRightSpace(s)
    local end_ = #s
    while end_ > 0 do
        local r, size = core.DecodeLastRune(s, end_)
        if not isSpaceRune(r) then
            break
        end
        end_ = end_ - size
    end
    return string.sub(s, 1, end_)
end

function diagnosticwriter.FormatDiagnosticsWithColorAndContext(output, diags, formatOpts)
    if core.Len(diags) == 0 then
        return
    end
    for i, diagnostic in ipairs(diags) do
        if i > 1 then
            output:WriteString(formatOpts.newLine)
        end
        diagnosticwriter.FormatDiagnosticWithColorAndContext(output, diagnostic, formatOpts)
    end
end

function diagnosticwriter.FormatDiagnosticWithColorAndContext(output, diagnostic, formatOpts)
    if diagnostic:File() ~= nil then
        local file = diagnostic:File()
        local pos = diagnostic:Pos()
        diagnosticwriter.WriteLocation(output, file, pos, formatOpts, diagnosticwriter.writeWithStyleAndReset)
        output:WriteString(" - ")
    end

    diagnosticwriter.writeWithStyleAndReset(output, diagnostics.Category_Name(diagnostic:Category()), diagnosticwriter.getCategoryFormat(diagnostic:Category()))
    output:WriteString(foregroundColorEscapeGrey .. " " .. diagnosticwriter.diagnosticPrefix(diagnostic) .. tostring(diagnostic:Code()) .. ": " .. resetEscapeSequence)
    diagnosticwriter.WriteFlattenedDiagnosticMessage(output, diagnostic, formatOpts.newLine, formatOpts.locale)

    if diagnostic:File() ~= nil and diagnostic:Code() ~= diagnostics.File_appears_to_be_binary:Code() then
        output:WriteString(formatOpts.newLine)
        diagnosticwriter.writeCodeSnippet(output, diagnostic:File(), diagnostic:Pos(), diagnostic:Len(), diagnosticwriter.getCategoryFormat(diagnostic:Category()), "", formatOpts)
        output:WriteString(formatOpts.newLine)
    end

    local relatedInformation = diagnostic:RelatedInformation()
    if relatedInformation ~= nil and #relatedInformation > 0 then
        for _, info in ipairs(relatedInformation) do
            local file = info:File()
            if file ~= nil then
                output:WriteString(formatOpts.newLine)
                output:WriteString("  ")
                local pos = info:Pos()
                diagnosticwriter.WriteLocation(output, file, pos, formatOpts, diagnosticwriter.writeWithStyleAndReset)
                output:WriteString(" - ")
                diagnosticwriter.WriteFlattenedDiagnosticMessage(output, info, formatOpts.newLine, formatOpts.locale)
                diagnosticwriter.writeCodeSnippet(output, file, pos, info:Len(), foregroundColorEscapeCyan, "    ", formatOpts)
            end
            output:WriteString(formatOpts.newLine)
        end
    end
end

function diagnosticwriter.writeCodeSnippet(writer, sourceFile, start, length, squiggleColor, indent, formatOpts)
    local firstLine, firstLineChar = scanner.GetECMALineAndUTF16CharacterOfPosition(sourceFile, start)
    local lastLine, lastLineChar = scanner.GetECMALineAndUTF16CharacterOfPosition(sourceFile, start + length)
    if length == 0 then
        lastLineChar = lastLineChar + 1 -- When length is zero, squiggle the character right after the start position.
    end

    local text = sourceFile:Text()
    local lastLineOfFile = scanner.GetECMALineOfPosition(sourceFile, #text)

    local hasMoreThanFiveLines = lastLine - firstLine >= 4
    local gutterWidth = #tostring(lastLine + 1)
    if hasMoreThanFiveLines then
        gutterWidth = math.max(#ellipsis, gutterWidth)
    end

    local i = firstLine
    while i <= lastLine do
        writer:WriteString(formatOpts.newLine)

        -- If the error spans over 5 lines, we'll only show the first 2 and last 2 lines,
        -- so we'll skip ahead to the second-to-last line.
        if hasMoreThanFiveLines and firstLine + 1 < i and i < lastLine - 1 then
            writer:WriteString(indent)
            writer:WriteString(gutterStyleSequence)
            writer:WriteString(padLeft(ellipsis, gutterWidth))
            writer:WriteString(resetEscapeSequence)
            writer:WriteString(gutterSeparator)
            writer:WriteString(formatOpts.newLine)
            i = lastLine - 1
        end

        local lineStart = scanner.GetECMAPositionOfLineAndByteOffset(sourceFile, i, 0)
        local lineEnd
        if i < lastLineOfFile then
            lineEnd = scanner.GetECMAPositionOfLineAndByteOffset(sourceFile, i + 1, 0)
        else
            lineEnd = #text
        end

        local lineContent = trimRightSpace(string.sub(text, lineStart + 1, lineEnd)) -- trim from end
        lineContent = string.gsub(lineContent, "\t", " ")                            -- convert tabs to single spaces

        -- Output the gutter and the actual contents of the line.
        writer:WriteString(indent)
        writer:WriteString(gutterStyleSequence)
        writer:WriteString(padLeft(i + 1, gutterWidth))
        writer:WriteString(resetEscapeSequence)
        writer:WriteString(gutterSeparator)
        writer:WriteString(lineContent)
        writer:WriteString(formatOpts.newLine)

        -- Output the gutter and the error span for the line using tildes.
        writer:WriteString(indent)
        writer:WriteString(gutterStyleSequence)
        writer:WriteString(padLeft("", gutterWidth))
        writer:WriteString(resetEscapeSequence)
        writer:WriteString(gutterSeparator)
        writer:WriteString(squiggleColor)
        if i == firstLine then
            -- If we're on the last line, then limit it to the last character of the last line.
            -- Otherwise, we'll just squiggle the rest of the line, giving 'slice' no end position.
            local lastCharForLine
            if i == lastLine then
                lastCharForLine = lastLineChar
            else
                lastCharForLine = core.UTF16Len(lineContent)
            end

            -- Fill with spaces until the first character,
            -- then squiggle the remainder of the line.
            writer:WriteString(string.rep(" ", firstLineChar))
            writer:WriteString(string.rep("~", lastCharForLine - firstLineChar))
        elseif i == lastLine then
            -- Squiggle until the final character.
            writer:WriteString(string.rep("~", lastLineChar))
        else
            -- Squiggle the entire line.
            writer:WriteString(string.rep("~", core.UTF16Len(lineContent)))
        end

        writer:WriteString(resetEscapeSequence)
        i = i + 1
    end
end

function diagnosticwriter.FlattenDiagnosticMessage(d, newLine, locale)
    local output = core.NewStringBuilder()
    diagnosticwriter.WriteFlattenedDiagnosticMessage(output, d, newLine, locale)
    return output:String()
end

function diagnosticwriter.WriteFlattenedASTDiagnosticMessage(writer, diagnostic, newline, locale)
    diagnosticwriter.WriteFlattenedDiagnosticMessage(writer, diagnosticwriter.WrapASTDiagnostic(diagnostic), newline, locale)
end

function diagnosticwriter.WriteFlattenedDiagnosticMessage(writer, diagnostic, newline, locale)
    writer:WriteString(diagnostic:Localize(locale))

    for _, chain in ipairs(diagnostic:MessageChain() or {}) do
        diagnosticwriter.flattenDiagnosticMessageChain(writer, chain, newline, locale, 1 --[[level]])
    end
end

function diagnosticwriter.flattenDiagnosticMessageChain(writer, chain, newLine, locale, level)
    writer:WriteString(newLine)
    for _ = 1, level do
        writer:WriteString("  ")
    end

    writer:WriteString(chain:Localize(locale))
    for _, child in ipairs(chain:MessageChain() or {}) do
        diagnosticwriter.flattenDiagnosticMessageChain(writer, child, newLine, locale, level + 1)
    end
end

-- diagnosticPrefix returns the prefix shown before a diagnostic's code, e.g. "TS" for compiler
-- diagnostics or a content mapper's custom source for its diagnostics.
function diagnosticwriter.diagnosticPrefix(diagnostic)
    local source = diagnostic:Source()
    if source ~= "" then
        return source
    end
    return "TS"
end

function diagnosticwriter.getCategoryFormat(category)
    if category == diagnostics.Category.Error then
        return foregroundColorEscapeRed
    elseif category == diagnostics.Category.Warning then
        return foregroundColorEscapeYellow
    elseif category == diagnostics.Category.Suggestion then
        return foregroundColorEscapeGrey
    elseif category == diagnostics.Category.Message then
        return foregroundColorEscapeBlue
    end
    error("Unhandled diagnostic category", 0)
end

-- FormattedWriter is func(output io.Writer, text string, formatStyle string).

function diagnosticwriter.writeWithStyleAndReset(output, text, formatStyle)
    output:WriteString(formatStyle)
    output:WriteString(text)
    output:WriteString(resetEscapeSequence)
end

function diagnosticwriter.WriteLocation(output, file, pos, formatOpts, writeWithStyleAndReset)
    local firstLine, firstChar = scanner.GetECMALineAndUTF16CharacterOfPosition(file, pos)
    local relativeFileName
    if formatOpts ~= nil then
        relativeFileName = tspath.ConvertToRelativePath(file:FileName(), formatOpts)
    else
        relativeFileName = file:FileName()
    end

    writeWithStyleAndReset(output, relativeFileName, foregroundColorEscapeCyan)
    output:WriteString(":")
    writeWithStyleAndReset(output, tostring(firstLine + 1), foregroundColorEscapeYellow)
    output:WriteString(":")
    writeWithStyleAndReset(output, tostring(firstChar + 1), foregroundColorEscapeYellow)
end

-- Some of these lived in watch.ts, but they're not specific to the watch API.

-- ErrorSummary: { totalErrorCount, globalErrors, errorsByFile (FileLike -> []Diagnostic), sortedFiles }

function diagnosticwriter.WriteErrorSummaryText(output, allDiagnostics, formatOpts)
    -- Roughly corresponds to 'getErrorSummaryText' from watch.ts

    local errorSummary = diagnosticwriter.getErrorSummary(allDiagnostics)
    local totalErrorCount = errorSummary.totalErrorCount
    if totalErrorCount == 0 then
        return
    end

    local firstFile = nil
    if #errorSummary.sortedFiles > 0 then
        firstFile = errorSummary.sortedFiles[1]
    end
    local firstFileErrors = nil
    if firstFile ~= nil and errorSummary.errorsByFile ~= nil then
        firstFileErrors = errorSummary.errorsByFile[firstFile]
    end
    local firstFileName = diagnosticwriter.prettyPathForFileError(firstFile, firstFileErrors, formatOpts)
    local numErroringFiles = 0
    for _ in pairs(errorSummary.errorsByFile or {}) do
        numErroringFiles = numErroringFiles + 1
    end

    local message
    if totalErrorCount == 1 then
        -- Special-case a single error.
        if #errorSummary.globalErrors > 0 or firstFileName == "" then
            message = diagnostics.Found_1_error:Localize(formatOpts.locale)
        else
            message = diagnostics.Found_1_error_in_0:Localize(formatOpts.locale, firstFileName)
        end
    else
        if numErroringFiles == 0 then
            -- No file-specific errors.
            message = diagnostics.Found_0_errors:Localize(formatOpts.locale, totalErrorCount)
        elseif numErroringFiles == 1 then
            -- One file with errors.
            message = diagnostics.Found_0_errors_in_the_same_file_starting_at_Colon_1:Localize(formatOpts.locale, totalErrorCount, firstFileName)
        else
            -- Multiple files with errors.
            message = diagnostics.Found_0_errors_in_1_files:Localize(formatOpts.locale, totalErrorCount, numErroringFiles)
        end
    end
    output:WriteString(formatOpts.newLine)
    output:WriteString(message)
    output:WriteString(formatOpts.newLine)
    output:WriteString(formatOpts.newLine)
    if numErroringFiles > 1 then
        diagnosticwriter.writeTabularErrorsDisplay(output, errorSummary, formatOpts)
        output:WriteString(formatOpts.newLine)
    end
end

function diagnosticwriter.getErrorSummary(diags)
    local totalErrorCount = 0
    local globalErrors = {}
    local errorsByFile = nil

    for _, diagnostic in ipairs(diags or {}) do
        if diagnostic:Category() ~= diagnostics.Category.Error then
            goto continue
        end

        totalErrorCount = totalErrorCount + 1
        do
            local file = diagnostic:File()
            if file == nil then
                globalErrors[#globalErrors + 1] = diagnostic
            else
                if errorsByFile == nil then
                    errorsByFile = {}
                end
                local list = errorsByFile[file]
                if list == nil then
                    list = {}
                    errorsByFile[file] = list
                end
                list[#list + 1] = diagnostic
            end
        end
        ::continue::
    end

    -- !!!
    -- Need an ordered map here, but sorting for consistency.
    local sortedFiles = {}
    for file in pairs(errorsByFile or {}) do
        sortedFiles[#sortedFiles + 1] = file
    end
    -- (stable with respect to the first error, since Go's map order is random anyway)
    table.sort(sortedFiles, function(a, b)
        return a:FileName() < b:FileName()
    end)

    return {
        totalErrorCount = totalErrorCount,
        globalErrors = globalErrors,
        errorsByFile = errorsByFile,
        sortedFiles = sortedFiles,
    }
end

function diagnosticwriter.writeTabularErrorsDisplay(output, errorSummary, formatOpts)
    local sortedFiles = errorSummary.sortedFiles

    local maxErrors = 0
    for _, errorsForFile in pairs(errorSummary.errorsByFile or {}) do
        maxErrors = math.max(maxErrors, #errorsForFile)
    end

    -- !!!
    -- TODO (drosen): This was never localized.
    -- Should make this better.
    local headerRow = diagnostics.Errors_Files:Localize(formatOpts.locale)
    local leftColumnHeadingLength = #(string.match(headerRow, "^[^ ]*"))
    local lengthOfBiggestErrorCount = #tostring(maxErrors)
    local leftPaddingGoal = math.max(leftColumnHeadingLength, lengthOfBiggestErrorCount)
    local headerPadding = math.max(lengthOfBiggestErrorCount - leftColumnHeadingLength, 0)

    output:WriteString(string.rep(" ", headerPadding))
    output:WriteString(headerRow)
    output:WriteString(formatOpts.newLine)

    for _, file in ipairs(sortedFiles) do
        local fileErrors = errorSummary.errorsByFile[file]
        local errorCount = #fileErrors

        output:WriteString(padLeft(errorCount, leftPaddingGoal) .. "  ")
        output:WriteString(diagnosticwriter.prettyPathForFileError(file, fileErrors, formatOpts))
        output:WriteString(formatOpts.newLine)
    end
end

function diagnosticwriter.prettyPathForFileError(file, fileErrors, formatOpts)
    if file == nil or core.Len(fileErrors) == 0 then
        return ""
    end
    local line = scanner.GetECMALineOfPosition(file, fileErrors[1]:Pos())
    local fileName = file:FileName()
    if tspath.PathIsAbsolute(fileName) and tspath.PathIsAbsolute(formatOpts.currentDirectory or "") then
        fileName = tspath.ConvertToRelativePath(file:FileName(), formatOpts)
    end
    return fileName .. foregroundColorEscapeGrey .. ":" .. tostring(line + 1) .. resetEscapeSequence
end

function diagnosticwriter.WriteFormatDiagnostics(output, diags, formatOpts)
    for _, diagnostic in ipairs(diags or {}) do
        diagnosticwriter.WriteFormatDiagnostic(output, diagnostic, formatOpts)
    end
end

function diagnosticwriter.WriteFormatDiagnostic(output, diagnostic, formatOpts)
    if diagnostic:File() ~= nil then
        local line, character = scanner.GetECMALineAndUTF16CharacterOfPosition(diagnostic:File(), diagnostic:Pos())
        local fileName = diagnostic:File():FileName()
        local relativeFileName = tspath.ConvertToRelativePath(fileName, formatOpts)
        output:WriteString(relativeFileName .. "(" .. tostring(line + 1) .. "," .. tostring(character + 1) .. "): ")
    end

    output:WriteString(diagnostics.Category_Name(diagnostic:Category()) .. " " .. diagnosticwriter.diagnosticPrefix(diagnostic) .. tostring(diagnostic:Code()) .. ": ")
    diagnosticwriter.WriteFlattenedDiagnosticMessage(output, diagnostic, formatOpts.newLine, formatOpts.locale)
    output:WriteString(formatOpts.newLine)
end

function diagnosticwriter.FormatDiagnosticsStatusWithColorAndTime(output, time, diag, formatOpts)
    output:WriteString("[")
    diagnosticwriter.writeWithStyleAndReset(output, time, foregroundColorEscapeGrey)
    output:WriteString("] ")
    diagnosticwriter.WriteFlattenedDiagnosticMessage(output, diag, formatOpts.newLine, formatOpts.locale)
end

function diagnosticwriter.FormatDiagnosticsStatusAndTime(output, time, diag, formatOpts)
    output:WriteString(time .. " - ")
    diagnosticwriter.WriteFlattenedDiagnosticMessage(output, diag, formatOpts.newLine, formatOpts.locale)
end

diagnosticwriter.ScreenStartingCodes = {
    diagnostics.Starting_compilation_in_watch_mode:Code(),
    diagnostics.File_change_detected_Starting_incremental_compilation:Code(),
}

function diagnosticwriter.TryClearScreen(output, diag, options)
    if not core.Tristate_IsTrue(options.preserveWatchOutput) and
        not core.Tristate_IsTrue(options.extendedDiagnostics) and
        not core.Tristate_IsTrue(options.diagnostics) then
        local code = diag:Code()
        for _, c in ipairs(diagnosticwriter.ScreenStartingCodes) do
            if c == code then
                output:WriteString("\27[2J\27[3J\27[H") -- Clear screen and move cursor to home position
                return true
            end
        end
    end
    return false
end

return diagnosticwriter
