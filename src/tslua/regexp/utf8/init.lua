-- Lua-only emulation (no Go counterpart file) of the parts of Go unicode/utf8 that the regexp
-- port uses. Kept inside tslua.regexp so the regexp packages stay leaves (tslua.stringutil
-- itself needs regexp).
local utf8 = {}
package.loaded["tslua.regexp.utf8"] = utf8

local sbyte, schar, ssub = string.byte, string.char, string.sub

utf8.RuneError = 0xFFFD
utf8.RuneSelf = 0x80
utf8.MaxRune = 0x10FFFF
utf8.UTFMax = 4

-- Go utf8.DecodeRuneInString(s[pos:]); pos is a 0-based byte offset (default 0).
-- Returns rune, size. Empty input -> RuneError, 0; invalid encoding -> RuneError, 1.
function utf8.DecodeRuneInString(s, pos)
    pos = pos or 0
    local n = #s
    if pos >= n then
        return 0xFFFD, 0
    end
    local i = pos + 1
    local c0 = sbyte(s, i)
    if c0 < 0x80 then
        return c0, 1
    end
    local size, lo, hi
    if c0 >= 0xC2 and c0 <= 0xDF then
        size, lo, hi = 2, 0x80, 0xBF
    elseif c0 == 0xE0 then
        size, lo, hi = 3, 0xA0, 0xBF
    elseif c0 == 0xED then
        size, lo, hi = 3, 0x80, 0x9F
    elseif c0 >= 0xE1 and c0 <= 0xEF then
        size, lo, hi = 3, 0x80, 0xBF
    elseif c0 == 0xF0 then
        size, lo, hi = 4, 0x90, 0xBF
    elseif c0 == 0xF4 then
        size, lo, hi = 4, 0x80, 0x8F
    elseif c0 >= 0xF1 and c0 <= 0xF3 then
        size, lo, hi = 4, 0x80, 0xBF
    else
        return 0xFFFD, 1
    end
    if pos + size > n then
        return 0xFFFD, 1
    end
    local c1 = sbyte(s, i + 1)
    if c1 < lo or c1 > hi then
        return 0xFFFD, 1
    end
    if size == 2 then
        return ((c0 & 0x1F) << 6) | (c1 & 0x3F), 2
    end
    local c2 = sbyte(s, i + 2)
    if c2 < 0x80 or c2 > 0xBF then
        return 0xFFFD, 1
    end
    if size == 3 then
        return ((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F), 3
    end
    local c3 = sbyte(s, i + 3)
    if c3 < 0x80 or c3 > 0xBF then
        return 0xFFFD, 1
    end
    return ((c0 & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F), 4
end

-- Go utf8.DecodeRune on a []byte: byte slices are Lua strings in this port.
utf8.DecodeRune = utf8.DecodeRuneInString

-- Go utf8.DecodeLastRuneInString(s[:end_]); end_ is a 0-based exclusive byte offset (default #s).
function utf8.DecodeLastRuneInString(s, end_)
    end_ = end_ or #s
    if end_ <= 0 then
        return 0xFFFD, 0
    end
    local start = end_ - 1
    local c = sbyte(s, start + 1)
    if c < 0x80 then
        return c, 1
    end
    local lim = end_ - 4
    if lim < 0 then
        lim = 0
    end
    start = start - 1
    while start >= lim do
        if (sbyte(s, start + 1) & 0xC0) ~= 0x80 then
            break
        end
        start = start - 1
    end
    if start < 0 then
        start = 0
    end
    local r, size = utf8.DecodeRuneInString(ssub(s, start + 1, end_), 0)
    if start + size ~= end_ then
        return 0xFFFD, 1
    end
    return r, size
end

utf8.DecodeLastRune = utf8.DecodeLastRuneInString

-- Go utf8.RuneLen.
function utf8.RuneLen(r)
    if r < 0 then
        return -1
    elseif r < 0x80 then
        return 1
    elseif r < 0x800 then
        return 2
    elseif r >= 0xD800 and r <= 0xDFFF then
        return -1
    elseif r < 0x10000 then
        return 3
    elseif r <= 0x10FFFF then
        return 4
    end
    return -1
end

-- Go utf8.ValidRune.
function utf8.ValidRune(r)
    if 0 <= r and r < 0xD800 then
        return true
    elseif 0xDFFF < r and r <= 0x10FFFF then
        return true
    end
    return false
end

-- Go string(r) / utf8.AppendRune: invalid code points encode as U+FFFD.
function utf8.EncodeRune(r)
    if r >= 0 and r < 0x80 then
        return schar(r)
    end
    if not utf8.ValidRune(r) then
        r = 0xFFFD
    end
    if r < 0x800 then
        return schar(0xC0 | (r >> 6), 0x80 | (r & 0x3F))
    elseif r < 0x10000 then
        return schar(0xE0 | (r >> 12), 0x80 | ((r >> 6) & 0x3F), 0x80 | (r & 0x3F))
    end
    return schar(0xF0 | (r >> 18), 0x80 | ((r >> 12) & 0x3F), 0x80 | ((r >> 6) & 0x3F), 0x80 | (r & 0x3F))
end

-- Go string(runes) for a []rune.
function utf8.RunesToString(runes)
    local parts = {}
    for i = 1, #(runes or {}) do
        parts[i] = utf8.EncodeRune(runes[i])
    end
    return table.concat(parts)
end

-- Go []rune(s).
function utf8.StringToRunes(s)
    local out = {}
    local pos, n = 0, #s
    while pos < n do
        local r, size = utf8.DecodeRuneInString(s, pos)
        out[#out + 1] = r
        pos = pos + size
    end
    return out
end

-- Go utf8.RuneCountInString.
function utf8.RuneCountInString(s)
    local count, pos, n = 0, 0, #s
    while pos < n do
        local _, size = utf8.DecodeRuneInString(s, pos)
        pos = pos + size
        count = count + 1
    end
    return count
end

return utf8
