local checker = require("tslua.checker")
local tracing = require("tslua.tracing")

local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags

-- Tracer records types and trace events during type checking. A nil Tracer
-- is a valid no-op, so call sites can use `local tr = c.tracer; if tr ~= nil` to
-- gate work that only matters under --generateTrace.
local Tracer = {}
Tracer.__index = Tracer
checker.Tracer = Tracer

-- NewTracer creates a Tracer for the given checker index that records both
-- type-creation events and trace events through the provided tracing session.
function checker.NewTracer(tr, checkerIndex)
    return setmetatable({ tracing = tr, recorder = tr:NewTypeTracer(checkerIndex), checkerIndex = checkerIndex }, Tracer)
end

function Tracer:RecordType(typ)
    self.recorder:RecordType(checker.wrapType(typ))
end

function Tracer:Push(phase, name, args, separateBeginAndEnd)
    if not separateBeginAndEnd then
        return tracing.Tracing.Push(self.tracing, phase, name, self:copyWithCheckerIndex(args), separateBeginAndEnd)
    end

    local restore
    args, restore = self:temporarilyAddCheckerIndex(args)
    local pop = tracing.Tracing.Push(self.tracing, phase, name, args, separateBeginAndEnd)
    restore()

    return function()
        local _, restoreEndArgs = self:temporarilyAddCheckerIndex(args)
        pop()
        restoreEndArgs()
    end
end

function Tracer:Instant(phase, name, args)
    tracing.Tracing.Instant(self.tracing, phase, name, self:copyWithCheckerIndex(args))
end

function Tracer:copyWithCheckerIndex(args)
    local withCheckerIndex = {}
    if args ~= nil then
        for k, v in pairs(args) do
            withCheckerIndex[k] = v
        end
    end
    withCheckerIndex["checkerId"] = self.checkerIndex
    return withCheckerIndex
end

-- Returns (args, restore).
function Tracer:temporarilyAddCheckerIndex(args)
    if args == nil then
        args = {}
    end

    local previous = args["checkerId"]
    local hadPrevious = previous ~= nil
    args["checkerId"] = self.checkerIndex

    return args, function()
        if hadPrevious then
            args["checkerId"] = previous
        else
            args["checkerId"] = nil
        end
    end
end

-- tracedTypeAdapter adapts a Type to the tracing.TracedType interface
local tracedTypeAdapter = {}
tracedTypeAdapter.__index = tracedTypeAdapter
checker.tracedTypeAdapter = tracedTypeAdapter

function tracedTypeAdapter:Id()
    return self.t.id
end

function tracedTypeAdapter:FormatFlags()
    return checker.FormatTypeFlags(self.t.flags)
end

function tracedTypeAdapter:IsConditional()
    return self.t.flags & TypeFlags.Conditional ~= 0
end

function tracedTypeAdapter:Symbol()
    return self.t.symbol
end

function tracedTypeAdapter:AliasSymbol()
    if self.t.alias == nil then
        return nil
    end
    return checker.TypeAlias.Symbol(self.t.alias)
end

function tracedTypeAdapter:AliasTypeArguments()
    if self.t.alias == nil then
        return nil
    end
    return checker.wrapTypes(checker.TypeAlias.TypeArguments(self.t.alias))
end

function tracedTypeAdapter:IntrinsicName()
    if self.t.flags & TypeFlags.Intrinsic == 0 then
        return ""
    end
    if getmetatable(self.t) ~= checker.IntrinsicType then
        return ""
    end
    return self.t.intrinsicName
end

function tracedTypeAdapter:UnionTypes()
    if self.t.flags & TypeFlags.Union == 0 then
        return nil
    end
    return checker.wrapTypes(self.t:AsUnionType().types)
end

function tracedTypeAdapter:IntersectionTypes()
    if self.t.flags & TypeFlags.Intersection == 0 then
        return nil
    end
    return checker.wrapTypes(self.t:AsIntersectionType().types)
end

