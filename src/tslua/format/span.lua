local format = require("tslua.format")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local debug = require("tslua.debug")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local LineAction = format.LineAction
local ruleAction = format.ruleAction
local ruleFlags = format.ruleFlags

-- Go `r == NewTextRangeWithKind(0, 0, 0)` (value comparison with the zero TextRangeWithKind).
local function isZeroRangeWithKind(r)
    return r.loc.pos == 0 and r.loc.end_ == 0 and r.kind == 0
end

local zeroRangeWithKind = { loc = core.NewTextRange(0, 0), kind = 0 }

-- Go strings.Repeat (panics on a negative count).
local function stringsRepeat(s, count)
    if count < 0 then
        error("strings: negative Repeat count")
    end
    return string.rep(s, count)
end

--[[* find node that fully contains given text range ]]
function format.findEnclosingNode(r, sourceFile)
    local find
    find = function(n)
        local candidate = nil
        n:ForEachChild(function(c)
            if c.flags & NodeFlags.Reparsed ~= 0 then
                return false
            end
            if r:ContainedBy(format.withTokenStart(c, sourceFile)) then
                candidate = c
                return true
            end
            return false
        end)
        if candidate ~= nil then
            local result = find(candidate)
            if result ~= nil then
                return result
            end
        end

        return n
    end
    return find(sourceFile:AsNode())
end

--[[*
 * Start of the original range might fall inside the comment - scanner will not yield appropriate results
 * This function will look for token that is located before the start of target range
 * and return its end as start position for the scanner.
 ]]
function format.getScanStartPosition(enclosingNode, originalRange, sourceFile)
    local adjusted = format.withTokenStart(enclosingNode, sourceFile)
    local start = adjusted:Pos()
    if start == originalRange:Pos() and enclosingNode:End() == originalRange:End() then
        return start
    end

    -- exclude JSDoc so the scan never starts inside a JSDoc comment
    local precedingToken = astnav.FindPrecedingTokenEx(sourceFile, originalRange:Pos(), nil --[[startNode]],
        true --[[excludeJSDoc]])
    if precedingToken == nil then
        -- no preceding token found - start from the beginning of enclosing node
        return enclosingNode:Pos()
    end

    -- preceding token ends after the start of original range (i.e when originalRange.pos falls in the middle of literal)
    -- start from the beginning of enclosingNode to handle the entire 'originalRange'
    if precedingToken:End() >= originalRange:Pos() then
        return enclosingNode:Pos()
    end

    return precedingToken:End()
end

--[[
 * For cases like
 * if (a ||
 *     b ||$
 *     c) {...}
 * If we hit Enter at $ we want line '    b ||' to be indented.
 * Formatting will be applied to the last two lines.
 * Node that fully encloses these lines is binary expression 'a ||...'.
 * Initial indentation for this node will be 0.
 * Binary expressions don't introduce new indentation scopes, however it is possible
 * that some parent node on the same line does - like if statement in this case.
 * Note that we are considering parents only from the same line with initial node -
 * if parent is on the different line - its delta was already contributed
 * to the initial indentation.
 ]]
function format.getOwnOrInheritedDelta(n, options, sourceFile)
    local previousLine = -1
    local child = nil
    while n ~= nil do
        local line = scanner.GetECMALineOfPosition(sourceFile, format.withTokenStart(n, sourceFile):Pos())
        if previousLine ~= -1 and line ~= previousLine then
            break
        end

        if format.ShouldIndentChildNode(options, n, child, sourceFile) then
            return options.indentSize -- !!! nil check???
        end

        previousLine = line
        child = n
        n = n.parent
    end
    return 0
end

function format.rangeHasNoErrors(_)
    return false
end

function format.prepareRangeContainsErrorFunction(errors, originalRange)
    if core.Len(errors) == 0 then
        return format.rangeHasNoErrors
    end

    -- pick only errors that fall in range
    local sorted = core.Filter(errors, function(d)
        return originalRange:Overlaps(d:Loc())
    end)
    if #sorted == 0 then
        return format.rangeHasNoErrors
    end
    core.SortStableFunc(sorted, function(a, b) return a:Pos() - b:Pos() end)

    local index = 0
    return function(r)
        -- in current implementation sequence of arguments [r1, r2...] is monotonically increasing.
        -- 'index' tracks the index of the most recent error that was checked.
        while true do
            if index >= #sorted then
                -- all errors in the range were already checked -> no error in specified range
                return false
            end

            local err = sorted[index + 1]

            if r:End() <= err:Pos() then
                -- specified range ends before the error referred by 'index' - no error in range
                return false
            end

            if r:Overlaps(err:Loc()) then
                -- specified range overlaps with error range
                return true
            end

            index = index + 1
        end
    end
end

local formatSpanWorker = {}
formatSpanWorker.__index = formatSpanWorker
format.formatSpanWorker = formatSpanWorker

function format.newFormatSpanWorker(ctx, originalRange, enclosingNode, initialIndentation, delta, requestKind,
                                    rangeContainsError, sourceFile)
    return setmetatable({
        ctx = ctx,
        originalRange = originalRange,
        enclosingNode = enclosingNode,
        initialIndentation = initialIndentation,
        delta = delta,
        requestKind = requestKind,
        rangeContainsError = rangeContainsError,
        sourceFile = sourceFile,

        formattingScanner = nil,
        formattingContext = nil,

        edits = nil,
        previousRange = zeroRangeWithKind,
        previousRangeTriviaEnd = 0,
        previousParent = nil,
        previousRangeStartLine = 0,

        childContextNode = nil,
        lastIndentedLine = 0,
        indentationOnLastIndentedLine = 0,

        visitor = nil,
        visitingNode = nil,
        visitingIndenter = nil,
        visitingNodeStartLine = 0,
        visitingUndecoratedNodeStartLine = 0,

        currentRules = {}, -- increaseInsertionIndex should assert there are no more than 32 rules in a given bucket
    }, formatSpanWorker)
end

function format.getNonDecoratorTokenPosOfNode(node, file)
    local lastDecorator = nil
    if ast.HasDecorators(node) then
        lastDecorator = core.FindLast(node:ModifierNodes(), ast.IsDecorator)
    end
    if file == nil then
        file = ast.GetSourceFileOfNode(node)
    end
    if lastDecorator == nil then
        return format.withTokenStart(node, file):Pos()
    end
    return scanner.SkipTrivia(file:Text(), lastDecorator:End())
end

