local jsnum = require("tslua.jsnum")
local json = require("tslua.json")
local stringutil = require("tslua.stringutil")

local ssub = string.sub

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-tostring
function jsnum.Number_String(n)
    if jsnum.Number_IsNaN(n) then
        return "NaN"
    elseif jsnum.Number_IsInf(n) then
        if n < 0 then
            return "-Infinity"
        end
        return "Infinity"
    end

    -- Fast path: for safe integers, directly convert to string.
    if jsnum.MinSafeInteger <= n and n <= jsnum.MaxSafeInteger then
        local i = math.tointeger(n)
        if i ~= nil then
            return string.format("%d", i)
        end
    end

    -- Otherwise, the Go json package handles this correctly.
    local b = json.formatNumber(n + 0.0)
    return b
end

-- https://tc39.es/ecma262/2024/multipage/abstract-operations.html#sec-stringtonumber
-- Returns a Lua float.
function jsnum.FromString(s)
    -- Implementing StringToNumber exactly as written in the spec involves
    -- writing a parser, along with the conversion of the parsed AST into the
    -- actual value.
    --
    -- The strategy below is to instead break the number apart and fix it up
    -- such that Lua's own parsing functionality can handle it.

    s = jsnum.trimStrWhiteSpace(s)

    if s == "" then
        return 0.0
    elseif s == "Infinity" or s == "+Infinity" then
        return jsnum.Inf(1)
    elseif s == "-Infinity" then
        return jsnum.Inf(-1)
    end

    local pos = 0
    while pos < #s do
        local r, size = stringutil.DecodeRune(s, pos)
        if not jsnum.isNumberRune(r) then
            return jsnum.NaN()
        end
        pos = pos + size
    end

    local n, ok = jsnum.tryParseInt(s)
    if ok then
        return n
    end

    -- Cut this off first so we can ensure -0 is returned as -0.
    local negative = false
    if ssub(s, 1, 1) == "-" then
        s = ssub(s, 2)
        negative = true
    end

    if not negative and ssub(s, 1, 1) == "+" then
        s = ssub(s, 2)
    end

    local first = stringutil.DecodeRune(s, 0)
    if not stringutil.IsDigit(first) and first ~= 0x2E then
        return jsnum.NaN()
    end

    local f = jsnum.parseFloatString(s)
    if f ~= f then
        return jsnum.NaN()
    end

    if negative then
        return -math.abs(f)
    end
    return math.abs(f)
end

-- strings.TrimFunc(s, isStrWhiteSpace)
function jsnum.trimStrWhiteSpace(s)
    local start = 0
    local n = #s
    while start < n do
        local r, size = stringutil.DecodeRune(s, start)
        if not jsnum.isStrWhiteSpace(r) then
            break
        end
        start = start + size
    end
    local end_ = n
    while end_ > start do
        local r, size = stringutil.DecodeLastRune(s, end_)
        if not jsnum.isStrWhiteSpace(r) then
            break
        end
        end_ = end_ - size
    end
    return ssub(s, start + 1, end_)
end

function jsnum.isStrWhiteSpace(r)
    -- This is different than stringutil.IsWhiteSpaceLike.

    -- https://tc39.es/ecma262/2024/multipage/ecmascript-language-lexical-grammar.html#prod-LineTerminator
    -- https://tc39.es/ecma262/2024/multipage/ecmascript-language-lexical-grammar.html#prod-WhiteSpace

    -- LineTerminator
    if r == 0x0A or r == 0x0D or r == 0x2028 or r == 0x2029 then
        return true
    end
    -- WhiteSpace
    if r == 0x09 or r == 0x0B or r == 0x0C or r == 0xFEFF then
        return true
    end

    -- WhiteSpace (unicode.Zs)
    return r == 0x20 or r == 0xA0 or r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x202F or r == 0x205F or r == 0x3000
end

