local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts
local FunctionFlags = ast.FunctionFlags
local EF = printer.EmitFlags

-- Facts we track as we traverse the tree (forAwaitHierarchyFacts)
estransforms.forAwaitHierarchyFactsNone = 0

--
-- Ancestor facts
--

estransforms.forAwaitHierarchyFactsHasLexicalThis = 1
estransforms.forAwaitHierarchyFactsIterationContainer = 2

--
-- Ancestor masks
--

estransforms.forAwaitHierarchyFactsAncestorFactsMask = 3

estransforms.forAwaitHierarchyFactsSourceFileExcludes = estransforms.forAwaitHierarchyFactsIterationContainer
estransforms.forAwaitHierarchyFactsStrictModeSourceFileIncludes = estransforms.forAwaitHierarchyFactsNone

estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes = estransforms.forAwaitHierarchyFactsHasLexicalThis
estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes = estransforms.forAwaitHierarchyFactsIterationContainer

estransforms.forAwaitHierarchyFactsArrowFunctionIncludes = estransforms.forAwaitHierarchyFactsNone
estransforms.forAwaitHierarchyFactsArrowFunctionExcludes = estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes

estransforms.forAwaitHierarchyFactsIterationStatementIncludes = estransforms.forAwaitHierarchyFactsIterationContainer
estransforms.forAwaitHierarchyFactsIterationStatementExcludes = estransforms.forAwaitHierarchyFactsNone

-- Embeds transformers.Transformer and superAccessState (methods promoted with
-- estransforms.embedSuperAccessState when the first instance is created).
--
-- Fields: compilerOptions, enclosingFunctionFlags, forAwaitHierarchyFacts, exportedVariableStatement,
-- fallbackNodeVisitor, noAsyncModifierVisitor, plus the superAccessState fields.
local forawaitTransformer = transformers.NewTransformerType()
estransforms.forawaitTransformer = forawaitTransformer

function estransforms.newforawaitTransformer(opts)
    estransforms.embedSuperAccessState(forawaitTransformer)
    local tx = setmetatable({
        compilerOptions = opts.compilerOptions,
        enclosingFunctionFlags = 0,
        forAwaitHierarchyFacts = 0,
        exportedVariableStatement = false,
        hasSuperElementAccess = false,
        hasSuperPropertyAssignment = false,
    }, forawaitTransformer)
    local result = tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
    tx:initSuperAccessVisitor(tx:EmitContext(), tx:Factory())
    tx.fallbackNodeVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitFallback(node) end)
    tx.noAsyncModifierVisitor = tx:EmitContext():NewNodeVisitor(function(node)
        if node.kind == Kind.AsyncKeyword then
            return nil
        end
        return node
    end)
    return result
end

function forawaitTransformer:affectsSubtree(excludeFacts, includeFacts)
    return self.forAwaitHierarchyFacts ~= ((self.forAwaitHierarchyFacts & ~excludeFacts) | includeFacts)
end

-- enterSubtree sets the HierarchyFacts for this node prior to visiting this node's subtree,
-- returning the facts set prior to modification.
function forawaitTransformer:enterSubtree(excludeFacts, includeFacts)
    local ancestorFacts = self.forAwaitHierarchyFacts
    self.forAwaitHierarchyFacts = ((self.forAwaitHierarchyFacts & ~excludeFacts) | includeFacts) & estransforms.forAwaitHierarchyFactsAncestorFactsMask
    return ancestorFacts
end

-- exitSubtree restores the HierarchyFacts for this node's ancestor after visiting this node's
-- subtree.
function forawaitTransformer:exitSubtree(ancestorFacts)
    self.forAwaitHierarchyFacts = ancestorFacts
end

function forawaitTransformer:visitModifiersNoAsync(modifiers)
    return self.noAsyncModifierVisitor:VisitModifiers(modifiers)
end

