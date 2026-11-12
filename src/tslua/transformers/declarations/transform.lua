local declarations = require("tslua.transformers.declarations")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SymbolFlags = ast.SymbolFlags
local TokenFlags = ast.TokenFlags
local JSDeclarationKind = ast.JSDeclarationKind
local EmitFlags = printer.EmitFlags
local LanguageVariant = core.LanguageVariant

-- ReferencedFilePair: { file = ast.SourceFile, ref = ast.FileReference }

-- OutputPaths interface: DeclarationFilePath() string, JsFilePath() string

-- DeclarationEmitHost interface (used to be passed in the TransformationContext, which is now just an EmitContext):
--   modulespecifiers.ModuleSpecifierGenerationHost methods,
--   GetCurrentDirectory() string, UseCaseSensitiveFileNames() bool,
--   GetSourceFileFromReference(origin, ref) ast.SourceFile,
--   GetOutputPathsFor(file, forceDtsPaths) OutputPaths,
--   SourceFileMayBeEmitted(file, forceDtsEmit) bool,
--   GetResolutionModeOverride(node) core.ResolutionMode,
--   GetEffectiveDeclarationFlags(node, flags) ast.ModifierFlags,
--   GetEmitResolver() printer.EmitResolver

-- Lua helpers for Go maps whose values may be nil (Go distinguishes a nil value from a missing key).
local mapNil = setmetatable({}, { __name = "declarations.mapNil" })

local function mapSet(m, k, v)
    if v == nil then
        m[k] = mapNil
    else
        m[k] = v
    end
end

local function mapGet(m, k)
    local v = m[k]
    if v == nil then
        return nil, false
    end
    if v == mapNil then
        return nil, true
    end
    return v, true
end

-- thisPropertyAssignmentKey is a Go struct { name string; node *ast.Node; isStatic, isPrivate bool }
-- used as a map key; in Lua it is encoded into a string key.
function declarations.getThisPropertyAssignmentKey(name, node, isStatic)
    local isPrivate = ast.IsPrivateIdentifier(name)
    local flags = (isStatic and "1" or "0") .. (isPrivate and "1" or "0")
    if name ~= nil and not ast.IsDynamicName(name) then
        local nameText, ok = ast.TryGetTextOfPropertyName(name)
        if ok then
            return "s" .. flags .. ":" .. nameText
        end
    end
    return "n" .. flags .. ":" .. tostring(ast.GetNodeId(node))
end

-- DeclarationTransformer embeds transformers.Transformer. Fields: host, compilerOptions, tracker, state,
-- resolver, declarationFilePath, declarationMapPath, needsDeclare, needsScopeFixMarker,
-- resultHasScopeMarker, enclosingDeclaration, resultHasExternalModuleIndicator,
-- suppressNewDiagnosticContexts, witnessedCjsExports, lateStatementReplacementMap, expandoHosts
-- (store the result of transforming expando hosts so they can be inserted later if the host is
-- actually referenced), expandoMembers (store any found expando _members_ after transforming them so
-- *if* the host is referenced, they can be emitted alongside it), deferredExpandoAssignments (expando
-- assignments whose host wasn't visible when collected, processed if the host is late-marked
-- visible), seenProperties, thisPropertyAssignmentsCollected, rawReferencedFiles,
-- rawTypeReferenceDirectives, rawLibReferenceDirectives, bindingNameVisitor, expressionVisitor,
-- cjsExportAssignmentVisitor, exportStrippingVisitor, thisPropertyVisitor, cjsExportAssignment,
-- cjsExportMembers, cjsExportAssignmentName (tracks the name node used for `export =` in CJS
-- module.exports assignments), declareStrippingVisitor, inClassExpressionDeclaration (true when
-- serializing members of a class expression kept as a class declaration).
local DeclarationTransformer = transformers.NewTransformerType()
declarations.DeclarationTransformer = DeclarationTransformer

-- TODO: Convert to transformers.TransformerFactory signature to allow more automatic composition with other transforms
function declarations.NewDeclarationTransformer(host, context, compilerOptions, declarationFilePath, declarationMapPath)
    local resolver = host:GetEmitResolver()
    local state = setmetatable({
        lateMarkedStatements = nil,
        diagnostics = nil,
        getSymbolAccessibilityDiagnostic = nil,
        errorNameNode = nil,
        isolatedDeclarations = core.Tristate_IsTrue(compilerOptions.isolatedDeclarations),
        stripInternal = core.Tristate_IsTrue(compilerOptions.stripInternal),
        currentSourceFile = nil,
        resolver = resolver,
        reportExpandoFunctionErrors = nil,
    }, declarations.SymbolTrackerSharedState)
    local tracker = declarations.NewSymbolTracker(host, resolver, state)
    -- TODO: Use new host GetOutputPathsFor method instead of passing in entrypoint paths (which will also better support bundled emit)
    local tx = setmetatable({
        host = host,
        compilerOptions = compilerOptions,
        tracker = tracker,
        state = state,
        resolver = resolver,
        declarationFilePath = declarationFilePath or "",
        declarationMapPath = declarationMapPath or "",

        needsDeclare = false,
        needsScopeFixMarker = false,
        resultHasScopeMarker = false,
        enclosingDeclaration = nil,
        resultHasExternalModuleIndicator = false,
        suppressNewDiagnosticContexts = false,
        witnessedCjsExports = collections.NewSet(),
        lateStatementReplacementMap = nil,
        expandoHosts = nil,
        expandoMembers = nil,
        deferredExpandoAssignments = nil,
        seenProperties = collections.NewSet(),
        thisPropertyAssignmentsCollected = nil,
        rawReferencedFiles = nil,
        rawTypeReferenceDirectives = nil,
        rawLibReferenceDirectives = nil,

        cjsExportAssignment = nil,
        cjsExportMembers = nil,
        cjsExportAssignmentName = nil,
        inClassExpressionDeclaration = false,
    }, DeclarationTransformer)
    tx.state.reportExpandoFunctionErrors = function(node)
        if not tx.state.isolatedDeclarations then
            return
        end
        local props = resolver:GetPropertiesOfContainerFunction(node)
        for _, p in ipairs(props or {}) do
            if ast.IsExpandoPropertyDeclaration(p.valueDeclaration) then
                local errorTarget = p.valueDeclaration
                if ast.IsBinaryExpression(errorTarget) then
                    errorTarget = errorTarget:AsBinaryExpression().left
                end
                tx.state:addDiagnostic(declarations.createDiagnosticForNode(errorTarget, diagnostics.Assigning_properties_to_functions_without_declaring_them_is_not_supported_with_isolatedDeclarations_Add_an_explicit_declaration_for_the_properties_assigned_to_this_function))
            end
        end
    end
    tx:NewTransformer(function(node) return tx:visit(node) end, context)
    tx.bindingNameVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitBindingName(node) end)
    tx.expressionVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitNestedExpression(node) end)
    tx.exportStrippingVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:stripExportModifiers(node) end)
    tx.thisPropertyVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitThisPropertyAssignments(node) end)
    tx.cjsExportAssignmentVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:visitCJSExportAssignments(node) end)
    tx.declareStrippingVisitor = tx:EmitContext():NewNodeVisitor(function(node) return tx:stripDeclareModifiers(node) end)
    return tx
end

function DeclarationTransformer:GetDiagnostics()
    return self.state.diagnostics
end

function DeclarationTransformer:shouldStripInternal(node)
    return self.state.stripInternal and node ~= nil and self:isInternalDeclaration(node, self.state.currentSourceFile)
end

