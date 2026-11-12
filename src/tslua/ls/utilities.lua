local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local jsnum = require("tslua.jsnum")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local strings = require("tslua.module").strings

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SemanticMeaning = ast.SemanticMeaning

-- Go quoteReplacer: strings.NewReplacer("'", `\'`, `\"`, `"`)
function ls.quoteReplace(s)
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = string.sub(s, i, i)
        if c == "'" then
            out[#out + 1] = "\\'"
            i = i + 1
        elseif c == "\\" and string.sub(s, i + 1, i + 1) == '"' then
            out[#out + 1] = '"'
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

function ls.IsInString(sourceFile, position, previousToken)
    if previousToken ~= nil and ast.IsStringTextContainingNode(previousToken) then
        local start = astnav.GetStartOfNode(previousToken, sourceFile, false --[[includeJSDoc]])
        local end_ = previousToken:End()

        -- To be "in" one of these literals, the position has to be:
        --   1. entirely within the token text.
        --   2. at the end position of an unterminated token.
        --   3. at the end of a regular expression (due to trailing flags like '/foo/g').
        if start < position and position < end_ then
            return true
        end

        if position == end_ then
            return ast.IsUnterminatedLiteral(previousToken)
        end
    end
    return false
end

function ls.isModuleSpecifierLike(node)
    if not ast.IsStringLiteralLike(node) then
        return false
    end

    if ast.IsRequireCall(node.parent, false --[[requireStringLiteralLikeArgument]]) or ast.IsImportCall(node.parent) then
        return node.parent:Arguments()[1] == node
    end

    return node.parent.kind == Kind.ExternalModuleReference or
        node.parent.kind == Kind.ImportDeclaration or
        node.parent.kind == Kind.JSImportDeclaration
end

function ls.getNonModuleSymbolOfMergedModuleSymbol(symbol)
    if core.Len(symbol.declarations) == 0 or (symbol.flags & (SymbolFlags.Module | SymbolFlags.Transient)) == 0 then
        return nil
    end

    local decl = core.Find(symbol.declarations, function(d)
        return not ast.IsSourceFile(d) and not ast.IsModuleDeclaration(d)
    end)
    if decl ~= nil then
        return decl:Symbol()
    end
    return nil
end

function ls.getLocalSymbolForExportSpecifier(referenceLocation, referenceSymbol, exportSpecifier, ch)
    if ls.isExportSpecifierAlias(referenceLocation, exportSpecifier) then
        local symbol = ch:GetExportSpecifierLocalTargetSymbol(exportSpecifier)
        if symbol ~= nil then
            return symbol
        end
    end
    return referenceSymbol
end

function ls.isExportSpecifierAlias(referenceLocation, exportSpecifier)
    debug.Assert(exportSpecifier.propertyName == referenceLocation or exportSpecifier:Name() == referenceLocation, "referenceLocation is not export specifier name or property name")
    local propertyName = exportSpecifier.propertyName
    if propertyName ~= nil then
        -- Given `export { foo as bar } [from "someModule"]`: It's an alias at `foo`, but at `bar` it's a new symbol.
        return propertyName == referenceLocation
    else
        -- `export { foo } from "foo"` is a re-export.
        -- `export { foo };` is not a re-export, it creates an alias for the local variable `foo`.
        return exportSpecifier.parent.parent:ModuleSpecifier() == nil
    end
end

function ls.isInComment(file, position, tokenAtPosition)
    return ls.getRangeOfEnclosingComment(file, position, astnav.FindPrecedingToken(file, position), tokenAtPosition)
end

function ls.positionBelongsToNode(candidate, position, file)
    return lsutil.PositionBelongsToNode(candidate, position, file)
end

-- PossibleTypeArgumentInfo: { called = *ast.IdentifierNode, nTypeArguments = int }

local possibleTypeArgumentsNoOpKinds = {
    [Kind.EqualsGreaterThanToken] = true,
    [Kind.Identifier] = true,
    [Kind.StringLiteral] = true,
    [Kind.NumericLiteral] = true,
    [Kind.BigIntLiteral] = true,
    [Kind.TrueKeyword] = true,
    [Kind.FalseKeyword] = true,
    [Kind.TypeOfKeyword] = true,
    [Kind.ExtendsKeyword] = true,
    [Kind.KeyOfKeyword] = true,
    [Kind.DotToken] = true,
    [Kind.BarToken] = true,
    [Kind.QuestionToken] = true,
    [Kind.ColonToken] = true,
}

-- Get info for an expression like `f <` that may be the start of type arguments.
function ls.getPossibleTypeArgumentsInfo(tokenIn, sourceFile)
    -- This is a rare case, but one that saves on a _lot_ of work if true - if the source file has _no_ `<` character,
    -- then there obviously can't be any type arguments - no expensive brace-matching backwards scanning required
    if not string.find(sourceFile:Text(), "<", 1, true) then
        return nil
    end

    local token = tokenIn
    -- This function determines if the node could be a type argument position
    -- When editing, it is common to have an incomplete type argument list (e.g. missing ">"),
    -- so the tree can have any shape depending on the tokens before the current node.
    -- Instead, scanning for an identifier followed by a "<" before current node
    -- will typically give us better results than inspecting the tree.
    -- Note that we also balance out the already provided type arguments, arrays, object literals while doing so.
    local remainingLessThanTokens = 0
    local nTypeArguments = 0
    while token ~= nil do
        local kind = token.kind
        if kind == Kind.LessThanToken then
            -- Found the beginning of the generic argument expression
            token = astnav.FindPrecedingToken(sourceFile, token:Pos())
            if token ~= nil and token.kind == Kind.QuestionDotToken then
                token = astnav.FindPrecedingToken(sourceFile, token:Pos())
            end
            if token == nil or not ast.IsIdentifier(token) then
                return nil
            end
            if remainingLessThanTokens == 0 then
                if ast.IsDeclarationName(token) then
                    return nil
                end
                return {
                    called = token,
                    nTypeArguments = nTypeArguments,
                }
            end
            remainingLessThanTokens = remainingLessThanTokens - 1
        elseif kind == Kind.GreaterThanGreaterThanGreaterThanToken then
            remainingLessThanTokens = remainingLessThanTokens + 3
        elseif kind == Kind.GreaterThanGreaterThanToken then
            remainingLessThanTokens = remainingLessThanTokens + 2
        elseif kind == Kind.GreaterThanToken then
            remainingLessThanTokens = remainingLessThanTokens + 1
        elseif kind == Kind.CloseBraceToken then
            -- This can be object type, skip until we find the matching open brace token
            -- Skip until the matching open brace token
            token = ls.findPrecedingMatchingToken(token, Kind.OpenBraceToken, sourceFile)
            if token == nil then
                return nil
            end
        elseif kind == Kind.CloseParenToken then
            -- This can be object type, skip until we find the matching open brace token
            -- Skip until the matching open brace token
            token = ls.findPrecedingMatchingToken(token, Kind.OpenParenToken, sourceFile)
            if token == nil then
                return nil
            end
        elseif kind == Kind.CloseBracketToken then
            -- This can be object type, skip until we find the matching open brace token
            -- Skip until the matching open brace token
            token = ls.findPrecedingMatchingToken(token, Kind.OpenBracketToken, sourceFile)
            if token == nil then
                return nil
            end
        elseif kind == Kind.CommaToken then
            -- Valid tokens in a type name. Skip.
            nTypeArguments = nTypeArguments + 1
        elseif possibleTypeArgumentsNoOpKinds[kind] then -- luacheck: ignore 542
            -- do nothing
        else
            if not ast.IsTypeNode(token) then
                -- Invalid token in type
                return nil
            end
        end
        token = astnav.FindPrecedingToken(sourceFile, token:Pos())
    end
    return nil
end

function ls.isNameOfModuleDeclaration(node)
    if node.parent.kind ~= Kind.ModuleDeclaration then
        return false
    end
    return node.parent:Name() == node
end

function ls.isExpressionOfExternalModuleImportEqualsDeclaration(node)
    return ast.IsExternalModuleImportEqualsDeclaration(node.parent.parent) and ast.GetExternalModuleImportEqualsDeclarationExpression(node.parent.parent) == node
end

function ls.isNamespaceReference(node)
    return ls.isQualifiedNameNamespaceReference(node) or ls.isPropertyAccessNamespaceReference(node)
end

function ls.isQualifiedNameNamespaceReference(node)
    local root = node
    local isLastClause = true
    if root.parent.kind == Kind.QualifiedName then
        while root.parent ~= nil and root.parent.kind == Kind.QualifiedName do
            root = root.parent
        end

        isLastClause = root:AsQualifiedName().right == node
    end

    return root.parent.kind == Kind.TypeReference and not isLastClause
end

function ls.isPropertyAccessNamespaceReference(node)
    local root = node
    local isLastClause = true
    if root.parent.kind == Kind.PropertyAccessExpression then
        while root.parent ~= nil and root.parent.kind == Kind.PropertyAccessExpression do
            root = root.parent
        end

        isLastClause = root:Name() == node
    end

    if not isLastClause and root.parent.kind == Kind.ExpressionWithTypeArguments and root.parent.parent.kind == Kind.HeritageClause then
        local decl = root.parent.parent.parent
        return (decl.kind == Kind.ClassDeclaration and root.parent.parent:AsHeritageClause().token == Kind.ImplementsKeyword) or
            (decl.kind == Kind.InterfaceDeclaration and root.parent.parent:AsHeritageClause().token == Kind.ExtendsKeyword)
    end

    return false
end

function ls.isThis(node)
    if node.kind == Kind.ThisKeyword then
        -- case ast.KindThisType: TODO: GH#9267
        return true
    elseif node.kind == Kind.Identifier then
        -- 'this' as a parameter
        return node:Text() == "this" and node.parent.kind == Kind.Parameter
    else
        return false
    end
end

function ls.isTypeReference(node)
    if ast.IsRightSideOfQualifiedNameOrPropertyAccess(node) then
        node = node.parent
    end

    if node.kind == Kind.ThisKeyword then
        return not ast.IsExpressionNode(node)
    elseif node.kind == Kind.ThisType then
        return true
    end

    local parentKind = node.parent.kind
    if parentKind == Kind.TypeReference then
        return true
    elseif parentKind == Kind.ImportType then
        return not node.parent:AsImportTypeNode().isTypeOf
    elseif parentKind == Kind.ExpressionWithTypeArguments then
        return ast.IsPartOfTypeNode(node.parent)
    end

    return false
end

function ls.isInRightSideOfInternalImportEqualsDeclaration(node)
    if node.parent == nil then
        return false
    end
    while node.parent.kind == Kind.QualifiedName do
        node = node.parent
    end

    return ast.IsInternalModuleImportEqualsDeclaration(node.parent) and node.parent:AsImportEqualsDeclaration().moduleReference == node
end

local LanguageService = ls.LanguageService

-- Returns (lsproto.Range, spanmap.Fidelity).
function LanguageService:createLspRangeFromNode(node, file)
    return self:createLspRangeFromBounds(scanner.GetTokenPosOfNode(node, file, false --[[includeJSDoc]]), node:End(), file)
end

function LanguageService:createLspRangeFromNodeForFeature(node, file, feature)
    return self.converters:ToLSPRangeForFeature(file, ls.createRangeFromNode(node, file), feature)
end

function ls.createRangeFromNode(node, file)
    return core.NewTextRange(scanner.GetTokenPosOfNode(node, file, false --[[includeJSDoc]]), node:End())
end

function LanguageService:createLspRangeFromBounds(start, end_, file)
    return self.converters:ToLSPRange(file, core.NewTextRange(start, end_))
end

function LanguageService:createLspRangeFromRange(textRange, script)
    return self.converters:ToLSPRange(script, textRange)
end

function LanguageService:createLspPosition(position, file)
    return self.converters:ToLSPPosition(file, position)
end

function ls.quote(file, preferences, text)
    -- Editors can pass in undefined or empty string - we want to infer the preference in those cases.
    local quotePreference = lsutil.GetQuotePreference(file, preferences)
    local quoted = core.StringifyJson(text, "" --[[prefix]], "" --[[indent]])
    if quotePreference == lsutil.QuotePreference.Single then
        quoted = "'" .. ls.quoteReplace(stringutil.StripQuotes(quoted)) .. "'"
    end
    return quoted
end

ls.typeKeywords = collections.NewSetFromItems(
    Kind.AnyKeyword,
    Kind.AssertsKeyword,
    Kind.BigIntKeyword,
    Kind.BooleanKeyword,
    Kind.FalseKeyword,
    Kind.InferKeyword,
    Kind.KeyOfKeyword,
    Kind.NeverKeyword,
    Kind.NullKeyword,
    Kind.NumberKeyword,
    Kind.ObjectKeyword,
    Kind.ReadonlyKeyword,
    Kind.StringKeyword,
    Kind.SymbolKeyword,
    Kind.TypeOfKeyword,
    Kind.TrueKeyword,
    Kind.VoidKeyword,
    Kind.UndefinedKeyword,
    Kind.UniqueKeyword,
    Kind.UnknownKeyword
)

function ls.isTypeKeyword(kind)
    return ls.typeKeywords:Has(kind)
end

function ls.isSeparator(node, candidate)
    return candidate ~= nil and node.parent ~= nil and (candidate.kind == Kind.CommaToken or (candidate.kind == Kind.SemicolonToken and node.parent.kind == Kind.ObjectLiteralExpression))
end

local literalNameOfDeclarationParentKinds = {
    [Kind.PropertyDeclaration] = true,
    [Kind.PropertySignature] = true,
    [Kind.PropertyAssignment] = true,
    [Kind.EnumMember] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.MethodSignature] = true,
    [Kind.GetAccessor] = true,
    [Kind.SetAccessor] = true,
    [Kind.ModuleDeclaration] = true,
}

function ls.isLiteralNameOfPropertyDeclarationOrIndexAccess(node)
    -- utilities
    local parentKind = node.parent.kind
    if literalNameOfDeclarationParentKinds[parentKind] then
        return ast.GetNameOfDeclaration(node.parent) == node
    elseif parentKind == Kind.ElementAccessExpression then
        return node.parent:AsElementAccessExpression().argumentExpression == node
    elseif parentKind == Kind.ComputedPropertyName then
        return true
    elseif parentKind == Kind.LiteralType then
        return node.parent.parent.kind == Kind.IndexedAccessType
    else
        return false
    end
end

function ls.isObjectBindingElementWithoutPropertyName(bindingElement)
    return bindingElement.kind == Kind.BindingElement and
        bindingElement.parent.kind == Kind.ObjectBindingPattern and
        bindingElement:Name().kind == Kind.Identifier and
        bindingElement:PropertyName() == nil
end

function ls.isRightSideOfPropertyAccess(node)
    return node.parent ~= nil and node.parent.kind == Kind.PropertyAccessExpression and node.parent:Name() == node
end

function ls.isStaticSymbol(symbol)
    if symbol.valueDeclaration == nil then
        return false
    end
    local modifierFlags = symbol.valueDeclaration:ModifierFlags()
    return modifierFlags & ModifierFlags.Static ~= 0
end

function ls.isImplementation(node)
    if node.flags & NodeFlags.Ambient ~= 0 then
        return not (node.kind == Kind.InterfaceDeclaration or node.kind == Kind.TypeAliasDeclaration)
    end
    if ast.IsVariableLike(node) then
        return ast.HasInitializer(node)
    end
    if ast.IsFunctionLikeDeclaration(node) then
        return node:Body() ~= nil
    end
    return ast.IsClassLike(node) or ast.IsModuleOrEnumDeclaration(node)
end

function ls.isImplementationExpression(node)
    local kind = node.kind
    if kind == Kind.ParenthesizedExpression then
        return ls.isImplementationExpression(node:Expression())
    elseif kind == Kind.ArrowFunction or kind == Kind.FunctionExpression or kind == Kind.ObjectLiteralExpression or kind == Kind.ClassExpression or kind == Kind.ArrayLiteralExpression then
        return true
    else
        return false
    end
end

function ls.isReadonlyTypeOperator(node)
    return node.kind == Kind.ReadonlyKeyword and node.parent.kind == Kind.TypeOperator and node.parent:AsTypeOperatorNode().operator == Kind.ReadonlyKeyword
end

function ls.isJumpStatementTarget(node)
    return node.kind == Kind.Identifier and ast.IsBreakOrContinueStatement(node.parent) and node.parent:Label() == node
end

function ls.isLabelOfLabeledStatement(node)
    return node.kind == Kind.Identifier and node.parent.kind == Kind.LabeledStatement and node.parent:Label() == node
end

function ls.findReferenceInPosition(refs, pos)
    return core.Find(refs, function(ref)
        return ref:ContainsInclusive(pos)
    end)
end

function ls.getContainingNodeIfInHeritageClause(node)
    if node.kind == Kind.Identifier or node.kind == Kind.QualifiedName or node.kind == Kind.PropertyAccessExpression then
        return ls.getContainingNodeIfInHeritageClause(node.parent)
    end
    if (node.kind == Kind.ExpressionWithTypeArguments or node.kind == Kind.TypeReference) and
        ast.IsHeritageClause(node.parent) and
        (ast.IsClassLike(node.parent.parent) or node.parent.parent.kind == Kind.InterfaceDeclaration) then
        return node.parent.parent
    end
    return nil
end

local containerNodeKinds = {
    [Kind.SourceFile] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.MethodSignature] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.GetAccessor] = true,
    [Kind.SetAccessor] = true,
    [Kind.ClassDeclaration] = true,
    [Kind.InterfaceDeclaration] = true,
    [Kind.EnumDeclaration] = true,
    [Kind.ModuleDeclaration] = true,
}

