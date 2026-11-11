-- Package jsnum provides JS-like number handling.
--
-- A jsnum.Number is a plain Lua float (Go `type Number float64`). Methods on Number are package
-- functions jsnum.Number_<Method>(n, ...). The generated constants live in jsnum.Number
-- (jsnum.Number.MaxSafeInteger); jsnum.MaxSafeInteger / jsnum.MinSafeInteger are aliases.
local jsnum = require("tslua.jsnum")

local spack, sunpack = string.pack, string.unpack

jsnum.MaxSafeInteger = jsnum.Number.MaxSafeInteger
jsnum.MinSafeInteger = jsnum.Number.MinSafeInteger

local function float64bits(x)
    return (sunpack("<i8", spack("<d", x)))
end

local function float64frombits(b)
    return (sunpack("<d", spack("<i8", b)))
end

jsnum.float64bits = float64bits
jsnum.float64frombits = float64frombits

function jsnum.NaN()
    return float64frombits(0x7FF8000000000001)
end

function jsnum.Number_IsNaN(n)
    return n ~= n
end

function jsnum.Inf(sign)
    if sign >= 0 then
        return math.huge
    end
    return -math.huge
end

function jsnum.Number_IsInf(n)
    return n == math.huge or n == -math.huge
end

function jsnum.isNonFinite(x)
    -- This is equivalent to checking `math.IsNaN(x) || math.IsInf(x, 0)` in one operation.
    local mask = 0x7FF0000000000000
    return float64bits(x + 0.0) & mask == mask
end

-- https://tc39.es/ecma262/2024/multipage/abstract-operations.html#sec-touint32
-- Returns a Lua integer in [0, 2^32).
function jsnum.Number_toUint32(x)
    -- The only difference between ToUint32 and ToInt32 is the interpretation of the bits.
    return jsnum.Number_toInt32(x) & 0xFFFFFFFF
end

local function wrapInt32(v)
    v = v & 0xFFFFFFFF
    if v >= 0x80000000 then
        v = v - 0x100000000
    end
    return v
end

-- https://tc39.es/ecma262/2024/multipage/abstract-operations.html#sec-toint32
-- Returns a Lua integer in [-2^31, 2^31).
function jsnum.Number_toInt32(n)
    local x = n + 0.0

    -- Fast path: if the number is in the range (-2^31, 2^31) and integral, i.e. an SMI,
    -- then we don't need to do any special mapping.
    if x >= -2147483648.0 and x < 2147483648.0 then
        local smi = math.tointeger(x)
        if smi ~= nil then
            return smi
        end
    end

    -- 2. If number is not finite or number is either +0𝔽 or -0𝔽, return +0𝔽.
    -- Zero was covered by the test above.
    if jsnum.isNonFinite(x) then
        return 0
    end

    -- Let int be truncate(ℝ(number)).
    if x >= 0 then
        x = math.floor(x) + 0.0
    else
        x = math.ceil(x) + 0.0
    end
    -- Let int32bit be int modulo 2**32.
    x = math.fmod(x, 4294967296.0)
    -- If int32bit ≥ 2**31, return 𝔽(int32bit - 2**32); otherwise return 𝔽(int32bit).
    return wrapInt32(math.tointeger(x))
end

