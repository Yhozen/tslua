-- luacheck: ignore 211 421 423 431 432
local fourslash = require("tslua.fourslash")
local json = require("tslua.json")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")
local collections = require("tslua.collections")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local debug = require("tslua.debug")
local gort = require("tslua.fourslash.goruntime")

local baselineDetail = {}
baselineDetail.__index = baselineDetail
fourslash.baselineDetail = baselineDetail

local textWithContext = {}
textWithContext.__index = textWithContext
fourslash.textWithContext = textWithContext

local FourslashTest = fourslash.FourslashTest

fourslash.baselineCommand = fourslash.baselineCommand or {}
fourslash.baselineCommand.autoImportsCmd = "Auto Imports"
fourslash.baselineCommand.callHierarchyCmd = "Call Hierarchy"
fourslash.baselineCommand.closingTagCmd = "Closing Tag"
fourslash.baselineCommand.documentHighlightsCmd = "documentHighlights"
fourslash.baselineCommand.findAllReferencesCmd = "findAllReferences"
fourslash.baselineCommand.vsFindAllReferencesCmd = "vsFindAllReferences"
fourslash.baselineCommand.goToDefinitionCmd = "goToDefinition"
fourslash.baselineCommand.goToImplementationCmd = "goToImplementation"
fourslash.baselineCommand.goToSourceDefinitionCmd = "goToSourceDefinition"
fourslash.baselineCommand.goToTypeDefinitionCmd = "goToType"
fourslash.baselineCommand.inlayHintsCmd = "Inlay Hints"
fourslash.baselineCommand.nonSuggestionDiagnosticsCmd = "Syntax and Semantic Diagnostics"
fourslash.baselineCommand.quickInfoCmd = "QuickInfo"
fourslash.baselineCommand.vsQuickInfoCmd = "VSQuickInfo"
fourslash.baselineCommand.linkedEditingCmd = "linkedEditing"
fourslash.baselineCommand.renameCmd = "findRenameLocations"
fourslash.baselineCommand.signatureHelpCmd = "SignatureHelp"
fourslash.baselineCommand.smartSelectionCmd = "Smart Selection"
fourslash.baselineCommand.codeLensesCmd = "Code Lenses"
fourslash.baselineCommand.documentSymbolsCmd = "Document Symbols"

fourslash.detailKind = fourslash.detailKind or {}
fourslash.detailKind.Marker = 0
fourslash.detailKind.ContextStart = 1
fourslash.detailKind.TextStart = 2
fourslash.detailKind.TextEnd = 3
fourslash.detailKind.ContextEnd = 4

function FourslashTest:addResultToBaseline(t, command, actual)
    local b = nil
    if self.testData:isStateBaseliningEnabled() then
        b = self.stateBaseline.baseline
    else
        do
            local builder, ok = gort.MapLookup(self.baselines, command, nil)
            if ok then
                b = builder
            else
                self.baselines[command] = gort.NewBuilder()
                b = self.baselines[command]
            end
        end
    end
    if b:Len() ~= 0 then
        b:WriteString("\n\n\n\n")
    end
    b:WriteString("// === ")
    b:WriteString(command)
    b:WriteString(" ===\n")
    b:WriteString(actual)
end

function FourslashTest:writeToBaseline(command, content)
    local b, ok = gort.MapLookup(self.baselines, command, nil)
    if not ok then
        self.baselines[command] = gort.NewBuilder()
        b = self.baselines[command]
    end
    b:WriteString(content)
end

function fourslash.getBaselineFileName(t, command)
    return (fourslash.getBaseFileNameFromTest(t) .. ".") .. fourslash.getBaselineExtension(command)
end

function fourslash.getBaselineExtension(command)
    local sw1 = command
    if sw1 == fourslash.baselineCommand.quickInfoCmd or sw1 == fourslash.baselineCommand.vsQuickInfoCmd or sw1 == fourslash.baselineCommand.signatureHelpCmd or sw1 == fourslash.baselineCommand.smartSelectionCmd or sw1 == fourslash.baselineCommand.inlayHintsCmd or sw1 == fourslash.baselineCommand.nonSuggestionDiagnosticsCmd or sw1 == fourslash.baselineCommand.documentSymbolsCmd or sw1 == fourslash.baselineCommand.closingTagCmd or sw1 == fourslash.baselineCommand.vsFindAllReferencesCmd then
        do return "baseline" end
    elseif sw1 == fourslash.baselineCommand.callHierarchyCmd then
        do return "callHierarchy.txt" end
    elseif sw1 == fourslash.baselineCommand.autoImportsCmd then
        do return "baseline.md" end
    elseif sw1 == fourslash.baselineCommand.linkedEditingCmd then
        do return "linkedEditing.txt" end
    else
        do return "baseline.jsonc" end
    end
end

