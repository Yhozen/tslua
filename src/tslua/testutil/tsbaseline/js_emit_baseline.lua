local tsbaseline = require("tslua.testutil.tsbaseline")
local ast = require("tslua.ast")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local diagnosticwriter = require("tslua.diagnosticwriter")
local harnessutil = require("tslua.testutil.harnessutil")
local outputpaths = require("tslua.outputpaths")
local parser = require("tslua.parser")
local tspath = require("tslua.tspath")

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

local function concat(...)
    local out = {}
    for i = 1, select("#", ...) do
        for _, x in ipairs(select(i, ...) or {}) do
            out[#out + 1] = x
        end
    end
    return out
end

function tsbaseline.DoJSEmitBaseline(t, baselinePath, header, options, result, tsConfigFiles, toBeCompiled, otherFiles, harnessSettings, opts)
    if not core.Tristate_IsTrue(options.noEmit) and not core.Tristate_IsTrue(options.emitDeclarationOnly) and result.js:Size() == 0 and core.Len(result.diagnostics) == 0 then
        t:Fatal("Expected at least one js file to be emitted or at least one error to be created.")
    end

    -- check js output
    local tsCode = core.NewStringBuilder()
    local tsSources = concat(otherFiles, toBeCompiled)
    tsCode:WriteString("//// [")
    tsCode:WriteString(header)
    tsCode:WriteString("] ////\r\n\r\n")

    for i, file in ipairs(tsSources) do
        tsCode:WriteString("//// [")
        tsCode:WriteString(tspath.GetBaseFileName(file.unitName))
        tsCode:WriteString("]\r\n")
        tsCode:WriteString(file.content)
        if i < #tsSources then
            tsCode:WriteString("\r\n")
        end
    end

    local jsCode = core.NewStringBuilder()
    for file in result.js:Values() do
        if jsCode:Len() > 0 and not hasSuffix(jsCode:String(), "\n") then
            jsCode:WriteString("\r\n")
        end
        if core.Len(result.diagnostics) == 0 and hasSuffix(file.unitName, tspath.ExtensionJson) then
            local fileParseResult = parser.ParseSourceFile(ast.NewSourceFileParseOptions(file.unitName, file.unitName), file.content, core.ScriptKind.JSON)
            if core.Len(fileParseResult:Diagnostics()) > 0 then
                jsCode:WriteString(tsbaseline.GetErrorBaseline(t, { file }, diagnosticwriter.WrapASTDiagnostics(fileParseResult:Diagnostics()), diagnosticwriter.CompareASTDiagnostics, false --[[pretty]]))
                goto continue
            end
        end
        jsCode:WriteString(tsbaseline.fileOutput(file, harnessSettings))
        ::continue::
    end

    if result.dts:Size() > 0 then
        jsCode:WriteString("\r\n\r\n")
        for declFile in result.dts:Values() do
            jsCode:WriteString(tsbaseline.fileOutput(declFile, harnessSettings))
        end
    end

    local declFileContext = tsbaseline.prepareDeclarationCompilationContext(
        toBeCompiled,
        otherFiles,
        result,
        harnessSettings,
        options,
        "" --[[currentDirectory]]
    )
    local declFileCompilationResult = tsbaseline.compileDeclarationFiles(t, declFileContext, result.symlinks)

    if declFileCompilationResult ~= nil and core.Len(declFileCompilationResult.declResult.diagnostics) > 0 then
        jsCode:WriteString("\r\n\r\n//// [DtsFileErrors]\r\n")
        jsCode:WriteString("\r\n\r\n")
        jsCode:WriteString(tsbaseline.GetErrorBaseline(
            t,
            concat(tsConfigFiles, declFileCompilationResult.declInputFiles, declFileCompilationResult.declOtherFiles),
            diagnosticwriter.WrapASTDiagnostics(declFileCompilationResult.declResult.diagnostics),
            diagnosticwriter.CompareASTDiagnostics,
            false --[[pretty]]
        ))
    end

    if not core.Tristate_IsTrue(options.noCheck) and not core.Tristate_IsTrue(options.noEmit) then
        local testConfig = {}
        testConfig["noCheck"] = "true"
        local withoutChecking = result.repeat_(testConfig)
        local function compareResultFileSets(a, b)
            for key, doc in a:Entries() do
                local original = b:GetOrZero(key)
                if original == nil then
                    jsCode:WriteString("\r\n\r\n!!!! File ")
                    jsCode:WriteString(tsbaseline.removeTestPathPrefixes(doc.unitName, false --[[retainTrailingDirectorySeparator]]))
                    jsCode:WriteString(" missing from original emit, but present in noCheck emit\r\n")
                    jsCode:WriteString(tsbaseline.fileOutput(doc, harnessSettings))
                elseif original.content ~= doc.content then
                    jsCode:WriteString("\r\n\r\n!!!! File ")
                    jsCode:WriteString(tsbaseline.removeTestPathPrefixes(doc.unitName, false --[[retainTrailingDirectorySeparator]]))
                    jsCode:WriteString(" differs from original emit in noCheck emit\r\n")
                    local fileName
                    if harnessSettings.fullEmitPaths then
                        fileName = tsbaseline.removeTestPathPrefixes(doc.unitName, false --[[retainTrailingDirectorySeparator]])
                    else
                        fileName = tspath.GetBaseFileName(doc.unitName)
                    end
                    jsCode:WriteString("//// [")
                    jsCode:WriteString(fileName)
                    jsCode:WriteString("]\r\n")
                    local expected = original.content
                    local actual = doc.content
                    jsCode:WriteString(baseline.DiffText("Expected\tThe full check baseline", "Actual\twith noCheck set", expected, actual))
                end
            end
        end
        compareResultFileSets(withoutChecking.dts, result.dts)
        compareResultFileSets(withoutChecking.js, result.js)
    end

    if tspath.FileExtensionIsOneOf(baselinePath, { tspath.ExtensionTs, tspath.ExtensionTsx }) then
        baselinePath = tspath.ChangeExtension(baselinePath, tspath.ExtensionJs)
    end

    local actual
    if jsCode:Len() > 0 then
        actual = tsCode:String() .. "\r\n\r\n" .. jsCode:String()
    else
        actual = baseline.NoContent
    end

    baseline.Run(t, baselinePath, actual, opts)
end

function tsbaseline.fileOutput(file, settings)
    local fileName
    if settings.fullEmitPaths then
        fileName = tsbaseline.removeTestPathPrefixes(file.unitName, false --[[retainTrailingDirectorySeparator]])
    else
        fileName = tspath.GetBaseFileName(file.unitName)
    end
    return "//// [" .. fileName .. "]\r\n" .. file.content
end

-- declarationCompilationContext: { declInputFiles, declOtherFiles, harnessSettings, options,
-- currentDirectory, config }

local function contentMapperOf(sourceFile)
    if sourceFile.ContentMapper == nil then
        return ""
    end
    return sourceFile:ContentMapper()
end

function tsbaseline.prepareDeclarationCompilationContext(
    inputFiles,
    otherFiles,
    result,
    harnessSettings,
    options,
    -- Current directory is needed for rwcRunner to be able to use currentDirectory defined in json file
    currentDirectory
)
    if core.Tristate_IsTrue(options.declaration) and core.Len(result.diagnostics) == 0 then
        if core.Tristate_IsTrue(options.emitDeclarationOnly) then
            if result.js:Size() > 0 then
                error("Only declaration files should be generated when emitDeclarationOnly:true", 0)
            end
            if result.dts:Size() == 0 and not core.Tristate_IsTrue(options.noEmit) then
                error("Expected at least one declaration file to be emitted when emitDeclarationOnly:true and no errors were generated", 0)
            end
        elseif not core.Some(result.program:GetSourceFiles(), function(file)
            return contentMapperOf(file) ~= ""
        end) and result.dts:Size() ~= result:GetNumberOfJSFiles(false --[[includeJson]]) then
            error("There were no errors and declFiles generated did not match number of js files generated", 0)
        end
    end

    local declInputFiles = {}
    local declOtherFiles = {}

    local function findUnit(fileName, units)
        for _, unit in ipairs(units) do
            if unit.unitName == fileName then
                return unit
            end
        end
        return nil
    end

    local function findResultCodeFile(fileName)
        local sourceFile = result.program:GetSourceFile(fileName)
        if sourceFile == nil then
            error("Program has no source file with name '" .. fileName .. "'", 0)
        end
        -- Is this file going to be emitted separately
        local sourceFileName

        if #options.outDir ~= 0 then
            local sourceFilePath = tspath.GetNormalizedAbsolutePath(sourceFile:FileName(), result.host:GetCurrentDirectory())
            local common = result.program:CommonSourceDirectory()
            local i = string.find(sourceFilePath, common, 1, true)
            if i ~= nil then
                sourceFilePath = string.sub(sourceFilePath, 1, i - 1) .. string.sub(sourceFilePath, i + #common)
            end
            sourceFileName = tspath.CombinePaths(options.outDir, sourceFilePath)
        else
            sourceFileName = sourceFile:FileName()
        end

        local dTsFileName = outputpaths.ChangeToDeclarationExtension(sourceFileName, result.program:Program())
        return result.dts:GetOrZero(dTsFileName)
    end

    local function addDtsFile(file, dtsFiles)
        if tspath.IsDeclarationFileName(file.unitName) or tspath.HasJSONFileExtension(file.unitName) then
            dtsFiles[#dtsFiles + 1] = file
        else
            local sourceFile = result.program:GetSourceFile(file.unitName)
            if sourceFile ~= nil and
                (tspath.HasTSFileExtension(file.unitName) or (tspath.HasJSFileExtension(file.unitName) and options:GetAllowJS()) or contentMapperOf(sourceFile) ~= "") then
                local declFile = findResultCodeFile(file.unitName)
                if declFile ~= nil and findUnit(declFile.unitName, declInputFiles) == nil and findUnit(declFile.unitName, declOtherFiles) == nil then
                    local content = declFile.content
                    if string.sub(content, 1, 3) == "\u{FEFF}" then
                        content = string.sub(content, 4)
                    end
                    dtsFiles[#dtsFiles + 1] = harnessutil.NewTestFile(declFile.unitName, content)
                end
            end
        end
        return dtsFiles
    end

    -- if the .d.ts is non-empty, confirm it compiles correctly as well
    if core.Tristate_IsTrue(options.declaration) and core.Len(result.diagnostics) == 0 and result.dts:Size() > 0 then
        for _, file in ipairs(inputFiles or {}) do
            declInputFiles = addDtsFile(file, declInputFiles)
        end
        for _, file in ipairs(otherFiles or {}) do
            declOtherFiles = addDtsFile(file, declOtherFiles)
        end
        return {
            declInputFiles = declInputFiles,
            declOtherFiles = declOtherFiles,
            harnessSettings = harnessSettings,
            options = options,
            currentDirectory = core.IfElse(#currentDirectory > 0, currentDirectory, harnessSettings.currentDirectory),
            config = result.program:Program():CommandLine(),
        }
    end
    return nil
end

-- declarationCompilationResult: { declInputFiles, declOtherFiles, declResult }

function tsbaseline.compileDeclarationFiles(t, context, symlinks)
    if context == nil then
        return nil
    end
    local tsconfig = nil
    if context.config ~= nil and context.config.configFile ~= nil then
        tsconfig = harnessutil.newParsedCommandLine(
            harnessutil.newParsedOptions(nil, nil, context.config:ContentMappers()),
            context.config.configFile,
            nil
        )
    end
    local declFileCompilationResult = harnessutil.CompileFilesEx(t,
        context.declInputFiles,
        context.declOtherFiles,
        context.harnessSettings,
        context.options,
        context.currentDirectory,
        symlinks,
        tsconfig)
    return {
        declInputFiles = context.declInputFiles,
        declOtherFiles = context.declOtherFiles,
        declResult = declFileCompilationResult,
    }
end

return tsbaseline
