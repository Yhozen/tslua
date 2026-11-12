local checker = require("tslua.checker")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local evaluator = require("tslua.evaluator")
local jsnum = require("tslua.jsnum")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")

local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local Tristate = core.Tristate
local SymbolAccessibility = printer.SymbolAccessibility
local JSDeclarationKind = ast.JSDeclarationKind

-- EmitResolver implements printer.EmitResolver (method set documented in
-- src/tslua/printer/emitresolver.lua). Checker locking (checkerMu) is a no-op in Lua and is
-- omitted.

-- Links for jsx
defineStruct("JSXLinks", nil, nil)

-- Links for declarations

-- if declaration is depended upon by exported declarations
defineStruct("DeclarationLinks", nil, { isVisible = Tristate.TSUnknown })

-- if file has had alias visibility marked
defineStruct("DeclarationFileLinks", nil, { aliasesMarked = false })

local EmitResolver = defineStruct("EmitResolver", nil, nil)

-- SymbolAccessibilityResult value with Go zero values filled in.
local function newSymbolAccessibilityResult(accessibility, errorSymbolName, errorNode, errorModuleName, aliasesToMakeVisible)
    return {
        accessibility = accessibility,
        aliasesToMakeVisible = aliasesToMakeVisible,
        errorSymbolName = errorSymbolName or "",
        errorNode = errorNode,
        errorModuleName = errorModuleName or "",
    }
end
checker.newSymbolAccessibilityResult = newSymbolAccessibilityResult

function checker.newEmitResolver(c)
    local e = checker.EmitResolver_new({ checker = c })
    e.jsxLinks = checker.NewLinkStore(checker.JSXLinks_new)
    e.declarationLinks = checker.NewLinkStore(checker.DeclarationLinks_new)
    e.declarationFileLinks = checker.NewLinkStore(checker.DeclarationFileLinks_new)
    e.isValueAliasDeclaration = function(node)
        return e:isValueAliasDeclarationWorker(node)
    end
    e.aliasMarkingVisitor = function(node)
        return e:aliasMarkingVisitorWorker(node)
    end
    e.checkerMu = c.mu
    return e
end

function EmitResolver:GetJsxFactoryEntity(location)
    return self.checker:getJsxFactoryEntity(location)
end

function EmitResolver:GetJsxFragmentFactoryEntity(location)
    return self.checker:getJsxFragmentFactoryEntity(location)
end

function EmitResolver:IsOptionalParameter(node)
    return self:isOptionalParameter(node)
end

function EmitResolver:IsLateBound(node)
    -- TODO: Require an emitContext to construct an EmitResolver, remove all emitContext arguments
    -- node = r.emitContext.ParseNode(node)
    if node == nil then
        return false
    end
    if not ast.IsParseTreeNode(node) then
        return false
    end
    local symbol = self.checker:getSymbolOfDeclaration(node)
    if symbol == nil then
        return false
    end
    return symbol.checkFlags & CheckFlags.Late ~= 0
end

function EmitResolver:GetEnumMemberValue(node)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(node) then
        return evaluator.NewResult(nil, false, false, false)
    end

    self.checker:computeEnumMemberValues(node.parent)
    if not self.checker.enumMemberLinks:Has(node) then
        return evaluator.NewResult(nil, false, false, false)
    end
    return self.checker.enumMemberLinks:Get(node).value
end

function EmitResolver:IsDeclarationVisible(node)
    -- Only lock on external API func to prevent deadlocks
    return self:isDeclarationVisible(node)
end

function EmitResolver:isDeclarationVisible(node)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(node) then
        return false
    end
    if node == nil then
        return false
    end

    local links = self.declarationLinks:Get(node)
    if links.isVisible == Tristate.TSUnknown then
        if self:determineIfDeclarationIsVisible(node) then
            links.isVisible = Tristate.TSTrue
        else
            links.isVisible = Tristate.TSFalse
        end
    end
    return links.isVisible == Tristate.TSTrue
end

local determineVisibleDeclarationKinds = ast.kindSet(
    Kind.VariableDeclaration,
    Kind.ModuleDeclaration,
    Kind.ClassDeclaration,
    Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration,
    Kind.JSTypeAliasDeclaration,
    Kind.FunctionDeclaration,
    Kind.EnumDeclaration,
    Kind.ImportEqualsDeclaration
)

local determineVisibleMemberKinds = ast.kindSet(
    Kind.PropertyDeclaration,
    Kind.PropertySignature,
    Kind.GetAccessor,
    Kind.SetAccessor,
    Kind.MethodDeclaration,
    Kind.MethodSignature
)

local determineVisibleParentKinds = ast.kindSet(
    Kind.Constructor,
    Kind.ConstructSignature,
    Kind.CallSignature,
    Kind.IndexSignature,
    Kind.Parameter,
    Kind.ModuleBlock,
    Kind.FunctionType,
    Kind.ConstructorType,
    Kind.TypeLiteral,
    Kind.TypeReference,
    Kind.ArrayType,
    Kind.TupleType,
    Kind.UnionType,
    Kind.IntersectionType,
    Kind.ParenthesizedType,
    Kind.NamedTupleMember
)

function EmitResolver:determineIfDeclarationIsVisible(node)
    local kind = node.kind
    if kind == Kind.JSDocCallbackTag or
        -- ast.KindJSDocEnumTag, // !!! TODO: JSDoc @enum support?
        kind == Kind.JSDocTypedefTag then
        -- Top-level jsdoc type aliases are considered exported
        -- First parent is comment node, second is hosting declaration or token; we only care about those tokens or declarations whose parent is a source file
        return node.parent ~= nil and node.parent.parent ~= nil and node.parent.parent.parent ~= nil and ast.IsSourceFile(node.parent.parent.parent)
    elseif kind == Kind.BindingElement then
        return self:isDeclarationVisible(node.parent.parent)
    elseif determineVisibleDeclarationKinds[kind] then
        if ast.IsVariableDeclaration(node) then
            if ast.IsBindingPattern(node:Name()) and
                #(node:Name():Elements() or {}) == 0 then
                -- If the binding pattern is empty, this variable declaration is not visible
                return false
            end
            -- falls through
        end
        -- External module augmentation is always visible
        -- A @typedef at top-level in an external module is always visible
        if ast.IsExternalModuleAugmentation(node) or ast.IsImplicitlyExportedJSDocDeclaration(node) then
            return true
        end
        local parent = ast.GetDeclarationContainer(node)
        -- If the node is not exported or it is not ambient module element (except import declaration)
        if self.checker:getCombinedModifierFlagsCached(node) & ModifierFlags.Export == 0 and
            not (node.kind ~= Kind.ImportEqualsDeclaration and parent.kind ~= Kind.SourceFile and parent.flags & NodeFlags.Ambient ~= 0) then
            return ast.IsGlobalSourceFile(parent)
        end
        -- Exported members/ambient module elements (exception import declaration) are visible if parent is visible
        return self:isDeclarationVisible(parent)
    elseif determineVisibleMemberKinds[kind] then
        if self.checker:GetEffectiveDeclarationFlags(node, ModifierFlags.Private | ModifierFlags.Protected) ~= 0 then
            -- Private/protected properties/methods are not visible
            return false
        end
        -- Public properties/methods are visible if its parents are visible, so:
        return self:isDeclarationVisible(node.parent)
    elseif determineVisibleParentKinds[kind] then
        return self:isDeclarationVisible(node.parent)
    elseif kind == Kind.ImportClause or kind == Kind.NamespaceImport or kind == Kind.ImportSpecifier then
        -- Default binding, import specifier and namespace import is visible
        -- only on demand so by default it is not visible
        return false
    elseif kind == Kind.TypeParameter then
        -- Type parameters are always visible
        return true
    elseif kind == Kind.SourceFile or kind == Kind.NamespaceExportDeclaration then
        -- Source file and namespace export are always visible
        return true
    elseif kind == Kind.ExportAssignment then
        -- Export assignments do not create name bindings outside the module
        return false
    elseif kind == Kind.ExportSpecifier then
        -- An `export {X}` (without a module specifier) is itself a visible re-export of
        -- the named binding; it contributes to the symbol's external visibility.
        local exportDecl = node.parent.parent
        if ast.IsExportDeclaration(exportDecl) and exportDecl:AsExportDeclaration().moduleSpecifier == nil then
            return self:isDeclarationVisible(exportDecl.parent)
        end
        return false
    else
        return false
    end
