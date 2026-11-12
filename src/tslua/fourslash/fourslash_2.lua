-- luacheck: ignore 211 421 423 431 432
local fourslash = require("tslua.fourslash")
local lsutil = require("tslua.ls.lsutil")
local stringutil = require("tslua.stringutil")
local diagnostics = require("tslua.diagnostics")
local project = require("tslua.project")
local repo = require("tslua.repo")
local core = require("tslua.core")
local collections = require("tslua.collections")
local lsproto = require("tslua.lsp.lsproto")
local ls = require("tslua.ls")
local json = require("tslua.json")
local spanmap = require("tslua.spanmap")
local vfstest = require("tslua.vfs.vfstest")
local bundled = require("tslua.bundled")
local lsptestutil = require("tslua.testutil.lsptestutil")
local jsonrpc = require("tslua.jsonrpc")
local baseline = require("tslua.testutil.baseline")
local debug = require("tslua.debug")
local tspath = require("tslua.tspath")
local tsbaseline = require("tslua.testutil.tsbaseline")
local lsconv = require("tslua.ls.lsconv")
local harnessutil = require("tslua.testutil.harnessutil")
local tsctests = require("tslua.execute.tsctests")
local gort = require("tslua.fourslash.goruntime")

local FourslashTest = fourslash.FourslashTest
local scriptInfo = fourslash.scriptInfo
local testConverters = fourslash.testConverters
local fourslashDiagnostic = fourslash.fourslashDiagnostic
local fourslashDiagnosticFile = fourslash.fourslashDiagnosticFile

function FourslashTest:VerifyBaselineHover(t)
    local markersAndItems = core.MapFiltered(self:Markers(), function(marker)
        if marker.name == nil then
            return {}, false
        end
        local params = lsproto.HoverParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker.fileName) }),
            position = marker.lsPosition,
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentHoverInfo, params)
        return fourslash.newMarkerAndItem(marker, result.hover), true
    end)
    local getRange = function(item)
        if (item == nil) or (item.range == nil) then
            return nil
        end
        return item.range
    end
    local getTooltipLines = function(item, _prev)
        local result = nil
        if item.contents.markupContent ~= nil then
            result = gort.strings.Split(item.contents.markupContent.value, "\n")
        end
        if item.contents.string ~= nil then
            result = gort.strings.Split(item.contents.string, "\n")
        end
        if item.contents.markedStringWithLanguage ~= nil then
            result = fourslash.appendLinesForMarkedStringWithLanguage(result, item.contents.markedStringWithLanguage)
        end
        if item.contents.markedStrings ~= nil then
            for i139, ms in gort.ipairs(item.contents.markedStrings) do
                if ms.markedStringWithLanguage ~= nil then
                    result = fourslash.appendLinesForMarkedStringWithLanguage(result, ms.markedStringWithLanguage)
                else
                    result = gort.append(result, ms.string)
                end
            end
        end
        return result
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.quickInfoCmd, fourslash.annotateContentWithTooltips(t, self, markersAndItems, "quickinfo", getRange, getTooltipLines))
    do
        local jsonStr, err = core.StringifyJson(markersAndItems, "", "  ")
        if err == nil then
            self:writeToBaseline(fourslash.baselineCommand.quickInfoCmd, jsonStr)
        else
            t:Fatalf("Failed to stringify markers and items for baseline: %v", err)
        end
    end
end

function FourslashTest:VerifyBaselineVSHover(t)
    local markersAndItems = core.MapFiltered(self:Markers(), function(marker)
        if marker.name == nil then
            return {}, false
        end
        local params = lsproto.HoverParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker.fileName) }),
            position = marker.lsPosition,
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentHoverInfo, params)
        return fourslash.newMarkerAndItem(marker, result.hover), true
    end)
    local getRange = function(item)
        if (item == nil) or (item.range == nil) then
            return nil
        end
        return item.range
    end
    local getTooltipLines = function(item, _prev)
        if item == nil then
            return nil
        end
        if item.vsRawContent == nil then
            return {
                "(no _vs_rawContent; is VSSupportsVisualStudioExtensions set on the test's ClientCapabilities?)",
            }
        end
        return fourslash.renderVSContainerElement(item.vsRawContent, "")
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.vsQuickInfoCmd, fourslash.annotateContentWithTooltips(t, self, markersAndItems, "vsquickinfo", getRange, getTooltipLines))
    do
        local jsonStr, err = core.StringifyJson(markersAndItems, "", "  ")
        if err == nil then
            self:writeToBaseline(fourslash.baselineCommand.vsQuickInfoCmd, jsonStr)
        else
            t:Fatalf("Failed to stringify markers and items for baseline: %v", err)
        end
    end
end

function fourslash.renderVSContainerElement(el, indent)
    local lines = { gort.fmt.Sprintf("%sContainerElement (Style=%s)", indent, el.style) }
    local childIndent = indent .. "  "
    for i141, child in gort.ipairs(el.elements) do
        if child.imageElement ~= nil then
            local imageId = child.imageElement.imageId
            lines = gort.append(lines, gort.fmt.Sprintf("%sImageElement { Guid: %s, Id: 0x%X }", childIndent, imageId.guid, imageId.id))
        elseif child.classifiedTextElement ~= nil then
            lines = gort.append(lines, childIndent .. "ClassifiedTextElement")
            for i143, run in gort.ipairs(child.classifiedTextElement.runs) do
                lines = gort.append(lines, gort.fmt.Sprintf("%s  [%s] %q", childIndent, run.classificationTypeName, run.text))
            end
        elseif child.containerElement ~= nil then
            lines = gort.appendSlice(lines, fourslash.renderVSContainerElement(child.containerElement, childIndent))
        else
            lines = gort.append(lines, childIndent .. "<empty union element>")
        end
    end
    return lines
end

function fourslash.appendLinesForMarkedStringWithLanguage(result, ms)
    result = gort.append(result, "```" .. ms.language)
    result = gort.append(result, ms.value)
    result = gort.append(result, "```")
    return result
end

function fourslash.hoverContentString(hover)
    if hover == nil then
        return ""
    end
    if hover.contents.markupContent ~= nil then
        return hover.contents.markupContent.value
    end
    if hover.contents.string ~= nil then
        return hover.contents.string
    end
    return ""
end

function FourslashTest:VerifyBaselineHoverWithVerbosity(t, verbosityLevels)
    local markersAndItems = nil
    for i145, marker in gort.ipairs(self:Markers()) do
        do
            if marker.name == nil then
                goto continue146
            end
            local levels, ok = gort.MapLookup(verbosityLevels, marker.name, nil)
            if not ok then
                levels = { 0 }
            end
            for i147, level in gort.ipairs(levels) do
                local i = i147 - 1
                local verbLevel = nil
                if level > 0 then
                    verbLevel = level
                end
                local params = lsproto.HoverParams({
                        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker.fileName) }),
                        position = marker.lsPosition,
                        verbosityLevel = verbLevel,
                    })
                local result = fourslash.sendRequest(t, self, lsproto.TextDocumentHoverInfo, params)
                local item = { hover = result.hover, verbosityLevel = level }
                if (i > 0) and (level > levels[(i - 1) + 1]) then
                    local prevItem = markersAndItems[(gort.len(markersAndItems) - 1) + 1].item
                    if ((prevItem ~= nil) and (prevItem.hover ~= nil)) and (not prevItem.hover.canIncreaseVerbosity) then
                        local prevContent = fourslash.hoverContentString(prevItem.hover)
                        local curContent = fourslash.hoverContentString(item.hover)
                        if prevContent ~= curContent then
                            t:Errorf([[
At marker %q: verbosity level %d response differs from level %d, but level %d had canIncreaseVerbosity=false.
  level %d: %s
  level %d: %s]], marker.name, level, levels[(i - 1) + 1], levels[(i - 1) + 1], levels[(i - 1) + 1], prevContent, level, curContent)
                        end
                    end
                end
                markersAndItems = gort.append(markersAndItems, fourslash.newMarkerAndItem(marker, item))
            end
        end
        ::continue146::
    end
    local getRange = function(item)
        if ((item == nil) or (item.hover == nil)) or (item.hover.range == nil) then
            return nil
        end
        return item.hover.range
    end
    local getTooltipLines = function(item, _prev)
        if (item == nil) or (item.hover == nil) then
            return nil
        end
        local result = nil
        if item.hover.contents.markupContent ~= nil then
            result = gort.strings.Split(item.hover.contents.markupContent.value, "\n")
        end
        if item.hover.contents.string ~= nil then
            result = gort.strings.Split(item.hover.contents.string, "\n")
        end
        if item.hover.contents.markedStringWithLanguage ~= nil then
            result = fourslash.appendLinesForMarkedStringWithLanguage(result, item.hover.contents.markedStringWithLanguage)
        end
        if item.hover.contents.markedStrings ~= nil then
            for i149, ms in gort.ipairs(item.hover.contents.markedStrings) do
                if ms.markedStringWithLanguage ~= nil then
                    result = fourslash.appendLinesForMarkedStringWithLanguage(result, ms.markedStringWithLanguage)
                else
                    result = gort.append(result, ms.string)
                end
            end
        end
        result = gort.append(result, gort.fmt.Sprintf("(verbosity level: %d)", item.verbosityLevel))
        return result
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.quickInfoCmd, fourslash.annotateContentWithTooltips(t, self, markersAndItems, "quickinfo", getRange, getTooltipLines))
    do
        local jsonStr, err = core.StringifyJson(markersAndItems, "", "  ")
        if err == nil then
            self:writeToBaseline(fourslash.baselineCommand.quickInfoCmd, jsonStr)
        else
            t:Fatalf("Failed to stringify markers and items for baseline: %v", err)
        end
    end
end

function FourslashTest:VerifyBaselineSignatureHelp(t)
    local markersAndItems = core.MapFiltered(self:Markers(), function(marker)
        if marker.name == nil then
            return {}, false
        end
        local params = lsproto.SignatureHelpParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker:FileName()) }),
            position = marker.lsPosition,
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
        return fourslash.newMarkerAndItem(marker, result.signatureHelp), true
    end)
    local getRange = function(item)
        return nil
    end
    local getTooltipLines = function(item, _prev)
        if (item == nil) or (gort.len(item.signatures) == 0) then
            return { "No signature help available" }
        end
        local activeSignature = 0
        if (item.activeSignature ~= nil) and (item.activeSignature < gort.len(item.signatures)) then
            activeSignature = item.activeSignature
        end
        local sig = item.signatures[activeSignature + 1]
        local signatureLine = sig.label
        local activeParamLine = ""
        local activeParamPtr = nil
        if sig.activeParameter ~= nil then
            activeParamPtr = sig.activeParameter
        else
            activeParamPtr = item.activeParameter
        end
        if ((activeParamPtr ~= nil) and (activeParamPtr.uinteger ~= nil)) and (sig.parameters ~= nil) then
            local activeParamIndex = activeParamPtr.uinteger
            if (activeParamIndex >= 0) and (activeParamIndex < gort.len(sig.parameters)) then
                local activeParam = (sig.parameters)[activeParamIndex + 1]
                local activeParamLabel = ""
                if activeParam.label.string ~= nil then
                    activeParamLabel = activeParam.label.string
                elseif activeParam.label.tuple ~= nil then
                    activeParamLabel = string.sub(signatureLine, (activeParam.label.tuple)[1] + 1, (activeParam.label.tuple)[2])
                else
                    t:Fatal("Unsupported param label kind.")
                end
                signatureLine = gort.strings.Replace(signatureLine, activeParamLabel, ("**" .. activeParamLabel) .. "**", 1)
                if activeParam.documentation ~= nil then
                    if activeParam.documentation.markupContent ~= nil then
                        activeParamLine = activeParam.documentation.markupContent.value
                    elseif activeParam.documentation.string ~= nil then
                        activeParamLine = activeParam.documentation.string
                    end
                    activeParamLine = gort.fmt.Sprintf("- `%s`: %s", activeParamLabel, activeParamLine)
                end
            end
        end
        local result = gort.makeSlice(0, function() return "" end)
        result = gort.append(result, signatureLine)
        if activeParamLine ~= "" then
            result = gort.append(result, activeParamLine)
        end
        if sig.documentation ~= nil then
            if sig.documentation.markupContent ~= nil then
                result = gort.appendSlice(result, gort.strings.Split(sig.documentation.markupContent.value, "\n"))
            elseif sig.documentation.string ~= nil then
                result = gort.appendSlice(result, gort.strings.Split(sig.documentation.string, "\n"))
            else
                t:Fatal("Unsupported documentation format.")
            end
        end
        return result
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.signatureHelpCmd, fourslash.annotateContentWithTooltips(t, self, markersAndItems, "signaturehelp", getRange, getTooltipLines))
    do
        local jsonStr, err = core.StringifyJson(markersAndItems, "", "  ")
        if err == nil then
            self:writeToBaseline(fourslash.baselineCommand.signatureHelpCmd, jsonStr)
        else
            t:Fatalf("Failed to stringify markers and items for baseline: %v", err)
        end
    end
end

