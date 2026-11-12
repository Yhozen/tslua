local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local FindAncestorResult = ast.FindAncestorResult

function lsutil.PositionIsASICandidate(pos, context, file)
    local contextAncestor = ast.FindAncestorOrQuit(context, function(ancestor)
        if ancestor:End() ~= pos then
            return FindAncestorResult.FindAncestorQuit
        end

        return ast.ToFindAncestorResult(lsutil.SyntaxMayBeASICandidate(ancestor.kind))
    end)

    return contextAncestor ~= nil and lsutil.NodeIsASICandidate(contextAncestor, file)
end

function lsutil.SyntaxMayBeASICandidate(kind)
    return lsutil.SyntaxRequiresTrailingCommaOrSemicolonOrASI(kind) or
        lsutil.SyntaxRequiresTrailingFunctionBlockOrSemicolonOrASI(kind) or
        lsutil.SyntaxRequiresTrailingModuleBlockOrSemicolonOrASI(kind) or
        lsutil.SyntaxRequiresTrailingSemicolonOrASI(kind)
end

function lsutil.SyntaxRequiresTrailingCommaOrSemicolonOrASI(kind)
    return kind == Kind.CallSignature or
        kind == Kind.ConstructSignature or
        kind == Kind.IndexSignature or
        kind == Kind.PropertySignature or
        kind == Kind.MethodSignature
end

function lsutil.SyntaxRequiresTrailingFunctionBlockOrSemicolonOrASI(kind)
    return kind == Kind.FunctionDeclaration or
        kind == Kind.Constructor or
        kind == Kind.MethodDeclaration or
        kind == Kind.GetAccessor or
        kind == Kind.SetAccessor
end

function lsutil.SyntaxRequiresTrailingModuleBlockOrSemicolonOrASI(kind)
    return kind == Kind.ModuleDeclaration
end

function lsutil.SyntaxRequiresTrailingSemicolonOrASI(kind)
    return kind == Kind.VariableStatement or
        kind == Kind.ExpressionStatement or
        kind == Kind.DoStatement or
        kind == Kind.ContinueStatement or
        kind == Kind.BreakStatement or
        kind == Kind.ReturnStatement or
        kind == Kind.ThrowStatement or
        kind == Kind.DebuggerStatement or
        kind == Kind.PropertyDeclaration or
        kind == Kind.TypeAliasDeclaration or
        kind == Kind.ImportDeclaration or
        kind == Kind.ImportEqualsDeclaration or
        kind == Kind.ExportDeclaration or
        kind == Kind.NamespaceExportDeclaration or
        kind == Kind.ExportAssignment
end

function lsutil.NodeIsASICandidate(node, file)
    local lastToken = lsutil.GetLastToken(node, file)
    if lastToken ~= nil and lastToken.kind == Kind.SemicolonToken then
        return false
    end

    if lsutil.SyntaxRequiresTrailingCommaOrSemicolonOrASI(node.kind) then
        if lastToken ~= nil and lastToken.kind == Kind.CommaToken then
            return false
        end
    elseif lsutil.SyntaxRequiresTrailingModuleBlockOrSemicolonOrASI(node.kind) then
        local lastChild = lsutil.GetLastChild(node, file)
        if lastChild ~= nil and ast.IsModuleBlock(lastChild) then
            return false
        end
    elseif lsutil.SyntaxRequiresTrailingFunctionBlockOrSemicolonOrASI(node.kind) then
        local lastChild = lsutil.GetLastChild(node, file)
        if lastChild ~= nil and ast.IsFunctionBlock(lastChild) then
            return false
        end
    elseif not lsutil.SyntaxRequiresTrailingSemicolonOrASI(node.kind) then
        return false
    end

    -- See comment in parser's `parseDoStatement`
    if node.kind == Kind.DoStatement then
        return true
    end

    local topNode = ast.FindAncestor(node, function(ancestor)
        return ancestor.parent == nil
    end)
    local nextToken = astnav.FindNextToken(node, topNode, file)
    if nextToken == nil or nextToken.kind == Kind.CloseBraceToken then
        return true
    end

    local startLine = scanner.GetECMALineOfPosition(file, node:End())
    local endLine = scanner.GetECMALineOfPosition(file, astnav.GetStartOfNode(nextToken, file, false --[[includeJSDoc]]))
    return startLine ~= endLine
end
