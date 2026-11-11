local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local module = require("tslua.module")
local outputpaths = require("tslua.outputpaths")
local parser = require("tslua.parser")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local ScriptKind = core.ScriptKind
local EmitOnly = compiler.EmitOnly

local function isTrue(t)
    return core.Tristate_IsTrue(t)
end

-- ProgramOptions: { host, config, useSourceOfProjectReference, singleThreaded (Tristate),
--   createCheckerPool (func(program) CheckerPool), typingsLocation, projectName, tracing }
local ProgramOptions = {}
ProgramOptions.__index = ProgramOptions
compiler.ProgramOptions = ProgramOptions

-- Fills in the Go zero values of a ProgramOptions literal.
function compiler.NewProgramOptions(fields)
    fields = fields or {}
    return setmetatable({
        host = fields.host,
        config = fields.config,
        useSourceOfProjectReference = fields.useSourceOfProjectReference or false,
        singleThreaded = fields.singleThreaded or Tristate.TSUnknown,
        createCheckerPool = fields.createCheckerPool,
        typingsLocation = fields.typingsLocation or "",
        projectName = fields.projectName or "",
        tracing = fields.tracing,
    }, ProgramOptions)
end

local function copyProgramOptions(opts)
    return compiler.NewProgramOptions(opts)
end

function ProgramOptions:canUseProjectReferenceSource()
    return self.useSourceOfProjectReference and not core.Tristate_IsTrue(self.config:CompilerOptions().disableSourceOfProjectReferenceRedirect)
end

-- lazyValue[T]: { value, initialized }
local function newLazyValue()
    return { value = nil, initialized = false }
end

local function lazyGetValue(l, compute)
    if not l.initialized then
        if l.value == nil then
            l.value = compute()
        end
        l.initialized = true
    end
    return l.value
end

local function lazyTryReuse(l, from)
    if from.initialized then
        l.value = from.value
        l.initialized = true
    end
end

-- packageNamesInfo: { resolved, unresolved, deepImportPackages } (*collections.Set[string])

local Program = {}
Program.__index = Program
compiler.Program = Program

local function newProgramTable(opts)
    return setmetatable({
        opts = opts,
        checkerPool = nil, -- always set; used as fallback for project system pools

        -- compilerCheckerPool is set only when the built-in compiler checker pool is in use
        -- (i.e. CreateCheckerPool was not provided).
        compilerCheckerPool = nil,

        comparePathsOptions = { useCaseSensitiveFileNames = false, currentDirectory = "" },

        -- processedFiles (embedded)
        finishedProcessing = false,

        usesUriStyleNodeCoreModules = Tristate.TSUnknown,

        commonSourceDirectory = "",
        commonSourceDirectoryDone = false,

        declarationDiagnosticCache = {},

        programDiagnostics = nil,
        hasEmitBlockingDiagnostics = {},
        contentMapperOptionDiagnostics = nil,

        sourceFilesToEmitDone = false,
        sourceFilesToEmit = nil,

        -- Cached unresolved imports for ATA
        unresolvedImports = newLazyValue(),
        knownSymlinks = newLazyValue(),

        -- Used by auto-imports
        packageNames = newLazyValue(),

        -- Used by workspace/symbol
        hasTSFileDone = false,
        hasTSFile = false,

        -- Cached map of package names to whether they bundle types
        packagesMapDone = false,
        packagesMap = nil,
    }, Program)
end

local function setProcessedFiles(p, pf)
    for k, v in pairs(pf) do
        p[k] = v
    end
end

local processedFilesFields = {
    "resolver", "files", "duplicateSourceFiles", "filesByPath", "projectReferenceFileMapper", "missingFiles",
    "resolvedModules", "typeResolutionsInFile", "sourceFileMetaDatas", "jsxRuntimeImportSpecifiers",
    "importHelpersImportSpecifiers", "libFiles", "sourceFilesFoundSearchingNodeModules", "includeProcessor",
    "outputFileToProjectReferenceSource", "redirectTargetsMap", "redirectFilesByPath", "contentMapperDiagnostics",
    "finishedProcessing",
}

-- FileExists implements checker.Program.
function Program:FileExists(path)
    return self:Host():FS():FileExists(path)
end

-- GetCurrentDirectory implements checker.Program.
function Program:GetCurrentDirectory()
    return self:Host():GetCurrentDirectory()
end

function Program:ContentMapperProject()
    return self.opts.host:ContentMapperProject()
end

-- GetGlobalTypingsCacheLocation implements checker.Program.
function Program:GetGlobalTypingsCacheLocation()
    return self.opts.typingsLocation
end

local function infoExists(entry)
    return entry ~= nil and entry.contents ~= nil
end

-- GetNearestAncestorDirectoryWithPackageJson implements checker.Program.
function Program:GetNearestAncestorDirectoryWithPackageJson(dirname)
    local scoped = self.resolver:GetPackageScopeForPath(dirname)
    if infoExists(scoped) then
        return scoped.packageDirectory
    end
    return ""
end

-- GetPackageJsonInfo implements checker.Program.
function Program:GetPackageJsonInfo(pkgJsonPath)
    local directory = tspath.GetDirectoryPath(pkgJsonPath)
    local scoped = self.resolver:GetPackageScopeForPath(directory)
    if infoExists(scoped) and scoped.packageDirectory == directory then
        return scoped
    end
    return nil
end

-- PackageJsonCacheEntries iterates on all package json cache entries.
function Program:PackageJsonCacheEntries(f)
    self.resolver:PackageJsonCacheEntries(f)
end

-- GetRedirectTargets returns the list of file paths that redirect to the given path.
-- These are files from the same package (same name@version) installed in different locations.
function Program:GetRedirectTargets(path)
    if self.redirectTargetsMap == nil then
        return nil
    end
    return self.redirectTargetsMap[path]
end

-- gets the original file that was included in program
-- this returns original source file name when including output of project reference
-- otherwise same name
-- Equivalent to originalFileName on SourceFile in Strada
function Program:GetSourceOfProjectReferenceIfOutputIncluded(file)
    if self.outputFileToProjectReferenceSource ~= nil then
        local source = self.outputFileToProjectReferenceSource[file:Path()]
        if source ~= nil then
            return source
        end
    end
    return file:FileName()
end

-- GetProjectReferenceFromSource implements checker.Program.
function Program:GetProjectReferenceFromSource(path)
    return self.projectReferenceFileMapper:getProjectReferenceFromSource(path)
end

-- IsSourceFromProjectReference implements checker.Program.
function Program:IsSourceFromProjectReference(path)
    return self.projectReferenceFileMapper:isSourceFromProjectReference(path)
end

function Program:GetProjectReferenceFromOutputDts(path)
    return self.projectReferenceFileMapper:getProjectReferenceFromOutputDts(path)
end

function Program:GetResolvedProjectReferenceFor(path)
    return self.projectReferenceFileMapper:getResolvedReferenceFor(path)
end

function Program:GetRedirectForResolution(file)
    local redirect = self.projectReferenceFileMapper:getRedirectForResolution(file)
    return redirect
end

function Program:GetParseFileRedirect(fileName)
    return self.projectReferenceFileMapper:getParseFileRedirect(ast.NewHasFileName(fileName, self:toPath(fileName)))
end

function Program:GetResolvedProjectReferences()
    return self.projectReferenceFileMapper:getResolvedProjectReferences()
end

function Program:RangeResolvedProjectReference(f)
    return self.projectReferenceFileMapper:rangeResolvedProjectReference(f)
end

function Program:RangeResolvedProjectReferenceInChildConfig(childConfig, f)
    return self.projectReferenceFileMapper:rangeResolvedProjectReferenceInChildConfig(childConfig, f)
end

-- UseCaseSensitiveFileNames implements checker.Program.
function Program:UseCaseSensitiveFileNames()
    return self:Host():FS():UseCaseSensitiveFileNames()
end

function Program:UsesUriStyleNodeCoreModules()
    return self.usesUriStyleNodeCoreModules
end

--- This should have similar behavior to 'processSourceFile' without diagnostics or mutation.
function Program:GetSourceFileFromReference(origin, ref)
    -- TODO: The module loader in corsa is fairly different than strada, it should probably be able to expose this functionality at some point,
    -- rather than redoing the logic approximately here, since most of the related logic now lives in module.Resolver
    -- Still, without the failed lookup reporting that only the loader does, this isn't terribly complicated

    local fileName = tspath.ResolvePath(tspath.GetDirectoryPath(origin:FileName()), ref.fileName)
    local supportedExtensionsBase = tsoptions.GetSupportedExtensions(self:Options(), self:CommandLine():ContentMapperExtensions())
    local supportedExtensions = tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(self:Options(), supportedExtensionsBase)
    local allowNonTsExtensions = isTrue(self:Options().allowNonTsExtensions)
    if tspath.HasExtension(fileName) then
        if not allowNonTsExtensions then
            local canonicalFileName = tspath.GetCanonicalFileName(fileName, self:UseCaseSensitiveFileNames())
            local supported = false
            for _, group in ipairs(supportedExtensions) do
                if tspath.FileExtensionIsOneOf(canonicalFileName, group) then
                    supported = true
                    break
                end
            end
            if not supported then
                return nil -- unsupported extensions are forced to fail
            end
        end

        return self:GetSourceFileForResolvedModule(fileName)
    end
    if allowNonTsExtensions then
        local extensionless = self:GetSourceFileForResolvedModule(fileName)
        if extensionless ~= nil then
            return extensionless
        end
    end

    -- Only try adding extensions from the first supported group (which should be .ts/.tsx/.d.ts)
    for _, ext in ipairs(supportedExtensions[1]) do
        local result = self:GetSourceFileForResolvedModule(fileName .. ext)
        if result ~= nil then
            return result
        end
    end
    return nil
end

function compiler.NewProgram(opts)
    opts = copyProgramOptions(opts)
    local p = newProgramTable(opts)
    setProcessedFiles(p, compiler.processAllProgramFiles(p.opts, p:SingleThreaded()))
    p:initCheckerPool()
    p:verifyCompilerOptions()
    p:collectContentMapperOptionDiagnostics()
    return p
end

-- Return an updated program for which it is known that only the file with the given path has changed.
-- In addition to a new program, return a boolean indicating whether the data of the old program was reused.
-- Returns (*Program, *ast.SourceFile, bool).
function Program:UpdateProgram(changedFilePath, newHost, createCheckerPool)
    local result, newFile, reused = self:ReuseProgram(changedFilePath, newHost, createCheckerPool)
    if reused then
        return result, newFile, true
    else
        local newOpts = copyProgramOptions(self.opts)
        newOpts.host = newHost
        if createCheckerPool ~= nil then
            newOpts.createCheckerPool = createCheckerPool
        end
        return compiler.NewProgram(newOpts), newFile, false
    end
end

local function equalParseOptions(a, b)
    local ea, eb = a.externalModuleIndicatorOptions, b.externalModuleIndicatorOptions
    return a.fileName == b.fileName and a.path == b.path and
        (ea == eb or (ea ~= nil and eb ~= nil and (ea.jsx or false) == (eb.jsx or false) and (ea.force or false) == (eb.force or false)))
end

