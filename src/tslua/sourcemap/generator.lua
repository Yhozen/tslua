local sourcemap = require("tslua.sourcemap")
local tspath = require("tslua.tspath")

sourcemap.sourceIndexNotSet = -1
sourcemap.nameIndexNotSet = -1
sourcemap.notSet = -1
sourcemap.notSetUTF16 = -1

local Generator = {}
Generator.__index = Generator
sourcemap.Generator = Generator

-- RawSourceMap: { version, file, sourceRoot, sources, names, mappings, sourcesContent }.
-- sourcesContent is nil (Go nil slice) or an array whose entries are a string or `false` (Go nil *string).
local RawSourceMap = {}
RawSourceMap.__index = RawSourceMap
sourcemap.RawSourceMap = RawSourceMap

function sourcemap.NewGenerator(file, sourceRoot, sourcesDirectoryPath, options)
    return setmetatable({
        pathOptions = options,
        file = file,
        sourceRoot = sourceRoot,
        sourcesDirectoryPath = sourcesDirectoryPath,
        rawSources = nil,
        sources = {},
        sourceToSourceIndexMap = {},
        sourcesContent = nil,
        names = {},
        nameToNameIndexMap = {},
        mappings = {}, -- strings.Builder: array of parts
        lastGeneratedLine = 0,
        lastGeneratedCharacter = 0,
        lastSourceIndex = 0,
        lastSourceLine = 0,
        lastSourceCharacter = 0,
        lastNameIndex = 0,
        hasLast = false,
        pendingGeneratedLine = 0,
        pendingGeneratedCharacter = 0,
        pendingSourceIndex = 0,
        pendingSourceLine = 0,
        pendingSourceCharacter = 0,
        pendingNameIndex = 0,
        hasPending = false,
        hasPendingSource = false,
        hasPendingName = false,
    }, Generator)
end

function Generator:Sources()
    return self.rawSources
end

