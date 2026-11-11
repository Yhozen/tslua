local outputpaths = require("tslua.outputpaths")
local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local JsxEmit = core.JsxEmit

-- OutputPathsHost interface: host:CommonSourceDirectory(), host:ContentMapperExtensions(),
-- host:GetCurrentDirectory(), host:UseCaseSensitiveFileNames().

local OutputPaths = {}
OutputPaths.__index = OutputPaths
outputpaths.OutputPaths = OutputPaths

function outputpaths.newOutputPaths()
    return setmetatable({
        jsFilePath = "",
        sourceMapFilePath = "",
        declarationFilePath = "",
        declarationMapPath = "",
    }, OutputPaths)
end

-- DeclarationFilePath implements declarations.OutputPaths.
function OutputPaths:DeclarationFilePath()
    return self.declarationFilePath
end

-- JsFilePath implements declarations.OutputPaths.
function OutputPaths:JsFilePath()
    return self.jsFilePath
end

function OutputPaths:SourceMapFilePath()
    return self.sourceMapFilePath
end

function OutputPaths:DeclarationMapPath()
    return self.declarationMapPath
end

-- ForceEmitPaths: { dts = bool, js = bool, declarationMap = bool } (nil fields are false).

local function comparePathsOptions(host)
    return tspath.NewComparePathsOptions(host:UseCaseSensitiveFileNames(), host:GetCurrentDirectory())
end

function outputpaths.GetOutputPathsFor(sourceFile, options, host, force)
    force = force or {}
    local ownOutputFilePath = outputpaths.getOwnEmitOutputFilePath(sourceFile:FileName(), options, host, outputpaths.GetOutputExtension(sourceFile:FileName(), options.jsx))
    local isJsonFile = ast.IsJsonSourceFile(sourceFile)
    -- If json file emits to the same location skip writing it, if emitDeclarationOnly skip writing it
    local isJsonEmittedToSameLocation = isJsonFile and
        tspath.ComparePaths(sourceFile:FileName(), ownOutputFilePath, comparePathsOptions(host)) == 0
    local paths = outputpaths.newOutputPaths()
    if sourceFile:ContentMapper() == "" and (force.js or options.emitDeclarationOnly ~= Tristate.TSTrue) and not isJsonEmittedToSameLocation then
        paths.jsFilePath = ownOutputFilePath
        if not ast.IsJsonSourceFile(sourceFile) then
            paths.sourceMapFilePath = outputpaths.GetSourceMapFilePath(paths.jsFilePath, options)
        end
    end
    if force.dts or options:GetEmitDeclarations() and not isJsonFile then
        paths.declarationFilePath = outputpaths.GetDeclarationEmitOutputFilePath(sourceFile:FileName(), options, host)
        if sourceFile:ContentMapper() == "" and (options:GetAreDeclarationMapsEnabled() or force.declarationMap and core.Tristate_IsTrue(options.declarationMap)) then
            paths.declarationMapPath = paths.declarationFilePath .. ".map"
        end
    end
    return paths
end

function outputpaths.ForEachEmittedFile(host, options, action, sourceFiles, forceDtsEmit)
    for _, sourceFile in ipairs(sourceFiles or {}) do
        if action(outputpaths.GetOutputPathsFor(sourceFile, options, host, { dts = forceDtsEmit }), sourceFile) then
            return true
        end
    end
    return false
end

function outputpaths.GetOutputJSFileName(inputFileName, options, host)
    if core.Tristate_IsTrue(options.emitDeclarationOnly) or outputpaths.isContentMappedFileName(inputFileName, host) then
        return ""
    end
    local outputFileName = outputpaths.GetOutputJSFileNameWorker(inputFileName, options, host)
    if not tspath.FileExtensionIs(outputFileName, tspath.ExtensionJson) or
        tspath.ComparePaths(inputFileName, outputFileName, comparePathsOptions(host)) ~= 0 then
        return outputFileName
    end

    return ""
end

function outputpaths.isContentMappedFileName(fileName, host)
    return tspath.GetLongestExtensionFromPath(fileName, host:ContentMapperExtensions(), not host:UseCaseSensitiveFileNames()) ~= ""
end

function outputpaths.GetOutputJSFileNameWorker(inputFileName, options, host)
    return tspath.ChangeExtension(
        outputpaths.getOutputPathWithoutChangingExtension(inputFileName, options.outDir, host),
        outputpaths.GetOutputExtension(inputFileName, options.jsx)
    )
end

function outputpaths.GetOutputDeclarationFileNameWorker(inputFileName, options, host)
    local dir = options.declarationDir
    if #dir == 0 then
        dir = options.outDir
    end
    return outputpaths.ChangeToDeclarationExtension(outputpaths.getOutputPathWithoutChangingExtension(inputFileName, dir, host), host)
end

