local testrunner = require("tslua.testrunner")
local ast = require("tslua.ast")
local baseline = require("tslua.testutil.baseline")
local checker = require("tslua.checker")
local core = require("tslua.core")
local harnessutil = require("tslua.testutil.harnessutil")
local repo = require("tslua.repo")
local testutil = require("tslua.testutil")
local tsbaseline = require("tslua.testutil.tsbaseline")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local osvfs = require("tslua.vfs.osvfs")

local CompilerTestType = testrunner.CompilerTestType

-- compilerBaselineRegex = regexp.MustCompile(`\.tsx?$`)
testrunner.compilerBaselineRegex = {
    MatchString = function(self, s)
        return string.sub(s, -3) == ".ts" or string.sub(s, -4) == ".tsx"
    end,
}
testrunner.requireStr = "require("
-- referencesRegex = regexp.MustCompile(`reference\spath`)
testrunner.referencesRegex = {
    MatchString = function(self, s)
        return string.find(s, "reference[\t\n\f\r ]path") ~= nil
    end,
}

-- Posix-style path to sources under test
testrunner.srcFolder = "/.src"

function testrunner.CompilerTestType_String(t)
    if t == CompilerTestType.TestTypeRegression then
        return "compiler"
    end
    return "conformance"
end

-- CompilerBaselineRunner: { isSubmodule, testFiles, basePath, testSuitName }
--
-- Lua-only field: enabledBaselines, nil (everything, like Go) or a set of the verification steps
-- to run: "errors", "contentmapper", "js", "sourcemap", "sourcemaprecord", "types", "symbols",
-- "moduleresolution", "unionordering", "parentpointers".
local CompilerBaselineRunner = {}
CompilerBaselineRunner.__index = CompilerBaselineRunner
testrunner.CompilerBaselineRunner = CompilerBaselineRunner

function testrunner.NewCompilerBaselineRunner(testType, isSubmodule)
    local testSuitName = testrunner.CompilerTestType_String(testType)
    local basePath
    if isSubmodule then
        basePath = "../_submodules/TypeScript/tests/cases/" .. testSuitName
    else
        basePath = "tests/cases/" .. testSuitName
    end
    return setmetatable({
        basePath = basePath,
        testSuitName = testSuitName,
        isSubmodule = isSubmodule,
        testFiles = nil,
        enabledBaselines = nil,
    }, CompilerBaselineRunner)
end

function CompilerBaselineRunner:enabled(kind)
    return self.enabledBaselines == nil or self.enabledBaselines[kind] == true
end

function CompilerBaselineRunner:EnumerateTestFiles()
    if core.Len(self.testFiles) > 0 then
        return self.testFiles
    end
    local files, err = harnessutil.EnumerateFiles(self.basePath, testrunner.compilerBaselineRegex, true --[[recursive]])
    if err ~= nil then
        error("Could not read compiler test files: " .. tostring(type(err) == "table" and err:Error() or err), 0)
    end
    self.testFiles = files
    return files
end

testrunner.skippedTests = {
    -- Tests that depended on typescript.d.ts in built.
    "APILibCheck.ts",
    "APISample_Watch.ts",
    "APISample_WatchWithDefaults.ts",
    "APISample_WatchWithOwnWatchHost.ts",
    "APISample_compile.ts",
    "APISample_jsdoc.ts",
    "APISample_linter.ts",
    "APISample_parseConfig.ts",
    "APISample_transform.ts",
    "APISample_watcher.ts",

    -- These tests contain options that have been completely removed, so fail to parse.
    "preserveUnusedImports.ts",
    "noCrashWithVerbatimModuleSyntaxAndImportsNotUsedAsValues.ts",
    "verbatimModuleSyntaxCompat.ts",
    "verbatimModuleSyntaxCompat2.ts",
    "verbatimModuleSyntaxCompat3.ts",
    "verbatimModuleSyntaxCompat4.ts",
    "preserveValueImports.ts",
    "preserveValueImports_importsNotUsedAsValues.ts",
    "preserveValueImports_errors.ts",
    "preserveValueImports_mixedImports.ts",
    "preserveValueImports_module.ts",
    "importsNotUsedAsValues_error.ts",
    "alwaysStrictNoImplicitUseStrict.ts",
    "nonPrimitiveIndexingWithForInSupressError.ts",
    "parameterInitializerBeforeDestructuringEmit.ts",
    "mappedTypeUnionConstraintInferences.ts",
    "lateBoundConstraintTypeChecksCorrectly.ts",
    "keyofDoesntContainSymbols.ts",
    "isolatedModulesOut.ts",
    "noStrictGenericChecks.ts",
    "noImplicitUseStrict_umd.ts",
    "noImplicitUseStrict_system.ts",
    "noImplicitUseStrict_es6.ts",
    "noImplicitUseStrict_commonjs.ts",
    "noImplicitUseStrict_amd.ts",
    "noImplicitAnyIndexingSuppressed.ts",
    "excessPropertyErrorsSuppressed.ts",
    "moduleNoneDynamicImport.ts",
    "moduleNoneErrors.ts",
    "moduleNoneOutFile.ts",
    "noErrorUsingImportExportModuleAugmentationInDeclarationFile1.ts",
    "noErrorUsingImportExportModuleAugmentationInDeclarationFile2.ts",
    "noErrorUsingImportExportModuleAugmentationInDeclarationFile3.ts",
    "requireOfJsonFileWithModuleEmitNone.ts",
    "requireOfJsonFileWithModuleNodeResolutionEmitNone.ts",
}

