local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts
local FunctionFlags = ast.FunctionFlags
local EF = printer.EmitFlags

-- asyncContextFlags
estransforms.asyncContextNonTopLevel = 1
estransforms.asyncContextHasLexicalThis = 2

-- lexicalArgumentsInfo is a Go value struct { binding, used }: treated as immutable (replaced, never
-- mutated) so that saved copies keep Go's copy semantics.
function estransforms.newLexicalArgumentsInfo(binding, used)
    return { binding = binding, used = used or false }
end

-- Embeds transformers.Transformer and superAccessState (methods promoted with
-- estransforms.embedSuperAccessState when the first instance is created).
--
-- Fields: contextFlags, enclosingFunctionParameterNames (collections.Set), lexicalArguments,
-- asyncBodyVisitor, fallbackNodeVisitor, plus the superAccessState fields.
local asyncTransformer = transformers.NewTransformerType()
estransforms.asyncTransformer = asyncTransformer

function estransforms.newAsyncTransformer(opts)
    estransforms.embedSuperAccessState(asyncTransformer)
    local tx = setmetatable({
        contextFlags = 0,
        lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false),
        hasSuperElementAccess = false,
        hasSuperPropertyAssignment = false,
    }, asyncTransformer)
    local result = tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
    tx:initSuperAccessVisitor(tx:EmitContext(), tx:Factory())
    tx.asyncBodyVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitAsyncBodyNode(node) end)
    tx.fallbackNodeVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitFallback(node) end)
    return result
end

function asyncTransformer:visitSourceFile(node)
    if node.isDeclarationFile then
        return node:AsNode()
    end

    self:setContextFlag(estransforms.asyncContextNonTopLevel, false)
    self:setContextFlag(estransforms.asyncContextHasLexicalThis, false)
    local visited = self:Visitor():VisitEachChild(node:AsNode())
    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers()))
    return visited
end

function asyncTransformer:setContextFlag(flag, val)
    if val then
        self.contextFlags = self.contextFlags | flag
    else
        self.contextFlags = self.contextFlags & ~flag
    end
end

function asyncTransformer:inContext(flags)
    return self.contextFlags & flags ~= 0
end

function asyncTransformer:inTopLevelContext()
    return not self:inContext(estransforms.asyncContextNonTopLevel)
end

function asyncTransformer:inHasLexicalThisContext()
    return self:inContext(estransforms.asyncContextHasLexicalThis)
end

-- cb is a method of asyncTransformer, called as cb(self, node).
function asyncTransformer:doWithContext(flags, cb, node)
    local flagsToSet = flags & ~self.contextFlags
    if flagsToSet ~= 0 then
        self:setContextFlag(flagsToSet, true)
        local result = cb(self, node)
        self:setContextFlag(flagsToSet, false)
        return result
    end
    return cb(self, node)
end

function asyncTransformer:visitDefault(node)
    return self:Visitor():VisitEachChild(node)
end

function asyncTransformer:fallbackVisitor(node)
    if self.capturedSuperProperties == nil and self.lexicalArguments.binding == nil then
        return node
    end
    self:trackSuperAccess(node)
    local k = node.kind
    if k == Kind.FunctionExpression or
        k == Kind.FunctionDeclaration or
        k == Kind.MethodDeclaration or
        k == Kind.GetAccessor or
        k == Kind.SetAccessor or
        k == Kind.Constructor then
        return node
    elseif k == Kind.Parameter or
        k == Kind.BindingElement or
        k == Kind.VariableDeclaration then
        -- fall through to visitEachChild
    elseif k == Kind.Identifier then
        if self.lexicalArguments.binding ~= nil and
            node:Text() == "arguments" and
            not ast.IsIdentifierName(node) and
            not ast.IsLabelName(node) then
            self.lexicalArguments = estransforms.newLexicalArgumentsInfo(self.lexicalArguments.binding, true)
            return self.lexicalArguments.binding
        end
    end
    return self.fallbackNodeVisitor:VisitEachChild(node)
end

function asyncTransformer:visitFallback(node)
    return self:fallbackVisitor(node)
end

function asyncTransformer:visit(node)
    if self:EmitContext():EmitFlags(node) & EF.EFNoLexicalThis ~= 0 and self:inHasLexicalThisContext() then
        self:setContextFlag(estransforms.asyncContextHasLexicalThis, false)
        local result = self:visitWorker(node)
        self:setContextFlag(estransforms.asyncContextHasLexicalThis, true)
        return result
    end
    return self:visitWorker(node)
end

