local scanner = require("tslua.scanner")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local TokenFlags = ast.TokenFlags
local CommentDirectiveKind = ast.CommentDirectiveKind
local LanguageVariant = core.LanguageVariant
local ScriptTarget = core.ScriptTarget
local EscapeSequenceScanningFlags = scanner.EscapeSequenceScanningFlags

local sbyte, ssub, sfind = string.byte, string.sub, string.find

-- C["x"] is the byte value of the one-character string "x" (Go rune literal 'x').
local C = {}
for i = 0, 127 do
    C[string.char(i)] = i
end

local RuneSelf = 0x80
local RuneError = 0xFFFD

-- Go strconv.ParseInt(s, base, bitSize) value (errors ignored, as the Go callers do):
-- syntax errors yield 0, out-of-range values are clamped to the bitSize range.
local function parseInt(s, base, bitSize)
    local max = (1 << (bitSize - 1)) - 1
    if s == "" then
        return 0
    end
    local v = 0
    for i = 1, #s do
        local c = sbyte(s, i)
        local d
        if c >= 48 and c <= 57 then
            d = c - 48
        elseif c >= 97 and c <= 122 then
            d = c - 97 + 10
        elseif c >= 65 and c <= 90 then
            d = c - 65 + 10
        else
            return 0
        end
        if d >= base then
            return 0
        end
        if v > (max - d) // base then
            return max
        end
        v = v * base + d
    end
    return v
end

scanner.textToKeyword = {
    ["abstract"] = Kind.AbstractKeyword,
    ["accessor"] = Kind.AccessorKeyword,
    ["any"] = Kind.AnyKeyword,
    ["as"] = Kind.AsKeyword,
    ["asserts"] = Kind.AssertsKeyword,
    ["assert"] = Kind.AssertKeyword,
    ["bigint"] = Kind.BigIntKeyword,
    ["boolean"] = Kind.BooleanKeyword,
    ["break"] = Kind.BreakKeyword,
    ["case"] = Kind.CaseKeyword,
    ["catch"] = Kind.CatchKeyword,
    ["class"] = Kind.ClassKeyword,
    ["continue"] = Kind.ContinueKeyword,
    ["const"] = Kind.ConstKeyword,
    ["constructor"] = Kind.ConstructorKeyword,
    ["debugger"] = Kind.DebuggerKeyword,
    ["declare"] = Kind.DeclareKeyword,
    ["default"] = Kind.DefaultKeyword,
    ["defer"] = Kind.DeferKeyword,
    ["delete"] = Kind.DeleteKeyword,
    ["do"] = Kind.DoKeyword,
    ["else"] = Kind.ElseKeyword,
    ["enum"] = Kind.EnumKeyword,
    ["export"] = Kind.ExportKeyword,
    ["extends"] = Kind.ExtendsKeyword,
    ["false"] = Kind.FalseKeyword,
    ["finally"] = Kind.FinallyKeyword,
    ["for"] = Kind.ForKeyword,
    ["from"] = Kind.FromKeyword,
    ["function"] = Kind.FunctionKeyword,
    ["get"] = Kind.GetKeyword,
    ["if"] = Kind.IfKeyword,
    ["immediate"] = Kind.ImmediateKeyword,
    ["implements"] = Kind.ImplementsKeyword,
    ["import"] = Kind.ImportKeyword,
    ["in"] = Kind.InKeyword,
    ["infer"] = Kind.InferKeyword,
    ["instanceof"] = Kind.InstanceOfKeyword,
    ["interface"] = Kind.InterfaceKeyword,
    ["intrinsic"] = Kind.IntrinsicKeyword,
    ["is"] = Kind.IsKeyword,
    ["keyof"] = Kind.KeyOfKeyword,
    ["let"] = Kind.LetKeyword,
    ["module"] = Kind.ModuleKeyword,
    ["namespace"] = Kind.NamespaceKeyword,
    ["never"] = Kind.NeverKeyword,
    ["new"] = Kind.NewKeyword,
    ["null"] = Kind.NullKeyword,
    ["number"] = Kind.NumberKeyword,
    ["object"] = Kind.ObjectKeyword,
    ["package"] = Kind.PackageKeyword,
    ["private"] = Kind.PrivateKeyword,
    ["protected"] = Kind.ProtectedKeyword,
    ["public"] = Kind.PublicKeyword,
    ["override"] = Kind.OverrideKeyword,
    ["out"] = Kind.OutKeyword,
    ["readonly"] = Kind.ReadonlyKeyword,
    ["require"] = Kind.RequireKeyword,
    ["global"] = Kind.GlobalKeyword,
    ["return"] = Kind.ReturnKeyword,
    ["satisfies"] = Kind.SatisfiesKeyword,
    ["set"] = Kind.SetKeyword,
    ["static"] = Kind.StaticKeyword,
    ["string"] = Kind.StringKeyword,
    ["super"] = Kind.SuperKeyword,
    ["switch"] = Kind.SwitchKeyword,
    ["symbol"] = Kind.SymbolKeyword,
    ["this"] = Kind.ThisKeyword,
    ["throw"] = Kind.ThrowKeyword,
    ["true"] = Kind.TrueKeyword,
    ["try"] = Kind.TryKeyword,
    ["type"] = Kind.TypeKeyword,
    ["typeof"] = Kind.TypeOfKeyword,
    ["undefined"] = Kind.UndefinedKeyword,
    ["unique"] = Kind.UniqueKeyword,
    ["unknown"] = Kind.UnknownKeyword,
    ["using"] = Kind.UsingKeyword,
    ["var"] = Kind.VarKeyword,
    ["void"] = Kind.VoidKeyword,
    ["while"] = Kind.WhileKeyword,
    ["with"] = Kind.WithKeyword,
    ["yield"] = Kind.YieldKeyword,
    ["async"] = Kind.AsyncKeyword,
    ["await"] = Kind.AwaitKeyword,
    ["of"] = Kind.OfKeyword,
}

-- Keyword texts in Go source order (Go map iteration order is random; this keeps
-- GetViableKeywordSuggestions deterministic).
scanner.textToKeywordOrder = {
    "abstract", "accessor", "any", "as", "asserts", "assert", "bigint", "boolean", "break", "case",
    "catch", "class", "continue", "const", "constructor", "debugger", "declare", "default", "defer",
    "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function",
    "get", "if", "immediate", "implements", "import", "in", "infer", "instanceof", "interface",
    "intrinsic", "is", "keyof", "let", "module", "namespace", "never", "new", "null", "number",
    "object", "package", "private", "protected", "public", "override", "out", "readonly", "require",
    "global", "return", "satisfies", "set", "static", "string", "super", "switch", "symbol", "this",
    "throw", "true", "try", "type", "typeof", "undefined", "unique", "unknown", "using", "var", "void",
    "while", "with", "yield", "async", "await", "of",
}

scanner.textToToken = (function()
    local m = {
        ["{"] = Kind.OpenBraceToken,
        ["}"] = Kind.CloseBraceToken,
        ["("] = Kind.OpenParenToken,
        [")"] = Kind.CloseParenToken,
        ["["] = Kind.OpenBracketToken,
        ["]"] = Kind.CloseBracketToken,
        ["."] = Kind.DotToken,
        ["..."] = Kind.DotDotDotToken,
        [";"] = Kind.SemicolonToken,
        [","] = Kind.CommaToken,
        ["<"] = Kind.LessThanToken,
        [">"] = Kind.GreaterThanToken,
        ["<="] = Kind.LessThanEqualsToken,
        [">="] = Kind.GreaterThanEqualsToken,
        ["=="] = Kind.EqualsEqualsToken,
        ["!="] = Kind.ExclamationEqualsToken,
        ["==="] = Kind.EqualsEqualsEqualsToken,
        ["!=="] = Kind.ExclamationEqualsEqualsToken,
        ["=>"] = Kind.EqualsGreaterThanToken,
        ["+"] = Kind.PlusToken,
        ["-"] = Kind.MinusToken,
        ["**"] = Kind.AsteriskAsteriskToken,
        ["*"] = Kind.AsteriskToken,
        ["/"] = Kind.SlashToken,
        ["%"] = Kind.PercentToken,
        ["++"] = Kind.PlusPlusToken,
        ["--"] = Kind.MinusMinusToken,
        ["<<"] = Kind.LessThanLessThanToken,
        ["</"] = Kind.LessThanSlashToken,
        [">>"] = Kind.GreaterThanGreaterThanToken,
        [">>>"] = Kind.GreaterThanGreaterThanGreaterThanToken,
        ["&"] = Kind.AmpersandToken,
        ["|"] = Kind.BarToken,
        ["^"] = Kind.CaretToken,
        ["!"] = Kind.ExclamationToken,
        ["~"] = Kind.TildeToken,
        ["&&"] = Kind.AmpersandAmpersandToken,
        ["||"] = Kind.BarBarToken,
        ["?"] = Kind.QuestionToken,
        ["??"] = Kind.QuestionQuestionToken,
        ["?."] = Kind.QuestionDotToken,
        [":"] = Kind.ColonToken,
        ["="] = Kind.EqualsToken,
        ["+="] = Kind.PlusEqualsToken,
        ["-="] = Kind.MinusEqualsToken,
        ["*="] = Kind.AsteriskEqualsToken,
        ["**="] = Kind.AsteriskAsteriskEqualsToken,
        ["/="] = Kind.SlashEqualsToken,
        ["%="] = Kind.PercentEqualsToken,
        ["<<="] = Kind.LessThanLessThanEqualsToken,
        [">>="] = Kind.GreaterThanGreaterThanEqualsToken,
        [">>>="] = Kind.GreaterThanGreaterThanGreaterThanEqualsToken,
        ["&="] = Kind.AmpersandEqualsToken,
        ["|="] = Kind.BarEqualsToken,
        ["^="] = Kind.CaretEqualsToken,
        ["||="] = Kind.BarBarEqualsToken,
        ["&&="] = Kind.AmpersandAmpersandEqualsToken,
        ["??="] = Kind.QuestionQuestionEqualsToken,
        ["@"] = Kind.AtToken,
        ["#"] = Kind.HashToken,
        ["`"] = Kind.BacktickToken,
    }
    for k, v in pairs(scanner.textToKeyword) do
        m[k] = v
    end
    return m
end)()

