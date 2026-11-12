local modulespecifiers = require("tslua.modulespecifiers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local module = require("tslua.module")
local outputpaths = require("tslua.outputpaths")
local packagejson = require("tslua.packagejson")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local ResultKind = modulespecifiers.ResultKind
local RelativePreferenceKind = modulespecifiers.RelativePreferenceKind
local ModuleSpecifierEnding = modulespecifiers.ModuleSpecifierEnding
local MatchingMode = modulespecifiers.MatchingMode
local JSONValueType = packagejson.JSONValueType

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

local function contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

local function countSlashes(s)
    local n = 0
    for _ in string.gmatch(s, "/") do
        n = n + 1
    end
    return n
end

-- Go strings.Cut(s, sep) -> before, after, found
local function cut(s, sep)
    local i = string.find(s, sep, 1, true)
    if i == nil then
        return s, "", false
    end
    return string.sub(s, 1, i - 1), string.sub(s, i + #sep), true
end

local function sliceContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

local function newComparePathsOptions(host)
    return tspath.NewComparePathsOptions(host:UseCaseSensitiveFileNames(), host:GetCurrentDirectory())
end

function modulespecifiers.GetModuleSpecifiers(moduleSymbol, checker, compilerOptions, importingSourceFile, host, userPreferences, options, forAutoImports)
    local result = modulespecifiers.GetModuleSpecifiersWithInfo(
        moduleSymbol,
        checker,
        compilerOptions,
        importingSourceFile,
        host,
        userPreferences,
        options,
        forAutoImports
    )
    return result
end

function modulespecifiers.GetModuleSpecifiersWithInfo(moduleSymbol, checker, compilerOptions, importingSourceFile, host, userPreferences, options, forAutoImports)
    local ambient = modulespecifiers.tryGetModuleNameFromAmbientModule(moduleSymbol, checker)
    if #ambient > 0 then
        if forAutoImports and modulespecifiers.IsExcludedByRegex(ambient, userPreferences.autoImportSpecifierExcludeRegexes) then
            return nil, ResultKind.Ambient
        end
        return { ambient }, ResultKind.Ambient
    end

    local moduleSourceFile = ast.GetSourceFileOfModule(moduleSymbol)
    if moduleSourceFile == nil then
        return nil, ResultKind.None
    end

    -- Use original source file name when file is from project reference output
    local moduleFileName = host:GetSourceOfProjectReferenceIfOutputIncluded(moduleSourceFile)

    return modulespecifiers.GetModuleSpecifiersForFileWithInfo(
        importingSourceFile,
        moduleFileName,
        compilerOptions,
        host,
        userPreferences,
        options,
        forAutoImports
    )
end

function modulespecifiers.GetModuleSpecifiersForFileWithInfo(importingSourceFile, moduleFileName, compilerOptions, host, userPreferences, options, forAutoImports)
    local modulePaths = modulespecifiers.getAllModulePathsWorker(
        modulespecifiers.getInfo(host:GetSourceOfProjectReferenceIfOutputIncluded(importingSourceFile), host),
        moduleFileName,
        host,
        compilerOptions,
        options
    )

    return modulespecifiers.computeModuleSpecifiers(
        modulePaths,
        compilerOptions,
        importingSourceFile,
        host,
        userPreferences,
        options,
        forAutoImports
    )
end

function modulespecifiers.tryGetModuleNameFromAmbientModule(moduleSymbol, checker)
    for _, decl in ipairs(moduleSymbol.declarations or {}) do
        if ast.IsModuleWithStringLiteralName(decl) and (not ast.IsModuleAugmentationExternal(decl) or not tspath.IsExternalModuleNameRelative(decl:Name():Text())) then
            return decl:Name():Text()
        end
    end

    -- the module could be a namespace, which is export through "export=" from an ambient module.
    --[[
     * declare module "m" {
     *     namespace ns {
     *         class c {}
     *     }
     *     export = ns;
     * }
    ]]
    -- `import {c} from "m";` is valid, in which case, `moduleSymbol` is "ns", but the module name should be "m"
    for _, d in ipairs(moduleSymbol.declarations or {}) do
        if not ast.IsModuleDeclaration(d) then
            goto continue
        end

        do
            local possibleContainer = ast.FindAncestor(d, ast.IsModuleWithStringLiteralName)
            if possibleContainer == nil or possibleContainer.parent == nil or not ast.IsSourceFile(possibleContainer.parent) then
                goto continue
            end

            local exports = possibleContainer:Symbol().exports
            local sym = exports and exports[ast.InternalSymbolNameExportEquals]
            if sym == nil then
                goto continue
            end
            local exportAssignmentDecl = sym.valueDeclaration
            if exportAssignmentDecl == nil or exportAssignmentDecl.kind ~= ast.Kind.ExportAssignment then
                goto continue
            end
            local exportSymbol = checker:GetSymbolAtLocation(exportAssignmentDecl:Expression())
            if exportSymbol == nil then
                goto continue
            end
            if exportSymbol.flags & ast.SymbolFlags.Alias ~= 0 then
                exportSymbol = checker:GetAliasedSymbol(exportSymbol)
            end
            -- TODO: Possible strada bug - isn't this insufficient in the presence of merge symbols?
            if exportSymbol == d:Symbol() then
                return possibleContainer:Name():Text()
            end
        end
        ::continue::
    end
    return ""
end

-- Info: { useCaseSensitiveFileNames, importingSourceFileName, sourceDirectory }

function modulespecifiers.getInfo(importingSourceFileName, host)
    local sourceDirectory = tspath.GetDirectoryPath(importingSourceFileName)
    return {
        importingSourceFileName = importingSourceFileName,
        sourceDirectory = sourceDirectory,
        useCaseSensitiveFileNames = host:UseCaseSensitiveFileNames(),
    }
end

function modulespecifiers.getAllModulePaths(info, importedFileName, host, compilerOptions, preferences, options)
    -- !!! use new cache model
    -- importingFilePath := tspath.ToPath(info.ImportingSourceFileName, host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
    -- importedFilePath := tspath.ToPath(importedFileName, host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
    -- cache := host.getModuleSpecifierCache();
    -- if (cache != nil) {
    --     cached := cache.get(importingFilePath, importedFilePath, preferences, options);
    --     if (cached.modulePaths) {return cached.modulePaths;}
    -- }
    local modulePaths = modulespecifiers.getAllModulePathsWorker(info, importedFileName, host, compilerOptions, options)
    -- if (cache != nil) {
    --     cache.setModulePaths(importingFilePath, importedFilePath, preferences, options, modulePaths);
    -- }
    return modulePaths
end

function modulespecifiers.getAllModulePathsWorker(info, importedFileName, host, compilerOptions, options)
    local allFileNames = {}
    local allFileNamesCount = 0
    local paths = modulespecifiers.GetEachFileNameOfModule(info.importingSourceFileName, importedFileName, host, true)
    for _, p in ipairs(paths) do
        if allFileNames[p.fileName] == nil then
            allFileNamesCount = allFileNamesCount + 1
        end
        allFileNames[p.fileName] = p
    end

    local useCaseSensitiveFileNames = info.useCaseSensitiveFileNames
    local comparePaths = function(a, b)
        return modulespecifiers.comparePathsByRedirect(a, b, useCaseSensitiveFileNames)
    end

    -- Sort by paths closest to importing file Name directory
    local sortedPaths = {}
    local directory = info.sourceDirectory
    while allFileNamesCount ~= 0 do
        local directoryStart = tspath.EnsureTrailingDirectorySeparator(directory)
        local pathsInDirectory
        local toDelete = {}
        for fileName, p in pairs(allFileNames) do
            if hasPrefix(fileName, directoryStart) then
                pathsInDirectory = core.Append(pathsInDirectory, p)
                toDelete[#toDelete + 1] = fileName
            end
        end
        for _, fileName in ipairs(toDelete) do
            allFileNames[fileName] = nil
            allFileNamesCount = allFileNamesCount - 1
        end
        if core.Len(pathsInDirectory) > 0 then
            core.SortFunc(pathsInDirectory, comparePaths)
            core.AppendAll(sortedPaths, pathsInDirectory)
        end
        local newDirectory = tspath.GetDirectoryPath(directory)
        if newDirectory == directory then
            break
        end
        directory = newDirectory
    end
    if allFileNamesCount > 0 then
        local remainingPaths = {}
        for _, p in pairs(allFileNames) do
            remainingPaths[#remainingPaths + 1] = p
        end
        core.SortFunc(remainingPaths, comparePaths)
        core.AppendAll(sortedPaths, remainingPaths)
    end
    return sortedPaths
end

-- containsIgnoredPath checks if a path contains patterns that should be ignored.
-- This is a local helper that duplicates tspath.ContainsIgnoredPath for performance.
function modulespecifiers.containsIgnoredPath(s)
    return contains(s, "/node_modules/.") or
        contains(s, "/.git") or
        contains(s, ".#")
end

-- ContainsNodeModules checks if a path contains the node_modules directory.
function modulespecifiers.ContainsNodeModules(s)
    return contains(s, "/node_modules/")
end

-- GetEachFileNameOfModule returns all possible file paths for a module, including symlink alternatives.
-- This function handles symlink resolution and provides multiple path options for module resolution.
function modulespecifiers.GetEachFileNameOfModule(importingFileName, importedFileName, host, preferSymlinks)
    local cwd = host:GetCurrentDirectory()
    local importedPath = tspath.ToPath(importedFileName, cwd, host:UseCaseSensitiveFileNames())
    local referenceRedirect = ""
    local outputAndReference = host:GetProjectReferenceFromSource(importedPath)
    if outputAndReference ~= nil and outputAndReference.outputDts ~= "" then
        referenceRedirect = outputAndReference.outputDts
    end

    local redirects = host:GetRedirectTargets(importedPath)
    local importedFileNames = {}
    if #referenceRedirect > 0 then
        importedFileNames[#importedFileNames + 1] = referenceRedirect
    end
    importedFileNames[#importedFileNames + 1] = importedFileName
    core.AppendAll(importedFileNames, redirects)
    local targets = core.Map(importedFileNames, function(f) return tspath.GetNormalizedAbsolutePath(f, cwd) end)
    local shouldFilterIgnoredPaths = not core.Every(targets, modulespecifiers.containsIgnoredPath)

    local results = {}
    if not preferSymlinks then
        for _, p in ipairs(targets) do
            if not (shouldFilterIgnoredPaths and modulespecifiers.containsIgnoredPath(p)) then
                results[#results + 1] = modulespecifiers.NewModulePath(
                    p,
                    modulespecifiers.ContainsNodeModules(p),
                    referenceRedirect == p
                )
            end
        end
    end

    local symlinkCache = host:GetSymlinkCache()
    local fullImportedFileName = tspath.GetNormalizedAbsolutePath(importedFileName, cwd)
    if symlinkCache ~= nil then
        tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(
            host:GetGlobalTypingsCacheLocation(),
            tspath.GetDirectoryPath(fullImportedFileName),
            function(realPathDirectory)
                local symlinkSet, ok = symlinkCache:DirectoriesByRealpath():Load(tspath.Path_EnsureTrailingDirectorySeparator(tspath.ToPath(realPathDirectory, cwd, host:UseCaseSensitiveFileNames())))
                if not ok then
                    return false, false
                end -- Continue to ancestor directory

                -- Don't want to a package to globally import from itself (importNameCodeFix_symlink_own_package.ts)
                if tspath.StartsWithDirectory(importingFileName, realPathDirectory, host:UseCaseSensitiveFileNames()) then
                    return false, true -- Stop search, each ancestor directory will also hit this condition
                end

                for _, target in ipairs(targets) do
                    if not tspath.StartsWithDirectory(target, realPathDirectory, host:UseCaseSensitiveFileNames()) then
                        goto continue
                    end

                    do
                        local relative = tspath.GetRelativePathFromDirectory(
                            realPathDirectory,
                            target,
                            tspath.NewComparePathsOptions(host:UseCaseSensitiveFileNames(), cwd)
                        )
                        symlinkSet:Range(function(symlinkDirectory)
                            local option = tspath.ResolvePath(symlinkDirectory, relative)
                            results[#results + 1] = modulespecifiers.NewModulePath(
                                option,
                                modulespecifiers.ContainsNodeModules(option),
                                target == referenceRedirect
                            )
                            shouldFilterIgnoredPaths = true -- We found a non-ignored path in symlinks, so we can reject ignored-path realpaths
                            return true
                        end)
                    end
                    ::continue::
                end

                return false, false
            end
        )
    end

    if preferSymlinks then
        for _, p in ipairs(targets) do
            if not (shouldFilterIgnoredPaths and modulespecifiers.containsIgnoredPath(p)) then
                results[#results + 1] = modulespecifiers.NewModulePath(
                    p,
                    modulespecifiers.ContainsNodeModules(p),
                    referenceRedirect == p
                )
            end
        end
    end

    return results
end

function modulespecifiers.computeModuleSpecifiers(modulePaths, compilerOptions, importingSourceFile, host, userPreferences, options, forAutoImport)
    local info = modulespecifiers.getInfo(importingSourceFile:FileName(), host)
    local preferences = modulespecifiers.getModuleSpecifierPreferences(userPreferences, host, compilerOptions, importingSourceFile, "")

    local existingSpecifier = ""
    for _, modulePath in ipairs(modulePaths or {}) do
        local targetPath = tspath.ToPath(modulePath.fileName, host:GetCurrentDirectory(), info.useCaseSensitiveFileNames)
        local existingImport
        for _, importSpecifier in ipairs(importingSourceFile:Imports() or {}) do
            local resolvedModule = host:GetResolvedModuleFromModuleSpecifier(importingSourceFile, importSpecifier)
            if module.ResolvedModule.IsResolved(resolvedModule) and tspath.ToPath(resolvedModule.resolvedFileName, host:GetCurrentDirectory(), info.useCaseSensitiveFileNames) == targetPath then
                existingImport = importSpecifier
                break
            end
        end
        if existingImport ~= nil then
            if preferences.relativePreference == RelativePreferenceKind.RelativePreferenceNonRelative and tspath.PathIsRelative(existingImport:Text()) then
                -- If the preference is for non-relative and the module specifier is relative, ignore it
                goto continue
            end
            local existingMode = host:GetModeForUsageLocation(importingSourceFile, existingImport)
            local targetMode = options.overrideImportMode
            if targetMode == ModuleKind.ResolutionModeNone then
                targetMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
            end
            if existingMode ~= targetMode and existingMode ~= ModuleKind.ResolutionModeNone and targetMode ~= ModuleKind.ResolutionModeNone then
                -- If the candidate import mode doesn't match the mode we're generating for, don't consider it
                goto continue
            end
            existingSpecifier = existingImport:Text()
            break
        end
        ::continue::
    end

    if existingSpecifier ~= "" then
        return { existingSpecifier }, ResultKind.None
    end

    local importedFileIsInNodeModules = core.Some(modulePaths, function(p) return p.isInNodeModules end)

    -- Module specifier priority:
    --   1. "Bare package specifiers" (e.g. "@foo/bar") resulting from a path through node_modules to a package.json's "types" entry
    --   2. Specifiers generated using "paths" from tsconfig
    --   3. Non-relative specfiers resulting from a path through node_modules (e.g. "@foo/bar/path/to/file")
    --   4. Relative paths
    local pathsSpecifiers
    local redirectPathsSpecifiers
    local nodeModulesSpecifiers
    local relativeSpecifiers

    for _, modulePath in ipairs(modulePaths or {}) do
        local specifier = ""
        if modulePath.isInNodeModules then
            specifier = modulespecifiers.tryGetModuleNameAsNodeModule(modulePath, info, importingSourceFile, host, compilerOptions, userPreferences --[[packageNameOnly]], false, options.overrideImportMode)
        end
        if #specifier > 0 and not (forAutoImport and modulespecifiers.IsExcludedByRegex(specifier, preferences.excludeRegexes)) then
            nodeModulesSpecifiers = core.Append(nodeModulesSpecifiers, specifier)
            if modulePath.isRedirect then
                -- If we got a specifier for a redirect, it was a bare package specifier (e.g. "@foo/bar",
                -- not "@foo/bar/path/to/file"). No other specifier will be this good, so stop looking.
                return nodeModulesSpecifiers, ResultKind.NodeModules
            end
        end

        local importMode = options.overrideImportMode
        if importMode == ModuleKind.ResolutionModeNone then
            importMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
        end
        local localSpecifier = modulespecifiers.getLocalModuleSpecifier(
            modulePath.fileName,
            info,
            compilerOptions,
            host,
            importMode,
            preferences,
            --[[pathsOnly]] modulePath.isRedirect or #specifier > 0
        )
        if #localSpecifier == 0 or forAutoImport and modulespecifiers.IsExcludedByRegex(localSpecifier, preferences.excludeRegexes) then
            goto continue
        end
        if modulePath.isRedirect then
            redirectPathsSpecifiers = core.Append(redirectPathsSpecifiers, localSpecifier)
        elseif modulespecifiers.PathIsBareSpecifier(localSpecifier) then
            if modulespecifiers.ContainsNodeModules(localSpecifier) then
                -- We could be in this branch due to inappropriate use of `baseUrl`, not intentional `paths`
                -- usage. It's impossible to reason about where to prioritize baseUrl-generated module
                -- specifiers, but if they contain `/node_modules/`, they're going to trigger a portability
                -- error, so *at least* don't prioritize those.
                relativeSpecifiers = core.Append(relativeSpecifiers, localSpecifier)
            else
                pathsSpecifiers = core.Append(pathsSpecifiers, localSpecifier)
            end
        elseif forAutoImport or not importedFileIsInNodeModules or modulePath.isInNodeModules then
            -- Why this extra conditional, not just an `else`? If some path to the file contained
            -- 'node_modules', but we can't create a non-relative specifier (e.g. "@foo/bar/path/to/file"),
            -- that means we had to go through a *sibling's* node_modules, not one we can access directly.
            -- If some path to the file was in node_modules but another was not, this likely indicates that
            -- we have a monorepo structure with symlinks. In this case, the non-nodeModules path is
            -- probably the realpath, e.g. "../bar/path/to/file", but a relative path to another package
            -- in a monorepo is probably not portable. So, the module specifier we actually go with will be
            -- the relative path through node_modules, so that the declaration emitter can produce a
            -- portability error. (See declarationEmitReexportedSymlinkReference3)
            relativeSpecifiers = core.Append(relativeSpecifiers, localSpecifier)
        end
        ::continue::
    end

    if core.Len(pathsSpecifiers) > 0 then
        return pathsSpecifiers, ResultKind.Paths
    end
    if core.Len(redirectPathsSpecifiers) > 0 then
        return redirectPathsSpecifiers, ResultKind.Redirect
    end
    if core.Len(nodeModulesSpecifiers) > 0 then
        return nodeModulesSpecifiers, ResultKind.NodeModules
    end
    return relativeSpecifiers, ResultKind.Relative
end

function modulespecifiers.getLocalModuleSpecifier(moduleFileName, info, compilerOptions, host, importMode, preferences, pathsOnly)
    local paths = compilerOptions.paths
    local rootDirs = compilerOptions.rootDirs

    if pathsOnly and paths == nil then
        return ""
    end

    local sourceDirectory = info.sourceDirectory

    local allowedEndings = preferences.getAllowedEndingsInPreferredOrder(importMode)
    local relativePath = ""
    if core.Len(rootDirs) > 0 then
        relativePath = modulespecifiers.tryGetModuleNameFromRootDirs(rootDirs, moduleFileName, sourceDirectory, allowedEndings, compilerOptions, host)
    end
    if #relativePath == 0 then
        relativePath = modulespecifiers.processEnding(modulespecifiers.ensurePathIsNonModuleName(tspath.GetRelativePathFromDirectory(sourceDirectory, moduleFileName, newComparePathsOptions(host))), allowedEndings, compilerOptions, host)
    end

    if (paths == nil and not compilerOptions:GetResolvePackageJsonImports()) or preferences.relativePreference == RelativePreferenceKind.RelativePreferenceRelative then
        if pathsOnly then
            return ""
        end
        return relativePath
    end

    local root = compilerOptions:GetPathsBasePath(host:GetCurrentDirectory())
    local baseDirectory = tspath.GetNormalizedAbsolutePath(root, host:GetCurrentDirectory())
    local relativeToBaseUrl = modulespecifiers.getRelativePathIfInSameVolume(moduleFileName, baseDirectory, host:UseCaseSensitiveFileNames())
    if #relativeToBaseUrl == 0 then
        if pathsOnly then
            return ""
        end
        return relativePath
    end

    local fromPackageJsonImports = ""
    if not pathsOnly then
        fromPackageJsonImports = modulespecifiers.tryGetModuleNameFromPackageJsonImports(
            moduleFileName,
            sourceDirectory,
            compilerOptions,
            host,
            importMode,
            modulespecifiers.prefersTsExtension(allowedEndings)
        )
    end

    local fromPaths = ""
    if (pathsOnly or #fromPackageJsonImports == 0) and paths ~= nil then
        fromPaths = modulespecifiers.tryGetModuleNameFromPaths(
            relativeToBaseUrl,
            paths,
            allowedEndings,
            baseDirectory,
            host,
            compilerOptions
        )
    end

    if pathsOnly then
        return fromPaths
    end

    local maybeNonRelative
    if #fromPackageJsonImports > 0 then
        maybeNonRelative = fromPackageJsonImports
    else
        maybeNonRelative = fromPaths
    end
    if #maybeNonRelative == 0 then
        return relativePath
    end

    local relativeIsExcluded = modulespecifiers.IsExcludedByRegex(relativePath, preferences.excludeRegexes)
    local nonRelativeIsExcluded = modulespecifiers.IsExcludedByRegex(maybeNonRelative, preferences.excludeRegexes)
    if not relativeIsExcluded and nonRelativeIsExcluded then
        return relativePath
    end
    if relativeIsExcluded and not nonRelativeIsExcluded then
        return maybeNonRelative
    end

    if preferences.relativePreference == RelativePreferenceKind.RelativePreferenceNonRelative and not tspath.PathIsRelative(maybeNonRelative) then
        return maybeNonRelative
    end

    if preferences.relativePreference == RelativePreferenceKind.RelativePreferenceExternalNonRelative and not tspath.PathIsRelative(maybeNonRelative) then
        local projectDirectory
        if #compilerOptions.configFilePath > 0 then
            projectDirectory = tspath.ToPath(tspath.GetDirectoryPath(compilerOptions.configFilePath), host:GetCurrentDirectory(), host:UseCaseSensitiveFileNames())
        else
            projectDirectory = tspath.ToPath(host:GetCurrentDirectory(), host:GetCurrentDirectory(), host:UseCaseSensitiveFileNames())
        end
        local canonicalSourceDirectory = tspath.ToPath(sourceDirectory, host:GetCurrentDirectory(), host:UseCaseSensitiveFileNames())
        local modulePath = tspath.ToPath(moduleFileName, projectDirectory, host:UseCaseSensitiveFileNames())

        local sourceIsInternal = tspath.Path_ContainsPath(projectDirectory, canonicalSourceDirectory)
        local targetIsInternal = tspath.Path_ContainsPath(projectDirectory, modulePath)
        if sourceIsInternal and not targetIsInternal or not sourceIsInternal and targetIsInternal then
            -- 1. The import path crosses the boundary of the tsconfig.json-containing directory.
            --
            --      src/
            --        tsconfig.json
            --        index.ts -------
            --      lib/              | (path crosses tsconfig.json)
            --        imported.ts <---
            --
            return maybeNonRelative
        end

        local nearestTargetPackageJson = host:GetNearestAncestorDirectoryWithPackageJson(tspath.GetDirectoryPath(modulePath))
        local nearestSourcePackageJson = host:GetNearestAncestorDirectoryWithPackageJson(sourceDirectory)

        if not modulespecifiers.packageJsonPathsAreEqual(nearestTargetPackageJson, nearestSourcePackageJson, newComparePathsOptions(host)) then
            -- 2. The importing and imported files are part of different packages.
            --
            --      packages/a/
            --        package.json
            --        index.ts --------
            --      packages/b/        | (path crosses package.json)
            --        package.json     |
            --        component.ts <---
            --
            return maybeNonRelative
        end

        return relativePath
    end

    -- Prefer a relative import over a baseUrl import if it has fewer components.
    if modulespecifiers.isPathRelativeToParent(maybeNonRelative) or modulespecifiers.CountPathComponents(relativePath) < modulespecifiers.CountPathComponents(maybeNonRelative) then
        return relativePath
    end
    return maybeNonRelative
end

function modulespecifiers.processEnding(fileName, allowedEndings, options, host)
    if tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionJson, tspath.ExtensionMjs, tspath.ExtensionCjs }) then
        return fileName
    end

    local noExtension = tspath.RemoveFileExtension(fileName)
    if fileName == noExtension then
        return fileName
    end

    local jsPriority = modulespecifiers.sliceIndex(allowedEndings, ModuleSpecifierEnding.JsExtension)
    local tsPriority = modulespecifiers.sliceIndex(allowedEndings, ModuleSpecifierEnding.TsExtension)
    if tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionMts, tspath.ExtensionCts }) and tsPriority ~= -1 and tsPriority < jsPriority then
        return fileName
    end
    if tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionDmts, tspath.ExtensionDcts }) then
        local inputExt = tspath.GetDeclarationFileExtension(fileName)
        local ext = modulespecifiers.GetJSExtensionForDeclarationFileExtension(inputExt)
        return tspath.RemoveExtension(fileName, inputExt) .. ext
    end
    if tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionMts, tspath.ExtensionCts }) then
        return noExtension .. modulespecifiers.getJSExtensionForFile(fileName, options)
    end
    if not tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionDts }) and tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionTs }) and contains(fileName, ".d.") then
        -- `foo.d.json.ts` and the like - remap back to `foo.json`
        local result = modulespecifiers.TryGetRealFileNameForNonJSDeclarationFileName(fileName)
        if result ~= "" then
            return result
        end
    end

    local first = allowedEndings[1]
    if first == ModuleSpecifierEnding.Minimal then
        local withoutIndex = noExtension
        if hasSuffix(noExtension, "/index") then
            withoutIndex = string.sub(noExtension, 1, #noExtension - #"/index")
        end
        if host ~= nil and withoutIndex ~= noExtension and modulespecifiers.tryGetAnyFileFromPath(host, withoutIndex) then
            -- Can't remove index if there's a file by the same name as the directory.
            -- Probably more callers should pass `host` so we can determine this?
            return noExtension
        end
        return withoutIndex
    elseif first == ModuleSpecifierEnding.Index then
        return noExtension
    elseif first == ModuleSpecifierEnding.JsExtension then
        return noExtension .. modulespecifiers.getJSExtensionForFile(fileName, options)
    elseif first == ModuleSpecifierEnding.TsExtension then
        -- For now, we don't know if this import is going to be type-only, which means we don't
        -- know if a .d.ts extension is valid, so use no extension or a .js extension
        if tspath.IsDeclarationFileName(fileName) then
            local extensionlessPriority = -1
            for i, e in ipairs(allowedEndings) do
                if e == ModuleSpecifierEnding.Minimal or e == ModuleSpecifierEnding.Index then
                    extensionlessPriority = i - 1
                    break
                end
            end
            if extensionlessPriority ~= -1 and extensionlessPriority < jsPriority then
                return noExtension
            end
            return noExtension .. modulespecifiers.getJSExtensionForFile(fileName, options)
        end
        return fileName
    else
        debug.AssertNever(first)
        return ""
    end
end

function modulespecifiers.tryGetModuleNameFromRootDirs(rootDirs, moduleFileName, sourceDirectory, allowedEndings, compilerOptions, host)
    local normalizedTargetPaths = modulespecifiers.getPathsRelativeToRootDirs(moduleFileName, rootDirs, host:UseCaseSensitiveFileNames())
    if core.Len(normalizedTargetPaths) == 0 then
        return ""
    end

    local normalizedSourcePaths = modulespecifiers.getPathsRelativeToRootDirs(sourceDirectory, rootDirs, host:UseCaseSensitiveFileNames())
    local shortest = ""
    local shortestSepCount = 0
    for _, sourcePath in ipairs(normalizedSourcePaths or {}) do
        for _, targetPath in ipairs(normalizedTargetPaths) do
            local candidate = modulespecifiers.ensurePathIsNonModuleName(tspath.GetRelativePathFromDirectory(sourcePath, targetPath, newComparePathsOptions(host)))
            local candidateSepCount = countSlashes(candidate)
            if #shortest == 0 or candidateSepCount < shortestSepCount then
                shortest = candidate
                shortestSepCount = candidateSepCount
            end
        end
    end

    if #shortest == 0 then
        return ""
    end
    return modulespecifiers.processEnding(shortest, allowedEndings, compilerOptions, host)
end

function modulespecifiers.tryGetModuleNameAsNodeModule(pathObj, info, importingSourceFile, host, options, userPreferences, packageNameOnly, overrideMode)
    local parts = modulespecifiers.GetNodeModulePathParts(pathObj.fileName)
    if parts == nil then
        return ""
    end

    -- Simplify the full file path to something that can be resolved by Node.
    local preferences = modulespecifiers.getModuleSpecifierPreferences(userPreferences, host, options, importingSourceFile, "")
    local allowedEndings = preferences.getAllowedEndingsInPreferredOrder(ModuleKind.ResolutionModeNone)

    local caseSensitive = host:UseCaseSensitiveFileNames()
    local moduleSpecifier = pathObj.fileName
    local isPackageRootPath = false
    if not packageNameOnly then
        local packageRootIndex = parts.packageRootIndex
        local moduleFileName = ""
        while true do
            -- If the module could be imported by a directory name, use that directory's name
            local pkgJsonResults = modulespecifiers.tryDirectoryWithPackageJson(
                parts,
                pathObj,
                importingSourceFile,
                host,
                overrideMode,
                options,
                allowedEndings
            )
            local moduleFileToTry = pkgJsonResults.moduleFileToTry
            local packageRootPath = pkgJsonResults.packageRootPath
            local blockedByExports = pkgJsonResults.blockedByExports
            local verbatimFromExports = pkgJsonResults.verbatimFromExports
            if blockedByExports then
                return "" -- File is under this package.json, but is not publicly exported - there's no way to name it via `node_modules` resolution
            end
            if verbatimFromExports then
                return moduleFileToTry
            end
            --}
            if #packageRootPath > 0 then
                moduleSpecifier = packageRootPath
                isPackageRootPath = true
                break
            end
            if #moduleFileName == 0 then
                moduleFileName = moduleFileToTry
            end
            -- try with next level of directory
            packageRootIndex = core.IndexAfter(pathObj.fileName, "/", packageRootIndex + 1)
            if packageRootIndex == -1 then
                moduleSpecifier = modulespecifiers.processEnding(moduleFileName, allowedEndings, options, host)
                break
            end
        end
    end

    if pathObj.isRedirect and not isPackageRootPath then
        return ""
    end

    local globalTypingsCacheLocation = host:GetGlobalTypingsCacheLocation()
    -- Get a path that's relative to node_modules or the importing file's path
    -- if node_modules folder is in this folder or any of its parent folders, no need to keep it.
    local pathToTopLevelNodeModules = string.sub(moduleSpecifier, 1, parts.topLevelNodeModulesIndex)

    if not stringutil.HasPrefix(info.sourceDirectory, pathToTopLevelNodeModules, caseSensitive) or #globalTypingsCacheLocation > 0 and stringutil.HasPrefix(globalTypingsCacheLocation, pathToTopLevelNodeModules, caseSensitive) then
        return ""
    end

    -- If the module was found in @types, get the actual Node package name
    local nodeModulesDirectoryName = string.sub(moduleSpecifier, parts.topLevelPackageNameIndex + 2)
    return module.GetPackageNameFromTypesPackageName(nodeModulesDirectoryName)
