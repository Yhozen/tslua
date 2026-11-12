local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

function estransforms.convertClassDeclarationToClassExpression(emitContext, node)
    local updated = emitContext.factory:NewClassExpression(
        transformers.ExtractModifiers(emitContext, node:Modifiers(), ~ast.ModifierFlags.ExportDefault),
        node:Name(),
        node.typeParameters,
        node.heritageClauses,
        node.members
    )
    emitContext:SetOriginal(updated, node:AsNode())
    updated.loc = node.loc
    return updated
end

function estransforms.createNotNullCondition(emitContext, left, right, invert)
    local token = Kind.ExclamationEqualsEqualsToken
    local op = Kind.AmpersandAmpersandToken
    if invert then
        token = Kind.EqualsEqualsEqualsToken
        op = Kind.BarBarToken
    end

    return emitContext.factory:NewBinaryExpression(
        nil,
        emitContext.factory:NewBinaryExpression(
            nil,
            left,
            nil,
            emitContext.factory:NewToken(token),
            emitContext.factory:NewKeywordExpression(Kind.NullKeyword)
        ),
        nil,
        emitContext.factory:NewToken(op),
        emitContext.factory:NewBinaryExpression(
            nil,
            right,
            nil,
            emitContext.factory:NewToken(token),
            emitContext.factory:NewVoidZeroExpression()
        )
    )
end

-- superAccessState tracks super property/element accesses and super property assignments
-- within async function or async generator bodies. It is embedded by both asyncTransformer
-- and forawaitTransformer to share the tracking logic.
--
-- Fields: factory, capturedSuperProperties (collections.OrderedSet of string),
-- hasSuperElementAccess, hasSuperPropertyAssignment, superBinding, superIndexBinding,
-- superAccessVisitor. Embedders copy the methods with estransforms.embedSuperAccessState(T)
-- and initialize the bool fields to false.
local superAccessState = {}
superAccessState.__index = superAccessState
estransforms.superAccessState = superAccessState

-- Lua helper (Go struct embedding): promotes the superAccessState methods onto the method table T.
function estransforms.embedSuperAccessState(T)
    for k, v in pairs(superAccessState) do
        if k ~= "__index" and rawget(T, k) == nil then
            T[k] = v
        end
    end
    return T
end

function superAccessState:initSuperAccessVisitor(emitContext, factory)
    self.factory = factory
    self.superAccessVisitor = emitContext:NewNodeVisitor(function(node) return self:visitSuperAccessNode(node) end)
end

-- visitSuperAccessNode walks the async/generator body and replaces super property/element
-- accesses with _super/_superIndex references. This is necessary because the async body
-- ends up inside a generator function where `super` is not valid.
function superAccessState:visitSuperAccessNode(node)
    local k = node.kind
    if k == Kind.CallExpression then
        local call = node:AsCallExpression()
        if ast.IsSuperProperty(call.expression) then
            return self:substituteCallExpressionWithSuperAccess(call, self.superAccessVisitor)
        end
        return self.superAccessVisitor:VisitEachChild(node)
    elseif k == Kind.PropertyAccessExpression then
        if node:Expression().kind == Kind.SuperKeyword then
            -- super.x → _super.x
            return self.factory:NewPropertyAccessExpression(
                self.superBinding, nil, node:Name(), NodeFlags.None
            )
        end
        return self.superAccessVisitor:VisitEachChild(node)
    elseif k == Kind.ElementAccessExpression then
        if node:Expression().kind == Kind.SuperKeyword then
            -- super[x] → _superIndex(x) or _superIndex(x).value
            return self:createSuperElementAccessInAsyncMethod(
                node:AsElementAccessExpression().argumentExpression
            )
        end
        return self.superAccessVisitor:VisitEachChild(node)
    -- Don't recurse into non-arrow function scopes or classes
    elseif k == Kind.FunctionExpression or k == Kind.FunctionDeclaration or
        k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor or
        k == Kind.Constructor or k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return node
    else
        return self.superAccessVisitor:VisitEachChild(node)
    end
end

function superAccessState:substituteSuperAccessesInBody(body)
    return self.superAccessVisitor:VisitNode(body)
end

