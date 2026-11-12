local pseudochecker = require("tslua.pseudochecker")

local PseudoTypeKind = pseudochecker.PseudoTypeKind
local PseudoObjectElementKind = pseudochecker.PseudoObjectElementKind

-- `PseudoType`s are skeletons of types - partially interpreted expressions and type nodes
-- composed to represent how you *should* construct a type out of them. They can be trivially
-- mapped into actual types by a real `Checker`, or into a tree of `Node`s directly, without
-- needing to make any intermediate types, by a `NodeBuilder`. Unlike checker `Type`s, these are
-- never normalized, and multiple pseudo-types may refer to the same underlying `Type`.

-- In strada, these were implicit in the AST nodes constructed in `expressionToTypeNode.ts`, which
-- repurposed AST nodes for this purpose, but in so doing, often confused weather or not it had validated
-- nested nodes for use at a given use-site. By keeping the mapping deferred like this, we can know we haven't
-- done any use-site checks until we're ready to map the `PseudoType` into a `Node`, and can cache
-- `PseudoType`s across multiple target positions.

-- A pseudo type is one flat table: the PseudoType fields (`kind`, `data` = the table itself) plus the
-- fields of its data struct; its metatable is the data struct class.

local PseudoType = {}
PseudoType.__index = PseudoType
pseudochecker.PseudoType = PseudoType

local function defineStruct(name, base)
    local cls = setmetatable({}, { __index = base })
    cls.__index = cls
    pseudochecker[name] = cls
    return cls
end

function pseudochecker.newPseudoType(kind, data)
    local n = data:AsPseudoType()
    n.kind = kind
    n.data = data
    return n
end

local PseudoTypeDefault = defineStruct("PseudoTypeDefault", PseudoType)

function PseudoTypeDefault:AsPseudoType()
    return self
end

local PseudoTypeBase = defineStruct("PseudoTypeBase", PseudoTypeDefault)

local function newData(cls, fields)
    local t = fields or {}
    t.kind = 0
    return setmetatable(t, cls)
end

pseudochecker.PseudoTypeUndefined = pseudochecker.newPseudoType(PseudoTypeKind.Undefined, newData(PseudoTypeBase))
pseudochecker.PseudoTypeNull = pseudochecker.newPseudoType(PseudoTypeKind.Null, newData(PseudoTypeBase))
pseudochecker.PseudoTypeAny = pseudochecker.newPseudoType(PseudoTypeKind.Any, newData(PseudoTypeBase))
pseudochecker.PseudoTypeString = pseudochecker.newPseudoType(PseudoTypeKind.String, newData(PseudoTypeBase))
pseudochecker.PseudoTypeNumber = pseudochecker.newPseudoType(PseudoTypeKind.Number, newData(PseudoTypeBase))
pseudochecker.PseudoTypeBigInt = pseudochecker.newPseudoType(PseudoTypeKind.BigInt, newData(PseudoTypeBase))
pseudochecker.PseudoTypeBoolean = pseudochecker.newPseudoType(PseudoTypeKind.Boolean, newData(PseudoTypeBase))
pseudochecker.PseudoTypeFalse = pseudochecker.newPseudoType(PseudoTypeKind.False, newData(PseudoTypeBase))
pseudochecker.PseudoTypeTrue = pseudochecker.newPseudoType(PseudoTypeKind.True, newData(PseudoTypeBase))

local function cast(t, cls, name)
    if getmetatable(t.data) ~= cls then
        error("interface conversion: pseudoTypeData is not *pseudochecker." .. name, 0)
    end
    return t.data
end

-- PseudoTypeDirect directly encodes the type referred to by a given TypeNode
local PseudoTypeDirect = defineStruct("PseudoTypeDirect", PseudoTypeBase)

function pseudochecker.NewPseudoTypeDirect(typeNode)
    return pseudochecker.newPseudoType(PseudoTypeKind.Direct, newData(PseudoTypeDirect, { typeNode = typeNode }))
end

function PseudoType:AsPseudoTypeDirect()
    return cast(self, PseudoTypeDirect, "PseudoTypeDirect")
end

-- PseudoTypeInferred directly encodes the type referred to by a given Expression
-- These represent cases where the expression was too complex for the pseudochecker.
-- Most of the time, these locations will produce an error under ID.
-- Specific error nodes (shorthand properties, spread assignments, etc.) are stored on the
-- ErrorNodes field, collected during pseudochecker construction.
local PseudoTypeInferred = defineStruct("PseudoTypeInferred", PseudoTypeBase)

function pseudochecker.NewPseudoTypeInferred(expr, isSignatureReturn)
    return pseudochecker.newPseudoType(PseudoTypeKind.Inferred, newData(PseudoTypeInferred, { expression = expr, errorNodes = nil, isSignatureReturn = isSignatureReturn or false }))
end

