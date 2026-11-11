local harnessutil = require("tslua.testutil.harnessutil")
local core = require("tslua.core")
local json = require("tslua.json")
local scanner = require("tslua.scanner")
local sourcemap = require("tslua.sourcemap")
local stringutil = require("tslua.stringutil")

-- writerAggregator is a strings.Builder with formatting helpers.
local writerAggregator = {}
writerAggregator.__index = function(self, key)
    local m = writerAggregator[key]
    if m ~= nil then
        return m
    end
    return core.StringBuilder[key]
end
harnessutil.writerAggregator = writerAggregator

function harnessutil.newWriterAggregator()
    local w = core.NewStringBuilder()
    return setmetatable(w, writerAggregator)
end

function writerAggregator:WriteStringf(format, ...)
    self:WriteString(string.format(format, ...))
end

function writerAggregator:WriteLine(s)
    self:WriteString(s)
    self:WriteString("\r\n")
end

function writerAggregator:WriteLinef(format, ...)
    self:WriteStringf(format .. "\r\n", ...)
end

-- sourceMapSpanWithDecodeErrors: { sourceMapSpan = *sourcemap.Mapping, decodeErrors = []string }
-- decodedMapping: { sourceMapSpan = *sourcemap.Mapping, error = string or nil }

local sourceMapDecoder = {}
sourceMapDecoder.__index = sourceMapDecoder

function harnessutil.newSourceMapDecoder(sourceMap)
    return setmetatable({
        sourceMapMappings = sourceMap.mappings,
        mappings = sourcemap.DecodeMappings(sourceMap.mappings),
    }, sourceMapDecoder)
end

local function errorText(err)
    if type(err) == "table" and err.Error ~= nil then
        return err:Error()
    end
    return tostring(err)
end

function sourceMapDecoder:decodeNextEncodedSourceMapSpan()
    local value, done = self.mappings:Next()
    if done then
        local mapping = {
            error = self.mappings:Error(),
            sourceMapSpan = self.mappings:State(),
        }
        if mapping.error == nil then
            mapping.error = "No encoded entry found"
        end
        return mapping
    end
    return { sourceMapSpan = value, error = nil }
end

function sourceMapDecoder:hasCompletedDecoding()
    return self.mappings:Pos() == #self.sourceMapMappings
end

function sourceMapDecoder:getRemainingDecodeString()
    return string.sub(self.sourceMapMappings, self.mappings:Pos() + 1)
end

local sourceMapSpanWriter = {}
sourceMapSpanWriter.__index = sourceMapSpanWriter
harnessutil.sourceMapSpanWriter = sourceMapSpanWriter

function harnessutil.newSourceMapSpanWriter(sourceMapRecorder, sourceMap, jsFile)
    local writer = setmetatable({
        sourceMapRecorder = sourceMapRecorder,
        sourceMapSources = sourceMap.sources or {},
        sourceMapNames = sourceMap.names or {},
        jsFile = jsFile,
        jsLineMap = core.ComputeECMALineStarts(jsFile.content),
        tsCode = "",
        tsLineMap = nil,
        spansOnSingleLine = {},
        prevWrittenSourcePos = 0,
        nextJsLineToWrite = 0,
        spanMarkerContinues = false,
        sourceMapDecoder = harnessutil.newSourceMapDecoder(sourceMap),
    }, sourceMapSpanWriter)

    sourceMapRecorder:WriteLine("===================================================================")
    sourceMapRecorder:WriteLinef("JsFile: %s", sourceMap.file)
    sourceMapRecorder:WriteLinef("mapUrl: %s", sourcemap.TryGetSourceMappingURL(sourcemap.CreateECMALineInfo(jsFile.content, writer.jsLineMap)))
    sourceMapRecorder:WriteLinef("sourceRoot: %s", sourceMap.sourceRoot or "")
    sourceMapRecorder:WriteLinef("sources: %s", table.concat(sourceMap.sources or {}, ","))
    if core.Len(sourceMap.sourcesContent) > 0 then
        local content, err = json.Marshal(sourceMap.sourcesContent)
        if err ~= nil then
            error(err, 0)
        end
        sourceMapRecorder:WriteLinef("sourcesContent: %s", content)
    end
    sourceMapRecorder:WriteLine("===================================================================")
    return writer
