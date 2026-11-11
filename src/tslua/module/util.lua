local module = require("tslua.module")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local semver = require("tslua.semver")
local tspath = require("tslua.tspath")

local strings = module.strings
local JsxEmit = core.JsxEmit

module.typeScriptVersion = semver.MustParse(core.Version())

function module.IsApplicableVersionedTypesKey(key)
    if not strings.HasPrefix(key, "types@") then
        return false
    end
    local range_, ok = semver.TryParseVersionRange(string.sub(key, #"types@" + 1))
    if not ok then
        return false
    end
    return range_:Test(module.typeScriptVersion)
end

function module.ParseNodeModuleFromPath(resolved, isFolder)
    local path = tspath.NormalizePath(resolved)
    local idx = strings.LastIndex(path, "/node_modules/")
    if idx == -1 then
        return ""
    end

    local indexAfterNodeModules = idx + #"/node_modules/"
    local indexAfterPackageName = module.moveToNextDirectorySeparatorIfAvailable(path, indexAfterNodeModules, isFolder)
    if string.byte(path, indexAfterNodeModules + 1) == string.byte("@") then
        indexAfterPackageName = module.moveToNextDirectorySeparatorIfAvailable(path, indexAfterPackageName, isFolder)
    end
    return string.sub(path, 1, indexAfterPackageName)
end

-- ParsePackageName returns packageName, rest.
function module.ParsePackageName(moduleName)
    local idx = strings.Index(moduleName, "/")
    if #moduleName > 0 and string.byte(moduleName, 1) == string.byte("@") then
        local offset = idx + 1
        idx = strings.Index(string.sub(moduleName, offset + 1), "/")
        if idx ~= -1 then
            idx = idx + offset
        end
    end
    if idx == -1 then
        return moduleName, ""
    end
    return string.sub(moduleName, 1, idx), string.sub(moduleName, idx + 2)
end

function module.MangleScopedPackageName(packageName)
    if #packageName > 0 and string.byte(packageName, 1) == string.byte("@") then
        local idx = strings.Index(packageName, "/")
        if idx == -1 then
            return packageName
        end
        return string.sub(packageName, 2, idx) .. "__" .. string.sub(packageName, idx + 2)
    end
    return packageName
end

function module.UnmangleScopedPackageName(packageName)
    local before, after, ok = strings.Cut(packageName, "__")
    if ok then
        return "@" .. before .. "/" .. after
    end
    return packageName
end

function module.GetTypesPackageName(packageName)
    return "@types/" .. module.MangleScopedPackageName(packageName)
end

function module.GetPackageNameFromTypesPackageName(mangledName)
    local withoutAtTypePrefix = strings.TrimPrefix(mangledName, "@types/")
    if withoutAtTypePrefix ~= mangledName then
        return module.UnmangleScopedPackageName(withoutAtTypePrefix)
    end
    return mangledName
end

function module.ComparePatternKeys(a, b)
    local aPatternIndex = strings.Index(a, "*")
    local bPatternIndex = strings.Index(b, "*")
    local baseLenA = #a
    if aPatternIndex ~= -1 then
        baseLenA = aPatternIndex + 1
    end
    local baseLenB = #b
    if bPatternIndex ~= -1 then
        baseLenB = bPatternIndex + 1
    end

    if baseLenA > baseLenB then
        return -1
    end
    if baseLenB > baseLenA then
        return 1
    end
    if aPatternIndex == -1 then
        return 1
    end
    if bPatternIndex == -1 then
        return -1
    end
    if #a > #b then
        return -1
    end
    if #b > #a then
        return 1
    end
    return 0
end

-- Returns a DiagnosticMessage if we won't include a resolved module due to its extension.
-- The DiagnosticMessage's parameters are the imported module name, and the filename it resolved to.
-- This returns a diagnostic even if the module will be an untyped module.
function module.GetResolutionDiagnostic(options, resolvedModule, file)
    local function needJsx()
        if options.jsx ~= JsxEmit.None then
            return nil
        end
        return diagnostics.Module_0_was_resolved_to_1_but_jsx_is_not_set
    end

    local function needAllowJs()
        if options:GetAllowJS() or not core.Tristate_IsTrue(core.Tristate_DefaultIfUnknown(options.noImplicitAny, options.strict)) then
            return nil
        end
        return diagnostics.Could_not_find_a_declaration_file_for_module_0_1_implicitly_has_an_any_type
    end

    local function needResolveJsonModule()
        if options:GetResolveJsonModule() then
            return nil
        end
        return diagnostics.Module_0_was_resolved_to_1_but_resolveJsonModule_is_not_used
    end

    local function needAllowArbitraryExtensions()
        if file.isDeclarationFile or core.Tristate_IsTrue(options.allowArbitraryExtensions) then
            return nil
        end
        return diagnostics.Module_0_was_resolved_to_1_but_allowArbitraryExtensions_is_not_set
    end

    if resolvedModule.resolvedUsingExtraExtensions then
        return nil
    end

    local ext = resolvedModule.extension
    if ext == tspath.ExtensionTs or ext == tspath.ExtensionDts or
        ext == tspath.ExtensionMts or ext == tspath.ExtensionDmts or
        ext == tspath.ExtensionCts or ext == tspath.ExtensionDcts then
        -- These are always allowed.
        return nil
    elseif ext == tspath.ExtensionTsx then
        return needJsx()
    elseif ext == tspath.ExtensionJsx then
        local message = needJsx()
        if message ~= nil then
            return message
        end
        return needAllowJs()
    elseif ext == tspath.ExtensionJs or ext == tspath.ExtensionMjs or ext == tspath.ExtensionCjs then
        return needAllowJs()
    elseif ext == tspath.ExtensionJson then
        return needResolveJsonModule()
    else
        return needAllowArbitraryExtensions()
    end
end

-- TryGetJSExtensionForFile maps TS/JS/DTS extensions to the output JS-side extension.
-- Returns an empty string if the extension is unsupported.
function module.TryGetJSExtensionForFile(fileName, options)
    local ext = tspath.TryGetExtensionFromPath(fileName)
    if ext == tspath.ExtensionTs or ext == tspath.ExtensionDts then
        return tspath.ExtensionJs
    elseif ext == tspath.ExtensionTsx then
        if options.jsx == JsxEmit.Preserve then
            return tspath.ExtensionJsx
        end
        return tspath.ExtensionJs
    elseif ext == tspath.ExtensionJs or ext == tspath.ExtensionJsx or ext == tspath.ExtensionJson then
        return ext
    elseif ext == tspath.ExtensionDmts or ext == tspath.ExtensionMts or ext == tspath.ExtensionMjs then
        return tspath.ExtensionMjs
    elseif ext == tspath.ExtensionDcts or ext == tspath.ExtensionCts or ext == tspath.ExtensionCjs then
        return tspath.ExtensionCjs
    else
        return ""
    end
end
