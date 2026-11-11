local scanner = require("tslua.scanner")
local ast = require("tslua.ast")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local TokenFlags = ast.TokenFlags

local function newNode(kind, flags, parent, loc)
    return setmetatable({ kind = kind, flags = flags or 0, parent = parent, loc = loc or core.NewTextRange(-1, -1) }, { __index = ast.Node })
end

local function scanAll(text, setup)
    local s = scanner.NewScanner()
    s:SetText(text)
    local errors = {}
    s:SetOnError(function(m, start, length, ...)
        errors[#errors + 1] = { code = m:Code(), start = start, length = length, args = { ... } }
    end)
    if setup then
        setup(s)
    end
    local tokens = {}
    while true do
        local k = s:Scan()
        tokens[#tokens + 1] = { kind = k, value = s:TokenValue(), start = s:TokenStart(), end_ = s:TokenEnd(), flags = s:TokenFlags() }
        if k == Kind.EndOfFile then
            break
        end
    end
    return tokens, errors
end

-- Runs one fixture case and returns tokens/errors/directives in fixture shape.
local function runCase(c)
    local tokens, errors, directives = {}, {}, {}
    local s = scanner.NewScanner()
    s:SetText(c.text)
    s:SetScriptTarget(c.target or core.ScriptTarget.None)
    if c.jsx then
        s:SetLanguageVariant(core.LanguageVariant.JSX)
    end
    if c.trivia then
        s:SetSkipTrivia(false)
    end
    s:SetOnError(function(m, start, length, ...)
        errors[#errors + 1] = { m:Code(), start, length, m:Localize(nil, ...) }
    end)
    for _ = 1, 1000 do
        local k
        if c.mode == "jsx" then
            k = s:ScanJsxToken()
        elseif c.mode == "jsdoc" then
            k = s:ScanJSDocToken()
        elseif c.mode == "jsdoctext" then
            k = s:ScanJSDocCommentTextToken(false)
        else
            k = s:Scan()
            if c.mode == "rescan" then
                if k == Kind.SlashToken or k == Kind.SlashEqualsToken then
                    k = s:ReScanSlashToken(true)
                elseif k == Kind.CloseBraceToken then
                    k = s:ReScanTemplateToken(false)
                elseif k == Kind.GreaterThanToken then
                    k = s:ReScanGreaterThanToken()
                elseif k == Kind.Identifier and c.jsx then
                    k = s:ScanJsxIdentifier()
                end
            end
        end
        tokens[#tokens + 1] = { ast.Kind_names[k], s:TokenStart(), s:TokenEnd(), s:TokenValue(), s:TokenFlags() }
        if k == Kind.EndOfFile then
            break
        end
    end
    for _, d in ipairs(s:CommentDirectives() or {}) do
        directives[#directives + 1] = { d.loc.pos, d.loc.end_, d.kind }
    end
    return tokens, errors, directives
end

-- BEGIN GENERATED FIXTURES (expected values produced by the Go scanner)
local fixtures = {
    {
        name = "punctuation",
        text = "{ } ( ) [ ] . ... ; , < > <= >= == != === !== => + - ** * / % ++ -- << >> >>> & | ^ ! ~ && || ? ?? ?. : = += -= *= **= /= %= <<= >>= >>>= &= |= ^= ||= &&= ??= @ # `",
        tokens = {
            { "OpenBraceToken", 0, 1, "", 0 },
            { "CloseBraceToken", 2, 3, "", 0 },
            { "OpenParenToken", 4, 5, "", 0 },
            { "CloseParenToken", 6, 7, "", 0 },
            { "OpenBracketToken", 8, 9, "", 0 },
            { "CloseBracketToken", 10, 11, "", 0 },
            { "DotToken", 12, 13, "", 0 },
            { "DotDotDotToken", 14, 17, "", 0 },
            { "SemicolonToken", 18, 19, "", 0 },
            { "CommaToken", 20, 21, "", 0 },
            { "LessThanToken", 22, 23, "", 0 },
            { "GreaterThanToken", 24, 25, "", 0 },
            { "LessThanEqualsToken", 26, 28, "", 0 },
            { "GreaterThanToken", 29, 30, "", 0 },
            { "EqualsToken", 30, 31, "", 0 },
            { "EqualsEqualsToken", 32, 34, "", 0 },
            { "ExclamationEqualsToken", 35, 37, "", 0 },
            { "EqualsEqualsEqualsToken", 38, 41, "", 0 },
            { "ExclamationEqualsEqualsToken", 42, 45, "", 0 },
            { "EqualsGreaterThanToken", 46, 48, "", 0 },
            { "PlusToken", 49, 50, "", 0 },
            { "MinusToken", 51, 52, "", 0 },
            { "AsteriskAsteriskToken", 53, 55, "", 0 },
            { "AsteriskToken", 56, 57, "", 0 },
            { "SlashToken", 58, 59, "", 0 },
            { "PercentToken", 60, 61, "", 0 },
            { "PlusPlusToken", 62, 64, "", 0 },
            { "MinusMinusToken", 65, 67, "", 0 },
            { "LessThanLessThanToken", 68, 70, "", 0 },
            { "GreaterThanToken", 71, 72, "", 0 },
            { "GreaterThanToken", 72, 73, "", 0 },
            { "GreaterThanToken", 74, 75, "", 0 },
            { "GreaterThanToken", 75, 76, "", 0 },
            { "GreaterThanToken", 76, 77, "", 0 },
            { "AmpersandToken", 78, 79, "", 0 },
            { "BarToken", 80, 81, "", 0 },
            { "CaretToken", 82, 83, "", 0 },
            { "ExclamationToken", 84, 85, "", 0 },
            { "TildeToken", 86, 87, "", 0 },
            { "AmpersandAmpersandToken", 88, 90, "", 0 },
            { "BarBarToken", 91, 93, "", 0 },
            { "QuestionToken", 94, 95, "", 0 },
            { "QuestionQuestionToken", 96, 98, "", 0 },
            { "QuestionDotToken", 99, 101, "", 0 },
            { "ColonToken", 102, 103, "", 0 },
            { "EqualsToken", 104, 105, "", 0 },
            { "PlusEqualsToken", 106, 108, "", 0 },
            { "MinusEqualsToken", 109, 111, "", 0 },
            { "AsteriskEqualsToken", 112, 114, "", 0 },
            { "AsteriskAsteriskEqualsToken", 115, 118, "", 0 },
            { "SlashEqualsToken", 119, 121, "", 0 },
            { "PercentEqualsToken", 122, 124, "", 0 },
            { "LessThanLessThanEqualsToken", 125, 128, "", 0 },
            { "GreaterThanToken", 129, 130, "", 0 },
            { "GreaterThanToken", 130, 131, "", 0 },
            { "EqualsToken", 131, 132, "", 0 },
            { "GreaterThanToken", 133, 134, "", 0 },
            { "GreaterThanToken", 134, 135, "", 0 },
            { "GreaterThanToken", 135, 136, "", 0 },
            { "EqualsToken", 136, 137, "", 0 },
            { "AmpersandEqualsToken", 138, 140, "", 0 },
            { "BarEqualsToken", 141, 143, "", 0 },
            { "CaretEqualsToken", 144, 146, "", 0 },
            { "BarBarEqualsToken", 147, 150, "", 0 },
            { "AmpersandAmpersandEqualsToken", 151, 154, "", 0 },
            { "QuestionQuestionEqualsToken", 155, 158, "", 0 },
            { "AtToken", 159, 160, "", 0 },
            { "PrivateIdentifier", 161, 162, "#", 0 },
            { "NoSubstitutionTemplateLiteral", 163, 164, "", 4 },
            { "EndOfFile", 164, 164, "", 0 },
        },
        errors = {
            { 1127, 161, 1, "Invalid character." },
            { 1160, 164, 0, "Unterminated template literal." },
        },
        directives = { },
    },
    {
        name = "punctuation rescan",
        text = "a >> b >>> c >= d >>= e >>>= f > g",
        mode = "rescan",
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "GreaterThanGreaterThanToken", 2, 4, "a", 0 },
            { "Identifier", 5, 6, "b", 0 },
            { "GreaterThanGreaterThanGreaterThanToken", 7, 10, "b", 0 },
            { "Identifier", 11, 12, "c", 0 },
            { "GreaterThanEqualsToken", 13, 15, "c", 0 },
            { "Identifier", 16, 17, "d", 0 },
            { "GreaterThanGreaterThanEqualsToken", 18, 21, "d", 0 },
            { "Identifier", 22, 23, "e", 0 },
            { "GreaterThanGreaterThanGreaterThanEqualsToken", 24, 28, "e", 0 },
            { "Identifier", 29, 30, "f", 0 },
            { "GreaterThanToken", 31, 32, "f", 0 },
            { "Identifier", 33, 34, "g", 0 },
            { "EndOfFile", 34, 34, "g", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "keywords",
        text = "abstract accessor any as asserts assert async await bigint boolean break case catch class const constructor continue debugger declare default defer delete do else enum export extends false finally for from function get global if immediate implements import in infer instanceof interface intrinsic is keyof let module namespace never new null number object of out override package private protected public readonly require return satisfies set static string super switch symbol this throw true try type typeof undefined unique unknown using var void while with yield",
        tokens = {
            { "AbstractKeyword", 0, 8, "abstract", 0 },
            { "AccessorKeyword", 9, 17, "accessor", 0 },
            { "AnyKeyword", 18, 21, "any", 0 },
            { "AsKeyword", 22, 24, "as", 0 },
            { "AssertsKeyword", 25, 32, "asserts", 0 },
            { "AssertKeyword", 33, 39, "assert", 0 },
            { "AsyncKeyword", 40, 45, "async", 0 },
            { "AwaitKeyword", 46, 51, "await", 0 },
            { "BigIntKeyword", 52, 58, "bigint", 0 },
            { "BooleanKeyword", 59, 66, "boolean", 0 },
            { "BreakKeyword", 67, 72, "break", 0 },
            { "CaseKeyword", 73, 77, "case", 0 },
            { "CatchKeyword", 78, 83, "catch", 0 },
            { "ClassKeyword", 84, 89, "class", 0 },
            { "ConstKeyword", 90, 95, "const", 0 },
            { "ConstructorKeyword", 96, 107, "constructor", 0 },
            { "ContinueKeyword", 108, 116, "continue", 0 },
            { "DebuggerKeyword", 117, 125, "debugger", 0 },
            { "DeclareKeyword", 126, 133, "declare", 0 },
            { "DefaultKeyword", 134, 141, "default", 0 },
            { "DeferKeyword", 142, 147, "defer", 0 },
            { "DeleteKeyword", 148, 154, "delete", 0 },
            { "DoKeyword", 155, 157, "do", 0 },
            { "ElseKeyword", 158, 162, "else", 0 },
            { "EnumKeyword", 163, 167, "enum", 0 },
            { "ExportKeyword", 168, 174, "export", 0 },
            { "ExtendsKeyword", 175, 182, "extends", 0 },
            { "FalseKeyword", 183, 188, "false", 0 },
            { "FinallyKeyword", 189, 196, "finally", 0 },
            { "ForKeyword", 197, 200, "for", 0 },
            { "FromKeyword", 201, 205, "from", 0 },
            { "FunctionKeyword", 206, 214, "function", 0 },
            { "GetKeyword", 215, 218, "get", 0 },
            { "GlobalKeyword", 219, 225, "global", 0 },
            { "IfKeyword", 226, 228, "if", 0 },
            { "ImmediateKeyword", 229, 238, "immediate", 0 },
            { "ImplementsKeyword", 239, 249, "implements", 0 },
            { "ImportKeyword", 250, 256, "import", 0 },
            { "InKeyword", 257, 259, "in", 0 },
            { "InferKeyword", 260, 265, "infer", 0 },
            { "InstanceOfKeyword", 266, 276, "instanceof", 0 },
            { "InterfaceKeyword", 277, 286, "interface", 0 },
            { "IntrinsicKeyword", 287, 296, "intrinsic", 0 },
            { "IsKeyword", 297, 299, "is", 0 },
            { "KeyOfKeyword", 300, 305, "keyof", 0 },
            { "LetKeyword", 306, 309, "let", 0 },
            { "ModuleKeyword", 310, 316, "module", 0 },
            { "NamespaceKeyword", 317, 326, "namespace", 0 },
            { "NeverKeyword", 327, 332, "never", 0 },
            { "NewKeyword", 333, 336, "new", 0 },
            { "NullKeyword", 337, 341, "null", 0 },
            { "NumberKeyword", 342, 348, "number", 0 },
            { "ObjectKeyword", 349, 355, "object", 0 },
            { "OfKeyword", 356, 358, "of", 0 },
            { "OutKeyword", 359, 362, "out", 0 },
            { "OverrideKeyword", 363, 371, "override", 0 },
            { "PackageKeyword", 372, 379, "package", 0 },
            { "PrivateKeyword", 380, 387, "private", 0 },
            { "ProtectedKeyword", 388, 397, "protected", 0 },
            { "PublicKeyword", 398, 404, "public", 0 },
            { "ReadonlyKeyword", 405, 413, "readonly", 0 },
            { "RequireKeyword", 414, 421, "require", 0 },
            { "ReturnKeyword", 422, 428, "return", 0 },
            { "SatisfiesKeyword", 429, 438, "satisfies", 0 },
            { "SetKeyword", 439, 442, "set", 0 },
            { "StaticKeyword", 443, 449, "static", 0 },
            { "StringKeyword", 450, 456, "string", 0 },
            { "SuperKeyword", 457, 462, "super", 0 },
            { "SwitchKeyword", 463, 469, "switch", 0 },
            { "SymbolKeyword", 470, 476, "symbol", 0 },
            { "ThisKeyword", 477, 481, "this", 0 },
            { "ThrowKeyword", 482, 487, "throw", 0 },
            { "TrueKeyword", 488, 492, "true", 0 },
            { "TryKeyword", 493, 496, "try", 0 },
            { "TypeKeyword", 497, 501, "type", 0 },
            { "TypeOfKeyword", 502, 508, "typeof", 0 },
            { "UndefinedKeyword", 509, 518, "undefined", 0 },
            { "UniqueKeyword", 519, 525, "unique", 0 },
            { "UnknownKeyword", 526, 533, "unknown", 0 },
            { "UsingKeyword", 534, 539, "using", 0 },
            { "VarKeyword", 540, 543, "var", 0 },
            { "VoidKeyword", 544, 548, "void", 0 },
            { "WhileKeyword", 549, 554, "while", 0 },
            { "WithKeyword", 555, 559, "with", 0 },
            { "YieldKeyword", 560, 565, "yield", 0 },
            { "EndOfFile", 565, 565, "yield", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "identifiers",
        text = "foo _bar $baz a1 \\u0061bc \\u{62}cd x\\u0079z caf\xc3\xa9 \xcf\x80 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9d\x92\x9c done",
        tokens = {
            { "Identifier", 0, 3, "foo", 0 },
            { "Identifier", 4, 8, "_bar", 0 },
            { "Identifier", 9, 13, "$baz", 0 },
            { "Identifier", 14, 16, "a1", 0 },
            { "Identifier", 17, 25, "abc", 1024 },
            { "Identifier", 26, 34, "bcd", 8 },
            { "Identifier", 35, 43, "xyz", 1024 },
            { "Identifier", 44, 49, "caf\xc3\xa9", 0 },
            { "Identifier", 50, 52, "\xcf\x80", 0 },
            { "Identifier", 53, 59, "\xe6\x97\xa5\xe6\x9c\xac", 0 },
            { "Identifier", 60, 64, "\xf0\x9d\x92\x9c", 0 },
            { "Identifier", 65, 69, "done", 0 },
            { "EndOfFile", 69, 69, "done", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "invalid identifier escapes",
        text = "\\u00 \\u{110000} \\x41 a\\u0020",
        tokens = {
            { "Unknown", 0, 1, "", 0 },
            { "Identifier", 1, 4, "u00", 0 },
            { "Unknown", 5, 6, "u00", 0 },
            { "Identifier", 6, 7, "u", 0 },
            { "OpenBraceToken", 7, 8, "u", 0 },
            { "NumericLiteral", 8, 14, "110000", 0 },
            { "CloseBraceToken", 14, 15, "110000", 0 },
            { "Unknown", 16, 17, "110000", 0 },
            { "Identifier", 17, 20, "x41", 0 },
            { "Identifier", 21, 22, "a", 0 },
            { "Unknown", 22, 23, "a", 0 },
            { "Identifier", 23, 28, "u0020", 0 },
            { "EndOfFile", 28, 28, "u0020", 0 },
        },
        errors = {
            { 1127, 0, 1, "Invalid character." },
            { 1127, 5, 1, "Invalid character." },
            { 1127, 16, 1, "Invalid character." },
            { 1127, 22, 1, "Invalid character." },
        },
        directives = { },
    },
    {
        name = "private identifiers",
        text = "#foo #\\u0061b # #1",
        tokens = {
            { "PrivateIdentifier", 0, 4, "#foo", 0 },
            { "PrivateIdentifier", 5, 13, "#ab", 1024 },
            { "PrivateIdentifier", 14, 15, "#", 0 },
            { "PrivateIdentifier", 16, 17, "#", 0 },
            { "NumericLiteral", 17, 18, "1", 0 },
            { "EndOfFile", 18, 18, "1", 0 },
        },
        errors = {
            { 1127, 14, 1, "Invalid character." },
            { 1127, 16, 1, "Invalid character." },
        },
        directives = { },
    },
    {
        name = "decimal numbers",
        text = "0 1 123 1.5 .5 5. 1e10 1E-5 1.5e+3 1_000_000 0.000001 1e21 123456789012345678901234567890",
        tokens = {
            { "NumericLiteral", 0, 1, "0", 0 },
            { "NumericLiteral", 2, 3, "1", 0 },
            { "NumericLiteral", 4, 7, "123", 0 },
            { "NumericLiteral", 8, 11, "1.5", 0 },
            { "NumericLiteral", 12, 14, "0.5", 0 },
            { "NumericLiteral", 15, 17, "5", 0 },
            { "NumericLiteral", 18, 22, "10000000000", 16 },
            { "NumericLiteral", 23, 27, "0.00001", 16 },
            { "NumericLiteral", 28, 34, "1500", 16 },
            { "NumericLiteral", 35, 44, "1000000", 512 },
            { "NumericLiteral", 45, 53, "0.000001", 0 },
            { "NumericLiteral", 54, 58, "1e+21", 16 },
            { "NumericLiteral", 59, 89, "1.2345678901234568e+29", 0 },
            { "EndOfFile", 89, 89, "1.2345678901234568e+29", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "radix numbers",
        text = "0x1F 0XFF 0x_1 0b1010 0B11 0o17 0O7 0x 0b 0o 0b12 0o78 0xFF_FF",
        tokens = {
            { "NumericLiteral", 0, 4, "31", 64 },
            { "NumericLiteral", 5, 9, "255", 64 },
            { "NumericLiteral", 10, 14, "1", 576 },
            { "NumericLiteral", 15, 21, "10", 128 },
            { "NumericLiteral", 22, 26, "3", 128 },
            { "NumericLiteral", 27, 31, "15", 256 },
            { "NumericLiteral", 32, 35, "7", 256 },
            { "NumericLiteral", 36, 38, "0", 64 },
            { "NumericLiteral", 39, 41, "0", 128 },
            { "NumericLiteral", 42, 44, "0", 256 },
            { "NumericLiteral", 45, 48, "1", 128 },
            { "NumericLiteral", 48, 49, "2", 0 },
            { "NumericLiteral", 50, 53, "7", 256 },
            { "NumericLiteral", 53, 54, "8", 0 },
            { "NumericLiteral", 55, 62, "65535", 576 },
            { "EndOfFile", 62, 62, "65535", 0 },
        },
        errors = {
            { 6188, 12, 1, "Numeric separators are not allowed here." },
            { 1125, 38, 0, "Hexadecimal digit expected." },
            { 1177, 41, 0, "Binary digit expected." },
            { 1178, 44, 0, "Octal digit expected." },
        },
        directives = { },
    },
    {
        name = "bigint",
        text = "1n 0x1Fn 0b101n 0o17n 1.5n 1e3n 0n 123456789012345678901234567890n",
        tokens = {
            { "BigIntLiteral", 0, 2, "1n", 0 },
            { "BigIntLiteral", 3, 8, "0x1fn", 64 },
            { "BigIntLiteral", 9, 15, "5n", 128 },
            { "BigIntLiteral", 16, 21, "15n", 256 },
            { "NumericLiteral", 22, 26, "1.5", 0 },
            { "NumericLiteral", 27, 31, "1000", 16 },
            { "BigIntLiteral", 32, 34, "0n", 0 },
            { "BigIntLiteral", 35, 66, "123456789012345678901234567890n", 0 },
            { "EndOfFile", 66, 66, "123456789012345678901234567890n", 0 },
        },
        errors = {
            { 1353, 22, 4, "A bigint literal must be an integer." },
            { 1352, 27, 4, "A bigint literal cannot use exponential notation." },
        },
        directives = { },
    },
    {
        name = "legacy octal and leading zero",
        text = "0777 08 09.5 00 012 -0777",
        tokens = {
            { "NumericLiteral", 0, 4, "511", 32 },
            { "NumericLiteral", 5, 7, "8", 8192 },
            { "NumericLiteral", 8, 12, "9.5", 8192 },
            { "NumericLiteral", 13, 15, "0", 32 },
            { "NumericLiteral", 16, 19, "10", 32 },
            { "MinusToken", 20, 21, "10", 0 },
            { "NumericLiteral", 21, 25, "511", 32 },
            { "EndOfFile", 25, 25, "511", 0 },
        },
        errors = {
            { 1121, 0, 4, "Octal literals are not allowed. Use the syntax '0o777'." },
            { 1489, 5, 2, "Decimals with leading zeros are not allowed." },
            { 1489, 8, 4, "Decimals with leading zeros are not allowed." },
            { 1121, 13, 2, "Octal literals are not allowed. Use the syntax '0o0'." },
            { 1121, 16, 3, "Octal literals are not allowed. Use the syntax '0o12'." },
            { 1121, 20, 5, "Octal literals are not allowed. Use the syntax '-0o777'." },
        },
        directives = { },
    },
    {
        name = "numeric separators errors",
        text = "1__0 1_ 0_1 1._5 1e_5 0x__1 0b1__0",
        tokens = {
            { "NumericLiteral", 0, 4, "10", 16896 },
            { "NumericLiteral", 5, 7, "1", 16896 },
            { "NumericLiteral", 8, 11, "1", 16896 },
            { "NumericLiteral", 12, 16, "1.5", 16896 },
            { "NumericLiteral", 17, 21, "100000", 16912 },
            { "NumericLiteral", 22, 27, "1", 576 },
            { "NumericLiteral", 28, 34, "2", 640 },
            { "EndOfFile", 34, 34, "2", 0 },
        },
        errors = {
            { 6189, 2, 1, "Multiple consecutive numeric separators are not permitted." },
            { 6188, 6, 1, "Numeric separators are not allowed here." },
            { 6188, 9, 1, "Numeric separators are not allowed here." },
            { 6188, 14, 1, "Numeric separators are not allowed here." },
            { 6188, 19, 1, "Numeric separators are not allowed here." },
            { 6188, 24, 1, "Numeric separators are not allowed here." },
            { 6188, 25, 1, "Numeric separators are not allowed here." },
            { 6189, 32, 1, "Multiple consecutive numeric separators are not permitted." },
        },
        directives = { },
    },
    {
        name = "identifier after number",
        text = "3in 1x 2n",
        tokens = {
            { "NumericLiteral", 0, 1, "3", 0 },
            { "InKeyword", 1, 3, "in", 0 },
            { "NumericLiteral", 4, 5, "1", 0 },
            { "Identifier", 5, 6, "x", 0 },
            { "BigIntLiteral", 7, 9, "2n", 0 },
            { "EndOfFile", 9, 9, "2n", 0 },
        },
        errors = {
            { 1351, 1, 2, "An identifier or keyword cannot immediately follow a numeric literal." },
            { 1351, 5, 1, "An identifier or keyword cannot immediately follow a numeric literal." },
        },
        directives = { },
    },
    {
        name = "strings",
        text = "'single' \"double\" 'it\\'s' \"a\\nb\\tc\" '\\x41\\u0042\\u{43}' '\\0' '\\v\\f\\b\\r' 'line\\\x0acont' ''",
        tokens = {
            { "StringLiteral", 0, 8, "single", 65536 },
            { "StringLiteral", 9, 17, "double", 0 },
            { "StringLiteral", 18, 25, "it's", 65536 },
            { "StringLiteral", 26, 35, "a\x0ab\x09c", 0 },
            { "StringLiteral", 36, 54, "ABC", 70664 },
            { "StringLiteral", 55, 59, "\x00", 65536 },
            { "StringLiteral", 60, 70, "\x0b\x0c\x08\x0d", 65536 },
            { "StringLiteral", 71, 83, "linecont", 65536 },
            { "StringLiteral", 84, 86, "", 65536 },
            { "EndOfFile", 86, 86, "", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "string octal and invalid escapes",
        text = "'\\01' '\\777' '\\8' '\\9' '\\x4' '\\u12' '\\u{FFFFFF}' '\\u{12'",
        tokens = {
            { "StringLiteral", 0, 5, "\x01", 67584 },
            { "StringLiteral", 6, 12, "?7", 67584 },
            { "StringLiteral", 13, 17, "8", 67584 },
            { "StringLiteral", 18, 22, "9", 67584 },
            { "StringLiteral", 23, 28, "\\x4", 67584 },
            { "StringLiteral", 29, 35, "\\u12", 68608 },
            { "StringLiteral", 36, 48, "\\u{FFFFFF}", 67584 },
            { "StringLiteral", 49, 56, "\\u{12", 67584 },
            { "EndOfFile", 56, 56, "\\u{12", 0 },
        },
        errors = {
            { 1487, 1, 3, "Octal escape sequences are not allowed. Use the syntax '\\x01'." },
            { 1487, 7, 3, "Octal escape sequences are not allowed. Use the syntax '\\x3f'." },
            { 1488, 14, 2, "Escape sequence '\\8' is not allowed." },
            { 1488, 19, 2, "Escape sequence '\\9' is not allowed." },
            { 1125, 27, 0, "Hexadecimal digit expected." },
            { 1125, 34, 0, "Hexadecimal digit expected." },
            { 1198, 40, 6, "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive." },
            { 1199, 55, 0, "Unterminated Unicode escape sequence." },
        },
        directives = { },
    },
    {
        name = "unterminated string",
        text = "'abc\x0adef' \"xyz",
        tokens = {
            { "StringLiteral", 0, 4, "abc", 65540 },
            { "Identifier", 5, 8, "def", 1 },
            { "StringLiteral", 8, 14, " \"xyz", 65540 },
            { "EndOfFile", 14, 14, " \"xyz", 0 },
        },
        errors = {
            { 1002, 4, 0, "Unterminated string literal." },
            { 1002, 14, 0, "Unterminated string literal." },
        },
        directives = { },
    },
    {
        name = "lone surrogates",
        text = "\"\xf0\x9f\xa6\x80\\ud7ff\\ud800\\ud801\\uD83E\\uDD80\" '\\u{D83E}\\u{DD80}' '\\uD83E\\u{DD80}'",
        tokens = {
            { "StringLiteral", 0, 36, "\xf0\x9f\xa6\x80\xed\x9f\xbf\xed\xa0\x80\xed\xa0\x81\xf0\x9f\xa6\x80", 1024 },
            { "StringLiteral", 37, 55, "\xf0\x9f\xa6\x80", 65544 },
            { "StringLiteral", 56, 72, "\xf0\x9f\xa6\x80", 66568 },
            { "EndOfFile", 72, 72, "\xf0\x9f\xa6\x80", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "templates",
        text = "`plain` `a${b}c${d}e` `\\n\\u0041` `line\x0d\x0abreak` `unterminated",
        mode = "rescan",
        tokens = {
            { "NoSubstitutionTemplateLiteral", 0, 7, "plain", 0 },
            { "TemplateHead", 8, 12, "a", 0 },
            { "Identifier", 12, 13, "b", 0 },
            { "TemplateMiddle", 13, 17, "c", 0 },
            { "Identifier", 17, 18, "d", 0 },
            { "TemplateTail", 18, 21, "e", 0 },
            { "NoSubstitutionTemplateLiteral", 22, 32, "\x0aA", 1024 },
            { "NoSubstitutionTemplateLiteral", 33, 46, "line\x0abreak", 0 },
            { "NoSubstitutionTemplateLiteral", 47, 60, "unterminated", 4 },
            { "EndOfFile", 60, 60, "unterminated", 0 },
        },
        errors = {
            { 1160, 60, 0, "Unterminated template literal." },
        },
        directives = { },
    },
    {
        name = "template invalid escapes",
        text = "`\\u{110000}` `\\xZ` `\\01`",
        mode = "rescan",
        tokens = {
            { "NoSubstitutionTemplateLiteral", 0, 12, "\\u{110000}", 2048 },
            { "NoSubstitutionTemplateLiteral", 13, 18, "\\xZ", 2048 },
            { "NoSubstitutionTemplateLiteral", 19, 24, "\\01", 2048 },
            { "EndOfFile", 24, 24, "\\01", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "regex basic",
        text = "/abc/g; x = /[/]/; y = /a\\/b/gimsuy; z = /(?<name>a)\\k<name>/d",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 6, "/abc/g", 0 },
            { "SemicolonToken", 6, 7, "/abc/g", 0 },
            { "Identifier", 8, 9, "x", 0 },
            { "EqualsToken", 10, 11, "x", 0 },
            { "RegularExpressionLiteral", 12, 17, "/[/]/", 0 },
            { "SemicolonToken", 17, 18, "/[/]/", 0 },
            { "Identifier", 19, 20, "y", 0 },
            { "EqualsToken", 21, 22, "y", 0 },
            { "RegularExpressionLiteral", 23, 35, "/a\\/b/gimsuy", 0 },
            { "SemicolonToken", 35, 36, "/a\\/b/gimsuy", 0 },
            { "Identifier", 37, 38, "z", 0 },
            { "EqualsToken", 39, 40, "z", 0 },
            { "RegularExpressionLiteral", 41, 62, "/(?<name>a)\\k<name>/d", 0 },
            { "EndOfFile", 62, 62, "/(?<name>a)\\k<name>/d", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "regex flags errors",
        text = "/a/gg; /a/uv; /a/x; /a/dsv",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 5, "/a/gg", 0 },
            { "SemicolonToken", 5, 6, "/a/gg", 0 },
            { "RegularExpressionLiteral", 7, 12, "/a/uv", 0 },
            { "SemicolonToken", 12, 13, "/a/uv", 0 },
            { "RegularExpressionLiteral", 14, 18, "/a/x", 0 },
            { "SemicolonToken", 18, 19, "/a/x", 0 },
            { "RegularExpressionLiteral", 20, 26, "/a/dsv", 0 },
            { "EndOfFile", 26, 26, "/a/dsv", 0 },
        },
        errors = {
            { 1500, 4, 1, "Duplicate regular expression flag." },
            { 1502, 11, 1, "The Unicode (u) flag and the Unicode Sets (v) flag cannot be set simultaneously." },
            { 1499, 17, 1, "Unknown regular expression flag." },
        },
        directives = { },
    },
    {
        name = "regex flags es5",
        text = "/a/d; /a/s; /a/v; /(?<n>a)/; /(?i:a)/",
        mode = "rescan",
        target = 1,
        tokens = {
            { "RegularExpressionLiteral", 0, 4, "/a/d", 0 },
            { "SemicolonToken", 4, 5, "/a/d", 0 },
            { "RegularExpressionLiteral", 6, 10, "/a/s", 0 },
            { "SemicolonToken", 10, 11, "/a/s", 0 },
            { "RegularExpressionLiteral", 12, 16, "/a/v", 0 },
            { "SemicolonToken", 16, 17, "/a/v", 0 },
            { "RegularExpressionLiteral", 18, 27, "/(?<n>a)/", 0 },
            { "SemicolonToken", 27, 28, "/(?<n>a)/", 0 },
            { "RegularExpressionLiteral", 29, 37, "/(?i:a)/", 0 },
            { "EndOfFile", 37, 37, "/(?i:a)/", 0 },
        },
        errors = {
            { 1501, 3, 1, "This regular expression flag is only available when targeting 'es2022' or later." },
            { 1501, 9, 1, "This regular expression flag is only available when targeting 'es2018' or later." },
            { 1501, 15, 1, "This regular expression flag is only available when targeting 'es2024' or later." },
            { 1503, 21, 3, "Named capturing groups are only available when targeting 'ES2018' or later." },
            { 18062, 32, 1, "Regular expression pattern modifiers are only available when targeting 'es2025' or later." },
        },
        directives = { },
    },
    {
        name = "regex unterminated",
        text = "x = /abc\x0ay = /[a-z)] ;  ",
        mode = "rescan",
        tokens = {
            { "Identifier", 0, 1, "x", 0 },
            { "EqualsToken", 2, 3, "x", 0 },
            { "RegularExpressionLiteral", 4, 8, "/abc", 4 },
            { "Identifier", 9, 10, "y", 1 },
            { "EqualsToken", 11, 12, "y", 0 },
            { "RegularExpressionLiteral", 13, 20, "/[a-z)]", 4 },
            { "SemicolonToken", 21, 22, "/[a-z)]", 0 },
            { "EndOfFile", 24, 24, "/[a-z)]", 0 },
        },
        errors = {
            { 1161, 4, 4, "Unterminated regular expression literal." },
            { 1161, 13, 7, "Unterminated regular expression literal." },
        },
        directives = { },
    },
    {
        name = "regex quantifiers",
        text = "/a{2,1}/; /a{,5}/u; /*/; /a**/; /a{2}?/; /{/; /}/u; /a{1/u",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 8, "/a{2,1}/", 0 },
            { "SemicolonToken", 8, 9, "/a{2,1}/", 0 },
            { "RegularExpressionLiteral", 10, 18, "/a{,5}/u", 0 },
            { "SemicolonToken", 18, 19, "/a{,5}/u", 0 },
            { "SemicolonToken", 30, 31, "/a{,5}/u", 0 },
            { "RegularExpressionLiteral", 32, 39, "/a{2}?/", 0 },
            { "SemicolonToken", 39, 40, "/a{2}?/", 0 },
            { "RegularExpressionLiteral", 41, 44, "/{/", 0 },
            { "SemicolonToken", 44, 45, "/{/", 0 },
            { "RegularExpressionLiteral", 46, 50, "/}/u", 0 },
            { "SemicolonToken", 50, 51, "/}/u", 0 },
            { "RegularExpressionLiteral", 52, 58, "/a{1/u", 0 },
            { "EndOfFile", 58, 58, "/a{1/u", 0 },
        },
        errors = {
            { 1506, 3, 3, "Numbers out of order in quantifier." },
            { 1505, 13, 0, "Incomplete quantifier. Digit expected." },
            { 1508, 47, 1, "Unexpected '}'. Did you mean to escape it with backslash?" },
            { 1005, 56, 0, "'}' expected." },
        },
        directives = { },
    },
    {
        name = "regex groups",
        text = "/(?:a)(?=b)(?!c)(?<=d)(?<!e)/; /(?<a>x)|(?<a>y)/; /(?<a>x)(?<a>y)/; /\\k<b>(?<bb>c)/; /(a)\\2/; /\\1/",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 29, "/(?:a)(?=b)(?!c)(?<=d)(?<!e)/", 0 },
            { "SemicolonToken", 29, 30, "/(?:a)(?=b)(?!c)(?<=d)(?<!e)/", 0 },
            { "RegularExpressionLiteral", 31, 48, "/(?<a>x)|(?<a>y)/", 0 },
            { "SemicolonToken", 48, 49, "/(?<a>x)|(?<a>y)/", 0 },
            { "RegularExpressionLiteral", 50, 66, "/(?<a>x)(?<a>y)/", 0 },
            { "SemicolonToken", 66, 67, "/(?<a>x)(?<a>y)/", 0 },
            { "RegularExpressionLiteral", 68, 83, "/\\k<b>(?<bb>c)/", 0 },
            { "SemicolonToken", 83, 84, "/\\k<b>(?<bb>c)/", 0 },
            { "RegularExpressionLiteral", 85, 92, "/(a)\\2/", 0 },
            { "SemicolonToken", 92, 93, "/(a)\\2/", 0 },
            { "RegularExpressionLiteral", 94, 98, "/\\1/", 0 },
            { "EndOfFile", 98, 98, "/\\1/", 0 },
        },
        errors = {
            { 1515, 61, 1, "Named capturing groups with the same name must be mutually exclusive to each other." },
            { 1532, 72, 1, "There is no capturing group named 'b' in this regular expression." },
            { 1533, 90, 1, "This backreference refers to a group that does not exist. There are only 1 capturing groups in this regular expression." },
            { 1534, 96, 1, "This backreference refers to a group that does not exist. There are no capturing groups in this regular expression." },
        },
        directives = { },
    },
    {
        name = "regex escapes",
        text = "/\\d\\D\\s\\S\\w\\W\\b\\B\\cA\\c1\\x41\\u0041\\u{41}/u; /\\q/v; /\\k/u; /\\-/; /\\a/u; /\\8/",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 41, "/\\d\\D\\s\\S\\w\\W\\b\\B\\cA\\c1\\x41\\u0041\\u{41}/u", 0 },
            { "SemicolonToken", 41, 42, "/\\d\\D\\s\\S\\w\\W\\b\\B\\cA\\c1\\x41\\u0041\\u{41}/u", 0 },
            { "RegularExpressionLiteral", 43, 48, "/\\q/v", 0 },
            { "SemicolonToken", 48, 49, "/\\q/v", 0 },
            { "RegularExpressionLiteral", 50, 55, "/\\k/u", 0 },
            { "SemicolonToken", 55, 56, "/\\k/u", 0 },
            { "RegularExpressionLiteral", 57, 61, "/\\-/", 0 },
            { "SemicolonToken", 61, 62, "/\\-/", 0 },
            { "RegularExpressionLiteral", 63, 68, "/\\a/u", 0 },
            { "SemicolonToken", 68, 69, "/\\a/u", 0 },
            { "RegularExpressionLiteral", 70, 74, "/\\8/", 0 },
            { "EndOfFile", 74, 74, "/\\8/", 0 },
        },
        errors = {
            { 1512, 20, 2, "'\\c' must be followed by an ASCII letter." },
            { 1511, 44, 2, "'\\q' is only available inside character class." },
            { 1510, 51, 2, "'\\k' must be followed by a capturing group name enclosed in angle brackets." },
            { 1535, 64, 2, "This character cannot be escaped in a regular expression." },
            { 1534, 72, 1, "This backreference refers to a group that does not exist. There are no capturing groups in this regular expression." },
        },
        directives = { },
    },
    {
        name = "regex classes",
        text = "/[a-z]/; /[z-a]/; /[\\d-z]/u; /[^]/; /[\\b]/",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 7, "/[a-z]/", 0 },
            { "SemicolonToken", 7, 8, "/[a-z]/", 0 },
            { "RegularExpressionLiteral", 9, 16, "/[z-a]/", 0 },
            { "SemicolonToken", 16, 17, "/[z-a]/", 0 },
            { "RegularExpressionLiteral", 18, 27, "/[\\d-z]/u", 0 },
            { "SemicolonToken", 27, 28, "/[\\d-z]/u", 0 },
            { "RegularExpressionLiteral", 29, 34, "/[^]/", 0 },
            { "SemicolonToken", 34, 35, "/[^]/", 0 },
            { "RegularExpressionLiteral", 36, 42, "/[\\b]/", 0 },
            { "EndOfFile", 42, 42, "/[\\b]/", 0 },
        },
        errors = {
            { 1517, 11, 3, "Range out of order in character class." },
            { 1516, 20, 2, "A character class range must not be bounded by another character class." },
        },
        directives = { },
    },
    {
        name = "regex unicode property",
        text = "/\\p{L}/u; /\\p{Letter}/u; /\\P{Script=Greek}/u; /\\p{Scirpt=Greek}/u; /\\p{Script=Grek}/u; /\\p{Lettr}/u; /\\p{RGI_Emoji}/u; /\\p{RGI_Emoji}/v; /\\P{RGI_Emoji}/v; /\\p{L}/; /\\p/u; /\\p{}/u; /\\p{=x}/u",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 8, "/\\p{L}/u", 0 },
            { "SemicolonToken", 8, 9, "/\\p{L}/u", 0 },
            { "RegularExpressionLiteral", 10, 23, "/\\p{Letter}/u", 0 },
            { "SemicolonToken", 23, 24, "/\\p{Letter}/u", 0 },
            { "RegularExpressionLiteral", 25, 44, "/\\P{Script=Greek}/u", 0 },
            { "SemicolonToken", 44, 45, "/\\P{Script=Greek}/u", 0 },
            { "RegularExpressionLiteral", 46, 65, "/\\p{Scirpt=Greek}/u", 0 },
            { "SemicolonToken", 65, 66, "/\\p{Scirpt=Greek}/u", 0 },
            { "RegularExpressionLiteral", 67, 85, "/\\p{Script=Grek}/u", 0 },
            { "SemicolonToken", 85, 86, "/\\p{Script=Grek}/u", 0 },
            { "RegularExpressionLiteral", 87, 99, "/\\p{Lettr}/u", 0 },
            { "SemicolonToken", 99, 100, "/\\p{Lettr}/u", 0 },
            { "RegularExpressionLiteral", 101, 117, "/\\p{RGI_Emoji}/u", 0 },
            { "SemicolonToken", 117, 118, "/\\p{RGI_Emoji}/u", 0 },
            { "RegularExpressionLiteral", 119, 135, "/\\p{RGI_Emoji}/v", 0 },
            { "SemicolonToken", 135, 136, "/\\p{RGI_Emoji}/v", 0 },
            { "RegularExpressionLiteral", 137, 153, "/\\P{RGI_Emoji}/v", 0 },
            { "SemicolonToken", 153, 154, "/\\P{RGI_Emoji}/v", 0 },
            { "RegularExpressionLiteral", 155, 162, "/\\p{L}/", 0 },
            { "SemicolonToken", 162, 163, "/\\p{L}/", 0 },
            { "RegularExpressionLiteral", 164, 169, "/\\p/u", 0 },
            { "SemicolonToken", 169, 170, "/\\p/u", 0 },
            { "RegularExpressionLiteral", 171, 178, "/\\p{}/u", 0 },
            { "SemicolonToken", 178, 179, "/\\p{}/u", 0 },
            { "RegularExpressionLiteral", 180, 189, "/\\p{=x}/u", 0 },
            { "EndOfFile", 189, 189, "/\\p{=x}/u", 0 },
        },
        errors = {
            { 1524, 50, 6, "Unknown Unicode property name." },
            { 1369, 50, 6, "Did you mean 'Script'?" },
            { 1529, 91, 5, "Unknown Unicode property name or value." },
            { 1369, 91, 5, "Did you mean 'Letter'?" },
            { 1528, 105, 9, "Any Unicode property that would possibly match more than a single character is only available when the Unicode Sets (v) flag is set." },
            { 1518, 141, 9, "Anything that would possibly match more than a single character is invalid inside a negated character class." },
            { 1530, 156, 5, "Unicode property value expressions are only available when the Unicode (u) flag or the Unicode Sets (v) flag is set." },
            { 1531, 165, 2, "'\\p' must be followed by a Unicode property value expression enclosed in braces." },
            { 1527, 175, 0, "Expected a Unicode property name or value." },
            { 1523, 184, 0, "Expected a Unicode property name." },
        },
        directives = { },
    },
    {
        name = "regex unicode sets",
        text = "/[a&&b]/v; /[a--b]/v; /[[a-z]--[aeiou]]/v; /[a&&&b]/v; /[\\q{abc|d}]/v; /[^\\q{ab}]/v; /[a-z--b]/v; /[&&a]/v; /[a--b&&c]/v; /[(]/v; /[aa]/v; /[!!]/v",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 9, "/[a&&b]/v", 0 },
            { "SemicolonToken", 9, 10, "/[a&&b]/v", 0 },
            { "RegularExpressionLiteral", 11, 20, "/[a--b]/v", 0 },
            { "SemicolonToken", 20, 21, "/[a--b]/v", 0 },
            { "RegularExpressionLiteral", 22, 41, "/[[a-z]--[aeiou]]/v", 0 },
            { "SemicolonToken", 41, 42, "/[[a-z]--[aeiou]]/v", 0 },
            { "RegularExpressionLiteral", 43, 53, "/[a&&&b]/v", 0 },
            { "SemicolonToken", 53, 54, "/[a&&&b]/v", 0 },
            { "RegularExpressionLiteral", 55, 69, "/[\\q{abc|d}]/v", 0 },
            { "SemicolonToken", 69, 70, "/[\\q{abc|d}]/v", 0 },
            { "RegularExpressionLiteral", 71, 83, "/[^\\q{ab}]/v", 0 },
            { "SemicolonToken", 83, 84, "/[^\\q{ab}]/v", 0 },
            { "RegularExpressionLiteral", 85, 96, "/[a-z--b]/v", 0 },
            { "SemicolonToken", 96, 97, "/[a-z--b]/v", 0 },
            { "RegularExpressionLiteral", 98, 106, "/[&&a]/v", 0 },
            { "SemicolonToken", 106, 107, "/[&&a]/v", 0 },
            { "RegularExpressionLiteral", 108, 120, "/[a--b&&c]/v", 0 },
            { "SemicolonToken", 120, 121, "/[a--b&&c]/v", 0 },
            { "RegularExpressionLiteral", 122, 128, "/[(]/v", 0 },
            { "SemicolonToken", 128, 129, "/[(]/v", 0 },
            { "RegularExpressionLiteral", 130, 137, "/[aa]/v", 0 },
            { "SemicolonToken", 137, 138, "/[aa]/v", 0 },
            { "RegularExpressionLiteral", 139, 146, "/[!!]/v", 0 },
            { "EndOfFile", 146, 146, "/[!!]/v", 0 },
        },
        errors = {
            { 1508, 48, 1, "Unexpected '&'. Did you mean to escape it with backslash?" },
            { 1518, 74, 6, "Anything that would possibly match more than a single character is invalid inside a negated character class." },
            { 1519, 90, 2, "Operators must not be mixed within a character class. Wrap it in a nested class instead." },
            { 1520, 100, 0, "Expected a class set operand." },
            { 1519, 114, 2, "Operators must not be mixed within a character class. Wrap it in a nested class instead." },
            { 1508, 124, 1, "Unexpected '('. Did you mean to escape it with backslash?" },
            { 1522, 141, 2, "A character class must not contain a reserved double punctuator. Did you mean to escape it with backslash?" },
        },
        directives = { },
    },
    {
        name = "regex modifiers",
        text = "/(?i:a)/; /(?-i:a)/; /(?i-s:a)/; /(?-:a)/; /(?g:a)/; /(?ii:a)/; /(?x:a)/",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 8, "/(?i:a)/", 0 },
            { "SemicolonToken", 8, 9, "/(?i:a)/", 0 },
            { "RegularExpressionLiteral", 10, 19, "/(?-i:a)/", 0 },
            { "SemicolonToken", 19, 20, "/(?-i:a)/", 0 },
            { "RegularExpressionLiteral", 21, 31, "/(?i-s:a)/", 0 },
            { "SemicolonToken", 31, 32, "/(?i-s:a)/", 0 },
            { "RegularExpressionLiteral", 33, 41, "/(?-:a)/", 0 },
            { "SemicolonToken", 41, 42, "/(?-:a)/", 0 },
            { "RegularExpressionLiteral", 43, 51, "/(?g:a)/", 0 },
            { "SemicolonToken", 51, 52, "/(?g:a)/", 0 },
            { "RegularExpressionLiteral", 53, 62, "/(?ii:a)/", 0 },
            { "SemicolonToken", 62, 63, "/(?ii:a)/", 0 },
            { "RegularExpressionLiteral", 64, 72, "/(?x:a)/", 0 },
            { "EndOfFile", 72, 72, "/(?x:a)/", 0 },
        },
        errors = {
            { 1504, 36, 1, "Subpattern flags must be present when there is a minus sign." },
            { 1509, 46, 1, "This regular expression flag cannot be toggled within a subpattern." },
            { 1500, 57, 1, "Duplicate regular expression flag." },
            { 1499, 67, 1, "Unknown regular expression flag." },
        },
        directives = { },
    },
    {
        name = "regex surrogates",
        text = "/[\xf0\x9f\x98\x80-\xf0\x9f\x98\x81]/; /[\xf0\x9f\x98\x81-\xf0\x9f\x98\x80]/u; /\\ud83d\\ude00/u; /[\\ud83d\\ude01-\\ud83d\\ude00]/u",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 13, "/[\xf0\x9f\x98\x80-\xf0\x9f\x98\x81]/", 0 },
            { "SemicolonToken", 13, 14, "/[\xf0\x9f\x98\x80-\xf0\x9f\x98\x81]/", 0 },
            { "RegularExpressionLiteral", 15, 29, "/[\xf0\x9f\x98\x81-\xf0\x9f\x98\x80]/u", 0 },
            { "SemicolonToken", 29, 30, "/[\xf0\x9f\x98\x81-\xf0\x9f\x98\x80]/u", 0 },
            { "RegularExpressionLiteral", 31, 46, "/\\ud83d\\ude00/u", 0 },
            { "SemicolonToken", 46, 47, "/\\ud83d\\ude00/u", 0 },
            { "RegularExpressionLiteral", 48, 78, "/[\\ud83d\\ude01-\\ud83d\\ude00]/u", 0 },
            { "EndOfFile", 78, 78, "/[\\ud83d\\ude01-\\ud83d\\ude00]/u", 0 },
        },
        errors = {
            { 1517, 2, 5, "Range out of order in character class." },
            { 1517, 17, 9, "Range out of order in character class." },
            { 1517, 50, 25, "Range out of order in character class." },
        },
        directives = { },
    },
    {
        name = "comments with trivia",
        text = "a // line\x0a/* block */ b /** jsdoc @deprecated */ c\x0d\x0a  \x09 d /* unterminated",
        trivia = true,
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "WhitespaceTrivia", 1, 2, "a", 0 },
            { "SingleLineCommentTrivia", 2, 9, "a", 0 },
            { "NewLineTrivia", 9, 10, "a", 1 },
            { "MultiLineCommentTrivia", 10, 21, "a", 0 },
            { "WhitespaceTrivia", 21, 22, "a", 0 },
            { "Identifier", 22, 23, "b", 0 },
            { "WhitespaceTrivia", 23, 24, "b", 0 },
            { "MultiLineCommentTrivia", 24, 48, "b", 131074 },
            { "WhitespaceTrivia", 48, 49, "b", 0 },
            { "Identifier", 49, 50, "c", 0 },
            { "NewLineTrivia", 50, 52, "c", 1 },
            { "WhitespaceTrivia", 52, 56, "c", 0 },
            { "Identifier", 56, 57, "d", 0 },
            { "WhitespaceTrivia", 57, 58, "d", 0 },
            { "MultiLineCommentTrivia", 58, 73, "d", 4 },
            { "EndOfFile", 73, 73, "d", 0 },
        },
        errors = {
            { 1010, 73, 0, "'*/' expected." },
        },
        directives = { },
    },
    {
        name = "comments skipped",
        text = "/** @see foo @link bar */ x // trailing\x0a/* multi\x0aline */ y",
        tokens = {
            { "Identifier", 26, 27, "x", 262146 },
            { "Identifier", 57, 58, "y", 1 },
            { "EndOfFile", 58, 58, "y", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "comment directives",
        text = "// @ts-ignore\x0ax\x0a/* @ts-expect-error */\x0ay\x0a/// @ts-expect-error extra\x0a//@ts-ignorefoo\x0a// not @ts-ignore\x0a/**\x0a * @ts-ignore\x0a */\x0az",
        tokens = {
            { "Identifier", 14, 15, "x", 1 },
            { "Identifier", 39, 40, "y", 1 },
            { "Identifier", 124, 125, "z", 3 },
            { "EndOfFile", 125, 125, "z", 0 },
        },
        errors = {
        },
        directives = { { 0, 13, 2 }, { 16, 38, 1 }, { 41, 67, 1 }, { 68, 83, 2 } },
    },
    {
        name = "conflict markers",
        text = "a\x0a<<<<<<< HEAD\x0ab\x0a=======\x0ac\x0a>>>>>>> branch\x0ad\x0a||||||| base\x0ae",
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "Identifier", 15, 16, "b", 1 },
            { "Identifier", 42, 43, "d", 1 },
            { "EndOfFile", 58, 58, "d", 1 },
        },
        errors = {
            { 1185, 2, 7, "Merge conflict marker encountered." },
            { 1185, 17, 7, "Merge conflict marker encountered." },
            { 1185, 27, 7, "Merge conflict marker encountered." },
            { 1185, 44, 7, "Merge conflict marker encountered." },
        },
        directives = { },
    },
    {
        name = "conflict markers trivia",
        text = "<<<<<<< HEAD\x0ax\x0a=======\x0ay\x0a>>>>>>> b\x0a",
        trivia = true,
        tokens = {
            { "ConflictMarkerTrivia", 0, 12, "", 0 },
            { "NewLineTrivia", 12, 13, "", 1 },
            { "Identifier", 13, 14, "x", 0 },
            { "NewLineTrivia", 14, 15, "x", 1 },
            { "ConflictMarkerTrivia", 15, 25, "x", 0 },
            { "ConflictMarkerTrivia", 25, 34, "x", 0 },
            { "NewLineTrivia", 34, 35, "x", 1 },
            { "EndOfFile", 35, 35, "x", 0 },
        },
        errors = {
            { 1185, 0, 7, "Merge conflict marker encountered." },
            { 1185, 15, 7, "Merge conflict marker encountered." },
            { 1185, 25, 7, "Merge conflict marker encountered." },
        },
        directives = { },
    },
    {
        name = "shebang",
        text = "#!/usr/bin/env node\x0ax #! y",
        tokens = {
            { "Identifier", 20, 21, "x", 1 },
            { "Unknown", 22, 23, "x", 0 },
            { "ExclamationToken", 23, 24, "x", 0 },
            { "Identifier", 25, 26, "y", 0 },
            { "EndOfFile", 26, 26, "y", 0 },
        },
        errors = {
            { 18026, 22, 2, "'#!' can only be used at the start of a file." },
        },
        directives = { },
    },
    {
        name = "whitespace and newlines",
        text = "a\xc2\xa0\xe2\x80\xa8b\xe3\x80\x80c\xc2\x85d\xef\xbb\xbfe\x0d\x0df\x0a",
        trivia = true,
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "WhitespaceTrivia", 1, 3, "a", 0 },
            { "Identifier", 6, 7, "b", 1 },
            { "WhitespaceTrivia", 7, 10, "b", 0 },
            { "Identifier", 10, 11, "c", 0 },
            { "Identifier", 13, 14, "d", 0 },
            { "WhitespaceTrivia", 14, 17, "d", 0 },
            { "Identifier", 17, 18, "e", 0 },
            { "NewLineTrivia", 18, 19, "e", 1 },
            { "NewLineTrivia", 19, 20, "e", 1 },
            { "Identifier", 20, 21, "f", 0 },
            { "NewLineTrivia", 21, 22, "f", 1 },
            { "EndOfFile", 22, 22, "f", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "invalid characters",
        text = "a \x01 \xc2\xa7 \\ b",
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "Unknown", 2, 3, "a", 0 },
            { "Unknown", 4, 6, "a", 0 },
            { "Unknown", 7, 8, "a", 0 },
            { "Identifier", 9, 10, "b", 0 },
            { "EndOfFile", 10, 10, "b", 0 },
        },
        errors = {
            { 1127, 2, 1, "Invalid character." },
            { 1127, 4, 2, "Invalid character." },
            { 1127, 7, 1, "Invalid character." },
        },
        directives = { },
    },
    {
        name = "binary file",
        text = "ab\xc3\xbf\xc3\xbecd",
        tokens = {
            { "Identifier", 0, 8, "ab\xc3\xbf\xc3\xbecd", 0 },
            { "EndOfFile", 8, 8, "ab\xc3\xbf\xc3\xbecd", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "jsx text",
        text = "hello world</div>  \x0a  <span>{x}</span> a > b } c",
        mode = "jsx",
        jsx = true,
        tokens = {
            { "JsxText", 0, 11, "hello world", 0 },
            { "LessThanSlashToken", 11, 13, "hello world", 0 },
            { "JsxText", 13, 22, "div>  \x0a  ", 0 },
            { "LessThanToken", 22, 23, "div>  \x0a  ", 0 },
            { "JsxText", 23, 28, "span>", 0 },
            { "OpenBraceToken", 28, 29, "span>", 0 },
            { "JsxText", 29, 31, "x}", 0 },
            { "LessThanSlashToken", 31, 33, "x}", 0 },
            { "JsxText", 33, 48, "span> a > b } c", 0 },
            { "EndOfFile", 48, 48, "span> a > b } c", 0 },
        },
        errors = {
            { 1382, 16, 1, "Unexpected token. Did you mean `{'>'}` or `&gt;`?" },
            { 1382, 27, 1, "Unexpected token. Did you mean `{'>'}` or `&gt;`?" },
            { 1381, 30, 1, "Unexpected token. Did you mean `{'}'}` or `&rbrace;`?" },
            { 1382, 37, 1, "Unexpected token. Did you mean `{'>'}` or `&gt;`?" },
            { 1382, 41, 1, "Unexpected token. Did you mean `{'>'}` or `&gt;`?" },
            { 1381, 45, 1, "Unexpected token. Did you mean `{'}'}` or `&rbrace;`?" },
        },
        directives = { },
    },
    {
        name = "jsx whitespace",
        text = "   \x0a   <a/>",
        mode = "jsx",
        jsx = true,
        tokens = {
            { "JsxTextAllWhiteSpaces", 0, 7, "   \x0a   ", 0 },
            { "LessThanToken", 7, 8, "   \x0a   ", 0 },
            { "JsxText", 8, 11, "a/>", 0 },
            { "EndOfFile", 11, 11, "a/>", 0 },
        },
        errors = {
            { 1382, 10, 1, "Unexpected token. Did you mean `{'>'}` or `&gt;`?" },
        },
        directives = { },
    },
    {
        name = "jsx identifiers",
        text = "<my-element data-foo:bar></my-element>",
        mode = "rescan",
        jsx = true,
        tokens = {
            { "LessThanToken", 0, 1, "", 0 },
            { "Identifier", 1, 11, "my-element", 0 },
            { "Identifier", 12, 20, "data-foo", 0 },
            { "ColonToken", 20, 21, "data-foo", 0 },
            { "Identifier", 21, 24, "bar", 0 },
            { "GreaterThanToken", 24, 25, "bar", 0 },
            { "LessThanSlashToken", 25, 27, "bar", 0 },
            { "Identifier", 27, 37, "my-element", 0 },
            { "GreaterThanToken", 37, 38, "my-element", 0 },
            { "EndOfFile", 38, 38, "my-element", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "jsx less than slash",
        text = "a </ b </* c */",
        jsx = true,
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "LessThanSlashToken", 2, 4, "a", 0 },
            { "Identifier", 5, 6, "b", 0 },
            { "LessThanToken", 7, 8, "b", 0 },
            { "EndOfFile", 15, 15, "b", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "jsdoc tokens",
        text = "@param {string} name - the name\x0a * @returns {number[]} `x` #a .b ,c =d <e> (f) \\u0061g h-i\x0d\x0a",
        mode = "jsdoc",
        tokens = {
            { "AtToken", 0, 1, "", 0 },
            { "Identifier", 1, 6, "param", 0 },
            { "WhitespaceTrivia", 6, 7, "param", 0 },
            { "OpenBraceToken", 7, 8, "param", 0 },
            { "StringKeyword", 8, 14, "string", 0 },
            { "CloseBraceToken", 14, 15, "string", 0 },
            { "WhitespaceTrivia", 15, 16, "string", 0 },
            { "Identifier", 16, 20, "name", 0 },
            { "WhitespaceTrivia", 20, 21, "name", 0 },
            { "Unknown", 21, 22, "name", 0 },
            { "WhitespaceTrivia", 22, 23, "name", 0 },
            { "Identifier", 23, 26, "the", 0 },
            { "WhitespaceTrivia", 26, 27, "the", 0 },
            { "Identifier", 27, 31, "name", 0 },
            { "NewLineTrivia", 31, 32, "name", 1 },
            { "WhitespaceTrivia", 32, 33, "name", 0 },
            { "AsteriskToken", 33, 34, "name", 0 },
            { "WhitespaceTrivia", 34, 35, "name", 0 },
            { "AtToken", 35, 36, "name", 0 },
            { "Identifier", 36, 43, "returns", 0 },
            { "WhitespaceTrivia", 43, 44, "returns", 0 },
            { "OpenBraceToken", 44, 45, "returns", 0 },
            { "NumberKeyword", 45, 51, "number", 0 },
            { "OpenBracketToken", 51, 52, "number", 0 },
            { "CloseBracketToken", 52, 53, "number", 0 },
            { "CloseBraceToken", 53, 54, "number", 0 },
            { "WhitespaceTrivia", 54, 55, "number", 0 },
            { "BacktickToken", 55, 56, "number", 0 },
            { "Identifier", 56, 57, "x", 0 },
            { "BacktickToken", 57, 58, "x", 0 },
            { "WhitespaceTrivia", 58, 59, "x", 0 },
            { "HashToken", 59, 60, "x", 0 },
            { "Identifier", 60, 61, "a", 0 },
            { "WhitespaceTrivia", 61, 62, "a", 0 },
            { "DotToken", 62, 63, "a", 0 },
            { "Identifier", 63, 64, "b", 0 },
            { "WhitespaceTrivia", 64, 65, "b", 0 },
            { "CommaToken", 65, 66, "b", 0 },
            { "Identifier", 66, 67, "c", 0 },
            { "WhitespaceTrivia", 67, 68, "c", 0 },
            { "EqualsToken", 68, 69, "c", 0 },
            { "Identifier", 69, 70, "d", 0 },
            { "WhitespaceTrivia", 70, 71, "d", 0 },
            { "LessThanToken", 71, 72, "d", 0 },
            { "Identifier", 72, 73, "e", 0 },
            { "GreaterThanToken", 73, 74, "e", 0 },
            { "WhitespaceTrivia", 74, 75, "e", 0 },
            { "OpenParenToken", 75, 76, "e", 0 },
            { "Identifier", 76, 77, "f", 0 },
            { "CloseParenToken", 77, 78, "f", 0 },
            { "WhitespaceTrivia", 78, 79, "f", 0 },
            { "Identifier", 79, 86, "ag", 1024 },
            { "WhitespaceTrivia", 86, 87, "ag", 0 },
            { "Identifier", 87, 90, "h-i", 0 },
            { "NewLineTrivia", 90, 92, "h-i", 1 },
            { "EndOfFile", 90, 92, "h-i", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "jsdoc comment text",
        text = "some text {@link foo} and @tag more\x0a next line `code`",
        mode = "jsdoctext",
        tokens = {
            { "JSDocCommentTextToken", 0, 10, "some text ", 0 },
            { "OpenBraceToken", 10, 11, "some text ", 0 },
            { "JSDocCommentTextToken", 11, 26, "@link foo} and ", 0 },
            { "AtToken", 26, 27, "@link foo} and ", 0 },
            { "JSDocCommentTextToken", 27, 35, "tag more", 0 },
            { "NewLineTrivia", 35, 36, "tag more", 1 },
            { "JSDocCommentTextToken", 36, 47, " next line ", 0 },
            { "BacktickToken", 47, 48, " next line ", 0 },
            { "JSDocCommentTextToken", 48, 52, "code", 0 },
            { "BacktickToken", 52, 53, "code", 0 },
            { "EndOfFile", 52, 53, "code", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "unicode escapes in keywords",
        text = "\\u0076ar v\\u0061r \\u{69}f",
        tokens = {
            { "VarKeyword", 0, 8, "var", 1024 },
            { "VarKeyword", 9, 17, "var", 1024 },
            { "IfKeyword", 18, 25, "if", 8 },
            { "EndOfFile", 25, 25, "if", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "question dot digit",
        text = "a?.5:b a?.b",
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "QuestionToken", 1, 2, "a", 0 },
            { "NumericLiteral", 2, 4, "0.5", 0 },
            { "ColonToken", 4, 5, "0.5", 0 },
            { "Identifier", 5, 6, "b", 0 },
            { "Identifier", 7, 8, "a", 0 },
            { "QuestionDotToken", 8, 10, "a", 0 },
            { "Identifier", 10, 11, "b", 0 },
            { "EndOfFile", 11, 11, "b", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "slash forms",
        text = "a / b /= c",
        tokens = {
            { "Identifier", 0, 1, "a", 0 },
            { "SlashToken", 2, 3, "a", 0 },
            { "Identifier", 4, 5, "b", 0 },
            { "SlashEqualsToken", 6, 8, "b", 0 },
            { "Identifier", 9, 10, "c", 0 },
            { "EndOfFile", 10, 10, "c", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "hash bang not at start",
        text = " #!x",
        tokens = {
            { "Unknown", 1, 2, "", 0 },
            { "ExclamationToken", 2, 3, "", 0 },
            { "Identifier", 3, 4, "x", 0 },
            { "EndOfFile", 4, 4, "x", 0 },
        },
        errors = {
            { 18026, 1, 2, "'#!' can only be used at the start of a file." },
        },
        directives = { },
    },
    {
        name = "empty",
        text = "",
        tokens = {
            { "EndOfFile", 0, 0, "", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "only trivia",
        text = "   \x0a\x09// c\x0a/* d */  ",
        tokens = {
            { "EndOfFile", 19, 19, "", 1 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "regex more classes",
        text = "/[[]/v; /[a-\\d]/u; /[\\d-a]/; /a{2,1/; /[\\1]/; /\\01/; /[\\01]/u; /[\\8]/; /\\c/; /[\\c]/; /[\\c]/u",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 6, "/[[]/v", 0 },
            { "SemicolonToken", 6, 7, "/[[]/v", 0 },
            { "RegularExpressionLiteral", 8, 17, "/[a-\\d]/u", 0 },
            { "SemicolonToken", 17, 18, "/[a-\\d]/u", 0 },
            { "RegularExpressionLiteral", 19, 27, "/[\\d-a]/", 0 },
            { "SemicolonToken", 27, 28, "/[\\d-a]/", 0 },
            { "RegularExpressionLiteral", 29, 36, "/a{2,1/", 0 },
            { "SemicolonToken", 36, 37, "/a{2,1/", 0 },
            { "RegularExpressionLiteral", 38, 44, "/[\\1]/", 0 },
            { "SemicolonToken", 44, 45, "/[\\1]/", 0 },
            { "RegularExpressionLiteral", 46, 51, "/\\01/", 0 },
            { "SemicolonToken", 51, 52, "/\\01/", 0 },
            { "RegularExpressionLiteral", 53, 61, "/[\\01]/u", 0 },
            { "SemicolonToken", 61, 62, "/[\\01]/u", 0 },
            { "RegularExpressionLiteral", 63, 69, "/[\\8]/", 0 },
            { "SemicolonToken", 69, 70, "/[\\8]/", 0 },
            { "RegularExpressionLiteral", 71, 75, "/\\c/", 0 },
            { "SemicolonToken", 75, 76, "/\\c/", 0 },
            { "RegularExpressionLiteral", 77, 83, "/[\\c]/", 0 },
            { "SemicolonToken", 83, 84, "/[\\c]/", 0 },
            { "RegularExpressionLiteral", 85, 92, "/[\\c]/u", 0 },
            { "EndOfFile", 92, 92, "/[\\c]/u", 0 },
        },
        errors = {
            { 1005, 4, 0, "']' expected." },
            { 1516, 12, 2, "A character class range must not be bounded by another character class." },
            { 1536, 40, 2, "Octal escape sequences and backreferences are not allowed in a character class. If this was intended as an escape sequence, use the syntax '\\x01' instead." },
            { 1487, 47, 3, "Octal escape sequences are not allowed. Use the syntax '\\x01'." },
            { 1487, 55, 3, "Octal escape sequences are not allowed. Use the syntax '\\x01'." },
            { 1537, 65, 2, "Decimal escape sequences and backreferences are not allowed in a character class." },
            { 1512, 87, 2, "'\\c' must be followed by an ASCII letter." },
        },
        directives = { },
    },
    {
        name = "regex duplicate groups es2018",
        text = "/(?:(?<a>x))(?<a>z)/; /(?:(?<a>x)|(?<a>y))/; /(?<a>x)|(?<a>y)/",
        mode = "rescan",
        target = 5,
        tokens = {
            { "RegularExpressionLiteral", 0, 20, "/(?:(?<a>x))(?<a>z)/", 0 },
            { "SemicolonToken", 20, 21, "/(?:(?<a>x))(?<a>z)/", 0 },
            { "RegularExpressionLiteral", 22, 43, "/(?:(?<a>x)|(?<a>y))/", 0 },
            { "SemicolonToken", 43, 44, "/(?:(?<a>x)|(?<a>y))/", 0 },
            { "RegularExpressionLiteral", 45, 62, "/(?<a>x)|(?<a>y)/", 0 },
            { "EndOfFile", 62, 62, "/(?<a>x)|(?<a>y)/", 0 },
        },
        errors = {
            { 1515, 15, 1, "Named capturing groups with the same name must be mutually exclusive to each other." },
            { 18063, 37, 1, "Duplicate named capturing groups are only available when targeting 'es2025' or later." },
            { 18063, 57, 1, "Duplicate named capturing groups are only available when targeting 'es2025' or later." },
        },
        directives = { },
    },
    {
        name = "regex lookbehind annexb quantifier",
        text = "/(?=a)*/; /(?=a)*/u; /(?<=a)*/; /^*/; /\\b+/",
        mode = "rescan",
        tokens = {
            { "RegularExpressionLiteral", 0, 8, "/(?=a)*/", 0 },
            { "SemicolonToken", 8, 9, "/(?=a)*/", 0 },
            { "RegularExpressionLiteral", 10, 19, "/(?=a)*/u", 0 },
            { "SemicolonToken", 19, 20, "/(?=a)*/u", 0 },
            { "RegularExpressionLiteral", 21, 30, "/(?<=a)*/", 0 },
            { "SemicolonToken", 30, 31, "/(?<=a)*/", 0 },
            { "RegularExpressionLiteral", 32, 36, "/^*/", 0 },
            { "SemicolonToken", 36, 37, "/^*/", 0 },
            { "RegularExpressionLiteral", 38, 43, "/\\b+/", 0 },
            { "EndOfFile", 43, 43, "/\\b+/", 0 },
        },
        errors = {
            { 1507, 16, 1, "There is nothing available for repetition." },
            { 1507, 28, 1, "There is nothing available for repetition." },
            { 1507, 34, 1, "There is nothing available for repetition." },
            { 1507, 41, 1, "There is nothing available for repetition." },
        },
        directives = { },
    },
    {
        name = "string line separator continuation",
        text = "'a\\\xe2\x80\xa8b' '\\\xc3\xa9'",
        tokens = {
            { "StringLiteral", 0, 8, "ab", 65536 },
            { "StringLiteral", 9, 14, "\xc3\xa9", 65536 },
            { "EndOfFile", 14, 14, "\xc3\xa9", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "invalid identifier start escape",
        text = "\\u0030abc \\u{1F600}",
        tokens = {
            { "Unknown", 0, 1, "", 0 },
            { "Identifier", 1, 9, "u0030abc", 0 },
            { "Unknown", 10, 11, "u0030abc", 0 },
            { "Identifier", 11, 12, "u", 0 },
            { "OpenBraceToken", 12, 13, "u", 0 },
            { "NumericLiteral", 13, 14, "1", 0 },
            { "Identifier", 14, 18, "F600", 0 },
            { "CloseBraceToken", 18, 19, "F600", 0 },
            { "EndOfFile", 19, 19, "F600", 0 },
        },
        errors = {
            { 1127, 0, 1, "Invalid character." },
            { 1127, 10, 1, "Invalid character." },
            { 1351, 14, 4, "An identifier or keyword cannot immediately follow a numeric literal." },
        },
        directives = { },
    },
    {
        name = "template line continuation",
        text = "`a\\\x0ab\\\x0d\x0ac` `\\u{1F600}\\uD83D\\uDE00`",
        mode = "rescan",
        tokens = {
            { "NoSubstitutionTemplateLiteral", 0, 10, "abc", 0 },
            { "NoSubstitutionTemplateLiteral", 11, 34, "\xf0\x9f\x98\x80\xf0\x9f\x98\x80", 1032 },
            { "EndOfFile", 34, 34, "\xf0\x9f\x98\x80\xf0\x9f\x98\x80", 0 },
        },
        errors = {
        },
        directives = { },
    },
    {
        name = "numbers misc",
        text = "1..toString 1.e5 0.0 0e0 9007199254740993 1e400 .0001 1_0.0_1e1_0 0X_ 0xG 0b_1 5e 5e+",
        tokens = {
            { "NumericLiteral", 0, 2, "1", 0 },
            { "DotToken", 2, 3, "1", 0 },
            { "Identifier", 3, 11, "toString", 0 },
            { "NumericLiteral", 12, 16, "100000", 16 },
            { "NumericLiteral", 17, 20, "0", 0 },
            { "NumericLiteral", 21, 24, "0", 16 },
            { "NumericLiteral", 25, 41, "9007199254740992", 0 },
            { "NumericLiteral", 42, 47, "Infinity", 16 },
            { "NumericLiteral", 48, 53, "0.0001", 0 },
            { "NumericLiteral", 54, 65, "100100000000", 528 },
            { "NumericLiteral", 66, 69, "0", 576 },
            { "NumericLiteral", 70, 72, "0", 64 },
            { "Identifier", 72, 73, "G", 0 },
            { "NumericLiteral", 74, 78, "1", 640 },
            { "NumericLiteral", 79, 81, "5", 16 },
            { "NumericLiteral", 82, 85, "5", 16 },
            { "EndOfFile", 85, 85, "5", 0 },
        },
        errors = {
            { 6188, 68, 1, "Numeric separators are not allowed here." },
            { 1125, 69, 0, "Hexadecimal digit expected." },
            { 1125, 72, 0, "Hexadecimal digit expected." },
            { 6188, 76, 1, "Numeric separators are not allowed here." },
            { 1124, 81, 0, "Digit expected." },
            { 1124, 85, 0, "Digit expected." },
        },
        directives = { },
    },
    {
        name = "jsdoc asterisks",
        text = "*\x0a * foo-bar\\u0062az\x0a\x09@ \\x",
        mode = "jsdoc",
        tokens = {
            { "AsteriskToken", 0, 1, "", 0 },
            { "NewLineTrivia", 1, 2, "", 1 },
            { "WhitespaceTrivia", 2, 3, "", 0 },
            { "AsteriskToken", 3, 4, "", 0 },
            { "WhitespaceTrivia", 4, 5, "", 0 },
            { "Identifier", 5, 20, "foo-barbaz", 1024 },
            { "NewLineTrivia", 20, 21, "foo-barbaz", 1 },
            { "WhitespaceTrivia", 21, 22, "foo-barbaz", 0 },
            { "AtToken", 22, 23, "foo-barbaz", 0 },
            { "WhitespaceTrivia", 23, 24, "foo-barbaz", 0 },
            { "Unknown", 24, 25, "foo-barbaz", 0 },
            { "Identifier", 25, 26, "x", 0 },
            { "EndOfFile", 25, 26, "x", 0 },
        },
        errors = {
        },
        directives = { },
    },
}
-- END GENERATED FIXTURES

describe("scanner", function()
    describe("matches the Go scanner on fixtures", function()
        for _, c in ipairs(fixtures) do
            it(c.name, function()
                local tokens, errors, directives = runCase(c)
                assert.are.same(c.tokens, tokens)
                assert.are.same(c.errors, errors)
                assert.are.same(c.directives, directives)
            end)
        end
    end)

    -- TestScanStringPreservesLoneSurrogates
    it("scans strings preserving lone surrogates", function()
        local s = scanner.NewScanner()
        s:SetText("\"\u{1F980}\\ud7ff\\ud800\\ud801\\uD83E\\uDD80\"")
        assert.are.equal(Kind.StringLiteral, s:Scan())
        assert.are.equal("\u{1F980}" ..
            stringutil.EncodeJSStringRune(0xD7FF) ..
            stringutil.EncodeJSStringRune(0xD800) ..
            stringutil.EncodeJSStringRune(0xD801) ..
            "\u{1F980}", s:TokenValue())
    end)

    -- TestNormalizeJSDocTypeSourceText
    it("normalizes JSDoc type source text", function()
        local tests = {
            { text = " \t* \tFoo", expected = { "Foo" } },
            { text = "Foo\r\n * Bar\r\t* Baz\u{2028} * Qux\u{2029}* Quux", expected = { "Foo", "Bar", "Baz", "Qux", "Quux" } },
            { text = "Foo\r\n *\r\n", expected = { "Foo", "", "" } },
            { text = "Foo\n  Bar", expected = { "Foo", "Bar" } },
            { text = "**Foo", expected = { "*Foo" } },
        }
        for _, test in ipairs(tests) do
            assert.are.equal(table.concat(test.expected, "\n"), scanner.normalizeJSDocTypeSourceText(test.text))
        end
    end)

    -- TestIsJSDocTypeExpressionOrChild
    it("detects JSDoc type expressions and their children", function()
        local jsDocType = newNode(Kind.TypeReference, ast.NodeFlags.JSDoc)
        local jsDocTypeChild = newNode(Kind.Identifier, ast.NodeFlags.JSDoc, jsDocType)
        local reparsedType = newNode(Kind.TypeLiteral, ast.NodeFlags.Reparsed)
        local reparsedTypeChild = newNode(Kind.Identifier, ast.NodeFlags.Reparsed, reparsedType)
        local ordinaryType = newNode(Kind.TypeReference)
        local jsDocTag = newNode(Kind.JSDocParameterTag, ast.NodeFlags.JSDoc)
        local jsDocTagChild = newNode(Kind.Identifier, ast.NodeFlags.JSDoc, jsDocTag)
        assert.is_true(scanner.isJSDocTypeExpressionOrChild(newNode(Kind.JSDocTypeExpression)))
        assert.is_true(scanner.isJSDocTypeExpressionOrChild(jsDocType))
        assert.is_true(scanner.isJSDocTypeExpressionOrChild(jsDocTypeChild))
        assert.is_true(scanner.isJSDocTypeExpressionOrChild(reparsedType))
        assert.is_true(scanner.isJSDocTypeExpressionOrChild(reparsedTypeChild))
        assert.is_false(scanner.isJSDocTypeExpressionOrChild(ordinaryType))
        assert.is_false(scanner.isJSDocTypeExpressionOrChild(jsDocTagChild))
    end)

    -- TestGetTextOfNodeFromJSDocTypePreservesAsteriskType
    it("preserves the asterisk type in JSDoc source text", function()
        local sourceText = "\n * *"
        local node = newNode(Kind.JSDocAllType, ast.NodeFlags.JSDoc, nil, core.NewTextRange(0, #sourceText))
        assert.are.equal("*", scanner.GetTextOfNodeFromSourceText(sourceText, node, false))
    end)

    it("reports binary files", function()
        local tokens, errors = scanAll("ab\255\254cd")
        assert.are.equal(Kind.Identifier, tokens[1].kind)
        assert.are.equal(Kind.NonTextFileMarkerTrivia, tokens[2].kind)
        assert.are.equal(6, tokens[2].end_)
        assert.are.equal(1490, errors[1].code)
    end)

    it("rescans tokens", function()
        local s = scanner.NewScanner()
        s:SetText("<< *= ?? #x a")
        assert.are.equal(Kind.LessThanLessThanToken, s:Scan())
        assert.are.equal(Kind.LessThanToken, s:ReScanLessThanToken())
        assert.are.equal(1, s:TokenEnd())
        assert.are.equal(Kind.LessThanToken, s:Scan())
        assert.are.equal(Kind.AsteriskEqualsToken, s:Scan())
        assert.are.equal(Kind.EqualsToken, s:ReScanAsteriskEqualsToken())
        assert.are.equal(Kind.EqualsToken, s:Scan())
        assert.are.equal(Kind.QuestionQuestionToken, s:Scan())
        assert.are.equal(Kind.QuestionToken, s:ReScanQuestionToken())
        assert.are.equal(Kind.QuestionToken, s:Scan())
        assert.are.equal(Kind.PrivateIdentifier, s:Scan())
        assert.are.equal("#x", s:TokenValue())
        assert.are.equal(Kind.HashToken, s:ReScanHashToken())
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.has_error(function() s:ReScanQuestionToken() end)
    end)

    it("marks and rewinds state including comment directives", function()
        local s = scanner.NewScanner()
        s:SetText("a // @ts-ignore\nb // @ts-expect-error\nc")
        s:Scan()
        local state = s:Mark()
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.are.equal(1, #s:CommentDirectives())
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.are.equal(2, #s:CommentDirectives())
        s:Rewind(state)
        assert.are.equal("a", s:TokenText())
        assert.is_nil(s:CommentDirectives())
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.are.equal("b", s:TokenValue())
        assert.are.equal(ast.CommentDirectiveKind.Ignore, s:CommentDirectives()[1].kind)
    end)

    it("scans JSX attribute values and rescans JSX tokens", function()
        local s = scanner.NewScanner()
        s:SetLanguageVariant(core.LanguageVariant.JSX)
        s:SetText("  \"a\\nb\" {x}")
        assert.are.equal(Kind.StringLiteral, s:ScanJsxAttributeValue())
        assert.are.equal("a\\nb", s:TokenValue())
        assert.are.equal(2, s:TokenStart())
        assert.are.equal(Kind.StringLiteral, s:ReScanJsxAttributeValue())
        assert.are.equal(Kind.OpenBraceToken, s:ScanJsxAttributeValue())
        assert.are.equal(Kind.JsxText, s:ScanJsxToken())
        assert.are.equal("x}", s:TokenValue())
    end)

    it("skips JSDoc leading asterisks", function()
        local s = scanner.NewScanner()
        s:SetText("a\n * b")
        s:SetSkipJSDocLeadingAsterisks(true)
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.are.equal(Kind.Identifier, s:Scan())
        assert.is_true(s:HasPrecedingJSDocLeadingAsterisks())
        assert.is_true(s:HasPrecedingLineBreak())
        s:SetSkipJSDocLeadingAsterisks(false)
        assert.are.equal(0, s.skipJSDocLeadingAsterisks)
    end)

    it("tracks JSDoc tag flags", function()
        local tokens = scanAll("/** @deprecated */ a /** @linkcode x */ b /** @seeAlso */ c /* @deprecated */ d")
        assert.are_not.equal(0, tokens[1].flags & TokenFlags.PrecedingJSDocWithDeprecated)
        assert.are_not.equal(0, tokens[2].flags & TokenFlags.PrecedingJSDocWithSeeOrLink)
        assert.are.equal(0, tokens[3].flags & TokenFlags.PrecedingJSDocWithSeeOrLink)
        assert.are.equal(0, tokens[4].flags & (TokenFlags.PrecedingJSDocComment | TokenFlags.PrecedingJSDocWithDeprecated))
    end)

    it("resets", function()
        local s = scanner.NewScanner()
        s:SetText("0x10 1")
        s:SetSkipTrivia(false)
        s:Scan()
        s:Reset()
        assert.are.equal("", s:Text())
        assert.is_true(s.skipTrivia)
        assert.are.same({}, s.hexNumberCache)
        assert.are.equal(Kind.EndOfFile, s:Scan())
    end)

    describe("utilities", function()
        it("converts between tokens and strings", function()
            assert.are.equal("=>", scanner.TokenToString(Kind.EqualsGreaterThanToken))
            assert.are.equal("instanceof", scanner.TokenToString(Kind.InstanceOfKeyword))
            assert.are.equal("", scanner.TokenToString(Kind.Identifier))
            assert.are.equal(Kind.QuestionQuestionEqualsToken, scanner.StringToToken("??="))
            assert.are.equal(Kind.Unknown, scanner.StringToToken("nope"))
            assert.are.equal(Kind.SatisfiesKeyword, scanner.GetIdentifierToken("satisfies"))
            assert.are.equal(Kind.Identifier, scanner.GetIdentifierToken("Satisfies"))
            assert.are.equal(Kind.Identifier, scanner.GetIdentifierToken("constructors"))
            assert.are.equal(Kind.ConstructorKeyword, scanner.IdentifierToKeywordKind({ text = "constructor" }))
            assert.are.equal(Kind.Unknown, scanner.IdentifierToKeywordKind({ text = "foo" }))
            local suggestions = scanner.GetViableKeywordSuggestions()
            assert.are.equal("abstract", suggestions[1])
            for _, sug in ipairs(suggestions) do
                assert.is_true(#sug > 2)
            end
        end)

        it("classifies identifiers", function()
            assert.is_true(scanner.IsValidIdentifier("abc"))
            assert.is_true(scanner.IsValidIdentifier("caf\u{e9}"))
            assert.is_false(scanner.IsValidIdentifier(""))
            assert.is_false(scanner.IsValidIdentifier("1a"))
            assert.is_false(scanner.IsValidIdentifier("a-b"))
            assert.is_true(scanner.IsIdentifierText("a-b", core.LanguageVariant.JSX))
            assert.is_false(scanner.IsIdentifierText("a-b", core.LanguageVariant.Standard))
            assert.is_false(scanner.IsIdentifierText("", core.LanguageVariant.Standard))
            assert.is_true(scanner.IsIntrinsicJsxName("div"))
            assert.is_true(scanner.IsIntrinsicJsxName("My-Element"))
            assert.is_false(scanner.IsIntrinsicJsxName("Div"))
            assert.is_false(scanner.IsIntrinsicJsxName(""))
            assert.is_true(scanner.IsIdentifierStart(0x3C0))
            assert.is_false(scanner.IsIdentifierStart(0x30))
            assert.is_true(scanner.IsIdentifierPart(0x30))
        end)

        it("skips trivia", function()
            local text = "#!shebang\n  // c\n /* d */ \u{3000}x"
            assert.are.equal(#text - 1, scanner.SkipTrivia(text, 0))
            assert.are.equal(10, scanner.SkipTriviaEx(text, 0, { stopAfterLineBreak = true }))
            assert.are.equal(12, scanner.SkipTriviaEx(text, 10, { stopAtComments = true }))
            assert.are.equal(-1, scanner.SkipTrivia(text, -1))
            assert.are.equal(4, scanner.SkipTriviaEx("\n * a", 0, { inJSDoc = true }))
            assert.are.equal(2, scanner.SkipTriviaEx("\n * a", 0, {}))
            local conflict = "<<<<<<< HEAD\nx"
            assert.are.equal(#conflict - 1, scanner.SkipTrivia(conflict, 0))
            assert.is_true(scanner.couldStartTrivia("#!", 0))
            assert.is_false(scanner.couldStartTrivia("a#", 1))
            assert.is_false(scanner.couldStartTrivia("a", 0))
        end)

        it("gets shebangs", function()
            assert.are.equal("#!/usr/bin/env node", scanner.GetShebang("#!/usr/bin/env node\nfoo"))
            assert.are.equal("", scanner.GetShebang("foo"))
        end)

        it("iterates comment ranges", function()
            local f = ast.NewNodeFactory(nil)
            local text = "a /* x */ // y\n /* z */ b"
            local trailing = {}
            for cr in scanner.GetTrailingCommentRanges(f, text, 1) do
                trailing[#trailing + 1] = { cr.kind, cr.pos, cr.end_, cr.hasTrailingNewLine }
            end
            assert.are.same({
                { Kind.MultiLineCommentTrivia, 2, 9, false },
                { Kind.SingleLineCommentTrivia, 10, 14, true },
            }, trailing)
            local leading = {}
            for cr in scanner.GetLeadingCommentRanges(f, text, 1) do
                leading[#leading + 1] = { cr.kind, cr.pos, cr.end_, cr.hasTrailingNewLine }
            end
            assert.are.same({ { Kind.MultiLineCommentTrivia, 16, 23, false } }, leading)
            local fromStart = {}
            for cr in scanner.GetLeadingCommentRanges(f, "#!x\n// a\n/* b", 0) do
                fromStart[#fromStart + 1] = { cr.kind, cr.pos, cr.end_, cr.hasTrailingNewLine }
            end
            assert.are.same({
                { Kind.SingleLineCommentTrivia, 4, 8, true },
                { Kind.MultiLineCommentTrivia, 9, 13, false },
            }, fromStart)
        end)

        it("computes line positions", function()
            local lineStarts = { 0, 4, 10 }
            assert.are.equal(0, scanner.ComputeLineOfPosition(lineStarts, 0))
            assert.are.equal(0, scanner.ComputeLineOfPosition(lineStarts, 3))
            assert.are.equal(1, scanner.ComputeLineOfPosition(lineStarts, 4))
            assert.are.equal(2, scanner.ComputeLineOfPosition(lineStarts, 99))
            assert.are.equal(12, scanner.ComputePositionOfLineAndByteOffset(lineStarts, 2, 2))
            assert.has_error(function() scanner.ComputePositionOfLineAndByteOffset(lineStarts, 3, 0) end)
            local text = "ab\n\u{1F600}x\n"
            local starts = { 0, 3, 9 }
            assert.are.equal(8, scanner.ComputePositionOfLineAndUTF16Character(starts, 1, 3, text, false))
            assert.are.equal(3, scanner.ComputePositionOfLineAndUTF16Character(starts, 1, 0, text, false))
            assert.are.equal(9, scanner.ComputePositionOfLineAndUTF16Character(starts, 5, 0, text, true))
            assert.has_error(function() scanner.ComputePositionOfLineAndUTF16Character(starts, 0, 9, text, false) end)
            local file = {
                Text = function() return text end,
                ECMALineMap = function() return starts end,
            }
            local line, character = scanner.GetECMALineAndUTF16CharacterOfPosition(file, 8)
            assert.are.equal(1, line)
            assert.are.equal(3, character)
            local line2, byteOffset = scanner.GetECMALineAndByteOffsetOfPosition(file, 8)
            assert.are.equal(1, line2)
            assert.are.equal(5, byteOffset)
            assert.are.equal(1, scanner.GetECMALineOfPosition(file, 3))
            assert.are.equal(8, scanner.GetECMAPositionOfLineAndUTF16Character(file, 1, 3))
            assert.are.equal(4, scanner.GetECMAPositionOfLineAndByteOffset(file, 1, 1))
            assert.are.equal(1, scanner.GetECMAEndLinePosition(file, 0))
        end)

        it("compares decimal strings", function()
            assert.are.equal(0, scanner.compareDecimalStrings("007", "7"))
            assert.are.equal(1, scanner.compareDecimalStrings("10", "9"))
            assert.are.equal(-1, scanner.compareDecimalStrings("0", "1"))
            assert.are.equal(0, scanner.compareDecimalStrings("", "000"))
        end)
    end)
end)
