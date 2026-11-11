local sourcemap = require("tslua.sourcemap")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local MissingSource = sourcemap.SourceIndex.MissingSource

-- Host is an interface: any table with the methods
--   host:UseCaseSensitiveFileNames() -> bool
--   host:GetECMALineInfo(fileName) -> ECMALineInfo or nil
--   host:ReadFile(fileName) -> contents, ok

-- Similar to `Mapping`, but position-based.
local MappedPosition = {}
MappedPosition.__index = MappedPosition
sourcemap.MappedPosition = MappedPosition
sourcemap.SourceMappedPosition = MappedPosition

sourcemap.missingPosition = -1

function MappedPosition:isSourceMappedPosition()
    return self.sourceIndex ~= MissingSource and self.sourcePosition ~= sourcemap.missingPosition
end

local function newMappedPosition(generatedPosition, sourcePosition, sourceIndex, nameIndex)
    return setmetatable({
        generatedPosition = generatedPosition,
        sourcePosition = sourcePosition,
        sourceIndex = sourceIndex,
        nameIndex = nameIndex,
    }, MappedPosition)
end

-- Maps source positions to generated positions and vice versa.
local DocumentPositionMapper = {}
DocumentPositionMapper.__index = DocumentPositionMapper
sourcemap.DocumentPositionMapper = DocumentPositionMapper

