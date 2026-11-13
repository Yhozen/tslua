-- Lua-only emulation (no Go counterpart file) of the parts of Go's strconv package that the
-- regexp port uses (quoting for error messages and program dumps).
local strconv = {}
package.loaded["tslua.regexp.strconv"] = strconv

local utf8 = require("tslua.regexp.utf8")
local unicode = require("tslua.regexp.unicode")

local lowerhex = "0123456789abcdef"

local function hexDigit(v)
    return string.sub(lowerhex, v + 1, v + 1)
end

local function hexN(r, n)
    local out = {}
    for s = (n - 1) * 4, 0, -4 do
        out[#out + 1] = hexDigit((r >> s) & 0xF)
    end
    return table.concat(out)
end

-- Go strconv.IsPrint (same as unicode.IsPrint).
function strconv.IsPrint(r)
    return unicode.IsPrint(r)
end

local function appendEscapedRune(buf, r, quote, asciiOnly)
    if r == quote or r == 0x5C then
        buf[#buf + 1] = "\\"
        buf[#buf + 1] = utf8.EncodeRune(r)
        return
    end
    if asciiOnly then
        if r < utf8.RuneSelf and strconv.IsPrint(r) then
            buf[#buf + 1] = string.char(r)
            return
        end
    elseif strconv.IsPrint(r) then
        buf[#buf + 1] = utf8.EncodeRune(r)
        return
    end
    if r == 7 then
        buf[#buf + 1] = "\\a"
    elseif r == 8 then
        buf[#buf + 1] = "\\b"
    elseif r == 12 then
        buf[#buf + 1] = "\\f"
    elseif r == 10 then
        buf[#buf + 1] = "\\n"
    elseif r == 13 then
        buf[#buf + 1] = "\\r"
    elseif r == 9 then
        buf[#buf + 1] = "\\t"
    elseif r == 11 then
        buf[#buf + 1] = "\\v"
    elseif r < 0x20 or r == 0x7F then
        buf[#buf + 1] = "\\x" .. hexN(r & 0xFF, 2)
    else
        if not utf8.ValidRune(r) then
            r = 0xFFFD
        end
        if r < 0x10000 then
            buf[#buf + 1] = "\\u" .. hexN(r, 4)
        else
            buf[#buf + 1] = "\\U" .. hexN(r, 8)
        end
    end
end

local function quoteWith(s, quote, asciiOnly)
    local buf = { string.char(quote) }
    local pos, n = 0, #s
    while pos < n do
        local r, width = string.byte(s, pos + 1), 1
        if r >= utf8.RuneSelf then
            r, width = utf8.DecodeRuneInString(s, pos)
        end
        if width == 1 and r == utf8.RuneError then
            local b = string.byte(s, pos + 1)
            buf[#buf + 1] = "\\x" .. hexDigit(b >> 4) .. hexDigit(b & 0xF)
        else
            appendEscapedRune(buf, r, quote, asciiOnly)
        end
        pos = pos + width
    end
    buf[#buf + 1] = string.char(quote)
    return table.concat(buf)
end

-- Go strconv.Quote.
function strconv.Quote(s)
    return quoteWith(s, 0x22, false)
end

-- Go strconv.QuoteToASCII.
function strconv.QuoteToASCII(s)
    return quoteWith(s, 0x22, true)
end

-- Go strconv.QuoteRune.
function strconv.QuoteRune(r)
    local buf = { "'" }
    appendEscapedRune(buf, r, 0x27, false)
    buf[#buf + 1] = "'"
    return table.concat(buf)
end

-- Go strconv.CanBackquote.
function strconv.CanBackquote(s)
    local pos, n = 0, #s
    while pos < n do
        local r, wid = utf8.DecodeRuneInString(s, pos)
        pos = pos + wid
        if wid > 1 then
            if r == 0xFEFF then
                return false
            end
        else
            if r == utf8.RuneError then
                return false
            end
            if (r < 0x20 and r ~= 0x09) or r == 0x60 or r == 0x7F then
                return false
            end
        end
    end
    return true
end

-- Go strconv.Itoa.
function strconv.Itoa(i)
    return string.format("%d", i)
end

-- Go strconv.FormatInt(i, base) for base 10 and 16.
function strconv.FormatInt(i, base)
    if base == 16 then
        if i < 0 then
            return "-" .. string.format("%x", -i)
        end
        return string.format("%x", i)
    end
    return string.format("%d", i)
end

strconv.FormatUint = strconv.FormatInt

return strconv
