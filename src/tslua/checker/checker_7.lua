local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local debug = require("tslua.debug")
local evaluator = require("tslua.evaluator")
local scanner = require("tslua.scanner")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local AccessFlags = checker.AccessFlags
local UnionReduction = checker.UnionReduction
local IntersectionFlags = checker.IntersectionFlags
local CachedTypeKind = checker.CachedTypeKind
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local MappedTypeModifiers = checker.MappedTypeModifiers
local TypeFormatFlags = checker.TypeFormatFlags
local Ternary = checker.Ternary
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
    local b = checker.keyBuilder_new({ inlineBuffer = {} }) -- Go: var b keyBuilder
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
                return FindAncestorResult.FindAncestorTrue
            elseif n.kind == Kind.ModuleDeclaration then
                return FindAncestorResult.FindAncestorFalse
            end
            return FindAncestorResult.FindAncestorQuit
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

--[[
 * Get type from type-reference that reference to class or interface
]]
function Checker:getTypeFromClassOrInterfaceReference(node, symbol)
    local t = self:getDeclaredTypeOfClassOrInterface(self:getMergedSymbol(symbol))
    local d = t:AsInterfaceType()
    local typeParameters = d:LocalTypeParameters()
    if core.Len(typeParameters) ~= 0 then
        local numTypeArguments = core.Len(node:TypeArguments())
        local minTypeArgumentCount = self:getMinTypeArgumentCount(typeParameters)
        local isJs = ast.IsInJSFile(node)
        local isJsImplicitAny = not self.noImplicitAny and isJs
        if not isJsImplicitAny and (numTypeArguments < minTypeArgumentCount or numTypeArguments > #typeParameters) then
            local message

            local missingAugmentsTag = isJs and ast.IsExpressionWithTypeArguments(node) and not ast.IsJSDocAugmentsTag(node.parent)
            if missingAugmentsTag then
                message = diagnostics.Expected_0_type_arguments_provide_these_with_an_extends_tag
                if minTypeArgumentCount < #typeParameters then
                    message = diagnostics.Expected_0_1_type_arguments_provide_these_with_an_extends_tag
                end
            else
                message = diagnostics.Generic_type_0_requires_1_type_argument_s
                if minTypeArgumentCount < #typeParameters then
                    message = diagnostics.Generic_type_0_requires_between_1_and_2_type_arguments
                end
            end
            local typeStr = self:TypeToStringEx(t, nil --[[enclosingDeclaration]], TypeFormatFlags.WriteArrayAsGenericType, nil)
            self:error(node, message, typeStr, minTypeArgumentCount, #typeParameters)
            if not isJs then
                -- TODO: Adopt same permissive behavior in TS as in JS to reduce follow-on editing experience failures (requires editing fillMissingTypeArguments)
                return self.errorType
            end
        end
        if node.kind == Kind.TypeReference and self:isDeferredTypeReferenceNode(node, numTypeArguments ~= #typeParameters) then
            return self:createDeferredTypeReference(t, node, nil --[[mapper]], nil --[[alias]])
        end
        -- In a type reference, the outer type parameters of the referenced class or interface are automatically
        -- supplied as type arguments and the type reference only specifies arguments for the local type parameters
        -- of the class or interface.
        local localTypeArguments = self:fillMissingTypeArguments(self:getTypeArgumentsFromNode(node), typeParameters, minTypeArgumentCount, isJs)
        local typeArguments = core.AppendAll(d:OuterTypeParameters(), localTypeArguments)
        return self:createTypeReferenceEx(t, typeArguments, checker.ObjectFlagsFromTypeNode)
    end
    if self:checkNoTypeArguments(node, symbol) then
        return t
    end
    return self.errorType
end

function Checker:getTypeArgumentsFromNode(node)
    return core.Map(node:TypeArguments(), function(n) return self:getTypeFromTypeNode(n) end)
end

function Checker:checkNoTypeArguments(node, symbol)
    if core.Len(node:TypeArguments()) ~= 0 then
        local typeName
        if symbol ~= nil then
            typeName = self:symbolToString(symbol)
        else
            typeName = scanner.DeclarationNameToString(node:AsTypeReferenceNode().typeName)
        end
        self:error(node, diagnostics.Type_0_is_not_generic, typeName)
        return false
    end
    return true
end

-- Return true if the given type reference node is directly aliased or if it needs to be deferred
-- because it is possibly contained in a circular chain of eagerly resolved types.
function Checker:isDeferredTypeReferenceNode(node, hasDefaultTypeArguments)
    if self:getAliasSymbolForTypeNode(node) ~= nil then
        return true
    end
    if self:isResolvedByTypeAlias(node) then
        if node.kind == Kind.ArrayType then
            return self:mayResolveTypeAlias(node:AsArrayTypeNode().elementType)
        elseif node.kind == Kind.TupleType then
            return core.Some(node:Elements(), function(e) return self:mayResolveTypeAlias(e) end)
        elseif node.kind == Kind.TypeReference then
            return hasDefaultTypeArguments or core.Some(node:TypeArguments(), function(e) return self:mayResolveTypeAlias(e) end)
        end
        error("Unhandled case in isDeferredTypeReferenceNode", 0)
    end
    return false
end

local resolvedByTypeAliasParentKinds = ast.kindSet(Kind.ParenthesizedType, Kind.NamedTupleMember, Kind.TypeReference, Kind.UnionType, Kind.IntersectionType,
    Kind.IndexedAccessType, Kind.ConditionalType, Kind.TypeOperator, Kind.ArrayType, Kind.TupleType)

-- Return true when the given node is transitively contained in type constructs that eagerly
-- resolve their constituent types. We include SyntaxKind.TypeReference because type arguments
-- of type aliases are eagerly resolved.
function Checker:isResolvedByTypeAlias(node)
    local parent = node.parent
    if resolvedByTypeAliasParentKinds[parent.kind] then
        return self:isResolvedByTypeAlias(parent)
    elseif parent.kind == Kind.TypeAliasDeclaration or parent.kind == Kind.JSTypeAliasDeclaration then
        return true
    end
    return false
end

-- Return true if resolving the given node (i.e. getTypeFromTypeNode) possibly causes resolution
-- of a type alias.
function Checker:mayResolveTypeAlias(node)
    local kind = node.kind
    local f = function(n) return self:mayResolveTypeAlias(n) end
    if kind == Kind.TypeReference then
        return self:resolveTypeReferenceName(node, SymbolFlags.Type, false).flags & SymbolFlags.TypeAlias ~= 0
    elseif kind == Kind.TypeQuery then
        return true
    elseif kind == Kind.TypeOperator then
        return node:AsTypeOperatorNode().operator ~= Kind.UniqueKeyword and self:mayResolveTypeAlias(node:Type())
    elseif kind == Kind.ParenthesizedType or kind == Kind.OptionalType or kind == Kind.NamedTupleMember then
        return self:mayResolveTypeAlias(node:Type())
    elseif kind == Kind.RestType then
        return node:Type().kind ~= Kind.ArrayType or self:mayResolveTypeAlias(node:Type():AsArrayTypeNode().elementType)
    elseif kind == Kind.UnionType then
        return core.Some(node:AsUnionTypeNode().types.nodes, f)
    elseif kind == Kind.IntersectionType then
        return core.Some(node:AsIntersectionTypeNode().types.nodes, f)
    elseif kind == Kind.IndexedAccessType then
        return self:mayResolveTypeAlias(node:AsIndexedAccessTypeNode().objectType) or self:mayResolveTypeAlias(node:AsIndexedAccessTypeNode().indexType)
    elseif kind == Kind.ConditionalType then
        return self:mayResolveTypeAlias(node:AsConditionalTypeNode().checkType) or self:mayResolveTypeAlias(node:AsConditionalTypeNode().extendsType) or
            self:mayResolveTypeAlias(node:AsConditionalTypeNode().trueType) or self:mayResolveTypeAlias(node:AsConditionalTypeNode().falseType)
    end
    return false
end

function Checker:createNormalizedTypeReference(target, typeArguments)
    if target.objectFlags & ObjectFlags.Tuple ~= 0 then
        return self:createNormalizedTupleType(target, typeArguments)
    end
    return self:createTypeReference(target, typeArguments)
end

function Checker:createNormalizedTupleTypeEx(target, elementTypes, objectFlags)
    local d = target:AsTupleType()
    if d.combinedFlags & ElementFlags.NonRequired == 0 then
        -- No need to normalize when we only have regular required elements
        return self:createTypeReferenceEx(target, elementTypes, objectFlags)
    end
    local numInfos = core.Len(d.elementInfos)
    if d.combinedFlags & ElementFlags.Variadic ~= 0 then
        for i1, e in ipairs(elementTypes or {}) do
            local i = i1 - 1
            if i < numInfos and d.elementInfos[i1].flags & ElementFlags.Variadic ~= 0 and e.flags & (TypeFlags.Never | TypeFlags.Union) ~= 0 then
                -- Transform [A, ...(X | Y | Z)] into [A, ...X] | [A, ...Y] | [A, ...Z]
                local checkTypes = core.MapIndex(elementTypes, function(t, j)
                    if j < numInfos and d.elementInfos[j + 1].flags & ElementFlags.Variadic ~= 0 then
                        return t
                    end
                    return self.unknownType
                end)
                if self:checkCrossProductUnion(checkTypes) then
                    return self:mapType(e, function(t)
                        return self:createNormalizedTupleTypeEx(target, core.ReplaceElement(elementTypes, i, t), objectFlags)
                    end)
                end
            end
        end
    end
    -- We have optional, rest, or variadic elements that may need normalizing. Normalization ensures that all variadic
    -- elements are generic and that the tuple type has one of the following layouts, disregarding variadic elements:
    -- (1) Zero or more required elements, followed by zero or more optional elements, followed by zero or one rest element.
    -- (2) Zero or more required elements, followed by a rest element, followed by zero or more required elements.
    -- In either layout, zero or more generic variadic elements may be present at any location.
    -- Note that the element types may contain an extra 'this' type argument that we want to ignore during normalization
    -- and then just append to the normalized element types.
    local n = checker.TupleNormalizer_new()
    if not n:normalize(self, core.Slice(elementTypes, 0, numInfos), d.elementInfos) then
        return self.errorType
    end
    if core.Len(elementTypes) > numInfos then
        n.types = core.Append(n.types, elementTypes[numInfos + 1])
    end
    local tupleTarget = self:getTupleTargetType(n.infos, d.readonly)
    if tupleTarget == self.emptyGenericType then
        return self.emptyObjectType
    elseif core.Len(n.types) ~= 0 then
        return self:createTypeReferenceEx(tupleTarget, n.types, objectFlags)
    end
    return tupleTarget
end

function Checker:createNormalizedTupleType(target, elementTypes)
    return self:createNormalizedTupleTypeEx(target, elementTypes, ObjectFlags.None)
end

-- TupleNormalizer: { c, types, infos, lastRequiredIndex, firstRestIndex, lastOptionalOrRestIndex }.
-- infos holds TupleElementInfo values, which are never mutated in place.
local TupleNormalizer = checker.defineStruct("TupleNormalizer", nil, {
    lastRequiredIndex = 0,
    firstRestIndex = 0,
    lastOptionalOrRestIndex = 0,
})

function TupleNormalizer:normalize(c, elementTypes, elementInfos)
    self.c = c
    self.lastRequiredIndex = -1
    self.firstRestIndex = -1
    self.lastOptionalOrRestIndex = -1
    for i, t in ipairs(elementTypes or {}) do
        local info = elementInfos[i]
        if info.flags & ElementFlags.Variadic ~= 0 then
            if t.flags & TypeFlags.Any ~= 0 then
                self:add(t, checker.TupleElementInfo_new({ flags = ElementFlags.Rest, labeledDeclaration = info.labeledDeclaration }))
            elseif t.flags & TypeFlags.InstantiableNonPrimitive ~= 0 or c:isGenericMappedType(t) then
                -- Generic variadic elements stay as they are.
                self:add(t, info)
            elseif checker.isTupleType(t) then
                local spreadTypes = c:getElementTypes(t)
                if core.Len(spreadTypes) + core.Len(self.types) >= 10000 then
                    local message = core.IfElse(ast.IsPartOfTypeNode(c.currentNode),
                        diagnostics.Type_produces_a_tuple_type_that_is_too_large_to_represent,
                        diagnostics.Expression_produces_a_tuple_type_that_is_too_large_to_represent)
                    c:error(c.currentNode, message)
                    return false
                end
                -- Spread variadic elements with tuple types into the resulting tuple.
                local spreadInfos = t:TargetTupleType().elementInfos
                for j, s in ipairs(spreadTypes or {}) do
                    self:add(s, spreadInfos[j])
                end
            else
                -- Treat everything else as an array type and create a rest element.
                local s = nil
                if c:isArrayLikeType(t) then
                    s = c:getIndexTypeOfType(t, c.numberType)
                end
                if s == nil then
                    s = c.errorType
                end
                self:add(s, checker.TupleElementInfo_new({ flags = ElementFlags.Rest, labeledDeclaration = info.labeledDeclaration }))
            end
        else
            -- Copy other element kinds with no change.
            self:add(t, info)
        end
    end
    -- Turn optional elements preceding the last required element into required elements
    for i = 1, self.lastRequiredIndex do
        local info = self.infos[i]
        if info.flags & ElementFlags.Optional ~= 0 then
            self.infos[i] = checker.TupleElementInfo_new({ flags = ElementFlags.Required, labeledDeclaration = info.labeledDeclaration })
        end
    end
    if self.firstRestIndex >= 0 and self.firstRestIndex < self.lastOptionalOrRestIndex then
        -- Turn elements between first rest and last optional/rest into a single rest element
        local types = nil
        for i = self.firstRestIndex, self.lastOptionalOrRestIndex do
            local t = self.types[i + 1]
            if self.infos[i + 1].flags & ElementFlags.Variadic ~= 0 then
                t = c:getIndexedAccessType(t, c.numberType)
            end
            types = core.Append(types, t)
        end
        self.types[self.firstRestIndex + 1] = c:getUnionType(types)
        -- slices.Delete(xs, firstRestIndex+1, lastOptionalOrRestIndex+1)
        local deleteCount = self.lastOptionalOrRestIndex - self.firstRestIndex
        for _ = 1, deleteCount do
            table.remove(self.types, self.firstRestIndex + 2)
            table.remove(self.infos, self.firstRestIndex + 2)
        end
    end
    return true
end

function TupleNormalizer:add(t, info)
    if info.flags & ElementFlags.Required ~= 0 then
        self.lastRequiredIndex = core.Len(self.types)
    end
    if info.flags & ElementFlags.Rest ~= 0 and self.firstRestIndex < 0 then
        self.firstRestIndex = core.Len(self.types)
    end
    if info.flags & (ElementFlags.Optional | ElementFlags.Rest) ~= 0 then
        self.lastOptionalOrRestIndex = core.Len(self.types)
    end
    self.types = core.Append(self.types, self.c:addOptionalityEx(t, true --[[isProperty]], info.flags & ElementFlags.Optional ~= 0))
    self.infos = core.Append(self.infos, info)
end

-- Return count of starting consecutive tuple elements of the given kind(s)
function checker.getStartElementCount(t, flags)
    for i, info in ipairs(t.elementInfos or {}) do
        if info.flags & flags == 0 then
            return i - 1
        end
    end
    return core.Len(t.elementInfos)
end

-- Return count of ending consecutive tuple elements of the given kind(s)
function checker.getEndElementCount(t, flags)
    local n = core.Len(t.elementInfos)
    for i = n, 1, -1 do
        if t.elementInfos[i].flags & flags == 0 then
            return n - i
        end
    end
    return n
end

function checker.getTotalFixedElementCount(t)
    return t.fixedLength + checker.getEndElementCount(t, ElementFlags.Fixed)
end

function Checker:getElementTypes(t)
    local typeArguments = self:getTypeArguments(t)
    local arity = self:getTypeReferenceArity(t)
    if core.Len(typeArguments) == arity then
        return typeArguments
    end
    return core.Slice(typeArguments, 0, arity)
end

function Checker:getTypeReferenceArity(t)
    return core.Len(t:TargetInterfaceType():TypeParameters())
end

function Checker:isArrayType(t)
    return t.objectFlags & ObjectFlags.Reference ~= 0 and (t:Target() == self.globalArrayType or t:Target() == self.globalReadonlyArrayType)
end

function Checker:isReadonlyArrayType(t)
    return t.objectFlags & ObjectFlags.Reference ~= 0 and t:Target() == self.globalReadonlyArrayType
end

function checker.isTupleType(t)
    return t.objectFlags & ObjectFlags.Reference ~= 0 and t:Target().objectFlags & ObjectFlags.Tuple ~= 0
end

function checker.isMutableTupleType(t)
    return checker.isTupleType(t) and not t:TargetTupleType().readonly
end

function checker.isGenericTupleType(t)
    return checker.isTupleType(t) and t:TargetTupleType().combinedFlags & ElementFlags.Variadic ~= 0
end

function checker.isSingleElementGenericTupleType(t)
    return checker.isGenericTupleType(t) and core.Len(t:TargetTupleType().elementInfos) == 1
end

function Checker:isArrayOrTupleType(t)
    return self:isArrayType(t) or checker.isTupleType(t)
end

function Checker:isMutableArrayOrTuple(t)
    return self:isArrayType(t) and not self:isReadonlyArrayType(t) or checker.isTupleType(t) and not t:TargetTupleType().readonly
end

function Checker:getElementTypeOfArrayType(t)
    if self:isArrayType(t) then
        return self:getTypeArguments(t)[1]
    end
    return nil
end

function Checker:isArrayLikeType(t)
    -- A type is array-like if it is a reference to the global Array or global ReadonlyArray type,
    -- or if it is not the undefined or null type and if it is assignable to ReadonlyArray<any>
    return self:isArrayType(t) or t.flags & TypeFlags.Nullable == 0 and self:isTypeAssignableTo(t, self.anyReadonlyArrayType)
end

function Checker:isMutableArrayLikeType(t)
    -- A type is mutable-array-like if it is a reference to the global Array type, or if it is not the
    -- any, undefined or null type and if it is assignable to Array<any>
    return self:isMutableArrayOrTuple(t) or t.flags & (TypeFlags.Any | TypeFlags.Nullable) == 0 and self:isTypeAssignableTo(t, self.anyArrayType)
end

function Checker:isEmptyArrayLiteralType(t)
    local elementType = self:getElementTypeOfArrayType(t)
    return elementType ~= nil and self:isEmptyLiteralType(elementType)
end

function Checker:isEmptyLiteralType(t)
    if self.strictNullChecks then
        return t == self.implicitNeverType
    end
    return t == self.undefinedWideningType
end

function Checker:isTupleLikeType(t)
    if checker.isTupleType(t) or self:getPropertyOfType(t, "0") ~= nil then
        return true
    end
    if self:isArrayLikeType(t) then
        local lengthType = self:getTypeOfPropertyOfType(t, "length")
        if lengthType ~= nil then
            return checker.everyType(lengthType, function(lt) return lt.flags & TypeFlags.NumberLiteral ~= 0 end)
        end
    end
    return false
end

function Checker:isArrayOrTupleLikeType(t)
    return self:isArrayLikeType(t) or self:isTupleLikeType(t)
end

function Checker:isArrayOrTupleOrIntersection(t)
    return t.flags & TypeFlags.Intersection ~= 0 and core.Every(t:Types(), function(e) return self:isArrayOrTupleType(e) end)
end

function Checker:getTupleElementType(t, index)
    local propType = self:getTypeOfPropertyOfType(t, tostring(index))
    if propType ~= nil then
        return propType
    end
    if checker.everyType(t, checker.isTupleType) then
        return self:getTupleElementTypeOutOfStartCount(t, index + 0.0, core.IfElse(self.compilerOptions.noUncheckedIndexedAccess == core.Tristate.TSTrue, self.undefinedType, nil))
    end
    return nil
end

--[[
 * Get type from reference to type alias. When a type alias is generic, the declared type of the type alias may include
 * references to the type parameters of the alias. We replace those with the actual type arguments by instantiating the
 * declared type. Instantiations are cached using the type identities of the type arguments as the key.
]]
function Checker:getTypeFromTypeAliasReference(node, symbol)
    local typeArguments = node:TypeArguments()
    if symbol.checkFlags & CheckFlags.Unresolved ~= 0 then
        local alias = checker.TypeAlias_new({ symbol = symbol, typeArguments = core.Map(typeArguments, function(n) return self:getTypeFromTypeNode(n) end) })
        local key = checker.getAliasKey(alias)
        local errorType = self.errorTypes[key]
        if errorType == nil then
            errorType = self:newIntrinsicType(TypeFlags.Any, "error")
            errorType.alias = alias
            self.errorTypes[key] = errorType
        end
        return errorType
    end
    local t = self:getDeclaredTypeOfSymbol(symbol)
    local typeParameters = self.typeAliasLinks:Get(symbol).typeParameters
    if core.Len(typeParameters) ~= 0 then
        local numTypeArguments = core.Len(typeArguments)
        local minTypeArgumentCount = self:getMinTypeArgumentCount(typeParameters)
        if numTypeArguments < minTypeArgumentCount or numTypeArguments > #typeParameters then
            local message = core.IfElse(minTypeArgumentCount == #typeParameters,
                diagnostics.Generic_type_0_requires_1_type_argument_s,
                diagnostics.Generic_type_0_requires_between_1_and_2_type_arguments)
            self:error(node, message, self:symbolToString(symbol), minTypeArgumentCount, #typeParameters)
            return self.errorType
        end
        -- We refrain from associating a local type alias with an instantiation of a top-level type alias
        -- because the local alias may end up being referenced in an inferred return type where it is not
        -- accessible--which in turn may lead to a large structural expansion of the type when generating
        -- a .d.ts file. See #43622 for an example.
        local aliasSymbol = self:getAliasSymbolForTypeNode(node)
        local newAliasSymbol = nil
        if aliasSymbol ~= nil and (checker.isLocalTypeAlias(symbol) or not checker.isLocalTypeAlias(aliasSymbol)) then
            newAliasSymbol = aliasSymbol
        end
        local aliasTypeArguments = nil
        if newAliasSymbol ~= nil then
            aliasTypeArguments = self:getTypeArgumentsForAliasSymbol(newAliasSymbol)
        elseif ast.IsTypeReferenceType(node) then
            local referencedAliasSymbol = self:resolveTypeReferenceName(node, SymbolFlags.Alias, true --[[ignoreErrors]])
            -- refers to an alias import/export/reexport - by making sure we use the target as an aliasSymbol,
            -- we ensure the exported symbol is used to refer to the type when it is reserialized later
            if referencedAliasSymbol ~= nil and referencedAliasSymbol ~= self.unknownSymbol then
                local resolved = self:resolveAlias(referencedAliasSymbol)
                if resolved ~= nil and resolved.flags & SymbolFlags.TypeAlias ~= 0 then
                    newAliasSymbol = resolved
                    aliasTypeArguments = self:getTypeArgumentsFromNode(node)
                end
            end
        end
        local newAlias = nil
        if newAliasSymbol ~= nil then
            newAlias = checker.TypeAlias_new({ symbol = newAliasSymbol, typeArguments = aliasTypeArguments })
        end
        return self:getTypeAliasInstantiation(symbol, self:getTypeArgumentsFromNode(node), newAlias)
    end
    if self:checkNoTypeArguments(node, symbol) then
        return t
    end
    return self.errorType
end

function Checker:getTypeAliasInstantiation(symbol, typeArguments, alias)
    local t = self:getDeclaredTypeOfSymbol(symbol)
    if t == self.intrinsicMarkerType then
        local typeKind = checker.intrinsicTypeKinds[symbol.name]
        if typeKind ~= nil and core.Len(typeArguments) == 1 then
            if typeKind == checker.IntrinsicTypeKind.NoInfer then
                return self:getNoInferType(typeArguments[1])
            else
                return self:getStringMappingType(symbol, typeArguments[1])
            end
        end
    end
    local links = self.typeAliasLinks:Get(symbol)
    local typeParameters = links.typeParameters
    local key = checker.getTypeAliasInstantiationKey(typeArguments, alias)
    local instantiation = links.instantiations[key]
    if instantiation == nil then
        local mapper = checker.newTypeMapper(typeParameters, self:fillMissingTypeArguments(typeArguments, typeParameters, self:getMinTypeArgumentCount(typeParameters), ast.IsInJSFile(symbol.valueDeclaration)))
        instantiation = self:instantiateTypeWithAlias(t, mapper, alias)
        links.instantiations[key] = instantiation
    end
    return instantiation
end

function checker.isLocalTypeAlias(symbol)
    local declaration = core.Find(symbol.declarations, function(d) return checker.isTypeAlias(d) end)
    return declaration ~= nil and ast.GetContainingFunction(declaration) ~= nil
end

function Checker:getDeclaredTypeOfSymbol(symbol)
    local result = self:tryGetDeclaredTypeOfSymbol(symbol)
    if result == nil then
        result = self.errorType
    end
    return result
end

function Checker:tryGetDeclaredTypeOfSymbol(symbol)
    if symbol.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
        return self:getDeclaredTypeOfClassOrInterface(symbol)
    elseif symbol.flags & SymbolFlags.TypeParameter ~= 0 then
        return self:getDeclaredTypeOfTypeParameter(symbol)
    elseif symbol.flags & SymbolFlags.TypeAlias ~= 0 then
        return self:getDeclaredTypeOfTypeAlias(symbol)
    elseif symbol.flags & SymbolFlags.Enum ~= 0 then
        return self:getDeclaredTypeOfEnum(symbol)
    elseif symbol.flags & SymbolFlags.EnumMember ~= 0 then
        return self:getDeclaredTypeOfEnumMember(symbol)
    elseif symbol.flags & SymbolFlags.Alias ~= 0 then
        return self:getDeclaredTypeOfAlias(symbol)
    end
    return nil
end

function checker.getTypeReferenceName(node)
    if node.kind == Kind.TypeReference then
        return node:AsTypeReferenceNode().typeName
    elseif node.kind == Kind.ExpressionWithTypeArguments then
        -- We only support expressions that are simple qualified names. For other
        -- expressions this produces nil
        local expr = node:Expression()
        if ast.IsEntityNameExpression(expr) then
            return expr
        end
    end
    return nil
end

function Checker:getAliasForTypeNode(node)
    local symbol = self:getAliasSymbolForTypeNode(node)
    if symbol ~= nil then
        return checker.TypeAlias_new({ symbol = symbol, typeArguments = self:getTypeArgumentsForAliasSymbol(symbol) })
    end
    return nil
end

function Checker:getAliasSymbolForTypeNode(node)
    local host = node.parent
    while ast.IsParenthesizedTypeNode(host) or ast.IsTypeOperatorNode(host) and host:AsTypeOperatorNode().operator == Kind.ReadonlyKeyword do
        host = host.parent
    end
    if checker.isTypeAlias(host) then
        return self:getSymbolOfDeclaration(host)
    end
    return nil
end

function Checker:getTypeArgumentsForAliasSymbol(symbol)
    if symbol ~= nil then
        return self:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    end
    return nil
end

function Checker:getOuterTypeParametersOfClassOrInterface(symbol)
    local declaration = self:getClassOrInterfaceLikeDeclaration(symbol)
    debug.Assert(declaration ~= nil, "Class was missing valueDeclaration -OR- non-class had no interface declarations")
    return self:getOuterTypeParameters(declaration, false --[[includeThisTypes]])
end

-- Returns the declaration used to obtain a class, interface, or function symbol's outer type parameters.
function Checker:getClassOrInterfaceLikeDeclaration(symbol)
    if symbol.flags & (SymbolFlags.Class | SymbolFlags.Function) ~= 0 then
        return symbol.valueDeclaration
    end
    return core.Find(symbol.declarations, function(d)
        if ast.IsInterfaceDeclaration(d) then
            return true
        end
        if not ast.IsVariableDeclaration(d) then
            return false
        end
        local initializer = d:Initializer()
        return initializer ~= nil and ast.IsFunctionExpressionOrArrowFunction(initializer)
    end)
end

function Checker:canGetTypeParametersOfClassOrInterface(symbol)
    return self:getClassOrInterfaceLikeDeclaration(symbol) ~= nil
end

local outerTypeParameterContainerKinds = ast.kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration, Kind.CallSignature, Kind.ConstructSignature,
    Kind.MethodSignature, Kind.FunctionType, Kind.ConstructorType, Kind.FunctionDeclaration,
    Kind.MethodDeclaration, Kind.FunctionExpression, Kind.ArrowFunction, Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.MappedType,
    Kind.ConditionalType)

-- Return the outer type parameters of a node or undefined if the node has no outer type parameters.
function Checker:getOuterTypeParameters(node, includeThisTypes)
    while true do
        node = node.parent
        if node == nil then
            return nil
        end
        local kind = node.kind
        if outerTypeParameterContainerKinds[kind] then
            local outerTypeParameters = self:getOuterTypeParameters(node, includeThisTypes)
            if (kind == Kind.FunctionExpression or kind == Kind.ArrowFunction or ast.IsObjectLiteralMethod(node)) and self:isContextSensitive(node) then
                local signature = core.FirstOrNil(self:getSignaturesOfType(self:getTypeOfSymbol(self:getSymbolOfDeclaration(node)), checker.SignatureKind.Call))
                if signature ~= nil and core.Len(signature.typeParameters) ~= 0 then
                    return core.AppendAll(outerTypeParameters, signature.typeParameters)
                end
            end
            if kind == Kind.MappedType then
                return core.Append(outerTypeParameters, self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(node:AsMappedTypeNode().typeParameter)))
            end
            if kind == Kind.ConditionalType then
                return core.AppendAll(outerTypeParameters, self:getInferTypeParameters(node))
            end
            local outerAndOwnTypeParameters = self:appendTypeParameters(outerTypeParameters, node:TypeParameters())
            local thisType = nil
            if includeThisTypes and (kind == Kind.ClassDeclaration or kind == Kind.ClassExpression or kind == Kind.InterfaceDeclaration) then
                thisType = self:getDeclaredTypeOfClassOrInterface(self:getSymbolOfDeclaration(node)):AsInterfaceType().thisType
            end
            if thisType ~= nil then
                return core.Append(outerAndOwnTypeParameters, thisType)
            end
            return outerAndOwnTypeParameters
        end
    end
end

function Checker:getInferTypeParameters(node)
    local result = nil
    for _, symbol in pairs(node:Locals() or {}) do
        if symbol.flags & SymbolFlags.TypeParameter ~= 0 then
            result = core.Append(result, self:getDeclaredTypeOfSymbol(symbol))
        end
    end
    return result
end

-- The local type parameters are the combined set of type parameters from all declarations of the class,
-- interface, or type alias.
function Checker:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    return self:appendLocalTypeParametersOfClassOrInterfaceOrTypeAlias(nil, symbol)
end

function Checker:appendLocalTypeParametersOfClassOrInterfaceOrTypeAlias(types, symbol)
    for _, node in ipairs(symbol.declarations or {}) do
        if ast.NodeKindIs(node, Kind.InterfaceDeclaration, Kind.ClassDeclaration, Kind.ClassExpression) or checker.isTypeAlias(node) then
            types = self:appendTypeParameters(types, node:TypeParameters())
        end
    end
    return types
end

-- Appends the type parameters given by a list of declarations to a set of type parameters and returns the resulting set.
-- The function allocates a new array if the input type parameter set is undefined, but otherwise it modifies the set
-- in-place and returns the same array.
function Checker:appendTypeParameters(typeParameters, declarations)
    for _, declaration in ipairs(declarations or {}) do
        typeParameters = core.AppendIfUnique(typeParameters, self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(declaration)))
    end
    return typeParameters
end

function Checker:getDeclaredTypeOfTypeParameter(symbol)
    local links = self.declaredTypeLinks:Get(symbol)
    if links.declaredType == nil then
        links.declaredType = self:newTypeParameter(symbol)
    end
    return links.declaredType
end

function Checker:getDeclaredTypeOfTypeAlias(symbol)
    local links = self.typeAliasLinks:Get(symbol)
    if links.declaredType == nil then
        -- Note that we use the links object as the target here because the symbol object is used as the unique
        -- identity for resolution of the 'type' property in SymbolLinks.
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.DeclaredType) then
            return self.errorType
        end
        local declaration = core.Find(symbol.declarations, function(d) return ast.IsTypeOrJSTypeAliasDeclaration(d) end)
        local typeNode = declaration:Type()
        local t = self:getTypeFromTypeNode(typeNode)
        if self:popTypeResolution() then
            local typeParameters = self:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
            if core.Len(typeParameters) ~= 0 then
                -- Initialize the instantiation cache for generic type aliases. The declared type corresponds to
                -- an instantiation of the type alias with the type parameters supplied as type arguments.
                links.typeParameters = typeParameters
                links.instantiations = {}
                links.instantiations[checker.getTypeListKey(typeParameters)] = t
            end
            if t == self.intrinsicMarkerType and symbol.name == "BuiltinIteratorReturn" then
                t = self:getBuiltinIteratorReturnType()
            end
        else
            local errorNode = declaration:Name()
            if errorNode == nil then
                errorNode = declaration
            end
            self:error(errorNode, diagnostics.Type_alias_0_circularly_references_itself, self:symbolToString(symbol))
            t = self.errorType
        end
        if links.declaredType == nil then
            links.declaredType = t
        end
    end
    return links.declaredType