function FourslashTest:VerifyBaselineSelectionRanges(t)
    local markers = self:Markers()
    local result = gort.NewBuilder()
    local newLine = "\n"
    for i151, marker in gort.ipairs(markers) do
        local i = i151 - 1
        do
            if i > 0 then
                result:WriteString(newLine)
                for _ = 0, 80 - 1 do
                    result:WriteByte(61)
                end
                result:WriteString(newLine)
                result:WriteString(newLine)
            end
            local script = self:getScriptInfo(marker:FileName())
            local fileContent = script.content
            local markerPos = marker.position
            local baselineContent = ((string.sub(fileContent, 1, markerPos) .. "/**/") .. string.sub(fileContent, markerPos + 1)) .. newLine
            result:WriteString(baselineContent)
            local params = lsproto.SelectionRangeParams({
                textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker:FileName()) }),
                positions = { marker.lsPosition },
            })
            local selectionRangeResult = fourslash.sendRequest(t, self, lsproto.TextDocumentSelectionRangeInfo, params)
            if (selectionRangeResult.selectionRanges == nil) or (gort.len(selectionRangeResult.selectionRanges) == 0) then
                result:WriteString("No selection ranges available\n")
                goto continue152
            end
            local selectionRange = (selectionRangeResult.selectionRanges)[1]
            result:WriteString(newLine)
            while selectionRange ~= nil do
                local start = self.converters:LineAndCharacterToPosition(script, selectionRange.range.start)
                local end_ = self.converters:LineAndCharacterToPosition(script, selectionRange.range.end_)
                local runes = fileContent
                local masked = gort.makeSlice(gort.len(runes), function() return 0 end)
                for i155, ch in gort.ipairs(runes) do
                    local i = i155 - 1
                    if (i >= start) and (i < end_) then
                        if ch == 32 then
                            masked[i + 1] = 8226
                        elseif (ch == 10) or (ch == 13) then
                            masked[i + 1] = ch
                        else
                            masked[i + 1] = ch
                        end
                    else
                        if (ch == 10) or (ch == 13) then
                            masked[i + 1] = ch
                        else
                            masked[i + 1] = 32
                        end
                    end
                end
                local maskedStr = gort.bytesToString(masked)
                maskedStr = gort.strings.ReplaceAll(maskedStr, "\n", "↲\n")
                maskedStr = gort.strings.ReplaceAll(maskedStr, "\r", "↲\r")
                local lines = gort.strings.Split(maskedStr, "\n")
                local nonBlankLines = nil
                for i157, line in gort.ipairs(lines) do
                    local trimmed = gort.strings.TrimSpace(line)
                    if (trimmed ~= "") and (trimmed ~= "↲") then
                        nonBlankLines = gort.append(nonBlankLines, line)
                    end
                end
                maskedStr = gort.strings.Join(nonBlankLines, "\n")
                local maskedRunes = maskedStr
                local isRealCharacter = function(ch)
                        return ((ch ~= 8226) and (ch ~= 8626)) and (not stringutil.IsWhiteSpaceLike(ch))
                    end
                local leadingWidth = -1
                for i159, ch in gort.ipairs(maskedRunes) do
                    local i = i159 - 1
                    if isRealCharacter(ch) then
                        leadingWidth = i
                        break
                    end
                end
                local trailingWidth = -1
                do
                    local j = gort.len(maskedRunes) - 1
                    while j >= 0 do
                        if isRealCharacter(maskedRunes[j + 1]) then
                            trailingWidth = j
                            break
                        end
                        j = j - 1
                    end
                end
                if ((leadingWidth ~= (-1)) and (trailingWidth ~= (-1))) and (leadingWidth <= trailingWidth) then
                    local prefix = gort.bytesToString(gort.slice(maskedRunes, 0, leadingWidth))
                    local middle = gort.bytesToString(gort.slice(maskedRunes, leadingWidth, trailingWidth + 1))
                    local suffix = gort.bytesToString(gort.slice(maskedRunes, trailingWidth + 1, nil))
                    middle = gort.strings.ReplaceAll(middle, "•", " ")
                    middle = gort.strings.ReplaceAll(middle, "↲", "")
                    maskedStr = (prefix .. middle) .. suffix
                end
                if gort.strings.Contains(maskedStr, "\n") then
                    result:WriteString(newLine)
                end
                result:WriteString(maskedStr)
                if not gort.strings.HasSuffix(maskedStr, "\n") then
                    result:WriteString(newLine)
                end
                selectionRange = selectionRange.parent
            end
        end
        ::continue152::
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.smartSelectionCmd, gort.strings.TrimSuffix(result:String(), "\n"))
end

function FourslashTest:VerifyBaselineCallHierarchy(t)
    local fileName = self.activeFilename
    local position = gort.CloneStruct(self.currentCaretPosition)
    local params = lsproto.CallHierarchyPrepareParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(fileName) }),
        position = position,
    })
    local prepareResult = fourslash.sendRequest(t, self, lsproto.TextDocumentPrepareCallHierarchyInfo, params)
    if (prepareResult.callHierarchyItems == nil) or (gort.len(prepareResult.callHierarchyItems) == 0) then
        self:addResultToBaseline(t, fourslash.baselineCommand.callHierarchyCmd, "No call hierarchy items available")
        return
    end
    local result = gort.NewBuilder()
    for i162, callHierarchyItem in gort.ipairs(prepareResult.callHierarchyItems) do
        local seen = {}
        local itemFileName = lsproto.DocumentUri_FileName(callHierarchyItem.uri)
        local script = self:getOrLoadScriptInfo(itemFileName)
        fourslash.formatCallHierarchyItem(t, self, script, result, callHierarchyItem, fourslash.callHierarchyItemDirection.Root, seen, "")
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.callHierarchyCmd, gort.strings.TrimSuffix(result:String(), "\n"))
end

function fourslash.symbolKindToLowercase(kind)
    return gort.strings.ToLower(lsproto.SymbolKind_String(kind))
end

function fourslash.formatCallHierarchyItem(t, f, file, result, callHierarchyItem, direction, seen, prefix)
    local key = { uri = callHierarchyItem.uri, range_ = callHierarchyItem.range, direction = direction }
    local alreadySeen = (seen[gort.Key(key)] or false)
    seen[gort.Key(key)] = true
    local incomingCalls = { skip = false, seen = false }
    local outgoingCalls = { skip = false, seen = false }
    if direction == fourslash.callHierarchyItemDirection.Outgoing then
        incomingCalls.skip = true
    elseif alreadySeen then
        incomingCalls.seen = true
    else
        local incomingParams = lsproto.CallHierarchyIncomingCallsParams({ item = callHierarchyItem })
        local incomingResult = fourslash.sendRequest(t, f, lsproto.CallHierarchyIncomingCallsInfo, incomingParams)
        if incomingResult.callHierarchyIncomingCalls ~= nil then
            incomingCalls.values = incomingResult.callHierarchyIncomingCalls
        end
    end
    if direction == fourslash.callHierarchyItemDirection.Incoming then
        outgoingCalls.skip = true
    elseif alreadySeen then
        outgoingCalls.seen = true
    else
        local outgoingParams = lsproto.CallHierarchyOutgoingCallsParams({ item = callHierarchyItem })
        local outgoingResult = fourslash.sendRequest(t, f, lsproto.CallHierarchyOutgoingCallsInfo, outgoingParams)
        if outgoingResult.callHierarchyOutgoingCalls ~= nil then
            outgoingCalls.values = outgoingResult.callHierarchyOutgoingCalls
        end
    end
    local trailingPrefix = prefix
    result:WriteString(gort.fmt.Sprintf("%s╭ name: %s\n", prefix, callHierarchyItem.name))
    result:WriteString(gort.fmt.Sprintf("%s├ kind: %s\n", prefix, fourslash.symbolKindToLowercase(callHierarchyItem.kind)))
    if (callHierarchyItem.detail ~= nil) and (callHierarchyItem.detail ~= "") then
        result:WriteString(gort.fmt.Sprintf("%s├ containerName: %s\n", prefix, callHierarchyItem.detail))
    end
    result:WriteString(gort.fmt.Sprintf("%s├ file: %s\n", prefix, lsproto.DocumentUri_FileName(callHierarchyItem.uri)))
    result:WriteString(prefix)
    result:WriteString("├ span:\n")
    fourslash.formatCallHierarchyItemSpan(f, file, result, callHierarchyItem.range, prefix .. "│ ", prefix .. "│ ")
    result:WriteString(prefix)
    result:WriteString("├ selectionSpan:\n")
    fourslash.formatCallHierarchyItemSpan(f, file, result, callHierarchyItem.selectionRange, prefix .. "│ ", prefix .. "│ ")
    if incomingCalls.seen then
        if outgoingCalls.skip then
            result:WriteString(trailingPrefix)
            result:WriteString("╰ incoming: ...\n")
        else
            result:WriteString(prefix)
            result:WriteString("├ incoming: ...\n")
        end
    elseif not incomingCalls.skip then
        if gort.len(incomingCalls.values) == 0 then
            if outgoingCalls.skip then
                result:WriteString(trailingPrefix)
                result:WriteString("╰ incoming: none\n")
            else
                result:WriteString(prefix)
                result:WriteString("├ incoming: none\n")
            end
        else
            result:WriteString(prefix)
            result:WriteString("├ incoming:\n")
            for i164, incomingCall in gort.ipairs(incomingCalls.values) do
                local i = i164 - 1
                local fromFileName = lsproto.DocumentUri_FileName(incomingCall.from.uri)
                local fromFile = f:getOrLoadScriptInfo(fromFileName)
                result:WriteString(prefix)
                result:WriteString("│ ╭ from:\n")
                fourslash.formatCallHierarchyItem(t, f, fromFile, result, incomingCall.from, fourslash.callHierarchyItemDirection.Incoming, seen, prefix .. "│ │ ")
                result:WriteString(prefix)
                result:WriteString("│ ├ fromSpans:\n")
                local fromSpansTrailingPrefix = trailingPrefix .. "╰ ╰ "
                if i < (gort.len(incomingCalls.values) - 1) then
                    fromSpansTrailingPrefix = prefix .. "│ ╰ "
                elseif (not outgoingCalls.skip) and (((not outgoingCalls.seen) or (gort.len(outgoingCalls.values) > 0))) then
                    fromSpansTrailingPrefix = prefix .. "│ ╰ "
                end
                fourslash.formatCallHierarchyItemSpans(f, fromFile, result, incomingCall.fromRanges, prefix .. "│ │ ", fromSpansTrailingPrefix)
            end
        end
    end
    if outgoingCalls.seen then
        result:WriteString(trailingPrefix)
        result:WriteString("╰ outgoing: ...\n")
    elseif not outgoingCalls.skip then
        if gort.len(outgoingCalls.values) == 0 then
            result:WriteString(trailingPrefix)
            result:WriteString("╰ outgoing: none\n")
        else
            result:WriteString(prefix)
            result:WriteString("├ outgoing:\n")
            for i166, outgoingCall in gort.ipairs(outgoingCalls.values) do
                local i = i166 - 1
                local toFileName = lsproto.DocumentUri_FileName(outgoingCall.to.uri)
                local toFile = f:getOrLoadScriptInfo(toFileName)
                result:WriteString(prefix)
                result:WriteString("│ ╭ to:\n")
                fourslash.formatCallHierarchyItem(t, f, toFile, result, outgoingCall.to, fourslash.callHierarchyItemDirection.Outgoing, seen, prefix .. "│ │ ")
                result:WriteString(prefix)
                result:WriteString("│ ├ fromSpans:\n")
                local fromSpansTrailingPrefix = trailingPrefix .. "╰ ╰ "
                if i < (gort.len(outgoingCalls.values) - 1) then
                    fromSpansTrailingPrefix = prefix .. "│ ╰ "
                end
                fourslash.formatCallHierarchyItemSpans(f, file, result, outgoingCall.fromRanges, prefix .. "│ │ ", fromSpansTrailingPrefix)
            end
        end
    end
end