function formatSpanWorker:execute(s)
    self.formattingScanner = s
    self.indentationOnLastIndentedLine = -1
    self.lastIndentedLine = -1
    local opt = format.GetFormatCodeSettingsFromContext(self.ctx)
    self.formattingContext = format.NewFormattingContext(self.sourceFile, self.requestKind, opt)
    -- formatting context is used by rules provider
    self.visitor = ast.NewNodeVisitor(function(child)
        if child == nil then
            return child
        end
        self:processChildNode(self.visitingNode, self.visitingIndenter, self.visitingNodeStartLine,
            self.visitingUndecoratedNodeStartLine, child, -1, self.visitingNode, self.visitingIndenter,
            self.visitingNodeStartLine, self.visitingUndecoratedNodeStartLine, false, false)
        return child
    end, ast.NewNodeFactory({}), {
        visitNodes = function(nodes, _)
            if nodes == nil then
                return nodes
            end
            self:processChildNodes(self.visitingNode, self.visitingIndenter, self.visitingNodeStartLine,
                self.visitingUndecoratedNodeStartLine, nodes, self.visitingNode, self.visitingNodeStartLine,
                self.visitingIndenter)
            return nodes
        end,
    })

    self.formattingScanner:advance()

    if self.formattingScanner:isOnToken() then
        local startLine = scanner.GetECMALineOfPosition(self.sourceFile,
            format.withTokenStart(self.enclosingNode, self.sourceFile):Pos())
        local undecoratedStartLine = startLine
        if ast.HasDecorators(self.enclosingNode) then
            undecoratedStartLine = scanner.GetECMALineOfPosition(self.sourceFile,
                format.getNonDecoratorTokenPosOfNode(self.enclosingNode, self.sourceFile))
        end

        self:processNode(self.enclosingNode, self.enclosingNode, startLine, undecoratedStartLine,
            self.initialIndentation, self.delta)
    end

    -- Leading trivia items get attached to and processed with the token that proceeds them. If the
    -- range ends in the middle of some leading trivia, the token that proceeds them won't be in the
    -- range and thus won't get processed. So we process those remaining trivia items here.
    local remainingTrivia = self.formattingScanner:getCurrentLeadingTrivia()
    if core.Len(remainingTrivia) > 0 then
        local indentation = self.initialIndentation
        if format.NodeWillIndentChild(self.formattingContext.options, self.enclosingNode, nil, self.sourceFile, false) then
            indentation = indentation + opt.indentSize -- !!! TODO: nil check???
        end

        self:indentTriviaItems(remainingTrivia, indentation, true, function(item)
            local startLine, startChar = scanner.GetECMALineAndByteOffsetOfPosition(self.sourceFile, item.loc:Pos())
            self:processRange(item, startLine, startChar, self.enclosingNode, self.enclosingNode, nil)
            self:insertIndentation(item.loc:Pos(), indentation, false)
        end)

        if core.Tristate_IsTrue(opt.trimTrailingWhitespace) then
            self:trimTrailingWhitespacesForRemainingRange(remainingTrivia)
        end
    end

    if not isZeroRangeWithKind(self.previousRange) and
        self.formattingScanner:getTokenFullStart() >= self.originalRange:End() then
        -- Formatting edits happen by looking at pairs of contiguous tokens (see `processPair`),
        -- typically inserting or deleting whitespace between them. The recursive `processNode`
        -- logic above bails out as soon as it encounters a token that is beyond the end of the
        -- range we're supposed to format (or if we reach the end of the file). But this potentially
        -- leaves out an edit that would occur *inside* the requested range but cannot be discovered
        -- without looking at one token *beyond* the end of the range: consider the line `x = { }`
        -- with a selection from the beginning of the line to the space inside the curly braces,
        -- inclusive. We would expect a format-selection would delete the space (if rules apply),
        -- but in order to do that, we need to process the pair ["{", "}"], but we stopped processing
        -- just before getting there. This block handles this trailing edit.
        local tokenInfo = zeroRangeWithKind
        if self.formattingScanner:isOnEOF() then
            tokenInfo = self.formattingScanner:readEOFTokenRange()
        elseif self.formattingScanner:isOnToken() then
            tokenInfo = self.formattingScanner:readTokenInfo(self.enclosingNode).token
        end

        if tokenInfo.loc:Pos() == self.previousRangeTriviaEnd then
            -- We need to check that tokenInfo and previousRange are contiguous: the `originalRange`
            -- may have ended in the middle of a token, which means we will have stopped formatting
            -- on that token, leaving `previousRange` pointing to the token before it, but already
            -- having moved the formatting scanner (where we just got `tokenInfo`) to the next token.
            -- If this happens, our supposed pair [previousRange, tokenInfo] actually straddles the
            -- token that intersects the end of the range we're supposed to format, so the pair will
            -- produce bogus edits if we try to `processPair`. Recall that the point of this logic is
            -- to perform a trailing edit at the end of the selection range: but there can be no valid
            -- edit in the middle of a token where the range ended, so if we have a non-contiguous
            -- pair here, we're already done and we can ignore it.
            local parent = astnav.FindPrecedingToken(self.sourceFile, tokenInfo.loc:End())
            if parent ~= nil then
                parent = parent.parent
            end
            if parent == nil then
                parent = self.previousParent
            end
            local line = scanner.GetECMALineOfPosition(self.sourceFile, tokenInfo.loc:Pos())
            self:processPair(
                tokenInfo,
                line,
                parent,
                self.previousRange,
                self.previousRangeStartLine,
                self.previousParent,
                parent,
                nil
            )
        end
    end

    return self.edits
end

