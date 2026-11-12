local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local autoimport = require("tslua.ls.autoimport")
local change = require("tslua.ls.change")
local checker = require("tslua.checker")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local TokenFlags = ast.TokenFlags
local FindAncestorResult = ast.FindAncestorResult
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local NBFlags = nodebuilder.Flags
local NBInternalFlags = nodebuilder.InternalFlags
local EF = printer.EmitFlags

local optimisticNameOptions = { flags = printer.GeneratedIdentifierFlagsOptimistic, prefix = "", suffix = "" }

ls.isolatedDeclarationsFixErrorCodes = {
    diagnostics.Function_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.Method_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.At_least_one_accessor_must_have_an_explicit_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.Variable_must_have_an_explicit_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.Parameter_must_have_an_explicit_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.Property_must_have_an_explicit_type_annotation_with_isolatedDeclarations:Code(),
    diagnostics.Expression_type_can_t_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Binding_elements_with_initializers_can_t_be_exported_directly_with_isolatedDeclarations:Code(),
    diagnostics.Computed_property_names_on_class_or_object_literals_cannot_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Computed_properties_must_be_number_or_string_literals_variables_or_dotted_expressions_with_isolatedDeclarations:Code(),
    diagnostics.Enum_member_initializers_must_be_computable_without_references_to_external_symbols_with_isolatedDeclarations:Code(),
    diagnostics.Extends_clause_can_t_contain_an_expression_with_isolatedDeclarations:Code(),
    diagnostics.Objects_that_contain_shorthand_properties_can_t_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Objects_that_contain_spread_assignments_can_t_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Arrays_with_spread_elements_can_t_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Default_exports_can_t_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Only_const_arrays_can_be_inferred_with_isolatedDeclarations:Code(),
    diagnostics.Assigning_properties_to_functions_without_declaring_them_is_not_supported_with_isolatedDeclarations_Add_an_explicit_declaration_for_the_properties_assigned_to_this_function:Code(),
    diagnostics.Declaration_emit_for_this_parameter_requires_implicitly_adding_undefined_to_its_type_This_is_not_supported_with_isolatedDeclarations:Code(),
    diagnostics.Type_containing_private_name_0_can_t_be_used_with_isolatedDeclarations:Code(),
    diagnostics.Add_satisfies_and_a_type_assertion_to_this_expression_satisfies_T_as_T_to_make_the_type_explicit:Code(),
}

ls.fixMissingTypeAnnotationOnExportsFixID = "fixMissingTypeAnnotationOnExports"

-- IsolatedDeclarationsFixProvider is the CodeFixProvider for isolatedDeclarations-related type annotation fixes.
ls.IsolatedDeclarationsFixProvider = {
    errorCodes = ls.isolatedDeclarationsFixErrorCodes,
    getCodeActions = function(ctx, fixContext)
        return ls.getIsolatedDeclarationsCodeActions(ctx, fixContext)
    end,
    fixIds = { ls.fixMissingTypeAnnotationOnExportsFixID },
    getAllCodeActions = function(ctx, fixContext)
        return ls.getAllIsolatedDeclarationsCodeActions(ctx, fixContext)
    end,
}

-- canHaveTypeAnnotationKinds are the node kinds that can have type annotations added.
ls.canHaveTypeAnnotationKinds = {
    [Kind.GetAccessor] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.PropertyDeclaration] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.ArrowFunction] = true,
    [Kind.VariableDeclaration] = true,
    [Kind.Parameter] = true,
    [Kind.ExportAssignment] = true,
    [Kind.ClassDeclaration] = true,
    [Kind.ObjectBindingPattern] = true,
    [Kind.ArrayBindingPattern] = true,
}

-- declarationEmitNodeBuilderFlags are the node builder flags used for declaration emit.
ls.declarationEmitNodeBuilderFlags = NBFlags.MultilineObjectLiterals |
    NBFlags.WriteClassExpressionAsTypeLiteral |
    NBFlags.UseTypeOfFunction |
    NBFlags.UseStructuralFallback |
    NBFlags.AllowEmptyTuple |
    NBFlags.GenerateNamesForShadowedTypeParams |
    NBFlags.NoTruncation

-- type typePrintMode int
ls.typePrintModeFull = 0
ls.typePrintModeRelative = 1 -- typeof X
ls.typePrintModeWidened = 2 -- widened literal type

function ls.getIsolatedDeclarationsCodeActions(ctx, fixContext)
    local ch, done = fixContext.program:GetTypeCheckerForFile(ctx, fixContext.sourceFile)

    local fixes = nil

    local function addFix(action)
        if action == nil then
            return
        end
        fixes = core.Append(fixes, action)
    end

    -- Match TS ordering: Full annotation, Relative annotation, Widened annotation,
    -- Full inline, Relative inline, Widened inline, Full extract
    local modes = { ls.typePrintModeFull, ls.typePrintModeRelative, ls.typePrintModeWidened }

    for _, mode in ipairs(modes) do
        addFix(ls.tryCodeAction(ctx, fixContext, ch, function(f)
            f.typePrintMode = mode
            return f:addTypeAnnotation(fixContext.span)
        end))
    end

    for _, mode in ipairs(modes) do
        addFix(ls.tryCodeAction(ctx, fixContext, ch, function(f)
            f.typePrintMode = mode
            return f:addInlineAssertion(fixContext.span)
        end))
    end

    -- extractAsVariable only in Full mode
    addFix(ls.tryCodeAction(ctx, fixContext, ch, function(f)
        f.typePrintMode = ls.typePrintModeFull
        return f:extractAsVariable(fixContext.span)
    end))

    done()
    return fixes, nil
end

function ls.getAllIsolatedDeclarationsCodeActions(ctx, fixContext)
    local ch, done = fixContext.program:GetTypeCheckerForFile(ctx, fixContext.sourceFile)

    local changeTracker = change.NewTracker(ctx, fixContext.program:Options(), fixContext.ls:FormatOptions(), fixContext.ls.converters)

    local fixer = ls.newIsolatedDeclarationsFixer({
        sourceFile = fixContext.sourceFile,
        program = fixContext.program,
        checker = ch,
        changeTracker = changeTracker,
        locale = locale.FromContext(ctx),
        typePrintMode = ls.typePrintModeFull,
    })

    local allDiags = ls.getAllDiagnostics(ctx, fixContext.program, fixContext.sourceFile)
    for _, diag in ipairs(allDiags or {}) do
        if ls.isFixableDiagnostic(diag, ls.isolatedDeclarationsFixErrorCodes) then
            local span = core.NewTextRange(diag:Loc():Pos(), diag:Loc():End())
            fixer:addTypeAnnotation(span)
        end
    end

    for _, sym in ipairs(fixer.symbolsToImport or {}) do
        fixer:addSymbolToExistingImport(sym)
    end

    local changes = changeTracker:GetChanges()
    local fileChanges = changes[fixContext.sourceFile:OriginalFileName()]
    if core.Len(fileChanges) == 0 then
        done()
        return nil, nil
    end

    done()
    return {
        description = diagnostics.Add_all_missing_type_annotations:Localize(locale.FromContext(ctx)),
        changes = fileChanges,
    }, nil
end

