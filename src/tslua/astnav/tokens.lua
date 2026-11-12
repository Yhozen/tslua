local astnav = require("tslua.astnav")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

function astnav.shouldRescanLessThanLessThanToken(s, containingNode, token)
    return token == Kind.LessThanLessThanToken and ast.IsJsxChild(containingNode)
end

function astnav.scanNavigationToken(s, containingNode)
    local token = s:Token()
    if astnav.shouldRescanLessThanLessThanToken(s, containingNode, token) then
        return s:ReScanJsxToken(true --[[allowMultilineJsxText]])
    end
    return token
end

function astnav.GetTouchingPropertyName(sourceFile, position)
    return astnav.getTokenAtPosition(sourceFile, position, false --[[allowPositionInLeadingTrivia]], function(node)
        return ast.IsPropertyNameLiteral(node) or ast.IsKeywordKind(node.kind) or ast.IsPrivateIdentifier(node)
    end)
end

function astnav.GetTouchingToken(sourceFile, position)
    return astnav.getTokenAtPosition(sourceFile, position, false --[[allowPositionInLeadingTrivia]], nil)
end

function astnav.GetTokenAtPosition(sourceFile, position)
    return astnav.getTokenAtPosition(sourceFile, position, true --[[allowPositionInLeadingTrivia]], nil)
end