function fourslash.formatCallHierarchyItemSpan(f, file, result, span, prefix, closingPrefix)
    local startLc = gort.CloneStruct(span.start)
    local endLc = gort.CloneStruct(span.end_)
    local startPos = f.converters:LineAndCharacterToPosition(file, span.start)
    local endPos = f.converters:LineAndCharacterToPosition(file, span.end_)
    local lineStarts = fourslash.computeLineStarts(file.content)
    local contextStart = startPos
    local contextEnd = endPos
    while ((contextStart > 0) and (string.byte(file.content, (contextStart - 1) + 1) ~= 10)) and (string.byte(file.content, (contextStart - 1) + 1) ~= 13) do
        contextStart = contextStart - 1
    end
    while ((contextEnd < #file.content) and (string.byte(file.content, contextEnd + 1) ~= 10)) and (string.byte(file.content, contextEnd + 1) ~= 13) do
        contextEnd = contextEnd + 1
    end
    local contextStartLine = startLc.line
    local contextEndLine = endLc.line
    local lineNumWidth = #gort.strconv.Itoa(contextEndLine + 1) + 2
    result:WriteString(gort.fmt.Sprintf("%s╭ %s:%d:%d-%d:%d\n", prefix, file.fileName, startLc.line + 1, startLc.character + 1, endLc.line + 1, endLc.character + 1))
    do
        local lineNum = contextStartLine
        while lineNum <= contextEndLine do
            local lineStart = lineStarts[lineNum + 1]
            local lineEnd = #file.content
            if (lineNum + 1) < gort.len(lineStarts) then
                lineEnd = lineStarts[(lineNum + 1) + 1]
            end
            local lineContent = string.sub(file.content, lineStart + 1, lineEnd)
            lineContent = gort.strings.TrimRight(lineContent, "\r\n")
            local lineNumStr = gort.fmt.Sprintf("%d:", lineNum + 1)
            local paddedLineNum = gort.strings.Repeat(" ", (lineNumWidth - #lineNumStr) - 1) .. lineNumStr
            if lineContent == "" then
                result:WriteString(gort.fmt.Sprintf("%s│ %s\n", prefix, paddedLineNum))
            else
                result:WriteString(gort.fmt.Sprintf("%s│ %s %s\n", prefix, paddedLineNum, lineContent))
            end
            if (lineNum >= startLc.line) and (lineNum <= endLc.line) then
                local selStart = 0
                local selEnd = #lineContent
                if lineNum == startLc.line then
                    selStart = startLc.character
                end
                if lineNum == endLc.line then
                    selEnd = endLc.character
                end
                local isEmpty = (startLc.line == endLc.line) and (startLc.character == endLc.character)
                if isEmpty then
                    local padding = gort.strings.Repeat(" ", lineNumWidth + selStart)
                    result:WriteString(gort.fmt.Sprintf("%s│ %s<\n", prefix, padding))
                else
                    local selLength = selEnd - selStart
                    selLength = math.max(selLength, 1)
                    if lineNum < endLc.line then
                        if selEnd > #lineContent then
                            selEnd = #lineContent
                            selLength = selEnd - selStart
                        end
                    end
                    local padding = gort.strings.Repeat(" ", lineNumWidth + selStart)
                    local carets = gort.strings.Repeat("^", selLength)
                    result:WriteString(gort.fmt.Sprintf("%s│ %s%s\n", prefix, padding, carets))
                end
            end
            lineNum = lineNum + 1
        end
    end
    result:WriteString(closingPrefix)
    result:WriteString("╰\n")
end

function fourslash.computeLineStarts(content)
    local lineStarts = { 0 }
    for i, ch in gort.runes(content) do
        if ch == 10 then
            lineStarts = gort.append(lineStarts, i + 1)
        end
    end
    return lineStarts
end

function fourslash.formatCallHierarchyItemSpans(f, file, result, spans, prefix, trailingPrefix)
    for i172, span in gort.ipairs(spans) do
        local i = i172 - 1
        local closingPrefix = prefix
        if i == (gort.len(spans) - 1) then
            closingPrefix = trailingPrefix
        end
        fourslash.formatCallHierarchyItemSpan(f, file, result, span, prefix, closingPrefix)
    end
end

function FourslashTest:VerifyBaselineDocumentHighlights(t, preferences, ...)
    local markerOrRangeOrNames = { ... }
    self:VerifyBaselineDocumentHighlightsWithOptions(t, preferences, nil, gort.unpack(markerOrRangeOrNames))
end

function FourslashTest:VerifyBaselineDocumentHighlightsWithOptions(t, preferences, filesToSearch, ...)
    local markerOrRangeOrNames = { ... }
    local markerOrRanges = nil
    for i174, markerOrRangeOrName in gort.ipairs(markerOrRangeOrNames) do
        local ts176 = markerOrRangeOrName
        if type(ts176) == "string" then
            local markerOrNameOrRange = ts176
            local marker, ok = gort.MapLookup(self.testData.markerPositions, markerOrNameOrRange, nil)
            if not ok then
                t:Fatalf("Marker '%s' not found", markerOrNameOrRange)
            end
            markerOrRanges = gort.append(markerOrRanges, marker)
        elseif gort.IsStruct(ts176, "tslua.fourslash", "Marker") then
            local markerOrNameOrRange = ts176
            markerOrRanges = gort.append(markerOrRanges, markerOrNameOrRange)
        elseif gort.IsStruct(ts176, "tslua.fourslash", "RangeMarker") then
            local markerOrNameOrRange = ts176
            markerOrRanges = gort.append(markerOrRanges, markerOrNameOrRange)
        else
            local markerOrNameOrRange = ts176
            t:Fatalf("Invalid marker or range type: %T. Expected string, *Marker, or *RangeMarker.", markerOrNameOrRange)
        end
    end
    self:verifyBaselineDocumentHighlights(t, preferences, filesToSearch, markerOrRanges)
end

function FourslashTest:verifyBaselineDocumentHighlights(t, preferences, filesToSearch, markerOrRanges)
    for i177, markerOrRange in gort.ipairs(markerOrRanges) do
        self:goToMarker(t, markerOrRange)
        local spans = nil
        local header = ""
        if gort.len(filesToSearch) > 0 then
            local searchURIs = nil
            for i179, file in gort.ipairs(filesToSearch) do
                searchURIs = gort.append(searchURIs, lsconv.FileNameToDocumentURI(file))
            end
            local params = lsproto.MultiDocumentHighlightParams({
                    textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                    position = self.currentCaretPosition,
                    filesToSearch = searchURIs,
                })
            local result = fourslash.sendRequest(t, self, lsproto.CustomTextDocumentMultiDocumentHighlightInfo, params)
            local multiHighlights = result.multiDocumentHighlights
            if multiHighlights == nil then
                multiHighlights = {}
            end
            for i181, mh in gort.ipairs(multiHighlights) do
                for i183, h in gort.ipairs(mh.highlights) do
                    spans = gort.append(spans, lsproto.Location({ uri = mh.uri, range = h.range }))
                end
            end
            local sb = gort.NewBuilder()
            sb:WriteString("// filesToSearch:\n")
            for i185, file in gort.ipairs(filesToSearch) do
                gort.fmt.Fprintf(sb, "//   %s\n", file)
            end
            sb:WriteString("\n")
            header = sb:String()
        else
            local params = lsproto.DocumentHighlightParams({
                    textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                    position = self.currentCaretPosition,
                })
            local result = fourslash.sendRequest(t, self, lsproto.TextDocumentDocumentHighlightInfo, params)
            local highlights = result.documentHighlights
            if highlights == nil then
                highlights = {}
            end
            for i187, h in gort.ipairs(highlights) do
                spans = gort.append(spans, lsproto.Location({ uri = lsconv.FileNameToDocumentURI(self.activeFilename), range = h.range }))
            end
        end
        self:addResultToBaseline(t, fourslash.baselineCommand.documentHighlightsCmd, header .. self:getBaselineForLocationsWithFileContents(spans, {
                marker = markerOrRange,
                markerName = "/*HIGHLIGHTS*/",
                endMarker = "",
                preserveResultOrder = false,
            }))
    end
end

function FourslashTest:lookupMarkersOrGetRanges(t, markers)
    local referenceLocations = nil
    if gort.len(markers) == 0 then
        referenceLocations = core.Map(self.testData.ranges, function(r)
            return r
        end)
    else
        referenceLocations = core.Map(markers, function(markerName)
            local marker, ok = gort.MapLookup(self.testData.markerPositions, markerName, nil)
            if not ok then
                t:Fatalf("Marker '%s' not found", markerName)
            end
            return marker
        end)
    end
    return referenceLocations
end

-- Go roundtripThroughJson[T]: T is given as a Go type string of lsproto (e.g. "[]Location").
function fourslash.roundtripThroughJson(goType, value)
    local result = lsproto.Zero(goType)
    local bytes, err = json.Marshal(value)
    if err ~= nil then
        return result, gort.fmt.Errorf("failed to marshal value to JSON: %w", err)
    end
    do
        local decoded, err2 = lsproto.UnmarshalAs(goType, bytes)
        if err2 ~= nil then
            return result, gort.fmt.Errorf("failed to unmarshal value from JSON: %w", err2)
        end
        result = decoded
    end
    return result, nil
end

function FourslashTest:Insert(t, text)
    t:Helper()
    self:baselineState(t)
    self:typeText(t, text)
end

function FourslashTest:InsertLine(t, text)
    t:Helper()
    self:baselineState(t)
    self:typeText(t, text .. "\n")
end

function FourslashTest:Backspace(t, count)
    local script = self:getScriptInfo(self.activeFilename)
    local offset = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
    self:baselineState(t)
    for _ = 0, count - 1 do
        offset = offset - 1
        self:editScriptAndUpdateMarkers(t, self.activeFilename, offset, offset + 1, "")
        self.currentCaretPosition = self.converters:PositionToLineAndCharacter(script, offset)
    end
end

function FourslashTest:DeleteAtCaret(t, count)
    local script = self:getScriptInfo(self.activeFilename)
    local offset = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
    self:baselineState(t)
    for _ = 0, count - 1 do
        self:editScriptAndUpdateMarkers(t, self.activeFilename, offset, offset + 1, "")
    end
end

function FourslashTest:Paste(t, text)
    local script = self:getScriptInfo(self.activeFilename)
    local start = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
    self:baselineState(t)
    self:editScriptAndUpdateMarkers(t, self.activeFilename, start, start, text)
    if self.stateEnableFormatting then
        local result = fourslash.sendRequestAndBaselineWorker(t, self, lsproto.TextDocumentRangeFormattingInfo, lsproto.DocumentRangeFormattingParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            range = lsproto.Range({
                start = self.currentCaretPosition,
                end_ = self.converters:PositionToLineAndCharacter(script, start + #text),
            }),
            options = self.userPreferences.formatCodeSettings:ToLSFormatOptions(),
        }), false)
        if result.textEdits ~= nil then
            self:applyTextEdits(t, result.textEdits)
        end
    end
end

function FourslashTest:ReplaceLine(t, lineIndex, text)
    self:baselineState(t)
    self:selectLine(t, lineIndex)
    self:typeText(t, text)
end

function FourslashTest:selectLine(t, lineIndex)
    local script = self:getScriptInfo(self.activeFilename)
    local start = script.lineMap.lineStarts[lineIndex + 1]
    local end_ = 0
    if (lineIndex + 1) >= gort.len(script.lineMap.lineStarts) then
        end_ = #script.content
    else
        end_ = script.lineMap.lineStarts[(lineIndex + 1) + 1] - 1
    end
    self:selectRange(t, core.NewTextRange(start, end_))
end

function FourslashTest:selectRange(t, textRange)
    local script = self:getScriptInfo(self.activeFilename)
    local start = self.converters:PositionToLineAndCharacter(script, textRange:Pos())
    local end_ = self.converters:PositionToLineAndCharacter(script, textRange:End())
    self:goToPosition(t, start)
    self.selectionEnd = end_
end

function FourslashTest:getSelection()
    local script = self:getScriptInfo(self.activeFilename)
    if self.selectionEnd == nil then
        return core.NewTextRange(self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition), self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition))
    end
    return core.NewTextRange(self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition), self.converters:LineAndCharacterToPosition(script, self.selectionEnd))
end

function FourslashTest:applyTextEdits(t, edits)
    local script = self:getScriptInfo(self.activeFilename)
    gort.slices.SortFunc(edits, function(a, b)
        local aStart = self.converters:LineAndCharacterToPosition(script, a.range.start)
        local bStart = self.converters:LineAndCharacterToPosition(script, b.range.start)
        return aStart - bStart
    end)
    local totalOffset = 0
    local currentCaretPosition = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
    do
        local i = gort.len(edits) - 1
        while i >= 0 do
            local edit = edits[i + 1]
            local start = self.converters:LineAndCharacterToPosition(script, edit.range.start)
            local end_ = self.converters:LineAndCharacterToPosition(script, edit.range.end_)
            self:editScriptAndUpdateMarkers(t, self.activeFilename, start, end_, edit.newText)
            local delta = #edit.newText - ((end_ - start))
            if start <= currentCaretPosition then
                if end_ <= currentCaretPosition then
                    currentCaretPosition = currentCaretPosition + delta
                else
                    currentCaretPosition = start
                end
            end
            totalOffset = totalOffset + delta
            i = i - 1
        end
    end
    self.currentCaretPosition = self.converters:PositionToLineAndCharacter(script, currentCaretPosition)
    return totalOffset
end

function FourslashTest:Replace(t, start, length, text)
    self:baselineState(t)
    self:replaceWorker(t, start, length, text)
end

function FourslashTest:replaceWorker(t, start, length, text)
    t:Helper()
    self:editScriptAndUpdateMarkers(t, self.activeFilename, start, start + length, text)
end

function FourslashTest:typeText(t, text)
    self.reportFormatOnTypeCrash = false
    gort.Defer(function() (function()
        self.reportFormatOnTypeCrash = true
    end)() end, function()
        local script = self:getScriptInfo(self.activeFilename)
        local selection = self:getSelection()
        self:replaceWorker(t, selection:Pos(), selection:End() - selection:Pos(), "")
        local totalSize = 0
        local offset = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
        while totalSize < #text do
            local r, size = gort.utf8.DecodeRuneInString(string.sub(text, totalSize + 1))
            self:editScriptAndUpdateMarkers(t, self.activeFilename, offset, offset, utf8.char(r))
            totalSize = totalSize + size
            offset = offset + size
            self.currentCaretPosition = self.converters:PositionToLineAndCharacter(script, offset)
            if self.stateEnableFormatting then
                local result = fourslash.sendRequestAndBaselineWorker(t, self, lsproto.TextDocumentOnTypeFormattingInfo, lsproto.DocumentOnTypeFormattingParams({
                        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                        position = self.currentCaretPosition,
                        ch = utf8.char(r),
                        options = self.userPreferences.formatCodeSettings:ToLSFormatOptions(),
                    }), false)
                if result.textEdits ~= nil then
                    offset = offset + self:applyTextEdits(t, result.textEdits)
                end
            end
        end
    end)
end

function FourslashTest:editScriptAndUpdateMarkers(t, fileName, editStart, editEnd, newText)
    self:editScriptAndUpdateMarkersWorker(t, fileName, { gort.Embed(setmetatable({ newText = newText }, core.TextChange), core.NewTextRange(editStart, editEnd)) })
end

function FourslashTest:editScriptAndUpdateMarkersWorker(t, fileName, changes)
    local sortedChanges = gort.slices.Clone(changes)
    gort.slices.SortFunc(sortedChanges, function(a, b)
        return a:Pos() - b:Pos()
    end)
    do
        local i = gort.len(sortedChanges) - 1
        while i >= 0 do
            local change = gort.CloneStruct(sortedChanges[i + 1])
            local editStart = change:Pos()
            local editEnd = change:End()
            local script = self:editScript(t, fileName, change)
            for i194, marker in gort.ipairs(self.testData.markers) do
                if marker:FileName() == fileName then
                    marker.position = fourslash.updatePosition(marker.position, editStart, editEnd, change.newText)
                    marker.lsPosition = self.converters:PositionToLineAndCharacter(script, marker.position)
                end
            end
            for i196, rangeMarker in gort.ipairs(self.testData.ranges) do
                if rangeMarker:FileName() == fileName then
                    local start = fourslash.updatePosition(rangeMarker.range:Pos(), editStart, editEnd, change.newText)
                    local end_ = fourslash.updatePosition(rangeMarker.range:End(), editStart, editEnd, change.newText)
                    rangeMarker.range = core.NewTextRange(start, end_)
                    local _
                    rangeMarker.lsRange, _ = self.converters:ToLSPRange(script, rangeMarker.range)
                end
            end
            i = i - 1
        end
    end
    self.rangesByText = nil
end

function fourslash.updatePosition(pos, editStart, editEnd, newText)
    if pos <= editStart then
        return pos
    end
    if pos < editEnd then
        return -1
    end
    return (pos + #newText) - ((editEnd - editStart))
end

function FourslashTest:fromLSPRange(script, r)
    local ranges = lsconv.FromLSPRange(self.converters, script, r, spanmap.Feature.All)
    if gort.len(ranges) ~= 1 then
        return setmetatable({ pos = 0, end_ = 0 }, core.TextRange)
    end
    return ranges[1].span
end

function FourslashTest:editScript(t, fileName, change)
    local script = self:getOrLoadScriptInfo(fileName)
    if script == nil then
        error(gort.fmt.Sprintf("Script info for file %s not found", fileName), 0)
    end
    local changeRange, _ = self.converters:ToLSPRange(script, core.NewTextRange(change:Pos(), change:End()))
    script:editContent(change)
    do
        local err = self.vfs:WriteFile(fileName, script.content)
        if err ~= nil then
            t:Fatalf("failed to write to VFS for %s: %v", fileName, err)
        end
    end
    fourslash.sendNotification(t, self, lsproto.TextDocumentDidChangeInfo, lsproto.DidChangeTextDocumentParams({
        textDocument = lsproto.VersionedTextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(fileName), version = script.version }),
        contentChanges = {
            lsproto.TextDocumentContentChangePartialOrWholeDocument({
                partial = lsproto.TextDocumentContentChangePartial({ range = changeRange, text = change.newText }),
            }),
        },
    }))
    return script
end

function FourslashTest:getScriptInfo(fileName)
    return self.scriptInfos[fileName]
end

function FourslashTest:getOrLoadScriptInfo(fileName)
    do
        local script = self:getScriptInfo(fileName)
        if script ~= nil then
            return script
        end
    end
    do
        local content, ok = self.vfs:ReadFile(fileName)
        if ok then
            local script = fourslash.newScriptInfo(fileName, content)
            self.scriptInfos[fileName] = script
            return script
        end
    end
    return nil
end

function FourslashTest:VerifyQuickInfoAt(t, marker, expectedText, expectedDocumentation)
    self:GoToMarker(t, marker)
    local hover = self:getQuickInfoAtCurrentPosition(t)
    if hover == nil then
        t:Fatalf("Expected hover result at marker '%s' but got nil", self.lastKnownMarkerName)
    end
    self:verifyHoverContent(t, hover.contents, expectedText, expectedDocumentation, self:getCurrentPositionPrefix())
end

function FourslashTest:getQuickInfoAtCurrentPosition(t)
    local params = lsproto.HoverParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentHoverInfo, params)
    return result.hover
end

function FourslashTest:verifyHoverContent(t, actual, expectedText, expectedDocumentation, prefix)
    if actual.markupContent ~= nil then
        self:verifyHoverMarkdown(t, actual.markupContent.value, expectedText, expectedDocumentation, prefix)
    else
        t:Fatalf(prefix .. "Expected markup content, got: %s", gort.cmp.Diff(actual, nil))
    end