function formatSpanWorker:processChildNode(node, indenter, nodeStartLine, undecoratedNodeStartLine, child, -- luacheck: ignore 212
                                           inheritedIndentation, parent, parentDynamicIndentation, parentStartLine,
                                           undecoratedParentStartLine, isListItem, isFirstListItem)
    debug.Assert(not ast.NodeIsSynthesized(child))

    if ast.NodeIsMissing(child) or child.flags & NodeFlags.Reparsed ~= 0 then
        return inheritedIndentation
    end
    local childStartPos = scanner.GetTokenPosOfNode(child, self.sourceFile, false)
    local childStartLine = scanner.GetECMALineOfPosition(self.sourceFile, childStartPos)

    local undecoratedChildStartLine = childStartLine
    if ast.HasDecorators(child) then
        undecoratedChildStartLine = scanner.GetECMALineOfPosition(self.sourceFile,
            format.getNonDecoratorTokenPosOfNode(child, self.sourceFile))
    end

    local isErrorMemberListElement = child.flags & NodeFlags.ThisNodeHasError ~= 0 and
        format.isMemberListElement(parent, child)
    -- if child is a list item - try to get its indentation, only if parent is within the original range.
    local childIndentationAmount = -1

    if not isErrorMemberListElement and isListItem and parent.loc:ContainedBy(self.originalRange) then
        childIndentationAmount = self:tryComputeIndentationForListItem(childStartPos, child:End(), parentStartLine,
            self.originalRange, inheritedIndentation)
        if childIndentationAmount ~= -1 then
            inheritedIndentation = childIndentationAmount
        end
    end

    -- child node is outside the target range - do not dive inside
    if not self.originalRange:Overlaps(child.loc) then
        if child:End() < self.originalRange:Pos() then
            self.formattingScanner:skipToEndOf(child.loc)
        end
        return inheritedIndentation
    end

    if child.loc:Len() == 0 then
        return inheritedIndentation
    end

    while self.formattingScanner:isOnToken() and self.formattingScanner:getTokenFullStart() < self.originalRange:End() do
        -- proceed any parent tokens that are located prior to child.getStart()
        local tokenInfo = self.formattingScanner:readTokenInfo(node)
        if tokenInfo.token.loc:End() > self.originalRange:End() then
            return inheritedIndentation
        end
        if tokenInfo.token.loc:End() > childStartPos then
            if tokenInfo.token.loc:Pos() > childStartPos then
                self.formattingScanner:skipToStartOf(child.loc)
            end
            -- stop when formatting scanner advances past the beginning of the child
            break
        end

        self:consumeTokenAndAdvanceScanner(tokenInfo, node, parentDynamicIndentation, node, false)
    end

    if not self.formattingScanner:isOnToken() or self.formattingScanner:getTokenFullStart() >= self.originalRange:End() then
        return inheritedIndentation
    end

    if ast.IsTokenKind(child.kind) then
        -- if child node is a token, it does not impact indentation, proceed it using parent indentation scope rules
        local tokenInfo = self.formattingScanner:readTokenInfo(child)
        -- JSX text shouldn't affect indenting
        if child.kind ~= Kind.JsxText then
            debug.Assert(tokenInfo.token.loc:End() == child.loc:End(), "Token end is child end")
            self:consumeTokenAndAdvanceScanner(tokenInfo, node, parentDynamicIndentation, child, false)
            return inheritedIndentation
        end
    end

    local effectiveParentStartLine = undecoratedParentStartLine
    if child.kind == Kind.Decorator then
        effectiveParentStartLine = childStartLine
    end
    local childIndentation = 0
    local delta = 0
    if isErrorMemberListElement then
        childIndentation = self:getCurrentIndentationAtPosition(childStartPos)
    else
        childIndentation, delta = self:computeIndentation(child, childStartLine, childIndentationAmount, node,
            parentDynamicIndentation, effectiveParentStartLine)
    end

    self:processNode(child, self.childContextNode, childStartLine, undecoratedChildStartLine, childIndentation, delta)

    self.childContextNode = node

    if isFirstListItem and parent.kind == Kind.ArrayLiteralExpression and inheritedIndentation == -1 then
        inheritedIndentation = childIndentation
    end

    return inheritedIndentation
end

function formatSpanWorker:processChildNodes(node, indenter, nodeStartLine, undecoratedNodeStartLine, nodes, parent,
                                            parentStartLine, parentDynamicIndentation)
    debug.Assert(nodes ~= nil)
    debug.Assert(not ast.PositionIsSynthesized(nodes:Pos()))
    debug.Assert(not ast.PositionIsSynthesized(nodes:End()))

    local listStartToken = format.getOpenTokenForList(parent, nodes)

    local listDynamicIndentation = parentDynamicIndentation
    local startLine = parentStartLine

    -- node range is outside the target range - do not dive inside
    if not self.originalRange:Overlaps(nodes.loc) then
        if nodes:End() < self.originalRange:Pos() and
            (core.Len(nodes.nodes) == 0 or nodes.nodes[1].flags & NodeFlags.Reparsed == 0) then
            self.formattingScanner:skipToEndOf(nodes.loc)
        end
        return
    end

    if listStartToken ~= Kind.Unknown then
        -- introduce a new indentation scope for lists (including list start and end tokens)
        while self.formattingScanner:isOnToken() and
            self.formattingScanner:getTokenFullStart() < self.originalRange:End() do
            local tokenInfo = self.formattingScanner:readTokenInfo(parent)
            if tokenInfo.token.loc:End() > nodes:Pos() then
                -- stop when formatting scanner moves past the beginning of node list
                break
            elseif tokenInfo.token.kind == listStartToken then
                -- consume list start token
                startLine = scanner.GetECMALineOfPosition(self.sourceFile, tokenInfo.token.loc:Pos())

                self:consumeTokenAndAdvanceScanner(tokenInfo, parent, parentDynamicIndentation, parent, false)

                local indentationOnListStartToken = 0
                if self.indentationOnLastIndentedLine ~= -1 then
                    -- scanner just processed list start token so consider last indentation as list indentation
                    -- function foo(): { // last indentation was 0, list item will be indented based on this value
                    --   foo: number;
                    -- }: {};
                    indentationOnListStartToken = self.indentationOnLastIndentedLine
                else
                    indentationOnListStartToken = self:getCurrentIndentationAtPosition(tokenInfo.token.loc:Pos())
                end

                listDynamicIndentation = self:getDynamicIndentation(parent, parentStartLine,
                    indentationOnListStartToken, self.formattingContext.options.indentSize)
            else
                -- consume any tokens that precede the list as child elements of 'node' using its indentation scope
                self:consumeTokenAndAdvanceScanner(tokenInfo, parent, parentDynamicIndentation, parent, false)
            end
        end
    end

    local inheritedIndentation = -1
    for i = 0, core.Len(nodes.nodes) - 1 do
        local child = nodes.nodes[i + 1]
        inheritedIndentation = self:processChildNode(node, indenter, nodeStartLine, undecoratedNodeStartLine, child,
            inheritedIndentation, node, listDynamicIndentation, startLine, startLine, true, i == 0)
    end

    local listEndToken = format.getCloseTokenForOpenToken(listStartToken)
    if listEndToken ~= Kind.Unknown and self.formattingScanner:isOnToken() and
        self.formattingScanner:getTokenFullStart() < self.originalRange:End() then
        local tokenInfo = self.formattingScanner:readTokenInfo(parent)
        if tokenInfo.token.kind == Kind.CommaToken then
            -- consume the comma
            self:consumeTokenAndAdvanceScanner(tokenInfo, parent, listDynamicIndentation, parent, false)
            if self.formattingScanner:isOnToken() then
                tokenInfo = self.formattingScanner:readTokenInfo(parent)
            else
                return
            end
        end

        -- consume the list end token only if it is still belong to the parent
        -- there might be the case when current token matches end token but does not considered as one
        -- function (x: function) <--
        -- without this check close paren will be interpreted as list end token for function expression which is wrong
        if tokenInfo.token.kind == listEndToken and tokenInfo.token.loc:ContainedBy(parent.loc) then
            -- consume list end token
            self:consumeTokenAndAdvanceScanner(tokenInfo, parent, listDynamicIndentation, parent,
                true --[[isListEndToken]])
        end
    end
