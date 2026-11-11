local ast = require("tslua.ast")

local Kind = ast.Kind
local OperatorPrecedence = ast.OperatorPrecedence
local OperatorPrecedenceFlags = ast.OperatorPrecedenceFlags
local TypePrecedence = ast.TypePrecedence
local kindSet = ast.kindSet

function ast.getOperator(expression)
    local kind = expression.kind
    if kind == Kind.BinaryExpression then
        return expression.operatorToken.kind
    elseif kind == Kind.PrefixUnaryExpression then
        return expression.operator
    elseif kind == Kind.PostfixUnaryExpression then
        return expression.operator
    end
    return expression.kind
end

-- Gets the precedence of an expression
function ast.GetExpressionPrecedence(expression)
    local operator = ast.getOperator(expression)
    local flags = OperatorPrecedenceFlags.None
    if expression.kind == Kind.NewExpression and expression:ArgumentList() == nil then
        flags = OperatorPrecedenceFlags.NewWithoutArguments
    elseif ast.IsOptionalChain(expression) then
        flags = OperatorPrecedenceFlags.OptionalChain
    end
    return ast.GetOperatorPrecedence(expression.kind, operator, flags)
end

local assignmentOperatorKinds = kindSet(Kind.EqualsToken, Kind.PlusEqualsToken, Kind.MinusEqualsToken,
    Kind.AsteriskAsteriskEqualsToken, Kind.AsteriskEqualsToken, Kind.SlashEqualsToken, Kind.PercentEqualsToken,
    Kind.LessThanLessThanEqualsToken, Kind.GreaterThanGreaterThanEqualsToken,
    Kind.GreaterThanGreaterThanGreaterThanEqualsToken, Kind.AmpersandEqualsToken, Kind.CaretEqualsToken,
    Kind.BarEqualsToken, Kind.BarBarEqualsToken, Kind.AmpersandAmpersandEqualsToken, Kind.QuestionQuestionEqualsToken)
local unaryPrecedenceKinds = kindSet(Kind.TypeAssertionExpression, Kind.NonNullExpression, Kind.PrefixUnaryExpression,
    Kind.TypeOfExpression, Kind.VoidExpression, Kind.DeleteExpression, Kind.AwaitExpression)
local primaryPrecedenceKinds = kindSet(Kind.ThisKeyword, Kind.SuperKeyword, Kind.ImportKeyword, Kind.Identifier,
    Kind.PrivateIdentifier, Kind.NullKeyword, Kind.TrueKeyword, Kind.FalseKeyword, Kind.NumericLiteral,
    Kind.BigIntLiteral, Kind.StringLiteral, Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression,
    Kind.FunctionExpression, Kind.ClassExpression, Kind.RegularExpressionLiteral, Kind.NoSubstitutionTemplateLiteral,
    Kind.TemplateExpression, Kind.OmittedExpression, Kind.JsxElement, Kind.JsxSelfClosingElement, Kind.JsxFragment,
    Kind.MissingDeclaration)

