local scanner = require("tslua.scanner")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local LanguageVariant = core.LanguageVariant

local sbyte, ssub, sfind = string.byte, string.sub, string.find

local C = {}
for i = 0, 127 do
    C[string.char(i)] = i
end

local RuneSelf = 0x80

-- Go utf16.RuneLen.
local function utf16RuneLen(r)
    if 0 <= r and r < 0xD800 or 0xE000 <= r and r < 0x10000 then
        return 1
    elseif 0x10000 <= r and r <= 0x10FFFF then
        return 2
    end
    return -1
end

function scanner.GetIdentifierToken(str)
    if #str >= 2 and #str <= 12 then
        local c0 = sbyte(str, 1)
        if c0 >= C["a"] and c0 <= C["z"] then
            local keyword = scanner.textToKeyword[str]
            if keyword ~= nil and keyword ~= Kind.Unknown then
                return keyword
            end
        end
    end
    return Kind.Identifier
end

function scanner.IsValidIdentifier(s)
    if #s == 0 then
        return false
    end
    for i, ch in core.Runes(s) do
        if i == 0 and not scanner.IsIdentifierStart(ch) or i ~= 0 and not scanner.IsIdentifierPart(ch) then
            return false
        end
    end
    return true
end

-- Section 6.1.4
function scanner.isWordCharacter(ch)
    return stringutil.IsASCIILetter(ch) or stringutil.IsDigit(ch) or ch == C["_"]
end

function scanner.IsIdentifierStart(ch)
    return stringutil.IsASCIILetter(ch) or ch == C["_"] or ch == C["$"] or ch >= RuneSelf and stringutil.IsUnicodeIdentifierStart(ch)
end

function scanner.IsIdentifierPart(ch)
    return scanner.IsIdentifierPartEx(ch, LanguageVariant.Standard)
end

function scanner.IsIdentifierPartEx(ch, languageVariant)
    return scanner.isWordCharacter(ch) or ch == C["$"] or
        ch >= RuneSelf and stringutil.IsUnicodeIdentifierPart(ch) or
        languageVariant == LanguageVariant.JSX and (ch == C["-"] or ch == C[":"]) -- "-" and ":" are valid in JSX Identifiers
end

-- Go [ast.KindCount]string: missing entries are "".
scanner.tokenToText = (function()
    local result = {}
    for text, kind in pairs(scanner.textToToken) do
        result[kind] = text
    end
    return result
end)()

function scanner.TokenToString(token)
    return scanner.tokenToText[token] or ""
end

function scanner.StringToToken(s)
    local kind = scanner.textToToken[s]
    if kind ~= nil then
        return kind
    end
    return Kind.Unknown
end

