local pseudochecker = require("tslua.pseudochecker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")

local PseudoChecker = pseudochecker.PseudoChecker
local Kind = ast.Kind
local PseudoTypeKind = pseudochecker.PseudoTypeKind

local returnSignatureKinds = ast.kindSet(
    Kind.MethodDeclaration, Kind.FunctionDeclaration, Kind.Constructor,
    Kind.MethodSignature, Kind.CallSignature, Kind.ConstructSignature,
    Kind.SetAccessor, Kind.IndexSignature, Kind.FunctionType, Kind.ConstructorType,
    Kind.FunctionExpression, Kind.ArrowFunction, Kind.JSDocSignature
)

function PseudoChecker:GetReturnTypeOfSignature(signatureNode)
    if signatureNode.kind == Kind.GetAccessor then
        return self:GetTypeOfAccessor(signatureNode)
    elseif returnSignatureKinds[signatureNode.kind] then
        return self:createReturnFromSignature(signatureNode)
    else
        debug.FailBadSyntaxKind(signatureNode, "Node needs to be an inferrable node")
        return nil
    end
end

function PseudoChecker:GetTypeOfAccessor(accessor)
    return self:typeFromAccessor(accessor)
end

function PseudoChecker:GetTypeOfExpression(node)
    return self:typeFromExpression(node)
end

function PseudoChecker:GetTypeOfDeclaration(node)
    local k = node.kind
    if k == Kind.Parameter then
        return self:typeFromParameter(node:AsParameterDeclaration())
    elseif k == Kind.VariableDeclaration then
        return self:typeFromVariable(node:AsVariableDeclaration())
    elseif k == Kind.PropertySignature or k == Kind.PropertyDeclaration or k == Kind.JSDocPropertyTag then
        return self:typeFromProperty(node)
    elseif k == Kind.BindingElement then
        return pseudochecker.NewPseudoTypeNoResult(node)
    elseif k == Kind.ExportAssignment then
        return self:typeFromExpression(node:AsExportAssignment().expression)
    elseif k == Kind.PropertyAccessExpression or k == Kind.ElementAccessExpression or k == Kind.BinaryExpression then
        return self:typeFromExpandoProperty(node)
    elseif k == Kind.PropertyAssignment or k == Kind.ShorthandPropertyAssignment then
        return self:typeFromPropertyAssignment(node)
    elseif k == Kind.CallExpression then
        local declKind = ast.GetAssignmentDeclarationKind(node)
        -- TODO: How much of the checker's getTypeFromPropertyDescriptor is worth trying to emulate over ASTs?
        if declKind == ast.JSDeclarationKind.ObjectDefinePropertyValue then
            -- !!!
        elseif declKind == ast.JSDeclarationKind.ObjectDefinePropertyExports then
            -- !!!
        end
        return pseudochecker.NewPseudoTypeNoResult(node)
    else
        debug.FailBadSyntaxKind(node, "node needs to be an inferrable node")
        return nil
    end
end

function PseudoChecker:typeFromPropertyAssignment(node)
    local annotation = node:Type()
    if annotation ~= nil then
        return pseudochecker.NewPseudoTypeDirect(annotation)
    end
    if node.kind == Kind.PropertyAssignment then
        local init = node:Initializer()
        if init ~= nil then
            local expr = self:typeFromExpression(init)
            if expr ~= nil and (expr.kind ~= PseudoTypeKind.Inferred or core.Len(expr:AsPseudoTypeInferred().errorNodes) > 0) then
                return expr
            end
            -- fallback to NoResult if PseudoTypeKindInferred without error nodes
        end
    end
    return pseudochecker.NewPseudoTypeNoResult(node)
end

-- This is _not_ redundant with the reparser; see how expandoFunctionSymbolProperty.ts and similar behaves
function PseudoChecker:typeFromExpandoProperty(node)
    local declaredType = node:Type()
    if declaredType ~= nil then
        return pseudochecker.NewPseudoTypeDirect(declaredType)
    end
    -- While `node` is an expression, as an expando, it should also always be a
    -- declaration with a `.Symbol()` which requires declaration fallback handling
    return pseudochecker.NewPseudoTypeNoResult(node)
end