end

function EmitResolver:PrecalculateDeclarationEmitVisibility(file)
    if self.declarationFileLinks:Get(file:AsNode()).aliasesMarked then
        return
    end
    self.declarationFileLinks:Get(file:AsNode()).aliasesMarked = true
    -- TODO: Does this even *have* to be an upfront walk? If it's not possible for a
    -- import a = a.b.c statement to chain into exposing a statement in a sibling scope,
    -- it could at least be pushed into scope entry -  then it wouldn't need to be recursive.
    file:AsNode():ForEachChild(self.aliasMarkingVisitor)
end

function checker.isCommonJSModuleExports(node)
    if ast.IsBinaryExpression(node) and ast.IsExpressionStatement(node.parent) and ast.IsSourceFile(node.parent.parent) and
        node.parent.parent:AsSourceFile().commonJSModuleIndicator ~= nil then
        local k = ast.GetAssignmentDeclarationKind(node)
        if k == JSDeclarationKind.ModuleExports or k == JSDeclarationKind.ExportsProperty then
            return true
        end
    end
    return false
end

function EmitResolver:aliasMarkingVisitorWorker(node)
    local kind = node.kind
    if kind == Kind.BinaryExpression then
        if checker.isCommonJSModuleExports(node) and ast.IsIdentifier(node:AsBinaryExpression().right) then
            self:markLinkedAliases(node:AsBinaryExpression().right)
        end
    elseif kind == Kind.ExportAssignment then
        if node:Expression().kind == Kind.Identifier then
            self:markLinkedAliases(node:Expression())
        end
    elseif kind == Kind.ExportSpecifier then
        self:markLinkedAliases(node:PropertyNameOrName())
    end
    return node:ForEachChild(self.aliasMarkingVisitor)
end

-- Sets the isVisible link on statements the Identifier or ExportName node points at
-- Follows chains of import d = a.b.c
function EmitResolver:markLinkedAliases(node)
    local exportSymbol
    if node.kind ~= Kind.StringLiteral and node.parent ~= nil and (ast.IsExportAssignment(node.parent) or checker.isCommonJSModuleExports(node.parent)) then
        exportSymbol = self.checker.resolveName(node, node:Text(), SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], false --[[isUse]], false)
    elseif node.parent.kind == Kind.ExportSpecifier then
        exportSymbol = self.checker:getTargetOfExportSpecifier(node.parent, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, false)
    end

    local visited = {} -- guard against circular imports
    while exportSymbol ~= nil do
        if visited[ast.GetSymbolId(exportSymbol)] then
            break
        end
        visited[ast.GetSymbolId(exportSymbol)] = true

        local nextSymbol
        for _, declaration in ipairs(exportSymbol.declarations or {}) do
            self.declarationLinks:Get(declaration).isVisible = Tristate.TSTrue

            if ast.IsInternalModuleImportEqualsDeclaration(declaration) then
                -- Add the referenced top container visible
                local internalModuleReference = declaration:AsImportEqualsDeclaration().moduleReference
                local firstIdentifier = ast.GetFirstIdentifier(internalModuleReference)
                local importSymbol = self.checker.resolveName(declaration, firstIdentifier:Text(), SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], false --[[isUse]], false)
                nextSymbol = importSymbol
            end
        end

        exportSymbol = nextSymbol
    end
end

function checker.getMeaningOfEntityNameReference(entityName)
    -- get symbol of the first identifier of the entityName
    local parent = entityName.parent
    if parent.kind == Kind.TypeQuery or
        parent.kind == Kind.ExpressionWithTypeArguments and not ast.IsPartOfTypeNode(parent) or
        parent.kind == Kind.ComputedPropertyName or
        parent.kind == Kind.TypePredicate and parent:AsTypePredicateNode().parameterName == entityName or
        parent.kind == Kind.BinaryExpression then
        -- Typeof value
        return SymbolFlags.Value | SymbolFlags.ExportValue
    end
    if entityName.kind == Kind.QualifiedName or entityName.kind == Kind.PropertyAccessExpression or
        parent.kind == Kind.ImportEqualsDeclaration or
        (parent.kind == Kind.QualifiedName and parent:AsQualifiedName().left == entityName) or
        (parent.kind == Kind.PropertyAccessExpression and parent:Expression() == entityName) or
        (parent.kind == Kind.ElementAccessExpression and parent:Expression() == entityName) then
        -- Left identifier from type reference or TypeAlias
        -- Entity name of the import declaration
        return SymbolFlags.Namespace
    end
    -- Type Reference or TypeAlias entity = Identifier
    return SymbolFlags.Type
end

function EmitResolver:IsEntityNameVisible(entityName, enclosingDeclaration)
    return self:isEntityNameVisible(entityName, enclosingDeclaration, true)
end

