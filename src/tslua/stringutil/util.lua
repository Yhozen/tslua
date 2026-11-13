-- Package stringutil Exports common rune utilities for parsing and emitting javascript
local stringutil = require("tslua.stringutil")
local regexp = require("tslua.regexp")

local sbyte = string.byte

function stringutil.IsWhiteSpaceLike(ch)
    return stringutil.IsWhiteSpaceSingleLine(ch) or stringutil.IsLineBreak(ch)
end

local whiteSpaceSingleLine = {
    [0x20] = true, -- space
    [0x09] = true, -- tab
    [0x0B] = true, -- verticalTab
    [0x0C] = true, -- formFeed
    [0x0085] = true, -- nextLine
    [0x00A0] = true, -- nonBreakingSpace
    [0x1680] = true, -- ogham
    [0x2000] = true, -- enQuad
    [0x2001] = true, -- emQuad
    [0x2002] = true, -- enSpace
    [0x2003] = true, -- emSpace
    [0x2004] = true, -- threePerEmSpace
    [0x2005] = true, -- fourPerEmSpace
    [0x2006] = true, -- sixPerEmSpace
    [0x2007] = true, -- figureSpace
    [0x2008] = true, -- punctuationEmSpace
    [0x2009] = true, -- thinSpace
    [0x200A] = true, -- hairSpace
    [0x200B] = true, -- zeroWidthSpace
    [0x202F] = true, -- narrowNoBreakSpace
    [0x205F] = true, -- mathematicalSpace
    [0x3000] = true, -- ideographicSpace
    [0xFEFF] = true, -- byteOrderMark
}

function stringutil.IsWhiteSpaceSingleLine(ch)
    -- Note: nextLine is in the Zs space, and should be considered to be a whitespace.
    -- It is explicitly not a line-break as it isn't in the exact set specified by EcmaScript.
    return whiteSpaceSingleLine[ch] == true
end

function stringutil.IsLineBreak(ch)
    -- ES5 7.3:
    -- The ECMAScript line terminator characters are listed in Table 3.
    --     Table 3: Line Terminator Characters
    --     Code Unit Value     Name                    Formal Name
    --     \u000A              Line Feed               <LF>
    --     \u000D              Carriage Return         <CR>
    --                    Line separator          <LS>
    --                    Paragraph separator     <PS>
    -- Only the characters in Table 3 are treated as line terminators. Other new line or line
    -- breaking characters are treated as white space but not as line terminators.
    return ch == 0x0A or ch == 0x0D or ch == 0x2028 or ch == 0x2029
end

function stringutil.IsDigit(ch)
    return ch >= 0x30 and ch <= 0x39
end

function stringutil.IsOctalDigit(ch)
    return ch >= 0x30 and ch <= 0x37
end

function stringutil.IsHexDigit(ch)
    return ch >= 0x30 and ch <= 0x39 or ch >= 0x41 and ch <= 0x46 or ch >= 0x61 and ch <= 0x66
end

function stringutil.IsASCIILetter(ch)
    return ch >= 0x41 and ch <= 0x5A or ch >= 0x61 and ch <= 0x7A
end

