local autoimport = require("tslua.ls.autoimport")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local module = require("tslua.module")
local modulespecifiers = require("tslua.modulespecifiers")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local wrapvfs = require("tslua.vfs.wrapvfs")

local Kind = ast.Kind
local OEK = ast.OuterExpressionKinds
local SymbolFlags = ast.SymbolFlags

-- Returns (moduleID, fileName, ok).
function autoimport.tryGetModuleIDAndFileNameOfModuleSymbol(symbol)
    if not symbol:IsExternalModule() then
        return "", "", false
    end
    local decl = ast.GetNonAugmentationDeclaration(symbol)
    if decl == nil then
        return "", "", false
    end
    if decl.kind == Kind.SourceFile then
        return decl:AsSourceFile():Path(), decl:AsSourceFile():FileName(), true
    end
    if ast.IsModuleWithStringLiteralName(decl) then
        return decl:Name():Text(), "", true
    end
    return "", "", false
end

-- Returns (moduleID, fileName).
function autoimport.getModuleIDAndFileNameOfModuleSymbol(symbol)
    if not symbol:IsExternalModule() then
        error("symbol is not an external module", 0)
    end
    local decl = ast.GetNonAugmentationDeclaration(symbol)
    if decl == nil then
        error("module symbol has no non-augmentation declaration", 0)
    end
    if decl.kind == Kind.SourceFile then
        return decl:AsSourceFile():Path(), decl:AsSourceFile():FileName()
    end
    if ast.IsModuleWithStringLiteralName(decl) then
        return decl:Name():Text(), ""
    end
    error("could not determine module ID of module symbol", 0)
end

