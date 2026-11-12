local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")

local NodeBuilderImpl = checker.NodeBuilderImpl -- defined in nodebuilderimpl.lua (loads before this file)
local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local TokenFlags = ast.TokenFlags
local TypeFlags = checker.TypeFlags
local EmitFlags = printer.EmitFlags
local SymbolAccessibility = printer.SymbolAccessibility

function NodeBuilderImpl:reuseNode(node)
    if node == nil then
        return node
    end

    return self:tryReuseExistingNodeHelper(node)
end

function NodeBuilderImpl:tryJSTypeNodeToTypeNode(node)
    return self:reuseNode(node)
end

function NodeBuilderImpl:reuseName(node, isMethod)
    local res = self:reuseNode(node)
    if res == nil then
        return res
    end

    local text, ok = ast.TryGetTextOfPropertyName(res)
    if not ok then
        return res
    end

    local kind = checker.classifyPropertyName(text, ast.IsStringLiteral(res), isMethod)
    if ast.IsIdentifier(res) and kind == checker.propertyNameNodeKindIdentifier then
        return res
    end
    if ast.IsStringLiteral(res) and kind == checker.propertyNameNodeKindStringLiteral then
        return res
    end

    local renamed
    if kind == checker.propertyNameNodeKindIdentifier then
        renamed = self:newIdentifier(text, nil)
    elseif kind == checker.propertyNameNodeKindStringLiteral then
        renamed = self.f:NewStringLiteral(text, TokenFlags.None)
    else
        return res
    end
    self.e:SetOriginal(renamed, res)
    return self:setTextRange(renamed, res)
end

function NodeBuilderImpl:reuseTypeNode(node)
    if node == nil then
        return node
    end
    local r = self:reuseNode(node)
    if r ~= nil then
        -- After successful reuse during hover, probe the reused AST for expandable
        -- type references so canIncreaseExpansionDepth is set even though
        -- typeToTypeNode (and shouldExpandType) were never called.
        if self.ctx.maxExpansionDepth >= 0 and not self.ctx.canIncreaseExpansionDepth then
            self:walkNodeForExpandability(node)
        end
        return r
    end
    self.ctx.tracker:ReportInferenceFallback(node)
    local t = self:getTypeFromTypeNode(node, false)
    return self:typeToTypeNode(t)
end

-- walkNodeForExpandability walks a reused AST node tree, calling checkTypeExpandability
-- on each type reference, type predicate, or import type node.
-- Short-circuits once canIncreaseExpansionDepth is set.
function NodeBuilderImpl:walkNodeForExpandability(node)
    if self.ctx.canIncreaseExpansionDepth or node == nil then
        return
    end
    -- Check these explicitly so we look into type arguments wehther or not they are in the tree or not.
    if ast.IsTypeReferenceNode(node) or ast.IsExpressionWithTypeArguments(node) or ast.IsTypePredicateNode(node) or ast.IsImportTypeNode(node) then
        local t = self:getTypeFromTypeNode(node, false)
        if t ~= nil then
            self:checkTypeExpandability(t)
            if self.ctx.canIncreaseExpansionDepth then
                return
            end
        end
    end
    node:ForEachChild(function(child)
        self:walkNodeForExpandability(child)
        return self.ctx.canIncreaseExpansionDepth
    end)
end

local recoveryBoundary = checker.defineStruct("recoveryBoundary", nil, {
    hadError = false,
    oldEncounteredError = false,
    oldApproximateLength = 0,
})
-- fields: ctx, hadError, deferredReports, oldTracker, oldTrackedSymbols, trackedSymbols, oldEncounteredError, oldApproximateLength

function recoveryBoundary:markError(f)
    self.hadError = true
    if f ~= nil then
        self.deferredReports = core.Append(self.deferredReports, f)
    end
end

-- originalRecoveryScopeState is a Go value struct { trackedSymbolsTop, unreportedErrorsTop, hadError }.
checker.defineStruct("originalRecoveryScopeState", nil, {
    trackedSymbolsTop = 0,
    unreportedErrorsTop = 0,
    hadError = false,
})

function recoveryBoundary:startRecoveryScope()
    local trackedSymbolsTop = core.Len(self.ctx.trackedSymbols)
    local unreportedErrorsTop = core.Len(self.deferredReports)
    return checker.originalRecoveryScopeState_new({ trackedSymbolsTop = trackedSymbolsTop, unreportedErrorsTop = unreportedErrorsTop, hadError = self.hadError })
end

-- Go xs[0:n] for a possibly-nil slice (nil stays nil).
local function truncate(xs, n)
    if xs == nil then
        return nil
    end
    return core.Slice(xs, 0, n)
end

function recoveryBoundary:endRecoveryScope(state)
    self.hadError = state.hadError
    self.ctx.trackedSymbols = truncate(self.ctx.trackedSymbols, state.trackedSymbolsTop)
    self.deferredReports = truncate(self.deferredReports, state.unreportedErrorsTop)
end