-- ScannerState fields (embedded in Scanner, flattened):
--   pos, fullStartPos, tokenStart, token, tokenValue, tokenFlags, commentDirectives,
--   skipJSDocLeadingAsterisks
local Scanner = {}
Scanner.__index = Scanner
scanner.Scanner = Scanner

local function resetScannerState(s)
    s.pos = 0
    s.fullStartPos = 0
    s.tokenStart = 0
    s.token = Kind.Unknown
    s.tokenValue = ""
    s.tokenFlags = TokenFlags.None
    s.commentDirectives = nil
    s.skipJSDocLeadingAsterisks = 0
end

function scanner.defaultScanner()
    local s = setmetatable({}, Scanner)
    s.text = ""
    s.end_ = 0
    s.languageVariant = LanguageVariant.Standard
    s.scriptTarget = ScriptTarget.None
    s.onError = nil
    s.skipTrivia = true
    resetScannerState(s)
    s.numberCache = nil
    s.hexNumberCache = nil
    s.hexDigitCache = nil
    return s
end

function scanner.NewScanner()
    return scanner.defaultScanner()
end

function Scanner:Reset()
    local numberCache = scanner.cleared(self.numberCache)
    local hexNumberCache = scanner.cleared(self.hexNumberCache)
    local hexDigitCache = scanner.cleared(self.hexDigitCache)
    local d = scanner.defaultScanner()
    for k in pairs(self) do
        self[k] = nil
    end
    for k, v in pairs(d) do
        self[k] = v
    end
    self.numberCache = numberCache
    self.hexNumberCache = hexNumberCache
    self.hexDigitCache = hexDigitCache
end

function scanner.cleared(m)
    if m ~= nil then
        for k in pairs(m) do
            m[k] = nil
        end
    end
    return m
end

function Scanner:Text()
    return self.text
end

function Scanner:Token()
    return self.token
end

function Scanner:TokenFlags()
    return self.tokenFlags
end

function Scanner:TokenFullStart()
    return self.fullStartPos
end

function Scanner:TokenStart()
    return self.tokenStart
end

function Scanner:TokenEnd()
    return self.pos
end

function Scanner:TokenText()
    return ssub(self.text, self.tokenStart + 1, self.pos)
end

function Scanner:TokenValue()
    return self.tokenValue
end

function Scanner:TokenRange()
    return core.NewTextRange(self.tokenStart, self.pos)
end

function Scanner:CommentDirectives()
    return self.commentDirectives
end

-- Returns a ScannerState value (a copy). The commentDirectives slice is shared like in Go;
-- its length at the time of Mark is recorded so Rewind restores the Go slice header.
function Scanner:Mark()
    local cd = self.commentDirectives
    return {
        pos = self.pos,
        fullStartPos = self.fullStartPos,
        tokenStart = self.tokenStart,
        token = self.token,
        tokenValue = self.tokenValue,
        tokenFlags = self.tokenFlags,
        commentDirectives = cd,
        commentDirectivesLen = cd and #cd or 0,
        skipJSDocLeadingAsterisks = self.skipJSDocLeadingAsterisks,
    }
end

function Scanner:Rewind(state)
    self.pos = state.pos
    self.fullStartPos = state.fullStartPos
    self.tokenStart = state.tokenStart
    self.token = state.token
    self.tokenValue = state.tokenValue
    self.tokenFlags = state.tokenFlags
    local cd = state.commentDirectives
    if cd ~= nil and #cd ~= state.commentDirectivesLen then
        local copy = {}
        for i = 1, state.commentDirectivesLen do
            copy[i] = cd[i]
        end
        cd = copy
    end
    self.commentDirectives = cd
    self.skipJSDocLeadingAsterisks = state.skipJSDocLeadingAsterisks
end

function Scanner:ResetPos(pos)
    if pos < 0 then
        error("Cannot reset token state to negative position", 0)
    end
    self.pos = pos
    self.fullStartPos = pos
    self.tokenStart = pos
end

function Scanner:ResetTokenState(pos)
    self:ResetPos(pos)
    self.token = Kind.Unknown
    self.tokenValue = ""
    self.tokenFlags = TokenFlags.None
end

function Scanner:SetSkipJSDocLeadingAsterisks(skip)
    if skip then
        self.skipJSDocLeadingAsterisks = self.skipJSDocLeadingAsterisks + 1
    else
        self.skipJSDocLeadingAsterisks = self.skipJSDocLeadingAsterisks + -1
    end
end

function Scanner:SetSkipTrivia(skip)
    self.skipTrivia = skip
end

function Scanner:HasUnicodeEscape()
    return self.tokenFlags & TokenFlags.UnicodeEscape ~= 0
end

function Scanner:HasExtendedUnicodeEscape()
    return self.tokenFlags & TokenFlags.ExtendedUnicodeEscape ~= 0
end

function Scanner:HasPrecedingLineBreak()
    return self.tokenFlags & TokenFlags.PrecedingLineBreak ~= 0
end

function Scanner:HasPrecedingJSDocComment()
    return self.tokenFlags & TokenFlags.PrecedingJSDocComment ~= 0
end

function Scanner:HasPrecedingJSDocLeadingAsterisks()
    return self.tokenFlags & TokenFlags.PrecedingJSDocLeadingAsterisks ~= 0
end

function Scanner:HasPrecedingJSDocWithDeprecatedTag()
    return self.tokenFlags & TokenFlags.PrecedingJSDocWithDeprecated ~= 0
end

function Scanner:HasPrecedingJSDocWithSeeOrLink()
    return self.tokenFlags & TokenFlags.PrecedingJSDocWithSeeOrLink ~= 0
end

-- scanJSDocCommentForTags scans a JSDoc comment for @deprecated, @see, and @link tags,
-- setting the appropriate token flags. Called during scanning when a JSDoc comment is detected.
function Scanner:scanJSDocCommentForTags(commentText)
    while true do
        local i = sfind(commentText, "@", 1, true)
        if i == nil then
            return
        end
        commentText = ssub(commentText, i + 1)
        if self.tokenFlags & TokenFlags.PrecedingJSDocWithDeprecated == 0 and scanner.hasJSDocTag(commentText, "deprecated") then
            self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingJSDocWithDeprecated
        end
        if self.tokenFlags & TokenFlags.PrecedingJSDocWithSeeOrLink == 0 and scanner.hasJSDocTag(commentText, "see", "link", "linkcode", "linkplain") then
            self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingJSDocWithSeeOrLink
        end
        if self.tokenFlags & (TokenFlags.PrecedingJSDocWithDeprecated | TokenFlags.PrecedingJSDocWithSeeOrLink) ==
            (TokenFlags.PrecedingJSDocWithDeprecated | TokenFlags.PrecedingJSDocWithSeeOrLink) then
            return
        end
    end
end