-- wordIndices splits an identifier into its constituent words based on camelCase and snake_case conventions
-- by returning the starting byte indices of each word. The first index is always 0.
--   - CamelCase
--     ^    ^
--   - snake_case
--     ^     ^
--   - ParseURL
--     ^    ^
--   - __proto__
--     ^
function autoimport.wordIndices(s)
    local indices = {}
    local byteIndex = 0
    local n = #s
    while byteIndex < n do
        local runeValue, size = stringutil.DecodeRune(s, byteIndex)
        if byteIndex == 0 then
            indices[#indices + 1] = byteIndex
        elseif runeValue == 0x5F then -- '_'
            if byteIndex + 1 < n and string.byte(s, byteIndex + 2) ~= 0x5F then
                indices[#indices + 1] = byteIndex + 1
            end
        elseif stringutil.UnicodeIsUpper(runeValue) and (stringutil.UnicodeIsLower((stringutil.DecodeLastRune(s, byteIndex))) or (byteIndex + 1 < n and stringutil.UnicodeIsLower((stringutil.DecodeRune(s, byteIndex + 1))))) then
            indices[#indices + 1] = byteIndex
        end
        byteIndex = byteIndex + size
    end
    return indices
end

function autoimport.getPackageNamesInNodeModules(nodeModulesDir, fs)
    local packageNames = collections.NewSet()
    if tspath.GetBaseFileName(nodeModulesDir) ~= "node_modules" then
        error("nodeModulesDir is not a node_modules directory", 0)
    end
    -- A missing node_modules directory yields no entries (GetAccessibleEntries returns
    -- empty), so there's no need to check existence first: a deleted node_modules is
    -- handled upstream in updateBucketAndDirectoryExistence, which drops the bucket.
    local entries = fs:GetAccessibleEntries(nodeModulesDir)
    for _, baseName in ipairs(entries.directories or {}) do
        local c = string.byte(baseName, 1)
        if c == 0x2E then -- '.'
            goto continue
        end
        if c == 0x40 then -- '@'
            local scopedDirPath = tspath.CombinePaths(nodeModulesDir, baseName)
            for _, scopedPackageDirName in ipairs(fs:GetAccessibleEntries(scopedDirPath).directories or {}) do
                local scopedBaseName = tspath.GetBaseFileName(scopedPackageDirName)
                if baseName == "@types" then
                    packageNames:Add(module.GetPackageNameFromTypesPackageName(tspath.CombinePaths("@types", scopedBaseName)))
                else
                    packageNames:Add(tspath.CombinePaths(baseName, scopedBaseName))
                end
            end
            goto continue
        end
        packageNames:Add(baseName)
        ::continue::
    end
    return packageNames
end

function autoimport.getDefaultLikeExportNameFromDeclaration(symbol)
    for _, d in ipairs(symbol.declarations or {}) do
        -- "export default" in this case. See `ExportAssignment`for more details.
        if ast.IsExportAssignment(d) then
            local innerExpression = ast.SkipOuterExpressions(d:Expression(), OEK.All)
            if ast.IsIdentifier(innerExpression) then
                return innerExpression:Text()
            end
            goto continue
        end
        -- "export { ~ as default }"
        if ast.IsExportSpecifier(d) and d:Symbol().flags == SymbolFlags.Alias and d:PropertyName() ~= nil then
            if d:PropertyName().kind == Kind.Identifier then
                return d:PropertyName():Text()
            end
            goto continue
        end
        do
            -- GH#52694
            local name = ast.GetNameOfDeclaration(d)
            if name ~= nil and name.kind == Kind.Identifier then
                return name:Text()
            end
            if symbol.parent ~= nil and not checker.IsExternalModuleSymbol(symbol.parent) then
                return symbol.parent.name
            end
        end
        ::continue::
    end
    return ""
end

function autoimport.getResolvedPackageNames(ctx, program)
    local rawNames = program:ResolvedPackageNames()
    local unresolvedPackageNames = program:UnresolvedPackageNames()

    -- Normalize @types/ package names to their actual package names
    -- (e.g., "@types/react" → "react"). ResolvedPackageNames can contain
    -- @types names when the program resolves an import like "react" to
    -- "@types/react/index.d.ts" via the PackageId.Name field.
    local resolvedPackageNames = collections.NewSetWithSizeHint(collections.Set.Len(rawNames))
    for name in pairs(collections.Set.Keys(rawNames) or {}) do
        resolvedPackageNames:Add(module.GetPackageNameFromTypesPackageName(name))
    end

    for _, name in ipairs(program:Options().types or {}) do
        if name ~= "*" then
            resolvedPackageNames:Add(module.GetPackageNameFromTypesPackageName(name))
        end
    end

    if collections.Set.Len(unresolvedPackageNames) > 0 then
        local ch, done = program:GetTypeChecker(ctx)
        for name in pairs(collections.Set.Keys(unresolvedPackageNames) or {}) do
            local symbol = ch:TryFindAmbientModule(name)
            if symbol ~= nil then
                local declaringFile = ast.GetSourceFileOfModule(symbol)
                local packageName = modulespecifiers.GetPackageNameFromDirectory(declaringFile:FileName())
                if packageName ~= "" then
                    resolvedPackageNames:Add(module.GetPackageNameFromTypesPackageName(packageName))
                end
            end
        end
        if done ~= nil then
            done()
        end
    end
    return resolvedPackageNames
end

-- addProjectReferenceOutputMappings adds output .d.ts to source file mappings
-- from a program's project references to the provided map.
-- This is used during node_modules bucket building to redirect extraction
-- from output files to source files when the output is from a project reference.
function autoimport.addProjectReferenceOutputMappings(program, result)
    local refs = program:GetResolvedProjectReferences()
    for _, ref in ipairs(refs or {}) do
        if ref == nil then
            goto continue
        end
        ref:ParseInputOutputNames()
        for outputDtsPath, mapping in pairs(ref:OutputDtsToProjectReference() or {}) do
            -- Only add if not already present (first program wins)
            if result[outputDtsPath] == nil then
                result[outputDtsPath] = mapping.source
            end
        end
        ::continue::
    end
end

-- Go uses a channel-based pool bounded by GOMAXPROCS; sequentially a single checker suffices.
-- Returns getChecker, closePool, getCreatedCount.
function autoimport.createCheckerPool(program)
    local pool = {}
    local created = 0

    return function()
        -- Try to get an existing checker
        if #pool > 0 then
            local ch = table.remove(pool)
            return ch, function() pool[#pool + 1] = ch end
        end
        created = created + 1
        local ch = checker.NewChecker(program, nil)
        return ch, function() pool[#pool + 1] = ch end
    end, function()
        pool = {}
    end, function()
        return created
    end
end

-- addPackageJsonDependencies adds all dependencies and peerDependencies from a package.json
-- to the given set, canonicalizing @types package names to their base names.
function autoimport.addPackageJsonDependencies(contents, deps)
    contents:RangeDependencies(function(name, _, field)
        if name == "" or name == "@types/" or string.byte(name, 1) == 0x2E then
            -- Edge cases that could make us blow up probably
            return true
        end
        if field == "dependencies" or field == "peerDependencies" then
            deps:Add(module.GetPackageNameFromTypesPackageName(name))
        end
        return true
    end)
end

local function cutPrefix(s, prefix)
    if string.sub(s, 1, #prefix) == prefix then
        return string.sub(s, #prefix + 1), true
    end
    return s, false
end

-- getPackageRealpathFuncs returns functions to transform between symlink and realpath for files within a package.
-- It calls FS.Realpath once per package directory and uses prefix substitution for files within that directory,
-- avoiding expensive realpath syscalls for each file. For files outside the package (e.g. re-exported
-- dependencies reached through node_modules symlinks), it resolves the file's directory realpath once,
-- finds the symlink boundary (the package root where the symlink lives), and caches that prefix mapping.
-- All subsequent files under the same symlinked package directory use prefix substitution with no syscalls.
-- Returns toRealpath, toSymlink.
function autoimport.getPackageRealpathFuncs(fs, packageDir)
    local realPackageDir = fs:Realpath(packageDir)
    local isSymlinked = realPackageDir ~= packageDir
    -- Cache of package-directory-level symlink→realpath prefix mappings for
    -- external packages encountered via re-exports. Keyed by the node_modules
    -- package directory (e.g. "/app/node_modules/dep"), so all files under
    -- that package reuse a single realpath lookup.
    local dirCache = {}
    local toRealpath = function(fileName)
        -- Fast path: files within the package use prefix substitution.
        if isSymlinked then
            local after, ok = cutPrefix(fileName, packageDir)
            if ok then
                return realPackageDir .. after
            end
        end
        -- Files outside the package (e.g. re-exports into symlinked deps):
        -- find the node_modules package directory, resolve it once, and cache.
        local pkgDir = module.ParseNodeModuleFromPath(fileName, false --[[isFolder]])
        if pkgDir == "" then
            return fileName
        end
        local realDir = dirCache[pkgDir]
        if realDir ~= nil then
            if realDir == pkgDir then
                return fileName
            end
            return realDir .. string.sub(fileName, #pkgDir + 1)
        end
        realDir = fs:Realpath(pkgDir)
        dirCache[pkgDir] = realDir
        if realDir == pkgDir then
            return fileName
        end
        return realDir .. string.sub(fileName, #pkgDir + 1)
    end
    if not isSymlinked then
        return toRealpath, core.Identity
    end
    -- toSymlink only handles files within the package directory (reversing the
    -- packageDir→realPackageDir substitution). It does not handle arbitrary external
    -- paths; callers should only use it for files known to be within the package.
    local toSymlink = function(fileName)
        local after, ok = cutPrefix(fileName, realPackageDir)
        if ok then
            return packageDir .. after
        end
        return fileName
    end
    return toRealpath, toSymlink
end

local resolutionHost = {}
resolutionHost.__index = resolutionHost
autoimport.resolutionHost = resolutionHost

function resolutionHost:GetCurrentDirectory()
    return self.currentDirectory
end

function resolutionHost:FS()
    return self.fs
end

function autoimport.getModuleResolver(host, realpath, opts)
    local rh = setmetatable({
        fs = wrapvfs.Wrap(host:FS(), { Realpath = realpath }),
        currentDirectory = host:GetCurrentDirectory(),
    }, resolutionHost)
    return module.NewResolverWithOptions(rh, core.EmptyCompilerOptions, "", "", opts)
end
