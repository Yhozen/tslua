local lsconv = require("tslua.ls.lsconv")
local bundled = require("tslua.bundled")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local diagnosticwriter = require("tslua.diagnosticwriter")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")
local strings = require("tslua.module").strings

local Fidelity = spanmap.Fidelity

-- Converters: { getLineMap = func(fileName) *LSPLineMap, positionEncoding = lsproto.PositionEncodingKind }
local Converters = {}
Converters.__index = Converters
lsconv.Converters = Converters

-- MappedSpan[T] is { script, span, fidelity } (spanmap.MappedSpan embedded);
-- MappedPosition[T] is { script, position, fidelity } (spanmap.MappedPosition embedded).
local function newMappedSpan(script, mapped)
    return { script = script, span = mapped.span, fidelity = mapped.fidelity }
end

local function newMappedPosition(script, mapped)
    return { script = script, position = mapped.position, fidelity = mapped.fidelity }
end

-- Script is a source text the converters operate over. For a content-mapped file, Text() is the content
-- mapper's virtual output and SpanMap() returns the map from that output back to the original text
-- (OriginalText()); virtual ranges are then automatically converted to original coordinates (see
-- ToLSPRange). For an ordinary file SpanMap() is nil and OriginalText() equals Text().
-- Interface: FileName(), OriginalFileName(), Text(), SpanMap(), OriginalText().

function lsconv.NewConverters(positionEncoding, getLineMap)
    return setmetatable({
        getLineMap = getLineMap,
        positionEncoding = positionEncoding,
    }, Converters)
end

local function newRange(start, end_)
    return { start = start, end_ = end_ }
end

-- ToLSPRange converts a range in a SourceFile (or a script read from the file system after declaration
-- mapping) to an lsproto.Range. If the file is a content-mapped virtual SourceFile, the range is mapped
-- through the file's span map and the fidelity of that mapping is returned. For normal files, the second
-- return value is FidelityExact.
function Converters:ToLSPRange(script, textRange)
    local fidelity
    script, textRange, fidelity = lsconv.virtualRangeToOriginal(script, textRange, nil)
    return newRange(
        self:positionToLineAndCharacter(script, textRange:Pos()),
        self:positionToLineAndCharacter(script, textRange:End())
    ), fidelity
end

-- ToLSPRangeForFeature is [Converters.ToLSPRange] for an LS feature. For a content-mapped file, it returns
-- FidelityNone unless the entire virtual range is covered by contiguous segments that participate in
-- feature; the returned range is still the best-effort mapped range. For normal files, it behaves like
-- [Converters.ToLSPRange].
function Converters:ToLSPRangeForFeature(script, textRange, feature)
    local fidelity
    script, textRange, fidelity = lsconv.virtualRangeToOriginal(script, textRange, feature)
    return newRange(
        self:positionToLineAndCharacter(script, textRange:Pos()),
        self:positionToLineAndCharacter(script, textRange:End())
    ), fidelity
end

-- ToLSPPosition converts a position in a SourceFile (or a script read from the file system after
-- declaration mapping) to an lsproto.Position. Positions in content-mapped files are mapped through
-- the file's span map; positions in normal files return FidelityExact.
function Converters:ToLSPPosition(script, position)
    local fidelity
    script, position, fidelity = lsconv.virtualPositionToOriginal(script, position, nil)
    return self:positionToLineAndCharacter(script, position), fidelity
end

-- ToLSPPositionForFeature is [Converters.ToLSPPosition] for an LS feature. For a content-mapped file, it returns
-- FidelityNone when the virtual position is not in a segment that participates in feature; the
-- returned position is still the best-effort mapped position. For normal files, it behaves like
-- [Converters.ToLSPPosition].
function Converters:ToLSPPositionForFeature(script, position, feature)
    local fidelity
    script, position, fidelity = lsconv.virtualPositionToOriginal(script, position, feature)
    return self:positionToLineAndCharacter(script, position), fidelity
end

-- ToLSPLocation converts a range in a SourceFile or script to an lsproto.Location. If the file is a content-mapped
-- virtual SourceFile, the range is mapped through the file's span map and the fidelity of that mapping is returned.
-- For normal files, the second return value is FidelityExact. If the file is a supplemental output of a content mapper,
-- the file's original file name is used for the URI (e.g. App.astro.0.ts -> App.astro).
function Converters:ToLSPLocation(script, rng)
    local lspRange, fidelity = self:ToLSPRange(script, rng)
    return {
        uri = lsconv.FileNameToDocumentURI(script:OriginalFileName()),
        range = lspRange,
    }, fidelity