-- wrappingTracker implements nodebuilder.SymbolTracker.
local wrappingTracker = checker.defineStruct("wrappingTracker", nil, nil)
-- fields: wrapped, bound

function wrappingTracker:PopErrorFallbackNode()
    self.wrapped:PopErrorFallbackNode()
end

function wrappingTracker:PushErrorFallbackNode(node)
    self.wrapped:PushErrorFallbackNode(node)
end

function wrappingTracker:ReportCyclicStructureError()
    local wrapped = self.wrapped
    self.bound:markError(function() wrapped:ReportCyclicStructureError() end)
end

function wrappingTracker:ReportInaccessibleThisError()
    local wrapped = self.wrapped
    self.bound:markError(function() wrapped:ReportInaccessibleThisError() end)
end

function wrappingTracker:ReportInaccessibleUniqueSymbolError()
    local wrapped = self.wrapped
    self.bound:markError(function() wrapped:ReportInaccessibleUniqueSymbolError() end)
end

function wrappingTracker:ReportInferenceFallback(node)
    self.wrapped:ReportInferenceFallback(node) -- Should this also be deferred?
end

function wrappingTracker:ReportLikelyUnsafeImportRequiredError(specifier, symbolName)
    self.bound:markError(function() self.wrapped:ReportLikelyUnsafeImportRequiredError(specifier, symbolName) end)
end

function wrappingTracker:ReportNonSerializableProperty(propertyName)
    self.bound:markError(function() self.wrapped:ReportNonSerializableProperty(propertyName) end)
end

function wrappingTracker:ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol)
    self.wrapped:ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol) -- Should this also be deferred?
end

function wrappingTracker:ReportPrivateInBaseOfClassExpression(propertyName)
    self.bound:markError(function() self.wrapped:ReportPrivateInBaseOfClassExpression(propertyName) end)
end

function wrappingTracker:ReportTruncationError()
    self.wrapped:ReportTruncationError() -- Should this also be deferred?
end

function wrappingTracker:TrackSymbol(symbol, enclosingDeclaration, meaning)
    self.bound.trackedSymbols = core.Append(self.bound.trackedSymbols, checker.TrackedSymbolArgs_new({
        symbol = symbol,
        enclosingDeclaration = enclosingDeclaration,
        meaning = meaning,
    }))
    return false
end

function checker.newWrappingTracker(inner, bound)
    return checker.wrappingTracker_new({
        wrapped = inner,
        bound = bound,
    })
end

function NodeBuilderImpl:createRecoveryBoundary()
    self.ch:checkNotCanceled()
    local bound = checker.recoveryBoundary_new({
        ctx = self.ctx,
        oldTracker = self.ctx.tracker,
        oldTrackedSymbols = self.ctx.trackedSymbols,
        oldEncounteredError = self.ctx.encounteredError,
        oldApproximateLength = self.ctx.approximateLength,
    })
    local newTracker = checker.NewSymbolTrackerImpl(self.ctx, checker.newWrappingTracker(self.ctx.tracker, bound))
    self.ctx.tracker = newTracker
    self.ctx.trackedSymbols = nil
    return bound
end

function NodeBuilderImpl:finalizeBoundary(bound)
    self.ctx.tracker = bound.oldTracker
    self.ctx.trackedSymbols = bound.oldTrackedSymbols
    self.ctx.encounteredError = bound.oldEncounteredError
    self.ctx.approximateLength = bound.oldApproximateLength

    for _, f in ipairs(bound.deferredReports or {}) do
        f()
    end
    if bound.hadError then
        return false
    end
    for _, a in ipairs(bound.trackedSymbols or {}) do
        self.ctx.tracker:TrackSymbol(a.symbol, a.enclosingDeclaration, a.meaning)
    end
    return true
end

function NodeBuilderImpl:tryReuseExistingNodeHelper(existing)
    local bound = self:createRecoveryBoundary()
    local v = checker.getExistingNodeTreeVisitor(self, bound) -- !!! TODO: Cache visitor and just reset bound+host builder? We try this for a *lot* of nodes.
    local transformed = v:VisitNode(existing)
    if not self:finalizeBoundary(bound) then
        return nil
    end
    self.ctx.approximateLength = self.ctx.approximateLength + (existing.loc:End() - existing.loc:Pos())
    return transformed
end