function ls.getContainerNode(node)
    local parent = node.parent
    while parent ~= nil do
        if containerNodeKinds[parent.kind] then
            return parent
        end
        parent = parent.parent
    end
    return nil
end

function ls.getAdjustedLocation(node, forRename, sourceFile)
    -- todo: check if this function needs to be changed for jsdoc updates

    local parent = node.parent
    -- /**/<modifier> [|name|] ...
    -- /**/<modifier> <class|interface|type|enum|module|namespace|function|get|set> [|name|] ...
    -- /**/<class|interface|type|enum|module|namespace|function|get|set> [|name|] ...
    -- /**/import [|name|] = ...
    --
    -- NOTE: If the node is a modifier, we don't adjust its location if it is the `default` modifier as that is handled
    -- specially by `getSymbolAtLocation`.
    local isModifier = function(n)
        if ast.IsModifier(n) and (forRename or n.kind ~= Kind.DefaultKeyword) then
            return ast.CanHaveModifiers(parent) and core.FindIndex(parent:ModifierNodes(), function(m)
                return m == n
            end) >= 0
        end
        local kind = n.kind
        if kind == Kind.ClassKeyword then
            return ast.IsClassDeclaration(parent) or ast.IsClassExpression(n)
        elseif kind == Kind.FunctionKeyword then
            return ast.IsFunctionDeclaration(parent) or ast.IsFunctionExpression(n)
        elseif kind == Kind.InterfaceKeyword then
            return ast.IsInterfaceDeclaration(parent)
        elseif kind == Kind.EnumKeyword then
            return ast.IsEnumDeclaration(parent)
        elseif kind == Kind.TypeKeyword then
            return ast.IsTypeAliasDeclaration(parent)
        elseif kind == Kind.NamespaceKeyword or kind == Kind.ModuleKeyword then
            return ast.IsModuleDeclaration(parent)
        elseif kind == Kind.ImportKeyword then
            return ast.IsImportEqualsDeclaration(parent)
        elseif kind == Kind.GetKeyword then
            return ast.IsGetAccessorDeclaration(parent)
        elseif kind == Kind.SetKeyword then
            return ast.IsSetAccessorDeclaration(parent)
        end
        return false
    end
    if isModifier(node) then
        if sourceFile == nil then
            sourceFile = ast.GetSourceFileOfNode(node)
        end
        local location = ls.getAdjustedLocationForDeclaration(parent, forRename, sourceFile)
        if location ~= nil then
            return location
        end
    end

    -- /**/<var|let|const> [|name|] ...
    if (node.kind == Kind.VarKeyword or node.kind == Kind.ConstKeyword or node.kind == Kind.LetKeyword) and
        ast.IsVariableDeclarationList(parent) and #parent:AsVariableDeclarationList().declarations.nodes == 1 then
        local declaration = parent:AsVariableDeclarationList().declarations.nodes[1]:AsVariableDeclaration()
        if ast.IsIdentifier(declaration:Name()) then
            return declaration:Name()
        end
    end

    if node.kind == Kind.TypeKeyword then
        -- import /**/type [|name|] from ...;
        -- import /**/type { [|name|] } from ...;
        -- import /**/type { propertyName as [|name|] } from ...;
        -- import /**/type ... from "[|module|]";
        if ast.IsImportClause(parent) and parent:IsTypeOnly() then
            local location = ls.getAdjustedLocationForImportDeclaration(parent.parent:AsImportDeclaration(), forRename)
            if location ~= nil then
                return location
            end
        end
        -- export /**/type { [|name|] } from ...;
        -- export /**/type { propertyName as [|name|] } from ...;
        -- export /**/type * from "[|module|]";
        -- export /**/type * as ... from "[|module|]";
        if ast.IsExportDeclaration(parent) and parent:IsTypeOnly() then
            local location = ls.getAdjustedLocationForExportDeclaration(parent:AsExportDeclaration(), forRename)
            if location ~= nil then
                return location
            end
        end
    end

    -- import { propertyName /**/as [|name|] } ...
    -- import * /**/as [|name|] ...
    -- export { propertyName /**/as [|name|] } ...
    -- export * /**/as [|name|] ...
    if node.kind == Kind.AsKeyword then
        if parent.kind == Kind.ImportSpecifier and parent:PropertyName() ~= nil or
            parent.kind == Kind.ExportSpecifier and parent:PropertyName() ~= nil or
            parent.kind == Kind.NamespaceImport or
            parent.kind == Kind.NamespaceExport then
            return parent:Name()
        end
        if parent.kind == Kind.ExportDeclaration then
            local exportClause = parent:AsExportDeclaration().exportClause
            if exportClause ~= nil and exportClause.kind == Kind.NamespaceExport then
                return exportClause:Name()
            end
        end
    end

    -- /**/import [|name|] from ...;
    -- /**/import { [|name|] } from ...;
    -- /**/import { propertyName as [|name|] } from ...;
    -- /**/import ... from "[|module|]";
    -- /**/import "[|module|]";
    if node.kind == Kind.ImportKeyword and parent.kind == Kind.ImportDeclaration then
        local location = ls.getAdjustedLocationForImportDeclaration(parent:AsImportDeclaration(), forRename)
        if location ~= nil then
            return location
        end
    end

    if node.kind == Kind.ExportKeyword then
        -- /**/export { [|name|] } ...;
        -- /**/export { propertyName as [|name|] } ...;
        -- /**/export * from "[|module|]";
        -- /**/export * as ... from "[|module|]";
        if parent.kind == Kind.ExportDeclaration then
            local location = ls.getAdjustedLocationForExportDeclaration(parent:AsExportDeclaration(), forRename)
            if location ~= nil then
                return location
            end
        end
        -- NOTE: We don't adjust the location of the `default` keyword as that is handled specially by `getSymbolAtLocation`.
        -- /**/export default [|name|];
        -- /**/export = [|name|];
        if parent.kind == Kind.ExportAssignment then
            return ast.SkipOuterExpressions(parent:Expression(), ast.OuterExpressionKinds.OEKAll)
        end
    end
    -- import name = /**/require("[|module|]");
    if node.kind == Kind.RequireKeyword and parent.kind == Kind.ExternalModuleReference then
        return parent:Expression()
    end
    -- import ... /**/from "[|module|]";
    -- export ... /**/from "[|module|]";
    if node.kind == Kind.FromKeyword then
        if (parent.kind == Kind.ImportDeclaration or parent.kind == Kind.ExportDeclaration) and parent:ModuleSpecifier() ~= nil then
            return parent:ModuleSpecifier()
        end
    end
    -- class ... /**/extends [|name|] ...
    -- class ... /**/implements [|name|] ...
    -- class ... /**/implements name1, name2 ...
    -- interface ... /**/extends [|name|] ...
    -- interface ... /**/extends name1, name2 ...
    if (node.kind == Kind.ExtendsKeyword or node.kind == Kind.ImplementsKeyword) and parent.kind == Kind.HeritageClause and parent:AsHeritageClause().token == node.kind then
        local getAdjustedLocationForHeritageClause = function(n)
            -- /**/extends [|name|]
            -- /**/implements [|name|]
            if #n.types.nodes == 1 then
                return ast.GetHeritageClauseElementName(n.types.nodes[1])
            end

            -- fall through `getAdjustedLocation`
            --    /**/extends name1, name2 ...
            --    /**/implements name1, name2 ...
            return nil
        end

        local location = getAdjustedLocationForHeritageClause(parent:AsHeritageClause())
        if location ~= nil then
            return location
        end
    end
    if node.kind == Kind.ExtendsKeyword then
        -- ... <T /**/extends [|U|]> ...
        if parent.kind == Kind.TypeParameter then
            local constraint = parent:AsTypeParameterDeclaration().constraint
            if constraint ~= nil and constraint.kind == Kind.TypeReference then
                return constraint:AsTypeReferenceNode().typeName
            end
        end
        -- ... T /**/extends [|U|] ? ...
        if parent.kind == Kind.ConditionalType then
            local extendsType = parent:AsConditionalTypeNode().extendsType
            if extendsType ~= nil and extendsType.kind == Kind.TypeReference then
                return extendsType:AsTypeReferenceNode().typeName
            end
        end
    end
    -- ... T extends /**/infer [|U|] ? ...
    if node.kind == Kind.InferKeyword and parent.kind == Kind.InferType then
        return parent:AsInferTypeNode().typeParameter:Name()
    end
    -- { [ [|K|] /**/in keyof T]: ... }
    if node.kind == Kind.InKeyword and parent.kind == Kind.TypeParameter and parent.parent.kind == Kind.MappedType then
        return parent:Name()
    end
    -- /**/keyof [|T|]
    if node.kind == Kind.KeyOfKeyword and parent.kind == Kind.TypeOperator and parent:AsTypeOperatorNode().operator == Kind.KeyOfKeyword then
        local parentType = parent:Type()
        if parentType ~= nil and parentType.kind == Kind.TypeReference then
            return parentType:AsTypeReferenceNode().typeName
        end
    end
    -- /**/readonly [|name|][]
    if node.kind == Kind.ReadonlyKeyword and parent.kind == Kind.TypeOperator and parent:AsTypeOperatorNode().operator == Kind.ReadonlyKeyword then
        local parentType = parent:Type()
        if parentType ~= nil and parentType.kind == Kind.ArrayType and parentType:AsArrayTypeNode().elementType.kind == Kind.TypeReference then
            return parentType:AsArrayTypeNode().elementType:AsTypeReferenceNode().typeName
        end
    end

    if not forRename then
        -- /**/new [|name|]
        -- /**/void [|name|]
        -- /**/void obj.[|name|]
        -- /**/typeof [|name|]
        -- /**/typeof obj.[|name|]
        -- /**/await [|name|]
        -- /**/await obj.[|name|]
        -- /**/yield [|name|]
        -- /**/yield obj.[|name|]
        -- /**/delete obj.[|name|]
        if node.kind == Kind.NewKeyword and parent.kind == Kind.NewExpression or
            node.kind == Kind.VoidKeyword and parent.kind == Kind.VoidExpression or
            node.kind == Kind.TypeOfKeyword and parent.kind == Kind.TypeOfExpression or
            node.kind == Kind.AwaitKeyword and parent.kind == Kind.AwaitExpression or
            node.kind == Kind.YieldKeyword and parent.kind == Kind.YieldExpression or
            node.kind == Kind.DeleteKeyword and parent.kind == Kind.DeleteExpression then
            local expr = parent:Expression()
            if expr ~= nil then
                return ast.SkipOuterExpressions(expr, ast.OuterExpressionKinds.OEKAll)
            end
        end

        -- left /**/in [|name|]
        -- left /**/instanceof [|name|]
        if (node.kind == Kind.InKeyword or node.kind == Kind.InstanceOfKeyword) and parent.kind == Kind.BinaryExpression and parent:AsBinaryExpression().operatorToken == node then
            return ast.SkipOuterExpressions(parent:AsBinaryExpression().right, ast.OuterExpressionKinds.OEKAll)
        end

        -- left /**/as [|name|]
        if node.kind == Kind.AsKeyword and parent.kind == Kind.AsExpression then
            local asExprType = parent:Type()
            if asExprType ~= nil and asExprType.kind == Kind.TypeReference then
                return asExprType:AsTypeReferenceNode().typeName
            end
        end

        -- for (... /**/in [|name|])
        -- for (... /**/of [|name|])
        if node.kind == Kind.InKeyword and parent.kind == Kind.ForInStatement or
            node.kind == Kind.OfKeyword and parent.kind == Kind.ForOfStatement then
            return ast.SkipOuterExpressions(parent:Expression(), ast.OuterExpressionKinds.OEKAll)
        end
    end

    return node
