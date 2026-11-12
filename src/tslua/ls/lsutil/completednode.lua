local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind

-- PositionBelongsToNode returns true if the position belongs to the node.
-- Assumes `candidate.Pos() <= position` holds.
function lsutil.PositionBelongsToNode(candidate, position, file)
    if candidate:Pos() > position then
        error("Expected candidate.pos <= position", 0)
    end
    return position < candidate:End() or not lsutil.IsCompletedNode(candidate, file)
end

local endsWithCloseBrace = {
    [Kind.ClassDeclaration] = true,
    [Kind.InterfaceDeclaration] = true,
    [Kind.EnumDeclaration] = true,
    [Kind.ObjectLiteralExpression] = true,
    [Kind.ObjectBindingPattern] = true,
    [Kind.TypeLiteral] = true,
    [Kind.Block] = true,
    [Kind.ModuleBlock] = true,
    [Kind.CaseBlock] = true,
    [Kind.NamedImports] = true,
    [Kind.NamedExports] = true,
}

local functionLikeKinds = {
    [Kind.Constructor] = true,
    [Kind.GetAccessor] = true,
    [Kind.SetAccessor] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.MethodSignature] = true,
    [Kind.ConstructSignature] = true,
    [Kind.CallSignature] = true,
    [Kind.ArrowFunction] = true,
}

local endsWithCloseBracket = {
    [Kind.ArrayLiteralExpression] = true,
    [Kind.ArrayBindingPattern] = true,
    [Kind.ElementAccessExpression] = true,
    [Kind.ComputedPropertyName] = true,
    [Kind.TupleType] = true,
}

function lsutil.IsCompletedNode(n, sourceFile)
    if n == nil or ast.NodeIsMissing(n) then
        return false
    end

    local kind = n.kind
    if endsWithCloseBrace[kind] then
        return lsutil.nodeEndsWith(n, Kind.CloseBraceToken, sourceFile)
    elseif kind == Kind.CatchClause then
        return lsutil.IsCompletedNode(n.block, sourceFile)
    elseif kind == Kind.NewExpression or kind == Kind.CallExpression or
        kind == Kind.ParenthesizedExpression or kind == Kind.ParenthesizedType then
        if kind == Kind.NewExpression and n:ArgumentList() == nil then
            return true
        end
        return lsutil.nodeEndsWith(n, Kind.CloseParenToken, sourceFile)
    elseif kind == Kind.FunctionType or kind == Kind.ConstructorType then
        return lsutil.IsCompletedNode(n:Type(), sourceFile)
    elseif functionLikeKinds[kind] then
        if n:Body() ~= nil then
            return lsutil.IsCompletedNode(n:Body(), sourceFile)
        end
        if n:Type() ~= nil then
            return lsutil.IsCompletedNode(n:Type(), sourceFile)
        end
        -- Even though type parameters can be unclosed, we can get away with
        -- having at least a closing paren.
        return lsutil.hasChildOfKind(n, Kind.CloseParenToken, sourceFile)
    elseif kind == Kind.ModuleDeclaration then
        return n:Body() ~= nil and lsutil.IsCompletedNode(n:Body(), sourceFile)
    elseif kind == Kind.IfStatement then
        if n.elseStatement ~= nil then
            return lsutil.IsCompletedNode(n.elseStatement, sourceFile)
        end
        return lsutil.IsCompletedNode(n.thenStatement, sourceFile)
    elseif kind == Kind.ExpressionStatement then
        return lsutil.IsCompletedNode(n:Expression(), sourceFile) or
            lsutil.hasChildOfKind(n, Kind.SemicolonToken, sourceFile)
    elseif endsWithCloseBracket[kind] then
        return lsutil.nodeEndsWith(n, Kind.CloseBracketToken, sourceFile)
    elseif kind == Kind.IndexSignature then
        if n.type ~= nil then
            return lsutil.IsCompletedNode(n.type, sourceFile)
        end
        return lsutil.hasChildOfKind(n, Kind.CloseBracketToken, sourceFile)
    elseif kind == Kind.CaseClause or kind == Kind.DefaultClause then
        -- there is no such thing as terminator token for CaseClause/DefaultClause so for simplicity always consider them non-completed
        return false
    elseif kind == Kind.ForStatement or kind == Kind.ForInStatement or kind == Kind.ForOfStatement or
        kind == Kind.WhileStatement then
        return lsutil.IsCompletedNode(n:Statement(), sourceFile)
    elseif kind == Kind.DoStatement then
        -- rough approximation: if DoStatement has While keyword - then if node is completed is checking the presence of ')';
        if lsutil.hasChildOfKind(n, Kind.WhileKeyword, sourceFile) then
            return lsutil.nodeEndsWith(n, Kind.CloseParenToken, sourceFile)
        end
        return lsutil.IsCompletedNode(n:Statement(), sourceFile)
    elseif kind == Kind.TypeQuery then
        return lsutil.IsCompletedNode(n.exprName, sourceFile)
    elseif kind == Kind.TypeOfExpression or kind == Kind.DeleteExpression or kind == Kind.VoidExpression or
        kind == Kind.YieldExpression or kind == Kind.SpreadElement then
        return lsutil.IsCompletedNode(n:Expression(), sourceFile)
    elseif kind == Kind.TaggedTemplateExpression then
        return lsutil.IsCompletedNode(n.template, sourceFile)
    elseif kind == Kind.TemplateExpression then
        if n.templateSpans == nil then
            return false
        end
        local lastSpan = core.LastOrNil(n.templateSpans.nodes)
        return lsutil.IsCompletedNode(lastSpan, sourceFile)
    elseif kind == Kind.TemplateSpan then
        return ast.NodeIsPresent(n.literal)
    elseif kind == Kind.ExportDeclaration or kind == Kind.ImportDeclaration then
        return ast.NodeIsPresent(n:ModuleSpecifier())
    elseif kind == Kind.PrefixUnaryExpression then
        return lsutil.IsCompletedNode(n.operand, sourceFile)
    elseif kind == Kind.BinaryExpression then
        return lsutil.IsCompletedNode(n.right, sourceFile)
    elseif kind == Kind.ConditionalExpression then
        return lsutil.IsCompletedNode(n.whenFalse, sourceFile)
    else
        return true
    end
