local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local OuterExpressionKinds = ast.OuterExpressionKinds
local FindAncestorResult = ast.FindAncestorResult
local JSDeclarationKind = ast.JSDeclarationKind
local SemanticMeaning = ast.SemanticMeaning
local kindSet = ast.kindSet

-- Atomic ids

ast.nextNodeId = 0
ast.nextSymbolId = 0

function ast.GetNodeId(node)
    local id = node.id
    if id == nil or id == 0 then
        ast.nextNodeId = ast.nextNodeId + 1
        id = ast.nextNodeId
        node.id = id
    end
    return id
end

function ast.GetSymbolId(symbol)
    local id = symbol.id
    if id == nil or id == 0 then
        ast.nextSymbolId = ast.nextSymbolId + 1
        id = ast.nextSymbolId
        symbol.id = id
    end
    return id
end

-- Go GetSymbolTable(data *SymbolTable) takes a pointer to a field. In Lua it takes the owner table
-- and the field name: ast.GetSymbolTable(symbol, "members").
function ast.GetSymbolTable(owner, field)
    local t = owner[field]
    if t == nil then
        t = {}
        owner[field] = t
    end
    return t
end

function ast.GetMembers(symbol)
    return ast.GetSymbolTable(symbol, "members")
end

function ast.GetExports(symbol)
    return ast.GetSymbolTable(symbol, "exports")
end

function ast.GetLocals(container)
    return ast.GetSymbolTable(container:LocalsContainerData(), "locals")
end

-- Determines if a node is missing (either `nil` or empty)
function ast.NodeIsMissing(node)
    return node == nil or node.loc.pos == node.loc.end_ and node.loc.pos >= 0 and node.kind ~= Kind.EndOfFile
end

-- Determines if a node is present
function ast.NodeIsPresent(node)
    return not ast.NodeIsMissing(node)
end

-- Determines if a node contains synthetic positions
function ast.NodeIsSynthesized(node)
    return ast.PositionIsSynthesized(node.loc.pos) or ast.PositionIsSynthesized(node.loc.end_)
end

function ast.RangeIsSynthesized(loc)
    return ast.PositionIsSynthesized(loc.pos) or ast.PositionIsSynthesized(loc.end_)
end

-- Determines whether a position is synthetic
function ast.PositionIsSynthesized(pos)
    return pos < 0
end

function ast.FindLastVisibleNode(nodes)
    local n = core.Len(nodes)
    local fromEnd = 1
    while fromEnd <= n and nodes[n - fromEnd + 1].flags & NodeFlags.Reparsed ~= 0 do
        fromEnd = fromEnd + 1
    end
    if fromEnd <= n then
        return nodes[n - fromEnd + 1]
    end
    return nil
end

function ast.NodeKindIs(node, ...)
    for _, k in ipairs({ ... }) do
        if node.kind == k then
            return true
        end
    end
    return false
end

function ast.IsModifier(node)
    return ast.IsModifierKind(node.kind)
end

function ast.IsModifierLike(node)
    return ast.IsModifier(node) or ast.IsDecorator(node)
end

function ast.IsCompoundAssignment(token)
    return token >= Kind.FirstCompoundAssignment and token <= Kind.LastCompoundAssignment
end

function ast.IsAssignmentExpression(node, excludeCompoundAssignment)
    if node.kind == Kind.BinaryExpression then
        local expr = node
        return (expr.operatorToken.kind == Kind.EqualsToken or not excludeCompoundAssignment and ast.IsAssignmentOperator(expr.operatorToken.kind)) and
            ast.IsLeftHandSideExpression(expr.left)
    end
    return false
end

function ast.GetRightMostAssignedExpression(node)
    while ast.IsAssignmentExpression(node, false --[[excludeCompoundAssignment]]) do
        node = node.right
    end
    return node
end

function ast.IsDestructuringAssignment(node)
    if ast.IsAssignmentExpression(node, true --[[excludeCompoundAssignment]]) then
        local kind = node.left.kind
        return kind == Kind.ObjectLiteralExpression or kind == Kind.ArrayLiteralExpression
    end
    return false
end

local objectBindingOrAssignmentElementKinds = kindSet(Kind.BindingElement, Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment, Kind.SpreadAssignment)

function ast.IsObjectBindingOrAssignmentElement(node)
    return objectBindingOrAssignmentElementKinds[node.kind] == true
end

local arrayBindingOrAssignmentElementKinds = kindSet(Kind.BindingElement, Kind.OmittedExpression, Kind.SpreadElement,
    Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression, Kind.Identifier, Kind.PropertyAccessExpression,
    Kind.ElementAccessExpression)

function ast.IsArrayBindingOrAssignmentElement(node)
    if arrayBindingOrAssignmentElementKinds[node.kind] then
        return true
    end
    return ast.IsAssignmentExpression(node, true --[[excludeCompoundAssignment]])
end

function ast.IsBindingPattern(node)
    return node.kind == Kind.ObjectBindingPattern or node.kind == Kind.ArrayBindingPattern
end

function ast.IsForInOrOfStatement(node)
    return node ~= nil and (node.kind == Kind.ForInStatement or node.kind == Kind.ForOfStatement)
end

-- A node is an assignment target if it is on the left hand side of an '=' token, if it is parented by a property
-- assignment in an object literal that is an assignment target, or if it is parented by an array literal that is
-- an assignment target. Examples include 'a = xxx', '{ p: a } = xxx', '[{ a }] = xxx'.
-- (Note that `p` is not a target in the above examples, only `a`.)
function ast.IsAssignmentTarget(node)
    return ast.GetAssignmentTarget(node) ~= nil
end

-- Returns the BinaryExpression, PrefixUnaryExpression, PostfixUnaryExpression, or ForInOrOfStatement that references
-- the given node as an assignment target
function ast.GetAssignmentTarget(node)
    while true do
        local parent = node.parent
        local kind = parent.kind
        if kind == Kind.BinaryExpression then
            if ast.IsAssignmentOperator(parent.operatorToken.kind) and parent.left == node then
                return parent
            end
            return nil
        elseif kind == Kind.PrefixUnaryExpression or kind == Kind.PostfixUnaryExpression then
            if parent.operator == Kind.PlusPlusToken or parent.operator == Kind.MinusMinusToken then
                return parent
            end
            return nil
        elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
            if parent:Initializer() == node then
                return parent
            end
            return nil
        elseif kind == Kind.ParenthesizedExpression or kind == Kind.ArrayLiteralExpression or
            kind == Kind.SpreadElement or kind == Kind.NonNullExpression then
            node = parent
        elseif kind == Kind.SpreadAssignment then
            node = parent.parent
        elseif kind == Kind.ShorthandPropertyAssignment then
            if parent:Name() ~= node then
                return nil
            end
            node = parent.parent
        elseif kind == Kind.PropertyAssignment then
            if parent:Name() == node then
                return nil
            end
            node = parent.parent
        else
            return nil
        end
    end
end

function ast.IsLogicalBinaryOperator(token)
    return token == Kind.BarBarToken or token == Kind.AmpersandAmpersandToken
end

function ast.IsLogicalOrCoalescingBinaryOperator(token)
    return ast.IsLogicalBinaryOperator(token) or token == Kind.QuestionQuestionToken
end

function ast.IsLogicalOrCoalescingBinaryExpression(expr)
    return ast.IsBinaryExpression(expr) and ast.IsLogicalOrCoalescingBinaryOperator(expr.operatorToken.kind)
end

function ast.IsLogicalOrCoalescingAssignmentExpression(expr)
    return ast.IsBinaryExpression(expr) and ast.IsLogicalOrCoalescingAssignmentOperator(expr.operatorToken.kind)
end

function ast.IsLogicalExpression(node)
    while true do
        if node.kind == Kind.ParenthesizedExpression then
            node = node:Expression()
        elseif node.kind == Kind.PrefixUnaryExpression and node.operator == Kind.ExclamationToken then
            node = node.operand
        else
            return ast.IsLogicalOrCoalescingBinaryExpression(node)
        end
    end
end

function ast.IsAccessor(node)
    return node.kind == Kind.GetAccessor or node.kind == Kind.SetAccessor
end

local propertyNameLiteralKinds = kindSet(Kind.Identifier, Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral,
    Kind.NumericLiteral)

function ast.IsPropertyNameLiteral(node)
    return propertyNameLiteralKinds[node.kind] == true
end

function ast.IsMemberName(node)
    return node.kind == Kind.Identifier or node.kind == Kind.PrivateIdentifier
end

function ast.IsEntityName(node)
    return node.kind == Kind.Identifier or node.kind == Kind.QualifiedName
end

local propertyNameKinds = kindSet(Kind.Identifier, Kind.PrivateIdentifier, Kind.StringLiteral, Kind.NumericLiteral,
    Kind.ComputedPropertyName)

function ast.IsPropertyName(node)
    return propertyNameKinds[node.kind] == true
end

local identifierNameParentNameKinds = kindSet(Kind.PropertyDeclaration, Kind.PropertySignature,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.GetAccessor, Kind.SetAccessor, Kind.EnumMember,
    Kind.PropertyAssignment, Kind.PropertyAccessExpression)
local identifierNameAlwaysKinds = kindSet(Kind.ExportSpecifier, Kind.JsxAttribute, Kind.JsxSelfClosingElement,
    Kind.JsxOpeningElement, Kind.JsxClosingElement)

-- Return true if the given identifier is classified as an IdentifierName by inspecting the parent of the node
function ast.IsIdentifierName(node)
    local parent = node.parent
    local kind = parent.kind
    if identifierNameParentNameKinds[kind] then
        return parent:Name() == node
    elseif kind == Kind.QualifiedName then
        return parent.right == node
    elseif kind == Kind.BindingElement or kind == Kind.ImportSpecifier then
        return parent:PropertyName() == node
    elseif identifierNameAlwaysKinds[kind] then
        return true
    end
    return false
end

function ast.IsPushOrUnshiftIdentifier(node)
    local text = node:Text()
    return text == "push" or text == "unshift"
end

function ast.IsBooleanLiteral(node)
    return node.kind == Kind.TrueKeyword or node.kind == Kind.FalseKeyword
end

function ast.IsLiteralExpression(node)
    return ast.IsLiteralKind(node.kind)
end

function ast.IsStringLiteralLike(node)
    return node.kind == Kind.StringLiteral or node.kind == Kind.NoSubstitutionTemplateLiteral