function astnav.getTokenAtPosition(sourceFile, position, allowPositionInLeadingTrivia,
                                   includePrecedingTokenAtEndPosition)
    -- getTokenAtPosition returns a token at the given position in the source file.
    -- The token can be a real node in the AST, or a synthesized token constructed
    -- with information from the scanner. Synthesized tokens are only created when
    -- needed, and they are stored in the source file's token cache such that multiple
    -- calls to getTokenAtPosition with the same position will return the same object
    -- in memory. If there is no token at the given position (possible when
    -- `allowPositionInLeadingTrivia` is false), the lowest node that encloses the
    -- position is returned.

    -- `next` tracks the node whose children will be visited on the next iteration.
    -- `prevSubtree` is a node whose end position is equal to the target position,
    -- only if `includePrecedingTokenAtEndPosition` is provided. Once set, the next
    -- iteration of the loop will test the rightmost token of `prevSubtree` to see
    -- if it should be returned.
    local next_, prevSubtree = nil, nil
    local current = sourceFile:AsNode()
    -- `left` tracks the lower boundary of the node/token that could be returned,
    -- and is eventually the scanner's start position, if the scanner is used.
    local left = 0
    -- `nodeAfterLeft` tracks the first node we visit after visiting the node that advances `left`.
    -- When scanning in between nodes for token, we should only scan up to the start of `nodeAfterLeft`.
    local nodeAfterLeft = nil

    local function getIncludedPrecedingToken(subtree)
        local child = astnav.FindPrecedingTokenEx(sourceFile, position, subtree, false --[[excludeJSDoc]])
        if child ~= nil and child:End() == position and includePrecedingTokenAtEndPosition(child) then
            return child
        end
        return nil
    end

    local function testNode(node)
        if node.kind ~= Kind.EndOfFile and node:End() == position and
            includePrecedingTokenAtEndPosition ~= nil and node.flags & NodeFlags.Reparsed == 0 then
            if prevSubtree ~= nil and getIncludedPrecedingToken(prevSubtree) ~= nil then
                return 0
            end
            prevSubtree = node
        end

        -- A node "contains" the position if position < end, except nodes at the file end
        -- treat end as inclusive (there's nowhere else to look). This applies to the EOF
        -- token itself, and to JSDoc nodes reaching EOF (e.g. unterminated JSDoc comments).
        if node:End() < position or node:End() == position and
            node.kind ~= Kind.EndOfFile and
            (not ast.IsJSDocKind(node.kind) or node:End() ~= sourceFile.endOfFileToken:End()) then
            return -1
        end
        local nodePos = astnav.getPosition(node, sourceFile, allowPositionInLeadingTrivia)
        if nodePos > position then
            return 1
        end
        return 0
    end

    -- We zero in on the node that contains the target position by visiting each
    -- child and JSDoc comment of the current node. Node children are walked in
    -- order, while node lists are binary searched.
    local function visitNode(node, _)
        -- We can't abort visiting children, so once a match is found, we set `next`
        -- and do nothing on subsequent visits.
        if node == nil or node.flags & NodeFlags.Reparsed ~= 0 then
            return nil
        end
        if nodeAfterLeft == nil then
            nodeAfterLeft = node
        end
        if next_ == nil then
            local result = testNode(node)
            if result == -1 then
                if not ast.IsJSDocKind(node.kind) then
                    -- We can't move the left boundary into or beyond JSDoc,
                    -- because we may end up returning the token after this JSDoc,
                    -- constructing it with the scanner, and we need to include
                    -- all its leading trivia in its position.
                    left = node:End()
                end
                nodeAfterLeft = nil
            elseif result == 0 then
                next_ = node
            end
        end
        return node
    end

    local function visitNodeList(nodeList, _)
        if nodeList == nil or core.Len(nodeList.nodes) == 0 then
            return nodeList
        end
        if nodeAfterLeft == nil then
            for _, node in ipairs(nodeList.nodes) do
                if node.flags & NodeFlags.Reparsed == 0 then
                    nodeAfterLeft = node
                    break
                end
            end
        end
        if next_ == nil then
            if nodeList:End() == position and includePrecedingTokenAtEndPosition ~= nil then
                left = nodeList:End()
                nodeAfterLeft = nil
                for i = #nodeList.nodes - 1, 0, -1 do
                    if nodeList.nodes[i + 1].flags & NodeFlags.Reparsed == 0 then
                        prevSubtree = nodeList.nodes[i + 1]
                        break
                    end
                end
            elseif nodeList:End() <= position then
                left = nodeList:End()
                nodeAfterLeft = nil
            elseif nodeList:Pos() <= position then
                local nodes = nodeList.nodes
                local index, match = core.BinarySearchUniqueFunc(nodes, function(middle, node)
                    if node.flags & NodeFlags.Reparsed ~= 0 then
                        return 0
                    end
                    local cmp = testNode(node)
                    if cmp < 0 then
                        left = node:End()
                        nodeAfterLeft = nil
                        for i = middle + 1, #nodes - 1 do
                            if nodes[i + 1].flags & NodeFlags.Reparsed == 0 then
                                nodeAfterLeft = nodes[i + 1]
                                break
                            end
                        end
                    end
                    return cmp
                end)
                if match and nodes[index + 1].flags & NodeFlags.Reparsed ~= 0 then
                    -- filter and search again
                    nodes = core.Filter(nodes, function(node)
                        return node.flags & NodeFlags.Reparsed == 0
                    end)
                    index, match = core.BinarySearchUniqueFunc(nodes, function(middle, node)
                        local cmp = testNode(node)
                        if cmp < 0 then
                            left = node:End()
                            if middle + 1 < #nodes then
                                nodeAfterLeft = nodes[middle + 2]
                            else
                                nodeAfterLeft = nil
                            end
                        end
                        return cmp
                    end)
                end
                if match then
                    next_ = nodes[index + 1]
                end
            end
        end
        return nodeList
    end

    while true do
        astnav.VisitEachChildAndJSDoc(current, sourceFile, visitNode, visitNodeList)
        -- If prevSubtree was set on the last iteration, it ends at the target position.
        -- Check if the rightmost token of prevSubtree should be returned based on the
        -- `includePrecedingTokenAtEndPosition` callback.
        if prevSubtree ~= nil then
            local child = getIncludedPrecedingToken(prevSubtree)
            if child ~= nil then
                -- Optimization: includePrecedingTokenAtEndPosition only ever returns true
                -- for real AST nodes, so we don't run the scanner here.
                return child
            end
            prevSubtree = nil
        end

        -- No node was found that contains the target position, so we've gone as deep as
        -- we can in the AST. We've either found a token, or we need to run the scanner
        -- to construct one that isn't stored in the AST.
        if next_ == nil then
            if ast.IsTokenKind(current.kind) or astnav.shouldSkipChild(current) then
                return current
            end
            local s = scanner.GetScannerForSourceFile(sourceFile, left)
            local end_ = current:End()
            -- We should only scan up to the start of the next node in the AST after the node ending at position `left`.
            -- It is necessary to enforce this invariant in cases where `position` occurs in between two node/tokens,
            -- such that we would not find a token in the loop below before we reach the next node.
            -- We can fall into this case when `allowPositionInLeadingTrivia` is false and `position` is in a leading trivia,
            -- or when `position` would be in the leading trivia of a node but this node is inside JSDoc:
            -- ```
            -- /**
            --  * @type {{
            --  */*$*/ identifier: boolean;
            --  * }}
            --  */
            -- ```
            -- The position of marker '$' falls in between the asterisk token and the identifier token, but is not
            -- part of the leading trivia for `identifier`.
            if nodeAfterLeft ~= nil then
                end_ = nodeAfterLeft:Pos()
            end
            while left < end_ do
                local token = astnav.scanNavigationToken(s, current)
                local tokenFullStart = s:TokenFullStart()
                local tokenStart = core.IfElse(allowPositionInLeadingTrivia, tokenFullStart, s:TokenStart())
                local tokenEnd = s:TokenEnd()
                local flags = s:TokenFlags()
                if tokenEnd > end_ then
                    break
                end
                if tokenStart <= position and (position < tokenEnd) then
                    if token == Kind.Identifier or not ast.IsTokenKind(token) then
                        if ast.IsJSDocKind(current.kind) then
                            return current
                        end
                        error(string.format("did not expect %s to have %s in its trivia", ast.Kind_String(current.kind),
                            ast.Kind_String(token)))
                    end
                    return sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, current, flags)
                end
                if includePrecedingTokenAtEndPosition ~= nil and tokenEnd == position then
                    local prevToken = sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, current, flags)
                    if includePrecedingTokenAtEndPosition(prevToken) then
                        return prevToken
                    end
                end
                left = tokenEnd
                s:Scan()
            end
            return current
        end
        current = next_
        left = current:Pos()
        nodeAfterLeft = nil
        next_ = nil
    end