end

-- pkgJsonDirAttemptResult: { moduleFileToTry, packageRootPath, blockedByExports, verbatimFromExports }
local function pkgJsonDirAttemptResult(init)
    return {
        moduleFileToTry = init.moduleFileToTry or "",
        packageRootPath = init.packageRootPath or "",
        blockedByExports = init.blockedByExports or false,
        verbatimFromExports = init.verbatimFromExports or false,
    }
end

function modulespecifiers.tryDirectoryWithPackageJson(parts, pathObj, importingSourceFile, host, overrideMode, options, allowedEndings)
    local rootIdx = parts.packageRootIndex
    if rootIdx == -1 then
        rootIdx = #pathObj.fileName -- TODO: possible strada bug? -1 in js slice removes characters from the end, in go it panics - js behavior seems unwanted here?
    end
    local packageRootPath = string.sub(pathObj.fileName, 1, rootIdx)
    local packageJsonPath = tspath.CombinePaths(packageRootPath, "package.json")
    local moduleFileToTry = pathObj.fileName
    local maybeBlockedByTypesVersions = false
    local packageJson = host:GetPackageJsonInfo(packageJsonPath)
    if packageJson == nil then
        -- No package.json exists; an index.js will still resolve as the package name
        local fileName = string.sub(moduleFileToTry, parts.packageRootIndex + 2)
        if fileName == "index.d.ts" or fileName == "index.js" or fileName == "index.ts" or fileName == "index.tsx" then
            return pkgJsonDirAttemptResult({ moduleFileToTry = moduleFileToTry, packageRootPath = packageRootPath })
        else
            return pkgJsonDirAttemptResult({ moduleFileToTry = moduleFileToTry })
        end
    end

    local importMode = overrideMode
    if importMode == ModuleKind.ResolutionModeNone then
        importMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
    end

    local packageJsonContent = packageJson:GetContents()
    if options:GetResolvePackageJsonExports() then
        -- The package name that we found in node_modules could be different from the package
        -- name in the package.json content via url/filepath dependency specifiers. We need to
        -- use the actual directory name, so don't look at `packageJsonContent.name` here.
        local nodeModulesDirectoryName = string.sub(packageRootPath, parts.topLevelPackageNameIndex + 2)
        local packageName = module.GetPackageNameFromTypesPackageName(nodeModulesDirectoryName)

        -- Determine resolution mode for package.json exports condition matching.
        -- TypeScript's tryDirectoryWithPackageJson uses the importing file's mode (moduleSpecifiers.ts:1257),
        -- but this causes incorrect exports resolution. We fix this by checking the target file's extension
        -- using the logic from getImpliedNodeFormatForEmitWorker (program.ts:4827-4838).
        -- .cjs/.cts/.d.cts → CommonJS → "require" condition
        -- .mjs/.mts/.d.mts → ESM → "import" condition
        if tspath.FileExtensionIsOneOf(pathObj.fileName, { tspath.ExtensionCjs, tspath.ExtensionCts, tspath.ExtensionDcts }) then
            importMode = ModuleKind.ResolutionModeCommonJS
        elseif tspath.FileExtensionIsOneOf(pathObj.fileName, { tspath.ExtensionMjs, tspath.ExtensionMts, tspath.ExtensionDmts }) then
            importMode = ModuleKind.ResolutionModeESM
        end

        local conditions = module.GetConditions(options, importMode)

        local fromExports = ""
        if packageJsonContent ~= nil and packageJsonContent.exports.type ~= JSONValueType.NotPresent then
            fromExports = modulespecifiers.tryGetModuleNameFromExports(
                options,
                host,
                pathObj.fileName,
                packageRootPath,
                packageName,
                packageJsonContent.exports,
                conditions
            )
        end
        if #fromExports > 0 then
            return pkgJsonDirAttemptResult({
                moduleFileToTry = fromExports,
                verbatimFromExports = true,
            })
        end
        if packageJsonContent ~= nil and packageJsonContent.exports.type ~= JSONValueType.NotPresent then
            return pkgJsonDirAttemptResult({
                moduleFileToTry = pathObj.fileName,
                blockedByExports = true,
            })
        end
    end

    local versionPaths = packagejson.newVersionPaths()
    if packageJsonContent ~= nil and packageJsonContent.typesVersions.type == JSONValueType.Object then
        versionPaths = packageJsonContent:GetVersionPaths(nil)
    end
    if versionPaths:GetPaths() ~= nil then
        local subModuleName = string.sub(pathObj.fileName, #packageRootPath + 2)
        local fromPaths = modulespecifiers.tryGetModuleNameFromPaths(
            subModuleName,
            versionPaths:GetPaths(),
            allowedEndings,
            packageRootPath,
            host,
            options
        )
        if #fromPaths == 0 then
            maybeBlockedByTypesVersions = true
        else
            moduleFileToTry = tspath.CombinePaths(packageRootPath, fromPaths)
        end
    end
    -- If the file is the main module, it can be imported by the package name
    local mainFileRelative = "index.js"
    if packageJsonContent ~= nil then
        if packageJsonContent.typings.valid then
            mainFileRelative = packageJsonContent.typings.value
        elseif packageJsonContent.types.valid then
            mainFileRelative = packageJsonContent.types.value
        elseif packageJsonContent.main.valid then
            mainFileRelative = packageJsonContent.main.value
        end
    end

    local blockedMain = false
    if maybeBlockedByTypesVersions then
        local p = module.MatchPatternOrExact(module.TryParsePatterns(versionPaths:GetPaths()), mainFileRelative)
        blockedMain = p.text ~= "" or p.starIndex ~= 0
    end
    if #mainFileRelative > 0 and not blockedMain then
        -- The 'main' file is also subject to mapping through typesVersions, and we couldn't come up with a path
        -- explicitly through typesVersions, so if it matches a key in typesVersions now, it's not reachable.
        -- (The only way this can happen is if some file in a package that's not resolvable from outside the
        -- package got pulled into the program anyway, e.g. transitively through a file that *is* reachable. It
        -- happens very easily in fourslash tests though, since every test file listed gets included. See
        -- importNameCodeFix_typesVersions.ts for an example.)
        local mainExportFile = tspath.ToPath(mainFileRelative, packageRootPath, host:UseCaseSensitiveFileNames())
        local compareOpt = newComparePathsOptions(host)
        if tspath.ComparePaths(tspath.RemoveFileExtension(mainExportFile), tspath.RemoveFileExtension(moduleFileToTry), compareOpt) == 0 then
            -- ^ An arbitrary removal of file extension for this comparison is almost certainly wrong
            return pkgJsonDirAttemptResult({ packageRootPath = packageRootPath, moduleFileToTry = moduleFileToTry })
        elseif packageJsonContent == nil or packageJsonContent.type.value ~= "module" and
            not tspath.FileExtensionIsOneOf(moduleFileToTry, tspath.ExtensionsNotSupportingExtensionlessResolution) and
            stringutil.HasPrefix(moduleFileToTry, mainExportFile, host:UseCaseSensitiveFileNames()) and
            tspath.ComparePaths(tspath.GetDirectoryPath(moduleFileToTry), tspath.RemoveTrailingDirectorySeparator(mainExportFile), compareOpt) == 0 and
            tspath.RemoveFileExtension(tspath.GetBaseFileName(moduleFileToTry)) == "index" then
            -- if mainExportFile is a directory, which contains moduleFileToTry, we just try index file
            -- example mainExportFile: `pkg/lib` and moduleFileToTry: `pkg/lib/index`, we can use packageRootPath
            -- but this behavior is deprecated for packages with "type": "module", so we only do this for packages without "type": "module"
            -- and make sure that the extension on index.{???} is something that supports omitting the extension
            return pkgJsonDirAttemptResult({ packageRootPath = packageRootPath, moduleFileToTry = moduleFileToTry })
        end
    end

    return pkgJsonDirAttemptResult({ moduleFileToTry = moduleFileToTry })
end

function modulespecifiers.tryGetModuleNameFromExports(options, host, targetFilePath, packageDirectory, packageName, exports, conditions)
    if exports:IsSubpaths() then
        -- sub-mappings
        -- 3 cases:
        -- * directory mappings (legacyish, key ends with / (technically allows index/extension resolution under cjs mode))
        -- * pattern mappings (contains a *)
        -- * exact mappings (no *, does not end with /)
        for k, subk in exports:AsObject():Entries() do
            local subPackageName = tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(packageName, k), "")
            local mode = MatchingMode.Exact
            if hasSuffix(k, "/") then
                mode = MatchingMode.Directory
            elseif contains(k, "*") then
                mode = MatchingMode.Pattern
            end
            local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, subPackageName, subk, conditions, mode --[[isImports]], false --[[preferTsExtension]], false)
            if #result > 0 then
                return result
            end
        end
    end
    return modulespecifiers.tryGetModuleNameFromExportsOrImports(
        options,
        host,
        targetFilePath,
        packageDirectory,
        packageName,
        exports,
        conditions,
        MatchingMode.Exact,
        --[[isImports]] false,
        --[[preferTsExtension]] false
    )
