local module = require("tslua.module")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local packagejson = require("tslua.packagejson")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local vfsmatch = require("tslua.vfs.vfsmatch")

local strings = module.strings
local Tristate = core.Tristate
local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local NodeResolutionFeatures = module.NodeResolutionFeatures
local JSONValueType = packagejson.JSONValueType
local InfoCacheEntry = packagejson.InfoCacheEntry

local extensionsTypeScript = module.extensionsTypeScript
local extensionsJavaScript = module.extensionsJavaScript
local extensionsDeclaration = module.extensionsDeclaration
local extensionsJson = module.extensionsJson
local extensionsImplementationFiles = module.extensionsImplementationFiles

local function cpo(useCaseSensitiveFileNames, currentDirectory)
    return module.newComparePathsOptions(useCaseSensitiveFileNames, currentDirectory)
end

local resolved = {}
resolved.__index = resolved
module.resolved = resolved
local R = resolved

function module.newResolved(fields)
    local r = setmetatable({
        path = "",
        extension = "",
        packageId = module.NewPackageId(),
        originalPath = "",
        resolvedUsingTsExtension = false,
        resolvedUsingExtraExtensions = false,
    }, resolved)
    if fields ~= nil then
        for k, v in pairs(fields) do
            r[k] = v
        end
    end
    return r
end

-- Nil-receiver methods: call as module.resolved.shouldContinueSearching(r).
function resolved.shouldContinueSearching(r)
    return r == nil
end

function resolved.isResolved(r)
    return r ~= nil and r.path ~= ""
end

function module.continueSearching()
    return nil
end

function module.unresolved()
    return module.newResolved()
end

-- resolutionKindSpecificLoader = function(extensions, candidate) -> resolved

local tracer = {}
tracer.__index = tracer
module.tracer = tracer

function module.newTracer()
    return setmetatable({ traces = nil }, tracer)
end

-- DiagAndArgs: { message = *diagnostics.Message, args = { ... } }

-- Nil-receiver methods: call as module.tracer.write(t, ...) when t may be nil.
function tracer.write(t, diag, ...)
    if t ~= nil then
        t.traces = core.Append(t.traces, { message = diag, args = table.pack(...) })
    end
end

function tracer.getTraces(t)
    if t ~= nil then
        return t.traces
    end
    return nil
end

local resolutionState = {}
resolutionState.__index = resolutionState
module.resolutionState = resolutionState

function module.newResolutionStateStruct(fields)
    local state = setmetatable({
        resolver = nil,
        tracer = nil,
        -- request fields
        name = "",
        containingDirectory = "",
        isConfigLookup = false,
        features = 0,
        esmMode = false,
        conditions = nil,
        extensions = 0,
        compilerOptions = nil,
        resolvePackageDirectoryOnly = false,
        -- state fields
        -- candidateEndingIsFromConfig is set when the candidate file extension originated from
        -- configuration (package.json fields, tsconfig.json paths entries, or wildcard substitutions)
        -- rather than from the module specifier written in source code. When true, resolvedUsingTsExtension
        -- is suppressed so the checker does not attempt to extract a TS extension from the original specifier.
        candidateEndingIsFromConfig = false,
        resolvedPackageDirectory = false,
        diagnostics = nil,
        -- Similar to whats on resolver but only done if compilerOptions are for project reference redirect
        -- Cached representation for `core.CompilerOptions.paths`.
        -- Doesn't handle other path patterns like in `typesVersions`.
        parsedPatternsForPathsOnce = false,
        parsedPatternsForPaths = nil,
    }, resolutionState)
    if fields ~= nil then
        for k, v in pairs(fields) do
            state[k] = v
        end
    end
    return state
end

function module.newResolutionState(
    name,
    containingDirectory,
    isTypeReferenceDirective,
    resolutionMode,
    compilerOptions,
    redirectedReference,
    resolver,
    traceBuilder
)
    local state = module.newResolutionStateStruct({
        name = name,
        containingDirectory = containingDirectory,
        compilerOptions = module.GetCompilerOptionsWithRedirect(compilerOptions, redirectedReference),
        resolver = resolver,
        tracer = traceBuilder,
    })

    if isTypeReferenceDirective then
        state.extensions = extensionsDeclaration
    elseif compilerOptions.noDtsResolution == Tristate.TSTrue then
        state.extensions = extensionsImplementationFiles
    else
        state.extensions = extensionsTypeScript | extensionsJavaScript | extensionsDeclaration
    end

    if not isTypeReferenceDirective and compilerOptions:GetResolveJsonModule() then
        state.extensions = state.extensions | extensionsJson
    end

    local kind = compilerOptions:GetModuleResolutionKind()
    if kind == ModuleResolutionKind.Node16 then
        state.features = NodeResolutionFeatures.Node16Default
        state.esmMode = resolutionMode == ModuleKind.ESNext
        state.conditions = module.GetConditions(compilerOptions, resolutionMode)
    elseif kind == ModuleResolutionKind.NodeNext then
        state.features = NodeResolutionFeatures.NodeNextDefault
        state.esmMode = resolutionMode == ModuleKind.ESNext
        state.conditions = module.GetConditions(compilerOptions, resolutionMode)
    elseif kind == ModuleResolutionKind.Bundler then
        state.features = module.getNodeResolutionFeatures(compilerOptions)
        state.conditions = module.GetConditions(compilerOptions, resolutionMode)
    end
    return state
end

function module.GetCompilerOptionsWithRedirect(compilerOptions, redirectedReference)
    if redirectedReference == nil then
        return compilerOptions
    end
    local optionsFromRedirect = redirectedReference:CompilerOptions()
    if optionsFromRedirect ~= nil then
        return optionsFromRedirect
    end
    return compilerOptions
end

-- Resolver embeds caches (flattened: packageJsonInfoCache, moduleResolutionCache,
-- typeRefDirectiveResolutionCache, parsedPatternsForPathsOnce, parsedPatternsForPaths).
local Resolver = {}
Resolver.__index = Resolver
module.Resolver = Resolver

local function newResolverStruct(host, compilerOptions, typingsLocation, projectName, extraExtensions)
    return setmetatable({
        host = host,
        compilerOptions = compilerOptions,
        typingsLocation = typingsLocation or "",
        projectName = projectName or "",
        extraExtensions = extraExtensions,
        packageJsonInfoCache = nil,
        moduleResolutionCache = module.newModuleResolutionCache(),
        typeRefDirectiveResolutionCache = module.newTypeRefDirectiveResolutionCache(),
        parsedPatternsForPathsOnce = false,
        parsedPatternsForPaths = nil,
    }, Resolver)
end

-- ResolverOptions: { packageJsonCache = *packagejson.InfoCache }

function module.NewResolver(
    host,
    options,
    typingsLocation,
    projectName,
    extraExtensions
)
    local r = newResolverStruct(host, options, typingsLocation, projectName, extraExtensions)
    for k, v in pairs(module.newCaches(host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames(), options)) do
        r[k] = v
    end
    return r
end

function module.NewResolverWithOptions(
    host,
    compilerOptions,
    typingsLocation,
    projectName,
    opts
)
    local r = newResolverStruct(host, compilerOptions, typingsLocation, projectName, nil)
    if opts ~= nil and opts.packageJsonCache ~= nil then
        r.packageJsonInfoCache = opts.packageJsonCache
    else
        for k, v in pairs(module.newCaches(host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames(), compilerOptions)) do
            r[k] = v
        end
    end
    return r
end

function Resolver:newTraceBuilder()
    if self.compilerOptions.traceResolution == Tristate.TSTrue then
        return module.newTracer()
    end
    return nil
end

function Resolver:GetPackageScopeForPath(directory)
    return module.newResolutionStateStruct({ compilerOptions = self.compilerOptions, resolver = self }):getPackageScopeForPath(directory)
end

function Resolver:PackageJsonCacheEntries(f)
    self.packageJsonInfoCache:Range(f)
end

function tracer:traceResolutionUsingProjectReference(redirectedReference)
    if redirectedReference ~= nil and redirectedReference:CompilerOptions() ~= nil then
        tracer.write(self, diagnostics.Using_compiler_options_of_project_reference_redirect_0, redirectedReference:ConfigName())
    end
end

-- Returns *ResolvedTypeReferenceDirective, []DiagAndArgs.
function Resolver:ResolveTypeReferenceDirective(
    typeReferenceDirectiveName,
    containingFile,
    resolutionMode,
    redirectedReference
)
    local containingDirectory = tspath.GetDirectoryPath(containingFile)
    local traceBuilder = self:newTraceBuilder()

    local fromInferredTypesContainingFile = strings.HasSuffix(containingFile, module.InferredTypesContainingFile)

    local cacheKey = module.typeRefDirectiveResolutionCacheKey(
        containingDirectory,
        typeReferenceDirectiveName,
        resolutionMode,
        module.getRedirectConfigName(redirectedReference),
        fromInferredTypesContainingFile
    )

    if traceBuilder == nil then
        local cached, ok = self.typeRefDirectiveResolutionCache:Get(cacheKey)
        if ok then
            return cached, nil
        end
    end

    local compilerOptions = module.GetCompilerOptionsWithRedirect(self.compilerOptions, redirectedReference)

    local typeRoots, fromConfig = compilerOptions:GetEffectiveTypeRoots(self.host:GetCurrentDirectory())
    if traceBuilder ~= nil then
        tracer.write(traceBuilder, diagnostics.Resolving_type_reference_directive_0_containing_file_1_root_directory_2, typeReferenceDirectiveName, containingFile, strings.Join(typeRoots, ","))
        traceBuilder:traceResolutionUsingProjectReference(redirectedReference)
    end

    local state = module.newResolutionState(typeReferenceDirectiveName, containingDirectory, true --[[isTypeReferenceDirective]], resolutionMode, compilerOptions, redirectedReference, self, traceBuilder)
    local result = state:resolveTypeReferenceDirective(typeRoots, fromConfig, fromInferredTypesContainingFile)

    if traceBuilder ~= nil then
        traceBuilder:traceTypeReferenceDirectiveResult(typeReferenceDirectiveName, result)
    end

    self.typeRefDirectiveResolutionCache:Set(cacheKey, result)

    return result, tracer.getTraces(traceBuilder)
end

-- Returns *ResolvedModule, []DiagAndArgs.
function Resolver:ResolveModuleName(moduleName, containingFile, resolutionMode, redirectedReference)
    local containingDirectory = tspath.GetDirectoryPath(containingFile)
    local traceBuilder = self:newTraceBuilder()

    local cacheKey = module.moduleResolutionCacheKey(
        containingDirectory,
        moduleName,
        resolutionMode,
        module.getRedirectConfigName(redirectedReference)
    )

    if traceBuilder == nil then
        local cached, ok = self.moduleResolutionCache:Get(cacheKey)
        if ok then
            return cached, nil
        end
    end

    local compilerOptions = module.GetCompilerOptionsWithRedirect(self.compilerOptions, redirectedReference)
    if traceBuilder ~= nil then
        tracer.write(traceBuilder, diagnostics.Resolving_module_0_from_1, moduleName, containingFile)
        traceBuilder:traceResolutionUsingProjectReference(redirectedReference)
    end

    local moduleResolution = compilerOptions:GetModuleResolutionKind()
    if compilerOptions.moduleResolution ~= moduleResolution then
        if traceBuilder ~= nil then
            tracer.write(traceBuilder, diagnostics.Module_resolution_kind_is_not_specified_using_0, core.ModuleResolutionKind_String(moduleResolution))
        end
    else
        if traceBuilder ~= nil then
            tracer.write(traceBuilder, diagnostics.Explicitly_specified_module_resolution_kind_Colon_0, core.ModuleResolutionKind_String(moduleResolution))
        end
    end

    local result
    if moduleResolution == ModuleResolutionKind.Node16 or moduleResolution == ModuleResolutionKind.NodeNext or moduleResolution == ModuleResolutionKind.Bundler then
        local state = module.newResolutionState(moduleName, containingDirectory, false --[[isTypeReferenceDirective]], resolutionMode, compilerOptions, redirectedReference, self, traceBuilder)
        result = state:resolveNodeLike()
    else
        error("Unexpected moduleResolution: " .. tostring(moduleResolution), 0)
    end

    if traceBuilder ~= nil then
        if result:IsResolved() then
            if result.packageId.name ~= "" then
                tracer.write(traceBuilder, diagnostics.Module_name_0_was_successfully_resolved_to_1_with_Package_ID_2, moduleName, result.resolvedFileName, result.packageId:String())
            else
                tracer.write(traceBuilder, diagnostics.Module_name_0_was_successfully_resolved_to_1, moduleName, result.resolvedFileName)
            end
        else
            tracer.write(traceBuilder, diagnostics.Module_name_0_was_not_resolved, moduleName)
        end
    end

    local finalResult = self:tryResolveFromTypingsLocation(moduleName, containingDirectory, result, traceBuilder)
    self.moduleResolutionCache:Set(cacheKey, finalResult)

    return finalResult, tracer.getTraces(traceBuilder)
