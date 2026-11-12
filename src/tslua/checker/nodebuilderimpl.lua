local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local jsnum = require("tslua.jsnum")
local module = require("tslua.module")
local modulespecifiers = require("tslua.modulespecifiers")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local pseudochecker = require("tslua.pseudochecker")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local CheckFlags = ast.CheckFlags
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local ElementFlags = checker.ElementFlags
local Flags = nodebuilder.Flags
local InternalFlags = nodebuilder.InternalFlags
local ModuleKind = core.ModuleKind
local EmitFlags = printer.EmitFlags


-- CompositeSymbolIdentity: { isConstructorNode, symbolId, nodeId } (map key: checker.CompositeSymbolIdentityKey)
function checker.CompositeSymbolIdentityKey(id)
    return (id.isConstructorNode and "1" or "0") .. ":" .. tostring(id.symbolId) .. ":" .. tostring(id.nodeId)
end

checker.defineStruct("TrackedSymbolArgs", nil, { meaning = 0 })

checker.defineStruct("SerializedTypeEntry", nil, { truncating = false, addedLength = 0 })

-- CompositeTypeCacheIdentity{typeId, flags, internalFlags} map key
function checker.CompositeTypeCacheIdentityKey(typeId, flags, internalFlags)
    return tostring(typeId) .. ":" .. tostring(flags) .. ":" .. tostring(internalFlags)
end

-- NodeBuilderLinks: serializedTypes (Collection of types serialized at this location), fakeScopeForSignatureDeclaration
-- (If present, this is a fake scope injected into an enclosing declaration chain; nil or a string.)
checker.defineStruct("NodeBuilderLinks", nil, nil)

-- NodeBuilderSymbolLinks: specifierCache (module.ModeAwareCache[string], keyed by module.ModeAwareCacheKeyString)
checker.defineStruct("NodeBuilderSymbolLinks", nil, nil)

checker.defineStruct("NodeBuilderContext", nil, {
    approximateLength = 0,
    maxTruncationLength = 0,
    encounteredError = false,
    truncating = false,
    reportedDiagnostic = false,
    flags = 0,
    internalFlags = 0,
    depth = 0,
    maxExpansionDepth = 0, -- -1 means no expansion, 0+ = verbosity levels
    canIncreaseExpansionDepth = false,
    expansionTruncated = false,
    suppressReportInferenceFallback = false,
})

-- Collection-valued fields whose Go zero value is usable (Set, CopyOnWriteMap/Set) are created on demand.
local contextZeroCollections = {
    visitedTypes = collections.NewSet,
    typeParameterNames = collections.NewCopyOnWriteMap,
    typeParameterNamesByText = collections.NewCopyOnWriteSet,
    typeParameterNamesByTextNextNameCount = collections.NewCopyOnWriteMap,
    typeParameterSymbolList = collections.NewCopyOnWriteSet,
}
local newNodeBuilderContextRaw = checker.NodeBuilderContext_new
function checker.NodeBuilderContext_new(init)
    local ctx = newNodeBuilderContextRaw(init)
    for k, f in pairs(contextZeroCollections) do
        if rawget(ctx, k) == nil then
            ctx[k] = f()
        end
    end
    return ctx
end

local NodeBuilderImpl = checker.defineStruct("NodeBuilderImpl", nil, nil)

checker.defaultMaximumTruncationLength = 160
checker.noTruncationMaximumTruncationLength = 1000000

-- Node builder utility functions

function checker.newNodeBuilderImpl(ch, e, idToSymbol)
    if idToSymbol == nil then
        idToSymbol = {}
    end
    local b = checker.NodeBuilderImpl_new({
        f = e.factory:AsNodeFactory(),
        ch = ch,
        e = e,
        idToSymbol = idToSymbol,
        pc = pseudochecker.NewPseudoChecker(ch.strictNullChecks, ch.exactOptionalPropertyTypes),
        links = checker.NewLinkStore(checker.NodeBuilderLinks_new),
        symbolLinks = checker.NewLinkStore(checker.NodeBuilderSymbolLinks_new),
    })
    b.cloneBindingNameVisitor = ast.NewNodeVisitor(function(node) return b:cloneBindingName(node) end, b.f, {})
    return b
end

function NodeBuilderImpl:saveRestoreFlags()
    local flags = self.ctx.flags
    local internalFlags = self.ctx.internalFlags
    local depth = self.ctx.depth

    return function()
        self.ctx.flags = flags
        self.ctx.internalFlags = internalFlags
        self.ctx.depth = depth
    end
end

function NodeBuilderImpl:checkTruncationLength()
    if self.ctx.truncating then
        return self.ctx.truncating
    end
    local maxLength
    if self.ctx.flags & Flags.NoTruncation ~= 0 then
        maxLength = checker.noTruncationMaximumTruncationLength
    elseif self.ctx.maxTruncationLength > 0 then
        maxLength = self.ctx.maxTruncationLength
    else
        maxLength = checker.defaultMaximumTruncationLength
    end
    self.ctx.truncating = self.ctx.approximateLength > maxLength
    return self.ctx.truncating
end

-- checkTruncationLengthIfExpanding returns true if maxExpansionDepth >= 0 and truncation length exceeded.
-- When expanding, we need to mark the output as truncated so we know not to offer further expansion.
function NodeBuilderImpl:checkTruncationLengthIfExpanding()
    if self.ctx.maxExpansionDepth >= 0 and self:checkTruncationLength() then
        self.ctx.expansionTruncated = true
        return true
    end
    return false
end

-- isExpandableType reports whether t has a named representation that could be inlined
-- as its structural form during hover expansion. Filters out lib types.
-- When isAlias is true, checks whether t's alias symbol is from user code (not lib).
function NodeBuilderImpl:isExpandableType(t, isAlias)
    if isAlias then
        return not self.ch:IsLibSymbolForHoverVerbosity(checker.TypeAlias.Symbol(t.alias))
    end
    if self.ch:IsLibTypeForHoverVerbosity(t) then
        return false
    end
    local objectFlags = t.objectFlags
    if t.flags & TypeFlags.EnumLike ~= 0 or
        objectFlags & ObjectFlags.Reference ~= 0 or
        objectFlags & ObjectFlags.ClassOrInterface ~= 0 then
        return true
    end
    if objectFlags & ObjectFlags.Anonymous ~= 0 and t.symbol ~= nil and
        t.symbol.flags & (SymbolFlags.Class | SymbolFlags.Enum | SymbolFlags.ValueModule | SymbolFlags.Function | SymbolFlags.Method) ~= 0 then
        return true
    end
    return false
end

-- isTypeOnStack reports whether t is already being processed in the current expansion,
-- excluding the last element (which is the type currently being serialized by typeToTypeNode).
function NodeBuilderImpl:isTypeOnStack(t)
    local typeStack = self.ctx.typeStack or {}
    for i = 1, #typeStack - 1 do
        if typeStack[i] == t then
            return true
        end
    end
    return false
end

-- shouldExpandType decides whether to expand this type at the current depth.
-- Returns true when depth < maxExpansionDepth (expand now).
-- At the boundary (depth == maxExpansionDepth), sets canIncreaseExpansionDepth
-- to signal that a higher verbosity level would reveal more detail.
-- Returns false when expansion is disabled (maxExpansionDepth < 0), the type
-- is not expandable, or the type is cyclic.
function NodeBuilderImpl:shouldExpandType(t, isAlias)
    if self.ctx.maxExpansionDepth < 0 then
        return false
    end
    if not self:isExpandableType(t, isAlias) then
        return false
    end
    if self:isTypeOnStack(t) then
        return false
    end
    if self.ctx.depth < self.ctx.maxExpansionDepth then
        return true
    end
    self.ctx.canIncreaseExpansionDepth = true
    return false
end

-- isActivelyExpanding reports whether the current depth is below maxExpansionDepth,
-- meaning type-node reuse should be skipped so typeToTypeNode can expand named types.
function NodeBuilderImpl:isActivelyExpanding()
    return self.ctx.maxExpansionDepth > 0 and self.ctx.depth < self.ctx.maxExpansionDepth
end