end

function ast.IsStringOrNumericLiteralLike(node)
    return ast.IsStringLiteralLike(node) or ast.IsNumericLiteral(node)
end

function ast.IsSignedNumericLiteral(node)
    if node.kind == Kind.PrefixUnaryExpression then
        return (node.operator == Kind.PlusToken or node.operator == Kind.MinusToken) and ast.IsNumericLiteral(node.operand)
    end
    return false
end

local optionalChainKinds = kindSet(Kind.PropertyAccessExpression, Kind.ElementAccessExpression, Kind.CallExpression,
    Kind.NonNullExpression)

-- Determines if a node is part of an OptionalChain
function ast.IsOptionalChain(node)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        return optionalChainKinds[node.kind] == true
    end
    return false
end

function ast.getQuestionDotToken(node)
    return node:QuestionDotToken()
end

-- Determines if node is the root expression of an OptionalChain
function ast.IsOptionalChainRoot(node)
    return ast.IsOptionalChain(node) and not ast.IsNonNullExpression(node) and ast.getQuestionDotToken(node) ~= nil
end

-- Determines whether a node is the outermost `OptionalChain` in an ECMAScript `OptionalExpression`:
--
--  1. For `a?.b.c`, the outermost chain is `a?.b.c` (`c` is the end of the chain starting at `a?.`)
--  2. For `a?.b!`, the outermost chain is `a?.b` (`b` is the end of the chain starting at `a?.`)
--  3. For `(a?.b.c).d`, the outermost chain is `a?.b.c` (`c` is the end of the chain starting at `a?.` since parens end the chain)
--  4. For `a?.b.c?.d`, both `a?.b.c` and `a?.b.c?.d` are outermost (`c` is the end of the chain starting at `a?.`, and `d` is
--     the end of the chain starting at `c?.`)
--  5. For `a?.(b?.c).d`, both `b?.c` and `a?.(b?.c)d` are outermost (`c` is the end of the chain starting at `b`, and `d` is
--     the end of the chain starting at `a?.`)
function ast.IsOutermostOptionalChain(node)
    local parent = node.parent
    return not ast.IsOptionalChain(parent) or -- cases 1, 2, and 3
        ast.IsOptionalChainRoot(parent) or -- case 4
        node ~= parent:Expression() -- case 5
end

-- Determines whether a node is the expression preceding an optional chain (i.e. `a` in `a?.b`).
function ast.IsExpressionOfOptionalChainRoot(node)
    return ast.IsOptionalChainRoot(node.parent) and node.parent:Expression() == node
end

function ast.IsNullishCoalesce(node)
    return node.kind == Kind.BinaryExpression and node.operatorToken.kind == Kind.QuestionQuestionToken
end

function ast.IsAssertionExpression(node)
    local kind = node.kind
    return kind == Kind.TypeAssertionExpression or kind == Kind.AsExpression
end

local leftHandSideExpressionKinds = kindSet(Kind.PropertyAccessExpression, Kind.ElementAccessExpression,
    Kind.NewExpression, Kind.CallExpression, Kind.JsxElement, Kind.JsxSelfClosingElement, Kind.JsxFragment,
    Kind.TaggedTemplateExpression, Kind.ArrayLiteralExpression, Kind.ParenthesizedExpression,
    Kind.ObjectLiteralExpression, Kind.ClassExpression, Kind.FunctionExpression, Kind.Identifier,
    Kind.PrivateIdentifier, Kind.RegularExpressionLiteral, Kind.NumericLiteral, Kind.BigIntLiteral,
    Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral, Kind.TemplateExpression, Kind.FalseKeyword,
    Kind.NullKeyword, Kind.ThisKeyword, Kind.TrueKeyword, Kind.SuperKeyword, Kind.NonNullExpression,
    Kind.ExpressionWithTypeArguments, Kind.MetaProperty, Kind.ImportKeyword, Kind.MissingDeclaration)

function ast.isLeftHandSideExpressionKind(kind)
    return leftHandSideExpressionKinds[kind] == true
end

-- Determines whether a node is a LeftHandSideExpression based only on its kind.
function ast.IsLeftHandSideExpression(node)
    return ast.isLeftHandSideExpressionKind(ast.SkipPartiallyEmittedExpressions(node).kind)
end

local unaryExpressionKinds = kindSet(Kind.PrefixUnaryExpression, Kind.PostfixUnaryExpression, Kind.DeleteExpression,
    Kind.TypeOfExpression, Kind.VoidExpression, Kind.AwaitExpression, Kind.TypeAssertionExpression)

function ast.isUnaryExpressionKind(kind)
    if unaryExpressionKinds[kind] then
        return true
    end
    return ast.isLeftHandSideExpressionKind(kind)
end

-- Determines whether a node is a UnaryExpression based only on its kind.
function ast.IsUnaryExpression(node)
    return ast.isUnaryExpressionKind(ast.SkipPartiallyEmittedExpressions(node).kind)
end

local expressionKinds = kindSet(Kind.ConditionalExpression, Kind.YieldExpression, Kind.ArrowFunction,
    Kind.BinaryExpression, Kind.SpreadElement, Kind.AsExpression, Kind.OmittedExpression,
    Kind.PartiallyEmittedExpression, Kind.SatisfiesExpression)

function ast.isExpressionKind(kind)
    if expressionKinds[kind] then
        return true
    end
    return ast.isUnaryExpressionKind(kind)
end

-- Determines whether a node is an expression based only on its kind.
function ast.IsExpression(node)
    return ast.isExpressionKind(ast.SkipPartiallyEmittedExpressions(node).kind)
end

function ast.IsCommaExpression(node)
    return node.kind == Kind.BinaryExpression and node.operatorToken.kind == Kind.CommaToken
end

function ast.IsCommaSequence(node)
    return ast.IsCommaExpression(node)
end

local iterationStatementKinds = kindSet(Kind.ForStatement, Kind.ForInStatement, Kind.ForOfStatement,
    Kind.DoStatement, Kind.WhileStatement)

function ast.IsIterationStatement(node, lookInLabeledStatements)
    if iterationStatementKinds[node.kind] then
        return true
    elseif node.kind == Kind.LabeledStatement then
        return lookInLabeledStatements and ast.IsIterationStatement(node:Statement(), lookInLabeledStatements)
    end
    return false
end

-- Determines if a node is a property or element access expression
function ast.IsAccessExpression(node)
    return node.kind == Kind.PropertyAccessExpression or node.kind == Kind.ElementAccessExpression
end

local functionLikeDeclarationKinds = kindSet(Kind.FunctionDeclaration, Kind.MethodDeclaration, Kind.Constructor,
    Kind.GetAccessor, Kind.SetAccessor, Kind.FunctionExpression, Kind.ArrowFunction)

function ast.isFunctionLikeDeclarationKind(kind)
    return functionLikeDeclarationKinds[kind] == true
end

-- Determines if a node is function-like (but is not a signature declaration)
function ast.IsFunctionLikeDeclaration(node)
    -- TODO(rbuckton): Move `node != nil` test to call sites
    return node ~= nil and ast.isFunctionLikeDeclarationKind(node.kind)
end

local functionLikeSignatureKinds = kindSet(Kind.MethodSignature, Kind.CallSignature, Kind.JSDocSignature,
    Kind.ConstructSignature, Kind.IndexSignature, Kind.FunctionType, Kind.ConstructorType)

function ast.IsFunctionLikeKind(kind)
    if functionLikeSignatureKinds[kind] then
        return true
    end
    return ast.isFunctionLikeDeclarationKind(kind)
end

-- Determines if a node is function- or signature-like.
function ast.IsFunctionLike(node)
    -- TODO(rbuckton): Move `node != nil` test to call sites
    return node ~= nil and ast.IsFunctionLikeKind(node.kind)
end

function ast.IsFunctionLikeOrClassStaticBlockDeclaration(node)
    return node ~= nil and (ast.IsFunctionLike(node) or ast.IsClassStaticBlockDeclaration(node))
end

function ast.IsFunctionOrSourceFile(node)
    return ast.IsFunctionLike(node) or ast.IsSourceFile(node)
end

function ast.IsClassLike(node)
    return node.kind == Kind.ClassDeclaration or node.kind == Kind.ClassExpression
end

function ast.IsClassOrInterfaceLike(node)
    return node.kind == Kind.ClassDeclaration or node.kind == Kind.ClassExpression or node.kind == Kind.InterfaceDeclaration
end

local classElementKinds = kindSet(Kind.Constructor, Kind.PropertyDeclaration, Kind.MethodDeclaration, Kind.GetAccessor,
    Kind.SetAccessor, Kind.IndexSignature, Kind.ClassStaticBlockDeclaration, Kind.SemicolonClassElement)

function ast.IsClassElement(node)
    return classElementKinds[node.kind] == true
end

function ast.IsMethodOrAccessor(node)
    local kind = node.kind
    return kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor
end

function ast.IsPrivateIdentifierClassElementDeclaration(node)
    return (ast.IsPropertyDeclaration(node) or ast.IsMethodOrAccessor(node)) and ast.IsPrivateIdentifier(node:Name())
end

function ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(node)
    local kind = node.kind
    return (kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor) and
        (node.parent.kind == Kind.ObjectLiteralExpression or node.parent.kind == Kind.ClassExpression)
end

local typeElementKinds = kindSet(Kind.ConstructSignature, Kind.CallSignature, Kind.PropertySignature,
    Kind.MethodSignature, Kind.IndexSignature, Kind.GetAccessor, Kind.SetAccessor, Kind.NotEmittedTypeElement)

function ast.IsTypeElement(node)
    return typeElementKinds[node.kind] == true
end

local objectLiteralElementKinds = kindSet(Kind.PropertyAssignment, Kind.ShorthandPropertyAssignment,
    Kind.SpreadAssignment, Kind.MethodDeclaration, Kind.GetAccessor, Kind.SetAccessor)

function ast.IsObjectLiteralElement(node)
    return objectLiteralElementKinds[node.kind] == true
end

function ast.IsObjectLiteralMethod(node)
    return node ~= nil and node.kind == Kind.MethodDeclaration and node.parent.kind == Kind.ObjectLiteralExpression
end

function ast.IsAutoAccessorPropertyDeclaration(node)
    return ast.IsPropertyDeclaration(node) and ast.HasAccessorModifier(node)
