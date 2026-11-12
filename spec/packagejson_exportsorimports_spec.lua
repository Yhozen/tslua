-- Port of internal/packagejson/exportsorimports_test.go. Go unmarshals into an anonymous struct
-- through reflection; the Lua port decodes the struct's fields explicitly.
local packagejson = require("tslua.packagejson")

local JSONValueType = packagejson.JSONValueType

local function testExports(unmarshal)
    -- type Exports struct { Imports ExportsOrImports `json:"imports"`; Exports ExportsOrImports `json:"exports"` }
    local e = { imports = packagejson.NewExportsOrImports(), exports = packagejson.NewExportsOrImports() }

    local jsonString = [[{
		"imports": {
			"#foo": {
				"import": "./foo.ts"
			}
		},
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
		}
	}]]

    local err = unmarshal(jsonString, e)
    assert.is_nil(err)

    assert.is_true(e.exports:IsSubpaths())
    assert.are.equal(3, e.exports:AsObject():Size())
    assert.is_true(e.exports:AsObject():GetOrZero("."):IsConditions())
    assert.is_true(e.exports:AsObject():GetOrZero("."):AsObject():GetOrZero("import").type == JSONValueType.String)
    assert.are.equal(JSONValueType.Null, e.exports:AsObject():GetOrZero("./test"):AsArray()[3].type)
    assert.is_true(e.exports:AsObject():GetOrZero("./null").type == JSONValueType.Null)

    assert.is_true(e.imports:IsImports())
    assert.are.equal(1, e.imports:AsObject():Size())
    assert.is_true(e.imports:AsObject():GetOrZero("#foo"):IsConditions())
    assert.is_true(e.imports:AsObject():GetOrZero("#foo"):AsObject():GetOrZero("import").type == JSONValueType.String)
end

describe("TestExports", function()
    it("UnmarshalJSONV2", function()
        testExports(function(input, out)
            local decoded, err = packagejson.decodeJSON(input)
            if err ~= nil then
                return err
            end
            packagejson.decodedObjectEach(decoded, function(key, value)
                if key == "imports" or key == "exports" then
                    out[key] = packagejson.unmarshalExportsOrImports(value)
                end
            end)
            return nil
        end)
    end)
end)
