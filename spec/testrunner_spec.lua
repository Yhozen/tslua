-- Tests of the test harness itself (tslua.testrunner, tslua.testutil.*, tslua.diagnosticwriter).
-- The expected values for real test case files were produced by the Go harness
-- (testrunner.ParseTestFilesAndSymlinks, extractCompilerSettings and
-- harnessutil.GetFileBasedTestConfigurations, configurations sorted by name); unit contents are
-- compared by length and a djb2-xor hash.

local ok, loadError = pcall(function()
    require("tslua.testrunner")
    require("tslua.testutil.tsbaseline")
end)

if not ok then
    describe("testrunner", function()
        pending("harness dependencies are not loadable yet: " .. tostring(loadError))
    end)
    return
end

local testrunner = require("tslua.testrunner")
local testutil = require("tslua.testutil")
local harnessutil = require("tslua.testutil.harnessutil")
local baseline = require("tslua.testutil.baseline")
local tsbaseline = require("tslua.testutil.tsbaseline")
local diagnosticwriter = require("tslua.diagnosticwriter")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local repo = require("tslua.repo")
local osvfs = require("tslua.vfs.osvfs")

local expectedCases = {
    {
        file = "testdata/tests/cases/compiler/superCallInJSWithWrongBaseTypeArgumentCount1.ts",
        units = {
            { name = "a.ts", len = 21, hash = 1874962356 },
            { name = "b.js", len = 273, hash = 3489900866 },
        },
        symlinks = {},
        currentDirectory = "",
        globalOptions = {["checkjs"] = "true", ["declaration"] = "true", ["module"] = "nodenext", ["strict"] = "true, false"},
        settings = {["checkjs"] = "true", ["declaration"] = "true", ["filename"] = "b.js", ["module"] = "nodenext", ["strict"] = "true, false"},
        configurations = {
            { name = "strict=false", config = {["checkjs"] = "true", ["declaration"] = "true", ["filename"] = "b.js", ["module"] = "nodenext", ["strict"] = "false"} },
            { name = "strict=true", config = {["checkjs"] = "true", ["declaration"] = "true", ["filename"] = "b.js", ["module"] = "nodenext", ["strict"] = "true"} },
        },
    },
    {
        file = "_submodules/TypeScript/tests/cases/compiler/commonJsIsolatedModules.ts",
        units = {
            { name = "tsconfig.json", len = 102, hash = 1855755363 },
            { name = "index.js", len = 30, hash = 1193616556 },
        },
        symlinks = {},
        currentDirectory = "",
        globalOptions = {["target"] = "es2015"},
        settings = {["filename"] = "index.js", ["target"] = "es2015"},
        configurations = {
            { name = "", config = {["filename"] = "index.js", ["target"] = "es2015"} },
        },
    },
    {
        file = "_submodules/TypeScript/tests/cases/compiler/moduleResolutionWithSymlinks.ts",
        units = {
            { name = "/src/library-a/index.ts", len = 44, hash = 1830874542 },
            { name = "/src/library-b/index.ts", len = 66, hash = 2190850008 },
            { name = "/src/app.ts", len = 806, hash = 1031223240 },
        },
        symlinks = {["/src/library-b/node_modules/library-a/index.ts"] = "/src/library-a/index.ts"},
        currentDirectory = "",
        globalOptions = {["fullemitpaths"] = "true", ["module"] = "commonjs", ["noimplicitreferences"] = "true", ["target"] = "es2015", ["traceresolution"] = "true"},
        settings = {["filename"] = "/src/app.ts", ["fullemitpaths"] = "true", ["module"] = "commonjs", ["noimplicitreferences"] = "true", ["symlink"] = "/src/library-b/node_modules/library-a/index.ts", ["target"] = "es2015", ["traceresolution"] = "true"},
        configurations = {
            { name = "", config = {["filename"] = "/src/app.ts", ["fullemitpaths"] = "true", ["module"] = "commonjs", ["noimplicitreferences"] = "true", ["symlink"] = "/src/library-b/node_modules/library-a/index.ts", ["target"] = "es2015", ["traceresolution"] = "true"} },
        },
    },
    {
        file = "_submodules/TypeScript/tests/cases/compiler/declarationEmitSymlinkPaths.ts",
        units = {
            { name = "/packages/search/package.json", len = 133, hash = 2830276461 },
            { name = "/packages/search/lib/index.d.ts", len = 54, hash = 3455144672 },
            { name = "/packages/search-prefix/src/API/NotificationAPIUtils.ts", len = 149, hash = 141904462 },
            { name = "/packages/search-prefix/src/Store/NotificationStore.ts", len = 167, hash = 3763554599 },
        },
        symlinks = {["/node_modules/search"] = "/packages/search", ["/node_modules/search-prefix"] = "/packages/search-prefix"},
        currentDirectory = "",
        globalOptions = {["declaration"] = "true", ["module"] = "commonjs", ["outdir"] = "/packages/search-prefix/lib", ["rootdir"] = "/packages/search-prefix/src", ["target"] = "es5, es2015"},
        settings = {["declaration"] = "true", ["filename"] = "/packages/search-prefix/src/Store/NotificationStore.ts", ["link"] = "/packages/search-prefix -> /node_modules/search-prefix", ["module"] = "commonjs", ["outdir"] = "/packages/search-prefix/lib", ["rootdir"] = "/packages/search-prefix/src", ["target"] = "es5, es2015"},
        configurations = {
            { name = "target=es2015", config = {["declaration"] = "true", ["filename"] = "/packages/search-prefix/src/Store/NotificationStore.ts", ["link"] = "/packages/search-prefix -> /node_modules/search-prefix", ["module"] = "commonjs", ["outdir"] = "/packages/search-prefix/lib", ["rootdir"] = "/packages/search-prefix/src", ["target"] = "es2015"} },
            { name = "target=es5", config = {["declaration"] = "true", ["filename"] = "/packages/search-prefix/src/Store/NotificationStore.ts", ["link"] = "/packages/search-prefix -> /node_modules/search-prefix", ["module"] = "commonjs", ["outdir"] = "/packages/search-prefix/lib", ["rootdir"] = "/packages/search-prefix/src", ["target"] = "es5"} },
        },
    },
    {
        file = "_submodules/TypeScript/tests/cases/conformance/expressions/optionalChaining/callChain/callChainWithSuper.ts",
        units = {
            { name = "callChainWithSuper.ts", len = 159, hash = 1549489966 },
        },
        symlinks = {},
        currentDirectory = "",
        globalOptions = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "*,-es3"},
        settings = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "*,-es3"},
        configurations = {
            { name = "target=es2016", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2016"} },
            { name = "target=es2017", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2017"} },
            { name = "target=es2018", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2018"} },
            { name = "target=es2019", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2019"} },
            { name = "target=es2020", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2020"} },
            { name = "target=es2021", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2021"} },
            { name = "target=es2022", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2022"} },
            { name = "target=es2023", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2023"} },
            { name = "target=es2024", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2024"} },
            { name = "target=es2025", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es2025"} },
            { name = "target=es5", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es5"} },
            { name = "target=es6", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "es6"} },
            { name = "target=esnext", config = {["notypesandsymbols"] = "true", ["strict"] = "true", ["target"] = "esnext"} },
        },
    },
    {
        file = "_submodules/TypeScript/tests/cases/compiler/declarationEmitForGlobalishSpecifierSymlink.ts",
        units = {
            { name = "/p1/node_modules/typescript-fsa/src/impl.d.ts", len = 52, hash = 869175796 },
            { name = "/p1/node_modules/typescript-fsa/index.d.ts", len = 27, hash = 330658418 },
            { name = "/p1/node_modules/typescript-fsa/package.json", len = 56, hash = 3989519975 },
            { name = "/p2/node_modules/typescript-fsa/src/impl.d.ts", len = 52, hash = 869175796 },
            { name = "/p2/node_modules/typescript-fsa/index.d.ts", len = 27, hash = 330658418 },
            { name = "/p2/node_modules/typescript-fsa/package.json", len = 56, hash = 3989519975 },
            { name = "/p1/index.ts", len = 97, hash = 1414399723 },
            { name = "/p2/index.d.ts", len = 45, hash = 1279973753 },
        },
        symlinks = {["/p1/node_modules/p2"] = "/p2"},
        currentDirectory = "",
        globalOptions = {["declaration"] = "true", ["module"] = "commonjs", ["target"] = "es2015", ["usecasesensitivefilenames"] = "true"},
        settings = {["declaration"] = "true", ["filename"] = "/p2/index.d.ts", ["link"] = "/p2 -> /p1/node_modules/p2", ["module"] = "commonjs", ["target"] = "es2015", ["usecasesensitivefilenames"] = "true"},
        configurations = {
            { name = "", config = {["declaration"] = "true", ["filename"] = "/p2/index.d.ts", ["link"] = "/p2 -> /p1/node_modules/p2", ["module"] = "commonjs", ["target"] = "es2015", ["usecasesensitivefilenames"] = "true"} },
        },
    },
    {
        file = "testdata/tests/cases/compiler/settingsSimpleTest.ts",
        units = {
            { name = "settingsSimpleTest.ts", len = 39, hash = 3576387000 },
        },
        symlinks = {},
        currentDirectory = "",
        globalOptions = {["declaration"] = "true;", ["moduleresolution"] = "classic", ["strict"] = "*", ["strictbuiltiniteratorreturn"] = "*, !true", ["target"] = "es2020"},
        settings = {["declaration"] = "true", ["moduleresolution"] = "classic", ["strict"] = "*", ["strictbuiltiniteratorreturn"] = "*, !true", ["target"] = "es2020"},
        configurations = {
            { name = "strict=false", config = {["declaration"] = "true", ["moduleresolution"] = "classic", ["strict"] = "false", ["strictbuiltiniteratorreturn"] = "false", ["target"] = "es2020"} },
            { name = "strict=true", config = {["declaration"] = "true", ["moduleresolution"] = "classic", ["strict"] = "true", ["strictbuiltiniteratorreturn"] = "false", ["target"] = "es2020"} },
        },
    },
}

local function djb2xor(s)
    local x = 5381
    for i = 1, #s do
        x = ((x * 33) ~ string.byte(s, i)) & 0xFFFFFFFF
    end
    return x
end

local function parseUnits(content, fileName)
    return testrunner.ParseTestFilesAndSymlinks(content, fileName, function(filename, unitContent)
        return { name = filename, content = unitContent }, nil
    end)
end

describe("test case parser", function()
    it("splits @filename units (TestMakeUnitsFromTest)", function()
        local code = table.concat({
            "// @strict: true",
            "// @noEmit: true",
            "// @filename: firstFile.ts",
            "function foo() { return \"a\"; }",
            "// normal comment",
            "// @filename: secondFile.ts",
            "// some other comment",
            "function bar() { return \"b\"; }",
        }, "\n")
        local content = testrunner.makeUnitsFromTest(code, "simpleTest.ts")
        assert.are.same({
            { content = "function foo() { return \"a\"; }\n// normal comment", name = "firstFile.ts" },
            { content = "// some other comment\nfunction bar() { return \"b\"; }", name = "secondFile.ts" },
        }, content.testUnitData)
        assert.is_nil(content.tsConfig)
        assert.is_nil(content.tsConfigFileUnitData)
        assert.are.same({}, content.symlinks)
    end)

    it("names a single unit after the file and drops leading blank lines", function()
        local units, symlinks, cwd, globals = parseUnits("// @target: es5\r\n\r\nlet x = 1;\r\nlet y = 2;", "/a/b/single.ts")
        assert.are.same({ { name = "single.ts", content = "let x = 1;\nlet y = 2;" } }, units)
        assert.are.same({}, symlinks)
        assert.are.equal("", cwd)
        assert.are.same({ target = "es5" }, globals)
    end)

    it("rejects code before the first @filename", function()
        assert.has_error(function()
            parseUnits("let x = 1;\n// @filename: a.ts\nlet y;", "t.ts")
        end, "Non-comment test content appears before the first '// @Filename' directive")
    end)

    it("parses @link and @symlink directives", function()
        local units, symlinks = parseUnits(table.concat({
            "// @filename: /a/index.ts",
            "// @symlink: /b/node_modules/a/index.ts, /c/index.ts",
            "export {};",
            "// @link: /packages/search -> /node_modules/search",
            "// @filename: /b/index.ts",
            "import {} from 'a';",
        }, "\n"), "t.ts")
        assert.are.equal(2, #units)
        assert.are.same({
            ["/b/node_modules/a/index.ts"] = "/a/index.ts",
            ["/c/index.ts"] = "/a/index.ts",
            ["/node_modules/search"] = "/packages/search",
        }, symlinks)
    end)

    it("extracts compiler settings like the Go regexp", function()
        local settings = testrunner.extractCompilerSettings(table.concat({
            "// @Target: ES5, ES2015;",
            "//@strict:true",
            "  // @notAtLineStart: x",
            "// @lib: es2015,  dom  ",
            "/// @tripleSlash: y",
        }, "\n"))
        assert.are.same({ target = "ES5, ES2015", strict = "true", lib = "es2015,  dom" }, settings)
        -- `\s*` after the colon may cross a line break, like RE2
        assert.are.same({ foo = "bar" }, testrunner.extractCompilerSettings("// @foo:\n  bar"))
    end)

    for _, expected in ipairs(expectedCases) do
        it("matches the Go harness for " .. expected.file, function()
            local path = repo.RootPath() .. "/" .. expected.file
            local content, readOk = osvfs.FS():ReadFile(path)
            assert.is_true(readOk)
            local units, symlinks, cwd, globals = parseUnits(content, path)
            local got = {}
            for i, u in ipairs(units) do
                got[i] = { name = u.name, len = #u.content, hash = djb2xor(u.content) }
            end
            assert.are.same(expected.units, got)
            assert.are.same(expected.symlinks, symlinks)
            assert.are.equal(expected.currentDirectory, cwd)
            assert.are.same(expected.globalOptions, globals)

            local settings = testrunner.extractCompilerSettings(content)
            assert.are.same(expected.settings, settings)

            local t = testutil.NewT("config", nil)
            local configurations = harnessutil.GetFileBasedTestConfigurations(t, settings, testrunner.compilerVaryBy())
            assert.is_false(t.failed)
            table.sort(configurations, function(a, b) return a.name < b.name end)
            assert.are.same(expected.configurations, configurations)
        end)
    end
end)

describe("file based test configurations", function()
    local function names(settings)
        local t = testutil.NewT("config", nil)
        local configs = harnessutil.GetFileBasedTestConfigurations(t, settings, testrunner.compilerVaryBy())
        local out = {}
        for i, c in ipairs(configs) do
            out[i] = c.name
        end
        table.sort(out)
        return out, configs, t
    end

    it("varies boolean and enum options and combines them", function()
        local got, configs = names({ strict = "true, false", module = "commonjs, esnext", lib = "es5" })
        assert.are.same({
            "module=commonjs,strict=false", "module=commonjs,strict=true",
            "module=esnext,strict=false", "module=esnext,strict=true",
        }, got)
        for _, c in ipairs(configs) do
            assert.are.equal("es5", c.config.lib)
        end
    end)

    it("handles *, exclusions and duplicates", function()
        -- a single remaining value is not a variation
        assert.are.same({ "" }, (names({ strict = "*, -true" })))
        assert.are.same({ "strict=false", "strict=true" }, (names({ strict = "*" })))
        -- es6 and es2015 are the same value; the first spelling wins
        assert.are.same({ "target=es2015", "target=es5" }, (names({ target = "es2015, es6, es5" })))
        -- an unknown excluded value is ignored
        assert.are.same({ "" }, (names({ target = "es5, -es3" })))
    end)

    it("does not vary options that do not support variations", function()
        local got, configs = names({ outdir = "a, b" })
        assert.are.same({ "" }, got)
        assert.are.equal("a, b", configs[1].config.outdir)
        assert.are.same({}, (names({})))
    end)

    it("limits the number of variations", function()
        local t = testutil.NewT("config", nil)
        testutil.runProtected(t, function(t1)
            harnessutil.GetFileBasedTestConfigurations(t1, { target = "*", strict = "*", module = "*" }, testrunner.compilerVaryBy())
        end)
        assert.is_true(t.failed)
        assert.are.equal("Provided test options exceeded the maximum number of variations", t.messages[1])
    end)
end)

describe("harness options", function()
    it("parses compiler and harness options from a test configuration", function()
        local t = testutil.NewT("options", nil)
        local options = core.NewCompilerOptions()
        local harnessOptions = harnessutil.NewHarnessOptions()
        harnessutil.SetOptionsFromTestConfig(t, {
            strict = "true",
            target = "es2015",
            outdir = "out",
            notypesandsymbols = "true",
            libfiles = "react.d.ts,lib.d.ts",
            nocheck = "true",
            typescriptversion = "5.0",
        }, options, harnessOptions, "/.src", false)
        assert.is_false(t.failed)
        assert.are.equal(core.Tristate.TSTrue, options.strict)
        assert.are.equal(core.ScriptTarget.ES2015, options.target)
        assert.are.equal("/.src/out", options.outDir)
        assert.are.equal(core.Tristate.TSTrue, options.noCheck)
        assert.is_true(harnessOptions.noTypesAndSymbols)
        assert.are.same({ "react.d.ts", "lib.d.ts" }, harnessOptions.libFiles)
    end)

    it("fails on unknown options", function()
        local t = testutil.NewT("options", nil)
        testutil.runProtected(t, function(t1)
            harnessutil.SetOptionsFromTestConfig(t1, { notanoption = "1" }, core.NewCompilerOptions(), harnessutil.NewHarnessOptions(), "/", false)
        end)
        assert.is_true(t.failed)
        assert.are.equal("Unknown compiler option 'notanoption'.", t.messages[1])
    end)
end)

describe("testing.T stand-in", function()
    it("records failures, skips and panics per subtest", function()
        local root = testutil.NewT("", nil)
        local order = {}
        root:Run("a", function(t)
            order[#order + 1] = "a"
            t:Errorf("x=%d %s", 1, "y")
            order[#order + 1] = "a2"
        end)
        root:Run("b", function(t)
            t:Skip("not supported")
            order[#order + 1] = "unreachable"
        end)
        root:Run("c", function(t)
            t:Fatalf("fatal %v", "z")
            order[#order + 1] = "unreachable"
        end)
        root:Run("d", function(t)
            testutil.RecoverAndFail(t, "Panic on d", function()
                error("boom")
            end)
        end)
        assert.are.same({ "a", "a2" }, order)
        assert.is_true(root.children[1].failed)
        assert.are.same({ "x=1 y" }, root.children[1].messages)
        assert.is_true(root.children[2].skipped)
        assert.is_false(root.children[2].failed)
        assert.is_true(root.children[3].failed)
        assert.is_true(root.children[4].failed)
        assert.is_not_nil(root.children[4].panicked)
        assert.truthy(string.find(root.children[4].messages[1], "Panic on d:\n", 1, true))
        assert.is_true(root.failed)
        assert.are.equal("d", root.children[4]:Name())
    end)
end)

describe("baseline", function()
    it("diffs like peter-evans/patience with skipped line numbers", function()
        local t = testutil.NewT("", nil)
        local diff = baseline.getBaselineDiff(t, "a\nB\nc\nd\ne\nf\ng\nh\ni\nJ\nk", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk", "x.types", nil, nil)
        assert.are.equal(table.concat({
            "--- old.x.types",
            "+++ new.x.types",
            "@@= skipped -0, +0 lines =@@",
            " a",
            "-b",
            "+B",
            " c",
            " d",
            " e",
            "@@= skipped -6, +6 lines =@@",
            " g",
            " h",
            " i",
            "-j",
            "+J",
            " k",
        }, "\n"), diff)
        assert.are.equal(baseline.NoContent, baseline.getBaselineDiff(t, "same", "same", "x", nil, nil))
        assert.are.equal(baseline.NoContent, baseline.getBaselineDiff(t, "a\r\nb", "a\nb", "x", function(old)
            return (string.gsub(old, "\n", "\r\n"))
        end, nil))
    end)

    it("writes local baselines only when they differ from the reference", function()
        local dir = os.tmpname()
        os.remove(dir)
        local reference = dir .. "/reference/a.errors.txt"
        local localPath = dir .. "/local/a.errors.txt"
        osvfs.FS():WriteFile(reference, "expected")

        local t = testutil.NewT("", nil)
        baseline.writeComparison(t, "expected", localPath, reference, false)
        assert.is_false(t.failed)
        assert.is_false(osvfs.FS():FileExists(localPath))

        baseline.writeComparison(t, "actual", localPath, reference, false)
        assert.is_true(t.failed)
        assert.are.equal("actual", (osvfs.FS():ReadFile(localPath)))
        assert.are.equal("expected", (osvfs.FS():ReadFile(reference)))

        t = testutil.NewT("", nil)
        baseline.writeComparison(t, baseline.NoContent, localPath, reference, false)
        assert.is_true(t.failed)
        assert.is_true(osvfs.FS():FileExists(localPath .. ".delete"))

        t = testutil.NewT("", nil)
        baseline.writeComparison(t, baseline.NoContent, dir .. "/local/b.types", dir .. "/reference/b.types", false)
        assert.is_false(t.failed)

        t = testutil.NewT("", nil)
        baseline.writeComparison(t, "new", dir .. "/local/c.types", dir .. "/reference/c.types", false)
        assert.is_true(t.failed)
        assert.truthy(string.find(t.messages[1], "new baseline created at", 1, true))

        assert.has_error(function()
            baseline.writeComparison(t, "", localPath, reference, false)
        end)
        osvfs.FS():Remove(dir)
    end)

    it("knows the reference roots", function()
        assert.truthy(string.find(baseline.referenceRoot(), "/testdata/baselines/reference$"))
        assert.truthy(string.find(baseline.submoduleReferenceRoot(), "/_submodules/TypeScript/tests/baselines/reference$"))
        assert.truthy(string.find(baseline.localRoot(), "/tests/out$") or os.getenv("TSLUA_TEST_OUT"))
        assert.is_true(baseline.submoduleTriagedFileNames() ~= nil)
    end)
end)

describe("tsbaseline helpers", function()
    it("replaces lib locations like the Go regexps", function()
        local text = "lib.es5.d.ts(12,3): error TS1: x\r\nfoo.ts(1,1): error\r\nLIB.dom.d.ts(1,2): lib.d.ts(3,4)\r\n"
        assert.are.equal("lib.es5.d.ts(--,--): error TS1: x\r\nfoo.ts(1,1): error\r\nLIB.dom.d.ts(1,2): lib.d.ts(--,--)\r\n",
            tsbaseline.diagnosticsLocationPrefix:ReplaceAllString(text, "$1(--,--)"))
        assert.are.equal(" lib.es5.d.ts:--:--", tsbaseline.diagnosticsLocationPattern:ReplaceAllString(" lib.es5.d.ts:12:3", "$1:--:--"))
    end)

    it("removes test path prefixes in target order", function()
        assert.are.equal("a.ts lib.d.ts file:///x b", tsbaseline.removeTestPathPrefixes("/.src/a.ts bundled:///libs/lib.d.ts file:///./src/x /.lib/b", false))
        assert.are.equal("/a.ts /lib.d.ts", tsbaseline.removeTestPathPrefixes("/.src/a.ts bundled:///libs/lib.d.ts", true))
    end)

    it("splits code lines like codeLinesRegexp", function()
        assert.are.same({ "a", "", "b", "c", "d" }, tsbaseline.codeLinesRegexp:Split("a\r\nb\nc\u{2028}d", -1))
        assert.are.same({ "a", "b", "" }, tsbaseline.lineDelimiter:Split("a\r\nb\n", -1))
        assert.are.equal("  \t ", tsbaseline.nonWhitespace:ReplaceAllString("ab\té", " "))
        assert.is_true(tsbaseline.bracketLineRegex:MatchString("  } "))
        assert.is_false(tsbaseline.bracketLineRegex:MatchString("};"))
        assert.are.equal("foo.errors.txt", tsbaseline.tsExtension:ReplaceAllString("foo.tsx", ".errors.txt"))
        assert.are.equal("a_b/__dotdot/c", tsbaseline.sanitizeTestFilePath("/A:B/../c"))
    end)
end)

describe("diagnosticwriter", function()
    -- Minimal FileLike and Diagnostic implementations.
    local function fakeFile(name, text)
        return {
            FileName = function() return name end,
            Text = function() return text end,
            ECMALineMap = function() return core.ComputeECMALineStarts(text) end,
        }
    end

    local function fakeDiagnostic(file, pos, len, message, chain)
        return {
            File = function() return file end,
            Pos = function() return pos end,
            End = function() return pos + len end,
            Len = function() return len end,
            Code = function() return message:Code() end,
            Category = function() return message:Category() end,
            Source = function() return "" end,
            Localize = function(_, locale) return message:Localize(locale, "x") end,
            MessageChain = function() return chain or {} end,
            RelatedInformation = function() return {} end,
        }
    end

    it("writes tsc-style diagnostics", function()
        local file = fakeFile("/.src/a.ts", "let a = 1;\nlet b = x;\n")
        local chained = fakeDiagnostic(nil, 0, 0, diagnostics.Cannot_find_name_0)
        local d = fakeDiagnostic(file, 19, 1, diagnostics.Cannot_find_name_0, { chained })
        local out = core.NewStringBuilder()
        diagnosticwriter.WriteFormatDiagnostics(out, { d }, { newLine = "\r\n", currentDirectory = "", useCaseSensitiveFileNames = false })
        assert.are.equal("/.src/a.ts(2,9): error TS2304: Cannot find name 'x'.\r\n  Cannot find name 'x'.\r\n", out:String())
    end)

    it("writes pretty diagnostics with a code snippet", function()
        local file = fakeFile("a.ts", "let a = 1;\nlet b = x;\n")
        local d = fakeDiagnostic(file, 19, 1, diagnostics.Cannot_find_name_0)
        local out = core.NewStringBuilder()
        diagnosticwriter.FormatDiagnosticsWithColorAndContext(out, { d }, { newLine = "\n", currentDirectory = "", useCaseSensitiveFileNames = false })
        local plain = string.gsub(out:String(), "\27%[[0-9;]*m", "")
        assert.are.equal("a.ts:2:9 - error TS2304: Cannot find name 'x'.\n\n2 let b = x;\n          ~\n", plain)

        local summary = core.NewStringBuilder()
        diagnosticwriter.WriteErrorSummaryText(summary, { d, d }, { newLine = "\n", currentDirectory = "", useCaseSensitiveFileNames = false })
        local plainSummary = string.gsub(summary:String(), "\27%[[0-9;]*m", "")
        assert.are.equal("\nFound 2 errors in the same file, starting at: a.ts:2\n\n", plainSummary)
    end)
end)
