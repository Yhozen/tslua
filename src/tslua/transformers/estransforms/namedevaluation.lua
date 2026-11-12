local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")

local Kind = ast.Kind
local TokenFlags = ast.TokenFlags
local OEK = ast.OuterExpressionKinds

--[[
 * Gets whether a node is a `static {}` block containing only a single call to the `__setFunctionName` helper where that
 * call's second argument is the value stored in the `assignedName` property of the block's `EmitNode`.
 * @internal
]]
function estransforms.isClassNamedEvaluationHelperBlock(emitContext, node)
    if not ast.IsClassStaticBlockDeclaration(node) or core.Len(node:AsClassStaticBlockDeclaration().body:Statements()) ~= 1 then
        return false
    end

    local statement = node:AsClassStaticBlockDeclaration().body:Statements()[1]
    if ast.IsExpressionStatement(statement) then
        local expression = statement:Expression()
        if emitContext:IsCallToHelper(expression, "__setFunctionName") then
            local arguments = expression:AsCallExpression().arguments
            return #arguments.nodes >= 2 and
                arguments.nodes[2] == emitContext:AssignedName(node:AsNode())
        end
    end
    return false
end

--[[
 * Gets whether a `ClassLikeDeclaration` has a `static {}` block containing only a single call to the
 * `__setFunctionName` helper.
 * @internal
]]
function estransforms.classHasExplicitlyAssignedName(emitContext, node)
    local assignedName = emitContext:AssignedName(node)
    if assignedName ~= nil then
        for _, member in ipairs(node:Members() or {}) do
            if estransforms.isClassNamedEvaluationHelperBlock(emitContext, member) then
                return true
            end
        end
    end
    return false
end

--[[
 * Gets whether a `ClassLikeDeclaration` has a declared name or contains a `static {}` block containing only a single
 * call to the `__setFunctionName` helper.
 * @internal
]]
function estransforms.classHasDeclaredOrExplicitlyAssignedName(emitContext, node)
    return node:Name() ~= nil or estransforms.classHasExplicitlyAssignedName(emitContext, node)
end

-- Indicates whether an expression is an anonymous function definition.
--
-- See https://tc39.es/ecma262/#sec-isanonymousfunctiondefinition
function estransforms.isAnonymousFunctionDefinition(emitContext, node, cb)
    node = ast.SkipOuterExpressions(node, OEK.OEKAll)
    local k = node.kind
    if k == Kind.ClassExpression then
        if estransforms.classHasDeclaredOrExplicitlyAssignedName(emitContext, node) then
            return false
        end
    elseif k == Kind.FunctionExpression then
        if node:AsFunctionExpression():Name() ~= nil then
            return false
        end
    elseif k == Kind.ArrowFunction then
        -- break
    else
        return false
    end
    if cb ~= nil then
        return cb(node)
    end
    return true
end

function estransforms.isNamedEvaluation(emitContext, node)
    return estransforms.isNamedEvaluationAnd(emitContext, node, nil)
end

function estransforms.isNamedEvaluationAnd(emitContext, node, cb)
    if not ast.IsNamedEvaluationSource(node) then
        return false
    end
    local k = node.kind
    if k == Kind.ShorthandPropertyAssignment then
        return estransforms.isAnonymousFunctionDefinition(emitContext, node:AsShorthandPropertyAssignment().objectAssignmentInitializer, cb)
    elseif k == Kind.PropertyAssignment or k == Kind.VariableDeclaration or k == Kind.Parameter or k == Kind.BindingElement or k == Kind.PropertyDeclaration then
        return estransforms.isAnonymousFunctionDefinition(emitContext, node:Initializer(), cb)
    elseif k == Kind.BinaryExpression then
        return estransforms.isAnonymousFunctionDefinition(emitContext, node:AsBinaryExpression().right, cb)
    elseif k == Kind.ExportAssignment then
        return estransforms.isAnonymousFunctionDefinition(emitContext, node:Expression(), cb)
    else
        debug.Fail("Unhandled case in isNamedEvaluation")
        return false
    end
end

-- Gets a string literal to use as the assigned name of an anonymous class or function declaration.
function estransforms.getAssignedNameOfIdentifier(emitContext, name, expression)
    local original = emitContext:MostOriginal(ast.SkipOuterExpressions(expression, OEK.OEKAll))
    if (ast.IsClassDeclaration(original) or ast.IsFunctionDeclaration(original)) and
        original:Name() == nil and ast.HasSyntacticModifier(original, ast.ModifierFlags.Default) then
        return emitContext.factory:NewStringLiteral("default", TokenFlags.None)
    end
    return emitContext.factory:NewStringLiteralFromNode(name)
