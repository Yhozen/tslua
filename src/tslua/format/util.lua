local format = require("tslua.format")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local scanner = require("tslua.scanner")

local Kind = ast.Kind

function format.rangeIsOnOneLine(node, file)
    local startLine = scanner.GetECMALineOfPosition(file, node:Pos())
    local endLine = scanner.GetECMALineOfPosition(file, node:End())
    return startLine == endLine
end

local openTokenForListFunctionKinds = ast.kindSet(Kind.Constructor, Kind.FunctionDeclaration, Kind.FunctionExpression,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.ArrowFunction, Kind.CallSignature, Kind.ConstructSignature,
    Kind.FunctionType, Kind.ConstructorType, Kind.GetAccessor, Kind.SetAccessor)
local openTokenForListClassKinds = ast.kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration)
local openTokenForListTypeArgumentKinds = ast.kindSet(Kind.TypeReference, Kind.TaggedTemplateExpression, Kind.TypeQuery,
    Kind.ExpressionWithTypeArguments, Kind.ImportType)

function format.getOpenTokenForList(node, list)
    local k = node.kind
    if openTokenForListFunctionKinds[k] then
        if node:TypeParameterList() == list then
            return Kind.LessThanToken
        elseif node:ParameterList() == list then
            return Kind.OpenParenToken
        end
    elseif k == Kind.CallExpression or k == Kind.NewExpression then
        if node:TypeArgumentList() == list then
            return Kind.LessThanToken
        elseif node:ArgumentList() == list then
            return Kind.OpenParenToken
        end
    elseif openTokenForListClassKinds[k] then
        if node:TypeParameterList() == list then
            return Kind.LessThanToken
        end
    elseif openTokenForListTypeArgumentKinds[k] then
        if node:TypeArgumentList() == list then
            return Kind.LessThanToken
        end
    elseif k == Kind.TypeLiteral then
        return Kind.OpenBraceToken
    end

    return Kind.Unknown
end

function format.getCloseTokenForOpenToken(kind)
    -- TODO: matches strada - seems like it could handle more pairs of braces, though? [] notably missing
    if kind == Kind.OpenParenToken then
        return Kind.CloseParenToken
    elseif kind == Kind.LessThanToken then
        return Kind.GreaterThanToken
    elseif kind == Kind.OpenBraceToken then
        return Kind.CloseBraceToken
    end
    return Kind.Unknown
end

function format.GetLineStartPositionForPosition(position, sourceFile)
    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    local line = scanner.GetECMALineOfPosition(sourceFile, position)
    return lineStarts[line + 1]
end

--[[*
 * Validating `expectedTokenKind` ensures the token was typed in the context we expect (eg: not a comment).
 * @param expectedTokenKind The kind of the last token constituting the desired parent node.
 ]]
function format.findImmediatelyPrecedingTokenOfKind(end_, expectedTokenKind, sourceFile)
    local precedingToken = astnav.FindPrecedingToken(sourceFile, end_)
    if precedingToken == nil or precedingToken.kind ~= expectedTokenKind or precedingToken:End() ~= end_ then
        return nil
    end
    return precedingToken
end

--[[*
 * Finds the highest node enclosing `node` at the same list level as `node`
 * and whose end does not exceed `node.end`.
 *
 * Consider typing the following
 * ```
 * let x = 1;
 * while (true) {
 * }
 * ```
 * Upon typing the closing curly, we want to format the entire `while`-statement, but not the preceding
 * variable declaration.
 ]]
function format.findOutermostNodeWithinListLevel(node)
    local current = node
    while current ~= nil and
        current.parent ~= nil and
        current.parent:End() == node:End() and
        not format.isListElement(current.parent, current) do
        current = current.parent
    end

    return current
end

-- Returns true if node is a element in some list in parent
-- i.e. parent is class declaration with the list of members and node is one of members.
function format.isListElement(parent, node)
    local k = parent.kind
    if k == Kind.ClassDeclaration or k == Kind.InterfaceDeclaration then
        return node.loc:ContainedBy(parent:MemberList().loc)
    elseif k == Kind.ModuleDeclaration then
        local body = parent:Body()
        return body ~= nil and body.kind == Kind.ModuleBlock and node.loc:ContainedBy(body:StatementList().loc)
    elseif k == Kind.SourceFile or k == Kind.Block or k == Kind.ModuleBlock then
        return node.loc:ContainedBy(parent:StatementList().loc)
    elseif k == Kind.CatchClause then
        return node.loc:ContainedBy(parent:AsCatchClause().block:StatementList().loc)
    end

    return false
end

local memberListElementKinds = ast.kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.EnumDeclaration, Kind.TypeLiteral, Kind.MappedType)

function format.isMemberListElement(parent, node)
    if memberListElementKinds[parent.kind] then
        return node.loc:ContainedBy(parent:MemberList().loc)
    end
    return false
end
