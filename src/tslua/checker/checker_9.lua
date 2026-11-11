local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local evaluator = require("tslua.evaluator")
local debug = require("tslua.debug")
local stringutil = require("tslua.stringutil")
local jsnum = require("tslua.jsnum")
local binder = require("tslua.binder")

local Checker = checker.Checker
local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local SignatureKind = checker.SignatureKind
local CheckMode = checker.CheckMode
local ContextFlags = checker.ContextFlags
local TypeFacts = checker.TypeFacts
local CachedTypeKind = checker.CachedTypeKind
local ExternalEmitHelpers = checker.ExternalEmitHelpers
local MappedTypeModifiers = checker.MappedTypeModifiers
local IntrinsicTypeKind = checker.IntrinsicTypeKind
local IterationTypeKind = checker.IterationTypeKind
local IterationUse = checker.IterationUse
local UnionReduction = checker.UnionReduction
local ElementFlags = checker.ElementFlags
local AccessFlags = checker.AccessFlags
local InferenceFlags = checker.InferenceFlags
local AssignmentKind = checker.AssignmentKind
local SymbolFlags = ast.SymbolFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local FunctionFlags = ast.FunctionFlags
local JSDeclarationKind = ast.JSDeclarationKind
local ModuleKind = core.ModuleKind

-- Go slices.Contains
local function slicesContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- Go slices.Clone
local function slicesClone(xs)
    if xs == nil then
        return nil
    end
    local result = {}
    for i, x in ipairs(xs) do
        result[i] = x
    end
    return result
end

function Checker:checkExternalEmitHelpers(location, helpers)
    if not core.Tristate_IsTrue(self.compilerOptions.importHelpers) then
        return
    end
    local sourceFile = ast.GetSourceFileOfNode(location)
    if not ast.IsEffectiveExternalModule(sourceFile, self.compilerOptions) or location.flags & NodeFlags.Ambient ~= 0 then
        return
    end
    local helpersModule = self:resolveHelpersModule(sourceFile, location)
    if helpersModule == self.unknownSymbol then
        return
    end
    local links = self.sourceFileLinks:Get(sourceFile)
    if links.requestedExternalEmitHelpers & helpers ~= helpers then
        local uncheckedHelpers = helpers & ~links.requestedExternalEmitHelpers
        local helper = ExternalEmitHelpers.FirstEmitHelper
        while helper <= ExternalEmitHelpers.LastEmitHelper do
            if uncheckedHelpers & helper == 0 then
                goto continue
            end
            for _, name in ipairs(self:getHelperNames(helper)) do
                local symbol = self:resolveSymbol(self:getSymbol(self:getExportsOfModule(helpersModule), name, SymbolFlags.Value))
                if symbol == nil then
                    self:error(location, diagnostics.This_syntax_requires_an_imported_helper_named_1_which_does_not_exist_in_0_Consider_upgrading_your_version_of_0, checker.externalHelpersModuleNameText, name)
                elseif helper & ExternalEmitHelpers.ClassPrivateFieldGet ~= 0 then
                    if not self:hasSignatureWithArityGreaterThan(symbol, 3) then
                        self:error(location, diagnostics.This_syntax_requires_an_imported_helper_named_1_with_2_parameters_which_is_not_compatible_with_the_one_in_0_Consider_upgrading_your_version_of_0, checker.externalHelpersModuleNameText, name, 4)
                    end
                elseif helper & ExternalEmitHelpers.ClassPrivateFieldSet ~= 0 then
                    if not self:hasSignatureWithArityGreaterThan(symbol, 4) then
                        self:error(location, diagnostics.This_syntax_requires_an_imported_helper_named_1_with_2_parameters_which_is_not_compatible_with_the_one_in_0_Consider_upgrading_your_version_of_0, checker.externalHelpersModuleNameText, name, 5)
                    end
                end
            end
            ::continue::
            helper = helper << 1
        end
    end
    links.requestedExternalEmitHelpers = links.requestedExternalEmitHelpers | helpers
end

function Checker:hasSignatureWithArityGreaterThan(symbol, arity)
    for _, signature in ipairs(self:getSignaturesOfSymbol(symbol) or {}) do
        if self:getParameterCount(signature) > arity then
            return true
        end
    end
    return false
end

function Checker:getHelperNames(helper)
    local H = ExternalEmitHelpers
    if helper == H.Rest then
        return { "__rest" }
    elseif helper == H.Decorate then
        if self.legacyDecorators then
            return { "__decorate" }
        end
        return { "__esDecorate", "__runInitializers" }
    elseif helper == H.Metadata then
        return { "__metadata" }
    elseif helper == H.Param then
        return { "__param" }
    elseif helper == H.Awaiter then
        return { "__awaiter" }
    elseif helper == H.Await then
        return { "__await" }
    elseif helper == H.AsyncGenerator then
        return { "__asyncGenerator" }
    elseif helper == H.AsyncDelegator then
        return { "__asyncDelegator" }
    elseif helper == H.AsyncValues then
        return { "__asyncValues" }
    elseif helper == H.ExportStar then
        return { "__exportStar" }
    elseif helper == H.ImportStar then
        return { "__importStar" }
    elseif helper == H.ImportDefault then
        return { "__importDefault" }
    elseif helper == H.MakeTemplateObject then
        return { "__makeTemplateObject" }
    elseif helper == H.ClassPrivateFieldGet then
        return { "__classPrivateFieldGet" }
    elseif helper == H.ClassPrivateFieldSet then
        return { "__classPrivateFieldSet" }
    elseif helper == H.ClassPrivateFieldIn then
        return { "__classPrivateFieldIn" }
    elseif helper == H.SetFunctionName then
        return { "__setFunctionName" }
    elseif helper == H.PropKey then
        return { "__propKey" }
    elseif helper == H.AddDisposableResourceAndDisposeResources then
        return { "__addDisposableResource", "__disposeResources" }
    elseif helper == H.RewriteRelativeImportExtension then
        return { "__rewriteRelativeImportExtension" }
    else
        error("Unrecognized helper", 0)
    end
end

function Checker:resolveHelpersModule(file, errorNode)
    local links = self.sourceFileLinks:Get(file)
    if links.externalHelpersModule == nil then
        local location = self.program:GetImportHelpersImportSpecifier(file:Path())
        local helpersModule = self:resolveExternalModule(location, checker.externalHelpersModuleNameText, diagnostics.This_syntax_requires_an_imported_helper_but_module_0_cannot_be_found, errorNode, false --[[isForAugmentation]])
        if helpersModule == nil then
            helpersModule = self.unknownSymbol
        end
        links.externalHelpersModule = helpersModule
    end
    return links.externalHelpersModule
end

function Checker:markDecoratorAliasReferenced(node --[[HasDecorators]])
    if core.Tristate_IsFalseOrUnknown(self.compilerOptions.emitDecoratorMetadata) then
        return
    end
    local firstDecorator = core.FirstOrNil(node:Decorators())
    if firstDecorator == nil then
        return
    end

    self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.Metadata)

    -- we only need to perform these checks if we are emitting serialized type metadata for the target of a decorator.
    local k = node.kind
    if k == Kind.ClassDeclaration then
        local ctor = ast.GetFirstConstructorWithBody(node)
        if ctor ~= nil then
            for _, p in ipairs(ctor:Parameters() or {}) do
                self:markDecoratorMedataDataTypeNodeAsReferenced(self:getParameterTypeNodeForDecoratorCheck(p))
            end
        end
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor then
        local otherKind = Kind.SetAccessor
        if node.kind == Kind.SetAccessor then
            otherKind = Kind.GetAccessor
        end
        local otherAccessor = ast.GetDeclarationOfKind(self:getSymbolOfDeclaration(node), otherKind)
        local annotation = self:getAnnotatedAccessorTypeNode(node)
        if annotation == nil and otherAccessor ~= nil then
            annotation = self:getAnnotatedAccessorTypeNode(otherAccessor)
        end
        self:markDecoratorMedataDataTypeNodeAsReferenced(annotation)
    elseif k == Kind.MethodDeclaration then
        for _, p in ipairs(node:Parameters() or {}) do
            self:markDecoratorMedataDataTypeNodeAsReferenced(self:getParameterTypeNodeForDecoratorCheck(p))
        end
        self:markDecoratorMedataDataTypeNodeAsReferenced(node:Type())
    elseif k == Kind.PropertyDeclaration then
        self:markDecoratorMedataDataTypeNodeAsReferenced(node:Type())
    elseif k == Kind.Parameter then
        self:markDecoratorMedataDataTypeNodeAsReferenced(self:getParameterTypeNodeForDecoratorCheck(node))
        local containingSignature = node.parent
        for _, p in ipairs(containingSignature:Parameters() or {}) do
            self:markDecoratorMedataDataTypeNodeAsReferenced(self:getParameterTypeNodeForDecoratorCheck(p))
        end
        self:markDecoratorMedataDataTypeNodeAsReferenced(containingSignature:Type())
    end
end

function Checker:getParameterTypeNodeForDecoratorCheck(node)
    local typeNode = node:Type()
    if node:AsParameterDeclaration().dotDotDotToken ~= nil then
        return ast.GetRestParameterElementType(typeNode)
    end
    return typeNode
end

