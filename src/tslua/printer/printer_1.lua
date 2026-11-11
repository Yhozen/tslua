-- Package printer exports a Printer for pretty-printing TS ASTs and writer interfaces and implementations for using them
-- (Go printer.go, part 1: PrinterOptions .. emitJSDocVariadicType)
local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local EF = printer.EmitFlags
local LF = printer.ListFormat
local WriteKind = printer.WriteKind
local OperatorPrecedence = ast.OperatorPrecedence
local TypePrecedence = ast.TypePrecedence

local function kindString(k)
    return tostring(ast.Kind_names[k] or k)
end

-- Go strings.TrimSpace (Unicode White_Space)
local function isUnicodeSpace(r)
    return r == 0x20 or (r >= 0x09 and r <= 0x0D) or r == 0x85 or r == 0xA0 or r == 0x1680 or
        (r >= 0x2000 and r <= 0x200A) or r == 0x2028 or r == 0x2029 or r == 0x202F or r == 0x205F or r == 0x3000
end

local function trimSpace(s)
    local n = #s
    local start = 0
    while start < n do
        local r, size = core.DecodeRune(s, start)
        if not isUnicodeSpace(r) then
            break
        end
        start = start + size
    end
    local stop = n
    while stop > start do
        -- find the start of the last rune
        local i = stop - 1
        while i > start and (string.byte(s, i + 1) & 0xC0) == 0x80 do
            i = i - 1
        end
        local r, size = core.DecodeRune(s, i)
        if i + size ~= stop or not isUnicodeSpace(r) then
            break
        end
        stop = i
    end
    return string.sub(s, start + 1, stop)
end

-- PrinterOptions fields (Go zero values):
--   removeComments, newLine, omitTrailingSemicolon, noEmitHelpers, target, sourceMap, inlineSourceMap,
--   inlineSources, omitBraceSourceMapPositions, onlyPrintJSDocStyle, neverAsciiEscape,
--   preserveSourceNewlines, terminateUnterminatedLiterals
local function normalizePrinterOptions(options)
    options = options or {}
    return {
        removeComments = options.removeComments or false,
        newLine = options.newLine or 0,
        omitTrailingSemicolon = options.omitTrailingSemicolon or false,
        noEmitHelpers = options.noEmitHelpers or false,
        target = options.target or 0,
        sourceMap = options.sourceMap or false,
        inlineSourceMap = options.inlineSourceMap or false,
        inlineSources = options.inlineSources or false,
        omitBraceSourceMapPositions = options.omitBraceSourceMapPositions or false,
        onlyPrintJSDocStyle = options.onlyPrintJSDocStyle or false,
        neverAsciiEscape = options.neverAsciiEscape or false,
        preserveSourceNewlines = options.preserveSourceNewlines or false,
        terminateUnterminatedLiterals = options.terminateUnterminatedLiterals or false,
    }
end

-- PrintHandlers fields: hasGlobalName, onBeforeEmitNode, onAfterEmitNode, onBeforeEmitNodeList,
-- onAfterEmitNodeList, onBeforeEmitToken, onAfterEmitToken (all optional functions). They are
-- flattened onto the Printer (Go embeds PrintHandlers).

local Printer = {}
Printer.__index = Printer
printer.Printer = Printer

-- detachedCommentsInfo: { nodePos, detachedCommentEndPos }
-- commentState: { emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd }
-- sourceMapState: { emitFlags, sourceMapRange, hasTokenSourceMapRange }
-- printerState: { commentState, sourceMapState }

function printer.NewPrinter(options, handlers, emitContext)
    local p = setmetatable({}, Printer)
    handlers = handlers or {}
    p.hasGlobalName = handlers.hasGlobalName
    p.onBeforeEmitNode = handlers.onBeforeEmitNode
    p.onAfterEmitNode = handlers.onAfterEmitNode
    p.onBeforeEmitNodeList = handlers.onBeforeEmitNodeList
    p.onAfterEmitNodeList = handlers.onAfterEmitNodeList
    p.onBeforeEmitToken = handlers.onBeforeEmitToken
    p.onAfterEmitToken = handlers.onAfterEmitToken
    p.options = normalizePrinterOptions(options)
    p.emitContext = emitContext
    p.currentSourceFile = nil
    p.uniqueHelperNames = nil
    p.externalHelpersModuleName = nil
    p.nextListElementPos = 0
    p.writer = nil
    p.ownWriter = nil
    p.writeKind = WriteKind.None
    p.sourceMapsDisabled = false
    p.sourceMapGenerator = nil
    p.sourceMapSource = nil
    p.sourceMapSourceIndex = 0
    p.sourceMapSourceIsJson = false
    p.sourceMapLineCharCache = nil
    p.mostRecentSourceMapSource = nil
    p.mostRecentSourceMapSourceIndex = 0
    p.containerPos = 0
    p.containerEnd = 0
    p.declarationListContainerEnd = 0
    p.detachedCommentsInfo = printer.newStack()
    p.commentsDisabled = false
    p.inExtends = false
    p.nameGenerator = printer.NewNameGenerator()
    p.makeFileLevelOptimisticUniqueName = nil
    p.idToSymbol = nil
    -- wire up name generator
    if p.emitContext == nil then
        p.emitContext = printer.NewEmitContext()
    end
    p.nameGenerator.context = p.emitContext
    p.nameGenerator.getTextOfNode = function(node) return p:getTextOfNode(node, false) end
    p.nameGenerator.isFileLevelUniqueNameInCurrentFile = function(name, privateName)
        return p:isFileLevelUniqueNameInCurrentFile(name, privateName)
    end
    p.makeFileLevelOptimisticUniqueName = function(name)
        return p.nameGenerator:MakeFileLevelOptimisticUniqueName(name)
    end
    p.containerPos = -1
    p.containerEnd = -1
    p.declarationListContainerEnd = -1
    p.commentsDisabled = p.options.removeComments
    return p
end

function Printer:getLiteralTextOfNode(node, sourceFile, flags)
    if ast.IsStringLiteral(node) then
        local textSourceNode = self.emitContext.textSource[node]
        if textSourceNode ~= nil then
            local text
            local k = textSourceNode.kind
            if k == Kind.NumericLiteral then
                text = textSourceNode:Text()
            elseif k == Kind.Identifier or k == Kind.PrivateIdentifier or k == Kind.JsxNamespacedName then
                text = self:getTextOfNode(textSourceNode, false)
            else
                return self:getLiteralTextOfNode(textSourceNode, ast.GetSourceFileOfNode(textSourceNode), flags)
            end

            if flags & printer.getLiteralTextFlagsJsxAttributeEscape ~= 0 then
                return "\"" .. printer.escapeJsxAttributeString(text, printer.QuoteChar.DoubleQuote) .. "\""
            elseif flags & printer.getLiteralTextFlagsNeverAsciiEscape ~= 0 or self.emitContext:EmitFlags(node) & EF.EFNoAsciiEscaping ~= 0 then
                return "\"" .. printer.EscapeString(text, printer.QuoteChar.DoubleQuote) .. "\""
            else
                return "\"" .. printer.escapeNonAsciiString(text, printer.QuoteChar.DoubleQuote) .. "\""
            end
        end
    end
    -- !!! Printer option to control whether to terminate unterminated literals
    if self.emitContext:EmitFlags(node) & EF.EFNoAsciiEscaping ~= 0 then
        flags = flags | printer.getLiteralTextFlagsNeverAsciiEscape
    end
    if self.options.target >= core.ScriptTarget.ES2021 then
        flags = flags | printer.getLiteralTextFlagsAllowNumericSeparator
    end
    local sf = sourceFile
    if sf == nil then
        sf = self.currentSourceFile
    end
    return printer.getLiteralText(node, sf, flags)
end

-- `node` must be one of Identifier | PrivateIdentifier | LiteralExpression | JsxNamespacedName
function Printer:getTextOfNode(node, includeTrivia)
    if ast.IsMemberName(node) and self.emitContext.autoGenerate[node] ~= nil then
        return self.nameGenerator:GenerateName(node)
    end

    if ast.IsStringLiteral(node) then
        local textSourceNode = self.emitContext.textSource[node]
        if textSourceNode ~= nil then
            return self:getTextOfNode(textSourceNode, includeTrivia)
        end
    end

    local canUseSourceFile = self.currentSourceFile ~= nil and node.parent ~= nil and not ast.NodeIsSynthesized(node)

    local k = node.kind
    if k == Kind.Identifier or k == Kind.PrivateIdentifier or k == Kind.JsxNamespacedName then
        if not canUseSourceFile or ast.GetSourceFileOfNode(node) ~= self.emitContext:MostOriginal(self.currentSourceFile) then
            return node:Text()
        end
    elseif k == Kind.StringLiteral or
        k == Kind.NumericLiteral or
        k == Kind.BigIntLiteral or
        k == Kind.NoSubstitutionTemplateLiteral or
        k == Kind.TemplateHead or
        k == Kind.TemplateMiddle or
        k == Kind.TemplateTail then
        return self:getLiteralTextOfNode(node, nil --[[sourceFile]], printer.getLiteralTextFlagsNone)
    else
        error("unexpected node: " .. kindString(node.kind), 0)
    end
    return scanner.GetSourceTextOfNodeFromSourceFile(self.currentSourceFile, node, includeTrivia)
end

--
-- Low-level writing
--

function Printer:writeAs(text, writeKind)
    if writeKind == WriteKind.None then
        self.writer:Write(text)
    elseif writeKind == WriteKind.Parameter then
        self:writeParameter(text)
    elseif writeKind == WriteKind.Keyword then
        self:writeKeyword(text)
    elseif writeKind == WriteKind.Operator then
        self:writeOperator(text)
    elseif writeKind == WriteKind.Property then
        self:writeProperty(text)
    elseif writeKind == WriteKind.Punctuation then
        self:writePunctuation(text)
    elseif writeKind == WriteKind.StringLiteral then
        self.writer:WriteStringLiteral(text)
    elseif writeKind == WriteKind.Comment then
        self:writeComment(text)
    elseif writeKind == WriteKind.Literal then
        self:writeLiteral(text)
    else
        error("unexpected printer.WriteKind: " .. tostring(writeKind), 0)
    end
