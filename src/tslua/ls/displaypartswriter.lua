local ls = require("tslua.ls")
local ast = require("tslua.ast")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local stringutil = require("tslua.stringutil")

local SymbolFlags = ast.SymbolFlags
local ClassificationTypeName = lsproto.ClassificationTypeName

-- displayPartsWriter implements EmitTextWriter and captures classified text runs
-- for VS colorized labels, while also building a plain string.
-- When vsCapability is false, only the plain string is built; runs are skipped.
-- { builder (core.StringBuilder), runs ([]*lsproto.VSClassifiedTextRun), vsCapability, lastWritten }
local displayPartsWriter = {}
displayPartsWriter.__index = displayPartsWriter
ls.displayPartsWriter = displayPartsWriter

function ls.newDisplayPartsWriter(vsCapability)
    return setmetatable({
        builder = core.NewStringBuilder(),
        runs = nil,
        vsCapability = vsCapability,
        lastWritten = "",
    }, displayPartsWriter)
end

function displayPartsWriter:addRun(classification, text)
    if text == "" then
        return
    end
    if self.vsCapability then
        self.runs = core.Append(self.runs, {
            classificationTypeName = classification,
            text = text,
        })
    end
    self.lastWritten = text
    self.builder:WriteString(text)
end

-- WriteClassified writes text with an explicit classification type.
function displayPartsWriter:WriteClassified(text, classification)
    self:addRun(classification, text)
end

-- WriteFrom copies the accumulated content from another displayPartsWriter.
function displayPartsWriter:WriteFrom(other)
    self.builder:WriteString(other:String())
    if self.vsCapability then
        self.runs = core.AppendAll(self.runs, other:GetRuns())
    end
    if other.lastWritten ~= "" then
        self.lastWritten = other.lastWritten
    end
end

function displayPartsWriter:GetRuns()
    return self.runs
end

function displayPartsWriter:String()
    return self.builder:String()
end

function displayPartsWriter:Clear()
    self.lastWritten = ""
    self.builder:Reset()
    self.runs = nil
end

function displayPartsWriter:DecreaseIndent() end

function displayPartsWriter:GetColumn() return 0 end

function displayPartsWriter:GetIndent() return 0 end

function displayPartsWriter:GetLine() return 0 end

function displayPartsWriter:GetTextPos()
    return self.builder:Len()
end

function displayPartsWriter:HasTrailingComment() return false end

function displayPartsWriter:HasTrailingWhitespace()
    if self.builder:Len() == 0 then
        return false
    end
    local ch = core.DecodeLastRune(self.lastWritten, #self.lastWritten)
    if ch == 0xFFFD then
        return false
    end
    return stringutil.IsWhiteSpaceLike(ch)
end

function displayPartsWriter:IncreaseIndent() end

function displayPartsWriter:IsAtStartOfLine() return false end

function displayPartsWriter:RawWrite(s)
    self:addRun(ClassificationTypeName.Text, s)
end

function displayPartsWriter:Write(s)
    self:addRun(ClassificationTypeName.Text, s)
end

function displayPartsWriter:WriteComment(text)
    -- Strada's writeComment uses unknownWrite → SymbolDisplayPartKind.text → "text"
    self:addRun(ClassificationTypeName.Text, text)
end

function displayPartsWriter:WriteKeyword(text)
    self:addRun(ClassificationTypeName.Keyword, text)
end

function displayPartsWriter:WriteLine()
    self:addRun(ClassificationTypeName.WhiteSpace, " ")
end

function displayPartsWriter:WriteLineForce(_)
    self:addRun(ClassificationTypeName.WhiteSpace, " ")
end

function displayPartsWriter:WriteLiteral(s)
    -- Strada's writeLiteral → SymbolDisplayPartKind.stringLiteral → "string"
    self:addRun(ClassificationTypeName.String, s)
end

function displayPartsWriter:WriteOperator(text)
    self:addRun(ClassificationTypeName.Operator, text)
end

function displayPartsWriter:WriteParameter(text)
    self:addRun(ClassificationTypeName.ParameterName, text)
end

function displayPartsWriter:WriteProperty(text)
    self:addRun(ClassificationTypeName.PropertyName, text)
end

function displayPartsWriter:WritePunctuation(text)
    self:addRun(ClassificationTypeName.Punctuation, text)
end

function displayPartsWriter:WriteSpace(text)
    self:addRun(ClassificationTypeName.WhiteSpace, text)
end

function displayPartsWriter:WriteStringLiteral(text)
    self:addRun(ClassificationTypeName.String, text)
end

function displayPartsWriter:WriteSymbol(text, symbol)
    local classification = ls.classificationForSymbol(symbol)
    self:addRun(classification, text)
end

function displayPartsWriter:WriteTrailingSemicolon(text)
    self:addRun(ClassificationTypeName.Punctuation, text)
end

-- classificationForSymbol determines the Roslyn classification type name based on a symbol's flags.
-- Matches the Strada translation chain: displayPartKind() → GetClassificationName().
function ls.classificationForSymbol(symbol)
    if symbol == nil then
        return ClassificationTypeName.Text
    end
    local flags = symbol.flags
    if flags & SymbolFlags.Variable ~= 0 then
        if ls.isFirstDeclarationOfSymbolParameter(symbol) then
            return ClassificationTypeName.ParameterName
        end
        return ClassificationTypeName.LocalName
    elseif flags & SymbolFlags.Property ~= 0 then
        return ClassificationTypeName.PropertyName
    elseif flags & SymbolFlags.GetAccessor ~= 0 then
        return ClassificationTypeName.PropertyName
    elseif flags & SymbolFlags.SetAccessor ~= 0 then
        return ClassificationTypeName.PropertyName
    elseif flags & SymbolFlags.EnumMember ~= 0 then
        return ClassificationTypeName.FieldName
    elseif flags & SymbolFlags.Function ~= 0 then
        return ClassificationTypeName.MethodName
    elseif flags & SymbolFlags.Class ~= 0 then
        return ClassificationTypeName.ClassName
    elseif flags & SymbolFlags.Interface ~= 0 then
        return ClassificationTypeName.InterfaceName
    elseif flags & SymbolFlags.Enum ~= 0 then
        return ClassificationTypeName.EnumName
    elseif flags & SymbolFlags.Module ~= 0 then
        return ClassificationTypeName.ModuleName
    elseif flags & SymbolFlags.Method ~= 0 then
        return ClassificationTypeName.MethodName
    elseif flags & SymbolFlags.TypeParameter ~= 0 then
        return ClassificationTypeName.TypeParameterName
    elseif flags & SymbolFlags.TypeAlias ~= 0 then
        return ClassificationTypeName.Identifier
    elseif flags & SymbolFlags.Alias ~= 0 then
        return ClassificationTypeName.Identifier
    else
        return ClassificationTypeName.Text
    end
end

-- isFirstDeclarationOfSymbolParameter checks if the symbol's first declaration is a parameter.
function ls.isFirstDeclarationOfSymbolParameter(symbol)
    local declarations = symbol.declarations
    if core.Len(declarations) == 0 then
        return false
    end
    return declarations[1].kind == ast.Kind.Parameter
end