end

function formatSpanWorker:executeProcessNodeVisitor(node, indenter, nodeStartLine, undecoratedNodeStartLine)
    local oldNode = self.visitingNode
    local oldIndenter = self.visitingIndenter
    local oldStart = self.visitingNodeStartLine
    local oldUndecoratedStart = self.visitingUndecoratedNodeStartLine
    self.visitingNode = node
    self.visitingIndenter = indenter
    self.visitingNodeStartLine = nodeStartLine
    self.visitingUndecoratedNodeStartLine = undecoratedNodeStartLine
    node:VisitEachChild(self.visitor)
    self.visitingNode = oldNode
    self.visitingIndenter = oldIndenter
    self.visitingNodeStartLine = oldStart
    self.visitingUndecoratedNodeStartLine = oldUndecoratedStart
end

function formatSpanWorker:getCurrentIndentationAtPosition(pos)
    local startLinePosition = format.GetLineStartPositionForPosition(pos, self.sourceFile)
    return format.FindFirstNonWhitespaceColumn(startLinePosition, pos, self.sourceFile, self.formattingContext.options)
end

-- Returns indentation, delta.
function formatSpanWorker:computeIndentation(node, startLine, inheritedIndentation, parent, parentDynamicIndentation,
                                             effectiveParentStartLine)
    local delta = 0
    if format.ShouldIndentChildNode(self.formattingContext.options, node, nil, nil) then
        delta = self.formattingContext.options.indentSize
    end

    if effectiveParentStartLine == startLine then
        -- if node is located on the same line with the parent
        -- - inherit indentation from the parent
        -- - push children if either parent of node itself has non-zero delta
        local indentation = self.indentationOnLastIndentedLine
        if startLine ~= self.lastIndentedLine then
            indentation = parentDynamicIndentation:getIndentation()
        end
        delta = math.min(self.formattingContext.options.indentSize, parentDynamicIndentation:getDelta(node) + delta)
        return indentation, delta
    elseif inheritedIndentation == -1 then
        if node.kind == Kind.OpenParenToken and startLine == self.lastIndentedLine then
            -- the is used for chaining methods formatting
            -- - we need to get the indentation on last line and the delta of parent
            return self.indentationOnLastIndentedLine, parentDynamicIndentation:getDelta(node)
        elseif format.childStartsOnTheSameLineWithElseInIfStatement(parent, node, startLine, self.sourceFile) or
            format.childIsUnindentedBranchOfConditionalExpression(parent, node, startLine, self.sourceFile) or
            format.argumentStartsOnSameLineAsPreviousArgument(parent, node, startLine, self.sourceFile) then
            return parentDynamicIndentation:getIndentation(), delta
        else
            local i = parentDynamicIndentation:getIndentation()
            if i == -1 then
                return parentDynamicIndentation:getIndentation(), delta
            end
            return i + parentDynamicIndentation:getDelta(node), delta
        end
    end

    return inheritedIndentation, delta
end

--[[* Tries to compute the indentation for a list element.
* If list element is not in range then
* function will pick its actual indentation
* so it can be pushed downstream as inherited indentation.
* If list element is in the range - its indentation will be equal
* to inherited indentation from its predecessors.
 ]]
function formatSpanWorker:tryComputeIndentationForListItem(startPos, endPos, parentStartLine, r, inheritedIndentation)
    local r2 = core.NewTextRange(startPos, endPos)
    if r:Overlaps(r2) or r2:ContainedBy(r) then --[[ Not to miss zero-range nodes e.g. JsxText ]]
        if inheritedIndentation ~= -1 then
            return inheritedIndentation
        end
    else
        local startLine = scanner.GetECMALineOfPosition(self.sourceFile, startPos)
        local column = self:getCurrentIndentationAtPosition(startPos)
        if startLine ~= parentStartLine or startPos == column then
            -- Use the base indent size if it is greater than
            -- the indentation of the inherited predecessor.
            local baseIndentSize = self.formattingContext.options.baseIndentSize
            if baseIndentSize > column then
                return baseIndentSize
            end
            return column
        end
    end
    return -1
end

function formatSpanWorker:processNode(node, contextNode, nodeStartLine, undecoratedNodeStartLine, indentation, delta)
    if not self.originalRange:Overlaps(format.withTokenStart(node, self.sourceFile)) then
        return
    end

    local nodeDynamicIndentation = self:getDynamicIndentation(node, nodeStartLine, indentation, delta)

    -- a useful observations when tracking context node
    --        /
    --      [a]
    --   /   |   \
    --  [b] [c] [d]
    -- node 'a' is a context node for nodes 'b', 'c', 'd'
    -- except for the leftmost leaf token in [b] - in this case context node ('e') is located somewhere above 'a'
    -- this rule can be applied recursively to child nodes of 'a'.
    --
    -- context node is set to parent node value after processing every child node
    -- context node is set to parent of the token after processing every token

    self.childContextNode = contextNode

    -- if there are any tokens that logically belong to node and interleave child nodes
    -- such tokens will be consumed in processChildNode for the child that follows them
    self:executeProcessNodeVisitor(node, nodeDynamicIndentation, nodeStartLine, undecoratedNodeStartLine)

    -- proceed any tokens in the node that are located after child nodes
    while self.formattingScanner:isOnToken() and self.formattingScanner:getTokenFullStart() < self.originalRange:End() do
        local tokenInfo = self.formattingScanner:readTokenInfo(node)
        if tokenInfo.token.loc:End() > math.min(node:End(), self.originalRange:End()) then
            break
        end
        self:consumeTokenAndAdvanceScanner(tokenInfo, node, nodeDynamicIndentation, node, false)
    end