end

function Printer:write(text)
    self:writeAs(text, self.writeKind)
end

function Printer:setWriteKind(kind)
    local previous = self.writeKind
    self.writeKind = kind
    return previous
end

function Printer:writeSymbol(text, optSymbol)
    if optSymbol == nil then
        self:write(text)
    else
        self.writer:WriteSymbol(text, optSymbol)
    end
end

function Printer:writeLiteral(text)
    self.writer:WriteLiteral(text)
end

function Printer:writePunctuation(text)
    self.writer:WritePunctuation(text)
end

function Printer:writeOperator(text)
    self.writer:WriteOperator(text)
end

function Printer:writeKeyword(text)
    self.writer:WriteKeyword(text)
end

function Printer:writeProperty(text)
    self.writer:WriteProperty(text)
end

function Printer:writeParameter(text)
    self.writer:WriteParameter(text)
end

function Printer:writeComment(text)
    self.writer:WriteComment(text)
end

function Printer:writeSpace()
    self.writer:WriteSpace(" ")
end

function Printer:writeLine()
    self.writer:WriteLine()
end

function Printer:writeLineRepeat(count)
    for _ = 1, count do
        self:writeLine()
    end
end

function Printer:writeLines(text)
    local lines = stringutil.SplitLines(text)
    local indentation = stringutil.GuessIndentation(lines)
    for _, line in ipairs(lines) do
        if indentation > 0 then
            line = string.sub(line, indentation + 1)
        end
        if #line > 0 then
            self:writeLine()
            self:write(line)
        end
    end
end

function Printer:writeTrailingSemicolon()
    self.writer:WriteTrailingSemicolon(";")
end

function Printer:increaseIndent()
    self.writer:IncreaseIndent()
end

function Printer:decreaseIndent()
    self.writer:DecreaseIndent()
end

function Printer:increaseIndentIf(indentRequested)
    if indentRequested then
        self:increaseIndent()
    end
end

function Printer:decreaseIndentIf(indentRequested)
    if indentRequested then
        self:decreaseIndent()
    end
end

function Printer:writeLineOrSpace(parentNode, prevChildNode, nextChildNode)
    if self:shouldEmitOnSingleLine(parentNode) then
        self:writeSpace()
    elseif self.options.preserveSourceNewlines then
        local lines = self:getLinesBetweenNodes(parentNode, prevChildNode, nextChildNode)
        if lines > 0 then
            self:writeLineRepeat(lines)
        else
            self:writeSpace()
        end
    else
        self:writeLine()
    end
end

function Printer:writeLinesAndIndent(lineCount, writeSpaceIfNotIndenting)
    if lineCount > 0 then
        self:increaseIndent()
        self:writeLineRepeat(lineCount)
    elseif writeSpaceIfNotIndenting then
        self:writeSpace()
    end
end

function Printer:writeLineSeparatorsAndIndentBefore(node, parent)
    if self.options.preserveSourceNewlines then
        local leadingNewlines = self:getLeadingLineTerminatorCount(parent, node, LF.LFNone)
        if leadingNewlines > 0 then
            self:writeLinesAndIndent(leadingNewlines, false --[[writeSpaceIfNotIndenting]])
            return true
        end
    end
    return false
end

function Printer:writeLineSeparatorsAfter(node, parent)
    if self.options.preserveSourceNewlines then
        local trailingNewlines = self:getClosingLineTerminatorCount(parent, node, LF.LFNone, core.NewTextRange(-1, -1) --[[childrenTextRange]])
        if trailingNewlines > 0 then
            self:writeLineRepeat(trailingNewlines)
        end
    end
end

function Printer:getLinesBetweenNodes(parent, node1, node2)
    if self:shouldElideIndentation(parent) then
        return 0
    end

    parent = printer.skipSynthesizedParentheses(parent)
    node1 = printer.skipSynthesizedParentheses(node1)
    node2 = printer.skipSynthesizedParentheses(node2)

    -- Always use a newline for synthesized code if the synthesizer desires it.
    if self:shouldEmitOnNewLine(node2, LF.LFNone) then
        return 1
    end

    if self.currentSourceFile ~= nil and not ast.NodeIsSynthesized(parent) and not ast.NodeIsSynthesized(node1) and not ast.NodeIsSynthesized(node2) then
        if self.options.preserveSourceNewlines then
            return self:getEffectiveLines(
                function(includeComments)
                    return printer.getLinesBetweenRangeEndAndRangeStart(
                        node1.loc,
                        node2.loc,
                        self.currentSourceFile,
                        includeComments
                    )
                end
            )
        end
        return printer.rangeEndIsOnSameLineAsRangeStart(node1.loc, node2.loc, self.currentSourceFile) and 0 or 1
    end

    return 0
end

function Printer:getEffectiveLines(getLineDifference)
    -- If 'preserveSourceNewlines' is disabled, we should never call this function
    -- because it could be more expensive than alternative approximations.
    if not self.options.preserveSourceNewlines then
        error("Should not be called when preserveSourceNewlines is false", 0)
    end
    -- We start by measuring the line difference from a position to its adjacent comments,
    -- so that this is counted as a one-line difference, not two:
    --
    --   node1;
    --   // NODE2 COMMENT
    --   node2;
    local lines = getLineDifference(true --[[includeComments]])
    if lines == 0 then
        -- However, if the line difference considering comments was 0, we might have this:
        --
        --   node1; // NODE2 COMMENT
        --   node2;
        --
        -- in which case we should be ignoring node2's comment, so this too is counted as
        -- a one-line difference, not zero.
        return getLineDifference(false --[[includeComments]])
    end
    return lines
end

function Printer:getLeadingLineTerminatorCount(parentNode, firstChild, format)
    if format & LF.LFPreserveLines ~= 0 or self.options.preserveSourceNewlines then
        if format & LF.LFPreferNewLine ~= 0 then
            return 1
        end

        if firstChild == nil then
            return (parentNode == nil or self.currentSourceFile ~= nil and printer.RangeIsOnSingleLine(parentNode.loc, self.currentSourceFile)) and 0 or 1
        end
        if self.nextListElementPos > 0 and firstChild:Pos() == self.nextListElementPos then
            -- If this child starts at the beginning of a list item in a parent list, its leading
            -- line terminators have already been written as the separating line terminators of the
            -- parent list. Example:
            --
            -- class Foo {
            --   constructor() {}
            --   public foo() {}
            -- }
            --
            -- The outer list is the list of class members, with one line terminator between the
            -- constructor and the method. The constructor is written, the separating line terminator
            -- is written, and then we start emitting the method. Its modifiers ([public]) constitute an inner
            -- list, so we look for its leading line terminators. If we didn't know that we had already
            -- written a newline as part of the parent list, it would appear that we need to write a
            -- leading newline to start the modifiers.
            return 0
        end
        if firstChild.kind == Kind.JsxText then
            -- JsxText will be written with its leading whitespace, so don't add more manually.
            return 0
        end
        if self.currentSourceFile ~= nil and parentNode ~= nil and
            not ast.PositionIsSynthesized(parentNode:Pos()) and
            not ast.NodeIsSynthesized(firstChild) and
            (firstChild.parent == nil --[[|| getOriginalNode(firstChild.Parent) == getOriginalNode(parentNode)]]) then
            if self.options.preserveSourceNewlines then
                return self:getEffectiveLines(
                    function(includeComments)
                        return printer.getLinesBetweenPositionAndPrecedingNonWhitespaceCharacter(
                            firstChild:Pos(),
                            parentNode:Pos(),
                            self.currentSourceFile,
                            includeComments
                        )
                    end
                )
            end
            return printer.RangeStartPositionsAreOnSameLine(parentNode.loc, firstChild.loc, self.currentSourceFile) and 0 or 1
        end
        if self:shouldEmitOnNewLine(firstChild, format) then
            return 1
        end
    end
    return format & LF.LFMultiLine ~= 0 and 1 or 0
end

function Printer:getSeparatingLineTerminatorCount(previousNode, nextNode, format)
    if format & LF.LFPreserveLines ~= 0 or self.options.preserveSourceNewlines then
        if previousNode == nil or nextNode == nil then
            return 0
        end
        if nextNode.kind == Kind.JsxText then
            -- JsxText will be written with its leading whitespace, so don't add more manually.
            return 0
        elseif self.currentSourceFile ~= nil and not ast.NodeIsSynthesized(previousNode) and not ast.NodeIsSynthesized(nextNode) then
            if self.options.preserveSourceNewlines and printer.siblingNodePositionsAreComparable(self.emitContext, previousNode, nextNode) then
                return self:getEffectiveLines(
                    function(includeComments)
                        return printer.getLinesBetweenRangeEndAndRangeStart(
                            previousNode.loc,
                            nextNode.loc,
                            self.currentSourceFile,
                            includeComments
                        )
                    end
                )
            elseif not self.options.preserveSourceNewlines and printer.originalNodesHaveSameParent(self.emitContext, previousNode, nextNode) then
                -- If `preserveSourceNewlines` is `false` we do not intend to preserve the effective lines between the
                -- previous and next node. Instead we naively check whether nodes are on separate lines within the
                -- same node parent. If so, we intend to preserve a single line terminator. This is less precise and
                -- expensive than checking with `preserveSourceNewlines` as above, but the goal is not to preserve the
                -- effective source lines between two sibling nodes.
                return printer.rangeEndIsOnSameLineAsRangeStart(previousNode.loc, nextNode.loc, self.currentSourceFile) and 0 or 1
            end
            -- If the two nodes are not comparable, add a line terminator based on the format that can indicate
            -- whether new lines are preferred or not.
            return format & LF.LFPreferNewLine ~= 0 and 1 or 0
        elseif self:shouldEmitOnNewLine(previousNode, format) or self:shouldEmitOnNewLine(nextNode, format) then
            return 1
        end
    elseif self:shouldEmitOnNewLine(nextNode, LF.LFNone) then
        return 1
    end
    return format & LF.LFMultiLine ~= 0 and 1 or 0