-- ReuseProgram attempts to produce a new program by replacing only
-- changedFilePath in place, reusing the rest of p. It returns
-- (newProgram, newFile, true) on success, or (nil, newFile, false) when the
-- file cannot be replaced in place.
function Program:ReuseProgram(changedFilePath, newHost, createCheckerPool)
    local newOpts = copyProgramOptions(self.opts)
    newOpts.host = newHost
    if createCheckerPool ~= nil then
        newOpts.createCheckerPool = createCheckerPool
    end

    local oldFile = self.filesByPath[changedFilePath]
    local newFile = nil
    local oldSupplementalFiles = nil
    local newSupplementalFiles = nil
    if oldFile:ContentMapper() ~= "" then
        -- Content-mapped files are produced by running an external transform, which a plain reparse can't
        -- reproduce.
        error("not implemented: Program.ReuseProgram for content-mapped files")
    else
        newFile = newHost:GetSourceFile(oldFile:ParseOptions())
    end

    -- If this file is part of a package redirect group (same package installed in multiple
    -- node_modules locations), we need to rebuild the program because the redirect targets
    -- might need recalculation.
    local inRedirectFiles = self.redirectFilesByPath ~= nil and self.redirectFilesByPath[changedFilePath] ~= nil
    local isRedirectTarget = self.redirectTargetsMap ~= nil and self.redirectTargetsMap[changedFilePath] ~= nil
    if inRedirectFiles or isRedirectTarget then
        return nil, newFile, false
    end

    if not self:canReplaceFileInProgram(oldFile, newFile) then
        return nil, newFile, false
    end
    -- Cloning does not recompute synthetic helper or JSX-runtime import bookkeeping. Fall back to a full
    -- build whenever either version requires those imports.
    if (self.importHelpersImportSpecifiers ~= nil and self.importHelpersImportSpecifiers[oldFile:Path()] ~= nil) or self:needsImportHelpersImportSpecifier(newFile) then
        return nil, newFile, false
    end
    if (self.jsxRuntimeImportSpecifiers ~= nil and self.jsxRuntimeImportSpecifiers[oldFile:Path()] ~= nil) or self:jsxRuntimeImportSpecifier(newFile) ~= "" then
        return nil, newFile, false
    end
    if core.Len(oldSupplementalFiles) ~= core.Len(newSupplementalFiles) then
        return nil, newFile, false
    end
    -- TODO: reverify compiler options when config has changed?
    local result = newProgramTable(newOpts)
    result.comparePathsOptions = self.comparePathsOptions
    for _, field in ipairs(processedFilesFields) do
        result[field] = self[field]
    end
    result.usesUriStyleNodeCoreModules = self.usesUriStyleNodeCoreModules
    result.programDiagnostics = self.programDiagnostics
    result.hasEmitBlockingDiagnostics = self.hasEmitBlockingDiagnostics
    result.contentMapperOptionDiagnostics = core.Slice(self.contentMapperOptionDiagnostics)
    lazyTryReuse(result.unresolvedImports, self.unresolvedImports)
    lazyTryReuse(result.knownSymlinks, self.knownSymlinks)
    lazyTryReuse(result.packageNames, self.packageNames)
    result:initCheckerPool()
    local index = core.FindIndex(result.files, function(file) return file:Path() == newFile:Path() end)
    result.files = core.Slice(result.files)
    result.files[index + 1] = newFile
    local filesByPath = {}
    for k, v in pairs(result.filesByPath) do
        filesByPath[k] = v
    end
    result.filesByPath = filesByPath
    result.filesByPath[newFile:Path()] = newFile
    compiler.updateFileIncludeProcessor(result)
    return result, newFile, true
end

function Program:initCheckerPool()
    if not self.finishedProcessing then
        error("Program must finish processing files before initializing checker pool", 0)
    end

    if self.opts.createCheckerPool ~= nil then
        self.checkerPool = self.opts.createCheckerPool(self)
    else
        local pool = compiler.newCheckerPoolWithTracing(self, self.opts.tracing)
        self.checkerPool = pool
        self.compilerCheckerPool = pool
    end
end

-- GetCheckerPool returns the checker pool associated with this program.
function Program:GetCheckerPool()
    return self.checkerPool
end

local function equalSlices(a, b, eq)
    if core.Len(a) ~= core.Len(b) then
        return false
    end
    for i = 1, core.Len(a) do
        if not eq(a[i], b[i]) then
            return false
        end
    end
    return true
end

function Program:canReplaceFileInProgram(file1, file2)
    return file2 ~= nil and
        equalParseOptions(file1:ParseOptions(), file2:ParseOptions()) and
        file1.scriptKind == file2.scriptKind and
        ast.IsExternalOrCommonJSModule(file1) == ast.IsExternalOrCommonJSModule(file2) and
        file1.usesUriStyleNodeCoreModules == file2.usesUriStyleNodeCoreModules and
        equalSlices(file1:Imports(), file2:Imports(), function(n1, n2)
            return compiler.equalModuleSpecifiers(n1, n2) and
                self:GetModeForUsageLocation(file1, n1) == self:GetModeForUsageLocation(file2, n2)
        end) and
        equalSlices(file1.moduleAugmentations, file2.moduleAugmentations, compiler.equalModuleAugmentationNames) and
        equalSlices(file1.ambientModuleNames, file2.ambientModuleNames, function(a, b) return a == b end) and
        equalSlices(file1.referencedFiles, file2.referencedFiles, compiler.equalFileReferences) and
        equalSlices(file1.typeReferenceDirectives, file2.typeReferenceDirectives, compiler.equalFileReferences) and
        equalSlices(file1.libReferenceDirectives, file2.libReferenceDirectives, compiler.equalFileReferences) and
        compiler.equalCheckJSDirectives(file1.checkJsDirective, file2.checkJsDirective)
end

function Program:needsImportHelpersImportSpecifier(file)
    local redirect = self.projectReferenceFileMapper:getRedirectForResolution(file)
    local optionsForFile = module.GetCompilerOptionsWithRedirect(self.opts.config:CompilerOptions(), redirect)
    if not isTrue(optionsForFile.importHelpers) then
        return false
    end
    local isJavaScriptFile = ast.IsSourceFileJS(file)
    local isExternalModuleFile = ast.IsExternalModule(file)
    if not isJavaScriptFile and (file.isDeclarationFile or (not optionsForFile:GetIsolatedModules() and not isExternalModuleFile)) then
        return false
    end
    return true
end

function Program:jsxRuntimeImportSpecifier(file)
    if not ast.IsSourceFileJS(file) and file.scriptKind ~= ScriptKind.TSX then
        return ""
    end
    local redirect = self.projectReferenceFileMapper:getRedirectForResolution(file)
    local optionsForFile = module.GetCompilerOptionsWithRedirect(self.opts.config:CompilerOptions(), redirect)
    return ast.GetJSXRuntimeImport(ast.GetJSXImplicitImportBase(optionsForFile, file), optionsForFile)
end

function compiler.equalModuleSpecifiers(n1, n2)
    return n1.kind == n2.kind and (not ast.IsStringLiteral(n1) or n1:Text() == n2:Text())
end

function compiler.equalModuleAugmentationNames(n1, n2)
    return n1.kind == n2.kind and n1:Text() == n2:Text()
end

function compiler.equalFileReferences(f1, f2)
    return f1.fileName == f2.fileName and f1.resolutionMode == f2.resolutionMode and f1.preserve == f2.preserve
end

function compiler.equalCheckJSDirectives(d1, d2)
    return d1 == nil and d2 == nil or d1 ~= nil and d2 ~= nil and d1.enabled == d2.enabled
end

function Program:SourceFiles() return self.files end
function Program:DuplicateSourceFiles() return self.duplicateSourceFiles end
function Program:Options() return self.opts.config:CompilerOptions() end

-- GetContentMapper returns the content mapper that produced the given source file, or nil if the
-- file was not produced by a content mapper.
function Program:GetContentMapper(file)
    if file:ContentMapper() == "" then
        return nil
    end
    local mapper = self.opts.config:GetContentMapperForFileName(file:FileName())
    if mapper ~= nil and mapper:Identity() == file:ContentMapper() then
        return mapper
    end
    return nil
end

function Program:ContentMapperExtensions() return self.opts.config:ContentMapperExtensions() end
function Program:CommandLine() return self.opts.config end
function Program:Host() return self.opts.host end
function Program:Tracing() return self.opts.tracing end
function Program:GetConfigFileParsingDiagnostics()
    return core.Slice(self.opts.config:GetConfigFileParsingDiagnostics())
end

-- GetUnresolvedImports returns the unresolved imports for this program.
-- The result is cached and computed only once.
function Program:GetUnresolvedImports()
    return lazyGetValue(self.unresolvedImports, function() return self:extractUnresolvedImports() end)
end

function Program:extractUnresolvedImports()
    local unresolvedSet = collections.NewSetWithSizeHint(0)

    for _, sourceFile in ipairs(self.files) do
        local unresolvedImports = self:extractUnresolvedImportsFromSourceFile(sourceFile)
        for _, imp in ipairs(unresolvedImports or {}) do
            unresolvedSet:Add(imp)
        end
    end

    return unresolvedSet
end

function Program:extractUnresolvedImportsFromSourceFile(file)
    local unresolvedImports = nil

    local resolvedModules = self.resolvedModules[file:Path()]
    for name, _, resolution in compiler.modeAwareCachePairs(resolvedModules) do
        local resolved = resolution:IsResolved()
        if (not resolved or not tspath.ExtensionIsOneOf(resolution.extension, tspath.SupportedTSExtensionsWithJsonFlat)) and
            not tspath.IsExternalModuleNameRelative(name) then
            unresolvedImports = core.Append(unresolvedImports, name)
        end
    end

    return unresolvedImports
end

function Program:SingleThreaded()
    return core.Tristate_IsTrue(core.Tristate_DefaultIfUnknown(self.opts.singleThreaded, self:Options().singleThreaded))
end

function Program:BindSourceFiles()
    local wg = core.NewWorkGroup(self:SingleThreaded())
    for _, file in ipairs(self.files) do
        if not file:IsBound() then
            wg:Queue(function()
                binder.BindSourceFile(file)
            end)
        end
    end
    wg:RunAndWait()
end

-- Return the type checker associated with the program.
function Program:GetTypeChecker(ctx)
    if self.compilerCheckerPool ~= nil then
        return self.compilerCheckerPool:getCheckerNonExclusive()
    end
    return self.checkerPool:GetChecker(ctx, nil)
end

function Program:ForEachCheckerParallel(cb)
    if self.compilerCheckerPool ~= nil then
        self.compilerCheckerPool:forEachCheckerParallel(cb)
    end
end

-- Return a checker for the given file. We may have multiple checkers in concurrent scenarios and this
-- method returns the checker that was tasked with checking the file. Note that it isn't possible to mix
-- types obtained from different checkers, so only non-type data (such as diagnostics or string
-- representations of types) should be obtained from checkers returned by this method.
function Program:GetTypeCheckerForFile(ctx, file)
    if self.compilerCheckerPool ~= nil then
        return self.compilerCheckerPool:getCheckerForFileNonExclusive(file)
    end
    return self.checkerPool:GetChecker(ctx, file)
end

-- Return a checker for the given file, locked to the current thread to prevent data races from multiple threads
-- accessing the same checker. The lock will be released when the `done` function is called.
function Program:GetTypeCheckerForFileExclusive(ctx, file)
    if self.compilerCheckerPool ~= nil then
        return self.compilerCheckerPool:getCheckerForFileExclusive(ctx, file)
    end
    return self.checkerPool:GetChecker(ctx, file)
end

function Program:GetResolvedModule(file, moduleReference, mode)
    local resolutions = self.resolvedModules[file:Path()]
    if resolutions ~= nil then
        local resolved = resolutions[compiler.modeAwareCacheKey(moduleReference, mode)]
        if resolved ~= nil then
            return resolved
        end
    end
    return nil
end

function Program:GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier)
    if not ast.IsStringLiteralLike(moduleSpecifier) then
        error("moduleSpecifier must be a StringLiteralLike", 0)
    end
    local mode = self:GetModeForUsageLocation(file, moduleSpecifier)
    return self:GetResolvedModule(file, moduleSpecifier:Text(), mode)
end

-- Returns map[tspath.Path]ModeAwareCache (see compiler.modeAwareCacheKey).
function Program:GetResolvedModules()
    return self.resolvedModules
end

-- GetPackagesMap returns a lazily-cached map of package names to whether they bundle types.
-- This is used by incremental diagnostic repopulation.
function Program:GetPackagesMap()
    if not self.packagesMapDone then
        self.packagesMapDone = true
        self.packagesMap = {}
        for _, resolvedModulesInFile in pairs(self.resolvedModules) do
            for _, mod in pairs(resolvedModulesInFile) do
                local name = compiler.packageIdName(mod.packageId)
                if name ~= "" then
                    self.packagesMap[name] = self.packagesMap[name] or mod.extension == tspath.ExtensionDts
                end
            end
        end
    end
    return self.packagesMap
end

local function concatAll(lists, n)
    local result = {}
    for i = 1, n do
        core.AppendAll(result, lists[i])
    end
    return result
end

