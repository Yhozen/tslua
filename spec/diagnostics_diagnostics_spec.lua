-- Port of internal/diagnostics/diagnostics_test.go. Locales are BCP 47 tag strings in the Lua
-- port (language.English = "en", language.Und = locale.Default, language.MustParse = ParseTag).
local diagnostics = require("tslua.diagnostics")
local localepkg = require("tslua.locale")

local English = "en"
local Und = localepkg.Default

local function MustParse(s)
    local tag, ok = localepkg.ParseTag(s)
    assert(ok, "language: tag is not well-formed: " .. s)
    return tag
end

describe("TestLocalize", function()
    local tests = {
        {
            name = "english default",
            message = diagnostics.Identifier_expected,
            locale = English,
            expected = "Identifier expected.",
        },
        {
            name = "undefined locale uses english",
            message = diagnostics.Identifier_expected,
            locale = Und,
            expected = "Identifier expected.",
        },
        {
            name = "with single argument",
            message = diagnostics.X_0_expected,
            locale = English,
            args = { ")" },
            expected = "')' expected.",
        },
        {
            name = "with multiple arguments",
            message = diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here,
            locale = English,
            args = { "{", "}" },
            expected = "The parser expected to find a '}' to match the '{' token here.",
        },
        {
            name = "fallback to english for unknown locale",
            message = diagnostics.Identifier_expected,
            locale = MustParse("af-ZA"),
            expected = "Identifier expected.",
        },
        {
            name = "german",
            message = diagnostics.Identifier_expected,
            locale = MustParse("de-DE"),
            expected = "Es wurde ein Bezeichner erwartet.",
        },
        {
            name = "french",
            message = diagnostics.Identifier_expected,
            locale = MustParse("fr-FR"),
            expected = "Identificateur attendu.",
        },
        {
            name = "spanish",
            message = diagnostics.Identifier_expected,
            locale = MustParse("es-ES"),
            expected = "Se esperaba un identificador.",
        },
        {
            name = "japanese",
            message = diagnostics.Identifier_expected,
            locale = MustParse("ja-JP"),
            expected = "識別子が必要です。",
        },
        {
            name = "chinese simplified",
            message = diagnostics.Identifier_expected,
            locale = MustParse("zh-CN"),
            expected = "应为标识符。",
        },
        {
            name = "korean",
            message = diagnostics.Identifier_expected,
            locale = MustParse("ko-KR"),
            expected = "식별자가 필요합니다.",
        },
        {
            name = "russian",
            message = diagnostics.Identifier_expected,
            locale = MustParse("ru-RU"),
            expected = "Ожидался идентификатор.",
        },
        {
            name = "german with args",
            message = diagnostics.X_0_expected,
            locale = MustParse("de-DE"),
            args = { ")" },
            expected = "\")\" wurde erwartet.",
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local result = tt.message:Localize(tt.locale, table.unpack(tt.args or {}))
            assert.are.equal(tt.expected, result)
        end)
    end
end)

describe("TestLocalize_ByKey", function()
    local tests = {
        {
            name = "by key without args",
            key = "Identifier_expected_1003",
            locale = English,
            expected = "Identifier expected.",
        },
        {
            name = "by key with args",
            key = "_0_expected_1005",
            locale = English,
            args = { ")" },
            expected = "')' expected.",
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local result = diagnostics.Localize(tt.locale, nil, tt.key, table.unpack(tt.args or {}))
            assert.are.equal(tt.expected, result)
        end)
    end
end)