-- Gets the precedence of an operator
function ast.GetOperatorPrecedence(nodeKind, operatorKind, flags)
    if nodeKind == Kind.SpreadElement then
        return OperatorPrecedence.Spread
    elseif nodeKind == Kind.YieldExpression then
        return OperatorPrecedence.Yield
    elseif nodeKind == Kind.ArrowFunction then
        -- !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
        return OperatorPrecedence.Assignment
    elseif nodeKind == Kind.ConditionalExpression then
        return OperatorPrecedence.Conditional
    elseif nodeKind == Kind.BinaryExpression then
        if operatorKind == Kind.CommaToken then
            return OperatorPrecedence.Comma
        elseif assignmentOperatorKinds[operatorKind] then
            return OperatorPrecedence.Assignment
        end
        return ast.GetBinaryOperatorPrecedence(operatorKind)
    elseif unaryPrecedenceKinds[nodeKind] then
        -- TODO: Should prefix `++` and `--` be moved to the `Update` precedence?
        return OperatorPrecedence.Unary
    elseif nodeKind == Kind.PostfixUnaryExpression then
        return OperatorPrecedence.Update
    elseif nodeKind == Kind.PropertyAccessExpression or nodeKind == Kind.ElementAccessExpression then
        -- !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
        if flags & OperatorPrecedenceFlags.OptionalChain ~= 0 then
            return OperatorPrecedence.OptionalChain
        end
        return OperatorPrecedence.Member
    elseif nodeKind == Kind.CallExpression then
        if flags & OperatorPrecedenceFlags.OptionalChain ~= 0 then
            return OperatorPrecedence.OptionalChain
        end
        return OperatorPrecedence.Member
    elseif nodeKind == Kind.NewExpression then
        -- !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
        if flags & OperatorPrecedenceFlags.NewWithoutArguments ~= 0 then
            return OperatorPrecedence.LeftHandSide
        end
        return OperatorPrecedence.Member
    elseif nodeKind == Kind.TaggedTemplateExpression or nodeKind == Kind.MetaProperty or
        nodeKind == Kind.ExpressionWithTypeArguments then
        -- !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
        return OperatorPrecedence.Member
    elseif nodeKind == Kind.AsExpression or nodeKind == Kind.SatisfiesExpression then
        return OperatorPrecedence.Relational
    elseif primaryPrecedenceKinds[nodeKind] then
        return OperatorPrecedence.Primary
    elseif nodeKind == Kind.ParenthesizedExpression then
        -- !!! By necessity, this differs from the old compiler to support emit. consider backporting
        return OperatorPrecedence.Parentheses
    end
    return OperatorPrecedence.Invalid
end

-- Gets the precedence of a binary operator
function ast.GetBinaryOperatorPrecedence(operatorKind)
    local k = operatorKind
    if k == Kind.QuestionQuestionToken then
        return OperatorPrecedence.Coalesce
    elseif k == Kind.BarBarToken then
        return OperatorPrecedence.LogicalOR
    elseif k == Kind.AmpersandAmpersandToken then
        return OperatorPrecedence.LogicalAND
    elseif k == Kind.BarToken then
        return OperatorPrecedence.BitwiseOR
    elseif k == Kind.CaretToken then
        return OperatorPrecedence.BitwiseXOR
    elseif k == Kind.AmpersandToken then
        return OperatorPrecedence.BitwiseAND
    elseif k == Kind.EqualsEqualsToken or k == Kind.ExclamationEqualsToken or k == Kind.EqualsEqualsEqualsToken or
        k == Kind.ExclamationEqualsEqualsToken then
        return OperatorPrecedence.Equality
    elseif k == Kind.LessThanToken or k == Kind.GreaterThanToken or k == Kind.LessThanEqualsToken or
        k == Kind.GreaterThanEqualsToken or k == Kind.InstanceOfKeyword or k == Kind.InKeyword or
        k == Kind.AsKeyword or k == Kind.SatisfiesKeyword then
        return OperatorPrecedence.Relational
    elseif k == Kind.LessThanLessThanToken or k == Kind.GreaterThanGreaterThanToken or
        k == Kind.GreaterThanGreaterThanGreaterThanToken then
        return OperatorPrecedence.Shift
    elseif k == Kind.PlusToken or k == Kind.MinusToken then
        return OperatorPrecedence.Additive
    elseif k == Kind.AsteriskToken or k == Kind.SlashToken or k == Kind.PercentToken then
        return OperatorPrecedence.Multiplicative
    elseif k == Kind.AsteriskAsteriskToken then
        return OperatorPrecedence.Exponentiation
    end
    -- -1 is lower than all other precedences.  Returning it will cause binary expression
    -- parsing to stop.
    return OperatorPrecedence.Invalid
end

