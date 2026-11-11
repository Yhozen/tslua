local printer = require("tslua.printer")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")

local singleLineStringWriter = {}
singleLineStringWriter.__index = singleLineStringWriter
printer.singleLineStringWriter = singleLineStringWriter

-- Go pools writers; Lua allocates a fresh one. Returns writer, release function.
function printer.GetSingleLineStringWriter()
    local w = setmetatable({ builder = printer.newStringsBuilder(), lastWritten = "" }, singleLineStringWriter)
    w:Clear()
    return w, function() end
end

function singleLineStringWriter:Clear()
    self.lastWritten = ""
    self.builder:Reset()
end

function singleLineStringWriter:DecreaseIndent()
    -- Do Nothing
end

function singleLineStringWriter:GetColumn()
    return 0
end

function singleLineStringWriter:GetIndent()
    return 0
end

function singleLineStringWriter:GetLine()
    return 0
end

function singleLineStringWriter:String()
    return self.builder:String()
end

function singleLineStringWriter:GetTextPos()
    return self.builder:Len()
end

function singleLineStringWriter:HasTrailingComment()
    return false
end

function singleLineStringWriter:HasTrailingWhitespace()
    if self.builder:Len() == 0 then
        return false
    end
    local ch = core.DecodeLastRune(self.lastWritten)
    if ch == core.RuneError then
        return false
    end
    return stringutil.IsWhiteSpaceLike(ch)
end

function singleLineStringWriter:IncreaseIndent()
    -- Do Nothing
end

function singleLineStringWriter:IsAtStartOfLine()
    return false
end

function singleLineStringWriter:RawWrite(s)
    self.lastWritten = s
    self.builder:WriteString(s)
end

function singleLineStringWriter:Write(s)
    self.lastWritten = s
    self.builder:WriteString(s)
end

function singleLineStringWriter:WriteComment(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteKeyword(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteLine()
    self.lastWritten = " "
    self.builder:WriteString(" ")
end

function singleLineStringWriter:WriteLineForce(force)
    self.lastWritten = " "
    self.builder:WriteString(" ")
end

function singleLineStringWriter:WriteLiteral(s)
    self.lastWritten = s
    self.builder:WriteString(s)
end

function singleLineStringWriter:WriteOperator(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteParameter(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteProperty(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WritePunctuation(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteSpace(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteStringLiteral(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteSymbol(text, symbol)
    self.lastWritten = text
    self.builder:WriteString(text)
end

function singleLineStringWriter:WriteTrailingSemicolon(text)
    self.lastWritten = text
    self.builder:WriteString(text)
end
