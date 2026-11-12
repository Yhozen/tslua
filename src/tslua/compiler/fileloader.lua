local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local module = require("tslua.module")
local spanmap = require("tslua.spanmap")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind

-- libResolution: { libraryName, resolution, trace }

-- maxContentMapperFailures is the number of transform failures a single content mapper may accumulate
-- before it is disabled for the rest of the program.
compiler.maxContentMapperFailures = 5

-- LibFile: { name, path, replaced }
function compiler.newLibFile(name, path, replaced)
    return { name = name, path = path, replaced = replaced }
end

-- sourceFileFromReferenceDiagnostic: { message, args }

local fileLoader = {}
fileLoader.__index = fileLoader
compiler.fileLoader = fileLoader

-- redirectsFile implements ast.HasFileName.
local redirectsFile = {}
redirectsFile.__index = redirectsFile
compiler.redirectsFile = redirectsFile

function compiler.newRedirectsFile(index, fileName, path, target)
    return setmetatable({ index = index, fileName = fileName, path = path, target = target }, redirectsFile)
end

-- DuplicateSourceFile: { parseOptions, contentMapperParseOptions, hash, scriptKind, contentMapper,
--   isContentMapperFailureStub }

function redirectsFile:FileName()
    return self.fileName
end

function redirectsFile:Path()
    return self.path
end

-- processedFiles fields (embedded in Program): resolver, files, duplicateSourceFiles, filesByPath,
-- projectReferenceFileMapper, missingFiles, resolvedModules, typeResolutionsInFile, sourceFileMetaDatas,
-- jsxRuntimeImportSpecifiers, importHelpersImportSpecifiers, libFiles, sourceFilesFoundSearchingNodeModules,
-- includeProcessor, outputFileToProjectReferenceSource, redirectTargetsMap, redirectFilesByPath,
-- contentMapperDiagnostics, finishedProcessing.

-- jsxRuntimeImportSpecifier: { moduleReference, specifier }

-- Go (*ImportAttributesNode).GetResolutionModeOverride accepts a nil receiver.
local function getResolutionModeOverride(attributes)
    if attributes == nil then
        return ModuleKind.ResolutionModeNone, false
    end
    return attributes:GetResolutionModeOverride()
end

local function infoExists(entry)
    return entry ~= nil and entry.contents ~= nil
end

function compiler.processAllProgramFiles(opts, singleThreaded)
    local compilerOptions = opts.config:CompilerOptions()
    local rootFiles = opts.config:FileNames()
    local supportedExtensions = tsoptions.GetSupportedExtensions(compilerOptions, opts.config:ContentMapperExtensions())
    local supportedExtensionsWithJsonIfResolveJsonModule = tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(compilerOptions, supportedExtensions)
    local maxNodeModuleJsDepth = 0
    if opts.config:CompilerOptions().maxNodeModuleJsDepth ~= nil then
        maxNodeModuleJsDepth = opts.config:CompilerOptions().maxNodeModuleJsDepth
    end
    local loader = setmetatable({
        opts = opts,
        resolver = nil,
        defaultLibraryPath = tspath.GetNormalizedAbsolutePath(opts.host:DefaultLibraryPath(), opts.host:GetCurrentDirectory()),
        comparePathsOptions = tspath.NewComparePathsOptions(
            opts.host:FS():UseCaseSensitiveFileNames(),
            opts.host:GetCurrentDirectory()
        ),
        filesParser = compiler.newFilesParser(core.NewWorkGroup(singleThreaded), maxNodeModuleJsDepth),
        rootTasks = {},
        supportedExtensions = supportedExtensions,
        supportedExtensionsWithJsonIfResolveJsonModule = supportedExtensionsWithJsonIfResolveJsonModule,
        contentMapperExtensions = opts.config:ContentMapperExtensions(),
        totalFileCount = 0,
        libFileCount = 0,
        factory = nil,
        projectReferenceFileMapper = nil,
        dtsDirectories = {},
        pathForLibFileCache = {},
        pathForLibFileResolutions = {},
        contentMapperFailures = nil,
        contentMapperInitFailed = {},
        contentMapperDiagnostics = nil,
    }, fileLoader)
    loader:addProjectReferenceTasks(singleThreaded)
    loader.resolver = module.NewResolver(loader.projectReferenceFileMapper.host, compilerOptions, opts.typingsLocation, opts.projectName, opts.config:ContentMapperExtensions())
    for index1, rootFile in ipairs(rootFiles or {}) do
        loader:addRootFileTask(rootFile, nil, compiler.newFileIncludeReason(compiler.fileIncludeKindRootFile, index1 - 1))
    end
    if core.Len(rootFiles) > 0 and core.Tristate_IsFalseOrUnknown(compilerOptions.noLib) then
        if compilerOptions.lib == nil then
            local name = tsoptions.GetDefaultLibFileName(compilerOptions)
            local libFile = loader:pathForLibFile(name)
            loader:addRootTask(libFile.path, libFile, compiler.newFileIncludeReason(compiler.fileIncludeKindLibFile, nil))
        else
            for index1, lib in ipairs(compilerOptions.lib) do
                local name, ok = tsoptions.GetLibFileName(lib)
                if ok then
                    local libFile = loader:pathForLibFile(name)
                    loader:addRootTask(libFile.path, libFile, compiler.newFileIncludeReason(compiler.fileIncludeKindLibFile, index1 - 1))
                end
                -- !!! error on unknown name
            end
        end
    end

    if core.Len(rootFiles) > 0 then
        loader:addAutomaticTypeDirectiveTasks()
    end

    loader.filesParser:parse(loader, loader.rootTasks)

    -- Clear out loader and host to ensure its not used post program creation
    loader.projectReferenceFileMapper.loader = nil
    loader.projectReferenceFileMapper.host = nil

    return loader.filesParser:getProcessedFiles(loader)
end

function fileLoader:toPath(file)
    return tspath.ToPath(file, self.opts.host:GetCurrentDirectory(), self.opts.host:FS():UseCaseSensitiveFileNames())
end

