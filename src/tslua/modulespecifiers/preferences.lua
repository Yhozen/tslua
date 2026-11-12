local modulespecifiers = require("tslua.modulespecifiers")
local core = require("tslua.core")
local debug = require("tslua.debug")
local tspath = require("tslua.tspath")

local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local ModuleSpecifierEnding = modulespecifiers.ModuleSpecifierEnding
local ImportModuleSpecifierPreference = modulespecifiers.ImportModuleSpecifierPreference
local ImportModuleSpecifierEndingPreference = modulespecifiers.ImportModuleSpecifierEndingPreference
local RelativePreferenceKind = modulespecifiers.RelativePreferenceKind

-- Program errors validate that `noEmit` or `emitDeclarationOnly` is also set,
-- so this function doesn't check them to avoid propagating errors.
function modulespecifiers.shouldAllowImportingTsExtension(compilerOptions, fromFileName)
    return compilerOptions:GetAllowImportingTsExtensions() or #fromFileName > 0 and tspath.IsDeclarationFileName(fromFileName)
end

function modulespecifiers.usesExtensionsOnImports(file)
    for _, ref in ipairs(file:Imports() or {}) do
        local text = ref:Text()
        if tspath.PathIsRelative(text) and not tspath.FileExtensionIsOneOf(text, tspath.ExtensionsNotSupportingExtensionlessResolution) then
            return tspath.HasTSFileExtension(text) or tspath.HasJSFileExtension(text)
        end
    end
    return false
end

function modulespecifiers.inferPreference(resolutionMode, sourceFile, moduleResolutionIsNodeNext)
    local usesJsExtensions = false
    local specifiers
    if sourceFile ~= nil and core.Len(sourceFile:Imports()) > 0 then
        specifiers = sourceFile:Imports()
    elseif sourceFile ~= nil and sourceFile:IsJS() then
        -- !!! TODO: JS support
        -- specifiers = core.Map(getRequiresAtTopOfFile(sourceFile), func(d *ast.Node) *ast.Node { return d.arguments[0] })
    end

    for _, specifier in ipairs(specifiers or {}) do
        local path = specifier:Text()
        if tspath.PathIsRelative(path) then
            -- !!! TODO: proper resolutionMode support
            if moduleResolutionIsNodeNext and resolutionMode == ModuleKind.ResolutionModeCommonJS --[[ && getModeForUsageLocation(sourceFile!, specifier, compilerOptions) === ModuleKind.ESNext ]] then
                -- We're trying to decide a preference for a CommonJS module specifier, but looking at an ESM import.
                goto continue
            end
            if tspath.FileExtensionIsOneOf(path, tspath.ExtensionsNotSupportingExtensionlessResolution) then
                -- These extensions are not optional, so do not indicate a preference.
                goto continue
            end
            if tspath.HasTSFileExtension(path) then
                return ModuleSpecifierEnding.TsExtension
            end
            if tspath.HasJSFileExtension(path) then
                usesJsExtensions = true
            end
        end
        ::continue::
    end

    if usesJsExtensions then
        return ModuleSpecifierEnding.JsExtension
    end
    return ModuleSpecifierEnding.Minimal
end

function modulespecifiers.getModuleSpecifierEndingPreference(pref, resolutionMode, compilerOptions, sourceFile)
    local moduleResolution = compilerOptions:GetModuleResolutionKind()
    local moduleResolutionIsNodeNext = ModuleResolutionKind.Node16 <= moduleResolution and moduleResolution <= ModuleResolutionKind.NodeNext

    if pref == ImportModuleSpecifierEndingPreference.Js or resolutionMode == ModuleKind.ResolutionModeESM and moduleResolutionIsNodeNext then
        -- Extensions are explicitly requested or required. Now choose between .js and .ts.
        if not modulespecifiers.shouldAllowImportingTsExtension(compilerOptions, "") then
            return ModuleSpecifierEnding.JsExtension
        end
        -- `allowImportingTsExtensions` is a strong signal, so use .ts unless the file
        -- already uses .js extensions and no .ts extensions.
        if modulespecifiers.inferPreference(resolutionMode, sourceFile, moduleResolutionIsNodeNext) ~= ModuleSpecifierEnding.JsExtension then
            return ModuleSpecifierEnding.TsExtension
        end
        return ModuleSpecifierEnding.JsExtension
    end

    if pref == ImportModuleSpecifierEndingPreference.Minimal then
        return ModuleSpecifierEnding.Minimal
    end

    if pref == ImportModuleSpecifierEndingPreference.Index then
        return ModuleSpecifierEnding.Index
    end

    -- No preference was specified.
    -- Look at imports and/or requires to guess whether .js, .ts, or extensionless imports are preferred.
    -- N.B. that `Index` detection is not supported since it would require file system probing to do
    -- accurately, and more importantly, literally nobody wants `Index` and its existence is a mystery.
    if not modulespecifiers.shouldAllowImportingTsExtension(compilerOptions, "") then
        -- If .ts imports are not valid, we only need to see one .js import to go with that.
        if sourceFile ~= nil and modulespecifiers.usesExtensionsOnImports(sourceFile) then
            return ModuleSpecifierEnding.JsExtension
        end
        return ModuleSpecifierEnding.Minimal
    end

    return modulespecifiers.inferPreference(resolutionMode, sourceFile, moduleResolutionIsNodeNext)
end