end

function Checker:getDeclaredTypeOfEnum(symbol)
    local links = self.declaredTypeLinks:Get(symbol)
    if links.declaredType == nil then
        local memberTypeList = nil
        for _, declaration in ipairs(symbol.declarations or {}) do
            if declaration.kind == Kind.EnumDeclaration then
                for _, member in ipairs(declaration:Members() or {}) do
                    if not ast.HasDynamicName(member) then
                        local memberSymbol = self:getSymbolOfDeclaration(member)
                        local value = self:getEnumMemberValue(member).value
                        local memberType
                        if value ~= nil then
                            memberType = self:getEnumLiteralType(value, symbol, memberSymbol)
                        else
                            memberType = self:createComputedEnumType(memberSymbol)
                        end
                        self.declaredTypeLinks:Get(memberSymbol).declaredType = self:getFreshTypeOfLiteralType(memberType)
                        memberTypeList = core.Append(memberTypeList, memberType)
                    end
                end
            end
        end
        local enumType
        if core.Len(memberTypeList) ~= 0 then
            enumType = self:getUnionTypeEx(memberTypeList, UnionReduction.Literal, checker.TypeAlias_new({ symbol = symbol }), nil --[[origin]])
        else
            enumType = self:createComputedEnumType(symbol)
        end
        if enumType.flags & TypeFlags.Union ~= 0 then
            enumType.flags = enumType.flags | TypeFlags.EnumLiteral
            enumType.symbol = symbol
        end
        links.declaredType = enumType
    end
    return links.declaredType