function PseudoChecker:typeFromProperty(node)
    local t = node:Type()
    if t ~= nil then
        return pseudochecker.NewPseudoTypeDirect(t)
    end
    if ast.IsPropertyDeclaration(node) then
        local init = node:Initializer()
        if init ~= nil and not pseudochecker.isContextuallyTyped(node) then
            -- explicit fail on readonly template literals to allow for literal freshness in the future
            if ast.HasModifier(node, ast.ModifierFlags.Readonly) and ast.IsTemplateExpression(init) then
                return pseudochecker.NewPseudoTypeNoResult(node)
            end
            local expr = self:typeFromExpression(init)
            if expr ~= nil and (expr.kind ~= PseudoTypeKind.Inferred or core.Len(expr:AsPseudoTypeInferred().errorNodes) > 0) then
                local postfixToken = node:AsPropertyDeclaration().postfixToken
                if expr.kind ~= PseudoTypeKind.Direct and postfixToken ~= nil and postfixToken.kind == Kind.QuestionToken then
                    -- type comes from the initializer expression on a property with a `?` - add `| undefined` to the type
                    return pseudochecker.addUndefinedIfDefinitelyRequired(expr)
                end
                return expr
            end
            -- fallback to NoResult if PseudoTypeKindInferred without error nodes
        end
    end
    return pseudochecker.NewPseudoTypeNoResult(node)
end

function PseudoChecker:typeFromVariable(declaration)
    local t = declaration.type
    if t ~= nil then
        return pseudochecker.NewPseudoTypeDirect(t)
    end
    local init = declaration.initializer
    if init ~= nil and declaration.symbol ~= nil and (core.Len(declaration.symbol.declarations) == 1 or core.CountWhere(declaration.symbol.declarations, ast.IsVariableDeclaration) == 1) then
        if not pseudochecker.isContextuallyTyped(declaration) then -- TODO: also should bail on expando declarations; reuse syntactic expando check used in declaration emit
            -- TODO: Strada forces an inference fallback on `const` variables with template expression initializers, to leave space for template literal freshness in the future
            if ast.IsVarConst(declaration) and ast.IsTemplateExpression(init) then
                return pseudochecker.NewPseudoTypeNoResult(declaration)
            end
            local expr = self:typeFromExpression(init)
            if expr ~= nil and (expr.kind ~= PseudoTypeKind.Inferred or core.Len(expr:AsPseudoTypeInferred().errorNodes) > 0) then
                return expr
            end
            -- fallback to NoResult if PseudoTypeKindInferred without error nodes
        end
    end
    return pseudochecker.NewPseudoTypeNoResult(declaration)
end