function stringutil.SplitLines(text)
    local lines = {}
    local start = 0
    local pos = 0
    local n = #text
    while pos < n do
        local c = sbyte(text, pos + 1)
        if c == 13 then -- '\r'
            if pos + 1 < n and sbyte(text, pos + 2) == 10 then
                lines[#lines + 1] = string.sub(text, start + 1, pos)
                pos = pos + 2
                start = pos
                goto continue
            end
            lines[#lines + 1] = string.sub(text, start + 1, pos)
            pos = pos + 1
            start = pos
            goto continue
        elseif c == 10 then -- '\n'
            lines[#lines + 1] = string.sub(text, start + 1, pos)
            pos = pos + 1
            start = pos
            goto continue
        end
        pos = pos + 1
        ::continue::
    end
    if start < n then
        lines[#lines + 1] = string.sub(text, start + 1)
    end
    return lines
end

function stringutil.GuessIndentation(lines)
    local MAX_SMI_X86 = 0x3fffffff
    local indentation = MAX_SMI_X86
    for _, line in ipairs(lines) do
        if #line == 0 then
            goto continue
        end
        do
            local i = 0
            while i < #line and i < indentation do
                local ch, size = stringutil.DecodeRune(line, i)
                if not stringutil.IsWhiteSpaceLike(ch) then
                    break
                end
                i = i + size
            end
            if i < indentation then
                indentation = i
            end
            if indentation == 0 then
                return 0
            end
        end
        ::continue::
    end
    if indentation == MAX_SMI_X86 then
        return 0
    end
    return indentation
end

local upperhex = "0123456789ABCDEF"

-- https://tc39.es/ecma262/multipage/global-object.html#sec-encodeuri-uri
function stringutil.EncodeURI(s)
    local parts = {}
    for i = 1, #s do
        local b = sbyte(s, i)
        if not stringutil.shouldEscapeForEncodeURI(b) then
            parts[#parts + 1] = string.char(b)
        else
            parts[#parts + 1] = "%" .. string.sub(upperhex, (b >> 4) + 1, (b >> 4) + 1) .. string.sub(upperhex, (b & 0x0f) + 1, (b & 0x0f) + 1)
        end
    end
    return table.concat(parts)
end

local encodeURIUnescaped = {}
for c in string.gmatch(";/?:@&=+$,#-_.!~*'()", ".") do
    encodeURIUnescaped[sbyte(c)] = true
end

function stringutil.shouldEscapeForEncodeURI(b)
    if b >= 0x41 and b <= 0x5A then
        return false
    elseif b >= 0x61 and b <= 0x7A then
        return false
    elseif b >= 0x30 and b <= 0x39 then
        return false
    end
    return not encodeURIUnescaped[b]
end

function stringutil.getByteOrderMarkLength(text)
    if #text >= 1 then
        local ch0 = sbyte(text, 1)
        if ch0 == 0xfe then
            if #text >= 2 and sbyte(text, 2) == 0xff then
                return 2 -- utf16be
            end
            return 0
        end
        if ch0 == 0xff then
            if #text >= 2 and sbyte(text, 2) == 0xfe then
                return 2 -- utf16le
            end
            return 0
        end
        if ch0 == 0xef then
            if #text >= 3 and sbyte(text, 2) == 0xbb and sbyte(text, 3) == 0xbf then
                return 3 -- utf8
            end
            return 0
        end
    end
    return 0
end

function stringutil.RemoveByteOrderMark(text)
    local length = stringutil.getByteOrderMarkLength(text)
    if length > 0 then
        return string.sub(text, length + 1)
    end
    return text
end

function stringutil.AddUTF8ByteOrderMark(text)
    if stringutil.getByteOrderMarkLength(text) == 0 then
        return "\xEF\xBB\xBF" .. text
    end
    return text
end

function stringutil.StripQuotes(name)
    if #name < 2 then
        return name
    end
    local firstChar = stringutil.DecodeRune(name, 0)
    local lastChar = stringutil.DecodeLastRune(name)
    if firstChar == lastChar and (firstChar == 0x27 or firstChar == 0x22 or firstChar == 0x60) then
        return string.sub(name, 2, #name - 1)
    end
    return name
end

stringutil.matchSlashSomething = regexp.MustCompile("\\\\.")

function stringutil.matchSlashReplacer(in_)
    return string.sub(in_, 2)
end

function stringutil.UnquoteString(str)
    -- strconv.Unquote is insufficient as that only handles a single character inside single quotes, as those are character literals in go
    local inner = stringutil.StripQuotes(str)
    -- In strada we do str.replace(/\\./g, s => s.substring(1)) - which is to say, replace all backslash-something with just something
    -- That's replicated here faithfully, but it seems wrong! This should probably be an actual unquote operation?
    return stringutil.matchSlashSomething:ReplaceAllStringFunc(inner, stringutil.matchSlashReplacer)
end

function stringutil.LowerFirstChar(str)
    local char, size = stringutil.DecodeRune(str, 0)
    if size > 0 then
        return stringutil.EncodeRune(stringutil.UnicodeToLower(char)) .. string.sub(str, size + 1)
    end
    return str
end

function stringutil.TruncateByRunes(str, maxLength)
    if #str < maxLength then
        return str
    end
    if maxLength <= 0 then
        return ""
    end
    local runeCount = 0
    local i = 0
    local n = #str
    while i < n do
        runeCount = runeCount + 1
        if runeCount > maxLength then
            return string.sub(str, 1, i)
        end
        local _, size = stringutil.DecodeRune(str, i)
        i = i + size
    end
    return str
end

function stringutil.IsHighSurrogate(ch)
    return stringutil.IsSurrogate(ch) and ch < stringutil.SurrogateLowStart
end

function stringutil.IsLowSurrogate(ch)
    return stringutil.IsSurrogate(ch) and ch >= stringutil.SurrogateLowStart
end

function stringutil.IsSurrogate(ch)
    return ch >= 0xD800 and ch < 0xE000
end

-- Go utf16.DecodeRune.
function stringutil.SurrogatePairToCodePoint(high, low)
    if high >= 0xD800 and high < 0xDC00 and low >= 0xDC00 and low < 0xE000 then
        return (((high - 0xD800) << 10) | (low - 0xDC00)) + 0x10000
    end
    return 0xFFFD
end

-- Go utf16.EncodeRune. Returns (high, low).
function stringutil.CodePointToSurrogatePair(ch)
    if ch < 0x10000 or ch > 0x10FFFF then
        return 0xFFFD, 0xFFFD
    end
    ch = ch - 0x10000
    return 0xD800 + ((ch >> 10) & 0x3ff), 0xDC00 + (ch & 0x3ff)
end

-- A lone surrogate (U+D800–U+DFFF) cannot be represented in valid UTF-8, so
-- EncodeJSStringRune stores it as the 3-byte CESU-8/WTF-8 sentinel that UTF-8
-- would use for that code point if surrogates were encodable.
stringutil.surrogateUTF8Lead = 0xED -- byte0, shared by the whole U+D000–U+DFFF block
stringutil.surrogateUTF8LeadBits = 0xD000 -- (surrogateUTF8Lead & 0x0F) << 12, byte0's decoded contribution
stringutil.utf8ContMarker = 0x80 -- continuation byte marker / min value (10xxxxxx)
stringutil.utf8ContMax = 0xBF -- continuation byte max value
stringutil.utf8ContMask = 0x3F -- data bits carried by a continuation byte
-- byte1 bounds that pin the block down to the surrogate range U+D800–U+DFFF:
-- 0xD800 -> 0xA0, 0xDFFF -> 0xBF.
stringutil.surrogateUTF8Byte1Min = 0xA0
stringutil.surrogateUTF8Byte1Max = 0xBF

function stringutil.EncodeJSStringRune(ch)
    if stringutil.IsSurrogate(ch) then
        return string.char(
            stringutil.surrogateUTF8Lead,
            stringutil.utf8ContMarker | ((ch >> 6) & stringutil.utf8ContMask),
            stringutil.utf8ContMarker | (ch & stringutil.utf8ContMask))
    end
    return stringutil.EncodeRune(ch)
end

-- Go DecodeJSStringRune(s[pos:]); pos is a 0-based byte offset (default 0). Returns (rune, size).
function stringutil.DecodeJSStringRune(s, pos)
    pos = pos or 0
    if #s - pos >= 3 then
        local b0, b1, b2 = sbyte(s, pos + 1, pos + 3)
        if b0 == stringutil.surrogateUTF8Lead and
            b1 >= stringutil.surrogateUTF8Byte1Min and b1 <= stringutil.surrogateUTF8Byte1Max and
            b2 >= stringutil.utf8ContMarker and b2 <= stringutil.utf8ContMax then
            return stringutil.surrogateUTF8LeadBits | ((b1 & stringutil.utf8ContMask) << 6) | (b2 & stringutil.utf8ContMask), 3
        end
    end
    return stringutil.DecodeRune(s, pos)
end

-- CombineSurrogatePairs canonicalizes a JS-string value produced by
-- concatenation, merging any adjacent high+low surrogate sentinel pair (as
-- written by EncodeJSStringRune) into the single supplementary code point they
-- represent. This mirrors how concatenating two UTF-16 code units forms a
-- surrogate pair in a JavaScript string. It must be applied wherever separately
-- scanned string values are joined, since each half is only a lone surrogate
-- until it meets its partner. Strings without a lone-surrogate sentinel (the
-- common case) are returned unchanged.
function stringutil.CombineSurrogatePairs(s)
    if not string.find(s, "\xED", 1, true) then
        return s
    end
    local parts = {}
    local i = 0
    local n = #s
    while i < n do
        local r, size = stringutil.DecodeJSStringRune(s, i)
        if stringutil.IsHighSurrogate(r) then
            local low, lowSize = stringutil.DecodeJSStringRune(s, i + size)
            if stringutil.IsLowSurrogate(low) then
                parts[#parts + 1] = stringutil.EncodeRune(stringutil.SurrogatePairToCodePoint(r, low))
                i = i + size + lowSize
                goto continue
            end
        end
        parts[#parts + 1] = string.sub(s, i + 1, i + size)
        i = i + size
        ::continue::
    end
    return table.concat(parts)
end
