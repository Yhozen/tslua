local change = require("tslua.ls.change")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local debug = require("tslua.debug")
local format = require("tslua.format")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local LeadingTriviaOption = change.LeadingTriviaOption
local TrailingTriviaOption = change.TrailingTriviaOption

-- deletedNodesInLists is { set = map[*ast.Node]bool, order = []*ast.Node } (insertion order kept
-- so the later trailing-comma pass is deterministic).

-- deleteDeclaration deletes a node with smart handling for different node types.
-- This handles special cases like import specifiers in lists, parameters, etc.
function change.deleteDeclaration(t, deletedNodesInLists, sourceFile, node)
    local kind = node.kind
    if kind == Kind.Parameter then
        local oldFunction = node.parent
        if oldFunction.kind == Kind.ArrowFunction and
            #oldFunction:AsArrowFunction().parameters.nodes == 1 and
            astnav.FindChildOfKind(oldFunction, Kind.OpenParenToken, sourceFile) == nil then
            -- Lambdas with exactly one parameter are special because, after removal, there
            -- must be an empty parameter list (i.e. `()`) and this won't necessarily be the
            -- case if the parameter is simply removed (e.g. in `x => 1`).
            t:ReplaceRangeWithText(sourceFile, t:GetAdjustedRange(sourceFile, node, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include), "()")
        else
            change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
        end
    elseif kind == Kind.ImportDeclaration or kind == Kind.ImportEqualsDeclaration then
        local imports = sourceFile:Imports()
        local isFirstImport = core.Len(imports) > 0 and node == imports[1].parent or
            node == core.Find(sourceFile.statements.nodes, function(s)
                return ast.IsAnyImportSyntax(s)
            end)
        -- For first import, leave header comment in place, otherwise only delete JSDoc comments
        local leadingTrivia = LeadingTriviaOption.StartLine
        if isFirstImport then
            leadingTrivia = LeadingTriviaOption.Exclude
        elseif change.hasJSDocNodes(node) then
            leadingTrivia = LeadingTriviaOption.JSDoc
        end
        change.deleteNode(t, sourceFile, node, leadingTrivia, TrailingTriviaOption.Include)
    elseif kind == Kind.BindingElement then
        local pattern = node.parent
        local elements = pattern:AsBindingPattern().elements.nodes
        local preserveComma = pattern.kind == Kind.ArrayBindingPattern and
            node ~= elements[#elements]
        if preserveComma then
            change.deleteNode(t, sourceFile, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Exclude)
        else
            change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
        end
    elseif kind == Kind.VariableDeclaration then
        change.deleteVariableDeclaration(t, deletedNodesInLists, sourceFile, node)
    elseif kind == Kind.TypeParameter then
        change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
    elseif kind == Kind.ImportSpecifier then
        local namedImports = node.parent
        if #namedImports:AsNamedImports().elements.nodes == 1 then
            change.deleteImportBinding(t, sourceFile, namedImports)
        else
            change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
        end
    elseif kind == Kind.NamespaceImport then
        change.deleteImportBinding(t, sourceFile, node)
    elseif kind == Kind.SemicolonToken then
        change.deleteNode(t, sourceFile, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Exclude)
    elseif kind == Kind.TypeKeyword then
        -- For type keyword in import clauses, we need to delete the keyword and any trailing space
        -- The trailing space is part of the next token's leading trivia, so we include it
        change.deleteNode(t, sourceFile, node, LeadingTriviaOption.Exclude, TrailingTriviaOption.Include)
    elseif kind == Kind.FunctionKeyword then
        change.deleteNode(t, sourceFile, node, LeadingTriviaOption.Exclude, TrailingTriviaOption.Include)
    elseif kind == Kind.ClassDeclaration or kind == Kind.FunctionDeclaration then
        local leadingTrivia = LeadingTriviaOption.StartLine
        if change.hasJSDocNodes(node) then
            leadingTrivia = LeadingTriviaOption.JSDoc
        end
        change.deleteNode(t, sourceFile, node, leadingTrivia, TrailingTriviaOption.Include)
    else
        if node.parent == nil then
            -- a misbehaving client can reach here with the SourceFile node
            change.deleteNode(t, sourceFile, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
        elseif node.parent.kind == Kind.ImportClause and node.parent:AsImportClause():Name() == node then
            change.deleteDefaultImport(t, sourceFile, node.parent)
        elseif node.parent.kind == Kind.CallExpression and core.FindIndex(node.parent:AsCallExpression().arguments.nodes, function(a)
            return a == node
        end) >= 0 then
            change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
        else
            change.deleteNode(t, sourceFile, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
        end
    end
end

function change.deleteDefaultImport(t, sourceFile, importClause)
    local clause = importClause:AsImportClause()
    if clause.namedBindings == nil then
        -- Delete the whole import
        change.deleteNode(t, sourceFile, importClause.parent, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
    else
        -- import |d,| * as ns from './file'
        local name = clause:Name()
        local start = astnav.GetStartOfNode(name, sourceFile, false)
        local nextToken = astnav.GetTokenAtPosition(sourceFile, name:End())
        if nextToken ~= nil and nextToken.kind == Kind.CommaToken then
            -- shift first non-whitespace position after comma to the start position of the node
            local end_ = scanner.SkipTriviaEx(sourceFile:Text(), nextToken:End(), { stopAfterLineBreak = false, stopAtComments = true })
            t:ReplaceRangeWithText(sourceFile, t:toLSPEditRange(sourceFile, core.NewTextRange(start, end_)), "")
        else
            change.deleteNode(t, sourceFile, name, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
        end
    end
end

function change.deleteImportBinding(t, sourceFile, node)
    local importClause = node.parent:AsImportClause()
    if importClause:Name() ~= nil then
        -- Delete named imports while preserving the default import
        -- import d|, * as ns| from './file'
        -- import d|, { a }| from './file'
        local previousToken = astnav.GetTokenAtPosition(sourceFile, node:Pos() - 1)
        debug.Assert(previousToken ~= nil, "previousToken should not be nil")
        local start = astnav.GetStartOfNode(previousToken, sourceFile, false)
        t:ReplaceRangeWithText(sourceFile, t:toLSPEditRange(sourceFile, core.NewTextRange(start, node:End())), "")
    else
        -- Delete the entire import declaration
        -- |import * as ns from './file'|
        -- |import { a } from './file'|
        local importDecl = ast.FindAncestorKind(node, Kind.ImportDeclaration)
        debug.Assert(importDecl ~= nil, "importDecl should not be nil")
        change.deleteNode(t, sourceFile, importDecl, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
    end
end

function change.deleteVariableDeclaration(t, deletedNodesInLists, sourceFile, node)
    local parent = node.parent

    if parent.kind == Kind.CatchClause then
        -- TODO: There's currently no unused diagnostic for this, could be a suggestion
        local openParen = astnav.FindChildOfKind(parent, Kind.OpenParenToken, sourceFile)
        local closeParen = astnav.FindChildOfKind(parent, Kind.CloseParenToken, sourceFile)
        debug.Assert(openParen ~= nil and closeParen ~= nil, "catch clause should have parens")
        t:DeleteNodeRange(sourceFile, openParen, closeParen, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
        return
    end

    if #parent:AsVariableDeclarationList().declarations.nodes ~= 1 then
        change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
        return
    end

    local gp = parent.parent
    local gpKind = gp.kind
    if gpKind == Kind.ForOfStatement or gpKind == Kind.ForInStatement then
        t:ReplaceNode(sourceFile, node, t.nodeFactory:NewObjectLiteralExpression(t.nodeFactory:NewNodeList({}), false), nil)
    elseif gpKind == Kind.ForStatement then
        change.deleteNode(t, sourceFile, parent, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
    elseif gpKind == Kind.VariableStatement then
        local leadingTrivia = LeadingTriviaOption.StartLine
        if change.hasJSDocNodes(gp) then
            leadingTrivia = LeadingTriviaOption.JSDoc
        end
        change.deleteNode(t, sourceFile, gp, leadingTrivia, TrailingTriviaOption.Include)
    else
        debug.Fail("Unexpected grandparent kind: " .. ast.Kind_String(gp.kind))
    end
end

-- deleteNode deletes a node with the specified trivia options.
-- Warning: This deletes comments too.
function change.deleteNode(t, sourceFile, node, leadingTrivia, trailingTrivia)
    local startPosition = t:getAdjustedStartPosition(sourceFile, node, leadingTrivia, false)
    local endPosition = t:getAdjustedEndPosition(sourceFile, node, trailingTrivia)
    t:ReplaceRangeWithText(sourceFile, t:toLSPEditRange(sourceFile, core.NewTextRange(startPosition, endPosition)), "")
end

function change.deleteNodeInList(t, deletedNodesInLists, sourceFile, node)
    local containingList = format.GetContainingList(node, sourceFile)
    debug.Assert(containingList ~= nil, "containingList should not be nil")
    local index = core.FindIndex(containingList.nodes, function(n)
        return n == node
    end)
    debug.Assert(index ~= -1, "node should be in containing list")

    if #containingList.nodes == 1 then
        change.deleteNode(t, sourceFile, node, LeadingTriviaOption.IncludeAll, TrailingTriviaOption.Include)
        return
    end

    -- Note: We will only delete a comma *after* a node. This will leave a trailing comma if we delete the last node.
    -- That's handled in the end by finishTrailingCommaAfterDeletingNodesInList.
    debug.Assert(not deletedNodesInLists.set[node], "Deleting a node twice")
    deletedNodesInLists.set[node] = true
    deletedNodesInLists.order[#deletedNodesInLists.order + 1] = node

    local startPos = t:startPositionToDeleteNodeInList(sourceFile, node)
    local endPos
    if index == #containingList.nodes - 1 then
        endPos = t:getAdjustedEndPosition(sourceFile, node, TrailingTriviaOption.None)
    else
        local prevNode = nil
        if index > 0 then
            prevNode = containingList.nodes[index]
        end
        endPos = t:endPositionToDeleteNodeInList(sourceFile, node, prevNode, containingList.nodes[index + 2])
    end

    t:ReplaceRangeWithText(sourceFile, t:toLSPEditRange(sourceFile, core.NewTextRange(startPos, endPos)), "")
end

local Tracker = change.Tracker

-- startPositionToDeleteNodeInList finds the first non-whitespace position in the leading trivia of the node
function Tracker:startPositionToDeleteNodeInList(sourceFile, node)
    local start = self:getAdjustedStartPosition(sourceFile, node, LeadingTriviaOption.IncludeAll, false)
    return scanner.SkipTriviaEx(sourceFile:Text(), start, { stopAfterLineBreak = false, stopAtComments = true })
end

function Tracker:endPositionToDeleteNodeInList(sourceFile, node, prevNode, nextNode)
    local end_ = self:startPositionToDeleteNodeInList(sourceFile, nextNode)
    if prevNode == nil or change.positionsAreOnSameLine(self:getAdjustedEndPosition(sourceFile, node, TrailingTriviaOption.Include), end_, sourceFile) then
        return end_
    end
    local token = astnav.FindPrecedingToken(sourceFile, astnav.GetStartOfNode(nextNode, sourceFile, false))
    if change.isSeparator(node, token) then
        local prevToken = astnav.FindPrecedingToken(sourceFile, astnav.GetStartOfNode(node, sourceFile, false))
        if change.isSeparator(prevNode, prevToken) then
            local pos = scanner.SkipTriviaEx(sourceFile:Text(), token:End(), { stopAfterLineBreak = true, stopAtComments = true })
            if change.positionsAreOnSameLine(astnav.GetStartOfNode(prevToken, sourceFile, false), astnav.GetStartOfNode(token, sourceFile, false), sourceFile) then
                if pos > 0 and stringutil.IsLineBreak(string.byte(sourceFile:Text(), pos)) then
                    return pos - 1
                end
                return pos
            end
            if stringutil.IsLineBreak(string.byte(sourceFile:Text(), pos + 1) or 0) then
                return pos
            end
        end
    end
    return end_
end

function change.positionsAreOnSameLine(pos1, pos2, sourceFile)
    return format.GetLineStartPositionForPosition(pos1, sourceFile) == format.GetLineStartPositionForPosition(pos2, sourceFile)
end

-- hasJSDocNodes checks if a node has JSDoc comments
function change.hasJSDocNodes(node)
    if node == nil then
        return false
    end
    -- nil is ok for JSDoc - it will return empty slice if not available
    local jsdocs = node:JSDoc(nil)
    return core.Len(jsdocs) > 0
end
