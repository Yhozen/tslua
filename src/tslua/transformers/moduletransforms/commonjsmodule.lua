local moduletransforms = require("tslua.transformers.moduletransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts
local ModuleKind = core.ModuleKind
local EF = printer.EmitFlags

-- Fields: topLevelVisitor (visits statements at top level of a module), topLevelNestedVisitor (visits nested
-- statements at top level of a module), discardedValueVisitor (visits expressions whose values would be discarded
-- at runtime), assignmentPatternVisitor (visits assignment patterns in a destructuring assignment), compilerOptions,
-- resolver, getEmitModuleFormatOfFile, moduleKind, languageVersion, currentSourceFile, currentModuleInfo,
-- parentNode and currentNode (used for ancestor tracking via pushNode/popNode to detect expression identifiers).
local CommonJSModuleTransformer = transformers.NewTransformerType()
moduletransforms.CommonJSModuleTransformer = CommonJSModuleTransformer

local function appendAll(dst, src)
    if dst == nil then
        dst = {}
    end
    if src ~= nil then
        for _, s in ipairs(src) do
            dst[#dst + 1] = s
        end
    end
    return dst
end

function moduletransforms.NewCommonJSModuleTransformer(opts)
    local compilerOptions = opts.compilerOptions
    local emitContext = opts.context
    local tx = setmetatable({
        topLevelVisitor = nil,
        topLevelNestedVisitor = nil,
        discardedValueVisitor = nil,
        assignmentPatternVisitor = nil,
        compilerOptions = compilerOptions,
        resolver = opts.resolver,
        getEmitModuleFormatOfFile = opts.getEmitModuleFormatOfFile,
        moduleKind = ModuleKind.None,
        languageVersion = core.ScriptTarget.None,
        currentSourceFile = nil,
        currentModuleInfo = nil,
        parentNode = nil,
        currentNode = nil,
    }, CommonJSModuleTransformer)
    tx.topLevelVisitor = emitContext:NewNodeVisitor(function(node) return tx:visitTopLevel(node) end)
    tx.topLevelNestedVisitor = emitContext:NewNodeVisitor(function(node) return tx:visitTopLevelNested(node) end)
    tx.discardedValueVisitor = emitContext:NewNodeVisitor(function(node) return tx:visitDiscardedValue(node) end)
    tx.assignmentPatternVisitor = emitContext:NewNodeVisitor(function(node) return tx:visitAssignmentPattern(node) end)
    tx.languageVersion = compilerOptions:GetEmitScriptTarget()
    tx.moduleKind = compilerOptions:GetEmitModuleKind()
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

-- Pushes a new child node onto the ancestor tracking stack, returning the grandparent node to be restored later via `popNode`.
function CommonJSModuleTransformer:pushNode(node)
    local grandparentNode = self.parentNode
    self.parentNode = self.currentNode
    self.currentNode = node
    return grandparentNode
end

-- Pops the last child node off the ancestor tracking stack, restoring the grandparent node.
function CommonJSModuleTransformer:popNode(grandparentNode)
    self.currentNode = self.parentNode
    self.parentNode = grandparentNode
end

-- Visits a node at the top level of the source file.
function CommonJSModuleTransformer:visitTopLevel(node)
    local grandparentNode = self:pushNode(node)

    local k = node.kind
    if k == Kind.ImportDeclaration then
        node = self:visitTopLevelImportDeclaration(node:AsImportDeclaration())
    elseif k == Kind.ImportEqualsDeclaration then
        node = self:visitTopLevelImportEqualsDeclaration(node:AsImportEqualsDeclaration())
    elseif k == Kind.ExportDeclaration then
        node = self:visitTopLevelExportDeclaration(node:AsExportDeclaration())
    elseif k == Kind.ExportAssignment then
        node = self:visitTopLevelExportAssignment(node:AsExportAssignment())
    elseif k == Kind.FunctionDeclaration then
        node = self:visitTopLevelFunctionDeclaration(node:AsFunctionDeclaration())
    elseif k == Kind.ClassDeclaration then
        node = self:visitTopLevelClassDeclaration(node:AsClassDeclaration())
    elseif k == Kind.VariableStatement then
        node = self:visitTopLevelVariableStatement(node:AsVariableStatement())
    else
        node = self:visitTopLevelNestedNoStack(node)
    end
    self:popNode(grandparentNode)
    return node
end

-- Visits nested elements at the top-level of a module.
function CommonJSModuleTransformer:visitTopLevelNested(node)
    local grandparentNode = self:pushNode(node)
    local result = self:visitTopLevelNestedNoStack(node)
    self:popNode(grandparentNode)
    return result
end

-- Visits nested elements at the top-level of a module without ancestor tracking.
function CommonJSModuleTransformer:visitTopLevelNestedNoStack(node)
    local k = node.kind
    if k == Kind.VariableStatement then
        node = self:visitTopLevelVariableStatement(node:AsVariableStatement())
    elseif k == Kind.ForStatement then
        node = self:visitTopLevelNestedForStatement(node:AsForStatement())
    elseif k == Kind.ForInStatement or k == Kind.ForOfStatement then
        node = self:visitTopLevelNestedForInOrOfStatement(node:AsForInOrOfStatement())
    elseif k == Kind.DoStatement then
        node = self:visitTopLevelNestedDoStatement(node:AsDoStatement())
    elseif k == Kind.WhileStatement then
        node = self:visitTopLevelNestedWhileStatement(node:AsWhileStatement())
    elseif k == Kind.LabeledStatement then
        node = self:visitTopLevelNestedLabeledStatement(node:AsLabeledStatement())
    elseif k == Kind.WithStatement then
        node = self:visitTopLevelNestedWithStatement(node:AsWithStatement())
    elseif k == Kind.IfStatement then
        node = self:visitTopLevelNestedIfStatement(node:AsIfStatement())
    elseif k == Kind.SwitchStatement then
        node = self:visitTopLevelNestedSwitchStatement(node:AsSwitchStatement())
    elseif k == Kind.CaseBlock then
        node = self:visitTopLevelNestedCaseBlock(node:AsCaseBlock())
    elseif k == Kind.CaseClause or k == Kind.DefaultClause then
        node = self:visitTopLevelNestedCaseOrDefaultClause(node:AsCaseOrDefaultClause())
    elseif k == Kind.TryStatement then
        node = self:visitTopLevelNestedTryStatement(node:AsTryStatement())
    elseif k == Kind.CatchClause then
        node = self:visitTopLevelNestedCatchClause(node:AsCatchClause())
    elseif k == Kind.Block then
        node = self:visitTopLevelNestedBlock(node:AsBlock())
    else
        node = self:visitNoStack(node, false --[[resultIsDiscarded]])
    end
    return node
end

-- Visits source elements that are not top-level or top-level nested statements.
function CommonJSModuleTransformer:visit(node)
    local grandparentNode = self:pushNode(node)
    local result = self:visitNoStack(node, false --[[resultIsDiscarded]])
    self:popNode(grandparentNode)
    return result
end

-- Visits source elements that are not top-level or top-level nested statements without ancestor tracking.
function CommonJSModuleTransformer:visitNoStack(node, resultIsDiscarded)
    -- This visitor does not need to descend into the tree if there are no dynamic imports or identifiers in the subtree
    if not ast.IsSourceFile(node) and node:SubtreeFacts() & (SubtreeFacts.SubtreeContainsDynamicImport | SubtreeFacts.SubtreeContainsIdentifier) == 0 then
        return node
    end

    local k = node.kind
    if k == Kind.SourceFile then
        node = self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.ForStatement then
        node = self:visitForStatement(node:AsForStatement())
    elseif k == Kind.ForInStatement or k == Kind.ForOfStatement then
        node = self:visitForInOrOfStatement(node:AsForInOrOfStatement())
    elseif k == Kind.ExpressionStatement then
        node = self:visitExpressionStatement(node:AsExpressionStatement())
    elseif k == Kind.VoidExpression then
        node = self:visitVoidExpression(node:AsVoidExpression())
    elseif k == Kind.ParenthesizedExpression then
        node = self:visitParenthesizedExpression(node:AsParenthesizedExpression(), resultIsDiscarded)
    elseif k == Kind.PartiallyEmittedExpression then
        node = self:visitPartiallyEmittedExpression(node:AsPartiallyEmittedExpression(), resultIsDiscarded)
    elseif k == Kind.CallExpression then
        node = self:visitCallExpression(node:AsCallExpression())
    elseif k == Kind.TaggedTemplateExpression then
        node = self:visitTaggedTemplateExpression(node:AsTaggedTemplateExpression())
    elseif k == Kind.BinaryExpression then
        node = self:visitBinaryExpression(node:AsBinaryExpression(), resultIsDiscarded)
    elseif k == Kind.PrefixUnaryExpression then
        node = self:visitPrefixUnaryExpression(node:AsPrefixUnaryExpression(), resultIsDiscarded)
    elseif k == Kind.PostfixUnaryExpression then
        node = self:visitPostfixUnaryExpression(node:AsPostfixUnaryExpression(), resultIsDiscarded)
    elseif k == Kind.ShorthandPropertyAssignment then
        node = self:visitShorthandPropertyAssignment(node:AsShorthandPropertyAssignment())
    elseif k == Kind.Identifier then
        node = self:visitIdentifier(node)
    else
        node = self:Visitor():VisitEachChild(node)
    end

    return node
end

-- Visits source elements whose value is discarded if they are expressions.
function CommonJSModuleTransformer:visitDiscardedValue(node)
    local grandparentNode = self:pushNode(node)
    local result = self:visitNoStack(node, true --[[resultIsDiscarded]])
    self:popNode(grandparentNode)
    return result
end

function CommonJSModuleTransformer:visitAssignmentPattern(node)
    local grandparentNode = self:pushNode(node)
    local result = self:visitAssignmentPatternNoStack(node)
    self:popNode(grandparentNode)
    return result
end

function CommonJSModuleTransformer:visitAssignmentPatternNoStack(node)
    local k = node.kind
    -- AssignmentPattern
    if k == Kind.ObjectLiteralExpression or k == Kind.ArrayLiteralExpression then
        node = self.assignmentPatternVisitor:VisitEachChild(node)

    -- AssignmentProperty
    elseif k == Kind.PropertyAssignment then
        node = self:visitAssignmentProperty(node:AsPropertyAssignment())
    elseif k == Kind.ShorthandPropertyAssignment then
        node = self:visitShorthandAssignmentProperty(node:AsShorthandPropertyAssignment())

    -- AssignmentRestProperty
    elseif k == Kind.SpreadAssignment then
        node = self:visitAssignmentRestProperty(node:AsSpreadAssignment())

    -- AssignmentRestElement
    elseif k == Kind.SpreadElement then
        node = self:visitAssignmentRestElement(node:AsSpreadElement())

    -- AssignmentElement
    else
        if ast.IsExpression(node) then
            node = self:visitAssignmentElement(node)
        else
            node = self:visitNoStack(node, false --[[resultIsDiscarded]])
        end
    end
    return node
end

function CommonJSModuleTransformer:visitSourceFile(node)
    if node.isDeclarationFile or
        not (ast.IsEffectiveExternalModule(node, self.compilerOptions) or
            node:SubtreeFacts() & SubtreeFacts.SubtreeContainsDynamicImport ~= 0) then
        return node:AsNode()
    end

    self.currentSourceFile = node
    self.currentModuleInfo = moduletransforms.collectExternalModuleInfo(node, self.compilerOptions, self:EmitContext(), self.resolver)
    local updated = self:transformCommonJSModule(node)
    self.currentSourceFile = nil
    self.currentModuleInfo = nil
    return updated
end

function CommonJSModuleTransformer:shouldEmitUnderscoreUnderscoreESModule()
    if tspath.FileExtensionIsOneOf(self.currentSourceFile:FileName(), tspath.SupportedJSExtensionsFlat) and
        self.currentSourceFile.commonJSModuleIndicator ~= nil and
        (self.currentSourceFile.externalModuleIndicator == nil or self.currentSourceFile.externalModuleIndicator.kind == Kind.SourceFile) then
        return false
    end
    if self.currentModuleInfo.exportEquals == nil and ast.IsExternalModule(self.currentSourceFile) then
        return true
    end
    return false
end

function CommonJSModuleTransformer:createUnderscoreUnderscoreESModule()
    local f = self:Factory()
    local statement = f:NewExpressionStatement(
        f:NewCallExpression(
            f:NewPropertyAccessExpression(
                f:NewIdentifier("Object"),
                nil, --[[questionDotToken]]
                f:NewIdentifier("defineProperty"),
                NodeFlags.None
            ),
            nil, --[[questionDotToken]]
            nil, --[[typeArguments]]
            f:NewNodeList({
                f:NewIdentifier("exports"),
                f:NewStringLiteral("__esModule", ast.TokenFlags.None),
                f:NewObjectLiteralExpression(
                    f:NewNodeList({
                        f:NewPropertyAssignment(
                            nil, --[[modifiers]]
                            f:NewIdentifier("value"),
                            nil, --[[postfixToken]]
                            nil, --[[typeNode]]
                            f:NewTrueExpression()
                        ),
                    }),
                    false --[[multiLine]]
                ),
            }),
            NodeFlags.None
        )
    )
    self:EmitContext():SetEmitFlags(statement, EF.EFCustomPrologue)
    return statement
end

function CommonJSModuleTransformer:transformCommonJSModule(node)
    self:EmitContext():StartVariableEnvironment()

    -- emit standard prologue directives (e.g. "use strict")
    local prologue, rest = self:Factory():SplitStandardPrologue(node.statements.nodes)
    local statements = appendAll(nil, prologue)

    -- emit custom prologues from other transformations
    local custom
    custom, rest = self:Factory():SplitCustomPrologue(rest)
    statements = appendAll(statements, core.FirstResult(self.topLevelVisitor:VisitSlice(custom)))

    -- emits `Object.defineProperty(exports, "__esModule", { value: true });` at the top of the file
    if self:shouldEmitUnderscoreUnderscoreESModule() then
        statements[#statements + 1] = self:createUnderscoreUnderscoreESModule()
    end

    -- initialize all exports to `undefined`, e.g.:
    --  exports.a = exports.b = void 0;
    if core.Len(self.currentModuleInfo.exportedNames) > 0 then
        local chunkSize = 50
        local exportedNames = self.currentModuleInfo.exportedNames
        local l = #exportedNames
        for i = 0, l - 1, chunkSize do
            local right = self:Factory():NewVoidZeroExpression()
            for j = i, math.min(i + chunkSize, l) - 1 do
                local nextId = exportedNames[j + 1]
                local left
                if nextId.kind == Kind.StringLiteral then
                    left = self:Factory():NewElementAccessExpression(
                        self:Factory():NewIdentifier("exports"),
                        nil, --[[questionDotToken]]
                        self:Factory():NewStringLiteralFromNode(nextId),
                        NodeFlags.None
                    )
                else
                    local name = nextId:Clone(self:Factory())
                    self:EmitContext():SetEmitFlags(name, EF.EFNoSourceMap | EF.EFNoComments)
                    left = self:Factory():NewPropertyAccessExpression(
                        self:Factory():NewIdentifier("exports"),
                        nil, --[[questionDotToken]]
                        name,
                        NodeFlags.None
                    )
                end
                right = self:Factory():NewAssignmentExpression(left, right)
            end
            local statement = self:Factory():NewExpressionStatement(right)
            self:EmitContext():AddEmitFlags(statement, EF.EFCustomPrologue)
            statements[#statements + 1] = statement
        end
    end

    -- initialize exports for function declarations, e.g.:
    --  exports.f = f;
    --  function f() {}
    -- These are marked as custom prologue so they are ordered before the external helpers
    -- import declaration (e.g., `const tslib_1 = require("tslib")`), matching TypeScript's emit order.
    local exportedFunctionsStart = #statements
    for f in self.currentModuleInfo.exportedFunctions:Values() do
        statements = self:appendExportsOfClassOrFunctionDeclaration(statements, f:AsNode())
    end
    for i = exportedFunctionsStart + 1, #statements do
        self:EmitContext():AddEmitFlags(statements[i], EF.EFCustomPrologue)
    end

    -- visit the remaining statements in the source file
    rest = core.FirstResult(self.topLevelVisitor:VisitSlice(rest))
    statements = appendAll(statements, rest)

    -- emit `module.exports = ...` if needd
    statements = self:appendExportEqualsIfNeeded(statements)

    -- merge temp variables into the statement list
    statements = self:EmitContext():EndAndMergeVariableEnvironment(statements)

    local statementList = self:Factory():NewNodeList(statements)
    statementList.loc = node.statements.loc
    local result = self:Factory():UpdateSourceFile(node, statementList, node.endOfFileToken):AsSourceFile()
    self:EmitContext():AddEmitHelper(result:AsNode(), table.unpack(self:EmitContext():ReadEmitHelpers() or {}))

    local externalHelpersImportDeclaration = moduletransforms.createExternalHelpersImportDeclarationIfNeeded(self:EmitContext(), result, self.compilerOptions, self.getEmitModuleFormatOfFile(node), false --[[hasExportStarsToExportValues]], false --[[hasImportStar]], false --[[hasImportDefault]])
    if externalHelpersImportDeclaration ~= nil then
        local prologue2, rest2 = self:Factory():SplitStandardPrologue(result.statements.nodes)
        local custom2
        custom2, rest2 = self:Factory():SplitCustomPrologue(rest2)
        local statements2 = appendAll(nil, prologue2)
        statements2 = appendAll(statements2, custom2)
        statements2 = core.Append(statements2, self.topLevelVisitor:VisitNode(externalHelpersImportDeclaration))
        statements2 = appendAll(statements2, rest2)
        local statementList2 = self:Factory():NewNodeList(statements2)
        statementList2.loc = result.statements.loc
        result = self:Factory():UpdateSourceFile(result, statementList2, node.endOfFileToken):AsSourceFile()
    end

    return result:AsNode()
end

-- Adds the down-level representation of `export=` to the statement list if one exists in the source file.
--
-- - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
function CommonJSModuleTransformer:appendExportEqualsIfNeeded(statements)
    if self.currentModuleInfo.exportEquals ~= nil then
        local expressionResult = self:visitExportEquals(self.currentModuleInfo.exportEquals)
        if expressionResult ~= nil then
            local statement = self:Factory():NewExpressionStatement(
                self:Factory():NewAssignmentExpression(
                    self:Factory():NewPropertyAccessExpression(
                        self:Factory():NewIdentifier("module"),
                        nil, --[[questionDotToken]]
                        self:Factory():NewIdentifier("exports"),
                        NodeFlags.None
                    ),
                    expressionResult
                )
            )

            self:EmitContext():AssignCommentAndSourceMapRanges(statement, self.currentModuleInfo.exportEquals:AsNode())
            self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
            statements = core.Append(statements, statement)
        end
    end
    return statements
end

function CommonJSModuleTransformer:visitExportEquals(node)
    local grandparentNode = self:pushNode(node:AsNode())
    local result = self:Visitor():VisitNode(node.expression)
    self:popNode(grandparentNode)
    return result
end

-- Appends the exports of an ImportDeclaration to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `decl` parameter is the declaration whose exports are to be recorded.
function CommonJSModuleTransformer:appendExportsOfImportDeclaration(statements, decl)
    if self.currentModuleInfo.exportEquals ~= nil then
        return statements
    end

    local importClause = decl.importClause
    if importClause == nil then
        return statements
    end

    local seen = collections.NewSet()
    if importClause:Name() ~= nil then
        statements = self:appendExportsOfDeclaration(statements, importClause, seen, false --[[liveBinding]])
    end

    local namedBindings = importClause:AsImportClause().namedBindings
    if namedBindings ~= nil then
        if namedBindings.kind == Kind.NamespaceImport then
            statements = self:appendExportsOfDeclaration(statements, namedBindings, seen, false --[[liveBinding]])
        elseif namedBindings.kind == Kind.NamedImports then
            for _, importBinding in ipairs(namedBindings:Elements() or {}) do
                statements = self:appendExportsOfDeclaration(statements, importBinding, seen, true --[[liveBinding]])
            end
        end
    end

    return statements
end

-- Appends the exports of a VariableStatement to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `node` parameter is the VariableStatement whose exports are to be recorded.
function CommonJSModuleTransformer:appendExportsOfVariableStatement(statements, node)
    return self:appendExportsOfVariableDeclarationList(statements, node.declarationList:AsVariableDeclarationList(), false --[[isForInOrOfInitializer]])
end

-- Appends the exports of a VariableDeclarationList to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `node` parameter is the VariableDeclarationList whose exports are to be recorded.
function CommonJSModuleTransformer:appendExportsOfVariableDeclarationList(statements, node, isForInOrOfInitializer)
    if self.currentModuleInfo.exportEquals ~= nil then
        return statements
    end

    for _, decl in ipairs(node.declarations.nodes) do
        statements = self:appendExportsOfBindingElement(statements, decl, isForInOrOfInitializer)
    end

    return statements
end

-- Appends the exports of a VariableDeclaration or BindingElement to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `decl` parameter is the declaration whose exports are to be recorded.
function CommonJSModuleTransformer:appendExportsOfBindingElement(statements, decl, isForInOrOfInitializer)
    if self.currentModuleInfo.exportEquals ~= nil or decl:Name() == nil then
        return statements
    end

    if ast.IsBindingPattern(decl:Name()) then
        for _, element in ipairs(decl:Name():Elements() or {}) do
            if not ast.IsOmittedExpression(element) then
                statements = self:appendExportsOfBindingElement(statements, element, isForInOrOfInitializer)
            end
        end
    elseif not transformers.IsGeneratedIdentifier(self:EmitContext(), decl:Name()) and
        (not ast.IsVariableDeclaration(decl) or decl:Initializer() ~= nil or isForInOrOfInitializer) then
        statements = self:appendExportsOfDeclaration(statements, decl, nil --[[seen]], false --[[liveBinding]])
    end

    return statements
end

-- Appends the exports of a ClassDeclaration or FunctionDeclaration to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `decl` parameter is the declaration whose exports are to be recorded.
function CommonJSModuleTransformer:appendExportsOfClassOrFunctionDeclaration(statements, decl)
    if self.currentModuleInfo.exportEquals ~= nil then
        return statements
    end

    local seen = collections.NewSet()
    if ast.HasSyntacticModifier(decl, ModifierFlags.Export) then
        local exportName
        if ast.HasSyntacticModifier(decl, ModifierFlags.Default) then
            exportName = self:Factory():NewIdentifier("default")
        else
            exportName = self:Factory():GetDeclarationName(decl)
        end

        local exportValue = self:Factory():GetLocalName(decl)
        statements = self:appendExportStatement(statements, seen, exportName, exportValue, decl.loc, false --[[allowComments]], false --[[liveBinding]])
    end

    if decl:Name() ~= nil then
        return self:appendExportsOfDeclaration(statements, decl, seen, false --[[liveBinding]])
    end

    return statements
end

-- Appends the exports of a declaration to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `decl` parameter is the declaration to export.
function CommonJSModuleTransformer:appendExportsOfDeclaration(statements, decl, seen, liveBinding)
    if self.currentModuleInfo.exportEquals ~= nil then
        return statements
    end

    if seen == nil then
        seen = collections.NewSet()
    end

    local name = decl:Name()
    if self.currentModuleInfo.exportSpecifiers:Len() > 0 and name ~= nil and ast.IsIdentifier(name) then
        name = self:Factory():GetDeclarationName(decl)
        local exportSpecifiers = self.currentModuleInfo.exportSpecifiers:Get(name:Text())
        if core.Len(exportSpecifiers) > 0 then
            local exportValue = self:visitExpressionIdentifier(name)
            for _, exportSpecifier in ipairs(exportSpecifiers) do
                statements = self:appendExportStatement(statements, seen, exportSpecifier:Name(), exportValue, exportSpecifier:Name().loc --[[location]], false --[[allowComments]], liveBinding)
            end
        end
    end

    return statements
end

-- Appends the down-level representation of an export to a statement list, returning the statement list.
--
--   - The `statements` parameter is a statement list to which the down-level export statements are to be appended.
--   - The `exportName` parameter is the name of the export.
--   - The `expression` parameter is the expression to export.
--   - The `location` parameter is the location to use for source maps and comments for the export.
--   - The `allowComments` parameter indicates whether to allow comments on the export.
function CommonJSModuleTransformer:appendExportStatement(statements, seen, exportName, expression, location, allowComments, liveBinding)
    if exportName.kind ~= Kind.StringLiteral then
        if seen:Has(exportName:Text()) then
            return statements
        end
        seen:Add(exportName:Text())
    end
    statements = core.Append(statements, self:createExportStatement(exportName, expression, location, allowComments, liveBinding))
    return statements
end

-- Creates a call to the current file's export function to export a value.
--
--   - The `name` parameter is the bound name of the export.
--   - The `value` parameter is the exported value.
--   - The `location` parameter is the location to use for source maps and comments for the export.
--   - The `allowComments` parameter indicates whether to emit comments for the statement.
function CommonJSModuleTransformer:createExportStatement(name, value, location, allowComments, liveBinding)
    local statement = self:Factory():NewExpressionStatement(self:createExportExpression(name, value, nil --[[location]], liveBinding))
    if location ~= nil then
        self:EmitContext():SetCommentRange(statement, location)
    end
    self:EmitContext():AddEmitFlags(statement, EF.EFStartOnNewLine)
    if not allowComments then
        self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
    end
    return statement
end

-- Creates a call to the current file's export function to export a value.
--
--   - The `name` parameter is the bound name of the export.
--   - The `value` parameter is the exported value.
--   - The `location` parameter is the location to use for source maps and comments for the export.
function CommonJSModuleTransformer:createExportExpression(name, value, location, liveBinding)
    local f = self:Factory()
    local expression
    if liveBinding then
        -- For a live binding we emit a getter on `exports` that returns the value:
        --  Object.defineProperty(exports, "<name>", { enumerable: true, get: function () { return <value>; } });
        expression = f:NewCallExpression(
            f:NewPropertyAccessExpression(
                f:NewIdentifier("Object"),
                nil, --[[questionDotToken]]
                f:NewIdentifier("defineProperty"),
                NodeFlags.None
            ),
            nil, --[[questionDotToken]]
            nil, --[[typeArguments]]
            f:NewNodeList({
                f:NewIdentifier("exports"),
                f:NewStringLiteralFromNode(name),
                f:NewObjectLiteralExpression(
                    f:NewNodeList({
                        f:NewPropertyAssignment(
                            nil, --[[modifiers]]
                            f:NewIdentifier("enumerable"),
                            nil, --[[postfixToken]]
                            nil, --[[typeNode]]
                            f:NewTrueExpression()
                        ),
                        f:NewPropertyAssignment(
                            nil, --[[modifiers]]
                            f:NewIdentifier("get"),
                            nil, --[[postfixToken]]
                            nil, --[[typeNode]]
                            f:NewFunctionExpression(
                                nil, --[[modifiers]]
                                nil, --[[asteriskToken]]
                                nil, --[[name]]
                                nil, --[[typeParameters]]
                                f:NewNodeList({}),
                                nil, --[[type]]
                                nil, --[[fullSignature]]
                                f:NewBlock(
                                    f:NewNodeList({
                                        f:NewReturnStatement(value),
                                    }),
                                    false --[[multiLine]]
                                )
                            )
                        ),
                    }),
                    false --[[multiLine]]
                ),
            }),
            NodeFlags.None
        )
    else
        -- Otherwise, we emit a simple property assignment.
        local left
        if name.kind == Kind.StringLiteral then
            -- emits:
            --  exports["<name>"] = <value>;
            left = f:NewElementAccessExpression(
                f:NewIdentifier("exports"),
                nil, --[[questionDotToken]]
                f:NewStringLiteralFromNode(name),
                NodeFlags.None
            )
        else
            -- emits:
            --  exports.<name> = <value>;
            left = f:NewPropertyAccessExpression(
                f:NewIdentifier("exports"),
                nil, --[[questionDotToken]]
                name:Clone(f),
                NodeFlags.None
            )
        end
        expression = f:NewAssignmentExpression(left, value)
    end
    if location ~= nil then
        self:EmitContext():SetCommentRange(expression, location)
    end
    return expression
end

-- Creates a `require()` call to import an external module.
function CommonJSModuleTransformer:createRequireCall(node)
    local args = nil
    local moduleName = moduletransforms.getExternalModuleNameLiteral(self:Factory(), node, self.currentSourceFile, nil --[[host]], nil --[[resolver]], self.compilerOptions)
    if moduleName ~= nil then
        args = core.Append(args, moduletransforms.rewriteModuleSpecifier(self:EmitContext(), moduleName, self.compilerOptions))
    end
    return self:Factory():NewCallExpression(
        self:Factory():NewIdentifier("require"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:Factory():NewNodeList(args),
        NodeFlags.None
    )
end

function CommonJSModuleTransformer:getHelperExpressionForExport(node, innerExpr)
    if moduletransforms.getExportNeedsImportStarHelper(node) then
        return self:Visitor():VisitNode(self:Factory():NewImportStarHelper(innerExpr))
    end
    return innerExpr
end

function CommonJSModuleTransformer:getHelperExpressionForImport(node, innerExpr)
    if moduletransforms.getImportNeedsImportStarHelper(node) then
        return self:Visitor():VisitNode(self:Factory():NewImportStarHelper(innerExpr))
    end
    if moduletransforms.getImportNeedsImportDefaultHelper(node) then
        return self:Visitor():VisitNode(self:Factory():NewImportDefaultHelper(innerExpr))
    end
    return innerExpr
end

function CommonJSModuleTransformer:visitTopLevelImportDeclaration(node)
    local f = self:Factory()
    if node.importClause == nil then
        -- import "mod";
        local statement = f:NewExpressionStatement(self:createRequireCall(node:AsNode()))
        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
        return statement
    end

    local statements = nil
    local variables = nil
    local namespaceDeclaration = ast.GetNamespaceDeclarationNode(node:AsNode())
    if namespaceDeclaration ~= nil and not ast.IsDefaultImport(node:AsNode()) then
        -- import * as n from "mod";
        variables = core.Append(
            variables,
            f:NewVariableDeclaration(
                namespaceDeclaration:Name():Clone(f),
                nil, --[[exclamationToken]]
                nil, --[[type]]
                self:getHelperExpressionForImport(node, self:createRequireCall(node:AsNode()))
            )
        )
    else
        -- import d from "mod";
        -- import { x, y } from "mod";
        -- import d, { x, y } from "mod";
        -- import d, * as n from "mod";
        variables = core.Append(
            variables,
            f:NewVariableDeclaration(
                f:NewGeneratedNameForNode(node:AsNode()),
                nil, --[[exclamationToken]]
                nil, --[[type]]
                self:getHelperExpressionForImport(node, self:createRequireCall(node:AsNode()))
            )
        )

        if namespaceDeclaration ~= nil and ast.IsDefaultImport(node:AsNode()) then
            variables = core.Append(
                variables,
                f:NewVariableDeclaration(
                    namespaceDeclaration:Name():Clone(f),
                    nil, --[[exclamationToken]]
                    nil, --[[type]]
                    f:NewGeneratedNameForNode(node:AsNode())
                )
            )
        end
    end

    local varStatement = f:NewVariableStatement(
        nil, --[[modifiers]]
        f:NewVariableDeclarationList(
            f:NewNodeList(variables),
            NodeFlags.Const
        )
    )

    self:EmitContext():SetOriginal(varStatement, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(varStatement, node:AsNode())
    statements = core.Append(statements, varStatement)
    statements = self:appendExportsOfImportDeclaration(statements, node)
    return transformers.SingleOrMany(statements, f)
end

function CommonJSModuleTransformer:visitTopLevelImportEqualsDeclaration(node)
    local f = self:Factory()
    if not ast.IsExternalModuleImportEqualsDeclaration(node:AsNode()) then
        -- import m = n;
        error("import= for internal module references should be handled in an earlier transformer.", 0)
    end

    local statements = nil
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export) then
        -- export import m = require("mod");
        local statement = f:NewExpressionStatement(
            self:createExportExpression(
                node:Name(),
                self:createRequireCall(node:AsNode()),
                node.loc,
                false --[[liveBinding]]
            )
        )

        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
        statements = core.Append(statements, statement)
    else
        -- import m = require("mod");
        local statement = f:NewVariableStatement(
            nil, --[[modifiers]]
            f:NewVariableDeclarationList(
                f:NewNodeList({
                    f:NewVariableDeclaration(
                        node:Name():Clone(f),
                        nil, --[[exclamationToken]]
                        nil, --[[typeNode]]
                        self:createRequireCall(node:AsNode())
                    ),
                }),
                NodeFlags.Const
            )
        )
        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
        statements = core.Append(statements, statement)
    end

    statements = self:appendExportsOfDeclaration(statements, node:AsNode(), nil --[[seen]], false --[[liveBinding]])
    return transformers.SingleOrMany(statements, f)
end

function CommonJSModuleTransformer:visitTopLevelExportDeclaration(node)
    local f = self:Factory()
    if node.moduleSpecifier == nil then
        -- Elide export declarations with no module specifier as they are handled
        -- elsewhere.
        return nil
    end

    local generatedName = f:NewGeneratedNameForNode(node:AsNode())
    if node.exportClause ~= nil and ast.IsNamedExports(node.exportClause) then
        -- export { x, y } from "mod";
        local statements = nil
        local varStatement = f:NewVariableStatement(
            nil, --[[modifiers]]
            f:NewVariableDeclarationList(
                f:NewNodeList({
                    f:NewVariableDeclaration(
                        generatedName,
                        nil, --[[exclamationToken]]
                        nil, --[[type]]
                        self:createRequireCall(node:AsNode())
                    ),
                }),
                NodeFlags.None
            )
        )
        self:EmitContext():SetOriginal(varStatement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(varStatement, node:AsNode())
        statements = core.Append(statements, varStatement)

        for _, specifier in ipairs(node.exportClause:Elements() or {}) do
            local specifierName = specifier:PropertyNameOrName()
            local exportNeedsImportDefault = ast.ModuleExportNameIsDefault(specifierName)

            local target
            if exportNeedsImportDefault then
                target = f:NewImportDefaultHelper(generatedName)
            else
                target = generatedName
            end

            local exportName
            if ast.IsStringLiteral(specifier:Name()) then
                exportName = f:NewStringLiteralFromNode(specifier:Name())
            else
                exportName = f:GetExportName(specifier:AsNode())
            end

            local exportedValue
            if ast.IsStringLiteral(specifierName) then
                exportedValue = f:NewElementAccessExpression(target, nil --[[questionDotToken]], specifierName, NodeFlags.None)
            else
                exportedValue = f:NewPropertyAccessExpression(target, nil --[[questionDotToken]], specifierName, NodeFlags.None)
            end
            local statement = f:NewExpressionStatement(
                self:createExportExpression(
                    exportName,
                    exportedValue,
                    nil, --[[location]]
                    true --[[liveBinding]]
                )
            )
            self:EmitContext():SetOriginal(statement, specifier:AsNode())
            self:EmitContext():AssignCommentAndSourceMapRanges(statement, specifier:AsNode())
            statements = core.Append(statements, statement)
        end

        return transformers.SingleOrMany(statements, f)
    end

    if node.exportClause ~= nil then
        -- export * as ns from "mod";
        -- export * as default from "mod";
        local exportName
        if ast.IsStringLiteral(node.exportClause:Name()) then
            exportName = f:NewStringLiteralFromNode(node.exportClause:Name())
        else
            exportName = node.exportClause:Name():Clone(f)
        end
        local statement = f:NewExpressionStatement(
            self:createExportExpression(
                exportName,
                self:getHelperExpressionForExport(
                    node,
                    self:createRequireCall(node:AsNode())
                ),
                nil, --[[location]]
                false --[[liveBinding]]
            )
        )
        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
        return statement
    end

    -- export * from "mod";
    local statement = f:NewExpressionStatement(
        self:Visitor():VisitNode(f:NewExportStarHelper(self:createRequireCall(node:AsNode()), f:NewIdentifier("exports")))
    )
    self:EmitContext():SetOriginal(statement, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
    return statement
end

function CommonJSModuleTransformer:visitTopLevelExportAssignment(node)
    if node.isExportEquals then
        return nil
    end

    return self:createExportStatement(
        self:Factory():NewIdentifier("default"),
        self:Visitor():VisitNode(node.expression),
        node.loc, --[[location]]
        true, --[[allowComments]]
        false --[[liveBinding]]
    )
end

function CommonJSModuleTransformer:visitTopLevelFunctionDeclaration(node)
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export) then
        return self:Factory():UpdateFunctionDeclaration(
            node,
            transformers.ExtractModifiers(self:EmitContext(), node.modifiers, ~ModifierFlags.ExportDefault),
            node.asteriskToken,
            self:Factory():GetDeclarationName(node:AsNode()),
            nil, --[[typeParameters]]
            self:Visitor():VisitNodes(node.parameters),
            nil, --[[type]]
            nil, --[[fullSignature]]
            self:Visitor():VisitNode(node.body)
        )
    else
        return self:Visitor():VisitEachChild(node:AsNode())
    end
end

function CommonJSModuleTransformer:visitTopLevelClassDeclaration(node)
    local statements = nil
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export) then
        statements = core.Append(statements, self:Factory():UpdateClassDeclaration(
            node,
            self:Visitor():VisitModifiers(transformers.ExtractModifiers(self:EmitContext(), node.modifiers, ~ModifierFlags.ExportDefault)),
            self:Factory():GetDeclarationName(node:AsNode()),
            nil, --[[typeParameters]]
            self:Visitor():VisitNodes(node.heritageClauses),
            self:Visitor():VisitNodes(node.members)
        ))
    else
        statements = core.Append(statements, self:Visitor():VisitEachChild(node:AsNode()))
    end
    statements = self:appendExportsOfClassOrFunctionDeclaration(statements, node:AsNode())
    return transformers.SingleOrMany(statements, self:Factory())
end

function CommonJSModuleTransformer:visitTopLevelVariableStatement(node)
    local statements = nil
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export) then
        -- export var a = b;
        local variables = nil
        local expressions = nil
        local modifiers = nil

        local function commitPendingVariables()
            if core.Len(variables) > 0 then
                local variableList = self:Factory():NewNodeList(variables)
                local statement = self:Factory():UpdateVariableStatement(
                    node,
                    modifiers,
                    self:Factory():UpdateVariableDeclarationList(
                        node.declarationList:AsVariableDeclarationList(),
                        variableList,
                        node.declarationList.flags
                    )
                )
                if core.Len(statements) > 0 then
                    self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
                end
                statements = core.Append(statements, statement)
                variables = nil
            end
        end

        local function commitPendingExpressions()
            if core.Len(expressions) > 0 then
                local statement = self:Factory():NewExpressionStatement(self:Factory():InlineExpressions(expressions))
                self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())
                if core.Len(statements) > 0 then
                    self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
                end
                statements = core.Append(statements, statement)
                expressions = nil
            end
        end

        local function pushVariable(variable)
            commitPendingExpressions()
            variables = core.Append(variables, variable)
        end

        local function pushExpression(expression)
            commitPendingVariables()
            expressions = core.Append(expressions, expression)
        end

        -- If we're exporting these variables, then these just become assignments to 'exports.x'.
        for _, variable in ipairs(node.declarationList:AsVariableDeclarationList().declarations.nodes) do
            local v = variable:AsVariableDeclaration()

            if ast.IsIdentifier(v:Name()) and transformers.IsLocalName(self:EmitContext(), v:Name()) then
                -- A "local name" generally means a variable declaration that *shouldn't* be
                -- converted to `exports.x = ...`, even if the declaration is exported. This
                -- usually indicates a class or function declaration that was converted into
                -- a variable declaration, as most references to the declaration will remain
                -- untransformed (i.e., `new C` rather than `new exports.C`). In these cases,
                -- an `export { x }` declaration will follow.

                if modifiers == nil then
                    modifiers = transformers.ExtractModifiers(self:EmitContext(), node.modifiers, ~ModifierFlags.ExportDefault)
                end

                if v.initializer ~= nil then
                    variable = self:Factory():UpdateVariableDeclaration(
                        v,
                        v:Name(),
                        nil, --[[exclamationToken]]
                        nil, --[[type]]
                        self:createExportExpression(
                            v:Name(),
                            self:Visitor():VisitNode(v.initializer),
                            nil,
                            false --[[liveBinding]]
                        )
                    )
                end

                pushVariable(variable)
            elseif v.initializer ~= nil and not ast.IsBindingPattern(v:Name()) and (ast.IsArrowFunction(v.initializer) or ast.IsFunctionExpression(v.initializer) or ast.IsClassExpression(v.initializer)) then
                -- preserve variable declarations for functions and classes to assign names

                pushVariable(self:Factory():NewVariableDeclaration(
                    v:Name(),
                    v.exclamationToken,
                    v.type,
                    self:Visitor():VisitNode(v.initializer)
                ))

                local propertyAccess = self:Factory():NewPropertyAccessExpression(
                    self:Factory():NewIdentifier("exports"),
                    nil, --[[questionDotToken]]
                    v:Name(),
                    NodeFlags.None
                )
                self:EmitContext():AssignCommentAndSourceMapRanges(propertyAccess, v:Name())

                pushExpression(self:Factory():NewAssignmentExpression(
                    propertyAccess,
                    v:Name():Clone(self:Factory())
                ))
            elseif ast.IsIdentifier(v:Name()) then
                local expression = self:transformInitializedVariable(v)
                if expression ~= nil then
                    pushExpression(self:Visitor():VisitNode(expression))
                end
            elseif ast.IsBindingPattern(v:Name()) then
                -- For binding patterns with export modifier, use flattenDestructuringAssignment
                -- to decompose into individual export assignments
                local expression = self:transformInitializedVariable(v)
                if expression ~= nil then
                    pushExpression(expression)
                end
            else
                -- For binding patterns, we can't do exports.{pattern} = value
                -- Just emit the assignment and let appendExportsOfVariableStatement handle the exports
                local expression = transformers.ConvertVariableDeclarationToAssignmentExpression(self:EmitContext(), v)
                if expression ~= nil then
                    pushExpression(self:Visitor():VisitNode(expression))
                end
            end
        end

        commitPendingVariables()
        commitPendingExpressions()
        statements = self:appendExportsOfVariableStatement(statements, node)
        return transformers.SingleOrMany(statements, self:Factory())
    end
    return self:visitTopLevelNestedVariableStatement(node)
end

function CommonJSModuleTransformer:transformInitializedVariable(node)
    if node.initializer == nil then
        return nil
    end
    local name = node:Name()
    if ast.IsBindingPattern(name) then
        -- Convert the binding pattern into an equivalent assignment expression and visit it
        -- as a destructuring assignment. This preserves native destructuring (and therefore
        -- iterator semantics for array patterns) whenever each leaf identifier can be
        -- substituted to an export reference. Only when the destructuring would assign to
        -- re-aliased or multi-exported names (where native destructuring cannot update all
        -- targets) does `visitDestructuringAssignment` fall back to flattening.
        local assignment = transformers.ConvertVariableDeclarationToAssignmentExpression(self:EmitContext(), node)
        local grandparentNode = self:pushNode(assignment)
        local result = self:visitDestructuringAssignment(assignment:AsBinaryExpression(), true --[[valueIsDiscarded]])
        self:popNode(grandparentNode)
        return result
    end
    local propertyAccess = self:Factory():NewPropertyAccessExpression(
        self:Factory():NewIdentifier("exports"),
        nil, --[[questionDotToken]]
        name,
        NodeFlags.None
    )
    self:EmitContext():AssignCommentAndSourceMapRanges(propertyAccess, name)
    return self:Factory():NewAssignmentExpression(propertyAccess, node.initializer)
end

-- Visits a top-level nested variable statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedVariableStatement(node)
    local statements = nil
    statements = core.Append(statements, self:Visitor():VisitEachChild(node:AsNode()))
    statements = self:appendExportsOfVariableStatement(statements, node)
    return transformers.SingleOrMany(statements, self:Factory())
end

-- Visits a top-level nested `for` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedForStatement(node)
    if node.initializer ~= nil and ast.IsVariableDeclarationList(node.initializer) and node.initializer.flags & NodeFlags.BlockScoped == 0 then
        local exportStatements = self:appendExportsOfVariableDeclarationList(nil --[[statements]], node.initializer:AsVariableDeclarationList(), false --[[isForInOrOfInitializer]])
        if core.Len(exportStatements) > 0 then
            -- given:
            --   export { x }
            --   for (var x = 0; ;) { }
            -- emits:
            --   var x = 0;
            --   exports.x = x;
            --   for (; ;) { }

            local statements = {}
            local varDeclList = self.discardedValueVisitor:VisitNode(node.initializer)
            local varStatement = self:Factory():NewVariableStatement(nil --[[modifiers]], varDeclList)
            statements[#statements + 1] = varStatement
            statements = appendAll(statements, exportStatements)

            local condition = self:Visitor():VisitNode(node.condition)
            local incrementor = self.discardedValueVisitor:VisitNode(node.incrementor)
            local body = self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
            statements[#statements + 1] = self:Factory():UpdateForStatement(
                node,
                nil, --[[initializer]]
                condition,
                incrementor,
                body
            )
            return transformers.SingleOrMany(statements, self:Factory())
        end
    end
    return self:Factory():UpdateForStatement(
        node,
        self.discardedValueVisitor:VisitNode(node.initializer),
        self:Visitor():VisitNode(node.condition),
        self.discardedValueVisitor:VisitNode(node.incrementor),
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
    )
end

-- Visits a top-level nested `for..in` or `for..of` statement as it may contain `var` declarations that are hoisted and
-- may still be exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedForInOrOfStatement(node)
    if ast.IsVariableDeclarationList(node.initializer) and node.initializer.flags & NodeFlags.BlockScoped == 0 then
        local exportStatements = self:appendExportsOfVariableDeclarationList(nil --[[statements]], node.initializer:AsVariableDeclarationList(), true --[[isForInOrOfInitializer]])
        if core.Len(exportStatements) > 0 then
            -- given:
            --   export { x }
            --   for (var x in y) {
            --     ...
            --   }
            -- emits:
            --   for (var x in y) {
            --     exports.x = x;
            --     ...
            --   }

            local initializer = self.discardedValueVisitor:VisitNode(node.initializer)
            local expression = self:Visitor():VisitNode(node.expression)
            local body = self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
            if ast.IsBlock(body) then
                local block = body:AsBlock()
                local bodyStatements = appendAll(appendAll(nil, exportStatements), block.statements.nodes)
                local bodyStatementList = self:Factory():NewNodeList(bodyStatements)
                bodyStatementList.loc = block.statements.loc
                body = self:Factory():UpdateBlock(block, bodyStatementList, block.multiLine)
            else
                local bodyStatements = appendAll(nil, exportStatements)
                bodyStatements[#bodyStatements + 1] = body
                body = self:Factory():NewBlock(self:Factory():NewNodeList(bodyStatements), true --[[multiLine]])
            end
            return self:Factory():UpdateForInOrOfStatement(node, node.awaitModifier, initializer, expression, body)
        end
    end
    return self:Factory():UpdateForInOrOfStatement(
        node,
        node.awaitModifier,
        self.discardedValueVisitor:VisitNode(node.initializer),
        self:Visitor():VisitNode(node.expression),
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
    )
end

-- Visits a top-level nested `do` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedDoStatement(node)
    return self:Factory():UpdateDoStatement(
        node,
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor),
        self:Visitor():VisitNode(node.expression)
    )
end

-- Visits a top-level nested `while` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedWhileStatement(node)
    return self:Factory():UpdateWhileStatement(
        node,
        self:Visitor():VisitNode(node.expression),
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
    )
end

-- Visits a top-level nested labeled statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedLabeledStatement(node)
    local statement = self.topLevelNestedVisitor:VisitEmbeddedStatement(node.statement)
    if statement == nil then
        statement = self:Factory():NewEmptyStatement()
    end
    return self:Factory():UpdateLabeledStatement(node, node.label, statement)
end

-- Visits a top-level nested `with` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedWithStatement(node)
    return self:Factory():UpdateWithStatement(
        node,
        self:Visitor():VisitNode(node.expression),
        self.topLevelNestedVisitor:VisitEmbeddedStatement(node.statement)
    )
end

-- Visits a top-level nested `if` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedIfStatement(node)
    local expression = self:Visitor():VisitNode(node.expression)
    local thenStatement = self.topLevelNestedVisitor:VisitEmbeddedStatement(node.thenStatement)
    if thenStatement == nil then
        thenStatement = self:Factory():NewBlock(self:Factory():NewNodeList(nil), false --[[multiLine]])
    end
    local elseStatement = self.topLevelNestedVisitor:VisitEmbeddedStatement(node.elseStatement)
    return self:Factory():UpdateIfStatement(node, expression, thenStatement, elseStatement)
end

-- Visits a top-level nested `switch` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedSwitchStatement(node)
    return self:Factory():UpdateSwitchStatement(
        node,
        self:Visitor():VisitNode(node.expression),
        self.topLevelNestedVisitor:VisitNode(node.caseBlock)
    )
end

-- Visits a top-level nested case block as it may contain `var` declarations that are hoisted and may still be exported
-- with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedCaseBlock(node)
    return self.topLevelNestedVisitor:VisitEachChild(node:AsNode())
end

-- Visits a top-level nested `case` or `default` clause as it may contain `var` declarations that are hoisted and may
-- still be exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedCaseOrDefaultClause(node)
    return self:Factory():UpdateCaseOrDefaultClause(
        node,
        self:Visitor():VisitNode(node.expression),
        self.topLevelNestedVisitor:VisitNodes(node.statements)
    )
end

-- Visits a top-level nested `try` statement as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedTryStatement(node)
    return self.topLevelNestedVisitor:VisitEachChild(node:AsNode())
end

-- Visits a top-level nested `catch` clause as it may contain `var` declarations that are hoisted and may still be
-- exported with `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedCatchClause(node)
    return self:Factory():UpdateCatchClause(
        node,
        node.variableDeclaration,
        self.topLevelNestedVisitor:VisitNode(node.block)
    )
end

-- Visits a top-level nested block as it may contain `var` declarations that are hoisted and may still be exported with
-- `export {}`.
function CommonJSModuleTransformer:visitTopLevelNestedBlock(node)
    return self.topLevelNestedVisitor:VisitEachChild(node:AsNode())
end

function CommonJSModuleTransformer:visitForStatement(node)
    return self:Factory():UpdateForStatement(
        node,
        self.discardedValueVisitor:VisitNode(node.initializer),
        self:Visitor():VisitNode(node.condition),
        self.discardedValueVisitor:VisitNode(node.incrementor),
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
    )
end

function CommonJSModuleTransformer:visitForInOrOfStatement(node)
    return self:Factory():UpdateForInOrOfStatement(
        node,
        node.awaitModifier,
        self.discardedValueVisitor:VisitNode(node.initializer),
        self:Visitor():VisitNode(node.expression),
        self:EmitContext():VisitIterationBody(node.statement, self.topLevelNestedVisitor)
    )
end

-- Visits an expression statement whose value will be discarded at runtime.
function CommonJSModuleTransformer:visitExpressionStatement(node)
    return self.discardedValueVisitor:VisitEachChild(node:AsNode())
end

-- Visits a `void` expression whose value will be discarded at runtime.
function CommonJSModuleTransformer:visitVoidExpression(node)
    return self.discardedValueVisitor:VisitEachChild(node:AsNode())
end

-- Visits a parenthesized expression whose value may be discarded at runtime.
function CommonJSModuleTransformer:visitParenthesizedExpression(node, resultIsDiscarded)
    local expression = core.IfElse(resultIsDiscarded, self.discardedValueVisitor, self:Visitor()):VisitNode(node.expression)
    return self:Factory():UpdateParenthesizedExpression(node, expression)
end

-- Visits a partially emitted expression whose value may be discarded at runtime.
function CommonJSModuleTransformer:visitPartiallyEmittedExpression(node, resultIsDiscarded)
    local expression = core.IfElse(resultIsDiscarded, self.discardedValueVisitor, self:Visitor()):VisitNode(node.expression)
    return self:Factory():UpdatePartiallyEmittedExpression(node, expression)
end

-- Visits a binary expression whose value may be discarded, or which might contain an assignment to an exported
-- identifier.
function CommonJSModuleTransformer:visitBinaryExpression(node, resultIsDiscarded)
    if ast.IsDestructuringAssignment(node:AsNode()) then
        return self:visitDestructuringAssignment(node, resultIsDiscarded)
    end

    if ast.IsAssignmentExpression(node:AsNode(), false --[[excludeCompoundAssignment]]) then
        return self:visitAssignmentExpression(node)
    end

    if ast.IsCommaExpression(node:AsNode()) then
        return self:visitCommaExpression(node, resultIsDiscarded)
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function CommonJSModuleTransformer:visitAssignmentExpression(node)
    -- When we see an assignment expression whose left-hand side is an exported symbol,
    -- we should ensure all exports of that symbol are updated with the correct value.
    --
    -- - We do not transform generated identifiers unless they are file-level reserved names.
    -- - We do not transform identifiers tagged with the LocalName flag.
    -- - We only transform identifiers that are exported at the top level.
    if ast.IsIdentifier(node.left) and
        (not transformers.IsGeneratedIdentifier(self:EmitContext(), node.left) or moduletransforms.isFileLevelReservedGeneratedIdentifier(self:EmitContext(), node.left)) and
        not transformers.IsLocalName(self:EmitContext(), node.left) then
        local exportedNames = self:getExports(node.left)
        if core.Len(exportedNames) > 0 then
            -- For each additional export of the declaration, apply an export assignment.
            local expression = self:Visitor():VisitEachChild(node:AsNode())
            for _, exportName in ipairs(exportedNames) do
                expression = self:createExportExpression(exportName, expression, node.loc --[[location]], false --[[liveBinding]])
            end
            return expression
        end
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

-- Visits a destructuring assignment which might target an exported identifier.
function CommonJSModuleTransformer:visitDestructuringAssignment(node, valueIsDiscarded)
    if self:destructuringNeedsFlattening(node.left) then
        return transformers.FlattenDestructuringAssignment(
            self,
            node:AsNode(),
            not valueIsDiscarded, --[[needsValue]]
            transformers.FlattenLevel.All,
            function(name, value, location) return self:createAllExportExpressions(name, value, location) end
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- destructuringNeedsFlattening checks whether a destructuring assignment target contains any
-- exported identifiers that need to be flattened into individual export assignments.
function CommonJSModuleTransformer:destructuringNeedsFlattening(node)
    if ast.IsObjectLiteralExpression(node) then
        for _, elem in ipairs(node:Properties() or {}) do
            local k = elem.kind
            if k == Kind.PropertyAssignment then
                if self:destructuringNeedsFlattening(elem:Initializer()) then
                    return true
                end
            elseif k == Kind.ShorthandPropertyAssignment then
                if self:destructuringNeedsFlattening(elem:Name()) then
                    return true
                end
            elseif k == Kind.SpreadAssignment then
                if self:destructuringNeedsFlattening(elem:Expression()) then
                    return true
                end
            elseif k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
                return false
            end
        end
    elseif ast.IsArrayLiteralExpression(node) then
        for _, elem in ipairs(node:AsArrayLiteralExpression().elements.nodes) do
            if ast.IsSpreadElement(elem) then
                if self:destructuringNeedsFlattening(elem:Expression()) then
                    return true
                end
            elseif self:destructuringNeedsFlattening(elem) then
                return true
            end
        end
    elseif ast.IsIdentifier(node) then
        local exportedNames = self:getExports(node)
        if transformers.IsExportName(self:EmitContext(), node) then
            -- The identifier is already wrapped to be an export reference; tolerate up to one
            -- matching export.
            return core.Len(exportedNames) > 1
        end
        if core.Len(exportedNames) == 0 then
            return false
        end
        -- A single direct export whose export name matches the identifier text can be handled
        -- natively: substitution will rewrite the identifier to `exports.X`, so no flattening
        -- is needed. Re-aliased exports (where the export name differs from the local name) or
        -- multi-exported names cannot be expressed natively in a destructuring assignment.
        if #exportedNames == 1 and self:isDirectExport(node) and exportedNames[1]:Text() == node:Text() then
            return false
        end
        return true
    end
    return false
end

-- createAllExportExpressions is the callback used during destructuring flattening to create
-- export expressions for each exported identifier binding.
function CommonJSModuleTransformer:createAllExportExpressions(name, value, location)
    local exportedNames = self:getExports(name)
    if core.Len(exportedNames) > 0 then
        -- If the name is directly exported (i.e., `export let x`), assign to exports.name directly.
        -- Otherwise, assign to the local binding first (i.e., `let x; export { x }`).
        local expression
        if self:isDirectExport(name) then
            -- Create exports.name = value to handle the direct export assignment,
            -- since the Go port doesn't have an onSubstituteNode mechanism to rewrite identifiers.
            local exportName = name:Clone(self:Factory())
            self:EmitContext():AddEmitFlags(exportName, EF.EFNoComments | EF.EFNoSourceMap)
            local propertyAccess = self:Factory():NewPropertyAccessExpression(
                self:Factory():NewIdentifier("exports"),
                nil, --[[questionDotToken]]
                exportName,
                NodeFlags.None
            )
            self:EmitContext():AddEmitFlags(propertyAccess, EF.EFNoComments)
            expression = self:Factory():NewAssignmentExpression(propertyAccess, value)
            self:EmitContext():AssignCommentAndSourceMapRanges(expression, name)
        else
            expression = self:Factory():NewAssignmentExpression(name, value)
        end
        for _, exportName in ipairs(exportedNames) do
            expression = self:createExportExpression(exportName, expression, location, false --[[liveBinding]])
        end
        return expression
    end
    -- If the identifier is directly exported but has no additional export aliases,
    -- still write to exports.name.
    if self:isDirectExport(name) then
        local exportName = name:Clone(self:Factory())
        self:EmitContext():AddEmitFlags(exportName, EF.EFNoComments | EF.EFNoSourceMap)
        local propertyAccess = self:Factory():NewPropertyAccessExpression(
            self:Factory():NewIdentifier("exports"),
            nil, --[[questionDotToken]]
            exportName,
            NodeFlags.None
        )
        self:EmitContext():AddEmitFlags(propertyAccess, EF.EFNoComments)
        local result = self:Factory():NewAssignmentExpression(propertyAccess, value)
        self:EmitContext():AssignCommentAndSourceMapRanges(result, name)
        return result
    end
    return self:Factory():NewAssignmentExpression(name, value)
end

-- isDirectExport checks whether the identifier is directly exported from the source file
-- (e.g., `export let x` or `export function f()`), as opposed to being re-exported via
-- `export { x }` for a locally-declared variable.
function CommonJSModuleTransformer:isDirectExport(name)
    local exportContainer = self.resolver:GetReferencedExportContainer(self:EmitContext():MostOriginal(name), false --[[prefixLocals]])
    return exportContainer ~= nil and ast.IsSourceFile(exportContainer)
end

function CommonJSModuleTransformer:visitAssignmentProperty(node)
    return self:Factory():UpdatePropertyAssignment(
        node,
        nil, --[[modifiers]]
        self:Visitor():VisitNode(node:Name()),
        nil, --[[postfixToken]]
        nil, --[[typeNode]]
        self.assignmentPatternVisitor:VisitNode(node.initializer)
    )
end

function CommonJSModuleTransformer:visitShorthandAssignmentProperty(node)
    local target = self:visitDestructuringAssignmentTargetNoStack(node:Name())
    if ast.IsIdentifier(target) then
        return self:Factory():UpdateShorthandPropertyAssignment(
            node,
            nil, --[[modifiers]]
            target,
            nil, --[[postfixToken]]
            nil, --[[typeNode]]
            node.equalsToken,
            self:Visitor():VisitNode(node.objectAssignmentInitializer)
        )
    end
    if node.objectAssignmentInitializer ~= nil then
        local equalsToken = node.equalsToken
        if equalsToken == nil then
            equalsToken = self:Factory():NewToken(Kind.EqualsToken)
        end
        target = self:Factory():NewBinaryExpression(
            nil, --[[modifiers]]
            target,
            nil, --[[typeNode]]
            equalsToken,
            self:Visitor():VisitNode(node.objectAssignmentInitializer)
        )
    end
    local updated = self:Factory():NewPropertyAssignment(
        nil, --[[modifiers]]
        node:Name(),
        nil, --[[postfixToken]]
        nil, --[[typeNode]]
        target
    )
    self:EmitContext():SetOriginal(updated, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(updated, node:AsNode())
    return updated
end

function CommonJSModuleTransformer:visitAssignmentRestProperty(node)
    return self:Factory():UpdateSpreadAssignment(
        node,
        self:visitDestructuringAssignmentTarget(node.expression)
    )
end

function CommonJSModuleTransformer:visitAssignmentRestElement(node)
    return self:Factory():UpdateSpreadElement(
        node,
        self:visitDestructuringAssignmentTarget(node.expression)
    )
end

function CommonJSModuleTransformer:visitAssignmentElement(node)
    if ast.IsBinaryExpression(node) then
        local n = node:AsBinaryExpression()
        if n.operatorToken.kind == Kind.EqualsToken then
            return self:Factory():UpdateBinaryExpression(
                n,
                nil, --[[modifiers]]
                self:visitDestructuringAssignmentTarget(n.left),
                nil, --[[typeNode]]
                n.operatorToken,
                self:Visitor():VisitNode(n.right)
            )
        end
    end

    return self:visitDestructuringAssignmentTargetNoStack(node)
end

function CommonJSModuleTransformer:visitDestructuringAssignmentTarget(node)
    local grandparentNode = self:pushNode(node)

    local k = node.kind
    if k == Kind.ObjectLiteralExpression or k == Kind.ArrayLiteralExpression then
        node = self:visitAssignmentPatternNoStack(node)
    else
        node = self:visitDestructuringAssignmentTargetNoStack(node)
    end
    self:popNode(grandparentNode)
    return node
end

function CommonJSModuleTransformer:visitDestructuringAssignmentTargetNoStack(node)
    if ast.IsIdentifier(node) and
        (not transformers.IsGeneratedIdentifier(self:EmitContext(), node) or moduletransforms.isFileLevelReservedGeneratedIdentifier(self:EmitContext(), node)) and
        not transformers.IsLocalName(self:EmitContext(), node) then
        local expression = self:visitExpressionIdentifier(node)
        local exportedNames = self:getExports(node)
        if core.Len(exportedNames) > 0 then
            -- transforms:
            --  var x;
            --  export { x }
            --  { x: x } = y
            -- to:
            --  { x: { set value(v) { exports.x = x = v; } }.value } = y

            local value = self:Factory():NewUniqueNameEx("value", {
                flags = printer.GeneratedIdentifierFlagsOptimistic,
            })
            expression = self:Factory():NewAssignmentExpression(expression, value)

            for _, exportName in ipairs(exportedNames) do
                expression = self:createExportExpression(exportName, expression, nil --[[location]], false --[[liveBinding]])
            end

            local statement = self:Factory():NewExpressionStatement(expression)
            local statementList = self:Factory():NewNodeList({ statement })
            local param = self:Factory():NewParameterDeclaration(
                nil, --[[modifiers]]
                nil, --[[dotDotDotToken]]
                value,
                nil, --[[questionToken]]
                nil, --[[type]]
                nil --[[initializer]]
            )
            local valueSetter = self:Factory():NewSetAccessorDeclaration(
                nil, --[[modifiers]]
                self:Factory():NewIdentifier("value"),
                nil, --[[typeParameters]]
                self:Factory():NewNodeList({ param }),
                nil, --[[returnType]]
                nil, --[[fullSignature]]
                self:Factory():NewBlock(statementList, false --[[multiLine]])
            )
            local propertyList = self:Factory():NewNodeList({ valueSetter })
            expression = self:Factory():NewObjectLiteralExpression(propertyList, false --[[multiLine]])
            expression = self:Factory():NewPropertyAccessExpression(expression, nil --[[questionDotToken]], self:Factory():NewIdentifier("value"), NodeFlags.None)
        end
        return expression
    end

    return self:visitNoStack(node, false --[[resultIsDiscarded]])
end

-- Visits a comma expression whose left-hand value is always discard, and whose right-hand value may be discarded at runtime.
function CommonJSModuleTransformer:visitCommaExpression(node, resultIsDiscarded)
    local left = self.discardedValueVisitor:VisitNode(node.left)
    local right = core.IfElse(resultIsDiscarded, self.discardedValueVisitor, self:Visitor()):VisitNode(node.right)
    return self:Factory():UpdateBinaryExpression(node, nil --[[modifiers]], left, nil --[[typeNode]], node.operatorToken, right)
end

-- Visits a prefix unary expression that might modify an exported identifier.
function CommonJSModuleTransformer:visitPrefixUnaryExpression(node, resultIsDiscarded)
    -- When we see a prefix increment expression whose operand is an exported
    -- symbol, we should ensure all exports of that symbol are updated with the correct
    -- value.
    --
    -- - We do not transform generated identifiers for any reason.
    -- - We do not transform identifiers tagged with the LocalName flag.
    -- - We do not transform identifiers that were originally the name of an enum or
    --   namespace due to how they are transformed in TypeScript.
    -- - We only transform identifiers that are exported at the top level.
    if (node.operator == Kind.PlusPlusToken or node.operator == Kind.MinusMinusToken) and
        ast.IsIdentifier(node.operand) and
        not transformers.IsLocalName(self:EmitContext(), node.operand) then
        local exportedNames = self:getExports(node.operand)
        if core.Len(exportedNames) > 0 then
            -- given:
            --   var x = 0;
            --   export { x }
            --   ++x;
            -- emits:
            --   var x = 0;
            --   exports.x = x;
            --   exports.x = ++x;
            -- note:
            --   after the operation, `exports.x` will hold the value of `x` after the increment.

            local expression = self:Factory():UpdatePrefixUnaryExpression(node, node.operator, self:Visitor():VisitNode(node.operand))
            for _, exportName in ipairs(exportedNames) do
                expression = self:createExportExpression(exportName, expression, nil --[[location]], false --[[liveBinding]])
                self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())
            end
            return expression
        end
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- Visits a postfix unary expression that might modify an exported identifier.
function CommonJSModuleTransformer:visitPostfixUnaryExpression(node, resultIsDiscarded)
    -- When we see a postfix increment expression whose operand is an exported
    -- symbol, we should ensure all exports of that symbol are updated with the correct
    -- value.
    --
    -- - We do not transform generated identifiers for any reason.
    -- - We do not transform identifiers tagged with the LocalName flag.
    -- - We do not transform identifiers that were originally the name of an enum or
    --   namespace due to how they are transformed in TypeScript.
    -- - We only transform identifiers that are exported at the top level.
    if (node.operator == Kind.PlusPlusToken or node.operator == Kind.MinusMinusToken) and
        ast.IsIdentifier(node.operand) and
        not transformers.IsLocalName(self:EmitContext(), node.operand) then
        local exportedNames = self:getExports(node.operand)
        if core.Len(exportedNames) > 0 then
            -- given (value is discarded):
            --   var x = 0;
            --   export { x }
            --   x++;
            -- emits:
            --   var x = 0, y;
            --   exports.x = x;
            --   exports.x = (x++, x);
            -- note:
            --   after the operation, `exports.x` will hold the value of `x` after the increment.
            --
            -- given (value is not discarded):
            --   var x = 0, y;
            --   export { x }
            --   y = x++;
            -- emits:
            --   var _a;
            --   var x = 0, y;
            --   exports.x = x;
            --   y = (exports.x = (_a = x++, x), _a);
            -- note:
            --   after the operation, `exports.x` will hold the value of `x` after the increment, while
            --   `y` will hold the value of `x` before the increment.

            local temp = nil
            local expression = self:Factory():UpdatePostfixUnaryExpression(node, self:Visitor():VisitNode(node.operand), node.operator)
            if not resultIsDiscarded then
                temp = self:Factory():NewTempVariable()
                self:EmitContext():AddVariableDeclaration(temp)

                expression = self:Factory():NewAssignmentExpression(temp, expression)
                self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())
            end

            expression = self:Factory():NewCommaExpression(expression, node.operand:Clone(self:Factory()))
            self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())

            for _, exportName in ipairs(exportedNames) do
                expression = self:createExportExpression(exportName, expression, nil --[[location]], false --[[liveBinding]])
                self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())
            end

            if temp ~= nil then
                expression = self:Factory():NewCommaExpression(expression, temp:AsNode())
                self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())
            end

            return expression
        end
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

-- Visits a call expression that might reference an imported symbol and thus require an indirect call, or that might
-- be an `import()` or `require()` call that may need to be rewritten.
function CommonJSModuleTransformer:visitCallExpression(node)
    local needsRewrite = false
    if core.Tristate_IsTrue(self.compilerOptions.rewriteRelativeImportExtensions) then
        if ast.IsImportCall(node:AsNode()) and #node.arguments.nodes > 0 or
            ast.IsInJSFile(node:AsNode()) and ast.IsRequireCall(node:AsNode(), false --[[requireStringLiteralLikeArgument]]) then
            needsRewrite = true
        end
    end
    if ast.IsImportCall(node:AsNode()) and self:shouldTransformImportCall() then
        return self:visitImportCallExpression(node, needsRewrite)
    end
    if needsRewrite then
        return self:shimOrRewriteImportOrRequireCall(node:AsCallExpression())
    end
    if ast.IsIdentifier(node.expression) then
        -- given:
        --   import { f } from "mod";
        --   f();
        -- emits:
        --   const mod_1 = require("mod");
        --   (0, mod_1.f)();
        -- note:
        --   the indirect call is applied by the printer by way of the `EFIndirectCall` emit flag.
        local expression = self:visitExpressionIdentifier(node.expression)
        local updated = self:Factory():UpdateCallExpression(
            node,
            expression,
            node.questionDotToken,
            nil, --[[typeArguments]]
            self:Visitor():VisitNodes(node.arguments),
            node.flags
        )
        if not ast.IsIdentifier(expression) and not transformers.IsHelperName(self:EmitContext(), node.expression) then
            self:EmitContext():AddEmitFlags(updated, EF.EFIndirectCall)
        end
        return updated
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function CommonJSModuleTransformer:shouldTransformImportCall()
    return ast.ShouldTransformImportCall(self.currentSourceFile:FileName(), self.compilerOptions, self.getEmitModuleFormatOfFile(self.currentSourceFile))
end

function CommonJSModuleTransformer:visitImportCallExpression(node, rewriteOrShim)
    if self.moduleKind == ModuleKind.None and self.languageVersion >= core.ScriptTarget.ES2020 then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local externalModuleName = moduletransforms.getExternalModuleNameLiteral(self:Factory(), node:AsNode(), self.currentSourceFile, nil --[[host]], nil --[[resolver]], self.compilerOptions)
    local firstArgument = self:Visitor():VisitNode(core.FirstOrNil(node.arguments.nodes))

    -- Only use the external module name if it differs from the first argument. This allows us to preserve the quote style of the argument on output.
    local argument
    if externalModuleName ~= nil and (firstArgument == nil or not ast.IsStringLiteral(firstArgument) or firstArgument:Text() ~= externalModuleName:Text()) then
        argument = externalModuleName
    elseif firstArgument ~= nil and rewriteOrShim then
        if ast.IsStringLiteral(firstArgument) then
            argument = moduletransforms.rewriteModuleSpecifier(self:EmitContext(), firstArgument, self.compilerOptions)
        else
            argument = self:Factory():NewRewriteRelativeImportExtensionsHelper(firstArgument, self.compilerOptions.jsx == core.JsxEmit.Preserve)
        end
    else
        argument = firstArgument
    end
    return self:createImportCallExpressionCommonJS(argument)
end

function CommonJSModuleTransformer:createImportCallExpressionCommonJS(arg)
    -- import(x)
    -- emit as
    -- Promise.resolve(`${x}`).then((s) => require(s)) /*CommonJS Require*/
    -- We have to wrap require in then callback so that require is done in asynchronously
    -- if we simply do require in resolve callback in Promise constructor. We will execute the loading immediately
    -- If the arg is not inlineable, we have to evaluate and ToString() it in the current scope
    -- Otherwise, we inline it in require() so that it's statically analyzable

    local f = self:Factory()
    local needSyncEval = arg ~= nil and not moduletransforms.isSimpleInlineableExpression(arg)

    local promiseResolveArguments = nil
    if needSyncEval then
        promiseResolveArguments = {
            f:NewTemplateExpression(
                f:NewTemplateHead("", "", ast.TokenFlags.None),
                f:NewNodeList({
                    f:NewTemplateSpan(arg, f:NewTemplateTail("", "", ast.TokenFlags.None)),
                })
            ),
        }
    end
    local promiseResolveCall = f:NewCallExpression(
        f:NewPropertyAccessExpression(
            f:NewIdentifier("Promise"),
            nil, --[[questionDotToken]]
            f:NewIdentifier("resolve"),
            NodeFlags.None
        ),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        f:NewNodeList(promiseResolveArguments),
        NodeFlags.None
    )

    local requireArguments = nil
    if needSyncEval then
        requireArguments = {
            f:NewIdentifier("s"),
        }
    elseif arg ~= nil then
        requireArguments = { arg }
    end

    local requireCall = f:NewImportStarHelper(
        f:NewCallExpression(
            f:NewIdentifier("require"),
            nil, --[[questionDotToken]]
            nil, --[[typeArguments]]
            f:NewNodeList(requireArguments),
            NodeFlags.None
        )
    )

    local parameters = nil
    if needSyncEval then
        parameters = {
            f:NewParameterDeclaration(
                nil, --[[modifiers]]
                nil, --[[dotDotDotToken]]
                f:NewIdentifier("s"),
                nil, --[[questionToken]]
                nil, --[[type]]
                nil --[[initializer]]
            ),
        }
    end

    local function_ = f:NewArrowFunction(
        nil, --[[modifiers]]
        nil, --[[typeParameters]]
        f:NewNodeList(parameters),
        nil, --[[type]]
        nil, --[[fullSignature]]
        f:NewToken(Kind.EqualsGreaterThanToken), --[[equalsGreaterThanToken]]
        requireCall
    )

    local downleveledImport = f:NewCallExpression(
        f:NewPropertyAccessExpression(
            promiseResolveCall,
            nil, --[[questionDotToken]]
            f:NewIdentifier("then"),
            NodeFlags.None
        ),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        f:NewNodeList({ function_ }),
        NodeFlags.None
    )
    return downleveledImport
end

function CommonJSModuleTransformer:shimOrRewriteImportOrRequireCall(node)
    local expression = self:Visitor():VisitNode(node.expression)
    local argumentsList = node.arguments
    if #node.arguments.nodes > 0 then
        local firstArgument = self:Visitor():VisitNode(node.arguments.nodes[1])
        local firstArgumentChanged = false
        if ast.IsStringLiteralLike(firstArgument) then
            local rewritten = moduletransforms.rewriteModuleSpecifier(self:EmitContext(), firstArgument, self.compilerOptions)
            firstArgumentChanged = rewritten ~= firstArgument
            firstArgument = rewritten
        else
            firstArgument = self:Factory():NewRewriteRelativeImportExtensionsHelper(firstArgument, self.compilerOptions.jsx == core.JsxEmit.Preserve)
            firstArgumentChanged = true
        end

        local rest, restChanged = self:Visitor():VisitSlice(core.Slice(node.arguments.nodes, 1, #node.arguments.nodes))
        if firstArgumentChanged or restChanged then
            local arguments = appendAll({ firstArgument }, rest)
            argumentsList = self:Factory():NewNodeList(arguments)
            argumentsList.loc = node.arguments.loc
        end
    end

    return self:Factory():UpdateCallExpression(
        node,
        expression,
        node.questionDotToken,
        nil, --[[typeArguments]]
        argumentsList,
        node.flags
    )
end

-- Visits a tagged template expression that might reference an imported symbol and thus require an indirect call.
function CommonJSModuleTransformer:visitTaggedTemplateExpression(node)
    if ast.IsIdentifier(node.tag) then
        -- given:
        --   import { f } from "mod";
        --   f``;
        -- emits:
        --   const mod_1 = require("mod");
        --   (0, mod_1.f) ``;
        -- note:
        --   the indirect call is applied by the printer by way of the `EFIndirectCall` emit flag.

        local expression = self:visitExpressionIdentifier(node.tag)
        local updated = self:Factory():UpdateTaggedTemplateExpression(
            node,
            expression,
            nil, --[[questionDotToken]]
            nil, --[[typeArguments]]
            self:Visitor():VisitNode(node.template),
            node.flags
        )
        if not ast.IsIdentifier(expression) and not transformers.IsHelperName(self:EmitContext(), node.tag) then
            self:EmitContext():AddEmitFlags(updated, EF.EFIndirectCall)
        end
        return updated
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- Visits a shorthand property assignment that might reference an imported or exported symbol.
function CommonJSModuleTransformer:visitShorthandPropertyAssignment(node)
    local name = node:Name()
    local exportedOrImportedName = self:visitExpressionIdentifier(name)
    if exportedOrImportedName ~= name then
        -- A shorthand property with an assignment initializer is probably part of a
        -- destructuring assignment
        local expression = exportedOrImportedName
        if node.objectAssignmentInitializer ~= nil then
            expression = self:Factory():NewAssignmentExpression(
                expression,
                self:Visitor():VisitNode(node.objectAssignmentInitializer)
            )
        end
        local assignment = self:Factory():NewPropertyAssignment(nil --[[modifiers]], name, nil --[[postfixToken]], nil --[[typeNode]], expression)
        assignment.loc = node.loc
        self:EmitContext():AssignCommentAndSourceMapRanges(assignment, node:AsNode())
        return assignment
    end
    return self:Factory():UpdateShorthandPropertyAssignment(
        node,
        nil, --[[modifiers]]
        exportedOrImportedName,
        nil, --[[postfixToken]]
        nil, --[[typeNode]]
        node.equalsToken,
        self:Visitor():VisitNode(node.objectAssignmentInitializer)
    )
end

-- Visits an identifier that, if it is in an expression position, might reference an imported or exported symbol.
function CommonJSModuleTransformer:visitIdentifier(node)
    if transformers.IsIdentifierReference(node, self.parentNode) then
        return self:visitExpressionIdentifier(node)
    end
    return node
end

-- Visits an identifier in an expression position that might reference an imported or exported symbol.
function CommonJSModuleTransformer:visitExpressionIdentifier(node)
    local info = self:EmitContext():GetAutoGenerateInfo(node)
    if not (info ~= nil and not printer.GeneratedIdentifierFlags_HasAllowNameSubstitution(info.flags)) and
        not transformers.IsHelperName(self:EmitContext(), node) and
        not transformers.IsLocalName(self:EmitContext(), node) and
        not moduletransforms.isDeclarationNameOfEnumOrNamespace(self:EmitContext(), node) then
        local exportContainer = self.resolver:GetReferencedExportContainer(self:EmitContext():MostOriginal(node), transformers.IsExportName(self:EmitContext(), node))
        if exportContainer ~= nil and ast.IsSourceFile(exportContainer) then
            local reference = self:Factory():NewPropertyAccessExpression(
                self:Factory():NewIdentifier("exports"),
                nil, --[[questionDotToken]]
                node:Clone(self:Factory()),
                NodeFlags.None
            )
            self:EmitContext():AssignCommentAndSourceMapRanges(reference, node)
            reference.loc = node.loc
            return reference
        end

        local importDeclaration = self.resolver:GetReferencedImportDeclaration(self:EmitContext():MostOriginal(node))
        if importDeclaration ~= nil then
            if ast.IsImportClause(importDeclaration) then
                local reference = self:Factory():NewPropertyAccessExpression(
                    self:Factory():NewGeneratedNameForNode(importDeclaration.parent),
                    nil, --[[questionDotToken]]
                    self:Factory():NewIdentifier("default"),
                    NodeFlags.None
                )
                self:EmitContext():AssignCommentAndSourceMapRanges(reference, node)
                reference.loc = node.loc
                return reference
            end
            if ast.IsImportSpecifier(importDeclaration) then
                local name = importDeclaration:AsImportSpecifier():PropertyNameOrName()
                local decl = ast.FindAncestor(importDeclaration, ast.IsImportDeclaration)
                local target = self:Factory():NewGeneratedNameForNode(core.Coalesce(decl, importDeclaration))
                local reference
                if ast.IsStringLiteral(name) then
                    reference = self:Factory():NewElementAccessExpression(
                        target,
                        nil, --[[questionDotToken]]
                        self:Factory():NewStringLiteralFromNode(name),
                        NodeFlags.None
                    )
                else
                    local referenceName = name:Clone(self:Factory())
                    self:EmitContext():AddEmitFlags(referenceName, EF.EFNoSourceMap | EF.EFNoComments)
                    reference = self:Factory():NewPropertyAccessExpression(
                        target,
                        nil, --[[questionDotToken]]
                        referenceName,
                        NodeFlags.None
                    )
                end
                self:EmitContext():AssignCommentAndSourceMapRanges(reference, node)
                reference.loc = node.loc
                return reference
            end
        end
    end
    return node
end

-- Gets the exported names of an identifier, if it is exported.
function CommonJSModuleTransformer:getExports(name)
    if not transformers.IsGeneratedIdentifier(self:EmitContext(), name) then
        local importDeclaration = self.resolver:GetReferencedImportDeclaration(self:EmitContext():MostOriginal(name))
        if importDeclaration ~= nil then
            return self.currentModuleInfo.exportedBindings:Get(importDeclaration)
        end

        -- An exported namespace or enum may merge with an ambient declaration, which won't show up in .js emit, so
        -- we analyze all value exports of a symbol.
        local bindingsSet = collections.NewSet()
        local bindings = nil
        local declarations = self.resolver:GetReferencedValueDeclarations(self:EmitContext():MostOriginal(name))
        if declarations ~= nil then
            for _, declaration in ipairs(declarations) do
                local exportedBindings = self.currentModuleInfo.exportedBindings:Get(declaration)
                for _, binding in ipairs(exportedBindings or {}) do
                    if not bindingsSet:Has(binding) then
                        bindingsSet:Add(binding)
                        bindings = core.Append(bindings, binding)
                    end
                end
            end
            return bindings
        end
    elseif moduletransforms.isFileLevelReservedGeneratedIdentifier(self:EmitContext(), name) then
        local exportSpecifiers = self.currentModuleInfo.exportSpecifiers:Get(name:Text())
        if exportSpecifiers ~= nil then
            local exportedNames = nil
            for _, exportSpecifier in ipairs(exportSpecifiers) do
                exportedNames = core.Append(exportedNames, exportSpecifier:Name())
            end
            return exportedNames
        end
    end
    return nil
end
