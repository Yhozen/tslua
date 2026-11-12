local encoder = require("tslua.api.encoder")
local ast = require("tslua.ast")

local Kind = ast.Kind

-- stringTable: { fileText, otherStrings (ByteBuf), offsets (array of uint32 pos/end pairs) }
local stringTable = {}
stringTable.__index = stringTable
encoder.stringTable = stringTable

function encoder.newStringTable(fileText, stringCount)
    local builder = encoder.newByteBuf()
    return setmetatable({
        fileText = fileText,
        otherStrings = builder,
        offsets = {},
    }, stringTable)
end

function stringTable:add(text, kind, pos, end_)
    local index = #self.offsets
    if kind == Kind.SourceFile then
        self.offsets[#self.offsets + 1] = pos
        self.offsets[#self.offsets + 1] = end_
        return index
    end
    local length = #text
    if end_ - pos > 0 and end_ <= #self.fileText then
        -- pos includes leading trivia, but we can usually infer the actual start of the
        -- string from the kind and end
        local endOffset = 0
        if kind == Kind.StringLiteral or kind == Kind.TemplateTail or kind == Kind.NoSubstitutionTemplateLiteral then
            endOffset = 1
        end
        end_ = end_ - endOffset
        local start = end_ - length
        if start < 0 then
            error("runtime error: slice bounds out of range [" .. tostring(start) .. ":" .. tostring(end_) .. "]", 0)
        end
        local fileSlice = string.sub(self.fileText, start + 1, end_)
        if fileSlice == text then
            self.offsets[#self.offsets + 1] = start
            self.offsets[#self.offsets + 1] = end_
            return index
        end
    end
    -- no exact match, so we need to add it to the string table
    local offset = #self.fileText + self.otherStrings:Len()
    self.otherStrings:WriteString(text)
    self.offsets[#self.offsets + 1] = offset
    self.offsets[#self.offsets + 1] = offset + length
    return index
end

-- Returns the encoded bytes as a Lua string.
function stringTable:encode()
    local result = encoder.newByteBuf()
    encoder.appendUint32s(result, self.offsets)
    result:WriteString(self.fileText)
    result:WriteString(self.otherStrings:String())
    return result:Bytes()
end

function stringTable:stringLength()
    return #self.fileText + self.otherStrings:Len()
end

function stringTable:encodedLength()
    return #self.offsets * 4 + #self.fileText + self.otherStrings:Len()
end