-- cb is a method of forawaitTransformer, called as cb(self, node).
function forawaitTransformer:doWithHierarchyFacts(cb, node, excludeFacts, includeFacts)
    if self:affectsSubtree(excludeFacts, includeFacts) then
        local ancestorFacts = self:enterSubtree(excludeFacts, includeFacts)
        local result = cb(self, node)
        self:exitSubtree(ancestorFacts)
        return result
    end
    return cb(self, node)
end

function forawaitTransformer:visitDefault(node)
    return self:Visitor():VisitEachChild(node)
end

function forawaitTransformer:fallbackVisitor(node)
    if self.capturedSuperProperties == nil then
        return node
    end
    local k = node.kind
    if k == Kind.FunctionExpression or k == Kind.FunctionDeclaration or
        k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor or
        k == Kind.Constructor then
        return node
    end
    self:trackSuperAccess(node)
    return self.fallbackNodeVisitor:VisitEachChild(node)
end

function forawaitTransformer:visitFallback(node)
    return self:fallbackVisitor(node)
end

function forawaitTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator == 0 then
        return self:fallbackVisitor(node)
    end
    self:trackSuperAccess(node)
    local k = node.kind
    if k == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.AwaitExpression then
        return self:visitAwaitExpression(node:AsAwaitExpression())
    elseif k == Kind.YieldExpression then
        return self:visitYieldExpression(node:AsYieldExpression())
    elseif k == Kind.ReturnStatement then
        return self:visitReturnStatement(node:AsReturnStatement())
    elseif k == Kind.LabeledStatement then
        return self:visitLabeledStatement(node:AsLabeledStatement())
    elseif k == Kind.DoStatement or k == Kind.WhileStatement or k == Kind.ForInStatement then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitDefault,
            node,
            estransforms.forAwaitHierarchyFactsIterationStatementExcludes,
            estransforms.forAwaitHierarchyFactsIterationStatementIncludes
        )
    elseif k == Kind.ForOfStatement then
        return self:visitForOfStatement(node:AsForInOrOfStatement(), nil)
    elseif k == Kind.ForStatement then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitDefault,
            node,
            estransforms.forAwaitHierarchyFactsIterationStatementExcludes,
            estransforms.forAwaitHierarchyFactsIterationStatementIncludes
        )
    elseif k == Kind.Constructor then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitConstructorDeclaration,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.MethodDeclaration then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitMethodDeclaration,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.GetAccessor then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitGetAccessorDeclaration,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.SetAccessor then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitSetAccessorDeclaration,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.FunctionDeclaration then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitFunctionDeclaration,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.FunctionExpression then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitFunctionExpression,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    elseif k == Kind.ArrowFunction then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitArrowFunction,
            node,
            estransforms.forAwaitHierarchyFactsArrowFunctionExcludes,
            estransforms.forAwaitHierarchyFactsArrowFunctionIncludes
        )
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return self:doWithHierarchyFacts(
            forawaitTransformer.visitDefault,
            node,
            estransforms.forAwaitHierarchyFactsClassOrFunctionExcludes,
            estransforms.forAwaitHierarchyFactsClassOrFunctionIncludes
        )
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function forawaitTransformer:visitAwaitExpression(node)
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        local result = self:Factory():NewYieldExpression(
            nil, --[[asteriskToken]]
            self:Factory():NewAwaitHelper(self:Visitor():VisitNode(node.expression))
        )
        result.loc = node.loc
        self:EmitContext():SetOriginal(result, node:AsNode())
        return result
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function forawaitTransformer:visitYieldExpression(node)
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        if node.asteriskToken ~= nil then
            local expression = self:Visitor():VisitNode(node.expression)

            local asyncValuesResult = self:Factory():NewAsyncValuesHelper(expression)
            asyncValuesResult.loc = expression.loc

            local asyncDelegatorResult = self:Factory():NewAsyncDelegatorHelper(asyncValuesResult)
            asyncDelegatorResult.loc = expression.loc

            local innerYield = self:Factory():UpdateYieldExpression(
                node,
                node.asteriskToken,
                asyncDelegatorResult
            )

            local awaitedYield = self:Factory():NewAwaitHelper(innerYield)

            local result = self:Factory():NewYieldExpression(
                nil, --[[asteriskToken]]
                awaitedYield
            )
            result.loc = node.loc
            self:EmitContext():SetOriginal(result, node:AsNode())
            return result
        end

        local innerExpression
        if node.expression ~= nil then
            innerExpression = self:Visitor():VisitNode(node.expression)
        else
            innerExpression = self:Factory():NewVoidZeroExpression()
        end

        local result = self:Factory():NewYieldExpression(
            nil, --[[asteriskToken]]
            self:createDownlevelAwait(innerExpression)
        )
        result.loc = node.loc
        self:EmitContext():SetOriginal(result, node:AsNode())
        return result
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function forawaitTransformer:visitReturnStatement(node)
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        local expression
        if node.expression ~= nil then
            expression = self:Visitor():VisitNode(node.expression)
        else
            expression = self:Factory():NewVoidZeroExpression()
        end
        return self:Factory():UpdateReturnStatement(
            node,
            self:createDownlevelAwait(expression)
        )
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function forawaitTransformer:visitLabeledStatement(node)
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 then
        local statement = estransforms.unwrapInnermostStatementOfLabel(node)
        if statement.kind == Kind.ForOfStatement and statement:AsForInOrOfStatement().awaitModifier ~= nil then
            return self:visitForOfStatement(statement:AsForInOrOfStatement(), node)
        end
        return self:Factory():RestoreEnclosingLabel(self:Visitor():VisitNode(statement), node)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- unwrapInnermostStatementOfLabel follows LabeledStatement chains to find the innermost statement.