function PseudoChecker:typeFromAccessor(accessor)
    local accessorDeclarations = ast.GetAllAccessorDeclarationsForDeclaration(accessor, accessor:DeclarationData().symbol.declarations)
    local accessorType = self:getTypeAnnotationFromAllAccessorDeclarations(accessor, accessorDeclarations)
    if accessorType ~= nil and not ast.IsTypePredicateNode(accessorType) then
        return pseudochecker.NewPseudoTypeDirect(accessorType)
    end
    if accessorDeclarations.getAccessor ~= nil then
        local res = self:createReturnFromSignature(accessorDeclarations.getAccessor)
        if res.kind == PseudoTypeKind.Inferred and core.Len(res:AsPseudoTypeInferred().errorNodes) == 0 then
            local errorNodes = { accessorDeclarations.getAccessor }
            if accessorDeclarations.setAccessor ~= nil then
                errorNodes[#errorNodes + 1] = accessorDeclarations.setAccessor
            end
            res = pseudochecker.NewPseudoTypeInferredWithErrors(res:AsPseudoTypeInferred().expression, res:AsPseudoTypeInferred().isSignatureReturn, errorNodes) -- Move error up to the accessor
        end
        return res
    end
    return pseudochecker.NewPseudoTypeNoResult(accessor)
end

function PseudoChecker:getTypeAnnotationFromAllAccessorDeclarations(node, accessors)
    local accessorType = self:getTypeAnnotationFromAccessor(node)
    if accessorType == nil and node ~= accessors.firstAccessor then
        accessorType = self:getTypeAnnotationFromAccessor(accessors.firstAccessor)
    end
    if accessorType == nil and accessors.secondAccessor ~= nil and node ~= accessors.secondAccessor then
        accessorType = self:getTypeAnnotationFromAccessor(accessors.secondAccessor)
    end
    return accessorType
end

function PseudoChecker:getTypeAnnotationFromAccessor(node)
    if node == nil then
        return nil
    end
    -- !!! TODO: support ripping return type off of .FullSignature
    if node.kind == Kind.GetAccessor then
        return node:AsGetAccessorDeclaration().type
    end
    local set = node:AsSetAccessorDeclaration()
    if set.parameters == nil or core.Len(set.parameters.nodes) < 1 then
        return nil
    end
    local p = set.parameters.nodes[1]
    if not ast.IsParameterDeclaration(p) then
        return nil
    end
    return p:AsParameterDeclaration().type
end

function pseudochecker.isValueSignatureDeclaration(node)
    return ast.IsFunctionExpression(node) or ast.IsArrowFunction(node) or ast.IsMethodDeclaration(node) or ast.IsAccessor(node) or ast.IsFunctionDeclaration(node) or ast.IsConstructorDeclaration(node)
end

-- does not return `nil`, returns a `NoResult` pseudotype instead
function PseudoChecker:createReturnFromSignature(fn)
    if ast.IsFunctionLike(fn) then
        local d = fn:FunctionLikeData()
        -- !!! TODO: support ripping return type off of .FullSignature
        local r = d.type
        if r ~= nil then
            return pseudochecker.NewPseudoTypeDirect(r)
        end
    end
    if pseudochecker.isValueSignatureDeclaration(fn) then
        return self:typeFromSingleReturnExpression(fn)
    end
    return pseudochecker.NewPseudoTypeNoResult(fn)
end

function PseudoChecker:typeFromSingleReturnExpression(fn)
    local candidateExpr
    if fn ~= nil and not ast.NodeIsMissing(fn:Body()) then
        local flags = ast.GetFunctionFlags(fn)
        if flags & ast.FunctionFlags.AsyncGenerator ~= 0 then
            return pseudochecker.NewPseudoTypeInferred(fn, true)
        end

        local body = fn:Body()
        if ast.IsBlock(body) then
            ast.ForEachReturnStatement(body, function(stmt)
                if stmt.parent ~= body then -- Why bail on nested return statements?
                    candidateExpr = nil
                    return true
                end
                if candidateExpr == nil then
                    candidateExpr = stmt:AsReturnStatement().expression
                else
                    candidateExpr = nil
                    return true
                end
                return false
            end)
        else
            candidateExpr = body
        end
    end
    if candidateExpr ~= nil then
        if pseudochecker.isContextuallyTyped(candidateExpr) then
            local t
            if candidateExpr.kind == Kind.TypeAssertionExpression then
                t = candidateExpr:AsTypeAssertion().type
            elseif candidateExpr.kind == Kind.AsExpression then
                t = candidateExpr:AsAsExpression().type
            end
            if t ~= nil and not ast.IsConstTypeReference(t) then
                return pseudochecker.NewPseudoTypeDirect(t)
            end
        else
            return self:typeFromExpression(candidateExpr)
        end
    end
    return pseudochecker.NewPseudoTypeInferred(fn, true)
end

-- This is basically `checkExpression` for pseudotypes
function PseudoChecker:typeFromExpression(node)
    local k = node.kind
    if k == Kind.OmittedExpression then
        return pseudochecker.PseudoTypeUndefined
    elseif k == Kind.ParenthesizedExpression then
        -- assertions transformed on reparse, just unwrap
        return self:typeFromExpression(node:AsParenthesizedExpression().expression)
    elseif k == Kind.Identifier then
        -- !!! TODO: in strada, this uses symbol information to ensure `node` refers to the global `undefined` symbol instead
        -- we should probably import `resolveName` and use it here to check for the same; but we have to setup some barebones pseudoglobals for that to work!
        if node:AsIdentifier().text == "undefined" then
            return pseudochecker.PseudoTypeUndefined
        end
    elseif k == Kind.NullKeyword then
        return pseudochecker.PseudoTypeNull
    elseif k == Kind.ArrowFunction or k == Kind.FunctionExpression then
        return self:typeFromFunctionLikeExpression(node)
    elseif k == Kind.TypeAssertionExpression then
        return self:typeFromTypeAssertion(node:AsTypeAssertion().expression, node:AsTypeAssertion().type)
    elseif k == Kind.AsExpression then
        return self:typeFromTypeAssertion(node:AsAsExpression().expression, node:AsAsExpression().type)
    elseif k == Kind.PrefixUnaryExpression then
        if ast.IsPrimitiveLiteralValue(node, true) then
            return self:typeFromPrimitiveLiteralPrefix(node:AsPrefixUnaryExpression())
        end
    elseif k == Kind.ArrayLiteralExpression then
        return self:typeFromArrayLiteral(node:AsArrayLiteralExpression())
    elseif k == Kind.ObjectLiteralExpression then
        return self:typeFromObjectLiteral(node:AsObjectLiteralExpression())
    elseif k == Kind.ClassExpression then
        return pseudochecker.NewPseudoTypeInferredWithErrors(node, false, { node }) -- No possible annotation/directly mappable syntax
    elseif k == Kind.TemplateExpression then
        -- templateLitWithHoles as const, not supported
        if pseudochecker.IsInConstContext(node) then
            return pseudochecker.NewPseudoTypeInferred(node, false)
        end
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeInferred(node, false), pseudochecker.PseudoTypeString)
    elseif k == Kind.NumericLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeNumericLiteral(node), pseudochecker.PseudoTypeNumber)
    elseif k == Kind.NoSubstitutionTemplateLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeStringLiteral(node), pseudochecker.PseudoTypeString)
    elseif k == Kind.StringLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeStringLiteral(node), pseudochecker.PseudoTypeString)
    elseif k == Kind.BigIntLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeBigIntLiteral(node), pseudochecker.PseudoTypeBigInt)
    elseif k == Kind.TrueKeyword then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.PseudoTypeTrue, pseudochecker.PseudoTypeBoolean)
    elseif k == Kind.FalseKeyword then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.PseudoTypeFalse, pseudochecker.PseudoTypeBoolean)
    end
    return pseudochecker.NewPseudoTypeInferred(node, false)
