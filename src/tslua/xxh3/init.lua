-- Port of github.com/zeebo/xxh3 (v1.1.0), the subset used by typescript-go: HashString128 /
-- Hash128 and Uint128.Bytes. Only the scalar accumulator is ported (the SIMD variants compute the
-- same values). Lua 5.4 integers are 64-bit two's complement with wrapping arithmetic, which
-- matches Go uint64 for +, -, *, ~, &, |, ~ (xor), << and >> (logical); unsigned comparisons are
-- not needed because only lengths are compared.
local xxh3 = {}
package.loaded["tslua.xxh3"] = xxh3

local sunpack = string.unpack

local stripe = 64
local block = 1024

local prime32_1 = 0x9E3779B1
local prime32_2 = 0x85EBCA77
local prime32_3 = 0xC2B2AE3D

local prime64_1 = 0x9E3779B185EBCA87
local prime64_2 = 0xC2B2AE3D27D4EB4F
local prime64_3 = 0x165667B19E3779F9
local prime64_4 = 0x85EBCA77C2B2AE63
local prime64_5 = 0x27D4EB2F165667C5

local key = string.char(
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e
)

-- Little-endian reads at 0-based offset o.
local function readU8(s, o)
    return string.byte(s, o + 1)
end

local function readU16(s, o)
    return (sunpack("<I2", s, o + 1))
end

local function readU32(s, o)
    return (sunpack("<I4", s, o + 1))
end

local function readU64(s, o)
    return (sunpack("<i8", s, o + 1))
end

local key64_000 = readU64(key, 0)
local key64_008 = readU64(key, 8)
local key64_016 = readU64(key, 16)
local key64_024 = readU64(key, 24)
local key64_032 = readU64(key, 32)
local key64_040 = readU64(key, 40)
local key64_048 = readU64(key, 48)
local key64_056 = readU64(key, 56)
local key64_064 = readU64(key, 64)
local key64_072 = readU64(key, 72)
local key64_080 = readU64(key, 80)
local key64_088 = readU64(key, 88)
local key64_096 = readU64(key, 96)
local key64_104 = readU64(key, 104)
local key64_112 = readU64(key, 112)
local key64_120 = readU64(key, 120)

local key64_103 = readU64(key, 103)
local key64_111 = readU64(key, 111)
local key64_119 = readU64(key, 119)
local key64_127 = readU64(key, 127)

local key32_000 = 0xbe4ba423
local key32_004 = 0x396cfeb8
local key32_008 = 0x1cad21f7
local key32_012 = 0x2c81017c

-- bits.Mul64: full 128-bit product of two uint64 values, returns hi, lo.
local function mul64(x, y)
    local x0, x1 = x & 0xffffffff, x >> 32
    local y0, y1 = y & 0xffffffff, y >> 32
    local w0 = x0 * y0
    local t = x1 * y0 + (w0 >> 32)
    local w1 = t & 0xffffffff
    local w2 = t >> 32
    w1 = w1 + x0 * y1
    local hi = x1 * y1 + w2 + (w1 >> 32)
    local lo = x * y
    return hi, lo
end

local function mulFold64(x, y)
    local hi, lo = mul64(x, y)
    return hi ~ lo
end

local function reverseBytes64(x)
    return (sunpack(">i8", string.pack("<i8", x)))
end

local function reverseBytes32(x)
    return (sunpack(">I4", string.pack("<I4", x & 0xffffffff)))
end

local function rotateLeft32(x, k)
    x = x & 0xffffffff
    return ((x << k) | (x >> (32 - k))) & 0xffffffff
end

local function xxh64AvalancheSmall(x)
    x = x * prime64_2
    x = x ~ (x >> 29)
    x = x * prime64_3
    x = x ~ (x >> 32)
    return x
end

local function xxh3Avalanche(x)
    x = x ~ (x >> 37)
    x = x * 0x165667919e3779f9
    x = x ~ (x >> 32)
    return x
end