function FourslashTest:getBaselineOptions(command, testPath)
    local subfolder = "fourslash/" .. fourslash.normalizeCommandName(command)
    if not fourslash.isSubmoduleTest(testPath) then
        return {
            subfolder = subfolder,
            isSubmodule = false,
            isSubmoduleAccepted = false,
            isSubmoduleTriaged = false,
            skipDiffWithOld = false,
        }
    end
    local sw2 = command
    if sw2 == fourslash.baselineCommand.smartSelectionCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.callHierarchyCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = function(s)
                    s = gort.strings.ReplaceAll(s, "/tests/cases/fourslash/server/", "/")
                    s = gort.strings.ReplaceAll(s, "/tests/cases/fourslash/", "/")
                    s = gort.strings.ReplaceAll(s, "kind: getter", "kind: property")
                    s = gort.strings.ReplaceAll(s, "kind: script", "kind: file")
                    return s
                end,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.renameCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = function(s)
                    local commandLines = nil
                    local commandPrefix = gort.regexp.MustCompile("^// === ([a-z\\sA-Z]*) ===")
                    local testFilePrefix = "/tests/cases/fourslash"
                    local serverTestFilePrefix = "/server"
                    local contextSpanOpening = "<|"
                    local contextSpanClosing = "|>"
                    local oldPreference = "providePrefixAndSuffixTextForRename"
                    local newPreference = "useAliasesForRename"
                    local replacer = gort.strings.NewReplacer(contextSpanOpening, "", contextSpanClosing, "", testFilePrefix, "", serverTestFilePrefix, "", oldPreference, newPreference)
                    local lines = gort.strings.Split(s, "\n")
                    local isInCommand = false
                    for i3, line in gort.ipairs(lines) do
                        do
                            if gort.strings.HasPrefix(line, "// @findInStrings: ") or gort.strings.HasPrefix(line, "// @findInComments: ") then
                                goto continue4
                            end
                            local matches = commandPrefix:FindStringSubmatch(line)
                            if gort.len(matches) > 0 then
                                local commandName = matches[2]
                                if commandName == command then
                                    isInCommand = true
                                else
                                    isInCommand = false
                                end
                            end
                            if isInCommand then
                                local fixedLine = replacer:Replace(line)
                                commandLines = gort.append(commandLines, fixedLine)
                            end
                        end
                        ::continue4::
                    end
                    return gort.strings.Join(fourslash.dropTrailingEmptyLines(commandLines), "\n")
                end,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.inlayHintsCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = function(s)
                    local commandLines = nil
                    local commandPrefix = gort.regexp.MustCompile("^// === ([a-z\\sA-Z]*) ===")
                    local lines = gort.strings.Split(s, "\n")
                    local isInCommand = false
                    local replacer = gort.strings.NewReplacer("\"whitespaceAfter\"", "\"paddingRight\"", "\"whitespaceBefore\"", "\"paddingLeft\"")
                    local hintStart = -1
                    do
                        local i = 0
                        while i < gort.len(lines) do
                            do
                                local line = lines[i + 1]
                                local matches = commandPrefix:FindStringSubmatch(line)
                                if gort.len(matches) > 0 then
                                    local commandName = matches[2]
                                    if commandName == command then
                                        isInCommand = true
                                    else
                                        isInCommand = false
                                    end
                                end
                                if isInCommand then
                                    if line == "{" then
                                        hintStart = gort.len(commandLines)
                                    end
                                    if (line == "}") and gort.strings.HasSuffix(commandLines[(gort.len(commandLines) - 1) + 1], ",") then
                                        commandLines[(gort.len(commandLines) - 1) + 1] = gort.strings.TrimSuffix(commandLines[(gort.len(commandLines) - 1) + 1], ",")
                                    end
                                    local trimmedLine = gort.strings.TrimSpace(line)
                                    if gort.strings.HasPrefix(trimmedLine, "\"position\": ") then
                                        goto continue5
                                    end
                                    if gort.strings.HasPrefix(trimmedLine, "\"text\": ") then
                                        if trimmedLine == "\"text\": \"\"," then
                                            goto continue5
                                        end
                                        line = gort.strings.Replace(line, "\"text\":", "\"label\":", 1)
                                    end
                                    if gort.strings.HasPrefix(trimmedLine, "\"kind\": ") then
                                        local sw6 = trimmedLine
                                        if sw6 == "\"kind\": \"Parameter\"," then
                                            line = gort.strings.Replace(line, "\"kind\": \"Parameter\",", "\"kind\": 2,", 1)
                                        elseif sw6 == "\"kind\": \"Type\"," then
                                            line = gort.strings.Replace(line, "\"kind\": \"Type\",", "\"kind\": 1,", 1)
                                        else
                                            goto continue5
                                        end
                                    end
                                    if gort.strings.HasPrefix(trimmedLine, "\"displayParts\": ") then
                                        local displayPartLines = nil
                                        displayPartLines = gort.append(displayPartLines, gort.strings.Replace(line, "displayParts", "label", 1))
                                        local j = 0
                                        do
                                            j = i + 1
                                            while j < gort.len(lines) do
                                                do
                                                    local line = lines[j + 1]
                                                    local trimmedLine = gort.strings.TrimSpace(line)
                                                    if gort.strings.HasPrefix(trimmedLine, "\"text\": ") then
                                                        line = gort.strings.Replace(line, "\"text\":", "\"value\":", 1)
                                                    elseif gort.strings.HasPrefix(trimmedLine, "\"span\": ") then
                                                        displayPartLines = gort.append(displayPartLines, gort.strings.Replace(line, "span", "location", 1) .. "},")
                                                        j = j + 3
                                                        goto continue7
                                                    elseif gort.strings.HasPrefix(trimmedLine, "\"file\": ") then
                                                        goto continue7
                                                    end
                                                    if (trimmedLine == "]") or (trimmedLine == "],") then
                                                        local fixedLine = line
                                                        if trimmedLine == "]" then
                                                            fixedLine = fixedLine .. ","
                                                        end
                                                        displayPartLines = gort.append(displayPartLines, fixedLine)
                                                        break
                                                    end
                                                    displayPartLines = gort.append(displayPartLines, line)
                                                end
                                                ::continue7::
                                                j = j + 1
                                            end
                                        end
                                        commandLines = gort.slices.Insert(commandLines, hintStart + 1, gort.unpack(displayPartLines))
                                        i = j
                                        goto continue5
                                    end
                                    local fixedLine = replacer:Replace(line)
                                    commandLines = gort.append(commandLines, fixedLine)
                                end
                            end
                            ::continue5::
                            i = i + 1
                        end
                    end
                    return gort.strings.Join(fourslash.dropTrailingEmptyLines(commandLines), "\n")
                end,
                diffFixupNew = function(s)
                    local lines = gort.strings.Split(s, "\n")
                    local fixedLines = nil
                    do
                        local i = 0
                        while i < gort.len(lines) do
                            do
                                local line = lines[i + 1]
                                local trimmedLine = gort.strings.TrimSpace(line)
                                if gort.strings.HasPrefix(trimmedLine, "\"position\": ") then
                                    i = i + 3
                                    goto continue8
                                end
                                if gort.strings.HasPrefix(trimmedLine, "\"location\": ") then
                                    fixedLines = gort.append(fixedLines, line .. "},")
                                    i = i + 12
                                    goto continue8
                                end
                                fixedLines = gort.append(fixedLines, line)
                            end
                            ::continue8::
                            i = i + 1
                        end
                    end
                    return gort.strings.Join(fixedLines, "\n")
                end,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.goToDefinitionCmd or sw2 == fourslash.baselineCommand.goToTypeDefinitionCmd or sw2 == fourslash.baselineCommand.goToImplementationCmd or sw2 == fourslash.baselineCommand.goToSourceDefinitionCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = function(s)
                    local commandLines = nil
                    local commandPrefix = gort.regexp.MustCompile("^// === ([a-z\\sA-Z]*) ===")
                    local testFilePrefix = "/tests/cases/fourslash"
                    local serverTestFilePrefix = "/server"
                    local oldGoToDefCommand = "getDefinitionAtPosition"
                    local oldGoToDefComment = "/*GOTO DEF POS*/"
                    local replacer = gort.strings.NewReplacer(testFilePrefix, "", serverTestFilePrefix, "", oldGoToDefCommand, fourslash.baselineCommand.goToDefinitionCmd, oldGoToDefComment, "/*GOTO DEF*/")
                    local objectRangeRegex = gort.regexp.MustCompile("{\\| [^|]* \\|}")
                    local detailsStr = "// === Details ==="
                    local lines = gort.strings.Split(s, "\n")
                    local isInCommand = false
                    local isInDetails = false
                    for i9, line in gort.ipairs(lines) do
                        local matches = commandPrefix:FindStringSubmatch(line)
                        if gort.len(matches) > 0 then
                            isInDetails = false
                            local commandName = matches[2]
                            if (commandName == command) or ((command == fourslash.baselineCommand.goToDefinitionCmd) and (commandName == oldGoToDefCommand)) then
                                isInCommand = true
                            else
                                isInCommand = false
                            end
                        end
                        if isInCommand then
                            if gort.strings.Contains(line, detailsStr) then
                                commandLines = gort.slice(commandLines, 0, gort.len(commandLines) - 1)
                                isInDetails = true
                            end
                            if not isInDetails then
                                local fixedLine = replacer:Replace(line)
                                fixedLine = objectRangeRegex:ReplaceAllString(fixedLine, "")
                                commandLines = gort.append(commandLines, fixedLine)
                            elseif line == "  ]" then
                                isInDetails = false
                            end
                        end
                    end
                    return gort.strings.Join(fourslash.dropTrailingEmptyLines(commandLines), "\n")
                end,
                diffFixupNew = function(s)
                    return gort.strings.ReplaceAll(s, "bundled:///libs/", "")
                end,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.findAllReferencesCmd then
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = function(s)
                    local commandLines = nil
                    local commandPrefix = gort.regexp.MustCompile("^// === ([a-z\\sA-Z]*) ===")
                    local filePrefix = gort.regexp.MustCompile("^// === ([^ ]*) ===")
                    local testFilePrefix = "/tests/cases/fourslash"
                    local serverTestFilePrefix = "/server"
                    local contextSpanOpening = "<|"
                    local contextSpanClosing = "|>"
                    local replacer = gort.strings.NewReplacer(testFilePrefix, "", serverTestFilePrefix, "", contextSpanOpening, "", contextSpanClosing, "")
                    local objectRangeRegex = gort.regexp.MustCompile("{\\| [^|]* \\|}")
                    local definitionsStr = "// === Definitions ==="
                    local detailsStr = "// === Details ==="
                    local lines = gort.strings.Split(s, "\n")
                    local isInCommand = false
                    local isInDetails = false
                    local isInDefinitions = false
                    local fileSections = nil
                    local currentFileName = ""
                    local currentFileLines = nil
                    for i11, line in gort.ipairs(lines) do
                        do
                            local matches = commandPrefix:FindStringSubmatch(line)
                            if gort.len(matches) > 0 then
                                isInDetails = false
                                isInDefinitions = false
                                local commandName = matches[2]
                                if commandName == fourslash.baselineCommand.findAllReferencesCmd then
                                    isInCommand = true
                                    if currentFileName ~= "" then
                                        fileSections = gort.append(fileSections, { fileName = currentFileName, lines = currentFileLines })
                                    end
                                    currentFileName = ""
                                    currentFileLines = nil
                                    gort.slices.SortFunc(fileSections, function(a, b)
                                        return gort.strings.Compare(a.fileName, b.fileName)
                                    end)
                                    for i13, section in gort.ipairs(fileSections) do
                                        section.lines = fourslash.dropTrailingEmptyLines(section.lines)
                                        commandLines = gort.appendSlice(commandLines, section.lines)
                                        commandLines = gort.append(commandLines, "")
                                    end
                                    fileSections = nil
                                    if gort.len(commandLines) > 0 then
                                        commandLines = gort.append(commandLines, "", "")
                                    end
                                    commandLines = gort.append(commandLines, replacer:Replace(line))
                                    goto continue12
                                else
                                    isInCommand = false
                                end
                            end
                            if isInCommand then
                                if gort.strings.Contains(line, definitionsStr) or gort.strings.Contains(line, detailsStr) then
                                    isInDefinitions = gort.strings.Contains(line, definitionsStr)
                                    isInDetails = gort.strings.Contains(line, detailsStr)
                                    if (gort.len(currentFileLines) > 0) and (currentFileLines[(gort.len(currentFileLines) - 1) + 1] == "") then
                                        currentFileLines = gort.slice(currentFileLines, 0, gort.len(currentFileLines) - 1)
                                    end
                                end
                                if not ((isInDefinitions or isInDetails)) then
                                    local fixedLine = replacer:Replace(line)
                                    fixedLine = objectRangeRegex:ReplaceAllString(fixedLine, "")
                                    local fileMatches = filePrefix:FindStringSubmatch(fixedLine)
                                    if gort.len(fileMatches) > 0 then
                                        if currentFileName ~= "" then
                                            fileSections = gort.append(fileSections, { fileName = currentFileName, lines = currentFileLines })
                                        end
                                        currentFileName = fileMatches[2]
                                        currentFileLines = { fixedLine }
                                    else
                                        currentFileLines = gort.append(currentFileLines, fixedLine)
                                    end
                                elseif isInDetails and (line == "  ]") then
                                    isInDetails = false
                                end
                            end
                        end
                        ::continue12::
                    end
                    if currentFileName ~= "" then
                        fileSections = gort.append(fileSections, { fileName = currentFileName, lines = currentFileLines })
                    end
                    if gort.len(fileSections) > 0 then
                        gort.slices.SortFunc(fileSections, function(a, b)
                            return gort.strings.Compare(a.fileName, b.fileName)
                        end)
                        for i15, section in gort.ipairs(fileSections) do
                            section.lines = fourslash.dropTrailingEmptyLines(section.lines)
                            commandLines = gort.appendSlice(commandLines, section.lines)
                            commandLines = gort.append(commandLines, "")
                        end
                    end
                    return gort.strings.Join(fourslash.dropTrailingEmptyLines(commandLines), "\n")
                end,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    elseif sw2 == fourslash.baselineCommand.linkedEditingCmd then
        local deleteInfo = function(s)
                local commandLines = {}
                local lines = gort.strings.Split(s, "\n")
                local linkedEditingInfoHeader = gort.regexp.MustCompile("=== [0-9]+ ===")
                local fileNameHeader = gort.regexp.MustCompile("=== [\\w,\\s-]+\\.[A-Za-z]+ ===")
                local inLinkedEditingInfo = false
                for i17, line in gort.ipairs(lines) do
                    local i = i17 - 1
                    do
                        if linkedEditingInfoHeader:MatchString(line) then
                            inLinkedEditingInfo = true
                            goto continue18
                        end
                        if fileNameHeader:MatchString(line) then
                            inLinkedEditingInfo = false
                            goto continue18
                        end
                        if not inLinkedEditingInfo then
                            lines[i + 1] = ""
                        end
                    end
                    ::continue18::
                end
                return gort.strings.Join(fourslash.dropTrailingEmptyLines(commandLines), "\n")
            end
        do return {
                subfolder = subfolder,
                isSubmodule = true,
                diffFixupOld = deleteInfo,
                diffFixupNew = deleteInfo,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    else
        do return {
                subfolder = subfolder,
                isSubmodule = false,
                isSubmoduleAccepted = false,
                isSubmoduleTriaged = false,
                skipDiffWithOld = false,
            } end
    end
end

function fourslash.dropTrailingEmptyLines(ss)
    do return gort.slice(ss, 0, core.FindLastIndex(ss, function(s)
        return s ~= ""
    end) + 1) end
end

function fourslash.isSubmoduleTest(testPath)
    return gort.strings.Contains(testPath, "fourslash/tests/gen") or gort.strings.Contains(testPath, "fourslash/tests/manual")
end

function fourslash.normalizeCommandName(command)
    local words = gort.strings.Fields(command)
    command = gort.strings.Join(words, "")
    return stringutil.LowerFirstChar(command)
end

function fourslash.locationToSpan(loc)
    return { uri = loc.uri, textSpan = loc.range }
end

function FourslashTest:getBaselineForLocationsWithFileContents(locations, options)
    return self:getBaselineForSpansWithFileContents(core.Map(locations, fourslash.locationToSpan), options)
end

function FourslashTest:getBaselineForSpansWithFileContents(spans, options)
    local spansByFile = collections.GroupBy(spans, function(span)
        return span.uri
    end)
    if options.preserveResultOrder then
        options.orderedFiles = fourslash.uniqueFilesInSpanOrder(spans)
    end
    return self:getBaselineForGroupedSpansWithFileContents(spansByFile, options)
end

function FourslashTest:getBaselineForGroupedSpansWithFileContents(groupedRanges, options)
    local foundMarker = false
    local foundAdditionalLocation = false
    local spanToContextId = {}
    local baselineEntries = {}
    local addFileEntry = function(path)
        local fileName = lsconv.FileNameToDocumentURI(path)
        local ranges = groupedRanges:Get(fileName)
        if gort.len(ranges) == 0 then
            return
        end
        local content, ok = self:textOfFile(path)
        if not ok then
            return
        end
        if (options.marker ~= nil) and (options.marker:FileName() == path) then
            foundMarker = true
        end
        if (options.additionalSpan ~= nil) and (options.additionalSpan.uri == fileName) then
            foundAdditionalLocation = true
        end
        baselineEntries = gort.append(baselineEntries, self:getBaselineContentForFile(path, content, ranges, spanToContextId, options))
    end
    local walkDirFn = function(path, d, e)
        if e ~= nil then
            return e
        end
        if not gort.fs.FileMode_IsRegular(d:Type()) then
            return nil
        end
        addFileEntry(path)
        return nil
    end
    if options.preserveResultOrder then
        for i19, uri in gort.ipairs(options.orderedFiles) do
            addFileEntry(lsproto.DocumentUri_FileName(uri))
        end
    else
        local err = self.vfs:WalkDir("/", walkDirFn)
        if (err ~= nil) and (not gort.errors.Is(err, gort.fs.ErrNotExist)) then
            error("walkdir error during fourslash baseline: " .. err:Error(), 0)
        end
        err = self.vfs:WalkDir("bundled:///", walkDirFn)
        if (err ~= nil) and (not gort.errors.Is(err, gort.fs.ErrNotExist)) then
            error("walkdir error during fourslash baseline: " .. err:Error(), 0)
        end
    end
    if (options.additionalSpan ~= nil) and (not foundAdditionalLocation) then
        local fileName = lsproto.DocumentUri_FileName(options.additionalSpan.uri)
        do
            local content, ok = self:textOfFile(fileName)
            if ok then
                baselineEntries = gort.append(baselineEntries, self:getBaselineContentForFile(fileName, content, { options.additionalSpan }, spanToContextId, options))
                if (options.marker ~= nil) and (options.marker:FileName() == fileName) then
                    foundMarker = true
                end
            end
        end
    end
    if (not foundMarker) and (options.marker ~= nil) then
        local markerFileName = options.marker:FileName()
        do
            local content, ok = self:textOfFile(markerFileName)
            if ok then
                baselineEntries = gort.append(baselineEntries, self:getBaselineContentForFile(markerFileName, content, nil, spanToContextId, options))
            end
        end
    end
    return gort.strings.Join(baselineEntries, "\n\n")
end

function fourslash.uniqueFilesInSpanOrder(spans)
    if gort.len(spans) == 0 then
        return nil
    end
    local seen = {}
    local result = gort.makeSlice(0, function() return "" end)
    for i21, span in gort.ipairs(spans) do
        do
            do
                local _, ok = gort.MapLookup(seen, span.uri, nil)
                if ok then
                    goto continue22
                end
            end
            seen[span.uri] = fourslash.Ignored
            result = gort.append(result, span.uri)
        end
        ::continue22::
    end
    return result
end

function FourslashTest:textOfFile(fileName)
    do
        local _, ok = gort.MapLookup(self.openFiles, fileName, nil)
        if ok then
            return self:getScriptInfo(fileName).content, true
        end
    end
    return self.vfs:ReadFile(fileName)
end

function fourslash.detailKind_isEnd(self)
    return (self == fourslash.detailKind.ContextEnd) or (self == fourslash.detailKind.TextEnd)
end

function fourslash.detailKind_isStart(self)
    return (self == fourslash.detailKind.ContextStart) or (self == fourslash.detailKind.TextStart)
end

function baselineDetail:getRange()
    local sw23 = self.kind
    if sw23 == fourslash.detailKind.ContextStart then
        do return self.span.contextSpan end
    elseif sw23 == fourslash.detailKind.ContextEnd then
        do return self.span.contextSpan end
    elseif sw23 == fourslash.detailKind.TextStart then
        do return self.span.textSpan end
    elseif sw23 == fourslash.detailKind.TextEnd then
        do return self.span.textSpan end
    elseif sw23 == fourslash.detailKind.Marker then
        do return lsproto.Range({ start = self.pos, end_ = self.pos }) end
    else
        error("unknown detail kind", 0)
    end
end

function FourslashTest:getBaselineContentForFile(fileName, content, spansInFile, spanToContextId, options)
    local details = {}
    local detailPrefixes = {}
    local detailSuffixes = {}
    local canDetermineContextIdInline = true
    if (options.marker ~= nil) and (options.marker:FileName() == fileName) then
        details = gort.append(details, setmetatable({ pos = options.marker:LSPos(), positionMarker = options.markerName, kind = 0 }, fourslash.baselineDetail))
    end
    for i24, span in gort.ipairs(spansInFile) do
        local contextSpanIndex = gort.len(details)
        if span.contextSpan ~= nil then
            details = gort.append(details, setmetatable({
                    pos = span.contextSpan.start,
                    positionMarker = "<|",
                    span = span,
                    kind = fourslash.detailKind.ContextStart,
                }, fourslash.baselineDetail))
            if lsproto.ComparePositions(span.contextSpan.start, span.textSpan.start) > 0 then
                canDetermineContextIdInline = false
            end
        end
        local textSpanIndex = gort.len(details)
        local startMarker = "[|"
        if options.getLocationData ~= nil then
            startMarker = startMarker .. options.getLocationData(span)
        end
        details = gort.append(details, setmetatable({
                pos = span.textSpan.start,
                positionMarker = startMarker,
                span = span,
                kind = fourslash.detailKind.TextStart,
            }, fourslash.baselineDetail), setmetatable({
                pos = span.textSpan.end_,
                positionMarker = core.OrElse(options.endMarker, "|]"),
                span = span,
                kind = fourslash.detailKind.TextEnd,
            }, fourslash.baselineDetail))
        if span.contextSpan ~= nil then
            details = gort.append(details, setmetatable({
                    pos = span.contextSpan.end_,
                    positionMarker = "|>",
                    span = span,
                    kind = fourslash.detailKind.ContextEnd,
                }, fourslash.baselineDetail))
        end
        if options.startMarkerPrefix ~= nil then
            local startPrefix = options.startMarkerPrefix(span)
            if startPrefix ~= nil then
                if ((options.marker ~= nil) and (fileName == options.marker:FileName())) and (gort.StructEqual(span.textSpan.start, options.marker:LSPos())) then
                    local _, ok = gort.MapLookup(detailPrefixes, details[1], "")
                    debug.Assert(not ok, "Expected only single prefix at marker location")
                    detailPrefixes[details[1]] = startPrefix
                elseif (span.contextSpan ~= nil) and (gort.StructEqual(span.contextSpan.start, span.textSpan.start)) then
                    detailPrefixes[details[contextSpanIndex + 1]] = startPrefix
                else
                    detailPrefixes[details[textSpanIndex + 1]] = startPrefix
                end
            end
        end
        if options.endMarkerSuffix ~= nil then
            local endSuffix = options.endMarkerSuffix(span)
            if endSuffix ~= nil then
                if ((options.marker ~= nil) and (fileName == options.marker:FileName())) and (gort.StructEqual(span.textSpan.end_, options.marker:LSPos())) then
                    detailSuffixes[details[1]] = endSuffix
                elseif (span.contextSpan ~= nil) and (gort.StructEqual(span.contextSpan.end_, span.textSpan.end_)) then
                    detailSuffixes[details[(textSpanIndex + 2) + 1]] = endSuffix
                else
                    detailSuffixes[details[(textSpanIndex + 1) + 1]] = endSuffix
                end
            end
        end
    end
    gort.slices.SortStableFunc(details, function(d1, d2)
        local c = lsproto.ComparePositions(d1.pos, d2.pos)
        if (c ~= 0) or ((d1.kind == fourslash.detailKind.Marker) and (d2.kind == fourslash.detailKind.Marker)) then
            return c
        end
        if (d1.kind == fourslash.detailKind.Marker) and fourslash.detailKind_isStart(d2.kind) then
            return -1
        end
        if (d2.kind == fourslash.detailKind.Marker) and fourslash.detailKind_isStart(d1.kind) then
            return 1
        end
        if (d1.kind == fourslash.detailKind.Marker) and fourslash.detailKind_isEnd(d2.kind) then
            return 1
        end
        if (d2.kind == fourslash.detailKind.Marker) and fourslash.detailKind_isEnd(d1.kind) then
            return -1
        end
        if d1.span == d2.span then
            return d1.kind - d2.kind
        end
        if fourslash.detailKind_isStart(d1.kind) and fourslash.detailKind_isEnd(d2.kind) then
            return 1
        end
        if fourslash.detailKind_isEnd(d1.kind) and fourslash.detailKind_isStart(d2.kind) then
            return -1
        end
        if fourslash.detailKind_isEnd(d1.kind) and fourslash.detailKind_isEnd(d2.kind) then
            local c = lsproto.ComparePositions(d2:getRange().start, d1:getRange().start)
            if c ~= 0 then
                return c
            end
            return d1.kind - d2.kind
        end
        if fourslash.detailKind_isStart(d1.kind) and fourslash.detailKind_isStart(d2.kind) then
            local c = lsproto.ComparePositions(d2:getRange().end_, d2:getRange().end_)
            if c ~= 0 then
                return c
            end
            return d1.kind - d2.kind
        end
        return 0
    end)
    local textWithContext = fourslash.newTextWithContext(fileName, content)
    for i26, detail in gort.ipairs(details) do
        local index = i26 - 1
        textWithContext:add(detail)
        textWithContext.pos = gort.CloneStruct(detail.pos)
        local prefix = (detailPrefixes[detail] or "")
        if prefix ~= "" then
            textWithContext.newContent:WriteString(prefix)
        end
        textWithContext.newContent:WriteString(detail.positionMarker)
        if detail.span ~= nil then
            local sw28 = detail.kind
            if sw28 == fourslash.detailKind.TextStart then
                local text = ""
                do
                    local contextId, ok = gort.MapLookup(spanToContextId, gort.Key(detail.span), 0)
                    if ok then
                        local isAfterContextStart = false
                        do
                            local textStartIndex = index - 1
                            while textStartIndex >= 0 do
                                local textStartDetail = details[textStartIndex + 1]
                                if (textStartDetail.kind == fourslash.detailKind.ContextStart) and (textStartDetail.span == detail.span) then
                                    isAfterContextStart = true
                                    break
                                end
                                if textStartDetail.span ~= nil then
                                    break
                                end
                                textStartIndex = textStartIndex - 1
                            end
                        end
                        if not isAfterContextStart then
                            if text == "" then
                                text = gort.fmt.Sprintf("contextId: %v", contextId)
                            else
                                text = (gort.fmt.Sprintf("contextId: %v", contextId) .. ", ") .. text
                            end
                        end
                    end
                end
                if text ~= "" then
                    textWithContext.newContent:WriteString("{ ")
                    textWithContext.newContent:WriteString(text)
                    textWithContext.newContent:WriteString(" |}")
                end
            elseif sw28 == fourslash.detailKind.ContextStart then
                if canDetermineContextIdInline then
                    spanToContextId[gort.Key(detail.span)] = gort.len(spanToContextId)
                end
            end
        end
        do
            local suffix, ok = gort.MapLookup(detailSuffixes, detail, "")
            if ok then
                textWithContext.newContent:WriteString(suffix)
            end
        end
    end
    textWithContext:add(nil)
    if textWithContext.newContent:Len() ~= 0 then
        textWithContext.readableContents:WriteString("\n")
        textWithContext:readableJsoncBaseline(textWithContext.newContent:String())
    end
    return textWithContext.readableContents:String()
end

function textWithContext:FileName()
    return self.fileName
end

function textWithContext:OriginalFileName()
    return self.fileName
end

function textWithContext:Text()
    return self.content
end

function textWithContext:OriginalText()
    return self.content
end

function textWithContext:SpanMap()
    return nil
end

function fourslash.newTextWithContext(fileName, content)
    local t = setmetatable({
        nLinesContext = 4,
        readableContents = gort.NewBuilder(),
        isLibFile = fourslash.isLibFile(fileName),
        newContent = gort.NewBuilder(),
        pos = lsproto.Position({ line = 0, character = 0 }),
        fileName = fileName,
        content = content,
        lineStarts = lsconv.ComputeLSPLineStarts(content),
        lineInfo = 0,
    }, fourslash.textWithContext)
    t.converters = fourslash.newTestConverters(lsconv.NewConverters(lsproto.PositionEncodingKind.UTF8, function(_p30)
        return t.lineStarts
    end))
    t.readableContents:WriteString("// === ")
    t.readableContents:WriteString(fileName)
    t.readableContents:WriteString(" ===")
    return t
end

function textWithContext:add(detail)
    if (self.newContent:Len() == 0) and (detail == nil) then
        error("Unsupported", 0)
    end
    if (detail == nil) or (((detail.kind ~= fourslash.detailKind.TextEnd) and (detail.kind ~= fourslash.detailKind.ContextEnd))) then
        local posLineIndex = self.lineInfo
        if (self.posInfo == nil) or (not gort.StructEqual(self.posInfo, self.pos)) then
            posLineIndex = self.lineStarts:ComputeIndexOfLineStart(self.converters:LineAndCharacterToPosition(self, self.pos))
        end
        local locationLineIndex = gort.len(self.lineStarts.lineStarts) - 1
        if detail ~= nil then
            locationLineIndex = self.lineStarts:ComputeIndexOfLineStart(self.converters:LineAndCharacterToPosition(self, detail.pos))
            self.posInfo = detail.pos
            self.lineInfo = locationLineIndex
        end
        local nLines = 0
        if self.newContent:Len() ~= 0 then
            nLines = nLines + (self.nLinesContext + 1)
        end
        if detail ~= nil then
            nLines = nLines + (self.nLinesContext + 1)
        end
        if (locationLineIndex - posLineIndex) > nLines then
            if self.newContent:Len() ~= 0 then
                local skippedString = ""
                if self.isLibFile then
                    skippedString = "--- (line: --) skipped ---\n"
                else
                    skippedString = gort.fmt.Sprintf("--- (line: %v) skipped ---", (posLineIndex + self.nLinesContext) + 1)
                end
                self.readableContents:WriteString("\n")
                self:readableJsoncBaseline((self.newContent:String() .. self:sliceOfContent(self:getIndex(self.pos), self:getIndex(self.lineStarts.lineStarts[(posLineIndex + self.nLinesContext) + 1]))) .. skippedString)
                if detail ~= nil then
                    self.readableContents:WriteString("\n")
                end
                self.newContent:Reset()
            end
            if detail ~= nil then
                if self.isLibFile then
                    self.newContent:WriteString("--- (line: --) skipped ---\n")
                else
                    self.newContent:WriteString(gort.fmt.Sprintf("--- (line: %v) skipped ---\n", (locationLineIndex - self.nLinesContext) + 1))
                end
                self.newContent:WriteString(self:sliceOfContent(self:getIndex(self.lineStarts.lineStarts[((locationLineIndex - self.nLinesContext) + 1) + 1]), self:getIndex(detail.pos)))
            end
            return
        end
    end
    if detail == nil then
        self.newContent:WriteString(self:sliceOfContent(self:getIndex(self.pos), nil))
    else
        self.newContent:WriteString(self:sliceOfContent(self:getIndex(self.pos), self:getIndex(detail.pos)))
    end
end

function textWithContext:readableJsoncBaseline(text)
    for i31, line in gort.ipairs(fourslash.lineSplitter:Split(text, -1)) do
        local i = i31 - 1
        if i > 0 then
            self.readableContents:WriteString("\n")
        end
        self.readableContents:WriteString("// ")
        self.readableContents:WriteString(line)
    end
end

-- markerAndItem[T]: { marker, item }; Lua-only MarshalJSON keeps Go field order.
local markerAndItem = {}
markerAndItem.__index = markerAndItem
fourslash.markerAndItem = markerAndItem

function fourslash.newMarkerAndItem(marker, item)
    return setmetatable({ marker = marker, item = item }, markerAndItem)
end

function markerAndItem:MarshalJSON()
    local m, err = json.Marshal(self.marker)
    if err ~= nil then
        return nil, err
    end
    local i
    i, err = json.Marshal(self.item)
    if err ~= nil then
        return nil, err
    end
    return "{\"marker\":" .. m .. ",\"item\":" .. i .. "}", nil
end

function fourslash.annotateContentWithTooltips(t, f, markersAndItems, opName, getRange, getTooltipLines)
    local barWithGutter = "| " .. gort.strings.Repeat("-", 70)
    local sorted = gort.slices.Clone(markersAndItems)
    gort.slices.SortStableFunc(sorted, function(a, b)
        do
            local c = gort.cmp.Compare(a.marker:FileName(), b.marker:FileName())
            if c ~= 0 then
                return c
            end
        end
        return -gort.cmp.Compare(a.marker.position, b.marker.position)
    end)
    local filesToLines = collections.NewOrderedMapWithSizeHint(1)
    local previous = nil
    for i33, itemAndMarker in gort.ipairs(sorted) do
        local marker = itemAndMarker.marker
        local item = itemAndMarker.item
        local textRange = getRange(item)
        if textRange == nil then
            local start = gort.CloneStruct(marker.lsPosition)
            local end_ = gort.CloneStruct(start)
            end_.character = end_.character + 1
            textRange = lsproto.Range({ start = start, end_ = end_ })
        end
        if textRange.start.line ~= textRange.end_.line then
            t:Fatalf("Expected text range to be on a single line, got %v", textRange)
        end
        local underline = gort.strings.Repeat(" ", textRange.start.character) .. gort.strings.Repeat("^", textRange.end_.character - textRange.start.character)
        local fileName = marker:FileName()
        local lines, ok = filesToLines:Get(fileName)
        if not ok then
            lines = fourslash.lineSplitter:Split(f:getScriptInfo(fileName).content, -1)
        end
        local tooltipLines = nil
        if item ~= nil then
            tooltipLines = getTooltipLines(item, previous)
        end
        if gort.len(tooltipLines) == 0 then
            tooltipLines = { gort.fmt.Sprintf("No %s at /*%s*/.", opName, marker.name) }
        end
        tooltipLines = core.Map(tooltipLines, function(line)
                return "| " .. line
            end)
        local linesToInsert = gort.makeSlice(gort.len(tooltipLines) + 3, function() return "" end)
        linesToInsert[1] = underline
        linesToInsert[2] = barWithGutter
        gort.copyInto(linesToInsert, 2, tooltipLines)
        linesToInsert[(gort.len(linesToInsert) - 1) + 1] = barWithGutter
        lines = gort.slices.Insert(lines, textRange.start.line + 1, gort.unpack(linesToInsert))
        filesToLines:Set(fileName, lines)
        previous = item
    end
    local builder = gort.NewBuilder()
    local seenFirst = false
    for fileName, lines in gort.seq(filesToLines:Entries()) do
        builder:WriteString(gort.fmt.Sprintf("=== %s ===\n", fileName))
        for i36, line in gort.ipairs(lines) do
            builder:WriteString("// ")
            builder:WriteString(line)
            builder:WriteByte(10)
        end
        if seenFirst then
            builder:WriteString("\n\n")
        else
            seenFirst = true
        end
    end
    return builder:String()
end

function textWithContext:sliceOfContent(start, end_)
    if (start == nil) or (start < 0) then
        start = 0
    end
    if (end_ == nil) or (end_ > #self.content) then
        end_ = #self.content
    end
    if start > end_ then
        return ""
    end
    return string.sub(self.content, start + 1, end_)
end

-- Go switches on *int, int, core.TextPos, *core.TextPos (all Lua numbers or nil) and
-- lsproto.Position, *lsproto.Position.
function textWithContext:getIndex(i)
    if type(i) == "number" then
        return i
    elseif gort.IsStruct(i, "tslua.lsp.lsproto", "Position") or (type(i) == "table" and i.line ~= nil and i.character ~= nil) then
        return self:getIndex(self.converters:LineAndCharacterToPosition(self, i))
    end
    error(gort.fmt.Sprintf("getIndex: unsupported type %T", i), 0)
end

function fourslash.codeFence(lang, code)
    return ((("```" .. lang) .. "\n") .. code) .. "\n```"
end

function fourslash.symbolInformationToData(symbol)
    return gort.fmt.Sprintf("{| name: %s, kind: %s |}", symbol.name, lsproto.SymbolKind_String(symbol.kind))
end

fourslash.lineSplitter = gort.regexp.MustCompile("\\r?\\n")