end

function modulespecifiers.tryGetModuleNameFromPackageJsonImports(moduleFileName, sourceDirectory, options, host, importMode, preferTsExtension)
    if not options:GetResolvePackageJsonImports() then
        return ""
    end

    local ancestorDirectoryWithPackageJson = host:GetNearestAncestorDirectoryWithPackageJson(sourceDirectory)
    if #ancestorDirectoryWithPackageJson == 0 then
        return ""
    end
    local packageJsonPath = tspath.CombinePaths(ancestorDirectoryWithPackageJson, "package.json")

    local info = host:GetPackageJsonInfo(packageJsonPath)
    if info == nil then
        return ""
    end

    local imports = info:GetContents().imports
    local t = imports.type
    if t == JSONValueType.NotPresent or t == JSONValueType.Array or t == JSONValueType.String then
        return "" -- not present or invalid for imports
    elseif t == JSONValueType.Object then
        local conditions = module.GetConditions(options, importMode)
        local top = imports:AsObject()
        for k, value in top:Entries() do
            if k == "#" or k == "#/" or not hasPrefix(k, "#") then
                goto continue -- invalid imports entry
            end
            if hasPrefix(k, "#/") and options:GetModuleResolutionKind() ~= ModuleResolutionKind.NodeNext and options:GetModuleResolutionKind() ~= ModuleResolutionKind.Bundler then
                goto continue -- "#/" imports keys are only valid in nodenext/bundler
            end
            do
                local mode = MatchingMode.Exact
                if hasSuffix(k, "/") then
                    mode = MatchingMode.Directory
                elseif contains(k, "*") then
                    mode = MatchingMode.Pattern
                end
                local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(
                    options,
                    host,
                    moduleFileName,
                    ancestorDirectoryWithPackageJson,
                    k,
                    value,
                    conditions,
                    mode,
                    true,
                    preferTsExtension
                )
                if #result > 0 then
                    return result
                end
            end
            ::continue::
        end
    end

    return ""
