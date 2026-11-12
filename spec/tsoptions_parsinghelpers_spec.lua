-- Port of internal/tsoptions/parsinghelpers_test.go. The Go test reflects over the visible fields
-- of core.CompilerOptions; core.CompilerOptions.Fields is the Lua description of that struct (json
-- key and Go zero value per field).
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")

describe("TestParseCompilerOptionNoMissingFields", function()
    it("TestParseCompilerOptionNoMissingFields", function()
        local missingKeys = {}
        for _, field in ipairs(core.CompilerOptions.Fields) do
            -- use the JSON key from the tag
            local keyName = field.json
            local val = field.zero
            local co = core.NewCompilerOptions()
            local found = tsoptions.parseCompilerOptions(keyName, val, co)
            if not found then
                missingKeys[#missingKeys + 1] = keyName
            end
        end
        assert.are.same({}, missingKeys, "The following keys are missing entries in the ParseCompilerOptions switch statement")
    end)
end)