end

function Resolver:ResolvePackageDirectory(moduleName, containingFile, resolutionMode, redirectedReference)
    local compilerOptions = module.GetCompilerOptionsWithRedirect(self.compilerOptions, redirectedReference)
    local containingDirectory = tspath.GetDirectoryPath(containingFile)
    local state = module.newResolutionState(moduleName, containingDirectory, false --[[isTypeReferenceDirective]], resolutionMode, compilerOptions, redirectedReference, self, nil)
    state.resolvePackageDirectoryOnly = true
    local result = state:loadModuleFromNearestNodeModulesDirectory(false --[[typesScopeOnly]])
    if result ~= nil and result.path ~= "" then
        return state:createResolvedModuleHandlingSymlink(result)
    end
    return nil
end

function Resolver:tryResolveFromTypingsLocation(moduleName, containingDirectory, originalResult, traceBuilder)
    if self.typingsLocation == "" or
        tspath.IsExternalModuleNameRelative(moduleName) or
        (originalResult.resolvedFileName ~= "" and tspath.ExtensionIsOneOf(originalResult.extension, tspath.SupportedTSExtensionsWithJsonFlat)) then
        return originalResult
    end

    local state = module.newResolutionState(
        moduleName,
        containingDirectory,
        false, --[[isTypeReferenceDirective]]
        ModuleKind.None, -- resolutionMode,
        self.compilerOptions,
        nil, -- redirectedReference,
        self,
        traceBuilder
    )
    if traceBuilder ~= nil then
        tracer.write(traceBuilder, diagnostics.Auto_discovery_for_typings_is_enabled_in_project_0_Running_extra_resolution_pass_for_module_1_using_cache_location_2, self.projectName, moduleName, self.typingsLocation)
    end
    local globalResolved = state:loadModuleFromImmediateNodeModulesDirectory(extensionsDeclaration, self.typingsLocation, false)
    if globalResolved == nil then
        return originalResult
    end
    local result = state:createResolvedModule(globalResolved, true)
    local merged = core.AppendAll(core.Slice(originalResult.resolutionDiagnostics, 0), result.resolutionDiagnostics)
    if originalResult.resolutionDiagnostics == nil and result.resolutionDiagnostics == nil then
        merged = nil
    end
    result.resolutionDiagnostics = merged
    return result
end

function Resolver:resolveConfig(moduleName, containingFile)
    local containingDirectory = tspath.GetDirectoryPath(containingFile)
    local state = module.newResolutionState(moduleName, containingDirectory, false --[[isTypeReferenceDirective]], ModuleKind.CommonJS, self.compilerOptions, nil, self, nil)
    state.isConfigLookup = true
    state.extensions = extensionsJson
    return state:resolveNodeLike()
end

function tracer:traceTypeReferenceDirectiveResult(typeReferenceDirectiveName, result)
    if not result:IsResolved() then
        tracer.write(self, diagnostics.Type_reference_directive_0_was_not_resolved, typeReferenceDirectiveName)
    elseif result.packageId.name ~= "" then
        tracer.write(self,
            diagnostics.Type_reference_directive_0_was_successfully_resolved_to_1_with_Package_ID_2_primary_Colon_3,
            typeReferenceDirectiveName,
            result.resolvedFileName,
            result.packageId:String(),
            result.primary
        )
    else
        tracer.write(self,
            diagnostics.Type_reference_directive_0_was_successfully_resolved_to_1_primary_Colon_2,
            typeReferenceDirectiveName,
            result.resolvedFileName,
            result.primary
        )
    end
end

function resolutionState:resolveTypeReferenceDirective(typeRoots, fromConfig, fromInferredTypesContainingFile)
    -- Primary lookup
    if core.Len(typeRoots) > 0 then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Resolving_with_primary_search_path_0, strings.Join(typeRoots, ", "))
        end
        for _, typeRoot in ipairs(typeRoots) do
            local candidate = self:getCandidateFromTypeRoot(typeRoot)
            local directoryExists = self.resolver.host:FS():DirectoryExists(typeRoot)
            if not directoryExists then
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, typeRoot)
                end
                goto continue
            end
            if fromConfig then
                -- Custom typeRoots resolve as file or directory just like we do modules
                local resolvedFromFile = self:loadModuleFromFile(extensionsDeclaration, candidate)
                if not R.shouldContinueSearching(resolvedFromFile) then
                    local packageDirectory = module.ParseNodeModuleFromPath(resolvedFromFile.path, false)
                    if packageDirectory ~= "" then
                        resolvedFromFile.packageId = self:getPackageId(resolvedFromFile.path, self:getPackageJsonInfo(packageDirectory))
                    end
                    return self:createResolvedTypeReferenceDirective(resolvedFromFile, true --[[primary]])
                end
            end
            do
                local resolvedFromDirectory = self:loadNodeModuleFromDirectory(extensionsDeclaration, candidate, true --[[considerPackageJson]])
                if not R.shouldContinueSearching(resolvedFromDirectory) then
                    return self:createResolvedTypeReferenceDirective(resolvedFromDirectory, true --[[primary]])
                end
            end
            ::continue::
        end
    elseif self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Root_directory_cannot_be_determined_skipping_primary_search_paths)
    end

    -- Secondary lookup
    local result
    if not fromConfig or not fromInferredTypesContainingFile then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Looking_up_in_node_modules_folder_initial_location_0, self.containingDirectory)
        end
        if not tspath.IsExternalModuleNameRelative(self.name) then
            result = self:loadModuleFromNearestNodeModulesDirectory(false --[[typesScopeOnly]])
        else
            local candidate = module.normalizePathForCJSResolution(self.containingDirectory, self.name)
            result = self:nodeLoadModuleByRelativeName(extensionsDeclaration, candidate, true --[[considerPackageJson]])
        end
    elseif self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Resolving_type_reference_directive_for_program_that_specifies_custom_typeRoots_skipping_lookup_in_node_modules_folder)
    end
    return self:createResolvedTypeReferenceDirective(result, false --[[primary]])
end

function resolutionState:getCandidateFromTypeRoot(typeRoot)
    local nameForLookup = self.name
    if strings.HasSuffix(typeRoot, "/node_modules/@types") or strings.HasSuffix(typeRoot, "/node_modules/@types/") then
        nameForLookup = self:mangleScopedPackageName(self.name)
    end
    return tspath.CombinePaths(typeRoot, nameForLookup)
end

function resolutionState:mangleScopedPackageName(name)
    local mangled = module.MangleScopedPackageName(name)
    if self.tracer ~= nil and mangled ~= name then
        tracer.write(self.tracer, diagnostics.Scoped_package_detected_looking_in_0, mangled)
    end
    return mangled
end

-- resolveFromTypeRoot tries to resolve a module name from the configured typeRoots.
-- This is used as a fallback after node_modules resolution fails, for declaration file lookups.
-- Returns nil if typeRoots is not configured or if no matching module is found in any typeRoot directory.
function resolutionState:resolveFromTypeRoot()
    if self.compilerOptions.typeRoots == nil then
        return nil
    end
    for _, typeRoot in ipairs(self.compilerOptions.typeRoots) do
        local candidate = self:getCandidateFromTypeRoot(typeRoot)
        local directoryExists = self.resolver.host:FS():DirectoryExists(typeRoot)
        if not directoryExists then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, typeRoot)
            end
            goto continue
        end
        do
            local resolvedFromFile = self:loadModuleFromFile(extensionsDeclaration, candidate)
            if not R.shouldContinueSearching(resolvedFromFile) then
                local packageDirectory = module.ParseNodeModuleFromPath(resolvedFromFile.path, false)
                if packageDirectory ~= "" then
                    resolvedFromFile.packageId = self:getPackageId(resolvedFromFile.path, self:getPackageJsonInfo(packageDirectory))
                end
                return resolvedFromFile
            end
            local result = self:loadNodeModuleFromDirectory(extensionsDeclaration, candidate, true --[[considerPackageJson]])
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        ::continue::
    end
    return nil
end

function resolutionState:getPackageScopeForPath(directory)
    local result = tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(
        self.resolver.typingsLocation,
        directory,
        function(dir)
            local result = self:getPackageJsonInfo(dir)
            if result ~= nil then
                return result, true
            end
            return nil, false
        end
    )
    return result
end

function resolutionState:resolveNodeLike()
    if self.tracer ~= nil then
        local conditions = strings.Join(core.Map(self.conditions, function(c) return "'" .. c .. "'" end), ", ")
        if self.esmMode then
            tracer.write(self.tracer, diagnostics.Resolving_in_0_mode_with_conditions_1, "ESM", conditions)
        else
            tracer.write(self.tracer, diagnostics.Resolving_in_0_mode_with_conditions_1, "CJS", conditions)
        end
    end
    local result = self:resolveNodeLikeWorker()
    if self.resolvedPackageDirectory and
        not self.isConfigLookup and
        self.features & NodeResolutionFeatures.Exports ~= 0 and
        self.extensions & (extensionsTypeScript | extensionsDeclaration) ~= 0 and
        not tspath.IsExternalModuleNameRelative(self.name) and
        result:IsResolved() and
        result.isExternalLibraryImport and
        not module.extensionIsOk(extensionsTypeScript | extensionsDeclaration, result.extension) and
        strings.SliceContains(self.conditions, "import") then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Resolution_of_non_relative_name_failed_trying_with_modern_Node_resolution_features_disabled_to_see_if_npm_library_needs_configuration_update)
        end
        self.features = self.features & ~NodeResolutionFeatures.Exports
        self.extensions = self.extensions & (extensionsTypeScript | extensionsDeclaration)
        local diagnosticsCount = core.Len(self.diagnostics)
        local diagnosticResult = self:resolveNodeLikeWorker()
        if diagnosticResult:IsResolved() and diagnosticResult.isExternalLibraryImport then
            result.alternateResult = diagnosticResult.resolvedFileName
        end
        if self.diagnostics ~= nil then
            self.diagnostics = core.Slice(self.diagnostics, 0, diagnosticsCount)
        end
    end
    return result
end

function resolutionState:resolveNodeLikeWorker()
    do
        local result = self:tryLoadModuleUsingOptionalResolutionSettings()
        if not R.shouldContinueSearching(result) then
            return self:createResolvedModuleHandlingSymlink(result)
        end
    end

    if not tspath.IsExternalModuleNameRelative(self.name) then
        if self.features & NodeResolutionFeatures.Imports ~= 0 and strings.HasPrefix(self.name, "#") then
            local result = self:loadModuleFromImports()
            if not R.shouldContinueSearching(result) then
                return self:createResolvedModuleHandlingSymlink(result)
            end
        end
        if self.features & NodeResolutionFeatures.SelfName ~= 0 then
            local result = self:loadModuleFromSelfNameReference()
            if not R.shouldContinueSearching(result) then
                return self:createResolvedModuleHandlingSymlink(result)
            end
        end
        if strings.Contains(self.name, ":") then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Skipping_module_0_that_looks_like_an_absolute_URI_target_file_types_Colon_1, self.name, module.extensions_String(self.extensions))
            end
            return self:createResolvedModule(nil, false)
        end
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Loading_module_0_from_node_modules_folder_target_file_types_Colon_1, self.name, module.extensions_String(self.extensions))
        end
        do
            local result = self:loadModuleFromNearestNodeModulesDirectory(false --[[typesScopeOnly]])
            if not R.shouldContinueSearching(result) then
                return self:createResolvedModuleHandlingSymlink(result)
            end
        end
        if self.extensions & extensionsDeclaration ~= 0 then
            local result = self:resolveFromTypeRoot()
            if not R.shouldContinueSearching(result) then
                return self:createResolvedModuleHandlingSymlink(result)
            end
        end
    else
        local candidate = module.normalizePathForCJSResolution(self.containingDirectory, self.name)
        local result = self:nodeLoadModuleByRelativeName(self.extensions, candidate, true)
        return self:createResolvedModule(
            result,
            result ~= nil and strings.Contains(result.path, "/node_modules/")
        )
    end
    return self:createResolvedModule(nil, false)