function NodeBuilderImpl:getModuleSpecifierOverride(parent, lit)
    if self.ctx.enclosingFile ~= ast.GetSourceFileOfNode(lit) then
        local mode = core.ModuleKind.ResolutionModeNone
        local importType = parent:AsImportTypeNode()
        if importType.attributes ~= nil then
            mode = self.ch:getResolutionModeOverride(importType.attributes:AsImportAttributes(), false)
        end
        local name = lit:Text()
        local originalName = name
        local nodeSymbol = self:tryGetResolvedSymbolFromTypeNode(parent)
        local meaning = SymbolFlags.Type
        if importType.isTypeOf then
            meaning = SymbolFlags.Value
        end
        local parentSymbol
        if nodeSymbol ~= nil and self.ch:IsSymbolAccessible(nodeSymbol, self.ctx.enclosingDeclaration, meaning, false).accessibility == SymbolAccessibility.Accessible then
            parentSymbol = self:lookupSymbolChain(nodeSymbol, meaning, true)[1]
        end
        if parentSymbol ~= nil and checker.IsExternalModuleSymbol(parentSymbol) then
            name = self:getSpecifierForModuleSymbol(parentSymbol, mode)
        else
            local targetFile = self.ch:getExternalModuleFileFromDeclaration(parent)
            if targetFile ~= nil then
                name = self:getSpecifierForModuleSymbol(targetFile.symbol, mode)
            end
        end
        if #name > 0 and string.find(name, "/node_modules/", 1, true) ~= nil then
            self.ctx.encounteredError = true
            self.ctx.tracker:ReportLikelyUnsafeImportRequiredError(name, "")
        end
        if name ~= originalName then
            return name
        end
    end
    return ""
end

function NodeBuilderImpl:rewriteModuleSpecifier(parent, lit)
    local newName = self:getModuleSpecifierOverride(parent, lit)
    if #newName == 0 then
        return lit
    end
    local res = self.f:NewStringLiteral(newName, TokenFlags.None)
    self.e:SetOriginal(res, lit)
    return res
end

function NodeBuilderImpl:getEnclosingDeclarationIgnoringFakeScope()
    local enc = self.ctx.enclosingDeclaration
    while enc ~= nil and self.links:Get(enc).fakeScopeForSignatureDeclaration ~= nil do
        enc = enc.parent
    end
    return enc
end