-- collectDiagnostics collects diagnostics from a single file or all files.
-- If sourceFile is non-nil, returns diagnostics for just that file.
-- If sourceFile is nil, returns diagnostics for all files in the program.
function Program:collectDiagnostics(ctx, sourceFile, concurrent, collect)
    local result
    if sourceFile ~= nil then
        result = collect(ctx, sourceFile)
    else
        local diags = self:collectDiagnosticsFromFiles(ctx, self.files, concurrent, collect)
        result = concatAll(diags, #self.files)
    end
    return compiler.filterAndSortDiagnostics(result)
end

function Program:collectDiagnosticsFromFiles(ctx, sourceFiles, concurrent, collect)
    local diags = {}
    local wg = core.NewWorkGroup(not concurrent or self:SingleThreaded())
    for i, file in ipairs(sourceFiles) do
        wg:Queue(function()
            diags[i] = collect(ctx, file)
        end)
    end
    wg:RunAndWait()
    return diags
end

-- collectCheckerDiagnostics collects diagnostics from a single file or all files,
-- using a callback that receives the checker for each file.
function Program:collectCheckerDiagnostics(ctx, sourceFile, collect)
    if sourceFile ~= nil then
        if self:SkipTypeChecking(sourceFile, false) then
            return nil
        end
        local c, done = self:GetTypeCheckerForFileExclusive(ctx, sourceFile)
        local result = collect(ctx, c, sourceFile)
        done()
        return compiler.filterAndSortDiagnostics(result)
    end
    return compiler.filterAndSortDiagnostics(concatAll(self:collectCheckerDiagnosticsFromFiles(ctx, self.files, collect), #self.files))
end

function compiler.filterAndSortDiagnostics(diags)
    return compiler.SortAndDeduplicateDiagnostics(core.Filter(diags or {}, function(diag)
        local file = diag:File()
        if not diag:ReportsUnnecessary() or file == nil or file:SpanMap() == nil or diag:Source() ~= "" then
            return true
        end
        local _, fidelity = file:SpanMap():VirtualToOriginalSpan(diag:Loc())
        local spanmap = require("tslua.spanmap")
        return fidelity ~= spanmap.Fidelity.None
    end))
end

-- collectCheckerDiagnosticsFromFiles collects checker diagnostics for a list of files.
-- The result is indexed like sourceFiles (entries for skipped files are nil).
function Program:collectCheckerDiagnosticsFromFiles(ctx, sourceFiles, collect)
    local diags = {}
    if self.compilerCheckerPool ~= nil then
        self.compilerCheckerPool:forEachCheckerGroupDo(ctx, sourceFiles, self:SingleThreaded(), function(c, fileIndex, file)
            diags[fileIndex + 1] = collect(ctx, c, file)
        end)
    else
        local wg = core.NewWorkGroup(self:SingleThreaded())
        for i, file in ipairs(sourceFiles) do
            if not self:SkipTypeChecking(file, false) then
                wg:Queue(function()
                    local c, done = self.checkerPool:GetChecker(ctx, file)
                    diags[i] = collect(ctx, c, file)
                    done()
                end)
            end
        end
        wg:RunAndWait()
    end
    return diags
end

function Program:GetSyntacticDiagnostics(ctx, sourceFile)
    return self:collectDiagnostics(ctx, sourceFile, false, function(_, file)
        local diags = core.AppendAll(core.Slice(file:Diagnostics()), file:JSDiagnostics())
        -- For JS files that won't be checked by the checker (no checkJs/ts-check), we need
        -- program-level syntactic checks that require compiler options. This mirrors Strada's
        -- getJSSyntacticDiagnosticsForFile in program.ts.
        if ast.IsSourceFileJS(file) and not ast.IsCheckJSEnabledForFile(file, self:Options()) then
            diags = core.AppendAll(diags, compiler.getAdditionalJSSyntacticDiagnostics(file, self:Options()))
        end
        return diags
    end)
end

-- getAdditionalJSSyntacticDiagnostics produces option-dependent syntactic diagnostics for JS files
-- that aren't covered by the parser or the checker. In Strada, the equivalent logic lives in
-- getJSSyntacticDiagnosticsForFile in program.ts. In Corsa, most of that function's checks were
-- moved into the parser (checkJSSyntax/checkJSDecoratorSyntax), but checks that depend on compiler
-- options can't live in the parser and must remain here. The checker handles these for checked files,
-- but doesn't run on unchecked JS files (no checkJs/ts-check).
function compiler.getAdditionalJSSyntacticDiagnostics(file, options)
    if isTrue(options.experimentalDecorators) then
        return nil
    end
    local diags = nil
    -- Parameter decorators are only valid with experimentalDecorators. Without it,
    -- the checker would report this, but the checker doesn't run on unchecked JS files.
    local walk
    walk = function(node)
        if node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsDecorators == 0 then
            return false
        end
        if node.kind == ast.Kind.Parameter and ast.HasDecorators(node) then
            local decorator = core.Find(node:ModifierNodes(), ast.IsDecorator)
            if decorator ~= nil then
                diags = core.Append(diags, ast.NewDiagnostic(file, decorator.loc, diagnostics.Decorators_are_not_valid_here))
            end
        end
        node:ForEachChild(walk)
        return false
    end
    file:ForEachChild(walk)
    return diags
end

function Program:GetBindDiagnostics(ctx, sourceFile)
    if sourceFile ~= nil then
        binder.BindSourceFile(sourceFile)
    else
        self:BindSourceFiles()
    end
    return self:collectDiagnostics(ctx, sourceFile, false, function(_, file)
        return file:BindDiagnostics()
    end)
end

function Program:GetSemanticDiagnostics(ctx, sourceFile)
    return self:collectCheckerDiagnostics(ctx, sourceFile, function(c1, c2, f) return self:getSemanticDiagnosticsWithChecker(c1, c2, f) end)
end

-- Returns map[*ast.SourceFile][]*ast.Diagnostic.
function Program:GetSemanticDiagnosticsWithoutNoEmitFiltering(ctx, sourceFiles)
    local allDiags = self:collectCheckerDiagnosticsFromFiles(ctx, sourceFiles, function(c1, c2, f) return self:getBindAndCheckDiagnosticsWithChecker(c1, c2, f) end)
    local result = {}
    for i = 1, #sourceFiles do
        result[sourceFiles[i]] = compiler.filterAndSortDiagnostics(allDiags[i])
    end
    return result
end

function Program:GetSuggestionDiagnostics(ctx, sourceFile)
    return self:collectCheckerDiagnostics(ctx, sourceFile, function(c1, c2, f) return self:getSuggestionDiagnosticsWithChecker(c1, c2, f) end)
end

function Program:GetProgramDiagnostics()
    local all = {}
    core.AppendAll(all, self.programDiagnostics)
    core.AppendAll(all, self.contentMapperDiagnostics)
    core.AppendAll(all, self.contentMapperOptionDiagnostics)
    core.AppendAll(all, self.includeProcessor:getDiagnostics(self):GetGlobalDiagnostics())
    return compiler.SortAndDeduplicateDiagnostics(all)
end

function Program:collectContentMapperOptionDiagnostics()
    local project = self:ContentMapperProject()
    if project == nil then
        return
    end
    local optionDiagnostics = project:Diagnostics()
    self.contentMapperOptionDiagnostics = core.Map(optionDiagnostics, function(diagnostic)
        local file, loc = tsoptions.GetContentMapperOptionDiagnosticLocation(self.opts.config, diagnostic.mapper, diagnostic.path)
        return ast.NewExternalDiagnostic(file, loc, diagnostic.source, diagnostics.Category.Error, diagnostic.code, diagnostic.messageText)
    end)
end

function Program:GetIncludeProcessorDiagnostics(sourceFile)
    if self:SkipTypeChecking(sourceFile, false) then
        return nil
    end
    local filtered = self:getDiagnosticsWithPrecedingDirectives(sourceFile, self.includeProcessor:getDiagnostics(self):GetDiagnosticsForFile(sourceFile))
    return filtered
end

function Program:SkipTypeChecking(sourceFile, ignoreNoCheck)
    return (not ignoreNoCheck and isTrue(self:Options().noCheck)) or
        isTrue(self:Options().skipLibCheck) and sourceFile.isDeclarationFile or
        isTrue(self:Options().skipDefaultLibCheck) and self:IsSourceFileDefaultLibrary(sourceFile:Path()) or
        self:IsSourceFromProjectReference(sourceFile:Path()) or
        not self:canIncludeBindAndCheckDiagnostics(sourceFile)
end

function Program:canIncludeBindAndCheckDiagnostics(sourceFile)
    if sourceFile.checkJsDirective ~= nil and not sourceFile.checkJsDirective.enabled then
        return false
    end

    if sourceFile.scriptKind == ScriptKind.TS or sourceFile.scriptKind == ScriptKind.TSX then
        return true
    end

    local isJS = sourceFile.scriptKind == ScriptKind.JS or sourceFile.scriptKind == ScriptKind.JSX
    local isCheckJS = isJS and ast.IsCheckJSEnabledForFile(sourceFile, self:Options())
    local isPlainJS = ast.IsPlainJSFile(sourceFile, self:Options().checkJs)

    -- By default, only type-check .ts, .tsx, plain JS, and checked JS
    -- - plain JS: .js files with no // ts-check and checkJs: undefined
    -- - check JS: .js files with either // ts-check or checkJs: true
    return isPlainJS or isCheckJS
end

function Program:getSourceFilesToEmit(targetSourceFiles, forceDtsEmit, forceJsEmit)
    if targetSourceFiles == nil and not forceDtsEmit and not forceJsEmit then
        if not self.sourceFilesToEmitDone then
            self.sourceFilesToEmitDone = true
            self.sourceFilesToEmit = compiler.getSourceFilesToEmit(self, nil, false, false)
        end
        return self.sourceFilesToEmit
    end
    return compiler.getSourceFilesToEmit(self, targetSourceFiles, forceDtsEmit, forceJsEmit)
end

function Program:verifyCompilerOptions()
    local options = self:Options()

    local sourceFileDone, sourceFileValue = false, nil
    local function sourceFile()
        if not sourceFileDone then
            sourceFileDone = true
            local configFile = self.opts.config.configFile
            if configFile ~= nil then
                sourceFileValue = configFile.sourceFile
            end
        end
        return sourceFileValue
    end

    local configFilePathDone, configFilePathValue = false, ""
    local function configFilePath()
        if not configFilePathDone then
            configFilePathDone = true
            local file = sourceFile()
            if file ~= nil then
                configFilePathValue = file:FileName()
            end
        end
        return configFilePathValue
    end

    local compilerOptionsPropertySyntaxDone, compilerOptionsPropertySyntaxValue = false, nil
    local function getCompilerOptionsPropertySyntax()
        if not compilerOptionsPropertySyntaxDone then
            compilerOptionsPropertySyntaxDone = true
            compilerOptionsPropertySyntaxValue = tsoptions.ForEachTsConfigPropArray(sourceFile(), "compilerOptions", core.Identity)
        end
        return compilerOptionsPropertySyntaxValue
    end

    local compilerOptionsObjectLiteralSyntaxDone, compilerOptionsObjectLiteralSyntaxValue = false, nil
    local function getCompilerOptionsObjectLiteralSyntax()
        if not compilerOptionsObjectLiteralSyntaxDone then
            compilerOptionsObjectLiteralSyntaxDone = true
            local compilerOptionsProperty = getCompilerOptionsPropertySyntax()
            if compilerOptionsProperty ~= nil and
                compilerOptionsProperty.initializer ~= nil and
                ast.IsObjectLiteralExpression(compilerOptionsProperty.initializer) then
                compilerOptionsObjectLiteralSyntaxValue = compilerOptionsProperty.initializer
            end
        end
        return compilerOptionsObjectLiteralSyntaxValue
    end

    local function createOptionDiagnosticInObjectLiteralSyntax(objectLiteral, onKey, key1, key2, message, ...)
        local args = table.pack(...)
        local diag = tsoptions.ForEachPropertyAssignment(objectLiteral, key1, function(property)
            local node
            if onKey then
                node = property:Name()
            else
                node = property.initializer
            end
            return tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), node, message, table.unpack(args, 1, args.n))
        end, key2)
        if diag ~= nil then
            self.programDiagnostics = core.Append(self.programDiagnostics, diag)
        end
        return diag
    end

    local function createCompilerOptionsDiagnostic(message, ...)
        local compilerOptionsProperty = getCompilerOptionsPropertySyntax()
        local diag
        if compilerOptionsProperty ~= nil then
            diag = tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), compilerOptionsProperty:Name(), message, ...)
        else
            diag = ast.NewCompilerDiagnostic(message, ...)
        end
        self.programDiagnostics = core.Append(self.programDiagnostics, diag)
        return diag
    end

    local function createDiagnosticForOption(onKey, option1, option2, message, ...)
        local diag = createOptionDiagnosticInObjectLiteralSyntax(getCompilerOptionsObjectLiteralSyntax(), onKey, option1, option2, message, ...)
        if diag == nil then
            diag = createCompilerOptionsDiagnostic(message, ...)
        end
        return diag
    end

    local function createDiagnosticForOptionName(message, option1, option2, ...)
        createDiagnosticForOption(true, option1, option2, message, option1, option2, ...)
    end

    local function createOptionValueDiagnostic(option1, message, ...)
        createDiagnosticForOption(false, option1, "", message, ...)
    end

    local function createRemovedOptionDiagnostic(name, value, useInstead)
        local message
        local args
        if value == "" then
            message = diagnostics.Option_0_has_been_removed_Please_remove_it_from_your_configuration
            args = { name }
        else
            message = diagnostics.Option_0_1_has_been_removed_Please_remove_it_from_your_configuration
            args = { name, value }
        end

        local diag = createDiagnosticForOption(value == "", name, "", message, table.unpack(args))
        if useInstead ~= "" then
            diag:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.Use_0_instead, useInstead))
        end
    end

    -- Removed in TS7

    if options.baseUrl ~= "" then
        -- BaseUrl will have been turned absolute by this point.
        local useInstead = ""
        if configFilePath() ~= "" then
            local relative = tspath.GetRelativePathFromFile(configFilePath(), options.baseUrl, self.comparePathsOptions)
            if not (compiler.hasPrefix(relative, "./") or compiler.hasPrefix(relative, "../")) then
                relative = "./" .. relative
            end
            local suggestion = tspath.CombinePaths(relative, "*")
            useInstead = '"paths": {"*": [' .. compiler.jsonMarshalString(suggestion) .. ']}'
        end
        createRemovedOptionDiagnostic("baseUrl", "", useInstead)
    end

    if options.outFile ~= "" then
        createRemovedOptionDiagnostic("outFile", "", "")
    end

    if options.target == core.ScriptTarget.ES5 then
        createRemovedOptionDiagnostic("target", "ES5", "")
    end

    if options.module == ModuleKind.AMD then
        createRemovedOptionDiagnostic("module", "AMD", "")
    end
    if options.module == ModuleKind.System then
        createRemovedOptionDiagnostic("module", "System", "")
    end
    if options.module == ModuleKind.UMD then
        createRemovedOptionDiagnostic("module", "UMD", "")
    end

    if options.moduleResolution == ModuleResolutionKind.Classic then
        createRemovedOptionDiagnostic("moduleResolution", "Classic", "")
    end

    if core.Tristate_IsFalse(options.alwaysStrict) then
        createRemovedOptionDiagnostic("alwaysStrict", "false", "")
    end

    if core.Tristate_IsFalse(options.esModuleInterop) then
        createRemovedOptionDiagnostic("esModuleInterop", "false", "")
    end

    if core.Tristate_IsFalse(options.allowSyntheticDefaultImports) then
        createRemovedOptionDiagnostic("allowSyntheticDefaultImports", "false", "")
    end

    if options.moduleResolution == ModuleResolutionKind.Node10 then
        createRemovedOptionDiagnostic("moduleResolution", "node10", "")
    end

    if not core.Tristate_IsUnknown(options.downlevelIteration) then
        createRemovedOptionDiagnostic("downlevelIteration", "", "")
    end

    if isTrue(options.strictPropertyInitialization) and not options:GetStrictOptionValue(options.strictNullChecks) then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "strictPropertyInitialization", "strictNullChecks")
    end
    if isTrue(options.exactOptionalPropertyTypes) and not options:GetStrictOptionValue(options.strictNullChecks) then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "exactOptionalPropertyTypes", "strictNullChecks")
    end

    if isTrue(options.isolatedDeclarations) then
        if options:GetAllowJS() then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_with_option_1, "allowJs", "isolatedDeclarations")
        end
        if not options:GetEmitDeclarations() then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "isolatedDeclarations", "declaration", "composite")
        end
    end

    if isTrue(options.inlineSourceMap) then
        if isTrue(options.sourceMap) then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_with_option_1, "sourceMap", "inlineSourceMap")
        end
        if options.mapRoot ~= "" then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_with_option_1, "mapRoot", "inlineSourceMap")
        end
    end

    if isTrue(options.composite) then
        if core.Tristate_IsFalse(options.declaration) then
            createDiagnosticForOptionName(diagnostics.Composite_projects_may_not_disable_declaration_emit, "declaration", "")
        end
        if core.Tristate_IsFalse(options.incremental) then
            createDiagnosticForOptionName(diagnostics.Composite_projects_may_not_disable_incremental_compilation, "declaration", "")
        end
    end

    if options.tsBuildInfoFile == "" and isTrue(options.incremental) and options.configFilePath == "" then
        createCompilerOptionsDiagnostic(diagnostics.Option_incremental_is_only_valid_with_a_known_configuration_file_like_tsconfig_json_or_when_tsBuildInfoFile_is_explicitly_provided)
    end

    self:verifyProjectReferences()

    if isTrue(options.composite) then
        local rootPaths = {}
        for _, fileName in ipairs(self.opts.config:FileNames()) do
            rootPaths[self:toPath(fileName)] = true
        end

        for _, file in ipairs(self.files) do
            if compiler.sourceFileMayBeEmitted(file, self, false, false) and not rootPaths[file:Path()] then
                self.includeProcessor:addProcessingDiagnostic(compiler.newProcessingDiagnostic(
                    compiler.processingDiagnosticKindExplainingFileInclude,
                    compiler.newIncludeExplainingDiagnostic({
                        file = file:Path(),
                        message = diagnostics.File_0_is_not_listed_within_the_file_list_of_project_1_Projects_must_list_all_files_or_use_an_include_pattern,
                        args = { file:FileName(), configFilePath() },
                    })
                ))
            end
        end
    end

    local function forEachOptionPathsSyntax(callback)
        return tsoptions.ForEachPropertyAssignment(getCompilerOptionsObjectLiteralSyntax(), "paths", callback)
    end

    local function createDiagnosticForOptionPaths(onKey, key, message, ...)
        local args = table.pack(...)
        local diag = forEachOptionPathsSyntax(function(pathProp)
            if ast.IsObjectLiteralExpression(pathProp.initializer) then
                return createOptionDiagnosticInObjectLiteralSyntax(pathProp.initializer, onKey, key, "", message, table.unpack(args, 1, args.n))
            end
            return nil
        end)
        if diag == nil then
            diag = createCompilerOptionsDiagnostic(message, ...)
        end
        return diag
    end

    local function createDiagnosticForOptionPathKeyValue(key, valueIndex, message, ...)
        local args = table.pack(...)
        local diag = forEachOptionPathsSyntax(function(pathProp)
            if ast.IsObjectLiteralExpression(pathProp.initializer) then
                return tsoptions.ForEachPropertyAssignment(pathProp.initializer, key, function(keyProps)
                    local initializer = keyProps.initializer
                    if ast.IsArrayLiteralExpression(initializer) then
                        local elements = initializer:ElementList()
                        if elements ~= nil and #elements.nodes > valueIndex then
                            local d = tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), elements.nodes[valueIndex + 1], message, table.unpack(args, 1, args.n))
                            self.programDiagnostics = core.Append(self.programDiagnostics, d)
                            return d
                        end
                    end
                    return nil
                end)
            end
            return nil
        end)
        if diag == nil then
            diag = createCompilerOptionsDiagnostic(message, ...)
        end
        return diag
    end

    if options.paths ~= nil then
        for key, value in options.paths:Entries() do
            if type(value) ~= "table" then
                value = nil
            end
            -- !!! This code does not handle cases where where the path mappings have the wrong types,
            -- as that information is mostly lost during the parsing process.
            if not compiler.hasZeroOrOneAsteriskCharacter(key) then
                createDiagnosticForOptionPaths(true, key, diagnostics.Pattern_0_can_have_at_most_one_Asterisk_character, key)
            end
            if value == nil then
                createDiagnosticForOptionPaths(false, key, diagnostics.Substitutions_for_pattern_0_should_be_an_array, key)
            elseif #value == 0 then
                createDiagnosticForOptionPaths(false, key, diagnostics.Substitutions_for_pattern_0_shouldn_t_be_an_empty_array, key)
            end
            for i1, subst in ipairs(value or {}) do
                if not compiler.hasZeroOrOneAsteriskCharacter(subst) then
                    createDiagnosticForOptionPathKeyValue(key, i1 - 1, diagnostics.Substitution_0_in_pattern_1_can_have_at_most_one_Asterisk_character, subst, key)
                end
                if not tspath.PathIsRelative(subst) and not tspath.PathIsAbsolute(subst) then
                    createDiagnosticForOptionPathKeyValue(key, i1 - 1, diagnostics.Non_relative_paths_are_not_allowed_Did_you_forget_a_leading_Slash)
                end
            end
        end
    end

    if core.Tristate_IsFalseOrUnknown(options.sourceMap) and core.Tristate_IsFalseOrUnknown(options.inlineSourceMap) then
        if isTrue(options.inlineSources) then
            createDiagnosticForOptionName(diagnostics.Option_0_can_only_be_used_when_either_option_inlineSourceMap_or_option_sourceMap_is_provided, "inlineSources", "")
        end
        if options.sourceRoot ~= "" then
            createDiagnosticForOptionName(diagnostics.Option_0_can_only_be_used_when_either_option_inlineSourceMap_or_option_sourceMap_is_provided, "sourceRoot", "")
        end
    end

    if options.mapRoot ~= "" and not (isTrue(options.sourceMap) or isTrue(options.declarationMap)) then
        -- Error to specify --mapRoot without --sourcemap
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "mapRoot", "sourceMap", "declarationMap")
    end

    if options.declarationDir ~= "" then
        if not options:GetEmitDeclarations() then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "declarationDir", "declaration", "composite")
        end
    end

    if isTrue(options.declarationMap) and not options:GetEmitDeclarations() then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "declarationMap", "declaration", "composite")
    end

    if options.lib ~= nil and isTrue(options.noLib) then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_with_option_1, "lib", "noLib")
    end

    if isTrue(options.isolatedModules) or isTrue(options.verbatimModuleSyntax) then
        if core.Tristate_IsFalse(options.preserveConstEnums) then
            createDiagnosticForOptionName(diagnostics.Option_preserveConstEnums_cannot_be_disabled_when_0_is_enabled, isTrue(options.verbatimModuleSyntax) and "verbatimModuleSyntax" or "isolatedModules", "preserveConstEnums")
        end
    end

    if options.outDir ~= "" or
        options.rootDir ~= "" or
        options.sourceRoot ~= "" or
        options.mapRoot ~= "" or
        (options:GetEmitDeclarations() and options.declarationDir ~= "") then
        -- !!! sheetal checkSourceFilesBelongToPath - for root Dir and configFile - explaining why file is in the program
        local dir = self:CommonSourceDirectory()
        if options.outDir ~= "" and dir == "" and core.Some(self.files, function(f) return tspath.GetRootLength(f:FileName()) > 1 end) then
            createDiagnosticForOptionName(diagnostics.Cannot_find_the_common_subdirectory_path_for_the_input_files, "outDir", "")
        end
    end

    if not isTrue(options.noEmit) and
        not isTrue(options.composite) and
        options.rootDir == "" and
        options.configFilePath ~= "" and
        (options.outDir ~= "" or
            (options:GetEmitDeclarations() and options.declarationDir ~= "") or
            options.outFile ~= "") then
        -- Check if rootDir inferred changed and issue diagnostic
        local dir = self:CommonSourceDirectory()
        local emittedFiles = nil
        for _, file in ipairs(self.files) do
            if not file.isDeclarationFile and compiler.sourceFileMayBeEmitted(file, self, false, false) then
                emittedFiles = core.Append(emittedFiles, file:FileName())
            end
        end
        local dir59 = outputpaths.GetComputedCommonSourceDirectory(emittedFiles, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
        if dir59 ~= "" and tspath.GetCanonicalFileName(dir, self:UseCaseSensitiveFileNames()) ~= tspath.GetCanonicalFileName(dir59, self:UseCaseSensitiveFileNames()) then
            -- change in layout
            local option1
            if options.outFile ~= "" then
                option1 = "outFile"
            elseif options.outDir ~= "" then
                option1 = "outDir"
            else
                option1 = "declarationDir"
            end
            local option2 = ""
            if options.outFile == "" and options.outDir ~= "" then
                option2 = "declarationDir"
            end
            local diag = createDiagnosticForOption(
                true, -- onKey
                option1,
                option2,
                diagnostics.The_common_source_directory_of_0_is_1_The_rootDir_setting_must_be_explicitly_set_to_this_or_another_path_to_adjust_your_output_s_file_layout,
                tspath.GetBaseFileName(options.configFilePath),
                tspath.GetRelativePathFromFile(options.configFilePath, dir59, self.comparePathsOptions)
            )
            diag:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.Visit_https_Colon_Slash_Slashaka_ms_Slashts6_for_migration_information))
        end
    end

    if isTrue(options.checkJs) and not options:GetAllowJS() then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "checkJs", "allowJs")
    end

    if isTrue(options.emitDeclarationOnly) then
        if not options:GetEmitDeclarations() then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "emitDeclarationOnly", "declaration", "composite")
        end
    end

    if isTrue(options.emitDecoratorMetadata) and core.Tristate_IsFalseOrUnknown(options.experimentalDecorators) then
        createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "emitDecoratorMetadata", "experimentalDecorators")
    end

    local JsxEmit = core.JsxEmit
    if options.jsxFactory ~= "" then
        if options.reactNamespace ~= "" then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_with_option_1, "reactNamespace", "jsxFactory")
        end
        if options.jsx == JsxEmit.ReactJSX or options.jsx == JsxEmit.ReactJSXDev then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxFactory", core.JsxEmit_String(options.jsx))
        end
        if parser.ParseIsolatedEntityName(options.jsxFactory) == nil then
            createOptionValueDiagnostic("jsxFactory", diagnostics.Invalid_value_for_jsxFactory_0_is_not_a_valid_identifier_or_qualified_name, options.jsxFactory)
        end
    elseif options.reactNamespace ~= "" and not scanner.IsIdentifierText(options.reactNamespace, core.LanguageVariant.Standard) then
        createOptionValueDiagnostic("reactNamespace", diagnostics.Invalid_value_for_reactNamespace_0_is_not_a_valid_identifier, options.reactNamespace)
    end

    if options.jsxFragmentFactory ~= "" then
        if options.jsxFactory == "" then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "jsxFragmentFactory", "jsxFactory")
        end
        if options.jsx == JsxEmit.ReactJSX or options.jsx == JsxEmit.ReactJSXDev then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxFragmentFactory", core.JsxEmit_String(options.jsx))
        end
        if parser.ParseIsolatedEntityName(options.jsxFragmentFactory) == nil then
            createOptionValueDiagnostic("jsxFragmentFactory", diagnostics.Invalid_value_for_jsxFragmentFactory_0_is_not_a_valid_identifier_or_qualified_name, options.jsxFragmentFactory)
        end
    end

    if options.reactNamespace ~= "" then
        if options.jsx == JsxEmit.ReactJSX or options.jsx == JsxEmit.ReactJSXDev then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "reactNamespace", core.JsxEmit_String(options.jsx))
        end
    end

    if options.jsxImportSource ~= "" then
        if options.jsx == JsxEmit.React then
            createDiagnosticForOptionName(diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxImportSource", core.JsxEmit_String(options.jsx))
        end
    end

    local moduleKind = options:GetEmitModuleKind()

    if isTrue(options.allowImportingTsExtensions) and not (isTrue(options.noEmit) or isTrue(options.emitDeclarationOnly) or isTrue(options.rewriteRelativeImportExtensions)) then
        createOptionValueDiagnostic("allowImportingTsExtensions", diagnostics.Option_allowImportingTsExtensions_can_only_be_used_when_one_of_noEmit_emitDeclarationOnly_or_rewriteRelativeImportExtensions_is_set)
    end

    local moduleResolution = options:GetModuleResolutionKind()
    if isTrue(options.resolvePackageJsonExports) and not compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution) then
        createDiagnosticForOptionName(diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler, "resolvePackageJsonExports", "")
    end
    if isTrue(options.resolvePackageJsonImports) and not compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution) then
        createDiagnosticForOptionName(diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler, "resolvePackageJsonImports", "")
    end
    if options.customConditions ~= nil and not compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution) then
        createDiagnosticForOptionName(diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler, "customConditions", "")
    end

    if moduleResolution == ModuleResolutionKind.Bundler and not compiler.emitModuleKindIsNonNodeESM(moduleKind) and moduleKind ~= ModuleKind.Preserve and moduleKind ~= ModuleKind.CommonJS then
        createOptionValueDiagnostic("moduleResolution", diagnostics.Option_0_can_only_be_used_when_module_is_set_to_preserve_commonjs_or_es2015_or_later, "bundler")
    end

    if ModuleKind.Node16 <= moduleKind and moduleKind <= ModuleKind.NodeNext and
        not (ModuleResolutionKind.Node16 <= moduleResolution and moduleResolution <= ModuleResolutionKind.NodeNext) then
        local moduleKindName = core.ModuleKind_String(moduleKind)
        local moduleResolutionName
        local v = core.ModuleKindToModuleResolutionKind[moduleKind]
        if v ~= nil then
            moduleResolutionName = core.ModuleResolutionKind_String(v)
        else
            moduleResolutionName = "Node16"
        end
        createOptionValueDiagnostic("moduleResolution", diagnostics.Option_moduleResolution_must_be_set_to_0_or_left_unspecified_when_option_module_is_set_to_1, moduleResolutionName, moduleKindName)
    elseif ModuleResolutionKind.Node16 <= moduleResolution and moduleResolution <= ModuleResolutionKind.NodeNext and
        not (ModuleKind.Node16 <= moduleKind and moduleKind <= ModuleKind.NodeNext) then
        local moduleResolutionName = core.ModuleResolutionKind_String(moduleResolution)
        createOptionValueDiagnostic("module", diagnostics.Option_module_must_be_set_to_0_when_option_moduleResolution_is_set_to_1, moduleResolutionName, moduleResolutionName)
    end

    -- !!! The below needs filesByName, which is not equivalent to p.filesByPath.

    -- If the emit is enabled make sure that every output file is unique and not overwriting any of the input files
    if not isTrue(options.noEmit) and not isTrue(options.suppressOutputPathCheck) then
        local emitFilesSeen = {}

        -- Verify that all the emit files are unique and don't overwrite input files
        local function verifyEmitFilePath(emitFileName)
            if emitFileName ~= "" then
                local emitFilePath = self:toPath(emitFileName)
                -- Report error if the output overwrites input file
                if self.filesByPath[emitFilePath] ~= nil then
                    local diag = ast.NewCompilerDiagnostic(diagnostics.Cannot_write_file_0_because_it_would_overwrite_input_file, emitFileName)
                    if configFilePath() == "" then
                        -- The program is from either an inferred project or an external project
                        diag:AddMessageChain(ast.NewCompilerDiagnostic(diagnostics.Adding_a_tsconfig_json_file_will_help_organize_projects_that_contain_both_TypeScript_and_JavaScript_files_Learn_more_at_https_Colon_Slash_Slashaka_ms_Slashtsconfig))
                    end
                    self:blockEmittingOfFile(emitFileName, diag)
                end

                local emitFileKey
                if not self:Host():FS():UseCaseSensitiveFileNames() then
                    emitFileKey = tspath.ToFileNameLowerCase(emitFilePath)
                else
                    emitFileKey = emitFilePath
                end

                -- Report error if multiple files write into same file
                if emitFilesSeen[emitFileKey] then
                    -- Already seen the same emit file - report error
                    self:blockEmittingOfFile(emitFileName, ast.NewCompilerDiagnostic(diagnostics.Cannot_write_file_0_because_it_would_be_overwritten_by_multiple_input_files, emitFileName))
                else
                    emitFilesSeen[emitFileKey] = true
                end
            end
        end

        outputpaths.ForEachEmittedFile(self, options, function(emitFileNames, _)
            verifyEmitFilePath(emitFileNames:JsFilePath())
            verifyEmitFilePath(emitFileNames:SourceMapFilePath())
            verifyEmitFilePath(emitFileNames:DeclarationFilePath())
            verifyEmitFilePath(emitFileNames:DeclarationMapPath())
            return false
        end, self:getSourceFilesToEmit(nil, false, false), false)
        verifyEmitFilePath(self.opts.config:GetBuildInfoFileName())
    end
