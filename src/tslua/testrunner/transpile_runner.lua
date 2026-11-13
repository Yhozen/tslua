local testrunner = require("tslua.testrunner")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local diagnosticwriter = require("tslua.diagnosticwriter")
local harnessutil = require("tslua.testutil.harnessutil")
local outputpaths = require("tslua.outputpaths")
local regexp = require("tslua.regexp")
local repo = require("tslua.repo")
local tsbaseline = require("tslua.testutil.tsbaseline")
local tspath = require("tslua.tspath")
local osvfs = require("tslua.vfs.osvfs")

testrunner.transpileBaselineRegex = regexp.MustCompile("\\.[cm]?[tj]sx?$")

testrunner.transpileVaryBy = {
    declarationmap = true,
    sourcemap = true,
    inlinesourcemap = true,
}

-- TranspileBaselineRunner: { testFiles, basePath }
local TranspileBaselineRunner = {}
TranspileBaselineRunner.__index = TranspileBaselineRunner
testrunner.TranspileBaselineRunner = TranspileBaselineRunner

function testrunner.NewTranspileBaselineRunner()
    return setmetatable({
        basePath = "../_submodules/TypeScript/tests/cases/transpile",
        testFiles = nil,
    }, TranspileBaselineRunner)
end

function TranspileBaselineRunner:EnumerateTestFiles()
    if core.Len(self.testFiles) > 0 then
        return self.testFiles
    end
    local files, err = harnessutil.EnumerateFiles(self.basePath, testrunner.transpileBaselineRegex, true)
    if err ~= nil then
        error("Could not read transpile test files: " .. tostring(type(err) == "table" and err:Error() or err), 0)
    end
    self.testFiles = files
    return files
end

function TranspileBaselineRunner:RunTests(t)
    for _, fileName in ipairs(self:EnumerateTestFiles()) do
        self:runTest(t, fileName)
    end
end