function checker.getExistingNodeTreeVisitor(b, bound)
    -- TODO: wrap all these closures into methods on an object so we can guarantee we reuse the same memory on each invocation by reusing/resetting the object
    -- instead of re-closing-over all of these each time we need a visitor. In theory the compiler could handle this, but in practice closure inlining hasn't been reliable
    local visitor
    -- note: also handles renaming type parameters renamed within the current context
    local function attachSymbolToLeftmostIdentifier(leftmost, node, sym)
        local vis
        local function visitorFunc(n)
            if n == leftmost then
                local type_
                local name
                if sym ~= nil then
                    type_ = b.ch:getDeclaredTypeOfSymbol(sym)
                    if sym.flags & SymbolFlags.TypeParameter ~= 0 then
                        name = b:typeParameterToName(type_)
                    end
                end
                if name == nil then
                    name = b:newIdentifier(n:Text(), sym)
                end
                name = b:setTextRange(name, n)
                b.e:AddEmitFlags(name, EmitFlags.EFNoAsciiEscaping)
                return name
            end
            return b:setTextRange(n:VisitEachChild(vis), n)
        end
        vis = ast.NewNodeVisitor(visitorFunc, b.f, {})
        return visitorFunc(node)
    end
    -- returns introducesError, node, symbol
    local function trackExistingEntityName(node, overrideEnclosing)
        local enclosingDeclaration = b.ctx.enclosingDeclaration
        if overrideEnclosing ~= nil then
            enclosingDeclaration = overrideEnclosing
        end
        local introducesError = false
        local leftmost = ast.GetFirstIdentifier(node)
        if ast.IsInJSFile(node) and (ast.IsExportsIdentifier(leftmost) or ast.IsModuleExportsAccessExpression(leftmost.parent) or (ast.IsQualifiedName(leftmost.parent) and ast.IsModuleIdentifier(leftmost.parent:AsQualifiedName().left) and ast.IsExportsIdentifier(leftmost.parent:AsQualifiedName().right))) then
            introducesError = true
            return introducesError, b:setTextRange(b.f:DeepCloneNode(node), node), nil
        end
        local meaning = checker.getMeaningOfEntityNameReference(node)
        local sym
        if ast.IsThisIdentifier(leftmost) then
            -- `this` isn't a bindable identifier - skip resolution, find a relevant `this` symbol directly and avoid exhaustive scope traversal
            sym = b.ch:getSymbolOfDeclaration(b.ch:getThisContainer(leftmost, false, false))
            if b.ch:IsSymbolAccessible(sym, leftmost, meaning, false).accessibility ~= SymbolAccessibility.Accessible then
                introducesError = true
                b.ctx.tracker:ReportInaccessibleThisError()
            end
            return introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), nil
        end
        sym = b.ch:resolveEntityName(leftmost, meaning, true, true, nil)
        if b.ctx.enclosingDeclaration ~= nil and not (sym ~= nil and sym.flags & SymbolFlags.TypeParameter ~= 0) then
            sym = b.ch:getExportSymbolOfValueSymbolIfExported(sym)
            -- Some declarations may be transplanted to a new location.
            -- When this happens we need to make sure that the name has the same meaning at both locations
            -- We also check for the unknownSymbol because when we create a fake scope some parameters may actually not be usable
            -- either because they are the expanded rest parameter,
            -- or because they are the newly added parameters from the tuple, which might have different meanings in the original context
            local symAtLocation = b.ch:resolveEntityName(leftmost, meaning, true, true, b.ctx.enclosingDeclaration)
            if
                -- Check for unusable parameters symbols
                symAtLocation == b.ch.unknownSymbol or
                -- If the symbol is not found, but was not found in the original scope either we probably have an error, don't reuse the node
                (symAtLocation == nil and sym ~= nil) or
                -- If the symbol is found both in declaration scope and in current scope then it should point to the same reference
                (symAtLocation ~= nil and sym ~= nil and b.ch:getSymbolIfSameReference(b.ch:getExportSymbolOfValueSymbolIfExported(symAtLocation), sym) == nil) then
                -- In isolated declaration we will not do rest parameter expansion so there is no need to report on these.
                if symAtLocation ~= b.ch.unknownSymbol then
                    b.ctx.tracker:ReportInferenceFallback(node)
                end
                introducesError = true
                return introducesError, b:setTextRange(b.f:DeepCloneNode(node), node), sym
            else
                sym = symAtLocation
            end
        end

        if sym ~= nil then
            -- If a parameter is resolvable in the current context it is also visible, so no need to go to symbol accesibility
            if sym.flags & SymbolFlags.FunctionScopedVariable ~= 0 and sym.valueDeclaration ~= nil then
                if ast.IsPartOfParameterDeclaration(sym.valueDeclaration) or ast.IsJSDocParameterTag(sym.valueDeclaration) then
                    return introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), nil
                end
            end
            if sym.flags & SymbolFlags.TypeParameter == 0 --[[ Type parameters are visible in the current context if they are are resolvable ]] and not ast.IsDeclarationName(node) and
                b.ch:IsSymbolAccessible(sym, enclosingDeclaration, meaning, false).accessibility ~= SymbolAccessibility.Accessible then
                b.ctx.tracker:ReportInferenceFallback(node)
                introducesError = true
            else
                b.ctx.tracker:TrackSymbol(sym, enclosingDeclaration, meaning)
            end
            return introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), nil
        end
        return introducesError, b:setTextRange(b.f:DeepCloneNode(node), node), nil
    end
    local tryVisitSimpleTypeNode
    local function tryVisitIndexedAccess(node)
        local resultObjectType = tryVisitSimpleTypeNode(node:AsIndexedAccessTypeNode().objectType)
        if resultObjectType == nil then
            return nil
        end
        return b:setTextRange(b.f:UpdateIndexedAccessTypeNode(node:AsIndexedAccessTypeNode(), resultObjectType, visitor:VisitNode(node:AsIndexedAccessTypeNode().indexType)), node)
    end
    local function tryVisitKeyOf(node)
        local to = node:AsTypeOperatorNode()
        local t = tryVisitSimpleTypeNode(to.type)
        if t == nil then
            return nil
        end
        return b:setTextRange(b.f:UpdateTypeOperatorNode(to, to.operator, t), node)
    end
    local function tryVisitTypeQuery(node)
        local tq = node:AsTypeQueryNode()
        local introducesError, exprName = trackExistingEntityName(tq.exprName, nil)
        if not introducesError then
            return b:setTextRange(b.f:UpdateTypeQueryNode(
                tq,
                exprName,
                visitor:VisitNodes(tq.typeArguments)
            ), node)
        end

        local serializedName = b:serializeTypeName(tq.exprName, true, visitor:VisitNodes(tq.typeArguments))
        if serializedName ~= nil then
            return b:setTextRange(serializedName, tq.exprName)
        end
        return nil
    end
    local function tryVisitTypeReference(node)
        if ast.IsConstTypeReference(node) then
            return nil
        end
        local s = b:tryGetResolvedSymbolFromTypeNode(node)
        if s == nil then
            return nil -- ???
        end
        if s.flags & SymbolFlags.TypeParameter ~= 0 then
            local declaredType = b.ch:getDeclaredTypeOfSymbol(s)
            if b.ctx.mapper ~= nil and b.ctx.mapper:Map(declaredType) ~= declaredType then
                return nil -- refers to type parameter remapped by context (TODO improvement: just return the remapped param name?)
            end
        end
        if not b:canReuseExistingJSTypeNode(node, b:getTypeFromTypeNode(node, false)) then
            -- fallback to serialization for jsdoc types that have insufficient or incomplete type args, or are remapped by the checker in only jsdoc contexts
            -- TODO: remappings like `promise` -> `Promise<any>` are static, we *could* statically remap the nodes, too. But that only matters for `isolatedDeclarations`
            -- in JS, should we enable that.
            return nil
        end
        local tr = node:AsTypeReferenceNode()
        local introducesError, newName = trackExistingEntityName(tr.typeName, nil)
        if not introducesError then
            local typeArguments = visitor:VisitNodes(tr.typeArguments)
            return b:setTextRange(b.f:UpdateTypeReferenceNode(
                tr,
                newName,
                typeArguments
            ), node)
        else
            local serializedName = b:serializeTypeName(tr.typeName, false, visitor:VisitNodes(tr.typeArguments))
            if serializedName ~= nil then
                return b:setTextRange(serializedName, tr.typeName)
            end
            return nil
        end
    end
    tryVisitSimpleTypeNode = function(node)
        local innerNode = ast.SkipParentheses(node)
        local k = innerNode.kind
        if k == Kind.TypeReference then
            return tryVisitTypeReference(innerNode)
        elseif k == Kind.TypeQuery then
            return tryVisitTypeQuery(innerNode)
        elseif k == Kind.IndexedAccessType then
            return tryVisitIndexedAccess(innerNode)
        elseif k == Kind.TypeOperator then
            if innerNode:AsTypeOperatorNode().operator == Kind.KeyOfKeyword then
                return tryVisitKeyOf(innerNode)
            end
        end
        return visitor:VisitNode(node)
    end
    local function visitExistingNodeTreeSymbolsWorker(node)
        local factory = b.f
        -- !!! TODO: the reparser *should* make all the jsdoc remapping logic here redundant,
        -- assuming we only ever try to preserve reparsed nodes and never walk back to the jsdoc "originals"
        -- accidentally.
        -- Still, what can be ported of the logic is here, just in case.
        -- Begin JSDoc handling
        if node.kind == Kind.JSDocTypeExpression then
            -- Unwrap JSDocTypeExpressions
            return visitor:VisitNode(node:AsJSDocTypeExpression().type)
        end
        -- !!! TODO: We don't _actually_ support jsdoc namepath types, emit `any` instead; verify we handle as gracefully as strada
        if node.kind == Kind.JSDocAllType --[[ || node.Kind == ast.JSDocNamepathType ]] then
            return factory:NewKeywordTypeNode(Kind.AnyKeyword)
        end
        -- !!! TODO: verify JSDocUnknwonType is hopefully just parsed into `unknown` upfront; the kind no longer exists
        -- if node.Kind == ast.KindJSDocUnknownType {
        -- 	return factory.NewKeywordTypeNode(ast.KindUnknownKeyword)
        -- }
        if node.kind == Kind.JSDocNullableType then
            local unionMembers = {
                visitor:VisitNode(node:AsJSDocNullableType().type),
                factory:NewLiteralTypeNode(factory:NewKeywordExpression(Kind.NullKeyword)),
            }
            return factory:NewUnionTypeNode(factory:NewNodeList(unionMembers))
        end
        if node.kind == Kind.JSDocOptionalType then
            local unionMembers = {
                visitor:VisitNode(node:AsJSDocOptionalType().type),
                factory:NewKeywordTypeNode(Kind.UndefinedKeyword),
            }
            return factory:NewUnionTypeNode(factory:NewNodeList(unionMembers))
        end
        if node.kind == Kind.JSDocNonNullableType then
            -- Unwrap
            return visitor:VisitNode(node:AsJSDocNonNullableType().type)
        end
        if node.kind == Kind.JSDocVariadicType then -- !!! TODO: verify this matches how jsdoc variadics are actually handled now?
            return factory:NewArrayTypeNode(visitor:VisitNode(node:AsJSDocVariadicType().type))
        end
        if node.kind == Kind.JSDocTypeLiteral then
            local members = {}
            for _, t in ipairs(node:AsJSDocTypeLiteral().jsDocPropertyTags or {}) do
                if t.kind ~= Kind.JSDocPropertyTag and t.kind ~= Kind.JSDocParameterTag then
                    goto continue
                end
                do
                    local n = t:Name()
                    local targetName
                    if ast.IsIdentifier(n) then
                        targetName = n
                    else
                        targetName = n:AsQualifiedName().right -- !!! TODO: without typesystem backup, doing this cast unguarded seems really suspect, even though it is what strada does
                    end
                    local name = visitor:VisitNode(targetName)
                    local shouldBeOptional = t:AsJSDocParameterOrPropertyTag().isBracketed or (t:TypeExpression() ~= nil and t:TypeExpression().kind == Kind.JSDocOptionalType)
                    local question
                    if shouldBeOptional then
                        question = factory:NewToken(Kind.QuestionToken)
                    end
                    local ty = visitor:VisitNode(t:TypeExpression()) -- !!! TODO: alternate lookup locations for the type? serialize on demand if it doesn't serialze? strada does something funky here.

                    members[#members + 1] = factory:NewPropertySignatureDeclaration(nil, name, question, ty, nil)
                end
                ::continue::
            end
            return factory:NewTypeLiteralNode(factory:NewNodeList(members))
        end
        -- if (ast.IsExpressionWithTypeArguments(node) || ast.IsTypeReferenceNode(node)) && ast.IsJSDocIndexSignature(node) { /// !!! TODO: JSDocIndexSignature handling hasn't been ported - readd if it's readded
        -- 	...
        -- }
        -- if node.Kind == ast.KindJSDocFunctionType {} // !!! no longer exists
        -- End JSDoc handling

        if ast.IsTypeReferenceNode(node) and ast.IsIdentifier(node:AsTypeReferenceNode().typeName) and node:AsTypeReferenceNode().typeName:AsIdentifier().text == "" then
            local replacement = factory:NewKeywordTypeNode(Kind.AnyKeyword)
            b.e:SetOriginal(replacement, node)
            return replacement
        end
        if ast.IsThisTypeNode(node) then
            -- TODO: strada never marks `this` type nodes as an error - it calls `canReuseTypeNode` on it, but that function always returns `true` for `this`
            -- type nodes, which in turn fails to verify that the `this` context is the same between the source and target locations. The conservative thing is to
            -- _never_ copy a `this`. We could improve this, but strada is *definitely* wrong and overbroad here. (note that we're inling uses of `canReuseTypeNode`
            -- in corsa because of the unfurled host structure meaning we don't need to defer to a host object for functionality it needs)
            -- bound.markError(nil) // conservative approach
            return node
        end
        if ast.IsTypeParameterDeclaration(node) then
            local _, newName = trackExistingEntityName(node:Name(), nil)
            local tp = node:AsTypeParameterDeclaration()
            return factory:UpdateTypeParameterDeclaration(
                tp,
                visitor:VisitModifiers(node:Modifiers()),
                newName,
                visitor:VisitNode(tp.constraint),
                visitor:VisitNode(tp.expression),
                visitor:VisitNode(tp.defaultType)
            )
        end
        if ast.IsIndexedAccessTypeNode(node) then
            local result = tryVisitIndexedAccess(node)
            if result ~= nil then
                return result
            end
            bound:markError(nil)
            return node
        end
        if ast.IsTypeReferenceNode(node) then
            local result = tryVisitTypeReference(node)
            if result ~= nil then
                return result
            end
            bound:markError(nil)
            return node
        end
        if ast.IsTypeQueryNode(node) then
            local result = tryVisitTypeQuery(node)
            if result ~= nil then
                return result
            end
            bound:markError(nil)
            return node
        end
        if ast.IsTypeOperatorNode(node) then
            local to = node:AsTypeOperatorNode()
            if to.operator == Kind.UniqueKeyword and to.type.kind == Kind.SymbolKeyword then
                local nonFakeEnclosing = b:getEnclosingDeclarationIgnoringFakeScope()
                local sameScope = ast.FindAncestor(node, function(a)
                    return a == nonFakeEnclosing
                end)
                if sameScope == nil then
                    bound:markError(nil)
                    return node
                end
            elseif to.operator == Kind.KeyOfKeyword then
                local result = tryVisitKeyOf(node)
                if result ~= nil then
                    return result
                end
                bound:markError(nil)
                return node
            end
        end
        if ast.IsLiteralImportTypeNode(node) then
            local it = node:AsImportTypeNode()
            -- assert keyword in imported attributes is deprecated, so we don't reuse types that contain it
            -- Ex: import("pkg", { assert: {} }
            if it.attributes ~= nil and it.attributes:AsImportAttributes().token == Kind.AssertKeyword then
                bound:markError(nil)
                return node
            end
            local t = b:getTypeFromTypeNode(node, true)
            if t == nil then
                bound:markError(nil)
                return node
            end
            if ast.IsInJSFile(node) then
                -- !!! TODO: invalidate node reuse if js fallback logic used in type param list/typeof lookup (but isn't this logic gone?)
                -- s := b.ch.symbolNodeLinks.Get(node).resolvedSymbol
            end
            local originalSpec = it.argument:AsLiteralTypeNode().literal
            local specifier = b:rewriteModuleSpecifier(node, originalSpec)
            if originalSpec == specifier then
                specifier = visitor:VisitNode(specifier) -- visit node if not replaced
            end
            local arg = it.argument
            if specifier ~= originalSpec then
                arg = factory:NewLiteralTypeNode(specifier)
            end
            return factory:UpdateImportTypeNode(
                it,
                it.isTypeOf,
                arg,
                visitor:VisitNode(it.attributes),
                visitor:VisitNode(it.qualifier),
                visitor:VisitNodes(it.typeArguments)
            )
        end
        if node:Name() ~= nil and node:Name().kind == Kind.ComputedPropertyName and not b.ch:hasLateBindableName(node) then
            if not ast.HasDynamicName(node) then
                -- !!! TODO: This matches strada, but rather than recursing, this should probably fall down to later cases.
                -- Take a `["field"]` property declaration - it still needs a `: any` appended to it
                return visitor:VisitEachChild(node)
            end
            -- !!! TODO: this condition matches strada, but it just seems wrong? Or at the very least extraordinarily approximate, and doesn't flag a builder error...
            local shouldRemoveDeclaration = not ((b.ctx.internalFlags & nodebuilder.InternalFlags.AllowUnresolvedNames ~= 0) and ast.IsEntityNameExpression(node:Name():AsComputedPropertyName().expression) and (b.ch:checkComputedPropertyName(node:Name()).flags & TypeFlags.Any ~= 0))
            if shouldRemoveDeclaration then
                return nil
            end
        end
        if (ast.IsFunctionLike(node) and node:Type() == nil) or (ast.IsPropertyDeclaration(node) and node:Type() == nil and node:Initializer() == nil) or (ast.IsPropertySignatureDeclaration(node) and node:Type() == nil and node:Initializer() == nil) or (ast.IsParameterDeclaration(node) and node:Type() == nil and node:Initializer() == nil) then
            local visited = visitor:VisitEachChild(node)
            if visited == node then
                visited = b:setTextRange(node:Clone(factory), node)
            end
            node = visited
            local newType = factory:NewKeywordTypeNode(Kind.AnyKeyword)
            local k = node.kind
            if k == Kind.PropertyDeclaration then
                return factory:UpdatePropertyDeclaration(
                    node:AsPropertyDeclaration(),
                    node:Modifiers(),
                    node:Name(),
                    node:PostfixToken(),
                    newType,
                    nil
                )
            elseif k == Kind.PropertySignature then
                return factory:UpdatePropertySignatureDeclaration(
                    node:AsPropertySignatureDeclaration(),
                    node:Modifiers(),
                    node:Name(),
                    node:PostfixToken(),
                    newType,
                    nil
                )
            elseif k == Kind.Parameter then
                return factory:UpdateParameterDeclaration(
                    node:AsParameterDeclaration(),
                    nil,
                    node:AsParameterDeclaration().dotDotDotToken,
                    node:Name(),
                    node:AsParameterDeclaration().questionToken,
                    newType,
                    nil
                )
            elseif k == Kind.MethodSignature then
                local ms = node:AsMethodSignatureDeclaration()
                return factory:UpdateMethodSignatureDeclaration(
                    ms,
                    node:Modifiers(),
                    node:Name(),
                    ms.postfixToken,
                    ms.typeParameters,
                    ms.parameters,
                    newType
                )
            elseif k == Kind.CallSignature then
                local cs = node:AsCallSignatureDeclaration()
                return factory:UpdateCallSignatureDeclaration(
                    cs,
                    cs.typeParameters,
                    cs.parameters,
                    newType
                )
            elseif k == Kind.JSDocSignature then
                local js = node:AsJSDocSignature()
                return factory:UpdateJSDocSignature(
                    js,
                    js.typeParameters,
                    js.parameters,
                    newType
                )
            elseif k == Kind.ConstructSignature then
                local cs = node:AsConstructSignatureDeclaration()
                return factory:UpdateConstructSignatureDeclaration(
                    cs,
                    cs.typeParameters,
                    cs.parameters,
                    newType
                )
            elseif k == Kind.IndexSignature then
                return factory:UpdateIndexSignatureDeclaration(
                    node:AsIndexSignatureDeclaration(),
                    node:Modifiers(),
                    node:AsIndexSignatureDeclaration().parameters,
                    newType
                )
            elseif k == Kind.FunctionType then
                local ft = node:AsFunctionTypeNode()
                return factory:UpdateFunctionTypeNode(
                    ft,
                    ft.typeParameters,
                    ft.parameters,
                    newType
                )
            elseif k == Kind.ConstructorType then
                local ct = node:AsConstructorTypeNode()
                return factory:UpdateConstructorTypeNode(
                    ct,
                    node:Modifiers(),
                    ct.typeParameters,
                    ct.parameters,
                    newType
                )
            end
        end
        if ast.IsComputedPropertyName(node) and ast.IsEntityNameExpression(node:AsComputedPropertyName().expression) then
            local introducesError, result = trackExistingEntityName(node:AsComputedPropertyName().expression, nil)
            if not introducesError then
                return factory:UpdateComputedPropertyName(node:AsComputedPropertyName(), result)
            else
                -- !!! TODO: rewriting computed names based on evaluator/typecheck results?
                -- strada's behavior seems hard to justify vs marking an error and moving on
                bound:markError(nil)
                return visitor:VisitEachChild(node)
            end
        end
        if ast.IsTypePredicateNode(node) then
            local tp = node:AsTypePredicateNode()
            local parameterName
            if ast.IsIdentifier(tp.parameterName) then
                local introducesError, result = trackExistingEntityName(tp.parameterName, nil)
                -- Should not usually happen the only case is when a type predicate comes from a JSDoc type annotation with it's own parameter symbol definition.
                -- /** @type {(v: unknown) => v is undefined} */
                -- const isUndef = v => v === undefined;
                if introducesError then
                    bound:markError(nil)
                end
                parameterName = result
            else
                parameterName = tp.parameterName:Clone(factory)
            end
            return factory:UpdateTypePredicateNode(
                tp,
                visitor:VisitNode(tp.assertsModifier),
                parameterName,
                visitor:VisitNode(tp.type)
            )
        end
        if ast.IsConditionalTypeNode(node) then
            local ct = node:AsConditionalTypeNode()
            local checkType = visitor:VisitNode(ct.checkType)
            local dispose = b:enterNewScope(node, nil, b.ch:getInferTypeParameters(node), nil, nil)
            local extendsType = visitor:VisitNode(ct.extendsType)
            local trueType = visitor:VisitNode(ct.trueType)
            dispose()
            local falseType = visitor:VisitNode(ct.falseType)
            return factory:UpdateConditionalTypeNode(
                ct,
                checkType,
                extendsType,
                trueType,
                falseType
            )
        end

        -- style applications
        if ast.IsTupleTypeNode(node) or (b.ctx.flags & nodebuilder.Flags.MultilineObjectLiterals == 0 and ast.IsTypeLiteralNode(node)) or ast.IsMappedTypeNode(node) then
            -- make tuples/types/mappedtypes single line
            local res = visitor:VisitEachChild(node)
            if res == node then
                res = res:Clone(factory)
                res = b:setTextRange(res, node)
            end
            b.e:AddEmitFlags(res, EmitFlags.EFSingleLine)
            return res
        end

        if ast.IsStringLiteralLike(node) then
            -- Preserve the original characters of the literal (e.g. emojis) in declaration emit
            -- rather than escaping them as ASCII Unicode escapes. Mirrors TypeScript's behavior
            -- for synthesized string literal types in the node builder (checker.ts:6853).
            local c = node:Clone(b.f)
            if ast.IsStringLiteral(node) and b.ctx.flags & nodebuilder.Flags.UseSingleQuotesForStringLiteralType ~= 0 and node:AsStringLiteral().tokenFlags & TokenFlags.SingleQuote == 0 then
                -- set single quote on string literals
                local sl = c:AsStringLiteral()
                sl.tokenFlags = sl.tokenFlags ~ TokenFlags.SingleQuote
            end
            b.e:AddEmitFlags(c, EmitFlags.EFNoAsciiEscaping)
            return c
        end

        return visitor:VisitEachChild(node)
    end
    local nonLocalNode = true
    visitor = ast.NewNodeVisitor(function(node)
        -- If there was an error in a sibling node bail early, the result will be discarded anyway
        if bound.hadError then
            return node
        end
        local recover_ = bound:startRecoveryScope()
        local introducesNewScope = ast.IsFunctionLike(node) or ast.IsMappedTypeNode(node)
        local exit
        if introducesNewScope then
            local params
            local typeParams
            if ast.IsFunctionLike(node) then
                local sig = b.ch:getSignatureFromDeclaration(node)
                params = sig.parameters
                typeParams = sig.typeParameters
            elseif ast.IsConditionalTypeNode(node) then -- !!! TODO: impossible in combination with the scope start check???
                typeParams = b.ch:getInferTypeParameters(node)
            elseif ast.IsMappedTypeNode(node) then
                typeParams = { b.ch:getDeclaredTypeOfTypeParameter(b.ch:getSymbolOfDeclaration(node:AsMappedTypeNode().typeParameter)) }
            end
            exit = b:enterNewScope(node, params, typeParams, nil, nil)
        end
        local result = visitExistingNodeTreeSymbolsWorker(node)
        if exit ~= nil then
            exit()
        end

        if result == node and not ast.NodeIsSynthesized(node) then
            result = b.f:DeepCloneNode(node) -- always clone a new node
        end

        -- We want to clone the subtree, so when we mark it up with __pos and __end in quickfixes,
        --  we don't get odd behavior because of reused nodes. We also need to clone to _remove_
        --  the position information if the node comes from a different file than the one the node builder
        --  is set to build for (even though we are reusing the node structure, the position information
        --  would make the printer print invalid spans for literals and identifiers, and the formatter would
        --  choke on the mismatched positonal spans between a parent and an injected child from another file).
        result = b:setTextRange(result, node)

        if bound.hadError then
            if ast.IsTypeNode(node) and not ast.IsTypePredicateNode(node) then
                bound:endRecoveryScope(recover_)
                -- TODO: this fallback matches strada behavior, but it lacks any verification that the type from `node` actually matches
                -- the type we'd expect at this traversal position within the parent type.
                local t = b:getTypeFromTypeNode(node, false)
                return b:typeToTypeNode(t)
            end
            return b:setTextRange(node:Clone(b.f), node)
        end

        return result
    end, b.f, {
        visitNodes = function(nodes, v)
            local res = v:VisitNodes(nodes)
            if nonLocalNode and res ~= nil then
                -- Remove position data from node lists originating in other files
                if res == nodes then
                    res = nodes:Clone(b.f)
                end
                res.loc = core.NewTextRange(-1, -1)
            end
            return res
        end,
        visitNode = function(node, v)
            -- Capture if the current node is in the current file so node lists knoww if they can keep positions or not
            local oldNonLocalNode = nonLocalNode
            nonLocalNode = b.ctx.enclosingFile == nil or b.ctx.enclosingFile ~= ast.GetSourceFileOfNode(b.e:MostOriginal(node))
            local res = v:VisitNode(node)
            nonLocalNode = oldNonLocalNode
            return res
        end,
    })
    return visitor
end

return checker