local leftmostExpressionKinds = kindSet(Kind.AsExpression, Kind.ElementAccessExpression, Kind.PropertyAccessExpression,
    Kind.NonNullExpression, Kind.PartiallyEmittedExpression, Kind.SatisfiesExpression)

-- Gets the leftmost expression of an expression, e.g. `a` in `a.b`, `a[b]`, `a++`, `a+b`, `a?b:c`, `a as B`, etc.
function ast.GetLeftmostExpression(node, stopAtCallExpressions)
    while true do
        local kind = node.kind
        if kind == Kind.PostfixUnaryExpression then
            node = node.operand
        elseif kind == Kind.BinaryExpression then
            node = node.left
        elseif kind == Kind.ConditionalExpression then
            node = node.condition
        elseif kind == Kind.TaggedTemplateExpression then
            node = node.tag
        elseif kind == Kind.CallExpression or leftmostExpressionKinds[kind] then
            if kind == Kind.CallExpression and stopAtCallExpressions then
                return node
            end
            node = node:Expression()
        else
            return node
        end
    end
end

local nonArrayTypePrecedenceKinds = kindSet(Kind.AnyKeyword, Kind.UnknownKeyword, Kind.StringKeyword,
    Kind.NumberKeyword, Kind.BigIntKeyword, Kind.SymbolKeyword, Kind.BooleanKeyword, Kind.UndefinedKeyword,
    Kind.NeverKeyword, Kind.ObjectKeyword, Kind.IntrinsicKeyword, Kind.VoidKeyword, Kind.JSDocAllType,
    Kind.JSDocNullableType, Kind.JSDocNonNullableType, Kind.LiteralType, Kind.TypePredicate, Kind.TypeReference,
    Kind.TypeLiteral, Kind.TupleType, Kind.RestType, Kind.ParenthesizedType, Kind.ThisType, Kind.MappedType,
    Kind.NamedTupleMember, Kind.TemplateLiteralType, Kind.ImportType,
    -- These occur in pseudo-types like `f<T>.C`, where `f` is a generic function and `C` is a local type
    Kind.PropertyAccessExpression, Kind.ExpressionWithTypeArguments)

-- Gets the precedence of a TypeNode
function ast.GetTypeNodePrecedence(n)
    local kind = n.kind
    if kind == Kind.ConditionalType then
        return TypePrecedence.Conditional
    elseif kind == Kind.JSDocOptionalType or kind == Kind.JSDocVariadicType then
        return TypePrecedence.JSDoc
    elseif kind == Kind.FunctionType or kind == Kind.ConstructorType then
        return TypePrecedence.Function
    elseif kind == Kind.UnionType then
        return TypePrecedence.Union
    elseif kind == Kind.IntersectionType then
        return TypePrecedence.Intersection
    elseif kind == Kind.TypeOperator then
        return TypePrecedence.TypeOperator
    elseif kind == Kind.InferType then
        if n.typeParameter:AsTypeParameterDeclaration().constraint ~= nil then
            -- `infer T extends U` must be treated as FunctionTypeNode precedence as the `extends` clause eagerly consumes
            -- TypeNode
            return TypePrecedence.Function
        end
        return TypePrecedence.TypeOperator
    elseif kind == Kind.IndexedAccessType or kind == Kind.ArrayType or kind == Kind.OptionalType then
        return TypePrecedence.Postfix
    elseif kind == Kind.TypeQuery then
        -- TypeQueryNode is actually a NonArrayType, but we treat it as TypeOperatorNode
        -- precedence so that it is parenthesized when used in a PostfixType
        -- context (e.g., `(typeof C)[]` instead of `typeof C[]`)
        return TypePrecedence.TypeOperator
    elseif nonArrayTypePrecedenceKinds[kind] then
        return TypePrecedence.NonArray
    end
    error(string.format("unhandled TypeNode: %s", ast.Kind_String(n.kind)))
end