function EmitResolver:isEntityNameVisible(entityName, enclosingDeclaration, shouldComputeAliasToMakeVisible)
    -- node = r.emitContext.ParseNode(entityName)
    if not ast.IsParseTreeNode(entityName) then
        return newSymbolAccessibilityResult(SymbolAccessibility.NotAccessible)
    end

    local meaning = checker.getMeaningOfEntityNameReference(entityName)
    local firstIdentifier = ast.GetFirstIdentifier(entityName)

    local symbol = self.checker.resolveName(enclosingDeclaration, firstIdentifier:Text(), meaning, nil, false, false)

    if symbol ~= nil and symbol.flags & SymbolFlags.TypeParameter ~= 0 and meaning & SymbolFlags.Type ~= 0 then
        return newSymbolAccessibilityResult(SymbolAccessibility.Accessible)
    end

    if symbol == nil and ast.IsThisIdentifier(firstIdentifier) then
        local sym = self.checker:getSymbolOfDeclaration(self.checker:getThisContainer(firstIdentifier, false, false))
        if self:isSymbolAccessible(sym, enclosingDeclaration, meaning, false).accessibility == SymbolAccessibility.Accessible then
            return newSymbolAccessibilityResult(SymbolAccessibility.Accessible)
        end
    end

    if symbol == nil then
        return newSymbolAccessibilityResult(SymbolAccessibility.NotResolved, firstIdentifier:Text(), firstIdentifier)
    end

    local visible = self:hasVisibleDeclarations(symbol, shouldComputeAliasToMakeVisible)
    if visible ~= nil then
        return visible
    end

    return newSymbolAccessibilityResult(SymbolAccessibility.NotAccessible, firstIdentifier:Text(), firstIdentifier)
end

function checker.noopAddVisibleAlias(declaration, aliasingStatement) -- luacheck: ignore 212
end

