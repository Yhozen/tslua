local checker = require("tslua.checker")
local Checker = checker.Checker
local core = require("tslua.core")

local defineStruct = checker.defineStruct
local TypeMapperKind = checker.TypeMapperKind

-- TypeMapper
--
-- A mapper is a single flat table whose class is the concrete mapper struct; m.data == m. Go's
-- TypeMapper.Map/Kind/MapsThisOnly forward to m.data, which in Lua resolves directly to the
-- concrete class methods (with TypeMapperBase defaults).

local TypeMapper = defineStruct("TypeMapper", nil, nil)

-- Factory functions

function checker.newTypeMapper(sources, targets)
    if core.Len(sources) == 1 then
        return checker.newSimpleTypeMapper(sources[1], targets[1])
    end
    return checker.newArrayTypeMapper(sources, targets)
end

function Checker:combineTypeMappers(m1, m2)
    if m1 ~= nil then
        return checker.newCompositeTypeMapper(self, m1, m2)
    end
    return m2
end

function Checker:mapTypeWithCompositeMapper(t, m1, m2)
    if m1 == nil then
        return m2:Map(t)
    end
    local t1 = m1:Map(t)
    if t1 ~= t then
        return self:instantiateType(t1, m2)
    end
    return m2:Map(t)
end

function checker.mergeTypeMappers(m1, m2)
    if m1 ~= nil then
        return checker.newMergedTypeMapper(m1, m2)
    end
    return m2
end

function checker.prependTypeMapping(source, target, mapper)
    if mapper == nil then
        return checker.newSimpleTypeMapper(source, target)
    end
    return checker.newMergedTypeMapper(checker.newSimpleTypeMapper(source, target), mapper)
end

function checker.appendTypeMapping(mapper, source, target)
    if mapper == nil then
        return checker.newSimpleTypeMapper(source, target)
    end
    return checker.newMergedTypeMapper(mapper, checker.newSimpleTypeMapper(source, target))
end

-- Maps forward-references to later types parameters to the empty object type.
-- This is used during inference when instantiating type parameter defaults.
function Checker:newBackreferenceMapper(context, index)
    local forwardInferences = core.Slice(context.inferences, index, #context.inferences)
    local typeParameters = core.Map(forwardInferences, function(i)
        return i.typeParameter
    end)
    return checker.newArrayToSingleTypeMapper(typeParameters, self.unknownType)
end

-- TypeMapperBase

local TypeMapperBase = defineStruct("TypeMapperBase", TypeMapper, nil)

function TypeMapperBase:Map(t)
    return t
end

function TypeMapperBase:Kind()
    return TypeMapperKind.Unknown
end

function TypeMapperBase:MapsThisOnly()
    return false
end

-- SimpleTypeMapper

local SimpleTypeMapper = defineStruct("SimpleTypeMapper", TypeMapperBase, nil)

function checker.newSimpleTypeMapper(source, target)
    local m = checker.SimpleTypeMapper_new()
    m.data = m
    m.source = source
    m.target = target
    return m
end

function SimpleTypeMapper:Map(t)
    if t == self.source then
        return self.target
    end
    return t
end

function SimpleTypeMapper:Kind()
    return TypeMapperKind.Simple
end

function SimpleTypeMapper:MapsThisOnly()
    return checker.isThisTypeParameter(self.source)
end

-- ArrayTypeMapper

local ArrayTypeMapper = defineStruct("ArrayTypeMapper", TypeMapperBase, nil)

function checker.newArrayTypeMapper(sources, targets)
    local m = checker.ArrayTypeMapper_new()
    m.data = m
    m.sources = sources
    m.targets = targets
    return m
end

function ArrayTypeMapper:Map(t)
    for i, s in ipairs(self.sources) do
        if t == s then
            return self.targets[i]
        end
    end
    return t
end

function ArrayTypeMapper:Kind()
    return TypeMapperKind.Array
end

function ArrayTypeMapper:MapsThisOnly()
    return #self.sources == 1 and checker.isThisTypeParameter(self.sources[1])
end

-- ArrayToSingleTypeMapper

local ArrayToSingleTypeMapper = defineStruct("ArrayToSingleTypeMapper", TypeMapperBase, nil)

function checker.newArrayToSingleTypeMapper(sources, target)
    local m = checker.ArrayToSingleTypeMapper_new()
    m.data = m
    m.sources = sources
    m.target = target
    return m
end

function ArrayToSingleTypeMapper:Map(t)
    for _, s in ipairs(self.sources) do
        if s == t then
            return self.target
        end
    end
    return t
end

function ArrayToSingleTypeMapper:MapsThisOnly()
    return #self.sources == 1 and checker.isThisTypeParameter(self.sources[1])
end

-- DeferredTypeMapper

local DeferredTypeMapper = defineStruct("DeferredTypeMapper", TypeMapperBase, nil)

function checker.newDeferredTypeMapper(sources, targets)
    local m = checker.DeferredTypeMapper_new()
    m.data = m
    m.sources = sources
    m.targets = targets
    return m
end

function DeferredTypeMapper:Map(t)
    for i, s in ipairs(self.sources) do
        if t == s then
            return self.targets[i]()
        end
    end
    return t
end

function DeferredTypeMapper:MapsThisOnly()
    return #self.sources == 1 and checker.isThisTypeParameter(self.sources[1])
end

-- FunctionTypeMapper

local FunctionTypeMapper = defineStruct("FunctionTypeMapper", TypeMapperBase, nil)

function checker.newFunctionTypeMapper(fn)
    local m = checker.FunctionTypeMapper_new()
    m.data = m
    m.fn = fn
    return m
end

function FunctionTypeMapper:Map(t)
    return self.fn(t)
end

-- MergedTypeMapper

local MergedTypeMapper = defineStruct("MergedTypeMapper", TypeMapperBase, nil)

function checker.newMergedTypeMapper(m1, m2)
    local m = checker.MergedTypeMapper_new()
    m.data = m
    m.m1 = m1
    m.m2 = m2
    return m
end

function MergedTypeMapper:Map(t)
    return self.m2:Map(self.m1:Map(t))
end

function MergedTypeMapper:Kind()
    return TypeMapperKind.Merged
end

-- CompositeTypeMapper

local CompositeTypeMapper = defineStruct("CompositeTypeMapper", TypeMapperBase, nil)

function checker.newCompositeTypeMapper(c, m1, m2)
    local m = checker.CompositeTypeMapper_new()
    m.data = m
    m.c = c
    m.m1 = m1
    m.m2 = m2
    return m
end

function CompositeTypeMapper:Map(t)
    local t1 = self.m1:Map(t)
    if t1 ~= t then
        return self.c:instantiateType(t1, self.m2)
    end
    return self.m2:Map(t)
end

-- InferenceTypeMapper

local InferenceTypeMapper = defineStruct("InferenceTypeMapper", TypeMapperBase, { fixing = false })

function Checker:newInferenceTypeMapper(n, fixing)
    local m = checker.InferenceTypeMapper_new()
    m.data = m
    m.c = self
    m.n = n
    m.fixing = fixing
    return m
end

function InferenceTypeMapper:Map(t)
    for i1, inference in ipairs(self.n.inferences) do
        local i = i1 - 1
        if t == inference.typeParameter then
            if self.fixing and not inference.isFixed then
                -- Before we commit to a particular inference (and thus lock out any further inferences),
                -- we infer from any intra-expression inference sites we have collected.
                self.c:inferFromIntraExpressionSites(self.n)
                checker.clearCachedInferences(self.n.inferences)
                inference.isFixed = true
            end
            return self.c:getInferredType(self.n, i)
        end
    end
    return t
end