function jsnum.Number_toShiftCount(x)
    return jsnum.Number_toUint32(x) & 31
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-signedRightShift
function jsnum.Number_SignedRightShift(x, y)
    -- arithmetic shift of an int32
    local v = jsnum.Number_toInt32(x)
    local s = jsnum.Number_toShiftCount(y)
    return (v // (1 << s)) + 0.0
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-unsignedRightShift
function jsnum.Number_UnsignedRightShift(x, y)
    return (jsnum.Number_toUint32(x) >> jsnum.Number_toShiftCount(y)) + 0.0
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-leftShift
function jsnum.Number_LeftShift(x, y)
    return wrapInt32(jsnum.Number_toInt32(x) << jsnum.Number_toShiftCount(y)) + 0.0
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-bitwiseNOT
function jsnum.Number_BitwiseNOT(x)
    return wrapInt32(~jsnum.Number_toInt32(x)) + 0.0
end

-- The below are implemented by https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numberbitwiseop.

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-bitwiseOR
function jsnum.Number_BitwiseOR(x, y)
    return wrapInt32(jsnum.Number_toInt32(x) | jsnum.Number_toInt32(y)) + 0.0
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-bitwiseAND
function jsnum.Number_BitwiseAND(x, y)
    return wrapInt32(jsnum.Number_toInt32(x) & jsnum.Number_toInt32(y)) + 0.0
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-bitwiseXOR
function jsnum.Number_BitwiseXOR(x, y)
    return wrapInt32(jsnum.Number_toInt32(x) ~ jsnum.Number_toInt32(y)) + 0.0
end

-- Go math.Trunc
function jsnum.mathTrunc(x)
    x = x + 0.0
    if x ~= x or x == math.huge or x == -math.huge or x == 0 then
        return x
    end
    local r
    if x > 0 then
        r = math.floor(x) + 0.0
    else
        r = math.ceil(x) + 0.0
        if r == 0 then
            r = -0.0
        end
    end
    return r
end

function jsnum.Number_trunc(x)
    return jsnum.mathTrunc(x)
end

function jsnum.Number_Floor(x)
    x = x + 0.0
    if x ~= x or x == math.huge or x == -math.huge or x == 0 then
        return x
    end
    return math.floor(x) + 0.0
end

function jsnum.Number_Abs(x)
    return float64frombits(float64bits(x + 0.0) & 0x7FFFFFFFFFFFFFFF)
end

jsnum.negativeZero = -0.0

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-remainder
function jsnum.Number_Remainder(n, d)
    if jsnum.Number_IsNaN(n) or jsnum.Number_IsNaN(d) then
        return jsnum.NaN()
    elseif jsnum.Number_IsInf(n) then
        return jsnum.NaN()
    elseif jsnum.Number_IsInf(d) then
        return n
    elseif d == 0 then
        return jsnum.NaN()
    elseif n == 0 then
        return n
    end
    return math.fmod(n + 0.0, d + 0.0)
end

---- Go math helpers needed by Exponentiate (ports of math.Frexp, math.Ldexp, math.Log2, math.Pow).

local shift = 64 - 11 - 1
local mask = 0x7FF
local bias = 1023
local SmallestNormal = 2.2250738585072014e-308 -- 2**-1022

-- normalize returns a normal number y and exponent exp satisfying x == y × 2**exp.
local function normalize(x)
    if math.abs(x) < SmallestNormal then
        return x * (1 << 52), -52
    end
    return x, 0
end

function jsnum.mathFrexp(f)
    if f == 0 or f ~= f or f == math.huge or f == -math.huge then
        return f, 0
    end
    local exp
    f, exp = normalize(f)
    local x = float64bits(f)
    exp = exp + ((x >> shift) & mask) - bias + 1
    x = x & ~(mask << shift)
    x = x | ((-1 + bias) << shift)
    return float64frombits(x), exp
end

function jsnum.mathLdexp(frac, exp)
    if frac == 0 then
        return frac -- correctly return -0
    elseif frac ~= frac or frac == math.huge or frac == -math.huge then
        return frac
    end
    local e
    frac, e = normalize(frac)
    exp = exp + e
    local x = float64bits(frac)
    exp = exp + ((x >> shift) & mask) - bias
    if exp < -1075 then
        if frac < 0 then
            return -0.0
        end
        return 0.0 -- underflow
    end
    if exp > 1023 then -- overflow
        if frac < 0 then
            return -math.huge
        end
        return math.huge
    end
    local m = 1.0
    if exp < -1022 then -- denormal
        exp = exp + 53
        m = 1.0 / (1 << 53) -- 2**-53
    end
    x = x & ~(mask << shift)
    x = x | ((exp + bias) << shift)
    return m * float64frombits(x)
end

function jsnum.mathLog2(x)
    local frac, exp = jsnum.mathFrexp(x)
    -- Make sure exact powers of two give an exact answer.
    -- Don't depend on Log(0.5)*(1/Ln2)+exp being exactly exp-1.
    if frac == 0.5 then
        return exp - 1 + 0.0
    end
    return math.log(frac) * 1.44269504088896340735992468100189214 + exp -- (1/Ln2)
end

local function isOddInt(x)
    if math.abs(x) >= (1 << 53) then
        -- 1 << 53 is the largest exact integer in the float64 format.
        -- Any number outside this range will be truncated before the decimal point and therefore will always be
        -- an even integer.
        -- Without this check and if x overflows int64 the int64(xi) conversion below may produce incorrect results
        -- on some architectures (and does so on arm64). See issue #57465.
        return false
    end
    local xi = math.floor(math.abs(x))
    local xf = math.abs(x) - xi
    return xf == 0 and (math.tointeger(xi) & 1) == 1
end

local function signbit(x)
    return float64bits(x) < 0
end

-- Port of Go's math.Pow (pure Go on amd64). Exp/Log of the fractional part use the C library.
function jsnum.mathPow(x, y)
    x, y = x + 0.0, y + 0.0
    if y == 0 or x == 1 then
        return 1.0
    elseif y == 1 then
        return x
    elseif x ~= x or y ~= y then
        return jsnum.NaN()
    elseif x == 0 then
        if y < 0 then
            if signbit(x) and isOddInt(y) then
                return -math.huge
            end
            return math.huge
        elseif y > 0 then
            if signbit(x) and isOddInt(y) then
                return x
            end
            return 0.0
        end
    elseif y == math.huge or y == -math.huge then
        if x == -1 then
            return 1.0
        elseif (math.abs(x) < 1) == (y == math.huge) then
            return 0.0
        else
            return math.huge
        end
    elseif x == math.huge or x == -math.huge then
        if x == -math.huge then
            return jsnum.mathPow(1 / x, -y) -- Pow(-0, -y)
        end
        if y < 0 then
            return 0.0
        elseif y > 0 then
            return math.huge
        end
    elseif y == 0.5 then
        return math.sqrt(x)
    elseif y == -0.5 then
        return 1 / math.sqrt(x)
    end

    local ay = math.abs(y)
    local yi = math.floor(ay) + 0.0
    local yf = ay - yi
    if yf ~= 0 and x < 0 then
        return jsnum.NaN()
    end
    if yi >= 9223372036854775808.0 then
        -- yi is a large even int that will lead to overflow (or underflow to 0)
        -- for all x except -1 (x == 1 was handled earlier)
        if x == -1 then
            return 1.0
        elseif (math.abs(x) < 1) == (y > 0) then
            return 0.0
        else
            return math.huge
        end
    end

    -- ans = a1 * 2**ae (= 1 for now).
    local a1 = 1.0
    local ae = 0

    -- ans *= x**yf
    if yf ~= 0 then
        if yf > 0.5 then
            yf = yf - 1
            yi = yi + 1
        end
        a1 = math.exp(yf * math.log(x))
    end

    -- ans *= x**yi
    -- by multiplying in successive squarings
    -- of x according to bits of yi.
    -- accumulate powers of two into exp.
    local x1, xe = jsnum.mathFrexp(x)
    local i = math.tointeger(yi)
    while i ~= 0 do
        if xe < -(1 << 12) or (1 << 12) < xe then
            -- catch xe before it overflows the left shift below
            ae = ae + xe
            break
        end
        if i & 1 == 1 then
            a1 = a1 * x1
            ae = ae + xe
        end
        x1 = x1 * x1
        xe = xe << 1
        if x1 < .5 then
            x1 = x1 + x1
            xe = xe - 1
        end
        i = i >> 1
    end

    -- ans = a1*2**ae
    -- if y < 0 { ans = 1 / ans }
    -- but in the opposite order
    if y < 0 then
        a1 = 1 / a1
        ae = -ae
    end
    return jsnum.mathLdexp(a1, ae)
end

---- Exact big integers (little-endian arrays of base 2^24 limbs) for Exponentiate.

local LIMB_BITS = 24
local LIMB = 1 << LIMB_BITS

local function bigFromInt(v)
    local r = {}
    while v > 0 do
        r[#r + 1] = v % LIMB
        v = v // LIMB
    end
    return r
end

local function bigMul(a, b)
    local r = {}
    for i = 1, #a + #b do
        r[i] = 0
    end
    for i = 1, #a do
        local carry = 0
        local ai = a[i]
        for j = 1, #b do
            local t = r[i + j - 1] + ai * b[j] + carry
            r[i + j - 1] = t % LIMB
            carry = t // LIMB
        end
        local k = i + #b
        while carry > 0 do
            local t = r[k] + carry
            r[k] = t % LIMB
            carry = t // LIMB
            k = k + 1
        end
    end
    while #r > 0 and r[#r] == 0 do
        r[#r] = nil
    end
    return r
end

local function bigBitLen(a)
    if #a == 0 then
        return 0
    end
    local top = a[#a]
    local n = 0
    while top > 0 do
        n = n + 1
        top = top >> 1
    end
    return (#a - 1) * LIMB_BITS + n
end

local function bigBit(a, i) -- bit i (0-based)
    local limb = a[i // LIMB_BITS + 1]
    if limb == nil then
        return 0
    end
    return (limb >> (i % LIMB_BITS)) & 1
end

-- Rounds a non-negative big integer to the nearest float64 (ties to even), like big.Float.Float64.
function jsnum.bigToFloat(a)
    local n = bigBitLen(a)
    if n == 0 then
        return 0.0
    end
    if n <= 53 then
        local v = 0
        for i = #a, 1, -1 do
            v = v * LIMB + a[i]
        end
        return v + 0.0
    end
    local mant = 0
    for i = n - 1, n - 53, -1 do
        mant = (mant << 1) | bigBit(a, i)
    end
    local roundBit = bigBit(a, n - 54)
    local sticky = 0
    for i = n - 55, 0, -1 do
        if bigBit(a, i) == 1 then
            sticky = 1
            break
        end
    end
    if roundBit == 1 and (sticky == 1 or (mant & 1) == 1) then
        mant = mant + 1
    end
    return jsnum.mathLdexp(mant + 0.0, n - 53)
end

-- https://tc39.es/ecma262/2024/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-exponentiate
function jsnum.Number_Exponentiate(base, exponent)
    if (base == 1 or base == -1) and jsnum.Number_IsInf(exponent) then
        return jsnum.NaN()
    elseif base == 1 and jsnum.Number_IsNaN(exponent) then
        return jsnum.NaN()
    end

    local b = base + 0.0
    local e = exponent + 0.0

    -- For integer base ** integer exponent where the result exceeds 53 bits,
    -- math.Pow can be off by multiple ULPs vs JS engines. Use exact big.Int
    -- arithmetic and IEEE 754 round-to-nearest-even conversion instead.
    -- The ES spec (§6.1.6.1.3) says exponentiate returns an
    -- "implementation-approximated" value, so engines are allowed to differ.
    -- This won't exactly match every engine (V8's fdlibm-compiled pow can
    -- round halfway ties differently), but will always be within 1 ULP
    -- (unit in the last place, i.e. the least significant bit of the result).
    local maxInt64 = 9223372036854775807.0
    if b >= -9223372036854775808.0 and b <= maxInt64 and b == jsnum.mathTrunc(b) and
        e >= 0 and e <= maxInt64 and e == jsnum.mathTrunc(e) and not jsnum.Number_IsInf(e) then
        local magnitude = e * jsnum.mathLog2(math.abs(b))
        if magnitude > 53 and magnitude <= jsnum.mathLog2(1.79769313486231570814527423731704356798070e+308) then
            local bi
            if b >= maxInt64 then
                bi = math.mininteger -- Go's int64(2**63) on amd64
            else
                bi = math.tointeger(b)
            end
            local negative = bi < 0
            local absB
            if bi == math.mininteger then
                absB = { 0, 0, 1 << 15 } -- 2**63
            else
                absB = bigFromInt(negative and -bi or bi)
            end
            local ei = math.tointeger(e)
            local result = { 1 }
            local p = absB
            while ei > 0 do
                if ei & 1 == 1 then
                    result = bigMul(result, p)
                end
                ei = ei >> 1
                if ei > 0 then
                    p = bigMul(p, p)
                end
            end
            local f = jsnum.bigToFloat(result)
            if negative and (math.tointeger(e) & 1) == 1 then
                f = -f
            end
            return f
        end
    end

    return jsnum.mathPow(b, e)
end