end

local function sliceEqual(a, b)
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

function resolutionState:loadModuleFromSelfNameReference()
    local directoryPath = tspath.GetNormalizedAbsolutePath(self.containingDirectory, self.resolver.host:GetCurrentDirectory())
    local scope = self:getPackageScopeForPath(directoryPath)
    if not InfoCacheEntry.Exists(scope) or scope.contents.exports:IsFalsy() then
        -- !!! falsy check seems wrong?
        return module.continueSearching()
    end
    local name, ok = scope.contents.name:GetValue()
    if not ok then
        return module.continueSearching()
    end
    local parts = tspath.GetPathComponents(self.name, "")
    local nameParts = tspath.GetPathComponents(name, "")
    if #parts < #nameParts or not sliceEqual(nameParts, core.Slice(parts, 0, #nameParts)) then
        return module.continueSearching()
    end
    local trailingParts = core.Slice(parts, #nameParts)
    local subpath
    if #trailingParts > 0 then
        subpath = tspath.CombinePaths(".", table.unpack(trailingParts))
    else
        subpath = "."
    end
    -- Maybe TODO: splitting extensions into two priorities should be unnecessary, except
    -- https://github.com/microsoft/TypeScript/issues/50762 makes the behavior different.
    -- As long as that bug exists, we need to do two passes here in self-name loading
    -- in order to be consistent with (non-self) library-name loading in
    -- `loadModuleFromNearestNodeModulesDirectoryWorker`, which uses two passes in order
    -- to prioritize `@types` packages higher up the directory tree over untyped
    -- implementation packages. See the selfNameModuleAugmentation.ts test for why this
    -- matters.
    --
    -- However, there's an exception. If the user has `allowJs` and `declaration`, we need
    -- to ensure that self-name imports of their own package can resolve back to their
    -- input JS files via `tryLoadInputFileForPath` at a higher priority than their output
    -- declaration files, so we need to do a single pass with all extensions for that case.
    if self.compilerOptions:GetAllowJS() and not strings.Contains(self.containingDirectory, "/node_modules/") then
        return self:loadModuleFromExports(scope, self.extensions, subpath)
    end
    local priorityExtensions = self.extensions & (extensionsTypeScript | extensionsDeclaration)
    local secondaryExtensions = self.extensions & ~(extensionsTypeScript | extensionsDeclaration)
    local result = self:loadModuleFromExports(scope, priorityExtensions, subpath)
    if not R.shouldContinueSearching(result) then
        return result
    end
    return self:loadModuleFromExports(scope, secondaryExtensions, subpath)
end

function resolutionState:loadModuleFromImports()
    if self.name == "#" or (strings.HasPrefix(self.name, "#/") and (self.features & NodeResolutionFeatures.ImportsPatternRoot) == 0) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Invalid_import_specifier_0_has_no_possible_resolutions, self.name)
        end
        return module.continueSearching()
    end
    local directoryPath = tspath.GetNormalizedAbsolutePath(self.containingDirectory, self.resolver.host:GetCurrentDirectory())
    local scope = self:getPackageScopeForPath(directoryPath)
    if not InfoCacheEntry.Exists(scope) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Directory_0_has_no_containing_package_json_scope_Imports_will_not_resolve, directoryPath)
        end
        return module.continueSearching()
    end
    if scope.contents.imports.type ~= JSONValueType.Object then
        -- !!! Old compiler only checks for undefined, but then assumes `imports` is an object if present.
        -- Maybe should have a new diagnostic for imports of an invalid type. Also, array should be handled?
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_no_imports_defined, scope.packageDirectory)
        end
        return module.continueSearching()
    end

    local result = self:loadModuleFromExportsOrImports(self.extensions, self.name, scope.contents.imports:AsObject(), scope, true --[[isImports]])
    if not R.shouldContinueSearching(result) then
        return result
    end

    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Import_specifier_0_does_not_exist_in_package_json_scope_at_path_1, self.name, scope.packageDirectory)
    end
    return module.continueSearching()
end

function resolutionState:loadModuleFromExports(packageInfo, ext, subpath)
    -- !!! This is ported exactly, but the falsy check seems wrong
    if not InfoCacheEntry.Exists(packageInfo) or packageInfo.contents.exports:IsFalsy() then
        return module.continueSearching()
    end

    local exports = packageInfo.contents.exports
    if subpath == "." then
        local mainExport = packagejson.NewExportsOrImports()
        if exports.type == JSONValueType.String or exports.type == JSONValueType.Array then
            mainExport = exports
        elseif exports.type == JSONValueType.Object then
            if exports:IsConditions() then
                mainExport = exports
            else
                local dot, ok = exports:AsObject():Get(".")
                if ok then
                    mainExport = dot
                end
            end
        end
        if mainExport.type ~= JSONValueType.NotPresent then
            return self:loadModuleFromTargetExportOrImport(ext, subpath, packageInfo, false --[[isImports]], mainExport, "", false --[[isPattern]], ".")
        end
    elseif exports.type == JSONValueType.Object and exports:IsSubpaths() then
        local result = self:loadModuleFromExportsOrImports(ext, subpath, exports:AsObject(), packageInfo, false --[[isImports]])
        if not R.shouldContinueSearching(result) then
            return result
        end
    end

    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Export_specifier_0_does_not_exist_in_package_json_scope_at_path_1, subpath, packageInfo.packageDirectory)
    end
    return module.continueSearching()
end

function resolutionState:loadModuleFromExportsOrImports(
    extensions,
    moduleName,
    lookupTable,
    scope,
    isImports
)
    if not strings.HasSuffix(moduleName, "/") and not strings.Contains(moduleName, "*") then
        local target, ok = lookupTable:Get(moduleName)
        if ok then
            return self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, "", false --[[isPattern]], moduleName)
        end
    end

    local expandingKeys = {}
    for key in lookupTable:Keys() do
        if strings.Count(key, "*") == 1 or strings.HasSuffix(key, "/") then
            expandingKeys[#expandingKeys + 1] = key
        end
    end
    module.sortFunc(expandingKeys, module.ComparePatternKeys)

    for _, potentialTarget in ipairs(expandingKeys) do
        if self.features & NodeResolutionFeatures.ExportsPatternTrailers ~= 0 and module.matchesPatternWithTrailer(potentialTarget, moduleName) then
            local target = lookupTable:Get(potentialTarget)
            local starPos = strings.Index(potentialTarget, "*")
            local subpath = string.sub(moduleName, starPos + 1, #moduleName - (#potentialTarget - 1 - starPos))
            return self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, true, potentialTarget)
        elseif strings.HasSuffix(potentialTarget, "*") and strings.HasPrefix(moduleName, string.sub(potentialTarget, 1, #potentialTarget - 1)) then
            local target = lookupTable:Get(potentialTarget)
            local subpath = string.sub(moduleName, #potentialTarget)
            return self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, true, potentialTarget)
        elseif strings.HasPrefix(moduleName, potentialTarget) then
            local target = lookupTable:Get(potentialTarget)
            local subpath = string.sub(moduleName, #potentialTarget + 1)
            return self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, false, potentialTarget)
        end
    end

    return module.continueSearching()
end

local function hasInvalidSegment(parts)
    return strings.SliceContains(parts, "..") or strings.SliceContains(parts, ".") or strings.SliceContains(parts, "node_modules")
end

function resolutionState:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, isPattern, key)
    if target.type == JSONValueType.String then
        local targetString = target.value
        if not isPattern and #subpath > 0 and not strings.HasSuffix(targetString, "/") then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
            end
            return module.continueSearching()
        end
        if not strings.HasPrefix(targetString, "./") then
            if isImports and not strings.HasPrefix(targetString, "../") and not strings.HasPrefix(targetString, "/") and not tspath.IsRootedDiskPath(targetString) then
                local combinedLookup = targetString .. subpath
                if isPattern then
                    combinedLookup = strings.ReplaceAll(targetString, "*", subpath)
                end
                local scopeContainingDirectory = tspath.EnsureTrailingDirectorySeparator(scope.packageDirectory)
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Using_0_subpath_1_with_target_2, "imports", key, combinedLookup)
                    tracer.write(self.tracer, diagnostics.Resolving_module_0_from_1, combinedLookup, scopeContainingDirectory)
                end
                local name, containingDirectory = self.name, self.containingDirectory
                self.name, self.containingDirectory = combinedLookup, scopeContainingDirectory
                local result = self:resolveNodeLike()
                self.name, self.containingDirectory = name, containingDirectory
                if result:IsResolved() then
                    return module.newResolved({
                        path = result.resolvedFileName,
                        extension = result.extension,
                        packageId = result.packageId,
                        originalPath = result.originalPath,
                        resolvedUsingTsExtension = result.resolvedUsingTsExtension,
                    })
                end
                return module.continueSearching()
            end
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
            end
            return module.continueSearching()
        end
        local parts
        if tspath.PathIsRelative(targetString) then
            parts = core.Slice(tspath.GetPathComponents(targetString, ""), 1)
        else
            parts = tspath.GetPathComponents(targetString, "")
        end
        local partsAfterFirst = core.Slice(parts, 1)
        if hasInvalidSegment(partsAfterFirst) then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
            end
            return module.continueSearching()
        end
        local resolvedTarget = tspath.CombinePaths(scope.packageDirectory, targetString)
        -- TODO: Assert that `resolvedTarget` is actually within the package directory? That's what the spec says.... but I'm not sure we need
        -- to be in the business of validating everyone's import and export map correctness.
        local subpathParts = tspath.GetPathComponents(subpath, "")
        if hasInvalidSegment(subpathParts) then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
            end
            return module.continueSearching()
        end

        if self.tracer ~= nil then
            local messageTarget
            if isPattern then
                messageTarget = strings.ReplaceAll(targetString, "*", subpath)
            else
                messageTarget = targetString .. subpath
            end
            tracer.write(self.tracer, diagnostics.Using_0_subpath_1_with_target_2, core.IfElse(isImports, "imports", "exports"), key, messageTarget)
        end
        local finalPath
        if isPattern then
            finalPath = tspath.GetNormalizedAbsolutePath(strings.ReplaceAll(resolvedTarget, "*", subpath), self.resolver.host:GetCurrentDirectory())
        else
            finalPath = tspath.GetNormalizedAbsolutePath(resolvedTarget .. subpath, self.resolver.host:GetCurrentDirectory())
        end
        local inputLink = self:tryLoadInputFileForPath(finalPath, subpath, tspath.CombinePaths(scope.packageDirectory, "package.json"), isImports)
        if not R.shouldContinueSearching(inputLink) then
            inputLink.packageId = self:getPackageId(inputLink.path, scope)
            return inputLink
        end
        local result = self:loadFileNameFromPackageJSONField(extensions, finalPath, targetString)
        if not R.shouldContinueSearching(result) then
            result.packageId = self:getPackageId(result.path, scope)
            return result
        end
        return module.continueSearching()
    elseif target.type == JSONValueType.Object then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Entering_conditional_exports)
        end
        for condition in target:AsObject():Keys() do
            if self:conditionMatches(condition) then
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Matched_0_condition_1, core.IfElse(isImports, "imports", "exports"), condition)
                end
                local subTarget = target:AsObject():Get(condition)
                local result = self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, subTarget, subpath, isPattern, key)
                if not R.shouldContinueSearching(result) then
                    if R.isResolved(result) and self.tracer ~= nil then
                        tracer.write(self.tracer, diagnostics.Resolved_under_condition_0, condition)
                    end
                    if self.tracer ~= nil then
                        tracer.write(self.tracer, diagnostics.Exiting_conditional_exports)
                    end
                    return result
                elseif self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Failed_to_resolve_under_condition_0, condition)
                end
            else
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Saw_non_matching_condition_0, condition)
                end
            end
        end
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Exiting_conditional_exports)
        end
        return module.continueSearching()
    elseif target.type == JSONValueType.Array then
        if #target:AsArray() == 0 then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
            end
            return module.continueSearching()
        end
        for _, elem in ipairs(target:AsArray()) do
            local result = self:loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, elem, subpath, isPattern, key)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
    elseif target.type == JSONValueType.Null then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.X_package_json_scope_0_explicitly_maps_specifier_1_to_null, scope.packageDirectory, moduleName)
        end
        return module.unresolved()
    end

    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.packageDirectory, moduleName)
    end
    return module.continueSearching()
