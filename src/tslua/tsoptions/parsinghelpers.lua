local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate

-- Go `any` option values are represented as: nil, string, boolean, number (Go int / float64),
-- a plain Lua array ([]any / []string) or a collections.OrderedMap[string, any] (JSON object).
-- core.Tristate values are numbers too.

function tsoptions.isOrderedMap(value)
    return type(value) == "table" and getmetatable(value) == collections.OrderedMap
end

function tsoptions.isSlice(value)
    return type(value) == "table" and getmetatable(value) == nil
end

function tsoptions.ParseTristate(value)
    if value == nil then
        return Tristate.TSUnknown
    end
    if type(value) == "number" then
        return value
    end
    if value == true then
        return Tristate.TSTrue
    else
        return Tristate.TSFalse
    end
end

function tsoptions.ParseStringArray(value)
    if tsoptions.isSlice(value) then
        local result = {}
        for _, v in ipairs(value) do
            if type(v) == "string" then
                result[#result + 1] = v
            end
        end
        return result
    end
    return nil
end

function tsoptions.parseStringMap(value)
    if tsoptions.isOrderedMap(value) then
        local result = collections.NewOrderedMapWithSizeHint(value:Size())
        for k, v in value:Entries() do
            result:Set(k, tsoptions.ParseStringArray(v))
        end
        return result
    end
    return nil
end

function tsoptions.ParseString(value)
    if type(value) == "string" then
        return value
    end
    return ""
end

-- Go int(float64) truncates toward zero.
local function toInt(num)
    if math.type(num) == "integer" then
        return num
    end
    local n = num >= 0 and math.floor(num) or math.ceil(num)
    return math.tointeger(n) or n
end

function tsoptions.parseNumber(value)
    if type(value) == "number" then
        return toInt(value)
    end
    return nil
end

-- projectReferenceParseResult: { reference = core.ProjectReference, hasPath, pathValid, hasCircular, circularValid }
function tsoptions.parseProjectReference(json)
    if tsoptions.isOrderedMap(json) then
        local result = {
            reference = core.NewProjectReference(),
            hasPath = false,
            pathValid = false,
            hasCircular = false,
            circularValid = false,
        }
        local value, ok = json:Get("path")
        if ok then
            result.hasPath = true
            if type(value) == "string" then
                result.reference.path = value
                result.pathValid = true
            end
        end
        value, ok = json:Get("circular")
        if ok then
            result.hasCircular = true
            if type(value) == "boolean" then
                result.reference.circular = value
                result.circularValid = true
            end
        end
        return result
    end
    return nil
end

-- contentmapper.Mapper: { package = string, packageDirectory = string, definition = { extensions = []string },
-- options = JSON text of the options object (Go json.Marshal output) or nil, manifest = contentmapper.Manifest }
function tsoptions.newContentMapper()
    return {
        package = "",
        packageDirectory = "",
        definition = { extensions = nil },
        options = nil,
        manifest = { name = "", version = "", exec = nil, compilerOptions = nil, dynamicConfig = false },
    }
end

-- Returns mapper, errors.
function tsoptions.parseContentMapper(value)
    if not tsoptions.isOrderedMap(value) then
        return nil, nil
    end
    local v = value
    local errors = nil
    local mapper = tsoptions.newContentMapper()
    local pkg, ok = v:Get("package")
    if ok then
        if type(pkg) == "string" and pkg ~= "" then
            mapper.package = pkg
        else
            errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, "contentMapper.package", "string"))
        end
    else
        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, "contentMapper.package", "string"))
    end
    local extensions
    extensions, ok = v:Get("extensions")
    if ok then
        local strs, isStringArray = tsoptions.parseStringArrayStrict(extensions)
        if isStringArray then
            mapper.definition.extensions = strs
        else
            errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, "contentMapper.extensions", "string[]"))
        end
    else
        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, "contentMapper.extensions", "string[]"))
    end
    local options
    options, ok = v:Get("options")
    if ok then
        if not tsoptions.isOrderedMap(options) then
            errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, "contentMapper.options", "object"))
        else
            mapper.options = core.StringifyJson(options, "", "")
        end
    end
    if core.Len(errors) ~= 0 then
        return nil, errors
    end
    return mapper, errors
