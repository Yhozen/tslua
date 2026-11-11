local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local collections = require("tslua.collections")
local evaluator = require("tslua.evaluator")

local TypeFlags = checker.TypeFlags
local VarianceFlags = checker.VarianceFlags
local SignatureFlags = checker.SignatureFlags

-- Struct classes. defineStruct creates the class table checker[name] and the constructor
-- checker[name .. "_new"](init), which returns a new instance with every numeric/bool/string field
-- (including those of the embedded base struct) set to its Go zero value and the fields of `init`
-- copied over. `base` is the embedded struct: method lookup falls back to it like Go embedding.
function checker.defineStruct(name, base, zeroFields)
    local class = {}
    class.__index = class
    class.__name = name
    local zeros = {}
    if base ~= nil then
        setmetatable(class, { __index = base })
        for k, v in pairs(rawget(base, "__zeros")) do
            zeros[k] = v
        end
    end
    if zeroFields ~= nil then
        for k, v in pairs(zeroFields) do
            zeros[k] = v
        end
    end
    class.__zeros = zeros
    checker[name] = class
    checker[name .. "_new"] = function(init)
        local o = {}
        for k, v in pairs(zeros) do
            o[k] = v
        end
        if init ~= nil then
            for k, v in pairs(init) do
                o[k] = v
            end
        end
        return setmetatable(o, class)
    end
    return class
end

local defineStruct = checker.defineStruct

