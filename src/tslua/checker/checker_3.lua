local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local debug = require("tslua.debug")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local CheckMode = checker.CheckMode
local ContextFlags = checker.ContextFlags
local TypeFacts = checker.TypeFacts
local IterationUse = checker.IterationUse
local AccessFlags = checker.AccessFlags
local UnionReduction = checker.UnionReduction
local CachedTypeKind = checker.CachedTypeKind
local NodeCheckFlags = checker.NodeCheckFlags
local AssignmentKind = checker.AssignmentKind
local SignatureKind = checker.SignatureKind
local SignatureFlags = checker.SignatureFlags
local InferencePriority = checker.InferencePriority
local UnusedKind = checker.UnusedKind
local SymbolFlags = ast.SymbolFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local FindAncestorResult = ast.FindAncestorResult

function Checker:reportUnused(location, kind, diagnostic)
    if location.flags & (NodeFlags.Ambient | NodeFlags.ThisNodeOrAnySubNodesHasError) == 0 then
        local isError = self:unusedIsError(kind)
        if isError then
            self:addDiagnostic(diagnostic)
        else
            local suggestion = diagnostic:Clone()
            suggestion:SetCategory(diagnostics.Category.Suggestion)
            self:addSuggestionDiagnostic(suggestion)
        end
    end
end

function Checker:unusedIsError(kind)
    if kind == UnusedKind.Local then
        return core.Tristate_IsTrue(self.compilerOptions.noUnusedLocals)
    elseif kind == UnusedKind.Parameter then
        return core.Tristate_IsTrue(self.compilerOptions.noUnusedParameters)
    else
        error("Unhandled case in unusedIsError", 0)
    end
end

function Checker:checkUnusedClassMembers(node)
    for _, member in ipairs(node:Members() or {}) do
        local k = member.kind
        if k == Kind.MethodDeclaration or k == Kind.PropertyDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
            if ast.IsSetAccessorDeclaration(member) and member:Symbol().flags & SymbolFlags.GetAccessor ~= 0 then
                goto continue -- Already would have reported an error on the getter.
            end
            local symbol = self:getSymbolOfDeclaration(member)
            if not self:isReferenced(symbol) and (ast.HasModifier(member, ModifierFlags.Private) or member:Name() ~= nil and ast.IsPrivateIdentifier(member:Name())) and member.flags & NodeFlags.Ambient == 0 then
                self:reportUnused(member, UnusedKind.Local, checker.NewDiagnosticForNode(member:Name(), diagnostics.X_0_is_declared_but_its_value_is_never_read, self:symbolToString(symbol)))
            end
        elseif k == Kind.Constructor then
            for _, parameter in ipairs(member:AsConstructorDeclaration().parameters.nodes) do
                if not self:isReferenced(parameter:Symbol()) and ast.HasSyntacticModifier(parameter, ModifierFlags.Private) then
                    self:reportUnused(parameter, UnusedKind.Local, checker.NewDiagnosticForNode(parameter:Name(), diagnostics.Property_0_is_declared_but_its_value_is_never_read, ast.SymbolName(parameter:Symbol())))
                end
            end
        elseif k == Kind.IndexSignature or k == Kind.SemicolonClassElement or k == Kind.ClassStaticBlockDeclaration or k == Kind.JSTypeAliasDeclaration then
            -- Can't be private
        else
            error("Unhandled case in checkUnusedClassMembers", 0)
        end
        ::continue::
    end
end

