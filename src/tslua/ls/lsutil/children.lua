local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

-- Replaces last(node.getChildren(sourceFile))
function lsutil.GetLastChild(node, sourceFile)
    local lastChildNode = lsutil.GetLastVisitedChild(node, sourceFile)
    if ast.IsJSDocSingleCommentNode(node) and lastChildNode == nil then
        return nil
    end
    local tokenStartPos
    if lastChildNode ~= nil then
        tokenStartPos = lastChildNode:End()
    else
        tokenStartPos = node:Pos()
    end
    local lastToken
    local s = scanner.GetScannerForSourceFile(sourceFile, tokenStartPos)
    local startPos = tokenStartPos
    while startPos < node:End() do
        local tokenKind = s:Token()
        local tokenFullStart = s:TokenFullStart()
        local tokenEnd = s:TokenEnd()
        lastToken = sourceFile:GetOrCreateToken(tokenKind, tokenFullStart, tokenEnd, node, s:TokenFlags())
        startPos = tokenEnd
        s:Scan()
    end
    return core.IfElse(lastToken ~= nil, lastToken, lastChildNode)
end

function lsutil.GetLastToken(node, sourceFile)
    if node == nil then
        return nil
    end

    if ast.IsTokenKind(node.kind) or ast.IsIdentifier(node) then
        return nil
    end

    lsutil.AssertHasRealPosition(node)

    local lastChild = lsutil.GetLastChild(node, sourceFile)
    if lastChild == nil then
        return nil
    end

    if lastChild.kind < Kind.FirstNode then
        return lastChild
    else
        return lsutil.GetLastToken(lastChild, sourceFile)
    end
end

-- Gets the last visited child of the given node.
-- NOTE: This doesn't include unvisited tokens; for this, use `getLastChild` or `getLastToken`.
function lsutil.GetLastVisitedChild(node, sourceFile)
    local lastChild

    local visitNode = function(n, _)
        if n ~= nil and n.flags & NodeFlags.Reparsed == 0 then
            lastChild = n
        end
        return n
    end
    local visitNodeList = function(nodeList, _)
        if nodeList ~= nil and #nodeList.nodes > 0 then
            for i = #nodeList.nodes, 1, -1 do
                if nodeList.nodes[i].flags & NodeFlags.Reparsed == 0 then
                    lastChild = nodeList.nodes[i]
                    break
                end
            end
        end
        return nodeList
    end

    astnav.VisitEachChildAndJSDoc(node, sourceFile, visitNode, visitNodeList)
    return lastChild
end

function lsutil.GetFirstToken(node, sourceFile)
    if ast.IsIdentifier(node) or ast.IsTokenKind(node.kind) then
        return nil
    end
    lsutil.AssertHasRealPosition(node)
    local firstChild
    node:ForEachChild(function(n)
        if n == nil or node.flags & NodeFlags.Reparsed ~= 0 then
            return false
        end
        firstChild = n
        return true
    end)

    local tokenEndPosition
    if firstChild ~= nil then
        tokenEndPosition = firstChild:Pos()
    else
        tokenEndPosition = node:End()
    end
    local s = scanner.GetScannerForSourceFile(sourceFile, node:Pos())
    local firstToken
    if node:Pos() < tokenEndPosition then
        local tokenKind = s:Token()
        local tokenFullStart = s:TokenFullStart()
        local tokenEnd = s:TokenEnd()
        firstToken = sourceFile:GetOrCreateToken(tokenKind, tokenFullStart, tokenEnd, node, s:TokenFlags())
    end

    if firstToken ~= nil then
        return firstToken
    end
    if firstChild == nil then
        return nil
    end
    if firstChild.kind < Kind.FirstNode then
        return firstChild
    end
    return lsutil.GetFirstToken(firstChild, sourceFile)
end

function lsutil.AssertHasRealPosition(node)
    if ast.PositionIsSynthesized(node:Pos()) or ast.PositionIsSynthesized(node:End()) then
        error("Node must have a real position for this operation.", 0)
    end
end
