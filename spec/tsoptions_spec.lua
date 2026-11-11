-- Ported from typescript-go internal/tsoptions/*_test.go (direct assertions; baseline tests are
-- covered by the baseline runner).
local core = require("tslua.core")
local collections = require("tslua.collections")
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
    it("TestParseCompilerOptionNoMissingFields", function()
        local missing = {}
        for _, field in ipairs(core.CompilerOptions.Fields) do
            local co = core.NewCompilerOptions()
            if not tsoptions.parseCompilerOptions(field.json, field.zero, co) then
                missing[#missing + 1] = field.json
            end
        end
        assert.are.same({}, missing)
    end)

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

    it("TestResponseFileParsing", function()
        local host = newHost({ ["/project/args.txt"] = "--strict --outDir dist" }, "/project", true)
        local parsed = tsoptions.ParseCommandLine({ "@args.txt" }, host)
        assert.are.equal(0, #parsed.errors)
        assert.is_true(core.Tristate_IsTrue(parsed:CompilerOptions().strict))
        assert.are.equal("/project/dist", parsed:CompilerOptions().outDir)

        host = newHost({
            ["/project/a.txt"] = "@/project/b.txt --strict",
            ["/project/b.txt"] = "@/project/a.txt --outDir dist",
        }, "/project", true)
        parsed = tsoptions.ParseCommandLine({ "@a.txt" }, host)
        assert.are.equal(0, #parsed.errors)
        assert.is_true(core.Tristate_IsTrue(parsed:CompilerOptions().strict))
        assert.are.equal("/project/dist", parsed:CompilerOptions().outDir)
    end)

    it("TestParseCommandLineTypeRootsRelativePath", function()
        local host = newHost({ ["/home/project/bug.ts"] = "let x = 1;" }, "/home/project", true)
        local cmdLine = tsoptions.ParseCommandLine({ "--typeRoots", "t", "bug.ts" }, host)
        assert.are.same({ "/home/project/t" }, cmdLine:CompilerOptions().typeRoots)
    end)

    it("TestCustomConditionsNullOverride", function()
        local files = {
            ["/project/tsconfig.json"] = '{\n  "compilerOptions": {\n    "customConditions": ["condition1", "condition2"]\n  }\n}',
            ["/project/index.ts"] = 'console.log("Hello, World!");',
        }
        local host = newHost(files, "/project", true)
        local cmdLine = tsoptions.ParseCommandLine({ "--project", "/project", "--customConditions", "null" }, host)
        local value, exists = cmdLine.raw:Get("customConditions")
        assert.is_true(exists)
        assert.is_nil(value)

        local wrappedRaw = collections.NewOrderedMap()
        wrappedRaw:Set("compilerOptions", cmdLine.raw)
        local parsedConfig, errors = tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig.json", cmdLine:CompilerOptions(), wrappedRaw, host, nil)
        assert.is_nil(errors)
        assert.is_nil(parsedConfig:CompilerOptions().customConditions)
    end)

    it("TestParseBuildCommandLine", function()
        local host = newHost({}, "/", true)
        local parsed = tsoptions.ParseBuildCommandLine({ "--clean", "--force" }, host)
        assert.are.same({ "." }, parsed.projects)
        assert.are.same({ diagnostics.Options_0_and_1_cannot_be_combined:Code() }, codes(parsed.errors))
        parsed = tsoptions.ParseBuildCommandLine({ "--verbose", "--listFiles", "p1" }, host)
        assert.are.same({}, codes(parsed.errors))
        assert.is_true(core.Tristate_IsTrue(parsed.buildOptions.verbose))
        assert.is_true(core.Tristate_IsTrue(parsed.compilerOptions.listFiles))
        assert.are.same({ "p1" }, parsed.projects)
        parsed = tsoptions.ParseBuildCommandLine({ "--strict" }, host)
        assert.are.same({ diagnostics.Compiler_option_0_may_not_be_used_with_build:Code() }, codes(parsed.errors))
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

    it("TestParseJsonSourceFileConfigFileContentWithEmptyExtendedConfig", function()
        local parsed = parseConfig({
            ["/project/tsconfig.json"] = '{\n  "extends": "./base.json"\n}',
            ["/project/base.json"] = "",
            ["/project/main.ts"] = "export const x = 1;",
        }, "/project/tsconfig.json", "/project")
        assert.are.same({ "/project/main.ts" }, parsed:FileNames())
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

    it("TestParseJsonConfigFileContentPreservesRaw", function()
        local host = newHost({ ["/project/index.ts"] = "export {};" }, "/project", true)
        local parsed = tsoptions.ParseJsonConfigFileContent(
            { files = { "index.ts" }, customSetting = { enabled = true }, compileOnSave = true },
            host, "/project", nil, "/project/tsconfig.json", nil, nil
        )
        assert.are.equal(0, core.Len(parsed.errors))
        assert.is_true(parsed.compileOnSave)
        assert.are.same({ "compileOnSave", "customSetting", "files" }, core.Collect(parsed.raw:Keys()))
    end)

    it("TestParseJsonConfigFileContentDefaultsCompileOnSaveToFalse", function()
        local host = newHost({ ["/project/index.ts"] = "export {};" }, "/project", true)
        local parsed = tsoptions.ParseJsonConfigFileContent({ files = { "index.ts" } }, host, "/project", nil, "/project/tsconfig.json", nil, nil)
        assert.is_false(parsed.compileOnSave)
    end)

    it("TestParseConfigFileTextToJson", function()
        local config, errors = tsoptions.ParseConfigFileTextToJson("/tsconfig.json", "/tsconfig.json", '{ // Excluded files\n "exclude": [\n // Exclude d.ts\n "file.d.ts"\n ]\n }')
        assert.is_nil(errors)
        assert.are.same({ "file.d.ts" }, config:GetOrZero("exclude"))
    end)
end)

describe("wildcard directories", function()
    it("TestGetWildcardDirectories_DotPrefixedIncludeWithDotDirExclude", function()
        local result = tsoptions.getWildcardDirectories(
            { "./app/**/*.ts", "./app/**/*.tsx" },
            { "**/node_modules", "**/.*/", "./build" },
            tspath.NewComparePathsOptions(true, "/home/projects/monorepo/apps/web")
        )
        assert.are.same({ ["/home/projects/monorepo/apps/web/app"] = true }, result)
    end)
end)
