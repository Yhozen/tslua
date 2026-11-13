local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local jsnum = require("tslua.jsnum")
local scanner = require("tslua.scanner")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local AccessFlags = checker.AccessFlags
local IndexFlags = checker.IndexFlags
local UnionReduction = checker.UnionReduction
local IntersectionFlags = checker.IntersectionFlags
local CachedTypeKind = checker.CachedTypeKind
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags

-- Go slices.BinarySearchFunc(types, t, CompareTypes): returns the 0-based insertion index and
-- whether t was found.
local function binarySearchTypes(types, t)
    local lo, hi = 0, core.Len(types)
    while lo < hi do
        local h = (lo + hi) >> 1
        if checker.CompareTypes(types[h + 1], t) < 0 then
            lo = h + 1
        else
            hi = h
        end
    end
    return lo, lo < core.Len(types) and checker.CompareTypes(types[lo + 1], t) == 0
end

-- Go slices.Contains
local function slicesContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
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

-- Go slices.Clone (nil stays nil)
local function slicesClone(xs)
    if xs == nil then
        return nil
    end
    local result = {}
    for i = 1, #xs do
        result[i] = xs[i]
    end
    return result
end

function checker.isUnaryTupleTypeNode(node)
    return ast.IsTupleTypeNode(node) and core.Len(node:Elements()) == 1
end

function Checker:newType(flags, objectFlags, data)
    self.typeCount = self.typeCount + 1
    local t = data:AsType()
    t.flags = flags
    t.objectFlags = objectFlags & ~(ObjectFlags.CouldContainTypeVariablesComputed | ObjectFlags.CouldContainTypeVariables | ObjectFlags.MembersResolved)
    t.id = self.typeCount
    t.checker = self
    t.data = data
    if self.tracer ~= nil then
        self.tracer:RecordType(t)
    end
    return t
end

function Checker:newIntrinsicType(flags, intrinsicName)
    return self:newIntrinsicTypeEx(flags, intrinsicName, ObjectFlags.None)
end

function Checker:newIntrinsicTypeEx(flags, intrinsicName, objectFlags)
    local data = checker.IntrinsicType_new()
    data.intrinsicName = intrinsicName
    return self:newType(flags, objectFlags, data)
end

function Checker:createWideningType(nonWideningType)
    if self.strictNullChecks then
        return nonWideningType
    end
    local t = self:newIntrinsicType(nonWideningType.flags, nonWideningType:AsIntrinsicType().intrinsicName)
    t.objectFlags = t.objectFlags | ObjectFlags.ContainsWideningType
    return t
end

function Checker:createUnknownUnionType()
    if self.strictNullChecks then
        return self:getUnionType({ self.undefinedType, self.nullType, self.unknownEmptyObjectType })
    end
    return self.unknownType
end

function Checker:newLiteralType(flags, value, regularType)
    local data = checker.LiteralType_new()
    data.value = value
    local t = self:newType(flags, ObjectFlags.None, data)
    if regularType ~= nil then
        data.regularType = regularType
    else
        data.regularType = t
    end
    return t
end

function Checker:newUniqueESSymbolType(symbol, name)
    local data = checker.UniqueESSymbolType_new()
    data.name = name
    local t = self:newType(TypeFlags.UniqueESSymbol, ObjectFlags.None, data)
    t.symbol = symbol
    return t
end

function Checker:newObjectType(objectFlags, symbol)
    local data
    if objectFlags & ObjectFlags.ClassOrInterface ~= 0 then
        data = checker.InterfaceType_new()
    elseif objectFlags & ObjectFlags.Tuple ~= 0 then
        data = checker.TupleType_new()
    elseif objectFlags & ObjectFlags.Reference ~= 0 then
        data = checker.TypeReference_new()
    elseif objectFlags & ObjectFlags.Mapped ~= 0 then
        data = checker.MappedType_new()
    elseif objectFlags & ObjectFlags.ReverseMapped ~= 0 then
        data = checker.ReverseMappedType_new()
    elseif objectFlags & ObjectFlags.EvolvingArray ~= 0 then
        data = checker.EvolvingArrayType_new()
    elseif objectFlags & checker.ObjectFlagsInstantiationExpressionType ~= 0 then
        data = checker.InstantiationExpressionType_new()
    elseif objectFlags & ObjectFlags.Anonymous ~= 0 then
        data = checker.ObjectType_new()
    else
        error("Unhandled case in newObjectType", 0)
    end
    local t = self:newType(TypeFlags.Object, objectFlags, data)
    t.symbol = symbol
    return t
end

function Checker:newAnonymousType(symbol, members, callSignatures, constructSignatures, indexInfos)
    local t = self:newObjectType(ObjectFlags.Anonymous, symbol)
    self:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
    return t
end

function Checker:tryCreateTypeReference(target, typeArguments)
    if core.Len(typeArguments) ~= 0 and target == self.emptyGenericType then
        return self.unknownType
    end
    return self:createTypeReference(target, typeArguments)
end

function Checker:createTypeReference(target, typeArguments)
    return self:createTypeReferenceEx(target, typeArguments, ObjectFlags.None)
end

function Checker:createTypeReferenceEx(target, typeArguments, objectFlags)
    local id = checker.getTypeListKey(typeArguments)
    local intf = target:AsInterfaceType()
    local existing = intf.instantiations[id]
    if existing ~= nil then
        return existing
    end
    local t = self:newObjectType(ObjectFlags.Reference | objectFlags | self:getPropagatingFlagsOfTypes(typeArguments, TypeFlags.None), target.symbol)
    local d = t:AsTypeReference()
    d.target = target
    d.resolvedTypeArguments = typeArguments
    intf.instantiations[id] = t
    return t
end

function Checker:createDeferredTypeReference(target, node, mapper, alias)
    if alias == nil then
        alias = self:getAliasForTypeNode(node)
        if alias ~= nil and mapper ~= nil then
            alias.typeArguments = self:instantiateTypes(alias.typeArguments, mapper)
        end
    end
    local t = self:newObjectType(ObjectFlags.Reference, target.symbol)
    t.alias = alias
    local d = t:AsTypeReference()
    d.target = target
    d.mapper = mapper
    d.node = node
    return t
end

function Checker:cloneTypeReference(source)
    local t = self:newObjectType(ObjectFlags.Reference, source.symbol)
    t.objectFlags = source.objectFlags & ~ObjectFlags.MembersResolved
    t:AsTypeReference().target = source:AsTypeReference().target
    t:AsTypeReference().resolvedTypeArguments = source:AsTypeReference().resolvedTypeArguments
    return t
end

function Checker:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
    t.objectFlags = t.objectFlags | ObjectFlags.MembersResolved
    local data = t:AsStructuredType()
    data.members = members
    data.properties = self:getNamedMembers(members, t.symbol)
    if core.Len(callSignatures) ~= 0 then
        if core.Len(constructSignatures) ~= 0 then
            data.signatures = core.Concatenate(callSignatures, constructSignatures)
        else
            data.signatures = slicesClone(callSignatures)
        end
        data.callSignatureCount = #callSignatures
    else
        if core.Len(constructSignatures) ~= 0 then
            data.signatures = slicesClone(constructSignatures)
        else
            data.signatures = nil
        end
        data.callSignatureCount = 0
    end
    data.indexInfos = slicesClone(indexInfos)
end

function Checker:newTypeParameter(symbol)
    local t = self:newType(TypeFlags.TypeParameter, ObjectFlags.None, checker.TypeParameter_new())
    t.symbol = symbol
    return t
end

-- This function is used to propagate certain flags when creating new object type references and union types.
-- It is only necessary to do so if a constituent type might be the undefined type, the null type, the type
-- of an object literal or a non-inferrable type. This is because there are operations in the type checker
-- that care about the presence of such types at arbitrary depth in a containing type.
function Checker:getPropagatingFlagsOfTypes(types, excludeKinds)
    local result = ObjectFlags.None
    for _, t in ipairs(types or {}) do
        if t.flags & excludeKinds == 0 then
            result = result | t.objectFlags
        end
    end
    return result & ObjectFlags.PropagatingFlags
end

function Checker:newUnionType(objectFlags, types)
    local data = checker.UnionType_new()
    data.types = types
    return self:newType(TypeFlags.Union, objectFlags, data)
end

function Checker:newIntersectionType(objectFlags, types)
    local data = checker.IntersectionType_new()
    data.types = types
    return self:newType(TypeFlags.Intersection, objectFlags, data)
end

function Checker:newIndexedAccessType(objectType, indexType, accessFlags)
    local data = checker.IndexedAccessType_new()
    data.objectType = objectType
    data.indexType = indexType
    data.accessFlags = accessFlags
    return self:newType(TypeFlags.IndexedAccess, ObjectFlags.None, data)
end

function Checker:newIndexType(target, indexFlags)
    local data = checker.IndexType_new()
    data.target = target
    data.indexFlags = indexFlags
    return self:newType(TypeFlags.Index, ObjectFlags.None, data)
end

function Checker:newTemplateLiteralType(texts, types)
    local data = checker.TemplateLiteralType_new()
    data.texts = texts
    data.types = types
    return self:newType(TypeFlags.TemplateLiteral, ObjectFlags.None, data)
end

function Checker:newStringMappingType(symbol, target)
    local data = checker.StringMappingType_new()
    data.target = target
    local t = self:newType(TypeFlags.StringMapping, ObjectFlags.None, data)
    t.symbol = symbol
    return t
end

function Checker:newConditionalType(root, mapper, combinedMapper)
    local data = checker.ConditionalType_new()
    data.root = root
    data.checkType = self:instantiateType(root.checkType, mapper)
    data.extendsType = self:instantiateType(root.extendsType, mapper)
    data.mapper = mapper
    data.combinedMapper = combinedMapper
    return self:newType(TypeFlags.Conditional, ObjectFlags.None, data)
end

function Checker:newSubstitutionType(baseType, constraint)
    local data = checker.SubstitutionType_new()
    data.baseType = baseType
    data.constraint = constraint
    return self:newType(TypeFlags.Substitution, ObjectFlags.None, data)
end

function Checker:newSignature(flags, declaration, typeParameters, thisParameter, parameters, resolvedReturnType, resolvedTypePredicate, minArgumentCount)
    self.signatureCount = self.signatureCount + 1
    local sig = self.signatureArena:New()
    sig.id = self.signatureCount
    sig.flags = flags
    sig.declaration = declaration
    sig.typeParameters = typeParameters
    sig.parameters = parameters
    sig.thisParameter = thisParameter
    sig.resolvedReturnType = resolvedReturnType
    sig.resolvedTypePredicate = resolvedTypePredicate
    sig.minArgumentCount = minArgumentCount
    sig.resolvedMinArgumentCount = -1
    return sig
end

function Checker:newIndexInfo(keyType, valueType, isReadonly, declaration, components)
    local info = self.indexInfoArena:New()
    info.keyType = keyType
    info.valueType = valueType
    info.isReadonly = isReadonly
    info.declaration = declaration
    info.components = components
    return info
end

function Checker:getRegularTypeOfLiteralType(t)
    if t.flags & TypeFlags.Freshable ~= 0 then
        return t:AsLiteralType().regularType
    end
    if t.flags & TypeFlags.Union ~= 0 then
        local u = t:AsUnionType()
        if u.regularType == nil then
            u.regularType = self:mapType(t, function(x) return self:getRegularTypeOfLiteralType(x) end)
        end
        return u.regularType
    end
    return t
end

function Checker:getFreshTypeOfLiteralType(t)
    if t.flags & TypeFlags.Freshable ~= 0 then
        local d = t:AsLiteralType()
        if d.freshType == nil then
            local f = self:newLiteralType(t.flags, d.value, t)
            f.symbol = t.symbol
            f:AsLiteralType().freshType = f
            d.freshType = f
        end
        return d.freshType
    end
    return t
end

function checker.isFreshLiteralType(t)
    return t.flags & TypeFlags.Freshable ~= 0 and t:AsLiteralType().freshType == t
end

function Checker:getStringLiteralType(value)
    local t = self.stringLiteralTypes[value]
    if t == nil then
        t = self:newLiteralType(TypeFlags.StringLiteral, value, nil)
        self.stringLiteralTypes[value] = t
    end
    return t
end

function Checker:getNumberLiteralType(value)
    -- NaN cannot be used as a Go map key because NaN != NaN in IEEE 754,
    -- so Go map lookups for NaN always miss. Cache NaN type separately.
    if jsnum.Number_IsNaN(value) then
        if self.nanType == nil then
            self.nanType = self:newLiteralType(TypeFlags.NumberLiteral, value, nil)
        end
        return self.nanType
    end
    local t = self.numberLiteralTypes[value]
    if t == nil then
        t = self:newLiteralType(TypeFlags.NumberLiteral, value, nil)
        self.numberLiteralTypes[value] = t
    end
    return t
end

function Checker:getBigIntLiteralType(value)
    local key = value:String()
    local t = self.bigintLiteralTypes[key]
    if t == nil then
        t = self:newLiteralType(TypeFlags.BigIntLiteral, value, nil)
        self.bigintLiteralTypes[key] = t
    end
    return t
end

-- text is a valid bigint string excluding a trailing `n`, but including a possible prefix `-`.
-- Use `isValidBigIntString(text, roundTripOnly)` before calling this function.
function Checker:parseBigIntLiteralType(text)
    return self:getBigIntLiteralType(jsnum.ParseValidBigInt(text))
end

function checker.getStringLiteralValue(t)
    return t:AsLiteralType().value
end

function checker.getNumberLiteralValue(t)
    return t:AsLiteralType().value
end

function checker.getBigIntLiteralValue(t)
    return t:AsLiteralType().value
end

function checker.getBooleanLiteralValue(t)
    return t:AsLiteralType().value
end

function Checker:getEnumLiteralType(value, enumSymbol, symbol)
    local flags
    local tv = type(value)
    if tv == "string" then
        flags = TypeFlags.EnumLiteral | TypeFlags.StringLiteral
    elseif tv == "number" then
        flags = TypeFlags.EnumLiteral | TypeFlags.NumberLiteral
        -- NaN cannot be used as a Go map key because NaN != NaN in IEEE 754,
        -- so Go map lookups for NaN always miss. Cache NaN enum types separately by enum symbol.
        if jsnum.Number_IsNaN(value) then
            local t = self.enumNaNLiteralTypes[enumSymbol]
            if t == nil then
                t = self:newLiteralType(flags, value, nil)
                t.symbol = symbol
                self.enumNaNLiteralTypes[enumSymbol] = t
            end
            return t
        end
    else
        error("Unhandled case in getEnumLiteralType", 0)
    end
    local key = checker.EnumLiteralKey(enumSymbol, value)
    local t = self.enumLiteralTypes[key]
    if t == nil then
        t = self:newLiteralType(flags, value, nil)
        t.symbol = symbol
        self.enumLiteralTypes[key] = t
    end
    return t
end

function checker.isLiteralType(t)
    if t.flags & TypeFlags.Boolean ~= 0 then
        return true
    end
    if t.flags & TypeFlags.Union ~= 0 then
        if t.flags & TypeFlags.EnumLiteral ~= 0 then
            return true
        end
        return core.Every(t:Types(), checker.isUnitType)
    end
    return checker.isUnitType(t)
end

function checker.isNeitherUnitTypeNorNever(t)
    return t.flags & (TypeFlags.Unit | TypeFlags.Never) == 0
end

function checker.isUnitType(t)
    return t.flags & TypeFlags.Unit ~= 0
end

function Checker:isUnitLikeType(t)
    -- Intersections that reduce to 'never' (e.g. 'T & null' where 'T extends {}') are not unit types.
    t = self:getBaseConstraintOrType(t)
    -- Scan intersections such that tagged literal types are considered unit types.
    if t.flags & TypeFlags.Intersection ~= 0 then
        return core.Some(t:AsIntersectionType().types, checker.isUnitType)
    end
    return checker.isUnitType(t)
end

function Checker:extractUnitType(t)
    if t.flags & TypeFlags.Intersection ~= 0 then
        local u = core.Find(t:AsIntersectionType().types, checker.isUnitType)
        if u ~= nil then
            return u
        end
    end
    return t
end

function Checker:getBaseTypeOfLiteralType(t)
    if t.flags & TypeFlags.EnumLike ~= 0 then
        return self:getBaseTypeOfEnumLikeType(t)
    elseif t.flags & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 then
        return self.stringType
    elseif t.flags & TypeFlags.NumberLiteral ~= 0 then
        return self.numberType
    elseif t.flags & TypeFlags.BigIntLiteral ~= 0 then
        return self.bigintType
    elseif t.flags & TypeFlags.BooleanLiteral ~= 0 then
        return self.booleanType
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:getBaseTypeOfLiteralTypeUnion(t)
    end
    return t
end

-- This like getBaseTypeOfLiteralType, but instead treats enum literals as strings/numbers instead
-- of returning their enum base type (which depends on the types of other literals in the enum).
function Checker:getBaseTypeOfLiteralTypeForComparison(t)
    if t.flags & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 then
        return self.stringType
    elseif t.flags & (TypeFlags.NumberLiteral | TypeFlags.Enum) ~= 0 then
        return self.numberType
    elseif t.flags & TypeFlags.BigIntLiteral ~= 0 then
        return self.bigintType
    elseif t.flags & TypeFlags.BooleanLiteral ~= 0 then
        return self.booleanType
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:mapType(t, function(x) return self:getBaseTypeOfLiteralTypeForComparison(x) end)
    end
    return t
end

function Checker:getBaseTypeOfEnumLikeType(t)
    if t.flags & TypeFlags.EnumLike ~= 0 and t.symbol.flags & SymbolFlags.EnumMember ~= 0 then
        return self:getDeclaredTypeOfSymbol(self:getParentOfSymbol(t.symbol))
    end
    return t
end