end

-- parseStringArrayStrict returns the string slice and true only if value is an array whose
-- elements are all strings. A missing element or wrong element type yields false.
function tsoptions.parseStringArrayStrict(value)
    if not tsoptions.isSlice(value) then
        return nil, false
    end
    local result = {}
    for _, v in ipairs(value) do
        if type(v) ~= "string" then
            return nil, false
        end
        result[#result + 1] = v
    end
    return result, true
end

function tsoptions.parseJsonToStringKey(json)
    local result = collections.NewOrderedMapWithSizeHint(6)
    if tsoptions.isOrderedMap(json) then
        local m = json
        for _, key in ipairs({ "include", "exclude", "files", "references", "contentMappers" }) do
            local v, ok = m:Get(key)
            if ok then
                result:Set(key, v)
            end
        end
        local v, ok = m:Get("extends")
        if ok then
            if type(v) == "string" then
                result:Set("extends", { v })
            end
            result:Set("extends", v)
        end
        for _, key in ipairs({ "compilerOptions", "excludes", "typeAcquisition" }) do
            v, ok = m:Get(key)
            if ok then
                result:Set(key, v)
            end
        end
    end
    return result
end

-- optionParser interface: ParseOption(key, value) -> errors, UnknownOptionDiagnostic(),
-- UnknownDidYouMeanDiagnostic(). The parsers wrap the options struct in field `options`.

local compilerOptionsParser = {}
compilerOptionsParser.__index = compilerOptionsParser
tsoptions.compilerOptionsParser = compilerOptionsParser

function tsoptions.newCompilerOptionsParser(options)
    return setmetatable({ options = options, CompilerOptions = options }, compilerOptionsParser)
end

function compilerOptionsParser:ParseOption(key, value)
    return tsoptions.ParseCompilerOptions(key, value, self.options)
end

function compilerOptionsParser:UnknownOptionDiagnostic()
    return tsoptions.extraKeyDiagnostics("compilerOptions")
end

function compilerOptionsParser:UnknownDidYouMeanDiagnostic()
    return tsoptions.extraKeyDidYouMeanDiagnostics("compilerOptions")
end

local watchOptionsParser = {}
watchOptionsParser.__index = watchOptionsParser
tsoptions.watchOptionsParser = watchOptionsParser

function tsoptions.newWatchOptionsParser(options)
    return setmetatable({ options = options, WatchOptions = options }, watchOptionsParser)
end

function watchOptionsParser:ParseOption(key, value)
    return tsoptions.ParseWatchOptions(key, value, self.options)
end

function watchOptionsParser:UnknownOptionDiagnostic()
    return tsoptions.extraKeyDiagnostics("watchOptions")
end

function watchOptionsParser:UnknownDidYouMeanDiagnostic()
    return tsoptions.extraKeyDidYouMeanDiagnostics("watchOptions")
end

local typeAcquisitionParser = {}
typeAcquisitionParser.__index = typeAcquisitionParser
tsoptions.typeAcquisitionParser = typeAcquisitionParser

function tsoptions.newTypeAcquisitionParser(options)
    return setmetatable({ options = options, TypeAcquisition = options }, typeAcquisitionParser)
end

function typeAcquisitionParser:ParseOption(key, value)
    return tsoptions.ParseTypeAcquisition(key, value, self.options)
end

function typeAcquisitionParser:UnknownOptionDiagnostic()
    return tsoptions.extraKeyDiagnostics("typeAcquisition")
end

function typeAcquisitionParser:UnknownDidYouMeanDiagnostic()
    return tsoptions.extraKeyDidYouMeanDiagnostics("typeAcquisition")
end

local buildOptionsParser = {}
buildOptionsParser.__index = buildOptionsParser
tsoptions.buildOptionsParser = buildOptionsParser

function tsoptions.newBuildOptionsParser(options)
    return setmetatable({ options = options, BuildOptions = options }, buildOptionsParser)
end

function buildOptionsParser:ParseOption(key, value)
    return tsoptions.ParseBuildOptions(key, value, self.options)
end

function buildOptionsParser:UnknownOptionDiagnostic()
    return tsoptions.extraKeyDiagnostics("buildOptions")
end

function buildOptionsParser:UnknownDidYouMeanDiagnostic()
    return tsoptions.extraKeyDidYouMeanDiagnostics("buildOptions")
end

function tsoptions.ParseCompilerOptions(key, value, allOptions)
    if value == nil then
        return nil
    end
    if allOptions == nil then
        return nil
    end
    tsoptions.parseCompilerOptions(key, value, allOptions)
    return nil
end

local P = {
    tristate = function(value) return tsoptions.ParseTristate(value) end,
    string = function(value) return tsoptions.ParseString(value) end,
    stringArray = function(value) return tsoptions.ParseStringArray(value) end,
    flag = function(value) return tsoptions.floatOrInt32ToFlag(value) end,
    number = function(value) return tsoptions.parseNumber(value) end,
    stringMap = function(value) return tsoptions.parseStringMap(value) end,
}

-- The Go switch, as an ordered table: option key -> { CompilerOptions field, parser }.
tsoptions.compilerOptionsSwitch = {
    allowJs = { "allowJs", P.tristate },
    allowImportingTsExtensions = { "allowImportingTsExtensions", P.tristate },
    allowSyntheticDefaultImports = { "allowSyntheticDefaultImports", P.tristate },
    allowNonTsExtensions = { "allowNonTsExtensions", P.tristate },
    allowUmdGlobalAccess = { "allowUmdGlobalAccess", P.tristate },
    allowUnreachableCode = { "allowUnreachableCode", P.tristate },
    allowUnusedLabels = { "allowUnusedLabels", P.tristate },
    allowArbitraryExtensions = { "allowArbitraryExtensions", P.tristate },
    alwaysStrict = { "alwaysStrict", P.tristate },
    assumeChangesOnlyAffectDirectDependencies = { "assumeChangesOnlyAffectDirectDependencies", P.tristate },
    baseUrl = { "baseUrl", P.string },
    build = { "build", P.tristate },
    checkJs = { "checkJs", P.tristate },
    customConditions = { "customConditions", P.stringArray },
    composite = { "composite", P.tristate },
    declarationDir = { "declarationDir", P.string },
    deduplicatePackages = { "deduplicatePackages", P.tristate },
    diagnostics = { "diagnostics", P.tristate },
    disableSizeLimit = { "disableSizeLimit", P.tristate },
    disableSourceOfProjectReferenceRedirect = { "disableSourceOfProjectReferenceRedirect", P.tristate },
    disableSolutionSearching = { "disableSolutionSearching", P.tristate },
    disableReferencedProjectLoad = { "disableReferencedProjectLoad", P.tristate },
    declarationMap = { "declarationMap", P.tristate },
    declaration = { "declaration", P.tristate },
    downlevelIteration = { "downlevelIteration", P.tristate },
    erasableSyntaxOnly = { "erasableSyntaxOnly", P.tristate },
    emitDeclarationOnly = { "emitDeclarationOnly", P.tristate },
    extendedDiagnostics = { "extendedDiagnostics", P.tristate },
    emitDecoratorMetadata = { "emitDecoratorMetadata", P.tristate },
    emitBOM = { "emitBOM", P.tristate },
    esModuleInterop = { "esModuleInterop", P.tristate },
    exactOptionalPropertyTypes = { "exactOptionalPropertyTypes", P.tristate },
    explainFiles = { "explainFiles", P.tristate },
    experimentalDecorators = { "experimentalDecorators", P.tristate },
    forceConsistentCasingInFileNames = { "forceConsistentCasingInFileNames", P.tristate },
    generateCpuProfile = { "generateCpuProfile", P.string },
    generateTrace = { "generateTrace", P.string },
    isolatedModules = { "isolatedModules", P.tristate },
    ignoreConfig = { "ignoreConfig", P.tristate },
    ignoreDeprecations = { "ignoreDeprecations", P.string },
    importHelpers = { "importHelpers", P.tristate },
    incremental = { "incremental", P.tristate },
    init = { "init", P.tristate },
    inlineSourceMap = { "inlineSourceMap", P.tristate },
    inlineSources = { "inlineSources", P.tristate },
    isolatedDeclarations = { "isolatedDeclarations", P.tristate },
    jsx = { "jsx", P.flag },
    jsxFactory = { "jsxFactory", P.string },
    jsxFragmentFactory = { "jsxFragmentFactory", P.string },
    jsxImportSource = { "jsxImportSource", P.string },
    lib = { "lib", P.stringArray },
    libReplacement = { "libReplacement", P.tristate },
    listEmittedFiles = { "listEmittedFiles", P.tristate },
    listFiles = { "listFiles", P.tristate },
    listFilesOnly = { "listFilesOnly", P.tristate },
    locale = { "locale", P.string },
    mapRoot = { "mapRoot", P.string },
    module = { "module", P.flag },
    moduleDetectionKind = { "moduleDetection", P.flag },
    moduleResolution = { "moduleResolution", P.flag },
    moduleSuffixes = { "moduleSuffixes", P.stringArray },
    moduleDetection = { "moduleDetection", P.flag },
    noCheck = { "noCheck", P.tristate },
    noFallthroughCasesInSwitch = { "noFallthroughCasesInSwitch", P.tristate },
    noEmitForJsFiles = { "noEmitForJsFiles", P.tristate },
    noErrorTruncation = { "noErrorTruncation", P.tristate },
    noImplicitAny = { "noImplicitAny", P.tristate },
    noImplicitThis = { "noImplicitThis", P.tristate },
    noLib = { "noLib", P.tristate },
    noPropertyAccessFromIndexSignature = { "noPropertyAccessFromIndexSignature", P.tristate },
    noUncheckedIndexedAccess = { "noUncheckedIndexedAccess", P.tristate },
    noEmitHelpers = { "noEmitHelpers", P.tristate },
    noEmitOnError = { "noEmitOnError", P.tristate },
    noImplicitReturns = { "noImplicitReturns", P.tristate },
    noUnusedLocals = { "noUnusedLocals", P.tristate },
    noUnusedParameters = { "noUnusedParameters", P.tristate },
    noImplicitOverride = { "noImplicitOverride", P.tristate },
    noUncheckedSideEffectImports = { "noUncheckedSideEffectImports", P.tristate },
    outFile = { "outFile", P.string },
    noResolve = { "noResolve", P.tristate },
    paths = { "paths", P.stringMap },
    preserveWatchOutput = { "preserveWatchOutput", P.tristate },
    preserveConstEnums = { "preserveConstEnums", P.tristate },
    preserveSymlinks = { "preserveSymlinks", P.tristate },
    project = { "project", P.string },
    pretty = { "pretty", P.tristate },
    resolveJsonModule = { "resolveJsonModule", P.tristate },
    resolvePackageJsonExports = { "resolvePackageJsonExports", P.tristate },
    resolvePackageJsonImports = { "resolvePackageJsonImports", P.tristate },
    reactNamespace = { "reactNamespace", P.string },
    rewriteRelativeImportExtensions = { "rewriteRelativeImportExtensions", P.tristate },
    rootDir = { "rootDir", P.string },
    rootDirs = { "rootDirs", P.stringArray },
    removeComments = { "removeComments", P.tristate },
    stableTypeOrdering = { "stableTypeOrdering", P.tristate },
    strict = { "strict", P.tristate },
    strictBindCallApply = { "strictBindCallApply", P.tristate },
    strictBuiltinIteratorReturn = { "strictBuiltinIteratorReturn", P.tristate },
    strictFunctionTypes = { "strictFunctionTypes", P.tristate },
    strictNullChecks = { "strictNullChecks", P.tristate },
    strictPropertyInitialization = { "strictPropertyInitialization", P.tristate },
    skipDefaultLibCheck = { "skipDefaultLibCheck", P.tristate },
    sourceMap = { "sourceMap", P.tristate },
    sourceRoot = { "sourceRoot", P.string },
    stripInternal = { "stripInternal", P.tristate },
    suppressOutputPathCheck = { "suppressOutputPathCheck", P.tristate },
    target = { "target", P.flag },
    traceResolution = { "traceResolution", P.tristate },
    tsBuildInfoFile = { "tsBuildInfoFile", P.string },
    typeRoots = { "typeRoots", P.stringArray },
    types = { "types", P.stringArray },
    useDefineForClassFields = { "useDefineForClassFields", P.tristate },
    useUnknownInCatchVariables = { "useUnknownInCatchVariables", P.tristate },
    verbatimModuleSyntax = { "verbatimModuleSyntax", P.tristate },
    version = { "version", P.tristate },
    help = { "help", P.tristate },
    all = { "all", P.tristate },
    maxNodeModuleJsDepth = { "maxNodeModuleJsDepth", P.number },
    skipLibCheck = { "skipLibCheck", P.tristate },
    noEmit = { "noEmit", P.tristate },
    showConfig = { "showConfig", P.tristate },
    configFilePath = { "configFilePath", P.string },
    noDtsResolution = { "noDtsResolution", P.tristate },
    pathsBasePath = { "pathsBasePath", P.string },
    outDir = { "outDir", P.string },
    newLine = { "newLine", P.flag },
    watch = { "watch", P.tristate },
    pprofDir = { "pprofDir", P.string },
    singleThreaded = { "singleThreaded", P.tristate },
    quiet = { "quiet", P.tristate },
    checkers = { "checkers", P.number },
    runExternalCode = { "runExternalCode", P.tristate },
}

-- Returns foundKey.
function tsoptions.parseCompilerOptions(key, value, allOptions)
    local option = tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, key)
    if option ~= nil then
        key = option.name
    end
    local case = tsoptions.compilerOptionsSwitch[key]
    if case == nil then
        -- different than any key above
        return false
    end
    allOptions[case[1]] = case[2](value)
    return true