end

function FourslashTest:verifyHoverMarkdown(t, actual, expectedText, expectedDocumentation, prefix)
    local expected = gort.fmt.Sprintf("```typescript\n%s\n```\n%s", expectedText, expectedDocumentation)
    fourslash.assertDeepEqual(t, actual, expected, prefix .. "Hover markdown content mismatch")
end

function FourslashTest:VerifyQuickInfoExists(t)
    do
        local isEmpty, _ = self:quickInfoIsEmpty(t)
        if isEmpty then
            t:Fatalf("Expected non-nil hover content at marker '%s'", self.lastKnownMarkerName)
        end
    end
end

function FourslashTest:VerifyNotQuickInfoExists(t)
    do
        local isEmpty, hover = self:quickInfoIsEmpty(t)
        if not isEmpty then
            t:Fatalf("Expected empty hover content at marker '%s', got '%s'", self.lastKnownMarkerName, gort.cmp.Diff(hover, nil))
        end
    end
end

function FourslashTest:quickInfoIsEmpty(t)
    local hover = self:getQuickInfoAtCurrentPosition(t)
    if (hover == nil) or ((((hover.contents.markupContent == nil) and (hover.contents.markedStrings == nil)) and (hover.contents.string == nil))) then
        return true, nil
    end
    return false, hover
end

function FourslashTest:VerifyQuickInfoIs(t, expectedText, expectedDocumentation)
    local hover = self:getQuickInfoAtCurrentPosition(t)
    self:verifyHoverContent(t, hover.contents, expectedText, expectedDocumentation, self:getCurrentPositionPrefix())
end

function FourslashTest:VerifyJsxClosingTag(t, markersToNewText)
    for marker, expectedText in gort.pairs(markersToNewText) do
        self:GoToMarker(t, marker)
        local params = lsproto.VSOnAutoInsertParams({
                vsTextDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                vsPosition = self.currentCaretPosition,
                vsCh = ">",
            })
        local requestResult = fourslash.sendRequest(t, self, lsproto.TextDocumentVSOnAutoInsertInfo, params)
        local actualText = nil
        do
            local item = requestResult.vsOnAutoInsertResponseItem
            if (item ~= nil) and (item.vsTextEdit ~= nil) then
                local newText = item.vsTextEdit.newText
                if item.vsTextEditFormat == lsproto.InsertTextFormat.Snippet then
                    local ok = false
                    newText, ok = gort.strings.CutPrefix(newText, "$0")
                    if not ok then
                        t:Fatalf("%sexpected JSX closing tag snippet to begin with $0, got %q", self:getCurrentPositionPrefix(), item.vsTextEdit.newText)
                    end
                end
                actualText = newText
            end
        end
        fourslash.assertDeepEqual(t, actualText, expectedText, self:getCurrentPositionPrefix() .. "JSX closing tag text mismatch")
    end
end

function FourslashTest:VerifyBaselineClosingTags(t)
    t:Helper()
    local markersAndItems = core.MapFiltered(self:Markers(), function(marker)
        if marker.name == nil then
            return {}, false
        end
        local params = lsproto.VSOnAutoInsertParams({
            vsTextDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker:FileName()) }),
            vsPosition = marker.lsPosition,
            vsCh = ">",
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentVSOnAutoInsertInfo, params)
        return fourslash.newMarkerAndItem(marker, result.vsOnAutoInsertResponseItem), true
    end)
    local getRange = function(item)
        return nil
    end
    local getTooltipLines = function(item, _prev)
        if (item == nil) or (item.vsTextEdit == nil) then
            return { "No closing tag" }
        end
        local format = "plaintext"
        if item.vsTextEditFormat == lsproto.InsertTextFormat.Snippet then
            format = "snippet"
        end
        return { gort.fmt.Sprintf("%s: %q", format, item.vsTextEdit.newText) }
    end
    local result = fourslash.annotateContentWithTooltips(t, self, markersAndItems, "closing tag", getRange, getTooltipLines)
    self:addResultToBaseline(t, fourslash.baselineCommand.closingTagCmd, result)
end

function FourslashTest:VerifySignatureHelp(t, expected)
    t:Helper()
    local prefix = self:getCurrentPositionPrefix()
    local params = lsproto.SignatureHelpParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
    local help = result.signatureHelp
    if help == nil then
        t:Fatalf("%sCould not get signature help", prefix)
    end
    local selectedIndex = 0
    if expected.overrideSelectedItemIndex > 0 then
        selectedIndex = expected.overrideSelectedItemIndex
    elseif help.activeSignature ~= nil then
        selectedIndex = help.activeSignature
    end
    if selectedIndex >= gort.len(help.signatures) then
        t:Fatalf("%sSelected signature index %d out of range (have %d signatures)", prefix, selectedIndex, gort.len(help.signatures))
    end
    local selectedSig = help.signatures[selectedIndex + 1]
    if expected.overloadsCount > 0 then
        if gort.len(help.signatures) ~= expected.overloadsCount then
            t:Errorf("%sExpected %d overloads, got %d", prefix, expected.overloadsCount, gort.len(help.signatures))
        end
    end
    if expected.text ~= "" then
        if selectedSig.label ~= expected.text then
            t:Errorf("%sExpected signature text %q, got %q", prefix, expected.text, selectedSig.label)
        end
    end
    if expected.docComment ~= "" then
        local actualDoc = ""
        if selectedSig.documentation ~= nil then
            if selectedSig.documentation.markupContent ~= nil then
                actualDoc = selectedSig.documentation.markupContent.value
            elseif selectedSig.documentation.string ~= nil then
                actualDoc = selectedSig.documentation.string
            end
        end
        if actualDoc ~= expected.docComment then
            t:Errorf("%sExpected doc comment %q, got %q", prefix, expected.docComment, actualDoc)
        end
    end
    if expected.parameterCount > 0 then
        local paramCount = 0
        if selectedSig.parameters ~= nil then
            paramCount = gort.len(selectedSig.parameters)
        end
        if paramCount ~= expected.parameterCount then
            t:Errorf("%sExpected %d parameters, got %d", prefix, expected.parameterCount, paramCount)
        end
    end
    local activeParamIndex = 0
    if (selectedSig.activeParameter ~= nil) and (selectedSig.activeParameter.uinteger ~= nil) then
        activeParamIndex = selectedSig.activeParameter.uinteger
    elseif (help.activeParameter ~= nil) and (help.activeParameter.uinteger ~= nil) then
        activeParamIndex = help.activeParameter.uinteger
    end
    local activeParam = nil
    if (selectedSig.parameters ~= nil) and (activeParamIndex < gort.len(selectedSig.parameters)) then
        activeParam = (selectedSig.parameters)[activeParamIndex + 1]
    end
    if expected.parameterName ~= "" then
        if activeParam == nil then
            t:Errorf("%sExpected parameter name %q, but no active parameter", prefix, expected.parameterName)
        else
            local actualName = ""
            if activeParam.label.string ~= nil then
                local label = activeParam.label.string
                label = gort.strings.TrimPrefix(label, "...")
                do
                    local name, _, found = gort.strings.Cut(label, ":")
                    if found then
                        actualName = gort.strings.TrimSpace(name)
                    else
                        do
                            local name, _, found = gort.strings.Cut(label, " extends ")
                            if found then
                                actualName = gort.strings.TrimSpace(name)
                            else
                                actualName = label
                            end
                        end
                    end
                end
            end
            if actualName ~= expected.parameterName then
                t:Errorf("%sExpected parameter name %q, got %q", prefix, expected.parameterName, actualName)
            end
        end
    end
    if expected.parameterSpan ~= "" then
        if activeParam == nil then
            t:Errorf("%sExpected parameter span %q, but no active parameter", prefix, expected.parameterSpan)
        else
            local actualSpan = ""
            if activeParam.label.string ~= nil then
                actualSpan = activeParam.label.string
            end
            if actualSpan ~= expected.parameterSpan then
                t:Errorf("%sExpected parameter span %q, got %q", prefix, expected.parameterSpan, actualSpan)
            end
        end
    end
    if expected.parameterDocComment ~= "" then
        if activeParam == nil then
            t:Errorf("%sExpected parameter doc comment %q, but no active parameter", prefix, expected.parameterDocComment)
        else
            local actualDoc = ""
            if activeParam.documentation ~= nil then
                if activeParam.documentation.markupContent ~= nil then
                    actualDoc = activeParam.documentation.markupContent.value
                elseif activeParam.documentation.string ~= nil then
                    actualDoc = activeParam.documentation.string
                end
            end
            if actualDoc ~= expected.parameterDocComment then
                t:Errorf("%sExpected parameter doc comment %q, got %q", prefix, expected.parameterDocComment, actualDoc)
            end
        end
    end
    if expected.isVariadicSet then
        local actualIsVariadic = false
        if selectedSig.parameters ~= nil then
            for i199, param in gort.ipairs(selectedSig.parameters) do
                if (param.label.string ~= nil) and gort.strings.HasPrefix(param.label.string, "...") then
                    actualIsVariadic = true
                    break
                end
            end
        end
        if actualIsVariadic ~= expected.isVariadic then
            t:Errorf("%sExpected isVariadic=%v, got %v", prefix, expected.isVariadic, actualIsVariadic)
        end
    end
end

function FourslashTest:VerifyNoSignatureHelp(t)
    t:Helper()
    local prefix = self:getCurrentPositionPrefix()
    local params = lsproto.SignatureHelpParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
    if (result.signatureHelp ~= nil) and (gort.len(result.signatureHelp.signatures) > 0) then
        t:Errorf("%sExpected no signature help, but got %d signatures", prefix, gort.len(result.signatureHelp.signatures))
    end
end

function FourslashTest:VerifyNoSignatureHelpWithContext(t, context_)
    t:Helper()
    local prefix = self:getCurrentPositionPrefix()
    local params = lsproto.SignatureHelpParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
        context = context_,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
    if (result.signatureHelp ~= nil) and (gort.len(result.signatureHelp.signatures) > 0) then
        t:Errorf("%sExpected no signature help, but got %d signatures", prefix, gort.len(result.signatureHelp.signatures))
    end
end

function FourslashTest:VerifyNoSignatureHelpForMarkersWithContext(t, context_, ...)
    local markers = { ... }
    t:Helper()
    for i201, marker in gort.ipairs(markers) do
        self:GoToMarker(t, marker)
        self:VerifyNoSignatureHelpWithContext(t, context_)
    end
end

function FourslashTest:VerifySignatureHelpPresent(t, context_)
    t:Helper()
    local prefix = self:getCurrentPositionPrefix()
    local params = lsproto.SignatureHelpParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
        context = context_,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
    if (result.signatureHelp == nil) or (gort.len(result.signatureHelp.signatures) == 0) then
        t:Errorf("%sExpected signature help to be present, but got none", prefix)
    end
end

function FourslashTest:VerifySignatureHelpPresentForMarkers(t, context_, ...)
    local markers = { ... }
    t:Helper()
    for i203, marker in gort.ipairs(markers) do
        self:GoToMarker(t, marker)
        self:VerifySignatureHelpPresent(t, context_)
    end
end

function FourslashTest:VerifyNoSignatureHelpForMarkers(t, ...)
    local markers = { ... }
    t:Helper()
    for i205, marker in gort.ipairs(markers) do
        self:GoToMarker(t, marker)
        self:VerifyNoSignatureHelp(t)
    end
end

function FourslashTest:VerifySignatureHelpWithCases(t, ...)
    local signatureHelpCases = { ... }
    for i207, option in gort.ipairs(signatureHelpCases) do
        local ts209 = option.markerInput
        if type(ts209) == "string" then
            local marker = ts209
            self:GoToMarker(t, marker)
            self:verifySignatureHelp(t, option.context, option.expected)
        elseif gort.IsStruct(ts209, "tslua.fourslash", "Marker") then
            local marker = ts209
            self:goToMarker(t, marker)
            self:verifySignatureHelp(t, option.context, option.expected)
        elseif gort.IsSlice(ts209, function(e) return type(e) == "string" end) then
            local marker = ts209
            for i210, markerName in gort.ipairs(marker) do
                self:GoToMarker(t, markerName)
                self:verifySignatureHelp(t, option.context, option.expected)
            end
        elseif gort.IsSlice(ts209, function(e) return gort.IsStruct(e, "tslua.fourslash", "Marker") end) then
            local marker = ts209
            for i212, marker in gort.ipairs(marker) do
                self:goToMarker(t, marker)
                self:verifySignatureHelp(t, option.context, option.expected)
            end
        elseif ts209 == nil then
            local marker = ts209
            self:verifySignatureHelp(t, option.context, option.expected)
        else
            local marker = ts209
            t:Fatalf("Invalid marker input type: %T. Expected string, *Marker, []string, or []*Marker.", option.markerInput)
        end
    end
end

function FourslashTest:verifySignatureHelp(t, context_, expected)
    local prefix = self:getCurrentPositionPrefix()
    local params = lsproto.SignatureHelpParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
        context = context_,
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSignatureHelpInfo, params)
    self:verifySignatureHelpResult(t, result.signatureHelp, expected, prefix)
end

function FourslashTest:verifySignatureHelpResult(t, actual, expected, prefix)
    fourslash.assertDeepEqual(t, actual, expected, prefix .. " SignatureHelp mismatch")
end

function FourslashTest:getCurrentPositionPrefix()
    if self.lastKnownMarkerName ~= nil then
        return gort.fmt.Sprintf("At marker '%s': ", self.lastKnownMarkerName)
    end
    return gort.fmt.Sprintf("At position %s(Ln %d, Col %d): ", self.activeFilename, self.currentCaretPosition.line, self.currentCaretPosition.character)
end

