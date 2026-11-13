local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local evaluator = require("tslua.evaluator")
local jsnum = require("tslua.jsnum")
local binder = require("tslua.binder")
local debug = require("tslua.debug")
local scanner = require("tslua.scanner")

local Checker = checker.Checker
local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local VarianceFlags = checker.VarianceFlags
local RelationComparisonResult = checker.RelationComparisonResult
local TypePredicateKind = checker.TypePredicateKind
local SymbolFlags = ast.SymbolFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local FindAncestorResult = ast.FindAncestorResult
local Tristate = core.Tristate
local MembersOrExportsResolutionKind = checker.MembersOrExportsResolutionKind
local ModifierFlags = ast.ModifierFlags

-- CheckMode, TypeSystemPropertyName, WideningKind, CachedTypeKind, InferenceFlags,
-- InferencePriority, DeclarationMeaning, DeclarationSpaces, IntrinsicTypeKind,
-- MappedTypeModifiers, MappedTypeNameTypeKind, ReferenceHint, TypeFacts, IterationUse and
-- IterationTypeKind are generated constants (consts_generated.lua).

-- TypeSystemEntity is any value (symbol, type, signature, node).

-- TypeResolution: value struct stored in c.typeResolutions.
defineStruct("TypeResolution", nil, { propertyName = 0, result = false })

-- ContextualInfo

defineStruct("ContextualInfo", nil, { isCache = false })

-- InferenceContextInfo

defineStruct("InferenceContextInfo", nil, nil)

-- Struct map keys are strings built from the struct fields in Go declaration order (see
-- docs/CHECKER.md). Pointers are encoded by their id.

local objectKeyIds = setmetatable({}, { __mode = "k" })
local nextObjectKeyId = 0

-- getObjectKeyId returns a stable unique id for an object that has no id of its own (for example
-- a flow node), for use in struct map keys.
function checker.getObjectKeyId(x)
    if x == nil then
        return 0
    end
    local id = objectKeyIds[x]
    if id == nil then
        nextObjectKeyId = nextObjectKeyId + 1
        id = nextObjectKeyId
        objectKeyIds[x] = id
    end
    return id
end

local function typeKeyId(t)
    if t == nil then
        return 0
    end
    return t.id
end

local function symbolKeyId(s)
    if s == nil then
        return 0
    end
    return ast.GetSymbolId(s)
end

local function nodeKeyId(n)
    if n == nil then
        return 0
    end
    return ast.GetNodeId(n)
end

local function boolKey(b)
    if b then
        return "1"
    end
    return "0"
end

-- Encodes an `any` value (string | jsnum.Number | bool | PseudoBigInt | nil) for use in a key.
local function anyKey(v)
    local tv = type(v)
    if tv == "string" then
        return "s" .. v
    elseif tv == "number" then
        if v == 0 then
            v = 0.0 -- Go: -0 == +0 as interface values
        end
        return "n" .. string.format("%.17g", v)
    elseif tv == "boolean" then
        return "b" .. boolKey(v)
    elseif v == nil then
        return "z"
    end
    return "p" .. v:String()
end

-- EnumLiteralKey

function checker.EnumLiteralKey(enumSymbol, value)
    return symbolKeyId(enumSymbol) .. ":" .. anyKey(value)
end

-- EnumRelationKey

function checker.EnumRelationKey(sourceId, targetId)
    return sourceId .. ":" .. targetId
end

-- CachedTypeKey

function checker.CachedTypeKey(kind, typeId)
    return kind .. ":" .. typeId
end

-- NarrowedTypeKey

function checker.NarrowedTypeKey(t, candidate, assumeTrue, checkDerived)
    return typeKeyId(t) .. ":" .. typeKeyId(candidate) .. ":" .. boolKey(assumeTrue) .. boolKey(checkDerived)
end

-- UnionOfUnionKey

function checker.UnionOfUnionKey(id1, id2, r, a)
    return id1 .. ":" .. id2 .. ":" .. r .. ":" .. a
end

-- CachedSignatureKey

function checker.CachedSignatureKey(sig, key)
    local id = 0
    if sig ~= nil then
        id = sig.id
    end
    return id .. ":" .. key
end

-- CacheHashKey is the unhashed key byte string prefixed with "h" (see docs/CHECKER.md); the zero
-- CacheHashKey is "".
function checker.hashString128(s)
    return "h" .. s
end

checker.SignatureKeyErased = checker.hashString128("-")
checker.SignatureKeyCanonical = checker.hashString128("*")
checker.SignatureKeyBase = checker.hashString128("#")
checker.SignatureKeyInner = checker.hashString128("<")
checker.SignatureKeyOuter = checker.hashString128(">")

-- StringMappingKey

function checker.StringMappingKey(s, t)
    return symbolKeyId(s) .. ":" .. typeKeyId(t)
end

-- AssignmentReducedKey

function checker.AssignmentReducedKey(id1, id2)
    return id1 .. ":" .. id2
end

-- DiscriminatedContextualTypeKey

function checker.DiscriminatedContextualTypeKey(nodeId, typeId)
    return nodeId .. ":" .. typeId
end

-- InstantiationExpressionKey

function checker.InstantiationExpressionKey(nodeId, typeId)
    return nodeId .. ":" .. typeId
end

-- SubstitutionTypeKey

function checker.SubstitutionTypeKey(baseId, constraintId)
    return baseId .. ":" .. constraintId
end

-- ReverseMappedTypeKey

function checker.ReverseMappedTypeKey(sourceId, targetId, constraintId)
    return sourceId .. ":" .. targetId .. ":" .. constraintId
end

-- IterationTypesKey

function checker.IterationTypesKey(typeId, use)
    return typeId .. ":" .. use
end

-- PropertiesTypesKey

function checker.PropertiesTypesKey(typeId, include, includeOrigin, unresolvedMembers)
    return typeId .. ":" .. include .. ":" .. boolKey(includeOrigin) .. boolKey(unresolvedMembers)
end

-- NonExistentPropertyKey

function checker.NonExistentPropertyKey(propNode, containingType, isUncheckedJS)
    return nodeKeyId(propNode) .. ":" .. typeKeyId(containingType) .. ":" .. boolKey(isUncheckedJS)
end

-- FlowLoopKey

function checker.FlowLoopKey(flowNode, refKey)
    return checker.getObjectKeyId(flowNode) .. ":" .. refKey
end

-- FlowLoopInfo: { key = FlowLoopKey string, types = []*Type }
defineStruct("FlowLoopInfo", nil, nil)

-- InferenceContext

defineStruct("InferenceContext", nil, {
    flags = 0, -- Inference flags
})

defineStruct("InferenceInfo", nil, {
    priority = 0, -- Priority of current inference set
    topLevel = false, -- True if all inferences are to top level occurrences
    isFixed = false, -- True if inferences are fixed
    impliedArity = 0, -- Implied arity (or -1)
})

defineStruct("IntraExpressionInferenceSite", nil, nil)

checker.intrinsicTypeKinds = {
    Uppercase = checker.IntrinsicTypeKind.Uppercase,
    Lowercase = checker.IntrinsicTypeKind.Lowercase,
    Capitalize = checker.IntrinsicTypeKind.Capitalize,
    Uncapitalize = checker.IntrinsicTypeKind.Uncapitalize,
    NoInfer = checker.IntrinsicTypeKind.NoInfer,
}

-- IterationTypes: value struct { yieldType, returnType, nextType }
defineStruct("IterationTypes", nil, nil)

-- IterationTypesResolver: function-valued fields are called with a dot.
defineStruct("IterationTypesResolver", nil, { iteratorSymbolName = "" })

defineStruct("WideningContext", nil, {
    propertyName = "", -- Name of property in parent
})

defineStruct("VarianceStackEntry", nil, nil)

checker.maxSerializationLevel = 2

-- Program and Host are interfaces: the program object passed to NewChecker provides the Go
-- methods (Options, SourceFiles, BindSourceFiles, GetSourceFile, ...), called with a colon.

-- Checker

checker.nextCheckerID = 0

-- sync.Mutex stand-in: the checker is single-threaded.
local noopMutex = {}
noopMutex.__index = noopMutex
checker.noopMutex = noopMutex

function noopMutex:Lock()
end

function noopMutex:Unlock()
end

function noopMutex:TryLock()
    return true
end

-- sync.Once stand-in: once:Do(f) runs f the first time only.
local syncOnce = {}
syncOnce.__index = syncOnce
checker.syncOnce = syncOnce

function checker.newSyncOnce()
    return setmetatable({ done = false }, syncOnce)
end

function syncOnce:Do(f)
    if not self.done then
        self.done = true
        f()
    end
end

local function newDiagnosticsCollection()
    if ast.NewDiagnosticsCollection ~= nil then
        return ast.NewDiagnosticsCollection()
    end
    return setmetatable({ count = 0, nonFileDiagnosticsSorted = false }, ast.DiagnosticsCollection)
end

local function newSet()
    return collections.NewSetWithSizeHint(0)
end