-- substituteCallExpressionWithSuperAccess handles super.x(args) and super[x](args).
function superAccessState:substituteCallExpressionWithSuperAccess(call, visitor)
    local expression = call.expression
    local target

    if ast.IsPropertyAccessExpression(expression) then
        -- super.x(args) → _super.x.call(this, args)
        target = self.factory:NewPropertyAccessExpression(
            self.superBinding, nil,
            expression:AsPropertyAccessExpression():Name(), NodeFlags.None
        )
    elseif ast.IsElementAccessExpression(expression) then
        -- super[x](args) → _superIndex(x).call(this, args) or _superIndex(x).value.call(this, args)
        target = self:createSuperElementAccessInAsyncMethod(
            expression:AsElementAccessExpression().argumentExpression
        )
    else
        return visitor:VisitEachChild(call:AsNode())
    end

    local callTarget = self.factory:NewPropertyAccessExpression(
        target, nil,
        self.factory:NewIdentifier("call"), NodeFlags.None
    )

    local allArgs = {}
    allArgs[#allArgs + 1] = self.factory:NewThisExpression()
    if call.arguments ~= nil then
        local visitedArgs = visitor:VisitNodes(call.arguments)
        if visitedArgs ~= nil then
            for _, a in ipairs(visitedArgs.nodes or {}) do
                allArgs[#allArgs + 1] = a
            end
        end
    end

    local result = self.factory:NewCallExpression(
        callTarget, nil, nil,
        self.factory:NewNodeList(allArgs), NodeFlags.None
    )
    result.loc = call.loc
    return result
end

-- createSuperElementAccessInAsyncMethod creates _superIndex(x) or _superIndex(x).value.
function superAccessState:createSuperElementAccessInAsyncMethod(argumentExpression)
    local superIndexCall = self.factory:NewCallExpression(
        self.superIndexBinding, nil, nil,
        self.factory:NewNodeList({ argumentExpression }),
        NodeFlags.None
    )
    if self.hasSuperPropertyAssignment then
        return self.factory:NewPropertyAccessExpression(
            superIndexCall, nil,
            self.factory:NewIdentifier("value"), NodeFlags.None
        )
    end
    return superIndexCall
end

-- createSuperAccessVariableStatement creates a variable named `_super` with accessor
-- properties for the given property names.
--
-- Create a variable declaration with a getter/setter (if binding) definition for each name:
--
--	const _super = Object.create(null, {
--	    x: { get: () => super.x },                           // read-only
--	    x: { get: () => super.x, set: (v) => super.x = v }, // read-write
--	});
function superAccessState:createSuperAccessVariableStatement()
    local f = self.factory
    local accessors = {}

    for name in self.capturedSuperProperties:Values() do
        local descriptorProperties = {}

        -- getter: get: () => super.name
        local getterBody = f:NewPropertyAccessExpression(
            f:NewKeywordExpression(Kind.SuperKeyword), nil,
            f:NewIdentifier(name), NodeFlags.None
        )
        local getterArrow = f:NewArrowFunction(
            nil, nil,
            f:NewNodeList({}),
            nil, nil,
            f:NewToken(Kind.EqualsGreaterThanToken),
            getterBody
        )
        local getter = f:NewPropertyAssignment(nil, f:NewIdentifier("get"), nil, nil, getterArrow)
        descriptorProperties[#descriptorProperties + 1] = getter

        if self.hasSuperPropertyAssignment then
            -- setter: set: v => super.name = v
            local vParam = f:NewParameterDeclaration(nil, nil, f:NewIdentifier("v"), nil, nil, nil)
            local superProp = f:NewPropertyAccessExpression(
                f:NewKeywordExpression(Kind.SuperKeyword), nil,
                f:NewIdentifier(name), NodeFlags.None
            )
            local assignExpr = f:NewAssignmentExpression(superProp, f:NewIdentifier("v"))
            local setterArrow = f:NewArrowFunction(
                nil, nil,
                f:NewNodeList({ vParam }),
                nil, nil,
                f:NewToken(Kind.EqualsGreaterThanToken),
                assignExpr
            )
            local setter = f:NewPropertyAssignment(nil, f:NewIdentifier("set"), nil, nil, setterArrow)
            descriptorProperties[#descriptorProperties + 1] = setter
        end

        local descriptor = f:NewObjectLiteralExpression(f:NewNodeList(descriptorProperties), false)
        local accessor = f:NewPropertyAssignment(nil, f:NewIdentifier(name), nil, nil, descriptor)
        accessors[#accessors + 1] = accessor
    end

    local descriptorsObject = f:NewObjectLiteralExpression(f:NewNodeList(accessors), true)

    local objectCreateCall = f:NewCallExpression(
        f:NewPropertyAccessExpression(
            f:NewIdentifier("Object"), nil,
            f:NewIdentifier("create"), NodeFlags.None
        ), nil, nil,
        f:NewNodeList({
            f:NewKeywordExpression(Kind.NullKeyword),
            descriptorsObject,
        }),
        NodeFlags.None
    )

    local decl = f:NewVariableDeclaration(self.superBinding, nil, nil, objectCreateCall)
    local declList = f:NewVariableDeclarationList(f:NewNodeList({ decl }), NodeFlags.Const)
    return f:NewVariableStatement(nil, declList)
end

-- trackSuperAccess records super property/element accesses and super property assignments
-- for the enclosing async method body. Called from both the main visitor and auxiliary
-- visitors to ensure super accesses are tracked regardless of whether the node has
-- transform flags.
function superAccessState:trackSuperAccess(node)
    if self.capturedSuperProperties == nil then
        return
    end
    local k = node.kind
    if k == Kind.PropertyAccessExpression then
        if node:Expression().kind == Kind.SuperKeyword then
            self.capturedSuperProperties:Add(node:Name():Text())
        end
    elseif k == Kind.ElementAccessExpression then
        if node:Expression().kind == Kind.SuperKeyword then
            self.hasSuperElementAccess = true
        end
    elseif k == Kind.BinaryExpression then
        if ast.IsAssignmentOperator(node:AsBinaryExpression().operatorToken.kind) and estransforms.assignmentTargetContainsSuperProperty(node:AsBinaryExpression().left) then
            self.hasSuperPropertyAssignment = true
        end
    elseif k == Kind.PrefixUnaryExpression then
        if estransforms.isUpdateExpression(node) and estransforms.assignmentTargetContainsSuperProperty(node:AsPrefixUnaryExpression().operand) then
            self.hasSuperPropertyAssignment = true
        end
    elseif k == Kind.PostfixUnaryExpression then
        if estransforms.isUpdateExpression(node) and estransforms.assignmentTargetContainsSuperProperty(node:AsPostfixUnaryExpression().operand) then
            self.hasSuperPropertyAssignment = true
        end
    end
end

-- createAccessorPropertyBackingField creates a private backing field for an `accessor` PropertyDeclaration.
function estransforms.createAccessorPropertyBackingField(f, node, modifiers, initializer)
    return f:UpdatePropertyDeclaration(
        node,
        modifiers,
        f:NewGeneratedPrivateNameForNodeEx(node:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" }),
        nil, -- postfixToken
        nil, -- typeNode
        initializer
    )
end
