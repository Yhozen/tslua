local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local outputpaths = require("tslua.outputpaths")
local printer = require("tslua.printer")
local sourcemap = require("tslua.sourcemap")
local stringutil = require("tslua.stringutil")
local declarations = require("tslua.transformers.declarations")
local estransforms = require("tslua.transformers.estransforms")
local inliners = require("tslua.transformers.inliners")
local jsxtransforms = require("tslua.transformers.jsxtransforms")
local moduletransforms = require("tslua.transformers.moduletransforms")
local tstransforms = require("tslua.transformers.tstransforms")
local tspath = require("tslua.tspath")

local EmitOnly = compiler.EmitOnly
local ModuleKind = core.ModuleKind
local Tristate = core.Tristate

local emitter = {}
emitter.__index = emitter
compiler.emitter = emitter

-- emitter fields: host, emitOnly, emitterDiagnostics, writer, paths, sourceFile, emitResult, forceEmit,
-- writeFile, tr
function compiler.newEmitter(fields)
    return setmetatable({
        host = fields.host,
        emitOnly = fields.emitOnly or EmitOnly.EmitAll,
        emitterDiagnostics = ast.NewDiagnosticsCollection(),
        writer = fields.writer,
        paths = fields.paths,
        sourceFile = fields.sourceFile,
        emitResult = compiler.newEmitResult(),
        forceEmit = fields.forceEmit or false,
        writeFile = fields.writeFile,
        tr = fields.tr,
    }, emitter)
end

function emitter:emit()
    self:emitJSFile(self.sourceFile, self.paths:JsFilePath(), self.paths:SourceMapFilePath())
    self:emitDeclarationFile(self.sourceFile, self.paths:DeclarationFilePath(), self.paths:DeclarationMapPath())
    self.emitResult.diagnostics = self.emitterDiagnostics:GetDiagnostics()
end

-- declarationTransformer interface: TransformSourceFile(sourceFile), GetDiagnostics()

function emitter:getDeclarationTransformers(emitContext, sourceFile, declarationFilePath, declarationMapPath)
    local forceDtsEmit = self.emitOnly == EmitOnly.BuilderSignature or self.forceEmit and self.emitOnly == EmitOnly.Dts
    return {
        declarations.NewDeclarationTransformer(self.host, emitContext, self.host:Options(), declarationFilePath, declarationMapPath),
        declarations.NewSupplementalReferencesTransformer(self.host, sourceFile, declarationFilePath, forceDtsEmit),
    }
end

function emitter:runScriptTransformers(emitContext, sourceFile)
    for _, transformer in ipairs(compiler.getScriptTransformers(emitContext, self.host, sourceFile)) do
        sourceFile = transformer:TransformSourceFile(sourceFile)
    end
    return sourceFile
end

-- Returns (*ast.SourceFile, []*ast.Diagnostic).
function emitter:runDeclarationTransformers(emitContext, sourceFile, declarationFilePath, declarationMapPath)
    local diags = nil
    for _, transformer in ipairs(self:getDeclarationTransformers(emitContext, sourceFile, declarationFilePath, declarationMapPath)) do
        sourceFile = transformer:TransformSourceFile(sourceFile)
        diags = core.AppendAll(diags, transformer:GetDiagnostics())
    end
    return sourceFile, diags
end

function compiler.getModuleTransformer(opts)
    local kind = opts.compilerOptions:GetEmitModuleKind()
    if kind == ModuleKind.Preserve then
        -- `ESModuleTransformer` contains logic for preserving CJS input syntax in `--module preserve`
        return moduletransforms.NewESModuleTransformer(opts)
    elseif kind == ModuleKind.ESNext or
        kind == ModuleKind.ES2022 or
        kind == ModuleKind.ES2020 or
        kind == ModuleKind.ES2015 or
        kind == ModuleKind.Node20 or
        kind == ModuleKind.Node18 or
        kind == ModuleKind.Node16 or
        kind == ModuleKind.NodeNext or
        kind == ModuleKind.CommonJS then
        return moduletransforms.NewImpliedModuleTransformer(opts)
    else
        return moduletransforms.NewCommonJSModuleTransformer(opts)
    end
end

