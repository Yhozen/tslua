local fourslash = require("tslua.fourslash")
local core = require("tslua.core")
local json = require("tslua.json")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local stringutil = require("tslua.stringutil")
local testrunner = require("tslua.testrunner")
local tspath = require("tslua.tspath")
local gort = require("tslua.fourslash.goruntime")

-- Inserted in source files by surrounding desired text
-- in a range with `[|` and `|]`. For example,
--
-- [|text in range|]
--
-- is a range with `text in range` "selected".
-- RangeMarker: { fileName, range (core.TextRange), lsRange (lsproto.Range), marker (*Marker) }
local RangeMarker = {}
RangeMarker.__index = RangeMarker
fourslash.RangeMarker = RangeMarker

function RangeMarker:LSPos()
    return self.lsRange.start
end

function RangeMarker:FileName()
    return self.fileName
end

function RangeMarker:GetName()
    if self.marker == nil then
        return nil
    end
    return self.marker.name
end

function RangeMarker:LSLocation()
    return {
        uri = lsconv.FileNameToDocumentURI(self.fileName),
        range = self.lsRange,
    }
end

-- Marker: { fileName, position, lsPosition (lsproto.Position), name (string or nil for anonymous
-- markers such as `{| "foo": "bar" |}`), data (map[string]any) }
local Marker = {}
Marker.__index = Marker
fourslash.Marker = Marker

function Marker:LSPos()
    return self.lsPosition
end

function Marker:FileName()
    return self.fileName
end

function Marker:GetName()
    return self.name
end

function Marker:MakerWithSymlink(fileName)
    return setmetatable({
        fileName = fileName,
        position = self.position,
        lsPosition = self.lsPosition,
        name = self.name,
        data = self.data,
    }, Marker)
end

-- MarkerOrRange interface: FileName(), LSPos(), GetName(). Lua-only helpers for Go type switches.
function fourslash.IsMarker(v)
    return type(v) == "table" and getmetatable(v) == Marker
end

function fourslash.IsRangeMarker(v)
    return type(v) == "table" and getmetatable(v) == RangeMarker
end

-- TestData: { files, markerPositions, markers, symlinks, globalOptions, ranges }
local TestData = {}
TestData.__index = TestData
fourslash.TestData = TestData

function TestData:isStateBaseliningEnabled()
    return fourslash.isStateBaseliningEnabled(self.globalOptions)
end

-- testFileWithMarkers: { file, markers, ranges }

function fourslash.isStateBaseliningEnabled(globalOptions)
    return globalOptions["statebaseline"] == "true"
end

