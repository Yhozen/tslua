-- Port of internal/execute/tsc/extendedconfigcache_test.go.
local tsc = require("tslua.execute.tsc")
local tsoptions = require("tslua.tsoptions")
local vfstest = require("tslua.vfs.vfstest")

-- testParseConfigHost implements tsoptions.ParseConfigHost.
local testParseConfigHost = {}
testParseConfigHost.__index = testParseConfigHost

function testParseConfigHost:FS() return self.fs end
function testParseConfigHost:GetCurrentDirectory() return self.cwd end

local function newHost(fs, cwd)
    return setmetatable({ fs = fs, cwd = cwd }, testParseConfigHost)
end

local function assertHasCircularityDiagnostic(cmd)
    for _, d in ipairs(cmd.errors or {}) do
        if d ~= nil and d:Code() == 18000 then
            return
        end
    end
    error("expected circularity diagnostic (code 18000), but none was found")
end

describe("TestExtendedConfigCacheExtendsCircularity", function()
    it("self-referencing extends", function()
        -- Regression test: a tsconfig extends cycle should produce an error,
        -- not a deadlock when using the tsc ExtendedConfigCache.
        local files = {
            ["/project/tsconfig.json"] = '{"extends": "./base.json"}',
            ["/project/base.json"] = '{"extends": "./base.json"}',
            ["/project/main.ts"] = "// Hello World!",
        }

        local fs = vfstest.FromMap(files, false --[[useCaseSensitiveFileNames]])
        local host = newHost(fs, "/project")
        local cache = tsc.NewExtendedConfigCache()

        local cmd = tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig.json", nil, nil, host, cache)
        assert.is_true(cmd ~= nil, "expected non-nil ParsedCommandLine")
        assertHasCircularityDiagnostic(cmd)
    end)

    it("mutual extends cycle", function()
        -- Two config files that extend each other.
        local files = {
            ["/project/tsconfig.json"] = '{"extends": "./other.json"}',
            ["/project/other.json"] = '{"extends": "./tsconfig.json"}',
            ["/project/main.ts"] = "// Hello World!",
        }

        local fs = vfstest.FromMap(files, false --[[useCaseSensitiveFileNames]])
        local host = newHost(fs, "/project")
        local cache = tsc.NewExtendedConfigCache()

        local cmd = tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig.json", nil, nil, host, cache)
        assert.is_true(cmd ~= nil, "expected non-nil ParsedCommandLine")
        assertHasCircularityDiagnostic(cmd)
    end)

    it("case-insensitive self-referencing extends", function()
        -- On a case-insensitive FS, ./Base.json and ./base.json resolve to the same
        -- cache entry. The cycle check must use canonical paths to avoid deadlock.
        local files = {
            ["/project/tsconfig.json"] = '{"extends": "./Base.json"}',
            ["/project/base.json"] = '{"extends": "./base.json"}',
            ["/project/main.ts"] = "// Hello World!",
        }

        local fs = vfstest.FromMap(files, false --[[useCaseSensitiveFileNames]])
        local host = newHost(fs, "/project")
        local cache = tsc.NewExtendedConfigCache()

        local cmd = tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig.json", nil, nil, host, cache)
        assert.is_true(cmd ~= nil, "expected non-nil ParsedCommandLine")
        assertHasCircularityDiagnostic(cmd)
    end)
end)

describe("TestExtendedConfigCacheNullExtendsDoesNotPanic", function()
    it("TestExtendedConfigCacheNullExtendsDoesNotPanic", function()
        local files = {
            ["/project/tsconfig.json"] = '{"extends": null}',
            ["/project/main.ts"] = "// Hello World!",
        }

        local fs = vfstest.FromMap(files, false --[[useCaseSensitiveFileNames]])
        local host = newHost(fs, "/project")
        local cache = tsc.NewExtendedConfigCache()

        local cmd = tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig.json", nil, nil, host, cache)
        assert.is_true(cmd ~= nil, "expected non-nil ParsedCommandLine")
        assert.is_true(#(cmd.errors or {}) > 0, "expected diagnostics for invalid null extends")
    end)
end)
