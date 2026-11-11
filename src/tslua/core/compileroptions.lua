local core = require("tslua.core")
local collections = require("tslua.collections")
local json = require("tslua.json")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local ModuleDetectionKind = core.ModuleDetectionKind
local ScriptTarget = core.ScriptTarget
local JsxEmit = core.JsxEmit
local NewLineKind = core.NewLineKind

-- CompilerOptions contains the compiler options exposed by the API.
local CompilerOptions = {}
CompilerOptions.__index = CompilerOptions
core.CompilerOptions = CompilerOptions

-- Every field of the Go struct, in declaration order. name is the Lua field (lowerCamel of the
-- Go name, which coincides with the json name); kind is one of "tristate" (zero TSUnknown),
-- "string" (zero ""), "stringlist" (nil-able []string), "intptr" (nil-able *int),
-- "map" (nil-able *collections.OrderedMap[string, []string]) or "enum:<Type>" (zero 0).
-- deprecated/internal mirror the Go struct tags.
CompilerOptions.Fields = {
    { name = "allowJs", json = "allowJs", kind = "tristate" },
    { name = "allowArbitraryExtensions", json = "allowArbitraryExtensions", kind = "tristate" },
    { name = "allowImportingTsExtensions", json = "allowImportingTsExtensions", kind = "tristate" },
    { name = "allowNonTsExtensions", json = "allowNonTsExtensions", kind = "tristate" },
    { name = "allowUmdGlobalAccess", json = "allowUmdGlobalAccess", kind = "tristate" },
    { name = "allowUnreachableCode", json = "allowUnreachableCode", kind = "tristate" },
    { name = "allowUnusedLabels", json = "allowUnusedLabels", kind = "tristate" },
    { name = "assumeChangesOnlyAffectDirectDependencies", json = "assumeChangesOnlyAffectDirectDependencies", kind = "tristate" },
    { name = "checkJs", json = "checkJs", kind = "tristate" },
    { name = "customConditions", json = "customConditions", kind = "stringlist" },
    { name = "composite", json = "composite", kind = "tristate" },
    { name = "emitDeclarationOnly", json = "emitDeclarationOnly", kind = "tristate" },
    { name = "emitBOM", json = "emitBOM", kind = "tristate" },
    { name = "emitDecoratorMetadata", json = "emitDecoratorMetadata", kind = "tristate" },
    { name = "declaration", json = "declaration", kind = "tristate" },
    { name = "declarationDir", json = "declarationDir", kind = "string" },
    { name = "declarationMap", json = "declarationMap", kind = "tristate" },
    { name = "deduplicatePackages", json = "deduplicatePackages", kind = "tristate" },
    { name = "disableSizeLimit", json = "disableSizeLimit", kind = "tristate" },
    { name = "disableSourceOfProjectReferenceRedirect", json = "disableSourceOfProjectReferenceRedirect", kind = "tristate" },
    { name = "disableSolutionSearching", json = "disableSolutionSearching", kind = "tristate" },
    { name = "disableReferencedProjectLoad", json = "disableReferencedProjectLoad", kind = "tristate" },
    { name = "erasableSyntaxOnly", json = "erasableSyntaxOnly", kind = "tristate" },
    { name = "exactOptionalPropertyTypes", json = "exactOptionalPropertyTypes", kind = "tristate" },
    { name = "experimentalDecorators", json = "experimentalDecorators", kind = "tristate" },
    { name = "forceConsistentCasingInFileNames", json = "forceConsistentCasingInFileNames", kind = "tristate" },
    { name = "isolatedModules", json = "isolatedModules", kind = "tristate" },
    { name = "isolatedDeclarations", json = "isolatedDeclarations", kind = "tristate" },
    { name = "ignoreConfig", json = "ignoreConfig", kind = "tristate" },
    { name = "ignoreDeprecations", json = "ignoreDeprecations", kind = "string" },
    { name = "importHelpers", json = "importHelpers", kind = "tristate" },
    { name = "inlineSourceMap", json = "inlineSourceMap", kind = "tristate" },
    { name = "inlineSources", json = "inlineSources", kind = "tristate" },
    { name = "init", json = "init", kind = "tristate" },
    { name = "incremental", json = "incremental", kind = "tristate" },
    { name = "jsx", json = "jsx", kind = "enum:JsxEmit" },
    { name = "jsxFactory", json = "jsxFactory", kind = "string" },
    { name = "jsxFragmentFactory", json = "jsxFragmentFactory", kind = "string" },
    { name = "jsxImportSource", json = "jsxImportSource", kind = "string" },
    { name = "lib", json = "lib", kind = "stringlist" },
    { name = "libReplacement", json = "libReplacement", kind = "tristate" },
    { name = "locale", json = "locale", kind = "string" },
    { name = "mapRoot", json = "mapRoot", kind = "string" },
    { name = "module", json = "module", kind = "enum:ModuleKind" },
    { name = "moduleResolution", json = "moduleResolution", kind = "enum:ModuleResolutionKind" },
    { name = "moduleSuffixes", json = "moduleSuffixes", kind = "stringlist" },
    { name = "moduleDetection", json = "moduleDetection", kind = "enum:ModuleDetectionKind" },
    { name = "newLine", json = "newLine", kind = "enum:NewLineKind" },
    { name = "noEmit", json = "noEmit", kind = "tristate" },
    { name = "noCheck", json = "noCheck", kind = "tristate" },
    { name = "noErrorTruncation", json = "noErrorTruncation", kind = "tristate" },
    { name = "noFallthroughCasesInSwitch", json = "noFallthroughCasesInSwitch", kind = "tristate" },
    { name = "noImplicitAny", json = "noImplicitAny", kind = "tristate" },
    { name = "noImplicitThis", json = "noImplicitThis", kind = "tristate" },
    { name = "noImplicitReturns", json = "noImplicitReturns", kind = "tristate" },
    { name = "noEmitHelpers", json = "noEmitHelpers", kind = "tristate" },
    { name = "noLib", json = "noLib", kind = "tristate" },
    { name = "noPropertyAccessFromIndexSignature", json = "noPropertyAccessFromIndexSignature", kind = "tristate" },
    { name = "noUncheckedIndexedAccess", json = "noUncheckedIndexedAccess", kind = "tristate" },
    { name = "noEmitOnError", json = "noEmitOnError", kind = "tristate" },
    { name = "noUnusedLocals", json = "noUnusedLocals", kind = "tristate" },
    { name = "noUnusedParameters", json = "noUnusedParameters", kind = "tristate" },
    { name = "noResolve", json = "noResolve", kind = "tristate" },
    { name = "noImplicitOverride", json = "noImplicitOverride", kind = "tristate" },
    { name = "noUncheckedSideEffectImports", json = "noUncheckedSideEffectImports", kind = "tristate" },
    { name = "outDir", json = "outDir", kind = "string" },
    { name = "preserveConstEnums", json = "preserveConstEnums", kind = "tristate" },
    { name = "preserveSymlinks", json = "preserveSymlinks", kind = "tristate" },
    { name = "project", json = "project", kind = "string" },
    { name = "resolveJsonModule", json = "resolveJsonModule", kind = "tristate" },
    { name = "resolvePackageJsonExports", json = "resolvePackageJsonExports", kind = "tristate" },
    { name = "resolvePackageJsonImports", json = "resolvePackageJsonImports", kind = "tristate" },
    { name = "removeComments", json = "removeComments", kind = "tristate" },
    { name = "rewriteRelativeImportExtensions", json = "rewriteRelativeImportExtensions", kind = "tristate" },
    { name = "reactNamespace", json = "reactNamespace", kind = "string" },
    { name = "rootDir", json = "rootDir", kind = "string" },
    { name = "rootDirs", json = "rootDirs", kind = "stringlist" },
    { name = "skipLibCheck", json = "skipLibCheck", kind = "tristate" },
    { name = "stableTypeOrdering", json = "stableTypeOrdering", kind = "tristate" },
    { name = "strict", json = "strict", kind = "tristate" },
    { name = "strictBindCallApply", json = "strictBindCallApply", kind = "tristate" },
    { name = "strictBuiltinIteratorReturn", json = "strictBuiltinIteratorReturn", kind = "tristate" },
    { name = "strictFunctionTypes", json = "strictFunctionTypes", kind = "tristate" },
    { name = "strictNullChecks", json = "strictNullChecks", kind = "tristate" },
    { name = "strictPropertyInitialization", json = "strictPropertyInitialization", kind = "tristate" },
    { name = "stripInternal", json = "stripInternal", kind = "tristate" },
    { name = "skipDefaultLibCheck", json = "skipDefaultLibCheck", kind = "tristate" },
    { name = "sourceMap", json = "sourceMap", kind = "tristate" },
    { name = "sourceRoot", json = "sourceRoot", kind = "string" },
    { name = "suppressOutputPathCheck", json = "suppressOutputPathCheck", kind = "tristate" },
    { name = "target", json = "target", kind = "enum:ScriptTarget" },
    { name = "traceResolution", json = "traceResolution", kind = "tristate" },
    { name = "tsBuildInfoFile", json = "tsBuildInfoFile", kind = "string" },
    { name = "typeRoots", json = "typeRoots", kind = "stringlist" },
    { name = "types", json = "types", kind = "stringlist" },
    { name = "useDefineForClassFields", json = "useDefineForClassFields", kind = "tristate" },
    { name = "useUnknownInCatchVariables", json = "useUnknownInCatchVariables", kind = "tristate" },
    { name = "verbatimModuleSyntax", json = "verbatimModuleSyntax", kind = "tristate" },
    { name = "maxNodeModuleJsDepth", json = "maxNodeModuleJsDepth", kind = "intptr" },
    { name = "allowSyntheticDefaultImports", json = "allowSyntheticDefaultImports", kind = "tristate" },
    { name = "alwaysStrict", json = "alwaysStrict", kind = "tristate" },
    { name = "baseUrl", json = "baseUrl", kind = "string" },
    { name = "downlevelIteration", json = "downlevelIteration", kind = "tristate" },
    { name = "esModuleInterop", json = "esModuleInterop", kind = "tristate" },
    { name = "outFile", json = "outFile", kind = "string" },
    { name = "configFilePath", json = "configFilePath", kind = "string" },
    { name = "noDtsResolution", json = "noDtsResolution", kind = "tristate" },
    { name = "pathsBasePath", json = "pathsBasePath", kind = "string" },
    { name = "diagnostics", json = "diagnostics", kind = "tristate" },
    { name = "extendedDiagnostics", json = "extendedDiagnostics", kind = "tristate" },
    { name = "generateCpuProfile", json = "generateCpuProfile", kind = "string" },
    { name = "generateTrace", json = "generateTrace", kind = "string" },
    { name = "listEmittedFiles", json = "listEmittedFiles", kind = "tristate" },
    { name = "listFiles", json = "listFiles", kind = "tristate" },
    { name = "explainFiles", json = "explainFiles", kind = "tristate" },
    { name = "listFilesOnly", json = "listFilesOnly", kind = "tristate" },
    { name = "noEmitForJsFiles", json = "noEmitForJsFiles", kind = "tristate" },
    { name = "preserveWatchOutput", json = "preserveWatchOutput", kind = "tristate" },
    { name = "pretty", json = "pretty", kind = "tristate" },
    { name = "version", json = "version", kind = "tristate" },
    { name = "watch", json = "watch", kind = "tristate" },
    { name = "showConfig", json = "showConfig", kind = "tristate" },
    { name = "build", json = "build", kind = "tristate" },
    { name = "help", json = "help", kind = "tristate" },
    { name = "all", json = "all", kind = "tristate" },
    { name = "runExternalCode", json = "runExternalCode", kind = "tristate" },
    { name = "pprofDir", json = "pprofDir", kind = "string" },
    { name = "singleThreaded", json = "singleThreaded", kind = "tristate" },
    { name = "quiet", json = "quiet", kind = "tristate" },
    { name = "checkers", json = "checkers", kind = "intptr" },
}

