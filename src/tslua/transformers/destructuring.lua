local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local SubtreeFacts = ast.SubtreeFacts
local FlattenLevel = transformers.FlattenLevel

-- CreateAssignmentCallback is a callback used to create custom assignment expressions during destructuring flattening.
-- When provided, the target will always be an Identifier, and the callback can wrap the assignment with additional logic
-- (e.g., export expressions in CJS modules or namespace member assignments).
-- Signature: function(name, value, location) -> Expression (location is a core.TextRange).

-- FlattenDestructuringAssignment flattens a destructuring assignment expression into a sequence of
-- individual property/element access assignments. Supports custom assignment callbacks for module
-- export or namespace member expressions.
function transformers.FlattenDestructuringAssignment(
    tx,
    node, -- VariableDeclaration | DestructuringAssignment
    needsValue,
    level,
    createAssignmentCallback
)
    local f = transformers.newFlattener(tx, level)
    f.createAssignmentCallback = createAssignmentCallback
    f.hoistTempVariables = true
    -- Assignment mode callbacks
    f.emitBindingOrAssignment = transformers.flattener.emitAssignment
    f.createArrayBindingOrAssignmentPattern = transformers.flattener.createArrayAssignmentPattern
    f.createObjectBindingOrAssignmentPattern = transformers.flattener.createObjectAssignmentPattern
    f.createArrayBindingOrAssignmentElement = transformers.flattener.createArrayAssignmentElement
    return f:flattenDestructuringAssignment(node, needsValue)
end

-- pendingDecl tracks a pending variable declaration during binding flattening:
--   { pendingExpressions = []Node or nil, name, value, location = core.TextRange, original }

-- FlattenDestructuringBinding flattens a binding pattern in a variable declaration or parameter
-- into individual variable declarations. Returns a single VariableDeclaration, a SyntaxList of
-- declarations, or nil.
function transformers.FlattenDestructuringBinding(
    tx,
    node, -- VariableDeclaration | ParameterDeclaration | BindingElement
    rval,
    level,
    hoistTempVariables,
    skipInitializer
)
    local f = transformers.newFlattener(tx, level)
    f.hoistTempVariables = hoistTempVariables
    -- Binding mode callbacks
    f.emitBindingOrAssignment = transformers.flattener.emitBinding
    f.createArrayBindingOrAssignmentPattern = transformers.flattener.createArrayBindingPattern
    f.createObjectBindingOrAssignmentPattern = transformers.flattener.createObjectBindingPattern
    f.createArrayBindingOrAssignmentElement = transformers.flattener.createArrayBindingElement
    return f:flattenDestructuringBinding(node, rval, skipInitializer)
end

-- flattener encapsulates the state and logic for flattening destructuring patterns.
-- It is equivalent to TypeScript's FlattenContext in destructuring.ts.
local flattener = {}
flattener.__index = flattener
transformers.flattener = flattener

function transformers.newFlattener(tx, level)
    return setmetatable({
        tx = tx,
        level = level,
        createAssignmentCallback = nil,
        -- State
        expressions = nil,
        declarations = {},
        hasTransformedPriorElement = false,
        hoistTempVariables = false,
        -- Mode callbacks (set by FlattenDestructuringAssignment or FlattenDestructuringBinding)
        emitBindingOrAssignment = nil,
        createArrayBindingOrAssignmentPattern = nil,
        createObjectBindingOrAssignmentPattern = nil,
        createArrayBindingOrAssignmentElement = nil,
    }, flattener)
end

-- --- Assignment mode callbacks ---

function flattener:createArrayAssignmentPattern(elements)
    return self.tx:Factory():NewArrayLiteralExpression(self.tx:Factory():NewNodeList(elements), false)
end

function flattener:createObjectAssignmentPattern(elements)
    return self.tx:Factory():NewObjectLiteralExpression(self.tx:Factory():NewNodeList(elements), false)
end

function flattener:createArrayAssignmentElement(expr)
    return expr
end

function flattener:emitAssignment(target, value, location, original)
    local expression
    if self.createAssignmentCallback ~= nil and ast.IsIdentifier(target) then
        expression = self.createAssignmentCallback(target, value, location)
    else
        expression = self.tx:Factory():NewAssignmentExpression(self.tx:Visitor():VisitNode(target), value)
        expression.loc = location
    end
    self.tx:EmitContext():SetOriginal(expression, original)
    self:emitExpression(expression)
end