end

function resolutionState:tryLoadInputFileForPath(finalPath, entry, packagePath, isImports)
    local options = self.compilerOptions
    local fs = self.resolver.host:FS()
    -- Replace any references to outputs for files in the program with the input files to support package self-names used with outDir
    if not self.isConfigLookup and
        (options.declarationDir ~= "" or options.outDir ~= "") and
        not strings.Contains(finalPath, "/node_modules/") and
        (options.configFilePath == "" or tspath.ContainsPath(
            tspath.GetDirectoryPath(packagePath),
            options.configFilePath,
            cpo(fs:UseCaseSensitiveFileNames(), self.resolver.host:GetCurrentDirectory())
        )) then
        -- Note: this differs from Strada's tryLoadInputFileForPath in that it
        -- does not attempt to perform "guesses", instead requring a clear root indicator.

        local rootDir
        if options.rootDir ~= "" then
            -- A `rootDir` compiler option strongly indicates the root location
            rootDir = options.rootDir
        elseif options.configFilePath ~= "" then
            -- When no explicit rootDir is set, treat the config file's directory as the project root, which establishes the common source directory, so no other locations need to be checked.
            rootDir = tspath.GetDirectoryPath(options.configFilePath)
        else
            local diagnostic = ast.NewDiagnostic(
                nil,
                core.NewTextRange(0, 0),
                core.IfElse(
                    isImports,
                    diagnostics.The_project_root_is_ambiguous_but_is_required_to_resolve_import_map_entry_0_in_file_1_Supply_the_rootDir_compiler_option_to_disambiguate,
                    diagnostics.The_project_root_is_ambiguous_but_is_required_to_resolve_export_map_entry_0_in_file_1_Supply_the_rootDir_compiler_option_to_disambiguate
                ),
                core.IfElse(entry == "", ".", entry), -- replace empty string with `.` - the reverse of the operation done when entries are built - so main entrypoint errors don't look weird
                packagePath
            )
            self.diagnostics = core.Append(self.diagnostics, diagnostic)
            return module.unresolved()
        end

        local candidateDirectories = self:getOutputDirectoriesForBaseDirectory(rootDir)
        for _, candidateDir in ipairs(candidateDirectories or {}) do
            if tspath.ContainsPath(candidateDir, finalPath, cpo(fs:UseCaseSensitiveFileNames(), self.resolver.host:GetCurrentDirectory())) then
                -- The matched export is looking up something in either the out declaration or js dir, now map the written path back into the source dir and source extension
                local pathFragment = ""
                if #finalPath > #candidateDir then
                    pathFragment = string.sub(finalPath, #candidateDir + 2) -- +1 to also remove directory separator
                end
                local possibleInputBase = tspath.CombinePaths(rootDir, pathFragment)
                local jsAndDtsExtensions = { tspath.ExtensionMjs, tspath.ExtensionCjs, tspath.ExtensionJs, tspath.ExtensionJson, tspath.ExtensionDmts, tspath.ExtensionDcts, tspath.ExtensionDts }
                for _, ext in ipairs(jsAndDtsExtensions) do
                    if tspath.FileExtensionIs(possibleInputBase, ext) then
                        local inputExts = tspath.GetPossibleOriginalInputExtensionForExtension(possibleInputBase)
                        for _, possibleExt in ipairs(inputExts) do
                            if module.extensionIsOk(self.extensions, possibleExt) then
                                local possibleInputWithInputExtension = tspath.ChangeExtension(possibleInputBase, possibleExt)
                                if fs:FileExists(possibleInputWithInputExtension) then
                                    local result = self:loadFileNameFromPackageJSONField(self.extensions, possibleInputWithInputExtension, "")
                                    if not R.shouldContinueSearching(result) then
                                        return result
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return module.continueSearching()
end

function resolutionState:getOutputDirectoriesForBaseDirectory(commonSourceDirGuess)
    -- Config file output paths are processed to be relative to the host's current directory, while
    -- otherwise the paths are resolved relative to the common source dir the compiler puts together
    local currentDir = core.IfElse(self.compilerOptions.configFilePath ~= "", self.resolver.host:GetCurrentDirectory(), commonSourceDirGuess)
    local candidateDirectories = nil
    if self.compilerOptions.declarationDir ~= "" then
        candidateDirectories = core.Append(candidateDirectories, tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(currentDir, self.compilerOptions.declarationDir), self.resolver.host:GetCurrentDirectory()))
    end
    if self.compilerOptions.outDir ~= "" and self.compilerOptions.outDir ~= self.compilerOptions.declarationDir then
        candidateDirectories = core.Append(candidateDirectories, tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(currentDir, self.compilerOptions.outDir), self.resolver.host:GetCurrentDirectory()))
    end
    return candidateDirectories
end

function resolutionState:loadModuleFromNearestNodeModulesDirectory(typesScopeOnly)
    local mode = ModuleKind.ResolutionModeCommonJS
    if self.esmMode or self:conditionMatches("import") then
        mode = ModuleKind.ResolutionModeESM
    end
    -- Do (up to) two passes through node_modules:
    --   1. For each ancestor node_modules directory, try to find:
    --      i.  TS/DTS files in the implementation package
    --      ii. DTS files in the @types package
    --   2. For each ancestor node_modules directory, try to find:
    --      i.  JS files in the implementation package
    local priorityExtensions = self.extensions & (extensionsTypeScript | extensionsDeclaration)
    local secondaryExtensions = self.extensions & ~(extensionsTypeScript | extensionsDeclaration)
    -- (1)
    if priorityExtensions ~= 0 then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Searching_all_ancestor_node_modules_directories_for_preferred_extensions_Colon_0, module.extensions_String(priorityExtensions))
        end
        local result = self:loadModuleFromNearestNodeModulesDirectoryWorker(priorityExtensions, mode, typesScopeOnly)
        if not R.shouldContinueSearching(result) then
            return result
        end
    end
    -- (2)
    if secondaryExtensions ~= 0 and not typesScopeOnly then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Searching_all_ancestor_node_modules_directories_for_fallback_extensions_Colon_0, module.extensions_String(secondaryExtensions))
        end
        return self:loadModuleFromNearestNodeModulesDirectoryWorker(secondaryExtensions, mode, typesScopeOnly)
    end
    return module.continueSearching()
end

function resolutionState:loadModuleFromNearestNodeModulesDirectoryWorker(ext, mode, typesScopeOnly)
    local result = tspath.ForEachAncestorDirectory(
        self.containingDirectory,
        function(directory)
            -- !!! stop at global cache
            if tspath.GetBaseFileName(directory) ~= "node_modules" then
                local result = self:loadModuleFromImmediateNodeModulesDirectory(ext, directory, typesScopeOnly)
                return result, not R.shouldContinueSearching(result)
            end
            return module.continueSearching(), false
        end
    )
    return result
end

function resolutionState:loadModuleFromImmediateNodeModulesDirectory(extensions, directory, typesScopeOnly)
    local nodeModulesFolder = tspath.CombinePaths(directory, "node_modules")
    if not self.resolver.host:FS():DirectoryExists(nodeModulesFolder) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, nodeModulesFolder)
        end
        return module.continueSearching()
    end

    if not typesScopeOnly then
        local packageResult = self:loadModuleFromSpecificNodeModulesDirectory(extensions, self.name, nodeModulesFolder)
        if not R.shouldContinueSearching(packageResult) then
            return packageResult
        end
    end

    if extensions & extensionsDeclaration ~= 0 then
        local nodeModulesAtTypes = tspath.CombinePaths(nodeModulesFolder, "@types")
        if not self.resolver.host:FS():DirectoryExists(nodeModulesAtTypes) then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, nodeModulesAtTypes)
            end
            return module.continueSearching()
        end
        return self:loadModuleFromSpecificNodeModulesDirectory(extensionsDeclaration, self:mangleScopedPackageName(self.name), nodeModulesAtTypes)
    end

    return module.continueSearching()
end