function compiler.getScriptTransformers(emitContext, host, sourceFile)
    local tx = {}
    local options = host:Options()

    -- JS files don't use reference calculations as they don't do import elision, no need to calculate it
    local importElisionEnabled = not core.Tristate_IsTrue(options.verbatimModuleSyntax) and not ast.IsInJSFile(sourceFile)
    local jsxTransformEnabled = options:GetJSXTransformEnabled() and sourceFile.languageVariant == core.LanguageVariant.JSX

    local emitResolver = host:GetEmitResolver()

    local referenceResolver
    if importElisionEnabled or jsxTransformEnabled or not options:GetIsolatedModules() or core.Tristate_IsTrue(options.emitDecoratorMetadata) then
        referenceResolver = emitResolver
    else
        referenceResolver = binder.NewReferenceResolver(options, {})
    end

    -- transformers.TransformOptions
    local opts = {
        context = emitContext,
        compilerOptions = options,
        resolver = referenceResolver,
        emitResolver = emitResolver,
        getEmitModuleFormatOfFile = function(file) return host:GetEmitModuleFormatOfFile(file) end,
    }

    -- transform TypeScript syntax
    do
        -- use type nodes to add metadata decorators
        if core.Tristate_IsTrue(options.emitDecoratorMetadata) then
            tx[#tx + 1] = tstransforms.NewMetadataTransformer(opts)
        end

        -- erase types
        tx[#tx + 1] = tstransforms.NewTypeEraserTransformer(opts)

        -- elide imports
        if importElisionEnabled then
            tx[#tx + 1] = tstransforms.NewImportElisionTransformer(opts)
        end

        -- transform `enum`, `namespace`, and parameter properties
        tx[#tx + 1] = tstransforms.NewRuntimeSyntaxTransformer(opts)

        if core.Tristate_IsTrue(options.experimentalDecorators) then
            tx[#tx + 1] = tstransforms.NewLegacyDecoratorsTransformer(opts)
        end
    end

    if jsxTransformEnabled then
        tx[#tx + 1] = jsxtransforms.NewJSXTransformer(opts)
    end

    local downleveler = estransforms.GetESTransformer(opts)
    if downleveler ~= nil then
        tx[#tx + 1] = downleveler
    end

    tx[#tx + 1] = estransforms.NewUseStrictTransformer(opts)

    -- transform module syntax
    tx[#tx + 1] = compiler.getModuleTransformer(opts)

    -- inlining (formerly done via substitutions)
    if not options:GetIsolatedModules() then
        tx[#tx + 1] = inliners.NewConstEnumInliningTransformer(opts)
    end
    return tx
end

function emitter:emitJSFile(sourceFile, jsFilePath, sourceMapFilePath)
    local options = self.host:Options()

    if sourceFile == nil or self.emitOnly ~= EmitOnly.EmitAll and self.emitOnly ~= EmitOnly.Js or #jsFilePath == 0 then
        return
    end

    if not self.forceEmit and (options.noEmit == Tristate.TSTrue or self.host:IsEmitBlocked(jsFilePath)) then
        self.emitResult.emitSkipped = true
        return
    end

    local emitContext, putEmitContext = printer.GetEmitContext()

    sourceFile = self:runScriptTransformers(emitContext, sourceFile)

    local printerOptions = {
        removeComments = core.Tristate_IsTrue(options.removeComments),
        newLine = options.newLine,
        noEmitHelpers = core.Tristate_IsTrue(options.noEmitHelpers),
        sourceMap = core.Tristate_IsTrue(options.sourceMap),
        inlineSourceMap = core.Tristate_IsTrue(options.inlineSourceMap),
        inlineSources = core.Tristate_IsTrue(options.inlineSources),
        target = options.target,
        -- !!!
    }

    -- create a printer to print the nodes
    local p = printer.NewPrinter(printerOptions, {
        -- !!!
    }, emitContext)

    self:printSourceFile(jsFilePath, sourceMapFilePath, sourceFile, p, options, compiler.shouldEmitSourceMaps(options, sourceFile))
    if putEmitContext ~= nil then
        putEmitContext()
    end
end

function emitter:emitDeclarationFile(sourceFile, declarationFilePath, declarationMapPath)
    local options = self.host:Options()

    if sourceFile == nil or self.emitOnly == EmitOnly.Js or #declarationFilePath == 0 then
        return
    end
    -- Declaration files for content-mapped files don't get source maps because the mapped positions would point into
    -- transformed TS content that exists only in-memory during the build. As a future improvement, it may be possible
    -- to double-map the positions using the content-mapped file's spanmap.
    local emitDeclarationMap = self.emitOnly ~= EmitOnly.BuilderSignature and core.Tristate_IsTrue(options.declarationMap) and sourceFile:ContentMapper() == ""

    local emitContext, putEmitContext = printer.GetEmitContext()
    local done = function()
        if putEmitContext ~= nil then
            putEmitContext()
        end
    end
    local diags
    sourceFile, diags = self:runDeclarationTransformers(emitContext, sourceFile, declarationFilePath, declarationMapPath)

    for _, elem in ipairs(diags or {}) do
        -- Add declaration transform diagnostics to emit diagnostics
        self.emitterDiagnostics:Add(elem)
    end

    if not self.forceEmit and self.emitOnly ~= EmitOnly.BuilderSignature and (options.noEmit == Tristate.TSTrue or self.host:IsEmitBlocked(declarationFilePath)) then
        self.emitResult.emitSkipped = true
        done()
        return
    end

    local declBlocked = core.Len(diags) > 0 and not self.forceEmit and self.emitOnly ~= EmitOnly.BuilderSignature
    if declBlocked then
        self.emitResult.emitSkipped = true
        done()
        return
    end

    local printerOptions = {
        removeComments = core.Tristate_IsTrue(options.removeComments),
        newLine = options.newLine,
        noEmitHelpers = true,
        -- Module: 			   options.Module, // NYI
        -- ModuleResolution:   options.ModuleResolution, // NYI
        target = options:GetEmitScriptTarget(),
        sourceMap = emitDeclarationMap,
        inlineSourceMap = core.Tristate_IsTrue(options.inlineSourceMap),
        -- InlineSources:       options.InlineSources.IsTrue(), // ignored, per strada
        -- ExtendedDiagnostics: options.ExtendedDiagnostics.IsTrue(), // NYI
        onlyPrintJSDocStyle = true,
        omitBraceSourceMapPositions = true,
    }

    -- create a printer to print the nodes
    local p = printer.NewPrinter(printerOptions, {
        -- !!!
    }, emitContext)

    local declarationMapOptions = core.NewCompilerOptions({
        sourceMap = emitDeclarationMap and Tristate.TSTrue or Tristate.TSFalse,
        sourceRoot = options.sourceRoot,
        mapRoot = options.mapRoot,
        -- Explicitly do not pass through either inline option.
    })
    self:printSourceFile(declarationFilePath, declarationMapPath, sourceFile, p, declarationMapOptions, compiler.shouldEmitSourceMaps(declarationMapOptions, sourceFile))
    done()
end

function emitter:printSourceFile(jsFilePath, sourceMapFilePath, sourceFile, printer_, mapOptions, shouldEmitSourceMaps)
    -- !!! sourceMapGenerator
    local options = self.host:Options()
    local sourceMapGenerator = nil
    if shouldEmitSourceMaps then
        sourceMapGenerator = sourcemap.NewGenerator(
            tspath.GetBaseFileName(tspath.NormalizeSlashes(jsFilePath)),
            compiler.getSourceRoot(mapOptions),
            self:getSourceMapDirectory(mapOptions, jsFilePath, sourceFile),
            tspath.NewComparePathsOptions(self.host:UseCaseSensitiveFileNames(), self.host:GetCurrentDirectory())
        )
    end

    printer_:Write(sourceFile, sourceFile, self.writer, sourceMapGenerator)

    local sourceMapUrlPos = -1
    if sourceMapGenerator ~= nil then
        if core.Tristate_IsTrue(mapOptions.sourceMap) or core.Tristate_IsTrue(mapOptions.inlineSourceMap) then
            self.emitResult.sourceMaps = core.Append(self.emitResult.sourceMaps, {
                inputSourceFileNames = sourceMapGenerator:Sources(),
                sourceMap = sourceMapGenerator:RawSourceMap(),
                generatedFile = jsFilePath,
            })
        end

        local sourceMappingURL = self:getSourceMappingURL(
            mapOptions,
            sourceMapGenerator,
            jsFilePath,
            sourceMapFilePath,
            sourceFile
        )

        if #sourceMappingURL > 0 then
            if not self.writer:IsAtStartOfLine() then
                self.writer:RawWrite(options.newLine == core.NewLineKind.CRLF and "\r\n" or "\n")
            end
            sourceMapUrlPos = self.writer:GetTextPos()
            self.writer:WriteComment("//# sourceMappingURL=")
            self.writer:WriteComment(sourceMappingURL)
        end

        -- Write the source map
        if #sourceMapFilePath > 0 then
            local sourceMap = sourceMapGenerator:String()
            local err = self:writeText(sourceMapFilePath, sourceMap, compiler.newWriteFileData({ sourceFile = self.sourceFile }))
            if err ~= nil then
                self.emitterDiagnostics:Add(ast.NewCompilerDiagnostic(diagnostics.Could_not_write_file_0_Colon_1, jsFilePath, tostring(err)))
            else
                self.emitResult.emittedFiles = core.Append(self.emitResult.emittedFiles, sourceMapFilePath)
            end
        end
    else
        self.writer:WriteLine()
    end

    -- Write the output file
    local text = self.writer:String()
    if core.Tristate_IsTrue(options.emitBOM) then
        text = stringutil.AddUTF8ByteOrderMark(text)
    end
    local data = compiler.newWriteFileData({
        sourceMapUrlPos = sourceMapUrlPos,
        diagnostics = self.emitterDiagnostics:GetDiagnostics(),
        sourceFile = self.sourceFile,
    })
    local err = self:writeText(jsFilePath, text, data)
    local skippedDtsWrite = data.skippedDtsWrite
    if err ~= nil then
        self.emitterDiagnostics:Add(ast.NewCompilerDiagnostic(diagnostics.Could_not_write_file_0_Colon_1, jsFilePath, tostring(err)))
    elseif not skippedDtsWrite then
        self.emitResult.emittedFiles = core.Append(self.emitResult.emittedFiles, jsFilePath)
    end

    -- Reset state
    self.writer:Clear()
end

-- Returns an error (nil on success).
function emitter:writeText(fileName, text, data)
    if self.writeFile ~= nil then
        return self.writeFile(fileName, text, data)
    end
    return self.host:WriteFile(fileName, text)
end

function compiler.shouldEmitSourceMaps(mapOptions, sourceFile)
    return (core.Tristate_IsTrue(mapOptions.sourceMap) or core.Tristate_IsTrue(mapOptions.inlineSourceMap)) and
        not tspath.FileExtensionIs(sourceFile:FileName(), tspath.ExtensionJson)
end

function compiler.getSourceRoot(mapOptions)
    -- Normalize source root and make sure it has trailing "/" so that it can be used to combine paths with the
    -- relative paths of the sources list in the sourcemap
    local sourceRoot = tspath.NormalizeSlashes(mapOptions.sourceRoot or "")
    if #sourceRoot > 0 then
        sourceRoot = tspath.EnsureTrailingDirectorySeparator(sourceRoot)
    end
    return sourceRoot
end

function emitter:getSourceMapDirectory(mapOptions, filePath, sourceFile)
    if #(mapOptions.sourceRoot or "") > 0 then
        return self.host:CommonSourceDirectory()
    end
    if #(mapOptions.mapRoot or "") > 0 then
        local sourceMapDir = tspath.NormalizeSlashes(mapOptions.mapRoot)
        if sourceFile ~= nil then
            -- For modules or multiple emit files the mapRoot will have directory structure like the sources
            -- So if src\a.ts and src\lib\b.ts are compiled together user would be moving the maps into mapRoot\a.js.map and mapRoot\lib\b.js.map
            sourceMapDir = tspath.GetDirectoryPath(outputpaths.GetSourceFilePathInNewDir(
                sourceFile:FileName(),
                sourceMapDir,
                self.host:GetCurrentDirectory(),
                self.host:CommonSourceDirectory(),
                self.host:UseCaseSensitiveFileNames()
            ))
        end
        if tspath.GetRootLength(sourceMapDir) == 0 then
            -- The relative paths are relative to the common directory
            sourceMapDir = tspath.CombinePaths(self.host:CommonSourceDirectory(), sourceMapDir)
        end
        return sourceMapDir
    end
    return tspath.GetDirectoryPath(tspath.NormalizePath(filePath))
end

function emitter:getSourceMappingURL(mapOptions, sourceMapGenerator, filePath, sourceMapFilePath, sourceFile)
    if core.Tristate_IsTrue(mapOptions.inlineSourceMap) then
        -- Encode the sourceMap into the sourceMap url
        return sourceMapGenerator:Base64DataURL()
    end

    local sourceMapFile = tspath.GetBaseFileName(tspath.NormalizeSlashes(sourceMapFilePath))
    if #(mapOptions.mapRoot or "") > 0 then
        local sourceMapDir = tspath.NormalizeSlashes(mapOptions.mapRoot)
        if sourceFile ~= nil then
            -- For modules or multiple emit files the mapRoot will have directory structure like the sources
            -- So if src\a.ts and src\lib\b.ts are compiled together user would be moving the maps into mapRoot\a.js.map and mapRoot\lib\b.js.map
            sourceMapDir = tspath.GetDirectoryPath(outputpaths.GetSourceFilePathInNewDir(
                sourceFile:FileName(),
                sourceMapDir,
                self.host:GetCurrentDirectory(),
                self.host:CommonSourceDirectory(),
                self.host:UseCaseSensitiveFileNames()
            ))
        end
        if tspath.GetRootLength(sourceMapDir) == 0 then
            -- The relative paths are relative to the common directory
            sourceMapDir = tspath.CombinePaths(self.host:CommonSourceDirectory(), sourceMapDir)
            return stringutil.EncodeURI(
                tspath.GetRelativePathToDirectoryOrUrl(
                    tspath.GetDirectoryPath(tspath.NormalizePath(filePath)), -- get the relative sourceMapDir path based on jsFilePath
                    tspath.CombinePaths(sourceMapDir, sourceMapFile), -- this is where user expects to see sourceMap
                    true, -- isAbsolutePathAnUrl
                    tspath.NewComparePathsOptions(self.host:UseCaseSensitiveFileNames(), self.host:GetCurrentDirectory())
                )
            )
        else
            return stringutil.EncodeURI(tspath.CombinePaths(sourceMapDir, sourceMapFile))
        end
    end
    return stringutil.EncodeURI(sourceMapFile)
end

-- SourceFileMayBeEmittedHost interface: Options(), GetProjectReferenceFromSource(path),
-- IsSourceFileFromExternalLibrary(file), GetCurrentDirectory(), UseCaseSensitiveFileNames(), SourceFiles().

function compiler.sourceFileMayBeEmitted(sourceFile, host, forceDtsEmit, forceJsEmit)
    -- TODO: move this to outputpaths?
    local options = host:Options()
    -- Js files are emitted only if option is enabled
    if not forceJsEmit and core.Tristate_IsTrue(options.noEmitForJsFiles) and ast.IsSourceFileJS(sourceFile) then
        return false
    end

    -- Declaration files are not emitted
    if sourceFile.isDeclarationFile then
        return false
    end

    -- Runtime output for content-mapped files is owned by the external content mapper or build tool. Only
    -- include them in the emit set when their transformed TypeScript can produce declarations.
    if sourceFile:ContentMapper() ~= "" and not forceDtsEmit and not options:GetEmitDeclarations() then
        return false
    end

    -- Source file from node_modules are not emitted
    if host:IsSourceFileFromExternalLibrary(sourceFile) then
        return false
    end

    -- forcing dts emit => file needs to be emitted
    if forceDtsEmit or forceJsEmit then
        return true
    end

    -- Check other conditions for file emit
    -- Source files from referenced projects are not emitted
    if host:GetProjectReferenceFromSource(sourceFile:Path()) ~= nil then
        return false
    end

    -- Any non json file should be emitted
    if not ast.IsJsonSourceFile(sourceFile) then
        return true
    end

    -- Json file is not emitted if outDir is not specified
    if options.outDir == "" then
        return false
    end

    -- Otherwise, if rootDir is specified or a config file exists, we know the common source directory and can check if the file would be emitted in the same location
    if options.rootDir ~= "" or options.configFilePath ~= "" then
        local commonDir = tspath.GetNormalizedAbsolutePath(outputpaths.GetCommonSourceDirectory(options, function() return nil end, host:GetCurrentDirectory(), host:UseCaseSensitiveFileNames(), nil), host:GetCurrentDirectory())
        local outputPath = outputpaths.GetSourceFilePathInNewDirWorker(sourceFile:FileName(), options.outDir, host:GetCurrentDirectory(), commonDir, host:UseCaseSensitiveFileNames())
        if tspath.ComparePaths(sourceFile:FileName(), outputPath, tspath.NewComparePathsOptions(host:UseCaseSensitiveFileNames(), host:GetCurrentDirectory())) == 0 then
            return false
        end
    end

    return true
end

function compiler.getSourceFilesToEmit(host, targetSourceFiles, forceDtsEmit, forceJsEmit)
    if targetSourceFiles == nil then
        targetSourceFiles = host:SourceFiles()
    end
    return core.Filter(targetSourceFiles, function(sourceFile)
        return compiler.sourceFileMayBeEmitted(sourceFile, host, forceDtsEmit, forceJsEmit)
    end)
end

function compiler.isSourceFileNotJson(file)
    return not ast.IsJsonSourceFile(file)
end

function compiler.getDeclarationDiagnostics(host, file)
    -- TODO: use p.getSourceFilesToEmit cache
    local fullFiles = core.Filter(compiler.getSourceFilesToEmit(host, { file }, false, false), compiler.isSourceFileNotJson)
    if not core.Some(fullFiles, function(f) return f == file end) then
        return {}
    end
    local options = host:Options()
    local transform = declarations.NewDeclarationTransformer(host, nil, options, "", "")
    transform:TransformSourceFile(file)
    return transform:GetDiagnostics()
end