-- --- Binding mode callbacks ---

function flattener:createArrayBindingPattern(elements)
    return self.tx:Factory():NewBindingPattern(Kind.ArrayBindingPattern, self.tx:Factory():NewNodeList(elements))
end

function flattener:createObjectBindingPattern(elements)
    return self.tx:Factory():NewBindingPattern(Kind.ObjectBindingPattern, self.tx:Factory():NewNodeList(elements))
end

function flattener:createArrayBindingElement(expr)
    return self.tx:Factory():NewBindingElement(nil, nil, expr, nil)
end

function flattener:emitBinding(target, value, location, original)
    if core.Len(self.expressions) > 0 then
        local exprs = core.AppendAll({}, self.expressions)
        exprs[#exprs + 1] = value
        value = self.tx:Factory():InlineExpressions(exprs)
        self.expressions = nil
    end
    self.declarations[#self.declarations + 1] = {
        pendingExpressions = nil,
        name = target,
        value = value,
        location = location,
        original = original,
    }
end

-- --- Shared helpers ---

function flattener:emitExpression(expr)
    self.expressions = core.Append(self.expressions, expr)
end

function flattener:ensureIdentifier(value, reuseIdentifierExpressions, location)
    if reuseIdentifierExpressions and ast.IsIdentifier(value) then
        return value
    end
    local temp = self.tx:Factory():NewTempVariable()
    if self.hoistTempVariables then
        self.tx:EmitContext():AddVariableDeclaration(temp)
        local assign = self.tx:Factory():NewAssignmentExpression(temp, value)
        assign.loc = location
        self:emitExpression(assign)
    else
        self.emitBindingOrAssignment(self, temp, value, location, nil)
    end
    return temp
end

function flattener:createDefaultValueCheck(value, defaultValue, location)
    value = self:ensureIdentifier(value, true, location)
    return self.tx:Factory():NewConditionalExpression(
        self.tx:Factory():NewTypeCheck(value, "undefined"),
        self.tx:Factory():NewToken(Kind.QuestionToken),
        defaultValue,
        self.tx:Factory():NewToken(Kind.ColonToken),
        value
    )
end

function flattener:createDestructuringPropertyAccess(value, propertyName)
    if ast.IsComputedPropertyName(propertyName) then
        local argumentExpression = self:ensureIdentifier(self.tx:Visitor():VisitNode(propertyName:Expression()), false, propertyName.loc)
        return self.tx:Factory():NewElementAccessExpression(value, nil, argumentExpression, ast.NodeFlags.None)
    elseif ast.IsStringOrNumericLiteralLike(propertyName) or ast.IsBigIntLiteral(propertyName) then
        local argumentExpression = propertyName:Clone(self.tx:Factory())
        return self.tx:Factory():NewElementAccessExpression(value, nil, argumentExpression, ast.NodeFlags.None)
    else
        local name = self.tx:Factory():NewIdentifier(propertyName:Text())
        return self.tx:Factory():NewPropertyAccessExpression(value, nil, name, ast.NodeFlags.None)
    end
end

-- --- Entry points ---

function flattener:flattenDestructuringAssignment(node, needsValue)
    local location = node.loc
    local value
    if ast.IsDestructuringAssignment(node) then
        value = node:AsBinaryExpression().right
        while ast.IsEmptyArrayLiteral(node:AsBinaryExpression().left) or ast.IsEmptyObjectLiteral(node:AsBinaryExpression().left) do
            if ast.IsDestructuringAssignment(value) then
                node = value
                location = node.loc
                value = node:AsBinaryExpression().right
            else
                return self.tx:Visitor():VisitNode(value)
            end
        end
    end

    if value ~= nil then
        value = self.tx:Visitor():VisitNode(value)
        if ast.IsIdentifier(value) and transformers.BindingOrAssignmentElementAssignsToName(node, value:Text()) or transformers.BindingOrAssignmentElementContainsNonLiteralComputedName(node) then
            value = self:ensureIdentifier(value, false, location)
        elseif needsValue then
            value = self:ensureIdentifier(value, true, location)
        elseif ast.NodeIsSynthesized(node) then
            location = value.loc
        end
    end

    self:flattenBindingOrAssignmentElement(node, value, location, ast.IsDestructuringAssignment(node))

    if value ~= nil and needsValue then
        if core.Len(self.expressions) == 0 then
            return value
        end
        self.expressions = core.Append(self.expressions, value)
    end

    local res = self.tx:Factory():InlineExpressions(self.expressions)
    if res ~= nil then
        return res
    end
    return self.tx:Factory():NewOmittedExpression()
end

function flattener:flattenDestructuringBinding(node, rval, skipInitializer)
    if ast.IsVariableDeclaration(node) then
        local initializer = transformers.GetInitializerOfBindingOrAssignmentElement(node)
        if initializer ~= nil and (ast.IsIdentifier(initializer) and transformers.BindingOrAssignmentElementAssignsToName(node, initializer:Text()) or transformers.BindingOrAssignmentElementContainsNonLiteralComputedName(node)) then
            initializer = self:ensureIdentifier(self.tx:Visitor():VisitNode(initializer), false, initializer.loc)
            node = self.tx:Factory():UpdateVariableDeclaration(node:AsVariableDeclaration(), node:Name(), nil, nil, initializer)
        end
    end

    self:flattenBindingOrAssignmentElement(node, rval, node.loc, skipInitializer)

    if core.Len(self.expressions) > 0 then
        local temp = self.tx:Factory():NewTempVariable()
        if self.hoistTempVariables then
            local value = self.tx:Factory():InlineExpressions(self.expressions)
            self.expressions = nil
            self.emitBindingOrAssignment(self, temp, value, core.NewTextRange(0, 0), nil)
        else
            self.tx:EmitContext():AddVariableDeclaration(temp)
            local last = self.declarations[#self.declarations]
            last.pendingExpressions = core.Append(last.pendingExpressions, self.tx:Factory():NewAssignmentExpression(temp, last.value))
            last.pendingExpressions = core.AppendAll(last.pendingExpressions, self.expressions)
            last.value = temp
        end
    end

    local decls = {}
    for _, pending in ipairs(self.declarations) do
        local expr = pending.value
        if core.Len(pending.pendingExpressions) > 0 then
            local exprs = core.AppendAll({}, pending.pendingExpressions)
            exprs[#exprs + 1] = pending.value
            expr = self.tx:Factory():InlineExpressions(exprs)
        end
        local decl = self.tx:Factory():NewVariableDeclaration(pending.name, nil, nil, expr)
        decl.loc = pending.location
        if pending.original ~= nil then
            self.tx:EmitContext():SetOriginal(decl, pending.original)
        end
        decls[#decls + 1] = decl
    end

    if #decls == 1 then
        return decls[1]
    end
    if #decls == 0 then
        return nil
    end
    return self.tx:Factory():NewSyntaxList(decls)
end

-- --- Core flattening ---

function flattener:flattenBindingOrAssignmentElement(element, value, location, skipInitializer)
    local bindingTarget = ast.GetTargetOfBindingOrAssignmentElement(element)
    if bindingTarget == nil then
        return
    end
    if not skipInitializer then
        local initializer = self.tx:Visitor():VisitNode(transformers.GetInitializerOfBindingOrAssignmentElement(element))
        if initializer ~= nil then
            if value ~= nil then
                value = self:createDefaultValueCheck(value, initializer, location)
                if not transformers.IsSimpleCopiableExpression(initializer) and (ast.IsBindingPattern(bindingTarget) or ast.IsAssignmentPattern(bindingTarget)) then
                    value = self:ensureIdentifier(value, true, location)
                end
            else
                value = initializer
            end
        elseif value == nil then
            value = self.tx:Factory():NewVoidZeroExpression()
        end
    end

    if transformers.isObjectBindingOrAssignmentPattern(bindingTarget) then
        self:flattenObjectBindingOrAssignmentPattern(element, bindingTarget, value, location)
    elseif transformers.isArrayBindingOrAssignmentPattern(bindingTarget) then
        self:flattenArrayBindingOrAssignmentPattern(element, bindingTarget, value, location)
    else
        self.emitBindingOrAssignment(self, bindingTarget, value, location, element)
    end
end

local restOrSpreadFacts = SubtreeFacts.SubtreeContainsRestOrSpread | SubtreeFacts.SubtreeContainsObjectRestOrSpread

function flattener:flattenObjectBindingOrAssignmentPattern(parent, pattern, value, location)
    local elements = ast.GetElementsOfBindingOrAssignmentPattern(pattern)
    local numElements = core.Len(elements)
    if numElements ~= 1 then
        local reuseIdentifierExpressions = not ast.IsDeclarationBindingElement(parent) or numElements ~= 0
        value = self:ensureIdentifier(value, reuseIdentifierExpressions, location)
    end
    local bindingElements
    local computedTempVariables
    for i0, element in ipairs(elements or {}) do
        local i = i0 - 1
        if ast.GetRestIndicatorOfBindingOrAssignmentElement(element) == nil then
            local propertyName = ast.TryGetPropertyNameOfBindingOrAssignmentElement(element)
            if self.level >= FlattenLevel.ObjectRest and
                element:SubtreeFacts() & restOrSpreadFacts == 0 and
                ast.GetTargetOfBindingOrAssignmentElement(element):SubtreeFacts() & restOrSpreadFacts == 0 and
                not ast.IsComputedPropertyName(propertyName) then
                bindingElements = core.Append(bindingElements, self.tx:Visitor():VisitNode(element))
            else
                if core.Len(bindingElements) > 0 then
                    self.emitBindingOrAssignment(self, self.createObjectBindingOrAssignmentPattern(self, bindingElements), value, location, pattern)
                    bindingElements = nil
                end
                local rhsValue = self:createDestructuringPropertyAccess(value, propertyName)
                if ast.IsComputedPropertyName(propertyName) then
                    computedTempVariables = core.Append(computedTempVariables, rhsValue:AsElementAccessExpression().argumentExpression)
                end
                self:flattenBindingOrAssignmentElement(element, rhsValue, element.loc, false)
            end
        elseif i == numElements - 1 then
            if core.Len(bindingElements) > 0 then
                self.emitBindingOrAssignment(self, self.createObjectBindingOrAssignmentPattern(self, bindingElements), value, location, pattern)
                bindingElements = nil
            end
            local rhsValue = self.tx:Factory():NewRestHelper(value, elements, computedTempVariables, pattern.loc)
            self:flattenBindingOrAssignmentElement(element, rhsValue, element.loc, false)
        end
    end
    if core.Len(bindingElements) > 0 then
        self.emitBindingOrAssignment(self, self.createObjectBindingOrAssignmentPattern(self, bindingElements), value, location, pattern)
    end
end

-- restIdElemPair: { id, element }

function flattener:flattenArrayBindingOrAssignmentPattern(parent, pattern, value, location)
    local elements = ast.GetElementsOfBindingOrAssignmentPattern(pattern)
    local numElements = core.Len(elements)
    if numElements ~= 1 and (self.level < FlattenLevel.ObjectRest or numElements == 0) or core.Every(elements, ast.IsOmittedExpression) then
        local reuseIdentifierExpressions = not ast.IsDeclarationBindingElement(parent) or numElements ~= 0
        value = self:ensureIdentifier(value, reuseIdentifierExpressions, location)
    end
    local bindingElements
    local restContainingElements
    for i0, element in ipairs(elements or {}) do
        local i = i0 - 1
        if self.level >= FlattenLevel.ObjectRest then
            if element:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 or self.hasTransformedPriorElement and not transformers.isSimpleBindingOrAssignmentElement(element) then
                self.hasTransformedPriorElement = true
                local temp = self.tx:Factory():NewTempVariable()
                if self.hoistTempVariables then
                    self.tx:EmitContext():AddVariableDeclaration(temp)
                end
                restContainingElements = core.Append(restContainingElements, { id = temp, element = element })
                bindingElements = core.Append(bindingElements, self.createArrayBindingOrAssignmentElement(self, temp))
            else
                bindingElements = core.Append(bindingElements, element)
            end
        elseif ast.IsOmittedExpression(element) then
            goto continue
        elseif ast.GetRestIndicatorOfBindingOrAssignmentElement(element) == nil then
            local rhsValue = self.tx:Factory():NewElementAccessExpression(value, nil, self.tx:Factory():NewNumericLiteral(string.format("%d", i), ast.TokenFlags.None), ast.NodeFlags.None)
            self:flattenBindingOrAssignmentElement(element, rhsValue, element.loc, false)
        elseif i == numElements - 1 then
            local rhsValue = self.tx:Factory():NewArraySliceCall(value, i)
            self:flattenBindingOrAssignmentElement(element, rhsValue, element.loc, false)
        end
        ::continue::
    end
    if core.Len(bindingElements) > 0 then
        self.emitBindingOrAssignment(self, self.createArrayBindingOrAssignmentPattern(self, bindingElements), value, location, pattern)
    end
    if core.Len(restContainingElements) > 0 then
        for _, pair in ipairs(restContainingElements) do
            self:flattenBindingOrAssignmentElement(pair.element, pair.id, pair.element.loc, false)
        end
    end
end

-- --- Exported helper functions ---

-- BindingOrAssignmentElementAssignsToName checks if any target in a binding/assignment pattern assigns to the given name.
function transformers.BindingOrAssignmentElementAssignsToName(element, name)
    local target = ast.GetTargetOfBindingOrAssignmentElement(element)
    if target == nil then
        return false
    end
    if ast.IsBindingPattern(target) or ast.IsAssignmentPattern(target) then
        return transformers.bindingOrAssignmentPatternAssignsToName(target, name)
    elseif ast.IsIdentifier(target) then
        return target:Text() == name
    end
    return false
end

function transformers.bindingOrAssignmentPatternAssignsToName(pattern, name)
    local elements = ast.GetElementsOfBindingOrAssignmentPattern(pattern)
    for _, element in ipairs(elements or {}) do
        if transformers.BindingOrAssignmentElementAssignsToName(element, name) then
            return true
        end
    end
    return false
end

-- BindingOrAssignmentElementContainsNonLiteralComputedName checks if any element has a non-literal computed property name.
function transformers.BindingOrAssignmentElementContainsNonLiteralComputedName(element)
    local propertyName = ast.TryGetPropertyNameOfBindingOrAssignmentElement(element)
    if propertyName ~= nil and ast.IsComputedPropertyName(propertyName) and not ast.IsLiteralExpression(propertyName:Expression()) then
        return true
    end
    local target = ast.GetTargetOfBindingOrAssignmentElement(element)
    return target ~= nil and (ast.IsBindingPattern(target) or ast.IsAssignmentPattern(target)) and transformers.bindingOrAssignmentPatternContainsNonLiteralComputedName(target)
end

function transformers.bindingOrAssignmentPatternContainsNonLiteralComputedName(pattern)
    local elements = ast.GetElementsOfBindingOrAssignmentPattern(pattern)
    return core.Some(elements, transformers.BindingOrAssignmentElementContainsNonLiteralComputedName)
end

-- GetInitializerOfBindingOrAssignmentElement returns the initializer/default value of a binding or assignment element.
function transformers.GetInitializerOfBindingOrAssignmentElement(bindingElement)
    if bindingElement == nil then
        return nil
    end
    if ast.IsDeclarationBindingElement(bindingElement) then
        return bindingElement:Initializer()
    end
    if ast.IsPropertyAssignment(bindingElement) then
        local initializer = bindingElement:Initializer()
        if ast.IsAssignmentExpression(initializer, true) then
            return initializer:AsBinaryExpression().right
        end
        return nil
    end
    if ast.IsShorthandPropertyAssignment(bindingElement) then
        return bindingElement:AsShorthandPropertyAssignment().objectAssignmentInitializer
    end
    if ast.IsAssignmentExpression(bindingElement, true) then
        return bindingElement:AsBinaryExpression().right
    end
    if ast.IsSpreadElement(bindingElement) then
        return transformers.GetInitializerOfBindingOrAssignmentElement(bindingElement:Expression())
    end
    return nil
end

function transformers.isObjectBindingOrAssignmentPattern(node)
    return node ~= nil and (node.kind == Kind.ObjectBindingPattern or node.kind == Kind.ObjectLiteralExpression)
end

function transformers.isArrayBindingOrAssignmentPattern(node)
    return node ~= nil and (node.kind == Kind.ArrayBindingPattern or node.kind == Kind.ArrayLiteralExpression)
end

function transformers.isSimpleBindingOrAssignmentElement(element)
    local target = ast.GetTargetOfBindingOrAssignmentElement(element)
    if target == nil or ast.IsOmittedExpression(target) then
        return true
    end
    local propertyName = ast.TryGetPropertyNameOfBindingOrAssignmentElement(element)
    if propertyName ~= nil and not ast.IsPropertyNameLiteral(propertyName) then
        return false
    end
    local initializer = transformers.GetInitializerOfBindingOrAssignmentElement(element)
    if initializer ~= nil and not transformers.IsSimpleInlineableExpression(initializer) then
        return false
    end
    if ast.IsBindingPattern(target) or ast.IsAssignmentPattern(target) then
        return core.Every(ast.GetElementsOfBindingOrAssignmentPattern(target), transformers.isSimpleBindingOrAssignmentElement)
    end
    return ast.IsIdentifier(target)
end