function fourslash.ParseTestData(t, contents, fileName)
    -- List of all the subfiles we've parsed out
    local files = {}

    local markerPositions = {}
    local markers = {}
    local ranges = {}

    local filesWithMarker, symlinks, _, globalOptions, e = testrunner.ParseTestFilesAndSymlinksWithOptions(
        contents,
        fileName,
        fourslash.parseFileContent,
        {
            allowImplicitFirstFile = true,
        }
    )
    if e ~= nil then
        t:Fatalf("Error parsing fourslash data: %s", e:Error())
    end

    local hasTSConfig = false
    for _, file in ipairs(filesWithMarker) do
        files[#files + 1] = file.file
        hasTSConfig = hasTSConfig or fourslash.isConfigFile(file.file.fileName)

        for _, m in ipairs(file.markers) do
            markers[#markers + 1] = m
        end
        for _, r in ipairs(file.ranges) do
            ranges[#ranges + 1] = r
        end
        for _, marker in ipairs(file.markers) do
            if marker.name == nil then
                if marker.data ~= nil then
                    -- The marker is an anonymous object marker, which does not need a name. Markers are only set into markerPositions if they have a name
                    goto continue
                end
                t:Fatalf("Marker at position %v is unnamed", marker.position)
            end
            do
                local existing = markerPositions[marker.name]
                if existing ~= nil then
                    t:Fatalf("Duplicate marker name: \"%s\" at %v and %v", marker.name, marker.position, existing.position)
                end
            end
            markerPositions[marker.name] = marker
            ::continue::
        end
    end

    if hasTSConfig and fourslash.hasUnsupportedGlobalOptionsWithConfig(globalOptions) and not fourslash.isStateBaseliningEnabled(globalOptions) then
        t:Fatalf("It is not allowed to use global options along with config files.")
    end

    return setmetatable({
        files = files,
        markerPositions = markerPositions,
        markers = markers,
        symlinks = symlinks,
        globalOptions = globalOptions,
        ranges = ranges,
    }, TestData)
end

function fourslash.hasUnsupportedGlobalOptionsWithConfig(globalOptions)
    for option in pairs(globalOptions) do
        local o = string.lower(option)
        if not (o == "symlink" or o == "link" or o == "usecasesensitivefilenames") then
            return true
        end
    end
    return false
end

function fourslash.isConfigFile(fileName)
    fileName = string.lower(fileName)
    return gort.strings.HasSuffix(fileName, "tsconfig.json") or gort.strings.HasSuffix(fileName, "jsconfig.json")
end

-- locationInformation: { position, sourcePosition, sourceLine, sourceColumn }
-- rangeLocationInformation: locationInformation + { marker }

-- TestFileInfo: { fileName, content (the contents of the file, with markers, etc stripped out),
-- emit, open }
local TestFileInfo = {}
TestFileInfo.__index = TestFileInfo
fourslash.TestFileInfo = TestFileInfo

-- FileName implements lsconv.Script.
function TestFileInfo:FileName()
    return self.fileName
end

-- OriginalFileName implements lsconv.Script.
function TestFileInfo:OriginalFileName()
    return self.fileName
end

-- Text implements lsconv.Script.
function TestFileInfo:Text()
    return self.content
end

-- OriginalText implements lsconv.Script.
function TestFileInfo:OriginalText()
    return self.content
end

-- SpanMap implements lsconv.Script.
function TestFileInfo:SpanMap()
    return nil
end

fourslash.emitThisFileOption = "emitthisfile"
fourslash.noOpenFileOption = "noopen"

fourslash.parserState = {
    stateNone = 0,
    stateInSlashStarMarker = 1,
    stateInObjectMarker = 2,
}

local function trimSpace(s)
    return (string.gsub(string.gsub(s, "^[ \t\n\r\v\f]+", ""), "[ \t\n\r\v\f]+$", ""))
end

local function sub(s, a, b)
    if b == nil then
        return string.sub(s, a + 1)
    end
    return string.sub(s, a + 1, b)
end

local RuneError = 0xFFFD
local byte = string.byte

function fourslash.parseFileContent(fileName, content, fileOptions)
    fileName = tspath.GetNormalizedAbsolutePath(fileName, "/")
    content = fourslash.chompLeadingSpace(content)

    -- The file content (minus metacharacters) so far
    local output = core.NewStringBuilder()

    local markers = {}

    --/ A stack of the open range markers that are still unclosed
    local openRanges = {}
    --/ A list of closed ranges we've collected so far
    local rangeMarkers = {}

    -- The total number of metacharacters removed from the file (so far)
    local difference = 0

    -- One-based current position data
    local line = 1
    local column = 1

    -- The current marker (or maybe multi-line comment?) we're parsing, possibly
    local openMarker = nil

    -- The latest position of the start of an unflushed plain text area
    local lastNormalCharPosition = 0

    local function flush(lastSafeCharIndex)
        if lastSafeCharIndex ~= -1 then
            output:WriteString(sub(content, lastNormalCharPosition, lastSafeCharIndex))
        else
            output:WriteString(sub(content, lastNormalCharPosition))
        end
    end

    local state = fourslash.parserState.stateNone
    local previousCharacter, i = core.DecodeRune(content, 0)
    local size = 0
    local currentCharacter
    local n = #content
    if n == 0 then
        -- utf8.DecodeRuneInString("") = RuneError, 0
        previousCharacter, i = RuneError, 0
    end
    while i < n do
        currentCharacter, size = core.DecodeRune(content, i)
        if state == fourslash.parserState.stateNone then
            if previousCharacter == 0x5B --[[ [ ]] and currentCharacter == 0x7C --[[ | ]] then
                -- found a range start
                openRanges[#openRanges + 1] = {
                    position = (i - 1) - difference,
                    sourcePosition = i - 1,
                    sourceLine = line,
                    sourceColumn = column,
                    marker = nil,
                }
                -- copy all text up to marker position
                flush(i - 1)
                lastNormalCharPosition = i + 1
                difference = difference + 2
            elseif previousCharacter == 0x7C --[[ | ]] and currentCharacter == 0x5D --[[ ] ]] then
                -- found a range end
                if #openRanges == 0 then
                    return nil, fourslash.reportError(fileName, line, column, "Found range end with no matching start.")
                end
                local rangeStart = openRanges[#openRanges]
                openRanges[#openRanges] = nil

                local closedRange = setmetatable({
                    fileName = fileName,
                    range = core.NewTextRange(rangeStart.position, (i - 1) - difference),
                    marker = rangeStart.marker,
                }, RangeMarker)

                rangeMarkers[#rangeMarkers + 1] = closedRange

                -- copy all text up to range marker position
                flush(i - 1)
                lastNormalCharPosition = i + 1
                difference = difference + 2
            elseif previousCharacter == 0x2F --[[ / ]] and currentCharacter == 0x2A --[[ * ]] and (i + 1 >= n or byte(content, i + 2) ~= 0x2F) then
                -- found a possible marker start
                state = fourslash.parserState.stateInSlashStarMarker
                openMarker = {
                    position = (i - 1) - difference,
                    sourcePosition = i - 1,
                    sourceLine = line,
                    sourceColumn = column - 1,
                }
            elseif previousCharacter == 0x7B --[[ { ]] and currentCharacter == 0x7C --[[ | ]] then
                -- found an object marker start
                state = fourslash.parserState.stateInObjectMarker
                openMarker = {
                    position = (i - 1) - difference,
                    sourcePosition = i - 1,
                    sourceLine = line,
                    sourceColumn = column,
                }
                flush(i - 1)
            end
        elseif state == fourslash.parserState.stateInObjectMarker then
            -- Object markers are only ever terminated by |} and have no content restrictions
            if previousCharacter == 0x7C --[[ | ]] and currentCharacter == 0x7D --[[ } ]] then
                local objectMarkerData = trimSpace(sub(content, openMarker.sourcePosition + 2, i - 1))
                local marker, e = fourslash.getObjectMarker(fileName, openMarker, objectMarkerData)
                if e ~= nil then
                    return nil, e
                end

                if #openRanges > 0 then
                    openRanges[#openRanges].marker = marker
                end
                markers[#markers + 1] = marker

                -- Set the current start to point to the end of the current marker to ignore its text
                lastNormalCharPosition = i + 1
                difference = difference + (i + 1 - openMarker.sourcePosition)

                -- Reset the state
                openMarker = nil
                state = fourslash.parserState.stateNone
            end
        elseif state == fourslash.parserState.stateInSlashStarMarker then
            if previousCharacter == 0x2A --[[ * ]] and currentCharacter == 0x2F --[[ / ]] then
                -- Record the marker
                -- start + 2 to ignore the */, -1 on the end to ignore the * (/ is next)
                local markerNameText = trimSpace(sub(content, openMarker.sourcePosition + 2, i - 1))
                local marker = setmetatable({
                    fileName = fileName,
                    position = openMarker.position,
                    name = markerNameText,
                }, Marker)
                if #openRanges > 0 then
                    openRanges[#openRanges].marker = marker
                end
                markers[#markers + 1] = marker

                -- Set the current start to point to the end of the current marker to ignore its text
                flush(openMarker.sourcePosition)
                lastNormalCharPosition = i + 1
                difference = difference + (i + 1 - openMarker.sourcePosition)

                -- Reset the state
                openMarker = nil
                state = fourslash.parserState.stateNone
            elseif not (stringutil.IsDigit(currentCharacter) or
                    stringutil.IsASCIILetter(currentCharacter) or
                    currentCharacter == 0x24 --[[ $ ]] or
                    currentCharacter == 0x5F --[[ _ ]]) then -- Invalid marker character
                if currentCharacter == 0x2A --[[ * ]] and i < n - 1 and byte(content, i + 2) == 0x2F then
                    -- The marker is about to be closed, ignore the 'invalid' char
                else
                    -- We've hit a non-valid marker character, so we were actually in a block comment
                    -- Bail out the text we've gathered so far back into the output
                    flush(i)
                    lastNormalCharPosition = i
                    openMarker = nil
                    state = fourslash.parserState.stateNone
                end
            end
        end
        if currentCharacter == 0x0A and previousCharacter == 0x0D then
            -- Ignore trailing \n after \r
            goto continue
        elseif currentCharacter == 0x0A or currentCharacter == 0x0D then
            line = line + 1
            column = 1
            goto continue
        end
        column = column + 1
        if i >= lastNormalCharPosition then
            previousCharacter = currentCharacter
        else
            previousCharacter = RuneError -- reset to avoid accidentally reusing marker delimiters as part of other markers
        end
        ::continue::
        i = i + size
    end

    -- Add the remaining text
    flush(-1)

    if #openRanges > 0 then
        local openRange = openRanges[1]
        return nil, fourslash.reportError(fileName, openRange.sourceLine, openRange.sourceColumn, "Unterminated range.")
    end

    if openMarker ~= nil then
        return nil, fourslash.reportError(fileName, openMarker.sourceLine, openMarker.sourceColumn, "Unterminated marker.")
    end

    local outputString = output:String()
    -- Set LS positions for markers
    local lineMap = lsconv.ComputeLSPLineStarts(outputString)
    local converters = fourslash.newTestConverters(lsconv.NewConverters(lsproto.PositionEncodingKind.UTF8, function(_)
        return lineMap
    end))

    local emit = fileOptions[fourslash.emitThisFileOption] == "true"

    local testFileInfo = setmetatable({
        fileName = fileName,
        content = outputString,
        emit = emit,
        open = fileOptions[fourslash.noOpenFileOption] ~= "true",
    }, TestFileInfo)

    core.SortStableFunc(rangeMarkers, function(a, b)
        if a.range:Pos() ~= b.range:Pos() then
            return a.range:Pos() - b.range:Pos()
        end
        return b.range:End() - a.range:End()
    end)

    for _, marker in ipairs(markers) do
        marker.lsPosition = converters:PositionToLineAndCharacter(testFileInfo, marker.position)
    end
    for _, rangeMarker in ipairs(rangeMarkers) do
        rangeMarker.lsRange = {
            start = converters:PositionToLineAndCharacter(testFileInfo, rangeMarker.range:Pos()),
            ["end"] = converters:PositionToLineAndCharacter(testFileInfo, rangeMarker.range:End()),
        }
    end

    return {
        file = testFileInfo,
        markers = markers,
        ranges = rangeMarkers,
    }, nil
end

function fourslash.getObjectMarker(fileName, location, text)
    -- Attempt to parse the marker value as JSON
    local v, e = json.Unmarshal("{ " .. text .. " }")

    if e ~= nil then
        return nil, fourslash.reportError(fileName, location.sourceLine, location.sourceColumn, "Unable to parse marker text " .. text)
    end
    local markerValue = v
    if type(markerValue) ~= "table" or next(markerValue) == nil or markerValue[1] ~= nil then
        return nil, fourslash.reportError(fileName, location.sourceLine, location.sourceColumn, "Object markers can not be empty")
    end

    local marker = setmetatable({
        fileName = fileName,
        position = location.position,
        data = markerValue,
    }, Marker)

    -- Object markers can be anonymous
    if markerValue["name"] ~= nil then
        local name = markerValue["name"]
        if type(name) == "string" and name ~= "" then
            marker.name = name
        end
    end

    return marker, nil
end

function fourslash.reportError(fileName, line, col, message)
    return setmetatable({ err = string.format("%s (%d,%d): %s", fileName, line, col, message) }, fourslash.fourslashError)
end

function fourslash.chompLeadingSpace(content)
    local lines = gort.strings.Split(content, "\n")
    for _, line in ipairs(lines) do
        if #line > 0 and byte(line, 1) ~= 0x20 then
            return content
        end
    end

    local result = {}
    for i, line in ipairs(lines) do
        if #line > 0 then
            result[i] = string.sub(line, 2)
        else
            result[i] = ""
        end
    end
    return table.concat(result, "\n")
end

local fourslashError = {}
fourslashError.__index = fourslashError
fourslash.fourslashError = fourslashError

function fourslashError:Error()
    return self.err
end