function tracedTypeAdapter:IndexType()
    if self.t.flags & TypeFlags.Index == 0 then
        return nil
    end
    local t = self.t:AsIndexType().target
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:IndexedAccessObjectType()
    if self.t.flags & TypeFlags.IndexedAccess == 0 then
        return nil
    end
    local t = self.t:AsIndexedAccessType().objectType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:IndexedAccessIndexType()
    if self.t.flags & TypeFlags.IndexedAccess == 0 then
        return nil
    end
    local t = self.t:AsIndexedAccessType().indexType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ConditionalCheckType()
    if self.t.flags & TypeFlags.Conditional == 0 then
        return nil
    end
    local t = self.t:AsConditionalType().checkType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ConditionalExtendsType()
    if self.t.flags & TypeFlags.Conditional == 0 then
        return nil
    end
    local t = self.t:AsConditionalType().extendsType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ConditionalTrueType()
    if self.t.flags & TypeFlags.Conditional == 0 then
        return nil
    end
    local t = self.t:AsConditionalType().resolvedTrueType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ConditionalFalseType()
    if self.t.flags & TypeFlags.Conditional == 0 then
        return nil
    end
    local t = self.t:AsConditionalType().resolvedFalseType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:SubstitutionBaseType()
    if self.t.flags & TypeFlags.Substitution == 0 then
        return nil
    end
    local t = self.t:AsSubstitutionType().baseType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:SubstitutionConstraintType()
    if self.t.flags & TypeFlags.Substitution == 0 then
        return nil
    end
    local t = self.t:AsSubstitutionType().constraint
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ReferenceTarget()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.Reference == 0 then
        return nil
    end
    local t = self.t:AsTypeReference().target
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ReferenceTypeArguments()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.Reference == 0 then
        return nil
    end
    return checker.wrapTypes(self.t:AsTypeReference().resolvedTypeArguments)
end

function tracedTypeAdapter:ReferenceNode()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.Reference == 0 then
        return nil
    end
    return self.t:AsTypeReference().node
end

function tracedTypeAdapter:ReverseMappedSourceType()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.ReverseMapped == 0 then
        return nil
    end
    local t = self.t:AsReverseMappedType().source
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ReverseMappedMappedType()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.ReverseMapped == 0 then
        return nil
    end
    local t = self.t:AsReverseMappedType().mappedType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:ReverseMappedConstraintType()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.ReverseMapped == 0 then
        return nil
    end
    local t = self.t:AsReverseMappedType().constraintType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:EvolvingArrayElementType()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.EvolvingArray == 0 then
        return nil
    end
    local t = self.t:AsEvolvingArrayType().elementType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:EvolvingArrayFinalType()
    if self.t.flags & TypeFlags.Object == 0 or self.t.objectFlags & ObjectFlags.EvolvingArray == 0 then
        return nil
    end
    local t = self.t:AsEvolvingArrayType().finalArrayType
    if t == nil then
        return nil
    end
    return checker.wrapType(t)
end

function tracedTypeAdapter:IsTuple()
    return self.t.objectFlags & ObjectFlags.Tuple ~= 0
end

function tracedTypeAdapter:Pattern()
    if self.checker == nil then
        return nil
    end
    return self.checker.patternForType[self.t]
end

function tracedTypeAdapter:RecursionIdentity()
    return checker.getRecursionIdentity(self.t)
end

function tracedTypeAdapter:Display()
    -- Compute display text for types where it's valuable for trace analysis.
    -- TypeScript only does this for Anonymous|Literal types, but we extend to
    -- unions, intersections, and template literals since they often lack
    -- firstDeclaration and the display text helps identify them.
    -- Incomplete types during tracing can cause panics, which we intentionally
    -- suppress (returning ""), matching TypeScript's try/catch around typeToString.
    if self.checker == nil then
        return ""
    end
    if self.t.objectFlags & ObjectFlags.Anonymous ~= 0 or
        self.t.flags & (TypeFlags.Literal | TypeFlags.TemplateLiteral | TypeFlags.Union | TypeFlags.Intersection) ~= 0 then
        local ok, result = pcall(self.checker.TypeToString, self.checker, self.t)
        if not ok then
            return ""
        end
        return result
    end
    return ""
end

function checker.wrapType(t)
    if t == nil then
        return nil
    end
    return setmetatable({ t = t, checker = t.checker }, tracedTypeAdapter)
end

function checker.wrapTypes(types)
    if types == nil or #types == 0 then
        return nil
    end
    local result = {}
    for i, t in ipairs(types) do
        result[i] = checker.wrapType(t)
    end
    return result
end