end

function astnav.getPosition(node, sourceFile, allowPositionInLeadingTrivia)
    if allowPositionInLeadingTrivia then
        return node:Pos()
    end
    return scanner.GetTokenPosOfNode(node, sourceFile, true --[[includeJSDoc]])
end

function astnav.findRightmostNode(node)
    local next_ = nil
    local current = node
    local function visitNode(n, _)
        if n ~= nil then
            next_ = n
        end
        return n
    end
    local function visitNodes(nodeList, _)
        if nodeList ~= nil then
            local rightmost = ast.FindLastVisibleNode(nodeList.nodes)
            if rightmost ~= nil then
                next_ = rightmost
            end
        end
        return nodeList
    end
    local visitor = astnav.getNodeVisitor(visitNode, visitNodes)

    while true do
        current:VisitEachChild(visitor)
        if next_ == nil then
            return current
        end
        current = next_
        next_ = nil
    end
end

function astnav.VisitEachChildAndJSDoc(node, sourceFile, visitNode, visitNodes)
    local visitor = astnav.getNodeVisitor(visitNode, visitNodes)
    for _, jsdoc in ipairs(node:JSDoc(sourceFile) or {}) do
        if visitor.hooks.visitNode ~= nil then
            visitor.hooks.visitNode(jsdoc, visitor)
        else
            visitor:VisitNode(jsdoc)
        end
    end
    node:VisitEachChild(visitor)
end

astnav.comparisonLessThan = -1
astnav.comparisonEqualTo = 0
astnav.comparisonGreaterThan = 1

-- Finds the leftmost token satisfying `position < token.End()`.
-- If the leftmost token satisfying `position < token.End()` is invalid, or if position
-- is in the trivia of that leftmost token,
-- we will find the rightmost valid token with `token.End() <= position`.
function astnav.FindPrecedingToken(sourceFile, position)
    return astnav.FindPrecedingTokenEx(sourceFile, position, nil, false)