end

-- Checks if node ends with 'expectedLastToken'.
-- If child at position 'length - 1' is 'SemicolonToken' it is skipped and 'expectedLastToken' is compared with child at position 'length - 2'.
function lsutil.nodeEndsWith(n, expectedLastToken, sourceFile)
    local lastChildNode = lsutil.GetLastVisitedChild(n, sourceFile)
    local lastNodeAndTokens = {}
    local tokenStartPos
    if lastChildNode ~= nil then
        lastNodeAndTokens = { lastChildNode }
        tokenStartPos = lastChildNode:End()
    else
        tokenStartPos = n:Pos()
    end
    local s = scanner.GetScannerForSourceFile(sourceFile, tokenStartPos)
    local startPos = tokenStartPos
    while startPos < n:End() do
        local tokenKind = s:Token()
        local tokenFullStart = s:TokenFullStart()
        local tokenEnd = s:TokenEnd()
        local token = sourceFile:GetOrCreateToken(tokenKind, tokenFullStart, tokenEnd, n, s:TokenFlags())
        lastNodeAndTokens[#lastNodeAndTokens + 1] = token
        startPos = tokenEnd
        s:Scan()
    end
    if #lastNodeAndTokens == 0 then
        return false
    end
    local lastChild = lastNodeAndTokens[#lastNodeAndTokens]
    if lastChild.kind == expectedLastToken then
        return true
    elseif lastChild.kind == Kind.SemicolonToken and #lastNodeAndTokens > 1 then
        return lastNodeAndTokens[#lastNodeAndTokens - 1].kind == expectedLastToken
    end
    return false
end

function lsutil.hasChildOfKind(containingNode, kind, sourceFile)
    return astnav.FindChildOfKind(containingNode, kind, sourceFile) ~= nil
end