end

function Program:blockEmittingOfFile(emitFileName, diag)
    self.hasEmitBlockingDiagnostics[self:toPath(emitFileName)] = true
    self.programDiagnostics = core.Append(self.programDiagnostics, diag)
end

function Program:IsEmitBlocked(emitFileName)
    return self.hasEmitBlockingDiagnostics[self:toPath(emitFileName)] == true
end

function Program:verifyProjectReferences()
    local buildInfoFileName = ""
    if not isTrue(self:Options().suppressOutputPathCheck) then
        buildInfoFileName = self.opts.config:GetBuildInfoFileName()
    end
    local function createDiagnosticForReference(config, index, message, ...)
        local diag = tsoptions.CreateDiagnosticAtReferenceSyntax(config, index, message, ...)
        if diag == nil then
            diag = ast.NewCompilerDiagnostic(message, ...)
        end
        self.programDiagnostics = core.Append(self.programDiagnostics, diag)
    end

    self:RangeResolvedProjectReference(function(path, config, parent, index)
        local ref = parent:ProjectReferences()[index + 1]
        -- !!! Deprecated in 5.0 and removed since 5.5
        -- verifyRemovedProjectReference(ref, parent, index);
        if config == nil then
            createDiagnosticForReference(parent, index, diagnostics.File_0_not_found, ref.path)
            return true
        end
        local refOptions = config:CompilerOptions()
        if not isTrue(refOptions.composite) or isTrue(refOptions.noEmit) then
            if core.Len(parent:FileNames()) > 0 then
                if not isTrue(refOptions.composite) then
                    createDiagnosticForReference(parent, index, diagnostics.Referenced_project_0_must_have_setting_composite_Colon_true, ref.path)
                end
                if isTrue(refOptions.noEmit) then
                    createDiagnosticForReference(parent, index, diagnostics.Referenced_project_0_may_not_disable_emit, ref.path)
                end
            end
        end
        if buildInfoFileName ~= "" and buildInfoFileName == config:GetBuildInfoFileName() then
            createDiagnosticForReference(parent, index, diagnostics.Cannot_write_file_0_because_it_will_overwrite_tsbuildinfo_file_generated_by_referenced_project_1, buildInfoFileName, ref.path)
            self.hasEmitBlockingDiagnostics[self:toPath(buildInfoFileName)] = true
        end
        return true
    end)
