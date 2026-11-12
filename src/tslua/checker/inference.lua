-- Go closures shadow their enclosing parameters (func(t *Type) inside a function of t).
-- luacheck: ignore 421 422 431 432 433
local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local jsnum = require("tslua.jsnum")

local Checker = checker.Checker
local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local InferencePriority = checker.InferencePriority
local InferenceFlags = checker.InferenceFlags
local ExpandingFlags = checker.ExpandingFlags
local VarianceFlags = checker.VarianceFlags
local SignatureKind = checker.SignatureKind
local SignatureFlags = checker.SignatureFlags
local UnionReduction = checker.UnionReduction
local MappedTypeModifiers = checker.MappedTypeModifiers
local IndexFlags = checker.IndexFlags
local ContextFlags = checker.ContextFlags
local Ternary = checker.Ternary
local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags

-- Go slices.Contains
local function containsValue(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- InferenceKey{s, t} as a map key string.
function checker.InferenceKey(s, t)
    return s .. ":" .. t
end

defineStruct("InferenceState", nil, {
    priority = 0,
    inferencePriority = 0,
    contravariant = false,
    bivariant = false,
    expandingFlags = 0,
})

function Checker:getInferenceState()
    local n = self.freeinferenceState
    if n == nil then
        n = checker.InferenceState_new({ sourceStack = {}, targetStack = {} })
    end
    self.freeinferenceState = n.next
    return n
end

function Checker:putInferenceState(n)
    local visited = n.visited
    if visited ~= nil then
        for k in pairs(visited) do
            visited[k] = nil
        end
    end
    n.inferences = nil
    n.originalSource = nil
    n.originalTarget = nil
    n.priority = 0
    n.inferencePriority = 0
    n.contravariant = false
    n.bivariant = false
    n.expandingFlags = 0
    n.propagationType = nil
    n.visited = visited
    n.sourceStack = {}
    n.targetStack = {}
    n.next = self.freeinferenceState
    self.freeinferenceState = n
end

function Checker:inferTypes(inferences, originalSource, originalTarget, priority, contravariant)
    local n = self:getInferenceState()
    n.inferences = inferences
    n.originalSource = originalSource
    n.originalTarget = originalTarget
    n.priority = priority
    n.inferencePriority = InferencePriority.MaxValue
    n.contravariant = contravariant
    self:inferFromTypes(n, originalSource, originalTarget)
    self:putInferenceState(n)
end

function Checker:inferFromTypes(n, source, target)
    if not self.couldContainTypeVariables(target) or self:isNoInferType(target) then
        return
    end
    if source == self.wildcardType or source == self.blockedStringType then
        -- We are inferring from an 'any' type. We want to infer this type for every type parameter
        -- referenced in the target type, so we record it as the propagation type and infer from the
        -- target to itself. Then, as we find candidates we substitute the propagation type.
        local savePropagationType = n.propagationType
        n.propagationType = source
        self:inferFromTypes(n, target, target)
        n.propagationType = savePropagationType
        return
    end
    if source.alias ~= nil and target.alias ~= nil and source.alias.symbol == target.alias.symbol then
        if core.Len(source.alias.typeArguments) ~= 0 or core.Len(target.alias.typeArguments) ~= 0 then
            -- Source and target are types originating in the same generic type alias declaration.
            -- Simply infer from source type arguments to target type arguments, with defaults applied.
            local params = self.typeAliasLinks:Get(source.alias.symbol).typeParameters
            local minParams = self:getMinTypeArgumentCount(params)
            local nodeIsInJsFile = ast.IsInJSFile(source.alias.symbol.valueDeclaration)
            local sourceTypes = self:fillMissingTypeArguments(source.alias.typeArguments, params, minParams, nodeIsInJsFile)
            local targetTypes = self:fillMissingTypeArguments(target.alias.typeArguments, params, minParams, nodeIsInJsFile)
            self:inferFromTypeArguments(n, sourceTypes, targetTypes, self:getAliasVariances(source.alias.symbol))
        end
        -- And if there weren't any type arguments, there's no reason to run inference as the types must be the same.
        return
    end
    if source == target and source.flags & TypeFlags.UnionOrIntersection ~= 0 then
        -- When source and target are the same union or intersection type, just relate each constituent
        -- type to itself.
        for _, t in ipairs(source:Types()) do
            self:inferFromTypes(n, t, t)
        end
        return
    end
    if target.flags & TypeFlags.Union ~= 0 then
        local sourceTypes
        if source.flags & TypeFlags.Union ~= 0 then
            sourceTypes = source:Types()
        else
            sourceTypes = { source }
        end
        -- First, infer between identically matching source and target constituents and remove the
        -- matching types.
        local tempSources, tempTargets = self:inferFromMatchingTypes(n, sourceTypes, target:Types(), Checker.isTypeOrBaseIdenticalTo, false --[[sort]])
        -- Next, infer between closely matching source and target constituents and remove
        -- the matching types. Types closely match when they are instantiations of the same
        -- object type or instantiations of the same type alias.
        local sources, targets = self:inferFromMatchingTypes(n, tempSources, tempTargets, Checker.isTypeCloselyMatchedBy, true --[[sort]])
        if core.Len(targets) == 0 then
            return
        end
        target = self:getUnionType(targets)
        if core.Len(sources) == 0 then
            -- All source constituents have been matched and there is nothing further to infer from.
            -- However, simply making no inferences is undesirable because it could ultimately mean
            -- inferring a type parameter constraint. Instead, make a lower priority inference from
            -- the full source to whatever remains in the target. For example, when inferring from
            -- string to 'string | T', make a lower priority inference of string for T.
            self:inferWithPriority(n, source, target, InferencePriority.NakedTypeVariable)
            return
        end
        source = self:getUnionType(sources)
    elseif target.flags & TypeFlags.Intersection ~= 0 and not core.Every(target:Types(), function(t)
        return self:isNonGenericObjectType(t)
    end) then
        -- We reduce intersection types unless they're simple combinations of object types. For example,
        -- when inferring from 'string[] & { extra: any }' to 'string[] & T' we want to remove string[] and
        -- infer { extra: any } for T. But when inferring to 'string[] & Iterable<T>' we want to keep the
        -- string[] on the source side and infer string for T.
        if source.flags & TypeFlags.Union == 0 then
            local sourceTypes
            if source.flags & TypeFlags.Intersection ~= 0 then
                sourceTypes = source:Types()
            else
                sourceTypes = { source }
            end
            -- Infer between identically matching source and target constituents and remove the matching types.
            local sources, targets = self:inferFromMatchingTypes(n, sourceTypes, target:Types(), Checker.isTypeIdenticalTo, false --[[sort]])
            if core.Len(sources) == 0 or core.Len(targets) == 0 then
                return
            end
            source = self:getIntersectionType(sources)
            target = self:getIntersectionType(targets)
        end
    end
    if target.flags & (TypeFlags.IndexedAccess | TypeFlags.Substitution) ~= 0 then
        if self:isNoInferType(target) then
            return
        end
        target = self:getActualTypeVariable(target)
    end
    if target.flags & TypeFlags.TypeVariable ~= 0 then
        -- Skip inference if the source is "blocked", which is used by the language service to
        -- prevent inference on nodes currently being edited.
        if self:isFromInferenceBlockedSource(source) then
            return
        end
        local inference = checker.getInferenceInfoForType(n, target)
        if inference ~= nil then
            -- If target is a type parameter, make an inference, unless the source type contains
            -- a "non-inferrable" type. Types with this flag set are markers used to prevent inference.
            --
            -- For example:
            --     - anyFunctionType is a wildcard type that's used to avoid contextually typing functions;
            --       it's internal, so should not be exposed to the user by adding it as a candidate.
            --     - autoType (and autoArrayType) is a special "any" used in control flow; like anyFunctionType,
            --       it's internal and should not be observable.
            --     - silentNeverType is returned by getInferredType when instantiating a generic function for
            --       inference (and a type variable has no mapping).
            --
            -- This flag is infectious; if we produce Box<never> (where never is silentNeverType), Box<never> is
            -- also non-inferrable.
            --
            -- As a special case, also ignore nonInferrableAnyType, which is a special form of the any type
            -- used as a stand-in for binding elements when they are being inferred.
            if source.objectFlags & ObjectFlags.NonInferrableType ~= 0 or source == self.nonInferrableAnyType then
                return
            end
            if not inference.isFixed then
                local candidate = core.Coalesce(n.propagationType, source)
                if candidate == self.blockedStringType then
                    return
                end
                if n.priority < inference.priority then
                    inference.candidates = nil
                    inference.contraCandidates = nil
                    inference.topLevel = true
                    inference.priority = n.priority
                end
                if n.priority == inference.priority then
                    -- We make contravariant inferences only if we are in a pure contravariant position,
                    -- i.e. only if we have not descended into a bivariant position.
                    if n.contravariant and not n.bivariant then
                        if not containsValue(inference.contraCandidates, candidate) then
                            inference.contraCandidates = core.Append(inference.contraCandidates, candidate)
                            checker.clearCachedInferences(n.inferences)
                        end
                    elseif not containsValue(inference.candidates, candidate) then
                        inference.candidates = core.Append(inference.candidates, candidate)
                        checker.clearCachedInferences(n.inferences)
                    end
                end
                if n.priority & InferencePriority.ReturnType == 0 and target.flags & TypeFlags.TypeParameter ~= 0 and inference.topLevel and not self:isTypeParameterAtTopLevel(n.originalTarget, target, 0) then
                    inference.topLevel = false
                    checker.clearCachedInferences(n.inferences)
                end
            end
            n.inferencePriority = math.min(n.inferencePriority, n.priority)
            return
        end
        -- Infer to the simplified version of an indexed access, if possible, to (hopefully) expose more bare type parameters to the inference engine
        local simplified = self:getSimplifiedType(target, false --[[writing]])
        if simplified ~= target then
            self:inferFromTypes(n, source, simplified)
        elseif target.flags & TypeFlags.IndexedAccess ~= 0 then
            local indexType = self:getSimplifiedType(target:AsIndexedAccessType().indexType, false --[[writing]])
            -- Generally simplifications of instantiable indexes are avoided to keep relationship checking correct, however if our target is an access, we can consider
            -- that key of that access to be "instantiated", since we're looking to find the infernce goal in any way we can.
            if indexType.flags & TypeFlags.Instantiable ~= 0 then
                local simplified2 = self:distributeIndexOverObjectType(self:getSimplifiedType(target:AsIndexedAccessType().objectType, false --[[writing]]), indexType, false --[[writing]])
                if simplified2 ~= nil and simplified2 ~= target then
                    self:inferFromTypes(n, source, simplified2)
                end
            end
        end
    end
    if source.objectFlags & ObjectFlags.Reference ~= 0 and target.objectFlags & ObjectFlags.Reference ~= 0 and (source:AsTypeReference().target == target:AsTypeReference().target or self:isArrayType(source) and self:isArrayType(target)) and not (source:AsTypeReference().node ~= nil and target:AsTypeReference().node ~= nil) then
        -- If source and target are references to the same generic type, infer from type arguments
        self:inferFromTypeArguments(n, self:getTypeArguments(source), self:getTypeArguments(target), self:getVariances(source:AsTypeReference().target))
    elseif source.flags & TypeFlags.Index ~= 0 and target.flags & TypeFlags.Index ~= 0 then
        self:inferFromContravariantTypes(n, source:AsIndexType().target, target:AsIndexType().target)
    elseif (checker.isLiteralType(source) or source.flags & TypeFlags.String ~= 0) and target.flags & TypeFlags.Index ~= 0 then
        local empty = self:createEmptyObjectTypeFromStringLiteral(source)
        self:inferFromContravariantTypesWithPriority(n, empty, target:AsIndexType().target, InferencePriority.LiteralKeyof)
    elseif source.flags & TypeFlags.IndexedAccess ~= 0 and target.flags & TypeFlags.IndexedAccess ~= 0 then
        self:inferFromTypes(n, source:AsIndexedAccessType().objectType, target:AsIndexedAccessType().objectType)
        self:inferFromTypes(n, source:AsIndexedAccessType().indexType, target:AsIndexedAccessType().indexType)
    elseif source.flags & TypeFlags.StringMapping ~= 0 and target.flags & TypeFlags.StringMapping ~= 0 then
        if source.symbol == target.symbol then
            self:inferFromTypes(n, source:AsStringMappingType().target, target:AsStringMappingType().target)
        end
    elseif source.flags & TypeFlags.Substitution ~= 0 then
        self:inferFromTypes(n, source:AsSubstitutionType().baseType, target)
        -- Make substitute inference at a lower priority
        self:inferWithPriority(n, self:getSubstitutionIntersection(source), target, InferencePriority.SubstituteSource)
    elseif target.flags & TypeFlags.Conditional ~= 0 then
        self:invokeOnce(n, source, target, Checker.inferToConditionalType)
    elseif target.flags & TypeFlags.UnionOrIntersection ~= 0 then
        self:inferToMultipleTypes(n, source, target:Types(), target.flags)
    elseif source.flags & TypeFlags.Union ~= 0 then
        -- Source is a union or intersection type, infer from each constituent type
        for _, sourceType in ipairs(source:Types()) do
            self:inferFromTypes(n, sourceType, target)
        end
    elseif target.flags & TypeFlags.TemplateLiteral ~= 0 then
        self:inferToTemplateLiteralType(n, source, target:AsTemplateLiteralType())
    else
        source = self:getReducedType(source)
        if self:isGenericMappedType(source) and self:isGenericMappedType(target) then
            self:invokeOnce(n, source, target, Checker.inferFromGenericMappedTypes)
        end
        if not (n.priority & InferencePriority.NoConstraints ~= 0 and source.flags & (TypeFlags.Intersection | TypeFlags.Instantiable) ~= 0) then
            local apparentSource = self:getApparentType(source)
            -- getApparentType can return _any_ type, since an indexed access or conditional may simplify to any other type.
            -- If that occurs and it doesn't simplify to an object or intersection, we'll need to restart `inferFromTypes`
            -- with the simplified source.
            if apparentSource ~= source and apparentSource.flags & (TypeFlags.Object | TypeFlags.Intersection) == 0 then
                self:inferFromTypes(n, apparentSource, target)
                return
            end
            source = apparentSource
        end
        if source.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 then
            self:invokeOnce(n, source, target, Checker.inferFromObjectTypes)
        end
    end
end

function Checker:inferFromTypeArguments(n, sourceTypes, targetTypes, variances)
    for i = 0, math.min(core.Len(sourceTypes), core.Len(targetTypes)) - 1 do
        if i < core.Len(variances) and variances[i + 1] & VarianceFlags.VarianceMask == VarianceFlags.Contravariant then
            self:inferFromContravariantTypes(n, sourceTypes[i + 1], targetTypes[i + 1])
        else
            self:inferFromTypes(n, sourceTypes[i + 1], targetTypes[i + 1])
        end
    end
end

function Checker:inferWithPriority(n, source, target, newPriority)
    local savePriority = n.priority
    n.priority = n.priority | newPriority
    self:inferFromTypes(n, source, target)
    n.priority = savePriority
end

function Checker:inferFromContravariantTypesWithPriority(n, source, target, newPriority)
    local savePriority = n.priority
    n.priority = n.priority | newPriority
    self:inferFromContravariantTypes(n, source, target)
    n.priority = savePriority
end

function Checker:inferFromContravariantTypes(n, source, target)
    n.contravariant = not n.contravariant
    self:inferFromTypes(n, source, target)
    n.contravariant = not n.contravariant
end

function Checker:inferFromContravariantTypesIfStrictFunctionTypes(n, source, target)
    if self.strictFunctionTypes or n.priority & InferencePriority.AlwaysStrict ~= 0 then
        self:inferFromContravariantTypes(n, source, target)
    else
        self:inferFromTypes(n, source, target)
    end
end

-- Ensure an inference action is performed only once for the given source and target types.
-- This includes two things:
-- Avoiding inferring between the same pair of source and target types,
-- and avoiding circularly inferring between source and target types.
-- For an example of the last, consider if we are inferring between source type
-- `type Deep<T> = { next: Deep<Deep<T>> }` and target type `type Loop<U> = { next: Loop<U> }`.
-- We would then infer between the types of the `next` property: `Deep<Deep<T>>` = `{ next: Deep<Deep<Deep<T>>> }` and `Loop<U>` = `{ next: Loop<U> }`.
-- We will then infer again between the types of the `next` property:
-- `Deep<Deep<Deep<T>>>` and `Loop<U>`, and so on, such that we would be forever inferring
-- between instantiations of the same types `Deep` and `Loop`.
-- In particular, we would be inferring from increasingly deep instantiations of `Deep` to `Loop`,
-- such that we would go on inferring forever, even though we would never infer
-- between the same pair of types.
-- action is a Go method expression: action(c, n, source, target).
function Checker:invokeOnce(n, source, target, action)
    local key = checker.InferenceKey(source.id, target.id)
    if n.visited ~= nil then
        local status = n.visited[key]
        if status ~= nil then
            n.inferencePriority = math.min(n.inferencePriority, status)
            return
        end
    end
    if n.visited == nil then
        n.visited = {}
    end
    n.visited[key] = InferencePriority.Circularity
    local saveInferencePriority = n.inferencePriority
    n.inferencePriority = InferencePriority.MaxValue
    -- We stop inferring and report a circularity if we encounter duplicate recursion identities on both
    -- the source side and the target side.
    local saveExpandingFlags = n.expandingFlags
    n.sourceStack[#n.sourceStack + 1] = source
    n.targetStack[#n.targetStack + 1] = target
    if self:isDeeplyNestedType(source, n.sourceStack, 2) then
        n.expandingFlags = n.expandingFlags | ExpandingFlags.Source
    end
    if self:isDeeplyNestedType(target, n.targetStack, 2) then
        n.expandingFlags = n.expandingFlags | ExpandingFlags.Target
    end
    if n.expandingFlags ~= ExpandingFlags.Both then
        action(self, n, source, target)
    else
        n.inferencePriority = InferencePriority.Circularity
    end
    n.targetStack[#n.targetStack] = nil
    n.sourceStack[#n.sourceStack] = nil
    n.expandingFlags = saveExpandingFlags
    n.visited[key] = n.inferencePriority
    n.inferencePriority = math.min(n.inferencePriority, saveInferencePriority)
end

-- matches is a Go method expression: matches(c, s, t).
function Checker:inferFromMatchingTypes(n, sources, targets, matches, sort)
    local matchedSources
    local matchedTargets
    for _, t in ipairs(targets or {}) do
        for _, s in ipairs(sources or {}) do
            if matches(self, s, t) then
                if not sort then
                    self:inferFromTypes(n, s, t)
                end
                matchedSources = core.AppendIfUnique(matchedSources, s)
                matchedTargets = core.AppendIfUnique(matchedTargets, t)
            end
        end
    end
    if sort then
        -- Sort target types by decreasing depth of generic instantiations. Intuitively, a successful
        -- inference from a type argument with deeper nesting is of higher quality because we've stripped
        -- away more layers of type instantiations that otherwise might skew the results. For example,
        -- when inferring from string[] | string[][] to T[] | T[][], the inference of string we make from
        -- relating string[][] to T[][] is of higher quality than the inference of string[] we make relating
        -- string[][] to T[].
        if matchedTargets ~= nil then
            core.SortFunc(matchedTargets, function(t1, t2)
                return checker.compareTypesAndDepth(t1, t2)
            end)
        end
        for _, t in ipairs(matchedTargets or {}) do
            for _, s in ipairs(matchedSources or {}) do
                if matches(self, s, t) then
                    self:inferFromTypes(n, s, t)
                end
            end
        end
    end
    if core.Len(matchedSources) ~= 0 then
        sources = core.Filter(sources, function(t)
            return not containsValue(matchedSources, t)
        end)
    end
    if core.Len(matchedTargets) ~= 0 then
        targets = core.Filter(targets, function(t)
            return not containsValue(matchedTargets, t)
        end)
    end
    return sources, targets
end

-- Compare two types first by depth and then by the regular type ordering.
function checker.compareTypesAndDepth(t1, t2)
    local d1 = checker.getTypeDepth(t1, 3)
    local d2 = checker.getTypeDepth(t2, 3)
    if d1 ~= d2 then
        return d2 - d1 -- Largest depth sorts first
    end
    return checker.CompareTypes(t1, t2)
end

-- Return the depth of the given type up to the given maximum depth. For generic aliased types
-- and type references, the depth is one plus the largest type argument depth. For union and
-- intersection types, the depth is the largest constituent type depth. For all other types,
-- the depth is zero. The maximum depth limits infinite recursion of circular types.
function checker.getTypeDepth(t, maxDepth)
    if maxDepth ~= 0 then
        if t.alias ~= nil and core.Len(t.alias.typeArguments) ~= 0 then
            return checker.getTypeListDepth(t.alias.typeArguments, maxDepth - 1) + 1
        end
        if t.objectFlags & ObjectFlags.Reference ~= 0 then
            local typeArguments = t.checker:getTypeArguments(t)
            if core.Len(typeArguments) ~= 0 then
                return checker.getTypeListDepth(typeArguments, maxDepth - 1) + 1
            end
        end
        if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
            return checker.getTypeListDepth(t:Types(), maxDepth)
        end
    end
    return 0
end

function checker.getTypeListDepth(types, maxDepth)
    local depth = 0
    for _, t in ipairs(types or {}) do
        depth = math.max(depth, checker.getTypeDepth(t, maxDepth))
    end
    return depth
end

function Checker:inferToMultipleTypes(n, source, targets, targetFlags)
    local typeVariableCount = 0
    if targetFlags & TypeFlags.Union ~= 0 then
        local nakedTypeVariable
        local sources
        if source.flags & TypeFlags.Union ~= 0 then
            sources = source:Types()
        else
            sources = { source }
        end
        local matched = {}
        for i = 1, #sources do
            matched[i] = false
        end
        local inferenceCircularity = false
        -- First infer to types that are not naked type variables. For each source type we
        -- track whether inferences were made from that particular type to some target with
        -- equal priority (i.e. of equal quality) to what we would infer for a naked type
        -- parameter.
        for _, t in ipairs(targets) do
            if checker.getInferenceInfoForType(n, t) ~= nil then
                nakedTypeVariable = t
                typeVariableCount = typeVariableCount + 1
            else
                for i = 1, #sources do
                    local saveInferencePriority = n.inferencePriority
                    n.inferencePriority = InferencePriority.MaxValue
                    self:inferFromTypes(n, sources[i], t)
                    if n.inferencePriority == n.priority then
                        matched[i] = true
                    end
                    inferenceCircularity = inferenceCircularity or n.inferencePriority == InferencePriority.Circularity
                    n.inferencePriority = math.min(n.inferencePriority, saveInferencePriority)
                end
            end
        end
        if typeVariableCount == 0 then
            -- If every target is an intersection of types containing a single naked type variable,
            -- make a lower priority inference to that type variable. This handles inferring from
            -- 'A | B' to 'T & (X | Y)' where we want to infer 'A | B' for T.
            local intersectionTypeVariable = checker.getSingleTypeVariableFromIntersectionTypes(n, targets)
            if intersectionTypeVariable ~= nil then
                self:inferWithPriority(n, source, intersectionTypeVariable, InferencePriority.NakedTypeVariable)
            end
            return
        end
        -- If the target has a single naked type variable and no inference circularities were
        -- encountered above (meaning we explored the types fully), create a union of the source
        -- types from which no inferences have been made so far and infer from that union to the
        -- naked type variable.
        if typeVariableCount == 1 and not inferenceCircularity then
            local unmatched = {}
            for i, s in ipairs(sources) do
                if not matched[i] then
                    unmatched[#unmatched + 1] = s
                end
            end
            if #unmatched ~= 0 then
                self:inferFromTypes(n, self:getUnionType(unmatched), nakedTypeVariable)
                return
            end
        end
    else
        -- We infer from types that are not naked type variables first so that inferences we
        -- make from nested naked type variables and given slightly higher priority by virtue
        -- of being first in the candidates array.
        for _, t in ipairs(targets) do
            if checker.getInferenceInfoForType(n, t) ~= nil then
                typeVariableCount = typeVariableCount + 1
            else
                self:inferFromTypes(n, source, t)
            end
        end
    end
    -- Inferences directly to naked type variables are given lower priority as they are
    -- less specific. For example, when inferring from Promise<string> to T | Promise<T>,
    -- we want to infer string for T, not Promise<string> | string. For intersection types
    -- we only infer to single naked type variables.
    if targetFlags & TypeFlags.Intersection ~= 0 and typeVariableCount == 1 or targetFlags & TypeFlags.Intersection == 0 and typeVariableCount > 0 then
        for _, t in ipairs(targets) do
            if checker.getInferenceInfoForType(n, t) ~= nil then
                self:inferWithPriority(n, source, t, InferencePriority.NakedTypeVariable)
            end
        end
    end
end

function checker.getSingleTypeVariableFromIntersectionTypes(n, types)
    local typeVariable
    for _, t in ipairs(types or {}) do
        if t.flags & TypeFlags.Intersection == 0 then
            return nil
        end
        local v = core.Find(t:Types(), function(t)
            return checker.getInferenceInfoForType(n, t) ~= nil
        end)
        if v == nil or typeVariable ~= nil and v ~= typeVariable then
            return nil
        end
        typeVariable = v
    end
    return typeVariable
end

function Checker:inferToMultipleTypesWithPriority(n, source, targets, targetFlags, newPriority)
    local savePriority = n.priority
    n.priority = n.priority | newPriority
    self:inferToMultipleTypes(n, source, targets, targetFlags)
    n.priority = savePriority
end

function Checker:inferToConditionalType(n, source, target)
    if source.flags & TypeFlags.Conditional ~= 0 then
        self:inferFromTypes(n, source:AsConditionalType().checkType, target:AsConditionalType().checkType)
        self:inferFromTypes(n, source:AsConditionalType().extendsType, target:AsConditionalType().extendsType)
        self:inferFromTypes(n, self:getTrueTypeFromConditionalType(source), self:getTrueTypeFromConditionalType(target))
        self:inferFromTypes(n, self:getFalseTypeFromConditionalType(source), self:getFalseTypeFromConditionalType(target))
    else
        local targetTypes = { self:getTrueTypeFromConditionalType(target), self:getFalseTypeFromConditionalType(target) }
        self:inferToMultipleTypesWithPriority(n, source, targetTypes, target.flags, core.IfElse(n.contravariant, InferencePriority.ContravariantConditional, 0))
    end
end

function Checker:inferToTemplateLiteralType(n, source, target)
    local matches = self:inferTypesFromTemplateLiteralType(source, target)
    local types = target.types
    -- When the target template literal contains only placeholders (meaning that inference is intended to extract
    -- single characters and remainder strings) and inference fails to produce matches, we want to infer 'never' for
    -- each placeholder such that instantiation with the inferred value(s) produces 'never', a type for which an
    -- assignment check will fail. If we make no inferences, we'll likely end up with the constraint 'string' which,
    -- upon instantiation, would collapse all the placeholders to just 'string', and an assignment check might
    -- succeed. That would be a pointless and confusing outcome.
    if core.Len(matches) ~= 0 or core.Every(target.texts, function(s)
        return s == ""
    end) then
        for i1, target in ipairs(types or {}) do
            local source
            if core.Len(matches) ~= 0 then
                source = matches[i1]
            else
                source = self.neverType
            end
            -- If we are inferring from a string literal type to a type variable whose constraint includes one of the
            -- allowed template literal placeholder types, infer from a literal type corresponding to the constraint.
            if source.flags & TypeFlags.StringLiteral ~= 0 and target.flags & TypeFlags.TypeVariable ~= 0 then
                local inferenceContext = checker.getInferenceInfoForType(n, target)
                if inferenceContext ~= nil then
                    local constraint = self:getBaseConstraintOfType(inferenceContext.typeParameter)
                    if constraint ~= nil and not checker.IsTypeAny(constraint) then
                        local allTypeFlags = TypeFlags.None
                        for _, t in ipairs(constraint:Distributed()) do
                            allTypeFlags = allTypeFlags | t.flags
                        end
                        -- If the constraint contains `string`, we don't need to look for a more preferred type
                        if allTypeFlags & TypeFlags.String == 0 then
                            local str = checker.getStringLiteralValue(source)
                            -- If the type contains `number` or a number literal and the string isn't a valid number, exclude numbers
                            if allTypeFlags & TypeFlags.NumberLike ~= 0 and not checker.isValidNumberString(str, true --[[roundTripOnly]]) then
                                allTypeFlags = allTypeFlags & ~TypeFlags.NumberLike
                            end
                            -- If the type contains `bigint` or a bigint literal and the string isn't a valid bigint, exclude bigints
                            if allTypeFlags & TypeFlags.BigIntLike ~= 0 and not checker.isValidBigIntString(str, true --[[roundTripOnly]]) then
                                allTypeFlags = allTypeFlags & ~TypeFlags.BigIntLike
                            end
                            local choose = function(left, right)
                                if right.flags & allTypeFlags == 0 then
                                    return left
                                elseif left.flags & TypeFlags.String ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.String ~= 0 then
                                    return source
                                elseif left.flags & TypeFlags.TemplateLiteral ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.TemplateLiteral ~= 0 and self:isTypeMatchedByTemplateLiteralType(source, right:AsTemplateLiteralType(), self.compareTypesAssignable) then
                                    return source
                                elseif left.flags & TypeFlags.StringMapping ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.StringMapping ~= 0 and str == checker.applyStringMapping(right.symbol, str) then
                                    return source
                                elseif left.flags & TypeFlags.StringLiteral ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.StringLiteral ~= 0 and checker.getStringLiteralValue(right) == str then
                                    return right
                                elseif left.flags & TypeFlags.Number ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.Number ~= 0 then
                                    return self:getNumberLiteralType(jsnum.FromString(str))
                                elseif left.flags & TypeFlags.Enum ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.Enum ~= 0 then
                                    return self:getNumberLiteralType(jsnum.FromString(str))
                                elseif left.flags & TypeFlags.NumberLiteral ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.NumberLiteral ~= 0 and checker.getNumberLiteralValue(right) == jsnum.FromString(str) then
                                    return right
                                elseif left.flags & TypeFlags.BigInt ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.BigInt ~= 0 then
                                    return self:parseBigIntLiteralType(str)
                                elseif left.flags & TypeFlags.BigIntLiteral ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.BigIntLiteral ~= 0 and checker.pseudoBigIntToString(checker.getBigIntLiteralValue(right)) == str then
                                    return right
                                elseif left.flags & TypeFlags.Boolean ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.Boolean ~= 0 then
                                    if str == "true" then
                                        return self.trueType
                                    elseif str == "false" then
                                        return self.falseType
                                    else
                                        return self.booleanType
                                    end
                                elseif left.flags & TypeFlags.BooleanLiteral ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.BooleanLiteral ~= 0 and core.IfElse(checker.getBooleanLiteralValue(right), "true", "false") == str then
                                    return right
                                elseif left.flags & TypeFlags.Undefined ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.Undefined ~= 0 and right:AsIntrinsicType().intrinsicName == str then
                                    return right
                                elseif left.flags & TypeFlags.Null ~= 0 then
                                    return left
                                elseif right.flags & TypeFlags.Null ~= 0 and right:AsIntrinsicType().intrinsicName == str then
                                    return right
                                else
                                    return left
                                end
                            end
                            local matchingType = self.neverType
                            for _, t in ipairs(constraint:Distributed()) do
                                matchingType = choose(matchingType, t)
                            end
                            if matchingType.flags & TypeFlags.Never == 0 then
                                self:inferFromTypes(n, matchingType, target)
                                goto continue
                            end
                        end
                    end
                end
            end
            self:inferFromTypes(n, source, target)
            ::continue::
        end
    end
end

function Checker:inferFromGenericMappedTypes(n, source, target)
    -- The source and target types are generic types { [P in S]: X } and { [P in T]: Y }, so we infer
    -- from S to T and from X to Y.
    self:inferFromTypes(n, self:getConstraintTypeFromMappedType(source), self:getConstraintTypeFromMappedType(target))
    self:inferFromTypes(n, self:getTemplateTypeFromMappedType(source), self:getTemplateTypeFromMappedType(target))
    local sourceNameType = self:getNameTypeFromMappedType(source)
    local targetNameType = self:getNameTypeFromMappedType(target)
    if sourceNameType ~= nil and targetNameType ~= nil then
        self:inferFromTypes(n, sourceNameType, targetNameType)
    end
end

function Checker:inferFromObjectTypes(n, source, target)
    if source.objectFlags & ObjectFlags.Reference ~= 0 and target.objectFlags & ObjectFlags.Reference ~= 0 and (source:Target() == target:Target() or self:isArrayType(source) and self:isArrayType(target)) then
        -- If source and target are references to the same generic type, infer from type arguments
        self:inferFromTypeArguments(n, self:getTypeArguments(source), self:getTypeArguments(target), self:getVariances(source:Target()))
        return
    end
    if self:isGenericMappedType(source) and self:isGenericMappedType(target) then
        self:inferFromGenericMappedTypes(n, source, target)
    end
    if target.objectFlags & ObjectFlags.Mapped ~= 0 and target:AsMappedType().declaration.nameType == nil then
        local constraintType = self:getConstraintTypeFromMappedType(target)
        if self:inferToMappedType(n, source, target, constraintType) then
            return
        end
    end
    -- Infer from the members of source and target only if the two types are possibly related
    if self:typesDefinitelyUnrelated(source, target) then
        return
    end
    if self:isArrayOrTupleType(source) then
        if checker.isTupleType(target) then
            local sourceArity = self:getTypeReferenceArity(source)
            local targetArity = self:getTypeReferenceArity(target)
            local elementTypes = self:getTypeArguments(target)
            local elementInfos = target:TargetTupleType().elementInfos
            -- When source and target are tuple types with the same structure (fixed, variadic, and rest are matched
            -- to the same kind in each position), simply infer between the element types.
            if checker.isTupleType(source) and self:isTupleTypeStructureMatching(source, target) then
                for i = 0, targetArity - 1 do
                    self:inferFromTypes(n, self:getTypeArguments(source)[i + 1], elementTypes[i + 1])
                end
                return
            end
            local startLength = 0
            local endLength = 0
            if checker.isTupleType(source) then
                startLength = math.min(source:TargetTupleType().fixedLength, target:TargetTupleType().fixedLength)
                if target:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 then
                    endLength = math.min(checker.getEndElementCount(source:TargetTupleType(), ElementFlags.Fixed), checker.getEndElementCount(target:TargetTupleType(), ElementFlags.Fixed))
                end
            end
            -- Infer between starting fixed elements.
            for i = 0, startLength - 1 do
                self:inferFromTypes(n, self:getTypeArguments(source)[i + 1], elementTypes[i + 1])
            end
            if not checker.isTupleType(source) or sourceArity - startLength - endLength == 1 and source:TargetTupleType().elementInfos[startLength + 1].flags & ElementFlags.Rest ~= 0 then
                -- Single rest element remains in source, infer from that to every element in target
                local restType = self:getTypeArguments(source)[startLength + 1]
                for i = startLength, targetArity - endLength - 1 do
                    local t = restType
                    if elementInfos[i + 1].flags & ElementFlags.Variadic ~= 0 then
                        t = self:createArrayType(t)
                    end
                    self:inferFromTypes(n, t, elementTypes[i + 1])
                end
            else
                local middleLength = targetArity - startLength - endLength
                if middleLength == 2 then
                    if elementInfos[startLength + 1].flags & elementInfos[startLength + 2].flags & ElementFlags.Variadic ~= 0 then
                        -- Middle of target is [...T, ...U] and source is tuple type
                        local targetInfo = checker.getInferenceInfoForType(n, elementTypes[startLength + 1])
                        if targetInfo ~= nil and targetInfo.impliedArity >= 0 then
                            -- Infer slices from source based on implied arity of T.
                            self:inferFromTypes(n, self:sliceTupleType(source, startLength, endLength + sourceArity - targetInfo.impliedArity), elementTypes[startLength + 1])
                            self:inferFromTypes(n, self:sliceTupleType(source, startLength + targetInfo.impliedArity, endLength), elementTypes[startLength + 2])
                        end
                    elseif elementInfos[startLength + 1].flags & ElementFlags.Variadic ~= 0 and elementInfos[startLength + 2].flags & ElementFlags.Rest ~= 0 then
                        -- Middle of target is [...T, ...rest] and source is tuple type
                        -- if T is constrained by a fixed-size tuple we might be able to use its arity to infer T
                        local info = checker.getInferenceInfoForType(n, elementTypes[startLength + 1])
                        if info ~= nil then
                            local constraint = self:getBaseConstraintOfType(info.typeParameter)
                            if constraint ~= nil and checker.isTupleType(constraint) and constraint:TargetTupleType().combinedFlags & ElementFlags.Variable == 0 then
                                local impliedArity = constraint:TargetTupleType().fixedLength
                                self:inferFromTypes(n, self:sliceTupleType(source, startLength, sourceArity - (startLength + impliedArity)), elementTypes[startLength + 1])
                                local restType = self:getElementTypeOfSliceOfTupleType(source, startLength + impliedArity, endLength, false, false)
                                if restType ~= nil then
                                    self:inferFromTypes(n, restType, elementTypes[startLength + 2])
                                end
                            end
                        end
                    elseif elementInfos[startLength + 1].flags & ElementFlags.Rest ~= 0 and elementInfos[startLength + 2].flags & ElementFlags.Variadic ~= 0 then
                        -- Middle of target is [...rest, ...T] and source is tuple type
                        -- if T is constrained by a fixed-size tuple we might be able to use its arity to infer T
                        local info = checker.getInferenceInfoForType(n, elementTypes[startLength + 2])
                        if info ~= nil then
                            local constraint = self:getBaseConstraintOfType(info.typeParameter)
                            if constraint ~= nil and checker.isTupleType(constraint) and constraint:TargetTupleType().combinedFlags & ElementFlags.Variable == 0 then
                                local impliedArity = constraint:TargetTupleType().fixedLength
                                local endIndex = sourceArity - checker.getEndElementCount(target:TargetTupleType(), ElementFlags.Fixed)
                                local startIndex = endIndex - impliedArity
                                if startIndex >= startLength then
                                    local trailingSlice = self:createTupleTypeEx(core.Slice(self:getTypeArguments(source), startIndex, endIndex), core.Slice(source:TargetTupleType().elementInfos, startIndex, endIndex), false --[[readonly]])
                                    local restType = self:getElementTypeOfSliceOfTupleType(source, startLength, endLength + impliedArity, false, false)
                                    if restType ~= nil then
                                        self:inferFromTypes(n, restType, elementTypes[startLength + 1])
                                    end
                                    self:inferFromTypes(n, trailingSlice, elementTypes[startLength + 2])
                                end
                            end
                        end
                    end
                elseif middleLength == 1 and elementInfos[startLength + 1].flags & ElementFlags.Variadic ~= 0 then
                    -- Middle of target is exactly one variadic element. Infer the slice between the fixed parts in the source.
                    -- If target ends in optional element(s), make a lower priority a speculative inference.
                    local priority = core.IfElse(elementInfos[targetArity].flags & ElementFlags.Optional ~= 0, InferencePriority.SpeculativeTuple, 0)
                    local sourceSlice = self:sliceTupleType(source, startLength, endLength)
                    self:inferWithPriority(n, sourceSlice, elementTypes[startLength + 1], priority)
                elseif middleLength == 1 and elementInfos[startLength + 1].flags & ElementFlags.Rest ~= 0 then
                    -- Middle of target is exactly one rest element. If middle of source is not empty, infer union of middle element types.
                    local restType = self:getElementTypeOfSliceOfTupleType(source, startLength, endLength, false, false)
                    if restType ~= nil then
                        self:inferFromTypes(n, restType, elementTypes[startLength + 1])
                    end
                end
            end
            -- Infer between ending fixed elements
            for i = 0, endLength - 1 do
                self:inferFromTypes(n, self:getTypeArguments(source)[sourceArity - i], elementTypes[targetArity - i])
            end
            return
        end
        if self:isArrayType(target) then
            self:inferFromIndexTypes(n, source, target)
            return
        end
    end
    self:inferFromProperties(n, source, target)
    self:inferFromSignatures(n, source, target, SignatureKind.Call)
    self:inferFromSignatures(n, source, target, SignatureKind.Construct)
    self:inferFromIndexTypes(n, source, target)
end

function Checker:inferFromProperties(n, source, target)
    local properties = self:getPropertiesOfObjectType(target)
    for _, targetProp in ipairs(properties or {}) do
        local sourceProp = self:getPropertyOfType(source, targetProp.name)
        if sourceProp ~= nil and not core.Some(sourceProp.declarations, function(d)
            return self:isSkipDirectInferenceNode(d)
        end) then
            self:inferFromTypes(n, self:removeMissingType(self:getTypeOfSymbol(sourceProp), sourceProp.flags & SymbolFlags.Optional ~= 0), self:removeMissingType(self:getTypeOfSymbol(targetProp), targetProp.flags & SymbolFlags.Optional ~= 0))
        end
    end
end

function Checker:inferFromSignatures(n, source, target, kind)
    local sourceSignatures = self:getSignaturesOfType(source, kind)
    local sourceLen = core.Len(sourceSignatures)
    if sourceLen > 0 then
        -- We match source and target signatures from the bottom up, and if the source has fewer signatures
        -- than the target, we infer from the first source signature to the excess target signatures.
        local targetSignatures = self:getSignaturesOfType(target, kind)
        local targetLen = core.Len(targetSignatures)
        for i = 0, targetLen - 1 do
            local sourceIndex = math.max(sourceLen - targetLen + i, 0)
            self:inferFromSignature(n, self:getBaseSignature(sourceSignatures[sourceIndex + 1]), self:getErasedSignature(targetSignatures[i + 1]))
        end
    end
end

function Checker:inferFromSignature(n, source, target)
    if source.flags & SignatureFlags.IsNonInferrable == 0 then
        local saveBivariant = n.bivariant
        local kind = Kind.Unknown
        if target.declaration ~= nil then
            kind = target.declaration.kind
        end
        -- Once we descend into a bivariant signature we remain bivariant for all nested inferences
        n.bivariant = n.bivariant or kind == Kind.MethodDeclaration or kind == Kind.MethodSignature or kind == Kind.Constructor
        self:applyToParameterTypes(source, target, function(s, t)
            self:inferFromContravariantTypesIfStrictFunctionTypes(n, s, t)
        end)
        n.bivariant = saveBivariant
    end
    self:applyToReturnTypes(source, target, function(s, t)
        self:inferFromTypes(n, s, t)
    end)
end

function Checker:applyToParameterTypes(source, target, callback)
    local sourceCount = self:getParameterCount(source)
    local targetCount = self:getParameterCount(target)
    local sourceRestType = self:getEffectiveRestType(source)
    local targetRestType = self:getEffectiveRestType(target)
    local targetNonRestCount = targetCount
    if targetRestType ~= nil then
        targetNonRestCount = targetNonRestCount - 1
    end
    local paramCount = targetNonRestCount
    if sourceRestType == nil then
        paramCount = math.min(sourceCount, targetNonRestCount)
    end
    local sourceThisType = self:getThisTypeOfSignature(source)
    if sourceThisType ~= nil then
        local targetThisType = self:getThisTypeOfSignature(target)
        if targetThisType ~= nil then
            callback(sourceThisType, targetThisType)
        end
    end
    for i = 0, paramCount - 1 do
        callback(self:getTypeAtPosition(source, i), self:getTypeAtPosition(target, i))
    end
    if targetRestType ~= nil then
        callback(self:getRestTypeAtPosition(source, paramCount, self:isConstTypeVariable(targetRestType, 0) and not checker.someType(targetRestType, function(t)
            return self:isMutableArrayLikeType(t)
        end) --[[readonly]]), targetRestType)
    end
end

function Checker:applyToReturnTypes(source, target, callback)
    local targetTypePredicate = self:getTypePredicateOfSignature(target)
    if targetTypePredicate ~= nil then
        local sourceTypePredicate = self:getTypePredicateOfSignature(source)
        if sourceTypePredicate ~= nil and self:typePredicateKindsMatch(sourceTypePredicate, targetTypePredicate) and sourceTypePredicate.t ~= nil and targetTypePredicate.t ~= nil then
            callback(sourceTypePredicate.t, targetTypePredicate.t)
            return
        end
    end
    local targetReturnType = self:getReturnTypeOfSignature(target)
    if self.couldContainTypeVariables(targetReturnType) then
        callback(self:getReturnTypeOfSignature(source), targetReturnType)
    end
end

function Checker:inferFromIndexTypes(n, source, target)
    -- Inferences across mapped type index signatures are pretty much the same a inferences to homomorphic variables
    local priority = InferencePriority.None
    if source.objectFlags & target.objectFlags & ObjectFlags.Mapped ~= 0 then
        priority = InferencePriority.HomomorphicMappedType
    end
    local indexInfos = self:getIndexInfosOfType(target)
    if self:isObjectTypeWithInferableIndex(source) then
        for _, targetInfo in ipairs(indexInfos or {}) do
            local propTypes = {}
            for _, prop in ipairs(self:getPropertiesOfType(source) or {}) do
                if self:isApplicableIndexType(self:getLiteralTypeFromProperty(prop, TypeFlags.StringOrNumberLiteralOrUnique, false), targetInfo.keyType) then
                    local propType = self:getTypeOfSymbol(prop)
                    if prop.flags & SymbolFlags.Optional ~= 0 then
                        propType = self:removeMissingOrUndefinedType(propType)
                    end
                    propTypes[#propTypes + 1] = propType
                end
            end
            for _, info in ipairs(self:getIndexInfosOfType(source) or {}) do
                if self:isApplicableIndexType(info.keyType, targetInfo.keyType) then
                    propTypes[#propTypes + 1] = info.valueType
                end
            end
            if #propTypes ~= 0 then
                self:inferWithPriority(n, self:getUnionType(propTypes), targetInfo.valueType, priority)
            end
        end
    end
    for _, targetInfo in ipairs(indexInfos or {}) do
        local sourceInfo = self:getApplicableIndexInfo(source, targetInfo.keyType)
        if sourceInfo ~= nil then
            self:inferWithPriority(n, sourceInfo.valueType, targetInfo.valueType, priority)
        end
    end
end

function Checker:inferToMappedType(n, source, target, constraintType)
    if constraintType.flags & TypeFlags.Union ~= 0 or constraintType.flags & TypeFlags.Intersection ~= 0 then
        local result = false
        for _, t in ipairs(constraintType:Types()) do
            result = self:inferToMappedType(n, source, target, t) or result
        end
        return result
    end
    if constraintType.flags & TypeFlags.Index ~= 0 then
        -- We're inferring from some source type S to a homomorphic mapped type { [P in keyof T]: X },
        -- where T is a type variable. Use inferTypeForHomomorphicMappedType to infer a suitable source
        -- type and then make a secondary inference from that type to T. We make a secondary inference
        -- such that direct inferences to T get priority over inferences to Partial<T>, for example.
        local inference = checker.getInferenceInfoForType(n, constraintType:AsIndexType().target)
        if inference ~= nil and not inference.isFixed and not self:isFromInferenceBlockedSource(source) then
            local inferredType = self:inferTypeForHomomorphicMappedType(source, target, constraintType)
            if inferredType ~= nil then
                -- We assign a lower priority to inferences made from types containing non-inferrable
                -- types because we may only have a partial result (i.e. we may have failed to make
                -- reverse inferences for some properties).
                self:inferWithPriority(n, inferredType, inference.typeParameter, core.IfElse(source.objectFlags & ObjectFlags.NonInferrableType ~= 0, InferencePriority.PartialHomomorphicMappedType, InferencePriority.HomomorphicMappedType))
            end
        end
        return true
    end
    if constraintType.flags & TypeFlags.TypeParameter ~= 0 then
        -- We're inferring from some source type S to a mapped type { [P in K]: X }, where K is a type
        -- parameter. First infer from 'keyof S' to K.
        self:inferWithPriority(n, self:getIndexTypeEx(source, core.IfElse(self.patternForType[source] ~= nil, IndexFlags.NoIndexSignatures, IndexFlags.None)), constraintType, InferencePriority.MappedTypeConstraint)
        -- If K is constrained to a type C, also infer to C. Thus, for a mapped type { [P in K]: X },
        -- where K extends keyof T, we make the same inferences as for a homomorphic mapped type
        -- { [P in keyof T]: X }. This enables us to make meaningful inferences when the target is a
        -- Pick<T, K>.
        local extendedConstraint = self:getConstraintOfType(constraintType)
        if extendedConstraint ~= nil and self:inferToMappedType(n, source, target, extendedConstraint) then
            return true
        end
        -- If no inferences can be made to K's constraint, infer from a union of the property types
        -- in the source to the template type X.
        local propTypes = core.Map(self:getPropertiesOfType(source), function(s)
            return self:getTypeOfSymbol(s)
        end)
        local indexTypes = core.Map(self:getIndexInfosOfType(source), function(info)
            if info ~= self.enumNumberIndexInfo then
                return info.valueType
            end
            return self.neverType
        end)
        self:inferFromTypes(n, self:getUnionType(core.Concatenate(propTypes, indexTypes)), self:getTemplateTypeFromMappedType(target))
        return true
    end
    return false
end

-- Infer a suitable input type for a homomorphic mapped type { [P in keyof T]: X }. We construct
-- an object type with the same set of properties as the source type, where the type of each
-- property is computed by inferring from the source property type to X for the type
-- variable T[P] (i.e. we treat the type T[P] as the type variable we're inferring for).
function Checker:inferTypeForHomomorphicMappedType(source, target, constraint)
    local key = checker.ReverseMappedTypeKey(source.id, target.id, constraint.id)
    local cached = self.reverseHomomorphicMappedCache[key]
    if cached ~= nil then
        return cached
    end
    local t = self:createReverseMappedType(source, target, constraint)
    self.reverseHomomorphicMappedCache[key] = t
    return t
end

function Checker:createReverseMappedType(source, target, constraint)
    -- We consider a source type reverse mappable if it has a string index signature or if
    -- it has one or more properties and is of a partially inferable type.
    if not (self:getIndexInfoOfType(source, self.stringType) ~= nil or core.Len(self:getPropertiesOfType(source)) ~= 0 and self:isPartiallyInferableType(source)) then
        return nil
    end
    -- For arrays and tuples we infer new arrays and tuples where the reverse mapping has been
    -- applied to the element type(s).
    if self:isArrayType(source) then
        local elementType = self:inferReverseMappedType(self:getTypeArguments(source)[1], target, constraint)
        if elementType == nil then
            return nil
        end
        return self:createArrayTypeEx(elementType, self:isReadonlyArrayType(source))
    end
    if checker.isTupleType(source) then
        -- Go maps to a slice that may hold nils and then checks them; Lua arrays cannot hold nil holes.
        local sourceElementTypes = self:getElementTypes(source)
        local elementTypes = {}
        local allDefined = true
        for i, t in ipairs(sourceElementTypes or {}) do
            local e = self:inferReverseMappedType(t, target, constraint)
            if e == nil then
                allDefined = false
            end
            elementTypes[i] = e
        end
        if not allDefined then
            return nil
        end
        local elementInfos = source:TargetTupleType().elementInfos
        if checker.getMappedTypeModifiers(target) & MappedTypeModifiers.IncludeOptional ~= 0 then
            elementInfos = core.SameMap(elementInfos, function(info)
                if info.flags & ElementFlags.Optional ~= 0 then
                    return checker.TupleElementInfo_new({ flags = ElementFlags.Required, labeledDeclaration = info.labeledDeclaration })
                end
                return info
            end)
        end
        return self:createTupleTypeEx(elementTypes, elementInfos, source:TargetTupleType().readonly)
    end
    -- For all other object types we infer a new object type where the reverse mapping has been
    -- applied to the type of each property.
    local reversed = self:newObjectType(ObjectFlags.ReverseMapped | ObjectFlags.Anonymous, nil --[[symbol]])
    reversed:AsReverseMappedType().source = source
    reversed:AsReverseMappedType().mappedType = target
    reversed:AsReverseMappedType().constraintType = constraint
    return reversed
end

-- We consider a type to be partially inferable if it isn't marked non-inferable or if it is
-- an object literal type with at least one property of an inferable type. For example, an object
-- literal { a: 123, b: x => true } is marked non-inferable because it contains a context sensitive
-- arrow function, but is considered partially inferable because property 'a' has an inferable type.
function Checker:isPartiallyInferableType(t)
    return t.objectFlags & ObjectFlags.NonInferrableType == 0 or checker.isObjectLiteralType(t) and core.Some(self:getPropertiesOfType(t), function(prop)
        return self:isPartiallyInferableType(self:getTypeOfSymbol(prop))
    end) or checker.isTupleType(t) and core.Some(self:getElementTypes(t), function(e)
        return self:isPartiallyInferableType(e)
    end)
end

function Checker:inferReverseMappedType(source, target, constraint)
    local key = checker.ReverseMappedTypeKey(source.id, target.id, constraint.id)
    -- A cached nil result is stored as false (Go map entries may hold nil).
    local cached = self.reverseMappedCache[key]
    if cached ~= nil then
        if cached == false then
            return self.unknownType
        end
        return cached
    end
    self.reverseMappedSourceStack[#self.reverseMappedSourceStack + 1] = source
    self.reverseMappedTargetStack[#self.reverseMappedTargetStack + 1] = target
    local saveExpandingFlags = self.reverseExpandingFlags
    if self:isDeeplyNestedType(source, self.reverseMappedSourceStack, 2) then
        self.reverseExpandingFlags = self.reverseExpandingFlags | ExpandingFlags.Source
    end
    if self:isDeeplyNestedType(target, self.reverseMappedTargetStack, 2) then
        self.reverseExpandingFlags = self.reverseExpandingFlags | ExpandingFlags.Target
    end
    local t
    if self.reverseExpandingFlags ~= ExpandingFlags.Both then
        t = self:inferReverseMappedTypeWorker(source, target, constraint)
    end
    self.reverseMappedSourceStack[#self.reverseMappedSourceStack] = nil
    self.reverseMappedTargetStack[#self.reverseMappedTargetStack] = nil
    self.reverseExpandingFlags = saveExpandingFlags
    if t == nil then
        self.reverseMappedCache[key] = false
    else
        self.reverseMappedCache[key] = t
    end
    return t
end

function Checker:inferReverseMappedTypeWorker(source, target, constraint)
    local typeParameter = self:getIndexedAccessType(constraint:AsIndexType().target, self:getTypeParameterFromMappedType(target))
    local templateType = self:getTemplateTypeFromMappedType(target)
    local inference = checker.newInferenceInfo(typeParameter)
    self:inferTypes({ inference }, source, templateType, InferencePriority.None, false)
    return self:getWidenedType(core.Coalesce(self:getTypeFromInference(inference), self.unknownType))
end

function Checker:resolveReverseMappedTypeMembers(t)
    local r = t:AsReverseMappedType()
    local indexInfo = self:getIndexInfoOfType(r.source, self.stringType)
    local modifiers = checker.getMappedTypeModifiers(r.mappedType)
    local readonlyMask = modifiers & MappedTypeModifiers.IncludeReadonly == 0
    local optionalMask = core.IfElse(modifiers & MappedTypeModifiers.IncludeOptional ~= 0, 0, SymbolFlags.Optional)
    local indexInfos
    if indexInfo ~= nil then
        indexInfos = { self:newIndexInfo(self.stringType, core.Coalesce(self:inferReverseMappedType(indexInfo.valueType, r.mappedType, r.constraintType), self.unknownType), readonlyMask and indexInfo.isReadonly, nil, nil) }
    end
    local members = ast.NewSymbolTable()
    local limitedConstraint = self:getLimitedConstraint(t)
    for _, prop in ipairs(self:getPropertiesOfType(r.source) or {}) do
        -- In case of a reverse mapped type with an intersection constraint, if we were able to
        -- extract the filtering type literals we skip those properties that are not assignable to them,
        -- because the extra properties wouldn't get through the application of the mapped type anyway
        if limitedConstraint ~= nil then
            local propertyNameType = self:getLiteralTypeFromProperty(prop, TypeFlags.StringOrNumberLiteralOrUnique, false)
            if not self:isTypeAssignableTo(propertyNameType, limitedConstraint) then
                goto continue
            end
        end
        do
            local checkFlags = CheckFlags.ReverseMapped | core.IfElse(readonlyMask and self:isReadonlySymbol(prop), CheckFlags.Readonly, 0)
            local inferredProp = self:newSymbolEx(SymbolFlags.Property | prop.flags & optionalMask, prop.name, checkFlags)
            inferredProp.declarations = prop.declarations
            self.valueSymbolLinks:Get(inferredProp).nameType = self.valueSymbolLinks:Get(prop).nameType
            local links = self.reverseMappedSymbolLinks:Get(inferredProp)
            links.propertyType = self:getTypeOfSymbol(prop)
            local constraintTarget = r.constraintType:AsIndexType().target
            if constraintTarget.flags & TypeFlags.IndexedAccess ~= 0 and constraintTarget:AsIndexedAccessType().objectType.flags & TypeFlags.TypeParameter ~= 0 and constraintTarget:AsIndexedAccessType().indexType.flags & TypeFlags.TypeParameter ~= 0 then
                -- A reverse mapping of `{[K in keyof T[K_1]]: T[K_1]}` is the same as that of `{[K in keyof T]: T}`, since all we care about is
                -- inferring to the "type parameter" (or indexed access) shared by the constraint and template. So, to reduce the number of
                -- type identities produced, we simplify such indexed access occurrences
                local newTypeParam = constraintTarget:AsIndexedAccessType().objectType
                local newMappedType = self:replaceIndexedAccess(r.mappedType, constraintTarget, newTypeParam)
                links.mappedType = newMappedType
                links.constraintType = self:getIndexType(newTypeParam)
            else
                links.mappedType = r.mappedType
                links.constraintType = r.constraintType
            end
            members[prop.name] = inferredProp
        end
        ::continue::
    end
    self:setStructuredTypeMembers(t, members, nil, nil, indexInfos)
end

function Checker:getTypeOfReverseMappedSymbol(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        local reverseLinks = self.reverseMappedSymbolLinks:Get(symbol)
        links.resolvedType = core.Coalesce(self:inferReverseMappedType(reverseLinks.propertyType, reverseLinks.mappedType, reverseLinks.constraintType), self.unknownType)
    end
    return links.resolvedType
end

-- If the original mapped type had an intersection constraint we extract its components,
-- and we make an attempt to do so even if the intersection has been reduced to a union.
-- This entire process allows us to possibly retrieve the filtering type literals.
-- e.g. { [K in keyof U & ("a" | "b") ] } -> "a" | "b"
function Checker:getLimitedConstraint(t)
    local constraint = self:getConstraintTypeFromMappedType(t:AsReverseMappedType().mappedType)
    if not (constraint.flags & TypeFlags.Union ~= 0 or constraint.flags & TypeFlags.Intersection ~= 0) then
        return nil
    end
    local origin = constraint
    if constraint.flags & TypeFlags.Union ~= 0 then
        origin = constraint:AsUnionType().origin
    end
    if origin == nil or origin.flags & TypeFlags.Intersection == 0 then
        return nil
    end
    local constraintType = t:AsReverseMappedType().constraintType
    local limitedConstraint = self:getIntersectionType(core.Filter(origin:Types(), function(t)
        return t ~= constraintType
    end))
    if limitedConstraint ~= self.neverType then
        return limitedConstraint
    end
    return nil
end

function Checker:replaceIndexedAccess(instantiable, t, replacement)
    -- map type.indexType to 0
    -- map type.objectType to `[TReplacement]`
    -- thus making the indexed access `[TReplacement][0]` or `TReplacement`
    return self:instantiateType(instantiable, checker.newTypeMapper({ t:AsIndexedAccessType().indexType, t:AsIndexedAccessType().objectType }, { self:getNumberLiteralType(0.0), self:createTupleType({ replacement }) }))
end

function Checker:typesDefinitelyUnrelated(source, target)
    -- Two tuple types with incompatible arities are definitely unrelated.
    -- Two object types that each have a property that is unmatched in the other are definitely unrelated.
    if checker.isTupleType(source) and checker.isTupleType(target) then
        return checker.tupleTypesDefinitelyUnrelated(source, target)
    end
    return self:getUnmatchedProperty(source, target, false --[[requireOptionalProperties]], true --[[matchDiscriminantProperties]]) ~= nil and
        self:getUnmatchedProperty(target, source, false --[[requireOptionalProperties]], false --[[matchDiscriminantProperties]]) ~= nil
end

function checker.tupleTypesDefinitelyUnrelated(source, target)
    local s = source:TargetTupleType()
    local t = target:TargetTupleType()
    return t.combinedFlags & ElementFlags.Variadic == 0 and t.minLength > s.minLength or
        t.combinedFlags & ElementFlags.Variable == 0 and (s.combinedFlags & ElementFlags.Variable ~= 0 or t.fixedLength < s.fixedLength)
end

function Checker:isTupleTypeStructureMatching(t1, t2)
    if self:getTypeReferenceArity(t1) ~= self:getTypeReferenceArity(t2) then
        return false
    end
    for i, e in ipairs(t1:TargetTupleType().elementInfos) do
        if e.flags & ElementFlags.Variable ~= t2:TargetTupleType().elementInfos[i].flags & ElementFlags.Variable then
            return false
        end
    end
    return true
end

function Checker:isTypeOrBaseIdenticalTo(s, t)
    if t == self.missingType then
        return s == t
    end
    return self:isTypeIdenticalTo(s, t) or
        t.flags & TypeFlags.String ~= 0 and s.flags & TypeFlags.StringLiteral ~= 0 or
        t.flags & TypeFlags.Number ~= 0 and s.flags & TypeFlags.NumberLiteral ~= 0
end

function Checker:isTypeCloselyMatchedBy(s, t)
    return s.flags & TypeFlags.Object ~= 0 and t.flags & TypeFlags.Object ~= 0 and s.symbol ~= nil and s.symbol == t.symbol or
        s.alias ~= nil and t.alias ~= nil and core.Len(s.alias.typeArguments) ~= 0 and s.alias.symbol == t.alias.symbol
end

-- Create an object with properties named in the string literal type. Every property has type `any`.
function Checker:createEmptyObjectTypeFromStringLiteral(t)
    local members = ast.NewSymbolTable()
    for _, t in ipairs(t:Distributed()) do
        if t.flags & TypeFlags.StringLiteral ~= 0 then
            local name = checker.getStringLiteralValue(t)
            local literalProp = self:newSymbol(SymbolFlags.Property, name)
            self.valueSymbolLinks:Get(literalProp).resolvedType = self.anyType
            if t.symbol ~= nil then
                literalProp.declarations = t.symbol.declarations
                literalProp.valueDeclaration = t.symbol.valueDeclaration
            end
            members[name] = literalProp
        end
    end
    local indexInfos
    if t.flags & TypeFlags.String ~= 0 then
        indexInfos = { self:newIndexInfo(self.stringType, self.emptyObjectType, false --[[isReadonly]], nil, nil) }
    end
    return self:newAnonymousType(nil, members, nil, nil, indexInfos)
end

function Checker:newInferenceContext(typeParameters, signature, flags, compareTypes)
    if compareTypes == nil then
        compareTypes = self.compareTypesAssignable
    end
    return self:newInferenceContextWorker(core.Map(typeParameters, function(tp)
        return checker.newInferenceInfo(tp)
    end), signature, flags, compareTypes)
end

function Checker:cloneInferenceContext(n, extraFlags)
    if n == nil then
        return nil
    end
    return self:newInferenceContextWorker(core.Map(n.inferences, function(info)
        return checker.cloneInferenceInfo(info)
    end), n.signature, n.flags | extraFlags, n.compareTypes)
end

function Checker:cloneInferredPartOfContext(n)
    local inferences = core.Filter(n.inferences, function(info)
        return checker.hasInferenceCandidates(info)
    end)
    if core.Len(inferences) == 0 then
        return nil
    end
    return self:newInferenceContextWorker(core.Map(inferences, function(info)
        return checker.cloneInferenceInfo(info)
    end), n.signature, n.flags, n.compareTypes)
end

function Checker:newInferenceContextWorker(inferences, signature, flags, compareTypes)
    local n = checker.InferenceContext_new({
        inferences = inferences,
        signature = signature,
        flags = flags,
        compareTypes = compareTypes,
    })
    n.mapper = self:newInferenceTypeMapper(n, true --[[fixing]])
    n.nonFixingMapper = self:newInferenceTypeMapper(n, false --[[fixing]])
    return n
end

function Checker:addIntraExpressionInferenceSite(n, node, t)
    n.intraExpressionInferenceSites = core.Append(n.intraExpressionInferenceSites, checker.IntraExpressionInferenceSite_new({ node = node, t = t }))
end

-- We collect intra-expression inference sites within object and array literals to handle cases where
-- inferred types flow between context sensitive element expressions. For example:
--
--	declare function foo<T>(arg: [(n: number) => T, (x: T) => void]): void;
--	foo([_a => 0, n => n.toFixed()]);
--
-- Above, both arrow functions in the tuple argument are context sensitive, thus both are omitted from the
-- pass that collects inferences from the non-context sensitive parts of the arguments. In the subsequent
-- pass where nothing is omitted, we need to commit to an inference for T in order to contextually type the
-- parameter in the second arrow function, but we want to first infer from the return type of the first
-- arrow function. This happens automatically when the arrow functions are discrete arguments (because we
-- infer from each argument before processing the next), but when the arrow functions are elements of an
-- object or array literal, we need to perform intra-expression inferences early.
function Checker:inferFromIntraExpressionSites(n)
    for _, site in ipairs(n.intraExpressionInferenceSites or {}) do
        local contextualType
        if ast.IsMethodDeclaration(site.node) then
            contextualType = self:getContextualTypeForObjectLiteralMethod(site.node, ContextFlags.NoConstraints)
        else
            contextualType = self:getContextualType(site.node, ContextFlags.NoConstraints)
        end
        if contextualType ~= nil then
            self:inferTypes(n.inferences, site.t, contextualType, InferencePriority.None, false)
        end
    end
    n.intraExpressionInferenceSites = nil
end

function Checker:getInferredType(n, index)
    local inference = n.inferences[index + 1]
    if inference.inferredType == nil then
        if inference.typeParameter == self.errorType then
            return inference.typeParameter
        end
        local inferredType
        local fallbackType
        if n.signature ~= nil then
            local inferredCovariantType
            if core.Len(inference.candidates) ~= 0 then
                inferredCovariantType = self:getCovariantInference(inference, n.signature)
            end
            local inferredContravariantType
            if core.Len(inference.contraCandidates) ~= 0 then
                inferredContravariantType = self:getContravariantInference(inference)
            end
            if inferredCovariantType ~= nil or inferredContravariantType ~= nil then
                -- If we have both co- and contra-variant inferences, we prefer the co-variant inference if it is not 'never',
                -- all co-variant inferences are assignable to it (i.e. it isn't one of a conflicting set of candidates), it is
                -- assignable to some contra-variant inference, and no other type parameter is constrained to this type parameter
                -- and has inferences that would conflict. Otherwise, we prefer the contra-variant inference.
                -- Similarly ignore co-variant `any` inference when both are available as almost everything is assignable to it
                -- and it would spoil the overall inference.
                local preferCovariantType = inferredCovariantType ~= nil and (inferredContravariantType == nil or
                    inferredCovariantType.flags & (TypeFlags.Never | TypeFlags.Any) == 0 and
                    core.Some(inference.contraCandidates, function(t)
                        return self:isTypeAssignableTo(inferredCovariantType, t)
                    end) and
                    core.Every(n.inferences, function(other)
                        return other ~= inference and self:getConstraintOfTypeParameter(other.typeParameter) ~= inference.typeParameter or
                            core.Every(other.candidates, function(t)
                                return self:isTypeAssignableTo(t, inferredCovariantType)
                            end)
                    end))
                if preferCovariantType then
                    inferredType = inferredCovariantType
                    fallbackType = inferredContravariantType
                else
                    inferredType = inferredContravariantType
                    fallbackType = inferredCovariantType
                end
            elseif n.flags & InferenceFlags.NoDefault ~= 0 then
                -- We use silentNeverType as the wildcard that signals no inferences.
                inferredType = self.silentNeverType
            else
                -- Infer either the default or the empty object type when no inferences were
                -- made. It is important to remember that in this case, inference still
                -- succeeds, meaning there is no error for not having inference candidates. An
                -- inference error only occurs when there are *conflicting* candidates, i.e.
                -- candidates with no common supertype.
                local defaultType = self:getDefaultFromTypeParameter(inference.typeParameter)
                if defaultType ~= nil then
                    -- Instantiate the default type. Any forward reference to a type
                    -- parameter should be instantiated to the empty object type.
                    inferredType = self:instantiateType(defaultType, checker.mergeTypeMappers(self:newBackreferenceMapper(n, index), n.nonFixingMapper))
                end
            end
        else
            inferredType = self:getTypeFromInference(inference)
        end
        inference.inferredType = inferredType
        if inference.inferredType == nil then
            inference.inferredType = core.IfElse(n.flags & InferenceFlags.AnyDefault ~= 0, self.anyType, self.unknownType)
        end
        local constraint = self:getConstraintOfTypeParameter(inference.typeParameter)
        if constraint ~= nil then
            local instantiatedConstraint = self:instantiateType(constraint, n.nonFixingMapper)
            if inferredType ~= nil then
                local constraintWithThis = self:getTypeWithThisArgument(instantiatedConstraint, inferredType, false)
                if n.compareTypes(inferredType, constraintWithThis, false) == Ternary.False then
                    local filteredByConstraint
                    if inference.priority == InferencePriority.ReturnType then
                        -- If we have a pure return type inference, we may succeed by removing constituents of the inferred type
                        -- that aren't assignable to the constraint type (pure return type inferences are speculation anyway).
                        filteredByConstraint = self:mapType(inferredType, function(t)
                            return core.IfElse(n.compareTypes(t, constraintWithThis, false) ~= Ternary.False, t, self.neverType)
                        end)
                    end
                    inferredType = core.IfElse(filteredByConstraint ~= nil and filteredByConstraint.flags & TypeFlags.Never == 0, filteredByConstraint, nil)
                end
            end
            if inferredType == nil then
                -- If the fallback type satisfies the constraint, we pick it. Otherwise, we pick the constraint.
                inferredType = core.IfElse(fallbackType ~= nil and n.compareTypes(fallbackType, self:getTypeWithThisArgument(instantiatedConstraint, fallbackType, false), false) ~= Ternary.False, fallbackType, instantiatedConstraint)
            end
            inference.inferredType = inferredType
        end
        self:clearActiveMapperCaches()
    end
    return inference.inferredType
end

function Checker:getInferredTypes(n)
    local result = {}
    for i = 0, #n.inferences - 1 do
        result[i + 1] = self:getInferredType(n, i)
    end
    return result
end

function Checker:getMapperFromContext(n)
    if n == nil then
        return nil
    end
    return n.mapper
end

-- Return a type mapper that combines the context's return mapper with a mapper that erases any additional type parameters
-- to their inferences at the time of creation.
function Checker:createOuterReturnMapper(context)
    if context.outerReturnMapper == nil then
        local mapper = self:cloneInferenceContext(context, InferenceFlags.None).mapper
        if context.returnMapper ~= nil then
            mapper = checker.newMergedTypeMapper(context.returnMapper, mapper)
        end
        context.outerReturnMapper = mapper
    end
    return context.outerReturnMapper
end

function Checker:getCovariantInference(inference, signature)
    -- Extract all object and array literal types and replace them with a single widened and normalized type.
    local candidates = self:unionObjectAndArrayLiteralCandidates(inference.candidates)
    -- We widen inferred literal types if
    -- all inferences were made to top-level occurrences of the type parameter, and
    -- the type parameter has no constraint or its constraint includes no primitive or literal types, and
    -- the type parameter was fixed during inference or does not occur at top-level in the return type.
    local primitiveConstraint = self:hasPrimitiveConstraint(inference.typeParameter) or self:isConstTypeVariable(inference.typeParameter, 0)
    local widenLiteralTypes = not primitiveConstraint and inference.topLevel and (inference.isFixed or not self:isTypeParameterAtTopLevelInReturnType(signature, inference.typeParameter))
    local baseCandidates
    if primitiveConstraint then
        baseCandidates = core.SameMap(candidates, function(t)
            return self:getRegularTypeOfLiteralType(t)
        end)
    elseif widenLiteralTypes then
        baseCandidates = core.SameMap(candidates, function(t)
            return self:getWidenedLiteralType(t)
        end)
    else
        baseCandidates = candidates
    end
    -- If all inferences were made from a position that implies a combined result, infer a union type.
    -- Otherwise, infer a common supertype.
    local unwidenedType
    if inference.priority & InferencePriority.PriorityImpliesCombination ~= 0 then
        unwidenedType = self:getUnionTypeEx(baseCandidates, UnionReduction.Subtype, nil, nil)
    else
        unwidenedType = self:getCommonSupertype(baseCandidates)
    end
    return self:getWidenedType(unwidenedType)
end

function Checker:getContravariantInference(inference)
    if inference.priority & InferencePriority.PriorityImpliesCombination ~= 0 then
        return self:getIntersectionType(inference.contraCandidates)
    end
    return self:getCommonSubtype(inference.contraCandidates)
end

function Checker:unionObjectAndArrayLiteralCandidates(candidates)
    if core.Len(candidates) > 1 then
        local objectLiterals = core.Filter(candidates, function(t)
            return checker.isObjectOrArrayLiteralType(t)
        end)
        if core.Len(objectLiterals) ~= 0 then
            local literalsType = self:getUnionTypeEx(objectLiterals, UnionReduction.Subtype, nil, nil)
            local nonLiteralTypes = core.Filter(candidates, function(t)
                return not checker.isObjectOrArrayLiteralType(t)
            end)
            return core.Concatenate(nonLiteralTypes, { literalsType })
        end
    end
    return candidates
end

function Checker:hasPrimitiveConstraint(t)
    local constraint = self:getConstraintOfTypeParameter(t)
    if constraint ~= nil then
        if constraint.flags & TypeFlags.Conditional ~= 0 then
            constraint = self:getDefaultConstraintOfConditionalType(constraint)
        end
        return self:maybeTypeOfKind(constraint, TypeFlags.Primitive | TypeFlags.Index | TypeFlags.TemplateLiteral | TypeFlags.StringMapping)
    end
    return false
end

function Checker:isTypeParameterAtTopLevel(t, tp, depth)
    return t == tp or
        t.flags & TypeFlags.UnionOrIntersection ~= 0 and core.Some(t:Types(), function(t)
            return self:isTypeParameterAtTopLevel(t, tp, depth)
        end) or
        depth < 3 and t.flags & TypeFlags.Conditional ~= 0 and
        (self:isTypeParameterAtTopLevel(self:getTrueTypeFromConditionalType(t), tp, depth + 1) or
            self:isTypeParameterAtTopLevel(self:getFalseTypeFromConditionalType(t), tp, depth + 1))
end

function Checker:isTypeParameterAtTopLevelInReturnType(signature, typeParameter)
    local typePredicate = self:getTypePredicateOfSignature(signature)
    if typePredicate ~= nil then
        return typePredicate.t ~= nil and self:isTypeParameterAtTopLevel(typePredicate.t, typeParameter, 0)
    end
    return self:isTypeParameterAtTopLevel(self:getReturnTypeOfSignature(signature), typeParameter, 0)
end

function Checker:getTypeFromInference(inference)
    if core.Len(inference.candidates) ~= 0 then
        return self:getUnionTypeEx(inference.candidates, UnionReduction.Subtype, nil, nil)
    elseif core.Len(inference.contraCandidates) ~= 0 then
        return self:getIntersectionType(inference.contraCandidates)
    end
    return nil
end

function checker.getInferenceInfoForType(n, t)
    if t.flags & TypeFlags.TypeVariable ~= 0 then
        for _, inference in ipairs(n.inferences or {}) do
            if t == inference.typeParameter then
                return inference
            end
        end
    end
    return nil
end

function Checker:getCommonSupertype(types)
    if core.Len(types) == 1 then
        return types[1]
    end
    -- Remove nullable types from each of the candidates.
    local primaryTypes = types
    if self.strictNullChecks then
        primaryTypes = core.SameMap(types, function(t)
            return self:filterType(t, function(u)
                return u.flags & TypeFlags.Nullable == 0
            end)
        end)
    end
    -- When the candidate types are all literal types with the same base type, return a union
    -- of those literal types. Otherwise, return the leftmost type for which no type to the
    -- right is a supertype.
    local supertype
    if self:literalTypesWithSameBaseType(primaryTypes) then
        supertype = self:getUnionType(primaryTypes)
    else
        supertype = self:getSingleCommonSupertype(primaryTypes)
    end
    -- Add any nullable types that occurred in the candidates back to the result.
    if core.Same(primaryTypes, types) then
        return supertype
    end
    return self:getNullableType(supertype, self:getCombinedTypeFlags(types) & TypeFlags.Nullable)
end

function Checker:getSingleCommonSupertype(types)
    -- First, find the leftmost type for which no type to the right is a strict supertype, and if that
    -- type is a strict supertype of all other candidates, return it. Otherwise, return the leftmost type
    -- for which no type to the right is a (regular) supertype.
    local candidate = self:findLeftmostType(types, Checker.isTypeStrictSubtypeOf)
    if core.Every(types, function(t)
        return t == candidate or self:isTypeStrictSubtypeOf(t, candidate)
    end) then
        return candidate
    end
    return self:findLeftmostType(types, Checker.isTypeSubtypeOf)
end

-- f is a Go method expression: f(c, s, t).
function Checker:findLeftmostType(types, f)
    local candidate
    for _, t in ipairs(types or {}) do
        if candidate == nil or f(self, candidate, t) then
            candidate = t
        end
    end
    return candidate
end

-- Return the leftmost type for which no type to the right is a subtype.
function Checker:getCommonSubtype(types)
    local subtype
    for _, t in ipairs(types or {}) do
        if subtype == nil or self:isTypeSubtypeOf(t, subtype) then
            subtype = t
        end
    end
    return subtype
end

function Checker:getCombinedTypeFlags(types)
    local flags = TypeFlags.None
    for _, t in ipairs(types or {}) do
        if t.flags & TypeFlags.Union ~= 0 then
            flags = flags | self:getCombinedTypeFlags(t:Types())
        else
            flags = flags | t.flags
        end
    end
    return flags
end

function Checker:literalTypesWithSameBaseType(types)
    local commonBaseType
    for _, t in ipairs(types or {}) do
        if t.flags & TypeFlags.Never == 0 then
            local baseType = self:getBaseTypeOfLiteralType(t)
            if commonBaseType == nil then
                commonBaseType = baseType
            end
            if baseType == t or baseType ~= commonBaseType then
                return false
            end
        end
    end
    return true
end

function Checker:isFromInferenceBlockedSource(t)
    return t.symbol ~= nil and core.Some(t.symbol.declarations, function(d)
        return self:isSkipDirectInferenceNode(d)
    end)
end

function Checker:isSkipDirectInferenceNode(node)
    return self.skipDirectInferenceNodes:Has(node)
end

function checker.newInferenceInfo(typeParameter)
    return checker.InferenceInfo_new({ typeParameter = typeParameter, priority = InferencePriority.MaxValue, topLevel = true, impliedArity = -1 })
end

-- Go slices.Clone: nil stays nil.
local function cloneSlice(xs)
    if xs == nil then
        return nil
    end
    return core.Slice(xs, 0, #xs)
end

function checker.cloneInferenceInfo(info)
    return checker.InferenceInfo_new({
        typeParameter = info.typeParameter,
        candidates = cloneSlice(info.candidates),
        contraCandidates = cloneSlice(info.contraCandidates),
        inferredType = info.inferredType,
        priority = info.priority,
        topLevel = info.topLevel,
        isFixed = info.isFixed,
        impliedArity = info.impliedArity,
    })
end

function checker.clearCachedInferences(inferences)
    for _, inference in ipairs(inferences or {}) do
        if not inference.isFixed then
            inference.inferredType = nil
        end
    end
end

function checker.hasInferenceCandidates(info)
    return core.Len(info.candidates) ~= 0 or core.Len(info.contraCandidates) ~= 0
end

function checker.hasInferenceCandidatesOrDefault(info)
    return checker.hasInferenceCandidates(info) or checker.hasTypeParameterDefault(info.typeParameter)
end

function checker.hasTypeParameterDefault(tp)
    if tp.symbol ~= nil then
        for _, d in ipairs(tp.symbol.declarations or {}) do
            if ast.IsTypeParameterDeclaration(d) and d:AsTypeParameterDeclaration().defaultType ~= nil then
                return true
            end
        end
    end
    return false
end

function checker.hasOverlappingInferences(a, b)
    for i = 1, core.Len(a) do
        if checker.hasInferenceCandidates(a[i]) and checker.hasInferenceCandidates(b[i]) then
            return true
        end
    end
    return false
end

function Checker:mergeInferences(target, source)
    for i = 1, core.Len(target) do
        if not checker.hasInferenceCandidates(target[i]) and checker.hasInferenceCandidates(source[i]) then
            target[i] = source[i]
        end
    end
end
