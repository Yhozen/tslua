local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local TokenFlags = ast.TokenFlags
local QuoteChar = printer.QuoteChar

local sbyte = string.byte
local ssub = string.sub

-- getLiteralTextFlags
printer.getLiteralTextFlagsNone = 0
printer.getLiteralTextFlagsNeverAsciiEscape = 1 << 0
printer.getLiteralTextFlagsJsxAttributeEscape = 1 << 1
printer.getLiteralTextFlagsTerminateUnterminatedLiterals = 1 << 2
printer.getLiteralTextFlagsAllowNumericSeparator = 1 << 3

printer.jsxEscapedCharsMap = {
    [0x22] = "&quot;", -- '"'
    [0x27] = "&apos;", -- '\''
}

printer.escapedCharsMap = {
    [0x09] = "\\t",
    [0x0B] = "\\v",
    [0x0C] = "\\f",
    [0x08] = "\\b",
    [0x0D] = "\\r",
    [0x0A] = "\\n",
    [0x5C] = "\\\\",
    [0x22] = "\\\"",
    [0x27] = "\\'",
    [0x60] = "\\`",
    [0x24] = "\\$", -- when quoteChar == '`'
    [0x2028] = "\\u2028", -- lineSeparator
    [0x2029] = "\\u2029", -- paragraphSeparator
    [0x0085] = "\\u0085", -- nextLine
}

function printer.encodeJsxCharacterEntity(b, charCode)
    local hexCharCode = string.format("%X", charCode)
    b:WriteString("&#x")
    b:WriteString(hexCharCode)
    b:WriteByte(0x3B) -- ';'
end

function printer.encodeUtf16EscapeSequence(b, charCode)
    local hexCharCode = string.format("%X", charCode)
    b:WriteString("\\u")
    for _ = #hexCharCode, 3 do
        b:WriteByte(0x30) -- '0'
    end
    b:WriteString(hexCharCode)
end

-- Based heavily on the abstract 'Quote'/'QuoteJSONString' operation from ECMA-262 (24.3.2.2),
-- but augmented for a few select characters (e.g. lineSeparator, paragraphSeparator, nextLine)
-- Note that this doesn't actually wrap the input in double quotes.
function printer.escapeStringWorker(s, quoteChar, flags, b)
    local pos = 0
    local i = 0
    local n = #s
    while i < n do
        -- A rune is at most 4 bytes, so decoding a 4-byte window equals decoding s[i:].
        local ch, size = stringutil.DecodeJSStringRune(ssub(s, i + 1, i + 4))

        local escape = false
        if ch >= 0xD800 and ch <= 0xDFFF then
            escape = true
        elseif ch == core.RuneError and size == 1 then
            -- A stray byte that is not valid UTF-8 (for example, a fragment of a
            -- surrogate sentinel left behind by code that sliced the string by
            -- byte). Escape it as the Unicode replacement character so the output
            -- is always well-formed rather than containing raw invalid bytes.
            escape = true
        end

        -- This consists of the first 19 unprintable ASCII characters, canonical escapes, lineSeparator,
        -- paragraphSeparator, and nextLine. The latter three are just desirable to suppress new lines in
        -- the language service. These characters should be escaped when printing, and if any characters are added,
        -- `escapedCharsMap` and/or `jsxEscapedCharsMap` must be updated. Note that this *does not* include the 'delete'
        -- character. There is no reason for this other than that JSON.stringify does not handle it either.
        if ch == 0x5C then -- '\\'
            if flags & printer.getLiteralTextFlagsJsxAttributeEscape == 0 then
                escape = true
            end
        elseif ch == 0x24 then -- '$'
            if quoteChar == QuoteChar.Backtick and i + 1 < n and sbyte(s, i + 2) == 0x7B then -- '{'
                escape = true
            end
        elseif ch == quoteChar or ch == 0x2028 or ch == 0x2029 or ch == 0x0085 or ch == 0x0D then
            escape = true
        elseif ch == 0x0A then
            if quoteChar ~= QuoteChar.Backtick then
                -- Template strings preserve simple LF newlines, still encode CRLF (or CR).
                escape = true
            end
        else
            if ch <= 0x1F or flags & printer.getLiteralTextFlagsNeverAsciiEscape == 0 and ch > 0x7F then
                escape = true
            end
        end

        if escape then
            if pos < i then
                -- Write string up to this point
                b:WriteString(ssub(s, pos + 1, i))
            end

            if flags & printer.getLiteralTextFlagsJsxAttributeEscape ~= 0 then
                if ch == 0 then
                    b:WriteString("&#0;")
                elseif printer.jsxEscapedCharsMap[ch] ~= nil then
                    b:WriteString(printer.jsxEscapedCharsMap[ch])
                else
                    printer.encodeJsxCharacterEntity(b, ch)
                end
            else
                if ch == 0x0D and quoteChar == QuoteChar.Backtick and i + 1 < n and sbyte(s, i + 2) == 0x0A then
                    -- Template strings preserve simple LF newlines, but still must escape CRLF. Left alone, the
                    -- above cases for `\r` and `\n` would inadvertently escape CRLF as two independent characters.
                    size = size + 1
                    b:WriteString("\\r\\n")
                elseif ch > 0xFFFF then
                    -- encode as surrogate pair
                    ch = ch - 0x10000
                    printer.encodeUtf16EscapeSequence(b, ((ch & 0xFFC00) >> 10) + 0xD800)
                    printer.encodeUtf16EscapeSequence(b, (ch & 0x3FF) + 0xDC00)
                elseif ch >= 0xD800 and ch <= 0xDFFF then
                    printer.encodeUtf16EscapeSequence(b, ch)
                elseif ch == 0 then
                    if i + 1 < n and stringutil.IsDigit(sbyte(s, i + 2)) then
                        -- If the null character is followed by digits, print as a hex escape to prevent the result from
                        -- parsing as an octal (which is forbidden in strict mode)
                        b:WriteString("\\x00")
                    else
                        -- Otherwise, keep printing a literal \0 for the null character
                        b:WriteString("\\0")
                    end
                else
                    local match = printer.escapedCharsMap[ch]
                    if match ~= nil then
                        b:WriteString(match)
                    else
                        printer.encodeUtf16EscapeSequence(b, ch)
                    end
                end
            end
            pos = i + size
        end

        i = i + size
    end

    if pos < i then
        b:WriteString(ssub(s, pos + 1))
    end