function sourcemap.createDocumentPositionMapper(host, sourceMap, mapPath)
    local mapDirectory = tspath.GetDirectoryPath(mapPath)
    local sourceRoot
    if sourceMap.sourceRoot ~= "" then
        sourceRoot = tspath.GetNormalizedAbsolutePath(sourceMap.sourceRoot, mapDirectory)
    else
        sourceRoot = mapDirectory
    end
    local generatedAbsoluteFilePath = tspath.GetNormalizedAbsolutePath(sourceMap.file, mapDirectory)
    local sourceFileAbsolutePaths = core.Map(sourceMap.sources, function(source)
        return tspath.GetNormalizedAbsolutePath(source, sourceRoot)
    end)
    local useCaseSensitiveFileNames = host:UseCaseSensitiveFileNames()
    local sourceToSourceIndexMap = {}
    for i1, source in ipairs(sourceFileAbsolutePaths) do
        sourceToSourceIndexMap[tspath.GetCanonicalFileName(source, useCaseSensitiveFileNames)] = i1 - 1
    end

    local decodedMappings = {}
    local generatedMappings
    -- map[SourceIndex][]*SourceMappedPosition; sourceMappingsCount is len(map)
    local sourceMappings = {}
    local sourceMappingsCount = 0

    -- getDecodedMappings()
    local decoder = sourcemap.DecodeMappings(sourceMap.mappings)
    for mapping in decoder:Values() do
        -- processMapping()
        local generatedPosition = -1
        local lineInfo = host:GetECMALineInfo(generatedAbsoluteFilePath)
        if lineInfo ~= nil then
            generatedPosition = scanner.ComputePositionOfLineAndUTF16Character(
                lineInfo.lineStarts,
                mapping.generatedLine,
                mapping.generatedCharacter,
                lineInfo.text,
                true --[[allowEdits]]
            )
        end

        local sourcePosition = -1
        if mapping:IsSourceMapping() then
            local sourceLineInfo = host:GetECMALineInfo(sourceFileAbsolutePaths[mapping.sourceIndex + 1])
            if sourceLineInfo ~= nil then
                local pos = scanner.ComputePositionOfLineAndUTF16Character(
                    sourceLineInfo.lineStarts,
                    mapping.sourceLine,
                    mapping.sourceCharacter,
                    sourceLineInfo.text,
                    true --[[allowEdits]]
                )
                sourcePosition = pos
            end
        end

        decodedMappings[#decodedMappings + 1] = newMappedPosition(generatedPosition, sourcePosition, mapping.sourceIndex, mapping.nameIndex)
    end
    if decoder:Error() ~= nil then
        decodedMappings = {}
    end

    -- getSourceMappings()
    for _, mapping in ipairs(decodedMappings) do
        if mapping:isSourceMappedPosition() then
            local sourceIndex = mapping.sourceIndex
            local list = sourceMappings[sourceIndex]
            if list == nil then
                list = {}
                sourceMappingsCount = sourceMappingsCount + 1
            end
            list[#list + 1] = newMappedPosition(mapping.generatedPosition, mapping.sourcePosition, sourceIndex, mapping.nameIndex)
            sourceMappings[sourceIndex] = list
        end
    end
    for i, list in pairs(sourceMappings) do
        sourcemap.sortFunc(list, function(a, b)
            if a.sourceIndex ~= b.sourceIndex then
                error("All source mappings should have the same source index", 0)
            end
            return a.sourcePosition - b.sourcePosition
        end)
        sourceMappings[i] = core.DeduplicateSorted(list, function(a, b)
            return a.generatedPosition == b.generatedPosition and
                a.sourceIndex == b.sourceIndex and
                a.sourcePosition == b.sourcePosition
        end)
    end

    -- getGeneratedMappings()
    generatedMappings = decodedMappings
    sourcemap.sortFunc(generatedMappings, function(a, b)
        return a.generatedPosition - b.generatedPosition
    end)
    generatedMappings = core.DeduplicateSorted(generatedMappings, function(a, b)
        return a.generatedPosition == b.generatedPosition and
            a.sourceIndex == b.sourceIndex and
            a.sourcePosition == b.sourcePosition
    end)

    return setmetatable({
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
        sourceFileAbsolutePaths = sourceFileAbsolutePaths,
        sourceToSourceIndexMap = sourceToSourceIndexMap,
        generatedAbsoluteFilePath = generatedAbsoluteFilePath,
        generatedMappings = generatedMappings,
        sourceMappings = sourceMappings,
        sourceMappingsCount = sourceMappingsCount,
    }, DocumentPositionMapper)
end

-- DocumentPosition: { fileName = string, pos = int }
function sourcemap.NewDocumentPosition(fileName, pos)
    return { fileName = fileName, pos = pos }
end

function DocumentPositionMapper:GetSourcePosition(loc)
    if self == nil then
        return nil
    end
    if core.Len(self.generatedMappings) == 0 then
        return nil
    end

    local targetIndex = sourcemap.binarySearchFunc(self.generatedMappings, loc.pos, function(m, pos)
        return m.generatedPosition - pos
    end)

    if targetIndex < 0 or targetIndex >= #self.generatedMappings then
        return nil
    end

    local mapping = self.generatedMappings[targetIndex + 1]
    if not mapping:isSourceMappedPosition() then
        return nil
    end

    -- Closest position
    return sourcemap.NewDocumentPosition(self.sourceFileAbsolutePaths[mapping.sourceIndex + 1], mapping.sourcePosition)
end

function DocumentPositionMapper:GetGeneratedPosition(loc)
    if self == nil then
        return nil
    end
    local sourceIndex = self.sourceToSourceIndexMap[tspath.GetCanonicalFileName(loc.fileName, self.useCaseSensitiveFileNames)]
    if sourceIndex == nil then
        return nil
    end
    if sourceIndex < 0 or sourceIndex >= self.sourceMappingsCount then
        return nil
    end
    local sourceMappings = self.sourceMappings[sourceIndex] or {}
    local targetIndex = sourcemap.binarySearchFunc(sourceMappings, loc.pos, function(m, pos)
        return m.sourcePosition - pos
    end)

    if targetIndex < 0 or targetIndex >= #sourceMappings then
        return nil
    end

    local mapping = sourceMappings[targetIndex + 1]
    if mapping.sourceIndex ~= sourceIndex then
        return nil
    end

    -- Closest position
    return sourcemap.NewDocumentPosition(self.generatedAbsoluteFilePath, mapping.generatedPosition)
end

function sourcemap.GetDocumentPositionMapper(host, generatedFileName)
    local mapFileName = sourcemap.tryGetSourceMappingURL(host, generatedFileName)
    if mapFileName ~= "" then
        local base64Object, matched = sourcemap.tryParseBase64Url(mapFileName)
        if matched then
            if base64Object ~= "" then
                local decoded, err = sourcemap.base64StdDecode(base64Object)
                if err == nil then
                    return sourcemap.convertDocumentToSourceMapper(host, decoded, generatedFileName)
                end
            end
            -- Not a data URL we can parse, skip it
            mapFileName = ""
        end
    end

    local possibleMapLocations = {}
    if mapFileName ~= "" then
        possibleMapLocations[#possibleMapLocations + 1] = mapFileName
    end
    possibleMapLocations[#possibleMapLocations + 1] = generatedFileName .. ".map"
    for _, location in ipairs(possibleMapLocations) do
        local locationFileName = tspath.GetNormalizedAbsolutePath(location, tspath.GetDirectoryPath(generatedFileName))
        local mapFileContents, ok = host:ReadFile(locationFileName)
        if ok then
            return sourcemap.convertDocumentToSourceMapper(host, mapFileContents, locationFileName)
        end
    end
    return nil
end

function sourcemap.convertDocumentToSourceMapper(host, contents, mapFileName)
    local sourceMap = sourcemap.tryParseRawSourceMap(contents)
    if sourceMap == nil or core.Len(sourceMap.sources) == 0 or sourceMap.file == "" or sourceMap.mappings == "" then
        -- invalid map
        return nil
    end

    -- Don't support source maps that contain inlined sources
    if sourceMap.sourcesContent ~= nil then
        for _, s in ipairs(sourceMap.sourcesContent) do
            if s ~= false then
                return nil
            end
        end
    end

    return sourcemap.createDocumentPositionMapper(host, sourceMap, mapFileName)
end

function sourcemap.tryParseRawSourceMap(contents)
    local sourceMap = sourcemap.unmarshalRawSourceMap(contents)
    if sourceMap == nil then
        return nil
    end
    if sourceMap.version ~= 3 then
        return nil
    end
    return sourceMap
end

function sourcemap.tryGetSourceMappingURL(host, fileName)
    local lineInfo = host:GetECMALineInfo(fileName)
    return sourcemap.TryGetSourceMappingURL(lineInfo)
end

local function cutPrefix(s, prefix)
    if string.sub(s, 1, #prefix) == prefix then
        return string.sub(s, #prefix + 1), true
    end
    return s, false
end

-- Equivalent to /^data:(?:application\/json;(?:charset=[uU][tT][fF]-8;)?base64,([A-Za-z0-9+/=]+)$)?/
-- Returns parseableUrl, isBase64Url.
function sourcemap.tryParseBase64Url(url)
    local found
    url, found = cutPrefix(url, "data:")
    if not found then
        return "", false
    end
    url, found = cutPrefix(url, "application/json;")
    if not found then
        return "", true
    end
    url, found = cutPrefix(url, "charset=")
    if found then
        if #url < #"utf-8;" then
            -- Go panics here (slice bounds out of range)
            error("runtime error: slice bounds out of range [:6] with length " .. tostring(#url), 0)
        end
        if string.lower(string.sub(url, 1, #"utf-8;")) ~= "utf-8;" then
            return "", true
        end
        url = string.sub(url, #"utf-8;" + 1)
    end
    url, found = cutPrefix(url, "base64,")
    if not found then
        return "", true
    end
    for i = 1, #url do
        local r = string.byte(url, i)
        if not (stringutil.IsASCIILetter(r) or stringutil.IsDigit(r) or r == 0x2B or r == 0x2F or r == 0x3D) then
            return "", true
        end
    end
    return url, true
end

-- Lua-only helpers: slices.SortFunc (stable merge sort; Go's pdqsort is unstable for n > 12),
-- slices.BinarySearchFunc and json.Unmarshal into a RawSourceMap.

function sourcemap.sortFunc(xs, cmp)
    local n = #xs
    if n < 2 then
        return
    end
    local tmp = {}
    local width = 1
    while width < n do
        local lo = 1
        while lo <= n do
            local mid = math.min(lo + width, n + 1)
            local hi = math.min(lo + 2 * width, n + 1)
            local i, j, k = lo, mid, lo
            while i < mid and j < hi do
                if cmp(xs[j], xs[i]) < 0 then
                    tmp[k] = xs[j]
                    j = j + 1
                else
                    tmp[k] = xs[i]
                    i = i + 1
                end
                k = k + 1
            end
            while i < mid do
                tmp[k] = xs[i]
                i = i + 1
                k = k + 1
            end
            while j < hi do
                tmp[k] = xs[j]
                j = j + 1
                k = k + 1
            end
            lo = hi
        end
        for m = 1, n do
            xs[m] = tmp[m]
        end
        width = width * 2
    end
end

-- Returns the 0-based insertion index and whether target was found.
function sourcemap.binarySearchFunc(xs, target, cmp)
    local n = #xs
    local i, j = 0, n
    while i < j do
        local h = (i + j) // 2
        if cmp(xs[h + 1], target) < 0 then
            i = h + 1
        else
            j = h
        end
    end
    return i, i < n and cmp(xs[i + 1], target) == 0
end

local jsonNull = setmetatable({}, { __name = "json null" })

local function jsonError(msg)
    error({ jsonError = msg }, 0)
end

local function skipWhitespace(s, pos)
    while pos <= #s do
        local c = string.byte(s, pos)
        if c ~= 0x20 and c ~= 0x09 and c ~= 0x0A and c ~= 0x0D then
            break
        end
        pos = pos + 1
    end
    return pos
end

local function hexValue(s, pos)
    local h = string.sub(s, pos, pos + 3)
    if #h ~= 4 or not string.match(h, "^%x%x%x%x$") then
        jsonError("invalid escape sequence")
    end
    return tonumber(h, 16)
end

local function parseString(s, pos)
    -- s[pos] == '"'
    local parts = {}
    pos = pos + 1
    local start = pos
    while true do
        if pos > #s then
            jsonError("unexpected EOF")
        end
        local c = string.byte(s, pos)
        if c == 0x22 then
            parts[#parts + 1] = string.sub(s, start, pos - 1)
            return table.concat(parts), pos + 1
        elseif c == 0x5C then
            parts[#parts + 1] = string.sub(s, start, pos - 1)
            local e = string.byte(s, pos + 1)
            if e == 0x22 or e == 0x5C or e == 0x2F then
                parts[#parts + 1] = string.char(e)
                pos = pos + 2
            elseif e == 0x62 then
                parts[#parts + 1] = "\b"
                pos = pos + 2
            elseif e == 0x66 then
                parts[#parts + 1] = "\f"
                pos = pos + 2
            elseif e == 0x6E then
                parts[#parts + 1] = "\n"
                pos = pos + 2
            elseif e == 0x72 then
                parts[#parts + 1] = "\r"
                pos = pos + 2
            elseif e == 0x74 then
                parts[#parts + 1] = "\t"
                pos = pos + 2
            elseif e == 0x75 then
                local r = hexValue(s, pos + 2)
                pos = pos + 6
                if r >= 0xD800 and r <= 0xDBFF then
                    if string.sub(s, pos, pos + 1) ~= "\\u" then
                        jsonError("invalid UTF-8")
                    end
                    local r2 = hexValue(s, pos + 2)
                    if r2 < 0xDC00 or r2 > 0xDFFF then
                        jsonError("invalid UTF-8")
                    end
                    pos = pos + 6
                    r = 0x10000 + ((r - 0xD800) << 10) + (r2 - 0xDC00)
                elseif r >= 0xDC00 and r <= 0xDFFF then
                    jsonError("invalid UTF-8")
                end
                parts[#parts + 1] = utf8.char(r)
            else
                jsonError("invalid escape sequence")
            end
            start = pos
        elseif c < 0x20 then
            jsonError("invalid character in string")
        elseif c < 0x80 then
            pos = pos + 1
        else
            local r, size = sourcemap.decodeRune(s, pos - 1)
            if r == 0xFFFD and size == 1 then
                jsonError("invalid UTF-8")
            end
            pos = pos + size
        end
    end
end

local parseValue

local function parseNumber(s, pos)
    local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if num == nil then
        jsonError("invalid character")
    end
    -- validate the exact JSON grammar
    local ok = string.match(num, "^-?0$") or string.match(num, "^-?[1-9]%d*$") or
        string.match(num, "^-?0%.%d+$") or string.match(num, "^-?[1-9]%d*%.%d+$") or
        string.match(num, "^-?0[eE][-+]?%d+$") or string.match(num, "^-?[1-9]%d*[eE][-+]?%d+$") or
        string.match(num, "^-?0%.%d+[eE][-+]?%d+$") or string.match(num, "^-?[1-9]%d*%.%d+[eE][-+]?%d+$")
    if not ok then
        jsonError("invalid number")
    end
    return { number = num }, pos + #num
end

parseValue = function(s, pos)
    pos = skipWhitespace(s, pos)
    local c = string.byte(s, pos)
    if c == nil then
        jsonError("unexpected EOF")
    elseif c == 0x22 then
        return parseString(s, pos)
    elseif c == 0x7B then -- '{'
        local obj = { members = {}, order = {} }
        pos = skipWhitespace(s, pos + 1)
        if string.byte(s, pos) == 0x7D then
            return obj, pos + 1
        end
        while true do
            pos = skipWhitespace(s, pos)
            if string.byte(s, pos) ~= 0x22 then
                jsonError("invalid character")
            end
            local name
            name, pos = parseString(s, pos)
            if obj.members[name] ~= nil then
                jsonError("duplicate object member name")
            end
            pos = skipWhitespace(s, pos)
            if string.byte(s, pos) ~= 0x3A then
                jsonError("invalid character")
            end
            local value
            value, pos = parseValue(s, pos + 1)
            obj.members[name] = value
            obj.order[#obj.order + 1] = name
            pos = skipWhitespace(s, pos)
            local d = string.byte(s, pos)
            if d == 0x2C then
                pos = pos + 1
            elseif d == 0x7D then
                return obj, pos + 1
            else
                jsonError("invalid character")
            end
        end
    elseif c == 0x5B then -- '['
        local arr = { elements = {} }
        pos = skipWhitespace(s, pos + 1)
        if string.byte(s, pos) == 0x5D then
            return arr, pos + 1
        end
        while true do
            local value
            value, pos = parseValue(s, pos)
            arr.elements[#arr.elements + 1] = value
            pos = skipWhitespace(s, pos)
            local d = string.byte(s, pos)
            if d == 0x2C then
                pos = pos + 1
            elseif d == 0x5D then
                return arr, pos + 1
            else
                jsonError("invalid character")
            end
        end
    elseif string.sub(s, pos, pos + 3) == "true" then
        return true, pos + 4
    elseif string.sub(s, pos, pos + 4) == "false" then
        return false, pos + 5
    elseif string.sub(s, pos, pos + 3) == "null" then
        return jsonNull, pos + 4
    elseif c == 0x2D or (c >= 0x30 and c <= 0x39) then
        return parseNumber(s, pos)
    end
    jsonError("invalid character")
end

local function decodeString(v)
    if v == jsonNull then
        return ""
    end
    if type(v) ~= "string" then
        jsonError("cannot unmarshal into Go string")
    end
    return v
end

local function decodeStringSlice(v, nilElement)
    if v == jsonNull then
        return nil
    end
    if type(v) ~= "table" or v.elements == nil then
        jsonError("cannot unmarshal into Go slice")
    end
    local result = {}
    for i, e in ipairs(v.elements) do
        if e == jsonNull then
            result[i] = nilElement
        else
            result[i] = decodeString(e)
        end
    end
    return result
end

local function decodeInt(v)
    if v == jsonNull then
        return 0
    end
    if type(v) ~= "table" or v.number == nil then
        jsonError("cannot unmarshal into Go int")
    end
    if not string.match(v.number, "^-?%d+$") then
        jsonError("cannot unmarshal JSON number into Go int")
    end
    local n = math.tointeger(tonumber(v.number))
    if n == nil then
        jsonError("cannot unmarshal JSON number into Go int: value out of range")
    end
    return n
end

-- json.Unmarshal(contents, &RawSourceMap{}); returns the RawSourceMap or nil on error.
function sourcemap.unmarshalRawSourceMap(contents)
    local ok, result = pcall(function()
        local value, pos = parseValue(contents, 1)
        pos = skipWhitespace(contents, pos)
        if pos <= #contents then
            jsonError("invalid character after top-level value")
        end
        if value == jsonNull then
            return setmetatable({ version = 0, file = "", sourceRoot = "", mappings = "" }, sourcemap.RawSourceMap)
        end
        if type(value) ~= "table" or value.members == nil then
            jsonError("cannot unmarshal into Go struct")
        end
        local m = setmetatable({ version = 0, file = "", sourceRoot = "", mappings = "" }, sourcemap.RawSourceMap)
        for _, name in ipairs(value.order) do
            local v = value.members[name]
            if name == "version" then
                m.version = decodeInt(v)
            elseif name == "file" then
                m.file = decodeString(v)
            elseif name == "sourceRoot" then
                m.sourceRoot = decodeString(v)
            elseif name == "sources" then
                m.sources = decodeStringSlice(v, "")
            elseif name == "names" then
                m.names = decodeStringSlice(v, "")
            elseif name == "mappings" then
                m.mappings = decodeString(v)
            elseif name == "sourcesContent" then
                m.sourcesContent = decodeStringSlice(v, false)
            end
        end
        return m
    end)
    if not ok then
        if type(result) == "table" and result.jsonError ~= nil then
            return nil
        end
        error(result, 0)
    end
    return result
end
