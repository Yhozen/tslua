local scanner = require("tslua.scanner")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local stringutil = require("tslua.stringutil")

local ScriptTarget = core.ScriptTarget
local EscapeSequenceScanningFlags = scanner.EscapeSequenceScanningFlags
local Scanner = scanner.Scanner

local sbyte, ssub = string.byte, string.sub

local C = {}
for i = 0, 127 do
    C[string.char(i)] = i
end

local RuneError = 0xFFFD

-- Go utf16.RuneLen.
local function utf16RuneLen(r)
    if 0 <= r and r < 0xD800 or 0xE000 <= r and r < 0x10000 then
        return 1
    elseif 0x10000 <= r and r <= 0x10FFFF then
        return 2
    end
    return -1
end

-- Go strconv.Atoi; returns nil on error (syntax or range).
local function atoi(s)
    if s == "" or not string.match(s, "^%d+$") then
        return nil
    end
    local v = 0
    for i = 1, #s do
        local d = sbyte(s, i) - 48
        if v > (math.maxinteger - d) // 10 then
            return nil
        end
        v = v * 10 + d
    end
    return v
end

-- Sorted keys of a string-keyed table (Go maps.Keys has random order; sorting keeps the
-- candidate order deterministic).
local function sortedKeys(m)
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

scanner.regularExpressionFlags = {
    None = 0,
    HasIndices = 1 << 0, -- d
    Global = 1 << 1, -- g
    IgnoreCase = 1 << 2, -- i
    Multiline = 1 << 3, -- m
    DotAll = 1 << 4, -- s
    Unicode = 1 << 5, -- u
    UnicodeSets = 1 << 6, -- v
    Sticky = 1 << 7, -- y
}
local regularExpressionFlags = scanner.regularExpressionFlags
regularExpressionFlags.AnyUnicodeMode = regularExpressionFlags.Unicode | regularExpressionFlags.UnicodeSets
regularExpressionFlags.Modifiers = regularExpressionFlags.IgnoreCase | regularExpressionFlags.Multiline | regularExpressionFlags.DotAll

scanner.charCodeToRegExpFlag = {
    [C["d"]] = regularExpressionFlags.HasIndices,
    [C["g"]] = regularExpressionFlags.Global,
    [C["i"]] = regularExpressionFlags.IgnoreCase,
    [C["m"]] = regularExpressionFlags.Multiline,
    [C["s"]] = regularExpressionFlags.DotAll,
    [C["u"]] = regularExpressionFlags.Unicode,
    [C["v"]] = regularExpressionFlags.UnicodeSets,
    [C["y"]] = regularExpressionFlags.Sticky,
}

scanner.regExpFlagToFirstAvailableLanguageVersion = {
    [regularExpressionFlags.HasIndices] = ScriptTarget.ES2022,
    [regularExpressionFlags.DotAll] = ScriptTarget.ES2018,
    [regularExpressionFlags.UnicodeSets] = ScriptTarget.ES2024,
}

local function scriptTargetLowerName(target)
    return string.lower(core.ScriptTarget_names[target])
end

function Scanner:checkRegularExpressionFlagAvailability(flag, pos, size)
    local availableFrom = scanner.regExpFlagToFirstAvailableLanguageVersion[flag]
    if availableFrom ~= nil and self:languageVersion() < availableFrom then
        self:errorAt(diagnostics.This_regular_expression_flag_is_only_available_when_targeting_0_or_later, pos, size, scriptTargetLowerName(availableFrom))
    end
end

scanner.classSetExpressionType = {
    Unknown = 0,
    ClassUnion = 1,
    ClassIntersection = 2,
    ClassSubtraction = 3,
}
local classSetExpressionType = scanner.classSetExpressionType

-- groupNameReference: { pos, end_, name }; decimalEscapeValue: { pos, end_, value }

local regExpParser = {}
regExpParser.__index = regExpParser
scanner.regExpParser = regExpParser

-- Struct literal &regExpParser{...} from Scanner.ReScanSlashToken.
function scanner.newRegExpParser(s, end_, regExpFlags, anyUnicodeMode, unicodeSetsMode, annexB, namedCaptureGroups)
    local p = setmetatable({}, regExpParser)
    p.scanner = s
    p.end_ = end_
    p.regExpFlags = regExpFlags
    p.anyUnicodeMode = anyUnicodeMode
    p.unicodeSetsMode = unicodeSetsMode
    p.annexB = annexB
    p.anyUnicodeModeOrNonAnnexB = false
    p.namedCaptureGroups = namedCaptureGroups
    -- See scanClassSetExpression.
    p.mayContainStrings = false
    -- The number of all (named and unnamed) capturing groups defined in the regex.
    p.numberOfCapturingGroups = 0
    -- All named capturing groups defined in the regex.
    p.groupSpecifiers = {}
    -- All references to named capturing groups in the regex.
    p.groupNameReferences = {}
    -- All numeric backreferences within the regex.
    p.decimalEscapes = {}
    -- A stack of scopes for named capturing groups. See scanGroupName.
    p.namedCapturingGroups = {}
    -- pendingLowSurrogate holds the low surrogate to emit on the next
    -- scanSourceCharacter call when Corsa has to split a non-BMP rune into
    -- UTF-16 surrogate code units in non-unicode mode. Strada did not need
    -- this bookkeeping because its source text was already indexed as UTF-16.
    p.pendingLowSurrogate = 0
    return p
end

function regExpParser:pos()
    return self.scanner.pos
end

function regExpParser:setPos(v)
    self.scanner.pos = v
end

