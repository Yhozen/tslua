local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local printer = require("tslua.printer")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

-- metadataSerializer fields: resolver, languageVersion, strictNullChecks, f, ec, c (metadataSerializerContext).
local metadataSerializer = {}
metadataSerializer.__index = metadataSerializer
tstransforms.metadataSerializer = metadataSerializer

-- metadataSerializerContext is a Go value struct; Lua uses a plain table
-- { currentLexicalScope, currentNameScope, serializingConditionalTypeBranch }, copied where Go copies.
local function copyContext(ctx)
    return {
        currentLexicalScope = ctx.currentLexicalScope,
        currentNameScope = ctx.currentNameScope,
        serializingConditionalTypeBranch = ctx.serializingConditionalTypeBranch or false,
    }
end

function tstransforms.newMetadataSerializer(resolver, f, ec, languageVersion, strictNullChecks)
    return setmetatable({
        resolver = resolver,
        languageVersion = languageVersion,
        f = f,
        ec = ec,
        strictNullChecks = strictNullChecks,
        c = { currentLexicalScope = nil, currentNameScope = nil, serializingConditionalTypeBranch = false },
    }, metadataSerializer)
end

function metadataSerializer:setContext(ctx)
    self.c = ctx
end

function metadataSerializer:SerializeTypeOfNode(ctx, node, container)
    local oldCtx = self.c
    self.c = copyContext(ctx)
    local result = self:serializeTypeOfNode(node, container)
    self:setContext(oldCtx)
    return result
end

function metadataSerializer:SerializeParameterTypesOfNode(ctx, node, container)
    local oldCtx = self.c
    self.c = copyContext(ctx)
    local result = self:serializeParameterTypesOfNode(node, container)
    self:setContext(oldCtx)
    return result
end

function metadataSerializer:SerializeReturnTypeOfNode(ctx, node)
    local oldCtx = self.c
    self.c = copyContext(ctx)
    local result = self:serializeReturnTypeOfNode(node)
    self:setContext(oldCtx)
    return result
end

function tstransforms.GetSetAccessorValueParameter(node)
    if node ~= nil and core.Len(node.parameters.nodes) > 0 then
        if #node.parameters.nodes >= 2 and ast.IsThisParameter(node.parameters.nodes[1]) then
            return node.parameters.nodes[2]
        end
        return node.parameters.nodes[1]
    end
    return nil
end

--[[*
 * Get the type annotation for the value parameter.
 *
 * @internal
 ]]
function tstransforms.getSetAccessorTypeAnnotationNode(node)
    local p = tstransforms.GetSetAccessorValueParameter(node)
    if p ~= nil and p:Type() ~= nil then
        return p:Type()
    end
    return nil
end

function tstransforms.getAccessorTypeNode(node, container)
    local accessors = ast.GetAllAccessorDeclarations(container:Members(), node)
    if accessors.setAccessor ~= nil then
        return tstransforms.getSetAccessorTypeAnnotationNode(accessors.setAccessor)
    end
    if accessors.getAccessor ~= nil then
        return accessors.getAccessor.type
    end
    return nil
end

--[[*
* Serializes the type of a node for use with decorator type metadata.
* @param node The node that should have its type serialized.
 ]]
function metadataSerializer:serializeTypeOfNode(node, container)
    local kind = node.kind
    if kind == Kind.PropertyDeclaration or kind == Kind.Parameter then
        return self:serializeTypeNode(node:Type())
    elseif kind == Kind.GetAccessor or kind == Kind.SetAccessor then
        return self:serializeTypeNode(tstransforms.getAccessorTypeNode(node, container))
    elseif kind == Kind.ClassDeclaration or kind == Kind.ClassExpression or kind == Kind.MethodDeclaration then
        return self.f:NewIdentifier("Function")
    else
        return self.f:NewVoidZeroExpression()
    end
end

--[[*
* Serializes the type of a node for use with decorator type metadata.
* @param node The node that should have its type serialized.
 ]]