function scanner.GetViableKeywordSuggestions()
    local result = {}
    for _, text in ipairs(scanner.textToKeywordOrder) do
        if #text > 2 then
            result[#result + 1] = text
        end
    end
    return result
end

function scanner.couldStartTrivia(text, pos)
    -- Keep in sync with skipTrivia
    local ch = sbyte(text, pos + 1)
    -- Characters that could start normal trivia
    if ch == C["\r"] or ch == C["\n"] or ch == C["\t"] or ch == C["\v"] or ch == C["\f"] or ch == C[" "] or ch == C["/"] or
        -- Characters that could start conflict marker trivia
        ch == C["<"] or ch == C["|"] or ch == C["="] or ch == C[">"] then
        return true
    elseif ch == C["#"] then
        -- Only if its the beginning can we have #! trivia
        return pos == 0
    end
    return ch > scanner.maxAsciiCharacter
end

-- SkipTriviaOptions: { stopAfterLineBreak = bool, stopAtComments = bool, inJSDoc = bool }

function scanner.SkipTrivia(text, pos)
    return scanner.SkipTriviaEx(text, pos, nil)
end

function scanner.SkipTriviaEx(text, pos, options)
    if ast.PositionIsSynthesized(pos) then
        return pos
    end
    if options == nil then
        options = {}
    end
    local stopAfterLineBreak = options.stopAfterLineBreak == true
    local stopAtComments = options.stopAtComments == true
    local inJSDoc = options.inJSDoc == true

    local textLen = #text
    local canConsumeStar = false
    -- Keep in sync with couldStartTrivia
    while true do
        if pos >= textLen then
            return pos
        end
        local ch, size = core.DecodeRune(text, pos)
        if ch == C["\r"] or ch == C["\n"] then
            if ch == C["\r"] and pos + 1 < textLen and sbyte(text, pos + 2) == C["\n"] then
                pos = pos + 1
            end
            pos = pos + 1
            if stopAfterLineBreak then
                return pos
            end
            canConsumeStar = inJSDoc
            goto continue
        elseif ch == C["\t"] or ch == C["\v"] or ch == C["\f"] or ch == C[" "] then
            pos = pos + 1
            goto continue
        elseif ch == C["/"] then
            if not stopAtComments then
                if pos + 1 < textLen then
                    if sbyte(text, pos + 2) == C["/"] then
                        pos = pos + 2
                        while pos < textLen do
                            local ch2, size2 = core.DecodeRune(text, pos)
                            if stringutil.IsLineBreak(ch2) then
                                break
                            end
                            pos = pos + size2
                        end
                        canConsumeStar = false
                        goto continue
                    end
                    if sbyte(text, pos + 2) == C["*"] then
                        pos = pos + 2
                        while pos < textLen do
                            if sbyte(text, pos + 1) == C["*"] and (pos + 1 < textLen) and sbyte(text, pos + 2) == C["/"] then
                                pos = pos + 2
                                break
                            end
                            local _, size2 = core.DecodeRune(text, pos)
                            pos = pos + size2
                        end
                        canConsumeStar = false
                        goto continue
                    end
                end
            end
        elseif ch == C["<"] or ch == C["|"] or ch == C["="] or ch == C[">"] then
            if scanner.isConflictMarkerTrivia(text, pos) then
                pos = scanner.scanConflictMarkerTrivia(text, pos, nil)
                canConsumeStar = false
                goto continue
            end
        elseif ch == C["#"] then
            if pos == 0 and scanner.isShebangTrivia(text, pos) then
                pos = scanner.scanShebangTrivia(text, pos)
                canConsumeStar = false
                goto continue
            end
        elseif ch == C["*"] then
            if canConsumeStar then
                pos = pos + 1
                canConsumeStar = false
                goto continue
            end
        else
            if ch > scanner.maxAsciiCharacter and stringutil.IsWhiteSpaceLike(ch) then
                pos = pos + size
                goto continue
            end
        end
        do
            return pos
        end
        ::continue::
    end
end

-- All conflict markers consist of the same character repeated seven times.  If it is
-- a <<<<<<< or >>>>>>> marker then it is also followed by a space.
scanner.mergeConflictMarkerLength = #"<<<<<<<"
scanner.maxAsciiCharacter = 127

function scanner.isConflictMarkerTrivia(text, pos)
    if pos < 0 then
        error("pos < 0", 0)
    end

    -- Fast reject: a conflict marker is the same byte repeated seven times. If the
    -- second byte differs (the overwhelmingly common case for `<`, `>`, `=`, `|`
    -- tokens), it cannot be a marker, so skip the line-start check entirely.
    if pos + 1 >= #text or sbyte(text, pos + 2) ~= sbyte(text, pos + 1) then
        return false
    end

    -- Conflict markers must be at the start of a line.
    local atLineStart = pos == 0 or stringutil.IsLineBreak(sbyte(text, pos))
    if not atLineStart and pos >= 2 then
        local prev = core.DecodeLastRune(text, pos - 2)
        atLineStart = stringutil.IsLineBreak(prev)
    end
    if atLineStart then
        local ch = sbyte(text, pos + 1)
        local mergeConflictMarkerLength = scanner.mergeConflictMarkerLength

        if (pos + mergeConflictMarkerLength) < #text then
            for i = 0, mergeConflictMarkerLength - 1 do
                if sbyte(text, pos + i + 1) ~= ch then
                    return false
                end
            end

            return ch == C["="] or sbyte(text, pos + mergeConflictMarkerLength + 1) == C[" "]
        end
    end

    return false
end

function scanner.scanConflictMarkerTrivia(text, pos, reportError)
    if reportError ~= nil then
        reportError(diagnostics.Merge_conflict_marker_encountered, pos, scanner.mergeConflictMarkerLength)
    end
    local ch, size = core.DecodeRune(text, pos)
    local length = #text

    if ch == C["<"] or ch == C[">"] then
        while pos < length and not stringutil.IsLineBreak(ch) do
            pos = pos + size
            ch, size = core.DecodeRune(text, pos)
        end
    else
        if ch ~= C["|"] and ch ~= C["="] then
            error("Assertion failed: ch must be either '|' or '='", 0)
        end
        -- Consume everything from the start of a ||||||| or ======= marker to the start
        -- of the next ======= or >>>>>>> marker.
        while pos < length do
            local currentChar = sbyte(text, pos + 1)
            if (currentChar == C["="] or currentChar == C[">"]) and currentChar ~= ch and scanner.isConflictMarkerTrivia(text, pos) then
                break
            end

            pos = pos + 1
        end
    end

    return pos
end

function scanner.isShebangTrivia(text, pos)
    if #text < 2 then
        return false
    end
    if pos ~= 0 then
        error("Shebangs check must only be done at the start of the file", 0)
    end
    return sbyte(text, 1) == C["#"] and sbyte(text, 2) == C["!"]
end

function scanner.scanShebangTrivia(text, pos)
    pos = pos + 2
    while pos < #text do
        local ch, size = core.DecodeRune(text, pos)
        if stringutil.IsLineBreak(ch) then
            break
        end
        pos = pos + size
    end
    return pos
end

function scanner.GetShebang(text)
    if not scanner.isShebangTrivia(text, 0) then
        return ""
    end

    local end_ = scanner.scanShebangTrivia(text, 0)
    return ssub(text, 1, end_)
end

function scanner.GetScannerForSourceFile(sourceFile, pos)
    local s = scanner.NewScanner()
    s.text = sourceFile:Text()
    s.pos = pos
    s.end_ = #s.text
    s.languageVariant = sourceFile.languageVariant
    s:Scan()
    return s
end

function scanner.ScanTokenAtPosition(sourceFile, pos)
    local s = scanner.GetScannerForSourceFile(sourceFile, pos)
    return s.token
end

function scanner.GetRangeOfTokenAtPosition(sourceFile, pos)
    local s = scanner.GetScannerForSourceFile(sourceFile, pos)
    return core.NewTextRange(s.tokenStart, s.pos)
end

function scanner.GetTokenPosOfNode(node, sourceFile, includeJSDoc)
    -- With nodes that have no width (i.e. 'Missing' nodes), we actually *don't*
    -- want to skip trivia because this will launch us forward to the next token.
    if ast.NodeIsMissing(node) then
        return node:Pos()
    end
    if ast.IsJSDocNode(node) or node.kind == Kind.JsxText then
        -- JsxText cannot actually contain comments, even though the scanner will think it sees comments
        return scanner.SkipTriviaEx(sourceFile:Text(), node:Pos(), { stopAtComments = true })
    end
    if includeJSDoc and core.Len(node:JSDoc(sourceFile)) > 0 then
        return scanner.GetTokenPosOfNode(node:JSDoc(sourceFile)[1], sourceFile, false --[[includeJSDoc]])
    end
    return scanner.SkipTriviaEx(sourceFile:Text(), node:Pos(), { inJSDoc = node.flags & NodeFlags.JSDoc ~= 0 })
end

function scanner.getErrorRangeForArrowFunction(sourceFile, node)
    local pos = scanner.SkipTrivia(sourceFile:Text(), node:Pos())
    local body = node:Body()
    if body ~= nil and body.kind == Kind.Block then
        local startLine = scanner.GetECMALineOfPosition(sourceFile, body:Pos())
        local endLine = scanner.GetECMALineOfPosition(sourceFile, body:End())
        if startLine < endLine then
            -- The arrow function spans multiple lines, make the error span be the first line, inclusive.
            return core.NewTextRange(pos, scanner.GetECMAEndLinePosition(sourceFile, startLine) + 1)
        end
    end
    return core.NewTextRange(pos, node:End())
end

local function textRangeEqual(a, b)
    return a.pos == b.pos and a.end_ == b.end_
end

function scanner.findOriginatingJSDocSatisfiesTag(sourceFile, node)
    local targetType = node:AsSatisfiesExpression().type
    if targetType.flags & NodeFlags.Reparsed == 0 then
        return nil
    end
    local current = node.parent
    while current ~= nil do
        if current.flags & NodeFlags.HasJSDoc ~= 0 then
            local firstSatisfiesTag = nil
            for _, jsDoc in ipairs(current:EagerJSDoc(sourceFile) or {}) do
                local tags = jsDoc:AsJSDoc().tags
                if tags ~= nil then
                    for _, tag in ipairs(tags.nodes) do
                        if ast.IsJSDocSatisfiesTag(tag) then
                            if firstSatisfiesTag == nil then
                                firstSatisfiesTag = tag
                            end
                            local typeExpr = tag:AsJSDocSatisfiesTag().typeExpression
                            if typeExpr ~= nil then
                                local t = typeExpr:Type()
                                if t ~= nil and textRangeEqual(t.loc, targetType.loc) then
                                    return tag
                                end
                            end
                        end
                    end
                end
            end
            return firstSatisfiesTag
        end
        current = current.parent
    end
    return nil
end

function scanner.GetErrorRangeForNode(sourceFile, node)
    local errorNode = node
    local kind = node.kind
    if kind == Kind.SourceFile then
        local pos = scanner.SkipTrivia(sourceFile:Text(), 0)
        if pos == #sourceFile:Text() then
            return core.NewTextRange(0, 0)
        end
        return scanner.GetRangeOfTokenAtPosition(sourceFile, pos)
    -- This list is a work in progress. Add missing node kinds to improve their error spans
    elseif (kind == Kind.FunctionDeclaration or kind == Kind.MethodDeclaration) and node.flags & NodeFlags.Reparsed ~= 0 then
        errorNode = node
    elseif kind == Kind.FunctionDeclaration or kind == Kind.MethodDeclaration or
        kind == Kind.VariableDeclaration or kind == Kind.BindingElement or kind == Kind.ClassDeclaration or kind == Kind.InterfaceDeclaration or
        kind == Kind.ModuleDeclaration or kind == Kind.EnumDeclaration or kind == Kind.EnumMember or kind == Kind.FunctionExpression or
        kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration or kind == Kind.PropertyDeclaration or
        kind == Kind.PropertySignature or kind == Kind.NamespaceImport then
        errorNode = ast.GetNameOfDeclaration(node)
    elseif kind == Kind.ClassExpression then
        errorNode = node:Name()
    elseif kind == Kind.ArrowFunction then
        return scanner.getErrorRangeForArrowFunction(sourceFile, node)
    elseif kind == Kind.CaseClause or kind == Kind.DefaultClause then
        local start = scanner.SkipTrivia(sourceFile:Text(), node:Pos())
        local end_ = node:End()
        local statements = node:Statements()
        if core.Len(statements) ~= 0 then
            end_ = statements[1]:Pos()
        end
        return core.NewTextRange(start, end_)
    elseif kind == Kind.ReturnStatement or kind == Kind.YieldExpression then
        local pos = scanner.SkipTrivia(sourceFile:Text(), node:Pos())
        return scanner.GetRangeOfTokenAtPosition(sourceFile, pos)
    elseif kind == Kind.SatisfiesExpression then
        local jsDocSatisfiesTag = scanner.findOriginatingJSDocSatisfiesTag(sourceFile, node)
        if jsDocSatisfiesTag ~= nil then
            local pos = scanner.SkipTrivia(sourceFile:Text(), jsDocSatisfiesTag:TagName():Pos())
            return scanner.GetRangeOfTokenAtPosition(sourceFile, pos)
        end
        local pos = scanner.SkipTrivia(sourceFile:Text(), node:AsSatisfiesExpression().expression:End())
        return scanner.GetRangeOfTokenAtPosition(sourceFile, pos)
    elseif kind == Kind.Constructor then
        if node.flags & NodeFlags.Reparsed ~= 0 then
            errorNode = node
        else
            local s = scanner.GetScannerForSourceFile(sourceFile, node:Pos())
            local start = s:TokenStart()
            while s:Token() ~= Kind.ConstructorKeyword and s:Token() ~= Kind.StringLiteral and s:Token() ~= Kind.EndOfFile do
                s:Scan()
            end
            return core.NewTextRange(start, s:TokenEnd())
        end
    end
    if errorNode == nil then
        -- If we don't have a better node, then just set the error on the first token of
        -- construct.
        return scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
    end
    local pos = errorNode:Pos()
    if not ast.NodeIsMissing(errorNode) and not ast.IsJsxText(errorNode) then
        pos = scanner.SkipTrivia(sourceFile:Text(), pos)
    end
    return core.NewTextRange(pos, errorNode:End())
end

-- lineStarts: Lua array of 0-based positions; returns a 0-based line number.
function scanner.ComputeLineOfPosition(lineStarts, pos)
    local low = 0
    local high = #lineStarts - 1
    while low <= high do
        local middle = low + ((high - low) >> 1)
        local value = lineStarts[middle + 1]
        if value < pos then
            low = middle + 1
        elseif value > pos then
            high = middle - 1
        else
            return middle
        end
    end
    return low - 1
end

function scanner.GetECMALineStarts(sourceFile)
    return sourceFile:ECMALineMap()
end

function scanner.GetECMALineOfPosition(sourceFile, pos)
    local lineMap = scanner.GetECMALineStarts(sourceFile)
    return scanner.ComputeLineOfPosition(lineMap, pos)
end

-- GetECMALineAndUTF16CharacterOfPosition returns the 0-based line number and the
-- UTF-16 code unit offset from the start of that line for the given byte position.
-- Uses ECMAScript line separators (LF, CR, CRLF, LS, PS).
function scanner.GetECMALineAndUTF16CharacterOfPosition(sourceFile, pos)
    local lineMap = scanner.GetECMALineStarts(sourceFile)
    local line = scanner.ComputeLineOfPosition(lineMap, pos)
    local character = core.UTF16Len(ssub(sourceFile:Text(), lineMap[line + 1] + 1, pos))
    return line, character
end

-- GetECMALineAndByteOffsetOfPosition returns the 0-based line number and the
-- raw UTF-8 byte offset from the start of that line for the given byte position.
-- Uses ECMAScript line separators (LF, CR, CRLF, LS, PS).
-- Unlike GetECMALineAndUTF16CharacterOfPosition, the offset is in bytes, not UTF-16 code units.
function scanner.GetECMALineAndByteOffsetOfPosition(sourceFile, pos)
    local lineMap = scanner.GetECMALineStarts(sourceFile)
    local line = scanner.ComputeLineOfPosition(lineMap, pos)
    local byteOffset = pos - lineMap[line + 1]
    return line, byteOffset
end

function scanner.GetECMAEndLinePosition(sourceFile, line)
    local pos = scanner.GetECMALineStarts(sourceFile)[line + 1]
    local text = sourceFile:Text()
    while true do
        local ch, size = core.DecodeRune(text, pos)
        if size == 0 or stringutil.IsLineBreak(ch) then
            return pos - 1
        end
        pos = pos + size
    end
end

-- GetECMAPositionOfLineAndUTF16Character converts a 0-based line number and UTF-16
-- code unit character offset back to an absolute byte position in the source text.
-- Uses ECMAScript line separators.
function scanner.GetECMAPositionOfLineAndUTF16Character(sourceFile, line, character)
    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    return scanner.ComputePositionOfLineAndUTF16Character(lineStarts, line, character, sourceFile:Text(), false)
end

-- GetECMAPositionOfLineAndByteOffset converts a 0-based line number and byte offset
-- from line start back to an absolute byte position in the source text.
-- Uses ECMAScript line separators.
function scanner.GetECMAPositionOfLineAndByteOffset(sourceFile, line, byteOffset)
    return scanner.ComputePositionOfLineAndByteOffset(scanner.GetECMALineStarts(sourceFile), line, byteOffset)
end

-- ComputePositionOfLineAndByteOffset computes a byte position from a line and
-- raw byte offset from the line start. This is a simple addition with validation.
function scanner.ComputePositionOfLineAndByteOffset(lineStarts, line, byteOffset)
    if line < 0 or line >= #lineStarts then
        error(string.format("Bad line number. Line: %d, lineStarts.length: %d.", line, #lineStarts), 0)
    end
    return lineStarts[line + 1] + byteOffset
end

-- ComputePositionOfLineAndUTF16Character converts a line and UTF-16 character offset
-- back to a byte position. The character parameter is measured in UTF-16 code units.
-- It scans from the line start to correctly handle multi-byte characters.
-- When allowEdits is true, out-of-range values are clamped instead of panicking.
function scanner.ComputePositionOfLineAndUTF16Character(lineStarts, line, character, text, allowEdits)
    if line < 0 or line >= #lineStarts then
        if allowEdits then
            -- Clamp line to nearest allowable value
            if line < 0 then
                line = 0
            elseif line >= #lineStarts then
                line = #lineStarts - 1
            end
        else
            error(string.format("Bad line number. Line: %d, lineStarts.length: %d.", line, #lineStarts), 0)
        end
    end

    local lineStart = lineStarts[line + 1]

    if character > 0 then
        -- UTF-16 character offset: scan from line start counting UTF-16 code units.
        local lineEnd = #text
        if line + 1 < #lineStarts then
            lineEnd = lineStarts[line + 2]
        end
        local utf16Count = 0
        local pos = lineStart
        while pos < lineEnd do
            if utf16Count >= character then
                break
            end
            local r, size = core.DecodeRune(text, pos)
            utf16Count = utf16Count + utf16RuneLen(r)
            pos = pos + size
        end
        if not allowEdits then
            if pos == lineEnd and utf16Count < character then
                error(string.format("Bad UTF-16 character offset. Line: %d, character: %d.", line, character), 0)
            end
            debug.Assert(pos <= #text)
            return pos
        end
        if pos > #text then
            return #text
        end
        return pos
    end

    -- Character is 0: line start position.
    local res = lineStart

    if allowEdits then
        if res > #text then
            return #text
        end
        return res
    end
    debug.Assert(res <= #text) -- Allow single character overflow for trailing newline
    return res
end

-- Returns a Lua iterator over ast.CommentRange values (Go iter.Seq[ast.CommentRange]).
function scanner.GetLeadingCommentRanges(f, text, pos)
    return scanner.iterateCommentRanges(f, text, pos, false)
end

function scanner.GetTrailingCommentRanges(f, text, pos)
    return scanner.iterateCommentRanges(f, text, pos, true)
end

--[[
Returns an iterator over each comment range following the provided position.
Single-line comment ranges include the leading double-slash characters but not the ending
line break. Multi-line comment ranges include the leading slash-asterisk and trailing
asterisk-slash characters.
]]
-- The ranges are collected eagerly (NewCommentRange is pure) and returned through an iterator.
function scanner.iterateCommentRanges(f, text, pos, trailing)
    local results = {}
    local function yield(cr)
        results[#results + 1] = cr
    end
    local pendingPos = 0
    local pendingEnd = 0
    local pendingKind = Kind.Unknown
    local pendingHasTrailingNewLine = false
    local hasPendingCommentRange = false
    local collecting = trailing
    if pos == 0 then
        collecting = true
        if scanner.isShebangTrivia(text, pos) then
            pos = scanner.scanShebangTrivia(text, pos)
        end
    end
    while pos >= 0 and pos < #text do
        local ch, size = core.DecodeRune(text, pos)
        if ch == C["\r"] or ch == C["\n"] then
            if ch == C["\r"] and pos + 1 < #text and sbyte(text, pos + 2) == C["\n"] then
                pos = pos + 1
            end
            pos = pos + 1
            if trailing then
                break
            end

            collecting = true
            if hasPendingCommentRange then
                pendingHasTrailingNewLine = true
            end
        elseif ch == C["\t"] or ch == C["\v"] or ch == C["\f"] or ch == C[" "] then
            pos = pos + 1
        elseif ch == C["/"] then
            local nextChar = 0
            if pos + 1 < #text then
                nextChar = sbyte(text, pos + 2)
            end
            local hasTrailingNewLine = false
            if nextChar == C["/"] or nextChar == C["*"] then
                local kind
                if nextChar == C["/"] then
                    kind = Kind.SingleLineCommentTrivia
                else
                    kind = Kind.MultiLineCommentTrivia
                end

                local startPos = pos
                pos = pos + 2
                if nextChar == C["/"] then
                    while pos < #text do
                        local c, s = core.DecodeRune(text, pos)
                        if stringutil.IsLineBreak(c) then
                            hasTrailingNewLine = true
                            break
                        end
                        pos = pos + s
                    end
                else
                    local i = sfind(text, "*/", pos + 1, true)
                    if i ~= nil then
                        pos = i + 1
                    else
                        pos = #text
                    end
                end

                if collecting then
                    if hasPendingCommentRange then
                        yield(f:NewCommentRange(pendingKind, pendingPos, pendingEnd, pendingHasTrailingNewLine))
                    end

                    pendingPos = startPos
                    pendingEnd = pos
                    pendingKind = kind
                    pendingHasTrailingNewLine = hasTrailingNewLine
                    hasPendingCommentRange = true
                end
            else
                break
            end
        else
            if ch > 127 --[[unicode.MaxASCII]] and stringutil.IsWhiteSpaceLike(ch) then
                if hasPendingCommentRange and stringutil.IsLineBreak(ch) then
                    pendingHasTrailingNewLine = true
                end
                pos = pos + size
            else
                break
            end
        end
    end

    if hasPendingCommentRange then
        yield(f:NewCommentRange(pendingKind, pendingPos, pendingEnd, pendingHasTrailingNewLine))
    end

    local i = 0
    return function()
        i = i + 1
        return results[i]
    end
end