function estransforms.unwrapInnermostStatementOfLabel(node)
    while true do
        if node.statement.kind ~= Kind.LabeledStatement then
            return node.statement
        end
        node = node.statement:AsLabeledStatement()
    end
end

function forawaitTransformer:visitSourceFile(node)
    local ancestorFacts = self:enterSubtree(
        estransforms.forAwaitHierarchyFactsSourceFileExcludes,
        estransforms.forAwaitHierarchyFactsStrictModeSourceFileIncludes
    )
    self.exportedVariableStatement = false
    local visited = self:Visitor():VisitEachChild(node:AsNode())
    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers()))
    self:exitSubtree(ancestorFacts)
    return visited
end

-- visitForOfStatement visits a ForOfStatement and converts it into a ES2015-compatible ForOfStatement.
function forawaitTransformer:visitForOfStatement(node, outermostLabeledStatement)
    local ancestorFacts = self:enterSubtree(estransforms.forAwaitHierarchyFactsIterationStatementExcludes, estransforms.forAwaitHierarchyFactsIterationStatementIncludes)
    local result
    if node.awaitModifier ~= nil then
        result = self:transformForAwaitOfStatement(node, outermostLabeledStatement, ancestorFacts)
    else
        result = self:Factory():RestoreEnclosingLabel(self:Visitor():VisitEachChild(node:AsNode()), outermostLabeledStatement)
    end
    self:exitSubtree(ancestorFacts)
    return result
end

