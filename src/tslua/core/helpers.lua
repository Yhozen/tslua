-- Lua-only helpers used by ported code (no Go counterpart file). See docs/PORTING.md.
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")

local schar = string.char

-- Go len(xs) for a possibly-nil slice (or string).
function core.Len(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

-- Go append(xs, values...) for a possibly-nil slice. Mutates and returns xs (or a new array).
function core.Append(xs, ...)
    if xs == nil then
        xs = {}
    end
    local n = #xs
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        n = n + 1
        xs[n] = v
    end
    return xs
end

-- Go append(xs, ys...). Mutates and returns xs (or a new array when xs is nil).
function core.AppendAll(xs, ys)
    if xs == nil then
        xs = {}
    end
    if ys ~= nil then
        local n = #xs
        for i = 1, #ys do
            xs[n + i] = ys[i]
        end
    end
    return xs
end

-- Go xs[a:b] (0-based, half-open). Returns a new array. b defaults to len(xs).
function core.Slice(xs, a, b)
    local result = {}
    if xs == nil then
        return result
    end
    a = a or 0
    b = b or #xs
    local n = 0
    for i = a + 1, b do
        n = n + 1
        result[n] = xs[i]
    end
    return result
end

-- Go integer division (truncates toward zero).
function core.IntDiv(a, b)
    local q = a // b
    if q < 0 and q * b ~= a then
        q = q + 1
    end
    return q
end

-- Go integer remainder (sign follows the dividend).
function core.IntMod(a, b)
    return a - core.IntDiv(a, b) * b
end

core.RuneError = 0xFFFD
core.RuneSelf = 0x80
core.MaxRune = 0x10FFFF
core.UTFMax = 4

-- UTF-8 primitives live in tslua.stringutil (a leaf package, so tspath can use them too).
-- core.DecodeRune(s, pos) -> rune, size: Go utf8.DecodeRuneInString(s[pos:]) (pos 0-based,
-- default 0; empty -> RuneError, 0; invalid -> RuneError, 1).
core.DecodeRune = stringutil.DecodeRune
-- core.DecodeLastRune(s, end_) -> rune, size: Go utf8.DecodeLastRuneInString(s[:end_]).
core.DecodeLastRune = stringutil.DecodeLastRune
-- core.EncodeRune(r) -> string: Go string(r) (invalid code points -> U+FFFD).
core.EncodeRune = stringutil.EncodeRune
-- core.RuneLen(r): Go utf8.RuneLen.
core.RuneLen = stringutil.RuneLen

-- Go `for i, r := range s` -> `for i, r in core.Runes(s) do` (i is a 0-based byte offset,
-- invalid bytes yield RuneError with width 1).
function core.Runes(s)
    local pos = 0
    local n = #s
    return function()
        if pos >= n then
            return nil
        end
        local r, size = core.DecodeRune(s, pos)
        local i = pos
        pos = pos + size
        return i, r
    end
end

-- Go []rune(s).
function core.StringToRunes(s)
    local result = {}
    local pos = 0
    local n = #s
    local k = 0
    while pos < n do
        local r, size = core.DecodeRune(s, pos)
        k = k + 1
        result[k] = r
        pos = pos + size
    end
    return result
end

-- Go string(runes).
function core.RunesToString(runes)
    local parts = {}
    for i = 1, #runes do
        parts[i] = core.EncodeRune(runes[i])
    end
    return table.concat(parts)
end

-- Go utf8.RuneCountInString.
function core.RuneCount(s)
    local count = 0
    local pos = 0
    local n = #s
    while pos < n do
        local _, size = core.DecodeRune(s, pos)
        pos = pos + size
        count = count + 1
    end
    return count
end

-- strings.Builder
local StringBuilder = {}
StringBuilder.__index = StringBuilder
core.StringBuilder = StringBuilder

function core.NewStringBuilder()
    return setmetatable({ buf = {}, n = 0, len = 0 }, StringBuilder)
end

setmetatable(StringBuilder, {
    __call = function()
        return core.NewStringBuilder()
    end,
})

function StringBuilder:WriteString(s)
    local n = self.n + 1
    self.n = n
    self.buf[n] = s
    self.len = self.len + #s
    return #s
end

function StringBuilder:WriteByte(b)
    local n = self.n + 1
    self.n = n
    self.buf[n] = schar(b)
    self.len = self.len + 1
end

function StringBuilder:WriteRune(r)
    local s = core.EncodeRune(r)
    local n = self.n + 1
    self.n = n
    self.buf[n] = s
    self.len = self.len + #s
    return #s
end

function StringBuilder:String()
    if self.n > 1 then
        local s = table.concat(self.buf, "", 1, self.n)
        self.buf = { s }
        self.n = 1
        return s
    elseif self.n == 1 then
        return self.buf[1]
    end
    return ""
end

function StringBuilder:Len()
    return self.len
end

function StringBuilder:Grow(n)
end

function StringBuilder:Reset()
    self.buf = {}
    self.n = 0
    self.len = 0
end

-- iter.Seq parameters are plain arrays; this turns a Lua iterator (as returned by ported
-- iter.Seq functions) into an array, like Go slices.Collect.
function core.Collect(iterator, state, control)
    local result = {}
    local n = 0
    if iterator == nil then
        return result
    end
    for v in iterator, state, control do
        n = n + 1
        result[n] = v
    end
    return result
end

-- A Lua iterator over the values of an array (Go slices.Values).
function core.Values(xs)
    local i = 0
    return function()
        if xs == nil then
            return nil
        end
        i = i + 1
        return xs[i]
    end
end

-- Generic Go zero-value test (nil, false, 0, "").
function core.IsZero(v)
    return v == nil or v == false or v == 0 or v == ""
end

-- The Go zero value of the type of v as far as it can be told from a Lua value: "" for strings,
-- 0 for numbers, false for booleans, nil otherwise. Generic helpers (core.Find, ...) use it so
-- that a "not found" result over a slice of strings is "" like in Go. Over an empty or nil slice
-- the element type is unknown and nil is returned.
function core.zeroLike(v)
    local tv = type(v)
    if tv == "string" then
        return ""
    elseif tv == "number" then
        return 0
    elseif tv == "boolean" then
        return false
    end
    return nil
end

-- Go slices.SortStableFunc(xs, cmp): stable in-place sort, cmp(a, b) returns an int.
function core.SortStableFunc(xs, cmp)
    local n = core.Len(xs)
    if n < 2 then
        return
    end
    -- insertion sort for short runs, then bottom-up merges
    local run = 12
    for lo = 1, n, run do
        local hi = math.min(lo + run - 1, n)
        for i = lo + 1, hi do
            local v = xs[i]
            local j = i - 1
            while j >= lo and cmp(xs[j], v) > 0 do
                xs[j + 1] = xs[j]
                j = j - 1
            end
            xs[j + 1] = v
        end
    end
    local width = run
    local tmp = {}
    while width < n do
        for lo = 1, n, 2 * width do
            local mid = lo + width - 1
            if mid < n then
                local hi = math.min(lo + 2 * width - 1, n)
                for k = lo, mid do
                    tmp[k] = xs[k]
                end
                local i, j, k = lo, mid + 1, lo
                while i <= mid and j <= hi do
                    if cmp(xs[j], tmp[i]) < 0 then
                        xs[k] = xs[j]
                        j = j + 1
                    else
                        xs[k] = tmp[i]
                        i = i + 1
                    end
                    k = k + 1
                end
                while i <= mid do
                    xs[k] = tmp[i]
                    i = i + 1
                    k = k + 1
                end
            end
        end
        width = width * 2
    end
end

-- Go slices.SortFunc. Go's pdqsort is not stable; this port sorts stably, which yields the same
-- result whenever cmp is a total order without ties (the deterministic cases).
function core.SortFunc(xs, cmp)
    core.SortStableFunc(xs, cmp)
end

-- Go slices.Sort for strings/numbers.
function core.Sort(xs)
    core.SortStableFunc(xs, function(a, b)
        if a < b then
            return -1
        elseif a > b then
            return 1
        end
        return 0
    end)
end