end

function formatSpanWorker:processPair(currentItem, currentStartLine, currentParent, previousItem, previousStartLine,
                                      previousParent, contextNode, dynamicIndentation)
    self.formattingContext:UpdateContext(previousItem, previousParent, currentItem, currentParent, contextNode)

    self.currentRules = {}
    self.currentRules = format.getRules(self.formattingContext, self.currentRules)

    local trimTrailingWhitespaces = not core.Tristate_IsFalse(self.formattingContext.options.trimTrailingWhitespace)
    local lineAction = LineAction.None

    if #self.currentRules > 0 then
        -- Apply rules in reverse order so that higher priority rules (which are first in the array)
        -- win in a conflict with lower priority rules.
        for i = #self.currentRules - 1, 0, -1 do
            local rule = self.currentRules[i + 1]
            lineAction = self:applyRuleEdits(rule, previousItem, previousStartLine, currentItem, currentStartLine)
            if dynamicIndentation ~= nil then
                if lineAction == LineAction.LineRemoved then
                    -- Handle the case where the next line is moved to be the end of this line.
                    -- In this case we don't indent the next line in the next pass.
                    if scanner.GetTokenPosOfNode(currentParent, self.sourceFile, false) == currentItem.loc:Pos() then
                        dynamicIndentation:recomputeIndentation(false --[[lineAddedByFormatting]], contextNode)
                    end
                elseif lineAction == LineAction.LineAdded then
                    -- Handle the case where token2 is moved to the new line.
                    -- In this case we indent token2 in the next pass but we set
                    -- sameLineIndent flag to notify the indenter that the indentation is within the line.
                    if scanner.GetTokenPosOfNode(currentParent, self.sourceFile, false) == currentItem.loc:Pos() then
                        dynamicIndentation:recomputeIndentation(true --[[lineAddedByFormatting]], contextNode)
                    end
                else
                    debug.Assert(lineAction == LineAction.None)
                end
            end

            -- We need to trim trailing whitespace between the tokens if they were on different lines, and no rule was applied to put them on the same line
            trimTrailingWhitespaces = trimTrailingWhitespaces and (rule:Action() & ruleAction.DeleteSpace == 0) and
                rule:Flags() ~= ruleFlags.CanDeleteNewLines
        end
    else
        trimTrailingWhitespaces = trimTrailingWhitespaces and currentItem.kind ~= Kind.EndOfFile
    end

    if currentStartLine ~= previousStartLine and trimTrailingWhitespaces then
        -- We need to trim trailing whitespace between the tokens if they were on different lines, and no rule was applied to put them on the same line
        self:trimTrailingWhitespacesForLines(previousStartLine, currentStartLine, previousItem)
    end

    return lineAction
end

function formatSpanWorker:applyRuleEdits(rule, previousRange, previousStartLine, currentRange, currentStartLine)
    local onLaterLine = currentStartLine ~= previousStartLine
    local action = rule:Action()
    if action == ruleAction.StopProcessingSpaceActions then
        -- no action required
        return LineAction.None
    elseif action == ruleAction.DeleteSpace then
        if previousRange.loc:End() ~= currentRange.loc:Pos() then
            -- delete characters starting from t1.end up to t2.pos exclusive
            self:recordDelete(previousRange.loc:End(), currentRange.loc:Pos() - previousRange.loc:End())
            if onLaterLine then
                return LineAction.LineRemoved
            end
            return LineAction.None
        end
    elseif action == ruleAction.DeleteToken then
        self:recordDelete(previousRange.loc:Pos(), previousRange.loc:Len())
    elseif action == ruleAction.InsertNewLine then
        -- exit early if we on different lines and rule cannot change number of newlines
        -- if line1 and line2 are on subsequent lines then no edits are required - ok to exit
        -- if line1 and line2 are separated with more than one newline - ok to exit since we cannot delete extra new lines
        if rule:Flags() ~= ruleFlags.CanDeleteNewLines and previousStartLine ~= currentStartLine then
            return LineAction.None
        end

        -- edit should not be applied if we have one line feed between elements
        local lineDelta = currentStartLine - previousStartLine
        if lineDelta ~= 1 then
            self:recordReplace(previousRange.loc:End(), currentRange.loc:Pos() - previousRange.loc:End(),
                format.GetNewLineOrDefaultFromContext(self.ctx))
            if onLaterLine then
                return LineAction.None
            end
            return LineAction.LineAdded
        end
    elseif action == ruleAction.InsertSpace then
        -- exit early if we on different lines and rule cannot change number of newlines
        if rule:Flags() ~= ruleFlags.CanDeleteNewLines and previousStartLine ~= currentStartLine then
            return LineAction.None
        end

        local posDelta = currentRange.loc:Pos() - previousRange.loc:End()
        if posDelta ~= 1 or string.byte(self.sourceFile:Text(), previousRange.loc:End() + 1) ~= 32 then
            self:recordReplace(previousRange.loc:End(), posDelta, " ")
            if onLaterLine then
                return LineAction.LineRemoved
            end
            return LineAction.None
        end
    elseif action == ruleAction.InsertTrailingSemicolon then
        self:recordInsert(previousRange.loc:End(), ";")
    end
    return LineAction.None
end

function formatSpanWorker:processRange(r, rangeStartLine, rangeStartCharacter, parent, contextNode, dynamicIndentation) -- luacheck: ignore 212
    local rangeHasError = self.rangeContainsError(r.loc)
    local lineAction = LineAction.None
    if not rangeHasError then
        if isZeroRangeWithKind(self.previousRange) then
            -- trim whitespaces starting from the beginning of the span up to the current line
            local originalStartLine = scanner.GetECMALineOfPosition(self.sourceFile, self.originalRange:Pos())
            self:trimTrailingWhitespacesForLines(originalStartLine, rangeStartLine, zeroRangeWithKind)
        else
            lineAction = self:processPair(r, rangeStartLine, parent, self.previousRange, self.previousRangeStartLine,
                self.previousParent, contextNode, dynamicIndentation)
        end
    end

    self.previousRange = r
    self.previousRangeTriviaEnd = r.loc:End()
    self.previousParent = parent
    self.previousRangeStartLine = rangeStartLine

    return lineAction
end