function FourslashTest:BaselineAutoImportsCompletions(t, markerNames)
    t:Helper()
    local reset = self:ConfigureWithReset(t, setmetatable({
        includeCompletionsForModuleExports = core.Tristate.TSTrue,
        includeCompletionsForImportStatements = core.Tristate.TSTrue,
        importModuleSpecifierPreference = self.userPreferences.importModuleSpecifierPreference,
        importModuleSpecifierEnding = self.userPreferences.importModuleSpecifierEnding,
        autoImportSpecifierExcludeRegexes = self.userPreferences.autoImportSpecifierExcludeRegexes,
        autoImportFileExcludePatterns = self.userPreferences.autoImportFileExcludePatterns,
        preferTypeOnlyAutoImports = self.userPreferences.preferTypeOnlyAutoImports,
        autoImportEntrypointDirectorySearch = self.userPreferences.autoImportEntrypointDirectorySearch,
        formatCodeSettings = setmetatable({
        baseIndentSize = 0,
        indentSize = 0,
        tabSize = 0,
        newLineCharacter = "",
        convertTabsToSpaces = 0,
        indentStyle = 0,
        trimTrailingWhitespace = 0,
        insertSpaceAfterCommaDelimiter = 0,
        insertSpaceAfterSemicolonInForStatements = 0,
        insertSpaceBeforeAndAfterBinaryOperators = 0,
        insertSpaceAfterConstructor = 0,
        insertSpaceAfterKeywordsInControlFlowStatements = 0,
        insertSpaceAfterFunctionKeywordForAnonymousFunctions = 0,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis = 0,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets = 0,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces = 0,
        insertSpaceAfterOpeningAndBeforeClosingEmptyBraces = 0,
        insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces = 0,
        insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces = 0,
        insertSpaceAfterTypeAssertion = 0,
        insertSpaceBeforeFunctionParenthesis = 0,
        placeOpenBraceOnNewLineForFunctions = 0,
        placeOpenBraceOnNewLineForControlBlocks = 0,
        insertSpaceBeforeTypeAnnotation = 0,
        indentMultiLineObjectLiteralBeginningOnBlankLine = 0,
        semicolons = "",
        indentSwitchCase = 0,
    }, lsutil.FormatCodeSettings),
        quotePreference = "",
        lazyConfiguredProjectsFromExternalProject = 0,
        maximumHoverLength = 0,
        includeAutomaticOptionalChainCompletions = 0,
        includeCompletionsWithClassMemberSnippets = 0,
        includeCompletionsWithObjectLiteralMethodSnippets = 0,
        jsxAttributeCompletionStyle = "",
        enableAutoClosingTags = 0,
        enableJSDocCompletions = 0,
        generateReturnInDocTemplate = 0,
        organizeImportsSort = 0,
        organizeImportsIgnoreCase = 0,
        organizeImportsCollation = false,
        organizeImportsLocale = "",
        organizeImportsNumericCollation = 0,
        organizeImportsAccentCollation = 0,
        organizeImportsCaseFirst = 0,
        organizeImportsTypeOrder = 0,
        allowTextChangesInNewFiles = 0,
        useAliasesForRename = 0,
        allowRenameOfImportPath = 0,
        provideRefactorNotApplicableReason = 0,
        inlayHints = {
        includeInlayParameterNameHints = "",
        includeInlayParameterNameHintsWhenArgumentMatchesName = 0,
        includeInlayFunctionParameterTypeHints = 0,
        includeInlayVariableTypeHints = 0,
        includeInlayVariableTypeHintsWhenTypeMatchesName = 0,
        includeInlayPropertyDeclarationTypeHints = 0,
        includeInlayFunctionLikeReturnTypeHints = 0,
        includeInlayEnumMemberValueHints = 0,
    },
        codeLens = {
        referencesCodeLensEnabled = 0,
        implementationsCodeLensEnabled = 0,
        referencesCodeLensShowOnAllFunctions = 0,
        implementationsCodeLensShowOnInterfaceMethods = 0,
        implementationsCodeLensShowOnAllClassMethods = 0,
    },
        preferGoToSourceDefinition = false,
        excludeLibrarySymbolsInNavTo = 0,
        workspaceSymbolsScope = "",
        enableFormatting = 0,
        enableValidation = 0,
        disableSuggestions = 0,
        disableLineTextInReferences = 0,
        displayPartsForJSDoc = 0,
        reportStyleChecksAsWarnings = 0,
        locale = "",
        disableAutomaticTypeAcquisition = 0,
        automaticTypeAcquisitionEnabled = 0,
        customConfigFileName = "",
    }, lsutil.UserPreferences))
    gort.Defer(reset, function()
        for i214, markerName in gort.ipairs(markerNames) do
            do
                self:GoToMarker(t, markerName)
                local params = lsproto.CompletionParams({
                    textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                    position = self.currentCaretPosition,
                    context = lsproto.CompletionContext({}),
                })
                local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCompletionInfo, params)
                local prefix = gort.fmt.Sprintf("At marker '%s': ", markerName)
                self:writeToBaseline(fourslash.baselineCommand.autoImportsCmd, "// === Auto Imports === \n")
                local fileContent, ok = self:textOfFile(self.activeFilename)
                if not ok then
                    t:Fatalf(prefix .. "Failed to read file %s for auto-import baseline", self.activeFilename)
                end
                local marker = self.testData.markerPositions[markerName]
                local ext = gort.strings.TrimPrefix(tspath.GetAnyExtensionFromPath(self.activeFilename, nil, true), ".")
                local lang = core.IfElse((ext == "mts") or (ext == "cts"), "ts", ext)
                self:writeToBaseline(fourslash.baselineCommand.autoImportsCmd, fourslash.codeFence(lang, (((((("// @FileName: " .. self.activeFilename) .. "\n") .. string.sub(fileContent, 1, marker.position)) .. "/*") .. markerName) .. "*/") .. string.sub(fileContent, marker.position + 1)))
                local currentFile = fourslash.newScriptInfo(self.activeFilename, fileContent)
                local converters = fourslash.newTestConverters(lsconv.NewConverters(lsproto.PositionEncodingKind.UTF8, function(_p216)
                    return currentFile.lineMap
                end))
                local list = nil
                if (result.items == nil) or (gort.len(result.items) == 0) then
                    if ((result.list == nil) or (result.list.items == nil)) or (gort.len(result.list.items) == 0) then
                        self:writeToBaseline(fourslash.baselineCommand.autoImportsCmd, "no autoimport completions found\n\n")
                        goto continue215
                    end
                    list = result.list.items
                else
                    list = result.items
                end
                for i217, item in gort.ipairs(list) do
                    do
                        if (item.data == nil) or (item.sortText ~= ls.SortText.AutoImportSuggestions) then
                            goto continue218
                        end
                        local details = fourslash.sendRequest(t, self, lsproto.CompletionItemResolveInfo, item)
                        if ((details == nil) or (details.additionalTextEdits == nil)) or (gort.len(details.additionalTextEdits) == 0) then
                            t:Fatalf(prefix .. "Entry %s from %s returned no code changes from completion details request", item.label, item.detail)
                        end
                        local allChanges = details.additionalTextEdits
                        gort.slices.SortFunc(allChanges, function(a, b)
                            return lsproto.ComparePositions(b.range.start, a.range.start)
                        end)
                        local newFileContent = fileContent
                        for i219, change in gort.ipairs(allChanges) do
                            newFileContent = (string.sub(newFileContent, 1, converters:LineAndCharacterToPosition(currentFile, change.range.start)) .. change.newText) .. string.sub(newFileContent, converters:LineAndCharacterToPosition(currentFile, change.range.end_) + 1)
                        end
                        self:writeToBaseline(fourslash.baselineCommand.autoImportsCmd, fourslash.codeFence(lang, newFileContent) .. "\n\n")
                    end
                    ::continue218::
                end
            end
            ::continue215::
        end
    end)
end

function FourslashTest:VerifyBaselineRename(t, preferences, ...)
    local markerOrNameOrRanges = { ... }
    local markerOrRanges = nil
    for i221, markerOrNameOrRange in gort.ipairs(markerOrNameOrRanges) do
        local ts223 = markerOrNameOrRange
        if type(ts223) == "string" then
            local markerOrNameOrRange = ts223
            local marker, ok = gort.MapLookup(self.testData.markerPositions, markerOrNameOrRange, nil)
            if not ok then
                t:Fatalf("Marker '%s' not found", markerOrNameOrRange)
            end
            markerOrRanges = gort.append(markerOrRanges, marker)
        elseif gort.IsStruct(ts223, "tslua.fourslash", "Marker") then
            local markerOrNameOrRange = ts223
            markerOrRanges = gort.append(markerOrRanges, markerOrNameOrRange)
        elseif gort.IsStruct(ts223, "tslua.fourslash", "RangeMarker") then
            local markerOrNameOrRange = ts223
            markerOrRanges = gort.append(markerOrRanges, markerOrNameOrRange)
        else
            local markerOrNameOrRange = ts223
            t:Fatalf("Invalid marker or range type: %T. Expected string, *Marker, or *RangeMarker.", markerOrNameOrRange)
        end
    end
    self:verifyBaselineRename(t, preferences, markerOrRanges)
end

function FourslashTest:verifyBaselineRename(t, preferences, markerOrRanges)
    local defers224 = {}
    gort.WithDefers(defers224, function()
        if preferences ~= nil then
            local deferred225 = self:ConfigureWithReset(t, preferences)
            defers224[#defers224 + 1] = deferred225
        end
        for i226, markerOrRange in gort.ipairs(markerOrRanges) do
            self:GoToMarkerOrRange(t, markerOrRange)
            local params = lsproto.RenameParams({
                    textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                    position = self.currentCaretPosition,
                    newName = "?",
                })
            local result = fourslash.sendRequest(t, self, lsproto.TextDocumentRenameInfo, params)
            local changes = nil
            if (result.workspaceEdit ~= nil) and (result.workspaceEdit.changes ~= nil) then
                changes = result.workspaceEdit.changes
            end
            local spanToText = {}
            local fileToSpan = collections.NewMultiMap()
            for uri, edits in gort.pairs(changes) do
                for i229, edit in gort.ipairs(edits) do
                    local span = { uri = uri, textSpan = edit.range }
                    fileToSpan:Add(uri, span)
                    spanToText[gort.Key(span)] = edit.newText
                end
            end
            local renameOptions = gort.NewBuilder()
            if preferences ~= nil then
                if preferences.useAliasesForRename ~= core.Tristate.TSUnknown then
                    gort.fmt.Fprintf(renameOptions, "// @useAliasesForRename: %v\n", core.Tristate_IsTrue(preferences.useAliasesForRename))
                end
                if preferences.quotePreference ~= lsutil.QuotePreference.Unknown then
                    gort.fmt.Fprintf(renameOptions, "// @quotePreference: %v\n", preferences.quotePreference)
                end
            end
            local baselineFileContent = self:getBaselineForGroupedSpansWithFileContents(fileToSpan, {
                    marker = markerOrRange,
                    markerName = "/*RENAME*/",
                    endMarker = "RENAME|]",
                    startMarkerPrefix = function(span)
                        local text = (spanToText[gort.Key(span)] or "")
                        local prefixAndSuffix = gort.strings.Split(text, "?")
                        if prefixAndSuffix[1] ~= "" then
                            return "/*START PREFIX*/" .. prefixAndSuffix[1]
                        end
                        return nil
                    end,
                    endMarkerSuffix = function(span)
                        local text = (spanToText[gort.Key(span)] or "")
                        local prefixAndSuffix = gort.strings.Split(text, "?")
                        if prefixAndSuffix[2] ~= "" then
                            return prefixAndSuffix[2] .. "/*END SUFFIX*/"
                        end
                        return nil
                    end,
                    preserveResultOrder = false,
                })
            local baselineResult = ""
            if renameOptions:Len() > 0 then
                baselineResult = (renameOptions:String() .. "\n") .. baselineFileContent
            else
                baselineResult = baselineFileContent
            end
            self:addResultToBaseline(t, fourslash.baselineCommand.renameCmd, baselineResult)
        end
    end)
end

function FourslashTest:VerifyRenameSucceeded(t, preferences)
    local defers231 = {}
    gort.WithDefers(defers231, function()
        if preferences ~= nil then
            local deferred232 = self:ConfigureWithReset(t, preferences)
            defers231[#defers231 + 1] = deferred232
        end
        local params = lsproto.PrepareRenameParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
        })
        local prefix = self:getCurrentPositionPrefix()
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentPrepareRenameInfo, params)
        if ((result.range == nil) and (result.prepareRenamePlaceholder == nil)) and (result.prepareRenameDefaultBehavior == nil) then
            t:Fatal(prefix .. "Expected rename to succeed, but prepareRename returned null")
        end
        local renameResult = fourslash.sendRequest(t, self, lsproto.TextDocumentRenameInfo, lsproto.RenameParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
            newName = "RENAME_SUCCEEDED_TEST",
        }))
        if ((renameResult.workspaceEdit == nil) or (renameResult.workspaceEdit.changes == nil)) or (gort.len(renameResult.workspaceEdit.changes) == 0) then
            t:Fatal(prefix .. "prepareRename succeeded but textDocument/rename returned no changes")
        end
    end)
end

function FourslashTest:VerifyRenameRange(t, expectedRange, expectedPlaceholder, preferences)
    local defers233 = {}
    gort.WithDefers(defers233, function()
        t:Helper()
        if preferences ~= nil then
            local deferred234 = self:ConfigureWithReset(t, preferences)
            defers233[#defers233 + 1] = deferred234
        end
        local params = lsproto.PrepareRenameParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentPrepareRenameInfo, params)
        if result.prepareRenamePlaceholder == nil then
            t:Fatal(self:getCurrentPositionPrefix() .. "Expected prepareRename to return a range and placeholder")
        end
        gort.assert.DeepEqual(t, result.prepareRenamePlaceholder.range, expectedRange)
        gort.assert.Equal(t, result.prepareRenamePlaceholder.placeholder, expectedPlaceholder)
    end)
end

function FourslashTest:RenameAtCaret(t, newName)
    t:Helper()
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentRenameInfo, lsproto.RenameParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        position = self.currentCaretPosition,
        newName = newName,
    }))
    if result.workspaceEdit == nil then
        return result
    end
    if result.workspaceEdit.changes ~= nil then
        for uri, edits in gort.pairs(result.workspaceEdit.changes) do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local script = self:getOrLoadScriptInfo(fileName)
            local changes = core.Map(edits, function(edit)
                    return gort.Embed(setmetatable({ newText = edit.newText }, core.TextChange), self:fromLSPRange(script, edit.range))
                end)
            self:editScriptAndUpdateMarkersWorker(t, fileName, changes)
        end
    end
    local renameFiles = nil
    if result.workspaceEdit.documentChanges ~= nil then
        for i236, docChange in gort.ipairs(result.workspaceEdit.documentChanges) do
            if docChange.textDocumentEdit ~= nil then
                local fileName = lsproto.DocumentUri_FileName(docChange.textDocumentEdit.textDocument.uri)
                local script = self:getOrLoadScriptInfo(fileName)
                local changes = core.Map(docChange.textDocumentEdit.edits, function(edit)
                        local textEdit = edit.textEdit
                        return gort.Embed(setmetatable({ newText = textEdit.newText }, core.TextChange), self:fromLSPRange(script, textEdit.range))
                    end)
                self:editScriptAndUpdateMarkersWorker(t, fileName, changes)
            elseif docChange.renameFile ~= nil then
                renameFiles = gort.append(renameFiles, docChange.renameFile)
            end
        end
    end
    if gort.len(renameFiles) > 0 then
        local fileRenames = nil
        for i238, renameFile in gort.ipairs(renameFiles) do
            fileRenames = gort.append(fileRenames, lsproto.FileRename({ oldUri = renameFile.oldUri, newUri = renameFile.newUri }))
        end
        if ((((self.capabilities ~= nil) and (self.capabilities.workspace ~= nil)) and (self.capabilities.workspace.fileOperations ~= nil)) and (self.capabilities.workspace.fileOperations.willRename ~= nil)) and self.capabilities.workspace.fileOperations.willRename then
            self:willRenameFilesWorker(t, gort.unpack(fileRenames))
        else
            for i240, renameFile in gort.ipairs(renameFiles) do
                self:renameFileOrDirectory(t, lsproto.DocumentUri_FileName(renameFile.oldUri), lsproto.DocumentUri_FileName(renameFile.newUri))
            end
        end
    end
    return result