end

function ast.IsParameterPropertyDeclaration(node, parent)
    return ast.IsParameterDeclaration(node) and ast.HasSyntacticModifier(node, ModifierFlags.ParameterPropertyModifier) and
        parent.kind == Kind.Constructor
end

local jsxChildKinds = kindSet(Kind.JsxElement, Kind.JsxExpression, Kind.JsxSelfClosingElement, Kind.JsxText,
    Kind.JsxFragment)

function ast.IsJsxChild(node)
    return jsxChildKinds[node.kind] == true
end

function ast.IsJsxAttributeLike(node)
    return ast.IsJsxAttribute(node) or ast.IsJsxSpreadAttribute(node)
end

local declarationStatementKinds = kindSet(Kind.FunctionDeclaration, Kind.MissingDeclaration, Kind.ClassDeclaration,
    Kind.InterfaceDeclaration, Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.EnumDeclaration,
    Kind.ModuleDeclaration, Kind.ImportDeclaration, Kind.JSImportDeclaration, Kind.ImportEqualsDeclaration,
    Kind.ExportDeclaration, Kind.ExportAssignment, Kind.NamespaceExportDeclaration)

function ast.isDeclarationStatementKind(kind)
    return declarationStatementKinds[kind] == true
end

-- Determines whether a node is a DeclarationStatement. Ideally this does not use Parent pointers, but it may use them
-- to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
--
-- NOTE: ECMA262 would just call this a Declaration
function ast.IsDeclarationStatement(node)
    return ast.isDeclarationStatementKind(node.kind)
end

local statementButNotDeclarationKinds = kindSet(Kind.BreakStatement, Kind.ContinueStatement, Kind.DebuggerStatement,
    Kind.DoStatement, Kind.ExpressionStatement, Kind.EmptyStatement, Kind.ForInStatement, Kind.ForOfStatement,
    Kind.ForStatement, Kind.IfStatement, Kind.LabeledStatement, Kind.ReturnStatement, Kind.SwitchStatement,
    Kind.ThrowStatement, Kind.TryStatement, Kind.VariableStatement, Kind.WhileStatement, Kind.WithStatement,
    Kind.NotEmittedStatement)

function ast.isStatementKindButNotDeclarationKind(kind)
    return statementButNotDeclarationKinds[kind] == true
end

-- Determines whether a node is a Statement that is not also a Declaration. Ideally this does not use Parent pointers,
-- but it may use them to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
--
-- NOTE: ECMA262 would just call this a Statement
function ast.IsStatementButNotDeclaration(node)
    return ast.isStatementKindButNotDeclarationKind(node.kind)
end

-- Determines whether a node is a Statement. Ideally this does not use Parent pointers, but it may use
-- them to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
--
-- NOTE: ECMA262 would call this either a StatementListItem or ModuleListItem
function ast.IsStatement(node)
    local kind = node.kind
    return ast.isStatementKindButNotDeclarationKind(kind) or ast.isDeclarationStatementKind(kind) or ast.isBlockStatement(node)
end

-- Determines whether a node is a BlockStatement. If parents are available, this ensures the Block is
-- not part of a `try` statement, `catch` clause, or the Block-like body of a function
function ast.isBlockStatement(node)
    if node.kind ~= Kind.Block then
        return false
    end
    if node.parent ~= nil and (node.parent.kind == Kind.TryStatement or node.parent.kind == Kind.CatchClause) then
        return false
    end
    return not ast.IsFunctionBlock(node)
end

-- Determines whether a node is the Block-like body of a function by walking the parent of the node
function ast.IsFunctionBlock(node)
    return node ~= nil and node.kind == Kind.Block and node.parent ~= nil and ast.IsFunctionLike(node.parent)
end

function ast.IsBlockOrCatchScoped(declaration)
    return ast.GetCombinedNodeFlags(declaration) & NodeFlags.BlockScoped ~= 0 or
        ast.IsCatchClauseVariableDeclarationOrBindingElement(declaration)
end

function ast.IsCatchClauseVariableDeclarationOrBindingElement(declaration)
    local node = ast.GetRootDeclaration(declaration)
    return node.kind == Kind.VariableDeclaration and node.parent.kind == Kind.CatchClause
end

local typeNodeKinds = kindSet(Kind.AnyKeyword, Kind.UnknownKeyword, Kind.NumberKeyword, Kind.BigIntKeyword,
    Kind.ObjectKeyword, Kind.BooleanKeyword, Kind.StringKeyword, Kind.SymbolKeyword, Kind.VoidKeyword,
    Kind.UndefinedKeyword, Kind.NeverKeyword, Kind.IntrinsicKeyword, Kind.ExpressionWithTypeArguments,
    Kind.JSDocAllType, Kind.JSDocNullableType, Kind.JSDocNonNullableType, Kind.JSDocOptionalType,
    Kind.JSDocVariadicType)

function ast.IsTypeNodeKind(kind)
    if typeNodeKinds[kind] then
        return true
    end
    return kind >= Kind.FirstTypeNode and kind <= Kind.LastTypeNode
end

function ast.IsTypeNode(node)
    return ast.IsTypeNodeKind(node.kind)
end

function ast.IsJSDocKind(kind)
    return Kind.FirstJSDocNode <= kind and kind <= Kind.LastJSDocNode
end

function ast.IsJSDocTypeAssertion(node)
    if node == nil or not ast.IsParenthesizedExpression(node) or not ast.IsInJSFile(node) then
        return false
    end
    local expr = node:Expression()
    return ast.IsAsExpression(expr) and expr:Type() ~= nil and expr:Type().flags & NodeFlags.Reparsed ~= 0
end

function ast.IsPrologueDirective(node)
    return node.kind == Kind.ExpressionStatement and
        node:Expression().kind == Kind.StringLiteral
end

local OEK = OuterExpressionKinds

-- Determines whether node is an "outer expression" of the provided kinds
function ast.IsOuterExpression(node, kinds)
    local kind = node.kind
    if kind == Kind.ParenthesizedExpression then
        return kinds & OEK.OEKParentheses ~= 0 and
            not (kinds & OEK.OEKExcludeJSDocTypeAssertion ~= 0 and ast.IsJSDocTypeAssertion(node))
    elseif kind == Kind.TypeAssertionExpression or kind == Kind.AsExpression then
        return kinds & OEK.OEKTypeAssertions ~= 0
    elseif kind == Kind.SatisfiesExpression then
        return kinds & (OEK.OEKExpressionsWithTypeArguments | OEK.OEKSatisfies) ~= 0
    elseif kind == Kind.ExpressionWithTypeArguments then
        return kinds & OEK.OEKExpressionsWithTypeArguments ~= 0
    elseif kind == Kind.NonNullExpression then
        return kinds & OEK.OEKNonNullAssertions ~= 0
    elseif kind == Kind.PartiallyEmittedExpression then
        return kinds & OEK.OEKPartiallyEmittedExpressions ~= 0
    elseif kind == Kind.BinaryExpression then
        local op = node.operatorToken.kind
        if op == Kind.EqualsToken then
            return kinds & OEK.OEKAssignments ~= 0
        elseif op == Kind.CommaToken then
            return kinds & OEK.OEKComma ~= 0
        end
    end
    return false
end

-- Descends into an expression, skipping past "outer expressions" of the provided kinds
function ast.SkipOuterExpressions(node, kinds)
    while ast.IsOuterExpression(node, kinds) do
        if ast.IsBinaryExpression(node) then
            node = node.right
        else
            node = node:Expression()
        end
    end
    return node
end

-- Skips past the parentheses of an expression
function ast.SkipParentheses(node)
    return ast.SkipOuterExpressions(node, OEK.OEKParentheses)
end

function ast.SkipTypeParentheses(node)
    while ast.IsParenthesizedTypeNode(node) do
        node = node:Type()
    end
    return node
end

function ast.SkipPartiallyEmittedExpressions(node)
    return ast.SkipOuterExpressions(node, OEK.OEKPartiallyEmittedExpressions)
end

-- Walks up the parents of a parenthesized expression to find the containing node
function ast.WalkUpParenthesizedExpressions(node)
    while node ~= nil and node.kind == Kind.ParenthesizedExpression do
        node = node.parent
    end
    return node
end

-- Walks up the parents of a parenthesized type to find the containing node
function ast.WalkUpParenthesizedTypes(node)
    while node ~= nil and node.kind == Kind.ParenthesizedType do
        node = node.parent
    end
    return node
end

-- Walks up the parents of a node to find the containing SourceFile
function ast.GetSourceFileOfNode(node)
    while node ~= nil do
        if node.kind == Kind.SourceFile then
            return node
        end
        node = node.parent
    end
    return nil
end

function ast.newParentInChildrenSetter()
    local state = { parent = nil, visit = nil }

    state.visit = function(node)
        if state.parent ~= nil then
            node.parent = state.parent
        end
        local saveParent = state.parent
        state.parent = node
        node:ForEachChild(state.visit)
        state.parent = saveParent
        return false
    end

    return state.visit
end

function ast.SetParentInChildren(node)
    local fn = ast.newParentInChildrenSetter()
    fn(node)
end

-- This should never be called outside the parser
function ast.SetImportsOfSourceFile(node, imports)
    node.imports = imports
end

-- Walks up the parents of a node to find the ancestor that matches the callback
function ast.FindAncestor(node, callback)
    while node ~= nil do
        if callback(node) then
            return node
        end
        node = node.parent
    end
    return nil
end