end

function ls.getAdjustedLocationForDeclaration(node, forRename, sourceFile)
    if node:Name() ~= nil then
        return node:Name()
    end
    if forRename then
        return nil
    end
    local kind = node.kind
    if kind == Kind.ClassDeclaration or kind == Kind.FunctionDeclaration then
        -- for class and function declarations, use the `default` modifier
        -- when the declaration is unnamed.
        return core.Find(node:ModifierNodes(), function(_)
            return node.kind == Kind.DefaultKeyword
        end)
    elseif kind == Kind.ClassExpression then
        -- for class expressions, use the `class` keyword when the class is unnamed
        return astnav.FindChildOfKind(node, Kind.ClassKeyword, sourceFile)
    elseif kind == Kind.FunctionExpression then
        -- for function expressions, use the `function` keyword when the function is unnamed
        return astnav.FindChildOfKind(node, Kind.FunctionKeyword, sourceFile)
    elseif kind == Kind.Constructor then
        return node
    end
    return nil
end

function ls.getAdjustedLocationForImportDeclaration(node, forRename)
    if node.importClause ~= nil then
        local name = node.importClause:Name()
        if name ~= nil then
            if node.importClause:AsImportClause().namedBindings ~= nil then
                -- do not adjust if we have both a name and named bindings
                return nil
            end
            -- /**/import [|name|] from ...;
            -- import /**/type [|name|] from ...;
            return node.importClause:Name()
        end

        -- /**/import { [|name|] } from ...;
        -- /**/import { propertyName as [|name|] } from ...;
        -- /**/import * as [|name|] from ...;
        -- import /**/type { [|name|] } from ...;
        -- import /**/type { propertyName as [|name|] } from ...;
        -- import /**/type * as [|name|] from ...;
        local namedBindings = node.importClause:AsImportClause().namedBindings
        if namedBindings ~= nil then
            if namedBindings.kind == Kind.NamedImports then
                -- do nothing if there is more than one binding
                local elements = namedBindings:Elements()
                if core.Len(elements) ~= 1 then
                    return nil
                end
                return elements[1]:Name()
            elseif namedBindings.kind == Kind.NamespaceImport then
                return namedBindings:Name()
            end
        end
    end
    if not forRename then
        -- /**/import "[|module|]";
        -- /**/import ... from "[|module|]";
        -- import /**/type ... from "[|module|]";
        return node.moduleSpecifier
    end
    return nil