-- Lua helper: body of Go's visit after the deferred context-flag restore is set up.
function asyncTransformer:visitWorker(node)
    if node:SubtreeFacts() & (SubtreeFacts.SubtreeContainsAnyAwait | SubtreeFacts.SubtreeContainsAwait) == 0 then
        return self:fallbackVisitor(node)
    end
    self:trackSuperAccess(node)
    local k = node.kind
    local NonTopLevel = estransforms.asyncContextNonTopLevel
    local HasLexicalThis = estransforms.asyncContextHasLexicalThis
    if k == Kind.AsyncKeyword then
        -- ES2017 async modifier should be elided for targets < ES2017
        return nil
    elseif k == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.AwaitExpression then
        return self:visitAwaitExpression(node:AsAwaitExpression())
    elseif k == Kind.MethodDeclaration then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitMethodDeclaration, node)
    elseif k == Kind.FunctionDeclaration then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitFunctionDeclaration, node)
    elseif k == Kind.FunctionExpression then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitFunctionExpression, node)
    elseif k == Kind.ArrowFunction then
        return self:doWithContext(NonTopLevel, asyncTransformer.visitArrowFunction, node)
    elseif k == Kind.GetAccessor then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitGetAccessorDeclaration, node)
    elseif k == Kind.SetAccessor then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitSetAccessorDeclaration, node)
    elseif k == Kind.Constructor then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitConstructorDeclaration, node)
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return self:doWithContext(NonTopLevel | HasLexicalThis, asyncTransformer.visitDefault, node)
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function asyncTransformer:visitAsyncBodyNode(node)
    if estransforms.isNodeWithPossibleHoistedDeclaration(node) then
        local k = node.kind
        if k == Kind.VariableStatement then
            return self:visitVariableStatementInAsyncBody(node)
        elseif k == Kind.ForStatement then
            return self:visitForStatementInAsyncBody(node:AsForStatement())
        elseif k == Kind.ForInStatement then
            return self:visitForInStatementInAsyncBody(node:AsForInOrOfStatement())
        elseif k == Kind.ForOfStatement then
            return self:visitForOfStatementInAsyncBody(node:AsForInOrOfStatement())
        elseif k == Kind.CatchClause then
            return self:visitCatchClauseInAsyncBody(node:AsCatchClause())
        elseif k == Kind.Block or
            k == Kind.SwitchStatement or
            k == Kind.CaseBlock or
            k == Kind.CaseClause or
            k == Kind.DefaultClause or
            k == Kind.TryStatement or
            k == Kind.DoStatement or
            k == Kind.WhileStatement or
            k == Kind.IfStatement or
            k == Kind.WithStatement or
            k == Kind.LabeledStatement then
            return self.asyncBodyVisitor:VisitEachChild(node)
        end
    end
    return self:visit(node)
end

function asyncTransformer:visitCatchClauseInAsyncBody(node)
    local catchClauseNames = collections.NewSet()
    if node.variableDeclaration ~= nil then
        self:recordDeclarationName(node.variableDeclaration, catchClauseNames)
    end

    -- names declared in a catch variable are block scoped
    local catchClauseUnshadowedNames
    for escapedName in pairs(catchClauseNames:Keys() or {}) do
        if self.enclosingFunctionParameterNames ~= nil and self.enclosingFunctionParameterNames:Has(escapedName) then
            if catchClauseUnshadowedNames == nil then
                catchClauseUnshadowedNames = self.enclosingFunctionParameterNames:Clone()
            end
            catchClauseUnshadowedNames:Delete(escapedName)
        end
    end

    if catchClauseUnshadowedNames ~= nil then
        local savedEnclosingFunctionParameterNames = self.enclosingFunctionParameterNames
        self.enclosingFunctionParameterNames = catchClauseUnshadowedNames
        local result = self.asyncBodyVisitor:VisitEachChild(node:AsNode())
        self.enclosingFunctionParameterNames = savedEnclosingFunctionParameterNames
        return result
    end
    return self.asyncBodyVisitor:VisitEachChild(node:AsNode())
end

function asyncTransformer:visitVariableStatementInAsyncBody(node)
    local declList = node:AsVariableStatement().declarationList
    if self:isVariableDeclarationListWithCollidingName(declList) then
        local expression = self:visitVariableDeclarationListWithCollidingNames(declList:AsVariableDeclarationList(), false)
        if expression ~= nil then
            return self:Factory():NewExpressionStatement(expression)
        end
        return nil
    end
    return self:Visitor():VisitEachChild(node)