-- Returns an array with one entry per callback (nil where no ancestor matched).
-- Note: Lua arrays cannot hold nil holes; the result has an explicit `n` field with the callback count.
function ast.FindManyAncestors(node, ...)
    local callbacks = { ... }
    local ancestors = { n = #callbacks }
    local found = 0
    while node ~= nil do
        for i, callback in ipairs(callbacks) do
            if ancestors[i] == nil and callback(node) then
                ancestors[i] = node
                found = found + 1
                if found == #callbacks then
                    return ancestors
                end
                break
            end
        end
        node = node.parent
    end
    return ancestors
end

-- Walks up the parents of a node to find the ancestor that matches the kind
function ast.FindAncestorKind(node, kind)
    while node ~= nil do
        if node.kind == kind then
            return node
        end
        node = node.parent
    end
    return nil
end

function ast.ToFindAncestorResult(b)
    if b then
        return FindAncestorResult.FindAncestorTrue
    end
    return FindAncestorResult.FindAncestorFalse
end

-- Walks up the parents of a node to find the ancestor that matches the callback
function ast.FindAncestorOrQuit(node, callback)
    while node ~= nil do
        local r = callback(node)
        if r == FindAncestorResult.FindAncestorQuit then
            return nil
        elseif r == FindAncestorResult.FindAncestorTrue then
            return node
        end
        node = node.parent
    end
    return nil
end

function ast.IsNodeDescendantOf(node, ancestor)
    while node ~= nil do
        if node == ancestor then
            return true
        end
        node = node.parent
    end
    return false
end

local modifierToFlagMap = {
    [Kind.StaticKeyword] = ModifierFlags.Static,
    [Kind.PublicKeyword] = ModifierFlags.Public,
    [Kind.ProtectedKeyword] = ModifierFlags.Protected,
    [Kind.PrivateKeyword] = ModifierFlags.Private,
    [Kind.AbstractKeyword] = ModifierFlags.Abstract,
    [Kind.AccessorKeyword] = ModifierFlags.Accessor,
    [Kind.ExportKeyword] = ModifierFlags.Export,
    [Kind.DeclareKeyword] = ModifierFlags.Ambient,
    [Kind.ConstKeyword] = ModifierFlags.Const,
    [Kind.DefaultKeyword] = ModifierFlags.Default,
    [Kind.AsyncKeyword] = ModifierFlags.Async,
    [Kind.ReadonlyKeyword] = ModifierFlags.Readonly,
    [Kind.OverrideKeyword] = ModifierFlags.Override,
    [Kind.InKeyword] = ModifierFlags.In,
    [Kind.OutKeyword] = ModifierFlags.Out,
    [Kind.Decorator] = ModifierFlags.Decorator,
}

function ast.ModifierToFlag(token)
    return modifierToFlagMap[token] or ModifierFlags.None
end

function ast.ModifiersToFlags(modifiers)
    local flags = ModifierFlags.None
    if modifiers ~= nil then
        for i = 1, #modifiers do
            flags = flags | ast.ModifierToFlag(modifiers[i].kind)
        end
    end
    return flags
end

function ast.HasSyntacticModifier(node, flags)
    return node:ModifierFlags() & flags ~= 0
end

function ast.HasAccessorModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Accessor)
end

function ast.HasStaticModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Static)
end

function ast.IsStatic(node)
    -- https://tc39.es/ecma262/#sec-static-semantics-isstatic
    return ast.IsClassElement(node) and ast.HasStaticModifier(node) or ast.IsClassStaticBlockDeclaration(node)
end

local canHaveSymbolKinds = kindSet(Kind.ArrowFunction, Kind.BinaryExpression, Kind.BindingElement, Kind.CallExpression,
    Kind.CallSignature, Kind.ClassDeclaration, Kind.ClassExpression, Kind.ClassStaticBlockDeclaration, Kind.Constructor,
    Kind.ConstructorType, Kind.ConstructSignature, Kind.ElementAccessExpression, Kind.EnumDeclaration, Kind.EnumMember,
    Kind.ExportAssignment, Kind.ExportDeclaration, Kind.ExportSpecifier, Kind.FunctionDeclaration,
    Kind.FunctionExpression, Kind.FunctionType, Kind.GetAccessor, Kind.ImportClause, Kind.ImportEqualsDeclaration,
    Kind.ImportSpecifier, Kind.IndexSignature, Kind.InterfaceDeclaration, Kind.JSTypeAliasDeclaration,
    Kind.JsxAttribute, Kind.JsxAttributes, Kind.JsxSpreadAttribute, Kind.MappedType, Kind.MethodDeclaration,
    Kind.MethodSignature, Kind.ModuleDeclaration, Kind.NamedTupleMember, Kind.NamespaceExport,
    Kind.NamespaceExportDeclaration, Kind.NamespaceImport, Kind.NewExpression, Kind.NoSubstitutionTemplateLiteral,
    Kind.NumericLiteral, Kind.ObjectLiteralExpression, Kind.Parameter, Kind.PropertyAccessExpression,
    Kind.PropertyAssignment, Kind.PropertyDeclaration, Kind.PropertySignature, Kind.SetAccessor,
    Kind.ShorthandPropertyAssignment, Kind.SourceFile, Kind.SpreadAssignment, Kind.StringLiteral,
    Kind.TypeAliasDeclaration, Kind.TypeLiteral, Kind.TypeParameter, Kind.VariableDeclaration)

function ast.CanHaveSymbol(node)
    return canHaveSymbolKinds[node.kind] == true
end

local canHaveIllegalDecoratorsKinds = kindSet(Kind.PropertyAssignment, Kind.ShorthandPropertyAssignment,
    Kind.FunctionDeclaration, Kind.Constructor, Kind.IndexSignature, Kind.ClassStaticBlockDeclaration,
    Kind.MissingDeclaration, Kind.VariableStatement, Kind.InterfaceDeclaration, Kind.TypeAliasDeclaration,
    Kind.EnumDeclaration, Kind.ModuleDeclaration, Kind.ImportEqualsDeclaration, Kind.ImportDeclaration,
    Kind.JSImportDeclaration, Kind.NamespaceExportDeclaration, Kind.ExportDeclaration, Kind.ExportAssignment)

function ast.CanHaveIllegalDecorators(node)
    return canHaveIllegalDecoratorsKinds[node.kind] == true
end

local canHaveIllegalModifiersKinds = kindSet(Kind.ClassStaticBlockDeclaration, Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment, Kind.MissingDeclaration, Kind.NamespaceExportDeclaration)

function ast.CanHaveIllegalModifiers(node)
    return canHaveIllegalModifiersKinds[node.kind] == true
end

local canHaveModifiersKinds = kindSet(Kind.TypeParameter, Kind.Parameter, Kind.PropertySignature,
    Kind.PropertyDeclaration, Kind.MethodSignature, Kind.MethodDeclaration, Kind.Constructor, Kind.GetAccessor,
    Kind.SetAccessor, Kind.IndexSignature, Kind.ConstructorType, Kind.FunctionExpression, Kind.ArrowFunction,
    Kind.ClassExpression, Kind.VariableStatement, Kind.FunctionDeclaration, Kind.ClassDeclaration,
    Kind.InterfaceDeclaration, Kind.TypeAliasDeclaration, Kind.EnumDeclaration, Kind.ModuleDeclaration,
    Kind.ImportEqualsDeclaration, Kind.ImportDeclaration, Kind.JSImportDeclaration, Kind.ExportAssignment,
    Kind.ExportDeclaration)

function ast.CanHaveModifiers(node)
    return canHaveModifiersKinds[node.kind] == true
end

local canHaveDecoratorsKinds = kindSet(Kind.Parameter, Kind.PropertyDeclaration, Kind.MethodDeclaration,
    Kind.GetAccessor, Kind.SetAccessor, Kind.ClassExpression, Kind.ClassDeclaration)

function ast.CanHaveDecorators(node)
    return canHaveDecoratorsKinds[node.kind] == true
end

function ast.IsFunctionOrModuleBlock(node)
    return ast.IsSourceFile(node) or ast.IsModuleBlock(node) or ast.IsBlock(node) and ast.IsFunctionLike(node.parent)
end

function ast.IsFunctionExpressionOrArrowFunction(node)
    return ast.IsFunctionExpression(node) or ast.IsArrowFunction(node)
end

local returnStatementContainerKinds = kindSet(Kind.CaseBlock, Kind.Block, Kind.IfStatement, Kind.DoStatement,
    Kind.WhileStatement, Kind.ForStatement, Kind.ForInStatement, Kind.ForOfStatement, Kind.WithStatement,
    Kind.SwitchStatement, Kind.CaseClause, Kind.DefaultClause, Kind.LabeledStatement, Kind.TryStatement,
    Kind.CatchClause)

-- Warning: This has the same semantics as the forEach family of functions in that traversal terminates
-- in the event that 'visitor' returns true.
function ast.ForEachReturnStatement(body, visitor)
    local traverse
    traverse = function(node)
        if node.kind == Kind.ReturnStatement then
            return visitor(node)
        elseif returnStatementContainerKinds[node.kind] then
            return node:ForEachChild(traverse)
        end
        return false
    end
    return traverse(body)
end

function ast.GetRootDeclaration(node)
    while node.kind == Kind.BindingElement do
        node = node.parent.parent
    end
    return node
end

function ast.GetCombinedModifierFlags(node)
    node = ast.GetRootDeclaration(node)
    local flags = node:ModifierFlags()
    if node.kind == Kind.VariableDeclaration then
        node = node.parent
    end
    if node ~= nil and node.kind == Kind.VariableDeclarationList then
        flags = flags | node:ModifierFlags()
        node = node.parent
    end
    if node ~= nil and node.kind == Kind.VariableStatement then
        flags = flags | node:ModifierFlags()
    end
    return flags
end

function ast.GetCombinedNodeFlags(node)
    node = ast.GetRootDeclaration(node)
    local flags = node.flags
    if node.kind == Kind.VariableDeclaration then
        node = node.parent
    end
    if node ~= nil and node.kind == Kind.VariableDeclarationList then
        flags = flags | node.flags
        node = node.parent
    end
    if node ~= nil and node.kind == Kind.VariableStatement then
        flags = flags | node.flags
    end
    return flags
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of an `await using` declaration.
function ast.IsVarAwaitUsing(node)
    return ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped == NodeFlags.AwaitUsing
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `using` declaration.
function ast.IsVarUsing(node)
    return ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped == NodeFlags.Using
end

-- GetJSDocDeprecatedTag returns the first @deprecated JSDoc tag for the given node, or nil if none exists.
function ast.GetJSDocDeprecatedTag(node)
    local jsdocs = node:JSDoc(nil)
    if jsdocs ~= nil then
        for _, jsdoc in ipairs(jsdocs) do
            local tags = jsdoc:AsJSDoc().tags
            if tags ~= nil then
                for _, tag in ipairs(tags.nodes) do
                    if ast.IsJSDocDeprecatedTag(tag) then
                        return tag
                    end
                end
            end
        end
    end
    return nil
end

