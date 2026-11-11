local printer = require("tslua.printer")

local trailingSemicolonDeferringWriter = {}
trailingSemicolonDeferringWriter.__index = trailingSemicolonDeferringWriter
printer.trailingSemicolonDeferringWriter = trailingSemicolonDeferringWriter

function printer.getTrailingSemicolonDeferringWriter(writer)
    return setmetatable({ inner = writer, hasPendingSemicolon = false }, trailingSemicolonDeferringWriter)
end

function trailingSemicolonDeferringWriter:commitSemicolon()
    if self.hasPendingSemicolon then
        self.inner:WriteTrailingSemicolon(";")
        self.hasPendingSemicolon = false
    end
end

function trailingSemicolonDeferringWriter:Write(s)
    self:commitSemicolon()
    self.inner:Write(s)
end

function trailingSemicolonDeferringWriter:WriteTrailingSemicolon(_)
    self.hasPendingSemicolon = true
end

function trailingSemicolonDeferringWriter:WriteComment(text)
    self:commitSemicolon()
    self.inner:WriteComment(text)
end

function trailingSemicolonDeferringWriter:WriteKeyword(text)
    self:commitSemicolon()
    self.inner:WriteKeyword(text)
end

function trailingSemicolonDeferringWriter:WriteOperator(text)
    self:commitSemicolon()
    self.inner:WriteOperator(text)
end

function trailingSemicolonDeferringWriter:WritePunctuation(text)
    self:commitSemicolon()
    self.inner:WritePunctuation(text)
end

function trailingSemicolonDeferringWriter:WriteSpace(text)
    self:commitSemicolon()
    self.inner:WriteSpace(text)
end

function trailingSemicolonDeferringWriter:WriteStringLiteral(text)
    self:commitSemicolon()
    self.inner:WriteStringLiteral(text)
end

function trailingSemicolonDeferringWriter:WriteParameter(text)
    self:commitSemicolon()
    self.inner:WriteParameter(text)
end

function trailingSemicolonDeferringWriter:WriteProperty(text)
    self:commitSemicolon()
    self.inner:WriteProperty(text)
end

function trailingSemicolonDeferringWriter:WriteSymbol(text, symbol)
    self:commitSemicolon()
    self.inner:WriteSymbol(text, symbol)
end

function trailingSemicolonDeferringWriter:WriteLine()
    self:commitSemicolon()
    self.inner:WriteLine()
end

function trailingSemicolonDeferringWriter:WriteLineForce(force)
    self:commitSemicolon()
    self.inner:WriteLineForce(force)
end

function trailingSemicolonDeferringWriter:IncreaseIndent()
    self:commitSemicolon()
    self.inner:IncreaseIndent()
end

function trailingSemicolonDeferringWriter:DecreaseIndent()
    self:commitSemicolon()
    self.inner:DecreaseIndent()
end

function trailingSemicolonDeferringWriter:Clear()
    self.hasPendingSemicolon = false
    self.inner:Clear()
end

function trailingSemicolonDeferringWriter:String()
    return self.inner:String()
end

function trailingSemicolonDeferringWriter:RawWrite(s)
    self:commitSemicolon()
    self.inner:RawWrite(s)
end

function trailingSemicolonDeferringWriter:WriteLiteral(s)
    self:commitSemicolon()
    self.inner:WriteLiteral(s)
end

function trailingSemicolonDeferringWriter:GetTextPos()
    return self.inner:GetTextPos()
end

function trailingSemicolonDeferringWriter:GetLine()
    return self.inner:GetLine()
end

function trailingSemicolonDeferringWriter:GetColumn()
    return self.inner:GetColumn()
end

function trailingSemicolonDeferringWriter:GetIndent()
    return self.inner:GetIndent()
end

function trailingSemicolonDeferringWriter:IsAtStartOfLine()
    return self.inner:IsAtStartOfLine()
end

function trailingSemicolonDeferringWriter:HasTrailingComment()
    return self.inner:HasTrailingComment()
end

function trailingSemicolonDeferringWriter:HasTrailingWhitespace()
    return self.inner:HasTrailingWhitespace()
end