end

function asyncTransformer:visitForInStatementInAsyncBody(node)
    local visitedInitializer
    if self:isVariableDeclarationListWithCollidingName(node.initializer) then
        visitedInitializer = self:visitVariableDeclarationListWithCollidingNames(node.initializer:AsVariableDeclarationList(), true)
    else
        visitedInitializer = self:Visitor():VisitNode(node.initializer)
    end

    return self:Factory():UpdateForInOrOfStatement(
        node,
        nil, --[[awaitModifier]]
        visitedInitializer,
        self:Visitor():VisitNode(node.expression),
        self.asyncBodyVisitor:VisitEmbeddedStatement(node.statement)
    )
end

function asyncTransformer:visitForOfStatementInAsyncBody(node)
    local visitedInitializer
    if self:isVariableDeclarationListWithCollidingName(node.initializer) then
        visitedInitializer = self:visitVariableDeclarationListWithCollidingNames(node.initializer:AsVariableDeclarationList(), true)
    else
        visitedInitializer = self:Visitor():VisitNode(node.initializer)
    end

    return self:Factory():UpdateForInOrOfStatement(
        node,
        self:Visitor():VisitNode(node.awaitModifier),
        visitedInitializer,
        self:Visitor():VisitNode(node.expression),
        self.asyncBodyVisitor:VisitEmbeddedStatement(node.statement)
    )
end

function asyncTransformer:visitForStatementInAsyncBody(node)
    local initializer = node.initializer
    local visitedInitializer
    if initializer ~= nil and self:isVariableDeclarationListWithCollidingName(initializer) then
        visitedInitializer = self:visitVariableDeclarationListWithCollidingNames(initializer:AsVariableDeclarationList(), false)
    else
        visitedInitializer = self:Visitor():VisitNode(node.initializer)
    end

    return self:Factory():UpdateForStatement(
        node,
        visitedInitializer,
        self:Visitor():VisitNode(node.condition),
        self:Visitor():VisitNode(node.incrementor),
        self.asyncBodyVisitor:VisitEmbeddedStatement(node.statement)
    )
end

-- visitAwaitExpression visits an AwaitExpression node.
--
-- This function will be called any time a ES2017 await expression is encountered.
function asyncTransformer:visitAwaitExpression(node)
    -- do not downlevel a top-level await as it is module syntax...
    if self:inTopLevelContext() then
        return self:Visitor():VisitEachChild(node:AsNode())
    end
    local yieldExpr = self:Factory():NewYieldExpression(
        nil, --[[asteriskToken]]
        self:Visitor():VisitNode(node.expression)
    )
    yieldExpr.loc = node.loc
    self:EmitContext():SetOriginal(yieldExpr, node:AsNode())
    return yieldExpr
end

