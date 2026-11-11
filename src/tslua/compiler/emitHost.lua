local compiler = require("tslua.compiler")
local outputpaths = require("tslua.outputpaths")

-- EmitHost interface: printer.EmitHost + declarations.DeclarationEmitHost + Options(), SourceFiles(),
-- UseCaseSensitiveFileNames(), GetCurrentDirectory(), CommonSourceDirectory(), IsEmitBlocked(file).

local emitHost = {}
emitHost.__index = emitHost
compiler.emitHost = emitHost

-- Returns (*emitHost, done func).
function compiler.newEmitHost(ctx, program, file)
    local c, done = program:GetTypeCheckerForFile(ctx, file)
    return setmetatable({
        program = program,
        emitResolver = c:GetEmitResolver(),
    }, emitHost), done
end

function emitHost:GetModeForUsageLocation(file, moduleSpecifier)
    return self.program:GetModeForUsageLocation(file, moduleSpecifier)
end

function emitHost:GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier)
    return self.program:GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier)
end

function emitHost:GetDefaultResolutionModeForFile(file)
    return self.program:GetDefaultResolutionModeForFile(file)
end

function emitHost:GetEmitModuleFormatOfFile(file)
    return self.program:GetEmitModuleFormatOfFile(file)
end

function emitHost:FileExists(path)
    return self.program:FileExists(path)
end

function emitHost:GetGlobalTypingsCacheLocation()
    return self.program:GetGlobalTypingsCacheLocation()
end

function emitHost:GetNearestAncestorDirectoryWithPackageJson(dirname)
    return self.program:GetNearestAncestorDirectoryWithPackageJson(dirname)
end

function emitHost:GetPackageJsonInfo(pkgJsonPath)
    return self.program:GetPackageJsonInfo(pkgJsonPath)
end

function emitHost:GetSourceOfProjectReferenceIfOutputIncluded(file)
    return self.program:GetSourceOfProjectReferenceIfOutputIncluded(file)
end

function emitHost:GetProjectReferenceFromSource(path)
    return self.program:GetProjectReferenceFromSource(path)
end

function emitHost:GetRedirectTargets(path)
    return self.program:GetRedirectTargets(path)
end

function emitHost:GetEffectiveDeclarationFlags(node, flags)
    return self:GetEmitResolver():GetEffectiveDeclarationFlags(node, flags)
end

function emitHost:GetOutputPathsFor(file, forceDtsPaths)
    -- TODO: cache
    return outputpaths.GetOutputPathsFor(file, self:Options(), self, { dts = forceDtsPaths, js = false, declarationMap = false })
end

function emitHost:SourceFileMayBeEmitted(file, forceDtsEmit)
    return compiler.sourceFileMayBeEmitted(file, self, forceDtsEmit, false)
end

function emitHost:GetResolutionModeOverride(node)
    return self:GetEmitResolver():GetResolutionModeOverride(node)
end

function emitHost:GetSourceFileFromReference(origin, ref)
    return self.program:GetSourceFileFromReference(origin, ref)
end

function emitHost:Options() return self.program:Options() end
function emitHost:SourceFiles() return self.program:SourceFiles() end
function emitHost:GetCurrentDirectory() return self.program:GetCurrentDirectory() end
function emitHost:CommonSourceDirectory() return self.program:CommonSourceDirectory() end

function emitHost:ContentMapperExtensions()
    return self.program:ContentMapperExtensions()
end

function emitHost:UseCaseSensitiveFileNames()
    return self.program:UseCaseSensitiveFileNames()
end

function emitHost:IsEmitBlocked(file)
    return self.program:IsEmitBlocked(file)
end

function emitHost:WriteFile(fileName, text)
    return self.program:Host():FS():WriteFile(fileName, text)
end

function emitHost:GetEmitResolver()
    return self.emitResolver
end

function emitHost:IsSourceFileFromExternalLibrary(file)
    return self.program:IsSourceFileFromExternalLibrary(file)
end

function emitHost:GetSymlinkCache()
    return self.program:GetSymlinkCache()
end

function emitHost:ResolveModuleName(moduleName, containingFile, resolutionMode)
    local resolved = self.program.resolver:ResolveModuleName(moduleName, containingFile, resolutionMode, nil)
    return resolved
end