function Checker:checkUnusedLocalsAndParameters(node)
    -- Go iterates a set and a map here (random order); insertion order is used instead.
    local variableParents = {}
    local variableParentsSeen = {}
    local importClauses = nil
    local importClauseOrder = {}
    for _, localSymbol in pairs(node:Locals() or {}) do
        local referenceKinds = self.symbolReferenceLinks:Get(localSymbol).referenceKinds
        if localSymbol.flags & SymbolFlags.TypeParameter ~= 0 and (localSymbol.flags & SymbolFlags.Variable == 0 or referenceKinds & SymbolFlags.Variable ~= 0) or
            localSymbol.flags & SymbolFlags.TypeParameter == 0 and (referenceKinds ~= 0 or localSymbol.exportSymbol ~= nil or
                localSymbol.flags & SymbolFlags.ModuleExports ~= 0) then
            goto continue
        end
        for _, declaration in ipairs(localSymbol.declarations or {}) do
            if ast.IsVariableDeclaration(declaration) or ast.IsParameterDeclaration(declaration) or ast.IsBindingElement(declaration) then
                local p = ast.GetRootDeclaration(declaration).parent
                if not variableParentsSeen[p] then
                    variableParentsSeen[p] = true
                    variableParents[#variableParents + 1] = p
                end
            elseif ast.IsImportClause(declaration) or ast.IsImportSpecifier(declaration) or ast.IsNamespaceImport(declaration) then
                if not checker.isIdentifierThatStartsWithUnderscore(declaration:Name()) then
                    if importClauses == nil then
                        importClauses = {}
                    end
                    local importClause = checker.importClauseFromImported(declaration)
                    if importClauses[importClause] == nil then
                        importClauses[importClause] = {}
                        importClauseOrder[#importClauseOrder + 1] = importClause
                    end
                    local list = importClauses[importClause]
                    list[#list + 1] = declaration
                end
            else
                if not ast.IsTypeParameterDeclaration(declaration) and not ast.IsAmbientModule(declaration) then
                    self:reportUnusedLocal(declaration, ast.SymbolName(localSymbol))
                end
            end
        end
        ::continue::
    end
    for _, declaration in ipairs(variableParents) do
        if ast.IsVariableDeclarationList(declaration) then
            self:reportUnusedVariables(declaration)
        else
            self:reportUnusedParameters(declaration)
        end
    end
    for _, declaration in ipairs(importClauseOrder) do
        self:reportUnusedImports(declaration, importClauses[declaration])
    end
end

function Checker:reportUnusedLocal(node, name)
    local message = core.IfElse(ast.IsTypeDeclaration(node), diagnostics.X_0_is_declared_but_never_used, diagnostics.X_0_is_declared_but_its_value_is_never_read)
    self:reportUnused(node, UnusedKind.Local, checker.NewDiagnosticForNode(core.OrElse(node:Name(), node), message, name))
end

function Checker:reportUnusedVariables(node)
    local declarations = node:AsVariableDeclarationList().declarations.nodes
    if #declarations > 1 and core.Every(declarations, function(d) return self:isUnreferencedVariableDeclaration(d) end) then
        self:reportUnusedVariable(node, checker.NewDiagnosticForNode(node, diagnostics.All_variables_are_unused))
    else
        self:reportUnusedVariableDeclarations(declarations)
    end
end

function Checker:reportUnusedParameters(node)
    self:reportUnusedVariableDeclarations(node:Parameters())
end

function Checker:reportUnusedBindingElements(node)
    local declarations = node:Elements() or {}
    if #declarations > 1 and core.Every(declarations, function(d) return self:isUnreferencedVariableDeclaration(d) end) then
        self:reportUnusedVariable(node, checker.NewDiagnosticForNode(node, diagnostics.All_destructured_elements_are_unused))
    else
        self:reportUnusedVariableDeclarations(declarations)
    end
end

function Checker:reportUnusedVariableDeclarations(declarations)
    for _, declaration in ipairs(declarations or {}) do
        local name = declaration:Name()
        if name ~= nil and not ast.IsParameterPropertyDeclaration(declaration, declaration.parent) and not ast.IsThisParameter(declaration) then
            if ast.IsBindingPattern(name) then
                self:reportUnusedBindingElements(name)
            elseif self:isUnreferencedVariableDeclaration(declaration) then
                self:reportUnusedVariable(declaration, checker.NewDiagnosticForNode(name, diagnostics.X_0_is_declared_but_its_value_is_never_read, name:Text()))
            end
        end
    end
end

function Checker:isUnreferencedVariableDeclaration(node)
    local name = node:Name()
    if name == nil then
        return true
    end
    if ast.IsBindingPattern(name) then
        return core.Every(node:Name():Elements(), function(d) return self:isUnreferencedVariableDeclaration(d) end)
    end
    if self.symbolReferenceLinks:Get(self:getSymbolOfDeclaration(node)).referenceKinds & SymbolFlags.Variable ~= 0 then
        return false
    end
    if ast.IsBindingElement(node) and ast.IsObjectBindingPattern(node.parent) then
        -- In `{ a, ...b }, `a` is considered used since it removes a property from `b`. `b` may still be unused though.
        local lastElement = core.LastOrNil(node.parent:Elements())
        if node ~= lastElement and checker.hasDotDotDotToken(lastElement) then
            return false
        end
    end
    if (ast.IsParameterDeclaration(node) or
            ast.IsVariableDeclaration(node) and (ast.IsForInOrOfStatement(node.parent.parent) or self:getCombinedNodeFlagsCached(node) & NodeFlags.Using ~= 0) or
            ast.IsBindingElement(node) and not (ast.IsObjectBindingPattern(node.parent) and node:PropertyName() == nil)) and
        checker.isIdentifierThatStartsWithUnderscore(name) then
        return false
    end
    return true
end

function Checker:reportUnusedImports(node, unuseds)
    local declarationCount = core.IfElse(node:Name() ~= nil, 1, 0)
    local namedBindings = node:AsImportClause().namedBindings
    if namedBindings ~= nil then
        if ast.IsNamespaceImport(namedBindings) then
            declarationCount = declarationCount + 1
        else
            declarationCount = declarationCount + core.Len(namedBindings:Elements())
        end
    end
    if declarationCount > 1 and declarationCount == #unuseds then
        self:reportUnused(node, UnusedKind.Local, checker.NewDiagnosticForNode(node.parent, diagnostics.All_imports_in_import_declaration_are_unused))
    else
        for _, unused in ipairs(unuseds) do
            self:reportUnusedLocal(unused, unused:Name():Text())
        end
    end
end

function checker.isIdentifierThatStartsWithUnderscore(node)
    return ast.IsIdentifier(node) and node:Text() ~= "" and string.byte(node:Text(), 1) == string.byte("_")
end

function checker.importClauseFromImported(node)
    if node.kind == Kind.ImportClause then
        return node
    elseif node.kind == Kind.NamespaceImport then
        return node.parent
    else
        return node.parent.parent
    end
end

function Checker:checkUnusedInferTypeParameter(node)
    local typeParameter = node:AsInferTypeNode().typeParameter
    if self:isUnreferencedTypeParameter(typeParameter) then
        self:reportUnused(node, UnusedKind.Parameter, checker.NewDiagnosticForNode(typeParameter:Name(), diagnostics.X_0_is_declared_but_never_used, typeParameter:Name():Text()))
    end
end

function Checker:checkUnusedTypeParameters(node)
    if not checker.allDeclarationsInSameSourceFile(self:getSymbolOfDeclaration(node)) then
        return
    end
    local typeParameterList = node:TypeParameterList()
    if typeParameterList == nil then
        return
    end
    if #typeParameterList.nodes > 1 and core.Every(typeParameterList.nodes, function(tp) return self:isUnreferencedTypeParameter(tp) end) then
        local file = ast.GetSourceFileOfNode(node)
        local loc = checker.rangeOfTypeParameters(file, typeParameterList)
        self:reportUnused(node, UnusedKind.Parameter, ast.NewDiagnostic(file, loc, diagnostics.All_type_parameters_are_unused))
    else
        for _, typeParameter in ipairs(typeParameterList.nodes) do
            if self:isUnreferencedTypeParameter(typeParameter) then
                self:reportUnused(node, UnusedKind.Parameter, checker.NewDiagnosticForNode(typeParameter, diagnostics.X_0_is_declared_but_never_used, typeParameter:Name():Text()))
            end
        end
    end
end

function Checker:isUnreferencedTypeParameter(typeParameter)
    return self.symbolReferenceLinks:Get(self:getMergedSymbol(typeParameter:Symbol())).referenceKinds & SymbolFlags.TypeParameter == 0 and not checker.isIdentifierThatStartsWithUnderscore(typeParameter:Name())
end

function Checker:checkUnusedRenamedBindingElements()
    for _, node in ipairs(self.renamedBindingElementsInTypes or {}) do
        if self.symbolReferenceLinks:Get(self:getSymbolOfDeclaration(node)).referenceKinds == 0 then
            local wrappingDeclaration = ast.WalkUpBindingElementsAndPatterns(node)
            debug.Assert(ast.IsPartOfParameterDeclaration(wrappingDeclaration), "Only parameter declaration should be checked here")
            local diagnostic = checker.NewDiagnosticForNode(node:Name(), diagnostics.X_0_is_an_unused_renaming_of_1_Did_you_intend_to_use_it_as_a_type_annotation, scanner.DeclarationNameToString(node:Name()), scanner.DeclarationNameToString(node:PropertyName()))
            if wrappingDeclaration:Type() == nil then
                -- entire parameter does not have type annotation, suggest adding an annotation
                diagnostic:AddRelatedInfo(ast.NewDiagnostic(ast.GetSourceFileOfNode(wrappingDeclaration), core.NewTextRange(wrappingDeclaration:End(), wrappingDeclaration:End()), diagnostics.We_can_only_write_a_type_for_0_by_adding_a_type_for_the_entire_parameter_here, scanner.DeclarationNameToString(node:PropertyName())))
            end
            self:addDiagnostic(diagnostic)
        end
    end
end

function Checker:checkExpressionStatement(node)
    -- Grammar checking
    self:checkGrammarStatementInAmbientContext(node)
    self:checkExpression(node:Expression())
end

-- Returns the type of an expression. Unlike checkExpression, this function is simply concerned
-- with computing the type and may not fully check all contained sub-expressions for errors.
function Checker:getTypeOfExpression(node)
    -- Don't bother caching types that require no flow analysis and are quick to compute.
    local quickType = self:getQuickTypeOfExpression(node)
    if quickType ~= nil then
        return quickType
    end
    -- If a type has been cached for the node, return it.
    if self.flowTypeCache ~= nil then
        local cachedType = self.flowTypeCache[node]
        if cachedType ~= nil then
            return cachedType
        end
    end
    local startInvocationCount = self.flowInvocationCount
    local t = self:checkExpressionEx(node, CheckMode.TypeOnly)
    -- If control flow analysis was required to determine the type, it is worth caching.
    if self.flowInvocationCount ~= startInvocationCount then
        if self.flowTypeCache == nil then
            self.flowTypeCache = {}
        end
        self.flowTypeCache[node] = t
    end
    return t
end

-- Returns the type of an expression. Unlike checkExpression, this function is simply concerned
-- with computing the type and may not fully check all contained sub-expressions for errors.
function Checker:getQuickTypeOfExpression(node)
    local expr = ast.SkipParentheses(node)
    if ast.IsAwaitExpression(expr) then
        local t = self:getQuickTypeOfExpression(expr:Expression())
        if t ~= nil then
            return self:getAwaitedType(t)
        end
        return nil
        -- Optimize for the common case of a call to a function with a single non-generic call
        -- signature where we can just fetch the return type without checking the arguments.
    elseif ast.IsCallExpression(expr) and expr:Expression().kind ~= Kind.SuperKeyword and not ast.IsRequireCall(expr, true --[[requireStringLiteralLikeArgument]]) and not self:isSymbolOrSymbolForCall(expr) and not ast.IsImportCall(expr) then
        if checker.isCallChain(expr) then
            return self:getReturnTypeOfSingleNonGenericSignatureOfCallChain(expr)
        end
        return self:getReturnTypeOfSingleNonGenericSignature(self:checkNonNullExpression(expr:Expression()), SignatureKind.Call)
    elseif ast.IsNewExpression(expr) then
        return self:getReturnTypeOfSingleNonGenericSignature(self:checkNonNullExpression(expr:Expression()), SignatureKind.Construct)
    elseif ast.IsAssertionExpression(expr) and not ast.IsConstTypeReference(expr:Type()) then
        return self:getTypeFromTypeNode(expr:Type())
    elseif ast.IsLiteralExpression(node) or ast.IsBooleanLiteral(node) then
        return self:checkExpression(node)
    end
    return nil
end

function Checker:getReturnTypeOfSingleNonGenericSignature(funcType, kind)
    local signature = self:getSingleSignature(funcType, kind, true --[[allowMembers]])
    if signature ~= nil and #(signature.typeParameters or {}) == 0 then
        return self:getReturnTypeOfSignature(signature)
    end
    return nil
end

function Checker:getReturnTypeOfSingleNonGenericSignatureOfCallChain(expr)
    local funcType = self:checkExpression(expr:Expression())
    local nonOptionalType = self:getOptionalExpressionType(funcType, expr:Expression())
    local returnType = self:getReturnTypeOfSingleNonGenericSignature(funcType, SignatureKind.Call)
    if returnType ~= nil then
        return self:propagateOptionalTypeMarker(returnType, expr, nonOptionalType ~= funcType)
    end
    return nil
end

function Checker:checkNonNullExpression(node)
    return self:checkNonNullType(self:checkExpression(node), node)
end

function Checker:checkNonNullType(t, node)
    return self:checkNonNullTypeWithReporter(t, node, Checker.reportObjectPossiblyNullOrUndefinedError)
end

-- reportError is a function(c, node, facts) (a Go method expression such as
-- (*Checker).reportObjectPossiblyNullOrUndefinedError -> Checker.reportObjectPossiblyNullOrUndefinedError).
function Checker:checkNonNullTypeWithReporter(t, node, reportError)
    if self.strictNullChecks and t.flags & TypeFlags.Unknown ~= 0 then
        if ast.IsEntityNameExpression(node) then
            local nodeText = checker.entityNameToString(node)
            if #nodeText < 100 then
                self:error(node, diagnostics.X_0_is_of_type_unknown, nodeText)
                return self.errorType
            end
        end
        self:error(node, diagnostics.Object_is_of_type_unknown)
        return self.errorType
    end
    local facts = self:getTypeFacts(t, TypeFacts.IsUndefinedOrNull)
    if facts & TypeFacts.IsUndefinedOrNull ~= 0 then
        reportError(self, node, facts)
        local nonNullable = self:GetNonNullableType(t)
        if nonNullable.flags & (TypeFlags.Nullable | TypeFlags.Never) ~= 0 then
            return self.errorType
        end
        return nonNullable
    end
    return t
end

function Checker:checkNonNullNonVoidType(t, node)
    local nonNullType = self:checkNonNullType(t, node)
    if nonNullType.flags & TypeFlags.Void ~= 0 then
        if ast.IsEntityNameExpression(node) then
            local nodeText = checker.entityNameToString(node)
            if ast.IsIdentifier(node) and nodeText == "undefined" then
                self:error(node, diagnostics.The_value_0_cannot_be_used_here, nodeText)
                return nonNullType
            end
            if #nodeText < 100 then
                self:error(node, diagnostics.X_0_is_possibly_undefined, nodeText)
                return nonNullType
            end
        end
        self:error(node, diagnostics.Object_is_possibly_undefined)
    end
    return nonNullType
end

function Checker:reportObjectPossiblyNullOrUndefinedError(node, facts)
    local nodeText = ""
    if ast.IsEntityNameExpression(node) then
        nodeText = checker.entityNameToString(node)
    end
    if node.kind == Kind.NullKeyword then
        self:error(node, diagnostics.The_value_0_cannot_be_used_here, "null")
        return
    end
    if nodeText ~= "" and #nodeText < 100 then
        if ast.IsIdentifier(node) and nodeText == "undefined" then
            self:error(node, diagnostics.The_value_0_cannot_be_used_here, "undefined")
            return
        end
        self:error(node, core.IfElse(facts & TypeFacts.IsUndefined ~= 0,
            core.IfElse(facts & TypeFacts.IsNull ~= 0,
                diagnostics.X_0_is_possibly_null_or_undefined,
                diagnostics.X_0_is_possibly_undefined),
            diagnostics.X_0_is_possibly_null), nodeText)
    else
        self:error(node, core.IfElse(facts & TypeFacts.IsUndefined ~= 0,
            core.IfElse(facts & TypeFacts.IsNull ~= 0,
                diagnostics.Object_is_possibly_null_or_undefined,
                diagnostics.Object_is_possibly_undefined),
            diagnostics.Object_is_possibly_null))
    end
end

function Checker:checkExpressionWithContextualType(node, contextualType, inferenceContext, checkMode)
    local contextNode = self:getContextNode(node)
    self:pushContextualType(contextNode, contextualType, false --[[isCache]])
    self:pushInferenceContext(contextNode, inferenceContext)
    local t = self:checkExpressionEx(node, checkMode | CheckMode.Contextual | core.IfElse(inferenceContext ~= nil, CheckMode.Inferential, 0))
    -- In CheckMode.Inferential we collect intra-expression inference sites to process before fixing any type
    -- parameters. This information is no longer needed after the call to checkExpression.
    if inferenceContext ~= nil and inferenceContext.intraExpressionInferenceSites ~= nil then
        inferenceContext.intraExpressionInferenceSites = nil
    end
    -- We strip literal freshness when an appropriate contextual type is present such that contextually typed
    -- literals always preserve their literal types (otherwise they might widen during type inference). An alternative
    -- here would be to not mark contextually typed literals as fresh in the first place.
    if self:maybeTypeOfKind(t, TypeFlags.Literal) and self:isLiteralOfContextualType(t, self:instantiateContextualType(contextualType, node, ContextFlags.None)) then
        t = self:getRegularTypeOfLiteralType(t)
    end
    self:popInferenceContext()
    self:popContextualType()
    return t
end

function Checker:getContextNode(node)
    if ast.IsJsxAttributes(node) and not ast.IsJsxSelfClosingElement(node.parent) then
        -- Needs to be the root JsxElement, so it encompasses the attributes _and_ the children (which are essentially part of the attributes)
        return node.parent.parent
    end
    return node
end

function Checker:checkExpressionCached(node)
    return self:checkExpressionCachedEx(node, CheckMode.Normal)
end

function Checker:checkExpressionCachedEx(node, checkMode)
    if checkMode ~= CheckMode.Normal then
        return self:checkExpressionEx(node, checkMode)
    end
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        -- When computing a type that we're going to cache, we need to ignore any ongoing control flow
        -- analysis because variables may have transient types in indeterminable states. Moving flowLoopStart
        -- to the top of the stack ensures all transient types are computed from a known point.
        local saveFlowLoopStack = self.flowLoopStack
        local saveFlowTypeCache = self.flowTypeCache
        self.flowLoopStack = nil
        self.flowTypeCache = nil
        links.resolvedType = self:checkExpressionEx(node, checkMode)
        self.flowTypeCache = saveFlowTypeCache
        self.flowLoopStack = saveFlowLoopStack
    end
    return links.resolvedType
end

-- Returns the type of an expression. Unlike checkExpression, this function is simply concerned
-- with computing the type and may not fully check all contained sub-expressions for errors.
-- It is intended for uses where you know there is no contextual type,
-- and requesting the contextual type might cause a circularity or other bad behaviour.
-- It sets the contextual type of the node to any before calling getTypeOfExpression.
function Checker:getContextFreeTypeOfExpression(node)
    local cached = self.contextFreeTypes[node]
    if cached ~= nil then
        return cached
    end
    self:pushContextualType(node, self.anyType, false --[[isCache]])
    local t = self:checkExpressionEx(node, CheckMode.SkipContextSensitive)
    self.contextFreeTypes[node] = t
    self:popContextualType()
    return t
end

function Checker:checkExpression(node)
    return self:checkExpressionEx(node, CheckMode.Normal)
end

function Checker:checkExpressionEx(node, checkMode)
    local saveCurrentNode = self.currentNode
    self.currentNode = node
    self.instantiationCount = 0
    local uninstantiatedType = self:checkExpressionWorker(node, checkMode)
    local t = self:instantiateTypeWithSingleGenericCallSignature(node, uninstantiatedType, checkMode)
    if checker.isConstEnumObjectType(t) then
        self:checkConstEnumAccess(node, t)
    end
    self.currentNode = saveCurrentNode
    return t
end

function Checker:checkConstEnumAccess(node, t)
    -- enum object type for const enums are only permitted in:
    -- - 'left' in property access
    -- - 'object' in indexed access
    -- - target in rhs of import statement
    local ok = ast.IsPropertyAccessExpression(node.parent) and node.parent:Expression() == node or
        ast.IsElementAccessExpression(node.parent) and node.parent:Expression() == node or
        ((ast.IsIdentifier(node) or ast.IsQualifiedName(node)) and checker.isInRightSideOfImportOrExportAssignment(node) or
            ast.IsTypeQueryNode(node.parent) and node.parent:AsTypeQueryNode().exprName == node) or
        ast.IsExportSpecifier(node.parent) -- We allow reexporting const enums
    if not ok then
        self:error(node, diagnostics.X_const_enums_can_only_be_used_in_property_or_index_access_expressions_or_the_right_hand_side_of_an_import_declaration_or_export_assignment_or_type_query)
    end
    -- --verbatimModuleSyntax only gets checked here when the enum usage does not
    -- resolve to an import, because imports of ambient const enums get checked
    -- separately in `checkAliasSymbol`.
    if core.Tristate_IsTrue(self.compilerOptions.isolatedModules) or core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) and ok and self.resolveName(node, ast.GetFirstIdentifier(node):Text(), SymbolFlags.Alias, nil, false, true) == nil then
        debug.Assert(t.symbol.flags & SymbolFlags.ConstEnum ~= 0)
        local constEnumDeclaration = t.symbol.valueDeclaration
        local redirect = self.program:GetProjectReferenceFromOutputDts(ast.GetSourceFileOfNode(constEnumDeclaration):Path())
        if constEnumDeclaration.flags & NodeFlags.Ambient ~= 0 and not ast.IsValidTypeOnlyAliasUseSite(node) and (redirect == nil or not redirect.resolved:CompilerOptions():ShouldPreserveConstEnums()) then
            self:error(node, diagnostics.Cannot_access_ambient_const_enums_when_0_is_enabled, self:getIsolatedModulesLikeFlagName())
        end
    end
end

function Checker:instantiateTypeWithSingleGenericCallSignature(node, t, checkMode)
    if checkMode & (CheckMode.Inferential | CheckMode.SkipGenericFunctions) == 0 then
        return t
    end
    local callSignature = self:getSingleSignature(t, SignatureKind.Call, true --[[allowMembers]])
    local constructSignature = self:getSingleSignature(t, SignatureKind.Construct, true --[[allowMembers]])
    local signature = core.OrElse(callSignature, constructSignature)
    if signature == nil or #(signature.typeParameters or {}) == 0 then
        return t
    end
    local contextualType = self:getApparentTypeOfContextualType(node, ContextFlags.NoConstraints)
    if contextualType == nil then
        return t
    end
    local contextualSignature = self:getSingleSignature(self:GetNonNullableType(contextualType), core.IfElse(callSignature ~= nil, SignatureKind.Call, SignatureKind.Construct), false --[[allowMembers]])
    if contextualSignature == nil or #(contextualSignature.typeParameters or {}) ~= 0 then
        return t
    end
    if checkMode & CheckMode.SkipGenericFunctions ~= 0 then
        self:skippedGenericFunction(node, checkMode)
        return self.anyFunctionType
    end
    local context = self:getInferenceContext(node)
    -- We have an expression that is an argument of a generic function for which we are performing
    -- type argument inference. The expression is of a function type with a single generic call
    -- signature and a contextual function type with a single non-generic call signature. Now check
    -- if the outer function returns a function type with a single non-generic call signature and
    -- if some of the outer function type parameters have no inferences so far. If so, we can
    -- potentially add inferred type parameters to the outer function return type.
    local returnSignature = nil
    if context.signature ~= nil then
        local returnType = self:getReturnTypeOfSignature(context.signature)
        if returnType ~= nil then
            returnSignature = self:getSingleCallOrConstructSignature(returnType)
        end
    end
    if returnSignature ~= nil and #(returnSignature.typeParameters or {}) == 0 and not core.Every(context.inferences, function(info) return checker.hasInferenceCandidates(info) end) then
        -- Instantiate the signature with its own type parameters as type arguments, possibly
        -- renaming the type parameters to ensure they have unique names.
        local uniqueTypeParameters = self:getUniqueTypeParameters(context, signature.typeParameters)
        local instantiatedSignature = self:getSignatureInstantiationWithoutFillingInTypeArguments(signature, uniqueTypeParameters)
        -- Infer from the parameters of the instantiated signature to the parameters of the
        -- contextual signature starting with an empty set of inference candidates.
        local inferences = core.Map(context.inferences, function(info)
            return checker.newInferenceInfo(info.typeParameter)
        end)
        self:applyToParameterTypes(instantiatedSignature, contextualSignature, function(source, target)
            self:inferTypes(inferences, source, target, InferencePriority.None, true --[[contravariant]])
        end)
        if core.Some(inferences, function(info) return checker.hasInferenceCandidates(info) end) then
            -- We have inference candidates, indicating that one or more type parameters are referenced
            -- in the parameter types of the contextual signature. Now also infer from the return type.
            self:applyToReturnTypes(instantiatedSignature, contextualSignature, function(source, target)
                self:inferTypes(inferences, source, target, InferencePriority.None, false)
            end)
            -- If the type parameters for which we produced candidates do not have any inferences yet,
            -- we adopt the new inference candidates and add the type parameters of the expression type
            -- to the set of inferred type parameters for the outer function return type.
            if not checker.hasOverlappingInferences(context.inferences, inferences) then
                self:mergeInferences(context.inferences, inferences)
                context.inferredTypeParameters = core.Concatenate(context.inferredTypeParameters, uniqueTypeParameters)
                return self:getOrCreateTypeFromSignature(instantiatedSignature)
            end
        end
    end
    -- TODO: The signature may reference any outer inference contexts, but we map pop off and then apply new inference contexts,
    -- and thus get different inferred types. That this is cached on the *first* such attempt is not currently an issue, since expression
    -- types *also* get cached on the first pass. If we ever properly speculate, though, the cached "isolatedSignatureType" signature
    -- field absolutely needs to be included in the list of speculative caches.
    return self:getOrCreateTypeFromSignature(self:instantiateSignatureInContextOf(signature, contextualSignature, context, nil))
end

function Checker:getOuterInferenceTypeParameters()
    local result = nil
    for i = 0, #(self.inferenceContextInfos or {}) - 1 do
        local context = self.inferenceContextInfos[i + 1].context
        if context ~= nil then
            for _, info in ipairs(context.inferences or {}) do
                result = core.Append(result, info.typeParameter)
            end
        end
    end
    return result
end

function Checker:getUniqueTypeParameters(context, typeParameters)
    local oldTypeParameters = nil
    local newTypeParameters = nil
    local result = {}
    for _, tp in ipairs(typeParameters or {}) do
        local name = tp.symbol.name
        if checker.hasTypeParameterByName(context.inferredTypeParameters, name) or checker.hasTypeParameterByName(result, name) then
            local newName = checker.getUniqueTypeParameterName(core.Concatenate(context.inferredTypeParameters, result), name)
            local symbol = self:newSymbol(SymbolFlags.TypeParameter, newName)
            local newTypeParameter = self:newTypeParameter(symbol)
            newTypeParameter:AsTypeParameter().target = tp
            oldTypeParameters = core.Append(oldTypeParameters, tp)
            newTypeParameters = core.Append(newTypeParameters, newTypeParameter)
            result[#result + 1] = newTypeParameter
        else
            result[#result + 1] = tp
        end
    end
    if core.Len(newTypeParameters) ~= 0 then
        local mapper = checker.newTypeMapper(oldTypeParameters, newTypeParameters)
        for _, tp in ipairs(newTypeParameters) do
            tp:AsTypeParameter().mapper = mapper
        end
    end
    return result
end

function checker.hasTypeParameterByName(typeParameters, name)
    return core.Some(typeParameters, function(tp)
        return tp.symbol.name == name
    end)
end

function checker.getUniqueTypeParameterName(typeParameters, baseName)
    while #baseName > 1 and string.byte(baseName, #baseName) >= string.byte("0") and string.byte(baseName, #baseName) <= string.byte("9") do
        baseName = string.sub(baseName, 1, #baseName - 1)
    end
    local index = 1
    while true do
        local augmentedName = baseName .. tostring(index)
        if not checker.hasTypeParameterByName(typeParameters, augmentedName) then
            return augmentedName
        end
        index = index + 1
    end
end

local checkExpressionWorkerDispatch = {
    [Kind.Identifier] = function(c, node, checkMode)
        return c:checkIdentifier(node, checkMode)
    end,
    [Kind.PrivateIdentifier] = function(c, node)
        return c:checkPrivateIdentifierExpression(node)
    end,
    [Kind.ThisKeyword] = function(c, node)
        return c:checkThisExpression(node)
    end,
    [Kind.SuperKeyword] = function(c, node)
        return c:checkSuperExpression(node)
    end,
    [Kind.NullKeyword] = function(c)
        return c.nullWideningType
    end,
    [Kind.StringLiteral] = function(c, node)
        if c:isSkipDirectInferenceNode(node) then
            return c.blockedStringType
        end
        return c:getFreshTypeOfLiteralType(c:getStringLiteralType(node:Text()))
    end,
    [Kind.NumericLiteral] = function(c, node)
        c:checkGrammarNumericLiteral(node:AsNumericLiteral())
        return c:getFreshTypeOfLiteralType(c:getNumberLiteralType(jsnum.FromString(node:Text())))
    end,
    [Kind.BigIntLiteral] = function(c, node)
        c:checkGrammarBigIntLiteral(node:AsBigIntLiteral())
        return c:getFreshTypeOfLiteralType(c:getBigIntLiteralType(jsnum.NewPseudoBigInt(jsnum.ParsePseudoBigInt(node:Text()), false --[[negative]])))
    end,
    [Kind.TrueKeyword] = function(c)
        return c.trueType
    end,
    [Kind.FalseKeyword] = function(c)
        return c.falseType
    end,
    [Kind.TemplateExpression] = function(c, node)
        return c:checkTemplateExpression(node)
    end,
    [Kind.RegularExpressionLiteral] = function(c, node)
        return c:checkRegularExpressionLiteral(node)
    end,
    [Kind.ArrayLiteralExpression] = function(c, node, checkMode)
        return c:checkArrayLiteral(node, checkMode)
    end,
    [Kind.ObjectLiteralExpression] = function(c, node, checkMode)
        return c:checkObjectLiteral(node, checkMode)
    end,
    [Kind.PropertyAccessExpression] = function(c, node, checkMode)
        return c:checkPropertyAccessExpression(node, checkMode, false --[[writeOnly]])
    end,
    [Kind.QualifiedName] = function(c, node, checkMode)
        return c:checkQualifiedName(node, checkMode)
    end,
    [Kind.ElementAccessExpression] = function(c, node, checkMode)
        return c:checkIndexedAccess(node, checkMode)
    end,
    [Kind.CallExpression] = function(c, node, checkMode)
        if ast.IsImportCall(node) then
            return c:checkImportCallExpression(node)
        end
        return c:checkCallExpression(node, checkMode)
    end,
    [Kind.NewExpression] = function(c, node, checkMode)
        return c:checkCallExpression(node, checkMode)
    end,
    [Kind.TaggedTemplateExpression] = function(c, node)
        return c:checkTaggedTemplateExpression(node)
    end,
    [Kind.ParenthesizedExpression] = function(c, node, checkMode)
        return c:checkParenthesizedExpression(node, checkMode)
    end,
    [Kind.ClassExpression] = function(c, node)
        return c:checkClassExpression(node)
    end,
    [Kind.FunctionExpression] = function(c, node, checkMode)
        return c:checkFunctionExpressionOrObjectLiteralMethod(node, checkMode)
    end,
    [Kind.TypeAssertionExpression] = function(c, node, checkMode)
        return c:checkAssertion(node, checkMode)
    end,
    [Kind.TypeOfExpression] = function(c, node)
        return c:checkTypeOfExpression(node)
    end,
    [Kind.NonNullExpression] = function(c, node)
        return c:checkNonNullAssertion(node)
    end,
    [Kind.ExpressionWithTypeArguments] = function(c, node)
        return c:checkExpressionWithTypeArguments(node)
    end,
    [Kind.SatisfiesExpression] = function(c, node)
        return c:checkSatisfiesExpression(node)
    end,
    [Kind.MetaProperty] = function(c, node)
        return c:checkMetaProperty(node)
    end,
    [Kind.DeleteExpression] = function(c, node)
        return c:checkDeleteExpression(node)
    end,
    [Kind.VoidExpression] = function(c, node)
        return c:checkVoidExpression(node)
    end,
    [Kind.AwaitExpression] = function(c, node)
        return c:checkAwaitExpression(node)
    end,
    [Kind.PrefixUnaryExpression] = function(c, node)
        return c:checkPrefixUnaryExpression(node)
    end,
    [Kind.PostfixUnaryExpression] = function(c, node)
        return c:checkPostfixUnaryExpression(node)
    end,
    [Kind.BinaryExpression] = function(c, node, checkMode)
        return c:checkBinaryExpression(node, checkMode)
    end,
    [Kind.ConditionalExpression] = function(c, node, checkMode)
        return c:checkConditionalExpression(node, checkMode)
    end,
    [Kind.SpreadElement] = function(c, node, checkMode)
        return c:checkSpreadExpression(node, checkMode)
    end,
    [Kind.OmittedExpression] = function(c)
        return c.undefinedWideningType
    end,
    [Kind.YieldExpression] = function(c, node)
        return c:checkYieldExpression(node)
    end,
    [Kind.SyntheticExpression] = function(c, node)
        return c:checkSyntheticExpression(node)
    end,
    [Kind.JsxExpression] = function(c, node, checkMode)
        return c:checkJsxExpression(node, checkMode)
    end,
    [Kind.JsxElement] = function(c, node, checkMode)
        return c:checkJsxElement(node, checkMode)
    end,
    [Kind.JsxSelfClosingElement] = function(c, node, checkMode)
        return c:checkJsxSelfClosingElement(node, checkMode)
    end,
    [Kind.JsxFragment] = function(c, node)
        return c:checkJsxFragment(node)
    end,
    [Kind.JsxAttributes] = function(c, node, checkMode)
        return c:checkJsxAttributes(node, checkMode)
    end,
    [Kind.JsxOpeningElement] = function()
        error("Should never directly check a JsxOpeningElement", 0)
    end,
}
checkExpressionWorkerDispatch[Kind.NoSubstitutionTemplateLiteral] = checkExpressionWorkerDispatch[Kind.StringLiteral]
checkExpressionWorkerDispatch[Kind.ArrowFunction] = checkExpressionWorkerDispatch[Kind.FunctionExpression]
checkExpressionWorkerDispatch[Kind.AsExpression] = checkExpressionWorkerDispatch[Kind.TypeAssertionExpression]

function Checker:checkExpressionWorker(node, checkMode)
    local f = checkExpressionWorkerDispatch[node.kind]
    if f ~= nil then
        return f(self, node, checkMode)
    end
    return self.errorType
end

function Checker:checkPrivateIdentifierExpression(node)
    self:checkGrammarPrivateIdentifierExpression(node:AsPrivateIdentifier())
    local symbol = self:getSymbolForPrivateIdentifierExpression(node)
    if symbol ~= nil then
        self:markPropertyAsReferenced(symbol, nil --[[nodeForCheckWriteOnly]], false --[[isSelfTypeAccess]])
    end
    return self.anyType
end

function Checker:getSymbolForPrivateIdentifierExpression(node)
    local links = self.symbolNodeLinks:Get(node)
    if links.resolvedSymbol == nil then
        links.resolvedSymbol = self:lookupSymbolForPrivateIdentifierDeclaration(node:Text(), node)
    end
    return links.resolvedSymbol
end

function Checker:checkSuperExpression(node)
    local isCallExpression = ast.IsCallExpression(node.parent) and node.parent:Expression() == node
    local immediateContainer = checker.getSuperContainer(node, true --[[stopOnFunctions]])
    local container = immediateContainer

    -- adjust the container reference in case if super is used inside arrow functions with arbitrarily deep nesting
    if not isCallExpression then
        while container ~= nil and ast.IsArrowFunction(container) do
            container = checker.getSuperContainer(container, true --[[stopOnFunctions]])
        end
    end

    local function isLegalUsageOfSuperExpression()
        if isCallExpression then
            -- TS 1.0 SPEC (April 2014): 4.8.1
            -- Super calls are only permitted in constructors of derived classes
            return ast.IsConstructorDeclaration(container)
        end
        -- TS 1.0 SPEC (April 2014)
        -- 'super' property access is allowed
        -- - In a constructor, instance member function, instance member accessor, or instance member variable initializer where this references a derived class instance
        -- - In a static member function or static member accessor

        -- topmost container must be something that is directly nested in the class declaration\object literal expression
        if ast.IsClassLike(container.parent) or ast.IsObjectLiteralExpression(container.parent) then
            if ast.IsStatic(container) then
                return ast.NodeKindIs(container, Kind.MethodDeclaration, Kind.MethodSignature, Kind.GetAccessor, Kind.SetAccessor, Kind.PropertyDeclaration, Kind.ClassStaticBlockDeclaration)
            end
            return ast.NodeKindIs(container, Kind.MethodDeclaration, Kind.MethodSignature, Kind.GetAccessor, Kind.SetAccessor, Kind.PropertyDeclaration, Kind.PropertySignature, Kind.Constructor)
        end
        return false
    end

    if container == nil or not isLegalUsageOfSuperExpression() then
        -- issue more specific error if super is used in computed property name
        -- class A { foo() { return "1" }}
        -- class B {
        --     [super.foo()]() {}
        -- }
        local current = ast.FindAncestorOrQuit(node, function(n)
            if n == container then
                return FindAncestorResult.FindAncestorQuit
            end
            if ast.IsComputedPropertyName(n) then
                return FindAncestorResult.FindAncestorTrue
            end
            return FindAncestorResult.FindAncestorFalse
        end)
        if current ~= nil and ast.IsComputedPropertyName(current) then
            self:error(node, diagnostics.X_super_cannot_be_referenced_in_a_computed_property_name)
        elseif isCallExpression then
            self:error(node, diagnostics.Super_calls_are_not_permitted_outside_constructors_or_in_nested_functions_inside_constructors)
        elseif container == nil or container.parent == nil or not (ast.IsClassLike(container.parent) or ast.IsObjectLiteralExpression(container.parent)) then
            self:error(node, diagnostics.X_super_can_only_be_referenced_in_members_of_derived_classes_or_object_literal_expressions)
        else
            self:error(node, diagnostics.X_super_property_access_is_permitted_only_in_a_constructor_member_function_or_member_accessor_of_a_derived_class)
        end
        return self.errorType
    end
    if not isCallExpression and ast.IsConstructorDeclaration(immediateContainer) then
        self:checkThisBeforeSuper(node, container, diagnostics.X_super_must_be_called_before_accessing_a_property_of_super_in_the_constructor_of_a_derived_class)
    end
    if container.parent.kind == Kind.ObjectLiteralExpression then
        -- for object literal assume that type of 'super' is 'any'
        return self.anyType
    end
    -- at this point the only legal case for parent is ClassLikeDeclaration
    local classLikeDeclaration = container.parent
    if ast.GetClassExtendsHeritageElement(classLikeDeclaration) == nil then
        self:error(node, diagnostics.X_super_can_only_be_referenced_in_a_derived_class)
        return self.errorType
    end
    if self:classDeclarationExtendsNull(classLikeDeclaration) then
        if isCallExpression then
            return self.errorType
        end
        return self.nullWideningType
    end
    local classType = self:getDeclaredTypeOfSymbol(self:getSymbolOfDeclaration(classLikeDeclaration))
    local baseClassType = nil
    if classType ~= nil then
        baseClassType = core.FirstOrNil(self:getBaseTypes(classType))
    end
    if baseClassType == nil then
        return self.errorType
    end
    if ast.IsConstructorDeclaration(container) and self:isInConstructorArgumentInitializer(node, container) then
        -- issue custom error message for super property access in constructor arguments (to be aligned with old compiler)
        self:error(node, diagnostics.X_super_cannot_be_referenced_in_constructor_arguments)
        return self.errorType
    end
    if ast.IsStatic(container) or isCallExpression then
        if not isCallExpression and
            self.languageVersion <= core.ScriptTarget.ES2021 and
            (ast.IsPropertyDeclaration(container) or ast.IsClassStaticBlockDeclaration(container)) then
            -- for `super.x` or `super[x]` in a static initializer, mark all enclosing
            -- block scope containers so that we can report potential collisions with
            -- `Reflect`.
            local current = ast.GetEnclosingBlockScopeContainer(node.parent)
            while current ~= nil do
                if not ast.IsSourceFile(current) or ast.IsExternalOrCommonJSModule(current:AsSourceFile()) then
                    local links = self.nodeLinks:Get(current)
                    links.flags = links.flags | NodeCheckFlags.ContainsSuperPropertyInStaticInitializer
                end
                current = ast.GetEnclosingBlockScopeContainer(current)
            end
        end
        return self:getBaseConstructorTypeOfClass(classType)
    end
    return self:getTypeWithThisArgument(baseClassType, classType:AsInterfaceType().thisType, false)
end

function Checker:isInConstructorArgumentInitializer(node, constructorDecl)
    return ast.FindAncestorOrQuit(node, function(n)
        if ast.IsFunctionLikeDeclaration(n) then
            return FindAncestorResult.FindAncestorQuit
        end
        if ast.IsParameterDeclaration(n) and n.parent == constructorDecl then
            return FindAncestorResult.FindAncestorTrue
        end
        return FindAncestorResult.FindAncestorFalse
    end) ~= nil
end

function Checker:checkTemplateExpression(node)
    local expr = node:AsTemplateExpression()
    local texts = {}
    local types = {}
    texts[1] = expr.head:Text()
    for i1, span in ipairs(expr.templateSpans.nodes) do
        local t = self:checkExpression(span:Expression())
        if self:maybeTypeOfKindConsideringBaseConstraint(t, TypeFlags.ESSymbolLike) then
            self:error(span:Expression(), diagnostics.Implicit_conversion_of_a_symbol_to_a_string_will_fail_at_runtime_Consider_wrapping_this_expression_in_String)
        end
        texts[i1 + 1] = span:AsTemplateSpan().literal:Text()
        types[i1] = core.IfElse(self:isTypeAssignableTo(t, self.templateConstraintType), t, self.stringType)
    end
    local evaluated = nil
    if not ast.IsTaggedTemplateExpression(node.parent) then
        evaluated = self.evaluate(node, node).value
    end
    if evaluated ~= nil then
        return self:getFreshTypeOfLiteralType(self:getStringLiteralType(evaluated))
    end
    if self:isConstContext(node) or self:isTemplateLiteralContext(node) or checker.someType(core.OrElse(self:getContextualType(node, ContextFlags.None), self.unknownType), function(t) return self:isTemplateLiteralContextualType(t) end) then
        return self:getTemplateLiteralType(texts, types)
    end
    return self.stringType
end

function Checker:isTemplateLiteralContext(node)
    local parent = node.parent
    return ast.IsParenthesizedExpression(parent) and self:isTemplateLiteralContext(parent) or ast.IsElementAccessExpression(parent) and parent:AsElementAccessExpression().argumentExpression == node
end

function Checker:isTemplateLiteralContextualType(t)
    return t.flags & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral) ~= 0 or t.flags & TypeFlags.InstantiableNonPrimitive ~= 0 and self:maybeTypeOfKind(core.OrElse(self:getBaseConstraintOfType(t), self.unknownType), TypeFlags.StringLike)
end

function Checker:checkRegularExpressionLiteral(node)
    local nodeLinks = self.nodeLinks:Get(node)
    if nodeLinks.flags & NodeCheckFlags.TypeChecked == 0 then
        nodeLinks.flags = nodeLinks.flags | NodeCheckFlags.TypeChecked
        self:checkGrammarRegularExpressionLiteral(node:AsRegularExpressionLiteral())
    end
    return self.globalRegExpType
end

function Checker:checkArrayLiteral(node, checkMode)
    local elements = node:Elements() or {}
    local elementTypes = {}
    local elementInfos = {}
    self:pushCachedContextualType(node)
    local inDestructuringPattern = ast.IsAssignmentTarget(node)
    local inConstContext = self:isConstContext(node)
    local contextualType = self:getApparentTypeOfContextualType(node, ContextFlags.None)
    local inTupleContext = checker.isSpreadIntoCallOrNew(node) or contextualType ~= nil and checker.someType(contextualType, function(t)
        return self:isTupleLikeType(t) or self:isGenericMappedType(t) and t:AsMappedType().nameType == nil and self:getHomomorphicTypeVariable(core.OrElse(t:AsMappedType().target, t)) ~= nil
    end)
    local hasOmittedExpression = false
    for i1, e in ipairs(elements) do
        if ast.IsSpreadElement(e) then
            local spreadType = self:checkExpressionEx(e:Expression(), checkMode)
            if self:isArrayLikeType(spreadType) then
                elementTypes[i1] = spreadType
                elementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Variadic })
            elseif inDestructuringPattern then
                -- Given the following situation:
                --    var c: {};
                --    [...c] = ["", 0];
                --
                -- c is represented in the tree as a spread element in an array literal.
                -- But c really functions as a rest element, and its purpose is to provide
                -- a contextual type for the right hand side of the assignment. Therefore,
                -- instead of calling checkExpression on "...c", which will give an error
                -- if c is not iterable/array-like, we need to act as if we are trying to
                -- get the contextual element type from it. So we do something similar to
                -- getContextualTypeForElementExpression, which will crucially not error
                -- if there is no index type / iterated type.
                local restElementType = self:getIndexTypeOfType(spreadType, self.numberType)
                if restElementType == nil then
                    restElementType = self:getIteratedTypeOrElementType(IterationUse.Destructuring, spreadType, self.undefinedType, nil --[[errorNode]], false --[[checkAssignability]])
                    if restElementType == nil then
                        restElementType = self.unknownType
                    end
                end
                elementTypes[i1] = restElementType
                elementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Rest })
            else
                elementTypes[i1] = self:checkIteratedTypeOrElementType(IterationUse.Spread, spreadType, self.undefinedType, e:Expression())
                elementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Rest })
            end
        elseif self.exactOptionalPropertyTypes and ast.IsOmittedExpression(e) then
            hasOmittedExpression = true
            elementTypes[i1] = self.undefinedOrMissingType
            elementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Optional })
        else
            local t = self:checkExpressionForMutableLocation(e, checkMode)
            elementTypes[i1] = self:addOptionalityEx(t, true --[[isProperty]], hasOmittedExpression)
            elementInfos[i1] = checker.TupleElementInfo_new({ flags = core.IfElse(hasOmittedExpression, ElementFlags.Optional, ElementFlags.Required) })
            if inTupleContext and checkMode & CheckMode.Inferential ~= 0 and checkMode & CheckMode.SkipContextSensitive == 0 and self:isContextSensitive(e) then
                local inferenceContext = self:getInferenceContext(node)
                -- In CheckMode.Inferential we should always have an inference context
                self:addIntraExpressionInferenceSite(inferenceContext, e, t)
            end
        end
    end
    self:popContextualType()
    if inDestructuringPattern then
        return self:createTupleTypeEx(elementTypes, elementInfos, false)
    end
    if checkMode & CheckMode.ForceTuple ~= 0 or inConstContext or inTupleContext then
        return self:createArrayLiteralType(self:createTupleTypeEx(elementTypes, elementInfos, inConstContext and not (contextualType ~= nil and checker.someType(contextualType, function(t) return self:isMutableArrayLikeType(t) end)) --[[readonly]]))
    end
    local elementType
    if #elementTypes ~= 0 then
        for i1, e in ipairs(elementTypes) do
            if elementInfos[i1].flags & ElementFlags.Variadic ~= 0 then
                elementTypes[i1] = core.OrElse(self:getIndexedAccessTypeOrUndefined(e, self.numberType, AccessFlags.None, nil, nil), self.anyType)
            end
        end
        elementType = self:getUnionTypeEx(elementTypes, UnionReduction.Subtype, nil, nil)
    else
        elementType = core.IfElse(self.strictNullChecks, self.implicitNeverType, self.undefinedWideningType)
    end
    return self:createArrayLiteralType(self:createArrayTypeEx(elementType, inConstContext))
end

function Checker:createArrayLiteralType(t)
    if t.objectFlags & ObjectFlags.Reference == 0 then
        return t
    end
    local key = checker.CachedTypeKey(CachedTypeKind.ArrayLiteralType, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local literalType = self:cloneTypeReference(t)
    literalType.objectFlags = literalType.objectFlags | ObjectFlags.ArrayLiteral | ObjectFlags.ContainsObjectOrArrayLiteral
    self.cachedTypes[key] = literalType
    return literalType
end

function checker.isSpreadIntoCallOrNew(node)
    local parent = ast.WalkUpParenthesizedExpressions(node.parent)
    return ast.IsSpreadElement(parent) and ast.IsCallOrNewExpression(parent.parent)
end

function Checker:checkQualifiedName(node, checkMode)
    local left = node:AsQualifiedName().left
    local leftType
    if ast.IsPartOfTypeQuery(node) and ast.IsThisIdentifier(left) then
        leftType = self:checkNonNullType(self:checkThisExpression(left), left)
    else
        leftType = self:checkNonNullExpression(left)
    end
    return self:checkPropertyAccessExpressionOrQualifiedName(node, left, leftType, node:AsQualifiedName().right, checkMode, false)
end

function Checker:checkIndexedAccess(node, checkMode)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        return self:checkElementAccessChain(node, checkMode)
    end
    return self:checkElementAccessExpression(node, self:checkNonNullExpression(node:Expression()), checkMode)
end

function Checker:checkElementAccessChain(node, checkMode)
    local exprType = self:checkExpression(node:Expression())
    local nonOptionalType = self:getOptionalExpressionType(exprType, node:Expression())
    return self:propagateOptionalTypeMarker(self:checkElementAccessExpression(node, self:checkNonNullType(nonOptionalType, node:Expression()), checkMode), node, nonOptionalType ~= exprType)
end

function Checker:checkElementAccessExpression(node, exprType, checkMode)
    local objectType = exprType
    if checker.getAssignmentTargetKind(node) ~= AssignmentKind.None or self:isMethodAccessForCall(node) then
        objectType = self:getWidenedType(objectType)
    end
    local indexExpression = node:AsElementAccessExpression().argumentExpression
    local indexType = self:checkExpression(indexExpression)
    if self:isErrorType(objectType) or objectType == self.silentNeverType then
        return objectType
    end
    if checker.isConstEnumObjectType(objectType) and not ast.IsStringLiteralLike(indexExpression) then
        self:error(indexExpression, diagnostics.A_const_enum_member_can_only_be_accessed_using_a_string_literal)
        return self.errorType
    end
    local effectiveIndexType = indexType
    if self:isForInVariableForNumericPropertyNames(indexExpression) then
        effectiveIndexType = self.numberType
    end
    local assignmentTargetKind = checker.getAssignmentTargetKind(node)
    local accessFlags
    if assignmentTargetKind == AssignmentKind.None then
        accessFlags = AccessFlags.ExpressionPosition
    else
        accessFlags = AccessFlags.Writing |
            core.IfElse(assignmentTargetKind == AssignmentKind.Compound, AccessFlags.ExpressionPosition, 0) |
            core.IfElse(self:isGenericObjectType(objectType) and not checker.isThisTypeParameter(objectType), AccessFlags.NoIndexSignatures, 0)
    end
    local indexedAccessType = core.OrElse(self:getIndexedAccessTypeOrUndefined(objectType, effectiveIndexType, accessFlags, node, nil), self.errorType)
    return self:checkIndexedAccessIndexType(self:getFlowTypeOfAccessExpression(node, self:getResolvedSymbolOrNil(node), indexedAccessType, indexExpression, checkMode), node)
end

-- Return true if given node is an expression consisting of an identifier (possibly parenthesized)
-- that references a for-in variable for an object with numeric property names.
function Checker:isForInVariableForNumericPropertyNames(expr)
    local e = ast.SkipParentheses(expr)
    if ast.IsIdentifier(e) then
        local symbol = self:getResolvedSymbol(e)
        if symbol.flags & SymbolFlags.Variable ~= 0 then
            local child = expr
            local node = expr.parent
            while node ~= nil do
                if ast.IsForInStatement(node) and child == node:AsForInOrOfStatement().statement and self:getForInVariableSymbol(node) == symbol and self:hasNumericPropertyNames(self:getTypeOfExpression(node:Expression())) then
                    return true
                end
                child = node
                node = node.parent
            end
        end
    end
    return false
end

-- Return the symbol of the for-in variable declared or referenced by the given for-in statement.
function Checker:getForInVariableSymbol(node)
    local initializer = node:Initializer()
    if ast.IsVariableDeclarationList(initializer) then
        local declarations = initializer:AsVariableDeclarationList().declarations.nodes
        if #declarations > 0 then
            local variable = declarations[1]
            if variable ~= nil and not ast.IsBindingPattern(variable:Name()) then
                return self:getSymbolOfDeclaration(variable)
            end
        end
    elseif ast.IsIdentifier(initializer) then
        return self:getResolvedSymbol(initializer)
    end
    return nil
end

-- Return true if the given type is considered to have numeric property names.
function Checker:hasNumericPropertyNames(t)
    return core.Len(self:getIndexInfosOfType(t)) == 1 and self:getIndexInfoOfType(t, self.numberType) ~= nil
end

function Checker:checkIndexedAccessIndexType(t, accessNode)
    if t.flags & TypeFlags.IndexedAccess == 0 then
        return t
    end
    -- Check if the index type is assignable to 'keyof T' for the object type.
    local objectType = t:AsIndexedAccessType().objectType
    local indexType = t:AsIndexedAccessType().indexType
    -- skip index type deferral on remapping mapped types
    local objectIndexType
    if self:isGenericMappedType(objectType) and self:getMappedTypeNameTypeKind(objectType) == checker.MappedTypeNameTypeKind.Remapping then
        objectIndexType = self:getIndexTypeForMappedType(objectType, checker.IndexFlags.None)
    else
        objectIndexType = self:getIndexTypeEx(objectType, checker.IndexFlags.None)
    end
    local hasNumberIndexInfo = self:getIndexInfoOfType(objectType, self.numberType) ~= nil
    if checker.everyType(indexType, function(t1)
            return self:isTypeAssignableTo(t1, objectIndexType) or hasNumberIndexInfo and self:isApplicableIndexType(t1, self.numberType)
        end) then
        if accessNode.kind == Kind.ElementAccessExpression and ast.IsAssignmentTarget(accessNode) and objectType.objectFlags & ObjectFlags.Mapped ~= 0 and checker.getMappedTypeModifiers(objectType) & checker.MappedTypeModifiers.IncludeReadonly ~= 0 then
            self:error(accessNode, diagnostics.Index_signature_in_type_0_only_permits_reading, self:TypeToString(objectType))
        end
        return t
    end
    if self:isGenericObjectType(objectType) then
        local propertyName = self:getPropertyNameFromIndex(indexType, accessNode)
        if propertyName ~= ast.InternalSymbolNameMissing then
            local propertySymbol = self:getConstituentProperty(objectType, propertyName)
            if propertySymbol ~= nil and checker.getDeclarationModifierFlagsFromSymbol(propertySymbol) & ModifierFlags.NonPublicAccessibilityModifier ~= 0 then
                self:error(accessNode, diagnostics.Private_or_protected_member_0_cannot_be_accessed_on_a_type_parameter, propertyName)
                return self.errorType
            end
        end
    end
    self:error(accessNode, diagnostics.Type_0_cannot_be_used_to_index_type_1, self:TypeToString(indexType), self:TypeToString(objectType))
    return self.errorType
end

function Checker:getConstituentProperty(objectType, propertyName)
    for _, t in ipairs(self:getApparentType(objectType):Distributed()) do
        local prop = self:getPropertyOfType(t, propertyName)
        if prop ~= nil then
            return prop
        end
    end
    return nil
end

function Checker:checkImportCallExpression(node)
    -- Check grammar of dynamic import
    self:checkGrammarImportCallExpression(node)
    local args = node:Arguments() or {}
    if core.Len(args) == 0 then
        -- No call arguments exist, so there are no child expressions to check.
        return self:createPromiseReturnType(node, self.anyType)
    end
    local specifier = args[1]
    local specifierType = self:checkExpressionCached(specifier)
    local optionsType = nil
    if core.Len(args) > 1 then
        optionsType = self:checkExpressionCached(args[2])
    end
    -- Even though multiple arguments is grammatically incorrect, type-check extra arguments for completion
    for i = 2, core.Len(args) - 1 do
        self:checkExpressionCached(args[i + 1])
    end
    if specifierType.flags & TypeFlags.Nullable ~= 0 or not self:isTypeAssignableTo(specifierType, self.stringType) then
        self:error(specifier, diagnostics.Dynamic_import_s_specifier_must_be_of_type_string_but_here_has_type_0, self:TypeToString(specifierType))
    end
    if optionsType ~= nil then
        local importCallOptionsType = self.getGlobalImportCallOptionsTypeChecked()
        if importCallOptionsType ~= self.emptyObjectType then
            self:checkTypeAssignableTo(optionsType, self:getNullableType(importCallOptionsType, TypeFlags.Undefined), args[2], nil)
        end
        if ast.IsObjectLiteralExpression(args[2]) then
            for _, prop in ipairs(args[2]:AsObjectLiteralExpression().properties.nodes) do
                if ast.IsPropertyAssignment(prop) and ast.IsIdentifier(prop:Name()) and prop:Name():Text() == "assert" then
                    self:error(prop:Name(), diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert)
                    break
                end
            end
        end
    end
    -- resolveExternalModuleName will return undefined if the moduleReferenceExpression is not a string literal
    local moduleSymbol = self:resolveExternalModuleName(node, specifier, false --[[ignoreErrors]])
    if moduleSymbol ~= nil then
        local esModuleSymbol = self:resolveExternalModuleSymbol(moduleSymbol, true --[[dontResolveAlias]])
        if esModuleSymbol ~= nil then
            local syntheticType = self:getTypeWithSyntheticDefaultOnly(self:getTypeOfSymbol(esModuleSymbol), esModuleSymbol, moduleSymbol, specifier)
            if syntheticType == nil then
                syntheticType = self:getTypeWithSyntheticDefaultImportType(self:getTypeOfSymbol(esModuleSymbol), esModuleSymbol, moduleSymbol, specifier)
            end
            return self:createPromiseReturnType(node, syntheticType)
        end
    end
    return self:createPromiseReturnType(node, self.anyType)
end

--[[
 * Syntactically and semantically checks a call or new expression.
 * @param node The call/new expression to be checked.
 * @returns On success, the expression's signature's return type. On failure, anyType.
]]
function Checker:checkCallExpression(node, checkMode)
    self:checkGrammarTypeArguments(node, node:TypeArgumentList())
    local signature = self:getResolvedSignature(node, nil --[[candidatesOutArray]], checkMode)
    if signature == self.resolvingSignature then
        -- CheckMode.SkipGenericFunctions is enabled and this is a call to a generic function that
        -- returns a function type. We defer checking and return silentNeverType.
        return self.silentNeverType
    end
    self:checkDeprecatedSignature(signature, node)
    if node:Expression().kind == Kind.SuperKeyword then
        return self.voidType
    end
    if ast.IsNewExpression(node) then
        local declaration = signature.declaration
        if declaration ~= nil and not ast.IsConstructorDeclaration(declaration) and not ast.IsConstructSignatureDeclaration(declaration) and not ast.IsConstructorTypeNode(declaration) then
            -- When resolved signature is a call signature (and not a construct signature) the result type is any
            if self.noImplicitAny then
                self:error(node, diagnostics.X_new_expression_whose_target_lacks_a_construct_signature_implicitly_has_an_any_type)
            end
            return self.anyType
        end
    end
    if ast.IsInJSFile(node) and self:isCommonJSRequire(node) then
        return self:resolveExternalModuleTypeByLiteral(node:Arguments()[1])
    end
    local returnType = self:getReturnTypeOfSignature(signature)
    -- Treat any call to the global 'Symbol' function that is part of a const variable or readonly property
    -- as a fresh unique symbol literal type.
    if returnType.flags & TypeFlags.ESSymbolLike ~= 0 and self:isSymbolOrSymbolForCall(node) then
        return self:getESSymbolLikeTypeForNode(ast.WalkUpParenthesizedExpressions(node.parent))
    end
    if ast.IsCallExpression(node) and node:QuestionDotToken() == nil and ast.IsExpressionStatement(node.parent) and returnType.flags & TypeFlags.Void ~= 0 and self:getTypePredicateOfSignature(signature) ~= nil then
        if not ast.IsDottedName(node:Expression()) then
            self:error(node:Expression(), diagnostics.Assertions_require_the_call_target_to_be_an_identifier_or_qualified_name)
        elseif self:getEffectsSignature(node) == nil then
            local diagnostic = self:error(node:Expression(), diagnostics.Assertions_require_every_name_in_the_call_target_to_be_declared_with_an_explicit_type_annotation)
            self:getTypeOfDottedName(node:Expression(), diagnostic)
        end
    end
    return returnType
end

function Checker:checkDeprecatedSignature(sig, node)
    if sig.flags & SignatureFlags.IsSignatureCandidateForOverloadFailure ~= 0 then
        return
    end
    if sig.declaration ~= nil and self:IsDeprecatedDeclaration(sig.declaration) then
        local suggestionNode = self:getDeprecatedSuggestionNode(node)
        local name = checker.tryGetPropertyAccessOrIdentifierToString(ast.GetInvokedExpression(node))
        self:addDeprecatedSuggestionWithSignature(suggestionNode, sig.declaration, name, self:signatureToString(sig))
    end
end

function Checker:addDeprecatedSuggestionWithSignature(location, declaration, deprecatedEntity, signatureString)
    local message = core.IfElse(deprecatedEntity ~= "", diagnostics.The_signature_0_of_1_is_deprecated, diagnostics.X_0_is_deprecated)
    local diagnostic = checker.NewDiagnosticForNode(location, message, signatureString, deprecatedEntity)
    return self:addDeprecatedSuggestionWorker({ declaration }, diagnostic)
end

function Checker:isSymbolOrSymbolForCall(node)
    if not ast.IsCallExpression(node) then
        return false
    end
    local left = node:Expression()
    if ast.IsPropertyAccessExpression(left) and left:Name():Text() == "for" then
        left = left:Expression()
    end
    if not ast.IsIdentifier(left) or left:Text() ~= "Symbol" then
        return false
    end
    -- make sure `Symbol` is the global symbol
    local globalESSymbol = self.getGlobalESSymbolConstructorSymbolOrNil()
    if globalESSymbol == nil then
        return false
    end
    return globalESSymbol == self.resolveName(left, "Symbol", SymbolFlags.Value, nil --[[nameNotFoundMessage]], false --[[isUse]], false)
end

--[[
 * Resolve a signature of a given call-like expression.
 * @param node a call-like expression to try resolve a signature for
 * @param candidatesOutArray an array of signature to be filled in by the function. It is passed by signature help in the language service;
 *    the function will fill it up with appropriate candidate signatures
 * @return a signature of the call-like expression or undefined if one can't be found
]]
-- candidatesOutArray (Go *[]*Signature) is nil or a Lua array whose contents are replaced.
function Checker:getResolvedSignature(node, candidatesOutArray, checkMode)
    local links = self.signatureLinks:Get(node)
    -- If getResolvedSignature has already been called, we will have cached the resolvedSignature.
    -- However, it is possible that either candidatesOutArray was not passed in the first time,
    -- or that a different candidatesOutArray was passed in. Therefore, we need to redo the work
    -- to correctly fill the candidatesOutArray.
    local cached = links.resolvedSignature
    if cached ~= nil and cached ~= self.resolvingSignature and candidatesOutArray == nil then
        return cached
    end
    local saveResolutionStart = self.resolutionStart
    if cached == nil then
        -- If we haven't already done so, temporarily reset the resolution stack. This allows us to
        -- handle "inverted" situations where, for example, an API client asks for the type of a symbol
        -- containined in a function call argument whose contextual type depends on the symbol itself
        -- through resolution of the containing function call. By resetting the resolution stack we'll
        -- retry the symbol type resolution with the resolvingSignature marker in place to suppress
        -- the contextual type circularity.
        self.resolutionStart = core.Len(self.typeResolutions)
    end
    links.resolvedSignature = self.resolvingSignature
    local result = self:resolveSignature(node, candidatesOutArray, checkMode)
    self.resolutionStart = saveResolutionStart
    -- When CheckMode.SkipGenericFunctions is set we use resolvingSignature to indicate that call
    -- resolution should be deferred.
    if result ~= self.resolvingSignature then
        -- if the signature resolution originated on a node that itself depends on the contextual type
        -- then it's possible that the resolved signature might not be the same as the one that would be computed in source order
        -- since resolving such signature leads to resolving the potential outer signature, its arguments and thus the very same signature
        -- it's possible that this inner resolution sets the resolvedSignature first.
        -- In such a case we ignore the local result and reuse the correct one that was cached.
        if links.resolvedSignature ~= self.resolvingSignature then
            result = links.resolvedSignature
        end
        -- If signature resolution originated in control flow type analysis (for example to compute the
        -- assigned type in a flow assignment) we don't cache the result as it may be based on temporary
        -- types from the control flow analysis.
        if core.Len(self.flowLoopStack) == 0 then
            links.resolvedSignature = result
        else
            links.resolvedSignature = cached
        end
    end
    return result
end

function Checker:resolveSignature(node, candidatesOutArray, checkMode)
    local k = node.kind
    if k == Kind.CallExpression then
        return self:resolveCallExpression(node, candidatesOutArray, checkMode)
    elseif k == Kind.NewExpression then
        return self:resolveNewExpression(node, candidatesOutArray, checkMode)
    elseif k == Kind.TaggedTemplateExpression then
        return self:resolveTaggedTemplateExpression(node, candidatesOutArray, checkMode)
    elseif k == Kind.Decorator then
        return self:resolveDecorator(node, candidatesOutArray, checkMode)
    elseif k == Kind.JsxOpeningFragment or k == Kind.JsxOpeningElement or k == Kind.JsxSelfClosingElement then
        return self:resolveJsxOpeningLikeElement(node, candidatesOutArray, checkMode)
    elseif k == Kind.BinaryExpression then
        return self:resolveInstanceofExpression(node, candidatesOutArray, checkMode)
    end
    error("Unhandled case in resolveSignature", 0)
end

function Checker:resolveCallExpression(node, candidatesOutArray, checkMode)
    if node:Expression().kind == Kind.SuperKeyword then
        local superType = self:checkSuperExpression(node:Expression())
        if checker.IsTypeAny(superType) then
            for _, arg in ipairs(node:Arguments() or {}) do
                -- Still visit arguments so they get marked for visibility, etc
                self:checkExpression(arg)
            end
            return self.anySignature
        end
        if not self:isErrorType(superType) then
            -- In super call, the candidate signatures are the matching arity signatures of the base constructor function instantiated
            -- with the type arguments specified in the extends clause.
            local baseTypeNode = ast.GetClassExtendsHeritageElement(ast.GetContainingClass(node))
            if baseTypeNode ~= nil then
                local baseConstructors = self:getInstantiatedConstructorsForTypeArguments(superType, baseTypeNode:TypeArguments(), baseTypeNode)
                return self:resolveCall(node, baseConstructors, candidatesOutArray, checkMode, SignatureFlags.None, nil)
            end
        end
        return self:resolveUntypedCall(node)
    end
    if ast.IsImportCall(node) then
        return self:resolveUntypedCall(node)
    end
    local callChainFlags
    local funcType = self:checkExpression(node:Expression())
    if checker.isCallChain(node) then
        local nonOptionalType = self:getOptionalExpressionType(funcType, node:Expression())
        if nonOptionalType == funcType then
            callChainFlags = SignatureFlags.None
        elseif ast.IsOutermostOptionalChain(node) then
            callChainFlags = SignatureFlags.IsOuterCallChain
        else
            callChainFlags = SignatureFlags.IsInnerCallChain
        end
        funcType = nonOptionalType
    else
        callChainFlags = SignatureFlags.None
    end
    funcType = self:checkNonNullTypeWithReporter(funcType, node:Expression(), Checker.reportCannotInvokePossiblyNullOrUndefinedError)
    if funcType == self.silentNeverType then
        return self.silentNeverSignature
    end
    local apparentType = self:getApparentType(funcType)
    if self:isErrorType(apparentType) then
        -- Another error has already been reported
        return self:resolveErrorCall(node)
    end
    -- Technically, this signatures list may be incomplete. We are taking the apparent type,
    -- but we are not including call signatures that may have been added to the Object or
    -- Function interface, since they have none by default. This is a bit of a leap of faith
    -- that the user will not add any.
    local callSignatures = self:getSignaturesOfType(apparentType, SignatureKind.Call)
    local numConstructSignatures = core.Len(self:getSignaturesOfType(apparentType, SignatureKind.Construct))
    -- TS 1.0 Spec: 4.12
    -- In an untyped function call no TypeArgs are permitted, Args can be any argument list, no contextual
    -- types are provided for the argument expressions, and the result is always of type Any.
    if self:isUntypedFunctionCall(funcType, apparentType, core.Len(callSignatures), numConstructSignatures) then
        -- The unknownType indicates that an error already occurred (and was reported).  No
        -- need to report another error in this case.
        if not self:isErrorType(funcType) and node:TypeArguments() ~= nil then
            self:error(node, diagnostics.Untyped_function_calls_may_not_accept_type_arguments)
        end
        return self:resolveUntypedCall(node)
    end
    -- If FuncExpr's apparent type(section 3.8.1) is a function type, the call is a typed function call.
    -- TypeScript employs overload resolution in typed function calls in order to support functions
    -- with multiple call signatures.
    if core.Len(callSignatures) == 0 then
        if numConstructSignatures ~= 0 then
            self:error(node, diagnostics.Value_of_type_0_is_not_callable_Did_you_mean_to_include_new, self:TypeToString(funcType))
        else
            local relatedInformation = nil
            if core.Len(node:Arguments()) == 1 then
                local text = ast.GetSourceFileOfNode(node):Text()
                local options = { stopAfterLineBreak = true }
                if stringutil.IsLineBreak(string.byte(text, scanner.SkipTriviaEx(text, node:Expression():End(), options))) then
                    relatedInformation = checker.createDiagnosticForNode(node:Expression(), diagnostics.Are_you_missing_a_semicolon)
                end
            end
            self:invocationError(node:Expression(), apparentType, SignatureKind.Call, relatedInformation)
        end
        return self:resolveErrorCall(node)
    end
    -- When a call to a generic function is an argument to an outer call to a generic function for which
    -- inference is in process, we have a choice to make. If the inner call relies on inferences made from
    -- its contextual type to its return type, deferring the inner call processing allows the best possible
    -- contextual type to accumulate. But if the outer call relies on inferences made from the return type of
    -- the inner call, the inner call should be processed early. There's no sure way to know which choice is
    -- right (only a full unification algorithm can determine that), so we resort to the following heuristic:
    -- If no type arguments are specified in the inner call and at least one call signature is generic and
    -- returns a function type, we choose to defer processing. This narrowly permits function composition
    -- operators to flow inferences through return types, but otherwise processes calls right away. We
    -- use the resolvingSignature singleton to indicate that we deferred processing. This result will be
    -- propagated out and eventually turned into silentNeverType (a type that is assignable to anything and
    -- from which we never make inferences).
    if checkMode & CheckMode.SkipGenericFunctions ~= 0 and core.Len(node:TypeArguments()) == 0 and core.Some(callSignatures, function(s) return self:isGenericFunctionReturningFunction(s) end) then
        self:skippedGenericFunction(node, checkMode)
        return self.resolvingSignature
    end
    return self:resolveCall(node, callSignatures, candidatesOutArray, checkMode, callChainFlags, nil)
end

function Checker:resolveNewExpression(node, candidatesOutArray, checkMode)
    local expressionType = self:checkNonNullExpression(node:Expression())
    if expressionType == self.silentNeverType then
        return self.silentNeverSignature
    end
    -- If expressionType's apparent type(section 3.8.1) is an object type with one or
    -- more construct signatures, the expression is processed in the same manner as a
    -- function call, but using the construct signatures as the initial set of candidate
    -- signatures for overload resolution. The result type of the function call becomes
    -- the result type of the operation.
    expressionType = self:getApparentType(expressionType)
    if self:isErrorType(expressionType) then
        -- Another error has already been reported
        return self:resolveErrorCall(node)
    end
    -- TS 1.0 spec: 4.11
    -- If expressionType is of type Any, Args can be any argument
    -- list and the result of the operation is of type Any.
    if checker.IsTypeAny(expressionType) then
        if core.Len(node:TypeArguments()) ~= 0 then
            self:error(node, diagnostics.Untyped_function_calls_may_not_accept_type_arguments)
        end
        return self:resolveUntypedCall(node)
    end
    -- Technically, this signatures list may be incomplete. We are taking the apparent type,
    -- but we are not including construct signatures that may have been added to the Object or
    -- Function interface, since they have none by default. This is a bit of a leap of faith
    -- that the user will not add any.
    local constructSignatures = self:getSignaturesOfType(expressionType, SignatureKind.Construct)
    if core.Len(constructSignatures) ~= 0 then
        if not self:isConstructorAccessible(node, constructSignatures[1]) then
            return self:resolveErrorCall(node)
        end
        -- If the expression is a class of abstract type, or an abstract construct signature,
        -- then it cannot be instantiated.
        -- In the case of a merged class-module or class-interface declaration,
        -- only the class declaration node will have the Abstract flag set.
        if checker.someSignature(constructSignatures, function(sig)
                return sig.flags & SignatureFlags.Abstract ~= 0
            end) then
            self:error(node, diagnostics.Cannot_create_an_instance_of_an_abstract_class)
            return self:resolveErrorCall(node)
        end
        if expressionType.symbol ~= nil then
            local valueDecl = ast.GetClassLikeDeclarationOfSymbol(expressionType.symbol)
            if valueDecl ~= nil and ast.HasModifier(valueDecl, ModifierFlags.Abstract) then
                self:error(node, diagnostics.Cannot_create_an_instance_of_an_abstract_class)
                return self:resolveErrorCall(node)
            end
        end
        return self:resolveCall(node, constructSignatures, candidatesOutArray, checkMode, SignatureFlags.None, nil)
    end
    -- If expressionType's apparent type is an object type with no construct signatures but
    -- one or more call signatures, the expression is processed as a function call. A compile-time
    -- error occurs if the result of the function call is not Void. The type of the result of the
    -- operation is Any. It is an error to have a Void this type.
    local callSignatures = self:getSignaturesOfType(expressionType, SignatureKind.Call)
    if core.Len(callSignatures) ~= 0 then
        local signature = self:resolveCall(node, callSignatures, candidatesOutArray, checkMode, SignatureFlags.None, nil)
        if not self.noImplicitAny then
            if signature.declaration ~= nil and self:getReturnTypeOfSignature(signature) ~= self.voidType then
                self:error(node, diagnostics.Only_a_void_function_can_be_called_with_the_new_keyword)
            end
            if self:getThisTypeOfSignature(signature) == self.voidType then
                self:error(node, diagnostics.A_function_that_is_called_with_the_new_keyword_cannot_have_a_this_type_that_is_void)
            end
        end
        return signature
    end
    self:invocationError(node:Expression(), expressionType, SignatureKind.Construct, nil)
    return self:resolveErrorCall(node)
end

function Checker:isConstructorAccessible(node, signature)
    if signature == nil or signature.declaration == nil then
        return true
    end
    local declaration = signature.declaration
    local modifiers = checker.getSelectedModifierFlags(declaration, ModifierFlags.NonPublicAccessibilityModifier)
    -- (1) Public constructors and (2) constructor functions are always accessible.
    if modifiers == 0 or not ast.IsConstructorDeclaration(declaration) then
        return true
    end
    local declaringClassDeclaration = ast.GetClassLikeDeclarationOfSymbol(declaration.parent:Symbol())
    local declaringClass = self:getDeclaredTypeOfSymbol(declaration.parent:Symbol())
    -- A private or protected constructor can only be instantiated within its own class (or a subclass, for protected)
    if not self:isNodeWithinClass(node, declaringClassDeclaration) then
        local containingClass = ast.GetContainingClass(node)
        if containingClass ~= nil and modifiers & ModifierFlags.Protected ~= 0 then
            local containingType = self:getDeclaredTypeOfSymbol(containingClass:Symbol())
            if self:typeHasProtectedAccessibleBase(declaration.parent:Symbol(), containingType) then
                return true
            end
        end
        if modifiers & ModifierFlags.Private ~= 0 then
            self:error(node, diagnostics.Constructor_of_class_0_is_private_and_only_accessible_within_the_class_declaration, self:TypeToString(declaringClass))
        end
        if modifiers & ModifierFlags.Protected ~= 0 then
            self:error(node, diagnostics.Constructor_of_class_0_is_protected_and_only_accessible_within_the_class_declaration, self:TypeToString(declaringClass))
        end
        return false
    end
    return true
end

function Checker:typeHasProtectedAccessibleBase(target, t)
    local baseTypes = self:getBaseTypes(self:getTargetType(t))
    if core.Len(baseTypes) == 0 then
        return false
    end
    local firstBase = baseTypes[1]
    if firstBase.flags & TypeFlags.Intersection ~= 0 then
        local types = firstBase:AsIntersectionType().types
        local mixinFlags = self:findMixins(types)
        for i1, intersectionMember in ipairs(firstBase:Types()) do
            -- We want to ignore mixin ctors
            if not mixinFlags[i1] then
                if intersectionMember.objectFlags & (ObjectFlags.Class | ObjectFlags.Interface) ~= 0 then
                    if intersectionMember.symbol == target then
                        return true
                    end
                    if self:typeHasProtectedAccessibleBase(target, intersectionMember) then
                        return true
                    end
                end
            end
        end
        return false
    end
    if firstBase.symbol == target then
        return true
    end
    return self:typeHasProtectedAccessibleBase(target, firstBase)
end

function checker.someSignature(signatures, f)
    for _, sig in ipairs(signatures or {}) do
        if sig.composite ~= nil and sig.composite.isUnion and core.Some(sig.composite.signatures, f) or sig.composite == nil and f(sig) then
            return true
        end
    end
    return false
end

function Checker:resolveTaggedTemplateExpression(node, candidatesOutArray, checkMode)
    local tag = node:AsTaggedTemplateExpression().tag
    local tagType = self:checkExpression(tag)
    local apparentType = self:getApparentType(tagType)
    if self:isErrorType(apparentType) then
        -- Another error has already been reported
        return self:resolveErrorCall(node)
    end
    local callSignatures = self:getSignaturesOfType(apparentType, SignatureKind.Call)
    local numConstructSignatures = core.Len(self:getSignaturesOfType(apparentType, SignatureKind.Construct))
    if self:isUntypedFunctionCall(tagType, apparentType, core.Len(callSignatures), numConstructSignatures) then
        return self:resolveUntypedCall(node)
    end
    if core.Len(callSignatures) == 0 then
        if ast.IsArrayLiteralExpression(node.parent) then
            self:error(tag, diagnostics.It_is_likely_that_you_are_missing_a_comma_to_separate_these_two_template_expressions_They_form_a_tagged_template_expression_which_cannot_be_invoked)
            return self:resolveErrorCall(node)
        end
        self:invocationError(tag, apparentType, SignatureKind.Call, nil)
        return self:resolveErrorCall(node)
    end
    return self:resolveCall(node, callSignatures, candidatesOutArray, checkMode, SignatureFlags.None, nil)
end

function Checker:resolveDecorator(node, candidatesOutArray, checkMode)
    if not ast.CanHaveDecorators(node.parent) then
        return self:resolveErrorCall(node)
    end
    local funcType = self:checkExpression(node:Expression())
    local apparentType = self:getApparentType(funcType)
    if self:isErrorType(apparentType) then
        return self:resolveErrorCall(node)
    end
    local callSignatures = self:getSignaturesOfType(apparentType, SignatureKind.Call)
    local numConstructSignatures = core.Len(self:getSignaturesOfType(apparentType, SignatureKind.Construct))
    if self:isUntypedFunctionCall(funcType, apparentType, core.Len(callSignatures), numConstructSignatures) then
        return self:resolveUntypedCall(node)
    end
    if self:isPotentiallyUncalledDecorator(node, callSignatures) and not ast.IsParenthesizedExpression(node:Expression()) then
        local nodeStr = scanner.GetTextOfNode(node:Expression())
        self:error(node, diagnostics.X_0_accepts_too_few_arguments_to_be_used_as_a_decorator_here_Did_you_mean_to_call_it_first_and_write_0, nodeStr)
        return self:resolveErrorCall(node)
    end
    local headMessage = self:getDiagnosticHeadMessageForDecoratorResolution(node)
    if core.Len(callSignatures) == 0 then
        local diag = ast.NewDiagnosticChain(self:invocationErrorDetails(node:Expression(), apparentType, SignatureKind.Call), headMessage)
        diag = self:addDiagnostic(diag)
        self:invocationErrorRecovery(apparentType, SignatureKind.Call, diag)
        return self:resolveErrorCall(node)
    end
    local decoratorSignature = self:getDecoratorCallSignature(node)
    if decoratorSignature == nil then
        return self:resolveErrorCall(node)
    end
    return self:resolveCall(node, callSignatures, candidatesOutArray, checkMode, SignatureFlags.None, headMessage)
end

-- Sometimes, we have a decorator that could accept zero arguments,
-- but is receiving too many arguments as part of the decorator invocation.
-- In those cases, a user may have meant to *call* the expression before using it as a decorator.
function Checker:isPotentiallyUncalledDecorator(decorator, signatures)
    return core.Len(signatures) ~= 0 and core.Every(signatures, function(sig)
        return sig.minArgumentCount == 0 and not checker.signatureHasRestParameter(sig) and core.Len(sig.parameters) < self:getDecoratorArgumentCount(decorator, sig)
    end)
end

-- Gets the localized diagnostic head message to use for errors when resolving a decorator as a call expression.
function Checker:getDiagnosticHeadMessageForDecoratorResolution(node)
    local k = node.parent.kind
    if k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return diagnostics.Unable_to_resolve_signature_of_class_decorator_when_called_as_an_expression
    elseif k == Kind.Parameter then
        return diagnostics.Unable_to_resolve_signature_of_parameter_decorator_when_called_as_an_expression
    elseif k == Kind.PropertyDeclaration then
        return diagnostics.Unable_to_resolve_signature_of_property_decorator_when_called_as_an_expression
    elseif k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
        return diagnostics.Unable_to_resolve_signature_of_method_decorator_when_called_as_an_expression
    end
    error("Unhandled case in getDiagnosticHeadMessageForDecoratorResolution", 0)
end

function Checker:resolveInstanceofExpression(node, candidatesOutArray, checkMode)
    -- if rightType is an object type with a custom `[Symbol.hasInstance]` method, then it is potentially
    -- valid on the right-hand side of the `instanceof` operator. This allows normal `object` types to
    -- participate in `instanceof`, as per Step 2 of https://tc39.es/ecma262/#sec-instanceofoperator.
    local right = node:AsBinaryExpression().right
    local rightType = self:checkExpression(right)
    if not checker.IsTypeAny(rightType) then
        local hasInstanceMethodType = self:getSymbolHasInstanceMethodOfObjectType(rightType)
        if hasInstanceMethodType ~= nil then
            local apparentType = self:getApparentType(hasInstanceMethodType)
            if self:isErrorType(apparentType) then
                return self:resolveErrorCall(node)
            end
            local callSignatures = self:getSignaturesOfType(apparentType, SignatureKind.Call)
            local constructSignatures = self:getSignaturesOfType(apparentType, SignatureKind.Construct)
            if self:isUntypedFunctionCall(hasInstanceMethodType, apparentType, core.Len(callSignatures), core.Len(constructSignatures)) then
                return self:resolveUntypedCall(node)
            end
            if core.Len(callSignatures) ~= 0 then
                return self:resolveCall(node, callSignatures, candidatesOutArray, checkMode, SignatureFlags.None, nil)
            end
        elseif not (self:typeHasCallOrConstructSignatures(rightType) or self:isTypeSubtypeOf(rightType, self.globalFunctionType)) then
            self:error(right, diagnostics.The_right_hand_side_of_an_instanceof_expression_must_be_either_of_type_any_a_class_function_or_other_type_assignable_to_the_Function_interface_type_or_an_object_type_with_a_Symbol_hasInstance_method)
            return self:resolveErrorCall(node)
        end
    end
    -- fall back to a default signature
    return self.anySignature
end

checker.defineStruct("CallState", nil, { argCheckMode = 0, isSingleNonGenericCandidate = false, signatureHelpTrailingComma = false })

-- Replaces the contents of a Go `*[]T` out-parameter (a Lua array) with values.
local function setOutArray(out, values)
    for i = #out, 1, -1 do
        out[i] = nil
    end
    for i, v in ipairs(values or {}) do
        out[i] = v
    end
end

function Checker:resolveCall(node, signatures, candidatesOutArray, checkMode, callChainFlags, headMessage)
    local isTaggedTemplate = node.kind == Kind.TaggedTemplateExpression
    local isDecorator = node.kind == Kind.Decorator
    local isJsxOpeningOrSelfClosingElement = ast.IsJsxOpeningLikeElement(node)
    local isInstanceof = node.kind == Kind.BinaryExpression
    local reportErrors = not self.isInferencePartiallyBlocked and candidatesOutArray == nil
    local s = checker.CallState_new()
    s.node = node
    if not isDecorator and not isInstanceof and not checker.isSuperCall(node) and not ast.IsJsxOpeningFragment(node) then
        s.typeArguments = node:TypeArguments()
        -- We already perform checking on the type arguments on the class declaration itself.
        if isTaggedTemplate or isJsxOpeningOrSelfClosingElement or node:Expression().kind ~= Kind.SuperKeyword then
            self:checkSourceElements(s.typeArguments)
        end
    end
    s.candidates = self:reorderCandidates(signatures, callChainFlags)
    if candidatesOutArray ~= nil then
        setOutArray(candidatesOutArray, s.candidates)
        -- Go's *candidatesOutArray aliases s.candidates, so later in-place updates
        -- (s.candidates[i] = checkCandidate, getCandidateForOverloadFailure) are visible to the caller.
        s.candidates = candidatesOutArray
    end

    if #s.candidates == 0 then
        -- In Strada we would error here, but no known repro doesn't have at least
        -- one other error in this codepath. Just return instead. See #54442
        return self.unknownSignature
    end

    s.args = self:getEffectiveCallArguments(node)
    -- The excludeArgument array contains true for each context sensitive argument (an argument
    -- is context sensitive it is susceptible to a one-time permanent contextual typing).
    --
    -- The idea is that we will perform type argument inference & assignability checking once
    -- without using the susceptible parameters that are functions, and once more for those
    -- parameters, contextually typing each as we go along.
    --
    -- For a tagged template, then the first argument be 'undefined' if necessary because it
    -- represents a TemplateStringsArray.
    --
    -- For a decorator, no arguments are susceptible to contextual typing due to the fact
    -- decorators are applied to a declaration by the emitter, and not to an expression.
    s.isSingleNonGenericCandidate = #s.candidates == 1 and core.Len(s.candidates[1].typeParameters) == 0
    if not isDecorator and not s.isSingleNonGenericCandidate and core.Some(s.args, function(a) return self:isContextSensitive(a) end) then
        s.argCheckMode = CheckMode.SkipContextSensitive
    else
        s.argCheckMode = CheckMode.Normal
    end
    -- The following variables are captured and modified by calls to chooseOverload.
    -- If overload resolution or type argument inference fails, we want to report the
    -- best error possible. The best error is one which says that an argument was not
    -- assignable to a parameter. This implies that everything else about the overload
    -- was fine. So if there is any overload that is only incorrect because of an
    -- argument, we will report an error on that one.
    --
    --     function foo(s: string): void;
    --     function foo(n: number): void; // Report argument error on this overload
    --     function foo(): void;
    --     foo(true);
    --
    -- If none of the overloads even made it that far, there are two possibilities.
    -- There was a problem with type arguments for some overload, in which case
    -- report an error on that. Or none of the overloads even had correct arity,
    -- in which case give an arity error.
    --
    --     function foo<T extends string>(x: T): void; // Report type argument error
    --     function foo(): void;
    --     foo<number>(0);
    --
    -- If we are in signature help, a trailing comma indicates that we intend to provide another argument,
    -- so we will only accept overloads with arity at least 1 higher than the current number of provided arguments.
    s.signatureHelpTrailingComma = checkMode & CheckMode.IsForSignatureHelp ~= 0 and ast.IsCallExpression(node) and node:ArgumentList():HasTrailingComma()
    -- Section 4.12.1:
    -- if the candidate list contains one or more signatures for which the type of each argument
    -- expression is a subtype of each corresponding parameter type, the return type of the first
    -- of those signatures becomes the return type of the function call.
    -- Otherwise, the return type of the first signature in the candidate list becomes the return
    -- type of the function call.
    --
    -- Whether the call is an error is determined by assignability of the arguments. The subtype pass
    -- is just important for choosing the best signature. So in the case where there is only one
    -- signature, the subtype pass is useless. So skipping it is an optimization.
    local result = nil
    if #s.candidates > 1 then
        result = self:chooseOverload(s, self.subtypeRelation)
    end
    if result == nil then
        result = self:chooseOverload(s, self.assignableRelation)
    end
    if result ~= nil then
        return result
    end
    result = self:getCandidateForOverloadFailure(s.node, s.candidates, s.args, candidatesOutArray ~= nil, checkMode)
    -- Preemptively cache the result; getResolvedSignature will do this after we return, but
    -- we need to ensure that the result is present for the error checks below so that if
    -- this signature is encountered again, we handle the circularity (rather than producing a
    -- different result which may produce no errors and assert). Callers of getResolvedSignature
    -- don't hit this issue because they only observe this result after it's had a chance to
    -- be cached, but the error reporting code below executes before getResolvedSignature sets
    -- resolvedSignature.
    self.signatureLinks:Get(node).resolvedSignature = result
    -- No signatures were applicable. Now report errors based on the last applicable signature with
    -- no arguments excluded from assignability checks.
    -- If candidate is undefined, it means that no candidates had a suitable arity. In that case,
    -- skip the checkApplicableSignature check.
    if reportErrors then
        -- If the call expression is a synthetic call to a `[Symbol.hasInstance]` method then we will produce a head
        -- message when reporting diagnostics that explains how we got to `right[Symbol.hasInstance](left)` from
        -- `left instanceof right`, as it pertains to "Argument" related messages reported for the call.
        if headMessage == nil and isInstanceof then
            headMessage = diagnostics.The_left_hand_side_of_an_instanceof_expression_must_be_assignable_to_the_first_argument_of_the_right_hand_side_s_Symbol_hasInstance_method
        end
        self:reportCallResolutionErrors(node, s, signatures, headMessage)
    end
    return result
end

function Checker:reorderCandidates(signatures, callChainFlags)
    local lastParent = nil
    local lastSymbol = nil
    local index = 0
    local cutoffIndex = 0
    local spliceIndex
    local specializedIndex = -1
    local result = {}
    for _, signature in ipairs(signatures or {}) do
        local symbol = nil
        local parent = nil
        if signature.declaration ~= nil then
            symbol = self:getSymbolOfDeclaration(signature.declaration)
            parent = signature.declaration.parent
        end
        if lastSymbol == nil or symbol == lastSymbol then
            if lastParent ~= nil and parent == lastParent then
                index = index + 1
            else
                lastParent = parent
                index = cutoffIndex
            end
        else
            -- current declaration belongs to a different symbol
            -- set cutoffIndex so re-orderings in the future won't change result set from 0 to cutoffIndex
            index = #result
            cutoffIndex = #result
            lastParent = parent
        end
        lastSymbol = symbol
        -- specialized signatures always need to be placed before non-specialized signatures regardless
        -- of the cutoff position; see GH#1133
        if checker.signatureHasLiteralTypes(signature) then
            specializedIndex = specializedIndex + 1
            spliceIndex = specializedIndex
            -- The cutoff index always needs to be greater than or equal to the specialized signature index
            -- in order to prevent non-specialized signatures from being added before a specialized
            -- signature.
            cutoffIndex = cutoffIndex + 1
        else
            spliceIndex = index
        end
        if callChainFlags ~= 0 then
            signature = self:getOptionalCallSignature(signature, callChainFlags)
        end
        if spliceIndex > #result then
            error("slices.Insert: index out of range", 0)
        end
        table.insert(result, spliceIndex + 1, signature)
    end
    return result
end

function checker.signatureHasLiteralTypes(s)
    return s.flags & SignatureFlags.HasLiteralTypes ~= 0
end

function Checker:getOptionalCallSignature(signature, callChainFlags)
    if signature.flags & SignatureFlags.CallChainFlags == callChainFlags then
        return signature
    end
    local key = checker.CachedSignatureKey(signature, core.IfElse(callChainFlags == SignatureFlags.IsInnerCallChain, checker.SignatureKeyInner, checker.SignatureKeyOuter))
    local cached = self.cachedSignatures[key]
    if cached ~= nil then
        return cached
    end
    local result = self:cloneSignature(signature)
    result.flags = result.flags | callChainFlags
    self.cachedSignatures[key] = result
    return result
end

function Checker:chooseOverload(s, relation)
    s.candidatesForArgumentError = nil
    s.candidateForArgumentArityError = nil
    s.candidateForTypeArgumentError = nil
    if s.isSingleNonGenericCandidate then
        local candidate = s.candidates[1]
        if core.Len(s.typeArguments) ~= 0 or not self:hasCorrectArity(s.node, s.args, candidate, s.signatureHelpTrailingComma) then
            return nil
        end
        if not self:isSignatureApplicable(s.node, s.args, candidate, relation, CheckMode.Normal, false --[[reportErrors]], nil --[[diagnosticOutput]]) then
            s.candidatesForArgumentError = { candidate }
            return nil
        end
        return candidate
    end
    for candidateIndex1, candidate in ipairs(s.candidates) do
        if not self:hasCorrectTypeArgumentArity(candidate, s.typeArguments) or not self:hasCorrectArity(s.node, s.args, candidate, s.signatureHelpTrailingComma) then
            goto continue
        end
        do
            local checkCandidate
            local inferenceContext = nil
            if core.Len(candidate.typeParameters) ~= 0 then
                local typeArgumentTypes
                if core.Len(s.typeArguments) ~= 0 then
                    typeArgumentTypes = self:checkTypeArguments(candidate, s.typeArguments, false --[[reportErrors]], nil)
                    if typeArgumentTypes == nil then
                        s.candidateForTypeArgumentError = candidate
                        goto continue
                    end
                else
                    inferenceContext = self:newInferenceContext(candidate.typeParameters, candidate, core.IfElse(ast.IsInJSFile(s.node), checker.InferenceFlags.AnyDefault, checker.InferenceFlags.None) --[[flags]], nil)
                    typeArgumentTypes = self:inferTypeArguments(s.node, candidate, s.args, s.argCheckMode | CheckMode.SkipGenericFunctions, inferenceContext)
                    if inferenceContext.flags & checker.InferenceFlags.SkippedGenericFunction ~= 0 then
                        s.argCheckMode = s.argCheckMode | CheckMode.SkipGenericFunctions
                    end
                end
                local inferredTypeParameters = nil
                if inferenceContext ~= nil then
                    inferredTypeParameters = inferenceContext.inferredTypeParameters
                end
                checkCandidate = self:getSignatureInstantiation(candidate, typeArgumentTypes, ast.IsInJSFile(candidate.declaration), inferredTypeParameters)
                -- If the original signature has a generic rest type, instantiation may produce a
                -- signature with different arity and we need to perform another arity check.
                if self:getNonArrayRestType(candidate) ~= nil and not self:hasCorrectArity(s.node, s.args, checkCandidate, s.signatureHelpTrailingComma) then
                    s.candidateForArgumentArityError = checkCandidate
                    goto continue
                end
            else
                checkCandidate = candidate
            end
            if not self:isSignatureApplicable(s.node, s.args, checkCandidate, relation, s.argCheckMode, false --[[reportErrors]], nil --[[diagnosticOutput]]) then
                -- Give preference to error candidates that have no rest parameters (as they are more specific)
                s.candidatesForArgumentError = core.Append(s.candidatesForArgumentError, checkCandidate)
                goto continue
            end
            if s.argCheckMode ~= 0 then
                -- If one or more context sensitive arguments were excluded, we start including
                -- them now (and keeping do so for any subsequent candidates) and perform a second
                -- round of type inference and applicability checking for this particular candidate.
                s.argCheckMode = CheckMode.Normal
                if inferenceContext ~= nil then
                    local typeArgumentTypes = self:inferTypeArguments(s.node, candidate, s.args, s.argCheckMode, inferenceContext)
                    checkCandidate = self:getSignatureInstantiation(candidate, typeArgumentTypes, ast.IsInJSFile(candidate.declaration), inferenceContext.inferredTypeParameters)
                    -- If the original signature has a generic rest type, instantiation may produce a
                    -- signature with different arity and we need to perform another arity check.
                    if self:getNonArrayRestType(candidate) ~= nil and not self:hasCorrectArity(s.node, s.args, checkCandidate, s.signatureHelpTrailingComma) then
                        s.candidateForArgumentArityError = checkCandidate
                        goto continue
                    end
                end
                if not self:isSignatureApplicable(s.node, s.args, checkCandidate, relation, s.argCheckMode, false --[[reportErrors]], nil --[[diagnosticOutput]]) then
                    -- Give preference to error candidates that have no rest parameters (as they are more specific)
                    s.candidatesForArgumentError = core.Append(s.candidatesForArgumentError, checkCandidate)
                    goto continue
                end
            end
            s.candidates[candidateIndex1] = checkCandidate
            return checkCandidate
        end
        ::continue::
    end
    return nil
end

function Checker:hasCorrectArity(node, args, signature, signatureHelpTrailingComma)
    if ast.IsJsxOpeningFragment(node) then
        return true
    end
    local argCount = 0
    local callIsIncomplete = false
    -- In incomplete call we want to be lenient when we have too few arguments
    local effectiveParameterCount = self:getParameterCount(signature)
    local effectiveMinimumArguments = self:getMinArgumentCount(signature)
    if ast.IsTaggedTemplateExpression(node) then
        argCount = core.Len(args)
        local template = node:AsTaggedTemplateExpression().template
        if ast.IsTemplateExpression(template) then
            -- If a tagged template expression lacks a tail literal, the call is incomplete.
            -- Specifically, a template only can end in a TemplateTail or a Missing literal.
            local lastSpan = core.LastOrNil(template:AsTemplateExpression().templateSpans.nodes)
            -- we should always have at least one span.
            callIsIncomplete = ast.NodeIsMissing(lastSpan:AsTemplateSpan().literal) or ast.IsUnterminatedLiteral(lastSpan:AsTemplateSpan().literal)
        else
            -- If the template didn't end in a backtick, or its beginning occurred right prior to EOF,
            -- then this might actually turn out to be a TemplateHead in the future;
            -- so we consider the call to be incomplete.
            callIsIncomplete = ast.IsUnterminatedLiteral(template)
        end
    elseif ast.IsDecorator(node) then
        argCount = self:getDecoratorArgumentCount(node, signature)
    elseif ast.IsBinaryExpression(node) then
        argCount = 1
    elseif ast.IsJsxOpeningLikeElement(node) then
        callIsIncomplete = node:Attributes():End() == node:End()
        if callIsIncomplete then
            return true
        end
        argCount = core.IfElse(effectiveMinimumArguments == 0, core.Len(args), 1)
        effectiveParameterCount = core.IfElse(core.Len(args) == 0, effectiveParameterCount, 1) -- class may have argumentless ctor functions - still resolve ctor and compare vs props member type
        effectiveMinimumArguments = math.min(effectiveMinimumArguments, 1) -- sfc may specify context argument - handled by framework and not typechecked
    elseif ast.IsNewExpression(node) and node:ArgumentList() == nil then
        -- This only happens when we have something of the form: 'new C'
        return self:getMinArgumentCount(signature) == 0
    else
        if signatureHelpTrailingComma then
            argCount = core.Len(args) + 1
        else
            argCount = core.Len(args)
        end
        -- If we are missing the close parenthesis, the call is incomplete.
        callIsIncomplete = node:ArgumentList():End() == node:End()
        -- If a spread argument is present, check that it corresponds to a rest parameter or at least that it's in the valid range.
        local spreadArgIndex = self:getSpreadArgumentIndex(args)
        if spreadArgIndex >= 0 then
            return spreadArgIndex >= self:getMinArgumentCount(signature) and (self:hasEffectiveRestParameter(signature) or spreadArgIndex < self:getParameterCount(signature))
        end
    end
    -- Too many arguments implies incorrect arity.
    if not self:hasEffectiveRestParameter(signature) and argCount > effectiveParameterCount then
        return false
    end
    -- If the call is incomplete, we should skip the lower bound check.
    -- JSX signatures can have extra parameters provided by the library which we don't check
    if callIsIncomplete or argCount >= effectiveMinimumArguments then
        return true
    end
    for i = argCount, effectiveMinimumArguments - 1 do
        local t = self:getTypeAtPosition(signature, i)
        if self:filterType(t, checker.acceptsVoid).flags & TypeFlags.Never ~= 0 then
            return false
        end
    end
    return true
end

function checker.acceptsVoid(t)
    return t.flags & TypeFlags.Void ~= 0
end

function Checker:getDecoratorArgumentCount(node, signature)
    if core.Tristate_IsTrue(self.compilerOptions.experimentalDecorators) then
        return self:getLegacyDecoratorArgumentCount(node, signature)
    end
    return math.min(math.max(self:getParameterCount(signature), 1), 2)
end

--[[
 * Returns the argument count for a decorator node that works like a function invocation.
]]
function Checker:getLegacyDecoratorArgumentCount(node, signature)
    local k = node.parent.kind
    if k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return 1
    elseif k == Kind.PropertyDeclaration then
        if ast.HasAccessorModifier(node.parent) then
            return 3
        end
        return 2
    elseif k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
        -- For decorators with only two parameters we supply only two arguments
        if core.Len(signature.parameters) <= 2 then
            return 2
        end
        return 3
    elseif k == Kind.Parameter then
        return 3
    end
    error("Unhandled case in getLegacyDecoratorArgumentCount", 0)
end

function Checker:hasCorrectTypeArgumentArity(signature, typeArguments)
    -- If the user supplied type arguments, but the number of type arguments does not match
    -- the declared number of type parameters, the call has an incorrect arity.
    local numTypeParameters = core.Len(signature.typeParameters)
    local minTypeArgumentCount = self:getMinTypeArgumentCount(signature.typeParameters)
    return core.Len(typeArguments) == 0 or core.Len(typeArguments) >= minTypeArgumentCount and core.Len(typeArguments) <= numTypeParameters
end

function Checker:checkTypeArguments(signature, typeArgumentNodes, reportErrors, headMessage)
    local isJavaScript = ast.IsInJSFile(signature.declaration)
    local typeParameters = signature.typeParameters
    local typeArgumentTypes = self:fillMissingTypeArguments(core.Map(typeArgumentNodes, function(n) return self:getTypeFromTypeNode(n) end), typeParameters, self:getMinTypeArgumentCount(typeParameters), isJavaScript)
    local mapper = nil
    for i = 0, core.Len(typeArgumentNodes) - 1 do
        debug.Assert(typeParameters[i + 1] ~= nil, "Should not call checkTypeArguments with too many type arguments")
        local constraint = self:getConstraintOfTypeParameter(typeParameters[i + 1])
        if constraint ~= nil then
            local typeArgumentHeadMessage = core.OrElse(headMessage, diagnostics.Type_0_does_not_satisfy_the_constraint_1)
            if mapper == nil then
                mapper = checker.newTypeMapper(typeParameters, typeArgumentTypes)
            end
            local typeArgument = typeArgumentTypes[i + 1]
            local errorNode = nil
            if reportErrors then
                errorNode = typeArgumentNodes[i + 1]
            end
            local diags = {}
            if not self:checkTypeAssignableToEx(typeArgument, self:getTypeWithThisArgument(self:instantiateType(constraint, mapper), typeArgument, false), errorNode, typeArgumentHeadMessage, diags) then
                if #diags ~= 0 then
                    local diagnostic = diags[1]
                    if headMessage ~= nil then
                        diagnostic = ast.NewDiagnosticChain(diagnostic, diagnostics.Type_0_does_not_satisfy_the_constraint_1)
                    end
                    self:addDiagnostic(diagnostic)
                end
                return nil
            end
        end
    end
    return typeArgumentTypes
end

-- diagnosticOutput (Go *[]*ast.Diagnostic) is nil or a Lua array that callees append to.
function Checker:isSignatureApplicable(node, args, signature, relation, checkMode, reportErrors, diagnosticOutput)
    if ast.IsJsxCallLike(node) then
        return self:checkApplicableSignatureForJsxCallLikeElement(node, signature, relation, checkMode, reportErrors, diagnosticOutput)
    end
    local thisType = self:getThisTypeOfSignature(signature)
    if thisType ~= nil and thisType ~= self.voidType and not (ast.IsNewExpression(node) or ast.IsCallExpression(node) and ast.IsSuperProperty(node:Expression())) then
        -- If the called expression is not of the form `x.f` or `x["f"]`, then sourceType = voidType
        -- If the signature's 'this' type is voidType, then the check is skipped -- anything is compatible.
        -- If the expression is a new expression or super call expression, then the check is skipped.
        local thisArgumentNode = self:getThisArgumentOfCall(node)
        local thisArgumentType = self:getThisArgumentType(thisArgumentNode)
        local errorNode = nil
        if reportErrors then
            errorNode = thisArgumentNode
            if errorNode == nil then
                errorNode = node
            end
        end
        local headMessage = diagnostics.The_this_context_of_type_0_is_not_assignable_to_method_s_this_of_type_1
        if not self:checkTypeRelatedToEx(thisArgumentType, thisType, relation, errorNode, headMessage, diagnosticOutput) then
            return false
        end
    end
    local headMessage = diagnostics.Argument_of_type_0_is_not_assignable_to_parameter_of_type_1
    local restType = self:getNonArrayRestType(signature)
    local argCount
    if restType ~= nil then
        argCount = math.min(self:getParameterCount(signature) - 1, core.Len(args))
    else
        argCount = core.Len(args)
    end
    for i = 0, argCount - 1 do
        local arg = args[i + 1]
        if not ast.IsOmittedExpression(arg) then
            local paramType = self:getTypeAtPosition(signature, i)
            local argType = self:checkExpressionWithContextualType(arg, paramType, nil --[[inferenceContext]], checkMode)
            -- If one or more arguments are still excluded (as indicated by CheckMode.SkipContextSensitive),
            -- we obtain the regular type of any object literal arguments because we may not have inferred complete
            -- parameter types yet and therefore excess property checks may yield false positives (see #17041).
            local checkArgType
            if checkMode & CheckMode.SkipContextSensitive ~= 0 then
                checkArgType = self:getRegularTypeOfObjectLiteral(argType)
            else
                checkArgType = argType
            end
            local effectiveCheckArgumentNode = self:getEffectiveCheckNode(arg)
            if not self:checkTypeRelatedToAndOptionallyElaborate(checkArgType, paramType, relation, core.IfElse(reportErrors, effectiveCheckArgumentNode, nil), effectiveCheckArgumentNode, headMessage, diagnosticOutput) then
                self:maybeAddMissingAwaitInfo(arg, checkArgType, paramType, relation, reportErrors, diagnosticOutput)
                return false
            end
        end
    end
    if restType ~= nil then
        local spreadType = self:getSpreadArgumentType(args, argCount, core.Len(args), restType, nil --[[context]], checkMode)
        local restArgCount = core.Len(args) - argCount
        local errorNode = nil
        if reportErrors then
            if restArgCount == 0 then
                errorNode = node
            elseif restArgCount == 1 then
                errorNode = self:getEffectiveCheckNode(args[argCount + 1])
            else
                errorNode = self:createSyntheticExpression(node, spreadType, false, nil)
                errorNode.loc = core.NewTextRange(args[argCount + 1]:Pos(), args[core.Len(args)]:End())
            end
        end
        if not self:checkTypeRelatedToEx(spreadType, restType, relation, errorNode, headMessage, diagnosticOutput) then
            self:maybeAddMissingAwaitInfo(errorNode, spreadType, restType, relation, reportErrors, diagnosticOutput)
            return false
        end
    end
    return true
end

function Checker:maybeAddMissingAwaitInfo(errorNode, source, target, relation, reportErrors, diagnosticOutput)
    if errorNode ~= nil and reportErrors and diagnosticOutput ~= nil and #diagnosticOutput ~= 0 then
        -- Bail if target is Promise-like---something else is wrong
        if self:getAwaitedTypeOfPromise(target) ~= nil then
            return
        end
        local awaitedTypeOfSource = self:getAwaitedTypeOfPromise(source)
        if awaitedTypeOfSource ~= nil and self:isTypeRelatedTo(awaitedTypeOfSource, target, relation) then
            diagnosticOutput[1]:AddRelatedInfo(checker.NewDiagnosticForNode(errorNode, diagnostics.Did_you_forget_to_use_await))
        end
    end
end

-- Returns the `this` argument node in calls like `x.f(...)` and `x[f](...)`. `nil` otherwise.
function Checker:getThisArgumentOfCall(node)
    if ast.IsBinaryExpression(node) then
        return node:AsBinaryExpression().right
    end
    local expression = nil
    if ast.IsCallExpression(node) then
        expression = node:Expression()
    elseif ast.IsTaggedTemplateExpression(node) then
        expression = node:AsTaggedTemplateExpression().tag
    elseif ast.IsDecorator(node) and not self.legacyDecorators then
        expression = node:Expression()
    end
    if expression ~= nil then
        local callee = ast.SkipOuterExpressions(expression, ast.OuterExpressionKinds.OEKAll)
        if ast.IsAccessExpression(callee) then
            return callee:Expression()
        end
    end
    return nil
end

function Checker:getThisArgumentType(node)
    if node == nil then
        return self.voidType
    end
    local thisArgumentType = self:checkExpression(node)
    if ast.IsOptionalChainRoot(node.parent) then
        return self:GetNonNullableType(thisArgumentType)
    elseif ast.IsOptionalChain(node.parent) then
        return self:removeOptionalTypeMarker(thisArgumentType)
    end
    return thisArgumentType
end

function Checker:getEffectiveCheckNode(argument)
    local OEK = ast.OuterExpressionKinds
    local flags = core.IfElse(
        ast.IsInJSFile(argument),
        OEK.OEKParentheses | OEK.OEKSatisfies | OEK.OEKExcludeJSDocTypeAssertion,
        OEK.OEKParentheses | OEK.OEKSatisfies
    )
    return ast.SkipOuterExpressions(argument, flags)
end

function Checker:inferTypeArguments(node, signature, args, checkMode, context)
    if ast.IsJsxOpeningLikeElement(node) then
        return self:inferJsxTypeArguments(node, signature, checkMode, context)
    end
    -- If a contextual type is available, infer from that type to the return type of the call expression. For
    -- example, given a 'function wrap<T, U>(cb: (x: T) => U): (x: T) => U' and a call expression
    -- 'let f: (x: string) => number = wrap(s => s.length)', we infer from the declared type of 'f' to the
    -- return type of 'wrap'.
    if not ast.IsDecorator(node) and not ast.IsBinaryExpression(node) then
        local skipBindingPatterns = core.Every(signature.typeParameters, function(p) return self:getDefaultFromTypeParameter(p) ~= nil end)
        local contextualType = self:getContextualType(node, core.IfElse(skipBindingPatterns, ContextFlags.SkipBindingPatterns, ContextFlags.None))
        if contextualType ~= nil then
            local inferenceTargetType = self:getReturnTypeOfSignature(signature)
            if self.couldContainTypeVariables(inferenceTargetType) then
                local outerContext = self:getInferenceContext(node)
                local isFromBindingPattern = not skipBindingPatterns and self:getContextualType(node, ContextFlags.SkipBindingPatterns) ~= contextualType
                -- A return type inference from a binding pattern can be used in instantiating the contextual
                -- type of an argument later in inference, but cannot stand on its own as the final return type.
                -- It is incorporated into `context.returnMapper` which is used in `instantiateContextualType`,
                -- but doesn't need to go into `context.inferences`. This allows a an array binding pattern to
                -- produce a tuple for `T` in
                --   declare function f<T>(cb: () => T): T;
                --   const [e1, e2, e3] = f(() => [1, "hi", true]);
                -- but does not produce any inference for `T` in
                --   declare function f<T>(): T;
                --   const [e1, e2, e3] = f();
                if not isFromBindingPattern then
                    -- We clone the inference context to avoid disturbing a resolution in progress for an
                    -- outer call expression. Effectively we just want a snapshot of whatever has been
                    -- inferred for any outer call expression so far.
                    local outerMapper = self:getMapperFromContext(self:cloneInferenceContext(outerContext, checker.InferenceFlags.NoDefault))
                    local instantiatedType = self:instantiateType(contextualType, outerMapper)
                    -- If the contextual type is a generic function type with a single call signature, we
                    -- instantiate the type with its own type parameters and type arguments. This ensures that
                    -- the type parameters are not erased to type any during type inference such that they can
                    -- be inferred as actual types from the contextual type. For example:
                    --   declare function arrayMap<T, U>(f: (x: T) => U): (a: T[]) => U[];
                    --   const boxElements: <A>(a: A[]) => { value: A }[] = arrayMap(value => ({ value }));
                    -- Above, the type of the 'value' parameter is inferred to be 'A'.
                    local contextualSignature = self:getSingleCallSignature(instantiatedType)
                    local inferenceSourceType
                    if contextualSignature ~= nil and core.Len(contextualSignature.typeParameters) ~= 0 then
                        inferenceSourceType = self:getOrCreateTypeFromSignature(self:getSignatureInstantiationWithoutFillingInTypeArguments(contextualSignature, contextualSignature.typeParameters))
                    else
                        inferenceSourceType = instantiatedType
                    end
                    -- Inferences made from return types have lower priority than all other inferences.
                    self:inferTypes(context.inferences, inferenceSourceType, inferenceTargetType, InferencePriority.ReturnType, false)
                end
                -- Create a type mapper for instantiating generic contextual types using the inferences made
                -- from the return type. We need a separate inference pass here because (a) instantiation of
                -- the source type uses the outer context's return mapper (which excludes inferences made from
                -- outer arguments), and (b) we don't want any further inferences going into this context.
                -- We use `createOuterReturnMapper` to ensure that all occurrences of outer type parameters are
                -- replaced with inferences produced from the outer return type or preceding outer arguments.
                -- This protects against circular inferences, i.e. avoiding situations where inferences reference
                -- type parameters for which the inferences are being made.
                local returnContext = self:newInferenceContext(signature.typeParameters, signature, context.flags, nil)
                local outerReturnMapper = nil
                if outerContext ~= nil then
                    outerReturnMapper = self:createOuterReturnMapper(outerContext)
                end
                local returnSourceType = self:instantiateType(contextualType, outerReturnMapper)
                self:inferTypes(returnContext.inferences, returnSourceType, inferenceTargetType, InferencePriority.None, false)
                if core.Some(returnContext.inferences, function(info) return checker.hasInferenceCandidates(info) end) then
                    context.returnMapper = self:getMapperFromContext(self:cloneInferredPartOfContext(returnContext))
                else
                    context.returnMapper = nil
                end
            end
        end
    end
    local restType = self:getNonArrayRestType(signature)
    local argCount = core.Len(args)
    if restType ~= nil then
        argCount = math.min(self:getParameterCount(signature) - 1, argCount)
    end
    if restType ~= nil and restType.flags & TypeFlags.TypeParameter ~= 0 then
        local info = core.Find(context.inferences, function(info) return info.typeParameter == restType end)
        if info ~= nil then
            if core.FindIndex(core.Slice(args, argCount, core.Len(args)), function(a) return checker.isSpreadArgument(a) end) < 0 then
                info.impliedArity = core.Len(args) - argCount
            end
        end
    end
    local thisType = self:getThisTypeOfSignature(signature)
    if thisType ~= nil and self.couldContainTypeVariables(thisType) then
        local thisArgumentNode = self:getThisArgumentOfCall(node)
        self:inferTypes(context.inferences, self:getThisArgumentType(thisArgumentNode), thisType, InferencePriority.None, false)
    end
    for i = 0, argCount - 1 do
        local arg = args[i + 1]
        if arg.kind ~= Kind.OmittedExpression then
            local paramType = self:getTypeAtPosition(signature, i)
            if self.couldContainTypeVariables(paramType) then
                local argType = self:checkExpressionWithContextualType(arg, paramType, context, checkMode)
                self:inferTypes(context.inferences, argType, paramType, InferencePriority.None, false)
            end
        end
    end
    if restType ~= nil and self.couldContainTypeVariables(restType) then
        local spreadType = self:getSpreadArgumentType(args, argCount, core.Len(args), restType, context, checkMode)
        self:inferTypes(context.inferences, spreadType, restType, InferencePriority.None, false)
    end
    return self:getInferredTypes(context)
end

-- No signature was applicable. We have already reported the errors for the invalid signature.
function Checker:getCandidateForOverloadFailure(node, candidates, args, hasCandidatesOutArray, checkMode)
    -- Else should not have called this.
    self:checkNodeDeferred(node)
    -- Normally we will combine overloads. Skip this if they have type parameters since that's hard to combine.
    -- Don't do this if there is a `candidatesOutArray`,
    -- because then we want the chosen best candidate to be one of the overloads, not a combination.
    if hasCandidatesOutArray or #candidates == 1 or core.Some(candidates, function(s) return core.Len(s.typeParameters) ~= 0 end) then
        return self:pickLongestCandidateSignature(node, candidates, args, checkMode)
    end
    return self:createUnionOfSignaturesForOverloadFailure(candidates)
end

function Checker:pickLongestCandidateSignature(node, candidates, args, checkMode)
    -- Pick the longest signature. This way we can get a contextual type for cases like:
    --     declare function f(a: { xa: number; xb: number; }, b: number);
    --     f({ |
    -- Also, use explicitly-supplied type arguments if they are provided, so we can get a contextual signature in cases like:
    --     declare function f<T>(k: keyof T);
    --     f<Foo>("
    local argCount = core.Len(args)
    if self.apparentArgumentCount ~= nil then
        argCount = self.apparentArgumentCount
    end
    local bestIndex = self:getLongestCandidateIndex(candidates, argCount)
    local candidate = candidates[bestIndex + 1]
    local typeParameters = candidate.typeParameters
    if core.Len(typeParameters) == 0 then
        return candidate
    end
    local typeArgumentNodes = nil
    if self:callLikeExpressionMayHaveTypeArguments(node) then
        typeArgumentNodes = node:TypeArguments()
    end
    local instantiated
    if core.Len(typeArgumentNodes) ~= 0 then
        instantiated = self:createSignatureInstantiation(candidate, self:getTypeArgumentsFromNodes(typeArgumentNodes, typeParameters))
    else
        instantiated = self:inferSignatureInstantiationForOverloadFailure(node, typeParameters, candidate, args, checkMode)
    end
    candidates[bestIndex + 1] = instantiated
    return instantiated
end

function Checker:getLongestCandidateIndex(candidates, argsCount)
    local maxParamsIndex = -1
    local maxParams = -1
    for i1, candidate in ipairs(candidates) do
        local i = i1 - 1
        local paramCount = self:getParameterCount(candidate)
        if self:hasEffectiveRestParameter(candidate) or paramCount >= argsCount then
            return i
        end
        if paramCount > maxParams then
            maxParams = paramCount
            maxParamsIndex = i
        end
    end
    return maxParamsIndex
end

function Checker:getTypeArgumentsFromNodes(typeArgumentNodes, typeParameters)
    if core.Len(typeArgumentNodes) > core.Len(typeParameters) then
        typeArgumentNodes = core.Slice(typeArgumentNodes, 0, core.Len(typeParameters))
    end
    local typeArguments = core.Map(typeArgumentNodes, function(n) return self:getTypeFromTypeNode(n) end) or {}
    while #typeArguments < core.Len(typeParameters) do
        local t = self:getDefaultFromTypeParameter(typeParameters[#typeArguments + 1])
        if t == nil then
            t = self:getConstraintOfTypeParameter(typeParameters[#typeArguments + 1])
            if t == nil then
                t = self.unknownType
            end
        end
        typeArguments[#typeArguments + 1] = t
    end
    return typeArguments
end

function Checker:inferSignatureInstantiationForOverloadFailure(node, typeParameters, candidate, args, checkMode)
    local inferenceContext = self:newInferenceContext(typeParameters, candidate, core.IfElse(ast.IsInJSFile(node), checker.InferenceFlags.AnyDefault, checker.InferenceFlags.None), nil)
    local typeArgumentTypes = self:inferTypeArguments(node, candidate, args, checkMode | CheckMode.SkipContextSensitive | CheckMode.SkipGenericFunctions, inferenceContext)
    return self:createSignatureInstantiation(candidate, typeArgumentTypes)
end

function Checker:createUnionOfSignaturesForOverloadFailure(candidates)
    local thisParameters = core.MapNonNil(candidates, function(s) return s.thisParameter end)
    local thisParameter = nil
    if core.Len(thisParameters) ~= 0 then
        thisParameter = self:createCombinedSymbolFromTypes(thisParameters, core.Map(thisParameters, function(p) return self:getTypeOfParameter(p) end))
    end
    local minArgumentCount, maxNonRestParam = checker.minAndMax(candidates, checker.getNonRestParameterCount)
    local parameters = {}
    for i = 0, maxNonRestParam - 1 do
        local symbols = core.MapNonNil(candidates, function(s)
            if checker.signatureHasRestParameter(s) then
                if i < core.Len(s.parameters) - 1 then
                    return s.parameters[i + 1]
                end
                return core.LastOrNil(s.parameters)
            end
            if i < core.Len(s.parameters) then
                return s.parameters[i + 1]
            end
            return nil
        end)
        parameters[#parameters + 1] = self:createCombinedSymbolFromTypes(symbols, core.MapNonNil(candidates, function(s) return self:tryGetTypeAtPosition(s, i) end))
    end
    local restParameterSymbols = core.MapNonNil(candidates, function(s)
        if checker.signatureHasRestParameter(s) then
            return core.LastOrNil(s.parameters)
        end
        return nil
    end)
    local flags = SignatureFlags.IsSignatureCandidateForOverloadFailure
    if core.Len(restParameterSymbols) ~= 0 then
        local t = self:createArrayType(self:getUnionTypeEx(core.MapNonNil(candidates, function(s) return self:tryGetRestTypeOfSignature(s) end), UnionReduction.Subtype, nil, nil))
        parameters[#parameters + 1] = self:createCombinedSymbolForOverloadFailure(restParameterSymbols, t)
        flags = flags | SignatureFlags.HasRestParameter
    end
    if core.Some(candidates, checker.signatureHasLiteralTypes) then
        flags = flags | SignatureFlags.HasLiteralTypes
    end
    return self:newSignature(flags, candidates[1].declaration, nil, thisParameter, parameters, self:getIntersectionType(core.Map(candidates, function(s) return self:getReturnTypeOfSignature(s) end)), nil, minArgumentCount)
end

function Checker:createCombinedSymbolFromTypes(sources, types)
    return self:createCombinedSymbolForOverloadFailure(sources, self:getUnionTypeEx(types, UnionReduction.Subtype, nil, nil))
end

function Checker:createCombinedSymbolForOverloadFailure(sources, t)
    -- This function is currently only used for erroneous overloads, so it's good enough to just use the first source.
    return self:createSymbolWithType(core.FirstOrNil(sources), t)
end

function Checker:getRestTypeOfSignature(signature)
    return core.OrElse(self:tryGetRestTypeOfSignature(signature), self.anyType)
end

function Checker:tryGetRestTypeOfSignature(signature)
    if not checker.signatureHasRestParameter(signature) then
        return nil
    end
    local restType = self:getTypeOfSymbol(signature.parameters[#signature.parameters])
    if checker.isTupleType(restType) then
        restType = self:getRestTypeOfTupleType(restType)
        if restType == nil then
            return nil
        end
    end
    return self:getIndexTypeOfType(restType, self.numberType)
end

function Checker:reportCallResolutionErrors(node, s, signatures, headMessage)
    if core.Len(s.candidatesForArgumentError) ~= 0 then
        local last = s.candidatesForArgumentError[#s.candidatesForArgumentError]
        local diags = {}
        self:isSignatureApplicable(s.node, s.args, last, self.assignableRelation, CheckMode.Normal, true --[[reportErrors]], diags)
        for _, diagnostic in ipairs(diags) do
            if #s.candidatesForArgumentError > 1 then
                diagnostic = ast.NewDiagnosticChain(diagnostic, diagnostics.The_last_overload_gave_the_following_error)
                diagnostic = ast.NewDiagnosticChain(diagnostic, diagnostics.No_overload_matches_this_call)
            end
            if headMessage ~= nil then
                diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
            end
            if last.declaration ~= nil and #s.candidatesForArgumentError > 1 then
                diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(last.declaration, diagnostics.The_last_overload_is_declared_here))
            end
            self:addImplementationSuccessElaboration(s, last, diagnostic)
            self:addDiagnostic(diagnostic)
        end
    elseif s.candidateForArgumentArityError ~= nil then
        self:addDiagnostic(self:getArgumentArityError(s.node, { s.candidateForArgumentArityError }, s.args, headMessage))
    elseif s.candidateForTypeArgumentError ~= nil then
        self:checkTypeArguments(s.candidateForTypeArgumentError, s.node:TypeArguments(), true --[[reportErrors]], headMessage)
    elseif not ast.IsJsxOpeningFragment(node) then
        local signaturesWithCorrectTypeArgumentArity = core.Filter(signatures, function(sig)
            return self:hasCorrectTypeArgumentArity(sig, s.typeArguments)
        end)
        if core.Len(signaturesWithCorrectTypeArgumentArity) == 0 then
            self:addDiagnostic(self:getTypeArgumentArityError(s.node, signatures, s.typeArguments, headMessage))
        else
            self:addDiagnostic(self:getArgumentArityError(s.node, signaturesWithCorrectTypeArgumentArity, s.args, headMessage))
        end
    end
end

function Checker:addImplementationSuccessElaboration(s, failed, diagnostic)
    if failed.declaration ~= nil and failed.declaration:Symbol() ~= nil then
        local declarations = failed.declaration:Symbol().declarations
        if core.Len(declarations) > 1 then
            local implementation = core.Find(declarations, function(d)
                return ast.IsFunctionLikeDeclaration(d) and ast.NodeIsPresent(d:Body())
            end)
            if implementation ~= nil then
                local candidate = self:getSignatureFromDeclaration(implementation)
                local localState = checker.CallState_new(s) -- Go: localState := *s
                localState.candidates = { candidate }
                localState.isSingleNonGenericCandidate = core.Len(candidate.typeParameters) == 0
                if self:chooseOverload(localState, self.assignableRelation) ~= nil then
                    diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(implementation, diagnostics.The_call_would_have_succeeded_against_this_implementation_but_implementation_signatures_of_overloads_are_not_externally_visible))
                end
            end
        end
    end
end

function Checker:getArgumentArityError(node, signatures, args, headMessage)
    local spreadIndex = self:getSpreadArgumentIndex(args)
    if spreadIndex > -1 then
        return checker.NewDiagnosticForNode(args[spreadIndex + 1], diagnostics.A_spread_argument_must_either_have_a_tuple_type_or_be_passed_to_a_rest_parameter)
    end
    local minCount = math.maxinteger -- smallest parameter count
    local maxCount = math.mininteger -- largest parameter count
    local maxBelow = math.mininteger -- largest parameter count that is smaller than the number of arguments
    local minAbove = math.maxinteger -- smallest parameter count that is larger than the number of arguments
    local closestSignature = nil
    for _, sig in ipairs(signatures) do
        local minParameter = self:getMinArgumentCount(sig)
        local maxParameter = self:getParameterCount(sig)
        -- smallest/largest parameter counts
        if minParameter < minCount then
            minCount = minParameter
            closestSignature = sig
        end
        maxCount = math.max(maxCount, maxParameter)
        -- shortest parameter count *longer than the call*/longest parameter count *shorter than the call*
        if minParameter < core.Len(args) and minParameter > maxBelow then
            maxBelow = minParameter
        end
        if core.Len(args) < maxParameter and maxParameter < minAbove then
            minAbove = maxParameter
        end
    end
    local hasRestParameter = core.Some(signatures, function(sig) return self:hasEffectiveRestParameter(sig) end)
    local parameterRange
    if hasRestParameter then
        parameterRange = tostring(minCount)
    elseif minCount < maxCount then
        parameterRange = tostring(minCount) .. "-" .. tostring(maxCount)
    else
        parameterRange = tostring(minCount)
    end
    local isVoidPromiseError = not hasRestParameter and parameterRange == "1" and core.Len(args) == 0 and self:isPromiseResolveArityError(node)
    local errorNode = checker.getErrorNodeForCallNode(node)
    if isVoidPromiseError and ast.IsInJSFile(node) then
        return checker.NewDiagnosticForNode(errorNode, diagnostics.Expected_1_argument_but_got_0_new_Promise_needs_a_JSDoc_hint_to_produce_a_resolve_that_can_be_called_without_arguments)
    end
    local message
    if ast.IsDecorator(node) then
        if hasRestParameter then
            message = diagnostics.The_runtime_will_invoke_the_decorator_with_1_arguments_but_the_decorator_expects_at_least_0
        else
            message = diagnostics.The_runtime_will_invoke_the_decorator_with_1_arguments_but_the_decorator_expects_0
        end
    elseif hasRestParameter then
        message = diagnostics.Expected_at_least_0_arguments_but_got_1
    elseif isVoidPromiseError then
        message = diagnostics.Expected_0_arguments_but_got_1_Did_you_forget_to_include_void_in_your_type_argument_to_Promise
    else
        message = diagnostics.Expected_0_arguments_but_got_1
    end
    if minCount < core.Len(args) and core.Len(args) < maxCount then
        -- between min and max, but with no matching overload
        local diagnostic = checker.NewDiagnosticForNode(errorNode, diagnostics.No_overload_expects_0_arguments_but_overloads_do_exist_that_expect_either_1_or_2_arguments, core.Len(args), maxBelow, minAbove)
        if headMessage ~= nil then
            diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
        end
        return diagnostic
    elseif core.Len(args) < minCount then
        -- too short: put the error span on the call expression, not any of the args
        local diagnostic = checker.NewDiagnosticForNode(errorNode, message, parameterRange, core.Len(args))
        if headMessage ~= nil then
            diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
        end
        local parameter = nil
        if closestSignature ~= nil and closestSignature.declaration ~= nil then
            parameter = core.ElementOrNil(closestSignature.declaration:Parameters(), core.Len(args) + core.IfElse(closestSignature.thisParameter ~= nil, 1, 0))
        end
        if parameter ~= nil then
            local related
            if ast.IsBindingPattern(parameter:Name()) then
                related = checker.NewDiagnosticForNode(parameter, diagnostics.An_argument_matching_this_binding_pattern_was_not_provided)
            elseif checker.isRestParameter(parameter) then
                related = checker.NewDiagnosticForNode(parameter, diagnostics.Arguments_for_the_rest_parameter_0_were_not_provided, parameter:Name():Text())
            else
                related = checker.NewDiagnosticForNode(parameter, diagnostics.An_argument_for_0_was_not_provided, parameter:Name():Text())
            end
            diagnostic:AddRelatedInfo(related)
        end
        return diagnostic
    else
        -- Guard against out-of-bounds access when maxCount >= len(args).
        -- This can happen when we reach this fallback error path but the argument
        -- count actually matches the parameter count (e.g., due to trailing commas
        -- causing signature resolution to fail for other reasons).
        if maxCount >= core.Len(args) then
            local diagnostic = checker.NewDiagnosticForNode(errorNode, message, parameterRange, core.Len(args))
            if headMessage ~= nil then
                diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
            end
            return diagnostic
        end
        local sourceFile = ast.GetSourceFileOfNode(node)
        local pos = args[maxCount + 1]:Pos()
        local end_ = args[core.Len(args)]:End()
        if end_ == pos then
            end_ = end_ + 1
        end
        pos = scanner.SkipTrivia(sourceFile:Text(), pos)
        if end_ < pos then
            end_ = pos
        end
        local diagnostic = ast.NewDiagnostic(sourceFile, core.NewTextRange(pos, end_), message, parameterRange, core.Len(args))
        if headMessage ~= nil then
            diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
        end
        return diagnostic
    end
end

function Checker:isPromiseResolveArityError(node)
    if not ast.IsCallExpression(node) or not ast.IsIdentifier(node:Expression()) then
        return false
    end
    local symbol = self.resolveName(node:Expression(), node:Expression():Text(), SymbolFlags.Value, nil --[[nameNotFoundMessage]], false --[[isUse]], false)
    if symbol == nil then
        return false
    end
    local decl = symbol.valueDeclaration
    if decl == nil or not ast.IsParameterDeclaration(decl) or not ast.IsFunctionExpressionOrArrowFunction(decl.parent) or not ast.IsNewExpression(decl.parent.parent) or not ast.IsIdentifier(decl.parent.parent:Expression()) then
        return false
    end
    local globalPromiseSymbol = self.getGlobalPromiseConstructorSymbolOrNil()
    if globalPromiseSymbol == nil then
        return false
    end
    local constructorSymbol = self:getResolvedSymbol(decl.parent.parent:Expression())
    return constructorSymbol == globalPromiseSymbol
end

function checker.getErrorNodeForCallNode(node)
    if ast.IsCallExpression(node) then
        node = node:Expression()
        if ast.IsPropertyAccessExpression(node) then
            node = node:Name()
        end
    end
    return node
end

function Checker:getTypeArgumentArityError(node, signatures, typeArguments, headMessage)
    local diagnostic
    local argCount = core.Len(typeArguments)
    local sourceFile = ast.GetSourceFileOfNode(node)
    local typeArgumentList = node:TypeArgumentList()
    local loc = core.NewTextRange(scanner.SkipTrivia(sourceFile:Text(), typeArgumentList.loc:Pos()), typeArgumentList.loc:End())
    if #signatures == 1 then
        -- No overloads exist
        local sig = signatures[1]
        local minCount = self:getMinTypeArgumentCount(sig.typeParameters)
        local maxCount = core.Len(sig.typeParameters)
        local expected = tostring(minCount)
        if minCount < maxCount then
            expected = expected .. "-" .. tostring(maxCount)
        end
        diagnostic = ast.NewDiagnostic(sourceFile, loc, diagnostics.Expected_0_type_arguments_but_got_1, expected, argCount)
    else
        -- Overloads exist
        local belowArgCount = math.mininteger
        local aboveArgCount = math.maxinteger
        for _, sig in ipairs(signatures) do
            local minCount = self:getMinTypeArgumentCount(sig.typeParameters)
            local maxCount = core.Len(sig.typeParameters)
            if minCount > argCount then
                aboveArgCount = math.min(aboveArgCount, minCount)
            elseif maxCount < argCount then
                belowArgCount = math.max(belowArgCount, maxCount)
            end
        end
        if belowArgCount ~= math.mininteger and aboveArgCount ~= math.maxinteger then
            diagnostic = ast.NewDiagnostic(sourceFile, loc, diagnostics.No_overload_expects_0_type_arguments_but_overloads_do_exist_that_expect_either_1_or_2_type_arguments, argCount, belowArgCount, aboveArgCount)
        else
            diagnostic = ast.NewDiagnostic(sourceFile, loc, diagnostics.Expected_0_type_arguments_but_got_1, core.IfElse(belowArgCount == math.mininteger, aboveArgCount, belowArgCount), argCount)
        end
    end
    if headMessage ~= nil then
        diagnostic = ast.NewDiagnosticChain(diagnostic, headMessage)
    end
    return diagnostic
end

function Checker:reportCannotInvokePossiblyNullOrUndefinedError(node, facts)
    self:error(node, core.IfElse(facts & TypeFacts.IsUndefined ~= 0,
        core.IfElse(facts & TypeFacts.IsNull ~= 0,
            diagnostics.Cannot_invoke_an_object_which_is_possibly_null_or_undefined,
            diagnostics.Cannot_invoke_an_object_which_is_possibly_undefined),
        diagnostics.Cannot_invoke_an_object_which_is_possibly_null))
end

function Checker:resolveUntypedCall(node)
    if self:callLikeExpressionMayHaveTypeArguments(node) then
        -- Check type arguments even though we will give an error that untyped calls may not accept type arguments.
        -- This gets us diagnostics for the type arguments and marks them as referenced.
        self:checkSourceElements(node:TypeArguments())
    end
    local k = node.kind
    if k == Kind.TaggedTemplateExpression then
        self:checkExpression(node:AsTaggedTemplateExpression().template)
    elseif k == Kind.JsxOpeningElement or k == Kind.JsxSelfClosingElement then
        self:checkExpression(node:Attributes())
    elseif k == Kind.BinaryExpression then
        self:checkExpression(node:AsBinaryExpression().left)
    elseif k == Kind.CallExpression or k == Kind.NewExpression then
        for _, argument in ipairs(node:Arguments() or {}) do
            self:checkExpression(argument)
        end
    end
    return self.anySignature
end

function Checker:resolveErrorCall(node)
    self:resolveUntypedCall(node)
    return self.unknownSignature
end

--[[
 * TS 1.0 spec: 4.12
 * If FuncExpr is of type Any, or of an object type that has no call or construct signatures
 * but is a subtype of the Function interface, the call is an untyped function call.
]]
function Checker:isUntypedFunctionCall(funcType, apparentFuncType, numCallSignatures, numConstructSignatures)
    -- We exclude union types because we may have a union of function types that happen to have no common signatures.
    return checker.IsTypeAny(funcType) or checker.IsTypeAny(apparentFuncType) and funcType.flags & TypeFlags.TypeParameter ~= 0 or
        numCallSignatures == 0 and numConstructSignatures == 0 and apparentFuncType.flags & TypeFlags.Union == 0 and
        self:getReducedType(apparentFuncType).flags & TypeFlags.Never == 0 and self:isTypeAssignableTo(funcType, self.globalFunctionType)
end

function Checker:invocationErrorDetails(errorTarget, apparentType, kind)
    local diagnostic = nil
    local isCall = kind == SignatureKind.Call
    local awaitedType = self:getAwaitedType(apparentType)
    local maybeMissingAwait = awaitedType ~= nil and core.Len(self:getSignaturesOfType(awaitedType, kind)) > 0
    local target = errorTarget
    if ast.IsPropertyAccessExpression(errorTarget) and ast.IsCallExpression(errorTarget.parent) then
        target = errorTarget:Name()
    end
    if apparentType.flags & TypeFlags.Union ~= 0 then
        local types = apparentType:Types()
        local hasSignatures = false
        for _, constituent in ipairs(types) do
            local signatures = self:getSignaturesOfType(constituent, kind)
            if core.Len(signatures) ~= 0 then
                hasSignatures = true
                if diagnostic ~= nil then
                    -- Bail early if we already have an error, no chance of "No constituent of type is callable"
                    break
                end
            else
                -- Error on the first non callable constituent only
                if diagnostic == nil then
                    diagnostic = checker.NewDiagnosticForNode(target, core.IfElse(isCall, diagnostics.Type_0_has_no_call_signatures, diagnostics.Type_0_has_no_construct_signatures), self:TypeToString(constituent))
                    diagnostic = checker.NewDiagnosticChainForNode(diagnostic, target, core.IfElse(isCall, diagnostics.Not_all_constituents_of_type_0_are_callable, diagnostics.Not_all_constituents_of_type_0_are_constructable), self:TypeToString(apparentType))
                end
                if hasSignatures then
                    -- Bail early if we already found a signature, no chance of "No constituent of type is callable"
                    break
                end
            end
        end
        if not hasSignatures then
            diagnostic = checker.NewDiagnosticForNode(target, core.IfElse(isCall, diagnostics.No_constituent_of_type_0_is_callable, diagnostics.No_constituent_of_type_0_is_constructable), self:TypeToString(apparentType))
        end
        if diagnostic == nil then
            diagnostic = checker.NewDiagnosticForNode(target, core.IfElse(isCall, diagnostics.Each_member_of_the_union_type_0_has_signatures_but_none_of_those_signatures_are_compatible_with_each_other, diagnostics.Each_member_of_the_union_type_0_has_construct_signatures_but_none_of_those_signatures_are_compatible_with_each_other), self:TypeToString(apparentType))
        end
    else
        diagnostic = checker.NewDiagnosticChainForNode(diagnostic, target, core.IfElse(isCall, diagnostics.Type_0_has_no_call_signatures, diagnostics.Type_0_has_no_construct_signatures), self:TypeToString(apparentType))
    end
    local headMessage = core.IfElse(isCall, diagnostics.This_expression_is_not_callable, diagnostics.This_expression_is_not_constructable)
    -- Diagnose get accessors incorrectly called as functions
    if ast.IsCallExpression(errorTarget.parent) and core.Len(errorTarget.parent:Arguments()) == 0 then
        local resolvedSymbol = self:getResolvedSymbolOrNil(errorTarget)
        if resolvedSymbol ~= nil and resolvedSymbol.flags & SymbolFlags.GetAccessor ~= 0 then
            headMessage = diagnostics.This_expression_is_not_callable_because_it_is_a_get_accessor_Did_you_mean_to_use_it_without
        end
    end
    diagnostic = checker.NewDiagnosticChainForNode(diagnostic, target, headMessage)
    if maybeMissingAwait then
        diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(errorTarget, diagnostics.Did_you_forget_to_use_await))
    end
    return diagnostic
end

function Checker:invocationError(errorTarget, apparentType, kind, relatedInformation)
    local diagnostic = self:invocationErrorDetails(errorTarget, apparentType, kind)
    if relatedInformation ~= nil then
        diagnostic:AddRelatedInfo(relatedInformation)
    end
    diagnostic = self:addDiagnostic(diagnostic)
    self:invocationErrorRecovery(apparentType, kind, diagnostic)
end

function Checker:invocationErrorRecovery(apparentType, kind, diagnostic)
    if apparentType.symbol == nil then
        return
    end
    local importNode = self.exportTypeLinks:Get(apparentType.symbol).originatingImport
    -- Create a diagnostic on the originating import if possible onto which we can attach a quickfix
    --  An import call expression cannot be rewritten into another form to correct the error - the only solution is to use `.default` at the use-site
    if importNode ~= nil and not ast.IsImportCall(importNode) then
        local sigs = self:getSignaturesOfType(self:getTypeOfSymbol(self.exportTypeLinks:Get(apparentType.symbol).target), kind)
        if core.Len(sigs) == 0 then
            return
        end
        diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(importNode, diagnostics.Type_originates_at_this_import_A_namespace_style_import_cannot_be_called_or_constructed_and_will_cause_a_failure_at_runtime_Consider_using_a_default_import_or_import_require_here_instead))
    end
end

function Checker:isGenericFunctionReturningFunction(signature)
    return core.Len(signature.typeParameters) ~= 0 and self:isFunctionType(self:getReturnTypeOfSignature(signature))
end

function Checker:skippedGenericFunction(node, checkMode)
    if checkMode & CheckMode.Inferential ~= 0 then
        -- We have skipped a generic function during inferential typing. Obtain the inference context and
        -- indicate this has occurred such that we know a second pass of inference is be needed.
        local context = self:getInferenceContext(node)
        context.flags = context.flags | checker.InferenceFlags.SkippedGenericFunction
    end
end

function Checker:checkTaggedTemplateExpression(node)
    if not self:checkGrammarTaggedTemplateChain(node:AsTaggedTemplateExpression()) then
        self:checkGrammarTypeArguments(node, node:TypeArgumentList())
    end
    local signature = self:getResolvedSignature(node, nil, CheckMode.Normal)
    self:checkDeprecatedSignature(signature, node)
    return self:getReturnTypeOfSignature(signature)
end

function Checker:checkParenthesizedExpression(node, checkMode)
    return self:checkExpressionEx(node:Expression(), checkMode)
end

function Checker:checkClassExpression(node)
    self:checkClassLikeDeclaration(node)
    self:checkNodeDeferred(node)
    self:checkClassExpressionExternalHelpers(node)
    return self:getTypeOfSymbol(self:getSymbolOfDeclaration(node))
end

function Checker:getFirstTransformableStaticClassElement(node)
    local willTransformStaticElementsOfDecoratedClass = not self.legacyDecorators and
        self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators and
        ast.ClassOrConstructorParameterIsDecorated(false, node)
    local willTransformPrivateElementsOrClassStaticBlocks = self.languageVersion < checker.LanguageFeatureMinimumTarget.PrivateNamesAndClassStaticBlocks or self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators
    local willTransformInitializers = not self.emitStandardClassFields
    if willTransformStaticElementsOfDecoratedClass or willTransformPrivateElementsOrClassStaticBlocks then
        for _, member in ipairs(node:Members() or {}) do
            if willTransformStaticElementsOfDecoratedClass and ast.ClassElementOrClassElementParameterIsDecorated(false, member, node) then
                local firstDecorator = core.FirstOrNil(node:Decorators())
                if firstDecorator ~= nil then
                    return firstDecorator
                end
                return node
            elseif willTransformPrivateElementsOrClassStaticBlocks then
                if ast.IsClassStaticBlockDeclaration(member) then
                    return member
                elseif ast.IsStatic(member) and
                    (ast.IsPrivateIdentifierClassElementDeclaration(member) or
                        willTransformInitializers and ast.IsInitializedProperty(member)) then
                    return member
                end
            end
        end
    end
    return nil
end

function Checker:checkClassExpressionExternalHelpers(node)
    if node:Name() ~= nil then
        return
    end
    local parent = checker.walkUpOuterExpressions(node)
    if not ast.IsNamedEvaluationSource(parent) then
        return
    end

    local willTransformESDecorators = not self.legacyDecorators and self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators
    local location
    if willTransformESDecorators and ast.ClassOrConstructorParameterIsDecorated(false, node) then
        location = node
        local firstDecorator = core.FirstOrNil(node:Decorators())
        if firstDecorator ~= nil then
            location = firstDecorator
        end
    else
        location = self:getFirstTransformableStaticClassElement(node)
    end

    if location ~= nil then
        self:checkExternalEmitHelpers(location, checker.ExternalEmitHelpers.SetFunctionName)
        if (ast.IsPropertyAssignment(parent) or ast.IsPropertyDeclaration(parent) or ast.IsBindingElement(parent)) and ast.IsComputedPropertyName(parent:Name()) then
            self:checkExternalEmitHelpers(location, checker.ExternalEmitHelpers.PropKey)
        end
    end
end

function Checker:checkClassExpressionDeferred(node)
    self:checkSourceElements(node:Members())
    self:registerForUnusedIdentifiersCheck(node)
end

function Checker:checkFunctionExpressionOrObjectLiteralMethod(node, checkMode)
    self:checkNodeDeferred(node)
    if ast.IsFunctionExpression(node) then
        self:checkCollisionsForDeclarationName(node, node:Name())
    end
    if checkMode & CheckMode.SkipContextSensitive ~= 0 and self:isContextSensitive(node) then
        -- Skip parameters, return signature with return type that retains noncontextual parts so inferences can still be drawn in an early stage
        if node:Type() == nil and not ast.HasContextSensitiveParameters(node) then
            -- Return plain anyFunctionType if there is no possibility we'll make inferences from the return type
            local contextualSignature = self:getContextualSignature(node)
            if contextualSignature ~= nil and self.couldContainTypeVariables(self:getReturnTypeOfSignature(contextualSignature)) then
                local cached = self.contextFreeTypes[node]
                if cached ~= nil then
                    return cached
                end
                local returnType = self:getReturnTypeFromBody(node, checkMode)
                local returnOnlySignature = self:newSignature(SignatureFlags.IsNonInferrable, nil, nil --[[typeParameters]], nil --[[thisParameter]], nil, returnType, nil --[[resolvedTypePredicate]], 0)
                local returnOnlyType = self:newAnonymousType(node:Symbol(), nil, { returnOnlySignature }, nil, nil)
                returnOnlyType.objectFlags = returnOnlyType.objectFlags | ObjectFlags.NonInferrableType
                self.contextFreeTypes[node] = returnOnlyType
                return returnOnlyType
            end
        end
        return self.anyFunctionType
    end
    -- Grammar checking
    local hasGrammarError = self:checkGrammarFunctionLikeDeclaration(node)
    if not hasGrammarError and ast.IsFunctionExpression(node) then
        self:checkGrammarForGenerator(node)
    end
    if node:FunctionLikeData().fullSignature ~= nil then
        if self:getContextualCallSignature(self:getTypeFromTypeNode(node:FunctionLikeData().fullSignature), node) == nil then
            self:error(node:FunctionLikeData().fullSignature, diagnostics.A_JSDoc_type_tag_on_a_function_must_have_a_signature_with_the_correct_number_of_arguments)
        end
    end
    self:contextuallyCheckFunctionExpressionOrObjectLiteralMethod(node, checkMode)
    return self:getTypeOfSymbol(self:getSymbolOfDeclaration(node))
end

function Checker:contextuallyCheckFunctionExpressionOrObjectLiteralMethod(node, checkMode)
    local links = self.nodeLinks:Get(node)
    -- Check if function expression is contextually typed and assign parameter types if so.
    if links.flags & NodeCheckFlags.ContextChecked == 0 then
        local contextualSignature = self:getContextualSignature(node)
        -- If a type check is started at a function expression that is an argument of a function call, obtaining the
        -- contextual type may recursively get back to here during overload resolution of the call. If so, we will have
        -- already assigned contextual types.
        if links.flags & NodeCheckFlags.ContextChecked == 0 then
            links.flags = links.flags | NodeCheckFlags.ContextChecked
            local signature = core.FirstOrNil(self:getSignaturesOfType(self:getTypeOfSymbol(self:getSymbolOfDeclaration(node)), SignatureKind.Call))
            if signature == nil then
                return
            end
            if self:isContextSensitive(node) then
                if contextualSignature ~= nil then
                    local inferenceContext = self:getInferenceContext(node)
                    local instantiatedContextualSignature = nil
                    if checkMode & CheckMode.Inferential ~= 0 then
                        self:inferFromAnnotatedParametersAndReturn(signature, contextualSignature, inferenceContext)
                        local restType = self:getEffectiveRestType(contextualSignature)
                        if restType ~= nil and restType.flags & TypeFlags.TypeParameter ~= 0 then
                            instantiatedContextualSignature = self:instantiateSignature(contextualSignature, inferenceContext.nonFixingMapper)
                        end
                    end
                    if instantiatedContextualSignature == nil then
                        if inferenceContext ~= nil then
                            instantiatedContextualSignature = self:instantiateSignature(contextualSignature, inferenceContext.mapper)
                        else
                            instantiatedContextualSignature = contextualSignature
                        end
                    end
                    self:assignContextualParameterTypes(signature, instantiatedContextualSignature)
                else
                    -- Force resolution of all parameter types such that the absence of a contextual type is consistently reflected.
                    self:assignNonContextualParameterTypes(signature)
                end
            elseif contextualSignature ~= nil and node:TypeParameters() == nil and core.Len(contextualSignature.parameters) > #node:Parameters() then
                local inferenceContext = self:getInferenceContext(node)
                if checkMode & CheckMode.Inferential ~= 0 then
                    self:inferFromAnnotatedParametersAndReturn(signature, contextualSignature, inferenceContext)
                end
            end
            if contextualSignature ~= nil and self:getReturnTypeFromAnnotation(node) == nil and signature.resolvedReturnType == nil then
                local returnType = self:getReturnTypeFromBody(node, checkMode)
                if signature.resolvedReturnType == nil then
                    signature.resolvedReturnType = returnType
                end
            end
            self:checkSignatureDeclaration(node)
        end
    end
end

function Checker:checkFunctionExpressionOrObjectLiteralMethodDeferred(node)
    local functionFlags = ast.GetFunctionFlags(node)
    local returnType = self:getReturnTypeFromAnnotation(node)
    self:checkAllCodePathsInNonVoidFunctionReturnOrThrow(node, returnType)
    local body = node:Body()
    if body ~= nil then
        if node:Type() == nil then
            -- There are some checks that are only performed in getReturnTypeFromBody, that may produce errors
            -- we need. An example is the noImplicitAny errors resulting from widening the return expression
            -- of a function. Because checking of function expression bodies is deferred, there was never an
            -- appropriate time to do this during the main walk of the file (see the comment at the top of
            -- checkFunctionExpressionBodies). So it must be done now.
            self:getReturnTypeOfSignature(self:getSignatureFromDeclaration(node))
        end
        if ast.IsBlock(body) then
            self:checkSourceElement(body)
        else
            -- From within an async function you can return either a non-promise value or a promise. Any
            -- Promise/A+ compatible implementation will always assimilate any foreign promise, so we
            -- should not be checking assignability of a promise to the return type. Instead, we need to
            -- check assignability of the awaited type of the expression body against the promised type of
            -- its return type annotation.
            local exprType = self:checkExpression(body)
            if returnType ~= nil then
                local returnOrPromisedType = self:unwrapReturnType(returnType, functionFlags)
                if returnOrPromisedType ~= nil then
                    self:checkReturnExpression(node, returnOrPromisedType, body, body, exprType, false)
                end
            end
        end
    end
end

function Checker:inferFromAnnotatedParametersAndReturn(sig, context, inferenceContext)
    local length = core.Len(sig.parameters) - core.IfElse(checker.signatureHasRestParameter(sig), 1, 0)
    for i = 0, length - 1 do
        local declaration = sig.parameters[i + 1].valueDeclaration
        local typeNode = declaration:Type()
        if typeNode ~= nil then
            local source = self:addOptionalityEx(self:getTypeFromTypeNode(typeNode), false --[[isProperty]], checker.isOptionalDeclaration(declaration))
            local target = self:getTypeAtPosition(context, i)
            self:inferTypes(inferenceContext.inferences, source, target, InferencePriority.None, false)
        end
    end
    local declaration = sig:Declaration()
    if declaration ~= nil then
        local returnTypeNode = declaration:Type()
        if returnTypeNode ~= nil then
            local source = self:getTypeFromTypeNode(returnTypeNode)
            local target = self:getReturnTypeOfSignature(context)
            self:inferTypes(inferenceContext.inferences, source, target, InferencePriority.None, false)
        end
    end
end

-- Return the contextual signature for a given expression node. A contextual type provides a
-- contextual signature if it has a single call signature and if that call signature is non-generic.
-- If the contextual type is a union type, get the signature from each type possible and if they are
-- all identical ignoring their return type, the result is same signature but with return type as
-- union type of return types from these signatures
function Checker:getContextualSignature(node)
    local t = self:getApparentTypeOfContextualType(node, ContextFlags.Signature)
    if t == nil then
        return nil
    end
    if t.flags & TypeFlags.Union == 0 then
        return self:getContextualCallSignature(t, node)
    end
    local signatureList = {}
    local types = t:Types()
    for _, current in ipairs(types) do
        local signature = self:getContextualCallSignature(current, node)
        if signature ~= nil then
            if #signatureList ~= 0 and self:compareSignaturesIdentical(signatureList[1], signature, false --[[partialMatch]], true --[[ignoreThisTypes]], true --[[ignoreReturnTypes]], function(s, t1) return self:compareTypesIdentical(s, t1) end) == checker.Ternary.False then
                -- Signatures aren't identical, do not use
                return nil
            end
            -- Use this signature for contextual union signature
            signatureList[#signatureList + 1] = signature
        end
    end
    if #signatureList == 0 then
        return nil
    elseif #signatureList == 1 then
        return signatureList[1]
    end
    -- Result is union of signatures collected (return type is union of return types of this signature set)
    return self:createUnionSignature(signatureList[1], signatureList)
end

function Checker:createUnionSignature(sig, unionSignatures)
    local result = self:cloneSignature(sig)
    result.composite = checker.CompositeSignature_new({ isUnion = true, signatures = unionSignatures })
    result.target = nil
    result.mapper = nil
    return result
end

-- If the given type is an object or union type with a single signature, and if that signature has at
-- least as many parameters as the given function, return the signature. Otherwise return undefined.
function Checker:getContextualCallSignature(t, node)
    local signatures = self:getSignaturesOfType(t, SignatureKind.Call)
    local applicableByArity = core.Filter(signatures, function(s) return not self:isAritySmaller(s, node) end)
    if core.Len(applicableByArity) == 1 then
        return applicableByArity[1]
    end
    return self:getIntersectedSignatures(applicableByArity)
end

function Checker:getIntersectedSignatures(signatures)
    if not self.noImplicitAny then
        return nil
    end
    local combined = nil
    for _, sig in ipairs(signatures or {}) do
        if combined == sig or combined == nil then
            combined = sig
        elseif self:compareTypeParametersIdentical(combined.typeParameters, sig.typeParameters) then
            combined = self:combineUnionOrIntersectionMemberSignatures(combined, sig, false --[[isUnion]])
        else
            return nil
        end
    end
    return combined
end

--[[ If the contextual signature has fewer parameters than the function expression, do not use it ]]
function Checker:isAritySmaller(signature, target)
    local parameters = target:Parameters()
    local targetParameterCount = 0
    while targetParameterCount < #parameters do
        local param = parameters[targetParameterCount + 1]
        if param:Initializer() ~= nil or param:QuestionToken() ~= nil or checker.hasDotDotDotToken(param) then
            break
        end
        targetParameterCount = targetParameterCount + 1
    end
    if #parameters ~= 0 and ast.IsThisParameter(parameters[1]) then
        targetParameterCount = targetParameterCount - 1
    end
    return not self:hasEffectiveRestParameter(signature) and self:getParameterCount(signature) < targetParameterCount
end

function Checker:assignContextualParameterTypes(sig, context)
    if core.Len(context.typeParameters) ~= 0 then
        if core.Len(sig.typeParameters) ~= 0 then
            -- This signature has already has a contextual inference performed and cached on it
            return
        end
        sig.typeParameters = context.typeParameters
    end
    if context.thisParameter ~= nil then
        local parameter = sig.thisParameter
        if parameter == nil or parameter.valueDeclaration ~= nil and parameter.valueDeclaration:Type() == nil then
            if parameter == nil then
                sig.thisParameter = self:createSymbolWithType(context.thisParameter, nil --[[type]])
            end
            self:assignParameterType(sig.thisParameter, self:getTypeOfSymbol(context.thisParameter))
        end
    end
    local length = core.Len(sig.parameters) - core.IfElse(checker.signatureHasRestParameter(sig), 1, 0)
    for i = 0, length - 1 do
        local parameter = sig.parameters[i + 1]
        local declaration = parameter.valueDeclaration
        if declaration:Type() == nil then
            local t = self:tryGetTypeAtPosition(context, i)
            if t ~= nil and declaration:Initializer() ~= nil then
                local initializerType = self:checkDeclarationInitializer(declaration, CheckMode.Normal, nil)
                if not self:isTypeAssignableTo(initializerType, t) then
                    initializerType = self:widenTypeInferredFromInitializer(declaration, initializerType)
                    if self:isTypeAssignableTo(t, initializerType) then
                        t = initializerType
                    end
                end
            end
            self:assignParameterType(parameter, t)
        end
    end
    if checker.signatureHasRestParameter(sig) then
        -- parameter might be a transient symbol generated by use of `arguments` in the function body.
        local parameter = core.LastOrNil(sig.parameters)
        if parameter.valueDeclaration ~= nil and parameter.valueDeclaration:Type() == nil or
            parameter.valueDeclaration == nil and parameter.checkFlags & ast.CheckFlags.DeferredType ~= 0 then
            local contextualParameterType = self:getRestTypeAtPosition(context, length, false)
            self:assignParameterType(parameter, contextualParameterType)
        end
    end
end

function Checker:assignNonContextualParameterTypes(signature)
    if signature.thisParameter ~= nil then
        self:assignParameterType(signature.thisParameter, nil)
    end
    for _, parameter in ipairs(signature.parameters or {}) do
        self:assignParameterType(parameter, nil)
    end
end

function Checker:assignParameterType(parameter, contextualType)
    local links = self.valueSymbolLinks:Get(parameter)
    if links.resolvedType ~= nil then
        return
    end
    local declaration = parameter.valueDeclaration
    local t = contextualType
    if t == nil then
        if declaration ~= nil then
            t = self:getWidenedTypeForVariableLikeDeclaration(declaration, true --[[reportErrors]])
        else
            t = self:getTypeOfSymbol(parameter)
        end
    end
    links.resolvedType = self:addOptionalityEx(t, false, declaration ~= nil and declaration:Initializer() == nil and checker.isOptionalDeclaration(declaration))
    if declaration ~= nil and not ast.IsIdentifier(declaration:Name()) then
        -- if inference didn't come up with anything but unknown, fall back to the binding pattern if present.
        if links.resolvedType == self.unknownType then
            links.resolvedType = self:getTypeFromBindingPattern(declaration:Name(), false, false)
        end
        self:assignBindingElementTypes(declaration:Name(), links.resolvedType)
    end
end

-- When contextual typing assigns a type to a parameter that contains a binding pattern, we also need to push
-- the destructured type into the contained binding elements.
function Checker:assignBindingElementTypes(pattern, parentType)
    for _, element in ipairs(pattern:Elements() or {}) do
        local name = element:Name()
        if name ~= nil then
            local t = self:getBindingElementTypeFromParentType(element, parentType, false --[[noTupleBoundsCheck]])
            if ast.IsIdentifier(name) then
                self.valueSymbolLinks:Get(self:getSymbolOfDeclaration(element)).resolvedType = t
            else
                self:assignBindingElementTypes(name, t)
            end
        end
    end
end

function Checker:checkCollisionsForDeclarationName(node, name)
    if name == nil then
        return
    end
    self:checkCollisionWithRequireExportsInGeneratedCode(node, name)
    self:checkCollisionWithGlobalObjectInGeneratedCode(node, name)
    self:checkCollisionWithGlobalPromiseInGeneratedCode(node, name)
    self:recordPotentialCollisionWithWeakMapSetInGeneratedCode(node, name)
    self:recordPotentialCollisionWithReflectInGeneratedCode(node, name)
    if ast.IsClassLike(node) then
        self:checkTypeNameIsReserved(name, diagnostics.Class_name_cannot_be_0)
        if node.flags & NodeFlags.Ambient == 0 then
            self:checkClassNameCollisionWithObject(name)
        end
    elseif ast.IsEnumDeclaration(node) then
        self:checkTypeNameIsReserved(name, diagnostics.Enum_name_cannot_be_0)
    end
end

function Checker:checkCollisionWithRequireExportsInGeneratedCode(node, name)
    -- No need to check for require or exports for ES6 modules and later
    if self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) >= core.ModuleKind.ES2015 then
        return
    end
    if name == nil or not self:needCollisionCheckForIdentifier(node, name, "require") and not self:needCollisionCheckForIdentifier(node, name, "exports") then
        return
    end
    -- Uninstantiated modules shouldnt do this check
    if ast.IsModuleDeclaration(node) and ast.GetModuleInstanceState(node) ~= ast.ModuleInstanceState.Instantiated then
        return
    end
    -- In case of variable declaration, node.parent is variable statement so look at the variable statement's parent
    local parent = ast.GetDeclarationContainer(node)
    if ast.IsSourceFile(parent) and ast.IsExternalOrCommonJSModule(parent:AsSourceFile()) then
        -- If the declaration happens to be in external module, report error that require and exports are reserved keywords
        self:errorSkippedOnNoEmit(name, diagnostics.Duplicate_identifier_0_Compiler_reserves_name_1_in_top_level_scope_of_a_module, scanner.DeclarationNameToString(name), scanner.DeclarationNameToString(name))
    end
end

function Checker:checkCollisionWithGlobalObjectInGeneratedCode(node, name)
    if name == nil or ast.IsClassLike(node) or not self:needCollisionCheckForIdentifier(node, name, "Object") then
        return
    end
    -- Uninstantiated modules shouldn't do this check
    if ast.IsModuleDeclaration(node) and ast.GetModuleInstanceState(node) ~= ast.ModuleInstanceState.Instantiated then
        return
    end
    -- In case of variable declaration, node.parent is variable statement so look at the variable statement's parent
    local parent = ast.GetDeclarationContainer(node)
    if ast.IsSourceFile(parent) and ast.IsExternalOrCommonJSModule(parent:AsSourceFile()) and self.program:GetEmitModuleFormatOfFile(parent:AsSourceFile()) == core.ModuleKind.CommonJS then
        -- If the declaration happens to be in external module, report error that Object is a reserved identifier.
        self:errorSkippedOnNoEmit(name, diagnostics.Duplicate_identifier_0_Compiler_reserves_name_1_in_top_level_scope_of_a_module, scanner.DeclarationNameToString(name), scanner.DeclarationNameToString(name))
    end
end

function Checker:needCollisionCheckForIdentifier(node, identifier, name)
    if identifier ~= nil and identifier:Text() ~= name then
        return false
    end
    local k = node.kind
    if k == Kind.PropertyDeclaration or k == Kind.PropertySignature or k == Kind.MethodDeclaration or k == Kind.MethodSignature or
        k == Kind.GetAccessor or k == Kind.SetAccessor or k == Kind.PropertyAssignment then
        -- it is ok to have member named '_super', '_this', `Promise`, etc. - member access is always qualified
        return false
    end
    if node.flags & NodeFlags.Ambient ~= 0 then
        -- ambient context - no codegen impact
        return false
    end
    if ast.IsImportClause(node) or ast.IsImportEqualsDeclaration(node) or ast.IsImportSpecifier(node) then
        -- type-only imports do not require collision checks against runtime values.
        if ast.IsTypeOnlyImportOrExportDeclaration(node) then
            return false
        end
    end
    local root = ast.GetRootDeclaration(node)
    if ast.IsParameterDeclaration(root) and ast.NodeIsMissing(root.parent:Body()) then
        -- just an overload - no codegen impact
        return false
    end
    return true
end

function Checker:setNodeLinksForPrivateIdentifierScope(node)
    local name = node:Name()
    if ast.IsPrivateIdentifier(name) then
        if self.languageVersion < checker.LanguageFeatureMinimumTarget.PrivateNamesAndClassStaticBlocks or
            self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators or
            not self.compilerOptions:GetUseDefineForClassFields() then
            local lexicalScope = ast.GetEnclosingBlockScopeContainer(node)
            while lexicalScope ~= nil do
                local links = self.nodeLinks:Get(lexicalScope)
                links.flags = links.flags | NodeCheckFlags.ContainsClassWithPrivateIdentifiers
                lexicalScope = ast.GetEnclosingBlockScopeContainer(lexicalScope)
            end
        end
    end
end

function Checker:recordPotentialCollisionWithWeakMapSetInGeneratedCode(node, name)
    if self.languageVersion <= core.ScriptTarget.ES2021 and
        (self:needCollisionCheckForIdentifier(node, name, "WeakMap") or self:needCollisionCheckForIdentifier(node, name, "WeakSet")) then
        self:addDeferredDiagnostic(function()
            self:checkWeakMapSetCollision(node)
        end)
    end
end

function Checker:checkWeakMapSetCollision(node)
    local enclosingBlockScope = ast.GetEnclosingBlockScopeContainer(node)
    if self.nodeLinks:Get(enclosingBlockScope).flags & NodeCheckFlags.ContainsClassWithPrivateIdentifiers ~= 0 then
        local name = node:Name()
        if name ~= nil and ast.IsIdentifier(name) then
            self:errorSkippedOnNoEmit(node, diagnostics.Compiler_reserves_name_0_when_emitting_private_identifier_downlevel, name:Text())
        end
    end
end

function Checker:checkCollisionWithGlobalPromiseInGeneratedCode(node, name)
    if name == nil or self.languageVersion >= core.ScriptTarget.ES2017 or not self:needCollisionCheckForIdentifier(node, name, "Promise") then
        return
    end
    -- Uninstantiated modules shouldn't do this check
    if ast.IsModuleDeclaration(node) and ast.GetModuleInstanceState(node) ~= ast.ModuleInstanceState.Instantiated then
        return
    end
    -- In case of variable declaration, node.parent is variable statement so look at the variable statement's parent
    local parent = ast.GetDeclarationContainer(node)
    if ast.IsSourceFile(parent) and ast.IsExternalOrCommonJSModule(parent:AsSourceFile()) and parent.flags & NodeFlags.HasAsyncFunctions ~= 0 then
        -- If the declaration happens to be in external module, report error that Promise is a reserved identifier.
        self:errorSkippedOnNoEmit(name, diagnostics.Duplicate_identifier_0_Compiler_reserves_name_1_in_top_level_scope_of_a_module_containing_async_functions, scanner.DeclarationNameToString(name), scanner.DeclarationNameToString(name))
    end
end

function Checker:recordPotentialCollisionWithReflectInGeneratedCode(node, name)
    if name ~= nil and self.languageVersion <= core.ScriptTarget.ES2021 and self:needCollisionCheckForIdentifier(node, name, "Reflect") then
        self:addDeferredDiagnostic(function()
            self:checkReflectCollision(node)
        end)
    end
end

function Checker:checkReflectCollision(node)
    local hasCollision = false
    if ast.IsClassExpression(node) then
        -- ClassExpression names don't contribute to their containers, but do matter for any of their block-scoped members.
        for _, member in ipairs(node:Members() or {}) do
            if self.nodeLinks:Get(member).flags & NodeCheckFlags.ContainsSuperPropertyInStaticInitializer ~= 0 then
                hasCollision = true
                break
            end
        end
    elseif ast.IsFunctionExpression(node) then
        -- FunctionExpression names don't contribute to their containers, but do matter for their contents
        if self.nodeLinks:Get(node).flags & NodeCheckFlags.ContainsSuperPropertyInStaticInitializer ~= 0 then
            hasCollision = true
        end
    else
        local container = ast.GetEnclosingBlockScopeContainer(node)
        if container ~= nil and self.nodeLinks:Get(container).flags & NodeCheckFlags.ContainsSuperPropertyInStaticInitializer ~= 0 then
            hasCollision = true
        end
    end
    if hasCollision then
        local name = node:Name()
        if name ~= nil and ast.IsIdentifier(name) then
            self:errorSkippedOnNoEmit(node, diagnostics.Duplicate_identifier_0_Compiler_reserves_name_1_when_emitting_super_references_in_static_initializers, scanner.DeclarationNameToString(name), "Reflect")
        end
    end
end

function Checker:checkClassNameCollisionWithObject(name)
    if name:Text() == "Object" and self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(name)) < core.ModuleKind.ES2015 then
        self:error(name, diagnostics.Class_name_cannot_be_Object_when_targeting_ES5_and_above_with_module_0, core.ModuleKind_String(self.moduleKind))
    end
end

function Checker:checkTypeOfExpression(node)
    self:checkExpression(node:Expression())
    return self.typeofType
end

function Checker:checkNonNullAssertion(node)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        -- checkNonNullChain checks the same operand expression (node.Expression()),
        -- so the child is still visited on this branch.
        return self:checkNonNullChain(node)
    end
    return self:GetNonNullableType(self:checkExpression(node:Expression()))
end

function Checker:checkNonNullChain(node)
    local leftType = self:checkExpression(node:Expression())
    local nonOptionalType = self:getOptionalExpressionType(leftType, node:Expression())
    return self:propagateOptionalTypeMarker(self:GetNonNullableType(nonOptionalType), node, nonOptionalType ~= leftType)
end

function Checker:checkExpressionWithTypeArguments(node)
    self:checkGrammarExpressionWithTypeArguments(node)
    self:checkSourceElements(node:TypeArguments())
    if ast.IsExpressionWithTypeArguments(node) then
        local parent = ast.WalkUpParenthesizedExpressions(node.parent)
        if ast.IsBinaryExpression(parent) and parent:AsBinaryExpression().operatorToken.kind == Kind.InstanceOfKeyword and checker.isNodeDescendantOf(node, parent:AsBinaryExpression().right) then
            self:error(node, diagnostics.The_right_hand_side_of_an_instanceof_expression_must_not_be_an_instantiation_expression)
        end
    end
    local exprType
    if ast.IsExpressionWithTypeArguments(node) then
        exprType = self:checkExpression(node:Expression())
    else
        local exprName = node:AsTypeQueryNode().exprName
        if ast.IsThisIdentifier(exprName) then
            exprType = self:checkThisExpression(node:AsTypeQueryNode().exprName)
        else
            exprType = self:checkExpression(node:AsTypeQueryNode().exprName)
        end
    end
    return self:getInstantiationExpressionType(exprType, node)
end