end

function compiler.hasZeroOrOneAsteriskCharacter(str)
    local seenAsterisk = false
    for i = 1, #str do
        if string.byte(str, i) == 42 then -- '*'
            if not seenAsterisk then
                seenAsterisk = true
            else
                -- have already seen asterisk
                return false
            end
        end
    end
    return true
end

function compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution)
    return moduleResolution >= ModuleResolutionKind.Node16 and moduleResolution <= ModuleResolutionKind.NodeNext or
        moduleResolution == ModuleResolutionKind.Bundler
end

function compiler.emitModuleKindIsNonNodeESM(moduleKind)
    return moduleKind >= ModuleKind.ES2015 and moduleKind <= ModuleKind.ESNext
end

function Program:GetGlobalDiagnostics(ctx)
    if #self.files == 0 then
        return nil
    end
    if self.compilerCheckerPool ~= nil then
        return self.compilerCheckerPool:GetGlobalDiagnostics()
    end
    -- For external pools (project system), global diagnostics are collected
    -- incrementally as checkers are used, not via a bulk query.
    return nil
end

function Program:GetDeclarationDiagnostics(ctx, sourceFile)
    return self:collectDiagnostics(ctx, sourceFile, true, function(c, f) return self:getDeclarationDiagnosticsForFile(c, f) end)
end

function compiler.FilterNoEmitSemanticDiagnostics(diags, options)
    if not isTrue(options.noEmit) then
        return diags
    end
    return core.Filter(diags or {}, function(d)
        return not d:SkippedOnNoEmit()
    end)
end

function Program:getSemanticDiagnosticsWithChecker(ctx, c, sourceFile)
    return core.AppendAll(
        core.Slice(compiler.FilterNoEmitSemanticDiagnostics(self:getBindAndCheckDiagnosticsWithChecker(ctx, c, sourceFile), self:Options())),
        self:GetIncludeProcessorDiagnostics(sourceFile)
    )
end

-- getBindAndCheckDiagnosticsWithChecker gets semantic diagnostics for a single file using a
-- caller-provided checker, including bind diagnostics, checker diagnostics, and handling
-- of @ts-ignore/@ts-expect-error directives.
function Program:getBindAndCheckDiagnosticsWithChecker(ctx, fileChecker, sourceFile)
    local compilerOptions = self:Options()
    if self:SkipTypeChecking(sourceFile, false) then
        return nil
    end

    -- Checker creation forces binding, so bind diagnostics will be populated.
    local diags = core.Slice(sourceFile:BindDiagnostics())
    core.AppendAll(diags, fileChecker:GetDiagnostics(ctx, sourceFile))

    local isPlainJS = ast.IsPlainJSFile(sourceFile, compilerOptions.checkJs)
    if isPlainJS then
        return core.Filter(diags, function(d)
            return compiler.plainJSErrors[d:Code()] == true
        end)
    end

    local isJS = sourceFile.scriptKind == ScriptKind.JS or sourceFile.scriptKind == ScriptKind.JSX
    local isCheckJS = isJS and ast.IsCheckJSEnabledForFile(sourceFile, compilerOptions)
    if isCheckJS then
        core.AppendAll(diags, sourceFile:JSDocDiagnostics())
    end

    local filtered, directivesByLine = self:getDiagnosticsWithPrecedingDirectives(sourceFile, diags)
    for _, line in ipairs(compiler.sortedKeys(directivesByLine)) do
        local directive = directivesByLine[line]
        -- Above we changed all used directive kinds to @ts-ignore, so any @ts-expect-error directives that
        -- remain are unused and thus errors.
        if directive.kind == ast.CommentDirectiveKind.ExpectError then
            filtered = core.Append(filtered, ast.NewDiagnostic(sourceFile, directive.loc, diagnostics.Unused_ts_expect_error_directive))
        end
    end
    filtered = compiler.applyContentMapperDiagnosticDirectives(sourceFile, filtered)
    return filtered
end