-- IsDeprecatedDeclaration reports whether the given declaration is marked as @deprecated.
-- It checks NodeFlagsPossiblyContainsDeprecatedTag on combined node flags, then confirms
-- by walking up to find the node with the flag and performing a JSDoc lookup.
function ast.IsDeprecatedDeclaration(declaration)
    return ast.IsDeprecatedDeclarationWithCachedFlags(declaration, ast.GetCombinedNodeFlags(declaration))
end

-- IsDeprecatedDeclarationWithCachedFlags is the core logic for IsDeprecatedDeclaration,
-- parameterized on pre-computed combined flags so the checker can supply cached flags.
function ast.IsDeprecatedDeclarationWithCachedFlags(declaration, combinedFlags)
    if combinedFlags & NodeFlags.PossiblyContainsDeprecatedTag == 0 then
        return false
    end
    -- Walk up to find the node that directly has the flag, since JSDoc is
    -- attached to that node (e.g. VariableStatement, not VariableDeclaration).
    local n = declaration
    while n ~= nil do
        if n.flags & NodeFlags.PossiblyContainsDeprecatedTag ~= 0 then
            return ast.GetJSDocDeprecatedTag(n) ~= nil
        end
        n = n.parent
    end
    return false
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `const` declaration.
function ast.IsVarConst(node)
    return ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped == NodeFlags.Const
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `const`, `using` or `await using` declaration.
function ast.IsVarConstLike(node)
    local f = ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped
    return f == NodeFlags.Const or f == NodeFlags.Using or f == NodeFlags.AwaitUsing
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `let` declaration.
function ast.IsVarLet(node)
    return ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped == NodeFlags.Let
end

function ast.IsImportMeta(node)
    if node.kind == Kind.MetaProperty then
        return node.keywordToken == Kind.ImportKeyword and node:Name():Text() == "meta"
    end
    return false
end

function ast.WalkUpBindingElementsAndPatterns(binding)
    local node = binding.parent
    while ast.IsBindingElement(node.parent) do
        node = node.parent.parent
    end
    return node.parent
end

function ast.IsSourceFileJS(file)
    return file.scriptKind == core.ScriptKind.JS or file.scriptKind == core.ScriptKind.JSX
end

function ast.IsInJSFile(node)
    return node ~= nil and node.flags & NodeFlags.JavaScriptFile ~= 0
end

function ast.IsDeclaration(node)
    if node.kind == Kind.TypeParameter then
        return node.parent ~= nil
    end
    return ast.IsDeclarationNode(node)
end

-- True if `name` is the name of a declaration node
function ast.IsDeclarationName(name)
    return not ast.IsSourceFile(name) and not ast.IsBindingPattern(name) and ast.IsDeclaration(name.parent) and
        name.parent:Name() == name
end

-- Like 'isDeclarationName', but returns true for LHS of `import { x as y }` or `export { x as y }`.
function ast.IsDeclarationNameOrImportPropertyName(name)
    local k = name.parent.kind
    if k == Kind.ImportSpecifier or k == Kind.ExportSpecifier then
        return ast.IsIdentifier(name) or name.kind == Kind.StringLiteral
    end
    return ast.IsDeclarationName(name)
end

function ast.IsLiteralComputedPropertyDeclarationName(node)
    return ast.IsStringOrNumericLiteralLike(node) and
        node.parent.kind == Kind.ComputedPropertyName and
        ast.IsDeclaration(node.parent.parent)
end

function ast.IsExternalModuleImportEqualsDeclaration(node)
    return node.kind == Kind.ImportEqualsDeclaration and node.moduleReference.kind == Kind.ExternalModuleReference
end

function ast.IsModuleOrEnumDeclaration(node)
    return node.kind == Kind.ModuleDeclaration or node.kind == Kind.EnumDeclaration
end

function ast.IsLiteralImportTypeNode(node)
    return ast.IsImportTypeNode(node) and ast.IsLiteralTypeNode(node.argument) and ast.IsStringLiteral(node.argument.literal)
end

function ast.IsJsxTagName(node)
    local parent = node.parent
    local k = parent.kind
    if k == Kind.JsxOpeningElement or k == Kind.JsxClosingElement or k == Kind.JsxSelfClosingElement then
        return parent:TagName() == node
    end
    return false
end

function ast.IsImportOrExportSpecifier(node)
    return ast.IsImportSpecifier(node) or ast.IsExportSpecifier(node)
end

function ast.IsVoidZero(node)
    return ast.IsVoidExpression(node) and ast.IsNumericLiteral(node:Expression()) and node:Expression():Text() == "0"
end

function ast.IsExportsIdentifier(node)
    return ast.IsIdentifier(node) and node:Text() == "exports"
end

function ast.IsModuleIdentifier(node)
    return ast.IsIdentifier(node) and node:Text() == "module"
end

function ast.IsThisIdentifier(node)
    return ast.IsIdentifier(node) and node:Text() == "this"
end

function ast.IsThisParameter(node)
    return ast.IsParameterDeclaration(node) and node:Name() ~= nil and ast.IsThisIdentifier(node:Name())
end

function ast.IsBindableStaticAccessExpression(node, excludeThisKeyword)
    return ast.IsPropertyAccessExpression(node) and
        (not excludeThisKeyword and node:Expression().kind == Kind.ThisKeyword or ast.IsIdentifier(node:Name()) and
            ast.IsBindableStaticNameExpression(node:Expression(), true --[[excludeThisKeyword]])) or
        ast.IsBindableStaticElementAccessExpression(node, excludeThisKeyword)
end

function ast.IsBindableStaticElementAccessExpression(node, excludeThisKeyword)
    return ast.IsLiteralLikeElementAccess(node) and
        ((not excludeThisKeyword and node:Expression().kind == Kind.ThisKeyword) or
            ast.IsEntityNameExpression(node:Expression()) or
            ast.IsBindableStaticAccessExpression(node:Expression(), true --[[excludeThisKeyword]]))
end

function ast.IsPrototypeAccess(node)
    if ast.IsBindableStaticAccessExpression(node, false --[[excludeThisKeyword]]) then
        local name = ast.GetElementOrPropertyAccessName(node)
        if name ~= nil then
            return name:Text() == "prototype"
        end
    end
    return false
end

function ast.IsLiteralLikeElementAccess(node)
    return ast.IsElementAccessExpression(node) and ast.IsStringOrNumericLiteralLike(node.argumentExpression)
end

function ast.IsBindableStaticNameExpression(node, excludeThisKeyword)
    return ast.IsEntityNameExpression(node) or ast.IsBindableStaticAccessExpression(node, excludeThisKeyword)
end

-- Does not handle signed numeric names like `a[+0]` - handling those would require handling prefix unary expressions
-- throughout late binding handling as well, which is awkward (but ultimately probably doable if there is demand)
function ast.GetElementOrPropertyAccessName(node)
    if node.kind == Kind.PropertyAccessExpression then
        if ast.IsIdentifier(node:Name()) then
            return node:Name()
        end
        return nil
    elseif node.kind == Kind.ElementAccessExpression then
        local arg = ast.SkipParentheses(node.argumentExpression)
        if ast.IsStringOrNumericLiteralLike(arg) then
            return arg
        end
        return nil
    end
    error("Unhandled case in GetElementOrPropertyAccessName")
end

function ast.GetInitializerOfBinaryExpression(expr)
    while ast.IsBinaryExpression(expr.right) do
        expr = expr.right
    end
    return expr.right:Expression()
end

function ast.IsExpressionWithTypeArgumentsInClassExtendsClause(node)
    return ast.TryGetClassExtendingExpressionWithTypeArguments(node) ~= nil
end

function ast.TryGetClassExtendingExpressionWithTypeArguments(node)
    if not ast.IsExpressionWithTypeArguments(node) then
        return nil
    end
    local cls, isImplements = ast.TryGetClassImplementingOrExtendingHeritageClauseElement(node)
    if cls ~= nil and not isImplements then
        return cls
    end
    return nil
end

-- Returns class, isImplements.
function ast.TryGetClassImplementingOrExtendingHeritageClauseElement(node)
    if (ast.IsExpressionWithTypeArguments(node) or ast.IsTypeReferenceNode(node)) and
        ast.IsHeritageClause(node.parent) and ast.IsClassLike(node.parent.parent) then
        return node.parent.parent, node.parent.token == Kind.ImplementsKeyword
    end
    return nil, false
end

function ast.GetNameOfDeclaration(declaration)
    if declaration == nil then
        return nil
    end
    local nonAssignedName = ast.GetNonAssignedNameOfDeclaration(declaration)
    if nonAssignedName ~= nil then
        return nonAssignedName
    end
    if ast.IsFunctionExpression(declaration) or ast.IsArrowFunction(declaration) or ast.IsClassExpression(declaration) then
        return ast.GetAssignedName(declaration)
    end
    return nil
end

function ast.GetNonAssignedNameOfDeclaration(declaration)
    -- !!!
    local kind = declaration.kind
    if kind == Kind.BinaryExpression or kind == Kind.CallExpression then
        local k = ast.GetAssignmentDeclarationKind(declaration)
        if k == JSDeclarationKind.Property or k == JSDeclarationKind.ThisProperty or k == JSDeclarationKind.ExportsProperty then
            local left = declaration:AsBinaryExpression().left
            local name = ast.GetElementOrPropertyAccessName(left)
            if name ~= nil then
                return name
            end
            return left
        elseif k == JSDeclarationKind.ObjectDefinePropertyValue or k == JSDeclarationKind.ObjectDefinePropertyExports then
            return declaration:Arguments()[2]
        end
        return nil
    elseif kind == Kind.ExportAssignment then
        local expr = declaration:Expression()
        if ast.IsIdentifier(expr) then
            return expr
        end
        return nil
    end
    return declaration:Name()
end

function ast.GetAssignedName(node)
    local parent = node.parent
    if parent ~= nil then
        local kind = parent.kind
        if kind == Kind.PropertyAssignment then
            return parent:Name()
        elseif kind == Kind.BindingElement then
            return parent:Name()
        elseif kind == Kind.BinaryExpression then
            if node == parent.right then
                local left = parent.left
                if left.kind == Kind.Identifier then
                    return left
                elseif left.kind == Kind.PropertyAccessExpression then
                    return left:Name()
                elseif left.kind == Kind.ElementAccessExpression then
                    local arg = ast.SkipParentheses(left.argumentExpression)
                    if ast.IsStringOrNumericLiteralLike(arg) then
                        return arg
                    end
                end
            end
        elseif kind == Kind.VariableDeclaration then
            local name = parent:Name()
            if ast.IsIdentifier(name) then
                return name
            end
        end
    end
    return nil