end

function Checker:getEnumMemberValue(node)
    self:computeEnumMemberValues(node.parent)
    return self.enumMemberLinks:Get(node).value
end

function Checker:createComputedEnumType(symbol)
    local regularType = self:newLiteralType(TypeFlags.Enum, nil, nil)
    regularType.symbol = symbol
    local freshType = self:newLiteralType(TypeFlags.Enum, nil, regularType)
    freshType.symbol = symbol
    regularType:AsLiteralType().freshType = freshType
    freshType:AsLiteralType().freshType = freshType
    return regularType
end

function Checker:getDeclaredTypeOfEnumMember(symbol)
    local links = self.declaredTypeLinks:Get(symbol)
    if links.declaredType == nil then
        local enumType = self:getDeclaredTypeOfEnum(self:getParentOfSymbol(symbol))
        if links.declaredType == nil then
            links.declaredType = enumType
        end
    end
    return links.declaredType
end

function Checker:computeEnumMemberValues(node)
    local nodeLinks = self.nodeLinks:Get(node)
    if nodeLinks.flags & checker.NodeCheckFlags.EnumValuesComputed == 0 then
        nodeLinks.flags = nodeLinks.flags | checker.NodeCheckFlags.EnumValuesComputed
        -- autoValue is Go's *jsnum.Number: a float, or nil.
        local autoValue = 0.0
        local previous = nil
        for _, member in ipairs(node:Members() or {}) do
            local result = self:computeEnumMemberValue(member, autoValue, previous)
            self.enumMemberLinks:Get(member).value = result
            if type(result.value) == "number" then
                autoValue = result.value + 1
            else
                autoValue = nil
            end
            previous = member
        end
    end