function resolutionState:loadModuleFromSpecificNodeModulesDirectory(ext, moduleName, nodeModulesDirectory)
    -- Strip any trailing directory separator so that imports like `pkg/` and `pkg`
    -- produce identical `candidate` and `packageDirectory` strings. Otherwise the
    -- `package.json` info cache (which is keyed by normalized path but stores the
    -- caller's `PackageDirectory` verbatim) can hand back, under concurrent
    -- inserts, an entry whose `PackageDirectory` doesn't match `candidate`,
    -- causing `loadNodeModuleFromDirectoryWorker`'s `ComparePaths(candidate, ...)`
    -- check to fail and skip loading the package's `main`/`types` entry.
    -- https://github.com/microsoft/typescript-go/issues/3526
    local candidate = tspath.RemoveTrailingDirectorySeparator(tspath.NormalizePath(tspath.CombinePaths(nodeModulesDirectory, moduleName)))
    local packageName, rest = module.ParsePackageName(moduleName)
    local packageDirectory = tspath.CombinePaths(nodeModulesDirectory, packageName)
    if packageName == "" then
        packageDirectory = candidate
    end

    if self.resolvePackageDirectoryOnly then
        if self.resolver.host:FS():DirectoryExists(packageDirectory) then
            return module.newResolved({ path = packageDirectory })
        end
        return module.continueSearching()
    end

    local rootPackageInfo = nil
    -- First look for a nested package.json, as in `node_modules/foo/bar/package.json`
    local packageInfo = self:getPackageJsonInfo(candidate)
    -- But only if we're not respecting export maps (if we are, we might redirect around this location)
    if rest ~= "" and InfoCacheEntry.Exists(packageInfo) then
        if self.features & NodeResolutionFeatures.Exports ~= 0 then
            rootPackageInfo = self:getPackageJsonInfo(packageDirectory)
        end
        if not InfoCacheEntry.Exists(rootPackageInfo) or rootPackageInfo.contents.exports.type == JSONValueType.NotPresent then
            local fromFile = self:loadModuleFromFile(ext, candidate)
            if not R.shouldContinueSearching(fromFile) then
                return fromFile
            end

            local fromDirectory = self:loadNodeModuleFromDirectoryWorker(ext, candidate, packageInfo)
            if not R.shouldContinueSearching(fromDirectory) then
                fromDirectory.packageId = self:getPackageId(fromDirectory.path, packageInfo)
                return fromDirectory
            end
        end
    end

    local function loader(extensions, cand)
        if rest ~= "" or not self.esmMode then
            local fromFile = self:loadModuleFromFile(extensions, cand)
            if not R.shouldContinueSearching(fromFile) then
                fromFile.packageId = self:getPackageId(fromFile.path, packageInfo)
                return fromFile
            end
        end
        local fromDirectory = self:loadNodeModuleFromDirectoryWorker(extensions, cand, packageInfo)
        if not R.shouldContinueSearching(fromDirectory) then
            fromDirectory.packageId = self:getPackageId(fromDirectory.path, packageInfo)
            return fromDirectory
        end
        if rest == "" and InfoCacheEntry.Exists(packageInfo) and
            (packageInfo.contents.exports.type == JSONValueType.NotPresent or packageInfo.contents.exports.type == JSONValueType.Null) and
            self.esmMode then
            -- EsmMode disables index lookup in `loadNodeModuleFromDirectoryWorker` generally, however non-relative package resolutions still assume
            -- a default `index.js` entrypoint if no `main` or `exports` are present
            local indexResult = self:loadModuleFromFile(extensions, tspath.CombinePaths(cand, "index.js"))
            if not R.shouldContinueSearching(indexResult) then
                indexResult.packageId = self:getPackageId(indexResult.path, packageInfo)
                return indexResult
            end
        end
        return module.continueSearching()
    end

    if rest ~= "" then
        packageInfo = rootPackageInfo
        if packageInfo == nil then
            -- Previous `packageInfo` may have been from a nested package.json; ensure we have the one from the package root now.
            packageInfo = self:getPackageJsonInfo(packageDirectory)
        end
    end
    if packageInfo ~= nil then
        self.resolvedPackageDirectory = true
        if self.features & NodeResolutionFeatures.Exports ~= 0 and
            InfoCacheEntry.Exists(packageInfo) and
            not packageInfo.contents.exports:IsFalsy() then
            -- package exports are higher priority than file/directory/typesVersions lookups and (and, if there's exports present*, blocks them)
            -- *Well, weirdly enough a top-level `"exports": null` does NOT block fallback resolution.
            -- https://github.com/microsoft/TypeScript/pull/49327
            return self:loadModuleFromExports(packageInfo, ext, tspath.CombinePaths(".", rest))
        end
        if rest ~= "" and InfoCacheEntry.Exists(packageInfo) then
            local versionPaths = packageInfo.contents:GetVersionPaths(self:getTraceFunc())
            if versionPaths:Exists() then
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.X_package_json_has_a_typesVersions_entry_0_that_matches_compiler_version_1_looking_for_a_pattern_to_match_module_name_2, versionPaths.version, core.Version(), rest)
                end
                local pathPatterns = module.TryParsePatterns(versionPaths:GetPaths())
                local fromPaths = self:tryLoadModuleUsingPaths(ext, rest, packageDirectory, versionPaths:GetPaths(), pathPatterns, loader)
                if not R.shouldContinueSearching(fromPaths) then
                    return fromPaths
                end
            end
        end
    end
    return loader(ext, candidate)
end

function resolutionState:createResolvedModuleHandlingSymlink(result)
    local isExternalLibraryImport = result ~= nil and strings.Contains(result.path, "/node_modules/")
    if self.compilerOptions.preserveSymlinks ~= Tristate.TSTrue and
        isExternalLibraryImport and
        result.originalPath == "" and
        not tspath.IsExternalModuleNameRelative(self.name) then
        local originalPath, resolvedFileName = self:getOriginalAndResolvedFileName(result.path)
        if originalPath ~= "" then
            result.path = resolvedFileName
            result.originalPath = originalPath
        end
    end
    return self:createResolvedModule(result, isExternalLibraryImport)
end

function resolutionState:createResolvedModule(result, isExternalLibraryImport)
    local resolvedModule = module.NewResolvedModule()
    -- Go shares the slice header; copy so later appends to r.diagnostics are not observed.
    if self.diagnostics ~= nil then
        resolvedModule.resolutionDiagnostics = core.Slice(self.diagnostics, 0)
    end

    if result ~= nil then
        resolvedModule.resolvedFileName = result.path
        resolvedModule.originalPath = result.originalPath
        resolvedModule.isExternalLibraryImport = isExternalLibraryImport
        resolvedModule.resolvedUsingTsExtension = result.resolvedUsingTsExtension
        resolvedModule.resolvedUsingExtraExtensions = result.resolvedUsingExtraExtensions
        resolvedModule.extension = result.extension
        resolvedModule.packageId = result.packageId
    end
    return resolvedModule
end

function resolutionState:createResolvedTypeReferenceDirective(result, primary)
    local resolvedTypeReferenceDirective = module.NewResolvedTypeReferenceDirective()
    if self.diagnostics ~= nil then
        resolvedTypeReferenceDirective.resolutionDiagnostics = core.Slice(self.diagnostics, 0)
    end

    if R.isResolved(result) then
        if not tspath.ExtensionIsTs(result.extension) then
            error("expected a TypeScript file extension", 0)
        end
        resolvedTypeReferenceDirective.resolvedFileName = result.path
        resolvedTypeReferenceDirective.primary = primary
        resolvedTypeReferenceDirective.packageId = result.packageId
        resolvedTypeReferenceDirective.isExternalLibraryImport = strings.Contains(result.path, "/node_modules/")

        if self.compilerOptions.preserveSymlinks ~= Tristate.TSTrue then
            local originalPath, resolvedFileName = self:getOriginalAndResolvedFileName(result.path)
            if originalPath ~= "" then
                resolvedTypeReferenceDirective.resolvedFileName = resolvedFileName
                resolvedTypeReferenceDirective.originalPath = originalPath
            end
        end
    end
    return resolvedTypeReferenceDirective
end

function resolutionState:getOriginalAndResolvedFileName(fileName)
    local resolvedFileName = self:realPath(fileName)
    local comparePathsOptions = cpo(self.resolver.host:FS():UseCaseSensitiveFileNames(), self.resolver.host:GetCurrentDirectory())
    if tspath.ComparePaths(fileName, resolvedFileName, comparePathsOptions) == 0 then
        -- If the fileName and realpath are differing only in casing, prefer fileName
        -- so that we can issue correct errors for casing under forceConsistentCasingInFileNames
        return "", fileName
    end
    return fileName, resolvedFileName
end

function resolutionState:tryLoadModuleUsingOptionalResolutionSettings()
    local result = self:tryLoadModuleUsingPathsIfEligible()
    if not R.shouldContinueSearching(result) then
        return result
    end

    if not tspath.IsExternalModuleNameRelative(self.name) then
        -- No more tryLoadModuleUsingBaseUrl.
        return module.continueSearching()
    else
        return self:tryLoadModuleUsingRootDirs()
    end
end

function resolutionState:getParsedPatternsForPaths()
    if self.compilerOptions == self.resolver.compilerOptions then
        return self.resolver:getParsedPatternsForPaths()
    end
    if not self.parsedPatternsForPathsOnce then
        self.parsedPatternsForPathsOnce = true
        self.parsedPatternsForPaths = module.TryParsePatterns(self.compilerOptions.paths)
    end
    return self.parsedPatternsForPaths
end

local function orderedMapSize(m)
    if m == nil then
        return 0
    end
    return m:Size()
end

function resolutionState:tryLoadModuleUsingPathsIfEligible()
    if orderedMapSize(self.compilerOptions.paths) > 0 and not tspath.PathIsRelative(self.name) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.X_paths_option_is_specified_looking_for_a_pattern_to_match_module_name_0, self.name)
        end
    else
        return module.continueSearching()
    end
    local baseDirectory = self.compilerOptions:GetPathsBasePath(self.resolver.host:GetCurrentDirectory())
    local pathPatterns = self:getParsedPatternsForPaths()
    return self:tryLoadModuleUsingPaths(
        self.extensions,
        self.name,
        baseDirectory,
        self.compilerOptions.paths,
        pathPatterns,
        function(extensions, candidate)
            return self:nodeLoadModuleByRelativeName(extensions, candidate, true --[[considerPackageJson]])
        end
    )
end

function resolutionState:tryLoadModuleUsingPaths(extensions, moduleName, containingDirectory, paths, pathPatterns, loader)
    local matchedPattern = module.MatchPatternOrExact(pathPatterns, moduleName)
    if matchedPattern:IsValid() then
        local matchedStar = matchedPattern:MatchedText(moduleName)
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Module_name_0_matched_pattern_1, moduleName, matchedPattern.text)
        end
        for _, subst in ipairs(paths:GetOrZero(matchedPattern.text) or {}) do
            local path = strings.Replace(subst, "*", matchedStar, 1)
            local candidate = tspath.NormalizePath(tspath.CombinePaths(containingDirectory, path))
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Trying_substitution_0_candidate_module_location_Colon_1, subst, path)
            end
            -- A path mapping may have an extension
            local extensionFromSubst = tspath.TryGetExtensionFromPath(subst)
            if extensionFromSubst ~= "" then
                local p, ok = self:tryFile(candidate)
                if ok then
                    return module.newResolved({
                        path = p,
                        extension = extensionFromSubst,
                    })
                end
            end
            -- When the substitution path has an explicit extension, the extension came from the
            -- paths config, not the module specifier. Suppress resolvedUsingTsExtension in that case.
            local saveCandidateEndingIsFromConfig = self.candidateEndingIsFromConfig
            if extensionFromSubst ~= "" then
                self.candidateEndingIsFromConfig = true
            end
            local result = loader(extensions, candidate)
            self.candidateEndingIsFromConfig = saveCandidateEndingIsFromConfig
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
    end
    return module.continueSearching()
end

function resolutionState:tryLoadModuleUsingRootDirs()
    if core.Len(self.compilerOptions.rootDirs) == 0 then
        return module.continueSearching()
    end

    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.X_rootDirs_option_is_set_using_it_to_resolve_relative_module_name_0, self.name)
    end

    local candidate = tspath.NormalizePath(tspath.CombinePaths(self.containingDirectory, self.name))

    local matchedRootDir = ""
    local matchedNormalizedPrefix = ""
    for _, rootDir in ipairs(self.compilerOptions.rootDirs) do
        -- rootDirs are expected to be absolute
        -- in case of tsconfig.json this will happen automatically - compiler will expand relative names
        -- using location of tsconfig.json as base location
        local normalizedRoot = tspath.NormalizePath(rootDir)
        if not strings.HasSuffix(normalizedRoot, "/") then
            normalizedRoot = normalizedRoot .. "/"
        end
        local isLongestMatchingPrefix = strings.HasPrefix(candidate, normalizedRoot) and
            (matchedNormalizedPrefix == "" or #matchedNormalizedPrefix < #normalizedRoot)

        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Checking_if_0_is_the_longest_matching_prefix_for_1_2, normalizedRoot, candidate, isLongestMatchingPrefix)
        end

        if isLongestMatchingPrefix then
            matchedNormalizedPrefix = normalizedRoot
            matchedRootDir = rootDir
        end
    end

    if matchedNormalizedPrefix ~= "" then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Longest_matching_prefix_for_0_is_1, candidate, matchedNormalizedPrefix)
        end
        local suffix = string.sub(candidate, #matchedNormalizedPrefix + 1)

        -- first - try to load from a initial location
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Loading_0_from_the_root_dir_1_candidate_location_2, suffix, matchedNormalizedPrefix, candidate)
        end
        local function loader(extensions, cand)
            return self:nodeLoadModuleByRelativeName(extensions, cand, true --[[considerPackageJson]])
        end
        local resolvedFileName = loader(self.extensions, candidate)
        if not R.shouldContinueSearching(resolvedFileName) then
            return resolvedFileName
        end

        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Trying_other_entries_in_rootDirs)
        end
        -- then try to resolve using remaining entries in rootDirs
        for _, rootDir in ipairs(self.compilerOptions.rootDirs) do
            if rootDir ~= matchedRootDir then
                local cand = tspath.CombinePaths(tspath.NormalizePath(rootDir), suffix)
                if self.tracer ~= nil then
                    tracer.write(self.tracer, diagnostics.Loading_0_from_the_root_dir_1_candidate_location_2, suffix, rootDir, cand)
                end
                local result = loader(self.extensions, cand)
                if not R.shouldContinueSearching(result) then
                    return result
                end
            end
        end
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Module_resolution_using_rootDirs_has_failed)
        end
    end
    return module.continueSearching()
end

function resolutionState:nodeLoadModuleByRelativeName(extensions, candidate, considerPackageJson)
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Loading_module_as_file_Slash_folder_candidate_module_location_0_target_file_types_Colon_1, candidate, module.extensions_String(extensions))
    end
    if not tspath.HasTrailingDirectorySeparator(candidate) then
        local parentOfCandidate = tspath.GetDirectoryPath(candidate)
        if not self.resolver.host:FS():DirectoryExists(parentOfCandidate) then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, parentOfCandidate)
            end
            return module.continueSearching()
        end
        local resolvedFromFile = self:loadModuleFromFile(extensions, candidate)
        if resolvedFromFile ~= nil then
            if considerPackageJson then
                local packageDirectory = module.ParseNodeModuleFromPath(resolvedFromFile.path, false --[[isFolder]])
                if packageDirectory ~= "" then
                    resolvedFromFile.packageId = self:getPackageId(resolvedFromFile.path, self:getPackageJsonInfo(packageDirectory))
                end
            end
            return resolvedFromFile
        end
    end
    if not self.resolver.host:FS():DirectoryExists(candidate) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, candidate)
        end
        return module.continueSearching()
    end
    -- esm mode relative imports shouldn't do any directory lookups (either inside `package.json`
    -- files or implicit `index.js`es). This is a notable departure from cjs norms, where `./foo/pkg`
    -- could have been redirected by `./foo/pkg/package.json` to an arbitrary location!
    if not self.esmMode then
        return self:loadNodeModuleFromDirectory(extensions, candidate, considerPackageJson)
    end
    return module.continueSearching()