function regExpParser:incPos(n)
    self.scanner.pos = self.scanner.pos + n
end

function regExpParser:char()
    return self.scanner:char()
end

function regExpParser:charAt(pos)
    return self.scanner:charAt(pos - self:pos())
end

function regExpParser:error(msg, pos, length, ...)
    self.scanner:errorAt(msg, pos, length, ...)
end

function regExpParser:text()
    return self.scanner.text
end

function scanner.compareDecimalStrings(a, b)
    a = string.gsub(a, "^0+", "")
    b = string.gsub(b, "^0+", "")
    if a == "" then
        a = "0"
    end
    if b == "" then
        b = "0"
    end
    if #a ~= #b then
        if #a < #b then
            return -1
        end
        return 1
    end
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- Disjunction ::= Alternative ('|' Alternative)*
function regExpParser:scanDisjunction(isInGroup)
    -- Names defined by any of this disjunction's alternatives. Since exactly one
    -- alternative is chosen at runtime, these names are unioned together (rather
    -- than intersected) and, when this disjunction is nested inside a group,
    -- bubbled up into the enclosing alternative's scope once the group closes.
    -- This ensures a name defined inside a nested group (e.g. `(?:(?<a>x))`) is
    -- still visible to a duplicate check for a sibling group later in the same
    -- enclosing alternative (e.g. `(?:(?<a>x))(?<a>z)`).
    local disjunctionNames = {}
    while true do
        self.namedCapturingGroups[#self.namedCapturingGroups + 1] = {}
        self:scanAlternative(isInGroup)
        local alternativeNames = self.namedCapturingGroups[#self.namedCapturingGroups]
        self.namedCapturingGroups[#self.namedCapturingGroups] = nil
        for name in pairs(alternativeNames) do
            disjunctionNames[name] = true
        end
        if self:char() ~= C["|"] then
            break
        end
        self:incPos(1)
    end
    if isInGroup and #self.namedCapturingGroups > 0 then
        local parentScope = self.namedCapturingGroups[#self.namedCapturingGroups]
        for name in pairs(disjunctionNames) do
            parentScope[name] = true
        end
    end
end

-- Alternative ::= Term*
-- Term ::=
--
--	| Assertion
--	| Atom Quantifier?
--
-- Assertion ::=
--
--	| '^'
--	| '$'
--	| '\b'
--	| '\B'
--	| '(?=' Disjunction ')'
--	| '(?!' Disjunction ')'
--	| '(?<=' Disjunction ')'
--	| '(?<!' Disjunction ')'
--
-- Quantifier ::= QuantifierPrefix '?'?
-- QuantifierPrefix ::=
--
--	| '*'
--	| '+'
--	| '?'
--	| '{' DecimalDigits (',' DecimalDigits?)? '}'
--
-- Atom ::=
--
--	| PatternCharacter
--	| '.'
--	| '\' AtomEscape
--	| CharacterClass
--	| '(?<' RegExpIdentifierName '>' Disjunction ')'
--	| '(?' RegularExpressionFlags ('-' RegularExpressionFlags)? ':' Disjunction ')'
--
-- CharacterClass ::= unicodeMode
--
--	? '[' ClassRanges ']'
--	: '[' ClassSetExpression ']'
function regExpParser:scanAlternative(isInGroup)
    local isPreviousTermQuantifiable = false
    while self:pos() < self.end_ do
        local start = self:pos()
        local ch = self:char()
        if ch == C["^"] or ch == C["$"] then
            self:incPos(1)
            isPreviousTermQuantifiable = false
        elseif ch == C["\\"] then
            self:incPos(1)
            local c = self:char()
            if c == C["b"] or c == C["B"] then
                self:incPos(1)
                isPreviousTermQuantifiable = false
            else
                self:scanAtomEscape()
                isPreviousTermQuantifiable = true
            end
        elseif ch == C["("] then
            self:incPos(1)
            if self:char() == C["?"] then
                self:incPos(1)
                local c = self:char()
                if c == C["="] or c == C["!"] then
                    self:incPos(1)
                    -- In Annex B, `(?=Disjunction)` and `(?!Disjunction)` are quantifiable
                    isPreviousTermQuantifiable = not self.anyUnicodeModeOrNonAnnexB
                elseif c == C["<"] then
                    local groupNameStart = self:pos()
                    self:incPos(1)
                    local c2 = self:char()
                    if c2 == C["="] or c2 == C["!"] then
                        self:incPos(1)
                        isPreviousTermQuantifiable = false
                    else
                        self:scanGroupName(false --[[isReference]])
                        self:scanExpectedChar(C[">"])
                        if self.scanner:languageVersion() < ScriptTarget.ES2018 then
                            self:error(diagnostics.Named_capturing_groups_are_only_available_when_targeting_ES2018_or_later, groupNameStart, self:pos() - groupNameStart)
                        end
                        self.numberOfCapturingGroups = self.numberOfCapturingGroups + 1
                        isPreviousTermQuantifiable = true
                    end
                else
                    local flagsStart = self:pos()
                    local setFlags = self:scanPatternModifiers(regularExpressionFlags.None)
                    if self:char() == C["-"] then
                        self:incPos(1)
                        self:scanPatternModifiers(setFlags)
                        if self:pos() == flagsStart + 1 then
                            self:error(diagnostics.Subpattern_flags_must_be_present_when_there_is_a_minus_sign, flagsStart, self:pos() - flagsStart)
                        end
                    end
                    -- Modifier characters were consumed, so this is `(?flags:` rather than a plain `(?:` group.
                    if self:pos() ~= flagsStart and self.scanner:languageVersion() < ScriptTarget.ES2025 then
                        self:error(diagnostics.Regular_expression_pattern_modifiers_are_only_available_when_targeting_0_or_later, flagsStart, self:pos() - flagsStart, scriptTargetLowerName(ScriptTarget.ES2025))
                    end
                    self:scanExpectedChar(C[":"])
                    isPreviousTermQuantifiable = true
                end
            else
                self.numberOfCapturingGroups = self.numberOfCapturingGroups + 1
                isPreviousTermQuantifiable = true
            end
            self:scanDisjunction(true --[[isInGroup]])
            self:scanExpectedChar(C[")"])
        elseif ch == C["{"] or ch == C["*"] or ch == C["+"] or ch == C["?"] then
            if ch == C["{"] then
                self:incPos(1)
                local digitsStart = self:pos()
                self:scanDigits()
                local minStr = self.scanner.tokenValue
                if not self.anyUnicodeModeOrNonAnnexB and minStr == "" then
                    isPreviousTermQuantifiable = true
                    goto continue
                end
                if self:char() == C[","] then
                    self:incPos(1)
                    self:scanDigits()
                    local maxStr = self.scanner.tokenValue
                    if minStr == "" then
                        if maxStr ~= "" or self:char() == C["}"] then
                            self:error(diagnostics.Incomplete_quantifier_Digit_expected, digitsStart, 0)
                        else
                            self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, start, 1, string.char(ch))
                            isPreviousTermQuantifiable = true
                            goto continue
                        end
                    elseif maxStr ~= "" then
                        if scanner.compareDecimalStrings(minStr, maxStr) > 0 and (self.anyUnicodeModeOrNonAnnexB or self:char() == C["}"]) then
                            self:error(diagnostics.Numbers_out_of_order_in_quantifier, digitsStart, self:pos() - digitsStart)
                        end
                    end
                elseif minStr == "" then
                    if self.anyUnicodeModeOrNonAnnexB then
                        self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, start, 1, string.char(ch))
                    end
                    isPreviousTermQuantifiable = true
                    goto continue
                end
                if self:char() ~= C["}"] then
                    if self.anyUnicodeModeOrNonAnnexB then
                        self:error(diagnostics.X_0_expected, self:pos(), 0, "}")
                        self:incPos(-1)
                    else
                        isPreviousTermQuantifiable = true
                        goto continue
                    end
                end
            end
            self:incPos(1)
            if self:char() == C["?"] then
                -- Non-greedy
                self:incPos(1)
            end
            if not isPreviousTermQuantifiable then
                self:error(diagnostics.There_is_nothing_available_for_repetition, start, self:pos() - start)
            end
            isPreviousTermQuantifiable = false
        elseif ch == C["."] then
            self:incPos(1)
            isPreviousTermQuantifiable = true
        elseif ch == C["["] then
            self:incPos(1)
            if self.unicodeSetsMode then
                self:scanClassSetExpression()
            else
                self:scanClassRanges()
                self.pendingLowSurrogate = 0
            end
            self:scanExpectedChar(C["]"])
            isPreviousTermQuantifiable = true
        elseif ch == C[")"] and isInGroup then
            return
        elseif ch == C[")"] or ch == C["]"] or ch == C["}"] then
            if self.anyUnicodeModeOrNonAnnexB or ch == C[")"] then
                self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, self:pos(), 1, string.char(ch))
            end
            self:incPos(1)
            isPreviousTermQuantifiable = true
        elseif ch == C["/"] or ch == C["|"] then
            return
        else
            self:scanSourceCharacter()
            isPreviousTermQuantifiable = true
        end
        ::continue::
    end
end

function regExpParser:scanPatternModifiers(currFlags)
    while self:pos() < self.end_ do
        local ch, size = core.DecodeRune(self:text(), self:pos())
        if ch == RuneError or not scanner.IsIdentifierPart(ch) then
            break
        end
        local flag = scanner.charCodeToRegExpFlag[ch]
        if flag == nil then
            self:error(diagnostics.Unknown_regular_expression_flag, self:pos(), size)
        elseif currFlags & flag ~= 0 then
            self:error(diagnostics.Duplicate_regular_expression_flag, self:pos(), size)
        elseif flag & regularExpressionFlags.Modifiers == 0 then
            self:error(diagnostics.This_regular_expression_flag_cannot_be_toggled_within_a_subpattern, self:pos(), size)
        else
            -- Modifier syntax itself requires ES2025, which is later than any flag that can appear
            -- here, so the group's own diagnostic already covers availability.
            currFlags = currFlags | flag
        end
        self:incPos(size)
    end
    return currFlags
end

-- AtomEscape ::=
--
--	| DecimalEscape
--	| CharacterClassEscape
--	| CharacterEscape
--	| 'k<' RegExpIdentifierName '>'
function regExpParser:scanAtomEscape()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["\\"])
    local ch = self:char()
    if ch == C["k"] then
        self:incPos(1)
        if self:char() == C["<"] then
            self:incPos(1)
            self:scanGroupName(true --[[isReference]])
            self:scanExpectedChar(C[">"])
        elseif self.anyUnicodeModeOrNonAnnexB or self.namedCaptureGroups then
            self:error(diagnostics.X_k_must_be_followed_by_a_capturing_group_name_enclosed_in_angle_brackets, self:pos() - 2, 2)
        end
        return
    end
    if ch == C["q"] and self.unicodeSetsMode then
        self:incPos(1)
        self:error(diagnostics.X_q_is_only_available_inside_character_class, self:pos() - 2, 2)
        return
    end
    if not self:scanCharacterClassEscape() and not self:scanDecimalEscape() then
        -- Regex literals cannot contain line breaks here, so a character escape must consume something.
        local escaped = self:scanCharacterEscape(true --[[atomEscape]])
        debug.Assert(escaped ~= "")
    end