end

function ast.GetAssignmentDeclarationKind(node)
    if node.kind == Kind.BinaryExpression then
        local bin = node
        if bin.operatorToken.kind == Kind.EqualsToken and ast.IsAccessExpression(bin.left) then
            if ast.IsInJSFile(bin.left) then
                if ast.IsModuleExportsAccessExpression(bin.left) and not ast.IsExportsIdentifier(bin.right) then
                    return JSDeclarationKind.ModuleExports
                end
                if (ast.IsModuleExportsAccessExpression(bin.left:Expression()) or ast.IsExportsIdentifier(bin.left:Expression())) and
                    ast.GetElementOrPropertyAccessName(bin.left) ~= nil then
                    return JSDeclarationKind.ExportsProperty
                end
                if bin.left:Expression().kind == Kind.ThisKeyword then
                    return JSDeclarationKind.ThisProperty
                end
            end
            if bin.left.kind == Kind.PropertyAccessExpression and ast.IsEntityNameExpressionEx(bin.left:Expression(), ast.IsInJSFile(bin.left)) and ast.IsIdentifier(bin.left:Name()) or
                bin.left.kind == Kind.ElementAccessExpression and ast.IsEntityNameExpressionEx(bin.left:Expression(), ast.IsInJSFile(bin.left)) then
                return JSDeclarationKind.Property
            end
        end
    elseif node.kind == Kind.CallExpression then
        if ast.IsInJSFile(node) and ast.IsBindableObjectDefinePropertyCall(node) then
            local entityName = node:Arguments()[1]
            if ast.IsExportsIdentifier(entityName) or ast.IsModuleExportsAccessExpression(entityName) then
                return JSDeclarationKind.ObjectDefinePropertyExports
            end
            return JSDeclarationKind.ObjectDefinePropertyValue
        end
    end
    return JSDeclarationKind.None
end

function ast.IsBindableObjectDefinePropertyCall(node)
    local args = node:Arguments()
    if core.Len(args) == 3 then
        local expr = node:Expression()
        if ast.IsPropertyAccessExpression(expr) and
            ast.IsIdentifier(expr:Expression()) and expr:Expression():Text() == "Object" and
            expr:Name():Text() == "defineProperty" and
            ast.IsStringOrNumericLiteralLike(args[2]) and
            ast.IsBindableStaticNameExpression(args[1] --[[excludeThisKeyword]], true) then
            return true
        end
    end
    return false
end

--[[
 * A declaration has a dynamic name if all of the following are true:
 *   1. The declaration has a computed property name.
 *   2. The computed name is *not* expressed as a StringLiteral.
 *   3. The computed name is *not* expressed as a NumericLiteral.
 *   4. The computed name is *not* expressed as a PlusToken or MinusToken
 *      immediately followed by a NumericLiteral.
]]
function ast.HasDynamicName(declaration)
    local name = ast.GetNameOfDeclaration(declaration)
    return name ~= nil and ast.IsDynamicName(name)
end

function ast.IsDynamicName(name)
    local expr
    if name.kind == Kind.ComputedPropertyName then
        expr = name:Expression()
    elseif name.kind == Kind.ElementAccessExpression then
        expr = ast.SkipParentheses(name.argumentExpression)
    else
        return false
    end
    return not ast.IsStringOrNumericLiteralLike(expr) and not ast.IsSignedNumericLiteral(expr)
end

function ast.IsEntityNameExpression(node)
    return ast.IsEntityNameExpressionEx(node, false --[[allowJS]])
end

function ast.IsEntityNameExpressionEx(node, allowJS)
    return ast.IsIdentifier(node) or
        ast.IsPropertyAccessEntityNameExpression(node, allowJS) or
        allowJS and (node.kind == Kind.ThisKeyword or ast.isElementAccessEntityNameExpression(node, allowJS))
end

function ast.IsPropertyAccessEntityNameExpression(node, allowJS)
    return ast.IsPropertyAccessExpression(node) and ast.IsIdentifier(node:Name()) and
        ast.IsEntityNameExpressionEx(node:Expression(), allowJS)
end

function ast.isElementAccessEntityNameExpression(node, allowJS)
    return ast.IsElementAccessExpression(node) and ast.IsStringOrNumericLiteralLike(node.argumentExpression) and
        ast.IsEntityNameExpressionEx(node:Expression(), allowJS)
end

function ast.IsDottedName(node)
    local kind = node.kind
    if kind == Kind.Identifier or kind == Kind.ThisKeyword or kind == Kind.SuperKeyword or kind == Kind.MetaProperty then
        return true
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ParenthesizedExpression then
        return ast.IsDottedName(node:Expression())
    end
    return false
end

function ast.HasSamePropertyAccessName(node1, node2)
    if node1.kind == Kind.Identifier and node2.kind == Kind.Identifier then
        return node1:Text() == node2:Text()
    elseif node1.kind == Kind.PropertyAccessExpression and node2.kind == Kind.PropertyAccessExpression then
        return node1:Name():Text() == node2:Name():Text() and
            ast.HasSamePropertyAccessName(node1:Expression(), node2:Expression())
    end
    return false
end

function ast.IsAmbientModule(node)
    return ast.IsModuleDeclaration(node) and (node:Name().kind == Kind.StringLiteral or ast.IsGlobalScopeAugmentation(node))
end

function ast.IsAmbientModuleSymbolName(s)
    return string.sub(s, 1, 1) == "\"" and string.sub(s, -1) == "\""
end

function ast.IsExternalModule(file)
    return file.externalModuleIndicator ~= nil
end

function ast.IsExternalOrCommonJSModule(file)
    return file.externalModuleIndicator ~= nil or file.commonJSModuleIndicator ~= nil
end

-- TODO: Should we deprecate `IsExternalOrCommonJSModule` in favor of this function?
function ast.IsEffectiveExternalModule(node, compilerOptions)
    return ast.IsExternalModule(node) or
        (ast.isCommonJSContainingModuleKind(compilerOptions:GetEmitModuleKind()) and node.commonJSModuleIndicator ~= nil)
end

function ast.isCommonJSContainingModuleKind(kind)
    return kind == core.ModuleKind.CommonJS or core.ModuleKind.Node16 <= kind and kind <= core.ModuleKind.NodeNext
end

function ast.IsExternalModuleIndicator(node)
    -- Exported top-level member indicates moduleness
    return ast.IsAnyImportOrReExport(node) or ast.IsExportAssignment(node) or ast.HasSyntacticModifier(node, ModifierFlags.Export)
end

function ast.IsExportNamespaceAsDefaultDeclaration(node)
    if ast.IsExportDeclaration(node) then
        local decl = node
        return ast.IsNamespaceExport(decl.exportClause) and ast.ModuleExportNameIsDefault(decl.exportClause:Name())
    end
    return false
end

function ast.IsGlobalScopeAugmentation(node)
    return ast.IsModuleDeclaration(node) and node.keyword == Kind.GlobalKeyword
end

function ast.IsModuleAugmentationExternal(node)
    -- external module augmentation is a ambient module declaration that is either:
    -- - defined in the top level scope and source file is an external module
    -- - defined inside ambient module declaration located in the top level scope and source file not an external module
    local k = node.parent.kind
    if k == Kind.SourceFile then
        return ast.IsExternalModule(node.parent)
    elseif k == Kind.ModuleBlock then
        local grandParent = node.parent.parent
        return ast.IsAmbientModule(grandParent) and ast.IsSourceFile(grandParent.parent) and
            not ast.IsExternalModule(grandParent.parent)
    end
    return false
end

function ast.IsModuleWithStringLiteralName(node)
    return ast.IsModuleDeclaration(node) and node:Name().kind == Kind.StringLiteral
end

function ast.GetContainingClass(node)
    return ast.FindAncestor(node.parent, ast.IsClassLike)
end

function ast.GetExtendsHeritageClauseElements(node)
    return ast.GetHeritageElements(node, Kind.ExtendsKeyword)
end

function ast.GetImplementsHeritageClauseElements(node)
    return ast.GetHeritageElements(node, Kind.ImplementsKeyword)
end

function ast.GetHeritageElements(node, kind)
    local clause = ast.GetHeritageClause(node, kind)
    if clause ~= nil then
        return clause.types.nodes
    end
    return nil
end

-- GetHeritageClauseElementName returns the expression or type name of a heritage clause element.
function ast.GetHeritageClauseElementName(node)
    if ast.IsTypeReferenceNode(node) then
        return node.typeName
    end
    return node:AsExpressionWithTypeArguments().expression
end

function ast.IsNameOfHeritageClauseTypeReference(node)
    while ast.IsQualifiedName(node.parent) do
        node = node.parent
    end
    return ast.IsTypeReferenceNode(node.parent) and
        node.parent.typeName == node and
        ast.IsHeritageClause(node.parent.parent)
end

function ast.GetHeritageClause(node, kind)
    local clauses = ast.getHeritageClauses(node)
    if clauses ~= nil then
        for _, clause in ipairs(clauses.nodes) do
            if clause.token == kind then
                return clause
            end
        end
    end
    return nil
end

function ast.getHeritageClauses(node)
    local k = node.kind
    if k == Kind.ClassDeclaration or k == Kind.ClassExpression or k == Kind.InterfaceDeclaration then
        return node.heritageClauses
    end
    return nil
end

function ast.IsPartOfTypeQuery(node)
    while node.kind == Kind.QualifiedName or node.kind == Kind.Identifier do
        node = node.parent
    end
    return node.kind == Kind.TypeQuery
end

--[[
 * This function returns true if the this node's root declaration is a parameter.
 * For example, passing a `ParameterDeclaration` will return true, as will passing a
 * binding element that is a child of a `ParameterDeclaration`.
 *
 * If you are looking to test that a `Node` is a `ParameterDeclaration`, use `isParameter`.
]]
function ast.IsPartOfParameterDeclaration(node)
    return ast.GetRootDeclaration(node).kind == Kind.Parameter
end