end

function resolutionState:loadModuleFromFile(extensions, candidate)
    -- ./foo.js -> ./foo.ts
    local resolvedByReplacingExtension = self:loadModuleFromFileNoImplicitExtensions(extensions, candidate)
    if resolvedByReplacingExtension ~= nil then
        return resolvedByReplacingExtension
    end

    -- ./foo -> ./foo.ts
    if not self.esmMode then
        return self:tryAddingExtensions(candidate, extensions, "")
    end

    return module.continueSearching()
end

function resolutionState:loadModuleFromFileNoImplicitExtensions(extensions, candidate)
    local base = tspath.GetBaseFileName(candidate)
    if not strings.Contains(base, ".") then
        return module.continueSearching() -- extensionless import, no lookups performed, since we don't support extensionless files
    end
    local extensionless = tspath.RemoveFileExtension(candidate)
    if extensionless == candidate then
        -- Once TS native extensions are handled, handle arbitrary extensions for declaration file mapping
        local extension = tspath.GetLongestExtensionFromPath(candidate, self.resolver.extraExtensions, false)
        if extension == "" then
            extension = string.sub(candidate, strings.LastIndex(candidate, ".") + 1)
        end
        extensionless = tspath.RemoveExtension(candidate, extension)
    end

    local extension = string.sub(candidate, #extensionless + 1)
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.File_name_0_has_a_1_extension_stripping_it, candidate, extension)
    end
    return self:tryAddingExtensions(extensionless, extensions, extension)
end

