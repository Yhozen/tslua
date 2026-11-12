-- Port of internal/ast/positionmap_test.go (Benchmark* skipped)
local ast = require("tslua.ast")
local stringutil = require("tslua.stringutil")

-- Go strings.LastIndex (0-based byte index, -1 if absent); sub is a single byte here.
local function lastIndex(s, sub)
    for i = #s - #sub + 1, 1, -1 do
        if string.sub(s, i, i + #sub - 1) == sub then
            return i - 1
        end
    end
    return -1
end

describe("TestPositionMapASCII", function()
    it("TestPositionMapASCII", function()
        local text = "const x = 1;"
        local pm = ast.ComputePositionMap(text)
        assert.is_true(pm:IsAsciiOnly(), "expected ASCII-only")
        for i = 0, #text do
            assert.are.equal(i, pm:UTF8ToUTF16(i), string.format("UTF8ToUTF16(%d)", i))
            assert.are.equal(i, pm:UTF16ToUTF8(i), string.format("UTF16ToUTF8(%d)", i))
        end
    end)
end)

describe("TestPositionMapTwoByte", function()
    it("TestPositionMapTwoByte", function()
        -- "café" — é (U+00E9) is 2 bytes UTF-8, 1 code unit UTF-16
        local text = "const café = 1;\nconst x = 2;"
        local pm = ast.ComputePositionMap(text)
        assert.is_false(pm:IsAsciiOnly(), "expected non-ASCII")

        -- Everything before é (byte offset 9) should be identity
        for i = 0, 9 do
            assert.are.equal(i, pm:UTF8ToUTF16(i), string.format("before é: UTF8ToUTF16(%d)", i))
        end

        -- é starts at UTF-8 byte 9, UTF-16 offset 9: same
        assert.are.equal(9, pm:UTF8ToUTF16(9), "at é: UTF8ToUTF16(9)")

        -- After é (byte 11 in UTF-8 = code unit 10 in UTF-16), delta is 1
        -- ' ' after café: UTF-8 byte 11, UTF-16 offset 10
        assert.are.equal(10, pm:UTF8ToUTF16(11), "after é: UTF8ToUTF16(11)")

        -- 'x' on second line: UTF-8 byte 23, UTF-16 offset 22
        local xUTF8 = lastIndex(text, "x")
        assert.are.equal(xUTF8 - 1, pm:UTF8ToUTF16(xUTF8), "at x")

        -- Reverse: UTF-16 offset 22 should map to UTF-8 byte 23
        local xUTF16 = xUTF8 - 1
        assert.are.equal(xUTF8, pm:UTF16ToUTF8(xUTF16), "reverse at x")
    end)
end)

describe("TestPositionMapFourByte", function()
    it("TestPositionMapFourByte", function()
        -- 🎉 (U+1F389) is 4 bytes UTF-8, 2 code units UTF-16
        local text = [[const a = "🎉";]] .. "\nconst b = 2;"
        local pm = ast.ComputePositionMap(text)
        assert.is_false(pm:IsAsciiOnly(), "expected non-ASCII")

        -- 🎉 starts at byte 11 (after `const a = "`)
        -- UTF-8: bytes 11-14 (4 bytes), UTF-16: units 11-12 (2 code units)
        -- After 🎉: UTF-8 byte 15, UTF-16 offset 13. Delta = 2.

        -- 'b' on second line
        local bUTF8 = lastIndex(text, "b")
        local bUTF16 = bUTF8 - 2 -- delta of 2 from emoji
        assert.are.equal(bUTF16, pm:UTF8ToUTF16(bUTF8), "at b")
        assert.are.equal(bUTF8, pm:UTF16ToUTF8(bUTF16), "reverse at b")
    end)
end)

describe("TestPositionMapMultipleNonASCII", function()
    it("TestPositionMapMultipleNonASCII", function()
        -- Mix of 2-byte and 4-byte characters
        -- "à" (U+00E0) = 2 bytes UTF-8, 1 code unit UTF-16 (delta +1)
        -- "🎉" (U+1F389) = 4 bytes UTF-8, 2 code units UTF-16 (delta +2)
        local text = "à🎉x"
        local pm = ast.ComputePositionMap(text)

        -- à: UTF-8 [0,2), UTF-16 [0,1)
        -- 🎉: UTF-8 [2,6), UTF-16 [1,3)
        -- x: UTF-8 [6,7), UTF-16 [3,4)
        local tests = {
            { utf8 = 0, utf16 = 0 },
            { utf8 = 2, utf16 = 1 }, -- start of 🎉
            { utf8 = 6, utf16 = 3 }, -- x
            { utf8 = 7, utf16 = 4 }, -- end
        }
        for _, tt in ipairs(tests) do
            assert.are.equal(tt.utf16, pm:UTF8ToUTF16(tt.utf8), string.format("UTF8ToUTF16(%d)", tt.utf8))
            assert.are.equal(tt.utf8, pm:UTF16ToUTF8(tt.utf16), string.format("UTF16ToUTF8(%d)", tt.utf16))
        end
    end)
end)

describe("TestPositionMapLoneSurrogateSentinel", function()
    it("TestPositionMapLoneSurrogateSentinel", function()
        local text = "a" .. stringutil.EncodeJSStringRune(0xD800) .. "b"
        local pm = ast.ComputePositionMap(text)
        assert.is_false(pm:IsAsciiOnly(), "expected non-ASCII")

        assert.are.equal(3, pm:UTF8ToUTF16(#text), string.format("UTF8ToUTF16(%d)", #text))
        assert.are.equal(#text - 1, pm:UTF16ToUTF8(2), "UTF16ToUTF8(2)")
    end)
end)

describe("TestPositionMapRoundtrip", function()
    it("TestPositionMapRoundtrip", function()
        local text = "let café = \"🎉\"; // naïve"
        local pm = ast.ComputePositionMap(text)

        -- Convert every valid UTF-16 position to UTF-8 and back
        local utf16Len = pm:UTF8ToUTF16(#text)
        for i = 0, utf16Len do
            local utf8Pos = pm:UTF16ToUTF8(i)
            local back = pm:UTF8ToUTF16(utf8Pos)
            assert.are.equal(i, back, string.format("roundtrip UTF16->UTF8->UTF16: %d -> %d -> %d", i, utf8Pos, back))
        end
    end)
end)
