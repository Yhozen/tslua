-- Port of internal/tsoptions/commandlineparser_test.go (with the export_test.go helper
-- ParseCommandLineTestWorker).
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local diagnosticwriter = require("tslua.diagnosticwriter")
local json = require("tslua.json")
local repo = require("tslua.repo")
local baseline = require("tslua.testutil.baseline")
local testutil = require("tslua.testutil")
local tsoptions = require("tslua.tsoptions")
local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local tspath = require("tslua.tspath")
local osvfs = require("tslua.vfs.osvfs")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind

-- runT runs fn(t) with a Go-style testing.T and fails the busted test if t failed.
local function runT(fn)
    local t = testutil.NewT("test", nil)
    testutil.runProtected(t, fn)
    if t.failed then
        error(table.concat(t.messages, "\n"), 0)
    end
end

-- t.TempDir()
local tempDirs = {}
local function tempDir()
    local p = os.tmpname()
    os.remove(p)
    os.execute("mkdir -p " .. osvfs.shellQuote(p))
    tempDirs[#tempDirs + 1] = p
    return p
end

teardown(function()
    for _, p in ipairs(tempDirs) do
        os.execute("rm -rf " .. osvfs.shellQuote(p))
    end
end)

-- export_test.go

local function getTestParseCommandLineWorkerDiagnostics(decls)
    if core.Len(decls) == 0 then
        return tsoptions.CompilerOptionsDidYouMeanDiagnostics
    end
    return tsoptions.getParseCommandLineWorkerDiagnostics(decls)
end

local function ParseCommandLineTestWorker(decls, commandLine, fs, currentDirectory)
    local parser = setmetatable({
        fs = fs,
        currentDirectory = currentDirectory,
        workerDiagnostics = tsoptions.CompilerOptionsDidYouMeanDiagnostics,
        fileNames = {},
        options = collections.NewOrderedMap(),
        errors = {},
        responseFileStack = {},
    }, tsoptions.commandLineParser)
    if core.Len(decls) ~= 0 then
        parser.workerDiagnostics = getTestParseCommandLineWorkerDiagnostics(decls)
    end

    parser.optionsMap = tsoptions.GetNameMapFromList(parser:OptionsDeclarations())
    parser:parseStrings(commandLine)
    return {
        fs = fs,
        workerDiagnostics = parser.workerDiagnostics,
        fileNames = parser.fileNames,
        options = parser.options,
        errors = parser.errors,
    }
end

-- Go json.Unmarshal into a struct: the fields are { json = name, name = luaField, kind = ... } with
-- the kinds of core.CompilerOptions.Fields. Unknown members are ignored. Returns err or nil.
local function unmarshalInto(target, fields, text)
    local object, err = json.Unmarshal(text, { ordered = true })
    if err ~= nil then
        return err
    end
    if object == nil then
        return nil
    end
    if type(object) ~= "table" or object.Entries == nil then
        return "json: cannot unmarshal into Go struct"
    end
    local byJson = {}
    for _, field in ipairs(fields) do
        byJson[field.json] = field
    end
    for key, value in object:Entries() do
        local field = byJson[key]
        if field ~= nil then
            local kind = field.kind
            if kind == "tristate" then
                local raw = "null"
                if value ~= nil then
                    raw = json.Marshal(value)
                end
                target[field.name] = core.Tristate_UnmarshalJSON(raw)
            elseif value == nil then
                if kind == "string" then
                    target[field.name] = ""
                elseif string.sub(kind, 1, 5) == "enum:" then
                    target[field.name] = 0
                else
                    target[field.name] = nil
                end
            elseif kind == "string" then
                if type(value) ~= "string" then
                    return "json: cannot unmarshal into Go " .. field.json .. " of type string"
                end
                target[field.name] = value
            elseif kind == "stringlist" then
                if type(value) ~= "table" or value.Entries ~= nil then
                    return "json: cannot unmarshal into Go " .. field.json .. " of type []string"
                end
                local list = {}
                for i, s in ipairs(value) do
                    if s == json.Null then
                        s = ""
                    elseif type(s) ~= "string" then
                        return "json: cannot unmarshal into Go " .. field.json .. " of type string"
                    end
                    list[i] = s
                end
                target[field.name] = list
            elseif kind == "intptr" or string.sub(kind, 1, 5) == "enum:" then
                if math.type(value) ~= "integer" and not (type(value) == "number" and value == math.floor(value)) then
                    return "json: cannot unmarshal into Go " .. field.json .. " of type int"
                end
                target[field.name] = math.tointeger(value)
            elseif kind == "map" then
                if type(value) ~= "table" or value.Entries == nil then
                    return "json: cannot unmarshal into Go " .. field.json .. " of type map"
                end
                local m = collections.NewOrderedMap()
                for k, v in value:Entries() do
                    m:Set(k, v)
                end
                target[field.name] = m
            else
                error("unexpected field kind " .. kind)
            end
        end
    end
    return nil
end

local watchOptionsFields = {
    { json = "watchInterval", name = "interval", kind = "intptr" },
    { json = "watchFile", name = "fileKind", kind = "enum:WatchFileKind" },
    { json = "watchDirectory", name = "directoryKind", kind = "enum:WatchDirectoryKind" },
    { json = "fallbackPolling", name = "fallbackPolling", kind = "enum:PollingKind" },
    { json = "synchronousWatchDirectory", name = "syncWatchDir", kind = "tristate" },
    { json = "excludeDirectories", name = "excludeDir", kind = "stringlist" },
    { json = "excludeFiles", name = "excludeFiles", kind = "stringlist" },
}

local buildOptionsFields = {
    { json = "dry", name = "dry", kind = "tristate" },
    { json = "force", name = "force", kind = "tristate" },
    { json = "verbose", name = "verbose", kind = "tristate" },
    { json = "builders", name = "builders", kind = "intptr" },
    { json = "stopBuildOnErrors", name = "stopBuildOnErrors", kind = "tristate" },
    { json = "clean", name = "clean", kind = "tristate" },
}

-- assert.DeepEqual(t, x, y, cmpopts.IgnoreUnexported(...)) over the exported struct fields.
local function assertFieldsDeepEqual(x, y, fields)
    for _, field in ipairs(fields) do
        local a, b = x[field.name], y[field.name]
        if field.kind == "map" and a ~= nil and b ~= nil then
            a, b = core.Collect(a:Entries()), core.Collect(b:Entries())
        end
        assert.are.same(a, b, field.name)
    end
end

-- strings.Cut
local function cut(s, sep)
    local i, j = string.find(s, sep, 1, true)
    if i == nil then
        return s, "", false
    end
    return string.sub(s, 1, i - 1), string.sub(s, j + 1), true
end

local function parseExistingCompilerBaseline(t, baselineText)
    local _, rest = cut(baselineText, "CompilerOptions::\n")
    local compilerOptions, watchOptions, watchFound
    compilerOptions, rest, watchFound = cut(rest, "\nWatchOptions::\n")
    watchOptions, rest = cut(rest, "\nFileNames::\n")
    local fileNames, errors = cut(rest, "\nErrors::\n")

    local baselineCompilerOptions = core.NewCompilerOptions()
    local e = unmarshalInto(baselineCompilerOptions, core.CompilerOptions.Fields, compilerOptions)
    testutil.Assert(t, e == nil, "%v", e)

    local baselineWatchOptions = core.NewWatchOptions()
    if watchFound and watchOptions ~= "" then
        local e2 = unmarshalInto(baselineWatchOptions, watchOptionsFields, watchOptions)
        testutil.Assert(t, e2 == nil, "%v", e2)
    end

    return {
        options = baselineCompilerOptions,
        watchoptions = baselineWatchOptions,
        fileNames = fileNames,
        errors = errors,
    }
end

local function formatArgs(formatted, commandLine)
    formatted:WriteString("Args::\n")
    formatted:WriteString("[")
    for i, arg in ipairs(commandLine) do
        if i > 1 then
            formatted:WriteString(", ")
        end
        formatted:WriteString('"')
        formatted:WriteString(arg)
        formatted:WriteString('"')
    end
    formatted:WriteString("]")
end

local function formatNewBaseline(commandLine, opts, fileNames, errors)
    local formatted = core.NewStringBuilder()
    formatArgs(formatted, commandLine)
    formatted:WriteString("\n\nCompilerOptions::\n")
    formatted:WriteString(opts)
    -- todo: watch options not implemented
    -- formatted.WriteString("WatchOptions::\n")
    formatted:WriteString("\n\nFileNames::\n")
    formatted:WriteString(fileNames)
    formatted:WriteString("\n\nErrors::\n")
    formatted:WriteString(errors)
    return formatted:String()
end

local function parseExistingCompilerBaselineBuild(t, baselineText)
    local _, rest = cut(baselineText, "buildOptions::\n")
    local buildOptions, watchOptions, watchFound
    buildOptions, rest, watchFound = cut(rest, "\nWatchOptions::\n")
    watchOptions, rest = cut(rest, "\nProjects::\n")
    local projects, errors = cut(rest, "\nErrors::\n")

    local baselineBuildOptions = core.NewBuildOptions()
    local e = unmarshalInto(baselineBuildOptions, buildOptionsFields, buildOptions)
    testutil.Assert(t, e == nil, "%v", e)

    local baselineCompilerOptions = core.NewCompilerOptions()
    e = unmarshalInto(baselineCompilerOptions, core.CompilerOptions.Fields, buildOptions)
    testutil.Assert(t, e == nil, "%v", e)

    local baselineWatchOptions = core.NewWatchOptions()
    if watchFound and watchOptions ~= "" then
        local e2 = unmarshalInto(baselineWatchOptions, watchOptionsFields, watchOptions)
        testutil.Assert(t, e2 == nil, "%v", e2)
    end

    return {
        options = baselineBuildOptions,
        compilerOptions = baselineCompilerOptions,
        watchoptions = baselineWatchOptions,
        projects = projects,
        errors = errors,
    }
end

local function formatNewBaselineBuild(commandLine, opts, compilerOpts, projects, errors)
    local formatted = core.NewStringBuilder()
    formatArgs(formatted, commandLine)
    formatted:WriteString("\n\nbuildOptions::\n")
    formatted:WriteString(opts)
    formatted:WriteString("\n\ncompilerOptions::\n")
    formatted:WriteString(compilerOpts)
    -- todo: watch options not implemented
    -- formatted.WriteString("WatchOptions::\n")
    formatted:WriteString("\n\nProjects::\n")
    formatted:WriteString(projects)
    formatted:WriteString("\n\nErrors::\n")
    formatted:WriteString(errors)
    return formatted:String()
end

-- filefixture.FromFile(name, path).ReadFile(t)
local function readFixture(t, path)
    local f = io.open(path, "rb")
    if f == nil then
        t:Fatalf("Failed to read test fixture %q: %v", path, "no such file")
    end
    local contents = f:read("a")
    f:close()
    return contents
end

local function createSubScenario(scenarioKind, subScenarioName, commandline, opts)
    subScenarioName = scenarioKind .. "/" .. subScenarioName
    local baselineFileName = "tests/baselines/reference/config/commandLineParsing/" .. subScenarioName .. ".js"

    return {
        baselinePath = repo.TypeScriptSubmodulePath() .. "/" .. baselineFileName,
        testName = subScenarioName,
        commandLine = commandline,
        optDecls = opts,
    }
end

local function assertParseResult(f)
    it(f.testName, function()
        runT(function(t)
            local originalBaseline = readFixture(t, f.baselinePath)
            local tsBaseline = parseExistingCompilerBaseline(t, originalBaseline)

            -- f.workerDiagnostic is either defined or set to default pointer in `createSubScenario`
            local parsed = ParseCommandLineTestWorker(f.optDecls, f.commandLine, osvfs.FS(), tempDir())

            local newBaselineFileNames = table.concat(parsed.fileNames, ",")
            assert.are.equal(tsBaseline.fileNames, newBaselineFileNames)

            local o = json.Marshal(parsed.options)
            local newParsedCompilerOptions = core.NewCompilerOptions()
            local e = unmarshalInto(newParsedCompilerOptions, core.CompilerOptions.Fields, o)
            assert.is_nil(e)
            assertFieldsDeepEqual(tsBaseline.options, newParsedCompilerOptions, core.CompilerOptions.Fields)

            local newParsedWatchOptions = core.NewWatchOptions()
            e = unmarshalInto(newParsedWatchOptions, watchOptionsFields, o)
            assert.is_nil(e)

            -- !!! useful for debugging but will not pass due to `none` as enum options
            -- assert.DeepEqual(t, tsBaseline.watchoptions, newParsedWatchOptions)

            local formattedErrors = core.NewStringBuilder()
            diagnosticwriter.WriteFormatDiagnostics(formattedErrors, diagnosticwriter.FromASTDiagnostics(parsed.errors), { newLine = "\n" })
            local newBaselineErrors = formattedErrors:String()

            -- !!!
            -- useful for debugging--compares the new errors with the old errors. currently will NOT pass because of unimplemented options, not completely identical enum options, etc
            -- assert.Equal(t, tsBaseline.errors, newBaselineErrors)

            baseline.Run(t, f.testName .. ".js", formatNewBaseline(f.commandLine, o, newBaselineFileNames, newBaselineErrors), { subfolder = "tsoptions/commandLineParsing" })
        end)
    end)
end

local function assertBuildParseResultWithTsBaseline(f, getTsBaseline)
    it(f.testName, function()
        runT(function(t)
            local tsBaseline
            if getTsBaseline ~= nil then
                tsBaseline = getTsBaseline(t)
            end

            -- f.workerDiagnostic is either defined or set to default pointer in `createSubScenario`
            local parsed = tsoptions.ParseBuildCommandLine(f.commandLine, setmetatable({
                vfs = osvfs.FS(),
                currentDirectory = tspath.NormalizeSlashes(repo.TypeScriptSubmodulePath()),
            }, tsoptionstest.VfsParseConfigHost))

            local newBaselineProjects = table.concat(parsed.projects, ",")
            if getTsBaseline ~= nil then
                assert.are.equal(tsBaseline.projects, newBaselineProjects)
            end

            local o = json.Marshal(parsed.buildOptions)
            local newParsedBuildOptions = core.NewBuildOptions()
            local e = unmarshalInto(newParsedBuildOptions, buildOptionsFields, o)
            assert.is_nil(e)
            if getTsBaseline ~= nil then
                assertFieldsDeepEqual(tsBaseline.options, newParsedBuildOptions, buildOptionsFields)
            end

            local compilerOpts = json.Marshal(parsed.compilerOptions)
            local newParsedCompilerOptions = core.NewCompilerOptions()
            e = unmarshalInto(newParsedCompilerOptions, core.CompilerOptions.Fields, compilerOpts)
            assert.is_nil(e)
            if getTsBaseline ~= nil then
                assertFieldsDeepEqual(tsBaseline.compilerOptions, newParsedCompilerOptions, core.CompilerOptions.Fields)
            end

            local newParsedWatchOptions = core.NewWatchOptions()
            e = unmarshalInto(newParsedWatchOptions, watchOptionsFields, o)
            assert.is_nil(e)

            -- !!! useful for debugging but will not pass due to `none` as enum options
            -- assert.DeepEqual(t, tsBaseline.watchoptions, newParsedWatchOptions)

            local formattedErrors = core.NewStringBuilder()
            diagnosticwriter.WriteFormatDiagnostics(formattedErrors, diagnosticwriter.FromASTDiagnostics(parsed.errors), { newLine = "\n" })
            local newBaselineErrors = formattedErrors:String()

            -- !!!
            -- useful for debugging--compares the new errors with the old errors. currently will NOT pass because of unimplemented options, not completely identical enum options, etc
            -- assert.Equal(t, tsBaseline.errors, newBaselineErrors)

            baseline.Run(t, f.testName .. ".js", formatNewBaselineBuild(f.commandLine, o, compilerOpts, newBaselineProjects, newBaselineErrors), { subfolder = "tsoptions/commandLineParsing" })
        end)
    end)
end

local function assertBuildParseResult(f)
    assertBuildParseResultWithTsBaseline(f, function(t)
        local originalBaseline = readFixture(t, f.baselinePath)
        return parseExistingCompilerBaselineBuild(t, originalBaseline)
    end)
end

describe("TestCommandLineParseResult", function()
    if not repo.TypeScriptSubmoduleExists() then
        pending("TypeScript submodule does not exist")
        return
    end

    local parseCommandLineSubScenarios = {
        -- --lib es6 0.ts
        { "Parse single option of library flag", { "--lib", "es6", "0.ts" } },
        { "Handles may only be used with --build flags", { "--build", "--clean", "--dry", "--force", "--verbose" } },
        -- --declarations --allowTS
        { "Handles did you mean for misspelt flags", { "--declarations", "--allowTS" } },
        -- --lib es5,es2015.symbol.wellknown 0.ts
        { "Parse multiple options of library flags", { "--lib", "es5,es2015.symbol.wellknown", "0.ts" } },
        -- --lib es5,invalidOption 0.ts
        { "Parse invalid option of library flags", { "--lib", "es5,invalidOption", "0.ts" } },
        -- 0.ts --jsx
        { "Parse empty options of --jsx", { "0.ts", "--jsx" } },
        -- 0.ts --
        { "Parse empty options of --module", { "0.ts", "--module" } },
        -- 0.ts --newLine
        { "Parse empty options of --newLine", { "0.ts", "--newLine" } },
        -- 0.ts --target
        { "Parse empty options of --target", { "0.ts", "--target" } },
        -- 0.ts --moduleResolution
        { "Parse empty options of --moduleResolution", { "0.ts", "--moduleResolution" } },
        -- 0.ts --lib
        { "Parse empty options of --lib", { "0.ts", "--lib" } },
        -- 0.ts --lib
        -- This test is an error because the empty string is falsey
        { "Parse empty string of --lib", { "0.ts", "--lib", "" } },
        -- 0.ts --lib
        { "Parse immediately following command line argument of --lib", { "0.ts", "--lib", "--sourcemap" } },
        -- --lib es5, es7 0.ts
        { "Parse --lib option with extra comma", { "--lib", "es5,", "es7", "0.ts" } },
        -- --lib es5, es7 0.ts
        { "Parse --lib option with trailing white-space", { "--lib", "es5, ", "es7", "0.ts" } },
        -- --lib es5,es2015.symbol.wellknown --target es5 0.ts
        { "Parse multiple compiler flags with input files at the end", { "--lib", "es5,es2015.symbol.wellknown", "--target", "es5", "0.ts" } },
        -- --module commonjs --target es5 0.ts --lib es5,es2015.symbol.wellknown
        { "Parse multiple compiler flags with input files in the middle", { "--module", "commonjs", "--target", "es5", "0.ts", "--lib", "es5,es2015.symbol.wellknown" } },
        -- --module commonjs --target es5 --lib es5 0.ts --library es2015.array,es2015.symbol.wellknown
        { "Parse multiple library compiler flags ", { "--module", "commonjs", "--target", "es5", "--lib", "es5", "0.ts", "--lib", "es2015.core, es2015.symbol.wellknown " } },
        { "Parse explicit boolean flag value", { "--strictNullChecks", "false", "0.ts" } },
        { "Parse non boolean argument after boolean flag", { "--noImplicitAny", "t", "0.ts" } },
        { "Parse implicit boolean flag value", { "--strictNullChecks" } },
        { "parse --incremental", { "--incremental", "0.ts" } },
        { "parse --tsBuildInfoFile", { "--tsBuildInfoFile", "build.tsbuildinfo", "0.ts" } },
        { "allows tsconfig only option to be set to null", { "--composite", "null", "-tsBuildInfoFile", "null", "0.ts" } },

        -- ****** Watch Options ******
        { "parse --watchFile", { "--watchFile", "UseFsEvents", "0.ts" } },
        { "parse --watchDirectory", { "--watchDirectory", "FixedPollingInterval", "0.ts" } },
        { "parse --fallbackPolling", { "--fallbackPolling", "PriorityInterval", "0.ts" } },
        { "parse --synchronousWatchDirectory", { "--synchronousWatchDirectory", "0.ts" } },
        { "errors on missing argument to --fallbackPolling", { "0.ts", "--fallbackPolling" } },
        { "parse --excludeDirectories", { "--excludeDirectories", "**/temp", "0.ts" } },
        { "errors on invalid excludeDirectories", { "--excludeDirectories", "**/../*", "0.ts" } },
        { "parse --excludeFiles", { "--excludeFiles", "**/temp/*.ts", "0.ts" } },
        { "errors on invalid excludeFiles", { "--excludeFiles", "**/../*", "0.ts" } },
    }

    for _, testCase in ipairs(parseCommandLineSubScenarios) do
        assertParseResult(createSubScenario("parseCommandLine", testCase[1], testCase[2]))
    end
end)

describe("TestResponseFileDoesNotPanic", function()
    -- Passing `@` with an empty or relative filename should not panic.
    -- It should produce a diagnostic error instead.
    local cwd
    before_each(function()
        cwd = cwd or tempDir()
    end)

    it("empty response file", function()
        local parsed = ParseCommandLineTestWorker(nil, { "@" }, osvfs.FS(), cwd)
        assert.is_true(#parsed.errors > 0, "expected an error for empty response file name")
    end)

    it("relative response file", function()
        local parsed = ParseCommandLineTestWorker(nil, { "@blah" }, osvfs.FS(), cwd)
        assert.is_true(#parsed.errors > 0, "expected an error for non-existent response file")
    end)
end)

describe("TestResponseFileParsing", function()
    it("final token without trailing whitespace", function()
        local host = tsoptionstest.NewVFSParseConfigHost({
            ["/project/args.txt"] = "--strict --outDir dist",
        }, "/project", true)
        local parsed = tsoptions.ParseCommandLine({ "@args.txt" }, host)
        assert.are.equal(0, core.Len(parsed.errors))
        assert.is_true(core.Tristate_IsTrue(parsed:CompilerOptions().strict))
        assert.are.equal("/project/dist", parsed:CompilerOptions().outDir)
    end)

    it("cyclic response files", function()
        local host = tsoptionstest.NewVFSParseConfigHost({
            ["/project/a.txt"] = "@/project/b.txt --strict",
            ["/project/b.txt"] = "@/project/a.txt --outDir dist",
        }, "/project", true)
        local parsed = tsoptions.ParseCommandLine({ "@a.txt" }, host)
        assert.are.equal(0, core.Len(parsed.errors))
        assert.is_true(core.Tristate_IsTrue(parsed:CompilerOptions().strict))
        assert.are.equal("/project/dist", parsed:CompilerOptions().outDir)
    end)
end)

describe("TestParseCommandLineTypeRootsRelativePath", function()
    it("TestParseCommandLineTypeRootsRelativePath", function()
        local host = tsoptionstest.NewVFSParseConfigHost({
            ["/home/project/bug.ts"] = "let x = 1;",
        }, "/home/project", true)

        local cmdLine = tsoptions.ParseCommandLine({ "--typeRoots", "t", "bug.ts" }, host)

        local typeRoots = cmdLine:CompilerOptions().typeRoots
        assert.is_true(typeRoots ~= nil, "typeRoots should not be nil")
        assert.are.equal(1, #typeRoots)
        assert.is_true(tspath.IsRootedDiskPath(typeRoots[1]), "typeRoots entry should be an absolute path, got: " .. typeRoots[1])
        assert.is_true(string.sub(typeRoots[1], -2) == "/t", "typeRoots entry should end with '/t', got: " .. typeRoots[1])
    end)
end)

describe("TestCustomConditionsNullOverride", function()
    it("TestCustomConditionsNullOverride", function()
        local files = {
            ["/project/tsconfig.json"] = '{\n  "compilerOptions": {\n    "customConditions": ["condition1", "condition2"]\n  }\n}',
            ["/project/index.ts"] = 'console.log("Hello, World!");',
        }

        local host = tsoptionstest.NewVFSParseConfigHost(files, "/project", true)

        -- Parse command line with --customConditions null
        local cmdLine = tsoptions.ParseCommandLine({ "--project", "/project", "--customConditions", "null" }, host)

        -- Check that the raw options contain null for customConditions
        local rawMap = cmdLine.raw
        assert.is_true(rawMap ~= nil and getmetatable(rawMap) == collections.OrderedMap, "Raw options should be an OrderedMap")
        local customConditionsRaw, exists = rawMap:Get("customConditions")
        assert.is_true(exists, "customConditions should exist in raw options")
        assert.is_true(customConditionsRaw == nil, "customConditions should be nil in raw options")

        -- Now parse the config file with the command line options
        -- Wrap command line options in "compilerOptions" key to match tsconfig.json structure
        local wrappedRaw = collections.NewOrderedMap()
        wrappedRaw:Set("compilerOptions", cmdLine.raw)
        local parsedConfig, errors = tsoptions.GetParsedCommandLineOfConfigFile(
            "/project/tsconfig.json",
            cmdLine:CompilerOptions(),
            wrappedRaw,
            host,
            nil
        )

        assert.is_true(core.Len(errors) == 0, "Should not have errors")

        -- Check that customConditions is nil (overridden by command line)
        local customConditions = parsedConfig:CompilerOptions().customConditions
        assert.is_true(customConditions == nil, "customConditions should be nil after override")
    end)
end)

local function createVerifyNullForNonNullIncluded(subScenario, kind, nonNullValue)
    local optDecls = {}
    for i, decl in ipairs(tsoptions.OptionsDeclarations) do
        optDecls[i] = decl
    end
    optDecls[#optDecls + 1] = tsoptions.newCommandLineOption({
        name = "optionName",
        kind = kind,
        isTSConfigOnly = true,
        category = diagnostics.Backwards_Compatibility,
        description = diagnostics.Enable_project_compilation,
        defaultValueDescription = nil,
    })
    return {
        subScenario = subScenario,
        optionName = "optionName",
        nonNullValue = nonNullValue,
        optDecls = optDecls,
    }
end

describe("TestParseCommandLineVerifyNull", function()
    if not repo.TypeScriptSubmoduleExists() then
        pending("TypeScript submodule does not exist")
        return
    end

    -- run test for boolean
    assertParseResult(createSubScenario("parseCommandLine", "allows setting option type boolean to false", { "--composite", "false", "0.ts" }))

    local verifyNullSubScenarios = {
        {
            subScenario = "option of type boolean",
            optionName = "composite",
            nonNullValue = "true",
        },
        {
            subScenario = "option of type object",
            optionName = "paths",
            nonNullValue = "",
        },
        {
            subScenario = "option of type list",
            optionName = "rootDirs",
            nonNullValue = "abc,xyz",
        },
        createVerifyNullForNonNullIncluded("option of type string", CommandLineOptionKind.CommandLineOptionTypeString, "hello"),
        createVerifyNullForNonNullIncluded("option of type number", CommandLineOptionKind.CommandLineOptionTypeNumber, "10"),
        -- todo: make the following work for tests -- currently it is difficult to do extra options of enum type
        -- createVerifyNullForNonNullIncluded("option of type custom map", CommandLineOptionTypeEnum, "node"),
    }

    for _, verifyNullCase in ipairs(verifyNullSubScenarios) do
        assertParseResult(createSubScenario(
            "parseCommandLine",
            verifyNullCase.subScenario .. " allows setting it to null",
            { "--" .. verifyNullCase.optionName, "null", "0.ts" },
            verifyNullCase.optDecls
        ))

        if verifyNullCase.nonNullValue ~= "" then
            assertParseResult(createSubScenario(
                "parseCommandLine",
                verifyNullCase.subScenario .. " errors if non null value is passed",
                { "--" .. verifyNullCase.optionName, verifyNullCase.nonNullValue, "0.ts" },
                verifyNullCase.optDecls
            ))
        end

        assertParseResult(createSubScenario(
            "parseCommandLine",
            verifyNullCase.subScenario .. " errors if its followed by another option",
            { "0.ts", "--strictNullChecks", "--" .. verifyNullCase.optionName },
            verifyNullCase.optDecls
        ))

        assertParseResult(createSubScenario(
            "parseCommandLine",
            verifyNullCase.subScenario .. " errors if its last option",
            { "0.ts", "--" .. verifyNullCase.optionName },
            verifyNullCase.optDecls
        ))
    end
end)

describe("TestParseBuildCommandLine", function()
    if not repo.TypeScriptSubmoduleExists() then
        pending("TypeScript submodule does not exist")
        return
    end

    local parseCommandLineSubScenarios = {
        { "parse build without any options ", {} },
        { "Parse multiple options", { "--verbose", "--force", "tests" } },
        { "Parse option with invalid option", { "--verbose", "--invalidOption" } },
        { "Parse multiple flags with input projects at the end", { "--force", "--verbose", "src", "tests" } },
        { "Parse multiple flags with input projects in the middle", { "--force", "src", "tests", "--verbose" } },
        { "Parse multiple flags with input projects in the beginning", { "src", "tests", "--force", "--verbose" } },
        { "parse build with --incremental", { "--incremental", "tests" } },
        { "parse build with --locale en-us", { "--locale", "en-us", "src" } },
        { "parse build with --tsBuildInfoFile", { "--tsBuildInfoFile", "build.tsbuildinfo", "tests" } },
        { "reports other common may not be used with --build flags", { "--strict" } },
        { "--clean and --force together is invalid", { "--clean", "--force" } },
        { "--clean and --verbose together is invalid", { "--clean", "--verbose" } },
        { "--clean and --watch together is invalid", { "--clean", "--watch" } },
        { "--watch and --dry together is invalid", { "--watch", "--dry" } },
        { "parse --watchFile", { "--watchFile", "UseFsEvents", "--verbose" } },
        { "parse --watchDirectory", { "--watchDirectory", "FixedPollingInterval", "--verbose" } },
        { "parse --fallbackPolling", { "--fallbackPolling", "PriorityInterval", "--verbose" } },
        { "parse --synchronousWatchDirectory", { "--synchronousWatchDirectory", "--verbose" } },
        { "errors on missing argument", { "--verbose", "--fallbackPolling" } },
        { "errors on invalid excludeDirectories", { "--excludeDirectories", "**/../*" } },
        { "parse --excludeFiles", { "--excludeFiles", "**/temp/*.ts" } },
        { "errors on invalid excludeFiles", { "--excludeFiles", "**/../*" } },
    }

    for _, testCase in ipairs(parseCommandLineSubScenarios) do
        assertBuildParseResult(createSubScenario("parseBuildOptions", testCase[1], testCase[2]))
    end

    local extraScenarios = {
        { "parse --builders", { "--builders", "2" } },
        { "--singleThreaded and --builders together", { "--singleThreaded", "--builders", "2" } },
        { "reports error when --builders is 0", { "--builders", "0" } },
        { "reports error when --builders is negative", { "--builders", "-1" } },
        { "reports error when --builders is invalid type", { "--builders", "invalid" } },
    }

    for _, testCase in ipairs(extraScenarios) do
        assertBuildParseResultWithTsBaseline(createSubScenario("parseBuildOptions", testCase[1], testCase[2]), nil)
    end
end)

describe("TestAffectsBuildInfo", function()
    it("should have affectsBuildInfo true for every option with affectsSemanticDiagnostics", function()
        for _, option in ipairs(tsoptions.OptionsDeclarations) do
            if option.affectsSemanticDiagnostics then
                -- semantic diagnostics affect the build info, so ensure they're included
                assert.is_true(option.affectsBuildInfo, option.name)
            end
        end
    end)
end)