function formatSpanWorker:processTrivia(trivia, parent, contextNode, dynamicIndentation)
    for _, triviaItem in ipairs(trivia or {}) do
        if format.isComment(triviaItem.kind) and triviaItem.loc:ContainedBy(self.originalRange) then
            local triviaItemStartLine, triviaItemStartCharacter = scanner.GetECMALineAndByteOffsetOfPosition(
                self.sourceFile, triviaItem.loc:Pos())
            self:processRange(triviaItem, triviaItemStartLine, triviaItemStartCharacter, parent, contextNode,
                dynamicIndentation)
        end
    end
end

--[[*
* Trimming will be done for lines after the previous range.
* Exclude comments as they had been previously processed.
 ]]
function formatSpanWorker:trimTrailingWhitespacesForRemainingRange(trivias)
    local startPos = self.originalRange:Pos()
    if not isZeroRangeWithKind(self.previousRange) then
        startPos = self.previousRange.loc:End()
    end

    for _, trivia in ipairs(trivias or {}) do
        if format.isComment(trivia.kind) then
            if startPos < trivia.loc:Pos() then
                self:trimTrailingWitespacesForPositions(startPos, trivia.loc:Pos() - 1, self.previousRange)
            end

            startPos = trivia.loc:End() + 1
        end
    end

    if startPos < self.originalRange:End() then
        self:trimTrailingWitespacesForPositions(startPos, self.originalRange:End(), self.previousRange)
    end
end

function formatSpanWorker:trimTrailingWitespacesForPositions(startPos, endPos, previousRange)
    local startLine = scanner.GetECMALineOfPosition(self.sourceFile, startPos)
    local endLine = scanner.GetECMALineOfPosition(self.sourceFile, endPos)

    self:trimTrailingWhitespacesForLines(startLine, endLine + 1, previousRange)
end

function formatSpanWorker:trimTrailingWhitespacesForLines(line1, line2, r)
    local lineStarts = scanner.GetECMALineStarts(self.sourceFile)
    for line = line1, line2 - 1 do
        local lineStartPosition = lineStarts[line + 1]
        local lineEndPosition = scanner.GetECMAEndLinePosition(self.sourceFile, line)

        -- do not trim whitespaces in comments or template expression
        if not isZeroRangeWithKind(r) and
            (format.isComment(r.kind) or format.isStringOrRegularExpressionOrTemplateLiteral(r.kind)) and
            r.loc:Pos() <= lineEndPosition and r.loc:End() > lineEndPosition then
            goto continue
        end

        do
            local whitespaceStart = self:getTrailingWhitespaceStartPosition(lineStartPosition, lineEndPosition)
            if whitespaceStart ~= -1 then
                if whitespaceStart ~= lineStartPosition then
                    local ch = stringutil.DecodeRune(self.sourceFile:Text(), whitespaceStart - 1)
                    debug.Assert(not stringutil.IsWhiteSpaceSingleLine(ch))
                end
                self:recordDelete(whitespaceStart, lineEndPosition + 1 - whitespaceStart)
            end
        end
        ::continue::
    end
end

--[[*
* @param start The position of the first character in range
* @param end The position of the last character in range
 ]]
function formatSpanWorker:getTrailingWhitespaceStartPosition(start, end_)
    local pos = end_
    local text = self.sourceFile:Text()
    while pos >= start do
        local ch, size = stringutil.DecodeRune(text, pos)
        if size == 0 then
            pos = pos - 1 -- multibyte character, rewind more
            goto continue
        end
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end
        pos = pos - 1
        ::continue::
    end
    if pos ~= end_ then
        return pos + 1
    end
    return -1
end

function format.isStringOrRegularExpressionOrTemplateLiteral(kind)
    return kind == Kind.StringLiteral or kind == Kind.RegularExpressionLiteral or ast.IsTemplateLiteralKind(kind)
end

function format.isComment(kind)
    return kind == Kind.SingleLineCommentTrivia or kind == Kind.MultiLineCommentTrivia
end

function formatSpanWorker:insertIndentation(pos, indentation, lineAdded)
    local indentationString = format.getIndentationString(indentation, self.formattingContext.options)
    if lineAdded then
        -- new line is added before the token by the formatting rules
        -- insert indentation string at the very beginning of the token
        self:recordReplace(pos, 0, indentationString)
    else
        local tokenStartLine, tokenStartCharacter = scanner.GetECMALineAndByteOffsetOfPosition(self.sourceFile, pos)
        local startLinePosition = scanner.GetECMALineStarts(self.sourceFile)[tokenStartLine + 1]
        if indentation ~= self:characterToColumn(startLinePosition, tokenStartCharacter) or
            self:indentationIsDifferent(indentationString, startLinePosition) then
            self:recordReplace(startLinePosition, tokenStartCharacter, indentationString)
        end
    end
end

function formatSpanWorker:characterToColumn(startLinePosition, characterInLine)
    local column = 0
    local text = self.sourceFile:Text()
    for i = 0, characterInLine - 1 do
        if string.byte(text, startLinePosition + i + 1) == 9 then -- '\t'
            if self.formattingContext.options.tabSize > 0 then
                column = column + self.formattingContext.options.tabSize -
                    (column % self.formattingContext.options.tabSize)
            end
        else
            column = column + 1
        end
    end
    return column
end

function formatSpanWorker:indentationIsDifferent(indentationString, startLinePosition)
    local text = self.sourceFile:Text()
    local end_ = startLinePosition + #indentationString
    if end_ > #text then
        return true
    end
    return indentationString ~= string.sub(text, startLinePosition + 1, end_)
end

function formatSpanWorker:indentTriviaItems(trivia, commentIndentation, indentNextTokenOrTrivia, indentSingleLine)
    for _, triviaItem in ipairs(trivia or {}) do
        local triviaInRange = triviaItem.loc:ContainedBy(self.originalRange)
        if triviaItem.kind == Kind.MultiLineCommentTrivia then
            if triviaInRange then
                self:indentMultilineComment(triviaItem.loc, commentIndentation, not indentNextTokenOrTrivia, true)
            end
            indentNextTokenOrTrivia = false
        elseif triviaItem.kind == Kind.SingleLineCommentTrivia then
            if indentNextTokenOrTrivia and triviaInRange then
                indentSingleLine(triviaItem)
            end
            indentNextTokenOrTrivia = false
        elseif triviaItem.kind == Kind.NewLineTrivia then
            indentNextTokenOrTrivia = true
        end
    end
    return indentNextTokenOrTrivia
end

