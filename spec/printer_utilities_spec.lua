-- Port of internal/printer/utilities_test.go
local ast = require("tslua.ast")
local printer = require("tslua.printer")

local QuoteChar = printer.QuoteChar

-- Go fmt "%q" of a string (strconv.Quote), used for subtest names.
local function goQuote(s)
    local b = { '"' }
    for _, r in utf8.codes(s) do
        if r == 0x22 then
            b[#b + 1] = '\\"'
        elseif r == 0x5C then
            b[#b + 1] = "\\\\"
        elseif r == 0x07 then
            b[#b + 1] = "\\a"
        elseif r == 0x08 then
            b[#b + 1] = "\\b"
        elseif r == 0x0C then
            b[#b + 1] = "\\f"
        elseif r == 0x0A then
            b[#b + 1] = "\\n"
        elseif r == 0x0D then
            b[#b + 1] = "\\r"
        elseif r == 0x09 then
            b[#b + 1] = "\\t"
        elseif r == 0x0B then
            b[#b + 1] = "\\v"
        elseif r < 0x20 or r == 0x7F then
            b[#b + 1] = string.format("\\x%02x", r)
        elseif r >= 0x80 and r < 0xA0 then
            b[#b + 1] = string.format("\\u%04x", r)
        else
            b[#b + 1] = utf8.char(r)
        end
    end
    b[#b + 1] = '"'
    return table.concat(b)
end

describe("TestEscapeString", function()
    local data = {
        { s = "", quoteChar = QuoteChar.DoubleQuote, expected = [[]] },
        { s = "abc", quoteChar = QuoteChar.DoubleQuote, expected = [[abc]] },
        { s = "ab\"c", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\"c]] },
        { s = "ab\tc", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\tc]] },
        { s = "ab\nc", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\nc]] },
        { s = "ab'c", quoteChar = QuoteChar.DoubleQuote, expected = [[ab'c]] },
        { s = "ab'c", quoteChar = QuoteChar.SingleQuote, expected = [[ab\'c]] },
        { s = "ab\"c", quoteChar = QuoteChar.SingleQuote, expected = [[ab"c]] },
        { s = "ab`c", quoteChar = QuoteChar.Backtick, expected = "ab\\`c" },
        { s = "\u{001f}", quoteChar = QuoteChar.Backtick, expected = "\\u001F" },
    }
    for i1, rec in ipairs(data) do
        local i = i1 - 1
        it(string.format("[%d] escapeString(%s, %d)", i, goQuote(rec.s), rec.quoteChar), function()
            local actual = printer.EscapeString(rec.s, rec.quoteChar)
            assert.are.equal(rec.expected, actual)
        end)
    end
end)

describe("TestEscapeNonAsciiString", function()
    local data = {
        { s = "", quoteChar = QuoteChar.DoubleQuote, expected = [[]] },
        { s = "abc", quoteChar = QuoteChar.DoubleQuote, expected = [[abc]] },
        { s = "ab\"c", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\"c]] },
        { s = "ab\tc", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\tc]] },
        { s = "ab\nc", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\nc]] },
        { s = "ab'c", quoteChar = QuoteChar.DoubleQuote, expected = [[ab'c]] },
        { s = "ab'c", quoteChar = QuoteChar.SingleQuote, expected = [[ab\'c]] },
        { s = "ab\"c", quoteChar = QuoteChar.SingleQuote, expected = [[ab"c]] },
        { s = "ab`c", quoteChar = QuoteChar.Backtick, expected = "ab\\`c" },
        { s = "ab\u{008f}c", quoteChar = QuoteChar.DoubleQuote, expected = [[ab\u008Fc]] },
        { s = "𝟘𝟙", quoteChar = QuoteChar.DoubleQuote, expected = [[\uD835\uDFD8\uD835\uDFD9]] },
    }
    for i1, rec in ipairs(data) do
        local i = i1 - 1
        it(string.format("[%d] escapeNonAsciiString(%s, %d)", i, goQuote(rec.s), rec.quoteChar), function()
            local actual = printer.escapeNonAsciiString(rec.s, rec.quoteChar)
            assert.are.equal(rec.expected, actual)
        end)
    end
end)

describe("TestEscapeJsxAttributeString", function()
    local data = {
        { s = "", quoteChar = QuoteChar.DoubleQuote, expected = "" },
        { s = "abc", quoteChar = QuoteChar.DoubleQuote, expected = "abc" },
        { s = "ab\"c", quoteChar = QuoteChar.DoubleQuote, expected = "ab&quot;c" },
        { s = "ab\tc", quoteChar = QuoteChar.DoubleQuote, expected = "ab&#x9;c" },
        { s = "ab\nc", quoteChar = QuoteChar.DoubleQuote, expected = "ab&#xA;c" },
        { s = "ab'c", quoteChar = QuoteChar.DoubleQuote, expected = "ab'c" },
        { s = "ab'c", quoteChar = QuoteChar.SingleQuote, expected = "ab&apos;c" },
        { s = "ab\"c", quoteChar = QuoteChar.SingleQuote, expected = "ab\"c" },
        { s = "ab\u{008f}c", quoteChar = QuoteChar.DoubleQuote, expected = "ab\u{008F}c" },
        { s = "𝟘𝟙", quoteChar = QuoteChar.DoubleQuote, expected = "𝟘𝟙" },
    }
    for i1, rec in ipairs(data) do
        local i = i1 - 1
        it(string.format("[%d] escapeJsxAttributeString(%s, %d)", i, goQuote(rec.s), rec.quoteChar), function()
            local actual = printer.escapeJsxAttributeString(rec.s, rec.quoteChar)
            assert.are.equal(rec.expected, actual)
        end)
    end
end)

describe("TestIsRecognizedTripleSlashComment", function()
    local data = {
        { s = "", commentRange = { kind = ast.Kind.MultiLineCommentTrivia }, expected = false },
        { s = "", commentRange = { kind = ast.Kind.SingleLineCommentTrivia }, expected = false },
        { s = "/a", expected = false },
        { s = "//", expected = false },
        { s = "//a", expected = false },
        { s = "///", expected = false },
        { s = "///a", expected = false },
        { s = "///<reference path=\"foo\" />", expected = true },
        { s = "///<reference types=\"foo\" />", expected = true },
        { s = "///<reference lib=\"foo\" />", expected = true },
        { s = "///<reference no-default-lib=\"foo\" />", expected = true },
        { s = "///<amd-dependency path=\"foo\" />", expected = true },
        { s = "///<amd-module />", expected = true },
        { s = "/// <reference path=\"foo\" />", expected = true },
        { s = "/// <reference types=\"foo\" />", expected = true },
        { s = "/// <reference lib=\"foo\" />", expected = true },
        { s = "/// <reference no-default-lib=\"foo\" />", expected = true },
        { s = "/// <amd-dependency path=\"foo\" />", expected = true },
        { s = "/// <amd-module />", expected = true },
        { s = "/// <reference path=\"foo\"/>", expected = true },
        { s = "/// <reference types=\"foo\"/>", expected = true },
        { s = "/// <reference lib=\"foo\"/>", expected = true },
        { s = "/// <reference no-default-lib=\"foo\"/>", expected = true },
        { s = "/// <amd-dependency path=\"foo\"/>", expected = true },
        { s = "/// <amd-module/>", expected = true },
        { s = "/// <reference path='foo' />", expected = true },
        { s = "/// <reference types='foo' />", expected = true },
        { s = "/// <reference lib='foo' />", expected = true },
        { s = "/// <reference no-default-lib='foo' />", expected = true },
        { s = "/// <amd-dependency path='foo' />", expected = true },
        { s = "/// <reference path=\"foo\" />  ", expected = true },
        { s = "/// <reference types=\"foo\" />  ", expected = true },
        { s = "/// <reference lib=\"foo\" />  ", expected = true },
        { s = "/// <reference no-default-lib=\"foo\" />  ", expected = true },
        { s = "/// <amd-dependency path=\"foo\" />  ", expected = true },
        { s = "/// <amd-module />  ", expected = true },
        { s = "/// <foo />", expected = false },
        { s = "/// <reference />", expected = false },
        { s = "/// <amd-dependency />", expected = false },
    }
    for i1, rec in ipairs(data) do
        local i = i1 - 1
        it(string.format("[%d] isRecognizedTripleSlashComment()", i), function()
            -- Go zero value ast.CommentRange{Kind: rec.commentRange.Kind}
            local kind = rec.commentRange and rec.commentRange.kind or ast.Kind.Unknown
            local commentRange = ast.NewCommentRangeValue(kind, 0, 0, false)
            if commentRange.kind == ast.Kind.Unknown then
                commentRange = ast.NewCommentRangeValue(ast.Kind.SingleLineCommentTrivia, 0, #rec.s, false)
            end
            local actual = printer.IsRecognizedTripleSlashComment(rec.s, commentRange)
            assert.are.equal(rec.expected, actual)
        end)
    end
end)