end

function ls.getAdjustedLocationForExportDeclaration(node, forRename)
    if node.exportClause ~= nil then
        -- /**/export { [|name|] } ...
        -- /**/export { propertyName as [|name|] } ...
        -- /**/export * as [|name|] ...
        -- export /**/type { [|name|] } from ...
        -- export /**/type { propertyName as [|name|] } from ...
        -- export /**/type * as [|name|] ...
        if node.exportClause.kind == Kind.NamedExports then
            -- do nothing if there is more than one binding
            local elements = node.exportClause:Elements()
            if core.Len(elements) ~= 1 then
                return nil
            end
            return elements[1]:Name()
        elseif node.exportClause.kind == Kind.NamespaceExport then
            return node.exportClause:Name()
        end
    end
    if not forRename then
        -- /**/export * from "[|module|]";
        -- export /**/type * from "[|module|]";
        return node.moduleSpecifier
    end
    return nil
end

function ls.symbolFlagsHaveMeaning(flags, meaning)
    if meaning == SemanticMeaning.All then
        return true
    end
    if meaning & SemanticMeaning.Value ~= 0 then
        return flags & SymbolFlags.Value ~= 0
    end
    if meaning & SemanticMeaning.Type ~= 0 then
        return flags & SymbolFlags.Type ~= 0
    end
    if meaning & SemanticMeaning.Namespace ~= 0 then
        return flags & SymbolFlags.Namespace ~= 0
    end
    return false
