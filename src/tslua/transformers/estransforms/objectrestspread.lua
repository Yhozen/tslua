local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts
local EF = printer.EmitFlags
local FlattenLevel = transformers.FlattenLevel

-- Fields: compilerOptions, inExportedVariableStatement, expressionResultIsUnused,
-- parametersWithPrecedingObjectRestOrSpread (node -> true, or nil).
local objectRestSpreadTransformer = transformers.NewTransformerType()
estransforms.objectRestSpreadTransformer = objectRestSpreadTransformer

function objectRestSpreadTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsESObjectRestOrSpread == 0 and self.parametersWithPrecedingObjectRestOrSpread == nil then
        return node
    end
    -- Save the expressionResultIsUnused flag set by the parent for this node,
    -- then reset to false for children (the default). Specific cases below override as needed.
    local expressionResultIsUnused = self.expressionResultIsUnused
    self.expressionResultIsUnused = false
    local result = self:visitWorker(node, expressionResultIsUnused)
    self.expressionResultIsUnused = expressionResultIsUnused
    return result
end

-- Lua helper: the switch of Go's visit, run before the deferred restore of expressionResultIsUnused.
function objectRestSpreadTransformer:visitWorker(node, expressionResultIsUnused)
    local k = node.kind
    if k == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.ObjectLiteralExpression then
        return self:visitObjectLiteralExpression(node:AsObjectLiteralExpression())
    elseif k == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression(), expressionResultIsUnused)
    elseif k == Kind.ExpressionStatement then
        self.expressionResultIsUnused = true
        return self:Visitor():VisitEachChild(node)
    elseif k == Kind.ParenthesizedExpression then
        self.expressionResultIsUnused = expressionResultIsUnused
        return self:Visitor():VisitEachChild(node)
    elseif k == Kind.ForOfStatement then
        return self:visitForOftatement(node:AsForInOrOfStatement())
    elseif k == Kind.VariableStatement then
        return self:visitVariableStatement(node:AsVariableStatement())
    elseif k == Kind.VariableDeclaration then
        return self:visitVariableDeclaration(node:AsVariableDeclaration())
    elseif k == Kind.CatchClause then
        return self:visitCatchClause(node:AsCatchClause())
    elseif k == Kind.Parameter then
        return self:visitParameter(node:AsParameterDeclaration())
    elseif k == Kind.Constructor then
        return self:visitContructorDeclaration(node:AsConstructorDeclaration())
    elseif k == Kind.GetAccessor then
        return self:visitGetAccessorDeclaration(node:AsGetAccessorDeclaration())
    elseif k == Kind.SetAccessor then
        return self:visitSetAccessorDeclaration(node:AsSetAccessorDeclaration())
    elseif k == Kind.MethodDeclaration then
        return self:visitMethodDeclaration(node:AsMethodDeclaration())
    elseif k == Kind.FunctionDeclaration then
        return self:visitFunctionDeclaration(node:AsFunctionDeclaration())
    elseif k == Kind.ArrowFunction then
        return self:visitArrowFunction(node:AsArrowFunction())
    elseif k == Kind.FunctionExpression then
        return self:visitFunctionExpression(node:AsFunctionExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function objectRestSpreadTransformer:visitSourceFile(node)
    local visited = self:Visitor():VisitEachChild(node:AsNode())
    self:EmitContext():AddEmitHelper(visited:AsNode(), table.unpack(self:EmitContext():ReadEmitHelpers()))
    return visited
end

function objectRestSpreadTransformer:visitParameter(node)
    if self.parametersWithPrecedingObjectRestOrSpread ~= nil then
        if self.parametersWithPrecedingObjectRestOrSpread[node:AsNode()] then
            local name = node:Name()
            if ast.IsBindingPattern(name) then
                name = self:Factory():NewGeneratedNameForNode(node:AsNode())
            end
            return self:Factory():UpdateParameterDeclaration(
                node,
                nil,
                node.dotDotDotToken,
                name,
                nil,
                nil,
                nil
            )
        end
    end
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
        -- Binding patterns are converted into a generated name and are
        -- evaluated inside the function body.
        return self:Factory():UpdateParameterDeclaration(
            node,
            nil,
            node.dotDotDotToken,
            self:Factory():NewGeneratedNameForNode(node:AsNode()),
            nil,
            nil,
            self:Visitor():VisitNode(node.initializer)
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:collectParametersWithPrecedingObjectRestOrSpread(node)
    local result
    for _, parameter in ipairs(node:Parameters() or {}) do
        if result ~= nil then
            result[parameter] = true
        elseif parameter:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
            result = {}
        end
    end
    return result
end

-- oldParamScope: the saved parametersWithPrecedingObjectRestOrSpread map (or nil).

function objectRestSpreadTransformer:enterParameterListContext(node)
    local old = self.parametersWithPrecedingObjectRestOrSpread
    self.parametersWithPrecedingObjectRestOrSpread = self:collectParametersWithPrecedingObjectRestOrSpread(node)
    return old
end

function objectRestSpreadTransformer:exitParameterListContext(scope)
    self.parametersWithPrecedingObjectRestOrSpread = scope
end

function objectRestSpreadTransformer:visitContructorDeclaration(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateConstructorDeclaration(
        node,
        node:Modifiers(),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitGetAccessorDeclaration(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateGetAccessorDeclaration(
        node,
        node:Modifiers(),
        self:Visitor():VisitNode(node:Name()),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitSetAccessorDeclaration(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateSetAccessorDeclaration(
        node,
        node:Modifiers(),
        self:Visitor():VisitNode(node:Name()),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitMethodDeclaration(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateMethodDeclaration(
        node,
        node:Modifiers(),
        node.asteriskToken,
        self:Visitor():VisitNode(node:Name()),
        node.postfixToken,
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitFunctionDeclaration(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateFunctionDeclaration(
        node,
        node:Modifiers(),
        node.asteriskToken,
        self:Visitor():VisitNode(node:Name()),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitArrowFunction(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateArrowFunction(
        node,
        node:Modifiers(),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        node.equalsGreaterThanToken,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:visitFunctionExpression(node)
    local old = self:enterParameterListContext(node:AsNode())
    local result = self:Factory():UpdateFunctionExpression(
        node,
        node:Modifiers(),
        node.asteriskToken,
        self:Visitor():VisitNode(node:Name()),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:transformFunctionBody(node:AsNode())
    )
    self:exitParameterListContext(old)
    return result
end

function objectRestSpreadTransformer:transformFunctionBody(node)
    -- EmitContext().VisitFunctionBody is not used here because this transformer needs to inject
    -- object rest assignments between visiting the body and merging the variable environment.
    self:EmitContext():StartVariableEnvironment()
    local body = self:Visitor():VisitNode(node:Body())
    local extras = self:EmitContext():EndVariableEnvironment()
    self:EmitContext():StartVariableEnvironment()
    local newStatements = self:collectObjectRestAssignments(node)
    extras = self:EmitContext():EndAndMergeVariableEnvironment(extras)
    if #(newStatements or {}) == 0 and #(extras or {}) == 0 then
        return body
    end

    if body == nil then
        body = self:Factory():NewBlock(self:Factory():NewNodeList({}), true)
    end
    local prefix = {}
    local suffix = {}
    if ast.IsBlock(body) then
        local custom = false
        local bodyStatements = body:Statements() or {}
        for i1, statement in ipairs(bodyStatements) do
            local i = i1 - 1
            if not custom and ast.IsPrologueDirective(statement) then
                prefix[#prefix + 1] = statement
            elseif self:EmitContext():EmitFlags(statement) & EF.EFCustomPrologue ~= 0 then
                custom = true
                prefix[#prefix + 1] = statement
            else
                suffix = core.Slice(bodyStatements, i, #bodyStatements)
                break
            end
        end
    else
        local ret = self:Factory():NewReturnStatement(body)
        ret.loc = body.loc
        local list = self:Factory():NewNodeList({})
        list.loc = body.loc
        body = self:Factory():NewBlock(list, true)
        suffix[#suffix + 1] = ret
    end

    local all = {}
    for _, s in ipairs(prefix) do
        all[#all + 1] = s
    end
    for _, s in ipairs(extras or {}) do
        all[#all + 1] = s
    end
    for _, s in ipairs(newStatements or {}) do
        all[#all + 1] = s
    end
    for _, s in ipairs(suffix) do
        all[#all + 1] = s
    end
    local newStatementList = self:Factory():NewNodeList(all)
    newStatementList.loc = body:StatementList().loc
    return self:Factory():UpdateBlock(body:AsBlock(), newStatementList, body:AsBlock().multiLine)
end

function objectRestSpreadTransformer:collectObjectRestAssignments(node)
    local containsPrecedingObjectRestOrSpread = false
    local results = {}
    for _, parameter in ipairs(node:Parameters() or {}) do
        if containsPrecedingObjectRestOrSpread then
            if ast.IsBindingPattern(parameter:Name()) then
                -- In cases where a binding pattern is simply '[]' or '{}',
                -- we usually don't want to emit a var declaration; however, in the presence
                -- of an initializer, we must emit that expression to preserve side effects.
                if #(parameter:Name():Elements() or {}) > 0 then
                    local declarations = transformers.FlattenDestructuringBinding(
                        self,
                        parameter, self:Factory():NewGeneratedNameForNode(parameter),
                        FlattenLevel.All, false, false
                    )
                    if declarations ~= nil then
                        local declarationList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({}), NodeFlags.None)
                        local decls = { declarations }
                        if declarations.kind == Kind.SyntaxList then
                            decls = declarations:AsSyntaxList().children
                        end
                        local declarationListNodes = declarationList:AsVariableDeclarationList().declarations.nodes
                        for _, d in ipairs(decls or {}) do
                            declarationListNodes[#declarationListNodes + 1] = d
                        end
                        local statement = self:Factory():NewVariableStatement(nil, declarationList)
                        self:EmitContext():AddEmitFlags(statement, EF.EFCustomPrologue)
                        results[#results + 1] = statement
                    end
                elseif parameter:Initializer() ~= nil then
                    local name = self:Factory():NewGeneratedNameForNode(parameter)
                    local initializer = self:Visitor():VisitNode(parameter:Initializer())
                    local assignment = self:Factory():NewAssignmentExpression(name, initializer)
                    local statement = self:Factory():NewExpressionStatement(assignment)
                    self:EmitContext():AddEmitFlags(statement, EF.EFCustomPrologue)
                    results[#results + 1] = statement
                end
            elseif parameter:Initializer() ~= nil then
                -- Converts a parameter initializer into a function body statement, i.e.:
                --
                --  function f(x = 1) { }
                --
                -- becomes
                --
                --  function f(x) {
                --    if (typeof x === "undefined") { x = 1; }
                --  }
                local name = parameter:Name():Clone(self:Factory())
                name.loc = parameter:Name().loc
                self:EmitContext():AddEmitFlags(name, EF.EFNoSourceMap)

                local initializer = self:Visitor():VisitNode(parameter:Initializer())
                self:EmitContext():AddEmitFlags(initializer, EF.EFNoSourceMap | EF.EFNoComments)

                local assignment = self:Factory():NewAssignmentExpression(name, initializer)
                assignment.loc = parameter.loc
                self:EmitContext():AddEmitFlags(assignment, EF.EFNoComments)

                local block = self:Factory():NewBlock(self:Factory():NewNodeList({ self:Factory():NewExpressionStatement(assignment) }), false)
                block.loc = parameter.loc
                self:EmitContext():AddEmitFlags(block, EF.EFSingleLine | EF.EFNoTrailingSourceMap | EF.EFNoTokenSourceMaps | EF.EFNoComments)

                local typeCheck = self:Factory():NewTypeCheck(name:Clone(self:Factory()), "undefined")
                local statement = self:Factory():NewIfStatement(typeCheck, block, nil)
                statement.loc = parameter.loc
                self:EmitContext():AddEmitFlags(statement, EF.EFNoTokenSourceMaps | EF.EFNoTrailingSourceMap | EF.EFCustomPrologue | EF.EFNoComments | EF.EFStartOnNewLine)
                results[#results + 1] = statement
            end
        elseif parameter:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
            containsPrecedingObjectRestOrSpread = true
            local declarations = transformers.FlattenDestructuringBinding(
                self,
                parameter, self:Factory():NewGeneratedNameForNode(parameter),
                FlattenLevel.ObjectRest, false, true
            )
            if declarations ~= nil then
                local declarationList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({}), NodeFlags.None)
                local decls = { declarations }
                if declarations.kind == Kind.SyntaxList then
                    decls = declarations:AsSyntaxList().children
                end
                local declarationListNodes = declarationList:AsVariableDeclarationList().declarations.nodes
                for _, d in ipairs(decls or {}) do
                    declarationListNodes[#declarationListNodes + 1] = d
                end
                local statement = self:Factory():NewVariableStatement(nil, declarationList)
                self:EmitContext():AddEmitFlags(statement, EF.EFCustomPrologue)
                results[#results + 1] = statement
            end
        end
    end

    return results
end

function objectRestSpreadTransformer:visitCatchClause(node)
    if node.variableDeclaration ~= nil and ast.IsBindingPattern(node.variableDeclaration:Name()) and node.variableDeclaration:Name():SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
        local name = self:Factory():NewGeneratedNameForNode(node.variableDeclaration:Name())
        local updatedDecl = self:Factory():UpdateVariableDeclaration(node.variableDeclaration:AsVariableDeclaration(), node.variableDeclaration:Name(), nil, nil, name)
        local visitedBindings = transformers.FlattenDestructuringBinding(
            self,
            updatedDecl, nil,
            FlattenLevel.ObjectRest, false, false
        )
        local block = self:Visitor():VisitNode(node.block)
        if visitedBindings ~= nil then
            local decls
            if visitedBindings.kind == Kind.SyntaxList then
                decls = visitedBindings:AsSyntaxList().children
            else
                decls = { visitedBindings }
            end
            local newStatement = self:Factory():NewVariableStatement(nil, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList(decls), NodeFlags.None))
            local statements = { newStatement }
            for _, s in ipairs(block:Statements() or {}) do
                statements[#statements + 1] = s
            end
            local statementList = self:Factory():NewNodeList(statements)
            statementList.loc = block:StatementList().loc

            block = self:Factory():UpdateBlock(block:AsBlock(), statementList, block:AsBlock().multiLine)
        end
        return self:Factory():UpdateCatchClause(
            node,
            self:Factory():UpdateVariableDeclaration(node.variableDeclaration:AsVariableDeclaration(), name, nil, nil, nil),
            block
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:visitVariableStatement(node)
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export) then
        local oldInExportedVariableStatement = self.inExportedVariableStatement
        self.inExportedVariableStatement = true
        local result = self:Visitor():VisitEachChild(node:AsNode())
        self.inExportedVariableStatement = oldInExportedVariableStatement
        return result
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:visitVariableDeclaration(node)
    if self.inExportedVariableStatement then
        self.inExportedVariableStatement = false
        local result = self:visitVariableDeclarationWorker(node, true)
        self.inExportedVariableStatement = true
        return result
    end
    return self:visitVariableDeclarationWorker(node, false)
end

function objectRestSpreadTransformer:visitVariableDeclarationWorker(node, exported)
    -- If we are here it is because the name contains a binding pattern with a rest somewhere in it.
    if ast.IsBindingPattern(node:Name()) and node:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
        return transformers.FlattenDestructuringBinding(
            self,
            node:AsNode(), nil,
            FlattenLevel.ObjectRest, exported, false
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:visitForOftatement(node)
    if node.initializer:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 or (ast.IsAssignmentPattern(node.initializer) and ast.ContainsObjectRestOrSpread(node.initializer)) then
        local initializerWithoutParens = ast.SkipParentheses(node.initializer)
        if ast.IsVariableDeclarationList(initializerWithoutParens) or ast.IsAssignmentPattern(initializerWithoutParens) then
            local bodyLocation = core.NewTextRange(0, 0)
            local statementsLocation = core.NewTextRange(0, 0)
            local temp = self:Factory():NewTempVariable()
            local res = self:Visitor():VisitNode(self:Factory():CreateForOfBindingStatement(initializerWithoutParens, temp))
            local statements = {}
            if res ~= nil then
                statements[#statements + 1] = res
            end
            if ast.IsBlock(node.statement) then
                for _, statement in ipairs(node.statement:Statements() or {}) do
                    local visited = self:Visitor():VisitEachChild(statement)
                    if visited ~= nil then
                        statements[#statements + 1] = visited
                    end
                end
                bodyLocation = node.statement.loc
                statementsLocation = node.statement:StatementList().loc
            elseif node.statement ~= nil then
                statements[#statements + 1] = self:Visitor():VisitEachChild(node.statement)
                bodyLocation = node.statement.loc
                statementsLocation = node.statement.loc
            end

            local list = self:Factory():NewVariableDeclarationList(
                self:Factory():NewNodeList({ self:Factory():NewVariableDeclaration(temp, nil, nil, nil) }),
                NodeFlags.Let
            )
            list.loc = node.initializer.loc

            local expr = self:Visitor():VisitEachChild(node.expression)

            local statementsList = self:Factory():NewNodeList(statements)
            statementsList.loc = statementsLocation

            local block = self:Factory():NewBlock(statementsList, true)
            block.loc = bodyLocation

            return self:Factory():UpdateForInOrOfStatement(
                node,
                node.awaitModifier,
                list,
                expr,
                block
            )
        end
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:visitBinaryExpression(node, expressionResultIsUnused)
    if ast.IsDestructuringAssignment(node:AsNode()) and ast.ContainsObjectRestOrSpread(node.left) then
        return transformers.FlattenDestructuringAssignment(
            self,
            node:AsNode(), not expressionResultIsUnused,
            FlattenLevel.ObjectRest, nil
        )
    end
    if node.operatorToken.kind == Kind.CommaToken then
        self.expressionResultIsUnused = true
        local left = self:Visitor():VisitNode(node.left)
        self.expressionResultIsUnused = expressionResultIsUnused
        local right = self:Visitor():VisitNode(node.right)
        return self:Factory():UpdateBinaryExpression(node, nil, left, nil, node.operatorToken, right)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function objectRestSpreadTransformer:visitObjectLiteralExpression(node)
    if (node:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread) == 0 then
        return self:Visitor():VisitEachChild(node:AsNode())
    end
    -- spread elements emit like so:
    -- non-spread elements are chunked together into object literals, and then all are passed to __assign:
    --     { a, ...o, b } => __assign(__assign({a}, o), {b});
    -- If the first element is a spread element, then the first argument to __assign is {}:
    --     { ...o, a, b, ...o2 } => __assign(__assign(__assign({}, o), {a, b}), o2)
    --
    -- We cannot call __assign with more than two elements, since any element could cause side effects. For
    -- example:
    --      var k = { a: 1, b: 2 };
    --      var o = { a: 3, ...k, b: k.a++ };
    --      // expected: { a: 1, b: 1 }
    -- If we translate the above to `__assign({ a: 3 }, k, { b: k.a++ })`, the `k.a++` will evaluate before
    -- `k` is spread and we end up with `{ a: 2, b: 1 }`.
    --
    -- This also occurs for spread elements, not just property assignments:
    --      var k = { a: 1, get b() { l = { z: 9 }; return 2; } };
    --      var l = { c: 3 };
    --      var o = { ...k, ...l };
    --      // expected: { a: 1, b: 2, z: 9 }
    -- If we translate the above to `__assign({}, k, l)`, the `l` will evaluate before `k` is spread and we
    -- end up with `{ a: 1, b: 2, c: 3 }`

    local objects = self:chunkObjectLiteralElements(node.properties) or {}
    if #objects > 0 and objects[1].kind ~= Kind.ObjectLiteralExpression then
        table.insert(objects, 1, self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(nil), false))
    end
    local expression = objects[1]
    if #objects > 1 then
        for i1, obj in ipairs(objects) do
            if i1 ~= 1 then
                expression = self:Factory():NewAssignHelper({ expression, obj }, self.compilerOptions:GetEmitScriptTarget())
            end
        end
        return expression
    end
    return self:Factory():NewAssignHelper(objects, self.compilerOptions:GetEmitScriptTarget())
end

function objectRestSpreadTransformer:chunkObjectLiteralElements(list)
    if list == nil or #(list.nodes or {}) == 0 then
        return nil
    end
    local elements = list.nodes
    local chunkObject = {}
    local objects = {}
    for _, e in ipairs(elements) do
        if e.kind == Kind.SpreadAssignment then
            if #chunkObject > 0 then
                objects[#objects + 1] = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(chunkObject), false)
                chunkObject = {}
            end
            local target = e:Expression()
            objects[#objects + 1] = self:Visitor():VisitNode(target)
        else
            local elem
            if e.kind == Kind.PropertyAssignment then
                elem = self:Factory():NewPropertyAssignment(nil, e:Name(), nil, nil, self:Visitor():VisitNode(e:Initializer()))
            else
                elem = self:Visitor():VisitNode(e)
            end
            chunkObject[#chunkObject + 1] = elem
        end
    end
    if #chunkObject > 0 then
        objects[#objects + 1] = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(chunkObject), false)
    end
    return objects
end

function estransforms.newObjectRestSpreadTransformer(opts)
    local tx = setmetatable({
        compilerOptions = opts.compilerOptions,
        inExportedVariableStatement = false,
        expressionResultIsUnused = false,
    }, objectRestSpreadTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