function metadataSerializer:serializeParameterTypesOfNode(node, container)
    local valueDeclaration
    if ast.IsClassLike(node) then
        valueDeclaration = ast.GetFirstConstructorWithBody(node)
    elseif ast.IsFunctionLike(node) and ast.NodeIsPresent(node:Body()) then
        valueDeclaration = node
    end

    if valueDeclaration == nil then
        return self.f:NewArrayLiteralExpression(self.f:NewNodeList({}), false)
    end

    local expressions
    local parameters = tstransforms.getParametersOfDecoratedDeclaration(valueDeclaration, container)
    for i0, parameter in ipairs(parameters.nodes or {}) do
        local i = i0 - 1
        if i == 0 and ast.IsIdentifier(parameter:Name()) and parameter:Name():Text() == "this" then
            goto continue
        end
        if parameter:AsParameterDeclaration().dotDotDotToken ~= nil then
            expressions = core.Append(expressions, self:serializeTypeNode(ast.GetRestParameterElementType(parameter:Type())))
        else
            expressions = core.Append(expressions, self:serializeTypeOfNode(parameter, container))
        end
        ::continue::
    end
    return self.f:NewArrayLiteralExpression(self.f:NewNodeList(expressions), false)
end

function tstransforms.getParametersOfDecoratedDeclaration(node, container)
    if container ~= nil and node.kind == Kind.GetAccessor then
        local acc = ast.GetAllAccessorDeclarations(container:Members(), node)
        if acc.setAccessor ~= nil then
            return acc.setAccessor.parameters
        end
    end
    return node:ParameterList()
end

--[[*
* Serializes the return type of a node for use with decorator type metadata.
* @param node The node that should have its return type serialized.
 ]]
function metadataSerializer:serializeReturnTypeOfNode(node)
    if ast.IsFunctionLike(node) and node:Type() ~= nil then
        return self:serializeTypeNode(node:Type())
    elseif ast.IsAsyncFunction(node) then
        return self.f:NewIdentifier("Promise")
    end
    return self.f:NewVoidZeroExpression()
end

local objectFallbackKinds = ast.kindSet(
    Kind.TypeQuery, Kind.IndexedAccessType, Kind.MappedType, Kind.TypeLiteral, Kind.AnyKeyword, Kind.UnknownKeyword, Kind.ThisType, Kind.ImportType,
    -- handle JSDoc types from an invalid parse
    Kind.JSDocAllType, Kind.JSDocVariadicType
)

--[[*
* Serializes a type node for use with decorator type metadata.
*
* Types are serialized in the following fashion:
* - Void types point to "undefined" (e.g. "void 0")
* - Function and Constructor types point to the global "Function" constructor.
* - Interface types with a call or construct signature types point to the global
*   "Function" constructor.
* - Array and Tuple types point to the global "Array" constructor.
* - Type predicates and booleans point to the global "Boolean" constructor.
* - String literal types and strings point to the global "String" constructor.
* - Enum and number types point to the global "Number" constructor.
* - Symbol types point to the global "Symbol" constructor.
* - Type references to classes (or class-like variables) point to the constructor for the class.
* - Anything else points to the global "Object" constructor.
*
* @param node The type node to serialize.
 ]]
function metadataSerializer:serializeTypeNode(node)
    if node == nil then
        return self.f:NewIdentifier("Object")
    end

    node = ast.SkipTypeParentheses(node)

    local kind = node.kind
    if kind == Kind.VoidKeyword or kind == Kind.UndefinedKeyword or kind == Kind.NeverKeyword then
        return self.f:NewVoidZeroExpression()
    elseif kind == Kind.FunctionType or kind == Kind.ConstructorType then
        return self.f:NewIdentifier("Function")
    elseif kind == Kind.ArrayType or kind == Kind.TupleType then
        return self.f:NewIdentifier("Array")
    elseif kind == Kind.TypePredicate then
        if node:AsTypePredicateNode().assertsModifier ~= nil then
            return self.f:NewVoidZeroExpression()
        end
        return self.f:NewIdentifier("Boolean")
    elseif kind == Kind.BooleanKeyword then
        return self.f:NewIdentifier("Boolean")
    elseif kind == Kind.TemplateLiteralType or kind == Kind.StringKeyword then
        return self.f:NewIdentifier("String")
    elseif kind == Kind.ObjectKeyword then
        return self.f:NewIdentifier("Object")
    elseif kind == Kind.LiteralType then
        return self:serializeLiteralOfLiteralTypeNode(node:AsLiteralTypeNode().literal)
    elseif kind == Kind.NumberKeyword then
        return self.f:NewIdentifier("Number")
    elseif kind == Kind.BigIntKeyword then
        return self:serializeBigIntConstructor()
    elseif kind == Kind.SymbolKeyword then
        return self.f:NewIdentifier("Symbol")
    elseif kind == Kind.TypeReference then
        return self:serializeTypeReferenceNode(node:AsTypeReferenceNode())
    elseif kind == Kind.IntersectionType then
        return self:serializeUnionOrIntersectionConstituents(node:AsIntersectionTypeNode().types.nodes, true)
    elseif kind == Kind.UnionType then
        return self:serializeUnionOrIntersectionConstituents(node:AsUnionTypeNode().types.nodes, false)
    elseif kind == Kind.ConditionalType then
        local oldState = self.c.serializingConditionalTypeBranch
        self.c.serializingConditionalTypeBranch = true
        local result = self:serializeUnionOrIntersectionConstituents({ node:AsConditionalTypeNode().trueType, node:AsConditionalTypeNode().falseType }, false)
        self.c.serializingConditionalTypeBranch = oldState
        return result
    elseif kind == Kind.TypeOperator then
        if node:AsTypeOperatorNode().operator == Kind.ReadonlyKeyword then
            return self:serializeTypeNode(node:Type())
        end
        -- TODO: why is `unique symbol` not handled as `Symbol`? This falls back to `Object`
    elseif objectFallbackKinds[kind] then -- luacheck: ignore 542
    elseif kind == Kind.JSDocNullableType or kind == Kind.JSDocNonNullableType or kind == Kind.JSDocOptionalType then
        return self:serializeTypeNode(node:Type())
    else
        debug.FailBadSyntaxKind(node)
        return nil
    end
    return self.f:NewIdentifier("Object")