end

function FourslashTest:WillRenameFiles(t, ...)
    local files = { ... }
    t:Helper()
    return fourslash.sendRequest(t, self, lsproto.WorkspaceWillRenameFilesInfo, lsproto.RenameFilesParams({ files = files }))
end

function FourslashTest:willRenameFilesWorker(t, ...)
    local files = { ... }
    t:Helper()
    local result = self:WillRenameFiles(t, gort.unpack(files))
    if result.workspaceEdit == nil then
        for i242, file in gort.ipairs(files) do
            local oldPath = lsproto.DocumentUri_FileName(file.oldUri)
            local newPath = lsproto.DocumentUri_FileName(file.newUri)
            self:renameFileOrDirectory(t, oldPath, newPath)
        end
        return
    end
    if result.workspaceEdit.changes ~= nil then
        for uri, edits in gort.pairs(result.workspaceEdit.changes) do
            local fileName = lsproto.DocumentUri_FileName(uri)
            local script = self:getOrLoadScriptInfo(fileName)
            local changes = core.Map(edits, function(edit)
                    return gort.Embed(setmetatable({ newText = edit.newText }, core.TextChange), self:fromLSPRange(script, edit.range))
                end)
            self:editScriptAndUpdateMarkersWorker(t, fileName, changes)
        end
    end
    local renameFiles = nil
    if result.workspaceEdit.documentChanges ~= nil then
        for i245, docChange in gort.ipairs(result.workspaceEdit.documentChanges) do
            if docChange.textDocumentEdit ~= nil then
                local fileName = lsproto.DocumentUri_FileName(docChange.textDocumentEdit.textDocument.uri)
                local script = self:getOrLoadScriptInfo(fileName)
                local changes = core.Map(docChange.textDocumentEdit.edits, function(edit)
                        local textEdit = edit.textEdit
                        return gort.Embed(setmetatable({ newText = textEdit.newText }, core.TextChange), self:fromLSPRange(script, textEdit.range))
                    end)
                self:editScriptAndUpdateMarkersWorker(t, fileName, changes)
            elseif docChange.renameFile ~= nil then
                renameFiles = gort.append(renameFiles, docChange.renameFile)
            end
        end
    end
    local fileRenames = nil
    for i247, renameFile in gort.ipairs(renameFiles) do
        fileRenames = gort.append(fileRenames, lsproto.FileRename({ oldUri = renameFile.oldUri, newUri = renameFile.newUri }))
    end
    self:willRenameFilesWorker(t, gort.unpack(fileRenames))
    for i249, file in gort.ipairs(files) do
        local oldPath = lsproto.DocumentUri_FileName(file.oldUri)
        local newPath = lsproto.DocumentUri_FileName(file.newUri)
        self:renameFileOrDirectory(t, oldPath, newPath)
    end
end

function FourslashTest:VerifyRename(t, markerName, newName, expectedFileContents)
    t:Helper()
    self:GoToMarker(t, markerName)
    self:RenameAtCaret(t, newName)
    for fileName, expectedContent in gort.pairs(expectedFileContents) do
        local script = self:getScriptInfo(fileName)
        if script == nil then
            t:Fatalf("Expected script info for %s, but got nil", fileName)
        end
        gort.assert.Equal(t, script.content, expectedContent, gort.fmt.Sprintf("File content after rename did not match expected content for %s.", fileName))
    end
end

function FourslashTest:VerifyWillRenameFilesEdits(t, oldPath, newPath, expectedFileContents, preferences)
    local defers252 = {}
    gort.WithDefers(defers252, function()
        t:Helper()
        if preferences ~= nil then
            local deferred253 = self:ConfigureWithReset(t, preferences)
            defers252[#defers252 + 1] = deferred253
        end
        self:willRenameFilesWorker(t, lsproto.FileRename({ oldUri = lsconv.FileNameToDocumentURI(oldPath), newUri = lsconv.FileNameToDocumentURI(newPath) }))
        for fileName, expectedContent in gort.pairs(expectedFileContents) do
            local script = self:getOrLoadScriptInfo(fileName)
            if script == nil then
                t:Fatalf("Expected script info for %s, but got nil", fileName)
            end
            gort.assert.Equal(t, script.content, expectedContent, gort.fmt.Sprintf("File content after workspace/willRenameFiles edits did not match expected content for %s.", fileName))
        end
    end)
end

function FourslashTest:getPathUpdater(oldPath, newPath)
    do return function(path)
        local compareOptions = setmetatable({ useCaseSensitiveFileNames = self.vfs:UseCaseSensitiveFileNames(), currentDirectory = "" }, tspath.ComparePathsOptions)
        if tspath.ComparePaths(path, oldPath, compareOptions) == 0 then
            return newPath, true
        end
        if tspath.StartsWithDirectory(path, oldPath, self.vfs:UseCaseSensitiveFileNames()) then
            return newPath .. string.sub(path, #oldPath + 1), true
        end
        return "", false
    end end
end

function FourslashTest:renameFileOrDirectory(t, oldPath, newPath)
    t:Helper()
    local pathUpdater = self:getPathUpdater(oldPath, newPath)
    local oldFileNames = {}
    do
        local _, ok = self.vfs:ReadFile(oldPath)
        if ok then
            oldFileNames[oldPath] = fourslash.Ignored
        else
            local walkErr = self.vfs:WalkDir(oldPath, function(path, d, err)
                if err ~= nil then
                    return err
                end
                if not d:IsDir() then
                    oldFileNames[path] = fourslash.Ignored
                end
                return nil
            end)
            if walkErr ~= nil then
                t:Fatalf("failed to collect files for rename %s -> %s: %v", oldPath, newPath, walkErr)
            end
        end
    end
    if gort.len(oldFileNames) == 0 then
        t:Fatalf("rename source %s did not exist in test environment", oldPath)
    end
    local fileEvents = gort.makeSlice(0, function() return nil end)
    local reopenAtNewPath = {}
    for oldFileName, _ in gort.pairs(oldFileNames) do
        local newFileName, updated = pathUpdater(oldFileName)
        if not updated then
            t:Fatalf("failed to compute renamed path for %s", oldFileName)
        end
        do
            local _, isOpen = gort.MapLookup(self.openFiles, oldFileName, nil)
            if isOpen then
                local script = self.scriptInfos[oldFileName]
                reopenAtNewPath[newFileName] = script.content
                fourslash.sendNotification(t, self, lsproto.TextDocumentDidCloseInfo, lsproto.DidCloseTextDocumentParams({
                        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(oldFileName) }),
                    }))
                gort.delete(self.openFiles, oldFileName)
            end
        end
        self.scriptInfos[newFileName] = fourslash.newScriptInfo(newFileName, self.scriptInfos[oldFileName].content)
        gort.delete(self.scriptInfos, oldFileName)
        local content
        content, updated = self.vfs:ReadFile(oldFileName)
        if not updated then
            t:Fatalf("failed to read content for %s during rename to %s", oldFileName, newFileName)
        end
        do
            local err = self.vfs:WriteFile(newFileName, content)
            if err ~= nil then
                t:Fatalf("failed to write renamed file %s: %v", newFileName, err)
            end
        end
        fileEvents = gort.append(fileEvents, lsproto.FileEvent({ uri = lsconv.FileNameToDocumentURI(oldFileName), type = lsproto.FileChangeType.Deleted }), lsproto.FileEvent({ uri = lsconv.FileNameToDocumentURI(newFileName), type = lsproto.FileChangeType.Created }))
    end
    do
        local err = self.vfs:Remove(oldPath)
        if err ~= nil then
            t:Fatalf("failed to remove old path %s: %v", oldPath, err)
        end
    end
    fourslash.sendNotification(t, self, lsproto.WorkspaceDidChangeWatchedFilesInfo, lsproto.DidChangeWatchedFilesParams({ changes = fileEvents }))
    for newFileName, content in gort.pairs(reopenAtNewPath) do
        fourslash.sendNotification(t, self, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
                textDocument = lsproto.TextDocumentItem({
                    uri = lsconv.FileNameToDocumentURI(newFileName),
                    languageId = fourslash.getLanguageKind(newFileName),
                    text = content,
                }),
            }))
        self.openFiles[newFileName] = fourslash.Ignored
    end
    do
        local updatedActive, ok = pathUpdater(self.activeFilename)
        if ok then
            self.activeFilename = updatedActive
        end
    end
end

function FourslashTest:VerifyRenameFailed(t, preferences)
    local defers257 = {}
    gort.WithDefers(defers257, function()
        if preferences ~= nil then
            local deferred258 = self:ConfigureWithReset(t, preferences)
            defers257[#defers257 + 1] = deferred258
        end
        local params = lsproto.PrepareRenameParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
        })
        local prefix = self:getCurrentPositionPrefix()
        self:baselineState(t)
        self:baselineRequestOrNotification(t, lsproto.TextDocumentPrepareRenameInfo.Method, params)
        local resMsg, result, _ = lsptestutil.SendRequest(t, self.client, lsproto.TextDocumentPrepareRenameInfo, params)
        self:baselineState(t)
        if (resMsg ~= nil) and (resMsg:AsResponse().error ~= nil) then
        elseif ((result.range ~= nil) or (result.prepareRenamePlaceholder ~= nil)) or (result.prepareRenameDefaultBehavior ~= nil) then
            t:Fatalf("%sExpected rename to fail, but prepareRename returned a result", prefix)
        end
        local renameMsg, renameResult, _ = lsptestutil.SendRequest(t, self.client, lsproto.TextDocumentRenameInfo, lsproto.RenameParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
            newName = "RENAME_FAILED_TEST",
        }))
        if (renameMsg ~= nil) and (renameMsg:AsResponse().error ~= nil) then
            return
        end
        if ((renameResult.workspaceEdit ~= nil) and (renameResult.workspaceEdit.changes ~= nil)) and (gort.len(renameResult.workspaceEdit.changes) > 0) then
            t:Fatalf("%sprepareRename returned null but textDocument/rename returned changes", prefix)
        end
    end)
end

function FourslashTest:VerifyBaselineRenameAtRangesWithText(t, preferences, ...)
    local texts = { ... }
    local markerOrRanges = nil
    for i259, text in gort.ipairs(texts) do
        local ranges = core.Map(self:GetRangesByText():Get(text), function(r)
                return r
            end)
        markerOrRanges = gort.appendSlice(markerOrRanges, ranges)
    end
    self:verifyBaselineRename(t, preferences, markerOrRanges)
end

function FourslashTest:GetRangesByText()
    if self.rangesByText ~= nil then
        return self.rangesByText
    end
    local rangesByText = collections.NewMultiMap()
    for i261, r in gort.ipairs(self.testData.ranges) do
        local rangeText = self:getRangeText(r)
        rangesByText:Add(rangeText, r)
    end
    self.rangesByText = rangesByText
    return rangesByText
end

function FourslashTest:getRangeText(r)
    local script = self:getScriptInfo(r:FileName())
    return string.sub(script.content, r.range:Pos() + 1, r.range:End())
end

function FourslashTest:verifyBaselines(t, testPath)
    if not self.testData:isStateBaseliningEnabled() then
        for command, content in gort.pairs(self.baselines) do
            baseline.Run(t, fourslash.getBaselineFileName(t, command), content:String(), self:getBaselineOptions(command, testPath))
        end
    else
        baseline.Run(t, fourslash.getBaseFileNameFromTest(t) .. ".baseline", self.stateBaseline.baseline:String(), {
            subfolder = "fourslash/state",
            isSubmodule = false,
            isSubmoduleAccepted = false,
            isSubmoduleTriaged = false,
            skipDiffWithOld = false,
        })
    end
end

function FourslashTest:VerifyBaselineInlayHints(t, span, testPreferences)
    local fileName = self.activeFilename
    local lspRange = lsproto.Range({})
    if span == nil then
        local _
        lspRange, _ = self.converters:ToLSPRange(self:getScriptInfo(fileName), core.NewTextRange(0, #self.scriptInfos[fileName].content))
    else
        lspRange = gort.CloneStruct(span)
    end
    local params = lsproto.InlayHintParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(fileName) }),
        range = lspRange,
    })
    local preferences = testPreferences
    if preferences == nil then
        preferences = lsutil.NewDefaultUserPreferences()
    end
    local reset = self:ConfigureWithReset(t, preferences)
    gort.Defer(reset, function()
        local prefix = gort.fmt.Sprintf("At position (Ln %d, Col %d): ", lspRange.start.line, lspRange.start.character)
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentInlayHintInfo, params)
        local fileLines = gort.strings.Split(self:getScriptInfo(fileName).content, "\n")
        local annotations = nil
        if result.inlayHints ~= nil then
            gort.slices.SortFunc(result.inlayHints, function(a, b)
                return lsproto.ComparePositions(a.position, b.position)
            end)
            annotations = core.Map(result.inlayHints, function(hint)
                if hint.label.inlayHintLabelParts ~= nil then
                    for i264, part in gort.ipairs(hint.label.inlayHintLabelParts) do
                        if (part.location ~= nil) and fourslash.isLibFile(lsproto.DocumentUri_FileName(part.location.uri)) then
                            part.location.range.start = lsproto.Position({ line = 0, character = 0 })
                            part.location.range.end_ = lsproto.Position({ line = 0, character = 0 })
                        end
                    end
                end
                local underline = gort.strings.Repeat(" ", hint.position.character) .. "^"
                local hintJson, err = core.StringifyJson(hint, "", "  ")
                if err ~= nil then
                    t:Fatalf(prefix .. "Failed to stringify inlay hint for baseline: %v", err)
                end
                local annotation = fileLines[hint.position.line + 1]
                annotation = annotation .. ((("\n" .. underline) .. "\n") .. hintJson)
                return annotation
            end)
        end
        if gort.len(annotations) == 0 then
            annotations = gort.append(annotations, "=== No inlay hints ===")
        end
        self:addResultToBaseline(t, fourslash.baselineCommand.inlayHintsCmd, gort.strings.Join(annotations, "\n\n"))
    end)
end