end

-- ToLSPLocationForFeature is [Converters.ToLSPLocation] for an LS feature. For a content-mapped file, it returns
-- FidelityNone when the virtual position is not in a segment that participates in feature; the
-- returned position is still the best-effort mapped position. For normal files, it behaves like
-- [Converters.ToLSPLocation].
function Converters:ToLSPLocationForFeature(script, rng, feature)
    local lspRange, fidelity = self:ToLSPRangeForFeature(script, rng, feature)
    return { uri = lsconv.FileNameToDocumentURI(script:OriginalFileName()), range = lspRange }, fidelity
end

-- FromLSPRange converts an lsproto.Range to offsets in one Script. For a content-mapped script, results
-- include each virtual projection covered by segments that participate in feature; it returns no
-- results when no projection qualifies. Normal scripts return one exact span.
function lsconv.FromLSPRange(c, script, textRange, feature)
    return lsconv.lspRangeToVirtual(c, { script }, textRange, feature)
end

-- FromLSPRangeForSourceFile converts an lsproto.Range to offsets in a SourceFile. When the file has
-- supplemental content-mapper outputs, results include every qualifying virtual projection across the
-- canonical and supplemental files. Projections not participating in feature are omitted.
function lsconv.FromLSPRangeForSourceFile(c, file, textRange, feature)
    local files = lsconv.sourceFileProjections(file)
    return lsconv.lspRangeToVirtual(c, files, textRange, feature)
end