function asyncTransformer:visitConstructorDeclaration(node)
    local decl = node:AsConstructorDeclaration()
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)
    local updated = self:Factory():UpdateConstructorDeclaration(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:transformMethodBody(node)
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

-- visitMethodDeclaration visits a MethodDeclaration node.
--
-- This function will be called when one of the following conditions are met:
-- - The node is marked as async
function asyncTransformer:visitMethodDeclaration(node)
    local decl = node:AsMethodDeclaration()
    local functionFlags = ast.GetFunctionFlags(node)
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)

    local parameters
    local body
    if functionFlags & FunctionFlags.Async ~= 0 then
        parameters = self:transformAsyncFunctionParameterList(node)
        body = self:transformAsyncFunctionBody(node, parameters)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:transformMethodBody(node)
    end

    local updated = self:Factory():UpdateMethodDeclaration(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        decl.asteriskToken,
        decl:Name(),
        nil, --[[postfixToken]]
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

function asyncTransformer:visitGetAccessorDeclaration(node)
    local decl = node:AsGetAccessorDeclaration()
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)
    local updated = self:Factory():UpdateGetAccessorDeclaration(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        decl:Name(),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:transformMethodBody(node)
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

function asyncTransformer:visitSetAccessorDeclaration(node)
    local decl = node:AsSetAccessorDeclaration()
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)
    local updated = self:Factory():UpdateSetAccessorDeclaration(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        decl:Name(),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:transformMethodBody(node)
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

-- visitFunctionDeclaration visits a FunctionDeclaration node.
--
-- This function will be called when one of the following conditions are met:
-- - The node is marked async
function asyncTransformer:visitFunctionDeclaration(node)
    local decl = node:AsFunctionDeclaration()
    local functionFlags = ast.GetFunctionFlags(node)
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)

    local parameters
    local body
    if functionFlags & FunctionFlags.Async ~= 0 then
        parameters = self:transformAsyncFunctionParameterList(node)
        body = self:transformAsyncFunctionBody(node, parameters)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(decl.body, self:Visitor())
    end

    local updated = self:Factory():UpdateFunctionDeclaration(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        decl.asteriskToken,
        self:Visitor():VisitNode(decl:Name()),
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

-- visitFunctionExpression visits a FunctionExpression node.
--
-- This function will be called when one of the following conditions are met:
-- - The node is marked async
function asyncTransformer:visitFunctionExpression(node)
    local decl = node:AsFunctionExpression()
    local functionFlags = ast.GetFunctionFlags(node)
    local savedLexicalArguments = self.lexicalArguments
    self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)

    local parameters
    local body
    if functionFlags & FunctionFlags.Async ~= 0 then
        parameters = self:transformAsyncFunctionParameterList(node)
        body = self:transformAsyncFunctionBody(node, parameters)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(decl.body, self:Visitor())
    end

    local updated = self:Factory():UpdateFunctionExpression(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        decl.asteriskToken,
        self:Visitor():VisitNode(decl:Name()),
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.lexicalArguments = savedLexicalArguments
    return updated
end

-- visitArrowFunction visits an ArrowFunction.
--
-- This function will be called when one of the following conditions are met:
-- - The node is marked async
function asyncTransformer:visitArrowFunction(node)
    -- `arguments` in class static blocks is always an error, but we preserve Strada's emit
    -- behavior for baseline compatibility. In Strada, checker-based `isArgumentsLocalBinding`
    -- returns false for `arguments` in static blocks (since the binding doesn't exist due to
    -- the error), so the async transform leaves them untouched.
    if self:EmitContext():EmitFlags(node) & EF.EFNoLexicalArguments ~= 0 then
        local savedLexicalArguments = self.lexicalArguments
        self.lexicalArguments = estransforms.newLexicalArgumentsInfo(nil, false)
        local result = self:visitArrowFunctionWorker(node)
        self.lexicalArguments = savedLexicalArguments
        return result
    end
    return self:visitArrowFunctionWorker(node)
end

-- Lua helper: body of Go's visitArrowFunction after the deferred lexicalArguments restore.
function asyncTransformer:visitArrowFunctionWorker(node)
    local decl = node:AsArrowFunction()
    local functionFlags = ast.GetFunctionFlags(node)

    local parameters
    local body
    if functionFlags & FunctionFlags.Async ~= 0 then
        parameters = self:transformAsyncFunctionParameterList(node)
        body = self:transformAsyncFunctionBody(node, parameters)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(decl.body, self:Visitor())
    end

    return self:Factory():UpdateArrowFunction(
        decl,
        self:Visitor():VisitModifiers(decl:Modifiers()),
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        decl.equalsGreaterThanToken,
        body
    )
end

function asyncTransformer:recordDeclarationName(node, names)
    local name = node:Name()
    if name == nil then
        return
    end
    if ast.IsIdentifier(name) then
        names:Add(name:Text())
    elseif ast.IsBindingPattern(name) then
        for _, element in ipairs(name:AsBindingPattern().elements.nodes) do
            if not ast.IsOmittedExpression(element) then
                self:recordDeclarationName(element, names)
            end
        end
    end
end

function asyncTransformer:isVariableDeclarationListWithCollidingName(node)
    if node == nil or not ast.IsVariableDeclarationList(node) or node.flags & NodeFlags.BlockScoped ~= 0 then
        return false
    end
    for _, decl in ipairs(node:AsVariableDeclarationList().declarations.nodes) do
        if self:collidesWithParameterName(decl) then
            return true
        end
    end
    return false
end

function asyncTransformer:visitVariableDeclarationListWithCollidingNames(node, hasReceiver)
    self:hoistVariableDeclarationList(node)

    local variables = {}
    for _, decl in ipairs(node.declarations.nodes) do
        if decl:AsVariableDeclaration().initializer ~= nil then
            variables[#variables + 1] = decl
        end
    end

    if #variables == 0 then
        if hasReceiver then
            local name = node.declarations.nodes[1]:Name()
            local target
            if ast.IsBindingPattern(name) then
                target = transformers.ConvertBindingPatternToAssignmentPattern(self:EmitContext(), name:AsBindingPattern())
            else
                target = name
            end
            return self:Visitor():VisitNode(target)
        end
        return nil
    end

    local expressions = {}
    for _, variable in ipairs(variables) do
        expressions[#expressions + 1] = self:transformInitializedVariable(variable:AsVariableDeclaration())
    end
    return self:Factory():InlineExpressions(expressions)
end

function asyncTransformer:hoistVariableDeclarationList(node)
    for _, decl in ipairs(node.declarations.nodes) do
        self:hoistVariable(decl)
    end
end

function asyncTransformer:hoistVariable(node)
    local name = node:Name()
    if name == nil then
        return
    end
    if ast.IsIdentifier(name) then
        self:EmitContext():AddVariableDeclaration(name)
    elseif ast.IsBindingPattern(name) then
        for _, element in ipairs(name:AsBindingPattern().elements.nodes) do
            if not ast.IsOmittedExpression(element) then
                self:hoistVariable(element)
            end
        end
    end
end

function asyncTransformer:transformInitializedVariable(node)
    local target
    if ast.IsBindingPattern(node:Name()) then
        target = transformers.ConvertBindingPatternToAssignmentPattern(self:EmitContext(), node:Name():AsBindingPattern())
    else
        target = node:Name()
    end
    local converted = self:Factory():NewAssignmentExpression(target, node.initializer)
    self:EmitContext():SetSourceMapRange(converted, node.loc)
    return self:Visitor():VisitNode(converted)
end

function asyncTransformer:collidesWithParameterName(node)
    local name = node:Name()
    if name == nil then
        return false
    end
    if ast.IsIdentifier(name) then
        return self.enclosingFunctionParameterNames ~= nil and self.enclosingFunctionParameterNames:Has(name:Text())
    end
    if ast.IsBindingPattern(name) then
        for _, element in ipairs(name:AsBindingPattern().elements.nodes) do
            if not ast.IsOmittedExpression(element) and self:collidesWithParameterName(element) then
                return true
            end
        end
    end
    return false
end

function asyncTransformer:transformMethodBody(node)
    local savedCapturedSuperProperties = self.capturedSuperProperties
    local savedHasSuperElementAccess = self.hasSuperElementAccess
    local savedHasSuperPropertyAssignment = self.hasSuperPropertyAssignment
    local savedSuperBinding = self.superBinding
    local savedSuperIndexBinding = self.superIndexBinding
    self.capturedSuperProperties = collections.NewOrderedSet()
    self.hasSuperElementAccess = false
    self.hasSuperPropertyAssignment = false
    self.superBinding = self:Factory():NewUniqueNameEx("_super", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
    self.superIndexBinding = self:Factory():NewUniqueNameEx("_superIndex", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })

    self:EmitContext():StartVariableEnvironment()
    local updated = self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())

    -- Minor optimization, emit `_super` helper to capture `super` access in an arrow.
    local emitSuperHelpers = (self.capturedSuperProperties:Size() > 0 or self.hasSuperElementAccess) and
        (ast.GetFunctionFlags(self:getOriginalIfFunctionLike(node)) & FunctionFlags.AsyncGenerator) ~= FunctionFlags.AsyncGenerator

    if emitSuperHelpers then
        if self.capturedSuperProperties:Size() > 0 then
            self:EmitContext():AddInitializationStatement(self:createSuperAccessVariableStatement())
        end
    end

    local mergedStatements = self:EmitContext():EndAndMergeVariableEnvironmentList(updated:StatementList())
    if emitSuperHelpers and self.hasSuperElementAccess and not updated:AsBlock().multiLine then
        local newBlock = self:Factory():NewBlock(mergedStatements, true)
        newBlock.loc = updated.loc
        updated = newBlock
    else
        updated = self:Factory():UpdateBlock(updated:AsBlock(), mergedStatements, updated:AsBlock().multiLine)
    end

    if emitSuperHelpers and self.hasSuperElementAccess then
        if self.hasSuperPropertyAssignment then
            self:EmitContext():AddEmitHelper(updated, printer.AdvancedAsyncSuperHelper)
        else
            self:EmitContext():AddEmitHelper(updated, printer.AsyncSuperHelper)
        end
    end

    self.capturedSuperProperties = savedCapturedSuperProperties
    self.hasSuperElementAccess = savedHasSuperElementAccess
    self.hasSuperPropertyAssignment = savedHasSuperPropertyAssignment
    self.superBinding = savedSuperBinding
    self.superIndexBinding = savedSuperIndexBinding
    return updated
end

function asyncTransformer:createCaptureArgumentsStatement()
    local variable = self:Factory():NewVariableDeclaration(
        self.lexicalArguments.binding,
        nil,
        nil,
        self:Factory():NewIdentifier("arguments")
    )
    local declList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ variable }), NodeFlags.None)
    local statement = self:Factory():NewVariableStatement(nil, declList)
    self:EmitContext():AddEmitFlags(statement, EF.EFStartOnNewLine | EF.EFCustomPrologue)
    return statement