function outputpaths.GetOutputExtension(fileName, jsx)
    if tspath.FileExtensionIs(fileName, tspath.ExtensionJson) then
        return tspath.ExtensionJson
    elseif jsx == JsxEmit.Preserve and tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionJsx, tspath.ExtensionTsx }) then
        return tspath.ExtensionJsx
    elseif tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionMts, tspath.ExtensionMjs }) then
        return tspath.ExtensionMjs
    elseif tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionCts, tspath.ExtensionCjs }) then
        return tspath.ExtensionCjs
    else
        return tspath.ExtensionJs
    end
end

function outputpaths.GetDeclarationEmitOutputFilePath(file, options, host)
    local outputDir = nil
    if #options.declarationDir > 0 then
        outputDir = options.declarationDir
    elseif #options.outDir > 0 then
        outputDir = options.outDir
    end

    local path
    if outputDir ~= nil then
        path = outputpaths.GetSourceFilePathInNewDirWorker(file, outputDir, host:GetCurrentDirectory(), host:CommonSourceDirectory(), host:UseCaseSensitiveFileNames())
    else
        path = file
    end
    return outputpaths.ChangeToDeclarationExtension(path, host)
end

function outputpaths.ChangeToDeclarationExtension(path, host)
    local extension = tspath.GetLongestExtensionFromPath(path, host:ContentMapperExtensions(), false)
    if extension ~= "" then
        return tspath.RemoveExtension(path, extension) .. ".d" .. extension .. ".ts"
    end
    local pathWithoutExtension = tspath.RemoveFileExtension(path)
    if pathWithoutExtension == path then
        local ext = tspath.GetAnyExtensionFromPath(path, nil, false)
        if ext ~= "" then
            pathWithoutExtension = tspath.RemoveExtension(path, ext)
        end
    end
    return pathWithoutExtension .. tspath.GetDeclarationEmitExtensionForPath(path)
end

function outputpaths.GetSourceFilePathInNewDir(fileName, newDirPath, currentDirectory, commonSourceDirectory, useCaseSensitiveFileNames)
    return outputpaths.GetSourceFilePathInNewDirWorker(fileName, newDirPath, currentDirectory, commonSourceDirectory, useCaseSensitiveFileNames)
end

function outputpaths.getOutputPathWithoutChangingExtension(inputFileName, outputDirectory, host)
    if #outputDirectory > 0 then
        return tspath.ResolvePath(outputDirectory, tspath.GetRelativePathFromDirectory(host:CommonSourceDirectory(), inputFileName, comparePathsOptions(host)))
    end
    return inputFileName
end

function outputpaths.GetSourceFilePathInNewDirWorker(fileName, newDirPath, currentDirectory, commonSourceDirectory, useCaseSensitiveFileNames)
    local sourceFilePath = tspath.GetNormalizedAbsolutePath(fileName, currentDirectory)
    local trimmed, ok = tspath.TrimFilePathPrefix(sourceFilePath, commonSourceDirectory, useCaseSensitiveFileNames)
    if ok then
        sourceFilePath = trimmed
    end
    return tspath.CombinePaths(newDirPath, sourceFilePath)
end

function outputpaths.getOwnEmitOutputFilePath(fileName, options, host, extension)
    local emitOutputFilePathWithoutExtension
    if #options.outDir > 0 then
        local currentDirectory = host:GetCurrentDirectory()
        emitOutputFilePathWithoutExtension = tspath.RemoveFileExtension(outputpaths.GetSourceFilePathInNewDir(
            fileName,
            options.outDir,
            currentDirectory,
            host:CommonSourceDirectory(),
            host:UseCaseSensitiveFileNames()
        ))
    else
        emitOutputFilePathWithoutExtension = tspath.RemoveFileExtension(fileName)
    end
    return emitOutputFilePathWithoutExtension .. extension
end

function outputpaths.GetSourceMapFilePath(jsFilePath, options)
    if core.Tristate_IsTrue(options.sourceMap) and not core.Tristate_IsTrue(options.inlineSourceMap) then
        return jsFilePath .. ".map"
    end
    return ""
end

function outputpaths.GetBuildInfoFileName(options, opts)
    if not options:IsIncremental() and not core.Tristate_IsTrue(options.build) then
        return ""
    end
    if options.tsBuildInfoFile ~= "" then
        return options.tsBuildInfoFile
    end
    if options.configFilePath == "" then
        return ""
    end
    local configFileExtensionLess = tspath.RemoveFileExtension(options.configFilePath)
    local buildInfoExtensionLess
    if options.outDir ~= "" then
        if options.rootDir ~= "" then
            buildInfoExtensionLess = tspath.ResolvePath(options.outDir, tspath.GetRelativePathFromDirectory(options.rootDir, configFileExtensionLess, opts))
        else
            buildInfoExtensionLess = tspath.CombinePaths(options.outDir, tspath.GetBaseFileName(configFileExtensionLess))
        end
    else
        buildInfoExtensionLess = configFileExtensionLess
    end
    return buildInfoExtensionLess .. tspath.ExtensionTsBuildInfo
end