function compiler.applyContentMapperDiagnosticDirectives(sourceFile, diags)
    local directives = sourceFile:DiagnosticDirectives()
    if core.Len(directives) == 0 then
        return diags
    end
    local used = {}
    for i = 1, #directives do
        used[i] = false
    end
    local function markUsed(diag)
        if diag:Source() ~= "" then
            return false
        end
        for i, directive in ipairs(directives) do
            if diag:Pos() >= directive.virtualRange:Pos() and diag:Pos() < directive.virtualRange:End() then
                used[i] = true
                return true
            end
        end
        return false
    end
    local filtered = core.Filter(diags or {}, function(diag)
        return not markUsed(diag)
    end)
    for i, directive in ipairs(directives) do
        if directive.policy == ast.MappedDiagnosticDirectivePolicy.Expect and not used[i] then
            filtered[#filtered + 1] = ast.NewExternalDiagnostic(
                sourceFile,
                directive.originalRange,
                directive.source,
                diagnostics.Category.Error,
                directive.unusedCode,
                directive.unusedMessageText
            )
        end
    end
    return filtered
end

-- Returns ([]*ast.Diagnostic, map[int]ast.CommentDirective).
function Program:getDiagnosticsWithPrecedingDirectives(sourceFile, diags)
    if core.Len(sourceFile.commentDirectives) == 0 then
        return diags, nil
    end
    -- Build map of directives by line number
    local directivesByLine = {}
    for _, directive in ipairs(sourceFile.commentDirectives) do
        local line = scanner.GetECMALineOfPosition(sourceFile, directive.loc:Pos())
        directivesByLine[line] = directive
    end
    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    local text = sourceFile:Text()
    local filtered = {}
    for _, diagnostic in ipairs(diags or {}) do
        local ignoreDiagnostic = false
        local line = scanner.ComputeLineOfPosition(lineStarts, diagnostic:Pos()) - 1
        while line >= 0 do
            -- If line contains a @ts-ignore or @ts-expect-error directive, ignore this diagnostic and change
            -- the directive kind to @ts-ignore to indicate it was used.
            local directive = directivesByLine[line]
            if directive ~= nil then
                ignoreDiagnostic = true
                directivesByLine[line] = { loc = directive.loc, kind = ast.CommentDirectiveKind.Ignore }
                break
            end
            -- Stop searching backwards when we encounter a line that isn't blank or a comment.
            if not compiler.isCommentOrBlankLine(text, lineStarts[line + 1]) then
                break
            end
            line = line - 1
        end
        if not ignoreDiagnostic then
            filtered[#filtered + 1] = diagnostic
        end
    end
    return filtered, directivesByLine
end

function Program:getDeclarationDiagnosticsForFile(ctx, sourceFile)
    if sourceFile.isDeclarationFile then
        return {}
    end

    local cached = self.declarationDiagnosticCache[sourceFile]
    if cached ~= nil then
        return cached
    end

    local host, done = compiler.newEmitHost(ctx, self, sourceFile)
    local diags = compiler.getDeclarationDiagnostics(host, sourceFile)
    done()
    self.declarationDiagnosticCache[sourceFile] = diags
    return diags
end

function Program:getSuggestionDiagnosticsWithChecker(ctx, fileChecker, sourceFile)
    if self:SkipTypeChecking(sourceFile, false) then
        return nil
    end

    return fileChecker:GetSuggestionDiagnostics(ctx, sourceFile)
end

function compiler.isCommentOrBlankLine(text, pos)
    local n = #text
    while pos < n and (string.byte(text, pos + 1) == 32 or string.byte(text, pos + 1) == 9) do
        pos = pos + 1
    end
    return pos == n or
        pos < n and (string.byte(text, pos + 1) == 13 or string.byte(text, pos + 1) == 10) or
        pos + 1 < n and string.byte(text, pos + 1) == 47 and string.byte(text, pos + 2) == 47
end

function compiler.SortAndDeduplicateDiagnostics(diags)
    diags = core.Slice(diags or {})
    compiler.sortStable(diags, ast.CompareDiagnostics)
    return compiler.compactAndMergeRelatedInfos(diags)
end

-- Remove duplicate diagnostics and, for sequences of diagnostics that differ only by related information,
-- create a single diagnostic with sorted and deduplicated related information.
function compiler.compactAndMergeRelatedInfos(diags)
    if #diags < 2 then
        return diags
    end
    local i = 0
    local j = 0
    local n_ = #diags
    while i < n_ do
        local d = diags[i + 1]
        local n = 1
        while i + n < n_ and ast.EqualDiagnosticsNoRelatedInfo(d, diags[i + n + 1]) do
            n = n + 1
        end
        if n > 1 then
            local relatedInfos = nil
            for k = 0, n - 1 do
                relatedInfos = core.AppendAll(relatedInfos, diags[i + k + 1]:RelatedInformation())
            end
            if relatedInfos ~= nil then
                compiler.sortStable(relatedInfos, ast.CompareDiagnostics)
                local compacted = {}
                for _, info in ipairs(relatedInfos) do
                    if #compacted == 0 or not ast.EqualDiagnostics(compacted[#compacted], info) then
                        compacted[#compacted + 1] = info
                    end
                end
                d = d:Clone():SetRelatedInfo(compacted)
            end
        end
        diags[j + 1] = d
        i = i + n
        j = j + 1
    end
    for k = n_, j + 1, -1 do
        diags[k] = nil
    end
    return diags
end

function Program:LineCount()
    local count = 0
    for _, file in ipairs(self.files) do
        count = count + #file:ECMALineMap()
    end
    return count
end

function Program:IdentifierCount()
    local count = 0
    for _, file in ipairs(self.files) do
        count = count + file.identifierCount
    end
    return count
end

function Program:SymbolCount()
    local count = 0
    for _, file in ipairs(self.files) do
        count = count + file.symbolCount
    end
    self:ForEachCheckerParallel(function(_, c)
        count = count + c.symbolCount
    end)
    return count
end

function Program:TypeCount()
    local count = 0
    self:ForEachCheckerParallel(function(_, c)
        count = count + c.typeCount
    end)
    return count
end

function Program:InstantiationCount()
    local count = 0
    self:ForEachCheckerParallel(function(_, c)
        count = count + c.totalInstantiationCount
    end)
    return count
end

function Program:Program()
    return self
end

function Program:GetSourceFileMetaData(path)
    local meta = self.sourceFileMetaDatas[path]
    if meta == nil then
        return compiler.newSourceFileMetaData()
    end
    return meta
end

function Program:GetEmitModuleFormatOfFile(sourceFile)
    return ast.GetEmitModuleFormatOfFileWorker(sourceFile:FileName(), self.projectReferenceFileMapper:getCompilerOptionsForFile(sourceFile), self:GetSourceFileMetaData(sourceFile:Path()))
end

function Program:GetEmitSyntaxForUsageLocation(sourceFile, location)
    return compiler.getEmitSyntaxForUsageLocationWorker(sourceFile:FileName(), self:GetSourceFileMetaData(sourceFile:Path()), location, self.projectReferenceFileMapper:getCompilerOptionsForFile(sourceFile))
end

function Program:GetImpliedNodeFormatForEmit(sourceFile)
    return ast.GetImpliedNodeFormatForEmitWorker(sourceFile:FileName(), self.projectReferenceFileMapper:getCompilerOptionsForFile(sourceFile):GetEmitModuleKind(), self:GetSourceFileMetaData(sourceFile:Path()))
end

function Program:GetModeForUsageLocation(sourceFile, location)
    return compiler.getModeForUsageLocation(sourceFile:FileName(), self:GetSourceFileMetaData(sourceFile:Path()), location, self.projectReferenceFileMapper:getCompilerOptionsForFile(sourceFile))
end

function Program:GetDefaultResolutionModeForFile(sourceFile)
    return compiler.getDefaultResolutionModeForFile(sourceFile:FileName(), self:GetSourceFileMetaData(sourceFile:Path()), self.projectReferenceFileMapper:getCompilerOptionsForFile(sourceFile))
end

function Program:IsSourceFileDefaultLibrary(path)
    return self.libFiles[path] ~= nil
end

function Program:IsGlobalTypingsFile(fileName)
    if not tspath.IsDeclarationFileName(fileName) then
        return false
    end
    return tspath.ContainsPath(self:GetGlobalTypingsCacheLocation(), fileName, self.comparePathsOptions)
end

function Program:GetDefaultLibFile(path)
    return self.libFiles[path]
end

function Program:CommonSourceDirectory()
    if not self.commonSourceDirectoryDone then
        self.commonSourceDirectoryDone = true
        local function files()
            return core.MapFiltered(self.files, function(file)
                return file:FileName(), compiler.sourceFileMayBeEmitted(file, self, false, false) and not file.isDeclarationFile
            end)
        end
        self.commonSourceDirectory = outputpaths.GetCommonSourceDirectory(
            self:Options(),
            files,
            self:GetCurrentDirectory(),
            self:UseCaseSensitiveFileNames(),
            function(sourceFiles, rootDirectory) return self:checkSourceFilesBelongToPath(sourceFiles, rootDirectory) end
        )
    end
    return self.commonSourceDirectory
end

function Program:checkSourceFilesBelongToPath(sourceFiles, rootDirectory)
    local allFilesBelongToPath = true
    for _, file in ipairs(sourceFiles) do
        local absoluteSourceFilePath = tspath.GetCanonicalFileName(tspath.GetNormalizedAbsolutePath(file, self:GetCurrentDirectory()), self:UseCaseSensitiveFileNames())
        if not tspath.ContainsPath(rootDirectory, file, self.comparePathsOptions) then
            self.includeProcessor:addProcessingDiagnostic(compiler.newProcessingDiagnostic(
                compiler.processingDiagnosticKindExplainingFileInclude,
                compiler.newIncludeExplainingDiagnostic({
                    file = absoluteSourceFilePath,
                    message = diagnostics.File_0_is_not_under_rootDir_1_rootDir_is_expected_to_contain_all_source_files,
                    args = { file, rootDirectory },
                })
            ))
            allFilesBelongToPath = false
        end
    end

    return allFilesBelongToPath
end

-- WriteFileData: { sourceMapUrlPos, buildInfo, diagnostics, skippedDtsWrite, sourceFile }
function compiler.newWriteFileData(fields)
    fields = fields or {}
    return {
        sourceMapUrlPos = fields.sourceMapUrlPos or 0,
        buildInfo = fields.buildInfo,
        diagnostics = fields.diagnostics,
        skippedDtsWrite = fields.skippedDtsWrite or false,
        sourceFile = fields.sourceFile,
    }
end

-- WriteFile: func(fileName, text, data *WriteFileData) error

-- EmitOptions: { targetSourceFiles (nil = all files), emitOnly, forceEmit, writeFile }
function compiler.NewEmitOptions(fields)
    fields = fields or {}
    return {
        targetSourceFiles = fields.targetSourceFiles,
        emitOnly = fields.emitOnly or EmitOnly.EmitAll,
        forceEmit = fields.forceEmit or false,
        writeFile = fields.writeFile,
    }
end

-- EmitResult: { emitSkipped, diagnostics, emittedFiles, sourceMaps }
function compiler.newEmitResult(fields)
    fields = fields or {}
    return {
        emitSkipped = fields.emitSkipped or false,
        diagnostics = fields.diagnostics, -- Contains declaration emit diagnostics
        emittedFiles = fields.emittedFiles, -- Array of files the compiler wrote to disk
        sourceMaps = fields.sourceMaps, -- Array of sourceMapData if compiler emitted sourcemaps
    }
end

-- SourceMapEmitResult: { inputSourceFileNames, sourceMap, generatedFile }

function Program:Emit(ctx, options)
    options = compiler.NewEmitOptions(options)

    if not options.forceEmit and options.emitOnly ~= EmitOnly.BuilderSignature then
        local result = compiler.HandleNoEmitOptions(
            ctx,
            self,
            options.targetSourceFiles,
            nil
        )
        if result ~= nil then
            return result
        end
    end

    local newLine = core.NewLineKind_GetNewLineCharacter(self:Options().newLine)
    local wg = core.NewWorkGroup(self:SingleThreaded())
    local emitters = {}
    local forceDtsEmit = options.emitOnly == EmitOnly.BuilderSignature or options.forceEmit and options.emitOnly == EmitOnly.Dts
    local forceJsEmit = options.forceEmit and options.emitOnly == EmitOnly.Js
    local sourceFiles = self:getSourceFilesToEmit(options.targetSourceFiles, forceDtsEmit, forceJsEmit)

    for _, sourceFile in ipairs(sourceFiles) do
        local e = compiler.newEmitter({
            writer = nil,
            sourceFile = sourceFile,
            emitOnly = options.emitOnly,
            forceEmit = options.forceEmit,
            writeFile = options.writeFile,
            tr = self.opts.tracing,
        })
        emitters[#emitters + 1] = e
        wg:Queue(function()
            local host, done = compiler.newEmitHost(ctx, self, sourceFile)
            e.host = host

            local writer = printer.NewTextWriter(newLine, 0)
            writer:Clear()

            -- attach writer and perform emit
            e.writer = writer
            e.paths = outputpaths.GetOutputPathsFor(sourceFile, host:Options(), host, {
                dts = forceDtsEmit,
                js = forceJsEmit,
                declarationMap = options.forceEmit and options.emitOnly == EmitOnly.Dts,
            })
            e:emit()
            e.writer = nil
            done()
        end)
    end

    -- wait for emit to complete
    wg:RunAndWait()

    -- collect results from emit, preserving input order
    return compiler.CombineEmitResults(core.Map(emitters, function(e)
        return e.emitResult
    end))
end

function compiler.CombineEmitResults(results)
    local result = compiler.newEmitResult()
    for _, emitResult in ipairs(results) do
        if emitResult.emitSkipped then
            result.emitSkipped = true
        end
        result.diagnostics = core.AppendAll(result.diagnostics, emitResult.diagnostics)
        result.emittedFiles = core.AppendAll(result.emittedFiles, emitResult.emittedFiles)
        if emitResult.sourceMaps ~= nil then
            result.sourceMaps = core.AppendAll(result.sourceMaps, emitResult.sourceMaps)
        end
    end
    return result
end

-- ProgramLike interface: Options(), GetSourceFile(path), GetSourceFiles(), GetConfigFileParsingDiagnostics(),
-- GetSyntacticDiagnostics(ctx, file), GetBindDiagnostics(ctx, file), GetProgramDiagnostics(),
-- GetGlobalDiagnostics(ctx), GetSemanticDiagnostics(ctx, file), GetDeclarationDiagnostics(ctx, file),
-- GetSuggestionDiagnostics(ctx, file), Emit(ctx, options), CommonSourceDirectory(),
-- IsSourceFileDefaultLibrary(path), Program().

-- HandleNoEmitOptions mirrors tsc's handleNoEmitOptions.
function compiler.HandleNoEmitOptions(ctx, program, files, emitBuildInfo)
    if not isTrue(program:Options().noEmit) then
        if not isTrue(program:Options().noEmitOnError) then
            return nil -- NoEmit is false and NoEmitOnError is also false, so we can proceed with normal emit
        end

        local diags = compiler.GetDiagnosticsOfAnyProgram(
            ctx,
            program,
            files,
            true,
            function(c, f) return program:GetBindDiagnostics(c, f) end,
            function(c, f) return program:GetSemanticDiagnostics(c, f) end
        )
        if #diags == 0 then
            return nil -- NoEmitOnError is enabled, but no diagnostics were found, so we can proceed with emitting
        end
        return compiler.newEmitResult({
            diagnostics = diags,
            emitSkipped = true,
        })
    end
    if files ~= nil then
        return compiler.newEmitResult({ emitSkipped = true })
    end
    if emitBuildInfo ~= nil then
        local result = emitBuildInfo()
        if result ~= nil then
            return result
        end
    end
    return compiler.newEmitResult()
end

function compiler.GetDiagnosticsOfAnyProgram(ctx, program, files, skipNoEmitCheckForDtsDiagnostics, getBindDiagnostics, getSemanticDiagnostics)
    local allDiagnostics = core.Slice(program:GetConfigFileParsingDiagnostics())
    local configFileParsingDiagnosticsLength = #allDiagnostics

    local function appendDiagnosticsForAllFiles(diags, getDiagnostics)
        if files == nil then
            return core.AppendAll(diags, getDiagnostics(ctx, nil))
        end
        for _, file in ipairs(files) do
            diags = core.AppendAll(diags, getDiagnostics(ctx, file))
        end
        return diags
    end

    local syntacticDiagnostics = appendDiagnosticsForAllFiles(nil, function(c, f) return program:GetSyntacticDiagnostics(c, f) end)
    if core.Len(syntacticDiagnostics) > 0 then
        -- Per-file content mapper failures are syntactic diagnostics, but the locationless diagnostic
        -- that disables a repeatedly failing mapper must still be reported.
        core.AppendAll(allDiagnostics, program:Program().contentMapperDiagnostics)
    end
    core.AppendAll(allDiagnostics, syntacticDiagnostics)

    -- If we didn't have any syntactic errors, then also try getting the program (options),
    -- global and semantic errors.
    if #allDiagnostics == configFileParsingDiagnosticsLength then
        core.AppendAll(allDiagnostics, program:GetProgramDiagnostics())

        -- Do binding early so we can track the time.
        appendDiagnosticsForAllFiles(nil, getBindDiagnostics)

        if core.Tristate_IsFalseOrUnknown(program:Options().listFilesOnly) then
            core.AppendAll(allDiagnostics, program:GetGlobalDiagnostics(ctx))

            if #allDiagnostics == configFileParsingDiagnosticsLength then
                allDiagnostics = appendDiagnosticsForAllFiles(allDiagnostics, getSemanticDiagnostics)
                -- Ask for the global diagnostics again (they were empty above); we may have found new during checking, e.g. missing globals.
                core.AppendAll(allDiagnostics, program:GetGlobalDiagnostics(ctx))
            end

            if (skipNoEmitCheckForDtsDiagnostics or isTrue(program:Options().noEmit)) and program:Options():GetEmitDeclarations() and #allDiagnostics == configFileParsingDiagnosticsLength then
                allDiagnostics = appendDiagnosticsForAllFiles(allDiagnostics, function(c, f) return program:GetDeclarationDiagnostics(c, f) end)
            end
        end
    end
    return allDiagnostics
end

function Program:toPath(filename)
    return tspath.ToPath(filename, self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
end

function Program:GetSourceFile(filename)
    local path = self:toPath(filename)
    return self:GetSourceFileByPath(path)
end

function Program:GetSourceFileForResolvedModule(fileName)
    local file = self:GetSourceFile(fileName)
    if file == nil then
        local filename = self:GetParseFileRedirect(fileName)
        if filename ~= "" then
            return self:GetSourceFile(filename)
        end
    end
    return file
end

function Program:FilesByPath()
    return self.filesByPath
end

function Program:GetSourceFileByPath(path)
    return self.filesByPath[path]
end

local function mapsEqualFunc(a, b, eq)
    a = a or {}
    b = b or {}
    if compiler.mapLen(a) ~= compiler.mapLen(b) then
        return false
    end
    for k, v in pairs(a) do
        local w = b[k]
        if w == nil or not eq(v, w) then
            return false
        end
    end
    return true
end

function Program:HasSameFileNames(other)
    return mapsEqualFunc(self.filesByPath, other.filesByPath, function(a, b)
        -- checks for casing differences on case-insensitive file systems
        return a:FileName() == b:FileName()
    end) and mapsEqualFunc(self.redirectFilesByPath, other.redirectFilesByPath, function(a, b)
        return a:FileName() == b:FileName()
    end)
end

function Program:GetSourceFiles()
    return self.files
end

-- Testing only
function Program:GetIncludeReasons()
    return self.includeProcessor.fileIncludeReasons
end

-- Testing only
function Program:IsMissingPath(path)
    for _, missingPath in ipairs(self.missingFiles or {}) do
        if self:toPath(missingPath) == path then
            return true
        end
    end
    return false
end

function Program:ExplainFiles(w, locale)
    local function toRelativeFileName(fileName)
        return tspath.GetRelativePathFromDirectory(self:GetCurrentDirectory(), fileName, self.comparePathsOptions)
    end
    local filesExplained = 0
    local function explainFile(file)
        compiler.fprintln(w, toRelativeFileName(file:FileName()))
        for _, reason in ipairs(self.includeProcessor.fileIncludeReasons[file:Path()] or {}) do
            compiler.fprintln(w, "  ", reason:toDiagnostic(self, true):Localize(locale))
        end
        for _, diag in ipairs(self.includeProcessor:explainRedirectAndImpliedFormat(self, file:Path(), toRelativeFileName) or {}) do
            compiler.fprintln(w, "  ", diag:Localize(locale))
        end
        filesExplained = filesExplained + 1
    end

    local redirectFiles = {}
    for _, f in pairs(self.redirectFilesByPath or {}) do
        redirectFiles[#redirectFiles + 1] = f
    end
    table.sort(redirectFiles, function(a, b)
        return a.index < b.index
    end)

    local files = self:GetSourceFiles()
    local sourceFileIndex = 0
    local function explainSourceFiles(endIndex)
        while filesExplained < endIndex do
            explainFile(files[sourceFileIndex + 1])
            sourceFileIndex = sourceFileIndex + 1
        end
    end

    for _, redirectFile in ipairs(redirectFiles) do
        -- Explain all sourceFiles till we reach this redirectFile index
        explainSourceFiles(redirectFile.index)
        explainFile(redirectFile)
    end

    -- Explain any remaining sourceFiles
    explainSourceFiles(#files + #redirectFiles)
end

function Program:GetLibFileFromReference(ref)
    local path, ok = tsoptions.GetLibFileName(ref.fileName)
    if not ok then
        return nil
    end
    return self.filesByPath[path]
end

function Program:GetResolvedTypeReferenceDirectiveFromTypeReferenceDirective(typeRef, sourceFile)
    local resolutions = self.typeResolutionsInFile[sourceFile:Path()]
    if resolutions ~= nil then
        return resolutions[compiler.modeAwareCacheKey(typeRef.fileName, self:getModeForTypeReferenceDirectiveInFile(typeRef, sourceFile))]
    end
    return nil
end

-- Returns map[tspath.Path]ModeAwareCache (see compiler.modeAwareCacheKey).
function Program:GetResolvedTypeReferenceDirectives()
    return self.typeResolutionsInFile
end

function Program:getModeForTypeReferenceDirectiveInFile(ref, sourceFile)
    if ref.resolutionMode ~= ModuleKind.ResolutionModeNone then
        return ref.resolutionMode
    end
    return self:GetDefaultResolutionModeForFile(sourceFile)
end

function Program:IsSourceFileFromExternalLibrary(file)
    return self.sourceFilesFoundSearchingNodeModules[file:Path()] == true
end

-- Returns (moduleReference string, specifier *ast.Node).
function Program:GetJSXRuntimeImportSpecifier(path)
    local result = self.jsxRuntimeImportSpecifiers ~= nil and self.jsxRuntimeImportSpecifiers[path] or nil
    if result ~= nil then
        return result.moduleReference, result.specifier
    end
    return "", nil
end

function Program:GetImportHelpersImportSpecifier(path)
    if self.importHelpersImportSpecifiers == nil then
        return nil
    end
    return self.importHelpersImportSpecifiers[path]
end

function Program:SourceFileMayBeEmitted(sourceFile, forceDtsEmit)
    return compiler.sourceFileMayBeEmitted(sourceFile, self, forceDtsEmit, false)
end

function Program:ResolvedPackageNames()
    return self:collectPackageNames().resolved
end

function Program:UnresolvedPackageNames()
    return self:collectPackageNames().unresolved
end

function Program:DeepImportPackageNames()
    return self:collectPackageNames().deepImportPackages
end

function Program:collectPackageNames()
    return lazyGetValue(self.packageNames, function()
        local modulespecifiers = require("tslua.modulespecifiers")
        local packageNames = {
            resolved = collections.NewSetWithSizeHint(0),
            unresolved = collections.NewSetWithSizeHint(0),
            deepImportPackages = collections.NewSetWithSizeHint(0),
        }
        for _, file in ipairs(self.files) do
            if self:IsSourceFileDefaultLibrary(file:Path()) or self:IsSourceFileFromExternalLibrary(file) or compiler.contains(file:FileName(), "/node_modules/") then
                -- Checking for /node_modules/ is a little imprecise, but ATA treats locally installed typings
                -- as root files, which would not pass IsSourceFileFromExternalLibrary.
                goto nextFile
            end
            for _, imp in ipairs(file:Imports() or {}) do
                if tspath.IsExternalModuleNameRelative(imp:Text()) then
                    goto nextImport
                end
                do
                    local resolvedModules = self.resolvedModules[file:Path()]
                    if resolvedModules ~= nil then
                        local resolvedModule = resolvedModules[compiler.modeAwareCacheKey(imp:Text(), self:GetModeForUsageLocation(file, imp))]
                        if resolvedModule ~= nil and resolvedModule:IsResolved() then
                            if not resolvedModule.isExternalLibraryImport then
                                goto nextImport
                            end
                            -- Priority order for getting package name:
                            -- 1. PackageId.Name (requires both name and version in package.json)
                            local name = compiler.packageIdName(resolvedModule.packageId)
                            if name == "" then
                                -- 2. GetPackageScopeForPath - get name from package.json in the package directory
                                local packageScope = self.resolver:GetPackageScopeForPath(resolvedModule.resolvedFileName)
                                if infoExists(packageScope) then
                                    local scopeName, ok = packageScope.contents.name:GetValue()
                                    if ok then
                                        name = scopeName
                                    end
                                end
                            end
                            if name == "" then
                                -- 3. GetPackageNameFromDirectory - extract from node_modules path
                                name = modulespecifiers.GetPackageNameFromDirectory(resolvedModule.resolvedFileName)
                            end
                            -- 4. If all fail, don't add empty string
                            if name ~= "" then
                                packageNames.resolved:Add(name)
                                -- Detect deep imports: subpath imports in packages without exports.
                                -- These are imports like "lodash/fp" where the package has no exports
                                -- map, so auto-import can only find them via recursive directory search.
                                local _, rest = module.ParsePackageName(imp:Text())
                                if rest ~= "" then
                                    local scope = self.resolver:GetPackageScopeForPath(resolvedModule.resolvedFileName)
                                    if infoExists(scope) and not scope.contents.exports:IsPresent() then
                                        packageNames.deepImportPackages:Add(module.GetPackageNameFromTypesPackageName(name))
                                    end
                                end
                            end
                            goto nextImport
                        end
                    end
                    packageNames.unresolved:Add(imp:Text())
                end
                ::nextImport::
            end
            ::nextFile::
        end
        return packageNames
    end)
end

function Program:IsLibFile(sourceFile)
    return self.libFiles[sourceFile:Path()] ~= nil
end

function Program:HasTSFile()
    if not self.hasTSFileDone then
        self.hasTSFileDone = true
        for _, file in ipairs(self.files) do
            if tspath.HasImplementationTSFileExtension(file:FileName()) then
                self.hasTSFile = true
                break
            end
        end
    end
    return self.hasTSFile
end

function Program:GetSymlinkCache()
    return lazyGetValue(self.knownSymlinks, function()
        local symlinks = require("tslua.symlinks")
        local knownSymlinks = symlinks.NewKnownSymlink(self:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())

        -- Resolved modules store realpath information when they're resolved inside node_modules
        if next(self.resolvedModules) ~= nil or next(self.typeResolutionsInFile) ~= nil then
            knownSymlinks:SetSymlinksFromResolutions(
                function(callback, file) self:ForEachResolvedModule(callback, file) end,
                function(callback, file) self:ForEachResolvedTypeReferenceDirective(callback, file) end
            )
        end

        -- Check other dependencies for symlinks
        local seenPackageJsons = {}
        for _, filePath in ipairs(compiler.sortedKeys(self.sourceFileMetaDatas)) do
            local meta = self.sourceFileMetaDatas[filePath]
            if meta.packageJsonDirectory == "" or
                not self:SourceFileMayBeEmitted(self:GetSourceFileByPath(filePath), false) then
                goto continue
            end
            do
                local pjPath = self:toPath(meta.packageJsonDirectory)
                if seenPackageJsons[pjPath] then
                    goto continue
                end
                seenPackageJsons[pjPath] = true
                local packageJsonName = tspath.CombinePaths(meta.packageJsonDirectory, "package.json")
                local info = self:GetPackageJsonInfo(packageJsonName)
                if info == nil or info:GetContents() == nil then
                    goto continue
                end

                for dep in info:GetContents():GetRuntimeDependencyNames():Keys() do
                    -- Skip work in common case: we already saved a symlink for this package directory
                    -- in the node_modules adjacent to this package.json
                    local possibleDirectoryPath = self:toPath(tspath.CombinePaths(meta.packageJsonDirectory, "node_modules", dep))
                    if knownSymlinks:HasDirectory(possibleDirectoryPath) then
                        goto nextDep
                    end
                    if not compiler.hasPrefix(dep, "@types") then
                        local possibleTypesDirectoryPath = self:toPath(tspath.CombinePaths(meta.packageJsonDirectory, "node_modules", module.GetTypesPackageName(dep)))
                        if knownSymlinks:HasDirectory(possibleTypesDirectoryPath) then
                            goto nextDep
                        end
                    end

                    do
                        local packageResolution = self.resolver:ResolvePackageDirectory(dep, packageJsonName, ModuleKind.ResolutionModeCommonJS, nil)
                        if packageResolution:IsResolved() and packageResolution.originalPath ~= "" then
                            knownSymlinks:ProcessResolution(
                                tspath.CombinePaths(packageResolution.originalPath, "package.json"),
                                tspath.CombinePaths(packageResolution.resolvedFileName, "package.json")
                            )
                        end
                    end
                    ::nextDep::
                end
            end
            ::continue::
        end
        return knownSymlinks
    end)
end

function Program:ResolveModuleName(moduleName, containingFile, resolutionMode)
    local resolved = self.resolver:ResolveModuleName(moduleName, containingFile, resolutionMode, nil)
    return resolved
end

-- callback(resolution, moduleName, mode, filePath)
function Program:ForEachResolvedModule(callback, file)
    compiler.forEachResolution(self.resolvedModules, callback, file)
end

function Program:ForEachResolvedTypeReferenceDirective(callback, file)
    compiler.forEachResolution(self.typeResolutionsInFile, callback, file)
end

function compiler.forEachResolution(resolutionCache, callback, file)
    if file ~= nil then
        local resolutions = resolutionCache[file:Path()]
        if resolutions ~= nil then
            for name, mode, resolution in compiler.modeAwareCachePairs(resolutions) do
                callback(resolution, name, mode, file:Path())
            end
        end
    else
        for _, filePath in ipairs(compiler.sortedKeys(resolutionCache)) do
            for name, mode, resolution in compiler.modeAwareCachePairs(resolutionCache[filePath]) do
                callback(resolution, name, mode, filePath)
            end
        end
    end
end

compiler.plainJSErrors = {}
for _, message in ipairs({
    -- binder errors
    diagnostics.Cannot_redeclare_block_scoped_variable_0,
    diagnostics.A_module_cannot_have_multiple_default_exports,
    diagnostics.Another_export_default_is_here,
    diagnostics.The_first_export_default_is_here,
    diagnostics.Identifier_expected_0_is_a_reserved_word_at_the_top_level_of_a_module,
    diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Modules_are_automatically_in_strict_mode,
    diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here,
    diagnostics.X_constructor_is_a_reserved_word,
    diagnostics.X_delete_cannot_be_called_on_an_identifier_in_strict_mode,
    diagnostics.Code_contained_in_a_class_is_evaluated_in_JavaScript_s_strict_mode_which_does_not_allow_this_use_of_0_For_more_information_see_https_Colon_Slash_Slashdeveloper_mozilla_org_Slashen_US_Slashdocs_SlashWeb_SlashJavaScript_SlashReference_SlashStrict_mode,
    diagnostics.Invalid_use_of_0_Modules_are_automatically_in_strict_mode,
    diagnostics.Invalid_use_of_0_in_strict_mode,
    diagnostics.A_label_is_not_allowed_here,
    diagnostics.X_with_statements_are_not_allowed_in_strict_mode,
    -- grammar errors
    diagnostics.A_break_statement_can_only_be_used_within_an_enclosing_iteration_or_switch_statement,
    diagnostics.A_break_statement_can_only_jump_to_a_label_of_an_enclosing_statement,
    diagnostics.A_class_declaration_without_the_default_modifier_must_have_a_name,
    diagnostics.A_class_member_cannot_have_the_0_keyword,
    diagnostics.A_comma_expression_is_not_allowed_in_a_computed_property_name,
    diagnostics.A_continue_statement_can_only_be_used_within_an_enclosing_iteration_statement,
    diagnostics.A_continue_statement_can_only_jump_to_a_label_of_an_enclosing_iteration_statement,
    diagnostics.A_default_clause_cannot_appear_more_than_once_in_a_switch_statement,
    diagnostics.A_default_export_must_be_at_the_top_level_of_a_file_or_module_declaration,
    diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context,
    diagnostics.A_destructuring_declaration_must_have_an_initializer,
    diagnostics.A_get_accessor_cannot_have_parameters,
    diagnostics.A_rest_element_cannot_contain_a_binding_pattern,
    diagnostics.A_rest_element_cannot_have_a_property_name,
    diagnostics.A_rest_element_cannot_have_an_initializer,
    diagnostics.A_rest_element_must_be_last_in_a_destructuring_pattern,
    diagnostics.A_rest_parameter_cannot_have_an_initializer,
    diagnostics.A_rest_parameter_must_be_last_in_a_parameter_list,
    diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma,
    diagnostics.A_return_statement_cannot_be_used_inside_a_class_static_block,
    diagnostics.A_set_accessor_cannot_have_rest_parameter,
    diagnostics.A_set_accessor_must_have_exactly_one_parameter,
    diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_module,
    diagnostics.An_export_declaration_cannot_have_modifiers,
    diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module,
    diagnostics.An_import_declaration_cannot_have_modifiers,
    diagnostics.An_object_member_cannot_be_declared_optional,
    diagnostics.Argument_of_dynamic_import_cannot_be_spread_element,
    diagnostics.Cannot_assign_to_private_method_0_Private_methods_are_not_writable,
    diagnostics.Cannot_redeclare_identifier_0_in_catch_clause,
    diagnostics.Catch_clause_variable_cannot_have_an_initializer,
    diagnostics.Class_decorators_can_t_be_used_with_static_private_identifier_Consider_removing_the_experimental_decorator,
    diagnostics.Classes_can_only_extend_a_single_class,
    diagnostics.Classes_may_not_have_a_field_named_constructor,
    diagnostics.Did_you_mean_to_use_a_Colon_An_can_only_follow_a_property_name_when_the_containing_object_literal_is_part_of_a_destructuring_pattern,
    diagnostics.Duplicate_label_0,
    diagnostics.Dynamic_imports_can_only_accept_a_module_specifier_and_an_optional_set_of_attributes_as_arguments,
    diagnostics.X_for_await_loops_cannot_be_used_inside_a_class_static_block,
    diagnostics.JSX_attributes_must_only_be_assigned_a_non_empty_expression,
    diagnostics.JSX_elements_cannot_have_multiple_attributes_with_the_same_name,
    diagnostics.JSX_expressions_may_not_use_the_comma_operator_Did_you_mean_to_write_an_array,
    diagnostics.JSX_property_access_expressions_cannot_include_JSX_namespace_names,
    diagnostics.Jump_target_cannot_cross_function_boundary,
    diagnostics.Line_terminator_not_permitted_before_arrow,
    diagnostics.Modifiers_cannot_appear_here,
    diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_in_statement,
    diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_of_statement,
    diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies,
    diagnostics.Private_identifiers_are_only_allowed_in_class_bodies_and_may_only_be_used_as_part_of_a_class_member_declaration_property_access_or_on_the_left_hand_side_of_an_in_expression,
    diagnostics.Property_0_is_not_accessible_outside_class_1_because_it_has_a_private_identifier,
    diagnostics.Tagged_template_expressions_are_not_permitted_in_an_optional_chain,
    diagnostics.The_left_hand_side_of_a_for_of_statement_may_not_be_async,
    diagnostics.The_variable_declaration_of_a_for_in_statement_cannot_have_an_initializer,
    diagnostics.The_variable_declaration_of_a_for_of_statement_cannot_have_an_initializer,
    diagnostics.Trailing_comma_not_allowed,
    diagnostics.Variable_declaration_list_cannot_be_empty,
    diagnostics.X_0_and_1_operations_cannot_be_mixed_without_parentheses,
    diagnostics.X_0_expected,
    diagnostics.X_0_is_not_a_valid_meta_property_for_keyword_1_Did_you_mean_2,
    diagnostics.X_0_list_cannot_be_empty,
    diagnostics.X_0_modifier_already_seen,
    diagnostics.X_0_modifier_cannot_appear_on_a_constructor_declaration,
    diagnostics.X_0_modifier_cannot_appear_on_a_module_or_namespace_element,
    diagnostics.X_0_modifier_cannot_appear_on_a_parameter,
    diagnostics.X_0_modifier_cannot_appear_on_class_elements_of_this_kind,
    diagnostics.X_0_modifier_cannot_be_used_here,
    diagnostics.X_0_modifier_must_precede_1_modifier,
    diagnostics.X_0_declarations_can_only_be_declared_inside_a_block,
    diagnostics.X_0_declarations_must_be_initialized,
    diagnostics.X_extends_clause_already_seen,
    diagnostics.X_let_is_not_allowed_to_be_used_as_a_name_in_let_or_const_declarations,
    diagnostics.Class_constructor_may_not_be_a_generator,
    diagnostics.Class_constructor_may_not_be_an_accessor,
    diagnostics.X_await_expressions_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules,
    diagnostics.X_await_using_statements_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules,
    diagnostics.Private_field_0_must_be_declared_in_an_enclosing_class,
    -- Type errors
    diagnostics.This_condition_will_always_return_0_since_JavaScript_compares_objects_by_reference_not_value,
}) do
    compiler.plainJSErrors[message:Code()] = true
end
