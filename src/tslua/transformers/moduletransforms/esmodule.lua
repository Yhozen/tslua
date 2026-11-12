local moduletransforms = require("tslua.transformers.moduletransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModuleKind = core.ModuleKind
local EF = printer.EmitFlags

local ESModuleTransformer = transformers.NewTransformerType()
moduletransforms.ESModuleTransformer = ESModuleTransformer

-- importRequireStatements: { statements = []Statement, requireHelperName = IdentifierNode }

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

function moduletransforms.NewESModuleTransformer(opts)
    local compilerOptions = opts.compilerOptions
    local tx = setmetatable({
        compilerOptions = compilerOptions,
        resolver = opts.resolver,
        getEmitModuleFormatOfFile = opts.getEmitModuleFormatOfFile,
        currentSourceFile = nil,
        importRequireStatements = nil,
        helperNameSubstitutions = nil,
    }, ESModuleTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end

-- Visits source elements that are not top-level or top-level nested statements.
function ESModuleTransformer:visit(node)
    local k = node.kind
    if k == Kind.SourceFile then
        node = self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.ImportDeclaration then
        node = self:visitImportDeclaration(node:AsImportDeclaration())
    elseif k == Kind.ImportEqualsDeclaration then
        node = self:visitImportEqualsDeclaration(node:AsImportEqualsDeclaration())
    elseif k == Kind.ExportAssignment then
        node = self:visitExportAssignment(node:AsExportAssignment())
    elseif k == Kind.ExportDeclaration then
        node = self:visitExportDeclaration(node:AsExportDeclaration())
    elseif k == Kind.CallExpression then
        node = self:visitCallExpression(node:AsCallExpression())
    else
        node = self:Visitor():VisitEachChild(node)
    end
    return node
end

function ESModuleTransformer:visitSourceFile(node)
    if node.isDeclarationFile or
        not (ast.IsExternalModule(node) or self.compilerOptions:GetIsolatedModules()) then
        return node:AsNode()
    end

    self.currentSourceFile = node
    self.importRequireStatements = nil

    local result = self:Visitor():VisitEachChild(node:AsNode()):AsSourceFile()
    self:EmitContext():AddEmitHelper(result:AsNode(), table.unpack(self:EmitContext():ReadEmitHelpers() or {}))

    local externalHelpersImportDeclaration = moduletransforms.createExternalHelpersImportDeclarationIfNeeded(self:EmitContext(), result, self.compilerOptions, self.getEmitModuleFormatOfFile(node), false --[[hasExportStarsToExportValues]], false --[[hasImportStar]], false --[[hasImportDefault]])
    if externalHelpersImportDeclaration ~= nil or self.importRequireStatements ~= nil then
        local prologue, rest = self:Factory():SplitStandardPrologue(result.statements.nodes)
        local custom
        custom, rest = self:Factory():SplitCustomPrologue(rest)
        local statements = appendAll(nil, prologue)
        statements = appendAll(statements, custom)
        if externalHelpersImportDeclaration ~= nil then
            -- The helpers import must be visited so that `import x = require("tslib")`
            -- (TypeScript-only syntax) is transformed to `const x = require("tslib")`
            -- for CJS output files via visitImportEqualsDeclaration.
            statements = core.Append(statements, self:Visitor():VisitNode(externalHelpersImportDeclaration))
        end
        if self.importRequireStatements ~= nil then
            statements = appendAll(statements, self.importRequireStatements.statements)
        end
        statements = appendAll(statements, rest)
        local statementList = self:Factory():NewNodeList(statements)
        statementList.loc = result.statements.loc
        result = self:Factory():UpdateSourceFile(result, statementList, node.endOfFileToken):AsSourceFile()
    end

    if ast.IsExternalModule(result) and
        self.compilerOptions:GetEmitModuleKind() ~= ModuleKind.Preserve and
        not core.Some(result.statements.nodes, ast.IsExternalModuleIndicator) then
        local statements = appendAll(nil, result.statements.nodes)
        statements[#statements + 1] = moduletransforms.createEmptyImports(self:Factory())
        local statementList = self:Factory():NewNodeList(statements)
        statementList.loc = result.statements.loc
        result = self:Factory():UpdateSourceFile(result, statementList, node.endOfFileToken):AsSourceFile()
    end

    self.importRequireStatements = nil
    self.currentSourceFile = nil
    return result:AsNode()
end

function ESModuleTransformer:visitImportDeclaration(node)
    if not core.Tristate_IsTrue(self.compilerOptions.rewriteRelativeImportExtensions) then
        return node:AsNode()
    end
    local updatedModuleSpecifier = moduletransforms.rewriteModuleSpecifier(self:EmitContext(), node.moduleSpecifier, self.compilerOptions)
    return self:Factory():UpdateImportDeclaration(
        node,
        nil, --[[modifiers]]
        self:Visitor():VisitNode(node.importClause),
        updatedModuleSpecifier,
        self:Visitor():VisitNode(node.attributes)
    )
end

function ESModuleTransformer:visitImportEqualsDeclaration(node)
    -- Though an error in es2020 modules, in node-flavor es2020 modules, we can helpfully transform this to a synthetic `require` call
    -- To give easy access to a synchronous `require` in node-flavor esm. We do the transform even in scenarios where we error, but `import.meta.url`
    -- is available, just because the output is reasonable for a node-like runtime.
    if self.compilerOptions:GetEmitModuleKind() < ModuleKind.Node16 then
        return nil
    end

    if not ast.IsExternalModuleImportEqualsDeclaration(node:AsNode()) then
        error("import= for internal module references should be handled in an earlier transformer.", 0)
    end

    local varStatement = self:Factory():NewVariableStatement(
        nil, --[[modifiers]]
        self:Factory():NewVariableDeclarationList(
            self:Factory():NewNodeList({
                self:Factory():NewVariableDeclaration(
                    node:Name():Clone(self:Factory()),
                    nil, --[[exclamationToken]]
                    nil, --[[type]]
                    self:createRequireCall(node:AsNode())
                ),
            }),
            NodeFlags.Const
        )
    )
    self:EmitContext():SetOriginal(varStatement, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(varStatement, node:AsNode())

    local statements = {}
    statements[#statements + 1] = varStatement
    statements = self:appendExportsOfImportEqualsDeclaration(statements, node)
    return transformers.SingleOrMany(statements, self:Factory())
end

function ESModuleTransformer:appendExportsOfImportEqualsDeclaration(statements, node)
    if ast.HasSyntacticModifier(node:AsNode(), ast.ModifierFlags.Export) then
        statements = core.Append(statements, self:Factory():NewExportDeclaration(
            nil, --[[modifiers]]
            false, --[[isTypeOnly]]
            self:Factory():NewNamedExports(
                self:Factory():NewNodeList({
                    self:Factory():NewExportSpecifier(
                        false, --[[isTypeOnly]]
                        nil, --[[propertyName]]
                        node:Name():Clone(self:Factory())
                    ),
                })
            ),
            nil, --[[moduleSpecifier]]
            nil --[[attributes]]
        ))
    end
    return statements
end

function ESModuleTransformer:visitExportAssignment(node)
    if not node.isExportEquals then
        return self:Visitor():VisitEachChild(node:AsNode())
    end
    if self.compilerOptions:GetEmitModuleKind() ~= ModuleKind.Preserve then
        -- Elide `export=` as it is not legal with --module ES6
        return nil
    end
    local statement = self:Factory():NewExpressionStatement(
        self:Factory():NewAssignmentExpression(
            self:Factory():NewPropertyAccessExpression(
                self:Factory():NewIdentifier("module"),
                nil, --[[questionDotToken]]
                self:Factory():NewIdentifier("exports"),
                NodeFlags.None
            ),
            self:Visitor():VisitNode(node.expression)
        )
    )
    self:EmitContext():SetOriginal(statement, node:AsNode())
    return statement
end

function ESModuleTransformer:visitExportDeclaration(node)
    if node.moduleSpecifier == nil then
        return node:AsNode()
    end

    local updatedModuleSpecifier = moduletransforms.rewriteModuleSpecifier(self:EmitContext(), node.moduleSpecifier, self.compilerOptions)
    if self.compilerOptions.module > ModuleKind.ES2015 or node.exportClause == nil or not ast.IsNamespaceExport(node.exportClause) then
        -- Either ill-formed or don't need to be transformed.
        return self:Factory():UpdateExportDeclaration(
            node,
            nil, --[[modifiers]]
            false, --[[isTypeOnly]]
            node.exportClause,
            updatedModuleSpecifier,
            self:Visitor():VisitNode(node.attributes)
        )
    end

    local oldIdentifier = node.exportClause:Name()
    local synthName = self:Factory():NewGeneratedNameForNode(oldIdentifier)
    local importDecl = self:Factory():NewImportDeclaration(
        nil, --[[modifiers]]
        self:Factory():NewImportClause(
            Kind.Unknown, --[[phaseModifier]]
            nil, --[[name]]
            self:Factory():NewNamespaceImport(synthName)
        ),
        updatedModuleSpecifier,
        self:Visitor():VisitNode(node.attributes)
    )
    self:EmitContext():SetOriginal(importDecl, node.exportClause)

    local exportDecl
    if ast.IsExportNamespaceAsDefaultDeclaration(node:AsNode()) then
        exportDecl = self:Factory():NewExportAssignment(nil --[[modifiers]], false --[[isExportEquals]], nil --[[typeNode]], synthName)
    else
        exportDecl = self:Factory():NewExportDeclaration(
            nil, --[[modifiers]]
            false, --[[isTypeOnly]]
            self:Factory():NewNamedExports(
                self:Factory():NewNodeList({
                    self:Factory():NewExportSpecifier(false --[[isTypeOnly]], synthName, oldIdentifier),
                })
            ),
            nil, --[[moduleSpecifier]]
            nil --[[attributes]]
        )
    end
    self:EmitContext():SetOriginal(exportDecl, node:AsNode())
    return transformers.SingleOrMany({ importDecl, exportDecl }, self:Factory())
end

function ESModuleTransformer:visitCallExpression(node)
    if core.Tristate_IsTrue(self.compilerOptions.rewriteRelativeImportExtensions) then
        if ast.IsImportCall(node:AsNode()) and core.Len(node.arguments.nodes) > 0 or
            ast.IsInJSFile(node:AsNode()) and ast.IsRequireCall(node:AsNode(), false --[[requireStringLiteralLikeArgument]]) then
            return self:visitImportOrRequireCall(node)
        end
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function ESModuleTransformer:visitImportOrRequireCall(node)
    if core.Len(node.arguments.nodes) == 0 then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local expression = self:Visitor():VisitNode(node.expression)

    local argument
    if ast.IsStringLiteralLike(node.arguments.nodes[1]) then
        argument = moduletransforms.rewriteModuleSpecifier(self:EmitContext(), node.arguments.nodes[1], self.compilerOptions)
    else
        argument = self:Factory():NewRewriteRelativeImportExtensionsHelper(node.arguments.nodes[1], self.compilerOptions.jsx == core.JsxEmit.Preserve)
    end

    local arguments = {}
    arguments[#arguments + 1] = argument

    local rest = core.FirstResult(self:Visitor():VisitSlice(core.Slice(node.arguments.nodes, 1, core.Len(node.arguments.nodes))))
    arguments = appendAll(arguments, rest)

    local argumentList = self:Factory():NewNodeList(arguments)
    argumentList.loc = node.arguments.loc
    return self:Factory():UpdateCallExpression(
        node,
        expression,
        node.questionDotToken,
        nil, --[[typeArguments]]
        argumentList,
        node.flags
    )
end

function ESModuleTransformer:createRequireCall(node)
    local moduleName = moduletransforms.getExternalModuleNameLiteral(self:Factory(), node, self.currentSourceFile, nil --[[host]], nil --[[emitResolver]], self.compilerOptions)

    local args = nil
    if moduleName ~= nil then
        args = core.Append(args, moduletransforms.rewriteModuleSpecifier(self:EmitContext(), moduleName, self.compilerOptions))
    end

    if self.compilerOptions:GetEmitModuleKind() == ModuleKind.Preserve then
        return self:Factory():NewCallExpression(
            self:Factory():NewIdentifier("require"),
            nil, --[[questionDotToken]]
            nil, --[[typeArguments]]
            self:Factory():NewNodeList(args),
            NodeFlags.None
        )
    end

    if self.importRequireStatements == nil then
        local createRequireName = self:Factory():NewUniqueNameEx("_createRequire", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
        local importStatement = self:Factory():NewImportDeclaration(
            nil, --[[modifiers]]
            self:Factory():NewImportClause(
                Kind.Unknown, --[[phaseModifier]]
                nil, --[[name]]
                self:Factory():NewNamedImports(
                    self:Factory():NewNodeList({
                        self:Factory():NewImportSpecifier(
                            false, --[[isTypeOnly]]
                            self:Factory():NewIdentifier("createRequire"),
                            createRequireName
                        ),
                    })
                )
            ),
            self:Factory():NewStringLiteral("module", ast.TokenFlags.None),
            nil --[[attributes]]
        )
        self:EmitContext():AddEmitFlags(importStatement, EF.EFCustomPrologue)

        local requireHelperName = self:Factory():NewUniqueNameEx("__require", { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel })
        local requireStatement = self:Factory():NewVariableStatement(
            nil, --[[modifiers]]
            self:Factory():NewVariableDeclarationList(
                self:Factory():NewNodeList({
                    self:Factory():NewVariableDeclaration(
                        requireHelperName,
                        nil, --[[exclamationToken]]
                        nil, --[[type]]
                        self:Factory():NewCallExpression(
                            createRequireName:Clone(self:Factory()),
                            nil, --[[questionDotToken]]
                            nil, --[[typeArguments]]
                            self:Factory():NewNodeList({
                                self:Factory():NewPropertyAccessExpression(
                                    self:Factory():NewMetaProperty(Kind.ImportKeyword, self:Factory():NewIdentifier("meta")),
                                    nil, --[[questionDotToken]]
                                    self:Factory():NewIdentifier("url"),
                                    NodeFlags.None
                                ),
                            }),
                            NodeFlags.None
                        )
                    ),
                }),
                NodeFlags.Const
            )
        )
        self:EmitContext():AddEmitFlags(requireStatement, EF.EFCustomPrologue)
        self.importRequireStatements = {
            statements = { importStatement, requireStatement },
            requireHelperName = requireHelperName,
        }
    end

    return self:Factory():NewCallExpression(
        self.importRequireStatements.requireHelperName:Clone(self:Factory()),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:Factory():NewNodeList(args),
        NodeFlags.None
    )
end
