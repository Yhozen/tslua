local stringutil = require("tslua.stringutil")

describe("stringutil identifier tables", function()
    it("match Go's IsUnicodeIdentifierStart/Part over all code points", function()
        -- Expected counts and rolling checksums computed with the Go implementation.
        local ns, ss, np, sp = 0, 0, 0, 0
        for r = 0, 0x10FFFF do
            if stringutil.IsUnicodeIdentifierStart(r) then
                ns = ns + 1
                ss = (ss * 31 + r) % 1000000007
            end
            if stringutil.IsUnicodeIdentifierPart(r) then
                np = np + 1
                sp = (sp * 31 + r) % 1000000007
            end
        end
        assert.are.same({ 136967, 485000695, 140108, 143020651 }, { ns, ss, np, sp })
        assert.is_true(stringutil.IsUnicodeIdentifierStart(0x41))
        assert.is_false(stringutil.IsUnicodeIdentifierStart(0x30))
        assert.is_true(stringutil.IsUnicodeIdentifierPart(0x30))
        assert.is_true(stringutil.IsUnicodeIdentifierStart(0x3C0)) -- π
    end)
end)

describe("stringutil JS casing (js_case_test.go)", function()
    local E = stringutil.EncodeJSStringRune
    local tests = {
        { stringutil.ToLowerJS("HELLO"), "hello" },
        { stringutil.ToUpperJS("hello"), "HELLO" },
        { stringutil.ToLowerJS("İSPANYOL"), "i̇spanyol" },
        { stringutil.ToLowerJS("Σ"), "σ" },
        { stringutil.ToLowerJS("ΟΣ"), "ος" },
        { stringutil.ToLowerJS("Ω"), "ω" },
        { stringutil.ToUpperJS("ßfoo"), "SSFOO" },
        { stringutil.ToUpperJS("ω"), "Ω" },
        { stringutil.ToUpperJS("ﬁoo"), "FIOO" },
        { stringutil.ToUpperJS("ß") .. "foo", "SSfoo" },
        { stringutil.ToLowerJS("İ") .. "foo", "i̇foo" },
        { stringutil.ToLowerJS("ʕΣ"), "ʕς" },
        { stringutil.ToLowerJS("ʰΣ"), "ʰσ" },
        { stringutil.ToLowerJS("ͅΣ"), "ͅσ" },
        { stringutil.ToLowerJS("ªΣ"), "ªς" },
        { stringutil.ToLowerJS("ºΣ"), "ºς" },
        { stringutil.ToLowerJS("ⅠΣ"), "ⅰς" },
        { stringutil.ToLowerJS("\u{1C89}Σ"), "\u{1C89}σ" },
        { stringutil.ToLowerJS("\u{A7CB}Σ"), "\u{A7CB}σ" },
        { stringutil.ToLowerJS("ΣA"), "σa" },
        { stringutil.ToLowerJS("ΣⅠ"), "σⅰ" },
        { stringutil.ToLowerJS("ΣͅA"), "σͅa" },
        { stringutil.ToUpperJS(E(0xD800)), E(0xD800) },
        { stringutil.ToLowerJS("A" .. E(0xD800) .. "B"), "a" .. E(0xD800) .. "b" },
        { stringutil.ToUpperJS(E(0xDC00) .. "x"), E(0xDC00) .. "X" },
        { stringutil.ToLowerJS(E(0xD800) .. "Σ"), E(0xD800) .. "σ" },
        -- additional cases checked against Go
        { stringutil.ToLowerJS("ΑΣ Β"), "ας β" },
        { stringutil.ToLowerJS("ΑΣ."), "ας." },
        { stringutil.ToLowerJS("aΣb"), "aσb" },
        { stringutil.ToUpperJS("straße"), "STRASSE" },
        { stringutil.ToLowerJS("ǅ"), "ǆ" },
        { stringutil.ToUpperJS("ǅ"), "Ǆ" },
        { stringutil.ToLowerJS("ΆΣΣ"), "άσς" },
        { stringutil.ToUpperJS("ﬃ"), "FFI" },
        { stringutil.ToUpperJS("ŉ"), "ʼN" },
    }
    it("matches Go", function()
        for i, t in ipairs(tests) do
            assert.are.equal(t[2], t[1], "case " .. i)
        end
    end)
end)

describe("stringutil util", function()
    it("misc", function()
        assert.are.same({ "a", "b", "", "c" }, stringutil.SplitLines("a\r\nb\n\rc"))
        assert.are.equal(2, stringutil.GuessIndentation({ "  a", "    b", "", "  c" }))
        assert.are.equal("a%20b%C3%A9;/", stringutil.EncodeURI("a b\u{E9};/"))
        assert.are.equal("abc", stringutil.StripQuotes('"abc"'))
        assert.are.equal("'abc\"", stringutil.StripQuotes("'abc\""))
        assert.are.equal("a'b\\", stringutil.UnquoteString("'a\\'b\\\\'"))
        assert.are.equal("abc", stringutil.RemoveByteOrderMark("\xEF\xBB\xBFabc"))
        assert.are.equal("\u{E9}bc", stringutil.LowerFirstChar("\u{C9}bc"))
        assert.are.equal("ab", stringutil.TruncateByRunes("abc", 2))
        assert.are.equal("\u{1F600}", stringutil.CombineSurrogatePairs(stringutil.EncodeJSStringRune(0xD83D) .. stringutil.EncodeJSStringRune(0xDE00)))
        local h, l = stringutil.CodePointToSurrogatePair(0x1F600)
        assert.are.same({ 0xD83D, 0xDE00 }, { h, l })
        assert.are.equal(0x1F600, stringutil.SurrogatePairToCodePoint(h, l))
    end)

    it("compare", function()
        assert.are.equal(0, stringutil.CompareStringsCaseInsensitive("abc", "ABC"))
        assert.are.equal(-1, stringutil.CompareStringsCaseInsensitive("abc", "ABD"))
        assert.are.equal(1, stringutil.CompareStringsCaseInsensitive("abcd", "ABC"))
        assert.are.equal(-1, stringutil.CompareStringsCaseSensitive("B", "a"))
        assert.is_true(stringutil.EquateStringCaseInsensitive("\u{212A}", "k"))
        assert.is_true(stringutil.HasPrefix("FooBar", "foo", false))
        assert.is_false(stringutil.HasPrefix("FooBar", "foo", true))
        assert.is_true(stringutil.HasSuffix("FooBar", "BAR", false))
        assert.are.equal(-1, stringutil.CompareStringsCaseInsensitiveEslintCompatible("_", "A"))
    end)
end)
