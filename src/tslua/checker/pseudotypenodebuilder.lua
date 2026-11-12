local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local pseudochecker = require("tslua.pseudochecker")

local NodeBuilderImpl = checker.NodeBuilderImpl
local Kind = ast.Kind
local PseudoTypeKind = pseudochecker.PseudoTypeKind
local PseudoObjectElementKind = pseudochecker.PseudoObjectElementKind
local TypeFlags = checker.TypeFlags
local TypeFacts = checker.TypeFacts
local Ternary = checker.Ternary
local ElementFlags = checker.ElementFlags
local ContextFlags = checker.ContextFlags
local TypePredicateKind = checker.TypePredicateKind
local EF = printer.EmitFlags

-- pseudoTypeToNodeWithCheckerFallback is like pseudoTypeToNode but when the top-level pseudo type
-- is PseudoTypeInferred, it reports any error nodes and then serializes from the checker's type.
-- This avoids incorrect type output when PseudoTypeInferred would derive the type from the
-- original declaration expression in an instantiated context.
function NodeBuilderImpl:pseudoTypeToNodeWithCheckerFallback(t, checkerType)
    if t.kind == PseudoTypeKind.Inferred then
        if not self.ctx.suppressReportInferenceFallback then
            local errorNodes = t:AsPseudoTypeInferred().errorNodes
            if core.Len(errorNodes) > 0 then
                for _, n in ipairs(errorNodes) do
                    self.ctx.tracker:ReportInferenceFallback(n)
                end
            else
                self.ctx.tracker:ReportInferenceFallback(t:AsPseudoTypeInferred().expression)
            end
        end
        local oldSuppress = self.ctx.suppressReportInferenceFallback
        self.ctx.suppressReportInferenceFallback = true
        local result = self:typeToTypeNode(checkerType)
        self.ctx.suppressReportInferenceFallback = oldSuppress
        return result
    elseif t.kind == PseudoTypeKind.Direct then
        local existing = t:AsPseudoTypeDirect().typeNode
        if not self:canReuseExistingJSTypeNode(existing, checkerType) then
            if not self.ctx.suppressReportInferenceFallback then
                self.ctx.tracker:ReportInferenceFallback(existing)
            end
            local oldSuppress = self.ctx.suppressReportInferenceFallback
            self.ctx.suppressReportInferenceFallback = true
            local result = self:typeToTypeNode(checkerType)
            self.ctx.suppressReportInferenceFallback = oldSuppress
            return result
        end
    end
    return self:pseudoTypeToNode(t)
end