end

function ls.getMeaningFromLocation(node)
    -- todo: check if this function needs to be changed for jsdoc updates
    node = ls.getAdjustedLocation(ast.GetReparsedNodeForNode(node), false --[[forRename]], nil)
    local parent = node.parent
    if ast.IsSourceFile(node) then
        return SemanticMeaning.Value
    elseif ast.NodeKindIs(parent, Kind.ExportAssignment, Kind.ExportSpecifier, Kind.ExternalModuleReference, Kind.ImportSpecifier, Kind.ImportClause) or parent.kind == Kind.ImportEqualsDeclaration and node == parent:Name() then
        return SemanticMeaning.All
    elseif ls.isInRightSideOfInternalImportEqualsDeclaration(node) then
        --     import a = |b|; // Namespace
        --     import a = |b.c|; // Value, type, namespace
        --     import a = |b.c|.d; // Namespace
        local name = node
        if node.kind ~= Kind.QualifiedName then
            name = core.IfElse(node.parent.kind == Kind.QualifiedName and node.parent:AsQualifiedName().right == node, node.parent, nil)
        end
        if name ~= nil and name.parent.kind == Kind.ImportEqualsDeclaration then
            return SemanticMeaning.All
        end
        return SemanticMeaning.Namespace
    elseif ast.IsDeclarationName(node) then
        return ls.getMeaningFromDeclaration(parent)
    elseif ast.IsEntityName(node) and ast.IsJSDocNameReferenceContext(node) then
        return SemanticMeaning.All
    elseif ls.isTypeReference(node) then
        return SemanticMeaning.Type
    elseif ls.isNamespaceReference(node) then
        return SemanticMeaning.Namespace
    elseif ast.IsTypeParameterDeclaration(parent) then
        return SemanticMeaning.Type
    elseif ast.IsLiteralTypeNode(parent) then
        -- This might be T["name"], which is actually referencing a property and not a type. So allow both meanings.
        return SemanticMeaning.Type | SemanticMeaning.Value
    else
        return SemanticMeaning.Value
    end
end

local meaningValueKinds = {
    [Kind.VariableDeclaration] = true,
    [Kind.Parameter] = true,
    [Kind.BindingElement] = true,
    [Kind.PropertyDeclaration] = true,
    [Kind.PropertySignature] = true,
    [Kind.PropertyAssignment] = true,
    [Kind.ShorthandPropertyAssignment] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.MethodSignature] = true,
    [Kind.Constructor] = true,
    [Kind.GetAccessor] = true,
    [Kind.SetAccessor] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.ArrowFunction] = true,
    [Kind.CatchClause] = true,
    [Kind.JsxAttribute] = true,
}