end

-- Returns assignedName, updatedName.
function estransforms.getAssignedNameOfPropertyName(emitContext, name, assignedNameText)
    local factory = emitContext.factory
    if #assignedNameText > 0 then
        local assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
        return assignedName, name
    end

    if ast.IsPropertyNameLiteral(name) or ast.IsPrivateIdentifier(name) then
        local assignedName = factory:NewStringLiteralFromNode(name)
        return assignedName, name
    end

    local expression = name:Expression()
    if ast.IsPropertyNameLiteral(expression) and not ast.IsIdentifier(expression) then
        local assignedName = factory:NewStringLiteralFromNode(expression)
        return assignedName, name
    end

    debug.Assert(ast.IsComputedPropertyName(name), "Expected computed property name")

    local assignedName = factory:NewGeneratedNameForNode(name)
    emitContext:AddVariableDeclaration(assignedName)

    local key = factory:NewPropKeyHelper(expression)
    local assignment = factory:NewAssignmentExpression(assignedName, key)
    local updatedName = factory:UpdateComputedPropertyName(name:AsComputedPropertyName(), assignment)
    return assignedName, updatedName
end

-- Creates a class `static {}` block used to dynamically set the name of a class.
--
-- The assignedName parameter is the expression used to resolve the assigned name at runtime. This expression should not produce
-- side effects.
-- The thisExpression parameter overrides the expression to use for the actual `this` reference. This can be used to provide an
-- expression that has already had its `EmitFlags` set or may have been tracked to prevent substitution.
function estransforms.createClassNamedEvaluationHelperBlock(emitContext, assignedName, thisExpression)
    -- produces:
    --
    --  static { __setFunctionName(this, "C"); }
    --

    if thisExpression == nil then
        thisExpression = emitContext.factory:NewThisExpression()
    end

    local factory = emitContext.factory
    local expression = factory:NewSetFunctionNameHelper(thisExpression, assignedName, "")
    local statement = factory:NewExpressionStatement(expression)
    local body = factory:NewBlock(factory:NewNodeList({ statement }), false)
    local block = factory:NewClassStaticBlockDeclaration(nil, body)

    -- We use `emitNode.assignedName` to indicate this is a NamedEvaluation helper block
    -- and to stash the expression used to resolve the assigned name.
    emitContext:SetAssignedName(block, assignedName)
    return block:AsNode()
end

