-- Hand-written tsoptions smoke tests. The Go tests of internal/tsoptions/*_test.go are ported in
-- spec/tsoptions_<file>_spec.lua.
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

local Tristate = core.Tristate

-- tsoptionstest.NewVFSParseConfigHost
local function newHost(files, cwd, useCaseSensitiveFileNames)
    local fs = vfstest.FromMap(files, useCaseSensitiveFileNames)
    return {
        FS = function() return fs end,
        GetCurrentDirectory = function() return cwd end,
    }
end

local function codes(diags)
    local result = {}
    for i, d in ipairs(diags or {}) do
        result[i] = d:Code()
    end
    return result
end

describe("tsoptions declarations", function()
    it("builds name maps", function()
        assert.are.equal("strict", tsoptions.CompilerNameMap:Get("STRICT").name)
        assert.are.equal("help", tsoptions.CompilerNameMap:GetOptionDeclarationFromName("h", true).name)
        assert.are.equal("build", tsoptions.BuildNameMap:GetOptionDeclarationFromName("b", true).name)
        assert.are.equal("lib.es2015.d.ts", (tsoptions.GetLibFileName("ES6")))
        assert.are.equal("lib.es2025.full.d.ts", tsoptions.GetDefaultLibFileName(core.NewCompilerOptions()))
        assert.are.equal("lib.esnext.full.d.ts", tsoptions.GetDefaultLibFileName(core.NewCompilerOptions({ target = core.ScriptTarget.ESNext })))
    end)
end)

describe("ParseCommandLine", function()
    it("parses options and file names", function()
        local host = newHost({ ["/project/a.ts"] = "" }, "/project", true)
        local parsed = tsoptions.ParseCommandLine({ "--strict", "--target", "es2020", "--outDir", "dist", "--lib", "es5,dom", "a.ts" }, host)
        assert.are.same({}, codes(parsed.errors))
        local options = parsed:CompilerOptions()
        assert.are.equal(Tristate.TSTrue, options.strict)
        assert.are.equal(core.ScriptTarget.ES2020, options.target)
        assert.are.equal("/project/dist", options.outDir)
        assert.are.same({ "lib.es5.d.ts", "lib.dom.d.ts" }, options.lib)
        assert.are.same({ "a.ts" }, parsed:FileNames())
    end)

    it("reports unknown options with suggestions", function()
        local host = newHost({}, "/", true)
        local parsed = tsoptions.ParseCommandLine({ "--strictt" }, host)
        assert.are.same({ diagnostics.Unknown_compiler_option_0_Did_you_mean_1:Code() }, codes(parsed.errors))
        parsed = tsoptions.ParseCommandLine({ "--verbose" }, host)
        assert.are.same({ diagnostics.Compiler_option_0_may_only_be_used_with_build:Code() }, codes(parsed.errors))
    end)

    it("reports invalid enum values and missing arguments", function()
        local host = newHost({}, "/", true)
        local parsed = tsoptions.ParseCommandLine({ "--target", "es7" }, host)
        assert.are.same({ diagnostics.Argument_for_0_option_must_be_Colon_1:Code() }, codes(parsed.errors))
        parsed = tsoptions.ParseCommandLine({ "--outDir" }, host)
        assert.are.same({ diagnostics.Compiler_option_0_expects_an_argument:Code() }, codes(parsed.errors))
    end)
end)

describe("tsconfig parsing", function()
    local function parseConfig(files, configFileName, cwd)
        local host = newHost(files, cwd, true)
        local configFile = tsoptions.NewTsconfigSourceFileFromFilePath(
            configFileName,
            tspath.ToPath(configFileName, cwd, true),
            files[configFileName]
        )
        return tsoptions.ParseJsonSourceFileConfigFileContent(configFile, host, cwd, nil, nil, configFileName, nil, nil)
    end

    it("parses compilerOptions, include and exclude", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = [[{
  // comment
  "compilerOptions": { "strict": true, "outDir": "dist", "module": "nodenext", "paths": { "@x/*": ["./x/*"] } },
  "include": ["src"],
  "exclude": ["src/ignored"]
}]],
            ["/project/src/a.ts"] = "",
            ["/project/src/b.tsx"] = "",
            ["/project/src/c.d.ts"] = "",
            ["/project/src/ignored/d.ts"] = "",
            ["/project/other.ts"] = "",
        }, "/project/tsconfig.json", "/project")
        assert.are.same({}, codes(parsed.errors))
        local options = parsed:CompilerOptions()
        assert.are.equal(Tristate.TSTrue, options.strict)
        assert.are.equal("/project/dist", options.outDir)
        assert.are.equal(core.ModuleKind.NodeNext, options.module)
        assert.are.equal("/project/tsconfig.json", options.configFilePath)
        assert.are.equal("/project", options.pathsBasePath)
        assert.are.same({ "./x/*" }, options.paths:GetOrZero("@x/*"))
        assert.are.same({ "/project/src/a.ts", "/project/src/b.tsx", "/project/src/c.d.ts" }, parsed:FileNames())
    end)

    it("handles files and extends", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = '{ "extends": "./base.json", "files": ["main.ts"] }',
            ["/project/base.json"] = '{ "compilerOptions": { "target": "es2017", "declaration": true }, "include": ["lib"] }',
            ["/project/main.ts"] = "",
            ["/project/lib/l.ts"] = "",
        }, "/project/tsconfig.json", "/project")
        assert.are.same({}, codes(parsed.errors))
        assert.are.equal(core.ScriptTarget.ES2017, parsed:CompilerOptions().target)
        assert.are.equal(Tristate.TSTrue, parsed:CompilerOptions().declaration)
        assert.are.same({ "/project/main.ts", "/project/lib/l.ts" }, parsed:FileNames())
        assert.are.same({ "/project/base.json" }, parsed:ExtendedSourceFiles())
        assert.are.same({ "/project/main.ts" }, parsed:LiteralFileNames())
    end)

    it("reports unknown compiler options, root compiler options and empty inputs", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = '{ "compilerOptions": { "strictt": true }, "outDir": "x", "include": ["nothing"] }',
        }, "/project/tsconfig.json", "/project")
        assert.are.same({
            diagnostics.Unknown_compiler_option_0_Did_you_mean_1:Code(),
            diagnostics.No_inputs_were_found_in_config_file_0_Specified_include_paths_were_1_and_exclude_paths_were_2:Code(),
        }, codes(parsed.errors))

        parsed = parseConfig({
            ["/project/tsconfig.json"] = '{ "strict": true }',
            ["/project/a.ts"] = "",
        }, "/project/tsconfig.json", "/project")
        assert.are.same({ diagnostics.X_0_should_be_set_inside_the_compilerOptions_object_of_the_config_json_file:Code() }, codes(parsed.errors))
    end)

    it("detects circular extends", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = '{ "extends": "./a.json" }',
            ["/project/a.json"] = '{ "extends": "./tsconfig.json" }',
            ["/project/x.ts"] = "",
        }, "/project/tsconfig.json", "/project")
        assert.are.same({ diagnostics.Circularity_detected_while_resolving_configuration_Colon_0:Code() }, codes(parsed.errors))
    end)

    it("parses references", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = '{ "files": [], "references": [{ "path": "./sub" }, { "path": 1 }] }',
        }, "/project/tsconfig.json", "/project")
        assert.are.same({ diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code() }, codes(parsed.errors))
        local refs = parsed:ProjectReferences()
        assert.are.equal(1, #refs)
        assert.are.equal("/project/sub", refs[1].path)
        assert.are.equal("./sub", refs[1].originalPath)
        assert.are.same({ "/project/sub/tsconfig.json" }, parsed:ResolvedProjectReferencePaths())
    end)
end)
