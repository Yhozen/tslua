-- Port of internal/packagejson/expected_test.go. Go unmarshals into an anonymous struct through
-- reflection; the Lua port has no reflection, so the struct's fields are decoded explicitly
-- (packagejson.unmarshalExpected with a converter for each Go type argument).
local packagejson = require("tslua.packagejson")

local function convertString(decoded)
    if type(decoded) == "string" then
        return decoded, true
    end
    return "", false
end

local function convertAny(decoded)
    return decoded, true
end

describe("TestExpected", function()
    it("TestExpected", function()
        -- type packageJson struct { Name Expected[string]; Version Expected[string]; Exports Expected[any]; Main Expected[string] }
        local fields = {
            { "name", "string", convertString },
            { "version", "string", convertString },
            { "exports", "unknown", convertAny },
            { "main", "string", convertString },
        }

        local p = {}
        for _, f in ipairs(fields) do
            p[f[1]] = packagejson.newExpected(f[2])
        end

        local jsonString = [[{
		"name": "test",
		"version": 2,
		"exports": null
	}]]

        local decoded, err = packagejson.decodeJSON(jsonString)
        assert.is_nil(err)
        packagejson.decodedObjectEach(decoded, function(key, value)
            for _, f in ipairs(fields) do
                if f[1] == key then
                    p[key] = packagejson.unmarshalExpected(f[2], value, f[3])
                end
            end
        end)

        assert.are.equal(true, p.name.valid)
        assert.are.equal("test", p.name.value)

        assert.are.equal(false, p.version.valid)
        assert.are.equal("", p.version.value)

        assert.is_true(p.exports.null)
        assert.are.equal(false, p.exports.valid)

        assert.are.equal(false, p.main.valid)
        assert.are.equal(false, p.main.null)
        assert.are.equal("", p.main.value)
    end)
end)