end

function Printer:getClosingLineTerminatorCount(parentNode, lastChild, format, childrenTextRange)
    if format & LF.LFPreserveLines ~= 0 or self.options.preserveSourceNewlines then
        if format & LF.LFPreferNewLine ~= 0 then
            return 1
        end
        if lastChild == nil then
            return (parentNode == nil or self.currentSourceFile ~= nil and printer.RangeIsOnSingleLine(parentNode.loc, self.currentSourceFile)) and 0 or 1
        end
        if self.currentSourceFile ~= nil and parentNode ~= nil and not ast.PositionIsSynthesized(parentNode:Pos()) and not ast.NodeIsSynthesized(lastChild) and (lastChild.parent == nil or lastChild.parent == parentNode) then
            if self.options.preserveSourceNewlines then
                local end_ = printer.greatestEnd(lastChild:End(), childrenTextRange)
                return self:getEffectiveLines(
                    function(includeComments)
                        return printer.getLinesBetweenPositionAndNextNonWhitespaceCharacter(
                            end_,
                            parentNode:End(),
                            self.currentSourceFile,
                            includeComments
                        )
                    end
                )
            end
            return printer.rangeEndPositionsAreOnSameLine(parentNode.loc, lastChild.loc, self.currentSourceFile) and 0 or 1
        end
        if self:shouldEmitOnNewLine(lastChild, format) then
            return 1
        end
    end
    if format & LF.LFMultiLine ~= 0 and format & LF.LFNoTrailingNewLine == 0 then
        return 1
    end
    return 0
end

function Printer:writeCommentRange(comment)
    if self.currentSourceFile == nil then
        return
    end

    local text = self.currentSourceFile:Text()
    local lineMap = self.currentSourceFile:ECMALineMap()
    self:writeCommentRangeWorker(text, lineMap, comment.kind, core.NewTextRange(comment.pos, comment.end_))
end