-- hasJSDocTag reports whether text starts with one of the given tag names followed
-- by a valid JSDoc tag terminator (whitespace, '}', '*', or end-of-string).
function scanner.hasJSDocTag(text, ...)
    for i = 1, select("#", ...) do
        local tag = select(i, ...)
        if ssub(text, 1, #tag) == tag then
            if #text == #tag then
                return true
            end
            local ch = sbyte(text, #tag + 1)
            if ch == C[" "] or ch == C["\t"] or ch == C["\n"] or ch == C["\r"] or ch == C["}"] or ch == C["*"] then
                return true
            end
        end
    end
    return false
end

function Scanner:SetText(text)
    self.text = text
    self.end_ = #text
    resetScannerState(self)
end

function Scanner:SetOnError(errorCallback)
    self.onError = errorCallback
end

function Scanner:SetLanguageVariant(languageVariant)
    self.languageVariant = languageVariant
end

function Scanner:SetScriptTarget(scriptTarget)
    self.scriptTarget = scriptTarget
end

function Scanner:languageVersion()
    if self.scriptTarget == ScriptTarget.None then
        return ScriptTarget.Latest
    end
    return self.scriptTarget
end

function Scanner:error(diagnostic)
    self:errorAt(diagnostic, self.pos, 0)
end

function Scanner:errorAt(diagnostic, pos, length, ...)
    if self.onError ~= nil then
        self.onError(diagnostic, pos, length, ...)
    end
end

-- NOTE: even though this returns a rune, it only decodes the current byte.
-- It must be checked against utf8.RuneSelf to verify that a call to charAndSize
-- is not needed.
function Scanner:char()
    if self.pos < self.end_ then
        return sbyte(self.text, self.pos + 1)
    end
    return -1
end

-- NOTE: this returns a rune, but only decodes the byte at the offset.
function Scanner:charAt(offset)
    if self.pos + offset < self.end_ then
        return sbyte(self.text, self.pos + offset + 1)
    end
    return -1
end

function Scanner:charAndSize()
    -- Fast path: a single ASCII byte.
    if self.pos < self.end_ then
        local b = sbyte(self.text, self.pos + 1)
        if b < RuneSelf then
            return b, 1
        end
    end
    return core.DecodeRune(self.text, self.pos)
end

-- scanASCIIWhile advances s.pos over the longest run of ASCII bytes for which
-- pred returns true. It stops at end-of-text, the first non-ASCII byte, or the
-- first byte where pred is false.
function Scanner:scanASCIIWhile(pred)
    local text = self.text
    local i = self.pos
    local n = self.end_
    while i < n do
        local b = sbyte(text, i + 1)
        if b >= RuneSelf or not pred(b) then
            break
        end
        i = i + 1
    end
    self.pos = i
end

local function isTriviaSkippedAfterNewLine(b)
    return b == C[" "] or (b >= C["\t"] and b <= C["\r"])
end

local function isNotLineBreakByte(b)
    return b ~= C["\n"] and b ~= C["\r"]
end

local function isNotStarOrLineBreakByte(b)
    return b ~= C["*"] and b ~= C["\n"] and b ~= C["\r"]
end

local function isASCIIIdentifierPartByte(b)
    return (b >= C["a"] and b <= C["z"]) or (b >= C["A"] and b <= C["Z"]) or (b >= C["0"] and b <= C["9"]) or b == C["_"] or b == C["$"]
end

local function isTemplateOrdinaryByte(b)
    return b ~= C["`"] and b ~= C["$"] and b ~= C["\\"] and b ~= C["\r"]
end

local function isDecimalDigitByte(b)
    return b >= C["0"] and b <= C["9"]
end

local function errorAtFunc(s)
    return function(diag, pos, length, ...)
        s:errorAt(diag, pos, length, ...)
    end
end

function Scanner:Scan()
    self.fullStartPos = self.pos
    self.tokenFlags = TokenFlags.None
    while true do
        local ch = self:char()
        self.tokenStart = self.pos

        if ch == C["\t"] or ch == C["\v"] or ch == C["\f"] or ch == C[" "] then
            self.pos = self.pos + 1
            if self.skipTrivia then
                goto continue
            end
            while true do
                local ch2, size = self:charAndSize()
                if not stringutil.IsWhiteSpaceSingleLine(ch2) then
                    break
                end
                self.pos = self.pos + size
            end
            self.token = Kind.WhitespaceTrivia
        elseif ch == C["\n"] or ch == C["\r"] then
            self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingLineBreak
            if self.skipTrivia then
                self.pos = self.pos + 1
                self:scanASCIIWhile(isTriviaSkippedAfterNewLine)
                goto continue
            end
            if ch == C["\r"] and self:charAt(1) == C["\n"] then
                self.pos = self.pos + 2
            else
                self.pos = self.pos + 1
            end
            self.token = Kind.NewLineTrivia
        elseif ch == C["!"] then
            if self:charAt(1) == C["="] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.ExclamationEqualsEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.ExclamationEqualsToken
                end
            else
                self.pos = self.pos + 1
                self.token = Kind.ExclamationToken
            end
        elseif ch == C['"'] or ch == C["'"] then
            self.tokenValue = self:scanString(false --[[jsxAttributeString]])
            self.token = Kind.StringLiteral
        elseif ch == C["`"] then
            self.token = self:scanTemplateAndSetTokenValue(false --[[shouldEmitInvalidEscapeError]])
        elseif ch == C["%"] then
            if self:charAt(1) == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.PercentEqualsToken
            else
                self.pos = self.pos + 1
                self.token = Kind.PercentToken
            end
        elseif ch == C["&"] then
            local next = self:charAt(1)
            if next == C["&"] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.AmpersandAmpersandEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.AmpersandAmpersandToken
                end
            elseif next == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.AmpersandEqualsToken
            else
                self.pos = self.pos + 1
                self.token = Kind.AmpersandToken
            end
        elseif ch == C["("] then
            self.pos = self.pos + 1
            self.token = Kind.OpenParenToken
        elseif ch == C[")"] then
            self.pos = self.pos + 1
            self.token = Kind.CloseParenToken
        elseif ch == C["*"] then
            local next = self:charAt(1)
            if next == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.AsteriskEqualsToken
            elseif next == C["*"] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.AsteriskAsteriskEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.AsteriskAsteriskToken
                end
            else
                self.pos = self.pos + 1
                if self.skipJSDocLeadingAsterisks ~= 0 and
                    (self.tokenFlags & TokenFlags.PrecedingJSDocLeadingAsterisks) == 0 and
                    (self.tokenFlags & TokenFlags.PrecedingLineBreak) ~= 0 then
                    self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingJSDocLeadingAsterisks
                    goto continue
                end
                self.token = Kind.AsteriskToken
            end
        elseif ch == C["+"] then
            local next = self:charAt(1)
            if next == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.PlusEqualsToken
            elseif next == C["+"] then
                self.pos = self.pos + 2
                self.token = Kind.PlusPlusToken
            else
                self.pos = self.pos + 1
                self.token = Kind.PlusToken
            end
        elseif ch == C[","] then
            self.pos = self.pos + 1
            self.token = Kind.CommaToken
        elseif ch == C["-"] then
            local next = self:charAt(1)
            if next == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.MinusEqualsToken
            elseif next == C["-"] then
                self.pos = self.pos + 2
                self.token = Kind.MinusMinusToken
            else
                self.pos = self.pos + 1
                self.token = Kind.MinusToken
            end
        elseif ch == C["."] then
            local next = self:charAt(1)
            if stringutil.IsDigit(next) then
                self.token = self:scanNumber()
            elseif next == C["."] and self:charAt(2) == C["."] then
                self.pos = self.pos + 3
                self.token = Kind.DotDotDotToken
            else
                self.pos = self.pos + 1
                self.token = Kind.DotToken
            end
        elseif ch == C["/"] then
            -- Single-line comment
            if self:charAt(1) == C["/"] then
                self.pos = self.pos + 2

                while true do
                    self:scanASCIIWhile(isNotLineBreakByte)
                    local ch1, size = self:charAndSize()
                    if size == 0 or stringutil.IsLineBreak(ch1) then
                        break
                    end
                    self.pos = self.pos + size
                end

                self:processCommentDirective(self.tokenStart, self.pos, false)

                if self.skipTrivia then
                    goto continue
                end
                self.token = Kind.SingleLineCommentTrivia
                return self.token
            end
            -- Multi-line comment
            if self:charAt(1) == C["*"] then
                self.pos = self.pos + 2
                local isJSDoc = self:char() == C["*"] and self:charAt(1) ~= C["/"]

                local commentClosed = false
                local lastLineStart = self.tokenStart
                while true do
                    self:scanASCIIWhile(isNotStarOrLineBreakByte)
                    local ch1, size = self:charAndSize()
                    if size == 0 then
                        break
                    end

                    if ch1 == C["*"] and self:charAt(1) == C["/"] then
                        self.pos = self.pos + 2
                        commentClosed = true
                        break
                    end

                    self.pos = self.pos + size

                    if stringutil.IsLineBreak(ch1) then
                        lastLineStart = self.pos
                        self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingLineBreak
                    end
                end

                if isJSDoc then
                    self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingJSDocComment
                    self:scanJSDocCommentForTags(ssub(self.text, self.tokenStart + 1, self.pos))
                end

                self:processCommentDirective(lastLineStart, self.pos, true)

                if not commentClosed then
                    self:error(diagnostics.Asterisk_Slash_expected)
                end

                if self.skipTrivia then
                    goto continue
                end

                if not commentClosed then
                    self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
                end
                self.token = Kind.MultiLineCommentTrivia
                return self.token
            end
            if self:charAt(1) == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.SlashEqualsToken
            else
                self.pos = self.pos + 1
                self.token = Kind.SlashToken
            end
        elseif ch == C["0"] and (self:charAt(1) == C["X"] or self:charAt(1) == C["x"]) then
            local start = self.pos
            self.pos = self.pos + 2
            local digits = self:scanHexDigits(1, true, true)
            if digits == "" then
                self:error(diagnostics.Hexadecimal_digit_expected)
                digits = "0"
            end
            if self.hexNumberCache == nil then
                self.hexNumberCache = {}
            end
            local cachedValue = self.hexNumberCache[digits]
            if cachedValue ~= nil then
                self.tokenValue = cachedValue
            else
                local rawText = ssub(self.text, start + 1, self.pos)
                if ssub(rawText, 1, 2) == "0x" and ssub(rawText, 3) == digits then
                    self.tokenValue = rawText
                else
                    self.tokenValue = "0x" .. digits
                end
                self.hexNumberCache[digits] = self.tokenValue
            end
            self.tokenFlags = self.tokenFlags | TokenFlags.HexSpecifier
            self.token = self:scanBigIntSuffix()
        elseif ch == C["0"] and (self:charAt(1) == C["B"] or self:charAt(1) == C["b"]) then
            self.pos = self.pos + 2
            local digits = self:scanBinaryOrOctalDigits(2)
            if digits == "" then
                self:error(diagnostics.Binary_digit_expected)
                digits = "0"
            end
            self.tokenValue = "0b" .. digits
            self.tokenFlags = self.tokenFlags | TokenFlags.BinarySpecifier
            self.token = self:scanBigIntSuffix()
        elseif ch == C["0"] and (self:charAt(1) == C["O"] or self:charAt(1) == C["o"]) then
            self.pos = self.pos + 2
            local digits = self:scanBinaryOrOctalDigits(8)
            if digits == "" then
                self:error(diagnostics.Octal_digit_expected)
                digits = "0"
            end
            self.tokenValue = "0o" .. digits
            self.tokenFlags = self.tokenFlags | TokenFlags.OctalSpecifier
            self.token = self:scanBigIntSuffix()
        elseif ch >= C["0"] and ch <= C["9"] then
            self.token = self:scanNumber()
        elseif ch == C[":"] then
            self.pos = self.pos + 1
            self.token = Kind.ColonToken
        elseif ch == C[";"] then
            self.pos = self.pos + 1
            self.token = Kind.SemicolonToken
        elseif ch == C["<"] then
            if self:charAt(1) == C["<"] and scanner.isConflictMarkerTrivia(self.text, self.pos) then
                self.pos = scanner.scanConflictMarkerTrivia(self.text, self.pos, errorAtFunc(self))
                if self.skipTrivia then
                    goto continue
                else
                    self.token = Kind.ConflictMarkerTrivia
                    return self.token
                end
            end
            if self:charAt(1) == C["<"] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.LessThanLessThanEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.LessThanLessThanToken
                end
            elseif self:charAt(1) == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.LessThanEqualsToken
            elseif self.languageVariant == LanguageVariant.JSX and self:charAt(1) == C["/"] and self:charAt(2) ~= C["*"] then
                self.pos = self.pos + 2
                self.token = Kind.LessThanSlashToken
            else
                self.pos = self.pos + 1
                self.token = Kind.LessThanToken
            end
        elseif ch == C["="] then
            if self:charAt(1) == C["="] and scanner.isConflictMarkerTrivia(self.text, self.pos) then
                self.pos = scanner.scanConflictMarkerTrivia(self.text, self.pos, errorAtFunc(self))
                if self.skipTrivia then
                    goto continue
                else
                    self.token = Kind.ConflictMarkerTrivia
                    return self.token
                end
            end
            if self:charAt(1) == C["="] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.EqualsEqualsEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.EqualsEqualsToken
                end
            elseif self:charAt(1) == C[">"] then
                self.pos = self.pos + 2
                self.token = Kind.EqualsGreaterThanToken
            else
                self.pos = self.pos + 1
                self.token = Kind.EqualsToken
            end
        elseif ch == C[">"] then
            if self:charAt(1) == C[">"] and scanner.isConflictMarkerTrivia(self.text, self.pos) then
                self.pos = scanner.scanConflictMarkerTrivia(self.text, self.pos, errorAtFunc(self))
                if self.skipTrivia then
                    goto continue
                else
                    self.token = Kind.ConflictMarkerTrivia
                    return self.token
                end
            end
            self.pos = self.pos + 1
            self.token = Kind.GreaterThanToken
        elseif ch == C["?"] then
            if self:charAt(1) == C["."] and not stringutil.IsDigit(self:charAt(2)) then
                self.pos = self.pos + 2
                self.token = Kind.QuestionDotToken
            elseif self:charAt(1) == C["?"] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.QuestionQuestionEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.QuestionQuestionToken
                end
            else
                self.pos = self.pos + 1
                self.token = Kind.QuestionToken
            end
        elseif ch == C["["] then
            self.pos = self.pos + 1
            self.token = Kind.OpenBracketToken
        elseif ch == C["]"] then
            self.pos = self.pos + 1
            self.token = Kind.CloseBracketToken
        elseif ch == C["^"] then
            if self:charAt(1) == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.CaretEqualsToken
            else
                self.pos = self.pos + 1
                self.token = Kind.CaretToken
            end
        elseif ch == C["{"] then
            self.pos = self.pos + 1
            self.token = Kind.OpenBraceToken
        elseif ch == C["|"] then
            if self:charAt(1) == C["|"] and scanner.isConflictMarkerTrivia(self.text, self.pos) then
                self.pos = scanner.scanConflictMarkerTrivia(self.text, self.pos, errorAtFunc(self))
                if self.skipTrivia then
                    goto continue
                else
                    self.token = Kind.ConflictMarkerTrivia
                    return self.token
                end
            end
            if self:charAt(1) == C["|"] then
                if self:charAt(2) == C["="] then
                    self.pos = self.pos + 3
                    self.token = Kind.BarBarEqualsToken
                else
                    self.pos = self.pos + 2
                    self.token = Kind.BarBarToken
                end
            elseif self:charAt(1) == C["="] then
                self.pos = self.pos + 2
                self.token = Kind.BarEqualsToken
            else
                self.pos = self.pos + 1
                self.token = Kind.BarToken
            end
        elseif ch == C["}"] then
            self.pos = self.pos + 1
            self.token = Kind.CloseBraceToken
        elseif ch == C["~"] then
            self.pos = self.pos + 1
            self.token = Kind.TildeToken
        elseif ch == C["@"] then
            self.pos = self.pos + 1
            self.token = Kind.AtToken
        elseif ch == C["\\"] then
            local cp = self:peekUnicodeEscape()
            if cp >= 0 and scanner.IsIdentifierStart(cp) then
                self.tokenValue = core.EncodeRune(self:scanUnicodeEscape(true)) .. self:scanIdentifierParts()
                self.token = scanner.GetIdentifierToken(self.tokenValue)
            else
                self:scanInvalidCharacter()
            end
        elseif ch == C["#"] then
            if self:charAt(1) == C["!"] then
                if self.pos == 0 then
                    self.pos = self.pos + 2
                    while true do
                        local ch2, size = self:charAndSize()
                        if not (size > 0 and not stringutil.IsLineBreak(ch2)) then
                            break
                        end
                        self.pos = self.pos + size
                    end
                    goto continue
                end
                self:errorAt(diagnostics.X_can_only_be_used_at_the_start_of_a_file, self.pos, 2)
                self.pos = self.pos + 1
                self.token = Kind.Unknown
                return self.token
            end
            if self:charAt(1) == C["\\"] then
                self.pos = self.pos + 1
                local cp = self:peekUnicodeEscape()
                if cp >= 0 and scanner.IsIdentifierStart(cp) then
                    self.tokenValue = "#" .. core.EncodeRune(self:scanUnicodeEscape(true)) .. self:scanIdentifierParts()
                    self.token = Kind.PrivateIdentifier
                    return self.token
                end
                self.pos = self.pos - 1
            end
            if not self:scanIdentifier(1) then
                self:errorAt(diagnostics.Invalid_character, self.pos - 1, 1)
                self.tokenValue = "#"
            end
            self.token = Kind.PrivateIdentifier
        else
            if ch < 0 then
                self.token = Kind.EndOfFile
                return self.token
            end
            if self:scanIdentifier(0) then
                self.token = scanner.GetIdentifierToken(self.tokenValue)
                return self.token
            end
            local ch2, size = self:charAndSize()
            if ch2 == RuneError then
                self:errorAt(diagnostics.File_appears_to_be_binary, 0, 0)
                self.pos = #self.text
                self.token = Kind.NonTextFileMarkerTrivia
                return self.token
            end
            if stringutil.IsWhiteSpaceSingleLine(ch2) then
                self.pos = self.pos + size

                -- If we get here and it's not 0x0085 (nextLine), then we're handling non-ASCII whitespace.
                -- Handle skipTrivia like we do in the space case above.
                if ch2 == 0x0085 or self.skipTrivia then
                    goto continue
                end

                while true do
                    ch2, size = self:charAndSize()
                    if not stringutil.IsWhiteSpaceSingleLine(ch2) then
                        break
                    end
                    self.pos = self.pos + size
                end
                self.token = Kind.WhitespaceTrivia
                return self.token
            end
            if stringutil.IsLineBreak(ch2) then
                self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingLineBreak
                self.pos = self.pos + size
                goto continue
            end
            self:scanInvalidCharacter()
        end
        do
            return self.token
        end
        ::continue::
    end
end

function Scanner:processCommentDirective(start, end_, multiline)
    local text = self.text
    -- Skip starting slashes and whitespace
    local pos = start
    if multiline then
        -- Skip whitespace
        while pos < end_ and (sbyte(text, pos + 1) == C[" "] or sbyte(text, pos + 1) == C["\t"]) do
            pos = pos + 1
        end
        -- Skip combinations of / and *
        while pos < end_ and (sbyte(text, pos + 1) == C["/"] or sbyte(text, pos + 1) == C["*"]) do
            pos = pos + 1
        end
    else
        -- Skip opening //
        pos = pos + 2
        -- Skip another / if present
        while pos < end_ and sbyte(text, pos + 1) == C["/"] do
            pos = pos + 1
        end
    end
    -- Skip whitespace
    while pos < end_ and (sbyte(text, pos + 1) == C[" "] or sbyte(text, pos + 1) == C["\t"]) do
        pos = pos + 1
    end
    -- Directive must start with '@'
    if not (pos < end_ and sbyte(text, pos + 1) == C["@"]) then
        return
    end
    pos = pos + 1
    local kind
    if ssub(text, pos + 1, pos + #"ts-expect-error") == "ts-expect-error" then
        kind = CommentDirectiveKind.ExpectError
    elseif ssub(text, pos + 1, pos + #"ts-ignore") == "ts-ignore" then
        kind = CommentDirectiveKind.Ignore
    else
        return
    end
    self.commentDirectives = core.Append(self.commentDirectives, { loc = core.NewTextRange(start, end_), kind = kind })
end

function Scanner:ReScanLessThanToken()
    if self.token == Kind.LessThanLessThanToken then
        self.pos = self.tokenStart + 1
        self.token = Kind.LessThanToken
    end
    return self.token
end

function Scanner:ReScanGreaterThanToken()
    if self.token == Kind.GreaterThanToken then
        self:reScanGreaterThanTokenInner()
    end
    return self.token
end

function Scanner:reScanGreaterThanTokenInner()
    self.pos = self.tokenStart + 1
    if self:char() == C[">"] then
        if self:charAt(1) == C[">"] then
            if self:charAt(2) == C["="] then
                self.pos = self.pos + 3
                self.token = Kind.GreaterThanGreaterThanGreaterThanEqualsToken
            else
                self.pos = self.pos + 2
                self.token = Kind.GreaterThanGreaterThanGreaterThanToken
            end
        elseif self:charAt(1) == C["="] then
            self.pos = self.pos + 2
            self.token = Kind.GreaterThanGreaterThanEqualsToken
        else
            self.pos = self.pos + 1
            self.token = Kind.GreaterThanGreaterThanToken
        end
    elseif self:char() == C["="] then
        self.pos = self.pos + 1
        self.token = Kind.GreaterThanEqualsToken
    end
end

function Scanner:ReScanTemplateToken(isTaggedTemplate)
    self.pos = self.tokenStart
    self.token = self:scanTemplateAndSetTokenValue(not isTaggedTemplate)
    return self.token
end

function Scanner:ReScanAsteriskEqualsToken()
    if self.token ~= Kind.AsteriskEqualsToken then
        error("'ReScanAsteriskEqualsToken' should only be called on a '*='", 0)
    end
    self.pos = self.tokenStart + 1
    self.token = Kind.EqualsToken
    return self.token
end

-- reportErrors: optional boolean (Go variadic `reportErrors ...bool`).
function Scanner:ReScanSlashToken(reportErrors)
    local shouldReportErrors = reportErrors == true
    if self.token == Kind.SlashToken or self.token == Kind.SlashEqualsToken then
        local text = self.text
        -- Quickly get to the end of regex such that we know the flags
        local startOfRegExpBody = self.tokenStart + 1
        local p = startOfRegExpBody
        local inEscape = false
        local namedCaptureGroups = false
        -- Although nested character classes are allowed in Unicode Sets mode,
        -- an unescaped slash is nevertheless invalid even in a character class in any Unicode mode.
        -- This is indicated by Section 12.9.5 Regular Expression Literals of the specification,
        -- where nested character classes are not considered at all. (A `[` RegularExpressionClassChar
        -- does nothing in a RegularExpressionClass, and a `]` always closes the class.)
        -- Additionally, parsing nested character classes will misinterpret regexes like `/[[]/`
        -- as unterminated, consuming characters beyond the slash. (This even applies to `/[[]/v`,
        -- which should be parsed as a well-terminated regex with an incomplete character class.)
        -- Thus we must not handle nested character classes in the first pass.
        local inCharacterClass = false
        while true do
            -- If we reach the end of a file, or hit a newline, then this is an unterminated
            -- regex. Report error and return what we have so far.
            if p >= self.end_ then
                self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
                break
            end
            local ch = sbyte(text, p + 1)
            if stringutil.IsLineBreak(ch) then
                self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
                break
            elseif inEscape then
                -- Parsing an escape character;
                -- reset the flag and just advance to the next char.
                inEscape = false
            elseif ch == C["/"] and not inCharacterClass then
                -- A slash within a character class is permissible,
                -- but in general it signals the end of the regexp literal.
                break
            elseif ch == C["["] then
                inCharacterClass = true
            elseif ch == C["\\"] then
                inEscape = true
            elseif ch == C["]"] then
                inCharacterClass = false
            elseif not inCharacterClass and ch == C["("] and
                p + 1 < self.end_ and sbyte(text, p + 2) == C["?"] and
                p + 2 < self.end_ and sbyte(text, p + 3) == C["<"] and
                (p + 3 >= self.end_ or (sbyte(text, p + 4) ~= C["="] and sbyte(text, p + 4) ~= C["!"])) then
                namedCaptureGroups = true
            end
            p = p + 1
        end

        local endOfRegExpBody = p
        if self.tokenFlags & TokenFlags.Unterminated ~= 0 then
            -- Search for the nearest unbalanced bracket for better recovery. Since the expression is
            -- invalid anyways, we take nested square brackets into consideration for the best guess.
            p = startOfRegExpBody
            inEscape = false
            local characterClassDepth = 0
            local inDecimalQuantifier = false
            local groupDepth = 0
            while p < endOfRegExpBody do
                local ch = sbyte(text, p + 1)
                if inEscape then
                    inEscape = false
                elseif ch == C["\\"] then
                    inEscape = true
                elseif ch == C["["] then
                    characterClassDepth = characterClassDepth + 1
                elseif ch == C["]"] and characterClassDepth ~= 0 then
                    characterClassDepth = characterClassDepth - 1
                elseif characterClassDepth == 0 then
                    if ch == C["{"] then
                        inDecimalQuantifier = true
                    elseif ch == C["}"] and inDecimalQuantifier then
                        inDecimalQuantifier = false
                    elseif not inDecimalQuantifier then
                        if ch == C["("] then
                            groupDepth = groupDepth + 1
                        elseif ch == C[")"] and groupDepth ~= 0 then
                            groupDepth = groupDepth - 1
                        elseif ch == C[")"] or ch == C["]"] or ch == C["}"] then
                            -- We encountered an unbalanced bracket outside a character class. Treat this position as the end of regex.
                            break
                        end
                    end
                end
                p = p + 1
            end
            -- Whitespaces and semicolons at the end are not likely to be part of the regex
            while p > startOfRegExpBody do
                local ch, size = core.DecodeLastRune(text, p)
                if stringutil.IsWhiteSpaceLike(ch) or ch == C[";"] then
                    p = p - size
                else
                    break
                end
            end
            self:errorAt(diagnostics.Unterminated_regular_expression_literal, self.tokenStart, p - self.tokenStart)
        else
            -- Consume the slash character
            p = p + 1
            local regularExpressionFlags = scanner.regularExpressionFlags
            local regExpFlags = regularExpressionFlags.None
            while p < self.end_ do
                local ch, size = core.DecodeRune(text, p)
                if ch == RuneError or not scanner.IsIdentifierPart(ch) then
                    break
                end
                if shouldReportErrors then
                    local flag = scanner.charCodeToRegExpFlag[ch]
                    if flag == nil then
                        self:errorAt(diagnostics.Unknown_regular_expression_flag, p, size)
                    elseif regExpFlags & flag ~= 0 then
                        self:errorAt(diagnostics.Duplicate_regular_expression_flag, p, size)
                    elseif (regExpFlags | flag) & regularExpressionFlags.AnyUnicodeMode == regularExpressionFlags.AnyUnicodeMode then
                        self:errorAt(diagnostics.The_Unicode_u_flag_and_the_Unicode_Sets_v_flag_cannot_be_set_simultaneously, p, size)
                    else
                        regExpFlags = regExpFlags | flag
                        self:checkRegularExpressionFlagAvailability(flag, p, size)
                    end
                end
                p = p + size
            end
            if shouldReportErrors then
                self.pos = startOfRegExpBody
                local saveEnd = self.end_
                local saveTokenPos = self.tokenStart
                local saveTokenFlags = self.tokenFlags
                self.end_ = endOfRegExpBody
                local parser = scanner.newRegExpParser(
                    self,
                    endOfRegExpBody,
                    regExpFlags,
                    regExpFlags & regularExpressionFlags.AnyUnicodeMode ~= 0,
                    regExpFlags & regularExpressionFlags.UnicodeSets ~= 0,
                    true,
                    namedCaptureGroups
                )
                parser:run()
                self.end_ = saveEnd
                self.pos = p
                self.tokenStart = saveTokenPos
                self.tokenFlags = saveTokenFlags
            else
                self.pos = p
            end
        end

        self.pos = p
        self.tokenValue = ssub(text, self.tokenStart + 1, self.pos)
        self.token = Kind.RegularExpressionLiteral
    end
    return self.token
end

function Scanner:ReScanJsxToken(allowMultilineJsxText)
    self.pos = self.fullStartPos
    self.tokenStart = self.fullStartPos
    self.token = self:ScanJsxTokenEx(allowMultilineJsxText)
    return self.token
end

function Scanner:ReScanHashToken()
    if self.token == Kind.PrivateIdentifier then
        self.pos = self.tokenStart + 1
        self.token = Kind.HashToken
    end
    return self.token
end

function Scanner:ReScanQuestionToken()
    if self.token ~= Kind.QuestionQuestionToken then
        error("'reScanQuestionToken' should only be called on a '??'", 0)
    end
    self.pos = self.tokenStart + 1
    self.token = Kind.QuestionToken
    return self.token
end

function Scanner:ScanJsxToken()
    return self:ScanJsxTokenEx(true --[[allowMultilineJsxText]])
end

function Scanner:ScanJsxTokenEx(allowMultilineJsxText)
    self.fullStartPos = self.pos
    self.tokenStart = self.pos
    local ch = self:char()
    if ch < 0 then
        self.token = Kind.EndOfFile
    elseif ch == C["<"] then
        if self:charAt(1) == C["/"] then
            self.pos = self.pos + 2
            self.token = Kind.LessThanSlashToken
        else
            self.pos = self.pos + 1
            self.token = Kind.LessThanToken
        end
    elseif ch == C["{"] then
        self.pos = self.pos + 1
        self.token = Kind.OpenBraceToken
    else
        -- First non-whitespace character on this line.
        local firstNonWhitespace = 0
        -- These initial values are special because the first line is:
        -- firstNonWhitespace = 0 to indicate that we want leading whitespace
        while true do
            local ch2, size = self:charAndSize()
            if size == 0 or ch2 == C["{"] then
                break
            end
            if ch2 == C["<"] then
                if scanner.isConflictMarkerTrivia(self.text, self.pos) then
                    self.pos = scanner.scanConflictMarkerTrivia(self.text, self.pos, errorAtFunc(self))
                    self.token = Kind.ConflictMarkerTrivia
                    return self.token
                end
                break
            end
            if ch2 == C[">"] then
                self:errorAt(diagnostics.Unexpected_token_Did_you_mean_or_gt, self.pos, 1)
            elseif ch2 == C["}"] then
                self:errorAt(diagnostics.Unexpected_token_Did_you_mean_or_rbrace, self.pos, 1)
            end
            -- FirstNonWhitespace is 0, then we only see whitespaces so far. If we see a linebreak, we want to ignore that whitespaces.
            -- i.e (- : whitespace)
            --      <div>----
            --      </div> becomes <div></div>
            --
            --      <div>----</div> becomes <div>----</div>
            if stringutil.IsLineBreak(ch2) and firstNonWhitespace == 0 then
                firstNonWhitespace = -1
            elseif not allowMultilineJsxText and stringutil.IsLineBreak(ch2) and firstNonWhitespace > 0 then
                -- Stop JsxText on each line during formatting. This allows the formatter to
                -- indent each line correctly.
                break
            elseif not stringutil.IsWhiteSpaceLike(ch2) then
                firstNonWhitespace = self.pos
            end
            self.pos = self.pos + size
        end
        self.tokenValue = ssub(self.text, self.fullStartPos + 1, self.pos)
        self.token = Kind.JsxText
        if firstNonWhitespace == -1 then
            self.token = Kind.JsxTextAllWhiteSpaces
        end
    end
    return self.token
end

-- Scans a JSX identifier; these differ from normal identifiers in that they allow dashes
function Scanner:ScanJsxIdentifier()
    if scanner.tokenIsIdentifierOrKeyword(self.token) then
        -- An identifier or keyword has already been parsed - check for a `-` or a single instance of `:` and then append it and
        -- everything after it to the token
        -- Do note that this means that `scanJsxIdentifier` effectively _mutates_ the visible token without advancing to a new token
        -- Any caller should be expecting this behavior and should only read the pos or token value after calling it.
        while true do
            local ch = self:char()
            if ch < 0 then
                break
            end
            if ch == C["-"] then
                self.tokenValue = self.tokenValue .. "-"
                self.pos = self.pos + 1
            else
                local oldPos = self.pos
                self.tokenValue = self.tokenValue .. self:scanIdentifierParts() -- reuse `scanIdentifierParts` so unicode escapes are handled
                if self.pos == oldPos then
                    break
                end
            end
        end
        self.token = scanner.GetIdentifierToken(self.tokenValue)
    end
    return self.token
end

function Scanner:ScanJsxAttributeValue()
    self.fullStartPos = self.pos
    -- Skip whitespace between '=' and the value so tokenStart lands on the
    -- opening quote, not on trivia.
    while true do
        local ch, size = self:charAndSize()
        if not (size > 0 and stringutil.IsWhiteSpaceLike(ch)) then
            break
        end
        self.pos = self.pos + size
    end
    self.tokenStart = self.pos
    local ch = self:char()
    if ch == C['"'] or ch == C["'"] then
        self.tokenValue = self:scanString(true --[[jsxAttributeString]])
        self.token = Kind.StringLiteral
        return self.token
    end
    -- If this scans anything other than `{`, it's a parse error.
    return self:Scan()
end

function Scanner:ReScanJsxAttributeValue()
    self.pos = self.fullStartPos
    self.tokenStart = self.fullStartPos
    return self:ScanJsxAttributeValue()
end

-- In addition to the usual JSDoc ast.Kinds, can also return ast.KindJSDocCommentTextToken
function Scanner:ScanJSDocCommentTextToken(inBackticks)
    self.fullStartPos = self.pos
    self.tokenFlags = TokenFlags.None
    local text = self.text
    if self.pos >= #text then
        self.token = Kind.EndOfFile
        return self.token
    end
    self.tokenStart = self.pos
    local ch, size = self:charAndSize()
    while self.pos < #text and not stringutil.IsLineBreak(ch) and ch ~= C["`"] do
        if not inBackticks then
            if ch == C["{"] then
                break
            elseif ch == C["@"] and self.pos >= 0 then
                -- @ doesn't start a new tag inside ``, and elsewhere, only after whitespace and before identifier
                local previous = core.DecodeLastRune(text, self.pos)
                if stringutil.IsWhiteSpaceSingleLine(previous) then
                    local next = core.DecodeRune(text, self.pos + size)
                    if scanner.IsIdentifierStart(next) then
                        break
                    end
                end
            end
        end
        self.pos = self.pos + size
        ch, size = self:charAndSize()
    end
    if self.pos == self.tokenStart then
        return self:ScanJSDocToken()
    end
    self.tokenValue = ssub(text, self.tokenStart + 1, self.pos)
    self.token = Kind.JSDocCommentTextToken
    return self.token
end

-- Peek at the character at the current scanner position (expected to be right after '@')
-- and return true if a JSDoc tag can follow. Identifier starts indicate a tag name.
-- Whitespace, newlines, and EOF are also accepted to support incomplete tags for code completion.
function Scanner:CanFollowJSDocAt()
    if self.pos >= #self.text then
        return true
    end
    local ch = core.DecodeRune(self.text, self.pos)
    return scanner.IsIdentifierStart(ch) or stringutil.IsWhiteSpaceSingleLine(ch) or stringutil.IsLineBreak(ch)
end

local jsDocSingleCharTokens = {
    [C["@"]] = Kind.AtToken,
    [C["*"]] = Kind.AsteriskToken,
    [C["{"]] = Kind.OpenBraceToken,
    [C["}"]] = Kind.CloseBraceToken,
    [C["["]] = Kind.OpenBracketToken,
    [C["]"]] = Kind.CloseBracketToken,
    [C["("]] = Kind.OpenParenToken,
    [C[")"]] = Kind.CloseParenToken,
    [C["<"]] = Kind.LessThanToken,
    [C[">"]] = Kind.GreaterThanToken,
    [C["="]] = Kind.EqualsToken,
    [C[","]] = Kind.CommaToken,
    [C["."]] = Kind.DotToken,
    [C["`"]] = Kind.BacktickToken,
    [C["#"]] = Kind.HashToken,
}

function Scanner:ScanJSDocToken()
    self.fullStartPos = self.pos
    self.tokenFlags = TokenFlags.None
    if self.pos >= #self.text then
        self.token = Kind.EndOfFile
        return self.token
    end

    self.tokenStart = self.pos
    local ch, size = self:charAndSize()
    self.pos = self.pos + size
    if ch == C["\t"] or ch == C["\v"] or ch == C["\f"] or ch == C[" "] then
        while true do
            local ch2, size2 = self:charAndSize()
            if not (size2 > 0 and stringutil.IsWhiteSpaceSingleLine(ch2)) then
                break
            end
            self.pos = self.pos + size2
        end
        self.token = Kind.WhitespaceTrivia
        return self.token
    elseif ch == C["\r"] or ch == C["\n"] then
        if ch == C["\r"] and self:char() == C["\n"] then
            self.pos = self.pos + 1
        end
        self.tokenFlags = self.tokenFlags | TokenFlags.PrecedingLineBreak
        self.token = Kind.NewLineTrivia
        return self.token
    elseif jsDocSingleCharTokens[ch] ~= nil then
        self.token = jsDocSingleCharTokens[ch]
        return self.token
    elseif ch == C["\\"] then
        self.pos = self.pos - 1
        local cp = self:peekUnicodeEscape()
        if cp >= 0 and scanner.IsIdentifierStart(cp) then
            self.tokenValue = core.EncodeRune(self:scanUnicodeEscape(true)) .. self:scanIdentifierParts()
            self.token = scanner.GetIdentifierToken(self.tokenValue)
        else
            self.pos = self.pos + 1
            self.token = Kind.Unknown
        end
        return self.token
    end

    if scanner.IsIdentifierStart(ch) then
        local char = ch
        while true do
            if self.pos >= #self.text then
                break
            end
            char, size = self:charAndSize()
            if not scanner.IsIdentifierPart(char) and char ~= C["-"] then
                break
            end
            self.pos = self.pos + size
        end
        self.tokenValue = ssub(self.text, self.tokenStart + 1, self.pos)
        if char == C["\\"] then
            self.tokenValue = self.tokenValue .. self:scanIdentifierParts()
        end
        self.token = scanner.GetIdentifierToken(self.tokenValue)
        return self.token
    else
        self.token = Kind.Unknown
        return self.token
    end
end

function Scanner:scanIdentifier(prefixLength)
    local start = self.pos
    self.pos = self.pos + prefixLength
    local ch = self:char()
    -- Fast path for simple ASCII identifiers
    if stringutil.IsASCIILetter(ch) or ch == C["_"] or ch == C["$"] then
        self.pos = self.pos + 1
        self:scanASCIIWhile(isASCIIIdentifierPartByte)
        ch = self:char()
        if ch < RuneSelf and ch ~= C["\\"] then
            self.tokenValue = ssub(self.text, start + 1, self.pos)
            return true
        end
        self.pos = start + prefixLength
    end
    local size
    ch, size = self:charAndSize()
    if scanner.IsIdentifierStart(ch) then
        while true do
            self.pos = self.pos + size
            ch, size = self:charAndSize()
            if not scanner.IsIdentifierPart(ch) then
                break
            end
        end
        self.tokenValue = ssub(self.text, start + 1, self.pos)
        if ch == C["\\"] then
            self.tokenValue = self.tokenValue .. self:scanIdentifierParts()
        end
        return true
    end
    return false
end

function Scanner:scanIdentifierParts()
    local sb = {}
    local start = self.pos
    while true do
        local ch, size = self:charAndSize()
        if scanner.IsIdentifierPart(ch) then
            self.pos = self.pos + size
            goto continue
        end
        if ch == C["\\"] then
            local escaped = self:peekUnicodeEscape()
            if escaped >= 0 and scanner.IsIdentifierPart(escaped) then
                sb[#sb + 1] = ssub(self.text, start + 1, self.pos)
                sb[#sb + 1] = core.EncodeRune(self:scanUnicodeEscape(true))
                start = self.pos
                goto continue
            end
        end
        do
            break
        end
        ::continue::
    end
    sb[#sb + 1] = ssub(self.text, start + 1, self.pos)
    return table.concat(sb)
end

function Scanner:scanString(jsxAttributeString)
    local text = self.text
    local quote = self:char()
    if quote == C["'"] then
        self.tokenFlags = self.tokenFlags | TokenFlags.SingleQuote
    end
    self.pos = self.pos + 1
    -- Fast path for simple strings without escape sequences.
    local found = sfind(text, string.char(quote), self.pos + 1, true)
    local strLen = found and (found - 1 - self.pos) or -1
    if strLen == 0 then
        self.pos = self.pos + 1
        return ""
    end
    if strLen > 0 then
        local str = ssub(text, self.pos + 1, self.pos + strLen)
        if jsxAttributeString or
            (sfind(str, "\\", 1, true) == nil and sfind(str, "\r", 1, true) == nil and sfind(str, "\n", 1, true) == nil) then
            self.pos = self.pos + strLen + 1
            return str
        end
    end
    local sb = {}
    local start = self.pos
    while true do
        local ch = self:char()
        if ch < 0 then
            sb[#sb + 1] = ssub(text, start + 1, self.pos)
            self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
            self:error(diagnostics.Unterminated_string_literal)
            break
        end
        if ch == quote then
            sb[#sb + 1] = ssub(text, start + 1, self.pos)
            self.pos = self.pos + 1
            break
        end
        if ch == C["\\"] and not jsxAttributeString then
            sb[#sb + 1] = ssub(text, start + 1, self.pos)
            sb[#sb + 1] = self:scanEscapeSequence(EscapeSequenceScanningFlags.String | EscapeSequenceScanningFlags.ReportErrors)
            start = self.pos
        elseif (ch == C["\n"] or ch == C["\r"]) and not jsxAttributeString then
            sb[#sb + 1] = ssub(text, start + 1, self.pos)
            self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
            self:error(diagnostics.Unterminated_string_literal)
            break
        else
            self.pos = self.pos + 1
        end
    end
    return table.concat(sb)
end

function Scanner:scanTemplateAndSetTokenValue(shouldEmitInvalidEscapeError)
    local text = self.text
    local startedWithBacktick = self:char() == C["`"]
    self.pos = self.pos + 1
    local start = self.pos
    local parts = {}
    local token
    while true do
        self:scanASCIIWhile(isTemplateOrdinaryByte)
        local ch = self:char()
        if ch < 0 or ch == C["`"] then
            parts[#parts + 1] = ssub(text, start + 1, self.pos)
            if ch == C["`"] then
                self.pos = self.pos + 1
            else
                self.tokenFlags = self.tokenFlags | TokenFlags.Unterminated
                self:error(diagnostics.Unterminated_template_literal)
            end
            token = startedWithBacktick and Kind.NoSubstitutionTemplateLiteral or Kind.TemplateTail
            break
        end
        if ch == C["$"] and self:charAt(1) == C["{"] then
            parts[#parts + 1] = ssub(text, start + 1, self.pos)
            self.pos = self.pos + 2
            token = startedWithBacktick and Kind.TemplateHead or Kind.TemplateMiddle
            break
        end
        if ch == C["\\"] then
            parts[#parts + 1] = ssub(text, start + 1, self.pos)
            parts[#parts + 1] = self:scanEscapeSequence(EscapeSequenceScanningFlags.String |
                (shouldEmitInvalidEscapeError and EscapeSequenceScanningFlags.ReportErrors or 0))
            start = self.pos
        elseif ch == C["\r"] then
            -- Speculated ECMAScript 6 Spec 11.8.6.1:
            -- <CR><LF> and <CR> LineTerminatorSequences are normalized to <LF> for Template Values
            parts[#parts + 1] = ssub(text, start + 1, self.pos)
            self.pos = self.pos + 1
            if self:char() == C["\n"] then
                self.pos = self.pos + 1
            end
            parts[#parts + 1] = "\n"
            start = self.pos
        else
            self.pos = self.pos + 1
        end
    end
    self.tokenValue = table.concat(parts)
    return token
end

function Scanner:scanEscapeSequence(flags)
    local text = self.text
    local start = self.pos
    self.pos = self.pos + 1
    local ch = self:char()
    if ch < 0 then
        self:error(diagnostics.Unexpected_end_of_text)
        return ""
    end
    self.pos = self.pos + 1
    if ch >= C["0"] and ch <= C["7"] then
        if ch == C["0"] then
            -- Although '0' preceding any digit is treated as LegacyOctalEscapeSequence,
            -- '\08' should separately be interpreted as '\0' + '8'.
            if not stringutil.IsDigit(self:char()) then
                return "\0"
            end
            -- '\01', '\011'
        end
        if ch <= C["3"] then
            -- '\1', '\17', '\177'
            if stringutil.IsOctalDigit(self:char()) then
                self.pos = self.pos + 1
            end
            -- '\17', '\177'
        end
        -- '\4', '\47' but not '\477'
        if stringutil.IsOctalDigit(self:char()) then
            self.pos = self.pos + 1
        end
        -- '\47'
        self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
        if flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0 then
            local code = parseInt(ssub(text, start + 2, self.pos), 8, 32)
            if flags & EscapeSequenceScanningFlags.RegularExpression ~= 0 and flags & EscapeSequenceScanningFlags.AtomEscape == 0 and ch ~= C["0"] then
                self:errorAt(diagnostics.Octal_escape_sequences_and_backreferences_are_not_allowed_in_a_character_class_If_this_was_intended_as_an_escape_sequence_use_the_syntax_0_instead, start, self.pos - start, string.format("\\x%02x", code))
            else
                self:errorAt(diagnostics.Octal_escape_sequences_are_not_allowed_Use_the_syntax_0, start, self.pos - start, string.format("\\x%02x", code))
            end
            return core.EncodeRune(code)
        end
        return ssub(text, start + 1, self.pos)
    elseif ch == C["8"] or ch == C["9"] then
        -- the invalid '\8' and '\9'
        self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
        if flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0 then
            if flags & EscapeSequenceScanningFlags.RegularExpression ~= 0 and flags & EscapeSequenceScanningFlags.AtomEscape == 0 then
                self:errorAt(diagnostics.Decimal_escape_sequences_and_backreferences_are_not_allowed_in_a_character_class, start, self.pos - start)
            else
                self:errorAt(diagnostics.Escape_sequence_0_is_not_allowed, start, self.pos - start, ssub(text, start + 1, self.pos))
            end
            return string.char(ch)
        end
        return ssub(text, start + 1, self.pos)
    elseif ch == C["b"] then
        return "\b"
    elseif ch == C["t"] then
        return "\t"
    elseif ch == C["n"] then
        return "\n"
    elseif ch == C["v"] then
        return "\v"
    elseif ch == C["f"] then
        return "\f"
    elseif ch == C["r"] then
        return "\r"
    elseif ch == C["'"] then
        return "'"
    elseif ch == C['"'] then
        return "\""
    elseif ch == C["u"] then
        -- '\uDDDD' and '\u{DDDDDD}'
        local extended = self:char() == C["{"]
        self.pos = self.pos - 2
        local codePoint = self:scanUnicodeEscape(flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0)
        if extended then
            if flags & EscapeSequenceScanningFlags.AllowExtendedUnicodeEscape == 0 then
                self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
                if flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0 then
                    self:errorAt(diagnostics.Unicode_escape_sequences_are_only_available_when_the_Unicode_u_flag_or_the_Unicode_Sets_v_flag_is_set, start, self.pos - start)
                end
            end
            if codePoint < 0 then
                return ssub(text, start + 1, self.pos)
            end
            -- In string literals, a high surrogate \u{...} followed by a low
            -- surrogate escape forms a single code point, exactly as adjacent
            -- UTF-16 code units would in a JavaScript string.
            if flags & EscapeSequenceScanningFlags.RegularExpression == 0 and stringutil.IsHighSurrogate(codePoint) then
                local combined, ok = self:scanLowSurrogateEscape(codePoint)
                if ok then
                    return core.EncodeRune(combined)
                end
            end
            return stringutil.EncodeJSStringRune(codePoint)
        end
        if codePoint < 0 then
            return ssub(text, start + 1, self.pos)
        elseif stringutil.IsHighSurrogate(codePoint) then
            if flags & EscapeSequenceScanningFlags.RegularExpression == 0 then
                -- Combine \uHigh followed by any low surrogate escape (\uLow or
                -- \u{Low}) into a single code point in string literals, matching
                -- how adjacent UTF-16 code units pair in a JavaScript string.
                local combined, ok = self:scanLowSurrogateEscape(codePoint)
                if ok then
                    return core.EncodeRune(combined)
                end
            elseif flags & EscapeSequenceScanningFlags.AnyUnicodeMode ~= 0 and
                self:char() == C["\\"] and self:charAt(1) == C["u"] and self:charAt(2) ~= C["{"] then
                -- In regex AnyUnicodeMode, combine \uHigh\uLow so scanClassRanges
                -- can compare the pair numerically. In non-unicode regex mode they
                -- are separate atoms, and extended \u{...} escapes never combine.
                local savedPos = self.pos
                local nextCodePoint = self:scanUnicodeEscape(flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0)
                if stringutil.IsLowSurrogate(nextCodePoint) then
                    return core.EncodeRune(stringutil.SurrogatePairToCodePoint(codePoint, nextCodePoint))
                end
                self.pos = savedPos
            end
        end
        -- Lone surrogate: encode as CESU-8 so it survives losslessly. In a
        -- non-unicode regex this also lets scanClassRanges compare it numerically.
        return stringutil.EncodeJSStringRune(codePoint)
    elseif ch == C["x"] then
        -- '\xDD'
        while self.pos < start + 4 do
            if not stringutil.IsHexDigit(self:char()) then
                self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
                if flags & EscapeSequenceScanningFlags.ReportInvalidEscapeErrors ~= 0 then
                    self:error(diagnostics.Hexadecimal_digit_expected)
                end
                return ssub(text, start + 1, self.pos)
            end
            self.pos = self.pos + 1
        end
        self.tokenFlags = self.tokenFlags | TokenFlags.HexEscape
        local escapedValue = parseInt(ssub(text, start + 3, self.pos), 16, 32)
        return core.EncodeRune(escapedValue)
    elseif ch == C["\r"] or ch == C["\n"] then
        -- when encountering a LineContinuation (i.e. a backslash and a line terminator sequence),
        -- the line terminator is interpreted to be "the empty code unit sequence".
        if ch == C["\r"] and self:char() == C["\n"] then
            self.pos = self.pos + 1
        end
        return ""
    else
        -- ch was read as a single byte; for multi-byte UTF-8 characters,
        -- we need to decode the full rune and advance past all its bytes.
        if ch >= RuneSelf then
            self.pos = self.pos - 1 -- back up past the single-byte advance
            local size
            ch, size = core.DecodeRune(text, self.pos)
            self.pos = self.pos + size
        end
        -- LineContinuation: a backslash followed by a line terminator is "the empty code unit sequence".
        if ch == 0x2028 or ch == 0x2029 then
            return ""
        end
        if flags & EscapeSequenceScanningFlags.AnyUnicodeMode ~= 0 or
            (flags & EscapeSequenceScanningFlags.RegularExpression ~= 0 and flags & EscapeSequenceScanningFlags.AnnexB == 0 and scanner.IsIdentifierPart(ch)) then
            self:errorAt(diagnostics.This_character_cannot_be_escaped_in_a_regular_expression, start, self.pos - start)
        end
        return core.EncodeRune(ch)
    end
end

-- Known to be at \u
function Scanner:scanUnicodeEscape(shouldEmitInvalidEscapeError)
    self.pos = self.pos + 2
    local start = self.pos
    local extended = self:char() == C["{"]
    local hexDigits
    if extended then
        self.pos = self.pos + 1
        hexDigits = self:scanHexDigits(1, true, false)
    else
        self.tokenFlags = self.tokenFlags | TokenFlags.UnicodeEscape
        hexDigits = self:scanHexDigits(4, false, false)
    end
    if hexDigits == "" then
        self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
        if shouldEmitInvalidEscapeError then
            self:error(diagnostics.Hexadecimal_digit_expected)
        end
        return -1
    end
    local hexValue = parseInt(hexDigits, 16, 32)
    if extended then
        local isInvalidExtendedEscape = false
        if hexValue > 0x10FFFF then
            if shouldEmitInvalidEscapeError then
                self:errorAt(diagnostics.An_extended_Unicode_escape_value_must_be_between_0x0_and_0x10FFFF_inclusive, start + 1, self.pos - start - 1)
            end
            isInvalidExtendedEscape = true
        end
        if self.pos >= self.end_ then
            if shouldEmitInvalidEscapeError then
                self:error(diagnostics.Unexpected_end_of_text)
            end
            isInvalidExtendedEscape = true
        elseif self:char() == C["}"] then
            self.pos = self.pos + 1
        else
            if shouldEmitInvalidEscapeError then
                self:error(diagnostics.Unterminated_Unicode_escape_sequence)
            end
            isInvalidExtendedEscape = true
        end
        if isInvalidExtendedEscape then
            self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidEscape
            return -1
        end
        self.tokenFlags = self.tokenFlags | TokenFlags.ExtendedUnicodeEscape
    end
    return hexValue
end

-- scanLowSurrogateEscape attempts to consume a low-surrogate Unicode escape
-- (either '\uLow' or '\u{Low}') immediately following an already-scanned high
-- surrogate and combine them into a single supplementary code point. This
-- mirrors how adjacent UTF-16 code units form a surrogate pair in a JavaScript
-- string, regardless of which escape syntax produced each half. On success it
-- returns the combined code point and true; otherwise it restores the scanner
-- position and returns false.
function Scanner:scanLowSurrogateEscape(high)
    if self:char() ~= C["\\"] or self:charAt(1) ~= C["u"] then
        return 0, false
    end
    local savedPos = self.pos
    local savedTokenFlags = self.tokenFlags
    -- Speculatively scan the escape with diagnostics suppressed: if it isn't a
    -- low surrogate we rewind below, and the caller re-scans the same escape and
    -- reports any error then, so reporting here would duplicate diagnostics.
    local low = self:scanUnicodeEscape(false)
    if stringutil.IsLowSurrogate(low) then
        return stringutil.SurrogatePairToCodePoint(high, low), true
    end
    self.pos = savedPos
    self.tokenFlags = savedTokenFlags
    return 0, false
end

-- Current character is known to be a backslash. Check for Unicode escape of the form '\uXXXX'
-- or '\u{XXXXXX}' and return code point value if valid Unicode escape is found. Otherwise return -1.
function Scanner:peekUnicodeEscape()
    if self:charAt(1) == C["u"] then
        local savePos = self.pos
        local saveTokenFlags = self.tokenFlags
        local codePoint = self:scanUnicodeEscape(false)
        self.pos = savePos
        self.tokenFlags = saveTokenFlags
        return codePoint
    end
    return -1
end

function Scanner:scanNumber()
    local text = self.text
    local start = self.pos
    local fixedPart
    if self:char() == C["0"] then
        self.pos = self.pos + 1
        if self:char() == C["_"] then
            self.tokenFlags = self.tokenFlags | TokenFlags.ContainsSeparator | TokenFlags.ContainsInvalidSeparator
            self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos, 1)
            self.pos = start
            fixedPart = self:scanNumberFragment()
        else
            local digits, isOctal = self:scanDigits()
            if digits == "" then
                fixedPart = "0"
            elseif not isOctal then
                self.tokenFlags = self.tokenFlags | TokenFlags.ContainsLeadingZero
                fixedPart = digits
            else
                local val = parseInt(digits, 8, 64)
                self.tokenValue = string.format("%d", val)
                self.tokenFlags = self.tokenFlags | TokenFlags.Octal
                local withMinus = self.token == Kind.MinusToken
                local literal = (withMinus and "-" or "") .. "0o" .. string.format("%o", val)
                if withMinus then
                    start = start - 1
                end
                self:errorAt(diagnostics.Octal_literals_are_not_allowed_Use_the_syntax_0, start, self.pos - start, literal)
                return Kind.NumericLiteral
            end
        end
    else
        fixedPart = self:scanNumberFragment()
    end
    local fixedPartEnd = self.pos
    local fractionalPart = ""
    local exponentPreamble = ""
    local exponentPart = ""
    if self:char() == C["."] then
        self.pos = self.pos + 1
        fractionalPart = self:scanNumberFragment()
    end
    local end_ = self.pos
    if self:char() == C["E"] or self:char() == C["e"] then
        self.pos = self.pos + 1
        self.tokenFlags = self.tokenFlags | TokenFlags.Scientific
        if self:char() == C["+"] or self:char() == C["-"] then
            self.pos = self.pos + 1
        end
        local startNumericPart = self.pos
        exponentPart = self:scanNumberFragment()
        if exponentPart == "" then
            self:error(diagnostics.Digit_expected)
        else
            exponentPreamble = ssub(text, end_ + 1, startNumericPart)
            end_ = self.pos
        end
    end
    if self.tokenFlags & TokenFlags.ContainsSeparator ~= 0 then
        self.tokenValue = fixedPart
        if fractionalPart ~= "" then
            self.tokenValue = self.tokenValue .. "." .. fractionalPart
        end
        if exponentPart ~= "" then
            self.tokenValue = self.tokenValue .. exponentPreamble .. exponentPart
        end
    else
        self.tokenValue = ssub(text, start + 1, end_)
    end
    if self.tokenFlags & TokenFlags.ContainsLeadingZero ~= 0 then
        self:errorAt(diagnostics.Decimals_with_leading_zeros_are_not_allowed, start, self.pos - start)
        self.tokenValue = jsnum.Number_String(jsnum.FromString(self.tokenValue))
        return Kind.NumericLiteral
    end
    local result
    if fixedPartEnd == self.pos then
        result = self:scanBigIntSuffix()
    else
        self.tokenValue = jsnum.Number_String(jsnum.FromString(self.tokenValue))
        result = Kind.NumericLiteral
    end
    local ch = self:charAndSize()
    if scanner.IsIdentifierStart(ch) then
        local idStart = self.pos
        local id = self:scanIdentifierParts()
        if result ~= Kind.BigIntLiteral and #id == 1 and sbyte(text, idStart + 1) == C["n"] then
            if self.tokenFlags & TokenFlags.Scientific ~= 0 then
                self:errorAt(diagnostics.A_bigint_literal_cannot_use_exponential_notation, start, self.pos - start)
                return result
            end
            if fixedPartEnd < idStart then
                self:errorAt(diagnostics.A_bigint_literal_must_be_an_integer, start, self.pos - start)
                return result
            end
        end
        self:errorAt(diagnostics.An_identifier_or_keyword_cannot_immediately_follow_a_numeric_literal, idStart, self.pos - idStart)
        self.pos = idStart
    end
    return result
end

function Scanner:scanNumberFragment()
    local text = self.text
    local start = self.pos
    local allowSeparator = false
    local isPreviousTokenSeparator = false
    local result = {}
    local resultLen = 0
    while true do
        local before = self.pos
        self:scanASCIIWhile(isDecimalDigitByte)
        if self.pos > before then
            allowSeparator = true
            isPreviousTokenSeparator = false
        end
        local ch = self:char()
        if ch == C["_"] then
            self.tokenFlags = self.tokenFlags | TokenFlags.ContainsSeparator
            if allowSeparator then
                allowSeparator = false
                isPreviousTokenSeparator = true
                local piece = ssub(text, start + 1, self.pos)
                result[#result + 1] = piece
                resultLen = resultLen + #piece
            else
                self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidSeparator
                if isPreviousTokenSeparator then
                    self:errorAt(diagnostics.Multiple_consecutive_numeric_separators_are_not_permitted, self.pos, 1)
                else
                    self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos, 1)
                end
            end
            self.pos = self.pos + 1
            start = self.pos
        else
            break
        end
    end
    if isPreviousTokenSeparator then
        self.tokenFlags = self.tokenFlags | TokenFlags.ContainsInvalidSeparator
        self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos - 1, 1)
    end
    if resultLen == 0 then
        return ssub(text, start + 1, self.pos)
    end
    result[#result + 1] = ssub(text, start + 1, self.pos)
    return table.concat(result)
end

function Scanner:scanDigits()
    local start = self.pos
    local isOctal = true
    while stringutil.IsDigit(self:char()) do
        if not stringutil.IsOctalDigit(self:char()) then
            isOctal = false
        end
        self.pos = self.pos + 1
    end
    return ssub(self.text, start + 1, self.pos), isOctal
end

function Scanner:scanHexDigits(minCount, scanAsManyAsPossible, canHaveSeparators)
    local digitCount = 0
    local start = self.pos
    local allowSeparator = false
    local isPreviousTokenSeparator = false
    while digitCount < minCount or scanAsManyAsPossible do
        local ch = self:char()
        if stringutil.IsHexDigit(ch) then
            allowSeparator = canHaveSeparators
            isPreviousTokenSeparator = false
            digitCount = digitCount + 1
        elseif canHaveSeparators and ch == C["_"] then
            self.tokenFlags = self.tokenFlags | TokenFlags.ContainsSeparator
            if allowSeparator then
                allowSeparator = false
                isPreviousTokenSeparator = true
            elseif isPreviousTokenSeparator then
                self:errorAt(diagnostics.Multiple_consecutive_numeric_separators_are_not_permitted, self.pos, 1)
            else
                self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos, 1)
            end
        else
            break
        end
        self.pos = self.pos + 1
    end
    if isPreviousTokenSeparator then
        self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos - 1, 1)
    end
    if digitCount < minCount then
        return ""
    end
    local digits = ssub(self.text, start + 1, self.pos)
    if self.hexDigitCache == nil then
        self.hexDigitCache = {}
    end
    local cached = self.hexDigitCache[digits]
    if cached ~= nil then
        return cached
    else
        local original = digits
        if self.tokenFlags & TokenFlags.ContainsSeparator ~= 0 then
            digits = string.gsub(digits, "_", "")
        end
        digits = string.lower(digits) -- standardize hex literals to lowercase
        self.hexDigitCache[original] = digits
        return digits
    end
end

function Scanner:scanBinaryOrOctalDigits(base)
    local sb = {}
    local allowSeparator = false
    local isPreviousTokenSeparator = false
    while true do
        local ch = self:char()
        if stringutil.IsDigit(ch) and ch - C["0"] < base then
            sb[#sb + 1] = string.char(ch)
            allowSeparator = true
            isPreviousTokenSeparator = false
        elseif ch == C["_"] then
            self.tokenFlags = self.tokenFlags | TokenFlags.ContainsSeparator
            if allowSeparator then
                allowSeparator = false
                isPreviousTokenSeparator = true
            elseif isPreviousTokenSeparator then
                self:errorAt(diagnostics.Multiple_consecutive_numeric_separators_are_not_permitted, self.pos, 1)
            else
                self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos, 1)
            end
        else
            break
        end
        self.pos = self.pos + 1
    end
    if isPreviousTokenSeparator then
        self:errorAt(diagnostics.Numeric_separators_are_not_allowed_here, self.pos - 1, 1)
    end
    return table.concat(sb)
end

function Scanner:scanBigIntSuffix()
    if self:char() == C["n"] then
        self.tokenValue = self.tokenValue .. "n"
        if self.tokenFlags & TokenFlags.BinaryOrOctalSpecifier ~= 0 then
            self.tokenValue = jsnum.ParsePseudoBigInt(self.tokenValue) .. "n"
        end
        self.pos = self.pos + 1
        return Kind.BigIntLiteral
    end
    if self.numberCache == nil then
        self.numberCache = {}
    end
    local cached = self.numberCache[self.tokenValue]
    if cached ~= nil then
        self.tokenValue = cached
    else
        local tokenValue = jsnum.Number_String(jsnum.FromString(self.tokenValue))
        if tokenValue == self.tokenValue then
            tokenValue = self.tokenValue
        end
        self.numberCache[self.tokenValue] = tokenValue
        self.tokenValue = tokenValue
    end
    return Kind.NumericLiteral
end

function Scanner:scanInvalidCharacter()
    local _, size = self:charAndSize()
    self:errorAt(diagnostics.Invalid_character, self.pos, size)
    self.pos = self.pos + size
    self.token = Kind.Unknown
end