local function reuseTypeParameters(b, typeParameters)
    local typeParams
    if core.Len(typeParameters) > 0 then
        local res = {}
        for _, tp in ipairs(typeParameters) do
            res[#res + 1] = b:reuseNode(tp)
        end
        typeParams = b.f:NewNodeList(res)
    end
    return typeParams
end

-- Maps a pseudochecker's pseudotypes into ast nodes and reports any inference fallback errors the pseudotype structure implies
function NodeBuilderImpl:pseudoTypeToNode(t)
    debug.Assert(t ~= nil, "Attempted to serialize nil pseudotype")
    local k = t.kind
    if k == PseudoTypeKind.Direct then
        return self:reuseTypeNode(t:AsPseudoTypeDirect().typeNode)
    elseif k == PseudoTypeKind.Inferred then
        local inferred = t:AsPseudoTypeInferred()
        local node = inferred.expression
        local errorNodes = inferred.errorNodes
        if core.Len(errorNodes) > 0 then
            for _, n in ipairs(errorNodes) do
                self.ctx.tracker:ReportInferenceFallback(n)
            end
        elseif ast.IsEntityNameExpression(node) and ast.IsDeclaration(node.parent) then
            self.ctx.tracker:ReportInferenceFallback(node.parent)
        else
            self.ctx.tracker:ReportInferenceFallback(node)
        end
        if inferred.isSignatureReturn then
            return self:serializeReturnTypeForSignature(self.ch:getSignatureFromDeclaration(node), false)
        end
        -- use symbol type from parent declaration to automatically handle expression type widening without duplicating logic
        if ast.IsReturnStatement(node.parent) then
            local enclosing = ast.GetContainingFunction(node)
            if ast.IsAccessor(enclosing) then
                return self:serializeTypeForDeclaration(enclosing, nil, nil, false)
            end
            return self:serializeReturnTypeForSignature(self.ch:getSignatureFromDeclaration(enclosing), false)
        end
        if ast.IsArrowFunction(node.parent) and node.parent:AsArrowFunction().body == node then
            return self:serializeReturnTypeForSignature(self.ch:getSignatureFromDeclaration(node.parent), false)
        end
        if ast.IsDeclaration(node.parent) then
            return self:serializeTypeForDeclaration(node.parent, nil, nil, false)
        end
        -- This might be effectively unreachable. If it's not, it may need more widening rules to mirror checker behavior for whatever expressions are serialized here
        local ty = self.ch:getTypeOfExpression(node)
        return self:typeToTypeNode(ty)
    elseif k == PseudoTypeKind.NoResult then
        local node = t:AsPseudoTypeNoResult().declaration
        self.ctx.tracker:ReportInferenceFallback(node)
        if ast.IsFunctionLike(node) and not ast.IsAccessor(node) then
            return self:serializeReturnTypeForSignature(self.ch:getSignatureFromDeclaration(node), false)
        end
        return self:serializeTypeForDeclaration(node, nil, nil, false)
    elseif k == PseudoTypeKind.MaybeConstLocation then
        local d = t:AsPseudoTypeMaybeConstLocation()
        -- see checkExpressionWithContextualType for general literal widening rules which need to be emulated here, plus
        -- checkTemplateLiteralExpression for template literal widening rules if the pseudochecker ever supports literalized templates
        local isInConstContext = self.ch:isConstContext(d.node)
        if not isInConstContext and pseudochecker.IsInConstContext(d.node) then
            -- Only consult the contextual type if the pseudochecker's syntactic check also puts us in a const context.
            -- getContextualType returns post-inference results at node-printing time which may not have existed
            -- during initial checking (e.g. when the contextual type depends on inference), causing incorrect
            -- literal type preservation.
            local contextualType = self.ch:getContextualType(d.node, ContextFlags.None)
            local ct = self:pseudoTypeToType(d.constType)
            if ct ~= nil and self.ch:isLiteralOfContextualType(ct, self.ch:instantiateContextualType(contextualType, d.node, ContextFlags.None)) then
                isInConstContext = true
            end
        end
        if isInConstContext then
            return self:pseudoTypeToNode(d.constType)
        else
            return self:pseudoTypeToNode(d.regularType)
        end
    elseif k == PseudoTypeKind.Union then
        local res = {}
        local hasElidedType = false
        local hasUndefined = false
        local members = t:AsPseudoTypeUnion().types
        local appendTypeNode
        appendTypeNode = function(node)
            if ast.IsUnionTypeNode(node) then
                for _, n in ipairs(node:AsUnionTypeNode().types.nodes) do
                    appendTypeNode(n)
                end
                return
            end
            if node.kind == Kind.UndefinedKeyword then
                if hasUndefined then
                    return
                end
                hasUndefined = true
            end
            res[#res + 1] = node
        end
        for _, m in ipairs(members or {}) do
            if not self.ch.strictNullChecks and (m.kind == PseudoTypeKind.Undefined or m.kind == PseudoTypeKind.Null) then
                hasElidedType = true
            else
                appendTypeNode(self:pseudoTypeToNode(m))
            end
        end
        if #res == 1 then
            return res[1]
        end
        if #res == 0 then
            if hasElidedType then
                return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
            end
            return self.f:NewKeywordTypeNode(Kind.NeverKeyword)
        end
        return self.f:NewUnionTypeNode(self.f:NewNodeList(res))
    elseif k == PseudoTypeKind.Undefined then
        if not self.ch.strictNullChecks then
            return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
        end
        return self.f:NewKeywordTypeNode(Kind.UndefinedKeyword)
    elseif k == PseudoTypeKind.Null then
        if not self.ch.strictNullChecks then
            return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
        end
        return self.f:NewLiteralTypeNode(self.f:NewKeywordExpression(Kind.NullKeyword))
    elseif k == PseudoTypeKind.Any then
        return self.f:NewKeywordTypeNode(Kind.AnyKeyword)
    elseif k == PseudoTypeKind.String then
        return self.f:NewKeywordTypeNode(Kind.StringKeyword)
    elseif k == PseudoTypeKind.Number then
        return self.f:NewKeywordTypeNode(Kind.NumberKeyword)
    elseif k == PseudoTypeKind.BigInt then
        return self.f:NewKeywordTypeNode(Kind.BigIntKeyword)
    elseif k == PseudoTypeKind.Boolean then
        return self.f:NewKeywordTypeNode(Kind.BooleanKeyword)
    elseif k == PseudoTypeKind.False then
        return self.f:NewLiteralTypeNode(self.f:NewKeywordExpression(Kind.FalseKeyword))
    elseif k == PseudoTypeKind.True then
        return self.f:NewLiteralTypeNode(self.f:NewKeywordExpression(Kind.TrueKeyword))
    elseif k == PseudoTypeKind.SingleCallSignature then
        local d = t:AsPseudoTypeSingleCallSignature()
        local signature = self.ch:getSignatureFromDeclaration(d.signature)
        local expandedParams = self.ch:getExpandedParameters(signature, true --[[skipUnionExpanding]])[1]
        local cleanup = self:enterNewScope(d.signature, expandedParams, signature.typeParameters, signature.parameters, signature.mapper)
        local typeParams = reuseTypeParameters(self, d.typeParameters)
        local params = self:pseudoParametersToNodeList(d.parameters)
        local returnType = self:pseudoTypeToNode(d.returnType)
        local result = self.f:NewFunctionTypeNode(typeParams, params, returnType)
        cleanup()
        return result
    elseif k == PseudoTypeKind.Tuple then
        local res = {}
        local elements = t:AsPseudoTypeTuple().elements
        for _, e in ipairs(elements or {}) do
            res[#res + 1] = self:pseudoTypeToNode(e)
        end
        -- pseudo-tuples are implicitly `readonly` since they originate from `as const` contexts
        -- but strada *sometimes* fails to add the `readonly` modifier to the generated node.
        local result = self.f:NewTupleTypeNode(self.f:NewNodeList(res))
        self.e:AddEmitFlags(result, EF.EFSingleLine)
        return self.f:NewTypeOperatorNode(Kind.ReadonlyKeyword, result)
    elseif k == PseudoTypeKind.ObjectLiteral then
        local elements = t:AsPseudoTypeObjectLiteral().elements
        if core.Len(elements) == 0 then
            local result = self.f:NewTypeLiteralNode(self.f:NewNodeList(nil))
            self.e:AddEmitFlags(result, EF.EFSingleLine)
            return result
        end
        -- NOTE: using the checker's `isConstContext` instead of the pseudochecker's `isInConstContext`
        -- results in different results here. The checker one is more "correct" but means we'll mark
        -- objects in parameter positions contextually typed by const type parameters as readonly -
        -- something a true syntactic ID emitter couldn't possibly know (since the signature could
        -- be from across files). This can't *really* happen in any cases ID doesn't already error on, though.
        -- Just something to keep in mind if the ID checker keeps growing.
        local isConst = self.ch:isConstContext(elements[1].name.parent.parent)
        local newElements = {}

        -- Member types are serialized within an object type literal, so set the
        -- corresponding flag to mirror createTypeNodeFromObjectType. This ensures
        -- inaccessible `this` references inside the members are reported (TS2527).
        local restoreObjectLiteralFlags = self:saveRestoreFlags()
        self.ctx.flags = self.ctx.flags | nodebuilder.Flags.InObjectTypeLiteral

        for _, e in ipairs(elements) do
            local modifiers
            if isConst or (e.kind == PseudoObjectElementKind.PropertyAssignment and e:AsPseudoPropertyAssignment().readonly) then
                modifiers = self.f:NewModifierList({ self.f:NewModifier(Kind.ReadonlyKeyword) })
            end
            local cleanup
            if e.kind ~= PseudoObjectElementKind.PropertyAssignment then
                local signature = self.ch:getSignatureFromDeclaration(e:Signature())
                local expandedParams = self.ch:getExpandedParameters(signature, true --[[skipUnionExpanding]])[1]
                cleanup = self:enterNewScope(e:Signature(), expandedParams, signature.typeParameters, signature.parameters, signature.mapper)
            end
            local newProp
            if e.kind == PseudoObjectElementKind.Method then
                local d = e:AsPseudoObjectMethod()
                local typeParams = reuseTypeParameters(self, d.typeParameters)
                if isConst then
                    newProp = self.f:NewPropertySignatureDeclaration(
                        modifiers,
                        self:reuseName(e.name, false --[[isMethod]]),
                        nil,
                        self.f:NewFunctionTypeNode(
                            typeParams,
                            self:pseudoParametersToNodeList(d.parameters),
                            self:pseudoTypeToNode(d.returnType)
                        ),
                        nil
                    )
                else
                    newProp = self.f:NewMethodSignatureDeclaration(
                        modifiers,
                        self:reuseName(e.name, true --[[isMethod]]),
                        nil,
                        typeParams,
                        self:pseudoParametersToNodeList(d.parameters),
                        self:pseudoTypeToNode(d.returnType)
                    )
                end
            elseif e.kind == PseudoObjectElementKind.PropertyAssignment then
                local d = e:AsPseudoPropertyAssignment()
                newProp = self.f:NewPropertySignatureDeclaration(
                    modifiers,
                    self:reuseName(e.name, false --[[isMethod]]),
                    nil,
                    self:pseudoTypeToNode(d.type),
                    nil
                )
            elseif e.kind == PseudoObjectElementKind.SetAccessor then
                local d = e:AsPseudoSetAccessor()
                newProp = self.f:NewSetAccessorDeclaration(
                    nil,
                    self:reuseName(e.name, false --[[isMethod]]),
                    nil,
                    self.f:NewNodeList({ self:pseudoParameterToNode(d.parameter) }),
                    nil,
                    nil,
                    nil
                )
            elseif e.kind == PseudoObjectElementKind.GetAccessor then
                local d = e:AsPseudoGetAccessor()
                newProp = self.f:NewGetAccessorDeclaration(
                    nil,
                    self:reuseName(e.name, false --[[isMethod]]),
                    nil,
                    nil,
                    self:pseudoTypeToNode(d.type),
                    nil,
                    nil
                )
            end
            if self.ctx.enclosingFile == ast.GetSourceFileOfNode(e.name) then
                self.e:SetCommentRange(newProp, e.name.parent.loc)
            end
            newElements[#newElements + 1] = newProp
            if cleanup ~= nil then
                cleanup()
            end
        end
        restoreObjectLiteralFlags()
        local result = self.f:NewTypeLiteralNode(self.f:NewNodeList(newElements))
        if self.ctx.flags & nodebuilder.Flags.MultilineObjectLiterals == 0 then
            self.e:AddEmitFlags(result, EF.EFSingleLine)
        end
        return result
    elseif k == PseudoTypeKind.StringLiteral or k == PseudoTypeKind.NumericLiteral or k == PseudoTypeKind.BigIntLiteral then
        local source = t:AsPseudoTypeLiteral().node
        return self.f:NewLiteralTypeNode(self:reuseNode(source))
    else
        debug.AssertNever(t.kind, "Unhandled pseudotype kind in pseudotype node construction")
        return nil
    end
end

function NodeBuilderImpl:pseudoParametersToNodeList(params)
    local res = {}
    for _, p in ipairs(params or {}) do
        res[#res + 1] = self:pseudoParameterToNode(p)
    end
    return self.f:NewNodeList(res)
end

function NodeBuilderImpl:pseudoParameterToNode(p)
    local dotDotDot
    local questionMark
    if p.rest then
        dotDotDot = self.f:NewToken(Kind.DotDotDotToken)
    end
    if p.optional then
        questionMark = self.f:NewToken(Kind.QuestionToken)
    end
    local parameter = self.f:NewParameterDeclaration(
        nil,
        dotDotDot,
        -- matches strada behavior of always reserializing param names from scratch
        self:parameterToParameterDeclarationName(p.name.parent:Symbol(), p.name.parent),
        questionMark,
        self:pseudoTypeToNode(p.type),
        nil
    )
    local original = p.name.parent
    if ast.IsParameterDeclaration(original) then
        self:setCommentRange(parameter, original)
    end
    return parameter
end

-- see `typeNodeIsEquivalentToType` in strada, but applied more broadly here, so is setup to handle more equivalences - strada only used it via
-- the `canReuseTypeNodeAnnotation` host hook and not the `canReuseTypeNode` hook, which meant locations using the later were reliant on
-- over-invalidation by the ID inference engine to not emit incorrect types.
function NodeBuilderImpl:pseudoTypeEquivalentToType(t, type_, isOptionalAnnotated, reportErrors)
    -- if type_ resolves to an error, we charitably assume equality, since we might be in a single-file checking mode
    if type_ ~= nil and self.ch:isErrorType(type_) then
        return true
    end
    -- If we can easily operate on just types, we should
    local typeFromPseudo = self:pseudoTypeToType(t) -- note: cannot convert complex types like objects, which must be validated separately
    if typeFromPseudo == type_ then
        return true
    end
    local undefinedStripped = type_
    if isOptionalAnnotated then
        undefinedStripped = self.ch:getTypeWithFacts(type_, TypeFacts.NEUndefined)
    end
    if typeFromPseudo ~= nil and type_ ~= nil then
        if isOptionalAnnotated then
            if undefinedStripped == typeFromPseudo then
                return true
            end
            if typeFromPseudo.flags & TypeFlags.Union ~= 0 and undefinedStripped.flags & TypeFlags.Union ~= 0 then
                -- does union comparison in general, since the unions may not be `==` identical due to aliasing and the like
                if self.ch:compareTypesIdentical(typeFromPseudo, undefinedStripped) == Ternary.True then
                    return true
                end
            end
        end
        -- handles freshness mismatches (e.g., fresh true vs regular true in as const)
        if self.ch:getRegularTypeOfLiteralType(typeFromPseudo) == self.ch:getRegularTypeOfLiteralType(type_) then
            return true
        end
        if typeFromPseudo.flags & TypeFlags.Union ~= 0 and type_.flags & TypeFlags.Union ~= 0 then
            -- handles union comparison in general, since unions may not be `==` identical due to aliasing
            if self.ch:compareTypesIdentical(typeFromPseudo, type_) == Ternary.True then
                return true
            end
        end
    end
    -- otherwise, fallback to actual pseudo/type cross-comparisons
    local k = t.kind
    if k == PseudoTypeKind.Inferred then
        -- PseudoTypeInferred with error nodes identifies specific problematic children.
        -- Report fine-grained errors on them, then return false so the parent falls back
        -- to checker-based serialization (avoiding issues like reusing raw JSON string
        -- literal property names from the pseudochecker's AST).
        local errorNodes = t:AsPseudoTypeInferred().errorNodes
        if core.Len(errorNodes) > 0 then
            if reportErrors then
                for _, n in ipairs(errorNodes) do
                    self.ctx.tracker:ReportInferenceFallback(n)
                end
            end
            return false
        end
        if reportErrors then
            self.ctx.tracker:ReportInferenceFallback(t:AsPseudoTypeInferred().expression)
        end
        return false
    elseif k == PseudoTypeKind.ObjectLiteral then
        local pt = t:AsPseudoTypeObjectLiteral()
        if type_ == nil then
            return false
        end
        local targetProps = self.ch:getPropertiesOfType(undefinedStripped)
        -- Count total declarations across all target prop symbols to handle getter/setter pairs,
        -- which are two elements in pt.Elements but only one symbol in targetProps.
        local targetDeclCount = 0
        for _, prop in ipairs(targetProps or {}) do
            targetDeclCount = targetDeclCount + core.Len(prop.declarations)
        end
        if core.Len(pt.elements) ~= targetDeclCount then
            return false
        end
        for _, e in ipairs(pt.elements or {}) do
            local targetProp
            local elemSymbol = e.name.parent:Symbol()
            if elemSymbol ~= nil then
                targetProp = self.ch:getPropertyOfType(undefinedStripped, elemSymbol.name)
            end
            if targetProp == nil then
                -- Name lookup failed or returned no result; search target properties
                -- for one whose declaration name node matches the one we have
                for _, prop in ipairs(targetProps or {}) do
                    if prop.valueDeclaration ~= nil and prop.valueDeclaration:Name() == e.name then
                        targetProp = prop
                        break
                    end
                end
                if targetProp == nil then
                    if reportErrors then
                        self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                    end
                    return false
                end
            end
            local targetIsOptional = targetProp.flags & ast.SymbolFlags.Optional ~= 0
            if e.optional ~= targetIsOptional then
                if reportErrors then
                    self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                end
                return false
            end
            local propType = self.ch:getTypeOfSymbol(targetProp)
            propType = self.ch:removeMissingType(propType, targetIsOptional)
            if e.kind == PseudoObjectElementKind.PropertyAssignment then
                local d = e:AsPseudoPropertyAssignment()
                if not self:pseudoTypeEquivalentToType(d.type, propType, e.optional, false) then
                    if reportErrors then
                        if d.type.kind == PseudoTypeKind.Inferred and core.Len(d.type:AsPseudoTypeInferred().errorNodes) > 0 then
                            -- Re-report the fine-grained error nodes; the recursive call used reportErrors=false
                            for _, n in ipairs(d.type:AsPseudoTypeInferred().errorNodes) do
                                self.ctx.tracker:ReportInferenceFallback(n)
                            end
                        elseif not checker.isStructuralPseudoType(d.type) then
                            self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                        end
                    end
                    return false
                end
            elseif e.kind == PseudoObjectElementKind.Method then
                local d = e:AsPseudoObjectMethod()
                local targetSig = self.ch:getSingleCallSignature(propType)
                if targetSig == nil then
                    -- Target property type doesn't have a single call signature; can't validate
                    goto continue
                end
                local paramEq = self:pseudoParametersEquivalentToParameters(d.parameters, targetSig, reportErrors, e.name.parent)
                if not paramEq then
                    return false
                end
                local targetPredicate = self.ch:getTypePredicateOfSignature(targetSig)
                if targetPredicate ~= nil then
                    if not self:pseudoReturnTypeMatchesPredicate(d.returnType, targetPredicate) then
                        if reportErrors then
                            self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                        end
                        return false
                    end
                elseif not self:pseudoTypeEquivalentToType(d.returnType, self.ch:getReturnTypeOfSignature(targetSig), false, false) then
                    if reportErrors then
                        self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                    end
                    return false
                end
            elseif e.kind == PseudoObjectElementKind.GetAccessor then
                local d = e:AsPseudoGetAccessor()
                if not self:pseudoTypeEquivalentToType(d.type, propType, false, false) then
                    if reportErrors then
                        self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                    end
                    return false
                end
            elseif e.kind == PseudoObjectElementKind.SetAccessor then
                local d = e:AsPseudoSetAccessor()
                local writeType = self.ch:getWriteTypeOfSymbol(targetProp)
                if not self:pseudoTypeEquivalentToType(d.parameter.type, writeType, false, false) then
                    if reportErrors then
                        self.ctx.tracker:ReportInferenceFallback(e.name.parent)
                    end
                    return false
                end
            end
            ::continue::
        end
        return true
    elseif k == PseudoTypeKind.Tuple then
        local pt = t:AsPseudoTypeTuple()
        if undefinedStripped == nil or not checker.isTupleType(undefinedStripped) then
            return false
        end
        local tupleTarget = undefinedStripped:TargetTupleType()
        -- Pseudo-tuples come from `as const` array literals, so they only ever have required elements.
        -- If the target tuple has optional, rest, or variadic elements, the structures can't match.
        if tupleTarget.combinedFlags & ElementFlags.NonRequired ~= 0 then
            return false
        end
        local elementTypes = self.ch:getTypeArguments(undefinedStripped)
        if core.Len(pt.elements) ~= core.Len(elementTypes) then
            return false
        end
        for i, elem in ipairs(pt.elements or {}) do
            if not self:pseudoTypeEquivalentToType(elem, elementTypes[i], false, reportErrors) then
                return false
            end
        end
        return true
    elseif k == PseudoTypeKind.SingleCallSignature then
        local targetSig = self.ch:getSingleCallSignature(undefinedStripped)
        if targetSig == nil then
            return false
        end
        local pt = t:AsPseudoTypeSingleCallSignature()
        if core.Len(targetSig.typeParameters) ~= core.Len(pt.typeParameters) then
            if reportErrors then
                self.ctx.tracker:ReportInferenceFallback(pt.signature)
            end
            return false
        end
        local paramEq = self:pseudoParametersEquivalentToParameters(pt.parameters, targetSig, reportErrors, pt.signature)
        if not paramEq then
            return false
        end
        local targetPredicate = self.ch:getTypePredicateOfSignature(targetSig)
        if targetPredicate ~= nil then
            if not self:pseudoReturnTypeMatchesPredicate(pt.returnType, targetPredicate) then
                if reportErrors then
                    self.ctx.tracker:ReportInferenceFallback(pt.signature)
                end
                return false
            end
        elseif not self:pseudoTypeEquivalentToType(pt.returnType, self.ch:getReturnTypeOfSignature(targetSig), false, reportErrors) then
            -- error reported within the return type
            return false
        end
        return true
    elseif k == PseudoTypeKind.NoResult then
        if reportErrors then
            self.ctx.tracker:ReportInferenceFallback(t:AsPseudoTypeNoResult().declaration)
        end
        return false
    else
        return false
    end
end

function NodeBuilderImpl:pseudoParametersEquivalentToParameters(params, targetSig, reportErrors, nonParamErrorLocation)
    if targetSig.thisParameter ~= nil and core.Len(params) == 0 then
        if reportErrors then
            self.ctx.tracker:ReportInferenceFallback(nonParamErrorLocation) -- missing `this` param
        end
        return false
    elseif targetSig.thisParameter ~= nil and ast.IsThisIdentifier(params[1].name) then
        local targetParam = targetSig.thisParameter
        local paramType = self.ch:getTypeOfParameter(targetParam)
        if not self:pseudoTypeEquivalentToType(params[1].type, paramType, params[1].optional, false) then
            if reportErrors then
                self.ctx.tracker:ReportInferenceFallback(params[1].name.parent)
            end
            return false
        end
        params = core.Slice(params, 1)
    elseif targetSig.thisParameter ~= nil then
        if reportErrors then
            self.ctx.tracker:ReportInferenceFallback(nonParamErrorLocation)
        end
        return false
    end
    if core.Len(targetSig.parameters) ~= core.Len(params) then
        if reportErrors then
            self.ctx.tracker:ReportInferenceFallback(nonParamErrorLocation)
        end
        return false -- TODO: spread tuple params may mess with this check
    end
    for i, p in ipairs(params or {}) do
        local targetParam = targetSig.parameters[i]
        if p.optional ~= self.ch:isOptionalParameter(targetParam.valueDeclaration) then
            if reportErrors then
                self.ctx.tracker:ReportInferenceFallback(p.name.parent)
            end
            return false
        end
        local paramType = self.ch:getTypeOfParameter(targetParam)
        if not self:pseudoTypeEquivalentToType(p.type, paramType, p.optional, false) then
            if reportErrors then
                self.ctx.tracker:ReportInferenceFallback(p.name.parent)
            end
            return false
        end
    end
    return true
end

function checker.isStructuralPseudoType(t)
    local k = t.kind
    if k == PseudoTypeKind.ObjectLiteral or k == PseudoTypeKind.Tuple or k == PseudoTypeKind.SingleCallSignature then
        return true
    elseif k == PseudoTypeKind.MaybeConstLocation then
        local d = t:AsPseudoTypeMaybeConstLocation()
        return checker.isStructuralPseudoType(d.constType) or checker.isStructuralPseudoType(d.regularType)
    end
    return false
end

-- pseudoReturnTypeMatchesPredicate checks if a pseudo return type (which should be a Direct type
-- wrapping a TypePredicate) matches the given type predicate from the checker.
function NodeBuilderImpl:pseudoReturnTypeMatchesPredicate(rt, predicate)
    if rt.kind ~= PseudoTypeKind.Direct then
        return false
    end
    local node = rt:AsPseudoTypeDirect().typeNode
    if not ast.IsTypePredicateNode(node) then
        return false
    end
    local tp = node:AsTypePredicateNode()
    -- Check asserts modifier matches
    local isAsserts = tp.assertsModifier ~= nil
    local predicateIsAsserts = predicate.kind == TypePredicateKind.AssertsThis or predicate.kind == TypePredicateKind.AssertsIdentifier
    if isAsserts ~= predicateIsAsserts then
        return false
    end
    -- Check this vs identifier matches
    local isThis = ast.IsThisTypeNode(tp.parameterName)
    local predicateIsThis = predicate.kind == TypePredicateKind.This or predicate.kind == TypePredicateKind.AssertsThis
    if isThis ~= predicateIsThis then
        return false
    end
    -- For identifier predicates, check parameter name matches
    if not isThis then
        if tp.parameterName:Text() ~= predicate.parameterName then
            return false
        end
    end
    -- Check the narrowed type, if any
    if predicate.t ~= nil then
        if tp.type == nil then
            return false
        end
        local predicateTypeFromNode = self.ch:getTypeFromTypeNode(tp.type)
        if predicateTypeFromNode ~= predicate.t then
            if self.ch:compareTypesIdentical(predicateTypeFromNode, predicate.t) ~= Ternary.True then
                return false
            end
        end
    elseif tp.type ~= nil then
        return false
    end
    return true
end

function NodeBuilderImpl:pseudoTypeToType(t)
    -- !!! TODO: only literal types currently mapped because this is only used to determine if literal contextual typing need apply to the pseudotype
    -- If this is used more broadly, the implementation needs to be filled out more to handle the structural pseudotypes - signatures, objects, tuples, etc
    debug.Assert(t ~= nil, "Attempted to realize nil pseudotype")
    local k = t.kind
    if k == PseudoTypeKind.Direct then
        return self.ch:getTypeFromTypeNode(t:AsPseudoTypeDirect().typeNode)
    elseif k == PseudoTypeKind.Inferred then
        local node = t:AsPseudoTypeInferred().expression
        if t:AsPseudoTypeInferred().isSignatureReturn then
            return self.ch:getReturnTypeOfSignature(self.ch:getSignatureFromDeclaration(node))
        end
        local ty = self.ch:getWidenedType(self.ch:getRegularTypeOfExpression(node))
        return ty
    elseif k == PseudoTypeKind.NoResult then
        return nil -- TODO: extract type selection logic from `serializeTypeForDeclaration`, not needed for current usecases but needed if completeness becomes required
    elseif k == PseudoTypeKind.MaybeConstLocation then
        local d = t:AsPseudoTypeMaybeConstLocation()
        if self.ch:isConstContext(d.node) then
            return self:pseudoTypeToType(d.constType)
        end
        return self:pseudoTypeToType(d.regularType)
    elseif k == PseudoTypeKind.Union then
        local res = {}
        local hasElidedType = false
        local members = t:AsPseudoTypeUnion().types
        for _, m in ipairs(members or {}) do
            if not self.ch.strictNullChecks and (m.kind == PseudoTypeKind.Undefined or m.kind == PseudoTypeKind.Null) then
                hasElidedType = true
            else
                local mt = self:pseudoTypeToType(m)
                if mt == nil then
                    return nil -- propagate failure
                end
                res[#res + 1] = mt
            end
        end
        if #res == 1 then
            return res[1]
        end
        if #res == 0 then
            if hasElidedType then
                return self.ch.anyType
            end
            return self.ch.neverType
        end
        return self.ch:getUnionType(res)
    elseif k == PseudoTypeKind.Undefined then
        return self.ch.undefinedWideningType
    elseif k == PseudoTypeKind.Null then
        return self.ch.nullWideningType
    elseif k == PseudoTypeKind.Any then
        return self.ch.anyType
    elseif k == PseudoTypeKind.String then
        return self.ch.stringType
    elseif k == PseudoTypeKind.Number then
        return self.ch.numberType
    elseif k == PseudoTypeKind.BigInt then
        return self.ch.bigintType
    elseif k == PseudoTypeKind.Boolean then
        return self.ch.booleanType
    elseif k == PseudoTypeKind.False then
        return self.ch.falseType
    elseif k == PseudoTypeKind.True then
        return self.ch.trueType
    elseif k == PseudoTypeKind.StringLiteral or k == PseudoTypeKind.NumericLiteral or k == PseudoTypeKind.BigIntLiteral then
        local source = t:AsPseudoTypeLiteral().node
        return self.ch:getRegularTypeOfExpression(source) -- big shortcut, uses cached expression types where possible
    elseif k == PseudoTypeKind.ObjectLiteral or k == PseudoTypeKind.SingleCallSignature or k == PseudoTypeKind.Tuple then
        return nil -- no simple mapping to a type, since these are structural types
    else
        debug.Fail("Unhandled pseudochecker.PseudoTypeKind in pseudoTypeToType")
        return nil
    end
end

return checker