function resolutionState:tryAddingExtensions(extensionless, extensions, originalExtension)
    local directory = tspath.GetDirectoryPath(extensionless)
    if directory ~= "" and not self.resolver.host:FS():DirectoryExists(directory) then
        return module.continueSearching()
    end

    local function try(extension, resolvedUsingTsExtension)
        return self:tryExtension(extension, extensionless, resolvedUsingTsExtension)
    end
    local result
    local o = originalExtension

    if o == tspath.ExtensionMjs or o == tspath.ExtensionMts or o == tspath.ExtensionDmts then
        if extensions & extensionsTypeScript ~= 0 then
            result = try(tspath.ExtensionMts, o == tspath.ExtensionMts or o == tspath.ExtensionDmts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsDeclaration ~= 0 then
            result = try(tspath.ExtensionDmts, o == tspath.ExtensionMts or o == tspath.ExtensionDmts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsJavaScript ~= 0 then
            result = try(tspath.ExtensionMjs, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    elseif o == tspath.ExtensionCjs or o == tspath.ExtensionCts or o == tspath.ExtensionDcts then
        if extensions & extensionsTypeScript ~= 0 then
            result = try(tspath.ExtensionCts, o == tspath.ExtensionCts or o == tspath.ExtensionDcts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsDeclaration ~= 0 then
            result = try(tspath.ExtensionDcts, o == tspath.ExtensionCts or o == tspath.ExtensionDcts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsJavaScript ~= 0 then
            result = try(tspath.ExtensionCjs, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    elseif o == tspath.ExtensionJson then
        if extensions & extensionsDeclaration ~= 0 then
            result = try(".d.json.ts", false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsJson ~= 0 then
            result = try(tspath.ExtensionJson, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    elseif o == tspath.ExtensionTsx or o == tspath.ExtensionJsx then
        -- basically idendical to the ts/js case below, but prefers matching tsx and jsx files exactly before falling back to the ts or js file path
        -- (historically, we disallow having both a a.ts and a.tsx file in the same compilation, since their outputs clash)
        -- TODO: We should probably error if `"./a.tsx"` resolved to `"./a.ts"`, right?
        if extensions & extensionsTypeScript ~= 0 then
            result = try(tspath.ExtensionTsx, o == tspath.ExtensionTsx)
            if not R.shouldContinueSearching(result) then
                return result
            end
            result = try(tspath.ExtensionTs, o == tspath.ExtensionTsx)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsDeclaration ~= 0 then
            result = try(tspath.ExtensionDts, o == tspath.ExtensionTsx)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsJavaScript ~= 0 then
            result = try(tspath.ExtensionJsx, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
            result = try(tspath.ExtensionJs, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    elseif o == tspath.ExtensionTs or o == tspath.ExtensionDts or o == tspath.ExtensionJs or o == "" then
        if extensions & extensionsTypeScript ~= 0 then
            result = try(tspath.ExtensionTs, o == tspath.ExtensionTs or o == tspath.ExtensionDts)
            if not R.shouldContinueSearching(result) then
                return result
            end
            result = try(tspath.ExtensionTsx, o == tspath.ExtensionTs or o == tspath.ExtensionDts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsDeclaration ~= 0 then
            result = try(tspath.ExtensionDts, o == tspath.ExtensionTs or o == tspath.ExtensionDts)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if extensions & extensionsJavaScript ~= 0 then
            result = try(tspath.ExtensionJs, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
            result = try(tspath.ExtensionJsx, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        if self.isConfigLookup then
            result = try(tspath.ExtensionJson, false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    else
        if strings.SliceContains(self.resolver.extraExtensions, o) then
            -- A fully specified import of an extraExtension resolves directly to the file.
            result = try(o, false)
            if not R.shouldContinueSearching(result) then
                result.resolvedUsingExtraExtensions = true
                return result
            end
        end
        if extensions & extensionsDeclaration ~= 0 and not tspath.IsDeclarationFileName(extensionless .. o) then
            result = try(".d" .. o .. ".ts", false)
            if not R.shouldContinueSearching(result) then
                return result
            end
        end
        return module.continueSearching()
    end
end

function resolutionState:tryExtension(extension, extensionless, resolvedUsingTsExtension)
    local fileName = extensionless .. extension
    local path, ok = self:tryFile(fileName)
    if ok then
        return module.newResolved({
            path = path,
            extension = extension,
            resolvedUsingTsExtension = not self.candidateEndingIsFromConfig and resolvedUsingTsExtension,
        })
    end
    return module.continueSearching()
end

-- Returns path, ok.
function resolutionState:tryFile(fileName)
    if core.Len(self.compilerOptions.moduleSuffixes) == 0 then
        return fileName, self:tryFileLookup(fileName)
    end

    local ext = tspath.TryGetExtensionFromPath(fileName)
    local fileNameNoExtension = tspath.RemoveExtension(fileName, ext)
    for _, suffix in ipairs(self.compilerOptions.moduleSuffixes) do
        local path = fileNameNoExtension .. suffix .. ext
        if self:tryFileLookup(path) then
            return path, true
        end
    end
    return fileName, false
end

function resolutionState:tryFileLookup(fileName)
    if self.resolver.host:FS():FileExists(fileName) then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.File_0_exists_use_it_as_a_name_resolution_result, fileName)
        end
        return true
    elseif self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.File_0_does_not_exist, fileName)
    end
    return false
end

function resolutionState:loadNodeModuleFromDirectory(extensions, candidate, considerPackageJson)
    local packageInfo = nil
    if considerPackageJson then
        packageInfo = self:getPackageJsonInfo(candidate)
    end

    return self:loadNodeModuleFromDirectoryWorker(extensions, candidate, packageInfo)
end

function resolutionState:loadNodeModuleFromDirectoryWorker(ext, candidate, packageInfo)
    local packageFile = ""
    local versionPaths = packagejson.newVersionPaths()
    local fs = self.resolver.host:FS()
    if InfoCacheEntry.Exists(packageInfo) then
        versionPaths = packageInfo.contents:GetVersionPaths(self:getTraceFunc())
        if tspath.ComparePaths(candidate, packageInfo.packageDirectory, cpo(fs:UseCaseSensitiveFileNames(), "")) == 0 then
            local file, ok = self:getPackageFile(ext, packageInfo)
            if ok then
                packageFile = file
            end
        end
    end

    local function loader(extensions, cand)
        local fromFile = self:loadFileNameFromPackageJSONField(extensions, cand, packageFile)
        if not R.shouldContinueSearching(fromFile) then
            return fromFile
        end

        -- Even if `extensions == extensionsDeclaration`, we can still look up a .ts file as a result of package.json "types"
        -- !!! should we not set this before the filename lookup above?
        local expandedExtensions = extensions
        if extensions == extensionsDeclaration then
            expandedExtensions = extensionsTypeScript | extensionsDeclaration
        end

        -- Disable `esmMode` for the resolution of the package path for CJS-mode packages (so the `main` field can omit extensions)
        local saveESMMode = self.esmMode
        local saveCandidateEndingIsFromConfig = self.candidateEndingIsFromConfig
        self.candidateEndingIsFromConfig = true
        if InfoCacheEntry.Exists(packageInfo) and packageInfo.contents.type.value ~= "module" then
            self.esmMode = false
        end
        local result = self:nodeLoadModuleByRelativeName(expandedExtensions, cand, false --[[considerPackageJson]])
        self.esmMode = saveESMMode
        self.candidateEndingIsFromConfig = saveCandidateEndingIsFromConfig
        return result
    end

    local indexPath
    if self.isConfigLookup then
        indexPath = tspath.CombinePaths(candidate, "tsconfig")
    else
        indexPath = tspath.CombinePaths(candidate, "index")
    end

    if versionPaths:Exists() and (packageFile == "" or tspath.ContainsPath(candidate, packageFile, cpo(false, ""))) then
        local moduleName
        if packageFile ~= "" then
            moduleName = tspath.GetRelativePathFromDirectory(candidate, packageFile, cpo(false, ""))
        else
            moduleName = tspath.GetRelativePathFromDirectory(candidate, indexPath, cpo(false, ""))
        end
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.X_package_json_has_a_typesVersions_entry_0_that_matches_compiler_version_1_looking_for_a_pattern_to_match_module_name_2, versionPaths.version, core.Version(), moduleName)
        end
        local pathPatterns = module.TryParsePatterns(versionPaths:GetPaths())
        local result = self:tryLoadModuleUsingPaths(ext, moduleName, candidate, versionPaths:GetPaths(), pathPatterns, loader)
        if not R.shouldContinueSearching(result) then
            if result.packageId.name ~= "" then
                -- !!! are these asserts really necessary?
                error("expected packageId to be empty", 0)
            end
            return result
        end
    end

    if packageFile ~= "" then
        local packageFileResult = loader(ext, packageFile)
        if not R.shouldContinueSearching(packageFileResult) then
            if packageFileResult.packageId.name ~= "" then
                -- !!! are these asserts really necessary?
                error("expected packageId to be empty", 0)
            end
            return packageFileResult
        end
    end

    -- ESM mode resolutions don't do package 'index' lookups
    if not self.esmMode then
        if not fs:DirectoryExists(candidate) then
            return module.continueSearching()
        end
        return self:loadModuleFromFile(ext, indexPath)
    end
    return module.continueSearching()
end

-- This function is only ever called with paths written in package.json files - never
-- module specifiers written in source files - and so it always allows the
-- candidate to end with a TS extension (but will also try substituting a JS extension for a TS extension).
function resolutionState:loadFileNameFromPackageJSONField(extensions, candidate, packageJSONValue)
    if extensions & extensionsTypeScript ~= 0 and tspath.HasImplementationTSFileExtension(candidate) or extensions & extensionsDeclaration ~= 0 and tspath.IsDeclarationFileName(candidate) then
        local path, ok = self:tryFile(candidate)
        if ok then
            local extension = tspath.TryExtractTSExtension(path)
            -- resolvedUsingTsExtension should be true when the pattern ends with * and the
            -- candidate file ends in a TS extension. This means the * matched a TS extension
            -- from the module specifier. For example:
            -- - import "pkg/foo.ts" with pattern "./*" -> true
            -- - import "pkg/foo.ts.omg" with pattern "./*.omg" -> true (star matched .ts)
            -- - import "pkg/foo" with pattern "./*.ts" -> false (extension in pattern, not specifier)
            local resolvedUsingTsExtension = strings.HasSuffix(packageJSONValue, "*") and extension ~= ""
            return module.newResolved({
                path = path,
                extension = extension,
                resolvedUsingTsExtension = resolvedUsingTsExtension,
            })
        end
        return module.continueSearching()
    end

    if self.isConfigLookup and extensions & extensionsJson ~= 0 and tspath.FileExtensionIs(candidate, tspath.ExtensionJson) then
        local path, ok = self:tryFile(candidate)
        if ok then
            return module.newResolved({
                path = path,
                extension = tspath.ExtensionJson,
            })
        end
    end

    return self:loadModuleFromFileNoImplicitExtensions(extensions, candidate)
end

-- Returns file, ok.
function resolutionState:getPackageFile(extensions, packageInfo)
    if not InfoCacheEntry.Exists(packageInfo) then
        return "", false
    end
    if self.isConfigLookup then
        return self:getPackageJSONPathField("tsconfig", packageInfo.contents.tsConfig, packageInfo.packageDirectory)
    end
    if extensions & extensionsDeclaration ~= 0 then
        local packageFile, ok = self:getPackageJSONPathField("typings", packageInfo.contents.typings, packageInfo.packageDirectory)
        if ok then
            return packageFile, ok
        end
        packageFile, ok = self:getPackageJSONPathField("types", packageInfo.contents.types, packageInfo.packageDirectory)
        if ok then
            return packageFile, ok
        end
    end
    if extensions & (extensionsImplementationFiles | extensionsDeclaration) ~= 0 then
        return self:getPackageJSONPathField("main", packageInfo.contents.main, packageInfo.packageDirectory)
    end
    return "", false
end

function resolutionState:getPackageJsonInfo(packageDirectory)
    local packageJsonPath = tspath.CombinePaths(packageDirectory, "package.json")
    local fs = self.resolver.host:FS()

    local existing = self.resolver.packageJsonInfoCache:Get(packageJsonPath)
    if existing ~= nil then
        if existing.contents ~= nil then
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.File_0_exists_according_to_earlier_cached_lookups, packageJsonPath)
            end
            return existing:WithPackageDirectory(packageDirectory)
        else
            if existing.directoryExists and self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.File_0_does_not_exist_according_to_earlier_cached_lookups, packageJsonPath)
            end
            return nil
        end
    end

    local directoryExists = fs:DirectoryExists(packageDirectory)
    if directoryExists and fs:FileExists(packageJsonPath) then
        -- Ignore error
        local contents = fs:ReadFile(packageJsonPath)
        local packageJsonContent, err = packagejson.Parse(contents or "")
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Found_package_json_at_0, packageJsonPath)
        end
        local result = packagejson.NewInfoCacheEntry(packageDirectory, true, packagejson.NewPackageJson(packageJsonContent, err == nil))
        result = self.resolver.packageJsonInfoCache:Set(packageJsonPath, result)
        return result:WithPackageDirectory(packageDirectory)
    else
        if directoryExists and self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.File_0_does_not_exist, packageJsonPath)
        end
        self.resolver.packageJsonInfoCache:Set(packageJsonPath, packagejson.NewInfoCacheEntry(packageDirectory, directoryExists, nil))
    end
    return nil
end

function resolutionState:getPackageId(resolvedFileName, packageInfo)
    if InfoCacheEntry.Exists(packageInfo) then
        local packageJsonContent = packageInfo.contents
        local name, ok = packageJsonContent.name:GetValue()
        if ok then
            local version, ok2 = packageJsonContent.version:GetValue()
            if ok2 then
                local subModuleName = ""
                if #resolvedFileName > #packageInfo.packageDirectory then
                    subModuleName = string.sub(resolvedFileName, #packageInfo.packageDirectory + 2)
                end
                return module.NewPackageId(
                    name,
                    subModuleName,
                    version,
                    self:readPackageJsonPeerDependencies(packageInfo)
                )
            end
        end
    end
    return module.NewPackageId()
end

function resolutionState:readPackageJsonPeerDependencies(packageJsonInfo)
    local peerDependencies = packageJsonInfo.contents.peerDependencies
    local ok = self:validatePackageJSONField("peerDependencies", peerDependencies)
    if not ok or next(peerDependencies.value or {}) == nil then
        return ""
    end
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.X_package_json_has_a_peerDependencies_field)
    end
    local packageDirectory = self:realPath(packageJsonInfo.packageDirectory)
    local nodeModulesIndex = strings.LastIndex(packageDirectory, "/node_modules")
    if nodeModulesIndex == -1 then
        return ""
    end
    local nodeModules = string.sub(packageDirectory, 1, nodeModulesIndex + #"/node_modules") .. "/"
    local names = {}
    for name in pairs(peerDependencies.value) do
        names[#names + 1] = name
    end
    table.sort(names)
    local builder = {}
    for _, name in ipairs(names) do
        local peerPackageJson = self:getPackageJsonInfo(nodeModules .. name)
        if InfoCacheEntry.Exists(peerPackageJson) then
            local version = peerPackageJson.contents.version.value
            builder[#builder + 1] = "+"
            builder[#builder + 1] = name
            builder[#builder + 1] = "@"
            builder[#builder + 1] = version
            if self.tracer ~= nil then
                tracer.write(self.tracer, diagnostics.Found_peerDependency_0_with_1_version, name, version)
            end
        elseif self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Failed_to_find_peerDependency_0, name)
        end
    end
    return table.concat(builder)
end

function resolutionState:realPath(path)
    local rp = tspath.NormalizePath(self.resolver.host:FS():Realpath(path))
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.Resolving_real_path_for_0_result_1, path, rp)
    end
    return rp
end

function resolutionState:validatePackageJSONField(fieldName, field)
    if field:IsPresent() then
        if field:IsValid() then
            return true
        end
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.Expected_type_of_0_field_in_package_json_to_be_1_got_2, fieldName, field:ExpectedJSONType(), field:ActualJSONType())
        end
    end
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.X_package_json_does_not_have_a_0_field, fieldName)
    end
    return false
end

-- Returns path, ok.
function resolutionState:getPackageJSONPathField(fieldName, field, directory)
    if not self:validatePackageJSONField(fieldName, field) then
        return "", false
    end
    if field.value == "" then
        if self.tracer ~= nil then
            tracer.write(self.tracer, diagnostics.X_package_json_had_a_falsy_0_field, fieldName)
        end
        return "", false
    end
    local path = tspath.NormalizePath(tspath.CombinePaths(directory, field.value))
    if self.tracer ~= nil then
        tracer.write(self.tracer, diagnostics.X_package_json_has_0_field_1_that_references_2, fieldName, field.value, path)
    end
    return path, true
end

function resolutionState:conditionMatches(condition)
    if condition == "default" or strings.SliceContains(self.conditions, condition) then
        return true
    end
    if not strings.SliceContains(self.conditions, "types") then
        return false -- only apply versioned types conditions if the types condition is applied
    end
    return module.IsApplicableVersionedTypesKey(condition)
end

function resolutionState:getTraceFunc()
    if self.tracer ~= nil then
        local t = self.tracer
        return function(m, ...)
            tracer.write(t, m, ...)
        end
    end
    return nil
end

function module.GetConditions(options, resolutionMode)
    local moduleResolution = options:GetModuleResolutionKind()
    if resolutionMode == ModuleKind.None and moduleResolution == ModuleResolutionKind.Bundler then
        resolutionMode = ModuleKind.ESNext
    end
    local conditions = {}
    if resolutionMode == ModuleKind.ESNext then
        conditions[#conditions + 1] = "import"
    else
        conditions[#conditions + 1] = "require"
    end

    if options.noDtsResolution ~= Tristate.TSTrue then
        conditions[#conditions + 1] = "types"
    end
    if moduleResolution ~= ModuleResolutionKind.Bundler then
        conditions[#conditions + 1] = "node"
    end
    conditions = core.Concatenate(conditions, options.customConditions)
    return conditions
end

function module.getNodeResolutionFeatures(options)
    local features = NodeResolutionFeatures.None

    local kind = options:GetModuleResolutionKind()
    if kind == ModuleResolutionKind.Node16 then
        features = NodeResolutionFeatures.Node16Default
    elseif kind == ModuleResolutionKind.NodeNext then
        features = NodeResolutionFeatures.NodeNextDefault
    elseif kind == ModuleResolutionKind.Bundler then
        features = NodeResolutionFeatures.BundlerDefault
    end
    if options.resolvePackageJsonExports == Tristate.TSTrue then
        features = features | NodeResolutionFeatures.Exports
    elseif options.resolvePackageJsonExports == Tristate.TSFalse then
        features = features & ~NodeResolutionFeatures.Exports
    end
    if options.resolvePackageJsonImports == Tristate.TSTrue then
        features = features | NodeResolutionFeatures.Imports
    elseif options.resolvePackageJsonImports == Tristate.TSFalse then
        features = features & ~NodeResolutionFeatures.Imports
    end
    return features
end

function module.moveToNextDirectorySeparatorIfAvailable(path, prevSeparatorIndex, isFolder)
    local offset = prevSeparatorIndex + 1
    local nextSeparatorIndex = -1
    if offset <= #path then
        nextSeparatorIndex = strings.Index(string.sub(path, offset + 1), "/")
    end
    if nextSeparatorIndex == -1 then
        if isFolder then
            return #path
        end
        return prevSeparatorIndex
    end
    return nextSeparatorIndex + offset
end

-- ParsedPatterns: { matchableStringSet = set (string -> true), patterns = []core.Pattern }
local ParsedPatterns = {}
ParsedPatterns.__index = ParsedPatterns
module.ParsedPatterns = ParsedPatterns

function Resolver:getParsedPatternsForPaths()
    if not self.parsedPatternsForPathsOnce then
        self.parsedPatternsForPathsOnce = true
        self.parsedPatternsForPaths = module.TryParsePatterns(self.compilerOptions.paths)
    end
    return self.parsedPatternsForPaths
end

local function orderedMapKeys(m)
    local keys = {}
    if m ~= nil then
        for k in m:Keys() do
            keys[#keys + 1] = k
        end
    end
    return keys
end

function module.TryParsePatterns(pathMappings)
    local paths = orderedMapKeys(pathMappings)

    local patterns = nil
    local matchableStringSet = {}

    for _, path in ipairs(paths) do
        local pattern = core.TryParsePattern(path)
        if pattern:IsValid() then
            if pattern.starIndex == -1 then
                matchableStringSet[path] = true
            else
                patterns = core.Append(patterns, pattern)
            end
        end
    end
    return setmetatable({
        matchableStringSet = matchableStringSet,
        patterns = patterns,
    }, ParsedPatterns)
end

function module.newPattern(text, starIndex)
    return setmetatable({ text = text, starIndex = starIndex }, core.Pattern)
end

function module.MatchPatternOrExact(patterns, candidate)
    if patterns.matchableStringSet[candidate] then
        return module.newPattern(candidate, -1)
    end
    if core.Len(patterns.patterns) == 0 then
        return module.newPattern("", 0)
    end
    local best = core.FindBestPatternMatch(patterns.patterns, core.Identity, candidate)
    if best == nil then
        return module.newPattern("", 0)
    end
    return best
end

-- If you import from "." inside a containing directory "/foo", the result of `tspath.NormalizePath`
-- would be "/foo", but this loses the information that `foo` is a directory and we intended
-- to look inside of it. The Node CommonJS resolution algorithm doesn't call this out
-- (https://nodejs.org/api/modules.html#all-together), but it seems that module paths ending
-- in `.` are actually normalized to `./` before proceeding with the resolution algorithm.
function module.normalizePathForCJSResolution(containingDirectory, moduleName)
    local combined = tspath.CombinePaths(containingDirectory, moduleName)
    local parts = tspath.GetPathComponents(combined, "")
    local lastPart = parts[#parts]
    if lastPart == "." or lastPart == ".." then
        return tspath.EnsureTrailingDirectorySeparator(tspath.NormalizePath(combined))
    end
    return tspath.NormalizePath(combined)
end

function module.matchesPatternWithTrailer(target, name)
    if strings.HasSuffix(target, "*") then
        return false
    end
    local before, after, ok = strings.Cut(target, "*")
    if not ok then
        return false
    end
    return strings.HasPrefix(name, before) and strings.HasSuffix(name, after)
end

-- True if `extension` is one of the supported `extensions`.
function module.extensionIsOk(extensions, extension)
    return (extensions & extensionsJavaScript ~= 0 and (extension == tspath.ExtensionJs or extension == tspath.ExtensionJsx or extension == tspath.ExtensionMjs or extension == tspath.ExtensionCjs)) or
        (extensions & extensionsTypeScript ~= 0 and (extension == tspath.ExtensionTs or extension == tspath.ExtensionTsx or extension == tspath.ExtensionMts or extension == tspath.ExtensionCts)) or
        (extensions & extensionsDeclaration ~= 0 and (extension == tspath.ExtensionDts or extension == tspath.ExtensionDmts or extension == tspath.ExtensionDcts)) or
        (extensions & extensionsJson ~= 0 and extension == tspath.ExtensionJson)
end

function module.ResolveConfig(moduleName, containingFile, host)
    local options = core.NewCompilerOptions()
    options.moduleResolution = ModuleResolutionKind.NodeNext
    local resolver = module.NewResolver(host, options, "", "", nil)
    return resolver:resolveConfig(moduleName, containingFile)
end

function module.GetAutomaticTypeDirectiveNames(options, host)
    if not options:UsesWildcardTypes() then
        if options.types ~= nil then
            return options.types
        end
        return {}
    end

    -- Walk the primary type lookup locations
    local wildcardMatches = nil
    local typeRoots = options:GetEffectiveTypeRoots(host:GetCurrentDirectory())
    for _, root in ipairs(typeRoots or {}) do
        if host:FS():DirectoryExists(root) then
            for _, typeDirectivePath in ipairs(host:FS():GetAccessibleEntries(root).directories or {}) do
                local normalized = tspath.NormalizePath(typeDirectivePath)
                local packageJsonPath = tspath.CombinePaths(root, normalized, "package.json")
                local isNotNeededPackage = false
                if host:FS():FileExists(packageJsonPath) then
                    local contents = host:FS():ReadFile(packageJsonPath)
                    local packageJsonContent = packagejson.Parse(contents or "")
                    -- `types-publisher` sometimes creates packages with `"typings": null` for packages that don't provide their own types.
                    -- See `createNotNeededPackageJSON` in the types-publisher` repo.
                    isNotNeededPackage = packageJsonContent.typings.null
                end
                if not isNotNeededPackage then
                    local baseFileName = tspath.GetBaseFileName(normalized)
                    if not strings.HasPrefix(baseFileName, ".") then
                        wildcardMatches = core.Append(wildcardMatches, baseFileName)
                    end
                end
            end
        end
    end

    -- Order potentially matters in program construction, so substitute
    -- in the wildcard in the position it was specified in the types array
    local result = nil
    for _, t in ipairs(options.types or {}) do
        if t == "*" then
            result = core.AppendAll(result, wildcardMatches)
        else
            result = core.Append(result, t)
        end
    end
    return core.Deduplicate(result)
end

-- Ending: module.Ending.Fixed / ExtensionChangeable / Changeable (generated constants).
--   Fixed indicates that the module specifier cannot be changed without changing its resolution.
--   ExtensionChangeable indicates that the module specifier's extension portion was inferred from a
--   file on disk, so an interchangeable one could be used instead (e.g. replacing .d.ts with .js).
--   Changeable indicates that the module specifier's file name and extension portion were inferred
--   from a file on disk without being matched as part of an 'exports' pattern, so can be changed according
--   to the importer's module resolution rules (e.g. an /index.d.ts may be dropped entirely in CommonJS settings).
local Ending = module.Ending

local ResolvedEntrypoint = {}
ResolvedEntrypoint.__index = ResolvedEntrypoint
module.ResolvedEntrypoint = ResolvedEntrypoint

function ResolvedEntrypoint:SymlinkOrRealpath()
    if self.originalFileName ~= "" then
        return self.originalFileName
    end
    return self.resolvedFileName
end

function Resolver:GetEntrypointsFromPackageJsonInfo(packageJson, packageName, enableDirectorySearch)
    local extensions = extensionsTypeScript | extensionsDeclaration
    local features = NodeResolutionFeatures.All
    local state = module.newResolutionStateStruct({ resolver = self, extensions = extensions, features = features, compilerOptions = self.compilerOptions })
    if InfoCacheEntry.Exists(packageJson) and packageJson.contents.exports:IsPresent() then
        local entrypoints = state:loadEntrypointsFromExportMap(packageJson, packageName, packageJson.contents.exports)
        return entrypoints
    end

    local result = nil
    local mainResolution = state:loadNodeModuleFromDirectoryWorker(
        extensions,
        packageJson.packageDirectory,
        packageJson
    )

    if R.isResolved(mainResolution) then
        result = core.Append(result, self:createResolvedEntrypointHandlingSymlink(
            mainResolution.path,
            packageName,
            nil,
            nil,
            Ending.Fixed
        ))
    end

    if enableDirectorySearch then
        local otherFiles = vfsmatch.ReadDirectory(
            self.host:FS(),
            self.host:GetCurrentDirectory(),
            packageJson.packageDirectory,
            module.extensions_Array(extensions),
            { "node_modules" },
            { "**/*" },
            vfsmatch.UnlimitedDepth
        )

        local comparePathsOptions = cpo(self.host:FS():UseCaseSensitiveFileNames(), "")
        for _, file in ipairs(otherFiles or {}) do
            if not (R.isResolved(mainResolution) and tspath.ComparePaths(file, mainResolution.path, comparePathsOptions) == 0) then
                result = core.Append(result, self:createResolvedEntrypointHandlingSymlink(
                    file,
                    tspath.ResolvePath(packageName, tspath.GetRelativePathFromDirectory(packageJson.packageDirectory, file, comparePathsOptions)),
                    nil,
                    nil,
                    Ending.Changeable
                ))
            end
        end
    end

    if core.Len(result) > 0 then
        return result
    end
    return nil
end

function Resolver:createResolvedEntrypointHandlingSymlink(fileName, moduleSpecifier, includeConditions, excludeConditions, ending)
    local originalFileName = ""
    local resolvedFileName = fileName
    local realPath = self.host:FS():Realpath(fileName)
    if realPath ~= fileName then
        originalFileName = fileName
        resolvedFileName = realPath
    end
    return setmetatable({
        -- OriginalFileName is the symlink path if the entrypoint was discovered at a symlink. Empty otherwise.
        originalFileName = originalFileName,
        -- ResolvedFileName is the real path to the entrypoint file.
        resolvedFileName = resolvedFileName,
        moduleSpecifier = moduleSpecifier,
        -- IncludeConditions are the conditions that a resolver must have to reach this entrypoint.
        includeConditions = includeConditions,
        -- ExcludeConditions are the conditions that a resolver must not have to reach this entrypoint.
        excludeConditions = excludeConditions,
        -- Ending indicates whether the file name and extension portion of ModuleSpecifier is fixed or can be changed.
        ending = ending,
    }, ResolvedEntrypoint)
end

local function cloneSet(s)
    if s == nil then
        return nil
    end
    return s:Clone()
end

function resolutionState:loadEntrypointsFromExportMap(
    packageJson,
    packageName,
    exports
)
    local loadEntrypointsFromTargetExports
    local entrypoints = nil

    loadEntrypointsFromTargetExports = function(subpath, includeConditions, excludeConditions, exp)
        if exp.type == JSONValueType.String and strings.HasPrefix(exp:AsString(), "./") then
            local str = exp:AsString()
            if strings.Contains(str, "*") then
                if strings.Index(str, "*") ~= strings.LastIndex(str, "*") then
                    return
                end
                local patternPath = tspath.ResolvePath(packageJson.packageDirectory, str)
                local leadingSlice, trailingSlice = strings.Cut(patternPath, "*")
                local caseSensitive = self.resolver.host:FS():UseCaseSensitiveFileNames()
                local files = vfsmatch.ReadDirectory(
                    self.resolver.host:FS(),
                    self.resolver.host:GetCurrentDirectory(),
                    packageJson.packageDirectory,
                    module.extensions_Array(self.extensions),
                    nil,
                    {
                        tspath.ChangeFullExtension(strings.Replace(str, "*", "**/*", 1), ".*"),
                    },
                    vfsmatch.UnlimitedDepth
                )
                for _, file in ipairs(files or {}) do
                    local matchedStar, ok = self:getMatchedStarForPatternEntrypoint(file, leadingSlice, trailingSlice, caseSensitive)
                    if ok then
                        local moduleSpecifier = tspath.ResolvePath(packageName, strings.Replace(subpath, "*", matchedStar, 1))
                        entrypoints = core.Append(entrypoints, self.resolver:createResolvedEntrypointHandlingSymlink(
                            file,
                            moduleSpecifier,
                            includeConditions,
                            excludeConditions,
                            core.IfElse(strings.HasSuffix(str, "*"), Ending.ExtensionChangeable, Ending.Fixed)
                        ))
                    end
                end
            else
                local partsAfterFirst = core.Slice(tspath.GetPathComponents(str, ""), 2)
                if hasInvalidSegment(partsAfterFirst) then
                    return
                end
                local resolvedTarget = tspath.ResolvePath(packageJson.packageDirectory, str)
                local result = self:loadFileNameFromPackageJSONField(self.extensions, resolvedTarget, str)
                if R.isResolved(result) then
                    entrypoints = core.Append(entrypoints, self.resolver:createResolvedEntrypointHandlingSymlink(
                        result.path,
                        tspath.ResolvePath(packageName, subpath),
                        includeConditions,
                        excludeConditions,
                        core.IfElse(strings.HasSuffix(str, "*"), Ending.ExtensionChangeable, Ending.Fixed)
                    ))
                end
            end
        elseif exp.type == JSONValueType.Array then
            for _, element in ipairs(exp:AsArray()) do
                loadEntrypointsFromTargetExports(subpath, includeConditions, excludeConditions, element)
            end
        elseif exp.type == JSONValueType.Object then
            local prevConditions = {}
            for condition, export in exp:AsObject():Entries() do
                if not (excludeConditions ~= nil and excludeConditions:Has(condition)) then
                    local conditionAlwaysMatches = condition == "default" or condition == "types" or module.IsApplicableVersionedTypesKey(condition)
                    local newIncludeConditions = includeConditions
                    if not conditionAlwaysMatches then
                        newIncludeConditions = cloneSet(includeConditions)
                        excludeConditions = cloneSet(excludeConditions)
                        if newIncludeConditions == nil then
                            newIncludeConditions = collections.NewSetWithSizeHint(0)
                        end
                        newIncludeConditions:Add(condition)
                        for _, prevCondition in ipairs(prevConditions) do
                            if excludeConditions == nil then
                                excludeConditions = collections.NewSetWithSizeHint(0)
                            end
                            excludeConditions:Add(prevCondition)
                        end
                    end

                    prevConditions[#prevConditions + 1] = condition
                    loadEntrypointsFromTargetExports(subpath, newIncludeConditions, excludeConditions, export)
                    if conditionAlwaysMatches then
                        break
                    end
                end
            end
        end
    end

    if exports.type == JSONValueType.Array then
        for _, element in ipairs(exports:AsArray()) do
            loadEntrypointsFromTargetExports(".", nil, nil, element)
        end
    elseif exports.type == JSONValueType.Object then
        if exports:IsSubpaths() then
            for subpath, export in exports:AsObject():Entries() do
                loadEntrypointsFromTargetExports(subpath, nil, nil, export)
            end
        else
            loadEntrypointsFromTargetExports(".", nil, nil, exports)
        end
    else
        loadEntrypointsFromTargetExports(".", nil, nil, exports)
    end

    return entrypoints
end

-- Returns matchedStar, ok.
function resolutionState:getMatchedStarForPatternEntrypoint(file, leadingSlice, trailingSlice, caseSensitive)
    if stringutil.HasPrefixAndSuffixWithoutOverlap(file, leadingSlice, trailingSlice, caseSensitive) then
        return string.sub(file, #leadingSlice + 1, #file - #trailingSlice), true
    end

    local jsExtension = module.TryGetJSExtensionForFile(file, self.compilerOptions)
    if #jsExtension > 0 then
        local swapped = tspath.ChangeFullExtension(file, jsExtension)
        if stringutil.HasPrefixAndSuffixWithoutOverlap(swapped, leadingSlice, trailingSlice, caseSensitive) then
            return string.sub(swapped, #leadingSlice + 1, #swapped - #trailingSlice), true
        end
    end

    return "", false
end