end

-- DecimalEscape ::= [1-9] [0-9]*
function regExpParser:scanDecimalEscape()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["\\"])
    local ch = self:char()
    if ch >= C["1"] and ch <= C["9"] then
        local start = self:pos()
        self:scanDigits()
        local val = atoi(self.scanner.tokenValue)
        if val == nil then
            val = math.maxinteger
        end
        self.decimalEscapes[#self.decimalEscapes + 1] = { pos = start, end_ = self:pos(), value = val }
        return true
    end
    return false
end

local identityEscapeChars = {}
for c in string.gmatch("^$/\\.*+?()[]{}|", ".") do
    identityEscapeChars[C[c]] = true
end

-- CharacterEscape ::=
--
--	| `c` ControlLetter
--	| IdentityEscape
--	| (Other sequences handled by `scanEscapeSequence`)
--
-- IdentityEscape ::=
--
--	| '^' | '$' | '/' | '\' | '.' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
--	| [~AnyUnicodeMode] (any other non-identifier characters)
function regExpParser:scanCharacterEscape(atomEscape)
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["\\"])
    local ch = self:char()
    if ch == -1 then
        self:error(diagnostics.Undetermined_character_escape, self:pos() - 1, 1)
        return "\\"
    elseif ch == C["c"] then
        self:incPos(1)
        ch = self:char()
        if stringutil.IsASCIILetter(ch) then
            self:incPos(1)
            return core.EncodeRune(ch & 0x1f)
        end
        if self.anyUnicodeModeOrNonAnnexB then
            self:error(diagnostics.X_c_must_be_followed_by_an_ASCII_letter, self:pos() - 2, 2)
        elseif atomEscape then
            self:incPos(-1)
            return "\\"
        end
        return core.EncodeRune(ch)
    elseif identityEscapeChars[ch] then
        self:incPos(1)
        return string.char(ch)
    else
        self:incPos(-1) -- back up to include the backslash for scanEscapeSequence
        local flags = EscapeSequenceScanningFlags.RegularExpression
        if self.annexB then
            flags = flags | EscapeSequenceScanningFlags.AnnexB
        end
        if self.anyUnicodeMode then
            flags = flags | EscapeSequenceScanningFlags.AnyUnicodeMode
        end
        if atomEscape then
            flags = flags | EscapeSequenceScanningFlags.AtomEscape
        end
        return self.scanner:scanEscapeSequence(flags)
    end