function ls.tryCodeAction(ctx, fixContext, ch, fn)
    local changeTracker = change.NewTracker(ctx, fixContext.program:Options(), fixContext.ls:FormatOptions(), fixContext.ls.converters)

    local importAdder = nil
    -- importAdder may be nil if the auto-import registry is not available;
    -- type node transformation still works without it, just without adding imports.

    local fixer = ls.newIsolatedDeclarationsFixer({
        sourceFile = fixContext.sourceFile,
        program = fixContext.program,
        checker = ch,
        changeTracker = changeTracker,
        importAdder = importAdder,
        locale = locale.FromContext(ctx),
    })

    local description = fn(fixer)
    if description == "" then
        return nil
    end

    -- Add any symbols that need to be imported to existing import declarations
    for _, sym in ipairs(fixer.symbolsToImport or {}) do
        fixer:addSymbolToExistingImport(sym)
    end

    local changes = changeTracker:GetChanges()
    local fileChanges = changes[fixContext.sourceFile:OriginalFileName()]

    -- Add import edits if import adder has fixes
    if importAdder ~= nil and importAdder:HasFixes() then
        fileChanges = core.AppendAll(fileChanges, importAdder:Edits())
    end

    if core.Len(fileChanges) == 0 then
        return nil
    end

    return ls.NewCodeAction({
        description = description,
        changes = fileChanges,
        fixID = ls.fixMissingTypeAnnotationOnExportsFixID,
        fixAllDescription = diagnostics.Add_all_missing_type_annotations:Localize(locale.FromContext(ctx)),
    })
end

-- isolatedDeclarationsFixer encapsulates the state for fixing isolated declarations errors.
local isolatedDeclarationsFixer = {}
isolatedDeclarationsFixer.__index = isolatedDeclarationsFixer
ls.isolatedDeclarationsFixer = isolatedDeclarationsFixer

-- Go &isolatedDeclarationsFixer{...}: fields { sourceFile, program, checker, changeTracker, importAdder,
-- locale, fixedNodes, typePrintMode, symbolsToImport, mutatedTarget }.
function ls.newIsolatedDeclarationsFixer(fields)
    return setmetatable({
        sourceFile = fields.sourceFile,
        program = fields.program,
        checker = fields.checker,
        changeTracker = fields.changeTracker,
        importAdder = fields.importAdder,
        locale = fields.locale,
        fixedNodes = {},
        typePrintMode = fields.typePrintMode or ls.typePrintModeFull,
        symbolsToImport = nil,
        mutatedTarget = false, -- set by inferType/relativeType when the target was mutated (e.g., spread decomposition)
    }, isolatedDeclarationsFixer)
end

function isolatedDeclarationsFixer:addTypeAnnotation(span)
    local nodeWithDiag = astnav.GetTokenAtPosition(self.sourceFile, span:Pos())

    local expandoFunction = ls.findExpandoFunction(self.checker, nodeWithDiag)
    if expandoFunction ~= nil then
        if ast.IsFunctionDeclaration(expandoFunction) then
            return self:createNamespaceForExpandoProperties(expandoFunction)
        end
        return self:fixIsolatedDeclarationError(expandoFunction)
    end

    local nodeMissingType = ls.findAncestorWithMissingType(nodeWithDiag)
    if nodeMissingType ~= nil then
        return self:fixIsolatedDeclarationError(nodeMissingType)
    end
    return ""
end