function pseudochecker.NewPseudoTypeInferredWithErrors(expr, isSignatureReturn, errorNodes)
    return pseudochecker.newPseudoType(PseudoTypeKind.Inferred, newData(PseudoTypeInferred, { expression = expr, errorNodes = errorNodes, isSignatureReturn = isSignatureReturn or false }))
end

function PseudoType:AsPseudoTypeInferred()
    return cast(self, PseudoTypeInferred, "PseudoTypeInferred")
end

-- PseudoTypeNoResult is analogous to PseudoTypeInferred in that it references a case
-- where the type was too complex for the pseudochecker. Rather than an expression, however,
-- it is referring to the return type of a signature or declaration.
local PseudoTypeNoResult = defineStruct("PseudoTypeNoResult", PseudoTypeBase)

function pseudochecker.NewPseudoTypeNoResult(decl)
    return pseudochecker.newPseudoType(PseudoTypeKind.NoResult, newData(PseudoTypeNoResult, { declaration = decl }))
end

function PseudoType:AsPseudoTypeNoResult()
    return cast(self, PseudoTypeNoResult, "PseudoTypeNoResult")
end

-- PseudoTypeMaybeConstLocation encodes the const/regular types of a location so the builder
-- can later select the appropriate pseudotype based on the location's context. This is used
-- to ensure accuracy in nested expressions without exposing type-based functionality to the pseudochecker.
-- A nodebuilder that doesn't do contextual typing would need to, as policy, reject these types if they
-- are in a contextually typed position! (Otherwise they could pick one, but either type could be wrong, depending on context!)
-- At the top-level, which is generally what ID is concerned with, nothing is contextually typed, so these cases don't generally
-- cause problems. Once you get into reused nodes in nested expressions, however, this becomes important.
-- In strada, checker `isConstContext` functionality exposed to the pseudochecker + type comparison sanity checking
-- on nested results masks the need for this abstraction, but with it present it clearly highlights a shortcoming
-- of the ID infernce model and how "standalone" it can(n't) truly be without substantial restrictions on expression inference.
local PseudoTypeMaybeConstLocation = defineStruct("PseudoTypeMaybeConstLocation", PseudoTypeBase)

function pseudochecker.NewPseudoTypeMaybeConstLocation(loc, ct, reg)
    return pseudochecker.newPseudoType(PseudoTypeKind.MaybeConstLocation, newData(PseudoTypeMaybeConstLocation, { node = loc, constType = ct, regularType = reg }))
end

function PseudoType:AsPseudoTypeMaybeConstLocation()
    return cast(self, PseudoTypeMaybeConstLocation, "PseudoTypeMaybeConstLocation")
end

-- PseudoTypeUnion is a collection of psudotypes joined into a union
local PseudoTypeUnion = defineStruct("PseudoTypeUnion", PseudoTypeBase)

function pseudochecker.NewPseudoTypeUnion(types)
    return pseudochecker.newPseudoType(PseudoTypeKind.Union, newData(PseudoTypeUnion, { types = types }))
end

function PseudoType:AsPseudoTypeUnion()
    return cast(self, PseudoTypeUnion, "PseudoTypeUnion")
end

-- PseudoParameter: { rest, name, optional, type }
function pseudochecker.NewPseudoParameter(isRest, name, isOptional, t)
    return { rest = isRest or false, name = name, optional = isOptional or false, type = t }
end

-- PseudoTypeSingleCallSignature represents an object type with a single call signature, like an arrow or function expression
local PseudoTypeSingleCallSignature = defineStruct("PseudoTypeSingleCallSignature", PseudoTypeBase)

function pseudochecker.NewPseudoTypeSingleCallSignature(signature, parameters, typeParameters, returnType)
    return pseudochecker.newPseudoType(PseudoTypeKind.SingleCallSignature, newData(PseudoTypeSingleCallSignature, {
        signature = signature,
        parameters = parameters,
        typeParameters = typeParameters,
        returnType = returnType,
    }))
end

function PseudoType:AsPseudoTypeSingleCallSignature()
    return cast(self, PseudoTypeSingleCallSignature, "PseudoTypeSingleCallSignature")
end

-- PseudoTypeTuple represents a tuple originaing from an `as const` array literal
local PseudoTypeTuple = defineStruct("PseudoTypeTuple", PseudoTypeBase)

function pseudochecker.NewPseudoTypeTuple(elements)
    return pseudochecker.newPseudoType(PseudoTypeKind.Tuple, newData(PseudoTypeTuple, {
        elements = elements,
    }))
end

function PseudoType:AsPseudoTypeTuple()
    return cast(self, PseudoTypeTuple, "PseudoTypeTuple")
end

-- PseudoObjectElement: one flat table { name, optional, kind, data = itself, ...data struct fields }
local PseudoObjectElement = {}
PseudoObjectElement.__index = PseudoObjectElement
pseudochecker.PseudoObjectElement = PseudoObjectElement

function PseudoObjectElement:AsPseudoObjectElement()
    return self
end

function PseudoObjectElement:Signature()
    if self.kind == PseudoObjectElementKind.Method then
        return self:AsPseudoObjectMethod().signature
    elseif self.kind == PseudoObjectElementKind.SetAccessor then
        return self:AsPseudoSetAccessor().signature
    elseif self.kind == PseudoObjectElementKind.GetAccessor then
        return self:AsPseudoGetAccessor().signature
    else
        return nil
    end
end

function pseudochecker.newPseudoObjectElement(kind, name, optional, data)
    local e = data:AsPseudoObjectElement()
    e.kind = kind
    e.name = name
    e.optional = optional or false
    e.data = data
    return e
end

local function elementCast(e, cls, name)
    if getmetatable(e.data) ~= cls then
        error("interface conversion: pseudoObjectElementData is not *pseudochecker." .. name, 0)
    end
    return e.data
end

local PseudoObjectMethod = defineStruct("PseudoObjectMethod", PseudoObjectElement)

function pseudochecker.NewPseudoObjectMethod(signature, name, optional, typeParameters, parameters, returnType)
    return pseudochecker.newPseudoObjectElement(PseudoObjectElementKind.Method, name, optional, setmetatable({
        signature = signature,
        typeParameters = typeParameters,
        parameters = parameters,
        returnType = returnType,
    }, PseudoObjectMethod))
end

function PseudoObjectElement:AsPseudoObjectMethod()
    return elementCast(self, PseudoObjectMethod, "PseudoObjectMethod")
end

local PseudoPropertyAssignment = defineStruct("PseudoPropertyAssignment", PseudoObjectElement)

function pseudochecker.NewPseudoPropertyAssignment(readonly, name, optional, t)
    return pseudochecker.newPseudoObjectElement(PseudoObjectElementKind.PropertyAssignment, name, optional, setmetatable({
        readonly = readonly or false,
        type = t,
    }, PseudoPropertyAssignment))
end

function PseudoObjectElement:AsPseudoPropertyAssignment()
    return elementCast(self, PseudoPropertyAssignment, "PseudoPropertyAssignment")
end

local PseudoSetAccessor = defineStruct("PseudoSetAccessor", PseudoObjectElement)

function pseudochecker.NewPseudoSetAccessor(signature, name, optional, p)
    return pseudochecker.newPseudoObjectElement(PseudoObjectElementKind.SetAccessor, name, optional, setmetatable({
        signature = signature,
        parameter = p,
    }, PseudoSetAccessor))
end

function PseudoObjectElement:AsPseudoSetAccessor()
    return elementCast(self, PseudoSetAccessor, "PseudoSetAccessor")
end

local PseudoGetAccessor = defineStruct("PseudoGetAccessor", PseudoObjectElement)

function pseudochecker.NewPseudoGetAccessor(signature, name, optional, t)
    return pseudochecker.newPseudoObjectElement(PseudoObjectElementKind.GetAccessor, name, optional, setmetatable({
        signature = signature,
        type = t,
    }, PseudoGetAccessor))
end

function PseudoObjectElement:AsPseudoGetAccessor()
    return elementCast(self, PseudoGetAccessor, "PseudoGetAccessor")
end

-- PseudoTypeObjectLiteral represents an object type originaing from an object literal
local PseudoTypeObjectLiteral = defineStruct("PseudoTypeObjectLiteral", PseudoTypeBase)

function pseudochecker.NewPseudoTypeObjectLiteral(elements)
    return pseudochecker.newPseudoType(PseudoTypeKind.ObjectLiteral, newData(PseudoTypeObjectLiteral, {
        elements = elements,
    }))
end

function PseudoType:AsPseudoTypeObjectLiteral()
    return cast(self, PseudoTypeObjectLiteral, "PseudoTypeObjectLiteral")
end

-- PseudoTypeLiteral represents a literal type
local PseudoTypeLiteral = defineStruct("PseudoTypeLiteral", PseudoTypeBase)

function pseudochecker.NewPseudoTypeStringLiteral(node)
    return pseudochecker.newPseudoType(PseudoTypeKind.StringLiteral, newData(PseudoTypeLiteral, {
        node = node,
    }))
end

function pseudochecker.NewPseudoTypeNumericLiteral(node)
    return pseudochecker.newPseudoType(PseudoTypeKind.NumericLiteral, newData(PseudoTypeLiteral, {
        node = node,
    }))
end

function pseudochecker.NewPseudoTypeBigIntLiteral(node)
    return pseudochecker.newPseudoType(PseudoTypeKind.BigIntLiteral, newData(PseudoTypeLiteral, {
        node = node,
    }))
end

function PseudoType:AsPseudoTypeLiteral()
    return cast(self, PseudoTypeLiteral, "PseudoTypeLiteral")
end

return pseudochecker