end

function regExpParser:scanGroupName(isReference)
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["<"])
    local s = self.scanner
    s.tokenStart = self:pos()
    s:scanIdentifier(0)
    if self:pos() == s.tokenStart then
        self:error(diagnostics.Expected_a_capturing_group_name, self:pos(), 0)
    elseif isReference then
        self.groupNameReferences[#self.groupNameReferences + 1] = { pos = s.tokenStart, end_ = self:pos(), name = s.tokenValue }
    elseif self:namedCapturingGroupsContains(s.tokenValue) then
        self:error(diagnostics.Named_capturing_groups_with_the_same_name_must_be_mutually_exclusive_to_each_other, s.tokenStart, self:pos() - s.tokenStart)
    else
        -- A previous definition can only have come from a mutually exclusive alternative.
        -- Below ES2018 the group itself is already reported, so don't stack a second error on it.
        if self.groupSpecifiers[s.tokenValue] and
            s:languageVersion() >= ScriptTarget.ES2018 and
            s:languageVersion() < ScriptTarget.ES2025 then
            self:error(diagnostics.Duplicate_named_capturing_groups_are_only_available_when_targeting_0_or_later, s.tokenStart, self:pos() - s.tokenStart, scriptTargetLowerName(ScriptTarget.ES2025))
        end
        if #self.namedCapturingGroups > 0 then
            self.namedCapturingGroups[#self.namedCapturingGroups][s.tokenValue] = true
        end
        self.groupSpecifiers[s.tokenValue] = true
    end
end

function regExpParser:namedCapturingGroupsContains(name)
    for _, group in ipairs(self.namedCapturingGroups) do
        if group[name] then
            return true
        end
    end
    return false
end

function regExpParser:isClassContentExit(ch)
    return ch == C["]"] or self:pos() >= self.end_
end

-- ClassRanges ::= '^'? (ClassAtom ('-' ClassAtom)?)*
function regExpParser:scanClassRanges()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["["])
    self.pendingLowSurrogate = 0
    if self:char() == C["^"] then
        self:incPos(1)
    end
    while self:pos() < self.end_ do
        local ch = self:char()
        if self:isClassContentExit(ch) then
            return
        end
        local minStart = self:pos()
        local minCharacter = self:scanClassAtom()
        if self:char() == C["-"] then
            self:incPos(1)
            ch = self:char()
            if self:isClassContentExit(ch) then
                return
            end
            if minCharacter == "" and self.anyUnicodeModeOrNonAnnexB then
                self:error(diagnostics.A_character_class_range_must_not_be_bounded_by_another_character_class, minStart, self:pos() - 1 - minStart)
            end
            local maxStart = self:pos()
            local maxCharacter = self:scanClassAtom()
            if maxCharacter == "" and self.anyUnicodeModeOrNonAnnexB then
                self:error(diagnostics.A_character_class_range_must_not_be_bounded_by_another_character_class, maxStart, self:pos() - maxStart)
                goto continue
            end
            if minCharacter == "" then
                goto continue
            end
            local minCharacterValue, minSize = stringutil.DecodeJSStringRune(minCharacter)
            local maxCharacterValue, maxSize = stringutil.DecodeJSStringRune(maxCharacter)
            if #minCharacter == minSize and #maxCharacter == maxSize and minCharacterValue > maxCharacterValue then
                self:error(diagnostics.Range_out_of_order_in_character_class, minStart, self:pos() - minStart)
            end
        end
        ::continue::
    end
end

-- Static Semantics: MayContainStrings
--     ClassUnion: ClassSetOperands.some(ClassSetOperand => ClassSetOperand.MayContainStrings)
--     ClassIntersection: ClassSetOperands.every(ClassSetOperand => ClassSetOperand.MayContainStrings)
--     ClassSubtraction: ClassSetOperands[0].MayContainStrings
--     ClassSetOperand:
--         || ClassStringDisjunctionContents.MayContainStrings
--         || CharacterClassEscape.UnicodePropertyValueExpression.LoneUnicodePropertyNameOrValue.MayContainStrings
--     ClassStringDisjunctionContents: ClassStrings.some(ClassString => ClassString.ClassSetCharacters.length !== 1)
--     LoneUnicodePropertyNameOrValue: isBinaryUnicodePropertyOfStrings(LoneUnicodePropertyNameOrValue)

-- ClassSetExpression ::= '^'? (ClassUnion | ClassIntersection | ClassSubtraction)
-- ClassUnion ::= (ClassSetRange | ClassSetOperand)*
-- ClassIntersection ::= ClassSetOperand ('&&' ClassSetOperand)+
-- ClassSubtraction ::= ClassSetOperand ('--' ClassSetOperand)+
-- ClassSetRange ::= ClassSetCharacter '-' ClassSetCharacter
function regExpParser:scanClassSetExpression()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["["])
    local isCharacterComplement = false
    if self:char() == C["^"] then
        self:incPos(1)
        isCharacterComplement = true
    end
    local expressionMayContainStrings = false
    local ch = self:char()
    if self:isClassContentExit(ch) then
        return
    end
    local start = self:pos()
    local operand = ""
    local twoChars = ""
    if self:pos() + 1 < self.end_ then
        twoChars = ssub(self:text(), self:pos() + 1, self:pos() + 2)
    end
    if twoChars == "--" or twoChars == "&&" then
        self:error(diagnostics.Expected_a_class_set_operand, self:pos(), 0)
        self.mayContainStrings = false
    else
        operand = self:scanClassSetOperand()
    end
    local c = self:char()
    if c == C["-"] then
        if self:pos() + 1 < self.end_ and self:charAt(self:pos() + 1) == C["-"] then
            if isCharacterComplement and self.mayContainStrings then
                self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, start, self:pos() - start)
            end
            expressionMayContainStrings = self.mayContainStrings
            self:scanClassSetSubExpression(classSetExpressionType.ClassSubtraction)
            self.mayContainStrings = not isCharacterComplement and expressionMayContainStrings
            return
        end
    elseif c == C["&"] then
        if self:pos() + 1 < self.end_ and self:charAt(self:pos() + 1) == C["&"] then
            self:scanClassSetSubExpression(classSetExpressionType.ClassIntersection)
            if isCharacterComplement and self.mayContainStrings then
                self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, start, self:pos() - start)
            end
            expressionMayContainStrings = self.mayContainStrings
            self.mayContainStrings = not isCharacterComplement and expressionMayContainStrings
            return
        end
    else
        if isCharacterComplement and self.mayContainStrings then
            self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, start, self:pos() - start)
        end
        expressionMayContainStrings = self.mayContainStrings
    end
    while self:pos() < self.end_ do
        ch = self:char()
        if ch == C["-"] then
            self:incPos(1)
            ch = self:char()
            if self:isClassContentExit(ch) then
                self.mayContainStrings = not isCharacterComplement and expressionMayContainStrings
                return
            end
            if ch == C["-"] then
                self:incPos(1)
                self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos() - 2, 2)
                start = self:pos() - 2
                operand = ssub(self:text(), start + 1, self:pos())
                goto continue
            else
                if operand == "" then
                    self:error(diagnostics.A_character_class_range_must_not_be_bounded_by_another_character_class, start, self:pos() - 1 - start)
                end
                local secondStart = self:pos()
                local secondOperand = self:scanClassSetOperand()
                if isCharacterComplement and self.mayContainStrings then
                    self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, secondStart, self:pos() - secondStart)
                end
                expressionMayContainStrings = expressionMayContainStrings or self.mayContainStrings
                if secondOperand == "" then
                    self:error(diagnostics.A_character_class_range_must_not_be_bounded_by_another_character_class, secondStart, self:pos() - secondStart)
                elseif operand ~= "" then
                    local minCharacterValue, minSize = stringutil.DecodeJSStringRune(operand)
                    local maxCharacterValue, maxSize = stringutil.DecodeJSStringRune(secondOperand)
                    if #operand == minSize and #secondOperand == maxSize and minCharacterValue > maxCharacterValue then
                        self:error(diagnostics.Range_out_of_order_in_character_class, start, self:pos() - start)
                    end
                end
            end
        elseif ch == C["&"] then
            if self:pos() + 1 < self.end_ and self:charAt(self:pos() + 1) == C["&"] then
                start = self:pos()
                self:incPos(2)
                self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos() - 2, 2)
                if self:char() == C["&"] then
                    self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, self:pos(), 1, string.char(ch))
                    self:incPos(1)
                end
                operand = ssub(self:text(), start + 1, self:pos())
                goto continue
            end
        end
        if self:isClassContentExit(self:char()) then
            break
        end
        start = self:pos()
        twoChars = ""
        if self:pos() + 1 < self.end_ then
            twoChars = ssub(self:text(), self:pos() + 1, self:pos() + 2)
        end
        if twoChars == "--" or twoChars == "&&" then
            self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos(), 2)
            self:incPos(2)
            operand = ssub(self:text(), start + 1, self:pos())
        else
            operand = self:scanClassSetOperand()
            if isCharacterComplement and self.mayContainStrings then
                self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, start, self:pos() - start)
            end
            expressionMayContainStrings = expressionMayContainStrings or self.mayContainStrings
        end
        ::continue::
    end
    self.mayContainStrings = not isCharacterComplement and expressionMayContainStrings
