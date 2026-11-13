local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local binder = require("tslua.binder")

local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local SignatureKind = checker.SignatureKind
local SignatureCheckMode = checker.SignatureCheckMode
local IntersectionState = checker.IntersectionState
local RecursionFlags = checker.RecursionFlags
local ExpandingFlags = checker.ExpandingFlags
local RelationComparisonResult = checker.RelationComparisonResult
local Ternary = checker.Ternary
local VarianceFlags = checker.VarianceFlags
local ElementFlags = checker.ElementFlags
local AccessFlags = checker.AccessFlags
local IndexFlags = checker.IndexFlags
local MappedTypeModifiers = checker.MappedTypeModifiers
local InferenceFlags = checker.InferenceFlags
local InferencePriority = checker.InferencePriority
local TypeFacts = checker.TypeFacts
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local ModifierFlags = ast.ModifierFlags

function Checker:isMemberOfStringMapping(source, target)
    if target.flags & TypeFlags.Any ~= 0 then
        return true
    elseif target.flags & (TypeFlags.String | TypeFlags.TemplateLiteral) ~= 0 then
        return self:isTypeAssignableTo(source, target)
    elseif target.flags & TypeFlags.StringMapping ~= 0 then
        -- We need to see whether applying the same mappings of the target
        -- onto the source would produce an identical type *and* that
        -- it's compatible with the inner-most non-string-mapped type.
        --
        -- The intuition here is that if same mappings don't affect the source at all,
        -- and the source is compatible with the unmapped target, then they must
        -- still reside in the same domain.
        local mapped, inner = self:applyTargetStringMappingToSource(source, target)
        return mapped == source and self:isMemberOfStringMapping(source, inner)
    end
    return false
end

function Checker:applyTargetStringMappingToSource(source, target)
    local inner = target:AsStringMappingType().target
    if inner.flags & TypeFlags.StringMapping ~= 0 then
        source, inner = self:applyTargetStringMappingToSource(source, inner)
    end
    return self:getStringMappingType(target.symbol, source), inner
end

function checker.visibilityToString(flags)
    if flags == ModifierFlags.Private then
        return "private"
    end
    if flags == ModifierFlags.Protected then
        return "protected"
    end
    return "public"
end

-- errorState

defineStruct("errorState", nil, nil)

-- ErrorChain: { next, message, args } where args is a table.pack'ed argument list.

defineStruct("ErrorChain", nil, nil)

