local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local glob = require("tslua.glob")
local locale = require("tslua.locale")
local outputpaths = require("tslua.outputpaths")
local tspath = require("tslua.tspath")
local vfsmatch = require("tslua.vfs.vfsmatch")

local strings = require("tslua.module").strings
local appendAll = require("tslua.module").appendAll

tsoptions.fileGlobPattern = "*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,json}"
tsoptions.recursiveFileGlobPattern = "**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,json}"

local ParsedCommandLine = {}
ParsedCommandLine.__index = ParsedCommandLine
tsoptions.ParsedCommandLine = ParsedCommandLine

-- fileGlobPatterns returns the include file glob patterns for this command line, augmenting the
-- built-in patterns with the extensions registered by its content mappers so that created
-- content-mapped files are recognized as possible root files.
-- Returns fileGlob, recursiveFileGlob.
function ParsedCommandLine:fileGlobPatterns()
    local mapperExtensions = self:ContentMapperExtensions()
    if core.Len(mapperExtensions) == 0 then
        return tsoptions.fileGlobPattern, tsoptions.recursiveFileGlobPattern
    end
    local extensions = { "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "json" }
    for _, extension in ipairs(mapperExtensions) do
        extensions[#extensions + 1] = strings.TrimPrefix(extension, ".")
    end
    local fileGlob = "*.{" .. strings.Join(extensions, ",") .. "}"
    return fileGlob, "**/" .. fileGlob
end

-- ParsedCommandLine fields: parsedConfig (*ParsedOptions), configFile (*TsConfigSourceFile; used in Program
-- and ExecuteCommandLine), errors, raw, compileOnSave (bool or nil), comparePathsOptions, and the lazily
-- computed caches below.
function tsoptions.newParsedCommandLineStruct(init)
    local p = setmetatable({
        parsedConfig = nil,
        configFile = nil,
        errors = nil,
        raw = nil,
        compileOnSave = nil,

        comparePathsOptions = tspath.NewComparePathsOptions(false, ""), -- Go zero value (value struct)
        wildcardDirectoriesOnce = false,
        wildcardDirectories = nil,
        includeGlobsOnce = false,
        includeGlobs = nil,

        sourceAndOutputMapsOnce = false,
        sourceToProjectReference = nil,
        outputDtsToProjectReference = nil,

        commonSourceDirectory = "",
        commonSourceDirectoryOnce = false,

        resolvedProjectReferencePaths = nil,
        resolvedProjectReferencePathsOnce = false,

        literalFileNamesLen = 0,
        fileNamesByPath = nil, -- maps file names to their paths, used for quick lookups
        fileNamesByPathOnce = false,

        locale = nil,
        localeOnce = false,
    }, ParsedCommandLine)
    if init ~= nil then
        for k, v in pairs(init) do
            p[k] = v
        end
    end
    return p
end

function tsoptions.NewParsedCommandLine(
    compilerOptions,
    rootFileNames,
    comparePathsOptions
)
    return tsoptions.newParsedCommandLineStruct({
        parsedConfig = tsoptions.NewParsedOptions({
            compilerOptions = compilerOptions,
            fileNames = rootFileNames,
        }),
        comparePathsOptions = comparePathsOptions,
    })
end

function ParsedCommandLine:WithFileNames(fileNames)
    local parsedConfig = self.parsedConfig:copy()
    parsedConfig.fileNames = fileNames
    return tsoptions.newParsedCommandLineStruct({
        parsedConfig = parsedConfig,
        configFile = self.configFile,
        errors = self.errors,
        raw = self.raw,
        compileOnSave = self.compileOnSave,
        comparePathsOptions = self.comparePathsOptions,
        wildcardDirectories = self.wildcardDirectories,
        includeGlobs = self.includeGlobs,
        literalFileNamesLen = self.literalFileNamesLen,
    })
end

-- SourceOutputAndProjectReference: { source, outputDts, resolved = *ParsedCommandLine }

-- ParsedCommandLine implements module.ResolvedProjectReference and outputpaths.OutputPathsHost.
-- ConfigName is callable on nil as tsoptions.ParsedCommandLine.ConfigName(p).
function ParsedCommandLine.ConfigName(p)
    if p == nil or p.configFile == nil then
        return ""
    end
    return p.configFile.sourceFile:FileName()
end

function ParsedCommandLine:SourceToProjectReference()
    return self.sourceToProjectReference
end

function ParsedCommandLine:OutputDtsToProjectReference()
    return self.outputDtsToProjectReference
end

function ParsedCommandLine:ParseInputOutputNames()
    if not self.sourceAndOutputMapsOnce then
        self.sourceAndOutputMapsOnce = true
        local sourceToOutput = {}
        local outputDtsToSource = {}

        for outputDts, source in self:getOutputDeclarationAndSourceFileNames() do
            local path = tspath.ToPath(source, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
            local projectReference = {
                source = source,
                outputDts = outputDts,
                resolved = self,
            }
            if outputDts ~= "" then
                outputDtsToSource[tspath.ToPath(outputDts, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())] = projectReference
            end
            sourceToOutput[path] = projectReference
        end
        self.outputDtsToProjectReference = outputDtsToSource
        self.sourceToProjectReference = sourceToOutput
    end
end

function ParsedCommandLine:CommonSourceDirectory()
    if not self.commonSourceDirectoryOnce then
        self.commonSourceDirectoryOnce = true
        local function files()
            return core.Filter(self.parsedConfig.fileNames or {}, function(file)
                return not (core.Tristate_IsTrue(self.parsedConfig.compilerOptions.noEmitForJsFiles) and tspath.HasJSFileExtension(file)) and not tspath.IsDeclarationFileName(file)
            end)
        end

        self.commonSourceDirectory = outputpaths.GetCommonSourceDirectory(
            self.parsedConfig.compilerOptions,
            files,
            self:GetCurrentDirectory(),
            self:UseCaseSensitiveFileNames(),
            function(sourceFiles, rootDirectory)
                return self:checkSourceFilesBelongToPath(sourceFiles, rootDirectory)
            end
        )
    end
    return self.commonSourceDirectory
end

function ParsedCommandLine:checkSourceFilesBelongToPath(sourceFiles, rootDirectory)
    local allFilesBelongToPath = true
    for _, file in ipairs(sourceFiles or {}) do
        local absoluteSourceFilePath = tspath.GetCanonicalFileName(tspath.GetNormalizedAbsolutePath(file, self:GetCurrentDirectory()), self:UseCaseSensitiveFileNames())
        if not tspath.ContainsPath(rootDirectory, file, self.comparePathsOptions) then
            self.errors = core.Append(self.errors, ast.NewCompilerDiagnostic(diagnostics.File_0_is_not_under_rootDir_1_rootDir_is_expected_to_contain_all_source_files, absoluteSourceFilePath, rootDirectory))
            allFilesBelongToPath = false
        end
    end

    return allFilesBelongToPath
end

function ParsedCommandLine:GetCurrentDirectory()
    return self.comparePathsOptions.currentDirectory
end

function ParsedCommandLine:UseCaseSensitiveFileNames()
    return self.comparePathsOptions.useCaseSensitiveFileNames
end

-- Lua iterator over (dtsName, inputName) pairs.
function ParsedCommandLine:getOutputDeclarationAndSourceFileNames()
    local pairsList = {}
    for _, fileName in ipairs(self.parsedConfig.fileNames or {}) do
        local outputDts = ""
        if not tspath.IsDeclarationFileName(fileName) and not tspath.FileExtensionIs(fileName, tspath.ExtensionJson) then
            outputDts = outputpaths.GetOutputDeclarationFileNameWorker(fileName, self:CompilerOptions(), self)
        end
        pairsList[#pairsList + 1] = { outputDts, fileName }
    end
    local i = 0
    return function()
        i = i + 1
        local entry = pairsList[i]
        if entry == nil then
            return nil
        end
        return entry[1], entry[2]
    end
end

-- Lua iterator over output file names.
function ParsedCommandLine:GetOutputFileNames()
    local names = {}
    local options = self:CompilerOptions()
    for _, fileName in ipairs(self.parsedConfig.fileNames or {}) do
        if not tspath.IsDeclarationFileName(fileName) then
            local jsFileName = outputpaths.GetOutputJSFileName(fileName, options, self)
            local isJson = tspath.FileExtensionIs(fileName, tspath.ExtensionJson)
            if jsFileName ~= "" then
                names[#names + 1] = jsFileName
                if not isJson then
                    local sourceMap = outputpaths.GetSourceMapFilePath(jsFileName, options)
                    if sourceMap ~= "" then
                        names[#names + 1] = sourceMap
                    end
                end
            end
            if not isJson and options:GetEmitDeclarations() then
                local dtsFileName = outputpaths.GetOutputDeclarationFileNameWorker(fileName, options, self)
                if dtsFileName ~= "" then
                    names[#names + 1] = dtsFileName
                    if self:GetContentMapperForFileName(fileName) == nil and options:GetAreDeclarationMapsEnabled() then
                        local declarationMap = dtsFileName .. ".map"
                        names[#names + 1] = declarationMap
                    end
                end
            end
        end
    end
    return core.Values(names)
end

function ParsedCommandLine:GetBuildInfoFileName()
    return outputpaths.GetBuildInfoFileName(self:CompilerOptions(), self.comparePathsOptions)
end

-- WildcardDirectories returns the cached wildcard directories, initializing them if needed.
-- Callable on nil as tsoptions.ParsedCommandLine.WildcardDirectories(p).
function ParsedCommandLine.WildcardDirectories(p)
    if p == nil then
        return nil
    end

    if not p.wildcardDirectoriesOnce then
        p.wildcardDirectoriesOnce = true
        if p.wildcardDirectories == nil then
            p.wildcardDirectories = tsoptions.getWildcardDirectories(
                p.configFile.configFileSpecs.validatedIncludeSpecs,
                p.configFile.configFileSpecs.validatedExcludeSpecs,
                p.comparePathsOptions
            )
        end
    end

    return p.wildcardDirectories
end

local function sortedKeys(m)
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

function ParsedCommandLine:WildcardDirectoryGlobs()
    local wildcardDirectories = self:WildcardDirectories()
    if wildcardDirectories == nil then
        return nil
    end

    if not self.includeGlobsOnce then
        self.includeGlobsOnce = true
        if self.includeGlobs == nil then
            local fileGlob, recursiveFileGlob = self:fileGlobPatterns()
            local globs = {}
            -- Go iterates the map in random order.
            for _, dir in ipairs(sortedKeys(wildcardDirectories)) do
                local recursive = wildcardDirectories[dir]
                local parsed, err = glob.Parse(tspath.NormalizePath(dir) .. "/" .. core.IfElse(recursive, recursiveFileGlob, fileGlob))
                if err == nil then
                    globs[#globs + 1] = parsed
                end
            end
            self.includeGlobs = globs
        end
    end

    return self.includeGlobs
end

-- Normalized file names explicitly specified in `files`
function ParsedCommandLine.LiteralFileNames(p)
    if p ~= nil and p.configFile ~= nil then
        return core.Slice(p:FileNames(), 0, p.literalFileNamesLen)
    end
    return nil
end

function ParsedCommandLine:SetParsedOptions(o)
    self.parsedConfig = o
end

function ParsedCommandLine:SetCompilerOptions(o)
    self.parsedConfig.compilerOptions = o
end

-- Callable on nil as tsoptions.ParsedCommandLine.CompilerOptions(p).
function ParsedCommandLine.CompilerOptions(p)
    if p == nil then
        return nil
    end
    return p.parsedConfig.compilerOptions
end

function ParsedCommandLine:SetTypeAcquisition(o)
    self.parsedConfig.typeAcquisition = o
end

function ParsedCommandLine:TypeAcquisition()
    return self.parsedConfig.typeAcquisition
end

-- All file names matched by files, include, and exclude patterns
function ParsedCommandLine:FileNames()
    return self.parsedConfig.fileNames
end

function ParsedCommandLine:FileNamesByPath()
    if not self.fileNamesByPathOnce then
        self.fileNamesByPathOnce = true
        self.fileNamesByPath = {}
        for _, fileName in ipairs(self.parsedConfig.fileNames or {}) do
            local path = tspath.ToPath(fileName, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
            self.fileNamesByPath[path] = fileName
        end
    end
    return self.fileNamesByPath
end

function ParsedCommandLine:ProjectReferences()
    return self.parsedConfig.projectReferences
end

-- Callable on nil as tsoptions.ParsedCommandLine.ContentMappers(p).
function ParsedCommandLine.ContentMappers(p)
    if p == nil or p.parsedConfig == nil then
        return nil
    end
    return p.parsedConfig.contentMappers
end

-- ContentMapperExtensions returns the flattened list of file extensions registered by the
-- config's content mappers.
function ParsedCommandLine:ContentMapperExtensions()
    return core.FlatMap(self:ContentMappers(), function(m)
        return m.extensions
    end)
end

-- GetContentMapperForFileName returns the configured content mapper whose extensions include fileName,
-- or nil if no content mapper is registered for the file's extension.
function ParsedCommandLine:GetContentMapperForFileName(fileName)
    local ignoreCase = not self:UseCaseSensitiveFileNames()
    local extension = tspath.GetLongestExtensionFromPath(fileName, self:ContentMapperExtensions(), ignoreCase)
    for _, mapper in ipairs(self:ContentMappers() or {}) do
        if core.Some(mapper.extensions, function(mapperExtension)
            return extension == mapperExtension or ignoreCase and strings.EqualFold(extension, mapperExtension)
        end) then
            return mapper
        end
    end
    return nil
end

function ParsedCommandLine:ResolvedProjectReferencePaths()
    if not self.resolvedProjectReferencePathsOnce then
        self.resolvedProjectReferencePathsOnce = true
        self.resolvedProjectReferencePaths = core.Map(self.parsedConfig.projectReferences, core.ResolveProjectReferencePath)
    end
    return self.resolvedProjectReferencePaths
end

-- Callable on nil as tsoptions.ParsedCommandLine.ExtendedSourceFiles(p).
function ParsedCommandLine.ExtendedSourceFiles(p)
    if p == nil or p.configFile == nil then
        return nil
    end
    return p.configFile.extendedSourceFiles
end

function ParsedCommandLine:GetConfigFileParsingDiagnostics()
    if self.configFile ~= nil then
        -- todo: !!! should be ConfigFile.ParseDiagnostics, check if they are the same
        return appendAll(core.Slice(self.configFile.sourceFile:Diagnostics(), 0), self.errors)
    end
    return self.errors
end

-- PossiblyMatchesFileName is a fast check to see if a file is currently included by a config
-- or would be included if the file were to be created. It may return false positives.
function ParsedCommandLine:PossiblyMatchesFileName(fileName)
    local path = tspath.ToPath(fileName, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
    if self:FileNamesByPath()[path] ~= nil then
        return true
    end

    for _, include in ipairs(self.configFile.configFileSpecs.validatedIncludeSpecs or {}) do
        if strings.IndexAny(include, "*?") == -1 and not vfsmatch.IsImplicitGlob(include) then
            local includePath = tspath.ToPath(include, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
            if includePath == path then
                return true
            end
        end
    end
    if self:GetContentMapperForFileName(fileName) ~= nil then
        local directoryPath = tspath.Path_GetDirectoryPath(path)
        if self:PossiblyMatchesDirectoryName(directoryPath) then
            return true
        end
    end
    local wildcardDirectoryGlobs = self:WildcardDirectoryGlobs()
    if core.Len(wildcardDirectoryGlobs) > 0 then
        for _, g in ipairs(wildcardDirectoryGlobs) do
            if g:Match(fileName) then
                return true
            end
        end
    end
    return false
end

function ParsedCommandLine:PossiblyMatchesDirectoryName(directoryPath)
    for wildcardDir, recursive in pairs(self:WildcardDirectories() or {}) do
        local wildcardDirPath = tspath.ToPath(wildcardDir, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
        if recursive then
            if tspath.Path_ContainsPath(wildcardDirPath, directoryPath) then
                return true
            end
        else
            if wildcardDirPath == directoryPath then
                return true
            end
        end
    end
    return false
end

function ParsedCommandLine:GetMatchedFileSpec(fileName)
    return self.configFile.configFileSpecs:getMatchedFileSpec(fileName, self.comparePathsOptions)
end

-- Returns spec, isDefault.
function ParsedCommandLine:GetMatchedIncludeSpec(fileName)
    local specs = self.configFile.configFileSpecs
    if core.Len(specs.validatedIncludeSpecs) == 0 then
        return "", false
    end

    if specs.isDefaultIncludeSpec then
        return specs.validatedIncludeSpecs[1], true
    end

    return specs:getMatchedIncludeSpec(fileName, self.comparePathsOptions), false
end

function ParsedCommandLine:ReloadFileNamesOfParsedCommandLine(fs)
    local parsedConfig = self.parsedConfig:copy()
    local fileNames, literalFileNamesLen = tsoptions.getFileNamesFromConfigSpecs(
        self.configFile.configFileSpecs,
        self:GetCurrentDirectory(),
        self:CompilerOptions(),
        fs,
        self:ContentMapperExtensions()
    )
    parsedConfig.fileNames = fileNames
    return tsoptions.newParsedCommandLineStruct({
        parsedConfig = parsedConfig,
        configFile = self.configFile,
        errors = self.errors,
        raw = self.raw,
        compileOnSave = self.compileOnSave,
        comparePathsOptions = self.comparePathsOptions,
        wildcardDirectories = self.wildcardDirectories,
        includeGlobs = self.includeGlobs,
        literalFileNamesLen = literalFileNamesLen,
    })
end

function ParsedCommandLine:Locale()
    if not self.localeOnce then
        self.localeOnce = true
        self.locale = locale.Parse(self:CompilerOptions().locale)
    end
    return self.locale
end