end

function regExpParser:scanClassSetSubExpression(expressionType)
    local expressionMayContainStrings = self.mayContainStrings
    while self:pos() < self.end_ do
        local ch = self:char()
        if self:isClassContentExit(ch) then
            break
        end
        if ch == C["-"] then
            self:incPos(1)
            if self:char() == C["-"] then
                self:incPos(1)
                if expressionType ~= classSetExpressionType.ClassSubtraction then
                    self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos() - 2, 2)
                end
            else
                self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos() - 1, 1)
            end
        elseif ch == C["&"] then
            self:incPos(1)
            if self:char() == C["&"] then
                self:incPos(1)
                if expressionType ~= classSetExpressionType.ClassIntersection then
                    self:error(diagnostics.Operators_must_not_be_mixed_within_a_character_class_Wrap_it_in_a_nested_class_instead, self:pos() - 2, 2)
                end
                if self:char() == C["&"] then
                    self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, self:pos(), 1, string.char(ch))
                    self:incPos(1)
                end
            else
                self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, self:pos() - 1, 1, string.char(ch))
            end
        else
            if expressionType == classSetExpressionType.ClassSubtraction then
                self:error(diagnostics.X_0_expected, self:pos(), 0, "--")
            elseif expressionType == classSetExpressionType.ClassIntersection then
                self:error(diagnostics.X_0_expected, self:pos(), 0, "&&")
            end
        end
        ch = self:char()
        if self:isClassContentExit(ch) then
            self:error(diagnostics.Expected_a_class_set_operand, self:pos(), 0)
            break
        end
        self:scanClassSetOperand()
        if expressionType == classSetExpressionType.ClassIntersection then
            expressionMayContainStrings = expressionMayContainStrings and self.mayContainStrings
        end
    end
    self.mayContainStrings = expressionMayContainStrings