function Checker:getBaseTypeOfLiteralTypeUnion(t)
    local key = checker.CachedTypeKey(CachedTypeKind.LiteralUnionBaseType, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local result = self:mapType(t, function(x) return self:getBaseTypeOfLiteralType(x) end)
    self.cachedTypes[key] = result
    return result
end

function Checker:getWidenedLiteralType(t)
    if t.flags & TypeFlags.EnumLike ~= 0 and checker.isFreshLiteralType(t) then
        return self:getBaseTypeOfEnumLikeType(t)
    elseif t.flags & TypeFlags.StringLiteral ~= 0 and checker.isFreshLiteralType(t) then
        return self.stringType
    elseif t.flags & TypeFlags.NumberLiteral ~= 0 and checker.isFreshLiteralType(t) then
        return self.numberType
    elseif t.flags & TypeFlags.BigIntLiteral ~= 0 and checker.isFreshLiteralType(t) then
        return self.bigintType
    elseif t.flags & TypeFlags.BooleanLiteral ~= 0 and checker.isFreshLiteralType(t) then
        return self.booleanType
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:mapType(t, function(x) return self:getWidenedLiteralType(x) end)
    end
    return t
end

function Checker:getWidenedUniqueESSymbolType(t)
    if t.flags & TypeFlags.UniqueESSymbol ~= 0 then
        return self.esSymbolType
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:mapType(t, function(x) return self:getWidenedUniqueESSymbolType(x) end)
    end
    return t
end

function Checker:getWidenedLiteralLikeTypeForContextualType(t, contextualType)
    if not self:isLiteralOfContextualType(t, contextualType) then
        t = self:getWidenedUniqueESSymbolType(self:getWidenedLiteralType(t))
    end
    return self:getRegularTypeOfLiteralType(t)
end

function Checker:isLiteralOfContextualType(candidateType, contextualType)
    if contextualType ~= nil then
        if contextualType.flags & TypeFlags.UnionOrIntersection ~= 0 then
            return core.Some(contextualType:Types(), function(t)
                return self:isLiteralOfContextualType(candidateType, t)
            end)
        end
        if contextualType.flags & TypeFlags.InstantiableNonPrimitive ~= 0 then
            -- If the contextual type is a type variable constrained to a primitive type, consider
            -- this a literal context for literals of that primitive type. For example, given a
            -- type parameter 'T extends string', infer string literal types for T.
            local constraint = self:getBaseConstraintOfType(contextualType)
            if constraint == nil then
                constraint = self.unknownType
            end
            return self:maybeTypeOfKind(constraint, TypeFlags.String) and self:maybeTypeOfKind(candidateType, TypeFlags.StringLiteral) or
                self:maybeTypeOfKind(constraint, TypeFlags.Number) and self:maybeTypeOfKind(candidateType, TypeFlags.NumberLiteral) or
                self:maybeTypeOfKind(constraint, TypeFlags.BigInt) and self:maybeTypeOfKind(candidateType, TypeFlags.BigIntLiteral) or
                self:maybeTypeOfKind(constraint, TypeFlags.ESSymbol) and self:maybeTypeOfKind(candidateType, TypeFlags.UniqueESSymbol) or
                self:isLiteralOfContextualType(candidateType, constraint)
        end
        -- If the contextual type is a literal of a particular primitive type, we consider this a
        -- literal context for all literals of that primitive type.
        return contextualType.flags & (TypeFlags.StringLiteral | TypeFlags.Index | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 and self:maybeTypeOfKind(candidateType, TypeFlags.StringLiteral) or
            contextualType.flags & TypeFlags.NumberLiteral ~= 0 and self:maybeTypeOfKind(candidateType, TypeFlags.NumberLiteral) or
            contextualType.flags & TypeFlags.BigIntLiteral ~= 0 and self:maybeTypeOfKind(candidateType, TypeFlags.BigIntLiteral) or
            contextualType.flags & TypeFlags.BooleanLiteral ~= 0 and self:maybeTypeOfKind(candidateType, TypeFlags.BooleanLiteral) or
            contextualType.flags & TypeFlags.UniqueESSymbol ~= 0 and self:maybeTypeOfKind(candidateType, TypeFlags.UniqueESSymbol)
    end
    return false
end

function Checker:mapTypeWithAlias(t, f, alias)
    if t.flags & TypeFlags.Union ~= 0 and alias ~= nil then
        return self:getUnionTypeEx(core.Map(t:Types(), f), UnionReduction.Literal, alias, nil)
    end
    return self:mapType(t, f)
end

function Checker:mapType(t, f)
    return self:mapTypeEx(t, f, false --[[noReductions]])
end

function Checker:mapTypeEx(t, f, noReductions)
    if t.flags & TypeFlags.Never ~= 0 then
        return t
    end
    if t.flags & TypeFlags.Union == 0 then
        return f(t)
    end
    local u = t:AsUnionType()
    local types = u.types
    if u.origin ~= nil and u.origin.flags & TypeFlags.Union ~= 0 then
        types = u.origin:Types()
    end
    local mappedTypes = {}
    local changed = false
    for _, s in ipairs(types) do
        local mapped
        if s.flags & TypeFlags.Union ~= 0 then
            mapped = self:mapTypeEx(s, f, noReductions)
        else
            mapped = f(s)
        end
        if mapped ~= s then
            changed = true
        end
        if mapped ~= nil then
            mappedTypes[#mappedTypes + 1] = mapped
        end
    end
    if changed then
        if #mappedTypes == 0 then
            return nil
        end
        return self:getUnionTypeEx(mappedTypes, core.IfElse(noReductions, UnionReduction.None, UnionReduction.Literal), nil --[[alias]], nil --[[origin]])
    end
    return t
end

function Checker:getUnionOrIntersectionType(types, isUnion, unionReduction)
    if isUnion then
        return self:getUnionTypeEx(types, unionReduction, nil, nil)
    end
    return self:getIntersectionType(types)
end

function Checker:getUnionType(types)
    return self:getUnionTypeEx(types, UnionReduction.Literal, nil --[[alias]], nil --[[origin]])
end

-- We sort and deduplicate the constituent types based on object identity. If the subtypeReduction
-- flag is specified we also reduce the constituent type set to only include types that aren't subtypes
-- of other types. Subtype reduction is expensive for large union types and is possible only when union
-- types are known not to circularly reference themselves (as is the case with union types created by
-- expression constructs such as array literals and the || and ?: operators). Named types can
-- circularly reference themselves and therefore cannot be subtype reduced during their declaration.
-- For example, "type Item = string | (() => Item" is a named type that circularly references itself.
function Checker:getUnionTypeEx(types, unionReduction, alias, origin)
    local n = core.Len(types)
    if n == 0 then
        return self.neverType
    end
    if n == 1 then
        return types[1]
    end
    -- We optimize for the common case of unioning a union type with some other type (such as `undefined`).
    if n == 2 and origin == nil and (types[1].flags & TypeFlags.Union ~= 0 or types[2].flags & TypeFlags.Union ~= 0) then
        local id1 = types[1].id
        local id2 = types[2].id
        if id1 > id2 then
            id1, id2 = id2, id1
        end
        local key = checker.UnionOfUnionKey(id1, id2, unionReduction, checker.getAliasKey(alias))
        local t = self.unionOfUnionTypes[key]
        if t == nil then
            t = self:getUnionTypeWorker(types, unionReduction, alias, nil --[[origin]])
            self.unionOfUnionTypes[key] = t
        end
        return t
    end
    return self:getUnionTypeWorker(types, unionReduction, alias, origin)
end

function Checker:getUnionTypeWorker(types, unionReduction, alias, origin)
    local typeSet, includes = self:addTypesToUnion(types)
    if unionReduction ~= UnionReduction.None then
        if includes & TypeFlags.AnyOrUnknown ~= 0 then
            if includes & TypeFlags.Any ~= 0 then
                if includes & TypeFlags.IncludesWildcard ~= 0 then
                    return self.wildcardType
                elseif includes & TypeFlags.IncludesError ~= 0 then
                    return self.errorType
                end
                return self.anyType
            end
            return self.unknownType
        end
        if includes & TypeFlags.Undefined ~= 0 then
            -- If type set contains both undefinedType and missingType, remove missingType
            if #typeSet >= 2 and typeSet[1] == self.undefinedType and typeSet[2] == self.missingType then
                table.remove(typeSet, 2)
            end
        end
        if includes & (TypeFlags.Enum | TypeFlags.Literal | TypeFlags.UniqueESSymbol | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 or
            includes & TypeFlags.Void ~= 0 and includes & TypeFlags.Undefined ~= 0 then
            typeSet = self:removeRedundantLiteralTypes(typeSet, includes, unionReduction & UnionReduction.Subtype ~= 0)
        end
        if includes & TypeFlags.StringLiteral ~= 0 and includes & (TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 then
            typeSet = self:removeStringLiteralsMatchedByTemplateLiterals(typeSet)
        end
        if includes & TypeFlags.IncludesConstrainedTypeVariable ~= 0 then
            typeSet = self:removeConstrainedTypeVariables(typeSet)
        end
        if unionReduction == UnionReduction.Subtype then
            typeSet = self:removeSubtypes(typeSet, includes & TypeFlags.Object ~= 0)
            if typeSet == nil then
                return self.errorType
            end
        end
        if #typeSet == 0 then
            if includes & TypeFlags.Null ~= 0 then
                if includes & TypeFlags.IncludesNonWideningType ~= 0 then
                    return self.nullType
                end
                return self.nullWideningType
            elseif includes & TypeFlags.Undefined ~= 0 then
                if includes & TypeFlags.IncludesNonWideningType ~= 0 then
                    return self.undefinedType
                end
                return self.undefinedWideningType
            end
            return self.neverType
        end
    end
    if origin == nil and includes & TypeFlags.Union ~= 0 then
        local namedUnions = self:addNamedUnions(nil, types)
        local reducedTypes = nil
        for _, t in ipairs(typeSet) do
            if not core.Some(namedUnions, function(u) return checker.containsType(u:Types(), t) end) then
                reducedTypes = core.Append(reducedTypes, t)
            end
        end
        if alias == nil and core.Len(namedUnions) == 1 and core.Len(reducedTypes) == 0 then
            return namedUnions[1]
        end
        -- We create a denormalized origin type only when the union was created from one or more named unions
        -- (unions with alias symbols or origins) and when there is no overlap between those named unions.
        local namedTypesCount = 0
        for _, u in ipairs(namedUnions or {}) do
            namedTypesCount = namedTypesCount + #u:Types()
        end
        if namedTypesCount + core.Len(reducedTypes) == #typeSet then
            for _, t in ipairs(namedUnions or {}) do
                reducedTypes = checker.insertType(reducedTypes, t)
            end
            origin = self:newUnionType(ObjectFlags.None, reducedTypes)
        end
    end
    local objectFlags = core.IfElse(includes & TypeFlags.NotPrimitiveUnion ~= 0, ObjectFlags.None, ObjectFlags.PrimitiveUnion) |
        core.IfElse(includes & TypeFlags.Intersection ~= 0, checker.ObjectFlagsContainsIntersections, ObjectFlags.None)
    return self:getUnionTypeFromSortedList(typeSet, objectFlags, alias, origin)
end

-- This function assumes the constituent type list is sorted and deduplicated.
function Checker:getUnionTypeFromSortedList(types, precomputedObjectFlags, alias, origin)
    local n = core.Len(types)
    if n == 0 then
        return self.neverType
    end
    if n == 1 then
        return types[1]
    end
    local key = checker.getUnionKey(types, origin, alias)
    local t = self.unionTypes[key]
    if t == nil then
        t = self:newUnionType(precomputedObjectFlags | self:getPropagatingFlagsOfTypes(types, TypeFlags.Nullable), types)
        t:AsUnionType().origin = origin
        t.alias = alias
        if n == 2 and types[1].flags & TypeFlags.BooleanLiteral ~= 0 and types[2].flags & TypeFlags.BooleanLiteral ~= 0 then
            t.flags = t.flags | TypeFlags.Boolean
        end
        self.unionTypes[key] = t
    end
    return t
end

-- Returns a Lua iterator over the union types (Go iter.Seq; Go map order is random).
function Checker:UnionTypes()
    local key = nil
    return function()
        local v
        key, v = next(self.unionTypes, key)
        return v
    end
end

function Checker:addTypesToUnion(sourceTypes)
    local types = {}
    local includes = 0
    local function addType(t)
        local flags = t.flags
        -- We ignore 'never' types in unions
        if flags & TypeFlags.Never ~= 0 then
            return
        end
        includes = includes | (flags & TypeFlags.IncludesMask)
        if flags & TypeFlags.Instantiable ~= 0 then
            includes = includes | TypeFlags.IncludesInstantiable
        end
        if flags & TypeFlags.Intersection ~= 0 and t.objectFlags & checker.ObjectFlagsIsConstrainedTypeVariable ~= 0 then
            includes = includes | TypeFlags.IncludesConstrainedTypeVariable
        end
        if t == self.wildcardType then
            includes = includes | TypeFlags.IncludesWildcard
        end
        if self:isErrorType(t) then
            includes = includes | TypeFlags.IncludesError
        end
        if not self.strictNullChecks and flags & TypeFlags.Nullable ~= 0 then
            if t.objectFlags & ObjectFlags.ContainsWideningType == 0 then
                includes = includes | TypeFlags.IncludesNonWideningType
            end
            return
        end
        types[#types + 1] = t
    end
    local lastType = nil
    for _, t in ipairs(sourceTypes or {}) do
        if t ~= lastType then
            if t.flags & TypeFlags.Union ~= 0 then
                local u = t:AsUnionType()
                if t.alias ~= nil or u.origin ~= nil then
                    includes = includes | TypeFlags.Union
                end
                for _, s in ipairs(u.types) do
                    addType(s)
                end
            else
                addType(t)
            end
            lastType = t
        end
    end
    if #types >= 2 then
        -- Sort and deduplicate types
        core.SortStableFunc(types, checker.CompareTypes)
        local unique = 1
        for i = 2, #types do
            local t = types[i]
            if t ~= types[unique] then
                unique = unique + 1
                types[unique] = t
            end
        end
        for i = #types, unique + 1, -1 do
            types[i] = nil
        end
    end
    return types, includes
end

function Checker:addNamedUnions(namedUnions, types)
    for _, t in ipairs(types or {}) do
        if t.flags & TypeFlags.Union ~= 0 then
            local u = t:AsUnionType()
            if t.alias ~= nil or u.origin ~= nil and u.origin.flags & TypeFlags.Union == 0 then
                namedUnions = core.AppendIfUnique(namedUnions, t)
            elseif u.origin ~= nil and u.origin.flags & TypeFlags.Union ~= 0 then
                namedUnions = self:addNamedUnions(namedUnions, u.origin:Types())
            end
        end
    end
    return namedUnions
end

function Checker:removeRedundantLiteralTypes(types, includes, reduceVoidUndefined)
    local i = #types
    while i > 0 do
        i = i - 1
        local t = types[i + 1]
        local flags = t.flags
        local remove = flags & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 and includes & TypeFlags.String ~= 0 or
            flags & TypeFlags.NumberLiteral ~= 0 and includes & TypeFlags.Number ~= 0 or
            flags & TypeFlags.BigIntLiteral ~= 0 and includes & TypeFlags.BigInt ~= 0 or
            flags & TypeFlags.UniqueESSymbol ~= 0 and includes & TypeFlags.ESSymbol ~= 0 or
            reduceVoidUndefined and flags & TypeFlags.Undefined ~= 0 and includes & TypeFlags.Void ~= 0 or
            checker.isFreshLiteralType(t) and checker.containsType(types, t:AsLiteralType().regularType)
        if remove then
            table.remove(types, i + 1)
        end
    end
    return types
end

function Checker:removeStringLiteralsMatchedByTemplateLiterals(types)
    local templates = core.Filter(types, function(t) return self:isPatternLiteralType(t) end)
    if core.Len(templates) ~= 0 then
        local i = #types
        while i > 0 do
            i = i - 1
            local t = types[i + 1]
            if t.flags & TypeFlags.StringLiteral ~= 0 and core.Some(templates, function(template)
                    return self:isTypeMatchedByTemplateLiteralOrStringMapping(t, template)
                end) then
                table.remove(types, i + 1)
            end
        end
    end
    return types
end

function Checker:isTypeMatchedByTemplateLiteralOrStringMapping(t, template)
    if template.flags & TypeFlags.TemplateLiteral ~= 0 then
        return self:isTypeMatchedByTemplateLiteralType(t, template:AsTemplateLiteralType(), self.compareTypesAssignable)
    end
    return self:isMemberOfStringMapping(t, template)
end

function Checker:removeConstrainedTypeVariables(types)
    local typeVariables = nil
    -- First collect a list of the type variables occurring in constraining intersections.
    for _, t in ipairs(types) do
        if t.flags & TypeFlags.Intersection ~= 0 and t.objectFlags & checker.ObjectFlagsIsConstrainedTypeVariable ~= 0 then
            local index = 0
            if t:AsIntersectionType().types[1].flags & TypeFlags.TypeVariable == 0 then
                index = 1
            end
            typeVariables = core.AppendIfUnique(typeVariables, t:AsIntersectionType().types[index + 1])
        end
    end
    -- For each type variable, check if the constraining intersections for that type variable fully
    -- cover the constraint of the type variable; if so, remove the constraining intersections and
    -- substitute the type variable.
    for _, typeVariable in ipairs(typeVariables or {}) do
        local primitives = nil
        -- First collect the primitive types from the constraining intersections.
        for _, t in ipairs(types) do
            if t.flags & TypeFlags.Intersection ~= 0 and t.objectFlags & checker.ObjectFlagsIsConstrainedTypeVariable ~= 0 then
                local index = 0
                if t:AsIntersectionType().types[1].flags & TypeFlags.TypeVariable == 0 then
                    index = 1
                end
                if t:AsIntersectionType().types[index + 1] == typeVariable then
                    primitives = checker.insertType(primitives, t:AsIntersectionType().types[1 - index + 1])
                end
            end
        end
        -- If every constituent in the type variable's constraint is covered by an intersection of the type
        -- variable and that constituent, remove those intersections and substitute the type variable.
        local constraint = self:getBaseConstraintOfType(typeVariable)
        if checker.everyType(constraint, function(t) return checker.containsType(primitives, t) end) then
            local i = #types
            while i > 0 do
                i = i - 1
                local t = types[i + 1]
                if t.flags & TypeFlags.Intersection ~= 0 and t.objectFlags & checker.ObjectFlagsIsConstrainedTypeVariable ~= 0 then
                    local index = 0
                    if t:AsIntersectionType().types[1].flags & TypeFlags.TypeVariable == 0 then
                        index = 1
                    end
                    if t:AsIntersectionType().types[index + 1] == typeVariable and checker.containsType(primitives, t:AsIntersectionType().types[1 - index + 1]) then
                        table.remove(types, i + 1)
                    end
                end
            end
            types = checker.insertType(types, typeVariable)
        end
    end
    return types
end

function Checker:removeSubtypes(types, hasObjectTypes)
    -- [] and [T] immediately reduce to [] and [T] respectively
    if #types < 2 then
        return types
    end
    local key = checker.getTypeListKey(types)
    local cached = self.subtypeReductionCache[key]
    if cached ~= nil then
        return cached
    end
    -- We assume that redundant primitive types have already been removed from the types array and that there
    -- are no any and unknown types in the array. Thus, the only possible supertypes for primitive types are empty
    -- object types, and if none of those are present we can exclude primitive types from the subtype check.
    local hasEmptyObject = hasObjectTypes and core.Some(types, function(t)
        return t.flags & TypeFlags.Object ~= 0 and not self:isGenericMappedType(t) and self:isEmptyResolvedType(self:resolveStructuredTypeMembers(t))
    end)
    local length = #types
    local i = length
    local count = 0
    while i > 0 do
        i = i - 1
        local source = types[i + 1]
        if hasEmptyObject or source.flags & TypeFlags.StructuredOrInstantiable ~= 0 then
            -- A type parameter with a union constraint may be a subtype of some union, but not a subtype of the
            -- individual constituents of that union. For example, `T extends A | B` is a subtype of `A | B`, but not
            -- a subtype of just `A` or just `B`. When we encounter such a type parameter, we therefore check if the
            -- type parameter is a subtype of a union of all the other types.
            if source.flags & TypeFlags.TypeParameter ~= 0 and self:getBaseConstraintOrType(source).flags & TypeFlags.Union ~= 0 then
                if self:isTypeRelatedTo(source, self:getUnionType(core.Map(types, function(t)
                        if t == source then
                            return self.neverType
                        end
                        return t
                    end)), self.strictSubtypeRelation) then
                    table.remove(types, i + 1)
                end
                goto continue
            end
            -- Find the first property with a unit type, if any. When constituents have a property by the same name
            -- but of a different unit type, we can quickly disqualify them from subtype checks. This helps subtype
            -- reduction of large discriminated union types.
            local keyProperty = nil
            local keyPropertyType = nil
            if source.flags & (TypeFlags.Object | TypeFlags.Intersection | TypeFlags.InstantiableNonPrimitive) ~= 0 then
                keyProperty = core.Find(self:getPropertiesOfType(source), function(p)
                    return checker.isUnitType(self:getTypeOfSymbol(p))
                end)
            end
            if keyProperty ~= nil then
                keyPropertyType = self:getRegularTypeOfLiteralType(self:getTypeOfSymbol(keyProperty))
            end
            for _, target in ipairs(types) do
                if source ~= target then
                    if count == 100000 then
                        -- After 100000 subtype checks we estimate the remaining amount of work by assuming the
                        -- same ratio of checks per element. If the estimated number of remaining type checks is
                        -- greater than 1M we deem the union type too complex to represent. This for example
                        -- caps union types at 1000 unique object types.
                        local estimatedCount = (count // (length - i)) * length
                        if estimatedCount > 1000000 then
                            local tr = self.tracer
                            if tr ~= nil then
                                tr:Instant(tracing.PhaseCheckTypes, "removeSubtypes_DepthLimit", { estimatedCount = estimatedCount })
                            end
                            self:error(self.currentNode, diagnostics.Expression_produces_a_union_type_that_is_too_complex_to_represent)
                            return nil
                        end
                    end
                    count = count + 1
                    if keyProperty ~= nil and target.flags & (TypeFlags.Object | TypeFlags.Intersection | TypeFlags.InstantiableNonPrimitive) ~= 0 then
                        local t = self:getTypeOfPropertyOfType(target, keyProperty.name)
                        if t ~= nil and checker.isUnitType(t) and self:getRegularTypeOfLiteralType(t) ~= keyPropertyType then
                            goto continueTarget
                        end
                    end
                    if (source == self.emptyObjectType or source == self.unknownEmptyObjectType) and target.symbol ~= nil and self:IsEmptyAnonymousObjectType(target) then
                        goto continueTarget
                    end
                    if self:isTypeRelatedTo(source, target, self.strictSubtypeRelation) and (self:getTargetType(source).objectFlags & ObjectFlags.Class == 0 or
                            self:getTargetType(target).objectFlags & ObjectFlags.Class == 0 or
                            self:isTypeDerivedFrom(source, target)) then
                        table.remove(types, i + 1)
                        break
                    end
                end
                ::continueTarget::
            end
        end
        ::continue::
    end
    self.subtypeReductionCache[key] = types
    return types
end

function Checker:intersectTypes(type1, type2)
    if type1 == nil then
        return type2
    elseif type2 == nil then
        return type1
    end
    return self:getIntersectionType({ type1, type2 })
end

-- We normalize combinations of intersection and union types based on the distributive property of the '&'
-- operator. Specifically, because X & (A | B) is equivalent to X & A | X & B, we can transform intersection
-- types with union type constituents into equivalent union types with intersection type constituents and
-- effectively ensure that union types are always at the top level in type representations.
--
-- We do not perform structural deduplication on intersection types. Intersection types are created only by the &
-- type operator and we can't reduce those because we want to support recursive intersection types. For example,
-- a type alias of the form "type List<T> = T & { next: List<T> }" cannot be reduced during its declaration.
-- Also, unlike union types, the order of the constituent types is preserved in order that overload resolution
-- for intersections of types with signatures can be deterministic.
function Checker:getIntersectionType(types)
    return self:getIntersectionTypeEx(types, IntersectionFlags.None, nil --[[alias]])
end

function Checker:getIntersectionTypeEx(types, flags, alias)
    local orderedTypes = checker.orderedSet_new()
    orderedTypes.values = {}
    local includes = self:addTypesToIntersection(orderedTypes, 0, types)
    local typeSet = orderedTypes.values
    local objectFlags = ObjectFlags.None
    -- An intersection type is considered empty if it contains
    -- the type never, or
    -- more than one unit type or,
    -- an object type and a nullable type (null or undefined), or
    -- a string-like type and a type known to be non-string-like, or
    -- a number-like type and a type known to be non-number-like, or
    -- a symbol-like type and a type known to be non-symbol-like, or
    -- a void-like type and a type known to be non-void-like, or
    -- a non-primitive type and a type known to be primitive.
    if includes & TypeFlags.Never ~= 0 then
        if slicesContains(typeSet, self.silentNeverType) then
            return self.silentNeverType
        end
        return self.neverType
    end
    if self.strictNullChecks and includes & TypeFlags.Nullable ~= 0 and includes & (TypeFlags.Object | TypeFlags.NonPrimitive | TypeFlags.IncludesEmptyObject) ~= 0 or
        includes & TypeFlags.NonPrimitive ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.NonPrimitive) ~= 0 or
        includes & TypeFlags.StringLike ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.StringLike) ~= 0 or
        includes & TypeFlags.NumberLike ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.NumberLike) ~= 0 or
        includes & TypeFlags.BigIntLike ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.BigIntLike) ~= 0 or
        includes & TypeFlags.ESSymbolLike ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.ESSymbolLike) ~= 0 or
        includes & TypeFlags.VoidLike ~= 0 and includes & (TypeFlags.DisjointDomains & ~TypeFlags.VoidLike) ~= 0 then
        return self.neverType
    end
    if includes & (TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 and includes & TypeFlags.StringLiteral ~= 0 then
        local isEmptySet
        typeSet, isEmptySet = self:extractRedundantTemplateLiterals(typeSet)
        if isEmptySet then
            return self.neverType
        end
    end
    if includes & TypeFlags.Any ~= 0 then
        if includes & TypeFlags.IncludesWildcard ~= 0 then
            return self.wildcardType
        elseif includes & TypeFlags.IncludesError ~= 0 then
            return self.errorType
        end
        return self.anyType
    end
    if not self.strictNullChecks and includes & TypeFlags.Nullable ~= 0 then
        if includes & TypeFlags.IncludesEmptyObject ~= 0 then
            return self.neverType
        elseif includes & TypeFlags.Undefined ~= 0 then
            return self.undefinedType
        end
        return self.nullType
    end
    if includes & TypeFlags.String ~= 0 and includes & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 or
        includes & TypeFlags.Number ~= 0 and includes & TypeFlags.NumberLiteral ~= 0 or
        includes & TypeFlags.BigInt ~= 0 and includes & TypeFlags.BigIntLiteral ~= 0 or
        includes & TypeFlags.ESSymbol ~= 0 and includes & TypeFlags.UniqueESSymbol ~= 0 or
        includes & TypeFlags.Void ~= 0 and includes & TypeFlags.Undefined ~= 0 or
        includes & TypeFlags.IncludesEmptyObject ~= 0 and includes & TypeFlags.DefinitelyNonNullable ~= 0 then
        if flags & IntersectionFlags.NoSupertypeReduction == 0 then
            typeSet = self:removeRedundantSupertypes(typeSet, includes)
        end
    end
    if includes & TypeFlags.IncludesMissingType ~= 0 then
        typeSet[slicesIndex(typeSet, self.undefinedType) + 1] = self.missingType
    end
    if #typeSet == 0 then
        return self.unknownType
    end
    if #typeSet == 1 then
        return typeSet[1]
    end
    if #typeSet == 2 and flags & IntersectionFlags.NoConstraintReduction == 0 then
        local typeVarIndex = 0
        if typeSet[1].flags & TypeFlags.TypeVariable == 0 then
            typeVarIndex = 1
        end
        local typeVariable = typeSet[typeVarIndex + 1]
        local primitiveType = typeSet[1 - typeVarIndex + 1]
        if typeVariable.flags & TypeFlags.TypeVariable ~= 0 and (primitiveType.flags & (TypeFlags.Primitive | TypeFlags.NonPrimitive) ~= 0 and not self:isGenericStringLikeType(primitiveType) or
                includes & TypeFlags.IncludesEmptyObject ~= 0) then
            -- We have an intersection T & P or P & T, where T is a type variable and P is a primitive type, the object type, or {}.
            local constraint = self:getBaseConstraintOfType(typeVariable)
            -- Check that T's constraint is similarly composed of primitive types, the object type, or {}.
            if constraint ~= nil and checker.everyType(constraint, self.isPrimitiveOrObjectOrEmptyType) then
                -- If T's constraint is a subtype of P, simply return T. For example, given `T extends "a" | "b"`,
                -- the intersection `T & string` reduces to just T.
                if self:isTypeStrictSubtypeOf(constraint, primitiveType) then
                    return typeVariable
                end
                if not (constraint.flags & TypeFlags.Union ~= 0 and checker.someType(constraint, function(n)
                        return self:isTypeStrictSubtypeOf(n, primitiveType)
                    end)) then
                    -- No constituent of T's constraint is a subtype of P. If P is also not a subtype of T's constraint,
                    -- then the constraint and P are unrelated, and the intersection reduces to never. For example, given
                    -- `T extends "a" | "b"`, the intersection `T & number` reduces to never.
                    if not self:isTypeStrictSubtypeOf(primitiveType, constraint) then
                        return self.neverType
                    end
                end
                -- Some constituent of T's constraint is a subtype of P, or P is a subtype of T's constraint. Thus,
                -- the intersection further constrains the type variable. For example, given `T extends string | number`,
                -- the intersection `T & "a"` is marked as a constrained type variable. Likewise, given `T extends "a" | 1`,
                -- the intersection `T & number` is marked as a constrained type variable.
                objectFlags = checker.ObjectFlagsIsConstrainedTypeVariable
            end
        end
    end
    local key = checker.getIntersectionKey(typeSet, flags, alias)
    local result = self.intersectionTypes[key]
    if result == nil then
        if includes & TypeFlags.Union ~= 0 then
            local reduced
            typeSet, reduced = self:intersectUnionsOfPrimitiveTypes(typeSet)
            if reduced then
                -- When the intersection creates a reduced set (which might mean that *all* union types have
                -- disappeared), we restart the operation to get a new set of combined flags. Once we have
                -- reduced we'll never reduce again, so this occurs at most once.
                result = self:getIntersectionTypeEx(typeSet, flags, alias)
            elseif core.Every(typeSet, checker.isUnionWithUndefined) then
                local containedUndefinedType = self.undefinedType
                if core.Some(typeSet, self.containsMissingType) then
                    containedUndefinedType = self.missingType
                end
                self:filterTypes(typeSet, checker.isNotUndefinedType)
                result = self:getUnionTypeEx({ self:getIntersectionTypeEx(typeSet, flags, nil --[[alias]]), containedUndefinedType }, UnionReduction.Literal, alias, nil --[[origin]])
            elseif core.Every(typeSet, checker.isUnionWithNull) then
                self:filterTypes(typeSet, checker.isNotNullType)
                result = self:getUnionTypeEx({ self:getIntersectionTypeEx(typeSet, flags, nil --[[alias]]), self.nullType }, UnionReduction.Literal, alias, nil --[[origin]])
            elseif #typeSet >= 3 and core.Len(types) > 2 then
                -- When we have three or more constituents, more than two inputs (to head off infinite reexpansion), some of which are unions, we employ a "divide and conquer" strategy
                -- where A & B & C & D is processed as (A & B) & (C & D). Since intersections of unions often produce far smaller
                -- unions of intersections than the full cartesian product (due to some intersections becoming `never`), this can
                -- dramatically reduce the overall work.
                local middle = #typeSet // 2
                result = self:getIntersectionTypeEx({
                    self:getIntersectionTypeEx(core.Slice(typeSet, 0, middle), flags, nil --[[alias]]),
                    self:getIntersectionTypeEx(core.Slice(typeSet, middle, #typeSet), flags, nil --[[alias]]),
                }, flags, alias)
            else
                -- We are attempting to construct a type of the form X & (A | B) & (C | D). Transform this into a type of
                -- the form X & A & C | X & A & D | X & B & C | X & B & D. If the estimated size of the resulting union type
                -- exceeds 100000 constituents, report an error.
                if not self:checkCrossProductUnion(typeSet) then
                    return self.errorType
                end
                local constituents = self:getCrossProductIntersections(typeSet, flags)
                -- We attach a denormalized origin type when at least one constituent of the cross-product union is an
                -- intersection (i.e. when the intersection didn't just reduce one or more unions to smaller unions) and
                -- the denormalized origin has fewer constituents than the union itself.
                local origin = nil
                if core.Some(constituents, checker.isIntersectionType) and checker.getConstituentCountOfTypes(constituents) > checker.getConstituentCountOfTypes(typeSet) then
                    origin = self:newIntersectionType(ObjectFlags.None, typeSet)
                end
                result = self:getUnionTypeEx(constituents, UnionReduction.Literal, alias, origin)
            end
        else
            result = self:newIntersectionType(objectFlags | self:getPropagatingFlagsOfTypes(types --[[excludeKinds]], TypeFlags.Nullable), typeSet)
            result.alias = alias
        end
        self.intersectionTypes[key] = result
    end
    return result
end

function checker.isUnionWithUndefined(t)
    return t.flags & TypeFlags.Union ~= 0 and t:Types()[1].flags & TypeFlags.Undefined ~= 0
end

function checker.isUnionWithNull(t)
    return t.flags & TypeFlags.Union ~= 0 and (t:Types()[1].flags & TypeFlags.Null ~= 0 or t:Types()[2].flags & TypeFlags.Null ~= 0)
end

function checker.isIntersectionType(t)
    return t.flags & TypeFlags.Intersection ~= 0
end

function checker.isPrimitiveUnion(t)
    return t.objectFlags & ObjectFlags.PrimitiveUnion ~= 0
end

function checker.isNotUndefinedType(t)
    return t.flags & TypeFlags.Undefined == 0
end

function checker.isNotNullType(t)
    return t.flags & TypeFlags.Null == 0
end

-- Add the given types to the given type set. Order is preserved, freshness is removed from literal
-- types, duplicates are removed, and nested types of the given kind are flattened into the set.
function Checker:addTypesToIntersection(typeSet, includes, types)
    for _, t in ipairs(types or {}) do
        includes = self:addTypeToIntersection(typeSet, includes, self:getRegularTypeOfLiteralType(t))
    end
    return includes
end

function Checker:addTypeToIntersection(typeSet, includes, t)
    local flags = t.flags
    if flags & TypeFlags.Intersection ~= 0 then
        return self:addTypesToIntersection(typeSet, includes, t:Types())
    end
    if self:IsEmptyAnonymousObjectType(t) then
        if includes & TypeFlags.IncludesEmptyObject == 0 then
            includes = includes | TypeFlags.IncludesEmptyObject
            typeSet:add(t)
        end
    else
        if flags & TypeFlags.AnyOrUnknown ~= 0 then
            if t == self.wildcardType then
                includes = includes | TypeFlags.IncludesWildcard
            end
            if self:isErrorType(t) then
                includes = includes | TypeFlags.IncludesError
            end
        elseif self.strictNullChecks or flags & TypeFlags.Nullable == 0 then
            if t == self.missingType then
                includes = includes | TypeFlags.IncludesMissingType
                t = self.undefinedType
            end
            if not typeSet:contains(t) then
                if t.flags & TypeFlags.Unit ~= 0 and includes & TypeFlags.Unit ~= 0 then
                    -- We have seen two distinct unit types which means we should reduce to an
                    -- empty intersection. Adding TypeFlags.NonPrimitive causes that to happen.
                    includes = includes | TypeFlags.NonPrimitive
                end
                typeSet:add(t)
            end
        end
        includes = includes | (flags & TypeFlags.IncludesMask)
    end
    return includes
end

function Checker:removeRedundantSupertypes(types, includes)
    local i = #types
    while i > 0 do
        i = i - 1
        local t = types[i + 1]
        local remove = t.flags & TypeFlags.String ~= 0 and includes & (TypeFlags.StringLiteral | TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 or
            t.flags & TypeFlags.Number ~= 0 and includes & TypeFlags.NumberLiteral ~= 0 or
            t.flags & TypeFlags.BigInt ~= 0 and includes & TypeFlags.BigIntLiteral ~= 0 or
            t.flags & TypeFlags.ESSymbol ~= 0 and includes & TypeFlags.UniqueESSymbol ~= 0 or
            t.flags & TypeFlags.Void ~= 0 and includes & TypeFlags.Undefined ~= 0 or
            self:IsEmptyAnonymousObjectType(t) and includes & TypeFlags.DefinitelyNonNullable ~= 0
        if remove then
            table.remove(types, i + 1)
        end
    end
    return types
end

-- Returns true if the intersection of the template literals and string literals is the empty set,
-- for example `get${string}` & "setX", and should reduce to never.
function Checker:extractRedundantTemplateLiterals(types)
    local literals = core.Filter(types, function(t) return t.flags & TypeFlags.StringLiteral ~= 0 end)
    local i = #types
    while i > 0 do
        i = i - 1
        local t = types[i + 1]
        if t.flags & (TypeFlags.TemplateLiteral | TypeFlags.StringMapping) == 0 then
            goto continue
        end
        for _, t2 in ipairs(literals) do
            if self:isTypeSubtypeOf(t2, t) then
                -- For example, `get${T}` & "getX" is just "getX", and Lowercase<string> & "foo" is just "foo"
                table.remove(types, i + 1)
                break
            end
            if self:isPatternLiteralType(t) then
                return types, true
            end
        end
        ::continue::
    end
    return types, false
end

-- If the given list of types contains more than one union of primitive types, replace the
-- first with a union containing an intersection of those primitive types, then remove the
-- other unions and return true. Otherwise, do nothing and return false.
function Checker:intersectUnionsOfPrimitiveTypes(types)
    local index = core.FindIndex(types, checker.isPrimitiveUnion)
    if index < 0 then
        return types, false
    end
    -- Remove all but the first union of primitive types and collect them in
    -- the unionTypes array.
    local i = index + 1
    local unionTypes = { types[index + 1] }
    while i < #types do
        local t = types[i + 1]
        if t.objectFlags & ObjectFlags.PrimitiveUnion ~= 0 then
            unionTypes[#unionTypes + 1] = t
            table.remove(types, i + 1)
        else
            i = i + 1
        end
    end
    -- Return false if there was only one union of primitive types
    if #unionTypes == 1 then
        return types, false
    end
    -- We have more than one union of primitive types, now intersect them. For each
    -- type in each union we check if the type is matched in every union and if so
    -- we include it in the result.
    local checked = nil
    local result = nil
    for _, u in ipairs(unionTypes) do
        for _, t in ipairs(u:Types()) do
            local inserted
            checked, inserted = checker.insertType(checked, t)
            if inserted then
                if self:eachUnionContains(unionTypes, t) then
                    -- undefinedType/missingType are always sorted first so we leverage that here
                    if t == self.undefinedType and core.Len(result) ~= 0 and result[1] == self.missingType then
                        goto continue
                    end
                    if t == self.missingType and core.Len(result) ~= 0 and result[1] == self.undefinedType then
                        result[1] = self.missingType
                        goto continue
                    end
                    result = checker.insertType(result, t)
                end
            end
            ::continue::
        end
    end
    -- Finally replace the first union with the result
    types[index + 1] = self:getUnionTypeFromSortedList(result, ObjectFlags.PrimitiveUnion, nil --[[alias]], nil --[[origin]])
    return types, true
end

-- Check that the given type has a match in every union. A given type is matched by
-- an identical type, and a literal type is additionally matched by its corresponding
-- primitive type, and missingType is matched by undefinedType (and vice versa).
function Checker:eachUnionContains(unionTypes, t)
    for _, u in ipairs(unionTypes) do
        if not self:unionContainsType(u, t, true --[[matchSymbol]]) then
            return false
        end
    end
    return true
end

function Checker:unionContainsType(union, t, matchSymbol)
    local types = union:Types()
    if checker.containsType(types, t) then
        return true
    end
    if t == self.missingType then
        return checker.containsType(types, self.undefinedType)
    end
    if t == self.undefinedType then
        return checker.containsType(types, self.missingType)
    end
    local primitive = nil
    if t.flags & TypeFlags.StringLiteral ~= 0 then
        primitive = self.stringType
    elseif t.flags & (TypeFlags.Enum | TypeFlags.NumberLiteral) ~= 0 then
        primitive = self.numberType
    elseif t.flags & TypeFlags.BigIntLiteral ~= 0 then
        primitive = self.bigintType
    elseif t.flags & TypeFlags.UniqueESSymbol ~= 0 and matchSymbol then
        primitive = self.esSymbolType
    end
    return primitive ~= nil and checker.containsType(types, primitive)
end

function Checker:getCrossProductIntersections(types, flags)
    local count = self:getCrossProductUnionSize(types)
    local intersections = nil
    for i = 0, count - 1 do
        local constituents = slicesClone(types)
        local n = i
        for j = #types - 1, 0, -1 do
            if types[j + 1].flags & TypeFlags.Union ~= 0 then
                local sourceTypes = types[j + 1]:Types()
                local length = #sourceTypes
                constituents[j + 1] = sourceTypes[n % length + 1]
                n = n // length
            end
        end
        local t = self:getIntersectionTypeEx(constituents, flags, nil --[[alias]])
        if t.flags & TypeFlags.Never == 0 then
            intersections = core.Append(intersections, t)
        end
    end
    return intersections
end

function checker.getConstituentCount(t)
    if t.flags & TypeFlags.UnionOrIntersection == 0 or t.alias ~= nil then
        return 1
    elseif t.flags & TypeFlags.Union ~= 0 and t:AsUnionType().origin ~= nil then
        return checker.getConstituentCount(t:AsUnionType().origin)
    end
    return checker.getConstituentCountOfTypes(t:Types())
end

function checker.getConstituentCountOfTypes(types)
    local n = 0
    for _, t in ipairs(types or {}) do
        n = n + checker.getConstituentCount(t)
    end
    return n
end

function Checker:filterTypes(types, predicate)
    for i, t in ipairs(types) do
        types[i] = self:filterType(t, predicate)
    end
end

function Checker:IsEmptyAnonymousObjectType(t)
    return t.objectFlags & ObjectFlags.Anonymous ~= 0 and (t.objectFlags & ObjectFlags.MembersResolved ~= 0 and self:isEmptyResolvedType(t:AsStructuredType()) or
        t.symbol ~= nil and t.symbol.flags & SymbolFlags.TypeLiteral ~= 0 and next(self:getMembersOfSymbol(t.symbol) or {}) == nil)
end

function Checker:isEmptyResolvedType(t)
    return t:AsType() ~= self.anyFunctionType and core.Len(t.properties) == 0 and core.Len(t.signatures) == 0 and core.Len(t.indexInfos) == 0
end

function Checker:isEmptyObjectType(t)
    if t.flags & TypeFlags.Object ~= 0 then
        return not self:isGenericMappedType(t) and self:isEmptyResolvedType(self:resolveStructuredTypeMembers(t))
    elseif t.flags & TypeFlags.NonPrimitive ~= 0 then
        return true
    elseif t.flags & TypeFlags.Union ~= 0 then
        return core.Some(t:Types(), function(x) return self:isEmptyObjectType(x) end)
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        return core.Every(t:Types(), function(x) return self:isEmptyObjectType(x) end)
    end
    return false
end

function Checker:isPatternLiteralPlaceholderType(t)
    if t.flags & TypeFlags.Intersection ~= 0 then
        -- Return true if the intersection consists of one or more placeholders and zero or
        -- more object type tags.
        local seenPlaceholder = false
        for _, s in ipairs(t:Types()) do
            if s.flags & (TypeFlags.Literal | TypeFlags.Nullable) ~= 0 or self:isPatternLiteralPlaceholderType(s) then
                seenPlaceholder = true
            elseif s.flags & TypeFlags.Object == 0 then
                return false
            end
        end
        return seenPlaceholder
    end
    return t.flags & (TypeFlags.Any | TypeFlags.String | TypeFlags.Number | TypeFlags.BigInt) ~= 0 or self:isPatternLiteralType(t)
end

function Checker:isPatternLiteralType(t)
    -- A pattern literal type is a template literal or a string mapping type that contains only
    -- non-generic pattern literal placeholders.
    return t.flags & TypeFlags.TemplateLiteral ~= 0 and core.Every(t:AsTemplateLiteralType().types, function(x) return self:isPatternLiteralPlaceholderType(x) end) or
        t.flags & TypeFlags.StringMapping ~= 0 and self:isPatternLiteralPlaceholderType(t:Target())
end

function Checker:isGenericStringLikeType(t)
    return t.flags & (TypeFlags.TemplateLiteral | TypeFlags.StringMapping) ~= 0 and not self:isPatternLiteralType(t)
end

function checker.forEachType(t, f)
    if t.flags & TypeFlags.Union ~= 0 then
        for _, u in ipairs(t:Types()) do
            f(u)
        end
    else
        f(t)
    end
end

function checker.someType(t, f)
    if t.flags & TypeFlags.Union ~= 0 then
        return core.Some(t:Types(), f)
    end
    return f(t)
end

function checker.everyType(t, f)
    if t.flags & TypeFlags.Union ~= 0 then
        return core.Every(t:Types(), f)
    end
    return f(t)
end

function checker.everyContainedType(t, f)
    if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        return core.Every(t:Types(), f)
    end
    return f(t)
end

function Checker:filterType(t, f)
    if t.flags & TypeFlags.Union ~= 0 then
        local types = t:Types()
        local filtered = core.Filter(types, f)
        if core.Same(types, filtered) then
            return t
        end
        local origin = t:AsUnionType().origin
        local newOrigin = nil
        if origin ~= nil and origin.flags & TypeFlags.Union ~= 0 then
            -- If the origin type is a (denormalized) union type, filter its non-union constituents. If that ends
            -- up removing a smaller number of types than in the normalized constituent set (meaning some of the
            -- filtered types are within nested unions in the origin), then we can't construct a new origin type.
            -- Otherwise, if we have exactly one type left in the origin set, return that as the filtered type.
            -- Otherwise, construct a new filtered origin type.
            local originTypes = origin:Types()
            local originFiltered = core.Filter(originTypes, function(u)
                return u.flags & TypeFlags.Union ~= 0 or f(u)
            end)
            if #originTypes - #originFiltered == #types - #filtered then
                if #originFiltered == 1 then
                    return originFiltered[1]
                end
                newOrigin = self:newUnionType(ObjectFlags.None, originFiltered)
            end
        end
        -- filtering could remove intersections so `ContainsIntersections` might be forwarded "incorrectly"
        -- it is purely an optimization hint so there is no harm in accidentally forwarding it
        return self:getUnionTypeFromSortedList(filtered, t:AsUnionType().objectFlags & (ObjectFlags.PrimitiveUnion | checker.ObjectFlagsContainsIntersections), nil --[[alias]], newOrigin)
    end
    if t.flags & TypeFlags.Never ~= 0 or f(t) then
        return t
    end
    return self.neverType
end

function Checker:removeType(t, targetType)
    if t.flags & TypeFlags.Union == 0 then
        if t == targetType then
            return self.neverType
        end
        return t
    end
    local origin = t:AsUnionType().origin
    if origin ~= nil and origin.flags & TypeFlags.Union ~= 0 and checker.containsType(origin:Types(), targetType) then
        return self:filterType(t, function(x) return x ~= targetType end)
    end
    local types = t:Types()
    local i, ok = binarySearchTypes(types, targetType)
    if ok then
        if #types == 2 then
            return types[1 - i + 1]
        end
        -- Remove the target type from the slice.
        local filtered = core.Slice(types, 0, i)
        for k = i + 2, #types do
            filtered[#filtered + 1] = types[k]
        end
        return self:getUnionTypeFromSortedList(filtered, t:AsUnionType().objectFlags & (ObjectFlags.PrimitiveUnion | checker.ObjectFlagsContainsIntersections), nil --[[alias]], nil --[[origin]])
    end
    return t
end

function checker.containsType(types, t)
    local _, ok = binarySearchTypes(types, t)
    return ok
end

-- Returns (types, inserted). Like Go's slices.Insert, the result may be a new array; callers use
-- the returned array.
function checker.insertType(types, t)
    local i, ok = binarySearchTypes(types, t)
    if not ok then
        local result = {}
        for k = 1, i do
            result[k] = types[k]
        end
        result[i + 1] = t
        for k = i + 1, core.Len(types) do
            result[k + 1] = types[k]
        end
        return result, true
    end
    return types, false
end

function checker.countTypes(t)
    if t.flags & TypeFlags.Union ~= 0 then
        return #t:Types()
    elseif t.flags & TypeFlags.Never ~= 0 then
        return 0
    end
    return 1
end

function Checker:isErrorType(t)
    -- The only 'any' types that have alias symbols are those manufactured by getTypeFromTypeAliasReference for
    -- a reference to an unresolved symbol. We want those to behave like the errorType.
    return t == self.errorType or t.flags & TypeFlags.Any ~= 0 and t.alias ~= nil
end

function checker.compareTypeIds(t1, t2)
    return t1.id - t2.id
end

function Checker:checkCrossProductUnion(types)
    local size = self:getCrossProductUnionSize(types)
    if size >= 100000 then
        local tr = self.tracer
        if tr ~= nil then
            tr:Instant(tracing.PhaseCheckTypes, "checkCrossProductUnion_DepthLimit", { size = size })
        end
        self:error(self.currentNode, diagnostics.Expression_produces_a_union_type_that_is_too_complex_to_represent)
        return false
    end
    return true
end

function Checker:getCrossProductUnionSize(types)
    local size = 1
    for _, t in ipairs(types) do
        if t.flags & TypeFlags.Union ~= 0 then
            local n = #t:Types()
            -- Cap the result to avoid integer overflow when computing the cross product of many large unions.
            -- In TypeScript, number overflow produces Infinity which naturally exceeds the limit check;
            -- in Go, we must guard against int wrapping to zero or negative.
            if n > 0 and size > math.maxinteger // n then
                return math.maxinteger
            end
            size = size * n
        elseif t.flags & TypeFlags.Never ~= 0 then
            return 0
        end
    end
    return size
end

function Checker:getIndexType(t)
    return self:getIndexTypeEx(t, IndexFlags.None)
end

function Checker:getIndexTypeEx(t, indexFlags)
    t = self:getReducedType(t)
    if self:isNoInferType(t) then
        return self:getNoInferType(self:getIndexTypeEx(t:AsSubstitutionType().baseType, indexFlags))
    elseif self:shouldDeferIndexType(t, indexFlags) then
        return self:getIndexTypeForGenericType(t, indexFlags)
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:getIntersectionType(core.Map(t:Types(), function(x) return self:getIndexTypeEx(x, indexFlags) end))
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        return self:getUnionType(core.Map(t:Types(), function(x) return self:getIndexTypeEx(x, indexFlags) end))
    elseif t.objectFlags & ObjectFlags.Mapped ~= 0 then
        return self:getIndexTypeForMappedType(t, indexFlags)
    elseif t == self.wildcardType then
        return self.wildcardType
    elseif t.flags & TypeFlags.Unknown ~= 0 then
        return self.neverType
    elseif t.flags & (TypeFlags.Any | TypeFlags.Never) ~= 0 then
        return self.stringNumberSymbolType
    end
    local include = core.IfElse(indexFlags & IndexFlags.NoIndexSignatures ~= 0, TypeFlags.StringLiteral, TypeFlags.StringLike) |
        core.IfElse(indexFlags & IndexFlags.StringsOnly ~= 0, TypeFlags.None, TypeFlags.NumberLike | TypeFlags.ESSymbolLike)
    return self:getLiteralTypeFromProperties(t, include, indexFlags == IndexFlags.None)
end

function Checker:getExtractStringType(t)
    local extractTypeAlias = self.getGlobalExtractSymbol()
    if extractTypeAlias ~= nil then
        return self:getTypeAliasInstantiation(extractTypeAlias, { t, self.stringType }, nil)
    end
    return self.stringType
end

function Checker:getLiteralTypeFromProperties(t, include, includeOrigin)
    local key = checker.PropertiesTypesKey(t.id, include, includeOrigin, t.objectFlags & checker.ObjectFlagsUnresolvedMembers ~= 0)
    local cached = self.propertiesTypes[key]
    if cached ~= nil then
        return cached
    end
    local origin = nil
    if includeOrigin and t.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Reference) ~= 0 or t.alias ~= nil then
        origin = self:newIndexType(t, IndexFlags.None)
    end
    local props = self:getPropertiesOfType(t)
    local indexInfos = self:getIndexInfosOfType(t)
    local types = {}
    for _, prop in ipairs(props or {}) do
        types[#types + 1] = self:getLiteralTypeFromProperty(prop, include, false)
    end
    for _, info in ipairs(indexInfos or {}) do
        if info ~= self.enumNumberIndexInfo and self:isKeyTypeIncluded(info.keyType, include) then
            if info.keyType == self.stringType and include & TypeFlags.Number ~= 0 then
                types[#types + 1] = self.stringOrNumberType
            else
                types[#types + 1] = info.keyType
            end
        end
    end
    local result = self:getUnionTypeEx(types, UnionReduction.Literal, nil, origin)
    self.propertiesTypes[key] = result
    return result
end

function Checker:getLiteralTypeFromProperty(prop, include, includeNonPublic)
    if includeNonPublic or checker.getDeclarationModifierFlagsFromSymbol(prop) & ModifierFlags.NonPublicAccessibilityModifier == 0 then
        local t = self.valueSymbolLinks:Get(self:getLateBoundSymbol(prop)).nameType
        if t == nil then
            if prop.name == ast.InternalSymbolNameDefault then
                t = self:getStringLiteralType("default")
            else
                local name = ast.GetNameOfDeclaration(prop.valueDeclaration)
                if name ~= nil then
                    t = self:getLiteralTypeFromPropertyName(name)
                end
                if t == nil and not checker.IsKnownSymbol(prop) then
                    t = self:getStringLiteralType(ast.SymbolName(prop))
                end
            end
        end
        if t ~= nil and t.flags & include ~= 0 then
            return t
        end
    end
    return self.neverType
end

function Checker:getLiteralTypeFromPropertyName(name)
    if ast.IsPrivateIdentifier(name) then
        return self.neverType
    end
    if ast.IsNumericLiteral(name) then
        return self:getRegularTypeOfLiteralType(self:checkExpression(name))
    end
    if ast.IsComputedPropertyName(name) then
        return self:getRegularTypeOfLiteralType(self:checkComputedPropertyName(name))
    end
    local propertyName = ast.GetPropertyNameForPropertyNameNode(name)
    if propertyName ~= ast.InternalSymbolNameMissing then
        return self:getStringLiteralType(propertyName)
    end
    if ast.IsExpression(name) then
        return self:getRegularTypeOfLiteralType(self:checkExpression(name))
    end
    return self.neverType
end

function Checker:isKeyTypeIncluded(keyType, include)
    return keyType.flags & include ~= 0 or
        keyType.flags & TypeFlags.Intersection ~= 0 and core.Some(keyType:Types(), function(t)
            return self:isKeyTypeIncluded(t, include)
        end)
end

function checker.isInvalidComputedPropertyName(node)
    return (ast.IsTypeLiteralNode(node.parent.parent) or ast.IsClassLike(node.parent.parent) or ast.IsInterfaceDeclaration(node.parent.parent)) and
        ast.IsBinaryExpression(node:Expression()) and node:Expression():AsBinaryExpression().operatorToken.kind == Kind.InKeyword and
        not ast.IsAccessor(node.parent)
end

function Checker:checkComputedPropertyName(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        links.resolvedType = self.circularConstraintType
        if checker.isInvalidComputedPropertyName(node) then
            links.resolvedType = self.errorType
            return links.resolvedType
        end
        links.resolvedType = self:checkExpression(node:Expression())
        -- This will allow types number, string, symbol or any. It will also allow enums, the unknown
        -- type, and any union of these types (like string | number).
        if links.resolvedType.flags & TypeFlags.Nullable ~= 0 or
            not self:isTypeAssignableToKind(links.resolvedType, TypeFlags.StringLike | TypeFlags.NumberLike | TypeFlags.ESSymbolLike) and
            not self:isTypeAssignableTo(links.resolvedType, self.stringNumberSymbolType) then
            self:error(node, diagnostics.A_computed_property_name_must_be_of_type_string_number_symbol_or_any)
        end
    end
    return links.resolvedType
end

function Checker:isNoInferType(t)
    -- A NoInfer<T> type is represented as a substitution type with a TypeFlags.Unknown constraint.
    return t.flags & TypeFlags.Substitution ~= 0 and t:AsSubstitutionType().constraint.flags & TypeFlags.Unknown ~= 0
end

function Checker:getSubstitutionIntersection(t)
    if self:isNoInferType(t) then
        return t:AsSubstitutionType().baseType
    end
    return self:getIntersectionType({ t:AsSubstitutionType().constraint, t:AsSubstitutionType().baseType })
end

function Checker:shouldDeferIndexType(t, indexFlags)
    return t.flags & TypeFlags.InstantiableNonPrimitive ~= 0 or
        self:isGenericTupleType(t) or
        self:isGenericMappedType(t) and self:getNameTypeFromMappedType(t) ~= nil or
        t.flags & TypeFlags.Union ~= 0 and indexFlags & IndexFlags.NoReducibleCheck == 0 and self:isGenericReducibleType(t) or
        t.flags & TypeFlags.Intersection ~= 0 and self:maybeTypeOfKind(t, TypeFlags.Instantiable) and core.Some(t:Types(), function(x) return self:IsEmptyAnonymousObjectType(x) end)
end

function Checker:getMappedTypeNameTypeKind(t)
    local nameType = self:getNameTypeFromMappedType(t)
    if nameType == nil then
        return checker.MappedTypeNameTypeKind.None
    end
    if self:isTypeAssignableTo(nameType, self:getTypeParameterFromMappedType(t)) then
        return checker.MappedTypeNameTypeKind.Filtering
    end
    return checker.MappedTypeNameTypeKind.Remapping
end

function Checker:getIndexTypeForGenericType(t, indexFlags)
    local key = checker.CachedTypeKey(core.IfElse(indexFlags & IndexFlags.StringsOnly ~= 0, CachedTypeKind.StringIndexType, CachedTypeKind.IndexType), t.id)
    local indexType = self.cachedTypes[key]
    if indexType ~= nil then
        return indexType
    end
    indexType = self:newIndexType(t, indexFlags & IndexFlags.StringsOnly)
    self.cachedTypes[key] = indexType
    return indexType
end

-- This roughly mirrors `resolveMappedTypeMembers` in the nongeneric case, except only reports a union of the keys calculated,
-- rather than manufacturing the properties. We can't just fetch the `constraintType` since that would ignore mappings
-- and mapping the `constraintType` directly ignores how mapped types map _properties_ and not keys (thus ignoring subtype
-- reduction in the constraintType) when possible.
-- @param noIndexSignatures Indicates if _string_ index signatures should be elided. (other index signatures are always reported)
function Checker:getIndexTypeForMappedType(t, indexFlags)
    local typeParameter = self:getTypeParameterFromMappedType(t)
    local constraintType = self:getConstraintTypeFromMappedType(t)
    local nameType = self:getNameTypeFromMappedType(core.OrElse(t:AsMappedType().target, t))
    if nameType == nil and indexFlags & IndexFlags.NoIndexSignatures == 0 then
        -- no mapping and no filtering required, just quickly bail to returning the constraint in the common case
        return constraintType
    end
    local keyTypes = nil
    local function addMemberForKeyType(keyType)
        local propNameType = keyType
        if nameType ~= nil then
            propNameType = self:instantiateType(nameType, checker.appendTypeMapping(t:AsMappedType().mapper, typeParameter, keyType))
        end
        -- `keyof` currently always returns `string | number` for concrete `string` index signatures - the below ternary keeps that behavior for mapped types
        -- See `getLiteralTypeFromProperties` where there's a similar ternary to cause the same behavior.
        keyTypes = core.Append(keyTypes, core.IfElse(propNameType == self.stringType, self.stringOrNumberType, propNameType))
    end
    -- Calling getApparentType on the `T` of a `keyof T` in the constraint type of a generic mapped type can
    -- trigger a circularity. For example, `T extends { [P in keyof T & string as Captitalize<P>]: any }` is
    -- a circular definition. For this reason, we only eagerly manifest the keys if the constraint is non-generic.
    if self:isGenericIndexType(constraintType) then
        if self:isMappedTypeWithKeyofConstraintDeclaration(t) then
            -- We have a generic index and a homomorphic mapping and a key remapping - we need to defer
            -- the whole `keyof whatever` for later since it's not safe to resolve the shape of modifier type.
            return self:getIndexTypeForGenericType(t, indexFlags)
        end
        -- Include the generic component in the resulting type.
        checker.forEachType(constraintType, addMemberForKeyType)
    elseif self:isMappedTypeWithKeyofConstraintDeclaration(t) then
        local modifiersType = self:getApparentType(self:getModifiersTypeFromMappedType(t))
        -- The 'T' in 'keyof T'
        self:forEachMappedTypePropertyKeyTypeAndIndexSignatureKeyType(modifiersType, TypeFlags.StringOrNumberLiteralOrUnique, indexFlags & IndexFlags.StringsOnly ~= 0, addMemberForKeyType)
    else
        checker.forEachType(self:getLowerBoundOfKeyType(constraintType), addMemberForKeyType)
    end
    -- We had to pick apart the constraintType to potentially map/filter it - compare the final resulting list with the
    -- original constraintType, so we can return the union that preserves aliases/origin data if possible.
    local result
    if indexFlags & IndexFlags.NoIndexSignatures ~= 0 then
        result = self:filterType(self:getUnionType(keyTypes), function(x)
            return x.flags & (TypeFlags.Any | TypeFlags.String) == 0
        end)
    else
        result = self:getUnionType(keyTypes)
    end
    if result.flags & TypeFlags.Union ~= 0 and constraintType.flags & TypeFlags.Union ~= 0 and checker.getTypeListKey(result:Types()) == checker.getTypeListKey(constraintType:Types()) then
        return constraintType
    end
    return result
end

function Checker:getIndexedAccessType(objectType, indexType)
    return self:getIndexedAccessTypeEx(objectType, indexType, AccessFlags.None, nil, nil)
end

function Checker:getIndexedAccessTypeEx(objectType, indexType, accessFlags, accessNode, alias)
    local result = self:getIndexedAccessTypeOrUndefined(objectType, indexType, accessFlags, accessNode, alias)
    if result == nil then
        result = core.IfElse(accessNode ~= nil, self.errorType, self.unknownType)
    end
    return result
end

function Checker:getIndexedAccessTypeOrUndefined(objectType, indexType, accessFlags, accessNode, alias)
    if objectType == self.wildcardType or indexType == self.wildcardType then
        return self.wildcardType
    end
    objectType = self:getReducedType(objectType)
    -- If the object type has a string index signature and no other members we know that the result will
    -- always be the type of that index signature and we can simplify accordingly.
    if self.isStringIndexSignatureOnlyType(objectType) and indexType.flags & TypeFlags.Nullable == 0 and self:isTypeAssignableToKind(indexType, TypeFlags.String | TypeFlags.Number) then
        indexType = self.stringType
    end
    -- In noUncheckedIndexedAccess mode, indexed access operations that occur in an expression in a read position and resolve to
    -- an index signature have 'undefined' included in their type.
    if self.compilerOptions.noUncheckedIndexedAccess == core.Tristate.TSTrue and accessFlags & AccessFlags.ExpressionPosition ~= 0 then
        accessFlags = accessFlags | AccessFlags.IncludeUndefined
    end
    -- If the index type is generic, or if the object type is generic and doesn't originate in an expression and
    -- the operation isn't exclusively indexing the fixed (non-variadic) portion of a tuple type, we are performing
    -- a higher-order index access where we cannot meaningfully access the properties of the object type. Note that
    -- for a generic T and a non-generic K, we eagerly resolve T[K] if it originates in an expression. This is to
    -- preserve backwards compatibility. For example, an element access 'this["foo"]' has always been resolved
    -- eagerly using the constraint type of 'this' at the given location.
    if self:shouldDeferIndexedAccessType(objectType, indexType, accessNode) then
        if objectType.flags & TypeFlags.AnyOrUnknown ~= 0 then
            return objectType
        end
        -- Defer the operation by creating an indexed access type.
        local persistentAccessFlags = accessFlags & AccessFlags.Persistent
        local key = checker.getIndexedAccessKey(objectType, indexType, accessFlags, alias)
        local t = self.indexedAccessTypes[key]
        if t == nil then
            t = self:newIndexedAccessType(objectType, indexType, persistentAccessFlags)
            t.alias = alias
            self.indexedAccessTypes[key] = t
        end
        return t
    end
    -- In the following we resolve T[K] to the type of the property in T selected by K.
    -- We treat boolean as different from other unions to improve errors;
    -- skipping straight to getPropertyTypeForIndexType gives errors with 'boolean' instead of 'true'.
    local apparentObjectType = self:getReducedApparentType(objectType)
    if indexType.flags & TypeFlags.Union ~= 0 and indexType.flags & TypeFlags.Boolean == 0 then
        local propTypes = nil
        local wasMissingProp = false
        for _, t in ipairs(indexType:Types()) do
            local propType = self:getPropertyTypeForIndexType(objectType, apparentObjectType, t, indexType, accessNode, accessFlags | core.IfElse(wasMissingProp, AccessFlags.SuppressNoImplicitAnyError, 0))
            if propType ~= nil then
                propTypes = core.Append(propTypes, propType)
            elseif accessNode == nil then
                -- If there's no error node, we can immediately stop, since error reporting is off
                return nil
            else
                -- Otherwise we set a flag and return at the end of the loop so we still mark all errors
                wasMissingProp = true
            end
        end
        if wasMissingProp then
            return nil
        end
        if accessFlags & AccessFlags.Writing ~= 0 then
            return self:getIntersectionTypeEx(propTypes, IntersectionFlags.None, alias)
        end
        return self:getUnionTypeEx(propTypes, UnionReduction.Literal, alias, nil)
    end
    return self:getPropertyTypeForIndexType(objectType, apparentObjectType, indexType, indexType, accessNode, accessFlags | AccessFlags.CacheSymbol | AccessFlags.ReportDeprecated)
end

function Checker:getPropertyTypeForIndexType(originalObjectType, objectType, indexType, fullIndexType, accessNode, accessFlags)
    local accessExpression = nil
    if accessNode ~= nil and ast.IsElementAccessExpression(accessNode) then
        accessExpression = accessNode
    end
    local propName = ""
    local hasPropName = false
    if not (accessNode ~= nil and ast.IsPrivateIdentifier(accessNode)) then
        propName = self:getPropertyNameFromIndex(indexType, accessNode)
        hasPropName = propName ~= ast.InternalSymbolNameMissing
    end
    if hasPropName then
        if accessFlags & AccessFlags.Contextual ~= 0 then
            local t = self:getTypeOfPropertyOfContextualType(objectType, propName)
            if t == nil then
                t = self.anyType
            end
            return t
        end
        local prop = self:getPropertyOfType(objectType, propName)
        if prop ~= nil then
            if accessFlags & AccessFlags.ReportDeprecated ~= 0 and accessNode ~= nil and core.Len(prop.declarations) ~= 0 and self:isDeprecatedSymbol(prop) and self:isUncalledFunctionReference(accessNode, prop) then
                local deprecatedNode
                if accessExpression ~= nil then
                    deprecatedNode = accessExpression:AsElementAccessExpression().argumentExpression
                elseif ast.IsIndexedAccessTypeNode(accessNode) then
                    deprecatedNode = accessNode:AsIndexedAccessTypeNode().indexType
                else
                    deprecatedNode = accessNode
                end
                self:addDeprecatedSuggestion(deprecatedNode, prop.declarations, propName)
            end
            if accessExpression ~= nil then
                self:markPropertyAsReferenced(prop, accessExpression, self:isSelfTypeAccess(accessExpression:Expression(), objectType.symbol))
                if self:isAssignmentToReadonlyEntity(accessExpression, prop, checker.getAssignmentTargetKind(accessExpression)) then
                    self:error(accessExpression:AsElementAccessExpression().argumentExpression, diagnostics.Cannot_assign_to_0_because_it_is_a_read_only_property, self:symbolToString(prop))
                    return nil
                end
                if accessFlags & AccessFlags.CacheSymbol ~= 0 then
                    self.symbolNodeLinks:Get(accessNode).resolvedSymbol = prop
                end
                if self:isThisPropertyAccessInConstructor(accessExpression, prop) then
                    return self.autoType
                end
            end
            local propType
            if accessFlags & AccessFlags.Writing ~= 0 then
                propType = self:getWriteTypeOfSymbol(prop)
            else
                propType = self:getTypeOfSymbol(prop)
            end
            if accessExpression ~= nil and checker.getAssignmentTargetKind(accessExpression) ~= checker.AssignmentKind.Definite then
                return self:getFlowTypeOfReference(accessExpression, propType)
            elseif accessNode ~= nil and ast.IsIndexedAccessTypeNode(accessNode) and self.containsMissingType(propType) then
                return self:getUnionType({ propType, self.undefinedType })
            else
                return propType
            end
        end
        if checker.everyType(objectType, checker.isTupleType) and checker.isNumericLiteralName(propName) then
            local index = jsnum.FromString(propName)
            if accessNode ~= nil and checker.everyType(objectType, function(t)
                    return t:TargetTupleType().combinedFlags & ElementFlags.Variable == 0
                end) and accessFlags & AccessFlags.AllowMissing == 0 then
                local indexNode = checker.getIndexNodeForAccessExpression(accessNode)
                if checker.isTupleType(objectType) then
                    if index < 0 then
                        self:error(indexNode, diagnostics.A_tuple_type_cannot_be_indexed_with_a_negative_value)
                        return self.undefinedType
                    end
                    self:error(indexNode, diagnostics.Tuple_type_0_of_length_1_has_no_element_at_index_2, self:TypeToString(objectType), self:getTypeReferenceArity(objectType), propName)
                else
                    self:error(indexNode, diagnostics.Property_0_does_not_exist_on_type_1, propName, self:TypeToString(objectType))
                end
            end
            if index >= 0 then
                self:errorIfWritingToReadonlyIndex(self:getIndexInfoOfType(objectType, self.numberType), objectType, accessExpression)
                return self:getTupleElementTypeOutOfStartCount(objectType, index, core.IfElse(accessFlags & AccessFlags.IncludeUndefined ~= 0, self.missingType, nil))
            end
        end
    end
    if indexType.flags & TypeFlags.Nullable == 0 and self:isTypeAssignableToKind(indexType, TypeFlags.StringLike | TypeFlags.NumberLike | TypeFlags.ESSymbolLike) then
        if objectType.flags & (TypeFlags.Any | TypeFlags.Never) ~= 0 then
            return objectType
        end
        -- If no index signature is applicable, we default to the string index signature. In effect, this means the string
        -- index signature applies even when accessing with a symbol-like type.
        local indexInfo = self:getApplicableIndexInfo(objectType, indexType)
        if indexInfo == nil then
            indexInfo = self:getIndexInfoOfType(objectType, self.stringType)
        end
        if indexInfo ~= nil then
            if accessFlags & AccessFlags.NoIndexSignatures ~= 0 and indexInfo.keyType ~= self.numberType then
                if accessExpression ~= nil then
                    if accessFlags & AccessFlags.Writing ~= 0 then
                        self:error(accessExpression, diagnostics.Type_0_is_generic_and_can_only_be_indexed_for_reading, self:TypeToString(originalObjectType))
                    else
                        self:error(accessExpression, diagnostics.Type_0_cannot_be_used_to_index_type_1, self:TypeToString(indexType), self:TypeToString(originalObjectType))
                    end
                end
                return nil
            end
            if accessNode ~= nil and indexInfo.keyType == self.stringType and not self:isTypeAssignableToKind(indexType, TypeFlags.String | TypeFlags.Number) then
                local indexNode = checker.getIndexNodeForAccessExpression(accessNode)
                self:error(indexNode, diagnostics.Type_0_cannot_be_used_as_an_index_type, self:TypeToString(indexType))
                if accessFlags & AccessFlags.IncludeUndefined ~= 0 then
                    return self:getUnionType({ indexInfo.valueType, self.missingType })
                else
                    return indexInfo.valueType
                end
            end
            self:errorIfWritingToReadonlyIndex(indexInfo, objectType, accessExpression)
            -- When accessing an enum object with its own type,
            -- e.g. E[E.A] for enum E { A }, undefined shouldn't
            -- be included in the result type
            if accessFlags & AccessFlags.IncludeUndefined ~= 0 and
                not (objectType.symbol ~= nil and
                    objectType.symbol.flags & (SymbolFlags.RegularEnum | SymbolFlags.ConstEnum) ~= 0 and
                    (indexType.symbol ~= nil and
                        indexType.flags & TypeFlags.EnumLiteral ~= 0 and
                        self:getParentOfSymbol(indexType.symbol) == objectType.symbol)) then
                return self:getUnionType({ indexInfo.valueType, self.missingType })
            end
            return indexInfo.valueType
        end
        if indexType.flags & TypeFlags.Never ~= 0 then
            return self.neverType
        end
        if self:isJSLiteralType(objectType) then
            return self.anyType
        end
        if accessExpression ~= nil and not checker.isConstEnumObjectType(objectType) then
            if checker.isObjectLiteralType(objectType) then
                if self.noImplicitAny and indexType.flags & (TypeFlags.StringLiteral | TypeFlags.NumberLiteral) ~= 0 then
                    self:addDiagnostic(checker.createDiagnosticForNode(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, indexType:AsLiteralType().value, self:TypeToString(objectType)))
                    return self.undefinedType
                elseif indexType.flags & (TypeFlags.Number | TypeFlags.String) ~= 0 then
                    local types = core.Map(objectType:AsStructuredType().properties, function(prop)
                        return self:getTypeOfSymbol(prop)
                    end)
                    return self:getUnionType(core.Append(types, self.undefinedType))
                end
            end
            if objectType.symbol == self.globalThisSymbol and hasPropName and self.globalThisSymbol.exports[propName] ~= nil and self.globalThisSymbol.exports[propName].flags & SymbolFlags.BlockScoped ~= 0 then
                self:error(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, propName, self:TypeToString(objectType))
            elseif self.noImplicitAny and accessFlags & AccessFlags.SuppressNoImplicitAnyError == 0 then
                if hasPropName and self:typeHasStaticProperty(propName, objectType) then
                    local typeName = self:TypeToString(objectType)
                    self:error(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1_Did_you_mean_to_access_the_static_member_2_instead, propName --[[as string]], typeName, typeName .. "[" .. scanner.GetTextOfNode(accessExpression:AsElementAccessExpression().argumentExpression) .. "]")
                elseif self:getIndexTypeOfType(objectType, self.numberType) ~= nil then
                    self:error(accessExpression:AsElementAccessExpression().argumentExpression, diagnostics.Element_implicitly_has_an_any_type_because_index_expression_is_not_of_type_number)
                else
                    local suggestion = ""
                    if hasPropName then
                        suggestion = self:getSuggestionForNonexistentProperty(propName, objectType)
                    end
                    if suggestion ~= "" then
                        self:error(accessExpression:AsElementAccessExpression().argumentExpression, diagnostics.Property_0_does_not_exist_on_type_1_Did_you_mean_2, propName --[[as string]], self:TypeToString(objectType), suggestion)
                    else
                        suggestion = self:getSuggestionForNonexistentIndexSignature(objectType, accessExpression, indexType)
                        if suggestion ~= "" then
                            self:error(accessExpression, diagnostics.Element_implicitly_has_an_any_type_because_type_0_has_no_index_signature_Did_you_mean_to_call_1, self:TypeToString(objectType), suggestion)
                        else
                            local diagnostic = nil
                            if indexType.flags & TypeFlags.EnumLiteral ~= 0 then
                                diagnostic = checker.NewDiagnosticForNode(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, "[" .. self:TypeToString(indexType) .. "]", self:TypeToString(objectType))
                            elseif indexType.flags & TypeFlags.UniqueESSymbol ~= 0 then
                                local symbolName = self:getFullyQualifiedName(indexType.symbol, accessExpression)
                                diagnostic = checker.NewDiagnosticForNode(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, "[" .. symbolName .. "]", self:TypeToString(objectType))
                            elseif indexType.flags & TypeFlags.StringLiteral ~= 0 then
                                diagnostic = checker.NewDiagnosticForNode(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, indexType:AsLiteralType().value, self:TypeToString(objectType))
                            elseif indexType.flags & TypeFlags.NumberLiteral ~= 0 then
                                diagnostic = checker.NewDiagnosticForNode(accessExpression, diagnostics.Property_0_does_not_exist_on_type_1, indexType:AsLiteralType().value, self:TypeToString(objectType))
                            elseif indexType.flags & (TypeFlags.Number | TypeFlags.String) ~= 0 then
                                diagnostic = checker.NewDiagnosticForNode(accessExpression, diagnostics.No_index_signature_with_a_parameter_of_type_0_was_found_on_type_1, self:TypeToString(indexType), self:TypeToString(objectType))
                            end
                            self:addDiagnostic(checker.NewDiagnosticChainForNode(diagnostic, accessExpression, diagnostics.Element_implicitly_has_an_any_type_because_expression_of_type_0_can_t_be_used_to_index_type_1, self:TypeToString(fullIndexType), self:TypeToString(objectType)))
                        end
                    end
                end
            end
            return nil
        end
    end
    if accessFlags & AccessFlags.AllowMissing ~= 0 and checker.isObjectLiteralType(objectType) then
        return self.undefinedType
    end
    if self:isJSLiteralType(objectType) then
        return self.anyType
    end
    if accessNode ~= nil then
        local indexNode = checker.getIndexNodeForAccessExpression(accessNode)
        if indexNode.kind ~= Kind.BigIntLiteral and indexType.flags & (TypeFlags.StringLiteral | TypeFlags.NumberLiteral) ~= 0 then
            self:error(indexNode, diagnostics.Property_0_does_not_exist_on_type_1, indexType:AsLiteralType().value, self:TypeToString(objectType))
        elseif indexType.flags & (TypeFlags.String | TypeFlags.Number) ~= 0 then
            self:error(indexNode, diagnostics.Type_0_has_no_matching_index_signature_for_type_1, self:TypeToString(objectType), self:TypeToString(indexType))
        else
            local typeString
            if indexNode.kind == Kind.BigIntLiteral then
                typeString = "bigint"
            else
                typeString = self:TypeToString(indexType)
            end
            self:error(indexNode, diagnostics.Type_0_cannot_be_used_as_an_index_type, typeString)
        end
    end
    if checker.IsTypeAny(indexType) then
        return indexType
    end
    return nil
end

function Checker:typeHasStaticProperty(propName, containingType)
    if containingType.symbol ~= nil then
        local prop = self:getPropertyOfType(self:getTypeOfSymbol(containingType.symbol), propName)
        return prop ~= nil and prop.valueDeclaration ~= nil and ast.IsStatic(prop.valueDeclaration)
    end
    return false
end

function Checker:getSuggestionForNonexistentProperty(name, containingType)
    local symbol = self:getSpellingSuggestionForName(name, self:getPropertiesOfType(containingType) or {}, SymbolFlags.Value)
    if symbol ~= nil then
        return symbol.name
    end
    return ""
end

function Checker:getSuggestionForNonexistentIndexSignature(objectType, expr, keyedType)
    -- check if object type has setter or getter
    local function hasProp(name)
        local prop = self:getPropertyOfObjectType(objectType, name)
        if prop ~= nil then
            local s = self:getSingleCallSignature(self:getTypeOfSymbol(prop))
            return s ~= nil and self:getMinArgumentCount(s) >= 1 and self:isTypeAssignableTo(keyedType, self:getTypeAtPosition(s, 0))
        end
        return false
    end
    local suggestedMethod = core.IfElse(ast.IsAssignmentTarget(expr), "set", "get")
    if not hasProp(suggestedMethod) then
        return ""
    end
    local suggestion = checker.tryGetPropertyAccessOrIdentifierToString(expr:Expression())
    if suggestion == "" then
        return suggestedMethod
    end
    return suggestion .. "." .. suggestedMethod
end

function Checker:getSuggestedTypeForNonexistentStringLiteralType(source, target)
    local candidates = core.Filter(target:Types(), function(t) return t.flags & TypeFlags.StringLiteral ~= 0 end)
    return core.GetSpellingSuggestionWithMaxCandidateCount(checker.getStringLiteralValue(source), candidates, checker.getStringLiteralValue, checker.CompareTypes, 1000)
end

function checker.getIndexNodeForAccessExpression(accessNode)
    local k = accessNode.kind
    if k == Kind.ElementAccessExpression then
        return accessNode:AsElementAccessExpression().argumentExpression
    elseif k == Kind.IndexedAccessType then
        return accessNode:AsIndexedAccessTypeNode().indexType
    elseif k == Kind.ComputedPropertyName then
        return accessNode:Expression()
    end
    return accessNode
end

function Checker:errorIfWritingToReadonlyIndex(indexInfo, objectType, accessExpression)
    if indexInfo ~= nil and indexInfo.isReadonly and accessExpression ~= nil and (ast.IsAssignmentTarget(accessExpression) or checker.isDeleteTarget(accessExpression)) then
        self:error(accessExpression, diagnostics.Index_signature_in_type_0_only_permits_reading, self:TypeToString(objectType))
    end
end

function Checker:isSelfTypeAccess(name, parent)
    return name.kind == Kind.ThisKeyword or parent ~= nil and ast.IsEntityNameExpression(name) and parent == self:getResolvedSymbol(ast.GetFirstIdentifier(name))
end

function Checker:isAssignmentToReadonlyEntity(expr, symbol, assignmentKind)
    if assignmentKind == checker.AssignmentKind.None then
        -- no assignment means it doesn't matter whether the entity is readonly
        return false
    end
    if ast.IsAccessExpression(expr) then
        local node = ast.SkipParentheses(expr:Expression())
        if ast.IsIdentifier(node) then
            local expressionSymbol = self:getResolvedSymbol(node)
            -- CommonJS module.exports is never readonly
            if expressionSymbol.flags & SymbolFlags.ModuleExports ~= 0 then
                return false
            end
        end
    end
    if self:isReadonlySymbol(symbol) then
        -- Allow assignments to readonly properties within constructors of the same class declaration.
        if symbol.flags & SymbolFlags.Property ~= 0 and ast.IsAccessExpression(expr) and expr:Expression().kind == Kind.ThisKeyword then
            -- Look for if this is the constructor for the class that `symbol` is a property of.
            local ctor = self:getControlFlowContainer(expr)
            if ctor == nil or not ast.IsConstructorDeclaration(ctor) then
                return true
            end
            if symbol.valueDeclaration ~= nil then
                local isAssignmentDeclaration = ast.IsBinaryExpression(symbol.valueDeclaration)
                local isLocalPropertyDeclaration = ctor.parent == symbol.valueDeclaration.parent
                local isLocalParameterProperty = ctor == symbol.valueDeclaration.parent
                local isLocalThisPropertyAssignment = isAssignmentDeclaration and symbol.parent.valueDeclaration == ctor.parent
                local isLocalThisPropertyAssignmentConstructorFunction = isAssignmentDeclaration and symbol.parent.valueDeclaration == ctor
                local isWriteableSymbol = isLocalPropertyDeclaration or isLocalParameterProperty or isLocalThisPropertyAssignment or isLocalThisPropertyAssignmentConstructorFunction
                return not isWriteableSymbol
            end
        end
        return true
    end
    if ast.IsAccessExpression(expr) then
        -- references through namespace import should be readonly
        local node = ast.SkipParentheses(expr:Expression())
        if ast.IsIdentifier(node) then
            local expressionSymbol = self:getResolvedSymbol(node)
            if expressionSymbol.flags & SymbolFlags.Alias ~= 0 then
                local declaration = self:getDeclarationOfAliasSymbol(expressionSymbol)
                return declaration ~= nil and ast.IsNamespaceImport(declaration)
            end
        end
    end
    return false
end

function Checker:isThisPropertyAccessInConstructor(node, prop)
    local constructor = nil
    local kind, location = self:isConstructorDeclaredThisProperty(prop)
    if kind == checker.thisAssignmentDeclarationConstructor then
        constructor = location
    elseif checker.isThisProperty(node) and self:isAutoTypedProperty(prop) then
        constructor = self:getDeclaringConstructor(prop)
    end
    return ast.GetThisContainer(node, true --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]]) == constructor
end

function Checker:isAutoTypedProperty(symbol)
    -- A property is auto-typed when its declaration has no type annotation or initializer and we're in
    -- noImplicitAny mode or a .js file.
    local declaration = symbol.valueDeclaration
    return declaration ~= nil and ast.IsPropertyDeclaration(declaration) and declaration:Type() == nil and declaration:Initializer() == nil and self.noImplicitAny
end

function Checker:getDeclaringConstructor(symbol)
    for _, declaration in ipairs(symbol.declarations or {}) do
        local container = ast.GetThisContainer(declaration, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
        if container ~= nil and ast.IsConstructorDeclaration(container) then
            return container
        end
    end
    return nil
end

function Checker:getPropertyNameFromIndex(indexType, accessNode)
    if checker.isTypeUsableAsPropertyName(indexType) then
        return checker.getPropertyNameFromType(indexType)
    end
    if accessNode ~= nil and ast.IsPropertyName(accessNode) then
        return ast.GetPropertyNameForPropertyNameNode(accessNode)
    end
    return ast.InternalSymbolNameMissing
end

function Checker:isStringIndexSignatureOnlyTypeWorker(t)
    return t.flags & TypeFlags.Object ~= 0 and not self:isGenericMappedType(t) and core.Len(self:getPropertiesOfType(t)) == 0 and core.Len(self:getIndexInfosOfType(t)) == 1 and self:getIndexInfoOfType(t, self.stringType) ~= nil or
        t.flags & TypeFlags.UnionOrIntersection ~= 0 and core.Every(t:Types(), self.isStringIndexSignatureOnlyType)
end

function Checker:shouldDeferIndexedAccessType(objectType, indexType, accessNode)
    if self:isGenericIndexType(indexType) then
        return true
    end
    if accessNode ~= nil and not ast.IsIndexedAccessTypeNode(accessNode) then
        return self:isGenericTupleType(objectType) and not checker.indexTypeLessThan(indexType, checker.getTotalFixedElementCount(objectType:TargetTupleType()))
    end
    return self:isGenericObjectType(objectType) and not (checker.isTupleType(objectType) and checker.indexTypeLessThan(indexType, checker.getTotalFixedElementCount(objectType:TargetTupleType()))) or
        self:isGenericReducibleType(objectType)
end

function checker.indexTypeLessThan(indexType, limit)
    return checker.everyType(indexType, function(t)
        if t.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
            local propName = checker.getPropertyNameFromType(t)
            if checker.isNumericLiteralName(propName) then
                local index = jsnum.FromString(propName)
                return index >= 0 and index < limit
            end
        end
        return false
    end)
end

function Checker:getNoInferType(t)
    if self:isNoInferTargetType(t) then
        return self:getOrCreateSubstitutionType(t, self.unknownType)
    end
    return t
end

function Checker:isNoInferTargetType(t)
    -- This is effectively a more conservative and predictable form of couldContainTypeVariables. We want to
    -- preserve NoInfer<T> only for types that could contain type variables, but we don't want to exhaustively
    -- examine all object type members.
    return t.flags & TypeFlags.UnionOrIntersection ~= 0 and core.Some(t:AsUnionOrIntersectionType().types, function(x) return self:isNoInferTargetType(x) end) or
        t.flags & TypeFlags.Substitution ~= 0 and not self:isNoInferType(t) and self:isNoInferTargetType(t:AsSubstitutionType().baseType) or
        t.flags & TypeFlags.Object ~= 0 and not self:IsEmptyAnonymousObjectType(t) or
        t.flags & (TypeFlags.Instantiable & ~TypeFlags.Substitution) ~= 0 and not self:isPatternLiteralType(t)
end

function Checker:getSubstitutionType(baseType, constraint)
    if constraint.flags & TypeFlags.AnyOrUnknown ~= 0 or constraint == baseType or baseType.flags & TypeFlags.Any ~= 0 then
        return baseType
    end
    return self:getOrCreateSubstitutionType(baseType, constraint)
end

function Checker:getOrCreateSubstitutionType(baseType, constraint)
    local key = checker.SubstitutionTypeKey(baseType.id, constraint.id)
    local cached = self.substitutionTypes[key]
    if cached ~= nil then
        return cached
    end
    local result = self:newSubstitutionType(baseType, constraint)
    self.substitutionTypes[key] = result
    return result
end

function Checker:getBaseConstraintOrType(t)
    local constraint = self:getBaseConstraintOfType(t)
    if constraint ~= nil then
        return constraint
    end
    return t
end

function Checker:getBaseConstraintOfType(t)
    if t.flags & (TypeFlags.InstantiableNonPrimitive | TypeFlags.UnionOrIntersection | TypeFlags.TemplateLiteral | TypeFlags.StringMapping | TypeFlags.Index) ~= 0 or self:isGenericTupleType(t) then
        local constraint = self:getResolvedBaseConstraint(t, nil)
        if constraint ~= self.noConstraintType and constraint ~= self.circularConstraintType then
            return constraint
        end
        return nil
    end
    return nil
end

-- stack is an array of recursion identities (see getRecursionIdentity); it is never mutated.
function Checker:getResolvedBaseConstraint(t, stack)
    local constrained = t:AsConstrainedType()
    if constrained == nil then
        return t
    end
    if constrained.resolvedBaseConstraint ~= nil then
        return constrained.resolvedBaseConstraint
    end
    if not self:pushTypeResolution(t, checker.TypeSystemPropertyName.ResolvedBaseConstraint) then
        return self.circularConstraintType
    end
    local constraint = nil
    -- We always explore at least 10 levels of nested constraints. Thereafter, we continue to explore
    -- up to 50 levels of nested constraints provided there are no "deeply nested" types on the stack
    -- (i.e. no types for which five instantiations have been recorded on the stack). If we reach 50
    -- levels of nesting, we are presumably exploring a repeating pattern with a long cycle that hasn't
    -- yet triggered the deeply nested limiter. We have no test cases that actually get to 50 levels of
    -- nesting, so it is effectively just a safety stop.
    local identity = checker.getRecursionIdentity(t)
    local n = core.Len(stack)
    if n < 10 or n < 50 and not slicesContains(stack, identity) then
        local newStack = slicesClone(stack) or {}
        newStack[#newStack + 1] = identity
        constraint = self:computeBaseConstraint(self:getSimplifiedType(t --[[writing]], false), newStack)
    end
    if not self:popTypeResolution() then
        if t.flags & TypeFlags.TypeParameter ~= 0 then
            local errorNode = self:getConstraintDeclaration(t)
            if errorNode ~= nil then
                local diagnostic = self:error(errorNode, diagnostics.Type_parameter_0_has_a_circular_constraint, self:TypeToString(t))
                if self.currentNode ~= nil and not checker.isNodeDescendantOf(errorNode, self.currentNode) and not checker.isNodeDescendantOf(self.currentNode, errorNode) then
                    diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(self.currentNode, diagnostics.Circularity_originates_in_type_at_this_location))
                end
            end
        end
        constraint = self.circularConstraintType
    end
    if constraint == nil then
        constraint = self.noConstraintType
    end
    if constrained.resolvedBaseConstraint == nil then
        constrained.resolvedBaseConstraint = constraint
    end
    return constraint
end

function Checker:computeBaseConstraint(t, stack)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        local constraint = self:getConstraintFromTypeParameter(t)
        if t:AsTypeParameter().isThisType then
            return constraint
        end
        return self:getNextBaseConstraint(constraint, stack)
    elseif t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        local types = t:Types()
        local constraints = {}
        local different = false
        for _, s in ipairs(types) do
            local constraint = self:getNextBaseConstraint(s, stack)
            if constraint ~= nil then
                if constraint ~= s then
                    different = true
                end
                constraints[#constraints + 1] = constraint
            else
                different = true
            end
        end
        if not different then
            return t
        end
        if t.flags & TypeFlags.Union ~= 0 and #constraints == #types then
            return self:getUnionType(constraints)
        elseif t.flags & TypeFlags.Intersection ~= 0 and #constraints ~= 0 then
            return self:getIntersectionType(constraints)
        end
        return nil
    elseif t.flags & TypeFlags.Index ~= 0 then
        if self:isGenericMappedType(t:AsIndexType().target) then
            local mappedType = t:AsIndexType().target
            if self:getNameTypeFromMappedType(mappedType) ~= nil and not self:isMappedTypeWithKeyofConstraintDeclaration(mappedType) then
                return self:getNextBaseConstraint(self:getIndexTypeForMappedType(mappedType, IndexFlags.None), stack)
            end
        end
        return self.stringNumberSymbolType
    elseif t.flags & TypeFlags.TemplateLiteral ~= 0 then
        local types = t:Types()
        local constraints = {}
        for _, s in ipairs(types) do
            local constraint = self:getNextBaseConstraint(s, stack)
            if constraint ~= nil then
                constraints[#constraints + 1] = constraint
            end
        end
        if #constraints == #types then
            return self:getTemplateLiteralType(t:AsTemplateLiteralType().texts, constraints)
        end
        return self.stringType
    elseif t.flags & TypeFlags.StringMapping ~= 0 then
        local constraint = self:getNextBaseConstraint(t:Target(), stack)
        if constraint ~= nil and constraint ~= t:Target() then
            return self:getStringMappingType(t.symbol, constraint)
        end
        return self.stringType
    elseif t.flags & TypeFlags.IndexedAccess ~= 0 then
        if self:isMappedTypeGenericIndexedAccess(t) then
            -- For indexed access types of the form { [P in K]: E }[X], where K is non-generic and X is generic,
            -- we substitute an instantiation of E where P is replaced with X.
            return self:getNextBaseConstraint(self:substituteIndexedMappedType(t:AsIndexedAccessType().objectType, t:AsIndexedAccessType().indexType), stack)
        end
        local baseObjectType = self:getNextBaseConstraint(t:AsIndexedAccessType().objectType, stack)
        local baseIndexType = self:getNextBaseConstraint(t:AsIndexedAccessType().indexType, stack)
        if baseObjectType == nil or baseIndexType == nil then
            return nil
        end
        return self:getNextBaseConstraint(self:getIndexedAccessTypeOrUndefined(baseObjectType, baseIndexType, t:AsIndexedAccessType().accessFlags, nil, nil), stack)
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        if self.conditionalConstraintDepth >= 100 then
            return nil
        end
        self.conditionalConstraintDepth = self.conditionalConstraintDepth + 1
        local constraint = self:getConstraintFromConditionalType(t)
        self.conditionalConstraintDepth = self.conditionalConstraintDepth - 1
        return self:getNextBaseConstraint(constraint, stack)
    elseif t.flags & TypeFlags.Substitution ~= 0 then
        return self:getNextBaseConstraint(self:getSubstitutionIntersection(t), stack)
    elseif self:isGenericTupleType(t) then
        -- We substitute constraints for variadic elements only when the constraints are array types or
        -- non-variadic tuple types as we want to avoid further (possibly unbounded) recursion.
        local elementTypes = self:getElementTypes(t)
        local elementInfos = t:TargetTupleType().elementInfos
        local newElements = {}
        for i, v in ipairs(elementTypes) do
            local newElement = v
            if v.flags & TypeFlags.TypeParameter ~= 0 and elementInfos[i].flags & ElementFlags.Variadic ~= 0 then
                local constraint = self:getNextBaseConstraint(v, stack)
                if constraint ~= nil and constraint ~= v and checker.everyType(constraint, function(n) return self:isArrayOrTupleType(n) and not self:isGenericTupleType(n) end) then
                    newElement = constraint
                end
            end
            newElements[#newElements + 1] = newElement
        end
        return self:createTupleTypeEx(newElements, elementInfos, t:TargetTupleType().readonly)
    end
    return t
end

function Checker:getNextBaseConstraint(t, stack)
    if t == nil then
        return nil
    end
    local constraint = self:getResolvedBaseConstraint(t, stack)
    if constraint == self.noConstraintType or constraint == self.circularConstraintType then
        return nil
    end
    return constraint
end

-- Return true if type might be of the given kind. A union or intersection type might be of a given
-- kind if at least one constituent type is of the given kind.
function Checker:maybeTypeOfKind(t, kind)
    if t.flags & kind ~= 0 then
        return true
    end
    if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        for _, u in ipairs(t:Types()) do
            if self:maybeTypeOfKind(u, kind) then
                return true
            end
        end
    end
    return false
end

function Checker:maybeTypeOfKindConsideringBaseConstraint(t, kind)
    if self:maybeTypeOfKind(t, kind) then
        return true
    end
    local baseConstraint = self:getBaseConstraintOrType(t)
    return baseConstraint ~= nil and self:maybeTypeOfKind(baseConstraint, kind)
end

function Checker:allTypesAssignableToKind(source, kind)
    return self:allTypesAssignableToKindEx(source, kind, false)
end

function Checker:allTypesAssignableToKindEx(source, kind, strict)
    if source.flags & TypeFlags.Union ~= 0 then
        return core.Every(source:Types(), function(subType)
            return self:allTypesAssignableToKindEx(subType, kind, strict)
        end)
    end
    return self:isTypeAssignableToKindEx(source, kind, strict)
end

function Checker:isTypeAssignableToKind(source, kind)
    return self:isTypeAssignableToKindEx(source, kind, false)
end

function Checker:isTypeAssignableToKindEx(source, kind, strict)
    if source.flags & kind ~= 0 then
        return true
    end
    if strict and source.flags & (TypeFlags.AnyOrUnknown | TypeFlags.Void | TypeFlags.Undefined | TypeFlags.Null) ~= 0 then
        return false
    end
    return kind & TypeFlags.NumberLike ~= 0 and self:isTypeAssignableTo(source, self.numberType) or
        kind & TypeFlags.BigIntLike ~= 0 and self:isTypeAssignableTo(source, self.bigintType) or
        kind & TypeFlags.StringLike ~= 0 and self:isTypeAssignableTo(source, self.stringType) or
        kind & TypeFlags.BooleanLike ~= 0 and self:isTypeAssignableTo(source, self.booleanType) or
        kind & TypeFlags.Void ~= 0 and self:isTypeAssignableTo(source, self.voidType) or
        kind & TypeFlags.Never ~= 0 and self:isTypeAssignableTo(source, self.neverType) or
        kind & TypeFlags.Null ~= 0 and self:isTypeAssignableTo(source, self.nullType) or
        kind & TypeFlags.Undefined ~= 0 and self:isTypeAssignableTo(source, self.undefinedType) or
        kind & TypeFlags.ESSymbol ~= 0 and self:isTypeAssignableTo(source, self.esSymbolType) or
        kind & TypeFlags.NonPrimitive ~= 0 and self:isTypeAssignableTo(source, self.nonPrimitiveType)
end

function checker.isConstEnumObjectType(t)
    return t.objectFlags & ObjectFlags.Anonymous ~= 0 and t.symbol ~= nil and checker.isConstEnumSymbol(t.symbol)
end

function checker.isConstEnumSymbol(symbol)
    return symbol.flags & SymbolFlags.ConstEnum ~= 0
end

function Checker:compareProperties(sourceProp, targetProp, compareTypes)
    -- Two members are considered identical when
    -- - they are public properties with identical names, optionality, and types,
    -- - they are private or protected properties originating in the same declaration and having identical types
    if sourceProp == targetProp then
        return checker.Ternary.True
    end
    local sourcePropAccessibility = checker.getDeclarationModifierFlagsFromSymbol(sourceProp) & ModifierFlags.NonPublicAccessibilityModifier
    local targetPropAccessibility = checker.getDeclarationModifierFlagsFromSymbol(targetProp) & ModifierFlags.NonPublicAccessibilityModifier
    if sourcePropAccessibility ~= targetPropAccessibility then
        return checker.Ternary.False
    end
    if sourcePropAccessibility ~= ModifierFlags.None then
        if self:getTargetSymbol(sourceProp) ~= self:getTargetSymbol(targetProp) then
            return checker.Ternary.False
        end
    else
        if (sourceProp.flags & SymbolFlags.Optional) ~= (targetProp.flags & SymbolFlags.Optional) then
            return checker.Ternary.False
        end
    end
    if self:isReadonlySymbol(sourceProp) ~= self:isReadonlySymbol(targetProp) then
        return checker.Ternary.False
    end
    return compareTypes(self:getNonMissingTypeOfSymbol(sourceProp), self:getNonMissingTypeOfSymbol(targetProp))
end

function checker.compareTypesEqual(s, t)
    if s == t then
        return checker.Ternary.True
    end
    return checker.Ternary.False
end

function Checker:markPropertyAsReferenced(prop, nodeForCheckWriteOnly, isSelfTypeAccess)
    if prop.flags & SymbolFlags.ClassMember == 0 or prop.valueDeclaration == nil then
        return
    end
    local hasPrivateModifier = ast.HasModifier(prop.valueDeclaration, ModifierFlags.Private)
    local hasPrivateIdentifier = prop.valueDeclaration:Name() ~= nil and ast.IsPrivateIdentifier(prop.valueDeclaration:Name())
    if not hasPrivateModifier and not hasPrivateIdentifier then
        return
    end
    if nodeForCheckWriteOnly ~= nil and ast.IsWriteOnlyAccess(nodeForCheckWriteOnly) and prop.flags & SymbolFlags.SetAccessor == 0 then
        return
    end
    if isSelfTypeAccess then
        -- Find any FunctionLikeDeclaration because those create a new 'this' binding. But this should only matter for methods (or getters/setters).
        local containingMethod = ast.FindAncestor(nodeForCheckWriteOnly, ast.IsFunctionLikeDeclaration)
        if containingMethod ~= nil and containingMethod:Symbol() == prop then
            return
        end
    end
    local target = prop
    if prop.checkFlags & CheckFlags.Instantiated ~= 0 then
        target = self.valueSymbolLinks:Get(prop).target
    end
    local links = self.symbolReferenceLinks:Get(target)
    links.referenceKinds = links.referenceKinds | SymbolFlags.All
end

function Checker:expandSignatureParametersWithTupleMembers(signature, restType, restIndex, restSymbol)
    local elementTypes = self:getTypeArguments(restType:AsType())
    local elementInfos = restType:TargetTupleType().elementInfos
    local associatedNames = self:getUniqAssociatedNamesFromTupleType(restType, restSymbol)
    local expanded = core.Slice(signature.parameters, 0, restIndex)
    for i1, t in ipairs(elementTypes) do
        local flags = elementInfos[i1].flags
        local checkFlags = CheckFlags.None
        if flags & ElementFlags.Variable ~= 0 then
            checkFlags = CheckFlags.RestParameter
        elseif flags & ElementFlags.Optional ~= 0 then
            checkFlags = CheckFlags.OptionalParameter
        end
        local symbol = self:newSymbolEx(SymbolFlags.FunctionScopedVariable, associatedNames[i1], checkFlags)
        local links = self.valueSymbolLinks:Get(symbol)
        if flags & ElementFlags.Rest ~= 0 then
            links.resolvedType = self:createArrayType(t)
        else
            links.resolvedType = t
        end
        expanded[#expanded + 1] = symbol
    end
    return expanded
end

function Checker:getUniqAssociatedNamesFromTupleType(t, restSymbol)
    local elementInfos = t:TargetTupleType().elementInfos
    local names = {}
    local counters = {}
    for i1, info in ipairs(elementInfos) do
        local i = i1 - 1
        names[i1] = self:getTupleElementLabel(info, restSymbol, i)
        -- count duplicates using negative values
        counters[names[i1]] = (counters[names[i1]] or 0) - 1
    end
    for i1, name in ipairs(names) do
        if (counters[name] or 0) == -1 then
            goto continue
        end
        while true do
            if (counters[name] or 0) < 0 then
                -- switch to a positive suffix counter
                counters[name] = 0
            end
            counters[name] = (counters[name] or 0) + 1
            local candidateName = name .. "_" .. string.format("%d", counters[name])
            if (counters[candidateName] or 0) == 0 then
                names[i1] = candidateName
                break
            end
        end
        ::continue::
    end
    return names
end

function checker.hasRestParameter(signature)
    local last = core.LastOrNil(signature:Parameters())
    return last ~= nil and checker.isRestParameter(last)
end

function checker.isRestParameter(param)
    return param:AsParameterDeclaration().dotDotDotToken ~= nil
end

function checker.getNameFromIndexInfo(info)
    if info.declaration ~= nil then
        return scanner.DeclarationNameToString(info.declaration:Parameters()[1]:Name())
    end
    return "x"
end

function Checker:isUnknownLikeUnionType(t)
    if self.strictNullChecks and t.flags & TypeFlags.Union ~= 0 then
        if t.objectFlags & checker.ObjectFlagsIsUnknownLikeUnionComputed == 0 then
            t.objectFlags = t.objectFlags | checker.ObjectFlagsIsUnknownLikeUnionComputed
            local types = t:Types()
            if #types >= 3 and types[1].flags & TypeFlags.Undefined ~= 0 and types[2].flags & TypeFlags.Null ~= 0 and core.Some(types, function(x) return self:IsEmptyAnonymousObjectType(x) end) then
                t.objectFlags = t.objectFlags | checker.ObjectFlagsIsUnknownLikeUnion
            end
        end
        return t.objectFlags & checker.ObjectFlagsIsUnknownLikeUnion ~= 0
    end
    return false
end

-- Return true the given type is a primitive union type where no two literal type constituents are
-- comparable. Specifically, that means (a) the union doesn't contain literals from different enum
-- types, and (b) the union doesn't contain both enum literals and string or number literals.
function Checker:isUniformUnionType(t)
    if t.objectFlags & ObjectFlags.PrimitiveUnion ~= 0 then
        if t.objectFlags & checker.ObjectFlagsIsUniformEnumComputed == 0 then
            t.objectFlags = t.objectFlags | checker.ObjectFlagsIsUniformEnumComputed | core.IfElse(self:computeIsUniformUnionType(t:Types()), checker.ObjectFlagsIsUniformEnum, ObjectFlags.None)
        end
        return t.objectFlags & checker.ObjectFlagsIsUniformEnum ~= 0
    end
    return false
end

function Checker:computeIsUniformUnionType(types)
    local enumSymbol = nil
    local hasStringOrNumberLiteral = false
    for _, t in ipairs(types) do
        if t.flags & TypeFlags.EnumLike ~= 0 then
            if hasStringOrNumberLiteral then
                return false
            end
            local parent = self:getParentOfSymbol(t.symbol)
            if enumSymbol == nil then
                enumSymbol = parent
            elseif enumSymbol ~= parent then
                return false
            end
        elseif t.flags & TypeFlags.StringOrNumberLiteral ~= 0 then
            if enumSymbol ~= nil then
                return false
            end
            hasStringOrNumberLiteral = true
        end
    end
    return true
end

function Checker:containsUndefinedType(t)
    if t.flags & TypeFlags.Union ~= 0 then
        t = t:Types()[1]
    end
    return t.flags & TypeFlags.Undefined ~= 0
end

function Checker:typeHasCallOrConstructSignatures(t)
    return t.flags & TypeFlags.StructuredType ~= 0 and core.Len(self:resolveStructuredTypeMembers(t).signatures) ~= 0
end

function Checker:getNormalizedType(t, writing)
    while true do
        local n
        if checker.isFreshLiteralType(t) then
            n = t:AsLiteralType().regularType
        elseif self:isGenericTupleType(t) then
            n = self:getNormalizedTupleType(t, writing)
        elseif t.objectFlags & ObjectFlags.Reference ~= 0 then
            if t:AsTypeReference().node ~= nil then
                n = self:createTypeReference(t:Target(), self:getTypeArguments(t))
            else
                n = self:getSingleBaseForNonAugmentingSubtype(t)
                if n == nil then
                    n = t
                end
            end
        elseif t.flags & TypeFlags.UnionOrIntersection ~= 0 then
            n = self:getNormalizedUnionOrIntersectionType(t, writing)
        elseif t.flags & TypeFlags.Substitution ~= 0 then
            if writing then
                n = t:AsSubstitutionType().baseType
            else
                n = self:getSubstitutionIntersection(t)
            end
        elseif t.flags & TypeFlags.Simplifiable ~= 0 then
            n = self:getSimplifiedType(t, writing)
        else
            return t
        end
        if n == t then
            return n
        end
        t = n
    end
end

function Checker:getSimplifiedType(t, writing)
    if t.flags & TypeFlags.IndexedAccess ~= 0 then
        return self:getSimplifiedIndexedAccessType(t, writing)
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        return self:getSimplifiedConditionalType(t, writing)
    end
    return t
end

-- Transform an indexed access to a simpler form, if possible. Return the simpler form, or return
-- the type itself if no transformation is possible. The writing flag indicates that the type is
-- the target of an assignment.
function Checker:getSimplifiedIndexedAccessType(t, writing)
    local key = checker.CachedTypeKey(core.IfElse(writing, CachedTypeKind.IndexedAccessForWriting, CachedTypeKind.IndexedAccessForReading), t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return core.IfElse(cached == self.circularConstraintType, t, cached)
    end
    self.cachedTypes[key] = t
    local result = self:getSimplifiedIndexedAccessTypeWorker(t, writing)
    if result ~= t then
        -- If the simplification is a union type that includes t, remove t from the type.
        result = self:removeType(result, t)
        self.cachedTypes[key] = result
    end
    return result
end

function Checker:getSimplifiedIndexedAccessTypeWorker(t, writing)
    -- We recursively simplify the object type as it may in turn be an indexed access type. For example, with
    -- '{ [P in T]: { [Q in U]: number } }[T][U]' we want to first simplify the inner indexed access type.
    local objectType = self:getSimplifiedType(t:AsIndexedAccessType().objectType, writing)
    local indexType = self:getSimplifiedType(t:AsIndexedAccessType().indexType, writing)
    -- T[A | B] -> T[A] | T[B] (reading)
    -- T[A | B] -> T[A] & T[B] (writing)
    local distributedOverIndex = self:distributeObjectOverIndexType(objectType, indexType, writing)
    if distributedOverIndex ~= nil then
        return distributedOverIndex
    end
    -- Only do the inner distributions if the index can no longer be instantiated to cause index distribution again
    if indexType.flags & TypeFlags.Instantiable == 0 then
        -- (T | U)[K] -> T[K] | U[K] (reading)
        -- (T | U)[K] -> T[K] & U[K] (writing)
        -- (T & U)[K] -> T[K] & U[K]
        local distributedOverObject = self:distributeIndexOverObjectType(objectType, indexType, writing)
        if distributedOverObject ~= nil then
            return distributedOverObject
        end
    end
    -- So ultimately (reading):
    -- ((A & B) | C)[K1 | K2] -> ((A & B) | C)[K1] | ((A & B) | C)[K2] -> (A & B)[K1] | C[K1] | (A & B)[K2] | C[K2] -> (A[K1] & B[K1]) | C[K1] | (A[K2] & B[K2]) | C[K2]
    -- A generic tuple type indexed by a number exists only when the index type doesn't select a
    -- fixed element. We simplify to either the combined type of all elements (when the index type
    -- the actual number type) or to the combined type of all non-fixed elements.
    if self:isGenericTupleType(objectType) and indexType.flags & TypeFlags.NumberLike ~= 0 then
        local elementType = self:getElementTypeOfSliceOfTupleType(objectType, core.IfElse(indexType.flags & TypeFlags.Number ~= 0, 0, objectType:TargetTupleType().fixedLength), 0 --[[endSkipCount]], writing, false)
        if elementType ~= nil then
            return elementType
        end
    end
    -- If the object type is a mapped type { [P in K]: E }, where K is generic, or { [P in K as N]: E }, where
    -- K is generic and N is assignable to P, instantiate E using a mapper that substitutes the index type for P.
    -- For example, for an index access { [P in K]: Box<T[P]> }[X], we construct the type Box<T[X]>.
    if self:isGenericMappedType(objectType) then
        if self:getMappedTypeNameTypeKind(objectType) ~= checker.MappedTypeNameTypeKind.Remapping then
            return self:mapType(self:substituteIndexedMappedType(objectType, t:AsIndexedAccessType().indexType), function(x)
                return self:getSimplifiedType(x, writing)
            end)
        end
    end
    return t
end

function Checker:distributeObjectOverIndexType(objectType, indexType, writing)
    -- T[A | B] -> T[A] | T[B] (reading)
    -- T[A | B] -> T[A] & T[B] (writing)
    if indexType.flags & TypeFlags.Union ~= 0 then
        local types = core.Map(indexType:Types(), function(t)
            return self:getSimplifiedType(self:getIndexedAccessType(objectType, t), writing)
        end)
        if writing then
            return self:getIntersectionType(types)
        end
        return self:getUnionType(types)
    end
    return nil
end

function Checker:distributeIndexOverObjectType(objectType, indexType, writing)
    -- (T | U)[K] -> T[K] | U[K] (reading)
    -- (T | U)[K] -> T[K] & U[K] (writing)
    -- (T & U)[K] -> T[K] & U[K]
    if objectType.flags & TypeFlags.Union ~= 0 or objectType.flags & TypeFlags.Intersection ~= 0 and not self:shouldDeferIndexType(objectType, IndexFlags.None) then
        local types = core.Map(objectType:Types(), function(t)
            return self:getSimplifiedType(self:getIndexedAccessType(t, indexType), writing)
        end)
        if objectType.flags & TypeFlags.Intersection ~= 0 or writing then
            return self:getIntersectionType(types)
        end
        return self:getUnionType(types)
    end
    return nil
end

function Checker:getSimplifiedConditionalType(t, writing)
    local checkType = t:AsConditionalType().checkType
    local extendsType = t:AsConditionalType().extendsType
    local trueType = self:getTrueTypeFromConditionalType(t)
    local falseType = self:getFalseTypeFromConditionalType(t)
    -- Simplifications for types of the form `T extends U ? T : never` and `T extends U ? never : T`.
    if falseType.flags & TypeFlags.Never ~= 0 and self:getActualTypeVariable(trueType) == self:getActualTypeVariable(checkType) then
        if checkType.flags & TypeFlags.Any ~= 0 or self:isTypeAssignableTo(self:getRestrictiveInstantiation(checkType), self:getRestrictiveInstantiation(extendsType)) then
            return self:getSimplifiedType(trueType, writing)
        elseif self:isIntersectionEmpty(checkType, extendsType) then
            return self.neverType
        end
    elseif trueType.flags & TypeFlags.Never ~= 0 and self:getActualTypeVariable(falseType) == self:getActualTypeVariable(checkType) then
        if checkType.flags & TypeFlags.Any == 0 and self:isTypeAssignableTo(self:getRestrictiveInstantiation(checkType), self:getRestrictiveInstantiation(extendsType)) then
            return self.neverType
        elseif checkType.flags & TypeFlags.Any ~= 0 or self:isIntersectionEmpty(checkType, extendsType) then
            return self:getSimplifiedType(falseType, writing)
        end
    end
    return t
end

-- Invokes union simplification logic to determine if an intersection is considered empty as a union constituent
function Checker:isIntersectionEmpty(type1, type2)
    return self:getUnionType({ self:intersectTypes(type1, type2), self.neverType }).flags & TypeFlags.Never ~= 0
end

function Checker:getSimplifiedTypeOrConstraint(t)
    local simplified = self:getSimplifiedType(t, false --[[writing]])
    if simplified ~= t then
        return simplified
    end
    return self:getConstraintOfType(t)
end

function Checker:getNormalizedUnionOrIntersectionType(t, writing)
    local reduced = self:getReducedType(t)
    if reduced ~= t then
        return reduced
    end
    if t.flags & TypeFlags.Intersection ~= 0 and self:shouldNormalizeIntersection(t) then
        -- Normalization handles cases like
        -- Partial<T>[K] & ({} | null) ==>
        -- Partial<T>[K] & {} | Partial<T>[K} & null ==>
        -- (T[K] | undefined) & {} | (T[K] | undefined) & null ==>
        -- T[K] & {} | undefined & {} | T[K] & null | undefined & null ==>
        -- T[K] & {} | T[K] & null
        local types = t:Types()
        local normalizedTypes = core.SameMap(types, function(u) return self:getNormalizedType(u, writing) end)
        if not core.Same(normalizedTypes, types) then
            return self:getIntersectionType(normalizedTypes)
        end
    end
    return t
end

function Checker:shouldNormalizeIntersection(t)
    local hasInstantiable = false
    local hasNullableOrEmpty = false
    for _, u in ipairs(t:Types()) do
        hasInstantiable = hasInstantiable or u.flags & TypeFlags.Instantiable ~= 0
        hasNullableOrEmpty = hasNullableOrEmpty or u.flags & TypeFlags.Nullable ~= 0 or self:IsEmptyAnonymousObjectType(u)
        if hasInstantiable and hasNullableOrEmpty then
            return true
        end
    end
    return false
end

function Checker:getNormalizedTupleType(t, writing)
    local elements = self:getElementTypes(t)
    local normalizedElements = core.SameMap(elements, function(e)
        if e.flags & TypeFlags.Simplifiable ~= 0 then
            return self:getSimplifiedType(e, writing)
        end
        return e
    end)
    if not core.Same(elements, normalizedElements) then
        return self:createNormalizedTupleType(t:Target(), normalizedElements)
    end
    return t
end

function Checker:getSingleBaseForNonAugmentingSubtype(t)
    if t.objectFlags & ObjectFlags.Reference == 0 or t:Target().objectFlags & ObjectFlags.ClassOrInterface == 0 then
        return nil
    end
    local key = checker.CachedTypeKey(CachedTypeKind.EquivalentBaseType, t.id)
    if t.objectFlags & checker.ObjectFlagsIdenticalBaseTypeCalculated ~= 0 then
        return self.cachedTypes[key]
    end
    t.objectFlags = t.objectFlags | checker.ObjectFlagsIdenticalBaseTypeCalculated
    local target = t:Target()
    if target.objectFlags & ObjectFlags.Class ~= 0 then
        local baseTypeNode = checker.getBaseTypeNodeOfClass(target)
        -- A base type expression may circularly reference the class itself (e.g. as an argument to function call), so we only
        -- check for base types specified as simple qualified names.
        if baseTypeNode ~= nil and not ast.IsIdentifier(baseTypeNode:Expression()) and not ast.IsPropertyAccessExpression(baseTypeNode:Expression()) then
            return nil
        end
    end
    local bases = self:getBaseTypes(target)
    if core.Len(bases) ~= 1 then
        return nil
    end
    if next(self:getMembersOfSymbol(t.symbol) or {}) ~= nil then
        -- If the interface has any members, they may subtype members in the base, so we should do a full structural comparison
        return nil
    end
    local instantiatedBase
    local typeParameters = target:AsInterfaceType():TypeParameters()
    if core.Len(typeParameters) == 0 then
        instantiatedBase = bases[1]
    else
        instantiatedBase = self:instantiateType(bases[1], checker.newTypeMapper(typeParameters, core.Slice(self:getTypeArguments(t), 0, #typeParameters)))
    end
    if core.Len(self:getTypeArguments(t)) > core.Len(typeParameters) then
        instantiatedBase = self:getTypeWithThisArgument(instantiatedBase, core.LastOrNil(self:getTypeArguments(t)), false)
    end
    self.cachedTypes[key] = instantiatedBase
    return instantiatedBase
end

function Checker:getModifiersTypeFromMappedType(t)
    local m = t:AsMappedType()
    if m.modifiersType == nil then
        if self:isMappedTypeWithKeyofConstraintDeclaration(t) then
            -- If the constraint declaration is a 'keyof T' node, the modifiers type is T. We check
            -- AST nodes here because, when T is a non-generic type, the logic below eagerly resolves
            -- 'keyof T' to a literal union type and we can't recover T from that type.
            m.modifiersType = self:instantiateType(self:getTypeFromTypeNode(self:getConstraintDeclarationForMappedType(t):Type()), m.mapper)
        else
            -- Otherwise, get the declared constraint type, and if the constraint type is a type parameter,
            -- get the constraint of that type parameter. If the resulting type is an indexed type 'keyof T',
            -- the modifiers type is T. Otherwise, the modifiers type is unknown.
            local declaredType = self:getTypeFromMappedTypeNode(m.declaration:AsNode())
            local constraint = self:getConstraintTypeFromMappedType(declaredType)
            local extendedConstraint = constraint
            if constraint ~= nil and constraint.flags & TypeFlags.TypeParameter ~= 0 then
                extendedConstraint = self:getConstraintOfTypeParameter(constraint)
            end
            if extendedConstraint ~= nil and extendedConstraint.flags & TypeFlags.Index ~= 0 then
                m.modifiersType = self:instantiateType(extendedConstraint:AsIndexType().target, m.mapper)
            else
                m.modifiersType = self.unknownType
            end
        end
    end
    return m.modifiersType
end

function Checker:extractTypesOfKind(t, kind)
    return self:filterType(t, function(x) return x.flags & kind ~= 0 end)
end

function Checker:getRegularTypeOfObjectLiteral(t)
    if not (checker.isObjectLiteralType(t) and t.objectFlags & ObjectFlags.FreshLiteral ~= 0) then
        return t
    end
    local key = checker.CachedTypeKey(CachedTypeKind.RegularObjectLiteral, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local resolved = self:resolveStructuredTypeMembers(t)
    local members = self:transformTypeOfMembers(t, function(x) return self:getRegularTypeOfObjectLiteral(x) end)
    local regular = self:newAnonymousType(t.symbol, members, resolved:CallSignatures(), resolved:ConstructSignatures(), resolved.indexInfos)
    regular.flags = resolved.flags
    regular.objectFlags = regular.objectFlags | (resolved.objectFlags & ~ObjectFlags.FreshLiteral)
    self.cachedTypes[key] = regular
    return regular
end

function Checker:transformTypeOfMembers(t, f)
    local members = ast.NewSymbolTable()
    for _, property in ipairs(self:getPropertiesOfObjectType(t) or {}) do
        local original = self:getTypeOfSymbol(property)
        local updated = f(original)
        if updated ~= original then
            property = self:createSymbolWithType(property, updated)
        end
        members[property.name] = property
    end
    return members
end

function Checker:markLinkedReferences(location, hint, propSymbol, parentType)
    if not self.canCollectSymbolAliasAccessibilityData then
        return
    end
    if location.flags & NodeFlags.Ambient ~= 0 and not ast.IsPropertySignatureDeclaration(location) and not ast.IsPropertyDeclaration(location) then
        -- References within types and declaration files are never going to contribute to retaining a JS import,
        -- except for properties (which can be decorated).
        return
    end
    local ReferenceHint = checker.ReferenceHint
    if hint == ReferenceHint.Identifier then
        self:markIdentifierAliasReferenced(location)
    elseif hint == ReferenceHint.Property then
        self:markPropertyAliasReferenced(location, propSymbol, parentType)
    elseif hint == ReferenceHint.ExportAssignment then
        self:markExportAssignmentAliasReferenced(location)
    elseif hint == ReferenceHint.Jsx then
        self:markJsxAliasReferenced(location)
    elseif hint == ReferenceHint.ExportImportEquals then
        self:markImportEqualsAliasReferenced(location)
    elseif hint == ReferenceHint.ExportSpecifier then
        self:markExportSpecifierAliasReferenced(location)
    elseif hint == ReferenceHint.Decorator then
        self:markDecoratorAliasReferenced(location)
    elseif hint == ReferenceHint.Unspecified then
        if location.flags & NodeFlags.InWithStatement ~= 0 then
            -- We cannot answer semantic questions within a with block, do not proceed any further
            return
        end
        if ast.IsJsxTagName(location) and checker.isJsxIntrinsicTagName(location) then
            return -- builtin JSX tag names aren't real type refs by most metrics, but are expressions, so must be filtered
        end
        if ast.IsIdentifier(location) then
            -- A shorthand property with an object-assignment-initializer (e.g. `{ s = 5 }`) is only valid inside a
            -- destructuring assignment target. When it appears in an ordinary object literal expression, the checker
            -- checks the initializer and never resolves the property name, so resolving it here would report a spurious
            -- "No value exists in scope for the shorthand property" diagnostic. Skip such names to match checking.
            local parent = location.parent
            if ast.IsShorthandPropertyAssignment(parent) and
                parent:Name() == location and
                parent:AsShorthandPropertyAssignment().objectAssignmentInitializer ~= nil and
                not ast.IsAssignmentTarget(parent.parent) then
                return
            end
            local res = ast.FindManyAncestors(location, ast.IsMetaProperty, ast.IsDecorator, ast.IsForInOrOfStatement, ast.IsComputedPropertyName, ast.IsHeritageClause)
            local metaProperty = res[1]
            local decorator = res[2]
            local forNode = res[3]
            local computedName = res[4]
            local heritageClause = res[5]
            if metaProperty ~= nil then
                return -- identifiers in meta properties shouldn't be resolved, but are expressions, so must be filtered
            end
            if decorator ~= nil then
                -- Decorators on nodes that cannot be decorated (e.g. class expressions, static blocks,
                -- `this` parameters) are never resolved during normal checking, so resolving them here would
                -- report spurious diagnostics. Only bail out for such invalid-position decorators; valid
                -- decorator expressions must still be resolved and marked for emit.
                local decorated = decorator.parent
                if decorated ~= nil and not ast.NodeCanBeDecorated(self.legacyDecorators, decorated, decorated.parent, decorated.parent.parent) then
                    return
                end
            end
            -- The right-hand side of a 'for-in'/'for-of' statement whose initializer is an empty variable
            -- declaration list (a grammar error, e.g. `for (var of X)`) is never checked, because the RHS
            -- is only checked while inferring the type of a variable declaration and there is none here.
            -- Resolving identifiers in the RHS here would report spurious diagnostics.
            if forNode ~= nil then
                local data = forNode:AsForInOrOfStatement()
                if ast.IsVariableDeclarationList(data.initializer) and
                    #data.initializer:AsVariableDeclarationList().declarations.nodes == 0 and
                    data.expression ~= nil and
                    (location == data.expression or ast.IsNodeDescendantOf(location, data.expression)) then
                    return
                end
            end
            -- Computed property names on enum members are a grammar error and are never checked
            -- (checkEnumMember only checks the member initializer, not the name), so resolving
            -- identifiers in them here would report a spurious "Cannot find name" diagnostic.
            if computedName ~= nil then
                if ast.IsEnumMember(computedName.parent) then
                    return
                end
                if checker.isInvalidComputedPropertyName(computedName) then
                    return
                end
            end
            if heritageClause ~= nil then
                -- extends heritage clauses on interfaces are not expressions and are unchecked if they are
                if ast.IsInterfaceDeclaration(heritageClause.parent) then
                    return
                end
                -- On a class, only the first `extends` type is resolved as a value (the base class); any
                -- additional `extends` types are grammar errors (e.g. `class C extends A extends B` or
                -- `class C extends A, B`) and are never resolved during checking.
                if ast.IsClassLike(heritageClause.parent) and
                    heritageClause:AsHeritageClause().token == Kind.ExtendsKeyword then
                    local firstExtends = ast.GetClassExtendsHeritageElement(heritageClause.parent)
                    if firstExtends ~= nil and
                        location ~= firstExtends and not ast.IsNodeDescendantOf(location, firstExtends) then
                        return
                    end
                end
            end
            -- Identifiers in expression contexts are emitted, so we need to follow their referenced aliases and mark them as used
            -- Some non-expression identifiers are also treated as expression identifiers for this purpose, eg, `a` in `b = {a}` or `q` in `import r = q`
            -- This is the exception, rather than the rule - most non-expression identifiers are declaration names.
            if (ast.IsExpressionNode(location) or
                    ast.IsShorthandPropertyAssignment(location.parent)) and
                checker.shouldMarkIdentifierAliasReferenced(location) then
                if ast.IsPropertyAccessOrQualifiedName(location.parent) then
                    local left
                    if ast.IsPropertyAccessExpression(location.parent) then
                        left = location.parent:Expression()
                    else
                        left = location.parent:AsQualifiedName().left
                    end
                    if left ~= location then
                        return -- Only mark the LHS (the RHS is a property lookup)
                    end
                end
                self:markIdentifierAliasReferenced(location)
                return
            end
        end
        if ast.IsPropertyAccessOrQualifiedName(location) then
            local topProp = location
            while ast.IsPropertyAccessOrQualifiedName(topProp) do
                if ast.IsPartOfTypeNode(topProp) then
                    return
                end
                topProp = topProp.parent
            end
            self:markPropertyAliasReferenced(location, nil --[[propSymbol]], nil --[[parentType]])
            return
        end
        if ast.IsExportAssignment(location) then
            self:markExportAssignmentAliasReferenced(location)
            return
        end
        if ast.IsJsxOpeningLikeElement(location) or ast.IsJsxOpeningFragment(location) then
            self:markJsxAliasReferenced(location)
            return
        end
        if ast.IsImportEqualsDeclaration(location) then
            if checker.isInternalModuleImportEqualsDeclaration(location) or self:checkExternalImportOrExportDeclaration(location) then
                self:markImportEqualsAliasReferenced(location)
                return
            end
            return
        end
        if ast.IsExportSpecifier(location) then
            self:markExportSpecifierAliasReferenced(location)
            return
        end
        if not core.Tristate_IsTrue(self.compilerOptions.emitDecoratorMetadata) then
            return
        end
        if not ast.CanHaveDecorators(location) or not ast.HasDecorators(location) or location:Modifiers() == nil or not ast.NodeCanBeDecorated(self.legacyDecorators, location, location.parent, location.parent.parent) then
            return
        end

        self:markDecoratorAliasReferenced(location)
        return
    else
        error("Unhandled reference hint", 0)
    end
end

function checker.isExportOrExportExpression(location)
    return ast.FindAncestor(location, function(n)
        local parent = n.parent
        if parent ~= nil then
            if ast.IsAnyExportAssignment(parent) then
                return parent:Expression() == n and ast.IsEntityNameExpression(n)
            end
            if ast.IsExportSpecifier(parent) then
                return parent:AsExportSpecifier():Name() == n or parent:PropertyName() == n
            end
        end
        return false
    end) ~= nil
end

function checker.shouldMarkIdentifierAliasReferenced(node)
    local parent = node.parent
    if parent ~= nil then
        -- A property access expression LHS? checkPropertyAccessExpression will handle that.
        if ast.IsPropertyAccessExpression(parent) and parent:Expression() == node then
            return false
        end
        -- Next two check for an identifier inside a type only export.
        if ast.IsExportSpecifier(parent) and parent:IsTypeOnly() then
            return false
        end
        if parent.parent ~= nil then
            local greatGrandparent = parent.parent.parent
            if greatGrandparent ~= nil and ast.IsExportDeclaration(greatGrandparent) and greatGrandparent:IsTypeOnly() then
                return false
            end
        end
    end
    return true
end

function checker.isInternalModuleImportEqualsDeclaration(node)
    return node.kind == Kind.ImportEqualsDeclaration and
        node:AsImportEqualsDeclaration().moduleReference.kind ~= Kind.ExternalModuleReference
end

function Checker:markIdentifierAliasReferenced(location)
    if ast.IsThisInTypeQuery(location) then
        return
    end
    local symbol = self:getResolvedSymbol(location)
    if symbol ~= nil and symbol ~= self.argumentsSymbol and symbol ~= self.unknownSymbol then
        self:markAliasReferenced(symbol, location)
    end
end

function Checker:markPropertyAliasReferenced(location --[[PropertyAccessExpression | QualifiedName]], propSymbol, parentType)
    if checker.isPartOfImportEqualsModuleReference(location) then
        return
    end
    local left
    if ast.IsPropertyAccessExpression(location) then
        left = location:Expression()
    else
        left = location:AsQualifiedName().left
    end
    if ast.IsThisIdentifier(left) or not ast.IsIdentifier(left) then
        return
    end
    local parentSymbol = self:getResolvedSymbol(left)
    if parentSymbol == nil or parentSymbol == self.unknownSymbol then
        return
    end
    -- In `Foo.Bar.Baz`, 'Foo' is not referenced if 'Bar' is a const enum or a module containing only const enums.
    -- `Foo` is also not referenced in `enum FooCopy { Bar = Foo.Bar }`, because the enum member value gets inlined
    -- here even if `Foo` is not a const enum.
    --
    -- The exceptions are:
    --   1. if 'isolatedModules' is enabled, because the const enum value will not be inlined, and
    --   2. if 'preserveConstEnums' is enabled and the expression is itself an export, e.g. `export = Foo.Bar.Baz`.
    --
    -- The property lookup is deferred as much as possible, in as many situations as possible, to avoid alias marking
    -- pulling on types/symbols it doesn't strictly need to.
    if self.compilerOptions:GetIsolatedModules() or (self.compilerOptions:ShouldPreserveConstEnums() and checker.isExportOrExportExpression(location)) then
        self:markAliasReferenced(parentSymbol, location)
        return
    end
    -- Hereafter, this relies on type checking - but every check prior to this only used symbol information
    local leftType = parentType
    if leftType == nil then
        leftType = self:checkExpressionCached(left)
    end
    if checker.IsTypeAny(leftType) or leftType == self.silentNeverType then
        self:markAliasReferenced(parentSymbol, location)
        return
    end
    local prop = propSymbol
    if prop == nil and parentType == nil then
        local right
        if ast.IsPropertyAccessExpression(location) then
            right = location:AsPropertyAccessExpression():Name()
        else
            right = location:AsQualifiedName().right
        end
        local lexicallyScopedSymbol = nil
        if ast.IsPrivateIdentifier(right) then
            lexicallyScopedSymbol = self:lookupSymbolForPrivateIdentifierDeclaration(right:Text(), right)
        end
        local assignmentKind = checker.getAssignmentTargetKind(location)
        local apparentType
        if assignmentKind ~= checker.AssignmentKind.None or self:isMethodAccessForCall(location) then
            apparentType = self:getApparentType(self:getWidenedType(leftType))
        else
            apparentType = self:getApparentType(leftType)
        end
        if ast.IsPrivateIdentifier(right) then
            if lexicallyScopedSymbol ~= nil then
                prop = self:getPrivateIdentifierPropertyOfType(apparentType, lexicallyScopedSymbol)
            end
        else
            prop = self:getPropertyOfType(apparentType, right:Text())
        end
    end
    if not (prop ~= nil and (checker.isConstEnumOrConstEnumOnlyModule(prop) or prop.flags & SymbolFlags.EnumMember ~= 0 and location.parent.kind == Kind.EnumMember)) then
        self:markAliasReferenced(parentSymbol, location)
    end
end

function checker.isPartOfImportEqualsModuleReference(location)
    local importEquals = ast.FindAncestorKind(location, Kind.ImportEqualsDeclaration)
    if importEquals == nil then
        return false
    end
    local node = location
    while node ~= nil and node ~= importEquals do
        if node == importEquals:AsImportEqualsDeclaration().moduleReference then
            return true
        end
        node = node.parent
    end
    return false
end

function Checker:markExportAssignmentAliasReferenced(location --[[ExportAssignment]])
    local id = location:Expression()
    if ast.IsIdentifier(id) then
        local sym = self:getExportSymbolOfValueSymbolIfExported(self:resolveEntityName(id, SymbolFlags.All, true --[[ignoreErrors]], true --[[dontResolveAlias]], location))
        if sym ~= nil then
            self:markAliasReferenced(sym, id)
        end
    end
end

function Checker:markJsxAliasReferenced(node --[[JsxOpeningLikeElement | JsxOpeningFragment]])
    if self:getJsxNamespaceContainerForImplicitImport(node) ~= nil then
        return
    end
    -- The reactNamespace/jsxFactory's root symbol should be marked as 'used' so we don't incorrectly elide its import.
    -- And if there is no reactNamespace/jsxFactory's symbol in scope when targeting React emit, we should issue an error.
    local jsxFactoryRefErr = core.IfElse(self.compilerOptions.jsx == core.JsxEmit.React, diagnostics.This_JSX_tag_requires_0_to_be_in_scope_but_it_could_not_be_found, nil)
    local jsxFactoryNamespace = self:getJsxNamespace(node)
    local jsxFactoryLocation = node
    if ast.IsJsxOpeningLikeElement(node) then
        jsxFactoryLocation = node:TagName()
    end
    local shouldFactoryRefErr = self.compilerOptions.jsx ~= core.JsxEmit.Preserve and self.compilerOptions.jsx ~= core.JsxEmit.ReactNative
    -- #38720/60122, allow null as jsxFragmentFactory
    local jsxFactorySym = nil
    if not (ast.IsJsxOpeningFragment(node) and jsxFactoryNamespace == "null") then
        local flags = SymbolFlags.Value
        if not shouldFactoryRefErr then
            flags = flags & ~SymbolFlags.Enum
        end
        jsxFactorySym = self.resolveName(jsxFactoryLocation, jsxFactoryNamespace, flags, jsxFactoryRefErr, true --[[isUse]], false --[[excludeGlobals]])
    end
    if jsxFactorySym ~= nil then
        -- Mark local symbol as referenced here because it might not have been marked
        -- if jsx emit was not jsxFactory as there wont be error being emitted
        self:symbolReferenced(jsxFactorySym, SymbolFlags.All)
        -- If react/jsxFactory symbol is alias, mark it as referenced
        if self.canCollectSymbolAliasAccessibilityData and jsxFactorySym.flags & SymbolFlags.Alias ~= 0 and self:getTypeOnlyAliasDeclaration(jsxFactorySym) == nil then
            self:markAliasSymbolAsReferenced(jsxFactorySym)
        end
    end
    -- if JsxFragment, additionally mark jsx pragma as referenced, since `getJsxNamespace` above would have resolved to only the fragment factory if they are distinct
    if ast.IsJsxOpeningFragment(node) then
        local file = ast.GetSourceFileOfNode(node)
        local entity = self:getJsxFactoryEntity(file:AsNode())
        if entity ~= nil then
            local localJsxNamespace = ast.GetFirstIdentifier(entity):Text()
            local flags = SymbolFlags.Value
            if not shouldFactoryRefErr then
                flags = flags & ~SymbolFlags.Enum
            end
            self.resolveName(jsxFactoryLocation, localJsxNamespace, flags, jsxFactoryRefErr, true --[[isUse]], false --[[excludeGlobals]])
        end
    end
end

function Checker:markImportEqualsAliasReferenced(location --[[ImportEqualsDeclaration]])
    if ast.HasSyntacticModifier(location, ModifierFlags.Export) then
        self:markExportAsReferenced(location)
    end
end

function Checker:markExportSpecifierAliasReferenced(location)
    if location.parent.parent:ModuleSpecifier() == nil and not location:IsTypeOnly() and not location.parent.parent:IsTypeOnly() then
        local exportedName = location:PropertyNameOrName()
        if exportedName.kind == Kind.StringLiteral then
            return -- Skip for invalid syntax like this: export { "x" }
        end
        local symbol = self.resolveName(exportedName, exportedName:Text(), SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]])
        if symbol ~= nil and (symbol == self.undefinedSymbol or symbol == self.globalThisSymbol or symbol.declarations ~= nil and ast.IsGlobalSourceFile(ast.GetDeclarationContainer(symbol.declarations[1]))) then -- luacheck: ignore 542
            -- Do nothing, non-local symbol
        else
            local target = symbol
            if target ~= nil and target.flags & SymbolFlags.Alias ~= 0 then
                target = self:resolveAlias(target)
            end
            if target == nil or self:getSymbolFlags(target) & SymbolFlags.Value ~= 0 then
                self:markExportAsReferenced(location) -- marks export as used
                self:markIdentifierAliasReferenced(exportedName) -- marks target of export as used
            end
        end
    end
end
