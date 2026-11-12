-- Port of internal/tsoptions/decls_test.go. The Go test reflects over the core.CompilerOptions
-- struct; core.CompilerOptions.Fields is the Lua description of that struct (field name and json
-- tag name; every tag carries ",omitzero" in Go).
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")

local function checkCompilerOptionJsonTagName(errors, field, name)
    local want = name
    local got = field.json
    if got ~= want then
        errors[#errors + 1] = "Field " .. field.name .. " has json tag " .. got .. ", but the option declaration has name " .. name
    end
end

describe("TestCompilerOptionsDeclaration", function()
    it("TestCompilerOptionsDeclaration", function()
        local errors = {}
        local decls = {}

        for _, decl in ipairs(tsoptions.OptionsDeclarations) do
            decls[string.lower(decl.name)] = decl
        end

        local internalOptions = {
            "allowNonTsExtensions",
            "build",
            "configFilePath",
            "noDtsResolution",
            "noEmitForJsFiles",
            "pathsBasePath",
            "suppressOutputPathCheck",
            "build",
        }

        local internalOptionsMap = {}
        for _, opt in ipairs(internalOptions) do
            internalOptionsMap[string.lower(opt)] = opt
        end

        for _, field in ipairs(core.CompilerOptions.Fields) do
            local lowerName = string.lower(field.name)

            local decl = decls[lowerName]
            if decl == nil then
                local name = internalOptionsMap[lowerName]
                if name ~= nil then
                    checkCompilerOptionJsonTagName(errors, field, name)
                else
                    errors[#errors + 1] = "CompilerOptions." .. field.name .. " has no options declaration"
                end
            else
                decls[lowerName] = nil

                checkCompilerOptionJsonTagName(errors, field, decl.name)
            end
        end

        local skippedOptions = {
            "plugins",
        }

        for _, opt in ipairs(skippedOptions) do
            decls[string.lower(opt)] = nil
        end

        local remaining = {}
        for _, decl in pairs(decls) do
            remaining[#remaining + 1] = "Option declaration " .. decl.name .. " is not present in CompilerOptions"
        end
        table.sort(remaining)
        for _, msg in ipairs(remaining) do
            errors[#errors + 1] = msg
        end
        assert.are.same({}, errors)
    end)
end)