local deprecatedFields = {
    allowSyntheticDefaultImports = true,
    alwaysStrict = true,
    baseUrl = true,
    downlevelIteration = true,
    esModuleInterop = true,
    outFile = true,
}
local internalFields = {
    noDtsResolution = true,
    pathsBasePath = true,
    diagnostics = true,
    extendedDiagnostics = true,
    generateCpuProfile = true,
    generateTrace = true,
    listEmittedFiles = true,
    listFiles = true,
    explainFiles = true,
    listFilesOnly = true,
    noEmitForJsFiles = true,
    preserveWatchOutput = true,
    pretty = true,
    version = true,
    watch = true,
    showConfig = true,
    build = true,
    help = true,
    all = true,
    runExternalCode = true,
    pprofDir = true,
    singleThreaded = true,
    quiet = true,
    checkers = true,
}
CompilerOptions.FieldsByName = {}
for _, field in ipairs(CompilerOptions.Fields) do
    field.deprecated = deprecatedFields[field.name] == true
    field.internal = internalFields[field.name] == true
    if field.kind == "tristate" then
        field.zero = Tristate.TSUnknown
    elseif field.kind == "string" then
        field.zero = ""
    elseif string.sub(field.kind, 1, 5) == "enum:" then
        field.zero = 0
    end
    CompilerOptions.FieldsByName[field.name] = field