function fileLoader:addRootTask(fileName, libFile, includeReason)
    local absPath = tspath.GetNormalizedAbsolutePath(fileName, self.opts.host:GetCurrentDirectory())
    if core.Tristate_IsTrue(self.opts.config:CompilerOptions().allowNonTsExtensions) or tspath.HasExtension(absPath) then
        self.rootTasks[#self.rootTasks + 1] = compiler.newParseTask({
            normalizedFilePath = absPath,
            libFile = libFile,
            includeReason = includeReason,
        })
    end
end

function fileLoader:addRootFileTask(fileName, libFile, includeReason)
    local currDir = self.opts.host:GetCurrentDirectory()
    local absPath = tspath.GetNormalizedAbsolutePath(fileName, currDir)
    local containingFile = currDir
    if self.opts.config.configFile ~= nil then
        containingFile = tspath.GetNormalizedAbsolutePath(self.opts.config.configFile.sourceFile:FileName(), currDir)
    end
    local resolvedFile, diagnostic = self:getSourceFileFromReference(absPath, fileName, containingFile, includeReason)
    local rootTask = compiler.newParseTask({
        normalizedFilePath = resolvedFile,
        libFile = libFile,
        includeReason = includeReason,
    })
    if diagnostic ~= nil then
        rootTask.normalizedFilePath = absPath
        rootTask.failedLookup = true
        rootTask.processingDiagnostics = { compiler.newProcessingDiagnostic(
            compiler.processingDiagnosticKindExplainingFileInclude,
            compiler.newIncludeExplainingDiagnostic({
                diagnosticReason = includeReason,
                message = diagnostic.message,
                args = diagnostic.args,
            })
        ) }
    end
    self.rootTasks[#self.rootTasks + 1] = rootTask
end

function fileLoader:addAutomaticTypeDirectiveTasks()
    local containingDirectory
    local compilerOptions = self.opts.config:CompilerOptions()
    if compilerOptions.configFilePath ~= "" then
        containingDirectory = tspath.GetDirectoryPath(compilerOptions.configFilePath)
    else
        containingDirectory = self.opts.host:GetCurrentDirectory()
    end
    local containingFileName = tspath.CombinePaths(containingDirectory, module.InferredTypesContainingFile)
    self.rootTasks[#self.rootTasks + 1] = compiler.newParseTask({
        normalizedFilePath = containingFileName,
        isForAutomaticTypeDirective = true,
    })
end

-- Returns toParse ([]resolvedRef), typeResolutionsInFile (ModeAwareCache), typeResolutionsTrace, pDiagnostics.
function fileLoader:resolveAutomaticTypeDirectives(containingFileName)
    local toParse = nil
    local typeResolutionsInFile = nil
    local typeResolutionsTrace = nil
    local pDiagnostics = nil
    local automaticTypeDirectiveNames = module.GetAutomaticTypeDirectiveNames(self.opts.config:CompilerOptions(), self.opts.host)
    if core.Len(automaticTypeDirectiveNames) ~= 0 then
        toParse = {}
        typeResolutionsInFile = {}
        for _, name in ipairs(automaticTypeDirectiveNames) do
            -- Under node16/nodenext module resolution, load `types`/ata include names as cjs resolution results by passing an `undefined` mode.
            -- Under bundler module resolution, this also triggers the "import" condition to be used.
            local resolutionMode = ModuleKind.ResolutionModeNone
            local resolved, trace = self.resolver:ResolveTypeReferenceDirective(name, containingFileName, resolutionMode, nil)
            typeResolutionsInFile[compiler.modeAwareCacheKey(name, resolutionMode)] = resolved
            typeResolutionsTrace = core.AppendAll(typeResolutionsTrace, trace)
            if resolved:IsResolved() then
                toParse[#toParse + 1] = compiler.newResolvedRef({
                    fileName = resolved.resolvedFileName,
                    increaseDepth = resolved.isExternalLibraryImport,
                    elideOnDepth = false,
                    includeReason = compiler.newFileIncludeReason(
                        compiler.fileIncludeKindAutomaticTypeDirectiveFile,
                        compiler.newAutomaticTypeDirectiveFileData(name, resolved.packageId)
                    ),
                    packageId = resolved.packageId,
                })
            else
                pDiagnostics = core.Append(pDiagnostics, compiler.newProcessingDiagnostic(
                    compiler.processingDiagnosticKindExplainingFileInclude,
                    compiler.newIncludeExplainingDiagnostic({
                        diagnosticReason = compiler.newFileIncludeReason(
                            compiler.fileIncludeKindAutomaticTypeDirectiveFile,
                            compiler.newAutomaticTypeDirectiveFileData(name, nil)
                        ),
                        message = diagnostics.Cannot_find_type_definition_file_for_0,
                        args = { name },
                    })
                ))
            end
        end
    end
    return toParse, typeResolutionsInFile, typeResolutionsTrace, pDiagnostics
end

function fileLoader:addProjectReferenceTasks(singleThreaded)
    self.projectReferenceFileMapper = compiler.newProjectReferenceFileMapper(self.opts, self.opts.host)
    local projectReferences = self.opts.config:ResolvedProjectReferencePaths()
    if core.Len(projectReferences) == 0 then
        return
    end

    local parser = compiler.newProjectReferenceParser(self, core.NewWorkGroup(singleThreaded))
    local rootTasks = compiler.createProjectReferenceParseTasks(projectReferences)
    parser:parse(rootTasks)
end

function fileLoader:sortLibs(libFiles)
    -- slices.SortFunc is not stable; priorities are distinct per lib name except for the
    -- non-default-lib bucket, where we keep the input order.
    local decorated = {}
    for i, f in ipairs(libFiles) do
        decorated[i] = { f = f, p = self:getDefaultLibFilePriority(f), i = i }
    end
    table.sort(decorated, function(a, b)
        if a.p ~= b.p then
            return a.p < b.p
        end
        return a.i < b.i
    end)
    for i, d in ipairs(decorated) do
        libFiles[i] = d.f
    end
end