function Printer:writeCommentRangeWorker(text, lineMap, kind, loc)
    if kind == Kind.MultiLineCommentTrivia then
        local indentSize = printer.GetDefaultIndentSize()
        local firstLine = scanner.ComputeLineOfPosition(lineMap, loc.pos)
        local lineCount = #lineMap
        local firstCommentLineIndent = -1
        local pos = loc.pos
        local currentLine = firstLine
        while pos < loc.end_ do
            local nextLineStart
            if currentLine + 1 == lineCount then
                nextLineStart = #text + 1
            else
                nextLineStart = lineMap[currentLine + 1 + 1]
            end

            if pos ~= loc.pos then
                -- If we are not emitting first line, we need to write the spaces to adjust the alignment
                if firstCommentLineIndent == -1 then
                    firstCommentLineIndent = printer.calculateIndent(text, lineMap[firstLine + 1], loc.pos)
                end

                -- These are number of spaces writer is going to write at current indent
                local currentWriterIndentSpacing = self.writer:GetIndent() * indentSize

                -- Number of spaces we want to be writing
                -- eg: Assume writer indent
                -- module m {
                --         /* starts at character 9 this is line 1
                --    * starts at character pos 4 line                        --1  = 8 - 8 + 3
                --   More left indented comment */                            --2  = 8 - 8 + 2
                --     class c { }
                -- }
                -- module m {
                --     /* this is line 1 -- Assume current writer indent 8
                --      * line                                                --3 = 8 - 4 + 5
                --            More right indented comment */                  --4 = 8 - 4 + 11
                --     class c { }
                -- }
                local spacesToEmit = currentWriterIndentSpacing - firstCommentLineIndent + printer.calculateIndent(text, pos, nextLineStart)
                if spacesToEmit > 0 then
                    local numberOfSingleSpacesToEmit = spacesToEmit % indentSize
                    local indentSizeSpaceString = printer.getIndentString((spacesToEmit - numberOfSingleSpacesToEmit) // indentSize, indentSize)

                    -- Write indent size string ( in eg 1: = "", 2: "" , 3: string with 8 spaces 4: string with 12 spaces
                    self.writer:RawWrite(indentSizeSpaceString)

                    -- Emit the single spaces (in eg: 1: 3 spaces, 2: 2 spaces, 3: 1 space, 4: 3 spaces)
                    while numberOfSingleSpacesToEmit > 0 do
                        self.writer:RawWrite(" ")
                        numberOfSingleSpacesToEmit = numberOfSingleSpacesToEmit - 1
                    end
                else
                    -- No spaces to emit write empty string
                    self.writer:RawWrite("")
                end
            end

            -- Write the comment line text
            local end_ = math.min(loc.end_, nextLineStart)
            local scan = pos
            while scan < end_ do
                local ch, size = core.DecodeRune(text, scan)
                if size == 0 then
                    break
                end
                if scan + size > end_ then
                    -- the rune is truncated by the end of the slice (Go decodes text[scan:end])
                    ch, size = 0xFFFD, 1
                end
                if stringutil.IsLineBreak(ch) then
                    end_ = scan
                    break
                end
                scan = scan + size
            end
            local currentLineText = trimSpace(string.sub(text, pos + 1, end_))
            if #currentLineText > 0 then
                self:writeComment(currentLineText)
                if end_ ~= loc.end_ then
                    self:writeLine()
                end
            else
                -- Empty string - make sure we write empty line
                self.writer:WriteLineForce(true)
            end

            pos = nextLineStart
            currentLine = currentLine + 1
        end
    else
        -- Single line comment of style //....
        self:writeComment(string.sub(text, loc.pos + 1, loc.end_))
    end
end

--
-- Custom emit behavior stubs (i.e., from `EmitNode`, `EmitFlags`, etc.)
--

function Printer:shouldEmitComments(node)
    return not self.commentsDisabled and
        self.currentSourceFile ~= nil and
        not ast.IsSourceFile(node)
end

function Printer:shouldWriteComment(comment)
    return not self.options.onlyPrintJSDocStyle or
        self.currentSourceFile ~= nil and printer.isJSDocLikeText(self.currentSourceFile:Text(), comment) or
        self.currentSourceFile ~= nil and printer.IsPinnedComment(self.currentSourceFile:Text(), comment)
end

function Printer:shouldEmitIndented(node)
    return self.emitContext:EmitFlags(node) & EF.EFIndented ~= 0
end

function Printer:shouldElideIndentation(node)
    return self.emitContext:EmitFlags(node) & EF.EFNoIndentation ~= 0
end

function Printer:shouldEmitOnSingleLine(node)
    return self.emitContext:EmitFlags(node) & EF.EFSingleLine ~= 0
end

function Printer:shouldEmitOnMultipleLines(node)
    return self.emitContext:EmitFlags(node) & EF.EFMultiLine ~= 0
end

function Printer:shouldEmitBlockFunctionBodyOnSingleLine(body)
    -- We must emit a function body as a single-line body in the following case:
    -- * The body has NodeEmitFlags.SingleLine specified.

    -- We must emit a function body as a multi-line body in the following cases:
    -- * The body is explicitly marked as multi-line.
    -- * A non-synthesized body's start and end position are on different lines.
    -- * Any statement in the body starts on a new line.

    if self:shouldEmitOnSingleLine(body) then
        return true
    end

    if body.multiLine then
        return false
    end

    if not ast.NodeIsSynthesized(body) and self.currentSourceFile ~= nil and not printer.RangeIsOnSingleLine(body.loc, self.currentSourceFile) then
        return false
    end

    local statements = body.statements.nodes
    if self:getLeadingLineTerminatorCount(body, statements[1], LF.LFPreserveLines) > 0 or
        self:getClosingLineTerminatorCount(body, statements[#statements], LF.LFPreserveLines, body.statements.loc) > 0 then
        return false
    end

    local previousStatement = nil
    for _, statement in ipairs(statements) do
        if self:getSeparatingLineTerminatorCount(previousStatement, statement, LF.LFPreserveLines) > 0 then
            return false
        end

        previousStatement = statement
    end

    return true
end

function Printer:shouldEmitOnNewLine(node, format)
    if self.emitContext:EmitFlags(node) & EF.EFStartOnNewLine ~= 0 then
        return true
    end
    return format & LF.LFPreferNewLine ~= 0
end

function Printer:shouldEmitSourceMaps(node)
    return not self.sourceMapsDisabled and
        self.sourceMapSource ~= nil and
        not ast.IsSourceFile(node) and
        not ast.IsInJsonFile(node)
end

function Printer:shouldEmitTokenSourceMaps(token, pos, contextNode, flags)
    -- We don't emit source positions for most tokens as it tends to be quite noisy, however
    -- we need to emit source positions for open and close braces so that tools like istanbul
    -- can map branches for code coverage. However, we still omit brace source positions when
    -- the output is a declaration file.
    return flags & printer.tefNoSourceMaps == 0 and
        self:shouldEmitSourceMaps(contextNode) and
        not self.options.omitBraceSourceMapPositions and (token == Kind.OpenBraceToken or token == Kind.CloseBraceToken)
end

function Printer:shouldEmitLeadingComments(node)
    return self.emitContext:EmitFlags(node) & EF.EFNoLeadingComments == 0
end

function Printer:shouldEmitTrailingComments(node)
    return self.emitContext:EmitFlags(node) & EF.EFNoTrailingComments == 0
end

function Printer:shouldEmitNestedComments(node)
    return self.emitContext:EmitFlags(node) & EF.EFNoNestedComments == 0
end

function Printer:shouldEmitDetachedComments(node)
    if not ast.IsSourceFile(node) then
        return true
    end

    local file = node

    -- Emit detached comment if there are no prologue directives or if the first node is synthesized.
    -- The synthesized node will have no leading comment so some comments may be missed.
    local statements = file.statements.nodes
    return #statements == 0 or
        not ast.IsPrologueDirective(statements[1]) or
        ast.NodeIsSynthesized(statements[1])
end

function Printer:hasCommentsAtPosition(pos)
    if self.currentSourceFile == nil then
        return false
    end

    for _ in scanner.GetTrailingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pos + 1) do -- luacheck: ignore 512
        return true
    end
    for _ in scanner.GetLeadingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pos + 1) do -- luacheck: ignore 512
        return true
    end
    return false
end

function Printer:shouldEmitIndirectCall(node)
    return self.emitContext:EmitFlags(node) & EF.EFIndirectCall ~= 0
end

function Printer:shouldAllowTrailingComma(node, list)
    if self.currentSourceFile == nil or self.currentSourceFile.scriptKind == core.ScriptKind.JSON then
        return false
    end

    local k = node.kind
    if k == Kind.ObjectLiteralExpression then
        return true
    elseif k == Kind.ArrayLiteralExpression or
        k == Kind.ArrowFunction or
        k == Kind.Constructor or
        k == Kind.GetAccessor or
        k == Kind.SetAccessor or
        k == Kind.TypeAliasDeclaration or
        k == Kind.JSTypeAliasDeclaration or
        k == Kind.FunctionType or
        k == Kind.ConstructorType or
        k == Kind.CallSignature or
        k == Kind.ConstructSignature or
        k == Kind.TaggedTemplateExpression or
        k == Kind.ObjectBindingPattern or
        k == Kind.ArrayBindingPattern or
        k == Kind.NamedImports or
        k == Kind.NamedExports or
        k == Kind.ImportAttributes then
        return true
    elseif k == Kind.ClassExpression or
        k == Kind.ClassDeclaration or
        k == Kind.InterfaceDeclaration then
        return list == node:TypeParameterList()
    elseif k == Kind.FunctionDeclaration or
        k == Kind.FunctionExpression or
        k == Kind.MethodDeclaration then
        return true
    elseif k == Kind.CallExpression then
        return true
    elseif k == Kind.NewExpression then
        return true
    end

    return false
end

--
-- Tokens/Keywords
--

function Printer:writeTokenText(token, writeKind, pos)
    -- !!! emit leading and trailing comments
    -- !!! emit leading and trailing source maps
    local tokenString = scanner.TokenToString(token)
    self:writeAs(tokenString, writeKind)
    if ast.PositionIsSynthesized(pos) then
        return pos
    else
        return pos + #tokenString
    end
end

function Printer:emitToken(token, pos, writeKind, contextNode)
    return self:emitTokenEx(token, pos, writeKind, contextNode, printer.tefNone)
end

function Printer:emitTokenEx(token, pos, writeKind, contextNode, flags)
    local state
    state, pos = self:enterToken(token, pos, contextNode, flags)
    pos = self:writeTokenText(token, writeKind, pos)
    self:exitToken(token, pos, contextNode, state)
    return pos
end

function Printer:emitKeywordNode(node)
    self:emitKeywordNodeEx(node, printer.tefNone)
end

function Printer:emitKeywordNodeEx(node, flags)
    if node == nil then
        return
    end

    local state = self:enterTokenNode(node, flags)
    self:writeTokenText(node.kind, WriteKind.Keyword, node:Pos())
    self:exitTokenNode(node, state)
end

function Printer:emitPunctuationNode(node)
    self:emitPunctuationNodeEx(node, printer.tefNone)
end

function Printer:emitPunctuationNodeEx(node, flags)
    if node == nil then
        return
    end

    local state = self:enterTokenNode(node, flags)
    self:writeTokenText(node.kind, WriteKind.Punctuation, node:Pos())
    self:exitTokenNode(node, state)
end

function Printer:emitTokenNode(node)
    self:emitTokenNodeEx(node, printer.tefNone)
end

function Printer:emitTokenNodeEx(node, flags)
    if node == nil then
        return
    end

    if ast.IsKeywordKind(node.kind) then
        self:emitKeywordNodeEx(node, flags)
    elseif ast.IsPunctuationKind(node.kind) then
        self:emitPunctuationNodeEx(node, flags)
    else
        error("unexpected TokenNode: " .. kindString(node.kind), 0)
    end
end

--
-- Literals
--

-- Emits literals of the following kinds
--
--	SyntaxKindNumericLiteral
--	SyntaxKindBigIntLiteral
--	SyntaxKindStringLiteral
--	SyntaxKindNoSubstitutionTemplateLiteral
--	SyntaxKindRegularExpressionLiteral
--	SyntaxKindTemplateHead
--	SyntaxKindTemplateMiddle
--	SyntaxKindTemplateTail
function Printer:emitLiteral(node, flags)
    -- Add NeverAsciiEscape flag if the printer option is set
    if self.options.neverAsciiEscape then
        flags = flags | printer.getLiteralTextFlagsNeverAsciiEscape
    end
    if self.options.terminateUnterminatedLiterals then
        flags = flags | printer.getLiteralTextFlagsTerminateUnterminatedLiterals
    end

    local text = self:getLiteralTextOfNode(node, nil --[[sourceFile]], flags)

    -- !!! Printer option to control source map emit, which causes us to use a different write method on the
    -- emit text writer:

    ----if (
    ----	(printerOptions.sourceMap || printerOptions.inlineSourceMap)
    ----	&& (node.kind === SyntaxKindStringLiteral || isTemplateLiteralKind(node.kind))
    ----) {
    ----	writeLiteral(text);
    ----} else {

    -- Quick info expects all literals to be called with writeStringLiteral, as there's no specific type for
    -- numberLiterals
    self.writer:WriteStringLiteral(text)

    -- }
end

function Printer:emitNumericLiteral(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitBigIntLiteral(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone) -- TODO: Preserve numeric literal separators after Strada migration
    self:exitNode(node, state)
end

function Printer:emitStringLiteral(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitNoSubstitutionTemplateLiteral(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitRegularExpressionLiteral(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

--
-- Pseudo-literals
--

function Printer:emitTemplateHead(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitTemplateMiddle(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitTemplateTail(node)
    local state = self:enterNode(node)
    self:emitLiteral(node, printer.getLiteralTextFlagsNone)
    self:exitNode(node, state)
end

function Printer:emitTemplateMiddleTail(node)
    if node.kind == Kind.TemplateMiddle then
        self:emitTemplateMiddle(node)
    elseif node.kind == Kind.TemplateTail then
        self:emitTemplateTail(node)
    end
end

--
-- Snippet Elements
--

function Printer:emitSnippetNode(node, snippetElement)
    if snippetElement.kind == printer.SnippetKind.TabStop then
        self:emitTabStop(node, snippetElement)
    else
        error("Unhandled snippet element kind: " .. tostring(snippetElement.kind), 0)
    end
end

function Printer:emitTabStop(node, snippetElement)
    printer.debugAssert(node.kind == Kind.EmptyStatement, "Snippet tab stops can only be emitted on empty statements")
    self.writer:RawWrite(string.format("$%d", snippetElement.order))
end

--
-- Names
--

function Printer:emitIdentifierText(node)
    local f = ast.GetSourceFileOfNode(node)
    printer.debugAssert(f == nil or self.currentSourceFile == nil or f:FileName() == self.currentSourceFile:FileName())
    local text = self:getTextOfNode(node, false --[[includeTrivia]])

    if self.idToSymbol ~= nil then
        local symbol = self.idToSymbol[node]
        if symbol ~= nil then
            self:writeSymbol(text, symbol)
            return
        end
    end
    self:write(text)
end

function Printer:emitIdentifierName(node)
    local state = self:enterNode(node)
    self:emitIdentifierText(node)
    self:exitNode(node, state)
end

function Printer:emitIdentifierNameNode(node)
    if node == nil then
        return
    end
    self:emitIdentifierName(node)
end

function Printer:getUniqueHelperName(name)
    local helperName = self.uniqueHelperNames[name]
    if helperName == nil then
        local newHelperName = self.emitContext.factory:NewUniqueNameEx(name, {
            flags = printer.GeneratedIdentifierFlagsFileLevel | printer.GeneratedIdentifierFlagsOptimistic,
            prefix = "",
            suffix = "",
        })
        self:generateName(newHelperName)
        self.uniqueHelperNames[name] = newHelperName
        return newHelperName
    end
    return helperName:Clone(self.emitContext.factory)
end

function Printer:emitIdentifierReference(node)
    if (self.externalHelpersModuleName ~= nil or self.uniqueHelperNames ~= nil) and
        self.emitContext:EmitFlags(node) & EF.EFHelperName ~= 0 then
        if self.externalHelpersModuleName ~= nil then
            -- Substitute `__helper` with `tslib_1.__helper`
            local helper = self.emitContext.factory:NewPropertyAccessExpression(
                self.externalHelpersModuleName:Clone(self.emitContext.factory),
                nil, --[[questionDotToken]]
                node:Clone(self.emitContext.factory),
                ast.NodeFlags.None
            )
            self.emitContext:AssignCommentAndSourceMapRanges(helper, node)
            self:emitPropertyAccessExpression(helper)
            return
        end
        if self.uniqueHelperNames ~= nil then
            -- Substitute `__helper` with `__helper_1` if there is a conflict in an ES module.
            local helperName = self:getUniqueHelperName(node.text)
            self.emitContext:AssignCommentAndSourceMapRanges(helperName, node)
            node = helperName
        end
    end

    local state = self:enterNode(node)
    self:emitIdentifierText(node)
    self:exitNode(node, state)
end

function Printer:emitBindingIdentifier(node)
    if self.uniqueHelperNames ~= nil and
        self.emitContext:EmitFlags(node) & EF.EFHelperName ~= 0 then
        -- Substitute `__helper` with `__helper_1` if there is a conflict in an ES module.
        local helperName = self:getUniqueHelperName(node.text)
        self.emitContext:AssignCommentAndSourceMapRanges(helperName, node)
        node = helperName
    end

    local state = self:enterNode(node)
    self:emitIdentifierText(node)
    self:exitNode(node, state)
end

function Printer:emitLabelIdentifier(node)
    local state = self:enterNode(node)
    self:emitIdentifierText(node)
    self:exitNode(node, state)
end

function Printer:emitPrivateIdentifier(node)
    local state = self:enterNode(node)
    self:write(self:getTextOfNode(node, false --[[includeTrivia]]))
    self:exitNode(node, state)
end

function Printer:emitQualifiedName(node)
    local state = self:enterNode(node)
    self:emitEntityName(node.left)
    self:writePunctuation(".")
    self:emitMemberName(node.right)
    self:exitNode(node, state)
end

function Printer:emitComputedPropertyName(node)
    local state = self:enterNode(node)
    self:writePunctuation("[")
    self:emitExpression(node.expression, OperatorPrecedence.DisallowComma)
    self:writePunctuation("]")
    self:exitNode(node, state)
end

function Printer:emitEntityName(node)
    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierReference(node)
    elseif k == Kind.QualifiedName then
        self:emitQualifiedName(node)
    elseif k == Kind.PropertyAccessExpression then
        -- TypeQuery nodes may have PropertyAccessExpression as exprName (e.g. typeof foo.x).
        -- TS's emitter handles this via generic emit(); we dispatch to expression emitter here.
        self:emitExpression(node, OperatorPrecedence.DisallowComma)
    else
        error("unexpected EntityName: " .. kindString(k), 0)
    end
end

function Printer:emitBindingName(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Identifier then
        self:emitBindingIdentifier(node)
    elseif k == Kind.ObjectBindingPattern then
        self:emitObjectBindingPattern(node)
    elseif k == Kind.ArrayBindingPattern then
        self:emitArrayBindingPattern(node)
    else
        error("unexpected BindingName: " .. kindString(k), 0)
    end
end

function Printer:emitPropertyName(node)
    if node == nil then
        return
    end

    local savedWriteKind = self.writeKind
    self.writeKind = WriteKind.Property

    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif k == Kind.PrivateIdentifier then
        self:emitPrivateIdentifier(node)
    elseif k == Kind.StringLiteral then
        self:emitStringLiteral(node)
    elseif k == Kind.NoSubstitutionTemplateLiteral then
        self:emitNoSubstitutionTemplateLiteral(node)
    elseif k == Kind.NumericLiteral then
        self:emitNumericLiteral(node)
    elseif k == Kind.BigIntLiteral then
        self:emitBigIntLiteral(node)
    elseif k == Kind.ComputedPropertyName then
        self:emitComputedPropertyName(node)
    else
        error("unexpected PropertyName: " .. kindString(k), 0)
    end

    self.writeKind = savedWriteKind
end

function Printer:emitMemberName(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif k == Kind.PrivateIdentifier then
        self:emitPrivateIdentifier(node)
    else
        error("unexpected MemberName: " .. kindString(k), 0)
    end
end

function Printer:emitModuleName(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Identifier then
        self:emitBindingIdentifier(node)
    elseif k == Kind.StringLiteral then
        self:emitStringLiteral(node)
    else
        error("unexpected ModuleName: " .. kindString(k), 0)
    end
end

function Printer:emitModuleExportName(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif k == Kind.StringLiteral then
        self:emitStringLiteral(node)
    else
        error("unexpected ModuleExportName: " .. kindString(k), 0)
    end
end

function Printer:emitImportAttributeName(node)
    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif k == Kind.StringLiteral then
        self:emitStringLiteral(node)
    else
        error("unexpected ImportAttributeName: " .. kindString(k), 0)
    end
end

function Printer:emitNestedModuleName(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif k == Kind.StringLiteral then
        self:emitStringLiteral(node)
    else
        error("unexpected ModuleName: " .. kindString(k), 0)
    end
end

--
-- Signature elements
--

function Printer:emitModifierList(parentNode, modifiers, allowDecorators)
    if modifiers == nil or #modifiers.nodes == 0 then
        return parentNode:Pos()
    end

    if core.Every(modifiers.nodes, ast.IsModifier) then
        -- if all modifier-likes are `Modifier`, simply emit the list as modifiers.
        self:emitList(Printer.emitKeywordNode, parentNode, modifiers, LF.LFModifiers)
    elseif core.Every(modifiers.nodes, ast.IsDecorator) then
        if not allowDecorators then
            return parentNode:Pos()
        end

        -- if all modifier-likes are `Decorator`, simply emit the list as decorators.
        self:emitList(Printer.emitModifierLike, parentNode, modifiers, LF.LFDecorators)
    else
        if self.onBeforeEmitNodeList ~= nil then
            self.onBeforeEmitNodeList(modifiers)
        end

        -- partition modifiers into contiguous chunks of `Modifier` or `Decorator` so as to
        -- use consistent formatting for each chunk
        local ModeNone = 0
        local ModeModifiers = 1
        local ModeDecorators = 2

        local lastMode = ModeNone
        local mode = ModeNone
        local start = 0
        local pos = 0

        local nodes = modifiers.nodes
        local lastModifier
        while start < #nodes do
            while pos < #nodes do
                lastModifier = nodes[pos + 1]
                if ast.IsDecorator(lastModifier) then
                    mode = ModeDecorators
                else
                    mode = ModeModifiers
                end
                if lastMode == ModeNone then
                    lastMode = mode
                elseif mode ~= lastMode then
                    break
                end
                pos = pos + 1
            end

            local textRange = core.NewTextRange(-1, -1)
            if start == 0 then
                textRange = core.NewTextRange(modifiers:Pos(), textRange.end_)
            end
            if pos == #nodes - 1 then
                textRange = core.NewTextRange(textRange.pos, modifiers:End())
            end
            if allowDecorators or lastMode == ModeModifiers then
                self:emitListItems(
                    Printer.emitModifierLike,
                    parentNode,
                    core.Slice(nodes, start, pos),
                    lastMode == ModeModifiers and LF.LFModifiers or LF.LFDecorators,
                    false, --[[hasTrailingComma]]
                    textRange
                )
            end
            start = pos
            lastMode = mode
            pos = pos + 1
        end

        if self.onAfterEmitNodeList ~= nil then
            self.onAfterEmitNodeList(modifiers)
        end
    end

    return printer.greatestEnd(parentNode:Pos(), modifiers.nodes[#modifiers.nodes])
end

function Printer:emitTypeParameter(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:emitBindingIdentifier(node:Name())
    if node.constraint ~= nil then
        self:writeSpace()
        self:writeKeyword("extends")
        self:writeSpace()
        self:emitTypeNodeOutsideExtends(node.constraint)
    end
    if node.defaultType ~= nil then
        self:writeSpace()
        self:writeOperator("=")
        self:writeSpace()
        self:emitTypeNodeOutsideExtends(node.defaultType)
    end
    self:exitNode(node, state)
end

function Printer:emitTypeParameterDeclarationNode(node)
    -- NOTE: QuickInfo uses TypeFormatFlagsWriteTypeArgumentsOfSignature to instruct the NodeBuilder to store type arguments
    -- (i.e. type nodes) instead of type parameter declarations in the type parameter list.
    if ast.IsTypeParameterDeclaration(node) then
        self:emitTypeParameter(node)
    else
        self:emitTypeArgument(node)
    end
end

function Printer:emitParameterName(node)
    local savedWriteKind = self.writeKind
    self.writeKind = WriteKind.Parameter
    self:emitBindingName(node)
    self.writeKind = savedWriteKind
end

function Printer:emitParameter(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitTokenNode(node.dotDotDotToken)
    self:emitParameterName(node:Name())
    self:emitTokenNode(node.questionToken)

    self:emitTypeAnnotation(node.type)

    -- The comment position has to fallback to any present node within the parameter declaration because as it turns
    -- out, the parser can make parameter declarations with _just_ an initializer.
    self:emitInitializer(node.initializer, printer.greatestEnd(node:Pos(), node.type, node.questionToken, node:Name(), node:Modifiers()), node)
    self:exitNode(node, state)
end

function Printer:emitParameterDeclarationNode(node)
    self:emitParameter(node)
end

function Printer:emitDecorator(node)
    local state = self:enterNode(node)
    self:writePunctuation("@")
    self:emitExpression(node.expression, OperatorPrecedence.LeftHandSide)
    self:exitNode(node, state)
end

function Printer:emitModifierLike(node)
    if ast.IsDecorator(node) then
        self:emitDecorator(node)
    elseif ast.IsModifier(node) then
        self:emitKeywordNode(node)
    else
        error("unhandled ModifierLike: " .. kindString(node.kind), 0)
    end
end

function Printer:emitTypeParameters(parentNode, nodes)
    if nodes == nil then
        return
    end
    self:emitList(Printer.emitTypeParameterDeclarationNode, parentNode, nodes, LF.LFTypeParameters | (ast.IsArrowFunction(parentNode) --[[p.shouldAllowTrailingComma(parentNode, nodes)]] and LF.LFAllowTrailingComma or LF.LFNone)) -- TODO: preserve trailing comma after Strada migration
end

function Printer:emitTypeAnnotation(node)
    if node == nil then
        return
    end

    self:writePunctuation(":")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node)
end

function Printer:emitInitializer(node, equalTokenPos, contextNode)
    if node == nil then
        return
    end

    self:writeSpace()
    self:emitToken(Kind.EqualsToken, equalTokenPos, WriteKind.Operator, contextNode)
    self:writeSpace()
    self:emitExpression(node, OperatorPrecedence.DisallowComma)
end

function Printer:emitParameters(parentNode, parameters)
    self:generateAllNames(parameters)
    self:emitList(Printer.emitParameterDeclarationNode, parentNode, parameters, LF.LFParameters --[[|core.IfElse(p.shouldAllowTrailingComma(parentNode, parameters), LFAllowTrailingComma, LFNone)]]) -- TODO: preserve trailing comma after Strada migration
end

function printer.canEmitSimpleArrowHead(parentNode, parameters)
    -- only arrow functions with a single parameter may have simple arrow head
    if not ast.IsArrowFunction(parentNode) or #parameters.nodes ~= 1 then
        return false
    end

    local parent = parentNode
    local parameter = parameters.nodes[1]
    local parentModifiers = parent:Modifiers()

    return parameter:Pos() == parent:Pos() and -- may not have parsed tokens between start of parent and parameter
        parent.typeParameters == nil and -- parent may not have type parameters
        parent.type == nil and -- parent may not have return type annotation
        (parentModifiers == nil or #parentModifiers.nodes == 0) and -- parent may not have modifiers
        not parameters:HasTrailingComma() and -- parameters may not have a trailing comma
        parameter:Modifiers() == nil and -- parameter may not have decorators or modifiers
        parameter.dotDotDotToken == nil and -- parameter may not be rest
        parameter.questionToken == nil and -- parameter may not be optional
        parameter.type == nil and -- parameter may not have a type annotation
        parameter.initializer == nil and -- parameter may not have an initializer
        ast.IsIdentifier(parameter:Name()) -- parameter name must be identifier
end

function Printer:emitParametersForArrow(parentNode --[[FunctionType | ConstructorType | ArrowFunction]], parameters)
    if printer.canEmitSimpleArrowHead(parentNode, parameters) then
        self:generateAllNames(parameters)
        self:emitList(Printer.emitParameterDeclarationNode, parentNode, parameters, LF.LFSingleArrowParameter)
    else
        self:emitParameters(parentNode, parameters)
    end
end

function Printer:emitParametersForIndexSignature(parentNode, parameters)
    self:generateAllNames(parameters)
    self:emitList(Printer.emitParameterDeclarationNode, parentNode, parameters, LF.LFIndexSignatureParameters)
end

function Printer:emitSignature(node)
    -- Go: n := node.FunctionLikeData() (the FunctionLikeBase fields are flattened onto the node)
    local n = node

    -- !!! In old emitter, quickinfo used type arguments in place of type parameters on instantiated signatures
    ----if n.TypeArguments != nil {
    ----	p.emitTypeArguments(node, n.TypeArguments)
    ----} else {
    self:emitTypeParameters(node, n.typeParameters)
    ----}

    self:emitParameters(node, n.parameters)
    self:emitTypeAnnotation(n.type)
end

function Printer:emitFunctionBody(body)
    self.emitContext:AddEmitFlags(body, EF.EFNoSourceMap)

    -- Use only notification hooks for the body block, not the full comment pipeline.
    -- Without this, trailing comments from the original method declaration
    -- (e.g., "// Error") leak into synthesized comma expressions when methods
    -- are hoisted into pending expressions.
    if self.onBeforeEmitNode ~= nil then
        self.onBeforeEmitNode(body)
    end

    self:generateNames(body)

    -- !!! Emit with comment after Strada migration
    ----p.emitTokenWithComment(ast.KindOpenBraceToken, body.Pos(), WriteKindPunctuation, body.AsNode())
    self:writePunctuation("{")

    self:increaseIndent()
    local detachedState = self:emitDetachedCommentsBeforeStatementList(body, body.statements.loc)
    local statementOffset = self:emitPrologueDirectives(body.statements)
    local pos = self.writer:GetTextPos()
    self:emitHelpers(body)

    if self:shouldEmitBlockFunctionBodyOnSingleLine(body) and statementOffset == 0 and pos == self.writer:GetTextPos() then
        self:decreaseIndent()
        self:emitListRange(Printer.emitStatement, body, body.statements, LF.LFSingleLineFunctionBodyStatements, statementOffset, -1)
        self:increaseIndent()
    else
        self:emitListRange(Printer.emitStatement, body, body.statements, LF.LFMultiLineFunctionBodyStatements, statementOffset, -1)
    end

    self:emitDetachedCommentsAfterStatementList(body, body.statements.loc, detachedState)
    self:decreaseIndent()

    -- !!! Emit comment after Strada migration
    ----p.emitTokenEx(ast.KindCloseBraceToken, body.Statements.End(), WriteKindPunctuation, body.AsNode(), tefNone)
    self:emitTokenEx(Kind.CloseBraceToken, body.statements:End(), WriteKind.Punctuation, body, printer.tefNoComments)

    if self.onAfterEmitNode ~= nil then
        self.onAfterEmitNode(body)
    end
end

function Printer:emitFunctionBodyNode(node)
    if node == nil then
        self:writeTrailingSemicolon()
        return
    end

    self:writeSpace()
    self:emitFunctionBody(node)
end

--
-- Type Members
--

function Printer:emitPropertySignature(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:emitPropertyName(node:Name())
    self:emitTokenNode(node.postfixToken)
    self:emitTypeAnnotation(node.type)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitPropertyDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitPropertyName(node:Name())
    self:emitTokenNode(node.postfixToken)
    self:emitTypeAnnotation(node.type)
    self:emitInitializer(node.initializer, printer.greatestEnd(node:Name():End(), node.type, node.postfixToken), node)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitMethodSignature(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:emitPropertyName(node:Name())
    self:emitTokenNode(node.postfixToken)
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:writeTrailingSemicolon()
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitMethodDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitTokenNode(node.asteriskToken)
    self:emitPropertyName(node:Name())
    self:emitTokenNode(node.postfixToken)
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitClassStaticBlockDeclaration(node)
    local state = self:enterNode(node)
    self:writeKeyword("static")
    self:pushNameGenerationScope(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:exitNode(node, state)
end

function Printer:emitConstructor(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("constructor")
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitAccessorDeclaration(token, node)
    local state = self:enterNode(node)
    local pos = self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitToken(token, pos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitPropertyName(node:Name())
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitGetAccessorDeclaration(node)
    self:emitAccessorDeclaration(Kind.GetKeyword, node)
end

function Printer:emitSetAccessorDeclaration(node)
    self:emitAccessorDeclaration(Kind.SetKeyword, node)
end

function Printer:emitCallSignature(node)
    local state = self:enterNode(node)
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:writeTrailingSemicolon()
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitConstructSignature(node)
    local state = self:enterNode(node)
    self:writeKeyword("new")
    self:writeSpace()
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:writeTrailingSemicolon()
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitIndexSignature(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitParametersForIndexSignature(node, node.parameters)
    self:emitTypeAnnotation(node.type)
    self:writeTrailingSemicolon()
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitClassElement(node)
    local k = node.kind
    if k == Kind.PropertyDeclaration then
        self:emitPropertyDeclaration(node)
    elseif k == Kind.MethodDeclaration then
        self:emitMethodDeclaration(node)
    elseif k == Kind.ClassStaticBlockDeclaration then
        self:emitClassStaticBlockDeclaration(node)
    elseif k == Kind.Constructor then
        self:emitConstructor(node)
    elseif k == Kind.GetAccessor then
        self:emitGetAccessorDeclaration(node)
    elseif k == Kind.SetAccessor then
        self:emitSetAccessorDeclaration(node)
    elseif k == Kind.IndexSignature then
        self:emitIndexSignature(node)
    elseif k == Kind.SemicolonClassElement then
        self:emitSemicolonClassElement(node)
    elseif k == Kind.NotEmittedStatement then
        self:emitNotEmittedStatement(node)
    elseif k == Kind.JSTypeAliasDeclaration then
        self:emitTypeAliasDeclaration(node)
    else
        error("unexpected ClassElement: " .. kindString(k), 0)
    end
end

function Printer:emitTypeElement(node)
    local k = node.kind
    if k == Kind.PropertySignature then
        self:emitPropertySignature(node)
    elseif k == Kind.MethodSignature then
        self:emitMethodSignature(node)
    elseif k == Kind.CallSignature then
        self:emitCallSignature(node)
    elseif k == Kind.ConstructSignature then
        self:emitConstructSignature(node)
    elseif k == Kind.GetAccessor then
        self:emitGetAccessorDeclaration(node)
    elseif k == Kind.SetAccessor then
        self:emitSetAccessorDeclaration(node)
    elseif k == Kind.IndexSignature then
        self:emitIndexSignature(node)
    elseif k == Kind.NotEmittedTypeElement then
        self:emitNotEmittedTypeElement(node)
    else
        error("unexpected TypeElement: " .. kindString(k), 0)
    end
end

function Printer:emitObjectLiteralElement(node)
    local k = node.kind
    if k == Kind.PropertyAssignment then
        self:emitPropertyAssignment(node)
    elseif k == Kind.ShorthandPropertyAssignment then
        self:emitShorthandPropertyAssignment(node)
    elseif k == Kind.SpreadAssignment then
        self:emitSpreadAssignment(node)
    elseif k == Kind.MethodDeclaration then
        self:emitMethodDeclaration(node)
    elseif k == Kind.GetAccessor then
        self:emitGetAccessorDeclaration(node)
    elseif k == Kind.SetAccessor then
        self:emitSetAccessorDeclaration(node)
    else
        error("unhandled ObjectLiteralElement: " .. kindString(k), 0)
    end
end

--
-- Types
--

function Printer:emitKeywordTypeNode(node)
    self:emitKeywordNode(node)
end

function Printer:emitTypePredicateParameterName(node)
    local k = node.kind
    if k == Kind.Identifier then
        self:emitIdentifierReference(node)
    elseif k == Kind.ThisType then
        self:emitThisType(node)
    else
        error("unexpected TypePredicateParameterName: " .. kindString(k), 0)
    end
end

function Printer:emitTypePredicate(node)
    local state = self:enterNode(node)
    if node.assertsModifier ~= nil then
        self:emitTokenNode(node.assertsModifier)
        self:writeSpace()
    end
    self:emitTypePredicateParameterName(node.parameterName)
    if node.type ~= nil then
        self:writeSpace()
        self:writeKeyword("is")
        self:writeSpace()
        self:emitTypeNodeOutsideExtends(node.type)
    end
    self:exitNode(node, state)
end

function Printer:emitTypeArgument(node)
    self:emitTypeNodeOutsideExtends(node)
end

function Printer:emitTypeArguments(parentNode, nodes)
    if nodes == nil then
        return
    end
    self:emitList(Printer.emitTypeParameterDeclarationNode, parentNode, nodes, LF.LFTypeArguments --[[|core.IfElse(p.shouldAllowTrailingComma(parentNode, nodes), LFAllowTrailingComma, LFNone)]]) -- TODO: preserve trailing comma after Strada migration
end

function Printer:emitTypeReference(node)
    local state = self:enterNode(node)
    self:emitEntityName(node.typeName)
    self:emitTypeArguments(node, node.typeArguments)
    self:exitNode(node, state)
end

-- Emits the return type of a FunctionTypeNode or ConstructorTypeNode, including the arrow (`=>`)
function Printer:emitReturnType(node)
    if node == nil then
        return
    end
    self:writePunctuation("=>")
    self:writeSpace()
    if self.inExtends and node.kind == Kind.InferType and node.typeParameter.constraint ~= nil then
        -- if the parent FunctionTypeNode or ConstructorTypeNode is in the `extends` clause of a ConditionalTypeNode,
        -- we must parenthesize `infer ... extends ...` so as not to result in an ambiguous parse.
        --
        -- `T extends () => infer U extends V ? W : X` would parse the `? W : X` as part of a ConditionalTypeNode in the
        -- return type of the FunctionTypeNode, thus we must emit as `T extends () => (infer U extends V) ? W : X`
        self:emitTypeNodePreservingExtends(node, TypePrecedence.Highest)
    else
        self:emitTypeNodePreservingExtends(node, TypePrecedence.Lowest)
    end
end

function Printer:emitFunctionType(node)
    local state = self:enterNode(node)
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    -- !!! in the old emitter, quickinfo uses type arguments in place of type parameters for instantiated signatures
    self:emitTypeParameters(node, node.typeParameters)
    self:emitParameters(node, node.parameters)
    self:writeSpace()
    self:emitReturnType(node.type)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitConstructorType(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("new")
    self:writeSpace()
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    -- !!! in the old emitter, quickinfo uses type arguments in place of type parameters for instantiated signatures
    self:emitTypeParameters(node, node.typeParameters)
    self:emitParameters(node, node.parameters)
    self:writeSpace()
    self:emitReturnType(node.type)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitTypeQuery(node)
    local state = self:enterNode(node)
    self:writeKeyword("typeof")
    self:writeSpace()
    self:emitEntityName(node.exprName)
    self:emitTypeArguments(node, node.typeArguments)
    self:exitNode(node, state)
end

function Printer:emitTypeLiteral(node)
    local state = self:enterNode(node)
    self:pushNameGenerationScope(node)
    self:generateAllMemberNames(node.members)
    self:writePunctuation("{")
    local flags = self:shouldEmitOnSingleLine(node) and LF.LFSingleLineTypeLiteralMembers or LF.LFMultiLineTypeLiteralMembers
    self:emitList(Printer.emitTypeElement, node, node.members, flags | LF.LFNoSpaceIfEmpty)
    self:writePunctuation("}")
    self:popNameGenerationScope(node)
    self:exitNode(node, state)
end

function Printer:emitArrayType(node)
    local state = self:enterNode(node)
    self:emitPostfixTypeOperand(node.elementType, node)
    self:writePunctuation("[")
    self:writePunctuation("]")
    self:exitNode(node, state)
end

-- emitPostfixTypeOperand emits the operand of a postfix type (ArrayType, IndexedAccessType,
-- OptionalType). It is equivalent to `emitTypeNode(operand, TypePrecedencePostfix)` except
-- that it preserves a parsed `typeof X` operand without adding parentheses (e.g.,
-- `typeof C[K]` instead of `(typeof C)[K]`). TypeScript's `parenthesizeNonArrayTypeOfPostfixType`
-- factory rule wraps `TypeQuery` in `ParenthesizedType` only when a postfix type is constructed
-- via the factory, so parsed postfix types preserve the source as written during round-trip
-- emit while synthesized postfix types (e.g., from declaration emit) still get the parentheses.
function Printer:emitPostfixTypeOperand(operand, parent)
    if ast.IsParseTreeNode(parent) and operand.kind == Kind.TypeQuery then
        self:emitTypeNode(operand, TypePrecedence.TypeOperator)
        return
    end
    self:emitTypeNode(operand, TypePrecedence.Postfix)
end

function Printer:emitTupleElementType(node)
    self:emitTypeNodeOutsideExtends(node)
end

function Printer:emitTupleType(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.OpenBracketToken, node:Pos(), WriteKind.Punctuation, node)
    local flags = self:shouldEmitOnSingleLine(node) and LF.LFSingleLineTupleTypeElements or LF.LFMultiLineTupleTypeElements
    self:emitList(Printer.emitTupleElementType, node, node.elements, flags | LF.LFNoSpaceIfEmpty)
    self:emitToken(Kind.CloseBracketToken, node.elements:End(), WriteKind.Punctuation, node)
    self:exitNode(node, state)
end

function Printer:emitRestType(node)
    local state = self:enterNode(node)
    self:writePunctuation("...")
    self:emitTypeNodeOutsideExtends(node.type)
    self:exitNode(node, state)
end

function Printer:emitOptionalType(node)
    local state = self:enterNode(node)
    -- !!! May need extra parenthesization if we also have JSDocNullableType
    self:emitPostfixTypeOperand(node.type, node)
    self:writePunctuation("?")
    self:exitNode(node, state)
end

function Printer:emitNamedTupleMember(node)
    local state = self:enterNode(node)
    self:emitPunctuationNode(node.dotDotDotToken)
    self:emitIdentifierName(node:Name())
    self:emitPunctuationNode(node.questionToken)
    self:emitToken(Kind.ColonToken, printer.greatestEnd(node:Name():End(), node.questionToken), WriteKind.Punctuation, node)
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.type)
    self:exitNode(node, state)
end

function Printer:emitUnionTypeConstituent(node)
    self:emitTypeNode(node, TypePrecedence.TypeOperator)
end

function Printer:emitUnionType(node)
    local state = self:enterNode(node)
    self:emitList(Printer.emitUnionTypeConstituent, node, node.types, LF.LFUnionTypeConstituents)
    self:exitNode(node, state)
end

function Printer:emitIntersectionTypeConstituent(node)
    self:emitTypeNode(node, TypePrecedence.TypeOperator)
end

function Printer:emitIntersectionType(node)
    local state = self:enterNode(node)
    self:emitList(Printer.emitIntersectionTypeConstituent, node, node.types, LF.LFIntersectionTypeConstituents --[[, parenthesizer.parenthesizeConstituentTypeOfIntersectionType]]) -- !!!
    self:exitNode(node, state)
end

function Printer:emitConditionalType(node)
    local state = self:enterNode(node)
    self:emitTypeNode(node.checkType, TypePrecedence.Union)
    self:writeSpace()
    self:writeKeyword("extends")
    self:writeSpace()
    self:emitTypeNodeInExtends(node.extendsType)
    self:writeSpace()
    self:writePunctuation("?")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.trueType)
    self:writeSpace()
    self:writePunctuation(":")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.falseType)
    self:exitNode(node, state)
end

function Printer:emitInferTypeParameter(node)
    local state = self:enterNode(node)
    self:emitBindingIdentifier(node:Name())
    if node.constraint ~= nil then
        self:writeSpace()
        self:writeKeyword("extends")
        self:writeSpace()
        self:emitTypeNodeInExtends(node.constraint)
    end
    self:exitNode(node, state)
end

function Printer:emitInferType(node)
    local state = self:enterNode(node)
    self:writeKeyword("infer")
    self:writeSpace()
    self:emitInferTypeParameter(node.typeParameter)
    self:exitNode(node, state)
end

function Printer:emitParenthesizedType(node)
    local state = self:enterNode(node)
    self:writePunctuation("(")
    self:emitTypeNodeOutsideExtends(node.type)
    self:writePunctuation(")")
    self:exitNode(node, state)
end

function Printer:emitThisType(node)
    local state = self:enterNode(node)
    self:writeKeyword("this")
    self:exitNode(node, state)
end

function Printer:emitTypeOperator(node)
    local state = self:enterNode(node)
    self:emitToken(node.operator, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitTypeNode(node.type, node.operator == Kind.ReadonlyKeyword and TypePrecedence.Postfix or TypePrecedence.TypeOperator)
    self:exitNode(node, state)
end

function Printer:emitIndexedAccessType(node)
    local state = self:enterNode(node)
    self:emitPostfixTypeOperand(node.objectType, node)
    self:writePunctuation("[")
    self:emitTypeNodeOutsideExtends(node.indexType)
    self:writePunctuation("]")
    self:exitNode(node, state)
end

function Printer:emitMappedTypeParameter(node)
    local state = self:enterNode(node)
    self:emitBindingIdentifier(node:Name())
    self:writeSpace()
    self:writeKeyword("in")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.constraint)
    self:exitNode(node, state)
end

function Printer:emitMappedType(node)
    local state = self:enterNode(node)
    local singleLine = self:shouldEmitOnSingleLine(node)
    self:writePunctuation("{")
    if singleLine then
        self:writeSpace()
    else
        self:writeLine()
        self:increaseIndent()
    end
    if node.readonlyToken ~= nil then
        self:emitTokenNode(node.readonlyToken)
        if node.readonlyToken.kind ~= Kind.ReadonlyKeyword then
            self:writeKeyword("readonly")
        end
        self:writeSpace()
    end
    self:writePunctuation("[")
    self:emitMappedTypeParameter(node.typeParameter)
    if node.nameType ~= nil then
        self:writeSpace()
        self:writeKeyword("as")
        self:writeSpace()
        self:emitTypeNodeOutsideExtends(node.nameType)
    end
    self:writePunctuation("]")
    if node.questionToken ~= nil then
        self:emitPunctuationNode(node.questionToken)
        if node.questionToken.kind ~= Kind.QuestionToken then
            self:writePunctuation("?")
        end
    end
    self:writePunctuation(":")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.type)
    self:writeTrailingSemicolon()
    if node.members ~= nil then
        if #node.members.nodes > 0 then
            if singleLine then
                self:writeSpace()
            else
                self:writeLine()
            end
            self:emitList(Printer.emitTypeElement, node, node.members, LF.LFPreserveLines)
        end
    end
    if singleLine then
        self:writeSpace()
    else
        self:writeLine()
        self:decreaseIndent()
    end
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitLiteralType(node)
    local state = self:enterNode(node)
    self:emitExpression(node.literal, OperatorPrecedence.Comma)
    self:exitNode(node, state)
end

function Printer:emitTemplateTypeSpan(node)
    local state = self:enterNode(node)
    self:emitTypeNodeOutsideExtends(node.type)
    self:emitTemplateMiddleTail(node.literal)
    self:exitNode(node, state)
end

function Printer:emitTemplateTypeSpanNode(node)
    self:emitTemplateTypeSpan(node)
end

function Printer:emitTemplateType(node)
    local state = self:enterNode(node)
    self:emitTemplateHead(node.head)
    self:emitList(Printer.emitTemplateTypeSpanNode, node, node.templateSpans, LF.LFTemplateExpressionSpans)
    self:exitNode(node, state)
end

function Printer:emitImportTypeNodeAttributes(node)
    local state = self:enterNode(node)
    self:writePunctuation("{")
    self:writeSpace()
    self:writeKeyword(node.token == Kind.AssertKeyword and "assert" or "with")
    self:writePunctuation(":")
    self:writeSpace()
    self:emitList(Printer.emitImportAttributeNode, node, node.attributes, LF.LFImportAttributes)
    self:writeSpace()
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitImportTypeNode(node)
    local state = self:enterNode(node)
    if node.isTypeOf then
        self:writeKeyword("typeof")
        self:writeSpace()
    end
    self:writeKeyword("import")
    self:writePunctuation("(")
    self:emitTypeNodeOutsideExtends(node.argument)
    if node.attributes ~= nil then
        self:writePunctuation(",")
        self:writeSpace()
        self:emitImportTypeNodeAttributes(node.attributes)
    end
    self:writePunctuation(")")
    if node.qualifier ~= nil then
        self:writePunctuation(".")
        self:emitEntityName(node.qualifier)
    end
    self:emitTypeArguments(node, node.typeArguments)
    self:exitNode(node, state)
end

-- emits a Type node in the `extends` clause of a ConditionalType
function Printer:emitTypeNodeInExtends(node)
    local savedInExtends = self.inExtends
    self.inExtends = true
    self:emitTypeNodePreservingExtends(node, TypePrecedence.Lowest)
    self.inExtends = savedInExtends
end

-- emits a Type node not in the `extends` clause of a ConditionalType or InferType
function Printer:emitTypeNodeOutsideExtends(node)
    local savedInExtends = self.inExtends
    self.inExtends = false
    self:emitTypeNodePreservingExtends(node, TypePrecedence.Lowest)
    self.inExtends = savedInExtends
end

-- emits a Type node preserving whether or not we are currently in the `extends` clause of a ConditionalType or InferType
function Printer:emitTypeNodePreservingExtends(node, precedence)
    self:emitTypeNode(node, precedence)
end

function Printer:emitTypeNode(node, precedence)
    if self.inExtends and precedence <= TypePrecedence.Conditional then
        -- in the `extends` clause of a ConditionalType or InferType, a ConditionalType must be parenthesized
        precedence = TypePrecedence.Function
    end

    local savedInExtends = self.inExtends
    local parens = ast.GetTypeNodePrecedence(node) < precedence
    if parens then
        self.inExtends = false
        self:writePunctuation("(")
    end

    local k = node.kind
    -- Keyword Types
    if k == Kind.AnyKeyword or
        k == Kind.UnknownKeyword or
        k == Kind.NumberKeyword or
        k == Kind.BigIntKeyword or
        k == Kind.ObjectKeyword or
        k == Kind.BooleanKeyword or
        k == Kind.StringKeyword or
        k == Kind.SymbolKeyword or
        k == Kind.VoidKeyword or
        k == Kind.UndefinedKeyword or
        k == Kind.NeverKeyword or
        k == Kind.IntrinsicKeyword then
        self:emitKeywordTypeNode(node)

        -- Types
    elseif k == Kind.TypePredicate then
        self:emitTypePredicate(node)
    elseif k == Kind.TypeReference then
        self:emitTypeReference(node)
    elseif k == Kind.FunctionType then
        self:emitFunctionType(node)
    elseif k == Kind.ConstructorType then
        self:emitConstructorType(node)
    elseif k == Kind.TypeQuery then
        self:emitTypeQuery(node)
    elseif k == Kind.TypeLiteral then
        self:emitTypeLiteral(node)
    elseif k == Kind.ArrayType then
        self:emitArrayType(node)
    elseif k == Kind.TupleType then
        self:emitTupleType(node)
    elseif k == Kind.OptionalType then
        self:emitOptionalType(node)
    elseif k == Kind.RestType then
        self:emitRestType(node)
    elseif k == Kind.UnionType then
        self:emitUnionType(node)
    elseif k == Kind.IntersectionType then
        self:emitIntersectionType(node)
    elseif k == Kind.ConditionalType then
        self:emitConditionalType(node)
    elseif k == Kind.InferType then
        self:emitInferType(node)
    elseif k == Kind.ParenthesizedType then
        self:emitParenthesizedType(node)
    elseif k == Kind.ThisType then
        self:emitThisType(node)
    elseif k == Kind.TypeOperator then
        self:emitTypeOperator(node)
    elseif k == Kind.IndexedAccessType then
        self:emitIndexedAccessType(node)
    elseif k == Kind.MappedType then
        self:emitMappedType(node)
    elseif k == Kind.LiteralType then
        self:emitLiteralType(node)
    elseif k == Kind.NamedTupleMember then
        self:emitNamedTupleMember(node)
    elseif k == Kind.TemplateLiteralType then
        self:emitTemplateType(node)
    elseif k == Kind.TemplateLiteralTypeSpan then
        self:emitTemplateTypeSpan(node)
    elseif k == Kind.ImportType then
        self:emitImportTypeNode(node)

    elseif k == Kind.PropertyAccessExpression then
        -- Occurs in pseudo-types such as `f<T>.C`, where `f` is a generic function and `C` is a local type
        self:emitPropertyAccessExpression(node)
    elseif k == Kind.ExpressionWithTypeArguments then
        -- !!! Should this actually be considered a type?
        self:emitExpressionWithTypeArguments(node)

    elseif k == Kind.JSDocAllType then
        self:emitJSDocAllType(node)
    elseif k == Kind.JSDocNonNullableType then
        self:emitJSDocNonNullableType(node)
    elseif k == Kind.JSDocNullableType then
        self:emitJSDocNullableType(node)
    elseif k == Kind.JSDocOptionalType then
        self:emitJSDocOptionalType(node)
    elseif k == Kind.JSDocVariadicType then
        self:emitJSDocVariadicType(node)

    else
        error("unhandled TypeNode: " .. kindString(k), 0)
    end

    if parens then
        self:writePunctuation(")")
    end

    self.inExtends = savedInExtends
end

--
-- Binding patterns
--

function Printer:emitObjectBindingPattern(node)
    local state = self:enterNode(node)
    self:writePunctuation("{")
    self:emitList(Printer.emitBindingElementNode, node, node.elements, LF.LFObjectBindingPatternElements)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitArrayBindingPattern(node)
    local state = self:enterNode(node)
    self:writePunctuation("[")
    self:emitList(Printer.emitBindingElementNode, node, node.elements, LF.LFArrayBindingPatternElements)
    self:writePunctuation("]")
    self:exitNode(node, state)
end

function Printer:emitBindingElement(node)
    local state = self:enterNode(node)
    self:emitTokenNode(node.dotDotDotToken)
    if node.propertyName ~= nil then
        self:emitPropertyName(node.propertyName)
        self:writePunctuation(":")
        self:writeSpace()
    end
    -- Old parser used `OmittedExpression` as a substitute for `Elision`. New parser uses a `BindingElement` with nil members
    local name = node:Name()
    if name ~= nil then
        self:emitBindingName(name)
        self:emitInitializer(node.initializer, node:Name():End(), node)
    end
    self:exitNode(node, state)
end

function Printer:emitBindingElementNode(node)
    self:emitBindingElement(node)
end

function Printer:emitJSDocAllType(node)
    self:emitKeywordNode(node)
end

function Printer:emitJSDocNonNullableType(node)
    local state = self:enterNode(node)
    self:writePunctuation("!")
    self:emitTypeNode(node.type, TypePrecedence.NonArray)
    self:exitNode(node, state)
end

function Printer:emitJSDocNullableType(node)
    local state = self:enterNode(node)
    self:writePunctuation("?")
    self:emitTypeNode(node.type, TypePrecedence.NonArray)
    self:exitNode(node, state)
end

function Printer:emitJSDocOptionalType(node)
    local state = self:enterNode(node)
    self:emitTypeNode(node.type, TypePrecedence.JSDoc)
    self:writePunctuation("=")
    self:exitNode(node, state)
end

function Printer:emitJSDocVariadicType(node)
    local state = self:enterNode(node)
    self:writePunctuation("...")
    self:emitTypeNode(node.type, TypePrecedence.JSDoc)
    self:exitNode(node, state)
end
