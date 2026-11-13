-- Go closures shadow their enclosing parameters (func(t *Type) inside a function of t).
-- luacheck: ignore 431 432
local checker = require("tslua.checker")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local evaluator = require("tslua.evaluator")
local scanner = require("tslua.scanner")

local Checker = checker.Checker
local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local TypeFacts = checker.TypeFacts
local TypePredicateKind = checker.TypePredicateKind
local UnionReduction = checker.UnionReduction
local CheckMode = checker.CheckMode
local SignatureKind = checker.SignatureKind
local AssignmentKind = checker.AssignmentKind
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local FlowFlags = ast.FlowFlags
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags

-- Go slices.Contains(xs[start:], v) (start is 0-based)
local function containsValue(xs, v, start)
    if xs ~= nil then
        for i = (start or 0) + 1, #xs do
            if xs[i] == v then
                return true
            end
        end
    end
    return false
end

-- Go slices.Index (0-based, -1 if absent)
local function indexOfValue(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

-- Go slices.Equal
local function equalValues(a, b)
    if core.Len(a) ~= core.Len(b) then
        return false
    end
    for i = 1, core.Len(a) do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Truncates xs to its first n elements in place (Go xs = xs[:n]).
local function truncate(xs, n)
    for i = #xs, n + 1, -1 do
        xs[i] = nil
    end
end

-- FlowType is a Go value struct { t, incomplete }; values are treated as immutable.
local FlowTypeClass = defineStruct("FlowType", nil, { incomplete = false })

-- Go composite literal FlowType{t: t, incomplete: incomplete}.
local function FlowType(t, incomplete)
    return setmetatable({ t = t, incomplete = incomplete or false }, FlowTypeClass)
end

function FlowTypeClass:isNil()
    return self.t == nil
end

function Checker:newFlowType(t, incomplete)
    if incomplete and t.flags & TypeFlags.Never ~= 0 then
        t = self.silentNeverType
    end
    return FlowType(t, incomplete)
end

-- SharedFlow: { flow = FlowNode, flowType = FlowType }
defineStruct("SharedFlow", nil, nil)

defineStruct("FlowState", nil, {
    refKey = "",
    depth = 0,
    sharedFlowStart = 0,
})

function Checker:getFlowState()
    local f = self.freeFlowState
    if f == nil then
        f = checker.FlowState_new({ reduceLabels = {} })
    end
    self.freeFlowState = f.next
    return f
end

function Checker:putFlowState(f)
    f.reference = nil
    f.declaredType = nil
    f.initialType = nil
    f.flowContainer = nil
    f.refKey = ""
    f.depth = 0
    f.sharedFlowStart = 0
    f.reduceLabels = {}
    f.next = self.freeFlowState
    self.freeFlowState = f
end

function checker.getFlowNodeOfNode(node)
    local flowNodeData = node:FlowNodeData()
    if flowNodeData ~= nil then
        return flowNodeData.flowNode
    end
    return nil
end

function Checker:getFlowTypeOfReference(reference, declaredType)
    return self:getFlowTypeOfReferenceEx(reference, declaredType, declaredType, nil, nil)
end

function Checker:getFlowTypeOfReferenceEx(reference, declaredType, initialType, flowContainer, flowNode)
    if self.flowAnalysisDisabled then
        return self.errorType
    end
    if flowNode == nil then
        flowNode = checker.getFlowNodeOfNode(reference)
        if flowNode == nil then
            return declaredType
        end
    end
    local f = self:getFlowState()
    f.reference = reference
    f.declaredType = declaredType
    f.initialType = core.Coalesce(initialType, declaredType)
    f.flowContainer = flowContainer
    f.sharedFlowStart = #self.sharedFlows
    self.flowInvocationCount = self.flowInvocationCount + 1
    local evolvedType = self:getTypeAtFlowNode(f, flowNode).t
    truncate(self.sharedFlows, f.sharedFlowStart)
    self:putFlowState(f)
    -- When the reference is 'x' in an 'x.length', 'x.push(value)', 'x.unshift(value)' or x[n] = value' operation,
    -- we give type 'any[]' to 'x' instead of using the type determined by control flow analysis such that operations
    -- on empty arrays are possible without implicit any errors and new element types can be inferred without
    -- type mismatch errors.
    local resultType
    if evolvedType.objectFlags & ObjectFlags.EvolvingArray ~= 0 and self:isEvolvingArrayOperationTarget(reference) then
        resultType = self.autoArrayType
    else
        resultType = self:finalizeEvolvingArrayType(evolvedType)
    end
    if resultType == self.unreachableNeverType or reference.parent ~= nil and ast.IsNonNullExpression(reference.parent) and resultType.flags & TypeFlags.Never == 0 and self:getTypeWithFacts(resultType, TypeFacts.NEUndefinedOrNull).flags & TypeFlags.Never ~= 0 then
        return declaredType
    end
    return resultType
end

function Checker:getTypeAtFlowNode(f, flow)
    if f.depth == 2000 then
        -- We have made 2000 recursive invocations. To avoid overflowing the call stack we report an error
        -- and disable further control flow analysis in the containing function or module body.
        local tr = self.tracer
        if tr ~= nil then
            tr:Instant(tracing.PhaseCheckTypes, "getTypeAtFlowNode_DepthLimit", { depth = f.depth })
        end
        self.flowAnalysisDisabled = true
        self:reportFlowControlError(f.reference)
        return FlowType(self.errorType)
    end
    f.depth = f.depth + 1
    local sharedFlow
    while true do
        local flags = flow.flags
        if flags & FlowFlags.Shared ~= 0 then
            -- We cache results of flow type resolution for shared nodes that were previously visited in
            -- the same getFlowTypeOfReference invocation. A node is considered shared when it is the
            -- antecedent of more than one node.
            for i = f.sharedFlowStart, #self.sharedFlows - 1 do
                if self.sharedFlows[i + 1].flow == flow then
                    f.depth = f.depth - 1
                    return self.sharedFlows[i + 1].flowType
                end
            end
            sharedFlow = flow
        end
        local t
        if flags & FlowFlags.Assignment ~= 0 then
            t = self:getTypeAtFlowAssignment(f, flow)
            if t:isNil() then
                flow = flow.antecedent
                goto continue
            end
        elseif flags & FlowFlags.Call ~= 0 then
            t = self:getTypeAtFlowCall(f, flow)
            if t:isNil() then
                flow = flow.antecedent
                goto continue
            end
        elseif flags & FlowFlags.Condition ~= 0 then
            t = self:getTypeAtFlowCondition(f, flow)
        elseif flags & FlowFlags.SwitchClause ~= 0 then
            t = self:getTypeAtSwitchClause(f, flow)
        elseif flags & FlowFlags.BranchLabel ~= 0 then
            local antecedents = checker.getBranchLabelAntecedents(flow, f.reduceLabels)
            if antecedents.next == nil then
                flow = antecedents.flow
                goto continue
            end
            t = self:getTypeAtFlowBranchLabel(f, flow, antecedents)
        elseif flags & FlowFlags.LoopLabel ~= 0 then
            if flow.antecedents.next == nil then
                flow = flow.antecedents.flow
                goto continue
            end
            t = self:getTypeAtFlowLoopLabel(f, flow)
        elseif flags & FlowFlags.ArrayMutation ~= 0 then
            t = self:getTypeAtFlowArrayMutation(f, flow)
            if t:isNil() then
                flow = flow.antecedent
                goto continue
            end
        elseif flags & FlowFlags.ReduceLabel ~= 0 then
            f.reduceLabels[#f.reduceLabels + 1] = flow.node:AsFlowReduceLabelData()
            t = self:getTypeAtFlowNode(f, flow.antecedent)
            f.reduceLabels[#f.reduceLabels] = nil
        elseif flags & FlowFlags.Start ~= 0 then
            -- Check if we should continue with the control flow of the containing function.
            local container = flow.node
            if container ~= nil and container ~= f.flowContainer and not ast.IsPropertyAccessExpression(f.reference) and not ast.IsElementAccessExpression(f.reference) and not (f.reference.kind == Kind.ThisKeyword and not ast.IsArrowFunction(container)) then
                flow = container:FlowNodeData().flowNode
                goto continue
            end
            -- At the top of the flow we have the initial type.
            t = FlowType(f.initialType)
        else
            -- Unreachable code errors are reported in the binding phase. Here we
            -- simply return the non-auto declared type to reduce follow-on errors.
            t = FlowType(self:convertAutoToAny(f.declaredType))
        end
        if sharedFlow ~= nil then
            -- Record visited node and the associated type in the cache.
            self.sharedFlows[#self.sharedFlows + 1] = checker.SharedFlow_new({ flow = sharedFlow, flowType = t })
        end
        f.depth = f.depth - 1
        do
            return t
        end
        ::continue::
    end
end

function checker.getBranchLabelAntecedents(flow, reduceLabels)
    local i = #reduceLabels
    while i ~= 0 do
        i = i - 1
        local data = reduceLabels[i + 1]
        if data.target == flow then
            return data.antecedents
        end
    end
    return flow.antecedents
end

function Checker:getTypeAtFlowAssignment(f, flow)
    local node = flow.node
    -- Assignments only narrow the computed type if the declared type is a union type. Thus, we
    -- only need to evaluate the assigned type if the declared type is a union type.
    if self:isMatchingReference(f.reference, node) then
        if not self:isReachableFlowNode(flow) then
            return FlowType(self.unreachableNeverType)
        end
        if checker.getAssignmentTargetKind(node) == AssignmentKind.Compound then
            local flowType = self:getTypeAtFlowNode(f, flow.antecedent)
            return self:newFlowType(self:getBaseTypeOfLiteralType(flowType.t), flowType.incomplete)
        end
        if f.declaredType == self.autoType or f.declaredType == self.autoArrayType then
            if self:isEmptyArrayAssignment(node) then
                return FlowType(self:getEvolvingArrayType(self.neverType))
            end
            local assignedType = self:getWidenedLiteralType(self:getInitialOrAssignedType(f, flow))
            if self:isTypeAssignableTo(assignedType, f.declaredType) then
                return FlowType(assignedType)
            end
            return FlowType(self.anyArrayType)
        end
        local t = f.declaredType
        if checker.isInCompoundLikeAssignment(node) then
            t = self:getBaseTypeOfLiteralType(t)
        end
        if t.flags & TypeFlags.Union ~= 0 then
            return FlowType(self:getAssignmentReducedType(t, self:getInitialOrAssignedType(f, flow)))
        end
        return FlowType(t)
    end
    -- We didn't have a direct match. However, if the reference is a dotted name, this
    -- may be an assignment to a left hand part of the reference. For example, for a
    -- reference 'x.y.z', we may be at an assignment to 'x.y' or 'x'. In that case,
    -- return the declared type.
    if self:containsMatchingReference(f.reference, node) then
        if not self:isReachableFlowNode(flow) then
            return FlowType(self.unreachableNeverType)
        end
        -- A matching dotted name might also be an expando property on a function *expression*,
        -- in which case we continue control flow analysis back to the function's declaration
        if ast.IsVariableDeclaration(node) and (ast.IsInJSFile(node) or ast.IsVarConstLike(node)) then
            local init = node:Initializer()
            if init ~= nil and ast.IsFunctionExpressionOrArrowFunction(init) then
                return self:getTypeAtFlowNode(f, flow.antecedent)
            end
        end
        return FlowType(f.declaredType)
    end
    -- for (const _ in ref) acts as a nonnull on ref
    if ast.IsVariableDeclaration(node) and ast.IsForInStatement(node.parent.parent) and (self:isMatchingReference(f.reference, node.parent.parent:Expression()) or self:optionalChainContainsReference(node.parent.parent:Expression(), f.reference)) then
        return FlowType(self:getNonNullableTypeIfNeeded(self:finalizeEvolvingArrayType(self:getTypeAtFlowNode(f, flow.antecedent).t)))
    end
    -- Assignment doesn't affect reference
    return FlowType(nil)
end

function Checker:getInitialOrAssignedType(f, flow)
    if ast.IsVariableDeclaration(flow.node) or ast.IsBindingElement(flow.node) then
        return self:getNarrowableTypeForReference(self:getInitialType(flow.node), f.reference, CheckMode.Normal)
    end
    return self:getNarrowableTypeForReference(self:getAssignedType(flow.node), f.reference, CheckMode.Normal)
end

function Checker:isEmptyArrayAssignment(node)
    return ast.IsVariableDeclaration(node) and node:Initializer() ~= nil and checker.isEmptyArrayLiteral(node:Initializer()) or
        not ast.IsBindingElement(node) and ast.IsBinaryExpression(node.parent) and checker.isEmptyArrayLiteral(node.parent:AsBinaryExpression().right)
end

function Checker:getTypeAtFlowCall(f, flow)
    local signature = self:getEffectsSignature(flow.node)
    if signature ~= nil then
        local predicate = self:getTypePredicateOfSignature(signature)
        if predicate ~= nil and (predicate.kind == TypePredicateKind.AssertsThis or predicate.kind == TypePredicateKind.AssertsIdentifier) then
            local flowType = self:getTypeAtFlowNode(f, flow.antecedent)
            local t = self:finalizeEvolvingArrayType(flowType.t)
            local narrowedType
            if predicate.t ~= nil then
                narrowedType = self:narrowTypeByTypePredicate(f, t, predicate, flow.node, true --[[assumeTrue]])
            elseif predicate.kind == TypePredicateKind.AssertsIdentifier and predicate.parameterIndex >= 0 and predicate.parameterIndex < core.Len(flow.node:Arguments()) then
                narrowedType = self:narrowTypeByAssertion(f, t, flow.node:Arguments()[predicate.parameterIndex + 1])
            else
                narrowedType = t
            end
            if narrowedType == t then
                return flowType
            end
            return self:newFlowType(narrowedType, flowType.incomplete)
        end
        if self:getReturnTypeOfSignature(signature).flags & TypeFlags.Never ~= 0 then
            return FlowType(self.unreachableNeverType)
        end
    end
    return FlowType(nil)
end

function Checker:narrowTypeByTypePredicate(f, t, predicate, callExpression, assumeTrue)
    -- Don't narrow from 'any' if the predicate type is exactly 'Object' or 'Function'
    if predicate.t ~= nil and not (checker.IsTypeAny(t) and (predicate.t == self.globalObjectType or predicate.t == self.globalFunctionType)) then
        local predicateArgument = self:getTypePredicateArgument(predicate, callExpression)
        if predicateArgument ~= nil then
            if self:isMatchingReference(f.reference, predicateArgument) then
                return self:getNarrowedType(t, predicate.t, assumeTrue, false --[[checkDerived]])
            end
            if self.strictNullChecks and self:optionalChainContainsReference(predicateArgument, f.reference) and (assumeTrue and not self:hasTypeFacts(predicate.t, TypeFacts.EQUndefined) or not assumeTrue and checker.everyType(predicate.t, function(x)
                return self:IsNullableType(x)
            end)) then
                t = self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
            end
            local access = self:getDiscriminantPropertyAccess(f, predicateArgument, t)
            if access ~= nil then
                return self:narrowTypeByDiscriminant(t, access, function(t)
                    return self:getNarrowedType(t, predicate.t, assumeTrue, false --[[checkDerived]])
                end)
            end
        end
    end
    return t
end

function Checker:narrowTypeByAssertion(f, t, expr)
    local node = ast.SkipParentheses(expr)
    if node.kind == Kind.FalseKeyword then
        return self.unreachableNeverType
    end
    if node.kind == Kind.BinaryExpression then
        if node:AsBinaryExpression().operatorToken.kind == Kind.AmpersandAmpersandToken then
            return self:narrowTypeByAssertion(f, self:narrowTypeByAssertion(f, t, node:AsBinaryExpression().left), node:AsBinaryExpression().right)
        end
        if node:AsBinaryExpression().operatorToken.kind == Kind.BarBarToken then
            return self:getUnionType({ self:narrowTypeByAssertion(f, t, node:AsBinaryExpression().left), self:narrowTypeByAssertion(f, t, node:AsBinaryExpression().right) })
        end
    end
    return self:narrowType(f, t, node, true --[[assumeTrue]])
end

function Checker:getTypeAtFlowCondition(f, flow)
    local flowType = self:getTypeAtFlowNode(f, flow.antecedent)
    if flowType.t.flags & TypeFlags.Never ~= 0 then
        return flowType
    end
    -- If we have an antecedent type (meaning we're reachable in some way), we first
    -- attempt to narrow the antecedent type. If that produces the never type, and if
    -- the antecedent type is incomplete (i.e. a transient type in a loop), then we
    -- take the type guard as an indication that control *could* reach here once we
    -- have the complete type. We proceed by switching to the silent never type which
    -- doesn't report errors when operators are applied to it. Note that this is the
    -- *only* place a silent never type is ever generated.
    local assumeTrue = flow.flags & FlowFlags.TrueCondition ~= 0
    local nonEvolvingType = self:finalizeEvolvingArrayType(flowType.t)
    local narrowedType = self:narrowType(f, nonEvolvingType, flow.node, assumeTrue)
    if narrowedType == nonEvolvingType then
        return flowType
    end
    return self:newFlowType(narrowedType, flowType.incomplete)
end

-- Narrow the given type based on the given expression having the assumed boolean value. The returned type
-- will be a subtype or the same type as the argument.
function Checker:narrowType(f, t, expr, assumeTrue)
    -- for `a?.b`, we emulate a synthetic `a !== null && a !== undefined` condition for `a`
    if ast.IsExpressionOfOptionalChainRoot(expr) or ast.IsBinaryExpression(expr.parent) and (expr.parent:AsBinaryExpression().operatorToken.kind == Kind.QuestionQuestionToken or expr.parent:AsBinaryExpression().operatorToken.kind == Kind.QuestionQuestionEqualsToken) and expr.parent:AsBinaryExpression().left == expr then
        return self:narrowTypeByOptionality(f, t, expr, assumeTrue)
    end
    local kind = expr.kind
    if kind == Kind.Identifier then
        -- When narrowing a reference to a const variable, non-assigned parameter, or readonly property, we inline
        -- up to five levels of aliased conditional expressions that are themselves declared as const variables.
        if not self:isMatchingReference(f.reference, expr) and self.inlineLevel < 5 then
            local symbol = self:getResolvedSymbol(expr)
            if self:isConstantVariable(symbol) then
                local declaration = symbol.valueDeclaration
                if declaration ~= nil and ast.IsVariableDeclaration(declaration) and declaration:Type() == nil and declaration:Initializer() ~= nil and self:isConstantReference(f.reference) then
                    self.inlineLevel = self.inlineLevel + 1
                    local result = self:narrowType(f, t, declaration:Initializer(), assumeTrue)
                    self.inlineLevel = self.inlineLevel - 1
                    return result
                end
            end
        end
        -- fallthrough
        return self:narrowTypeByTruthiness(f, t, expr, assumeTrue)
    elseif kind == Kind.ThisKeyword or kind == Kind.SuperKeyword or kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        return self:narrowTypeByTruthiness(f, t, expr, assumeTrue)
    elseif kind == Kind.CallExpression then
        return self:narrowTypeByCallExpression(f, t, expr, assumeTrue)
    elseif kind == Kind.ParenthesizedExpression or kind == Kind.NonNullExpression or kind == Kind.SatisfiesExpression then
        return self:narrowType(f, t, expr:Expression(), assumeTrue)
    elseif kind == Kind.BinaryExpression then
        return self:narrowTypeByBinaryExpression(f, t, expr:AsBinaryExpression(), assumeTrue)
    elseif kind == Kind.PrefixUnaryExpression then
        if expr:AsPrefixUnaryExpression().operator == Kind.ExclamationToken then
            return self:narrowType(f, t, expr:AsPrefixUnaryExpression().operand, not assumeTrue)
        end
    end
    return t
end

function Checker:narrowTypeByOptionality(f, t, expr, assumePresent)
    if self:isMatchingReference(f.reference, expr) then
        return self:getAdjustedTypeWithFacts(t, core.IfElse(assumePresent, TypeFacts.NEUndefinedOrNull, TypeFacts.EQUndefinedOrNull))
    end
    local access = self:getDiscriminantPropertyAccess(f, expr, t)
    if access ~= nil then
        return self:narrowTypeByDiscriminant(t, access, function(t)
            return self:getTypeWithFacts(t, core.IfElse(assumePresent, TypeFacts.NEUndefinedOrNull, TypeFacts.EQUndefinedOrNull))
        end)
    end
    return t
end

function Checker:narrowTypeByTruthiness(f, t, expr, assumeTrue)
    if self:isMatchingReference(f.reference, expr) then
        return self:getAdjustedTypeWithFacts(t, core.IfElse(assumeTrue, TypeFacts.Truthy, TypeFacts.Falsy))
    end
    if self.strictNullChecks and assumeTrue and self:optionalChainContainsReference(expr, f.reference) then
        t = self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
    end
    local access = self:getDiscriminantPropertyAccess(f, expr, t)
    if access ~= nil then
        return self:narrowTypeByDiscriminant(t, access, function(t)
            return self:getTypeWithFacts(t, core.IfElse(assumeTrue, TypeFacts.Truthy, TypeFacts.Falsy))
        end)
    end
    return t
end

function Checker:narrowTypeByCallExpression(f, t, callExpression, assumeTrue)
    if self:hasMatchingArgument(callExpression, f.reference) then
        local predicate
        if assumeTrue or not checker.isCallChain(callExpression) then
            local signature = self:getEffectsSignature(callExpression)
            if signature ~= nil then
                predicate = self:getTypePredicateOfSignature(signature)
            end
        end
        if predicate ~= nil and (predicate.kind == TypePredicateKind.This or predicate.kind == TypePredicateKind.Identifier) then
            return self:narrowTypeByTypePredicate(f, t, predicate, callExpression, assumeTrue)
        end
    end
    if self.containsMissingType(t) and ast.IsAccessExpression(f.reference) and ast.IsPropertyAccessExpression(callExpression:Expression()) then
        local callAccess = callExpression:Expression()
        if self:isMatchingReference(f.reference:Expression(), self:getReferenceCandidate(callAccess:Expression())) and ast.IsIdentifier(callAccess:Name()) and callAccess:Name():Text() == "hasOwnProperty" and core.Len(callExpression:Arguments()) == 1 then
            local argument = callExpression:Arguments()[1]
            local accessedName, ok = self:getAccessedPropertyName(f.reference)
            if ok and ast.IsStringLiteralLike(argument) and accessedName == argument:Text() then
                return self:getTypeWithFacts(t, core.IfElse(assumeTrue, TypeFacts.NEUndefined, TypeFacts.EQUndefined))
            end
        end
    end
    return t
end

function Checker:narrowTypeByBinaryExpression(f, t, expr, assumeTrue)
    local opKind = expr.operatorToken.kind
    if opKind == Kind.EqualsToken or opKind == Kind.BarBarEqualsToken or opKind == Kind.AmpersandAmpersandEqualsToken or opKind == Kind.QuestionQuestionEqualsToken then
        return self:narrowTypeByTruthiness(f, self:narrowType(f, t, expr.right, assumeTrue), expr.left, assumeTrue)
    elseif opKind == Kind.EqualsEqualsToken or opKind == Kind.ExclamationEqualsToken or opKind == Kind.EqualsEqualsEqualsToken or opKind == Kind.ExclamationEqualsEqualsToken then
        local operator = expr.operatorToken.kind
        local left = self:getReferenceCandidate(expr.left)
        local right = self:getReferenceCandidate(expr.right)
        if left.kind == Kind.TypeOfExpression and ast.IsStringLiteralLike(right) then
            return self:narrowTypeByTypeof(f, t, left:AsTypeOfExpression(), operator, right, assumeTrue)
        end
        if right.kind == Kind.TypeOfExpression and ast.IsStringLiteralLike(left) then
            return self:narrowTypeByTypeof(f, t, right:AsTypeOfExpression(), operator, left, assumeTrue)
        end
        if self:isMatchingReference(f.reference, left) then
            return self:narrowTypeByEquality(t, operator, right, assumeTrue)
        end
        if self:isMatchingReference(f.reference, right) then
            return self:narrowTypeByEquality(t, operator, left, assumeTrue)
        end
        if self.strictNullChecks then
            if self:optionalChainContainsReference(left, f.reference) then
                t = self:narrowTypeByOptionalChainContainment(f, t, operator, right, assumeTrue)
            elseif self:optionalChainContainsReference(right, f.reference) then
                t = self:narrowTypeByOptionalChainContainment(f, t, operator, left, assumeTrue)
            end
        end
        local leftAccess = self:getDiscriminantPropertyAccess(f, left, t)
        if leftAccess ~= nil then
            return self:narrowTypeByDiscriminantProperty(t, leftAccess, operator, right, assumeTrue)
        end
        local rightAccess = self:getDiscriminantPropertyAccess(f, right, t)
        if rightAccess ~= nil then
            return self:narrowTypeByDiscriminantProperty(t, rightAccess, operator, left, assumeTrue)
        end
        if self:isMatchingConstructorReference(f, left) then
            return self:narrowTypeByConstructor(t, operator, right, assumeTrue)
        end
        if self:isMatchingConstructorReference(f, right) then
            return self:narrowTypeByConstructor(t, operator, left, assumeTrue)
        end
        if ast.IsBooleanLiteral(right) and not ast.IsAccessExpression(left) then
            return self:narrowTypeByBooleanComparison(f, t, left, right, operator, assumeTrue)
        end
        if ast.IsBooleanLiteral(left) and not ast.IsAccessExpression(right) then
            return self:narrowTypeByBooleanComparison(f, t, right, left, operator, assumeTrue)
        end
    elseif opKind == Kind.InstanceOfKeyword then
        return self:narrowTypeByInstanceof(f, t, expr, assumeTrue)
    elseif opKind == Kind.InKeyword then
        if ast.IsPrivateIdentifier(expr.left) then
            return self:narrowTypeByPrivateIdentifierInInExpression(f, t, expr, assumeTrue)
        end
        local target = self:getReferenceCandidate(expr.right)
        if self.containsMissingType(t) and ast.IsAccessExpression(f.reference) and self:isMatchingReference(f.reference:Expression(), target) then
            local leftType = self:getTypeOfExpression(expr.left)
            if checker.isTypeUsableAsPropertyName(leftType) then
                local accessedName, ok = self:getAccessedPropertyName(f.reference)
                if ok and accessedName == checker.getPropertyNameFromType(leftType) then
                    return self:getTypeWithFacts(t, core.IfElse(assumeTrue, TypeFacts.NEUndefined, TypeFacts.EQUndefined))
                end
            end
        end
        if self:isMatchingReference(f.reference, target) then
            local leftType = self:getTypeOfExpression(expr.left)
            if checker.isTypeUsableAsPropertyName(leftType) then
                return self:narrowTypeByInKeyword(f, t, leftType, assumeTrue)
            end
        end
    elseif opKind == Kind.CommaToken then
        return self:narrowType(f, t, expr.right, assumeTrue)
    elseif opKind == Kind.AmpersandAmpersandToken then
        -- Ordinarily we won't see && and || expressions in control flow analysis because the Binder breaks those
        -- expressions down to individual conditional control flows. However, we may encounter them when analyzing
        -- aliased conditional expressions.
        if assumeTrue then
            return self:narrowType(f, self:narrowType(f, t, expr.left, true --[[assumeTrue]]), expr.right, true --[[assumeTrue]])
        end
        return self:getUnionType({ self:narrowType(f, t, expr.left, false --[[assumeTrue]]), self:narrowType(f, t, expr.right, false --[[assumeTrue]]) })
    elseif opKind == Kind.BarBarToken then
        if assumeTrue then
            return self:getUnionType({ self:narrowType(f, t, expr.left, true --[[assumeTrue]]), self:narrowType(f, t, expr.right, true --[[assumeTrue]]) })
        end
        return self:narrowType(f, self:narrowType(f, t, expr.left, false --[[assumeTrue]]), expr.right, false --[[assumeTrue]])
    end
    return t
end

function Checker:narrowTypeByEquality(t, operator, value, assumeTrue)
    if t.flags & TypeFlags.Any ~= 0 then
        return t
    end
    if operator == Kind.ExclamationEqualsToken or operator == Kind.ExclamationEqualsEqualsToken then
        assumeTrue = not assumeTrue
    end
    local valueType = self:getTypeOfExpression(value)
    local doubleEquals = operator == Kind.EqualsEqualsToken or operator == Kind.ExclamationEqualsToken
    if valueType.flags & TypeFlags.Nullable ~= 0 then
        if not self.strictNullChecks then
            return t
        end
        local facts
        if doubleEquals then
            facts = core.IfElse(assumeTrue, TypeFacts.EQUndefinedOrNull, TypeFacts.NEUndefinedOrNull)
        elseif valueType.flags & TypeFlags.Null ~= 0 then
            facts = core.IfElse(assumeTrue, TypeFacts.EQNull, TypeFacts.NENull)
        else
            facts = core.IfElse(assumeTrue, TypeFacts.EQUndefined, TypeFacts.NEUndefined)
        end
        return self:getAdjustedTypeWithFacts(t, facts)
    end
    if assumeTrue then
        if not doubleEquals and (t.flags & TypeFlags.Unknown ~= 0 or checker.someType(t, function(x)
            return self:IsEmptyAnonymousObjectType(x)
        end)) then
            if valueType.flags & (TypeFlags.Primitive | TypeFlags.NonPrimitive) ~= 0 or self:IsEmptyAnonymousObjectType(valueType) then
                return valueType
            end
            if valueType.flags & TypeFlags.Object ~= 0 then
                return self.nonPrimitiveType
            end
        end
        if not doubleEquals and valueType.flags & TypeFlags.Primitive ~= 0 and self:isUniformUnionType(t) then
            local regularType = self:getRegularTypeOfLiteralType(valueType)
            if self:unionContainsType(t, regularType, false --[[matchSymbol]]) then
                return regularType
            end
        end
        local filteredType = self:filterType(t, function(t)
            return self:areTypesComparable(t, valueType) or doubleEquals and checker.isCoercibleUnderDoubleEquals(t, valueType)
        end)
        return self:replacePrimitivesWithLiterals(filteredType, valueType)
    end
    if checker.isUnitType(valueType) then
        if self:isUniformUnionType(t) then
            local filteredType = self:removeType(t, self:getRegularTypeOfLiteralType(valueType))
            if filteredType ~= t then
                return filteredType
            end
        end
        return self:filterType(t, function(t)
            return not (self:isUnitLikeType(t) and self:areTypesComparable(t, valueType))
        end)
    end
    return t
end

function Checker:narrowTypeByTypeof(f, t, typeOfExpr, operator, literal, assumeTrue)
    -- We have '==', '!=', '===', or !==' operator with 'typeof xxx' and string literal operands
    if operator == Kind.ExclamationEqualsToken or operator == Kind.ExclamationEqualsEqualsToken then
        assumeTrue = not assumeTrue
    end
    local target = self:getReferenceCandidate(typeOfExpr.expression)
    if not self:isMatchingReference(f.reference, target) then
        if self.strictNullChecks and self:optionalChainContainsReference(target, f.reference) and assumeTrue == (literal:Text() ~= "undefined") then
            t = self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
        end
        local propertyAccess = self:getDiscriminantPropertyAccess(f, target, t)
        if propertyAccess ~= nil then
            return self:narrowTypeByDiscriminant(t, propertyAccess, function(t)
                return self:narrowTypeByLiteralExpression(t, literal, assumeTrue)
            end)
        end
        return t
    end
    return self:narrowTypeByLiteralExpression(t, literal, assumeTrue)
end

checker.typeofNEFacts = {
    ["string"] = TypeFacts.TypeofNEString,
    ["number"] = TypeFacts.TypeofNENumber,
    ["bigint"] = TypeFacts.TypeofNEBigInt,
    ["boolean"] = TypeFacts.TypeofNEBoolean,
    ["symbol"] = TypeFacts.TypeofNESymbol,
    ["undefined"] = TypeFacts.NEUndefined,
    ["object"] = TypeFacts.TypeofNEObject,
    ["function"] = TypeFacts.TypeofNEFunction,
}

function Checker:narrowTypeByLiteralExpression(t, literal, assumeTrue)
    if assumeTrue then
        return self:narrowTypeByTypeName(t, literal:Text())
    end
    local facts = checker.typeofNEFacts[literal:Text()]
    if facts == nil then
        facts = TypeFacts.TypeofNEHostObject
    end
    return self:getAdjustedTypeWithFacts(t, facts)
end

function Checker:narrowTypeByTypeName(t, typeName)
    if typeName == "string" then
        return self:narrowTypeByTypeFacts(t, self.stringType, TypeFacts.TypeofEQString)
    elseif typeName == "number" then
        return self:narrowTypeByTypeFacts(t, self.numberType, TypeFacts.TypeofEQNumber)
    elseif typeName == "bigint" then
        return self:narrowTypeByTypeFacts(t, self.bigintType, TypeFacts.TypeofEQBigInt)
    elseif typeName == "boolean" then
        return self:narrowTypeByTypeFacts(t, self.booleanType, TypeFacts.TypeofEQBoolean)
    elseif typeName == "symbol" then
        return self:narrowTypeByTypeFacts(t, self.esSymbolType, TypeFacts.TypeofEQSymbol)
    elseif typeName == "object" then
        if t.flags & TypeFlags.Any ~= 0 then
            return t
        end
        return self:getUnionType({ self:narrowTypeByTypeFacts(t, self.nonPrimitiveType, TypeFacts.TypeofEQObject), self:narrowTypeByTypeFacts(t, self.nullType, TypeFacts.EQNull) })
    elseif typeName == "function" then
        if t.flags & TypeFlags.Any ~= 0 then
            return t
        end
        return self:narrowTypeByTypeFacts(t, self.globalFunctionType, TypeFacts.TypeofEQFunction)
    elseif typeName == "undefined" then
        return self:narrowTypeByTypeFacts(t, self.undefinedType, TypeFacts.EQUndefined)
    end
    return self:narrowTypeByTypeFacts(t, self.nonPrimitiveType, TypeFacts.TypeofEQHostObject)
end

function Checker:narrowTypeByTypeFacts(t, impliedType, facts)
    return self:mapType(t, function(t)
        if self:isTypeRelatedTo(t, impliedType, self.strictSubtypeRelation) then
            if self:hasTypeFacts(t, facts) then
                return t
            end
            return self.neverType
        elseif self:isTypeSubtypeOf(impliedType, t) then
            return impliedType
        elseif self:hasTypeFacts(t, facts) then
            return self:getIntersectionType({ t, impliedType })
        end
        return self.neverType
    end)
end

function Checker:narrowTypeByDiscriminantProperty(t, access, operator, value, assumeTrue)
    if (operator == Kind.EqualsEqualsEqualsToken or operator == Kind.ExclamationEqualsEqualsToken) and t.flags & TypeFlags.Union ~= 0 then
        local keyPropertyName = self:getKeyPropertyName(t)
        if keyPropertyName ~= "" then
            local accessedName, ok = self:getAccessedPropertyName(access)
            if ok and keyPropertyName == accessedName then
                local candidate = self:getConstituentTypeForKeyType(t, self:getTypeOfExpression(value))
                if candidate ~= nil then
                    if assumeTrue and operator == Kind.EqualsEqualsEqualsToken or not assumeTrue and operator == Kind.ExclamationEqualsEqualsToken then
                        return candidate
                    end
                    local propType = self:getTypeOfPropertyOfType(candidate, keyPropertyName)
                    if propType ~= nil and checker.isUnitType(propType) then
                        return self:removeType(t, candidate)
                    end
                    return t
                end
            end
        end
    end
    return self:narrowTypeByDiscriminant(t, access, function(t)
        return self:narrowTypeByEquality(t, operator, value, assumeTrue)
    end)
end

function Checker:narrowTypeByDiscriminant(t, access, narrowType)
    local propName, ok = self:getAccessedPropertyName(access)
    if not ok then
        return t
    end
    local optionalChain = ast.IsOptionalChain(access)
    local removeNullable = self.strictNullChecks and (optionalChain or checker.isNonNullAccess(access)) and self:maybeTypeOfKind(t, TypeFlags.Nullable)
    local nonNullType = t
    if removeNullable then
        nonNullType = self:getTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
    end
    local propType = self:getTypeOfPropertyOfType(nonNullType, propName)
    if propType == nil then
        return t
    end
    if removeNullable and optionalChain then
        propType = self:getOptionalType(propType, false)
    end
    local narrowedPropType = narrowType(propType)
    return self:filterType(t, function(t)
        local discriminantType = core.OrElse(self:getTypeOfPropertyOrIndexSignatureOfType(t, propName), self.unknownType)
        return discriminantType.flags & TypeFlags.Never == 0 and narrowedPropType.flags & TypeFlags.Never == 0 and self:areTypesComparable(narrowedPropType, discriminantType)
    end)
end

function Checker:isMatchingConstructorReference(f, expr)
    local name
    if ast.IsPropertyAccessExpression(expr) then
        name = expr:AsPropertyAccessExpression():Name()
    elseif ast.IsElementAccessExpression(expr) and ast.IsStringLiteralLike(expr:AsElementAccessExpression().argumentExpression) then
        name = expr:AsElementAccessExpression().argumentExpression
    end
    return name ~= nil and name:Text() == "constructor" and self:isMatchingReference(f.reference, expr:Expression())
end

function Checker:narrowTypeByConstructor(t, operator, identifier, assumeTrue)
    -- Do not narrow when checking inequality.
    if assumeTrue and operator ~= Kind.EqualsEqualsToken and operator ~= Kind.EqualsEqualsEqualsToken or not assumeTrue and operator ~= Kind.ExclamationEqualsToken and operator ~= Kind.ExclamationEqualsEqualsToken then
        return t
    end
    -- Get the type of the constructor identifier expression, if it is not a function then do not narrow.
    local identifierType = self:getTypeOfExpression(identifier)
    if not self:isFunctionType(identifierType) and not self:isConstructorType(identifierType) then
        return t
    end
    -- Get the prototype property of the type identifier so we can find out its type.
    local prototypeProperty = self:getPropertyOfType(identifierType, "prototype")
    if prototypeProperty == nil then
        return t
    end
    -- Get the type of the prototype, if it is undefined, or the global `Object` or `Function` types then do not narrow.
    local prototypeType = self:getTypeOfSymbol(prototypeProperty)
    local candidate
    if not checker.IsTypeAny(prototypeType) then
        candidate = prototypeType
    end
    if candidate == nil or candidate == self.globalObjectType or candidate == self.globalFunctionType then
        return t
    end
    -- If the type that is being narrowed is `any` then just return the `candidate` type since every type is a subtype of `any`.
    if checker.IsTypeAny(t) then
        return candidate
    end
    -- Filter out types that are not considered to be "constructed by" the `candidate` type.
    return self:filterType(t, function(t)
        return self:isConstructedBy(t, candidate)
    end)
end

function Checker:isConstructedBy(source, target)
    -- If either the source or target type are a class type then we need to check that they are the same exact type.
    -- This is because you may have a class `A` that defines some set of properties, and another class `B`
    -- that defines the same set of properties as class `A`, in that case they are structurally the same
    -- type, but when you do something like `instanceOfA.constructor === B` it will return false.
    if source.flags & TypeFlags.Object ~= 0 and source.objectFlags & ObjectFlags.Class ~= 0 or target.flags & TypeFlags.Object ~= 0 and target.objectFlags & ObjectFlags.Class ~= 0 then
        return source.symbol == target.symbol
    end
    -- For all other types just check that the `source` type is a subtype of the `target` type.
    return self:isTypeSubtypeOf(source, target)
end

function Checker:narrowTypeByBooleanComparison(f, t, expr, boolValue, operator, assumeTrue)
    assumeTrue = (assumeTrue ~= (boolValue.kind == Kind.TrueKeyword)) ~= (operator ~= Kind.ExclamationEqualsEqualsToken and operator ~= Kind.ExclamationEqualsToken)
    return self:narrowType(f, t, expr, assumeTrue)
end

function Checker:narrowTypeByInstanceof(f, t, expr, assumeTrue)
    local left = self:getReferenceCandidate(expr.left)
    if not self:isMatchingReference(f.reference, left) then
        if assumeTrue and self.strictNullChecks and self:optionalChainContainsReference(left, f.reference) then
            return self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
        end
        return t
    end
    local right = expr.right
    local rightType = self:getTypeOfExpression(right)
    if not self:isTypeDerivedFrom(rightType, self.globalObjectType) then
        return t
    end
    -- if the right-hand side has an object type with a custom `[Symbol.hasInstance]` method, and that method
    -- has a type predicate, use the type predicate to perform narrowing. This allows normal `object` types to
    -- participate in `instanceof`, as per Step 2 of https://tc39.es/ecma262/#sec-instanceofoperator.
    local predicate
    local signature = self:getEffectsSignature(expr:AsNode())
    if signature ~= nil then
        predicate = self:getTypePredicateOfSignature(signature)
    end
    if predicate ~= nil and predicate.kind == TypePredicateKind.Identifier and predicate.parameterIndex == 0 then
        return self:getNarrowedType(t, predicate.t, assumeTrue, true --[[checkDerived]])
    end
    if not self:isTypeDerivedFrom(rightType, self.globalFunctionType) then
        return t
    end
    local instanceType = self:mapType(rightType, function(x)
        return self:getInstanceType(x)
    end)
    -- Don't narrow from `any` if the target type is exactly `Object` or `Function`, and narrow
    -- in the false branch only if the target is a non-empty object type.
    if checker.IsTypeAny(t) and (instanceType == self.globalObjectType or instanceType == self.globalFunctionType) or not assumeTrue and not (instanceType.flags & TypeFlags.Object ~= 0 and not self:IsEmptyAnonymousObjectType(instanceType)) then
        return t
    end
    return self:getNarrowedType(t, instanceType, assumeTrue, true --[[checkDerived]])
end

function Checker:getNarrowedType(t, candidate, assumeTrue, checkDerived)
    if t.flags & TypeFlags.Union == 0 then
        return self:getNarrowedTypeWorker(t, candidate, assumeTrue, checkDerived)
    end
    local key = checker.NarrowedTypeKey(t, candidate, assumeTrue, checkDerived)
    local narrowedType = self.narrowedTypes[key]
    if narrowedType ~= nil then
        return narrowedType
    end
    narrowedType = self:getNarrowedTypeWorker(t, candidate, assumeTrue, checkDerived)
    self.narrowedTypes[key] = narrowedType
    return narrowedType
end

function Checker:getNarrowedTypeWorker(t, candidate, assumeTrue, checkDerived)
    if not assumeTrue then
        if t == candidate then
            return self.neverType
        end
        if checkDerived then
            return self:filterType(t, function(t)
                return not self:isTypeDerivedFrom(t, candidate)
            end)
        end
        if t.flags & TypeFlags.Unknown ~= 0 then
            t = self.unknownUnionType
        end
        local trueType = self:getNarrowedType(t, candidate, true --[[assumeTrue]], false --[[checkDerived]])
        return self:recombineUnknownType(self:filterType(t, function(t)
            return not self:isTypeSubsetOf(t, trueType)
        end))
    end
    if t.flags & TypeFlags.AnyOrUnknown ~= 0 then
        return candidate
    end
    if t == candidate then
        return candidate
    end
    -- We first attempt to filter the current type, narrowing constituents as appropriate and removing
    -- constituents that are unrelated to the candidate.
    local keyPropertyName = ""
    if t.flags & TypeFlags.Union ~= 0 then
        keyPropertyName = self:getKeyPropertyName(t)
    end
    local narrowedType = self:mapType(candidate, function(n)
        -- If a discriminant property is available, use that to reduce the type.
        local matching = t
        if keyPropertyName ~= "" then
            local discriminant = self:getTypeOfPropertyOfType(n, keyPropertyName)
            if discriminant ~= nil then
                local constituent = self:getConstituentTypeForKeyType(t, discriminant)
                if constituent ~= nil then
                    matching = constituent
                end
            end
        end
        -- For each constituent t in the current type, if t and c are directly related, pick the most
        -- specific of the two. When t and c are related in both directions, we prefer c for type predicates
        -- because that is the asserted type, but t for `instanceof` because generics aren't reflected in
        -- prototype object types.
        local mapType
        if checkDerived then
            mapType = function(t)
                if self:isTypeDerivedFrom(t, n) then
                    return t
                elseif self:isTypeDerivedFrom(n, t) then
                    return n
                end
                return self.neverType
            end
        else
            mapType = function(t)
                if self:isTypeStrictSubtypeOf(t, n) then
                    return t
                elseif self:isTypeStrictSubtypeOf(n, t) then
                    return n
                elseif self:isTypeSubtypeOf(t, n) then
                    return t
                elseif self:isTypeSubtypeOf(n, t) then
                    return n
                end
                return self.neverType
            end
        end
        local directlyRelated = self:mapType(matching, mapType)
        if directlyRelated.flags & TypeFlags.Never == 0 then
            return directlyRelated
        end
        -- If no constituents are directly related, create intersections for any generic constituents that
        -- are related by constraint.
        local isRelated
        if checkDerived then
            isRelated = function(s, x)
                return self:isTypeDerivedFrom(s, x)
            end
        else
            isRelated = function(s, x)
                return self:isTypeSubtypeOf(s, x)
            end
        end
        return self:mapType(t, function(t)
            if self:maybeTypeOfKind(t, TypeFlags.Instantiable) then
                local constraint = self:getBaseConstraintOfType(t)
                if constraint == nil or isRelated(n, constraint) then
                    return self:getIntersectionType({ t, n })
                end
            end
            return self.neverType
        end)
    end)
    -- If filtering produced a non-empty type, return that. Otherwise, pick the most specific of the two
    -- based on assignability, or as a last resort produce an intersection.
    if narrowedType.flags & TypeFlags.Never == 0 then
        return narrowedType
    elseif self:isTypeSubtypeOf(candidate, t) then
        return candidate
    elseif self:isTypeAssignableTo(t, candidate) then
        return t
    elseif self:isTypeAssignableTo(candidate, t) then
        return candidate
    end
    return self:getIntersectionType({ t, candidate })
end

function Checker:getInstanceType(constructorType)
    local prototypePropertyType = self:getTypeOfPropertyOfType(constructorType, "prototype")
    if prototypePropertyType ~= nil and not checker.IsTypeAny(prototypePropertyType) then
        return prototypePropertyType
    end
    local constructSignatures = self:getSignaturesOfType(constructorType, SignatureKind.Construct)
    if core.Len(constructSignatures) ~= 0 then
        return self:getUnionType(core.Map(constructSignatures, function(signature)
            return self:getReturnTypeOfSignature(self:getErasedSignature(signature))
        end))
    end
    -- We use the empty object type to indicate we don't know the type of objects created by
    -- this constructor function.
    return self.emptyObjectType
end

function Checker:narrowTypeByPrivateIdentifierInInExpression(f, t, expr, assumeTrue)
    local target = self:getReferenceCandidate(expr.right)
    if not self:isMatchingReference(f.reference, target) then
        return t
    end
    local symbol = self:getSymbolForPrivateIdentifierExpression(expr.left)
    if symbol == nil then
        return t
    end
    local classSymbol = symbol.parent
    local targetType
    if ast.HasStaticModifier(symbol.valueDeclaration) then
        targetType = self:getTypeOfSymbol(classSymbol)
    else
        targetType = self:getDeclaredTypeOfSymbol(classSymbol)
    end
    return self:getNarrowedType(t, targetType, assumeTrue, true --[[checkDerived]])
end

function Checker:narrowTypeByInKeyword(f, t, nameType, assumeTrue)
    local name = checker.getPropertyNameFromType(nameType)
    local isKnownProperty = checker.someType(t, function(t)
        return self:isTypePresencePossible(t, name, true --[[assumeTrue]])
    end)
    if isKnownProperty then
        -- If the check is for a known property (i.e. a property declared in some constituent of
        -- the target type), we filter the target type by presence of absence of the property.
        return self:filterType(t, function(t)
            return self:isTypePresencePossible(t, name, assumeTrue)
        end)
    end
    if assumeTrue then
        -- If the check is for an unknown property, we intersect the target type with `Record<X, unknown>`,
        -- where X is the name of the property.
        local recordSymbol = self.getGlobalRecordSymbol()
        if recordSymbol ~= nil then
            return self:getIntersectionType({ t, self:getTypeAliasInstantiation(recordSymbol, { nameType, self.unknownType }, nil) })
        end
    end
    return t
end

function Checker:isTypePresencePossible(t, propName, assumeTrue)
    local prop = self:getPropertyOfType(t, propName)
    if prop ~= nil then
        return prop.flags & SymbolFlags.Optional ~= 0 or prop.checkFlags & CheckFlags.Partial ~= 0 or assumeTrue
    end
    return self:getApplicableIndexInfoForName(t, propName) ~= nil or not assumeTrue
end

function Checker:narrowTypeByOptionalChainContainment(f, t, operator, value, assumeTrue)
    -- We are in a branch of obj?.foo === value (or any one of the other equality operators). We narrow obj as follows:
    -- When operator is === and type of value excludes undefined, null and undefined is removed from type of obj in true branch.
    -- When operator is !== and type of value excludes undefined, null and undefined is removed from type of obj in false branch.
    -- When operator is == and type of value excludes null and undefined, null and undefined is removed from type of obj in true branch.
    -- When operator is != and type of value excludes null and undefined, null and undefined is removed from type of obj in false branch.
    -- When operator is === and type of value is undefined, null and undefined is removed from type of obj in false branch.
    -- When operator is !== and type of value is undefined, null and undefined is removed from type of obj in true branch.
    -- When operator is == and type of value is null or undefined, null and undefined is removed from type of obj in false branch.
    -- When operator is != and type of value is null or undefined, null and undefined is removed from type of obj in true branch.
    local equalsOperator = operator == Kind.EqualsEqualsToken or operator == Kind.EqualsEqualsEqualsToken
    local nullableFlags
    if operator == Kind.EqualsEqualsToken or operator == Kind.ExclamationEqualsToken then
        nullableFlags = TypeFlags.Nullable
    else
        nullableFlags = TypeFlags.Undefined
    end
    local valueType = self:getTypeOfExpression(value)
    -- Note that we include any and unknown in the exclusion test because their domain includes null and undefined.
    local removeNullable = equalsOperator ~= assumeTrue and checker.everyType(valueType, function(t)
        return t.flags & nullableFlags ~= 0
    end) or equalsOperator == assumeTrue and checker.everyType(valueType, function(t)
        return t.flags & (TypeFlags.AnyOrUnknown | nullableFlags) == 0
    end)
    if removeNullable then
        return self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
    end
    return t
end

function Checker:getTypeAtSwitchClause(f, flow)
    local data = flow.node:AsFlowSwitchClauseData()
    local expr = ast.SkipParentheses(data.switchStatement:Expression())
    local flowType = self:getTypeAtFlowNode(f, flow.antecedent)
    local t = flowType.t
    if self:isMatchingReference(f.reference, expr) then
        t = self:narrowTypeBySwitchOnDiscriminant(t, data)
    elseif expr.kind == Kind.TypeOfExpression and self:isMatchingReference(f.reference, expr:Expression()) then
        t = self:narrowTypeBySwitchOnTypeOf(t, data)
    elseif expr.kind == Kind.TrueKeyword then
        t = self:narrowTypeBySwitchOnTrue(f, t, data)
    else
        if self.strictNullChecks then
            if self:optionalChainContainsReference(expr, f.reference) then
                t = self:narrowTypeBySwitchOptionalChainContainment(t, data, function(t)
                    return t.flags & (TypeFlags.Undefined | TypeFlags.Never) == 0
                end)
            elseif ast.IsTypeOfExpression(expr) and self:optionalChainContainsReference(expr:Expression(), f.reference) then
                t = self:narrowTypeBySwitchOptionalChainContainment(t, data, function(t)
                    return not (t.flags & TypeFlags.Never ~= 0 or t.flags & TypeFlags.StringLiteral ~= 0 and checker.getStringLiteralValue(t) == "undefined")
                end)
            end
        end
        local access = self:getDiscriminantPropertyAccess(f, expr, t)
        if access ~= nil then
            t = self:narrowTypeBySwitchOnDiscriminantProperty(t, access, data)
        end
    end
    return self:newFlowType(t, flowType.incomplete)
end

function Checker:narrowTypeBySwitchOnDiscriminant(t, data)
    -- We only narrow if all case expressions specify
    -- values with unit types, except for the case where
    -- `type` is unknown. In this instance we map object
    -- types to the nonPrimitive type and narrow with that.
    local switchTypes = self:getSwitchClauseTypes(data.switchStatement)
    if core.Len(switchTypes) == 0 then
        return t
    end
    local clauseTypes = core.Slice(switchTypes, data.clauseStart, data.clauseEnd)
    local hasDefaultClause = data.clauseStart == data.clauseEnd or containsValue(clauseTypes, self.neverType)
    if (t.flags & TypeFlags.Unknown ~= 0) and not hasDefaultClause then
        local groundClauseTypes
        for i1, s in ipairs(clauseTypes) do
            local i = i1 - 1
            if s.flags & (TypeFlags.Primitive | TypeFlags.NonPrimitive) ~= 0 then
                if groundClauseTypes ~= nil then
                    groundClauseTypes[#groundClauseTypes + 1] = s
                end
            elseif s.flags & TypeFlags.Object ~= 0 then
                if groundClauseTypes == nil then
                    groundClauseTypes = core.Slice(clauseTypes, 0, i)
                end
                groundClauseTypes[#groundClauseTypes + 1] = self.nonPrimitiveType
            else
                return t
            end
        end
        return self:getUnionType(core.IfElse(groundClauseTypes == nil, clauseTypes, groundClauseTypes))
    end
    local discriminantType = self:getUnionType(clauseTypes)
    local caseType
    if discriminantType.flags & TypeFlags.Never ~= 0 then
        caseType = self.neverType
    else
        if discriminantType.flags & TypeFlags.Primitive ~= 0 and self:isUniformUnionType(t) then
            local regularType = self:getRegularTypeOfLiteralType(discriminantType)
            if self:unionContainsType(t, regularType, false --[[matchSymbol]]) then
                caseType = regularType
            end
        end
        if caseType == nil then
            local filtered = self:filterType(t, function(t)
                return self:areTypesComparable(discriminantType, t)
            end)
            caseType = self:replacePrimitivesWithLiterals(filtered, discriminantType)
        end
    end
    if not hasDefaultClause then
        return caseType
    end
    local defaultType = self:filterType(t, function(t)
        if not self:isUnitLikeType(t) then
            return true
        end
        local u = self.undefinedType
        if t.flags & TypeFlags.Undefined == 0 then
            u = self:getRegularTypeOfLiteralType(self:extractUnitType(t))
        end
        return not core.Some(switchTypes, function(st)
            return checker.isUnitType(st) and self:areTypesComparable(st, u)
        end)
    end)
    if caseType.flags & TypeFlags.Never ~= 0 then
        return defaultType
    end
    return self:getUnionType({ caseType, defaultType })
end

function Checker:narrowTypeBySwitchOnTypeOf(t, data)
    local witnesses = self:getSwitchClauseTypeOfWitnesses(data.switchStatement)
    if witnesses == nil then
        return t
    end
    local clauses = data.switchStatement:AsSwitchStatement().caseBlock:AsCaseBlock().clauses.nodes
    -- Equal start and end denotes implicit fallthrough; undefined marks explicit default clause.
    local defaultIndex = core.FindIndex(clauses, function(clause)
        return clause.kind == Kind.DefaultClause
    end)
    local clauseStart = data.clauseStart
    local clauseEnd = data.clauseEnd
    local hasDefaultClause = clauseStart == clauseEnd or (defaultIndex >= clauseStart and defaultIndex < clauseEnd)
    if hasDefaultClause then
        -- In the default clause we filter constituents down to those that are not-equal to all handled cases.
        local notEqualFacts = self:getNotEqualFactsFromTypeofSwitch(clauseStart, clauseEnd, witnesses)
        return self:filterType(t, function(t)
            return self:getTypeFacts(t, notEqualFacts) == notEqualFacts
        end)
    end
    -- In the non-default cause we create a union of the type narrowed by each of the listed cases.
    local clauseWitnesses = core.Slice(witnesses, clauseStart, clauseEnd)
    return self:getUnionType(core.Map(clauseWitnesses, function(text)
        if text ~= "" then
            return self:narrowTypeByTypeName(t, text)
        end
        return self.neverType
    end))
end

function Checker:narrowTypeBySwitchOnTrue(f, t, data)
    local clauses = data.switchStatement:AsSwitchStatement().caseBlock:AsCaseBlock().clauses.nodes
    local defaultIndex = core.FindIndex(clauses, function(clause)
        return clause.kind == Kind.DefaultClause
    end)
    local clauseStart = data.clauseStart
    local clauseEnd = data.clauseEnd
    local hasDefaultClause = clauseStart == clauseEnd or (defaultIndex >= clauseStart and defaultIndex < clauseEnd)
    -- First, narrow away all of the cases that preceded this set of cases.
    for i = 0, clauseStart - 1 do
        local clause = clauses[i + 1]
        if clause.kind == Kind.CaseClause then
            t = self:narrowType(f, t, clause:Expression(), false --[[assumeTrue]])
        end
    end
    -- If our current set has a default, then none the other cases were hit either.
    -- There's no point in narrowing by the other cases in the set, since we can
    -- get here through other paths.
    if hasDefaultClause then
        for i = clauseEnd, #clauses - 1 do
            local clause = clauses[i + 1]
            if clause.kind == Kind.CaseClause then
                t = self:narrowType(f, t, clause:Expression(), false --[[assumeTrue]])
            end
        end
        return t
    end
    -- Now, narrow based on the cases in this set.
    return self:getUnionType(core.Map(core.Slice(clauses, clauseStart, clauseEnd), function(clause)
        if clause.kind == Kind.CaseClause then
            return self:narrowType(f, t, clause:Expression(), true --[[assumeTrue]])
        end
        return self.neverType
    end))
end

function Checker:narrowTypeBySwitchOptionalChainContainment(t, data, clauseCheck)
    local everyClauseChecks = data.clauseStart ~= data.clauseEnd and core.Every(core.Slice(self:getSwitchClauseTypes(data.switchStatement), data.clauseStart, data.clauseEnd), clauseCheck)
    if everyClauseChecks then
        return self:getTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
    end
    return t
end

function Checker:narrowTypeBySwitchOnDiscriminantProperty(t, access, data)
    if data.clauseStart < data.clauseEnd and t.flags & TypeFlags.Union ~= 0 then
        local accessedName = self:getAccessedPropertyName(access)
        if accessedName ~= "" and self:getKeyPropertyName(t) == accessedName then
            local clauseTypes = core.Slice(self:getSwitchClauseTypes(data.switchStatement), data.clauseStart, data.clauseEnd)
            local candidate = self:getUnionType(core.Map(clauseTypes, function(s)
                local result = self:getConstituentTypeForKeyType(t, s)
                if result ~= nil then
                    return result
                end
                return self.unknownType
            end))
            if candidate ~= self.unknownType then
                return candidate
            end
        end
    end
    return self:narrowTypeByDiscriminant(t, access, function(t)
        return self:narrowTypeBySwitchOnDiscriminant(t, data)
    end)
end

function Checker:getTypeAtFlowBranchLabel(f, flow, antecedents)
    local antecedentStart = #self.antecedentTypes
    local subtypeReduction = false
    local seenIncomplete = false
    local bypassFlow
    local list = antecedents
    while list ~= nil do
        local antecedent = list.flow
        if bypassFlow == nil and antecedent.flags & FlowFlags.SwitchClause ~= 0 and antecedent.node:AsFlowSwitchClauseData():IsEmpty() then
            -- The antecedent is the bypass branch of a potentially exhaustive switch statement.
            bypassFlow = antecedent
            goto continue
        end
        do
            local flowType = self:getTypeAtFlowNode(f, antecedent)
            -- If the type at a particular antecedent path is the declared type and the
            -- reference is known to always be assigned (i.e. when declared and initial types
            -- are the same), there is no reason to process more antecedents since the only
            -- possible outcome is subtypes that will be removed in the final union type anyway.
            if flowType.t == f.declaredType and f.declaredType == f.initialType then
                truncate(self.antecedentTypes, antecedentStart)
                return FlowType(flowType.t)
            end
            if not containsValue(self.antecedentTypes, flowType.t, antecedentStart) then
                self.antecedentTypes[#self.antecedentTypes + 1] = flowType.t
            end
            -- If an antecedent type is not a subset of the declared type, we need to perform
            -- subtype reduction. This happens when a "foreign" type is injected into the control
            -- flow using the instanceof operator or a user defined type predicate.
            if not self:isTypeSubsetOf(flowType.t, f.initialType) then
                subtypeReduction = true
            end
            if flowType.incomplete then
                seenIncomplete = true
            end
        end
        ::continue::
        list = list.next
    end
    if bypassFlow ~= nil then
        local flowType = self:getTypeAtFlowNode(f, bypassFlow)
        -- If the bypass flow contributes a type we haven't seen yet and the switch statement
        -- isn't exhaustive, process the bypass flow type. Since exhaustiveness checks increase
        -- the risk of circularities, we only want to perform them when they make a difference.
        if flowType.t.flags & TypeFlags.Never == 0 and not containsValue(self.antecedentTypes, flowType.t, antecedentStart) and not self:isExhaustiveSwitchStatement(bypassFlow.node:AsFlowSwitchClauseData().switchStatement) then
            if flowType.t == f.declaredType and f.declaredType == f.initialType then
                truncate(self.antecedentTypes, antecedentStart)
                return FlowType(flowType.t)
            end
            self.antecedentTypes[#self.antecedentTypes + 1] = flowType.t
            if not self:isTypeSubsetOf(flowType.t, f.initialType) then
                subtypeReduction = true
            end
            if flowType.incomplete then
                seenIncomplete = true
            end
        end
    end
    local result = self:newFlowType(self:getUnionOrEvolvingArrayType(f, core.Slice(self.antecedentTypes, antecedentStart, #self.antecedentTypes), core.IfElse(subtypeReduction, UnionReduction.Subtype, UnionReduction.Literal)), seenIncomplete)
    truncate(self.antecedentTypes, antecedentStart)
    return result
end

-- At flow control branch or loop junctions, if the type along every antecedent code path
-- is an evolving array type, we construct a combined evolving array type. Otherwise we
-- finalize all evolving array types.
function Checker:getUnionOrEvolvingArrayType(f, types, subtypeReduction)
    if checker.isEvolvingArrayTypeList(types) then
        return self:getEvolvingArrayType(self:getUnionType(core.Map(types, function(t)
            return self:getElementTypeOfEvolvingArrayType(t)
        end)))
    end
    local result = self:recombineUnknownType(self:getUnionTypeEx(core.SameMap(types, function(t)
        return self:finalizeEvolvingArrayType(t)
    end), subtypeReduction, nil, nil))
    if result ~= f.declaredType and result.flags & f.declaredType.flags & TypeFlags.Union ~= 0 and equalValues(result:AsUnionType().types, f.declaredType:AsUnionType().types) then
        return f.declaredType
    end
    return result
end

function Checker:getTypeAtFlowLoopLabel(f, flow)
    if checker.CacheHashKey_IsZero(f.refKey) then
        f.refKey = self:getFlowReferenceKey(f)
    end
    if f.refKey == checker.nonDottedNameCacheKey then
        -- No cache key is generated when binding patterns are in unnarrowable situations
        return FlowType(f.declaredType)
    end
    local key = checker.FlowLoopKey(flow, f.refKey)
    -- If we have previously computed the control flow type for the reference at
    -- this flow loop junction, return the cached type.
    local cached = self.flowLoopCache[key]
    if cached ~= nil then
        return FlowType(cached)
    end
    -- If this flow loop junction and reference are already being processed, return
    -- the union of the types computed for each branch so far, marked as incomplete.
    -- It is possible to see an empty array in cases where loops are nested and the
    -- back edge of the outer loop reaches an inner loop that is already being analyzed.
    -- In such cases we restart the analysis of the inner loop, which will then see
    -- a non-empty in-process array for the outer loop and eventually terminate because
    -- the first antecedent of a loop junction is always the non-looping control flow
    -- path that leads to the top.
    for _, loopInfo in ipairs(self.flowLoopStack or {}) do
        if loopInfo.key == key and #loopInfo.types ~= 0 then
            return self:newFlowType(self:getUnionOrEvolvingArrayType(f, loopInfo.types, UnionReduction.Literal), true --[[incomplete]])
        end
    end
    -- Add the flow loop junction and reference to the in-process stack and analyze
    -- each antecedent code path.
    local antecedentTypes = {}
    local subtypeReduction = false
    local firstAntecedentType = FlowType(nil)
    local list = flow.antecedents
    while list ~= nil do
        local flowType
        if firstAntecedentType:isNil() then
            -- The first antecedent of a loop junction is always the non-looping control
            -- flow path that leads to the top.
            firstAntecedentType = self:getTypeAtFlowNode(f, list.flow)
            flowType = firstAntecedentType
        else
            -- All but the first antecedent are the looping control flow paths that lead
            -- back to the loop junction. We track these on the flow loop stack.
            -- (Go stores a slice header: the stacked entry sees the types gathered so far.)
            self.flowLoopStack = core.Append(self.flowLoopStack, checker.FlowLoopInfo_new({ key = key, types = core.Slice(antecedentTypes, 0, #antecedentTypes) }))
            local saveFlowTypeCache = self.flowTypeCache
            self.flowTypeCache = nil
            flowType = self:getTypeAtFlowNode(f, list.flow)
            self.flowTypeCache = saveFlowTypeCache
            self.flowLoopStack[#self.flowLoopStack] = nil
            -- If we see a value appear in the cache it is a sign that control flow analysis
            -- was restarted and completed by checkExpressionCached. We can simply pick up
            -- the resulting type and bail out.
            cached = self.flowLoopCache[key]
            if cached ~= nil then
                return FlowType(cached)
            end
        end
        antecedentTypes = core.AppendIfUnique(antecedentTypes, flowType.t)
        -- If an antecedent type is not a subset of the declared type, we need to perform
        -- subtype reduction. This happens when a "foreign" type is injected into the control
        -- flow using the instanceof operator or a user defined type predicate.
        if not self:isTypeSubsetOf(flowType.t, f.initialType) then
            subtypeReduction = true
        end
        -- If the type at a particular antecedent path is the declared type there is no
        -- reason to process more antecedents since the only possible outcome is subtypes
        -- that will be removed in the final union type anyway.
        if flowType.t == f.declaredType then
            break
        end
        list = list.next
    end
    -- The result is incomplete if the first antecedent (the non-looping control flow path)
    -- is incomplete.
    local result = self:getUnionOrEvolvingArrayType(f, antecedentTypes, core.IfElse(subtypeReduction, UnionReduction.Subtype, UnionReduction.Literal))
    if firstAntecedentType.incomplete then
        return self:newFlowType(result, true --[[incomplete]])
    end
    self.flowLoopCache[key] = result
    return FlowType(result)
end

function Checker:getTypeAtFlowArrayMutation(f, flow)
    if f.declaredType == self.autoType or f.declaredType == self.autoArrayType then
        local node = flow.node
        local expr
        if ast.IsCallExpression(node) then
            expr = node:Expression():Expression()
        else
            expr = node:AsBinaryExpression().left:Expression()
        end
        if self:isMatchingReference(f.reference, self:getReferenceCandidate(expr)) then
            local flowType = self:getTypeAtFlowNode(f, flow.antecedent)
            if flowType.t.objectFlags & ObjectFlags.EvolvingArray ~= 0 then
                local evolvedType = flowType.t
                if ast.IsCallExpression(node) then
                    for _, arg in ipairs(node:Arguments() or {}) do
                        evolvedType = self:addEvolvingArrayElementType(evolvedType, arg)
                    end
                else
                    -- We must get the context free expression type so as to not recur in an uncached fashion on the LHS (which causes exponential blowup in compile time)
                    local indexType = self:getContextFreeTypeOfExpression(node:AsBinaryExpression().left:AsElementAccessExpression().argumentExpression)
                    if self:isTypeAssignableToKind(indexType, TypeFlags.NumberLike) then
                        evolvedType = self:addEvolvingArrayElementType(evolvedType, node:AsBinaryExpression().right)
                    end
                end
                return self:newFlowType(evolvedType, flowType.incomplete)
            end
            return flowType
        end
    end
    return FlowType(nil)
end

function Checker:getDiscriminantPropertyAccess(f, expr, computedType)
    -- As long as the computed type is a subset of the declared type, we use the full declared type to detect
    -- a discriminant property. In cases where the computed type isn't a subset, e.g because of a preceding type
    -- predicate narrowing, we use the actual computed type.
    if f.declaredType.flags & TypeFlags.Union ~= 0 or computedType.flags & TypeFlags.Union ~= 0 then
        local access = self:getCandidateDiscriminantPropertyAccess(f, expr)
        if access ~= nil then
            local name, ok = self:getAccessedPropertyName(access)
            if ok then
                local t = computedType
                if f.declaredType.flags & TypeFlags.Union ~= 0 and self:isTypeSubsetOf(computedType, f.declaredType) then
                    t = f.declaredType
                end
                if self:isDiscriminantProperty(t, name) then
                    return access
                end
            end
        end
    end
    return nil
end

function Checker:getCandidateDiscriminantPropertyAccess(f, expr)
    if ast.IsBindingPattern(f.reference) or ast.IsFunctionExpressionOrArrowFunction(f.reference) or ast.IsObjectLiteralMethod(f.reference) then
        -- When the reference is a binding pattern or function or arrow expression, we are narrowing a pseudo-reference in
        -- getNarrowedTypeOfSymbol. An identifier for a destructuring variable declared in the same binding pattern or
        -- parameter declared in the same parameter list is a candidate.
        if ast.IsIdentifier(expr) then
            local symbol = self:getResolvedSymbol(expr)
            local declaration = self:getExportSymbolOfValueSymbolIfExported(symbol).valueDeclaration
            if declaration ~= nil and (ast.IsBindingElement(declaration) or ast.IsParameterDeclaration(declaration)) and f.reference == declaration.parent and declaration:Initializer() == nil and not checker.hasDotDotDotToken(declaration) then
                return declaration
            end
        end
    elseif ast.IsAccessExpression(expr) then
        -- An access expression is a candidate if the reference matches the left hand expression.
        if self:isMatchingReference(f.reference, expr:Expression()) then
            return expr
        end
    elseif ast.IsIdentifier(expr) then
        local symbol = self:getResolvedSymbol(expr)
        if self:isConstantVariable(symbol) then
            local declaration = symbol.valueDeclaration
            local initializer = checker.getCandidateVariableDeclarationInitializer(declaration)
            -- Given 'const x = obj.kind', allow 'x' as an alias for 'obj.kind'
            if initializer ~= nil and ast.IsAccessExpression(initializer) and self:isMatchingReference(f.reference, initializer:Expression()) then
                return initializer
            end
            -- Given 'const { kind: x } = obj', allow 'x' as an alias for 'obj.kind'
            if ast.IsBindingElement(declaration) and declaration:Initializer() == nil then
                initializer = checker.getCandidateVariableDeclarationInitializer(declaration.parent.parent)
                if initializer ~= nil and (ast.IsIdentifier(initializer) or ast.IsAccessExpression(initializer)) and self:isMatchingReference(f.reference, initializer) then
                    return declaration
                end
            end
        end
    end
    return nil
end

function checker.getCandidateVariableDeclarationInitializer(node)
    if ast.IsVariableDeclaration(node) and node:Type() == nil then
        local initializer = node:Initializer()
        if initializer ~= nil then
            return ast.SkipParentheses(initializer)
        end
    end
    return nil
end

-- An evolving array type tracks the element types that have so far been seen in an
-- 'x.push(value)' or 'x[n] = value' operation along the control flow graph. Evolving
-- array types are ultimately converted into manifest array types (using getFinalArrayType)
-- and never escape the getFlowTypeOfReference function.
function Checker:getEvolvingArrayType(elementType)
    local key = checker.CachedTypeKey(checker.CachedTypeKind.EvolvingArrayType, elementType.id)
    local result = self.cachedTypes[key]
    if result == nil then
        result = self:newObjectType(ObjectFlags.EvolvingArray, nil)
        result:AsEvolvingArrayType().elementType = elementType
        self.cachedTypes[key] = result
    end
    return result
end

function Checker:getElementTypeOfEvolvingArrayType(t)
    if t.objectFlags & ObjectFlags.EvolvingArray ~= 0 then
        return t:AsEvolvingArrayType().elementType
    end
    return self.neverType
end

function checker.isEvolvingArrayTypeList(types)
    local hasEvolvingArrayType = false
    for _, t in ipairs(types or {}) do
        if t.flags & TypeFlags.Never == 0 then
            if t.objectFlags & ObjectFlags.EvolvingArray == 0 then
                return false
            end
            hasEvolvingArrayType = true
        end
    end
    return hasEvolvingArrayType
end

-- Return true if the given node is 'x' in an 'x.length', x.push(value)', 'x.unshift(value)' or
-- 'x[n] = value' operation, where 'n' is an expression of type any, undefined, or a number-like type.
function Checker:isEvolvingArrayOperationTarget(node)
    local root = self:getReferenceRoot(node)
    local parent = root.parent
    local isLengthPushOrUnshift = ast.IsPropertyAccessExpression(parent) and (parent:Name():Text() == "length" or
        ast.IsCallExpression(parent.parent) and ast.IsIdentifier(parent:Name()) and ast.IsPushOrUnshiftIdentifier(parent:Name()))
    local isElementAssignment = ast.IsElementAccessExpression(parent) and parent:Expression() == root and
        ast.IsBinaryExpression(parent.parent) and parent.parent:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken and
        parent.parent:AsBinaryExpression().left == parent and not ast.IsAssignmentTarget(parent.parent) and
        self:isTypeAssignableToKind(self:getTypeOfExpression(parent:AsElementAccessExpression().argumentExpression), TypeFlags.NumberLike)
    return isLengthPushOrUnshift or isElementAssignment
end

-- When adding evolving array element types we do not perform subtype reduction. Instead,
-- we defer subtype reduction until the evolving array type is finalized into a manifest
-- array type.
function Checker:addEvolvingArrayElementType(evolvingArrayType, node)
    local newElementType = self:getRegularTypeOfObjectLiteral(self:getBaseTypeOfLiteralType(self:getContextFreeTypeOfExpression(node)))
    local elementType = evolvingArrayType:AsEvolvingArrayType().elementType
    if self:isTypeSubsetOf(newElementType, elementType) then
        return evolvingArrayType
    end
    return self:getEvolvingArrayType(self:getUnionType({ elementType, newElementType }))
end

function Checker:finalizeEvolvingArrayType(t)
    if t.objectFlags & ObjectFlags.EvolvingArray ~= 0 then
        return self:getFinalArrayType(t:AsEvolvingArrayType())
    end
    return t
end

function Checker:getFinalArrayType(t)
    if t.finalArrayType == nil then
        t.finalArrayType = self:createFinalArrayType(t.elementType)
    end
    return t.finalArrayType
end

function Checker:createFinalArrayType(elementType)
    if elementType.flags & TypeFlags.Never ~= 0 then
        return self.autoArrayType
    elseif elementType.flags & TypeFlags.Union ~= 0 then
        return self:createArrayType(self:getUnionTypeEx(elementType:Types(), UnionReduction.Subtype, nil, nil))
    end
    return self:createArrayType(elementType)
end

function Checker:reportFlowControlError(node)
    local block = ast.FindAncestor(node, function(n)
        return ast.IsFunctionOrModuleBlock(n)
    end)
    local sourceFile = ast.GetSourceFileOfNode(node)
    local span = scanner.GetRangeOfTokenAtPosition(sourceFile, block:StatementList():Pos())
    self:addDiagnostic(ast.NewDiagnostic(sourceFile, span, diagnostics.The_containing_function_or_module_body_is_too_large_for_control_flow_analysis))
end

function Checker:isMatchingReference(source, target)
    local tk = target.kind
    if tk == Kind.ParenthesizedExpression or tk == Kind.NonNullExpression then
        return self:isMatchingReference(source, target:Expression())
    elseif tk == Kind.BinaryExpression then
        return ast.IsAssignmentExpression(target, false) and self:isMatchingReference(source, target:AsBinaryExpression().left) or
            ast.IsBinaryExpression(target) and target:AsBinaryExpression().operatorToken.kind == Kind.CommaToken and
            self:isMatchingReference(source, target:AsBinaryExpression().right)
    end
    local sk = source.kind
    if sk == Kind.MetaProperty then
        return ast.IsMetaProperty(target) and source:AsMetaProperty().keywordToken == target:AsMetaProperty().keywordToken and source:Name():Text() == target:Name():Text()
    elseif sk == Kind.Identifier or sk == Kind.PrivateIdentifier then
        if ast.IsThisInTypeQuery(source) then
            return target.kind == Kind.ThisKeyword
        end
        return ast.IsIdentifier(target) and self:getResolvedSymbol(source) == self:getResolvedSymbol(target) or
            (ast.IsVariableDeclaration(target) or ast.IsBindingElement(target)) and self:getExportSymbolOfValueSymbolIfExported(self:getResolvedSymbol(source)) == self:getSymbolOfDeclaration(target)
    elseif sk == Kind.ThisKeyword then
        return target.kind == Kind.ThisKeyword
    elseif sk == Kind.SuperKeyword then
        return target.kind == Kind.SuperKeyword
    elseif sk == Kind.NonNullExpression or sk == Kind.ParenthesizedExpression or sk == Kind.SatisfiesExpression then
        return self:isMatchingReference(source:Expression(), target)
    elseif sk == Kind.PropertyAccessExpression or sk == Kind.ElementAccessExpression then
        local sourcePropertyName, ok = self:getAccessedPropertyName(source)
        if ok then
            if ast.IsAccessExpression(target) then
                local targetPropertyName, ok2 = self:getAccessedPropertyName(target)
                if ok2 then
                    return targetPropertyName == sourcePropertyName and self:isMatchingReference(source:Expression(), target:Expression())
                end
            end
        end
        if ast.IsElementAccessExpression(source) and ast.IsElementAccessExpression(target) then
            local sourceArg = source:AsElementAccessExpression().argumentExpression
            local targetArg = target:AsElementAccessExpression().argumentExpression
            if ast.IsIdentifier(sourceArg) and ast.IsIdentifier(targetArg) then
                local symbol = self:getResolvedSymbol(sourceArg)
                if symbol == self:getResolvedSymbol(targetArg) and (self:isConstantVariable(symbol) or self:isParameterOrMutableLocalVariable(symbol) and not self:isSymbolAssigned(symbol)) then
                    return self:isMatchingReference(source:Expression(), target:Expression())
                end
            end
        end
    elseif sk == Kind.QualifiedName then
        if ast.IsAccessExpression(target) then
            local targetPropertyName, ok = self:getAccessedPropertyName(target)
            if ok then
                return source:AsQualifiedName().right:Text() == targetPropertyName and self:isMatchingReference(source:AsQualifiedName().left, target:Expression())
            end
        end
    elseif sk == Kind.BinaryExpression then
        return ast.IsBinaryExpression(source) and source:AsBinaryExpression().operatorToken.kind == Kind.CommaToken and self:isMatchingReference(source:AsBinaryExpression().right, target)
    end
    return false
end

checker.nonDottedNameCacheKey = checker.hashString128("?")

-- Return the flow cache key for a "dotted name" (i.e. a sequence of identifiers
-- separated by dots). The key consists of the id of the symbol referenced by the
-- leftmost identifier followed by zero or more property names separated by dots.
-- The result is nonDottedNameCacheKey if the reference isn't a dotted name.
function Checker:getFlowReferenceKey(f)
    local b = checker.keyBuilder_new({ inlineBuffer = {} })
    if self:writeFlowCacheKey(b, f.reference, f.declaredType, f.initialType, f.flowContainer) then
        return b:hash()
    end
    return checker.nonDottedNameCacheKey -- Reference isn't a dotted name
end

function Checker:writeFlowCacheKey(b, node, declaredType, initialType, flowContainer)
    local kind = node.kind
    if kind == Kind.Identifier or kind == Kind.ThisKeyword then
        if kind == Kind.Identifier then
            if not ast.IsThisInTypeQuery(node) then
                local symbol = self:getResolvedSymbol(node)
                if symbol == self.unknownSymbol then
                    return false
                end
                b:writeSymbol(symbol)
            end
        end
        -- fallthrough
        b:writeByte(string.byte(":"))
        b:writeType(declaredType)
        if initialType ~= declaredType then
            b:writeByte(string.byte("="))
            b:writeType(initialType)
        end
        if flowContainer ~= nil then
            b:writeByte(string.byte("@"))
            b:writeNode(flowContainer)
        end
        return true
    elseif kind == Kind.NonNullExpression or kind == Kind.ParenthesizedExpression then
        return self:writeFlowCacheKey(b, node:Expression(), declaredType, initialType, flowContainer)
    elseif kind == Kind.QualifiedName then
        if not self:writeFlowCacheKey(b, node:AsQualifiedName().left, declaredType, initialType, flowContainer) then
            return false
        end
        b:writeByte(string.byte("."))
        b:writeString(node:AsQualifiedName().right:Text())
        return true
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        local propName, ok = self:getAccessedPropertyName(node)
        if ok then
            if not self:writeFlowCacheKey(b, node:Expression(), declaredType, initialType, flowContainer) then
                return false
            end
            b:writeByte(string.byte("."))
            b:writeString(propName)
            return true
        end
        if ast.IsElementAccessExpression(node) and ast.IsIdentifier(node:AsElementAccessExpression().argumentExpression) then
            local symbol = self:getResolvedSymbol(node:AsElementAccessExpression().argumentExpression)
            if self:isConstantVariable(symbol) or self:isParameterOrMutableLocalVariable(symbol) and not self:isSymbolAssigned(symbol) then
                if not self:writeFlowCacheKey(b, node:Expression(), declaredType, initialType, flowContainer) then
                    return false
                end
                b:writeString(".@")
                b:writeSymbol(symbol)
                return true
            end
        end
    elseif kind == Kind.ObjectBindingPattern or kind == Kind.ArrayBindingPattern or kind == Kind.FunctionDeclaration or
        kind == Kind.FunctionExpression or kind == Kind.ArrowFunction or kind == Kind.MethodDeclaration then
        b:writeNode(node)
        b:writeByte(string.byte("#"))
        b:writeType(declaredType)
        return true
    end
    return false
end

function Checker:getAccessedPropertyName(access)
    if ast.IsPropertyAccessExpression(access) then
        return access:Name():Text(), true
    end
    if ast.IsElementAccessExpression(access) then
        return self:tryGetElementAccessExpressionName(access:AsElementAccessExpression())
    end
    if ast.IsBindingElement(access) then
        return self:getDestructuringPropertyName(access)
    end
    if ast.IsParameterDeclaration(access) then
        return string.format("%d", indexOfValue(access.parent:Parameters(), access)), true
    end
    return "", false
end

function Checker:tryGetElementAccessExpressionName(node)
    if ast.IsStringOrNumericLiteralLike(node.argumentExpression) then
        return node.argumentExpression:Text(), true
    elseif ast.IsEntityNameExpression(node.argumentExpression) then
        return self:tryGetNameFromEntityNameExpression(node.argumentExpression)
    end
    return "", false
end

function Checker:tryGetNameFromEntityNameExpression(node)
    local symbol = self:resolveEntityName(node, SymbolFlags.Value, true --[[ignoreErrors]], false, nil)
    if symbol == nil or not (self:isConstantVariable(symbol) or (symbol.flags & SymbolFlags.EnumMember ~= 0)) then
        return "", false
    end
    local declaration = symbol.valueDeclaration
    if declaration == nil then
        return "", false
    end
    local t = self:tryGetTypeFromTypeNode(declaration)
    if t ~= nil then
        local name, ok = checker.tryGetNameFromType(t)
        if ok then
            return name, true
        end
    end
    -- We exclude binding elements because their initializers don't solely determine their types and resolving
    -- full types can cause circularities (see https://github.com/microsoft/TypeScript/issues/63192).
    if checker.hasOnlyExpressionInitializer(declaration) and not ast.IsBindingElement(declaration) and self:isBlockScopedNameDeclaredBeforeUse(declaration, node) then
        local initializer = declaration:Initializer()
        if initializer ~= nil then
            local initializerType = self:getTypeOfExpression(initializer)
            if initializerType ~= nil then
                return checker.tryGetNameFromType(initializerType)
            end
        elseif ast.IsEnumMember(declaration) then
            return ast.TryGetTextOfPropertyName(declaration:Name())
        end
    end
    return "", false
end

function checker.tryGetNameFromType(t)
    if t.flags & TypeFlags.UniqueESSymbol ~= 0 then
        return t:AsUniqueESSymbolType().name, true
    elseif t.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
        return evaluator.AnyToString(t:AsLiteralType().value), true
    end
    return "", false
end

function Checker:getDestructuringPropertyName(node)
    local parent = node.parent
    if ast.IsBindingElement(node) and ast.IsObjectBindingPattern(parent) then
        return self:getLiteralPropertyNameText(checker.getBindingElementPropertyName(node))
    end
    if ast.IsPropertyAssignment(node) or ast.IsShorthandPropertyAssignment(node) then
        return self:getLiteralPropertyNameText(node:Name())
    end
    if ast.IsArrayLiteralExpression(parent) or ast.IsArrayBindingPattern(parent) then
        return string.format("%d", indexOfValue(parent:Elements(), node)), true
    end
    return "", false
end

function Checker:getLiteralPropertyNameText(name)
    local t = self:getLiteralTypeFromPropertyName(name)
    if t.flags & (TypeFlags.StringLiteral | TypeFlags.NumberLiteral) ~= 0 then
        return evaluator.AnyToString(t:AsLiteralType().value), true
    end
    return "", false
end

function Checker:isConstantReference(node)
    local kind = node.kind
    if kind == Kind.ThisKeyword then
        return true
    elseif kind == Kind.Identifier then
        if not ast.IsThisInTypeQuery(node) then
            local symbol = self:getResolvedSymbol(node)
            return self:isConstantVariable(symbol) or self:isParameterOrMutableLocalVariable(symbol) and not self:isSymbolAssigned(symbol) or symbol.valueDeclaration ~= nil and ast.IsFunctionExpression(symbol.valueDeclaration)
        end
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        -- The resolvedSymbol property is initialized by checkPropertyAccess or checkElementAccess before we get here.
        if self:isConstantReference(node:Expression()) then
            local symbol = self:getResolvedSymbolOrNil(node)
            if symbol ~= nil then
                return self:isReadonlySymbol(symbol)
            end
        end
    elseif kind == Kind.ObjectBindingPattern or kind == Kind.ArrayBindingPattern then
        local rootDeclaration = ast.GetRootDeclaration(node.parent)
        if ast.IsParameterDeclaration(rootDeclaration) or ast.IsVariableDeclaration(rootDeclaration) and ast.IsCatchClause(rootDeclaration.parent) then
            return not self:isSomeSymbolAssigned(rootDeclaration)
        end
        return ast.IsVariableDeclaration(rootDeclaration) and self:isVarConstLike(rootDeclaration)
    end
    return false
end

function Checker:containsMatchingReference(source, target)
    while ast.IsAccessExpression(source) do
        source = source:Expression()
        if self:isMatchingReference(source, target) then
            return true
        end
    end
    return false
end

function Checker:optionalChainContainsReference(source, target)
    while ast.IsOptionalChain(source) do
        source = source:Expression()
        if self:isMatchingReference(source, target) then
            return true
        end
    end
    return false
end

function Checker:getReferenceCandidate(node)
    local kind = node.kind
    if kind == Kind.ParenthesizedExpression then
        return self:getReferenceCandidate(node:Expression())
    elseif kind == Kind.BinaryExpression then
        local op = node:AsBinaryExpression().operatorToken.kind
        if op == Kind.EqualsToken or op == Kind.BarBarEqualsToken or op == Kind.AmpersandAmpersandEqualsToken or op == Kind.QuestionQuestionEqualsToken then
            return self:getReferenceCandidate(node:AsBinaryExpression().left)
        elseif op == Kind.CommaToken then
            return self:getReferenceCandidate(node:AsBinaryExpression().right)
        end
    end
    return node
end

function Checker:getReferenceRoot(node)
    local parent = node.parent
    if ast.IsParenthesizedExpression(parent) or
        ast.IsBinaryExpression(parent) and parent:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken and parent:AsBinaryExpression().left == node or
        ast.IsBinaryExpression(parent) and parent:AsBinaryExpression().operatorToken.kind == Kind.CommaToken and parent:AsBinaryExpression().right == node then
        return self:getReferenceRoot(parent)
    end
    return node
end

function Checker:hasMatchingArgument(expression, reference)
    for _, argument in ipairs(expression:Arguments() or {}) do
        if self:isOrContainsMatchingReference(reference, argument) or self:optionalChainContainsReference(argument, reference) then
            return true
        end
    end
    if ast.IsPropertyAccessExpression(expression:Expression()) and self:isOrContainsMatchingReference(reference, expression:Expression():Expression()) then
        return true
    end
    return false
end

function Checker:isOrContainsMatchingReference(source, target)
    return self:isMatchingReference(source, target) or self:containsMatchingReference(source, target)
end

-- Return a new type in which occurrences of the string, number and bigint primitives and placeholder template
-- literal types in typeWithPrimitives have been replaced with occurrences of compatible and more specific types
-- from typeWithLiterals. This is essentially a limited form of intersection between the two types. We avoid a
-- true intersection because it is more costly and, when applied to union types, generates a large number of
-- types we don't actually care about.
function Checker:replacePrimitivesWithLiterals(typeWithPrimitives, typeWithLiterals)
    if self:maybeTypeOfKind(typeWithPrimitives, TypeFlags.String | TypeFlags.TemplateLiteral | TypeFlags.Number | TypeFlags.BigInt) and
        self:maybeTypeOfKind(typeWithLiterals, TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping | TypeFlags.NumberLiteral | TypeFlags.BigIntLiteral) then
        return self:mapType(typeWithPrimitives, function(t)
            if t.flags & TypeFlags.String ~= 0 then
                return self:extractTypesOfKind(typeWithLiterals, TypeFlags.String | TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping)
            elseif self:isPatternLiteralType(t) and not self:maybeTypeOfKind(typeWithLiterals, TypeFlags.String | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) then
                return self:extractTypesOfKind(typeWithLiterals, TypeFlags.StringLiteral)
            elseif t.flags & TypeFlags.Number ~= 0 then
                return self:extractTypesOfKind(typeWithLiterals, TypeFlags.Number | TypeFlags.NumberLiteral)
            elseif t.flags & TypeFlags.BigInt ~= 0 then
                return self:extractTypesOfKind(typeWithLiterals, TypeFlags.BigInt | TypeFlags.BigIntLiteral)
            else
                return t
            end
        end)
    end
    return typeWithPrimitives
end

function checker.isCoercibleUnderDoubleEquals(source, target)
    return source.flags & (TypeFlags.Number | TypeFlags.String | TypeFlags.BooleanLiteral) ~= 0 and
        target.flags & (TypeFlags.Number | TypeFlags.String | TypeFlags.Boolean) ~= 0
end

function Checker:isExhaustiveSwitchStatement(node)
    local links = self.switchStatementLinks:Get(node)
    if links.exhaustiveState == checker.ExhaustiveState.Unknown then
        -- Indicate resolution is in process
        links.exhaustiveState = checker.ExhaustiveState.Computing
        local isExhaustive = self:computeExhaustiveSwitchStatement(node)
        if links.exhaustiveState == checker.ExhaustiveState.Computing then
            links.exhaustiveState = core.IfElse(isExhaustive, checker.ExhaustiveState.True, checker.ExhaustiveState.False)
        end
    elseif links.exhaustiveState == checker.ExhaustiveState.Computing then
        -- Resolve circularity to false
        links.exhaustiveState = checker.ExhaustiveState.False
    end
    return links.exhaustiveState == checker.ExhaustiveState.True
end

function Checker:computeExhaustiveSwitchStatement(node)
    if ast.IsTypeOfExpression(node:Expression()) then
        local witnesses = self:getSwitchClauseTypeOfWitnesses(node)
        if witnesses == nil then
            return false
        end
        local operandConstraint = self:getBaseConstraintOrType(self:checkExpressionCached(node:Expression():Expression()))
        -- Get the not-equal flags for all handled cases.
        local notEqualFacts = self:getNotEqualFactsFromTypeofSwitch(0, 0, witnesses)
        if operandConstraint.flags & TypeFlags.AnyOrUnknown ~= 0 then
            -- We special case the top types to be exhaustive when all cases are handled.
            return TypeFacts.AllTypeofNE & notEqualFacts == TypeFacts.AllTypeofNE
        end
        -- A missing not-equal flag indicates that the type wasn't handled by some case.
        return not checker.someType(operandConstraint, function(t)
            return self:getTypeFacts(t, notEqualFacts) == notEqualFacts
        end)
    end
    local t = self:getBaseConstraintOrType(self:checkExpressionCached(node:Expression()))
    if not checker.isLiteralType(t) then
        return false
    end
    local switchTypes = self:getSwitchClauseTypes(node)
    if core.Len(switchTypes) == 0 or core.Some(switchTypes, function(x)
        return checker.isNeitherUnitTypeNorNever(x)
    end) then
        return false
    end
    return self:eachTypeContainedIn(self:mapType(t, function(x)
        return self:getRegularTypeOfLiteralType(x)
    end), switchTypes)
end

function Checker:eachTypeContainedIn(source, types)
    if source.flags & TypeFlags.Union ~= 0 then
        return not core.Some(source:AsUnionType().types, function(t)
            return not containsValue(types, t)
        end)
    end
    return containsValue(types, source)
end

-- Get the type names from all cases in a switch on `typeof`. The default clause and/or duplicate type names are
-- represented as empty strings. Return nil if one or more case clause expressions are not string literals.
function Checker:getSwitchClauseTypeOfWitnesses(node)
    local links = self.switchStatementLinks:Get(node)
    if not links.witnessesComputed then
        local clauses = node:AsSwitchStatement().caseBlock:AsCaseBlock().clauses.nodes
        local witnesses = {}
        for i = 1, #clauses do
            witnesses[i] = ""
        end
        for i1, clause in ipairs(clauses) do
            if clause.kind == Kind.CaseClause then
                if not ast.IsStringLiteralLike(clause:Expression()) then
                    witnesses = nil
                    break
                end
                local text = clause:Expression():Text()
                if not containsValue(witnesses, text) then
                    witnesses[i1] = text
                end
            end
        end
        links.witnesses = witnesses
        links.witnessesComputed = true
    end
    return links.witnesses
end

-- Return the combined not-equal type facts for all cases except those between the start and end indices.
function Checker:getNotEqualFactsFromTypeofSwitch(start, end_, witnesses)
    local facts = TypeFacts.None
    for i1, witness in ipairs(witnesses) do
        local i = i1 - 1
        if (i < start or i >= end_) and witness ~= "" then
            local f = checker.typeofNEFacts[witness]
            if f == nil then
                f = TypeFacts.TypeofNEHostObject
            end
            facts = facts | f
        end
    end
    return facts
end

function Checker:getSwitchClauseTypes(node)
    local links = self.switchStatementLinks:Get(node)
    if not links.switchTypesComputed then
        local clauses = node:AsSwitchStatement().caseBlock:AsCaseBlock().clauses.nodes
        local types = {}
        for i, clause in ipairs(clauses) do
            types[i] = self:getTypeOfSwitchClause(clause)
        end
        links.switchTypes = types
        links.switchTypesComputed = true
    end
    return links.switchTypes
end

function Checker:getTypeOfSwitchClause(clause)
    if clause.kind == Kind.CaseClause then
        return self:getRegularTypeOfLiteralType(self:getTypeOfExpression(clause:Expression()))
    end
    return self.neverType
end

function Checker:getEffectsSignature(node)
    local links = self.signatureLinks:Get(node)
    local signature = links.effectsSignature
    if signature == nil then
        -- A call expression parented by an expression statement is a potential assertion. Other call
        -- expressions are potential type predicate function calls. In order to avoid triggering
        -- circularities in control flow analysis, we use getTypeOfDottedName when resolving the call
        -- target expression of an assertion.
        local funcType
        if ast.IsBinaryExpression(node) then
            local rightType = self:checkNonNullExpression(node:AsBinaryExpression().right)
            funcType = self:getSymbolHasInstanceMethodOfObjectType(rightType)
        elseif ast.IsExpressionStatement(node.parent) then
            funcType = self:getTypeOfDottedName(node:Expression(), nil --[[diagnostic]])
        elseif node:Expression().kind ~= Kind.SuperKeyword then
            if ast.IsOptionalChain(node) then
                funcType = self:checkNonNullType(self:getOptionalExpressionType(self:checkExpression(node:Expression()), node:Expression()), node:Expression())
            else
                funcType = self:checkNonNullExpression(node:Expression())
            end
        end
        local apparentType
        if funcType ~= nil then
            apparentType = self:getApparentType(funcType)
        end
        local signatures = self:getSignaturesOfType(core.OrElse(apparentType, self.unknownType), SignatureKind.Call)
        if core.Len(signatures) == 1 and core.Len(signatures[1].typeParameters) == 0 then
            signature = signatures[1]
        elseif core.Some(signatures, function(s)
            return self:hasTypePredicateOrNeverReturnType(s)
        end) then
            signature = self:getResolvedSignature(node, nil, CheckMode.Normal)
        end
        if not (signature ~= nil and self:hasTypePredicateOrNeverReturnType(signature)) then
            signature = self.unknownSignature
        end
        links.effectsSignature = signature
    end
    if signature == self.unknownSignature then
        return nil
    end
    return signature
end

--[[
 * Get the type of the `[Symbol.hasInstance]` method of an object type.
]]
function Checker:getSymbolHasInstanceMethodOfObjectType(t)
    local hasInstancePropertyName = self:getPropertyNameForKnownSymbolName("hasInstance")
    if self:allTypesAssignableToKind(t, TypeFlags.NonPrimitive) then
        local hasInstanceProperty = self:getPropertyOfType(t, hasInstancePropertyName)
        if hasInstanceProperty ~= nil then
            local hasInstancePropertyType = self:getTypeOfSymbol(hasInstanceProperty)
            if hasInstancePropertyType ~= nil and core.Len(self:getSignaturesOfType(hasInstancePropertyType, SignatureKind.Call)) ~= 0 then
                return hasInstancePropertyType
            end
        end
    end
    return nil
end

function Checker:getPropertyNameForKnownSymbolName(symbolName)
    local ctorType = self.getGlobalESSymbolConstructorSymbolOrNil()
    if ctorType ~= nil then
        local uniqueType = self:getTypeOfPropertyOfType(self:getTypeOfSymbol(ctorType), symbolName)
        if uniqueType ~= nil and checker.isTypeUsableAsPropertyName(uniqueType) then
            return checker.getPropertyNameFromType(uniqueType)
        end
    end
    return ast.InternalSymbolNamePrefix .. "@" .. symbolName
end

-- We require the dotted function name in an assertion expression to be comprised of identifiers
-- that reference function, method, class or value module symbols; or variable, property or
-- parameter symbols with declarations that have explicit type annotations. Such references are
-- resolvable with no possibility of triggering circularities in control flow analysis.
function Checker:getTypeOfDottedName(node, diagnostic)
    if node.flags & NodeFlags.InWithStatement == 0 then
        local kind = node.kind
        if kind == Kind.Identifier then
            local symbol = self:getExportSymbolOfValueSymbolIfExported(self:getResolvedSymbol(node))
            return self:getExplicitTypeOfSymbol(symbol, diagnostic)
        elseif kind == Kind.ThisKeyword then
            return self:getExplicitThisType(node)
        elseif kind == Kind.SuperKeyword then
            return self:checkSuperExpression(node)
        elseif kind == Kind.PropertyAccessExpression then
            local t = self:getTypeOfDottedName(node:Expression(), diagnostic)
            if t ~= nil then
                local name = node:Name()
                local prop
                if ast.IsPrivateIdentifier(name) then
                    if t.symbol ~= nil then
                        prop = self:getPropertyOfType(t, binder.GetSymbolNameForPrivateIdentifier(t.symbol, name:Text()))
                    end
                else
                    prop = self:getPropertyOfType(t, name:Text())
                end
                if prop ~= nil then
                    return self:getExplicitTypeOfSymbol(prop, diagnostic)
                end
            end
        elseif kind == Kind.ParenthesizedExpression then
            return self:getTypeOfDottedName(node:Expression(), diagnostic)
        end
    end
    return nil
end

local function getExplicitTypeOfResolvedSymbol(c, symbol, diagnostic)
    if symbol.flags & (SymbolFlags.Function | SymbolFlags.Method | SymbolFlags.Class | SymbolFlags.ValueModule) ~= 0 then
        return c:getTypeOfSymbol(symbol)
    end
    if symbol.flags & (SymbolFlags.Variable | SymbolFlags.Property) ~= 0 then
        if symbol.checkFlags & CheckFlags.Mapped ~= 0 then
            local origin = c.mappedSymbolLinks:Get(symbol).syntheticOrigin
            if origin ~= nil and c:getExplicitTypeOfSymbol(origin, diagnostic) ~= nil then
                return c:getTypeOfSymbol(symbol)
            end
        end
        local declaration = symbol.valueDeclaration
        if declaration ~= nil then
            if c:isDeclarationWithExplicitTypeAnnotation(declaration) then
                return c:getTypeOfSymbol(symbol)
            end
            if ast.IsVariableDeclaration(declaration) and ast.IsForOfStatement(declaration.parent.parent) then
                local statement = declaration.parent.parent
                local expressionType = c:getTypeOfDottedName(statement:Expression(), nil --[[diagnostic]])
                if expressionType ~= nil then
                    local use
                    if statement:AsForInOrOfStatement().awaitModifier ~= nil then
                        use = checker.IterationUse.ForAwaitOf
                    else
                        use = checker.IterationUse.ForOf
                    end
                    return c:checkIteratedTypeOrElementType(use, expressionType, c.undefinedType, nil --[[errorNode]])
                end
            end
            if diagnostic ~= nil then
                diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(declaration, diagnostics.X_0_needs_an_explicit_type_annotation, c:symbolToString(symbol)))
            end
        end
    end
    return nil
end

function Checker:getExplicitTypeOfSymbol(symbol, diagnostic)
    symbol = self:resolveSymbol(symbol)
    if not self.resolvingExplicitTypeOfSymbol:AddIfAbsent(symbol) then
        return nil
    end
    local result = getExplicitTypeOfResolvedSymbol(self, symbol, diagnostic)
    self.resolvingExplicitTypeOfSymbol:Delete(symbol)
    return result
end

function Checker:isDeclarationWithExplicitTypeAnnotation(node)
    return (ast.IsVariableDeclaration(node) or ast.IsPropertyDeclaration(node) or ast.IsPropertySignatureDeclaration(node) or ast.IsParameterDeclaration(node)) and node:Type() ~= nil or
        self:isExpandoPropertyFunctionWithReturnTypeAnnotation(node)
end

function Checker:isExpandoPropertyFunctionWithReturnTypeAnnotation(node)
    if ast.IsBinaryExpression(node) then
        local expr = node:AsBinaryExpression().right
        if ast.IsFunctionLike(expr) and expr:Type() ~= nil then
            return true
        end
    end
    return false
end

function Checker:hasTypePredicateOrNeverReturnType(sig)
    return self:getTypePredicateOfSignature(sig) ~= nil or sig.declaration ~= nil and core.OrElse(self:getReturnTypeFromAnnotation(sig.declaration), self.unknownType).flags & TypeFlags.Never ~= 0
end

function Checker:getExplicitThisType(node)
    local container = ast.GetThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    if ast.IsFunctionLike(container) then
        local signature = self:getSignatureFromDeclaration(container)
        if signature.thisParameter ~= nil then
            return self:getExplicitTypeOfSymbol(signature.thisParameter, nil)
        end
    end
    if container.parent ~= nil and ast.IsClassLike(container.parent) then
        local symbol = self:getSymbolOfDeclaration(container.parent)
        if ast.IsStatic(container) then
            return self:getTypeOfSymbol(symbol)
        else
            return self:getDeclaredTypeOfSymbol(symbol):AsInterfaceType().thisType
        end
    end
    return nil
end

function Checker:getInitialType(node)
    if node.kind == Kind.VariableDeclaration then
        return self:getInitialTypeOfVariableDeclaration(node)
    elseif node.kind == Kind.BindingElement then
        return self:getInitialTypeOfBindingElement(node)
    end
    error("Unhandled case in getInitialType")
end

function Checker:getInitialTypeOfVariableDeclaration(node)
    if node:Initializer() ~= nil then
        return self:getTypeOfInitializer(node:Initializer())
    end
    if ast.IsForInStatement(node.parent.parent) then
        return self.stringType
    end
    if ast.IsForOfStatement(node.parent.parent) then
        local t = self:checkRightHandSideOfForOf(node.parent.parent)
        if t ~= nil then
            return t
        end
    end
    return self.errorType
end

function Checker:getTypeOfInitializer(node)
    -- Return the cached type if one is available. If the type of the variable was inferred
    -- from its initializer, we'll already have cached the type. Otherwise we compute it now
    -- without caching such that transient types are reflected.
    if self.typeNodeLinks:Has(node) then
        local t = self.typeNodeLinks:Get(node).resolvedType
        if t ~= nil then
            return t
        end
    end
    return self:getTypeOfExpression(node)
end

function Checker:getInitialTypeOfBindingElement(node)
    local pattern = node.parent
    local parentType = self:getInitialType(pattern.parent)
    local t
    if ast.IsObjectBindingPattern(pattern) then
        t = self:getTypeOfDestructuredProperty(parentType, checker.getBindingElementPropertyName(node))
    elseif not checker.hasDotDotDotToken(node) then
        t = self:getTypeOfDestructuredArrayElement(parentType, indexOfValue(pattern:Elements(), node))
    else
        t = self:getTypeOfDestructuredSpreadExpression(parentType)
    end
    return self:getTypeWithDefault(t, node:Initializer())
end

function Checker:getAssignedType(node)
    local parent = node.parent
    local kind = parent.kind
    if kind == Kind.ForInStatement then
        return self.stringType
    elseif kind == Kind.ForOfStatement then
        local t = self:checkRightHandSideOfForOf(parent)
        if t ~= nil then
            return t
        end
    elseif kind == Kind.BinaryExpression then
        return self:getAssignedTypeOfBinaryExpression(parent)
    elseif kind == Kind.DeleteExpression then
        return self.undefinedType
    elseif kind == Kind.ArrayLiteralExpression then
        return self:getAssignedTypeOfArrayLiteralElement(parent, node)
    elseif kind == Kind.SpreadElement then
        return self:getAssignedTypeOfSpreadExpression(parent)
    elseif kind == Kind.PropertyAssignment then
        return self:getAssignedTypeOfPropertyAssignment(parent)
    elseif kind == Kind.ShorthandPropertyAssignment then
        return self:getAssignedTypeOfShorthandPropertyAssignment(parent)
    end
    return self.errorType
end

function Checker:getAssignedTypeOfBinaryExpression(node)
    local isDestructuringDefaultAssignment = ast.IsArrayLiteralExpression(node.parent) and self:isDestructuringAssignmentTarget(node.parent) or
        ast.IsPropertyAssignment(node.parent) and self:isDestructuringAssignmentTarget(node.parent.parent)
    if isDestructuringDefaultAssignment then
        return self:getTypeWithDefault(self:getAssignedType(node), node:AsBinaryExpression().right)
    end
    return self:getTypeOfExpression(node:AsBinaryExpression().right)
end

function Checker:getAssignedTypeOfArrayLiteralElement(node, element)
    return self:getTypeOfDestructuredArrayElement(self:getAssignedType(node), indexOfValue(node:Elements(), element))
end

function Checker:getTypeOfDestructuredArrayElement(t, index)
    if checker.everyType(t, function(x)
        return self:isTupleLikeType(x)
    end) then
        local elementType = self:getTupleElementType(t, index)
        if elementType ~= nil then
            return elementType
        end
    end
    local elementType = self:checkIteratedTypeOrElementType(checker.IterationUse.Destructuring, t, self.undefinedType, nil --[[errorNode]])
    if elementType ~= nil then
        return self:includeUndefinedInIndexSignature(elementType)
    end
    return self.errorType
end

function Checker:includeUndefinedInIndexSignature(t)
    if t == nil then
        return nil
    end
    if self.compilerOptions.noUncheckedIndexedAccess == core.Tristate.TSTrue then
        return self:getUnionType({ t, self.missingType })
    end
    return t
end

function Checker:getAssignedTypeOfSpreadExpression(node)
    return self:getTypeOfDestructuredSpreadExpression(self:getAssignedType(node.parent))
end

function Checker:getTypeOfDestructuredSpreadExpression(t)
    local elementType = self:checkIteratedTypeOrElementType(checker.IterationUse.Destructuring, t, self.undefinedType, nil --[[errorNode]])
    if elementType == nil then
        elementType = self.errorType
    end
    return self:createArrayType(elementType)
end

function Checker:getAssignedTypeOfPropertyAssignment(node)
    return self:getTypeOfDestructuredProperty(self:getAssignedType(node.parent), node:Name())
end

function Checker:getTypeOfDestructuredProperty(t, name)
    local nameType = self:getLiteralTypeFromPropertyName(name)
    if not checker.isTypeUsableAsPropertyName(nameType) then
        return self.errorType
    end
    local text = checker.getPropertyNameFromType(nameType)
    local propType = self:getTypeOfPropertyOfType(t, text)
    if propType ~= nil then
        return propType
    end
    local indexInfo = self:getApplicableIndexInfoForName(t, text)
    if indexInfo ~= nil then
        return self:includeUndefinedInIndexSignature(indexInfo.valueType)
    end
    return self.errorType
end

function Checker:getAssignedTypeOfShorthandPropertyAssignment(node)
    return self:getTypeWithDefault(self:getAssignedTypeOfPropertyAssignment(node), node:AsShorthandPropertyAssignment().objectAssignmentInitializer)
end

function Checker:isDestructuringAssignmentTarget(parent)
    return ast.IsBinaryExpression(parent.parent) and parent.parent:AsBinaryExpression().left == parent or
        ast.IsForOfStatement(parent.parent) and parent.parent:Initializer() == parent
end

function Checker:getTypeWithDefault(t, defaultExpression)
    if defaultExpression ~= nil then
        return self:getUnionType({ self:getNonUndefinedType(t), self:getTypeOfExpression(defaultExpression) })
    end
    return t
end

-- Remove those constituent types of declaredType to which no constituent type of assignedType is assignable.
-- For example, when a variable of type number | string | boolean is assigned a value of type number | boolean,
-- we remove type string.
function Checker:getAssignmentReducedType(declaredType, assignedType)
    if declaredType == assignedType then
        return declaredType
    end
    if assignedType.flags & TypeFlags.Never ~= 0 then
        return assignedType
    end
    local key = checker.AssignmentReducedKey(declaredType.id, assignedType.id)
    local result = self.assignmentReducedTypes[key]
    if result == nil then
        result = self:getAssignmentReducedTypeWorker(declaredType, assignedType)
        self.assignmentReducedTypes[key] = result
    end
    return result
end

function Checker:getAssignmentReducedTypeWorker(declaredType, assignedType)
    local filteredType = self:filterType(declaredType, function(t)
        return self:typeMaybeAssignableTo(assignedType, t)
    end)
    -- Ensure that we narrow to fresh types if the assignment is a fresh boolean literal type.
    local reducedType = filteredType
    if assignedType.flags & TypeFlags.BooleanLiteral ~= 0 and checker.isFreshLiteralType(assignedType) then
        reducedType = self:mapType(filteredType, function(t)
            return self:getFreshTypeOfLiteralType(t)
        end)
    end
    -- Our crude heuristic produces an invalid result in some cases: see GH#26130.
    -- For now, when that happens, we give up and don't narrow at all.  (This also
    -- means we'll never narrow for erroneous assignments where the assigned type
    -- is not assignable to the declared type.)
    if self:isTypeAssignableTo(assignedType, reducedType) then
        return reducedType
    end
    return declaredType
end

function Checker:typeMaybeAssignableTo(source, target)
    if source.flags & TypeFlags.Union == 0 then
        return self:isTypeAssignableTo(source, target)
    end
    -- Quick exit when source union contains the target type
    if checker.containsType(source:Types(), target) then
        return true
    end
    -- Otherwise, check if any constituent type of the source union is assignable to the target type
    for _, t in ipairs(source:Types()) do
        if self:isTypeAssignableTo(t, target) then
            return true
        end
    end
    return false
end

function Checker:getTypePredicateArgument(predicate, callExpression)
    if predicate.kind == TypePredicateKind.Identifier or predicate.kind == TypePredicateKind.AssertsIdentifier then
        local arguments = callExpression:Arguments()
        if predicate.parameterIndex >= 0 and predicate.parameterIndex < core.Len(arguments) then
            return arguments[predicate.parameterIndex + 1]
        end
    else
        local invokedExpression = ast.SkipParentheses(callExpression:Expression())
        if ast.IsAccessExpression(invokedExpression) then
            return ast.SkipParentheses(invokedExpression:Expression())
        end
    end
    return nil
end

local function newFlowAccessName(c, symbol)
    local name = symbol.name
    local prefix = ast.InternalSymbolNamePrefix .. "#"
    if string.sub(name, 1, #prefix) == prefix then
        local at = string.find(name, "@", 1, true)
        return c.factory:NewPrivateIdentifier(string.sub(name, at + 1))
    end
    return c.factory:NewIdentifier(name)
end

function Checker:getFlowTypeInConstructor(symbol, constructor)
    local accessName = newFlowAccessName(self, symbol)
    local reference = self.factory:NewPropertyAccessExpression(self.factory:NewKeywordExpression(Kind.ThisKeyword), nil, accessName, NodeFlags.None)
    reference:Expression().parent = reference
    reference.parent = constructor
    reference:FlowNodeData().flowNode = constructor:AsConstructorDeclaration().returnFlowNode
    local flowType = self:getFlowTypeOfProperty(reference, symbol)
    if self.noImplicitAny and (flowType == self.autoType or flowType == self.autoArrayType) then
        self:error(symbol.valueDeclaration, diagnostics.Member_0_implicitly_has_an_1_type, self:symbolToString(symbol), self:TypeToString(flowType))
    end
    -- We don't infer a type if assignments are only null or undefined.
    if checker.everyType(flowType, function(t)
        return self:IsNullableType(t)
    end) then
        return nil
    end
    return self:convertAutoToAny(flowType)
end

function Checker:getFlowTypeInStaticBlocks(symbol, staticBlocks)
    local accessName = newFlowAccessName(self, symbol)
    for _, staticBlock in ipairs(staticBlocks or {}) do
        local reference = self.factory:NewPropertyAccessExpression(self.factory:NewKeywordExpression(Kind.ThisKeyword), nil, accessName, NodeFlags.None)
        reference:Expression().parent = reference
        reference.parent = staticBlock
        reference:FlowNodeData().flowNode = staticBlock:AsClassStaticBlockDeclaration().returnFlowNode
        local flowType = self:getFlowTypeOfProperty(reference, symbol)
        if self.noImplicitAny and (flowType == self.autoType or flowType == self.autoArrayType) then
            self:error(symbol.valueDeclaration, diagnostics.Member_0_implicitly_has_an_1_type, self:symbolToString(symbol), self:TypeToString(flowType))
        end
        -- We don't infer a type if assignments are only null or undefined.
        if not checker.everyType(flowType, function(t)
            return self:IsNullableType(t)
        end) then
            return self:convertAutoToAny(flowType)
        end
    end
    return nil
end

function Checker:isReachableFlowNode(flow)
    local f = self:getFlowState()
    local result = self:isReachableFlowNodeWorker(f, flow, false --[[noCacheCheck]])
    self:putFlowState(f)
    self.lastFlowNode = flow
    self.lastFlowNodeReachable = result
    return result
end

function Checker:isReachableFlowNodeWorker(f, flow, noCacheCheck)
    while true do
        if flow == self.lastFlowNode then
            return self.lastFlowNodeReachable
        end
        local flags = flow.flags
        if flags & FlowFlags.Shared ~= 0 then
            if not noCacheCheck and #f.reduceLabels == 0 then
                local reachable = self.flowNodeReachable[flow]
                if reachable ~= nil then
                    return reachable
                end
                reachable = self:isReachableFlowNodeWorker(f, flow, true --[[noCacheCheck]])
                self.flowNodeReachable[flow] = reachable
                return reachable
            end
            noCacheCheck = false
        end
        if flags & (FlowFlags.Assignment | FlowFlags.Condition | FlowFlags.ArrayMutation) ~= 0 then
            flow = flow.antecedent
        elseif flags & FlowFlags.Call ~= 0 then
            local signature = self:getEffectsSignature(flow.node)
            if signature ~= nil then
                local predicate = self:getTypePredicateOfSignature(signature)
                if predicate ~= nil and predicate.kind == TypePredicateKind.AssertsIdentifier and predicate.t == nil then
                    local arguments = flow.node:Arguments()
                    if predicate.parameterIndex >= 0 and predicate.parameterIndex < core.Len(arguments) and self:isFalseExpression(arguments[predicate.parameterIndex + 1]) then
                        return false
                    end
                end
                if self:getReturnTypeOfSignature(signature).flags & TypeFlags.Never ~= 0 then
                    return false
                end
            end
            flow = flow.antecedent
        elseif flags & FlowFlags.BranchLabel ~= 0 then
            -- A branching point is reachable if any branch is reachable.
            local list = checker.getBranchLabelAntecedents(flow, f.reduceLabels)
            while list ~= nil do
                if self:isReachableFlowNodeWorker(f, list.flow, false --[[noCacheCheck]]) then
                    return true
                end
                list = list.next
            end
            return false
        elseif flags & FlowFlags.LoopLabel ~= 0 then
            if flow.antecedents == nil then
                return false
            end
            -- A loop is reachable if the control flow path that leads to the top is reachable.
            flow = flow.antecedents.flow
        elseif flags & FlowFlags.SwitchClause ~= 0 then
            -- The control flow path representing an unmatched value in a switch statement with
            -- no default clause is unreachable if the switch statement is exhaustive.
            local data = flow.node:AsFlowSwitchClauseData()
            if data.clauseStart == data.clauseEnd and self:isExhaustiveSwitchStatement(data.switchStatement) then
                return false
            end
            flow = flow.antecedent
        elseif flags & FlowFlags.ReduceLabel ~= 0 then
            -- Cache is unreliable once we start adjusting labels
            self.lastFlowNode = nil
            f.reduceLabels[#f.reduceLabels + 1] = flow.node:AsFlowReduceLabelData()
            local result = self:isReachableFlowNodeWorker(f, flow.antecedent, false --[[noCacheCheck]])
            f.reduceLabels[#f.reduceLabels] = nil
            return result
        else
            return flags & FlowFlags.Unreachable == 0
        end
    end
end

function Checker:isFalseExpression(expr)
    local node = ast.SkipParentheses(expr)
    if node.kind == Kind.FalseKeyword then
        return true
    end
    if ast.IsBinaryExpression(node) then
        local binary = node:AsBinaryExpression()
        return binary.operatorToken.kind == Kind.AmpersandAmpersandToken and (self:isFalseExpression(binary.left) or self:isFalseExpression(binary.right)) or
            binary.operatorToken.kind == Kind.BarBarToken and self:isFalseExpression(binary.left) and self:isFalseExpression(binary.right)
    end
    return false
end

-- Return true if the given flow node is preceded by a 'super(...)' call in every possible code path
-- leading to the node.
function Checker:isPostSuperFlowNode(flow, noCacheCheck)
    local f = self:getFlowState()
    local result = self:isPostSuperFlowNodeWorker(f, flow, noCacheCheck)
    self:putFlowState(f)
    return result
end

function Checker:isPostSuperFlowNodeWorker(f, flow, noCacheCheck)
    while true do
        local flags = flow.flags
        if flags & FlowFlags.Shared ~= 0 then
            if not noCacheCheck then
                local postSuper = self.flowNodePostSuper[flow]
                if postSuper ~= nil then
                    return postSuper
                end
                postSuper = self:isPostSuperFlowNodeWorker(f, flow, true --[[noCacheCheck]])
                self.flowNodePostSuper[flow] = postSuper
            end
            noCacheCheck = false
        end
        if flags & (FlowFlags.Assignment | FlowFlags.Condition | FlowFlags.ArrayMutation | FlowFlags.SwitchClause) ~= 0 then
            flow = flow.antecedent
        elseif flags & FlowFlags.Call ~= 0 then
            if flow.node:Expression().kind == Kind.SuperKeyword then
                return true
            end
            flow = flow.antecedent
        elseif flags & FlowFlags.BranchLabel ~= 0 then
            local list = checker.getBranchLabelAntecedents(flow, f.reduceLabels)
            while list ~= nil do
                if not self:isPostSuperFlowNodeWorker(f, list.flow, false --[[noCacheCheck]]) then
                    return false
                end
                list = list.next
            end
            return true
        elseif flags & FlowFlags.LoopLabel ~= 0 then
            -- A loop is post-super if the control flow path that leads to the top is post-super.
            flow = flow.antecedents.flow
        elseif flags & FlowFlags.ReduceLabel ~= 0 then
            f.reduceLabels[#f.reduceLabels + 1] = flow.node:AsFlowReduceLabelData()
            local result = self:isPostSuperFlowNodeWorker(f, flow.antecedent, false --[[noCacheCheck]])
            f.reduceLabels[#f.reduceLabels] = nil
            return result
        else
            -- Unreachable nodes are considered post-super to silence errors
            return flags & FlowFlags.Unreachable ~= 0
        end
    end
end

-- Check if a parameter, catch variable, or mutable local variable is definitely assigned anywhere
function Checker:isSymbolAssignedDefinitely(symbol)
    self:ensureAssignmentsMarked(symbol)
    return self.markedAssignmentSymbolLinks:Get(symbol).hasDefiniteAssignment
end

-- Check if a parameter, catch variable, or mutable local variable is assigned anywhere
function Checker:isSymbolAssigned(symbol)
    self:ensureAssignmentsMarked(symbol)
    return self.markedAssignmentSymbolLinks:Get(symbol).lastAssignmentPos ~= 0
end

-- Return true if there are no assignments to the given symbol or if the given location
-- is past the last assignment to the symbol.
function Checker:isPastLastAssignment(symbol, location)
    self:ensureAssignmentsMarked(symbol)
    local lastAssignmentPos = self.markedAssignmentSymbolLinks:Get(symbol).lastAssignmentPos
    return lastAssignmentPos == 0 or location ~= nil and lastAssignmentPos < location:Pos()
end

function Checker:ensureAssignmentsMarked(symbol)
    if self.markedAssignmentSymbolLinks:Get(symbol).lastAssignmentPos ~= 0 then
        return
    end
    local parent = ast.FindAncestor(symbol.valueDeclaration, function(n)
        return ast.IsFunctionOrSourceFile(n)
    end)
    if parent == nil then
        return
    end
    local links = self.nodeLinks:Get(parent)
    if links.flags & checker.NodeCheckFlags.AssignmentsMarked == 0 then
        links.flags = links.flags | checker.NodeCheckFlags.AssignmentsMarked
        if not self:hasParentWithAssignmentsMarked(parent) then
            self.markNodeAssignments(parent)
        end
    end
end

function Checker:hasParentWithAssignmentsMarked(node)
    return ast.FindAncestor(node.parent, function(node)
        return ast.IsFunctionOrSourceFile(node) and self.nodeLinks:Get(node).flags & checker.NodeCheckFlags.AssignmentsMarked ~= 0
    end) ~= nil
end

local maxInt32 = 2147483647

-- For all assignments within the given root node, record the last assignment source position for all
-- referenced parameters and mutable local variables. When assignments occur in nested functions  or
-- references occur in export specifiers, record math.MaxInt32 as the assignment position. When
-- assignments occur in compound statements, record the ending source position of the compound statement
-- as the assignment position (this is more conservative than full control flow analysis, but requires
-- only a single walk over the AST).
function Checker:markNodeAssignmentsWorker(node)
    local kind = node.kind
    if kind == Kind.Identifier then
        local assignmentKind = checker.getAssignmentTargetKind(node)
        if assignmentKind ~= AssignmentKind.None then
            local symbol = self:getResolvedSymbol(node)
            if self:isParameterOrMutableLocalVariable(symbol) then
                local links = self.markedAssignmentSymbolLinks:Get(symbol)
                local pos = links.lastAssignmentPos
                if pos == 0 or pos ~= maxInt32 then
                    local referencingFunction = ast.FindAncestor(node, function(n)
                        return ast.IsFunctionOrSourceFile(n)
                    end)
                    local declaringFunction = ast.FindAncestor(symbol.valueDeclaration, function(n)
                        return ast.IsFunctionOrSourceFile(n)
                    end)
                    if referencingFunction == declaringFunction then
                        links.lastAssignmentPos = self:extendAssignmentPosition(node, symbol.valueDeclaration)
                    else
                        links.lastAssignmentPos = maxInt32
                    end
                end
                if assignmentKind == AssignmentKind.Definite then
                    links.hasDefiniteAssignment = true
                end
            end
        end
        return false
    elseif kind == Kind.ExportSpecifier then
        local exportDeclaration = node:AsExportSpecifier().parent.parent:AsExportDeclaration()
        local name = node:PropertyNameOrName()
        if not node:IsTypeOnly() and not exportDeclaration.isTypeOnly and exportDeclaration.moduleSpecifier == nil and not ast.IsStringLiteral(name) then
            local symbol = self:resolveEntityName(name, SymbolFlags.Value, true --[[ignoreErrors]], true --[[dontResolveAlias]], nil)
            if symbol ~= nil and self:isParameterOrMutableLocalVariable(symbol) then
                local links = self.markedAssignmentSymbolLinks:Get(symbol)
                links.lastAssignmentPos = maxInt32
            end
        end
        return false
    elseif kind == Kind.InterfaceDeclaration or
        kind == Kind.TypeAliasDeclaration or
        kind == Kind.JSTypeAliasDeclaration or
        kind == Kind.EnumDeclaration then
        return false
    end
    if ast.IsTypeNode(node) then
        return false
    end
    return node:ForEachChild(self.markNodeAssignments)
end

-- Extend the position of the given assignment target node to the end of any intervening variable statement,
-- expression statement, compound statement, or class declaration occurring between the node and the given
-- declaration node.
local extendAssignmentPositionKinds = ast.kindSet(Kind.VariableStatement, Kind.ExpressionStatement, Kind.IfStatement, Kind.DoStatement, Kind.WhileStatement,
    Kind.ForStatement, Kind.ForInStatement, Kind.ForOfStatement, Kind.WithStatement, Kind.SwitchStatement,
    Kind.TryStatement, Kind.ClassDeclaration)

function Checker:extendAssignmentPosition(node, declaration)
    local pos = node:Pos()
    while node ~= nil and node:Pos() > declaration:Pos() do
        if extendAssignmentPositionKinds[node.kind] then
            pos = node:End()
        end
        node = node.parent
    end
    return pos
end
