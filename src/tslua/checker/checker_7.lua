local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local debug = require("tslua.debug")
local evaluator = require("tslua.evaluator")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local IndexFlags = checker.IndexFlags
local AccessFlags = checker.AccessFlags
local UnionReduction = checker.UnionReduction
local IntersectionFlags = checker.IntersectionFlags
local CachedTypeKind = checker.CachedTypeKind
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local MappedTypeModifiers = checker.MappedTypeModifiers
local MappedTypeNameTypeKind = checker.MappedTypeNameTypeKind
local TypeFormatFlags = checker.TypeFormatFlags
local Ternary = checker.Ternary
local SignatureFlags = checker.SignatureFlags
local TypeMapperKind = checker.TypeMapperKind
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local Kind = ast.Kind
local FindAncestorResult = ast.FindAncestorResult

-- Go slices.Repeat([]*Type{t}, n).
local function repeatValue(v, n)
    local result = {}
    for i = 1, n do
        result[i] = v
    end
    return result
end

-- Go slices.Contains.
local function contains(xs, x)
    if xs ~= nil then
        for _, v in ipairs(xs) do
            if v == x then
                return true
            end
        end
    end
    return false
end

-- Go slices.Index (0-based, -1 if absent).
local function indexOf(xs, x)
    if xs ~= nil then
        for i, v in ipairs(xs) do
            if v == x then
                return i - 1
            end
        end
    end
    return -1
end

-- Return the symbol for a given property in a union or intersection type, or undefined if the property
-- does not exist in any constituent type. Note that the returned property may only be present in some
-- constituents, in which case the isPartial flag is set when the containing type is union type. We need
-- these partial properties when identifying discriminant properties, but otherwise they are filtered out
-- and do not appear to be present in the union type.
function Checker:getUnionOrIntersectionProperty(t, name, skipObjectFunctionPropertyAugment)
    local cache
    if skipObjectFunctionPropertyAugment then
        cache = ast.GetSymbolTable(t:AsUnionOrIntersectionType(), "propertyCacheWithoutFunctionPropertyAugment")
    else
        cache = ast.GetSymbolTable(t:AsUnionOrIntersectionType(), "propertyCache")
    end
    local cached = cache[name]
    if cached ~= nil then
        return cached
    end
    local prop = self:createUnionOrIntersectionProperty(t, name, skipObjectFunctionPropertyAugment)
    if prop ~= nil then
        cache[name] = prop
        -- Propagate an entry from the non-augmented cache to the augmented cache unless the property is partial.
        if skipObjectFunctionPropertyAugment and prop.checkFlags & CheckFlags.Partial == 0 then
            local augmentedCache = ast.GetSymbolTable(t:AsUnionOrIntersectionType(), "propertyCache")
            if augmentedCache[name] == nil then
                augmentedCache[name] = prop
            end
        end
    end
    return prop
end