local function accumStripe(accs, p, po, k, ko)
    for off = 0, 6, 2 do
        local dv0 = readU64(p, po + 8 * off)
        local dk0 = dv0 ~ readU64(k, ko + 8 * off)
        local ac1 = dv0
        local ac0 = (dk0 & 0xffffffff) * (dk0 >> 32)

        local dv1 = readU64(p, po + 8 * off + 8)
        local dk1 = dv1 ~ readU64(k, ko + 8 * off + 8)
        ac0 = ac0 + dv1
        ac1 = ac1 + (dk1 & 0xffffffff) * (dk1 >> 32)

        accs[off + 1] = accs[off + 1] + ac0
        accs[off + 2] = accs[off + 2] + ac1
    end
end

-- accumScalar with the default secret. p is the input string, l its length.
local function accumScalar(accs, p, l)
    local po = 0
    while l > block do
        local ko = 0

        -- accs
        for _ = 0, 15 do
            accumStripe(accs, p, po, key, ko)
            l = l - stripe
            if l > 0 then
                po, ko = po + stripe, ko + 8
            end
        end

        -- scramble accs
        for i = 0, 7 do
            local a = accs[i + 1]
            a = a ~ (a >> 47)
            a = a ~ readU64(key, 128 + 8 * i)
            a = a * prime32_1
            accs[i + 1] = a
        end
    end

    if l > 0 then
        local t, ko = (l - 1) // stripe, 0

        for _ = 1, t do
            accumStripe(accs, p, po, key, ko)
            l = l - stripe
            if l > 0 then
                po, ko = po + stripe, ko + 8
            end
        end

        if l > 0 then
            po = po - (stripe - l)

            for i = 0, 7 do
                local dv = readU64(p, po + 8 * i)
                local dk = dv ~ readU64(key, 121 + 8 * i)
                -- even lanes add to the odd accumulator and vice versa
                local other = (i ~ 1) + 1
                accs[other] = accs[other] + dv
                accs[i + 1] = accs[i + 1] + (dk & 0xffffffff) * (dk >> 32)
            end
        end
    end
end

-- Uint128 is a 128 bit value { hi = uint64, lo = uint64 }.
local Uint128 = {}
Uint128.__index = Uint128
xxh3.Uint128 = Uint128

function xxh3.NewUint128(hi, lo)
    return setmetatable({ hi = hi, lo = lo }, Uint128)
end

-- Bytes returns the uint128 as a 16-byte string in canonical form (big-endian encoded).
function Uint128:Bytes()
    return string.pack(">i8>i8", self.hi, self.lo)
end

-- Hex returns hex.EncodeToString(u.Bytes()).
function Uint128:Hex()
    return string.format("%016x%016x", self.hi, self.lo)
end

