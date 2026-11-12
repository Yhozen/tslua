-- Port of internal/packagejson/packagejson_test.go (TestParse; BenchmarkPackageJSON is skipped).
local packagejson = require("tslua.packagejson")

-- Go compares with cmpopts.IgnoreUnexported(Fields, HeaderFields, Expected[...], ExportsOrImports):
-- keep only the exported fields (Expected: Null/Valid/Value; JSONValue: Type/Value).
local function exported(v)
    if type(v) ~= "table" then
        return v
    end
    local mt = getmetatable(v)
    if mt == packagejson.Expected then
        return { null = v.null, valid = v.valid, value = exported(v.value) }
    elseif mt == packagejson.JSONValue or mt == packagejson.ExportsOrImports then
        return { type = v.type, value = exported(v.value) }
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = exported(x)
    end
    return out
end

local function fields(init)
    local f = packagejson.NewFields()
    for k, v in pairs(init) do
        f[k] = v
    end
    return f
end

local function contentMapperFields(init)
    local f = packagejson.NewContentMapperFields()
    for k, v in pairs(init) do
        f[k] = v
    end
    return f
end

describe("TestParse", function()
    local tests = {
        {
            name = "duplicate names",
            content = [[{
				"name": "test-package",
				"name": "test-package",
				"version": "1.0.0"
			}]],
            want = fields({
                -- HeaderFields
                name = packagejson.ExpectedOf("test-package", "string"),
                version = packagejson.ExpectedOf("1.0.0", "string"),
            }),
        },
        {
            name = "content mapper",
            content = [[{
				"name": "test-package",
				"typescript": {
					"contentMapper": { "exec": ["mapper"], "dynamicConfig": true }
				}
			}]],
            want = fields({
                name = packagejson.ExpectedOf("test-package", "string"),
                contentMapper = packagejson.ExpectedOf(contentMapperFields({
                    exec = packagejson.ExpectedOf({ "mapper" }, "array"),
                    dynamicConfig = packagejson.ExpectedOf(true, "boolean"),
                }), "object"),
            }),
        },
        {
            name = "invalid typescript field is ignored",
            content = [[{ "name": "test-package", "typescript": "invalid" }]],
            want = fields({
                name = packagejson.ExpectedOf("test-package", "string"),
            }),
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local got, err = packagejson.Parse(tt.content)
            assert.is_nil(err)
            assert.are.same(exported(tt.want), exported(got))
        end)
    end
end)
