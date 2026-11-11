local packagejson = require("tslua.packagejson")
local collections = require("tslua.collections")
local json = require("tslua.json")

-- Fields embeds HeaderFields, PathFields and DependencyFields; all are flattened onto one table:
--   HeaderFields:     name, version, type (Expected[string])
--   PathFields:       tsConfig, main, types, typings (Expected[string]), typesVersions (JSONValue),
--                     imports, exports (ExportsOrImports)
--   DependencyFields: dependencies, devDependencies, peerDependencies, optionalDependencies
--                     (Expected[map[string]string]; the map is a Lua table name -> version)
--   contentMapper (Expected[ContentMapperFields])
local Fields = {}
Fields.__index = Fields
packagejson.Fields = Fields
-- DependencyFields methods are promoted to Fields (and PackageJson).
packagejson.DependencyFields = Fields

function packagejson.NewFields()
    return setmetatable({
        name = packagejson.newExpected("string"),
        version = packagejson.newExpected("string"),
        type = packagejson.newExpected("string"),
        tsConfig = packagejson.newExpected("string"),
        main = packagejson.newExpected("string"),
        types = packagejson.newExpected("string"),
        typings = packagejson.newExpected("string"),
        typesVersions = packagejson.NewJSONValue(),
        imports = packagejson.NewExportsOrImports(),
        exports = packagejson.NewExportsOrImports(),
        dependencies = packagejson.newExpected("object"),
        devDependencies = packagejson.newExpected("object"),
        peerDependencies = packagejson.newExpected("object"),
        optionalDependencies = packagejson.newExpected("object"),
        contentMapper = packagejson.newExpected("object"),
    }, Fields)
end

-- HasDependency returns true if the package.json has a dependency with the given name
-- under any of the dependency fields (dependencies, devDependencies, peerDependencies,
-- optionalDependencies).
function Fields:HasDependency(name)
    local deps, ok = self.dependencies:GetValue()
    if ok and deps[name] ~= nil then
        return true
    end
    local devDeps, ok2 = self.devDependencies:GetValue()
    if ok2 and devDeps[name] ~= nil then
        return true
    end
    local peerDeps, ok3 = self.peerDependencies:GetValue()
    if ok3 and peerDeps[name] ~= nil then
        return true
    end
    local optDeps, ok4 = self.optionalDependencies:GetValue()
    if ok4 and optDeps[name] ~= nil then
        return true
    end
    return false
end

function Fields:RangeDependencies(f)
    local fields = {
        { self.dependencies, "dependencies" },
        { self.devDependencies, "devDependencies" },
        { self.peerDependencies, "peerDependencies" },
        { self.optionalDependencies, "optionalDependencies" },
    }
    for _, entry in ipairs(fields) do
        local deps, ok = entry[1]:GetValue()
        if ok then
            for name, version in pairs(deps) do
                if not f(name, version, entry[2]) then
                    return
                end
            end
        end
    end
end

function Fields:GetRuntimeDependencyNames()
    local count = 0
    local deps = self.dependencies:GetValue() or {}
    local peerDeps = self.peerDependencies:GetValue() or {}
    local optDeps = self.optionalDependencies:GetValue() or {}
    local names = collections.NewSetWithSizeHint(count)
    for name in pairs(deps) do
        names:Add(name)
    end
    for name in pairs(peerDeps) do
        names:Add(name)
    end
    for name in pairs(optDeps) do
        names:Add(name)
    end
    return names
end

-- ContentMapperFields: { exec = Expected[[]string], compilerOptions = Expected[[]string],
-- dynamicConfig = Expected[bool] }
function packagejson.NewContentMapperFields()
    return {
        exec = packagejson.newExpected("array"),
        compilerOptions = packagejson.newExpected("array"),
        dynamicConfig = packagejson.newExpected("boolean"),
    }
end

-- Converters used to unmarshal a decoded JSON value into a Go type T: return value, ok.
local function convertString(decoded)
    if type(decoded) == "string" then
        return decoded, true
    end
    return "", false
end

local function convertBool(decoded)
    if type(decoded) == "boolean" then
        return decoded, true
    end
    return false, false
end

local function convertStringMap(decoded)
    if packagejson.decodedKind(decoded) ~= "object" then
        return nil, false
    end
    local result = {}
    local ok = true
    packagejson.decodedObjectEach(decoded, function(key, value)
        local kind = packagejson.decodedKind(value)
        if kind == "string" then
            result[key] = value
        elseif kind == "null" then
            result[key] = ""
        else
            ok = false
        end
    end)
    if not ok then
        return nil, false
    end
    return result, true
end