local meaningTypeKinds = {
    [Kind.TypeParameter] = true,
    [Kind.InterfaceDeclaration] = true,
    [Kind.TypeAliasDeclaration] = true,
    [Kind.JSTypeAliasDeclaration] = true,
    [Kind.TypeLiteral] = true,
}

local meaningAllKinds = {
    [Kind.EnumDeclaration] = true,
    [Kind.NamedImports] = true,
    [Kind.ImportSpecifier] = true,
    [Kind.ImportEqualsDeclaration] = true,
    [Kind.ImportDeclaration] = true,
    [Kind.JSImportDeclaration] = true,
    [Kind.ExportAssignment] = true,
    [Kind.ExportDeclaration] = true,
}

function ls.getMeaningFromDeclaration(node)
    local kind = node.kind
    if meaningValueKinds[kind] then
        return SemanticMeaning.Value
    elseif meaningTypeKinds[kind] then
        return SemanticMeaning.Type
    elseif kind == Kind.EnumMember or kind == Kind.ClassDeclaration then
        return SemanticMeaning.Value | SemanticMeaning.Type
    elseif kind == Kind.ModuleDeclaration then
        if ast.IsAmbientModule(node) then
            return SemanticMeaning.Namespace | SemanticMeaning.Value
        elseif ast.GetModuleInstanceState(node) == ast.ModuleInstanceState.Instantiated then
            return SemanticMeaning.Namespace | SemanticMeaning.Value
        else
            return SemanticMeaning.Namespace
        end
    elseif meaningAllKinds[kind] then
        return SemanticMeaning.All
    elseif kind == Kind.SourceFile then
        -- An external module can be a Value
        return SemanticMeaning.Namespace | SemanticMeaning.Value
    end

    return SemanticMeaning.All
end

function ls.getIntersectingMeaningFromDeclarations(node, symbol, defaultMeaning)
    if node == nil then
        return defaultMeaning
    end

    local meaning = ls.getMeaningFromLocation(node)
    local declarations = symbol.declarations
    if core.Len(declarations) == 0 then
        return meaning
    end

    local lastIterationMeaning = meaning

    -- !!! TODO check if the port is correct and the for loop is needed
    local iteration = function(m)
        for _, declaration in ipairs(declarations) do
            local declarationMeaning = ls.getMeaningFromDeclaration(declaration)

            if declarationMeaning & m ~= 0 then
                m = m | declarationMeaning
            end
        end
        return m
    end
    meaning = iteration(meaning)

    while meaning ~= lastIterationMeaning do
        -- The result is order-sensitive, for instance if initialMeaning == Namespace, and declarations = [class, instantiated module]
        -- we need to consider both as the initialMeaning intersects with the module in the namespace space, and the module
        -- intersects with the class in the value space.
        -- To achieve that we will keep iterating until the result stabilizes.

        -- Remember the last meaning
        lastIterationMeaning = meaning
        meaning = iteration(meaning)
    end

    return meaning
end

-- Returns the node in an `extends` or `implements` clause of a class or interface.
function ls.getAllSuperTypeNodes(node)
    if ast.IsInterfaceDeclaration(node) then
        return ast.GetHeritageElements(node, Kind.ExtendsKeyword)
    end
    if ast.IsClassLike(node) then
        return core.AppendAll(
            core.SingleElementSlice(ast.GetClassExtendsHeritageElement(node)),
            ast.GetImplementsHeritageClauseElements(node)
        )
    end
    return nil
end

function ls.getParentSymbolsOfPropertyAccess(location, symbol, ch)
    if not ls.isRightSideOfPropertyAccess(location) then
        return nil
    end
    local lhsType = ch:GetTypeAtLocation(location.parent:Expression())
    if lhsType == nil then
        return nil
    end
    local possibleSymbols
    if lhsType:Flags() & checker.TypeFlags.UnionOrIntersection ~= 0 then
        possibleSymbols = lhsType:Types()
    elseif lhsType:Symbol() ~= symbol.parent then
        possibleSymbols = { lhsType }
    end
    return core.MapNonNil(possibleSymbols, function(t)
        if t:Symbol() ~= nil and t:Symbol().flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
            return t:Symbol()
        end
        return nil
    end)
end

-- Find symbol of the given property-name and add the symbol to the given result array
-- @param symbol a symbol to start searching for the given propertyName
-- @param propertyName a name of property to search for
-- @param cb a cache of symbol from previous iterations of calling this function to prevent infinite revisiting of the same symbol.
--
--	The value of previousIterationSymbol is undefined when the function is first called.
function ls.getPropertySymbolsFromBaseTypes(symbol, propertyName, ch, cb)
    local seen = collections.NewSet()
    local recur
    recur = function(sym)
        -- Use `addToSeen` to ensure we don't infinitely recurse in this situation:
        --      interface C extends C {
        --          /*findRef*/propName: string;
        --      }
        if sym.flags & (SymbolFlags.Class | SymbolFlags.Interface) == 0 or not seen:AddIfAbsent(sym) then
            return nil
        end
        for _, declaration in ipairs(sym.declarations or {}) do
            for _, typeReference in ipairs(ls.getAllSuperTypeNodes(declaration) or {}) do
                local propertyType = ch:GetTypeAtLocation(typeReference)
                if propertyType ~= nil and propertyType:Symbol() ~= nil then
                    -- Visit the typeReference as well to see if it directly or indirectly uses that property
                    local propertySymbol = ch:GetPropertyOfType(propertyType, propertyName)
                    if propertySymbol ~= nil then
                        for _, rootSymbol in ipairs(ch:GetRootSymbols(propertySymbol) or {}) do
                            local result = cb(rootSymbol)
                            if result ~= nil then
                                return result
                            end
                        end
                    end
                    local result = recur(propertyType:Symbol())
                    if result ~= nil then
                        return result
                    end
                end
            end
        end
        return nil
    end
    return recur(symbol)
end

function ls.getPropertySymbolFromBindingElement(ch, bindingElement)
    local typeOfPattern = ch:GetTypeAtLocation(bindingElement.parent)
    if typeOfPattern ~= nil then
        return ch:GetPropertyOfType(typeOfPattern, bindingElement:Name():Text())
    end
    return nil
end

function ls.getPropertySymbolOfObjectBindingPatternWithoutPropertyName(symbol, ch)
    local bindingElement = ast.GetDeclarationOfKind(symbol, Kind.BindingElement)
    if bindingElement ~= nil and ls.isObjectBindingElementWithoutPropertyName(bindingElement) then
        return ls.getPropertySymbolFromBindingElement(ch, bindingElement)
    end
    return nil
end

function ls.getTargetLabel(referenceNode, labelName)
    -- todo: rewrite as `ast.FindAncestor`
    while referenceNode ~= nil do
        if referenceNode.kind == Kind.LabeledStatement and referenceNode:Label():Text() == labelName then
            return referenceNode:Label()
        end
        referenceNode = referenceNode.parent
    end
    return nil
end

function ls.skipConstraint(t, typeChecker)
    if t:IsTypeParameter() then
        local c = typeChecker:GetBaseConstraintOfType(t)
        if c ~= nil then
            return c
        end
    end
    return t
end

-- caseClauseTrackerState: { existingStrings, existingNumbers, existingBigInts } (collections.Set;
-- big ints are keyed by their String() form, the Lua stand-in for Go struct map keys).
local caseClauseTrackerState = {}
caseClauseTrackerState.__index = caseClauseTrackerState
ls.caseClauseTrackerState = caseClauseTrackerState

