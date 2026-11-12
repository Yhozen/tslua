local lsproto = require("tslua.lsp.lsproto")
local jsonrpc = require("tslua.jsonrpc")

-- Implements a cmp.Compare like function for two Position
-- ComparePositions(pos, other) == cmp.Compare(pos, other)
function lsproto.ComparePositions(pos, other)
    local lineComp = lsproto.cmpCompare(pos.line, other.line)
    if lineComp ~= 0 then
        return lineComp
    end
    return lsproto.cmpCompare(pos.character, other.character)
end

-- Implements a cmp.Compare like function for two Range
-- CompareRanges(lsRange, other) == cmp.Compare(lsRange, other)
--
--	Range.Start is compared before Range.End
function lsproto.CompareRanges(lsRange, other)
    local startComp = lsproto.ComparePositions(lsRange.start, other.start)
    if startComp ~= 0 then
        return startComp
    end
    return lsproto.ComparePositions(lsRange.end_, other.end_)
end

-- cmp.Compare
function lsproto.cmpCompare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- AsString returns the plain text of a StringOrMarkupContent, reading the
-- MarkupContent value when the message is not a plain string.
function lsproto.StringOrMarkupContent:AsString()
    if self.string ~= nil then
        return self.string
    end
    if self.markupContent ~= nil then
        return self.markupContent.value
    end
    return ""
end

function lsproto.IntegerOrString:AsString()
    local codeStr = ""
    if self.string ~= nil then
        codeStr = self.string
    elseif self.integer ~= nil then
        codeStr = tostring(self.integer)
    else
        codeStr = "-1"
    end
    return codeStr
end

function lsproto.diagnosticExistsInSlice(elem, diags)
    for _, diag in ipairs(diags or {}) do
        if lsproto.diagnosticsEqual(elem, diag) then
            return true
        end
    end
    return false
end

function lsproto.diagnosticsEqual(diag1, diag2)
    if lsproto.diagnosticCodesEqual(diag1.code, diag2.code) and lsproto.diagnosticMessagesEqual(diag1.message, diag2.message) and lsproto.CompareRanges(diag1.range, diag2.range) == 0 then
        return true
    end
    return false
end

function lsproto.diagnosticCodesEqual(code1, code2)
    if code1.string ~= nil and code2.string ~= nil then
        return code1.string == code2.string
    end
    if code1.integer ~= nil and code2.integer ~= nil then
        return code1.integer == code2.integer
    end
    return false
end

function lsproto.diagnosticMessagesEqual(message1, message2)
    if message1.string ~= nil and message2.string ~= nil then
        return message1.string == message2.string
    end
    if message1.markupContent ~= nil and message2.markupContent ~= nil then
        return message1.markupContent.kind == message2.markupContent.kind and message1.markupContent.value == message2.markupContent.value
    end
    return false
end

-- Returns (missingFromList1, missingFromList2).
function lsproto.CompareDiagnostics(list1, list2)
    local missingFromList1 = {}
    local missingFromList2 = {}
    for _, elem in ipairs(list1 or {}) do
        if not lsproto.diagnosticExistsInSlice(elem, list2) then
            missingFromList2[#missingFromList2 + 1] = elem
        end
    end
    for _, elem in ipairs(list2 or {}) do
        if not lsproto.diagnosticExistsInSlice(elem, list1) then
            missingFromList1[#missingFromList1 + 1] = elem
        end
    end
    return missingFromList1, missingFromList2
end

function lsproto.Diagnostic:AsString()
    return lsproto.IntegerOrString.AsString(self.code) .. " (" .. tostring(self.range.start.line) .. ":" .. tostring(self.range.start.character) .. "-" .. tostring(self.range.end_.line) .. ":" .. tostring(self.range.end_.character) .. "): " .. lsproto.StringOrMarkupContent.AsString(self.message)
end

function lsproto.Diagnostic:CodeAsString()
    return "Code(" .. lsproto.IntegerOrString.AsString(self.code) .. ")"
end

-- ErrorCode values are errors (ErrorCode.Error()).
jsonrpc.numberErrorStrings[#jsonrpc.numberErrorStrings + 1] = function(n)
    return lsproto.ErrorCode_String(n)
end