end

-- Go `&core.CompilerOptions{Field: value, ...}`: every field starts at its Go zero value; init
-- (optional) supplies field values by Lua field name.
function core.NewCompilerOptions(init)
    local options = setmetatable({}, CompilerOptions)
    for _, field in ipairs(CompilerOptions.Fields) do
        if field.zero ~= nil then
            options[field.name] = field.zero
        end
    end
    if init ~= nil then
        for k, v in pairs(init) do
            if CompilerOptions.FieldsByName[k] == nil then
                error("unknown CompilerOptions field: " .. tostring(k), 2)
            end
            options[k] = v
        end
    end
    return options
end

core.EmptyCompilerOptions = core.NewCompilerOptions()

-- Clone creates a shallow copy of the CompilerOptions.
function CompilerOptions:Clone()
    local target = setmetatable({}, CompilerOptions)
    for _, field in ipairs(CompilerOptions.Fields) do
        target[field.name] = self[field.name]
    end
    return target
end

-- Go json.Marshal(options): members in struct order, omitzero (Tristate TSUnknown, "", 0, nil
-- omitted), Tristate as true/false, enums as numbers. Returns (string, err).
function CompilerOptions:MarshalJSON()
    local parts = {}
    for _, field in ipairs(CompilerOptions.Fields) do
        local v = self[field.name]
        local raw, err
        if field.kind == "tristate" then
            if v ~= Tristate.TSUnknown then
                raw = core.Tristate_MarshalJSON(v)
            end
        elseif field.kind == "string" then
            if v ~= "" then
                raw = json.QuoteString(v)
            end
        elseif v ~= nil and v ~= 0 then
            raw, err = json.Marshal(v)
            if err ~= nil then
                return nil, err
            end
        end
        if raw ~= nil then
            parts[#parts + 1] = json.QuoteString(field.json) .. ":" .. raw
        end
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end

function CompilerOptions:GetEmitScriptTarget()
    if self.target ~= ScriptTarget.None then
        return self.target
    end
    return ScriptTarget.LatestStandard
end

function CompilerOptions:GetEmitModuleKind()
    if self.module ~= ModuleKind.None then
        return self.module
    end

    local target = self:GetEmitScriptTarget()
    if target == ScriptTarget.ESNext then
        return ModuleKind.ESNext
    end
    if target >= ScriptTarget.ES2022 then
        return ModuleKind.ES2022
    end
    if target >= ScriptTarget.ES2020 then
        return ModuleKind.ES2020
    end
    if target >= ScriptTarget.ES2015 then
        return ModuleKind.ES2015
    end
    return ModuleKind.CommonJS
end

function CompilerOptions:GetModuleResolutionKind()
    local mr = self.moduleResolution
    if mr == ModuleResolutionKind.Unknown or mr == ModuleResolutionKind.Classic or mr == ModuleResolutionKind.Node10 then
        local mk = self:GetEmitModuleKind()
        if mk == ModuleKind.Node16 or mk == ModuleKind.Node18 or mk == ModuleKind.Node20 then
            return ModuleResolutionKind.Node16
        elseif mk == ModuleKind.NodeNext then
            return ModuleResolutionKind.NodeNext
        else
            return ModuleResolutionKind.Bundler
        end
    else
        return mr
    end
end

function CompilerOptions:GetEmitModuleDetectionKind()
    if self.moduleDetection ~= ModuleDetectionKind.None then
        return self.moduleDetection
    end
    local moduleKind = self:GetEmitModuleKind()
    if ModuleKind.Node16 <= moduleKind and moduleKind <= ModuleKind.NodeNext then
        return ModuleDetectionKind.Force
    end
    return ModuleDetectionKind.Auto
end

function CompilerOptions:GetResolvePackageJsonExports()
    return core.Tristate_IsTrueOrUnknown(self.resolvePackageJsonExports)
end

function CompilerOptions:GetResolvePackageJsonImports()
    return core.Tristate_IsTrueOrUnknown(self.resolvePackageJsonImports)
end

function CompilerOptions:GetAllowImportingTsExtensions()
    return core.Tristate_IsTrue(self.allowImportingTsExtensions) or core.Tristate_IsTrue(self.rewriteRelativeImportExtensions)
end

function CompilerOptions:AllowImportingTsExtensionsFrom(fileName)
    return self:GetAllowImportingTsExtensions() or tspath.IsDeclarationFileName(fileName)
end

function CompilerOptions:GetResolveJsonModule()
    if self.resolveJsonModule ~= Tristate.TSUnknown then
        return self.resolveJsonModule == Tristate.TSTrue
    end
    local mk = self:GetEmitModuleKind()
    -- TODO in 6.0: add Node16/Node18
    if mk == ModuleKind.Node20 or mk == ModuleKind.NodeNext then
        return true
    end
    return self:GetModuleResolutionKind() == ModuleResolutionKind.Bundler
end

function CompilerOptions:ShouldPreserveConstEnums()
    return self.preserveConstEnums == Tristate.TSTrue or self:GetIsolatedModules()
end

function CompilerOptions:GetAllowJS()
    if self.allowJs ~= Tristate.TSUnknown then
        return self.allowJs == Tristate.TSTrue
    end
    return self.checkJs == Tristate.TSTrue
end

function CompilerOptions:GetJSXTransformEnabled()
    local jsx = self.jsx
    return jsx == JsxEmit.React or jsx == JsxEmit.ReactJSX or jsx == JsxEmit.ReactJSXDev
end

function CompilerOptions:GetStrictOptionValue(value)
    if value ~= Tristate.TSUnknown then
        return value == Tristate.TSTrue
    end
    return self.strict ~= Tristate.TSFalse
end

-- Returns (result, fromConfig).
function CompilerOptions:GetEffectiveTypeRoots(currentDirectory)
    if self.typeRoots ~= nil then
        return self.typeRoots, true
    end
    local baseDir
    if self.configFilePath ~= "" then
        baseDir = tspath.GetDirectoryPath(self.configFilePath)
    else
        baseDir = currentDirectory
        if baseDir == "" then
            -- This was accounted for in the TS codebase, but only for third-party API usage
            -- where the module resolution host does not provide a getCurrentDirectory().
            error("cannot get effective type roots without a config file path or current directory", 0)
        end
    end

    local typeRoots = {}
    tspath.ForEachAncestorDirectory(baseDir, function(dir)
        typeRoots[#typeRoots + 1] = tspath.CombinePaths(dir, "node_modules", "@types")
        return nil, false
    end)
    return typeRoots, false
end

-- UsesWildcardTypes returns true if this option's types array includes "*"
function CompilerOptions:UsesWildcardTypes()
    if self.types == nil then
        return false
    end
    for _, t in ipairs(self.types) do
        if t == "*" then
            return true
        end
    end
    return false
end

function CompilerOptions:GetIsolatedModules()
    return self.isolatedModules == Tristate.TSTrue or self.verbatimModuleSyntax == Tristate.TSTrue
end

function CompilerOptions:IsIncremental()
    return core.Tristate_IsTrue(self.incremental) or core.Tristate_IsTrue(self.composite)
end

function CompilerOptions:GetEmitStandardClassFields()
    return self.useDefineForClassFields ~= Tristate.TSFalse and self:GetEmitScriptTarget() >= ScriptTarget.ES2022
end

function CompilerOptions:GetUseDefineForClassFields()
    if self.useDefineForClassFields == Tristate.TSUnknown then
        return self:GetEmitScriptTarget() >= ScriptTarget.ES2022
    end
    return self.useDefineForClassFields == Tristate.TSTrue
end

function CompilerOptions:GetEmitDeclarations()
    return core.Tristate_IsTrue(self.declaration) or core.Tristate_IsTrue(self.composite)
end

function CompilerOptions:GetAreDeclarationMapsEnabled()
    return self.declarationMap == Tristate.TSTrue and self:GetEmitDeclarations()
end

function CompilerOptions:HasJsonModuleEmitEnabled()
    local mk = self:GetEmitModuleKind()
    if mk == ModuleKind.System or mk == ModuleKind.UMD then
        return false
    end
    return true
end

function CompilerOptions:GetPathsBasePath(currentDirectory)
    if collections.OrderedMap.Size(self.paths) == 0 then
        return ""
    end
    if self.pathsBasePath ~= "" then
        return self.pathsBasePath
    end
    return currentDirectory
end

function core.ModuleKind_IsNonNodeESM(moduleKind)
    return moduleKind >= ModuleKind.ES2015 and moduleKind <= ModuleKind.ESNext
end

function core.ModuleKind_SupportsImportAttributes(moduleKind)
    return ModuleKind.Node18 <= moduleKind and moduleKind <= ModuleKind.NodeNext or
        moduleKind == ModuleKind.Preserve or
        moduleKind == ModuleKind.ESNext
end

core.ModuleKindToModuleResolutionKind = {
    [ModuleKind.Node16] = ModuleResolutionKind.Node16,
    [ModuleKind.NodeNext] = ModuleResolutionKind.NodeNext,
}

-- We don't use stringer on this for now, because these values
-- are user-facing in --traceResolution, and stringer currently
-- lacks the ability to remove the "ModuleResolutionKind" prefix
-- when generating code for multiple types into the same output
-- file. Additionally, since there's no TS equivalent of
-- `ModuleResolutionKindUnknown`, we want to panic on that case,
-- as it probably represents a mistake when porting TS to Go.
function core.ModuleResolutionKind_String(m)
    if m == ModuleResolutionKind.Unknown then
        error("should not use zero value of ModuleResolutionKind", 0)
    elseif m == ModuleResolutionKind.Classic then
        return "Classic"
    elseif m == ModuleResolutionKind.Node10 then
        return "Node10"
    elseif m == ModuleResolutionKind.Node16 then
        return "Node16"
    elseif m == ModuleResolutionKind.NodeNext then
        return "NodeNext"
    elseif m == ModuleResolutionKind.Bundler then
        return "Bundler"
    else
        error("unhandled case in ModuleResolutionKind.String", 0)
    end
end

function core.GetNewLineKind(s)
    if s == "\r\n" then
        return NewLineKind.CRLF
    elseif s == "\n" then
        return NewLineKind.LF
    else
        return NewLineKind.None
    end
end

function core.NewLineKind_GetNewLineCharacter(newLine)
    if newLine == NewLineKind.CRLF then
        return "\r\n"
    else
        return "\n"
    end
end

function core.JsxEmit_String(j)
    if j == JsxEmit.None then
        error("should not use zero value of JsxEmit", 0)
    elseif j == JsxEmit.Preserve then
        return "preserve"
    elseif j == JsxEmit.ReactNative then
        return "react-native"
    elseif j == JsxEmit.React then
        return "react"
    elseif j == JsxEmit.ReactJSX then
        return "react-jsx"
    elseif j == JsxEmit.ReactJSXDev then
        return "react-jsxdev"
    else
        error("unhandled case in JsxEmit.String", 0)
    end
end