function TranspileBaselineRunner:runTest(t, fileName)
    local content, ok = osvfs.FS():ReadFile(fileName)
    if not ok then
        error("Could not read transpile test file: " .. fileName, 0)
    end
    local settings = testrunner.extractCompilerSettings(content)
    local configurations = harnessutil.GetFileBasedTestConfigurations(t, settings, testrunner.transpileVaryBy)
    if #configurations == 0 then
        configurations = { { name = "", config = settings } }
    end

    local extension = tspath.GetAnyExtensionFromPath(fileName, nil, false)
    local baseName = tspath.GetBaseFileName(fileName)
    local justName = baseName
    if #extension > 0 and string.sub(baseName, -#extension) == extension then
        justName = string.sub(baseName, 1, #baseName - #extension)
    end
    local units = testrunner.makeUnitsFromTest(content, baseName).testUnitData

    for _, configuration in ipairs(configurations) do
        local configuredName = justName
        if configuration.name ~= "" then
            configuredName = configuredName .. "(" .. testrunner.formatTranspileConfigurationName(configuration.name) .. ")"
        end
        t:Run(configuredName, function(t1)
            local options = core.NewCompilerOptions()
            local harnessOptions = harnessutil.NewHarnessOptions()
            harnessutil.SetOptionsFromTestConfig(t1, configuration.config, options, harnessOptions, testrunner.srcFolder, false)

            if not core.Tristate_IsTrue(options.emitDeclarationOnly) then
                self:runKind(t1, configuredName, extension, units, options, harnessOptions, false)
            end
            if core.Tristate_IsTrue(options.declaration) then
                self:runKind(t1, configuredName, extension, units, options, harnessOptions, true)
            end
        end)
    end
end

local function replaceAll(s, old, new)
    local out = {}
    local pos = 1
    while true do
        local i = string.find(s, old, pos, true)
        if i == nil then
            break
        end
        out[#out + 1] = string.sub(s, pos, i - 1)
        out[#out + 1] = new
        pos = i + #old
    end
    out[#out + 1] = string.sub(s, pos)
    return table.concat(out)
end

function testrunner.formatTranspileConfigurationName(name)
    name = replaceAll(name, "declarationmap=", "declarationMap=")
    name = replaceAll(name, "inlinesourcemap=", "inlineSourceMap=")
    return replaceAll(name, "sourcemap=", "sourceMap=")
end

-- tslua.transpile (internal/transpile) is loaded on first use, so the compiler baseline runner
-- does not pay for it.
local function requireTranspile()
    return require("tslua.transpile")
end

function TranspileBaselineRunner:runKind(t, configuredName, extension, units, options, harnessOptions, declaration)
    local transpile = requireTranspile()
    local result = core.NewStringBuilder()
    for _, unit in ipairs(units) do
        testrunner.appendTranspileSection(result, unit.name, unit.content)
    end

    for _, unit in ipairs(units) do
        local transpileOptions = {
            compilerOptions = options,
            fileName = unit.name,
            reportDiagnostics = harnessOptions.reportDiagnostics,
        }
        local output
        if declaration then
            output = transpile.TranspileDeclaration(t:Context(), unit.content, transpileOptions)
        else
            output = transpile.TranspileModule(t:Context(), unit.content, transpileOptions)
        end
        if output == nil then
            t:Fatal("transpilation was canceled")
        end

        local outputExtension = outputpaths.GetOutputExtension(unit.name, options.jsx)
        if declaration then
            outputExtension = tspath.GetDeclarationEmitExtensionForPath(unit.name)
        end
        local outputFileName = tspath.ChangeExtension(unit.name, outputExtension)
        testrunner.appendTranspileSection(result, outputFileName, output.outputText)
        if output.sourceMapText ~= nil and output.sourceMapText ~= "" then
            testrunner.appendTranspileSection(result, outputFileName .. ".map", output.sourceMapText)
        end
        if core.Len(output.diagnostics) > 0 then
            result:WriteString("\r\n\r\n//// [Diagnostics reported]\r\n")
            local diagnosticFileName = unit.name
            local file = output.diagnostics[1]:File()
            if file ~= nil then
                diagnosticFileName = file:FileName()
            end
            local errorBaseline = tsbaseline.GetErrorBaseline(
                t,
                { harnessutil.NewTestFile(diagnosticFileName, unit.content) },
                diagnosticwriter.WrapASTDiagnostics(output.diagnostics),
                diagnosticwriter.CompareASTDiagnostics,
                core.Tristate_IsTrue(options.pretty)
            )
            result:WriteString(replaceAll(errorBaseline, diagnosticFileName, unit.name))
            if string.sub(result:String(), -1) ~= "\n" then
                result:WriteString("\r\n")
            end
        end
    end

    local baselineExtension = outputpaths.GetOutputExtension(configuredName .. extension, options.jsx)
    if declaration then
        baselineExtension = tspath.GetDeclarationEmitExtensionForPath(configuredName .. extension)
    end
    local baselineName = configuredName .. baselineExtension
    baseline.Run(t, "transpile/" .. baselineName, result:String(), { isSubmodule = true })
end

function testrunner.appendTranspileSection(result, fileName, content)
    result:WriteString("//// [" .. fileName .. "] ////\r\n")
    result:WriteString(content)
    if string.sub(content, -1) ~= "\n" then
        result:WriteString("\r\n")
    end
end

function testrunner.cleanTranspileBaselines()
    for _, folder in ipairs({ "submodule", "submoduleAccepted", "submoduleTriaged" }) do
        local err = osvfs.FS():Remove(baseline.join(testrunner.localBasePath(), folder, "transpile"))
        if err ~= nil then
            error("Could not clean up transpile baselines: " .. err:Error(), 0)
        end
    end
end

function testrunner.RunTranspileTests(t)
    repo.SkipIfNoTypeScriptSubmodule(t)
    testrunner.cleanTranspileBaselines()
    testrunner.NewTranspileBaselineRunner():RunTests(t)
end

return testrunner