local function pushTypeStack(ctx, t)
    local typeStack = ctx.typeStack
    if typeStack == nil then
        typeStack = {}
        ctx.typeStack = typeStack
    end
    typeStack[#typeStack + 1] = t or false
end

local function popTypeStack(ctx)
    local typeStack = ctx.typeStack
    typeStack[#typeStack] = nil
end

-- checkTypeExpandability probes whether a type (or its type arguments) could be expanded,
-- for use after type-node reuse where shouldExpandType was never called.
-- Delegates to shouldExpandType for the actual check, then recurses into type arguments
-- of reference types (e.g., Apple inside Promise<Apple>).
function NodeBuilderImpl:checkTypeExpandability(t)
    if self.ctx.maxExpansionDepth < 0 or t == nil or self.ctx.canIncreaseExpansionDepth then
        return
    end
    -- Push t onto the type stack so shouldExpandType's cycle detection works correctly.
    pushTypeStack(self.ctx, t)
    local ctx = self.ctx
    local function done()
        popTypeStack(ctx)
    end
    -- If t is an ancestor in the current expansion, return early to avoid unbounded recursion.
    if self:isTypeOnStack(t) then
        return done()
    end
    if t.alias ~= nil then
        self:shouldExpandType(t, true)
    end
    if not self.ctx.canIncreaseExpansionDepth then
        self:shouldExpandType(t, false)
    end
    if self.ctx.canIncreaseExpansionDepth then
        return done()
    end
    -- Recurse into type arguments (e.g., check Apple in Promise<Apple>).
    if t.objectFlags & ObjectFlags.Reference ~= 0 then
        for _, arg in ipairs(self.ch:getTypeArguments(t) or {}) do
            self:checkTypeExpandability(arg)
            if self.ctx.canIncreaseExpansionDepth then
                return done()
            end
        end
    end
    return done()
end

function NodeBuilderImpl:appendReferenceToType(root, ref)
    if ast.IsImportTypeNode(root) then
        -- first shift type arguments

        -- !!! In the old emitter, an Identifier could have type arguments for use with quickinfo:
        -- typeArguments := root.TypeArguments
        -- qualifier := root.AsImportTypeNode().Qualifier
        -- if qualifier != nil {
        -- 	if ast.IsIdentifier(qualifier) {
        -- 		if typeArguments != getIdentifierTypeArguments(qualifier) {
        -- 			qualifier = setIdentifierTypeArguments(b.f.CloneNode(qualifier), typeArguments)
        -- 		}
        -- 	} else {
        -- 		if typeArguments != getIdentifierTypeArguments(qualifier.Right) {
        -- 			qualifier = b.f.UpdateQualifiedName(qualifier, qualifier.Left, setIdentifierTypeArguments(b.f.cloneNode(qualifier.Right), typeArguments))
        -- 		}
        -- 	}
        -- }
        -- !!! Without the above, nested type args are silently elided
        local imprt = root:AsImportTypeNode()
        -- then move qualifiers
        local ids = checker.getAccessStack(ref)
        local qualifier = root:AsImportTypeNode().qualifier
        for _, id in ipairs(ids) do
            if qualifier ~= nil then
                qualifier = self.f:NewQualifiedName(qualifier, id)
            else
                qualifier = id
            end
        end
        return self.f:UpdateImportTypeNode(imprt, imprt.isTypeOf, imprt.argument, imprt.attributes, qualifier, ref:TypeArgumentList())
    elseif ast.IsTypeReferenceNode(root) then
        local typeRef = root:AsTypeReferenceNode()
        if self.ctx.flags & Flags.UseInstantiationExpressions ~= 0 and typeRef.typeArguments ~= nil and core.Len(typeRef.typeArguments.nodes) ~= 0 then
            local expr = self:createExpressionWithTypeArguments(self:createAccessExpression(typeRef.typeName), typeRef.typeArguments)
            for _, id in ipairs(checker.getAccessStack(ref)) do
                expr = self.f:NewPropertyAccessExpression(expr, nil, id, NodeFlags.None)
            end
            return expr
        end
        local typeName = typeRef.typeName
        for _, id in ipairs(checker.getAccessStack(ref)) do
            typeName = self.f:NewQualifiedName(typeName, id)
        end
        return self.f:UpdateTypeReferenceNode(root:AsTypeReferenceNode(), typeName, ref:TypeArgumentList())
    end
    local expr = self:createAccessExpression(root)
    for _, id in ipairs(checker.getAccessStack(ref)) do
        expr = self.f:NewPropertyAccessExpression(expr, nil, id, NodeFlags.None)
    end
    return expr
end

function checker.getAccessStack(ref)
    local state = ref:AsTypeReferenceNode().typeName
    local ids = {}
    while not ast.IsIdentifier(state) do
        local entity = state:AsQualifiedName()
        table.insert(ids, 1, entity.right)
        state = entity.left
    end
    table.insert(ids, 1, state)
    return ids
end

function checker.isClassInstanceSide(c, t)
    return t.symbol ~= nil and t.symbol.flags & SymbolFlags.Class ~= 0 and (t == c:getDeclaredTypeOfClassOrInterface(t.symbol) or (t.flags & TypeFlags.Object ~= 0 and t.objectFlags & ObjectFlags.IsClassInstanceClone ~= 0))
end

function NodeBuilderImpl:createElidedInformationPlaceholder()
    self.ctx.approximateLength = self.ctx.approximateLength + 3
    if self.ctx.flags & Flags.NoTruncation == 0 then
        return self.f:NewTypeReferenceNode(self.f:NewIdentifier("..."), nil --[[typeArguments]])
    end
    return self.e:AddSyntheticLeadingComment(self.f:NewKeywordTypeNode(Kind.AnyKeyword), Kind.MultiLineCommentTrivia, "elided", false --[[hasTrailingNewLine]])
end

function NodeBuilderImpl:mapToTypeNodes(list, isBareList)
    if core.Len(list) == 0 then
        return nil
    end

    if self:checkTruncationLength() then
        if not isBareList then
            local node
            if self.ctx.flags & Flags.NoTruncation ~= 0 then
                node = self.e:AddSyntheticLeadingComment(self.f:NewKeywordTypeNode(Kind.AnyKeyword), Kind.MultiLineCommentTrivia, "elided", false --[[hasTrailingNewLine]])
            else
                node = self.f:NewTypeReferenceNode(self.f:NewIdentifier("..."), nil --[[typeArguments]])
            end
            return self.f:NewNodeList({ node })
        elseif #list > 2 then
            local first = self:typeToTypeNode(list[1])
            local second
            local last = self:typeToTypeNode(list[#list])

            if self.ctx.flags & Flags.NoTruncation ~= 0 then
                second = self.e:AddSyntheticLeadingComment(self.f:NewKeywordTypeNode(Kind.AnyKeyword), Kind.MultiLineCommentTrivia, string.format("... %d more elided ...", #list - 2), false --[[hasTrailingNewLine]])
            else
                local text = string.format("... %d more ...", #list - 2)
                second = self.f:NewTypeReferenceNode(self.f:NewIdentifier(text), nil --[[typeArguments]])
            end
            local nodes = {}
            -- Go builds a 3-element slice; nil entries are kept out of the Lua array.
            if first ~= nil then
                nodes[#nodes + 1] = first
            end
            nodes[#nodes + 1] = second
            if last ~= nil then
                nodes[#nodes + 1] = last
            end
            return self.f:NewNodeList(nodes)
        end
    end

    local mayHaveNameCollisions = self.ctx.flags & Flags.UseFullyQualifiedType == 0
    -- seenName: { t, i }
    local seenNames
    if mayHaveNameCollisions then
        seenNames = collections.NewMultiMap()
    end

    local result = {}

    for i1, t in ipairs(list) do
        local i = i1 - 1
        local displayIndex = i + 1
        if self:checkTruncationLength() and (displayIndex + 2 < #list - 1) then
            if self.ctx.flags & Flags.NoTruncation ~= 0 then
                result[#result + 1] = self.e:AddSyntheticLeadingComment(self.f:NewKeywordTypeNode(Kind.AnyKeyword), Kind.MultiLineCommentTrivia, string.format("... %d more elided ...", #list - displayIndex), false --[[hasTrailingNewLine]])
            else
                local text = string.format("... %d more ...", #list - displayIndex)
                result[#result + 1] = self.f:NewTypeReferenceNode(self.f:NewIdentifier(text), nil --[[typeArguments]])
            end
            local typeNode = self:typeToTypeNode(list[#list])
            if typeNode ~= nil then
                result[#result + 1] = typeNode
            end
            break
        end
        self.ctx.approximateLength = self.ctx.approximateLength + 2 -- Account for whitespace + separator
        local typeNode = self:typeToTypeNode(t)
        if typeNode ~= nil then
            result[#result + 1] = typeNode
            if seenNames ~= nil and checker.isIdentifierTypeReference(typeNode) then
                seenNames:Add(typeNode:AsTypeReferenceNode().typeName:Text(), { t = t, i = #result - 1 })
            end
        end
    end

    if seenNames ~= nil then
        -- To avoid printing types like `[Foo, Foo]` or `Bar & Bar` where
        -- occurrences of the same name actually come from different
        -- namespaces, go through the single-identifier type reference nodes
        -- we just generated, and see if any names were generated more than
        -- once while referring to different types. If so, regenerate the
        -- type node for each entry by that name with the
        -- `UseFullyQualifiedType` flag enabled.
        local restoreFlags = self:saveRestoreFlags()
        self.ctx.flags = self.ctx.flags | Flags.UseFullyQualifiedType
        for types in seenNames:Values() do
            if not checker.arrayIsHomogeneous(types, function(a, b)
                return checker.typesAreSameReference(a.t, b.t)
            end) then
                for _, seen in ipairs(types) do
                    result[seen.i + 1] = self:typeToTypeNode(seen.t)
                end
            end
        end
        restoreFlags()
    end

    return self.f:NewNodeList(result)
end

function NodeBuilderImpl:serializeTypeName(node, isTypeOf, typeArguments)
    local meaning = SymbolFlags.Type
    if isTypeOf then
        meaning = SymbolFlags.Value
    end
    local symbol = self.ch:resolveEntityName(node, meaning, true, false, node)
    if symbol == nil then
        return nil
    end

    local resolvedSymbol = symbol
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        resolvedSymbol = self.ch:resolveAlias(symbol)
    end

    if self.ch:IsSymbolAccessible(symbol, self.ctx.enclosingDeclaration, meaning, false).accessibility ~= printer.SymbolAccessibility.Accessible then
        return nil
    end
    return self:symbolToTypeNode(resolvedSymbol, meaning, typeArguments)
end

function checker.isIdentifierTypeReference(node)
    return ast.IsTypeReferenceNode(node) and ast.IsIdentifier(node:AsTypeReferenceNode().typeName)
end

function checker.arrayIsHomogeneous(array, comparer)
    if core.Len(array) < 2 then
        return true
    end
    local first = array[1]
    for i = 2, #array do
        local target = array[i]
        if not comparer(first, target) then
            return false
        end
    end
    return true
end

function checker.typesAreSameReference(a, b)
    return a == b or a.symbol ~= nil and a.symbol == b.symbol or a.alias ~= nil and a.alias == b.alias
end

function NodeBuilderImpl:setCommentRange(node, range_)
    if range_ ~= nil and self.ctx.enclosingFile ~= nil and self.ctx.enclosingFile == ast.GetSourceFileOfNode(range_) then
        -- Copy comments to node for declaration emit
        self.e:AssignCommentRange(node, range_)
    end
end

function NodeBuilderImpl:typeNodeIsEquivalentToType(annotatedDeclaration, t, typeFromTypeNode)
    if typeFromTypeNode == t then
        return true
    end
    if annotatedDeclaration == nil then
        return false
    end
    -- !!!
    -- used to be hasEffectiveQuestionToken for JSDoc
    if checker.isOptionalDeclaration(annotatedDeclaration) then
        return self.ch:getTypeWithFacts(t, checker.TypeFacts.NEUndefined) == typeFromTypeNode
    end
    return false
end

function NodeBuilderImpl:canReuseExistingJSTypeNode(existing, t)
    return self.ch:getIntendedTypeFromJSDocTypeReference(existing) == nil and self:existingTypeNodeIsNotReferenceOrIsReferenceWithCompatibleTypeArgumentCount(existing, t)
end

function NodeBuilderImpl:tryGetResolvedSymbolFromTypeNode(node)
    if node == nil or node.parent == nil then
        return nil
    end
    self.ch:getTypeFromTypeNode(node)
    -- call to ensure symbol is resolved
    local links = self.ch.symbolNodeLinks:TryGet(node)
    if links == nil then
        return nil
    end
    return links.resolvedSymbol
end

function NodeBuilderImpl:existingTypeNodeIsNotReferenceOrIsReferenceWithCompatibleTypeArgumentCount(existing, t)
    -- In JS, you can say something like `Foo` and get a `Foo<any>` implicitly - we don't want to preserve that original `Foo` in these cases, though.
    if t.objectFlags & ObjectFlags.Reference == 0 then
        return true
    end
    if not ast.IsTypeReferenceNode(existing) then
        return true
    end

    local symbol = self:tryGetResolvedSymbolFromTypeNode(existing)
    if symbol == nil then
        return true
    end

    -- `type` is a reference type, and `existing` is a type reference node, but we still need to make sure they refer to the _same_ target type
    -- before we go comparing their type argument counts.

    local existingTarget = self.ch:getDeclaredTypeOfSymbol(symbol)
    if existingTarget == nil or existingTarget ~= t:AsTypeReference().target then
        return true
    end
    return core.Len(existing:TypeArguments()) >= self.ch:getMinTypeArgumentCount(t:AsTypeReference().target:AsInterfaceType():TypeParameters())
end

function NodeBuilderImpl:tryReuseExistingNonParameterTypeNode(existing, t, host, annotationType)
    if host == nil then
        host = self.ctx.enclosingDeclaration
    end
    if annotationType == nil then
        annotationType = self:getTypeFromTypeNode(existing, true)
    end
    if annotationType ~= nil and self:typeNodeIsEquivalentToType(host, t, annotationType) and self:canReuseExistingJSTypeNode(existing, t) then
        local result = self:tryReuseExistingNodeHelper(existing)
        if result ~= nil then
            return result
        end
    end
    return nil
end

function NodeBuilderImpl:getResolvedTypeWithoutAbstractConstructSignatures(t)
    if core.Len(t:ConstructSignatures()) == 0 then
        return t
    end
    if t.objectTypeWithoutAbstractConstructSignatures ~= nil then
        return t.objectTypeWithoutAbstractConstructSignatures
    end
    local constructSignatures = core.Filter(t:ConstructSignatures(), function(signature)
        return signature.flags & SignatureFlags.Abstract == 0
    end)
    if core.Len(constructSignatures) == core.Len(t:ConstructSignatures()) then
        t.objectTypeWithoutAbstractConstructSignatures = t
        return t
    end
    local sigs = constructSignatures
    if core.Len(constructSignatures) == 0 then
        sigs = {}
    end
    local typeCopy = self.ch:newAnonymousType(t.symbol, t.members, t:CallSignatures(), sigs, t.indexInfos)
    t.objectTypeWithoutAbstractConstructSignatures = typeCopy
    typeCopy:AsStructuredType().objectTypeWithoutAbstractConstructSignatures = typeCopy
    return typeCopy
end

function NodeBuilderImpl:symbolToNode(symbol, meaning)
    if self.ctx.internalFlags & InternalFlags.WriteComputedProps ~= 0 then
        if symbol.valueDeclaration ~= nil then
            local name = ast.GetNameOfDeclaration(symbol.valueDeclaration)
            if name ~= nil and ast.IsComputedPropertyName(name) then
                return name
            end
        end
        if self.ch.valueSymbolLinks:Has(symbol) then
            local nameType = self.ch.valueSymbolLinks:Get(symbol).nameType
            if nameType ~= nil and nameType.flags & (TypeFlags.EnumLiteral | TypeFlags.UniqueESSymbol) ~= 0 then
                local oldEnclosing = self.ctx.enclosingDeclaration
                self.ctx.enclosingDeclaration = nameType.symbol.valueDeclaration
                local result = self.f:NewComputedPropertyName(self:symbolToExpression(nameType.symbol, meaning))
                self.ctx.enclosingDeclaration = oldEnclosing
                return result
            end
        end
    end
    return self:symbolToExpression(symbol, meaning)
end

function NodeBuilderImpl:symbolToName(symbol, meaning, expectsIdentifier)
    local chain = self:lookupSymbolChain(symbol, meaning, false)
    if expectsIdentifier and core.Len(chain) ~= 1 and not self.ctx.encounteredError and (self.ctx.flags & Flags.AllowQualifiedNameInPlaceOfIdentifier ~= 0) then
        self.ctx.encounteredError = true
    end
    return self:createEntityNameFromSymbolChain(chain, core.Len(chain) - 1)
end

function NodeBuilderImpl:createEntityNameFromSymbolChain(chain, index)
    -- typeParameterNodes := b.lookupTypeParameterNodes(chain, index)
    local symbol = chain[index + 1]

    if index == 0 then
        self.ctx.flags = self.ctx.flags | Flags.InInitialEntityName
    end
    local symbolName = self:getNameOfSymbolAsWritten(symbol)
    if index == 0 then
        self.ctx.flags = self.ctx.flags ~ Flags.InInitialEntityName
    end

    local identifier = self:newIdentifier(symbolName, symbol)
    self.e:AddEmitFlags(identifier, EmitFlags.EFNoAsciiEscaping)
    -- !!! TODO: smuggle type arguments out
    -- if (typeParameterNodes) setIdentifierTypeArguments(identifier, factory.createNodeArray<TypeNode | TypeParameterDeclaration>(typeParameterNodes));
    -- identifier.symbol = symbol;
    -- expression = identifier;
    if index > 0 then
        return self.f:NewQualifiedName(
            self:createEntityNameFromSymbolChain(chain, index - 1),
            identifier
        )
    end
    return identifier
end

-- TODO: Audit usages of symbolToEntityNameNode - they should probably all be symbolToName
function NodeBuilderImpl:symbolToEntityNameNode(symbol)
    local identifier = self:newIdentifier(symbol.name, symbol)
    if symbol.parent ~= nil then
        return self.f:NewQualifiedName(self:symbolToEntityNameNode(symbol.parent), identifier)
    end
    return identifier
end

function NodeBuilderImpl:symbolToTypeNode(symbol, mask, typeArguments)
    local chain = self:lookupSymbolChain(symbol, mask, (self.ctx.flags & Flags.UseAliasDefinedOutsideCurrentScope == 0)) -- If we're using aliases outside the current scope, dont bother with the module
    if core.Len(chain) == 0 then
        return nil -- TODO: shouldn't be possible, `lookupSymbolChain` should always at least return the input symbol and issue an error
    end
    local isTypeOf = mask == SymbolFlags.Value
    if core.Some(chain[1].declarations, checker.hasNonGlobalAugmentationExternalModuleSymbol) then
        -- module is root, must use `ImportTypeNode`
        local nonRootParts
        if #chain > 1 then
            nonRootParts = self:createAccessFromSymbolChain(chain, #chain - 1, 1, typeArguments)
        end
        local typeParameterNodes = typeArguments
        if typeParameterNodes == nil then
            typeParameterNodes = self:lookupTypeParameterNodes(chain, 0)
        end
        local contextFile = ast.GetSourceFileOfNode(self.e:MostOriginal(self.ctx.enclosingDeclaration)) -- TODO: Just use b.ctx.enclosingFile ? Or is the delayed lookup important for context moves?
        local targetFile = ast.GetSourceFileOfModule(chain[1])
        local specifier = ""
        local attributes
        if self.ch.compilerOptions:GetModuleResolutionKind() == core.ModuleResolutionKind.Node16 or self.ch.compilerOptions:GetModuleResolutionKind() == core.ModuleResolutionKind.NodeNext then
            -- An `import` type directed at an esm format file is only going to resolve in esm mode - set the esm mode assertion
            if targetFile ~= nil and contextFile ~= nil and self.ch.program:GetEmitModuleFormatOfFile(targetFile) == ModuleKind.ESNext and self.ch.program:GetEmitModuleFormatOfFile(targetFile) ~= self.ch.program:GetEmitModuleFormatOfFile(contextFile) then
                specifier = self:getSpecifierForModuleSymbol(chain[1], ModuleKind.ESNext)
                attributes = self.f:NewImportAttributes(
                    Kind.WithKeyword,
                    self.f:NewNodeList({ self.f:NewImportAttribute(self:newStringLiteral("resolution-mode"), self:newStringLiteral("import")) }),
                    false
                )
            end
        end
        if #specifier == 0 then
            specifier = self:getSpecifierForModuleSymbol(chain[1], ModuleKind.ResolutionModeNone)
        end
        if (self.ctx.flags & Flags.AllowNodeModulesRelativePaths == 0) --[[ && b.ch.compilerOptions.GetModuleResolutionKind() != core.ModuleResolutionKindClassic ]] and string.find(specifier, "/node_modules/", 1, true) ~= nil then
            local oldSpecifier = specifier

            if self.ch.compilerOptions:GetModuleResolutionKind() == core.ModuleResolutionKind.Node16 or self.ch.compilerOptions:GetModuleResolutionKind() == core.ModuleResolutionKind.NodeNext then
                -- We might be able to write a portable import type using a mode override; try specifier generation again, but with a different mode set
                local swappedMode = ModuleKind.ESNext
                if self.ch.program:GetEmitModuleFormatOfFile(contextFile) == ModuleKind.ESNext then
                    swappedMode = ModuleKind.CommonJS
                end
                specifier = self:getSpecifierForModuleSymbol(chain[1], swappedMode)

                if string.find(specifier, "/node_modules/", 1, true) ~= nil then
                    -- Still unreachable :(
                    specifier = oldSpecifier
                else
                    local modeStr = "require"
                    if swappedMode == ModuleKind.ESNext then
                        modeStr = "import"
                    end
                    attributes = self.f:NewImportAttributes(
                        Kind.WithKeyword,
                        self.f:NewNodeList({ self.f:NewImportAttribute(self:newStringLiteral("resolution-mode"), self:newStringLiteral(modeStr)) }),
                        false
                    )
                end
            end

            if attributes == nil then
                -- If ultimately we can only name the symbol with a reference that dives into a `node_modules` folder, we should error
                -- since declaration files with these kinds of references are liable to fail when published :(
                self.ctx.encounteredError = true
                self.ctx.tracker:ReportLikelyUnsafeImportRequiredError(oldSpecifier, symbol.name)
            end
        end

        local lit = self.f:NewLiteralTypeNode(self:newStringLiteral(specifier))
        self.ctx.approximateLength = self.ctx.approximateLength + #specifier + 10 -- specifier + import("")
        if nonRootParts == nil or ast.IsEntityName(nonRootParts) then
            if nonRootParts ~= nil then
                -- !!! TODO: smuggle type arguments out
                -- const lastId = isIdentifier(nonRootParts) ? nonRootParts : nonRootParts.right;
                -- setIdentifierTypeArguments(lastId, /*typeArguments*/ undefined);
            end
            return self.f:NewImportTypeNode(isTypeOf, lit, attributes, nonRootParts, typeParameterNodes)
        end

        local splitNode = checker.getTopmostIndexedAccessType(nonRootParts:AsIndexedAccessTypeNode())
        local qualifier = splitNode.objectType:AsTypeReferenceNode().typeName
        return self.f:NewIndexedAccessTypeNode(
            self.f:NewImportTypeNode(isTypeOf, lit, attributes, qualifier, typeParameterNodes),
            splitNode.indexType
        )
    end

    local entityName = self:createAccessFromSymbolChain(chain, #chain - 1, 0, typeArguments)
    if ast.IsIndexedAccessTypeNode(entityName) then
        return entityName -- Indexed accesses can never be `typeof`
    end
    if ast.IsEntityName(entityName) then
        if isTypeOf then
            return self.f:NewTypeQueryNode(entityName, nil)
        end
        return self.f:NewTypeReferenceNode(entityName, typeArguments)
    end
    if isTypeOf and ast.IsExpressionWithTypeArguments(entityName) then
        local expr = entityName:AsExpressionWithTypeArguments()
        return self.f:NewTypeQueryNode(self.f:DeepCloneNode(expr.expression), expr.typeArguments)
    end
    return entityName
end

function checker.getTopmostIndexedAccessType(node)
    if ast.IsIndexedAccessTypeNode(node.objectType) then
        return checker.getTopmostIndexedAccessType(node.objectType:AsIndexedAccessTypeNode())
    end
    return node
end

function NodeBuilderImpl:createAccessFromSymbolChain(chain, index, stopper, overrideTypeArguments)
    local typeParameterNodes = overrideTypeArguments
    if index ~= (#chain - 1) then
        typeParameterNodes = self:lookupTypeParameterNodes(chain, index)
    end
    local symbol = chain[index + 1]
    local parent
    if index > 0 then
        parent = chain[index]
    end

    local symbolName = ""
    if index == 0 then
        self.ctx.flags = self.ctx.flags | Flags.InInitialEntityName
        symbolName = self:getNameOfSymbolAsWritten(symbol)
        self.ctx.approximateLength = self.ctx.approximateLength + #symbolName + 1
        self.ctx.flags = self.ctx.flags ~ Flags.InInitialEntityName
    else
        -- lookup a ref to symbol within parent to handle export aliases
        if parent ~= nil then
            local exports = self.ch:getExportsOfSymbol(parent)
            if exports ~= nil then
                -- avoid exhaustive iteration in the common case
                local res = exports[symbol.name]
                if symbol.name ~= ast.InternalSymbolNameExportEquals and not checker.isLateBoundName(symbol.name) and res ~= nil and self.ch:getSymbolIfSameReference(res, symbol) ~= nil then
                    symbolName = symbol.name
                else
                    local results = {}
                    local resultSymbols = {}
                    for name, ex in pairs(exports) do
                        if self.ch:getSymbolIfSameReference(ex, symbol) ~= nil and not checker.isLateBoundName(name) and name ~= ast.InternalSymbolNameExportEquals then
                            if results[ex] == nil then
                                resultSymbols[#resultSymbols + 1] = ex
                            end
                            results[ex] = name
                            -- break // must collect all results and sort them - exports are randomly iterated
                        end
                    end
                    if #resultSymbols > 0 then
                        self.ch:sortSymbols(resultSymbols)
                        symbolName = results[resultSymbols[1]]
                    end
                end
            end
        end
    end

    if #symbolName == 0 then
        local name
        for _, d in ipairs(symbol.declarations or {}) do
            name = ast.GetNameOfDeclaration(d)
            if name ~= nil then
                break
            end
        end
        if name ~= nil and ast.IsComputedPropertyName(name) and ast.IsEntityName(name:Expression()) then
            local lhs = self:createAccessFromSymbolChain(chain, index - 1, stopper, overrideTypeArguments)
            if ast.IsEntityName(lhs) then
                return self.f:NewIndexedAccessTypeNode(
                    self.f:NewParenthesizedTypeNode(self.f:NewTypeQueryNode(lhs, nil)),
                    self.f:NewTypeQueryNode(name:Expression(), nil)
                )
            end
            return lhs
        end
        symbolName = self:getNameOfSymbolAsWritten(symbol)
    end
    self.ctx.approximateLength = self.ctx.approximateLength + #symbolName + 1

    if (self.ctx.flags & Flags.ForbidIndexedAccessSymbolReferences == 0) and parent ~= nil then
        local parentMembers = self.ch:getMembersOfSymbol(parent)
        if parentMembers ~= nil and parentMembers[symbol.name] ~= nil and
            self.ch:getSymbolIfSameReference(self.ch:getMembersOfSymbol(parent)[symbol.name], symbol) ~= nil then
            -- Should use an indexed access
            local lhs = self:createAccessFromSymbolChain(chain, index - 1, stopper, overrideTypeArguments)
            if ast.IsIndexedAccessTypeNode(lhs) then
                return self.f:NewIndexedAccessTypeNode(
                    lhs,
                    self.f:NewLiteralTypeNode(self:newStringLiteral(symbolName))
                )
            end
            return self.f:NewIndexedAccessTypeNode(
                self.f:NewTypeReferenceNode(lhs, typeParameterNodes),
                self.f:NewLiteralTypeNode(self:newStringLiteral(symbolName))
            )
        end
    end

    local identifier = self:newIdentifier(symbolName, symbol)
    self.e:AddEmitFlags(identifier, EmitFlags.EFNoAsciiEscaping)

    if index > stopper then
        local lhs = self:createAccessFromSymbolChain(chain, index - 1, stopper, overrideTypeArguments)
        if self.ctx.flags & Flags.UseInstantiationExpressions == 0 or ast.IsEntityName(lhs) and (typeParameterNodes == nil or core.Len(typeParameterNodes.nodes) == 0) then
            return self.f:NewQualifiedName(lhs, identifier)
        end
        return self:createExpressionWithTypeArguments(self.f:NewPropertyAccessExpression(self:createAccessExpression(lhs), nil, identifier, NodeFlags.None), typeParameterNodes)
    end
    return identifier
end

function NodeBuilderImpl:symbolToExpression(symbol, mask)
    local chain = self:lookupSymbolChain(symbol, mask, false)
    return self:createExpressionFromSymbolChain(chain, #chain - 1)
end

function NodeBuilderImpl:createExpressionFromSymbolChain(chain, index)
    local typeParameterNodes = self:lookupExpressionChainTypeArgumentNodes(chain, index)
    local symbol = chain[index + 1]

    if index == 0 then
        self.ctx.flags = self.ctx.flags | Flags.InInitialEntityName
    end
    local symbolName = self:getNameOfSymbolAsWritten(symbol)
    if index == 0 then
        self.ctx.flags = self.ctx.flags ~ Flags.InInitialEntityName
    end

    if checker.startsWithSingleOrDoubleQuote(symbolName) and core.Some(symbol.declarations, checker.hasNonGlobalAugmentationExternalModuleSymbol) then
        local specifier = self:getSpecifierForModuleSymbol(symbol, ModuleKind.ResolutionModeNone)
        self.ctx.approximateLength = self.ctx.approximateLength + 2 + #specifier
        return self:newStringLiteral(specifier)
    end

    if index == 0 or checker.canUsePropertyAccess(symbolName) then
        local identifier = self:newIdentifier(symbolName, symbol)
        self.e:AddEmitFlags(identifier, EmitFlags.EFNoAsciiEscaping)
        self.ctx.approximateLength = self.ctx.approximateLength + 1 + #symbolName
        if index > 0 then
            local result = self.f:NewPropertyAccessExpression(self:createExpressionFromSymbolChain(chain, index - 1), nil, identifier, NodeFlags.None)
            self.e:AddEmitFlags(result, EmitFlags.EFNoIndentation)
            return self:createExpressionWithTypeArguments(result, typeParameterNodes)
        end
        return self:createExpressionWithTypeArguments(identifier, typeParameterNodes)
    end

    if checker.startsWithSquareBracket(symbolName) then
        symbolName = string.sub(symbolName, 2, #symbolName - 1)
    end

    local expression
    if checker.startsWithSingleOrDoubleQuote(symbolName) and symbol.flags & SymbolFlags.EnumMember == 0 then
        local literalText = stringutil.UnquoteString(symbolName)
        self.ctx.approximateLength = self.ctx.approximateLength + #literalText + 2
        expression = self:newStringLiteralEx(literalText, string.byte(symbolName, 1) == 39 --[[ '\'' ]])
    elseif jsnum.Number_String(jsnum.FromString(symbolName)) == symbolName then
        -- TODO: the follwing in strada would assert if the number is negative, but no such assertion exists here
        -- Moreover, what's even guaranteeing the name *isn't* -1 here anyway? Needs double-checking.
        self.ctx.approximateLength = self.ctx.approximateLength + #symbolName
        expression = self.f:NewNumericLiteral(symbolName, ast.TokenFlags.None)
    end
    if expression == nil then
        self.ctx.approximateLength = self.ctx.approximateLength + #symbolName
        expression = self:newIdentifier(symbolName, symbol)
        self.e:AddEmitFlags(expression, EmitFlags.EFNoAsciiEscaping)
    end
    self.ctx.approximateLength = self.ctx.approximateLength + 2 -- []
    return self:createExpressionWithTypeArguments(self.f:NewElementAccessExpression(self:createExpressionFromSymbolChain(chain, index - 1), nil, expression, NodeFlags.None), typeParameterNodes)
end

function checker.canUsePropertyAccess(name)
    if #name == 0 then
        return false
    end
    -- TODO: in strada, this only used `isIdentifierStart` on the first character, while this checks the whole string for validity
    -- - possible strada bug?
    if string.sub(name, 1, 1) == "#" then
        return #name > 1 and scanner.IsIdentifierText(string.sub(name, 2), core.LanguageVariant.Standard)
    end
    return scanner.IsIdentifierText(name, core.LanguageVariant.Standard)
end

function checker.startsWithSingleOrDoubleQuote(str)
    local c = string.sub(str, 1, 1)
    return c == "'" or c == "\""
end

function checker.startsWithSquareBracket(str)
    return string.sub(str, 1, 1) == "["
end

function checker.isDefaultBindingContext(location)
    return location.kind == Kind.SourceFile or ast.IsAmbientModule(location)
end

function NodeBuilderImpl:getNameOfSymbolFromNameType(symbol)
    if self.ch.valueSymbolLinks:Has(symbol) then
        local nameType = self.ch.valueSymbolLinks:Get(symbol).nameType
        if nameType == nil then
            return ""
        end
        if nameType.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
            local name = ""
            local v = nameType:AsLiteralType().value
            if type(v) == "string" then
                name = v
            elseif type(v) == "number" then
                name = jsnum.Number_String(v)
            end
            if not scanner.IsIdentifierText(name, core.LanguageVariant.Standard) and not checker.isNumericLiteralName(name) then
                return self.ch:valueToString(nameType:AsLiteralType().value)
            end
            if checker.isNumericLiteralName(name) and string.sub(name, 1, 1) == "-" then
                return "[" .. name .. "]"
            end
            return name
        end
        if nameType.flags & TypeFlags.UniqueESSymbol ~= 0 then
            local text = self:getNameOfSymbolAsWritten(nameType:AsUniqueESSymbolType().symbol)
            return "[" .. text .. "]"
        end
    end
    return ""
end

--[[
* Gets a human-readable name for a symbol.
* Should *not* be used for the right-hand side of a `.` -- use `symbolName(symbol)` for that instead.
*
* Unlike `symbolName(symbol)`, this will include quotes if the name is from a string literal.
* It will also use a representation of a number as written instead of a decimal form, e.g. `0o11` instead of `9`.
]]
function NodeBuilderImpl:getNameOfSymbolAsWritten(symbol)
    local result = self.ctx.remappedSymbolReferences[ast.GetSymbolId(symbol)]
    if result ~= nil then
        symbol = result
    end
    if symbol.name == ast.InternalSymbolNameDefault and (self.ctx.flags & Flags.UseAliasDefinedOutsideCurrentScope == 0) and
        -- If it's not the first part of an entity name, it must print as `default`
        ((self.ctx.flags & Flags.InInitialEntityName == 0) or
            -- if the symbol is synthesized, it will only be referenced externally it must print as `default`
            core.Len(symbol.declarations) == 0 or
            -- if not in the same binding context (source file, module declaration), it must print as `default`
            (self.ctx.enclosingDeclaration ~= nil and ast.FindAncestor(symbol.declarations[1], checker.isDefaultBindingContext) ~= ast.FindAncestor(self.ctx.enclosingDeclaration, checker.isDefaultBindingContext))) then
        return "default"
    end
    if core.Len(symbol.declarations) > 0 then
        local name = core.FirstNonNil(symbol.declarations, ast.GetNameOfDeclaration) -- Try using a declaration with a name, first
        if name ~= nil then
            -- !!! TODO: JS Object.defineProperty declarations
            -- if ast.IsCallExpression(declaration) && ast.IsBindableObjectDefinePropertyCall(declaration) {
            -- 	return symbol.Name
            -- }
            if ast.IsComputedPropertyName(name) and symbol.checkFlags & CheckFlags.Late == 0 then
                if self.ch.valueSymbolLinks:Has(symbol) and self.ch.valueSymbolLinks:Get(symbol).nameType ~= nil and self.ch.valueSymbolLinks:Get(symbol).nameType.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
                    local r = self:getNameOfSymbolFromNameType(symbol)
                    if #r > 0 then
                        return r
                    end
                end
            end
            return scanner.DeclarationNameToString(name)
        end
        local declaration = symbol.declarations[1] -- Declaration may be nameless, but we'll try anyway
        if declaration.parent ~= nil and declaration.parent.kind == Kind.VariableDeclaration then
            return scanner.DeclarationNameToString(declaration.parent:AsVariableDeclaration():Name())
        end
        if ast.IsClassExpression(declaration) or ast.IsFunctionExpression(declaration) or ast.IsArrowFunction(declaration) then
            if self.ctx ~= nil and not self.ctx.encounteredError and self.ctx.flags & Flags.AllowAnonymousIdentifier == 0 then
                self.ctx.encounteredError = true
            end
            if declaration.kind == Kind.ClassExpression then
                return "(Anonymous class)"
            elseif declaration.kind == Kind.FunctionExpression or declaration.kind == Kind.ArrowFunction then
                return "(Anonymous function)"
            end
        end
    end
    local name = self:getNameOfSymbolFromNameType(symbol)
    if #name > 0 then
        return name
    end
    return ast.EscapeInternalSymbolName(symbol.name)
end

-- The full set of type parameters for a generic class or interface type consists of its outer type parameters plus
-- its locally declared type parameters.
function NodeBuilderImpl:getTypeParametersOfClassOrInterface(symbol)
    local result = {}
    core.AppendAll(result, self.ch:getOuterTypeParametersOfClassOrInterface(symbol))
    core.AppendAll(result, self.ch:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol))
    return result
end

function NodeBuilderImpl:lookupTypeParameterNodes(chain, index)
    debug.Assert(chain ~= nil and 0 <= index and index < #chain)
    local symbol = chain[index + 1]
    local symbolId = ast.GetSymbolId(symbol)
    if self.ctx.typeParameterSymbolList:Has(symbolId) then
        return nil
    end
    self.ctx.typeParameterSymbolList:Add(symbolId)

    if self.ctx.flags & Flags.WriteTypeParametersInQualifiedName ~= 0 and index < (#chain - 1) then
        local typeArgumentNodes = self:lookupInstantiatedTypeArgumentNodes(chain, index)
        if typeArgumentNodes ~= nil then
            return typeArgumentNodes
        else
            local typeParameterNodes = self:typeParametersToTypeParameterDeclarations(symbol)
            if core.Len(typeParameterNodes) > 0 then
                return self.f:NewNodeList(typeParameterNodes)
            end
            return nil
        end
    end

    return nil
end

-- TODO: move `lookupSymbolChain` and co to `symbolaccessibility.go` (but getSpecifierForModuleSymbol uses much context which makes that hard?)
function NodeBuilderImpl:lookupSymbolChain(symbol, meaning, yieldModuleSymbol)
    self.ctx.tracker:TrackSymbol(symbol, self.ctx.enclosingDeclaration, meaning)
    return self:lookupSymbolChainWorker(symbol, meaning, yieldModuleSymbol)
end

function NodeBuilderImpl:lookupSymbolChainWorker(symbol, meaning, yieldModuleSymbol)
    -- Try to get qualified name if the symbol is not a type parameter and there is an enclosing declaration.
    local chain
    local isTypeParameter = symbol.flags & SymbolFlags.TypeParameter ~= 0
    if not isTypeParameter and (self.ctx.enclosingDeclaration ~= nil or self.ctx.flags & Flags.UseFullyQualifiedType ~= 0) and (self.ctx.internalFlags & InternalFlags.DoNotIncludeSymbolChain == 0) then
        local res = self:getSymbolChain(symbol, meaning, --[[endOfChain]] true, yieldModuleSymbol)
        chain = res
        debug.Assert(chain ~= nil)
        debug.Assert(#chain > 0)
    else
        chain = { symbol }
    end
    return chain
end

-- sortedSymbolNamePair: { sym, name }

--[[ @param endOfChain Set to false for recursive calls; non-recursive calls should always output something. ]]
function NodeBuilderImpl:getSymbolChain(symbol, meaning, endOfChain, yieldModuleSymbol)
    local accessibleSymbolChain = self.ch:getAccessibleSymbolChain(symbol, self.ctx.enclosingDeclaration, meaning, self.ctx.flags & Flags.UseOnlyExternalAliasing ~= 0)
    local qualifierMeaning = meaning
    if core.Len(accessibleSymbolChain) > 1 then
        qualifierMeaning = checker.getQualifiedLeftMeaning(meaning)
    end
    if core.Len(accessibleSymbolChain) == 0 or
        self.ch:needsQualification(accessibleSymbolChain[1], self.ctx.enclosingDeclaration, qualifierMeaning) then
        -- Go up and add our parent.
        local root = symbol
        if core.Len(accessibleSymbolChain) > 0 then
            root = accessibleSymbolChain[1]
        end
        local parents = self.ch:getContainersOfSymbol(root, self.ctx.enclosingDeclaration, meaning)
        if core.Len(parents) > 0 then
            local parentSpecifiers = core.Map(parents, function(s)
                if core.Some(s.declarations, checker.hasNonGlobalAugmentationExternalModuleSymbol) then
                    return { sym = s, name = self:getSpecifierForModuleSymbol(s, ModuleKind.ResolutionModeNone) }
                end
                return { sym = s, name = "" }
            end)
            core.SortStableFunc(parentSpecifiers, function(a, b) return self:sortByBestName(a, b) end)
            for _, pair in ipairs(parentSpecifiers) do
                local parent = pair.sym
                local parentChain = self:getSymbolChain(parent, checker.getQualifiedLeftMeaning(meaning), false, yieldModuleSymbol)
                if core.Len(parentChain) > 0 then
                    if parent.exports ~= nil then
                        local exported = parent.exports[ast.InternalSymbolNameExportEquals]
                        if exported ~= nil and self.ch:getSymbolIfSameReference(exported, symbol) ~= nil then
                            -- parentChain root _is_ symbol - symbol is a module export=, so it kinda looks like it's own parent
                            -- No need to lookup an alias for the symbol in itself
                            accessibleSymbolChain = parentChain
                            break
                        end
                    end
                    local nextSyms = accessibleSymbolChain
                    if core.Len(nextSyms) == 0 then
                        local fallback = self.ch:getAliasForSymbolInContainer(parent, symbol)
                        if fallback == nil then
                            fallback = symbol
                        end
                        nextSyms = { fallback }
                    end
                    -- Go's append(parentChain, nextSyms...) may write into parentChain's backing array; copy instead.
                    accessibleSymbolChain = core.AppendAll(core.Slice(parentChain, 0), nextSyms)
                    break
                end
            end
        end
    end
    if core.Len(accessibleSymbolChain) > 0 then
        return accessibleSymbolChain
    end
    if
    -- If this is the last part of outputting the symbol, always output. The cases apply only to parent symbols.
        endOfChain or
        -- If a parent symbol is an anonymous type, don't write it.
        (symbol.flags & (SymbolFlags.TypeLiteral | SymbolFlags.ObjectLiteral) == 0) then
        -- If a parent symbol is an external module, don't write it. (We prefer just `x` vs `"foo/bar".x`.)
        if not endOfChain and not yieldModuleSymbol and core.Some(symbol.declarations, checker.hasNonGlobalAugmentationExternalModuleSymbol) then
            return nil
        end
        return { symbol }
    end
    return nil
end

function NodeBuilderImpl:sortByBestName(a, b)
    local specifierA = a.name
    local specifierB = b.name
    if #specifierA > 0 and #specifierB > 0 then
        local isBRelative = tspath.PathIsRelative(specifierB)
        if tspath.PathIsRelative(specifierA) == isBRelative then
            -- Both relative or both non-relative, sort by number of parts
            return modulespecifiers.CountPathComponents(specifierA) - modulespecifiers.CountPathComponents(specifierB)
        end
        if isBRelative then
            -- A is non-relative, B is relative: prefer A
            return -1
        end
        -- A is relative, B is non-relative: prefer B
        return 1
    end
    return self.ch.compareSymbols(a.sym, b.sym) -- must sort symbols for stable ordering
end

local moduleSpecifierKinds = ast.kindSet(
    Kind.VariableDeclaration,
    Kind.BindingElement,
    Kind.ImportDeclaration,
    Kind.ExportDeclaration,
    Kind.ImportEqualsDeclaration,
    Kind.ImportClause,
    Kind.NamespaceExport,
    Kind.NamespaceImport,
    Kind.ExportSpecifier,
    Kind.ImportSpecifier,
    Kind.ImportType
)

function checker.canHaveModuleSpecifier(node)
    if node == nil then
        return false
    end
    return moduleSpecifierKinds[node.kind] == true
end

function checker.TryGetModuleSpecifierFromDeclaration(node)
    local res = checker.tryGetModuleSpecifierFromDeclarationWorker(node)
    if res == nil or not ast.IsStringLiteral(res) then
        return nil
    end
    return res
end

function checker.tryGetModuleSpecifierFromDeclarationWorker(node)
    local k = node.kind
    if k == Kind.VariableDeclaration or k == Kind.BindingElement then
        local requireCall = ast.FindAncestor(node:Initializer(), function(n)
            return ast.IsRequireCall(n, true --[[requireStringLiteralLikeArgument]])
        end)
        if requireCall == nil then
            return nil
        end
        return requireCall:Arguments()[1]
    elseif k == Kind.ImportDeclaration or k == Kind.ExportDeclaration or k == Kind.JSDocImportTag then
        return node:ModuleSpecifier()
    elseif k == Kind.ImportEqualsDeclaration then
        local ref = node:AsImportEqualsDeclaration().moduleReference
        if ref.kind ~= Kind.ExternalModuleReference then
            return nil
        end
        return ref:Expression()
    elseif k == Kind.ImportClause then
        if ast.IsImportDeclaration(node.parent) then
            return node.parent:ModuleSpecifier()
        end
        return node.parent:ModuleSpecifier()
    elseif k == Kind.NamespaceExport then
        return node.parent:ModuleSpecifier()
    elseif k == Kind.NamespaceImport then
        if ast.IsImportDeclaration(node.parent.parent) then
            return node.parent.parent:ModuleSpecifier()
        end
        return node.parent.parent:ModuleSpecifier()
    elseif k == Kind.ExportSpecifier then
        return node.parent.parent:ModuleSpecifier()
    elseif k == Kind.ImportSpecifier then
        if ast.IsImportDeclaration(node.parent.parent.parent) then
            return node.parent.parent.parent:ModuleSpecifier()
        end
        return node.parent.parent.parent:ModuleSpecifier()
    elseif k == Kind.ImportType then
        if ast.IsLiteralImportTypeNode(node) then
            return node:AsImportTypeNode().argument:AsLiteralTypeNode().literal
        end
        return nil
    else
        debug.AssertNever(node)
        return nil
    end
end

function NodeBuilderImpl:getSpecifierForModuleSymbol(symbol, overrideImportMode)
    local file = ast.GetDeclarationOfKind(symbol, Kind.SourceFile)
    if file == nil then
        local equivalentSymbol = core.FirstNonNil(symbol.declarations, function(d)
            return self.ch:getFileSymbolIfFileSymbolExportEqualsContainer(d, symbol)
        end)
        if equivalentSymbol ~= nil then
            file = ast.GetDeclarationOfKind(equivalentSymbol, Kind.SourceFile)
        end
    end

    if file == nil then
        if ast.IsAmbientModuleSymbolName(symbol.name) then
            return stringutil.StripQuotes(symbol.name)
        end
    end
    if self.ctx.enclosingFile == nil then
        if ast.IsAmbientModuleSymbolName(symbol.name) then
            return stringutil.StripQuotes(symbol.name)
        end
        return ast.GetSourceFileOfModule(symbol):FileName()
    end

    local enclosingDeclaration = self.e:MostOriginal(self.ctx.enclosingDeclaration)
    local originalModuleSpecifier
    if checker.canHaveModuleSpecifier(enclosingDeclaration) then
        originalModuleSpecifier = checker.TryGetModuleSpecifierFromDeclaration(enclosingDeclaration)
    end
    local contextFile = self.ctx.enclosingFile
    local resolutionMode = overrideImportMode
    if resolutionMode == ModuleKind.ResolutionModeNone and originalModuleSpecifier ~= nil then
        resolutionMode = self.ch.program:GetModeForUsageLocation(contextFile, originalModuleSpecifier)
    elseif resolutionMode == ModuleKind.ResolutionModeNone and contextFile ~= nil then
        resolutionMode = self.ch.program:GetDefaultResolutionModeForFile(contextFile)
    end
    local cacheKey = module.ModeAwareCacheKeyString(contextFile:Path(), resolutionMode)
    local links = self.symbolLinks:Get(symbol)
    if links.specifierCache == nil then
        links.specifierCache = {}
    end
    local result = links.specifierCache[cacheKey]
    if result ~= nil then
        return result
    end
    -- For declaration bundles, we need to generate absolute paths relative to the common source dir for imports,
    -- just like how the declaration emitter does for the ambient module declarations - we can easily accomplish this
    -- using the `baseUrl` compiler option (which we would otherwise never use in declaration emit) and a non-relative
    -- specifier preference
    local host = self.ctx.host
    local specifierCompilerOptions = self.ch.compilerOptions
    local specifierPref = modulespecifiers.ImportModuleSpecifierPreference.ProjectRelative
    local endingPref = modulespecifiers.ImportModuleSpecifierEndingPreference.None
    if resolutionMode == ModuleKind.ResolutionModeESM then
        endingPref = modulespecifiers.ImportModuleSpecifierEndingPreference.Js
    end

    local allSpecifiers = modulespecifiers.GetModuleSpecifiers(
        symbol,
        self.ch,
        specifierCompilerOptions,
        contextFile,
        host,
        modulespecifiers.UserPreferences_new({
            importModuleSpecifierPreference = specifierPref,
            importModuleSpecifierEnding = endingPref,
        }),
        modulespecifiers.ModuleSpecifierOptions_new({
            overrideImportMode = overrideImportMode,
        }),
        false --[[forAutoImports]]
    )
    if core.Len(allSpecifiers) == 0 then
        links.specifierCache[cacheKey] = ""
        return ""
    end
    local specifier = allSpecifiers[1]
    links.specifierCache[cacheKey] = specifier
    return specifier
end

function NodeBuilderImpl:typeParameterToDeclarationWithConstraint(typeParameter, constraintNode)
    local restoreFlags = self:saveRestoreFlags()
    self.ctx.flags = self.ctx.flags & ~Flags.WriteTypeParametersInQualifiedName -- Avoids potential infinite loop when building for a claimspace with a generic
    local modifiers = ast.CreateModifiersFromModifierFlags(self.ch:getTypeParameterModifiers(typeParameter), function(kind) return self.f:NewModifier(kind) end)
    local modifiersList
    if core.Len(modifiers) > 0 then
        modifiersList = self.f:NewModifierList(modifiers)
    end
    local name = self:typeParameterToName(typeParameter)
    local defaultParameter = self.ch:getDefaultFromTypeParameter(typeParameter)
    local defaultParameterDeclarationNode
    if defaultParameter ~= nil then
        defaultParameterDeclarationNode = self:typeToTypeNode(defaultParameter)
    end
    restoreFlags()
    return self.f:NewTypeParameterDeclaration(
        modifiersList,
        name,
        constraintNode,
        nil, -- expression
        defaultParameterDeclarationNode
    )
end

--[[
* Unlike the utilities `setTextRange`, this checks if the `location` we're trying to set on `range` is within the
* same file as the active context. If not, the range is not applied. This prevents us from copying ranges across files,
* which will confuse the node printer (as it assumes all node ranges are within the current file).
* Additionally, if `range` _isn't synthetic_, or isn't in the current file, it will _copy_ it to _remove_ its' position
* information.
*
* It also calls `setOriginalNode` to setup a `.original` pointer, since you basically *always* want these in the node builder.
]]
function NodeBuilderImpl:setTextRange(range_, location)
    if range_ == nil then
        return range_
    end
    if not ast.NodeIsSynthesized(range_) or (range_.flags & NodeFlags.Synthesized == 0) or self.ctx.enclosingFile == nil or self.ctx.enclosingFile ~= ast.GetSourceFileOfNode(self.e:MostOriginal(range_)) then
        local original = range_
        range_ = range_:Clone(self.f) -- if `range` is synthesized or originates in another file, copy it so it definitely has synthetic positions
        range_.loc = core.NewTextRange(-1, -1)
        local symbol = self.idToSymbol[original]
        if symbol ~= nil then
            self.idToSymbol[range_] = symbol
        end
    end
    if range_ == location or location == nil then
        return range_
    end
    -- Don't overwrite the original node if `range` has an `original` node that points either directly or indirectly to `location`
    local original = self.e:Original(range_)
    while original ~= nil and original ~= location do
        original = self.e:Original(original)
    end
    if original == nil then
        self.e:SetOriginalEx(range_, location, true)
    end

    -- only set positions if range comes from the same file since copying text across files isn't supported by the emitter
    if self.ctx.enclosingFile ~= nil and self.ctx.enclosingFile == ast.GetSourceFileOfNode(self.e:MostOriginal(location)) then
        range_.loc = location.loc
        return range_
    else
        range_.loc = core.NewTextRange(-1, -1)
    end
    return range_
end

function NodeBuilderImpl:typeParameterShadowsOtherTypeParameterInScope(name, typeParameter)
    local result = self.ch.resolveName(self.ctx.enclosingDeclaration, name, SymbolFlags.Type, nil, false, false)
    if result ~= nil and result.flags & SymbolFlags.TypeParameter ~= 0 then
        return result ~= typeParameter.symbol
    end
    return false
end

function NodeBuilderImpl:typeParameterToName(typeParameter)
    if self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 then
        local cached, ok = self.ctx.typeParameterNames:Get(typeParameter.id)
        if ok then
            return cached
        end
    end
    local result = self:symbolToName(typeParameter.symbol, SymbolFlags.Type, --[[expectsIdentifier]] true)
    if not ast.IsIdentifier(result) then
        return self.f:NewIdentifier("(Missing type parameter)"):AsIdentifier()
    end
    if typeParameter.symbol ~= nil and core.Len(typeParameter.symbol.declarations) > 0 then
        local decl = typeParameter.symbol.declarations[1]
        if decl ~= nil and ast.IsTypeParameterDeclaration(decl) then
            result = self:setTextRange(result, decl:Name())
        end
    end
    if self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 then
        local rawText = result:Text()
        local i = self.ctx.typeParameterNamesByTextNextNameCount:Get(rawText) or 0
        local text = rawText

        while true do
            if not self.ctx.typeParameterNamesByText:Has(text) and not self:typeParameterShadowsOtherTypeParameterInScope(text, typeParameter) then
                break
            end
            i = i + 1
            text = rawText .. "_" .. tostring(i)
        end

        if text ~= rawText then
            -- !!! TODO: smuggle type arguments out
            -- const typeArguments = getIdentifierTypeArguments(result);
            result = self:newIdentifier(text, typeParameter.symbol)
            -- setIdentifierTypeArguments(result, typeArguments);
        end

        -- avoiding iterations of the above loop turns out to be worth it when `i` starts to get large, so we cache the max
        -- `i` we've used thus far, to save work later
        self.ctx.typeParameterNamesByTextNextNameCount:Set(rawText, i)
        self.ctx.typeParameterNames:Set(typeParameter.id, result:AsIdentifier())
        self.ctx.typeParameterNamesByText:Add(text)
    end

    return result:AsIdentifier()
end

function NodeBuilderImpl:isMappedTypeHomomorphic(mapped)
    return self.ch:getHomomorphicTypeVariable(mapped) ~= nil
end

function NodeBuilderImpl:isHomomorphicMappedTypeWithNonHomomorphicInstantiation(mapped)
    return mapped.target ~= nil and not self:isMappedTypeHomomorphic(mapped) and self:isMappedTypeHomomorphic(mapped.target)
end

function NodeBuilderImpl:createMappedTypeNodeFromType(t)
    debug.Assert(t:Flags() & TypeFlags.Object ~= 0)
    local mapped = t:AsMappedType()
    local readonlyToken
    if mapped.declaration.readonlyToken ~= nil then
        readonlyToken = self.f:NewToken(mapped.declaration.readonlyToken.kind)
    end
    local questionToken
    if mapped.declaration.questionToken ~= nil then
        questionToken = self.f:NewToken(mapped.declaration.questionToken.kind)
    end
    local appropriateConstraintTypeNode
    local newTypeVariable
    local templateType = self.ch:getTemplateTypeFromMappedType(t)
    local typeParameter = self.ch:getTypeParameterFromMappedType(t)

    -- If the mapped type isn't `keyof` constraint-declared, _but_ still has modifiers preserved, and its naive instantiation won't preserve modifiers because its constraint isn't `keyof` constrained, we have work to do
    local needsModifierPreservingWrapper = not self.ch:isMappedTypeWithKeyofConstraintDeclaration(t) and
        self.ch:getModifiersTypeFromMappedType(t).flags & TypeFlags.Unknown == 0 and
        self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 and
        not (self.ch:getConstraintTypeFromMappedType(t).flags & TypeFlags.TypeParameter ~= 0 and self.ch:getConstraintOfTypeParameter(self.ch:getConstraintTypeFromMappedType(t)).flags & TypeFlags.Index ~= 0)

    if self.ch:isMappedTypeWithKeyofConstraintDeclaration(t) then
        -- We have a { [P in keyof T]: X }
        -- We do this to ensure we retain the toplevel keyof-ness of the type which may be lost due to keyof distribution during `getConstraintTypeFromMappedType`
        if self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 and self:isHomomorphicMappedTypeWithNonHomomorphicInstantiation(mapped) then
            local newConstraintParam = self.ch:newTypeParameter(
                self.ch:newSymbol(SymbolFlags.TypeParameter, "T")
            )
            local name = self:typeParameterToName(newConstraintParam)
            local target = t:Target()
            newTypeVariable = self.f:NewTypeReferenceNode(name, nil)
            templateType = self.ch:instantiateType(self.ch:getTemplateTypeFromMappedType(target), checker.newTypeMapper({ self.ch:getTypeParameterFromMappedType(target), self.ch:getModifiersTypeFromMappedType(target) }, { typeParameter, newConstraintParam }))
        end
        local indexTarget = newTypeVariable
        if indexTarget == nil then
            indexTarget = self:typeToTypeNode(self.ch:getModifiersTypeFromMappedType(t))
        end
        appropriateConstraintTypeNode = self.f:NewTypeOperatorNode(Kind.KeyOfKeyword, indexTarget)
    elseif needsModifierPreservingWrapper then
        -- So, step 1: new type variable
        local newParam = self.ch:newTypeParameter(
            self.ch:newSymbol(SymbolFlags.TypeParameter, "T")
        )
        local name = self:typeParameterToName(newParam)
        newTypeVariable = self.f:NewTypeReferenceNode(name, nil)
        -- step 2: make that new type variable itself the constraint node, making the mapped type `{[K in T_1]: Template}`
        appropriateConstraintTypeNode = newTypeVariable
    else
        appropriateConstraintTypeNode = self:typeToTypeNode(self.ch:getConstraintTypeFromMappedType(t))
    end

    -- nameType and templateType nodes have to be in the new scope
    local cleanup = self:enterNewScope(mapped.declaration, nil, { self.ch:getTypeParameterFromMappedType(t) }, nil, nil)
    local typeParameterDeclarationNode = self:typeParameterToDeclarationWithConstraint(typeParameter, appropriateConstraintTypeNode)
    local nameTypeNode
    if mapped.declaration.nameType ~= nil then
        nameTypeNode = self:typeToTypeNode(self.ch:getNameTypeFromMappedType(t))
    end
    local templateTypeNode = self:typeToTypeNode(self.ch:removeMissingType(
        templateType,
        checker.getMappedTypeModifiers(t) & checker.MappedTypeModifiers.IncludeOptional ~= 0
    ))
    cleanup()
    local result = self.f:NewMappedTypeNode(
        readonlyToken,
        typeParameterDeclarationNode,
        nameTypeNode,
        questionToken,
        templateTypeNode,
        nil
    )
    self.ctx.approximateLength = self.ctx.approximateLength + 10
    self.e:AddEmitFlags(result, EmitFlags.EFSingleLine)

    if self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 and self:isHomomorphicMappedTypeWithNonHomomorphicInstantiation(mapped) then
        -- homomorphic mapped type with a non-homomorphic naive inlining
        -- wrap it with a conditional like `SomeModifiersType extends infer U ? {..the mapped type...} : never` to ensure the resulting
        -- type stays homomorphic

        local rawConstraintTypeFromDeclaration = self:getTypeFromTypeNode(mapped.declaration.typeParameter:AsTypeParameterDeclaration().constraint:Type(), false)
        if rawConstraintTypeFromDeclaration ~= nil then
            rawConstraintTypeFromDeclaration = self.ch:getConstraintOfTypeParameter(rawConstraintTypeFromDeclaration)
        end
        if rawConstraintTypeFromDeclaration == nil then
            rawConstraintTypeFromDeclaration = self.ch.unknownType
        end
        local originalConstraint = self.ch:instantiateType(rawConstraintTypeFromDeclaration, mapped.mapper)

        local originalConstraintNode
        if originalConstraint.flags & TypeFlags.Unknown == 0 then
            originalConstraintNode = self:typeToTypeNode(originalConstraint)
        end

        return self.f:NewConditionalTypeNode(
            self:typeToTypeNode(self.ch:getModifiersTypeFromMappedType(t)),
            self.f:NewInferTypeNode(self.f:NewTypeParameterDeclaration(nil, newTypeVariable:AsTypeReferenceNode().typeName:Clone(self.f), originalConstraintNode, nil, nil)),
            result,
            self.f:NewKeywordTypeNode(Kind.NeverKeyword)
        )
    elseif needsModifierPreservingWrapper then
        -- and step 3: once the mapped type is reconstructed, create a `ConstraintType extends infer T_1 extends keyof ModifiersType ? {[K in T_1]: Template} : never`
        -- subtly different from the `keyof` constraint case, by including the `keyof` constraint on the `infer` type parameter, it doesn't rely on the constraint type being itself
        -- constrained to a `keyof` type to preserve its modifier-preserving behavior. This is all basically because we preserve modifiers for a wider set of mapped types than
        -- just homomorphic ones.
        return self.f:NewConditionalTypeNode(
            self:typeToTypeNode(self.ch:getConstraintTypeFromMappedType(t)),
            self.f:NewInferTypeNode(self.f:NewTypeParameterDeclaration(nil, newTypeVariable:AsTypeReferenceNode().typeName:Clone(self.f), self.f:NewTypeOperatorNode(Kind.KeyOfKeyword, self:typeToTypeNode(self.ch:getModifiersTypeFromMappedType(t))), nil, nil)),
            result,
            self.f:NewKeywordTypeNode(Kind.NeverKeyword)
        )
    end

    return result
end

function NodeBuilderImpl:typePredicateToTypePredicateNode(predicate)
    local TypePredicateKind = checker.TypePredicateKind
    local assertsModifier
    if predicate.kind == TypePredicateKind.AssertsIdentifier or predicate.kind == TypePredicateKind.AssertsThis then
        assertsModifier = self.f:NewToken(Kind.AssertsKeyword)
    end
    local parameterName
    if predicate.kind == TypePredicateKind.Identifier or predicate.kind == TypePredicateKind.AssertsIdentifier then
        parameterName = self.f:NewIdentifier(predicate.parameterName)
        self.e:AddEmitFlags(parameterName, EmitFlags.EFNoAsciiEscaping)
    else
        parameterName = self.f:NewThisTypeNode()
    end
    local typeNode
    if predicate.t ~= nil then
        typeNode = self:typeToTypeNode(predicate.t)
    end
    return self.f:NewTypePredicateNode(
        assertsModifier,
        parameterName,
        typeNode
    )
end

function NodeBuilderImpl:typeToTypeNodeHelperWithPossibleReusableTypeNode(t, typeNode)
    if t == nil then
        return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
    end
    if not self:isActivelyExpanding() and typeNode ~= nil and self:getTypeFromTypeNode(typeNode, false) == t then
        local reused = self:tryReuseExistingNodeHelper(typeNode)
        if reused ~= nil then
            self:checkTypeExpandability(t)
            return reused
        end
    end
    return self:typeToTypeNode(t)
end

function NodeBuilderImpl:typeParameterToDeclaration(parameter)
    local constraint = self.ch:getConstraintOfTypeParameter(parameter)
    local constraintNode
    if constraint ~= nil then
        constraintNode = self:typeToTypeNodeHelperWithPossibleReusableTypeNode(constraint, self.ch:getConstraintDeclaration(parameter))
    end
    return self:typeParameterToDeclarationWithConstraint(parameter, constraintNode)
end

function NodeBuilderImpl:symbolToTypeParameterDeclarations(symbol)
    return self:typeParametersToTypeParameterDeclarations(symbol)
end

function NodeBuilderImpl:typeParametersToTypeParameterDeclarations(symbol)
    local targetSymbol = self.ch:getTargetSymbol(symbol)
    if targetSymbol.flags & (SymbolFlags.Class | SymbolFlags.Interface | SymbolFlags.Alias) ~= 0 then
        local results
        local params = self.ch:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
        for _, param in ipairs(params or {}) do
            results = core.Append(results, self:typeParameterToDeclaration(param))
        end
        return results
    elseif targetSymbol.flags & SymbolFlags.Function ~= 0 then
        local results
        for _, param in ipairs(self.ch:getTypeParametersFromDeclaration(symbol.valueDeclaration) or {}) do
            results = core.Append(results, self:typeParameterToDeclaration(param))
        end
        return results
    end
    return nil
end

function checker.getEffectiveParameterDeclaration(symbol)
    local parameterDeclaration = ast.GetDeclarationOfKind(symbol, Kind.Parameter)
    if parameterDeclaration ~= nil then
        return parameterDeclaration
    end
    if symbol.flags & SymbolFlags.Transient == 0 then
        return ast.GetDeclarationOfKind(symbol, Kind.JSDocParameterTag)
    end
    return nil
end

function NodeBuilderImpl:symbolToParameterDeclaration(parameterSymbol, preserveModifierFlags)
    local parameterDeclaration = checker.getEffectiveParameterDeclaration(parameterSymbol)

    local parameterType = self.ch:getTypeOfSymbol(parameterSymbol)
    local parameterTypeNode = self:serializeTypeForDeclaration(parameterDeclaration, parameterType, parameterSymbol, true)
    local modifiers
    if self.ctx.flags & Flags.OmitParameterModifiers == 0 and preserveModifierFlags and parameterDeclaration ~= nil and ast.CanHaveModifiers(parameterDeclaration) then
        local originals = core.Filter(parameterDeclaration:ModifierNodes(), ast.IsModifier)
        local clones = core.Map(originals, function(node) return node:Clone(self.f) end)
        if core.Len(clones) > 0 then
            modifiers = self.f:NewModifierList(clones)
        end
    end
    local isRest = parameterDeclaration ~= nil and checker.isRestParameter(parameterDeclaration) or parameterSymbol.checkFlags & CheckFlags.RestParameter ~= 0
    local dotDotDotToken
    if isRest then
        dotDotDotToken = self.f:NewToken(Kind.DotDotDotToken)
    end
    local name = self:parameterToParameterDeclarationName(parameterSymbol, parameterDeclaration)
    local isOptional = parameterDeclaration ~= nil and self.ch:isOptionalParameter(parameterDeclaration) or parameterSymbol.checkFlags & CheckFlags.OptionalParameter ~= 0
    local questionToken
    if isOptional then
        questionToken = self.f:NewToken(Kind.QuestionToken)
    end

    local parameterNode = self.f:NewParameterDeclaration(
        modifiers,
        dotDotDotToken,
        name,
        questionToken,
        parameterTypeNode,
        --[[initializer]] nil
    )
    self.ctx.approximateLength = self.ctx.approximateLength + #parameterSymbol.name + 3
    return parameterNode
end

function NodeBuilderImpl:parameterToParameterDeclarationName(parameterSymbol, parameterDeclaration)
    if parameterDeclaration == nil or parameterDeclaration:Name() == nil then
        return self:newIdentifier(parameterSymbol.name, parameterSymbol)
    end

    local name = parameterDeclaration:Name()
    if name.kind == Kind.Identifier then
        local cloned = self.f:DeepCloneNode(name)
        self.e:SetEmitFlags(cloned, EmitFlags.EFNoAsciiEscaping)
        self.idToSymbol[cloned] = parameterSymbol
        return cloned
    elseif name.kind == Kind.QualifiedName then
        local cloned = self.f:DeepCloneNode(name:AsQualifiedName().right)
        self.e:SetEmitFlags(cloned, EmitFlags.EFNoAsciiEscaping)
        self.idToSymbol[cloned] = parameterSymbol
        return cloned
    else
        return self:cloneBindingName(name)
    end
end

function NodeBuilderImpl:cloneBindingName(node)
    if ast.IsComputedPropertyName(node) and self.ch:isLateBindableName(node) then
        self:trackComputedName(node:Expression(), self.ctx.enclosingDeclaration)
    end

    local visited = self.cloneBindingNameVisitor:VisitEachChild(node)

    if ast.IsBindingElement(visited) then
        local bindingElement = visited:AsBindingElement()
        visited = self.f:UpdateBindingElement(
            bindingElement,
            bindingElement.dotDotDotToken,
            bindingElement.propertyName,
            bindingElement:Name(),
            nil -- remove initializer
        )
    end

    if not ast.NodeIsSynthesized(visited) then
        visited = self.f:DeepCloneNode(visited)
    end

    self.e:SetEmitFlags(visited, EmitFlags.EFSingleLine | EmitFlags.EFNoAsciiEscaping)
    return visited
end

function NodeBuilderImpl:serializeTypeForExpression(expr)
    -- !!! TODO: shim, add node reuse
    local t = self.ch:instantiateType(self.ch:getWidenedType(self.ch:getRegularTypeOfExpression(expr)), self.ctx.mapper)
    return self:typeToTypeNode(t)
end

function NodeBuilderImpl:serializeInferredReturnTypeForSignature(signature, returnType)
    local oldSuppressReportInferenceFallback = self.ctx.suppressReportInferenceFallback
    self.ctx.suppressReportInferenceFallback = true
    local typePredicate = self.ch:getTypePredicateOfSignature(signature)
    local returnTypeNode
    if typePredicate ~= nil then
        local predicate
        if self.ctx.mapper ~= nil then
            predicate = self.ch:instantiateTypePredicate(typePredicate, self.ctx.mapper)
        else
            predicate = typePredicate
        end
        returnTypeNode = self:typePredicateToTypePredicateNodeHelper(predicate)
    else
        returnTypeNode = self:typeToTypeNode(returnType)
    end
    self.ctx.suppressReportInferenceFallback = oldSuppressReportInferenceFallback
    return returnTypeNode
end

function NodeBuilderImpl:typePredicateToTypePredicateNodeHelper(typePredicate)
    local TypePredicateKind = checker.TypePredicateKind
    local assertsModifier
    if typePredicate.kind == TypePredicateKind.AssertsThis or typePredicate.kind == TypePredicateKind.AssertsIdentifier then
        assertsModifier = self.f:NewToken(Kind.AssertsKeyword)
    else
        assertsModifier = nil
    end
    local parameterName
    if typePredicate.kind == TypePredicateKind.Identifier or typePredicate.kind == TypePredicateKind.AssertsIdentifier then
        parameterName = self:newIdentifier(typePredicate.parameterName, nil --[[symbol]])
        self.e:SetEmitFlags(parameterName, EmitFlags.EFNoAsciiEscaping)
    else
        parameterName = self.f:NewThisTypeNode()
    end
    local typeNode
    if typePredicate.t ~= nil then
        typeNode = self:typeToTypeNode(typePredicate.t)
    end
    return self.f:NewTypePredicateNode(assertsModifier, parameterName, typeNode)
end

-- SignatureToSignatureDeclarationOptions: { modifiers, name, questionToken }
checker.defineStruct("SignatureToSignatureDeclarationOptions", nil, nil)

function NodeBuilderImpl:signatureToSignatureDeclarationHelper(signature, kind, options)
    local typeParameters

    local expandedParams, cleanup = self:enterSignatureScope(signature)
    self.ctx.approximateLength = self.ctx.approximateLength + 3
    -- Usually a signature contributes a few more characters than this, but 3 is the minimum

    if self.ctx.flags & Flags.WriteTypeArgumentsOfSignature ~= 0 and signature.target ~= nil and signature.mapper ~= nil and core.Len(signature.target.typeParameters) ~= 0 then
        for _, parameter in ipairs(signature.target.typeParameters) do
            typeParameters = core.Append(typeParameters, self:typeToTypeNode(self.ch:instantiateType(parameter, signature.mapper)))
        end
    else
        for _, parameter in ipairs(signature.typeParameters or {}) do
            typeParameters = core.Append(typeParameters, self:typeParameterToDeclaration(parameter))
        end
    end

    local restoreFlags = self:saveRestoreFlags()
    self.ctx.flags = self.ctx.flags & ~Flags.SuppressAnyReturnType
    -- If the expanded parameter list had a variadic in a non-trailing position, don't expand it
    local parameters = core.Map(core.IfElse(core.Some(expandedParams, function(p)
        return p ~= expandedParams[#expandedParams] and p.checkFlags & CheckFlags.RestParameter ~= 0
    end), signature.parameters, expandedParams), function(parameter)
        return self:symbolToParameterDeclaration(parameter, kind == Kind.Constructor)
    end)
    if parameters == nil then
        parameters = {}
    end
    local thisParameter
    if self.ctx.flags & Flags.OmitThisParameter ~= 0 then
        thisParameter = nil
    else
        thisParameter = self:tryGetThisParameterDeclaration(signature)
    end
    if thisParameter ~= nil then
        table.insert(parameters, 1, thisParameter)
    end
    restoreFlags()

    local returnTypeNode = self:serializeReturnTypeForSignature(signature, true)

    local modifiers
    if options ~= nil then
        modifiers = options.modifiers
    end
    if (kind == Kind.ConstructorType) and signature.flags & SignatureFlags.Abstract ~= 0 then
        local flags = ast.ModifiersToFlags(modifiers)
        modifiers = ast.CreateModifiersFromModifierFlags(flags | ModifierFlags.Abstract, function(k) return self.f:NewModifier(k) end)
    end

    local paramList = self.f:NewNodeList(parameters)
    local typeParamList
    if core.Len(typeParameters) ~= 0 then
        typeParamList = self.f:NewNodeList(typeParameters)
    end
    local modifierList
    if core.Len(modifiers) > 0 then
        modifierList = self.f:NewModifierList(modifiers)
    end
    local name
    if options ~= nil then
        name = options.name
    end
    if name == nil then
        name = self.f:NewIdentifier("")
    end

    local node
    if kind == Kind.CallSignature then
        node = self.f:NewCallSignatureDeclaration(typeParamList, paramList, returnTypeNode)
    elseif kind == Kind.ConstructSignature then
        node = self.f:NewConstructSignatureDeclaration(typeParamList, paramList, returnTypeNode)
    elseif kind == Kind.MethodSignature then
        local questionToken
        if options ~= nil then
            questionToken = options.questionToken
        end
        node = self.f:NewMethodSignatureDeclaration(modifierList, name, questionToken, typeParamList, paramList, returnTypeNode)
    elseif kind == Kind.MethodDeclaration then
        node = self.f:NewMethodDeclaration(modifierList, nil --[[asteriskToken]], name, nil --[[questionToken]], typeParamList, paramList, returnTypeNode, nil --[[fullSignature]], nil --[[body]])
    elseif kind == Kind.Constructor then
        node = self.f:NewConstructorDeclaration(modifierList, nil --[[typeParamList]], paramList, nil --[[returnTypeNode]], nil --[[fullSignature]], nil --[[body]])
    elseif kind == Kind.GetAccessor then
        node = self.f:NewGetAccessorDeclaration(modifierList, name, nil --[[typeParamList]], paramList, returnTypeNode, nil --[[fullSignature]], nil --[[body]])
    elseif kind == Kind.SetAccessor then
        node = self.f:NewSetAccessorDeclaration(modifierList, name, nil --[[typeParamList]], paramList, nil --[[returnTypeNode]], nil --[[fullSignature]], nil --[[body]])
    elseif kind == Kind.IndexSignature then
        node = self.f:NewIndexSignatureDeclaration(modifierList, paramList, returnTypeNode)
        -- !!! JSDoc Support
        -- case kind == ast.KindJSDocFunctionType:
        -- 	node = b.f.NewJSDocFunctionType(parameters, returnTypeNode)
    elseif kind == Kind.FunctionType then
        if returnTypeNode == nil then
            returnTypeNode = self.f:NewTypeReferenceNode(self.f:NewIdentifier(""), nil)
        end
        node = self.f:NewFunctionTypeNode(typeParamList, paramList, returnTypeNode)
    elseif kind == Kind.ConstructorType then
        if returnTypeNode == nil then
            returnTypeNode = self.f:NewTypeReferenceNode(self.f:NewIdentifier(""), nil)
        end
        node = self.f:NewConstructorTypeNode(modifierList, typeParamList, paramList, returnTypeNode)
    elseif kind == Kind.FunctionDeclaration then
        -- TODO: assert name is Identifier
        node = self.f:NewFunctionDeclaration(modifierList, nil --[[asteriskToken]], name, typeParamList, paramList, returnTypeNode, nil --[[fullSignature]], nil --[[body]])
    elseif kind == Kind.FunctionExpression then
        -- TODO: assert name is Identifier
        node = self.f:NewFunctionExpression(modifierList, nil --[[asteriskToken]], name, typeParamList, paramList, returnTypeNode, nil --[[fullSignature]], self.f:NewBlock(self.f:NewNodeList({}), false))
    elseif kind == Kind.ArrowFunction then
        node = self.f:NewArrowFunction(modifierList, typeParamList, paramList, returnTypeNode, nil --[[fullSignature]], nil --[[equalsGreaterThanToken]], self.f:NewBlock(self.f:NewNodeList({}), false))
    else
        error("Unhandled kind in signatureToSignatureDeclarationHelper", 0)
    end

    -- !!! TODO: Smuggle type arguments of signatures out for quickinfo
    -- if typeArguments != nil {
    -- 	node.TypeArguments = b.f.NewNodeList(typeArguments)
    -- }

    cleanup()
    return node
end

function Checker:getExpandedParameters(sig, skipUnionExpanding)
    local c = self
    if checker.signatureHasRestParameter(sig) then
        local restIndex = #sig.parameters - 1
        local restSymbol = sig.parameters[restIndex + 1]
        local restType = c:getTypeOfSymbol(restSymbol)
        local getUniqAssociatedNamesFromTupleType = function(t, restSym)
            local names = core.MapIndex(t:Target():AsTupleType().elementInfos, function(info, i)
                return c:getTupleElementLabel(info, restSym, i)
            end)
            if core.Len(names) > 0 then
                local duplicates = {}
                local uniqueNames = {}
                for i1, name in ipairs(names) do
                    if uniqueNames[name] ~= nil then
                        duplicates[#duplicates + 1] = i1 - 1
                    else
                        uniqueNames[name] = true
                    end
                end
                local counters = {}
                for _, i in ipairs(duplicates) do
                    local counter = counters[names[i + 1]]
                    if counter == nil then
                        counter = 1
                    end
                    local name
                    while true do
                        name = names[i + 1] .. "_" .. tostring(counter)
                        if uniqueNames[name] ~= nil then
                            counter = counter + 1
                        else
                            uniqueNames[name] = true
                            break
                        end
                    end
                    names[i + 1] = name
                    counters[names[i + 1]] = counter + 1
                end
            end
            return names
        end
        local expandSignatureParametersWithTupleMembers = function(rt, ri, restSym)
            local elementTypes = c:getTypeArguments(rt)
            local associatedNames = getUniqAssociatedNamesFromTupleType(rt, restSym)
            local restParams = core.MapIndex(elementTypes, function(t, i)
                -- Lookup the label from the individual tuple passed in before falling back to the signature `rest` parameter name
                -- TODO: getTupleElementLabel can no longer fail, investigate if this lack of falliability meaningfully changes output
                -- var name *string
                -- if associatedNames != nil && associatedNames[i] != nil {
                -- 	name = associatedNames[i]
                -- } else {
                -- 	name = c.getParameterNameAtPosition(sig, restIndex+i, restType)
                -- }
                local name = associatedNames[i + 1]
                local flags = rt:Target():AsTupleType().elementInfos[i + 1].flags
                local checkFlags = 0
                if flags & ElementFlags.Variable ~= 0 then
                    checkFlags = CheckFlags.RestParameter
                elseif flags & ElementFlags.Optional ~= 0 then
                    checkFlags = CheckFlags.OptionalParameter
                end
                local symbol = c:newSymbolEx(SymbolFlags.FunctionScopedVariable, name, checkFlags)
                local links = c.valueSymbolLinks:Get(symbol)
                if flags & ElementFlags.Rest ~= 0 then
                    links.resolvedType = c:createArrayType(t)
                else
                    links.resolvedType = t
                end
                return symbol
            end)
            return core.Concatenate(core.Slice(sig.parameters, 0, ri), restParams)
        end

        if checker.isTupleType(restType) then
            return { expandSignatureParametersWithTupleMembers(restType, restIndex, restSymbol) }
        elseif not skipUnionExpanding and restType.flags & TypeFlags.Union ~= 0 and core.Every(restType:AsUnionType().types, checker.isTupleType) then
            return core.Map(restType:AsUnionType().types, function(t)
                return expandSignatureParametersWithTupleMembers(t, restIndex, restSymbol)
            end)
        end
    end
    return { sig.parameters }
end

function NodeBuilderImpl:tryGetThisParameterDeclaration(signature)
    if signature.thisParameter ~= nil then
        return self:symbolToParameterDeclaration(signature.thisParameter, false)
    end
    if signature.declaration ~= nil and ast.IsInJSFile(signature.declaration) then
        -- !!! JSDoc Support
        -- thisTag := getJSDocThisTag(signature.declaration)
        -- if (thisTag && thisTag.typeExpression) {
        -- 	return factory.createParameterDeclaration(
        -- 		/*modifiers*/ undefined,
        -- 		/*dotDotDotToken*/ undefined,
        -- 		"this",
        -- 		/*questionToken*/ undefined,
        -- 		typeToTypeNodeHelper(getTypeFromTypeNode(context, thisTag.typeExpression), context),
        -- 	);
        -- }
    end
    return nil
end

--[[
* Serializes the return type of the signature by first trying to use the syntactic printer if possible and falling back to the checker type if not.
]]
function NodeBuilderImpl:serializeReturnTypeForSignature(signature, tryReuse)
    local suppressAny = self.ctx.flags & Flags.SuppressAnyReturnType ~= 0
    local restoreFlags = self:saveRestoreFlags()
    if suppressAny then
        self.ctx.flags = self.ctx.flags & ~Flags.SuppressAnyReturnType -- suppress only toplevel `any`s
    end
    local returnTypeNode

    local returnType
    if signature.declaration ~= nil and not ast.NodeIsSynthesized(signature.declaration) then
        local symbol = self.ch:getSymbolOfDeclaration(signature.declaration)
        returnType = self.ctx.enclosingSymbolTypes[ast.GetSymbolId(symbol)]
        if returnType == nil then
            returnType = self.ch:instantiateType(self.ch:getReturnTypeOfSignature(signature), self.ctx.mapper)
        end
    else
        returnType = self.ch:getReturnTypeOfSignature(signature)
    end
    if not (suppressAny and checker.IsTypeAny(returnType)) then
        if not self:isActivelyExpanding() and tryReuse and self.ctx.enclosingDeclaration ~= nil and signature.declaration ~= nil and not ast.NodeIsSynthesized(signature.declaration) then
            local declarationSymbol = self.ch:getSymbolOfDeclaration(signature.declaration)
            local restore = self:addSymbolTypeToContext(declarationSymbol, returnType)
            local pt = self.pc:GetReturnTypeOfSignature(signature.declaration)
            if self:pseudoTypeEquivalentToType(pt, returnType, false, not self.ctx.suppressReportInferenceFallback) then
                -- Also verify the pseudo type captures any inferred type predicate, not just the boolean return type.
                -- The pseudochecker is unaware of inferred type predicates, so it produces boolean where
                -- the checker infers e.g. `x is string`.
                local typePredicate = self.ch:getTypePredicateOfSignature(signature)
                if typePredicate ~= nil and not self:pseudoReturnTypeMatchesPredicate(pt, typePredicate) then
                    if not self.ctx.suppressReportInferenceFallback then
                        self.ctx.tracker:ReportInferenceFallback(signature.declaration)
                    end
                    pt = nil
                end
                if pt ~= nil then
                    -- !!! TODO: If annotated type node is a reference with insufficient type arguments, we should still fall back to type serialization
                    -- see: canReuseTypeNodeAnnotation in strada for context
                    returnTypeNode = self:pseudoTypeToNodeWithCheckerFallback(pt, returnType)
                end
            end
            restore()
        end
        if returnTypeNode == nil then
            returnTypeNode = self:serializeInferredReturnTypeForSignature(signature, returnType)
        end
    end

    if returnTypeNode == nil and not suppressAny then
        returnTypeNode = self.f:NewKeywordTypeNode(Kind.AnyKeyword)
    end
    restoreFlags()
    return returnTypeNode
end

function NodeBuilderImpl:isTriviallySerializableComputedName(e)
    local shapeGood = e ~= nil and e:Name() ~= nil and ast.IsComputedPropertyName(e:Name()) and ast.IsEntityNameExpression(e:Name():Expression())
    if not shapeGood then
        return false
    end
    -- TODO: going through emit resolver here is weird. Relayer these APIs.
    return self.ch:GetEmitResolver():isEntityNameVisible(e:Name():Expression(), self.ctx.enclosingDeclaration, false).accessibility == printer.SymbolAccessibility.Accessible
end

function NodeBuilderImpl:indexInfoToObjectComputedNamesOrSignatureDeclaration(indexInfo, typeNode)
    if core.Len(indexInfo.components) > 0 then
        -- Index info is derived from object or class computed property names (plus explicit named members) - we can clone those instead of writing out the result computed index signature
        local allComponentComputedNamesSerializable = self.ctx.enclosingDeclaration ~= nil and core.Every(indexInfo.components, function(c) return self:isTriviallySerializableComputedName(c) end)
        if allComponentComputedNamesSerializable then
            -- Only use computed name serialization form if all components are visible and take the `a.b.c` form
            local newComponents = core.Filter(indexInfo.components, function(c)
                -- skip late bound props that contribute to the index signature - they'll be created by property creation anyway
                return not self.ch:hasLateBindableName(c)
            end)
            local bailed = false
            local results = {}
            for _, e in ipairs(newComponents or {}) do
                local name = self:reuseNode(e:Name())
                if name ~= nil then
                    -- Still need to track visibility even if we've already checked it to paint references as used
                    self:trackComputedName(e:Name():Expression(), self.ctx.enclosingDeclaration)
                    local mods
                    if indexInfo.isReadonly then
                        mods = self.f:NewModifierList({ self.f:NewModifier(Kind.ReadonlyKeyword) })
                    end
                    local postfixToken
                    if e:PostfixToken() ~= nil then
                        postfixToken = e:PostfixToken():Clone(self.f)
                    end
                    local currentTypeNode
                    if typeNode ~= nil then
                        currentTypeNode = self.f:DeepCloneNode(typeNode)
                    else
                        currentTypeNode = self:typeToTypeNode(self.ch:getTypeOfSymbol(e:Symbol()))
                    end
                    local sig = self.f:NewPropertySignatureDeclaration(
                        mods,
                        name,
                        postfixToken,
                        currentTypeNode,
                        nil
                    )
                    sig.loc = e.loc
                    results[#results + 1] = sig
                else
                    -- Go's core.Map keeps mapping after a bail; the results are discarded either way.
                    bailed = true
                end
            end
            if not bailed then
                return results
            end
        end
    end
    return { self:indexInfoToIndexSignatureDeclarationHelper(indexInfo, typeNode) }
end

function NodeBuilderImpl:indexInfoToIndexSignatureDeclarationHelper(indexInfo, typeNode)
    local name = checker.getNameFromIndexInfo(indexInfo)
    local indexerTypeNode = self:typeToTypeNode(indexInfo.keyType)

    local indexingParameter = self.f:NewParameterDeclaration(nil, nil, self:newIdentifier(name, nil --[[symbol]]), nil, indexerTypeNode, nil)
    if typeNode == nil then
        if indexInfo.valueType == nil then
            typeNode = self.f:NewKeywordTypeNode(Kind.AnyKeyword)
        else
            typeNode = self:typeToTypeNode(indexInfo.valueType)
        end
    end
    if indexInfo.valueType == nil and self.ctx.flags & Flags.AllowEmptyIndexInfoType == 0 then
        self.ctx.encounteredError = true
    end
    self.ctx.approximateLength = self.ctx.approximateLength + #name + 4
    local modifiers
    if indexInfo.isReadonly then
        self.ctx.approximateLength = self.ctx.approximateLength + 9
        modifiers = self.f:NewModifierList({ self.f:NewModifier(Kind.ReadonlyKeyword) })
    end
    return self.f:NewIndexSignatureDeclaration(modifiers, self.f:NewNodeList({ indexingParameter }), typeNode)
end

function checker.hasTypeAnnotation(declaration)
    if declaration == nil or declaration:Type() == nil then
        return false
    end
    -- Type alias declarations have a .Type() that is their type definition, not a type annotation on a value.
    -- Exclude them so callers don't mistake them for annotated value declarations.
    if ast.IsTypeAliasDeclaration(declaration) or ast.IsJSTypeAliasDeclaration(declaration) then
        return false
    end
    return true
end

--[[
* Unlike `typeToTypeNodeHelper`, this handles setting up the `AllowUniqueESSymbolType` flag
* so a `unique symbol` is returned when appropriate for the input symbol, rather than `typeof sym`
* @param declaration - The preferred declaration to pull existing type nodes from (the symbol will be used as a fallback to find any annotated declaration)
* @param type - The type to write; an existing annotation must match this type if it's used, otherwise this is the type serialized as a new type node
* @param symbol - The symbol is used both to find an existing annotation if declaration is not provided, and to determine if `unique symbol` should be printed
]]
function NodeBuilderImpl:serializeTypeForDeclaration(declaration, t, symbol, tryReuse)
    if declaration == nil then
        if symbol ~= nil then
            declaration = symbol.valueDeclaration
            if declaration == nil then
                -- TODO: prefer annotated declarations like in strada (but does this ever even matter in practice? All callers should supply a declaration!)
                declaration = core.FirstOrNil(symbol.declarations)
            end
        end
    end
    if symbol == nil then
        symbol = self.ch:getSymbolOfDeclaration(declaration)
    end
    if t == nil then
        if symbol == nil then
            if ast.IsVariableLike(declaration) then
                t = self.ch:getTypeForVariableLikeDeclaration(declaration, false, checker.CheckMode.Normal)
            else
                t = self.ch.errorType
            end
        else
            t = self.ctx.enclosingSymbolTypes[ast.GetSymbolId(symbol)]
            if t == nil then
                if symbol.flags & SymbolFlags.Accessor ~= 0 and declaration.kind == Kind.SetAccessor then
                    t = self.ch:instantiateType(self.ch:getWriteTypeOfSymbol(symbol), self.ctx.mapper)
                elseif symbol ~= nil and (symbol.flags & (SymbolFlags.TypeLiteral | SymbolFlags.Signature) == 0) then
                    t = self.ch:instantiateType(self.ch:getWidenedLiteralType(self.ch:getTypeOfSymbol(symbol)), self.ctx.mapper)
                else
                    t = self.ch.errorType
                end
            end
        end
    end

    -- !!! TODO: JSDoc, getEmitResolver call is unfortunate layering for the helper - hoist it into checker
    local requiresAddingUndefined = declaration ~= nil and (ast.IsParameterDeclaration(declaration) or ast.IsPropertySignatureDeclaration(declaration) or ast.IsPropertyDeclaration(declaration)) and self.ch:GetEmitResolver():requiresAddingImplicitUndefined(declaration, symbol, self.ctx.enclosingDeclaration)
    local addUndefinedForParameter = requiresAddingUndefined and (ast.IsParameterDeclaration(declaration) --[[|| ast.IsJSDocParameterTag(declaration)]])
    if addUndefinedForParameter then
        t = self.ch:getOptionalType(t, false)
    end

    local restoreFlags = self:saveRestoreFlags()
    if t.flags & TypeFlags.UniqueESSymbol ~= 0 and t.symbol == symbol and (self.ctx.enclosingDeclaration == nil or core.Some(symbol.declarations, function(d)
        return ast.GetSourceFileOfNode(d) == self.ctx.enclosingFile
    end)) then
        self.ctx.flags = self.ctx.flags | Flags.AllowUniqueESSymbolType
    end
    local result
    local reportedInferenceFallback = false
    -- !!! expandable hover support
    if not self:isActivelyExpanding() and tryReuse and self.ctx.enclosingDeclaration ~= nil and declaration ~= nil and (ast.IsAccessor(declaration) or (ast.HasInferredType(declaration) and not ast.NodeIsSynthesized(declaration) and (t:ObjectFlags() & ObjectFlags.RequiresWidening) == 0)) then
        local remove
        if symbol ~= nil then
            remove = self:addSymbolTypeToContext(symbol, t)
        end
        local pt
        if ast.IsAccessor(declaration) then
            pt = self.pc:GetTypeOfAccessor(declaration)
        else
            pt = self.pc:GetTypeOfDeclaration(declaration)
        end
        if (pt == nil or pt.kind == pseudochecker.PseudoTypeKind.NoResult) and ast.IsBinaryExpression(declaration) and symbol ~= nil then
            local decl = core.Find(symbol.declarations, checker.hasTypeAnnotation)
            if decl ~= nil then
                -- Binary expressions have a first-in-wins type annotation system. The first one with an annotation supplies the type for the rest.
                pt = self.pc:GetTypeOfDeclaration(decl)
            end
        end
        local reportErrors = not self.ctx.suppressReportInferenceFallback
        if self:pseudoTypeEquivalentToType(pt, t, not requiresAddingUndefined and (ast.IsParameterDeclaration(declaration) or ast.IsPropertySignatureDeclaration(declaration) or ast.IsPropertyDeclaration(declaration)) and checker.isOptionalDeclaration(declaration), reportErrors) then
            -- !!! TODO: If annotated type node is a reference with insufficient type arguments, we should still fall back to type serialization
            -- see: canReuseTypeNodeAnnotation in strada for context
            local ptt = self:pseudoTypeToType(pt)
            if ptt ~= nil and requiresAddingUndefined and checker.containsNonMissingUndefinedType(self.ch, t) and not checker.containsNonMissingUndefinedType(self.ch, ptt) then
                pt = pseudochecker.NewPseudoTypeUnion({ pt, pseudochecker.PseudoTypeUndefined })
            end
            result = self:pseudoTypeToNodeWithCheckerFallback(pt, t)
        else
            -- Equivalence failed; if errors from inferred-with-errors pseudo types were
            -- reported, note it so we can suppress nested errors during the fallback
            -- typeToTypeNode serialization (mirroring the suppression that
            -- pseudoTypeToNodeWithCheckerFallback provides).
            reportedInferenceFallback = reportErrors and pt.kind == pseudochecker.PseudoTypeKind.Inferred and core.Len(pt:AsPseudoTypeInferred().errorNodes) > 0
            local shouldAddUndefined = false
            if requiresAddingUndefined then
                local ptt = self:pseudoTypeToType(pt)
                if ptt ~= nil then
                    shouldAddUndefined = not checker.containsNonMissingUndefinedType(self.ch, ptt)
                else
                    shouldAddUndefined = not pseudochecker.CouldAlreadyReferToUndefinedType(pt)
                end
            end
            if shouldAddUndefined then
                pt = pseudochecker.NewPseudoTypeUnion({ pt, pseudochecker.PseudoTypeUndefined })
                if self:pseudoTypeEquivalentToType(pt, t, false, reportErrors) then
                    result = self:pseudoTypeToNodeWithCheckerFallback(pt, t)
                    reportedInferenceFallback = false
                end
            end
        end
        if remove ~= nil then
            remove()
        end
    end
    if result == nil then
        if reportedInferenceFallback then
            local oldSuppress = self.ctx.suppressReportInferenceFallback
            self.ctx.suppressReportInferenceFallback = true
            result = self:typeToTypeNode(t)
            self.ctx.suppressReportInferenceFallback = oldSuppress
        else
            result = self:typeToTypeNode(t)
        end
    end
    restoreFlags()
    if result == nil then
        return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
    end
    return result
end

function NodeBuilderImpl:shouldUsePlaceholderForProperty(propertySymbol)
    -- Use placeholders for reverse mapped types we've either
    -- (1) already descended into, or
    -- (2) are nested reverse mappings within a mapping over a non-anonymous type, or
    -- (3) are deeply nested properties that originate from the same mapped type.
    -- Condition (2) is a restriction mostly just to
    -- reduce the blowup in printback size from doing, eg, a deep reverse mapping over `Window`.
    -- Since anonymous types usually come from expressions, this allows us to preserve the output
    -- for deep mappings which likely come from expressions, while truncating those parts which
    -- come from mappings over library functions.
    -- Condition (3) limits printing of possibly infinitely deep reverse mapped types.
    if propertySymbol.checkFlags & CheckFlags.ReverseMapped == 0 then
        return false
    end
    local stack = self.ctx.reverseMappedStack or {}
    -- (1)
    for _, s in ipairs(stack) do
        if s == propertySymbol then
            return true
        end
    end
    -- (2)
    if #stack > 0 then
        local last = stack[#stack]
        if self.ch.reverseMappedSymbolLinks:Has(last) then
            local links = self.ch.reverseMappedSymbolLinks:TryGet(last)
            local propertyType = links.propertyType
            if propertyType ~= nil and propertyType.objectFlags & ObjectFlags.Anonymous == 0 then
                return true
            end
        end
    end
    -- (3) - we only inspect the last MAX_REVERSE_MAPPED_NESTING_INSPECTION_DEPTH elements of the
    -- stack for approximate matches to catch tight infinite loops
    -- TODO: Why? Reasoning lost to time. this could probably stand to be improved?
    if #stack < checker.MAX_REVERSE_MAPPED_NESTING_INSPECTION_DEPTH then
        return false
    end
    if not self.ch.reverseMappedSymbolLinks:Has(propertySymbol) then
        return false
    end
    local propertyLinks = self.ch.reverseMappedSymbolLinks:TryGet(propertySymbol)
    local propMappedType = propertyLinks.mappedType
    if propMappedType == nil or propMappedType.symbol == nil then
        return false
    end
    for i = 0, #stack - 1 do
        if i > checker.MAX_REVERSE_MAPPED_NESTING_INSPECTION_DEPTH then
            break
        end
        local prop = stack[#stack - i]
        if self.ch.reverseMappedSymbolLinks:Has(prop) then
            local links = self.ch.reverseMappedSymbolLinks:TryGet(prop)
            local mappedType = links.mappedType
            if mappedType ~= nil and mappedType.symbol == propMappedType.symbol then
                return true
            end
        end
    end
    return false
end

function NodeBuilderImpl:trackComputedName(accessExpression, enclosingDeclaration)
    -- get symbol of the first identifier of the entityName
    local firstIdentifier = ast.GetFirstIdentifier(accessExpression)
    local name = self.ch.resolveName(enclosingDeclaration, firstIdentifier:Text(), SymbolFlags.Value | SymbolFlags.ExportValue, nil --[[nameNotFoundMessage]], true --[[isUse]], false)
    if name ~= nil then
        self.ctx.tracker:TrackSymbol(name, enclosingDeclaration, SymbolFlags.Value)
    else
        -- Name does not resolve at target location, track symbol at dest location (should be inaccessible)
        local fallback = self.ch.resolveName(firstIdentifier, firstIdentifier:Text(), SymbolFlags.Value | SymbolFlags.ExportValue, nil --[[nameNotFoundMessage]], true --[[isUse]], false)
        if fallback ~= nil then
            self.ctx.tracker:TrackSymbol(fallback, enclosingDeclaration, SymbolFlags.Value)
        end
    end
end

-- propertyNameNodeKind (unexported Go iota constants)
checker.propertyNameNodeKindIdentifier = 0
checker.propertyNameNodeKindNumericLiteral = 1
checker.propertyNameNodeKindStringLiteral = 2

function checker.classifyPropertyName(name, stringNamed, isMethod)
    if isMethod and name == "new" then
        return checker.propertyNameNodeKindStringLiteral
    end
    if scanner.IsIdentifierText(name, core.LanguageVariant.Standard) then
        return checker.propertyNameNodeKindIdentifier
    end
    return core.IfElse(not stringNamed and checker.isNumericLiteralName(name) and jsnum.FromString(name) >= 0, checker.propertyNameNodeKindNumericLiteral, checker.propertyNameNodeKindStringLiteral)
end

function NodeBuilderImpl:createPropertyNameNodeForIdentifierOrLiteral(name, singleQuote, stringNamed, isMethod, symbol)
    local k = checker.classifyPropertyName(name, stringNamed, isMethod)
    if k == checker.propertyNameNodeKindIdentifier then
        return self:newIdentifier(name, symbol)
    elseif k == checker.propertyNameNodeKindNumericLiteral then
        return self.f:NewNumericLiteral(name, ast.TokenFlags.None)
    else
        return self.f:NewStringLiteral(name, core.IfElse(singleQuote, ast.TokenFlags.SingleQuote, ast.TokenFlags.None))
    end
end

function NodeBuilderImpl:isStringNamed(d)
    local name = ast.GetNameOfDeclaration(d)
    if name == nil then
        return false
    end
    if ast.IsComputedPropertyName(name) then
        local t = self.ch:checkExpression(name:Expression())
        return t.flags & TypeFlags.StringLike ~= 0
    end
    if ast.IsElementAccessExpression(name) then
        local t = self.ch:checkExpression(name:AsElementAccessExpression().argumentExpression)
        return t.flags & TypeFlags.StringLike ~= 0
    end
    return ast.IsStringLiteral(name)
end

function NodeBuilderImpl:isSingleQuotedStringNamed(d)
    local name = ast.GetNameOfDeclaration(d)
    return name ~= nil and ast.IsStringLiteral(name) and name:AsStringLiteral().tokenFlags & ast.TokenFlags.SingleQuote ~= 0
end

function NodeBuilderImpl:getPropertyNameNodeForSymbol(symbol, enclosingDeclaration)
    -- For hash-private names, clone the original private identifier from the declaration
    if symbol.valueDeclaration ~= nil then
        local declName = symbol.valueDeclaration:Name()
        if declName ~= nil and ast.IsPrivateIdentifier(declName) then
            return self.f:DeepCloneNode(declName)
        end
    end
    local stringNamed = core.Len(symbol.declarations) ~= 0 and core.Every(symbol.declarations, function(d) return self:isStringNamed(d) end)
    local singleQuote = core.Len(symbol.declarations) ~= 0 and core.Every(symbol.declarations, function(d) return self:isSingleQuotedStringNamed(d) end)
    local isMethod = symbol.flags & SymbolFlags.Method ~= 0
    local fromNameType = self:getPropertyNameNodeForSymbolFromNameType(symbol, enclosingDeclaration, singleQuote, stringNamed, isMethod)
    if fromNameType ~= nil then
        return fromNameType
    end

    local name = symbol.name
    local privateNamePrefix = ast.InternalSymbolNamePrefix .. "#"
    if string.sub(name, 1, #privateNamePrefix) == privateNamePrefix then
        -- symbol IDs are unstable - replace #nnn# with #private#
        name = string.sub(name, #privateNamePrefix + 1)
        name = string.gsub(name, "^%d+", "")
        name = "__#private" .. name
    end

    return self:createPropertyNameNodeForIdentifierOrLiteral(name, singleQuote, stringNamed, isMethod, symbol)
end

-- See getNameForSymbolFromNameType for a stringy equivalent
function NodeBuilderImpl:getPropertyNameNodeForSymbolFromNameType(symbol, enclosingDeclaration, singleQuote, stringNamed, isMethod)
    if not self.ch.valueSymbolLinks:Has(symbol) then
        return nil
    end
    local nameType = self.ch.valueSymbolLinks:TryGet(symbol).nameType
    if nameType == nil then
        return nil
    end
    local enumEnclosingDeclaration = enclosingDeclaration
    if enumEnclosingDeclaration == nil and self.ctx.enclosingFile ~= nil then
        enumEnclosingDeclaration = self.ctx.enclosingFile
    end
    if nameType.flags & TypeFlags.EnumLiteral ~= 0 then
        local enumSymbol = nameType.symbol.parent
        if enumSymbol == nil then
            enumSymbol = nameType.symbol
        end
        if enumEnclosingDeclaration ~= nil and
            self.ch:IsSymbolAccessibleByFlags(enumSymbol, enumEnclosingDeclaration, SymbolFlags.Value) then
            local saveEnclosingDeclaration = self.ctx.enclosingDeclaration
            self.ctx.enclosingDeclaration = enumEnclosingDeclaration
            local result = self.f:NewComputedPropertyName(self:symbolToExpression(nameType.symbol, SymbolFlags.Value))
            self.ctx.enclosingDeclaration = saveEnclosingDeclaration
            return result
        end
    end
    if nameType.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
        local name = ""
        local v = nameType:AsLiteralType().value
        if type(v) == "number" then
            name = jsnum.Number_String(v)
        elseif type(v) == "string" then
            name = v
        end
        if not scanner.IsIdentifierText(name, core.LanguageVariant.Standard) and (stringNamed or not checker.isNumericLiteralName(name)) then
            local node = self.f:NewStringLiteral(name, core.IfElse(singleQuote, ast.TokenFlags.SingleQuote, ast.TokenFlags.None))
            return node
        end
        if checker.isNumericLiteralName(name) and string.sub(name, 1, 1) == "-" then
            return self.f:NewComputedPropertyName(self.f:NewPrefixUnaryExpression(Kind.MinusToken, self.f:NewNumericLiteral(string.sub(name, 2), ast.TokenFlags.None)))
        end
        return self:createPropertyNameNodeForIdentifierOrLiteral(name, singleQuote, stringNamed, isMethod, symbol)
    end
    if nameType.flags & TypeFlags.UniqueESSymbol ~= 0 then
        return self.f:NewComputedPropertyName(self:symbolToExpression(nameType:AsUniqueESSymbolType().symbol, SymbolFlags.Value))
    end
    return nil
end

function NodeBuilderImpl:addPropertyToElementList(propertySymbol, typeElements)
    local propertyIsReverseMapped = propertySymbol.checkFlags & CheckFlags.ReverseMapped ~= 0
    local propertyType
    if self:shouldUsePlaceholderForProperty(propertySymbol) then
        propertyType = self.ch.anyType
    else
        propertyType = self.ch:getNonMissingTypeOfSymbol(propertySymbol)
    end
    local saveEnclosingDeclaration = self.ctx.enclosingDeclaration
    self.ctx.enclosingDeclaration = nil
    if checker.isLateBoundName(propertySymbol.name) then
        if core.Len(propertySymbol.declarations) > 0 then
            local decl = propertySymbol.declarations[1]
            if self.ch:hasLateBindableName(decl) then
                if ast.IsBinaryExpression(decl) then
                    local name = ast.GetNameOfDeclaration(decl)
                    if name ~= nil and ast.IsElementAccessExpression(name) and ast.IsPropertyAccessEntityNameExpression(name:AsElementAccessExpression().argumentExpression, false --[[allowJs]]) then
                        self:trackComputedName(name:AsElementAccessExpression().argumentExpression, saveEnclosingDeclaration)
                    end
                else
                    self:trackComputedName(decl:Name():Expression(), saveEnclosingDeclaration)
                end
            end
        else
            self.ctx.tracker:ReportNonSerializableProperty(self.ch:symbolToString(propertySymbol))
        end
    end
    if propertySymbol.valueDeclaration ~= nil then
        self.ctx.enclosingDeclaration = propertySymbol.valueDeclaration
    elseif core.Len(propertySymbol.declarations) > 0 and propertySymbol.declarations[1] ~= nil then
        self.ctx.enclosingDeclaration = propertySymbol.declarations[1]
    else
        self.ctx.enclosingDeclaration = saveEnclosingDeclaration
    end
    local propertyName = self:getPropertyNameNodeForSymbol(propertySymbol, saveEnclosingDeclaration)
    self.ctx.enclosingDeclaration = saveEnclosingDeclaration
    self.ctx.approximateLength = self.ctx.approximateLength + #ast.SymbolName(propertySymbol) + 1

    if propertySymbol.flags & SymbolFlags.Accessor ~= 0 then
        local writeType = self.ch:getWriteTypeOfSymbol(propertySymbol)
        if not self.ch:isErrorType(propertyType) and not self.ch:isErrorType(writeType) then
            local propDeclaration = ast.GetDeclarationOfKind(propertySymbol, Kind.PropertyDeclaration)
            if propertyType ~= writeType or propertySymbol.parent ~= nil and propertySymbol.parent.flags & SymbolFlags.Class ~= 0 and propDeclaration == nil then
                local symbolMapper = self.ch.valueSymbolLinks:Get(propertySymbol).mapper
                local getterDeclaration = ast.GetDeclarationOfKind(propertySymbol, Kind.GetAccessor)
                if getterDeclaration ~= nil then
                    local getterSignature = self.ch:getSignatureFromDeclaration(getterDeclaration)
                    if symbolMapper ~= nil then
                        getterSignature = self.ch:instantiateSignature(getterSignature, symbolMapper)
                    end
                    local getter = self:signatureToSignatureDeclarationHelper(getterSignature, Kind.GetAccessor, checker.SignatureToSignatureDeclarationOptions_new({
                        name = propertyName,
                    }))
                    self:setCommentRange(getter, getterDeclaration)
                    typeElements = core.Append(typeElements, getter)
                end
                local setterDeclaration = ast.GetDeclarationOfKind(propertySymbol, Kind.SetAccessor)
                if setterDeclaration ~= nil then
                    local setterSignature = self.ch:getSignatureFromDeclaration(setterDeclaration)
                    if symbolMapper ~= nil then
                        setterSignature = self.ch:instantiateSignature(setterSignature, symbolMapper)
                    end
                    local setter = self:signatureToSignatureDeclarationHelper(setterSignature, Kind.SetAccessor, checker.SignatureToSignatureDeclarationOptions_new({
                        name = propertyName,
                    }))
                    self:setCommentRange(setter, setterDeclaration)
                    typeElements = core.Append(typeElements, setter)
                end
                return typeElements
            elseif propertySymbol.parent ~= nil and propertySymbol.parent.flags & SymbolFlags.Class ~= 0 and propDeclaration ~= nil and core.Find(propDeclaration:ModifierNodes(), function(m)
                return m.kind == Kind.AccessorKeyword
            end) ~= nil then
                local fakeGetterSignature = self.ch:newSignature(SignatureFlags.None, nil, nil, nil, nil, propertyType, nil, 0)
                local fakeGetterDeclaration = self:signatureToSignatureDeclarationHelper(fakeGetterSignature, Kind.GetAccessor, checker.SignatureToSignatureDeclarationOptions_new({
                    name = propertyName,
                }))
                self:setCommentRange(fakeGetterDeclaration, propDeclaration)
                typeElements = core.Append(typeElements, fakeGetterDeclaration)

                local setterParam = self.ch:newSymbol(SymbolFlags.FunctionScopedVariable, "arg")
                self.ch.valueSymbolLinks:Get(setterParam).resolvedType = writeType
                local fakeSetterSignature = self.ch:newSignature(SignatureFlags.None, nil, nil, nil, { setterParam }, self.ch.voidType, nil, 0)
                local fakeSetterDeclaration = self:signatureToSignatureDeclarationHelper(fakeSetterSignature, Kind.SetAccessor, checker.SignatureToSignatureDeclarationOptions_new({
                    name = propertyName,
                }))
                typeElements = core.Append(typeElements, fakeSetterDeclaration)
                return typeElements
            end
        end
    end

    local optionalToken
    if propertySymbol.flags & SymbolFlags.Optional ~= 0 then
        optionalToken = self.f:NewToken(Kind.QuestionToken)
    else
        optionalToken = nil
    end
    if propertySymbol.flags & (SymbolFlags.Function | SymbolFlags.Method) ~= 0 and core.Len(self.ch:getPropertiesOfObjectType(propertyType)) == 0 and not self.ch:isReadonlySymbol(propertySymbol) then
        local signatures = self.ch:getSignaturesOfType(self.ch:filterType(propertyType, function(t)
            return t.flags & TypeFlags.Undefined == 0
        end), checker.SignatureKind.Call)
        for _, signature in ipairs(signatures or {}) do
            local methodDeclaration = self:signatureToSignatureDeclarationHelper(signature, Kind.MethodSignature, checker.SignatureToSignatureDeclarationOptions_new({
                name = propertyName,
                questionToken = optionalToken,
            }))
            self:setCommentRange(methodDeclaration, core.Coalesce(signature.declaration, propertySymbol.valueDeclaration))
            typeElements = core.Append(typeElements, methodDeclaration)
        end
        if core.Len(signatures) ~= 0 or optionalToken == nil then
            return typeElements
        end
    end
    local propertyTypeNode
    if self:shouldUsePlaceholderForProperty(propertySymbol) then
        propertyTypeNode = self:createElidedInformationPlaceholder()
    else
        if propertyIsReverseMapped then
            self.ctx.reverseMappedStack = core.Append(self.ctx.reverseMappedStack, propertySymbol)
        end
        if propertyType ~= nil then
            propertyTypeNode = self:serializeTypeForDeclaration(nil --[[declaration]], propertyType, propertySymbol, true)
        else
            propertyTypeNode = self.f:NewKeywordTypeNode(Kind.AnyKeyword)
        end
        if propertyIsReverseMapped then
            local stack = self.ctx.reverseMappedStack
            stack[#stack] = nil
        end
    end

    local modifiers
    if self.ch:isReadonlySymbol(propertySymbol) then
        modifiers = self.f:NewModifierList({ self.f:NewModifier(Kind.ReadonlyKeyword) })
        self.ctx.approximateLength = self.ctx.approximateLength + 9
    end
    local propertySignature = self.f:NewPropertySignatureDeclaration(modifiers, propertyName, optionalToken, propertyTypeNode, nil)

    self:setCommentRange(propertySignature, propertySymbol.valueDeclaration)
    typeElements = core.Append(typeElements, propertySignature)

    return typeElements
end

function NodeBuilderImpl:createTypeNodesFromResolvedType(resolvedType)
    if self:checkTruncationLength() then
        if self.ctx.flags & Flags.NoTruncation ~= 0 then
            local elem = self.f:NewNotEmittedTypeElement()
            return self.f:NewNodeList({ self.e:AddSyntheticTrailingComment(elem, Kind.MultiLineCommentTrivia, "elided", false --[[hasTrailingNewLine]]) })
        end
        return self.f:NewNodeList({ self.f:NewPropertySignatureDeclaration(nil, self.f:NewIdentifier("..."), nil, nil, nil) })
    end
    local typeElements
    for _, signature in ipairs(resolvedType:CallSignatures() or {}) do
        typeElements = core.Append(typeElements, self:signatureToSignatureDeclarationHelper(signature, Kind.CallSignature, nil))
    end
    for _, signature in ipairs(resolvedType:ConstructSignatures() or {}) do
        if signature.flags & SignatureFlags.Abstract ~= 0 then
            goto continue
        end
        typeElements = core.Append(typeElements, self:signatureToSignatureDeclarationHelper(signature, Kind.ConstructSignature, nil))
        ::continue::
    end
    for _, info in ipairs(resolvedType.indexInfos or {}) do
        local placeholder
        if resolvedType.objectFlags & ObjectFlags.ReverseMapped ~= 0 then
            placeholder = self:createElidedInformationPlaceholder()
        end
        typeElements = core.AppendAll(typeElements, self:indexInfoToObjectComputedNamesOrSignatureDeclaration(info, placeholder))
    end

    local properties = resolvedType.properties
    if core.Len(properties) == 0 then
        return self.f:NewNodeList(typeElements or {})
    end

    local i = 0
    for _, propertySymbol in ipairs(properties) do
        if checker.isExpanding(self.ctx) and propertySymbol.flags & SymbolFlags.Prototype ~= 0 then
            goto continue
        end
        i = i + 1
        if self.ctx.flags & Flags.WriteClassExpressionAsTypeLiteral ~= 0 then
            if propertySymbol.flags & SymbolFlags.Prototype ~= 0 then
                goto continue
            end
            if checker.getDeclarationModifierFlagsFromSymbol(propertySymbol) & (ModifierFlags.Private | ModifierFlags.Protected) ~= 0 then
                self.ctx.tracker:ReportPrivateInBaseOfClassExpression(propertySymbol.name)
            end
            if checker.IsPrivateIdentifierSymbol(propertySymbol) then
                self.ctx.tracker:ReportPrivateInBaseOfClassExpression(ast.SymbolName(propertySymbol))
            end
        end
        if self:checkTruncationLength() and (i + 2 < #properties - 1) then
            if self.ctx.flags & Flags.NoTruncation ~= 0 then
                typeElements[#typeElements] = self.e:AddSyntheticTrailingComment(typeElements[#typeElements], Kind.MultiLineCommentTrivia, string.format("... %d more elided ...", #properties - i), false --[[hasTrailingNewLine]])
            else
                local text = string.format("... %d more ...", #properties - i)
                typeElements = core.Append(typeElements, self.f:NewPropertySignatureDeclaration(nil, self.f:NewIdentifier(text), nil, nil, nil))
            end
            typeElements = self:addPropertyToElementList(properties[#properties], typeElements)
            break
        end
        typeElements = self:addPropertyToElementList(propertySymbol, typeElements)
        ::continue::
    end
    if core.Len(typeElements) ~= 0 then
        return self.f:NewNodeList(typeElements)
    else
        return nil
    end
end

function NodeBuilderImpl:createTypeNodeFromObjectType(t)
    if self.ch:isGenericMappedType(t) or (t.objectFlags & ObjectFlags.Mapped ~= 0 and t:AsMappedType().containsError) then
        return self:createMappedTypeNodeFromType(t)
    end

    local resolved = self.ch:resolveStructuredTypeMembers(t)
    local callSigs = resolved:CallSignatures()
    local ctorSigs = resolved:ConstructSignatures()
    if core.Len(resolved.properties) == 0 and core.Len(resolved.indexInfos) == 0 then
        if core.Len(callSigs) == 0 and core.Len(ctorSigs) == 0 then
            self.ctx.approximateLength = self.ctx.approximateLength + 2
            local result = self.f:NewTypeLiteralNode(self.f:NewNodeList({}))
            self.e:SetEmitFlags(result, EmitFlags.EFSingleLine)
            return result
        end

        if core.Len(callSigs) == 1 and core.Len(ctorSigs) == 0 then
            local signature = callSigs[1]
            local signatureNode = self:signatureToSignatureDeclarationHelper(signature, Kind.FunctionType, nil)
            return signatureNode
        end

        if core.Len(ctorSigs) == 1 and core.Len(callSigs) == 0 then
            local signature = ctorSigs[1]
            local signatureNode = self:signatureToSignatureDeclarationHelper(signature, Kind.ConstructorType, nil)
            return signatureNode
        end
    end

    local abstractSignatures = core.Filter(ctorSigs, function(signature)
        return signature.flags & SignatureFlags.Abstract ~= 0
    end)
    if core.Len(abstractSignatures) > 0 then
        local types = core.Map(abstractSignatures, function(s)
            return self.ch:getOrCreateTypeFromSignature(s)
        end)
        -- count the number of type elements excluding abstract constructors
        local propertyCount
        if self.ctx.flags & Flags.WriteClassExpressionAsTypeLiteral ~= 0 then
            propertyCount = core.CountWhere(resolved.properties, function(p)
                return p.flags & SymbolFlags.Prototype == 0
            end)
        else
            propertyCount = core.Len(resolved.properties)
        end
        local typeElementCount = core.Len(callSigs) + (core.Len(ctorSigs) - #abstractSignatures) + core.Len(resolved.indexInfos) + propertyCount
        -- don't include an empty object literal if there were no other static-side
        -- properties to write, i.e. `abstract class C { }` becomes `abstract new () => {}`
        -- and not `(abstract new () => {}) & {}`
        if typeElementCount ~= 0 then
            -- create a copy of the object type without any abstract construct signatures.
            types[#types + 1] = self:getResolvedTypeWithoutAbstractConstructSignatures(resolved)
        end
        return self:typeToTypeNode(self.ch:getIntersectionType(types))
    end

    local restoreFlags = self:saveRestoreFlags()
    self.ctx.flags = self.ctx.flags | Flags.InObjectTypeLiteral
    local members = self:createTypeNodesFromResolvedType(resolved)
    restoreFlags()
    local typeLiteralNode = self.f:NewTypeLiteralNode(members)
    self.ctx.approximateLength = self.ctx.approximateLength + 2
    self.e:SetEmitFlags(typeLiteralNode, core.IfElse((self.ctx.flags & Flags.MultilineObjectLiterals ~= 0), 0, EmitFlags.EFSingleLine))
    return typeLiteralNode
end

function checker.getTypeAliasForTypeLiteral(c, t)
    if t.symbol ~= nil and t.symbol.flags & SymbolFlags.TypeLiteral ~= 0 and t.symbol.declarations ~= nil then
        local node = ast.WalkUpParenthesizedTypes(t.symbol.declarations[1].parent)
        if ast.IsTypeAliasDeclaration(node) then
            return c:getSymbolOfDeclaration(node)
        end
    end
    return nil
end

function NodeBuilderImpl:shouldWriteTypeOfFunctionSymbol(symbol, typeId)
    local isStaticMethodSymbol = symbol.flags & SymbolFlags.Method ~= 0 and core.Some(symbol.declarations, function(declaration)
        return ast.IsStatic(declaration) and not self.ch:isLateBindableIndexSignature(ast.GetNameOfDeclaration(declaration))
    end)
    local isNonLocalFunctionSymbol = false
    local isFunctionExpressionSymbol = false
    if symbol.flags & SymbolFlags.Function ~= 0 then
        if symbol.parent ~= nil then
            isNonLocalFunctionSymbol = true
        else
            for _, declaration in ipairs(symbol.declarations or {}) do
                if declaration.parent.kind == Kind.SourceFile or declaration.parent.kind == Kind.ModuleBlock then
                    isNonLocalFunctionSymbol = true
                    break
                end
                if ast.IsFunctionExpressionOrArrowFunction(declaration) and ast.IsVariableDeclaration(declaration.parent) and
                    ast.IsVariableDeclarationList(declaration.parent.parent) and ast.IsVariableStatement(declaration.parent.parent.parent) and
                    declaration.parent.parent.parent.parent ~= nil and
                    (declaration.parent.parent.parent.parent.kind == Kind.SourceFile or declaration.parent.parent.parent.parent.kind == Kind.ModuleBlock) then
                    isNonLocalFunctionSymbol = true
                    isFunctionExpressionSymbol = true
                    break
                end
            end
        end
    end
    if isStaticMethodSymbol or isNonLocalFunctionSymbol then
        if isFunctionExpressionSymbol and symbol.valueDeclaration ~= nil and symbol.valueDeclaration.parent ~= nil and symbol.valueDeclaration.parent ~= self.ctx.enclosingDeclaration then
            symbol = self.ch:getMergedSymbol(symbol.valueDeclaration.parent:Symbol())
        end
        -- typeof is allowed only for static/non local functions
        return (self.ctx.flags & Flags.UseTypeOfFunction ~= 0 or self.ctx.visitedTypes:Has(typeId)) and -- it is type of the symbol uses itself recursively
            (self.ctx.flags & Flags.UseStructuralFallback == 0 or self.ch:IsValueSymbolAccessible(symbol, self.ctx.enclosingDeclaration)), symbol -- And the build is going to succeed without visibility error or there is no structural fallback allowed
    end
    return false, symbol
end

function NodeBuilderImpl:createAnonymousTypeNode(t)
    return self:createAnonymousTypeNodeEx(t, false, false)
end

function NodeBuilderImpl:shouldEmitTypeOfSymbol(forceExpansion, forceClassExpansion, isInstanceType, symbol, typeId)
    if forceExpansion then
        return false, symbol
    end
    local nonFunctionResult = symbol.flags & SymbolFlags.Class ~= 0 and not forceClassExpansion and self.ch:getBaseTypeVariableOfClass(symbol) == nil and not (symbol.valueDeclaration ~= nil and ast.IsClassLike(symbol.valueDeclaration) and self.ctx.flags & Flags.WriteClassExpressionAsTypeLiteral ~= 0 and (not ast.IsClassDeclaration(symbol.valueDeclaration) or self.ch:IsSymbolAccessible(symbol, self.ctx.enclosingDeclaration, isInstanceType, false --[[shouldComputeAliasesToMakeVisible]]).accessibility ~= printer.SymbolAccessibility.Accessible)) or symbol.flags & (SymbolFlags.Enum | SymbolFlags.ValueModule) ~= 0
    if nonFunctionResult then
        return true, symbol
    end
    return self:shouldWriteTypeOfFunctionSymbol(symbol, typeId)
end

local function createTypeNodeFromObjectTypeTransform(b, t)
    return b:createTypeNodeFromObjectType(t)
end

local function typeToTypeNodeTransform(b, t)
    return b:typeToTypeNode(t)
end

function NodeBuilderImpl:createAnonymousTypeNodeEx(t, forceClassExpansion, forceExpansion)
    local typeId = t.id
    local symbol = t.symbol
    if symbol ~= nil then
        local isInstantiationExpressionType = t.objectFlags & ObjectFlags.InstantiationExpressionType ~= 0
        if isInstantiationExpressionType then
            local instantiationExpressionType = t:AsInstantiationExpressionType()
            local existing = instantiationExpressionType.node
            --  instantiationExpressionType.node is unreliable for constituents of unions and intersections.
            -- declare const Err: typeof ErrImpl & (<T>() => T);
            -- type ErrAlias<U> = typeof Err<U>;
            -- declare const e: ErrAlias<number>;
            -- ErrAlias<number> = typeof Err<number> = typeof ErrImpl & (<number>() => number)
            -- The problem is each constituent of the intersection will be associated with typeof Err<number>
            -- And when extracting a type for typeof ErrImpl from typeof Err<number> does not make sense.
            if ast.IsTypeQueryNode(existing) and self:getTypeFromTypeNode(existing, false) == t then
                -- Guard against unbounded recursion when the existing typeof node fails to be reused
                -- (e.g. its entity name isn't accessible from this scope) and the recovery boundary's
                -- fallback re-enters typeToTypeNode with the very same instantiation type, which would
                -- in turn try to reuse the same node again. Mark the type as visited around the reuse
                -- attempt so the inner recursion bottoms out via the visitedTypes guard below.
                if self.ctx.visitedTypes:Has(typeId) then
                    return self:createElidedInformationPlaceholder()
                end
                self.ctx.visitedTypes:Add(typeId)
                local typeNode = self:tryReuseExistingNonParameterTypeNode(existing, t, nil, nil)
                self.ctx.visitedTypes:Delete(typeId)
                if typeNode ~= nil then
                    return typeNode
                end
            end
            if self.ctx.visitedTypes:Has(typeId) then
                return self:createElidedInformationPlaceholder()
            end
            return self:visitAndTransformType(t, createTypeNodeFromObjectTypeTransform)
        end
        local isInstanceType
        if checker.isClassInstanceSide(self.ch, t) then
            isInstanceType = SymbolFlags.Type
        else
            isInstanceType = SymbolFlags.Value
        end

        -- !!! JS support
        -- if c.isJSConstructor(symbol.ValueDeclaration) {
        -- 	// Instance and static types share the same symbol; only add 'typeof' for the static side.
        -- 	return b.symbolToTypeNode(symbol, isInstanceType, nil)
        -- } else
        local ok, sym = self:shouldEmitTypeOfSymbol(forceExpansion, forceClassExpansion, isInstanceType, symbol, typeId)
        if ok then
            if self:shouldExpandType(t, false --[[isAlias]]) then
                self.ctx.depth = self.ctx.depth + 1
            else
                return self:symbolToTypeNode(sym, isInstanceType, nil)
            end
        end
        if self.ctx.visitedTypes:Has(typeId) then
            -- If type is an anonymous type literal in a type alias declaration, use type alias name
            local typeAlias = checker.getTypeAliasForTypeLiteral(self.ch, t)
            if typeAlias ~= nil then
                -- The specified symbol flags need to be reinterpreted as type flags
                return self:symbolToTypeNode(typeAlias, SymbolFlags.Type, nil)
            else
                return self:createElidedInformationPlaceholder()
            end
        else
            return self:visitAndTransformType(t, createTypeNodeFromObjectTypeTransform)
        end
    else
        -- Anonymous types without a symbol are never circular.
        return self:createTypeNodeFromObjectType(t)
    end
end

function NodeBuilderImpl:getTypeFromTypeNode(node, noMappedTypes)
    -- !!! noMappedTypes optional param support
    if node.parent == nil then
        return self.ch.errorType
    end
    local t = self.ch:getTypeFromTypeNode(node)
    if self.ctx.mapper == nil then
        return t
    end

    local instantiated = self.ch:instantiateType(t, self.ctx.mapper)
    if noMappedTypes and instantiated ~= t then
        return nil
    end
    return instantiated
end

function NodeBuilderImpl:typeToTypeNodeOrCircularityElision(t)
    if t.flags & TypeFlags.Union ~= 0 then
        if self.ctx.visitedTypes:Has(t.id) then
            if self.ctx.flags & Flags.AllowAnonymousIdentifier == 0 then
                self.ctx.encounteredError = true
                self.ctx.tracker:ReportCyclicStructureError()
            end
            return self:createElidedInformationPlaceholder()
        end
        return self:visitAndTransformType(t, typeToTypeNodeTransform)
    end
    return self:typeToTypeNode(t)
end

function NodeBuilderImpl:conditionalTypeToTypeNode(t_)
    if self:checkTruncationLength() then
        return self:createElidedInformationPlaceholder()
    end
    local t = t_:AsConditionalType()
    local checkTypeNode = self:typeToTypeNode(t.checkType)
    self.ctx.approximateLength = self.ctx.approximateLength + 15
    if self.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 and t.root.isDistributive and t.checkType.flags & TypeFlags.TypeParameter == 0 then
        local newParam = self.ch:newTypeParameter(self.ch:newSymbol(SymbolFlags.TypeParameter, "T" --[[ as __String ]]))
        local name = self:typeParameterToName(newParam)
        local newTypeVariable = self.f:NewTypeReferenceNode(name, nil)
        self.ctx.approximateLength = self.ctx.approximateLength + 37
        -- 15 each for two added conditionals, 7 for an added infer type
        local newMapper = checker.prependTypeMapping(t.root.checkType, newParam, t.mapper)
        local saveInferTypeParameters = self.ctx.inferTypeParameters
        self.ctx.inferTypeParameters = t.root.inferTypeParameters
        local extendsTypeNode = self:typeToTypeNode(self.ch:instantiateType(t.root.extendsType, newMapper))
        self.ctx.inferTypeParameters = saveInferTypeParameters
        local trueTypeNode = self:typeToTypeNodeOrCircularityElision(self.ch:instantiateType(self:getTypeFromTypeNode(t.root.node.trueType, false), newMapper))
        local falseTypeNode = self:typeToTypeNodeOrCircularityElision(self.ch:instantiateType(self:getTypeFromTypeNode(t.root.node.falseType, false), newMapper))

        -- outermost conditional makes `T` a type parameter, allowing the inner conditionals to be distributive
        -- second conditional makes `T` have `T & checkType` substitution, so it is correctly usable as the checkType
        -- inner conditional runs the check the user provided on the check type (distributively) and returns the result
        -- checkType extends infer T ? T extends checkType ? T extends extendsType<T> ? trueType<T> : falseType<T> : never : never;
        -- this is potentially simplifiable to
        -- checkType extends infer T ? T extends checkType & extendsType<T> ? trueType<T> : falseType<T> : never;
        -- but that may confuse users who read the output more.
        -- On the other hand,
        -- checkType extends infer T extends checkType ? T extends extendsType<T> ? trueType<T> : falseType<T> : never;
        -- may also work with `infer ... extends ...` in, but would produce declarations only compatible with the latest TS.
        local newId = newTypeVariable:AsTypeReferenceNode().typeName:AsIdentifier():Clone(self.f)
        local syntheticExtendsNode = self.f:NewInferTypeNode(self.f:NewTypeParameterDeclaration(nil, newId, nil, nil, nil))
        local innerCheckConditionalNode = self.f:NewConditionalTypeNode(newTypeVariable, extendsTypeNode, trueTypeNode, falseTypeNode)
        local syntheticTrueNode = self.f:NewConditionalTypeNode(self.f:NewTypeReferenceNode(name:Clone(self.f), nil), self.f:DeepCloneNode(checkTypeNode), innerCheckConditionalNode, self.f:NewKeywordTypeNode(Kind.NeverKeyword))
        return self.f:NewConditionalTypeNode(checkTypeNode, syntheticExtendsNode, syntheticTrueNode, self.f:NewKeywordTypeNode(Kind.NeverKeyword))
    end
    local saveInferTypeParameters = self.ctx.inferTypeParameters
    self.ctx.inferTypeParameters = t.root.inferTypeParameters
    local extendsTypeNode = self:typeToTypeNode(t.extendsType)
    self.ctx.inferTypeParameters = saveInferTypeParameters
    local trueTypeNode = self:typeToTypeNodeOrCircularityElision(self.ch:getTrueTypeFromConditionalType(t_))
    local falseTypeNode = self:typeToTypeNodeOrCircularityElision(self.ch:getFalseTypeFromConditionalType(t_))
    return self.f:NewConditionalTypeNode(checkTypeNode, extendsTypeNode, trueTypeNode, falseTypeNode)
end

function NodeBuilderImpl:getParentSymbolOfTypeParameter(typeParameter)
    local tp = ast.GetDeclarationOfKind(typeParameter.symbol, Kind.TypeParameter)
    local host
    -- !!! JSDoc support
    -- if ast.IsJSDocTemplateTag(tp.Parent) {
    -- 	host = getEffectiveContainerForJSDocTemplateTag(tp.Parent)
    -- } else {
    host = tp.parent
    -- }
    if host == nil then
        return nil
    end
    return self.ch:getSymbolOfNode(host)
end

local function slicesEqual(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function NodeBuilderImpl:typeReferenceToTypeNode(t)
    local typeArguments = self.ch:getTypeArguments(t)
    if t:Target() == self.ch.globalArrayType or t:Target() == self.ch.globalReadonlyArrayType then
        if self.ctx.flags & Flags.WriteArrayAsGenericType ~= 0 then
            local typeArgumentNode = self:typeToTypeNode(typeArguments[1])
            return self.f:NewTypeReferenceNode(
                self:newIdentifier(core.IfElse(t:Target() == self.ch.globalArrayType, "Array", "ReadonlyArray"), t:Target().symbol),
                self.f:NewNodeList({ typeArgumentNode })
            )
        end
        local elementType = self:typeToTypeNode(typeArguments[1])
        local arrayType = self.f:NewArrayTypeNode(elementType)
        if t:Target() == self.ch.globalArrayType then
            return arrayType
        else
            return self.f:NewTypeOperatorNode(Kind.ReadonlyKeyword, arrayType)
        end
    elseif t:Target().objectFlags & ObjectFlags.Tuple ~= 0 then
        typeArguments = core.SameMapIndex(typeArguments, function(arg, i)
            local isOptional = false
            if i < core.Len(t:Target():AsTupleType().elementInfos) then
                isOptional = t:Target():AsTupleType().elementInfos[i + 1].flags & ElementFlags.Optional ~= 0
            end
            return self.ch:removeMissingType(arg, isOptional)
        end)
        if core.Len(typeArguments) > 0 then
            local arity = self.ch:getTypeReferenceArity(t)
            local tupleConstituentNodes = self:mapToTypeNodes(core.Slice(typeArguments, 0, arity), false --[[isBareList]])
            if tupleConstituentNodes ~= nil then
                local nodes = tupleConstituentNodes.nodes
                for i = 0, #nodes - 1 do
                    local info = t:Target():AsTupleType().elementInfos[i + 1]
                    local flags = info.flags
                    local labeledElementDeclaration = info.labeledDeclaration

                    if labeledElementDeclaration ~= nil then
                        local dotDotDot
                        if flags & ElementFlags.Variable ~= 0 then
                            dotDotDot = self.f:NewToken(Kind.DotDotDotToken)
                        end
                        local label = self:newIdentifier(self.ch:getTupleElementLabel(info, nil, i), nil --[[symbol]])
                        local question
                        if flags & ElementFlags.Optional ~= 0 then
                            question = self.f:NewToken(Kind.QuestionToken)
                        end
                        local elementNode
                        if flags & ElementFlags.Rest ~= 0 then
                            elementNode = self.f:NewArrayTypeNode(nodes[i + 1])
                        else
                            elementNode = nodes[i + 1]
                        end
                        nodes[i + 1] = self.f:NewNamedTupleMember(dotDotDot, label, question, elementNode)
                    else
                        if flags & ElementFlags.Variable ~= 0 then
                            local elementNode
                            if flags & ElementFlags.Rest ~= 0 then
                                elementNode = self.f:NewArrayTypeNode(nodes[i + 1])
                            else
                                elementNode = nodes[i + 1]
                            end
                            nodes[i + 1] = self.f:NewRestTypeNode(elementNode)
                        elseif flags & ElementFlags.Optional ~= 0 then
                            nodes[i + 1] = self.f:NewOptionalTypeNode(nodes[i + 1])
                        end
                    end
                end
                local tupleTypeNode = self.f:NewTupleTypeNode(tupleConstituentNodes)
                self.e:SetEmitFlags(tupleTypeNode, EmitFlags.EFSingleLine)
                if t:Target():AsTupleType().readonly then
                    return self.f:NewTypeOperatorNode(Kind.ReadonlyKeyword, tupleTypeNode)
                else
                    return tupleTypeNode
                end
            end
        end
        if self.ctx.encounteredError or (self.ctx.flags & Flags.AllowEmptyTuple ~= 0) then
            local tupleTypeNode = self.f:NewTupleTypeNode(self.f:NewNodeList({}))
            self.e:SetEmitFlags(tupleTypeNode, EmitFlags.EFSingleLine)
            if t:Target():AsTupleType().readonly then
                return self.f:NewTypeOperatorNode(Kind.ReadonlyKeyword, tupleTypeNode)
            else
                return tupleTypeNode
            end
        end
        self.ctx.encounteredError = true
        return nil
        -- TODO: GH#18217
    elseif self.ctx.flags & Flags.WriteClassExpressionAsTypeLiteral ~= 0 and t.symbol.valueDeclaration ~= nil and ast.IsClassLike(t.symbol.valueDeclaration) and not self.ch:IsValueSymbolAccessible(t.symbol, self.ctx.enclosingDeclaration) then
        return self:createAnonymousTypeNode(t)
    else
        local outerTypeParameters = t:Target():AsInterfaceType():OuterTypeParameters()
        local i = 0
        local resultType
        if outerTypeParameters ~= nil then
            local length = #outerTypeParameters
            while i < length do
                -- Find group of type arguments for type parameters with the same declaring container.
                local start = i
                local parent = self:getParentSymbolOfTypeParameter(outerTypeParameters[i + 1]:AsTypeParameter())
                repeat -- do-while loop
                    i = i + 1
                until not (i < length and self:getParentSymbolOfTypeParameter(outerTypeParameters[i + 1]:AsTypeParameter()) == parent)
                -- When type parameters are their own type arguments for the whole group (i.e. we have
                -- the default outer type arguments), we don't show the group.

                if not slicesEqual(core.Slice(outerTypeParameters, start, i), core.Slice(typeArguments, start, i)) then
                    local typeArgumentSlice = self:mapToTypeNodes(core.Slice(typeArguments, start, i), false --[[isBareList]])
                    local restoreFlags = self:saveRestoreFlags()
                    self.ctx.flags = self.ctx.flags | Flags.ForbidIndexedAccessSymbolReferences
                    local ref = self:symbolToTypeNode(parent, SymbolFlags.Type, typeArgumentSlice)
                    restoreFlags()
                    if resultType == nil then
                        resultType = ref
                    else
                        resultType = self:appendReferenceToType(resultType, ref)
                    end
                end
            end
        end
        local typeArgumentNodes
        if core.Len(typeArguments) > 0 then
            local typeParameterCount = 0
            local typeParams = t:Target():AsInterfaceType():TypeParameters()
            if typeParams ~= nil then
                typeParameterCount = math.min(#typeParams, #typeArguments)

                -- Maybe we should do this for more types, but for now we only elide type arguments that are
                -- identical to their associated type parameters' defaults for `Iterable`, `IterableIterator`,
                -- `AsyncIterable`, and `AsyncIterableIterator` to provide backwards-compatible .d.ts emit due
                -- to each now having three type parameters instead of only one.
                if self.ch:isReferenceToType(t, self.ch.getGlobalIterableType()) or self.ch:isReferenceToType(t, self.ch.getGlobalIterableIteratorType()) or self.ch:isReferenceToType(t, self.ch.getGlobalAsyncIterableType()) or self.ch:isReferenceToType(t, self.ch.getGlobalAsyncIterableIteratorType()) then
                    local refNode = t:AsTypeReference().node
                    if refNode == nil or not ast.IsTypeReferenceNode(refNode) or refNode:TypeArguments() == nil or #refNode:TypeArguments() < typeParameterCount then
                        while typeParameterCount > 0 do
                            local typeArgument = typeArguments[typeParameterCount]
                            local typeParameter = t:Target():AsInterfaceType():TypeParameters()[typeParameterCount]
                            local defaultType = self.ch:getDefaultFromTypeParameter(typeParameter)
                            if defaultType == nil or not self.ch:isTypeIdenticalTo(typeArgument, defaultType) then
                                break
                            end
                            typeParameterCount = typeParameterCount - 1
                        end
                    end
                end
            end

            typeArgumentNodes = self:mapToTypeNodes(core.Slice(typeArguments, i, typeParameterCount), false --[[isBareList]])
        end
        local restoreFlags = self:saveRestoreFlags()
        self.ctx.flags = self.ctx.flags | Flags.ForbidIndexedAccessSymbolReferences
        local finalRef = self:symbolToTypeNode(t.symbol, SymbolFlags.Type, typeArgumentNodes)
        restoreFlags()
        if resultType == nil then
            return finalRef
        else
            return self:appendReferenceToType(resultType, finalRef)
        end
    end
end

local function typeReferenceToTypeNodeTransform(b, t)
    return b:typeReferenceToTypeNode(t)
end

local function conditionalTypeToTypeNodeTransform(b, t)
    return b:conditionalTypeToTypeNode(t)
end

function NodeBuilderImpl:visitAndTransformType(t, transform)
    local typeId = t.id
    local isConstructorObject = t.objectFlags & ObjectFlags.Anonymous ~= 0 and t.symbol ~= nil and t.symbol.flags & SymbolFlags.Class ~= 0
    local id
    if t.objectFlags & ObjectFlags.Reference ~= 0 and t:AsTypeReference().node ~= nil then
        id = { isConstructorNode = false, symbolId = 0, nodeId = ast.GetNodeId(t:AsTypeReference().node) }
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        id = { isConstructorNode = false, symbolId = 0, nodeId = ast.GetNodeId(t:AsConditionalType().root.node) }
    elseif t.symbol ~= nil then
        id = { isConstructorNode = isConstructorObject, symbolId = ast.GetSymbolId(t.symbol), nodeId = 0 }
    else
        id = nil
    end
    local idKey
    if id ~= nil then
        idKey = checker.CompositeSymbolIdentityKey(id)
    end
    -- Since instantiations of the same anonymous type have the same symbol, tracking symbols instead
    -- of types allows us to catch circular references to instantiations of the same anonymous type

    local key = checker.CompositeTypeCacheIdentityKey(typeId, self.ctx.flags, self.ctx.internalFlags)
    -- Don't rely on type cache if we're expanding a type, because we need to compute `canIncreaseExpansionDepth`.
    local canUseCache = self.ctx.maxExpansionDepth < 0
    if canUseCache and self.ctx.enclosingDeclaration ~= nil and self.links:Has(self.ctx.enclosingDeclaration) then
        local links = self.links:Get(self.ctx.enclosingDeclaration)
        local cachedResult = links.serializedTypes and links.serializedTypes[key]
        if cachedResult ~= nil then
            -- TODO:: check if we instead store late painted statements associated with this?
            for _, arg in ipairs(cachedResult.trackedSymbols or {}) do
                self.ctx.tracker:TrackSymbol(arg.symbol, arg.enclosingDeclaration, arg.meaning)
            end
            if cachedResult.truncating then
                self.ctx.truncating = true
            end
            self.ctx.approximateLength = self.ctx.approximateLength + cachedResult.addedLength
            return self.f:DeepCloneNode(cachedResult.node)
        end
    end

    local depth = 0
    if id ~= nil then
        depth = self.ctx.symbolDepth[idKey] or 0
        if depth > 10 then
            return self:createElidedInformationPlaceholder()
        end
        self.ctx.symbolDepth[idKey] = depth + 1
    end
    self.ctx.visitedTypes:Add(typeId)
    local prevTrackedSymbols = self.ctx.trackedSymbols
    self.ctx.trackedSymbols = nil
    local startLength = self.ctx.approximateLength
    local result = transform(self, t)
    local addedLength = self.ctx.approximateLength - startLength
    if canUseCache and not self.ctx.reportedDiagnostic and not self.ctx.encounteredError then
        local links = self.links:Get(self.ctx.enclosingDeclaration)
        if links.serializedTypes == nil then
            links.serializedTypes = {}
        end
        links.serializedTypes[key] = checker.SerializedTypeEntry_new({
            node = result,
            truncating = self.ctx.truncating,
            addedLength = addedLength,
            trackedSymbols = self.ctx.trackedSymbols,
        })
    end
    self.ctx.visitedTypes:Delete(typeId)
    if id ~= nil then
        self.ctx.symbolDepth[idKey] = depth
    end
    self.ctx.trackedSymbols = prevTrackedSymbols
    return result

    -- !!! TODO: Attempt node reuse or parse nodes to minimize copying once text range setting is set up
    -- deepCloneOrReuseNode := func(node T) T {
    -- 	if !nodeIsSynthesized(node) && getParseTreeNode(node) == node {
    -- 		return node
    -- 	}
    -- 	return setTextRange(b.ctx, b.f.cloneNode(visitEachChildWorker(node, deepCloneOrReuseNode, nil /*b.ctx*/, deepCloneOrReuseNodes, deepCloneOrReuseNode)), node)
    -- }

    -- deepCloneOrReuseNodes := func(nodes *NodeArray[*ast.Node], visitor Visitor, test func(node *ast.Node) bool, start number, count number) *NodeArray[*ast.Node] {
    -- 	if nodes != nil && nodes.length == 0 {
    -- 		// Ensure we explicitly make a copy of an empty array; visitNodes will not do this unless the array has elements,
    -- 		// which can lead to us reusing the same empty NodeArray more than once within the same AST during type noding.
    -- 		return setTextRangeWorker(b.f.NewNodeArray(nil, nodes.hasTrailingComma), nodes)
    -- 	}
    -- 	return visitNodes(nodes, visitor, test, start, count)
    -- }
end

-- Body of typeToTypeNode; `deferred.depth` records Go's `defer func() { b.ctx.depth-- }()`.
local function typeToTypeNodeBody(b, t, deferred)
    local inTypeAlias = b.ctx.flags & Flags.InTypeAlias
    b.ctx.flags = b.ctx.flags & ~Flags.InTypeAlias

    if t == nil then
        if b.ctx.flags & Flags.AllowEmptyUnionOrIntersection == 0 then
            b.ctx.encounteredError = true
            return nil
            -- TODO: GH#18217
        end
        b.ctx.approximateLength = b.ctx.approximateLength + 3
        return b.f:NewKeywordTypeNode(Kind.AnyKeyword)
    end

    if b.ctx.flags & Flags.NoTypeReduction == 0 then
        t = b.ch:getReducedType(t)
    end

    if t.flags & TypeFlags.Any ~= 0 then
        if t.alias ~= nil then
            return t.alias:ToTypeReferenceNode(b)
        end
        if t == b.ch.unresolvedType then
            return b.e:AddSyntheticLeadingComment(b.f:NewKeywordTypeNode(Kind.AnyKeyword), Kind.MultiLineCommentTrivia, "unresolved", false --[[hasTrailingNewLine]])
        end
        b.ctx.approximateLength = b.ctx.approximateLength + 3
        return b.f:NewKeywordTypeNode(core.IfElse(t == b.ch.intrinsicMarkerType, Kind.IntrinsicKeyword, Kind.AnyKeyword))
    end
    if t.flags & TypeFlags.Unknown ~= 0 then
        return b.f:NewKeywordTypeNode(Kind.UnknownKeyword)
    end
    if t.flags & TypeFlags.String ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        return b.f:NewKeywordTypeNode(Kind.StringKeyword)
    end
    if t.flags & TypeFlags.Number ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        return b.f:NewKeywordTypeNode(Kind.NumberKeyword)
    end
    if t.flags & TypeFlags.BigInt ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        return b.f:NewKeywordTypeNode(Kind.BigIntKeyword)
    end
    if t.flags & TypeFlags.Boolean ~= 0 and t.alias == nil then
        b.ctx.approximateLength = b.ctx.approximateLength + 7
        return b.f:NewKeywordTypeNode(Kind.BooleanKeyword)
    end
    local expandingEnum = false
    if t.flags & TypeFlags.EnumLike ~= 0 then
        if t.symbol.flags & SymbolFlags.EnumMember ~= 0 then
            local parentSymbol = b.ch:getParentOfSymbol(t.symbol)
            local parentName = b:symbolToTypeNode(parentSymbol, SymbolFlags.Type, nil)
            if b.ch:getDeclaredTypeOfSymbol(parentSymbol) == t then
                return parentName
            end
            local memberName = ast.SymbolName(t.symbol)
            if scanner.IsIdentifierText(memberName, core.LanguageVariant.Standard) then
                return b:appendReferenceToType(parentName --[[ as TypeReference | ImportTypeNode ]], b.f:NewTypeReferenceNode(b.f:NewIdentifier(memberName), nil --[[typeArguments]]))
            end
            if ast.IsImportTypeNode(parentName) then
                parentName:AsImportTypeNode().isTypeOf = true
                -- mutably update, node is freshly manufactured anyhow
                return b.f:NewIndexedAccessTypeNode(parentName, b.f:NewLiteralTypeNode(b:newStringLiteral(memberName)))
            elseif ast.IsTypeReferenceNode(parentName) then
                return b.f:NewIndexedAccessTypeNode(b.f:NewTypeQueryNode(parentName:AsTypeReferenceNode().typeName, nil), b.f:NewLiteralTypeNode(b:newStringLiteral(memberName)))
            else
                error("Unhandled type node kind returned from `symbolToTypeNode`.", 0)
            end
        end
        if t.flags & TypeFlags.Union == 0 or not b:shouldExpandType(t, false --[[isAlias]]) then
            return b:symbolToTypeNode(t.symbol, SymbolFlags.Type, nil)
        end
        expandingEnum = true
    end
    if t.flags & TypeFlags.StringLiteral ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + #t:AsLiteralType().value + 2
        local lit = b:newStringLiteral(t:AsLiteralType().value)
        b.e:AddEmitFlags(lit, EmitFlags.EFNoAsciiEscaping)
        return b.f:NewLiteralTypeNode(lit)
    end
    if t.flags & TypeFlags.NumberLiteral ~= 0 then
        local value = t:AsLiteralType().value
        local text = jsnum.Number_String(value)
        b.ctx.approximateLength = b.ctx.approximateLength + #text
        if value < 0 then
            return b.f:NewLiteralTypeNode(b.f:NewPrefixUnaryExpression(Kind.MinusToken, b.f:NewNumericLiteral(string.sub(text, 2), ast.TokenFlags.None)))
        else
            return b.f:NewLiteralTypeNode(b.f:NewNumericLiteral(text, ast.TokenFlags.None))
        end
    end
    if t.flags & TypeFlags.BigIntLiteral ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + #checker.pseudoBigIntToString(checker.getBigIntLiteralValue(t)) + 1
        return b.f:NewLiteralTypeNode(b.f:NewBigIntLiteral(checker.pseudoBigIntToString(checker.getBigIntLiteralValue(t)) .. "n", ast.TokenFlags.None))
    end
    if t.flags & TypeFlags.BooleanLiteral ~= 0 then
        if t:AsLiteralType().value then
            b.ctx.approximateLength = b.ctx.approximateLength + 4
            return b.f:NewLiteralTypeNode(b.f:NewKeywordExpression(Kind.TrueKeyword))
        else
            b.ctx.approximateLength = b.ctx.approximateLength + 5
            return b.f:NewLiteralTypeNode(b.f:NewKeywordExpression(Kind.FalseKeyword))
        end
    end
    if t.flags & TypeFlags.UniqueESSymbol ~= 0 then
        if b.ctx.flags & Flags.AllowUniqueESSymbolType == 0 then
            if b.ch:IsValueSymbolAccessible(t.symbol, b.ctx.enclosingDeclaration) then
                b.ctx.approximateLength = b.ctx.approximateLength + 6
                return b:symbolToTypeNode(t.symbol, SymbolFlags.Value, nil)
            end
            b.ctx.tracker:ReportInaccessibleUniqueSymbolError()
        end
        b.ctx.approximateLength = b.ctx.approximateLength + 13
        return b.f:NewTypeOperatorNode(Kind.UniqueKeyword, b.f:NewKeywordTypeNode(Kind.SymbolKeyword))
    end
    if t.flags & TypeFlags.Void ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 4
        return b.f:NewKeywordTypeNode(Kind.VoidKeyword)
    end
    if t.flags & TypeFlags.Undefined ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 9
        return b.f:NewKeywordTypeNode(Kind.UndefinedKeyword)
    end
    if t.flags & TypeFlags.Null ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 4
        return b.f:NewLiteralTypeNode(b.f:NewKeywordExpression(Kind.NullKeyword))
    end
    if t.flags & TypeFlags.Never ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 5
        return b.f:NewKeywordTypeNode(Kind.NeverKeyword)
    end
    if t.flags & TypeFlags.ESSymbol ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        return b.f:NewKeywordTypeNode(Kind.SymbolKeyword)
    end
    if t.flags & TypeFlags.NonPrimitive ~= 0 then
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        return b.f:NewKeywordTypeNode(Kind.ObjectKeyword)
    end
    if checker.isThisTypeParameter(t) then
        if b.ctx.flags & Flags.InObjectTypeLiteral ~= 0 then
            if not b.ctx.encounteredError and b.ctx.flags & Flags.AllowThisInObjectLiteral == 0 then
                b.ctx.encounteredError = true
            end
            b.ctx.tracker:ReportInaccessibleThisError()
        end
        b.ctx.approximateLength = b.ctx.approximateLength + 4
        return b.f:NewThisTypeNode()
    end

    if inTypeAlias == 0 and t.alias ~= nil and (b.ctx.flags & Flags.UseAliasDefinedOutsideCurrentScope ~= 0 or b.ch:IsTypeSymbolAccessible(t.alias:Symbol(), b.ctx.enclosingDeclaration)) then
        -- If we should expand this type alias, skip the alias and fall through to expand the underlying type
        if not b:shouldExpandType(t, true --[[isAlias]]) then
            local sym = t.alias:Symbol()
            local typeArgumentNodes = b:mapToTypeNodes(t.alias:TypeArguments(), false --[[isBareList]])
            if checker.isReservedMemberName(sym.name) and sym.flags & SymbolFlags.Class == 0 then
                return b.f:NewTypeReferenceNode(b.f:NewIdentifier(""), typeArgumentNodes)
            end
            if typeArgumentNodes ~= nil and core.Len(typeArgumentNodes.nodes) == 1 and sym == b.ch.globalArrayType.symbol then
                return b.f:NewArrayTypeNode(typeArgumentNodes.nodes[1])
            end
            return b:symbolToTypeNode(sym, SymbolFlags.Type, typeArgumentNodes)
        end
        -- Expanding: increment depth and process the underlying type
        b.ctx.depth = b.ctx.depth + 1
        deferred.depth = true
    end

    local objectFlags = t.objectFlags

    if objectFlags & ObjectFlags.Reference ~= 0 then
        debug.Assert(t:Flags() & TypeFlags.Object ~= 0)
        -- When expanding, expand type references to their structural form
        if b:shouldExpandType(t, false --[[isAlias]]) then
            b.ctx.depth = b.ctx.depth + 1
            local result = b:createAnonymousTypeNodeEx(t, true --[[forceClassExpansion]], true --[[forceExpansion]])
            b.ctx.depth = b.ctx.depth - 1
            return result
        end
        if t:AsTypeReference().node ~= nil then
            return b:visitAndTransformType(t, typeReferenceToTypeNodeTransform)
        else
            return b:typeReferenceToTypeNode(t)
        end
    end
    if t.flags & TypeFlags.TypeParameter ~= 0 or objectFlags & ObjectFlags.ClassOrInterface ~= 0 then
        -- When expanding class or interface types, show their structural form
        if objectFlags & ObjectFlags.ClassOrInterface ~= 0 and b:shouldExpandType(t, false --[[isAlias]]) then
            b.ctx.depth = b.ctx.depth + 1
            local result = b:createAnonymousTypeNodeEx(t, true --[[forceClassExpansion]], true --[[forceExpansion]])
            b.ctx.depth = b.ctx.depth - 1
            return result
        end
        local isInferTypeParameter = false
        if t.flags & TypeFlags.TypeParameter ~= 0 then
            for _, p in ipairs(b.ctx.inferTypeParameters or {}) do
                if p == t then
                    isInferTypeParameter = true
                    break
                end
            end
        end
        if isInferTypeParameter then
            b.ctx.approximateLength = b.ctx.approximateLength + #ast.SymbolName(t.symbol) + 6
            local constraintNode
            local constraint = b.ch:getConstraintOfTypeParameter(t)
            if constraint ~= nil then
                -- If the infer type has a constraint that is not the same as the constraint
                -- we would have normally inferred based on b, we emit the constraint
                -- using `infer T extends ?`. We omit inferred constraints from type references
                -- as they may be elided.
                local inferredConstraint = b.ch:getInferredTypeParameterConstraint(t, true --[[omitTypeReferences]])
                if not (inferredConstraint ~= nil and b.ch:isTypeIdenticalTo(constraint, inferredConstraint)) then
                    b.ctx.approximateLength = b.ctx.approximateLength + 9
                    constraintNode = b:typeToTypeNode(constraint)
                end
            end
            return b.f:NewInferTypeNode(b:typeParameterToDeclarationWithConstraint(t, constraintNode))
        end
        if b.ctx.flags & Flags.GenerateNamesForShadowedTypeParams ~= 0 and t.flags & TypeFlags.TypeParameter ~= 0 then
            local name = b:typeParameterToName(t)
            b.ctx.approximateLength = b.ctx.approximateLength + #name.text
            return b.f:NewTypeReferenceNode(b:newIdentifier(name.text, t.symbol), nil --[[typeArguments]])
        end
        -- Ignore constraint/default when creating a usage (as opposed to declaration) of a type parameter.
        if t.symbol ~= nil then
            return b:symbolToTypeNode(t.symbol, SymbolFlags.Type, nil)
        end
        local name
        if (t == b.ch.markerSuperTypeForCheck or t == b.ch.markerSubTypeForCheck) and b.ch.varianceTypeParameter ~= nil and b.ch.varianceTypeParameter.symbol ~= nil then
            name = core.IfElse(t == b.ch.markerSubTypeForCheck, "sub-", "super-") .. ast.SymbolName(b.ch.varianceTypeParameter.symbol)
        else
            name = "?"
        end
        return b.f:NewTypeReferenceNode(b:newIdentifier(name, nil --[[symbol]]), nil --[[typeArguments]])
    end
    if t.flags & TypeFlags.Union ~= 0 and t:AsUnionType().origin ~= nil then
        t = t:AsUnionType().origin
    end
    if t.flags & (TypeFlags.Union | TypeFlags.Intersection) ~= 0 then
        local types
        if t.flags & TypeFlags.Union ~= 0 then
            types = b.ch:formatUnionTypes(t:AsUnionType().types, expandingEnum)
        else
            types = t:AsIntersectionType().types
        end
        if core.Len(types) == 1 then
            return b:typeToTypeNode(types[1])
        end
        local typeNodes = b:mapToTypeNodes(types, true --[[isBareList]])
        if typeNodes ~= nil and core.Len(typeNodes.nodes) > 0 then
            if t.flags & TypeFlags.Union ~= 0 then
                return b.f:NewUnionTypeNode(typeNodes)
            else
                return b.f:NewIntersectionTypeNode(typeNodes)
            end
        else
            if not b.ctx.encounteredError and b.ctx.flags & Flags.AllowEmptyUnionOrIntersection == 0 then
                b.ctx.encounteredError = true
            end
            return nil
            -- TODO: GH#18217
        end
    end
    if objectFlags & (ObjectFlags.Anonymous | ObjectFlags.Mapped) ~= 0 then
        debug.Assert(t:Flags() & TypeFlags.Object ~= 0)
        -- The type is an object literal type.
        return b:createAnonymousTypeNode(t)
    end
    if t.flags & TypeFlags.Index ~= 0 then
        local indexedType = t:Target()
        b.ctx.approximateLength = b.ctx.approximateLength + 6
        local indexTypeNode = b:typeToTypeNode(indexedType)
        return b.f:NewTypeOperatorNode(Kind.KeyOfKeyword, indexTypeNode)
    end
    if t.flags & TypeFlags.TemplateLiteral ~= 0 then
        local texts = t:AsTemplateLiteralType().texts
        local types = t:AsTemplateLiteralType().types
        local templateHead = b.f:NewTemplateHead(texts[1], "", ast.TokenFlags.None)
        b.e:AddEmitFlags(templateHead, EmitFlags.EFNoAsciiEscaping)
        local templateSpans = b.f:NewNodeList(core.MapIndex(types, function(tt, i)
            local res
            if i < #types - 1 then
                res = b.f:NewTemplateMiddle(texts[i + 2], "", ast.TokenFlags.None)
            else
                res = b.f:NewTemplateTail(texts[i + 2], "", ast.TokenFlags.None)
            end
            b.e:AddEmitFlags(res, EmitFlags.EFNoAsciiEscaping)
            return b.f:NewTemplateLiteralTypeSpan(b:typeToTypeNode(tt), res)
        end))
        b.ctx.approximateLength = b.ctx.approximateLength + 2
        return b.f:NewTemplateLiteralTypeNode(templateHead, templateSpans)
    end
    if t.flags & TypeFlags.StringMapping ~= 0 then
        local typeNode = b:typeToTypeNode(t:Target())
        return b:symbolToTypeNode(t:AsStringMappingType().symbol, SymbolFlags.Type, b.f:NewNodeList({ typeNode }))
    end
    if t.flags & TypeFlags.IndexedAccess ~= 0 then
        local objectTypeNode = b:typeToTypeNode(t:AsIndexedAccessType().objectType)
        local indexTypeNode = b:typeToTypeNode(t:AsIndexedAccessType().indexType)
        b.ctx.approximateLength = b.ctx.approximateLength + 2
        return b.f:NewIndexedAccessTypeNode(objectTypeNode, indexTypeNode)
    end
    if t.flags & TypeFlags.Conditional ~= 0 then
        return b:visitAndTransformType(t, conditionalTypeToTypeNodeTransform)
    end
    if t.flags & TypeFlags.Substitution ~= 0 then
        local typeNode = b:typeToTypeNode(t:AsSubstitutionType().baseType)
        if not b.ch:isNoInferType(t) then
            return typeNode
        end
        local noInferSymbol = b.ch:getGlobalTypeAliasSymbol("NoInfer", 1, false)
        if noInferSymbol ~= nil then
            return b:symbolToTypeNode(noInferSymbol, SymbolFlags.Type, b.f:NewNodeList({ typeNode }))
        else
            return typeNode
        end
    end

    error("Should be unreachable.", 0)
end

function NodeBuilderImpl:typeToTypeNode(t)
    -- Push type onto typeStack for expansion depth tracking
    local pushed = false
    if self.ctx.maxExpansionDepth >= 0 and t ~= nil then
        pushTypeStack(self.ctx, t)
        pushed = true
    end
    local deferred = { depth = false }
    local result = typeToTypeNodeBody(self, t, deferred)
    if deferred.depth then
        self.ctx.depth = self.ctx.depth - 1
    end
    if pushed then
        popTypeStack(self.ctx)
    end
    return result
end

function NodeBuilderImpl:newStringLiteral(text)
    return self:newStringLiteralEx(text, false --[[isSingleQuote]])
end

function NodeBuilderImpl:newStringLiteralEx(text, isSingleQuote)
    local flags = ast.TokenFlags.None
    if isSingleQuote or self.ctx.flags & Flags.UseSingleQuotesForStringLiteralType ~= 0 then
        flags = flags | ast.TokenFlags.SingleQuote
    end
    local node = self.f:NewStringLiteral(text, flags)
    return node
end

-- Direct serialization core functions for types, type aliases, and symbols

function checker.TypeAlias:ToTypeReferenceNode(b)
    return b.f:NewTypeReferenceNode(b:symbolToEntityNameNode(self:Symbol()), b:mapToTypeNodes(self:TypeArguments(), false --[[isBareList]]))
end

function NodeBuilderImpl:newIdentifier(text, symbol)
    local id = self.f:NewIdentifier(text)
    if symbol ~= nil then
        self.idToSymbol[id] = symbol
    end
    return id
end

function NodeBuilderImpl:createAccessExpression(node)
    if ast.IsQualifiedName(node) then
        return self.f:NewPropertyAccessExpression(self:createAccessExpression(node:AsQualifiedName().left), nil --[[questionDotToken]], self.f:DeepCloneNode(node:AsQualifiedName().right), NodeFlags.None)
    elseif ast.IsIdentifier(node) or ast.IsPropertyAccessExpression(node) or ast.IsExpressionWithTypeArguments(node) then
        return self.f:DeepCloneNode(node)
    else
        error("unexpected access node kind: " .. ast.Kind_String(node.kind), 0)
    end
end

function NodeBuilderImpl:createExpressionWithTypeArguments(expr, typeArguments)
    if typeArguments == nil or core.Len(typeArguments.nodes) == 0 then
        return expr
    end
    return self.f:NewExpressionWithTypeArguments(expr, typeArguments)
end

function NodeBuilderImpl:lookupInstantiatedTypeArgumentNodes(chain, index)
    if self:shouldWriteTypeParametersInQualifiedName(chain, index) then
        local symbol = chain[index + 1]
        local nextSymbol = chain[index + 2]
        if nextSymbol.checkFlags & CheckFlags.Instantiated == 0 then
            return nil
        end

        local targetSymbol = symbol
        if symbol.flags & SymbolFlags.Alias ~= 0 and not self.ch:canGetTypeParametersOfClassOrInterface(symbol) then
            targetSymbol = self.ch:resolveAlias(symbol)
        end

        if not self.ch:canGetTypeParametersOfClassOrInterface(targetSymbol) then
            return nil
        end

        local params = self:getTypeParametersOfClassOrInterface(targetSymbol)
        local targetMapper = self.ch.valueSymbolLinks:Get(nextSymbol).mapper
        if targetMapper ~= nil then
            params = core.Map(params, function(p) return targetMapper:Map(p) end)
        end
        return self:mapToTypeNodes(params, false --[[isBareList]])
    end
    return nil
end

function NodeBuilderImpl:lookupExpressionChainTypeArgumentNodes(chain, index)
    if self:shouldWriteTypeParametersInQualifiedName(chain, index) then
        local symbol = chain[index + 1]
        local symbolId = ast.GetSymbolId(symbol)
        if self.ctx.typeParameterSymbolList:Has(symbolId) then
            return nil
        end

        self.ctx.typeParameterSymbolList:Add(symbolId)
        local typeArgumentNodes = self:lookupInstantiatedTypeArgumentNodes(chain, index)
        if typeArgumentNodes ~= nil then
            return typeArgumentNodes
        end
        local typeParameterNodes = self:typeParametersToTypeParameterDeclarations(symbol)
        if core.Len(typeParameterNodes) > 0 then
            return self.f:NewNodeList(typeParameterNodes)
        end
    end
    return nil
end

function NodeBuilderImpl:shouldWriteTypeParametersInQualifiedName(chain, index)
    return self.ctx.flags & Flags.WriteTypeParametersInQualifiedName ~= 0 and index < #chain - 1
end

return checker