function DeclarationTransformer:isInternalDeclaration(node, sourceFile)
    if node == nil then
        return false
    end
    local parseTreeNode = self:EmitContext():MostOriginal(node)
    if not ast.IsParseTreeNode(parseTreeNode) then
        return false
    end
    if parseTreeNode.kind == Kind.Parameter then
        local params = parseTreeNode.parent:Parameters()
        local paramIdx = core.FindIndex(params, function(p)
            return p == parseTreeNode
        end)
        local previousSibling
        if paramIdx > 0 then
            previousSibling = params[paramIdx]
        end

        local text = sourceFile:Text()
        local commentRanges = {}

        if previousSibling ~= nil then
            -- to handle
            -- ... parameters, /** @internal */
            -- public param: string
            local trailingPos = scanner.SkipTriviaEx(text, previousSibling:End() + 1, { stopAtComments = true })
            for comment in scanner.GetTrailingCommentRanges(self:Factory():AsNodeFactory(), text, trailingPos) do
                commentRanges[#commentRanges + 1] = comment
            end
            for comment in scanner.GetLeadingCommentRanges(self:Factory():AsNodeFactory(), text, node:Pos()) do
                commentRanges[#commentRanges + 1] = comment
            end
        else
            local trailingPos = scanner.SkipTriviaEx(text, node:Pos(), { stopAtComments = true })
            for comment in scanner.GetTrailingCommentRanges(self:Factory():AsNodeFactory(), text, trailingPos) do
                commentRanges[#commentRanges + 1] = comment
            end
        end

        if #commentRanges > 0 then
            return declarations.hasInternalAnnotation(commentRanges[#commentRanges], sourceFile)
        end
        return false
    end

    for commentRange in self:getLeadingCommentRangesOfNode(parseTreeNode, sourceFile) do
        if declarations.hasInternalAnnotation(commentRange, sourceFile) then
            return true
        end
    end
    return false
end

-- Go returns an iter.Seq (nil for no comments); in Lua this returns an iterator (empty for nil).
function DeclarationTransformer:getLeadingCommentRangesOfNode(node, sourceFile)
    if node == nil or node.kind == Kind.JsxText then
        return function() return nil end
    end
    return scanner.GetLeadingCommentRanges(self:Factory():AsNodeFactory(), sourceFile:Text(), node:Pos())
end

function declarations.hasInternalAnnotation(commentRange, sourceFile)
    local comment = string.sub(sourceFile:Text(), commentRange:Pos() + 1, commentRange:End())
    return string.find(comment, "@internal", 1, true) ~= nil
end

declarations.declarationEmitNodeBuilderFlags = nodebuilder.Flags.MultilineObjectLiterals |
    nodebuilder.Flags.WriteClassExpressionAsTypeLiteral |
    nodebuilder.Flags.UseTypeOfFunction |
    nodebuilder.Flags.UseStructuralFallback |
    nodebuilder.Flags.AllowEmptyTuple |
    nodebuilder.Flags.GenerateNamesForShadowedTypeParams |
    nodebuilder.Flags.NoTruncation

declarations.declarationEmitInternalNodeBuilderFlags = nodebuilder.InternalFlags.AllowUnresolvedNames

local declarationStatementKinds = ast.kindSet(
    Kind.FunctionDeclaration,
    Kind.ModuleDeclaration,
    Kind.ImportEqualsDeclaration,
    Kind.InterfaceDeclaration,
    Kind.ClassDeclaration,
    Kind.JSTypeAliasDeclaration,
    Kind.TypeAliasDeclaration,
    Kind.EnumDeclaration,
    Kind.VariableStatement,
    Kind.ImportDeclaration,
    Kind.JSImportDeclaration,
    Kind.ExportDeclaration,
    Kind.ExportAssignment
)

local elidedStatementKinds = ast.kindSet(
    Kind.BreakStatement,
    Kind.ContinueStatement,
    Kind.DebuggerStatement,
    Kind.DoStatement,
    Kind.EmptyStatement,
    Kind.ForInStatement,
    Kind.ForOfStatement,
    Kind.ForStatement,
    Kind.IfStatement,
    Kind.LabeledStatement,
    Kind.ReturnStatement,
    Kind.SwitchStatement,
    Kind.ThrowStatement,
    Kind.TryStatement,
    Kind.WhileStatement,
    Kind.WithStatement,
    Kind.NotEmittedStatement,
    Kind.Block,
    Kind.MissingDeclaration,
    Kind.ExpressionStatement
)

-- functions as both `visitDeclarationStatements` and `transformRoot`, utilitzing SyntaxList nodes
function DeclarationTransformer:visit(node)
    if node == nil then
        return nil
    end
    local kind = node.kind
    if kind == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    -- statements we keep but do something to
    elseif declarationStatementKinds[kind] then
        return self:visitDeclarationStatements(node)
    -- statements we elide
    elseif elidedStatementKinds[kind] then
        return nil
    -- parts of things, things we just visit children of
    else
        return self:visitDeclarationSubtree(node)
    end
end

function declarations.throwDiagnostic(result)
    error("Diagnostic emitted without context", 0)
end

function DeclarationTransformer:visitSourceFile(node)
    self.cjsExportAssignmentName = nil
    if node.isDeclarationFile then
        return node
    end

    self.needsDeclare = true
    self.needsScopeFixMarker = false
    self.resultHasScopeMarker = false
    self.enclosingDeclaration = node
    self.state.getSymbolAccessibilityDiagnostic = declarations.throwDiagnostic
    self.resultHasExternalModuleIndicator = false
    self.suppressNewDiagnosticContexts = false
    self.state.lateMarkedStatements = {}
    self.lateStatementReplacementMap = {}
    self.expandoHosts = {}
    self.expandoMembers = {}
    self.deferredExpandoAssignments = {}
    self.rawReferencedFiles = {}
    self.rawTypeReferenceDirectives = {}
    self.rawLibReferenceDirectives = {}
    self.witnessedCjsExports:Clear()
    self.state.currentSourceFile = node
    self:collectFileReferences(node)
    self.resolver:PrecalculateDeclarationEmitVisibility(self:EmitContext():MostOriginal(node):AsSourceFile())
    local updated = self:transformSourceFile(node)
    self.state.currentSourceFile = nil
    return updated
end

function DeclarationTransformer:collectFileReferences(sourceFile)
    for _, ref in ipairs(sourceFile.referencedFiles or {}) do
        self.rawReferencedFiles[#self.rawReferencedFiles + 1] = { file = sourceFile, ref = ref }
    end
    for _, ref in ipairs(sourceFile.typeReferenceDirectives or {}) do
        self.rawTypeReferenceDirectives[#self.rawTypeReferenceDirectives + 1] = ref
    end
    for _, ref in ipairs(sourceFile.libReferenceDirectives or {}) do
        self.rawLibReferenceDirectives[#self.rawLibReferenceDirectives + 1] = ref
    end
end

function declarations.nodeOrSyntaxListChildren(node)
    if ast.IsSyntaxList(node) then
        return node:AsSyntaxList().children
    end
    return { node }
end

function declarations.flattenSyntaxLists(nodes)
    return core.FlatMap(nodes, declarations.nodeOrSyntaxListChildren)
end

function DeclarationTransformer:appendCjsExports(combinedStatements)
    local result = {}
    if self.cjsExportAssignment ~= nil then
        result[#result + 1] = self.cjsExportAssignment
    end
    for _, n in ipairs(self.cjsExportMembers or {}) do
        result[#result + 1] = n
    end
    for _, n in ipairs(combinedStatements.nodes or {}) do
        result[#result + 1] = n
    end
    local statementNodes = declarations.flattenSyntaxLists(result)
    if core.Len(statementNodes) ~= core.Len(combinedStatements.nodes) then
        combinedStatements = self:Factory():NewNodeList(statementNodes)
    end
    return combinedStatements
end

function DeclarationTransformer:transformSourceFile(node)
    self.cjsExportAssignment = nil
    self.cjsExportAssignmentName = nil
    self.cjsExportMembers = nil
    self.cjsExportAssignmentVisitor:VisitNode(node) -- collect nested module.exports= assignments
    self.expressionVisitor:VisitNode(node) -- collect expando members (requires any export assignment be located in advance)
    local combinedStatements
    local statements = self:Visitor():VisitNodes(node.statements)
    combinedStatements = self:transformAndReplaceLatePaintedStatements(statements)
    combinedStatements = self:appendCjsExports(combinedStatements)
    combinedStatements.loc = statements.loc -- setTextRange
    if ast.IsExternalOrCommonJSModule(node) then
        if ast.IsInJSFile(node) then
            local exportEquals = node.symbol.exports ~= nil and node.symbol.exports[ast.InternalSymbolNameExportEquals] or nil
            if exportEquals ~= nil and core.Len(exportEquals.declarations) > 1 then
                for _, decl in ipairs(exportEquals.declarations) do
                    self.state:addDiagnostic(declarations.createDiagnosticForNode(decl, diagnostics.Multiple_module_exports_assignments_cannot_be_serialized_for_declaration_emit))
                end
            end
        end
        if not self.resultHasExternalModuleIndicator or (self.needsScopeFixMarker and not self.resultHasScopeMarker) then
            local marker = declarations.createEmptyExports(self:Factory():AsNodeFactory())
            local newList = {}
            for _, n in ipairs(combinedStatements.nodes or {}) do
                newList[#newList + 1] = n
            end
            newList[#newList + 1] = marker
            local withMarker = self:Factory():NewNodeList(newList)
            withMarker.loc = combinedStatements.loc
            combinedStatements = withMarker
        end
    end
    local outputFilePath = tspath.GetDirectoryPath(tspath.NormalizeSlashes(self.declarationFilePath))
    local result = self:Factory():UpdateSourceFile(node, combinedStatements, node.endOfFileToken)
    result:AsSourceFile().libReferenceDirectives = self:getLibReferences()
    result:AsSourceFile().typeReferenceDirectives = self:getTypeReferences()
    result:AsSourceFile().isDeclarationFile = true
    result:AsSourceFile().referencedFiles = self:getReferencedFiles(outputFilePath)
    self.cjsExportAssignment = nil
    self.cjsExportAssignmentName = nil
    self.cjsExportMembers = nil
    return result
end

function declarations.createEmptyExports(factory)
    return factory:NewExportDeclaration(nil, false --[[isTypeOnly]], factory:NewNamedExports(factory:NewNodeList({})), nil, nil)
end

function DeclarationTransformer:transformAndReplaceLatePaintedStatements(statements)
    -- This is a `while` loop because `handleSymbolAccessibilityError` can see additional import aliases marked as visible during
    -- error handling which must now be included in the output and themselves checked for errors.
    -- For example:
    -- ```
    -- module A {
    --   export module Q {}
    --   import B = Q;
    --   import C = B;
    --   export import D = C;
    -- }
    -- ```
    -- In such a scenario, only Q and D are initially visible, but we don't consider imports as private names - instead we say they if they are referenced they must
    -- be recorded. So while checking D's visibility we mark C as visible, then we must check C which in turn marks B, completing the chain of
    -- dependent imports and allowing a valid declaration file output. Today, this dependent alias marking only happens for internal import aliases.
    while true do
        if core.Len(self.state.lateMarkedStatements) == 0 then
            break
        end

        local next = self.state.lateMarkedStatements[1]
        self.state.lateMarkedStatements = core.Slice(self.state.lateMarkedStatements, 1, #self.state.lateMarkedStatements)

        local saveNeedsDeclare = self.needsDeclare
        self.needsDeclare = next.parent ~= nil and ast.IsSourceFile(next.parent)

        local result = self:transformTopLevelDeclaration(next)

        self.needsDeclare = saveNeedsDeclare
        local original = self:EmitContext():MostOriginal(next)
        local id = ast.GetNodeId(original)
        mapSet(self.lateStatementReplacementMap, id, result)
    end

    -- And lastly, we need to get the final form of all those indetermine import declarations from before and add them to the output list
    -- (and remove them from the set to examine for outter declarations)
    local results = {}
    for _, statement in ipairs(statements.nodes or {}) do
        if not ast.IsLateVisibilityPaintedStatement(statement) then
            results[#results + 1] = statement
            goto continue
        end
        do
            local original = self:EmitContext():MostOriginal(statement)
            local id = ast.GetNodeId(original)
            local replacement, ok = mapGet(self.lateStatementReplacementMap, id)
            if not ok then
                results[#results + 1] = statement
                goto continue -- not replaced
            end
            if replacement == nil then
                goto continue -- deleted
            end
            if replacement.kind == Kind.SyntaxList then
                if not self.needsScopeFixMarker or not self.resultHasExternalModuleIndicator then
                    for _, elem in ipairs(replacement:AsSyntaxList().children or {}) do
                        if declarations.needsScopeMarker(elem) then
                            self.needsScopeFixMarker = true
                        end
                        if ast.IsSourceFile(statement.parent) and ast.IsExternalModuleIndicator(elem) then
                            self.resultHasExternalModuleIndicator = true
                        end
                    end
                end
                for _, elem in ipairs(replacement:AsSyntaxList().children or {}) do
                    results[#results + 1] = elem
                end
            else
                if declarations.needsScopeMarker(replacement) then
                    self.needsScopeFixMarker = true
                end
                if ast.IsSourceFile(statement.parent) and ast.IsExternalModuleIndicator(replacement) then
                    self.resultHasExternalModuleIndicator = true
                end
                results[#results + 1] = replacement
            end
        end
        ::continue::
    end

    return self:Factory():NewNodeList(results)
end

function DeclarationTransformer:getReferencedFiles(outputFilePath)
    local results = nil
    -- Handle path rewrites for triple slash ref comments
    for _, pair in ipairs(self.rawReferencedFiles) do
        local sourceFile = pair.file
        local ref = pair.ref

        if not ref.preserve then
            goto continue
        end

        do
            local file = self.host:GetSourceFileFromReference(sourceFile, ref)
            if file == nil then
                goto continue
            end

            local declFileName
            if file.isDeclarationFile then
                declFileName = file:FileName()
            else
                local paths = self.host:GetOutputPathsFor(file, true)
                -- Try to use output path for referenced file, or output js path if that doesn't exist, or the input path if all else fails
                declFileName = paths:DeclarationFilePath()
                if #declFileName == 0 then
                    declFileName = paths:JsFilePath()
                end
                if #declFileName == 0 then
                    declFileName = file:FileName()
                end
            end
            -- Should only be missing if the source file is missing a fileName (at which point we can't name a reference to it anyway)
            -- TODO: Shouldn't this be a crash or assert instead of a silent continue?
            if #declFileName == 0 then
                goto continue
            end

            local fileName = tspath.GetRelativePathToDirectoryOrUrl(
                outputFilePath,
                declFileName,
                false, -- TODO: Probably unsafe to assume this isn't a URL, but that's what strada does
                {
                    currentDirectory = self.host:GetCurrentDirectory(),
                    useCaseSensitiveFileNames = self.host:UseCaseSensitiveFileNames(),
                }
            )

            results = core.Append(results, ast.NewFileReference(-1, -1, fileName, ref.resolutionMode, ref.preserve))
        end
        ::continue::
    end
    return results
end

function DeclarationTransformer:getLibReferences()
    local result = nil
    -- clone retained references
    for _, ref in ipairs(self.rawLibReferenceDirectives) do
        if ref.preserve then
            result = core.Append(result, ast.NewFileReference(-1, -1, ref.fileName, ref.resolutionMode, ref.preserve))
        end
    end
    return result
end

function DeclarationTransformer:getTypeReferences()
    local result = nil
    -- clone retained references
    for _, ref in ipairs(self.rawTypeReferenceDirectives) do
        if ref.preserve then
            result = core.Append(result, ast.NewFileReference(-1, -1, ref.fileName, ref.resolutionMode, ref.preserve))
        end
    end
    return result
end

-- Returns (canProduceDiagnostic, cleanup).
function DeclarationTransformer:setupDiagnosticContext(input)
    local canProduceDiagnostic = declarations.canProduceDiagnostics(input)
    local oldWithinObjectLiteralType = self.suppressNewDiagnosticContexts
    local shouldEnterSuppressNewDiagnosticsContextContext = (input.kind == Kind.TypeLiteral or input.kind == Kind.MappedType) and not (input.parent.kind == Kind.TypeAliasDeclaration or input.parent.kind == Kind.JSTypeAliasDeclaration)

    local oldDiag = self.state.getSymbolAccessibilityDiagnostic
    if canProduceDiagnostic and not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(input)
    end
    local oldName = self.state.errorNameNode

    if shouldEnterSuppressNewDiagnosticsContextContext then
        self.suppressNewDiagnosticContexts = true
    end

    return canProduceDiagnostic, function()
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
        self.state.errorNameNode = oldName
        self.suppressNewDiagnosticContexts = oldWithinObjectLiteralType
    end
end

function DeclarationTransformer:visitDeclarationSubtree(input)
    if self:shouldStripInternal(input) then
        return nil
    end
    if ast.IsDeclaration(input) then
        if declarations.isDeclarationAndNotVisible(self:EmitContext(), self.resolver, input) then
            return nil
        end
        if ast.HasDynamicName(input) then
            if self.state.isolatedDeclarations then
                -- Classes and object literals usually elide properties with computed names that are not of a literal type
                -- In isolated declarations TSC needs to error on these as we don't know the type in a DTE.
                if not self.resolver:IsDefinitelyReferenceToGlobalSymbolObject(input:Name():Expression()) then
                    if ast.IsClassDeclaration(input.parent) or ast.IsObjectLiteralExpression(input.parent) then
                        self.state:addDiagnostic(declarations.createDiagnosticForNode(input, diagnostics.Computed_property_names_on_class_or_object_literals_cannot_be_inferred_with_isolatedDeclarations))
                        return nil
                    elseif (ast.IsInterfaceDeclaration(input.parent) or ast.IsTypeLiteralNode(input.parent)) and not ast.IsEntityNameExpression(input:Name():Expression()) then
                        -- Type declarations just need to double-check that the input computed name is an entity name expression
                        self.state:addDiagnostic(declarations.createDiagnosticForNode(input, diagnostics.Computed_properties_must_be_number_or_string_literals_variables_or_dotted_expressions_with_isolatedDeclarations))
                        return nil
                    end
                end
            elseif not self.resolver:IsLateBound(self:EmitContext():ParseNode(input)) or not ast.IsEntityNameExpression(input:Name():Expression()) then
                return nil
            end
        end
    end

    -- Elide implementation signatures from overload sets
    if ast.IsFunctionLike(input) and self.resolver:IsImplementationOfOverload(input) then
        return nil
    end

    if input.kind == Kind.SemicolonClassElement then
        return nil
    end

    if ast.IsHeritageClause(input) and (core.Len(input:AsHeritageClause().types.nodes) == 0 or (#input:AsHeritageClause().types.nodes == 1 and ast.NodeIsMissing(input:AsHeritageClause().types.nodes[1]))) then
        return nil
    end

    local previousEnclosingDeclaration = self.enclosingDeclaration
    if declarations.isEnclosingDeclaration(input) then
        self.enclosingDeclaration = input
    end

    local canProduceDiagnostic, cleanupDiagnosticContext = self:setupDiagnosticContext(input)

    local result
    local kind = input.kind
    if kind == Kind.MappedType then
        result = self:transformMappedTypeNode(input:AsMappedTypeNode())
    elseif kind == Kind.HeritageClause then
        result = self:transformHeritageClause(input:AsHeritageClause())
    elseif kind == Kind.MethodSignature then
        result = self:transformMethodSignatureDeclaration(input:AsMethodSignatureDeclaration())
    elseif kind == Kind.MethodDeclaration then
        result = self:transformMethodDeclaration(input:AsMethodDeclaration())
    elseif kind == Kind.ConstructSignature then
        result = self:transformConstructSignatureDeclaration(input:AsConstructSignatureDeclaration())
    elseif kind == Kind.Constructor then
        result = self:transformConstructorDeclaration(input:AsConstructorDeclaration())
    elseif kind == Kind.GetAccessor then
        result = self:transformGetAccesorDeclaration(input:AsGetAccessorDeclaration())
    elseif kind == Kind.SetAccessor then
        result = self:transformSetAccessorDeclaration(input:AsSetAccessorDeclaration())
    elseif kind == Kind.PropertyDeclaration then
        result = self:transformPropertyDeclaration(input:AsPropertyDeclaration())
    elseif kind == Kind.PropertySignature then
        result = self:transformPropertySignatureDeclaration(input:AsPropertySignatureDeclaration())
    elseif kind == Kind.CallSignature then
        result = self:transformCallSignatureDeclaration(input:AsCallSignatureDeclaration())
    elseif kind == Kind.IndexSignature then
        result = self:transformIndexSignatureDeclaration(input:AsIndexSignatureDeclaration())
    elseif kind == Kind.VariableDeclaration then
        result = self:transformVariableDeclaration(input:AsVariableDeclaration())
    elseif kind == Kind.TypeParameter then
        result = self:transformTypeParameterDeclaration(input:AsTypeParameterDeclaration())
    elseif kind == Kind.ExpressionWithTypeArguments then
        result = self:transformExpressionWithTypeArguments(input:AsExpressionWithTypeArguments())
    elseif kind == Kind.TypeReference then
        result = self:transformTypeReference(input:AsTypeReferenceNode())
    elseif kind == Kind.ConditionalType then
        result = self:transformConditionalTypeNode(input:AsConditionalTypeNode())
    elseif kind == Kind.FunctionType then
        result = self:transformFunctionTypeNode(input:AsFunctionTypeNode())
    elseif kind == Kind.ConstructorType then
        result = self:transformConstructorTypeNode(input:AsConstructorTypeNode())
    elseif kind == Kind.ImportType then
        result = self:transformImportTypeNode(input:AsImportTypeNode())
    elseif kind == Kind.TypeQuery then
        self:checkEntityNameVisibility(input:AsTypeQueryNode().exprName, self.enclosingDeclaration)
        result = self:Visitor():VisitEachChild(input)
    elseif kind == Kind.QualifiedName then
        if input:AsQualifiedName().right.kind == Kind.PrivateIdentifier then
            self.state:addDiagnostic(declarations.createDiagnosticForNode(input, diagnostics.Declaration_emit_elides_private_members_but_0_refers_to_a_private_member_Write_an_explicit_type_here, input:AsQualifiedName().right:Text()))
        end
        result = self:Visitor():VisitEachChild(input)
    elseif kind == Kind.TupleType then
        result = self:Visitor():VisitEachChild(input)
        if result ~= nil then
            if transformers.IsOriginalNodeSingleLine(self:EmitContext(), input) then
                self:EmitContext():AddEmitFlags(result, EmitFlags.EFSingleLine)
            end
        end
    elseif kind == Kind.JSDocTypeExpression then
        result = self:transformJSDocTypeExpression(input:AsJSDocTypeExpression())
    elseif kind == Kind.JSDocTypeLiteral then
        result = self:transformJSDocTypeLiteral(input:AsJSDocTypeLiteral())
    elseif kind == Kind.JSDocPropertyTag then
        result = self:transformJSDocPropertyTag(input:AsJSDocParameterOrPropertyTag())
    elseif kind == Kind.JSDocAllType then
        result = self:transformJSDocAllType(input:AsJSDocAllType())
    elseif kind == Kind.JSDocNullableType then
        result = self:transformJSDocNullableType(input:AsJSDocNullableType())
    elseif kind == Kind.JSDocNonNullableType then
        result = self:transformJSDocNonNullableType(input:AsJSDocNonNullableType())
    elseif kind == Kind.JSDocOptionalType then
        result = self:transformJSDocOptionalType(input:AsJSDocOptionalType())
    elseif kind == Kind.JSDocVariadicType then
        result = self:transformJSDocVariadicType(input:AsJSDocVariadicType())
    else
        result = self:Visitor():VisitEachChild(input)
    end

    if result ~= nil and canProduceDiagnostic and ast.HasDynamicName(input) then
        self:checkName(input)
    end

    self.enclosingDeclaration = previousEnclosingDeclaration
    cleanupDiagnosticContext()
    return result
end

function DeclarationTransformer:checkName(node)
    local oldDiag = self.state.getSymbolAccessibilityDiagnostic
    if not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNodeName(node)
    end
    self.state.errorNameNode = node:Name()
    debug.Assert(ast.HasDynamicName(node)) -- Should only be called with dynamic names
    local entityName = node:Name():Expression()
    self:checkEntityNameVisibility(entityName, self.enclosingDeclaration)
    if not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
    end
    self.state.errorNameNode = nil
end

function DeclarationTransformer:transformMappedTypeNode(input)
    -- handle missing template type nodes, since the printer does not
    local typeNode
    if input.type == nil then
        typeNode = self:Factory():NewKeywordTypeNode(Kind.AnyKeyword)
    else
        typeNode = self:Visitor().visit(input.type)
    end
    return self:Factory():UpdateMappedTypeNode(
        input,
        input.readonlyToken,
        self:Visitor().visit(input.typeParameter),
        self:Visitor().visit(input.nameType),
        input.questionToken,
        typeNode,
        nil
    )
end

function DeclarationTransformer:transformHeritageClause(clause)
    local retainedClauses = core.Filter(clause.types.nodes, function(t)
        local name = ast.GetHeritageClauseElementName(t)
        return ast.IsEntityName(name) or ast.IsEntityNameExpression(name) or
            (clause.token == Kind.ExtendsKeyword and ast.IsExpressionWithTypeArguments(t) and t:Expression().kind == Kind.NullKeyword)
    end)
    if core.Len(retainedClauses) == 0 then
        return nil -- elide empty clause
    end
    if core.Len(retainedClauses) == core.Len(clause.types.nodes) then
        return self:Visitor():VisitEachChild(clause)
    end
    return self:Factory():UpdateHeritageClause(
        clause,
        clause.token,
        self:Visitor():VisitNodes(self:Factory():NewNodeList(retainedClauses))
    )
end

function DeclarationTransformer:transformImportTypeNode(input)
    if not ast.IsLiteralImportTypeNode(input) then
        return input
    end
    return self:Factory():UpdateImportTypeNode(
        input,
        input.isTypeOf,
        self:Factory():UpdateLiteralTypeNode(
            input.argument:AsLiteralTypeNode(),
            self:rewriteModuleSpecifier(input, input.argument:AsLiteralTypeNode().literal)
        ),
        input.attributes,
        input.qualifier,
        self:Visitor():VisitNodes(input.typeArguments)
    )
end

function DeclarationTransformer:transformConstructorTypeNode(input)
    return self:Factory():UpdateConstructorTypeNode(
        input,
        self:ensureModifiers(input),
        self:Visitor():VisitNodes(input.typeParameters),
        self:updateParamList(input, input.parameters),
        self:Visitor().visit(input.type)
    )
end

function DeclarationTransformer:transformFunctionTypeNode(input)
    return self:Factory():UpdateFunctionTypeNode(
        input,
        self:Visitor():VisitNodes(input.typeParameters),
        self:updateParamList(input, input.parameters),
        self:Visitor().visit(input.type)
    )
end

function DeclarationTransformer:transformConditionalTypeNode(input)
    local checkType = self:Visitor().visit(input.checkType)
    local extendsType = self:Visitor().visit(input.extendsType)
    local oldEnclosingDecl = self.enclosingDeclaration
    self.enclosingDeclaration = input.trueType
    local trueType = self:Visitor().visit(input.trueType)
    self.enclosingDeclaration = oldEnclosingDecl
    local falseType = self:Visitor().visit(input.falseType)

    return self:Factory():UpdateConditionalTypeNode(
        input,
        checkType,
        extendsType,
        trueType,
        falseType
    )
end

function DeclarationTransformer:transformTypeReference(input)
    self:checkEntityNameVisibility(input.typeName, self.enclosingDeclaration)
    return self:Visitor():VisitEachChild(input)
end

function DeclarationTransformer:transformExpressionWithTypeArguments(input)
    if ast.IsEntityName(input.expression) or ast.IsEntityNameExpression(input.expression) then
        self:checkEntityNameVisibility(input.expression, self.enclosingDeclaration)
    end
    return self:Visitor():VisitEachChild(input)
end

function DeclarationTransformer:transformTypeParameterDeclaration(input)
    if declarations.isPrivateMethodTypeParameter(self.host, input) and (input.defaultType ~= nil or input.constraint ~= nil) then
        return self:Factory():UpdateTypeParameterDeclaration(
            input,
            input:Modifiers(),
            input:Name(),
            nil,
            input.expression,
            nil
        )
    end
    return self:Visitor():VisitEachChild(input)
end

function DeclarationTransformer:transformVariableDeclaration(input)
    if self.state.currentSourceFile.commonJSModuleIndicator ~= nil and ast.IsVariableDeclarationInitializedToRequire(input) then
        return self:transformCjsRequireVariableDeclaration(input)
    end
    if ast.IsBindingPattern(input:Name()) and declarations.hasAnyBindingInitializers(input:Name():AsBindingPattern()) then
        return self:recreateBindingPattern(input:Name():AsBindingPattern())
    end
    -- Variable declaration types also suppress new diagnostic contexts, provided the contexts wouldn't be made for binding pattern types
    self.suppressNewDiagnosticContexts = true
    return self:Factory():UpdateVariableDeclaration(
        input,
        self.bindingNameVisitor:VisitNode(input:Name()),
        nil,
        self:ensureType(input, false),
        self:ensureNoInitializer(input)
    )
end

function declarations.hasAnyBindingInitializers(bindingPattern)
    for _, elem in ipairs(bindingPattern.elements.nodes or {}) do
        if not ast.IsBindingElement(elem) then
            goto continue
        end
        do
            local e = elem:AsBindingElement()
            if e.initializer ~= nil then
                return true
            end
            if e:Name() ~= nil and ast.IsBindingPattern(e:Name()) and declarations.hasAnyBindingInitializers(e:Name():AsBindingPattern()) then
                return true
            end
        end
        ::continue::
    end
    return false
end

function DeclarationTransformer:transformCjsRequireVariableDeclaration(input)
    local specifier = self:rewriteModuleSpecifier(input, input.initializer:AsCallExpression().arguments.nodes[1])
    if ast.IsIdentifier(input:Name()) then
        -- `const x = require("something")` -> `import x = require("something")`
        return self:Factory():NewImportEqualsDeclaration(nil, false, input:Name(), self:Factory():NewExternalModuleReference(specifier))
    elseif ast.IsArrayBindingPattern(input:Name()) then
        -- TODO: Is this actually reachable? should we error on this?
        return nil
    else -- object binding pattern
        -- `const {x, y: z} = require("something")` -> `import {x, y as z} from "something"`
        local b = input:Name():AsBindingPattern()
        local importSpecifiers = nil
        for _, elem in ipairs(b.elements.nodes or {}) do
            if ast.IsIdentifier(elem:Name()) then
                importSpecifiers = core.Append(importSpecifiers, self:Factory():NewImportSpecifier(false, elem:PropertyName(), elem:Name()))
            end
            -- otherwise nested destructuring, bail
        end
        return self:Factory():NewImportDeclaration(
            nil,
            self:Factory():NewImportClause(
                Kind.Unknown,
                nil,
                self:Factory():NewNamedImports(self:Factory():NewNodeList(importSpecifiers))
            ),
            specifier,
            nil
        )
    end
end

function DeclarationTransformer:recreateBindingPattern(input)
    local results = {}
    for _, elem in ipairs(input.elements.nodes or {}) do
        local result = self:recreateBindingElement(elem:AsBindingElement())
        if result == nil then
            goto continue
        end
        if result.kind == Kind.SyntaxList then
            for _, c in ipairs(result:AsSyntaxList().children or {}) do
                results[#results + 1] = c
            end
        else
            results[#results + 1] = result
        end
        ::continue::
    end
    if #results == 0 then
        return nil
    end
    if #results == 1 then
        return results[1]
    end
    return self:Factory():NewSyntaxList(results)
end

function DeclarationTransformer:recreateBindingElement(e)
    if e:Name() == nil then
        return nil
    end
    if not declarations.getBindingNameVisible(self.resolver, e) then
        return nil
    end
    if ast.IsBindingPattern(e:Name()) then
        return self:recreateBindingPattern(e:Name():AsBindingPattern())
    end
    return self:Factory():NewVariableDeclaration(
        e:Name(),
        nil,
        self:ensureType(e, false),
        nil -- TODO: possible strada bug - not emitting const initialized binding pattern elements?
    )
end

function DeclarationTransformer:transformIndexSignatureDeclaration(input)
    local t = self:Visitor().visit(input.type)
    if t == nil then
        t = self:Factory():NewKeywordTypeNode(Kind.AnyKeyword)
    end
    return self:Factory():UpdateIndexSignatureDeclaration(
        input,
        self:ensureModifiers(input),
        self:updateParamList(input, input.parameters),
        t
    )
end

function DeclarationTransformer:transformCallSignatureDeclaration(input)
    return self:Factory():UpdateCallSignatureDeclaration(
        input,
        self:ensureTypeParams(input, input.typeParameters),
        self:updateParamList(input, input.parameters),
        self:ensureType(input, false)
    )
end

function DeclarationTransformer:transformPropertySignatureDeclaration(input)
    if ast.IsPrivateIdentifier(input:Name()) then
        return nil
    end
    local result = self:Factory():UpdatePropertySignatureDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        input.postfixToken,
        self:ensureType(input, false),
        self:ensureNoInitializer(input) -- TODO: possible strada bug (fixed here) - const property signatures never initialized
    )
    self:preservePartialJsDoc(result, input)
    return result
end

function DeclarationTransformer:transformPropertyDeclaration(input)
    if ast.IsPrivateIdentifier(input:Name()) then
        return nil
    end
    -- Remove definite assignment assertion (!) from declaration files
    local postfixToken = input.postfixToken
    if postfixToken ~= nil and postfixToken.kind == Kind.ExclamationToken then
        postfixToken = nil
    end
    return self:Factory():UpdatePropertyDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        postfixToken,
        self:ensureType(input, false),
        self:ensureNoInitializer(input)
    )
end

function DeclarationTransformer:transformSetAccessorDeclaration(input)
    if ast.IsPrivateIdentifier(input:Name()) then
        return nil
    end

    return self:Factory():UpdateSetAccessorDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        nil, -- accessors shouldn't have type params
        self:updateAccessorParamList(input, self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(input), ModifierFlags.Private) ~= 0),
        nil,
        nil,
        nil
    )
end

function DeclarationTransformer:transformGetAccesorDeclaration(input)
    if ast.IsPrivateIdentifier(input:Name()) then
        return nil
    end
    return self:Factory():UpdateGetAccessorDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        nil, -- accessors shouldn't have type params
        self:updateAccessorParamList(input, self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(input), ModifierFlags.Private) ~= 0),
        self:ensureType(input, false),
        nil,
        nil
    )
end

function DeclarationTransformer:updateAccessorParamList(input, isPrivate)
    local newParams = {}
    if not isPrivate then
        local thisParam = ast.GetThisParameter(input)
        if thisParam ~= nil then
            newParams[#newParams + 1] = self:ensureParameter(thisParam:AsParameterDeclaration())
        end
    end
    if ast.IsSetAccessorDeclaration(input) then
        local valueParam
        if not isPrivate then
            local params = input:AsSetAccessorDeclaration().parameters.nodes or {}
            if #newParams == 1 and #params >= 2 then
                valueParam = self:ensureParameter(params[2]:AsParameterDeclaration())
            elseif #newParams == 0 and #params >= 1 then
                valueParam = self:ensureParameter(params[1]:AsParameterDeclaration())
            end
        end
        if valueParam == nil then
            -- When synthesizing a missing value parameter, emit `value: any` for non-private accessors to match TypeScript's declaration emit behavior.
            local t
            if not isPrivate then
                t = self:Factory():NewKeywordTypeNode(Kind.AnyKeyword)
            end
            valueParam = self:Factory():NewParameterDeclaration(
                nil,
                nil,
                self:Factory():NewIdentifier("value"),
                nil,
                t,
                nil
            )
        end
        newParams[#newParams + 1] = valueParam
    end
    return self:Factory():NewNodeList(newParams)
end

function DeclarationTransformer:transformConstructorDeclaration(input)
    -- A constructor declaration may not have a type annotation
    return self:Factory():UpdateConstructorDeclaration(
        input,
        self:ensureModifiers(input),
        nil, -- no type params
        self:updateParamList(input, input.parameters),
        nil, -- no return type
        nil,
        nil
    )
end

function DeclarationTransformer:transformConstructSignatureDeclaration(input)
    return self:Factory():UpdateConstructSignatureDeclaration(
        input,
        self:ensureTypeParams(input, input.typeParameters),
        self:updateParamList(input, input.parameters),
        self:ensureType(input, false)
    )
end

function DeclarationTransformer:omitPrivateMethodType(input)
    if input:Symbol() ~= nil and core.Len(input:Symbol().declarations) > 0 and input:Symbol().declarations[1] ~= input then
        return nil
    end
    local result = self:Factory():NewPropertyDeclaration(
        self:ensureModifiers(input),
        input:Name(),
        nil,
        nil,
        nil
    )
    self:preserveJsDoc(result, input)
    return result
end

function DeclarationTransformer:transformMethodSignatureDeclaration(input)
    if self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(input), ModifierFlags.Private) ~= 0 then
        return self:omitPrivateMethodType(input)
    elseif ast.IsPrivateIdentifier(input:Name()) then
        return nil
    else
        return self:Factory():UpdateMethodSignatureDeclaration(
            input,
            self:ensureModifiers(input),
            input:Name(),
            input.postfixToken,
            self:ensureTypeParams(input, input.typeParameters),
            self:updateParamList(input, input.parameters),
            self:ensureType(input, false)
        )
    end
end

function DeclarationTransformer:transformMethodDeclaration(input)
    if self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(input), ModifierFlags.Private) ~= 0 then
        return self:omitPrivateMethodType(input)
    elseif ast.IsPrivateIdentifier(input:Name()) then
        return nil
    else
        return self:Factory():UpdateMethodDeclaration(
            input,
            self:ensureModifiers(input),
            nil,
            input:Name(),
            input.postfixToken,
            self:ensureTypeParams(input, input.typeParameters),
            self:updateParamList(input, input.parameters),
            self:ensureType(input, false),
            nil,
            nil
        )
    end
end

function DeclarationTransformer:visitDeclarationStatements(input)
    if self:shouldStripInternal(input) then
        return nil
    end
    local kind = input.kind
    if kind == Kind.ExportDeclaration then
        if ast.IsSourceFile(input.parent) then
            self.resultHasExternalModuleIndicator = true
        end
        self.resultHasScopeMarker = true
        -- Rewrite external module names if necessary
        return self:Factory():UpdateExportDeclaration(
            input:AsExportDeclaration(),
            input:Modifiers(),
            input:IsTypeOnly(),
            input:AsExportDeclaration().exportClause,
            self:rewriteModuleSpecifier(input, input:ModuleSpecifier()),
            self:tryGetResolutionModeOverride(input:AsExportDeclaration().attributes)
        )
    elseif kind == Kind.ExportAssignment then
        return self:transformExportAssignment(input, input, input:Expression(), input:AsExportAssignment().isExportEquals)
    else
        local id = ast.GetNodeId(self:EmitContext():MostOriginal(input))
        if mapGet(self.lateStatementReplacementMap, id) == nil then
            -- Don't actually transform yet; just leave as original node - will be elided/swapped by late pass
            mapSet(self.lateStatementReplacementMap, id, self:transformTopLevelDeclaration(input))
        end
        return input
    end
end

function DeclarationTransformer:tryGetNameOfAssignedExpression(unwrapped)
    local nameNode
    local nameText = ""
    if not ast.IsPropertyAccessExpression(unwrapped) and unwrapped:Name() ~= nil then
        nameText = unwrapped:Name():Text()
    elseif ast.IsIdentifier(unwrapped) then
        nameText = unwrapped:Text()
    end
    if nameText ~= "" and nameText ~= "default" then
        if self.resolver:IsNameResolvable(self.enclosingDeclaration, nameText) then
            -- create a unique name that shares the same text as its' base
            nameNode = self:Factory():NewUniqueNameEx(nameText, { flags = printer.GeneratedIdentifierFlagsOptimistic })
        else
            -- use the node's name as-is, since it's not otherwise in-scope
            nameNode = self:Factory():NewIdentifier(nameText)
        end
    end
    return nameNode
end

function DeclarationTransformer:getNameOfExportedAssignedExpression(unwrapped, isExportEquals)
    local nameNode = self:tryGetNameOfAssignedExpression(unwrapped)
    if nameNode == nil then
        -- fallback to a default name
        if isExportEquals and ast.IsSourceFileJS(self.state.currentSourceFile) then
            -- only JS files prefer to use `_exports` for export assignments - TS has always used `_default` for both `export=` and `export default`
            nameNode = self:Factory():NewUniqueNameEx("_exports", { flags = printer.GeneratedIdentifierFlagsOptimistic })
        else
            nameNode = self:Factory():NewUniqueNameEx("_default", { flags = printer.GeneratedIdentifierFlagsOptimistic })
        end
    end
    self.cjsExportAssignmentName = nameNode
    return nameNode
end

function DeclarationTransformer:declareModifierList()
    if self.needsDeclare then
        return self:Factory():NewModifierList({ self:Factory():NewModifier(Kind.DeclareKeyword) })
    end
    return self:Factory():NewModifierList({})
end

function DeclarationTransformer:transformExportAssignment(input, assignment, expression, isExportEquals)
    if ast.IsSourceFile(input.parent) then
        self.resultHasExternalModuleIndicator = true
    end
    self.resultHasScopeMarker = true
    if ast.IsIdentifier(expression) and (ast.IsSourceFile(input.parent) or ast.IsModuleBlock(input.parent)) then
        local exportAssignment = self:Factory():NewExportAssignment(nil, isExportEquals, nil, expression)
        self:preserveJsDoc(exportAssignment, input)
        return exportAssignment
    end

    -- Check if the expression is a class expression - emit as a class declaration + export assignment
    local unwrapped = ast.SkipOuterExpressions(expression, ast.OuterExpressionKinds.OEKExpressionTypePassthrough)
    local newId = self:getNameOfExportedAssignedExpression(unwrapped, isExportEquals)
    if ast.IsClassExpression(unwrapped) then
        local mods = {}
        if self.needsDeclare then
            mods[#mods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
        end
        local classDecl = self:transformClassExpressionToDeclaration(unwrapped, newId, self:Factory():NewModifierList(mods))
        self:preserveJsDoc(classDecl, input)
        -- Reuse the same name node for the export so unique names resolve consistently
        local exportAssignment = self:Factory():NewExportAssignment(nil, isExportEquals, nil, newId)
        self:removeAllComments(exportAssignment)
        return self:Factory():NewSyntaxList({ exportAssignment, classDecl })
    elseif ast.IsFunctionLike(unwrapped) then
        -- Promote function or arrow function expressions to a function declaration
        local mods = {}
        if self.needsDeclare then
            mods[#mods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
        end
        local fullSignatureType = assignment:Type()
        local funcDecl = self:transformFunctionLikeToDeclaration(unwrapped, newId, self:Factory():NewModifierList(mods), fullSignatureType)
        self:preserveJsDoc(funcDecl, input)
        -- Reuse the same name node for the export so unique names resolve consistently
        local exportAssignment = self:Factory():NewExportAssignment(nil, isExportEquals, nil, newId)
        self:removeAllComments(exportAssignment)
        return self:Factory():NewSyntaxList({ exportAssignment, funcDecl })
    end

    -- expression is non-identifier, create _default typed variable to reference
    self.state.getSymbolAccessibilityDiagnostic = function(_)
        return {
            diagnosticMessage = diagnostics.Default_export_of_the_module_has_or_is_using_private_name_0,
            errorNode = input,
        }
    end
    self.cjsExportAssignmentName = newId
    self.tracker:PushErrorFallbackNode(assignment)
    local type_, initializer
    if ast.IsPrimitiveLiteralValue(declarations.unwrapParenthesizedExpression(expression), true) then
        initializer = self.resolver:CreateLiteralConstValue(self:EmitContext(), self:EmitContext():ParseNode(assignment), self.tracker)
    end
    if initializer == nil then
        type_ = self:ensureType(assignment, false)
    end
    local varDecl = self:Factory():NewVariableDeclaration(newId, nil, type_, initializer)
    self.tracker:PopErrorFallbackNode()
    local modList = self:declareModifierList()
    local statement = self:Factory():NewVariableStatement(modList, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.Const))
    local exportAssignment = self:Factory():NewExportAssignment(nil, isExportEquals, nil, newId)
    -- Remove comments from the export declaration and copy them onto the synthetic _default declaration
    self:preserveJsDoc(statement, input)
    return self:Factory():NewSyntaxList({ statement, exportAssignment })
end

function DeclarationTransformer:transformFunctionLikeToDeclaration(unwrapped, funcName, mods, fullSignatureType)
    local d = unwrapped:FunctionLikeData()
    local sig = d.fullSignature
    if sig == nil then
        sig = fullSignatureType
    end
    if sig == nil then
        return self:Factory():NewFunctionDeclaration(
            mods,
            nil,
            funcName,
            self:ensureTypeParams(unwrapped, d.typeParameters),
            self:updateParamList(unwrapped, d.parameters),
            self:ensureType(unwrapped, false),
            self:Visitor():VisitNode(sig),
            nil
        )
    else
        -- If a full signature type node is present, emit as a variable statement to reuse it
        return self:Factory():NewVariableStatement(
            mods,
            self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ self:Factory():NewVariableDeclaration(funcName, nil, self:Visitor():VisitNode(sig), nil) }), NodeFlags.Const)
        )
    end
end

function DeclarationTransformer:transformBinaryExpressionToExportDeclaration(input, name)
    local propertyName = input:AsBinaryExpression().right

    -- track alias target so referenced declarations are included in the output
    self.tracker:handleSymbolAccessibilityError(self.resolver:IsEntityNameVisible(propertyName, self.enclosingDeclaration))

    if ast.IsIdentifier(name) and propertyName:Text() == name:Text() then
        propertyName = nil
    end

    return self:Factory():NewExportDeclaration(
        nil,
        false,
        self:Factory():NewNamedExports(self:Factory():NewNodeList({ self:Factory():NewExportSpecifier(false, propertyName, name) })),
        nil,
        nil
    )
end

function DeclarationTransformer:transformCommonJSExport(input, name)
    local res = self:transformCommonJSExportWorker(input, name)
    if res == nil then
        return res
    end
    return self:wrapInCJSExportNamespace(res)
end

function DeclarationTransformer:transformCommonJSExportWorker(input, name)
    local nameText = ""
    if ast.IsIdentifier(name) or ast.IsStringLiteral(name) then
        nameText = name:Text()
    end
    if self.witnessedCjsExports:Has(nameText) and nameText ~= "" then
        return nil -- Already emitted this export name
    end
    self.witnessedCjsExports:Add(nameText)
    self.resultHasExternalModuleIndicator = true
    self.resultHasScopeMarker = true
    -- only transform cjs exports to shorthand at the top-level of a source file, otherwise we uniformly emit nested exports with a type annotation
    if declarations.isCommonJSAliasExport(input) and ast.IsExpressionStatement(input.parent) and ast.IsSourceFile(input.parent.parent) then
        -- export { name }
        -- export { source as name }
        return self:transformBinaryExpressionToExportDeclaration(input, name)
    end

    -- Check if the RHS is a class expression - emit as a class declaration instead of a typed variable
    if ast.IsBinaryExpression(input) then
        local rhs = declarations.unwrapParenthesizedExpression(input:AsBinaryExpression().right)
        if ast.IsClassExpression(rhs) then
            local ce = rhs:AsClassExpression()
            local classExprName = ce:Name()
            local hasExprName = classExprName ~= nil and #classExprName:Text() > 0

            if hasExprName then
                -- Set up TrackSymbol watch to detect if the class expression's own
                -- symbol is referenced during member type serialization.
                self.tracker.watchedClassSymbol = rhs:Symbol()
                self.tracker.classSymbolTracked = false
                local result = self:transformCommonJSNamedClassExport(input, name, rhs, classExprName)
                self.tracker.watchedClassSymbol = nil
                self.tracker.classSymbolTracked = false
                return result
            end
            local mods = {}
            mods[#mods + 1] = self:Factory():NewModifier(Kind.ExportKeyword)
            if self.needsDeclare then
                mods[#mods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
            end
            local className = name
            if not ast.IsIdentifier(className) then
                className = self:Factory():NewUniqueNameEx("_class", { flags = printer.GeneratedIdentifierFlagsOptimistic })
            end
            local classDecl = self:transformClassExpressionToDeclaration(rhs, className, self:Factory():NewModifierList(mods))
            self:preserveJsDoc(classDecl, input)
            if not ast.IsIdentifier(name) then
                -- Non-identifier name: emit class declaration + named export
                local exportDecl = self:Factory():NewExportDeclaration(nil, false, self:Factory():NewNamedExports(self:Factory():NewNodeList({ self:Factory():NewExportSpecifier(false, className, name) })), nil, nil)
                self:removeAllComments(exportDecl)
                return self:Factory():NewSyntaxList({ classDecl, exportDecl })
            end
            return classDecl
        end
    end

    if ast.IsIdentifier(name) then
        if name:Text() == "default" then
            -- const _default: Type; export default _default;
            local newId = self:Factory():NewUniqueNameEx("_default", { flags = printer.GeneratedIdentifierFlagsOptimistic })
            self.state.getSymbolAccessibilityDiagnostic = function(_)
                return {
                    diagnosticMessage = diagnostics.Default_export_of_the_module_has_or_is_using_private_name_0,
                    errorNode = input,
                }
            end
            self.tracker:PushErrorFallbackNode(input)
            local type_ = self:ensureType(input, false)
            local varDecl = self:Factory():NewVariableDeclaration(newId, nil, type_, nil)
            self.tracker:PopErrorFallbackNode()
            local modList = self:declareModifierList()
            local statement = self:Factory():NewVariableStatement(modList, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.Const))

            local assignment = self:Factory():NewExportAssignment(input:Modifiers(), false, nil, newId)
            -- Remove comments from the export declaration and copy them onto the synthetic _default declaration
            self:preserveJsDoc(statement, input)
            self:removeAllComments(assignment)
            return self:Factory():NewSyntaxList({ statement, assignment })
        elseif self.host:GetEmitResolver():GetReferencedValueDeclaration(name) == input or self.host:GetEmitResolver():GetReferencedValueDeclaration(name) == nil then
            -- only inline to a export var if the `name` lookup points at this assignment or nothing - if it points at something else, we must use a temp name
            -- export var name: Type
            self.tracker:PushErrorFallbackNode(input)
            local type_ = self:ensureType(input, false)
            local varDecl = self:Factory():NewVariableDeclaration(name, nil, type_, nil)
            self.tracker:PopErrorFallbackNode()
            local modList
            if self.needsDeclare then
                modList = self:Factory():NewModifierList({ self:Factory():NewModifier(Kind.ExportKeyword), self:Factory():NewModifier(Kind.DeclareKeyword) })
            else
                modList = self:Factory():NewModifierList({ self:Factory():NewModifier(Kind.ExportKeyword) })
            end
            return self:Factory():NewVariableStatement(modList, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.None))
        end
    end
    -- const _exported: Type; export {_exported as "name"};
    local newId = self:Factory():NewUniqueNameEx("_exported", { flags = printer.GeneratedIdentifierFlagsOptimistic })
    self.state.getSymbolAccessibilityDiagnostic = function(_)
        return {
            diagnosticMessage = diagnostics.Default_export_of_the_module_has_or_is_using_private_name_0,
            errorNode = input,
        }
    end
    self.tracker:PushErrorFallbackNode(input)
    local type_ = self:ensureType(input, false)
    local varDecl = self:Factory():NewVariableDeclaration(newId, nil, type_, nil)
    self.tracker:PopErrorFallbackNode()
    local modList = self:declareModifierList()
    local statement = self:Factory():NewVariableStatement(modList, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.Const))

    local assignment = self:Factory():NewExportDeclaration(nil, false, self:Factory():NewNamedExports(self:Factory():NewNodeList({ self:Factory():NewExportSpecifier(false, newId, name) })), nil, nil)
    -- Remove comments from the export declaration and copy them onto the synthetic _default declaration
    self:preserveJsDoc(statement, input)
    self:removeAllComments(assignment)
    return self:Factory():NewSyntaxList({ statement, assignment })
end

-- Lua helper: the `hasExprName` branch of Go's transformCommonJSExportWorker (whose deferred
-- reset of the TrackSymbol watch runs in the caller).
function DeclarationTransformer:transformCommonJSNamedClassExport(input, name, rhs, classExprName)
    -- Serialize class members using the class expression name, which
    -- triggers TrackSymbol for any self-referential member types.
    local className = self:Factory():NewIdentifier(classExprName:Text())
    local classMods = { self:Factory():NewModifier(Kind.ExportKeyword) }
    local classDecl = self:transformClassExpressionToDeclaration(rhs, className, self:Factory():NewModifierList(classMods))
    self:preserveJsDoc(classDecl, input)

    -- Determine if namespace isolation is needed:
    -- - The class expression name differs from the export name, OR
    -- - The class's own symbol was used in a member's serialized type
    local namesDiffer = not ast.IsIdentifier(name) or classExprName:Text() ~= name:Text()
    local needsIsolation = namesDiffer or self.tracker.classSymbolTracked

    if needsIsolation then
        local nsName = self:Factory():NewUniqueNameEx("_ns", { flags = printer.GeneratedIdentifierFlagsOptimistic })
        local nsMods = {}
        if self.needsDeclare then
            nsMods[#nsMods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
        end
        local nsDecl = self:Factory():NewModuleDeclaration(
            self:Factory():NewModifierList(nsMods),
            Kind.NamespaceKeyword,
            nsName,
            self:Factory():NewModuleBlock(self:Factory():NewNodeList({ classDecl }))
        )

        local aliasBase = "_exported"
        local nameText = name:Text()
        if ast.IsIdentifier(name) and scanner.IsIdentifierText("_" .. nameText, LanguageVariant.Standard) then
            aliasBase = "_" .. nameText
        end
        local importAlias = self:Factory():NewUniqueNameEx(aliasBase, { flags = printer.GeneratedIdentifierFlagsOptimistic })
        local qualifiedName = self:Factory():NewQualifiedName(nsName, className)
        local importDecl = self:Factory():NewImportEqualsDeclaration(nil, false, importAlias, qualifiedName)

        local exportSpecifier = self:Factory():NewExportSpecifier(false, importAlias, name)
        local exportDecl = self:Factory():NewExportDeclaration(nil, false, self:Factory():NewNamedExports(self:Factory():NewNodeList({ exportSpecifier })), nil, nil)
        self:removeAllComments(exportDecl)

        return self:Factory():NewSyntaxList({ nsDecl, importDecl, exportDecl })
    end

    -- No isolation needed: names match and no self-references.
    -- Update modifiers to include declare if needed.
    local mods = {}
    mods[#mods + 1] = self:Factory():NewModifier(Kind.ExportKeyword)
    if self.needsDeclare then
        mods[#mods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
    end
    classDecl = self:Factory():UpdateClassDeclaration(
        classDecl:AsClassDeclaration(),
        self:Factory():NewModifierList(mods),
        classDecl:AsClassDeclaration():Name(),
        classDecl:AsClassDeclaration().typeParameters,
        classDecl:AsClassDeclaration().heritageClauses,
        classDecl:AsClassDeclaration().members
    )
    return classDecl
end

function DeclarationTransformer:wrapInCJSExportNamespace(content)
    if self.cjsExportAssignmentName == nil then
        return content
    end
    -- Reuse the same name node so unique names resolve consistently with the class/export
    local nsName = self.cjsExportAssignmentName
    local members
    if content.kind == Kind.SyntaxList then
        members = content:AsSyntaxList().children
    else
        members = { content }
    end
    local nsMods = {}
    if self.needsDeclare then
        nsMods[#nsMods + 1] = self:Factory():NewModifier(Kind.DeclareKeyword)
    end
    members = self.declareStrippingVisitor:VisitSlice(members)
    return self:Factory():NewModuleDeclaration(
        self:Factory():NewModifierList(nsMods),
        Kind.NamespaceKeyword,
        nsName,
        self:Factory():NewModuleBlock(self:Factory():NewNodeList(members))
    )
end

function declarations.isCommonJSAliasExport(node)
    if ast.IsBinaryExpression(node) and ast.IsIdentifier(node:AsBinaryExpression().right) then
        local symbol = node:Symbol()
        if symbol ~= nil and core.Len(symbol.declarations) == 1 then
            return true
        end
    end
    return false
end

-- transformClassExpressionToDeclaration converts a class expression into a class declaration
-- for use in CJS export declarations (e.g., exports.K = class K {} or module.exports = class Thing {}).
-- This delegates to the shared buildClassMembers helper to stay in sync with transformClassDeclaration.
function DeclarationTransformer:transformClassExpressionToDeclaration(classExpr, className, modifiers)
    local previousEnclosingDeclaration = self.enclosingDeclaration
    self.enclosingDeclaration = classExpr
    local previousInClassExpressionDeclaration = self.inClassExpressionDeclaration
    self.inClassExpressionDeclaration = true

    local extraMembers
    if ast.IsInJSFile(classExpr) then
        extraMembers = self:collectThisPropertyAssignments(classExpr)
    end
    local members = self:buildClassMembers(classExpr, extraMembers)
    local typeParameters = self:ensureTypeParams(classExpr, classExpr:AsClassExpression().typeParameters)
    local heritageClauses = self:Visitor():VisitNodes(classExpr:AsClassExpression().heritageClauses)

    local result = self:Factory():NewClassDeclaration(
        modifiers,
        className,
        typeParameters,
        heritageClauses,
        members
    )
    self.enclosingDeclaration = previousEnclosingDeclaration
    self.inClassExpressionDeclaration = previousInClassExpressionDeclaration
    return result
end

function DeclarationTransformer:rewriteModuleSpecifier(parent, input)
    if input == nil then
        return nil
    end
    self.resultHasExternalModuleIndicator = self.resultHasExternalModuleIndicator or (parent.kind ~= Kind.ModuleDeclaration and parent.kind ~= Kind.ImportType)
    return input
end

function DeclarationTransformer:tryGetResolutionModeOverride(node)
    if node == nil then
        return node
    end
    local mode = self.host:GetResolutionModeOverride(node)
    if mode ~= core.ModuleKind.ResolutionModeNone then
        return node
    end
    return nil
end

function DeclarationTransformer:preserveJsDoc(updated, original)
    -- Copy comment range from original to updated node so JSDoc comments are preserved
    self:EmitContext():AssignCommentRange(updated, original)
end

function DeclarationTransformer:preservePartialJsDoc(updated, original)
    if original.flags & NodeFlags.Reparsed == 0 then
        return
    end
    local jsdoc = core.FirstOrNil(original:EagerJSDoc(ast.GetSourceFileOfNode(original)))
    if jsdoc == nil then
        return
    end
    local description = scanner.GetTextOfJSDocComment(jsdoc:AsJSDoc().comment)
    if description == "" then
        return
    end
    local comment = "*\n * " .. string.gsub(description, "\n", "\n * ") .. "\n "
    self:EmitContext():AddSyntheticLeadingComment(updated, Kind.MultiLineCommentTrivia, comment, true --[[hasTrailingNewLine]])
end

function DeclarationTransformer:removeAllComments(node)
    self:EmitContext():AddEmitFlags(node, EmitFlags.EFNoComments)
    -- !!! TODO: Also remove synthetic trailing/leading comments added by transforms
    -- emitNode.leadingComments = undefined;
    -- emitNode.trailingComments = undefined;
end

function DeclarationTransformer:ensureType(node, ignorePrivate)
    if not ignorePrivate and self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(node), ModifierFlags.Private) ~= 0 then
        -- Private nodes emit no types (except private parameter properties, whose parameter types are actually visible)
        return nil
    end

    if self:shouldPrintWithInitializer(node) then
        -- Literal const declarations will have an initializer ensured rather than a type
        return nil
    end

    -- Should be removed createTypeOfDeclaration will actually now reuse the existing annotation so there is no real need to duplicate type walking
    -- Left in for now to minimize diff during syntactic type node builder refactor
    if not ast.IsExportAssignment(node) and not ast.IsBindingElement(node) and node:Type() ~= nil and (not ast.IsParameterDeclaration(node) or not self.resolver:RequiresAddingImplicitUndefined(node, nil, self.enclosingDeclaration)) then
        if self.state.currentSourceFile:IsJS() then
            -- JS types have a heap of constructs we can't directly emit into .d.ts files; the node builder contains logic to remap those where possible, so we invoke it here
            -- In strada we always built js declarations symbolically, so all js type nodes went through this postprocessing
            local jsFlags = declarations.declarationEmitNodeBuilderFlags
            if self.inClassExpressionDeclaration then
                jsFlags = jsFlags & ~nodebuilder.Flags.WriteClassExpressionAsTypeLiteral
            end
            local res = self.resolver:TryJSTypeNodeToTypeNode(self:EmitContext(), node:Type(), self.enclosingDeclaration, jsFlags, declarations.declarationEmitInternalNodeBuilderFlags, self.tracker)
            if res ~= nil then
                return res
            end
            -- otherwise, fall back to full serialization
        else
            return self:Visitor().visit(node:Type())
        end
    end

    local oldErrorNameNode = self.state.errorNameNode
    self.state.errorNameNode = node:Name()
    local oldDiag
    if not self.suppressNewDiagnosticContexts then
        oldDiag = self.state.getSymbolAccessibilityDiagnostic
        if declarations.canProduceDiagnostics(node) then
            self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(node)
        end
    end
    local typeNode

    local flags = declarations.declarationEmitNodeBuilderFlags
    if self.inClassExpressionDeclaration then
        flags = flags & ~nodebuilder.Flags.WriteClassExpressionAsTypeLiteral
    end
    if ast.HasInferredType(node) then
        typeNode = self.resolver:CreateTypeOfDeclaration(self:EmitContext(), node, self.enclosingDeclaration, flags, declarations.declarationEmitInternalNodeBuilderFlags, self.tracker)
    elseif ast.IsFunctionLike(node) then
        typeNode = self.resolver:CreateReturnTypeOfSignatureDeclaration(self:EmitContext(), node, self.enclosingDeclaration, flags, declarations.declarationEmitInternalNodeBuilderFlags, self.tracker)
    else
        debug.AssertNever(node)
    end

    self.state.errorNameNode = oldErrorNameNode
    if not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
    end
    if typeNode == nil then
        return self:Factory():NewKeywordTypeNode(Kind.AnyKeyword)
    end
    return typeNode
end

function DeclarationTransformer:shouldPrintWithInitializer(node)
    return declarations.canHaveLiteralInitializer(self.host, node) and node:Initializer() ~= nil and self.resolver:IsLiteralConstDeclaration(self:EmitContext():MostOriginal(node))
end

function DeclarationTransformer:checkEntityNameVisibility(entityName, enclosingDeclaration)
    local visibilityResult = self.resolver:IsEntityNameVisible(entityName, enclosingDeclaration)
    self.tracker:handleSymbolAccessibilityError(visibilityResult)
end

-- Transforms the direct child of a source file into zero or more replacement statements
function DeclarationTransformer:transformTopLevelDeclaration(input)
    if core.Len(self.state.lateMarkedStatements) > 0 then
        -- Remove duplicates of the current statement from the deferred work queue (this was done via orderedRemoveItem in strada - why? to ensure the same backing array? microop?)
        self.state.lateMarkedStatements = core.Filter(self.state.lateMarkedStatements, function(node) return node ~= input end)
    end
    if self:shouldStripInternal(input) then
        return nil
    end
    if input.kind == Kind.ImportEqualsDeclaration then
        return self:transformImportEqualsDeclaration(input:AsImportEqualsDeclaration())
    end
    if input.kind == Kind.ImportDeclaration or input.kind == Kind.JSImportDeclaration then
        local res = self:transformImportDeclaration(input:AsImportDeclaration())
        if res ~= nil and res.kind ~= Kind.ImportDeclaration then
            res = res:Clone(self:Factory())
            res.kind = Kind.ImportDeclaration
            return res
        end
        return res
    end
    if ast.IsDeclaration(input) and declarations.isDeclarationAndNotVisible(self:EmitContext(), self.resolver, input) then
        return nil
    end

    -- !!! TODO: JSDoc support
    -- if (isJSDocImportTag(input)) return;

    -- Elide implementation signatures from overload sets
    if ast.IsFunctionLike(input) and self.resolver:IsImplementationOfOverload(input) then
        return nil
    end
    local original = self:EmitContext():MostOriginal(input)
    local id = ast.GetNodeId(original)
    local _, isExpandoHost = mapGet(self.expandoHosts, id)
    local hasDeferredExpandoAssignments = self.deferredExpandoAssignments[id] ~= nil
    if isExpandoHost or hasDeferredExpandoAssignments then
        return self:createFullExpandoBlock(id)
    end

    local previousEnclosingDeclaration = self.enclosingDeclaration
    if declarations.isEnclosingDeclaration(input) then
        self.enclosingDeclaration = input
    end

    local canProduceDiagnostic = declarations.canProduceDiagnostics(input)
    local oldDiag = self.state.getSymbolAccessibilityDiagnostic
    local oldName = self.state.errorNameNode
    if canProduceDiagnostic then
        self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(input)
    end
    local saveNeedsDeclare = self.needsDeclare

    local result
    local kind = input.kind
    if kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration then
        result = self:transformTypeAliasDeclaration(input:AsTypeAliasDeclaration())
    elseif kind == Kind.InterfaceDeclaration then
        result = self:transformInterfaceDeclaration(input:AsInterfaceDeclaration())
    elseif kind == Kind.FunctionDeclaration then
        result = self:transformFunctionDeclaration(input:AsFunctionDeclaration())
    elseif kind == Kind.ModuleDeclaration then
        result = self:transformModuleDeclaration(input:AsModuleDeclaration())
    elseif kind == Kind.ClassDeclaration then
        result = self:transformClassDeclaration(input:AsClassDeclaration())
    elseif kind == Kind.VariableStatement then
        result = self:transformVariableStatement(input:AsVariableStatement())
    elseif kind == Kind.EnumDeclaration then
        result = self:transformEnumDeclaration(input:AsEnumDeclaration())
    else
        -- Anything left unhandled is an error, so this should be unreachable
        error(string.format("Unhandled top-level node in declaration emit: %q", ast.Kind_String(input.kind)), 0)
    end

    self.enclosingDeclaration = previousEnclosingDeclaration
    self.state.getSymbolAccessibilityDiagnostic = oldDiag
    self.needsDeclare = saveNeedsDeclare
    self.state.errorNameNode = oldName
    return result
end

function DeclarationTransformer:transformTypeAliasDeclaration(input)
    self.needsDeclare = false
    return self:Factory():UpdateTypeAliasDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        self:Visitor():VisitNodes(input.typeParameters),
        self:Visitor().visit(input.type)
    )
end

function DeclarationTransformer:transformInterfaceDeclaration(input)
    return self:Factory():UpdateInterfaceDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        self:Visitor():VisitNodes(input.typeParameters),
        self:Visitor():VisitNodes(input.heritageClauses),
        self:Visitor():VisitNodes(input.members)
    )
end

function DeclarationTransformer:transformFunctionDeclaration(input)
    if self.resolver:IsExpandoFunctionDeclaration(input) then
        self.state.reportExpandoFunctionErrors(input)
    end
    return self:Factory():UpdateFunctionDeclaration(
        input,
        self:ensureModifiers(input),
        nil,
        input:Name(),
        self:ensureTypeParams(input, input.typeParameters),
        self:updateParamList(input, input.parameters),
        self:ensureType(input, false),
        nil, --[[fullSignature]]
        nil
    )
end

function DeclarationTransformer:transformModuleDeclaration(input)
    -- !!! TODO: module declarations are now parsed into nested module objects with export modifiers
    -- It'd be good to collapse those back in the declaration output, but the AST can't represent the
    -- `namespace a.b.c` shape for the printer (without using invalid identifier names).
    local mods = self:ensureModifiers(input)
    local saveNeedsDeclare = self.needsDeclare
    self.needsDeclare = false
    local inner = input.body
    local keyword = input.keyword
    if keyword ~= Kind.GlobalKeyword and (input:Name() == nil or not ast.IsStringLiteral(input:Name())) then
        keyword = Kind.NamespaceKeyword
    end

    if inner ~= nil and inner.kind == Kind.ModuleBlock then
        local oldNeedsScopeFix = self.needsScopeFixMarker
        local oldHasScopeFix = self.resultHasScopeMarker
        self.resultHasScopeMarker = false
        self.needsScopeFixMarker = false
        local statements = self:Visitor():VisitNodes(inner:StatementList())
        local lateStatements = self:transformAndReplaceLatePaintedStatements(statements)
        if input.flags & NodeFlags.Ambient ~= 0 then
            self.needsScopeFixMarker = false -- If it was `declare`'d everything is implicitly exported already, ignore late printed "privates"
        end
        -- With the final list of statements, there are 3 possibilities:
        -- 1. There's an export assignment or export declaration in the namespace - do nothing
        -- 2. Everything is exported and there are no export assignments or export declarations - strip all export modifiers
        -- 3. Some things are exported, some are not, and there's no marker - add an empty marker
        if not ast.IsGlobalScopeAugmentation(input) and not self.resultHasScopeMarker and not declarations.hasScopeMarker(lateStatements) then
            if self.needsScopeFixMarker then
                local nodes = {}
                for _, n in ipairs(lateStatements.nodes or {}) do
                    nodes[#nodes + 1] = n
                end
                nodes[#nodes + 1] = declarations.createEmptyExports(self:Factory():AsNodeFactory())
                lateStatements = self:Factory():NewNodeList(nodes)
            else
                lateStatements = self.exportStrippingVisitor:VisitNodes(lateStatements)
            end
        end

        local body = self:Factory():UpdateModuleBlock(inner:AsModuleBlock(), lateStatements)
        self.needsDeclare = saveNeedsDeclare
        self.needsScopeFixMarker = oldNeedsScopeFix
        self.resultHasScopeMarker = oldHasScopeFix

        return self:Factory():UpdateModuleDeclaration(
            input,
            mods,
            keyword,
            input:Name(),
            body
        )
    end
    if inner ~= nil then
        -- trigger visit. ignore result (is deferred, so is just inner unless elided)
        self:Visitor().visit(inner)
        -- eagerly transform nested namespaces (the nesting doesn't need any elision or painting done)
        local original = self:EmitContext():MostOriginal(inner)
        local id = ast.GetNodeId(original)
        local body = mapGet(self.lateStatementReplacementMap, id)
        self.lateStatementReplacementMap[id] = nil
        return self:Factory():UpdateModuleDeclaration(
            input,
            mods,
            keyword,
            input:Name(),
            body
        )
    end
    return self:Factory():UpdateModuleDeclaration(
        input,
        mods,
        keyword,
        input:Name(),
        nil
    )
end

function DeclarationTransformer:stripExportModifiers(statement)
    if statement == nil then
        return nil
    end
    local parseNode = self:EmitContext():ParseNode(statement)
    if ast.IsImportEqualsDeclaration(statement) or (parseNode ~= nil and self.host:GetEffectiveDeclarationFlags(parseNode, ModifierFlags.Default) ~= 0) or not ast.CanHaveModifiers(statement) then
        -- `export import` statements should remain as-is, as imports are _not_ implicitly exported in an ambient namespace
        -- Likewise, `export default` classes and the like and just be `default`, so we preserve their `export` modifiers, too
        return statement
    end

    local oldFlags = ast.GetCombinedModifierFlags(statement)
    if oldFlags & ModifierFlags.Export == 0 then
        return statement
    end
    local newFlags = oldFlags & (ModifierFlags.All ~ ModifierFlags.Export)
    local modifiers = ast.CreateModifiersFromModifierFlags(newFlags, self:newModifierFunc())
    return ast.ReplaceModifiers(self:Factory():AsNodeFactory(), statement, self:Factory():NewModifierList(modifiers))
end

-- Lua helper: Go passes the method value `tx.Factory().NewModifier`.
function DeclarationTransformer:newModifierFunc()
    local f = self:Factory()
    return function(kind) return f:NewModifier(kind) end
end

-- buildClassMembers builds the member list for a class-like node (ClassDeclaration or ClassExpression).
-- It handles parameter properties, private identifiers, late-bound index signatures, and visited members.
-- Extra members (e.g., this-property assignments from JS files) can be passed via extraMembers (an array or nil).
function DeclarationTransformer:buildClassMembers(classNode, extraMembers)
    local ctor = ast.GetFirstConstructorWithBody(classNode)
    local parameterProperties = {}
    if ctor ~= nil then
        local oldDiag = self.state.getSymbolAccessibilityDiagnostic
        for _, param in ipairs(ctor:AsConstructorDeclaration().parameters.nodes or {}) do
            if not ast.HasSyntacticModifier(param, ModifierFlags.ParameterPropertyModifier) or self:shouldStripInternal(param) then
                goto continue
            end
            self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(param)
            if param:Name().kind == Kind.Identifier then
                local updated = self:Factory():NewPropertyDeclaration(
                    self:ensureModifiers(param),
                    param:Name(),
                    param:QuestionToken(),
                    self:ensureType(param, false),
                    self:ensureNoInitializer(param)
                )
                self:preserveJsDoc(updated, param)
                parameterProperties[#parameterProperties + 1] = updated
            else
                -- Pattern - this is currently an error, but we emit declarations for it somewhat correctly
                for _, p in ipairs(self:walkBindingPattern(param:Name():AsBindingPattern(), param) or {}) do
                    parameterProperties[#parameterProperties + 1] = p
                end
            end
            ::continue::
        end
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
    end

    -- When the class has at least one private identifier, create a unique constant identifier to retain the nominal typing behavior
    -- Prevents other classes with the same public members from being used in place of the current class
    local privateIdentifier
    if core.Some(classNode:ClassLikeData().members.nodes, function(member)
        return member:Name() ~= nil and ast.IsPrivateIdentifier(member:Name())
    end) then
        privateIdentifier = self:Factory():NewPropertyDeclaration(nil, self:Factory():NewPrivateIdentifier("#private"), nil, nil, nil)
    end

    local lateIndexes = self.resolver:CreateLateBoundIndexSignatures(
        self:EmitContext(),
        classNode,
        self.enclosingDeclaration,
        declarations.declarationEmitNodeBuilderFlags,
        declarations.declarationEmitInternalNodeBuilderFlags,
        self.tracker
    )

    local memberNodes = {}
    if privateIdentifier ~= nil then
        memberNodes[#memberNodes + 1] = privateIdentifier
    end
    for _, n in ipairs(lateIndexes or {}) do
        memberNodes[#memberNodes + 1] = n
    end
    for _, n in ipairs(parameterProperties) do
        memberNodes[#memberNodes + 1] = n
    end
    for _, n in ipairs(extraMembers or {}) do
        memberNodes[#memberNodes + 1] = n
    end
    local visitResult = self:Visitor():VisitNodes(classNode:ClassLikeData().members)
    if visitResult ~= nil and core.Len(visitResult.nodes) > 0 then
        for _, n in ipairs(visitResult.nodes) do
            memberNodes[#memberNodes + 1] = n
        end
    end
    return self:Factory():NewNodeList(memberNodes)
end

function DeclarationTransformer:transformClassDeclaration(input)
    local previousEnclosingDeclaration = self.enclosingDeclaration
    self.enclosingDeclaration = input

    self.state.errorNameNode = input:Name()
    self.tracker:PushErrorFallbackNode(input)

    local result = self:transformClassDeclarationWorker(input)

    self.tracker:PopErrorFallbackNode()
    self.enclosingDeclaration = previousEnclosingDeclaration
    return result
end

-- Lua helper: the body of Go's transformClassDeclaration after its deferred restores are set up.
function DeclarationTransformer:transformClassDeclarationWorker(input)
    local modifiers = self:ensureModifiers(input)
    local typeParameters = self:ensureTypeParams(input, input.typeParameters)

    -- Collect this.x property assignments from constructors and static blocks in JS files
    local extraMembers
    if ast.IsInJSFile(input) then
        extraMembers = self:collectThisPropertyAssignments(input)
    end

    local members = self:buildClassMembers(input, extraMembers)

    local extendsClause = declarations.getEffectiveBaseTypeNode(input)

    if extendsClause ~= nil and not ast.IsEntityNameExpression(extendsClause:AsExpressionWithTypeArguments().expression) and extendsClause:AsExpressionWithTypeArguments().expression.kind ~= Kind.NullKeyword then
        self.tracker:ReportInferenceFallback(extendsClause:AsExpressionWithTypeArguments().expression) -- Add an isolated declarations error on this extends clause
        local oldId = "default"
        if ast.NodeIsPresent(input:Name()) and ast.IsIdentifier(input:Name()) and #input:Name():Text() > 0 then
            oldId = input:Name():Text()
        end
        local newId = self:Factory():NewUniqueNameEx(oldId .. "_base", { flags = printer.GeneratedIdentifierFlagsOptimistic })
        self.state.getSymbolAccessibilityDiagnostic = function(_)
            return {
                diagnosticMessage = diagnostics.X_extends_clause_of_exported_class_0_has_or_is_using_private_name_1,
                errorNode = extendsClause,
                typeName = input:Name(),
            }
        end

        local varDecl = self:Factory():NewVariableDeclaration(
            newId,
            nil,
            self.resolver:CreateTypeOfExpression(self:EmitContext(), extendsClause:Expression(), input, declarations.declarationEmitNodeBuilderFlags, declarations.declarationEmitInternalNodeBuilderFlags, self.tracker),
            nil
        )
        local mods
        if self.needsDeclare then
            mods = self:Factory():NewModifierList({ self:Factory():NewModifier(Kind.DeclareKeyword) })
        end
        local statement = self:Factory():NewVariableStatement(
            mods,
            self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.Const)
        )
        local newHeritageClause = self:Factory():UpdateHeritageClause(
            extendsClause.parent:AsHeritageClause(),
            extendsClause.parent:AsHeritageClause().token,
            self:Factory():NewNodeList({
                self:Factory():UpdateExpressionWithTypeArguments(
                    extendsClause:AsExpressionWithTypeArguments(),
                    newId,
                    self:Visitor():VisitNodes(extendsClause:AsExpressionWithTypeArguments().typeArguments)
                ),
            })
        )
        local retainedHeritageClauses = self:Visitor():VisitNodes(input.heritageClauses) -- should just be `implements`
        local heritageList = {
            newHeritageClause,
        }
        if retainedHeritageClauses ~= nil and core.Len(retainedHeritageClauses.nodes) > 0 then
            for _, n in ipairs(retainedHeritageClauses.nodes) do
                heritageList[#heritageList + 1] = n
            end
        end
        local heritageClauses = self:Factory():NewNodeList(heritageList)

        return self:Factory():NewSyntaxList({
            statement,
            self:Factory():UpdateClassDeclaration(
                input,
                modifiers,
                input:Name(),
                typeParameters,
                heritageClauses,
                members
            ),
        })
    end

    return self:Factory():UpdateClassDeclaration(
        input,
        modifiers,
        input:Name(),
        typeParameters,
        self:Visitor():VisitNodes(input.heritageClauses),
        members
    )
end

function DeclarationTransformer:visitThisPropertyAssignments(node)
    local thisTarget
    local isStatic = false
    local thisContainer = ast.GetThisContainer(node, false, false)
    thisTarget = thisContainer.parent
    if thisTarget == nil then
        return nil -- thisContainer was source file, can't have expando-this
    end
    if ast.HasStaticModifier(thisContainer) or ast.IsClassStaticBlockDeclaration(thisContainer) then
        isStatic = true
    end
    if thisTarget ~= self.enclosingDeclaration then
        return nil -- stop searching within new `this` contexts
    end
    -- caseBlock:
    repeat
        if ast.GetAssignmentDeclarationKind(node) == JSDeclarationKind.ThisProperty then
            local name = ast.GetNameOfDeclaration(node)
            local base = self.resolver:GetReferencedMemberValueDeclaration(node)
            local key = declarations.getThisPropertyAssignmentKey(name, node, isStatic)
            if base == nil or self.seenProperties:Has(key) then
                break
            end
            self.seenProperties:Add(key)

            -- problem: this prop might be overriding a prop from a base type. The checker has special bails for override compat comparisons for binary expression properties,
            -- but what we transform to won't - so we either need to match the base type (for example, if it's a getter/setter) or emit nothing
            -- See `checkKindsOfPropertyMemberOverrides` in the checker for what we're trying to satisfy here
            if thisTarget:ClassLikeData().heritageClauses ~= nil and core.Len(thisTarget:ClassLikeData().heritageClauses.nodes) > 0 and not declarations.isClassExtendingNull(thisTarget) then
                -- there is a base type any assignments might be "from"
                self.tracker:ReportInferenceFallback(thisTarget) -- Add an isolated declarations error on this class - we can't know how to transform this prop into an assignment without referring to type information
                if self.resolver:IsThisPropertyAssignmentDeclarationRedundant(node) then
                    break -- skip assignments whose member is already provided by an `extends` base type (an inherited accessor/method, or an identical inherited property)
                    -- TODO: If the property has an explicit `@type` annotation, we should probably emit it (maybe with an `override` modifier) instead of skipping it
                end
            end

            local mods
            if isStatic then
                mods = self:Factory():NewModifierList({ self:Factory():NewModifier(Kind.StaticKeyword) })
            end
            if ast.HasDynamicName(node) then
                if not transformers.IsSimpleInlineableExpression(name) then
                    break -- Member either becomes an index signature or is a reassignment
                end
                self:checkName(node)
                name = self:Factory():NewComputedPropertyName(name) -- Convert `this[foo] = expr` to `[foo]: Type`
            end
            if ast.GetTextOfPropertyName(name) == "constructor" then
                break -- `constructor` is a builtin class member, not allowed to redeclare it
            end
            if ast.IsIdentifier(name) and not scanner.IsIdentifierText(name:Text(), LanguageVariant.Standard) then
                name = self:Factory():NewStringLiteralFromNode(name)
            end
            local prop = self:Factory():NewPropertyDeclaration(
                mods,
                name,
                nil,
                self:ensureType(node, false),
                nil
            )
            if ast.IsExpressionStatement(node.parent) then
                self:preserveJsDoc(prop, node.parent)
            end
            self.thisPropertyAssignmentsCollected[#self.thisPropertyAssignmentsCollected + 1] = prop
        end
    until true
    return self.thisPropertyVisitor:VisitEachChild(node)
end

function declarations.isClassExtendingNull(node)
    if node == nil then
        return false
    end
    local extendsClause = ast.GetHeritageClause(node, Kind.ExtendsKeyword)
    if extendsClause == nil then
        return false
    end
    local types = extendsClause:AsHeritageClause().types
    if types == nil or core.Len(types.nodes) ~= 1 then
        return false
    end
    local expr = types.nodes[1]:AsExpressionWithTypeArguments().expression
    return expr ~= nil and expr.kind == Kind.NullKeyword
end

-- collectThisPropertyAssignments finds `this.x = expr` assignments in constructors, methods, and static blocks
-- of JS classes and synthesizes PropertyDeclaration nodes for each unique property name.
function DeclarationTransformer:collectThisPropertyAssignments(classNode)
    local members = classNode:ClassLikeData().members
    local seen = collections.NewSet()
    -- Pre-populate seen with existing direct member nodes to avoid duplicates
    for _, member in ipairs(members.nodes or {}) do
        if member:Name() ~= nil then
            local isStatic = ast.IsStatic(member)
            seen:Add(declarations.getThisPropertyAssignmentKey(member:Name(), member, isStatic))
        end
    end
    self.seenProperties = seen
    self.thisPropertyAssignmentsCollected = {}

    for _, n in ipairs(members.nodes or {}) do
        self.thisPropertyVisitor:VisitEachChild(n)
    end
    local result = self.thisPropertyAssignmentsCollected
    self.thisPropertyAssignmentsCollected = nil
    self.seenProperties:Clear()
    return result
end

function DeclarationTransformer:walkBindingPattern(pattern, param)
    local elems = nil
    for _, elem in ipairs(pattern.elements.nodes or {}) do
        if ast.IsOmittedExpression(elem) then
            goto continue
        end
        if ast.IsBindingPattern(elem:Name()) then
            for _, e in ipairs(self:walkBindingPattern(elem:Name():AsBindingPattern(), param) or {}) do
                elems = core.Append(elems, e)
            end
            goto continue
        end
        elems = core.Append(elems, self:Factory():NewPropertyDeclaration(
            self:ensureModifiers(param),
            elem:Name(),
            nil, --[[questionOrExclamationToken]]
            self:ensureType(elem, false),
            nil --[[initializer]]
        ))
        ::continue::
    end
    return elems
end

function DeclarationTransformer:transformVariableStatement(input)
    local visible = false
    for _, decl in ipairs(input.declarationList:AsVariableDeclarationList().declarations.nodes or {}) do
        visible = declarations.getBindingNameVisible(self.resolver, decl)
        if visible then
            break
        end
    end
    if not visible then
        return nil
    end

    local inputNodes = input.declarationList:AsVariableDeclarationList().declarations.nodes
    local extraImports
    if self.state.currentSourceFile.commonJSModuleIndicator ~= nil then
        local normalDeclarations
        local imports
        for _, n in ipairs(inputNodes or {}) do
            if ast.IsVariableDeclarationInitializedToRequire(n) then
                imports = core.Append(imports, n)
            else
                normalDeclarations = core.Append(normalDeclarations, n)
            end
        end
        inputNodes = normalDeclarations
        extraImports = self:Visitor():VisitSlice(imports)
    end

    local nodes = self:Visitor():VisitSlice(inputNodes)
    if core.Len(nodes) == 0 then
        if core.Len(extraImports) > 0 then
            return self:Factory():NewSyntaxList(extraImports)
        end
        return nil
    end
    local nodeList = self:Factory():NewNodeList(nodes)

    local modifiers = self:ensureModifiers(input)

    local declList
    if ast.IsVarUsing(input.declarationList) or ast.IsVarAwaitUsing(input.declarationList) then
        declList = self:Factory():NewVariableDeclarationList(nodeList, NodeFlags.Const)
        self:EmitContext():SetOriginal(declList, input.declarationList)
        self:EmitContext():SetCommentRange(declList, input.declarationList.loc)
        declList.loc = input.declarationList.loc
    else
        declList = self:Factory():UpdateVariableDeclarationList(input.declarationList:AsVariableDeclarationList(), nodeList, input.declarationList.flags)
    end
    local res = self:Factory():UpdateVariableStatement(input, modifiers, declList)
    if core.Len(extraImports) > 0 then
        local list = {}
        for _, n in ipairs(extraImports) do
            list[#list + 1] = n
        end
        list[#list + 1] = res
        return self:Factory():NewSyntaxList(list)
    end
    return res
end

function DeclarationTransformer:transformEnumDeclaration(input)
    return self:Factory():UpdateEnumDeclaration(
        input,
        self:ensureModifiers(input),
        input:Name(),
        self:Factory():NewNodeList(core.MapNonNil(input.members.nodes, function(m)
            if self:shouldStripInternal(m) then
                return nil
            end

            -- Rewrite enum values to their constants, if available
            local enumValue = self.resolver:GetEnumMemberValue(m)

            if self.state.isolatedDeclarations and m:Initializer() ~= nil and enumValue.hasExternalReferences and
                -- This will be its own compiler error instead, so don't report.
                not ast.IsComputedPropertyName(m:Name()) then
                self.state:addDiagnostic(declarations.createDiagnosticForNode(m, diagnostics.Enum_member_initializers_must_be_computable_without_references_to_external_symbols_with_isolatedDeclarations))
            end

            local newInitializer
            local value = enumValue.value
            if type(value) == "number" then
                if jsnum.Number_IsInf(value) then
                    if value > 0 then
                        newInitializer = self:Factory():NewIdentifier("Infinity")
                    else
                        newInitializer = self:Factory():NewPrefixUnaryExpression(Kind.MinusToken, self:Factory():NewIdentifier("Infinity"))
                    end
                elseif jsnum.Number_IsNaN(value) then
                    newInitializer = self:Factory():NewIdentifier("NaN")
                elseif value >= 0 then
                    newInitializer = self:Factory():NewNumericLiteral(jsnum.Number_String(value), TokenFlags.None)
                else
                    newInitializer = self:Factory():NewPrefixUnaryExpression(
                        Kind.MinusToken,
                        self:Factory():NewNumericLiteral(jsnum.Number_String(-value), TokenFlags.None)
                    )
                end
            elseif type(value) == "string" then
                newInitializer = self:Factory():NewStringLiteral(value, TokenFlags.None)
            else
                -- nil
                newInitializer = nil
            end
            local result = self:Factory():UpdateEnumMember(m:AsEnumMember(), m:Name(), newInitializer)
            self:preserveJsDoc(result, m)
            return result
        end))
    )
end

function DeclarationTransformer:ensureModifiers(node)
    local currentFlags = ast.GetCombinedModifierFlags(self:EmitContext():ParseNode(node)) & ModifierFlags.All
    local newFlags = self:ensureModifierFlags(node)
    if currentFlags == newFlags then
        -- Elide decorators
        local mods = node:Modifiers()
        if mods == nil then
            return mods
        end
        if declarations.canReuseModifierNodes(mods.nodes) then
            return self:Factory():NewModifierList(core.Filter(mods.nodes, ast.IsModifier))
        end
    end
    local result = ast.CreateModifiersFromModifierFlags(newFlags, self:newModifierFunc())
    if core.Len(result) == 0 then
        return nil
    end
    return self:Factory():NewModifierList(result)
end

function DeclarationTransformer:ensureModifierFlags(node)
    local mask = ModifierFlags.All ~ (ModifierFlags.Public | ModifierFlags.Async | ModifierFlags.Override) -- No async and override modifiers in declaration files
    local additions = ModifierFlags.None
    if self.needsDeclare and not declarations.isAlwaysType(node) then
        additions = ModifierFlags.Ambient
    end
    local parentIsFile = node.parent.kind == Kind.SourceFile
    if not parentIsFile then
        mask = mask ~ ModifierFlags.Ambient
        additions = ModifierFlags.None
    end
    if ast.IsImplicitlyExportedJSDocDeclaration(node) then
        additions = additions | ModifierFlags.Export
    end
    return declarations.maskModifierFlags(node, mask, additions)
end

function DeclarationTransformer:ensureTypeParams(node, params)
    if self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(node), ModifierFlags.Private) ~= 0 then
        return nil
    end
    local typeParameters = self:Visitor():VisitNodes(params)
    if typeParameters ~= nil then
        return typeParameters
    end
    local oldErrorNameNode = self.state.errorNameNode
    self.state.errorNameNode = node:Name()
    local oldDiag
    if not self.suppressNewDiagnosticContexts then
        oldDiag = self.state.getSymbolAccessibilityDiagnostic
        if declarations.canProduceDiagnostics(node) then
            self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(node)
        end
    end

    local data = node:FunctionLikeData()
    if data ~= nil and data.fullSignature ~= nil then
        local nodes = self.resolver:CreateTypeParametersOfSignatureDeclaration(self:EmitContext(), node, self.enclosingDeclaration, declarations.declarationEmitNodeBuilderFlags, declarations.declarationEmitInternalNodeBuilderFlags, self.tracker)
        if nodes ~= nil then
            typeParameters = self:Factory():NewNodeList(nodes)
            typeParameters.loc = node.loc
        end
    end

    self.state.errorNameNode = oldErrorNameNode
    if not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
    end
    return typeParameters
end

function DeclarationTransformer:updateParamList(node, params)
    if self.host:GetEffectiveDeclarationFlags(self:EmitContext():ParseNode(node), ModifierFlags.Private) ~= 0 or core.Len(params.nodes) == 0 then
        return self:Factory():NewNodeList({})
    end
    local results = {}
    for i, p in ipairs(params.nodes) do
        results[i] = self:ensureParameter(p:AsParameterDeclaration())
    end
    return self:Factory():NewNodeList(results)
end

function DeclarationTransformer:ensureParameter(p)
    local oldDiag = self.state.getSymbolAccessibilityDiagnostic
    if not self.suppressNewDiagnosticContexts then
        self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(p)
    end
    local questionToken
    if self.resolver:IsOptionalParameter(p) then
        if p.questionToken ~= nil then
            questionToken = p.questionToken
        else
            questionToken = self:Factory():NewToken(Kind.QuestionToken)
        end
    end
    local result = self:Factory():UpdateParameterDeclaration(
        p,
        nil,
        p.dotDotDotToken,
        self.bindingNameVisitor:VisitNode(p:Name()),
        questionToken,
        self:ensureType(p, true),
        self:ensureNoInitializer(p)
    )
    self.state.getSymbolAccessibilityDiagnostic = oldDiag
    return result
end

function DeclarationTransformer:ensureNoInitializer(node)
    if self:shouldPrintWithInitializer(node) then
        local unwrappedInitializer = declarations.unwrapParenthesizedExpression(node:Initializer())
        if not ast.IsPrimitiveLiteralValue(unwrappedInitializer, true) then
            self.tracker:ReportInferenceFallback(node)
        end
        return self.resolver:CreateLiteralConstValue(self:EmitContext(), self:EmitContext():ParseNode(node), self.tracker)
    end
    return nil
end

function DeclarationTransformer:visitBindingName(node)
    local kind = node.kind
    if kind == Kind.Identifier or kind == Kind.OmittedExpression then
        return node
    elseif kind == Kind.ArrayBindingPattern or kind == Kind.ObjectBindingPattern then
        return node:VisitEachChild(self.bindingNameVisitor)
    elseif kind == Kind.BindingElement then
        if node:PropertyName() ~= nil and ast.IsComputedPropertyName(node:PropertyName()) and ast.IsEntityNameExpression(node:PropertyName():Expression()) then
            self:checkEntityNameVisibility(node:PropertyName():Expression(), self.enclosingDeclaration)
        end
        return self:Factory():UpdateBindingElement(node:AsBindingElement(), node:AsBindingElement().dotDotDotToken, node:PropertyName(), self.bindingNameVisitor:VisitNode(node:Name()), nil --[[initializer]])
    else
        return node
    end
end

function DeclarationTransformer:transformImportEqualsDeclaration(decl)
    if not self.resolver:IsDeclarationVisible(decl) then
        return nil
    end
    if decl.moduleReference.kind == Kind.ExternalModuleReference then
        -- Rewrite external module names if necessary
        local specifier = ast.GetExternalModuleImportEqualsDeclarationExpression(decl)
        return self:Factory():UpdateImportEqualsDeclaration(
            decl,
            decl:Modifiers(),
            decl.isTypeOnly,
            decl:Name(),
            self:Factory():UpdateExternalModuleReference(decl.moduleReference:AsExternalModuleReference(), self:rewriteModuleSpecifier(decl, specifier))
        )
    else
        local oldDiag = self.state.getSymbolAccessibilityDiagnostic
        self.state.getSymbolAccessibilityDiagnostic = declarations.createGetSymbolAccessibilityDiagnosticForNode(decl)
        self:checkEntityNameVisibility(decl.moduleReference, self.enclosingDeclaration)
        self.state.getSymbolAccessibilityDiagnostic = oldDiag
        return decl
    end
end

function DeclarationTransformer:transformImportDeclaration(decl)
    if decl.importClause == nil then
        -- import "mod" - possibly needed for side effects? (global interface patches, module augmentations, etc)
        return self:Factory():UpdateImportDeclaration(
            decl,
            decl:Modifiers(),
            decl.importClause,
            self:rewriteModuleSpecifier(decl, decl.moduleSpecifier),
            self:tryGetResolutionModeOverride(decl.attributes)
        )
    end
    local phaseModifier = decl.importClause:AsImportClause().phaseModifier
    if phaseModifier == Kind.DeferKeyword then
        phaseModifier = Kind.Unknown
    end
    -- The `importClause` visibility corresponds to the default's visibility.
    local visibleDefaultBinding
    if decl.importClause ~= nil and decl.importClause:Name() ~= nil and self.resolver:IsDeclarationVisible(decl.importClause) then
        visibleDefaultBinding = decl.importClause:Name()
    end
    if decl.importClause:AsImportClause().namedBindings == nil then
        -- No named bindings (either namespace or list), meaning the import is just default or should be elided
        if visibleDefaultBinding == nil then
            return nil
        end
        return self:Factory():UpdateImportDeclaration(
            decl,
            decl:Modifiers(),
            self:Factory():UpdateImportClause(
                decl.importClause:AsImportClause(),
                phaseModifier,
                visibleDefaultBinding,
                nil --[[namedBindings]]
            ),
            self:rewriteModuleSpecifier(decl, decl.moduleSpecifier),
            self:tryGetResolutionModeOverride(decl.attributes)
        )
    end
    if decl.importClause:AsImportClause().namedBindings.kind == Kind.NamespaceImport then
        -- Namespace import (optionally with visible default)
        local namedBindings
        if self.resolver:IsDeclarationVisible(decl.importClause:AsImportClause().namedBindings) then
            namedBindings = decl.importClause:AsImportClause().namedBindings
        end
        if visibleDefaultBinding == nil and namedBindings == nil then
            return nil
        end
        return self:Factory():UpdateImportDeclaration(
            decl,
            decl:Modifiers(),
            self:Factory():UpdateImportClause(
                decl.importClause:AsImportClause(),
                phaseModifier,
                visibleDefaultBinding,
                namedBindings
            ),
            self:rewriteModuleSpecifier(decl, decl.moduleSpecifier),
            self:tryGetResolutionModeOverride(decl.attributes)
        )
    end
    -- Named imports (optionally with visible default)
    local bindingList = core.Filter(
        decl.importClause:AsImportClause().namedBindings:Elements(),
        function(b)
            return self.resolver:IsDeclarationVisible(b)
        end
    )
    if core.Len(bindingList) > 0 or visibleDefaultBinding ~= nil then
        local namedImports
        if core.Len(bindingList) > 0 then
            namedImports = self:Factory():UpdateNamedImports(
                decl.importClause:AsImportClause().namedBindings:AsNamedImports(),
                self:Factory():NewNodeList(bindingList)
            )
        end
        return self:Factory():UpdateImportDeclaration(
            decl,
            decl:Modifiers(),
            self:Factory():UpdateImportClause(
                decl.importClause:AsImportClause(),
                phaseModifier,
                visibleDefaultBinding,
                namedImports
            ),
            self:rewriteModuleSpecifier(decl, decl.moduleSpecifier),
            self:tryGetResolutionModeOverride(decl.attributes)
        )
    end
    -- Augmentation of export depends on import
    if self.resolver:IsImportRequiredByAugmentation(decl) then
        if self.state.isolatedDeclarations then
            self.state:addDiagnostic(declarations.createDiagnosticForNode(decl, diagnostics.Declaration_emit_for_this_file_requires_preserving_this_import_for_augmentations_This_is_not_supported_with_isolatedDeclarations))
        end
        return self:Factory():UpdateImportDeclaration(
            decl,
            decl:Modifiers(),
            nil, --[[importClause]]
            self:rewriteModuleSpecifier(decl, decl.moduleSpecifier),
            self:tryGetResolutionModeOverride(decl.attributes)
        )
    end
    -- Nothing visible
    return nil
end

function DeclarationTransformer:transformJSDocTypeExpression(input)
    return self:Visitor().visit(input.type)
end

function DeclarationTransformer:transformJSDocTypeLiteral(input)
    local members = self:Visitor():VisitSlice(input.jsDocPropertyTags)
    local replacement = self:Factory():NewTypeLiteralNode(self:Factory():NewNodeList(members))
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:transformJSDocPropertyTag(input)
    local replacement = self:Factory():NewPropertySignatureDeclaration(
        nil,
        self:Visitor().visit(input.tagName),
        nil,
        self:Visitor().visit(input.typeExpression),
        nil
    )
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:transformJSDocAllType(input)
    local replacement = self:Factory():NewKeywordTypeNode(Kind.AnyKeyword)
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:transformJSDocNullableType(input)
    local replacement = self:Factory():NewUnionTypeNode(self:Factory():NewNodeList({
        self:Visitor().visit(input.type),
        self:Factory():NewLiteralTypeNode(self:Factory():NewKeywordExpression(Kind.NullKeyword)),
    }))
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:transformJSDocNonNullableType(input)
    return self:Visitor().visit(input.type)
end

function DeclarationTransformer:transformJSDocVariadicType(input)
    local replacement = self:Factory():NewArrayTypeNode(self:Visitor().visit(input.type))
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:transformJSDocOptionalType(input)
    local replacement = self:Factory():NewUnionTypeNode(self:Factory():NewNodeList({
        self:Visitor().visit(input.type),
        self:Factory():NewKeywordTypeNode(Kind.UndefinedKeyword),
    }))
    self:EmitContext():SetOriginal(replacement, input)
    return replacement
end

function DeclarationTransformer:getNameExpressionPreferringIdentifier(nameExpr)
    if ast.IsNumericLiteral(nameExpr) then
        -- Numeric property names are string properties in JS; convert to string literal
        nameExpr = self:Factory():NewStringLiteral(nameExpr:Text(), TokenFlags.None)
    end
    if ast.IsStringLiteralLike(nameExpr) and scanner.IsIdentifierText(nameExpr:Text(), LanguageVariant.Standard) then
        local result = self:Factory():NewIdentifier(nameExpr:Text()) -- prefer non-string literal names where possible
        local kwKind = scanner.IdentifierToKeywordKind(result:AsIdentifier())
        -- keep keywords as strings, except `default`, which has special reformulations in the transformer
        if kwKind == Kind.Unknown or kwKind == Kind.DefaultKeyword then
            -- fake this into a parse tree node so the reference resolver resolves the node via `resolveName`
            result.parent = nameExpr.parent
            result.flags = result.flags & ~NodeFlags.Synthesized
            -- intentionally leave Loc unset so the string isn't used as the text source of the identifier
            return result
        end
    end
    return nameExpr
end

function declarations.isNotDeclareModifier(mod)
    return mod.kind ~= Kind.DeclareKeyword
end

function DeclarationTransformer:stripDeclareModifiers(node)
    if node == nil then
        return nil
    end
    local mods = node:Modifiers()
    if mods ~= nil then
        local flags = node:ModifierFlags()
        if flags & ModifierFlags.Ambient ~= 0 then
            local filtered = core.Filter(mods.nodes, declarations.isNotDeclareModifier)
            node:AsMutable():SetModifiers(self:Factory():NewModifierList(filtered))
        end
    end
    return node -- no need to recur into children, only strip at top-level
end

function DeclarationTransformer:visitCJSExportAssignments(expression)
    if expression ~= nil then
        local _, cleanupDiagnosticContext = self:setupDiagnosticContext(expression)
        if ast.GetAssignmentDeclarationKind(expression) == JSDeclarationKind.ModuleExports then
            if self.state.currentSourceFile.commonJSModuleIndicator ~= nil then
                local result = self:transformExportAssignment(expression.parent, expression, expression:AsBinaryExpression().right, true --[[isExportEquals]])
                if result ~= nil then
                    self.cjsExportAssignment = result
                    self.resultHasScopeMarker = true
                    self.resultHasExternalModuleIndicator = true
                end
            end
        end
        local result = self.cjsExportAssignmentVisitor:VisitEachChild(expression) -- recur through the whole tree, looking for module.exports=
        cleanupDiagnosticContext()
        return result
    end
    return nil
end

function DeclarationTransformer:visitNestedExpression(expression)
    if expression ~= nil then
        local _, cleanupDiagnosticContext = self:setupDiagnosticContext(expression)
        local kind = ast.GetAssignmentDeclarationKind(expression)
        if kind == JSDeclarationKind.Property then
            self:transformExpandoAssignment(expression:AsBinaryExpression())
        elseif kind == JSDeclarationKind.ExportsProperty then
            if self.state.currentSourceFile.commonJSModuleIndicator ~= nil then
                local result = self:transformCommonJSExport(expression, self:getNameExpressionPreferringIdentifier(ast.GetElementOrPropertyAccessName(expression:AsBinaryExpression().left)))
                if result ~= nil then
                    self.cjsExportMembers = core.Append(self.cjsExportMembers, result)
                end
            end
        elseif kind == JSDeclarationKind.ObjectDefinePropertyExports then
            if self.state.currentSourceFile.commonJSModuleIndicator ~= nil then
                local result = self:transformCommonJSExport(expression, self:getNameExpressionPreferringIdentifier(expression:Arguments()[2]))
                if result ~= nil then
                    self.cjsExportMembers = core.Append(self.cjsExportMembers, result)
                end
            end
        end
        local result = self.expressionVisitor:VisitEachChild(expression) -- recur through the whole tree, looking for special assignments
        cleanupDiagnosticContext()
        return result
    end
    return nil
end

function DeclarationTransformer:transformExpandoAssignment(node)
    local left = node.left

    local symbol = node.symbol
    if symbol == nil or symbol.flags & SymbolFlags.Assignment == 0 then
        return
    end

    local ns = ast.GetLeftmostAccessExpression(left)
    if ns == nil or ns.kind ~= Kind.Identifier then
        return
    end

    local declaration = self.resolver:GetReferencedValueDeclaration(ns)
    if declaration == nil then
        return
    end

    if self:shouldStripInternal(declaration) then
        return
    end

    if ast.IsVariableDeclaration(declaration) and declaration:Type() ~= nil then
        return
    end

    if ast.IsFunctionDeclaration(declaration) and declaration:FunctionLikeData().fullSignature ~= nil then
        return
    end

    if ast.IsVariableDeclaration(declaration) and not ast.IsFunctionLike(declaration:Initializer()) then
        return -- We're going to add a type, no need to dupe members with a namespace
    end

    local host = declaration:Symbol()
    if host == nil then
        return
    end

    local name = self:Factory():NewIdentifier(ns:Text())
    local property = self:tryGetPropertyName(left)
    if property == "" or not scanner.IsIdentifierText(property, LanguageVariant.Standard) then
        return
    end

    local hostId = self:getExpandoHostId(declaration)

    if ast.IsDeclaration(declaration) and declarations.isDeclarationAndNotVisible(self:EmitContext(), self.resolver, declaration) then
        -- The host isn't visible (yet) - printing the type of a visible declaration may still
        -- late-mark it as visible (e.g. an exported variable whose type prints as `typeof host`),
        -- so defer the assignment to be processed if and when that happens.
        self.deferredExpandoAssignments[hostId] = core.Append(self.deferredExpandoAssignments[hostId], node)
        return
    end

    if ast.IsFunctionDeclaration(declaration) and not declarations.shouldEmitFunctionProperties(declaration:AsFunctionDeclaration()) then
        return
    end

    self:transformExpandoHost(name, declaration)

    local exportName = self:Factory():NewIdentifier(property)
    local localName = self:tryGetNameOfAssignedExpression(node)
    if localName == nil and not self.resolver:IsNameResolvable(self.enclosingDeclaration, property) and not ast.IsNonContextualKeyword(scanner.StringToToken(exportName:Text())) then
        -- use exportName as localName if there won't be any conflicts or keyword issues
        localName = exportName
    end
    if localName == nil or ast.IsNonContextualKeyword(scanner.StringToToken(localName:Text())) then
        -- fallback to a generated name if the localName doesn't exist or is a keyword
        localName = self:Factory():NewGeneratedNameForNode(node)
    end

    local _, cleanupDiagnosticContext = self:setupDiagnosticContext(node)

    if ast.IsIdentifier(node.right) then
        -- alias-like, emit an `export {name}` or `export {name as alias}`
        local result = self:transformBinaryExpressionToExportDeclaration(node, exportName)
        self.expandoMembers[hostId] = core.Append(self.expandoMembers[hostId], result)
        cleanupDiagnosticContext()
        return
    end

    local preexistingExpandoHasExport = core.Some(self.expandoMembers[hostId], ast.IsExportDeclaration)
    local varModifiers

    if preexistingExpandoHasExport then
        varModifiers = self:Factory():NewModifierList(ast.CreateModifiersFromModifierFlags(ModifierFlags.Export, self:newModifierFunc()))
    end

    local synthesizedNamespace = self:Factory():NewModuleDeclaration(nil --[[modifiers]], Kind.NamespaceKeyword, name, self:Factory():NewModuleBlock(self:Factory():NewNodeList({})))
    synthesizedNamespace.parent = self.enclosingDeclaration
    local declarationData = synthesizedNamespace:DeclarationData()
    declarationData.symbol = host
    local containerData = synthesizedNamespace:LocalsContainerData()
    containerData.locals = {}
    containerData.locals[localName:Text()] = symbol

    local oldEnclosing = self.enclosingDeclaration
    self.enclosingDeclaration = synthesizedNamespace

    local statements = {
        self:Factory():NewVariableStatement(
            varModifiers,
            self:Factory():NewVariableDeclarationList(
                self:Factory():NewNodeList({
                    self:Factory():NewVariableDeclaration(localName, nil --[[exclamationToken]], self:ensureType(node, false), nil --[[initializer]]),
                }),
                NodeFlags.None
            )
        ),
    }

    if localName:Text() ~= exportName:Text() then
        local namedExports = self:Factory():NewNamedExports(self:Factory():NewNodeList(
            {
                self:Factory():NewExportSpecifier(false --[[isTypeOnly]], localName, exportName),
            }
        ))
        statements[#statements + 1] = self:Factory():NewExportDeclaration(nil --[[modifiers]], false --[[isTypeOnly]], namedExports, nil --[[moduleSpecifier]], nil --[[attributes]])
    end

    if #statements > 1 and not preexistingExpandoHasExport then
        -- Add an `export` modifier to all existing expando members so they remain exported after the `export {}` is added
        for _, decl in ipairs(self.expandoMembers[hostId] or {}) do
            local modifierFlags = ModifierFlags.Export | ast.GetCombinedModifierFlags(decl)
            decl:AsMutable():SetModifiers(self:Factory():NewModifierList(ast.CreateModifiersFromModifierFlags(modifierFlags, self:newModifierFunc())))
        end
    end
    for _, s in ipairs(statements) do
        self.expandoMembers[hostId] = core.Append(self.expandoMembers[hostId], s)
    end
    self.enclosingDeclaration = oldEnclosing
    cleanupDiagnosticContext()
end

function DeclarationTransformer:getExpandoHostId(declaration)
    local root = core.IfElse(ast.IsVariableDeclaration(declaration), declaration.parent and declaration.parent.parent, declaration)
    local id = ast.GetNodeId(self:EmitContext():MostOriginal(root))
    return id
end

function DeclarationTransformer:transformExpandoHost(name, declaration)
    local root = core.IfElse(ast.IsVariableDeclaration(declaration), declaration.parent and declaration.parent.parent, declaration)
    local id = self:getExpandoHostId(declaration)

    local _, ok = mapGet(self.expandoHosts, id)
    if ok then
        return
    end

    local saveNeedsDeclare = self.needsDeclare
    self.needsDeclare = true

    local modifierFlags = self:ensureModifierFlags(root)
    local defaultExport = modifierFlags & ModifierFlags.Export ~= 0 and modifierFlags & ModifierFlags.Default ~= 0

    self.needsDeclare = saveNeedsDeclare

    if defaultExport then
        modifierFlags = modifierFlags | ModifierFlags.Ambient
        modifierFlags = modifierFlags ~ ModifierFlags.Default
        modifierFlags = modifierFlags ~ ModifierFlags.Export
    end

    local _, cleanupDiagnosticContext = self:setupDiagnosticContext(declaration)

    local modifiers = self:Factory():NewModifierList(ast.CreateModifiersFromModifierFlags(modifierFlags, self:newModifierFunc()))
    local replacement = {}

    if ast.IsFunctionDeclaration(declaration) then
        local typeParameters, parameters, asteriskToken = declarations.extractExpandoHostParams(declaration)
        replacement[#replacement + 1] = self:Factory():UpdateFunctionDeclaration(declaration:AsFunctionDeclaration(), modifiers, asteriskToken, declaration:Name(), self:ensureTypeParams(declaration, typeParameters), self:updateParamList(declaration, parameters), self:ensureType(declaration, false), nil --[[fullSignature]], nil --[[body]])
    elseif ast.IsVariableDeclaration(declaration) and ast.IsFunctionExpressionOrArrowFunction(declaration:Initializer()) then
        local fn = declaration:Initializer()
        local typeParameters, parameters, asteriskToken = declarations.extractExpandoHostParams(fn)
        replacement[#replacement + 1] = self:Factory():NewFunctionDeclaration(modifiers, asteriskToken, self:Factory():NewIdentifier(name:Text()), self:ensureTypeParams(fn, typeParameters), self:updateParamList(fn, parameters), self:ensureType(fn, false), nil --[[fullSignature]], nil --[[body]])
    else
        mapSet(self.expandoHosts, id, self:transformTopLevelDeclaration(declaration))
        cleanupDiagnosticContext()
        return
    end

    self.state.reportExpandoFunctionErrors(declaration)

    if defaultExport then
        if ast.IsSourceFile(declaration.parent) then
            self.resultHasExternalModuleIndicator = true
        end
        self.resultHasScopeMarker = true
        replacement[#replacement + 1] = self:Factory():NewExportAssignment(nil --[[modifiers]], false --[[isExportEquals]], nil --[[typeNode]], name)
    end

    -- store host result to be added to the output when it's actually visited
    mapSet(self.expandoHosts, id, self:Factory():NewSyntaxList(replacement))
    local _, hasLate = mapGet(self.lateStatementReplacementMap, id)
    if hasLate then
        mapSet(self.lateStatementReplacementMap, id, self:createFullExpandoBlock(id))
    end
    cleanupDiagnosticContext()
end

function DeclarationTransformer:createFullExpandoBlock(id)
    -- Process any expando assignments on this host that were skipped because it wasn't
    -- visible when they were collected - if it's still not visible, they simply get
    -- re-deferred, and are dropped if the host is never late-marked visible.
    local deferred = self.deferredExpandoAssignments[id]
    if deferred ~= nil then
        self.deferredExpandoAssignments[id] = nil
        for _, assignment in ipairs(deferred) do
            self:transformExpandoAssignment(assignment)
        end
    end
    local n = mapGet(self.expandoHosts, id)
    local addOns = self.expandoMembers[id]
    if addOns ~= nil then
        local modifiers
        local name
        local host
        if n ~= nil and n.kind == Kind.SyntaxList then
            -- find the first named syntax list element and use its' name & modifiers
            for _, c in ipairs(n:AsSyntaxList().children or {}) do
                if c:Name() ~= nil then
                    name = c:Name():Clone(self:Factory())
                    if c:Modifiers() ~= nil then
                        modifiers = c:Modifiers():Clone(self:Factory():AsNodeFactory())
                    end
                    break
                end
            end
            host = n:AsSyntaxList().children
        elseif n ~= nil then
            name = n:Name():Clone(self:Factory())
            if n:Modifiers() ~= nil then
                modifiers = n:Modifiers():Clone(self:Factory():AsNodeFactory())
            end
            host = { n }
        end
        if name ~= nil then
            local moduleDecl = self:Factory():NewModuleDeclaration(
                modifiers,
                Kind.NamespaceKeyword,
                name,
                self:Factory():NewModuleBlock(self:Factory():NewNodeList(addOns))
            )
            local members = {}
            for _, h in ipairs(host or {}) do
                members[#members + 1] = h
            end
            members[#members + 1] = moduleDecl
            return self:Factory():NewSyntaxList(members)
        end
    end
    return n
end

-- Returns (typeParameters, parameters, asteriskToken).
function declarations.extractExpandoHostParams(node)
    local kind = node.kind
    if kind == Kind.FunctionExpression then
        local fn = node:AsFunctionExpression()
        return fn.typeParameters, fn.parameters, fn.asteriskToken
    elseif kind == Kind.ArrowFunction then
        local fn = node:AsArrowFunction()
        return fn.typeParameters, fn.parameters, fn.asteriskToken
    else
        local fn = node:AsFunctionDeclaration()
        return fn.typeParameters, fn.parameters, fn.asteriskToken
    end
end

function DeclarationTransformer:tryGetPropertyName(node)
    if ast.IsElementAccessExpression(node) then
        return self.resolver:GetElementAccessExpressionName(node:AsElementAccessExpression())
    end
    if ast.IsPropertyAccessExpression(node) then
        return node:Name():Text()
    end
    return ""
end