-- relatedInfo arrays are never mutated in place (Go's errorState captures slice headers, so a
-- restored state must not see later appends); appending always copies.
local function appendRelatedInfo(relatedInfo, d)
    local result = {}
    for i, x in ipairs(relatedInfo or {}) do
        result[i] = x
    end
    result[#result + 1] = d
    return result
end

-- Relater

local Relater = defineStruct("Relater", nil, {
    maybeCount = 0,
    sourceDepth = 0,
    targetDepth = 0,
    expandingFlags = ExpandingFlags.None,
    overflow = false,
    relationCount = 0,
})

local function newRelater(c)
    local r = checker.Relater_new({ c = c })
    r.maybeKeys = {}
    r.maybeKeysSet = collections.NewSetWithSizeHint(0)
    r.sourceStack = {}
    r.targetStack = {}
    -- Go method value r.reportError, passed as an ErrorReporter.
    r.reportErrorFn = function(message, ...)
        r:reportError(message, ...)
    end
    -- Go method values r.isRelatedToSimple / r.isRelatedToWorker.
    r.isRelatedToSimpleFn = function(s, t)
        return r:isRelatedToSimple(s, t)
    end
    r.isRelatedToWorkerFn = function(s, t, reportErrors)
        return r:isRelatedToWorker(s, t, reportErrors)
    end
    return r
end

function Checker:getRelater()
    local r = self.freeRelater
    if r == nil then
        r = newRelater(self)
    end
    self.freeRelater = r.next
    return r
end

function Checker:putRelater(r)
    r.maybeKeysSet:Clear()
    r.relation = nil
    r.errorNode = nil
    r.errorChain = nil
    r.relatedInfo = nil
    r.maybeKeys = {}
    r.sourceStack = {}
    r.targetStack = {}
    r.maybeCount = 0
    r.sourceDepth = 0
    r.targetDepth = 0
    r.expandingFlags = ExpandingFlags.None
    r.overflow = false
    r.relationCount = 0
    r.next = self.freeRelater
    self.freeRelater = r
end

function Relater:isRelatedToSimple(source, target)
    return self:isRelatedToEx(source, target, RecursionFlags.Both, false --[[reportErrors]], nil --[[headMessage]], IntersectionState.None)
end

function Relater:isRelatedToWorker(source, target, reportErrors)
    return self:isRelatedToEx(source, target, RecursionFlags.Both, reportErrors, nil, IntersectionState.None)
end

function Relater:isRelatedTo(source, target, recursionFlags, reportErrors)
    return self:isRelatedToEx(source, target, recursionFlags, reportErrors, nil, IntersectionState.None)
end

function Relater:isRelatedToEx(originalSource, originalTarget, recursionFlags, reportErrors, headMessage, intersectionState)
    local r = self
    local c = r.c
    if originalSource == originalTarget then
        return Ternary.True
    end
    -- Before normalization: if `source` is type an object type, and `target` is primitive,
    -- skip all the checks we don't need and just return `isSimpleTypeRelatedTo` result
    if originalSource.flags & TypeFlags.Object ~= 0 and originalTarget.flags & TypeFlags.Primitive ~= 0 then
        if r.relation == c.comparableRelation and originalTarget.flags & TypeFlags.Never == 0 and c:isSimpleTypeRelatedTo(originalTarget, originalSource, r.relation, nil) or
            c:isSimpleTypeRelatedTo(originalSource, originalTarget, r.relation, core.IfElse(reportErrors, r.reportErrorFn, nil)) then
            return Ternary.True
        end
        if reportErrors then
            r:reportErrorResults(originalSource, originalTarget, originalSource, originalTarget, headMessage)
        end
        return Ternary.False
    end
    -- Normalize the source and target types: Turn fresh literal types into regular literal types,
    -- turn deferred type references into regular type references, simplify indexed access and
    -- conditional types, and resolve substitution types to either the substitution (on the source
    -- side) or the type variable (on the target side).
    local source = c:getNormalizedType(originalSource, false --[[writing]])
    local target = c:getNormalizedType(originalTarget, true --[[writing]])
    if source == target then
        return Ternary.True
    end
    if r.relation == c.identityRelation then
        if source.flags ~= target.flags then
            return Ternary.False
        end
        if source.flags & TypeFlags.Singleton ~= 0 then
            return Ternary.True
        end
        r:traceUnionsOrIntersectionsTooLarge(source, target)
        return r:recursiveTypeRelatedTo(source, target, false --[[reportErrors]], IntersectionState.None, recursionFlags)
    end
    -- We fastpath comparing a type parameter to exactly its constraint, as this is _super_ common,
    -- and otherwise, for type parameters in large unions, causes us to need to compare the union to itself,
    -- as we break down the _target_ union first, _then_ get the source constraint - so for every
    -- member of the target, we attempt to find a match in the source. This avoids that in cases where
    -- the target is exactly the constraint.
    if source.flags & TypeFlags.TypeParameter ~= 0 and c:getConstraintOfType(source) == target then
        return Ternary.True
    end
    -- See if we're relating a definitely non-nullable type to a union that includes null and/or undefined
    -- plus a single non-nullable type. If so, remove null and/or undefined from the target type.
    if source.flags & TypeFlags.DefinitelyNonNullable ~= 0 and target.flags & TypeFlags.Union ~= 0 then
        local types = target:Types()
        local candidate
        if #types == 2 and types[1].flags & TypeFlags.Nullable ~= 0 then
            candidate = types[2]
        elseif #types == 3 and types[1].flags & TypeFlags.Nullable ~= 0 and types[2].flags & TypeFlags.Nullable ~= 0 then
            candidate = types[3]
        end
        if candidate ~= nil and candidate.flags & TypeFlags.Nullable == 0 then
            target = c:getNormalizedType(candidate, true --[[writing]])
            if source == target then
                return Ternary.True
            end
        end
    end
    if r.relation == c.comparableRelation and target.flags & TypeFlags.Never == 0 and c:isSimpleTypeRelatedTo(target, source, r.relation, nil) or
        c:isSimpleTypeRelatedTo(source, target, r.relation, core.IfElse(reportErrors, r.reportErrorFn, nil)) then
        return Ternary.True
    end
    if source.flags & TypeFlags.StructuredOrInstantiable ~= 0 or target.flags & TypeFlags.StructuredOrInstantiable ~= 0 then
        local isPerformingExcessPropertyChecks = intersectionState & IntersectionState.Target == 0 and checker.isObjectLiteralType(source) and source.objectFlags & ObjectFlags.FreshLiteral ~= 0
        if isPerformingExcessPropertyChecks then
            if r:hasExcessProperties(source, target, reportErrors) then
                if reportErrors then
                    r:reportRelationError(headMessage, source, core.IfElse(originalTarget.alias ~= nil, originalTarget, target))
                end
                return Ternary.False
            end
        end
        local isPerformingCommonPropertyChecks = (r.relation ~= c.comparableRelation or checker.isUnitType(source)) and
            intersectionState & IntersectionState.Target == 0 and
            source.flags & (TypeFlags.Primitive | TypeFlags.Object | TypeFlags.Intersection) ~= 0 and source ~= c.globalObjectType and
            target.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 and c:isWeakType(target) and (core.Len(c:getPropertiesOfType(source)) > 0 or c:typeHasCallOrConstructSignatures(source))
        local isComparingJsxAttributes = source.objectFlags & ObjectFlags.JsxAttributes ~= 0
        if isPerformingCommonPropertyChecks and not c:hasCommonProperties(source, target, isComparingJsxAttributes) then
            if reportErrors then
                local sourceString = c:TypeToString(core.IfElse(originalSource.alias ~= nil, originalSource, source))
                local targetString = c:TypeToString(core.IfElse(originalTarget.alias ~= nil, originalTarget, target))
                local calls = c:getSignaturesOfType(source, SignatureKind.Call)
                local constructs = c:getSignaturesOfType(source, SignatureKind.Construct)
                if core.Len(calls) > 0 and r:isRelatedTo(c:getReturnTypeOfSignature(calls[1]), target, RecursionFlags.Source, false --[[reportErrors]]) ~= Ternary.False or
                    core.Len(constructs) > 0 and r:isRelatedTo(c:getReturnTypeOfSignature(constructs[1]), target, RecursionFlags.Source, false --[[reportErrors]]) ~= Ternary.False then
                    r:reportError(diagnostics.Value_of_type_0_has_no_properties_in_common_with_type_1_Did_you_mean_to_call_it, sourceString, targetString)
                else
                    r:reportError(diagnostics.Type_0_has_no_properties_in_common_with_type_1, sourceString, targetString)
                end
            end
            return Ternary.False
        end
        r:traceUnionsOrIntersectionsTooLarge(source, target)
        local skipCaching = source.flags & TypeFlags.Union ~= 0 and #source:Types() < 4 and target.flags & TypeFlags.Union == 0 or
            target.flags & TypeFlags.Union ~= 0 and #target:Types() < 4 and source.flags & TypeFlags.StructuredOrInstantiable == 0
        local result
        if skipCaching then
            result = r:unionOrIntersectionRelatedTo(source, target, reportErrors, intersectionState)
        else
            result = r:recursiveTypeRelatedTo(source, target, reportErrors, intersectionState, recursionFlags)
        end
        if result ~= Ternary.False then
            return result
        end
    end
    if reportErrors then
        r:reportErrorResults(originalSource, originalTarget, source, target, headMessage)
    end
    return Ternary.False
end

function Relater:hasExcessProperties(source, target, reportErrors)
    local r = self
    local c = r.c
    if not checker.isExcessPropertyCheckTarget(target) or not c.noImplicitAny and target.objectFlags & ObjectFlags.JSLiteral ~= 0 then
        -- Disable excess property checks on JS literals to simulate having an implicit "index signature" - but only outside of noImplicitAny
        return false
    end
    local isComparingJsxAttributes = source.objectFlags & ObjectFlags.JsxAttributes ~= 0
    if (r.relation == c.assignableRelation or r.relation == c.comparableRelation) and (c:isTypeSubsetOf(c.globalObjectType, target) or (not isComparingJsxAttributes and c:isEmptyObjectType(target))) then
        return false
    end
    local reducedTarget = target
    local checkTypes
    if target.flags & TypeFlags.Union ~= 0 then
        reducedTarget = c:findMatchingDiscriminantType(source, target, r.isRelatedToSimpleFn)
        if reducedTarget == nil then
            reducedTarget = c:filterPrimitivesIfContainsNonPrimitive(target)
        end
        checkTypes = reducedTarget:Distributed()
    end
    for _, prop in ipairs(c:getPropertiesOfType(source) or {}) do
        if checker.shouldCheckAsExcessProperty(prop, source.symbol) and not checker.isIgnoredJsxProperty(source, prop) then
            if not c:isKnownProperty(reducedTarget, prop.name, isComparingJsxAttributes) then
                if reportErrors then
                    -- Report error in terms of object types in the target as those are the only ones
                    -- we check in isKnownProperty.
                    local errorTarget = c:filterType(reducedTarget, checker.isExcessPropertyCheckTarget)
                    -- We know *exactly* where things went wrong when comparing the types.
                    -- Use this property as the error node as this will be more helpful in
                    -- reasoning about what went wrong.
                    if r.errorNode == nil then
                        error("No errorNode in hasExcessProperties", 0)
                    end
                    if ast.IsJsxAttributes(r.errorNode) or ast.IsJsxOpeningLikeElement(r.errorNode) or ast.IsJsxOpeningLikeElement(r.errorNode.parent) then
                        -- JsxAttributes has an object-literal flag and undergo same type-assignablity check as normal object-literal.
                        -- However, using an object-literal error message will be very confusing to the users so we give different a message.
                        if prop.valueDeclaration ~= nil and ast.IsJsxAttribute(prop.valueDeclaration) and ast.GetSourceFileOfNode(r.errorNode) == ast.GetSourceFileOfNode(prop.valueDeclaration:Name()) then
                            -- Note that extraneous children (as in `<NoChild>extra</NoChild>`) don't pass this check,
                            -- since `children` is a Kind.PropertySignature instead of a Kind.JsxAttribute.
                            r.errorNode = prop.valueDeclaration:Name()
                        end
                        local propName = c:symbolToString(prop)
                        local suggestionSymbol = c:getSuggestedSymbolForNonexistentJSXAttribute(propName, errorTarget)
                        if suggestionSymbol ~= nil then
                            r:reportError(diagnostics.Property_0_does_not_exist_on_type_1_Did_you_mean_2, propName, c:TypeToString(errorTarget), c:symbolToString(suggestionSymbol))
                        else
                            r:reportError(diagnostics.Property_0_does_not_exist_on_type_1, propName, c:TypeToString(errorTarget))
                        end
                    else
                        -- use the property's value declaration if the property is assigned inside the literal itself
                        local objectLiteralDeclaration
                        if source.symbol ~= nil then
                            objectLiteralDeclaration = core.FirstOrNil(source.symbol.declarations)
                        end
                        local suggestion = ""
                        if prop.valueDeclaration ~= nil and ast.IsObjectLiteralElement(prop.valueDeclaration) and
                            ast.FindAncestor(prop.valueDeclaration, function(d) return d == objectLiteralDeclaration end) ~= nil and
                            ast.GetSourceFileOfNode(objectLiteralDeclaration) == ast.GetSourceFileOfNode(r.errorNode) then
                            local name = prop.valueDeclaration:Name()
                            r.errorNode = name
                            if ast.IsIdentifier(name) then
                                suggestion = c:getSuggestionForNonexistentProperty(name:Text(), errorTarget)
                            end
                        end
                        if suggestion ~= "" then
                            r:reportError(diagnostics.Object_literal_may_only_specify_known_properties_but_0_does_not_exist_in_type_1_Did_you_mean_to_write_2, c:symbolToString(prop), c:TypeToString(errorTarget), suggestion)
                        else
                            r:reportError(diagnostics.Object_literal_may_only_specify_known_properties_and_0_does_not_exist_in_type_1, c:symbolToString(prop), c:TypeToString(errorTarget))
                        end
                    end
                end
                return true
            end
            if checkTypes ~= nil and r:isRelatedTo(c:getTypeOfSymbol(prop), c:getTypeOfPropertyInTypes(checkTypes, prop.name), RecursionFlags.Both, reportErrors) == Ternary.False then
                if reportErrors then
                    r:reportError(diagnostics.Types_of_property_0_are_incompatible, c:symbolToString(prop))
                end
                return true
            end
        end
    end
    return false
end

function Checker:getTypeOfPropertyInTypes(types, name)
    local propTypes
    for _, t in ipairs(types) do
        propTypes = core.Append(propTypes, self:getTypeOfPropertyInType(t, name))
    end
    return self:getUnionType(propTypes)
end

function Checker:getTypeOfPropertyInType(t, name)
    local c = self
    t = c:getApparentType(t)
    local prop
    if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        prop = c:getPropertyOfUnionOrIntersectionType(t, name, false)
    else
        prop = c:getPropertyOfObjectType(t, name)
    end
    if prop ~= nil then
        return c:getTypeOfSymbol(prop)
    end
    local indexInfo = c:getApplicableIndexInfoForName(t, name)
    if indexInfo ~= nil then
        return indexInfo.valueType
    end
    return c.undefinedType
end

function checker.shouldCheckAsExcessProperty(prop, container)
    return prop.valueDeclaration ~= nil and container.valueDeclaration ~= nil and prop.valueDeclaration.parent == container.valueDeclaration
end

function checker.isIgnoredJsxProperty(source, sourceProp)
    return source.objectFlags & ObjectFlags.JsxAttributes ~= 0 and checker.isHyphenatedJsxName(sourceProp.name)
end

function Checker:isTypeSubsetOf(source, target)
    return source == target or source.flags & TypeFlags.Never ~= 0 or target.flags & TypeFlags.Union ~= 0 and self:isTypeSubsetOfUnion(source, target)
end

function Checker:isTypeSubsetOfUnion(source, target)
    if source.flags & TypeFlags.Union ~= 0 then
        for _, t in ipairs(source:Types()) do
            if not checker.containsType(target:Types(), t) then
                return false
            end
        end
        return true
    end
    if source.flags & TypeFlags.EnumLike ~= 0 and self:getBaseTypeOfEnumLikeType(source) == target then
        return true
    end
    return checker.containsType(target:Types(), source)
end

local function stringSlicesEqual(a, b)
    if core.Len(a) ~= core.Len(b) then
        return false
    end
    for i = 1, core.Len(a) do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function sliceContains(xs, x)
    for _, v in ipairs(xs or {}) do
        if v == x then
            return true
        end
    end
    return false
end

function Relater:unionOrIntersectionRelatedTo(source, target, reportErrors, intersectionState)
    local r = self
    local c = r.c
    -- Note that these checks are specifically ordered to produce correct results. In particular,
    -- we need to deconstruct unions before intersections (because unions are always at the top),
    -- and we need to handle "each" relations before "some" relations for the same kind of type.
    if source.flags & TypeFlags.Union ~= 0 then
        if target.flags & TypeFlags.Union ~= 0 then
            -- Intersections of union types are normalized into unions of intersection types, and such normalized
            -- unions can get very large and expensive to relate. The following fast path checks if the source union
            -- originated in an intersection. If so, and if that intersection contains the target type, then we know
            -- the result to be true (for any two types A and B, A & B is related to both A and B).
            local sourceOrigin = source:AsUnionType().origin
            if sourceOrigin ~= nil and sourceOrigin.flags & TypeFlags.Intersection ~= 0 and target.alias ~= nil and sliceContains(sourceOrigin:Types(), target) then
                return Ternary.True
            end
            -- Similarly, in unions of unions the we preserve the original list of unions. This original list is often
            -- much shorter than the normalized result, so we scan it in the following fast path.
            local targetOrigin = target:AsUnionType().origin
            if targetOrigin ~= nil and targetOrigin.flags & TypeFlags.Union ~= 0 and source.alias ~= nil and sliceContains(targetOrigin:Types(), source) then
                return Ternary.True
            end
        end
        if r.relation == c.comparableRelation then
            return r:someTypeRelatedToType(source, target, reportErrors and source.flags & TypeFlags.Primitive == 0, intersectionState)
        end
        return r:eachTypeRelatedToType(source, target, reportErrors and source.flags & TypeFlags.Primitive == 0, intersectionState)
    end
    if target.flags & TypeFlags.Union ~= 0 then
        return r:typeRelatedToSomeType(c:getRegularTypeOfObjectLiteral(source), target, reportErrors and source.flags & TypeFlags.Primitive == 0 and target.flags & TypeFlags.Primitive == 0, intersectionState)
    end
    if target.flags & TypeFlags.Intersection ~= 0 then
        return r:typeRelatedToEachType(source, target, reportErrors, IntersectionState.Target)
    end
    -- Source is an intersection. For the comparable relation, if the target is a primitive type we hoist the
    -- constraints of all non-primitive types in the source into a new intersection. We do this because the
    -- intersection may further constrain the constraints of the non-primitive types. For example, given a type
    -- parameter 'T extends 1 | 2', the intersection 'T & 1' should be reduced to '1' such that it doesn't
    -- appear to be comparable to '2'.
    if r.relation == c.comparableRelation and target.flags & TypeFlags.Primitive ~= 0 then
        local constraints = core.SameMap(source:Types(), function(t)
            if t.flags & TypeFlags.Instantiable ~= 0 then
                local constraint = c:getBaseConstraintOfType(t)
                if constraint ~= nil then
                    return constraint
                end
                return c.unknownType
            end
            return t
        end)
        if not core.Same(constraints, source:Types()) then
            source = c:getIntersectionType(constraints)
            if source.flags & TypeFlags.Never ~= 0 then
                return Ternary.False
            end
            if source.flags & TypeFlags.Intersection == 0 then
                local result = r:isRelatedTo(source, target, RecursionFlags.Source, false --[[reportErrors]])
                if result ~= Ternary.False then
                    return result
                end
                return r:isRelatedTo(target, source, RecursionFlags.Source, false --[[reportErrors]])
            end
        end
    end
    -- Check to see if any constituents of the intersection are immediately related to the target.
    -- Don't report errors though. Elaborating on whether a source constituent is related to the target is
    -- not actually useful and leads to some confusing error messages. Instead, we rely on the caller
    -- checking whether the full intersection viewed as an object is related to the target.
    return r:someTypeRelatedToType(source, target, false --[[reportErrors]], IntersectionState.Source)
end

function Relater:someTypeRelatedToType(source, target, reportErrors, intersectionState)
    local sourceTypes = source:Types()
    if source.flags & TypeFlags.Union ~= 0 and checker.containsType(sourceTypes, target) then
        return Ternary.True
    end
    for i, t in ipairs(sourceTypes) do
        local related = self:isRelatedToEx(t, target, RecursionFlags.Source, reportErrors and i == #sourceTypes, nil --[[headMessage]], intersectionState)
        if related ~= Ternary.False then
            return related
        end
    end
    return Ternary.False
end

function Relater:eachTypeRelatedToType(source, target, reportErrors, intersectionState)
    local r = self
    local result = Ternary.True
    local sourceTypes = source:Types()
    -- We strip `undefined` from the target if the `source` trivially doesn't contain it for our correspondence-checking fastpath
    -- since `undefined` is frequently added by optionality and would otherwise spoil a potentially useful correspondence
    local strippedTarget = r:getUndefinedStrippedTargetIfNeeded(source, target)
    local strippedTypes
    if strippedTarget.flags & TypeFlags.Union ~= 0 then
        strippedTypes = strippedTarget:Types()
    end
    for i1, sourceType in ipairs(sourceTypes) do
        local i = i1 - 1
        if strippedTarget.flags & TypeFlags.Union ~= 0 and #sourceTypes >= #strippedTypes and #sourceTypes % #strippedTypes == 0 then
            -- many unions are mappings of one another; in such cases, simply comparing members at the same index can shortcut the comparison
            -- such unions will have identical lengths, and their corresponding elements will match up. Another common scenario is where a large
            -- union has a union of objects intersected with it. In such cases, if the input was, eg `("a" | "b" | "c") & (string | boolean | {} | {whatever})`,
            -- the result will have the structure `"a" | "b" | "c" | "a" & {} | "b" & {} | "c" & {} | "a" & {whatever} | "b" & {whatever} | "c" & {whatever}`
            -- - the resulting union has a length which is a multiple of the original union, and the elements correspond modulo the length of the original union
            local related = r:isRelatedToEx(sourceType, strippedTypes[i % #strippedTypes + 1], RecursionFlags.Both, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
            if related ~= Ternary.False then
                result = result & related
                goto continue
            end
        end
        do
            local related = r:isRelatedToEx(sourceType, target, RecursionFlags.Source, reportErrors, nil --[[headMessage]], intersectionState)
            if related == Ternary.False then
                return Ternary.False
            end
            result = result & related
        end
        ::continue::
    end
    return result
end

function Relater:getUndefinedStrippedTargetIfNeeded(source, target)
    if source.flags & TypeFlags.Union ~= 0 and target.flags & TypeFlags.Union ~= 0 and source:Types()[1].flags & TypeFlags.Undefined == 0 and target:Types()[1].flags & TypeFlags.Undefined ~= 0 then
        return self.c:extractTypesOfKind(target, ~TypeFlags.Undefined)
    end
    return target
end

function Relater:typeRelatedToSomeType(source, target, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local targetTypes = target:Types()
    if target.flags & TypeFlags.Union ~= 0 then
        if checker.containsType(targetTypes, source) then
            return Ternary.True
        end
        if r.relation ~= c.comparableRelation and target.objectFlags & ObjectFlags.PrimitiveUnion ~= 0 and source.flags & TypeFlags.EnumLiteral == 0 and
            (source.flags & (TypeFlags.StringLiteral | TypeFlags.BooleanLiteral | TypeFlags.BigIntLiteral) ~= 0 or
                (r.relation == c.subtypeRelation or r.relation == c.strictSubtypeRelation) and source.flags & TypeFlags.NumberLiteral ~= 0) then
            -- When relating a literal type to a union of primitive types, we know the relation is false unless
            -- the union contains the base primitive type or the literal type in one of its fresh/regular forms.
            -- We exclude numeric literals for non-subtype relations because numeric literals are assignable to
            -- numeric enum literals with the same value. Similarly, we exclude enum literal types because
            -- identically named enum types are related (see isEnumTypeRelatedTo). We exclude the comparable
            -- relation in entirety because it needs to be checked in both directions.
            local alternateForm
            if source == source:AsLiteralType().regularType then
                alternateForm = source:AsLiteralType().freshType
            else
                alternateForm = source:AsLiteralType().regularType
            end
            local primitive
            if source.flags & TypeFlags.StringLiteral ~= 0 then
                primitive = c.stringType
            elseif source.flags & TypeFlags.NumberLiteral ~= 0 then
                primitive = c.numberType
            elseif source.flags & TypeFlags.BigIntLiteral ~= 0 then
                primitive = c.bigintType
            end
            if primitive ~= nil and checker.containsType(targetTypes, primitive) or alternateForm ~= nil and checker.containsType(targetTypes, alternateForm) then
                return Ternary.True
            end
            return Ternary.False
        end
        local match = c:getMatchingUnionConstituentForType(target, source)
        if match ~= nil then
            local related = r:isRelatedToEx(source, match, RecursionFlags.Target, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
            if related ~= Ternary.False then
                return related
            end
        end
    end
    for _, t in ipairs(targetTypes) do
        local related = r:isRelatedToEx(source, t, RecursionFlags.Target, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
        if related ~= Ternary.False then
            return related
        end
    end
    if reportErrors then
        -- Elaborate only if we can find a best matching type in the target union
        local bestMatchingType = c:getBestMatchingType(source, target, r.isRelatedToSimpleFn)
        if bestMatchingType ~= nil then
            r:isRelatedToEx(source, bestMatchingType, RecursionFlags.Target, true --[[reportErrors]], nil --[[headMessage]], intersectionState)
        end
    end
    return Ternary.False
end

function Relater:typeRelatedToEachType(source, target, reportErrors, intersectionState)
    local result = Ternary.True
    local targetTypes = target:Types()
    for _, targetType in ipairs(targetTypes) do
        local related = self:isRelatedToEx(source, targetType, RecursionFlags.Target, reportErrors, nil --[[headMessage]], intersectionState)
        if related == Ternary.False then
            return Ternary.False
        end
        result = result & related
    end
    return result
end

function Relater:eachTypeRelatedToSomeType(source, target)
    local result = Ternary.True
    local sourceTypes = source:Types()
    for _, sourceType in ipairs(sourceTypes) do
        local related = self:typeRelatedToSomeType(sourceType, target, false --[[reportErrors]], IntersectionState.None)
        if related == Ternary.False then
            return Ternary.False
        end
        result = result & related
    end
    return result
end

-- Determine if possibly recursive types are related. First, check if the result is already available in the global cache.
-- Second, check if we have already started a comparison of the given two types in which case we assume the result to be true.
-- Third, check if both types are part of deeply nested chains of generic type instantiations and if so assume the types are
-- equal and infinitely expanding. Fourth, if we have reached a depth of 100 nested comparisons, assume we have runaway recursion
-- and issue an error. Otherwise, actually compare the structure of the two types.
function Relater:recursiveTypeRelatedTo(source, target, reportErrors, intersectionState, recursionFlags)
    local r = self
    local c = r.c
    if r.overflow then
        -- Note that stack depth overflows can cause _any_ relation involving structured types to become false, so it is
        -- important to have well-defined behavior even in cases that shouldn't normally occur.
        return Ternary.False
    end
    local id, constrained = checker.getRelationKey(source, target, intersectionState, r.relation == c.identityRelation, false --[[ignoreConstraints]])
    local entry = r.relation:get(id)
    if entry ~= RelationComparisonResult.None then
        if reportErrors and entry & RelationComparisonResult.Failed ~= 0 and entry & RelationComparisonResult.Overflow == 0 then -- luacheck: ignore 542
            -- We are elaborating errors and the cached result is a failure not due to a comparison overflow,
            -- so we will do the comparison again to generate an error message.
        else
            c.reliabilityFlags = c.reliabilityFlags | entry & (RelationComparisonResult.ReportsUnmeasurable | RelationComparisonResult.ReportsUnreliable)
            if reportErrors and entry & RelationComparisonResult.Overflow ~= 0 then
                r:reportError(diagnostics.Excessive_complexity_comparing_types_0_and_1, c:TypeToString(source), c:TypeToString(target))
            end
            if entry & RelationComparisonResult.Succeeded ~= 0 then
                return Ternary.True
            end
            return Ternary.False
        end
    end
    if r.relationCount <= 0 then
        r.overflow = true
        return Ternary.False
    end
    -- If source and target are already being compared, consider them related with assumptions
    if r.maybeKeysSet:Has(id) then
        return Ternary.Maybe
    end
    -- A constrained key indicates that we have type references that reference constrained
    -- type parameters. For such keys we also check against the key we would have gotten if all type parameters
    -- were unconstrained.
    if constrained then
        local broadestEquivalentId = checker.getRelationKey(source, target, intersectionState, r.relation == c.identityRelation, true --[[ignoreConstraints]])
        if r.maybeKeysSet:Has(broadestEquivalentId) then
            return Ternary.Maybe
        end
    end
    if #r.sourceStack == 100 or #r.targetStack == 100 then
        -- We stop relating if we reach 100 levels of nesting. This is a backstop to catch infinite recursion
        -- that wasn't caught by isDeeplyNestedType. It will also stop relating types that truly are over 100
        -- levels deep, but those are exceedingly rare.
        return Ternary.Maybe
    end
    local maybeStart = #r.maybeKeys
    r.maybeKeys[#r.maybeKeys + 1] = id
    r.maybeKeysSet:Add(id)
    local saveExpandingFlags = r.expandingFlags
    if recursionFlags & RecursionFlags.Source ~= 0 then
        r.sourceStack[#r.sourceStack + 1] = source
        if r.expandingFlags & ExpandingFlags.Source == 0 and c:isDeeplyNestedType(source, r.sourceStack, 3) then
            r.expandingFlags = r.expandingFlags | ExpandingFlags.Source
        end
    end
    if recursionFlags & RecursionFlags.Target ~= 0 then
        r.targetStack[#r.targetStack + 1] = target
        if r.expandingFlags & ExpandingFlags.Target == 0 and c:isDeeplyNestedType(target, r.targetStack, 3) then
            r.expandingFlags = r.expandingFlags | ExpandingFlags.Target
        end
    end
    local saveReliabilityFlags = c.reliabilityFlags
    c.reliabilityFlags = 0
    local result
    local pop = nil
    if r.expandingFlags == ExpandingFlags.Both then
        local tr = c.tracer
        if tr ~= nil then
            tr:Instant(tracing.PhaseCheckTypes, "recursiveTypeRelatedTo_DepthLimit", { sourceId = source.id, targetId = target.id, depth = #r.sourceStack, targetDepth = #r.targetStack })
        end
        result = Ternary.Maybe
    else
        local tr = c.tracer
        if tr ~= nil then
            -- Go: deferred until return
            pop = tr:Push(tracing.PhaseCheckTypes, "structuredTypeRelatedTo", { sourceId = source.id, targetId = target.id }, false)
        end
        result = r:structuredTypeRelatedTo(source, target, reportErrors, intersectionState)
    end
    local propagatingVarianceFlags = c.reliabilityFlags
    c.reliabilityFlags = c.reliabilityFlags | saveReliabilityFlags
    if recursionFlags & RecursionFlags.Source ~= 0 then
        r.sourceStack[#r.sourceStack] = nil
    end
    if recursionFlags & RecursionFlags.Target ~= 0 then
        r.targetStack[#r.targetStack] = nil
    end
    r.expandingFlags = saveExpandingFlags
    if result ~= Ternary.False then
        if result == Ternary.True or (#r.sourceStack == 0 and #r.targetStack == 0) then
            if result == Ternary.True or result == Ternary.Maybe then
                -- If result is definitely true, record all maybe keys as having succeeded. Also, record Ternary.Maybe
                -- results as having succeeded once we reach depth 0, but never record Ternary.Unknown results.
                r:resetMaybeStack(maybeStart, propagatingVarianceFlags, true)
            else
                r:resetMaybeStack(maybeStart, propagatingVarianceFlags, false)
            end
        end
        -- Note: it's intentional that we don't reset in the else case;
        -- we leave them on the stack such that when we hit depth zero
        -- above, we can report all of them as successful.
    else
        -- A false result goes straight into global cache (when something is false under
        -- assumptions it will also be false without assumptions)
        r.relation:set(id, RelationComparisonResult.Failed | propagatingVarianceFlags)
        r.relationCount = r.relationCount - 1
        r:resetMaybeStack(maybeStart, propagatingVarianceFlags, false)
    end
    if pop ~= nil then
        pop()
    end
    return result
end

function Relater:resetMaybeStack(maybeStart, propagatingVarianceFlags, markAllAsSucceeded)
    local r = self
    for i = maybeStart, #r.maybeKeys - 1 do
        r.maybeKeysSet:Delete(r.maybeKeys[i + 1])
        if markAllAsSucceeded then
            r.relation:set(r.maybeKeys[i + 1], RelationComparisonResult.Succeeded | propagatingVarianceFlags)
            r.relationCount = r.relationCount - 1
        end
    end
    for i = #r.maybeKeys, maybeStart + 1, -1 do
        r.maybeKeys[i] = nil
    end
end

function Relater:getErrorState()
    return checker.errorState_new({
        errorChain = self.errorChain,
        relatedInfo = self.relatedInfo,
    })
end

function Relater:restoreErrorState(e)
    self.errorChain = e.errorChain
    self.relatedInfo = e.relatedInfo
end

function Relater:structuredTypeRelatedTo(source, target, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local saveErrorState = r:getErrorState()
    local result = r:structuredTypeRelatedToWorker(source, target, reportErrors, intersectionState)
    if r.relation ~= c.identityRelation then
        -- The combined constraint of an intersection type is the intersection of the constraints of
        -- the constituents. When an intersection type contains instantiable types with union type
        -- constraints, there are situations where we need to examine the combined constraint. One is
        -- when the target is a union type. Another is when the intersection contains types belonging
        -- to one of the disjoint domains. For example, given type variables T and U, each with the
        -- constraint 'string | number', the combined constraint of 'T & U' is 'string | number' and
        -- we need to check this constraint against a union on the target side. Also, given a type
        -- variable V constrained to 'string | number', 'V & number' has a combined constraint of
        -- 'string & number | number & number' which reduces to just 'number'.
        -- This also handles type parameters, as a type parameter with a union constraint compared against a union
        -- needs to have its constraint hoisted into an intersection with said type parameter, this way
        -- the type param can be compared with itself in the target (with the influence of its constraint to match other parts)
        -- For example, if `T extends 1 | 2` and `U extends 2 | 3` and we compare `T & U` to `T & U & (1 | 2 | 3)`
        if result == Ternary.False and (source.flags & TypeFlags.Intersection ~= 0 or source.flags & TypeFlags.TypeParameter ~= 0 and target.flags & TypeFlags.Union ~= 0) then
            local sourceTypes
            if source.flags & TypeFlags.Intersection ~= 0 then
                sourceTypes = source:Types()
            else
                sourceTypes = { source }
            end
            local constraint = c:getEffectiveConstraintOfIntersection(sourceTypes, target.flags & TypeFlags.Union ~= 0)
            if constraint ~= nil and checker.everyType(constraint, function(t) return t ~= source end) then
                -- TODO: Stack errors so we get a pyramid for the "normal" comparison above, _and_ a second for this
                result = r:isRelatedToEx(constraint, target, RecursionFlags.Source, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
            end
        end
        -- When the target is an intersection we need an extra property check in order to detect nested excess
        -- properties and nested weak types. The following are motivating examples that all should be errors, but
        -- aren't without this extra property check:
        --
        --   let obj: { a: { x: string } } & { c: number } = { a: { x: 'hello', y: 2 }, c: 5 };  // Nested excess property
        --
        --   declare let wrong: { a: { y: string } };
        --   let weak: { a?: { x?: number } } & { c?: string } = wrong;  // Nested weak object type
        --
        if result ~= Ternary.False and intersectionState & IntersectionState.Target == 0 and target.flags & TypeFlags.Intersection ~= 0 and not c:isGenericObjectType(target) and source.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 then
            result = result & r:propertiesRelatedTo(source, target, reportErrors, nil --[[excludedProperties]], false --[[optionalsOnly]], IntersectionState.None)
            if result ~= 0 and checker.isObjectLiteralType(source) and source.objectFlags & ObjectFlags.FreshLiteral ~= 0 then
                result = result & r:indexSignaturesRelatedTo(source, target, false --[[sourceIsPrimitive]], reportErrors, IntersectionState.None)
            end
        -- When the source is an intersection we need an extra check of any optional properties in the target to
        -- detect possible mismatched property types. For example:
        --
        --   function foo<T extends object>(x: { a?: string }, y: T & { a: boolean }) {
        --     x = y;  // Mismatched property in source intersection
        --   }
        --
        elseif result ~= 0 and c:isNonGenericObjectType(target) and not c:isArrayOrTupleType(target) and r:isSourceIntersectionNeedingExtraCheck(source, target) then
            result = result & r:propertiesRelatedTo(source, target, reportErrors, nil --[[excludedProperties]], true --[[optionalsOnly]], intersectionState)
        end
    end
    if result ~= Ternary.False then
        r:restoreErrorState(saveErrorState)
    end
    return result
end

function Relater:isSourceIntersectionNeedingExtraCheck(source, target)
    return source.flags & TypeFlags.Intersection ~= 0 and self.c:getApparentType(source).flags & TypeFlags.StructuredType ~= 0 and
        not core.Some(source:Types(), function(t)
            return t == target or t.objectFlags & ObjectFlags.NonInferrableType ~= 0
        end)
end

function Relater:structuredTypeRelatedToWorker(source, target, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local result = Ternary.False
    local varianceCheckFailed = false
    local originalErrorChain
    local saveErrorState = r:getErrorState()
    local function relateVariances(sourceTypeArguments, targetTypeArguments, variances, intersectionState_)
        result = r:typeArgumentsRelatedTo(sourceTypeArguments, targetTypeArguments, variances, reportErrors, intersectionState_)
        if result ~= Ternary.False then
            return result, true
        end
        if core.Some(variances, function(v) return v & VarianceFlags.AllowsStructuralFallback ~= 0 end) then
            -- If some type parameter was `Unmeasurable` or `Unreliable`, and we couldn't pass by assuming it was identical, then we
            -- have to allow a structural fallback check
            -- We elide the variance-based error elaborations, since those might not be too helpful, since we'll potentially
            -- be assuming identity of the type parameter.
            originalErrorChain = nil
            r:restoreErrorState(saveErrorState)
            return Ternary.False, false
        end
        local allowStructuralFallback = c:hasCovariantVoidArgument(targetTypeArguments, variances)
        varianceCheckFailed = not allowStructuralFallback
        -- The type arguments did not relate appropriately, but it may be because we have no variance
        -- information (in which case typeArgumentsRelatedTo defaulted to covariance for all type
        -- arguments). It might also be the case that the target type has a 'void' type argument for
        -- a covariant type parameter that is only used in return positions within the generic type
        -- (in which case any type argument is permitted on the source side). In those cases we proceed
        -- with a structural comparison. Otherwise, we know for certain the instantiations aren't
        -- related and we can return here.
        if core.Len(variances) ~= 0 and not allowStructuralFallback then
            -- In some cases generic types that are covariant in regular type checking mode become
            -- invariant in --strictFunctionTypes mode because one or more type parameters are used in
            -- both co- and contravariant positions. In order to make it easier to diagnose *why* such
            -- types are invariant, if any of the type parameters are invariant we reset the reported
            -- errors and instead force a structural comparison (which will include elaborations that
            -- reveal the reason).
            -- We can switch on `reportErrors` here, since varianceCheckFailed guarantees we return `False`,
            -- we can return `False` early here to skip calculating the structural error message we don't need.
            if varianceCheckFailed and not (reportErrors and core.Some(variances, function(v) return (v & VarianceFlags.VarianceMask) == VarianceFlags.Invariant end)) then
                return Ternary.False, true
            end
            -- We remember the original error information so we can restore it in case the structural
            -- comparison unexpectedly succeeds. This can happen when the structural comparison result
            -- is a Ternary.Maybe for example caused by the recursion depth limiter.
            originalErrorChain = r.errorChain
            r:restoreErrorState(saveErrorState)
        end
        return Ternary.False, false
    end
    if r.relation == c.identityRelation then
        -- We've already checked that source.flags and target.flags are identical
        if source.flags & TypeFlags.UnionOrIntersection ~= 0 then
            local result_ = r:eachTypeRelatedToSomeType(source, target)
            if result_ ~= Ternary.False then
                result_ = result_ & r:eachTypeRelatedToSomeType(target, source)
            end
            return result_
        elseif source.flags & TypeFlags.Index ~= 0 then
            return r:isRelatedTo(source:Target(), target:Target(), RecursionFlags.Both, false --[[reportErrors]])
        elseif source.flags & TypeFlags.IndexedAccess ~= 0 then
            result = r:isRelatedTo(source:AsIndexedAccessType().objectType, target:AsIndexedAccessType().objectType, RecursionFlags.Both, false --[[reportErrors]])
            if result ~= Ternary.False then
                result = result & r:isRelatedTo(source:AsIndexedAccessType().indexType, target:AsIndexedAccessType().indexType, RecursionFlags.Both, false --[[reportErrors]])
                if result ~= Ternary.False then
                    return result
                end
            end
        elseif source.flags & TypeFlags.Conditional ~= 0 then
            if source:AsConditionalType().root.isDistributive == target:AsConditionalType().root.isDistributive then
                result = r:isRelatedTo(source:AsConditionalType().checkType, target:AsConditionalType().checkType, RecursionFlags.Both, false --[[reportErrors]])
                if result ~= Ternary.False then
                    result = result & r:isRelatedTo(source:AsConditionalType().extendsType, target:AsConditionalType().extendsType, RecursionFlags.Both, false --[[reportErrors]])
                    if result ~= Ternary.False then
                        result = result & r:isRelatedTo(c:getTrueTypeFromConditionalType(source), c:getTrueTypeFromConditionalType(target), RecursionFlags.Both, false --[[reportErrors]])
                        if result ~= Ternary.False then
                            result = result & r:isRelatedTo(c:getFalseTypeFromConditionalType(source), c:getFalseTypeFromConditionalType(target), RecursionFlags.Both, false --[[reportErrors]])
                            if result ~= Ternary.False then
                                return result
                            end
                        end
                    end
                end
            end
        elseif source.flags & TypeFlags.Substitution ~= 0 then
            result = r:isRelatedTo(source:AsSubstitutionType().baseType, target:AsSubstitutionType().baseType, RecursionFlags.Both, false --[[reportErrors]])
            if result ~= Ternary.False then
                result = result & r:isRelatedTo(source:AsSubstitutionType().constraint, target:AsSubstitutionType().constraint, RecursionFlags.Both, false --[[reportErrors]])
                if result ~= Ternary.False then
                    return result
                end
            end
        elseif source.flags & TypeFlags.TemplateLiteral ~= 0 then
            if stringSlicesEqual(source:AsTemplateLiteralType().texts, target:AsTemplateLiteralType().texts) then
                result = Ternary.True
                for i, sourceType in ipairs(source:AsTemplateLiteralType().types) do
                    local targetType = target:AsTemplateLiteralType().types[i]
                    result = result & r:isRelatedTo(sourceType, targetType, RecursionFlags.Both, false --[[reportErrors]])
                    if result == Ternary.False then
                        return result
                    end
                end
                return result
            end
        elseif source.flags & TypeFlags.StringMapping ~= 0 then
            if source:AsStringMappingType():Symbol() == target:AsStringMappingType():Symbol() then
                return r:isRelatedTo(source:AsStringMappingType().target, target:AsStringMappingType().target, RecursionFlags.Both, false --[[reportErrors]])
            end
        end
        if source.flags & TypeFlags.Object == 0 then
            return Ternary.False
        end
    elseif source.flags & TypeFlags.UnionOrIntersection ~= 0 or target.flags & TypeFlags.UnionOrIntersection ~= 0 then
        result = r:unionOrIntersectionRelatedTo(source, target, reportErrors, intersectionState)
        if result ~= Ternary.False then
            return result
        end
        -- The ordered decomposition above doesn't handle all cases. Specifically, we also need to handle:
        -- Source is instantiable (e.g. source has union or intersection constraint).
        -- Source is an object, target is a union (e.g. { a, b: boolean } <=> { a, b: true } | { a, b: false }).
        -- Source is an intersection, target is an object (e.g. { a } & { b } <=> { a, b }).
        -- Source is an intersection, target is a union (e.g. { a } & { b: boolean } <=> { a, b: true } | { a, b: false }).
        -- Source is an intersection, target instantiable (e.g. string & { tag } <=> T["a"] constrained to string & { tag }).
        if not (source.flags & TypeFlags.Instantiable ~= 0 or
            source.flags & TypeFlags.Object ~= 0 and target.flags & TypeFlags.Union ~= 0 or
            source.flags & TypeFlags.Intersection ~= 0 and target.flags & (TypeFlags.Object | TypeFlags.Union | TypeFlags.Instantiable) ~= 0) then
            return Ternary.False
        end
    end
    -- We limit alias variance probing to only object and conditional types since their alias behavior
    -- is more predictable than other, interned types, which may or may not have an alias depending on
    -- the order in which things were checked.
    if source.flags & (TypeFlags.Object | TypeFlags.Conditional) ~= 0 and source.alias ~= nil and core.Len(source.alias.typeArguments) ~= 0 and
        target.alias ~= nil and source.alias.symbol == target.alias.symbol and not (c:isMarkerType(source) or c:isMarkerType(target)) then
        local variances = c:getAliasVariances(source.alias.symbol)
        if core.Len(variances) == 0 then
            return Ternary.Unknown
        end
        local params = c.typeAliasLinks:Get(source.alias.symbol).typeParameters
        local minParams = c:getMinTypeArgumentCount(params)
        local nodeIsInJsFile = ast.IsInJSFile(source.alias.symbol.valueDeclaration)
        local sourceTypes = c:fillMissingTypeArguments(source.alias.typeArguments, params, minParams, nodeIsInJsFile)
        local targetTypes = c:fillMissingTypeArguments(target.alias.typeArguments, params, minParams, nodeIsInJsFile)
        local varianceResult, ok = relateVariances(sourceTypes, targetTypes, variances, intersectionState)
        if ok then
            return varianceResult
        end
    end
    -- For a generic type T and a type U that is assignable to T, [...U] is assignable to T, U is assignable to readonly [...T],
    -- and U is assignable to [...T] when U is constrained to a mutable array or tuple type.
    if checker.isSingleElementGenericTupleType(source) and not source:TargetTupleType().readonly then
        result = r:isRelatedTo(c:getTypeArguments(source)[1], target, RecursionFlags.Source, false --[[reportErrors]])
        if result ~= Ternary.False then
            return result
        end
    end
    if checker.isSingleElementGenericTupleType(target) and (target:TargetTupleType().readonly or c:isMutableArrayOrTuple(c:getBaseConstraintOrType(source))) then
        result = r:isRelatedTo(source, c:getTypeArguments(target)[1], RecursionFlags.Target, false --[[reportErrors]])
        if result ~= Ternary.False then
            return result
        end
    end
    if target.flags & TypeFlags.TypeParameter ~= 0 then
        -- A source type { [P in Q]: X } is related to a target type T if keyof T is related to Q and X is related to T[Q].
        if source.objectFlags & ObjectFlags.Mapped ~= 0 and source:AsMappedType().declaration.nameType == nil and r:isRelatedTo(c:getIndexType(target), c:getConstraintTypeFromMappedType(source), RecursionFlags.Both, false) ~= Ternary.False then
            if checker.getMappedTypeModifiers(source) & MappedTypeModifiers.IncludeOptional == 0 then
                local templateType = c:getTemplateTypeFromMappedType(source)
                local indexedAccessType = c:getIndexedAccessType(target, c:getTypeParameterFromMappedType(source))
                result = r:isRelatedTo(templateType, indexedAccessType, RecursionFlags.Both, reportErrors)
                if result ~= Ternary.False then
                    return result
                end
            end
        end
        if r.relation == c.comparableRelation and source.flags & TypeFlags.TypeParameter ~= 0 then
            -- This is a carve-out in comparability to essentially forbid comparing a type parameter with another type parameter
            -- unless one extends the other. (Remember: comparability is mostly bidirectional!)
            local constraint = c:getConstraintOfTypeParameter(source)
            if constraint ~= nil and checker.someType(constraint, function(t) return t.flags & TypeFlags.TypeParameter ~= 0 end) then
                return r:isRelatedTo(constraint, target, RecursionFlags.Source, false --[[reportErrors]])
            end
            return Ternary.False
        end
    elseif target.flags & TypeFlags.IndexedAccess ~= 0 then
        if source.flags & TypeFlags.IndexedAccess ~= 0 then
            -- Relate components directly before falling back to constraint relationships
            -- A type S[K] is related to a type T[J] if S is related to T and K is related to J.
            result = r:isRelatedTo(source:AsIndexedAccessType().objectType, target:AsIndexedAccessType().objectType, RecursionFlags.Both, reportErrors)
            if result ~= Ternary.False then
                result = result & r:isRelatedTo(source:AsIndexedAccessType().indexType, target:AsIndexedAccessType().indexType, RecursionFlags.Both, reportErrors)
            end
            if result ~= Ternary.False then
                return result
            end
            if reportErrors then
                originalErrorChain = r.errorChain
            end
        end
        -- A type S is related to a type T[K] if S is related to C, where C is the base
        -- constraint of T[K] for writing.
        if r.relation == c.assignableRelation or r.relation == c.comparableRelation then
            local objectType = target:AsIndexedAccessType().objectType
            local indexType = target:AsIndexedAccessType().indexType
            local baseObjectType = c:getBaseConstraintOrType(objectType)
            local baseIndexType = c:getBaseConstraintOrType(indexType)
            if not c:isGenericObjectType(baseObjectType) and not c:isGenericIndexType(baseIndexType) then
                local accessFlags = AccessFlags.Writing | core.IfElse(baseObjectType ~= objectType, AccessFlags.NoIndexSignatures, 0)
                local constraint = c:getIndexedAccessTypeOrUndefined(baseObjectType, baseIndexType, accessFlags, nil, nil)
                if constraint ~= nil then
                    if reportErrors and originalErrorChain ~= nil then
                        -- create a new chain for the constraint error
                        r:restoreErrorState(saveErrorState)
                    end
                    result = r:isRelatedToEx(source, constraint, RecursionFlags.Target, reportErrors, nil --[[headMessage]], intersectionState)
                    if result ~= Ternary.False then
                        return result
                    end
                    -- prefer the shorter chain of the constraint comparison chain, and the direct comparison chain
                    if reportErrors and originalErrorChain ~= nil and r.errorChain ~= nil then
                        if checker.chainDepth(originalErrorChain) <= checker.chainDepth(r.errorChain) then
                            r.errorChain = originalErrorChain
                        end
                    end
                end
            end
        end
        if reportErrors then
            originalErrorChain = nil
        end
    elseif target.flags & TypeFlags.Index ~= 0 then
        local targetType = target:AsIndexType().target
        -- A keyof S is related to a keyof T if T is related to S.
        if source.flags & TypeFlags.Index ~= 0 then
            result = r:isRelatedTo(targetType, source:AsIndexType().target, RecursionFlags.Both, false --[[reportErrors]])
            if result ~= Ternary.False then
                return result
            end
        end
        if checker.isTupleType(targetType) then
            -- An index type can have a tuple type target when the tuple type contains variadic elements.
            -- Check if the source is related to the known keys of the tuple type.
            result = r:isRelatedTo(source, c:getKnownKeysOfTupleType(targetType), RecursionFlags.Target, reportErrors)
            if result ~= Ternary.False then
                return result
            end
        else
            -- A type S is assignable to keyof T if S is assignable to keyof C, where C is the
            -- simplified form of T or, if T doesn't simplify, the constraint of T.
            local constraint = c:getSimplifiedTypeOrConstraint(targetType)
            if constraint ~= nil then
                -- We require Ternary.True here such that circular constraints don't cause
                -- false positives. For example, given 'T extends { [K in keyof T]: string }',
                -- 'keyof T' has itself as its constraint and produces a Ternary.Maybe when
                -- related to other types.
                if r:isRelatedTo(source, c:getIndexTypeEx(constraint, target:AsIndexType().indexFlags | IndexFlags.NoReducibleCheck), RecursionFlags.Target, reportErrors) == Ternary.True then
                    return Ternary.True
                end
            elseif c:isGenericMappedType(targetType) then
                -- generic mapped types that don't simplify or have a constraint still have a very simple set of keys we can compare against
                -- - their nameType or constraintType.
                -- In many ways, this comparison is a deferred version of what `getIndexTypeForMappedType` does to actually resolve the keys for _non_-generic types
                local nameType = c:getNameTypeFromMappedType(targetType)
                local constraintType = c:getConstraintTypeFromMappedType(targetType)
                local targetKeys
                if nameType ~= nil and c:isMappedTypeWithKeyofConstraintDeclaration(targetType) then
                    -- we need to get the apparent mappings and union them with the generic mappings, since some properties may be
                    -- missing from the `constraintType` which will otherwise be mapped in the object
                    local mappedKeys = c:getApparentMappedTypeKeys(nameType, targetType)
                    -- We still need to include the non-apparent (and thus still generic) keys in the target side of the comparison (in case they're in the source side)
                    targetKeys = c:getUnionType({ mappedKeys, nameType })
                elseif nameType ~= nil then
                    targetKeys = nameType
                else
                    targetKeys = constraintType
                end
                if r:isRelatedTo(source, targetKeys, RecursionFlags.Target, reportErrors) == Ternary.True then
                    return Ternary.True
                end
            end
        end
    elseif target.flags & TypeFlags.Conditional ~= 0 then
        -- If we reach 10 levels of nesting for the same conditional type, assume it is an infinitely expanding recursive
        -- conditional type and bail out with a Ternary.Maybe result.
        if c:isDeeplyNestedType(target, r.targetStack, 10) then
            return Ternary.Maybe
        end
        local ct = target:AsConditionalType()
        -- We check for a relationship to a conditional type target only when the conditional type has no
        -- 'infer' positions, is not distributive or is distributive but doesn't reference the check type
        -- parameter in either of the result types, and the source isn't an instantiation of the same
        -- conditional type (as happens when computing variance).
        if ct.root.inferTypeParameters == nil and not c:isDistributionDependent(ct.root) and not (source.flags & TypeFlags.Conditional ~= 0 and source:AsConditionalType().root == ct.root) then
            -- Check if the conditional is always true or always false but still deferred for distribution purposes.
            local skipTrue = not c:isTypeAssignableTo(c:getPermissiveInstantiation(ct.checkType), c:getPermissiveInstantiation(ct.extendsType))
            local skipFalse = not skipTrue and c:isTypeAssignableTo(c:getRestrictiveInstantiation(ct.checkType), c:getRestrictiveInstantiation(ct.extendsType))
            -- TODO: Find a nice way to include potential conditional type breakdowns in error output, if they seem good (they usually don't)
            if skipTrue then
                result = Ternary.True
            else
                result = r:isRelatedToEx(source, c:getTrueTypeFromConditionalType(target), RecursionFlags.Target, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
            end
            if result ~= Ternary.False then
                if skipFalse then
                    result = result & Ternary.True
                else
                    result = result & r:isRelatedToEx(source, c:getFalseTypeFromConditionalType(target), RecursionFlags.Target, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
                end
                if result ~= Ternary.False then
                    return result
                end
            end
        end
    elseif target.flags & TypeFlags.TemplateLiteral ~= 0 then
        if source.flags & TypeFlags.TemplateLiteral ~= 0 then
            if r.relation == c.comparableRelation then
                if c:templateLiteralTypesDefinitelyUnrelated(source:AsTemplateLiteralType(), target:AsTemplateLiteralType()) then
                    return Ternary.False
                end
                return Ternary.True
            end
            -- Report unreliable variance for type variables referenced in template literal type placeholders.
            -- For example, `foo-${number}` is related to `foo-${string}` even though number isn't related to string.
            c:instantiateType(source, c.reportUnreliableMapper)
        end
        if c:isTypeMatchedByTemplateLiteralType(source, target:AsTemplateLiteralType(), r.isRelatedToWorkerFn) then
            return Ternary.True
        end
    elseif target.flags & TypeFlags.StringMapping ~= 0 then
        if source.flags & TypeFlags.StringMapping == 0 then
            if c:isMemberOfStringMapping(source, target) then
                return Ternary.True
            end
        end
    elseif c:isGenericMappedType(target) and r.relation ~= c.identityRelation then
        -- Check if source type `S` is related to target type `{ [P in Q]: T }` or `{ [P in Q as R]: T}`.
        local keysRemapped = target:AsMappedType().declaration.nameType ~= nil
        local templateType = c:getTemplateTypeFromMappedType(target)
        local modifiers = checker.getMappedTypeModifiers(target)
        if modifiers & MappedTypeModifiers.ExcludeOptional == 0 then
            -- If the mapped type has shape `{ [P in Q]: T[P] }`,
            -- source `S` is related to target if `T` = `S`, i.e. `S` is related to `{ [P in Q]: S[P] }`.
            if not keysRemapped and templateType.flags & TypeFlags.IndexedAccess ~= 0 and templateType:AsIndexedAccessType().objectType == source and templateType:AsIndexedAccessType().indexType == c:getTypeParameterFromMappedType(target) then
                return Ternary.True
            end
            if not c:isGenericMappedType(source) then
                -- If target has shape `{ [P in Q as R]: T}`, then its keys have type `R`.
                -- If target has shape `{ [P in Q]: T }`, then its keys have type `Q`.
                local targetKeys
                if keysRemapped then
                    targetKeys = c:getNameTypeFromMappedType(target)
                else
                    targetKeys = c:getConstraintTypeFromMappedType(target)
                end
                -- Type of the keys of source type `S`, i.e. `keyof S`.
                local sourceKeys = c:getIndexTypeEx(source, IndexFlags.NoIndexSignatures)
                local includeOptional = modifiers & MappedTypeModifiers.IncludeOptional ~= 0
                local filteredByApplicability
                if includeOptional then
                    filteredByApplicability = c:intersectTypes(targetKeys, sourceKeys)
                end
                -- A source type `S` is related to a target type `{ [P in Q]: T }` if `Q` is related to `keyof S` and `S[Q]` is related to `T`.
                -- A source type `S` is related to a target type `{ [P in Q as R]: T }` if `R` is related to `keyof S` and `S[R]` is related to `T.
                -- A source type `S` is related to a target type `{ [P in Q]?: T }` if some constituent `Q'` of `Q` is related to `keyof S` and `S[Q']` is related to `T`.
                -- A source type `S` is related to a target type `{ [P in Q as R]?: T }` if some constituent `R'` of `R` is related to `keyof S` and `S[R']` is related to `T`.
                if includeOptional and filteredByApplicability.flags & TypeFlags.Never == 0 or not includeOptional and r:isRelatedTo(targetKeys, sourceKeys, RecursionFlags.Both, false) ~= Ternary.False then
                    local templateType_ = c:getTemplateTypeFromMappedType(target)
                    local typeParameter = c:getTypeParameterFromMappedType(target)
                    -- Fastpath: When the template type has the form `Obj[P]` where `P` is the mapped type parameter, directly compare source `S` with `Obj`
                    -- to avoid creating the (potentially very large) number of new intermediate types made by manufacturing `S[P]`.
                    local nonNullComponent = c:extractTypesOfKind(templateType_, ~TypeFlags.Nullable)
                    if not keysRemapped and nonNullComponent.flags & TypeFlags.IndexedAccess ~= 0 and nonNullComponent:AsIndexedAccessType().indexType == typeParameter then
                        result = r:isRelatedTo(source, nonNullComponent:AsIndexedAccessType().objectType, RecursionFlags.Target, reportErrors)
                        if result ~= Ternary.False then
                            return result
                        end
                    else
                        -- We need to compare the type of a property on the source type `S` to the type of the same property on the target type,
                        -- so we need to construct an indexing type representing a property, and then use indexing type to index the source type for comparison.
                        -- If the target type has shape `{ [P in Q]: T }`, then a property of the target has type `P`.
                        -- If the target type has shape `{ [P in Q]?: T }`, then a property of the target has type `P`,
                        -- but the property is optional, so we only want to compare properties `P` that are common between `keyof S` and `Q`.
                        -- If the target type has shape `{ [P in Q as R]: T }`, then a property of the target has type `R`.
                        -- If the target type has shape `{ [P in Q as R]?: T }`, then a property of the target has type `R`,
                        -- but the property is optional, so we only want to compare properties `R` that are common between `keyof S` and `R`.
                        local indexingType = typeParameter
                        if keysRemapped then
                            indexingType = filteredByApplicability or targetKeys
                        elseif filteredByApplicability ~= nil then
                            indexingType = c:getIntersectionType({ filteredByApplicability, typeParameter })
                        end
                        local indexedAccessType = c:getIndexedAccessType(source, indexingType)
                        -- Compare `S[indexingType]` to `T`, where `T` is the type of a property of the target type.
                        result = r:isRelatedTo(indexedAccessType, templateType_, RecursionFlags.Both, reportErrors)
                        if result ~= Ternary.False then
                            return result
                        end
                    end
                end
                originalErrorChain = r.errorChain
                r:restoreErrorState(saveErrorState)
            end
        end
    end
    if source.flags & TypeFlags.TypeVariable ~= 0 then
        -- IndexedAccess comparisons are handled above in the `target.flags&TypeFlagsIndexedAccess` branch
        if source.flags & TypeFlags.IndexedAccess == 0 or target.flags & TypeFlags.IndexedAccess == 0 then
            local constraint = c:getConstraintOfType(source)
            if constraint == nil then
                constraint = c.unknownType
            end
            -- hi-speed no-this-instantiation check (less accurate, but avoids costly `this`-instantiation when the constraint will suffice), see #28231 for report on why this is needed
            result = r:isRelatedToEx(constraint, target, RecursionFlags.Source, false --[[reportErrors]], nil --[[headMessage]], intersectionState)
            if result ~= Ternary.False then
                return result
            end
            local constraintWithThis = c:getTypeWithThisArgument(constraint, source, false --[[needApparentType]])
            result = r:isRelatedToEx(constraintWithThis, target, RecursionFlags.Source, reportErrors and constraint ~= c.unknownType and target.flags & source.flags & TypeFlags.TypeParameter == 0, nil --[[headMessage]], intersectionState)
            if result ~= Ternary.False then
                return result
            end
            if c:isMappedTypeGenericIndexedAccess(source) then
                -- For an indexed access type { [P in K]: E}[X], above we have already explored an instantiation of E with X
                -- substituted for P. We also want to explore type { [P in K]: E }[C], where C is the constraint of X.
                local indexConstraint = c:getConstraintOfType(source:AsIndexedAccessType().indexType)
                if indexConstraint ~= nil then
                    result = r:isRelatedTo(c:getIndexedAccessType(source:AsIndexedAccessType().objectType, indexConstraint), target, RecursionFlags.Source, reportErrors)
                    if result ~= Ternary.False then
                        return result
                    end
                end
            end
        end
    elseif source.flags & TypeFlags.Index ~= 0 then
        local isDeferredMappedIndex = c:shouldDeferIndexType(source:AsIndexType().target, source:AsIndexType().indexFlags) and source:AsIndexType().target.objectFlags & ObjectFlags.Mapped ~= 0
        result = r:isRelatedTo(c.stringNumberSymbolType, target, RecursionFlags.Source, reportErrors and not isDeferredMappedIndex)
        if result ~= Ternary.False then
            return result
        end
        if isDeferredMappedIndex then
            local mappedType = source:AsIndexType().target
            local nameType = c:getNameTypeFromMappedType(mappedType)
            -- Unlike on the target side, on the source side we do *not* include the generic part of the `nameType`, since that comes from a
            -- (potentially anonymous) mapped type local type parameter, so that'd never assign outside the mapped type body, but we still want to
            -- allow assignments of index types of identical (or similar enough) mapped types.
            -- eg, `keyof {[X in keyof A]: Obj[X]}` should be assignable to `keyof {[Y in keyof A]: Tup[Y]}` because both map over the same set of keys (`keyof A`).
            -- Without this source-side breakdown, a `keyof {[X in keyof A]: Obj[X]}` style type won't be assignable to anything except itself, which is much too strict.
            local sourceMappedKeys
            if nameType ~= nil and c:isMappedTypeWithKeyofConstraintDeclaration(mappedType) then
                sourceMappedKeys = c:getApparentMappedTypeKeys(nameType, mappedType)
            elseif nameType ~= nil then
                sourceMappedKeys = nameType
            else
                sourceMappedKeys = c:getConstraintTypeFromMappedType(mappedType)
            end
            result = r:isRelatedTo(sourceMappedKeys, target, RecursionFlags.Source, reportErrors)
            if result ~= Ternary.False then
                return result
            end
        end
    elseif source.flags & TypeFlags.Conditional ~= 0 then
        -- If we reach 10 levels of nesting for the same conditional type, assume it is an infinitely expanding recursive
        -- conditional type and bail out with a Ternary.Maybe result.
        if c:isDeeplyNestedType(source, r.sourceStack, 10) then
            return Ternary.Maybe
        end
        if target.flags & TypeFlags.Conditional ~= 0 then
            -- Two conditional types 'T1 extends U1 ? X1 : Y1' and 'T2 extends U2 ? X2 : Y2' are related if
            -- one of T1 and T2 is related to the other, U1 and U2 are identical types, X1 is related to X2,
            -- and Y1 is related to Y2.
            local sourceParams = source:AsConditionalType().root.inferTypeParameters
            local sourceExtends = source:AsConditionalType().extendsType
            local mapper
            if core.Len(sourceParams) ~= 0 then
                -- If the source has infer type parameters, we instantiate them in the context of the target
                local ctx = c:newInferenceContext(sourceParams, nil --[[signature]], InferenceFlags.None, r.isRelatedToWorkerFn)
                c:inferTypes(ctx.inferences, target:AsConditionalType().extendsType, sourceExtends, InferencePriority.NoConstraints | InferencePriority.AlwaysStrict, false)
                sourceExtends = c:instantiateType(sourceExtends, ctx.mapper)
                mapper = ctx.mapper
            end
            if c:isTypeIdenticalTo(sourceExtends, target:AsConditionalType().extendsType) and (r:isRelatedTo(source:AsConditionalType().checkType, target:AsConditionalType().checkType, RecursionFlags.Both, false) ~= 0 or r:isRelatedTo(target:AsConditionalType().checkType, source:AsConditionalType().checkType, RecursionFlags.Both, false) ~= 0) then
                result = r:isRelatedTo(c:instantiateType(c:getTrueTypeFromConditionalType(source), mapper), c:getTrueTypeFromConditionalType(target), RecursionFlags.Both, reportErrors)
                if result ~= Ternary.False then
                    result = result & r:isRelatedTo(c:getFalseTypeFromConditionalType(source), c:getFalseTypeFromConditionalType(target), RecursionFlags.Both, reportErrors)
                end
                if result ~= Ternary.False then
                    return result
                end
            end
        end
        -- conditionals can be related to one another via normal constraint, as, eg, `A extends B ? O : never` should be assignable to `O`
        -- when `O` is a conditional (`never` is trivially assignable to `O`, as is `O`!).
        local defaultConstraint = c:getDefaultConstraintOfConditionalType(source)
        if defaultConstraint ~= nil then
            result = r:isRelatedTo(defaultConstraint, target, RecursionFlags.Source, reportErrors)
            if result ~= Ternary.False then
                return result
            end
        end
        -- conditionals aren't related to one another via distributive constraint as it is much too inaccurate and allows way
        -- more assignments than are desirable (since it maps the source check type to its constraint, it loses information).
        if target.flags & TypeFlags.Conditional == 0 and c:hasNonCircularBaseConstraint(source) then
            local distributiveConstraint = c:getConstraintOfDistributiveConditionalType(source)
            if distributiveConstraint ~= nil then
                r:restoreErrorState(saveErrorState)
                result = r:isRelatedTo(distributiveConstraint, target, RecursionFlags.Source, reportErrors)
                if result ~= Ternary.False then
                    return result
                end
            end
        end
    elseif source.flags & TypeFlags.TemplateLiteral ~= 0 and target.flags & TypeFlags.Object == 0 then
        if target.flags & TypeFlags.TemplateLiteral == 0 then
            local constraint = c:getBaseConstraintOfType(source)
            if constraint ~= nil and constraint ~= source then
                result = r:isRelatedTo(constraint, target, RecursionFlags.Source, reportErrors)
                if result ~= Ternary.False then
                    return result
                end
            end
        end
    elseif source.flags & TypeFlags.StringMapping ~= 0 then
        if target.flags & TypeFlags.StringMapping ~= 0 then
            if source:AsStringMappingType().symbol ~= target:AsStringMappingType().symbol then
                return Ternary.False
            end
            result = r:isRelatedTo(source:AsStringMappingType().target, target:AsStringMappingType().target, RecursionFlags.Both, reportErrors)
            if result ~= Ternary.False then
                return result
            end
        else
            local constraint = c:getBaseConstraintOfType(source)
            if constraint ~= nil then
                result = r:isRelatedTo(constraint, target, RecursionFlags.Source, reportErrors)
                if result ~= Ternary.False then
                    return result
                end
            end
        end
    else
        -- An empty object type is related to any mapped type that includes a '?' modifier.
        if r.relation ~= c.subtypeRelation and r.relation ~= c.strictSubtypeRelation and checker.isPartialMappedType(target) and c:isEmptyObjectType(source) then
            return Ternary.True
        end
        if c:isGenericMappedType(target) then
            if c:isGenericMappedType(source) then
                result = r:mappedTypeRelatedTo(source, target, reportErrors)
                if result ~= Ternary.False then
                    return result
                end
            end
            return Ternary.False
        end
        local sourceIsPrimitive = source.flags & TypeFlags.Primitive ~= 0
        if r.relation ~= c.identityRelation then
            source = c:getApparentType(source)
        elseif c:isGenericMappedType(source) then
            return Ternary.False
        end
        if source.objectFlags & ObjectFlags.Reference ~= 0 and target.objectFlags & ObjectFlags.Reference ~= 0 and source:Target() == target:Target() and not checker.isTupleType(source) and not c:isMarkerType(source) and not c:isMarkerType(target) then
            -- When strictNullChecks is disabled, the element type of the empty array literal is undefinedWideningType,
            -- and an empty array literal wouldn't be assignable to a `never[]` without this check.
            if c:isEmptyArrayLiteralType(source) then
                return Ternary.True
            end
            -- We have type references to the same generic type, and the type references are not marker
            -- type references (which are intended by be compared structurally). Obtain the variance
            -- information for the type parameters and relate the type arguments accordingly.
            local variances = c:getVariances(source:Target())
            -- We return Ternary.Maybe for a recursive invocation of getVariances (signaled by emptyArray). This
            -- effectively means we measure variance only from type parameter occurrences that aren't nested in
            -- recursive instantiations of the generic type.
            if core.Len(variances) == 0 then
                return Ternary.Unknown
            end
            local varianceResult, ok = relateVariances(c:getTypeArguments(source), c:getTypeArguments(target), variances, intersectionState)
            if ok then
                return varianceResult
            end
        elseif c:isArrayType(target) and (c:isReadonlyArrayType(target) and checker.everyType(source, function(t) return c:isArrayOrTupleType(t) end) or checker.everyType(source, checker.isMutableTupleType)) then
            if r.relation ~= c.identityRelation then
                return r:isRelatedTo(c:getIndexTypeOfTypeEx(source, c.numberType, c.anyType), c:getIndexTypeOfTypeEx(target, c.numberType, c.anyType), RecursionFlags.Both, reportErrors)
            end
            -- By flags alone, we know that the `target` is a readonly array while the source is a normal array or tuple
            -- or `target` is an array and source is a tuple - in both cases the types cannot be identical, by construction
            return Ternary.False
        elseif c:isGenericTupleType(source) and checker.isTupleType(target) and not c:isGenericTupleType(target) then
            local constraint = c:getBaseConstraintOrType(source)
            if constraint ~= source then
                return r:isRelatedTo(constraint, target, RecursionFlags.Source, reportErrors)
            end
        elseif (r.relation == c.subtypeRelation or r.relation == c.strictSubtypeRelation) and c:isEmptyObjectType(target) and target.objectFlags & ObjectFlags.FreshLiteral ~= 0 and not c:isEmptyObjectType(source) then
            return Ternary.False
        end
        -- Even if relationship doesn't hold for unions, intersections, or generic type references,
        -- it may hold in a structural comparison.
        -- In a check of the form X = A & B, we will have previously checked if A relates to X or B relates
        -- to X. Failing both of those we want to check if the aggregation of A and B's members structurally
        -- relates to X. Thus, we include intersection types on the source side here.
        if source.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 and target.flags & TypeFlags.Object ~= 0 then
            -- Report structural errors only if we haven't reported any errors yet
            local reportStructuralErrors = reportErrors and r.errorChain == saveErrorState.errorChain and not sourceIsPrimitive
            result = r:propertiesRelatedTo(source, target, reportStructuralErrors, nil --[[excludedProperties]], false --[[optionalsOnly]], intersectionState)
            if result ~= Ternary.False then
                result = result & r:signaturesRelatedTo(source, target, SignatureKind.Call, reportStructuralErrors, intersectionState)
                if result ~= Ternary.False then
                    result = result & r:signaturesRelatedTo(source, target, SignatureKind.Construct, reportStructuralErrors, intersectionState)
                    if result ~= Ternary.False then
                        result = result & r:indexSignaturesRelatedTo(source, target, sourceIsPrimitive, reportStructuralErrors, intersectionState)
                    end
                end
            end
            if result ~= Ternary.False then
                if not varianceCheckFailed then
                    return result
                end
                if originalErrorChain ~= nil then
                    r.errorChain = originalErrorChain
                elseif r.errorChain == nil then
                    r.errorChain = saveErrorState.errorChain
                end
                -- Use variance error (there is no structural one) and return false
            end
        end
        -- If S is an object type and T is a discriminated union, S may be related to T if
        -- there exists a constituent of T for every combination of the discriminants of S
        -- with respect to T. We do not report errors here, as we will use the existing
        -- error result from checking each constituent of the union.
        if source.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 and target.flags & TypeFlags.Union ~= 0 then
            local objectOnlyTarget = c:extractTypesOfKind(target, TypeFlags.Object | TypeFlags.Intersection | TypeFlags.Substitution)
            if objectOnlyTarget.flags & TypeFlags.Union ~= 0 then
                local result_ = r:typeRelatedToDiscriminatedType(source, objectOnlyTarget)
                if result_ ~= Ternary.False then
                    return result_
                end
            end
        end
    end
    return Ternary.False
end

function Relater:typeArgumentsRelatedTo(sources, targets, variances, reportErrors, intersectionState)
    local r = self
    local c = r.c
    if core.Len(sources) ~= core.Len(targets) and r.relation == c.identityRelation then
        return Ternary.False
    end
    local length = math.min(core.Len(sources), core.Len(targets))
    local result = Ternary.True
    for i = 0, length - 1 do
        -- When variance information isn't available we default to covariance. This happens
        -- in the process of computing variance information for recursive types and when
        -- comparing 'this' type arguments.
        local varianceFlags = VarianceFlags.Covariant
        if i < core.Len(variances) then
            varianceFlags = variances[i + 1]
        end
        local variance = varianceFlags & VarianceFlags.VarianceMask
        -- We ignore arguments for independent type parameters (because they're never witnessed).
        if variance ~= VarianceFlags.Independent then
            local s = sources[i + 1]
            local t = targets[i + 1]
            local related
            if varianceFlags & VarianceFlags.Unmeasurable ~= 0 then
                -- Even an `Unmeasurable` variance works out without a structural check if the source and target are _identical_.
                -- We can't simply assume invariance, because `Unmeasurable` marks nonlinear relations, for example, a relation tainted by
                -- the `-?` modifier in a mapped type (where, no matter how the inputs are related, the outputs still might not be)
                if r.relation == c.identityRelation then
                    related = r:isRelatedTo(s, t, RecursionFlags.Both, false --[[reportErrors]])
                else
                    related = c:compareTypesIdentical(s, t)
                end
            else
                -- Propagate unreliable variance flag in variance computations
                if #c.varianceStack ~= 0 and varianceFlags & VarianceFlags.Unreliable ~= 0 then
                    c:instantiateType(s, c.reportUnreliableMapper)
                end
                if variance == VarianceFlags.Covariant then
                    related = r:isRelatedToEx(s, t, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                elseif variance == VarianceFlags.Contravariant then
                    related = r:isRelatedToEx(t, s, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                elseif variance == VarianceFlags.Bivariant then
                    -- In the bivariant case we first compare contravariantly without reporting
                    -- errors. Then, if that doesn't succeed, we compare covariantly with error
                    -- reporting. Thus, error elaboration will be based on the covariant check,
                    -- which is generally easier to reason about.
                    related = r:isRelatedTo(t, s, RecursionFlags.Both, false --[[reportErrors]])
                    if related == Ternary.False then
                        related = r:isRelatedToEx(s, t, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                    end
                else
                    -- In the invariant case we first compare covariantly, and only when that
                    -- succeeds do we proceed to compare contravariantly. Thus, error elaboration
                    -- will typically be based on the covariant check.
                    related = r:isRelatedToEx(s, t, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                    if related ~= Ternary.False then
                        related = related & r:isRelatedToEx(t, s, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                    end
                end
            end
            if related == Ternary.False then
                return Ternary.False
            end
            result = result & related
        end
    end
    return result
end

-- A type [P in S]: X is related to a type [Q in T]: Y if T is related to S and X' is
-- related to Y, where X' is an instantiation of X in which P is replaced with Q. Notice
-- that S and T are contra-variant whereas X and Y are co-variant.
function Relater:mappedTypeRelatedTo(source, target, reportErrors)
    local r = self
    local c = r.c
    local modifiersRelated = r.relation == c.comparableRelation or
        r.relation == c.identityRelation and checker.getMappedTypeModifiers(source) == checker.getMappedTypeModifiers(target) or
        r.relation ~= c.identityRelation and c:getCombinedMappedTypeOptionality(source) <= c:getCombinedMappedTypeOptionality(target)
    if modifiersRelated then
        local targetConstraint = c:getConstraintTypeFromMappedType(target)
        local sourceConstraint = c:instantiateType(c:getConstraintTypeFromMappedType(source), core.IfElse(c:getCombinedMappedTypeOptionality(source) < 0, c.reportUnmeasurableMapper, c.reportUnreliableMapper))
        local result = r:isRelatedTo(targetConstraint, sourceConstraint, RecursionFlags.Both, reportErrors)
        if result ~= Ternary.False then
            local mapper = checker.newSimpleTypeMapper(c:getTypeParameterFromMappedType(source), c:getTypeParameterFromMappedType(target))
            if c:instantiateType(c:getNameTypeFromMappedType(source), mapper) == c:instantiateType(c:getNameTypeFromMappedType(target), mapper) then
                return result & r:isRelatedTo(c:instantiateType(c:getTemplateTypeFromMappedType(source), mapper), c:getTemplateTypeFromMappedType(target), RecursionFlags.Both, reportErrors)
            end
        end
    end
    return Ternary.False
end

function Relater:typeRelatedToDiscriminatedType(source, target)
    local r = self
    local c = r.c
    -- 1. Generate the combinations of discriminant properties & types 'source' can satisfy.
    --    a. If the number of combinations is above a set limit, the comparison is too complex.
    -- 2. Filter 'target' to the subset of types whose discriminants exist in the matrix.
    --    a. If 'target' does not satisfy all discriminants in the matrix, 'source' is not related.
    -- 3. For each type in the filtered 'target', determine if all non-discriminant properties of
    --    'target' are related to a property in 'source'.
    --
    -- NOTE: See ~/tests/cases/conformance/types/typeRelationships/assignmentCompatibility/assignmentCompatWithDiscriminatedUnion.ts
    --       for examples.
    local sourceProperties = c:getPropertiesOfType(source)
    local sourcePropertiesFiltered = c:findDiscriminantProperties(sourceProperties, target)
    if core.Len(sourcePropertiesFiltered) == 0 then
        return Ternary.False
    end
    -- Though we could compute the number of combinations as we generate
    -- the matrix, this would incur additional memory overhead due to
    -- array allocations. To reduce this overhead, we first compute
    -- the number of combinations to ensure we will not surpass our
    -- fixed limit before incurring the cost of any allocations:
    local numCombinations = 1
    for _, sourceProperty in ipairs(sourcePropertiesFiltered) do
        numCombinations = numCombinations * checker.countTypes(c:getNonMissingTypeOfSymbol(sourceProperty))
        if numCombinations > 25 then
            local tr = c.tracer
            if tr ~= nil then
                tr:Instant(tracing.PhaseCheckTypes, "typeRelatedToDiscriminatedType_DepthLimit", { sourceId = source.id, targetId = target.id, numCombinations = numCombinations })
            end
            return Ternary.False
        end
        if numCombinations == 0 then
            return Ternary.False
        end
    end
    -- Compute the set of types for each discriminant property.
    local sourceDiscriminantTypes = {}
    local excludedProperties = collections.NewSet()
    for i, sourceProperty in ipairs(sourcePropertiesFiltered) do
        local sourcePropertyType = c:getNonMissingTypeOfSymbol(sourceProperty)
        sourceDiscriminantTypes[i] = sourcePropertyType:Distributed() or {}
        excludedProperties:Add(sourceProperty.name)
    end
    -- Build the cartesian product
    local discriminantCombinations = {}
    for i = 0, numCombinations - 1 do
        local combination = {}
        local n = i
        for j = #sourceDiscriminantTypes - 1, 0, -1 do
            local sourceTypes = sourceDiscriminantTypes[j + 1]
            local length = #sourceTypes
            combination[j + 1] = sourceTypes[n % length + 1]
            n = n // length
        end
        discriminantCombinations[i + 1] = combination
    end
    -- Match each combination of the cartesian product of discriminant properties to one or more
    -- constituents of 'target'. If any combination does not have a match then 'source' is not relatable.
    local matchingTypes
    for _, combination in ipairs(discriminantCombinations) do
        local hasMatch = false
        for _, t in ipairs(target:Types()) do
            for i, sourceProperty in ipairs(sourcePropertiesFiltered) do
                local targetProperty = c:getPropertyOfType(t, sourceProperty.name)
                if targetProperty == nil then
                    goto continue_outer
                end
                if sourceProperty == targetProperty then
                    goto continue_inner
                end
                do
                    -- We compare the source property to the target in the context of a single discriminant type.
                    local related = r:propertyRelatedTo(source, target, sourceProperty, targetProperty, function(_) return combination[i] end,
                        false --[[reportErrors]], IntersectionState.None, c.strictNullChecks or r.relation == c.comparableRelation --[[skipOptional]])
                    -- If the target property could not be found, or if the properties were not related,
                    -- then this constituent is not a match.
                    if related == Ternary.False then
                        goto continue_outer
                    end
                end
                ::continue_inner::
            end
            matchingTypes = core.AppendIfUnique(matchingTypes, t)
            hasMatch = true
            ::continue_outer::
        end
        if not hasMatch then
            -- We failed to match any type for this combination.
            return Ternary.False
        end
    end
    -- Compare the remaining non-discriminant properties of each match.
    local result = Ternary.True
    for _, t in ipairs(matchingTypes or {}) do
        result = result & r:propertiesRelatedTo(source, t, false --[[reportErrors]], excludedProperties, false --[[optionalsOnly]], IntersectionState.None)
        if result ~= Ternary.False then
            result = result & r:signaturesRelatedTo(source, t, SignatureKind.Call, false --[[reportErrors]], IntersectionState.None)
            if result ~= Ternary.False then
                result = result & r:signaturesRelatedTo(source, t, SignatureKind.Construct, false --[[reportErrors]], IntersectionState.None)
                if result ~= Ternary.False and not (checker.isTupleType(source) and checker.isTupleType(t)) then
                    -- Comparing numeric index types when both `source` and `type` are tuples is unnecessary as the
                    -- element types should be sufficiently covered by `propertiesRelatedTo`. It also causes problems
                    -- with index type assignability as the types for the excluded discriminants are still included
                    -- in the index type.
                    result = result & r:indexSignaturesRelatedTo(source, t, false --[[sourceIsPrimitive]], false --[[reportErrors]], IntersectionState.None)
                end
            end
        end
        if result == Ternary.False then
            return result
        end
    end
    return result
end

-- excludedProperties is a collections.Set or nil (Go's zero Set).
function Relater:propertiesRelatedTo(source, target, reportErrors, excludedProperties, optionalsOnly, intersectionState)
    local r = self
    local c = r.c
    if r.relation == c.identityRelation then
        return r:propertiesIdenticalTo(source, target, excludedProperties)
    end
    local result = Ternary.True
    if checker.isTupleType(target) then
        if c:isArrayOrTupleType(source) then
            if not target:TargetTupleType().readonly and (c:isReadonlyArrayType(source) or checker.isTupleType(source) and source:TargetTupleType().readonly) then
                return Ternary.False
            end
            local sourceArity = c:getTypeReferenceArity(source)
            local targetArity = c:getTypeReferenceArity(target)
            local sourceRest
            if checker.isTupleType(source) then
                sourceRest = source:TargetTupleType().combinedFlags & ElementFlags.Rest ~= 0
            else
                sourceRest = true
            end
            local targetHasRestElement = target:TargetTupleType().combinedFlags & ElementFlags.Rest ~= 0
            local targetHasVariableElement = target:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0
            local sourceMinLength
            if checker.isTupleType(source) then
                sourceMinLength = source:TargetTupleType().minLength
            else
                sourceMinLength = 0
            end
            local targetMinLength = target:TargetTupleType().minLength
            if not sourceRest and sourceArity < targetMinLength then
                if reportErrors then
                    r:reportError(diagnostics.Source_has_0_element_s_but_target_requires_1, sourceArity, targetMinLength)
                end
                return Ternary.False
            end
            if not targetHasVariableElement and targetArity < sourceMinLength then
                if reportErrors then
                    r:reportError(diagnostics.Source_has_0_element_s_but_target_allows_only_1, sourceMinLength, targetArity)
                end
                return Ternary.False
            end
            if not targetHasVariableElement and (sourceRest or targetArity < sourceArity) then
                if reportErrors then
                    if sourceMinLength < targetMinLength then
                        r:reportError(diagnostics.Target_requires_0_element_s_but_source_may_have_fewer, targetMinLength)
                    else
                        r:reportError(diagnostics.Target_allows_only_0_element_s_but_source_may_have_more, targetArity)
                    end
                end
                return Ternary.False
            end
            local sourceTypeArguments = c:getTypeArguments(source)
            local targetTypeArguments = c:getTypeArguments(target)
            local targetStartCount = checker.getStartElementCount(target:TargetTupleType(), ElementFlags.NonRest)
            local targetEndCount = checker.getEndElementCount(target:TargetTupleType(), ElementFlags.NonRest)
            local canExcludeDiscriminants = collections.Set.Len(excludedProperties) ~= 0
            for sourcePosition = 0, sourceArity - 1 do
                local sourceFlags
                if checker.isTupleType(source) then
                    sourceFlags = source:TargetTupleType().elementInfos[sourcePosition + 1].flags
                else
                    sourceFlags = ElementFlags.Rest
                end
                local sourcePositionFromEnd = sourceArity - 1 - sourcePosition
                local targetPosition
                if targetHasRestElement and sourcePosition >= targetStartCount then
                    targetPosition = targetArity - 1 - math.min(sourcePositionFromEnd, targetEndCount)
                else
                    if sourcePosition >= targetArity then
                        if reportErrors then
                            r:reportError(diagnostics.Target_allows_only_0_element_s_but_source_may_have_more, targetArity)
                        end
                        return Ternary.False
                    end
                    targetPosition = sourcePosition
                end
                local targetFlags = ElementFlags.None
                if targetPosition >= 0 then
                    targetFlags = target:TargetTupleType().elementInfos[targetPosition + 1].flags
                end
                if targetFlags & ElementFlags.Variadic ~= 0 and sourceFlags & ElementFlags.Variadic == 0 then
                    if reportErrors then
                        r:reportError(diagnostics.Source_provides_no_match_for_variadic_element_at_position_0_in_target, targetPosition)
                    end
                    return Ternary.False
                end
                if sourceFlags & ElementFlags.Variadic ~= 0 and targetFlags & ElementFlags.Variable == 0 then
                    if reportErrors then
                        r:reportError(diagnostics.Variadic_element_at_position_0_in_source_does_not_match_element_at_position_1_in_target, sourcePosition, targetPosition)
                    end
                    return Ternary.False
                end
                if targetFlags & ElementFlags.Required ~= 0 and sourceFlags & ElementFlags.Required == 0 then
                    if reportErrors then
                        r:reportError(diagnostics.Source_provides_no_match_for_required_element_at_position_0_in_target, targetPosition)
                    end
                    return Ternary.False
                end
                -- We can only exclude discriminant properties if we have not yet encountered a variable-length element.
                if canExcludeDiscriminants then
                    if sourceFlags & ElementFlags.Variable ~= 0 or targetFlags & ElementFlags.Variable ~= 0 then
                        canExcludeDiscriminants = false
                    end
                    if canExcludeDiscriminants and collections.Set.Has(excludedProperties, tostring(sourcePosition)) then
                        goto continue
                    end
                end
                do
                    local sourceType = c:removeMissingType(sourceTypeArguments[sourcePosition + 1], sourceFlags & targetFlags & ElementFlags.Optional ~= 0)
                    local targetType = targetTypeArguments[targetPosition + 1]
                    local targetCheckType
                    if sourceFlags & ElementFlags.Variadic ~= 0 and targetFlags & ElementFlags.Rest ~= 0 then
                        targetCheckType = c:createArrayType(targetType)
                    else
                        targetCheckType = c:removeMissingType(targetType, targetFlags & ElementFlags.Optional ~= 0)
                    end
                    local related = r:isRelatedToEx(sourceType, targetCheckType, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
                    if related == Ternary.False then
                        if reportErrors and (targetArity > 1 or sourceArity > 1) then
                            if targetHasRestElement and sourcePosition >= targetStartCount and sourcePositionFromEnd >= targetEndCount and targetStartCount ~= sourceArity - targetEndCount - 1 then
                                r:reportError(diagnostics.Type_at_positions_0_through_1_in_source_is_not_compatible_with_type_at_position_2_in_target, targetStartCount, sourceArity - targetEndCount - 1, targetPosition)
                            else
                                r:reportError(diagnostics.Type_at_position_0_in_source_is_not_compatible_with_type_at_position_1_in_target, sourcePosition, targetPosition)
                            end
                        end
                        return Ternary.False
                    end
                    result = result & related
                end
                ::continue::
            end
            return result
        end
        if target:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 then
            return Ternary.False
        end
    end
    local requireOptionalProperties = (r.relation == c.subtypeRelation or r.relation == c.strictSubtypeRelation) and not checker.isObjectLiteralType(source) and not c:isEmptyArrayLiteralType(source) and not checker.isTupleType(source)
    local unmatchedProperty = c:getUnmatchedProperty(source, target, requireOptionalProperties, false --[[matchDiscriminantProperties]])
    if unmatchedProperty ~= nil then
        if reportErrors and c:shouldReportUnmatchedPropertyError(source, target) then
            r:reportUnmatchedProperty(source, target, unmatchedProperty, requireOptionalProperties)
        end
        return Ternary.False
    end
    if checker.isObjectLiteralType(target) then
        for _, sourceProp in ipairs(checker.excludeProperties(c:getPropertiesOfType(source), excludedProperties) or {}) do
            if c:getPropertyOfObjectType(target, sourceProp.name) == nil then
                if reportErrors then
                    r:reportError(diagnostics.Property_0_does_not_exist_on_type_1, c:symbolToString(sourceProp), c:TypeToString(target))
                end
                return Ternary.False
            end
        end
    end
    -- We only call this for union target types when we're attempting to do excess property checking - in those cases, we want to get _all possible props_
    -- from the target union, across all members
    local properties = c:getPropertiesOfType(target)
    local numericNamesOnly = checker.isTupleType(source) and checker.isTupleType(target)
    for _, targetProp in ipairs(checker.excludeProperties(properties, excludedProperties) or {}) do
        local name = targetProp.name
        if targetProp.flags & SymbolFlags.Prototype == 0 and (not numericNamesOnly or checker.isNumericLiteralName(name) or name == "length") and (not optionalsOnly or targetProp.flags & SymbolFlags.Optional ~= 0) then
            local sourceProp = c:getPropertyOfType(source, name)
            if sourceProp ~= nil and sourceProp ~= targetProp then
                local related = r:propertyRelatedTo(source, target, sourceProp, targetProp, function(s) return c:getNonMissingTypeOfSymbol(s) end, reportErrors, intersectionState, r.relation == c.comparableRelation)
                if related == Ternary.False then
                    return Ternary.False
                end
                result = result & related
            end
        end
    end
    return result
end

function Relater:propertyRelatedTo(source, target, sourceProp, targetProp, getTypeOfSourceProperty, reportErrors, intersectionState, skipOptional)
    local r = self
    local c = r.c
    local sourcePropFlags = checker.getDeclarationModifierFlagsFromSymbol(sourceProp)
    local targetPropFlags = checker.getDeclarationModifierFlagsFromSymbol(targetProp)
    if sourcePropFlags & ModifierFlags.Private ~= 0 or targetPropFlags & ModifierFlags.Private ~= 0 then
        if sourceProp.valueDeclaration ~= targetProp.valueDeclaration then
            if reportErrors then
                if sourcePropFlags & ModifierFlags.Private ~= 0 and targetPropFlags & ModifierFlags.Private ~= 0 then
                    r:reportError(diagnostics.Types_have_separate_declarations_of_a_private_property_0, c:symbolToString(targetProp))
                else
                    r:reportError(diagnostics.Property_0_is_private_in_type_1_but_not_in_type_2, c:symbolToString(targetProp), c:TypeToString(core.IfElse(sourcePropFlags & ModifierFlags.Private ~= 0, source, target)), c:TypeToString(core.IfElse(sourcePropFlags & ModifierFlags.Private ~= 0, target, source)))
                end
            end
            return Ternary.False
        end
    elseif targetPropFlags & ModifierFlags.Protected ~= 0 then
        if not c:isValidOverrideOf(sourceProp, targetProp) then
            if reportErrors then
                local sourceType = c:getDeclaringClass(sourceProp) or source
                local targetType = c:getDeclaringClass(targetProp) or target
                r:reportError(diagnostics.Property_0_is_protected_but_type_1_is_not_a_class_derived_from_2, c:symbolToString(targetProp), c:TypeToString(sourceType), c:TypeToString(targetType))
            end
            return Ternary.False
        end
    elseif sourcePropFlags & ModifierFlags.Protected ~= 0 then
        if reportErrors then
            r:reportError(diagnostics.Property_0_is_protected_in_type_1_but_public_in_type_2, c:symbolToString(targetProp), c:TypeToString(source), c:TypeToString(target))
        end
        return Ternary.False
    end
    -- Ensure {readonly a: whatever} is not a subtype of {a: whatever},
    -- while {a: whatever} is a subtype of {readonly a: whatever}.
    -- This ensures the subtype relationship is ordered, and preventing declaration order
    -- from deciding which type "wins" in union subtype reduction.
    -- They're still assignable to one another, since `readonly` doesn't affect assignability.
    -- This is only applied during the strictSubtypeRelation -- currently used in subtype reduction
    if r.relation == c.strictSubtypeRelation and c:isReadonlySymbol(sourceProp) and not c:isReadonlySymbol(targetProp) then
        return Ternary.False
    end
    -- If the target comes from a partial union prop, allow `undefined` in the target type
    local related = r:isPropertySymbolTypeRelated(sourceProp, targetProp, getTypeOfSourceProperty, reportErrors, intersectionState)
    if related == Ternary.False then
        if reportErrors then
            r:reportError(diagnostics.Types_of_property_0_are_incompatible, c:symbolToString(targetProp))
        end
        return Ternary.False
    end
    -- When checking for comparability, be more lenient with optional properties.
    if not skipOptional and sourceProp.flags & SymbolFlags.Optional ~= 0 and targetProp.flags & SymbolFlags.ClassMember ~= 0 and targetProp.flags & SymbolFlags.Optional == 0 then
        -- TypeScript 1.0 spec (April 2014): 3.8.3
        -- S is a subtype of a type T, and T is a supertype of S if ...
        -- S' and T are object types and, for each member M in T..
        -- M is a property and S' contains a property N where
        -- if M is a required property, N is also a required property
        -- (M - property in T)
        -- (N - property in S)
        if reportErrors then
            r:reportError(diagnostics.Property_0_is_optional_in_type_1_but_required_in_type_2, c:symbolToString(targetProp), c:TypeToString(source), c:TypeToString(target))
        end
        return Ternary.False
    end
    return related
end

function Relater:isPropertySymbolTypeRelated(sourceProp, targetProp, getTypeOfSourceProperty, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local targetIsOptional = c.strictNullChecks and targetProp.checkFlags & CheckFlags.Partial ~= 0
    local effectiveTarget = c:addOptionalityEx(c:getNonMissingTypeOfSymbol(targetProp), false --[[isProperty]], targetIsOptional)
    -- source could resolve to `any` and that's not related to `unknown` target under strict subtype relation
    if effectiveTarget.flags & core.IfElse(r.relation == c.strictSubtypeRelation, TypeFlags.Any, TypeFlags.AnyOrUnknown) ~= 0 then
        return Ternary.True
    end
    local effectiveSource = getTypeOfSourceProperty(sourceProp)
    return r:isRelatedToEx(effectiveSource, effectiveTarget, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
end

function Relater:reportUnmatchedProperty(source, target, unmatchedProperty, requireOptionalProperties)
    local r = self
    local c = r.c
    -- give specific error in case where private names have the same description
    if unmatchedProperty.valueDeclaration ~= nil and
        unmatchedProperty.valueDeclaration:Name() ~= nil and
        ast.IsPrivateIdentifier(unmatchedProperty.valueDeclaration:Name()) and
        source.symbol ~= nil and
        source.symbol.flags & SymbolFlags.Class ~= 0 then
        local privateIdentifierDescription = unmatchedProperty.valueDeclaration:Name():Text()
        local symbolTableKey = binder.GetSymbolNameForPrivateIdentifier(source.symbol, privateIdentifierDescription)
        if c:getPropertyOfType(source, symbolTableKey) ~= nil then
            r:reportError(diagnostics.Property_0_in_type_1_refers_to_a_different_member_that_cannot_be_accessed_from_within_type_2, privateIdentifierDescription, c:SymbolToString(source.symbol), c:SymbolToString(target.symbol))
            return
        end
    end
    local props = c:getUnmatchedProperties(source, target, requireOptionalProperties, false --[[matchDiscriminantProperties]])
    if core.Len(props) == 1 then
        local sourceType, targetType = c:getTypeNamesForErrorDisplay(source, target)
        local propName = c:symbolToString(unmatchedProperty)
        r:reportError(diagnostics.Property_0_is_missing_in_type_1_but_required_in_type_2, propName, sourceType, targetType)
        if core.Len(unmatchedProperty.declarations) ~= 0 then
            r.relatedInfo = appendRelatedInfo(r.relatedInfo, checker.createDiagnosticForNode(unmatchedProperty.declarations[1], diagnostics.X_0_is_declared_here, propName))
        end
    elseif r:tryElaborateArrayLikeErrors(source, target, false --[[reportErrors]]) then
        local sourceType, targetType = c:getTypeNamesForErrorDisplay(source, target)
        local symbolToString = function(s) return c:symbolToString(s) end
        if core.Len(props) > 5 then
            local propNames = table.concat(core.Map(core.Slice(props, 0, 4), symbolToString), ", ")
            r:reportError(diagnostics.Type_0_is_missing_the_following_properties_from_type_1_Colon_2_and_3_more, sourceType, targetType, propNames, #props - 4)
        else
            local propNames = table.concat(core.Map(props, symbolToString) or {}, ", ")
            r:reportError(diagnostics.Type_0_is_missing_the_following_properties_from_type_1_Colon_2, sourceType, targetType, propNames)
        end
    end
end

function Relater:tryElaborateArrayLikeErrors(source, target, reportErrors)
    local r = self
    local c = r.c
    --[[*
     * The spec for elaboration is:
     * - If the source is a readonly tuple and the target is a mutable array or tuple, elaborate on mutability and skip property elaborations.
     * - If the source is a tuple then skip property elaborations if the target is an array or tuple.
     * - If the source is a readonly array and the target is a mutable array or tuple, elaborate on mutability and skip property elaborations.
     * - If the source an array then skip property elaborations if the target is a tuple.
     ]]
    if checker.isTupleType(source) then
        if source:TargetTupleType().readonly and c:isMutableArrayOrTuple(target) then
            if reportErrors then
                r:reportError(diagnostics.The_type_0_is_readonly_and_cannot_be_assigned_to_the_mutable_type_1, c:TypeToString(source), c:TypeToString(target))
            end
            return false
        end
        return c:isArrayOrTupleType(target)
    end
    if c:isReadonlyArrayType(source) and c:isMutableArrayOrTuple(target) then
        if reportErrors then
            r:reportError(diagnostics.The_type_0_is_readonly_and_cannot_be_assigned_to_the_mutable_type_1, c:TypeToString(source), c:TypeToString(target))
        end
        return false
    end
    if checker.isTupleType(target) then
        return c:isArrayType(source)
    end
    return true
end

function Relater:tryElaborateErrorsForPrimitivesAndObjects(source, target)
    local c = self.c
    if (source == c.globalStringType and target == c.stringType) or
        (source == c.globalNumberType and target == c.numberType) or
        (source == c.globalBooleanType and target == c.booleanType) or
        (source == c.getGlobalESSymbolType() and target == c.esSymbolType) then
        self:reportError(diagnostics.X_0_is_a_primitive_but_1_is_a_wrapper_object_Prefer_using_0_when_possible, c:TypeToString(target), c:TypeToString(source))
    end
end

function Relater:propertiesIdenticalTo(source, target, excludedProperties)
    local r = self
    local c = r.c
    if source.flags & TypeFlags.Object == 0 or target.flags & TypeFlags.Object == 0 then
        return Ternary.False
    end
    local sourceProperties = checker.excludeProperties(c:getPropertiesOfObjectType(source), excludedProperties)
    local targetProperties = checker.excludeProperties(c:getPropertiesOfObjectType(target), excludedProperties)
    if core.Len(sourceProperties) ~= core.Len(targetProperties) then
        return Ternary.False
    end
    local result = Ternary.True
    for _, sourceProp in ipairs(sourceProperties or {}) do
        local targetProp = c:getPropertyOfObjectType(target, sourceProp.name)
        if targetProp == nil then
            return Ternary.False
        end
        local related = c:compareProperties(sourceProp, targetProp, r.isRelatedToSimpleFn)
        if related == Ternary.False then
            return Ternary.False
        end
        result = result & related
    end
    return result
end

function Relater:signaturesRelatedTo(source, target, kind, reportErrors, intersectionState)
    local r = self
    local c = r.c
    if r.relation == c.identityRelation then
        return r:signaturesIdenticalTo(source, target, kind)
    end
    -- With respect to signatures, the anyFunctionType wildcard is a subtype of every other function type.
    if source == c.anyFunctionType then
        return Ternary.True
    end
    if target == c.anyFunctionType then
        return Ternary.False
    end
    local sourceSignatures = c:getSignaturesOfType(source, kind) or {}
    local targetSignatures = c:getSignaturesOfType(target, kind) or {}
    if kind == SignatureKind.Construct and #sourceSignatures ~= 0 and #targetSignatures ~= 0 then
        local sourceIsAbstract = sourceSignatures[1].flags & SignatureFlags.Abstract ~= 0
        local targetIsAbstract = targetSignatures[1].flags & SignatureFlags.Abstract ~= 0
        if sourceIsAbstract and not targetIsAbstract then
            -- An abstract constructor type is not assignable to a non-abstract constructor type
            -- as it would otherwise be possible to new an abstract class. Note that the assignability
            -- check we perform for an extends clause excludes construct signatures from the target,
            -- so this check never proceeds.
            if reportErrors then
                r:reportError(diagnostics.Cannot_assign_an_abstract_constructor_type_to_a_non_abstract_constructor_type)
            end
            return Ternary.False
        end
        if not r:constructorVisibilitiesAreCompatible(sourceSignatures[1], targetSignatures[1], reportErrors) then
            return Ternary.False
        end
    end
    local result = Ternary.True
    if source.objectFlags & ObjectFlags.Instantiated ~= 0 and target.objectFlags & ObjectFlags.Instantiated ~= 0 and source.symbol == target.symbol or
        source.objectFlags & ObjectFlags.Reference ~= 0 and target.objectFlags & ObjectFlags.Reference ~= 0 and source:Target() == target:Target() then
        -- We have instantiations of the same anonymous type (which typically will be the type of a
        -- method). Simply do a pairwise comparison of the signatures in the two signature lists instead
        -- of the much more expensive N * M comparison matrix we explore below. We erase type parameters
        -- as they are known to always be the same.
        for i = 1, #targetSignatures do
            local related = r:signatureRelatedTo(sourceSignatures[i], targetSignatures[i], true --[[erase]], reportErrors, intersectionState)
            if related == Ternary.False then
                return Ternary.False
            end
            result = result & related
        end
    elseif #sourceSignatures == 1 and #targetSignatures == 1 then
        -- For simple functions (functions with a single signature) we only erase type parameters for
        -- the comparable relation. Otherwise, if the source signature is generic, we instantiate it
        -- in the context of the target signature before checking the relationship. Ideally we'd do
        -- this regardless of the number of signatures, but the potential costs are prohibitive due
        -- to the quadratic nature of the logic below.
        local eraseGenerics = r.relation == c.comparableRelation
        result = r:signatureRelatedTo(sourceSignatures[1], targetSignatures[1], eraseGenerics, reportErrors, intersectionState)
    else
        for _, t in ipairs(targetSignatures) do
            local saveErrorState = r:getErrorState()
            -- Only elaborate errors from the first failure
            local shouldElaborateErrors = reportErrors
            for _, s in ipairs(sourceSignatures) do
                local related = r:signatureRelatedTo(s, t, true --[[erase]], shouldElaborateErrors, intersectionState)
                if related ~= Ternary.False then
                    result = result & related
                    r:restoreErrorState(saveErrorState)
                    goto continue_outer
                end
                shouldElaborateErrors = false
            end
            if shouldElaborateErrors then
                r:reportError(diagnostics.Type_0_provides_no_match_for_the_signature_1, c:TypeToString(source), c:signatureToString(t))
            end
            do
                return Ternary.False
            end
            ::continue_outer::
        end
    end
    return result
end

function Relater:constructorVisibilitiesAreCompatible(sourceSignature, targetSignature, reportErrors)
    if sourceSignature.declaration == nil or targetSignature.declaration == nil then
        return true
    end
    local sourceAccessibility = sourceSignature.declaration:ModifierFlags() & ModifierFlags.NonPublicAccessibilityModifier
    local targetAccessibility = targetSignature.declaration:ModifierFlags() & ModifierFlags.NonPublicAccessibilityModifier
    -- A public, protected and private signature is assignable to a private signature.
    if targetAccessibility == ModifierFlags.Private then
        return true
    end
    -- A public and protected signature is assignable to a protected signature.
    if targetAccessibility == ModifierFlags.Protected and sourceAccessibility ~= ModifierFlags.Private then
        return true
    end
    -- Only a public signature is assignable to public signature.
    if targetAccessibility ~= ModifierFlags.Protected and sourceAccessibility == 0 then
        return true
    end
    if reportErrors then
        self:reportError(diagnostics.Cannot_assign_a_0_constructor_type_to_a_1_constructor_type, checker.visibilityToString(sourceAccessibility), checker.visibilityToString(targetAccessibility))
    end
    return false
end

-- See signatureAssignableTo, compareSignaturesIdentical
function Relater:signatureRelatedTo(source, target, erase, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local checkMode = SignatureCheckMode.None
    if r.relation == c.subtypeRelation then
        checkMode = SignatureCheckMode.StrictTopSignature
    elseif r.relation == c.strictSubtypeRelation then
        checkMode = SignatureCheckMode.StrictTopSignature | SignatureCheckMode.StrictArity
    end
    if erase then
        source = c:getErasedSignature(source)
        target = c:getErasedSignature(target)
    end
    local isRelatedToWorker = function(s, t, reportErrors_)
        return r:isRelatedToEx(s, t, RecursionFlags.Both, reportErrors_, nil --[[headMessage]], intersectionState)
    end
    return c:compareSignaturesRelated(source, target, checkMode, reportErrors, r.reportErrorFn, isRelatedToWorker, c.reportUnreliableMapper)
end

function Relater:signaturesIdenticalTo(source, target, kind)
    local r = self
    local c = r.c
    local sourceSignatures = c:getSignaturesOfType(source, kind) or {}
    local targetSignatures = c:getSignaturesOfType(target, kind) or {}
    if #sourceSignatures ~= #targetSignatures then
        return Ternary.False
    end
    local result = Ternary.True
    for i = 1, #sourceSignatures do
        local related = c:compareSignaturesIdentical(sourceSignatures[i], targetSignatures[i], false --[[partialMatch]], false --[[ignoreThisTypes]], false --[[ignoreReturnTypes]], r.isRelatedToSimpleFn)
        if related == 0 then
            return Ternary.False
        end
        result = result & related
    end
    return result
end

function Relater:indexSignaturesRelatedTo(source, target, sourceIsPrimitive, reportErrors, intersectionState)
    local r = self
    local c = r.c
    if r.relation == c.identityRelation then
        return r:indexSignaturesIdenticalTo(source, target)
    end
    local indexInfos = c:getIndexInfosOfType(target)
    local targetHasStringIndex = core.Some(indexInfos, function(info) return info.keyType == c.stringType end)
    local result = Ternary.True
    for _, targetInfo in ipairs(indexInfos or {}) do
        local related
        if r.relation ~= c.strictSubtypeRelation and not sourceIsPrimitive and targetHasStringIndex and targetInfo.valueType.flags & TypeFlags.Any ~= 0 then
            related = Ternary.True
        elseif c:isGenericMappedType(source) and targetHasStringIndex then
            related = r:isRelatedTo(c:getTemplateTypeFromMappedType(source), targetInfo.valueType, RecursionFlags.Both, reportErrors)
        else
            related = r:typeRelatedToIndexInfo(source, targetInfo, reportErrors, intersectionState)
        end
        if related == Ternary.False then
            return Ternary.False
        end
        result = result & related
    end
    return result
end

function Relater:typeRelatedToIndexInfo(source, targetInfo, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local sourceInfo = c:getApplicableIndexInfo(source, targetInfo.keyType)
    if sourceInfo ~= nil then
        return r:indexInfoRelatedTo(sourceInfo, targetInfo, reportErrors, intersectionState)
    end
    -- Intersection constituents are never considered to have an inferred index signature. Also, in the strict subtype relation,
    -- only fresh object literals are considered to have inferred index signatures. This ensures { [x: string]: xxx } <: {} but
    -- not vice-versa. Without this rule, those types would be mutual strict subtypes.
    if intersectionState & IntersectionState.Source == 0 and (r.relation ~= c.strictSubtypeRelation or source.objectFlags & ObjectFlags.FreshLiteral ~= 0) and c:isObjectTypeWithInferableIndex(source) then
        return r:membersRelatedToIndexInfo(source, targetInfo, reportErrors, intersectionState)
    end
    if reportErrors then
        r:reportError(diagnostics.Index_signature_for_type_0_is_missing_in_type_1, c:TypeToString(targetInfo.keyType), c:TypeToString(source))
    end
    return Ternary.False
end

-- Return true if the type was inferred from
--   - an object literal, object type literal, enum type, or a value module and has no call or construct signatures, or
--   - a JS expando object literal or a rest type, or
--   - a reverse mapped type with a source for which one of the above is true.
function Checker:isObjectTypeWithInferableIndex(t)
    local c = self
    if t.flags & TypeFlags.Intersection ~= 0 then
        return core.Every(t:Types(), function(t_) return c:isObjectTypeWithInferableIndex(t_) end)
    end
    return t.symbol ~= nil and
        t.symbol.flags & (SymbolFlags.ObjectLiteral | SymbolFlags.TypeLiteral | SymbolFlags.Enum | SymbolFlags.ValueModule) ~= 0 and t.symbol.flags & SymbolFlags.Class == 0 and not c:typeHasCallOrConstructSignatures(t) or
        t.objectFlags & (ObjectFlags.JSLiteral | checker.ObjectFlagsObjectRestType) ~= 0 or
        t.objectFlags & ObjectFlags.ReverseMapped ~= 0 and c:isObjectTypeWithInferableIndex(t:AsReverseMappedType().source)
end

function Relater:membersRelatedToIndexInfo(source, targetInfo, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local result = Ternary.True
    local keyType = targetInfo.keyType
    local props
    if source.flags & TypeFlags.Intersection ~= 0 then
        props = c:getPropertiesOfUnionOrIntersectionType(source)
    else
        props = c:getPropertiesOfObjectType(source)
    end
    for _, prop in ipairs(props or {}) do
        -- Skip over ignored JSX and symbol-named members
        if checker.isIgnoredJsxProperty(source, prop) then
            goto continue
        end
        if c:isApplicableIndexType(c:getLiteralTypeFromProperty(prop, TypeFlags.StringOrNumberLiteralOrUnique, false), keyType) then
            local propType = c:getNonMissingTypeOfSymbol(prop)
            local t
            if c.exactOptionalPropertyTypes or propType.flags & TypeFlags.Undefined ~= 0 or keyType == c.numberType or prop.flags & SymbolFlags.Optional == 0 then
                t = propType
            else
                t = c:getTypeWithFacts(propType, TypeFacts.NEUndefined)
            end
            local related = r:isRelatedToEx(t, targetInfo.valueType, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
            if related == Ternary.False then
                if reportErrors then
                    r:reportError(diagnostics.Property_0_is_incompatible_with_index_signature, c:symbolToString(prop))
                end
                return Ternary.False
            end
            result = result & related
        end
        ::continue::
    end
    for _, info in ipairs(c:getIndexInfosOfType(source) or {}) do
        if c:isApplicableIndexType(info.keyType, keyType) then
            local related = r:indexInfoRelatedTo(info, targetInfo, reportErrors, intersectionState)
            if related == 0 then
                return Ternary.False
            end
            result = result & related
        end
    end
    return result
end

function Relater:indexInfoRelatedTo(sourceInfo, targetInfo, reportErrors, intersectionState)
    local r = self
    local c = r.c
    local related = r:isRelatedToEx(sourceInfo.valueType, targetInfo.valueType, RecursionFlags.Both, reportErrors, nil --[[headMessage]], intersectionState)
    if related == Ternary.False and reportErrors then
        if sourceInfo.keyType == targetInfo.keyType then
            r:reportError(diagnostics.X_0_index_signatures_are_incompatible, c:TypeToString(sourceInfo.keyType))
        else
            r:reportError(diagnostics.X_0_and_1_index_signatures_are_incompatible, c:TypeToString(sourceInfo.keyType), c:TypeToString(targetInfo.keyType))
        end
    end
    return related
end

function Relater:indexSignaturesIdenticalTo(source, target)
    local r = self
    local c = r.c
    local sourceInfos = c:getIndexInfosOfType(source)
    local targetInfos = c:getIndexInfosOfType(target)
    if core.Len(sourceInfos) ~= core.Len(targetInfos) then
        return Ternary.False
    end
    for _, targetInfo in ipairs(targetInfos or {}) do
        local sourceInfo = c:getIndexInfoOfType(source, targetInfo.keyType)
        if not (sourceInfo ~= nil and r:isRelatedTo(sourceInfo.valueType, targetInfo.valueType, RecursionFlags.Both, false) ~= Ternary.False and sourceInfo.isReadonly == targetInfo.isReadonly) then
            return Ternary.False
        end
    end
    return Ternary.True
end

function Relater:reportErrorResults(originalSource, originalTarget, source, target, headMessage)
    local r = self
    local c = r.c
    local sourceHasBase = c:getSingleBaseForNonAugmentingSubtype(originalSource) ~= nil
    local targetHasBase = c:getSingleBaseForNonAugmentingSubtype(originalTarget) ~= nil
    if originalSource.alias ~= nil or sourceHasBase then
        source = originalSource
    end
    if originalTarget.alias ~= nil or targetHasBase then
        target = originalTarget
    end
    if source.flags & TypeFlags.Object ~= 0 and target.flags & TypeFlags.Object ~= 0 then
        r:tryElaborateArrayLikeErrors(source, target, true --[[reportErrors]])
    end
    if source.flags & TypeFlags.Object ~= 0 and target.flags & TypeFlags.Primitive ~= 0 then
        r:tryElaborateErrorsForPrimitivesAndObjects(source, target)
    elseif source.symbol ~= nil and source.flags & TypeFlags.Object ~= 0 and c.globalObjectType == source then
        r:reportError(diagnostics.The_Object_type_is_assignable_to_very_few_other_types_Did_you_mean_to_use_the_any_type_instead)
    elseif source.objectFlags & ObjectFlags.JsxAttributes ~= 0 and target.flags & TypeFlags.Intersection ~= 0 then
        local targetTypes = target:Types()
        local intrinsicAttributes = c:getJsxType(checker.JsxNames.intrinsicAttributes, r.errorNode)
        local intrinsicClassAttributes = c:getJsxType(checker.JsxNames.intrinsicClassAttributes, r.errorNode)
        if not c:isErrorType(intrinsicAttributes) and not c:isErrorType(intrinsicClassAttributes) and (sliceContains(targetTypes, intrinsicAttributes) or sliceContains(targetTypes, intrinsicClassAttributes)) then
            return
        end
    elseif originalTarget.flags & TypeFlags.Intersection ~= 0 and originalTarget.objectFlags & checker.ObjectFlagsIsNeverIntersection ~= 0 then
        local message = diagnostics.The_intersection_0_was_reduced_to_never_because_property_1_has_conflicting_types_in_some_constituents
        local prop = core.Find(c:getPropertiesOfUnionOrIntersectionType(originalTarget), function(p) return c:isDiscriminantWithNeverType(p) end)
        if prop == nil then
            message = diagnostics.The_intersection_0_was_reduced_to_never_because_property_1_exists_in_multiple_constituents_and_is_private_in_some
            prop = core.Find(c:getPropertiesOfUnionOrIntersectionType(originalTarget), checker.isConflictingPrivateProperty)
        end
        if prop ~= nil then
            r:reportError(message, c:typeToStringEx(originalTarget, nil --[[enclosingDeclaration]], checker.TypeFormatFlags.NoTypeReduction, nil), c:symbolToString(prop))
        end
    end
    r:reportRelationError(headMessage, source, target)
    if source.flags & TypeFlags.TypeParameter ~= 0 and source.symbol ~= nil and core.Len(source.symbol.declarations) ~= 0 and c:getConstraintOfType(source) == nil then
        local syntheticParam = c:cloneTypeParameter(source)
        syntheticParam:AsTypeParameter().constraint = c:instantiateType(target, checker.newSimpleTypeMapper(source, syntheticParam))
        if c:hasNonCircularBaseConstraint(syntheticParam) then
            local targetConstraintString = c:TypeToString(target)
            r.relatedInfo = appendRelatedInfo(r.relatedInfo, checker.NewDiagnosticForNode(source.symbol.declarations[1], diagnostics.This_type_parameter_might_need_an_extends_0_constraint, targetConstraintString))
        end
    end
end

function Relater:reportRelationError(message, source, target)
    local r = self
    local c = r.c
    local sourceType, targetType = c:getTypeNamesForErrorDisplay(source, target)
    local generalizedSource = source
    local generalizedSourceType = sourceType
    -- Don't generalize on 'never' - we really want the original type
    -- to be displayed for use-cases like 'assertNever'.
    if target.flags & TypeFlags.Never == 0 and checker.isLiteralType(source) and not c:typeCouldHaveTopLevelSingletonTypes(target) then
        generalizedSource = c:getBaseTypeOfLiteralType(source)
        generalizedSourceType = c:getTypeNameForErrorDisplay(generalizedSource)
    end
    -- If `target` is of indexed access type (and `source` it is not), we use the object type of `target` for better error reporting
    local targetFlags
    if target.flags & TypeFlags.IndexedAccess ~= 0 and source.flags & TypeFlags.IndexedAccess == 0 then
        targetFlags = target:AsIndexedAccessType().objectType.flags
    else
        targetFlags = target.flags
    end
    if targetFlags & TypeFlags.TypeParameter ~= 0 and target ~= c.markerSuperTypeForCheck and target ~= c.markerSubTypeForCheck then
        local constraint = c:getBaseConstraintOfType(target)
        if constraint ~= nil and c:isTypeAssignableTo(generalizedSource, constraint) then
            r:reportError(diagnostics.X_0_is_assignable_to_the_constraint_of_type_1_but_1_could_be_instantiated_with_a_different_subtype_of_constraint_2, generalizedSourceType, targetType, c:TypeToString(constraint))
        elseif constraint ~= nil and c:isTypeAssignableTo(source, constraint) then
            r:reportError(diagnostics.X_0_is_assignable_to_the_constraint_of_type_1_but_1_could_be_instantiated_with_a_different_subtype_of_constraint_2, sourceType, targetType, c:TypeToString(constraint))
        else
            r.errorChain = nil -- Only report this error once
            r:reportError(diagnostics.X_0_could_be_instantiated_with_an_arbitrary_type_which_could_be_unrelated_to_1, targetType, generalizedSourceType)
        end
    end
    if message == nil then
        if r.relation == c.comparableRelation then
            message = diagnostics.Type_0_is_not_comparable_to_type_1
        elseif sourceType == targetType then
            message = diagnostics.Type_0_is_not_assignable_to_type_1_Two_different_types_with_this_name_exist_but_they_are_unrelated
        elseif c.exactOptionalPropertyTypes and core.Len(c:getExactOptionalUnassignableProperties(source, target)) ~= 0 then
            message = diagnostics.Type_0_is_not_assignable_to_type_1_with_exactOptionalPropertyTypes_Colon_true_Consider_adding_undefined_to_the_types_of_the_target_s_properties
        else
            if source.flags & TypeFlags.StringLiteral ~= 0 and target.flags & TypeFlags.Union ~= 0 then
                local suggestedType = c:getSuggestedTypeForNonexistentStringLiteralType(source, target)
                if suggestedType ~= nil then
                    r:reportError(diagnostics.Type_0_is_not_assignable_to_type_1_Did_you_mean_2, generalizedSourceType, targetType, c:TypeToString(suggestedType))
                    return
                end
            end
            message = diagnostics.Type_0_is_not_assignable_to_type_1
        end
    elseif message == diagnostics.Argument_of_type_0_is_not_assignable_to_parameter_of_type_1 and c.exactOptionalPropertyTypes and core.Len(c:getExactOptionalUnassignableProperties(source, target)) > 0 then
        message = diagnostics.Argument_of_type_0_is_not_assignable_to_parameter_of_type_1_with_exactOptionalPropertyTypes_Colon_true_Consider_adding_undefined_to_the_types_of_the_target_s_properties
    end
    local chainMessage = r:getChainMessage(0)
    -- Suppress if next message is an excess property error
    if chainMessage == diagnostics.Object_literal_may_only_specify_known_properties_and_0_does_not_exist_in_type_1 or
        chainMessage == diagnostics.Object_literal_may_only_specify_known_properties_but_0_does_not_exist_in_type_1_Did_you_mean_to_write_2 then
        return
    -- Suppress if next message is an excessive complexity/stack depth message for source and target or a readonly
    -- vs. mutable error for source and target
    elseif chainMessage == diagnostics.Excessive_complexity_comparing_types_0_and_1 or
        chainMessage == diagnostics.The_type_0_is_readonly_and_cannot_be_assigned_to_the_mutable_type_1 then
        if r:chainArgsMatch(generalizedSourceType, targetType) then
            return
        end
    -- Suppress if next message is a missing property message for source and target and we're not
    -- reporting on conversion or interface implementation
    elseif chainMessage == diagnostics.Property_0_is_missing_in_type_1_but_required_in_type_2 then
        if not checker.isConversionOrInterfaceImplementationMessage(message) and r:chainArgsMatch(nil, generalizedSourceType, targetType) then
            return
        end
    -- Suppress if next message is a missing property message for source and target and we're not
    -- reporting on conversion or interface implementation
    elseif chainMessage == diagnostics.Type_0_is_missing_the_following_properties_from_type_1_Colon_2_and_3_more or
        chainMessage == diagnostics.Type_0_is_missing_the_following_properties_from_type_1_Colon_2 then
        if not checker.isConversionOrInterfaceImplementationMessage(message) and r:chainArgsMatch(generalizedSourceType, targetType) then
            return
        end
    end
    r:reportError(message, generalizedSourceType, targetType)
end

function Relater:reportError(message, ...)
    local r = self
    local args = table.pack(...)
    if message == diagnostics.Types_of_property_0_are_incompatible then
        -- Suppress if next message is an excess property error
        local chainMessage = r:getChainMessage(0)
        if chainMessage == diagnostics.Object_literal_may_only_specify_known_properties_and_0_does_not_exist_in_type_1 or
            chainMessage == diagnostics.Object_literal_may_only_specify_known_properties_but_0_does_not_exist_in_type_1_Did_you_mean_to_write_2 then
            return
        end
        -- Transform a property incompatibility message for property 'x' followed by some elaboration message
        -- followed by a signature return type incompatibility message into a single return type incompatibility
        -- message for 'x()' or 'x(...)'
        local arg = ""
        chainMessage = r:getChainMessage(1)
        if chainMessage == diagnostics.Call_signatures_with_no_arguments_have_incompatible_return_types_0_and_1 then
            arg = checker.getPropertyNameArg(args[1]) .. "()"
        elseif chainMessage == diagnostics.Construct_signatures_with_no_arguments_have_incompatible_return_types_0_and_1 then
            arg = "new " .. checker.getPropertyNameArg(args[1]) .. "()"
        elseif chainMessage == diagnostics.Call_signature_return_types_0_and_1_are_incompatible then
            arg = checker.getPropertyNameArg(args[1]) .. "(...)"
        elseif chainMessage == diagnostics.Construct_signature_return_types_0_and_1_are_incompatible then
            arg = "new " .. checker.getPropertyNameArg(args[1]) .. "(...)"
        end
        if arg ~= "" then
            message = diagnostics.The_types_returned_by_0_are_incompatible_between_these_types
            args[1] = arg
            r.errorChain = r.errorChain.next.next
        end
        -- Transform a property incompatibility message for property 'x' followed by some elaboration message
        -- followed by a property incompatibility message for property 'y' into a single property incompatibility
        -- message for 'x.y'
        chainMessage = r:getChainMessage(1)
        if chainMessage == diagnostics.Types_of_property_0_are_incompatible or
            chainMessage == diagnostics.The_types_of_0_are_incompatible_between_these_types or
            chainMessage == diagnostics.The_types_returned_by_0_are_incompatible_between_these_types then
            local head = checker.getPropertyNameArg(args[1])
            local tail = checker.getPropertyNameArg(r.errorChain.next.args[1])
            local arg_ = checker.addToDottedName(head, tail)
            r.errorChain = r.errorChain.next.next
            if message == diagnostics.Types_of_property_0_are_incompatible then
                message = diagnostics.The_types_of_0_are_incompatible_between_these_types
            end
            r:reportError(message, arg_)
            return
        end
    end
    r.errorChain = checker.ErrorChain_new({ next = r.errorChain, message = message, args = args })
end

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function checker.addToDottedName(head, tail)
    if hasPrefix(head, "new ") then
        head = "(" .. head .. ")"
    end
    local pos = 0
    while true do
        if hasPrefix(string.sub(tail, pos + 1), "(") then
            pos = pos + 1
        elseif hasPrefix(string.sub(tail, pos + 1), "new ") then
            pos = pos + 4
        else
            break
        end
    end
    local prefix = string.sub(tail, 1, pos)
    local suffix = string.sub(tail, pos + 1)
    if hasPrefix(suffix, "[") then
        return prefix .. head .. suffix
    end
    return prefix .. head .. "." .. suffix
end

function Relater:getChainMessage(index)
    local e = self.errorChain
    while true do
        if e == nil then
            return nil
        end
        if index == 0 then
            return e.message
        end
        e = e.next
        index = index - 1
    end
end

-- Return true if the arguments of the first entry on the error chain match the
-- given arguments (where nil acts as a wildcard).
function Relater:chainArgsMatch(...)
    local n = select("#", ...)
    for i = 1, n do
        local a = select(i, ...)
        if a ~= nil and a ~= self.errorChain.args[i] then
            return false
        end
    end
    return true
end

function checker.getPropertyNameArg(arg)
    local s = arg
    if type(s) ~= "string" then
        error("interface conversion: getPropertyNameArg expects a string", 0)
    end
    if #s ~= 0 then
        local ch = string.sub(s, 1, 1)
        if ch == "\"" or ch == "'" or ch == "`" then
            return "[" .. s .. "]"
        end
    end
    return s
end

function checker.isConversionOrInterfaceImplementationMessage(message)
    return message == diagnostics.Class_0_incorrectly_implements_interface_1 or
        message == diagnostics.Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1_and_inherit_its_members_as_a_subclass or
        message == diagnostics.Conversion_of_type_0_to_type_1_may_be_a_mistake_because_neither_type_sufficiently_overlaps_with_the_other_If_this_was_intentional_convert_the_expression_to_unknown_first or
        message == diagnostics.Its_instance_type_0_is_not_a_valid_JSX_element or
        message == diagnostics.Its_return_type_0_is_not_a_valid_JSX_element or
        message == diagnostics.Its_element_type_0_is_not_a_valid_JSX_element
end

function checker.chainDepth(chain)
    local depth = 0
    while chain ~= nil do
        depth = depth + 1
        chain = chain.next
    end
    return depth
end

-- An object type S is considered to be derived from an object type T if
-- S is a union type and every constituent of S is derived from T,
-- T is a union type and S is derived from at least one constituent of T, or
-- S is an intersection type and some constituent of S is derived from T, or
-- S is a type variable with a base constraint that is derived from T, or
-- T is {} and S is an object-like type (ensuring {} is less derived than Object), or
-- T is one of the global types Object and Function and S is a subtype of T, or
-- T occurs directly or indirectly in an 'extends' clause of S.
-- Note that this check ignores type parameters and only considers the
-- inheritance hierarchy.
function Checker:isTypeDerivedFrom(source, target)
    local c = self
    if source.flags & TypeFlags.Union ~= 0 then
        return core.Every(source:AsUnionType().types, function(t)
            return c:isTypeDerivedFrom(t, target)
        end)
    elseif target.flags & TypeFlags.Union ~= 0 then
        return core.Some(target:AsUnionType().types, function(t)
            return c:isTypeDerivedFrom(source, t)
        end)
    elseif source.flags & TypeFlags.Intersection ~= 0 then
        return core.Some(source:AsIntersectionType().types, function(t)
            return c:isTypeDerivedFrom(t, target)
        end)
    elseif source.flags & TypeFlags.InstantiableNonPrimitive ~= 0 then
        local constraint = c:getBaseConstraintOfType(source)
        if constraint == nil then
            constraint = c.unknownType
        end
        return c:isTypeDerivedFrom(constraint, target)
    elseif c:IsEmptyAnonymousObjectType(target) then
        return source.flags & (TypeFlags.Object | TypeFlags.NonPrimitive) ~= 0
    elseif target == c.globalObjectType then
        return source.flags & (TypeFlags.Object | TypeFlags.NonPrimitive) ~= 0 and not c:IsEmptyAnonymousObjectType(source)
    elseif target == c.globalFunctionType then
        return source.flags & TypeFlags.Object ~= 0 and c:isFunctionObjectType(source)
    end
    return c:hasBaseType(source, c:getTargetType(target)) or (c:isArrayType(target) and not c:isReadonlyArrayType(target) and c:isTypeDerivedFrom(source, c.globalReadonlyArrayType))
end

function Checker:isDistributionDependent(root)
    return root.isDistributive and (self:isTypeParameterPossiblyReferenced(root.checkType, root.node.trueType) or self:isTypeParameterPossiblyReferenced(root.checkType, root.node.falseType))
end

function Relater:traceUnionsOrIntersectionsTooLarge(source, target)
    local tr = self.c.tracer
    if tr == nil then
        return
    end
    if source.flags & TypeFlags.UnionOrIntersection ~= 0 and target.flags & TypeFlags.UnionOrIntersection ~= 0 then
        if source.objectFlags & target.objectFlags & ObjectFlags.PrimitiveUnion ~= 0 then
            -- There's a fast path for comparing primitive unions
            return
        end
        local sourceSize = #source:Types()
        local targetSize = #target:Types()
        if sourceSize * targetSize > 1000000 then
            tr:Instant(tracing.PhaseCheckTypes, "traceUnionsOrIntersectionsTooLarge_DepthLimit", { sourceId = source.id, sourceSize = sourceSize, targetId = target.id, targetSize = targetSize })
        end
    end
end