function Checker:createUnionOrIntersectionProperty(containingType, name, skipObjectFunctionPropertyAugment)
    local propFlags = SymbolFlags.None
    local singleProp = nil
    local propSet = collections.NewOrderedSet()
    local indexTypes = nil
    local isUnion = containingType.flags & TypeFlags.Union ~= 0
    -- Flags we want to propagate to the result if they exist in all source symbols
    local checkFlags = 0
    local optionalFlag = 0
    if not isUnion then
        checkFlags = CheckFlags.Readonly
        optionalFlag = SymbolFlags.Optional
    end
    local syntheticFlag = CheckFlags.SyntheticMethod
    local mergedInstantiations = false
    for _, current in ipairs(containingType:Types() or {}) do
        local t = self:getApparentType(current)
        if not self:isErrorType(t) and t.flags & TypeFlags.Never == 0 then
            local prop = self:getPropertyOfTypeEx(t, name, skipObjectFunctionPropertyAugment, false)
            local modifiers = 0
            if prop ~= nil then
                modifiers = checker.getDeclarationModifierFlagsFromSymbol(prop)
                if prop.flags & SymbolFlags.ClassMember ~= 0 then
                    if isUnion then
                        optionalFlag = optionalFlag | (prop.flags & SymbolFlags.Optional)
                    else
                        optionalFlag = optionalFlag & prop.flags
                    end
                end
                if singleProp == nil then
                    singleProp = prop
                    propFlags = core.OrElse(prop.flags & SymbolFlags.Accessor, SymbolFlags.Property)
                elseif prop ~= singleProp then
                    local isInstantiation = self:getTargetSymbol(prop) == self:getTargetSymbol(singleProp)
                    -- If the symbols are instances of one another with identical types - consider the symbols
                    -- equivalent and just use the first one, which thus allows us to avoid eliding private
                    -- members when intersecting a (this-)instantiations of a class with its raw base or another instance
                    if isInstantiation and self:compareProperties(singleProp, prop, checker.compareTypesEqual) == Ternary.True then
                        -- If we merged instantiations of a generic type, we replicate the symbol parent resetting behavior we used
                        -- to do when we recorded multiple distinct symbols so that we still get, eg, `Array<T>.length` printed
                        -- back and not `Array<string>.length` when we're looking at a `.length` access on a `string[] | number[]`
                        mergedInstantiations = singleProp.parent ~= nil and core.Len(self:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(singleProp.parent)) ~= 0
                    else
                        if propSet:Size() == 0 then
                            propSet:Add(singleProp)
                        end
                        propSet:Add(prop)
                    end
                    -- classes created by mixins are represented as intersections
                    -- and overriding a property in a derived class redefines it completely at runtime
                    -- so a get accessor can't be merged with a set accessor in a base class,
                    -- for that reason the accessor flags are only used when they are the same in all constituents
                    if propFlags & SymbolFlags.Accessor ~= 0 and (prop.flags & SymbolFlags.Accessor ~= (propFlags & SymbolFlags.Accessor)) then
                        propFlags = (propFlags & ~SymbolFlags.Accessor) | SymbolFlags.Property
                    end
                end
                if isUnion and self:isReadonlySymbol(prop) then
                    checkFlags = checkFlags | CheckFlags.Readonly
                elseif not isUnion and not self:isReadonlySymbol(prop) then
                    checkFlags = checkFlags & ~CheckFlags.Readonly
                end
                if modifiers & ModifierFlags.NonPublicAccessibilityModifier == 0 then
                    checkFlags = checkFlags | CheckFlags.ContainsPublic
                end
                if modifiers & ModifierFlags.Protected ~= 0 then
                    checkFlags = checkFlags | CheckFlags.ContainsProtected
                end
                if modifiers & ModifierFlags.Private ~= 0 then
                    checkFlags = checkFlags | CheckFlags.ContainsPrivate
                end
                if modifiers & ModifierFlags.Static ~= 0 then
                    checkFlags = checkFlags | CheckFlags.ContainsStatic
                end
                if not checker.isPrototypeProperty(prop) then
                    syntheticFlag = CheckFlags.SyntheticProperty
                end
            elseif isUnion then
                local indexInfo = nil
                if not checker.isLateBoundName(name) then
                    indexInfo = self:getApplicableIndexInfoForName(t, name)
                end
                if indexInfo ~= nil then
                    propFlags = propFlags & ~SymbolFlags.Accessor | SymbolFlags.Property
                    checkFlags = checkFlags | CheckFlags.WritePartial | core.IfElse(indexInfo.isReadonly, CheckFlags.Readonly, 0)
                    if checker.isTupleType(t) then
                        local indexType = self:getRestTypeOfTupleType(t)
                        if indexType == nil then
                            indexType = self.undefinedType
                        end
                        indexTypes = core.Append(indexTypes, indexType)
                    else
                        indexTypes = core.Append(indexTypes, indexInfo.valueType)
                    end
                elseif checker.isObjectLiteralType(t) and t.objectFlags & checker.ObjectFlagsContainsSpread == 0 then
                    checkFlags = checkFlags | CheckFlags.WritePartial
                    indexTypes = core.Append(indexTypes, self.undefinedType)
                else
                    checkFlags = checkFlags | CheckFlags.ReadPartial
                end
            end
        end
    end
    if singleProp == nil or isUnion and
        (propSet:Size() ~= 0 or checkFlags & CheckFlags.Partial ~= 0) and
        checkFlags & (CheckFlags.ContainsPrivate | CheckFlags.ContainsProtected) ~= 0 and
        not (propSet:Size() ~= 0 and self:hasCommonDeclaration(propSet)) then
        -- No property was found, or, in a union, a property has a private or protected declaration in one
        -- constituent, but is missing or has a different declaration in another constituent.
        return nil
    end
    if propSet:Size() == 0 and checkFlags & CheckFlags.ReadPartial == 0 and core.Len(indexTypes) == 0 then
        if not mergedInstantiations then
            return singleProp
        end
        -- No symbol from a union/intersection should have a `.parent` set (since unions/intersections don't act as symbol parents)
        -- Unless that parent is "reconstituted" from the "first value declaration" on the symbol (which is likely different than its instantiated parent!)
        -- They also have a `.containingType` set, which affects some services endpoints behavior, like `getRootSymbol`
        local singlePropType = nil
        local singlePropMapper = nil
        if singleProp.flags & SymbolFlags.Transient ~= 0 then
            local links = self.valueSymbolLinks:Get(singleProp)
            singlePropType = links.resolvedType
            singlePropMapper = links.mapper
        end
        local clone = self:createSymbolWithType(singleProp, singlePropType)
        if singleProp.valueDeclaration ~= nil then
            clone.parent = singleProp.valueDeclaration:Symbol().parent
        end
        local links = self.valueSymbolLinks:Get(clone)
        links.containingType = containingType
        links.mapper = singlePropMapper
        links.writeType = self:getWriteTypeOfSymbol(singleProp)
        return clone
    end
    if propSet:Size() == 0 then
        propSet:Add(singleProp)
    end
    local declarations = nil
    local firstType = nil
    local nameType = nil
    local propTypes = nil
    local writeTypes = nil
    local firstValueDeclaration = nil
    local hasNonUniformValueDeclaration = false
    for prop in propSet:Values() do
        if firstValueDeclaration == nil then
            firstValueDeclaration = prop.valueDeclaration
        elseif prop.valueDeclaration ~= nil and prop.valueDeclaration ~= firstValueDeclaration then
            hasNonUniformValueDeclaration = true
        end
        declarations = core.AppendAll(declarations, prop.declarations)
        local t = self:getTypeOfSymbol(prop)
        if firstType == nil then
            firstType = t
            nameType = self.valueSymbolLinks:Get(prop).nameType
        end
        local writeType = self:getWriteTypeOfSymbol(prop)
        if writeTypes ~= nil or writeType ~= t then
            if writeTypes == nil then
                writeTypes = core.Slice(propTypes, 0)
            end
            writeTypes[#writeTypes + 1] = writeType
        end
        if t ~= firstType then
            checkFlags = checkFlags | CheckFlags.HasNonUniformType
        end
        if checker.isLiteralType(t) or self:isPatternLiteralType(t) then
            checkFlags = checkFlags | CheckFlags.HasLiteralType
        end
        if t.flags & TypeFlags.Never ~= 0 and t ~= self.uniqueLiteralType then
            checkFlags = checkFlags | CheckFlags.HasNeverType
        end
        propTypes = core.Append(propTypes, t)
    end
    propTypes = core.AppendAll(propTypes, indexTypes)
    local result = self:newSymbolEx(propFlags | optionalFlag, name, checkFlags | syntheticFlag)
    result.declarations = declarations
    if not hasNonUniformValueDeclaration and firstValueDeclaration ~= nil then
        result.valueDeclaration = firstValueDeclaration
        -- Inherit information about parent type.
        result.parent = firstValueDeclaration:Symbol().parent
    end
    local links = self.valueSymbolLinks:Get(result)
    links.containingType = containingType
    links.nameType = nameType
    if #propTypes > 2 then
        -- When `propTypes` has the potential to explode in size when normalized, defer normalization until absolutely needed
        result.checkFlags = result.checkFlags | CheckFlags.DeferredType
        local deferred = self.deferredSymbolLinks:Get(result)
        deferred.parent = containingType
        deferred.constituents = propTypes
        deferred.writeConstituents = writeTypes
        return result
    end
    if isUnion then
        links.resolvedType = self:getUnionType(propTypes)
    else
        links.resolvedType = self:getIntersectionType(propTypes)
    end
    if writeTypes ~= nil then
        if isUnion then
            links.writeType = self:getUnionType(writeTypes)
        else
            links.writeType = self:getIntersectionType(writeTypes)
        end
    end
    return result
end

function Checker:getTargetSymbol(s)
    -- if symbol is instantiated its flags are not copied from the 'target'
    -- so we'll need to get back original 'target' symbol to work with correct set of flags
    -- NOTE: cast to TransientSymbol should be safe because only TransientSymbols have CheckFlags.Instantiated
    if s ~= nil and s.checkFlags & CheckFlags.Instantiated ~= 0 then
        return self.valueSymbolLinks:Get(s).target
    end
    return s
end

--[[
 * Return whether this symbol is a member of a prototype somewhere
 * Note that this is not tracked well within the compiler, so the answer may be incorrect.
]]
function checker.isPrototypeProperty(symbol)
    return symbol.flags & SymbolFlags.Method ~= 0 or symbol.checkFlags & CheckFlags.SyntheticMethod ~= 0
end

function Checker:hasCommonDeclaration(symbols)
    local commonDeclarations = collections.NewSet()
    for symbol in symbols:Values() do
        if core.Len(symbol.declarations) == 0 then
            return false
        end
        if commonDeclarations:Len() == 0 then
            for _, d in ipairs(symbol.declarations) do
                commonDeclarations:Add(d)
            end
            goto continue
        end
        for d in pairs(commonDeclarations:Keys() or {}) do
            if not contains(symbol.declarations, d) then
                commonDeclarations:Delete(d)
            end
        end
        if commonDeclarations:Len() == 0 then
            return false
        end
        ::continue::
    end
    return commonDeclarations:Len() ~= 0
end

function Checker:createSymbolWithType(source, t)
    local symbol = self:newSymbolEx(source.flags, source.name, source.checkFlags & CheckFlags.Readonly)
    symbol.declarations = source.declarations
    symbol.parent = source.parent
    symbol.valueDeclaration = source.valueDeclaration
    local links = self.valueSymbolLinks:Get(symbol)
    links.resolvedType = t
    links.target = source
    links.nameType = self.valueSymbolLinks:Get(source).nameType
    return symbol
end

function Checker:isMappedTypeGenericIndexedAccess(t)
    if t.flags & TypeFlags.IndexedAccess ~= 0 then
        local objectType = t:AsIndexedAccessType().objectType
        return objectType.objectFlags & ObjectFlags.Mapped ~= 0 and not self:isGenericMappedType(objectType) and self:isGenericIndexType(t:AsIndexedAccessType().indexType) and
            checker.getMappedTypeModifiers(objectType) & MappedTypeModifiers.ExcludeOptional == 0 and objectType:AsMappedType().declaration.nameType == nil
    end
    return false
end

--[[
 * For a type parameter, return the base constraint of the type parameter. For the string, number,
 * boolean, and symbol primitive types, return the corresponding object types. Otherwise return the
 * type itself.
]]
function Checker:getApparentType(t)
    local originalType = t
    if t.flags & TypeFlags.Instantiable ~= 0 then
        t = self:getBaseConstraintOfType(t)
        if t == nil then
            t = self.unknownType
        end
    end
    if t.objectFlags & ObjectFlags.Mapped ~= 0 then
        return self:getApparentTypeOfMappedType(t)
    elseif t.objectFlags & ObjectFlags.Reference ~= 0 and t ~= originalType then
        return self:getTypeWithThisArgument(t, originalType, false --[[needsApparentType]])
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        return self:getApparentTypeOfIntersectionType(t, originalType)
    elseif t.flags & TypeFlags.StringLike ~= 0 then
        return self.globalStringType
    elseif t.flags & TypeFlags.NumberLike ~= 0 then
        return self.globalNumberType
    elseif t.flags & TypeFlags.BigIntLike ~= 0 then
        return self.getGlobalBigIntType()
    elseif t.flags & TypeFlags.BooleanLike ~= 0 then
        return self.globalBooleanType
    elseif t.flags & TypeFlags.ESSymbolLike ~= 0 then
        return self.getGlobalESSymbolType()
    elseif t.flags & TypeFlags.NonPrimitive ~= 0 then
        return self.emptyObjectType
    elseif t.flags & TypeFlags.Index ~= 0 then
        return self.stringNumberSymbolType
    elseif t.flags & TypeFlags.Unknown ~= 0 and not self.strictNullChecks then
        return self.emptyObjectType
    end
    return t
end

function Checker:getApparentTypeOfMappedType(t)
    local m = t:AsMappedType()
    if m.resolvedApparentType == nil then
        m.resolvedApparentType = self:getResolvedApparentTypeOfMappedType(t)
    end
    return m.resolvedApparentType
end

function Checker:getResolvedApparentTypeOfMappedType(t)
    local target = core.OrElse(t:AsMappedType().target, t)
    local typeVariable = self:getHomomorphicTypeVariable(target)
    if typeVariable ~= nil and target:AsMappedType().declaration.nameType == nil then
        -- We have a homomorphic mapped type or an instantiation of a homomorphic mapped type, i.e. a type
        -- of the form { [P in keyof T]: X }. Obtain the modifiers type (the T of the keyof T), and if it is
        -- another generic mapped type, recursively obtain its apparent type. Otherwise, obtain its base
        -- constraint. Then, if every constituent of the base constraint is an array or tuple type, apply
        -- this mapped type to the base constraint. It is safe to recurse when the modifiers type is a
        -- mapped type because we protect again circular constraints in getTypeFromMappedTypeNode.
        local modifiersType = self:getModifiersTypeFromMappedType(t)
        local baseConstraint
        if self:isGenericMappedType(modifiersType) then
            baseConstraint = self:getApparentTypeOfMappedType(modifiersType)
        else
            baseConstraint = self:getBaseConstraintOfType(modifiersType)
        end
        if baseConstraint ~= nil and checker.everyType(baseConstraint, function(ct)
            return self:isArrayOrTupleType(ct) or self:isArrayOrTupleOrIntersection(ct)
        end) then
            return self:instantiateType(target, checker.prependTypeMapping(typeVariable, baseConstraint, t:AsMappedType().mapper))
        end
    end
    return t
end

function Checker:getApparentTypeOfIntersectionType(t, thisArgument)
    if t == thisArgument then
        local d = t:AsIntersectionType()
        if d.resolvedApparentType == nil then
            d.resolvedApparentType = self:getTypeWithThisArgument(t, thisArgument, true --[[needApparentType]])
        end
        return d.resolvedApparentType
    end
    local key = checker.CachedTypeKey(CachedTypeKind.ApparentType, thisArgument.id)
    local result = self.cachedTypes[key]
    if result == nil then
        result = self:getTypeWithThisArgument(t, thisArgument, true --[[needApparentType]])
        self.cachedTypes[key] = result
    end
    return result
end

--[[
 * Return the reduced form of the given type. For a union type, it is a union of the normalized constituent types.
 * For an intersection of types containing one or more mututally exclusive discriminant properties, it is 'never'.
 * For all other types, it is simply the type itself. Discriminant properties are considered mutually exclusive when
 * no constituent property has type 'never', but the intersection of the constituent property types is 'never'.
]]
function Checker:getReducedType(t)
    if t.flags & TypeFlags.Union ~= 0 then
        if t.objectFlags & checker.ObjectFlagsContainsIntersections ~= 0 then
            local cachedReducedType = t:AsUnionType().resolvedReducedType
            if cachedReducedType ~= nil then
                return cachedReducedType
            end
            local reducedType = self:getReducedUnionType(t)
            t:AsUnionType().resolvedReducedType = reducedType
            return reducedType
        end
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        if t.objectFlags & checker.ObjectFlagsIsNeverIntersectionComputed == 0 then
            t.objectFlags = t.objectFlags | checker.ObjectFlagsIsNeverIntersectionComputed
            if core.Some(self:getPropertiesOfUnionOrIntersectionType(t), function(p) return self:isNeverReducedProperty(p) end) then
                t.objectFlags = t.objectFlags | checker.ObjectFlagsIsNeverIntersection
            end
        end
        if t.objectFlags & checker.ObjectFlagsIsNeverIntersection ~= 0 then
            return self.neverType
        end
    end
    return t
end

function Checker:getReducedUnionType(unionType)
    local reducedTypes = core.SameMap(unionType:Types(), function(t) return self:getReducedType(t) end)
    if core.Same(reducedTypes, unionType:Types()) then
        return unionType
    end
    local reduced = self:getUnionType(reducedTypes)
    if reduced.flags & TypeFlags.Union ~= 0 then
        reduced:AsUnionType().resolvedReducedType = reduced
    end
    return reduced
end

function Checker:isNeverReducedProperty(prop)
    return self:isDiscriminantWithNeverType(prop) or checker.isConflictingPrivateProperty(prop)
end

function Checker:getReducedApparentType(t)
    -- Since getApparentType may return a non-reduced union or intersection type, we need to perform
    -- type reduction both before and after obtaining the apparent type. For example, given a type parameter
    -- 'T extends A | B', the type 'T & X' becomes 'A & X | B & X' after obtaining the apparent type, and
    -- that type may need further reduction to remove empty intersections.
    return self:getReducedType(self:getApparentType(self:getReducedType(t)))
end

function Checker:elaborateNeverIntersection(chain, node, t)
    if t.flags & TypeFlags.Intersection ~= 0 and t.objectFlags & checker.ObjectFlagsIsNeverIntersection ~= 0 then
        local neverProp = core.Find(self:getPropertiesOfUnionOrIntersectionType(t), function(p) return self:isDiscriminantWithNeverType(p) end)
        if neverProp ~= nil then
            return checker.NewDiagnosticChainForNode(chain, node, diagnostics.The_intersection_0_was_reduced_to_never_because_property_1_has_conflicting_types_in_some_constituents, self:typeToStringEx(t, nil, TypeFormatFlags.NoTypeReduction, nil), self:symbolToString(neverProp))
        end
        local privateProp = core.Find(self:getPropertiesOfUnionOrIntersectionType(t), function(p) return checker.isConflictingPrivateProperty(p) end)
        if privateProp ~= nil then
            return checker.NewDiagnosticChainForNode(chain, node, diagnostics.The_intersection_0_was_reduced_to_never_because_property_1_exists_in_multiple_constituents_and_is_private_in_some, self:typeToStringEx(t, nil, TypeFormatFlags.NoTypeReduction, nil), self:symbolToString(privateProp))
        end
    end
    return chain
end

function Checker:isDiscriminantWithNeverType(prop)
    -- Return true for a synthetic non-optional property with non-uniform types, where at least one is
    -- a literal type and none is never, that reduces to never.
    return prop.flags & SymbolFlags.Optional == 0 and prop.checkFlags & (CheckFlags.NonUniformAndLiteral | CheckFlags.HasNeverType) == CheckFlags.NonUniformAndLiteral and self:getTypeOfSymbol(prop).flags & TypeFlags.Never ~= 0
end

function checker.isConflictingPrivateProperty(prop)
    -- Return true for a synthetic property with multiple declarations, at least one of which is private.
    return prop.valueDeclaration == nil and prop.checkFlags & CheckFlags.ContainsPrivate ~= 0
end

function Checker:getTypeArguments(t)
    local d = t:AsTypeReference()
    if d.resolvedTypeArguments == nil then
        local n = d.target:AsInterfaceType()
        if not self:pushTypeResolution(t, TypeSystemPropertyName.ResolvedTypeArguments) then
            return repeatValue(self.errorType, core.Len(n:TypeParameters()))
        end
        local typeArguments = nil
        local node = t:AsTypeReference().node
        if node ~= nil then
            if node.kind == Kind.TypeReference then
                typeArguments = core.AppendAll(n:OuterTypeParameters(), self:getEffectiveTypeArguments(node, n:LocalTypeParameters()))
            elseif node.kind == Kind.ArrayType then
                typeArguments = { self:getTypeFromTypeNode(node:AsArrayTypeNode().elementType) }
            elseif node.kind == Kind.TupleType then
                typeArguments = core.Map(node:Elements(), function(e) return self:getTypeFromTypeNode(e) end)
            else
                error("Unhandled case in getTypeArguments", 0)
            end
        end
        if self:popTypeResolution() then
            if d.resolvedTypeArguments == nil then
                d.resolvedTypeArguments = self:instantiateTypes(typeArguments, d.mapper)
            end
        else
            if d.resolvedTypeArguments == nil then
                d.resolvedTypeArguments = repeatValue(self.errorType, core.Len(n:TypeParameters()))
            end
            local errorNode = core.IfElse(node ~= nil, node, self.currentNode)
            if d.target.symbol ~= nil then
                self:error(errorNode, diagnostics.Type_arguments_for_0_circularly_reference_themselves, self:symbolToString(d.target.symbol))
            else
                self:error(errorNode, diagnostics.Tuple_type_arguments_circularly_reference_themselves)
            end
        end
    end
    return d.resolvedTypeArguments
end

function Checker:getEffectiveTypeArguments(node, typeParameters)
    return self:fillMissingTypeArguments(core.Map(node:TypeArguments(), function(n) return self:getTypeFromTypeNode(n) end), typeParameters, self:getMinTypeArgumentCount(typeParameters), ast.IsInJSFile(node))
end

-- Gets the minimum number of type arguments needed to satisfy all non-optional type parameters.
function Checker:getMinTypeArgumentCount(typeParameters)
    local minTypeArgumentCount = 0
    for i1, typeParameter in ipairs(typeParameters or {}) do
        if not self:hasTypeParameterDefault(typeParameter) then
            minTypeArgumentCount = i1
        end
    end
    return minTypeArgumentCount
end

function Checker:hasTypeParameterDefault(t)
    return t.symbol ~= nil and core.Some(t.symbol.declarations, function(d)
        return ast.IsTypeParameterDeclaration(d) and d:AsTypeParameterDeclaration().defaultType ~= nil
    end)
end

function Checker:fillMissingTypeArguments(typeArguments, typeParameters, minTypeArgumentCount, isJavaScriptImplicitAny)
    local numTypeParameters = core.Len(typeParameters)
    if numTypeParameters == 0 then
        return nil
    end
    local numTypeArguments = core.Len(typeArguments)
    if isJavaScriptImplicitAny or numTypeArguments < numTypeParameters then
        local result = {}
        for i = 1, numTypeParameters do
            if i <= numTypeArguments then
                result[i] = typeArguments[i]
            else
                -- Map invalid forward references in default types to the error type
                result[i] = self.errorType
            end
        end
        local baseDefaultType = self:getDefaultTypeArgumentType(isJavaScriptImplicitAny)
        for i = numTypeArguments, numTypeParameters - 1 do
            local defaultType = self:getDefaultFromTypeParameter(typeParameters[i + 1])

            if isJavaScriptImplicitAny and defaultType ~= nil and (self:isTypeIdenticalTo(defaultType, self.unknownType) or self:isTypeIdenticalTo(defaultType, self.emptyObjectType)) then
                defaultType = self.anyType
            end

            if defaultType ~= nil then
                result[i + 1] = self:instantiateType(defaultType, checker.newTypeMapper(typeParameters, result))
            else
                result[i + 1] = baseDefaultType
            end
        end
        return result
    end
    return typeArguments
end

function Checker:getDefaultTypeArgumentType(isInJavaScriptFile)
    if isInJavaScriptFile then
        return self.anyType
    end
    return self.unknownType
end

-- Gets the default type for a type parameter. If the type parameter is the result of an instantiation,
-- this gets the instantiated default type of its target. If the type parameter has no default type or
-- the default is circular, `undefined` is returned.
function Checker:getDefaultFromTypeParameter(t)
    if t.flags & TypeFlags.TypeParameter == 0 then
        return nil
    end
    local defaultType = self:getResolvedTypeParameterDefault(t)
    if defaultType ~= self.noConstraintType and defaultType ~= self.circularConstraintType then
        return defaultType
    end
    return nil
end

function Checker:getResolvedTypeParameterDefault(t)
    local d = t:AsTypeParameter()
    if d.resolvedDefaultType == nil then
        if d.target ~= nil then
            local targetDefault = self:getResolvedTypeParameterDefault(d.target)
            if targetDefault ~= nil then
                d.resolvedDefaultType = self:instantiateType(targetDefault, d.mapper)
            else
                d.resolvedDefaultType = self.noConstraintType
            end
        else
            -- To block recursion, set the initial value to the resolvingDefaultType.
            d.resolvedDefaultType = self.resolvingDefaultType
            local defaultType = self.noConstraintType
            if t.symbol ~= nil then
                local defaultDeclaration = core.FirstNonNil(t.symbol.declarations, function(decl)
                    if ast.IsTypeParameterDeclaration(decl) then
                        return decl:AsTypeParameterDeclaration().defaultType
                    end
                    return nil
                end)
                if defaultDeclaration ~= nil then
                    defaultType = self:getTypeFromTypeNode(defaultDeclaration)
                end
            end
            if d.resolvedDefaultType == self.resolvingDefaultType then
                -- If we have not been called recursively, set the correct default type.
                d.resolvedDefaultType = defaultType
            end
        end
    elseif d.resolvedDefaultType == self.resolvingDefaultType then
        -- If we are called recursively for this type parameter, mark the default as circular.
        d.resolvedDefaultType = self.circularConstraintType
    end
    return d.resolvedDefaultType
end

function Checker:getDefaultOrUnknownFromTypeParameter(t)
    local result = self:getDefaultFromTypeParameter(t)
    return core.IfElse(result ~= nil, result, self.unknownType)
end

function Checker:getNamedMembers(members, container)
    if members == nil or next(members) == nil then
        return nil
    end
    -- For classes and interfaces, we store explicitly declared members ahead of inherited members. This ensures we process
    -- explicitly declared members first in type relations, which is beneficial because explicitly declared members are more
    -- likely to contain discriminating differences. See for example https://github.com/microsoft/typescript-go/issues/1968.
    local contained = {}
    local rest = {}
    if container ~= nil and container.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
        for id, symbol in pairs(members) do
            if self:isNamedMember(symbol, id) and self:isDeclarationContainedBy(symbol, container) then
                contained[#contained + 1] = symbol
            end
        end
    end
    for id, symbol in pairs(members) do
        if self:isNamedMember(symbol, id) and (container == nil or container.flags & (SymbolFlags.Class | SymbolFlags.Interface) == 0 or not self:isDeclarationContainedBy(symbol, container)) then
            rest[#rest + 1] = symbol
        end
    end
    self:sortSymbols(contained)
    self:sortSymbols(rest)
    local result = contained
    for _, symbol in ipairs(rest) do
        result[#result + 1] = symbol
    end
    return result
end

function Checker:isDeclarationContainedBy(symbol, container)
    local declaration = symbol.valueDeclaration
    if declaration ~= nil then
        for _, d in ipairs(container.declarations or {}) do
            if declaration.loc:ContainedBy(d.loc) then
                return true
            end
        end
    end
    return false
end

function Checker:isNamedMember(symbol, id)
    return not checker.isReservedMemberName(id) and self:symbolIsValue(symbol)
end

function Checker:symbolIsValue(symbol)
    return self:symbolIsValueEx(symbol, false --[[includeTypeOnlyMembers]])
end

function Checker:symbolIsValueEx(symbol, includeTypeOnlyMembers)
    return symbol.flags & SymbolFlags.Value ~= 0 or symbol.flags & SymbolFlags.Alias ~= 0 and
        self:getSymbolFlagsEx(symbol, not includeTypeOnlyMembers, false --[[excludeLocalMeanings]]) & SymbolFlags.Value ~= 0
end

function Checker:instantiateType(t, m)
    return self:instantiateTypeWithAlias(t, m, nil --[[alias]])
end

function Checker:instantiateTypeWithAlias(t, m, alias)
    -- Check for type variables in the alias, so things like `type Brand<T> = number & {}` can potentially be copied with new alias type args, despite them being unreferenced.
    -- This is the behavior most people using aliases expect, and prevents the cache from leaking type parameters outside their scope of validity.
    -- tests/cases/compiler/declarationEmitArrowFunctionNoRenaming.ts contains an example of this, which previously only worked in strada via some input node reuse logic instead.
    if t == nil or m == nil or not (self.couldContainTypeVariables(t) or (t.alias ~= nil and core.Len(t.alias.typeArguments) > 0 and core.Some(t.alias.typeArguments, self.couldContainTypeVariables))) then
        return t
    end
    if self.instantiationDepth == 100 or self.instantiationCount >= 5000000 then
        -- We have reached 100 recursive type instantiations, or 5M type instantiations caused by the same statement
        -- or expression. There is a very high likelihood we're dealing with a combination of infinite generic types
        -- that perpetually generate new type identities, so we stop the recursion here by yielding the error type.
        -- (Tracing is out of scope: c.tracer is always nil.)
        self:error(self.currentNode, diagnostics.Type_instantiation_is_excessively_deep_and_possibly_infinite)
        return self.errorType
    end
    local index = self:findActiveMapper(m)
    if index == -1 then
        self:pushActiveMapper(m)
    end
    local b = checker.keyBuilder_new()
    b:writeType(t)
    b:writeAlias(alias)
    local key = b:hash()
    local cache = self.activeTypeMappersCaches[core.IfElse(index ~= -1, index, #self.activeTypeMappersCaches - 1) + 1]
    local cachedType = cache[key]
    if cachedType ~= nil then
        return cachedType
    end
    self.totalInstantiationCount = self.totalInstantiationCount + 1
    self.instantiationCount = self.instantiationCount + 1
    self.instantiationDepth = self.instantiationDepth + 1
    local result = self:instantiateTypeWorker(t, m, alias)
    if index == -1 then
        self:popActiveMapper()
    else
        cache[key] = result
    end
    self.instantiationDepth = self.instantiationDepth - 1
    return result
end

function Checker:pushActiveMapper(mapper)
    self.activeMappers[#self.activeMappers + 1] = mapper
    self.activeTypeMappersCaches[#self.activeTypeMappersCaches + 1] = {}
end

function Checker:popActiveMapper()
    self.activeMappers[#self.activeMappers] = nil

    -- Clear the map (Go keeps it in the list for later reuse).
    local lastIndex = #self.activeTypeMappersCaches
    local cache = self.activeTypeMappersCaches[lastIndex]
    for k in pairs(cache) do
        cache[k] = nil
    end
    self.activeTypeMappersCaches[lastIndex] = nil
end

function Checker:findActiveMapper(mapper)
    return core.FindLastIndex(self.activeMappers, function(m) return m == mapper end)
end

function Checker:clearActiveMapperCaches()
    for _, cache in ipairs(self.activeTypeMappersCaches) do
        for k in pairs(cache) do
            cache[k] = nil
        end
    end
end

-- Return true if the given type could possibly reference a type parameter for which
-- we perform type inference (i.e. a type parameter of a generic function). We cache
-- results for union and intersection types for performance reasons.
function Checker:couldContainTypeVariablesWorker(t)
    if t.flags & TypeFlags.StructuredOrInstantiable == 0 then
        return false
    end
    local objectFlags = t.objectFlags
    if objectFlags & ObjectFlags.CouldContainTypeVariablesComputed ~= 0 then
        return objectFlags & ObjectFlags.CouldContainTypeVariables ~= 0
    end
    local result = t.flags & TypeFlags.Instantiable ~= 0 or
        t.flags & TypeFlags.Object ~= 0 and not self:isNonGenericTopLevelType(t) and (objectFlags & ObjectFlags.Reference ~= 0 and (t:AsTypeReference().node ~= nil or core.Some(self:getTypeArguments(t), self.couldContainTypeVariables)) or
            objectFlags & ObjectFlags.Anonymous ~= 0 and t.symbol ~= nil and t.symbol.flags & (SymbolFlags.Function | SymbolFlags.Method | SymbolFlags.Class | SymbolFlags.TypeLiteral | SymbolFlags.ObjectLiteral) ~= 0 and t.symbol.declarations ~= nil or
            objectFlags & (ObjectFlags.Mapped | ObjectFlags.ReverseMapped | checker.ObjectFlagsObjectRestType | checker.ObjectFlagsInstantiationExpressionType) ~= 0) or
        t.flags & TypeFlags.UnionOrIntersection ~= 0 and t.flags & TypeFlags.EnumLiteral == 0 and not self:isNonGenericTopLevelType(t) and core.Some(t:Types(), self.couldContainTypeVariables)
    t.objectFlags = t.objectFlags | ObjectFlags.CouldContainTypeVariablesComputed | core.IfElse(result, ObjectFlags.CouldContainTypeVariables, 0)
    return result
end

function Checker:isNonGenericTopLevelType(t)
    if t.alias ~= nil and core.Len(t.alias.typeArguments) == 0 then
        local declaration = ast.GetDeclarationOfKind(t.alias.symbol, Kind.TypeAliasDeclaration)
        if declaration == nil then
            declaration = ast.GetDeclarationOfKind(t.alias.symbol, Kind.JSTypeAliasDeclaration)
        end
        return declaration ~= nil and ast.FindAncestorOrQuit(declaration.parent, function(n)
            if n.kind == Kind.SourceFile then
                return FindAncestorResult.True
            elseif n.kind == Kind.ModuleDeclaration then
                return FindAncestorResult.False
            end
            return FindAncestorResult.Quit
        end) ~= nil
    end
    return false
end

function Checker:instantiateTypeWorker(t, m, alias)
    local flags = t.flags
    if flags & TypeFlags.TypeParameter ~= 0 then
        return m:Map(t)
    elseif flags & TypeFlags.Object ~= 0 then
        local objectFlags = t.objectFlags
        if objectFlags & (ObjectFlags.Reference | ObjectFlags.Anonymous | ObjectFlags.Mapped) ~= 0 then
            if objectFlags & ObjectFlags.Reference ~= 0 and t:AsTypeReference().node == nil then
                local resolvedTypeArguments = t:AsTypeReference().resolvedTypeArguments
                local newTypeArguments = self:instantiateTypes(resolvedTypeArguments, m)
                if core.Same(newTypeArguments, resolvedTypeArguments) then
                    return t
                end
                return self:createNormalizedTypeReference(t:Target(), newTypeArguments)
            end
            if objectFlags & ObjectFlags.ReverseMapped ~= 0 then
                return self:instantiateReverseMappedType(t, m)
            end
            return self:getObjectTypeInstantiation(t, m, alias)
        end
        return t
    elseif flags & TypeFlags.UnionOrIntersection ~= 0 then
        local source = t
        if t.flags & TypeFlags.Union ~= 0 then
            local origin = t:AsUnionType().origin
            if origin ~= nil and origin.flags & TypeFlags.UnionOrIntersection ~= 0 then
                source = origin
            end
        end
        local types = source:Types()
        local newTypes = self:instantiateTypes(types, m)
        if core.Same(newTypes, types) and checker.TypeAlias.Symbol(alias) == checker.TypeAlias.Symbol(t.alias) then
            return t
        end
        if alias == nil then
            alias = self:instantiateTypeAlias(t.alias, m)
        end
        if source.flags & TypeFlags.Intersection ~= 0 then
            return self:getIntersectionTypeEx(newTypes, IntersectionFlags.None, alias)
        end
        return self:getUnionTypeEx(newTypes, UnionReduction.Literal, alias, nil --[[origin]])
    elseif flags & TypeFlags.Index ~= 0 then
        return self:getIndexType(self:instantiateType(t:Target(), m))
    elseif flags & TypeFlags.IndexedAccess ~= 0 then
        if alias == nil then
            alias = self:instantiateTypeAlias(t.alias, m)
        end
        local d = t:AsIndexedAccessType()
        return self:getIndexedAccessTypeEx(self:instantiateType(d.objectType, m), self:instantiateType(d.indexType, m), d.accessFlags, nil --[[accessNode]], alias)
    elseif flags & TypeFlags.TemplateLiteral ~= 0 then
        return self:getTemplateLiteralType(t:AsTemplateLiteralType().texts, self:instantiateTypes(t:AsTemplateLiteralType().types, m))
    elseif flags & TypeFlags.StringMapping ~= 0 then
        return self:getStringMappingType(t.symbol, self:instantiateType(t:AsStringMappingType().target, m))
    elseif flags & TypeFlags.Conditional ~= 0 then
        return self:getConditionalTypeInstantiation(t, self:combineTypeMappers(t:AsConditionalType().mapper, m), false --[[forConstraint]], alias)
    elseif flags & TypeFlags.Substitution ~= 0 then
        local newBaseType = self:instantiateType(t:AsSubstitutionType().baseType, m)
        if self:isNoInferType(t) then
            return self:getNoInferType(newBaseType)
        end
        local newConstraint = self:instantiateType(t:AsSubstitutionType().constraint, m)
        -- A substitution type originates in the true branch of a conditional type and can be resolved
        -- to just the base type in the same cases as the conditional type resolves to its true branch
        -- (because the base type is then known to satisfy the constraint).
        if newBaseType.flags & TypeFlags.TypeVariable ~= 0 and self:isGenericType(newConstraint) then
            return self:getSubstitutionType(newBaseType, newConstraint)
        end
        if newConstraint.flags & TypeFlags.AnyOrUnknown ~= 0 or self:isTypeAssignableTo(self:getRestrictiveInstantiation(newBaseType), self:getRestrictiveInstantiation(newConstraint)) then
            return newBaseType
        end
        if newBaseType.flags & TypeFlags.TypeVariable ~= 0 then
            return self:getSubstitutionType(newBaseType, newConstraint)
        end
        return self:getIntersectionType({ newConstraint, newBaseType })
    end
    return t
end

-- Handles instantiation of the following object types:
-- AnonymousType (ObjectFlagsAnonymous|ObjectFlagsSingleSignatureType)
-- TypeReference with node != nil (ObjectFlagsReference)
-- InstantiationExpressionType (ObjectFlagsInstantiationExpressionType)
-- MappedType (ObjectFlagsMapped)
function Checker:getObjectTypeInstantiation(t, m, alias)
    local declaration
    local target
    local typeParameters
    if t.objectFlags & ObjectFlags.Reference ~= 0 then -- Deferred type reference
        declaration = t:AsTypeReference().node
    elseif t.objectFlags & checker.ObjectFlagsInstantiationExpressionType ~= 0 then
        declaration = t:AsInstantiationExpressionType().node
    else
        declaration = t.symbol.declarations[1]
    end
    local links = self.typeNodeLinks:Get(declaration)
    if t.objectFlags & ObjectFlags.Reference ~= 0 then -- Deferred type reference
        target = links.resolvedType
    elseif t.objectFlags & ObjectFlags.Instantiated ~= 0 then
        target = t:Target()
    else
        target = t
    end
    typeParameters = links.outerTypeParameters
    if typeParameters == nil then
        -- The first time an anonymous type is instantiated we compute and store a list of the type
        -- parameters that are in scope (and therefore potentially referenced). For type literals that
        -- aren't the right hand side of a generic type alias declaration we optimize by reducing the
        -- set of type parameters to those that are possibly referenced in the literal.
        typeParameters = self:getOuterTypeParameters(declaration, true --[[includeThisTypes]])
        if core.Len(checker.TypeAlias.TypeArguments(target.alias)) == 0 then
            if t.objectFlags & (ObjectFlags.Reference | checker.ObjectFlagsInstantiationExpressionType) ~= 0 then
                typeParameters = core.Filter(typeParameters, function(tp)
                    return self:isTypeParameterPossiblyReferenced(tp, declaration)
                end)
            elseif target.symbol.flags & (SymbolFlags.Method | SymbolFlags.TypeLiteral) ~= 0 then
                typeParameters = core.Filter(typeParameters, function(tp)
                    return core.Some(t.symbol.declarations, function(d)
                        return self:isTypeParameterPossiblyReferenced(tp, d)
                    end)
                end)
            end
        end
        if typeParameters == nil then
            typeParameters = {}
        end
        links.outerTypeParameters = typeParameters
    end
    if #typeParameters == 0 then
        return t
    end
    -- We are instantiating an anonymous type that has one or more type parameters in scope. Apply the
    -- mapper to the type parameters to produce the effective list of type arguments, and compute the
    -- instantiation cache key from the type IDs of the type arguments.
    local typeArguments = {}
    for i, tp in ipairs(typeParameters) do
        typeArguments[i] = self:mapTypeWithCompositeMapper(tp, t:Mapper(), m)
    end
    local newAlias = alias
    if newAlias == nil then
        newAlias = self:instantiateTypeAlias(t.alias, m)
    end
    local data = target:AsObjectType()
    local key = checker.getTypeInstantiationKey(typeArguments, newAlias, t.objectFlags & checker.ObjectFlagsSingleSignatureType ~= 0)
    if data.instantiations == nil then
        data.instantiations = {}
        data.instantiations[checker.getTypeInstantiationKey(typeParameters, target.alias, false)] = target
    end
    local result = data.instantiations[key]
    if result == nil then
        local newMapper = checker.newTypeMapper(typeParameters, typeArguments)
        if target.objectFlags & checker.ObjectFlagsSingleSignatureType ~= 0 and m ~= nil then
            newMapper = self:combineTypeMappers(newMapper, m)
        end
        if target.objectFlags & ObjectFlags.Reference ~= 0 then
            result = self:createDeferredTypeReference(t:Target(), t:AsTypeReference().node, newMapper, newAlias)
        elseif target.objectFlags & ObjectFlags.Mapped ~= 0 then
            result = self:instantiateMappedType(target, newMapper, newAlias)
        else
            result = self:instantiateAnonymousType(target, newMapper, newAlias)
        end
        data.instantiations[key] = result
        if result.flags & TypeFlags.ObjectFlagsType ~= 0 and result.objectFlags & ObjectFlags.CouldContainTypeVariablesComputed == 0 then
            -- if `result` is one of the object types we tried to make (it may not be, due to how `instantiateMappedType` works), we can carry forward the type variable containment check from the input type arguments
            local resultCouldContainObjectFlags = core.Some(typeArguments, self.couldContainTypeVariables)
            if result.objectFlags & ObjectFlags.CouldContainTypeVariablesComputed == 0 then
                if result.objectFlags & (ObjectFlags.Mapped | ObjectFlags.Anonymous | ObjectFlags.Reference) ~= 0 then
                    result.objectFlags = result.objectFlags | ObjectFlags.CouldContainTypeVariablesComputed | core.IfElse(resultCouldContainObjectFlags, ObjectFlags.CouldContainTypeVariables, 0)
                else
                    -- If none of the type arguments for the outer type parameters contain type variables, it follows
                    -- that the instantiated type doesn't reference type variables.
                    -- Intrinsics have `CouldContainTypeVariablesComputed` pre-set, so this should only cover unions and intersections resulting from `instantiateMappedType`
                    result.objectFlags = result.objectFlags | core.IfElse(not resultCouldContainObjectFlags, ObjectFlags.CouldContainTypeVariablesComputed, 0)
                end
            end
        end
    end
    return result
end

function Checker:isTypeParameterPossiblyReferenced(tp, node)
    local containsReference
    containsReference = function(node) -- luacheck: ignore 432
        local kind = node.kind
        if kind == Kind.ThisType then
            return tp:AsTypeParameter().isThisType
        elseif kind == Kind.TypeReference then
            -- use worker because we're looking for === equality
            if not tp:AsTypeParameter().isThisType and core.Len(node:TypeArguments()) == 0 and self:getSymbolFromTypeReference(node) == tp.symbol then
                return true
            end
        elseif kind == Kind.TypeQuery then
            local entityName = node:AsTypeQueryNode().exprName
            local firstIdentifier = ast.GetFirstIdentifier(entityName)
            if not ast.IsThisIdentifier(firstIdentifier) then
                local firstIdentifierSymbol = self:getResolvedSymbol(firstIdentifier)
                local tpDeclaration = tp.symbol.declarations[1] -- There is exactly one declaration, otherwise `containsReference` is not called
                local tpScope = nil
                if ast.IsTypeParameterDeclaration(tpDeclaration) then
                    tpScope = tpDeclaration.parent -- Type parameter is a regular type parameter, e.g. foo<T>
                elseif tp:AsTypeParameter().isThisType then
                    tpScope = tpDeclaration -- Type parameter is the this type, and its declaration is the class declaration.
                end
                if tpScope ~= nil then
                    return core.Some(firstIdentifierSymbol.declarations, function(d) return checker.isNodeDescendantOf(d, tpScope) end) or
                        core.Some(node:TypeArguments(), containsReference)
                end
            end
            return true
        elseif kind == Kind.MethodDeclaration or kind == Kind.MethodSignature then
            local returnType = node:Type()
            return returnType == nil and node:Body() ~= nil or
                core.Some(node:TypeParameters(), containsReference) or
                core.Some(node:Parameters(), containsReference) or
                returnType ~= nil and containsReference(returnType)
        end
        return node:ForEachChild(containsReference)
    end
    -- If the type parameter doesn't have exactly one declaration, if there are intervening statement blocks
    -- between the node and the type parameter declaration, if the node contains actual references to the
    -- type parameter, or if the node contains type queries that we can't prove couldn't contain references to the type parameter,
    -- we consider the type parameter possibly referenced.
    if tp.symbol ~= nil and core.Len(tp.symbol.declarations) == 1 then
        local container = tp.symbol.declarations[1].parent
        local n = node
        while n ~= container do
            if n == nil or ast.IsBlock(n) or ast.IsConditionalTypeNode(n) and containsReference(n:AsConditionalTypeNode().extendsType) then
                return true
            end
            n = n.parent
        end
        return containsReference(node)
    end
    return true
end

function Checker:instantiateAnonymousType(t, m, alias)
    local result = self:newObjectType(t.objectFlags & ~(ObjectFlags.CouldContainTypeVariablesComputed | ObjectFlags.CouldContainTypeVariables) | ObjectFlags.Instantiated, t.symbol)
    if t.objectFlags & ObjectFlags.Mapped ~= 0 then
        result:AsMappedType().declaration = t:AsMappedType().declaration
        -- C.f. instantiateSignature
        local origTypeParameter = self:getTypeParameterFromMappedType(t)
        local freshTypeParameter = self:cloneTypeParameter(origTypeParameter)
        result:AsMappedType().typeParameter = freshTypeParameter
        m = self:combineTypeMappers(checker.newSimpleTypeMapper(origTypeParameter, freshTypeParameter), m)
        freshTypeParameter:AsTypeParameter().mapper = m
    elseif t.objectFlags & checker.ObjectFlagsInstantiationExpressionType ~= 0 then
        result:AsInstantiationExpressionType().node = t:AsInstantiationExpressionType().node
    end
    if alias == nil then
        alias = self:instantiateTypeAlias(t.alias, m)
    end
    result.alias = alias
    if alias ~= nil and core.Len(alias.typeArguments) ~= 0 then
        result.objectFlags = result.objectFlags | self:getPropagatingFlagsOfTypes(result.alias.typeArguments, TypeFlags.None)
    end
    local d = result:AsObjectType()
    d.target = t
    d.mapper = m
    return result
end

function Checker:getConditionalTypeInstantiation(t, mapper, forConstraint, alias)
    local root = t:AsConditionalType().root
    if core.Len(root.outerTypeParameters) ~= 0 then
        -- We are instantiating a conditional type that has one or more type parameters in scope. Apply the
        -- mapper to the type parameters to produce the effective list of type arguments, and compute the
        -- instantiation cache key from the type IDs of the type arguments.
        local typeArguments = core.Map(root.outerTypeParameters, function(tp) return mapper:Map(tp) end)
        local key = checker.getConditionalTypeKey(typeArguments, alias, forConstraint)
        local result = root.instantiations[key]
        if result == nil then
            local newMapper = checker.newTypeMapper(root.outerTypeParameters, typeArguments)
            local checkType = root.checkType
            local distributionType = nil
            if root.isDistributive then
                distributionType = self:getReducedType(newMapper:Map(checkType))
            end
            -- Distributive conditional types are distributed over union types. For example, when the
            -- distributive conditional type T extends U ? X : Y is instantiated with A | B for T, the
            -- result is (A extends U ? X : Y) | (B extends U ? X : Y).
            if distributionType ~= nil and checkType ~= distributionType and distributionType.flags & (TypeFlags.Union | TypeFlags.Never) ~= 0 then
                result = self:mapTypeWithAlias(distributionType, function(dt)
                    return self:getConditionalType(root, checker.prependTypeMapping(checkType, dt, newMapper), forConstraint, nil)
                end, alias)
            else
                result = self:getConditionalType(root, newMapper, forConstraint, alias)
            end
            root.instantiations[key] = result
        end
        return result
    end
    return t
end

function Checker:cloneTypeParameter(tp)
    local result = self:newTypeParameter(tp.symbol)
    result:AsTypeParameter().target = tp
    return result
end

function Checker:getHomomorphicTypeVariable(t)
    local constraintType = self:getConstraintTypeFromMappedType(t)
    if constraintType.flags & TypeFlags.Index ~= 0 then
        local typeVariable = self:getActualTypeVariable(constraintType:AsIndexType().target)
        if typeVariable.flags & TypeFlags.TypeParameter ~= 0 then
            return typeVariable
        end
    end
    return nil
end

function Checker:instantiateMappedType(t, m, alias)
    -- For a homomorphic mapped type { [P in keyof T]: X }, where T is some type variable, the mapping
    -- operation depends on T as follows:
    -- * If T is a primitive type no mapping is performed and the result is simply T.
    -- * If T is a union type we distribute the mapped type over the union.
    -- * If T is an array we map to an array where the element type has been transformed.
    -- * If T is a tuple we map to a tuple where the element types have been transformed.
    -- * If T is an intersection of array or tuple types we map to an intersection of transformed array or tuple types.
    -- * Otherwise we map to an object type where the type of each property has been transformed.
    -- For example, when T is instantiated to a union type A | B, we produce { [P in keyof A]: X } |
    -- { [P in keyof B]: X }, and when when T is instantiated to a union type A | undefined, we produce
    -- { [P in keyof A]: X } | undefined.
    local d = t:AsMappedType()
    local typeVariable = self:getHomomorphicTypeVariable(t)
    local instantiateConstituent
    instantiateConstituent = function(s)
        if s.flags & (TypeFlags.AnyOrUnknown | TypeFlags.InstantiableNonPrimitive | TypeFlags.Object | TypeFlags.Intersection) == 0 or s == self.wildcardType or self:isErrorType(s) then
            return s
        end
        if d.declaration.nameType == nil then
            if self:isArrayType(s) or s.flags & TypeFlags.Any ~= 0 and self:findResolutionCycleStartIndex(typeVariable, TypeSystemPropertyName.ResolvedBaseConstraint) < 0 and self:hasArrayOrTypeTypeConstraint(typeVariable) then
                return self:instantiateMappedArrayType(s, t, checker.prependTypeMapping(typeVariable, s, m))
            end
            if checker.isTupleType(s) then
                return self:instantiateMappedTupleType(s, t, typeVariable, m)
            end
            if self:isArrayOrTupleOrIntersection(s) then
                return self:getIntersectionType(core.Map(s:Types(), instantiateConstituent))
            end
        end
        return self:instantiateAnonymousType(t, checker.prependTypeMapping(typeVariable, s, m), nil)
    end
    if typeVariable ~= nil then
        local mappedTypeVariable = self:instantiateType(typeVariable, m)
        if typeVariable ~= mappedTypeVariable then
            return self:mapTypeWithAlias(self:getReducedType(mappedTypeVariable), instantiateConstituent, alias)
        end
    end
    -- If the constraint type of the instantiation is the wildcard type, return the wildcard type.
    if self:instantiateType(self:getConstraintTypeFromMappedType(t), m) == self.wildcardType then
        return self.wildcardType
    end
    return self:instantiateAnonymousType(t, m, alias)
end

function Checker:hasArrayOrTypeTypeConstraint(typeVariable)
    local constraint = self:getConstraintOfTypeParameter(typeVariable)
    return constraint ~= nil and checker.everyType(constraint, function(t) return self:isArrayOrTupleType(t) end)
end

function Checker:instantiateMappedArrayType(arrayType, mappedType, m)
    local elementType = self:instantiateMappedTypeTemplate(mappedType, self.numberType, true --[[isOptional]], m)
    if self:isErrorType(elementType) then
        return self.errorType
    end
    return self:createArrayTypeEx(elementType, checker.getModifiedReadonlyState(self:isReadonlyArrayType(arrayType), checker.getMappedTypeModifiers(mappedType)))
end

function Checker:instantiateMappedTupleType(tupleType, mappedType, typeVariable, m)
    -- We apply the mapped type's template type to each of the fixed part elements. For variadic elements, we
    -- apply the mapped type itself to the variadic element type. For other elements in the variable part of the
    -- tuple, we surround the element type with an array type and apply the mapped type to that. This ensures
    -- that we get sequential property key types for the fixed part of the tuple, and property key type number
    -- for the remaining elements. For example
    --
    --   type Keys<T> = { [K in keyof T]: K };
    --   type Foo<T extends any[]> = Keys<[string, string, ...T, string]>; // ["0", "1", ...Keys<T>, number]
    --
    local elementInfos = tupleType:TargetTupleType().elementInfos
    local fixedLength = tupleType:TargetTupleType().fixedLength
    local fixedMapper = m
    if fixedLength ~= 0 then
        fixedMapper = checker.prependTypeMapping(typeVariable, tupleType, m)
    end
    local modifiers = checker.getMappedTypeModifiers(mappedType)
    local elementTypes = self:getElementTypes(tupleType)
    local newElementTypes = {}
    local newElementInfos = core.Slice(elementInfos, 0)
    for i1, e in ipairs(elementTypes or {}) do
        local i = i1 - 1
        local flags = elementInfos[i1].flags
        local mapped
        if i < fixedLength then
            mapped = self:instantiateMappedTypeTemplate(mappedType, self:getStringLiteralType(tostring(i)), flags & ElementFlags.Optional ~= 0, fixedMapper)
        elseif flags & ElementFlags.Variadic ~= 0 then
            mapped = self:instantiateType(mappedType, checker.prependTypeMapping(typeVariable, e, m))
        else
            mapped = self:getElementTypeOfArrayType(self:instantiateType(mappedType, checker.prependTypeMapping(typeVariable, self:createArrayType(e), m)))
            if mapped == nil then
                mapped = self.unknownType
            end
        end
        -- TupleElementInfo is a Go value struct: build a new one instead of mutating.
        if modifiers & MappedTypeModifiers.IncludeOptional ~= 0 then
            if flags & ElementFlags.Required ~= 0 then
                newElementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Optional, labeledDeclaration = newElementInfos[i1].labeledDeclaration })
            end
        elseif modifiers & MappedTypeModifiers.ExcludeOptional ~= 0 then
            if flags & ElementFlags.Optional ~= 0 then
                newElementInfos[i1] = checker.TupleElementInfo_new({ flags = ElementFlags.Required, labeledDeclaration = newElementInfos[i1].labeledDeclaration })
            end
        end
        newElementTypes[i1] = mapped
    end
    local newReadonly = checker.getModifiedReadonlyState(tupleType:TargetTupleType().readonly, checker.getMappedTypeModifiers(mappedType))
    if contains(newElementTypes, self.errorType) then
        return self.errorType
    end
    return self:createTupleTypeEx(newElementTypes, newElementInfos, newReadonly)
end

function Checker:instantiateMappedTypeTemplate(t, key, isOptional, m)
    local templateMapper = checker.appendTypeMapping(m, self:getTypeParameterFromMappedType(t), key)
    local propType = self:instantiateType(self:getTemplateTypeFromMappedType(core.OrElse(t:AsMappedType().target, t)), templateMapper)
    local modifiers = checker.getMappedTypeModifiers(t)
    if self.strictNullChecks and modifiers & MappedTypeModifiers.IncludeOptional ~= 0 and not self:maybeTypeOfKind(propType, TypeFlags.Undefined | TypeFlags.Void) then
        return self:getOptionalType(propType, true --[[isProperty]])
    elseif self.strictNullChecks and modifiers & MappedTypeModifiers.ExcludeOptional ~= 0 and isOptional then
        return self:removeMissingOrUndefinedType(propType)
    else
        return propType
    end
end

function checker.getModifiedReadonlyState(state, modifiers)
    if modifiers & MappedTypeModifiers.IncludeReadonly ~= 0 then
        return true
    elseif modifiers & MappedTypeModifiers.ExcludeReadonly ~= 0 then
        return false
    end
    return state
end

function Checker:getTypeParameterFromMappedType(t)
    local m = t:AsMappedType()
    if m.typeParameter == nil then
        m.typeParameter = self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(m.declaration.typeParameter))
    end
    return m.typeParameter
end

function Checker:getConstraintTypeFromMappedType(t)
    local m = t:AsMappedType()
    if m.constraintType == nil then
        m.constraintType = core.OrElse(self:getConstraintOfTypeParameter(self:getTypeParameterFromMappedType(t)), self.errorType)
    end
    return m.constraintType
end

function Checker:getNameTypeFromMappedType(t)
    local m = t:AsMappedType()
    if m.declaration.nameType == nil then
        return nil
    end
    if m.nameType == nil then
        m.nameType = self:instantiateType(self:getTypeFromTypeNode(m.declaration.nameType), m.mapper)
    end
    return m.nameType
end

function Checker:getTemplateTypeFromMappedType(t)
    local m = t:AsMappedType()
    if m.templateType == nil then
        if m.declaration.type ~= nil then
            m.templateType = self:instantiateType(self:addOptionalityEx(self:getTypeFromTypeNode(m.declaration.type) --[[isProperty]], true, checker.getMappedTypeModifiers(t) & MappedTypeModifiers.IncludeOptional ~= 0), m.mapper)
        else
            m.templateType = self.errorType
        end
    end
    return m.templateType
end

function Checker:isMappedTypeWithKeyofConstraintDeclaration(t)
    local constraintDeclaration = self:getConstraintDeclarationForMappedType(t)
    return ast.IsTypeOperatorNode(constraintDeclaration) and constraintDeclaration:AsTypeOperatorNode().operator == Kind.KeyOfKeyword
end

function Checker:getConstraintDeclarationForMappedType(t)
    return t:AsMappedType().declaration.typeParameter:AsTypeParameterDeclaration().constraint
end

function Checker:getApparentMappedTypeKeys(nameType, targetType)
    local modifiersType = self:getApparentType(self:getModifiersTypeFromMappedType(targetType))
    local mappedKeys = nil
    self:forEachMappedTypePropertyKeyTypeAndIndexSignatureKeyType(modifiersType, TypeFlags.StringOrNumberLiteralOrUnique, false, function(t)
        mappedKeys = core.Append(mappedKeys, self:instantiateType(nameType, checker.appendTypeMapping(targetType:Mapper(), self:getTypeParameterFromMappedType(targetType), t)))
    end)
    return self:getUnionType(mappedKeys)
end

function Checker:forEachMappedTypePropertyKeyTypeAndIndexSignatureKeyType(t, include, stringsOnly, cb)
    for _, prop in ipairs(self:getPropertiesOfType(t) or {}) do
        cb(self:getLiteralTypeFromProperty(prop, include, false))
    end
    if t.flags & TypeFlags.Any ~= 0 then
        cb(self.stringType)
    else
        for _, info in ipairs(self:getIndexInfosOfType(t) or {}) do
            if not stringsOnly or info.keyType.flags & (TypeFlags.String | TypeFlags.TemplateLiteral) ~= 0 then
                cb(info.keyType)
            end
        end
    end
end

function Checker:instantiateReverseMappedType(t, m)
    local r = t:AsReverseMappedType()
    local innerMappedType = self:instantiateType(r.mappedType, m)
    if innerMappedType.objectFlags & ObjectFlags.Mapped == 0 then
        return t
    end
    local innerIndexType = self:instantiateType(r.constraintType, m)
    if innerIndexType.flags & TypeFlags.Index == 0 then
        return t
    end
    local instantiated = self:inferTypeForHomomorphicMappedType(self:instantiateType(r.source, m), innerMappedType, innerIndexType)
    if instantiated ~= nil then
        return instantiated
    end
    return t
    -- Nested invocation of `inferTypeForHomomorphicMappedType` or the `source` instantiated into something unmappable
end

function Checker:instantiateTypeAlias(alias, m)
    if alias == nil then
        return nil
    end
    return checker.TypeAlias_new({ symbol = alias.symbol, typeArguments = self:instantiateTypes(alias.typeArguments, m) })
end

function Checker:instantiateTypes(types, m)
    return checker.instantiateList(self, types, m, Checker.instantiateType)
end

function Checker:instantiateSymbols(symbols, m)
    return checker.instantiateList(self, symbols, m, Checker.instantiateSymbol)
end

function Checker:instantiateSignatures(signatures, m)
    return checker.instantiateList(self, signatures, m, Checker.instantiateSignature)
end

function Checker:instantiateIndexInfos(indexInfos, m)
    return checker.instantiateList(self, indexInfos, m, Checker.instantiateIndexInfo)
end

function checker.instantiateList(c, values, m, instantiator)
    if values == nil then
        return nil
    end
    local n = #values
    for i = 1, n do
        local value = values[i]
        local mapped = instantiator(c, value, m)
        if mapped ~= value then
            local result = {}
            for k = 1, i - 1 do
                result[k] = values[k]
            end
            result[i] = mapped
            for j = i + 1, n do
                result[j] = instantiator(c, values[j], m)
            end
            return result
        end
    end
    return values
end

function Checker:tryGetTypeFromTypeNode(node)
    local typeNode = node:Type()
    if typeNode ~= nil then
        return self:getTypeFromTypeNode(typeNode)
    end
    return nil
end

function Checker:getTypeFromTypeNode(node)
    return self:getConditionalFlowTypeOfType(self:getTypeFromTypeNodeWorker(node), node)
end

local getTypeFromTypeNodeWorkerDispatch = {
    [Kind.AnyKeyword] = function(c)
        return c.anyType
    end,
    [Kind.JSDocAllType] = function(c)
        return c.anyType
    end,
    [Kind.JSDocNonNullableType] = function(c, node)
        return c:getTypeFromTypeNode(node:Type())
    end,
    [Kind.JSDocNullableType] = function(c, node)
        local t = c:getTypeFromTypeNode(node:Type())
        if c.strictNullChecks then
            return c:getNullableType(t, TypeFlags.Null)
        else
            return t
        end
    end,
    [Kind.JSDocVariadicType] = function(c, node)
        return c:createArrayType(c:getTypeFromTypeNode(node:AsJSDocVariadicType().type))
    end,
    [Kind.JSDocOptionalType] = function(c, node)
        return c:addOptionality(c:getTypeFromTypeNode(node:Type()))
    end,
    [Kind.UnknownKeyword] = function(c)
        return c.unknownType
    end,
    [Kind.StringKeyword] = function(c)
        return c.stringType
    end,
    [Kind.NumberKeyword] = function(c)
        return c.numberType
    end,
    [Kind.BigIntKeyword] = function(c)
        return c.bigintType
    end,
    [Kind.BooleanKeyword] = function(c)
        return c.booleanType
    end,
    [Kind.SymbolKeyword] = function(c)
        return c.esSymbolType
    end,
    [Kind.VoidKeyword] = function(c)
        return c.voidType
    end,
    [Kind.UndefinedKeyword] = function(c)
        return c.undefinedType
    end,
    [Kind.NullKeyword] = function(c)
        return c.nullType
    end,
    [Kind.NeverKeyword] = function(c)
        return c.neverType
    end,
    [Kind.ObjectKeyword] = function(c)
        return c.nonPrimitiveType
    end,
    [Kind.IntrinsicKeyword] = function(c)
        return c.intrinsicMarkerType
    end,
    [Kind.ThisType] = function(c, node)
        return c:getTypeFromThisTypeNode(node)
    end,
    [Kind.ThisKeyword] = function(c, node)
        return c:getTypeFromThisTypeNode(node)
    end,
    [Kind.LiteralType] = function(c, node)
        return c:getTypeFromLiteralTypeNode(node)
    end,
    [Kind.TypeReference] = function(c, node)
        return c:getTypeFromTypeReference(node)
    end,
    [Kind.ExpressionWithTypeArguments] = function(c, node)
        return c:getTypeFromTypeReference(node)
    end,
    [Kind.TypePredicate] = function(c, node)
        if node:AsTypePredicateNode().assertsModifier ~= nil then
            return c.voidType
        end
        return c.booleanType
    end,
    [Kind.TypeQuery] = function(c, node)
        return c:getTypeFromTypeQueryNode(node)
    end,
    [Kind.ArrayType] = function(c, node)
        return c:getTypeFromArrayOrTupleTypeNode(node)
    end,
    [Kind.TupleType] = function(c, node)
        return c:getTypeFromArrayOrTupleTypeNode(node)
    end,
    [Kind.OptionalType] = function(c, node)
        return c:getTypeFromOptionalTypeNode(node)
    end,
    [Kind.UnionType] = function(c, node)
        return c:getTypeFromUnionTypeNode(node)
    end,
    [Kind.IntersectionType] = function(c, node)
        return c:getTypeFromIntersectionTypeNode(node)
    end,
    [Kind.NamedTupleMember] = function(c, node)
        return c:getTypeFromNamedTupleTypeNode(node)
    end,
    [Kind.ParenthesizedType] = function(c, node)
        return c:getTypeFromTypeNode(node:Type())
    end,
    [Kind.RestType] = function(c, node)
        return c:getTypeFromRestTypeNode(node)
    end,
    [Kind.FunctionType] = function(c, node)
        return c:getTypeFromTypeLiteralOrFunctionOrConstructorTypeNode(node)
    end,
    [Kind.ConstructorType] = function(c, node)
        return c:getTypeFromTypeLiteralOrFunctionOrConstructorTypeNode(node)
    end,
    [Kind.TypeLiteral] = function(c, node)
        return c:getTypeFromTypeLiteralOrFunctionOrConstructorTypeNode(node)
    end,
    [Kind.TypeOperator] = function(c, node)
        return c:getTypeFromTypeOperatorNode(node)
    end,
    [Kind.IndexedAccessType] = function(c, node)
        return c:getTypeFromIndexedAccessTypeNode(node)
    end,
    [Kind.TemplateLiteralType] = function(c, node)
        return c:getTypeFromTemplateTypeNode(node)
    end,
    [Kind.MappedType] = function(c, node)
        return c:getTypeFromMappedTypeNode(node)
    end,
    [Kind.ConditionalType] = function(c, node)
        return c:getTypeFromConditionalTypeNode(node)
    end,
    [Kind.InferType] = function(c, node)
        return c:getTypeFromInferTypeNode(node)
    end,
    [Kind.ImportType] = function(c, node)
        return c:getTypeFromImportTypeNode(node)
    end,
}

function Checker:getTypeFromTypeNodeWorker(node)
    local f = getTypeFromTypeNodeWorkerDispatch[node.kind]
    if f ~= nil then
        return f(self, node)
    end
    return self.errorType
end

function Checker:getTypeFromThisTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        links.resolvedType = self:getThisType(node)
    end
    return links.resolvedType
end

function Checker:getThisType(node)
    local container = ast.GetThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    if container ~= nil then
        local parent = container.parent
        if parent ~= nil and (ast.IsClassLike(parent) or ast.IsInterfaceDeclaration(parent)) then
            if not ast.IsStatic(container) and (not ast.IsConstructorDeclaration(container) or checker.isNodeDescendantOf(node, container:Body())) then
                return core.Coalesce(self:getDeclaredTypeOfClassOrInterface(self:getSymbolOfDeclaration(parent)):AsInterfaceType().thisType, self.errorType)
            end
        end
    end
    self:error(node, diagnostics.A_this_type_is_available_only_in_a_non_static_member_of_a_class_or_interface)
    return self.errorType
end

function Checker:getTypeFromLiteralTypeNode(node)
    if node:AsLiteralTypeNode().literal.kind == Kind.NullKeyword then
        return self.nullType
    end
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        links.resolvedType = self:getRegularTypeOfLiteralType(self:checkExpression(node:AsLiteralTypeNode().literal))
    end
    return links.resolvedType
end

function Checker:getTypeFromTypeLiteralOrFunctionOrConstructorTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        -- Deferred resolution of members is handled by resolveObjectTypeMembers
        local alias = self:getAliasForTypeNode(node)
        local sym = node:Symbol()
        if sym == nil or next(self:getMembersOfSymbol(sym) or {}) == nil and alias == nil then
            links.resolvedType = self.emptyTypeLiteralType
        else
            local t = self:newObjectType(ObjectFlags.Anonymous, node:Symbol())
            t.alias = alias
            links.resolvedType = t
        end
    end
    return links.resolvedType
end

function Checker:getTypeFromIndexedAccessTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local objectType = self:getTypeFromTypeNode(node:AsIndexedAccessTypeNode().objectType)
        local indexType = self:getTypeFromTypeNode(node:AsIndexedAccessTypeNode().indexType)
        local potentialAlias = self:getAliasForTypeNode(node)
        links.resolvedType = self:getIndexedAccessTypeEx(objectType, indexType, AccessFlags.None, node, potentialAlias)
    end
    return links.resolvedType
end

function Checker:getTypeFromTypeOperatorNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local argType = node:Type()
        local operator = node:AsTypeOperatorNode().operator
        if operator == Kind.KeyOfKeyword then
            links.resolvedType = self:getIndexType(self:getTypeFromTypeNode(argType))
        elseif operator == Kind.UniqueKeyword then
            if argType.kind == Kind.SymbolKeyword then
                links.resolvedType = self:getESSymbolLikeTypeForNode(ast.WalkUpParenthesizedTypes(node.parent))
            else
                links.resolvedType = self.errorType
            end
        elseif operator == Kind.ReadonlyKeyword then
            links.resolvedType = self:getTypeFromTypeNode(argType)
        else
            error("Unhandled case in getTypeFromTypeOperatorNode", 0)
        end
    end
    return links.resolvedType
end

function Checker:getESSymbolLikeTypeForNode(node)
    if checker.isValidESSymbolDeclaration(node) then
        local symbol = self:getSymbolOfNode(node)
        if symbol ~= nil then
            local uniqueType = self.uniqueESSymbolTypes[symbol]
            if uniqueType == nil then
                local name = ast.InternalSymbolNamePrefix .. "@" .. symbol.name .. "@" .. string.format("%d", ast.GetSymbolId(symbol))
                uniqueType = self:newUniqueESSymbolType(symbol, name)
                self.uniqueESSymbolTypes[symbol] = uniqueType
            end
            return uniqueType
        end
    end
    return self.esSymbolType
end

function Checker:getTypeFromTypeReference(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        -- Cache both the resolved symbol and the resolved type. The resolved symbol is needed when we check the
        -- type reference in checkTypeReferenceNode.
        -- handle LS queries on the `const` in `x as const` by resolving to the type of `x`
        if checker.isConstTypeReference(node) and ast.IsAssertionExpression(node.parent) then
            links.resolvedType = self:checkExpressionCached(node.parent:Expression())
        else
            local t = self:getIntendedTypeFromJSDocTypeReference(node)
            if t ~= nil then
                links.resolvedType = t
            else
                links.resolvedType = self:getTypeReferenceType(node, self:getSymbolFromTypeReference(node))
            end
        end
    end
    return links.resolvedType
end

function Checker:getIntendedTypeFromJSDocTypeReference(node)
    if node.flags & NodeFlags.JSDoc ~= 0 and ast.IsTypeReferenceNode(node) then
        local typeName = node:AsTypeReferenceNode().typeName
        if ast.IsIdentifier(typeName) then
            local typeArgs = node:TypeArguments()
            local text = typeName:Text()
            if text == "String" then
                self:checkNoTypeArguments(node, nil)
                return self.stringType
            elseif text == "Number" then
                self:checkNoTypeArguments(node, nil)
                return self.numberType
            elseif text == "BigInt" then
                self:checkNoTypeArguments(node, nil)
                return self.bigintType
            elseif text == "Boolean" then
                self:checkNoTypeArguments(node, nil)
                return self.booleanType
            elseif text == "Void" then
                self:checkNoTypeArguments(node, nil)
                return self.voidType
            elseif text == "Undefined" then
                self:checkNoTypeArguments(node, nil)
                return self.undefinedType
            elseif text == "Null" then
                self:checkNoTypeArguments(node, nil)
                return self.nullType
            elseif text == "Function" or text == "function" then
                self:checkNoTypeArguments(node, nil)
                return self.globalFunctionType
            elseif text == "array" then
                if core.Len(typeArgs) == 0 and not self.noImplicitAny then
                    return self.anyArrayType
                end
            elseif text == "promise" then
                if core.Len(typeArgs) == 0 and not self.noImplicitAny then
                    return self:createPromiseType(self.anyType)
                end
            elseif text == "Object" then
                if core.Len(typeArgs) == 2 then
                    local recordSymbol = self.getGlobalRecordSymbol()
                    if recordSymbol ~= nil then
                        local indexType = self:getTypeFromTypeNode(typeArgs[1])
                        if self:isValidIndexKeyType(indexType) then
                            return self:getTypeAliasInstantiation(recordSymbol, { indexType, self:getTypeFromTypeNode(typeArgs[2]) }, nil)
                        end
                    end
                    return self.anyType
                end
                if not self.noImplicitAny then
                    self:checkNoTypeArguments(node, nil)
                    return self.anyType
                end
            end
        end
    end
    return nil
end

function Checker:getSymbolFromTypeReference(node)
    local links = self.symbolNodeLinks:Get(node)
    if links.resolvedSymbol == nil then
        -- The `const` in a `const` assertion resolves to nothing; resolveName knows not to
        -- report an error for it, so no special-casing is needed here.
        links.resolvedSymbol = self:resolveTypeReferenceName(node, SymbolFlags.Type, false --[[ignoreErrors]])
    end
    return links.resolvedSymbol
end

function Checker:resolveTypeReferenceName(typeReference, meaning, ignoreErrors)
    local name = checker.getTypeReferenceName(typeReference)
    if name == nil then
        return self.unknownSymbol
    end
    local symbol = self:resolveEntityName(name, meaning, ignoreErrors, false --[[dontResolveAlias]], nil --[[location]])
    if symbol ~= nil and symbol ~= self.unknownSymbol then
        return symbol
    end
    if ignoreErrors then
        return self.unknownSymbol
    end
    return self:getUnresolvedSymbolForEntityName(name)
end

function Checker:getUnresolvedSymbolForEntityName(name)
    local identifier
    if name.kind == Kind.QualifiedName then
        identifier = name:AsQualifiedName().right
    elseif name.kind == Kind.PropertyAccessExpression then
        identifier = name:Name()
    else
        identifier = name
    end
    local text = identifier:Text()
    if text ~= "" then
        local parentSymbol = nil
        if name.kind == Kind.QualifiedName then
            parentSymbol = self:getUnresolvedSymbolForEntityName(name:AsQualifiedName().left)
        elseif name.kind == Kind.PropertyAccessExpression then
            parentSymbol = self:getUnresolvedSymbolForEntityName(name:Expression())
        end
        local path
        if parentSymbol ~= nil then
            path = checker.getSymbolPath(parentSymbol) .. "." .. text
        else
            path = text
        end
        local result = self.unresolvedSymbols[path]
        if result == nil then
            result = self:newSymbolEx(SymbolFlags.TypeAlias, text, CheckFlags.Unresolved)
            self.unresolvedSymbols[path] = result
            result.parent = parentSymbol
            self.typeAliasLinks:Get(result).declaredType = self.unresolvedType
        end
        return result
    end
    return self.unknownSymbol
end

function checker.getSymbolPath(symbol)
    if symbol.parent ~= nil then
        return checker.getSymbolPath(symbol.parent) .. "." .. symbol.name
    end
    return symbol.name
end

function Checker:getTypeReferenceType(node, symbol)
    if symbol == self.unknownSymbol then
        return self.errorType
    end
    if symbol.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
        return self:getTypeFromClassOrInterfaceReference(node, symbol)
    end
    if symbol.flags & SymbolFlags.TypeAlias ~= 0 then
        return self:getTypeFromTypeAliasReference(node, symbol)
    end
    -- Get type from reference to named type that cannot be generic (enum or type parameter)
    local res = self:tryGetDeclaredTypeOfSymbol(symbol)
    if res ~= nil and self:checkNoTypeArguments(node, symbol) then
        return self:getRegularTypeOfLiteralType(res)
    end

    -- !!! Resolving values as types for JS
    return self.errorType
end