end

function astnav.FindPrecedingTokenEx(sourceFile, position, startNode, excludeJSDoc)
    local find
    find = function(n)
        if ast.IsNonWhitespaceToken(n) and n.kind ~= Kind.EndOfFile then
            return n
        end

        -- `foundChild` is the leftmost node that contains the target position.
        -- `prevChild` is the last visited child of the current node.
        local foundChild, prevChild = nil, nil
        local function visitNode(node, _)
            -- skip synthesized nodes (that will exist now because of jsdoc handling)
            if node == nil or node.flags & NodeFlags.Reparsed ~= 0 then
                return node
            end
            if foundChild ~= nil then -- We cannot abort visiting children, so once the desired child is found, we do nothing.
                return node
            end
            if position < node:End() and (prevChild == nil or prevChild:End() <= position) then
                foundChild = node
            else
                prevChild = node
            end
            return node
        end
        local function visitNodes(nodeList, _)
            if foundChild ~= nil then
                return nodeList
            end
            if nodeList ~= nil and core.Len(nodeList.nodes) > 0 then
                local nodes = nodeList.nodes
                local index, match = core.BinarySearchUniqueFunc(nodes, function(middle, _)
                    -- synthetic jsdoc nodes should have jsdocNode.End() <= n.Pos()
                    if nodes[middle + 1].flags & NodeFlags.Reparsed ~= 0 then
                        return astnav.comparisonLessThan
                    end
                    if position < nodes[middle + 1]:End() then
                        if middle == 0 or position >= nodes[middle]:End() then
                            return astnav.comparisonEqualTo
                        end
                        return astnav.comparisonGreaterThan
                    end
                    return astnav.comparisonLessThan
                end)

                if match then
                    foundChild = nodes[index + 1]
                end

                local validLookupIndex = core.IfElse(match, index - 1, #nodes - 1)
                for i = validLookupIndex, 0, -1 do
                    if nodes[i + 1].flags & NodeFlags.Reparsed == 0 then
                        if prevChild == nil then
                            prevChild = nodes[i + 1]
                        end
                    end
                end
            end
            return nodeList
        end
        astnav.VisitEachChildAndJSDoc(n, sourceFile, visitNode, visitNodes)

        if foundChild ~= nil then
            -- Note that the span of a node's tokens is [getStartOfNode(node, ...), node.end).
            -- Given that `position < child.end` and child has constituent tokens, we distinguish these cases:
            -- 1) `position` precedes `child`'s tokens or `child` has no tokens (ie: in a comment or whitespace preceding `child`):
            -- we need to find the last token in a previous child node or child tokens.
            -- 2) `position` is within the same span: we recurse on `child`.
            local start = astnav.GetStartOfNode(foundChild, sourceFile, not excludeJSDoc --[[includeJSDoc]])
            local lookInPreviousChild = start >= position or -- cursor in the leading trivia or preceding tokens
                not astnav.isValidPrecedingNode(foundChild, sourceFile)
            if lookInPreviousChild then
                if position >= foundChild:Pos() then
                    -- Find jsdoc preceding the foundChild.
                    local jsDoc = nil
                    local nodeJSDoc = n:JSDoc(sourceFile)
                    for i = core.Len(nodeJSDoc) - 1, 0, -1 do
                        if nodeJSDoc[i + 1]:Pos() >= foundChild:Pos() then
                            jsDoc = nodeJSDoc[i + 1]
                            break
                        end
                    end
                    if jsDoc ~= nil then
                        if not excludeJSDoc and position < jsDoc:End() then
                            return find(jsDoc)
                        else
                            return astnav.findRightmostValidToken(jsDoc:End(), sourceFile, n, position, excludeJSDoc)
                        end
                    end
                    return astnav.findRightmostValidToken(foundChild:Pos(), sourceFile, n, -1 --[[position]],
                        excludeJSDoc)
                else -- Answer is in tokens between two visited children.
                    return astnav.findRightmostValidToken(foundChild:Pos(), sourceFile, n, position, excludeJSDoc)
                end
            else
                -- position is in [foundChild.getStart(), foundChild.End): recur.
                return find(foundChild)
            end
        end

        -- We have two cases here: either the position is at the end of the file,
        -- or the desired token is in the unvisited trailing tokens of the current node.
        if position >= n:End() then
            return astnav.findRightmostValidToken(n:End(), sourceFile, n, -1 --[[position]], excludeJSDoc)
        else
            return astnav.findRightmostValidToken(n:End(), sourceFile, n, position, excludeJSDoc)
        end
    end

    local node
    if startNode ~= nil then
        node = startNode
    else
        node = sourceFile:AsNode()
    end
    local result = find(node)
    if result ~= nil and ast.IsWhitespaceOnlyJsxText(result) then
        error("Expected result to be a non-whitespace token.")
    end
    return result