local function contains(xs, x)
    for _, v in ipairs(xs) do
        if v == x then
            return true
        end
    end
    return false
end

function testrunner.IsSkippedTest(filename)
    return contains(testrunner.skippedTests, tspath.GetBaseFileName(filename))
end

function CompilerBaselineRunner:RunTests(t)
    self:cleanUpLocal(t)
    local files = self:EnumerateTestFiles()

    for _, filename in ipairs(files) do
        if contains(testrunner.skippedTests, tspath.GetBaseFileName(filename)) then
            goto continue
        end
        self:runTest(t, filename)
        ::continue::
    end
end

-- Go: filepath.Join(repo.TestDataPath(), "baselines", "local"); the Lua port writes local
-- baselines to baseline.localRoot() (tests/out).
function testrunner.localBasePath()
    return baseline.localRoot()
end

function CompilerBaselineRunner:cleanUpLocal(t)
    local localPath = baseline.join(testrunner.localBasePath(), core.IfElse(self.isSubmodule, "diff", ""), self.testSuitName)
    local err = osvfs.FS():Remove(localPath)
    if err ~= nil then
        error("Could not clean up local compiler tests: " .. err:Error(), 0)
    end
end

-- Set of compiler options for which we allow variations to be specified in the test file,
-- for instance `// @strict: true, false`.
local compilerVaryByValue = nil

function testrunner.compilerVaryBy()
    if compilerVaryByValue == nil then
        compilerVaryByValue = testrunner.getCompilerVaryByMap()
    end
    return compilerVaryByValue
end