function Checker:markDecoratorMedataDataTypeNodeAsReferenced(node --[[TypeNode]])
    local entityName = self:getEntityNameForDecoratorMetadata(node)
    if entityName ~= nil and ast.IsEntityName(entityName) then
        self:markEntityNameOrEntityExpressionAsReference(entityName, true)
    end
end

function Checker:getEntityNameForDecoratorMetadata(node)
    if node == nil then
        return node
    end
    local k = node.kind
    if k == Kind.IntersectionType then
        return self:getEntityNameForDecoratorMetadataFromTypeList(node:AsIntersectionTypeNode().types.nodes)
    elseif k == Kind.UnionType then
        return self:getEntityNameForDecoratorMetadataFromTypeList(node:AsUnionTypeNode().types.nodes)
    elseif k == Kind.ConditionalType then
        return self:getEntityNameForDecoratorMetadataFromTypeList({ node:AsConditionalTypeNode().trueType, node:AsConditionalTypeNode().falseType })
    elseif k == Kind.ParenthesizedType then
        return self:getEntityNameForDecoratorMetadata(node:AsParenthesizedTypeNode().type)
    elseif k == Kind.NamedTupleMember then
        return self:getEntityNameForDecoratorMetadata(node:AsNamedTupleMember().type)
    elseif k == Kind.TypeReference then
        return node:AsTypeReferenceNode().typeName
    end
    return nil
end

function Checker:getEntityNameForDecoratorMetadataFromTypeList(typeNodes)
    local commonEntityName
    for _, typeNode in ipairs(typeNodes or {}) do
        if typeNode.kind == Kind.NeverKeyword then
            goto continue -- Always elide `never` from the union/intersection if possible
        end
        if not self.strictNullChecks and (typeNode.kind == Kind.LiteralType and typeNode:AsLiteralTypeNode().literal.kind == Kind.NullKeyword or typeNode.kind == Kind.UndefinedKeyword) then
            goto continue -- Elide null and undefined from unions for metadata, just like what we did prior to the implementation of strict null checks
        end
        do
            local individualEntityName = self:getEntityNameForDecoratorMetadata(typeNode)
            if individualEntityName == nil then
                -- Individual is something like string number
                -- So it would be serialized to either that type or object
                -- Safe to return here
                return nil
            end

            if commonEntityName == nil then
                commonEntityName = individualEntityName
            else
                -- Note this is in sync with the transformation that happens for type node.
                -- Keep this in sync with serializeUnionOrIntersectionType
                -- Verify if they refer to same entity and is identifier
                -- return undefined if they dont match because we would emit object
                if not ast.IsIdentifier(commonEntityName) or not ast.IsIdentifier(individualEntityName) or commonEntityName:AsIdentifier().text ~= individualEntityName:AsIdentifier().text then
                    return nil
                end
            end
        end
        ::continue::
    end
    return commonEntityName
end

function Checker:markAliasReferenced(symbol, location)
    if not self.canCollectSymbolAliasAccessibilityData then
        return
    end
    if ast.IsNonLocalAlias(symbol, SymbolFlags.Value --[[excludes]]) and not checker.IsInTypeQuery(location) then
        local target = self:resolveAlias(symbol)
        if self:getSymbolFlagsEx(symbol, true --[[excludeTypeOnlyMeanings]], false --[[excludeLocalMeanings]]) & (SymbolFlags.Value | SymbolFlags.ExportValue) ~= 0 then
            -- An alias resolving to a const enum cannot be elided if (1) 'isolatedModules' is enabled
            -- (because the const enum value will not be inlined), or if (2) the alias is an export
            -- of a const enum declaration that will be preserved.
            if self.compilerOptions:GetIsolatedModules() or
                self.compilerOptions:ShouldPreserveConstEnums() and checker.isExportOrExportExpression(location) or
                not checker.isConstEnumOrConstEnumOnlyModule(self:getExportSymbolOfValueSymbolIfExported(target)) then
                self:markAliasSymbolAsReferenced(symbol)
            end
        end
    end
end

-- When an alias symbol is referenced, we need to mark the entity it references as referenced and in turn repeat that until
-- we reach a non-alias or an exported entity (which is always considered referenced). We do this by checking the target of
-- the alias as an expression (which recursively takes us back here if the target references another alias).
function Checker:markAliasSymbolAsReferenced(symbol)
    local links = self.aliasSymbolLinks:Get(symbol)
    if not links.referenced then
        links.referenced = true
        local node = self:getDeclarationOfAliasSymbol(symbol)
        if node == nil then
            error("Unexpected nil in markAliasSymbolAsReferenced", 0)
        end
        -- We defer checking of the reference of an `import =` until the import itself is referenced,
        -- This way a chain of imports can be elided if ultimately the final input is only used in a type
        -- position.
        if ast.IsImportEqualsDeclaration(node) and node:AsImportEqualsDeclaration().moduleReference.kind ~= Kind.ExternalModuleReference then
            if self:getSymbolFlags(self:resolveSymbol(symbol)) & SymbolFlags.Value ~= 0 then
                -- import foo = <symbol>
                local left = ast.GetFirstIdentifier(node:AsImportEqualsDeclaration().moduleReference)
                self:markIdentifierAliasReferenced(left)
            end
        end
    end
end

function Checker:markExportAsReferenced(node --[[ImportEqualsDeclaration | ExportSpecifier]])
    local symbol = self:getSymbolOfDeclaration(node)
    local target = self:resolveAlias(symbol)
    if target ~= nil then
        local markAlias = target == self.unknownSymbol or
            ((self:getSymbolFlagsEx(symbol, true --[[excludeTypeOnlyMeanings]], false --[[excludeLocalMeanings]]) & SymbolFlags.Value ~= 0) and not checker.isConstEnumOrConstEnumOnlyModule(target))
        if markAlias then
            self:markAliasSymbolAsReferenced(symbol)
        end
    end
end

function Checker:markEntityNameOrEntityExpressionAsReference(typeName --[[EntityNameOrEntityNameExpression | nil]], forDecoratorMetadata)
    if typeName == nil then
        return
    end

    local rootName = ast.GetFirstIdentifier(typeName)
    local meaning = core.IfElse(typeName.kind == Kind.Identifier, SymbolFlags.Type, SymbolFlags.Namespace) | SymbolFlags.Alias
    local rootSymbol = self.resolveName(rootName, rootName:Text(), meaning, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]])

    if rootSymbol ~= nil and rootSymbol.flags & SymbolFlags.Alias ~= 0 then
        if self.canCollectSymbolAliasAccessibilityData and
            self:symbolIsValue(rootSymbol) and
            not checker.isConstEnumOrConstEnumOnlyModule(self:resolveAlias(rootSymbol)) and
            self:getTypeOnlyAliasDeclaration(rootSymbol) == nil then
            self:markAliasSymbolAsReferenced(rootSymbol)
        elseif forDecoratorMetadata and
            self.compilerOptions:GetIsolatedModules() and
            self.compilerOptions:GetEmitModuleKind() >= ModuleKind.ES2015 and
            not self:symbolIsValue(rootSymbol) and
            not core.Some(rootSymbol.declarations, ast.IsTypeOnlyImportOrExportDeclaration) then
            local diag = self:error(typeName, diagnostics.A_type_referenced_in_a_decorated_signature_must_be_imported_with_import_type_or_a_namespace_import_when_isolatedModules_and_emitDecoratorMetadata_are_enabled)
            local aliasDeclaration
            for _, decl in ipairs(rootSymbol.declarations or {}) do
                if ast.IsAliasSymbolDeclaration(decl) then
                    aliasDeclaration = decl
                    break
                end
            end
            if aliasDeclaration ~= nil then
                diag:SetRelatedInfo({ checker.createDiagnosticForNode(aliasDeclaration, diagnostics.X_0_was_imported_here, rootName:Text()) })
            end
        end
    end
end

function checker.getEntityNameFromTypeNode(node)
    local k = node.kind
    if k == Kind.TypeReference then
        return node:AsTypeReferenceNode().typeName
    elseif k == Kind.ExpressionWithTypeArguments then
        if ast.IsEntityNameExpression(node:Expression()) then
            return node:Expression()
        end
        return nil
    elseif k == Kind.Identifier or k == Kind.QualifiedName then
        -- These aren't valid TypeNodes, but we treat them as such because of `isPartOfTypeNode`, which returns `true` for things that aren't `TypeNode`s.
        return node
    end

    return nil
end

-- If a TypeNode can be resolved to a value symbol imported from an external module, it is
-- marked as referenced to prevent import elision.
function Checker:markTypeNodeAsReferenced(node)
    if node ~= nil then
        self:markEntityNameOrEntityExpressionAsReference(checker.getEntityNameFromTypeNode(node), false --[[forDecoratorMetadata]])
    end
end

function Checker:GetPromisedTypeOfPromise(t)
    return self:getPromisedTypeOfPromiseEx(t, nil, nil)
end