function fileLoader:getDefaultLibFilePriority(a)
    -- defaultLibraryPath and a.FileName() are absolute and normalized; a prefix check should suffice.
    local defaultLibraryPath = tspath.RemoveTrailingDirectorySeparator(self.defaultLibraryPath)
    local aFileName = a:FileName()

    if compiler.hasPrefix(aFileName, defaultLibraryPath) and #aFileName > #defaultLibraryPath and string.byte(aFileName, #defaultLibraryPath + 1) == string.byte("/") then
        -- avoid tspath.GetBaseFileName; we know these paths are already absolute and normalized.
        local basename = string.match(aFileName, "[^/]*$")
        if basename == "lib.d.ts" or basename == "lib.es6.d.ts" then
            return 0
        end
        local name = compiler.trimSuffix(compiler.trimPrefix(basename, "lib."), ".d.ts")
        for i, lib in ipairs(tsoptions.Libs) do
            if lib == name then
                return i
            end
        end
    end
    return #tsoptions.Libs + 2
end

function fileLoader:loadSourceFileMetaData(fileName)
    local packageJsonScope = self.resolver:GetPackageScopeForPath(tspath.GetDirectoryPath(fileName))
    local moduleResolutionKind = self.opts.config:CompilerOptions():GetModuleResolutionKind()

    local packageJsonType, packageJsonDirectory = "", ""
    if infoExists(packageJsonScope) then
        packageJsonDirectory = packageJsonScope.packageDirectory
        local value, ok = packageJsonScope.contents.type:GetValue()
        if ok then
            if not tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionMts, tspath.ExtensionCts, tspath.ExtensionMjs, tspath.ExtensionCjs }) and
                ModuleResolutionKind.Node16 <= moduleResolutionKind and moduleResolutionKind <= ModuleResolutionKind.NodeNext or compiler.contains(fileName, "/node_modules/") then
                packageJsonType = value
            end
        end
    end

    local impliedNodeFormat = ast.GetImpliedNodeFormatForFile(fileName, packageJsonType)
    return compiler.newSourceFileMetaData(packageJsonType, packageJsonDirectory, impliedNodeFormat)
end

-- ast.SourceFileMetaData value struct.
function compiler.newSourceFileMetaData(packageJsonType, packageJsonDirectory, impliedNodeFormat)
    return {
        packageJsonType = packageJsonType or "",
        packageJsonDirectory = packageJsonDirectory or "",
        impliedNodeFormat = impliedNodeFormat or ModuleKind.ResolutionModeNone,
    }
end

function fileLoader:parseSourceFile(t)
    local path = self:toPath(t.normalizedFilePath)
    local options = self.projectReferenceFileMapper:getCompilerOptionsForFile(t)
    local parseOptions = {
        fileName = t.normalizedFilePath,
        path = path,
        externalModuleIndicatorOptions = ast.GetExternalModuleIndicatorOptions(t.normalizedFilePath, options, t.metadata),
    }
    if tspath.FileExtensionIsOneOf(t.normalizedFilePath, self.contentMapperExtensions or {}) then
        return self:parseContentMappedFile(parseOptions)
    end
    return self.opts.host:GetSourceFile(parseOptions)
end

-- parseContentMappedFile produces a content-mapped virtual source file via the host's content
-- mapper, preserving the original file name and retaining the untransformed text on the
-- source file. Content mapper extensions only reach the parser when content mappers are configured.
--
-- When initialization fails, one program diagnostic is reported and the mapper is not attempted for
-- subsequent files. Other failures produce per-file diagnostics and count toward a failure budget; after
-- maxContentMapperFailures, one program diagnostic reports that the mapper was disabled and subsequent
-- files are silently substituted with empty files. It returns nil only if the file cannot be read.
function fileLoader:parseContentMappedFile(opts)
    local mapper = self.opts.config:GetContentMapperForFileName(opts.fileName)
    local label = mapper:DiagnosticName()
    local transformIdentity = self:getContentMapperTransformIdentity(mapper)
    if self:contentMapperUnavailable(mapper) then
        -- The mapper failed initialization or exceeded its failure budget; add the file empty without re-reporting.
        return self:emptyContentMappedFile(opts, mapper:Identity(), transformIdentity)
    end
    local files, err = self.opts.host:GetContentMappedSourceFiles(opts, mapper)
    if err ~= nil then
        local sourceFile = self:emptyContentMappedFile(opts, mapper:Identity(), transformIdentity)
        local transformError, ok = contentmapper.ErrorsAsType(err, contentmapper.TransformError)
        if ok and transformError.kind == contentmapper.TransformErrorKind.Initialize then
            self:recordContentMapperInitializationFailure(mapper, label, transformError)
            return sourceFile
        end
        if self:recordContentMapperFailure(mapper, label) then
            local diagnostic
            local problem, isMappingError = contentmapper.ErrorsAsType(err, spanmap.MappingError)
            if isMappingError then
                diagnostic = compiler.contentMapperMappingDiagnostic(sourceFile, label, problem)
            else
                diagnostic = compiler.contentMapperTransformDiagnostic(sourceFile, label, err)
            end
            sourceFile:SetDiagnostics(core.Append(core.Slice(sourceFile:Diagnostics(), 0), diagnostic))
        end
        return sourceFile
    end
    return files.canonical
end