function ast.IsInTopLevelContext(node)
    -- The name of a class or function declaration is a BindingIdentifier in its surrounding scope.
    if ast.IsIdentifier(node) then
        local parent = node.parent
        if (ast.IsClassDeclaration(parent) or ast.IsFunctionDeclaration(parent)) and parent:Name() == node then
            node = parent
        end
    end
    local container = ast.GetThisContainer(node, true --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    return ast.IsSourceFile(container)
end

local thisContainerKinds = kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ModuleDeclaration,
    Kind.ClassStaticBlockDeclaration, Kind.PropertyDeclaration, Kind.PropertySignature, Kind.MethodDeclaration,
    Kind.MethodSignature, Kind.Constructor, Kind.GetAccessor, Kind.SetAccessor, Kind.CallSignature,
    Kind.ConstructSignature, Kind.IndexSignature, Kind.EnumDeclaration, Kind.SourceFile)

function ast.GetThisContainer(node, includeArrowFunctions, includeClassComputedPropertyName)
    while true do
        node = node.parent
        if node == nil then
            error("nil parent in getThisContainer")
        end
        local kind = node.kind
        if kind == Kind.ComputedPropertyName then
            if includeClassComputedPropertyName and ast.IsClassLike(node.parent.parent) then
                return node
            end
            node = node.parent.parent
        elseif kind == Kind.Decorator then
            if node.parent.kind == Kind.Parameter and ast.IsClassElement(node.parent.parent) then
                -- If the decorator's parent is a ParameterDeclaration, we resolve the this container from
                -- the grandparent class declaration.
                node = node.parent.parent
            elseif ast.IsClassElement(node.parent) then
                -- If the decorator's parent is a class element, we resolve the 'this' container
                -- from the parent class declaration.
                node = node.parent
            end
        elseif kind == Kind.ArrowFunction then
            if includeArrowFunctions then
                return node
            end
        elseif thisContainerKinds[kind] then
            return node
        end
    end
end

local superContainerKinds = kindSet(Kind.PropertyDeclaration, Kind.PropertySignature, Kind.MethodDeclaration,
    Kind.MethodSignature, Kind.Constructor, Kind.GetAccessor, Kind.SetAccessor, Kind.ClassStaticBlockDeclaration)

function ast.GetSuperContainer(node, stopOnFunctions)
    node = node.parent
    while node ~= nil do
        local kind = node.kind
        if kind == Kind.ComputedPropertyName then
            node = node.parent
        elseif kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.ArrowFunction then
            if stopOnFunctions then
                return node
            end
        elseif superContainerKinds[kind] then
            return node
        elseif kind == Kind.Decorator then
            -- Decorators are always applied outside of the body of a class or method.
            if node.parent.kind == Kind.Parameter and ast.IsClassElement(node.parent.parent) then
                -- If the decorator's parent is a ParameterDeclaration, we resolve the this container from
                -- the grandparent class declaration.
                node = node.parent.parent
            elseif ast.IsClassElement(node.parent) then
                -- If the decorator's parent is a class element, we resolve the 'this' container
                -- from the parent class declaration.
                node = node.parent
            end
        end
        node = node.parent
    end
    return nil
end

function ast.GetImmediatelyInvokedFunctionExpression(fn)
    if ast.IsFunctionExpressionOrArrowFunction(fn) then
        local prev = fn
        local parent = fn.parent
        while ast.IsParenthesizedExpression(parent) do
            prev = parent
            parent = parent.parent
        end
        if ast.IsCallExpression(parent) and parent:Expression() == prev then
            return parent
        end
    end
    return nil
end

function ast.IsEnumConst(node)
    return ast.GetCombinedModifierFlags(node) & ModifierFlags.Const ~= 0
end

function ast.ExpressionIsAlias(node)
    return ast.IsEntityNameExpression(node) or ast.IsClassExpression(node)
end

function ast.IsInstanceOfExpression(node)
    return ast.IsBinaryExpression(node) and node.operatorToken.kind == Kind.InstanceOfKeyword
end

function ast.IsAnyImportOrReExport(node)
    return ast.IsImportNode(node) or ast.IsExportDeclaration(node)
end

function ast.IsImportNode(node)
    return ast.IsAnyImportSyntax(node) or ast.NodeKindIs(node, Kind.JSImportDeclaration)
end

-- Checks if the node is a genuine import declation. In particular the re-parsed KindJSImportDeclaration
-- is explicitly excluded because the callers of this function are typically not prepared to handle it properly.
-- For more permissive check, use IsImportNode.
function ast.IsAnyImportSyntax(node)
    return ast.NodeKindIs(node, Kind.ImportDeclaration, Kind.ImportEqualsDeclaration)
end

function ast.IsJsonSourceFile(file)
    return file.scriptKind == core.ScriptKind.JSON
end

function ast.IsInJsonFile(node)
    return node.flags & NodeFlags.JsonFile ~= 0
end

function ast.GetExternalModuleName(node)
    local kind = node.kind
    if kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or kind == Kind.ExportDeclaration then
        return node:ModuleSpecifier()
    elseif kind == Kind.ImportEqualsDeclaration then
        if node.moduleReference.kind == Kind.ExternalModuleReference then
            return node.moduleReference:Expression()
        end
        return nil
    elseif kind == Kind.ImportType then
        return ast.getImportTypeNodeLiteral(node)
    elseif kind == Kind.CallExpression then
        return core.FirstOrNil(node:Arguments())
    elseif kind == Kind.ModuleDeclaration then
        if ast.IsStringLiteral(node:Name()) then
            return node:Name()
        end
        return nil
    end
    error("Unhandled case in getExternalModuleName")
end

function ast.GetImportAttributes(node)
    local kind = node.kind
    if kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or kind == Kind.ExportDeclaration then
        return node.attributes
    end
    error("Unhandled case in getImportAttributes")
end

function ast.getImportTypeNodeLiteral(node)
    if ast.IsImportTypeNode(node) then
        local importTypeNode = node
        if ast.IsLiteralTypeNode(importTypeNode.argument) then
            local literalTypeNode = importTypeNode.argument
            if ast.IsStringLiteral(literalTypeNode.literal) then
                return literalTypeNode.literal
            end
        end
    end
    return nil
end

local expressionNodeKinds = kindSet(Kind.SuperKeyword, Kind.NullKeyword, Kind.TrueKeyword, Kind.FalseKeyword,
    Kind.RegularExpressionLiteral, Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression,
    Kind.PropertyAccessExpression, Kind.ElementAccessExpression, Kind.CallExpression, Kind.NewExpression,
    Kind.TaggedTemplateExpression, Kind.AsExpression, Kind.TypeAssertionExpression, Kind.SatisfiesExpression,
    Kind.NonNullExpression, Kind.ParenthesizedExpression, Kind.FunctionExpression, Kind.ClassExpression,
    Kind.ArrowFunction, Kind.VoidExpression, Kind.DeleteExpression, Kind.TypeOfExpression,
    Kind.PrefixUnaryExpression, Kind.PostfixUnaryExpression, Kind.BinaryExpression, Kind.ConditionalExpression,
    Kind.SpreadElement, Kind.TemplateExpression, Kind.OmittedExpression, Kind.JsxElement,
    Kind.JsxSelfClosingElement, Kind.JsxFragment, Kind.YieldExpression, Kind.AwaitExpression)
local expressionContextLiteralKinds = kindSet(Kind.NumericLiteral, Kind.BigIntLiteral, Kind.StringLiteral,
    Kind.NoSubstitutionTemplateLiteral, Kind.ThisKeyword)

function ast.IsExpressionNode(node)
    local kind = node.kind
    if expressionNodeKinds[kind] then
        return true
    elseif kind == Kind.MetaProperty then
        -- `import.defer` in `import.defer(...)` is not an expression
        return not ast.IsImportCall(node.parent) or node.parent:Expression() ~= node
    elseif kind == Kind.ExpressionWithTypeArguments then
        return not ast.IsHeritageClause(node.parent)
    elseif kind == Kind.QualifiedName then
        while node.parent.kind == Kind.QualifiedName do
            node = node.parent
        end
        return ast.IsTypeQueryNode(node.parent) or ast.IsJSDocLinkLike(node.parent) or
            ast.IsJSDocNameReference(node.parent) or ast.IsJsxTagName(node)
    elseif kind == Kind.PrivateIdentifier then
        return ast.IsBinaryExpression(node.parent) and node.parent.left == node and
            node.parent.operatorToken.kind == Kind.InKeyword
    elseif kind == Kind.Identifier then
        if ast.IsTypeQueryNode(node.parent) or ast.IsJSDocLinkLike(node.parent) or ast.IsJSDocNameReference(node.parent) or
            ast.IsJsxTagName(node) then
            return true
        end
        -- fallthrough
        return ast.IsInExpressionContext(node)
    elseif expressionContextLiteralKinds[kind] then
        return ast.IsInExpressionContext(node)
    end
    return false
end

local initializerContextKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.PropertyDeclaration,
    Kind.PropertySignature, Kind.EnumMember, Kind.PropertyAssignment, Kind.BindingElement)
local expressionContextKinds = kindSet(Kind.ExpressionStatement, Kind.IfStatement, Kind.DoStatement,
    Kind.WhileStatement, Kind.ReturnStatement, Kind.WithStatement, Kind.SwitchStatement, Kind.CaseClause,
    Kind.DefaultClause, Kind.ThrowStatement, Kind.TypeAssertionExpression, Kind.AsExpression, Kind.TemplateSpan,
    Kind.ComputedPropertyName, Kind.SatisfiesExpression)

function ast.IsInExpressionContext(node)
    local parent = node.parent
    local kind = parent.kind
    if initializerContextKinds[kind] then
        return parent:Initializer() == node
    elseif expressionContextKinds[kind] then
        return parent:Expression() == node
    elseif kind == Kind.ForStatement then
        local s = parent
        return s.initializer == node and s.initializer.kind ~= Kind.VariableDeclarationList or s.condition == node or
            s.incrementor == node
    elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
        local s = parent
        return s.initializer == node and s.initializer.kind ~= Kind.VariableDeclarationList or s.expression == node
    elseif kind == Kind.Decorator or kind == Kind.JsxExpression or kind == Kind.JsxSpreadAttribute or
        kind == Kind.SpreadAssignment then
        return true
    elseif kind == Kind.ExpressionWithTypeArguments then
        return parent:Expression() == node and not ast.IsPartOfTypeNode(parent)
    elseif kind == Kind.ShorthandPropertyAssignment then
        return parent.objectAssignmentInitializer == node
    end
    return ast.IsExpressionNode(parent)