function FourslashTest:VerifyBaselineLinkedEditing(t)
    local baselineBuilder = gort.NewBuilder()
    local offset = 0
    for i266, file in gort.ipairs(self.testData.files) do
        do
            gort.fmt.Fprint(baselineBuilder, "// === Linked Editing ===\n")
            gort.fmt.Fprintf(baselineBuilder, "=== %s ===\n", file:FileName())
            local results = {}
            local found = {}
            for i, _ in gort.runes(file.content) do
                local params = lsproto.LinkedEditingRangeParams({
                        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(file:FileName()) }),
                        position = self.converters:PositionToLineAndCharacter(self:getScriptInfo(file:FileName()), i),
                    })
                local result = fourslash.sendRequest(t, self, lsproto.TextDocumentLinkedEditingRangeInfo, params)
                if ((result.linkedEditingRanges ~= nil) and (gort.len(result.linkedEditingRanges.ranges) > 0)) and (not (found[gort.Key(result.linkedEditingRanges.ranges[1])] or false)) then
                    results = gort.append(results, result.linkedEditingRanges)
                    found[gort.Key(result.linkedEditingRanges.ranges[1])] = true
                end
            end
            if gort.len(results) == 0 then
                gort.fmt.Fprintf(baselineBuilder, "%s\n\n--No linked edits found--\n\n\n", file.content)
                goto continue267
            end
            gort.slices.SortFunc(results, function(a, b)
                return lsproto.ComparePositions(a.ranges[1].start, b.ranges[1].start)
            end)
            local baselineDetails = {}
            local foundEditInfoBuilder = gort.NewBuilder()
            for i269, edit in gort.ipairs(results) do
                baselineDetails = gort.append(baselineDetails, setmetatable({
                        pos = edit.ranges[1].start,
                        positionMarker = gort.fmt.Sprintf("[|/*%d*/", offset),
                        kind = 0,
                    }, fourslash.baselineDetail))
                baselineDetails = gort.append(baselineDetails, setmetatable({ pos = edit.ranges[1].end_, positionMarker = "|]", kind = 0 }, fourslash.baselineDetail))
                baselineDetails = gort.append(baselineDetails, setmetatable({
                        pos = edit.ranges[2].start,
                        positionMarker = gort.fmt.Sprintf("[|/*%d*/", offset),
                        kind = 0,
                    }, fourslash.baselineDetail))
                baselineDetails = gort.append(baselineDetails, setmetatable({ pos = edit.ranges[2].end_, positionMarker = "|]", kind = 0 }, fourslash.baselineDetail))
                gort.fmt.Fprintf(foundEditInfoBuilder, "\n\n=== %d ===\n%s", offset, core.Must(core.StringifyJson(edit, "", "  ")))
                offset = offset + 1
            end
            gort.slices.SortStableFunc(baselineDetails, function(a, b)
                return lsproto.ComparePositions(a.pos, b.pos)
            end)
            local lastPosition = 0
            for i271, detail in gort.ipairs(baselineDetails) do
                local currentPosition = self.converters:LineAndCharacterToPosition(self:getScriptInfo(file:FileName()), detail.pos)
                gort.fmt.Fprint(baselineBuilder, string.sub(file.content, lastPosition + 1, currentPosition))
                gort.fmt.Fprint(baselineBuilder, detail.positionMarker)
                lastPosition = currentPosition
            end
            gort.fmt.Fprint(baselineBuilder, string.sub(file.content, lastPosition + 1))
            baselineBuilder:WriteString(foundEditInfoBuilder:String() .. "\n\n\n")
        end
        ::continue267::
    end
    self:writeToBaseline(fourslash.baselineCommand.linkedEditingCmd, baselineBuilder:String())
end

function FourslashTest:VerifyLinkedEditing(t, markerNamesToExpected)
    for markerName, expectedRanges in gort.pairs(markerNamesToExpected) do
        do
            self:GoToMarker(t, markerName)
            local params = lsproto.LinkedEditingRangeParams({
                textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                position = self.currentCaretPosition,
            })
            local result = fourslash.sendRequest(t, self, lsproto.TextDocumentLinkedEditingRangeInfo, params)
            local actualRanges = result.linkedEditingRanges
            if gort.len(expectedRanges) == 0 then
                if (actualRanges ~= nil) and (gort.len(actualRanges.ranges) ~= 0) then
                    t:Fatalf("Expected no linked editing ranges for marker '%s', but found %v", markerName, actualRanges)
                end
                goto continue273
            else
                if (actualRanges == nil) or (gort.len(actualRanges.ranges) == 0) then
                    t:Fatalf("Expected linked editing ranges for marker '%s', but found none", markerName)
                end
                fourslash.assertDeepEqual(t, actualRanges.ranges[1], expectedRanges[1], gort.fmt.Sprintf("Linked editing ranges for opening element do not match expected for marker '%s'", markerName))
                fourslash.assertDeepEqual(t, actualRanges.ranges[2], expectedRanges[2], gort.fmt.Sprintf("Linked editing ranges for closing element do not match expected for marker '%s'", markerName))
            end
        end
        ::continue273::
    end
end

function FourslashTest:VerifyDiagnostics(t, expected)
    self:verifyDiagnostics(t, expected, function(d)
        return true
    end)
end

function FourslashTest:VerifyNonSuggestionDiagnostics(t, expected)
    self:verifyDiagnostics(t, expected, function(d)
        return not fourslash.isSuggestionDiagnostic(d)
    end)
end

function FourslashTest:VerifySuggestionDiagnostics(t, expected)
    self:verifyDiagnostics(t, expected, fourslash.isSuggestionDiagnostic)
end

function FourslashTest:verifyDiagnostics(t, expected, filterDiagnostics)
    local actualDiagnostics = self:getDiagnostics(t, self.activeFilename)
    actualDiagnostics = core.Filter(actualDiagnostics, filterDiagnostics)
    local emptyRange = lsproto.Range({})
    local expectedWithRanges = gort.makeSlice(gort.len(expected), function() return nil end)
    for i274, diag in gort.ipairs(expected) do
        local i = i274 - 1
        if gort.StructEqual(diag.range, emptyRange) then
            local rangesInFile = self:getRangesInFile(self.activeFilename)
            if gort.len(rangesInFile) == 0 then
                t:Fatalf("No ranges found in file %s to assign to diagnostic with empty range", self.activeFilename)
            end
            local diagWithRange = gort.CloneStruct(diag)
            diagWithRange.range = gort.CloneStruct(rangesInFile[1].lsRange)
            expectedWithRanges[i + 1] = diagWithRange
        else
            expectedWithRanges[i + 1] = diag
        end
    end
    if (gort.len(actualDiagnostics) == 0) and (gort.len(expectedWithRanges) == 0) then
        return
    end
    fourslash.assertDeepEqual(t, actualDiagnostics, expectedWithRanges, "Diagnostics do not match expected", fourslash.diagnosticsIgnoreOpts)
end

function FourslashTest:getDiagnostics(t, fileName)
    local params = lsproto.DocumentDiagnosticParams({ textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(fileName) }) })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentDiagnosticInfo, params)
    if result.fullDocumentDiagnosticReport ~= nil then
        return result.fullDocumentDiagnosticReport.items
    end
    return nil
end

function fourslash.isSuggestionDiagnostic(diag)
    return (diag.severity ~= nil) and (diag.severity == lsproto.DiagnosticSeverity.Hint)
end

function FourslashTest:VerifyBaselineNonSuggestionDiagnostics(t)
    local diagnostics_ = nil
    local files = nil
    for fileName, scriptInfo in gort.pairs(self.scriptInfos) do
        do
            if tspath.HasJSONFileExtension(fileName) then
                goto continue276
            end
            files = gort.append(files, { unitName = fileName, content = scriptInfo.content })
            local lspDiagnostics = core.Filter(self:getDiagnostics(t, fileName), function(d)
                return not fourslash.isSuggestionDiagnostic(d)
            end)
            diagnostics_ = gort.appendSlice(diagnostics_, core.Map(lspDiagnostics, function(d)
                return self:toDiagnostic(scriptInfo, d)
            end))
        end
        ::continue276::
    end
    gort.slices.SortFunc(files, function(a, b)
        return gort.strings.Compare(a.unitName, b.unitName)
    end)
    local result = tsbaseline.GetErrorBaseline(t, files, diagnostics_, fourslash.compareDiagnostics, false)
    self:addResultToBaseline(t, fourslash.baselineCommand.nonSuggestionDiagnosticsCmd, result)
end

function fourslashDiagnosticFile:FileName()
    return self.file.unitName
end

function fourslashDiagnosticFile:OriginalFileName()
    return self.file.unitName
end

function fourslashDiagnosticFile:Text()
    return self.file.content
end

function fourslashDiagnosticFile:OriginalText()
    return self.file.content
end

function fourslashDiagnosticFile:SpanMap()
    return nil
end

function fourslashDiagnosticFile:ECMALineMap()
    if self.ecmaLineMap == nil then
        self.ecmaLineMap = core.ComputeECMALineStarts(self.file.content)
    end
    return self.ecmaLineMap
end

function fourslashDiagnostic:File()
    return self.file
end

function fourslashDiagnostic:Pos()
    return self.loc:Pos()
end

function fourslashDiagnostic:End()
    return self.loc:End()
end

function fourslashDiagnostic:Len()
    return self.loc:Len()
end

function fourslashDiagnostic:Code()
    return self.code
end

function fourslashDiagnostic:Category()
    return self.category
end

function fourslashDiagnostic:Source()
    return ""
end

function fourslashDiagnostic:Localize(locale_)
    return self.message
end

function fourslashDiagnostic:MessageChain()
    return nil
end

function fourslashDiagnostic:RelatedInformation()
    local relatedInfo = gort.makeSlice(0, function() return nil end)
    for i277, relDiag in gort.ipairs(self.relatedDiagnostics) do
        relatedInfo = gort.append(relatedInfo, relDiag)
    end
    return relatedInfo
end

function FourslashTest:toDiagnostic(scriptInfo, lspDiagnostic)
    local category = 0
    local sw279 = lspDiagnostic.severity
    if sw279 == lsproto.DiagnosticSeverity.Error then
        category = diagnostics.Category.Error
    elseif sw279 == lsproto.DiagnosticSeverity.Warning then
        category = diagnostics.Category.Warning
    elseif sw279 == lsproto.DiagnosticSeverity.Information then
        category = diagnostics.Category.Message
    elseif sw279 == lsproto.DiagnosticSeverity.Hint then
        category = diagnostics.Category.Suggestion
    else
        category = diagnostics.Category.Error
    end
    local code = lspDiagnostic.code.integer
    local relatedDiagnostics = nil
    if lspDiagnostic.relatedInformation ~= nil then
        for i280, info in gort.ipairs(lspDiagnostic.relatedInformation) do
            do
                local relatedScriptInfo = self:getScriptInfo(lsproto.DocumentUri_FileName(info.location.uri))
                if relatedScriptInfo == nil then
                    goto continue281
                end
                local relatedDiagnostic = setmetatable({
                    file = setmetatable({ file = { unitName = relatedScriptInfo.fileName, content = relatedScriptInfo.content } }, fourslash.fourslashDiagnosticFile),
                    loc = self:fromLSPRange(relatedScriptInfo, info.location.range),
                    code = code,
                    category = category,
                    message = info.message,
                    reportsUnnecessary = false,
                    reportsDeprecated = false,
                }, fourslash.fourslashDiagnostic)
                relatedDiagnostics = gort.append(relatedDiagnostics, relatedDiagnostic)
            end
            ::continue281::
        end
    end
    local diagnostic = setmetatable({
        file = setmetatable({ file = { unitName = scriptInfo.fileName, content = scriptInfo.content } }, fourslash.fourslashDiagnosticFile),
        loc = self:fromLSPRange(scriptInfo, lspDiagnostic.range),
        code = code,
        category = category,
        message = lspDiagnostic.message:AsString(),
        relatedDiagnostics = relatedDiagnostics,
        reportsUnnecessary = false,
        reportsDeprecated = false,
    }, fourslash.fourslashDiagnostic)
    return diagnostic
end

function fourslash.compareDiagnostics(d1, d2)
    local c = gort.strings.Compare(d1.file:FileName(), d2.file:FileName())
    if c ~= 0 then
        return c
    end
    c = d1:Pos() - d2:Pos()
    if c ~= 0 then
        return c
    end
    c = d1:End() - d2:End()
    if c ~= 0 then
        return c
    end
    c = d1.code - d2.code
    if c ~= 0 then
        return c
    end
    c = gort.strings.Compare(d1.message, d2.message)
    if c ~= 0 then
        return c
    end
    return fourslash.compareRelatedDiagnostics(d1.relatedDiagnostics, d2.relatedDiagnostics)
end

function fourslash.compareRelatedDiagnostics(d1, d2)
    local c = gort.len(d2) - gort.len(d1)
    if c ~= 0 then
        return c
    end
    for i282, _ in gort.ipairs(d1) do
        local i = i282 - 1
        c = fourslash.compareDiagnostics(d1[i + 1], d2[i + 1])
        if c ~= 0 then
            return c
        end
    end
    return 0
end

function fourslash.isLibFile(fileName)
    local baseName = tspath.GetBaseFileName(fileName)
    if gort.strings.HasPrefix(baseName, "lib.") and gort.strings.HasSuffix(baseName, ".d.ts") then
        return true
    end
    return false
end

function FourslashTest:VerifyBaselineGoToImplementation(t, ...)
    local markerNames = { ... }
    self:verifyBaselineDefinitions(t, fourslash.baselineCommand.goToImplementationCmd, "/*GOTO IMPL*/", function(t, f, fileName, position)
        local params = lsproto.ImplementationParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(f.activeFilename) }),
            position = f.currentCaretPosition,
        })
        return fourslash.sendRequest(t, f, lsproto.TextDocumentImplementationInfo, params)
    end, false, gort.unpack(markerNames))
end

function FourslashTest:VerifyWorkspaceSymbol(t, cases)
    local originalPreferences = gort.CloneStruct(self.userPreferences)
    for i284, testCase in gort.ipairs(cases) do
        local preferences = testCase.preferences
        if preferences == nil then
            preferences = lsutil.NewDefaultUserPreferences()
        end
        self:Configure(t, preferences)
        local result = fourslash.sendRequest(t, self, lsproto.WorkspaceSymbolInfo, lsproto.WorkspaceSymbolParams({
                query = testCase.pattern,
                textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            }))
        if result.symbolInformations == nil then
            t:Fatalf("Expected non-nil symbol information array from workspace symbol request")
        end
        if testCase.includes ~= nil then
            if testCase.exact ~= nil then
                t:Fatalf("Test case cannot have both 'Includes' and 'Exact' fields set")
            end
            fourslash.verifyIncludesSymbols(t, result.symbolInformations, testCase.includes, ("Workspace symbols mismatch with pattern '" .. testCase.pattern) .. "'")
        else
            if testCase.exact == nil then
                t:Fatalf("Test case must have either 'Includes' or 'Exact' field set")
            end
            fourslash.verifyExactSymbols(t, result.symbolInformations, testCase.exact, ("Workspace symbols mismatch with pattern '" .. testCase.pattern) .. "'")
        end
    end
    self:Configure(t, originalPreferences)