-- FromLSPRangeIntersectingForSourceFile projects every feature-enabled intersection with textRange
-- across the canonical and supplemental virtual files. Unlike FromLSPRangeForSourceFile, the original
-- range endpoints need not be mapped. This is intended for read-only range requests such as semantic
-- tokens and inlay hints, where an editor commonly asks for a viewport spanning host markup:
--
--	original: <template>...</template><script>const x = 1</script><style>...</style>
--	          [---------------- requested viewport ---------------------------------)
--	                                          [----------) mapped script
--
-- The result contains the script intersection even though both viewport endpoints are outside it.
function lsconv.FromLSPRangeIntersectingForSourceFile(c, file, textRange, feature)
    local files = lsconv.sourceFileProjections(file)
    local result = {}
    for _, script in ipairs(files) do
        local spans = script:SpanMap()
        if spans == nil then
            result[#result + 1] = {
                script = script,
                span = core.NewTextRange(
                    c:lineAndCharacterToPosition(script, textRange.start),
                    c:lineAndCharacterToPosition(script, textRange.end_)
                ),
                fidelity = Fidelity.Exact,
            }
            goto continue
        end
        do
            local original = lsconv.newOriginalTextScript(script:OriginalFileName(), script:OriginalText())
            local originalRange = core.NewTextRange(
                c:lineAndCharacterToPosition(original, textRange.start),
                c:lineAndCharacterToPosition(original, textRange.end_)
            )
            for _, mapped in ipairs(spans:OriginalToVirtualIntersectingSpans(originalRange, feature) or {}) do
                result[#result + 1] = newMappedSpan(script, mapped)
            end
        end
        ::continue::
    end
    return result
end

function lsconv.lspRangeToVirtual(c, scripts, textRange, feature)
    local result = {}
    for _, script in ipairs(scripts) do
        for _, mapped in ipairs(c:lspRangeToVirtual(script, textRange, feature) or {}) do
            result[#result + 1] = newMappedSpan(script, mapped)
        end
    end
    return result
end

function Converters:lspRangeToVirtual(script, textRange, feature)
    local spans = script:SpanMap()
    if spans == nil then
        return { {
            span = core.NewTextRange(
                self:lineAndCharacterToPosition(script, textRange.start),
                self:lineAndCharacterToPosition(script, textRange.end_)
            ),
            fidelity = Fidelity.Exact,
        } }
    end
    -- A content-mapped script's line map is its original text's, so convert against that text and then map
    -- the resulting original range forward into the virtual text.
    local original = lsconv.newOriginalTextScript(script:OriginalFileName(), script:OriginalText())
    local origRange = core.NewTextRange(
        self:lineAndCharacterToPosition(original, textRange.start),
        self:lineAndCharacterToPosition(original, textRange.end_)
    )
    return spans:OriginalToVirtualSpans(origRange, feature)
end

-- FromLSPPosition converts an lsproto.Position to offsets in one Script. For a content-mapped script,
-- results include each virtual projection whose segment participates in feature; it returns no results
-- when no projection qualifies. Normal scripts return one exact position.
function lsconv.FromLSPPosition(c, script, position, feature)
    return lsconv.lspPositionToVirtual(c, { script }, position, feature)
end

-- FromLSPPositionForSourceFile converts an lsproto.Position to offsets in a SourceFile. When the file has
-- supplemental content-mapper outputs, results include every qualifying virtual projection across the
-- canonical and supplemental files. Projections not participating in feature are omitted.
function lsconv.FromLSPPositionForSourceFile(c, file, position, feature)
    local files = lsconv.sourceFileProjections(file)
    return lsconv.lspPositionToVirtual(c, files, position, feature)
end

function lsconv.sourceFileProjections(file)
    local supplemental = file:SupplementalSourceFiles()
    local files = { file }
    for _, f in ipairs(supplemental or {}) do
        files[#files + 1] = f
    end
    return files
end

function lsconv.lspPositionToVirtual(c, scripts, position, feature)
    local result = {}
    for _, script in ipairs(scripts) do
        for _, mapped in ipairs(c:lspPositionToVirtual(script, position, feature) or {}) do
            result[#result + 1] = newMappedPosition(script, mapped)
        end
    end
    return result
end

function Converters:lspPositionToVirtual(script, position, feature)
    local spans = script:SpanMap()
    if spans == nil then
        return { { position = self:lineAndCharacterToPosition(script, position), fidelity = Fidelity.Exact } }
    end
    local original = lsconv.newOriginalTextScript(script:OriginalFileName(), script:OriginalText())
    local origOffset = self:lineAndCharacterToPosition(original, position)
    return spans:OriginalToVirtualPositions(origOffset, feature)
end

-- virtualRangeToOriginal maps a content mapper's virtual range back to its original text.
-- A nil feature bypasses feature filtering for diagnostics and edits.
-- Returns (Script, core.TextRange, spanmap.Fidelity).
function lsconv.virtualRangeToOriginal(script, textRange, feature)
    if script:SpanMap() == nil then
        return script, textRange, Fidelity.Exact
    end
    local mapped, fidelity
    if feature == nil then
        mapped, fidelity = script:SpanMap():VirtualToOriginalSpan(textRange)
    else
        mapped, fidelity = script:SpanMap():VirtualToOriginalSpanForFeature(textRange, feature)
    end
    return lsconv.newOriginalTextScript(script:OriginalFileName(), script:OriginalText()), mapped, fidelity
end

-- virtualPositionToOriginal is the single-position analog of virtualRangeToOriginal.
function lsconv.virtualPositionToOriginal(script, position, feature)
    if script:SpanMap() == nil then
        return script, position, Fidelity.Exact
    end
    local mapped, fidelity
    if feature == nil then
        mapped, fidelity = script:SpanMap():VirtualToOriginalPosition(position)
    else
        mapped, fidelity = script:SpanMap():VirtualToOriginalPositionForFeature(position, feature)
    end
    return lsconv.newOriginalTextScript(script:OriginalFileName(), script:OriginalText()), mapped, fidelity
end

function lsconv.LanguageKindToScriptKind(languageID)
    if languageID == "typescript" then
        return core.ScriptKind.TS
    elseif languageID == "typescriptreact" then
        return core.ScriptKind.TSX
    elseif languageID == "javascript" then
        return core.ScriptKind.JS
    elseif languageID == "javascriptreact" then
        return core.ScriptKind.JSX
    elseif languageID == "json" then
        return core.ScriptKind.JSON
    else
        return core.ScriptKind.Unknown
    end
end

-- https://github.com/microsoft/vscode-uri/blob/edfdccd976efaf4bb8fdeca87e97c47257721729/src/uri.ts#L455
lsconv.extraEscapeReplacements = {
    [":"] = "%3A",
    ["/"] = "%2F",
    ["?"] = "%3F",
    ["#"] = "%23",
    ["["] = "%5B",
    ["]"] = "%5D",
    ["@"] = "%40",

    ["!"] = "%21",
    ["$"] = "%24",
    ["&"] = "%26",
    ["'"] = "%27",
    ["("] = "%28",
    [")"] = "%29",
    ["*"] = "%2A",
    ["+"] = "%2B",
    [","] = "%2C",
    [";"] = "%3B",
    ["="] = "%3D",

    [" "] = "%20",
}

-- Go extraEscapeReplacer.Replace (a strings.Replacer of single-byte keys).
function lsconv.extraEscapeReplace(s)
    return (string.gsub(s, "[:/%?#%[%]@!%$&'%(%)%*%+,;= ]", lsconv.extraEscapeReplacements))
end

-- Go url.PathEscape (encodePathSegment mode).
function lsconv.urlPathEscape(s)
    return (string.gsub(s, "[^%w%-_%.~%$&%+:=@]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function lsconv.FileNameToDocumentURI(fileName)
    if bundled.IsBundled(fileName) then
        return fileName
    end
    if tspath.IsDynamicFileName(fileName) then
        local scheme, rest, ok = strings.Cut(string.sub(fileName, 3), "/")
        if not ok then
            error("invalid file name: " .. fileName, 0)
        end
        local authority, path
        authority, path, ok = strings.Cut(rest, "/")
        if not ok then
            error("invalid file name: " .. fileName, 0)
        end
        if authority == "ts-nul-authority" then
            return scheme .. ":" .. path
        end
        return scheme .. "://" .. authority .. "/" .. path
    end

    local volume
    volume, fileName = tspath.SplitVolumePath(fileName)
    if volume ~= "" then
        volume = "/" .. lsconv.extraEscapeReplace(volume)
    end

    fileName = strings.TrimPrefix(fileName, "//")

    local parts = strings.Split(fileName, "/")
    for i, part in ipairs(parts) do
        parts[i] = lsconv.extraEscapeReplace(lsconv.urlPathEscape(part))
    end

    return "file://" .. volume .. table.concat(parts, "/")
end

-- Go utf16.RuneLen.
local function utf16RuneLen(r)
    if r >= 0 and r < 0xD800 or r > 0xDFFF and r < 0x10000 then
        return 1
    elseif r >= 0x10000 and r <= 0x10FFFF then
        return 2
    end
    return -1
end

function Converters:lineAndCharacterToPosition(script, lineAndCharacter)
    -- UTF-8/16 0-indexed line and character to UTF-8 offset
    debug.Assert(script:SpanMap() == nil, "raw coordinate conversion requires a non-content-mapped script")

    local lineMap = self.getLineMap(script:FileName())

    local line = lineAndCharacter.line
    local char = lineAndCharacter.character

    local textLen = #script:Text()

    -- Clamp line to valid range.
    if line >= #lineMap.lineStarts then
        return textLen
    end

    local start = lineMap.lineStarts[line + 1]

    -- Determine the end of this line (start of next line, or end of text).
    local lineEnd
    if line + 1 < #lineMap.lineStarts then
        lineEnd = lineMap.lineStarts[line + 2]
    else
        lineEnd = textLen
    end

    if lineMap.asciiOnly or self.positionEncoding == lsproto.PositionEncodingKind.UTF8 then
        return math.max(start, math.min(start + char, lineEnd))
    end

    -- Scan from line start counting UTF-16 code units to find the byte position.
    -- Uses DecodeRuneInString (not range + RuneLen) so that invalid UTF-8 bytes
    -- advance by their actual size (1) rather than RuneLen(RuneError) == 3.
    -- This matches the approach in scanner.ComputePositionOfLineAndUTF16Character.
    local utf16Char = 0
    local pos = start
    local end_ = lineEnd
    local text = script:Text()
    while pos < end_ do
        local r, size = core.DecodeRune(text, pos)
        local u16Len = utf16RuneLen(r)
        if utf16Char + u16Len > char then
            break
        end
        utf16Char = utf16Char + u16Len
        pos = pos + size
    end

    return pos
end

function Converters:positionToLineAndCharacter(script, position)
    -- UTF-8 offset to UTF-8/16 0-indexed line and character
    debug.Assert(script:SpanMap() == nil, "raw coordinate conversion requires a non-content-mapped script")

    position = math.max(0, math.min(position, #script:Text()))

    local lineMap = self.getLineMap(script:FileName())

    local line, isLineStart = lsconv.binarySearchInts(lineMap.lineStarts, position)
    if not isLineStart then
        line = line - 1
    end
    line = math.max(0, math.min(line, #lineMap.lineStarts - 1))

    -- The current line ranges from lineMap.LineStarts[line] (or 0) to lineMap.LineStarts[line+1] (or len(text)).

    local start = lineMap.lineStarts[line + 1]

    local character = 0
    if lineMap.asciiOnly or self.positionEncoding == lsproto.PositionEncodingKind.UTF8 then
        character = position - start
    else
        -- We need to rescan the text as UTF-16 to find the character offset.
        for _, r in core.Runes(string.sub(script:Text(), start + 1, position)) do
            character = character + utf16RuneLen(r)
        end
    end

    return {
        line = line,
        character = character,
    }
end

-- diagnosticOptions: { reportStyleChecksAsWarnings, relatedInformation, tagValueSet, visualStudio }

-- DiagnosticToLSPPull converts a diagnostic for pull diagnostics (textDocument/diagnostic)
function lsconv.DiagnosticToLSPPull(ctx, converters, diagnostic, reportStyleChecksAsWarnings)
    local clientCaps = lsproto.GetClientCapabilities(ctx)
    local clientDiagnosticCaps = clientCaps.textDocument.diagnostic
    return lsconv.diagnosticToLSP(ctx, converters, diagnostic, {
        reportStyleChecksAsWarnings = reportStyleChecksAsWarnings, -- !!! get through context UserPreferences
        relatedInformation = clientDiagnosticCaps.relatedInformation,
        tagValueSet = clientDiagnosticCaps.tagSupport.valueSet,
        visualStudio = clientCaps.vsSupportsVisualStudioExtensions,
    })
end

-- DiagnosticToLSPPush converts a diagnostic for push diagnostics (textDocument/publishDiagnostics)
function lsconv.DiagnosticToLSPPush(ctx, converters, diagnostic)
    local clientCaps = lsproto.GetClientCapabilities(ctx)
    local clientDiagnosticCaps = clientCaps.textDocument.publishDiagnostics
    return lsconv.diagnosticToLSP(ctx, converters, diagnostic, {
        reportStyleChecksAsWarnings = false,
        relatedInformation = clientDiagnosticCaps.relatedInformation,
        tagValueSet = clientDiagnosticCaps.tagSupport.valueSet,
        visualStudio = clientCaps.vsSupportsVisualStudioExtensions,
    })
end

-- https://github.com/microsoft/vscode/blob/93e08afe0469712706ca4e268f778cfadf1a43ef/extensions/typescript-language-features/src/typeScriptServiceClientHost.ts#L40C7-L40C29
lsconv.styleCheckDiagnostics = collections.NewSetFromItems(
    diagnostics.X_0_is_declared_but_never_used:Code(),
    diagnostics.X_0_is_declared_but_its_value_is_never_read:Code(),
    diagnostics.Property_0_is_declared_but_its_value_is_never_read:Code(),
    diagnostics.All_imports_in_import_declaration_are_unused:Code(),
    diagnostics.Unreachable_code_detected:Code(),
    diagnostics.Unused_label:Code(),
    diagnostics.Fallthrough_case_in_switch:Code(),
    diagnostics.Not_all_code_paths_return_a_value:Code()
)

local function zeroRange()
    return newRange({ line = 0, character = 0 }, { line = 0, character = 0 })
end

function lsconv.diagnosticToLSP(ctx, converters, diagnostic, opts)
    local loc = locale.FromContext(ctx)
    local severity = lsconv.diagnosticSeverity(diagnostic:Category())

    if opts.reportStyleChecksAsWarnings and severity == lsproto.DiagnosticSeverity.Error and lsconv.styleCheckDiagnostics:Has(diagnostic:Code()) then
        severity = lsproto.DiagnosticSeverity.Warning
    end

    local relatedInformation
    if opts.relatedInformation then
        relatedInformation = {}
        for _, related in ipairs(diagnostic:RelatedInformation() or {}) do
            local script, rloc = lsconv.diagnosticScriptAndRange(related:File(), related:Loc(), related:Source())
            local relatedRange, fidelity = converters:ToLSPRange(script, rloc)
            if spanmap.Fidelity_IsNone(fidelity) then
                -- Related diagnostic information cannot omit its location. Use an explicit file-level
                -- location instead of presenting the synthesized span's insertion point as related source.
                relatedRange = zeroRange()
            end
            relatedInformation[#relatedInformation + 1] = {
                location = {
                    uri = lsconv.FileNameToDocumentURI(related:File():OriginalFileName()),
                    range = relatedRange,
                },
                message = related:Localize(loc),
            }
        end
    end

    local tags
    if core.Len(opts.tagValueSet) > 0 and (diagnostic:ReportsUnnecessary() or diagnostic:ReportsDeprecated()) then
        tags = {}
        if diagnostic:ReportsUnnecessary() and core.FindIndex(opts.tagValueSet, function(t)
            return t == lsproto.DiagnosticTag.Unnecessary
        end) >= 0 then
            tags[#tags + 1] = lsproto.DiagnosticTag.Unnecessary
        end
        if diagnostic:ReportsDeprecated() and core.FindIndex(opts.tagValueSet, function(t)
            return t == lsproto.DiagnosticTag.Deprecated
        end) >= 0 then
            tags[#tags + 1] = lsproto.DiagnosticTag.Deprecated
        end
    end

    -- For diagnostics without a file (e.g., program diagnostics), use a zero range
    local lspRange = zeroRange()
    if diagnostic:File() ~= nil then
        local script, dloc = lsconv.diagnosticScriptAndRange(diagnostic:File(), diagnostic:Loc(), diagnostic:Source())
        local fidelity
        lspRange, fidelity = converters:ToLSPRange(script, dloc)
        if spanmap.Fidelity_IsNone(fidelity) then
            -- Diagnostics must carry a range. A zero range honestly means "this file" when the
            -- diagnostic arose entirely in synthesized code and has no original source span.
            lspRange = zeroRange()
        end
    end

    local code
    local sourceText = diagnostic:Source()
    if sourceText == "" then
        sourceText = "ts"
    end
    if opts.visualStudio then
        code = {
            string = string.format("TS%d", diagnostic:Code()),
        }
    else
        code = {
            integer = diagnostic:Code(),
        }
    end

    return {
        range = lspRange,
        code = code,
        severity = severity,
        message = { string = lsconv.messageChainToString(diagnostic, loc) },
        source = sourceText,
        relatedInformation = lsconv.ptrToSliceIfNonEmpty(relatedInformation),
        tags = lsconv.ptrToSliceIfNonEmpty(tags),
    }
end

-- diagnosticScriptAndRange resolves the text basis and range to report a diagnostic against. For a
-- content-mapped file it maps the diagnostic's virtual range back to the original text so
-- the range lines up with what the editor shows; the original text's line map is already what
-- getLineMap returns for the file. A range in synthesized code has no original counterpart, so it is
-- surfaced at the top of the file. Non-mapped files are returned unchanged.
function lsconv.diagnosticScriptAndRange(file, loc, source)
    if file == nil or file:SpanMap() == nil then
        return file, loc
    end
    local original = lsconv.newOriginalTextScript(file:OriginalFileName(), file:OriginalText())
    if source ~= "" then
        -- A content mapper's own diagnostics already carry original-text ranges.
        return original, loc
    end
    local mapped, fidelity = file:SpanMap():VirtualToOriginalSpan(loc)
    if fidelity == Fidelity.None then
        -- Entirely synthesized code has no original location; surface it at the top of the file.
        return original, core.NewTextRange(0, 0)
    end
    return original, mapped
end

-- originalTextScript presents a content-mapped file's original (untransformed) text as a Script, so that
-- ranges already mapped into that text convert to the correct line/character positions.
local originalTextScript = {}
originalTextScript.__index = originalTextScript
lsconv.originalTextScript = originalTextScript

function lsconv.newOriginalTextScript(fileName, text)
    return setmetatable({ fileName = fileName, text = text }, originalTextScript)
end

function originalTextScript:FileName() return self.fileName end
function originalTextScript:OriginalFileName() return self.fileName end
function originalTextScript:Text() return self.text end
function originalTextScript:OriginalText() return self.text end
function originalTextScript:SpanMap() return nil end

-- diagnosticSeverity maps a diagnostic category to its LSP severity.
function lsconv.diagnosticSeverity(category)
    if category == diagnostics.Category.Suggestion then
        return lsproto.DiagnosticSeverity.Hint
    elseif category == diagnostics.Category.Message then
        return lsproto.DiagnosticSeverity.Information
    elseif category == diagnostics.Category.Warning then
        return lsproto.DiagnosticSeverity.Warning
    else
        return lsproto.DiagnosticSeverity.Error
    end
end

function lsconv.messageChainToString(diagnostic, loc)
    if core.Len(diagnostic:MessageChain()) == 0 then
        return diagnostic:Localize(loc)
    end
    local b = core.NewStringBuilder()
    diagnosticwriter.WriteFlattenedASTDiagnosticMessage(b, diagnostic, "\n", loc)
    return b:String()
end

function lsconv.ptrToSliceIfNonEmpty(s)
    if core.Len(s) == 0 then
        return nil
    end
    return s
end