end

local partOfTypeKeywordKinds = kindSet(Kind.AnyKeyword, Kind.UnknownKeyword, Kind.NumberKeyword, Kind.BigIntKeyword,
    Kind.StringKeyword, Kind.BooleanKeyword, Kind.SymbolKeyword, Kind.ObjectKeyword, Kind.UndefinedKeyword,
    Kind.NullKeyword, Kind.NeverKeyword)

function ast.IsPartOfTypeNode(node)
    local kind = node.kind
    if kind >= Kind.FirstTypeNode and kind <= Kind.LastTypeNode then
        return true
    end
    if partOfTypeKeywordKinds[kind] then
        return true
    elseif kind == Kind.VoidKeyword then
        return node.parent.kind ~= Kind.VoidExpression
    elseif kind == Kind.ExpressionWithTypeArguments then
        return ast.isPartOfTypeExpressionWithTypeArguments(node)
    elseif kind == Kind.TypeParameter then
        return node.parent.kind == Kind.MappedType or node.parent.kind == Kind.InferType
    elseif kind == Kind.Identifier then
        local parent = node.parent
        if ast.IsQualifiedName(parent) and parent.right == node then
            return ast.isPartOfTypeNodeInParent(parent)
        end
        if ast.IsPropertyAccessExpression(parent) and parent:Name() == node then
            return ast.isPartOfTypeNodeInParent(parent)
        end
        return ast.isPartOfTypeNodeInParent(node)
    elseif kind == Kind.QualifiedName or kind == Kind.PropertyAccessExpression or kind == Kind.ThisKeyword then
        return ast.isPartOfTypeNodeInParent(node)
    end
    return false
end

local typeAnnotatedParentKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.PropertyDeclaration,
    Kind.PropertySignature, Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction, Kind.Constructor,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.GetAccessor, Kind.SetAccessor, Kind.CallSignature,
    Kind.ConstructSignature, Kind.IndexSignature, Kind.TypeAssertionExpression)

function ast.isPartOfTypeNodeInParent(node)
    local parent = node.parent
    if parent.kind == Kind.TypeQuery then
        return false
    end
    if parent.kind == Kind.ImportType then
        return not parent.isTypeOf
    end

    -- Do not recursively call isPartOfTypeNode on the parent. In the example:
    --
    --     let a: A.B.C;
    --
    -- Calling isPartOfTypeNode would consider the qualified name A.B a type node.
    -- Only C and A.B.C are type nodes.
    if parent.kind >= Kind.FirstTypeNode and parent.kind <= Kind.LastTypeNode then
        return true
    end
    local kind = parent.kind
    if kind == Kind.ExpressionWithTypeArguments then
        return ast.isPartOfTypeExpressionWithTypeArguments(parent)
    elseif kind == Kind.TypeParameter then
        return node == parent.constraint
    elseif typeAnnotatedParentKinds[kind] then
        return node == parent:Type()
    elseif kind == Kind.CallExpression or kind == Kind.NewExpression or kind == Kind.TaggedTemplateExpression then
        local typeArguments = parent:TypeArguments()
        if typeArguments ~= nil then
            for _, t in ipairs(typeArguments) do
                if t == node then
                    return true
                end
            end
        end
        return false
    end
    return false
end

function ast.isPartOfTypeExpressionWithTypeArguments(node)
    local parent = node.parent
    return ast.IsHeritageClause(parent) and (not ast.IsClassLike(parent.parent) or parent.token == Kind.ImplementsKeyword) or
        ast.IsJSDocImplementsTag(parent) or
        ast.IsJSDocAugmentsTag(parent)
end

function ast.IsJSDocLinkLike(node)
    return ast.NodeKindIs(node, Kind.JSDocLink, Kind.JSDocLinkCode, Kind.JSDocLinkPlain)
end

function ast.IsJSDocTag(node)
    return node.kind >= Kind.FirstJSDocTagNode and node.kind <= Kind.LastJSDocTagNode
end

function ast.IsSuperCall(node)
    return ast.IsCallExpression(node) and node:Expression().kind == Kind.SuperKeyword
end

function ast.IsImportCall(node)
    if not ast.IsCallExpression(node) then
        return false
    end
    local e = node:Expression()
    return e.kind == Kind.ImportKeyword or ast.IsMetaProperty(e) and e.keywordToken == Kind.ImportKeyword and e:Text() == "defer"
end

function ast.IsComputedNonLiteralName(name)
    return ast.IsComputedPropertyName(name) and not ast.IsStringOrNumericLiteralLike(name:Expression())
end

function ast.IsQuestionToken(node)
    return node ~= nil and node.kind == Kind.QuestionToken
end

function ast.EntityNameToString(name, getTextOfNode)
    local kind = name.kind
    if kind == Kind.ThisKeyword then
        return "this"
    elseif kind == Kind.Identifier or kind == Kind.PrivateIdentifier then
        if ast.NodeIsSynthesized(name) or getTextOfNode == nil then
            return name:Text()
        end
        return getTextOfNode(name)
    elseif kind == Kind.QualifiedName then
        return ast.EntityNameToString(name.left, getTextOfNode) .. "." .. ast.EntityNameToString(name.right, getTextOfNode)
    elseif kind == Kind.PropertyAccessExpression then
        return ast.EntityNameToString(name:Expression(), getTextOfNode) .. "." .. ast.EntityNameToString(name:Name(), getTextOfNode)
    elseif kind == Kind.JsxNamespacedName then
        return ast.EntityNameToString(name.namespace, getTextOfNode) .. ":" .. ast.EntityNameToString(name:Name(), getTextOfNode)
    end
    error("Unhandled case in EntityNameToString")
end

function ast.GetTextOfPropertyName(name)
    local text = ast.TryGetTextOfPropertyName(name)
    return text
end

local textOfPropertyNameKinds = kindSet(Kind.Identifier, Kind.PrivateIdentifier, Kind.StringLiteral,
    Kind.NumericLiteral, Kind.BigIntLiteral, Kind.NoSubstitutionTemplateLiteral)

-- Returns text, ok.
function ast.TryGetTextOfPropertyName(name)
    local kind = name.kind
    if textOfPropertyNameKinds[kind] then
        return name:Text(), true
    elseif kind == Kind.ComputedPropertyName then
        if ast.IsStringOrNumericLiteralLike(name:Expression()) then
            return name:Expression():Text(), true
        end
    elseif kind == Kind.JsxNamespacedName then
        return name.namespace:Text() .. ":" .. name:Name():Text(), true
    end
    return "", false
end

function ast.IsJSDocNode(node)
    return node.kind >= Kind.FirstJSDocNode and node.kind <= Kind.LastJSDocNode
end

function ast.IsNonWhitespaceToken(node)
    return ast.IsTokenKind(node.kind) and not ast.IsWhitespaceOnlyJsxText(node)
end

function ast.IsWhitespaceOnlyJsxText(node)
    return node.kind == Kind.JsxText and node.containsOnlyTriviaWhiteSpaces
end

function ast.GetNewTargetContainer(node)
    local container = ast.GetThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    if container ~= nil then
        local kind = container.kind
        if kind == Kind.Constructor or kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression then
            return container
        end
    end
    return nil
end

function ast.GetEnclosingBlockScopeContainer(node)
    return ast.FindAncestor(node.parent, function(current)
        return ast.IsBlockScope(current, current.parent)
    end)
end

local blockScopeKinds = kindSet(Kind.SourceFile, Kind.CaseBlock, Kind.CatchClause, Kind.ModuleDeclaration,
    Kind.ForStatement, Kind.ForInStatement, Kind.ForOfStatement, Kind.Constructor, Kind.MethodDeclaration,
    Kind.GetAccessor, Kind.SetAccessor, Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction,
    Kind.PropertyDeclaration, Kind.ClassStaticBlockDeclaration)

function ast.IsBlockScope(node, parentNode)
    if blockScopeKinds[node.kind] then
        return true
    elseif node.kind == Kind.Block then
        -- function block is not considered block-scope container
        -- see comment in binder.ts: bind(...), case for SyntaxKind.Block
        return not ast.IsFunctionLikeOrClassStaticBlockDeclaration(parentNode)
    end
    return false
end

local valueMeaningKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.BindingElement,
    Kind.PropertyDeclaration, Kind.PropertySignature, Kind.PropertyAssignment, Kind.ShorthandPropertyAssignment,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.Constructor, Kind.GetAccessor, Kind.SetAccessor,
    Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction, Kind.CatchClause, Kind.JsxAttribute)
local typeMeaningKinds = kindSet(Kind.TypeParameter, Kind.InterfaceDeclaration, Kind.TypeAliasDeclaration,
    Kind.JSTypeAliasDeclaration, Kind.TypeLiteral)
local allMeaningKinds = kindSet(Kind.EnumDeclaration, Kind.NamedImports, Kind.ImportSpecifier,
    Kind.ImportEqualsDeclaration, Kind.ImportDeclaration, Kind.JSImportDeclaration, Kind.ExportAssignment,
    Kind.ExportDeclaration)

function ast.GetMeaningFromDeclaration(node)
    local kind = node.kind
    if valueMeaningKinds[kind] then
        return SemanticMeaning.Value
    elseif typeMeaningKinds[kind] then
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
    elseif allMeaningKinds[kind] then
        return SemanticMeaning.All
    elseif kind == Kind.SourceFile then
        -- An external module can be a Value
        return SemanticMeaning.Namespace | SemanticMeaning.Value
    end
    return SemanticMeaning.All
end

function ast.IsPropertyAccessOrQualifiedName(node)
    return node.kind == Kind.PropertyAccessExpression or node.kind == Kind.QualifiedName
end

function ast.IsLabelName(node)
    return ast.IsLabelOfLabeledStatement(node) or ast.IsJumpStatementTarget(node)
end

function ast.IsLabelOfLabeledStatement(node)
    if not ast.IsIdentifier(node) then
        return false
    end
    if not ast.IsLabeledStatement(node.parent) then
        return false
    end
    return node == node.parent:Label()
end

function ast.IsJumpStatementTarget(node)
    if not ast.IsIdentifier(node) then
        return false
    end
    if not ast.IsBreakOrContinueStatement(node.parent) then
        return false
    end
    return node == node.parent:Label()
end