end

function Checker:computeEnumMemberValue(member, autoValue, previous)
    if ast.IsComputedNonLiteralName(member:Name()) then
        self:error(member:Name(), diagnostics.Computed_property_names_are_not_allowed_in_enums)
    elseif ast.IsBigIntLiteral(member:Name()) then
        self:error(member:Name(), diagnostics.An_enum_member_cannot_have_a_numeric_name)
    else
        local text = ast.GetTextOfPropertyName(member:Name())
        if checker.isNumericLiteralName(text) and not ast.IsInfinityOrNaNString(text) then
            self:error(member:Name(), diagnostics.An_enum_member_cannot_have_a_numeric_name)
        end
    end
    if member:Initializer() ~= nil then
        return self:computeConstantEnumMemberValue(member)
    end
    -- In ambient non-const numeric enum declarations, enum members without initializers are
    -- considered computed members (as opposed to having auto-incremented values).
    if member.parent.flags & NodeFlags.Ambient ~= 0 and not ast.IsEnumConst(member.parent) then
        return evaluator.NewResult(nil, false, false, false)
    end
    -- If the member declaration specifies no value, the member is considered a constant enum member.
    -- If the member is the first member in the enum declaration, it is assigned the value zero.
    -- Otherwise, it is assigned the value of the immediately preceding member plus one, and an error
    -- occurs if the immediately preceding member is not a constant enum member.
    if autoValue == nil then
        self:error(member:Name(), diagnostics.Enum_member_must_have_initializer)
        return evaluator.NewResult(nil, false, false, false)
    end
    if self.compilerOptions:GetIsolatedModules() and previous ~= nil and previous:Initializer() ~= nil then
        local prevValue = self:getEnumMemberValue(previous)
        local prevIsNum = type(prevValue.value) == "number"
        if not prevIsNum or prevValue.resolvedOtherFiles then
            self:error(member:Name(), diagnostics.Enum_member_following_a_non_literal_numeric_member_must_have_an_initializer_when_isolatedModules_is_enabled)
        end
    end
    return evaluator.NewResult(autoValue, false, false, false)
end

function Checker:computeConstantEnumMemberValue(member)
    local isConstEnum = ast.IsEnumConst(member.parent)
    local initializer = member:Initializer()
    local result = self.evaluate(initializer, member)
    if result.value ~= nil then
        if isConstEnum then
            local numValue = result.value
            if type(numValue) == "number" and (jsnum.Number_IsInf(numValue) or jsnum.Number_IsNaN(numValue)) then
                self:error(initializer, core.IfElse(jsnum.Number_IsNaN(numValue),
                    diagnostics.X_const_enum_member_initializer_was_evaluated_to_disallowed_value_NaN,
                    diagnostics.X_const_enum_member_initializer_was_evaluated_to_a_non_finite_value))
            end
        end
        if self.compilerOptions:GetIsolatedModules() then
            if type(result.value) == "string" and not result.isSyntacticallyString then
                local memberName = member.parent:Name():Text() .. "." .. member:Name():Text()
                self:error(initializer, diagnostics.X_0_has_a_string_type_but_must_have_syntactically_recognizable_string_syntax_when_isolatedModules_is_enabled, memberName)
            end
        end
    elseif isConstEnum then
        self:error(initializer, diagnostics.X_const_enum_member_initializers_must_be_constant_expressions)
    elseif member.parent.flags & NodeFlags.Ambient ~= 0 then
        self:error(initializer, diagnostics.In_ambient_enum_declarations_member_initializer_must_be_constant_expression)
    else
        self:checkTypeAssignableTo(self:checkExpression(initializer), self.numberType, initializer, diagnostics.Type_0_is_not_assignable_to_type_1_as_required_for_computed_enum_member_values)
    end
    return result
end

function Checker:evaluateEntity(expr, location)
    if expr.kind == Kind.Identifier or expr.kind == Kind.PropertyAccessExpression then
        local symbol = self:resolveEntityName(expr, SymbolFlags.Value, true --[[ignoreErrors]], false, nil)
        if symbol == nil then
            return evaluator.NewResult(nil, false, false, false)
        end
        if expr.kind == Kind.Identifier then
            if ast.IsInfinityOrNaNString(expr:Text()) and (symbol == self:getGlobalSymbol(expr:Text(), SymbolFlags.Value, nil --[[diagnostic]])) then
                -- Technically we resolved a global lib file here, but the decision to treat this as numeric
                -- is more predicated on the fact that the single-file resolution *didn't* resolve to a
                -- different meaning of `Infinity` or `NaN`. Transpilers handle this no problem.
                return evaluator.NewResult(jsnum.FromString(expr:Text()), false, false, false)
            end
        end
        if symbol.flags & SymbolFlags.EnumMember ~= 0 then
            if location ~= nil then
                return self:evaluateEnumMember(expr, symbol, location)
            end
            return self:getEnumMemberValue(symbol.valueDeclaration)
        end
        if self:isConstantVariable(symbol) then
            local declaration = symbol.valueDeclaration
            if declaration ~= nil and ast.IsVariableDeclaration(declaration) and declaration:Type() == nil and declaration:Initializer() ~= nil and
                (location == nil or declaration ~= location and self:isBlockScopedNameDeclaredBeforeUse(declaration, location)) then
                local result = self.evaluate(declaration:Initializer(), declaration)
                if location ~= nil and ast.GetSourceFileOfNode(location) ~= ast.GetSourceFileOfNode(declaration) then
                    return evaluator.NewResult(result.value, false, true, true)
                end
                return evaluator.NewResult(result.value, result.isSyntacticallyString, result.resolvedOtherFiles, true --[[hasExternalReferences]])
            end
        end
        return evaluator.NewResult(nil, false, false, false)
    elseif expr.kind == Kind.ElementAccessExpression then
        local root = expr:Expression()
        if ast.IsEntityNameExpression(root) and ast.IsStringLiteralLike(expr:AsElementAccessExpression().argumentExpression) then
            local rootSymbol = self:resolveEntityName(root, SymbolFlags.Value, true --[[ignoreErrors]], false, nil)
            if rootSymbol ~= nil and rootSymbol.flags & SymbolFlags.Enum ~= 0 then
                local name = expr:AsElementAccessExpression().argumentExpression:Text()
                local member = rootSymbol.exports and rootSymbol.exports[name]
                if member ~= nil then
                    if location ~= nil then
                        return self:evaluateEnumMember(expr, member, location)
                    end
                    return self:getEnumMemberValue(member.valueDeclaration)
                end
            end
        end
        return evaluator.NewResult(nil, false, false, false)
    end
    error("Unhandled case in evaluateEntity", 0)
