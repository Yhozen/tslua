local packagejson = require("tslua.packagejson")

-- Expected[T]. Generics vanish, so the expected JSON type of T (Go uses reflection on T) is
-- stored in the `expectedJSONType` field: "string", "boolean", "array", "object", "number".
local Expected = {}
Expected.__index = Expected
packagejson.Expected = Expected

local zeroValues = {
    string = "",
    boolean = false,
    number = 0,
}

function packagejson.newExpected(expectedJSONType)
    return setmetatable({
        actualJSONType = "",
        null = false,
        valid = false,
        value = zeroValues[expectedJSONType],
        expectedJSONType = expectedJSONType,
    }, Expected)
end

-- UnmarshalJSON. `convert(decoded)` returns the Go value of T and whether the unmarshal into T
-- succeeded.
function packagejson.unmarshalExpected(expectedJSONType, decoded, convert)
    local e = packagejson.newExpected(expectedJSONType)
    local kind = packagejson.decodedKind(decoded)
    if kind == "null" then
        e.null = true
        e.actualJSONType = "null"
        return e
    end
    local value, ok = convert(decoded)
    if ok then
        e.value = value
        e.valid = true
    end
    e.actualJSONType = kind
    return e
end

function Expected:IsPresent()
    return self.actualJSONType ~= ""
end

function Expected:GetValue()
    return self.value, self.valid
end

function Expected:IsValid()
    return self.valid
end

function Expected:ExpectedJSONType()
    return self.expectedJSONType or "unknown"
end

function Expected:ActualJSONType()
    return self.actualJSONType
end

function packagejson.ExpectedOf(value, expectedJSONType)
    local e = packagejson.newExpected(expectedJSONType)
    e.value = value
    e.valid = true
    e.actualJSONType = expectedJSONType
    return e
end