function compiler.contentMapperTransformDiagnostic(file, label, err)
    local collision, isCollision = contentmapper.ErrorsAsType(err, contentmapper.SupplementalFileCollisionError)
    if isCollision then
        return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.Content_mapper_supplemental_output_file_0_conflicts_with_an_existing_file, collision.fileName)
    end
    local transformError, ok = contentmapper.ErrorsAsType(err, contentmapper.TransformError)
    if ok then
        local TransformErrorKind = contentmapper.TransformErrorKind
        local kind = transformError.kind
        if kind == TransformErrorKind.Initialize then
            local initializeError, isInitializeError = contentmapper.ErrorsAsType(transformError, contentmapper.InitializeError)
            if isInitializeError then
                local InitializeErrorKind = contentmapper.InitializeErrorKind
                local ikind = initializeError.kind
                if ikind == InitializeErrorKind.ProtocolVersion then
                    return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_uses_unsupported_protocol_version_0_expected_version_1, initializeError.protocolVersion, contentmapper.ProtocolVersion)
                elseif ikind == InitializeErrorKind.PositionEncoding then
                    return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_selected_unsupported_position_encoding_0, initializeError.positionEncoding)
                elseif ikind == InitializeErrorKind.EmptyDiagnosticSource then
                    return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_diagnostic_source_must_not_be_empty)
                elseif ikind == InitializeErrorKind.ReservedDiagnosticSource then
                    return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_diagnostic_source_0_is_reserved_by_TypeScript, initializeError.diagnosticSource)
                end
            end
            return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_process_could_not_be_started_or_initialized)
        elseif kind == TransformErrorKind.Project then
            return compiler.contentMapperTransformDiagnosticChain(file, label, compiler.ContentMapperProjectErrorDiagnostic(transformError))
        elseif kind == TransformErrorKind.Request then
            return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_process_failed_while_handling_the_transform_request)
        elseif kind == TransformErrorKind.Response then
            local extensionError, isExtensionError = contentmapper.ErrorsAsType(transformError, contentmapper.InvalidVirtualExtensionError)
            if isExtensionError then
                return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_returned_an_output_with_unsupported_virtual_extension_0, extensionError.extension)
            end
            local directiveError, isDirectiveError = contentmapper.ErrorsAsType(transformError, contentmapper.DiagnosticDirectiveError)
            if isDirectiveError then
                local DiagnosticDirectiveErrorKind = contentmapper.DiagnosticDirectiveErrorKind
                local dkind = directiveError.kind
                local detail = nil
                if dkind == DiagnosticDirectiveErrorKind.InvalidRange then
                    detail = ast.NewCompilerDiagnostic(diagnostics.Diagnostic_directive_0_returned_by_the_content_mapper_has_an_invalid_range, directiveError.index)
                elseif dkind == DiagnosticDirectiveErrorKind.InvalidPolicy then
                    detail = ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_returned_a_diagnostic_directive_with_invalid_policy_0, directiveError.policy)
                elseif dkind == DiagnosticDirectiveErrorKind.ExpectMissingUnusedDiagnostic then
                    detail = ast.NewCompilerDiagnostic(diagnostics.Diagnostic_directive_0_returned_by_the_content_mapper_must_specify_unusedExpectDirectiveIndex_when_there_is_not_exactly_one_unusedExpectDirectiveDiagnostics_entry, directiveError.index)
                elseif dkind == DiagnosticDirectiveErrorKind.InvalidUnusedDiagnosticIndex then
                    detail = ast.NewCompilerDiagnostic(diagnostics.Diagnostic_directive_0_returned_by_the_content_mapper_has_an_invalid_unusedExpectDirectiveIndex, directiveError.index)
                elseif dkind == DiagnosticDirectiveErrorKind.Overlap then
                    detail = ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_returned_diagnostic_directives_with_overlapping_virtual_ranges)
                end
                if detail ~= nil then
                    if directiveError.supplementalIndex >= 0 then
                        detail = ast.NewDiagnosticChain(detail, diagnostics.The_invalid_diagnostic_directive_is_in_supplemental_output_0_returned_by_the_content_mapper, directiveError.supplementalIndex)
                    end
                    return compiler.contentMapperTransformDiagnosticWithDetail(file, label, detail)
                end
            end
            return compiler.contentMapperTransformDiagnosticChain(file, label, diagnostics.The_content_mapper_returned_an_invalid_transform_response)
        elseif kind == TransformErrorKind.Mappings then
            return ast.NewDiagnostic(file, core.NewTextRange(0, 0), diagnostics.The_content_mapper_0_did_not_provide_the_required_position_mappings, label)
        end
    end
    return ast.NewDiagnostic(file, core.NewTextRange(0, 0), diagnostics.The_content_mapper_0_failed_to_transform_this_file, label)
end

-- ContentMapperProjectErrorDiagnostic returns the localized diagnostic message for a project setup error.
function compiler.ContentMapperProjectErrorDiagnostic(err)
    local projectError, ok = contentmapper.ErrorsAsType(err, contentmapper.ProjectError)
    if ok then
        local ProjectErrorKind = contentmapper.ProjectErrorKind
        local kind = projectError.kind
        if kind == ProjectErrorKind.MalformedResponse then
            return diagnostics.The_content_mapper_returned_a_project_response_that_could_not_be_decoded
        elseif kind == ProjectErrorKind.MissingConfigIdentity then
            return diagnostics.The_content_mapper_did_not_return_configIdentity_which_is_required_when_the_content_mapper_has_dynamicConfig_Colon_true_in_its_package_json
        elseif kind == ProjectErrorKind.NonAbsoluteWatchedFile then
            return diagnostics.The_content_mapper_returned_a_non_absolute_path_in_watchedFiles
        elseif kind == ProjectErrorKind.UnexpectedConfigIdentity then
            return diagnostics.The_content_mapper_returned_configIdentity_which_is_only_allowed_when_it_declares_dynamicConfig_Colon_true_in_its_package_json
        elseif kind == ProjectErrorKind.UnexpectedWatchedFiles then
            return diagnostics.The_content_mapper_returned_watchedFiles_which_is_only_allowed_when_it_declares_dynamicConfig_Colon_true_in_its_package_json
        end
    end
    return diagnostics.The_content_mapper_process_failed_while_handling_the_project_request
end

function compiler.contentMapperTransformDiagnosticChain(file, label, message, ...)
    return compiler.contentMapperTransformDiagnosticWithDetail(file, label, ast.NewCompilerDiagnostic(message, ...))
end

function compiler.contentMapperTransformDiagnosticWithDetail(file, label, detail)
    return ast.NewDiagnostic(
        file,
        core.NewTextRange(0, 0),
        diagnostics.The_content_mapper_0_failed_to_transform_this_file,
        label
    ):AddMessageChain(detail)
end