-- Gets the "promised type" of a promise.
-- @param type The type of the promise.
-- @remarks The "promised type" of a type is the type of the "value" parameter of the "onfulfilled" callback.
-- thisTypeForErrorOut (Go **Type) is nil or a table whose `value` field receives the result.
function Checker:getPromisedTypeOfPromiseEx(t, errorNode, thisTypeForErrorOut)
    --  { // type
    --      then( // thenFunction
    --          onfulfilled: ( // onfulfilledParameterType
    --              value: T // valueParameterType
    --          ) => any
    --      ): any;
    --  }
    if checker.IsTypeAny(t) then
        return nil
    end
    local key = checker.CachedTypeKey(CachedTypeKind.PromisedTypeOfPromise, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    if self:isReferenceToType(t, self.getGlobalPromiseType()) then
        local result = self:getTypeArguments(t)[1]
        self.cachedTypes[key] = result
        return result
    end
    -- primitives with a `{ then() }` won't be unwrapped/adopted.
    if self:allTypesAssignableToKind(self:getBaseConstraintOrType(t), TypeFlags.Primitive | TypeFlags.Never) then
        return nil
    end
    local thenFunction = self:getTypeOfPropertyOfType(t, "then")
    -- TODO: GH#18217
    if checker.IsTypeAny(thenFunction) then
        return nil
    end
    local thenSignatures
    if thenFunction ~= nil then
        thenSignatures = self:getSignaturesOfType(thenFunction, SignatureKind.Call)
    end
    if core.Len(thenSignatures) == 0 then
        if errorNode ~= nil then
            self:error(errorNode, diagnostics.A_promise_must_have_a_then_method)
        end
        return nil
    end
    local thisTypeForError
    local candidates = {}
    for _, thenSignature in ipairs(thenSignatures) do
        local thisType = self:getThisTypeOfSignature(thenSignature)
        if thisType ~= nil and thisType ~= self.voidType and not self:isTypeRelatedTo(t, thisType, self.subtypeRelation) then
            thisTypeForError = thisType
        else
            candidates[#candidates + 1] = thenSignature
        end
    end
    if #candidates == 0 then
        debug.Assert(thisTypeForError ~= nil)
        if thisTypeForErrorOut ~= nil then
            thisTypeForErrorOut.value = thisTypeForError
        end
        if errorNode ~= nil then
            self:error(errorNode, diagnostics.The_this_context_of_type_0_is_not_assignable_to_method_s_this_of_type_1, self:TypeToString(t), self:TypeToString(thisTypeForError))
        end
        return nil
    end
    local onfulfilledParameterType = self:getTypeWithFacts(self:getUnionType(core.Map(candidates, function(s) return self:getTypeOfFirstParameterOfSignature(s) end)), TypeFacts.NEUndefinedOrNull)
    if checker.IsTypeAny(onfulfilledParameterType) then
        return nil
    end
    local onfulfilledParameterSignatures = self:getSignaturesOfType(onfulfilledParameterType, SignatureKind.Call)
    if core.Len(onfulfilledParameterSignatures) == 0 then
        if errorNode ~= nil then
            self:error(errorNode, diagnostics.The_first_parameter_of_the_then_method_of_a_promise_must_be_a_callback)
        end
        return nil
    end
    local result = self:getUnionTypeEx(core.Map(onfulfilledParameterSignatures, function(s) return self:getTypeOfFirstParameterOfSignature(s) end), UnionReduction.Subtype, nil, nil)
    self.cachedTypes[key] = result
    return result
end

function Checker:getTypeOfFirstParameterOfSignature(signature)
    return self:getTypeOfFirstParameterOfSignatureWithFallback(signature, self.neverType)
end

function Checker:getTypeOfFirstParameterOfSignatureWithFallback(signature, fallbackType)
    if core.Len(signature.parameters) > 0 then
        return self:getTypeAtPosition(signature, 0)
    end
    return fallbackType
end

function checker.getMappedTypeModifiers(t)
    local declaration = t:AsMappedType().declaration
    local modifiers = 0
    if declaration.readonlyToken ~= nil then
        modifiers = modifiers | core.IfElse(declaration.readonlyToken.kind == Kind.MinusToken, MappedTypeModifiers.ExcludeReadonly, MappedTypeModifiers.IncludeReadonly)
    end
    if declaration.questionToken ~= nil then
        modifiers = modifiers | core.IfElse(declaration.questionToken.kind == Kind.MinusToken, MappedTypeModifiers.ExcludeOptional, MappedTypeModifiers.IncludeOptional)
    end
    return modifiers
end

-- Return -1, 0, or 1, where -1 means optionality is stripped (i.e. -?), 0 means optionality is unchanged, and 1 means
-- optionality is added (i.e. +?).
function checker.getMappedTypeOptionality(t)
    local modifiers = checker.getMappedTypeModifiers(t)
    if modifiers & MappedTypeModifiers.ExcludeOptional ~= 0 then
        return -1
    elseif modifiers & MappedTypeModifiers.IncludeOptional ~= 0 then
        return 1
    end
    return 0
end

-- Return -1, 0, or 1, for stripped, unchanged, or added optionality respectively. When a homomorphic mapped type doesn't
-- modify optionality, recursively consult the optionality of the type being mapped over to see if it strips or adds optionality.
-- For intersections, return -1 or 1 when all constituents strip or add optionality, otherwise return 0.
function Checker:getCombinedMappedTypeOptionality(t)
    if t.objectFlags & ObjectFlags.Mapped ~= 0 then
        local optionality = checker.getMappedTypeOptionality(t)
        if optionality ~= 0 then
            return optionality
        end
        return self:getCombinedMappedTypeOptionality(self:getModifiersTypeFromMappedType(t))
    end
    if t.flags & TypeFlags.Intersection ~= 0 then
        local types = t:Types()
        local optionality = self:getCombinedMappedTypeOptionality(types[1])
        for i = 2, #types do
            if self:getCombinedMappedTypeOptionality(types[i]) ~= optionality then
                return 0
            end
        end
        return optionality
    end
    return 0
end

function checker.isPartialMappedType(t)
    return t.objectFlags & ObjectFlags.Mapped ~= 0 and checker.getMappedTypeModifiers(t) & MappedTypeModifiers.IncludeOptional ~= 0
end

function Checker:getOptionalExpressionType(exprType, expression)
    if ast.IsExpressionOfOptionalChainRoot(expression) then
        return self:GetNonNullableType(exprType)
    elseif ast.IsOptionalChain(expression) then
        return self:removeOptionalTypeMarker(exprType)
    else
        return exprType
    end
end

function Checker:removeOptionalTypeMarker(t)
    if self.strictNullChecks then
        return self:removeType(t, self.optionalType)
    end
    return t
end

function Checker:propagateOptionalTypeMarker(t, node, wasOptional)
    if wasOptional then
        if ast.IsOutermostOptionalChain(node) then
            return self:getOptionalType(t, false)
        end
        return self:addOptionalTypeMarker(t)
    end
    return t
end

function Checker:removeMissingType(t, isOptional)
    if self.exactOptionalPropertyTypes and isOptional then
        return self:removeType(t, self.missingType)
    end
    return t
end

function Checker:removeMissingOrUndefinedType(t)
    if self.exactOptionalPropertyTypes then
        return self:removeType(t, self.missingType)
    end
    return self:getTypeWithFacts(t, TypeFacts.NEUndefined)
end

function Checker:removeDefinitelyFalsyTypes(t)
    return self:filterType(t, function(t_) return self:hasTypeFacts(t_, TypeFacts.Truthy) end)
end

function Checker:extractDefinitelyFalsyTypes(t)
    return self:mapType(t, function(t_) return self:getDefinitelyFalsyPartOfType(t_) end)
end

function Checker:getDefinitelyFalsyPartOfType(t)
    if t.flags & TypeFlags.String ~= 0 then
        return self.emptyStringType
    elseif t.flags & TypeFlags.Number ~= 0 then
        return self.zeroType
    elseif t.flags & TypeFlags.BigInt ~= 0 then
        return self.zeroBigIntType
    elseif t == self.regularFalseType or t == self.falseType or
        t.flags & (TypeFlags.Void | TypeFlags.Undefined | TypeFlags.Null | TypeFlags.AnyOrUnknown) ~= 0 or
        t.flags & TypeFlags.StringLiteral ~= 0 and checker.getStringLiteralValue(t) == "" or
        t.flags & TypeFlags.NumberLiteral ~= 0 and checker.getNumberLiteralValue(t) == 0 or
        t.flags & TypeFlags.BigIntLiteral ~= 0 and checker.isZeroBigInt(t) then
        return t
    end
    return self.neverType
end

function Checker:getConstraintDeclaration(t)
    if t.symbol ~= nil then
        for _, d in ipairs(t.symbol.declarations or {}) do
            if ast.IsTypeParameterDeclaration(d) then
                local constraint = d:AsTypeParameterDeclaration().constraint
                if constraint ~= nil then
                    return constraint
                end
            end
        end
    end
    return nil
end

function Checker:getTemplateLiteralType(texts, types)
    local unionIndex = core.FindIndex(types, function(t)
        return t.flags & (TypeFlags.Never | TypeFlags.Union) ~= 0
    end)
    if unionIndex >= 0 then
        if not self:checkCrossProductUnion(types) then
            return self.errorType
        end
        return self:mapType(types[unionIndex + 1], function(t)
            return self:getTemplateLiteralType(texts, core.ReplaceElement(types, unionIndex, t))
        end)
    end
    if slicesContains(types, self.wildcardType) then
        return self.wildcardType
    end
    local newTypes = {}
    local newTexts = {}
    local sb = { texts[1] }
    local function sbString()
        return table.concat(sb)
    end
    local addSpans
    addSpans = function(texts_, types_)
        for i1, t in ipairs(types_ or {}) do
            if t.flags & (TypeFlags.Literal | TypeFlags.Null | TypeFlags.Undefined) ~= 0 then
                sb[#sb + 1] = self:getTemplateStringForType(t)
                sb[#sb + 1] = texts_[i1 + 1]
            elseif t.flags & TypeFlags.TemplateLiteral ~= 0 then
                sb[#sb + 1] = t:AsTemplateLiteralType().texts[1]
                if not addSpans(t:AsTemplateLiteralType().texts, t:AsTemplateLiteralType().types) then
                    return false
                end
                sb[#sb + 1] = texts_[i1 + 1]
            elseif self:isGenericIndexType(t) or self:isPatternLiteralPlaceholderType(t) then
                newTypes[#newTypes + 1] = t
                newTexts[#newTexts + 1] = stringutil.CombineSurrogatePairs(sbString())
                sb = {}
                sb[#sb + 1] = texts_[i1 + 1]
            else
                return false
            end
        end
        return true
    end
    if not addSpans(texts, types) then
        return self.stringType
    end
    if #newTypes == 0 then
        return self:getStringLiteralType(stringutil.CombineSurrogatePairs(sbString()))
    end
    newTexts[#newTexts + 1] = stringutil.CombineSurrogatePairs(sbString())
    if core.Every(newTexts, function(t) return t == "" end) then
        if core.Every(newTypes, function(t) return t.flags & TypeFlags.String ~= 0 end) then
            return self.stringType
        end
        -- Normalize `${Mapping<xxx>}` into Mapping<xxx>
        if #newTypes == 1 and self:isPatternLiteralType(newTypes[1]) then
            return newTypes[1]
        end
    end
    local key = checker.getTemplateTypeKey(newTexts, newTypes)
    local t = self.templateLiteralTypes[key]
    if t == nil then
        t = self:newTemplateLiteralType(newTexts, newTypes)
        self.templateLiteralTypes[key] = t
    end
    return t
end

function Checker:getTemplateStringForType(t)
    if t.flags & (TypeFlags.StringLiteral | TypeFlags.NumberLiteral | TypeFlags.BooleanLiteral | TypeFlags.BigIntLiteral) ~= 0 then
        return evaluator.AnyToString(t:AsLiteralType().value)
    elseif t.flags & TypeFlags.Nullable ~= 0 then
        return t:AsIntrinsicType().intrinsicName
    end
    return ""
end

function Checker:getStringMappingType(symbol, t)
    if t.flags & (TypeFlags.Union | TypeFlags.Never) ~= 0 then
        return self:mapType(t, function(t_) return self:getStringMappingType(symbol, t_) end)
    elseif t.flags & TypeFlags.StringLiteral ~= 0 then
        return self:getStringLiteralType(checker.applyStringMapping(symbol, checker.getStringLiteralValue(t)))
    elseif t.flags & TypeFlags.TemplateLiteral ~= 0 then
        return self:getTemplateLiteralType(self:applyTemplateStringMapping(symbol, t:AsTemplateLiteralType().texts, t:AsTemplateLiteralType().types))
    elseif t.flags & TypeFlags.StringMapping ~= 0 and symbol == t.symbol then
        return t
    elseif t.flags & (TypeFlags.Any | TypeFlags.String | TypeFlags.StringMapping) ~= 0 or self:isGenericIndexType(t) then
        return self:getStringMappingTypeForGenericType(symbol, t)
    elseif self:isPatternLiteralPlaceholderType(t) then
        return self:getStringMappingTypeForGenericType(symbol, self:getTemplateLiteralType({ "", "" }, { t }))
    else
        return t
    end
end

function checker.applyStringMapping(symbol, str)
    local kind = checker.intrinsicTypeKinds[symbol.name]
    if kind == IntrinsicTypeKind.Uppercase then
        return stringutil.ToUpperJS(str)
    elseif kind == IntrinsicTypeKind.Lowercase then
        return stringutil.ToLowerJS(str)
    elseif kind == IntrinsicTypeKind.Capitalize then
        local _, size = stringutil.DecodeJSStringRune(str)
        return stringutil.ToUpperJS(string.sub(str, 1, size)) .. string.sub(str, size + 1)
    elseif kind == IntrinsicTypeKind.Uncapitalize then
        local _, size = stringutil.DecodeJSStringRune(str)
        return stringutil.ToLowerJS(string.sub(str, 1, size)) .. string.sub(str, size + 1)
    end
    return str
end

function Checker:applyTemplateStringMapping(symbol, texts, types)
    local kind = checker.intrinsicTypeKinds[symbol.name]
    if kind == IntrinsicTypeKind.Uppercase or kind == IntrinsicTypeKind.Lowercase then
        return core.Map(texts, function(t) return checker.applyStringMapping(symbol, t) end),
            core.Map(types, function(t) return self:getStringMappingType(symbol, t) end)
    elseif kind == IntrinsicTypeKind.Capitalize or kind == IntrinsicTypeKind.Uncapitalize then
        if texts[1] ~= "" then
            local newTexts = slicesClone(texts)
            newTexts[1] = checker.applyStringMapping(symbol, newTexts[1])
            return newTexts, types
        end
        local newTypes = slicesClone(types)
        newTypes[1] = self:getStringMappingType(symbol, newTypes[1])
        return texts, newTypes
    end
    return texts, types
end

function Checker:getStringMappingTypeForGenericType(symbol, t)
    local key = checker.StringMappingKey(symbol, t)
    local result = self.stringMappingTypes[key]
    if result == nil then
        result = self:newStringMappingType(symbol, t)
        self.stringMappingTypes[key] = result
    end
    return result
end

-- Given an indexed access on a mapped type of the form { [P in K]: E }[X], return an instantiation of E where P is
-- replaced with X. Since this simplification doesn't account for mapped type modifiers, add 'undefined' to the
-- resulting type if the mapped type includes a '?' modifier or if the modifiers type indicates that some properties
-- are optional. If the modifiers type is generic, conservatively estimate optionality by recursively looking for
-- mapped types that include '?' modifiers.
function Checker:substituteIndexedMappedType(objectType, index)
    local mapper = checker.newSimpleTypeMapper(self:getTypeParameterFromMappedType(objectType), index)
    local templateMapper = self:combineTypeMappers(objectType:AsMappedType().mapper, mapper)
    local instantiatedTemplateType = self:instantiateType(self:getTemplateTypeFromMappedType(core.OrElse(objectType:AsMappedType().target, objectType)), templateMapper)
    local isOptional = checker.getMappedTypeOptionality(objectType) > 0
    if not isOptional then
        if self:isGenericType(objectType) then
            isOptional = self:getCombinedMappedTypeOptionality(self:getModifiersTypeFromMappedType(objectType)) > 0
        else
            isOptional = self:couldAccessOptionalProperty(objectType, index)
        end
    end
    return self:addOptionalityEx(instantiatedTemplateType, true --[[isProperty]], isOptional)
end

-- Return true if an indexed access with the given object and index types could access an optional property.
function Checker:couldAccessOptionalProperty(objectType, indexType)
    local indexConstraint = self:getBaseConstraintOfType(indexType)
    return indexConstraint ~= nil and core.Some(self:getPropertiesOfType(objectType), function(p)
        return p.flags & SymbolFlags.Optional ~= 0 and self:isTypeAssignableTo(self:getLiteralTypeFromProperty(p, TypeFlags.StringOrNumberLiteralOrUnique, false), indexConstraint)
    end)
end

function Checker:getTypeOfPropertyOrIndexSignatureOfType(t, name)
    local propType = self:getTypeOfPropertyOfType(t, name)
    if propType ~= nil then
        return propType
    end
    local indexInfo = self:getApplicableIndexInfoForName(t, name)
    if indexInfo ~= nil then
        return self:addOptionalityEx(indexInfo.valueType, true --[[isProperty]], true --[[isOptional]])
    end
    return nil
end

-- Go slices.Index (0-based, -1 if absent)
local function slicesIndex(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

--[[
Whoa! Do you really want to use this function?

Unless you're trying to get the *non-apparent* type for a
value-literal type or you're authoring relevant portions of this algorithm,
you probably meant to use 'getApparentTypeOfContextualType'.
Otherwise this may not be very useful.

In cases where you *are* working on this function, you should understand
when it is appropriate to use 'getContextualType' and 'getApparentTypeOfContextualType'.

  - Use 'getContextualType' when you are simply going to propagate the result to the expression.
  - Use 'getApparentTypeOfContextualType' when you're going to need the members of the type.

@param node the expression whose contextual type will be returned.
@returns the contextual type of an expression.
]]
function Checker:getContextualType(node, contextFlags)
    if node.flags & NodeFlags.InWithStatement ~= 0 then
        -- We cannot answer semantic questions within a with block, do not proceed any further
        return nil
    end
    -- Cached contextual types are obtained with no ContextFlags, so we can only consult them for
    -- requests with no ContextFlags.
    local index = self:findContextualNode(node, contextFlags == ContextFlags.None --[[includeCaches]])
    if index >= 0 then
        return self.contextualInfos[index + 1].t
    end
    local parent = node.parent
    local k = parent.kind
    if k == Kind.VariableDeclaration or k == Kind.Parameter or k == Kind.PropertyDeclaration or k == Kind.PropertySignature or k == Kind.BindingElement then
        return self:getContextualTypeForInitializerExpression(node, contextFlags)
    elseif k == Kind.ArrowFunction or k == Kind.ReturnStatement then
        return self:getContextualTypeForReturnExpression(node, contextFlags)
    elseif k == Kind.YieldExpression then
        return self:getContextualTypeForYieldOperand(parent, contextFlags)
    elseif k == Kind.AwaitExpression then
        return self:getContextualTypeForAwaitOperand(parent, contextFlags)
    elseif k == Kind.CallExpression or k == Kind.NewExpression then
        return self:getContextualTypeForArgument(parent, node)
    elseif k == Kind.Decorator then
        return self:getContextualTypeForDecorator(parent)
    elseif k == Kind.TypeAssertionExpression or k == Kind.AsExpression then
        if ast.IsConstAssertion(parent) then
            return self:getContextualType(parent, contextFlags)
        end
        return self:getTypeFromTypeNode(parent:Type())
    elseif k == Kind.BinaryExpression then
        return self:getContextualTypeForBinaryOperand(node, contextFlags)
    elseif k == Kind.PropertyAssignment or k == Kind.ShorthandPropertyAssignment then
        return self:getContextualTypeForObjectLiteralElement(parent, contextFlags)
    elseif k == Kind.SpreadAssignment then
        return self:getContextualType(parent.parent, contextFlags)
    elseif k == Kind.ArrayLiteralExpression then
        local t = self:getApparentTypeOfContextualType(parent, contextFlags)
        local elementIndex = ast.IndexOfNode(parent:Elements(), node)
        if elementIndex < 0 then
            return nil
        end
        local firstSpreadIndex, lastSpreadIndex = self:getSpreadIndices(parent)
        return self:getContextualTypeForElementExpression(t, elementIndex, core.Len(parent:Elements()), firstSpreadIndex, lastSpreadIndex)
    elseif k == Kind.ConditionalExpression then
        return self:getContextualTypeForConditionalOperand(node, contextFlags)
    elseif k == Kind.TemplateSpan then
        return self:getContextualTypeForSubstitutionExpression(parent.parent, node)
    elseif k == Kind.ParenthesizedExpression then
        return self:getContextualType(parent, contextFlags)
    elseif k == Kind.NonNullExpression then
        return self:getContextualType(parent, contextFlags)
    elseif k == Kind.SatisfiesExpression then
        return self:getTypeFromTypeNode(parent:Type())
    elseif k == Kind.ExportAssignment then
        return self:tryGetTypeFromTypeNode(parent)
    elseif k == Kind.JsxExpression then
        return self:getContextualTypeForJsxExpression(parent, contextFlags)
    elseif k == Kind.JsxAttribute or k == Kind.JsxSpreadAttribute then
        return self:getContextualTypeForJsxAttribute(parent, contextFlags)
    elseif k == Kind.JsxOpeningElement or k == Kind.JsxSelfClosingElement then
        return self:getContextualJsxElementAttributesType(parent, contextFlags)
    elseif k == Kind.ImportAttribute then
        return self:getContextualImportAttributeType(parent)
    end
    return nil
end

-- In a variable, parameter or property declaration with a type annotation,
-- the contextual type of an initializer expression is the type of the variable, parameter or property.
--
-- Otherwise, in a parameter declaration of a contextually typed function expression,
-- the contextual type of an initializer expression is the contextual type of the parameter.
--
-- Otherwise, in a variable or parameter declaration with a binding pattern name,
-- the contextual type of an initializer expression is the type implied by the binding pattern.
--
-- Otherwise, in a binding pattern inside a variable or parameter declaration,
-- the contextual type of an initializer expression is the type annotation of the containing declaration, if present.
function Checker:getContextualTypeForInitializerExpression(node, contextFlags)
    local declaration = node.parent
    local initializer = declaration:Initializer()
    if node == initializer then
        local result = self:getContextualTypeForVariableLikeDeclaration(declaration, contextFlags)
        if result ~= nil then
            return result
        end
        if contextFlags & ContextFlags.SkipBindingPatterns == 0 and ast.IsBindingPattern(declaration:Name()) and core.Len(declaration:Name():Elements()) > 0 then
            return self:getTypeFromBindingPattern(declaration:Name(), true --[[includePatternInType]], false --[[reportErrors]])
        end
    end
    return nil
end

function Checker:getContextualTypeForVariableLikeDeclaration(declaration, contextFlags)
    local typeNode = declaration:Type()
    if typeNode ~= nil then
        return self:getTypeFromTypeNode(typeNode)
    end
    local k = declaration.kind
    if k == Kind.Parameter then
        return self:getContextuallyTypedParameterType(declaration)
    elseif k == Kind.BindingElement then
        return self:getContextualTypeForBindingElement(declaration, contextFlags)
    elseif k == Kind.PropertyDeclaration then
        if ast.IsStatic(declaration) then
            return self:getContextualTypeForStaticPropertyDeclaration(declaration, contextFlags)
        end
    end
    -- By default, do nothing and return nil - only the above cases have context implied by a parent
    return nil
end

-- Return contextual type of parameter or undefined if no contextual type is available
function Checker:getContextuallyTypedParameterType(parameter)
    local fn = parameter.parent
    if not self:isContextSensitiveFunctionOrObjectLiteralMethod(fn) then
        return nil
    end
    local iife = ast.GetImmediatelyInvokedFunctionExpression(fn)
    if iife ~= nil then
        local args = self:getEffectiveCallArguments(iife)
        local indexOfParameter = slicesIndex(fn:Parameters(), parameter)
        if checker.hasDotDotDotToken(parameter) then
            return self:getSpreadArgumentType(args, indexOfParameter, core.Len(args), self.anyType, nil --[[context]], CheckMode.Normal)
        end
        local links = self.signatureLinks:Get(iife)
        local cached = links.resolvedSignature
        links.resolvedSignature = self.anySignature
        local t
        if indexOfParameter < core.Len(args) then
            t = self:getWidenedLiteralType(self:checkExpression(args[indexOfParameter + 1]))
        elseif parameter:Initializer() ~= nil then
            t = nil
        else
            t = self.undefinedWideningType
        end
        links.resolvedSignature = cached
        return t
    end
    local contextualSignature = self:getContextualSignature(fn)
    if contextualSignature ~= nil then
        local index = slicesIndex(fn:Parameters(), parameter) - core.IfElse(ast.GetThisParameter(fn) ~= nil, 1, 0)
        if checker.hasDotDotDotToken(parameter) and core.LastOrNil(fn:Parameters()) == parameter then
            return self:getRestTypeAtPosition(contextualSignature, index, false)
        end
        return self:tryGetTypeAtPosition(contextualSignature, index)
    end
    return nil
end

function Checker:isContextSensitiveFunctionOrObjectLiteralMethod(fn)
    return (ast.IsFunctionExpressionOrArrowFunction(fn) or ast.IsObjectLiteralMethod(fn)) and self:isContextSensitiveFunctionLikeDeclaration(fn)
end

function Checker:getSpreadArgumentType(args, index, argCount, restType, context, checkMode)
    local inConstContext = self:isConstTypeVariable(restType, 0)
    if argCount > 0 and index >= argCount - 1 then
        local arg = args[argCount]
        if checker.isSpreadArgument(arg) then
            -- We are inferring from a spread expression in the last argument position, i.e. both the parameter
            -- and the argument are ...x forms.
            local spreadType
            if ast.IsSyntheticExpression(arg) then
                spreadType = arg:AsSyntheticExpression().type
            else
                spreadType = self:checkExpressionWithContextualType(arg:Expression(), restType, context, checkMode)
            end
            if self:isArrayLikeType(spreadType) then
                return self:getMutableArrayOrTupleType(spreadType)
            end
            if ast.IsSpreadElement(arg) then
                arg = arg:Expression()
            end
            return self:createArrayTypeEx(self:checkIteratedTypeOrElementType(IterationUse.Spread, spreadType, self.undefinedType, arg), inConstContext)
        end
    end
    local types = {}
    local infos = {}
    for i = index, argCount - 1 do
        local arg = args[i + 1]
        local t
        local infoFlags = 0
        local infoLabeledDeclaration
        if checker.isSpreadArgument(arg) then
            local spreadType
            if ast.IsSyntheticExpression(arg) then
                spreadType = arg:AsSyntheticExpression().type
            else
                spreadType = self:checkExpression(arg:Expression())
            end
            if self:isArrayLikeType(spreadType) then
                t = spreadType
                infoFlags = ElementFlags.Variadic
            else
                if ast.IsSpreadElement(arg) then
                    t = self:checkIteratedTypeOrElementType(IterationUse.Spread, spreadType, self.undefinedType, arg:Expression())
                else
                    t = self:checkIteratedTypeOrElementType(IterationUse.Spread, spreadType, self.undefinedType, arg)
                end
                infoFlags = ElementFlags.Rest
            end
        else
            local contextualType
            if checker.isTupleType(restType) then
                contextualType = core.OrElse(self:getContextualTypeForElementExpression(restType, i - index, argCount - index, -1, -1), self.unknownType)
            else
                contextualType = self:getIndexedAccessTypeEx(restType, self:getNumberLiteralType((i - index) + 0.0), AccessFlags.Contextual, nil, nil)
            end
            local argType = self:checkExpressionWithContextualType(arg, contextualType, context, checkMode)
            local hasPrimitiveContextualType = inConstContext or self:maybeTypeOfKind(contextualType, TypeFlags.Primitive | TypeFlags.Index | TypeFlags.TemplateLiteral | TypeFlags.StringMapping)
            if hasPrimitiveContextualType then
                t = self:getRegularTypeOfLiteralType(argType)
            else
                t = self:getWidenedLiteralType(argType)
            end
            infoFlags = ElementFlags.Required
        end
        if ast.IsSyntheticExpression(arg) and arg:AsSyntheticExpression().tupleNameSource ~= nil then
            infoLabeledDeclaration = arg:AsSyntheticExpression().tupleNameSource
        end
        types[#types + 1] = t
        infos[#infos + 1] = checker.TupleElementInfo_new({ flags = infoFlags, labeledDeclaration = infoLabeledDeclaration })
    end
    return self:createTupleTypeEx(types, infos, inConstContext and not checker.someType(restType, function(t) return self:isMutableArrayLikeType(t) end))
end

function Checker:getMutableArrayOrTupleType(t)
    if t.flags & TypeFlags.Union ~= 0 then
        return self:mapType(t, function(t_) return self:getMutableArrayOrTupleType(t_) end)
    elseif t.flags & TypeFlags.Any ~= 0 or self:isMutableArrayOrTuple(self:getBaseConstraintOrType(t)) then
        return t
    elseif checker.isTupleType(t) then
        return self:createTupleTypeEx(self:getElementTypes(t), t:TargetTupleType().elementInfos, false --[[readonly]])
    end
    return self:createTupleTypeEx({ t }, { checker.TupleElementInfo_new({ flags = ElementFlags.Variadic }) }, false)
end

function Checker:getContextualTypeForBindingElement(declaration, contextFlags)
    local name = declaration:PropertyNameOrName()
    if ast.IsBindingPattern(name) or ast.IsComputedNonLiteralName(name) then
        return nil
    end
    local parent = declaration.parent.parent
    local parentType = self:getContextualTypeForVariableLikeDeclaration(parent, contextFlags)
    if parentType == nil then
        if not ast.IsBindingElement(parent) and parent:Initializer() ~= nil then
            parentType = self:checkDeclarationInitializer(parent, core.IfElse(checker.hasDotDotDotToken(declaration), CheckMode.RestBindingElement, CheckMode.Normal), nil)
        end
    end
    if parentType == nil then
        return nil
    end
    if ast.IsArrayBindingPattern(parent:Name()) then
        local index = slicesIndex(declaration.parent:Elements(), declaration)
        if index < 0 then
            return nil
        end
        return self:getContextualTypeForElementExpression(parentType, index, -1, -1, -1)
    end
    local nameType = self:getLiteralTypeFromPropertyName(name)
    if checker.isTypeUsableAsPropertyName(nameType) then
        return self:getTypeOfPropertyOfType(parentType, checker.getPropertyNameFromType(nameType))
    end
    return nil
end

function Checker:getContextualTypeForStaticPropertyDeclaration(declaration, contextFlags)
    if ast.IsExpression(declaration.parent) then
        local parentType = self:getContextualType(declaration.parent, contextFlags)
        if parentType ~= nil then
            return self:getTypeOfPropertyOfContextualType(parentType, self:getSymbolOfDeclaration(declaration).name)
        end
    end
    return nil
end

function Checker:getContextualTypeForReturnExpression(node, contextFlags)
    local fn = ast.GetContainingFunction(node)
    if fn ~= nil then
        local contextualReturnType = self:getContextualReturnType(fn, contextFlags)
        if contextualReturnType ~= nil then
            local functionFlags = ast.GetFunctionFlags(fn)
            if functionFlags & FunctionFlags.Generator ~= 0 then
                local isAsyncGenerator = (functionFlags & FunctionFlags.Async) ~= 0
                if contextualReturnType.flags & TypeFlags.Union ~= 0 then
                    contextualReturnType = self:filterType(contextualReturnType, function(t)
                        return self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, t, isAsyncGenerator) ~= nil
                    end)
                end
                local iterationReturnType = self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, contextualReturnType, (functionFlags & FunctionFlags.Async) ~= 0)
                if iterationReturnType == nil then
                    return nil
                end
                contextualReturnType = iterationReturnType
                -- falls through to unwrap Promise for AsyncGenerators
            end
            if functionFlags & FunctionFlags.Async ~= 0 then
                -- Get the awaited type without the `Awaited<T>` alias
                local contextualAwaitedType = self:mapType(contextualReturnType, function(t) return self:getAwaitedTypeNoAlias(t) end)
                if contextualAwaitedType == nil then
                    return nil
                end
                return self:getUnionType({ contextualAwaitedType, self:createPromiseLikeType(contextualAwaitedType) })
            end
            -- Regular function or Generator function
            return contextualReturnType
        end
    end
    return nil
end

function Checker:getContextualIterationType(kind, functionDecl)
    local isAsync = ast.GetFunctionFlags(functionDecl) & FunctionFlags.Async ~= 0
    local contextualReturnType = self:getContextualReturnType(functionDecl, ContextFlags.None)
    if contextualReturnType ~= nil then
        return self:getIterationTypeOfGeneratorFunctionReturnType(kind, contextualReturnType, isAsync)
    end
    return nil
end

function Checker:getContextualReturnType(functionDecl, contextFlags)
    -- If the containing function has a return type annotation, is a constructor, or is a get accessor whose
    -- corresponding set accessor has a type annotation, return statements in the function are contextually typed
    local returnType = self:getReturnTypeFromAnnotation(functionDecl)
    if returnType ~= nil then
        return returnType
    end
    -- Otherwise, if the containing function is contextually typed by a function type with exactly one call signature
    -- and that call signature is non-generic, return statements are contextually typed by the return type of the signature
    local signature = self:getContextualSignatureForFunctionLikeDeclaration(functionDecl)
    if signature ~= nil and not self:isResolvingReturnTypeOfSignature(signature) then
        local returnType_ = self:getReturnTypeOfSignature(signature)
        local functionFlags = ast.GetFunctionFlags(functionDecl)
        if functionFlags & FunctionFlags.Generator ~= 0 then
            return self:filterType(returnType_, function(t)
                return t.flags & (TypeFlags.AnyOrUnknown | TypeFlags.Void | TypeFlags.InstantiableNonPrimitive) ~= 0 or self:checkGeneratorInstantiationAssignabilityToReturnType(t, functionFlags, nil --[[errorNode]])
            end)
        end
        if functionFlags & FunctionFlags.Async ~= 0 then
            return self:filterType(returnType_, function(t)
                return t.flags & (TypeFlags.AnyOrUnknown | TypeFlags.Void | TypeFlags.InstantiableNonPrimitive) ~= 0 or self:getAwaitedTypeOfPromise(t) ~= nil
            end)
        end
        return returnType_
    end
    local iife = ast.GetImmediatelyInvokedFunctionExpression(functionDecl)
    if iife ~= nil then
        return self:getContextualType(iife, contextFlags)
    end
    return nil
end

function Checker:checkGeneratorInstantiationAssignabilityToReturnType(returnType, functionFlags, errorNode)
    -- Naively, one could check that Generator<any, any, any> is assignable to the return type annotation.
    -- However, that would not catch the error in the following case.
    --
    --    interface BadGenerator extends Iterable<number>, Iterator<string> { }
    --    function* g(): BadGenerator { } // Iterable and Iterator have different types!
    --
    local generatorYieldType = core.OrElse(self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Yield, returnType, (functionFlags & FunctionFlags.Async) ~= 0), self.anyType)
    local generatorReturnType = core.OrElse(self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, returnType, (functionFlags & FunctionFlags.Async) ~= 0), generatorYieldType)
    local generatorNextType = core.OrElse(self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Next, returnType, (functionFlags & FunctionFlags.Async) ~= 0), self.unknownType)
    local generatorInstantiation = self:createGeneratorType(generatorYieldType, generatorReturnType, generatorNextType, functionFlags & FunctionFlags.Async ~= 0)
    return self:checkTypeAssignableTo(generatorInstantiation, returnType, errorNode, nil)
end

function Checker:getContextualSignatureForFunctionLikeDeclaration(node)
    -- Only function expressions, arrow functions, and object literal methods are contextually typed.
    if ast.IsFunctionExpressionOrArrowFunction(node) or ast.IsObjectLiteralMethod(node) then
        return self:getContextualSignature(node)
    end
    return nil
end

function Checker:getContextualTypeForYieldOperand(node, contextFlags)
    local fn = ast.GetContainingFunction(node)
    if fn ~= nil then
        local functionFlags = ast.GetFunctionFlags(fn)
        local contextualReturnType = self:getContextualReturnType(fn, contextFlags)
        if contextualReturnType ~= nil then
            local isAsyncGenerator = functionFlags & FunctionFlags.Async ~= 0
            local isYieldStar = node:AsYieldExpression().asteriskToken ~= nil
            if not isYieldStar and contextualReturnType.flags & TypeFlags.Union ~= 0 then
                contextualReturnType = self:filterType(contextualReturnType, function(t)
                    return self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, t, isAsyncGenerator) ~= nil
                end)
            end
            if isYieldStar then
                local iterationTypes = self:getIterationTypesOfGeneratorFunctionReturnType(contextualReturnType, isAsyncGenerator)
                local yieldType = core.OrElse(iterationTypes.yieldType, self.silentNeverType)
                local returnType = core.OrElse(self:getContextualType(node, contextFlags), self.silentNeverType)
                local nextType = core.OrElse(iterationTypes.nextType, self.unknownType)
                local generatorType = self:createGeneratorType(yieldType, returnType, nextType, false --[[isAsyncGenerator]])
                if isAsyncGenerator then
                    local asyncGeneratorType = self:createGeneratorType(yieldType, returnType, nextType, true --[[isAsyncGenerator]])
                    return self:getUnionType({ generatorType, asyncGeneratorType })
                end
                return generatorType
            end
            return self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Yield, contextualReturnType, isAsyncGenerator)
        end
    end
    return nil
end

function Checker:getContextualTypeForAwaitOperand(node, contextFlags)
    local contextualType = self:getContextualType(node, contextFlags)
    if contextualType ~= nil then
        local contextualAwaitedType = self:getAwaitedTypeNoAlias(contextualType)
        if contextualAwaitedType ~= nil then
            return self:getUnionType({ contextualAwaitedType, self:createPromiseLikeType(contextualAwaitedType) })
        end
    end
    return nil
end

-- In a typed function call, an argument or substitution expression is contextually typed by the type of the corresponding parameter.
function Checker:getContextualTypeForArgument(callTarget, arg)
    local args = self:getEffectiveCallArguments(callTarget)
    local argIndex = slicesIndex(args, arg)
    -- -1 for e.g. the expression of a CallExpression, or the tag of a TaggedTemplateExpression
    if argIndex == -1 then
        return nil
    end
    return self:getContextualTypeForArgumentAtIndex(callTarget, argIndex)
end

function Checker:getContextualTypeForArgumentAtIndex(callTarget, argIndex)
    if ast.IsImportCall(callTarget) then
        if argIndex == 0 then
            return self.stringType
        elseif argIndex == 1 then
            return self.getGlobalImportCallOptionsType()
        else
            return self.anyType
        end
    end
    -- If we're already in the process of resolving the given signature, don't resolve again as
    -- that could cause infinite recursion. Instead, return anySignature.
    local signature
    if self.signatureLinks:Get(callTarget).resolvedSignature == self.resolvingSignature then
        signature = self.resolvingSignature
    else
        signature = self:getResolvedSignature(callTarget, nil, CheckMode.Normal)
    end
    if ast.IsJsxOpeningLikeElement(callTarget) and argIndex == 0 then
        return self:getEffectiveFirstArgumentForJsxSignature(signature, callTarget)
    end
    local restIndex = core.Len(signature.parameters) - 1
    if checker.signatureHasRestParameter(signature) and argIndex >= restIndex then
        return self:getIndexedAccessTypeEx(self:getTypeOfSymbol(signature.parameters[restIndex + 1]), self:getNumberLiteralType((argIndex - restIndex) + 0.0), AccessFlags.Contextual, nil, nil)
    end
    return self:getTypeAtPosition(signature, argIndex)
end

function Checker:getContextualTypeForDecorator(decorator)
    local signature = self:getDecoratorCallSignature(decorator)
    if signature ~= nil then
        return self:getOrCreateTypeFromSignature(signature)
    end
    return nil
end

function Checker:getContextualTypeForBinaryOperand(node, contextFlags)
    local binary = node.parent:AsBinaryExpression()
    local t_ = binary.type
    if t_ ~= nil then
        return self:getTypeFromTypeNode(t_)
    end
    local k = binary.operatorToken.kind
    if k == Kind.EqualsToken or k == Kind.AmpersandAmpersandEqualsToken or k == Kind.BarBarEqualsToken or k == Kind.QuestionQuestionEqualsToken then
        -- In an assignment expression, the right operand is contextually typed by the type of the left operand
        -- unless it's an assignment declaration.
        if node == binary.right then
            local target = ast.GetLeftmostExpression(binary.left, false)
            if not (ast.IsIdentifier(target) and self:getResolvedSymbol(target).flags & SymbolFlags.ModuleExports ~= 0) then
                return self:getContextualTypeForAssignmentExpression(binary)
            end
        end
    elseif k == Kind.BarBarToken or k == Kind.QuestionQuestionToken then
        -- When an || expression has a contextual type, the operands are contextually typed by that type, except
        -- when that type originates in a binding pattern, the right operand is contextually typed by the type of
        -- the left operand. When an || expression has no contextual type, the right operand is contextually typed
        -- by the type of the left operand, except for the special case of Javascript declarations of the form
        -- `namespace.prop = namespace.prop || {}`.
        local t = self:getContextualType(binary:AsNode(), contextFlags)
        if node == binary.right and (t == nil or self.patternForType[t] ~= nil) then
            return self:getTypeOfExpression(binary.left)
        end
        return t
    elseif k == Kind.AmpersandAmpersandToken or k == Kind.CommaToken then
        if node == binary.right then
            return self:getContextualType(binary:AsNode(), contextFlags)
        end
    end
    return nil
end

function Checker:getContextualTypeForAssignmentExpression(binary)
    local left = binary.left
    if ast.IsAccessExpression(left) then
        local expr = left:Expression()
        local k = expr.kind
        if k == Kind.Identifier then
            local symbol = self:getExportSymbolOfValueSymbolIfExported(self:getResolvedSymbol(expr))
            if symbol.flags & SymbolFlags.ModuleExports ~= 0 then
                -- No contextual type for an expression of the form 'module.exports = expr'.
                return nil
            end
            if binary.symbol ~= nil then
                -- We have an assignment declaration (a binary expression with a symbol assigned by the binder) of the form
                -- 'F.id = expr' or 'F[xxx] = expr'. If 'F' is declared as a variable with a type annotation, we can obtain a
                -- contextual type from the annotated type without triggering a circularity. Otherwise, the assignment
                -- declaration has no contextual type.
                if symbol.valueDeclaration ~= nil and ast.IsVariableDeclaration(symbol.valueDeclaration) then
                    local typeNode = symbol.valueDeclaration:Type()
                    if typeNode ~= nil then
                        if ast.IsPropertyAccessExpression(left) then
                            return self:getTypeOfPropertyOfContextualType(self:getTypeFromTypeNode(typeNode), left:Name():Text())
                        end
                        local nameType = self:checkExpressionCached(left:AsElementAccessExpression().argumentExpression)
                        if checker.isTypeUsableAsPropertyName(nameType) then
                            return self:getTypeOfPropertyOfContextualTypeEx(self:getTypeFromTypeNode(typeNode), checker.getPropertyNameFromType(nameType), nameType)
                        end
                        return self:getTypeOfExpression(left)
                    end
                end
                return nil
            end
        elseif k == Kind.PropertyAccessExpression or k == Kind.ElementAccessExpression then
            if binary.symbol ~= nil then
                return nil
            end
        elseif k == Kind.ThisKeyword then
            local symbol
            local thisType = self:getTypeOfExpression(expr)
            if ast.IsPropertyAccessExpression(left) then
                local name = left:Name()
                if ast.IsPrivateIdentifier(name) then
                    if thisType.symbol ~= nil then
                        symbol = self:getPropertyOfType(thisType, binder.GetSymbolNameForPrivateIdentifier(thisType.symbol, name:Text()))
                    end
                else
                    symbol = self:getPropertyOfType(thisType, name:Text())
                end
            else
                local propType = self:checkExpressionCached(left:AsElementAccessExpression().argumentExpression)
                if checker.isTypeUsableAsPropertyName(propType) then
                    symbol = self:getPropertyOfType(thisType, checker.getPropertyNameFromType(propType))
                end
            end
            if symbol ~= nil then
                local d = symbol.valueDeclaration
                if d ~= nil and (ast.IsPropertyDeclaration(d) or ast.IsPropertySignatureDeclaration(d)) and d:Type() == nil and d:Initializer() == nil then
                    -- No contextual type for 'this.xxx = expr', where xxx is declared as a property with no type annotation or initializer.
                    return nil
                end
            end
            if binary.symbol ~= nil and binary.symbol.valueDeclaration ~= nil and binary.symbol.valueDeclaration:Type() == nil then
                -- We have an assignment declaration 'this.xxx = expr' with no (synthetic) type annotation
                if not ast.IsObjectLiteralMethod(self:getThisContainer(expr, false, false)) then
                    return nil
                end
                -- and now for one single case of object literal methods
                local name = ast.GetElementOrPropertyAccessName(left)
                if name == nil then
                    return nil
                else
                    -- !!! contextual typing for `this` in object literals
                    return nil
                end
            end
        end
    end
    return self:getTypeOfExpression(left)
end

function Checker:getContextualTypeForObjectLiteralElement(element, contextFlags)
    local t_ = element:Type()
    if t_ ~= nil and not ast.IsObjectLiteralMethod(element) then
        return self:getTypeFromTypeNode(t_)
    end
    local objectLiteral = element.parent
    local t = self:getApparentTypeOfContextualType(objectLiteral, contextFlags)
    if t ~= nil then
        if self:hasBindableName(element) then
            -- For a (non-symbol) computed property, there is no reason to look up the name
            -- in the type. It will just be "__computed", which does not appear in any
            -- SymbolTable.
            local symbol = self:getSymbolOfDeclaration(element)
            return self:getTypeOfPropertyOfContextualTypeEx(t, symbol.name, self.valueSymbolLinks:Get(symbol).nameType)
        end
        if ast.HasDynamicName(element) then
            local name = ast.GetNameOfDeclaration(element)
            if name ~= nil and ast.IsComputedPropertyName(name) then
                local exprType = self:checkExpression(name:Expression())
                if checker.isTypeUsableAsPropertyName(exprType) then
                    local propType = self:getTypeOfPropertyOfContextualType(t, checker.getPropertyNameFromType(exprType))
                    if propType ~= nil then
                        return propType
                    end
                end
            end
        end
        if element:Name() ~= nil then
            local nameType = self:getLiteralTypeFromPropertyName(element:Name())
            -- We avoid calling getApplicableIndexInfo here because it performs potentially expensive intersection reduction.
            return self:mapTypeEx(t, function(t1)
                local indexInfo = self:findApplicableIndexInfo(self:getIndexInfosOfStructuredType(t1), nameType)
                if indexInfo == nil then
                    return nil
                end
                return indexInfo.valueType
            end, true --[[noReductions]])
        end
    end
    return nil
end

-- In an object literal contextually typed by a type T, the contextual type of a property assignment is the type of
-- the matching property in T, if one exists. Otherwise, it is the type of the numeric index signature in T, if one
-- exists. Otherwise, it is the type of the string index signature in T, if one exists.
function Checker:getContextualTypeForObjectLiteralMethod(node, contextFlags)
    if node.flags & NodeFlags.InWithStatement ~= 0 then
        -- We cannot answer semantic questions within a with block, do not proceed any further
        return nil
    end
    return self:getContextualTypeForObjectLiteralElement(node, contextFlags)
end

function Checker:getContextualTypeForElementExpression(t, index, length, firstSpreadIndex, lastSpreadIndex)
    if t == nil then
        return nil
    end
    return self:mapTypeEx(t, function(t1)
        if checker.isTupleType(t1) then
            -- If index is before any spread element and within the fixed part of the contextual tuple type, return
            -- the type of the contextual tuple element.
            if (firstSpreadIndex < 0 or index < firstSpreadIndex) and index < t1:TargetTupleType().fixedLength then
                return self:removeMissingType(self:getTypeArguments(t1)[index + 1], t1:TargetTupleType().elementInfos[index + 1].flags & ElementFlags.Optional ~= 0)
            end
            -- When the length is known and the index is after all spread elements we compute the offset from the element
            -- to the end and the number of ending fixed elements in the contextual tuple type.
            local offset = 0
            if length >= 0 and (lastSpreadIndex < 0 or index > lastSpreadIndex) then
                offset = length - index
            end
            local fixedEndLength = 0
            if offset > 0 and t1:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 then
                fixedEndLength = checker.getEndElementCount(t1:TargetTupleType(), ElementFlags.Fixed)
            end
            -- If the offset is within the ending fixed part of the contextual tuple type, return the type of the contextual
            -- tuple element.
            if offset > 0 and offset <= fixedEndLength then
                return self:getTypeArguments(t1)[self:getTypeReferenceArity(t1) - offset + 1]
            end
            -- Return a union of the possible contextual element types with no subtype reduction.
            local tupleIndex = t1:TargetTupleType().fixedLength
            if firstSpreadIndex >= 0 then
                tupleIndex = math.min(tupleIndex, firstSpreadIndex)
            end
            local endSkipCount = fixedEndLength
            if length >= 0 and lastSpreadIndex >= 0 then
                endSkipCount = math.min(fixedEndLength, length - lastSpreadIndex)
            end
            return self:getElementTypeOfSliceOfTupleType(t1, tupleIndex, endSkipCount, false --[[writing]], true --[[noReductions]])
        end
        -- If element index is known and a contextual property with that name exists, return it. Otherwise return the
        -- iterated or element type of the contextual type.
        if firstSpreadIndex < 0 or index < firstSpreadIndex then
            local propType = self:getTypeOfPropertyOfContextualType(t1, tostring(index))
            if propType ~= nil then
                return propType
            end
        end
        return self:getIteratedTypeOrElementType(IterationUse.Element, t1, self.undefinedType, nil --[[errorNode]], false --[[checkAssignability]])
    end, true --[[noReductions]])
end

-- In a contextually typed conditional expression, the true/false expressions are contextually typed by the same type.
function Checker:getContextualTypeForConditionalOperand(node, contextFlags)
    local conditional = node.parent:AsConditionalExpression()
    if node == conditional.whenTrue or node == conditional.whenFalse then
        return self:getContextualType(node.parent, contextFlags)
    end
    return nil
end

function Checker:getContextualTypeForSubstitutionExpression(template, substitutionExpression)
    if ast.IsTaggedTemplateExpression(template.parent) then
        return self:getContextualTypeForArgument(template.parent, substitutionExpression)
    end
    return nil
end

function Checker:getContextualImportAttributeType(node)
    return self:getTypeOfPropertyOfContextualType(self.getGlobalImportAttributesType(), node:Name():Text())
end

-- Returns the effective arguments for an expression that works like a function invocation.
function Checker:getEffectiveCallArguments(node)
    if ast.IsJsxOpeningFragment(node) then
        -- This attributes Type does not include a children property yet, the same way a fragment created with <React.Fragment> does not at this stage
        return { self:createSyntheticExpression(node, self.emptyFreshJsxObjectType, false, nil) }
    elseif ast.IsTaggedTemplateExpression(node) then
        local template = node:AsTaggedTemplateExpression().template
        local firstArg = self:createSyntheticExpression(template, self.getGlobalTemplateStringsArrayType(), false, nil)
        if not ast.IsTemplateExpression(template) then
            return { firstArg }
        end
        local spans = template:AsTemplateExpression().templateSpans.nodes
        local args = { firstArg }
        for i, span in ipairs(spans) do
            args[i + 1] = span:Expression()
        end
        return args
    elseif ast.IsDecorator(node) then
        return self:getEffectiveDecoratorArguments(node)
    elseif ast.IsBinaryExpression(node) then
        -- Handles instanceof operator
        return { node:AsBinaryExpression().left }
    elseif ast.IsJsxOpeningLikeElement(node) then
        if core.Len(node:Attributes():Properties()) ~= 0 or (ast.IsJsxOpeningElement(node) and core.Len(node.parent:Children().nodes) ~= 0) then
            return { node:Attributes() }
        end
        return nil
    else
        local args = node:Arguments()
        local spreadIndex = self:getSpreadArgumentIndex(args)
        if spreadIndex >= 0 then
            -- Create synthetic arguments from spreads of tuple types.
            local effectiveArgs = core.Slice(args, 0, spreadIndex)
            for i = spreadIndex, #args - 1 do
                local arg = args[i + 1]
                local spreadType
                -- We can call checkExpressionCached because spread expressions never have a contextual type.
                if ast.IsSpreadElement(arg) then
                    if core.Len(self.flowLoopStack) ~= 0 then
                        spreadType = self:checkExpression(arg:Expression())
                    else
                        spreadType = self:checkExpressionCached(arg:Expression())
                    end
                end
                if spreadType ~= nil and checker.isTupleType(spreadType) then
                    for j, t in ipairs(self:getElementTypes(spreadType)) do
                        local elementInfos = spreadType:TargetTupleType().elementInfos
                        local flags = elementInfos[j].flags
                        local syntheticType = t
                        if flags & ElementFlags.Rest ~= 0 then
                            syntheticType = self:createArrayType(t)
                        end
                        local syntheticArg = self:createSyntheticExpression(arg, syntheticType, flags & ElementFlags.Variable ~= 0, elementInfos[j].labeledDeclaration)
                        effectiveArgs[#effectiveArgs + 1] = syntheticArg
                    end
                else
                    effectiveArgs[#effectiveArgs + 1] = arg
                end
            end
            return effectiveArgs
        end
        return args
    end
end

function Checker:getSpreadArgumentIndex(args)
    return core.FindIndex(args, checker.isSpreadArgument)
end

function checker.isSpreadArgument(arg)
    return ast.IsSpreadElement(arg) or ast.IsSyntheticExpression(arg) and arg:AsSyntheticExpression().isSpread
end

function Checker:createSyntheticExpression(parent, t, isSpread, tupleNameSource)
    local result = self.factory:NewSyntheticExpression(t, isSpread, tupleNameSource)
    result.loc = parent.loc
    result.parent = parent
    return result
end

function Checker:getSpreadIndices(node)
    local links = self.arrayLiteralLinks:Get(node)
    if not links.indicesComputed then
        local first, last = -1, -1
        for i1, element in ipairs(node:Elements() or {}) do
            if ast.IsSpreadElement(element) then
                if first < 0 then
                    first = i1 - 1
                end
                last = i1 - 1
            end
        end
        links.firstSpreadIndex, links.lastSpreadIndex = first, last
        links.indicesComputed = true
    end
    return links.firstSpreadIndex, links.lastSpreadIndex
end

-- Returns the synthetic argument list for a decorator invocation.
function Checker:getEffectiveDecoratorArguments(node)
    local expr = node:Expression()
    local signature = self:getDecoratorCallSignature(node)
    if signature ~= nil then
        local args = {}
        for i, param in ipairs(signature.parameters or {}) do
            args[i] = self:createSyntheticExpression(expr, self:getTypeOfSymbol(param), false, nil)
        end
        return args
    end
    error("Decorator signature not found", 0)
end

function Checker:getDecoratorCallSignature(decorator)
    if self.legacyDecorators then
        return self:getLegacyDecoratorCallSignature(decorator)
    end
    return self:getESDecoratorCallSignature(decorator)
end