function forawaitTransformer:convertForOfStatementHead(node, boundValue, nonUserCode)
    local f = self:Factory()
    local value = f:NewTempVariable()
    self:EmitContext():AddVariableDeclaration(value)
    local iteratorValueExpression = f:NewAssignmentExpression(value, boundValue)
    local iteratorValueStatement = f:NewExpressionStatement(iteratorValueExpression)
    self:EmitContext():SetSourceMapRange(iteratorValueStatement, node.expression.loc)

    local exitNonUserCodeExpression = f:NewAssignmentExpression(nonUserCode, f:NewKeywordExpression(Kind.FalseKeyword))
    local exitNonUserCodeStatement = f:NewExpressionStatement(exitNonUserCodeExpression)
    self:EmitContext():SetSourceMapRange(exitNonUserCodeStatement, node.expression.loc)

    local statements = { iteratorValueStatement, exitNonUserCodeStatement }
    local binding = self:Factory():CreateForOfBindingStatement(node.initializer, value)
    statements[#statements + 1] = self:Visitor():VisitNode(binding)

    local bodyLocation = core.NewTextRange(0, 0)
    local statementsLocation = core.NewTextRange(0, 0)
    local statement = self:Visitor():VisitEmbeddedStatement(node.statement)
    if ast.IsBlock(statement) then
        for _, s in ipairs(statement:Statements() or {}) do
            statements[#statements + 1] = s
        end
        bodyLocation = statement.loc
        statementsLocation = statement:StatementList().loc
    else
        statements[#statements + 1] = statement
    end

    local stmtList = f:NewNodeList(statements)
    stmtList.loc = statementsLocation
    local block = f:NewBlock(stmtList, true)
    block.loc = bodyLocation
    return block
end

function forawaitTransformer:createDownlevelAwait(expression)
    if self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        return self:Factory():NewYieldExpression(
            nil, --[[asteriskToken]]
            self:Factory():NewAwaitHelper(expression)
        )
    end
    return self:Factory():NewAwaitExpression(expression)
end

function forawaitTransformer:transformForAwaitOfStatement(node, outermostLabeledStatement, ancestorFacts)
    local f = self:Factory()
    local expression = self:Visitor():VisitNode(node.expression)

    local iterator
    if ast.IsIdentifier(expression) then
        iterator = f:NewGeneratedNameForNode(expression)
    else
        iterator = f:NewTempVariable()
    end

    local result
    if ast.IsIdentifier(expression) then
        result = f:NewGeneratedNameForNode(iterator)
    else
        result = f:NewTempVariable()
    end

    local nonUserCode = f:NewTempVariable()
    local done = f:NewTempVariable()
    self:EmitContext():AddVariableDeclaration(done)
    local errorRecord = f:NewUniqueName("e")
    local catchVariable = f:NewGeneratedNameForNode(errorRecord)
    local returnMethod = f:NewTempVariable()
    local callValues = f:NewAsyncValuesHelper(expression)
    callValues.loc = node.expression.loc
    local callNext = f:NewCallExpression(
        f:NewPropertyAccessExpression(iterator, nil, f:NewIdentifier("next"), NodeFlags.None),
        nil, nil,
        f:NewNodeList({}),
        NodeFlags.None
    )
    local getDone = f:NewPropertyAccessExpression(result, nil, f:NewIdentifier("done"), NodeFlags.None)
    local getValue = f:NewPropertyAccessExpression(result, nil, f:NewIdentifier("value"), NodeFlags.None)
    local callReturn = f:NewFunctionCallCall(returnMethod, iterator, {})

    self:EmitContext():AddVariableDeclaration(errorRecord)
    self:EmitContext():AddVariableDeclaration(returnMethod)

    -- if we are enclosed in an outer loop ensure we reset 'errorRecord' per each iteration
    local initializer
    if ancestorFacts & estransforms.forAwaitHierarchyFactsIterationContainer ~= 0 then
        initializer = f:InlineExpressions({
            f:NewAssignmentExpression(errorRecord, f:NewVoidZeroExpression()),
            callValues,
        })
    else
        initializer = callValues
    end

    -- Build the for statement
    local iteratorDecl = f:NewVariableDeclaration(iterator, nil, nil, initializer)
    iteratorDecl.loc = node.expression.loc
    local varDeclList = f:NewVariableDeclarationList(f:NewNodeList({
        f:NewVariableDeclaration(nonUserCode, nil, nil, f:NewKeywordExpression(Kind.TrueKeyword)),
        iteratorDecl,
        f:NewVariableDeclaration(result, nil, nil, nil),
    }), NodeFlags.None)
    varDeclList.loc = node.expression.loc

    local condition = f:InlineExpressions({
        f:NewAssignmentExpression(result, self:createDownlevelAwait(callNext)),
        f:NewAssignmentExpression(done, getDone),
        f:NewPrefixUnaryExpression(Kind.ExclamationToken, done),
    })

    local incrementor = f:NewAssignmentExpression(nonUserCode, f:NewKeywordExpression(Kind.TrueKeyword))

    local forStatement = f:NewForStatement(
        varDeclList,
        condition,
        incrementor,
        self:convertForOfStatementHead(node, getValue, nonUserCode)
    )
    forStatement.loc = node.loc
    self:EmitContext():AddEmitFlags(forStatement, EF.EFNoTokenTrailingSourceMaps)
    self:EmitContext():SetOriginal(forStatement, node:AsNode())

    -- Build the try/catch/finally
    local tryBlock = f:NewBlock(f:NewNodeList({
        f:RestoreEnclosingLabel(forStatement, outermostLabeledStatement),
    }), true)

    -- catch clause: { e_1 = { error: e_2 }; }
    local catchBody = f:NewBlock(f:NewNodeList({
        f:NewExpressionStatement(
            f:NewAssignmentExpression(
                errorRecord,
                f:NewObjectLiteralExpression(f:NewNodeList({
                    f:NewPropertyAssignment(nil, f:NewIdentifier("error"), nil, nil, catchVariable),
                }), false)
            )
        ),
    }), false)
    self:EmitContext():AddEmitFlags(catchBody, EF.EFSingleLine)
    local catchClause = f:NewCatchClause(
        f:NewVariableDeclaration(catchVariable, nil, nil, nil),
        catchBody
    )

    -- finally block
    -- inner try: if (!nonUserCode && !done && (returnMethod = iterator.return)) await returnMethod.call(iterator);
    local innerIfCondition = f:NewBinaryExpression(
        nil,
        f:NewBinaryExpression(
            nil,
            f:NewPrefixUnaryExpression(Kind.ExclamationToken, nonUserCode),
            nil,
            f:NewToken(Kind.AmpersandAmpersandToken),
            f:NewPrefixUnaryExpression(Kind.ExclamationToken, done)
        ),
        nil,
        f:NewToken(Kind.AmpersandAmpersandToken),
        f:NewAssignmentExpression(
            returnMethod,
            f:NewPropertyAccessExpression(iterator, nil, f:NewIdentifier("return"), NodeFlags.None)
        )
    )
    local innerIfStatement = f:NewIfStatement(
        innerIfCondition,
        f:NewExpressionStatement(self:createDownlevelAwait(callReturn)),
        nil
    )
    self:EmitContext():AddEmitFlags(innerIfStatement, EF.EFSingleLine)

    local innerTryBlock = f:NewBlock(f:NewNodeList({ innerIfStatement }), false)

    -- inner finally: if (errorRecord) throw errorRecord.error;
    local innerFinallyIf = f:NewIfStatement(
        errorRecord,
        f:NewThrowStatement(
            f:NewPropertyAccessExpression(errorRecord, nil, f:NewIdentifier("error"), NodeFlags.None)
        ),
        nil
    )
    self:EmitContext():AddEmitFlags(innerFinallyIf, EF.EFSingleLine)
    local innerFinallyBlock = f:NewBlock(f:NewNodeList({ innerFinallyIf }), false)
    self:EmitContext():AddEmitFlags(innerFinallyBlock, EF.EFSingleLine)

    local innerTryStatement = f:NewTryStatement(innerTryBlock, nil, innerFinallyBlock)
    local finallyBlock = f:NewBlock(f:NewNodeList({ innerTryStatement }), true)

    return f:NewTryStatement(tryBlock, catchClause, finallyBlock)
end

function forawaitTransformer:visitConstructorDeclaration(node)
    local decl = node:AsConstructorDeclaration()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)
    local updated = self:Factory():UpdateConstructorDeclaration(
        decl,
        decl:Modifiers(),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitGetAccessorDeclaration(node)
    local decl = node:AsGetAccessorDeclaration()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)
    local updated = self:Factory():UpdateGetAccessorDeclaration(
        decl,
        decl:Modifiers(),
        self:Visitor():VisitNode(decl:Name()),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitSetAccessorDeclaration(node)
    local decl = node:AsSetAccessorDeclaration()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)
    local updated = self:Factory():UpdateSetAccessorDeclaration(
        decl,
        decl:Modifiers(),
        self:Visitor():VisitNode(decl:Name()),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitMethodDeclaration(node)
    local decl = node:AsMethodDeclaration()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)

    local modifiers
    if self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        modifiers = self:visitModifiersNoAsync(decl:Modifiers())
    else
        modifiers = decl:Modifiers()
    end

    local asteriskToken
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 then
        asteriskToken = nil
    else
        asteriskToken = decl.asteriskToken
    end

    local parameters
    local body
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        parameters = self:transformAsyncGeneratorFunctionParameterList(node)
        body = self:transformAsyncGeneratorFunctionBody(node)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    end

    local updated = self:Factory():UpdateMethodDeclaration(
        decl,
        modifiers,
        asteriskToken,
        self:Visitor():VisitNode(decl:Name()),
        nil, --[[postfixToken]]
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitFunctionDeclaration(node)
    local decl = node:AsFunctionDeclaration()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)

    local modifiers
    if self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        modifiers = self:visitModifiersNoAsync(decl:Modifiers())
    else
        modifiers = decl:Modifiers()
    end

    local asteriskToken
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 then
        asteriskToken = nil
    else
        asteriskToken = decl.asteriskToken
    end

    local parameters
    local body
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        parameters = self:transformAsyncGeneratorFunctionParameterList(node)
        body = self:transformAsyncGeneratorFunctionBody(node)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    end

    local updated = self:Factory():UpdateFunctionDeclaration(
        decl,
        modifiers,
        asteriskToken,
        decl:Name(),
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitArrowFunction(node)
    local decl = node:AsArrowFunction()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)
    local updated = self:Factory():UpdateArrowFunction(
        decl,
        decl:Modifiers(),
        nil, --[[typeParameters]]
        self:EmitContext():VisitParameters(decl.parameters, self:Visitor()),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        decl.equalsGreaterThanToken,
        self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:visitFunctionExpression(node)
    local decl = node:AsFunctionExpression()
    local savedEnclosingFunctionFlags = self.enclosingFunctionFlags
    self.enclosingFunctionFlags = ast.GetFunctionFlags(node)

    local modifiers
    if self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        modifiers = self:visitModifiersNoAsync(decl:Modifiers())
    else
        modifiers = decl:Modifiers()
    end

    local asteriskToken
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 then
        asteriskToken = nil
    else
        asteriskToken = decl.asteriskToken
    end

    local parameters
    local body
    if self.enclosingFunctionFlags & FunctionFlags.Async ~= 0 and self.enclosingFunctionFlags & FunctionFlags.Generator ~= 0 then
        parameters = self:transformAsyncGeneratorFunctionParameterList(node)
        body = self:transformAsyncGeneratorFunctionBody(node)
    else
        parameters = self:EmitContext():VisitParameters(decl.parameters, self:Visitor())
        body = self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
    end

    local updated = self:Factory():UpdateFunctionExpression(
        decl,
        modifiers,
        asteriskToken,
        decl:Name(),
        nil, --[[typeParameters]]
        parameters,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )
    self.enclosingFunctionFlags = savedEnclosingFunctionFlags
    return updated
end

function forawaitTransformer:transformAsyncGeneratorFunctionParameterList(node)
    if estransforms.isSimpleParameterList(node:Parameters()) then
        return self:EmitContext():VisitParameters(node:ParameterList(), self:Visitor())
    end
    -- Add fixed parameters to preserve the function's `length` property.
    local newParameters = {}
    for _, parameter in ipairs(node:Parameters() or {}) do
        local param = parameter:AsParameterDeclaration()
        if param.initializer ~= nil or param.dotDotDotToken ~= nil then
            break
        end
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

function forawaitTransformer:transformAsyncGeneratorFunctionBody(node)
    local f = self:Factory()
    local innerParameters
    if not estransforms.isSimpleParameterList(node:Parameters()) then
        innerParameters = self:EmitContext():VisitParameters(node:ParameterList(), self:Visitor())
    end

    local savedCapturedSuperProperties = self.capturedSuperProperties
    local savedHasSuperElementAccess = self.hasSuperElementAccess
    local savedHasSuperPropertyAssignment = self.hasSuperPropertyAssignment
    local savedSuperBinding = self.superBinding
    local savedSuperIndexBinding = self.superIndexBinding
    self.capturedSuperProperties = collections.NewOrderedSet()
    self.hasSuperElementAccess = false
    self.hasSuperPropertyAssignment = false
    self.superBinding = f:NewUniqueNameEx("_super", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
    self.superIndexBinding = f:NewUniqueNameEx("_superIndex", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })

    local asyncBody = f:UpdateBlock(
        node:Body():AsBlock(),
        self:Visitor():VisitNodes(node:Body():StatementList()),
        node:Body():AsBlock().multiLine
    )
    asyncBody = f:UpdateBlock(
        asyncBody:AsBlock(),
        self:EmitContext():EndAndMergeVariableEnvironmentList(asyncBody:StatementList()),
        asyncBody:AsBlock().multiLine
    )

    -- Substitute super property accesses with _super/_superIndex helpers
    local emitSuperHelpers = self.capturedSuperProperties:Size() > 0 or self.hasSuperElementAccess
    if emitSuperHelpers then
        asyncBody = self:substituteSuperAccessesInBody(asyncBody)
    end

    local innerParams
    if innerParameters ~= nil then
        innerParams = innerParameters
    else
        innerParams = f:NewNodeList({})
    end

    local name
    if node:Name() ~= nil then
        name = f:NewGeneratedNameForNode(node:Name())
    end

    local generatorFunc = f:NewFunctionExpression(
        nil, --[[modifiers]]
        f:NewToken(Kind.AsteriskToken),
        name,
        nil, --[[typeParameters]]
        innerParams,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        asyncBody
    )

    local returnStatement = f:NewReturnStatement(
        f:NewAsyncGeneratorHelper(
            generatorFunc,
            self.forAwaitHierarchyFacts & estransforms.forAwaitHierarchyFactsHasLexicalThis ~= 0
        )
    )

    self:EmitContext():StartVariableEnvironment()
    if emitSuperHelpers then
        if self.capturedSuperProperties:Size() > 0 then
            self:EmitContext():AddInitializationStatement(self:createSuperAccessVariableStatement())
        end
    end

    local outerStatements = { returnStatement }

    local block = f:UpdateBlock(
        node:Body():AsBlock(),
        self:EmitContext():EndAndMergeVariableEnvironmentList(f:NewNodeList(outerStatements)),
        node:Body():AsBlock().multiLine
    )

    if emitSuperHelpers and self.hasSuperElementAccess then
        if self.hasSuperPropertyAssignment then
            self:EmitContext():AddEmitHelper(block, printer.AdvancedAsyncSuperHelper)
        else
            self:EmitContext():AddEmitHelper(block, printer.AsyncSuperHelper)
        end
    end

    self.capturedSuperProperties = savedCapturedSuperProperties
    self.hasSuperElementAccess = savedHasSuperElementAccess
    self.hasSuperPropertyAssignment = savedHasSuperPropertyAssignment
    self.superBinding = savedSuperBinding
    self.superIndexBinding = savedSuperIndexBinding

    return block
end