function checker.NewChecker(program, tracer)
    program:BindSourceFiles()

    local c = setmetatable({}, Checker)
    -- Go zero values for every field that is not explicitly initialized below.
    c.typeCount = 0
    c.symbolCount = 0
    c.signatureCount = 0
    c.totalInstantiationCount = 0
    c.instantiationCount = 0
    c.instantiationDepth = 0
    c.conditionalConstraintDepth = 0
    c.inlineLevel = 0
    c.serializationLevel = 0
    c.currentNode = nil
    c.varianceTypeParameter = nil
    c.isInferencePartiallyBlocked = false
    c.wasCanceled = false
    c.thisExpandoKinds = {}
    c.markerTypes = newSet()
    c.resolvingExplicitTypeOfSymbol = newSet()
    c.symbolTableAliasCache = {}
    c.classExpressionNameTables = {}
    c.diagnostics = newDiagnosticsCollection()
    c.suggestionDiagnostics = newDiagnosticsCollection()
    c.symbolArena = core.NewArena(function()
        return ast.NewSymbol(0, "")
    end)
    c.signatureArena = core.NewArena(checker.Signature_new)
    c.indexInfoArena = core.NewArena(checker.IndexInfo_new)
    c.factory = ast.NewNodeFactory(nil)
    c.nodeLinks = checker.NewLinkStore(checker.NodeLinks_new)
    c.signatureLinks = checker.NewLinkStore(checker.SignatureLinks_new)
    c.symbolNodeLinks = checker.NewLinkStore(checker.SymbolNodeLinks_new)
    c.typeNodeLinks = checker.NewLinkStore(checker.TypeNodeLinks_new)
    c.enumMemberLinks = checker.NewLinkStore(checker.EnumMemberLinks_new)
    c.assertionLinks = checker.NewLinkStore(checker.AssertionLinks_new)
    c.arrayLiteralLinks = checker.NewLinkStore(checker.ArrayLiteralLinks_new)
    c.switchStatementLinks = checker.NewLinkStore(checker.SwitchStatementLinks_new)
    c.jsxElementLinks = checker.NewLinkStore(function()
        return checker.JsxElementLinks_new()
    end)
    c.computedNameLinks = checker.NewLinkStore(checker.ComputedNameNodeLinks_new)
    c.symbolReferenceLinks = checker.NewLinkStore(checker.SymbolReferenceLinks_new)
    c.valueSymbolLinks = checker.NewLinkStore(checker.ValueSymbolLinks_new)
    c.mappedSymbolLinks = checker.NewLinkStore(checker.MappedSymbolLinks_new)
    c.deferredSymbolLinks = checker.NewLinkStore(checker.DeferredSymbolLinks_new)
    c.aliasSymbolLinks = checker.NewLinkStore(checker.AliasSymbolLinks_new)
    c.moduleSymbolLinks = checker.NewLinkStore(checker.ModuleSymbolLinks_new)
    c.lateBoundLinks = checker.NewLinkStore(checker.LateBoundLinks_new)
    c.exportTypeLinks = checker.NewLinkStore(checker.ExportTypeLinks_new)
    c.membersAndExportsLinks = checker.NewLinkStore(checker.MembersAndExportsLinks_new)
    c.typeAliasLinks = checker.NewLinkStore(checker.TypeAliasLinks_new)
    c.declaredTypeLinks = checker.NewLinkStore(checker.DeclaredTypeLinks_new)
    c.spreadLinks = checker.NewLinkStore(checker.SpreadLinks_new)
    c.varianceLinks = checker.NewLinkStore(checker.VarianceLinks_new)
    c.reverseMappedSymbolLinks = checker.NewLinkStore(checker.ReverseMappedSymbolLinks_new)
    c.markedAssignmentSymbolLinks = checker.NewLinkStore(checker.MarkedAssignmentSymbolLinks_new)
    c.symbolContainerLinks = checker.NewLinkStore(checker.ContainingSymbolLinks_new)
    c.sourceFileLinks = checker.NewLinkStore(checker.SourceFileLinks_new)
    c.regExpScanner = nil
    c.reliabilityFlags = 0
    c.patternAmbientModules = nil
    c.patternAmbientModuleAugmentations = nil
    c.deferredGlobalImportMetaExpressionType = nil
    c.contextualBindingPatterns = nil
    c.typeResolutions = {}
    c.resolutionStart = 0
    c.varianceStack = {}
    c.apparentArgumentCount = nil
    c.lastGetCombinedNodeFlagsNode = nil
    c.lastGetCombinedNodeFlagsResult = 0
    c.lastGetCombinedModifierFlagsNode = nil
    c.lastGetCombinedModifierFlagsResult = 0
    c.freeinferenceState = nil
    c.freeFlowState = nil
    c.flowLoopStack = {}
    c.sharedFlows = {}
    c.antecedentTypes = {}
    c.flowAnalysisDisabled = false
    c.flowInvocationCount = 0
    c.flowTypeCache = nil
    c.lastFlowNode = nil
    c.lastFlowNodeReachable = false
    c.renamedBindingElementsInTypes = nil
    c.contextualInfos = {}
    c.inferenceContextInfos = {}
    c.awaitedTypeStack = {}
    c.reverseMappedSourceStack = {}
    c.reverseMappedTargetStack = {}
    c.reverseExpandingFlags = 0
    c.freeRelater = nil
    c.emitResolver = nil
    c.emitResolverOnce = checker.newSyncOnce()
    c._jsxNamespace = ""
    c._jsxFactoryEntity = nil
    c.skipDirectInferenceNodes = newSet()
    c.ctx = nil
    c.packagesMap = nil
    c.activeMappers = {}
    c.activeTypeMappersCaches = {}
    c.ambientModulesOnce = checker.newSyncOnce()
    c.ambientModules = nil
    c.withinUnreachableCode = false
    c.reportedUnreachableNodes = newSet()
    c.nonExistentProperties = newSet()
    c.deferredDiagnosticCallbacks = {}
    c.typeToStringNodebuilder = nil
    c.mu = setmetatable({}, noopMutex)

    checker.nextCheckerID = checker.nextCheckerID + 1
    c.id = checker.nextCheckerID
    c.tracer = tracer
    c.program = program
    c.compilerOptions = program:Options()
    c.files = program:SourceFiles()
    c.fileIndexMap = checker.createFileIndexMap(c.files)
    c.compareSymbols = function(a, b) -- Closure optimization
        return c:compareSymbolsWorker(a, b)
    end
    c.compareSymbolChains = function(a, b) -- Closure optimization
        return c:compareSymbolChainsWorker(a, b)
    end
    c.languageVersion = c.compilerOptions:GetEmitScriptTarget()
    c.moduleKind = c.compilerOptions:GetEmitModuleKind()
    c.moduleResolutionKind = c.compilerOptions:GetModuleResolutionKind()
    c.legacyDecorators = c.compilerOptions.experimentalDecorators == core.Tristate.TSTrue
    c.emitStandardClassFields = c.compilerOptions:GetEmitStandardClassFields()
    c.strictNullChecks = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.strictNullChecks)
    c.strictFunctionTypes = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.strictFunctionTypes)
    c.strictBindCallApply = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.strictBindCallApply)
    c.strictPropertyInitialization = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.strictPropertyInitialization)
    c.strictBuiltinIteratorReturn = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.strictBuiltinIteratorReturn)
    c.noImplicitAny = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.noImplicitAny)
    c.noImplicitThis = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.noImplicitThis)
    c.useUnknownInCatchVariables = c.compilerOptions:GetStrictOptionValue(c.compilerOptions.useUnknownInCatchVariables)
    c.exactOptionalPropertyTypes = c.compilerOptions.exactOptionalPropertyTypes == core.Tristate.TSTrue
    c.canCollectSymbolAliasAccessibilityData = core.Tristate_IsFalseOrUnknown(c.compilerOptions.verbatimModuleSyntax)
    c.arrayVariances = { VarianceFlags.Covariant }
    c.globals = ast.NewSymbolTable()
    c.evaluate = evaluator.NewEvaluator(function(expr, location)
        return c:evaluateEntity(expr, location)
    end, ast.OuterExpressionKinds.OEKParentheses)
    c.stringLiteralTypes = {}
    c.numberLiteralTypes = {}
    c.bigintLiteralTypes = {}
    c.enumLiteralTypes = {}
    c.enumNaNLiteralTypes = {}
    c.indexedAccessTypes = {}
    c.templateLiteralTypes = {}
    c.stringMappingTypes = {}
    c.uniqueESSymbolTypes = {}
    c.thisExpandoKinds = {}
    c.thisExpandoLocations = {}
    c.subtypeReductionCache = {}
    c.cachedTypes = {}
    c.cachedSignatures = {}
    c.undefinedProperties = {}
    c.narrowedTypes = {}
    c.assignmentReducedTypes = {}
    c.discriminatedContextualTypes = {}
    c.instantiationExpressionTypes = {}
    c.substitutionTypes = {}
    c.reverseMappedCache = {}
    c.reverseHomomorphicMappedCache = {}
    c.iterationTypesCache = {}
    c.undefinedSymbol = c:newSymbol(SymbolFlags.Property, "undefined")
    c.argumentsSymbol = c:newSymbol(SymbolFlags.Property, "arguments")
    c.requireSymbol = c:newSymbol(SymbolFlags.Property, "require")
    c.unknownSymbol = c:newSymbol(SymbolFlags.Property, "unknown")
    c.unresolvedSymbols = {}
    c.errorTypes = {}
    c.moduleSymbols = {}
    c.globalThisSymbol = c:newSymbolEx(SymbolFlags.Module, "globalThis", ast.CheckFlags.Readonly)
    c.globalThisSymbol.exports = c.globals
    c.globals[c.globalThisSymbol.name] = c.globalThisSymbol
    local nameResolver = c:createNameResolver()
    c.resolveName = function(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals)
        return nameResolver:Resolve(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals)
    end
    local suggestionNameResolver = c:createNameResolverForSuggestion()
    c.resolveNameForSymbolSuggestion = function(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals)
        return suggestionNameResolver:Resolve(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals)
    end
    c.tupleTypes = {}
    c.unionTypes = {}
    c.unionOfUnionTypes = {}
    c.intersectionTypes = {}
    c.propertiesTypes = {}
    c.mergedSymbols = {}
    c.patternForType = {}
    c.contextFreeTypes = {}
    c.anyType = c:newIntrinsicType(TypeFlags.Any, "any")
    c.autoType = c:newIntrinsicTypeEx(TypeFlags.Any, "any", ObjectFlags.NonInferrableType)
    c.wildcardType = c:newIntrinsicType(TypeFlags.Any, "any")
    c.blockedStringType = c:newIntrinsicType(TypeFlags.Any, "any")
    c.errorType = c:newIntrinsicType(TypeFlags.Any, "error")
    c.unresolvedType = c:newIntrinsicType(TypeFlags.Any, "unresolved")
    c.nonInferrableAnyType = c:newIntrinsicTypeEx(TypeFlags.Any, "any", ObjectFlags.ContainsWideningType)
    c.intrinsicMarkerType = c:newIntrinsicType(TypeFlags.Any, "intrinsic")
    c.unknownType = c:newIntrinsicType(TypeFlags.Unknown, "unknown")
    c.undefinedType = c:newIntrinsicType(TypeFlags.Undefined, "undefined")
    c.undefinedWideningType = c:createWideningType(c.undefinedType)
    c.missingType = c:newIntrinsicType(TypeFlags.Undefined, "undefined")
    c.undefinedOrMissingType = core.IfElse(c.exactOptionalPropertyTypes, c.missingType, c.undefinedType)
    c.optionalType = c:newIntrinsicType(TypeFlags.Undefined, "undefined")
    c.nullType = c:newIntrinsicType(TypeFlags.Null, "null")
    c.nullWideningType = c:createWideningType(c.nullType)
    c.stringType = c:newIntrinsicType(TypeFlags.String, "string")
    c.numberType = c:newIntrinsicType(TypeFlags.Number, "number")
    c.bigintType = c:newIntrinsicType(TypeFlags.BigInt, "bigint")
    c.regularFalseType = c:newLiteralType(TypeFlags.BooleanLiteral, false, nil)
    c.falseType = c:newLiteralType(TypeFlags.BooleanLiteral, false, c.regularFalseType)
    c.regularFalseType:AsLiteralType().freshType = c.falseType
    c.falseType:AsLiteralType().freshType = c.falseType
    c.regularTrueType = c:newLiteralType(TypeFlags.BooleanLiteral, true, nil)
    c.trueType = c:newLiteralType(TypeFlags.BooleanLiteral, true, c.regularTrueType)
    c.regularTrueType:AsLiteralType().freshType = c.trueType
    c.trueType:AsLiteralType().freshType = c.trueType
    c.booleanType = c:getUnionType({ c.regularFalseType, c.regularTrueType })
    c.esSymbolType = c:newIntrinsicType(TypeFlags.ESSymbol, "symbol")
    c.voidType = c:newIntrinsicType(TypeFlags.Void, "void")
    c.neverType = c:newIntrinsicType(TypeFlags.Never, "never")
    c.silentNeverType = c:newIntrinsicTypeEx(TypeFlags.Never, "never", ObjectFlags.NonInferrableType)
    c.implicitNeverType = c:newIntrinsicType(TypeFlags.Never, "never")
    c.unreachableNeverType = c:newIntrinsicType(TypeFlags.Never, "never")
    c.nonPrimitiveType = c:newIntrinsicType(TypeFlags.NonPrimitive, "object")
    c.stringOrNumberType = c:getUnionType({ c.stringType, c.numberType })
    c.stringNumberSymbolType = c:getUnionType({ c.stringType, c.numberType, c.esSymbolType })
    c.numberOrBigIntType = c:getUnionType({ c.numberType, c.bigintType })
    c.numericStringType = c:getTemplateLiteralType({ "", "" }, { c.numberType }) -- The `${number}` type
    c.templateConstraintType = c:getUnionType({ c.stringType, c.numberType, c.booleanType, c.bigintType, c.nullType, c.undefinedType })
    c.uniqueLiteralType = c:newIntrinsicType(TypeFlags.Never, "never") -- Special `never` flagged by union reduction to behave as a literal
    c.uniqueLiteralMapper = checker.newFunctionTypeMapper(function(t)
        return c:getUniqueLiteralTypeForTypeParameter(t)
    end)
    c.reportUnreliableMapper = checker.newFunctionTypeMapper(function(t)
        return c:reportUnreliableWorker(t)
    end)
    c.reportUnmeasurableMapper = checker.newFunctionTypeMapper(function(t)
        return c:reportUnmeasurableWorker(t)
    end)
    c.restrictiveMapper = checker.newFunctionTypeMapper(function(t)
        return c:restrictiveMapperWorker(t)
    end)
    c.permissiveMapper = checker.newFunctionTypeMapper(function(t)
        return c:permissiveMapperWorker(t)
    end)
    c.emptyObjectType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.emptyJsxObjectType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.emptyFreshJsxObjectType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.emptyTypeLiteralType = c:newAnonymousType(c:newSymbol(SymbolFlags.TypeLiteral, ast.InternalSymbolNameType), nil, nil, nil, nil)
    c.unknownEmptyObjectType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.unknownUnionType = c:createUnknownUnionType()
    c.emptyGenericType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.emptyGenericType:AsObjectType().instantiations = {}
    c.anyFunctionType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.anyFunctionType.objectFlags = c.anyFunctionType.objectFlags | ObjectFlags.NonInferrableType
    c.noConstraintType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.circularConstraintType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.resolvingDefaultType = c:newAnonymousType(nil --[[symbol]], nil, nil, nil, nil)
    c.markerSuperType = c:newTypeParameter(nil)
    c.markerSubType = c:newTypeParameter(nil)
    c.markerSubType:AsTypeParameter().constraint = c.markerSuperType
    c.markerOtherType = c:newTypeParameter(nil)
    c.markerSuperTypeForCheck = c:newTypeParameter(nil)
    c.markerSubTypeForCheck = c:newTypeParameter(nil)
    c.markerSubTypeForCheck:AsTypeParameter().constraint = c.markerSuperTypeForCheck
    c.noTypePredicate = checker.TypePredicate_new({ kind = TypePredicateKind.Identifier, parameterIndex = 0, parameterName = "<<unresolved>>", t = c.anyType })
    c.anySignature = c:newSignature(SignatureFlags.None, nil, nil, nil, nil, c.anyType, nil, 0)
    c.unknownSignature = c:newSignature(SignatureFlags.None, nil, nil, nil, nil, c.errorType, nil, 0)
    c.resolvingSignature = c:newSignature(SignatureFlags.None, nil, nil, nil, nil, c.anyType, nil, 0)
    c.silentNeverSignature = c:newSignature(SignatureFlags.None, nil, nil, nil, nil, c.silentNeverType, nil, 0)
    c.cachedArgumentsReferenced = {}
    c.enumNumberIndexInfo = checker.IndexInfo_new({ keyType = c.numberType, valueType = c.stringType, isReadonly = true })
    c.anyBaseTypeIndexInfo = checker.IndexInfo_new({ keyType = c.stringType, valueType = c.anyType, isReadonly = false })
    c.emptyStringType = c:getStringLiteralType("")
    c.zeroType = c:getNumberLiteralType(0.0)
    c.zeroBigIntType = c:getBigIntLiteralType(jsnum.NewPseudoBigInt("0", false))
    local typeofNames = {}
    for name in pairs(checker.typeofNEFacts) do
        typeofNames[#typeofNames + 1] = name
    end
    table.sort(typeofNames)
    c.typeofType = c:getUnionType(core.Map(typeofNames, function(name)
        return c:getStringLiteralType(name)
    end))
    c.flowLoopCache = {}
    c.flowNodeReachable = {}
    c.flowNodePostSuper = {}
    c.subtypeRelation = checker.Relation_new()
    c.strictSubtypeRelation = checker.Relation_new()
    c.assignableRelation = checker.Relation_new()
    c.comparableRelation = checker.Relation_new()
    c.identityRelation = checker.Relation_new()
    c.enumRelation = {}
    c.getGlobalESSymbolType = c:getGlobalTypeResolver("Symbol", 0 --[[arity]], false --[[reportErrors]])
    c.getGlobalBigIntType = c:getGlobalTypeResolver("BigInt", 0 --[[arity]], false --[[reportErrors]])
    c.getGlobalImportMetaType = c:getGlobalTypeResolver("ImportMeta", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalImportAttributesType = c:getGlobalTypeResolver("ImportAttributes", 0 --[[arity]], false --[[reportErrors]])
    c.getGlobalImportAttributesTypeChecked = c:getGlobalTypeResolver("ImportAttributes", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalNonNullableTypeAliasOrNil = c:getGlobalTypeAliasResolver("NonNullable", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalExtractSymbol = c:getGlobalTypeAliasResolver("Extract", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalDisposableType = c:getGlobalTypeResolver("Disposable", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalAsyncDisposableType = c:getGlobalTypeResolver("AsyncDisposable", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalAwaitedSymbol = c:getGlobalTypeAliasResolver("Awaited", 1 --[[arity]], true --[[reportErrors]])
    c.getGlobalAwaitedSymbolOrNil = c:getGlobalTypeAliasResolver("Awaited", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalNaNSymbolOrNil = c:getGlobalValueSymbolResolver("NaN", false --[[reportErrors]])
    c.getGlobalRecordSymbol = c:getGlobalTypeAliasResolver("Record", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalTemplateStringsArrayType = c:getGlobalTypeResolver("TemplateStringsArray", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalESSymbolConstructorSymbolOrNil = c:getGlobalValueSymbolResolver("Symbol", false --[[reportErrors]])
    c.getGlobalESSymbolConstructorTypeSymbolOrNil = c:getGlobalTypeSymbolResolver("SymbolConstructor", false --[[reportErrors]])
    c.getGlobalImportCallOptionsType = c:getGlobalTypeResolver("ImportCallOptions", 0 --[[arity]], false --[[reportErrors]])
    c.getGlobalImportCallOptionsTypeChecked = c:getGlobalTypeResolver("ImportCallOptions", 0 --[[arity]], true --[[reportErrors]])
    c.getGlobalPromiseType = c:getGlobalTypeResolver("Promise", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalPromiseTypeChecked = c:getGlobalTypeResolver("Promise", 1 --[[arity]], true --[[reportErrors]])
    c.getGlobalPromiseLikeType = c:getGlobalTypeResolver("PromiseLike", 1 --[[arity]], true --[[reportErrors]])
    c.getGlobalPromiseConstructorSymbol = c:getGlobalValueSymbolResolver("Promise", true --[[reportErrors]])
    c.getGlobalPromiseConstructorSymbolOrNil = c:getGlobalValueSymbolResolver("Promise", false --[[reportErrors]])
    c.getGlobalOmitSymbol = c:getGlobalTypeAliasResolver("Omit", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalNoInferSymbolOrNil = c:getGlobalTypeAliasResolver("NoInfer", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalIteratorType = c:getGlobalTypeResolver("Iterator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalIterableType = c:getGlobalTypeResolver("Iterable", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalIterableTypeChecked = c:getGlobalTypeResolver("Iterable", 3 --[[arity]], true --[[reportErrors]])
    c.getGlobalIterableIteratorType = c:getGlobalTypeResolver("IterableIterator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalIterableIteratorTypeChecked = c:getGlobalTypeResolver("IterableIterator", 3 --[[arity]], true --[[reportErrors]])
    c.getGlobalIteratorObjectType = c:getGlobalTypeResolver("IteratorObject", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalGeneratorType = c:getGlobalTypeResolver("Generator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalAsyncIteratorType = c:getGlobalTypeResolver("AsyncIterator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalAsyncIterableType = c:getGlobalTypeResolver("AsyncIterable", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalAsyncIterableTypeChecked = c:getGlobalTypeResolver("AsyncIterable", 3 --[[arity]], true --[[reportErrors]])
    c.getGlobalAsyncIterableIteratorType = c:getGlobalTypeResolver("AsyncIterableIterator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalAsyncIterableIteratorTypeChecked = c:getGlobalTypeResolver("AsyncIterableIterator", 3 --[[arity]], true --[[reportErrors]])
    c.getGlobalAsyncIteratorObjectType = c:getGlobalTypeResolver("AsyncIteratorObject", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalAsyncGeneratorType = c:getGlobalTypeResolver("AsyncGenerator", 3 --[[arity]], false --[[reportErrors]])
    c.getGlobalIteratorYieldResultType = c:getGlobalTypeResolver("IteratorYieldResult", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalIteratorReturnResultType = c:getGlobalTypeResolver("IteratorReturnResult", 1 --[[arity]], false --[[reportErrors]])
    c.getGlobalTypedPropertyDescriptorType = c:getGlobalTypeResolver("TypedPropertyDescriptor", 1 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassDecoratorContextType = c:getGlobalTypeResolver("ClassDecoratorContext", 1 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassMethodDecoratorContextType = c:getGlobalTypeResolver("ClassMethodDecoratorContext", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassGetterDecoratorContextType = c:getGlobalTypeResolver("ClassGetterDecoratorContext", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassSetterDecoratorContextType = c:getGlobalTypeResolver("ClassSetterDecoratorContext", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassAccessorDecoratorContextType = c:getGlobalTypeResolver("ClassAccessorDecoratorContext", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassAccessorDecoratorTargetType = c:getGlobalTypeResolver("ClassAccessorDecoratorTarget", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassAccessorDecoratorResultType = c:getGlobalTypeResolver("ClassAccessorDecoratorResult", 2 --[[arity]], true --[[reportErrors]])
    c.getGlobalClassFieldDecoratorContextType = c:getGlobalTypeResolver("ClassFieldDecoratorContext", 2 --[[arity]], true --[[reportErrors]])
    c:initializeClosures()
    c:initializeIterationResolvers()
    c:initializeChecker()
    return c, c.mu
end

function checker.createFileIndexMap(files)
    local result = {}
    for i, file in ipairs(files) do
        result[file] = i - 1
    end
    return result
end

function checker.countGlobalSymbols(files)
    local count = 0
    for _, file in ipairs(files) do
        if not ast.IsExternalOrCommonJSModule(file) then
            for _ in pairs(file.locals or {}) do
                count = count + 1
            end
        end
    end
    return count
end

function Checker:reportUnreliableWorker(t)
    if t == self.markerSuperType or t == self.markerSubType or t == self.markerOtherType then
        self.reliabilityFlags = self.reliabilityFlags | RelationComparisonResult.ReportsUnreliable
    end
    return t
end

function Checker:reportUnmeasurableWorker(t)
    if t == self.markerSuperType or t == self.markerSubType or t == self.markerOtherType then
        self.reliabilityFlags = self.reliabilityFlags | RelationComparisonResult.ReportsUnmeasurable
    end
    return t
end

-- Resolve to the global class or interface by the given name and arity, or emptyObjectType/emptyGenericType otherwise
function Checker:getGlobalTypeResolver(name, arity, reportErrors)
    return core.Memoize(function()
        return self:getGlobalType(name, arity, reportErrors)
    end)
end

-- Resolve to the global type alias symbol by the given name and arity, or nil otherwise
function Checker:getGlobalTypeAliasResolver(name, arity, reportErrors)
    return core.Memoize(function()
        return self:getGlobalTypeAliasSymbol(name, arity, reportErrors)
    end)
end

-- Resolve to the global value symbol by the given name, or nil otherwise
function Checker:getGlobalValueSymbolResolver(name, reportErrors)
    return core.Memoize(function()
        return self:getGlobalSymbol(name, SymbolFlags.Value, core.IfElse(reportErrors, diagnostics.Cannot_find_global_value_0, nil))
    end)
end

function Checker:getGlobalTypeSymbolResolver(name, reportErrors)
    return core.Memoize(function()
        return self:getGlobalSymbol(name, SymbolFlags.Type, core.IfElse(reportErrors, diagnostics.Cannot_find_global_type_0, nil))
    end)
end

function Checker:getGlobalTypesResolver(names, arity, reportErrors)
    return core.Memoize(function()
        return core.Map(names, function(name)
            return self:getGlobalType(name, arity, reportErrors)
        end)
    end)
end

function Checker:getGlobalTypeAliasSymbol(name, arity, reportErrors)
    local symbol = self:getGlobalSymbol(name, SymbolFlags.TypeAlias, core.IfElse(reportErrors, diagnostics.Cannot_find_global_type_0, nil))
    if symbol == nil then
        return nil
    end
    -- Resolve the declared type of the symbol. This resolves type parameters for the type alias so that we can check arity.
    self:getDeclaredTypeOfSymbol(symbol)
    if core.Len(self.typeAliasLinks:Get(symbol).typeParameters) ~= arity then
        if reportErrors then
            local decl = core.Find(symbol.declarations, ast.IsTypeAliasDeclaration)
            self:error(decl, diagnostics.Global_type_0_must_have_1_type_parameter_s, ast.SymbolName(symbol), arity)
        end
        return nil
    end
    return symbol
end

function Checker:GetTypeAliasTypeParameters(symbol)
    if symbol.flags & SymbolFlags.TypeAlias == 0 then
        error("Attempted to fetch type alias parameters for non-type-alias symbol", 0)
    end
    self:getDeclaredTypeOfSymbol(symbol)
    return self.typeAliasLinks:Get(symbol).typeParameters
end

function Checker:getGlobalType(name, arity, reportErrors)
    local symbol = self:getGlobalSymbol(name, SymbolFlags.Type, core.IfElse(reportErrors, diagnostics.Cannot_find_global_type_0, nil))
    if symbol ~= nil then
        if symbol.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
            local t = self:getDeclaredTypeOfSymbol(symbol)
            if core.Len(t:AsInterfaceType():TypeParameters()) == arity then
                return t
            end
            if reportErrors then
                self:error(checker.getGlobalTypeDeclaration(symbol), diagnostics.Global_type_0_must_have_1_type_parameter_s, ast.SymbolName(symbol), arity)
            end
        elseif reportErrors then
            self:error(checker.getGlobalTypeDeclaration(symbol), diagnostics.Global_type_0_must_be_a_class_or_interface_type, ast.SymbolName(symbol))
        end
    end
    if arity ~= 0 then
        return self.emptyGenericType
    end
    return self.emptyObjectType
end

function checker.getGlobalTypeDeclaration(symbol)
    for _, declaration in ipairs(symbol.declarations or {}) do
        local k = declaration.kind
        if k == Kind.ClassDeclaration or k == Kind.InterfaceDeclaration or k == Kind.EnumDeclaration or k == Kind.TypeAliasDeclaration then
            return declaration
        end
    end
    return nil
end

function Checker:getGlobalSymbol(name, meaning, diagnostic)
    -- Don't track references for global symbols anyway, so value if `isReference` is arbitrary
    return self.resolveName(nil, name, meaning, diagnostic, false --[[isUse]], false --[[excludeGlobals]])
end

function Checker:initializeClosures()
    local c = self
    c.isPrimitiveOrObjectOrEmptyType = function(t)
        return t.flags & (TypeFlags.Primitive | TypeFlags.NonPrimitive) ~= 0 or c:IsEmptyAnonymousObjectType(t)
    end
    c.containsMissingType = function(t)
        return t == c.missingType or t.flags & TypeFlags.Union ~= 0 and t:Types()[1] == c.missingType
    end
    c.couldContainTypeVariables = function(t)
        return c:couldContainTypeVariablesWorker(t)
    end
    c.isStringIndexSignatureOnlyType = function(t)
        return c:isStringIndexSignatureOnlyTypeWorker(t)
    end
    c.markNodeAssignments = function(node)
        return c:markNodeAssignmentsWorker(node)
    end
    c.compareTypesAssignable = function(s, t, reportErrors)
        return c:compareTypesAssignableWorker(s, t, reportErrors)
    end
end

function Checker:initializeIterationResolvers()
    local c = self
    c.syncIterationTypesResolver = checker.IterationTypesResolver_new({
        iteratorSymbolName = "iterator",
        getGlobalIteratorType = c.getGlobalIteratorType,
        getGlobalIterableType = c.getGlobalIterableType,
        getGlobalIterableTypeChecked = c.getGlobalIterableTypeChecked,
        getGlobalIterableIteratorType = c.getGlobalIterableIteratorType,
        getGlobalIterableIteratorTypeChecked = c.getGlobalIterableIteratorTypeChecked,
        getGlobalIteratorObjectType = c.getGlobalIteratorObjectType,
        getGlobalGeneratorType = c.getGlobalGeneratorType,
        getGlobalBuiltinIteratorTypes = c:getGlobalTypesResolver({ "ArrayIterator", "MapIterator", "SetIterator", "StringIterator" }, 1, false --[[reportErrors]]),
        resolveIterationType = function(t, errorNode)
            return t
        end,
        mustHaveANextMethodDiagnostic = diagnostics.An_iterator_must_have_a_next_method,
        mustBeAMethodDiagnostic = diagnostics.The_0_property_of_an_iterator_must_be_a_method,
        mustHaveAValueDiagnostic = diagnostics.The_type_returned_by_the_0_method_of_an_iterator_must_have_a_value_property,
    })
    c.asyncIterationTypesResolver = checker.IterationTypesResolver_new({
        iteratorSymbolName = "asyncIterator",
        getGlobalIteratorType = c.getGlobalAsyncIteratorType,
        getGlobalIterableType = c.getGlobalAsyncIterableType,
        getGlobalIterableTypeChecked = c.getGlobalAsyncIterableTypeChecked,
        getGlobalIterableIteratorType = c.getGlobalAsyncIterableIteratorType,
        getGlobalIterableIteratorTypeChecked = c.getGlobalAsyncIterableIteratorTypeChecked,
        getGlobalIteratorObjectType = c.getGlobalAsyncIteratorObjectType,
        getGlobalGeneratorType = c.getGlobalAsyncGeneratorType,
        getGlobalBuiltinIteratorTypes = c:getGlobalTypesResolver({ "ReadableStreamAsyncIterator" }, 1, false --[[reportErrors]]),
        resolveIterationType = function(t, errorNode)
            return c:getAwaitedTypeEx(t, errorNode, diagnostics.Type_of_await_operand_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member)
        end,
        mustHaveANextMethodDiagnostic = diagnostics.An_async_iterator_must_have_a_next_method,
        mustBeAMethodDiagnostic = diagnostics.The_0_property_of_an_async_iterator_must_be_a_method,
        mustHaveAValueDiagnostic = diagnostics.The_type_returned_by_the_0_method_of_an_async_iterator_must_be_a_promise_for_a_type_with_a_value_property,
    })
end

function Checker:initializeChecker()
    -- Initialize global symbol table
    local ambientModuleSymbols = {}
    local augmentations = {}
    for _, file in ipairs(self.files) do
        if not ast.IsExternalOrCommonJSModule(file) then
            -- It is an error for a non-external-module (i.e. script) to declare its own `globalThis`.
            local fileGlobalThisSymbol = file.locals ~= nil and file.locals["globalThis"] or nil
            if fileGlobalThisSymbol ~= nil then
                for _, d in ipairs(fileGlobalThisSymbol.declarations or {}) do
                    self:addDiagnostic(checker.NewDiagnosticForNode(d, diagnostics.Declaration_name_conflicts_with_built_in_global_identifier_0, "globalThis"))
                end
            end
            for _, symbol in pairs(file.locals or {}) do
                -- We defer merging of global ambient module declarations since they may require other global symbols
                -- and types to be resolved. See https://github.com/microsoft/typescript-go/issues/2953.
                if symbol.flags & SymbolFlags.Module ~= 0 and ast.IsAmbientModuleSymbolName(symbol.name) then
                    ambientModuleSymbols[#ambientModuleSymbols + 1] = symbol
                else
                    self:mergeGlobalSymbol(symbol)
                end
            end
        end
        for _, m in ipairs(file.patternAmbientModules or {}) do
            self.patternAmbientModules = core.Append(self.patternAmbientModules, m)
        end
        augmentations[#augmentations + 1] = file.moduleAugmentations or {}
        if file.symbol ~= nil then
            -- Merge in UMD exports with first-in-wins semantics (see #9771)
            for name, symbol in pairs(file.globalExports or {}) do
                if self.globals[name] == nil then
                    self.globals[name] = symbol
                end
            end
        end
    end
    -- We do global augmentations separately from module augmentations (and before creating global types) because they
    --  1. Affect global types. We won't have the correct global types until global augmentations are merged. Also,
    --  2. Module augmentation instantiation requires creating the type of a module, which, in turn, can require
    --       checking for an export or property on the module (if export=) which, in turn, can fall back to the
    --       apparent type of the module - either globalObjectType or globalFunctionType - which wouldn't exist if we
    --       did module augmentations prior to finalizing the global types.
    for _, list in ipairs(augmentations) do
        for _, augmentation in ipairs(list) do
            -- Merge 'global' module augmentations. This needs to be done after global symbol table is initialized to
            -- make sure that all ambient modules are indexed
            if ast.IsGlobalScopeAugmentation(augmentation.parent) then
                self:mergeModuleAugmentation(augmentation)
            end
        end
    end
    self:addUndefinedToGlobalsOrErrorOnRedeclaration()
    self.valueSymbolLinks:Get(self.undefinedSymbol).resolvedType = self.undefinedWideningType
    self.valueSymbolLinks:Get(self.argumentsSymbol).resolvedType = self:getGlobalType("IArguments", 0 --[[arity]], true --[[reportErrors]])
    self.valueSymbolLinks:Get(self.unknownSymbol).resolvedType = self.errorType
    self.valueSymbolLinks:Get(self.globalThisSymbol).resolvedType = self:newObjectType(ObjectFlags.Anonymous, self.globalThisSymbol)
    -- Initialize special types
    self.globalArrayType = self:getGlobalType("Array", 1 --[[arity]], true --[[reportErrors]])
    self.globalObjectType = self:getGlobalType("Object", 0 --[[arity]], true --[[reportErrors]])
    self.globalFunctionType = self:getGlobalType("Function", 0 --[[arity]], true --[[reportErrors]])
    self.globalCallableFunctionType = self:getGlobalStrictFunctionType("CallableFunction")
    self.globalNewableFunctionType = self:getGlobalStrictFunctionType("NewableFunction")
    self.globalStringType = self:getGlobalType("String", 0 --[[arity]], true --[[reportErrors]])
    self.globalNumberType = self:getGlobalType("Number", 0 --[[arity]], true --[[reportErrors]])
    self.globalBooleanType = self:getGlobalType("Boolean", 0 --[[arity]], true --[[reportErrors]])
    self.globalRegExpType = self:getGlobalType("RegExp", 0 --[[arity]], true --[[reportErrors]])
    self.anyArrayType = self:createArrayType(self.anyType)
    self.autoArrayType = self:createArrayType(self.autoType)
    if self.autoArrayType == self.emptyObjectType then
        -- autoArrayType is used as a marker, so even if global Array type is not defined, it needs to be a unique type
        self.autoArrayType = self:newAnonymousType(nil, nil, nil, nil, nil)
    end
    self.globalReadonlyArrayType = self:getGlobalType("ReadonlyArray", 1 --[[arity]], false --[[reportErrors]])
    if self.globalReadonlyArrayType == self.emptyGenericType then
        self.globalReadonlyArrayType = self.globalArrayType
    end
    self.anyReadonlyArrayType = self:createTypeFromGenericGlobalType(self.globalReadonlyArrayType, { self.anyType })
    self.globalThisType = self:getGlobalType("ThisType", 1 --[[arity]], false --[[reportErrors]])
    -- Now merge global ambient module declarations
    for _, symbol in ipairs(ambientModuleSymbols) do
        self:mergeGlobalSymbol(symbol)
    end
    -- merge _nonglobal_ module augmentations.
    -- this needs to be done after global symbol table is initialized to make sure that all ambient modules are indexed
    for _, list in ipairs(augmentations) do
        for _, augmentation in ipairs(list) do
            if not ast.IsGlobalScopeAugmentation(augmentation.parent) then
                self:mergeModuleAugmentation(augmentation)
            end
        end
    end
end

function Checker:mergeGlobalSymbol(symbol)
    local globalSymbol = self.globals[symbol.name]
    local merged
    if globalSymbol ~= nil then
        merged = self:mergeSymbol(globalSymbol, symbol, false --[[unidirectional]])
    else
        merged = self:getMergedSymbol(symbol)
    end
    self.globals[symbol.name] = merged
end

function Checker:mergeModuleAugmentation(moduleName)
    local moduleNode = moduleName.parent
    local moduleAugmentation = moduleNode:AsModuleDeclaration()
    if moduleAugmentation.symbol.declarations[1] ~= moduleNode then
        -- this is a combined symbol for multiple augmentations within the same file.
        -- its symbol already has accumulated information for all declarations
        -- so we need to add it just once - do the work only for first declaration
        return
    end
    if ast.IsGlobalScopeAugmentation(moduleNode) then
        self:mergeSymbolTable(self.globals, moduleAugmentation.symbol.exports, false --[[unidirectional]], nil --[[parent]])
    else
        -- find a module that about to be augmented
        -- do not validate names of augmentations that are defined in ambient context
        local moduleNotFoundError = nil
        if moduleName.parent.parent.flags & NodeFlags.Ambient == 0 then
            moduleNotFoundError = diagnostics.Invalid_module_name_in_augmentation_module_0_cannot_be_found
        end
        local mainModule = self:resolveExternalModuleNameWorker(moduleName, moduleName, moduleNotFoundError --[[ignoreErrors]], false --[[isForAugmentation]], true)
        if mainModule == nil then
            return
        end
        -- obtain item referenced by 'export='
        mainModule = self:resolveExternalModuleSymbol(mainModule, false --[[dontResolveAlias]])
        if mainModule.flags & SymbolFlags.Namespace ~= 0 then
            -- If we're merging an augmentation to a pattern ambient module, we want to
            -- perform the merge unidirectionally from the augmentation ('a.foo') to
            -- the pattern ('*.foo'), so that 'getMergedSymbol()' on a.foo gives you
            -- all the exports both from the pattern and from the augmentation, but
            -- 'getMergedSymbol()' on *.foo only gives you exports from *.foo.
            if core.Some(self.patternAmbientModules, function(module)
                return mainModule == module.symbol
            end) then
                local merged = self:mergeSymbol(moduleAugmentation.symbol, mainModule, true --[[unidirectional]])
                -- moduleName will be a StringLiteral since this is not `declare global`.
                if self.patternAmbientModuleAugmentations == nil then
                    self.patternAmbientModuleAugmentations = ast.NewSymbolTable()
                end
                self.patternAmbientModuleAugmentations[moduleName:Text()] = merged
            else
                local augmentationExports = moduleAugmentation.symbol.exports
                if mainModule.exports ~= nil and mainModule.exports[ast.InternalSymbolNameExportStar] ~= nil and augmentationExports ~= nil and next(augmentationExports) ~= nil then
                    -- We may need to merge the module augmentation's exports into the target symbols of the resolved exports
                    local resolvedExports = self:getResolvedMembersOrExportsOfSymbol(mainModule, MembersOrExportsResolutionKind.ResolvedExports)
                    for key, value in pairs(augmentationExports) do
                        if resolvedExports[key] ~= nil and mainModule.exports[key] == nil then
                            self:mergeSymbol(resolvedExports[key], value, false --[[unidirectional]])
                        end
                    end
                end
                self:mergeSymbol(mainModule, moduleAugmentation.symbol, false --[[unidirectional]])
            end
        else
            -- moduleName will be a StringLiteral since this is not `declare global`.
            self:error(moduleName, diagnostics.Cannot_augment_module_0_because_it_resolves_to_a_non_module_entity, moduleName:Text())
        end
    end
end

function Checker:addUndefinedToGlobalsOrErrorOnRedeclaration()
    local name = self.undefinedSymbol.name
    local targetSymbol = self.globals[name]
    if targetSymbol ~= nil then
        for _, declaration in ipairs(targetSymbol.declarations or {}) do
            if not ast.IsTypeDeclaration(declaration) then
                self:addDiagnostic(checker.createDiagnosticForNode(declaration, diagnostics.Declaration_name_conflicts_with_built_in_global_identifier_0, name))
            end
        end
    else
        self.globals[name] = self.undefinedSymbol
    end
end

function Checker:createNameResolver()
    local c = self
    return setmetatable({
        compilerOptions = c.compilerOptions,
        getSymbolOfDeclaration = function(node)
            return c:getSymbolOfDeclaration(node)
        end,
        error = function(location, message, ...)
            return c:error(location, message, ...)
        end,
        globals = c.globals,
        argumentsSymbol = c.argumentsSymbol,
        requireSymbol = c.requireSymbol,
        lookup = function(symbols, name, meaning)
            return c:getSymbol(symbols, name, meaning)
        end,
        symbolReferenced = function(symbol, meaning)
            c:symbolReferenced(symbol, meaning)
        end,
        setRequiresScopeChangeCache = function(node, value)
            c:setRequiresScopeChangeCache(node, value)
        end,
        getRequiresScopeChangeCache = function(node)
            return c:getRequiresScopeChangeCache(node)
        end,
        onPropertyWithInvalidInitializer = function(location, name, declaration, result)
            return c:checkAndReportErrorForInvalidInitializer(location, name, declaration, result)
        end,
        onFailedToResolveSymbol = function(location, name, meaning, nameNotFoundMessage)
            c:onFailedToResolveSymbol(location, name, meaning, nameNotFoundMessage)
        end,
        onSuccessfullyResolvedSymbol = function(location, result, meaning, lastLocation, associatedDeclarationForContainingInitializerOrBindingName, withinDeferredContext)
            c:onSuccessfullyResolvedSymbol(location, result, meaning, lastLocation, associatedDeclarationForContainingInitializerOrBindingName, withinDeferredContext)
        end,
    }, binder.NameResolver)
end

function Checker:createNameResolverForSuggestion()
    local c = self
    return setmetatable({
        compilerOptions = c.compilerOptions,
        getSymbolOfDeclaration = function(node)
            return c:getSymbolOfDeclaration(node)
        end,
        error = function(location, message, ...)
            return c:error(location, message, ...)
        end,
        globals = c.globals,
        argumentsSymbol = c.argumentsSymbol,
        requireSymbol = c.requireSymbol,
        lookup = function(symbols, name, meaning)
            return c:getSuggestionForSymbolNameLookup(symbols, name, meaning)
        end,
        symbolReferenced = function(symbol, meaning)
            c:symbolReferenced(symbol, meaning)
        end,
        setRequiresScopeChangeCache = function(node, value)
            c:setRequiresScopeChangeCache(node, value)
        end,
        getRequiresScopeChangeCache = function(node)
            return c:getRequiresScopeChangeCache(node)
        end,
    }, binder.NameResolver)
end

function Checker:symbolReferenced(symbol, meaning)
    local links = self.symbolReferenceLinks:Get(symbol)
    links.referenceKinds = links.referenceKinds | meaning
end

function Checker:getRequiresScopeChangeCache(node)
    return self.nodeLinks:Get(node).declarationRequiresScopeChange
end

function Checker:setRequiresScopeChangeCache(node, value)
    self.nodeLinks:Get(node).declarationRequiresScopeChange = value
end

-- The invalid initializer error is needed in two situation:
-- 1. When result is undefined, after checking for a missing "this."
-- 2. When result is defined
function Checker:checkAndReportErrorForInvalidInitializer(errorLocation, name, propertyWithInvalidInitializer, result)
    if not self.compilerOptions:GetEmitStandardClassFields() then
        if errorLocation ~= nil and result == nil and self:checkAndReportErrorForMissingPrefix(errorLocation, name) then
            return true
        end
        -- We have a match, but the reference occurred within a property initializer and the identifier also binds
        -- to a local variable in the constructor where the code will be emitted. Note that this is actually allowed
        -- with emitStandardClassFields because the scope semantics are different.
        local prop = propertyWithInvalidInitializer:AsPropertyDeclaration()
        local message = core.IfElse(errorLocation ~= nil and prop.type ~= nil and prop.type.loc:ContainsInclusive(errorLocation:Pos()),
            diagnostics.Type_of_instance_member_variable_0_cannot_reference_identifier_1_declared_in_the_constructor,
            diagnostics.Initializer_of_instance_member_variable_0_cannot_reference_identifier_1_declared_in_the_constructor)
        self:error(errorLocation, message, scanner.DeclarationNameToString(prop:Name()), name)
        return true
    end
    return false
end

function Checker:checkAndReportErrorForMissingPrefix(errorLocation, name)
    if not ast.IsIdentifier(errorLocation) or errorLocation:Text() ~= name or checker.isTypeReferenceIdentifier(errorLocation) or checker.IsInTypeQuery(errorLocation) then
        return false
    end
    local container = self:getThisContainer(errorLocation, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    local location = container
    while location.parent ~= nil do
        if ast.IsClassLike(location.parent) then
            local classSymbol = self:getSymbolOfDeclaration(location.parent)
            if classSymbol == nil then
                break
            end
            -- Check to see if a static member exists.
            local constructorType = self:getTypeOfSymbol(classSymbol)
            if self:getPropertyOfType(constructorType, name) ~= nil then
                self:error(errorLocation, diagnostics.Cannot_find_name_0_Did_you_mean_the_static_member_1_0, name, self:symbolToString(classSymbol))
                return true
            end
            -- No static member is present.
            -- Check if we're in an instance method and look for a relevant instance member.
            if location == container and not ast.IsStatic(location) then
                local instanceType = self:getDeclaredTypeOfSymbol(classSymbol):AsInterfaceType().thisType
                -- TODO: GH#18217
                if self:getPropertyOfType(instanceType, name) ~= nil then
                    self:error(errorLocation, diagnostics.Cannot_find_name_0_Did_you_mean_the_instance_member_this_0, name)
                    return true
                end
            end
        end
        location = location.parent
    end
    return false
end

function Checker:onFailedToResolveSymbol(errorLocation, name, meaning, nameNotFoundMessage)
    -- The `const` in a `const` assertion (`x as const`) is a syntactic marker, not a real
    -- type reference, and must never be resolved or reported as an unresolvable name.
    if checker.isConstTypeReferenceName(errorLocation) then
        return
    end
    if errorLocation ~= nil and (errorLocation.parent.kind == Kind.JSDocLink or
        self:checkAndReportErrorForMissingPrefix(errorLocation, name) or
        self:checkAndReportErrorForExtendingInterface(errorLocation) or
        self:checkAndReportErrorForUsingTypeAsNamespace(errorLocation, name, meaning) or
        self:checkAndReportErrorForExportingPrimitiveType(errorLocation, name) or
        self:checkAndReportErrorForUsingNamespaceAsTypeOrValue(errorLocation, name, meaning) or
        self:checkAndReportErrorForUsingTypeAsValue(errorLocation, name, meaning) or
        self:checkAndReportErrorForUsingValueAsType(errorLocation, name, meaning)) then
        return
    end
    local declarationName = name
    if errorLocation ~= nil and ast.IsIdentifier(errorLocation) and errorLocation:Text() == name then
        declarationName = scanner.DeclarationNameToString(errorLocation) -- use escape sequences from original file
    end
    -- Report missing lib first
    local suggestedLib = self:getSuggestedLibForNonExistentName(name)
    if suggestedLib ~= "" then
        self:error(errorLocation, nameNotFoundMessage, declarationName, suggestedLib)
        return
    end
    -- Then spelling suggestions
    local suggestion = self:getSuggestedSymbolForNonexistentSymbol(errorLocation, name, meaning)
    if suggestion ~= nil and not (suggestion.valueDeclaration ~= nil and ast.IsAmbientModule(suggestion.valueDeclaration) and ast.IsGlobalScopeAugmentation(suggestion.valueDeclaration)) then
        local suggestionName = self:symbolToString(suggestion)
        local isUncheckedJS = self:isUncheckedJSSuggestion(errorLocation, suggestion, false --[[excludeClasses]])
        local message = core.IfElse(meaning == SymbolFlags.Namespace, diagnostics.Cannot_find_namespace_0_Did_you_mean_1,
            core.IfElse(isUncheckedJS, diagnostics.Could_not_find_name_0_Did_you_mean_1, diagnostics.Cannot_find_name_0_Did_you_mean_1))
        local diagnostic = checker.NewDiagnosticForNode(errorLocation, message, declarationName, suggestionName)
        if suggestion.valueDeclaration ~= nil then
            diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(suggestion.valueDeclaration, diagnostics.X_0_is_declared_here, suggestionName))
        end
        self:addErrorOrSuggestion(not isUncheckedJS, diagnostic)
        return
    end
    -- And then fall back to unspecified "not found"
    self:error(errorLocation, nameNotFoundMessage, declarationName)
end

function Checker:checkAndReportErrorForUsingTypeAsNamespace(errorLocation, name, meaning)
    if meaning == SymbolFlags.Namespace then
        local symbol = self:resolveSymbol(self.resolveName(errorLocation, name, SymbolFlags.Type & ~SymbolFlags.Namespace, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]]))
        if symbol ~= nil then
            local parent = errorLocation.parent
            if ast.IsQualifiedName(parent) then
                debug.Assert(parent:AsQualifiedName().left == errorLocation, "Should only be resolving left side of qualified name as a namespace")
                local propName = parent:AsQualifiedName().right:Text()
                local propType = self:getPropertyOfType(self:getDeclaredTypeOfSymbol(symbol), propName)
                if propType ~= nil then
                    self:error(parent, diagnostics.Cannot_access_0_1_because_0_is_a_type_but_not_a_namespace_Did_you_mean_to_retrieve_the_type_of_the_property_1_in_0_with_0_1, name, propName)
                    return true
                end
            end
            self:error(errorLocation, diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_namespace_here, name)
            return true
        end
    end
    return false
end

function Checker:checkAndReportErrorForExportingPrimitiveType(errorLocation, name)
    if checker.isPrimitiveTypeName(name) and errorLocation.parent.kind == Kind.ExportSpecifier then
        self:error(errorLocation, diagnostics.Cannot_export_0_Only_local_declarations_can_be_exported_from_a_module, name)
        return true
    end
    return false
end

function checker.isPrimitiveTypeName(s)
    return s == "any" or s == "string" or s == "number" or s == "boolean" or s == "never" or s == "unknown"
end

function Checker:checkAndReportErrorForUsingNamespaceAsTypeOrValue(errorLocation, name, meaning)
    if meaning & (SymbolFlags.Value & ~SymbolFlags.Type) ~= 0 then
        local symbol = self:resolveSymbol(self.resolveName(errorLocation, name, SymbolFlags.NamespaceModule, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]]))
        if symbol ~= nil then
            -- `export = ns` may legitimately reference a namespace; checkExportAssignment decides
            -- whether that is an error, so don't report "cannot use namespace as a value" here.
            if not checker.isExportAssignmentExpressionName(errorLocation) then
                self:error(errorLocation, diagnostics.Cannot_use_namespace_0_as_a_value, name)
            end
            return true
        end
    elseif meaning & (SymbolFlags.Type & ~SymbolFlags.Value) ~= 0 then
        local symbol = self:resolveSymbol(self.resolveName(errorLocation, name, SymbolFlags.Module, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]]))
        if symbol ~= nil then
            self:error(errorLocation, diagnostics.Cannot_use_namespace_0_as_a_type, name)
            return true
        end
    end
    return false
end

function Checker:checkAndReportErrorForUsingTypeAsValue(errorLocation, name, meaning)
    if meaning & SymbolFlags.Value ~= 0 then
        if checker.isPrimitiveTypeName(name) then
            local grandparent = errorLocation.parent.parent
            if grandparent ~= nil and grandparent.parent ~= nil and ast.IsHeritageClause(grandparent) then
                local heritageKind = grandparent:AsHeritageClause().token
                local containerKind = grandparent.parent.kind
                if containerKind == Kind.InterfaceDeclaration and heritageKind == Kind.ExtendsKeyword then
                    self:error(errorLocation, diagnostics.An_interface_cannot_extend_a_primitive_type_like_0_It_can_only_extend_other_named_object_types, name)
                elseif ast.IsClassLike(grandparent.parent) and heritageKind == Kind.ExtendsKeyword then
                    self:error(errorLocation, diagnostics.A_class_cannot_extend_a_primitive_type_like_0_Classes_can_only_extend_constructable_values, name)
                elseif ast.IsClassLike(grandparent.parent) and heritageKind == Kind.ImplementsKeyword then
                    self:error(errorLocation, diagnostics.A_class_cannot_implement_a_primitive_type_like_0_It_can_only_implement_other_named_object_types, name)
                end
            else
                self:error(errorLocation, diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_value_here, name)
            end
            return true
        end
        local symbol = self:resolveSymbol(self.resolveName(errorLocation, name, SymbolFlags.Type & ~SymbolFlags.Value, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]]))
        if symbol ~= nil then
            local allFlags = self:getSymbolFlags(symbol)
            if allFlags & SymbolFlags.Value == 0 then
                -- `export = SomeType` may legitimately reference a type-only name; checkExportAssignment
                -- decides whether that is an error, so don't report "used as a value" here.
                if checker.isExportAssignmentExpressionName(errorLocation) then
                    return true
                end
                if checker.isES2015OrLaterConstructorName(name) then
                    self:error(errorLocation, diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_value_here_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_es2015_or_later, name)
                elseif self:maybeMappedType(errorLocation, symbol) then
                    self:error(errorLocation, diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_value_here_Did_you_mean_to_use_1_in_0, name, core.IfElse(name == "K", "P", "K"))
                else
                    self:error(errorLocation, diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_value_here, name)
                end
                return true
            end
        end
    end
    return false
end

function checker.isES2015OrLaterConstructorName(s)
    return s == "Promise" or s == "Symbol" or s == "Map" or s == "WeakMap" or s == "Set" or s == "WeakSet"
end

function Checker:maybeMappedType(node, symbol)
    while true do
        node = node.parent
        if not (ast.IsComputedPropertyName(node) or ast.IsPropertySignatureDeclaration(node)) then
            break
        end
    end
    if ast.IsTypeLiteralNode(node) and #node:Members() == 1 then
        local t = self:getDeclaredTypeOfSymbol(symbol)
        return t.flags & TypeFlags.Union ~= 0 and self:allTypesAssignableToKindEx(t, TypeFlags.StringOrNumberLiteral, true --[[strict]])
    end
    return false
end

function Checker:checkAndReportErrorForUsingValueAsType(errorLocation, name, meaning)
    if meaning & (SymbolFlags.Type & ~SymbolFlags.Namespace) ~= 0 then
        local symbol = self:resolveSymbol(self.resolveName(errorLocation, name, ~SymbolFlags.Type & SymbolFlags.Value, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]]))
        if symbol ~= nil and symbol.flags & SymbolFlags.Namespace == 0 then
            self:error(errorLocation, diagnostics.X_0_refers_to_a_value_but_is_being_used_as_a_type_here_Did_you_mean_typeof_0, name)
            return true
        end
    end
    return false
end

function Checker:getSuggestedLibForNonExistentName(name)
    local featureMap = checker.getFeatureMap()
    local typeFeatures = featureMap[name]
    if typeFeatures ~= nil then
        return typeFeatures[1].lib
    end
    return ""
end

function Checker:getSuggestedSymbolForNonexistentSymbol(location, outerName, meaning)
    return self.resolveNameForSymbolSuggestion(location, outerName, meaning, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
end

-- Go sync.OnceValue returning map[builtinName]*ast.Symbol. The entries are kept as an ordered array
-- of { builtin, symbol } pairs; consumers only use membership/iteration (order-insensitive).
local primitiveTypeAliasSuggestionsValue = nil

function checker.primitiveTypeAliasSuggestions()
    if primitiveTypeAliasSuggestionsValue == nil then
        local result = {}
        for _, e in ipairs({
            { "string", "String" },
            { "number", "Number" },
            { "boolean", "Boolean" },
            { "object", "Object" },
            { "bigint", "BigInt" },
            { "symbol", "Symbol" },
        }) do
            local sym = ast.NewSymbol(SymbolFlags.TypeAlias | SymbolFlags.Transient, e[1])
            result[#result + 1] = { e[2], sym }
        end
        primitiveTypeAliasSuggestionsValue = result
    end
    return primitiveTypeAliasSuggestionsValue
end

-- Returns a Lua iterator (Go iter.Seq[*ast.Symbol]).
function checker.getPrimitiveTypeAliasSuggestions(symbols)
    local entries = checker.primitiveTypeAliasSuggestions()
    local i = 0
    return function()
        while true do
            i = i + 1
            local e = entries[i]
            if e == nil then
                return nil
            end
            if symbols ~= nil and symbols[e[1]] ~= nil then
                return e[2]
            end
        end
    end
end

function Checker:getSuggestionForSymbolNameLookup(symbols, name, meaning)
    local symbol = self:getSymbol(symbols, name, meaning)
    if symbol ~= nil then
        return symbol
    end
    -- Go: core.ConcatenateSeq(maps.Values(symbols), extras), materialized as an array.
    local candidates = {}
    for _, s in pairs(symbols or {}) do
        candidates[#candidates + 1] = s
    end
    if meaning & SymbolFlags.GlobalLookup ~= 0 then
        for s in checker.getPrimitiveTypeAliasSuggestions(symbols) do
            candidates[#candidates + 1] = s
        end
    end
    return self:getSpellingSuggestionForName(name, candidates, meaning)
end

-- Given a name and a list of symbols whose names are *not* equal to the name, return a spelling suggestion if there is
-- one that is close enough. Names less than length 3 only check for case-insensitive equality, not levenshtein distance.
--
-- If there is a candidate that's the same except for case, return that.
-- If there is a candidate that's within one edit of the name, return that.
-- Otherwise, return the candidate with the smallest Levenshtein distance,
--
-- Except for candidates:
--   - With no name
--   - Whose meaning doesn't match the `meaning` parameter.
--   - Whose length differs from the target name by more than 0.34 of the length of the name.
--   - Whose levenshtein distance is more than 0.4 of the length of the name (0.4 allows 1 substitution/transposition
--     for every 5 characters, and 1 insertion/deletion at 3 characters)
--
-- symbols is an array (Go iter.Seq parameter).
function Checker:getSpellingSuggestionForName(name, symbols, meaning)
    local getCandidateName = function(candidate)
        local candidateName = ast.SymbolName(candidate)
        if #candidateName == 0 or string.byte(candidateName, 1) == 0x22 --[['"']] or string.byte(candidateName, 1) == 0xFE then
            return ""
        end
        if candidate.flags & meaning ~= 0 then
            return candidateName
        end
        if candidate.flags & SymbolFlags.Alias ~= 0 then
            local alias = self:tryResolveAlias(candidate)
            if alias ~= nil and alias.flags & meaning ~= 0 then
                return candidateName
            end
        end
        return ""
    end
    return core.GetSpellingSuggestion(name, symbols, getCandidateName, self.compareSymbols)
end

function Checker:onSuccessfullyResolvedSymbol(errorLocation, result, meaning, lastLocation, associatedDeclarationForContainingInitializerOrBindingName, withinDeferredContext)
    local name = result.name
    local isInExternalModule = lastLocation ~= nil and ast.IsSourceFile(lastLocation) and ast.IsExternalOrCommonJSModule(lastLocation:AsSourceFile())
    -- Only check for block-scoped variable if we have an error location and are looking for the
    -- name with variable meaning
    --      For example,
    --          declare module foo {
    --              interface bar {}
    --          }
    --      const foo/*1*/: foo/*2*/.bar;
    -- The foo at /*1*/ and /*2*/ will share same symbol with two meanings:
    -- block-scoped variable and namespace module. However, only when we
    -- try to resolve name in /*1*/ which is used in variable position,
    -- we want to check for block-scoped
    if errorLocation ~= nil and (meaning & SymbolFlags.BlockScopedVariable ~= 0 or meaning & (SymbolFlags.Class | SymbolFlags.Enum) ~= 0 and meaning & SymbolFlags.Value == SymbolFlags.Value) then
        local exportOrLocalSymbol = self:getExportSymbolOfValueSymbolIfExported(result)
        if exportOrLocalSymbol.flags & (SymbolFlags.BlockScopedVariable | SymbolFlags.Class | SymbolFlags.Enum) ~= 0 then
            self:checkResolvedBlockScopedVariable(exportOrLocalSymbol, errorLocation)
        end
    end
    -- If we're in an external module, we can't reference value symbols created from UMD export declarations
    if isInExternalModule and (meaning & SymbolFlags.Value) == SymbolFlags.Value and errorLocation.flags & NodeFlags.JSDoc == 0 then
        local merged = self:getMergedSymbol(result)
        if core.Len(merged.declarations) ~= 0 and core.Every(merged.declarations, function(d)
            return ast.IsNamespaceExportDeclaration(d) or ast.IsSourceFile(d) and d:AsSourceFile().globalExports ~= nil
        end) then
            self:errorOrSuggestion(self.compilerOptions.allowUmdGlobalAccess ~= Tristate.TSTrue, errorLocation, diagnostics.X_0_refers_to_a_UMD_global_but_the_current_file_is_a_module_Consider_adding_an_import_instead, name)
        end
    end
    -- If we're in a parameter initializer or binding name, we can't reference the values of the parameter whose initializer we're within or parameters to the right
    if associatedDeclarationForContainingInitializerOrBindingName ~= nil and not withinDeferredContext and (meaning & SymbolFlags.Value) == SymbolFlags.Value then
        local candidate = self:getMergedSymbol(self:getLateBoundSymbol(result))
        local root = ast.GetRootDeclaration(associatedDeclarationForContainingInitializerOrBindingName)
        -- A parameter initializer or binding pattern initializer within a parameter cannot refer to itself
        if candidate == self:getSymbolOfDeclaration(associatedDeclarationForContainingInitializerOrBindingName) then
            self:error(errorLocation, diagnostics.Parameter_0_cannot_reference_itself, scanner.DeclarationNameToString(associatedDeclarationForContainingInitializerOrBindingName:Name()))
        elseif candidate.valueDeclaration ~= nil and candidate.valueDeclaration:Pos() > associatedDeclarationForContainingInitializerOrBindingName:Pos() and root.parent:Locals() ~= nil and self:getSymbol(root.parent:Locals(), candidate.name, meaning) == candidate then
            self:error(errorLocation, diagnostics.Parameter_0_cannot_reference_identifier_1_declared_after_it, scanner.DeclarationNameToString(associatedDeclarationForContainingInitializerOrBindingName:Name()), scanner.DeclarationNameToString(errorLocation))
        end
    end
    if errorLocation ~= nil and meaning & SymbolFlags.Value ~= 0 and result.flags & SymbolFlags.Alias ~= 0 and result.flags & SymbolFlags.Value == 0 and not ast.IsValidTypeOnlyAliasUseSite(errorLocation) then
        local typeOnlyDeclaration = self:getTypeOnlyAliasDeclarationEx(result, SymbolFlags.Value)
        if typeOnlyDeclaration ~= nil then
            local message = core.IfElse(ast.NodeKindIs(typeOnlyDeclaration, Kind.ExportSpecifier, Kind.ExportDeclaration, Kind.NamespaceExport),
                diagnostics.X_0_cannot_be_used_as_a_value_because_it_was_exported_using_export_type,
                diagnostics.X_0_cannot_be_used_as_a_value_because_it_was_imported_using_import_type)
            self:addTypeOnlyDeclarationRelatedInfo(self:error(errorLocation, message, name), typeOnlyDeclaration, name)
        end
    end
    -- Look at 'compilerOptions.isolatedModules' and not 'getIsolatedModules(...)' (which considers 'verbatimModuleSyntax')
    -- here because 'verbatimModuleSyntax' will already have an error for importing a type without 'import type'.
    if self.compilerOptions.isolatedModules == Tristate.TSTrue and result ~= nil and isInExternalModule and (meaning & SymbolFlags.Value) == SymbolFlags.Value then
        local isGlobal = self:getSymbol(self.globals, name, meaning) == result
        local nonValueSymbol = nil
        if isGlobal and ast.IsSourceFile(lastLocation) then
            nonValueSymbol = self:getSymbol(lastLocation:Locals(), name, ~SymbolFlags.Value)
        end
        if nonValueSymbol ~= nil then
            local importDecl = core.Find(nonValueSymbol.declarations, function(d)
                return ast.NodeKindIs(d, Kind.ImportSpecifier, Kind.ImportClause, Kind.NamespaceImport, Kind.ImportEqualsDeclaration)
            end)
            if importDecl ~= nil and not ast.IsTypeOnlyImportDeclaration(importDecl) then
                self:error(importDecl, diagnostics.Import_0_conflicts_with_global_value_used_in_this_file_so_must_be_declared_with_a_type_only_import_when_isolatedModules_is_enabled, name)
            end
        end
    end
end

function Checker:checkResolvedBlockScopedVariable(result, errorLocation)
    debug.Assert(result.flags & SymbolFlags.BlockScopedVariable ~= 0 or result.flags & SymbolFlags.Class ~= 0 or result.flags & SymbolFlags.Enum ~= 0)
    if result.flags & (SymbolFlags.Function | SymbolFlags.FunctionScopedVariable | SymbolFlags.Assignment) ~= 0 and result.flags & SymbolFlags.Class ~= 0 then
        -- constructor functions aren't block scoped
        return
    end
    -- Block-scoped variables cannot be used before their definition
    local declaration = core.Find(result.declarations, function(d)
        return ast.IsBlockOrCatchScoped(d) or ast.IsClassLike(d) or ast.IsEnumDeclaration(d)
    end)
    if declaration == nil then
        error("checkResolvedBlockScopedVariable could not find block-scoped declaration", 0)
    end
    if declaration.flags & NodeFlags.Ambient == 0 and not self:isBlockScopedNameDeclaredBeforeUse(declaration, errorLocation) then
        local diagnostic = nil
        local declarationName = scanner.DeclarationNameToString(ast.GetNameOfDeclaration(declaration))
        if result.flags & SymbolFlags.BlockScopedVariable ~= 0 then
            diagnostic = self:error(errorLocation, diagnostics.Block_scoped_variable_0_used_before_its_declaration, declarationName)
        elseif result.flags & SymbolFlags.Class ~= 0 then
            diagnostic = self:error(errorLocation, diagnostics.Class_0_used_before_its_declaration, declarationName)
        elseif result.flags & SymbolFlags.RegularEnum ~= 0 then
            diagnostic = self:error(errorLocation, diagnostics.Enum_0_used_before_its_declaration, declarationName)
        else
            debug.Assert(result.flags & SymbolFlags.ConstEnum ~= 0)
            if self.compilerOptions:GetIsolatedModules() then
                diagnostic = self:error(errorLocation, diagnostics.Enum_0_used_before_its_declaration, declarationName)
            end
        end
        if diagnostic ~= nil then
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(declaration, diagnostics.X_0_is_declared_here, declarationName))
        end
    end
end

function Checker:isBlockScopedNameDeclaredBeforeUse(declaration, usage)
    local declarationFile = ast.GetSourceFileOfNode(declaration)
    local useFile = ast.GetSourceFileOfNode(usage)
    local declContainer = ast.GetEnclosingBlockScopeContainer(declaration)
    if declarationFile ~= useFile then
        -- nodes are in different files and order cannot be determined
        return true
    end
    -- deferred usage in a type context is always OK regardless of the usage position:
    if usage.flags & NodeFlags.JSDoc ~= 0 or checker.IsInTypeQuery(usage) or self:isInAmbientOrTypeNode(usage) then
        return true
    end
    if declaration:Pos() <= usage:Pos() and not (ast.IsPropertyDeclaration(declaration) and checker.isThisProperty(usage.parent) and declaration:Initializer() == nil and not checker.isExclamationToken(declaration:PostfixToken())) then
        -- declaration is before usage
        if declaration.kind == Kind.BindingElement then
            -- still might be illegal if declaration and usage are both binding elements (eg var [a = b, b = b] = [1, 2])
            local errorBindingElement = ast.FindAncestorKind(usage, Kind.BindingElement)
            if errorBindingElement ~= nil then
                return ast.FindAncestor(errorBindingElement, ast.IsBindingElement) ~= ast.FindAncestor(declaration, ast.IsBindingElement) or declaration:Pos() < errorBindingElement:Pos()
            end
            -- or it might be illegal if usage happens before parent variable is declared (eg var [a] = a)
            return self:isBlockScopedNameDeclaredBeforeUse(ast.FindAncestorKind(declaration, Kind.VariableDeclaration), usage)
        elseif declaration.kind == Kind.VariableDeclaration then
            -- still might be illegal if usage is in the initializer of the variable declaration (eg var a = a)
            return not checker.isImmediatelyUsedInInitializerOfBlockScopedVariable(declaration, usage, declContainer)
        elseif ast.IsClassLike(declaration) then
            -- still might be illegal if the usage is within a computed property name in the class (eg class A { static p = "a"; [A.p]() {} })
            -- or when used within a decorator in the class (e.g. `@dec(A.x) class A { static x = "x" }`),
            -- except when used in a function that is not an IIFE (e.g., `@dec(() => A.x) class A { ... }`)
            local container = usage
            while container ~= nil and container ~= declaration do
                if ast.IsComputedPropertyName(container) and container.parent.parent == declaration or
                    not self.legacyDecorators and ast.IsDecorator(container) and (container.parent == declaration or
                        ast.IsMethodDeclaration(container.parent) and container.parent.parent == declaration or
                        ast.IsAccessor(container.parent) and container.parent.parent == declaration or
                        ast.IsPropertyDeclaration(container.parent) and container.parent.parent == declaration or
                        ast.IsParameterDeclaration(container.parent) and container.parent.parent.parent == declaration) then
                    break
                end
                container = container.parent
            end
            if container == nil or container == declaration then
                return true
            end
            if not self.legacyDecorators and ast.IsDecorator(container) then
                local n = usage
                while n ~= nil and n ~= container do
                    if ast.IsFunctionLike(n) and ast.GetImmediatelyInvokedFunctionExpression(n) == nil then
                        break
                    end
                    n = n.parent
                end
                return n ~= nil and n ~= container
            end
            return false
        elseif ast.IsPropertyDeclaration(declaration) then
            -- still might be illegal if a self-referencing property initializer (eg private x = this.x)
            return not checker.isPropertyImmediatelyReferencedWithinDeclaration(declaration, usage, false --[[stopAtAnyPropertyDeclaration]])
        elseif ast.IsParameterPropertyDeclaration(declaration, declaration.parent) then
            -- foo = this.bar is illegal in emitStandardClassFields when bar is a parameter property
            return not (self.emitStandardClassFields and ast.GetContainingClass(declaration) == ast.GetContainingClass(usage) and self:isUsedInFunctionOrInstanceProperty(usage, declaration, declContainer))
        end
        return true
    end
    -- declaration is after usage, but it can still be legal if usage is deferred:
    -- 1. inside an export specifier
    -- 2. inside a function
    -- 3. inside an instance property initializer, a reference to a non-instance property
    --    (except when emitStandardClassFields: true and the reference is to a parameter property)
    -- 4. inside a static property initializer, a reference to a static method in the same class
    -- 5. inside a TS export= declaration (since we will move the export statement during emit to avoid TDZ)
    if ast.IsExportSpecifier(usage.parent) or ast.IsExportAssignment(usage.parent) and usage.parent:AsExportAssignment().isExportEquals then
        -- export specifiers do not use the variable, they only make it available for use
        return true
    end
    -- When resolving symbols for exports, the `usage` location passed in can be the export site directly
    if ast.IsExportAssignment(usage) and usage:AsExportAssignment().isExportEquals then
        return true
    end
    if self:isUsedInFunctionOrInstanceProperty(usage, declaration, declContainer) then
        if self.emitStandardClassFields and ast.GetContainingClass(declaration) ~= nil and (ast.IsPropertyDeclaration(declaration) or ast.IsParameterPropertyDeclaration(declaration, declaration.parent)) then
            return not checker.isPropertyImmediatelyReferencedWithinDeclaration(declaration, usage, true --[[stopAtAnyPropertyDeclaration]])
        end
        return true
    end
    return false
end

function Checker:isUsedInFunctionOrInstanceProperty(usage, declaration, declContainer)
    return ast.FindAncestorOrQuit(usage, function(current)
        if current == declContainer then
            return FindAncestorResult.FindAncestorQuit
        end
        if ast.IsFunctionLike(current) then
            return ast.ToFindAncestorResult(ast.GetImmediatelyInvokedFunctionExpression(current) == nil)
        end
        if ast.IsClassStaticBlockDeclaration(current) then
            return ast.ToFindAncestorResult(declaration:Pos() < usage:Pos())
        end

        if current.parent ~= nil and ast.IsPropertyDeclaration(current.parent) then
            local propertyDeclaration = current.parent
            local initializerOfProperty = propertyDeclaration:Initializer() == current
            if initializerOfProperty then
                if ast.IsStatic(current.parent) then
                    if ast.IsMethodDeclaration(declaration) then
                        return FindAncestorResult.FindAncestorTrue
                    end
                    if ast.IsPropertyDeclaration(declaration) and ast.GetContainingClass(usage) == ast.GetContainingClass(declaration) then
                        local propName = declaration:Name()
                        if ast.IsIdentifier(propName) or ast.IsPrivateIdentifier(propName) then
                            local t = self:getTypeOfSymbol(self:getSymbolOfDeclaration(declaration))
                            local staticBlocks = core.Filter(declaration.parent:Members(), ast.IsClassStaticBlockDeclaration)
                            if self:isPropertyInitializedInStaticBlocks(propName, t, staticBlocks, declaration.parent:Pos(), current:Pos()) then
                                return FindAncestorResult.FindAncestorTrue
                            end
                        end
                    end
                else
                    local isDeclarationInstanceProperty = ast.IsPropertyDeclaration(declaration) and not ast.IsStatic(declaration)
                    if not isDeclarationInstanceProperty or ast.GetContainingClass(usage) ~= ast.GetContainingClass(declaration) then
                        return FindAncestorResult.FindAncestorTrue
                    end
                end
            end
        end

        if current.parent ~= nil and ast.IsDecorator(current.parent) then
            local decorator = current.parent:AsDecorator()
            if decorator.expression == current then
                if ast.IsParameterDeclaration(decorator.parent) then
                    if self:isUsedInFunctionOrInstanceProperty(decorator.parent.parent.parent, declaration, declContainer) then
                        return FindAncestorResult.FindAncestorTrue
                    end
                    return FindAncestorResult.FindAncestorQuit
                end
                if ast.IsMethodDeclaration(decorator.parent) then
                    if self:isUsedInFunctionOrInstanceProperty(decorator.parent.parent, declaration, declContainer) then
                        return FindAncestorResult.FindAncestorTrue
                    end
                    return FindAncestorResult.FindAncestorQuit
                end
            end
        end

        return FindAncestorResult.FindAncestorFalse
    end) ~= nil
end

function checker.isImmediatelyUsedInInitializerOfBlockScopedVariable(declaration, usage, declContainer)
    local kind = declaration.parent.parent.kind
    if kind == Kind.VariableStatement or kind == Kind.ForStatement or kind == Kind.ForOfStatement then
        -- variable statement/for/for-of statement case,
        -- use site should not be inside variable declaration (initializer of declaration or binding element)
        if checker.isSameScopeDescendentOf(usage, declaration, declContainer) then
            return true
        end
    end
    -- ForIn/ForOf case - use site should not be used in expression part
    local grandparent = declaration.parent.parent
    return ast.IsForInOrOfStatement(grandparent) and checker.isSameScopeDescendentOf(usage, grandparent:Expression(), declContainer)
end

-- Starting from 'initial' node walk up the parent chain until 'stopAt' node is reached.
-- If at any point current node is equal to 'parent' node - return true.
-- If current node is an IIFE, continue walking up.
-- Return false if 'stopAt' node is reached or isFunctionLike(current) === true.
function checker.isSameScopeDescendentOf(initial, parent, stopAt)
    if parent == nil then
        return false
    end
    local n = initial
    while n ~= nil do
        if n == parent then
            return true
        end
        if n == stopAt or ast.IsFunctionLike(n) and (ast.GetImmediatelyInvokedFunctionExpression(n) == nil or (ast.GetFunctionFlags(n) & ast.FunctionFlags.AsyncGenerator ~= 0)) then
            return false
        end
        n = n.parent
    end
    return false
end

-- isPropertyImmediatelyReferencedWithinDeclaration is used for detecting ES-standard class field use-before-def errors
function checker.isPropertyImmediatelyReferencedWithinDeclaration(declaration, usage, stopAtAnyPropertyDeclaration)
    -- always legal if usage is after declaration
    if usage:End() > declaration:End() then
        return false
    end
    -- still might be legal if usage is deferred (e.g. x: any = () => this.x)
    -- otherwise illegal if immediately referenced within the declaration (e.g. x: any = this.x)
    local node = usage
    while node ~= nil and node ~= declaration do
        if node.kind == Kind.ArrowFunction then
            return false
        elseif node.kind == Kind.PropertyDeclaration then
            -- even when stopping at any property declaration, they need to come from the same class
            return stopAtAnyPropertyDeclaration and
                ((ast.IsPropertyDeclaration(declaration) and node.parent == declaration.parent) or
                    (ast.IsParameterPropertyDeclaration(declaration, declaration.parent) and node.parent == declaration.parent.parent))
        elseif node.kind == Kind.Block then
            local parentKind = node.parent.kind
            if parentKind == Kind.MethodDeclaration or parentKind == Kind.GetAccessor or parentKind == Kind.SetAccessor then
                return false
            end
        end
        node = node.parent
    end
    return true
end

-- Return the type-only declaration node (if any) for the given alias symbol (non-transitively)
function Checker:getTypeOnlyAliasDeclaration(symbol)
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        self:resolveAlias(symbol)
        return self.aliasSymbolLinks:Get(symbol).typeOnlyDeclaration
    end
    return nil
end

-- Return the first type-only alias declaration node (if any) in the resolution chain that affects
-- the symbol for the given meaning
function Checker:getTypeOnlyAliasDeclarationEx(symbol, meaning)
    while symbol.flags & SymbolFlags.Alias ~= 0 and symbol.flags & meaning == 0 do
        local resolved = self:resolveAlias(symbol)
        local links = self.aliasSymbolLinks:Get(symbol)
        if links.typeOnlyDeclaration ~= nil then
            return links.typeOnlyDeclaration
        end
        symbol = resolved
    end
    return nil
end

function Checker:getImmediateAliasedSymbol(symbol)
    debug.Assert(symbol.flags & SymbolFlags.Alias ~= 0, "Should only get Alias here.")
    local links = self.aliasSymbolLinks:Get(symbol)
    if links.immediateTarget == nil then
        local node = self:getDeclarationOfAliasSymbol(symbol)
        if node == nil then
            error("Unexpected nil in getImmediateAliasedSymbol", 0)
        end
        links.immediateTarget = self:getTargetOfAliasDeclaration(node)
    end
    return links.immediateTarget
end

function Checker:addTypeOnlyDeclarationRelatedInfo(diagnostic, typeOnlyDeclaration, name)
    if typeOnlyDeclaration == nil then
        return diagnostic
    end
    local isExport = ast.IsExportSpecifier(typeOnlyDeclaration) or ast.IsExportDeclaration(typeOnlyDeclaration) or ast.IsNamespaceExport(typeOnlyDeclaration)
    return diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(typeOnlyDeclaration, core.IfElse(isExport, diagnostics.X_0_was_exported_here, diagnostics.X_0_was_imported_here), name))
end

function Checker:getSymbol(symbols, name, meaning)
    if meaning & SymbolFlags.All ~= 0 then
        local symbol = self:getMergedSymbol(symbols ~= nil and symbols[name] or nil)
        if symbol ~= nil then
            if symbol.flags & meaning ~= 0 then
                return symbol
            end
            if symbol.flags & SymbolFlags.Alias ~= 0 then
                local targetFlags = self:getSymbolFlags(symbol)
                -- `targetFlags` will be `SymbolFlags.All` if an error occurred in alias resolution; this avoids cascading errors
                if targetFlags & meaning ~= 0 then
                    return symbol
                end
            end
        end
    end
    -- return nil if we can't find a symbol
    return nil
end

function Checker:checkSourceFile(ctx, sourceFile, checkUnused)
    self.ctx = ctx
    local links = self.sourceFileLinks:Get(sourceFile)
    local pop = nil
    if not links.typeChecked then
        local tr = self.tracer
        if tr ~= nil then
            -- Go: deferred until return
            pop = tr:Push(tracing.PhaseCheck, "checkSourceFile", { path = sourceFile:FileName() }, true)
        end
        -- Grammar checking
        self:checkGrammarSourceFile(sourceFile)
        self.renamedBindingElementsInTypes = nil
        self:checkSourceElements(sourceFile.statements.nodes)
        self:checkDeferredNodes(sourceFile)
        if ast.IsExternalOrCommonJSModule(sourceFile) then
            self:checkExternalModuleExports(sourceFile:AsNode())
            self:registerForUnusedIdentifiersCheck(sourceFile:AsNode())
        end
        if not sourceFile.isDeclarationFile and not self:isCanceled() then
            self:checkUnusedRenamedBindingElements()
        end
        self:produceDeferredDiagnostics()
        self.reportedUnreachableNodes:Clear()
        links.typeChecked = true
    end
    if checkUnused and not links.unusedChecked then
        -- The unused identifiers check relies on a full type check having first been performed
        if not sourceFile.isDeclarationFile and not self:isCanceled() then
            self:checkUnusedIdentifiers(links.identifierCheckNodes)
        end
        links.unusedChecked = true
    end
    if self:isCanceled() then
        self.wasCanceled = true
    end
    self.ctx = nil
    if pop ~= nil then
        pop()
    end
end

function Checker:checkSourceElements(nodes)
    for _, node in ipairs(nodes or {}) do
        if self:isCanceled() then
            break
        end
        self:checkSourceElement(node)
    end
end

function Checker:checkSourceElement(node)
    if node ~= nil then
        local saveCurrentNode = self.currentNode
        local saveWithinUnreachableCode = self.withinUnreachableCode
        self.currentNode = node
        self.instantiationCount = 0
        self:checkSourceElementWorker(node)
        self.currentNode = saveCurrentNode
        self.withinUnreachableCode = saveWithinUnreachableCode
    end
    return false
end

function Checker:checkSourceElementWorker(node)
    for _, jsdoc in ipairs(node:EagerJSDoc(nil) or {}) do
        self:checkJSDocComments(jsdoc)
        local tags = jsdoc:AsJSDoc().tags
        if tags ~= nil then
            for _, tag in ipairs(tags.nodes) do
                self:checkJSDocComments(tag)
            end
        end
    end

    if not self.withinUnreachableCode and self.compilerOptions.allowUnreachableCode ~= core.Tristate.TSTrue then
        if self:checkSourceElementUnreachable(node) then
            self.withinUnreachableCode = true
        end
    end

    local k = node.kind
    if k == Kind.TypeParameter then
        self:checkTypeParameter(node)
    elseif k == Kind.Parameter then
        self:checkParameter(node)
    elseif k == Kind.PropertyDeclaration then
        self:checkPropertyDeclaration(node)
    elseif k == Kind.PropertySignature then
        self:checkPropertySignature(node)
    elseif k == Kind.ConstructorType or k == Kind.FunctionType or k == Kind.CallSignature or k == Kind.ConstructSignature or k == Kind.IndexSignature then
        self:checkSignatureDeclaration(node)
    elseif k == Kind.MethodDeclaration or k == Kind.MethodSignature then
        self:checkMethodDeclaration(node)
    elseif k == Kind.ClassStaticBlockDeclaration then
        self:checkClassStaticBlockDeclaration(node)
    elseif k == Kind.Constructor then
        self:checkConstructorDeclaration(node)
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor then
        self:checkAccessorDeclaration(node)
    elseif k == Kind.TypeReference then
        self:checkTypeReferenceNode(node)
    elseif k == Kind.TypePredicate then
        self:checkTypePredicate(node)
    elseif k == Kind.TypeQuery then
        self:checkTypeQuery(node)
    elseif k == Kind.TypeLiteral then
        self:checkTypeLiteral(node)
    elseif k == Kind.ArrayType then
        self:checkArrayType(node)
    elseif k == Kind.TupleType then
        self:checkTupleType(node)
    elseif k == Kind.UnionType or k == Kind.IntersectionType then
        self:checkUnionOrIntersectionType(node)
    elseif k == Kind.ParenthesizedType or k == Kind.OptionalType or k == Kind.RestType then
        node:ForEachChild(function(n)
            return self:checkSourceElement(n)
        end)
    elseif k == Kind.ThisType then
        self:checkThisType(node)
    elseif k == Kind.TypeOperator then
        self:checkTypeOperator(node)
    elseif k == Kind.ConditionalType then
        self:checkConditionalType(node)
    elseif k == Kind.InferType then
        self:checkInferType(node)
    elseif k == Kind.TemplateLiteralType then
        self:checkTemplateLiteralType(node)
    elseif k == Kind.ImportType then
        self:checkImportType(node)
    elseif k == Kind.NamedTupleMember then
        self:checkNamedTupleMember(node)
    elseif k == Kind.IndexedAccessType then
        self:checkIndexedAccessType(node)
    elseif k == Kind.MappedType then
        self:checkMappedType(node)
    elseif k == Kind.FunctionDeclaration then
        self:checkFunctionDeclaration(node)
    elseif k == Kind.Block or k == Kind.ModuleBlock then
        self:checkBlock(node)
    elseif k == Kind.VariableStatement then
        self:checkVariableStatement(node)
    elseif k == Kind.ExpressionStatement then
        self:checkExpressionStatement(node)
    elseif k == Kind.IfStatement then
        self:checkIfStatement(node)
    elseif k == Kind.DoStatement then
        self:checkDoStatement(node)
    elseif k == Kind.WhileStatement then
        self:checkWhileStatement(node)
    elseif k == Kind.ForStatement then
        self:checkForStatement(node)
    elseif k == Kind.ForInStatement then
        self:checkForInStatement(node)
    elseif k == Kind.ForOfStatement then
        self:checkForOfStatement(node)
    elseif k == Kind.ContinueStatement or k == Kind.BreakStatement then
        self:checkBreakOrContinueStatement(node)
    elseif k == Kind.ReturnStatement then
        self:checkReturnStatement(node)
    elseif k == Kind.WithStatement then
        self:checkWithStatement(node)
    elseif k == Kind.SwitchStatement then
        self:checkSwitchStatement(node)
    elseif k == Kind.LabeledStatement then
        self:checkLabeledStatement(node)
    elseif k == Kind.ThrowStatement then
        self:checkThrowStatement(node)
    elseif k == Kind.TryStatement then
        self:checkTryStatement(node)
    elseif k == Kind.VariableDeclaration then
        self:checkVariableDeclaration(node)
    elseif k == Kind.BindingElement then
        self:checkBindingElement(node)
    elseif k == Kind.ClassDeclaration then
        self:checkClassDeclaration(node)
    elseif k == Kind.InterfaceDeclaration then
        self:checkInterfaceDeclaration(node)
    elseif k == Kind.TypeAliasDeclaration or k == Kind.JSTypeAliasDeclaration then
        self:checkTypeAliasDeclaration(node)
    elseif k == Kind.EnumDeclaration then
        self:checkEnumDeclaration(node)
    elseif k == Kind.EnumMember then
        self:checkEnumMember(node)
    elseif k == Kind.ModuleDeclaration then
        self:checkModuleDeclaration(node)
    elseif k == Kind.ImportDeclaration or k == Kind.JSImportDeclaration then
        self:checkImportDeclaration(node)
    elseif k == Kind.ImportEqualsDeclaration then
        self:checkImportEqualsDeclaration(node)
    elseif k == Kind.ExportDeclaration then
        self:checkExportDeclaration(node)
    elseif k == Kind.ExportAssignment then
        self:checkExportAssignment(node)
    elseif k == Kind.EmptyStatement then
        self:checkGrammarStatementInAmbientContext(node)
    elseif k == Kind.DebuggerStatement then
        self:checkGrammarStatementInAmbientContext(node)
    elseif k == Kind.MissingDeclaration then
        self:checkMissingDeclaration(node)
    elseif k == Kind.JSDocNonNullableType or k == Kind.JSDocNullableType or k == Kind.JSDocAllType or k == Kind.JSDocTypeLiteral then
        self:checkJSDocType(node)
    end
end

function Checker:checkSourceElementUnreachable(node)
    if not ast.IsPotentiallyExecutableNode(node) then
        return false
    end

    if self.reportedUnreachableNodes:Has(node) then
        return true
    end

    if not self:isSourceElementUnreachable(node) then
        return false
    end

    self.reportedUnreachableNodes:Add(node)

    local sourceFile = ast.GetSourceFileOfNode(node)

    local startNode = node
    local endNode = node

    local parent = node.parent
    if parent:CanHaveStatements() then
        local statements = parent:Statements()
        local offset = -1
        for i, s in ipairs(statements) do
            if s == node then
                offset = i - 1
                break
            end
        end
        if offset >= 0 then
            -- Scan backwards to find the first unreachable unreported node;
            -- this may happen when producing region diagnostics where not all nodes
            -- will have been visited.
            -- TODO: enable this code once we support region diagnostics again.
            local first = offset

            local last = offset
            for i = offset + 1, #statements - 1 do
                local nextNode = statements[i + 1]
                if not ast.IsPotentiallyExecutableNode(nextNode) or not self:isSourceElementUnreachable(nextNode) then
                    break
                end
                last = i
                self.reportedUnreachableNodes:Add(nextNode)
            end

            startNode = statements[first + 1]
            endNode = statements[last + 1]
        end
    end

    local start = scanner.GetTokenPosOfNode(startNode, sourceFile, false --[[includeJSDoc]])

    local diagnostic = ast.NewDiagnostic(sourceFile, core.NewTextRange(start, endNode:End()), diagnostics.Unreachable_code_detected)
    self:addErrorOrSuggestion(self.compilerOptions.allowUnreachableCode == core.Tristate.TSFalse, diagnostic)

    return true
end

function Checker:isSourceElementUnreachable(node)
    -- Precondition: ast.IsPotentiallyExecutableNode is true
    if node.flags & NodeFlags.Unreachable ~= 0 then
        -- The binder has determined that this code is unreachable.
        -- Ignore const enums unless preserveConstEnums is set.
        if node.kind == Kind.EnumDeclaration then
            return not ast.IsEnumConst(node) or self.compilerOptions:ShouldPreserveConstEnums()
        elseif node.kind == Kind.ModuleDeclaration then
            return ast.IsInstantiatedModule(node, self.compilerOptions:ShouldPreserveConstEnums())
        else
            return true
        end
    else
        local flowNode = node:FlowNodeData().flowNode
        if flowNode ~= nil then
            -- For code the binder doesn't know is unreachable, use control flow / types.
            return not self:isReachableFlowNode(flowNode)
        end
    end
    return false
end

-- Function and class expression bodies are checked after all statements in the enclosing body. This is
-- to ensure constructs like the following are permitted:
--
--	const foo = function () {
--	   const s = foo();
--	   return "hello";
--	}
--
-- Here, performing a full type check of the body of the function expression whilst in the process of
-- determining the type of foo would cause foo to be given type any because of the recursive reference.
-- Delaying the type check of the body ensures foo has been assigned a type.
function Checker:checkNodeDeferred(node)
    local enclosingFile = ast.GetSourceFileOfNode(node)
    local links = self.sourceFileLinks:Get(enclosingFile)
    if not links.typeChecked then
        links.deferredNodes:Add(node)
    end
end

function Checker:checkDeferredNodes(context)
    local links = self.sourceFileLinks:Get(context)
    for node in links.deferredNodes:Values() do
        if self:isCanceled() then
            break
        end
        self:checkDeferredNode(node)
    end
    links.deferredNodes = collections.NewOrderedSetWithSizeHint(0)
end

function Checker:checkDeferredNode(node)
    local pop = nil
    local tr = self.tracer
    if tr ~= nil then
        -- Go: deferred until return
        pop = tr:Push(tracing.PhaseCheck, "checkDeferredNode", { kind = node.kind, pos = node:Pos(), ["end"] = node:End(), path = ast.GetSourceFileOfNode(node):FileName() }, false)
    end
    local saveCurrentNode = self.currentNode
    self.currentNode = node
    self.instantiationCount = 0
    local k = node.kind
    if k == Kind.CallExpression or k == Kind.NewExpression or k == Kind.TaggedTemplateExpression or k == Kind.Decorator or k == Kind.JsxOpeningElement then
        -- These node kinds are deferred checked when overload resolution fails. To save on work,
        -- we ensure the arguments are checked just once in a deferred way.
        self:resolveUntypedCall(node)
    elseif k == Kind.FunctionExpression or k == Kind.ArrowFunction or k == Kind.MethodDeclaration or k == Kind.MethodSignature then
        self:checkFunctionExpressionOrObjectLiteralMethodDeferred(node)
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor then
        self:checkAccessorDeclaration(node)
    elseif k == Kind.ClassExpression then
        self:checkClassExpressionDeferred(node)
    elseif k == Kind.TypeParameter then
        self:checkTypeParameterDeferred(node)
    elseif k == Kind.JsxSelfClosingElement then
        self:checkJsxSelfClosingElementDeferred(node)
    elseif k == Kind.JsxElement then
        self:checkJsxElementDeferred(node)
    elseif k == Kind.TypeAssertionExpression or k == Kind.AsExpression then
        self:checkAssertionDeferred(node)
    elseif k == Kind.VoidExpression then
        self:checkExpression(node:Expression())
    elseif k == Kind.BinaryExpression then
        if ast.IsInstanceOfExpression(node) then
            self:resolveUntypedCall(node)
        end
    elseif k == Kind.ObjectLiteralExpression or k == Kind.JsxAttributes then
        self:checkContextualDeprecations(node)
    end
    self.currentNode = saveCurrentNode
    if pop ~= nil then
        pop()
    end
end

function Checker:checkJSDocComments(node)
    for _, comment in ipairs(node:Comments() or {}) do
        self:checkJSDocComment(comment)
    end
end

function Checker:checkJSDocComment(node)
    -- This performs minimal checking of JSDoc nodes to ensure that @link references to entities are recorded
    -- for purposes of checking unused identifiers.
    local k = node.kind
    if k == Kind.JSDocLink or k == Kind.JSDocLinkCode or k == Kind.JSDocLinkPlain then
        self:resolveJSDocMemberName(node:Name())
    end
end

function Checker:resolveJSDocMemberName(name)
    if name ~= nil and ast.IsEntityName(name) then
        local meaning = SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Value
        local symbol = self:resolveEntityName(name, meaning, true --[[ignoreErrors]], true --[[dontResolveAlias]], ast.GetHostSignatureFromJSDoc(name))
        if symbol ~= nil then
            return symbol
        end
        if ast.IsQualifiedName(name) then
            symbol = self:resolveJSDocMemberName(name:AsQualifiedName().left)
            if symbol ~= nil then
                local t
                if symbol.flags & SymbolFlags.Value ~= 0 then
                    local proto = self:getPropertyOfType(self:getTypeOfSymbol(symbol), "prototype")
                    if proto ~= nil then
                        t = self:getTypeOfSymbol(proto)
                    end
                end
                if t == nil then
                    t = self:getDeclaredTypeOfSymbol(symbol)
                end
                return self:getPropertyOfType(t, name:AsQualifiedName().right:Text())
            end
        end
    end
    return nil
end

function Checker:checkJSDocType(node)
    self:checkJSDocTypeIsInJsFile(node)
    node:ForEachChild(function(n)
        return self:checkSourceElement(n)
    end)
end

function Checker:checkJSDocTypeIsInJsFile(node)
    if not ast.IsInJSFile(node) then
        if ast.IsJSDocNonNullableType(node) or ast.IsJSDocNullableType(node) then
            local token = core.IfElse(ast.IsJSDocNonNullableType(node), "!", "?")
            local postfix = node:Pos() == node:Type():Pos()
            local message = core.IfElse(postfix,
                diagnostics.X_0_at_the_end_of_a_type_is_not_valid_TypeScript_syntax_Did_you_mean_to_write_1,
                diagnostics.X_0_at_the_start_of_a_type_is_not_valid_TypeScript_syntax_Did_you_mean_to_write_1)
            local t = self:getTypeFromTypeNode(node:Type())
            if ast.IsJSDocNullableType(node) and t ~= self.neverType and t ~= self.voidType then
                t = self:getNullableType(t, core.IfElse(postfix, TypeFlags.Undefined, TypeFlags.Nullable))
            end
            self:grammarErrorOnNode(node, message, token, self:TypeToString(t))
        else
            self:grammarErrorOnNode(node, diagnostics.JSDoc_types_can_only_be_used_inside_documentation_comments)
        end
    end
end

function Checker:checkTypeParameter(node)
    -- Grammar Checking
    self:checkGrammarModifiers(node)
    local expr = node:AsTypeParameterDeclaration().expression
    if expr ~= nil then
        self:grammarErrorOnFirstToken(expr, diagnostics.Type_expected)
    end
    local tpNode = node:AsTypeParameterDeclaration()
    self:checkSourceElement(tpNode.constraint)
    self:checkSourceElement(tpNode.defaultType)
    local typeParameter = self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(node))
    -- Resolve base constraint to reveal circularity errors
    self:getBaseConstraintOfType(typeParameter)
    if self:getResolvedTypeParameterDefault(typeParameter) == self.circularConstraintType then
        self:error(tpNode.defaultType, diagnostics.Type_parameter_0_has_a_circular_default, self:TypeToString(typeParameter))
    end
    local constraintType = self:getConstraintOfTypeParameter(typeParameter)
    local defaultType = self:getDefaultFromTypeParameter(typeParameter)
    if constraintType ~= nil and defaultType ~= nil then
        self:checkTypeAssignableTo(defaultType, self:getTypeWithThisArgument(self:instantiateType(constraintType, checker.newSimpleTypeMapper(typeParameter, defaultType)), defaultType, false), tpNode.defaultType, diagnostics.Type_0_does_not_satisfy_the_constraint_1)
    end
    self:checkTypeNameIsReserved(node:Name(), diagnostics.Type_parameter_name_cannot_be_0)
    self:checkNodeDeferred(node)
end

function Checker:checkTypeParameterDeferred(node)
    if ast.IsInterfaceDeclaration(node.parent) or ast.IsClassLike(node.parent) or ast.IsTypeOrJSTypeAliasDeclaration(node.parent) then
        local typeParameter = self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(node))
        local modifiers = self:getTypeParameterModifiers(typeParameter) & (ModifierFlags.In | ModifierFlags.Out)
        if modifiers ~= 0 then
            local symbol = self:getSymbolOfDeclaration(node.parent)
            if ast.IsTypeOrJSTypeAliasDeclaration(node.parent) and self:getDeclaredTypeOfSymbol(symbol).objectFlags & (checker.ObjectFlags.Anonymous | checker.ObjectFlags.Mapped) == 0 then
                self:error(node, diagnostics.Variance_annotations_are_only_supported_in_type_aliases_for_object_function_constructor_and_mapped_types)
            elseif modifiers == ModifierFlags.In or modifiers == ModifierFlags.Out then
                local pop = nil
                local tr = self.tracer
                if tr ~= nil then
                    -- Go: deferred until return
                    pop = tr:Push(tracing.PhaseCheckTypes, "checkTypeParameterDeferred", { parent = self:getDeclaredTypeOfSymbol(symbol).id, id = typeParameter.id }, false)
                end
                local source = self:createMarkerType(symbol, typeParameter, core.IfElse(modifiers == ModifierFlags.Out, self.markerSubTypeForCheck, self.markerSuperTypeForCheck))
                local target = self:createMarkerType(symbol, typeParameter, core.IfElse(modifiers == ModifierFlags.Out, self.markerSuperTypeForCheck, self.markerSubTypeForCheck))
                local saveVarianceTypeParameter = typeParameter
                self.varianceTypeParameter = typeParameter
                self:checkTypeAssignableTo(source, target, node, diagnostics.Type_0_is_not_assignable_to_type_1_as_implied_by_variance_annotation)
                self.varianceTypeParameter = saveVarianceTypeParameter
                if pop ~= nil then
                    pop()
                end
            end
        end
    end
end

function Checker:shouldCheckErasableSyntax(node)
    return core.Tristate_IsTrue(self.compilerOptions.erasableSyntaxOnly) and not ast.IsInJSFile(node)
end

function Checker:checkParameter(node)
    -- Grammar checking
    -- It is a SyntaxError if the Identifier "eval" or the Identifier "arguments" occurs as the
    -- Identifier in a PropertySetParameterList of a PropertyAssignment that is contained in strict code
    -- or if its FunctionBody is strict code(11.1.5).
    self:checkGrammarModifiers(node)
    self:checkVariableLikeDeclaration(node)
    local fn = ast.GetContainingFunction(node)
    local paramName = ""
    if node:Name() ~= nil and ast.IsIdentifier(node:Name()) then
        paramName = node:Name():Text()
    end
    if ast.HasSyntacticModifier(node, ModifierFlags.ParameterPropertyModifier) then
        if self:shouldCheckErasableSyntax(node) then
            self:error(node, diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled)
        end
        if not (ast.IsConstructorDeclaration(fn) and ast.NodeIsPresent(fn:Body())) then
            self:error(node, diagnostics.A_parameter_property_is_only_allowed_in_a_constructor_implementation)
        end
        if ast.IsConstructorDeclaration(fn) and paramName == "constructor" then
            self:error(node:Name(), diagnostics.X_constructor_cannot_be_used_as_a_parameter_property_name)
        end
    end
    if node:Initializer() == nil and checker.isOptionalDeclaration(node) and ast.IsBindingPattern(node:Name()) and fn:Body() ~= nil then
        self:error(node, diagnostics.A_binding_pattern_parameter_cannot_be_optional_in_an_implementation_signature)
    end
    if paramName == "this" or paramName == "new" then
        local index = -1
        for i, p in ipairs(fn:Parameters()) do
            if p == node then
                index = i - 1
                break
            end
        end
        if index ~= 0 then
            self:error(node, diagnostics.A_0_parameter_must_be_the_first_parameter, paramName)
        end
        if ast.IsConstructorDeclaration(fn) or ast.IsConstructSignatureDeclaration(fn) or ast.IsConstructorTypeNode(fn) then
            self:error(node, diagnostics.A_constructor_cannot_have_a_this_parameter)
        end
        if ast.IsArrowFunction(fn) then
            self:error(node, diagnostics.An_arrow_function_cannot_have_a_this_parameter)
        end
        if ast.IsAccessor(fn) then
            self:error(node, diagnostics.X_get_and_set_accessors_cannot_declare_this_parameters)
        end
    end
    -- Only check rest parameter type if it's not a binding pattern. Since binding patterns are
    -- not allowed in a rest parameter, we already have an error from checkGrammarParameterList.
    if checker.hasDotDotDotToken(node) and not ast.IsBindingPattern(node:Name()) and not self:isTypeAssignableTo(self:getReducedType(self:getTypeOfSymbol(node:Symbol())), self.anyReadonlyArrayType) then
        self:error(node, diagnostics.A_rest_parameter_must_be_of_an_array_type)
    end
end

function Checker:checkPropertyDeclaration(node)
    -- Grammar checking
    if not self:checkGrammarModifiers(node) and not self:checkGrammarProperty(node) then
        self:checkGrammarComputedPropertyName(node:Name())
    end
    self:checkVariableLikeDeclaration(node)
    self:setNodeLinksForPrivateIdentifierScope(node)
    -- property signatures already report "initializer not allowed in ambient context" elsewhere
    if ast.HasSyntacticModifier(node, ModifierFlags.Abstract) and ast.IsPropertyDeclaration(node) then
        if node:Initializer() ~= nil then
            self:error(node, diagnostics.Property_0_cannot_have_an_initializer_because_it_is_marked_abstract, scanner.DeclarationNameToString(node:Name()))
        end
    end
end

function Checker:checkPropertySignature(node)
    if ast.IsPrivateIdentifier(node:AsPropertySignatureDeclaration():Name()) then
        self:error(node, diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
    end
    self:checkPropertyDeclaration(node)
end

function Checker:checkSignatureDeclaration(node)
    -- Grammar checking
    local k = node.kind
    if k == Kind.IndexSignature then
        self:checkGrammarIndexSignature(node:AsIndexSignatureDeclaration())
    elseif k == Kind.FunctionType or k == Kind.FunctionDeclaration or k == Kind.ConstructorType or k == Kind.CallSignature or k == Kind.Constructor or k == Kind.ConstructSignature then
        self:checkGrammarFunctionLikeDeclaration(node)
    end
    local FunctionFlags = ast.FunctionFlags
    local functionFlags = ast.GetFunctionFlags(node)
    if functionFlags & FunctionFlags.Invalid == 0 then
        -- Async generators prior to ES2018 require the __await and __asyncGenerator helpers
        if functionFlags & FunctionFlags.AsyncGenerator == FunctionFlags.AsyncGenerator and
            self.languageVersion < checker.LanguageFeatureMinimumTarget.AsyncGenerators then
            self:checkExternalEmitHelpers(node, checker.ExternalEmitHelpers.AsyncGeneratorIncludes)
        end
        if functionFlags & FunctionFlags.AsyncGenerator == FunctionFlags.Async and self.languageVersion < checker.LanguageFeatureMinimumTarget.AsyncFunctions then
            self:checkExternalEmitHelpers(node, checker.ExternalEmitHelpers.Awaiter)
        end
    end
    self:checkTypeParameters(node:TypeParameters())
    self:checkUnmatchedJSDocParameters(node)
    self:checkSourceElements(node:Parameters())
    local returnTypeNode = node:Type()
    if returnTypeNode ~= nil then
        self:checkSourceElement(returnTypeNode)
    end
    if self.noImplicitAny and returnTypeNode == nil then
        if node.kind == Kind.ConstructSignature then
            self:error(node, diagnostics.Construct_signature_which_lacks_return_type_annotation_implicitly_has_an_any_return_type)
        elseif node.kind == Kind.CallSignature then
            self:error(node, diagnostics.Call_signature_which_lacks_return_type_annotation_implicitly_has_an_any_return_type)
        end
    end
    if returnTypeNode ~= nil then
        if (functionFlags & (FunctionFlags.Invalid | FunctionFlags.Generator)) == FunctionFlags.Generator then
            local returnType = self:getTypeFromTypeNode(returnTypeNode)
            if returnType == self.voidType then
                self:error(returnTypeNode, diagnostics.A_generator_cannot_have_a_void_type_annotation)
            else
                self:checkGeneratorInstantiationAssignabilityToReturnType(returnType, functionFlags, returnTypeNode)
            end
        elseif (functionFlags & FunctionFlags.AsyncGenerator) == FunctionFlags.Async then
            self:checkAsyncFunctionReturnType(node, returnTypeNode)
        end
    end
    if not ast.IsIndexSignatureDeclaration(node) then
        self:registerForUnusedIdentifiersCheck(node)
    end
end

-- Checks the return type of an async function to ensure it is a compatible
-- Promise implementation.
--
-- This checks that an async function has a valid Promise-compatible return type.
-- An async function has a valid Promise-compatible return type if the resolved value
-- of the return type has a construct signature that takes in an `initializer` function
-- that in turn supplies a `resolve` function as one of its arguments and results in an
-- object with a callable `then` signature.
function Checker:checkAsyncFunctionReturnType(node, returnTypeNode)
    local returnType = self:getTypeFromTypeNode(returnTypeNode)
    if self:isErrorType(returnType) then
        return
    end
    local globalPromiseType = self.getGlobalPromiseTypeChecked()
    if globalPromiseType ~= self.emptyGenericType and not self:isReferenceToType(returnType, globalPromiseType) then
        -- The promise type was not a valid type reference to the global promise type, so we
        -- report an error and return the unknown type.
        self:error(returnTypeNode, diagnostics.The_return_type_of_an_async_function_or_method_must_be_the_global_Promise_T_type_Did_you_mean_to_write_Promise_0, self:TypeToString(core.OrElse(self:getAwaitedTypeNoAlias(returnType), self.voidType)))
        return
    end
    self:checkAwaitedType(returnType, false --[[withAlias]], node, diagnostics.The_return_type_of_an_async_function_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member)
end

function Checker:checkMethodDeclaration(node)
    -- Grammar checking
    if not self:checkGrammarMethod(node) then
        self:checkGrammarComputedPropertyName(node:Name())
        if ast.IsMethodDeclaration(node) and node:AsMethodDeclaration().asteriskToken ~= nil and ast.IsIdentifier(node:Name()) and node:Name():Text() == "constructor" then
            self:error(node:Name(), diagnostics.Class_constructor_may_not_be_a_generator)
        end
    end
    -- Grammar checking for modifiers is done inside the function checkGrammarFunctionLikeDeclaration
    self:checkFunctionOrMethodDeclaration(node)
    -- method signatures already report "implementation not allowed in ambient context" elsewhere
    if ast.HasSyntacticModifier(node, ModifierFlags.Abstract) and ast.IsMethodDeclaration(node) and node:Body() ~= nil then
        self:error(node, diagnostics.Method_0_cannot_have_an_implementation_because_it_is_marked_abstract, scanner.DeclarationNameToString(node:Name()))
    end
    -- Private named methods are only allowed in class declarations
    if ast.IsPrivateIdentifier(node:Name()) and ast.GetContainingClass(node) == nil then
        self:error(node, diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
    end
    self:setNodeLinksForPrivateIdentifierScope(node)
end

function Checker:checkClassStaticBlockDeclaration(node)
    -- Grammar checking
    self:checkGrammarModifiers(node)
    node:ForEachChild(function(n)
        return self:checkSourceElement(n)
    end)
end

function Checker:checkConstructorDeclaration(node)
    -- Grammar check on signature of constructor and modifier of the constructor is done in checkSignatureDeclaration function.
    self:checkSignatureDeclaration(node)
    -- Grammar check for checking only related to constructorDeclaration
    local ctor = node:AsConstructorDeclaration()
    if not self:checkGrammarConstructorTypeParameters(ctor) then
        self:checkGrammarConstructorTypeAnnotation(ctor)
    end
    self:checkSourceElement(node:Body())
    local symbol = self:getSymbolOfDeclaration(node)
    self:checkFunctionOrConstructorSymbol(symbol)
    -- exit early in the case of signature - super checks are not relevant to them
    if ast.NodeIsMissing(node:Body()) then
        return
    end
    -- TS 1.0 spec (April 2014): 8.3.2
    -- Constructors of classes with no extends clause may not contain super calls, whereas
    -- constructors of derived classes must contain at least one super call somewhere in their function body.
    local containingClassDecl = node.parent
    if ast.GetClassExtendsHeritageElement(containingClassDecl) == nil then
        return
    end
    local classExtendsNull = self:classDeclarationExtendsNull(containingClassDecl)
    local superCall = self:findFirstSuperCall(node:Body())
    if superCall ~= nil then
        if classExtendsNull then
            self:error(superCall, diagnostics.A_constructor_cannot_contain_a_super_call_when_its_class_extends_null)
        end
        -- A super call must be root-level in a constructor if both of the following are true:
        -- - The containing class is a derived class.
        -- - The constructor declares parameter properties
        --   or the containing class declares instance member variables with initializers.
        local superCallShouldBeRootLevel = not self.emitStandardClassFields and
            (core.Some(node.parent:Members(), checker.isInstancePropertyWithInitializerOrPrivateIdentifierProperty) or
                core.Some(node:Parameters(), function(p)
                    return ast.HasSyntacticModifier(p, ModifierFlags.ParameterPropertyModifier)
                end))
        if superCallShouldBeRootLevel then
            -- Until we have better flow analysis, it is an error to place the super call within any kind of block or conditional
            -- See GH #8277
            if not checker.superCallIsRootLevelInConstructor(superCall, node:Body()) then
                self:error(superCall, diagnostics.A_super_call_must_be_a_root_level_statement_within_a_constructor_of_a_derived_class_that_contains_initialized_properties_parameter_properties_or_private_identifiers)
            else
                local superCallStatement
                for _, statement in ipairs(node:Body():Statements()) do
                    if ast.IsExpressionStatement(statement) and checker.isSuperCall(ast.SkipOuterExpressions(statement:Expression(), ast.OuterExpressionKinds.OEKAll)) then
                        superCallStatement = statement
                        break
                    end
                    if checker.nodeImmediatelyReferencesSuperOrThis(statement) then
                        break
                    end
                end
                -- Until we have better flow analysis, it is an error to place the super call within any kind of block or conditional
                -- See GH #8277
                if superCallStatement == nil then
                    self:error(node, diagnostics.A_super_call_must_be_the_first_statement_in_the_constructor_to_refer_to_super_or_this_when_a_derived_class_contains_initialized_properties_parameter_properties_or_private_identifiers)
                end
            end
        end
    elseif not classExtendsNull then
        self:error(node, diagnostics.Constructors_for_derived_classes_must_contain_a_super_call)
    end
end

function Checker:findFirstSuperCall(node)
    local superCall
    local visit
    visit = function(n)
        if checker.isSuperCall(n) then
            superCall = n
            return true
        elseif ast.IsFunctionLike(n) then
            return false
        end
        return n:ForEachChild(visit)
    end
    visit(node)
    return superCall
end

function checker.isInstancePropertyWithInitializerOrPrivateIdentifierProperty(n)
    return ast.IsPrivateIdentifierClassElementDeclaration(n) or ast.IsPropertyDeclaration(n) and not ast.IsStatic(n) and n:Initializer() ~= nil
end

function checker.superCallIsRootLevelInConstructor(superCall, body)
    local superCallParent = ast.WalkUpParenthesizedExpressions(superCall.parent)
    return ast.IsExpressionStatement(superCallParent) and superCallParent.parent == body
end

function checker.nodeImmediatelyReferencesSuperOrThis(node)
    local k = node.kind
    if k == Kind.SuperKeyword or k == Kind.ThisKeyword then
        return true
    elseif k == Kind.ArrowFunction or k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.PropertyDeclaration then
        return false
    elseif k == Kind.Block then
        local pk = node.parent.kind
        if pk == Kind.Constructor or pk == Kind.MethodDeclaration or pk == Kind.GetAccessor or pk == Kind.SetAccessor then
            return false
        end
    end
    return node:ForEachChild(checker.nodeImmediatelyReferencesSuperOrThis)
end

function Checker:checkAccessorDeclaration(node)
    -- Grammar checking accessors
    if not self:checkGrammarFunctionLikeDeclaration(node) and not self:checkGrammarAccessor(node) then
        self:checkGrammarComputedPropertyName(node:Name())
    end
    local name = node:Name()
    if ast.IsIdentifier(name) and name:Text() == "constructor" and ast.IsClassLike(node.parent) then
        self:error(node:Name(), diagnostics.Class_constructor_may_not_be_an_accessor)
    end
    self:checkDecorators(node)
    self:checkSignatureDeclaration(node)
    if ast.IsGetAccessorDeclaration(node) then
        if node.flags & NodeFlags.Ambient == 0 and ast.NodeIsPresent(node:Body()) and node.flags & NodeFlags.HasImplicitReturn ~= 0 then
            if node.flags & NodeFlags.HasExplicitReturn == 0 then
                self:error(name, diagnostics.A_get_accessor_must_return_a_value)
            end
        end
    end
    -- Do not use hasDynamicName here, because that returns false for well known symbols.
    -- We want to perform checkComputedPropertyName for all computed properties, including
    -- well known symbols.
    if ast.IsComputedPropertyName(name) then
        self:checkComputedPropertyName(name)
    end
    if self:hasBindableName(node) then
        -- TypeScript 1.0 spec (April 2014): 8.4.3
        -- Accessors for the same member name must specify the same accessibility.
        local symbol = self:getSymbolOfDeclaration(node)
        local getter = ast.GetDeclarationOfKind(symbol, Kind.GetAccessor)
        local setter = ast.GetDeclarationOfKind(symbol, Kind.SetAccessor)
        if getter ~= nil and setter ~= nil and self.nodeLinks:Get(getter).flags & checker.NodeCheckFlags.TypeChecked == 0 then
            local getterLinks = self.nodeLinks:Get(getter)
            getterLinks.flags = getterLinks.flags | checker.NodeCheckFlags.TypeChecked
            local getterFlags = getter:ModifierFlags()
            local setterFlags = setter:ModifierFlags()
            if (getterFlags & ModifierFlags.Abstract) ~= (setterFlags & ModifierFlags.Abstract) then
                self:error(getter:Name(), diagnostics.Accessors_must_both_be_abstract_or_non_abstract)
                self:error(setter:Name(), diagnostics.Accessors_must_both_be_abstract_or_non_abstract)
            end
            if ((getterFlags & ModifierFlags.Protected ~= 0) and setterFlags & (ModifierFlags.Protected | ModifierFlags.Private) == 0) or ((getterFlags & ModifierFlags.Private ~= 0) and setterFlags & ModifierFlags.Private == 0) then
                self:error(getter:Name(), diagnostics.A_get_accessor_must_be_at_least_as_accessible_as_the_setter)
                self:error(setter:Name(), diagnostics.A_get_accessor_must_be_at_least_as_accessible_as_the_setter)
            end
        end
    end
    local returnType = self:getTypeOfAccessors(self:getSymbolOfDeclaration(node))
    if node.kind == Kind.GetAccessor then
        self:checkAllCodePathsInNonVoidFunctionReturnOrThrow(node, returnType)
    end
    self:checkSourceElement(node:Body())
    self:setNodeLinksForPrivateIdentifierScope(node)
end

function Checker:checkTypeReferenceNode(node)
    self:checkGrammarTypeArguments(node, node:TypeArgumentList())
    if ast.IsTypeReferenceNode(node) and node.flags & NodeFlags.JSDoc == 0 then
        local data = node:AsTypeReferenceNode()
        if data.typeArguments ~= nil and data.typeName:End() ~= data.typeArguments:Pos() then
            -- If there was a token between the type name and the type arguments, check if it was a DotToken
            local sourceFile = ast.GetSourceFileOfNode(node)
            if scanner.ScanTokenAtPosition(sourceFile, data.typeName:End()) == Kind.DotToken then
                self:grammarErrorAtPos(node, scanner.SkipTrivia(sourceFile:Text(), data.typeName:End()), 1, diagnostics.JSDoc_types_can_only_be_used_inside_documentation_comments)
            end
        end
    end
    self:checkSourceElements(node:TypeArguments())
    self:checkTypeReferenceOrImport(node)
end

function Checker:checkTypeReferenceOrImport(node)
    local t = self:getTypeFromTypeNode(node)
    if not self:isErrorType(t) then
        if core.Len(node:TypeArguments()) ~= 0 then
            local typeParameters = self:getTypeParametersForTypeReferenceOrImport(node)
            if core.Len(typeParameters) ~= 0 then
                self:checkTypeArgumentConstraints(node, typeParameters)
            end
        end
        local symbol = self:getResolvedSymbolOrNil(node)
        if symbol ~= nil then
            if core.Some(symbol.declarations, function(d)
                return ast.IsTypeDeclaration(d) and self:IsDeprecatedDeclaration(d)
            end) then
                self:addDeprecatedSuggestion(self:getDeprecatedSuggestionNode(node), symbol.declarations, symbol.name)
            end
        end
    end
end

function Checker:checkTypeArgumentConstraints(node, typeParameters)
    local typeArguments
    local mapper
    local result = true
    for i1, typeParameter in ipairs(typeParameters) do
        local i = i1 - 1
        local constraint = self:getConstraintOfTypeParameter(typeParameter)
        if constraint ~= nil then
            if typeArguments == nil then
                typeArguments = self:getEffectiveTypeArguments(node, typeParameters)
                mapper = checker.newTypeMapper(typeParameters, typeArguments)
            end
            result = result and self:checkTypeAssignableTo(typeArguments[i + 1], self:instantiateType(constraint, mapper), core.ElementOrNil(node:TypeArguments(), i), diagnostics.Type_0_does_not_satisfy_the_constraint_1)
        end
    end
    return result
end

function Checker:getDeprecatedSuggestionNode(node)
    node = ast.SkipParentheses(node)
    local k = node.kind
    if k == Kind.CallExpression or k == Kind.Decorator or k == Kind.NewExpression then
        return self:getDeprecatedSuggestionNode(node:Expression())
    elseif k == Kind.TaggedTemplateExpression then
        return self:getDeprecatedSuggestionNode(node:AsTaggedTemplateExpression().tag)
    elseif k == Kind.JsxOpeningElement or k == Kind.JsxSelfClosingElement then
        return self:getDeprecatedSuggestionNode(node:TagName())
    elseif k == Kind.ElementAccessExpression then
        return node:AsElementAccessExpression().argumentExpression
    elseif k == Kind.PropertyAccessExpression then
        return node:Name()
    elseif k == Kind.TypeReference then
        local typeName = node:AsTypeReferenceNode().typeName
        if ast.IsQualifiedName(typeName) then
            return typeName:AsQualifiedName().right
        end
    end
    return node
end

function Checker:checkTypePredicate(node)
    -- Always check the predicate's type so nested type errors are reported even when the
    -- predicate is in an invalid position, keeping diagnostics stable.
    self:checkSourceElement(node:Type())
    local parent = self:getTypePredicateParent(node)
    if parent == nil then
        -- The parent must not be valid.
        self:error(node, diagnostics.A_type_predicate_is_only_allowed_in_return_type_position_for_functions_and_methods)
        return
    end
    local signature = self:getSignatureFromDeclaration(parent)
    local typePredicate = self:getTypePredicateOfSignature(signature)
    if typePredicate == nil then
        return
    end
    local parameterName = node:AsTypePredicateNode().parameterName
    if typePredicate.kind ~= TypePredicateKind.This and typePredicate.kind ~= TypePredicateKind.AssertsThis then
        if typePredicate.parameterIndex >= 0 then
            if checker.signatureHasRestParameter(signature) and typePredicate.parameterIndex == core.Len(signature.parameters) - 1 then
                self:error(parameterName, diagnostics.A_type_predicate_cannot_reference_a_rest_parameter)
            else
                if typePredicate.t ~= nil then
                    -- Go passes &diags (a *[]*ast.Diagnostic out-parameter); the relater appends to this array.
                    local diags = {}
                    if not self:checkTypeAssignableToEx(typePredicate.t, self:getTypeOfSymbol(signature.parameters[typePredicate.parameterIndex + 1]), node:Type(), nil --[[headMessage]], diags) then
                        self:addDiagnostic(ast.NewDiagnosticChain(diags[1], diagnostics.A_type_predicate_s_type_must_be_assignable_to_its_parameter_s_type))
                    end
                end
            end
        elseif parameterName ~= nil then
            local hasReportedError = false
            for _, param in ipairs(parent:Parameters()) do
                local name = param:Name()
                if ast.IsBindingPattern(name) and self:checkIfTypePredicateVariableIsDeclaredInBindingPattern(name, parameterName, typePredicate.parameterName) then
                    hasReportedError = true
                    break
                end
            end
            if not hasReportedError then
                self:error(parameterName, diagnostics.Cannot_find_parameter_0, typePredicate.parameterName)
            end
        end
    end
end

function Checker:getTypePredicateParent(node)
    local parent = node.parent
    local k = parent.kind
    if k == Kind.ArrowFunction or k == Kind.CallSignature or k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.FunctionType or
        k == Kind.MethodDeclaration or k == Kind.MethodSignature then
        if node == parent:Type() then
            return parent
        end
    end
    return nil
end

function Checker:checkIfTypePredicateVariableIsDeclaredInBindingPattern(pattern, predicateVariableNode, predicateVariableName)
    for _, element in ipairs(pattern:Elements()) do
        local name = element:Name()
        if name == nil then
            goto continue
        end
        if ast.IsIdentifier(name) and name:Text() == predicateVariableName then
            self:error(predicateVariableNode, diagnostics.A_type_predicate_cannot_reference_element_0_in_a_binding_pattern, predicateVariableName)
            return true
        end
        if ast.IsArrayBindingPattern(name) or ast.IsObjectBindingPattern(name) then
            if self:checkIfTypePredicateVariableIsDeclaredInBindingPattern(name, predicateVariableNode, predicateVariableName) then
                return true
            end
        end
        ::continue::
    end
    return false
end

function Checker:checkTypeQuery(node)
    self:getTypeFromTypeQueryNode(node)
end

function Checker:checkTypeLiteral(node)
    self:checkSourceElements(node:Members())
    local t = self:getTypeFromTypeLiteralOrFunctionOrConstructorTypeNode(node)
    self:checkIndexConstraints(t, t.symbol, false --[[isStaticIndex]])
    self:checkTypeForDuplicateIndexSignatures(node)
    self:checkObjectTypeForDuplicateDeclarations(node, false --[[checkPrivateNames]])
end

function Checker:checkObjectTypeForDuplicateDeclarations(node, checkPrivateNames)
    local instanceNames
    local staticNames
    local privateNames
    local nodeInAmbientContext = node.flags & NodeFlags.Ambient ~= 0
    local function checkPropertyOrAccessor(symbol, kind, isStatic)
        if core.Len(symbol.declarations) > 1 then
            local names
            if isStatic then
                if staticNames == nil then
                    staticNames = {}
                end
                names = staticNames
            else
                if instanceNames == nil then
                    instanceNames = {}
                end
                names = instanceNames
            end
            local state = names[symbol.name] or 0
            if state == 0 then
                -- On first occurrence just record the kind
                names[symbol.name] = kind
            elseif state == 1 or state == 2 and kind ~= 2 then
                -- Error on second property or combination of property and accessor
                self:reportDuplicateMemberErrors(node, symbol.name, true, isStatic, diagnostics.Duplicate_identifier_0)
                -- Record that errors have been reported
                names[symbol.name] = 3
            end
        end
    end
    for _, member in ipairs(node:Members()) do
        if ast.IsConstructorDeclaration(member) then
            for _, param in ipairs(member:Parameters()) do
                if ast.IsParameterPropertyDeclaration(param, member) and not ast.IsBindingPattern(param:Name()) then
                    checkPropertyOrAccessor(self:getSymbolOfDeclaration(param), 1, false --[[isStatic]])
                end
            end
        else
            local symbol = self:getSymbolOfDeclaration(member)
            local isStatic = ast.HasStaticModifier(member)
            -- In non-ambient contexts, check that static members are not named 'prototype'.
            if not nodeInAmbientContext and isStatic and symbol ~= nil and symbol.name == "prototype" then
                self:error(member:Name(), diagnostics.Static_property_0_conflicts_with_built_in_property_Function_0_of_constructor_function_1, symbol.name, self:symbolToString(self:getSymbolOfDeclaration(node)))
            end
            -- Check that this object type declaration doesn't contain multiple declarations of the same property,
            -- or accessor and property declarations with the same name.
            if ast.IsPropertyDeclaration(member) and not ast.HasAccessorModifier(member) or ast.IsPropertySignatureDeclaration(member) then
                checkPropertyOrAccessor(symbol, 1, isStatic)
            elseif ast.IsAccessor(member) or ast.IsPropertyDeclaration(member) and ast.HasAccessorModifier(member) then
                checkPropertyOrAccessor(symbol, 2, isStatic)
            end
            -- Check that each private identifier is used only for instance members or only for static members. It is an
            -- error for an instance and a static member to have the same private identifier.
            if checkPrivateNames and member:Name() ~= nil and ast.IsPrivateIdentifier(member:Name()) then
                local flags = (privateNames ~= nil and privateNames[symbol.name]) or 0
                if flags ~= 3 then
                    flags = flags | core.IfElse(ast.IsStatic(member), 2, 1)
                    if privateNames == nil then
                        privateNames = {}
                    end
                    privateNames[symbol.name] = flags
                    if flags == 3 then
                        self:reportDuplicateMemberErrors(node, symbol.name, false, false, diagnostics.Duplicate_identifier_0_Static_and_instance_elements_cannot_share_the_same_private_name)
                    end
                end
            end
        end
    end
end

function Checker:reportDuplicateMemberErrors(node, name, checkStatic, isStatic, message)
    for _, member in ipairs(node:Members()) do
        if ast.IsConstructorDeclaration(member) then
            for _, param in ipairs(member:Parameters()) do
                if ast.IsParameterPropertyDeclaration(param, member) and not ast.IsBindingPattern(param:Name()) then
                    local symbol = self:getSymbolOfDeclaration(param)
                    if symbol.name == name then
                        self:error(param:Name(), message, self:symbolToString(symbol))
                    end
                end
            end
        else
            local symbol = self:getSymbolOfDeclaration(member)
            if symbol ~= nil and symbol.name == name and (not checkStatic or isStatic == ast.IsStatic(member)) then
                self:error(member:Name(), message, self:symbolToString(symbol))
            end
        end
    end
end

function Checker:checkArrayType(node)
    self:checkSourceElement(node:AsArrayTypeNode().elementType)
end

function Checker:checkTupleType(node)
    local ElementFlags = checker.ElementFlags
    local seenOptionalElement = false
    local seenRestElement = false
    local elements = node:Elements()
    for _, e in ipairs(elements) do
        local flags = self:getTupleElementFlags(e)
        if flags & ElementFlags.Variadic ~= 0 then
            local t = self:getTypeFromTypeNode(e:Type())
            if not self:isArrayLikeType(t) then
                self:error(e, diagnostics.A_rest_element_type_must_be_an_array_type)
                break
            end
            if self:isArrayType(t) or checker.isTupleType(t) and t:TargetTupleType().combinedFlags & ElementFlags.Rest ~= 0 then
                flags = flags | ElementFlags.Rest
            end
        end
        if flags & ElementFlags.Rest ~= 0 then
            if seenRestElement then
                self:grammarErrorOnNode(e, diagnostics.A_rest_element_cannot_follow_another_rest_element)
                break
            end
            seenRestElement = true
        elseif flags & ElementFlags.Optional ~= 0 then
            if seenRestElement then
                self:grammarErrorOnNode(e, diagnostics.An_optional_element_cannot_follow_a_rest_element)
                break
            end
            seenOptionalElement = true
        elseif flags & ElementFlags.Required ~= 0 and seenOptionalElement then
            self:grammarErrorOnNode(e, diagnostics.A_required_element_cannot_follow_an_optional_element)
            break
        end
    end
    self:checkSourceElements(elements)
    self:getTypeFromTypeNode(node)
end

function Checker:checkUnionOrIntersectionType(node)
    node:ForEachChild(function(n)
        return self:checkSourceElement(n)
    end)
    self:getTypeFromTypeNode(node)
end

function Checker:checkThisType(node)
    self:getTypeFromThisTypeNode(node)
end

function Checker:checkTypeOperator(node)
    self:checkGrammarTypeOperatorNode(node:AsTypeOperatorNode())
    self:checkSourceElement(node:Type())
end

function Checker:checkConditionalType(node)
    node:ForEachChild(function(n)
        return self:checkSourceElement(n)
    end)
end

function Checker:checkInferType(node)
    if ast.FindAncestor(node, function(n)
        return n.parent ~= nil and n.parent.kind == Kind.ConditionalType and n.parent:AsConditionalTypeNode().extendsType == n
    end) == nil then
        self:grammarErrorOnNode(node, diagnostics.X_infer_declarations_are_only_permitted_in_the_extends_clause_of_a_conditional_type)
    end
    local typeParameterDeclarationNode = node:AsInferTypeNode().typeParameter
    self:checkSourceElement(typeParameterDeclarationNode)
    local symbol = self:getSymbolOfDeclaration(typeParameterDeclarationNode)
    if core.Len(symbol.declarations) > 1 then
        local links = self.declaredTypeLinks:Get(symbol)
        if not links.typeParametersChecked then
            links.typeParametersChecked = true
            local typeParameter = self:getDeclaredTypeOfTypeParameter(symbol)
            local declarations = checker.getDeclarationsOfKind(symbol, Kind.TypeParameter)
            if not self:areTypeParametersIdentical(declarations, { typeParameter }, function(decl)
                return { decl }
            end) then
                -- Report an error on every conflicting declaration.
                local name = self:symbolToString(symbol)
                for _, declaration in ipairs(declarations) do
                    self:error(declaration:Name(), diagnostics.All_declarations_of_0_must_have_identical_constraints, name)
                end
            end
        end
    end
    self:registerForUnusedIdentifiersCheck(node)
end

function Checker:checkTemplateLiteralType(node)
    for _, span in ipairs(node:AsTemplateLiteralTypeNode().templateSpans.nodes) do
        self:checkSourceElement(span:Type())
        local t = self:getTypeFromTypeNode(span:Type())
        self:checkTypeAssignableTo(t, self.templateConstraintType, span:Type(), nil)
    end
    self:getTypeFromTypeNode(node)
end

function Checker:checkImportType(node)
    self:checkSourceElement(node:AsImportTypeNode().argument)
    local attributes = node:AsImportTypeNode().attributes
    if attributes ~= nil then
        self:getResolutionModeOverride(attributes:AsImportAttributes(), true --[[reportErrors]])
    end
    self:checkTypeReferenceOrImport(node)
end

function Checker:getResolutionModeOverride(node, reportErrors)
    local ResolutionMode = core.ModuleKind
    if #node.attributes.nodes ~= 1 then
        if reportErrors then
            self:grammarErrorOnNode(node:AsNode(), diagnostics.Type_import_attributes_should_have_exactly_one_key_resolution_mode_with_value_import_or_require)
        end
        return ResolutionMode.ResolutionModeNone
    end
    local elem = node.attributes.nodes[1]
    if not ast.IsStringLiteralLike(elem:Name()) then
        return ResolutionMode.ResolutionModeNone
    end
    if elem:Name():Text() ~= "resolution-mode" then
        if reportErrors then
            self:grammarErrorOnNode(elem:Name(), diagnostics.X_resolution_mode_is_the_only_valid_key_for_type_import_attributes)
        end
        return ResolutionMode.ResolutionModeNone
    end
    local value = elem:AsImportAttribute().value
    if not ast.IsStringLiteralLike(value) then
        return ResolutionMode.ResolutionModeNone
    end
    if value:Text() ~= "import" and value:Text() ~= "require" then
        if reportErrors then
            self:grammarErrorOnNode(value, diagnostics.X_resolution_mode_should_be_either_require_or_import)
        end
        return ResolutionMode.ResolutionModeNone
    end
    if value:Text() == "import" then
        return ResolutionMode.ResolutionModeESM
    end
    return ResolutionMode.ResolutionModeCommonJS
end

function Checker:checkNamedTupleMember(node)
    local tupleMember = node:AsNamedTupleMember()
    if tupleMember.dotDotDotToken ~= nil and tupleMember.questionToken ~= nil then
        self:grammarErrorOnNode(node, diagnostics.A_tuple_member_cannot_be_both_optional_and_rest)
    end
    if tupleMember.type.kind == Kind.OptionalType then
        self:grammarErrorOnNode(tupleMember.type, diagnostics.A_labeled_tuple_element_is_declared_as_optional_with_a_question_mark_after_the_name_and_before_the_colon_rather_than_after_the_type)
    end
    if tupleMember.type.kind == Kind.RestType then
        self:grammarErrorOnNode(tupleMember.type, diagnostics.A_labeled_tuple_element_is_declared_as_rest_with_a_before_the_name_rather_than_before_the_type)
    end
    self:checkSourceElement(node:Type())
    self:getTypeFromTypeNode(node)
end

function Checker:checkIndexedAccessType(node)
    node:ForEachChild(function(n)
        return self:checkSourceElement(n)
    end)
    self:checkIndexedAccessIndexType(self:getTypeFromIndexedAccessTypeNode(node), node)
end

function Checker:checkMappedType(node)
    local mappedTypeNode = node:AsMappedTypeNode()
    self:checkGrammarMappedType(mappedTypeNode)
    self:checkSourceElement(mappedTypeNode.typeParameter)
    self:checkSourceElement(mappedTypeNode.nameType)
    self:checkSourceElement(mappedTypeNode.type)
    if mappedTypeNode.type == nil then
        self:reportImplicitAny(node, self.anyType, checker.WideningKind.Normal)
    end
    local t = self:getTypeFromMappedTypeNode(node)
    local nameType = self:getNameTypeFromMappedType(t)
    if nameType ~= nil then
        self:checkTypeAssignableTo(nameType, self.stringNumberSymbolType, mappedTypeNode.nameType, nil)
    else
        local constraintType = self:getConstraintTypeFromMappedType(t)
        self:checkTypeAssignableTo(constraintType, self.stringNumberSymbolType, mappedTypeNode.typeParameter:AsTypeParameterDeclaration().constraint, nil)
    end
end

function Checker:checkFunctionDeclaration(node)
    self:checkFunctionOrMethodDeclaration(node)
    self:checkGrammarForGenerator(node)
    self:checkCollisionsForDeclarationName(node, node:Name())
end

function Checker:checkFunctionOrMethodDeclaration(node)
    self:checkDecorators(node)
    self:checkSignatureDeclaration(node)
    local functionFlags = ast.GetFunctionFlags(node)
    -- Do not use hasDynamicName here, because that returns false for well known symbols.
    -- We want to perform checkComputedPropertyName for all computed properties, including
    -- well known symbols.
    if node:Name() ~= nil and ast.IsComputedPropertyName(node:Name()) then
        -- This check will account for methods in class/interface declarations,
        -- as well as accessors in classes/object literals
        self:checkComputedPropertyName(node:Name())
    end
    if self:hasBindableName(node) then
        -- first we want to check the local symbol that contain this declaration
        -- - if node.localSymbol !== undefined - this is current declaration is exported and localSymbol points to the local symbol
        -- - if node.localSymbol === undefined - this node is non-exported so we can just pick the result of getSymbolOfNode
        local symbol = self:getSymbolOfDeclaration(node)
        local localSymbol = node:LocalSymbol() or symbol
        -- Since the javascript won't do semantic analysis like typescript, ignore javascript function
        -- declarations so that redeclaring a function in a JS file is not reported as a duplicate.
        if node.flags & NodeFlags.JavaScriptFile == 0 then
            self:checkFunctionOrConstructorSymbol(localSymbol)
        end
        if symbol.parent ~= nil then
            -- run check on export symbol to check that modifiers agree across all exported declarations
            self:checkFunctionOrConstructorSymbol(symbol)
        end
    end
    local body = node:Body()
    self:checkSourceElement(body)
    self:checkAllCodePathsInNonVoidFunctionReturnOrThrow(node, self:getReturnTypeFromAnnotation(node))
    local fullSignature = node:FunctionLikeData().fullSignature
    if fullSignature ~= nil then
        if self:getContextualCallSignature(self:getTypeFromTypeNode(fullSignature), node) == nil then
            self:error(fullSignature, diagnostics.A_JSDoc_type_tag_on_a_function_must_have_a_signature_with_the_correct_number_of_arguments)
        end
    end
    if node:Type() == nil then
        -- Report an implicit any error if there is no body, no explicit return type, and node is not a private method
        -- in an ambient context
        if ast.NodeIsMissing(body) and not checker.isPrivateWithinAmbient(node) then
            self:reportImplicitAny(node, self.anyType, checker.WideningKind.Normal)
        end
        if functionFlags & ast.FunctionFlags.Generator ~= 0 and ast.NodeIsPresent(body) then
            -- A generator with a body and no type annotation can still cause errors. It can error if the
            -- yielded values have no common supertype, or it can give an implicit any error if it has no
            -- yielded values. The only way to trigger these errors is to try checking its return type.
            self:getReturnTypeOfSignature(self:getSignatureFromDeclaration(node))
        end
    end
end

function Checker:checkFunctionOrConstructorSymbol(symbol)
    -- Only check the symbol once
    local links = self.valueSymbolLinks:Get(symbol)
    if not links.functionOrConstructorChecked then
        links.functionOrConstructorChecked = true
        self:checkFunctionOrConstructorSymbolWorker(symbol)
    end
end