function isolatedDeclarationsFixer:createNamespaceForExpandoProperties(expandoFunc)
    local funcDecl = expandoFunc:AsFunctionDeclaration()
    if funcDecl:Name() == nil then
        return ""
    end

    local t = self.checker:GetTypeAtLocation(expandoFunc)
    local elements = self.checker:GetPropertiesOfType(t)
    if core.Len(elements) == 0 then
        return ""
    end

    local factory = self.changeTracker.nodeFactory

    local newProperties = nil
    for _, symbol in ipairs(elements) do
        if not scanner.IsIdentifierText(symbol.name, core.LanguageVariant.Standard) then
            goto continue
        end
        -- skip symbols that already have a variable declaration
        if symbol.valueDeclaration ~= nil and ast.IsVariableDeclaration(symbol.valueDeclaration) then
            goto continue
        end

        do
            local symType = self.checker:GetTypeOfSymbol(symbol)
            local typeNode = self:typeToMinimizedReferenceType(symType, expandoFunc, ls.declarationEmitNodeBuilderFlags)
            if typeNode == nil then
                goto continue
            end

            local varDecl = factory:NewVariableDeclaration(factory:NewIdentifier(symbol.name), nil, typeNode, nil)
            local exportToken = factory:NewToken(Kind.ExportKeyword)
            local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.None)
            local varStmt = factory:NewVariableStatement(factory:NewModifierList({ exportToken }), varDeclList)
            newProperties = core.Append(newProperties, varStmt)
        end

        ::continue::
    end

    if core.Len(newProperties) == 0 then
        return ""
    end

    local modifiers = {}
    if ast.HasSyntacticModifier(expandoFunc, ModifierFlags.Export) then
        modifiers[#modifiers + 1] = factory:NewToken(Kind.ExportKeyword)
    end
    modifiers[#modifiers + 1] = factory:NewToken(Kind.DeclareKeyword)

    local namespace = factory:NewModuleDeclaration(
        factory:NewModifierList(modifiers),
        Kind.NamespaceKeyword,
        factory:NewIdentifier(funcDecl:Name():Text()),
        factory:NewModuleBlock(factory:NewNodeList(newProperties))
    )
    -- Set the flags for namespace
    namespace.flags = NodeFlags.Ambient | NodeFlags.ExportContext | NodeFlags.ContextFlags

    self.changeTracker:InsertNodeAfter(self.sourceFile, expandoFunc, namespace)
    return diagnostics.Annotate_types_of_properties_expando_function_in_a_namespace:Localize(self.locale)
end

-- needsParenthesizedExpressionForAssertion checks if an expression needs parentheses for an assertion.
function ls.needsParenthesizedExpressionForAssertion(node)
    return not ast.IsEntityNameExpression(node) and not ast.IsCallExpression(node) and not ast.IsObjectLiteralExpression(node) and not ast.IsArrayLiteralExpression(node)
end

-- createAsExpression creates an `expr as Type` expression, parenthesizing if needed.
function ls.createAsExpression(factory, node, typeNode)
    if ls.needsParenthesizedExpressionForAssertion(node) then
        node = factory:NewParenthesizedExpression(node)
    end
    return factory:NewAsExpression(node, typeNode)
end

function isolatedDeclarationsFixer:addInlineAssertion(span)
    local nodeWithDiag = astnav.GetTokenAtPosition(self.sourceFile, span:Pos())

    -- No inline assertions for expando members
    local expandoFunction = ls.findExpandoFunction(self.checker, nodeWithDiag)
    if expandoFunction ~= nil then
        return ""
    end

    local targetNode = ls.findBestFittingNode(nodeWithDiag, span)
    if targetNode == nil or ls.isValueSignatureDeclaration(targetNode) or ls.isValueSignatureDeclaration(targetNode.parent) then
        return ""
    end

    local isExpressionTarget = ast.IsExpression(targetNode)
    local isShorthandPropertyAssignmentTarget = ast.IsShorthandPropertyAssignment(targetNode)

    -- Go's IsDeclaration is broader than TS's isDeclaration (e.g. CallExpression has DeclarationData
    -- in Go but is not a declaration kind in TS). Use isNamedDeclarationKind to match TS behavior.
    if not isShorthandPropertyAssignmentTarget and ls.isNamedDeclarationKind(targetNode) then
        return ""
    end
    -- No inline assertions on binding patterns
    if ast.FindAncestor(targetNode, ast.IsBindingPattern) ~= nil then
        return ""
    end
    -- No inline assertions on enum members
    if ast.FindAncestor(targetNode, ast.IsEnumMember) ~= nil then
        return ""
    end
    -- No support for typeof in extends clauses
    if isExpressionTarget and (ast.FindAncestorKind(targetNode, Kind.HeritageClause) ~= nil or ast.FindAncestor(targetNode, ast.IsTypeNode) ~= nil) then
        return ""
    end
    -- Can't inline type spread elements
    if ast.IsSpreadElement(targetNode) then
        return ""
    end

    local variableDeclaration = ast.FindAncestorKind(targetNode, Kind.VariableDeclaration)
    local variableType = nil
    if variableDeclaration ~= nil then
        variableType = self.checker:GetTypeAtLocation(variableDeclaration)
    end
    -- Can't use typeof on unique symbols
    if variableType ~= nil and variableType:Flags() & TypeFlags.UniqueESSymbol ~= 0 then
        return ""
    end

    if not isExpressionTarget and not isShorthandPropertyAssignmentTarget then
        return ""
    end

    local typeNode = self:inferType(targetNode, variableType)
    if typeNode == nil or self.mutatedTarget then
        return ""
    end

    local factory = self.changeTracker.nodeFactory

    if isShorthandPropertyAssignmentTarget then
        -- Insert `: expr as Type` after the shorthand property name
        local clonedName = factory:DeepCloneNode(targetNode:AsShorthandPropertyAssignment():Name())
        local asExpr = ls.createAsExpression(factory, clonedName, typeNode)
        self.changeTracker:InsertNodeAt(self.sourceFile, targetNode:End(), asExpr, change.NodeOptions_new({ prefix = ": " }))
    elseif isExpressionTarget then
        -- Replace expression with `(expression) satisfies Type as Type` or `expression satisfies Type as Type`
        local clonedTarget = factory:DeepCloneNode(targetNode)
        if ls.needsParenthesizedExpressionForAssertion(targetNode) then
            clonedTarget = factory:NewParenthesizedExpression(clonedTarget)
        end
        local clonedType = factory:DeepCloneNode(typeNode)
        local satisfiesAsExpr = factory:NewAsExpression(
            factory:NewSatisfiesExpression(clonedTarget, clonedType),
            typeNode
        )
        self.changeTracker:ReplaceNode(self.sourceFile, targetNode, satisfiesAsExpr, nil)
    else
        return ""
    end

    return diagnostics.Add_satisfies_and_an_inline_type_assertion_with_0:Localize(self.locale, ls.typeToStringForDiag(typeNode, self.sourceFile, self.changeTracker))
end

function isolatedDeclarationsFixer:extractAsVariable(span)
    local nodeWithDiag = astnav.GetTokenAtPosition(self.sourceFile, span:Pos())
    local targetNode = ls.findBestFittingNode(nodeWithDiag, span)
    if targetNode == nil or ls.isValueSignatureDeclaration(targetNode) or ls.isValueSignatureDeclaration(targetNode.parent) then
        return ""
    end

    if not ast.IsExpression(targetNode) then
        return ""
    end

    local factory = self.changeTracker.nodeFactory

    -- Array literals should be marked as const
    if ast.IsArrayLiteralExpression(targetNode) then
        local constRef = factory:NewTypeReferenceNode(factory:NewIdentifier("const"), nil)
        local cloned = factory:DeepCloneNode(targetNode)
        self.changeTracker:ReplaceNode(self.sourceFile, targetNode, ls.createAsExpression(factory, cloned, constRef), nil)
        return diagnostics.Mark_array_literal_as_const:Localize(self.locale)
    end

    local parentPropertyAssignment = ast.FindAncestorKind(targetNode, Kind.PropertyAssignment)
    if parentPropertyAssignment ~= nil then
        -- Identifiers or entity names can already be typeof-ed
        if parentPropertyAssignment == targetNode.parent and ast.IsEntityNameExpression(targetNode) then
            return ""
        end

        local tempName = self.changeTracker.emitContext.factory:NewUniqueNameEx(ls.getIdentifierNameForNode(targetNode), optimisticNameOptions)

        local replacementTarget = targetNode
        local initializationNode = targetNode

        -- Handle spread elements: walk up to the spread's parent and handle const assertions
        if ast.IsSpreadElement(replacementTarget) then
            replacementTarget = ast.WalkUpParenthesizedExpressions(replacementTarget.parent)
            if ls.isConstAssertion(replacementTarget.parent) then
                replacementTarget = replacementTarget.parent
                initializationNode = replacementTarget
            else
                local constRef = factory:NewTypeReferenceNode(factory:NewIdentifier("const"), nil)
                initializationNode = ls.createAsExpression(factory, factory:DeepCloneNode(replacementTarget), constRef)
            end
        end

        if ast.IsEntityNameExpression(replacementTarget) then
            return ""
        end

        local clonedInit = factory:DeepCloneNode(initializationNode)
        local varDecl = factory:NewVariableDeclaration(tempName, nil, nil, clonedInit)
        local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
        local varStmt = factory:NewVariableStatement(nil, varDeclList)

        local statement = ast.FindAncestor(targetNode, ast.IsStatement)
        if statement == nil then
            return ""
        end
        self.changeTracker:InsertNodeBefore(self.sourceFile, statement, varStmt, false, change.LeadingTriviaOption.None)

        local typeQuery = factory:NewTypeQueryNode(tempName, nil)
        local asExpr = factory:NewAsExpression(tempName, typeQuery)
        self.changeTracker:ReplaceNode(self.sourceFile, replacementTarget, asExpr, nil)

        local idText = ls.typeToStringForDiag(tempName, self.sourceFile, self.changeTracker)
        return diagnostics.Extract_to_variable_and_replace_with_0_as_typeof_0:Localize(self.locale, idText)
    end

    return ""
end

-- findExpandoFunction finds the function declaration that has expando properties assigned to it.
-- isExpandoPropertyDeclarationForFix matches TS's isExpandoPropertyDeclaration which includes
-- PropertyAccessExpression, ElementAccessExpression, and BinaryExpression. The shared
-- ast.IsExpandoPropertyDeclaration was narrowed to BinaryExpression only for checker purposes.
function ls.isExpandoPropertyDeclarationForFix(node)
    return node ~= nil and (ast.IsPropertyAccessExpression(node) or ast.IsElementAccessExpression(node) or ast.IsBinaryExpression(node))
end

function ls.findExpandoFunction(ch, node)
    local expandoDeclaration = ast.FindAncestorOrQuit(node, function(n)
        if ast.IsStatement(n) then
            return FindAncestorResult.FindAncestorQuit
        end
        if ls.isExpandoPropertyDeclarationForFix(n) then
            return FindAncestorResult.FindAncestorTrue
        end
        return FindAncestorResult.FindAncestorFalse
    end)

    if expandoDeclaration == nil or not ls.isExpandoPropertyDeclarationForFix(expandoDeclaration) then
        return nil
    end

    local assignmentTarget = expandoDeclaration
    -- Some late bound expando members use the whole expression as the declaration.
    if ast.IsBinaryExpression(assignmentTarget) then
        assignmentTarget = assignmentTarget:AsBinaryExpression().left
        if not ls.isExpandoPropertyDeclarationForFix(assignmentTarget) then
            return nil
        end
    end

    local expression
    if ast.IsPropertyAccessExpression(assignmentTarget) then
        expression = assignmentTarget:AsPropertyAccessExpression().expression
    elseif ast.IsElementAccessExpression(assignmentTarget) then
        expression = assignmentTarget:AsElementAccessExpression().expression
    else
        return nil
    end

    local targetType = ch:GetTypeAtLocation(expression)
    if targetType == nil then
        return nil
    end

    local properties = ch:GetPropertiesOfType(targetType)
    local found = false
    for _, p in ipairs(properties or {}) do
        if p.valueDeclaration == expandoDeclaration or p.valueDeclaration == expandoDeclaration.parent then
            found = true
            break
        end
    end
    if not found then
        return nil
    end

    local symbol = targetType:Symbol()
    if symbol == nil or symbol.valueDeclaration == nil then
        return nil
    end

    local fn = symbol.valueDeclaration
    if (ast.IsFunctionExpression(fn) or ast.IsArrowFunction(fn)) and ast.IsVariableDeclaration(fn.parent) then
        return fn.parent
    end
    if ast.IsFunctionDeclaration(fn) then
        return fn
    end

    return nil
end

function isolatedDeclarationsFixer:fixIsolatedDeclarationError(node)
    -- Avoid creating duplicate fixes for the same node
    if self.fixedNodes[node] then
        return ""
    end
    self.fixedNodes[node] = true

    local kind = node.kind
    if kind == Kind.Parameter or kind == Kind.PropertyDeclaration or kind == Kind.VariableDeclaration then
        return self:addTypeToVariableLike(node)
    elseif kind == Kind.ArrowFunction or kind == Kind.FunctionExpression or kind == Kind.FunctionDeclaration or
        kind == Kind.MethodDeclaration or kind == Kind.GetAccessor then
        return self:addTypeToSignatureDeclaration(node)
    elseif kind == Kind.ExportAssignment then
        return self:transformExportAssignment(node)
    elseif kind == Kind.ClassDeclaration then
        return self:transformExtendsClauseWithExpression(node)
    elseif kind == Kind.ObjectBindingPattern or kind == Kind.ArrayBindingPattern then
        return self:transformDestructuringPatterns(node)
    else
        return ""
    end
end

function isolatedDeclarationsFixer:addTypeToSignatureDeclaration(funcNode)
    if funcNode:Type() ~= nil then
        return ""
    end
    local typeNode = self:inferType(funcNode, nil)
    if typeNode == nil then
        return ""
    end
    self.changeTracker:TryInsertTypeAnnotation(self.sourceFile, funcNode, typeNode)
    return diagnostics.Add_return_type_0:Localize(self.locale, ls.typeToStringForDiag(typeNode, self.sourceFile, self.changeTracker))
end

function isolatedDeclarationsFixer:transformExportAssignment(defaultExport)
    local exportAssignment = defaultExport:AsExportAssignment()
    if exportAssignment.isExportEquals then
        return ""
    end

    local expression = exportAssignment.expression
    local typeNode = self:inferType(expression, nil)
    if typeNode == nil then
        return ""
    end

    local factory = self.changeTracker.nodeFactory

    local defaultIdentifier = self.changeTracker.emitContext.factory:NewUniqueName("_default")

    -- Deep clone the expression so synthesized nodes don't reference original source positions
    local clonedExpression = factory:DeepCloneNode(expression)

    local varDecl = factory:NewVariableDeclaration(defaultIdentifier, nil, typeNode, clonedExpression)
    local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
    local varStmt = factory:NewVariableStatement(nil, varDeclList)

    local newExport = factory:UpdateExportAssignment(defaultExport:AsExportAssignment(), defaultExport:Modifiers(), false, nil, defaultIdentifier)

    self.changeTracker:ReplaceNodeWithNodes(self.sourceFile, defaultExport, { varStmt, newExport }, nil)
    return diagnostics.Extract_default_export_to_variable:Localize(self.locale)
end

function isolatedDeclarationsFixer:transformExtendsClauseWithExpression(classDecl)
    local cd = classDecl:AsClassDeclaration()
    local extendsClause = nil
    if cd.heritageClauses ~= nil then
        for _, clause in ipairs(cd.heritageClauses.nodes or {}) do
            if clause:AsHeritageClause().token == Kind.ExtendsKeyword then
                extendsClause = clause
                break
            end
        end
    end
    if extendsClause == nil then
        return ""
    end

    local heritageTypes = extendsClause:AsHeritageClause().types
    if heritageTypes == nil or core.Len(heritageTypes.nodes) == 0 then
        return ""
    end
    local heritageExpression = heritageTypes.nodes[1]
    local expression = heritageExpression:AsExpressionWithTypeArguments().expression

    local heritageTypeNode = self:inferType(expression, nil)
    if heritageTypeNode == nil then
        return ""
    end

    local factory = self.changeTracker.nodeFactory

    local baseName = "Anonymous"
    if cd:Name() ~= nil then
        baseName = cd:Name():Text() .. "Base"
    end
    local baseClassName = self.changeTracker.emitContext.factory:NewUniqueNameEx(baseName, optimisticNameOptions)

    -- Create: const <BaseName>: <type> = <expression>;
    local clonedExpression = factory:DeepCloneNode(expression)
    local varDecl = factory:NewVariableDeclaration(baseClassName, nil, heritageTypeNode, clonedExpression)
    local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
    local varStmt = factory:NewVariableStatement(nil, varDeclList)

    self.changeTracker:InsertNodeBefore(self.sourceFile, classDecl, varStmt, false, change.LeadingTriviaOption.None)

    -- Replace the heritage expression with the base class name
    self.changeTracker:ReplaceNode(self.sourceFile, heritageExpression, factory:NewExpressionWithTypeArguments(baseClassName, nil), nil)

    return diagnostics.Extract_base_class_to_variable:Localize(self.locale)
end

function isolatedDeclarationsFixer:transformDestructuringPatterns(bindingPattern)
    local enclosingVariableDeclaration = bindingPattern.parent
    if not ast.IsVariableDeclaration(enclosingVariableDeclaration) then
        return ""
    end
    local enclosingVarStmt = enclosingVariableDeclaration.parent.parent
    if not ast.IsVariableStatement(enclosingVarStmt) then
        return ""
    end

    local initializer = enclosingVariableDeclaration:Initializer()
    if initializer == nil then
        return ""
    end

    local factory = self.changeTracker.nodeFactory
    local newNodes = {}

    local baseExprNode
    if not ast.IsIdentifier(initializer) then
        -- Create a temporary variable for complex expressions
        local tempName = self.changeTracker.emitContext.factory:NewUniqueNameEx("dest", optimisticNameOptions)
        local clonedInitializer = factory:DeepCloneNode(initializer)
        local varDecl = factory:NewVariableDeclaration(tempName, nil, nil, clonedInitializer)
        local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
        local varStmt = factory:NewVariableStatement(nil, varDeclList)
        newNodes[#newNodes + 1] = varStmt
        baseExprNode = tempName
    else
        -- Use a new identifier to avoid referencing original source positions
        baseExprNode = factory:NewIdentifier(initializer:Text())
    end

    -- Extract each binding element as a separate variable with type annotation
    self:extractBindingElements(bindingPattern, baseExprNode, newNodes, enclosingVarStmt)

    if #newNodes == 0 then
        return ""
    end

    -- If the enclosing variable statement has multiple declarations, preserve the non-destructuring ones
    local declList = enclosingVarStmt:AsVariableStatement().declarationList:AsVariableDeclarationList()
    if core.Len(declList.declarations.nodes) > 1 then
        local remainingDecls = nil
        for _, d in ipairs(declList.declarations.nodes) do
            if d ~= enclosingVariableDeclaration then
                remainingDecls = core.Append(remainingDecls, d)
            end
        end
        if core.Len(remainingDecls) > 0 then
            newNodes[#newNodes + 1] = factory:UpdateVariableStatement(
                enclosingVarStmt:AsVariableStatement(),
                enclosingVarStmt:AsVariableStatement():Modifiers(),
                factory:UpdateVariableDeclarationList(
                    declList,
                    factory:NewNodeList(remainingDecls),
                    declList.flags
                )
            )
        end
    end

    self.changeTracker:ReplaceNodeWithNodes(self.sourceFile, enclosingVarStmt, newNodes, nil)
    return diagnostics.Extract_binding_expressions_to_variable:Localize(self.locale)
end

-- newNodes is the Go *[]*ast.Node: a Lua array appended to in place.
function isolatedDeclarationsFixer:extractBindingElements(bindingPattern, baseExpr, newNodes, enclosingVarStmt)
    local factory = self.changeTracker.nodeFactory

    if ast.IsObjectBindingPattern(bindingPattern) then
        for _, element in ipairs(bindingPattern:AsBindingPattern().elements.nodes or {}) do
            if ast.IsOmittedExpression(element) then
                goto continue
            end
            do
                local be = element:AsBindingElement()
                local name = be:Name()
                if name == nil then
                    goto continue
                end

                -- Build property access expression
                local accessExpr
                if be.propertyName ~= nil and ast.IsComputedPropertyName(be.propertyName) then
                    -- Handle computed property names: create a temp variable for the computed expression
                    local computedExpression = be.propertyName:AsComputedPropertyName().expression
                    local identifierForComputedProperty = self.changeTracker.emitContext.factory:NewGeneratedNameForNode(computedExpression)
                    local compVarDecl = factory:NewVariableDeclaration(identifierForComputedProperty, nil, nil, computedExpression)
                    local compVarDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ compVarDecl }), NodeFlags.Const)
                    local compVarStmt = factory:NewVariableStatement(nil, compVarDeclList)
                    newNodes[#newNodes + 1] = compVarStmt
                    accessExpr = factory:NewElementAccessExpression(baseExpr, nil, identifierForComputedProperty, NodeFlags.None)
                elseif be.propertyName ~= nil then
                    -- Use property name text (handles identifiers, string literals, numeric literals)
                    local propText = be.propertyName:Text()
                    accessExpr = factory:NewPropertyAccessExpression(baseExpr, nil, factory:NewIdentifier(propText), NodeFlags.None)
                elseif ast.IsIdentifier(name) then
                    accessExpr = factory:NewPropertyAccessExpression(baseExpr, nil, factory:NewIdentifier(name:Text()), NodeFlags.None)
                else
                    goto continue
                end

                if ast.IsBindingPattern(name) then
                    self:extractBindingElements(name, accessExpr, newNodes, enclosingVarStmt)
                else
                    self:emitBindingElementVariable(factory, name, be, accessExpr, newNodes, enclosingVarStmt)
                end
            end
            ::continue::
        end
    elseif ast.IsArrayBindingPattern(bindingPattern) then
        for i1, element in ipairs(bindingPattern:AsBindingPattern().elements.nodes or {}) do
            local i = i1 - 1
            if ast.IsOmittedExpression(element) then
                goto continue
            end
            do
                local be = element:AsBindingElement()
                local name = be:Name()
                if name == nil then
                    goto continue
                end

                local accessExpr = factory:NewElementAccessExpression(baseExpr, nil, factory:NewNumericLiteral(tostring(i), TokenFlags.None), NodeFlags.None)

                if ast.IsBindingPattern(name) then
                    self:extractBindingElements(name, accessExpr, newNodes, enclosingVarStmt)
                else
                    self:emitBindingElementVariable(factory, name, be, accessExpr, newNodes, enclosingVarStmt)
                end
            end
            ::continue::
        end
    end
end

-- emitBindingElementVariable creates a variable declaration for a single binding element,
-- handling default initializers by creating a ternary `temp === undefined ? default : temp`.
function isolatedDeclarationsFixer:emitBindingElementVariable(factory, name, be, accessExpr, newNodes, enclosingVarStmt)
    local typeNode = self:inferType(name, nil)
    local variableInitializer = accessExpr

    if be.initializer ~= nil then
        -- Create a temp variable to hold the accessed value, then use a conditional expression
        -- to apply the default: temp === undefined ? defaultValue : temp
        local propName = be.propertyName
        local tempBaseName = "temp"
        if propName ~= nil and ast.IsIdentifier(propName) then
            tempBaseName = propName:Text()
        end
        local tempName = self.changeTracker.emitContext.factory:NewUniqueNameEx(tempBaseName, optimisticNameOptions)
        local tempVarDecl = factory:NewVariableDeclaration(tempName, nil, nil, variableInitializer)
        local tempVarDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ tempVarDecl }), NodeFlags.Const)
        local tempVarStmt = factory:NewVariableStatement(nil, tempVarDeclList)
        newNodes[#newNodes + 1] = tempVarStmt

        variableInitializer = factory:NewConditionalExpression(
            factory:NewBinaryExpression(
                nil,
                tempName,
                nil,
                factory:NewToken(Kind.EqualsEqualsEqualsToken),
                factory:NewIdentifier("undefined")
            ),
            factory:NewToken(Kind.QuestionToken),
            be.initializer,
            factory:NewToken(Kind.ColonToken),
            variableInitializer
        )
    end

    local exportModifier = self:getExportModifier(enclosingVarStmt)
    local varDecl = factory:NewVariableDeclaration(factory:NewIdentifier(name:Text()), nil, typeNode, variableInitializer)
    local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
    local varStmt = factory:NewVariableStatement(exportModifier, varDeclList)
    newNodes[#newNodes + 1] = varStmt
end

function isolatedDeclarationsFixer:getExportModifier(enclosingVarStmt)
    if ast.HasSyntacticModifier(enclosingVarStmt, ModifierFlags.Export) then
        local exportToken = self.changeTracker.nodeFactory:NewToken(Kind.ExportKeyword)
        return self.changeTracker.nodeFactory:NewModifierList({ exportToken })
    end
    return nil
end

function isolatedDeclarationsFixer:inferType(node, variableType)
    self.mutatedTarget = false

    -- Handle Relative mode first: return typeof X for identifiers
    if self.typePrintMode == ls.typePrintModeRelative then
        return self:relativeType(node)
    end

    local t = nil

    if ls.isValueSignatureDeclaration(node) then
        local signature = self.checker:GetSignatureFromDeclaration(node)
        if signature ~= nil then
            local typePredicate = self.checker:GetTypePredicateOfSignature(signature)
            if typePredicate ~= nil then
                if typePredicate:Type() == nil then
                    return nil
                end
                local enclosingDecl = ast.FindAncestor(node, ast.IsDeclaration)
                if enclosingDecl == nil then
                    enclosingDecl = self.sourceFile
                end
                local flags = ls.declarationEmitNodeBuilderFlags
                if typePredicate:Type():Flags() & TypeFlags.UniqueESSymbol ~= 0 then
                    flags = flags | NBFlags.AllowUniqueESSymbolType
                end
                local result = self.checker:TypePredicateToTypePredicateNode(typePredicate, enclosingDecl, flags, nil)
                if result ~= nil then
                    return result
                end
                return nil
            end
            t = self.checker:GetReturnTypeOfSignature(signature)
        end
    else
        t = self.checker:GetTypeAtLocation(node)
    end

    if t == nil then
        return nil
    end

    -- Handle Widened mode: return widened literal type if different
    if self.typePrintMode == ls.typePrintModeWidened then
        if variableType ~= nil then
            t = variableType
        end
        local widenedType = self.checker:GetWidenedLiteralType(t)
        if self.checker:IsTypeAssignableTo(widenedType, t) then
            return nil -- widened type is same, no fix needed
        end
        t = widenedType
    end

    local enclosingDecl = ast.FindAncestor(node, ast.IsDeclaration)
    if enclosingDecl == nil then
        enclosingDecl = self.sourceFile
    end

    local flags = ls.declarationEmitNodeBuilderFlags | self:getExtraFlags(node, t)

    -- For parameters that require adding implicit undefined, add it to the type
    if ast.IsParameterDeclaration(node) and self.checker:RequiresAddingImplicitUndefined(node) then
        t = self.checker:GetUnionTypeEx({ self.checker:GetUndefinedType(), t }, checker.UnionReduction.None)
    end

    local typeNode = self:typeToMinimizedReferenceType(t, enclosingDecl, flags)
    return typeNode
end

function isolatedDeclarationsFixer:getExtraFlags(node, t)
    if (ast.IsVariableDeclaration(node) or
            (ast.IsPropertyDeclaration(node) and ast.HasSyntacticModifier(node, ModifierFlags.Static | ModifierFlags.Readonly))) and
        t:Flags() & TypeFlags.UniqueESSymbol ~= 0 then
        return NBFlags.AllowUniqueESSymbolType
    end
    return NBFlags.None
end

-- createTypeOfFromEntityNameExpression creates a `typeof X` type query node.
function isolatedDeclarationsFixer:createTypeOfFromEntityNameExpression(node)
    return self.changeTracker.nodeFactory:NewTypeQueryNode(
        self.changeTracker.nodeFactory:DeepCloneNode(node), nil
    )
end

-- typeFromArraySpreadElements decomposes an array literal with spread elements into
-- separate variables, returning a tuple type of typeof references.
function isolatedDeclarationsFixer:typeFromArraySpreadElements(node, name)
    local isInConstContext = ast.FindAncestor(node, ls.isConstAssertion) ~= nil
    if not isInConstContext then
        return nil
    end
    if name == "" then
        name = "temp"
    end
    local factory = self.changeTracker.nodeFactory
    return self:typeFromSpreads(
        node,
        name,
        isInConstContext,
        function(n)
            return n:AsArrayLiteralExpression().elements.nodes
        end,
        ast.IsSpreadElement,
        function(expr)
            return factory:NewSpreadElement(expr)
        end,
        function(elements)
            return factory:NewArrayLiteralExpression(factory:NewNodeList(elements), true)
        end,
        function(types)
            local restTypes = {}
            for i, t in ipairs(types or {}) do
                restTypes[i] = factory:NewRestTypeNode(t)
            end
            return factory:NewTupleTypeNode(factory:NewNodeList(restTypes))
        end
    )
end

-- typeFromObjectSpreadAssignment decomposes an object literal with spread assignments into
-- separate variables, returning an intersection type of typeof references.
function isolatedDeclarationsFixer:typeFromObjectSpreadAssignment(node, name)
    local isInConstContext = ast.FindAncestor(node, ls.isConstAssertion) ~= nil
    if name == "" then
        name = "temp"
    end
    local factory = self.changeTracker.nodeFactory
    return self:typeFromSpreads(
        node,
        name,
        isInConstContext,
        function(n)
            if n:AsObjectLiteralExpression().properties ~= nil then
                return n:AsObjectLiteralExpression().properties.nodes
            end
            return nil
        end,
        ast.IsSpreadAssignment,
        function(expr)
            return factory:NewSpreadAssignment(expr)
        end,
        function(elements)
            return factory:NewObjectLiteralExpression(factory:NewNodeList(elements), true)
        end,
        function(types)
            return factory:NewIntersectionTypeNode(factory:NewNodeList(types))
        end
    )
end

-- typeFromSpreads is the generic spread decomposition function, ported from TS's typeFromSpreads.
-- It splits a literal with spread elements into separate const variables and returns a composed type.
-- The Go pointer-to-slice arguments of the helpers are boxes { v = slice }.
function isolatedDeclarationsFixer:typeFromSpreads(node, name, isInConstContext, getChildren, isSpread, createSpread, makeNodeOfKind, finalType)
    local factory = self.changeTracker.nodeFactory
    local intersectionTypes = { v = nil }
    local newSpreads = { v = nil }
    local currentVariableProperties = { v = nil }

    local statement = ast.FindAncestor(node, ast.IsStatement)

    local children = getChildren(node)
    for _, prop in ipairs(children or {}) do
        if isSpread(prop) then
            self:finalizesVariablePart(factory, name, isInConstContext, statement, makeNodeOfKind, createSpread, currentVariableProperties, intersectionTypes, newSpreads)
            if ast.IsEntityNameExpression(prop:Expression()) then
                intersectionTypes.v = core.Append(intersectionTypes.v, self:createTypeOfFromEntityNameExpression(prop:Expression()))
                newSpreads.v = core.Append(newSpreads.v, prop)
            else
                self:makeSpreadVariable(factory, name, isInConstContext, statement, createSpread, prop:Expression(), intersectionTypes, newSpreads)
            end
        else
            currentVariableProperties.v = core.Append(currentVariableProperties.v, prop)
        end
    end

    if core.Len(newSpreads.v) == 0 then
        return nil
    end

    self:finalizesVariablePart(factory, name, isInConstContext, statement, makeNodeOfKind, createSpread, currentVariableProperties, intersectionTypes, newSpreads)

    self.changeTracker:ReplaceNode(self.sourceFile, node, makeNodeOfKind(newSpreads.v), nil)
    self.mutatedTarget = true

    return finalType(intersectionTypes.v)
end

-- makeSpreadVariable creates a const variable for a spread expression and adds it to the decomposition.
function isolatedDeclarationsFixer:makeSpreadVariable(factory, name, isInConstContext, statement, createSpread, expression, intersectionTypes, newSpreads)
    local tempName = self.changeTracker.emitContext.factory:NewUniqueNameEx(
        name .. "_Part" .. tostring(core.Len(newSpreads.v) + 1),
        optimisticNameOptions
    )

    local initializer
    if not isInConstContext then
        initializer = factory:DeepCloneNode(expression)
    else
        local constRef = factory:NewTypeReferenceNode(factory:NewIdentifier("const"), nil)
        initializer = factory:NewAsExpression(factory:DeepCloneNode(expression), constRef)
    end

    local varDecl = factory:NewVariableDeclaration(tempName, nil, nil, initializer)
    local varDeclList = factory:NewVariableDeclarationList(factory:NewNodeList({ varDecl }), NodeFlags.Const)
    local varStmt = factory:NewVariableStatement(nil, varDeclList)

    if statement ~= nil then
        self.changeTracker:InsertNodeBefore(self.sourceFile, statement, varStmt, false, change.LeadingTriviaOption.None)
    end

    intersectionTypes.v = core.Append(intersectionTypes.v, self:createTypeOfFromEntityNameExpression(tempName))
    newSpreads.v = core.Append(newSpreads.v, createSpread(tempName))
end

-- finalizesVariablePart finalizes accumulated non-spread properties into a variable.
function isolatedDeclarationsFixer:finalizesVariablePart(factory, name, isInConstContext, statement, makeNodeOfKind, createSpread, currentVariableProperties, intersectionTypes, newSpreads)
    if core.Len(currentVariableProperties.v) > 0 then
        self:makeSpreadVariable(factory, name, isInConstContext, statement, createSpread, makeNodeOfKind(currentVariableProperties.v), intersectionTypes, newSpreads)
        currentVariableProperties.v = nil
    end
end

-- isConstAssertion checks if a node is an `as const` or `<const>` assertion.
function ls.isConstAssertion(node)
    if ast.IsAssertionExpression(node) then
        local typeNode = node:Type()
        return ast.IsConstTypeReference(typeNode)
    end
    return false
end

-- relativeType creates a typeof expression for a node, used in TypePrintMode.Relative.
-- Instead of spelling out the full type, returns `typeof X` for identifiers.
-- For object/array literals with spreads, decomposes into separate variables.
function isolatedDeclarationsFixer:relativeType(node)
    if ast.IsParameterDeclaration(node) then
        return nil
    end
    if ast.IsShorthandPropertyAssignment(node) then
        return self:createTypeOfFromEntityNameExpression(node:AsShorthandPropertyAssignment():Name())
    end
    if ast.IsEntityNameExpression(node) then
        return self:createTypeOfFromEntityNameExpression(node)
    end
    if ls.isConstAssertion(node) then
        return self:relativeType(node:Expression())
    end
    if ast.IsArrayLiteralExpression(node) then
        local varDecl = ast.FindAncestorKind(node, Kind.VariableDeclaration)
        local partName = ""
        if varDecl ~= nil and ast.IsIdentifier(varDecl:Name()) then
            partName = varDecl:Name():AsIdentifier().text
        end
        return self:typeFromArraySpreadElements(node:AsArrayLiteralExpression(), partName)
    end
    if ast.IsObjectLiteralExpression(node) then
        local varDecl = ast.FindAncestorKind(node, Kind.VariableDeclaration)
        local partName = ""
        if varDecl ~= nil and ast.IsIdentifier(varDecl:Name()) then
            partName = varDecl:Name():AsIdentifier().text
        end
        return self:typeFromObjectSpreadAssignment(node:AsObjectLiteralExpression(), partName)
    end
    if ast.IsVariableDeclaration(node) and node:Initializer() ~= nil then
        return self:relativeType(node:Initializer())
    end
    if ast.IsConditionalExpression(node) then
        local cond = node:AsConditionalExpression()
        local trueType = self:relativeType(cond.whenTrue)
        if trueType == nil then
            return nil
        end
        local trueMutated = self.mutatedTarget
        local falseType = self:relativeType(cond.whenFalse)
        if falseType == nil then
            return nil
        end
        self.mutatedTarget = trueMutated or self.mutatedTarget
        local factory = self.changeTracker.nodeFactory
        return factory:NewUnionTypeNode(factory:NewNodeList({ trueType, falseType }))
    end
    return nil
end

-- typeToMinimizedReferenceType converts a type to a type node, then trims trailing
-- type arguments that match their defaults. Ported from TS's
-- services/codefixes/helpers.ts typeToMinimizedReferenceType.
function isolatedDeclarationsFixer:typeToMinimizedReferenceType(t, enclosingDecl, flags)
    local idToSymbol = {}
    -- !!! When truncation tracking is supported, check if the type was truncated
    -- and return factory.NewKeywordTypeNode(ast.KindAnyKeyword) instead of the truncated node.
    local typeNode = self.checker:TypeToTypeNodeEx(t, enclosingDecl, flags, NBInternalFlags.WriteComputedProps, idToSymbol)
    if typeNode == nil then
        return nil
    end
    if ast.IsTypeReferenceNode(typeNode) and t:ObjectFlags() & ObjectFlags.Reference ~= 0 then
        local typeArgs = self.checker:GetTypeArguments(t)
        local nodeTypeArgs = typeNode:TypeArguments()
        if core.Len(typeArgs) > 0 and core.Len(nodeTypeArgs) > 0 then
            local cutoff = ls.endOfRequiredTypeParameters(self.checker, t)
            if cutoff < #nodeTypeArgs then
                -- Trim trailing default type arguments
                local trimmedArgs = self.changeTracker.nodeFactory:NewNodeList(core.Slice(nodeTypeArgs, 0, cutoff))
                typeNode = self.changeTracker.nodeFactory:UpdateTypeReferenceNode(
                    typeNode:AsTypeReferenceNode(),
                    typeNode:AsTypeReferenceNode().typeName,
                    trimmedArgs
                )
            end
        end
    end
    -- Convert import type references (e.g. import("./path").Name) to simple type references
    -- and collect symbols that need to be imported
    local referenceTypeNode, importableSymbols = autoimport.TryGetAutoImportableReferenceFromTypeNode(typeNode, idToSymbol)
    if referenceTypeNode ~= nil then
        typeNode = referenceTypeNode
        self.symbolsToImport = core.AppendAll(self.symbolsToImport, importableSymbols)
    end
    return typeNode
end

-- endOfRequiredTypeParameters finds the number of type arguments that are
-- actually required (i.e., differ from their defaults). Ported from TS's
-- services/codefixes/helpers.ts endOfRequiredTypeParameters.
function ls.endOfRequiredTypeParameters(ch, t)
    local typeArgs = ch:GetTypeArguments(t)
    if core.Len(typeArgs) == 0 then
        return 0
    end
    local target = t:Target()
    if target == nil or target:AsInterfaceType() == nil then
        return #typeArgs
    end
    local typeParams = target:AsInterfaceType():TypeParameters()
    local localTypeParams = target:AsInterfaceType():LocalTypeParameters()
    local outerCount = core.Len(typeParams) - core.Len(localTypeParams)
    for cutoff = 0, #typeArgs - 1 do
        -- Skip cutoff positions where the local type parameter has no default.
        -- This matches TS's check for constraint === undefined on localTypeParameters,
        -- which in practice skips type parameters without defaults (e.g. Set<T>
        -- where T has no default should not have <unknown> elided).
        local localIdx = cutoff - outerCount
        if localIdx < 0 or localIdx >= core.Len(localTypeParams) or not ls.typeParamHasDefault(localTypeParams[localIdx + 1]) then
            goto continue
        end
        do
            local filledIn = ch:FillMissingTypeArguments(core.Slice(typeArgs, 0, cutoff), typeParams, cutoff, false)
            local allMatch = true
            for i, fill in ipairs(filledIn or {}) do
                if fill ~= typeArgs[i] then
                    allMatch = false
                    break
                end
            end
            if allMatch then
                return cutoff
            end
        end
        ::continue::
    end
    return #typeArgs
end

-- typeParamHasDefault checks if a type parameter has a default type declaration.
function ls.typeParamHasDefault(tp)
    local sym = tp:Symbol()
    if sym == nil then
        return false
    end
    for _, decl in ipairs(sym.declarations or {}) do
        if ast.IsTypeParameterDeclaration(decl) and decl:AsTypeParameterDeclaration().defaultType ~= nil then
            return true
        end
    end
    return false
end

function isolatedDeclarationsFixer:addTypeToVariableLike(decl)
    local typeNode = self:inferType(decl, nil)
    if typeNode == nil then
        return ""
    end
    if decl:Type() ~= nil then
        self.changeTracker:ReplaceNode(self.sourceFile, decl:Type(), typeNode, nil)
    else
        self.changeTracker:TryInsertTypeAnnotation(self.sourceFile, decl, typeNode)
        -- Parenthesize paren-less arrow function parameters (`x => ...`) so the inserted `: T`
        -- produces `(x: T) => ...` instead of the invalid `x: T => ...`. Queued after the type
        -- annotation so that the `)` edit at param.End() sorts after the annotation insertion.
        if ast.IsParameterDeclaration(decl) and decl.parent ~= nil and ast.IsArrowFunction(decl.parent) then
            self.changeTracker:ParenthesizeArrowParameters(self.sourceFile, decl.parent)
        end
    end
    return diagnostics.Add_annotation_of_type_0:Localize(self.locale, ls.typeToStringForDiag(typeNode, self.sourceFile, self.changeTracker))
end

-- typeToStringForDiag converts a type node to a string for use in diagnostic descriptions.
-- It reuses the change tracker's EmitContext so that generated identifier names are resolved
-- consistently with the actual code edits, and passes the source file so that the printer's
-- name generator can check for conflicts with existing file-level identifiers.
function ls.typeToStringForDiag(typeNode, sourceFile, ct)
    local emitContext = ct.emitContext
    local savedFlags = emitContext:EmitFlags(typeNode)
    emitContext:SetEmitFlags(typeNode, savedFlags | EF.EFSingleLine)
    local p = printer.NewPrinter(
        {
            newLine = core.NewLineKind.LF,
        },
        {},
        emitContext
    )
    local writer, release = printer.GetSingleLineStringWriter()
    p:Write(typeNode, sourceFile, writer, nil)
    emitContext:SetEmitFlags(typeNode, savedFlags)
    local result = writer:String()
    release()
    if #result > 160 then
        return string.sub(result, 1, 157) .. "..."
    end
    return result
end

-- findAncestorWithMissingType walks up the ancestor chain to find a node that
-- can have a type annotation and is missing one.
function ls.findAncestorWithMissingType(node)
    return ast.FindAncestor(node, function(n)
        if not ls.canHaveTypeAnnotationKinds[n.kind] then
            return false
        end
        if ast.IsObjectBindingPattern(n) or ast.IsArrayBindingPattern(n) then
            return ast.IsVariableDeclaration(n.parent)
        end
        return true
    end)
end

-- findBestFittingNode walks up from the token to find the node that best fits the diagnostic span.
function ls.findBestFittingNode(node, span)
    if node == nil then
        return nil
    end
    while node ~= nil and node:End() < span:Pos() + span:Len() do
        node = node.parent
    end
    while node.parent ~= nil and node.parent:Pos() == node:Pos() and node.parent:End() == node:End() do
        node = node.parent
    end
    if ast.IsIdentifier(node) and ast.HasInitializer(node.parent) and node.parent:Initializer() ~= nil then
        return node.parent:Initializer()
    end
    if ast.IsIdentifier(node) and ast.IsShorthandPropertyAssignment(node.parent) then
        return node.parent
    end
    return node
end

-- isNamedDeclarationKind matches TS's isDeclarationKind, which is narrower than Go's IsDeclaration.
-- Go's IsDeclaration returns true for any node with DeclarationData (including CallExpression),
-- while TS's isDeclaration only returns true for specific named declaration kinds.
ls.namedDeclarationKinds = ast.kindSet(
    Kind.ArrowFunction, Kind.BindingElement, Kind.ClassDeclaration, Kind.ClassExpression,
    Kind.ClassStaticBlockDeclaration, Kind.Constructor, Kind.EnumDeclaration, Kind.EnumMember,
    Kind.ExportSpecifier, Kind.FunctionDeclaration, Kind.FunctionExpression,
    Kind.GetAccessor, Kind.ImportClause, Kind.ImportEqualsDeclaration,
    Kind.ImportSpecifier, Kind.InterfaceDeclaration, Kind.JsxAttribute,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.ModuleDeclaration,
    Kind.NamespaceExportDeclaration, Kind.NamespaceImport, Kind.NamespaceExport,
    Kind.Parameter, Kind.PropertyAssignment, Kind.PropertyDeclaration,
    Kind.PropertySignature, Kind.SetAccessor, Kind.ShorthandPropertyAssignment,
    Kind.TypeAliasDeclaration, Kind.TypeParameter, Kind.VariableDeclaration,
    Kind.JSDocTypedefTag, Kind.JSDocCallbackTag, Kind.JSDocPropertyTag,
    Kind.NamedTupleMember
)

function ls.isNamedDeclarationKind(node)
    return ls.namedDeclarationKinds[node.kind] == true
end

-- isValueSignatureDeclaration checks if a node is a function-like declaration that produces a value.
function ls.isValueSignatureDeclaration(node)
    return ast.IsFunctionExpression(node) or ast.IsArrowFunction(node) or ast.IsMethodDeclaration(node) or
        ast.IsAccessor(node) or ast.IsFunctionDeclaration(node) or ast.IsConstructorDeclaration(node)
end

-- getIdentifierNameForNode derives a meaningful variable name from a node expression.
-- For property access expressions like `obj.foo`, returns "foo". Otherwise returns "newLocal".
-- Ported from TS's getIdentifierForNode in services/refactors/helpers.ts.
function ls.getIdentifierNameForNode(node)
    if ast.IsPropertyAccessExpression(node) then
        local name = node:AsPropertyAccessExpression():Name()
        if ast.IsIdentifier(name) and not ast.IsPrivateIdentifier(name) and scanner.IdentifierToKeywordKind(name:AsIdentifier()) == Kind.Unknown then
            return name:Text()
        end
    end
    return "newLocal"
end

-- addSymbolToExistingImport finds the existing import declaration for the symbol's module
-- and adds the symbol name to the named imports.
function isolatedDeclarationsFixer:addSymbolToExistingImport(sym)
    if sym == nil or sym.parent == nil then
        return
    end

    -- Find the module specifier for this symbol
    local moduleSymbol = sym.parent
    local symbolName = sym.name

    -- Walk the source file's import declarations to find the one importing from the same module
    for _, stmt in ipairs(self.sourceFile.statements.nodes or {}) do
        if not ast.IsImportDeclaration(stmt) then
            goto continue
        end
        do
            local importDecl = stmt:AsImportDeclaration()
            if importDecl.importClause == nil then
                goto continue
            end

            -- Check if this import is from the same module
            local importModuleSymbol = self.checker:GetSymbolAtLocation(importDecl.moduleSpecifier)
            if importModuleSymbol == nil or self.checker:GetMergedSymbol(importModuleSymbol) ~= self.checker:GetMergedSymbol(moduleSymbol) then
                goto continue
            end

            -- Found the matching import - add the symbol to named imports
            local importClause = importDecl.importClause:AsImportClause()
            if importClause.namedBindings ~= nil and ast.IsNamedImports(importClause.namedBindings) then
                -- Add to existing named imports
                local existingElements = importClause.namedBindings:AsNamedImports().elements.nodes
                local factory = self.changeTracker.nodeFactory
                local newSpecifier = factory:NewImportSpecifier(false, nil, factory:NewIdentifier(symbolName))
                -- Go's append may write into spare capacity of the original slice, never into its
                -- visible elements: copy.
                local newElements = core.Slice(existingElements, 0, core.Len(existingElements))
                newElements[#newElements + 1] = newSpecifier
                local newNamedImports = factory:NewNamedImports(factory:NewNodeList(newElements))
                local newImportClause = factory:UpdateImportClause(importClause, importClause.phaseModifier, importClause:Name(), newNamedImports)
                local newImportDecl = factory:UpdateImportDeclaration(importDecl, importDecl:Modifiers(), newImportClause, importDecl.moduleSpecifier, importDecl.attributes)
                self.changeTracker:ReplaceNode(self.sourceFile, stmt, newImportDecl, nil)
            end
            return
        end
        ::continue::
    end
end