-- Injects a class `static {}` block used to dynamically set the name of a class, if one does not already exist.
function estransforms.injectClassNamedEvaluationHelperBlockIfMissing(emitContext, node, assignedName, thisExpression)
    -- given:
    --
    --  let C = class {
    --  };
    --
    -- produces:
    --
    --  let C = class {
    --      static { __setFunctionName(this, "C"); }
    --  };

    -- NOTE: If the class has a `_classThis` assignment block, this helper will be injected after that block.

    if estransforms.classHasExplicitlyAssignedName(emitContext, node) then
        return node
    end

    local factory = emitContext.factory
    local namedEvaluationBlock = estransforms.createClassNamedEvaluationHelperBlock(emitContext, assignedName, thisExpression)
    if node:Name() ~= nil then
        emitContext:SetSourceMapRange(namedEvaluationBlock:Body():Statements()[1], node:Name().loc)
    end

    local nodeMembers = node:Members() or {}
    local insertionIndex = core.FindIndex(nodeMembers, function(n)
        return estransforms.isClassThisAssignmentBlock(emitContext, n)
    end) + 1

    local members = {}
    for i = 1, insertionIndex do
        members[#members + 1] = nodeMembers[i]
    end
    members[#members + 1] = namedEvaluationBlock
    for i = insertionIndex + 1, #nodeMembers do
        members[#members + 1] = nodeMembers[i]
    end
    local membersList = factory:NewNodeList(members)
    membersList.loc = node:MemberList().loc

    local oldNode = node
    if ast.IsClassDeclaration(node) then
        node = factory:UpdateClassDeclaration(
            node:AsClassDeclaration(),
            node:Modifiers(),
            node:Name(),
            node:TypeParameterList(),
            node:AsClassDeclaration().heritageClauses,
            membersList
        )
    else
        node = factory:UpdateClassExpression(
            node:AsClassExpression(),
            node:Modifiers(),
            node:Name(),
            node:TypeParameterList(),
            node:AsClassExpression().heritageClauses,
            membersList
        )
    end

    emitContext:SetAssignedName(node, assignedName)

    -- Transfer ClassThis from old to new node, since UpdateClassExpression creates
    -- a new node that won't have ClassThis set on it.
    local ct = emitContext:ClassThis(oldNode)
    if ct ~= nil then
        emitContext:SetClassThis(node, ct)
    end

    return node
end

function estransforms.finishTransformNamedEvaluation(emitContext, expression, assignedName, ignoreEmptyStringLiteral)
    if ignoreEmptyStringLiteral and ast.IsStringLiteral(assignedName) and #assignedName:Text() == 0 then
        return expression
    end

    local factory = emitContext.factory
    local innerExpression = ast.SkipOuterExpressions(expression, OEK.OEKAll)

    local updatedExpression
    if ast.IsClassExpression(innerExpression) then
        updatedExpression = estransforms.injectClassNamedEvaluationHelperBlockIfMissing(emitContext, innerExpression, assignedName, nil)
    else
        updatedExpression = factory:NewSetFunctionNameHelper(innerExpression, assignedName, "")
    end

    return factory:RestoreOuterExpressions(expression, updatedExpression, OEK.OEKAll)
end

function estransforms.transformNamedEvaluationOfPropertyAssignment(context, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 13.2.5.5 RS: PropertyDefinitionEvaluation
    --   PropertyAssignment : PropertyName `:` AssignmentExpression
    --     ...
    --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and _isProtoSetter_ is *false*, then
    --        a. Let _popValue_ be ? NamedEvaluation of |AssignmentExpression| with argument _propKey_.
    --     ...

    local factory = context.factory
    local assignedName, name = estransforms.getAssignedNameOfPropertyName(context, node:Name(), assignedNameText)
    local initializer = estransforms.finishTransformNamedEvaluation(context, node.initializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdatePropertyAssignment(node, nil, name, nil, nil, initializer)
end

function estransforms.transformNamedEvaluationOfShorthandAssignmentProperty(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 13.15.5.3 RS: PropertyDestructuringAssignmentEvaluation
    --   AssignmentProperty : IdentifierReference Initializer?
    --     ...
    --     4. If |Initializer?| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _P_.
    --     ...

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    else
        assignedName = estransforms.getAssignedNameOfIdentifier(emitContext, node:Name(), node.objectAssignmentInitializer)
    end
    local objectAssignmentInitializer = estransforms.finishTransformNamedEvaluation(emitContext, node.objectAssignmentInitializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateShorthandPropertyAssignment(
        node,
        nil, -- modifiers
        node:Name(),
        nil, -- postfixToken
        nil, -- typeNode
        node.equalsToken,
        objectAssignmentInitializer
    )
end

function estransforms.transformNamedEvaluationOfVariableDeclaration(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 14.3.1.2 RS: Evaluation
    --   LexicalBinding : BindingIdentifier Initializer
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.2.1 RS: Evaluation
    --   VariableDeclaration : BindingIdentifier Initializer
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    else
        assignedName = estransforms.getAssignedNameOfIdentifier(emitContext, node:Name(), node.initializer)
    end
    local initializer = estransforms.finishTransformNamedEvaluation(emitContext, node.initializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateVariableDeclaration(
        node,
        node:Name(),
        nil, -- exclamationToken
        nil, -- typeNode
        initializer
    )
end

function estransforms.transformNamedEvaluationOfParameterDeclaration(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 8.6.3 RS: IteratorBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     5. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.3.3 RS: KeyedBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     4. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    else
        assignedName = estransforms.getAssignedNameOfIdentifier(emitContext, node:Name(), node.initializer)
    end
    local initializer = estransforms.finishTransformNamedEvaluation(emitContext, node.initializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateParameterDeclaration(
        node,
        nil, -- modifiers
        node.dotDotDotToken,
        node:Name(),
        nil, -- questionToken
        nil, -- typeNode
        initializer
    )
end

function estransforms.transformNamedEvaluationOfBindingElement(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 8.6.3 RS: IteratorBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     5. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.3.3 RS: KeyedBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     4. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    else
        assignedName = estransforms.getAssignedNameOfIdentifier(emitContext, node:Name(), node.initializer)
    end
    local initializer = estransforms.finishTransformNamedEvaluation(emitContext, node.initializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateBindingElement(
        node,
        node.dotDotDotToken,
        node.propertyName,
        node:Name(),
        initializer
    )
end

function estransforms.transformNamedEvaluationOfPropertyDeclaration(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 10.2.1.3 RS: EvaluateBody
    --   Initializer : `=` AssignmentExpression
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _functionObject_.[[ClassFieldInitializerName]].
    --     ...

    local factory = emitContext.factory
    local assignedName, name = estransforms.getAssignedNameOfPropertyName(emitContext, node:Name(), assignedNameText)
    local initializer = estransforms.finishTransformNamedEvaluation(emitContext, node.initializer, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdatePropertyDeclaration(
        node,
        node:Modifiers(),
        name,
        nil, -- postfixToken
        nil, -- typeNode
        initializer
    )
end

function estransforms.transformNamedEvaluationOfAssignmentExpression(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 13.15.2 RS: Evaluation
    --   AssignmentExpression : LeftHandSideExpression `=` AssignmentExpression
    --     1. If |LeftHandSideExpression| is neither an |ObjectLiteral| nor an |ArrayLiteral|, then
    --        a. Let _lref_ be ? Evaluation of |LeftHandSideExpression|.
    --        b. If IsAnonymousFunctionDefinition(|AssignmentExpression|) and IsIdentifierRef of |LeftHandSideExpression| are both *true*, then
    --           i. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
    --     ...
    --
    --   AssignmentExpression : LeftHandSideExpression `&&=` AssignmentExpression
    --     ...
    --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
    --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
    --     ...
    --
    --   AssignmentExpression : LeftHandSideExpression `||=` AssignmentExpression
    --     ...
    --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
    --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
    --     ...
    --
    --   AssignmentExpression : LeftHandSideExpression `??=` AssignmentExpression
    --     ...
    --     4. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
    --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
    --     ...

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    else
        assignedName = estransforms.getAssignedNameOfIdentifier(emitContext, node.left, node.right)
    end
    local right = estransforms.finishTransformNamedEvaluation(emitContext, node.right, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateBinaryExpression(
        node,
        nil, -- modifiers
        node.left,
        nil, -- typeNode
        node.operatorToken,
        right
    )
end

function estransforms.transformNamedEvaluationOfExportAssignment(emitContext, node, ignoreEmptyStringLiteral, assignedNameText)
    -- 16.2.3.7 RS: Evaluation
    --   ExportDeclaration : `export` `default` AssignmentExpression `;`
    --     1. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |AssignmentExpression| with argument `"default"`.
    --     ...

    -- NOTE: Since emit for `export =` translates to `module.exports = ...`, the assigned name of the class or function
    -- is `""`.

    local factory = emitContext.factory
    local assignedName
    if #assignedNameText > 0 then
        assignedName = factory:NewStringLiteral(assignedNameText, TokenFlags.None)
    elseif node.isExportEquals then
        assignedName = factory:NewStringLiteral("", TokenFlags.None)
    else
        assignedName = factory:NewStringLiteral("default", TokenFlags.None)
    end
    local expression = estransforms.finishTransformNamedEvaluation(emitContext, node.expression, assignedName, ignoreEmptyStringLiteral)
    return factory:UpdateExportAssignment(
        node,
        nil, -- modifiers
        node.isExportEquals,
        nil, -- typeNode
        expression
    )
end

-- Performs a shallow transformation of a `NamedEvaluation` node, such that a valid name will be assigned.
function estransforms.transformNamedEvaluation(context, node, ignoreEmptyStringLiteral, assignedName)
    local k = node.kind
    if k == Kind.PropertyAssignment then
        return estransforms.transformNamedEvaluationOfPropertyAssignment(context, node:AsPropertyAssignment(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.ShorthandPropertyAssignment then
        return estransforms.transformNamedEvaluationOfShorthandAssignmentProperty(context, node:AsShorthandPropertyAssignment(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.VariableDeclaration then
        return estransforms.transformNamedEvaluationOfVariableDeclaration(context, node:AsVariableDeclaration(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.Parameter then
        return estransforms.transformNamedEvaluationOfParameterDeclaration(context, node:AsParameterDeclaration(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.BindingElement then
        return estransforms.transformNamedEvaluationOfBindingElement(context, node:AsBindingElement(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.PropertyDeclaration then
        return estransforms.transformNamedEvaluationOfPropertyDeclaration(context, node:AsPropertyDeclaration(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.BinaryExpression then
        return estransforms.transformNamedEvaluationOfAssignmentExpression(context, node:AsBinaryExpression(), ignoreEmptyStringLiteral, assignedName)
    elseif k == Kind.ExportAssignment then
        return estransforms.transformNamedEvaluationOfExportAssignment(context, node:AsExportAssignment(), ignoreEmptyStringLiteral, assignedName)
    else
        debug.Fail("Unhandled case in transformNamedEvaluation")
        return node
    end
end
