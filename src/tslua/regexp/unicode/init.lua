-- Lua-only emulation (no Go counterpart file) of the parts of Go's unicode package that the
-- regexp port uses. The tables (and the results of SimpleFold, IsPrint, IsLetter, IsDigit over
-- all runes) are generated from Go by scripts/gen/regexptables and loaded on first use.
local unicode = {}
package.loaded["tslua.regexp.unicode"] = unicode

unicode.MaxRune = 0x10FFFF
unicode.ReplacementChar = 0xFFFD
unicode.MaxASCII = 0x7F
unicode.MaxLatin1 = 0xFF

local tables -- tslua.regexp.unicode.tables_generated, loaded lazily
local foldMap -- rune -> unicode.SimpleFold(rune), only for runes that fold

local function load()
    if tables == nil then
        tables = require("tslua.regexp.unicode.tables_generated")
        foldMap = {}
        local f = tables.fold
        for i = 1, #f, 2 do
            foldMap[f[i]] = f[i + 1]
        end
        unicode.Version = tables.Version
        unicode.Categories = tables.Categories
        unicode.Scripts = tables.Scripts
        unicode.FoldCategory = tables.FoldCategory
        unicode.FoldScript = tables.FoldScript
        unicode.CategoryAliases = tables.CategoryAliases
        unicode.Cn = tables.Cn
    end
    return tables
end

-- unicode.Categories, Scripts, FoldCategory, FoldScript, CategoryAliases, Cn, Version are
-- materialized on first access.
setmetatable(unicode, {
    __index = function(_, k)
        if k == "Categories" or k == "Scripts" or k == "FoldCategory" or k == "FoldScript"
            or k == "CategoryAliases" or k == "Cn" or k == "Version" then
            load()
            return rawget(unicode, k)
        end
        return nil
    end,
})

-- Go unicode.SimpleFold: the smallest rune > r in r's case-folding orbit if one exists, else
-- the smallest rune >= 0 in it.
function unicode.SimpleFold(r)
    if r < 0 or r > unicode.MaxRune then
        return r
    end
    if foldMap == nil then
        load()
    end
    local f = foldMap[r]
    if f ~= nil then
        return f
    end
    return r
end

local function inPairs(ranges, r)
    local lo, hi = 0, #ranges // 2 - 1
    while lo <= hi do
        local m = (lo + hi) // 2
        if r < ranges[2 * m + 1] then
            hi = m - 1
        elseif r > ranges[2 * m + 2] then
            lo = m + 1
        else
            return true
        end
    end
    return false
end

-- Go unicode.IsPrint.
function unicode.IsPrint(r)
    return inPairs(load().print, r)
end

-- Go unicode.IsLetter.
function unicode.IsLetter(r)
    if r >= 0 and r < 0x80 then
        return (r >= 0x41 and r <= 0x5A) or (r >= 0x61 and r <= 0x7A)
    end
    return inPairs(load().letter, r)
end

-- Go unicode.IsDigit.
function unicode.IsDigit(r)
    if r >= 0 and r < 0x80 then
        return r >= 0x30 and r <= 0x39
    end
    return inPairs(load().digit, r)
end

local function inStrided(xs, r)
    for i = 1, #xs, 3 do
        local lo, hi, stride = xs[i], xs[i + 1], xs[i + 2]
        if r < lo then
            return false
        end
        if r <= hi then
            return stride == 1 or (r - lo) % stride == 0
        end
    end
    return false
end

-- Go unicode.Is for a generated range table.
function unicode.Is(tab, r)
    return inStrided(tab.r16, r) or inStrided(tab.r32, r)
end

return unicode