end

function fourslash.verifyExactSymbols(t, actual, expected, prefix)
    if gort.len(actual) ~= gort.len(expected) then
        t:Fatalf("%s: Expected %d symbols, but got %d:\n%s", prefix, gort.len(expected), gort.len(actual), gort.cmp.Diff(actual, expected))
    end
    for i286, _ in gort.ipairs(actual) do
        local i = i286 - 1
        fourslash.assertDeepEqual(t, actual[i + 1], expected[i + 1], prefix)
    end
end

function fourslash.verifyIncludesSymbols(t, actual, includes, prefix)
    local nameAndLocToActualSymbol = {}
    for i288, sym in gort.ipairs(actual) do
        nameAndLocToActualSymbol[gort.Key({ name = sym.name, loc = sym.location })] = sym
    end
    for i290, sym in gort.ipairs(includes) do
        local actualSym, ok = gort.MapLookup(nameAndLocToActualSymbol, gort.Key({ name = sym.name, loc = sym.location }), nil)
        if not ok then
            t:Fatalf("%s: Expected symbol '%s' at location '%v' not found", prefix, sym.name, sym.location)
        end
        fourslash.assertDeepEqual(t, actualSym, sym, gort.fmt.Sprintf("%s: Symbol '%s' at location '%v' mismatch", prefix, sym.name, sym.location))
    end
end

function FourslashTest:VerifyBaselineDocumentSymbol(t)
    local params = lsproto.DocumentSymbolParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentDocumentSymbolInfo, params)
    local uri = lsconv.FileNameToDocumentURI(self.activeFilename)
    local symbolBySpan = {}
    if result.documentSymbols ~= nil then
        for i292, symbol in gort.ipairs(result.documentSymbols) do
            fourslash.collectDocumentSymbolSpans(uri, symbol, symbolBySpan)
        end
    end
    local spans = gort.makeSlice(0, function() return { uri = "", textSpan = lsproto.Range({}) } end)
    for k294, symbol in gort.pairs(symbolBySpan) do
        local key = gort.Unkey(k294)
        spans = gort.append(spans, { uri = key.uri, textSpan = key.textSpan, contextSpan = symbol.range })
    end
    self:addResultToBaseline(t, fourslash.baselineCommand.documentSymbolsCmd, self:getBaselineForSpansWithFileContents(spans, {
        getLocationData = function(span)
            local symbol = symbolBySpan[gort.Key({ uri = span.uri, textSpan = span.textSpan, contextSpan = span.contextSpan })]
            return gort.fmt.Sprintf("{| name: %s, kind: %s |}", symbol.name, lsproto.SymbolKind_String(symbol.kind))
        end,
        markerName = "",
        endMarker = "",
        preserveResultOrder = false,
    }))
    local detailsBuilder = gort.NewBuilder()
    if result.documentSymbols ~= nil then
        fourslash.writeDocumentSymbolDetails(result.documentSymbols, 0, detailsBuilder)
    end
    self:writeToBaseline(fourslash.baselineCommand.documentSymbolsCmd, "\n\n// === Details ===\n" .. detailsBuilder:String())
end

function fourslash.writeDocumentSymbolDetails(symbols, indent, builder)
    for i295, symbol in gort.ipairs(symbols) do
        gort.fmt.Fprintf(builder, "%s(%s) %s\n", gort.strings.Repeat("  ", indent), lsproto.SymbolKind_String(symbol.kind), symbol.name)
        if symbol.children ~= nil then
            fourslash.writeDocumentSymbolDetails(symbol.children, indent + 1, builder)
        end
    end
end

function fourslash.collectDocumentSymbolSpans(uri, symbol, symbolBySpan)
    local key = { uri = uri, textSpan = symbol.selectionRange, contextSpan = symbol.range }
    do
        local _, ok = gort.MapLookup(symbolBySpan, gort.Key(key), nil)
        if not ok then
            symbolBySpan[gort.Key(key)] = symbol
        end
    end
    if symbol.children ~= nil then
        for i297, child in gort.ipairs(symbol.children) do
            fourslash.collectDocumentSymbolSpans(uri, child, symbolBySpan)
        end
    end
end

function FourslashTest:VerifyNumberOfErrorsInCurrentFile(t, expectedCount)
    local diagnostics_ = self:getDiagnostics(t, self.activeFilename)
    local errors = core.Filter(diagnostics_, function(d)
        return not fourslash.isSuggestionDiagnostic(d)
    end)
    if gort.len(errors) ~= expectedCount then
        t:Fatalf("Expected %d errors in current file, but got %d", expectedCount, gort.len(errors))
    end
end

function FourslashTest:VerifyNoErrors(t)
    for fileName, _ in gort.pairs(self.openFiles) do
        local diagnostics_ = self:getDiagnostics(t, fileName)
        local errors = core.Filter(diagnostics_, function(d)
                return not fourslash.isSuggestionDiagnostic(d)
            end)
        if gort.len(errors) > 0 then
            local messages = nil
            for i300, err in gort.ipairs(errors) do
                messages = gort.append(messages, err.message:AsString())
            end
            t:Fatalf("Expected no errors but found %d in %s: %v", gort.len(errors), fileName, messages)
        end
    end
end

function FourslashTest:VerifyErrorExistsAtRange(t, rangeMarker, code, message)
    local diagnostics_ = self:getDiagnostics(t, rangeMarker:FileName())
    for i302, diag in gort.ipairs(diagnostics_) do
        if ((diag.code ~= nil) and (diag.code.integer ~= nil)) and (diag.code.integer == code) then
            if (((diag.range.start.line == rangeMarker.lsRange.start.line) and (diag.range.start.character == rangeMarker.lsRange.start.character)) and (diag.range.end_.line == rangeMarker.lsRange.end_.line)) and (diag.range.end_.character == rangeMarker.lsRange.end_.character) then
                if (message ~= "") and (diag.message:AsString() ~= message) then
                    t:Fatalf("Error at range has code %d but message mismatch. Expected: %q, Got: %q", code, message, diag.message:AsString())
                end
                return
            end
        end
    end
    t:Fatalf("Expected error with code %d at range %v but it was not found", code, rangeMarker.lsRange)
end

function FourslashTest:VerifyErrorExistsBetweenMarkers(t, startMarkerName, endMarkerName)
    local startMarker, ok = gort.MapLookup(self.testData.markerPositions, startMarkerName, nil)
    if not ok then
        t:Fatalf("Start marker '%s' not found", startMarkerName)
    end
    local endMarker
    endMarker, ok = gort.MapLookup(self.testData.markerPositions, endMarkerName, nil)
    if not ok then
        t:Fatalf("End marker '%s' not found", endMarkerName)
    end
    if startMarker:FileName() ~= endMarker:FileName() then
        t:Fatalf("Markers '%s' and '%s' are in different files", startMarkerName, endMarkerName)
    end
    local diagnostics_ = self:getDiagnostics(t, startMarker:FileName())
    local startPos = startMarker.position
    local endPos = endMarker.position
    for i304, diag in gort.ipairs(diagnostics_) do
        if not fourslash.isSuggestionDiagnostic(diag) then
            local diagStart = self.converters:LineAndCharacterToPosition(self:getScriptInfo(startMarker:FileName()), diag.range.start)
            local diagEnd = self.converters:LineAndCharacterToPosition(self:getScriptInfo(startMarker:FileName()), diag.range.end_)
            if (diagStart >= startPos) and (diagEnd <= endPos) then
                return
            end
        end
    end
    t:Fatalf("Expected error between markers '%s' and '%s' but none was found", startMarkerName, endMarkerName)
end

function FourslashTest:VerifyErrorExistsAfterMarker(t, markerName)
    local fileName = ""
    local markerPos = 0
    if markerName == "" then
        fileName = self.activeFilename
        markerPos = self.converters:LineAndCharacterToPosition(self:getScriptInfo(self.activeFilename), self.currentCaretPosition)
    else
        local marker, ok = gort.MapLookup(self.testData.markerPositions, markerName, nil)
        if not ok then
            t:Fatalf("Marker '%s' not found", markerName)
        end
        fileName = marker:FileName()
        markerPos = marker.position
    end
    local diagnostics_ = self:getDiagnostics(t, fileName)
    for i306, diag in gort.ipairs(diagnostics_) do
        if not fourslash.isSuggestionDiagnostic(diag) then
            local diagStart = self.converters:LineAndCharacterToPosition(self:getScriptInfo(fileName), diag.range.start)
            if diagStart >= markerPos then
                return
            end
        end
    end
    t:Fatalf("Expected error after marker '%s' but none was found", markerName)
end

function FourslashTest:VerifyErrorExistsBeforeMarker(t, markerName)
    local fileName = ""
    local markerPos = 0
    if markerName == "" then
        fileName = self.activeFilename
        markerPos = self.converters:LineAndCharacterToPosition(self:getScriptInfo(self.activeFilename), self.currentCaretPosition)
    else
        local marker, ok = gort.MapLookup(self.testData.markerPositions, markerName, nil)
        if not ok then
            t:Fatalf("Marker '%s' not found", markerName)
        end
        fileName = marker:FileName()
        markerPos = marker.position
    end
    local diagnostics_ = self:getDiagnostics(t, fileName)
    for i308, diag in gort.ipairs(diagnostics_) do
        if not fourslash.isSuggestionDiagnostic(diag) then
            local diagEnd = self.converters:LineAndCharacterToPosition(self:getScriptInfo(fileName), diag.range.end_)
            if diagEnd <= markerPos then
                return
            end
        end
    end
    t:Fatalf("Expected error before marker '%s' but none was found", markerName)
end

function fourslash.updatePositionForTextEdit(position, editStart, editEnd, newTextLength)
    if position <= editStart then
        return position
    end
    if position < editEnd then
        return -1
    end
    return (position + newTextLength) - ((editEnd - editStart))
end

function fourslash.removeWhitespace(text)
    local builder = gort.NewBuilder()
    for _, ch in gort.runes(text) do
        do
            if stringutil.IsWhiteSpaceLike(ch) then
                goto continue310
            end
            builder:WriteRune(ch)
        end
        ::continue310::
    end
    return builder:String()
end

function fourslash.assertValidTextRange(t, textRange, message)
    t:Helper()
    if (textRange:Pos() >= 0) and (textRange:End() >= 0) then
        return
    end
    t:Fatal(message)
end

function fourslash.selectCodeFixDiagnostic(diagnostics_, errorCode)
    if errorCode == 0 then
        return diagnostics_[1]
    end
    do return core.Find(diagnostics_, function(diagnostic)
        return ((diagnostic.code ~= nil) and (diagnostic.code.integer ~= nil)) and (diagnostic.code.integer == errorCode)
    end) end
end

fourslash.parseCache = project.NewParseCache({ disableDeletion = true })
fourslash.ptrTrue = true
fourslash.ptrFalse = false
fourslash.defaultCompletionCapabilities = lsproto.CompletionClientCapabilities({
    completionItem = lsproto.ClientCompletionItemOptions({
        snippetSupport = fourslash.ptrFalse,
        commitCharactersSupport = fourslash.ptrTrue,
        preselectSupport = fourslash.ptrTrue,
        labelDetailsSupport = fourslash.ptrFalse,
        insertReplaceSupport = fourslash.ptrTrue,
        documentationFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText },
    }),
    completionList = lsproto.CompletionListCapabilities({ itemDefaults = { "commitCharacters", "editRange" } }),
})
fourslash.defaultDefinitionCapabilities = lsproto.DefinitionClientCapabilities({ linkSupport = fourslash.ptrTrue })
fourslash.defaultTypeDefinitionCapabilities = lsproto.TypeDefinitionClientCapabilities({ linkSupport = fourslash.ptrTrue })
fourslash.defaultImplementationCapabilities = lsproto.ImplementationClientCapabilities({ linkSupport = fourslash.ptrTrue })
fourslash.defaultHoverCapabilities = lsproto.HoverClientCapabilities({ contentFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText } })
fourslash.defaultExperimentalCapabilities = lsproto.ExperimentalClientCapabilities({ hoverVerbosityLevel = fourslash.ptrTrue })
fourslash.defaultSignatureHelpCapabilities = lsproto.SignatureHelpClientCapabilities({
    signatureInformation = lsproto.ClientSignatureInformationOptions({
        documentationFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText },
        parameterInformation = lsproto.ClientSignatureParameterInformationOptions({ labelOffsetSupport = fourslash.ptrTrue }),
        activeParameterSupport = fourslash.ptrTrue,
    }),
    contextSupport = fourslash.ptrTrue,
})
fourslash.defaultDocumentSymbolCapabilities = lsproto.DocumentSymbolClientCapabilities({ hierarchicalDocumentSymbolSupport = fourslash.ptrTrue })
fourslash.defaultFoldingRangeCapabilities = lsproto.FoldingRangeClientCapabilities({
    rangeLimit = 5000,
    foldingRangeKind = lsproto.ClientFoldingRangeKindOptions({
        valueSet = { lsproto.FoldingRangeKind.Comment, lsproto.FoldingRangeKind.Imports, lsproto.FoldingRangeKind.Region },
    }),
    foldingRange = lsproto.ClientFoldingRangeOptions({ collapsedText = fourslash.ptrTrue }),
})
fourslash.defaultDiagnosticCapabilities = lsproto.DiagnosticClientCapabilities({
    relatedInformation = fourslash.ptrTrue,
    tagSupport = lsproto.ClientDiagnosticsTagOptions({ valueSet = { lsproto.DiagnosticTag.Unnecessary, lsproto.DiagnosticTag.Deprecated } }),
})
fourslash.defaultPublishDiagnosticCapabilities = lsproto.PublishDiagnosticsClientCapabilities({
    relatedInformation = fourslash.ptrTrue,
    tagSupport = lsproto.ClientDiagnosticsTagOptions({ valueSet = { lsproto.DiagnosticTag.Unnecessary, lsproto.DiagnosticTag.Deprecated } }),
})
fourslash.defaultWorkspaceEditCapabilities = lsproto.WorkspaceEditClientCapabilities({ documentChanges = fourslash.ptrTrue, resourceOperations = { lsproto.ResourceOperationKind.Rename } })
fourslash.completionIgnoreOpts = fourslash.ignorePaths(".Kind", ".SortText", ".FilterText", ".Data", ".AdditionalTextEdits")
fourslash.autoImportIgnoreOpts = fourslash.ignorePaths(".Kind", ".SortText", ".FilterText", ".Data", ".LabelDetails", ".Detail", ".AdditionalTextEdits")
fourslash.diagnosticsIgnoreOpts = fourslash.ignorePaths(".Severity", ".Source", ".RelatedInformation")
fourslash._ = nil
fourslash._ = nil
-- Go: new([]*lsproto.TextEdit) — distinct sentinels compared by identity
fourslash.AnyTextEdits = {}
fourslash.NoTextEdits = {}
