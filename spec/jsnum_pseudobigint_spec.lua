-- Port of internal/jsnum/pseudobigint_test.go.
local jsnum = require("tslua.jsnum")

describe("TestParsePseudoBigInt", function()
    local testNumbers = {}
    for i = 0, 1e3 - 1 do
        testNumbers[#testNumbers + 1] = i + 0.0
    end
    for bits = 0, 52 do
        testNumbers[#testNumbers + 1] = (1 << bits) + 0.0
        testNumbers[#testNumbers + 1] = ((1 << bits) - 1) + 0.0
    end

    it("strip base-10 strings", function()
        for _, testNumber in ipairs(testNumbers) do
            for leadingZeros = 0, 9 do
                assert.are.equal(
                    jsnum.Number_String(testNumber),
                    jsnum.ParsePseudoBigInt(string.rep("0", leadingZeros) .. jsnum.Number_String(testNumber) .. "n")
                )
            end
        end
    end)

    it("parse non-decimal bases (small numbers)", function()
        local cases = {
            -- binary
            { lit = "0b0n", out = "0" },
            { lit = "0b1n", out = "1" },
            { lit = "0b1010n", out = "10" },
            { lit = "0b1010_0101n", out = "165" },
            { lit = "0B1101n", out = "13" }, -- uppercase prefix

            -- octal
            { lit = "0o0n", out = "0" },
            { lit = "0o7n", out = "7" },
            { lit = "0o755n", out = "493" },
            { lit = "0o7_5_5n", out = "493" },
            { lit = "0O12n", out = "10" }, -- uppercase prefix

            -- hex
            { lit = "0x0n", out = "0" },
            { lit = "0xFn", out = "15" },
            { lit = "0xFFn", out = "255" },
            { lit = "0xF_Fn", out = "255" },
            { lit = "0X1Fn", out = "31" }, -- uppercase prefix
        }

        for _, c in ipairs(cases) do
            assert.are.equal(c.out, jsnum.ParsePseudoBigInt(c.lit), "literal: " .. c.lit)
        end
    end)

    it("can parse large literals", function()
        assert.are.equal("123456789012345678901234567890", jsnum.ParsePseudoBigInt("123456789012345678901234567890n"))
        assert.are.equal("123456789012345678901234567890", jsnum.ParsePseudoBigInt("0b1100011101110100100001111111101101100001101110011111000001110111001001110001111110000101011010010n"))
        assert.are.equal("123456789012345678901234567890", jsnum.ParsePseudoBigInt("0o143564417755415637016711617605322n"))
        assert.are.equal("123456789012345678901234567890", jsnum.ParsePseudoBigInt("0x18ee90ff6c373e0ee4e3f0ad2n"))
    end)
end)