function formatSpanWorker:indentMultilineComment(commentRange, indentation, firstLineIsIndented, indentFinalLine)
    -- split comment in lines
    local startLine = scanner.GetECMALineOfPosition(self.sourceFile, commentRange:Pos())
    local endLine = scanner.GetECMALineOfPosition(self.sourceFile, commentRange:End())

    if startLine == endLine then
        if not firstLineIsIndented then
            -- treat as single line comment
            self:insertIndentation(commentRange:Pos(), indentation, false)
        end
        return
    end

    local parts = {}
    local startPos = commentRange:Pos()
    for line = startLine, endLine - 1 do
        local endOfLine = scanner.GetECMAEndLinePosition(self.sourceFile, line)
        parts[#parts + 1] = core.NewTextRange(startPos, endOfLine)
        startPos = scanner.GetECMALineStarts(self.sourceFile)[line + 2]
    end

    if indentFinalLine then
        parts[#parts + 1] = core.NewTextRange(startPos, commentRange:End())
    end

    if #parts == 0 then
        return
    end

    local startLinePos = scanner.GetECMALineStarts(self.sourceFile)[startLine + 1]

    local nonWhitespaceInFirstPartCharacter, nonWhitespaceInFirstPartColumn = format.findFirstNonWhitespaceCharacterAndColumn(
        startLinePos, parts[1]:Pos(), self.sourceFile, self.formattingContext.options)

    local startIndex = 0

    if firstLineIsIndented then
        startIndex = 1
        startLine = startLine + 1
    end

    -- shift all parts on the delta size
    local delta = indentation - nonWhitespaceInFirstPartColumn
    for i = startIndex, #parts - 1 do
        local startLinePos_ = scanner.GetECMALineStarts(self.sourceFile)[startLine + 1]
        local nonWhitespaceCharacter = nonWhitespaceInFirstPartCharacter
        local nonWhitespaceColumn = nonWhitespaceInFirstPartColumn
        if i ~= 0 then
            nonWhitespaceCharacter, nonWhitespaceColumn = format.findFirstNonWhitespaceCharacterAndColumn(
                parts[i + 1]:Pos(), parts[i + 1]:End(), self.sourceFile, self.formattingContext.options)
        end
        local newIndentation = nonWhitespaceColumn + delta
        if newIndentation > 0 then
            local indentationString = format.getIndentationString(newIndentation, self.formattingContext.options)
            self:recordReplace(startLinePos_, nonWhitespaceCharacter, indentationString)
        else
            self:recordDelete(startLinePos_, nonWhitespaceCharacter)
        end

        startLine = startLine + 1
    end
end

function format.getIndentationString(indentation, options)
    -- go's `strings.Repeat` already has static, global caching for repeated tabs and spaces, so there's no need to cache here like in strada
    if not core.Tristate_IsTrue(options.convertTabsToSpaces) then
        if options.tabSize == 0 then
            return ""
        end
        local tabs = indentation // options.tabSize -- math.Floor(float64(indentation) / float64(options.TabSize))
        local spaces = indentation - (tabs * options.tabSize)
        local res = stringsRepeat("\t", tabs)
        if spaces > 0 then
            res = res .. stringsRepeat(" ", spaces)
        end

        return res
    else
        return stringsRepeat(" ", indentation)
    end
end

function format.createTextChangeFromStartLength(start, length, newText)
    return core.NewTextChange(core.NewTextRange(start, start + length), newText)
end

function formatSpanWorker:recordDelete(start, length)
    if length ~= 0 then
        self.edits = core.Append(self.edits, format.createTextChangeFromStartLength(start, length, ""))
    end
end

function formatSpanWorker:recordReplace(start, length, newText)
    if length ~= 0 or newText ~= "" then
        self.edits = core.Append(self.edits, format.createTextChangeFromStartLength(start, length, newText))
    end
end

function formatSpanWorker:recordInsert(start, text)
    if text ~= "" then
        self.edits = core.Append(self.edits, format.createTextChangeFromStartLength(start, 0, text))
    end
end

function formatSpanWorker:consumeTokenAndAdvanceScanner(currentTokenInfo, parent, dynamicIndenation, container,
                                                        isListEndToken)
    -- assert(currentTokenInfo.token.Loc.ContainedBy(parent.Loc)) // !!!
    local lastTriviaWasNewLine = self.formattingScanner:lastTrailingTriviaWasNewLine()
    local indentToken = false

    if core.Len(currentTokenInfo.leadingTrivia) > 0 then
        self:processTrivia(currentTokenInfo.leadingTrivia, parent, self.childContextNode, dynamicIndenation)
    end

    local lineAction = LineAction.None
    local isTokenInRange = currentTokenInfo.token.loc:ContainedBy(self.originalRange)

    local tokenStartLine, tokenStartChar = scanner.GetECMALineAndByteOffsetOfPosition(self.sourceFile,
        currentTokenInfo.token.loc:Pos())

    if isTokenInRange then
        local rangeHasError = self.rangeContainsError(currentTokenInfo.token.loc)
        -- save previousRange since processRange will overwrite this value with current one
        local savePreviousRange = self.previousRange
        lineAction = self:processRange(currentTokenInfo.token, tokenStartLine, tokenStartChar, parent,
            self.childContextNode, dynamicIndenation)
        -- do not indent comments\token if token range overlaps with some error
        if not rangeHasError then
            if lineAction == LineAction.None then
                -- indent token only if end line of previous range does not match start line of the token
                if not isZeroRangeWithKind(savePreviousRange) then
                    local prevEndLine = scanner.GetECMALineOfPosition(self.sourceFile, savePreviousRange.loc:End())
                    indentToken = lastTriviaWasNewLine and tokenStartLine ~= prevEndLine
                else
                    -- When there's no previous range (first token), TS sets prevEndLine to undefined.
                    -- tokenStart.line !== undefined is always true in JS, so indentToken = lastTriviaWasNewLine.
                    indentToken = lastTriviaWasNewLine
                end
            else
                indentToken = lineAction == LineAction.LineAdded
            end
        end
    end

    if core.Len(currentTokenInfo.trailingTrivia) > 0 then
        self.previousRangeTriviaEnd = core.LastOrNil(currentTokenInfo.trailingTrivia).loc:End()
        -- If any trailing comment trivia extends past the original range, it won't be
        -- processed by processTrivia (which skips comments not contained by originalRange).
        -- Cap previousRangeTriviaEnd before such comments so the trailing edit contiguity
        -- check in execute() won't pair across unprocessed comment content.
        for _, trivia in ipairs(currentTokenInfo.trailingTrivia) do
            if format.isComment(trivia.kind) and not trivia.loc:ContainedBy(self.originalRange) then
                self.previousRangeTriviaEnd = trivia.loc:Pos()
                break
            end
        end
        self:processTrivia(currentTokenInfo.trailingTrivia, parent, self.childContextNode, dynamicIndenation)
    end

    if indentToken then
        local tokenIndentation = -1
        if isTokenInRange and not self.rangeContainsError(currentTokenInfo.token.loc) then
            tokenIndentation = dynamicIndenation:getIndentationForToken(tokenStartLine, currentTokenInfo.token.kind,
                container, not not isListEndToken)
        end
        local indentNextTokenOrTrivia = true
        if core.Len(currentTokenInfo.leadingTrivia) > 0 then
            local commentIndentation = dynamicIndenation:getIndentationForComment(currentTokenInfo.token.kind,
                tokenIndentation, container)
            indentNextTokenOrTrivia = self:indentTriviaItems(currentTokenInfo.leadingTrivia, commentIndentation,
                indentNextTokenOrTrivia, function(item)
                    self:insertIndentation(item.loc:Pos(), commentIndentation, false)
                end)
        end

        -- indent token only if is it is in target range and does not overlap with any error ranges
        if tokenIndentation ~= -1 and indentNextTokenOrTrivia then
            self:insertIndentation(currentTokenInfo.token.loc:Pos(), tokenIndentation, lineAction == LineAction.LineAdded)

            self.lastIndentedLine = tokenStartLine
            self.indentationOnLastIndentedLine = tokenIndentation
        end
    end

    self.formattingScanner:advance()

    self.childContextNode = parent
end

local dynamicIndenter = {}
dynamicIndenter.__index = dynamicIndenter
format.dynamicIndenter = dynamicIndenter

function dynamicIndenter:getIndentationForComment(kind, tokenIndentation, container)
    -- preceding comment to the token that closes the indentation scope inherits the indentation from the scope
    -- ..  {
    --     // comment
    -- }
    if kind == Kind.CloseBraceToken or kind == Kind.CloseBracketToken or kind == Kind.CloseParenToken then
        return self.indentation + self:getDelta(container)
    end
    if tokenIndentation ~= -1 then
        return tokenIndentation
    end
    return self.indentation
end

-- if list end token is LessThanToken '>' then its delta should be explicitly suppressed
-- so that LessThanToken as a binary operator can still be indented.
-- foo.then
--
--	<
--	    number,
--	    string,
--	>();
--
-- vs
-- var a = xValue
--
--	> yValue;
function dynamicIndenter:getIndentationForToken(line, kind, container, suppressDelta)
    if not suppressDelta and self:shouldAddDelta(line, kind, container) then
        return self.indentation + self:getDelta(container)
    end
    return self.indentation
end

function dynamicIndenter:getIndentation()
    return self.indentation
end

function dynamicIndenter:getDelta(child)
    -- Delta value should be zero when the node explicitly prevents indentation of the child node
    if format.NodeWillIndentChild(self.options, self.node, child, self.sourceFile, true) then
        return self.delta
    end
    return 0
end

function dynamicIndenter:recomputeIndentation(lineAdded, parent)
    if format.ShouldIndentChildNode(self.options, parent, self.node, self.sourceFile) then
        if lineAdded then
            self.indentation = self.indentation + self.options.indentSize -- !!! no nil check???
        else
            self.indentation = self.indentation - self.options.indentSize -- !!! no nil check???
        end
        if format.ShouldIndentChildNode(self.options, self.node, nil, nil) then
            self.delta = self.options.indentSize
        else
            self.delta = 0
        end
    end
end

function dynamicIndenter:shouldAddDelta(line, kind, container)
    -- open and close brace, 'else' and 'while' (in do statement) tokens has indentation of the parent
    if kind == Kind.OpenBraceToken or kind == Kind.CloseBraceToken or kind == Kind.CloseParenToken or
        kind == Kind.ElseKeyword or kind == Kind.WhileKeyword or kind == Kind.AtToken then
        return false
    elseif kind == Kind.SlashToken or kind == Kind.GreaterThanToken then
        local ck = container.kind
        if ck == Kind.JsxOpeningElement or ck == Kind.JsxClosingElement or ck == Kind.JsxSelfClosingElement then
            return false
        end
    elseif kind == Kind.OpenBracketToken or kind == Kind.CloseBracketToken then
        if container.kind ~= Kind.MappedType then
            return false
        end
    end
    -- if token line equals to the line of containing node (this is a first token in the node) - use node indentation
    return self.nodeStartLine ~= line and
        -- if this token is the first token following the list of decorators, we do not need to indent
        not (ast.HasDecorators(self.node) and kind == format.getFirstNonDecoratorTokenOfNode(self.node))
end

function format.getFirstNonDecoratorTokenOfNode(node)
    if ast.CanHaveModifiers(node) then
        local modifierNodes = node:ModifierNodes()
        local start = core.FindIndex(modifierNodes, ast.IsDecorator)
        if start < 0 then
            error("slice bounds out of range [" .. start .. ":]")
        end
        local modifier = core.Find(core.Slice(modifierNodes, start), ast.IsModifier)
        if modifier ~= nil then
            return modifier.kind
        end
    end

    local k = node.kind
    if k == Kind.ClassDeclaration then
        return Kind.ClassKeyword
    elseif k == Kind.InterfaceDeclaration then
        return Kind.InterfaceKeyword
    elseif k == Kind.FunctionDeclaration then
        return Kind.FunctionKeyword
    elseif k == Kind.EnumDeclaration then
        return Kind.EnumDeclaration
    elseif k == Kind.GetAccessor then
        return Kind.GetKeyword
    elseif k == Kind.SetAccessor then
        return Kind.SetKeyword
    elseif k == Kind.MethodDeclaration or k == Kind.PropertyDeclaration or k == Kind.Parameter then
        if k == Kind.MethodDeclaration and node:AsMethodDeclaration().asteriskToken ~= nil then
            return Kind.AsteriskToken
        end
        -- fallthrough
        local name = ast.GetNameOfDeclaration(node)
        if name ~= nil then
            return name.kind
        end
    end

    return Kind.Unknown
end

function formatSpanWorker:getDynamicIndentation(node, nodeStartLine, indentation, delta)
    return setmetatable({
        node = node,
        nodeStartLine = nodeStartLine,
        indentation = indentation,
        delta = delta,
        options = self.formattingContext.options,
        sourceFile = self.sourceFile,
    }, dynamicIndenter)
end
