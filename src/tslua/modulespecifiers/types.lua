local modulespecifiers = require("tslua.modulespecifiers")
local core = require("tslua.core")

-- SourceFileForSpecifierGeneration is an interface: a table with the methods
--   Path() -> tspath.Path, FileName() -> string, Imports() -> []*ast.StringLiteralLike, IsJS() -> bool
-- (an ast.SourceFile satisfies it).
--
-- CheckerShape is an interface: a table with the methods
--   GetSymbolAtLocation(node) -> *ast.Symbol, GetAliasedSymbol(symbol) -> *ast.Symbol
--
-- ModuleSpecifierGenerationHost is an interface: a table with the methods
--   GetSymlinkCache() -> *symlinks.KnownSymlinks
--   CommonSourceDirectory() -> string
--   ContentMapperExtensions() -> []string
--   GetGlobalTypingsCacheLocation() -> string
--   UseCaseSensitiveFileNames() -> bool
--   GetCurrentDirectory() -> string
--   GetProjectReferenceFromSource(path) -> *tsoptions.SourceOutputAndProjectReference
--   GetRedirectTargets(path) -> []string
--   GetSourceOfProjectReferenceIfOutputIncluded(file) -> string
--   FileExists(path) -> bool
--   GetNearestAncestorDirectoryWithPackageJson(dirname) -> string
--   GetPackageJsonInfo(pkgJsonPath) -> *packagejson.InfoCacheEntry
--   GetDefaultResolutionModeForFile(file) -> core.ResolutionMode
--   GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier) -> *module.ResolvedModule
--   GetModeForUsageLocation(file, moduleSpecifier) -> core.ResolutionMode
-- All are called as methods (host:GetCurrentDirectory()).

-- ModulePath is a Go value struct: { fileName, isInNodeModules, isRedirect }.
function modulespecifiers.NewModulePath(fileName, isInNodeModules, isRedirect)
    return {
        fileName = fileName or "",
        isInNodeModules = isInNodeModules or false,
        isRedirect = isRedirect or false,
    }
end

-- UserPreferences is a Go value struct:
--   { importModuleSpecifierPreference, importModuleSpecifierEnding, autoImportSpecifierExcludeRegexes }
-- UserPreferences_new(init) is Go's `UserPreferences{...}` (zero values filled in).
function modulespecifiers.UserPreferences_new(init)
    local p = {
        importModuleSpecifierPreference = modulespecifiers.ImportModuleSpecifierPreference.None,
        importModuleSpecifierEnding = modulespecifiers.ImportModuleSpecifierEndingPreference.None,
        autoImportSpecifierExcludeRegexes = nil,
    }
    if init ~= nil then
        for k, v in pairs(init) do
            p[k] = v
        end
    end
    return p
end

-- ModuleSpecifierOptions is a Go value struct: { overrideImportMode }.
-- ModuleSpecifierOptions_new(init) is Go's `ModuleSpecifierOptions{...}`.
function modulespecifiers.ModuleSpecifierOptions_new(init)
    local o = {
        overrideImportMode = core.ModuleKind.ResolutionModeNone,
    }
    if init ~= nil then
        for k, v in pairs(init) do
            o[k] = v
        end
    end
    return o
end

return modulespecifiers