function testrunner.getCompilerVaryByMap()
    local Kind = tsoptions.CommandLineOptionKind
    local varyByOptions = core.Map(core.Filter(tsoptions.OptionsDeclarations, function(option)
        return not option.isCommandLineOnly and
            (option.kind == Kind.CommandLineOptionTypeBoolean or option.kind == Kind.CommandLineOptionTypeEnum) and
            (option.affectsProgramStructure or
                option.affectsEmit or
                option.affectsModuleResolution or
                option.affectsBindDiagnostics or
                option.affectsSemanticDiagnostics or
                option.affectsSourceFile or
                option.affectsDeclarationPath or
                option.affectsBuildInfo)
    end), function(option)
        return option.name
    end)
    -- explicit variations that do not match above conditions
    varyByOptions[#varyByOptions + 1] = "noEmit"
    varyByOptions[#varyByOptions + 1] = "isolatedModules"
    local varyByMap = {}
    for _, option in ipairs(varyByOptions) do
        varyByMap[string.lower(option)] = true
    end
    return varyByMap
end

function CompilerBaselineRunner:runTest(t, filename)
    local test = testrunner.getCompilerFileBasedTest(t, filename)
    local basename = tspath.GetBaseFileName(filename)
    if #test.configurations > 0 then
        for _, config in ipairs(test.configurations) do
            local testName = basename
            if config.name ~= "" then
                testName = testName .. " " .. config.name
            end
            t:Run(testName, function(t1)
                self:runSingleConfigTest(t1, testName, test, config)
            end)
        end
    else
        t:Run(basename, function(t1)
            self:runSingleConfigTest(t1, basename, test, nil)
        end)
    end
end

function CompilerBaselineRunner:runSingleConfigTest(t, testName, test, config)
    t:Parallel()
    testutil.RecoverAndFail(t, "Panic on compiling test " .. test.filename, function()
        local payload = testrunner.makeUnitsFromTest(test.content, test.filename)
        local compilerTest = testrunner.newCompilerTest(t, testName, test.filename, payload, config)

        harnessutil.SkipUnsupportedCompilerOptions(t, compilerTest.options)

        if self:enabled("errors") then
            compilerTest:verifyDiagnostics(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("contentmapper") then
            compilerTest:verifyContentMapper(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("js") then
            compilerTest:verifyJavaScriptOutput(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("sourcemap") then
            compilerTest:verifySourceMapOutput(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("sourcemaprecord") then
            compilerTest:verifySourceMapRecord(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("types") or self:enabled("symbols") then
            compilerTest:verifyTypesAndSymbols(t, self.testSuitName, self.isSubmodule, not self:enabled("types"), not self:enabled("symbols"))
        end
        if self:enabled("moduleresolution") then
            compilerTest:verifyModuleResolution(t, self.testSuitName, self.isSubmodule)
        end
        if self:enabled("unionordering") then
            compilerTest:verifyUnionOrdering(t)
        end
        if self:enabled("parentpointers") then
            compilerTest:verifyParentPointers(t)
        end
    end)
end

-- compilerFileBasedTest: { filename, content, configurations = []NamedTestConfiguration }

function testrunner.getCompilerFileBasedTest(t, filename)
    local content, ok = osvfs.FS():ReadFile(filename)
    if not ok then
        error("Could not read test file: " .. filename, 0)
    end
    local settings = testrunner.extractCompilerSettings(content)
    local configurations = harnessutil.GetFileBasedTestConfigurations(t, settings, testrunner.compilerVaryBy())
    return {
        filename = filename,
        content = content,
        configurations = configurations,
    }
end

-- compilerTest: { testName, filename, basename, configuredName (name with configuration
-- description, e.g. `file`), currentDirectory, options, harnessOptions, result, tsConfigFiles,
-- toBeCompiled (equivalent to the files that will be passed on the command line), otherFiles
-- (equivalent to other files on the file system not directly passed to the compiler (ie things
-- that are referenced by other files)), hasNonDtsFiles }
local compilerTest = {}
compilerTest.__index = compilerTest
testrunner.compilerTest = compilerTest

-- testCaseContentWithConfig: testCaseContent + configuration (harnessutil.TestConfiguration)

function testrunner.newCompilerTest(t, testName, filename, testContent, namedConfiguration)
    local basename = tspath.GetBaseFileName(filename)
    local configuredName = basename
    if namedConfiguration ~= nil and namedConfiguration.name ~= "" then
        local extname = tspath.GetAnyExtensionFromPath(basename, nil, false)
        local extensionlessBasename = string.sub(basename, 1, #basename - #extname)
        configuredName = extensionlessBasename .. "(" .. namedConfiguration.name .. ")" .. extname
    end

    local configuration = nil
    if namedConfiguration ~= nil then
        configuration = namedConfiguration.config
    end
    local testCaseContentWithConfig = {
        testUnitData = testContent.testUnitData,
        tsConfig = testContent.tsConfig,
        tsConfigFileUnitData = testContent.tsConfigFileUnitData,
        symlinks = testContent.symlinks,
        configuration = configuration,
    }

    -- (a nil Go map reads as empty)
    local harnessConfig = testCaseContentWithConfig.configuration or {}
    local currentDirectory = tspath.GetNormalizedAbsolutePath(harnessConfig["currentdirectory"] or "", testrunner.srcFolder)

    local units = testCaseContentWithConfig.testUnitData
    local toBeCompiled = {}
    local otherFiles = {}
    local tsConfig = nil
    local hasNonDtsFiles = core.Some(
        units,
        function(unit) return not tspath.FileExtensionIs(unit.name, tspath.ExtensionDts) end
    )
    local tsConfigFiles = {}
    if testCaseContentWithConfig.tsConfig ~= nil then
        tsConfig = testCaseContentWithConfig.tsConfig
        tsConfigFiles = {
            testrunner.createHarnessTestFile(testCaseContentWithConfig.tsConfigFileUnitData, currentDirectory),
        }
        for _, unit in ipairs(units) do
            if contains(
                    tsConfig.parsedConfig.fileNames or {},
                    tspath.GetNormalizedAbsolutePath(unit.name, currentDirectory)
                ) then
                toBeCompiled[#toBeCompiled + 1] = testrunner.createHarnessTestFile(unit, currentDirectory)
            else
                otherFiles[#otherFiles + 1] = testrunner.createHarnessTestFile(unit, currentDirectory)
            end
        end
    else
        local baseUrl = harnessConfig["baseurl"]
        if baseUrl ~= nil and not tspath.IsRootedDiskPath(baseUrl) then
            harnessConfig["baseurl"] = tspath.GetNormalizedAbsolutePath(baseUrl, currentDirectory)
        end

        local lastUnit = units[#units]
        -- We need to assemble the list of input files for the compiler and other related files on the 'filesystem' (ie in a multi-file test)
        -- If the last file in a test uses require or a triple slash reference we'll assume all other files will be brought in via references,
        -- otherwise, assume all files are just meant to be in the same compilation session without explicit references to one another.

        if (harnessConfig["noimplicitreferences"] or "") ~= "" or
            string.find(lastUnit.content, testrunner.requireStr, 1, true) ~= nil or
            testrunner.referencesRegex:MatchString(lastUnit.content) then
            toBeCompiled[#toBeCompiled + 1] = testrunner.createHarnessTestFile(lastUnit, currentDirectory)
            for i = 1, #units - 1 do
                otherFiles[#otherFiles + 1] = testrunner.createHarnessTestFile(units[i], currentDirectory)
            end
        else
            toBeCompiled = core.Map(units, function(unit) return testrunner.createHarnessTestFile(unit, currentDirectory) end)
        end
    end

    local result = harnessutil.CompileFiles(
        t,
        toBeCompiled,
        otherFiles,
        testCaseContentWithConfig.configuration,
        tsConfig,
        currentDirectory,
        testCaseContentWithConfig.symlinks
    )

    -- Content-mapped files are transformed during program construction; the transformed text is what the
    -- compiler actually parses and reports positions against. Baseline that text (rather than the original
    -- foreign source) so the type, symbol, and error baselines line up with the compiler's positions.
    for _, file in ipairs(core.Concatenate(toBeCompiled, otherFiles)) do
        local sf = result.program:GetSourceFile(file.unitName)
        if sf ~= nil and sf.ContentMapper ~= nil and sf:ContentMapper() ~= "" then
            file.content = sf:Text()
        end
    end

    return setmetatable({
        testName = testName,
        filename = filename,
        basename = basename,
        configuredName = configuredName,
        currentDirectory = currentDirectory,
        options = result.options,
        harnessOptions = result.harnessOptions,
        result = result,
        tsConfigFiles = tsConfigFiles,
        toBeCompiled = toBeCompiled,
        otherFiles = otherFiles,
        hasNonDtsFiles = hasNonDtsFiles,
    }, compilerTest)
end

local function cutPrefix(s, prefix)
    if string.sub(s, 1, #prefix) == prefix then
        return string.sub(s, #prefix + 1), true
    end
    return s, false
end

function compilerTest:verifyDiagnostics(t, suiteName, isSubmodule)
    t:Run("error", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating error baseline for test " .. self.filename, function()
            local files = core.Concatenate(self.tsConfigFiles, core.Concatenate(self.toBeCompiled, self.otherFiles))
            local diags = self.result.diagnostics
            -- Content-mapped files' diagnostics are baselined separately (see verifyContentMapper), where they can
            -- be rendered against the correct text; the squiggle renderer here assumes a single coordinate space.
            local contentMapped = self:contentMappedFileNames()
            if contentMapped ~= nil and next(contentMapped) ~= nil then
                files = core.Filter(files, function(f)
                    return not contentMapped[tspath.GetNormalizedAbsolutePath(f.unitName, self.currentDirectory)]
                end)
                diags = core.Filter(diags, function(d)
                    return d:File() == nil or not contentMapped[d:File():FileName()]
                end)
            end
            tsbaseline.DoErrorBaseline(t1, self.configuredName, files, diags, core.Tristate_IsTrue(self.result.options.pretty), {
                subfolder = suiteName,
                isSubmodule = isSubmodule,
                diffFixupOld = function(old)
                    local sb = {}

                    for line in string.gmatch(old .. "\n", "([^\n]*)\n") do
                        local relativePrefixNew = "==== "
                        local relativePrefixOld = relativePrefixNew .. "./"
                        local rest, ok = cutPrefix(line, relativePrefixOld)
                        if ok then
                            line = relativePrefixNew .. rest
                        end

                        sb[#sb + 1] = line
                        sb[#sb + 1] = "\n"
                    end

                    local s = table.concat(sb)
                    return string.sub(s, 1, #s - 1)
                end,
            })
        end)
    end)
end

function compilerTest:verifyContentMapper(t, suiteName, isSubmodule)
    t:Run("content mapper", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating content mapper baseline for test " .. self.filename, function()
            tsbaseline.DoContentMapperBaseline(t1, self.configuredName, self.result.program, self.result.diagnostics, {
                subfolder = suiteName,
                isSubmodule = isSubmodule,
            })
        end)
    end)
end

-- contentMappedFileNames returns the set of absolute file names that were produced by a content mapper.
function compilerTest:contentMappedFileNames()
    local program = self.result.program:Program()
    local mapped = nil
    for _, file in ipairs(self.result.program:GetSourceFiles()) do
        if program:GetContentMapper(file) ~= nil then
            if mapped == nil then
                mapped = {}
            end
            mapped[file:FileName()] = true
        end
    end
    return mapped
end

testrunner.skippedEmitTests = {
    ["filesEmittingIntoSameOutput.ts"] = "Output order nondeterministic due to collision on filename during parallel emit.",
    ["jsFileCompilationWithJsEmitPathSameAsInput.ts"] = "Output order nondeterministic due to collision on filename during parallel emit.",
    ["grammarErrors.ts"] = "Output order nondeterministic due to collision on filename during parallel emit.",
    ["jsFileCompilationEmitBlockedCorrectly.ts"] = "Output order nondeterministic due to collision on filename during parallel emit.",
    ["jsDeclarationsReexportAliasesEsModuleInterop.ts"] = "cls.d.ts is missing statements when run concurrently.",
    ["jsFileCompilationWithoutJsExtensions.ts"] = "No files are emitted.",
    ["typeOnlyMerge2.ts"] = "Nondeterministic contents when run concurrently.",
    ["typeOnlyMerge3.ts"] = "Nondeterministic contents when run concurrently.",
}

function compilerTest:header(isSubmodule)
    local headerComponents = tspath.GetPathComponentsRelativeTo(repo.TestDataPath(), self.filename, {})
    if isSubmodule then
        headerComponents = core.Slice(headerComponents, 4) -- Strip "./../_submodules/TypeScript" prefix
    end
    return tspath.GetPathFromPathComponents(headerComponents)
end

function compilerTest:verifyJavaScriptOutput(t, suiteName, isSubmodule)
    if not self.hasNonDtsFiles then
        return
    end

    t:Run("output", function(t1)
        local msg = testrunner.skippedEmitTests[self.basename]
        if msg ~= nil then
            t1:Skip(msg)
        end

        testutil.RecoverAndFail(t1, "Panic on creating js output for test " .. self.filename, function()
            local header = self:header(isSubmodule)
            tsbaseline.DoJSEmitBaseline(
                t1,
                self.configuredName,
                header,
                self.options,
                self.result,
                self.tsConfigFiles,
                self.toBeCompiled,
                self.otherFiles,
                self.harnessOptions,
                { subfolder = suiteName, isSubmodule = isSubmodule }
            )
        end)
    end)
end

function compilerTest:verifySourceMapOutput(t, suiteName, isSubmodule)
    t:Run("sourcemap", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating source map output for test " .. self.filename, function()
            local header = self:header(isSubmodule)
            tsbaseline.DoSourcemapBaseline(
                t1,
                self.configuredName,
                header,
                self.options,
                self.result,
                self.harnessOptions,
                { subfolder = suiteName, isSubmodule = isSubmodule }
            )
        end)
    end)
end

function compilerTest:verifySourceMapRecord(t, suiteName, isSubmodule)
    t:Run("sourcemap record", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating source map record for test " .. self.filename, function()
            local header = self:header(isSubmodule)
            tsbaseline.DoSourcemapRecordBaseline(
                t1,
                self.configuredName,
                header,
                self.options,
                self.result,
                self.harnessOptions,
                { subfolder = suiteName, isSubmodule = isSubmodule }
            )
        end)
    end)
end

-- skipTypeBaselines / skipSymbolBaselines are Lua-only (the CLI's --baselines); Go always runs both.
function compilerTest:verifyTypesAndSymbols(t, suiteName, isSubmodule, skipTypeBaselines, skipSymbolBaselines)
    local noTypesAndSymbols = self.harnessOptions.noTypesAndSymbols
    if noTypesAndSymbols then
        return
    end
    local program = self.result.program
    local allFiles = core.Filter(
        core.Concatenate(self.toBeCompiled, self.otherFiles),
        function(f)
            return program:GetSourceFile(f.unitName) ~= nil
        end
    )

    local header = self:header(isSubmodule)
    tsbaseline.DoTypeAndSymbolBaseline(
        t,
        self.configuredName,
        header,
        program,
        allFiles,
        { subfolder = suiteName, isSubmodule = isSubmodule },
        skipTypeBaselines == true,
        skipSymbolBaselines == true,
        core.Len(self.result.diagnostics) > 0
    )
end

function compilerTest:verifyModuleResolution(t, suiteName, isSubmodule)
    if not core.Tristate_IsTrue(self.options.traceResolution) then
        return
    end

    t:Run("module resolution", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating module resolution baseline for test " .. self.filename, function()
            tsbaseline.DoModuleResolutionBaseline(t1, self.configuredName, self.result.trace, {
                subfolder = suiteName,
                isSubmodule = isSubmodule,
                skipDiffWithOld = true,
            })
        end)
    end)
end

function testrunner.createHarnessTestFile(unit, currentDirectory)
    return harnessutil.NewTestFile(tspath.GetNormalizedAbsolutePath(unit.name, currentDirectory), unit.content)
end

local function arraysEqual(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- slices.SortFunc with a Go-style comparer.
local function sortFunc(xs, cmp)
    table.sort(xs, function(a, b)
        return cmp(a, b) < 0
    end)
end

-- A deterministic shuffler standing in for math/rand/v2 PCG(1234, 5678): the check only needs
-- some fixed sequence of permutations, not Go's exact one.
local function newShuffler()
    local state = 1234 * 6364136223846793005 + 5678
    return function(n, swap)
        for i = n - 1, 1, -1 do
            state = state * 6364136223846793005 + 1442695040888963407
            local j = ((state >> 33) & 0x7fffffff) % (i + 1)
            swap(i, j)
        end
    end
end

function compilerTest:verifyUnionOrdering(t)
    t:Run("union ordering", function(t1)
        local p = self.result.program:Program()
        p:ForEachCheckerParallel(function(_, c)
            for union in c:UnionTypes() do
                local types = union:Types()

                local reversed = {}
                for i = #types, 1, -1 do
                    reversed[#reversed + 1] = types[i]
                end
                sortFunc(reversed, checker.CompareTypes)
                testutil.Assert(t1, arraysEqual(reversed, types), "compareTypes does not sort union types consistently")

                local shuffled = {}
                for i, x in ipairs(types) do
                    shuffled[i] = x
                end
                local shuffle = newShuffler()

                for _ = 1, 10 do
                    shuffle(#shuffled, function(i, j)
                        shuffled[i + 1], shuffled[j + 1] = shuffled[j + 1], shuffled[i + 1]
                    end)
                    sortFunc(shuffled, checker.CompareTypes)
                    testutil.Assert(t1, arraysEqual(shuffled, types), "compareTypes does not sort union types consistently")
                end
            end
        end)
    end)
end

function compilerTest:verifyParentPointers(t)
    t:Run("source file parent pointers", function(t1)
        local parent = nil
        local verifier
        verifier = function(n)
            if n == nil then
                return false
            end
            testutil.Assert(t1, n.parent ~= nil, "parent node does not exist")
            local elab = ""
            if not ast.NodeIsSynthesized(n) then
                elab = elab .. string.sub(ast.GetSourceFileOfNode(n):Text(), n.loc:Pos() + 1, n.loc:End())
            else
                elab = elab .. "!synthetic! no text available"
            end
            testutil.Assert(t1, n.parent == parent, "%s", "parent node does not match traversed parent: " .. ast.Kind_names[n.kind] .. ": " .. elab)
            local oldParent = parent
            parent = n
            n:ForEachChild(verifier)
            parent = oldParent
            return false
        end
        for _, f in ipairs(self.result.program:GetSourceFiles()) do
            if self.result.program:IsSourceFileDefaultLibrary(f:Path()) then
                goto continue
            end
            parent = f
            f:ForEachChild(verifier)
            ::continue::
        end
    end)
end

return testrunner
