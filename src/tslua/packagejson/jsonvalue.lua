local packagejson = require("tslua.packagejson")
local collections = require("tslua.collections")

-- JSONValueType (Go iota constants; packagejson has no generated constants).
packagejson.JSONValueType = {
    NotPresent = 0,
    Null = 1,
    String = 2,
    Number = 3,
    Boolean = 4,
    Array = 5,
    Object = 6,
}
local JSONValueType = packagejson.JSONValueType
packagejson.JSONValueType_names = {}
for k, v in pairs(JSONValueType) do
    packagejson.JSONValueType_names[v] = k
end

function packagejson.JSONValueType_String(t)
    if t == JSONValueType.Null then
        return "null"
    elseif t == JSONValueType.String then
        return "string"
    elseif t == JSONValueType.Number then
        return "number"
    elseif t == JSONValueType.Boolean then
        return "boolean"
    elseif t == JSONValueType.Array then
        return "array"
    elseif t == JSONValueType.Object then
        return "object"
    else
        return "unknown(" .. tostring(t) .. ")"
    end
end

-- JSONValue is a Go value struct { Type, Value }. Arrays hold JSONValues, objects are
-- collections.OrderedMap[string, JSONValue].
local JSONValue = {}
JSONValue.__index = JSONValue
packagejson.JSONValue = JSONValue

function packagejson.NewJSONValue(t, value)
    return setmetatable({ type = t or JSONValueType.NotPresent, value = value }, JSONValue)
end

function JSONValue:IsPresent()
    return self.type ~= JSONValueType.NotPresent
end

function JSONValue:IsFalsy()
    local t = self.type
    if t == JSONValueType.NotPresent or t == JSONValueType.Null then
        return true
    elseif t == JSONValueType.String then
        return self.value == ""
    elseif t == JSONValueType.Number then
        -- Go compares the float64 Value with the untyped int 0 through `any`, which is never equal.
        return false
    elseif t == JSONValueType.Boolean then
        return not self.value
    else
        return false
    end
end

function JSONValue:AsObject()
    if self.type ~= JSONValueType.Object then
        error("expected object, got " .. packagejson.JSONValueType_String(self.type), 0)
    end
    return self.value
end

function JSONValue:AsArray()
    if self.type ~= JSONValueType.Array then
        error("expected array, got " .. packagejson.JSONValueType_String(self.type), 0)
    end
    return self.value
end

function JSONValue:AsString()
    if self.type ~= JSONValueType.String then
        error("expected string, got " .. packagejson.JSONValueType_String(self.type), 0)
    end
    return self.value
end

-- unmarshalJSONValue / unmarshalJSONValueV2: build a JSONValue (or a value of the given
-- metatable `mt`, e.g. ExportsOrImports) from a decoded generic JSON value (see
-- packagejson.decodedKind in packagejson.lua). Elements of arrays and objects are built with
-- the same metatable, like Go's generic T.
function packagejson.unmarshalJSONValue(mt, decoded)
    local v = setmetatable({ type = JSONValueType.NotPresent, value = nil }, mt)
    local kind = packagejson.decodedKind(decoded)
    if kind == "null" then
        v.value = nil
        v.type = JSONValueType.Null
    elseif kind == "string" then
        v.type = JSONValueType.String
        v.value = decoded
    elseif kind == "array" then
        local elements = nil
        for _, element in ipairs(packagejson.decodedArray(decoded)) do
            elements = elements or {}
            elements[#elements + 1] = packagejson.unmarshalJSONValue(mt, element)
        end
        v.type = JSONValueType.Array
        v.value = elements or {}
    elseif kind == "object" then
        local object = collections.NewOrderedMapWithSizeHint(0)
        packagejson.decodedObjectEach(decoded, function(key, value)
            object:Set(key, packagejson.unmarshalJSONValue(mt, value))
        end)
        v.type = JSONValueType.Object
        v.value = object
    elseif kind == "boolean" then
        v.type = JSONValueType.Boolean
        v.value = decoded
    else
        v.type = JSONValueType.Number
        v.value = decoded + 0.0
    end
    return v
end