end

function Checker:evaluateEnumMember(expr, symbol, location)
    local declaration = symbol.valueDeclaration
    if declaration == nil or declaration == location then
        self:error(expr, diagnostics.Property_0_is_used_before_being_assigned, self:symbolToString(symbol))
        return evaluator.NewResult(nil, false, false, false)
    end
    if not self:isBlockScopedNameDeclaredBeforeUse(declaration, location) then
        self:error(expr, diagnostics.A_member_initializer_in_a_enum_declaration_cannot_reference_members_declared_after_it_including_members_defined_in_other_enums)
        return evaluator.NewResult(0.0, false, false, false)
    end
    local value = self:getEnumMemberValue(declaration)
    if location.parent ~= declaration.parent then
        return evaluator.NewResult(value.value, value.isSyntacticallyString, value.resolvedOtherFiles, true --[[hasExternalReferences]])
    end
    return value
end

function Checker:getDeclaredTypeOfAlias(symbol)
    local links = self.declaredTypeLinks:Get(symbol)
    if links.declaredType == nil then
        links.declaredType = self:getDeclaredTypeOfSymbol(self:resolveAlias(symbol))
    end
    return links.declaredType
end

function Checker:getTypeFromTypeQueryNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        -- TypeScript 1.0 spec (April 2014): 3.6.3
        -- The expression is processed as an identifier expression (section 4.3)
        -- or property access expression(section 4.10),
        -- the widened type(section 3.9) of which becomes the result.
        local t = self:checkExpressionWithTypeArguments(node)
        links.resolvedType = self:getRegularTypeOfLiteralType(self:getWidenedType(t))
    end
    return links.resolvedType
end

function Checker:getTypeFromArrayOrTupleTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local target = self:getArrayOrTupleTargetType(node)
        if target == self.emptyGenericType then
            links.resolvedType = self.emptyObjectType
        elseif not (node.kind == Kind.TupleType and core.Some(node:Elements(), function(e) return self:isVariadicTupleElement(e) end)) and self:isDeferredTypeReferenceNode(node, false) then
            if node.kind == Kind.TupleType and core.Len(node:Elements()) == 0 then
                links.resolvedType = target
            else
                links.resolvedType = self:createDeferredTypeReference(target, node, nil --[[mapper]], nil --[[alias]])
            end
        else
            local elementTypes
            if node.kind == Kind.ArrayType then
                elementTypes = { self:getTypeFromTypeNode(node:AsArrayTypeNode().elementType) }
            else
                elementTypes = core.Map(node:Elements(), function(e) return self:getTypeFromTypeNode(e) end)
            end
            if target.objectFlags & ObjectFlags.Tuple ~= 0 then
                links.resolvedType = self:createNormalizedTupleTypeEx(target, elementTypes, checker.ObjectFlagsFromTypeNode)
            else
                links.resolvedType = self:createTypeReferenceEx(target, elementTypes, checker.ObjectFlagsFromTypeNode)
            end
        end
    end
    return links.resolvedType
end

function Checker:isVariadicTupleElement(node)
    return self:getTupleElementFlags(node) & ElementFlags.Variadic ~= 0
end

function Checker:getArrayOrTupleTargetType(node)
    local readonly = self:isReadonlyTypeOperator(node.parent)
    local elementType = self:getArrayElementTypeNode(node)
    if elementType ~= nil then
        if readonly then
            return self.globalReadonlyArrayType
        end
        return self.globalArrayType
    end
    return self:getTupleTargetType(core.Map(node:Elements(), function(e) return self:getTupleElementInfo(e) end), readonly)
end

function Checker:isReadonlyTypeOperator(node)
    return ast.IsTypeOperatorNode(node) and node:AsTypeOperatorNode().operator == Kind.ReadonlyKeyword
end

function Checker:getTypeFromNamedTupleTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        if node:AsNamedTupleMember().dotDotDotToken ~= nil then
            links.resolvedType = self:getTypeFromRestTypeNode(node)
        else
            links.resolvedType = self:addOptionalityEx(self:getTypeFromTypeNode(node:Type()), true --[[isProperty]], node:QuestionToken() ~= nil)
        end
    end
    return links.resolvedType
end

function Checker:getTypeFromRestTypeNode(node)
    local typeNode = node:Type()
    local elementTypeNode = self:getArrayElementTypeNode(typeNode)
    if elementTypeNode ~= nil then
        typeNode = elementTypeNode
    end
    return self:getTypeFromTypeNode(typeNode)
end

function Checker:getArrayElementTypeNode(node)
    if node.kind == Kind.ParenthesizedType then
        return self:getArrayElementTypeNode(node:Type())
    elseif node.kind == Kind.TupleType then
        if core.Len(node:Elements()) == 1 then
            node = node:Elements()[1]
            if node.kind == Kind.RestType then
                return self:getArrayElementTypeNode(node:Type())
            end
            if node.kind == Kind.NamedTupleMember and node:AsNamedTupleMember().dotDotDotToken ~= nil then
                return self:getArrayElementTypeNode(node:Type())
            end
        end
    elseif node.kind == Kind.ArrayType then
        return node:AsArrayTypeNode().elementType
    end
    return nil
end

function Checker:getTypeFromOptionalTypeNode(node)
    return self:addOptionalityEx(self:getTypeFromTypeNode(node:Type()), true --[[isProperty]], true --[[isOptional]])
end

function Checker:getTypeFromUnionTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local alias = self:getAliasForTypeNode(node)
        links.resolvedType = self:getUnionTypeEx(core.Map(node:AsUnionTypeNode().types.nodes, function(n) return self:getTypeFromTypeNode(n) end), UnionReduction.Literal, alias, nil --[[origin]])
    end
    return links.resolvedType
end

function Checker:getTypeFromIntersectionTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local alias = self:getAliasForTypeNode(node)
        local types = core.Map(node:AsIntersectionTypeNode().types.nodes, function(n) return self:getTypeFromTypeNode(n) end)
        -- We perform no supertype reduction for X & {} or {} & X, where X is one of string, number, bigint,
        -- or a pattern literal template type. This enables union types like "a" | "b" | string & {} or
        -- "aa" | "ab" | `a${string}` which preserve the literal types for purposes of statement completion.
        local noSupertypeReduction = false
        if core.Len(types) == 2 then
            local emptyIndex = indexOf(types, self.emptyTypeLiteralType)
            if emptyIndex >= 0 then
                local t = types[1 - emptyIndex + 1]
                noSupertypeReduction = t.flags & (TypeFlags.String | TypeFlags.Number | TypeFlags.BigInt) ~= 0 or t.flags & TypeFlags.TemplateLiteral ~= 0 and self:isPatternLiteralType(t)
            end
        end
        links.resolvedType = self:getIntersectionTypeEx(types, core.IfElse(noSupertypeReduction, IntersectionFlags.NoSupertypeReduction, 0), alias)
    end
    return links.resolvedType
end

function Checker:getTypeFromTemplateTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local spans = node:AsTemplateLiteralTypeNode().templateSpans
        local texts = {}
        local types = {}
        texts[1] = node:AsTemplateLiteralTypeNode().head:Text()
        for i, span in ipairs(spans.nodes or {}) do
            texts[i + 1] = span:AsTemplateLiteralTypeSpan().literal:Text()
            types[i] = self:getTypeFromTypeNode(span:Type())
        end
        links.resolvedType = self:getTemplateLiteralType(texts, types)
    end
    return links.resolvedType
end

function Checker:getTypeFromMappedTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local t = self:newObjectType(ObjectFlags.Mapped, node:Symbol())
        t:AsMappedType().declaration = node:AsMappedTypeNode()
        t.alias = self:getAliasForTypeNode(node)
        links.resolvedType = t
        -- Eagerly resolve the constraint type which forces an error if the constraint type circularly
        -- references itself through one or more type aliases.
        self:getConstraintTypeFromMappedType(t)
    end
    return links.resolvedType
end

function Checker:getTypeFromConditionalTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local checkType = self:getTypeFromTypeNode(node:AsConditionalTypeNode().checkType)
        local alias = self:getAliasForTypeNode(node)
        local allOuterTypeParameters = self:getOuterTypeParameters(node, true --[[includeThisTypes]])
        local outerTypeParameters
        if alias ~= nil and core.Len(alias.typeArguments) ~= 0 then
            outerTypeParameters = allOuterTypeParameters
        else
            outerTypeParameters = core.Filter(allOuterTypeParameters, function(tp) return self:isTypeParameterPossiblyReferenced(tp, node) end)
        end
        local root = checker.ConditionalRoot_new({
            node = node:AsConditionalTypeNode(),
            checkType = checkType,
            extendsType = self:getTypeFromTypeNode(node:AsConditionalTypeNode().extendsType),
            isDistributive = checkType.flags & TypeFlags.TypeParameter ~= 0,
            inferTypeParameters = self:getInferTypeParameters(node),
            outerTypeParameters = outerTypeParameters,
            instantiations = nil,
            alias = alias,
        })
        links.resolvedType = self:getConditionalType(root, nil --[[mapper]], false --[[forConstraint]], nil)
        if outerTypeParameters ~= nil then
            root.instantiations = {}
            root.instantiations[checker.getConditionalTypeKey(outerTypeParameters, nil --[[alias]], false --[[forConstraint]])] = links.resolvedType
        end
    end
    return links.resolvedType
end