end

-- ClassSetOperand ::=
--
--	| '[' ClassSetExpression ']'
--	| '\' CharacterClassEscape
--	| '\q{' ClassStringDisjunctionContents '}'
--	| ClassSetCharacter
function regExpParser:scanClassSetOperand()
    self.mayContainStrings = false
    local ch = self:char()
    if ch == C["["] then
        self:incPos(1)
        self:scanClassSetExpression()
        self:scanExpectedChar(C["]"])
        return ""
    elseif ch == C["\\"] then
        self:incPos(1)
        if self:scanCharacterClassEscape() then
            return ""
        elseif self:char() == C["q"] then
            self:incPos(1)
            if self:char() == C["{"] then
                self:incPos(1)
                self:scanClassStringDisjunctionContents()
                self:scanExpectedChar(C["}"])
                return ""
            else
                self:error(diagnostics.X_q_must_be_followed_by_string_alternatives_enclosed_in_braces, self:pos() - 2, 2)
                return "q"
            end
        end
        self:incPos(-1)
    end
    return self:scanClassSetCharacter()
end

-- ClassStringDisjunctionContents ::= ClassSetCharacter* ('|' ClassSetCharacter*)*
function regExpParser:scanClassStringDisjunctionContents()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["{"])
    local characterCount = 0
    while self:pos() < self.end_ do
        local ch = self:char()
        if ch == C["}"] then
            if characterCount ~= 1 then
                self.mayContainStrings = true
            end
            return
        elseif ch == C["|"] then
            if characterCount ~= 1 then
                self.mayContainStrings = true
            end
            self:incPos(1)
            characterCount = 0
        else
            self:scanClassSetCharacter()
            characterCount = characterCount + 1
        end
    end
end

local function charSet(chars)
    local set = {}
    for c in string.gmatch(chars, ".") do
        set[C[c]] = true
    end
    return set
end

local classSetReservedPunctuators = charSet("&-!#%,:;<=>@`~")
local classSetReservedDoublePunctuators = charSet("&!#%*+,.:;<=>?@`~")
local classSetSyntaxCharacters = charSet("/()[]{}-|")

-- ClassSetCharacter ::=
--
--	| SourceCharacter -- ClassSetSyntaxCharacter -- ClassSetReservedDoublePunctuator
--	| '\' (CharacterEscape | ClassSetReservedPunctuator | 'b')
function regExpParser:scanClassSetCharacter()
    local ch = self:char()
    if ch == C["\\"] then
        self:incPos(1)
        local innerCh = self:char()
        if innerCh == C["b"] then
            self:incPos(1)
            return "\b"
        elseif classSetReservedPunctuators[innerCh] then
            self:incPos(1)
            return string.char(innerCh)
        else
            return self:scanCharacterEscape(false --[[atomEscape]])
        end
    elseif self:pos() + 1 < self.end_ and ch == self:charAt(self:pos() + 1) then
        if classSetReservedDoublePunctuators[ch] then
            self:error(diagnostics.A_character_class_must_not_contain_a_reserved_double_punctuator_Did_you_mean_to_escape_it_with_backslash, self:pos(), 2)
            self:incPos(2)
            return ssub(self:text(), self:pos() - 1, self:pos())
        end
    end
    if classSetSyntaxCharacters[ch] then
        self:error(diagnostics.Unexpected_0_Did_you_mean_to_escape_it_with_backslash, self:pos(), 1, string.char(ch))
        self:incPos(1)
        return string.char(ch)
    end
    return self:scanSourceCharacter()
