local jsnum = require("tslua.jsnum")

-- PseudoBigInt represents a JS-like bigint. The zero state of the struct represents the value 0.
-- Immutable value: { negative = bool, base10Value = string }.
-- negative: true if the value is a non-zero negative number.
-- base10Value: the absolute value in base 10 with no leading zeros. The value zero is represented as an empty string.
local PseudoBigInt = {}
PseudoBigInt.__index = PseudoBigInt
jsnum.PseudoBigInt = PseudoBigInt

PseudoBigInt.__eq = function(a, b)
    return a.negative == b.negative and a.base10Value == b.base10Value
end

local function trimLeftZeros(s)
    return (string.gsub(s, "^0+", ""))
end

function jsnum.NewPseudoBigInt(value, negative)
    value = trimLeftZeros(value)
    return setmetatable({ negative = negative and #value ~= 0, base10Value = value }, PseudoBigInt)
end

function PseudoBigInt:String()
    if #self.base10Value == 0 then
        return "0"
    end
    if self.negative then
        return "-" .. self.base10Value
    end
    return self.base10Value
end

function PseudoBigInt:Sign()
    if #self.base10Value == 0 then
        return 0
    end
    if self.negative then
        return -1
    end
    return 1
end

function jsnum.ParseValidBigInt(text)
    local negative = false
    if string.sub(text, 1, 1) == "-" then
        text = string.sub(text, 2)
        negative = true
    end
    return jsnum.NewPseudoBigInt(jsnum.ParsePseudoBigInt(text), negative)
end

-- Converts the digits of s (all valid in the given base) to a base-10 string.
function jsnum.baseDigitsToDecimal(s, base)
    -- little-endian base 10^7 limbs
    local LIMB = 10000000
    local r = { 0 }
    for i = 1, #s do
        local d = tonumber(string.sub(s, i, i), 16)
        local carry = d
        for k = 1, #r do
            local t = r[k] * base + carry
            r[k] = t % LIMB
            carry = t // LIMB
        end
        while carry > 0 do
            r[#r + 1] = carry % LIMB
            carry = carry // LIMB
        end
    end
    local parts = { string.format("%d", r[#r]) }
    for k = #r - 1, 1, -1 do
        parts[#parts + 1] = string.format("%07d", r[k])
    end
    return table.concat(parts)
end

function jsnum.ParsePseudoBigInt(stringValue)
    if string.sub(stringValue, -1) == "n" then
        stringValue = string.sub(stringValue, 1, -2)
    end
    local b1 = ""
    if #stringValue > 1 then
        b1 = string.sub(stringValue, 2, 2)
    end
    local base
    if b1 == "b" or b1 == "B" then
        base = 2
    elseif b1 == "o" or b1 == "O" then
        base = 8
    elseif b1 == "x" or b1 == "X" then
        base = 16
    else
        stringValue = trimLeftZeros(stringValue)
        if stringValue == "" then
            return "0"
        end
        return stringValue
    end
    -- big.Int.SetString(stringValue, 0) requires a leading "0" before the base letter.
    local digits = string.sub(stringValue, 3)
    local valid = string.sub(stringValue, 1, 1) == "0" and #digits > 0
    if valid then
        -- base 0 permits underscores between digits
        local cleaned = string.gsub(digits, "_", "")
        if string.find(digits, "_$") or string.find(digits, "__") then
            valid = false
        end
        digits = cleaned
        local pattern = (base == 2 and "^[01]+$") or (base == 8 and "^[0-7]+$") or "^%x+$"
        if not string.find(digits, pattern) then
            valid = false
        end
    end
    if not valid then
        error(string.format("Failed to parse big int: %q", stringValue), 0)
    end
    return jsnum.baseDigitsToDecimal(digits, base) -- !!!
end
