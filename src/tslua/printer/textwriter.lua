local printer = require("tslua.printer")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")

local textWriter = {}
textWriter.__index = textWriter
printer.textWriter = textWriter

function textWriter:Clear()
    local newLine, indentSize = self.newLine, self.indentSize
    for k in pairs(self) do
        self[k] = nil
    end
    self.newLine = newLine
    self.indentSize = indentSize
    self.builder = printer.newStringsBuilder()
    self.lastWritten = ""
    self.indent = 0
    self.lineStart = true
    self.lineCount = 0
    self.linePos = 0
    self.hasTrailingCommentState = false
end

function textWriter:Grow(n)
    self.builder:Grow(n)
end

function textWriter:DecreaseIndent()
    self.indent = self.indent - 1
end

-- GetColumn returns the column position measured in UTF-16 code units
-- for source map compatibility.
function textWriter:GetColumn()
    if self.lineStart then
        return self.indent * self.indentSize
    end
    -- Count UTF-16 code units from the last line start.
    -- For ASCII-only output (the common case), this equals the byte count.
    return core.UTF16Len(string.sub(self.builder:String(), self.linePos + 1))
end

function textWriter:GetIndent()
    return self.indent
end

function textWriter:GetLine()
    return self.lineCount
end

function textWriter:String()
    return self.builder:String()
end

function textWriter:GetTextPos()
    return self.builder:Len()
end

function textWriter:HasTrailingComment()
    return self.hasTrailingCommentState
end

function textWriter:HasTrailingWhitespace()
    if self.builder:Len() == 0 then
        return false
    end
    local ch = core.DecodeLastRune(self.lastWritten)
    if ch == core.RuneError then
        return false
    end
    return stringutil.IsWhiteSpaceLike(ch)
end

function textWriter:IncreaseIndent()
    self.indent = self.indent + 1
end

function textWriter:IsAtStartOfLine()
    return self.lineStart
end

function textWriter:RawWrite(s)
    if s ~= "" then
        self.builder:WriteString(s)
        self.lastWritten = s
        self.hasTrailingCommentState = false
    end
    self:updateLineCountAndPosFor(s)
end

function textWriter:updateLineCountAndPosFor(s)
    local count = 0
    local lastLineStart = 0

    for lineStart in core.ComputeECMALineStartsSeq(s) do
        count = count + 1
        lastLineStart = lineStart
    end

    if count > 1 then
        self.lineCount = self.lineCount + count - 1
        local curLen = self.builder:Len()
        self.linePos = curLen - #s + lastLineStart
        self.lineStart = (self.linePos - curLen) == 0
        return
    end
    self.lineStart = false
end

printer.defaultIndentSize = 4

-- GetDefaultIndentSize returns the default indent size (4 spaces) used when no specific indent size is configured.
function printer.GetDefaultIndentSize()
    return printer.defaultIndentSize
end

function printer.getIndentString(indent, indentSize)
    if indent == 0 then
        return ""
    end
    -- TODO: This is cached in tsc - should it be cached here?
    return string.rep(" ", indent * indentSize)
end

function textWriter:writeText(s)
    if s ~= "" then
        if self.lineStart then
            self.builder:WriteString(printer.getIndentString(self.indent, self.indentSize))
            self.lineStart = false
        end
        self.builder:WriteString(s)
        self.lastWritten = s
        self:updateLineCountAndPosFor(s)
    end
end

function textWriter:Write(s)
    if s ~= "" then
        self.hasTrailingCommentState = false
    end
    self:writeText(s)
end

function textWriter:WriteComment(text)
    if text ~= "" then
        self.hasTrailingCommentState = true
    end
    self:writeText(text)
end

function textWriter:WriteKeyword(text)
    self:Write(text)
end

function textWriter:writeLineRaw()
    self.builder:WriteString(self.newLine)
    self.lastWritten = self.newLine
    self.lineCount = self.lineCount + 1
    self.linePos = self.builder:Len()
    self.lineStart = true
    self.hasTrailingCommentState = false
end

function textWriter:WriteLine()
    if not self.lineStart then
        self:writeLineRaw()
    end
end

function textWriter:WriteLineForce(force)
    if not self.lineStart or force then
        self:writeLineRaw()
    end
end

function textWriter:WriteLiteral(s)
    self:Write(s)
end

function textWriter:WriteOperator(text)
    self:Write(text)
end

function textWriter:WriteParameter(text)
    self:Write(text)
end

function textWriter:WriteProperty(text)
    self:Write(text)
end

function textWriter:WritePunctuation(text)
    self:Write(text)
end

function textWriter:WriteSpace(text)
    self:Write(text)
end

function textWriter:WriteStringLiteral(text)
    self:Write(text)
end

function textWriter:WriteSymbol(text, symbol)
    self:Write(text)
end

function textWriter:WriteTrailingSemicolon(text)
    self:Write(text)
end

function printer.NewTextWriter(newLine, indentSize)
    if indentSize <= 0 then
        indentSize = 4
    end
    local w = setmetatable({}, textWriter)
    w.newLine = newLine
    w.indentSize = indentSize
    w:Clear()
    return w
end