-- trackerAddValue: string | jsnum.Number
-- trackerHasValue: string | jsnum.Number | jsnum.PseudoBigInt

function caseClauseTrackerState:addValue(value)
    local tv = type(value)
    if tv == "string" then
        self.existingStrings:Add(value)
    elseif tv == "number" then
        self.existingNumbers:Add(value)
    else
        error("Unsupported type: " .. tv, 0)
    end
end

local function bigIntKey(v)
    return v:String()
end

function caseClauseTrackerState:hasValue(value)
    local tv = type(value)
    if tv == "string" then
        return self.existingStrings:Has(value)
    elseif tv == "number" then
        return self.existingNumbers:Has(value)
    elseif getmetatable(value) == jsnum.PseudoBigInt then
        return self.existingBigInts:Has(bigIntKey(value))
    else
        error("Unsupported type: " .. tv, 0)
    end
end

function ls.newCaseClauseTracker(typeChecker, clauses)
    local c = setmetatable({
        existingStrings = collections.NewSet(),
        existingNumbers = collections.NewSet(),
        existingBigInts = collections.NewSet(),
    }, caseClauseTrackerState)
    for _, clause in ipairs(clauses or {}) do
        if not ast.IsDefaultClause(clause) then
            local expression = ast.SkipParentheses(clause:Expression())
            if ast.IsLiteralExpression(expression) then
                local kind = expression.kind
                if kind == Kind.NoSubstitutionTemplateLiteral or kind == Kind.StringLiteral then
                    c.existingStrings:Add(expression:Text())
                elseif kind == Kind.NumericLiteral then
                    c.existingNumbers:Add(jsnum.FromString(expression:Text()))
                elseif kind == Kind.BigIntLiteral then
                    c.existingBigInts:Add(bigIntKey(jsnum.ParseValidBigInt(expression:Text())))
                end
            else
                local symbol = typeChecker:GetSymbolAtLocation(clause:Expression())
                if symbol ~= nil and symbol.valueDeclaration ~= nil and ast.IsEnumMember(symbol.valueDeclaration) then
                    local enumValue = typeChecker:GetConstantValue(symbol.valueDeclaration)
                    if enumValue ~= nil then
                        c:addValue(enumValue)
                    end
                end
            end
        end
    end
    return c
end

function ls.RangeContainsRange(r1, r2)
    return ls.startEndContainsRange(r1:Pos(), r1:End(), r2)
end

function ls.startEndContainsRange(start, end_, textRange)
    return start <= textRange:Pos() and end_ >= textRange:End()
end

function ls.getPossibleGenericSignatures(called, typeArgumentCount, c)
    local typeAtLocation = c:GetTypeAtLocation(called)
    if ast.IsOptionalChain(called.parent) then
        typeAtLocation = ls.removeOptionality(typeAtLocation, ast.IsOptionalChainRoot(called.parent), true --[[isOptionalChain]], c)
    end
    local signatures
    if ast.IsNewExpression(called.parent) then
        signatures = c:GetSignaturesOfType(typeAtLocation, checker.SignatureKind.Construct)
    else
        signatures = c:GetSignaturesOfType(typeAtLocation, checker.SignatureKind.Call)
    end
    return core.Filter(signatures, function(s)
        return s:TypeParameters() ~= nil and #s:TypeParameters() >= typeArgumentCount
    end)
end

function ls.removeOptionality(t, isOptionalExpression, isOptionalChain, c)
    if isOptionalExpression then
        return c:GetNonNullableType(t)
    elseif isOptionalChain then
        return c:GetNonOptionalType(t)
    end
    return t
end

function ls.isNoSubstitutionTemplateLiteral(node)
    return node.kind == Kind.NoSubstitutionTemplateLiteral
end

function ls.isTaggedTemplateExpression(node)
    return node.kind == Kind.TaggedTemplateExpression
end

function ls.isInsideTemplateLiteral(node, position, sourceFile)
    return ast.IsTemplateLiteralKind(node.kind) and (scanner.GetTokenPosOfNode(node, sourceFile, false) < position and position < node:End() or (ast.IsUnterminatedLiteral(node) and position == node:End()))
end

-- Pseudo-literals
function ls.isTemplateHead(node)
    return node.kind == Kind.TemplateHead
end

function ls.isTemplateTail(node)
    return node.kind == Kind.TemplateTail
end

function ls.findPrecedingMatchingToken(token, matchingTokenKind, sourceFile)
    local closeTokenText = scanner.TokenToString(token.kind)
    local matchingTokenText = scanner.TokenToString(matchingTokenKind)
    -- Text-scan based fast path - can be bamboozled by comments and other trivia, but often provides
    -- a good, fast approximation without too much extra work in the cases where it fails.
    local bestGuessIndex = strings.LastIndex(sourceFile:Text(), matchingTokenText)
    if bestGuessIndex == -1 then
        return nil -- if the token text doesn't appear in the file, there can't be a match - super fast bail
    end
    -- we can only use the textual result directly if we didn't have to count any close tokens within the range
    if strings.LastIndex(sourceFile:Text(), closeTokenText) < bestGuessIndex then
        local nodeAtGuess = astnav.FindPrecedingToken(sourceFile, bestGuessIndex + 1)
        if nodeAtGuess ~= nil and nodeAtGuess.kind == matchingTokenKind then
            return nodeAtGuess
        end
    end
    local tokenKind = token.kind
    local remainingMatchingTokens = 0
    while true do
        local preceding = astnav.FindPrecedingToken(sourceFile, token:Pos())
        if preceding == nil then
            return nil
        end
        token = preceding
        if token.kind == matchingTokenKind then
            if remainingMatchingTokens == 0 then
                return token
            end
            remainingMatchingTokens = remainingMatchingTokens - 1
        elseif token.kind == tokenKind then
            remainingMatchingTokens = remainingMatchingTokens + 1
        end
    end
end

function ls.findContainingList(node, file)
    -- The node might be a list element (nonsynthetic) or a comma (synthetic). Either way, it will
    -- be parented by the container of the SyntaxList, not the SyntaxList itself.
    local list
    local visitNode = function(n, _)
        return n
    end
    local visitNodes = function(nodes, _)
        if nodes ~= nil and ls.RangeContainsRange(nodes.loc, node.loc) then
            list = nodes
        end
        return nodes
    end
    astnav.VisitEachChildAndJSDoc(node.parent, file, visitNode, visitNodes)
    return list
end

-- Returns a Lua iterator over ast.CommentRange (Go iter.Seq), or nil.
function ls.getLeadingCommentRangesOfNode(node, file)
    if node.kind == Kind.JsxText then
        return nil
    end
    return scanner.GetLeadingCommentRanges(ast.NewNodeFactory({}), file:Text(), node:Pos())
end