-- contentMapperMappingDiagnostic builds the diagnostic reported against a mapper that produced an
-- invalid span map, including the offsets involved so the mapper's author can locate the problem.
function compiler.contentMapperMappingDiagnostic(file, label, problem)
    local loc = core.NewTextRange(0, 0)
    local MappingErrorKind = spanmap.MappingErrorKind
    local kind = problem.kind
    if kind == MappingErrorKind.Overlap then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_overlapping_or_out_of_order_position_mappings_near_virtual_offset_1, label, problem.virtualPos)
    elseif kind == MappingErrorKind.OutOfBounds then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_a_position_mapping_that_points_outside_the_original_content_original_offset_1, label, problem.originalPos)
    elseif kind == MappingErrorKind.VerbatimMismatch then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_a_verbatim_mapping_that_does_not_match_the_original_content_virtual_offset_1_original_offset_2, label, problem.virtualPos, problem.originalPos)
    elseif kind == MappingErrorKind.Kind then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_a_position_mapping_with_an_invalid_kind_near_virtual_offset_1, label, problem.virtualPos)
    elseif kind == MappingErrorKind.OriginalOverlap then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_overlapping_original_position_mappings_that_are_not_identical_near_original_offset_1, label, problem.originalPos)
    elseif kind == MappingErrorKind.Feature then
        return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_produced_invalid_mapping_features_near_original_offset_1, label, problem.originalPos)
    end
    return ast.NewDiagnostic(file, loc, diagnostics.The_content_mapper_0_did_not_provide_the_required_position_mappings, label)
end

-- emptyContentMappedFile produces an empty TypeScript source file for a content-mapped file whose
-- transform could not be used, retaining the original content for diagnostics. Importers see it as an
-- empty module rather than triggering a "cannot find module" error. It is still marked as content-mapped
-- so it is excluded from emit like a successfully mapped file.
function fileLoader:getContentMapperTransformIdentity(mapper)
    local project = self.opts.host:ContentMapperProject()
    if project ~= nil then
        local identity, err = project:Identity(mapper)
        if err == nil then
            return identity
        end
    end
    return mapper:TransformIdentity(self.opts.config:CompilerOptions()):Hex()
end

function fileLoader:emptyContentMappedFile(opts, mapperIdentity, transformIdentity)
    local content = self.opts.host:FS():ReadFile(opts.fileName)
    local sourceFile = require("tslua.parser").ParseSourceFile(opts, "", core.ScriptKind.TS)
    sourceFile:SetContentMapperInfo({
        contentMapper = mapperIdentity,
        transformIdentity = transformIdentity,
        parseOptions = opts,
        virtualFileName = opts.fileName .. tspath.ExtensionTs,
        originalText = content or "",
    })
    return sourceFile
end

-- ContentMapperInitializationDiagnostic returns a fileless diagnostic for a mapper initialization failure.
function compiler.ContentMapperInitializationDiagnostic(label, err)
    local initializeError, ok = contentmapper.ErrorsAsType(err, contentmapper.InitializeError)
    if ok and label == "" then
        label = initializeError.mapperName
    end
    local diagnostic = ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_0_could_not_be_initialized, label)
    if ok then
        local InitializeErrorKind = contentmapper.InitializeErrorKind
        local kind = initializeError.kind
        if kind == InitializeErrorKind.ProcessStart then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_command_0_could_not_be_started_Colon_1, initializeError.command, initializeError.detail))
        elseif kind == InitializeErrorKind.ProcessExit then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_process_exited_before_responding_to_the_initialize_request_exit_code_0, initializeError.exitCode))
        elseif kind == InitializeErrorKind.NoResponse then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_did_not_respond_to_the_initialize_request_within_0_seconds, initializeError.timeoutSeconds))
        elseif kind == InitializeErrorKind.InvalidResponse then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_returned_an_initialize_response_that_could_not_be_decoded_Colon_0, initializeError.detail))
        elseif kind == InitializeErrorKind.Request then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_s_initialize_request_failed_Colon_0, initializeError.detail))
        elseif kind == InitializeErrorKind.ProtocolVersion then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_uses_unsupported_protocol_version_0_expected_version_1, initializeError.protocolVersion, contentmapper.ProtocolVersion))
        elseif kind == InitializeErrorKind.PositionEncoding then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_selected_unsupported_position_encoding_0, initializeError.positionEncoding))
        elseif kind == InitializeErrorKind.EmptyDiagnosticSource then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_diagnostic_source_must_not_be_empty))
        elseif kind == InitializeErrorKind.ReservedDiagnosticSource then
            return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_diagnostic_source_0_is_reserved_by_TypeScript, initializeError.diagnosticSource))
        end
    end
    return diagnostic:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_process_could_not_be_started_or_initialized))
end

-- ContentMapperProjectDiagnostic returns a fileless diagnostic for project setup or mapper initialization.
function compiler.ContentMapperProjectDiagnostic(err)
    local _, ok = contentmapper.ErrorsAsType(err, contentmapper.InitializeError)
    if ok then
        return compiler.ContentMapperInitializationDiagnostic("", err)
    end
    return ast.NewCompilerDiagnostic(compiler.ContentMapperProjectErrorDiagnostic(err))
end

-- contentMapperUnavailable reports whether mapper failed initialization or exceeded its failure budget.
function fileLoader:contentMapperUnavailable(mapper)
    if mapper == nil then
        return false
    end
    return self.contentMapperInitFailed[mapper] == true or (self.contentMapperFailures ~= nil and (self.contentMapperFailures[mapper] or 0) >= compiler.maxContentMapperFailures)
end

function fileLoader:recordContentMapperInitializationFailure(mapper, label, err)
    if self.contentMapperInitFailed[mapper] then
        return
    end
    self.contentMapperInitFailed[mapper] = true
    self.contentMapperDiagnostics = core.Append(self.contentMapperDiagnostics, compiler.ContentMapperInitializationDiagnostic(label, err))
end