function EmitResolver:hasVisibleDeclarations(symbol, shouldComputeAliasToMakeVisible)
    -- Go map[ast.NodeId]*ast.Node; Lua keeps first-insertion order of the keys (Go's map order is
    -- random) so the result is deterministic.
    local aliasesToMakeVisibleSet
    local aliasesToMakeVisibleOrder

    local addVisibleAlias
    if shouldComputeAliasToMakeVisible then
        addVisibleAlias = function(declaration, aliasingStatement)
            self.declarationLinks:Get(declaration).isVisible = Tristate.TSTrue
            if aliasesToMakeVisibleSet == nil then
                aliasesToMakeVisibleSet = {}
                aliasesToMakeVisibleOrder = {}
            end
            local id = ast.GetNodeId(declaration)
            if aliasesToMakeVisibleSet[id] == nil then
                aliasesToMakeVisibleOrder[#aliasesToMakeVisibleOrder + 1] = id
            end
            aliasesToMakeVisibleSet[id] = aliasingStatement
        end
    else
        addVisibleAlias = checker.noopAddVisibleAlias
    end

    for _, declaration in ipairs(symbol.declarations or {}) do
        if ast.IsIdentifier(declaration) then
            goto continue
        end
        if not self:isDeclarationVisible(declaration) then
            -- Mark the unexported alias as visible if its parent is visible
            -- because these kind of aliases can be used to name types in declaration file
            local anyImportSyntax = checker.getAnyImportSyntax(declaration)
            if anyImportSyntax ~= nil and
                not ast.HasSyntacticModifier(anyImportSyntax, ModifierFlags.Export) and -- import clause without export
                self:isDeclarationVisible(anyImportSyntax.parent) then
                addVisibleAlias(declaration, anyImportSyntax)
                goto continue
            end
            if ast.IsVariableDeclaration(declaration) and ast.IsVariableStatement(declaration.parent.parent) and
                not ast.HasSyntacticModifier(declaration.parent.parent, ModifierFlags.Export) and -- unexported variable statement
                self:isDeclarationVisible(declaration.parent.parent.parent) then
                addVisibleAlias(declaration, declaration.parent.parent)
                goto continue
            end
            if ast.IsLateVisibilityPaintedStatement(declaration) and -- unexported top-level statement
                not ast.HasSyntacticModifier(declaration, ModifierFlags.Export) and
                self:isDeclarationVisible(declaration.parent) then
                addVisibleAlias(declaration, declaration)
                goto continue
            end
            if ast.IsBindingElement(declaration) then
                if symbol.flags & SymbolFlags.Alias ~= 0 and ast.IsInJSFile(declaration) and declaration.parent ~= nil and declaration.parent.parent ~= nil and -- exported import-like top-level JS require statement
                    ast.IsVariableDeclaration(declaration.parent.parent) and
                    declaration.parent.parent.parent.parent ~= nil and ast.IsVariableStatement(declaration.parent.parent.parent.parent) and
                    not ast.HasSyntacticModifier(declaration.parent.parent.parent.parent, ModifierFlags.Export) and
                    declaration.parent.parent.parent.parent.parent ~= nil and -- check if the thing containing the variable statement is visible (ie, the file)
                    self:isDeclarationVisible(declaration.parent.parent.parent.parent.parent) then
                    addVisibleAlias(declaration, declaration.parent.parent.parent.parent)
                    goto continue
                end
                if symbol.flags & SymbolFlags.BlockScopedVariable ~= 0 then
                    local rootDeclaration = ast.WalkUpBindingElementsAndPatterns(declaration)
                    if ast.IsParameterDeclaration(rootDeclaration) then
                        return nil
                    end
                    local variableStatement = rootDeclaration.parent.parent
                    if not ast.IsVariableStatement(variableStatement) then
                        return nil
                    end
                    if ast.HasSyntacticModifier(variableStatement, ModifierFlags.Export) then
                        goto continue -- no alias to add, already exported
                    end
                    if not self:isDeclarationVisible(variableStatement.parent) then
                        return nil -- not visible
                    end
                    addVisibleAlias(declaration, variableStatement)
                    goto continue
                end
            end

            -- Declaration is not visible
            return nil
        end
        ::continue::
    end

    local aliasesToMakeVisible
    if aliasesToMakeVisibleSet ~= nil then
        aliasesToMakeVisible = {}
        for _, id in ipairs(aliasesToMakeVisibleOrder) do
            aliasesToMakeVisible[#aliasesToMakeVisible + 1] = aliasesToMakeVisibleSet[id]
        end
    end
    return newSymbolAccessibilityResult(SymbolAccessibility.Accessible, nil, nil, nil, aliasesToMakeVisible)
end

function EmitResolver:IsImplementationOfOverload(node)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(node) then
        return false
    end
    if ast.NodeIsPresent(node:Body()) then
        if ast.IsGetAccessorDeclaration(node) or ast.IsSetAccessorDeclaration(node) then
            return false -- Get or set accessors can never be overload implementations, but can have up to 2 signatures
        end
        local symbol = self.checker:getSymbolOfDeclaration(node)
        local signaturesOfSymbol = self.checker:getSignaturesOfSymbol(symbol)
        -- If this function body corresponds to function with multiple signature, it is implementation of overload
        -- e.g.: function foo(a: string): string;
        --       function foo(a: number): number;
        --       function foo(a: any) { // This is implementation of the overloads
        --           return a;
        --       }
        if core.Len(signaturesOfSymbol) > 1 then
            return true
        end
        -- If there is single signature for the symbol, it is overload if that signature isn't coming from the node
        -- e.g.: function foo(a: string): string;
        --       function foo(a: any) { // This is implementation of the overloads
        --           return a;
        --       }
        if core.Len(signaturesOfSymbol) == 1 then
            local signature = signaturesOfSymbol[1]
            if signature == self.checker:getSignatureOfFullSignatureType(node) then
                return false
            end
            local declaration = signature.declaration
            if declaration ~= node and declaration.flags & NodeFlags.JSDoc == 0 then
                return true
            end
        end
    end
    return false
end

function EmitResolver:IsImportRequiredByAugmentation(decl)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(decl:AsNode()) then
        return false
    end
    local file = ast.GetSourceFileOfNode(decl:AsNode())
    if file.symbol == nil then
        -- script file
        return false
    end
    local importTarget = self:GetExternalModuleFileFromDeclaration(decl:AsNode())
    if importTarget == nil then
        return false
    end
    if importTarget == file then
        return false
    end
    local exports = self.checker:getExportsOfModule(file.symbol)
    for _, s in pairs(exports or {}) do
        local merged = self.checker:getMergedSymbol(s)
        if merged ~= s then
            if core.Len(merged.declarations) > 0 then
                for _, d in ipairs(merged.declarations) do
                    local declFile = ast.GetSourceFileOfNode(d)
                    if declFile == importTarget then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function EmitResolver:IsDefinitelyReferenceToGlobalSymbolObject(node)
    if not ast.IsPropertyAccessExpression(node) or
        not ast.IsIdentifier(node:Name()) or
        not ast.IsPropertyAccessExpression(node:Expression()) and not ast.IsIdentifier(node:Expression()) then
        return false
    end
    if node:Expression().kind == Kind.Identifier then
        if node:Expression():Text() ~= "Symbol" then
            return false
        end
        -- Exactly `Symbol.something` and `Symbol` either does not resolve or definitely resolves to the global Symbol
        return self.checker:getResolvedSymbol(node:Expression()) == self.checker:getGlobalSymbol("Symbol", SymbolFlags.Value | SymbolFlags.ExportValue, nil --[[diagnostic]])
    end
    if node:Expression():Expression().kind ~= Kind.Identifier or node:Expression():Expression():Text() ~= "globalThis" or node:Expression():Name():Text() ~= "Symbol" then
        return false
    end
    -- Exactly `globalThis.Symbol.something` and `globalThis` resolves to the global `globalThis`
    return self.checker:getResolvedSymbol(node:Expression():Expression()) == self.checker.globalThisSymbol
end

function EmitResolver:RequiresAddingImplicitUndefined(declaration, symbol, enclosingDeclaration)
    if not ast.IsParseTreeNode(declaration) then
        return false
    end
    return self:requiresAddingImplicitUndefined(declaration, symbol, enclosingDeclaration)
end

function EmitResolver:RequiresAddingImplicitUndefinedUnsafe(declaration, symbol, enclosingDeclaration)
    if not ast.IsParseTreeNode(declaration) then
        return false
    end
    -- NO LOCKING - only should be called in contexts that already have a checker lock
    return self:requiresAddingImplicitUndefined(declaration, symbol, enclosingDeclaration)
end

function EmitResolver:requiresAddingImplicitUndefined(declaration, symbol, enclosingDeclaration)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(declaration) then
        return false
    end
    local kind = declaration.kind
    if kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature or kind == Kind.JSDocPropertyTag then
        if symbol == nil then
            symbol = self.checker:getSymbolOfDeclaration(declaration)
        end
        local t = self.checker:getTypeOfSymbol(symbol)
        self.checker.mappedSymbolLinks:Has(symbol)
        return (symbol.flags & SymbolFlags.Property ~= 0) and (symbol.flags & SymbolFlags.Optional ~= 0) and checker.isOptionalDeclaration(declaration) and self.checker.reverseMappedSymbolLinks:Has(symbol) and self.checker.reverseMappedSymbolLinks:Get(symbol).mappedType ~= nil and checker.containsNonMissingUndefinedType(self.checker, t)
    elseif kind == Kind.Parameter or kind == Kind.JSDocParameterTag then
        return self:requiresAddingImplicitUndefinedWorker(declaration, enclosingDeclaration)
    else
        error("Node cannot possibly require adding undefined", 0)
    end
end

function EmitResolver:requiresAddingImplicitUndefinedWorker(parameter, enclosingDeclaration)
    return (self:isRequiredInitializedParameter(parameter, enclosingDeclaration) or self:isOptionalUninitializedParameterProperty(parameter)) and not self:declaredParameterTypeContainsUndefined(parameter)
end

function EmitResolver:declaredParameterTypeContainsUndefined(parameter)
    -- typeNode := getNonlocalEffectiveTypeAnnotationNode(parameter); // !!! JSDoc Support
    local typeNode = parameter:Type()
    if typeNode == nil then
        return false
    end
    local t = self.checker:getTypeFromTypeNode(typeNode)
    -- allow error type here to avoid confusing errors that the annotation has to contain undefined when it does in cases like this:
    --
    -- export function fn(x?: Unresolved | undefined): void {}
    return self.checker:isErrorType(t) or self.checker:containsUndefinedType(t)
end

function EmitResolver:isOptionalUninitializedParameterProperty(parameter)
    return self.checker.strictNullChecks and
        self:isOptionalParameter(parameter) and
        ( --[[isJSDocParameterTag(parameter) ||]] parameter:Initializer() == nil) and -- !!! TODO: JSDoc support
        ast.HasSyntacticModifier(parameter, ModifierFlags.ParameterPropertyModifier)
end

function EmitResolver:isRequiredInitializedParameter(parameter, enclosingDeclaration)
    if not self.checker.strictNullChecks or self:isOptionalParameter(parameter) or --[[isJSDocParameterTag(parameter) ||]] parameter:Initializer() == nil then -- !!! TODO: JSDoc Support
        return false
    end
    if ast.HasSyntacticModifier(parameter, ModifierFlags.ParameterPropertyModifier) then
        return enclosingDeclaration ~= nil and ast.IsFunctionLikeDeclaration(enclosingDeclaration)
    end
    return true
end

function EmitResolver:isOptionalParameter(node)
    return self.checker:isOptionalParameter(node)
end

function EmitResolver:IsLiteralConstDeclaration(node)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(node) then
        return false
    end
    if checker.isDeclarationReadonly(node) or ast.IsVariableDeclaration(node) and ast.IsVarConst(node) then
        local s = self.checker:getSymbolOfDeclaration(node)
        if s == nil then
            return false
        end
        return checker.isFreshLiteralType(self.checker:getTypeOfSymbol(s))
    end
    return false
end

function EmitResolver:IsExpandoFunctionDeclarationUnsafe(node)
    -- node = r.emitContext.ParseNode(node)
    if not ast.IsParseTreeNode(node) then
        return false
    end
    -- this is substantially different from strada, but so is expando property checking
    local props = self:GetPropertiesOfContainerFunction(node)
    for _, p in ipairs(props or {}) do
        if ast.IsExpandoPropertyDeclaration(p.valueDeclaration) then
            return true
        end
    end
    return false
end

function EmitResolver:IsExpandoFunctionDeclaration(node)
    return self:IsExpandoFunctionDeclarationUnsafe(node)
end

function EmitResolver:isSymbolAccessible(symbol, enclosingDeclaration, meaning, shouldComputeAliasToMarkVisible)
    return self.checker:IsSymbolAccessible(symbol, enclosingDeclaration, meaning, shouldComputeAliasToMarkVisible)
end

function EmitResolver:IsSymbolAccessible(symbol, enclosingDeclaration, meaning, shouldComputeAliasToMarkVisible)
    -- TODO: Split into locking and non-locking API methods - only current usage is the symbol tracker, which is non-locking,
    -- as all tracker calls happen within a CreateX call below, which already holds a lock
    return self:isSymbolAccessible(symbol, enclosingDeclaration, meaning, shouldComputeAliasToMarkVisible)
end

function checker.isConstEnumOrConstEnumOnlyModule(s)
    return checker.isConstEnumSymbol(s) or s.flags & SymbolFlags.ConstEnumOnlyModule ~= 0
end

function EmitResolver:IsReferencedAliasDeclaration(node)
    local c = self.checker
    if not c.canCollectSymbolAliasAccessibilityData or not ast.IsParseTreeNode(node) then
        return true
    end

    if ast.IsAliasSymbolDeclaration(node) then
        local symbol = c:getSymbolOfDeclaration(node)
        if symbol ~= nil then
            local aliasLinks = c.aliasSymbolLinks:Get(symbol)
            if aliasLinks.referenced then
                return true
            end
            local target = aliasLinks.aliasTarget
            if target ~= nil and node:ModifierFlags() & ModifierFlags.Export ~= 0 and
                c:getSymbolFlags(target) & SymbolFlags.Value ~= 0 and
                (c.compilerOptions:ShouldPreserveConstEnums() or not checker.isConstEnumOrConstEnumOnlyModule(target)) then
                return true
            end
        end
    end
    return false
end

function EmitResolver:IsValueAliasDeclaration(node)
    local c = self.checker
    if not c.canCollectSymbolAliasAccessibilityData or not ast.IsParseTreeNode(node) then
        return true
    end

    return self:isValueAliasDeclarationWorker(node)
end

function EmitResolver:isValueAliasDeclarationWorker(node)
    local c = self.checker

    local kind = node.kind
    if kind == Kind.ImportEqualsDeclaration then
        return self:isAliasResolvedToValue(c:getSymbolOfDeclaration(node), false --[[excludeTypeOnlyValues]])
    elseif kind == Kind.ImportClause or
        kind == Kind.NamespaceImport or
        kind == Kind.ImportSpecifier or
        kind == Kind.ExportSpecifier then
        local symbol = c:getSymbolOfDeclaration(node)
        return symbol ~= nil and self:isAliasResolvedToValue(symbol, true --[[excludeTypeOnlyValues]])
    elseif kind == Kind.ExportDeclaration then
        local exportClause = node:AsExportDeclaration().exportClause
        return exportClause ~= nil and (ast.IsNamespaceExport(exportClause) or
            core.Some(exportClause:Elements(), self.isValueAliasDeclaration))
    elseif kind == Kind.ExportAssignment then
        if node:Expression() ~= nil and node:Expression().kind == Kind.Identifier then
            return self:isAliasResolvedToValue(c:getSymbolOfDeclaration(node), true --[[excludeTypeOnlyValues]])
        end
        return true
    elseif kind == Kind.BinaryExpression then
        if checker.isCommonJSModuleExports(node) and ast.IsIdentifier(node:AsBinaryExpression().right) then
            return self:isAliasResolvedToValue(c:getSymbolOfDeclaration(node), true --[[excludeTypeOnlyValues]])
        end
    end
    return false
end

function EmitResolver:isAliasResolvedToValue(symbol, excludeTypeOnlyValues)
    local c = self.checker
    if symbol == nil then
        return false
    end
    if symbol.valueDeclaration ~= nil then
        local container = ast.GetSourceFileOfNode(symbol.valueDeclaration)
        if container ~= nil then
            local fileSymbol = c:getSymbolOfDeclaration(container:AsNode())
            -- Ensures cjs export assignment is setup, since this symbol may point at, and merge with, the file itself.
            -- If we don't, the merge may not have yet occurred, and the flags check below will be missing flags that
            -- are added as a result of the merge.
            c:resolveExternalModuleSymbol(fileSymbol, false --[[dontResolveAlias]])
        end
    end
    local target = c:getExportSymbolOfValueSymbolIfExported(c:resolveAlias(symbol))
    if target == c.unknownSymbol then
        return not excludeTypeOnlyValues or c:getTypeOnlyAliasDeclaration(symbol) == nil
    end
    -- const enums and modules that contain only const enums are not considered values from the emit perspective
    -- unless 'preserveConstEnums' option is set to true
    return c:getSymbolFlagsEx(symbol, excludeTypeOnlyValues, true --[[excludeLocalMeanings]]) & SymbolFlags.Value ~= 0 and
        (c.compilerOptions:ShouldPreserveConstEnums() or
            not checker.isConstEnumOrConstEnumOnlyModule(target))
end

function EmitResolver:IsTopLevelValueImportEqualsWithEntityName(node)
    local c = self.checker
    if not c.canCollectSymbolAliasAccessibilityData then
        return true
    end
    if not ast.IsParseTreeNode(node) or node.kind ~= Kind.ImportEqualsDeclaration or node.parent.kind ~= Kind.SourceFile then
        return false
    end
    if ast.IsImportEqualsDeclaration(node) and
        (ast.NodeIsMissing(node:AsImportEqualsDeclaration().moduleReference) or node:AsImportEqualsDeclaration().moduleReference.kind == Kind.ExternalModuleReference) then
        return false
    end

    return self:isAliasResolvedToValue(c:getSymbolOfDeclaration(node), false --[[excludeTypeOnlyValues]])
end

function EmitResolver:MarkLinkedReferencesRecursively(file)
    if not ast.IsParseTreeNode(file:AsNode()) then
        return
    end

    if file ~= nil then
        local visit
        visit = function(n)
            if ast.IsImportEqualsDeclaration(n) and n:ModifierFlags() & ModifierFlags.Export == 0 then
                return false -- These are deferred and marked in a chain when referenced
            end
            if ast.IsImportDeclaration(n) then
                return false -- likewise, these are ultimately what get marked by calls on other nodes - we want to skip them
            end
            self.checker:markLinkedReferences(n, checker.ReferenceHint.Unspecified, nil --[[propSymbol]], nil --[[parentType]])
            n:ForEachChild(visit)
            return false
        end
        file:ForEachChild(visit)
    end
end

function EmitResolver:GetExternalModuleFileFromDeclaration(declaration)
    if not ast.IsParseTreeNode(declaration) then
        return nil
    end

    return self.checker:getExternalModuleFileFromDeclaration(declaration)
end

function EmitResolver:getReferenceResolver()
    if self.referenceResolver == nil then
        local c = self.checker
        self.referenceResolver = binder.NewReferenceResolver(c.compilerOptions, {
            resolveName = c.resolveName,
            getResolvedSymbol = function(node)
                return c:getResolvedSymbolOrNil(node)
            end,
            getMergedSymbol = function(symbol)
                return c:getMergedSymbol(symbol)
            end,
            getParentOfSymbol = function(symbol)
                return c:getParentOfSymbol(symbol)
            end,
            getSymbolOfDeclaration = function(declaration)
                return c:getSymbolOfDeclaration(declaration)
            end,
            getTypeOnlyAliasDeclaration = function(symbol, include)
                return c:getTypeOnlyAliasDeclarationEx(symbol, include)
            end,
            getExportSymbolOfValueSymbolIfExported = function(symbol)
                return c:getExportSymbolOfValueSymbolIfExported(symbol)
            end,
            getElementAccessExpressionName = function(expression)
                return c:tryGetElementAccessExpressionName(expression)
            end,
        })
    end
    return self.referenceResolver
end

function EmitResolver:GetReferencedExportContainer(node, prefixLocals)
    if not ast.IsParseTreeNode(node) then
        return nil
    end

    return self:getReferenceResolver():GetReferencedExportContainer(node, prefixLocals)
end

function EmitResolver:SetReferencedImportDeclaration(node, ref)
    self.jsxLinks:Get(node).importRef = ref
end

function EmitResolver:GetReferencedImportDeclaration(node)
    if not ast.IsParseTreeNode(node) then
        return self.jsxLinks:Get(node).importRef
    end

    local symbol = self.checker:getReferencedValueOrAliasSymbol(node)
    if ast.IsNonLocalAlias(symbol, SymbolFlags.Value) and self.checker:getTypeOnlyAliasDeclarationEx(symbol, SymbolFlags.Value) == nil then
        return self.checker:getDeclarationOfAliasSymbol(symbol)
    end
    return nil
end

function EmitResolver:GetReferencedValueDeclaration(node)
    if not ast.IsParseTreeNode(node) then
        return nil
    end

    return self:getReferenceResolver():GetReferencedValueDeclaration(node)
end

function EmitResolver:GetReferencedValueDeclarationUnsafe(node)
    return self:getReferenceResolver():GetReferencedValueDeclaration(node)
end

function EmitResolver:GetReferencedValueDeclarations(node)
    if not ast.IsParseTreeNode(node) then
        return nil
    end

    return self:getReferenceResolver():GetReferencedValueDeclarations(node)
end

-- IsNameResolvable returns `true` if the given `name` resolves to any symbol at `location`
function EmitResolver:IsNameResolvable(location, name)
    local symbol = self.checker.resolveName(location, name, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
    return symbol ~= nil
end

function EmitResolver:GetElementAccessExpressionName(expression)
    if not ast.IsParseTreeNode(expression:AsNode()) then
        return ""
    end

    return self:getReferenceResolver():GetElementAccessExpressionName(expression)
end

function EmitResolver:GetReferencedMemberValueDeclaration(node)
    if not ast.IsParseTreeNode(node) then
        return nil
    end

    return self:getReferenceResolver():GetReferencedMemberValueDeclaration(node)
end

-- TODO: the emit resolver being responsible for some amount of node construction is a very leaky abstraction,
-- and requires giving it access to a lot of context it's otherwise not required to have, which also further complicates the API
-- and likely reduces performance. There's probably some refactoring that could be done here to simplify this.

function EmitResolver:CreateReturnTypeOfSignatureDeclaration(emitContext, signatureDeclaration, enclosingDeclaration, flags, internalFlags, tracker)
    local original = emitContext:ParseNode(signatureDeclaration)
    if original == nil then
        return emitContext.factory:NewKeywordTypeNode(Kind.AnyKeyword)
    end

    local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
    return requestNodeBuilder:SerializeReturnTypeForSignature(original, enclosingDeclaration, flags, internalFlags, tracker)
end

function EmitResolver:CreateTypeParametersOfSignatureDeclaration(emitContext, signatureDeclaration, enclosingDeclaration, flags, internalFlags, tracker)
    local original = emitContext:ParseNode(signatureDeclaration)
    if original == nil then
        return nil
    end

    local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
    return requestNodeBuilder:SerializeTypeParametersForSignature(original, enclosingDeclaration, flags, internalFlags, tracker)
end

function EmitResolver:CreateTypeOfDeclaration(emitContext, declaration, enclosingDeclaration, flags, internalFlags, tracker)
    local original = emitContext:ParseNode(declaration)
    if original == nil then
        return emitContext.factory:NewKeywordTypeNode(Kind.AnyKeyword)
    end

    local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
    -- // Get type of the symbol if this is the valid symbol otherwise get type at location
    local symbol = self.checker:getSymbolOfDeclaration(declaration)
    return requestNodeBuilder:SerializeTypeForDeclaration(declaration, symbol, enclosingDeclaration, flags | nodebuilder.Flags.MultilineObjectLiterals, internalFlags, tracker)
end

function EmitResolver:CreateLiteralConstValue(emitContext, node, tracker)
    node = emitContext:ParseNode(node)
    local t = self.checker:getTypeOfSymbol(self.checker:getSymbolOfDeclaration(node))
    if t == nil then
        return nil -- TODO: How!? Maybe this should be a panic. All symbols should have a type.
    end

    local factory = emitContext.factory
    local enumResult
    if t.flags & TypeFlags.EnumLike ~= 0 then
        local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
        enumResult = requestNodeBuilder:SymbolToExpression(t.symbol, SymbolFlags.Value, node, nodebuilder.Flags.None, nodebuilder.InternalFlags.None, tracker)
        -- What about regularTrueType/regularFalseType - since those aren't fresh, we never make initializers from them
        -- TODO: handle those if this function is ever used for more than initializers in declaration emit
    elseif t == self.checker.trueType then
        enumResult = factory:NewKeywordExpression(Kind.TrueKeyword)
    elseif t == self.checker.falseType then
        enumResult = factory:NewKeywordExpression(Kind.FalseKeyword)
    end
    if enumResult ~= nil then
        return enumResult
    end
    if t.flags & TypeFlags.Literal == 0 then
        return nil -- non-literal type
    end
    local value = t:AsLiteralType().value
    local vt = type(value)
    if vt == "string" then
        return factory:NewStringLiteral(value, ast.TokenFlags.None)
    elseif vt == "number" then
        if jsnum.Number_IsInf(value) then
            if value > 0 then
                return factory:NewIdentifier("Infinity")
            end
            return factory:NewPrefixUnaryExpression(Kind.MinusToken, factory:NewIdentifier("Infinity"))
        end
        if jsnum.Number_IsNaN(value) then
            return factory:NewIdentifier("NaN")
        end
        if jsnum.Number_Abs(value) ~= value then
            -- negative
            return factory:NewPrefixUnaryExpression(
                Kind.MinusToken,
                factory:NewNumericLiteral(string.sub(jsnum.Number_String(value), 2), ast.TokenFlags.None)
            )
        end
        return factory:NewNumericLiteral(jsnum.Number_String(value), ast.TokenFlags.None)
    elseif vt == "table" and getmetatable(value) == jsnum.PseudoBigInt then
        return factory:NewBigIntLiteral(checker.pseudoBigIntToString(value) .. "n", ast.TokenFlags.None)
    elseif vt == "boolean" then
        local kind = Kind.FalseKeyword
        if value then
            kind = Kind.TrueKeyword
        end
        return factory:NewKeywordExpression(kind)
    end
    error("unhandled literal const value kind", 0)
end

function EmitResolver:CreateTypeOfExpression(emitContext, expression, enclosingDeclaration, flags, internalFlags, tracker)
    expression = emitContext:ParseNode(expression)
    if expression == nil then
        return emitContext.factory:NewKeywordTypeNode(Kind.AnyKeyword)
    end

    local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
    return requestNodeBuilder:SerializeTypeForExpression(expression, enclosingDeclaration, flags | nodebuilder.Flags.MultilineObjectLiterals, internalFlags, tracker)
end

function EmitResolver:CreateLateBoundIndexSignatures(emitContext, container, enclosingDeclaration, flags, internalFlags, tracker)
    container = emitContext:ParseNode(container)
    local c = self.checker
    local factory = emitContext.factory

    local sym = container:Symbol()
    local staticInfos = c:getIndexInfosOfType(c:getTypeOfSymbol(sym))
    local instanceIndexSymbol = c:getIndexSymbol(sym)
    local instanceInfos
    if instanceIndexSymbol ~= nil then
        -- Go collects the map values in random order; sort them for a deterministic result.
        local siblingSymbols = {}
        for _, s in pairs(c:getMembersOfSymbol(sym) or {}) do
            siblingSymbols[#siblingSymbols + 1] = s
        end
        c:sortSymbols(siblingSymbols)
        instanceInfos = c:getIndexInfosOfIndexSymbol(instanceIndexSymbol, siblingSymbols)
    end

    local requestNodeBuilder = checker.NewNodeBuilder(c, emitContext) -- TODO: cache per-context

    local result
    for i1, infoList in ipairs({ staticInfos or false, instanceInfos or false }) do
        local i = i1 - 1
        local isStatic = true
        if i > 0 then
            isStatic = false
        end
        if not infoList or #infoList == 0 then
            goto continueList
        end
        for _, info in ipairs(infoList) do
            if info.declaration ~= nil then
                goto continue
            end
            if info == c.anyBaseTypeIndexInfo then
                goto continue -- inherited, but looks like a late-bound signature because it has no declarations
            end
            if core.Len(info.components) ~= 0 then
                -- !!! TODO: Complete late-bound index info support - getObjectLiteralIndexInfo does not yet add late bound components to index signatures
                local allComponentComputedNamesSerializable = enclosingDeclaration ~= nil and core.Every(info.components, function(comp)
                    return comp:Name() ~= nil and
                        ast.IsComputedPropertyName(comp:Name()) and
                        ast.IsEntityNameExpression(comp:Name():Expression()) and
                        self:isEntityNameVisible(comp:Name():Expression(), enclosingDeclaration, false).accessibility == SymbolAccessibility.Accessible
                end)
                if allComponentComputedNamesSerializable then
                    for _, comp in ipairs(info.components) do
                        if c:hasLateBindableName(comp) then
                            -- skip late bound props that contribute to the index signature - they'll be preserved via other means
                            goto continueComp
                        end

                        do
                            local firstIdentifier = ast.GetFirstIdentifier(comp:Name():Expression())
                            local name = c.resolveName(firstIdentifier, firstIdentifier:Text(), SymbolFlags.Value | SymbolFlags.ExportValue, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]])
                            if name ~= nil then
                                tracker:TrackSymbol(name, enclosingDeclaration, SymbolFlags.Value)
                            end

                            local staticModifier = factory:NewModifier(Kind.StaticKeyword)
                            local mods
                            if isStatic then
                                mods = { staticModifier }
                            end
                            if info.isReadonly then
                                mods = core.Append(mods, factory:NewModifier(Kind.ReadonlyKeyword))
                            end

                            local modifierList
                            if mods ~= nil then
                                modifierList = factory:NewModifierList(mods)
                            end
                            local decl = factory:NewPropertyDeclaration(
                                modifierList,
                                comp:Name(),
                                comp:QuestionToken(),
                                requestNodeBuilder:TypeToTypeNode(c:getTypeOfSymbol(comp:Symbol()), enclosingDeclaration, flags, internalFlags, tracker),
                                nil
                            )
                            result = core.Append(result, decl)
                        end
                        ::continueComp::
                    end
                    goto continue
                end
            end
            do
                local node = requestNodeBuilder:IndexInfoToIndexSignatureDeclaration(info, enclosingDeclaration, flags, internalFlags, tracker)
                if node ~= nil and isStatic then
                    local modNodes = { factory:NewModifier(Kind.StaticKeyword) }
                    for _, m in ipairs(node:ModifierNodes() or {}) do
                        modNodes[#modNodes + 1] = m
                    end
                    local mods = factory:NewModifierList(modNodes)
                    node = factory:UpdateIndexSignatureDeclaration(
                        node:AsIndexSignatureDeclaration(),
                        mods,
                        node:ParameterList(),
                        node:Type()
                    )
                end
                if node ~= nil then
                    result = core.Append(result, node)
                end
            end
            ::continue::
        end
        ::continueList::
    end
    return result
end

function EmitResolver:GetEffectiveDeclarationFlags(node, flags)
    -- node = emitContext.ParseNode(node)
    return self.checker:GetEffectiveDeclarationFlags(node, flags)
end

function EmitResolver:GetResolutionModeOverride(node)
    -- node = emitContext.ParseNode(node)
    return self.checker:GetResolutionModeOverride(node:AsImportAttributes(), false)
end

function EmitResolver:GetConstantValue(node)
    -- node = emitContext.ParseNode(node)
    return self.checker:GetConstantValue(node)
end

function EmitResolver:GetTypeReferenceSerializationKind(typeName, location)
    -- typeName = emitContext.ParseNode(typeName)
    -- location = emitContext.ParseNode(location)
    local c = self.checker

    if typeName == nil or location == nil then
        return printer.TypeReferenceSerializationKindUnknown
    end

    -- Resolve the symbol as a value to ensure the type can be reached at runtime during emit.
    local isTypeOnly = false
    if ast.IsQualifiedName(typeName) then
        local rootValueSymbol = c:resolveEntityName(ast.GetFirstIdentifier(typeName), SymbolFlags.Value, true, true, location)

        if rootValueSymbol ~= nil and core.Len(rootValueSymbol.declarations) > 0 then
            isTypeOnly = core.Every(rootValueSymbol.declarations, function(d)
                return ast.IsTypeOnlyImportOrExportDeclaration(d)
            end)
        end
    end
    local valueSymbol = c:resolveEntityName(typeName, SymbolFlags.Value, true, true, location)
    local resolvedValueSymbol = valueSymbol
    if valueSymbol ~= nil and valueSymbol.flags & SymbolFlags.Alias ~= 0 then
        resolvedValueSymbol = c:resolveAlias(valueSymbol)
    end

    isTypeOnly = isTypeOnly or (valueSymbol ~= nil and c:getTypeOnlyAliasDeclarationEx(valueSymbol, SymbolFlags.Value) ~= nil)

    -- Resolve the symbol as a type so that we can provide a more useful hint for the type serializer.
    local typeSymbol = c:resolveEntityName(typeName, SymbolFlags.Type, true, true, location)
    local resolvedTypeSymbol = typeSymbol
    if typeSymbol ~= nil and typeSymbol.flags & SymbolFlags.Alias ~= 0 then
        resolvedTypeSymbol = c:resolveAlias(typeSymbol)
    end
    -- In case the value symbol can't be resolved (e.g. because of missing declarations), use type symbol for reachability check.
    isTypeOnly = isTypeOnly or (typeSymbol ~= nil and c:getTypeOnlyAliasDeclarationEx(typeSymbol, SymbolFlags.Type) ~= nil)

    if resolvedValueSymbol ~= nil and resolvedValueSymbol == resolvedTypeSymbol then
        local globalPromiseSymbol = c.getGlobalPromiseConstructorSymbol()
        if globalPromiseSymbol ~= nil and resolvedValueSymbol == globalPromiseSymbol then
            return printer.TypeReferenceSerializationKindPromise
        end

        local constructorType = c:getTypeOfSymbol(resolvedValueSymbol)
        if constructorType ~= nil and c:isConstructorType(constructorType) then
            if isTypeOnly then
                return printer.TypeReferenceSerializationKindTypeWithCallSignature
            end
            return printer.TypeReferenceSerializationKindTypeWithConstructSignatureAndValue
        end
    end

    -- We might not be able to resolve type symbol so use unknown type in that case (eg error case)
    if resolvedTypeSymbol == nil then
        if isTypeOnly then
            return printer.TypeReferenceSerializationKindObjectType
        end
        return printer.TypeReferenceSerializationKindUnknown
    end

    local type_ = c:getDeclaredTypeOfSymbol(resolvedTypeSymbol)
    if c:isErrorType(type_) then
        if isTypeOnly then
            return printer.TypeReferenceSerializationKindObjectType
        end
        return printer.TypeReferenceSerializationKindUnknown
    end

    if type_.flags & TypeFlags.AnyOrUnknown ~= 0 then
        return printer.TypeReferenceSerializationKindObjectType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.Void | TypeFlags.Nullable | TypeFlags.Never) then
        return printer.TypeReferenceSerializationKindVoidNullableOrNeverType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.BooleanLike) then
        return printer.TypeReferenceSerializationKindBooleanType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.NumberLike) then
        return printer.TypeReferenceSerializationKindNumberLikeType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.BigIntLike) then
        return printer.TypeReferenceSerializationKindBigIntLikeType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.StringLike) then
        return printer.TypeReferenceSerializationKindStringLikeType
    elseif checker.isTupleType(type_) then
        return printer.TypeReferenceSerializationKindArrayLikeType
    elseif c:isTypeAssignableToKind(type_, TypeFlags.ESSymbolLike) then
        return printer.TypeReferenceSerializationKindESSymbolType
    elseif c:isFunctionType(type_) then
        return printer.TypeReferenceSerializationKindTypeWithCallSignature
    elseif c:isArrayType(type_) then
        return printer.TypeReferenceSerializationKindArrayLikeType
    else
        return printer.TypeReferenceSerializationKindObjectType
    end
