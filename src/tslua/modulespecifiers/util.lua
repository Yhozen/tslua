local modulespecifiers = require("tslua.modulespecifiers")
local core = require("tslua.core")
local module = require("tslua.module")
local regexp = require("tslua.regexp")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local ModuleSpecifierEnding = modulespecifiers.ModuleSpecifierEnding

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

local function contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

-- Go strings.LastIndex (0-based, -1 if absent).
local function lastIndex(s, sub)
    local result = -1
    local init = 1
    while true do
        local i = string.find(s, sub, init, true)
        if i == nil then
            return result
        end
        result = i - 1
        init = i + 1
    end
end

-- Go strings.Index (0-based, -1 if absent).
local function index(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

function modulespecifiers.comparePathsByRedirect(a, b, useCaseSensitiveFileNames)
    -- Redirects sort first, matching Strada's compareBooleans(b.isRedirect, a.isRedirect).
    local c = core.CompareBooleans(b.isRedirect, a.isRedirect)
    if c ~= 0 then
        return c
    end
    c = tspath.CompareNumberOfDirectorySeparators(a.fileName, b.fileName)
    if c ~= 0 then
        return c
    end
    -- Strada relies on Map insertion order to break remaining ties deterministically;
    -- Go maps are unordered, so compare paths to keep the ordering stable.
    return tspath.ComparePaths(a.fileName, b.fileName, tspath.NewComparePathsOptions(useCaseSensitiveFileNames, ""))
end

function modulespecifiers.PathIsBareSpecifier(path)
    return not tspath.PathIsAbsolute(path) and not tspath.PathIsRelative(path)
end

function modulespecifiers.IsExcludedByRegex(moduleSpecifier, excludes)
    for _, pattern in ipairs(excludes or {}) do
        local re = modulespecifiers.stringToRegex(pattern)
        if re ~= nil then
            if re:MatchString(moduleSpecifier) then
                return true
            end
        end
    end
    return false
end

-- regexPatternCache maps regexPatternCacheKey{pattern, caseInsensitive} (encoded as a string key)
-- to the compiled *regexp.Regexp, or false for patterns that failed to compile (Go stores nil).
modulespecifiers.regexPatternCache = {}
modulespecifiers.regexPatternCacheLen = 0

function modulespecifiers.stringToRegex(pattern)
    local caseInsensitive = false

    if #pattern > 2 and string.byte(pattern, 1) == 47 --[[ '/' ]] then
        local lastSlash = lastIndex(pattern, "/")
        if lastSlash > 0 then
            local hasUnescapedMiddleSlash = false
            for i = 1, lastSlash - 1 do
                if string.byte(pattern, i + 1) == 47 and (i == 0 or string.byte(pattern, i) ~= 92 --[[ '\\' ]]) then
                    hasUnescapedMiddleSlash = true
                    break
                end
            end

            if not hasUnescapedMiddleSlash then
                local flags = string.sub(pattern, lastSlash + 2)
                pattern = string.sub(pattern, 2, lastSlash)

                for flag in string.gmatch(flags, ".") do
                    if flag == "i" then
                        caseInsensitive = true
                    end
                end
            end
        end
    end
    local key = (caseInsensitive and "1" or "0") .. pattern

    local re = modulespecifiers.regexPatternCache[key]
    if re ~= nil then
        return re or nil
    end

    if modulespecifiers.regexPatternCacheLen > 1000 then
        modulespecifiers.regexPatternCache = {}
        modulespecifiers.regexPatternCacheLen = 0
    end

    local compilePattern = pattern
    if caseInsensitive then
        compilePattern = "(?i:" .. pattern .. ")"
    end

    local compiled, err = regexp.Compile(compilePattern)
    modulespecifiers.regexPatternCacheLen = modulespecifiers.regexPatternCacheLen + 1
    if err ~= nil then
        modulespecifiers.regexPatternCache[key] = false
        return nil
    end
    modulespecifiers.regexPatternCache[key] = compiled
    return compiled
end

--[[
 * Ensures a path is either absolute (prefixed with `/` or `c:`) or dot-relative (prefixed
 * with `./` or `../`) so as not to be confused with an unprefixed module name.
 *
 * ```ts
 * ensurePathIsNonModuleName("/path/to/file.ext") === "/path/to/file.ext"
 * ensurePathIsNonModuleName("./path/to/file.ext") === "./path/to/file.ext"
 * ensurePathIsNonModuleName("../path/to/file.ext") === "../path/to/file.ext"
 * ensurePathIsNonModuleName("path/to/file.ext") === "./path/to/file.ext"
 * ```
 *
]]
function modulespecifiers.ensurePathIsNonModuleName(path)
    if modulespecifiers.PathIsBareSpecifier(path) then
        return "./" .. path
    end
    return path
end

function modulespecifiers.GetJSExtensionForDeclarationFileExtension(ext)
    if ext == tspath.ExtensionDts then
        return tspath.ExtensionJs
    elseif ext == tspath.ExtensionDmts then
        return tspath.ExtensionMjs
    elseif ext == tspath.ExtensionDcts then
        return tspath.ExtensionCjs
    else
        -- .d.json.ts and the like
        return string.sub(ext, #".d" + 1, #ext - #tspath.ExtensionTs)
    end
end

-- TryGetRealFileNameForNonJSDeclarationFileName remaps files like `foo.d.json.ts` or
-- `foo.module.d.css.ts` back to their real non-JS names.
function modulespecifiers.TryGetRealFileNameForNonJSDeclarationFileName(fileName)
    local baseName = tspath.GetBaseFileName(fileName)
    -- Ends with .ts, contains ".d.", and is NOT a standard .d.ts file
    if not hasSuffix(fileName, tspath.ExtensionTs) or
        not contains(baseName, ".d.") or
        hasSuffix(baseName, tspath.ExtensionDts) then
        return ""
    end
    local noExtension = tspath.RemoveExtension(fileName, tspath.ExtensionTs)
    local lastDotIndex = lastIndex(noExtension, ".")
    local ext = string.sub(noExtension, lastDotIndex + 1)
    local before = noExtension
    local cut = index(noExtension, ".d.")
    if cut >= 0 then
        before = string.sub(noExtension, 1, cut)
    end
    return before .. ext
end

function modulespecifiers.getJSExtensionForFile(fileName, options)
    local result = module.TryGetJSExtensionForFile(fileName, options)
    if #result == 0 then
        error("Extension " .. modulespecifiers.extensionFromPath(fileName) .. " is unsupported:: FileName:: " .. fileName, 0)
    end
    return result
end

--[[
 * Gets the extension from a path.
 * Path must have a valid extension.
]]
function modulespecifiers.extensionFromPath(path)
    local ext = tspath.TryGetExtensionFromPath(path)
    if #ext == 0 then
        error("File " .. path .. " has unknown extension.", 0)
    end
    return ext
end

function modulespecifiers.tryGetAnyFileFromPath(host, path)
    -- !!! TODO: shouldn't this use readdir instead of fileexists for perf?
    -- We check all js, `node` and `json` extensions in addition to TS, since node module resolution would also choose those over the directory
    local extGroups = tsoptions.GetSupportedExtensions(
        core.NewCompilerOptions({
            allowJs = core.Tristate.TSTrue,
        }),
        { ".node", ".json" }
    )
    for _, exts in ipairs(extGroups) do
        for _, e in ipairs(exts) do
            local fullPath = path .. e
            if host:FileExists(tspath.GetNormalizedAbsolutePath(fullPath, host:GetCurrentDirectory())) then
                return true
            end
        end
    end
    return false
end

function modulespecifiers.getPathsRelativeToRootDirs(path, rootDirs, useCaseSensitiveFileNames)
    local results
    for _, rootDir in ipairs(rootDirs or {}) do
        local relativePath = modulespecifiers.getRelativePathIfInSameVolume(path, rootDir, useCaseSensitiveFileNames)
        if not modulespecifiers.isPathRelativeToParent(relativePath) then
            results = core.Append(results, relativePath)
        end
    end
    return results
end

function modulespecifiers.isPathRelativeToParent(path)
    return hasPrefix(path, "..")
end

function modulespecifiers.getRelativePathIfInSameVolume(path, directoryPath, useCaseSensitiveFileNames)
    local relativePath = tspath.GetRelativePathToDirectoryOrUrl(directoryPath, path, false, tspath.NewComparePathsOptions(
        useCaseSensitiveFileNames,
        directoryPath
    ))
    if tspath.IsRootedDiskPath(relativePath) then
        return ""
    end
    return relativePath
end

function modulespecifiers.packageJsonPathsAreEqual(a, b, options)
    if a == b then
        return true
    end
    if #a == 0 or #b == 0 then
        return false
    end
    return tspath.ComparePaths(a, b, options) == 0
end

-- Go slices.Index (0-based, -1 if absent).
local function sliceIndex(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end
modulespecifiers.sliceIndex = sliceIndex

function modulespecifiers.prefersTsExtension(allowedEndings)
    local jsPriority = sliceIndex(allowedEndings, ModuleSpecifierEnding.JsExtension)
    local tsPriority = sliceIndex(allowedEndings, ModuleSpecifierEnding.TsExtension)
    if tsPriority > -1 then
        return tsPriority < jsPriority
    end
    return false
end

function modulespecifiers.replaceFirstStar(s, replacement)
    local i = string.find(s, "*", 1, true)
    if i == nil then
        return s
    end
    return string.sub(s, 1, i - 1) .. replacement .. string.sub(s, i + 1)
end

-- NodeModulePathParts: { topLevelNodeModulesIndex, topLevelPackageNameIndex, packageRootIndex, fileNameIndex }

modulespecifiers.nodeModulesPathParseStateBeforeNodeModules = 0
modulespecifiers.nodeModulesPathParseStateNodeModules = 1
modulespecifiers.nodeModulesPathParseStateScope = 2
modulespecifiers.nodeModulesPathParseStatePackageContent = 3

function modulespecifiers.GetNodeModulePathParts(fullPath)
    -- If fullPath can't be valid module file within node_modules, returns undefined.
    -- Example of expected pattern: /base/path/node_modules/[@scope/otherpackage/@otherscope/node_modules/]package/[subdirectory/]file.js
    -- Returns indices:                       ^            ^                                                      ^             ^
    local BeforeNodeModules = modulespecifiers.nodeModulesPathParseStateBeforeNodeModules
    local NodeModules = modulespecifiers.nodeModulesPathParseStateNodeModules
    local Scope = modulespecifiers.nodeModulesPathParseStateScope
    local PackageContent = modulespecifiers.nodeModulesPathParseStatePackageContent

    local topLevelNodeModulesIndex = 0
    local topLevelPackageNameIndex = 0
    local packageRootIndex = 0
    local fileNameIndex = 0

    local partStart = 0
    local partEnd = 0
    local state = BeforeNodeModules

    while partEnd >= 0 do
        partStart = partEnd
        if partStart + 1 > #fullPath then
            error("slice bounds out of range", 0)
        end
        partEnd = core.IndexAfter(fullPath, "/", partStart + 1)
        if state == BeforeNodeModules then
            if index(string.sub(fullPath, partStart + 1), "/node_modules/") == 0 then
                topLevelNodeModulesIndex = partStart
                topLevelPackageNameIndex = partEnd
                state = NodeModules
            end
        elseif state == NodeModules or state == Scope then
            if state == NodeModules and partStart + 1 >= #fullPath then
                error("index out of range", 0)
            end
            if state == NodeModules and string.byte(fullPath, partStart + 2) == 64 --[[ '@' ]] then
                state = Scope
            else
                packageRootIndex = partEnd
                state = PackageContent
            end
        elseif state == PackageContent then
            if index(string.sub(fullPath, partStart + 1), "/node_modules/") == 0 then
                state = NodeModules
            else
                state = PackageContent
            end
        end
    end

    fileNameIndex = partStart

    if state > NodeModules then
        return {
            topLevelNodeModulesIndex = topLevelNodeModulesIndex,
            topLevelPackageNameIndex = topLevelPackageNameIndex,
            packageRootIndex = packageRootIndex,
            fileNameIndex = fileNameIndex,
        }
    end
    return nil
end

function modulespecifiers.GetNodeModulesPackageName(compilerOptions, importingSourceFile, nodeModulesFileName, host, preferences, options)
    local info = modulespecifiers.getInfo(importingSourceFile:FileName(), host)
    local modulePaths = modulespecifiers.getAllModulePaths(info, nodeModulesFileName, host, compilerOptions, preferences, options)
    for _, modulePath in ipairs(modulePaths) do
        local result = modulespecifiers.tryGetModuleNameAsNodeModule(modulePath, info, importingSourceFile, host, compilerOptions, preferences, true --[[packageNameOnly]], options.overrideImportMode)
        if #result > 0 then
            return result
        end
    end
    return ""
end

function modulespecifiers.allKeysStartWithDot(obj)
    for k in obj:Keys() do
        if not hasPrefix(k, ".") then
            return false
        end
    end
    return true
end

function modulespecifiers.GetPackageNameFromDirectory(fileOrDirectoryPath)
    local idx = lastIndex(fileOrDirectoryPath, "/node_modules/")
    if idx == -1 then
        return ""
    end

    local basename = string.sub(fileOrDirectoryPath, idx + #"/node_modules/" + 1)
    if #basename == 0 then
        error("index out of range [0] with length 0", 0)
    end
    if string.byte(basename, 1) == 46 --[[ '.' ]] then
        return ""
    end

    local nextSlash = index(basename, "/")
    if nextSlash == -1 then
        return basename
    end

    if string.byte(basename, 1) ~= 64 --[[ '@' ]] or nextSlash == #basename - 1 then
        return string.sub(basename, 1, nextSlash)
    end

    local secondSlash = index(string.sub(basename, nextSlash + 2), "/")
    if secondSlash == -1 then
        return basename
    end

    return string.sub(basename, 1, nextSlash + 1 + secondSlash)
end

-- ProcessEntrypointEnding processes a pre-computed module specifier from a package.json exports
-- entrypoint according to the entrypoint's Ending type and the user's preferred endings.
function modulespecifiers.ProcessEntrypointEnding(entrypoint, prefs, host, options, importingSourceFile, allowedEndings)
    local specifier = entrypoint.moduleSpecifier
    if entrypoint.ending == module.Ending.Fixed then
        return specifier
    end

    if core.Len(allowedEndings) == 0 then
        allowedEndings = modulespecifiers.GetAllowedEndingsInPreferredOrder(
            prefs,
            host,
            options,
            importingSourceFile,
            "",
            host:GetDefaultResolutionModeForFile(importingSourceFile)
        )
    end

    local preferredEnding = allowedEndings[1]

    -- Handle declaration file extensions
    local dtsExtension = tspath.GetDeclarationFileExtension(specifier)
    if dtsExtension ~= "" then
        if preferredEnding == ModuleSpecifierEnding.TsExtension or preferredEnding == ModuleSpecifierEnding.JsExtension then
            -- Map .d.ts -> .js, .d.mts -> .mjs, .d.cts -> .cjs
            local jsExtension = modulespecifiers.GetJSExtensionForDeclarationFileExtension(dtsExtension)
            return tspath.ChangeAnyExtension(specifier, jsExtension, { dtsExtension }, false)
        elseif preferredEnding == ModuleSpecifierEnding.Minimal or preferredEnding == ModuleSpecifierEnding.Index then
            if entrypoint.ending == module.Ending.Changeable then
                -- .d.mts/.d.cts must keep an extension; rewrite to .mjs/.cjs instead of dropping
                if dtsExtension == tspath.ExtensionDts then
                    specifier = tspath.RemoveExtension(specifier, dtsExtension)
                    if preferredEnding == ModuleSpecifierEnding.Minimal and hasSuffix(specifier, "/index") then
                        specifier = string.sub(specifier, 1, #specifier - #"/index")
                    end
                    return specifier
                end
                local jsExtension = modulespecifiers.GetJSExtensionForDeclarationFileExtension(dtsExtension)
                return tspath.ChangeAnyExtension(specifier, jsExtension, { dtsExtension }, false)
            end
            -- EndingExtensionChangeable - can only change extension, not remove it
            local jsExtension = modulespecifiers.GetJSExtensionForDeclarationFileExtension(dtsExtension)
            return tspath.ChangeAnyExtension(specifier, jsExtension, { dtsExtension }, false)
        end
        return specifier
    end

    -- Handle .ts/.tsx/.mts/.cts extensions
    if tspath.FileExtensionIsOneOf(specifier, { tspath.ExtensionTs, tspath.ExtensionTsx, tspath.ExtensionMts, tspath.ExtensionCts }) then
        if preferredEnding == ModuleSpecifierEnding.TsExtension then
            return specifier
        elseif preferredEnding == ModuleSpecifierEnding.JsExtension then
            local jsExtension = module.TryGetJSExtensionForFile(specifier, options)
            if jsExtension ~= "" then
                return tspath.RemoveFileExtension(specifier) .. jsExtension
            end
            return specifier
        elseif preferredEnding == ModuleSpecifierEnding.Minimal or preferredEnding == ModuleSpecifierEnding.Index then
            if entrypoint.ending == module.Ending.Changeable then
                specifier = tspath.RemoveFileExtension(specifier)
                if preferredEnding == ModuleSpecifierEnding.Minimal and hasSuffix(specifier, "/index") then
                    specifier = string.sub(specifier, 1, #specifier - #"/index")
                end
                return specifier
            end
            -- EndingExtensionChangeable - can only change extension, not remove it
            local jsExtension = module.TryGetJSExtensionForFile(specifier, options)
            if jsExtension ~= "" then
                return tspath.RemoveFileExtension(specifier) .. jsExtension
            end
            return specifier
        end
        return specifier
    end

    -- Handle .js/.jsx/.mjs/.cjs extensions
    if tspath.FileExtensionIsOneOf(specifier, { tspath.ExtensionJs, tspath.ExtensionJsx, tspath.ExtensionMjs, tspath.ExtensionCjs }) then
        if preferredEnding == ModuleSpecifierEnding.TsExtension or preferredEnding == ModuleSpecifierEnding.JsExtension then
            return specifier
        elseif preferredEnding == ModuleSpecifierEnding.Minimal or preferredEnding == ModuleSpecifierEnding.Index then
            if entrypoint.ending == module.Ending.Changeable then
                specifier = tspath.RemoveFileExtension(specifier)
                if preferredEnding == ModuleSpecifierEnding.Minimal and hasSuffix(specifier, "/index") then
                    specifier = string.sub(specifier, 1, #specifier - #"/index")
                end
                return specifier
            end
            -- EndingExtensionChangeable - keep the extension
            return specifier
        end
        return specifier
    end

    -- For other extensions (like .json), return as-is
    return specifier
end

return modulespecifiers