end

function printer.EscapeString(s, quoteChar)
    local b = printer.newStringsBuilder()
    b:Grow(#s + 2)
    printer.escapeStringWorker(s, quoteChar, printer.getLiteralTextFlagsNeverAsciiEscape, b)
    return b:String()
end

function printer.escapeNonAsciiString(s, quoteChar)
    local b = printer.newStringsBuilder()
    b:Grow(#s + 2)
    printer.escapeStringWorker(s, quoteChar, printer.getLiteralTextFlagsNone, b)
    return b:String()
end

function printer.escapeJsxAttributeString(s, quoteChar)
    local b = printer.newStringsBuilder()
    b:Grow(#s + 2)
    printer.escapeStringWorker(s, quoteChar, printer.getLiteralTextFlagsJsxAttributeEscape | printer.getLiteralTextFlagsNeverAsciiEscape, b)
    return b:String()
end

function printer.canUseOriginalText(node, flags)
    -- A synthetic node has no original text, nor does a node without a parent as we would be unable to find the
    -- containing SourceFile. We also cannot use the original text if the literal was unterminated and the caller has
    -- requested proper termination of unterminated literals
    if ast.NodeIsSynthesized(node) or node.parent == nil or flags & printer.getLiteralTextFlagsTerminateUnterminatedLiterals ~= 0 and ast.IsUnterminatedLiteral(node) then
        return false
    end

    if node.kind == Kind.NumericLiteral then
        local tokenFlags = node:AsNumericLiteral().tokenFlags
        -- For a numeric literal, we cannot use the original text if the original text was an invalid literal
        if tokenFlags & TokenFlags.IsInvalid ~= 0 then
            return false
        end
        -- We also cannot use the original text if the literal contains numeric separators, but numeric separators
        -- are not permitted
        if tokenFlags & TokenFlags.ContainsSeparator ~= 0 then
            return flags & printer.getLiteralTextFlagsAllowNumericSeparator ~= 0
        end
    end

    -- Finally, we do not use the original text of a BigInt literal
    -- TODO(rbuckton): The reason as to why we do not use the original text for bigints is not mentioned in the
    -- original compiler source. It could be that this is no longer necessary, in which case bigint literals should
    -- use the same code path as numeric literals, above
    return node.kind ~= Kind.BigIntLiteral
end

function printer.getLiteralText(node, sourceFile, flags)
    -- If we don't need to downlevel and we can reach the original source text using
    -- the node's parent reference, then simply get the text as it was originally written.
    if sourceFile ~= nil and printer.canUseOriginalText(node, flags) then
        return scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node, false --[[includeTrivia]])
    end

    -- If we can't reach the original source text, use the canonical form if it's a number,
    -- or a (possibly escaped) quoted form of the original text if it's string-like.
    local kind = node.kind
    if kind == Kind.StringLiteral then
        local b = printer.newStringsBuilder()
        local quoteChar
        if node:AsStringLiteral().tokenFlags & TokenFlags.SingleQuote ~= 0 then
            quoteChar = QuoteChar.SingleQuote
        else
            quoteChar = QuoteChar.DoubleQuote
        end

        local text = node:Text()

        -- Write leading quote character
        b:Grow(#text + 2)
        b:WriteRune(quoteChar)

        -- Write text
        printer.escapeStringWorker(text, quoteChar, flags, b)

        -- Write trailing quote character
        b:WriteRune(quoteChar)
        return b:String()
    elseif kind == Kind.NoSubstitutionTemplateLiteral or
        kind == Kind.TemplateHead or
        kind == Kind.TemplateMiddle or
        kind == Kind.TemplateTail then
        -- If a NoSubstitutionTemplateLiteral appears to have a substitution in it, the original text
        -- had to include a backslash: `not \${a} substitution`.
        local b = printer.newStringsBuilder()
        local text = node:Text()
        local rawText = node:TemplateLiteralLikeData().rawText or ""
        local raw = #rawText > 0 or #text == 0

        local textLen
        if raw then
            textLen = #rawText
        else
            textLen = #text
        end

        -- Write leading quote character
        if kind == Kind.NoSubstitutionTemplateLiteral then
            b:Grow(2 + textLen)
            b:WriteRune(0x60) -- '`'
        elseif kind == Kind.TemplateHead then
            b:Grow(3 + textLen)
            b:WriteRune(0x60) -- '`'
        elseif kind == Kind.TemplateMiddle then
            b:Grow(3 + textLen)
            b:WriteRune(0x7D) -- '}'
        elseif kind == Kind.TemplateTail then
            b:Grow(2 + textLen)
            b:WriteRune(0x7D) -- '}'
        end

        -- Write text
        if #rawText > 0 or #text == 0 then
            -- If rawText is set, it is expected to be valid.
            b:WriteString(rawText)
        else
            printer.escapeStringWorker(text, QuoteChar.Backtick, flags, b)
        end

        -- Write trailing quote character
        if kind == Kind.NoSubstitutionTemplateLiteral then
            b:WriteRune(0x60) -- '`'
        elseif kind == Kind.TemplateHead then
            b:WriteString("${")
        elseif kind == Kind.TemplateMiddle then
            b:WriteString("${")
        elseif kind == Kind.TemplateTail then
            b:WriteRune(0x60) -- '`'
        end
        return b:String()
    elseif kind == Kind.NumericLiteral or kind == Kind.BigIntLiteral then
        return node:Text()
    elseif kind == Kind.RegularExpressionLiteral then
        if flags & printer.getLiteralTextFlagsTerminateUnterminatedLiterals ~= 0 and ast.IsUnterminatedLiteral(node) then
            local b = printer.newStringsBuilder()
            local text = node:Text()
            if #text > 0 and sbyte(text, #text) == 0x5C then -- '\\'
                b:Grow(2 + #text)
                b:WriteString(text)
                b:WriteString(" /")
            else
                b:Grow(1 + #text)
                b:WriteString(text)
                b:WriteString("/")
            end
            return b:String()
        end
        return node:Text()
    else
        error("Unsupported LiteralLikeNode", 0)
    end
end

function printer.isNotPrologueDirective(node)
    return not ast.IsPrologueDirective(node)
end

function printer.RangeIsOnSingleLine(r, sourceFile)
    return printer.rangeStartIsOnSameLineAsRangeEnd(r, r, sourceFile)
end

function printer.RangeStartPositionsAreOnSameLine(range1, range2, sourceFile)
    return printer.PositionsAreOnSameLine(
        printer.getStartPositionOfRange(range1, sourceFile, false --[[includeComments]]),
        printer.getStartPositionOfRange(range2, sourceFile, false --[[includeComments]]),
        sourceFile
    )
end

function printer.rangeEndPositionsAreOnSameLine(range1, range2, sourceFile)
    return printer.PositionsAreOnSameLine(range1:End(), range2:End(), sourceFile)
end

function printer.rangeStartIsOnSameLineAsRangeEnd(range1, range2, sourceFile)
    return printer.PositionsAreOnSameLine(printer.getStartPositionOfRange(range1, sourceFile, false --[[includeComments]]), range2:End(), sourceFile)
end

function printer.rangeEndIsOnSameLineAsRangeStart(range1, range2, sourceFile)
    return printer.PositionsAreOnSameLine(range1:End(), printer.getStartPositionOfRange(range2, sourceFile, false --[[includeComments]]), sourceFile)
end

function printer.getStartPositionOfRange(r, sourceFile, includeComments)
    if ast.PositionIsSynthesized(r:Pos()) then
        return -1
    end
    return scanner.SkipTriviaEx(sourceFile:Text(), r:Pos(), { stopAtComments = includeComments, stopAfterLineBreak = false, inJSDoc = false })
end

function printer.PositionsAreOnSameLine(pos1, pos2, sourceFile)
    return printer.GetLinesBetweenPositions(sourceFile, pos1, pos2) == 0
end

function printer.GetLinesBetweenPositions(sourceFile, pos1, pos2)
    if pos1 == pos2 then
        return 0
    end
    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    local lower = core.IfElse(pos1 < pos2, pos1, pos2)
    local isNegative = lower == pos2
    local upper = core.IfElse(isNegative, pos1, pos2)
    local lowerLine = scanner.ComputeLineOfPosition(lineStarts, lower)
    if lowerLine < 0 then
        -- Go: lineStarts[lowerLine:] with a negative index panics.
        error("slice bounds out of range", 0)
    end
    -- Go searches lineStarts[lowerLine:]; since lineStarts[lowerLine] <= lower <= upper, searching the
    -- whole array and subtracting lowerLine yields the same index without copying the slice.
    local upperLine = lowerLine + (scanner.ComputeLineOfPosition(lineStarts, upper) - lowerLine)
    if isNegative then
        return lowerLine - upperLine
    else
        return upperLine - lowerLine
    end
end

function printer.getLinesBetweenRangeEndAndRangeStart(range1, range2, sourceFile, includeSecondRangeComments)
    local range2Start = printer.getStartPositionOfRange(range2, sourceFile, includeSecondRangeComments)
    return printer.GetLinesBetweenPositions(sourceFile, range1:End(), range2Start)
end

function printer.getLinesBetweenPositionAndPrecedingNonWhitespaceCharacter(pos, stopPos, sourceFile, includeComments)
    local startPos = scanner.SkipTriviaEx(sourceFile:Text(), pos, { stopAtComments = includeComments, stopAfterLineBreak = false, inJSDoc = false })
    local prevPos = printer.getPreviousNonWhitespacePosition(startPos, stopPos, sourceFile)
    return printer.GetLinesBetweenPositions(sourceFile, core.IfElse(prevPos >= 0, prevPos, stopPos), startPos)
end

function printer.getLinesBetweenPositionAndNextNonWhitespaceCharacter(pos, stopPos, sourceFile, includeComments)
    local nextPos = scanner.SkipTriviaEx(sourceFile:Text(), pos, { stopAtComments = includeComments, stopAfterLineBreak = false, inJSDoc = false })
    return printer.GetLinesBetweenPositions(sourceFile, pos, core.IfElse(stopPos < nextPos, stopPos, nextPos))
end

function printer.getPreviousNonWhitespacePosition(pos, stopPos, sourceFile)
    local text = sourceFile:Text()
    while pos >= stopPos do
        if not stringutil.IsWhiteSpaceLike(sbyte(text, pos + 1)) then
            return pos
        end
        pos = pos - 1
    end
    return -1
end

function printer.siblingNodePositionsAreComparable(emitContext, previousNode, nextNode)
    if nextNode:Pos() < previousNode:End() then
        return false
    end

    previousNode = emitContext:MostOriginal(previousNode)
    nextNode = emitContext:MostOriginal(nextNode)
    local parent = previousNode.parent
    if parent == nil or parent ~= nextNode.parent then
        return false
    end

    local parentNodeArray = printer.getContainingNodeArray(previousNode)
    if parentNodeArray ~= nil then
        local prevNodeIndex = -1
        local nextNodeIndex = -1
        for i, n in ipairs((parentNodeArray.nodes or {})) do
            if prevNodeIndex < 0 and n == previousNode then
                prevNodeIndex = i - 1
            end
            if nextNodeIndex < 0 and n == nextNode then
                nextNodeIndex = i - 1
            end
        end
        return prevNodeIndex >= 0 and nextNodeIndex == prevNodeIndex + 1
    end

    return false
end

function printer.getContainingNodeArray(node)
    local parent = node.parent
    if parent == nil then
        return nil
    end

    local kind = node.kind
    if kind == Kind.TypeParameter then
        if ast.IsFunctionLike(parent) or ast.IsClassLike(parent) or ast.IsInterfaceDeclaration(parent) or ast.IsTypeOrJSTypeAliasDeclaration(parent) then
            return parent:TypeParameterList()
        elseif ast.IsInferTypeNode(parent) then
            -- break
        else
            error("Unexpected TypeParameter parent: " .. tostring(parent.kind), 0)
        end
    elseif kind == Kind.Parameter then
        return node.parent:FunctionLikeData().parameters
    elseif kind == Kind.TemplateLiteralTypeSpan then
        return node.parent:AsTemplateLiteralTypeNode().templateSpans
    elseif kind == Kind.TemplateSpan then
        return node.parent:AsTemplateExpression().templateSpans
    elseif kind == Kind.Decorator then
        if printer.canHaveDecorators(node.parent) then
            local modifiers = node.parent:Modifiers()
            if modifiers ~= nil then
                return modifiers
            end
        end
        return nil
    elseif kind == Kind.HeritageClause then
        if ast.IsClassLike(node.parent) then
            return node.parent:ClassLikeData().heritageClauses
        else
            return node.parent:AsInterfaceDeclaration().heritageClauses
        end
    end

    -- TODO(rbuckton)
    -- if ast.IsJSDocTag(node) {
    --     if ast.IsJSDocTypeLiteral(node.parent) {
    -- 		return nil
    -- 	 }
    -- 	 return node.parent.tags
    -- }

    local pkind = parent.kind
    if pkind == Kind.TypeLiteral or pkind == Kind.InterfaceDeclaration then
        if ast.IsTypeElement(node) then
            return parent:MemberList()
        end
    elseif pkind == Kind.UnionType then
        return parent:AsUnionTypeNode().types
    elseif pkind == Kind.IntersectionType then
        return parent:AsIntersectionTypeNode().types
    elseif pkind == Kind.ArrayLiteralExpression or pkind == Kind.TupleType or pkind == Kind.NamedImports or pkind == Kind.NamedExports then
        return parent:ElementList()
    elseif pkind == Kind.ObjectLiteralExpression or pkind == Kind.JsxAttributes then
        return parent:PropertyList()
    elseif pkind == Kind.CallExpression then
        local p = parent:AsCallExpression()
        if ast.IsTypeNode(node) then
            return p.typeArguments
        elseif node ~= p.expression then
            return p.arguments
        end
    elseif pkind == Kind.NewExpression then
        local p = parent:AsNewExpression()
        if ast.IsTypeNode(node) then
            return p.typeArguments
        elseif node ~= p.expression then
            return p.arguments
        end
    elseif pkind == Kind.JsxElement or pkind == Kind.JsxFragment then
        if ast.IsJsxChild(node) then
            return parent:Children()
        end
    elseif pkind == Kind.JsxOpeningElement or pkind == Kind.JsxSelfClosingElement then
        if ast.IsTypeNode(node) then
            return parent:TypeArgumentList()
        end
    elseif pkind == Kind.Block or pkind == Kind.ModuleBlock or pkind == Kind.CaseClause or pkind == Kind.DefaultClause then
        return parent:StatementList()
    elseif pkind == Kind.CaseBlock then
        return parent:AsCaseBlock().clauses
    elseif pkind == Kind.ClassDeclaration or pkind == Kind.ClassExpression then
        if ast.IsClassElement(node) then
            return parent:MemberList()
        end
    elseif pkind == Kind.EnumDeclaration then
        if ast.IsEnumMember(node) then
            return parent:MemberList()
        end
    elseif pkind == Kind.SourceFile then
        if ast.IsStatement(node) then
            return parent:StatementList()
        end
    end

    if ast.IsModifier(node) then
        local modifiers = parent:Modifiers()
        if modifiers ~= nil then
            return modifiers
        end
    end

    return nil
end

function printer.canHaveDecorators(node)
    local kind = node.kind
    if kind == Kind.Parameter or
        kind == Kind.PropertyDeclaration or
        kind == Kind.MethodDeclaration or
        kind == Kind.GetAccessor or
        kind == Kind.SetAccessor or
        kind == Kind.ClassExpression or
        kind == Kind.ClassDeclaration then
        return true
    end
    return false
end

function printer.originalNodesHaveSameParent(emitContext, nodeA, nodeB)
    nodeA = emitContext:MostOriginal(nodeA)
    if nodeA.parent ~= nil then
        -- For performance, do not call `MostOriginal` for `nodeB` if `nodeA` doesn't even
        -- have a parent node.
        nodeB = emitContext:MostOriginal(nodeB)
        return nodeA.parent == nodeB.parent
    end
    return false
end

-- node is a Node, NodeList, ModifierList or TextRange (anything with an End() method), or nil.
-- In Go a nil pointer of any of those types yields (0, false); in Lua those are all plain nil.
function printer.tryGetEnd(node)
    if node ~= nil then
        return node:End(), true
    end
    return 0, false
end

-- Variadic; nil entries are allowed (Go typed-nil pointers).
function printer.greatestEnd(end_, ...)
    local nodes = table.pack(...)
    for i = nodes.n, 1, -1 do
        local node = nodes[i]
        local nodeEnd, ok = printer.tryGetEnd(node)
        if ok and end_ < nodeEnd then
            end_ = nodeEnd
        end
    end
    return end_
end

function printer.skipSynthesizedParentheses(node)
    while node.kind == Kind.ParenthesizedExpression and ast.NodeIsSynthesized(node) do
        node = node:Expression()
    end
    return node
end

function printer.isNewExpressionWithoutArguments(node)
    return node.kind == Kind.NewExpression and node:ArgumentList() == nil
end

function printer.isBinaryOperation(node, token)
    node = ast.SkipPartiallyEmittedExpressions(node)
    return node.kind == Kind.BinaryExpression and
        node:AsBinaryExpression().operatorToken.kind == token
end

function printer.mixingBinaryOperatorsRequiresParentheses(a, b)
    if a == Kind.QuestionQuestionToken then
        return b == Kind.AmpersandAmpersandToken or b == Kind.BarBarToken
    end
    if b == Kind.QuestionQuestionToken then
        return a == Kind.AmpersandAmpersandToken or a == Kind.BarBarToken
    end
    return false
end

function printer.isImmediatelyInvokedFunctionExpressionOrArrowFunction(node)
    node = ast.SkipPartiallyEmittedExpressions(node)
    if not ast.IsCallExpression(node) then
        return false
    end
    node = ast.SkipPartiallyEmittedExpressions(node:Expression())
    return ast.IsFunctionExpression(node) or ast.IsArrowFunction(node)
end

function printer.hasLeadingHash(text)
    return #text > 0 and sbyte(text, 1) == 0x23 -- '#'
end

function printer.removeLeadingHash(text)
    if printer.hasLeadingHash(text) then
        return ssub(text, 2)
    else
        return text
    end
end

function printer.ensureLeadingHash(text)
    if printer.hasLeadingHash(text) then
        return text
    else
        return "#" .. text
    end
end

function printer.FormatGeneratedName(privateName, prefix, base, suffix)
    local name = printer.removeLeadingHash(prefix) .. printer.removeLeadingHash(base) .. printer.removeLeadingHash(suffix)
    if privateName then
        return printer.ensureLeadingHash(name)
    end
    return name
end

function printer.isASCIIWordCharacter(ch)
    return stringutil.IsASCIILetter(ch) or stringutil.IsDigit(ch) or ch == 0x5F -- '_'
end

function printer.makeIdentifierFromModuleName(moduleName)
    moduleName = tspath.GetBaseFileName(moduleName)
    local builder = printer.newStringsBuilder()
    local start = 0
    local pos = 0
    local n = #moduleName
    while pos < n do
        local ch = sbyte(moduleName, pos + 1)
        if pos == 0 and stringutil.IsDigit(ch) then
            builder:WriteByte(0x5F) -- '_'
        elseif not printer.isASCIIWordCharacter(ch) then
            if start < pos then
                builder:WriteString(ssub(moduleName, start + 1, pos))
            end
            builder:WriteByte(0x5F) -- '_'
            start = pos + 1
        end
        pos = pos + 1
    end
    if start < pos then
        builder:WriteString(ssub(moduleName, start + 1, pos))
    end
    return builder:String()
end

function printer.findSpanEndWithEmitContext(c, array, test, start)
    local i = start
    local n = core.Len(array)
    while i < n and test(c, array[i + 1]) do
        i = i + 1
    end
    return i
end

function printer.findSpanEnd(array, test, start)
    local i = start
    local n = core.Len(array)
    while i < n and test(array[i + 1]) do
        i = i + 1
    end
    return i
end

-- Go: skipWhiteSpaceSingleLine(text string, pos *int); returns the updated pos.
function printer.skipWhiteSpaceSingleLine(text, pos)
    while pos < #text do
        local ch, size = core.DecodeRune(text, pos)
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end
        pos = pos + size
    end
    return pos
end

-- Go: matchWhiteSpaceSingleLine(text string, pos *int) bool; returns the result and the updated pos.
function printer.matchWhiteSpaceSingleLine(text, pos)
    local startPos = pos
    pos = printer.skipWhiteSpaceSingleLine(text, pos)
    return pos ~= startPos, pos
end

-- Go: matchRune(text string, pos *int, expected rune) bool; returns the result and the updated pos.
function printer.matchRune(text, pos, expected)
    local ch, size = core.DecodeRune(text, pos)
    if ch == expected then
        return true, pos + size
    end
    return false, pos
end

-- Go: matchString(text string, pos *int, expected string) bool; returns the result and the updated pos.
function printer.matchString(text, pos, expected)
    local textPos = pos
    local expectedPos = 0
    while expectedPos < #expected do
        if textPos >= #text then
            return false, pos
        end

        local expectedRune, expectedSize = core.DecodeRune(expected, expectedPos)
        local ok
        ok, textPos = printer.matchRune(text, textPos, expectedRune)
        if not ok then
            return false, pos
        end

        expectedPos = expectedPos + expectedSize
    end

    return true, textPos
end

-- Go: matchQuotedString(text string, pos *int) bool; returns the result and the updated pos.
function printer.matchQuotedString(text, pos)
    local textPos = pos
    local quoteChar
    local ok
    ok, textPos = printer.matchRune(text, textPos, 0x27) -- '\''
    if ok then
        quoteChar = 0x27
    else
        ok, textPos = printer.matchRune(text, textPos, 0x22) -- '"'
        if ok then
            quoteChar = 0x22
        else
            return false, pos
        end
    end
    while textPos < #text do
        local ch, size = core.DecodeRune(text, textPos)
        textPos = textPos + size
        if ch == quoteChar then
            return true, textPos
        end
    end
    return false, pos
end

-- /// <reference path="..." />
-- /// <reference types="..." />
-- /// <reference lib="..." />
-- /// <reference no-default-lib="..." />
-- /// <amd-dependency path="..." />
-- /// <amd-module />
function printer.IsRecognizedTripleSlashComment(text, commentRange)
    local crPos = commentRange.pos
    local crEnd = commentRange.end_
    if commentRange.kind == Kind.SingleLineCommentTrivia and
        crEnd - crPos > 2 and
        sbyte(text, crPos + 2) == 0x2F and
        sbyte(text, crPos + 3) == 0x2F then
        text = ssub(text, crPos + 4, crEnd)
        local pos = 0
        local ok
        pos = printer.skipWhiteSpaceSingleLine(text, pos)
        ok, pos = printer.matchRune(text, pos, 0x3C) -- '<'
        if not ok then
            return false
        end
        local matched
        matched, pos = printer.matchString(text, pos, "reference")
        if matched then
            ok, pos = printer.matchWhiteSpaceSingleLine(text, pos)
            if not ok then
                return false
            end
            local any
            any, pos = printer.matchString(text, pos, "path")
            if not any then
                any, pos = printer.matchString(text, pos, "types")
            end
            if not any then
                any, pos = printer.matchString(text, pos, "lib")
            end
            if not any then
                any, pos = printer.matchString(text, pos, "no-default-lib")
            end
            if not any then
                return false
            end
            pos = printer.skipWhiteSpaceSingleLine(text, pos)
            ok, pos = printer.matchRune(text, pos, 0x3D) -- '='
            if not ok then
                return false
            end
            pos = printer.skipWhiteSpaceSingleLine(text, pos)
            ok, pos = printer.matchQuotedString(text, pos)
            if not ok then
                return false
            end
        else
            matched, pos = printer.matchString(text, pos, "amd-dependency")
            if matched then
                ok, pos = printer.matchWhiteSpaceSingleLine(text, pos)
                if not ok then
                    return false
                end
                ok, pos = printer.matchString(text, pos, "path")
                if not ok then
                    return false
                end
                pos = printer.skipWhiteSpaceSingleLine(text, pos)
                ok, pos = printer.matchRune(text, pos, 0x3D) -- '='
                if not ok then
                    return false
                end
                pos = printer.skipWhiteSpaceSingleLine(text, pos)
                ok, pos = printer.matchQuotedString(text, pos)
                if not ok then
                    return false
                end
            else
                matched, pos = printer.matchString(text, pos, "amd-module")
                if matched then
                    pos = printer.skipWhiteSpaceSingleLine(text, pos)
                else
                    return false
                end
            end
        end
        local index = string.find(ssub(text, pos + 1), "/>", 1, true)
        return index ~= nil
    end

    return false
end

function printer.isJSDocLikeText(text, comment)
    return comment.kind == Kind.MultiLineCommentTrivia and
        comment.end_ - comment.pos >= 5 and
        sbyte(text, comment.pos + 3) == 0x2A and -- '*'
        sbyte(text, comment.pos + 4) ~= 0x2F -- '/'
end

function printer.IsPinnedComment(text, comment)
    return comment.kind == Kind.MultiLineCommentTrivia and
        comment.end_ - comment.pos > 5 and
        sbyte(text, comment.pos + 3) == 0x21 -- '!'
end

function printer.calculateIndent(text, pos, end_)
    local currentLineIndent = 0
    local indentSize = printer.GetDefaultIndentSize()
    while pos < end_ do
        local ch, size = core.DecodeRune(text, pos)
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end
        if ch == 0x09 then -- '\t'
            -- Tabs = TabSize = indent size and go to next tabStop
            currentLineIndent = currentLineIndent + indentSize - (currentLineIndent % indentSize)
        else
            -- Single space
            currentLineIndent = currentLineIndent + 1
        end
        pos = pos + size
    end

    return currentLineIndent
end

-- lineCharacterCache provides cached line/character lookups for a source file,
-- optimized for monotonically increasing positions (e.g., during source map emit).
--
-- When positions increase within the same line, only the delta between the last
-- position and the new position needs to be scanned for UTF-16 code unit counts,
-- turning what would be O(n²) into O(n) for long lines.
--
-- Character offsets are measured in UTF-16 code units per the source map specification.
local lineCharacterCache = {}
lineCharacterCache.__index = lineCharacterCache
printer.lineCharacterCache = lineCharacterCache

function printer.newLineCharacterCache(source)
    return setmetatable({
        lineMap = source:ECMALineMap(),
        text = source:Text(),
        cachedLine = 0,
        cachedPos = 0,
        cachedChar = 0,
        hasCached = false,
    }, lineCharacterCache)
end

-- getLineAndCharacter returns the 0-based line number and UTF-16 code unit
-- offset from the start of that line for the given byte position.
function lineCharacterCache:getLineAndCharacter(pos)
    local line = scanner.ComputeLineOfPosition(self.lineMap, pos)
    local lineStart = self.lineMap[line + 1]
    -- When pos is beyond the source text (e.g., for error-recovery tokens like
    -- missing closing braces), we can't slice past the text end. Compute the
    -- UTF-16 length up to EOF and add the remaining byte offset arithmetically,
    -- matching TypeScript's computeLineAndCharacterOfPosition which uses
    -- arithmetic (position - lineStarts[lineNumber]) and handles this implicitly.
    local endPos = math.min(pos, #self.text)
    local character
    if self.hasCached and line == self.cachedLine and endPos >= self.cachedPos then
        -- Incremental: only count UTF-16 code units from the last cached position.
        character = self.cachedChar + core.UTF16Len(ssub(self.text, self.cachedPos + 1, endPos))
    else
        -- Full computation from line start.
        character = core.UTF16Len(ssub(self.text, lineStart + 1, endPos))
    end
    local cachedChar = character
    character = character + (pos - endPos)
    self.cachedLine = line
    self.cachedPos = endPos
    self.cachedChar = cachedChar
    self.hasCached = true
    return line, character
end