end

-- floatOrInt32ToFlag converts an enum option value (already an enum number, or a JSON float64)
-- to the integer enum value.
function tsoptions.floatOrInt32ToFlag(value)
    if type(value) ~= "number" then
        error("interface conversion: interface {} is " .. type(value) .. ", not float64", 0)
    end
    return toInt(value)
end

function tsoptions.ParseWatchOptions(key, value, allOptions)
    if allOptions == nil then
        return nil
    end
    if key == "watchInterval" then
        allOptions.interval = tsoptions.parseNumber(value)
    elseif key == "watchFile" then
        if value ~= nil then
            allOptions.fileKind = value
        end
    elseif key == "watchDirectory" then
        if value ~= nil then
            allOptions.directoryKind = value
        end
    elseif key == "fallbackPolling" then
        if value ~= nil then
            allOptions.fallbackPolling = value
        end
    elseif key == "synchronousWatchDirectory" then
        allOptions.syncWatchDir = tsoptions.ParseTristate(value)
    elseif key == "excludeDirectories" then
        allOptions.excludeDir = tsoptions.ParseStringArray(value)
    elseif key == "excludeFiles" then
        allOptions.excludeFiles = tsoptions.ParseStringArray(value)
    end
    return nil
end

function tsoptions.ParseTypeAcquisition(key, value, allOptions)
    if value == nil then
        return nil
    end
    if allOptions == nil then
        return nil
    end
    if key == "enable" then
        allOptions.enable = tsoptions.ParseTristate(value)
    elseif key == "include" then
        allOptions.include = tsoptions.ParseStringArray(value)
    elseif key == "exclude" then
        allOptions.exclude = tsoptions.ParseStringArray(value)
    elseif key == "disableFilenameBasedTypeAcquisition" then
        allOptions.disableFilenameBasedTypeAcquisition = tsoptions.ParseTristate(value)
    end
    return nil