end

function metadataSerializer:serializeUnionOrIntersectionConstituents(types, isIntersection)
    -- Note when updating logic here also update `getEntityNameForDecoratorMetadata` in checker.ts so that aliases can be marked as referenced
    local serializedType
    for _, typeNode0 in ipairs(types or {}) do
        local typeNode = ast.SkipTypeParentheses(typeNode0)
        if typeNode.kind == Kind.NeverKeyword then
            if isIntersection then
                return self.f:NewVoidZeroExpression() -- Reduce to `never` in an intersection
            end
            goto continue -- Elide `never` in a union
        end

        if typeNode.kind == Kind.UnknownKeyword then
            if not isIntersection then
                return self.f:NewIdentifier("Object") -- Reduce to `unknown` in a union
            end
            goto continue -- Elide `unknown` in an intersection
        end

        if typeNode.kind == Kind.AnyKeyword then
            return self.f:NewIdentifier("Object") -- Reduce to `any` in a union or intersection
        end

        if not self.strictNullChecks and ((ast.IsLiteralTypeNode(typeNode) and typeNode:AsLiteralTypeNode().literal.kind == Kind.NullKeyword) or typeNode.kind == Kind.UndefinedKeyword) then
            goto continue -- Elide null and undefined from unions for metadata, just like what we did prior to the implementation of strict null checks
        end

        do
            local serializedConstituent = self:serializeTypeNode(typeNode)
            if ast.IsIdentifier(serializedConstituent) and serializedConstituent:AsIdentifier().text == "Object" then
                -- One of the individual is global object, return immediately
                return serializedConstituent
            end

            -- If there exists union that is not `void 0` expression, check if the the common type is identifier.
            -- anything more complex and we will just default to Object
            if serializedType ~= nil then
                -- Different types
                if not self:equateSerializedTypeNodes(serializedType, serializedConstituent) then
                    return self.f:NewIdentifier("Object")
                end
            else
                -- Initialize the union type
                serializedType = serializedConstituent
            end
        end
        ::continue::
    end

    -- If we were able to find common type, use it
    if serializedType ~= nil then
        return serializedType
    end
    return self.f:NewVoidZeroExpression() -- Fallback is only hit if all union constituents are null/undefined/never
end

function metadataSerializer:serializeLiteralOfLiteralTypeNode(node)
    local kind = node.kind
    if kind == Kind.StringLiteral or kind == Kind.NoSubstitutionTemplateLiteral then
        return self.f:NewIdentifier("String")
    elseif kind == Kind.PrefixUnaryExpression then
        local operand = node:AsPrefixUnaryExpression().operand
        if operand.kind == Kind.NumericLiteral or operand.kind == Kind.BigIntLiteral then
            return self:serializeLiteralOfLiteralTypeNode(operand)
        else
            debug.FailBadSyntaxKind(operand)
        end
    elseif kind == Kind.NumericLiteral then
        return self.f:NewIdentifier("Number")
    elseif kind == Kind.BigIntLiteral then
        return self:serializeBigIntConstructor()
    elseif kind == Kind.TrueKeyword or kind == Kind.FalseKeyword then
        return self.f:NewIdentifier("Boolean")
    elseif kind == Kind.NullKeyword then
        return self.f:NewVoidZeroExpression()
    else
        debug.FailBadSyntaxKind(node)
        return nil
    end
    return nil
end

