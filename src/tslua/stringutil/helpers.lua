-- Lua-only helpers (no Go counterpart file): UTF-8 primitives with Go unicode/utf8 semantics and
-- approximations of Go unicode/strings case functions built on the generated JS case tables.
local stringutil = require("tslua.stringutil")

local sbyte, schar, ssub = string.byte, string.char, string.sub


-- Go utf8.DecodeRuneInString(s[pos:]); pos is a 0-based byte offset (default 0).
-- Returns rune, size. Empty input -> RuneError, 0; invalid encoding -> RuneError, 1.
function stringutil.DecodeRune(s, pos)
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
        -- still must validate available bytes, but result is RuneError, 1 either way
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

-- Go utf8.DecodeLastRuneInString(s[:end_]); end_ is a 0-based exclusive byte offset (default #s).
function stringutil.DecodeLastRune(s, end_)
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
    local r, size = stringutil.DecodeRune(ssub(s, start + 1, end_), 0)
    if start + size ~= end_ then
        return 0xFFFD, 1
    end
    return r, size
end

-- Go string(rune) / utf8.EncodeRune: invalid code points (negative, surrogates, > MaxRune)
-- encode as U+FFFD.
function stringutil.EncodeRune(r)
    if r >= 0 and r < 0x80 then
        return schar(r)
    end
    if r < 0 or r > 0x10FFFF or (r >= 0xD800 and r <= 0xDFFF) then
        r = 0xFFFD
    end
    if r < 0x800 then
        return schar(0xC0 | (r >> 6), 0x80 | (r & 0x3F))
    elseif r < 0x10000 then
        return schar(0xE0 | (r >> 12), 0x80 | ((r >> 6) & 0x3F), 0x80 | (r & 0x3F))
    end
    return schar(0xF0 | (r >> 18), 0x80 | ((r >> 12) & 0x3F), 0x80 | ((r >> 6) & 0x3F), 0x80 | (r & 0x3F))
end

-- Go utf8.RuneLen.
function stringutil.RuneLen(r)
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


-- Go unicode.Is for a generated range table (flat lo, hi, stride triples sorted by lo).
function stringutil.unicodeIs(tab, r)
    local n = #tab // 3
    local lo, hi = 0, n - 1
    while lo <= hi do
        local m = (lo + hi) // 2
        local base = m * 3
        local rlo = tab[base + 1]
        if r < rlo then
            hi = m - 1
        elseif r > tab[base + 2] then
            lo = m + 1
        else
            local stride = tab[base + 3]
            return stride == 1 or (r - rlo) % stride == 0
        end
    end
    return false
end

local function singleRune(s)
    local r, size = stringutil.DecodeRune(s, 0)
    if size == #s and size > 0 then
        return r
    end
    return nil
end

-- Simple (one-rune) case mappings derived from the generated tables, approximating Go's
-- unicode.ToLower / unicode.ToUpper.
local simpleLower = {}
local simpleUpper = {}

function stringutil.UnicodeToLower(r)
    if r < 0x80 then
        if r >= 0x41 and r <= 0x5A then
            return r + 32
        end
        return r
    end
    local v = simpleLower[r]
    if v == nil then
        v = r
        local mapping = stringutil.specialCasingMappings[r]
        if mapping ~= nil then
            local single = singleRune(mapping.lower)
            if single ~= nil then
                v = single
            elseif r == 0x130 then
                -- Go: unicode.ToLower('İ') == 'i' (UnicodeData simple mapping)
                v = 0x69
            end
        end
        simpleLower[r] = v
    end
    return v
end

function stringutil.UnicodeToUpper(r)
    if r < 0x80 then
        if r >= 0x61 and r <= 0x7A then
            return r - 32
        end
        return r
    end
    local v = simpleUpper[r]
    if v == nil then
        v = r
        local mapping = stringutil.specialCasingMappings[r]
        if mapping ~= nil then
            local single = singleRune(mapping.upper)
            if single ~= nil then
                v = single
            end
        end
        simpleUpper[r] = v
    end
    return v
end

-- Go strings.EqualFold (simple case folding, approximated with the simple mappings above).
function stringutil.EqualFold(s, t)
    if s == t then
        return true
    end
    local i, j = 0, 0
    local ns, nt = #s, #t
    while i < ns and j < nt do
        local r1, s1 = stringutil.DecodeRune(s, i)
        local r2, s2 = stringutil.DecodeRune(t, j)
        i = i + s1
        j = j + s2
        if r1 ~= r2 then
            if stringutil.UnicodeToLower(r1) ~= stringutil.UnicodeToLower(r2) and
                stringutil.UnicodeToUpper(r1) ~= stringutil.UnicodeToUpper(r2) then
                return false
            end
        end
    end
    return i == ns and j == nt
end

local function stringsMap(f, s)
    local parts = {}
    local pos = 0
    local n = #s
    local k = 0
    while pos < n do
        local r, size = stringutil.DecodeRune(s, pos)
        pos = pos + size
        k = k + 1
        parts[k] = stringutil.EncodeRune(f(r))
    end
    return table.concat(parts)
end

local function isASCII(s)
    return not string.find(s, "[\128-\255]")
end

-- Go strings.ToLower.
function stringutil.StringsToLower(s)
    if isASCII(s) then
        if not string.find(s, "[A-Z]") then
            return s
        end
        return (string.gsub(s, "[A-Z]", function(c)
            return schar(sbyte(c) + 32)
        end))
    end
    return stringsMap(stringutil.UnicodeToLower, s)
end

-- Go strings.ToUpper.
function stringutil.StringsToUpper(s)
    if isASCII(s) then
        if not string.find(s, "[a-z]") then
            return s
        end
        return (string.gsub(s, "[a-z]", function(c)
            return schar(sbyte(c) - 32)
        end))
    end
    return stringsMap(stringutil.UnicodeToUpper, s)
end

-- Go unicode.IsSpace.
function stringutil.UnicodeIsSpace(r)
    if r <= 0xFF then
        return r == 0x20 or (r >= 0x09 and r <= 0x0D) or r == 0x85 or r == 0xA0
    end
    return r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x2028 or r == 0x2029 or
        r == 0x202F or r == 0x205F or r == 0x3000
end

-- Go unicode.IsUpper / IsLower (approximated with the simple case mappings).
function stringutil.UnicodeIsUpper(r)
    return stringutil.UnicodeToLower(r) ~= r
end

function stringutil.UnicodeIsLower(r)
    return stringutil.UnicodeToUpper(r) ~= r
end