end

function sourceMapSpanWriter:getSourceMapSpanString(mapEntry, getAbsentNameIndex)
    local mapString = harnessutil.newWriterAggregator()
    mapString:WriteStringf("Emitted(%d, %d)", mapEntry.generatedLine + 1, mapEntry.generatedCharacter + 1)
    if mapEntry:IsSourceMapping() then
        mapString:WriteStringf(" Source(%d, %d) + SourceIndex(%d)", mapEntry.sourceLine + 1, mapEntry.sourceCharacter + 1, mapEntry.sourceIndex)
        if mapEntry.nameIndex >= 0 and mapEntry.nameIndex < #self.sourceMapNames then
            mapString:WriteStringf(" name (%s)", self.sourceMapNames[mapEntry.nameIndex + 1])
        else
            if mapEntry.nameIndex ~= sourcemap.NameIndex.MissingName or getAbsentNameIndex then
                mapString:WriteStringf(" nameIndex (%d)", mapEntry.nameIndex)
            end
        end
    end
    return mapString:String()
end

function sourceMapSpanWriter:recordSourceMapSpan(sourceMapSpan)
    -- verify the decoded span is same as the new span
    local decodeResult = self.sourceMapDecoder:decodeNextEncodedSourceMapSpan()
    local decodeErrors = nil
    if decodeResult.error ~= nil or not decodeResult.sourceMapSpan:Equals(sourceMapSpan) then
        if decodeResult.error ~= nil then
            decodeErrors = { "!!^^ !!^^ There was decoding error in the sourcemap at this location: " .. errorText(decodeResult.error) }
        else
            decodeErrors = { "!!^^ !!^^ The decoded span from sourcemap's mapping entry does not match what was encoded for this span:" }
        end
        decodeErrors[#decodeErrors + 1] = "!!^^ !!^^ Decoded span from sourcemap's mappings entry: " ..
            self:getSourceMapSpanString(decodeResult.sourceMapSpan, true --[[getAbsentNameIndex]]) ..
            " Span encoded by the emitter:" ..
            self:getSourceMapSpanString(sourceMapSpan, true --[[getAbsentNameIndex]])
    end

    if #self.spansOnSingleLine > 0 and self.spansOnSingleLine[1].sourceMapSpan.generatedLine ~= sourceMapSpan.generatedLine then
        -- On different line from the one that we have been recording till now,
        self:writeRecordedSpans()
        self.spansOnSingleLine = {}
    end
    self.spansOnSingleLine[#self.spansOnSingleLine + 1] = {
        sourceMapSpan = sourceMapSpan,
        decodeErrors = decodeErrors,
    }
end

function sourceMapSpanWriter:recordNewSourceFileSpan(sourceMapSpan, newSourceFileCode)
    local continuesLine = false
    if #self.spansOnSingleLine > 0 and self.spansOnSingleLine[1].sourceMapSpan.generatedCharacter == sourceMapSpan.generatedLine then -- !!! char == line seems like a bug in Strada?
        self:writeRecordedSpans()
        self.spansOnSingleLine = {}
        self.nextJsLineToWrite = self.nextJsLineToWrite - 1 -- walk back one line to reprint the line
        continuesLine = true
    end

    self:recordSourceMapSpan(sourceMapSpan)

    if #self.spansOnSingleLine ~= 1 then
        error("expected a single span", 0)
    end

    self.sourceMapRecorder:WriteLine("-------------------------------------------------------------------")
    if continuesLine then
        self.sourceMapRecorder:WriteLinef("emittedFile:%s (%d, %d)", self.jsFile.unitName, sourceMapSpan.generatedLine + 1, sourceMapSpan.generatedCharacter + 1)
    else
        self.sourceMapRecorder:WriteLinef("emittedFile:%s", self.jsFile.unitName)
    end
    self.sourceMapRecorder:WriteLinef("sourceFile:%s", self.sourceMapSources[self.spansOnSingleLine[1].sourceMapSpan.sourceIndex + 1])
    self.sourceMapRecorder:WriteLine("-------------------------------------------------------------------")

    self.tsLineMap = core.ComputeECMALineStarts(newSourceFileCode)
    self.tsCode = newSourceFileCode
    self.prevWrittenSourcePos = 0
end

function sourceMapSpanWriter:close()
    -- Write the lines pending on the single line
    self:writeRecordedSpans()

    if not self.sourceMapDecoder:hasCompletedDecoding() then
        self.sourceMapRecorder:WriteLine("!!!! **** There are more source map entries in the sourceMap's mapping than what was encoded")
        self.sourceMapRecorder:WriteLinef("!!!! **** Remaining decoded string: %s", self.sourceMapDecoder:getRemainingDecodeString())
    end

    -- write remaining js lines
    self:writeJsFileLines(#self.jsLineMap)
end

function sourceMapSpanWriter:getTextOfLine(line, lineMap, code)
    local startPos = lineMap[line + 1]
    if startPos == nil then
        error(string.format("runtime error: index out of range [%d] with length %d", line, #lineMap), 0)
    end
    local endPos
    if line + 1 < #lineMap then
        endPos = lineMap[line + 2]
    else
        endPos = #code
    end
    local text = string.sub(code, startPos + 1, endPos)
    if line == 0 then
        return stringutil.RemoveByteOrderMark(text)
    end
    -- return line == 0 ? Utils.removeByteOrderMark(text) : text;
    return text
end

function sourceMapSpanWriter:writeJsFileLines(endJsLine)
    while self.nextJsLineToWrite < endJsLine do
        self.sourceMapRecorder:WriteString(">>>" .. self:getTextOfLine(self.nextJsLineToWrite, self.jsLineMap, self.jsFile.content))
        self.nextJsLineToWrite = self.nextJsLineToWrite + 1
    end
end

function sourceMapSpanWriter:writeRecordedSpans()
    local recordedSpanWriter = harnessutil.newRecordedSpanWriter(self)
    recordedSpanWriter:writeRecordedSpans()
end

local recordedSpanWriter = {}
recordedSpanWriter.__index = recordedSpanWriter

function harnessutil.newRecordedSpanWriter(w)
    return setmetatable({ markerIds = {}, prevEmittedCol = 0, w = w }, recordedSpanWriter)
end

function recordedSpanWriter:getMarkerId(markerIndex)
    local markerId
    if self.w.spanMarkerContinues then
        if markerIndex ~= 0 then
            error("expected markerIndex to be 0", 0)
        end
        markerId = "1->"
    else
        markerId = tostring(markerIndex + 1)
        if #markerId < 2 then
            markerId = markerId .. " "
        end
        markerId = markerId .. ">"
    end
    return markerId
end

function recordedSpanWriter:iterateSpans(fn)
    self.prevEmittedCol = 0
    for i = 0, #self.w.spansOnSingleLine - 1 do
        fn(self, self.w.spansOnSingleLine[i + 1], i)
        self.prevEmittedCol = self.w.spansOnSingleLine[i + 1].sourceMapSpan.generatedCharacter
    end
end

function recordedSpanWriter:writeSourceMapIndent(indentLength, indentPrefix)
    self.w.sourceMapRecorder:WriteString(indentPrefix)
    self.w.sourceMapRecorder:WriteString(string.rep(" ", indentLength))
end

function recordedSpanWriter:writeSourceMapMarker(currentSpan, index)
    self:writeSourceMapMarkerEx(currentSpan, index, currentSpan.sourceMapSpan.generatedCharacter, false --[[endContinues]])
end

function recordedSpanWriter:writeSourceMapMarkerEx(currentSpan, index, endColumn, endContinues)
    local markerId = self:getMarkerId(index)
    self.markerIds[#self.markerIds + 1] = markerId
    self:writeSourceMapIndent(self.prevEmittedCol, markerId)
    if endColumn > self.prevEmittedCol then
        self.w.sourceMapRecorder:WriteString(string.rep("^", endColumn - self.prevEmittedCol))
    end
    if endContinues then
        self.w.sourceMapRecorder:WriteString("->")
    end
    self.w.sourceMapRecorder:WriteLine("")
    self.w.spanMarkerContinues = endContinues
end

function recordedSpanWriter:writeSourceMapSourceText(currentSpan, index)
    -- Convert UTF-16 character offset from the source map to a byte position.
    local sourcePos = scanner.ComputePositionOfLineAndUTF16Character(
        self.w.tsLineMap,
        currentSpan.sourceMapSpan.sourceLine,
        currentSpan.sourceMapSpan.sourceCharacter,
        self.w.tsCode,
        true --[[allowEdits]]
    )
    local sourceText = ""
    if self.w.prevWrittenSourcePos < sourcePos then
        -- Position that goes forward, get text
        sourceText = string.sub(self.w.tsCode, self.w.prevWrittenSourcePos + 1, sourcePos)
    end

    -- If there are decode errors, write
    for _, decodeError in ipairs(currentSpan.decodeErrors or {}) do
        self:writeSourceMapIndent(self.prevEmittedCol, self.markerIds[index + 1])
        self.w.sourceMapRecorder:WriteLine(decodeError)
    end

    local tsCodeLineMap = core.ComputeECMALineStarts(sourceText)
    for i = 0, #tsCodeLineMap - 1 do
        if i == 0 then
            self:writeSourceMapIndent(self.prevEmittedCol, self.markerIds[index + 1])
        else
            self:writeSourceMapIndent(self.prevEmittedCol, "  >")
        end
        self.w.sourceMapRecorder:WriteString(self.w:getTextOfLine(i, tsCodeLineMap, sourceText))
        if i == #tsCodeLineMap - 1 then
            self.w.sourceMapRecorder:WriteLine("")
        end
    end

    self.w.prevWrittenSourcePos = sourcePos
end

function recordedSpanWriter:writeSpanDetails(currentSpan, index)
    self.w.sourceMapRecorder:WriteLine(self.markerIds[index + 1] .. self.w:getSourceMapSpanString(currentSpan.sourceMapSpan, false --[[getAbsentNameIndex]]))
end

function recordedSpanWriter:writeRecordedSpans()
    local w = self.w

    if #w.spansOnSingleLine > 0 then
        local currentJsLine = w.spansOnSingleLine[1].sourceMapSpan.generatedLine

        -- Write js line
        w:writeJsFileLines(currentJsLine + 1)

        -- Emit markers
        self:iterateSpans(recordedSpanWriter.writeSourceMapMarker)

        local jsFileText = w:getTextOfLine(currentJsLine + 1, w.jsLineMap, w.jsFile.content) -- TODO: Strada is wrong here, we should be looking at `currentJsLine`, not `currentJsLine+1`
        if self.prevEmittedCol < #jsFileText - 1 then
            -- There is remaining text on this line that will be part of next source span so write marker that continues
            self:writeSourceMapMarkerEx(nil --[[currentSpan]], #w.spansOnSingleLine, #jsFileText - 1 --[[endColumn]], true --[[endContinues]])
        end

        -- Emit Source text
        self:iterateSpans(recordedSpanWriter.writeSourceMapSourceText)

        -- Emit column number etc
        self:iterateSpans(recordedSpanWriter.writeSpanDetails)

        w.sourceMapRecorder:WriteLine("---")
    end
end

return harnessutil