-- Correctly rounded value of the digits of s in a power-of-two base (bitsPerDigit 1, 3 or 4),
-- like strconv.ParseInt followed by float64 conversion, or big.Int.Float64 for large values.
function jsnum.parsePowerOfTwoBase(s, bitsPerDigit)
    local bits = {}
    for i = 1, #s do
        local d = tonumber(ssub(s, i, i), 16)
        for b = bitsPerDigit - 1, 0, -1 do
            bits[#bits + 1] = (d >> b) & 1
        end
    end
    local first = 1
    while first <= #bits and bits[first] == 0 do
        first = first + 1
    end
    local n = #bits - first + 1
    if n <= 0 then
        return 0.0
    end
    if n <= 53 then
        local v = 0
        for i = first, #bits do
            v = (v << 1) | bits[i]
        end
        return v + 0.0
    end
    local mant = 0
    for i = first, first + 52 do
        mant = (mant << 1) | bits[i]
    end
    local roundBit = bits[first + 53]
    local sticky = 0
    for i = first + 54, #bits do
        if bits[i] == 1 then
            sticky = 1
            break
        end
    end
    if roundBit == 1 and (sticky == 1 or (mant & 1) == 1) then
        mant = mant + 1
    end
    return jsnum.mathLdexp(mant + 0.0, n - 53)
end

-- Returns (Number, ok).
function jsnum.tryParseInt(s)
    if #s > 2 then
        local prefix, rest = ssub(s, 1, 2), ssub(s, 3)
        if prefix == "0b" or prefix == "0B" then
            if not jsnum.isAllBinaryDigits(rest) then
                return jsnum.NaN(), true
            end
            return jsnum.parsePowerOfTwoBase(rest, 1), true
        elseif prefix == "0o" or prefix == "0O" then
            if not jsnum.isAllOctalDigits(rest) then
                return jsnum.NaN(), true
            end
            return jsnum.parsePowerOfTwoBase(rest, 3), true
        elseif prefix == "0x" or prefix == "0X" then
            if not jsnum.isAllHexDigits(rest) then
                return jsnum.NaN(), true
            end
            return jsnum.parsePowerOfTwoBase(rest, 4), true
        end
    end

    -- StringToNumber does not parse leading zeros as octal.
    s = jsnum.trimLeadingZeros(s)
    if not jsnum.isAllDigits(s) then
        return 0.0, false
    end
    if s == "" then
        return jsnum.NaN(), true
    end
    -- Decimal digits: tonumber is exact for int64 values and correctly rounded (strtod) beyond.
    return tonumber(s) + 0.0, true
end

function jsnum.parseFloatString(s)
    local hasDot, hasExp = false, false

    -- <a>
    -- <a>.<b>
    -- <a>.<b>e<c>
    -- <a>e<c>
    local a, b, c, rest = "", "", "", ""

    local dot = string.find(s, ".", 1, true)
    if dot ~= nil then
        a, rest, hasDot = ssub(s, 1, dot - 1), ssub(s, dot + 1), true
        -- <a>.<b>
        -- <a>.<b>e<c>
        b, c, hasExp = jsnum.cutAny(rest, "eE")
    else
        -- <a>
        -- <a>e<c>
        a, c, hasExp = jsnum.cutAny(s, "eE")
    end

    local sb = {}

    if a == "" then
        if hasDot and b == "" then
            return jsnum.NaN()
        end
        if hasExp and c == "" then
            return jsnum.NaN()
        end
        sb[#sb + 1] = "0"
    else
        a = jsnum.trimLeadingZeros(a)
        if not jsnum.isAllDigits(a) then
            return jsnum.NaN()
        end
        sb[#sb + 1] = a
    end

    if hasDot then
        sb[#sb + 1] = "."
        if b == "" then
            sb[#sb + 1] = "0"
        else
            b = jsnum.trimTrailingZeros(b)
            if not jsnum.isAllDigits(b) then
                return jsnum.NaN()
            end
            sb[#sb + 1] = b
        end
    end

    if hasExp then
        sb[#sb + 1] = "e"

        local negative = false
        if ssub(c, 1, 1) == "-" then
            c = ssub(c, 2)
            negative = true
        end
        if negative then
            sb[#sb + 1] = "-"
        elseif ssub(c, 1, 1) == "+" then
            c = ssub(c, 2)
        end
        c = jsnum.trimLeadingZeros(c)
        if not jsnum.isAllDigits(c) then
            return jsnum.NaN()
        end
        sb[#sb + 1] = c
    end

    return jsnum.stringToFloat64(table.concat(sb))
end

-- Returns (before, after, found).
function jsnum.cutAny(s, cutset)
    for i = 1, #s do
        if string.find(cutset, ssub(s, i, i), 1, true) then
            return ssub(s, 1, i - 1), ssub(s, i + 1), true
        end
    end
    return s, "", false
end

function jsnum.trimLeadingZeros(s)
    if ssub(s, 1, 1) == "0" then
        s = (string.gsub(s, "^0+", ""))
        if s == "" then
            return "0"
        end
    end
    return s
end

function jsnum.trimTrailingZeros(s)
    if ssub(s, -1) == "0" then
        s = (string.gsub(s, "0+$", ""))
        if s == "" then
            return "0"
        end
    end
    return s
end

-- strconv.ParseFloat: correctly rounded; out-of-range values give ±Inf or 0 like Go.
function jsnum.stringToFloat64(s)
    -- Exponents too large for strtod's int parsing are clamped (the digits are bounded by the
    -- input length, so the result is already 0 or Inf).
    local mant, sign, digits = string.match(s, "^(.-)e(%-?)(%d+)$")
    if mant ~= nil and #digits > 6 then
        s = mant .. "e" .. sign .. "999999"
    end
    local f = tonumber(s)
    if f == nil then
        return jsnum.NaN()
    end
    return f + 0.0
end

function jsnum.isAllDigits(s)
    return not string.find(s, "[^0-9]")
end

function jsnum.isAllBinaryDigits(s)
    return not string.find(s, "[^01]")
end

function jsnum.isAllOctalDigits(s)
    return not string.find(s, "[^0-7]")
end

function jsnum.isAllHexDigits(s)
    return not string.find(s, "[^0-9a-fA-F]")
end

function jsnum.isNumberRune(r)
    if stringutil.IsDigit(r) then
        return true
    end

    if 0x61 <= r and r <= 0x66 then
        return true
    end

    if 0x41 <= r and r <= 0x46 then
        return true
    end

    return r == 0x2E or r == 0x2D or r == 0x2B or r == 0x78 or r == 0x58 or r == 0x6F or r == 0x4F
end