-- recordContentMapperFailure counts a transform failure for mapper. It returns whether the failure
-- should be reported for this file (false once the mapper is already disabled). On the failure that
-- reaches maxContentMapperFailures it appends a single program diagnostic disabling the mapper.
function fileLoader:recordContentMapperFailure(mapper, label)
    if self.contentMapperFailures == nil then
        self.contentMapperFailures = {}
    end
    if (self.contentMapperFailures[mapper] or 0) >= compiler.maxContentMapperFailures then
        return false
    end
    self.contentMapperFailures[mapper] = (self.contentMapperFailures[mapper] or 0) + 1
    if self.contentMapperFailures[mapper] >= compiler.maxContentMapperFailures then
        self.contentMapperDiagnostics = core.Append(self.contentMapperDiagnostics, ast.NewCompilerDiagnostic(
            diagnostics.The_content_mapper_0_failed_1_times_and_will_not_be_used,
            label,
            compiler.maxContentMapperFailures
        ))
    end
    return true
end

function fileLoader:isSupportedExtension(canonicalFileName)
    for _, group in ipairs(self.supportedExtensionsWithJsonIfResolveJsonModule) do
        if tspath.FileExtensionIsOneOf(canonicalFileName, group) then
            return true
        end
    end
    return false
end

local function flattenExtensions(groups)
    local flat = {}
    for _, group in ipairs(groups) do
        for _, ext in ipairs(group) do
            flat[#flat + 1] = ext
        end
    end
    return flat
end

-- Returns (string, *sourceFileFromReferenceDiagnostic).
function fileLoader:getSourceFileFromReference(fileName, referenceText, containingFile, includeReason)
    local options = self.opts.config:CompilerOptions()
    local allowNonTsExtensions = core.Tristate_IsTrue(options.allowNonTsExtensions)
    local diagnosticFileName = tspath.NormalizeSlashes(referenceText)
    local fs = self.opts.host:FS()

    if tspath.HasExtension(fileName) then
        local canonicalFileName = tspath.GetCanonicalFileName(fileName, fs:UseCaseSensitiveFileNames())
        if not allowNonTsExtensions and not self:isSupportedExtension(canonicalFileName) then
            if tspath.HasJSFileExtension(canonicalFileName) then
                return "", { message = diagnostics.File_0_is_a_JavaScript_file_Did_you_mean_to_enable_the_allowJs_option, args = { diagnosticFileName } }
            end
            return "", { message = diagnostics.File_0_has_an_unsupported_extension_The_only_supported_extensions_are_1, args = { diagnosticFileName, "'" .. table.concat(flattenExtensions(self.supportedExtensions), "', '") .. "'" } }
        end

        if not fs:FileExists(fileName) then
            return "", { message = diagnostics.File_0_not_found, args = { diagnosticFileName } }
        end

        if compiler.isReferencedFileReason(includeReason) and tspath.GetCanonicalFileName(containingFile, fs:UseCaseSensitiveFileNames()) == canonicalFileName then
            return "", { message = diagnostics.A_file_cannot_have_a_reference_to_itself }
        end
        return fileName, nil
    end

    if allowNonTsExtensions and fs:FileExists(fileName) then
        return fileName, nil
    end

    if allowNonTsExtensions then
        return "", { message = diagnostics.File_0_not_found, args = { diagnosticFileName } }
    end

    for _, ext in ipairs(self.supportedExtensions[1]) do
        local candidate = fileName .. ext
        if fs:FileExists(candidate) then
            return candidate, nil
        end
    end

    return "", { message = diagnostics.Could_not_resolve_the_path_0_with_the_extensions_Colon_1, args = { diagnosticFileName, "'" .. table.concat(flattenExtensions(self.supportedExtensions), "', '") .. "'" } }
end

-- Returns (*resolvedRef, *processingDiagnostic).
function fileLoader:resolveTripleslashPathReference(moduleName, containingFile, index)
    local basePath = tspath.GetDirectoryPath(containingFile)
    local referencedFileName = moduleName

    if not tspath.IsRootedDiskPath(moduleName) then
        referencedFileName = tspath.CombinePaths(basePath, moduleName)
    end
    local normalizedFileName = tspath.NormalizePath(referencedFileName)
    local includeReason = compiler.newFileIncludeReason(
        compiler.fileIncludeKindReferenceFile,
        compiler.newReferencedFileData(self:toPath(containingFile), index, nil)
    )

    local resolvedFileName, diagnostic = self:getSourceFileFromReference(
        normalizedFileName,
        moduleName,
        containingFile,
        includeReason
    )
    if diagnostic ~= nil then
        return nil, compiler.newProcessingDiagnostic(
            compiler.processingDiagnosticKindExplainingFileInclude,
            compiler.newIncludeExplainingDiagnostic({
                diagnosticReason = includeReason,
                message = diagnostic.message,
                args = diagnostic.args,
            })
        )
    end

    return compiler.newResolvedRef({
        fileName = resolvedFileName,
        includeReason = includeReason,
    }), nil
end

function fileLoader:resolveTypeReferenceDirectives(t)
    local file = t.file
    if core.Len(file.typeReferenceDirectives) == 0 then
        return
    end
    local meta = t.metadata

    local typeResolutionsInFile = {}
    local typeResolutionsTrace = nil
    for index1, ref in ipairs(file.typeReferenceDirectives) do
        local index = index1 - 1
        local redirect, fileName = self.projectReferenceFileMapper:getRedirectForResolution(file)
        local resolutionMode = compiler.getModeForTypeReferenceDirectiveInFile(ref, file, meta, module.GetCompilerOptionsWithRedirect(self.opts.config:CompilerOptions(), redirect))
        local resolved, trace = self.resolver:ResolveTypeReferenceDirective(ref.fileName, fileName, resolutionMode, redirect)
        typeResolutionsInFile[compiler.modeAwareCacheKey(ref.fileName, resolutionMode)] = resolved
        local includeReason = compiler.newFileIncludeReason(
            compiler.fileIncludeKindTypeReferenceDirective,
            compiler.newReferencedFileData(t.path, index, nil)
        )
        typeResolutionsTrace = core.AppendAll(typeResolutionsTrace, trace)

        if resolved:IsResolved() then
            t:addSubTask(compiler.newResolvedRef({
                fileName = resolved.resolvedFileName,
                increaseDepth = resolved.isExternalLibraryImport,
                elideOnDepth = false,
                includeReason = includeReason,
                packageId = resolved.packageId,
            }), nil)
        else
            t.processingDiagnostics = core.Append(t.processingDiagnostics, compiler.newProcessingDiagnostic(
                compiler.processingDiagnosticKindUnknownReference,
                includeReason
            ))
        end
    end

    t.typeResolutionsInFile = typeResolutionsInFile
    t.typeResolutionsTrace = typeResolutionsTrace
end

compiler.externalHelpersModuleNameText = "tslib" -- TODO(jakebailey): dedupe

function fileLoader:resolveImportsAndModuleAugmentations(t)
    local file = t.file
    local meta = t.metadata

    local moduleNames = {}

    local isJavaScriptFile = ast.IsSourceFileJS(file)
    local isExternalModuleFile = ast.IsExternalModule(file)

    local redirect, fileName = self.projectReferenceFileMapper:getRedirectForResolution(file)
    local optionsForFile = module.GetCompilerOptionsWithRedirect(self.opts.config:CompilerOptions(), redirect)
    if isJavaScriptFile or (not file.isDeclarationFile and (optionsForFile:GetIsolatedModules() or isExternalModuleFile)) then
        if core.Tristate_IsTrue(optionsForFile.importHelpers) then
            local specifier = self:createSyntheticImport(compiler.externalHelpersModuleNameText, file)
            moduleNames[#moduleNames + 1] = specifier
            t.importHelpersImportSpecifier = specifier
        end
    end

    if isJavaScriptFile or file.scriptKind == core.ScriptKind.TSX then
        local jsxImport = ast.GetJSXRuntimeImport(ast.GetJSXImplicitImportBase(optionsForFile, file), optionsForFile)
        if jsxImport ~= "" then
            local specifier = self:createSyntheticImport(jsxImport, file)
            moduleNames[#moduleNames + 1] = specifier
            t.jsxRuntimeImportSpecifier = {
                moduleReference = jsxImport,
                specifier = specifier,
            }
        end
    end

    local importsStart = #moduleNames

    local imports = file:Imports() or {}
    for _, imp in ipairs(imports) do
        moduleNames[#moduleNames + 1] = imp
    end
    for _, imp in ipairs(file.moduleAugmentations or {}) do
        if imp.kind == ast.Kind.StringLiteral then
            moduleNames[#moduleNames + 1] = imp
        end
        -- Do nothing if it's an Identifier; we don't need to do module resolution for `declare global`.
    end

    if #moduleNames ~= 0 then
        local resolutionsInFile = {}
        local resolutionsTrace = nil

        for index1, entry in ipairs(moduleNames) do
            local index = index1 - 1
            local moduleName = entry:Text()
            if moduleName == "" then
                goto continue
            end

            do
                local mode = compiler.getModeForUsageLocation(file:FileName(), meta, entry, optionsForFile)
                local resolvedModule, trace = self.resolver:ResolveModuleName(moduleName, fileName, mode, redirect)
                resolutionsInFile[compiler.modeAwareCacheKey(moduleName, mode)] = resolvedModule
                resolutionsTrace = core.AppendAll(resolutionsTrace, trace)

                if not resolvedModule:IsResolved() then
                    goto continue
                end

                local resolvedFileName = resolvedModule.resolvedFileName
                local isFromNodeModulesSearch = resolvedModule.isExternalLibraryImport
                -- Don't treat redirected files as JS files.
                local isJsFile = not resolvedModule.resolvedUsingExtraExtensions and not tspath.FileExtensionIsOneOf(resolvedFileName, tspath.SupportedTSExtensionsWithJsonFlat) and self.projectReferenceFileMapper:getRedirectParsedCommandLineForResolution(ast.NewHasFileName(resolvedFileName, self:toPath(resolvedFileName))) == nil
                local isJsFileFromNodeModules = isFromNodeModulesSearch and isJsFile and compiler.contains(resolvedFileName, "/node_modules/")

                -- add file to program only if:
                -- - resolution was successful
                -- - noResolve is falsy
                -- - module name comes from the list of imports
                -- - it's not a top level JavaScript module that exceeded the search max

                local importIndex = index - importsStart

                local shouldAddFile = moduleName ~= "" and
                    module.GetResolutionDiagnostic(optionsForFile, resolvedModule, file) == nil and
                    not core.Tristate_IsTrue(optionsForFile.noResolve) and
                    not (isJsFile and not optionsForFile:GetAllowJS()) and
                    (importIndex < 0 or (importIndex < #imports and (ast.IsInJSFile(imports[importIndex + 1]) or imports[importIndex + 1].flags & ast.NodeFlags.JSDoc == 0)))

                if shouldAddFile then
                    local synthetic = nil
                    if importIndex < 0 then
                        synthetic = entry
                    end
                    t:addSubTask(compiler.newResolvedRef({
                        fileName = resolvedFileName,
                        increaseDepth = resolvedModule.isExternalLibraryImport,
                        elideOnDepth = isJsFileFromNodeModules,
                        includeReason = compiler.newFileIncludeReason(
                            compiler.fileIncludeKindImport,
                            compiler.newReferencedFileData(t.path, importIndex, synthetic)
                        ),
                        packageId = resolvedModule.packageId,
                    }), nil)
                end
            end
            ::continue::
        end

        t.resolutionsInFile = resolutionsInFile
        t.resolutionsTrace = resolutionsTrace
    end
end

function fileLoader:createSyntheticImport(text, file)
    if self.factory == nil then
        self.factory = ast.NewNodeFactory({})
    end
    local externalHelpersModuleReference = self.factory:NewStringLiteral(text, ast.TokenFlags.None)
    local importDecl = self.factory:NewImportDeclaration(nil, nil, externalHelpersModuleReference, nil)
    externalHelpersModuleReference.parent = importDecl
    importDecl.parent = file
    return externalHelpersModuleReference
end

function fileLoader:pathForLibFile(name)
    local cached = self.pathForLibFileCache[name]
    if cached ~= nil then
        return cached
    end

    local path = tspath.CombinePaths(self.defaultLibraryPath, name)
    local replaced = false
    if core.Tristate_IsTrue(self.opts.config:CompilerOptions().libReplacement) and name ~= "lib.d.ts" then
        local libraryName = compiler.getLibraryNameFromLibFileName(name)
        local resolveFrom = compiler.getInferredLibraryNameResolveFrom(self.opts.config:CompilerOptions(), self.opts.host:GetCurrentDirectory(), name)
        local resolution, trace = self:resolveLibrary(libraryName, resolveFrom)
        if resolution:IsResolved() then
            path = resolution.resolvedFileName
            replaced = true
        end
        local key = self:toPath(resolveFrom)
        if self.pathForLibFileResolutions[key] == nil then
            self.pathForLibFileResolutions[key] = {
                libraryName = libraryName,
                resolution = resolution,
                trace = trace,
            }
        end
    end

    local libPath = compiler.newLibFile(name, path, replaced)
    self.pathForLibFileCache[name] = libPath
    return libPath
end

function fileLoader:resolveLibrary(libraryName, resolveFrom)
    return self.resolver:ResolveModuleName(libraryName, resolveFrom, ModuleKind.CommonJS, nil)
end

function compiler.getLibraryNameFromLibFileName(libFileName)
    -- Support resolving to lib.dom.d.ts -> @typescript/lib-dom, and
    --                      lib.dom.iterable.d.ts -> @typescript/lib-dom/iterable
    --                      lib.es2015.symbol.wellknown.d.ts -> @typescript/lib-es2015/symbol-wellknown
    local components = {}
    for part in string.gmatch(libFileName .. ".", "([^.]*)%.") do
        components[#components + 1] = part
    end
    local path = { "@typescript/lib-" }
    if #components > 1 then
        path[#path + 1] = components[2]
    end
    local i = 2
    while i < #components and components[i + 1] ~= "" and components[i + 1] ~= "d" do
        if i == 2 then
            path[#path + 1] = "/"
        else
            path[#path + 1] = "-"
        end
        path[#path + 1] = components[i + 1]
        i = i + 1
    end
    return table.concat(path)
end

function compiler.getInferredLibraryNameResolveFrom(options, currentDirectory, libFileName)
    local containingDirectory
    if options.configFilePath ~= "" then
        containingDirectory = tspath.GetDirectoryPath(options.configFilePath)
    else
        containingDirectory = currentDirectory
    end
    return tspath.CombinePaths(containingDirectory, "__lib_node_modules_lookup_" .. libFileName .. "__.ts")
end

function compiler.getModeForTypeReferenceDirectiveInFile(ref, file, meta, options)
    if ref.resolutionMode ~= ModuleKind.ResolutionModeNone then
        return ref.resolutionMode
    else
        return compiler.getDefaultResolutionModeForFile(file:FileName(), meta, options)
    end
end

function compiler.getDefaultResolutionModeForFile(fileName, meta, options)
    if compiler.importSyntaxAffectsModuleResolution(options) then
        return ast.GetImpliedNodeFormatForEmitWorker(fileName, options:GetEmitModuleKind(), meta)
    else
        return ModuleKind.ResolutionModeNone
    end
end

function compiler.getModeForUsageLocation(fileName, meta, usage, options)
    local parent = usage.parent
    if ast.IsImportDeclaration(parent) or parent.kind == ast.Kind.JSImportDeclaration or ast.IsExportDeclaration(parent) or ast.IsJSDocImportTag(parent) then
        local isTypeOnly = ast.IsExclusivelyTypeOnlyImportOrExport(parent)
        if isTypeOnly then
            local override, ok = nil, false
            local kind = parent.kind
            if kind == ast.Kind.ImportDeclaration or kind == ast.Kind.JSImportDeclaration or kind == ast.Kind.ExportDeclaration or kind == ast.Kind.JSDocImportTag then
                override, ok = getResolutionModeOverride(parent.attributes)
            end
            if ok then
                return override
            end
        end
    end
    if ast.IsLiteralTypeNode(parent) and ast.IsImportTypeNode(parent.parent) then
        local override, ok = getResolutionModeOverride(parent.parent.attributes)
        if ok then
            return override
        end
    end

    if options ~= nil and compiler.importSyntaxAffectsModuleResolution(options) then
        return compiler.getEmitSyntaxForUsageLocationWorker(fileName, meta, usage, options)
    end

    return ModuleKind.ResolutionModeNone
end

function compiler.importSyntaxAffectsModuleResolution(options)
    local moduleResolution = options:GetModuleResolutionKind()
    return ModuleResolutionKind.Node16 <= moduleResolution and moduleResolution <= ModuleResolutionKind.NodeNext or
        options:GetResolvePackageJsonExports() or options:GetResolvePackageJsonImports()
end

function compiler.getEmitSyntaxForUsageLocationWorker(fileName, meta, usage, options)
    if ast.IsRequireCall(usage.parent, false) or ast.IsExternalModuleReference(usage.parent) and ast.IsImportEqualsDeclaration(usage.parent.parent) then
        return ModuleKind.CommonJS
    end
    local fileEmitMode = ast.GetEmitModuleFormatOfFileWorker(fileName, options, meta)
    if ast.IsImportCall(ast.WalkUpParenthesizedExpressions(usage.parent)) then
        if ast.ShouldTransformImportCall(fileName, options, fileEmitMode) then
            return ModuleKind.CommonJS
        else
            return ModuleKind.ESNext
        end
    end
    -- If we're in --module preserve on an input file, we know that an import
    -- is an import. But if this is a declaration file, we'd prefer to use the
    -- impliedNodeFormat. Since we want things to be consistent between the two,
    -- we need to issue errors when the user writes ESM syntax in a definitely-CJS
    -- file, until/unless declaration emit can indicate a true ESM import. On the
    -- other hand, writing CJS syntax in a definitely-ESM file is fine, since declaration
    -- emit preserves the CJS syntax.
    if fileEmitMode == ModuleKind.CommonJS then
        return ModuleKind.CommonJS
    else
        if core.ModuleKind_IsNonNodeESM(fileEmitMode) or fileEmitMode == ModuleKind.Preserve then
            return ModuleKind.ESNext
        end
    end
    return ModuleKind.None
end