-- Adds a source to the source map
function Generator:AddSource(fileName)
    local source = tspath.GetRelativePathToDirectoryOrUrl(
        self.sourcesDirectoryPath,
        fileName,
        true, --[[isAbsolutePathAnUrl]]
        self.pathOptions
    )

    local sourceIndex = self.sourceToSourceIndexMap[source]
    if sourceIndex == nil then
        sourceIndex = #self.sources
        self.sources[#self.sources + 1] = source
        if self.rawSources == nil then
            self.rawSources = {}
        end
        self.rawSources[#self.rawSources + 1] = fileName
        self.sourceToSourceIndexMap[source] = sourceIndex
    end

    return sourceIndex
end

-- Sets the content for a source. Returns an error message or nil.
function Generator:SetSourceContent(sourceIndex, content)
    if sourceIndex < 0 or sourceIndex >= #self.sources then
        return "sourceIndex is out of range"
    end
    if self.sourcesContent == nil then
        self.sourcesContent = {}
    end
    while #self.sourcesContent <= sourceIndex do
        self.sourcesContent[#self.sourcesContent + 1] = false
    end
    self.sourcesContent[sourceIndex + 1] = content
    return nil
end

-- Declares a name in the source map, returning the index of the name
function Generator:AddName(name)
    local nameIndex = self.nameToNameIndexMap[name]
    if nameIndex == nil then
        nameIndex = #self.names
        self.names[#self.names + 1] = name
        self.nameToNameIndexMap[name] = nameIndex
    end
    return nameIndex
end

function Generator:isNewGeneratedPosition(generatedLine, generatedCharacter)
    return not self.hasPending or
        self.pendingGeneratedLine ~= generatedLine or
        self.pendingGeneratedCharacter ~= generatedCharacter
end

function Generator:isBacktrackingSourcePosition(sourceIndex, sourceLine, sourceCharacter)
    return sourceIndex ~= sourcemap.sourceIndexNotSet and
        sourceLine ~= sourcemap.notSet and
        sourceCharacter ~= sourcemap.notSetUTF16 and
        self.pendingSourceIndex == sourceIndex and
        (self.pendingSourceLine > sourceLine or
            self.pendingSourceLine == sourceLine and self.pendingSourceCharacter > sourceCharacter)
end

function Generator:shouldCommitMapping()
    return self.hasPending and (not self.hasLast or
        self.lastGeneratedLine ~= self.pendingGeneratedLine or
        self.lastGeneratedCharacter ~= self.pendingGeneratedCharacter or
        self.lastSourceIndex ~= self.pendingSourceIndex or
        self.lastSourceLine ~= self.pendingSourceLine or
        self.lastSourceCharacter ~= self.pendingSourceCharacter or
        self.lastNameIndex ~= self.pendingNameIndex)
end

function Generator:appendMappingCharCode(charCode)
    self.mappings[#self.mappings + 1] = utf8.char(charCode)
end

function Generator:appendBase64VLQ(inValue)
    -- Add a new least significant bit that has the sign of the value.
    -- if negative number the least significant bit that gets added to the number has value 1
    -- else least significant bit value that gets added is 0
    -- eg. -1 changes to binary : 01 [1] => 3
    --     +1 changes to binary : 01 [0] => 2
    if inValue < 0 then
        inValue = ((-inValue) << 1) + 1
    else
        inValue = inValue << 1
    end

    -- Encode 5 bits at a time starting from least significant bits
    while true do
        local currentDigit = inValue & 31 -- 11111
        inValue = inValue // 32 -- arithmetic shift (Go >> on int)
        if inValue > 0 then
            -- There are still more digits to decode, set the msb (6th bit)
            currentDigit = currentDigit | 32
        end
        self:appendMappingCharCode(sourcemap.base64FormatEncode(currentDigit))
        if inValue <= 0 then
            break
        end
    end
end

function Generator:commitPendingMapping()
    if not self:shouldCommitMapping() then
        return
    end

    -- Line/Comma delimiters
    if self.lastGeneratedLine < self.pendingGeneratedLine then
        -- Emit line delimiters
        while true do
            self:appendMappingCharCode(0x3B) -- ';'
            self.lastGeneratedLine = self.lastGeneratedLine + 1
            if self.lastGeneratedLine >= self.pendingGeneratedLine then
                break
            end
        end
        -- Only need to set this once
        self.lastGeneratedCharacter = 0
    else
        if self.lastGeneratedLine ~= self.pendingGeneratedLine then
            -- panic rather than error as an invariant has been violated
            error("generatedLine cannot backtrack", 0)
        end
        -- Emit comma to separate the entry
        if self.hasLast then
            self:appendMappingCharCode(0x2C) -- ','
        end
    end

    -- 1. Relative generated character
    self:appendBase64VLQ(self.pendingGeneratedCharacter - self.lastGeneratedCharacter)
    self.lastGeneratedCharacter = self.pendingGeneratedCharacter

    if self.hasPendingSource then
        -- 2. Relative sourceIndex
        self:appendBase64VLQ(self.pendingSourceIndex - self.lastSourceIndex)
        self.lastSourceIndex = self.pendingSourceIndex

        -- 3. Relative source line
        self:appendBase64VLQ(self.pendingSourceLine - self.lastSourceLine)
        self.lastSourceLine = self.pendingSourceLine

        -- 4. Relative source character
        self:appendBase64VLQ(self.pendingSourceCharacter - self.lastSourceCharacter)
        self.lastSourceCharacter = self.pendingSourceCharacter

        if self.hasPendingName then
            -- 5. Relative nameIndex
            self:appendBase64VLQ(self.pendingNameIndex - self.lastNameIndex)
            self.lastNameIndex = self.pendingNameIndex
        end
    end

    self.hasLast = true
end

function Generator:addMapping(generatedLine, generatedCharacter, sourceIndex, sourceLine, sourceCharacter, nameIndex)
    if self:isNewGeneratedPosition(generatedLine, generatedCharacter) or
        self:isBacktrackingSourcePosition(sourceIndex, sourceLine, sourceCharacter) then
        self:commitPendingMapping()
        self.pendingGeneratedLine = generatedLine
        self.pendingGeneratedCharacter = generatedCharacter
        self.hasPendingSource = false
        self.hasPendingName = false
        self.hasPending = true
    end

    if sourceIndex ~= sourcemap.sourceIndexNotSet and sourceLine ~= sourcemap.notSet and sourceCharacter ~= sourcemap.notSetUTF16 then
        self.pendingSourceIndex = sourceIndex
        self.pendingSourceLine = sourceLine
        self.pendingSourceCharacter = sourceCharacter
        self.hasPendingSource = true
        if nameIndex ~= sourcemap.nameIndexNotSet then
            self.pendingNameIndex = nameIndex
            self.hasPendingName = true
        end
    end
end

-- Adds a mapping without source information. Returns an error message or nil.
function Generator:AddGeneratedMapping(generatedLine, generatedCharacter)
    if generatedLine < self.pendingGeneratedLine then
        return "generatedLine cannot backtrack"
    end
    if generatedCharacter < 0 then
        return "generatedCharacter cannot be negative"
    end
    self:addMapping(generatedLine, generatedCharacter, sourcemap.sourceIndexNotSet, sourcemap.notSet --[[sourceLine]], sourcemap.notSetUTF16 --[[sourceCharacter]], sourcemap.nameIndexNotSet)
    return nil
end

-- Adds a mapping with source information. Returns an error message or nil.
function Generator:AddSourceMapping(generatedLine, generatedCharacter, sourceIndex, sourceLine, sourceCharacter)
    if generatedLine < self.pendingGeneratedLine then
        return "generatedLine cannot backtrack"
    end
    if generatedCharacter < 0 then
        return "generatedCharacter cannot be negative"
    end
    if sourceIndex < 0 or sourceIndex >= #self.sources then
        return "sourceIndex is out of range"
    end
    if sourceLine < 0 then
        return "sourceLine cannot be negative"
    end
    if sourceCharacter < 0 then
        return "sourceCharacter cannot be negative"
    end
    self:addMapping(generatedLine, generatedCharacter, sourceIndex, sourceLine, sourceCharacter, sourcemap.nameIndexNotSet)
    return nil
end

-- Adds a mapping with source and name information. Returns an error message or nil.
function Generator:AddNamedSourceMapping(generatedLine, generatedCharacter, sourceIndex, sourceLine, sourceCharacter, nameIndex)
    if generatedLine < self.pendingGeneratedLine then
        return "generatedLine cannot backtrack"
    end
    if generatedCharacter < 0 then
        return "generatedCharacter cannot be negative"
    end
    if sourceIndex < 0 or sourceIndex >= #self.sources then
        return "sourceIndex is out of range"
    end
    if sourceLine < 0 then
        return "sourceLine cannot be negative"
    end
    if sourceCharacter < 0 then
        return "sourceCharacter cannot be negative"
    end
    if nameIndex < 0 or nameIndex >= #self.names then
        return "nameIndex is out of range"
    end
    self:addMapping(generatedLine, generatedCharacter, sourceIndex, sourceLine, sourceCharacter, nameIndex)
    return nil
end

local function cloneArray(xs)
    if xs == nil then
        return nil
    end
    local result = {}
    for i, x in ipairs(xs) do
        result[i] = x
    end
    return result
end

-- Gets the source map as a `RawSourceMap` object
function Generator:RawSourceMap()
    self:commitPendingMapping()
    local sources = cloneArray(self.sources)
    local names = cloneArray(self.names)
    local mappings = table.concat(self.mappings)
    self.mappings = { mappings }
    return setmetatable({
        version = 3,
        file = self.file,
        sourceRoot = self.sourceRoot,
        sources = sources,
        names = names,
        mappings = mappings,
        sourcesContent = cloneArray(self.sourcesContent),
    }, RawSourceMap)
end

function Generator:bytes()
    return sourcemap.marshalRawSourceMap(self:RawSourceMap())
end

-- Gets the string representation of the source map
function Generator:String()
    return self:bytes()
end

function Generator:Base64DataURL()
    local prefix = "data:application/json;base64,"
    local data = self:bytes()
    return prefix .. sourcemap.base64StdEncode(data)
end

function sourcemap.base64FormatEncode(value)
    if value >= 0 and value < 26 then
        return 0x41 + value -- 'A'
    elseif value >= 26 and value < 52 then
        return 0x61 + value - 26 -- 'a'
    elseif value >= 52 and value < 62 then
        return 0x30 + value - 52 -- '0'
    elseif value == 62 then
        return 0x2B -- '+'
    elseif value == 63 then
        return 0x2F -- '/'
    else
        error("not a base64 value", 0)
    end
end

-- Lua-only helpers: encoding/json (go-json-experiment defaults, AllowInvalidUTF8) and encoding/base64.

local hexDigits = "0123456789abcdef"

local function appendEscapedUTF16(parts, x)
    parts[#parts + 1] = "\\u"
    for shift = 12, 0, -4 do
        local d = (x >> shift) & 0xF
        parts[#parts + 1] = string.sub(hexDigits, d + 1, d + 1)
    end
end

-- jsonwire.AppendQuote with default flags (no HTML/JS escaping) and AllowInvalidUTF8(true).
function sourcemap.jsonQuote(s)
    local parts = { '"' }
    local i, n = 0, 0
    local len = #s
    while n < len do
        local c = string.byte(s, n + 1)
        if c < 0x80 then
            n = n + 1
            if c < 0x20 or c == 0x22 or c == 0x5C then
                parts[#parts + 1] = string.sub(s, i + 1, n - 1)
                if c == 0x22 or c == 0x5C then
                    parts[#parts + 1] = "\\" .. string.char(c)
                elseif c == 0x08 then
                    parts[#parts + 1] = "\\b"
                elseif c == 0x0C then
                    parts[#parts + 1] = "\\f"
                elseif c == 0x0A then
                    parts[#parts + 1] = "\\n"
                elseif c == 0x0D then
                    parts[#parts + 1] = "\\r"
                elseif c == 0x09 then
                    parts[#parts + 1] = "\\t"
                else
                    appendEscapedUTF16(parts, c)
                end
                i = n
            end
        else
            local r, rn = sourcemap.decodeRune(s, n)
            n = n + rn
            if r == 0xFFFD and rn == 1 then
                parts[#parts + 1] = string.sub(s, i + 1, n - rn)
                parts[#parts + 1] = "\u{FFFD}"
                i = n
            end
        end
    end
    parts[#parts + 1] = string.sub(s, i + 1, n)
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local function marshalStringArray(xs)
    local parts = {}
    for i, x in ipairs(xs) do
        if x == false then
            parts[i] = "null"
        else
            parts[i] = sourcemap.jsonQuote(x)
        end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- json.Marshal(*RawSourceMap)
function sourcemap.marshalRawSourceMap(m)
    local parts = {
        '{"version":', string.format("%d", m.version),
        ',"file":', sourcemap.jsonQuote(m.file),
        ',"sourceRoot":', sourcemap.jsonQuote(m.sourceRoot),
        ',"sources":', m.sources == nil and "null" or marshalStringArray(m.sources),
        ',"names":', m.names == nil and "null" or marshalStringArray(m.names),
        ',"mappings":', sourcemap.jsonQuote(m.mappings),
    }
    -- `omitzero`: a nil slice is omitted
    if m.sourcesContent ~= nil then
        parts[#parts + 1] = ',"sourcesContent":'
        parts[#parts + 1] = marshalStringArray(m.sourcesContent)
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- base64.StdEncoding.EncodeToString
function sourcemap.base64StdEncode(data)
    local parts = {}
    local len = #data
    local i = 1
    while i + 2 <= len do
        local a, b, c = string.byte(data, i, i + 2)
        local v = (a << 16) | (b << 8) | c
        parts[#parts + 1] = string.char(
            string.byte(base64Alphabet, ((v >> 18) & 63) + 1),
            string.byte(base64Alphabet, ((v >> 12) & 63) + 1),
            string.byte(base64Alphabet, ((v >> 6) & 63) + 1),
            string.byte(base64Alphabet, (v & 63) + 1))
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local v = string.byte(data, i) << 16
        parts[#parts + 1] = string.char(
            string.byte(base64Alphabet, ((v >> 18) & 63) + 1),
            string.byte(base64Alphabet, ((v >> 12) & 63) + 1)) .. "=="
    elseif rem == 2 then
        local a, b = string.byte(data, i, i + 1)
        local v = (a << 16) | (b << 8)
        parts[#parts + 1] = string.char(
            string.byte(base64Alphabet, ((v >> 18) & 63) + 1),
            string.byte(base64Alphabet, ((v >> 12) & 63) + 1),
            string.byte(base64Alphabet, ((v >> 6) & 63) + 1)) .. "="
    end
    return table.concat(parts)
end

local base64DecodeMap = {}
for k = 1, #base64Alphabet do
    base64DecodeMap[string.byte(base64Alphabet, k)] = k - 1
end

-- base64.StdEncoding.DecodeString; returns decoded, err (err is a message or nil).
function sourcemap.base64StdDecode(s)
    local out = {}
    local len = #s
    local pos = 1
    while pos <= len do
        local vals = {}
        local j = 0
        local padded = false
        while j < 4 do
            if pos > len then
                -- input ended inside a quantum (padding is required by StdEncoding)
                if j == 0 then
                    break
                end
                return nil, "illegal base64 data at input byte " .. tostring(pos - 1)
            end
            local c = string.byte(s, pos)
            -- newlines are ignored
            if c == 0x0A or c == 0x0D then
                pos = pos + 1
                goto nextChar
            end
            if c == 0x3D then -- '='
                if j < 2 then
                    return nil, "illegal base64 data at input byte " .. tostring(pos - 1)
                end
                pos = pos + 1
                if j == 2 then
                    -- skip newlines, then expect a second '='
                    while pos <= len and (string.byte(s, pos) == 0x0A or string.byte(s, pos) == 0x0D) do
                        pos = pos + 1
                    end
                    if pos > len or string.byte(s, pos) ~= 0x3D then
                        return nil, "illegal base64 data at input byte " .. tostring(pos - 1)
                    end
                    pos = pos + 1
                end
                while pos <= len and (string.byte(s, pos) == 0x0A or string.byte(s, pos) == 0x0D) do
                    pos = pos + 1
                end
                if pos <= len then
                    return nil, "illegal base64 data at input byte " .. tostring(pos - 1)
                end
                padded = true
                break
            end
            do
                local v = base64DecodeMap[c]
                if v == nil then
                    return nil, "illegal base64 data at input byte " .. tostring(pos - 1)
                end
                vals[j + 1] = v
                j = j + 1
                pos = pos + 1
            end
            ::nextChar::
        end
        if j == 0 then
            break
        end
        local v = (vals[1] << 18) | (vals[2] << 12) | ((vals[3] or 0) << 6) | (vals[4] or 0)
        out[#out + 1] = string.char((v >> 16) & 0xFF)
        if j >= 3 then
            out[#out + 1] = string.char((v >> 8) & 0xFF)
        end
        if j == 4 then
            out[#out + 1] = string.char(v & 0xFF)
        end
        if padded then
            break
        end
    end
    return table.concat(out), nil
end