function Checker:getConditionalType(root, mapper, forConstraint, alias)
    local result = nil
    local extraTypes = nil
    local tailCount = 0
    -- We loop here for an immediately nested conditional type in the false position, effectively treating
    -- types of the form 'A extends B ? X : C extends D ? Y : E extends F ? Z : ...' as a single construct for
    -- purposes of resolution. We also loop here when resolution of a conditional type ends in resolution of
    -- another (or, through recursion, possibly the same) conditional type. In the potentially tail-recursive
    -- cases we increment the tail recursion counter and stop after 1000 iterations.
    while true do
        if tailCount == 1000 then
            self:error(self.currentNode, diagnostics.Type_instantiation_is_excessively_deep_and_possibly_infinite)
            return self.errorType
        end
        local checkType = self:instantiateType(self:getActualTypeVariable(root.checkType), mapper)
        local extendsType = self:instantiateType(root.extendsType, mapper)
        if checkType == self.errorType or extendsType == self.errorType then
            return self.errorType
        end
        if checkType == self.wildcardType or extendsType == self.wildcardType then
            return self.wildcardType
        end
        local checkTypeNode = ast.SkipTypeParentheses(root.node.checkType)
        local extendsTypeNode = ast.SkipTypeParentheses(root.node.extendsType)
        -- When the check and extends types are simple tuple types of the same arity, we defer resolution of the
        -- conditional type when any tuple elements are generic. This is such that non-distributable conditional
        -- types can be written `[X] extends [Y] ? ...` and be deferred similarly to `X extends Y ? ...`.
        local checkTuples = self:isSimpleTupleType(checkTypeNode) and self:isSimpleTupleType(extendsTypeNode) and core.Len(checkTypeNode:Elements()) == core.Len(extendsTypeNode:Elements())
        local checkTypeDeferred = self:isDeferredType(checkType, checkTuples)
        local combinedMapper = nil
        if core.Len(root.inferTypeParameters) ~= 0 then
            -- When we're looking at making an inference for an infer type, when we get its constraint, it'll automagically be
            -- instantiated with the context, so it doesn't need the mapper for the inference context - however the constraint
            -- may refer to another _root_, _uncloned_ `infer` type parameter [1], or to something mapped by `mapper` [2].
            -- [1] Eg, if we have `Foo<T, U extends T>` and `Foo<number, infer B>` - `B` is constrained to `T`, which, in turn, has been instantiated
            -- as `number`
            -- Conversely, if we have `Foo<infer A, infer B>`, `B` is still constrained to `T` and `T` is instantiated as `A`
            -- [2] Eg, if we have `Foo<T, U extends T>` and `Foo<Q, infer B>` where `Q` is mapped by `mapper` into `number` - `B` is constrained to `T`
            -- which is in turn instantiated as `Q`, which is in turn instantiated as `number`.
            -- So we need to:
            --    * combine `context.nonFixingMapper` with `mapper` so their constraints can be instantiated in the context of `mapper` (otherwise they'd only get inference context information)
            --    * incorporate all of the component mappers into the combined mapper for the true and false members
            -- This means we have two mappers that need applying:
            --    * The original `mapper` used to create this conditional
            --    * The mapper that maps the infer type parameter to its inference result (`context.mapper`)
            local context = self:newInferenceContext(root.inferTypeParameters, nil --[[signature]], checker.InferenceFlags.None, nil)
            if mapper ~= nil then
                context.nonFixingMapper = self:combineTypeMappers(context.nonFixingMapper, mapper)
            end
            if not checkTypeDeferred then
                -- We don't want inferences from constraints as they may cause us to eagerly resolve the
                -- conditional type instead of deferring resolution. Also, we always want strict function
                -- types rules (i.e. proper contravariance) for inferences.
                self:inferTypes(context.inferences, checkType, extendsType, checker.InferencePriority.NoConstraints | checker.InferencePriority.AlwaysStrict, false)
            end
            -- It's possible for 'infer T' type parameters to be given uninstantiated constraints when the
            -- those type parameters are used in type references (see getInferredTypeParameterConstraint). For
            -- that reason we need context.mapper to be first in the combined mapper. See #42636 for examples.
            if mapper ~= nil then
                combinedMapper = self:combineTypeMappers(context.mapper, mapper)
            else
                combinedMapper = context.mapper
            end
        end
        -- Instantiate the extends type including inferences for 'infer T' type parameters
        local inferredExtendsType
        if combinedMapper ~= nil then
            inferredExtendsType = self:instantiateType(root.extendsType, combinedMapper)
        else
            inferredExtendsType = extendsType
        end
        -- We attempt to resolve the conditional type only when the check and extends types are non-generic
        if not checkTypeDeferred and not self:isDeferredType(inferredExtendsType, checkTuples) then
            -- Return falseType for a definitely false extends check. We check an instantiations of the two
            -- types with type parameters mapped to the wildcard type, the most permissive instantiations
            -- possible (the wildcard type is assignable to and from all types). If those are not related,
            -- then no instantiations will be and we can just return the false branch type.
            if inferredExtendsType.flags & TypeFlags.AnyOrUnknown == 0 and (checkType.flags & TypeFlags.Any ~= 0 or not self:isTypeAssignableTo(self:getPermissiveInstantiation(checkType), self:getPermissiveInstantiation(inferredExtendsType))) then
                -- Return union of trueType and falseType for 'any' since it matches anything. Furthermore, for a
                -- distributive conditional type applied to the constraint of a type variable, include trueType if
                -- there are possible values of the check type that are also possible values of the extends type.
                -- We use a reverse assignability check as it is less expensive than the comparable relationship
                -- and avoids false positives of a non-empty intersection check.
                if checkType.flags & TypeFlags.Any ~= 0 or forConstraint and inferredExtendsType.flags & TypeFlags.Never == 0 and checker.someType(self:getPermissiveInstantiation(inferredExtendsType), function(t)
                    return self:isTypeAssignableTo(t, self:getPermissiveInstantiation(checkType))
                end) then
                    extraTypes = core.Append(extraTypes, self:instantiateType(self:getTypeFromTypeNode(root.node.trueType), core.OrElse(combinedMapper, mapper)))
                end
                -- If falseType is an immediately nested conditional type that isn't distributive or has an
                -- identical checkType, switch to that type and loop.
                local falseType = self:getTypeFromTypeNode(root.node.falseType)
                if falseType.flags & TypeFlags.Conditional ~= 0 then
                    local newRoot = falseType:AsConditionalType().root
                    if newRoot.node.parent == root.node:AsNode() and (not newRoot.isDistributive or newRoot.checkType == root.checkType) then
                        root = newRoot
                        goto continue
                    end
                    local tailRoot, tailRootMapper = self:getTailRecursionRoot(falseType, mapper)
                    if tailRoot ~= nil then
                        root = tailRoot
                        mapper = tailRootMapper
                        alias = nil
                        if tailRoot.alias ~= nil then
                            tailCount = tailCount + 1
                        end
                        goto continue
                    end
                end
                result = self:instantiateType(falseType, mapper)
                break
            end
            -- Return trueType for a definitely true extends check. We check instantiations of the two
            -- types with type parameters mapped to their restrictive form, i.e. a form of the type parameter
            -- that has no constraint. This ensures that, for example, the type
            --   type Foo<T extends { x: any }> = T extends { x: string } ? string : number
            -- doesn't immediately resolve to 'string' instead of being deferred.
            if inferredExtendsType.flags & TypeFlags.AnyOrUnknown ~= 0 or self:isTypeAssignableTo(self:getRestrictiveInstantiation(checkType), self:getRestrictiveInstantiation(inferredExtendsType)) then
                local trueType = self:getTypeFromTypeNode(root.node.trueType)
                local trueMapper = core.OrElse(combinedMapper, mapper)
                local tailRoot, tailRootMapper = self:getTailRecursionRoot(trueType, trueMapper)
                if tailRoot ~= nil then
                    root = tailRoot
                    mapper = tailRootMapper
                    alias = nil
                    if tailRoot.alias ~= nil then
                        tailCount = tailCount + 1
                    end
                    goto continue
                end
                result = self:instantiateType(trueType, trueMapper)
                break
            end
        end
        -- Return a deferred type for a check that is neither definitely true nor definitely false
        result = self:newConditionalType(root, mapper, combinedMapper)
        if alias ~= nil then
            result.alias = alias
        else
            result.alias = self:instantiateTypeAlias(root.alias, mapper)
        end
        do
            break
        end
        ::continue::
    end
    if extraTypes ~= nil then
        return self:getUnionType(core.Append(extraTypes, result))
    end
    return result
end

-- We tail-recurse for generic conditional types that (a) have not already been evaluated and cached, and
-- (b) are non distributive, have a check type that is unaffected by instantiation, or have a non-union check
-- type. Note that recursion is possible only through aliased conditional types, so we only increment the tail
-- recursion counter for those.
function Checker:getTailRecursionRoot(newType, newMapper)
    if newType.flags & TypeFlags.Conditional ~= 0 and newMapper ~= nil then
        local newRoot = newType:AsConditionalType().root
        if core.Len(newRoot.outerTypeParameters) ~= 0 then
            local typeParamMapper = self:combineTypeMappers(newType:AsConditionalType().mapper, newMapper)
            local typeArguments = core.Map(newRoot.outerTypeParameters, function(t) return typeParamMapper:Map(t) end)
            local newRootMapper = checker.newTypeMapper(newRoot.outerTypeParameters, typeArguments)
            local newCheckType = nil
            if newRoot.isDistributive then
                newCheckType = newRootMapper:Map(newRoot.checkType)
            end
            if newCheckType == nil or newCheckType == newRoot.checkType or newCheckType.flags & (TypeFlags.Union | TypeFlags.Never) == 0 then
                return newRoot, newRootMapper
            end
        end
    end
    return nil, nil
end

function Checker:isSimpleTupleType(node)
    return ast.IsTupleTypeNode(node) and core.Len(node:Elements()) > 0 and not core.Some(node:Elements(), function(e)
        return ast.IsOptionalTypeNode(e) or ast.IsRestTypeNode(e) or ast.IsNamedTupleMember(e) and (e:QuestionToken() ~= nil or e:AsNamedTupleMember().dotDotDotToken ~= nil)
    end)
end

function Checker:isDeferredType(t, checkTuples)
    return self:isGenericType(t) or checkTuples and checker.isTupleType(t) and core.Some(self:getElementTypes(t), function(e) return self:isGenericType(e) end)
end

function Checker:getPermissiveInstantiation(t)
    if t.flags & (TypeFlags.Primitive | TypeFlags.AnyOrUnknown | TypeFlags.Never) ~= 0 then
        return t
    end
    local key = checker.CachedTypeKey(CachedTypeKind.PermissiveInstantiation, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local result = self:instantiateType(t, self.permissiveMapper)
    self.cachedTypes[key] = result
    return result
end

function Checker:getRestrictiveInstantiation(t)
    if t.flags & (TypeFlags.Primitive | TypeFlags.AnyOrUnknown | TypeFlags.Never) ~= 0 then
        return t
    end
    local key = checker.CachedTypeKey(CachedTypeKind.RestrictiveInstantiation, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local result = self:instantiateType(t, self.restrictiveMapper)
    self.cachedTypes[key] = result
    -- We set the following so we don't attempt to set the restrictive instance of a restrictive instance
    -- which is redundant - we'll produce new type identities, but all type params have already been mapped.
    -- This also gives us a way to detect restrictive instances upon comparisons and _disable_ the "distributeive constraint"
    -- assignability check for them, which is distinctly unsafe, as once you have a restrctive instance, all the type parameters
    -- are constrained to `unknown` and produce tons of false positives/negatives!
    self.cachedTypes[checker.CachedTypeKey(CachedTypeKind.RestrictiveInstantiation, result.id)] = result
    return result
end

function Checker:getRestrictiveTypeParameter(t)
    if t:AsTypeParameter().constraint == nil and self:getConstraintDeclaration(t) == nil or t:AsTypeParameter().constraint == self.noConstraintType then
        return t
    end
    local key = checker.CachedTypeKey(CachedTypeKind.RestrictiveTypeParameter, t.id)
    local cached = self.cachedTypes[key]
    if cached ~= nil then
        return cached
    end
    local result = self:newTypeParameter(t.symbol)
    result:AsTypeParameter().constraint = self.noConstraintType
    self.cachedTypes[key] = result
    return result
end

function Checker:restrictiveMapperWorker(t)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        return self:getRestrictiveTypeParameter(t)
    end
    return t
end

function Checker:permissiveMapperWorker(t)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        return self.wildcardType
    end
    return t
end

function Checker:getTrueTypeFromConditionalType(t)
    local d = t:AsConditionalType()
    if d.resolvedTrueType == nil then
        d.resolvedTrueType = self:instantiateType(self:getTypeFromTypeNode(d.root.node.trueType), d.mapper)
    end
    return d.resolvedTrueType
end

function Checker:getFalseTypeFromConditionalType(t)
    local d = t:AsConditionalType()
    if d.resolvedFalseType == nil then
        d.resolvedFalseType = self:instantiateType(self:getTypeFromTypeNode(d.root.node.falseType), d.mapper)
    end
    return d.resolvedFalseType
end

function Checker:getInferredTrueTypeFromConditionalType(t)
    local d = t:AsConditionalType()
    if d.resolvedInferredTrueType == nil then
        if d.combinedMapper ~= nil then
            d.resolvedInferredTrueType = self:instantiateType(self:getTypeFromTypeNode(d.root.node.trueType), d.combinedMapper)
        else
            d.resolvedInferredTrueType = self:getTrueTypeFromConditionalType(t)
        end
    end
    return d.resolvedInferredTrueType
end

function Checker:getTypeFromInferTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        links.resolvedType = self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(node:AsInferTypeNode().typeParameter))
    end
    return links.resolvedType
end

function Checker:getTypeFromImportTypeNode(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local n = node:AsImportTypeNode()
        if not ast.IsLiteralImportTypeNode(node) then
            self:error(n.argument, diagnostics.String_literal_expected)
            self.symbolNodeLinks:Get(node).resolvedSymbol = self.unknownSymbol
            links.resolvedType = self.errorType
            return links.resolvedType
        end
        local targetMeaning = core.IfElse(n.isTypeOf, SymbolFlags.Value, SymbolFlags.Type)
        -- TODO: Future work: support unions/generics/whatever via a deferred import-type
        local innerModuleSymbol = self:resolveExternalModuleName(node, n.argument:AsLiteralTypeNode().literal, false --[[ignoreErrors]])
        if innerModuleSymbol == nil then
            self.symbolNodeLinks:Get(node).resolvedSymbol = self.unknownSymbol
            links.resolvedType = self.errorType
            return links.resolvedType
        end
        local moduleSymbol = self:resolveExternalModuleSymbol(innerModuleSymbol, false --[[dontResolveAlias]])
        if not ast.NodeIsMissing(n.qualifier) then
            local nameChain = self:getIdentifierChain(n.qualifier)
            local currentNamespace = moduleSymbol
            for i1, current in ipairs(nameChain) do
                local meaning = SymbolFlags.Namespace
                if i1 == #nameChain then
                    meaning = targetMeaning
                end
                -- typeof a.b.c is normally resolved using `checkExpression` which in turn defers to `checkQualifiedName`
                -- That, in turn, ultimately uses `getPropertyOfType` on the type of the symbol, which differs slightly from
                -- the `exports` lookup process that only looks up namespace members which is used for most type references
                local mergedResolvedSymbol = self:getMergedSymbol(self:resolveSymbol(currentNamespace))
                local symbolFromVariable = nil
                local symbolFromModule = nil
                if n.isTypeOf then
                    symbolFromVariable = self:getPropertyOfTypeEx(self:getTypeOfSymbol(mergedResolvedSymbol), current:Text(), false --[[skipObjectFunctionPropertyAugment]], true --[[includeTypeOnlyMembers]])
                else
                    symbolFromModule = self:getSymbol(self:getExportsOfSymbol(mergedResolvedSymbol), current:Text(), meaning)
                    if symbolFromModule == nil then
                        -- a CommonJS module might have typedefs exported alongside an export=
                        -- !!!
                        local immediateModuleSymbol = self:resolveExternalModuleSymbol(innerModuleSymbol, true --[[dontResolveAlias]])
                        if immediateModuleSymbol ~= nil and core.Some(immediateModuleSymbol.declarations, function(d)
                            return ast.GetAssignmentDeclarationKind(d) == ast.JSDeclarationKind.ModuleExports
                        end) then
                            symbolFromModule = self:getSymbol(self:getExportsOfSymbol(immediateModuleSymbol.parent), current:Text(), meaning)
                        end
                    end
                end
                local nextSymbol = core.OrElse(symbolFromModule, symbolFromVariable)
                if nextSymbol == nil then
                    self:error(current, diagnostics.Namespace_0_has_no_exported_member_1, self:getFullyQualifiedName(currentNamespace, nil), scanner.DeclarationNameToString(current))
                    links.resolvedType = self.errorType
                    return links.resolvedType
                end
                self.symbolNodeLinks:Get(current).resolvedSymbol = nextSymbol
                self.symbolNodeLinks:Get(current.parent).resolvedSymbol = nextSymbol
                currentNamespace = nextSymbol
            end
            links.resolvedType = self:resolveImportSymbolType(node, currentNamespace, targetMeaning)
        else
            if self:getSymbolFlags(moduleSymbol) & targetMeaning ~= 0 then
                links.resolvedType = self:resolveImportSymbolType(node, moduleSymbol, targetMeaning)
            else
                local message = core.IfElse(targetMeaning == SymbolFlags.Value,
                    diagnostics.Module_0_does_not_refer_to_a_value_but_is_used_as_a_value_here,
                    diagnostics.Module_0_does_not_refer_to_a_type_but_is_used_as_a_type_here_Did_you_mean_typeof_import_0)
                self:error(node, message, n.argument:AsLiteralTypeNode().literal:Text())
                self.symbolNodeLinks:Get(node).resolvedSymbol = self.unknownSymbol
                links.resolvedType = self.errorType
            end
        end
    end
    return links.resolvedType
end

function Checker:getIdentifierChain(node)
    if ast.IsIdentifier(node) then
        return { node }
    end
    return core.Append(self:getIdentifierChain(node:AsQualifiedName().left), node:AsQualifiedName().right)
end

function Checker:resolveImportSymbolType(node, symbol, meaning)
    local resolvedSymbol = self:resolveSymbol(symbol)
    self.symbolNodeLinks:Get(node).resolvedSymbol = resolvedSymbol
    if meaning == SymbolFlags.Value then
        -- intentionally doesn't use resolved symbol so type is cached as expected on the alias
        return self:getInstantiationExpressionType(self:getTypeOfSymbol(symbol), node)
    end
    -- getTypeReferenceType doesn't handle aliases - it must get the resolved symbol
    return self:getTypeReferenceType(node, resolvedSymbol)
end

function Checker:createTypeFromGenericGlobalType(genericGlobalType, typeArguments)
    if genericGlobalType ~= self.emptyGenericType then
        return self:createTypeReference(genericGlobalType, typeArguments)
    end
    return self.emptyObjectType
end

function Checker:getGlobalStrictFunctionType(name)
    if self.strictBindCallApply then
        return self:getGlobalType(name, 0 --[[arity]], true --[[reportErrors]])
    end
    return self.globalFunctionType
end

function Checker:getGlobalImportMetaExpressionType()
    if self.deferredGlobalImportMetaExpressionType == nil then
        -- Create a synthetic type `ImportMetaExpression { meta: MetaProperty }`
        local symbol = self:newSymbol(SymbolFlags.None, "ImportMetaExpression")
        local importMetaType = self.getGlobalImportMetaType()
        local metaPropertySymbol = self:newSymbolEx(SymbolFlags.Property, "meta", CheckFlags.Readonly)
        metaPropertySymbol.parent = symbol
        self.valueSymbolLinks:Get(metaPropertySymbol).resolvedType = importMetaType
        local members = checker.createSymbolTable({ metaPropertySymbol })
        symbol.members = members
        self.deferredGlobalImportMetaExpressionType = self:newAnonymousType(symbol, members, nil, nil, nil)
    end
    return self.deferredGlobalImportMetaExpressionType
end

function Checker:createIterableType(iteratedType)
    return self:createTypeFromGenericGlobalType(self.getGlobalIterableTypeChecked(), { iteratedType, self.voidType, self.undefinedType })
end

function Checker:createArrayType(elementType)
    return self:createArrayTypeEx(elementType, false --[[readonly]])
end

function Checker:createArrayTypeEx(elementType, readonly)
    return self:createTypeFromGenericGlobalType(core.IfElse(readonly, self.globalReadonlyArrayType, self.globalArrayType), { elementType })
end

function Checker:getTupleElementFlags(node)
    if node.kind == Kind.OptionalType then
        return ElementFlags.Optional
    elseif node.kind == Kind.RestType then
        return core.IfElse(self:getArrayElementTypeNode(node:Type()) ~= nil, ElementFlags.Rest, ElementFlags.Variadic)
    elseif node.kind == Kind.NamedTupleMember then
        local named = node:AsNamedTupleMember()
        if named.questionToken ~= nil then
            return ElementFlags.Optional
        elseif named.dotDotDotToken ~= nil then
            return core.IfElse(self:getArrayElementTypeNode(named.type) ~= nil, ElementFlags.Rest, ElementFlags.Variadic)
        end
        return ElementFlags.Required
    end
    return ElementFlags.Required
end

function Checker:getTupleElementInfo(node)
    return checker.TupleElementInfo_new({
        flags = self:getTupleElementFlags(node),
        labeledDeclaration = core.IfElse(ast.IsNamedTupleMember(node) or ast.IsParameterDeclaration(node), node, nil),
    })
end

function Checker:createTupleType(elementTypes)
    local elementInfos = core.Map(elementTypes, function() return checker.TupleElementInfo_new({ flags = ElementFlags.Required }) end)
    return self:createTupleTypeEx(elementTypes, elementInfos, false --[[readonly]])
end

function Checker:createTupleTypeEx(elementTypes, elementInfos, readonly)
    local tupleTarget = self:getTupleTargetType(elementInfos, readonly)
    if tupleTarget == self.emptyGenericType then
        return self.emptyObjectType
    elseif core.Len(elementTypes) ~= 0 then
        return self:createNormalizedTypeReference(tupleTarget, elementTypes)
    end
    return tupleTarget
end

function Checker:getTupleTargetType(elementInfos, readonly)
    if core.Len(elementInfos) == 1 and elementInfos[1].flags & ElementFlags.Rest ~= 0 then
        -- [...X[]] is equivalent to just X[]
        if readonly then
            return self.globalReadonlyArrayType
        end
        return self.globalArrayType
    end
    local key = checker.getTupleKey(elementInfos, readonly)
    local t = self.tupleTypes[key]
    if t == nil then
        t = self:createTupleTargetType(elementInfos, readonly)
        self.tupleTypes[key] = t
    end
    return t
end

-- We represent tuple types as type references to synthesized generic interface types created by
-- this function. The types are of the form:
--
--	interface Tuple<T0, T1, T2, ...> extends Array<T0 | T1 | T2 | ...> { 0: T0, 1: T1, 2: T2, ... }
--
-- Note that the generic type created by this function has no symbol associated with it. The same
-- is true for each of the synthesized type parameters.
function Checker:createTupleTargetType(elementInfos, readonly)
    local arity = core.Len(elementInfos)
    local minLength = core.CountWhere(elementInfos, function(e)
        return e.flags & (ElementFlags.Required | ElementFlags.Variadic) ~= 0
    end)
    local typeParameters = nil
    local members = {}
    local fixedLength = 0
    local combinedFlags = ElementFlags.None
    if arity ~= 0 then
        typeParameters = {}
        for i = 0, arity - 1 do
            local typeParameter = self:newTypeParameter(nil)
            typeParameters[#typeParameters + 1] = typeParameter
            local flags = elementInfos[i + 1].flags
            combinedFlags = combinedFlags | flags
            if combinedFlags & ElementFlags.Variable == 0 then
                local property = self:newSymbolEx(SymbolFlags.Property | core.IfElse(flags & ElementFlags.Optional ~= 0, SymbolFlags.Optional, 0), tostring(i), core.IfElse(readonly, CheckFlags.Readonly, 0))
                self.valueSymbolLinks:Get(property).resolvedType = typeParameter
                -- c.valueSymbolLinks.get(property).tupleLabelDeclaration = elementInfos[i].labeledDeclaration
                if members[property.name] == nil then
                    fixedLength = fixedLength + 1
                end
                members[property.name] = property
            end
        end
    end
    local lengthSymbol = self:newSymbolEx(SymbolFlags.Property, "length", core.IfElse(readonly, CheckFlags.Readonly, 0))
    if combinedFlags & ElementFlags.Variable ~= 0 then
        self.valueSymbolLinks:Get(lengthSymbol).resolvedType = self.numberType
    else
        local literalTypes = nil
        for i = minLength, arity do
            literalTypes = core.Append(literalTypes, self:getNumberLiteralType(i + 0.0))
        end
        self.valueSymbolLinks:Get(lengthSymbol).resolvedType = self:getUnionType(literalTypes)
    end
    members[lengthSymbol.name] = lengthSymbol
    local t = self:newObjectType(ObjectFlags.Tuple | ObjectFlags.Reference, nil)
    local d = t:AsTupleType()
    d.thisType = self:newTypeParameter(nil)
    d.thisType:AsTypeParameter().isThisType = true
    d.thisType:AsTypeParameter().constraint = t
    d.allTypeParameters = core.Append(typeParameters, d.thisType)
    d.instantiations = {}
    d.instantiations[checker.getTypeListKey(d:TypeParameters())] = t
    d.target = t
    d.resolvedTypeArguments = d:TypeParameters()
    d.declaredMembersResolved = true
    d.declaredMembers = members
    d.elementInfos = elementInfos
    d.minLength = minLength
    d.fixedLength = fixedLength
    d.combinedFlags = combinedFlags
    d.readonly = readonly
    return t
end

function Checker:getElementTypeOfSliceOfTupleType(t, index, endSkipCount, writing, noReductions)
    local length = self:getTypeReferenceArity(t) - endSkipCount
    local elementInfos = t:TargetTupleType().elementInfos
    if index < length then
        local typeArguments = self:getTypeArguments(t)
        local elementTypes = nil
        for i = index, length - 1 do
            local e = typeArguments[i + 1]
            if elementInfos[i + 1].flags & ElementFlags.Variadic ~= 0 then
                e = self:getIndexedAccessType(e, self.numberType)
            end
            elementTypes = core.Append(elementTypes, e)
        end
        if writing then
            return self:getIntersectionType(elementTypes)
        end
        return self:getUnionTypeEx(elementTypes, core.IfElse(noReductions, UnionReduction.None, UnionReduction.Literal), nil, nil)
    end
    return nil
end

function Checker:getRestTypeOfTupleType(t)
    return self:getElementTypeOfSliceOfTupleType(t, t:TargetTupleType().fixedLength, 0, false, false)
end

function Checker:getTupleElementTypeOutOfStartCount(t, index, undefinedLikeType)
    return self:mapType(t, function(e)
        local restType = self:getRestTypeOfTupleType(e)
        if restType == nil then
            return self.undefinedType
        end
        if undefinedLikeType ~= nil and index >= checker.getTotalFixedElementCount(e:TargetTupleType()) then
            return self:getUnionType({ restType, undefinedLikeType })
        end
        return restType
    end)
end

function Checker:isGenericType(t)
    return self:getGenericObjectFlags(t) ~= 0
end

function Checker:isGenericObjectType(t)
    return self:getGenericObjectFlags(t) & checker.ObjectFlagsIsGenericObjectType ~= 0
end

function Checker:isGenericIndexType(t)
    return self:getGenericObjectFlags(t) & checker.ObjectFlagsIsGenericIndexType ~= 0
end

function Checker:getGenericObjectFlags(t)
    local combinedFlags = 0
    if t.flags & (TypeFlags.UnionOrIntersection | TypeFlags.Substitution) ~= 0 then
        if t.objectFlags & checker.ObjectFlagsIsGenericTypeComputed == 0 then
            if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
                for _, u in ipairs(t:Types() or {}) do
                    combinedFlags = combinedFlags | self:getGenericObjectFlags(u)
                end
            else
                combinedFlags = self:getGenericObjectFlags(t:AsSubstitutionType().baseType) | self:getGenericObjectFlags(t:AsSubstitutionType().constraint)
            end
            t.objectFlags = t.objectFlags | checker.ObjectFlagsIsGenericTypeComputed | combinedFlags
        end
        return t.objectFlags & checker.ObjectFlagsIsGenericType
    end
    if t.flags & TypeFlags.InstantiableNonPrimitive ~= 0 or self:isGenericMappedType(t) or self:isGenericTupleType(t) then
        combinedFlags = combinedFlags | checker.ObjectFlagsIsGenericObjectType
    end
    if t.flags & (TypeFlags.InstantiableNonPrimitive | TypeFlags.Index) ~= 0 or self:isGenericStringLikeType(t) then
        combinedFlags = combinedFlags | checker.ObjectFlagsIsGenericIndexType
    end
    return combinedFlags
end

function Checker:isGenericTupleType(t)
    return checker.isTupleType(t) and t:TargetTupleType().combinedFlags & ElementFlags.Variadic ~= 0
end

function Checker:isGenericMappedType(t)
    if t.objectFlags & ObjectFlags.Mapped ~= 0 then
        local constraint = self:getConstraintTypeFromMappedType(t)
        if self:isGenericIndexType(constraint) then
            return true
        end
        -- A mapped type is generic if the 'as' clause references generic types other than the iteration type.
        -- To determine this, we substitute the constraint type (that we now know isn't generic) for the iteration
        -- type and check whether the resulting type is generic.
        local nameType = self:getNameTypeFromMappedType(t)
        if nameType ~= nil and self:isGenericIndexType(self:instantiateType(nameType, checker.newSimpleTypeMapper(self:getTypeParameterFromMappedType(t), constraint))) then
            return true
        end
    end
    return false
end

--[[
 * A union type which is reducible upon instantiation (meaning some members are removed under certain instantiations)
 * must be kept generic, as that instantiation information needs to flow through the type system. By replacing all
 * type parameters in the union with a special never type that is treated as a literal in `getReducedType`, we can cause
 * the `getReducedType` logic to reduce the resulting type if possible (since only intersections with conflicting
 * literal-typed properties are reducible).
]]
function Checker:isGenericReducibleType(t)
    return t.flags & TypeFlags.Union ~= 0 and t.objectFlags & checker.ObjectFlagsContainsIntersections ~= 0 and core.Some(t:Types(), function(u) return self:isGenericReducibleType(u) end) or
        t.flags & TypeFlags.Intersection ~= 0 and self:isReducibleIntersection(t)
end

function Checker:isReducibleIntersection(t)
    local d = t:AsIntersectionType()
    if d.uniqueLiteralFilledInstantiation == nil then
        d.uniqueLiteralFilledInstantiation = self:instantiateType(t, self.uniqueLiteralMapper)
    end
    return self:getReducedType(d.uniqueLiteralFilledInstantiation) ~= d.uniqueLiteralFilledInstantiation
end

function Checker:getUniqueLiteralTypeForTypeParameter(t)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        return self.uniqueLiteralType
    end
    return t
end

function Checker:getConditionalFlowTypeOfType(t, node)
    local constraints = nil
    local covariant = true
    while node ~= nil and not ast.IsStatement(node) and node.kind ~= Kind.JSDoc do
        local parent = node.parent
        -- only consider variance flipped by parameter locations - `keyof` types would usually be considered variance inverting, but
        -- often get used in indexed accesses where they behave sortof invariantly, but our checking is lax
        if ast.IsParameterDeclaration(parent) then
            covariant = not covariant
        end
        -- Always substitute on type parameters, regardless of variance, since even
        -- in contravariant positions, they may rely on substituted constraints to be valid
        if (covariant or t.flags & TypeFlags.TypeVariable ~= 0) and ast.IsConditionalTypeNode(parent) and node == parent:AsConditionalTypeNode().trueType then
            local constraint = self:getImpliedConstraint(t, parent:AsConditionalTypeNode().checkType, parent:AsConditionalTypeNode().extendsType)
            if constraint ~= nil then
                constraints = core.Append(constraints, constraint)
            end
        elseif t.flags & TypeFlags.TypeParameter ~= 0 and ast.IsMappedTypeNode(parent) and parent:AsMappedTypeNode().nameType == nil and node == parent:Type() then
            local mappedType = self:getTypeFromTypeNode(parent)
            if self:getTypeParameterFromMappedType(mappedType) == self:getActualTypeVariable(t) then
                local typeParameter = self:getHomomorphicTypeVariable(mappedType)
                if typeParameter ~= nil then
                    local constraint = self:getConstraintOfTypeParameter(typeParameter)
                    if constraint ~= nil and checker.everyType(constraint, function(ct) return self:isArrayOrTupleType(ct) end) then
                        constraints = core.Append(constraints, self:getUnionType({ self.numberType, self.numericStringType }))
                    end
                end
            end
        end
        node = parent
    end
    if core.Len(constraints) ~= 0 then
        return self:getSubstitutionType(t, self:getIntersectionType(constraints))
    end
    return t
end

function Checker:getImpliedConstraint(t, checkNode, extendsNode)
    if checker.isUnaryTupleTypeNode(checkNode) and checker.isUnaryTupleTypeNode(extendsNode) then
        return self:getImpliedConstraint(t, checkNode:Elements()[1], extendsNode:Elements()[1])
    elseif self:getActualTypeVariable(self:getTypeFromTypeNode(checkNode)) == self:getActualTypeVariable(t) then
        return self:getTypeFromTypeNode(extendsNode)
    end
    return nil
end