function modulespecifiers.getPreferredEnding(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier, resolutionMode)
    if #oldImportSpecifier > 0 then
        if tspath.HasJSFileExtension(oldImportSpecifier) then
            return ModuleSpecifierEnding.JsExtension
        end
        if string.sub(oldImportSpecifier, -#"/index") == "/index" then
            return ModuleSpecifierEnding.Index
        end
    end
    if resolutionMode == ModuleKind.ResolutionModeNone then
        resolutionMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
    end
    return modulespecifiers.getModuleSpecifierEndingPreference(
        prefs.importModuleSpecifierEnding,
        resolutionMode,
        compilerOptions,
        importingSourceFile
    )
end

-- ModuleSpecifierPreferences: { relativePreference, getAllowedEndingsInPreferredOrder = fn(syntaxImpliedNodeFormat), excludeRegexes }
-- (getAllowedEndingsInPreferredOrder is a function-valued field: call with a dot).

function modulespecifiers.GetAllowedEndingsInPreferredOrder(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier, syntaxImpliedNodeFormat)
    local preferredEnding = modulespecifiers.getPreferredEnding(
        prefs,
        host,
        compilerOptions,
        importingSourceFile,
        oldImportSpecifier,
        ModuleKind.ResolutionModeNone
    )
    local resolutionMode = host:GetDefaultResolutionModeForFile(importingSourceFile)
    if resolutionMode ~= syntaxImpliedNodeFormat then
        preferredEnding = modulespecifiers.getPreferredEnding(
            prefs,
            host,
            compilerOptions,
            importingSourceFile,
            oldImportSpecifier,
            syntaxImpliedNodeFormat
        )
    end
    local moduleResolution = compilerOptions:GetModuleResolutionKind()
    local moduleResolutionIsNodeNext = ModuleResolutionKind.Node16 <= moduleResolution and moduleResolution <= ModuleResolutionKind.NodeNext
    local allowImportingTsExtension = modulespecifiers.shouldAllowImportingTsExtension(compilerOptions, importingSourceFile:FileName())
    -- TypeScript uses `(syntaxImpliedNodeFormat ?? impliedNodeFormat)` here - fall back to the
    -- file's default resolution mode when no syntax-implied mode is given.
    local effectiveSyntaxMode = syntaxImpliedNodeFormat
    if effectiveSyntaxMode == ModuleKind.ResolutionModeNone then
        effectiveSyntaxMode = resolutionMode
    end
    if effectiveSyntaxMode == ModuleKind.ResolutionModeESM and moduleResolutionIsNodeNext then
        if allowImportingTsExtension then
            return { ModuleSpecifierEnding.TsExtension, ModuleSpecifierEnding.JsExtension }
        end
        return { ModuleSpecifierEnding.JsExtension }
    end
    if preferredEnding == ModuleSpecifierEnding.JsExtension then
        if allowImportingTsExtension then
            return { ModuleSpecifierEnding.JsExtension, ModuleSpecifierEnding.TsExtension, ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.Index }
        end
        return { ModuleSpecifierEnding.JsExtension, ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.Index }
    elseif preferredEnding == ModuleSpecifierEnding.TsExtension then
        return { ModuleSpecifierEnding.TsExtension, ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.JsExtension, ModuleSpecifierEnding.Index }
    elseif preferredEnding == ModuleSpecifierEnding.Index then
        if allowImportingTsExtension then
            return { ModuleSpecifierEnding.Index, ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.TsExtension, ModuleSpecifierEnding.JsExtension }
        end
        return { ModuleSpecifierEnding.Index, ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.JsExtension }
    elseif preferredEnding == ModuleSpecifierEnding.Minimal then
        if allowImportingTsExtension then
            return { ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.Index, ModuleSpecifierEnding.TsExtension, ModuleSpecifierEnding.JsExtension }
        end
        return { ModuleSpecifierEnding.Minimal, ModuleSpecifierEnding.Index, ModuleSpecifierEnding.JsExtension }
    else
        debug.AssertNever(preferredEnding)
    end
    return { ModuleSpecifierEnding.Minimal }
end

function modulespecifiers.getModuleSpecifierPreferences(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier)
    local excludes = prefs.autoImportSpecifierExcludeRegexes
    local relativePreference = RelativePreferenceKind.RelativePreferenceShortest
    if #oldImportSpecifier > 0 then
        if tspath.IsExternalModuleNameRelative(oldImportSpecifier) then
            relativePreference = RelativePreferenceKind.RelativePreferenceRelative
        else
            relativePreference = RelativePreferenceKind.RelativePreferenceNonRelative
        end
    else
        local p = prefs.importModuleSpecifierPreference
        if p == ImportModuleSpecifierPreference.Relative then
            relativePreference = RelativePreferenceKind.RelativePreferenceRelative
        elseif p == ImportModuleSpecifierPreference.NonRelative then
            relativePreference = RelativePreferenceKind.RelativePreferenceNonRelative
        elseif p == ImportModuleSpecifierPreference.ProjectRelative then
            relativePreference = RelativePreferenceKind.RelativePreferenceExternalNonRelative
            -- all others are shortest
        end
    end

    local getAllowedEndingsInPreferredOrder = function(syntaxImpliedNodeFormat)
        return modulespecifiers.GetAllowedEndingsInPreferredOrder(
            prefs,
            host,
            compilerOptions,
            importingSourceFile,
            oldImportSpecifier,
            syntaxImpliedNodeFormat
        )
    end

    return {
        excludeRegexes = excludes,
        relativePreference = relativePreference,
        getAllowedEndingsInPreferredOrder = getAllowedEndingsInPreferredOrder,
    }
end

return modulespecifiers