local function convertStringSlice(decoded)
    if packagejson.decodedKind(decoded) ~= "array" then
        return nil, false
    end
    local result = {}
    for _, value in ipairs(packagejson.decodedArray(decoded)) do
        local kind = packagejson.decodedKind(value)
        if kind == "string" then
            result[#result + 1] = value
        elseif kind == "null" then
            result[#result + 1] = ""
        else
            return nil, false
        end
    end
    return result, true
end

local function getField(decoded, name)
    local value, ok = nil, false
    packagejson.decodedObjectEach(decoded, function(key, v)
        if key == name then
            value, ok = v, true
        end
    end)
    return value, ok
end

local function convertContentMapperFields(decoded)
    if packagejson.decodedKind(decoded) ~= "object" then
        return packagejson.NewContentMapperFields(), false
    end
    local result = packagejson.NewContentMapperFields()
    local v, ok = getField(decoded, "exec")
    if ok then
        result.exec = packagejson.unmarshalExpected("array", v, convertStringSlice)
    end
    v, ok = getField(decoded, "compilerOptions")
    if ok then
        result.compilerOptions = packagejson.unmarshalExpected("array", v, convertStringSlice)
    end
    v, ok = getField(decoded, "dynamicConfig")
    if ok then
        result.dynamicConfig = packagejson.unmarshalExpected("boolean", v, convertBool)
    end
    return result, true
end

local function convertTypeScriptFields(decoded)
    if packagejson.decodedKind(decoded) ~= "object" then
        return { contentMapper = packagejson.newExpected("object") }, false
    end
    local result = { contentMapper = packagejson.newExpected("object") }
    local v, ok = getField(decoded, "contentMapper")
    if ok then
        result.contentMapper = packagejson.unmarshalExpected("object", v, convertContentMapperFields)
    end
    return result, true
end

local expectedStringFields = {
    name = "name",
    version = "version",
    type = "type",
    tsconfig = "tsConfig",
    main = "main",
    types = "types",
    typings = "typings",
}

local expectedMapFields = {
    dependencies = true,
    devDependencies = true,
    peerDependencies = true,
    optionalDependencies = true,
}

-- Parse returns (Fields, err). err is nil on success, a string otherwise.
function packagejson.Parse(data)
    local decoded, err = packagejson.decodeJSON(data)
    if err ~= nil then
        return packagejson.NewFields(), err
    end
    local kind = packagejson.decodedKind(decoded)
    if kind == "null" then
        return packagejson.NewFields(), nil
    end
    if kind ~= "object" then
        return packagejson.NewFields(), "json: cannot unmarshal " .. kind .. " into Go value of type struct"
    end
    local parsed = packagejson.NewFields()
    local typeScript = packagejson.newExpected("object")
    packagejson.decodedObjectEach(decoded, function(key, value)
        local stringField = expectedStringFields[key]
        if stringField ~= nil then
            parsed[stringField] = packagejson.unmarshalExpected("string", value, convertString)
        elseif expectedMapFields[key] then
            parsed[key] = packagejson.unmarshalExpected("object", value, convertStringMap)
        elseif key == "typesVersions" then
            parsed.typesVersions = packagejson.unmarshalJSONValue(packagejson.JSONValue, value)
        elseif key == "imports" then
            parsed.imports = packagejson.unmarshalExportsOrImports(value)
        elseif key == "exports" then
            parsed.exports = packagejson.unmarshalExportsOrImports(value)
        elseif key == "typescript" then
            typeScript = packagejson.unmarshalExpected("object", value, convertTypeScriptFields)
        end
    end)
    local typeScriptValue = typeScript:GetValue()
    if typeScriptValue ~= nil and typeScript:IsValid() then
        parsed.contentMapper = typeScriptValue.contentMapper
    end
    return parsed, nil
end

-- Adapters over the generic values produced by tslua.json (Go's json.Unmarshal does the
-- equivalent work through reflection).
function packagejson.decodeJSON(data)
    local ok, value, err = pcall(json.Unmarshal, data, { ordered = true, allowDuplicateNames = true })
    if not ok then
        return nil, tostring(value)
    end
    if err ~= nil then
        return nil, err
    end
    return value, nil
end

function packagejson.decodedKind(decoded)
    if decoded == nil or decoded == json.Null then
        return "null"
    end
    local t = type(decoded)
    if t == "string" then
        return "string"
    elseif t == "boolean" then
        return "boolean"
    elseif t == "number" then
        return "number"
    elseif t == "table" then
        if getmetatable(decoded) == collections.OrderedMap then
            return "object"
        end
        return "array"
    end
    return "unknown"
end

function packagejson.decodedArray(decoded)
    return decoded
end

function packagejson.decodedObjectEach(decoded, f)
    for key, value in decoded:Entries() do
        f(key, value)
    end
end