function xxh3.hashAny128(p)
    local l = #p
    local hi, lo = 0, 0

    if l <= 16 then
        if l > 8 then -- 9-16
            local bitflipl = key64_032 ~ key64_040
            local bitfliph = key64_048 ~ key64_056

            local input_lo = readU64(p, 0)
            local input_hi = readU64(p, l - 8)

            local m128_h, m128_l = mul64(input_lo ~ input_hi ~ bitflipl, prime64_1)

            m128_l = m128_l + ((l - 1) << 54)
            input_hi = input_hi ~ bitfliph

            m128_h = m128_h + input_hi + (input_hi & 0xffffffff) * (prime32_2 - 1)

            m128_l = m128_l ~ reverseBytes64(m128_h)

            hi, lo = mul64(m128_l, prime64_2)
            hi = hi + m128_h * prime64_2

            lo = xxh3Avalanche(lo)
            hi = xxh3Avalanche(hi)

            return xxh3.NewUint128(hi, lo)
        elseif l > 3 then -- 4-8
            local bitflip = key64_016 ~ key64_024

            local input_lo = readU32(p, 0)
            local input_hi = readU32(p, l - 4)
            local input_64 = input_lo + (input_hi << 32)
            local keyed = input_64 ~ bitflip

            hi, lo = mul64(keyed, prime64_1 + (l << 2))

            hi = hi + (lo << 1)
            lo = lo ~ (hi >> 3)

            lo = lo ~ (lo >> 35)
            lo = lo * 0x9fb21c651e98df25
            lo = lo ~ (lo >> 28)
            hi = xxh3Avalanche(hi)

            return xxh3.NewUint128(hi, lo)
        elseif l == 3 then -- 3
            local c12 = readU16(p, 0)
            local c3 = readU8(p, 2)
            lo = (c12 << 16) + c3 + (3 << 8)
        elseif l > 1 then -- 2
            local c12 = readU16(p, 0)
            lo = ((c12 * ((1 << 24) + 1)) >> 8) + (2 << 8)
        elseif l == 1 then -- 1
            local c1 = readU8(p, 0)
            lo = c1 * ((1 << 24) + (1 << 16) + 1) + (1 << 8)
        else -- 0
            return xxh3.NewUint128(0x99aa06d3014798d8, 0x6001c324468d497f)
        end

        hi = rotateLeft32(reverseBytes32(lo), 13)
        lo = lo ~ (key32_000 ~ key32_004)
        hi = hi ~ (key32_008 ~ key32_012)

        lo = xxh64AvalancheSmall(lo)
        hi = xxh64AvalancheSmall(hi)

        return xxh3.NewUint128(hi, lo)
    elseif l <= 128 then
        lo = l * prime64_1

        if l > 32 then
            if l > 64 then
                if l > 96 then
                    local in8, in7 = readU64(p, l - 8 * 8), readU64(p, l - 7 * 8)
                    local i6, i7 = readU64(p, 6 * 8), readU64(p, 7 * 8)

                    hi = hi + mulFold64(in8 ~ key64_112, in7 ~ key64_120)
                    hi = hi ~ (i6 + i7)
                    lo = lo + mulFold64(i6 ~ key64_096, i7 ~ key64_104)
                    lo = lo ~ (in8 + in7)
                end -- 96

                local in6, in5 = readU64(p, l - 6 * 8), readU64(p, l - 5 * 8)
                local i4, i5 = readU64(p, 4 * 8), readU64(p, 5 * 8)

                hi = hi + mulFold64(in6 ~ key64_080, in5 ~ key64_088)
                hi = hi ~ (i4 + i5)
                lo = lo + mulFold64(i4 ~ key64_064, i5 ~ key64_072)
                lo = lo ~ (in6 + in5)
            end -- 64

            local in4, in3 = readU64(p, l - 4 * 8), readU64(p, l - 3 * 8)
            local i2, i3 = readU64(p, 2 * 8), readU64(p, 3 * 8)

            hi = hi + mulFold64(in4 ~ key64_048, in3 ~ key64_056)
            hi = hi ~ (i2 + i3)
            lo = lo + mulFold64(i2 ~ key64_032, i3 ~ key64_040)
            lo = lo ~ (in4 + in3)
        end -- 32

        local in2, in1 = readU64(p, l - 2 * 8), readU64(p, l - 1 * 8)
        local i0, i1 = readU64(p, 0 * 8), readU64(p, 1 * 8)

        hi = hi + mulFold64(in2 ~ key64_016, in1 ~ key64_024)
        hi = hi ~ (i0 + i1)
        lo = lo + mulFold64(i0 ~ key64_000, i1 ~ key64_008)
        lo = lo ~ (in2 + in1)

        hi, lo = (lo * prime64_1) + (hi * prime64_4) + (l * prime64_2), hi + lo

        hi = -xxh3Avalanche(hi)
        lo = xxh3Avalanche(lo)

        return xxh3.NewUint128(hi, lo)
    elseif l <= 240 then
        lo = l * prime64_1

        local function group(base, k0, k1, k2, k3)
            local i0, i1, i2, i3 = readU64(p, base), readU64(p, base + 8), readU64(p, base + 16), readU64(p, base + 24)

            hi = hi + mulFold64(i2 ~ k2, i3 ~ k3)
            hi = hi ~ (i0 + i1)
            lo = lo + mulFold64(i0 ~ k0, i1 ~ k1)
            lo = lo ~ (i2 + i3)
        end

        group(0 * 8, key64_000, key64_008, key64_016, key64_024)
        group(4 * 8, key64_032, key64_040, key64_048, key64_056)
        group(8 * 8, key64_064, key64_072, key64_080, key64_088)
        group(12 * 8, key64_096, key64_104, key64_112, key64_120)

        -- avalanche
        hi = xxh3Avalanche(hi)
        lo = xxh3Avalanche(lo)

        -- trailing groups after 128
        local top = l & ~31
        for i = 4 * 32, top - 1, 32 do
            group(i, readU64(key, i - 125), readU64(key, i - 117), readU64(key, i - 109), readU64(key, i - 101))
        end

        -- last 32 bytes
        do
            local i0, i1, i2, i3 = readU64(p, l - 32), readU64(p, l - 24), readU64(p, l - 16), readU64(p, l - 8)

            hi = hi + mulFold64(i0 ~ key64_119, i1 ~ key64_127)
            hi = hi ~ (i2 + i3)
            lo = lo + mulFold64(i2 ~ key64_103, i3 ~ key64_111)
            lo = lo ~ (i0 + i1)
        end

        hi, lo = (lo * prime64_1) + (hi * prime64_4) + (l * prime64_2), hi + lo

        hi = -xxh3Avalanche(hi)
        lo = xxh3Avalanche(lo)

        return xxh3.NewUint128(hi, lo)
    end

    lo = l * prime64_1
    hi = ~(l * prime64_2)

    local accs = {
        prime32_3, prime64_1, prime64_2, prime64_3,
        prime64_4, prime32_2, prime64_5, prime32_1,
    }

    accumScalar(accs, p, l)

    -- merge accs
    for i = 0, 3 do
        local a0, a1 = accs[2 * i + 1], accs[2 * i + 2]
        lo = lo + mulFold64(a0 ~ readU64(key, 11 + 16 * i), a1 ~ readU64(key, 19 + 16 * i))
        hi = hi + mulFold64(a0 ~ readU64(key, 117 + 16 * i), a1 ~ readU64(key, 125 + 16 * i))
    end

    lo = xxh3Avalanche(lo)
    hi = xxh3Avalanche(hi)

    return xxh3.NewUint128(hi, lo)