-- Returns xs[a:b] as a new array (Go slices.Clip(xs[a:b])).
local function sliceOf(xs, a, b)
    local result = {}
    if xs ~= nil then
        for i = a + 1, b do
            result[#result + 1] = xs[i]
        end
    end
    return result
end

checker.externalHelpersModuleNameText = "tslib"

-- Links for referenced symbols

defineStruct("SymbolReferenceLinks", nil, { referenceKinds = 0 })

-- Links for value symbols

defineStruct("ValueSymbolLinks", nil, { functionOrConstructorChecked = false })

-- Additional links for mapped symbols

defineStruct("MappedSymbolLinks", nil, nil)

-- Additional links for deferred type symbols

defineStruct("DeferredSymbolLinks", nil, nil)

-- Links for alias symbols

defineStruct("AliasSymbolLinks", nil, { referenced = false })

-- Links for module symbols

defineStruct("ModuleSymbolLinks", nil, { exportsChecked = false })

defineStruct("ReverseMappedSymbolLinks", nil, nil)

-- Links for late-bound symbols

defineStruct("LateBoundLinks", nil, nil)

-- Links for export type symbols

defineStruct("ExportTypeLinks", nil, nil)

-- Links for type aliases

defineStruct("TypeAliasLinks", nil, { isConstructorDeclaredProperty = false })

-- Links for declared types (type parameters, class types, interface types, enums)

defineStruct("DeclaredTypeLinks", nil, {
    interfaceChecked = false,
    indexSignaturesChecked = false,
    typeParametersChecked = false,
    enumChecked = false,
})

-- Links for switch clauses

defineStruct("SwitchStatementLinks", nil, {
    exhaustiveState = checker.ExhaustiveState.Unknown,
    switchTypesComputed = false,
    witnessesComputed = false,
})

defineStruct("ArrayLiteralLinks", nil, {
    indicesComputed = false,
    firstSpreadIndex = 0, -- Index of first spread expression (or -1 if none)
    lastSpreadIndex = 0, -- Index of last spread expression (or -1 if none)
})

-- Links for late-binding containers

-- MembersAndExportsLinks is Go [2]ast.SymbolTable indexed by MembersOrExportsResolutionKind:
-- Go links[kind] -> links[kind + 1].
defineStruct("MembersAndExportsLinks", nil, nil)

-- Links for synthetic spread properties

defineStruct("SpreadLinks", nil, nil)

-- Links for variances of type aliases and interface types

defineStruct("VarianceLinks", nil, nil)

function checker.VarianceFlags_String(v)
    local variance = v & VarianceFlags.VarianceMask
    local result
    if variance == VarianceFlags.Invariant then
        result = "in out"
    elseif variance == VarianceFlags.Bivariant then
        result = "[bivariant]"
    elseif variance == VarianceFlags.Contravariant then
        result = "in"
    elseif variance == VarianceFlags.Covariant then
        result = "out"
    elseif variance == VarianceFlags.Independent then
        result = "[independent]"
    else
        result = ""
    end
    if v & VarianceFlags.Unmeasurable ~= 0 then
        result = result .. " (unmeasurable)"
    elseif v & VarianceFlags.Unreliable ~= 0 then
        result = result .. " (unreliable)"
    end
    return result
end

defineStruct("MarkedAssignmentSymbolLinks", nil, {
    lastAssignmentPos = 0,
    hasDefiniteAssignment = false, -- Symbol is definitely assigned somewhere
})

-- accessibleChainCacheKey{useOnlyExternalAliasing, location, meaning} as a map key string.
function checker.accessibleChainCacheKey(useOnlyExternalAliasing, location, meaning)
    local locationId = 0
    if location ~= nil then
        locationId = ast.GetNodeId(location)
    end
    return (useOnlyExternalAliasing and "1" or "0") .. ":" .. locationId .. ":" .. meaning
end

defineStruct("ContainingSymbolLinks", nil, nil)

-- Common links

defineStruct("NodeLinks", nil, {
    flags = 0, -- Set of flags specific to Node
    declarationRequiresScopeChange = core.Tristate.TSUnknown, -- Set by `useOuterVariableScopeInParameter` in checker when downlevel emit would change the name resolution scope inside of a parameter.
    hasReportedStatementInAmbientContext = false, -- Cache boolean if we report statements in ambient context
})

defineStruct("SymbolNodeLinks", nil, nil)

defineStruct("TypeNodeLinks", nil, nil)

-- hasName is Go *bool: nil, true or false.
defineStruct("ComputedNameNodeLinks", nil, { name = "" })

-- Links for enum members

defineStruct("EnumMemberLinks", nil, nil)
local newEnumMemberLinks = checker.EnumMemberLinks_new
function checker.EnumMemberLinks_new(init)
    local links = newEnumMemberLinks(init)
    if links.value == nil then
        links.value = evaluator.NewResult(nil, false, false, false) -- Constant value of enum member
    end
    return links
end

-- Links for assertion expressions

defineStruct("AssertionLinks", nil, nil)

-- SourceFile links

defineStruct("SourceFileLinks", nil, {
    typeChecked = false,
    unusedChecked = false,
    requestedExternalEmitHelpers = 0,
    localJsxNamespace = "",
    localJsxFragmentNamespace = "",
})
local newSourceFileLinks = checker.SourceFileLinks_new
function checker.SourceFileLinks_new(init)
    local links = newSourceFileLinks(init)
    if links.deferredNodes == nil then
        links.deferredNodes = collections.NewOrderedSetWithSizeHint(0)
    end
    return links
end

-- Signature specific links

defineStruct("SignatureLinks", nil, nil)

local typeFlagNames = {
    { TypeFlags.Any, "Any" },
    { TypeFlags.Unknown, "Unknown" },
    { TypeFlags.Undefined, "Undefined" },
    { TypeFlags.Null, "Null" },
    { TypeFlags.Void, "Void" },
    { TypeFlags.String, "String" },
    { TypeFlags.Number, "Number" },
    { TypeFlags.BigInt, "BigInt" },
    { TypeFlags.Boolean, "Boolean" },
    { TypeFlags.ESSymbol, "ESSymbol" },
    { TypeFlags.StringLiteral, "StringLiteral" },
    { TypeFlags.NumberLiteral, "NumberLiteral" },
    { TypeFlags.BigIntLiteral, "BigIntLiteral" },
    { TypeFlags.BooleanLiteral, "BooleanLiteral" },
    { TypeFlags.UniqueESSymbol, "UniqueESSymbol" },
    { TypeFlags.EnumLiteral, "EnumLiteral" },
    { TypeFlags.Enum, "Enum" },
    { TypeFlags.NonPrimitive, "NonPrimitive" },
    { TypeFlags.Never, "Never" },
    { TypeFlags.TypeParameter, "TypeParameter" },
    { TypeFlags.Object, "Object" },
    { TypeFlags.Index, "Index" },
    { TypeFlags.TemplateLiteral, "TemplateLiteral" },
    { TypeFlags.StringMapping, "StringMapping" },
    { TypeFlags.Substitution, "Substitution" },
    { TypeFlags.IndexedAccess, "IndexedAccess" },
    { TypeFlags.Conditional, "Conditional" },
    { TypeFlags.Union, "Union" },
    { TypeFlags.Intersection, "Intersection" },
}
checker.typeFlagNames = typeFlagNames

-- FormatTypeFlags returns the individual flag names as a slice of strings.
function checker.FormatTypeFlags(flags)
    local result = {}
    for _, fn in ipairs(typeFlagNames) do
        if flags & fn[1] ~= 0 then
            result[#result + 1] = fn[2]
        end
    end
    if #result == 0 then
        result[#result + 1] = "None"
    end
    return result
end

-- String returns a pipe-separated string of flag names.
function checker.TypeFlags_String(f)
    return table.concat(checker.FormatTypeFlags(f), "|")
end

-- TypeAlias

local TypeAlias = defineStruct("TypeAlias", nil, nil)

-- Symbol and TypeArguments accept a nil alias like Go; call them as TypeAlias.Symbol(a).
function TypeAlias.Symbol(a)
    if a == nil then
        return nil
    end
    return a.symbol
end

function TypeAlias.TypeArguments(a)
    if a == nil then
        return nil
    end
    return a.typeArguments
end

-- Type

local Type = defineStruct("Type", nil, {
    flags = 0,
    objectFlags = 0,
    id = 0,
})

function Type:Id()
    return self.id
end

function Type:Flags()
    return self.flags
end

function Type:ObjectFlags()
    return self.objectFlags
end

-- Casts for concrete struct types are defined below, once the classes exist. Casts for embedded
-- struct types (AsObjectType, AsStructuredType, ...) are methods of the data classes (TypeBase
-- returns nil, the embedding class returns the type itself).

function Type:Distributed()
    if self.flags & TypeFlags.Union ~= 0 then
        return self:AsUnionType().types
    elseif self.flags & TypeFlags.Never ~= 0 then
        return nil
    end
    return { self }
end

-- Common accessors

function Type:Target()
    if self.flags & TypeFlags.Object ~= 0 then
        return self:AsObjectType().target
    elseif self.flags & TypeFlags.TypeParameter ~= 0 then
        return self:AsTypeParameter().target
    elseif self.flags & TypeFlags.Index ~= 0 then
        return self:AsIndexType().target
    elseif self.flags & TypeFlags.StringMapping ~= 0 then
        return self:AsStringMappingType().target
    elseif self.flags & TypeFlags.Object ~= 0 and self.objectFlags & checker.ObjectFlags.Mapped ~= 0 then
        return self:AsMappedType().target
    end
    error("Unhandled case in Type.Target", 0)
end

function Type:Mapper()
    if self.flags & TypeFlags.Object ~= 0 then
        return self:AsObjectType().mapper
    elseif self.flags & TypeFlags.TypeParameter ~= 0 then
        return self:AsTypeParameter().mapper
    elseif self.flags & TypeFlags.Conditional ~= 0 then
        return self:AsConditionalType().mapper
    end
    error("Unhandled case in Type.Mapper", 0)
end

function Type:Types()
    if self.flags & TypeFlags.UnionOrIntersection ~= 0 then
        return self:AsUnionOrIntersectionType().types
    elseif self.flags & TypeFlags.TemplateLiteral ~= 0 then
        return self:AsTemplateLiteralType().types
    end
    error("Unhandled case in Type.Types", 0)
end

function Type:TargetInterfaceType()
    return self:AsTypeReference().target:AsInterfaceType()
end

function Type:TargetTupleType()
    return self:AsTypeReference().target:AsTupleType()
end

function Type:Symbol()
    return self.symbol
end

function Type:Alias()
    return self.alias
end

function Type:IsUnion()
    return self.flags & TypeFlags.Union ~= 0
end

function Type:IsString()
    return self.flags & TypeFlags.String ~= 0
end

function Type:IsIntersection()
    return self.flags & TypeFlags.Intersection ~= 0
end

function Type:IsStringLiteral()
    return self.flags & TypeFlags.StringLiteral ~= 0
end

function Type:IsNumberLiteral()
    return self.flags & TypeFlags.NumberLiteral ~= 0
end

function Type:IsBigIntLiteral()
    return self.flags & TypeFlags.BigIntLiteral ~= 0
end

function Type:IsEnumLiteral()
    return self.flags & TypeFlags.EnumLiteral ~= 0
end

function Type:IsBooleanLike()
    return self.flags & TypeFlags.BooleanLike ~= 0
end

function Type:IsStringLike()
    return self.flags & TypeFlags.StringLike ~= 0
end

function Type:IsClass()
    return self.objectFlags & checker.ObjectFlags.Class ~= 0
end

function Type:IsTypeParameter()
    return self.flags & TypeFlags.TypeParameter ~= 0
end

function Type:IsIndex()
    return self.flags & TypeFlags.Index ~= 0
end

function Type:IsTupleType()
    return checker.isTupleType(self)
end

-- TypeData / TypeBase

local TypeBase = defineStruct("TypeBase", Type, nil)

function TypeBase:AsType()
    return self
end

function TypeBase:AsConstrainedType()
    return nil
end

function TypeBase:AsStructuredType()
    return nil
end

function TypeBase:AsObjectType()
    return nil
end

function TypeBase:AsTypeReference()
    return nil
end

function TypeBase:AsInterfaceType()
    return nil
end

function TypeBase:AsUnionOrIntersectionType()
    return nil
end

-- IntrinsicTypeData

local IntrinsicType = defineStruct("IntrinsicType", TypeBase, { intrinsicName = "" })

function IntrinsicType:IntrinsicName()
    return self.intrinsicName
end

-- LiteralTypeData

-- value: string | jsnum.Number | bool | PseudoBigInt | nil (computed enum)
local LiteralType = defineStruct("LiteralType", TypeBase, nil)

function LiteralType:Value()
    return self.value
end

function LiteralType:FreshType()
    return self.freshType
end

function LiteralType:RegularType()
    return self.regularType
end

function LiteralType:String()
    return checker.ValueToString(self.value)
end

-- UniqueESSymbolTypeData

defineStruct("UniqueESSymbolType", TypeBase, { name = "" })

-- ConstrainedType (type with computed base constraint)

local ConstrainedType = defineStruct("ConstrainedType", TypeBase, nil)

function ConstrainedType:AsConstrainedType()
    return self
end

-- StructuredType (base of all types with members)

local StructuredType = defineStruct("StructuredType", ConstrainedType, {
    callSignatureCount = 0, -- Count of call signatures
})

function StructuredType:AsStructuredType()
    return self
end

function StructuredType:CallSignatures()
    return sliceOf(self.signatures, 0, self.callSignatureCount)
end

function StructuredType:ConstructSignatures()
    return sliceOf(self.signatures, self.callSignatureCount, core.Len(self.signatures))
end

function StructuredType:Properties()
    return self.properties
end

-- Except for tuple type references and reverse mapped types, all object types have an associated symbol.
-- Possible object type instances are listed in the following.

-- InterfaceType:
-- ObjectFlagsClass: Originating non-generic class type
-- ObjectFlagsClass|ObjectFlagsReference: Originating generic class type
-- ObjectFlagsInterface: Originating non-generic interface type
-- ObjectFlagsInterface|ObjectFlagsReference: Originating generic interface type

-- TupleType:
-- ObjectFlagsReference|ObjectFlagsTuple: Originating generic tuple type (synthesized)

-- TypeReference
-- ObjectFlagsReference: Instantiated generic class, interface, or tuple type

-- ObjectType:
-- ObjectFlagsAnonymous: Originating anonymous object type
-- ObjectFlagsAnonymous|ObjectFlagsInstantiated: Instantiated anonymous object type

-- MappedType:
-- ObjectFlagsMapped: Originating mapped type
-- ObjectFlagsMapped|ObjectFlagsInstantiated: Instantiated mapped type

-- InstantiationExpressionType:
-- ObjectFlagsAnonymous|ObjectFlagsInstantiationExpression: Originating instantiation expression type
-- ObjectFlagsAnonymous|ObjectFlagsInstantiated|ObjectFlagsInstantiationExpression: Instantiated instantiation expression type

-- ReverseMappedType:
-- ObjectFlagsAnonymous|ObjectFlagsReverseMapped: Reverse mapped type

-- EvolvingArrayType:
-- ObjectFlagsEvolvingArray: Evolving array type

local ObjectType = defineStruct("ObjectType", StructuredType, nil)

function ObjectType:AsObjectType()
    return self
end

-- TypeReference (instantiation of an InterfaceType)

local TypeReference = defineStruct("TypeReference", ObjectType, nil)

function TypeReference:AsTypeReference()
    return self
end

-- InterfaceType (when generic, serves as reference to instantiation of itself)

local InterfaceType = defineStruct("InterfaceType", TypeReference, {
    outerTypeParameterCount = 0, -- Count of outer type parameters
    baseTypesResolved = false,
    declaredMembersResolved = false,
})

function InterfaceType:AsInterfaceType()
    return self
end

function InterfaceType:OuterTypeParameters()
    if core.Len(self.allTypeParameters) == 0 then
        return nil
    end
    return sliceOf(self.allTypeParameters, 0, self.outerTypeParameterCount)
end

function InterfaceType:LocalTypeParameters()
    if core.Len(self.allTypeParameters) == 0 then
        return nil
    end
    return sliceOf(self.allTypeParameters, self.outerTypeParameterCount, #self.allTypeParameters - 1)
end

function InterfaceType:TypeParameters()
    if core.Len(self.allTypeParameters) == 0 then
        return nil
    end
    return sliceOf(self.allTypeParameters, 0, #self.allTypeParameters - 1)
end

-- TupleType

local TupleElementInfo = defineStruct("TupleElementInfo", nil, { flags = 0 })

function TupleElementInfo:TupleElementFlags()
    return self.flags
end

function TupleElementInfo:LabeledDeclaration()
    return self.labeledDeclaration
end

local TupleType = defineStruct("TupleType", InterfaceType, {
    minLength = 0, -- Number of required or variadic elements
    fixedLength = 0, -- Number of initial required or optional elements
    combinedFlags = 0,
    readonly = false,
})

function TupleType:FixedLength()
    return self.fixedLength
end

function TupleType:IsReadonly()
    return self.readonly
end

function TupleType:ElementFlags()
    local elementFlags = {}
    for i, info in ipairs(self.elementInfos or {}) do
        elementFlags[i] = info.flags
    end
    return elementFlags
end

function TupleType:ElementInfos()
    return self.elementInfos
end

-- InstantiationExpressionType

defineStruct("InstantiationExpressionType", ObjectType, nil)

-- MappedType

defineStruct("MappedType", ObjectType, { containsError = false })

-- ReverseMappedType

defineStruct("ReverseMappedType", ObjectType, nil)

-- EvolvingArrayType

defineStruct("EvolvingArrayType", ObjectType, nil)

-- UnionOrIntersectionTypeData

local UnionOrIntersectionType = defineStruct("UnionOrIntersectionType", StructuredType, nil)

function UnionOrIntersectionType:AsUnionOrIntersectionType()
    return self
end

function UnionOrIntersectionType:Types()
    return self.types
end

-- UnionType

-- keyPropertyName: Property with unique unit type that exists in every object/intersection in union type
-- constituentMap: Constituents keyed by unit type discriminants
defineStruct("UnionType", UnionOrIntersectionType, { keyPropertyName = "" })

-- IntersectionType

defineStruct("IntersectionType", UnionOrIntersectionType, nil)

-- TypeParameter

local TypeParameter = defineStruct("TypeParameter", ConstrainedType, { isThisType = false })

function TypeParameter:IsThisType()
    return self.isThisType
end

-- IndexType

local IndexType = defineStruct("IndexType", ConstrainedType, { indexFlags = 0 })

function IndexType:Target()
    return self.target
end

-- IndexedAccessType

local IndexedAccessType = defineStruct("IndexedAccessType", ConstrainedType, {
    accessFlags = 0, -- Only includes AccessFlags.Persistent
})

function IndexedAccessType:ObjectType()
    return self.objectType
end

function IndexedAccessType:IndexType()
    return self.indexType
end

-- texts: Always one element longer than types
-- types: Always at least one element
local TemplateLiteralType = defineStruct("TemplateLiteralType", ConstrainedType, nil)

function TemplateLiteralType:Texts()
    return self.texts
end

function TemplateLiteralType:Types()
    return self.types
end

local StringMappingType = defineStruct("StringMappingType", ConstrainedType, nil)

function StringMappingType:Target()
    return self.target
end

-- baseType: Target type
-- constraint: Constraint that target type is known to satisfy
local SubstitutionType = defineStruct("SubstitutionType", ConstrainedType, nil)

function SubstitutionType:BaseType()
    return self.baseType
end

function SubstitutionType:SubstConstraint()
    return self.constraint
end

defineStruct("ConditionalRoot", nil, { isDistributive = false })

-- resolvedInferredTrueType: The `trueType` instantiated with the `combinedMapper`, if present
local ConditionalType = defineStruct("ConditionalType", ConstrainedType, nil)

function ConditionalType:CheckType()
    return self.checkType
end

function ConditionalType:ExtendsType()
    return self.extendsType
end

-- Concrete casts: the type table is its own data; assert the data struct like Go's type assertion.

local function defineCast(methodName, class)
    Type[methodName] = function(t)
        if getmetatable(t) ~= class then
            error("interface conversion: checker.TypeData is not *checker." .. class.__name, 0)
        end
        return t
    end
end

defineCast("AsIntrinsicType", IntrinsicType)
defineCast("AsLiteralType", LiteralType)
defineCast("AsUniqueESSymbolType", checker.UniqueESSymbolType)
defineCast("AsTupleType", TupleType)
defineCast("AsInstantiationExpressionType", checker.InstantiationExpressionType)
defineCast("AsMappedType", checker.MappedType)
defineCast("AsReverseMappedType", checker.ReverseMappedType)
defineCast("AsEvolvingArrayType", checker.EvolvingArrayType)
defineCast("AsTypeParameter", TypeParameter)
defineCast("AsUnionType", checker.UnionType)
defineCast("AsIntersectionType", checker.IntersectionType)
defineCast("AsIndexType", IndexType)
defineCast("AsIndexedAccessType", IndexedAccessType)
defineCast("AsTemplateLiteralType", TemplateLiteralType)
defineCast("AsStringMappingType", StringMappingType)
defineCast("AsSubstitutionType", SubstitutionType)
defineCast("AsConditionalType", ConditionalType)

-- Signature

local Signature = defineStruct("Signature", nil, {
    id = 0,
    flags = 0,
    minArgumentCount = 0,
    resolvedMinArgumentCount = 0,
})

function Signature:Id()
    return self.id
end

function Signature:Flags()
    return self.flags
end

function Signature:TypeParameters()
    return self.typeParameters
end

function Signature:Declaration()
    return self.declaration
end

function Signature:Target()
    return self.target
end

function Signature:ThisParameter()
    return self.thisParameter
end

function Signature:Parameters()
    return self.parameters
end

function Signature:HasRestParameter()
    return self.flags & SignatureFlags.HasRestParameter ~= 0
end

function Signature:MinArgumentCount()
    return self.minArgumentCount
end

-- isUnion: True for union, false for intersection
defineStruct("CompositeSignature", nil, { isUnion = false })

local TypePredicate = defineStruct("TypePredicate", nil, {
    kind = 0,
    parameterIndex = 0,
    parameterName = "",
})

function TypePredicate:Type()
    return self.t
end

function TypePredicate:Kind()
    return self.kind
end

function TypePredicate:ParameterIndex()
    return self.parameterIndex
end

function TypePredicate:ParameterName()
    return self.parameterName
end

-- IndexInfo

-- declaration: IndexSignatureDeclaration
-- indexSymbol: Synthetic property symbol for this index signature
-- components: ElementWithComputedPropertyName
local IndexInfo = defineStruct("IndexInfo", nil, { isReadonly = false })

function IndexInfo:KeyType()
    return self.keyType
end

function IndexInfo:ValueType()
    return self.valueType
end

function IndexInfo:IsReadonly()
    return self.isReadonly
end

function IndexInfo:Declaration()
    return self.declaration
end

checker.LanguageFeatureMinimumTarget = {
    Exponentiation = core.ScriptTarget.ES2016,
    AsyncFunctions = core.ScriptTarget.ES2017,
    ForAwaitOf = core.ScriptTarget.ES2018,
    AsyncGenerators = core.ScriptTarget.ES2018,
    AsyncIteration = core.ScriptTarget.ES2018,
    ObjectSpreadRest = core.ScriptTarget.ES2018,
    RegularExpressionFlagsDotAll = core.ScriptTarget.ES2018,
    BindinglessCatch = core.ScriptTarget.ES2019,
    BigInt = core.ScriptTarget.ES2020,
    NullishCoalesce = core.ScriptTarget.ES2020,
    OptionalChaining = core.ScriptTarget.ES2020,
    LogicalAssignment = core.ScriptTarget.ES2021,
    TopLevelAwait = core.ScriptTarget.ES2022,
    ClassFields = core.ScriptTarget.ES2022,
    PrivateNamesAndClassStaticBlocks = core.ScriptTarget.ES2022,
    RegularExpressionFlagsHasIndices = core.ScriptTarget.ES2022,
    ShebangComments = core.ScriptTarget.ESNext,
    UsingAndAwaitUsing = core.ScriptTarget.ESNext,
    ClassAndClassElementDecorators = core.ScriptTarget.ESNext,
    RegularExpressionFlagsUnicodeSets = core.ScriptTarget.ESNext,
}
