local sourcemap = require("tslua.sourcemap")

local MissingSource = sourcemap.SourceIndex.MissingSource
local MissingName = sourcemap.NameIndex.MissingName

local Mapping = {}
Mapping.__index = Mapping
sourcemap.Mapping = Mapping

function Mapping:Equals(other)
    return self == other or self.generatedLine == other.generatedLine and
        self.generatedCharacter == other.generatedCharacter and
        self.sourceIndex == other.sourceIndex and
        self.sourceLine == other.sourceLine and
        self.sourceCharacter == other.sourceCharacter and
        self.nameIndex == other.nameIndex
end

function Mapping:IsSourceMapping()
    return self.sourceIndex ~= MissingSource and
        self.sourceLine ~= sourcemap.MissingLineOrColumn and
        self.sourceCharacter ~= sourcemap.MissingUTF16Column
end

local MappingsDecoder = {}
MappingsDecoder.__index = MappingsDecoder
sourcemap.MappingsDecoder = MappingsDecoder

function sourcemap.DecodeMappings(mappings)
    return setmetatable({
        mappings = mappings,
        done = false,
        pos = 0,
        generatedLine = 0,
        generatedCharacter = 0,
        sourceIndex = 0,
        sourceLine = 0,
        sourceCharacter = 0,
        nameIndex = 0,
        error = nil, -- error message or nil
    }, MappingsDecoder)
end

function MappingsDecoder:MappingsString()
    return self.mappings
end

function MappingsDecoder:Pos()
    return self.pos
end

-- Returns the error message, or nil.
function MappingsDecoder:Error()
    return self.error
end

function MappingsDecoder:State()
    return self:captureMapping(true --[[hasSource]], true --[[hasName]])
end

-- Values returns a Lua iterator over the decoded mappings (`for m in d:Values() do`).
function MappingsDecoder:Values()
    return function()
        local value, done = self:Next()
        if done then
            return nil
        end
        return value
    end
end

-- Returns value, done.
function MappingsDecoder:Next()
    while not self.done and self.pos < #self.mappings do
        local ch = string.byte(self.mappings, self.pos + 1)
        if ch == 0x3B then -- ';'
            -- new line
            self.generatedLine = self.generatedLine + 1
            self.generatedCharacter = 0
            self.pos = self.pos + 1
            goto continue
        end

        if ch == 0x2C then -- ','
            -- Next entry is on same line - no action needed
            self.pos = self.pos + 1
            goto continue
        end

        do
            local hasSource = false
            local hasName = false
            self.generatedCharacter = self.generatedCharacter + self:base64VLQFormatDecode()
            if self:hasReportedError() then
                return self:stopIterating()
            end
            if self.generatedCharacter < 0 then
                return self:setErrorAndStopIterating("Invalid generatedCharacter found")
            end

            if not self:isSourceMappingSegmentEnd() then
                hasSource = true

                self.sourceIndex = self.sourceIndex + self:base64VLQFormatDecode()
                if self:hasReportedError() then
                    return self:stopIterating()
                end
                if self.sourceIndex < 0 then
                    return self:setErrorAndStopIterating("Invalid sourceIndex found")
                end
                if self:isSourceMappingSegmentEnd() then
                    return self:setErrorAndStopIterating("Unsupported Format: No entries after sourceIndex")
                end

                self.sourceLine = self.sourceLine + self:base64VLQFormatDecode()
                if self:hasReportedError() then
                    return self:stopIterating()
                end
                if self.sourceLine < 0 then
                    return self:setErrorAndStopIterating("Invalid sourceLine found")
                end
                if self:isSourceMappingSegmentEnd() then
                    return self:setErrorAndStopIterating("Unsupported Format: No entries after sourceLine")
                end

                self.sourceCharacter = self.sourceCharacter + self:base64VLQFormatDecode()
                if self:hasReportedError() then
                    return self:stopIterating()
                end
                if self.sourceCharacter < 0 then
                    return self:setErrorAndStopIterating("Invalid sourceCharacter found")
                end

                if not self:isSourceMappingSegmentEnd() then
                    hasName = true
                    self.nameIndex = self.nameIndex + self:base64VLQFormatDecode()
                    if self:hasReportedError() then
                        return self:stopIterating()
                    end
                    if self.nameIndex < 0 then
                        return self:setErrorAndStopIterating("Invalid nameIndex found")
                    end

                    if not self:isSourceMappingSegmentEnd() then
                        return self:setErrorAndStopIterating("Unsupported Error Format: Entries after nameIndex")
                    end
                end
            end

            do
                return self:captureMapping(hasSource, hasName), false
            end
        end
        ::continue::
    end

    return self:stopIterating()
end

function MappingsDecoder:captureMapping(hasSource, hasName)
    local mapping = setmetatable({}, Mapping)
    mapping.generatedLine = self.generatedLine
    mapping.generatedCharacter = self.generatedCharacter
    mapping.sourceIndex = hasSource and self.sourceIndex or MissingSource
    mapping.sourceLine = hasSource and self.sourceLine or sourcemap.MissingLineOrColumn
    mapping.sourceCharacter = hasSource and self.sourceCharacter or sourcemap.MissingUTF16Column
    mapping.nameIndex = hasName and self.nameIndex or MissingName
    return mapping
end

function MappingsDecoder:stopIterating()
    self.done = true
    return nil, true
end

function MappingsDecoder:setError(err)
    self.error = err
end

function MappingsDecoder:setErrorAndStopIterating(err)
    self:setError(err)
    return self:stopIterating()
end

function MappingsDecoder:hasReportedError()
    return self.error ~= nil
end

function MappingsDecoder:isSourceMappingSegmentEnd()
    if self.pos == #self.mappings then
        return true
    end
    local ch = string.byte(self.mappings, self.pos + 1)
    return ch == 0x2C or ch == 0x3B
end

function MappingsDecoder:base64VLQFormatDecode()
    local moreDigits = true
    local shiftCount = 0
    local value = 0
    while moreDigits do
        if self.pos >= #self.mappings then
            self:setError("Error in decoding base64VLQFormatDecode, past the mapping string")
            return -1
        end

        -- 6 digit number
        local currentByte = sourcemap.base64FormatDecode(string.byte(self.mappings, self.pos + 1))
        if currentByte == -1 then
            self:setError("Invalid character in VLQ")
            return -1
        end

        -- If msb is set, we still have more bits to continue
        moreDigits = (currentByte & 32) ~= 0

        -- least significant 5 bits are the next msbs in the final value.
        value = value | ((currentByte & 31) << shiftCount)
        shiftCount = shiftCount + 5
        self.pos = self.pos + 1
    end

    -- Least significant bit if 1 represents negative and rest of the msb is actual absolute value
    if (value & 1) == 0 then
        -- + number
        value = value // 2 -- arithmetic shift (Go >> on int)
    else
        -- - number
        value = value // 2 -- arithmetic shift (Go >> on int)
        value = -value
    end

    return value
end

function sourcemap.base64FormatDecode(ch)
    if ch >= 0x41 and ch <= 0x5A then -- 'A'..'Z'
        return ch - 0x41
    elseif ch >= 0x61 and ch <= 0x7A then -- 'a'..'z'
        return ch - 0x61 + 26
    elseif ch >= 0x30 and ch <= 0x39 then -- '0'..'9'
        return ch - 0x30 + 52
    elseif ch == 0x2B then -- '+'
        return 62
    elseif ch == 0x2F then -- '/'
        return 63
    else
        return -1
    end
end