end

function asyncTransformer:transformAsyncFunctionParameterList(node)
    if estransforms.isSimpleParameterList(node:Parameters()) then
        return self:EmitContext():VisitParameters(node:ParameterList(), self:Visitor())
    end

    local newParameters = {}
    for _, parameter in ipairs(node:Parameters() or {}) do
        local param = parameter:AsParameterDeclaration()
        if param.initializer ~= nil or param.dotDotDotToken ~= nil then
            -- for an arrow function, capture the remaining arguments in a rest parameter.
            -- for any other function/method this isn't necessary as we can just use `arguments`.
            if node.kind == Kind.ArrowFunction then
                local restParameter = self:Factory():NewParameterDeclaration(
                    nil,
                    self:Factory():NewToken(Kind.DotDotDotToken),
                    self:Factory():NewUniqueNameEx("args", { flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes }),
                    nil,
                    nil,
                    nil
                )
                newParameters[#newParameters + 1] = restParameter
            end
            break
        end
        -- for arrow functions we capture fixed parameters to forward to `__awaiter`. For all other functions
        -- we add fixed parameters to preserve the function's `length` property.
        local newParameter = self:Factory():NewParameterDeclaration(
            nil,
            nil,
            self:Factory():NewGeneratedNameForNodeEx(param:Name(), { flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes }),
            nil,
            nil,
            nil
        )
        newParameters[#newParameters + 1] = newParameter
    end
    local newParametersArray = self:Factory():NewNodeList(newParameters)
    newParametersArray.loc = node:ParameterList().loc
    return newParametersArray
end

function asyncTransformer:transformAsyncFunctionBody(node, outerParameters)
    local isArrow = node.kind == Kind.ArrowFunction
    local savedCapturedSuperProperties = self.capturedSuperProperties
    local savedHasSuperElementAccess = self.hasSuperElementAccess
    local savedHasSuperPropertyAssignment = self.hasSuperPropertyAssignment
    local savedSuperBinding = self.superBinding
    local savedSuperIndexBinding = self.superIndexBinding
    if not isArrow then
        self.capturedSuperProperties = collections.NewOrderedSet()
        self.hasSuperElementAccess = false
        self.hasSuperPropertyAssignment = false
        self.superBinding = self:Factory():NewUniqueNameEx("_super", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
        self.superIndexBinding = self:Factory():NewUniqueNameEx("_superIndex", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
    end

    local innerParameters = nil
    if not estransforms.isSimpleParameterList(node:Parameters()) then
        innerParameters = self:EmitContext():VisitParameters(node:ParameterList(), self:Visitor())
    end

    local savedLexicalArguments = self.lexicalArguments
    local captureLexicalArguments = self.lexicalArguments.binding == nil
    if captureLexicalArguments then
        self.lexicalArguments = estransforms.newLexicalArgumentsInfo(self:Factory():NewUniqueName("arguments"), false)
    end

    local argumentsExpression
    if innerParameters ~= nil then
        if isArrow then
            -- `node` does not have a simple parameter list, so `outerParameters` refers to placeholders that are
            -- forwarded to `innerParameters`, matching how they are introduced in `transformAsyncFunctionParameterList`.
            local parameterBindings = {}
            local outerLen = #(outerParameters.nodes or {})
            for i1, param in ipairs(node:Parameters() or {}) do
                local i = i1 - 1
                if i >= outerLen then
                    break
                end
                local originalParameter = param:AsParameterDeclaration()
                local outerParameter = outerParameters.nodes[i + 1]:AsParameterDeclaration()
                if originalParameter.initializer ~= nil or originalParameter.dotDotDotToken ~= nil then
                    parameterBindings[#parameterBindings + 1] = self:Factory():NewSpreadElement(outerParameter:Name())
                    break
                end
                parameterBindings[#parameterBindings + 1] = outerParameter:Name()
            end
            argumentsExpression = self:Factory():NewArrayLiteralExpression(self:Factory():NewNodeList(parameterBindings), false)
        else
            argumentsExpression = self:Factory():NewIdentifier("arguments")
        end
    end

    -- An async function is emit as an outer function that calls an inner
    -- generator function. To preserve lexical bindings, we pass the current
    -- `this` and `arguments` objects to `__awaiter`. The generator function
    -- passed to `__awaiter` is executed inside of the callback to the
    -- promise constructor.

    local savedEnclosingFunctionParameterNames = self.enclosingFunctionParameterNames
    self.enclosingFunctionParameterNames = collections.NewSet()
    for _, parameter in ipairs(node:Parameters() or {}) do
        self:recordDeclarationName(parameter, self.enclosingFunctionParameterNames)
    end

    local hasLexicalThis = self:inHasLexicalThisContext()

    local asyncBody = self:transformAsyncFunctionBodyWorker(node:Body())
    asyncBody = self:Factory():UpdateBlock(
        asyncBody:AsBlock(),
        self:EmitContext():EndAndMergeVariableEnvironmentList(asyncBody:StatementList()),
        asyncBody:AsBlock().multiLine
    )

    -- Substitute super property accesses with _super/_superIndex helpers
    local emitSuperHelpers = self.capturedSuperProperties ~= nil and
        (self.capturedSuperProperties:Size() > 0 or self.hasSuperElementAccess)
    if emitSuperHelpers then
        innerParameters = self.superAccessVisitor:VisitNodes(innerParameters)
        asyncBody = self:substituteSuperAccessesInBody(asyncBody)
    end

    local result
    if not isArrow then
        self:EmitContext():StartVariableEnvironment()

        -- Minor optimization, emit `_super` helper to capture `super` access in an arrow.
        if emitSuperHelpers then
            if self.capturedSuperProperties:Size() > 0 then
                self:EmitContext():AddInitializationStatement(self:createSuperAccessVariableStatement())
            end
        end

        if captureLexicalArguments and self.lexicalArguments.used then
            self:EmitContext():AddInitializationStatement(self:createCaptureArgumentsStatement())
        end

        local statements = {
            self:Factory():NewReturnStatement(
                self:Factory():NewAwaiterHelper(
                    hasLexicalThis,
                    argumentsExpression,
                    innerParameters,
                    asyncBody
                )
            ),
        }

        local block = self:Factory():NewBlock(
            self:EmitContext():EndAndMergeVariableEnvironmentList(self:Factory():NewNodeList(statements)),
            true
        )
        block.loc = node:Body().loc

        if emitSuperHelpers and self.hasSuperElementAccess then
            if self.hasSuperPropertyAssignment then
                self:EmitContext():AddEmitHelper(block, printer.AdvancedAsyncSuperHelper)
            else
                self:EmitContext():AddEmitHelper(block, printer.AsyncSuperHelper)
            end
        end

        result = block
    else
        result = self:Factory():NewAwaiterHelper(
            hasLexicalThis,
            argumentsExpression,
            innerParameters,
            asyncBody
        )

        if captureLexicalArguments and self.lexicalArguments.used then
            local block = self:EmitContext():ConvertToFunctionBlock(result, true --[[multiLine]])
            if not ast.IsBlock(result) then
                self:EmitContext():SetOriginal(block:StatementList().nodes[1], result)
            end
            result = self:Factory():UpdateBlock(
                block:AsBlock(),
                self:EmitContext():MergeEnvironmentList(block:StatementList(), { self:createCaptureArgumentsStatement() }),
                block:AsBlock().multiLine
            )
        end
    end

    self.enclosingFunctionParameterNames = savedEnclosingFunctionParameterNames
    if not isArrow then
        self.capturedSuperProperties = savedCapturedSuperProperties
        self.hasSuperElementAccess = savedHasSuperElementAccess
        self.hasSuperPropertyAssignment = savedHasSuperPropertyAssignment
        self.superBinding = savedSuperBinding
        self.superIndexBinding = savedSuperIndexBinding
        self.lexicalArguments = savedLexicalArguments
    elseif captureLexicalArguments and not self.lexicalArguments.used then
        -- If we created a new binding but it wasn't used, restore the previous state.
        -- If it was used, keep the binding alive so sibling arrows can reuse it
        -- (the `var` declaration hoists to the enclosing function scope).
        self.lexicalArguments = savedLexicalArguments
    elseif captureLexicalArguments then
        -- Keep the binding but clear the used flag so siblings don't re-emit the capture statement.
        self.lexicalArguments = estransforms.newLexicalArgumentsInfo(self.lexicalArguments.binding, false)
    end
    return result
end

function asyncTransformer:transformAsyncFunctionBodyWorker(body)
    if ast.IsBlock(body) then
        return self:Factory():UpdateBlock(
            body:AsBlock(),
            self.asyncBodyVisitor:VisitNodes(body:StatementList()),
            body:AsBlock().multiLine
        )
    end
    -- Convert expression body to block body with return statement
    local visited = self.asyncBodyVisitor:VisitNode(body)
    local ret = self:Factory():NewReturnStatement(visited)
    ret.loc = body.loc
    local list = self:Factory():NewNodeList({ ret })
    list.loc = body.loc
    local block = self:Factory():NewBlock(list, false --[[multiLine]])
    block.loc = body.loc
    return block
end

-- assignmentTargetContainsSuperProperty checks top-down whether an assignment target
-- expression contains a super property or element access (super.x or super[x]).
-- This avoids relying on parent pointers (IsAssignmentTarget) which may not be set
-- on synthesized AST nodes from prior transforms.
function estransforms.assignmentTargetContainsSuperProperty(node)
    local k = node.kind
    if k == Kind.PropertyAccessExpression or k == Kind.ElementAccessExpression then
        return node:Expression().kind == Kind.SuperKeyword
    elseif k == Kind.ParenthesizedExpression then
        return estransforms.assignmentTargetContainsSuperProperty(node:AsParenthesizedExpression().expression)
    elseif k == Kind.ArrayLiteralExpression then
        for _, e in ipairs(node:AsArrayLiteralExpression().elements.nodes or {}) do
            if estransforms.assignmentTargetContainsSuperProperty(e) then
                return true
            end
        end
        return false
    elseif k == Kind.ObjectLiteralExpression then
        for _, prop in ipairs(node:AsObjectLiteralExpression().properties.nodes or {}) do
            local pk = prop.kind
            if pk == Kind.PropertyAssignment then
                if estransforms.assignmentTargetContainsSuperProperty(prop:AsPropertyAssignment().initializer) then
                    return true
                end
            elseif pk == Kind.ShorthandPropertyAssignment then
                if estransforms.assignmentTargetContainsSuperProperty(prop:AsShorthandPropertyAssignment():Name()) then
                    return true
                end
            elseif pk == Kind.SpreadAssignment then
                if estransforms.assignmentTargetContainsSuperProperty(prop:AsSpreadAssignment().expression) then
                    return true
                end
            end
        end
    elseif k == Kind.SpreadElement then
        return estransforms.assignmentTargetContainsSuperProperty(node:AsSpreadElement().expression)
    end
    return false
end

-- isUpdateExpression checks if a prefix/postfix unary expression is ++ or --.
function estransforms.isUpdateExpression(node)
    if ast.IsPrefixUnaryExpression(node) then
        local op = node:AsPrefixUnaryExpression().operator
        return op == Kind.PlusPlusToken or op == Kind.MinusMinusToken
    end
    if ast.IsPostfixUnaryExpression(node) then
        local op = node:AsPostfixUnaryExpression().operator
        return op == Kind.PlusPlusToken or op == Kind.MinusMinusToken
    end
    return false
end

function asyncTransformer:getOriginalIfFunctionLike(node)
    local original = self:EmitContext():MostOriginal(node)
    if original ~= nil and ast.IsFunctionLikeDeclaration(original) then
        return original
    end
    return node
end

-- isSimpleParameterList checks if every parameter has no initializer and an Identifier name.
function estransforms.isSimpleParameterList(params)
    for _, param in ipairs(params or {}) do
        local p = param:AsParameterDeclaration()
        if p.initializer ~= nil or not ast.IsIdentifier(p:Name()) then
            return false
        end
    end
    return true
end

-- isNodeWithPossibleHoistedDeclaration checks if a node could contain hoisted declarations.
estransforms.nodeWithPossibleHoistedDeclarationKinds = {
    [Kind.Block] = true,
    [Kind.VariableStatement] = true,
    [Kind.WithStatement] = true,
    [Kind.IfStatement] = true,
    [Kind.SwitchStatement] = true,
    [Kind.CaseBlock] = true,
    [Kind.CaseClause] = true,
    [Kind.DefaultClause] = true,
    [Kind.LabeledStatement] = true,
    [Kind.ForStatement] = true,
    [Kind.ForInStatement] = true,
    [Kind.ForOfStatement] = true,
    [Kind.DoStatement] = true,
    [Kind.WhileStatement] = true,
    [Kind.TryStatement] = true,
    [Kind.CatchClause] = true,
}

function estransforms.isNodeWithPossibleHoistedDeclaration(node)
    return estransforms.nodeWithPossibleHoistedDeclarationKinds[node.kind] == true
end