end

function tsoptions.ParseBuildOptions(key, value, allOptions)
    if value == nil then
        return nil
    end
    if allOptions == nil then
        return nil
    end
    local option = tsoptions.BuildNameMap:Get(key)
    if option ~= nil then
        key = option.name
    end
    if key == "clean" then
        allOptions.clean = tsoptions.ParseTristate(value)
    elseif key == "dry" then
        allOptions.dry = tsoptions.ParseTristate(value)
    elseif key == "force" then
        allOptions.force = tsoptions.ParseTristate(value)
    elseif key == "builders" then
        allOptions.builders = tsoptions.parseNumber(value)
    elseif key == "stopBuildOnErrors" then
        allOptions.stopBuildOnErrors = tsoptions.ParseTristate(value)
    elseif key == "verbose" then
        allOptions.verbose = tsoptions.ParseTristate(value)
    end
    return nil
end

local function isZero(field, value)
    if value == nil then
        return true
    end
    if field.zero ~= nil then
        return value == field.zero
    end
    return false
end

-- mergeCompilerOptions merges the source compiler options into the target compiler options
-- with optional awareness of explicitly set null values in the raw JSON.
-- Fields in the source options will overwrite the corresponding fields in the target options,
-- including when they are explicitly set to null in the raw configuration (if rawSource is provided).
function tsoptions.mergeCompilerOptions(targetOptions, sourceOptions, rawSource)
    if sourceOptions == nil then
        return targetOptions
    end

    -- Collect explicitly null field names from raw JSON
    local explicitNullFields = {}
    if rawSource ~= nil then
        if tsoptions.isOrderedMap(rawSource) then
            -- Options are nested under "compilerOptions" in both tsconfig.json and wrapped command line options
            local compilerOptionsRaw, exists = rawSource:Get("compilerOptions")
            if exists then
                if tsoptions.isOrderedMap(compilerOptionsRaw) then
                    for key, value in compilerOptionsRaw:Entries() do
                        if value == nil then
                            explicitNullFields[key] = true
                        end
                    end
                end
            end
        end
    end

    -- Do the merge, handling explicit nulls during the normal merge
    for _, field in ipairs(core.CompilerOptions.Fields) do
        -- Get the JSON field name for this struct field and check if it's explicitly null
        if field.json ~= nil and field.json ~= "" and explicitNullFields[field.json] then
            targetOptions[field.name] = field.zero
        else
            -- Normal merge behavior: copy non-zero fields
            local sourceField = sourceOptions[field.name]
            if not isZero(field, sourceField) then
                targetOptions[field.name] = sourceField
            end
        end
    end

    return targetOptions