end

function PseudoChecker:typeFromObjectLiteral(node)
    local errorNodes = self:canGetTypeFromObjectLiteral(node)
    if errorNodes ~= nil then
        return pseudochecker.NewPseudoTypeInferredWithErrors(node, false, errorNodes)
    end
    -- we are in a const context producing an object literal type, there are no shorthand or spread assignments
    if node.properties == nil or core.Len(node.properties.nodes) == 0 then
        return pseudochecker.NewPseudoTypeObjectLiteral(nil)
    end
    local results = {}
    for _, e in ipairs(node.properties.nodes) do
        if e.kind == Kind.MethodDeclaration then
            local postfixToken = e:AsMethodDeclaration().postfixToken
            local optional = postfixToken ~= nil and postfixToken.kind == Kind.QuestionToken
            if e:FunctionLikeData().fullSignature ~= nil then
                results[#results + 1] = pseudochecker.NewPseudoPropertyAssignment(
                    false,
                    e:Name(),
                    optional,
                    pseudochecker.NewPseudoTypeDirect(e:FunctionLikeData().fullSignature)
                )
            else
                results[#results + 1] = pseudochecker.NewPseudoObjectMethod(
                    e,
                    e:Name(),
                    optional,
                    self:cloneTypeParameters(e:AsMethodDeclaration().typeParameters),
                    self:cloneParameters(e:ParameterList()),
                    self:createReturnFromSignature(e)
                )
            end
        elseif e.kind == Kind.PropertyAssignment then
            local postfixToken = e:AsPropertyAssignment().postfixToken
            results[#results + 1] = pseudochecker.NewPseudoPropertyAssignment(
                false,
                e:Name(),
                postfixToken ~= nil and postfixToken.kind == Kind.QuestionToken,
                self:typeFromExpression(e:Initializer())
            )
        elseif e.kind == Kind.SetAccessor or e.kind == Kind.GetAccessor then
            local member = self:getAccessorMember(e, e:Name())
            if member ~= nil then
                results[#results + 1] = member
            end
        end
    end
    return pseudochecker.NewPseudoTypeObjectLiteral(results)
end

-- roughly analogous to typeFromObjectLiteralAccessor in strada
function PseudoChecker:getAccessorMember(accessor, name)
    local allAccessors = ast.GetAllAccessorDeclarationsForDeclaration(accessor, accessor:Symbol().declarations) -- TODO: node preservation for late-bound accessor pairs?

    -- TODO: handle pseudo-annotations from get accessor return positions?
    if allAccessors.getAccessor ~= nil and allAccessors.getAccessor.type ~= nil and
        allAccessors.setAccessor ~= nil and core.Len(allAccessors.setAccessor.parameters.nodes) > 0 and allAccessors.setAccessor.parameters.nodes[1]:AsParameterDeclaration().type ~= nil then
        -- We have possible types for both accessors, we can't know if they are the same type so we keep both accessors

        if ast.IsGetAccessorDeclaration(accessor) then
            return pseudochecker.NewPseudoGetAccessor(
                accessor,
                name,
                false,
                self:typeFromAccessor(accessor)
            )
        else
            return pseudochecker.NewPseudoSetAccessor(
                accessor,
                name,
                false,
                self:cloneParameters(accessor:AsSetAccessorDeclaration().parameters)[1]
            )
        end
    end

    if accessor == allAccessors.firstAccessor then
        -- only one annotated accessor; output a property - `readonly` for a single `get` accessor

        local accessorType = self:typeFromAccessor(accessor)
        local readonly = ast.IsGetAccessorDeclaration(accessor) and allAccessors.secondAccessor == nil
        return pseudochecker.NewPseudoPropertyAssignment(
            readonly,
            name,
            false,
            accessorType
        )
    end
    return nil
end

-- canGetTypeFromObjectLiteral checks whether an object literal can be typed by the pseudochecker.
-- Returns nil if the object can be typed, or a slice of error nodes (shorthand/spread properties,
-- non-literal computed names) that prevent typing.
function PseudoChecker:canGetTypeFromObjectLiteral(node)
    if node.properties == nil or core.Len(node.properties.nodes) == 0 then
        return nil -- empty object, ok
    end
    local errorNodes
    for _, e in ipairs(node.properties.nodes) do
        if e.flags & ast.NodeFlags.ThisNodeHasError ~= 0 then
            errorNodes = core.Append(errorNodes, e)
        elseif e.kind == Kind.ShorthandPropertyAssignment or e.kind == Kind.SpreadAssignment then
            errorNodes = core.Append(errorNodes, e)
        elseif e:Name().flags & ast.NodeFlags.ThisNodeHasError ~= 0 then
            errorNodes = core.Append(errorNodes, e:Name())
        elseif e:Name().kind == Kind.PrivateIdentifier then
            errorNodes = core.Append(errorNodes, e)
        elseif e:Name().kind == Kind.ComputedPropertyName then
            local expression = e:Name():Expression()
            if not ast.IsPrimitiveLiteralValue(expression, false) then
                errorNodes = core.Append(errorNodes, e:Name())
            end
        end
    end
    return errorNodes
end

function PseudoChecker:typeFromArrayLiteral(node)
    local errorNodes = self:canGetTypeFromArrayLiteral(node)
    if errorNodes ~= nil then
        return pseudochecker.NewPseudoTypeInferredWithErrors(node, false, errorNodes)
    end
    if pseudochecker.IsInConstContext(node) and pseudochecker.isContextuallyTyped(node) then
        return pseudochecker.NewPseudoTypeInferred(node, false) -- expr in an as const cast with a contextual type has variable readonly state, bail
    end
    -- we are in a const context producing a tuple type, there are no spread elements
    local results = {}
    for _, e in ipairs(node.elements.nodes or {}) do
        results[#results + 1] = self:typeFromExpression(e)
    end
    return pseudochecker.NewPseudoTypeTuple(results)
end

-- canGetTypeFromArrayLiteral checks whether an array literal can be typed by the pseudochecker.
-- Returns nil if the array can be typed, or a slice of error nodes that prevent typing.
-- For non-const arrays, the error node is the array expression itself.
-- For const arrays with spreads, the error node is the spread element.
function PseudoChecker:canGetTypeFromArrayLiteral(node)
    if not pseudochecker.IsInConstContext(node) then
        return { node }
    end
    for _, e in ipairs(node.elements.nodes or {}) do
        if e.kind == Kind.SpreadElement then
            return { e }
        end
    end
    return nil
end

-- See `isConstContext` in `checker.go` - this is basically any node kind mentioned in that
local constContextPropagatingKinds = ast.kindSet(
    Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression,
    Kind.ParenthesizedExpression, Kind.SpreadElement, Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment, Kind.TemplateSpan, Kind.PrefixUnaryExpression
)

function pseudochecker.isConstContextPropagatingKind(kind)
    return constContextPropagatingKinds[kind] == true
end

-- IsInConstContext traverses up the parent chain to determine if the node is within a const context without needing any
-- persistent traversal scope tracking (which could be unreliable in the presence of `typeof` queries anyway!)
function pseudochecker.IsInConstContext(node)
    -- An expression is in a const context if an ancestor is a const type maybeAssertion expression
    local maybeAssertion = ast.FindAncestor(
        node.parent,
        function(n)
            -- stop traversing at assertions or anything not an array/object literal, since only those create or transfer const-ness
            return ast.IsAssertionExpression(n) or not pseudochecker.isConstContextPropagatingKind(n.kind)
        end
    )
    return ast.IsConstAssertion(maybeAssertion)
end

function PseudoChecker:typeFromPrimitiveLiteralPrefix(node)
    local expr = node
    if node.operator == Kind.PlusToken then
        expr = node.operand
    end
    local inner = node.operand
    if inner.kind == Kind.BigIntLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeBigIntLiteral(expr), pseudochecker.PseudoTypeBigInt)
    end
    if inner.kind == Kind.NumericLiteral then
        return pseudochecker.NewPseudoTypeMaybeConstLocation(node, pseudochecker.NewPseudoTypeNumericLiteral(expr), pseudochecker.PseudoTypeNumber)
    end
    debug.FailBadSyntaxKind(inner)
    return nil
end

function PseudoChecker:typeFromTypeAssertion(expression, typeNode)
    if ast.IsConstTypeReference(typeNode) then
        return self:typeFromExpression(expression)
    end
    return pseudochecker.NewPseudoTypeDirect(typeNode)
end

function PseudoChecker:typeFromFunctionLikeExpression(node)
    if node:FunctionLikeData().fullSignature ~= nil then
        return pseudochecker.NewPseudoTypeDirect(node:FunctionLikeData().fullSignature)
    end
    local returnType = self:createReturnFromSignature(node)
    local typeParameters = self:cloneTypeParameters(node:FunctionLikeData().typeParameters)
    local parameters = self:cloneParameters(node:FunctionLikeData().parameters)
    return pseudochecker.NewPseudoTypeSingleCallSignature(
        node,
        parameters,
        typeParameters,
        returnType
    )
end

function PseudoChecker:cloneTypeParameters(nodes)
    if nodes == nil then
        return nil
    end
    if core.Len(nodes.nodes) == 0 then
        return nil
    end
    local result = {}
    for _, e in ipairs(nodes.nodes) do
        result[#result + 1] = e:AsTypeParameterDeclaration()
    end
    return result
end

function pseudochecker.isUndefinedPseudoType(t)
    return t.kind == PseudoTypeKind.Undefined or (t.kind == PseudoTypeKind.MaybeConstLocation and pseudochecker.isUndefinedPseudoType(t:AsPseudoTypeMaybeConstLocation().constType))
end

function pseudochecker.typeNodeCouldReferToUndefined(node)
    while node.kind == Kind.ParenthesizedType do
        node = node:AsParenthesizedTypeNode().type
    end
    local k = node.kind
    -- these types require symbolic/type resolution to know if they definitely do or do not refer to `undefined`, so might (or definitely do)
    if k == Kind.TypeReference or k == Kind.IndexedAccessType or k == Kind.TypeQuery or k == Kind.OptionalType or k == Kind.RestType or k == Kind.ImportType then
        return true
    elseif k == Kind.IntersectionType then
        -- TODO: why is this not `core.Every`? strada treated unions and intersections the same, but logically every intersection member needs to contain a possible `undefined`
        -- for the result type to contain `undefined`. Likely a bug persisting from strada.
        return core.Some(node:AsIntersectionTypeNode().types.nodes, pseudochecker.typeNodeCouldReferToUndefined)
    elseif k == Kind.UnionType then
        return core.Some(node:AsUnionTypeNode().types.nodes, pseudochecker.typeNodeCouldReferToUndefined)
    elseif k == Kind.ConditionalType then -- suspect - should be treated as a union of both branches instead, likely a bug persisted from strada
        return true
    elseif k == Kind.TypeOperator then -- suspect - always refers to a subset of `string | number | symbol` for `keyof` or `symbol` for `unique`
        return true
    elseif k == Kind.TypePredicate then -- suspect - always refers to `never` or `boolean`, depending on kind - considered possibly-`undefined` referencing for strada compat
        return true
    elseif k == Kind.UndefinedKeyword then
        return true
    else -- all other keywords, literal types, function-y types, array/tuple types, type literals, template types, this types
        return false
    end
end

-- see this as the inverse of `canAddUndefined` in `expressionToTypeNode` in strada
function pseudochecker.CouldAlreadyReferToUndefinedType(t)
    if t.kind == PseudoTypeKind.NoResult or t.kind == PseudoTypeKind.Inferred or pseudochecker.isUndefinedPseudoType(t) then
        return true
    end
    if t.kind == PseudoTypeKind.MaybeConstLocation then
        local mc = t:AsPseudoTypeMaybeConstLocation()
        return pseudochecker.CouldAlreadyReferToUndefinedType(mc.regularType) -- if we're even asking this question, it's not a `const` location
    end
    if t.kind == PseudoTypeKind.Direct then
        -- inspect the direct type node
        local node = t:AsPseudoTypeDirect().typeNode
        return pseudochecker.typeNodeCouldReferToUndefined(node)
    end
    if t.kind == PseudoTypeKind.Union then
        return core.Some(t:AsPseudoTypeUnion().types, pseudochecker.CouldAlreadyReferToUndefinedType)
    end
    return false
end

function pseudochecker.isOptionalInitializedOrRestParameter(node)
    local p = node:AsParameterDeclaration()
    if p.dotDotDotToken ~= nil or p.initializer ~= nil or p.questionToken ~= nil then
        return true
    end
    return false
end

-- lastRequiredParamIndex returns the index just past the last required parameter
-- in the list. A parameter is "required" if it has no question token, no initializer,
-- and no rest token. This is computed in a single reverse pass so callers can
-- determine "has required parameter after index i" with `i+1 < lastRequired`
-- (equivalently, `i < lastRequired-1`) in O(1).
function pseudochecker.lastRequiredParamIndex(params)
    for i = core.Len(params) - 1, 0, -1 do
        if not pseudochecker.isOptionalInitializedOrRestParameter(params[i + 1]) then
            return i + 1
        end
    end
    return 0
end

function pseudochecker.addUndefinedIfDefinitelyRequired(expr)
    -- If `expr` doesn't already contain `| undefined` or a direct/inferred type that may contain `undefined`, add `| undefined`
    -- in Strada, this reached into the checker to see if `undefined` was necessary, using `isRequiredOptionalParameter` from the emit resolver,
    -- but that's not required on top of the syntactic checks to get the same behavior. (If we get the type wrong, it'll mismatch later and be discarded
    -- for an inference error since corsa actually validates that pseudotypes semantically match the inferred type the checker produces)
    if pseudochecker.CouldAlreadyReferToUndefinedType(expr) then
        return expr -- will just error later, more like than not, unless the `undefined` is explicit in the pseudo
    end
    -- Explicitly add an `| undefined`
    return pseudochecker.NewPseudoTypeUnion({ expr, pseudochecker.PseudoTypeUndefined })
end

function PseudoChecker:typeFromParameter(node)
    local parent = node.parent
    if parent.kind == Kind.SetAccessor then
        return self:GetTypeOfAccessor(parent)
    end
    -- Fast path: no initializer means we never need parameter position info.
    if node.initializer == nil then
        if node.type ~= nil then
            return pseudochecker.NewPseudoTypeDirect(node.type)
        end
        return pseudochecker.NewPseudoTypeNoResult(node)
    end
    local p = parent:Parameters()
    local selfIdx = -1
    for i, x in ipairs(p or {}) do
        if x == node then
            selfIdx = i - 1
            break
        end
    end
    local lastRequired = pseudochecker.lastRequiredParamIndex(p)
    return self:typeFromParameterWorker(node, selfIdx, lastRequired)
end

function PseudoChecker:typeFromParameterWorker(node, selfIdx, lastRequired)
    local parent = node.parent
    if parent.kind == Kind.SetAccessor then
        return self:GetTypeOfAccessor(parent)
    end
    local hasRequiredAfter = selfIdx < lastRequired - 1
    local declaredType = node.type
    if declaredType ~= nil then
        local result = pseudochecker.NewPseudoTypeDirect(declaredType)
        -- When the parameter has an initializer and strict null checks are enabled,
        -- check if `| undefined` needs to be added because there are required parameters after this one.
        -- This mirrors the checker's getTypeOfParameter which adds optionality for initialized parameters.
        if self.strictNullChecks and node.initializer ~= nil and hasRequiredAfter then
            return pseudochecker.addUndefinedIfDefinitelyRequired(result)
        end
        return result
    end
    if node.initializer ~= nil and ast.IsIdentifier(node:Name()) and not pseudochecker.isContextuallyTyped(node) then
        local expr = self:typeFromExpression(node.initializer)
        if expr ~= nil and (expr.kind == PseudoTypeKind.Inferred and core.Len(expr:AsPseudoTypeInferred().errorNodes) == 0) then
            expr = pseudochecker.NewPseudoTypeInferredWithErrors(expr:AsPseudoTypeInferred().expression, false, { node }) -- Move error up to the parameter
        end
        if not self.strictNullChecks then
            return expr
        end
        if not hasRequiredAfter then
            return expr
        end
        -- if there is a non-optional parameter after this one, a `| undefined` will need to explicitly be emitted on this parameter, if it's not already there
        return pseudochecker.addUndefinedIfDefinitelyRequired(expr)
    end
    -- TODO: In strada, the ID checker doesn't infer a parameter type from binding pattern names, but the real checker _does_!
    -- This means ID won't let you write, say, `({elem}) => false` without an annotation, even though it's trivially of type
    -- `(p0: {elem: any}) => boolean` and error-free under `noImplicitAny: false`!
    -- That limitation is retained here.
    return pseudochecker.NewPseudoTypeNoResult(node)
end

function PseudoChecker:cloneParameters(nodes)
    if nodes == nil then
        return nil
    end
    if core.Len(nodes.nodes) == 0 then
        return nil
    end
    local lastRequired = pseudochecker.lastRequiredParamIndex(nodes.nodes)
    local result = {}
    for i1, e in ipairs(nodes.nodes) do
        local i = i1 - 1
        local p = e:AsParameterDeclaration()
        local optional = p.questionToken ~= nil
        if not optional and p.initializer ~= nil then
            -- A parameter with an initializer is optional only if all subsequent
            -- parameters are also optional/have initializers/are rest parameters.
            -- This matches the checker's isOptionalParameter semantics.
            optional = i >= lastRequired - 1
        end
        result[#result + 1] = pseudochecker.NewPseudoParameter(
            p.dotDotDotToken ~= nil,
            e:Name(),
            optional,
            self:typeFromParameterWorker(p, i, lastRequired)
        )
    end
    return result
end

function pseudochecker.isContextuallyTyped(node)
    return ast.FindAncestor(node.parent, function(n)
        -- Functions calls or parent type annotations (but not the return type of a function expression) may impact the inferred type and local inference is unreliable
        if ast.IsCallExpression(n) then
            return true
        end
        if ast.IsSatisfiesExpression(n) then
            return true
        end
        if (ast.IsVariableParameterOrProperty(n) or ast.IsAssertionExpression(n)) and n:Type() ~= nil and not ast.IsConstAssertion(n) then
            return true
        end
        return ast.IsJsxElement(n) or ast.IsJsxExpression(n)
    end) ~= nil
end

return pseudochecker