end

-- specPair: { ending, value }

function modulespecifiers.tryGetModuleNameFromPaths(relativeToBaseUrl, paths, allowedEndings, baseDirectory, host, compilerOptions)
    local caseSensitive = host:UseCaseSensitiveFileNames()
    for key, values in paths:Entries() do
        for _, patternText in ipairs(values or {}) do
            local normalized = tspath.NormalizePath(patternText)
            local pattern = modulespecifiers.getRelativePathIfInSameVolume(normalized, baseDirectory, caseSensitive)
            if #pattern == 0 then
                pattern = normalized
            end
            local prefix, suffix, ok = cut(pattern, "*")

            -- In module resolution, if `pattern` itself has an extension, a file with that extension is looked up directly,
            -- meaning a '.ts' or '.d.ts' extension is allowed to resolve. This is distinct from the case where a '*' substitution
            -- causes a module specifier to have an extension, i.e. the extension comes from the module specifier in a JS/TS file
            -- and matches the '*'. For example:
            --
            -- Module Specifier      | Path Mapping (key: [pattern]) | Interpolation       | Resolution Action
            -- ---------------------->------------------------------->--------------------->---------------------------------------------------------------
            -- import "@app/foo"    -> "@app/*": ["./src/app/*.ts"] -> "./src/app/foo.ts" -> tryFile("./src/app/foo.ts") || [continue resolution algorithm]
            -- import "@app/foo.ts" -> "@app/*": ["./src/app/*"]    -> "./src/app/foo.ts" -> [continue resolution algorithm]
            --
            -- (https://github.com/microsoft/TypeScript/blob/ad4ded80e1d58f0bf36ac16bea71bc10d9f09895/src/compiler/moduleNameResolver.ts#L2509-L2516)
            --
            -- The interpolation produced by both scenarios is identical, but only in the former, where the extension is encoded in
            -- the path mapping rather than in the module specifier, will we prioritize a file lookup on the interpolation result.
            -- (In fact, currently, the latter scenario will necessarily fail since no resolution mode recognizes '.ts' as a valid
            -- extension for a module specifier.)
            --
            -- Here, this means we need to be careful about whether we generate a match from the target filename (typically with a
            -- .ts extension) or the possible relative module specifiers representing that file:
            --
            -- Filename            | Relative Module Specifier Candidates         | Path Mapping                 | Filename Result    | Module Specifier Results
            -- --------------------<----------------------------------------------<------------------------------<-------------------||----------------------------
            -- dist/haha.d.ts      <- dist/haha, dist/haha.js                     <- "@app/*": ["./dist/*.d.ts"] <- @app/haha        || (none)
            -- dist/haha.d.ts      <- dist/haha, dist/haha.js                     <- "@app/*": ["./dist/*"]      <- (none)           || @app/haha, @app/haha.js
            -- dist/foo/index.d.ts <- dist/foo, dist/foo/index, dist/foo/index.js <- "@app/*": ["./dist/*.d.ts"] <- @app/foo/index   || (none)
            -- dist/foo/index.d.ts <- dist/foo, dist/foo/index, dist/foo/index.js <- "@app/*": ["./dist/*"]      <- (none)           || @app/foo, @app/foo/index, @app/foo/index.js
            -- dist/wow.js.js      <- dist/wow.js, dist/wow.js.js                 <- "@app/*": ["./dist/*.js"]   <- @app/wow.js      || @app/wow, @app/wow.js
            --
            -- The "Filename Result" can be generated only if `pattern` has an extension. Care must be taken that the list of
            -- relative module specifiers to run the interpolation (a) is actually valid for the module resolution mode, (b) takes
            -- into account the existence of other files (e.g. 'dist/wow.js' cannot refer to 'dist/wow.js.js' if 'dist/wow.js'
            -- exists) and (c) that they are ordered by preference. The last row shows that the filename result and module
            -- specifier results are not mutually exclusive. Note that the filename result is a higher priority in module
            -- resolution, but as long criteria (b) above is met, I don't think its result needs to be the highest priority result
            -- in module specifier generation. I have included it last, as it's difficult to tell exactly where it should be
            -- sorted among the others for a particular value of `importModuleSpecifierEnding`.

            local candidates = {}
            for _, ending in ipairs(allowedEndings) do
                local result = modulespecifiers.processEnding(
                    relativeToBaseUrl,
                    { ending },
                    compilerOptions,
                    host
                )
                candidates[#candidates + 1] = { ending = ending, value = result }
            end
            if #tspath.TryGetExtensionFromPath(pattern) > 0 then
                candidates[#candidates + 1] = { ending = ModuleSpecifierEnding.JsExtension, value = relativeToBaseUrl }
            end

            if ok then
                for _, c in ipairs(candidates) do
                    local value = c.value
                    if #value >= #prefix + #suffix and
                        stringutil.HasPrefix(value, prefix, caseSensitive) and -- TODO: possible strada bug: these are not case-switched in strada
                        stringutil.HasSuffix(value, suffix, caseSensitive) and
                        modulespecifiers.validateEnding(c, relativeToBaseUrl, compilerOptions, host) then
                        local matchedStar = string.sub(value, #prefix + 1, #value - #suffix)
                        if not tspath.PathIsRelative(matchedStar) then
                            return modulespecifiers.replaceFirstStar(key, matchedStar)
                        end
                    end
                end
            elseif core.Some(candidates, function(c) return c.ending ~= ModuleSpecifierEnding.Minimal and pattern == c.value end) or
                core.Some(candidates, function(c)
                    return c.ending == ModuleSpecifierEnding.Minimal and pattern == c.value and modulespecifiers.validateEnding(c, relativeToBaseUrl, compilerOptions, host)
                end) then
                return key
            end
        end
    end
    return ""
end

function modulespecifiers.validateEnding(c, relativeToBaseUrl, compilerOptions, host)
    -- Optimization: `removeExtensionAndIndexPostFix` can query the file system (a good bit) if `ending` is `Minimal`, the basename
    -- is 'index', and a `host` is provided. To avoid that until it's unavoidable, we ran the function with no `host` above. Only
    -- here, after we've checked that the minimal ending is indeed a match (via the length and prefix/suffix checks / `some` calls),
    -- do we check that the host-validated result is consistent with the answer we got before. If it's not, it falls back to the
    -- `ModuleSpecifierEnding.Index` result, which should already be in the list of candidates if `Minimal` was. (Note: the assumption here is
    -- that every module resolution mode that supports dropping extensions also supports dropping `/index`. Like literally
    -- everything else in this file, this logic needs to be updated if that's not true in some future module resolution mode.)
    return c.ending ~= ModuleSpecifierEnding.Minimal or c.value == modulespecifiers.processEnding(relativeToBaseUrl, { c.ending }, compilerOptions, host)
end

function modulespecifiers.tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, exports, conditions, mode, isImports, preferTsExtension)
    local t = exports.type
    if t == JSONValueType.NotPresent then
        return ""
    elseif t == JSONValueType.String then
        local strValue = exports.value

        -- possible strada bug? Always uses compilerOptions of the host project, not those applicable to the targeted package.json!
        local outputFile = ""
        local declarationFile = ""
        if isImports then
            outputFile = outputpaths.GetOutputJSFileNameWorker(targetFilePath, options, host)
            declarationFile = outputpaths.GetOutputDeclarationFileNameWorker(targetFilePath, options, host)
        end

        local pathOrPattern = tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(packageDirectory, strValue), "")
        local extensionSwappedTarget = ""
        if tspath.HasTSFileExtension(targetFilePath) then
            extensionSwappedTarget = tspath.RemoveFileExtension(targetFilePath) .. module.TryGetJSExtensionForFile(targetFilePath, options)
        end
        local canTryTsExtension = preferTsExtension and tspath.HasImplementationTSFileExtension(targetFilePath)

        local compareOpts = newComparePathsOptions(host)

        if mode == MatchingMode.Exact then
            if #extensionSwappedTarget > 0 and tspath.ComparePaths(extensionSwappedTarget, pathOrPattern, compareOpts) == 0 or
                tspath.ComparePaths(targetFilePath, pathOrPattern, compareOpts) == 0 or
                #outputFile > 0 and tspath.ComparePaths(outputFile, pathOrPattern, compareOpts) == 0 or
                #declarationFile > 0 and tspath.ComparePaths(declarationFile, pathOrPattern, compareOpts) == 0 then
                return packageName
            end
        elseif mode == MatchingMode.Directory then
            if canTryTsExtension and tspath.ContainsPath(targetFilePath, pathOrPattern, compareOpts) then
                local fragment = tspath.GetRelativePathFromDirectory(pathOrPattern, targetFilePath, compareOpts)
                return tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(tspath.CombinePaths(packageName, strValue), fragment), "")
            end
            if #extensionSwappedTarget > 0 and tspath.ContainsPath(pathOrPattern, extensionSwappedTarget, compareOpts) then
                local fragment = tspath.GetRelativePathFromDirectory(pathOrPattern, extensionSwappedTarget, compareOpts)
                return tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(tspath.CombinePaths(packageName, strValue), fragment), "")
            end
            if not canTryTsExtension and tspath.ContainsPath(pathOrPattern, targetFilePath, compareOpts) then
                local fragment = tspath.GetRelativePathFromDirectory(pathOrPattern, targetFilePath, compareOpts)
                return tspath.GetNormalizedAbsolutePath(tspath.CombinePaths(tspath.CombinePaths(packageName, strValue), fragment), "")
            end
            if #outputFile > 0 and tspath.ContainsPath(pathOrPattern, outputFile, compareOpts) then
                local fragment = tspath.GetRelativePathFromDirectory(pathOrPattern, outputFile, compareOpts)
                return tspath.CombinePaths(packageName, fragment)
            end
            if #declarationFile > 0 and tspath.ContainsPath(pathOrPattern, declarationFile, compareOpts) then
                local fragment = tspath.GetRelativePathFromDirectory(pathOrPattern, declarationFile, compareOpts)
                local jsExtension = modulespecifiers.getJSExtensionForFile(declarationFile, options)
                local fragmentWithJsExtension = tspath.ChangeExtension(fragment, jsExtension)
                return tspath.CombinePaths(packageName, fragmentWithJsExtension)
            end
        elseif mode == MatchingMode.Pattern then
            local leadingSlice, trailingSlice = cut(pathOrPattern, "*")
            local caseSensitive = host:UseCaseSensitiveFileNames()
            if canTryTsExtension and stringutil.HasPrefixAndSuffixWithoutOverlap(targetFilePath, leadingSlice, trailingSlice, caseSensitive) then
                local starReplacement = string.sub(targetFilePath, #leadingSlice + 1, #targetFilePath - #trailingSlice)
                return modulespecifiers.replaceFirstStar(packageName, starReplacement)
            end
            if #extensionSwappedTarget > 0 and stringutil.HasPrefixAndSuffixWithoutOverlap(extensionSwappedTarget, leadingSlice, trailingSlice, caseSensitive) then
                local starReplacement = string.sub(extensionSwappedTarget, #leadingSlice + 1, #extensionSwappedTarget - #trailingSlice)
                return modulespecifiers.replaceFirstStar(packageName, starReplacement)
            end
            if not canTryTsExtension and stringutil.HasPrefixAndSuffixWithoutOverlap(targetFilePath, leadingSlice, trailingSlice, caseSensitive) then
                local starReplacement = string.sub(targetFilePath, #leadingSlice + 1, #targetFilePath - #trailingSlice)
                return modulespecifiers.replaceFirstStar(packageName, starReplacement)
            end
            if #outputFile > 0 and stringutil.HasPrefixAndSuffixWithoutOverlap(outputFile, leadingSlice, trailingSlice, caseSensitive) then
                local starReplacement = string.sub(outputFile, #leadingSlice + 1, #outputFile - #trailingSlice)
                return modulespecifiers.replaceFirstStar(packageName, starReplacement)
            end
            if #declarationFile > 0 and stringutil.HasPrefixAndSuffixWithoutOverlap(declarationFile, leadingSlice, trailingSlice, caseSensitive) then
                local starReplacement = string.sub(declarationFile, #leadingSlice + 1, #declarationFile - #trailingSlice)
                local substituted = modulespecifiers.replaceFirstStar(packageName, starReplacement)
                local jsExtension = module.TryGetJSExtensionForFile(declarationFile, options)
                if #jsExtension > 0 then
                    return tspath.ChangeFullExtension(substituted, jsExtension)
                end
            end
        end
        return ""
    elseif t == JSONValueType.Array then
        local arr = exports:AsArray()
        for _, e in ipairs(arr) do
            local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, e, conditions, mode, isImports, preferTsExtension)
            if #result > 0 then
                return result
            end
        end
    elseif t == JSONValueType.Object then
        -- conditional mapping
        local obj = exports:AsObject()
        for key, value in obj:Entries() do
            if key == "default" or sliceContains(conditions, key) or sliceContains(conditions, "types") and module.IsApplicableVersionedTypesKey(key) then
                local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, value, conditions, mode, isImports, preferTsExtension)
                if #result > 0 then
                    return result
                end
            end
        end
    elseif t == JSONValueType.Null then
        return ""
    end
    return ""
end

-- `importingSourceFile` and `importingSourceFileName`? Why not just use `importingSourceFile.path`?
-- Because when this is called by the declaration emitter, `importingSourceFile` is the implementation
-- file, but `importingSourceFileName` and `toFileName` refer to declaration files (the former to the
-- one currently being produced; the latter to the one being imported). We need an implementation file
-- just to get its `impliedNodeFormat` and to detect certain preferences from existing import module
-- specifiers.
function modulespecifiers.GetModuleSpecifier(compilerOptions, host, importingSourceFile, importingSourceFileName, oldImportSpecifier, toFileName, options)
    return modulespecifiers.getModuleSpecifierWithPreferences(
        compilerOptions,
        host,
        importingSourceFile,
        importingSourceFileName,
        oldImportSpecifier,
        toFileName,
        modulespecifiers.UserPreferences_new(),
        options
    )
end

function modulespecifiers.UpdateModuleSpecifier(compilerOptions, host, importingSourceFile, importingSourceFileName, oldImportSpecifier, toFileName, userPreferences, options)
    return modulespecifiers.getModuleSpecifierWithPreferences(
        compilerOptions,
        host,
        importingSourceFile,
        importingSourceFileName,
        oldImportSpecifier,
        toFileName,
        userPreferences,
        options
    )
end

function modulespecifiers.getModuleSpecifierWithPreferences(compilerOptions, host, importingSourceFile, importingSourceFileName, oldImportSpecifier, toFileName, userPreferences, options)
    local info = modulespecifiers.getInfo(importingSourceFileName, host)
    local modulePaths = modulespecifiers.getAllModulePaths(info, toFileName, host, compilerOptions, userPreferences, options)
    local preferences = modulespecifiers.getModuleSpecifierPreferences(userPreferences, host, compilerOptions, importingSourceFile, oldImportSpecifier)

    local resolutionMode = options.overrideImportMode
    if resolutionMode == ModuleKind.ResolutionModeNone then
        resolutionMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
    end

    for _, modulePath in ipairs(modulePaths) do
        local firstDefined = modulespecifiers.tryGetModuleNameAsNodeModule(modulePath, info, importingSourceFile, host, compilerOptions, userPreferences, false --[[packageNameOnly]], options.overrideImportMode)
        if #firstDefined > 0 then
            return firstDefined
        end
    end

    return modulespecifiers.getLocalModuleSpecifier(toFileName, info, compilerOptions, host, resolutionMode, preferences, false)
end

return modulespecifiers