end

-- ClassAtom ::=
--
--	| SourceCharacter but not one of '\' or ']'
--	| '\' ClassEscape
--
-- ClassEscape ::=
--
--	| 'b'
--	| '-'
--	| CharacterClassEscape
--	| CharacterEscape
function regExpParser:scanClassAtom()
    if self:char() == C["\\"] then
        self:incPos(1)
        local ch = self:char()
        if ch == C["b"] then
            self:incPos(1)
            return "\b"
        elseif ch == C["-"] then
            self:incPos(1)
            return string.char(ch)
        else
            if self:scanCharacterClassEscape() then
                return ""
            end
            return self:scanCharacterEscape(false --[[atomEscape]])
        end
    else
        return self:scanSourceCharacter()
    end
end

-- CharacterClassEscape ::=
--
--	| 'd' | 'D' | 's' | 'S' | 'w' | 'W'
--	| [+AnyUnicodeMode] ('P' | 'p') '{' UnicodePropertyValueExpression '}'
function regExpParser:scanCharacterClassEscape()
    debug.Assert(self:pos() > 0 and sbyte(self:text(), self:pos()) == C["\\"])
    local isCharacterComplement = false
    local start = self:pos() - 1
    local ch = self:char()
    if ch == C["d"] or ch == C["D"] or ch == C["s"] or ch == C["S"] or ch == C["w"] or ch == C["W"] then
        self:incPos(1)
        return true
    elseif ch == C["P"] or ch == C["p"] then
        if ch == C["P"] then
            isCharacterComplement = true
        end
        self:incPos(1)
        if self:char() == C["{"] then
            self:incPos(1)
            local propertyNameOrValueStart = self:pos()
            local propertyNameOrValue = self:scanWordCharacters()
            if self:char() == C["="] then
                local propertyName = scanner.nonBinaryUnicodeProperties[propertyNameOrValue] or ""
                if self:pos() == propertyNameOrValueStart then
                    self:error(diagnostics.Expected_a_Unicode_property_name, self:pos(), 0)
                elseif propertyName == "" then
                    self:error(diagnostics.Unknown_Unicode_property_name, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart)
                    local suggestion = self:getSpellingSuggestionForUnicodePropertyName(propertyNameOrValue)
                    if suggestion ~= nil and suggestion ~= "" then
                        self:error(diagnostics.Did_you_mean_0, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart, suggestion)
                    end
                end
                self:incPos(1)
                local propertyValueStart = self:pos()
                local propertyValue = self:scanWordCharacters()
                if self:pos() == propertyValueStart then
                    self:error(diagnostics.Expected_a_Unicode_property_value, self:pos(), 0)
                elseif propertyName ~= "" then
                    local values = scanner.valuesOfNonBinaryUnicodeProperties[propertyName]
                    if values ~= nil and not values:Has(propertyValue) then
                        self:error(diagnostics.Unknown_Unicode_property_value, propertyValueStart, self:pos() - propertyValueStart)
                        local suggestion = self:getSpellingSuggestionForUnicodePropertyValue(propertyName, propertyValue)
                        if suggestion ~= nil and suggestion ~= "" then
                            self:error(diagnostics.Did_you_mean_0, propertyValueStart, self:pos() - propertyValueStart, suggestion)
                        end
                    end
                end
            else
                if self:pos() == propertyNameOrValueStart then
                    self:error(diagnostics.Expected_a_Unicode_property_name_or_value, self:pos(), 0)
                elseif scanner.binaryUnicodePropertiesOfStrings:Has(propertyNameOrValue) then
                    if not self.unicodeSetsMode then
                        self:error(diagnostics.Any_Unicode_property_that_would_possibly_match_more_than_a_single_character_is_only_available_when_the_Unicode_Sets_v_flag_is_set, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart)
                    elseif isCharacterComplement then
                        self:error(diagnostics.Anything_that_would_possibly_match_more_than_a_single_character_is_invalid_inside_a_negated_character_class, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart)
                    else
                        self.mayContainStrings = true
                    end
                elseif not scanner.valuesOfNonBinaryUnicodeProperties["General_Category"]:Has(propertyNameOrValue) and not scanner.binaryUnicodeProperties:Has(propertyNameOrValue) then
                    self:error(diagnostics.Unknown_Unicode_property_name_or_value, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart)
                    local suggestion = self:getSpellingSuggestionForUnicodePropertyNameOrValue(propertyNameOrValue)
                    if suggestion ~= nil and suggestion ~= "" then
                        self:error(diagnostics.Did_you_mean_0, propertyNameOrValueStart, self:pos() - propertyNameOrValueStart, suggestion)
                    end
                end
            end
            self:scanExpectedChar(C["}"])
            if not self.anyUnicodeMode then
                self:error(diagnostics.Unicode_property_value_expressions_are_only_available_when_the_Unicode_u_flag_or_the_Unicode_Sets_v_flag_is_set, start, self:pos() - start)
            end
        elseif self.anyUnicodeModeOrNonAnnexB then
            self:error(diagnostics.X_0_must_be_followed_by_a_Unicode_property_value_expression_enclosed_in_braces, self:pos() - 2, 2, string.char(ch))
        else
            self:incPos(-1)
            return false
        end
        return true
    end
    return false
