-- Lua-only helpers (Go `strings` package equivalents) used by ported code. No Go counterpart file.
local module = require("tslua.module")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local strings = {}
module.strings = strings

local sfind, ssub = string.find, string.sub

-- strings.Index: 0-based byte index of the first occurrence of sub, or -1.
function strings.Index(s, sub)
    local i = sfind(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

-- strings.LastIndex: 0-based byte index of the last occurrence of sub, or -1.
function strings.LastIndex(s, sub)
    if sub == "" then
        return #s
    end
    local last = -1
    local init = 1
    while true do
        local i = sfind(s, sub, init, true)
        if i == nil then
            return last
        end
        last = i - 1
        init = i + 1
    end
end

-- strings.IndexAny: 0-based index of the first byte of s that occurs in chars (ASCII only).
function strings.IndexAny(s, chars)
    for i = 1, #s do
        if sfind(chars, ssub(s, i, i), 1, true) then
            return i - 1
        end
    end
    return -1
end

function strings.HasPrefix(s, prefix)
    return #s >= #prefix and ssub(s, 1, #prefix) == prefix
end

function strings.HasSuffix(s, suffix)
    return #s >= #suffix and (suffix == "" or ssub(s, -#suffix) == suffix)
end

function strings.Contains(s, sub)
    return sfind(s, sub, 1, true) ~= nil
end

function strings.TrimPrefix(s, prefix)
    if strings.HasPrefix(s, prefix) then
        return ssub(s, #prefix + 1)
    end
    return s
end

function strings.TrimSuffix(s, suffix)
    if suffix ~= "" and strings.HasSuffix(s, suffix) then
        return ssub(s, 1, #s - #suffix)
    end
    return s
end

-- strings.Count for a non-empty sub.
function strings.Count(s, sub)
    local n = 0
    local init = 1
    while true do
        local i, j = sfind(s, sub, init, true)
        if i == nil then
            return n
        end
        n = n + 1
        init = j + 1
    end
end

-- strings.Cut: before, after, found.
function strings.Cut(s, sep)
    local i, j = sfind(s, sep, 1, true)
    if i == nil then
        return s, "", false
    end
    return ssub(s, 1, i - 1), ssub(s, j + 1), true
end

-- strings.Replace(s, old, new, n); n < 0 replaces all. old must be non-empty.
function strings.Replace(s, old, new, n)
    local parts = {}
    local init = 1
    local count = 0
    while n < 0 or count < n do
        local i, j = sfind(s, old, init, true)
        if i == nil then
            break
        end
        parts[#parts + 1] = ssub(s, init, i - 1)
        parts[#parts + 1] = new
        init = j + 1
        count = count + 1
    end
    parts[#parts + 1] = ssub(s, init)
    return table.concat(parts)
end

function strings.ReplaceAll(s, old, new)
    return strings.Replace(s, old, new, -1)
end

-- strings.Split for a non-empty separator.
function strings.Split(s, sep)
    local result = {}
    local init = 1
    while true do
        local i, j = sfind(s, sep, init, true)
        if i == nil then
            result[#result + 1] = ssub(s, init)
            return result
        end
        result[#result + 1] = ssub(s, init, i - 1)
        init = j + 1
    end
end

-- strings.Join
function strings.Join(xs, sep)
    return table.concat(xs or {}, sep)
end

-- strings.Compare
function strings.Compare(a, b)
    if a == b then
        return 0
    elseif a < b then
        return -1
    end
    return 1
end

-- strings.ToLower
function strings.ToLower(s)
    return stringutil.StringsToLower(s)
end

-- strings.TrimFunc(s, f) with f(rune) -> bool.
function strings.TrimFunc(s, f)
    local start = 0
    while start < #s do
        local r, size = stringutil.DecodeRune(s, start)
        if not f(r) then
            break
        end
        start = start + size
    end
    local stop = #s
    while stop > start do
        local r, size = stringutil.DecodeLastRune(s, stop)
        if not f(r) then
            break
        end
        stop = stop - size
    end
    return string.sub(s, start + 1, stop)
end

-- strings.TrimSpace
function strings.TrimSpace(s)
    return strings.TrimFunc(s, stringutil.UnicodeIsSpace)
end

-- strings.EqualFold
function strings.EqualFold(a, b)
    return stringutil.EqualFold(a, b)
end

-- slices.Contains for arrays of comparable values.
function strings.SliceContains(xs, v)
    if xs == nil then
        return false
    end
    for _, x in ipairs(xs) do
        if x == v then
            return true
        end
    end
    return false
end

-- slices.SortFunc. Stable insertion sort: Go's pdqsort uses insertion sort for short slices
-- (<= 12 elements), so this matches Go's order for the small inputs sorted here.
function module.sortFunc(xs, cmp)
    for i = 2, #xs do
        local v = xs[i]
        local j = i - 1
        while j >= 1 and cmp(v, xs[j]) < 0 do
            xs[j + 1] = xs[j]
            j = j - 1
        end
        xs[j + 1] = v
    end
    return xs
end

-- tspath.ComparePathsOptions value struct.
function module.newComparePathsOptions(useCaseSensitiveFileNames, currentDirectory)
    return tspath.NewComparePathsOptions(useCaseSensitiveFileNames or false, currentDirectory or "")
end

-- Go append(xs, ys...): like core.AppendAll but keeps a nil xs nil when ys is empty.
function module.appendAll(xs, ys)
    if ys == nil or #ys == 0 then
        return xs
    end
    return core.AppendAll(xs, ys)
end
