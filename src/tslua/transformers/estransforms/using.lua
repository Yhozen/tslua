local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts
local EF = printer.EmitFlags

-- Fields: exportBindings (name -> ExportSpecifier), exportBindingNames ([]string), exportVars,
-- defaultExportBinding, exportEqualsBinding.
local usingDeclarationTransformer = transformers.NewTransformerType()
estransforms.usingDeclarationTransformer = usingDeclarationTransformer

function estransforms.newUsingDeclarationTransformer(opts)
    local tx = setmetatable({}, usingDeclarationTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end

-- usingKind
estransforms.usingKindNone = 0
estransforms.usingKindSync = 1
estransforms.usingKindAsync = 2

function usingDeclarationTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsUsing == 0 then
        return node
    end

    local k = node.kind
    if k == Kind.SourceFile then
        node = self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.Block then
        node = self:visitBlock(node:AsBlock())
    elseif k == Kind.ForStatement then
        node = self:visitForStatement(node:AsForStatement())
    elseif k == Kind.ForOfStatement then
        node = self:visitForOfStatement(node:AsForInOrOfStatement())
    else
        node = self:Visitor():VisitEachChild(node)
    end
    return node
end

function usingDeclarationTransformer:visitSourceFile(node)
    if node.isDeclarationFile then
        return node:AsNode()
    end

    local visited
    local usingKind = estransforms.getUsingKindOfStatements(node.statements.nodes)
    if usingKind ~= estransforms.usingKindNone then
        -- Imports and exports must stay at the top level. This means we must hoist all imports, exports, and
        -- top-level function declarations and bindings out of the `try` statements we generate. For example:
        --
        -- given:
        --
        --  import { w } from "mod";
        --  const x = expr1;
        --  using y = expr2;
        --  const z = expr3;
        --  export function f() {
        --    console.log(z);
        --  }
        --
        -- produces:
        --
        --  import { x } from "mod";        // <-- preserved
        --  const x = expr1;                // <-- preserved
        --  var y, z;                       // <-- hoisted
        --  export function f() {           // <-- hoisted
        --    console.log(z);
        --  }
        --  const env_1 = { stack: [], error: void 0, hasError: false };
        --  try {
        --    y = __addDisposableResource(env_1, expr2, false);
        --    z = expr3;
        --  }
        --  catch (e_1) {
        --    env_1.error = e_1;
        --    env_1.hasError = true;
        --  }
        --  finally {
        --    __disposeResource(env_1);
        --  }
        --
        -- In this transformation, we hoist `y`, `z`, and `f` to a new outer statement list while moving all other
        -- statements in the source file into the `try` block, which is the same approach we use for System module
        -- emit. Unlike System module emit, we attempt to preserve all statements prior to the first top-level
        -- `using` to isolate the complexity of the transformed output to only where it is necessary.
        self:EmitContext():StartVariableEnvironment()

        self.exportBindings = {}
        self.exportVars = nil

        local prologue, rest = self:Factory():SplitStandardPrologue(node.statements.nodes)
        rest = rest or {}
        local topLevelStatements = {}
        for _, s in ipairs((self:Visitor():VisitSlice(prologue)) or {}) do
            topLevelStatements[#topLevelStatements + 1] = s
        end

        -- Collect and transform any leading statements up to the first `using` or `await using`. This preserves
        -- the original statement order much as is possible.

        local pos = 0
        while pos < #rest do
            local statement = rest[pos + 1]
            if estransforms.getUsingKind(statement) ~= estransforms.usingKindNone then
                if pos > 0 then
                    for _, s in ipairs((self:Visitor():VisitSlice(core.Slice(rest, 0, pos))) or {}) do
                        topLevelStatements[#topLevelStatements + 1] = s
                    end
                end
                break
            end
            pos = pos + 1
        end

        if pos >= #rest then
            error("Should have encountered at least one 'using' statement.", 0)
        end

        -- transform the rest of the body
        local envBinding = self:createEnvBinding()
        local bodyStatements = self:transformUsingDeclarations(core.Slice(rest, pos, #rest), envBinding, topLevelStatements)

        -- add `export {}` declarations for any hoisted bindings.
        if next(self.exportBindings) ~= nil then
            local exportSpecifiers = {}
            for _, name in ipairs(self.exportBindingNames or {}) do
                local specifier = self.exportBindings[name]
                debug.Assert(specifier ~= nil, "Missing export binding for hoisted export name")
                exportSpecifiers[#exportSpecifiers + 1] = specifier
            end
            topLevelStatements[#topLevelStatements + 1] = self:Factory():NewExportDeclaration(
                nil, --[[modifiers]]
                false, --[[isTypeOnly]]
                self:Factory():NewNamedExports(
                    self:Factory():NewNodeList(
                        exportSpecifiers
                    )
                ),
                nil, --[[moduleSpecifier]]
                nil --[[attributes]]
            )
        end

        for _, s in ipairs(self:EmitContext():EndVariableEnvironment() or {}) do
            topLevelStatements[#topLevelStatements + 1] = s
        end
        if #(self.exportVars or {}) > 0 then
            topLevelStatements[#topLevelStatements + 1] = self:Factory():NewVariableStatement(
                self:Factory():NewModifierList({
                    self:Factory():NewModifier(Kind.ExportKeyword),
                }),
                self:Factory():NewVariableDeclarationList(
                    self:Factory():NewNodeList(self.exportVars),
                    NodeFlags.Let
                )
            )
        end
        for _, s in ipairs(self:createDownlevelUsingStatements(bodyStatements, envBinding, usingKind == estransforms.usingKindAsync)) do
            topLevelStatements[#topLevelStatements + 1] = s
        end

        if self.exportEqualsBinding ~= nil then
            topLevelStatements[#topLevelStatements + 1] = self:Factory():NewExportAssignment(
                nil, --[[modifiers]]
                true, --[[isExportEquals]]
                nil, --[[typeNode]]
                self.exportEqualsBinding
            )
        end

        visited = self:Factory():UpdateSourceFile(node, self:Factory():NewNodeList(topLevelStatements), node.endOfFileToken)
    else
        visited = self:Visitor():VisitEachChild(node:AsNode())
    end
    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers()))
    self.exportVars = nil
    self.exportBindings = nil
    self.exportBindingNames = nil
    self.defaultExportBinding = nil
    self.exportEqualsBinding = nil
    return visited
end

function usingDeclarationTransformer:visitBlock(node)
    local usingKind = estransforms.getUsingKindOfStatements(node.statements.nodes)
    if usingKind ~= estransforms.usingKindNone then
        local prologue, rest = self:Factory():SplitStandardPrologue(node.statements.nodes)
        local envBinding = self:createEnvBinding()
        local statements = {}
        for _, s in ipairs((self:Visitor():VisitSlice(prologue)) or {}) do
            statements[#statements + 1] = s
        end
        for _, s in ipairs(self:createDownlevelUsingStatements(
            self:transformUsingDeclarations(rest, envBinding, nil --[[topLevelStatements]]),
            envBinding,
            usingKind == estransforms.usingKindAsync
        )) do
            statements[#statements + 1] = s
        end
        local statementList = self:Factory():NewNodeList(statements)
        statementList.loc = node.statements.loc
        return self:Factory():UpdateBlock(node, statementList, node.multiLine)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function usingDeclarationTransformer:visitForStatement(node)
    if node.initializer ~= nil and estransforms.isUsingVariableDeclarationList(node.initializer) then
        -- given:
        --
        --  for (using x = expr; cond; incr) { ... }
        --
        -- produces a shallow transformation to:
        --
        --  {
        --    using x = expr;
        --    for (; cond; incr) { ... }
        --  }
        --
        -- before handing the shallow transformation back to the visitor for an in-depth transformation.
        return self:Visitor():VisitNode(
            self:Factory():NewBlock(self:Factory():NewNodeList({
                self:Factory():NewVariableStatement(nil --[[modifiers]], node.initializer),
                self:Factory():UpdateForStatement(
                    node,
                    nil, --[[initializer]]
                    node.condition,
                    node.incrementor,
                    node.statement
                ),
            }), false --[[multiLine]])
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function usingDeclarationTransformer:visitForOfStatement(node)
    if estransforms.isUsingVariableDeclarationList(node.initializer) then
        -- given:
        --
        --  for (using x of y) { ... }
        --
        -- produces a shallow transformation to:
        --
        --  for (const x_1 of y) {
        --    using x = x;
        --    ...
        --  }
        --
        -- before handing the shallow transformation back to the visitor for an in-depth transformation.
        local forInitializer = node.initializer:AsVariableDeclarationList()
        local forDecl = core.FirstOrNil(forInitializer.declarations.nodes)
        if forDecl == nil then
            forDecl = self:Factory():NewVariableDeclaration(self:Factory():NewTempVariable(), nil, nil, nil)
        end

        local isAwaitUsing = estransforms.getUsingKindOfVariableDeclarationList(forInitializer) == estransforms.usingKindAsync
        local temp = self:Factory():NewGeneratedNameForNode(forDecl:Name())
        local usingVar = self:Factory():UpdateVariableDeclaration(forDecl:AsVariableDeclaration(), forDecl:Name(), nil --[[exclamationToken]], nil --[[type]], temp)
        local usingVarList = self:Factory():NewVariableDeclarationList(
            self:Factory():NewNodeList({ usingVar }),
            core.IfElse(isAwaitUsing, NodeFlags.AwaitUsing, NodeFlags.Using)
        )
        local usingVarStatement = self:Factory():NewVariableStatement(nil --[[modifiers]], usingVarList)
        local statement
        if ast.IsBlock(node.statement) then
            local statements = { usingVarStatement }
            for _, s in ipairs(node.statement:Statements() or {}) do
                statements[#statements + 1] = s
            end
            statement = self:Factory():UpdateBlock(
                node.statement:AsBlock(),
                self:Factory():NewNodeList(statements),
                node.statement:AsBlock().multiLine
            )
        else
            statement = self:Factory():NewBlock(
                self:Factory():NewNodeList({
                    usingVarStatement,
                    node.statement,
                }),
                true --[[multiLine]]
            )
        end
        return self:Visitor():VisitNode(
            self:Factory():UpdateForInOrOfStatement(
                node,
                node.awaitModifier,
                self:Factory():NewVariableDeclarationList(
                    self:Factory():NewNodeList({
                        self:Factory():NewVariableDeclaration(temp, nil --[[exclamationToken]], nil --[[type]], nil),
                    }),
                    NodeFlags.Const
                ),
                node.expression,
                statement
            )
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- topLevelStatements is a Lua array appended to in place (Go *[]*ast.Statement), or nil.
function usingDeclarationTransformer:transformUsingDeclarations(statementsIn, envBinding, topLevelStatements)
    local statements = {}

    local function hoist(node)
        if topLevelStatements == nil then
            return node
        end

        local k = node.kind
        if k == Kind.ImportDeclaration or
            k == Kind.ImportEqualsDeclaration or
            k == Kind.ExportDeclaration or
            k == Kind.FunctionDeclaration then
            self:hoistImportOrExportOrHoistedDeclaration(node, topLevelStatements)
            return nil
        elseif k == Kind.ExportAssignment then
            return self:hoistExportAssignment(node:AsExportAssignment())
        elseif k == Kind.ClassDeclaration then
            return self:hoistClassDeclaration(node:AsClassDeclaration())
        elseif k == Kind.VariableStatement then
            return self:hoistVariableStatement(node:AsVariableStatement())
        end

        return node
    end

    local function hoistOrAppendNode(node)
        node = hoist(node)
        if node ~= nil then
            statements[#statements + 1] = node
        end
    end

    for _, statement in ipairs(statementsIn or {}) do
        local usingKind = estransforms.getUsingKind(statement)
        local replaced = false
        if usingKind ~= estransforms.usingKindNone then
            local varStatement = statement:AsVariableStatement()
            local declarationList = varStatement.declarationList
            local declarations = {}
            for _, declaration in ipairs(declarationList:AsVariableDeclarationList().declarations.nodes) do
                if not ast.IsIdentifier(declaration:Name()) then
                    -- Since binding patterns are a grammar error, we reset `declarations` so we don't process this as a `using`.
                    declarations = {}
                    break
                end

                -- perform a shallow transform for any named evaluation
                if estransforms.isNamedEvaluation(self:EmitContext(), declaration) then
                    declaration = estransforms.transformNamedEvaluation(self:EmitContext(), declaration, false --[[ignoreEmptyStringLiteral]], "" --[[assignedName]])
                end

                local initializer = self:Visitor():VisitNode(declaration:Initializer())
                if initializer == nil then
                    initializer = self:Factory():NewVoidZeroExpression()
                end
                declarations[#declarations + 1] = self:Factory():UpdateVariableDeclaration(
                    declaration:AsVariableDeclaration(),
                    declaration:Name(),
                    nil, --[[exclamationToken]]
                    nil, --[[type]]
                    self:Factory():NewAddDisposableResourceHelper(
                        envBinding,
                        initializer,
                        usingKind == estransforms.usingKindAsync
                    )
                )
            end

            -- Only replace the statement if it was valid.
            if #declarations > 0 then
                local varList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList(declarations), NodeFlags.Const)
                self:EmitContext():SetOriginal(varList, declarationList)
                varList.loc = declarationList.loc
                hoistOrAppendNode(self:Factory():UpdateVariableStatement(varStatement, nil --[[modifiers]], varList))
                replaced = true
            end
        end

        if not replaced then
            local result = self:visit(statement)
            if result ~= nil then
                if result.kind == Kind.SyntaxList then
                    for _, node in ipairs(result:AsSyntaxList().children or {}) do
                        hoistOrAppendNode(node)
                    end
                else
                    hoistOrAppendNode(result)
                end
            end
        end
    end
    return statements
end

function usingDeclarationTransformer:hoistImportOrExportOrHoistedDeclaration(node, topLevelStatements)
    -- NOTE: `node` has already been visited
    topLevelStatements[#topLevelStatements + 1] = node
end

function usingDeclarationTransformer:hoistExportAssignment(node)
    if node.isExportEquals then
        return self:hoistExportEquals(node)
    else
        return self:hoistExportDefault(node)
    end
end

function usingDeclarationTransformer:hoistExportDefault(node)
    -- NOTE: `node` has already been visited
    if self.defaultExportBinding ~= nil then
        -- invalid case of multiple `export default` declarations. Don't assert here, just pass it through
        return node:AsNode()
    end

    -- given:
    --
    --   export default expr;
    --
    -- produces:
    --
    --   // top level
    --   var default_1;
    --   export { default_1 as default };
    --
    --   // body
    --   default_1 = expr;

    self.defaultExportBinding = self:Factory():NewUniqueNameEx("_default", { flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes | printer.GeneratedIdentifierFlagsFileLevel | printer.GeneratedIdentifierFlagsOptimistic })
    self:hoistBindingIdentifier(self.defaultExportBinding, true --[[isExport]], self:Factory():NewIdentifier("default"), node:AsNode())

    -- give a class or function expression an assigned name, if needed.
    local expression = node.expression
    local innerExpression = ast.SkipOuterExpressions(expression, ast.OuterExpressionKinds.OEKAll)
    if estransforms.isNamedEvaluation(self:EmitContext(), innerExpression) then
        innerExpression = estransforms.transformNamedEvaluation(self:EmitContext(), innerExpression, false --[[ignoreEmptyStringLiteral]], "default")
        expression = self:Factory():RestoreOuterExpressions(expression, innerExpression, ast.OuterExpressionKinds.OEKAll)
    end

    local assignment = self:Factory():NewAssignmentExpression(self.defaultExportBinding, expression)
    return self:Factory():NewExpressionStatement(assignment)
end

function usingDeclarationTransformer:hoistExportEquals(node)
    -- NOTE: `node` has already been visited
    if self.exportEqualsBinding ~= nil then
        -- invalid case of multiple `export default` declarations. Don't assert here, just pass it through
        return node:AsNode()
    end

    -- given:
    --
    --   export = expr;
    --
    -- produces:
    --
    --   // top level
    --   var default_1;
    --
    --   try {
    --       // body
    --       default_1 = expr;
    --   } ...
    --
    --   // top level suffix
    --   export = default_1;

    self.exportEqualsBinding = self:Factory():NewUniqueNameEx("_default", { flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes | printer.GeneratedIdentifierFlagsFileLevel | printer.GeneratedIdentifierFlagsOptimistic })
    self:EmitContext():AddVariableDeclaration(self.exportEqualsBinding)

    -- give a class or function expression an assigned name, if needed.
    local assignment = self:Factory():NewAssignmentExpression(self.exportEqualsBinding, node.expression)
    return self:Factory():NewExpressionStatement(assignment)
end

function usingDeclarationTransformer:hoistClassDeclaration(node)
    -- NOTE: `node` has already been visited
    if node:Name() == nil and self.defaultExportBinding ~= nil then
        -- invalid case of multiple `export default` declarations. Don't assert here, just pass it through
        return node:AsNode()
    end

    local isExported = ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export)
    local isDefault = ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Default)

    -- When hoisting a class declaration at the top level of a file containing a top-level `using` statement, we
    -- must first convert it to a class expression so that we can hoist the binding outside of the `try`.
    local expression = estransforms.convertClassDeclarationToClassExpression(self:EmitContext(), node)
    if node:Name() ~= nil then
        -- given:
        --
        --  using x = expr;
        --  class C {}
        --
        -- produces:
        --
        --  var x, C;
        --  const env_1 = { ... };
        --  try {
        --    x = __addDisposableResource(env_1, expr, false);
        --    C = class {};
        --  }
        --  catch (e_1) {
        --    env_1.error = e_1;
        --    env_1.hasError = true;
        --  }
        --  finally {
        --    __disposeResources(env_1);
        --  }
        --
        -- If the class is exported, we also produce an `export { C };`
        self:hoistBindingIdentifier(self:Factory():GetLocalName(node:AsNode()), isExported and not isDefault, nil --[[exportAlias]], node:AsNode())
        expression = self:Factory():NewAssignmentExpression(self:Factory():GetDeclarationName(node:AsNode()), expression)
        self:EmitContext():SetOriginal(expression, node:AsNode())
        self:EmitContext():SetSourceMapRange(expression, node.loc)
        self:EmitContext():SetCommentRange(expression, node.loc)
        if estransforms.isNamedEvaluation(self:EmitContext(), expression) then
            expression = estransforms.transformNamedEvaluation(self:EmitContext(), expression, false --[[ignoreEmptyStringLiteral]], "" --[[assignedName]])
        end
    end

    if isDefault and self.defaultExportBinding == nil then
        -- In the case of a default export, we create a temporary variable that we export as the default and then
        -- assign to that variable.
        --
        -- given:
        --
        --  using x = expr;
        --  export default class C {}
        --
        -- produces:
        --
        --  export { default_1 as default };
        --  var x, C, default_1;
        --  const env_1 = { ... };
        --  try {
        --    x = __addDisposableResource(env_1, expr, false);
        --    default_1 = C = class {};
        --  }
        --  catch (e_1) {
        --    env_1.error = e_1;
        --    env_1.hasError = true;
        --  }
        --  finally {
        --    __disposeResources(env_1);
        --  }
        --
        -- Though we will never reassign `default_1`, this most closely matches the specified runtime semantics.
        self.defaultExportBinding = self:Factory():NewUniqueNameEx("_default", { flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes | printer.GeneratedIdentifierFlagsFileLevel | printer.GeneratedIdentifierFlagsOptimistic })
        self:hoistBindingIdentifier(self.defaultExportBinding, true --[[isExport]], self:Factory():NewIdentifier("default"), node:AsNode())
        expression = self:Factory():NewAssignmentExpression(self.defaultExportBinding, expression)
        self:EmitContext():SetOriginal(expression, node:AsNode())
        if estransforms.isNamedEvaluation(self:EmitContext(), expression) then
            expression = estransforms.transformNamedEvaluation(self:EmitContext(), expression, false --[[ignoreEmptyStringLiteral]], "default")
        end
    end

    return self:Factory():NewExpressionStatement(expression)
end

function usingDeclarationTransformer:hoistVariableStatement(node)
    -- NOTE: `node` has already been visited
    local expressions = {}
    local isExported = ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export)
    for _, variable in ipairs(node.declarationList:AsVariableDeclarationList().declarations.nodes) do
        self:hoistBindingElement(variable, isExported, variable)
        if variable:Initializer() ~= nil then
            expressions[#expressions + 1] = self:hoistInitializedVariable(variable:AsVariableDeclaration())
        end
    end
    if #expressions > 0 then
        local statement = self:Factory():NewExpressionStatement(self:Factory():InlineExpressions(expressions))
        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():SetCommentRange(statement, node.loc)
        self:EmitContext():SetSourceMapRange(statement, node.loc)
        return statement
    end
    return nil
end

function usingDeclarationTransformer:hoistInitializedVariable(node)
    -- NOTE: `node` has already been visited
    if node.initializer == nil then
        error("Expected initializer", 0)
    end
    local target
    if ast.IsIdentifier(node:Name()) then
        target = node:Name():Clone(self:Factory())
        self:EmitContext():SetEmitFlags(target, self:EmitContext():EmitFlags(target) & ~(EF.EFLocalName | EF.EFExportName))
    else
        target = transformers.ConvertBindingPatternToAssignmentPattern(self:EmitContext(), node:Name():AsBindingPattern())
    end

    local assignment = self:Factory():NewAssignmentExpression(target, node.initializer)
    self:EmitContext():SetOriginal(assignment, node:AsNode())
    self:EmitContext():SetCommentRange(assignment, node.loc)
    self:EmitContext():SetSourceMapRange(assignment, node.loc)
    return assignment
end

function usingDeclarationTransformer:hoistBindingElement(node --[[VariableDeclaration|BindingElement]], isExportedDeclaration, original)
    -- NOTE: `node` has already been visited
    if ast.IsBindingPattern(node:Name()) then
        for _, element in ipairs(node:Name():Elements() or {}) do
            if element:Name() ~= nil then
                self:hoistBindingElement(element, isExportedDeclaration, original)
            end
        end
    else
        self:hoistBindingIdentifier(node:Name(), isExportedDeclaration, nil --[[exportAlias]], original)
    end
end

function usingDeclarationTransformer:hoistBindingIdentifier(node, isExport, exportAlias, original)
    -- NOTE: `node` has already been visited
    local name = node
    if not transformers.IsGeneratedIdentifier(self:EmitContext(), node) then
        name = name:Clone(self:Factory())
    end
    if isExport then
        if exportAlias == nil and not transformers.IsLocalName(self:EmitContext(), name) then
            local varDecl = self:Factory():NewVariableDeclaration(name, nil --[[exclamationToken]], nil --[[type]], nil --[[initializer]])
            if original ~= nil then
                self:EmitContext():SetOriginal(varDecl, original)
            end
            self.exportVars = self.exportVars or {}
            self.exportVars[#self.exportVars + 1] = varDecl
            return
        end

        local localName
        local exportName
        if exportAlias ~= nil then
            localName = name
            exportName = exportAlias
        else
            exportName = name
        end
        local specifier = self:Factory():NewExportSpecifier(false --[[isTypeOnly]], localName, exportName)
        if original ~= nil then
            self:EmitContext():SetOriginal(specifier, original)
        end
        if self.exportBindings == nil then
            self.exportBindings = {}
        end
        if self.exportBindings[name:Text()] == nil then
            self.exportBindingNames = self.exportBindingNames or {}
            self.exportBindingNames[#self.exportBindingNames + 1] = name:Text()
        end
        self.exportBindings[name:Text()] = specifier
    end
    self:EmitContext():AddVariableDeclaration(name)
end

function usingDeclarationTransformer:createEnvBinding()
    return self:Factory():NewUniqueName("env")
end

function usingDeclarationTransformer:createDownlevelUsingStatements(bodyStatements, envBinding, async)
    local statements = {}

    -- produces:
    --
    --  const env_1 = { stack: [], error: void 0, hasError: false };
    --
    local envObject = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({
        self:Factory():NewPropertyAssignment(nil --[[modifiers]], self:Factory():NewIdentifier("stack"), nil --[[postfixToken]], nil --[[typeNode]], self:Factory():NewArrayLiteralExpression(nil, false --[[multiLine]])),
        self:Factory():NewPropertyAssignment(nil --[[modifiers]], self:Factory():NewIdentifier("error"), nil --[[postfixToken]], nil --[[typeNode]], self:Factory():NewVoidZeroExpression()),
        self:Factory():NewPropertyAssignment(nil --[[modifiers]], self:Factory():NewIdentifier("hasError"), nil --[[postfixToken]], nil --[[typeNode]], self:Factory():NewFalseExpression()),
    }), false --[[multiLine]])
    local envVar = self:Factory():NewVariableDeclaration(envBinding, nil --[[exclamationToken]], nil --[[typeNode]], envObject)
    local envVarList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ envVar }), NodeFlags.Const)
    local envVarStatement = self:Factory():NewVariableStatement(nil --[[modifiers]], envVarList)
    statements[#statements + 1] = envVarStatement

    -- when `async` is `false`, produces:
    --
    --  try {
    --    <bodyStatements>
    --  }
    --  catch (e_1) {
    --      env_1.error = e_1;
    --      env_1.hasError = true;
    --  }
    --  finally {
    --    __disposeResources(env_1);
    --  }

    -- when `async` is `true`, produces:
    --
    --  try {
    --    <bodyStatements>
    --  }
    --  catch (e_1) {
    --      env_1.error = e_1;
    --      env_1.hasError = true;
    --  }
    --  finally {
    --    const result_1 = __disposeResources(env_1);
    --    if (result_1) {
    --      await result_1;
    --    }
    --  }

    -- Unfortunately, it is necessary to use two properties to indicate an error because `throw undefined` is legal
    -- JavaScript.
    local tryBlock = self:Factory():NewBlock(self:Factory():NewNodeList(bodyStatements), true --[[multiLine]])
    local bodyCatchBinding = self:Factory():NewUniqueName("e")
    local catchClause = self:Factory():NewCatchClause(
        self:Factory():NewVariableDeclaration(
            bodyCatchBinding,
            nil, --[[exclamationToken]]
            nil, --[[type]]
            nil --[[initializer]]
        ),
        self:Factory():NewBlock(self:Factory():NewNodeList({
            self:Factory():NewExpressionStatement(
                self:Factory():NewAssignmentExpression(
                    self:Factory():NewPropertyAccessExpression(envBinding, nil, self:Factory():NewIdentifier("error"), NodeFlags.None),
                    bodyCatchBinding
                )
            ),
            self:Factory():NewExpressionStatement(
                self:Factory():NewAssignmentExpression(
                    self:Factory():NewPropertyAccessExpression(envBinding, nil, self:Factory():NewIdentifier("hasError"), NodeFlags.None),
                    self:Factory():NewTrueExpression()
                )
            ),
        }), true --[[multiLine]])
    )

    local finallyBlock
    if async then
        local result = self:Factory():NewUniqueName("result")
        finallyBlock = self:Factory():NewBlock(self:Factory():NewNodeList({
            self:Factory():NewVariableStatement(
                nil, --[[modifiers]]
                self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({
                    self:Factory():NewVariableDeclaration(
                        result,
                        nil, --[[exclamationToken]]
                        nil, --[[type]]
                        self:Factory():NewDisposeResourcesHelper(envBinding)
                    ),
                }), NodeFlags.Const)
            ),
            self:Factory():NewIfStatement(result, self:Factory():NewExpressionStatement(self:Factory():NewAwaitExpression(result)), nil --[[elseStatement]]),
        }), true --[[multiLine]])
    else
        finallyBlock = self:Factory():NewBlock(self:Factory():NewNodeList({
            self:Factory():NewExpressionStatement(
                self:Factory():NewDisposeResourcesHelper(envBinding)
            ),
        }), true --[[multiLine]])
    end

    local tryStatement = self:Factory():NewTryStatement(tryBlock, catchClause, finallyBlock)
    statements[#statements + 1] = tryStatement
    return statements
end

function estransforms.isUsingVariableDeclarationList(node)
    return ast.IsVariableDeclarationList(node) and estransforms.getUsingKindOfVariableDeclarationList(node:AsVariableDeclarationList()) ~= estransforms.usingKindNone
end

function estransforms.getUsingKindOfVariableDeclarationList(node)
    local scoped = node.flags & NodeFlags.BlockScoped
    if scoped == NodeFlags.AwaitUsing then
        return estransforms.usingKindAsync
    elseif scoped == NodeFlags.Using then
        return estransforms.usingKindSync
    else
        return estransforms.usingKindNone
    end
end

function estransforms.getUsingKindOfVariableStatement(node)
    return estransforms.getUsingKindOfVariableDeclarationList(node.declarationList:AsVariableDeclarationList())
end

function estransforms.getUsingKind(statement)
    if ast.IsVariableStatement(statement) then
        return estransforms.getUsingKindOfVariableStatement(statement:AsVariableStatement())
    end
    return estransforms.usingKindNone
end

function estransforms.getUsingKindOfStatements(statements)
    local result = estransforms.usingKindNone
    for _, statement in ipairs(statements or {}) do
        local usingKind = estransforms.getUsingKind(statement)
        if usingKind == estransforms.usingKindAsync then
            return estransforms.usingKindAsync
        end
        if usingKind > result then
            result = usingKind
        end
    end
    return result
end
