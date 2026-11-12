local autoimport = require("tslua.ls.autoimport")
local binder = require("tslua.binder")
local collections = require("tslua.collections")
local core = require("tslua.core")
local module = require("tslua.module")
local tspath = require("tslua.tspath")

-- pathAndFileName { path, fileName }

-- aliasResolver implements checker.Program. Fields: toPath, host (RegistryCloneHost),
-- moduleResolver, rootFiles, symlinks (maps from realpath to symlinked path and file name),
-- onFailedAmbientModuleLookup, resolvedModules (SyncMap path -> SyncMap ModeAwareCacheKey -> ResolvedModule).
local aliasResolver = {}
aliasResolver.__index = aliasResolver
autoimport.aliasResolver = aliasResolver

function autoimport.newAliasResolver(rootFiles, symlinks, host, moduleResolver, toPath, onFailedAmbientModuleLookup)
    local r = setmetatable({
        toPath = toPath,
        host = host,
        moduleResolver = moduleResolver,
        rootFiles = rootFiles,
        symlinks = symlinks,
        onFailedAmbientModuleLookup = onFailedAmbientModuleLookup,
        resolvedModules = collections.NewSyncMap(),
    }, aliasResolver)
    return r
end

-- BindSourceFiles implements checker.Program.
function aliasResolver:BindSourceFiles()
    -- We will bind as we parse
end

-- SourceFiles implements checker.Program.
function aliasResolver:SourceFiles()
    return self.rootFiles
end

-- Options implements checker.Program.
function aliasResolver:Options()
    local opts = core.NewCompilerOptions()
    opts.noCheck = core.Tristate.TSTrue
    return opts
end

-- GetCurrentDirectory implements checker.Program.
function aliasResolver:GetCurrentDirectory()
    return self.host:GetCurrentDirectory()
end

-- UseCaseSensitiveFileNames implements checker.Program.
function aliasResolver:UseCaseSensitiveFileNames()
    return self.host:FS():UseCaseSensitiveFileNames()
end

-- GetSourceFile implements checker.Program.
function aliasResolver:GetSourceFile(fileName)
    local file = self.host:GetSourceFile(fileName, self.toPath(fileName))
    -- file may be nil due to symlink/realpath mismatch; see TestAutoImportBuilderFS
    if file == nil then
        return nil
    end
    binder.BindSourceFile(file)
    return file
end

-- GetDefaultResolutionModeForFile implements checker.Program.
function aliasResolver:GetDefaultResolutionModeForFile(file)
    return core.ModuleKind.ESNext
end

-- GetEmitModuleFormatOfFile implements checker.Program.
function aliasResolver:GetEmitModuleFormatOfFile(sourceFile)
    return core.ModuleKind.ESNext
end

-- GetEmitSyntaxForUsageLocation implements checker.Program.
function aliasResolver:GetEmitSyntaxForUsageLocation(sourceFile, usageLocation)
    return core.ModuleKind.ESNext
end

-- GetImpliedNodeFormatForEmit implements checker.Program.
function aliasResolver:GetImpliedNodeFormatForEmit(sourceFile)
    return core.ModuleKind.ESNext
end

-- GetModeForUsageLocation implements checker.Program.
function aliasResolver:GetModeForUsageLocation(file, moduleSpecifier)
    return core.ModuleKind.ESNext
end

-- GetResolvedModule implements checker.Program.
function aliasResolver:GetResolvedModule(currentSourceFile, moduleReference, mode)
    local cache = self.resolvedModules:LoadOrStore(currentSourceFile:Path(), collections.NewSyncMap())
    local key = module.ModeAwareCacheKeyString(moduleReference, mode)
    local resolved, ok = cache:Load(key)
    if ok then
        return resolved
    end
    resolved = self.moduleResolver:ResolveModuleName(moduleReference, currentSourceFile:FileName(), mode, nil)
    resolved = cache:LoadOrStore(key, resolved)
    if not resolved:IsResolved() and not tspath.PathIsRelative(moduleReference) then
        self.onFailedAmbientModuleLookup(currentSourceFile, moduleReference)
    end
    return resolved
end

-- GetSourceFileForResolvedModule implements checker.Program.
function aliasResolver:GetSourceFileForResolvedModule(fileName)
    return self:GetSourceFile(fileName)
end

-- GetResolvedModules implements checker.Program.
function aliasResolver:GetResolvedModules()
    -- only used when producing diagnostics, which hopefully the checker won't do
    return nil
end

-- ---

-- GetSymlinkCache implements checker.Program.
function aliasResolver:GetSymlinkCache()
    error("unimplemented", 0)
end

-- GetSourceFileMetaData implements checker.Program.
function aliasResolver:GetSourceFileMetaData(path)
    error("unimplemented", 0)
end

-- CommonSourceDirectory implements checker.Program.
function aliasResolver:CommonSourceDirectory()
    error("unimplemented", 0)
end

-- ContentMapperExtensions implements checker.Program.
function aliasResolver:ContentMapperExtensions()
    return nil
end

-- FileExists implements checker.Program.
function aliasResolver:FileExists(fileName)
    error("unimplemented", 0)
end

-- GetGlobalTypingsCacheLocation implements checker.Program.
function aliasResolver:GetGlobalTypingsCacheLocation()
    error("unimplemented", 0)
end

-- GetImportHelpersImportSpecifier implements checker.Program.
function aliasResolver:GetImportHelpersImportSpecifier(path)
    error("unimplemented", 0)
end

-- GetJSXRuntimeImportSpecifier implements checker.Program.
function aliasResolver:GetJSXRuntimeImportSpecifier(path)
    error("unimplemented", 0)
end

-- GetNearestAncestorDirectoryWithPackageJson implements checker.Program.
function aliasResolver:GetNearestAncestorDirectoryWithPackageJson(dirname)
    error("unimplemented", 0)
end

-- GetPackageJsonInfo implements checker.Program.
function aliasResolver:GetPackageJsonInfo(pkgJsonPath)
    error("unimplemented", 0)
end

-- GetProjectReferenceFromOutputDts implements checker.Program.
function aliasResolver:GetProjectReferenceFromOutputDts(path)
    error("unimplemented", 0)
end

-- GetProjectReferenceFromSource implements checker.Program.
function aliasResolver:GetProjectReferenceFromSource(path)
    error("unimplemented", 0)
end

-- GetRedirectForResolution implements checker.Program.
function aliasResolver:GetRedirectForResolution(file)
    error("unimplemented", 0)
end

-- GetRedirectTargets implements checker.Program.
function aliasResolver:GetRedirectTargets(path)
    error("unimplemented", 0)
end

-- GetResolvedModuleFromModuleSpecifier implements checker.Program.
function aliasResolver:GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier)
    error("unimplemented", 0)
end

-- GetSourceOfProjectReferenceIfOutputIncluded implements checker.Program.
function aliasResolver:GetSourceOfProjectReferenceIfOutputIncluded(file)
    error("unimplemented", 0)
end

-- IsSourceFileDefaultLibrary implements checker.Program.
function aliasResolver:IsSourceFileDefaultLibrary(path)
    return false
end

-- IsSourceFromProjectReference implements checker.Program.
function aliasResolver:IsSourceFromProjectReference(path)
    error("unimplemented", 0)
end

-- SourceFileMayBeEmitted implements checker.Program.
function aliasResolver:SourceFileMayBeEmitted(sourceFile, forceDtsEmit)
    error("unimplemented", 0)
end

function aliasResolver:GetPackagesMap()
    return nil
end