end

function EmitResolver:GetPropertiesOfContainerFunction(node)
    -- This is explicitly _not locked_ because it is only called via error reporters invoked via node builder calls
    -- to the symbol tracker already within locked contexts.
    if node == nil then
        return {}
    end
    local s = self.checker:getSymbolOfDeclaration(node)
    if s == nil then
        return {}
    end
    return self.checker:getPropertiesOfType(self.checker:getTypeOfSymbol(s))
end

function EmitResolver:TryJSTypeNodeToTypeNode(emitContext, typeNode, enclosingDeclaration, flags, internalFlags, tracker)
    typeNode = emitContext:ParseNode(typeNode)

    local requestNodeBuilder = checker.NewNodeBuilder(self.checker, emitContext) -- TODO: cache per-context
    return requestNodeBuilder:TryJSTypeNodeToTypeNode(typeNode, enclosingDeclaration, flags, internalFlags, tracker)
end

-- IsThisPropertyAssignmentDeclarationRedundant reports whether a JS `this.<name> = ...` expando
-- assignment should be omitted from declaration emit because the member it would synthesize is
-- already provided by an `extends` base type. This mirrors the skip condition in the checker's
-- serializePropertySymbol: an inherited member is redundant when it is identical to the assigned
-- one (same readonly-ness, optionality and type). Inherited accessors and methods are always
-- treated as redundant here, since accessors merge oddly with value assignments (and run via the
-- accessor at runtime), and `this`-expando props carry the ReplaceableByMethod contract, so a
-- rebind such as `this.method = this.method.bind(this)` must not override the base method.
--
-- Only `extends` base types are considered. Members coming from `implements` clauses are not
-- inherited, so the class must redeclare them, and they are always emitted.
function EmitResolver:IsThisPropertyAssignmentDeclarationRedundant(node)
    if node == nil then
        return false
    end

    local c = self.checker
    local s = c:getSymbolOfDeclaration(node)
    if s == nil or s.parent == nil then
        return false
    end
    local parentType = c:getDeclaredTypeOfSymbol(s.parent)
    if parentType == nil then
        return false
    end
    for _, base in ipairs(c:getBaseTypes(parentType) or {}) do
        local baseProp = c:getPropertyOfType(base, s.name)
        if baseProp ~= nil then
            if baseProp.flags & (SymbolFlags.Accessor | SymbolFlags.Method | SymbolFlags.Function) ~= 0 then
                return true
            end
            if c:isReadonlySymbol(baseProp) == c:isReadonlySymbol(s) and
                (s.flags & SymbolFlags.Optional) == (baseProp.flags & SymbolFlags.Optional) and
                c:isTypeIdenticalTo(c:getTypeOfSymbol(s), c:getTypeOfSymbol(baseProp)) then
                return true
            end
        end
    end
    return false
end