--[[*
* Serializes a TypeReferenceNode to an appropriate JS constructor value for use with decorator type metadata.
* @param node The type reference node.
 ]]
function metadataSerializer:serializeTypeReferenceNode(node)
    local serialScope = self.c.currentNameScope
    if serialScope == nil then
        serialScope = self.c.currentLexicalScope
    end
    local kind = self.resolver:GetTypeReferenceSerializationKind(self.ec:ParseNode(node.typeName), self.ec:ParseNode(serialScope))
    if kind == printer.TypeReferenceSerializationKindUnknown then
        -- From conditional type type reference that cannot be resolved is Similar to any or unknown
        if self.c.serializingConditionalTypeBranch then
            return self.f:NewIdentifier("Object")
        end

        local serialized = self:serializeEntityNameAsExpressionFallback(node.typeName)
        local temp = self.f:NewTempVariable()
        self.ec:AddVariableDeclaration(temp)
        return self.f:NewConditionalExpression(
            self.f:NewTypeCheck(self.f:NewAssignmentExpression(temp, serialized), "function"),
            self.f:NewToken(Kind.QuestionToken),
            temp,
            self.f:NewToken(Kind.ColonToken),
            self.f:NewIdentifier("Object")
        )
    elseif kind == printer.TypeReferenceSerializationKindTypeWithConstructSignatureAndValue then
        return self:serializeEntityNameAsExpression(node.typeName)
    elseif kind == printer.TypeReferenceSerializationKindVoidNullableOrNeverType then
        return self.f:NewVoidZeroExpression()
    elseif kind == printer.TypeReferenceSerializationKindBigIntLikeType then
        return self:serializeBigIntConstructor()
    elseif kind == printer.TypeReferenceSerializationKindBooleanType then
        return self.f:NewIdentifier("Boolean")
    elseif kind == printer.TypeReferenceSerializationKindNumberLikeType then
        return self.f:NewIdentifier("Number")
    elseif kind == printer.TypeReferenceSerializationKindStringLikeType then
        return self.f:NewIdentifier("String")
    elseif kind == printer.TypeReferenceSerializationKindArrayLikeType then
        return self.f:NewIdentifier("Array")
    elseif kind == printer.TypeReferenceSerializationKindESSymbolType then
        return self.f:NewIdentifier("Symbol")
    elseif kind == printer.TypeReferenceSerializationKindTypeWithCallSignature then
        return self.f:NewIdentifier("Function")
    elseif kind == printer.TypeReferenceSerializationKindPromise then
        return self.f:NewIdentifier("Promise")
    elseif kind == printer.TypeReferenceSerializationKindObjectType then
        return self.f:NewIdentifier("Object")
    else
        debug.AssertNever(kind, "unknown type reference serialization kind")
        return nil
    end
end

function metadataSerializer:serializeBigIntConstructor()
    if self.languageVersion >= core.ScriptTarget.ES2020 then
        return self.f:NewIdentifier("BigInt")
    end
    return self.f:NewConditionalExpression(
        self.f:NewTypeCheck(self.f:NewIdentifier("BigInt"), "function"),
        self.f:NewToken(Kind.QuestionToken),
        self.f:NewIdentifier("BigInt"),
        self.f:NewToken(Kind.ColonToken),
        self.f:NewIdentifier("Object")
    )
end

--[[*
* Serializes an entity name as an expression for decorator type metadata.
* @param node The entity name to serialize.
 ]]
function metadataSerializer:serializeEntityNameAsExpression(node)
    if node.kind == Kind.Identifier then
        -- Create a clone of the name with a new parent, and treat it as if it were
        -- a source tree node for the purposes of the checker.
        local name = node:Clone(self.f)
        name.loc = node.loc
        self.ec:UnsetOriginal(name) -- make this identifier emulate a parse node, making it behave correctly when inspected by the module transforms
        name.parent = self.ec:ParseNode(self.c.currentLexicalScope) -- ensure the parent is set to a parse tree node.
        return name
    elseif node.kind == Kind.QualifiedName then
        return self:serializeQualifiedNameAsExpression(node:AsQualifiedName())
    end
    return nil
end

--[[*
* Serializes an qualified name as an expression for decorator type metadata.
* @param node The qualified name to serialize.
 ]]
function metadataSerializer:serializeQualifiedNameAsExpression(node)
    return self.f:NewPropertyAccessExpression(self:serializeEntityNameAsExpression(node.left), nil, node.right, NodeFlags.None)
end

--[[*
* Serializes an entity name which may not exist at runtime, but whose access shouldn't throw
* @param node The entity name to serialize.
 ]]