-- Equivalent to Strada's `node.getChildren()` for non-JSDoc nodes.
function ls.getChildrenFromNonJSDocNode(node, sourceFile)
    local childNodes = {}
    node:ForEachChild(function(child)
        childNodes[#childNodes + 1] = child
        return false
    end)

    -- If the node has no children, don't scan for tokens.
    -- This prevents creating tokens for leaf nodes' own text.
    if #childNodes == 0 then
        return nil
    end

    local children = {}
    local pos = node:Pos()
    for _, child in ipairs(childNodes) do
        local s = scanner.GetScannerForSourceFile(sourceFile, pos)
        while pos < child:Pos() do
            local token = s:Token()
            local tokenFullStart = s:TokenFullStart()
            local tokenEnd = s:TokenEnd()
            children[#children + 1] = sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, node, s:TokenFlags())
            pos = tokenEnd
            s:Scan()
        end
        children[#children + 1] = child
        pos = child:End()
    end
    local s = scanner.GetScannerForSourceFile(sourceFile, pos)
    while pos < node:End() do
        local token = s:Token()
        local tokenFullStart = s:TokenFullStart()
        local tokenEnd = s:TokenEnd()
        children[#children + 1] = sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, node, s:TokenFlags())
        pos = tokenEnd
        s:Scan()
    end
    return children
end

-- Returns the containing object literal property declaration given a possible name node, e.g. "a" in x = { "a": 1 }
function ls.getContainingObjectLiteralElement(node)
    local element = ls.getContainingObjectLiteralElementWorker(node)
    if element ~= nil and (ast.IsObjectLiteralExpression(element.parent) or ast.IsJsxAttributes(element.parent)) then
        return element
    end
    return nil
end

function ls.getContainingObjectLiteralElementWorker(node)
    local kind = node.kind
    if kind == Kind.StringLiteral or kind == Kind.NoSubstitutionTemplateLiteral or kind == Kind.NumericLiteral then
        if node.parent.kind == Kind.ComputedPropertyName then
            if ls.isObjectLiteralOrJsxElement(node.parent.parent) then
                return node.parent.parent
            end
            return nil
        end
        kind = Kind.Identifier -- fallthrough
    end
    if kind == Kind.Identifier or kind == Kind.JsxNamespacedName then
        if ls.isObjectLiteralOrJsxElement(node.parent) and (node.parent.parent.kind == Kind.ObjectLiteralExpression or node.parent.parent.kind == Kind.JsxAttributes) and node.parent:Name() == node then
            return node.parent
        end
    end
    return nil
end

function ls.isObjectLiteralOrJsxElement(node)
    return ast.IsObjectLiteralElement(node) or ast.IsJsxAttribute(node) or ast.IsJsxSpreadAttribute(node)
end

-- Return a function that returns true if the given node has not been seen
function ls.nodeSeenTracker()
    local seen = collections.NewSet()
    return function(node)
        return seen:AddIfAbsent(node)
    end
end

-- FindAllReferences.toContextSpan
-- textRange is a *core.TextRange (nil-able); returns a *core.TextRange or nil.
function ls.toContextRange(textRange, contextFile, context)
    if context == nil then
        return textRange
    end
    -- !!! isContextWithStartAndEndNode
    local contextRange = ls.getRangeOfNode(context, contextFile, nil --[[endNode]])
    if contextRange:Pos() ~= textRange:Pos() or contextRange:End() ~= textRange:End() then
        return contextRange
    end
    return nil
end

function ls.getReferenceAtPosition(sourceFile, position, program)
    local referencePath = ls.findReferenceInPosition(sourceFile.referencedFiles, position)
    if referencePath ~= nil then
        local file = program:GetSourceFileFromReference(sourceFile, referencePath)
        if file ~= nil then
            return { reference = referencePath, fileName = file:FileName(), file = file, unverified = false }
        end
        return nil
    end

    local typeReferenceDirective = ls.findReferenceInPosition(sourceFile.typeReferenceDirectives, position)
    if typeReferenceDirective ~= nil then
        local reference = program:GetResolvedTypeReferenceDirectiveFromTypeReferenceDirective(typeReferenceDirective, sourceFile)
        if reference ~= nil then
            local file = program:GetSourceFile(reference.resolvedFileName)
            if file ~= nil then
                return { reference = typeReferenceDirective, fileName = file:FileName(), file = file, unverified = false }
            end
        end
        return nil
    end

    local libReferenceDirective = ls.findReferenceInPosition(sourceFile.libReferenceDirectives, position)
    if libReferenceDirective ~= nil then
        local file = program:GetLibFileFromReference(libReferenceDirective)
        if file ~= nil then
            return { reference = libReferenceDirective, fileName = file:FileName(), file = file, unverified = false }
        end
        return nil
    end

    if core.Len(sourceFile:Imports()) == 0 and core.Len(sourceFile.moduleAugmentations) == 0 then
        return nil
    end

    local node = astnav.GetTouchingToken(sourceFile, position)
    if not ls.isModuleSpecifierLike(node) or not tspath.IsExternalModuleNameRelative(node:Text()) then
        return nil
    end

    local resolution = program:GetResolvedModuleFromModuleSpecifier(sourceFile, node)
    if resolution ~= nil then
        local verifiedFileName = resolution.resolvedFileName
        local fileName = resolution.resolvedFileName
        if fileName == "" then
            fileName = tspath.ResolvePath(tspath.GetDirectoryPath(sourceFile:FileName()), node:Text())
        end
        return {
            file = program:GetSourceFile(fileName),
            fileName = fileName,
            reference = nil,
            unverified = verifiedFileName ~= "",
        }
    end

    return nil
end

function ls.getContextualTypeFromParent(node, typeChecker, contextFlags)
    local parent = ast.WalkUpParenthesizedExpressions(node.parent)
    local kind = parent.kind
    if kind == Kind.NewExpression then
        return typeChecker:GetContextualType(parent, contextFlags)
    elseif kind == Kind.BinaryExpression then
        if ls.isEqualityOperatorKind(parent:AsBinaryExpression().operatorToken.kind) then
            return typeChecker:GetTypeAtLocation(
                core.IfElse(node == parent:AsBinaryExpression().right, parent:AsBinaryExpression().left, parent:AsBinaryExpression().right)
            )
        end
        return typeChecker:GetContextualType(node, contextFlags)
    elseif kind == Kind.CaseClause then
        return ls.getSwitchedType(parent, typeChecker)
    else
        return typeChecker:GetContextualType(node, contextFlags)
    end
end

function ls.getContextualTypeFromParentOrAncestorTypeNode(node, typeChecker)
    if node.flags & NodeFlags.JSDoc ~= 0 and node.flags & NodeFlags.JavaScriptFile == 0 then
        return nil
    end

    local contextualType = ls.getContextualTypeFromParent(node, typeChecker, checker.ContextFlags.None)
    if contextualType ~= nil then
        return contextualType
    end

    local ancestorTypeNode = ls.getAncestorTypeNode(node)
    if ancestorTypeNode ~= nil then
        return typeChecker:GetTypeAtLocation(ancestorTypeNode)
    end

    return nil
end

function ls.getAncestorTypeNode(node)
    local lastTypeNode
    ast.FindAncestor(node, function(n)
        if ast.IsTypeNode(n) then
            lastTypeNode = n
        end
        return not ast.IsQualifiedName(n.parent) and not ast.IsTypeNode(n.parent) and not ast.IsTypeElement(n.parent)
    end)
    return lastTypeNode
end

function ls.isSourceFileWithGlobalExports(node)
    return node ~= nil and ast.IsSourceFile(node) and node:AsSourceFile().globalExports ~= nil
end