end

function tsoptions.convertToOptionsWithAbsolutePaths(optionsBase, optionMap, cwd)
    -- !!! convert to options with absolute paths was previously done with `CompilerOptions` object, but for ease of implementation, we do it pre-conversion.
    -- !!! Revisit this choice if/when refactoring when conversion is done in tsconfig parsing
    if optionsBase == nil then
        return nil
    end
    local updates = {}
    for o, v in optionsBase:Entries() do
        local result, ok = tsoptions.ConvertOptionToAbsolutePath(o, v, optionMap, cwd)
        if ok then
            updates[#updates + 1] = { o, result }
        end
    end
    for _, update in ipairs(updates) do
        optionsBase:Set(update[1], update[2])
    end
    return optionsBase
end

-- Returns value, ok.
function tsoptions.ConvertOptionToAbsolutePath(o, v, optionMap, cwd)
    local option = tsoptions.CommandLineOptionNameMap_Get(optionMap, o)
    if option == nil then
        return nil, false
    end
    if option.kind == "list" then
        if option:Elements().isFilePath then
            if tsoptions.isSlice(v) then
                return core.Map(v, function(item)
                    if type(item) == "string" then
                        return tspath.GetNormalizedAbsolutePath(item, cwd)
                    end
                    return item
                end), true
            end
        end
    elseif option.isFilePath then
        if type(v) == "string" then
            return tspath.GetNormalizedAbsolutePath(v, cwd), true
        end
    end
    return nil, false
end