function metadataSerializer:serializeEntityNameAsExpressionFallback(node)
    if node.kind == Kind.Identifier then
        -- A -> typeof A !== "undefined" && A
        local copied = self:serializeEntityNameAsExpression(node)
        return self:createCheckedValue(copied, copied)
    end
    if node:AsQualifiedName().left.kind == Kind.Identifier then
        -- A.B -> typeof A !== "undefined" && A.B
        return self:createCheckedValue(self:serializeEntityNameAsExpression(node:AsQualifiedName().left), self:serializeEntityNameAsExpression(node))
    end
    -- A.B.C -> typeof A !== "undefined" && (_a = A.B) !== void 0 && _a.C
    local left = self:serializeEntityNameAsExpressionFallback(node:AsQualifiedName().left)
    local temp = self.f:NewTempVariable()
    self.ec:AddVariableDeclaration(temp)
    return self.f:NewLogicalANDExpression(
        self.f:NewLogicalANDExpression(
            left:AsBinaryExpression().left,
            self.f:NewStrictInequalityExpression(self.f:NewAssignmentExpression(temp, left:AsBinaryExpression().right), self.f:NewVoidZeroExpression())
        ),
        self.f:NewPropertyAccessExpression(temp, nil, node:AsQualifiedName().right, NodeFlags.None)
    )
end

--[[*
* Produces an expression that results in `right` if `left` is not undefined at runtime:
*
* ```
* typeof left !== "undefined" && right
* ```
*
* We use `typeof L !== "undefined"` (rather than `L !== undefined`) since `L` may not be declared.
* It's acceptable for this expression to result in `false` at runtime, as the result is intended to be
* further checked by any containing expression.
 ]]
function metadataSerializer:createCheckedValue(left, right)
    return self.f:NewLogicalANDExpression(
        self.f:NewStrictInequalityExpression(self.f:NewTypeOfExpression(left), self.f:NewStringLiteral("undefined", ast.TokenFlags.None)),
        right
    )
end

function metadataSerializer:equateSerializedTypeNodes(left, right)
    -- temp vars used in fallback
    if transformers.IsGeneratedIdentifier(self.ec, left) then
        return transformers.IsGeneratedIdentifier(self.ec, right)
    end
    -- entity names
    if ast.IsIdentifier(left) then
        return ast.IsIdentifier(right) and left:Text() == right:Text()
    end
    if ast.IsPropertyAccessExpression(left) then
        return ast.IsPropertyAccessExpression(right) and self:equateSerializedTypeNodes(left:Expression(), right:Expression()) and self:equateSerializedTypeNodes(left:Name(), right:Name())
    end
    -- `void 0`
    if ast.IsVoidExpression(left) then
        return ast.IsVoidExpression(right) and ast.IsNumericLiteral(left:Expression()) and ast.IsNumericLiteral(right:Expression()) and left:Expression():Text() == "0" and right:Expression():Text() == "0"
    end
    -- `"undefined"` or `"function"` in `typeof` checks
    if ast.IsStringLiteral(left) then
        return ast.IsStringLiteral(right) and left:Text() == right:Text()
    end
    -- used in `typeof` checks for fallback
    if ast.IsTypeOfExpression(left) then
        return ast.IsTypeOfExpression(right) and self:equateSerializedTypeNodes(left:Expression(), right:Expression())
    end
    -- parens in `typeof` checks with temps
    if ast.IsParenthesizedExpression(left) then
        return ast.IsParenthesizedExpression(right) and self:equateSerializedTypeNodes(left:Expression(), right:Expression())
    end
    -- conditionals used in fallback
    if ast.IsConditionalExpression(left) then
        return ast.IsConditionalExpression(right) and self:equateSerializedTypeNodes(left:AsConditionalExpression().condition, right:AsConditionalExpression().condition) and self:equateSerializedTypeNodes(left:AsConditionalExpression().whenTrue, right:AsConditionalExpression().whenTrue) and self:equateSerializedTypeNodes(left:AsConditionalExpression().whenFalse, right:AsConditionalExpression().whenFalse)
    end
    -- logical binary and assignments used in fallback
    if ast.IsBinaryExpression(left) then
        return ast.IsBinaryExpression(right) and left:AsBinaryExpression().operatorToken.kind == right:AsBinaryExpression().operatorToken.kind and self:equateSerializedTypeNodes(left:AsBinaryExpression().left, right:AsBinaryExpression().left) and self:equateSerializedTypeNodes(left:AsBinaryExpression().right, right:AsBinaryExpression().right)
    end
    return false
end