end

function regExpParser:getSpellingSuggestionForUnicodePropertyName(name)
    return core.GetSpellingSuggestionForStrings(name, scanner.nonBinaryUnicodePropertiesKeys)
end

function regExpParser:getSpellingSuggestionForUnicodePropertyValue(propertyName, value)
    local values = scanner.valuesOfNonBinaryUnicodeProperties[propertyName]
    if values == nil then
        return ""
    end
    return core.GetSpellingSuggestionForStrings(value, values:Keys())
end

function regExpParser:getSpellingSuggestionForUnicodePropertyNameOrValue(name)
    local candidates = {}
    for _, set in ipairs({
        scanner.valuesOfNonBinaryUnicodeProperties["General_Category"],
        scanner.binaryUnicodeProperties,
        scanner.binaryUnicodePropertiesOfStrings,
    }) do
        for _, k in ipairs(set:Keys()) do
            candidates[#candidates + 1] = k
        end
    end
    return core.GetSpellingSuggestionForStrings(name, candidates)
end

function regExpParser:scanWordCharacters()
    local start = self:pos()
    while self:pos() < self.end_ do
        local ch = self:char()
        if not scanner.isWordCharacter(ch) then
            break
        end
        self:incPos(1)
    end
    return ssub(self:text(), start + 1, self:pos())
end

function regExpParser:scanSourceCharacter()
    if self:pos() >= self.end_ then
        return ""
    end
    local text = self:text()
    if not self.anyUnicodeMode then
        if self.pendingLowSurrogate ~= 0 then
            -- Second of two surrogate code units for the same non-BMP character.
            -- Now advance past the full UTF-8 sequence (the high surrogate call did not advance).
            local _, size = core.DecodeRune(text, self:pos())
            self:incPos(size)
            local low = self.pendingLowSurrogate
            self.pendingLowSurrogate = 0
            return stringutil.EncodeJSStringRune(low)
        end
        local ch, size = core.DecodeRune(text, self:pos())
        if ch == RuneError or size == 0 then
            -- Not a valid rune; consume one raw byte.
            self:incPos(1)
            return core.EncodeRune(sbyte(text, self:pos()))
        end
        if utf16RuneLen(ch) == 2 then
            -- Non-BMP character: emit the high surrogate first WITHOUT advancing.
            -- The low surrogate will be emitted on the next call, which also advances.
            local high, low = stringutil.CodePointToSurrogatePair(ch)
            self.pendingLowSurrogate = low
            return stringutil.EncodeJSStringRune(high)
        end
        self:incPos(size)
        return core.EncodeRune(ch)
    end
    local ch, size = core.DecodeRune(text, self:pos())
    if size == 0 then
        return ""
    end
    if ch == RuneError then
        -- Invalid UTF-8; consume the byte to avoid infinite loops.
        self:incPos(size)
        return ""
    end
    self:incPos(size)
    return core.EncodeRune(ch)
end

function regExpParser:scanExpectedChar(ch)
    if self:char() == ch then
        self:incPos(1)
    else
        self:error(diagnostics.X_0_expected, self:pos(), 0, core.EncodeRune(ch))
    end
end

function regExpParser:scanDigits()
    local start = self:pos()
    while self:pos() < self.end_ and stringutil.IsDigit(self:char()) do
        self:incPos(1)
    end
    self.scanner.tokenValue = ssub(self:text(), start + 1, self:pos())
end

function regExpParser:run()
    -- Regular expressions are checked more strictly when either in 'u' or 'v' mode, or
    -- when not using the looser interpretation of the syntax from ECMA-262 Annex B.
    self.anyUnicodeModeOrNonAnnexB = self.anyUnicodeMode or not self.annexB

    self:scanDisjunction(false --[[isInGroup]])

    for _, reference in ipairs(self.groupNameReferences) do
        if not self.groupSpecifiers[reference.name] then
            self:error(diagnostics.There_is_no_capturing_group_named_0_in_this_regular_expression, reference.pos, reference.end_ - reference.pos, reference.name)
            if next(self.groupSpecifiers) ~= nil then
                local suggestion = core.GetSpellingSuggestionForStrings(reference.name, sortedKeys(self.groupSpecifiers))
                if suggestion ~= nil and suggestion ~= "" then
                    self:error(diagnostics.Did_you_mean_0, reference.pos, reference.end_ - reference.pos, suggestion)
                end
            end
        end
    end
    for _, escape in ipairs(self.decimalEscapes) do
        -- Although a DecimalEscape with a value greater than the number of capturing groups
        -- is treated as either a LegacyOctalEscapeSequence or an IdentityEscape in Annex B,
        -- an error is nevertheless reported since it's most likely a mistake.
        if escape.value > self.numberOfCapturingGroups then
            if self.numberOfCapturingGroups > 0 then
                self:error(diagnostics.This_backreference_refers_to_a_group_that_does_not_exist_There_are_only_0_capturing_groups_in_this_regular_expression, escape.pos, escape.end_ - escape.pos, self.numberOfCapturingGroups)
            else
                self:error(diagnostics.This_backreference_refers_to_a_group_that_does_not_exist_There_are_no_capturing_groups_in_this_regular_expression, escape.pos, escape.end_ - escape.pos)
            end
        end
    end
end
