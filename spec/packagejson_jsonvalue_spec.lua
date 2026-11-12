-- Port of internal/packagejson/jsonvalue_test.go. Go unmarshals into an anonymous struct through
-- reflection; the Lua port decodes the struct's fields explicitly.
local packagejson = require("tslua.packagejson")

local JSONValueType = packagejson.JSONValueType

local function testJSONValue(unmarshal)
    -- type packageJson struct { Private, False, Name, Version, Exports, Imports, NotPresent JSONValue }
    local tags = {
        private = "private",
        ["false"] = "false_",
        name = "name",
        version = "version",
        exports = "exports",
        imports = "imports",
        notPresent = "notPresent",
    }
    local p = {}
    for _, field in pairs(tags) do
        p[field] = packagejson.NewJSONValue()
    end

    local jsonString = [[{
		"private": true,
		"false": false,
		"name": "test",
		"version": 2,
		"exports": {
			".": {
				"import": "./test.ts",
				"default": "./test.ts"
			},
			"./test": [
				"./test1.ts",
				"./test2.ts",
				null
			],
			"./null": null
		},
		"imports": null
	}]]

    local err = unmarshal(jsonString, p, tags)
    assert.is_nil(err)

    assert.are.equal(JSONValueType.Boolean, p.private.type)
    assert.are.equal(true, p.private.value)

    assert.are.equal(JSONValueType.String, p.name.type)
    assert.are.equal("test", p.name.value)

    assert.are.equal(JSONValueType.Number, p.version.type)
    assert.are.equal(2.0, p.version.value)
    assert.are.equal("float", math.type(p.version.value))

    assert.are.equal(JSONValueType.Object, p.exports.type)
    assert.are.equal(3, p.exports:AsObject():Size())
    assert.are.equal(JSONValueType.Object, p.exports:AsObject():GetOrZero(".").type)
    assert.are.equal("./test.ts", p.exports:AsObject():GetOrZero("."):AsObject():GetOrZero("import").value)

    assert.are.equal(JSONValueType.Array, p.exports:AsObject():GetOrZero("./test").type)
    assert.are.equal(3, #p.exports:AsObject():GetOrZero("./test"):AsArray())
    assert.are.equal("./test1.ts", p.exports:AsObject():GetOrZero("./test"):AsArray()[1].value)
    assert.are.equal("./test2.ts", p.exports:AsObject():GetOrZero("./test"):AsArray()[2].value)
    assert.are.equal(JSONValueType.Null, p.exports:AsObject():GetOrZero("./test"):AsArray()[3].type)

    assert.are.equal(JSONValueType.Null, p.exports:AsObject():GetOrZero("./null").type)

    assert.are.equal(JSONValueType.Null, p.imports.type)
    assert.is_nil(p.imports.value)

    assert.are.equal(JSONValueType.NotPresent, p.notPresent.type)
    assert.is_nil(p.notPresent.value)
end

describe("TestJSONValue", function()
    it("UnmarshalJSONV2", function()
        testJSONValue(function(input, out, tags)
            local decoded, err = packagejson.decodeJSON(input)
            if err ~= nil then
                return err
            end
            packagejson.decodedObjectEach(decoded, function(key, value)
                local field = tags[key]
                if field ~= nil then
                    out[field] = packagejson.unmarshalJSONValue(packagejson.JSONValue, value)
                end
            end)
            return nil
        end)
    end)
end)
