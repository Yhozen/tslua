local sourcemap = require("tslua.sourcemap")
local stringutil = require("tslua.stringutil")

-- Tries to find the sourceMappingURL comment at the end of a file.
function sourcemap.TryGetSourceMappingURL(lineInfo)
    if lineInfo ~= nil then
        for index = lineInfo:LineCount() - 1, 0, -1 do
            local line = lineInfo:LineText(index)
            line = sourcemap.trimLeftFunc(line, sourcemap.unicodeIsSpace)
            line = sourcemap.trimRightFunc(line, stringutil.IsLineBreak)
            if #line == 0 then
                goto continue
            end
            do
                local c2 = string.byte(line, 3)
                if #line < 4 or string.sub(line, 1, 2) ~= "//" or c2 ~= 0x23 and c2 ~= 0x40 or string.byte(line, 4) ~= 0x20 then
                    break
                end
                local rest = string.sub(line, 5)
                local prefix = "sourceMappingURL="
                if string.sub(rest, 1, #prefix) == prefix then
                    return sourcemap.trimRightFunc(string.sub(rest, #prefix + 1), sourcemap.unicodeIsSpace)
                end
            end
            ::continue::
        end
    end
    return ""
end

-- Lua-only helpers (Go standard library equivalents used by this package).

local RuneError = 0xFFFD

-- utf8.DecodeRuneInString(s[i:]) with a 0-based byte offset i; returns rune, size.
function sourcemap.decodeRune(s, i)
    local n = #s - i
    if n < 1 then
        return RuneError, 0
    end
    local b0 = string.byte(s, i + 1)
    if b0 < 0x80 then
        return b0, 1
    end
    local size, min, r
    if b0 >= 0xC2 and b0 <= 0xDF then
        size, min, r = 2, 0x80, b0 & 0x1F
    elseif b0 >= 0xE0 and b0 <= 0xEF then
        size, min, r = 3, 0x800, b0 & 0x0F
    elseif b0 >= 0xF0 and b0 <= 0xF4 then
        size, min, r = 4, 0x10000, b0 & 0x07
    else
        return RuneError, 1
    end
    if n < size then
        -- check the available continuation bytes like Go does: any invalid -> width 1
        return RuneError, 1
    end
    for k = 1, size - 1 do
        local b = string.byte(s, i + 1 + k)
        if b < 0x80 or b > 0xBF then
            return RuneError, 1
        end
        r = (r << 6) | (b & 0x3F)
    end
    if r < min or r > 0x10FFFF or (r >= 0xD800 and r <= 0xDFFF) then
        return RuneError, 1
    end
    return r, size
end

-- utf8.DecodeLastRuneInString(s); returns rune, size.
function sourcemap.decodeLastRune(s)
    local end_ = #s
    if end_ == 0 then
        return RuneError, 0
    end
    local start = end_ - 1
    local b = string.byte(s, start + 1)
    if b < 0x80 then
        return b, 1
    end
    local lim = end_ - 4
    if lim < 0 then
        lim = 0
    end
    start = start - 1
    while start >= lim do
        local c = string.byte(s, start + 1)
        if c & 0xC0 ~= 0x80 then
            break
        end
        start = start - 1
    end
    if start < 0 then
        start = 0
    end
    local r, size = sourcemap.decodeRune(string.sub(s, 1, end_), start)
    if start + size ~= end_ then
        return RuneError, 1
    end
    return r, size
end

-- unicode.IsSpace
function sourcemap.unicodeIsSpace(r)
    if r <= 0xFF then
        return r == 0x20 or (r >= 0x09 and r <= 0x0D) or r == 0x85 or r == 0xA0
    end
    return r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x2028 or r == 0x2029 or
        r == 0x202F or r == 0x205F or r == 0x3000
end

-- strings.TrimLeftFunc
function sourcemap.trimLeftFunc(s, f)
    local i = 0
    while i < #s do
        local r, size = sourcemap.decodeRune(s, i)
        if not f(r) then
            break
        end
        i = i + size
    end
    return string.sub(s, i + 1)
end

-- strings.TrimRightFunc
function sourcemap.trimRightFunc(s, f)
    while #s > 0 do
        local r, size = sourcemap.decodeLastRune(s)
        if not f(r) then
            break
        end
        s = string.sub(s, 1, #s - size)
    end
    return s
end
