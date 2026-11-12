local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")

describe("diagnostics", function()
    it("exposes generated messages with Go accessors", function()
        local m = diagnostics.Identifier_expected
        assert.are.equal(1003, m:Code())
        assert.are.equal(diagnostics.Category.Error, m:Category())
        assert.are.equal("Identifier_expected_1003", m:Key())
        assert.is_false(m:ReportsUnnecessary())
        assert.is_false(m:ElidedInCompatibilityPyramid())
        assert.is_false(m:ReportsDeprecated())
        assert.is_true(diagnostics.Left_side_of_comma_operator_is_unused_and_has_no_side_effects:ReportsUnnecessary())
        assert.is_true(diagnostics.Call_signature_return_types_0_and_1_are_incompatible:ElidedInCompatibilityPyramid())
    end)

    it("names categories", function()
        assert.are.equal("error", diagnostics.Category_Name(diagnostics.Category.Error))
        assert.are.equal("warning", diagnostics.Category_Name(diagnostics.Category.Warning))
        assert.are.equal("suggestion", diagnostics.Category_Name(diagnostics.Category.Suggestion))
        assert.are.equal("message", diagnostics.Category_Name(diagnostics.Category.Message))
        assert.are.equal("CategoryMessage", diagnostics.Category_String(diagnostics.Category.Message))
        assert.are.equal("Category(7)", diagnostics.Category_String(7))
    end)

    -- TestLocalize (English cases)
    it("localizes in English", function()
        assert.are.equal("Identifier expected.", diagnostics.Identifier_expected:Localize(nil))
        assert.are.equal("')' expected.", diagnostics.X_0_expected:Localize(nil, ")"))
        assert.are.equal("The parser expected to find a '}' to match the '{' token here.",
            diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here:Localize(nil, "{", "}"))
        assert.are.equal("'x' expected.", diagnostics.Localize(nil, nil, "_0_expected_1005", "x"))
        assert.has_error(function() diagnostics.Localize(nil, nil, "nope") end)
    end)

    it("formats placeholders and arguments", function()
        assert.are.equal("a 1 b 0", diagnostics.Format("a {1} b {0}", { "0", "1" }))
        assert.are.equal("plain", diagnostics.Format("plain", nil))
        assert.has_error(function() diagnostics.Format("{2}", { "a" }) end)
        assert.are.equal("x\u{FFFD}y", diagnostics.Format("{0}", { "x\255\254y" }))
        assert.are.same({ "s", "3", "2.5", "true", "1e+06" }, diagnostics.StringifyArgs({ "s", 3, 2.5, true, 1e6 }))
        assert.is_nil(diagnostics.StringifyArgs({}))
    end)

    it("creates ad hoc messages", function()
        local m = diagnostics.NewAdHocMessage("hello")
        assert.are.equal(-1, m:Code())
        assert.are.equal("-1", m:Key())
        assert.are.equal(diagnostics.Category.Error, m:Category())
        assert.are.equal("hello", m:String())
    end)

    -- TestLocalize
    it("localizes in other locales", function()
        local function tag(s)
            local t, ok = locale.Parse(s)
            assert.is_true(ok)
            return t
        end
        local tests = {
            { diagnostics.Identifier_expected, tag("en"), {}, "Identifier expected." },
            { diagnostics.Identifier_expected, locale.Default, {}, "Identifier expected." },
            { diagnostics.X_0_expected, tag("en"), { ")" }, "')' expected." },
            { diagnostics.Identifier_expected, tag("af-ZA"), {}, "Identifier expected." },
            { diagnostics.Identifier_expected, tag("de-DE"), {}, "Es wurde ein Bezeichner erwartet." },
            { diagnostics.Identifier_expected, tag("fr-FR"), {}, "Identificateur attendu." },
            { diagnostics.Identifier_expected, tag("es-ES"), {}, "Se esperaba un identificador." },
            { diagnostics.Identifier_expected, tag("ja-JP"), {}, "識別子が必要です。" },
            { diagnostics.Identifier_expected, tag("zh-CN"), {}, "应为标识符。" },
            { diagnostics.Identifier_expected, tag("ko-KR"), {}, "식별자가 필요합니다." },
            { diagnostics.Identifier_expected, tag("ru-RU"), {}, "Ожидался идентификатор." },
            { diagnostics.X_0_expected, tag("de-DE"), { ")" }, "\")\" wurde erwartet." },
        }
        for _, tt in ipairs(tests) do
            assert.are.equal(tt[4], tt[1]:Localize(tt[2], table.unpack(tt[3])))
        end
        -- TestLocalize_ByKey
        assert.are.equal("Identifier expected.", diagnostics.Localize(tag("en"), nil, "Identifier_expected_1003"))
        assert.are.equal("')' expected.", diagnostics.Localize(tag("en"), nil, "_0_expected_1005", ")"))
    end)

    it("parses and matches language tags like golang.org/x/text/language", function()
        assert.are.same({ "zh-Hant-TW", true }, { locale.Parse("ZH_hant-tw") })
        assert.are.same({ "cs", true }, { locale.Parse("ces") })
        assert.are.same({ "en-GB", true }, { locale.Parse("en-UK") })
        assert.are.same({ "de", false }, { locale.Parse("de-foobar") })
        assert.are.same({ "", false }, { locale.Parse("whoops") })
        local _, index = diagnostics.matcher:Match("zh-HK")
        assert.are.equal(2, index)
        _, index = diagnostics.matcher:Match("pt-PT")
        assert.are.equal(11, index)
        local conf
        _, index, conf = diagnostics.matcher:Match("af-ZA")
        assert.are.equal(locale.Confidence.No, conf)
    end)
end)