end

-- HashString128 returns the 128-bit hash of the string.
function xxh3.HashString128(s)
    return xxh3.hashAny128(s)
end

-- Hash128 returns the 128-bit hash of the byte slice (a Lua string).
function xxh3.Hash128(b)
    return xxh3.hashAny128(b)
end

---- 64-bit hash (hash64.go, hasher.go)

local function rotateLeft64(x, k)
    return (x << k) | (x >> (64 - k))
end

local function xxhAvalancheSmall(x)
    x = x ~ (x >> 33)
    x = x * prime64_2
    x = x ~ (x >> 29)
    x = x * prime64_3
    x = x ~ (x >> 32)
    return x
end

local function rrmxmx(h64, len)
    h64 = h64 ~ rotateLeft64(h64, 49) ~ rotateLeft64(h64, 24)
    h64 = h64 * 0x9fb21c651e98df25
    h64 = h64 ~ ((h64 >> 35) + len)
    h64 = h64 * 0x9fb21c651e98df25
    h64 = h64 ~ (h64 >> 28)
    return h64
end

-- hashAny returns the 64-bit hash (a Lua integer holding the uint64 bits) of the string p.
function xxh3.hashAny(p)
    local l = #p
    local acc

    if l <= 16 then
        if l > 8 then -- 9-16
            local inputlo = readU64(p, 0) ~ (key64_024 ~ key64_032)
            local inputhi = readU64(p, l - 8) ~ (key64_040 ~ key64_048)
            local folded = mulFold64(inputlo, inputhi)
            return xxh3Avalanche(l + reverseBytes64(inputlo) + inputhi + folded)
        elseif l > 3 then -- 4-8
            local input1 = readU32(p, 0)
            local input2 = readU32(p, l - 4)
            local input64 = input2 + (input1 << 32)
            local keyed = input64 ~ (key64_008 ~ key64_016)
            return rrmxmx(keyed, l)
        elseif l == 3 then -- 3
            local c12 = readU16(p, 0)
            local c3 = readU8(p, 2)
            acc = (c12 << 16) + c3 + (3 << 8)
        elseif l > 1 then -- 2
            local c12 = readU16(p, 0)
            acc = ((c12 * ((1 << 24) + 1)) >> 8) + (2 << 8)
        elseif l == 1 then -- 1
            local c1 = readU8(p, 0)
            acc = c1 * ((1 << 24) + (1 << 16) + 1) + (1 << 8)
        else -- 0
            return 0x2d06800538d394c2 -- xxh_avalanche(key64_056 ^ key64_064)
        end

        acc = acc ~ (key32_000 ~ key32_004)
        return xxhAvalancheSmall(acc)
    elseif l <= 128 then
        acc = l * prime64_1

        if l > 32 then
            if l > 64 then
                if l > 96 then
                    acc = acc + mulFold64(readU64(p, 6 * 8) ~ key64_096, readU64(p, 7 * 8) ~ key64_104)
                    acc = acc + mulFold64(readU64(p, l - 8 * 8) ~ key64_112, readU64(p, l - 7 * 8) ~ key64_120)
                end -- 96
                acc = acc + mulFold64(readU64(p, 4 * 8) ~ key64_064, readU64(p, 5 * 8) ~ key64_072)
                acc = acc + mulFold64(readU64(p, l - 6 * 8) ~ key64_080, readU64(p, l - 5 * 8) ~ key64_088)
            end -- 64
            acc = acc + mulFold64(readU64(p, 2 * 8) ~ key64_032, readU64(p, 3 * 8) ~ key64_040)
            acc = acc + mulFold64(readU64(p, l - 4 * 8) ~ key64_048, readU64(p, l - 3 * 8) ~ key64_056)
        end -- 32
        acc = acc + mulFold64(readU64(p, 0 * 8) ~ key64_000, readU64(p, 1 * 8) ~ key64_008)
        acc = acc + mulFold64(readU64(p, l - 2 * 8) ~ key64_016, readU64(p, l - 1 * 8) ~ key64_024)

        return xxh3Avalanche(acc)
    elseif l <= 240 then
        acc = l * prime64_1

        for i = 0, 7 do
            acc = acc + mulFold64(readU64(p, i * 16) ~ readU64(key, i * 16), readU64(p, i * 16 + 8) ~ readU64(key, i * 16 + 8))
        end

        -- avalanche
        acc = xxh3Avalanche(acc)

        -- trailing groups after 128
        local top = l & ~15
        for i = 8 * 16, top - 1, 16 do
            acc = acc + mulFold64(readU64(p, i + 0) ~ readU64(key, i - 125), readU64(p, i + 8) ~ readU64(key, i - 117))
        end

        -- last 16 bytes
        acc = acc + mulFold64(readU64(p, l - 16) ~ key64_119, readU64(p, l - 8) ~ key64_127)

        return xxh3Avalanche(acc)
    end

    acc = l * prime64_1

    local accs = {
        prime32_3, prime64_1, prime64_2, prime64_3,
        prime64_4, prime32_2, prime64_5, prime32_1,
    }

    accumScalar(accs, p, l)

    -- merge accs
    for i = 0, 3 do
        acc = acc + mulFold64(accs[2 * i + 1] ~ readU64(key, 11 + 16 * i), accs[2 * i + 2] ~ readU64(key, 19 + 16 * i))
    end

    return xxh3Avalanche(acc)
end

-- HashString returns the 64-bit hash of the string.
function xxh3.HashString(s)
    return xxh3.hashAny(s)
end

-- Hash returns the 64-bit hash of the byte slice (a Lua string).
function xxh3.Hash(b)
    return xxh3.hashAny(b)
end

-- Hasher implements hash.Hash64. The written data is buffered and hashed on Sum64; XXH3 streaming
-- yields the same value as hashing the concatenated input at once.
local Hasher = {}
Hasher.__index = Hasher
xxh3.Hasher = Hasher

-- New returns a new Hasher.
function xxh3.New()
    return setmetatable({ buf = {} }, Hasher)
end

-- Reset resets the Hash to its initial state.
function Hasher:Reset()
    self.buf = {}
end

-- WriteString adds more data to the running hash. Returns (n, err); it never returns an error.
function Hasher:WriteString(s)
    self.buf[#self.buf + 1] = s
    return #s, nil
end

Hasher.Write = Hasher.WriteString

-- Sum64 returns the 64-bit hash of the written data.
function Hasher:Sum64()
    return xxh3.hashAny(table.concat(self.buf))
end

return xxh3
