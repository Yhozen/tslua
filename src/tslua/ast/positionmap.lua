local ast = require("tslua.ast")
local stringutil = require("tslua.stringutil")

-- PositionMap provides bidirectional mapping between UTF-8 byte offsets (used by Go)
-- and UTF-16 code unit offsets (used by JavaScript/TypeScript).
--
-- For ASCII-only text, the two are identical. For text containing non-ASCII characters,
-- the offsets diverge because multi-byte UTF-8 sequences map to different numbers of
-- UTF-16 code units:
--   - U+0000..U+007F:   1 byte  in UTF-8, 1 code unit  in UTF-16
--   - U+0080..U+07FF:   2 bytes in UTF-8, 1 code unit  in UTF-16
--   - U+0800..U+FFFF:   3 bytes in UTF-8, 1 code unit  in UTF-16
--   - U+10000..U+10FFFF: 4 bytes in UTF-8, 2 code units in UTF-16 (surrogate pair)
local PositionMap = {}
PositionMap.__index = PositionMap
PositionMap.__name = "PositionMap"
ast.PositionMap = PositionMap

-- entries[i] = { utf8Pos = UTF-8 byte offset AFTER this multi-byte character,
--                delta = cumulative (utf8 - utf16) offset difference after this character }

-- ComputePositionMap builds a PositionMap for the given text.
function ast.ComputePositionMap(text)
    local pm = setmetatable({ asciiOnly = false, entries = {} }, PositionMap)
    local delta = 0
    local i = 0
    local n = #text
    while i < n do
        local b = string.byte(text, i + 1)
        if b < 0x80 then
            i = i + 1
        else
            local r, size = stringutil.DecodeJSStringRune(string.sub(text, i + 1))
            local utf16Size = 1
            if r >= 0x10000 then
                utf16Size = 2
            end
            delta = delta + size - utf16Size
            pm.entries[#pm.entries + 1] = { utf8Pos = i + size, delta = delta }
            i = i + size
        end
    end
    pm.asciiOnly = #pm.entries == 0
    return pm
end

-- IsAsciiOnly returns true if the text is ASCII-only,
-- meaning UTF-8 and UTF-16 offsets are identical.
function PositionMap:IsAsciiOnly()
    return self.asciiOnly
end

-- UTF8ToUTF16 converts a UTF-8 byte offset to a UTF-16 code unit offset.
function PositionMap:UTF8ToUTF16(utf8Offset)
    if self.asciiOnly then
        return utf8Offset
    end
    -- Binary search: find the last entry where utf8Pos <= utf8Offset
    local entries = self.entries
    local lo, hi = 0, #entries
    while lo < hi do
        local mid = lo + (hi - lo) // 2
        if entries[mid + 1].utf8Pos <= utf8Offset then
            lo = mid + 1
        else
            hi = mid
        end
    end
    if lo == 0 then
        -- Before any multi-byte character
        return utf8Offset
    end
    return utf8Offset - entries[lo].delta
end

-- UTF16ToUTF8 converts a UTF-16 code unit offset to a UTF-8 byte offset.
function PositionMap:UTF16ToUTF8(utf16Offset)
    if self.asciiOnly then
        return utf16Offset
    end
    -- We need the last entry where (utf8Pos - delta) <= utf16Offset.
    -- (utf8Pos - delta) is the UTF-16 offset of that entry's character.
    local entries = self.entries
    local lo, hi = 0, #entries
    while lo < hi do
        local mid = lo + (hi - lo) // 2
        local utf16Pos = entries[mid + 1].utf8Pos - entries[mid + 1].delta
        if utf16Pos <= utf16Offset then
            lo = mid + 1
        else
            hi = mid
        end
    end
    if lo == 0 then
        return utf16Offset
    end
    return utf16Offset + entries[lo].delta
end