end

function astnav.isValidPrecedingNode(node, sourceFile)
    if node.kind == Kind.EndOfFile then
        return core.Len(node:JSDoc(sourceFile)) > 0
    end
    local start = astnav.GetStartOfNode(node, sourceFile, false --[[includeJSDoc]])
    local width = node:End() - start
    return not (ast.IsWhitespaceOnlyJsxText(node) or width == 0)
end

function astnav.GetStartOfNode(node, file, includeJSDoc)
    return scanner.GetTokenPosOfNode(node, file, includeJSDoc)
end

-- Looks for rightmost valid token in the range [startPos, endPos).
-- If position is >= 0, looks for rightmost valid token that precedes or touches that position.
function astnav.findRightmostValidToken(endPos, sourceFile, containingNode, position, excludeJSDoc)
    if position == -1 then
        position = containingNode:End()
    end
    local find
    find = function(n, endPos) -- luacheck: ignore 432
        if n == nil then
            return nil
        end
        if ast.IsNonWhitespaceToken(n) then
            return n
        end

        local rightmostValidNode = nil
        local rightmostVisitedNodes = {} -- Nodes after the last valid node.
        local hasChildren = false
        local function shouldVisitNode(node)
            -- Node is synthetic or out of the desired range: don't visit it.
            return not (node.flags & NodeFlags.Reparsed ~= 0 or
                node:End() > endPos or
                astnav.GetStartOfNode(node, sourceFile, not excludeJSDoc --[[includeJSDoc]]) >= position)
        end
        local function visitNode(node, _)
            if node == nil or node.flags & NodeFlags.Reparsed ~= 0 then
                return node
            end
            hasChildren = true
            if not shouldVisitNode(node) then
                return node
            end
            rightmostVisitedNodes[#rightmostVisitedNodes + 1] = node
            if astnav.isValidPrecedingNode(node, sourceFile) then
                rightmostValidNode = node
                rightmostVisitedNodes = {}
            end
            return node
        end
        local function visitNodes(nodeList, _)
            if nodeList ~= nil and core.Len(nodeList.nodes) > 0 then
                hasChildren = true
                local index = core.BinarySearchUniqueFunc(nodeList.nodes, function(_, node)
                    if node:End() > endPos then
                        return astnav.comparisonGreaterThan
                    end
                    return astnav.comparisonLessThan
                end)
                local validIndex = -1
                for i = index - 1, 0, -1 do
                    if shouldVisitNode(nodeList.nodes[i + 1]) then
                        if astnav.isValidPrecedingNode(nodeList.nodes[i + 1], sourceFile) then
                            validIndex = i
                            rightmostValidNode = nodeList.nodes[i + 1]
                            break
                        end
                    end
                end
                for i = validIndex + 1, index - 1 do
                    if shouldVisitNode(nodeList.nodes[i + 1]) then
                        rightmostVisitedNodes[#rightmostVisitedNodes + 1] = nodeList.nodes[i + 1]
                    end
                end
            end
            return nodeList
        end
        astnav.VisitEachChildAndJSDoc(n, sourceFile, visitNode, visitNodes)

        -- Three cases:
        -- 1. The answer is a token of `rightmostValidNode`.
        -- 2. The answer is one of the unvisited tokens that occur after the rightmost valid node.
        -- 3. The current node is a childless, token-less node. The answer is the current node.

        -- Case 2: Look at unvisited trailing tokens that occur in between the rightmost visited nodes.
        if not astnav.shouldSkipChild(n) then -- JSDoc nodes don't include trivia tokens as children.
            local startPos
            if rightmostValidNode ~= nil then
                startPos = rightmostValidNode:End()
            else
                startPos = n:Pos()
            end
            local s = scanner.GetScannerForSourceFile(sourceFile, startPos)
            local tokens = {}
            for _, visitedNode in ipairs(rightmostVisitedNodes) do
                -- Trailing tokens that occur before this node.
                while startPos < math.min(visitedNode:Pos(), position) do
                    local token = astnav.scanNavigationToken(s, n)
                    local tokenStart = s:TokenStart()
                    if tokenStart >= math.min(visitedNode:Pos(), position) then
                        break
                    end
                    local tokenFullStart = s:TokenFullStart()
                    local tokenEnd = s:TokenEnd()
                    startPos = tokenEnd
                    local flags = s:TokenFlags()
                    tokens[#tokens + 1] = sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, n, flags)
                    s:Scan()
                end
                startPos = visitedNode:End()
                s:ResetPos(startPos)
                s:Scan()
            end
            -- Trailing tokens after last visited node.
            while startPos < math.min(endPos, position) do
                local token = astnav.scanNavigationToken(s, n)
                local tokenStart = s:TokenStart()
                if tokenStart >= math.min(endPos, position) then
                    break
                end
                local tokenFullStart = s:TokenFullStart()
                local tokenEnd = s:TokenEnd()
                startPos = tokenEnd
                local flags = s:TokenFlags()
                tokens[#tokens + 1] = sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, n, flags)
                s:Scan()
            end

            local lastToken = #tokens - 1
            -- Find preceding valid token.
            for i = lastToken, 0, -1 do
                if not ast.IsWhitespaceOnlyJsxText(tokens[i + 1]) then
                    return tokens[i + 1]
                end
            end
        end

        -- Case 3: childless node.
        if not hasChildren then
            if n ~= containingNode then
                return n
            end
            return nil
        end
        -- Case 1: recur on rightmostValidNode.
        if rightmostValidNode ~= nil then
            endPos = rightmostValidNode:End()
        end
        return find(rightmostValidNode, endPos)
    end

    return find(containingNode, endPos)
end

function astnav.FindNextToken(previousToken, parent, file)
    local find
    find = function(n)
        if ast.IsTokenKind(n.kind) and n:Pos() == previousToken:End() then
            -- this is token that starts at the end of previous token - return it
            return n
        end
        -- Node that contains `previousToken` or occurs immediately after it.
        local foundNode = nil
        local function visitNode(node, _)
            if node ~= nil and node.flags & NodeFlags.Reparsed == 0 and
                node:Pos() <= previousToken:End() and node:End() > previousToken:End() then
                foundNode = node
            end
            return node
        end
        local function visitNodes(nodeList, _)
            if nodeList ~= nil and core.Len(nodeList.nodes) > 0 and foundNode == nil then
                local nodes = nodeList.nodes
                local index, match = core.BinarySearchUniqueFunc(nodes, function(_, node)
                    if node.flags & NodeFlags.Reparsed ~= 0 then
                        return astnav.comparisonLessThan
                    end
                    if node:Pos() > previousToken:End() then
                        return astnav.comparisonGreaterThan
                    end
                    if node:End() <= previousToken:Pos() then
                        return astnav.comparisonLessThan
                    end
                    return astnav.comparisonEqualTo
                end)
                if match then
                    foundNode = nodes[index + 1]
                end
            end
            return nodeList
        end
        astnav.VisitEachChildAndJSDoc(n, file, visitNode, visitNodes)
        -- Cases:
        -- 1. no answer exists
        -- 2. answer is an unvisited token
        -- 3. answer is in the visited found node

        -- Case 3: look for the next token inside the found node.
        if foundNode ~= nil then
            return find(foundNode)
        end
        local startPos = previousToken:End()
        -- Case 2: look for the next token directly.
        if startPos >= n:Pos() and startPos < n:End() then
            local s = scanner.GetScannerForSourceFile(file, startPos)
            local token = s:Token()
            local tokenFullStart = s:TokenFullStart()
            local tokenEnd = s:TokenEnd()
            local flags = s:TokenFlags()
            -- Use tokenFullStart (which includes leading trivia) to match TS's
            -- findNextToken behavior where `n.pos === previousToken.end` is checked
            -- (TS's pos includes trivia, same as Go's Pos()/tokenFullStart).
            if tokenFullStart == previousToken:End() then
                return file:GetOrCreateToken(token, tokenFullStart, tokenEnd, n, flags)
            end
            error(string.format("Expected to find next token at %d, got token %s at %d", previousToken:End(),
                ast.Kind_String(token), tokenFullStart))
        end
        -- Case 3: no answer.
        return nil
    end
    return find(parent)
end

function astnav.getNodeVisitor(visitNode, visitNodes)
    local wrappedVisitNode, wrappedVisitNodes = nil, nil
    if visitNode ~= nil then
        wrappedVisitNode = function(n, v)
            if ast.IsJSDocSingleCommentNodeComment(n) then
                return n
            end
            return visitNode(n, v)
        end
    end

    if visitNodes ~= nil then
        wrappedVisitNodes = function(n, v)
            if ast.IsJSDocSingleCommentNodeList(n) then
                return n
            end
            return visitNodes(n, v)
        end
    end

    return ast.NewNodeVisitor(core.Identity, nil, {
        visitNode = wrappedVisitNode,
        visitToken = wrappedVisitNode,
        visitNodes = wrappedVisitNodes,
        visitModifiers = function(modifiers, visitor)
            if modifiers ~= nil then
                wrappedVisitNodes(modifiers, visitor)
            end
            return modifiers
        end,
    })
end

function astnav.shouldSkipChild(node)
    return node.kind == Kind.JSDoc or
        node.kind == Kind.JSDocText or
        node.kind == Kind.JSDocTypeLiteral or
        node.kind == Kind.JSDocSignature or
        ast.IsJSDocLinkLike(node) or
        ast.IsJSDocTag(node)
end

-- FindChildOfKind searches for a child node or token of the specified kind within a containing node.
-- This function scans through both AST nodes and intervening tokens to find the first match.
function astnav.FindChildOfKind(containingNode, kind, sourceFile)
    local lastNodePos = containingNode:Pos()
    local scan = scanner.GetScannerForSourceFile(sourceFile, lastNodePos)

    local foundChild = nil
    local function visitNode(node)
        if node == nil or node.flags & NodeFlags.Reparsed ~= 0 then
            return false
        end
        -- Look for child in preceding tokens.
        local startPos = lastNodePos
        while startPos < node:Pos() do
            local tokenKind = scan:Token()
            local tokenEnd = scan:TokenEnd()
            if tokenKind == kind then
                local tokenFullStart = scan:TokenFullStart()
                local flags = scan:TokenFlags()
                foundChild = sourceFile:GetOrCreateToken(tokenKind, tokenFullStart, tokenEnd, containingNode, flags)
                return true
            end
            startPos = tokenEnd
            scan:Scan()
        end

        if node.kind == kind then
            foundChild = node
            return true
        end

        lastNodePos = node:End()
        scan:ResetPos(lastNodePos)
        return false
    end

    ast.ForEachChildAndJSDoc(containingNode, sourceFile, visitNode)

    if foundChild ~= nil then
        return foundChild
    end

    -- Look for child in trailing tokens.
    local startPos = lastNodePos
    while startPos < containingNode:End() do
        local tokenKind = scan:Token()
        local tokenEnd = scan:TokenEnd()
        if tokenKind == kind then
            local tokenFullStart = scan:TokenFullStart()
            local flags = scan:TokenFlags()
            local token = sourceFile:GetOrCreateToken(tokenKind, tokenFullStart, tokenEnd, containingNode, flags)
            return token
        end
        startPos = tokenEnd
        scan:Scan()
    end
    return nil
end
