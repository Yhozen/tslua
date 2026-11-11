local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local locale = require("tslua.locale")
local module = require("tslua.module")
local parser = require("tslua.parser")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")
local vfsmatch = require("tslua.vfs.vfsmatch")

local strings = module.strings
local appendAll = module.appendAll
local Kind = ast.Kind
local CommandLineOptionKind = tsoptions.CommandLineOptionKind
local isOrderedMap = tsoptions.isOrderedMap
local isSlice = tsoptions.isSlice

-- Go `struct{}{}` returned by convertToJson for an empty root (neither a map nor a slice).
tsoptions.emptyStruct = setmetatable({}, { __name = "struct{}" })

local function newOrderedMap()
    return collections.NewOrderedMapWithSizeHint(0)
end

-- extendsResult: { options, include, exclude, files, contentMappers, compileOnSave = false,
-- extendedSourceFiles = set (string -> true) }

-- compilerOptionsDeclaration, compileOnSaveCommandLineOption, extendsOptionDeclaration and
-- tsconfigRootOptionsMap are initialized by tsoptions.initTsconfigparsingVars (end of file).

-- configFileSpecs: { filesSpecs, includeSpecs, excludeSpecs (any; present to report errors, user specified specs),
-- validatedFilesSpec, validatedIncludeSpecs, validatedExcludeSpecs, validatedFilesSpecBeforeSubstitution,
-- validatedIncludeSpecsBeforeSubstitution, isDefaultIncludeSpec }
local configFileSpecs = {}
configFileSpecs.__index = configFileSpecs
tsoptions.configFileSpecs = configFileSpecs

function configFileSpecs:matchesExclude(fileName, comparePathsOptions)
    if core.Len(self.validatedExcludeSpecs) == 0 then
        return false
    end
    local excludeMatcher = vfsmatch.NewSpecMatcher(self.validatedExcludeSpecs, comparePathsOptions.currentDirectory, vfsmatch.Usage.Exclude, comparePathsOptions.useCaseSensitiveFileNames)
    if excludeMatcher == nil then
        return false
    end
    if excludeMatcher:MatchString(fileName) then
        return true
    end
    if not tspath.HasExtension(fileName) then
        if excludeMatcher:MatchString(tspath.EnsureTrailingDirectorySeparator(fileName)) then
            return true
        end
    end
    return false
end

function configFileSpecs:getMatchedIncludeSpec(fileName, comparePathsOptions)
    if core.Len(self.validatedIncludeSpecs) == 0 then
        return ""
    end
    for index1, spec in ipairs(self.validatedIncludeSpecs) do
        local includeMatcher = vfsmatch.NewSpecMatcher({ spec }, comparePathsOptions.currentDirectory, vfsmatch.Usage.Files, comparePathsOptions.useCaseSensitiveFileNames)
        if includeMatcher ~= nil and includeMatcher:MatchString(fileName) then
            return self.validatedIncludeSpecsBeforeSubstitution[index1]
        end
    end
    return ""
end

function configFileSpecs:getMatchedFileSpec(fileName, comparePathsOptions)
    if core.Len(self.validatedFilesSpec) == 0 then
        return ""
    end
    local filePath = tspath.ToPath(fileName, comparePathsOptions.currentDirectory, comparePathsOptions.useCaseSensitiveFileNames)
    for index1, spec in ipairs(self.validatedFilesSpec) do
        if tspath.ToPath(spec, comparePathsOptions.currentDirectory, comparePathsOptions.useCaseSensitiveFileNames) == filePath then
            return self.validatedFilesSpecBeforeSubstitution[index1]
        end
    end
    return ""
end

-- ExtendedConfigCache interface: cache:GetExtendedConfig(fileName, path, resolutionStack, host) -> *ExtendedConfigCacheEntry

local ExtendedConfigCacheEntry = {}
ExtendedConfigCacheEntry.__index = ExtendedConfigCacheEntry
tsoptions.ExtendedConfigCacheEntry = ExtendedConfigCacheEntry

function ExtendedConfigCacheEntry:ExtendedFileNames()
    if self.extendedResult ~= nil then
        return self.extendedResult.extendedSourceFiles
    end
    return nil
end

-- parsedTsconfig: { raw, options, typeAcquisition,
--   extendedConfigPath (Note that the case of the config path has not yet been normalized, as no files have been imported into the project yet) }

-- Returns *parsedTsconfig, errors.
function tsoptions.parseOwnConfigOfJsonSourceFile(
    sourceFile,
    host,
    basePath,
    configFileName
)
    local compilerOptions = tsoptions.getDefaultCompilerOptions(configFileName)
    local typeAcquisition = tsoptions.getDefaultTypeAcquisition(configFileName)
    local extendedConfigPath = nil
    local rootCompilerOptions = nil
    local errors = nil
    local function onPropertySet(
        keyText,
        value,
        propertyAssignment,
        parentOption, -- TsConfigOnlyOption,
        option
    )
        -- Ensure value is verified except for extends which is handled in its own way for error reporting
        local propertySetErrors = nil
        if option ~= nil and option ~= tsoptions.extendsOptionDeclaration then
            value, propertySetErrors = tsoptions.convertJsonOption(option, value, basePath, propertyAssignment, propertyAssignment.initializer, sourceFile)
        end
        if parentOption ~= nil and parentOption.name ~= "undefined" and value ~= nil then
            if option ~= nil and option.name ~= "" then
                local parseDiagnostics = nil
                if parentOption.name == "compilerOptions" then
                    parseDiagnostics = tsoptions.ParseCompilerOptions(option.name, value, compilerOptions)
                elseif parentOption.name == "typeAcquisition" then
                    parseDiagnostics = tsoptions.ParseTypeAcquisition(option.name, value, typeAcquisition)
                end
                propertySetErrors = appendAll(propertySetErrors, parseDiagnostics)
            elseif keyText ~= "" and tsoptions.extraKeyDiagnostics(parentOption.name) ~= nil then
                local unknownNameDiag = tsoptions.extraKeyDiagnostics(parentOption.name)
                if parentOption.elementOptions ~= nil then
                    local possibleOption = tsoptions.CommandLineOptionNameMap_Get(parentOption.elementOptions, keyText)
                    if possibleOption == nil then
                        possibleOption = tsoptions.CommandLineOptionNameMap_GetSpellingSuggestion(parentOption.elementOptions, keyText)
                    end
                    if possibleOption ~= nil and possibleOption.name ~= keyText then
                        propertySetErrors = core.Append(propertySetErrors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(
                            sourceFile,
                            propertyAssignment:Name(),
                            tsoptions.extraKeyDidYouMeanDiagnostics(parentOption.name),
                            keyText,
                            possibleOption.name
                        ))
                    else
                        propertySetErrors = core.Append(propertySetErrors, tsoptions.createUnknownOptionError(
                            keyText,
                            unknownNameDiag,
                            "", --[[unknownOptionErrorText]]
                            propertyAssignment:Name(),
                            sourceFile,
                            nil, --[[alternateMode]]
                            nil, --[[unknownDidYouMeanDiagnostic]]
                            nil --[[optionsNameMap]]
                        ))
                    end
                else
                    -- errors = append(errors, ast.NewCompilerDiagnostic(diagnostics.Unknown_compiler_option_0_Did_you_mean_1, keyText, core.FindKey(parentOption.ElementOptions, keyText)))
                end
            end
        elseif parentOption == tsoptions.tsconfigRootOptionsMap then
            if option == tsoptions.extendsOptionDeclaration then
                local configPath, err = tsoptions.getExtendsConfigPathOrArray(value, host, basePath, configFileName, propertyAssignment, propertyAssignment.initializer, sourceFile)
                extendedConfigPath = configPath
                propertySetErrors = appendAll(propertySetErrors, err)
            elseif option == nil then
                if keyText == "excludes" then
                    propertySetErrors = core.Append(propertySetErrors, tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile, propertyAssignment:Name(), diagnostics.Unknown_option_excludes_Did_you_mean_exclude))
                end
                if core.Find(tsoptions.optionsForCompiler, function(opt) return opt.name == keyText end) ~= nil then
                    rootCompilerOptions = core.Append(rootCompilerOptions, propertyAssignment:Name())
                end
            end
        end
        return value, propertySetErrors
    end

    local json, err = tsoptions.convertConfigFileToObject(
        sourceFile,
        {
            rootOptions = tsoptions.tsconfigRootOptionsMap,
            onPropertySet = onPropertySet,
        }
    )
    errors = appendAll(errors, err)
    if core.Len(rootCompilerOptions) ~= 0 and isOrderedMap(json) and not json:Has("compilerOptions") then
        errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFile(
            sourceFile,
            rootCompilerOptions[1],
            diagnostics.X_0_should_be_set_inside_the_compilerOptions_object_of_the_config_json_file,
            ast.GetTextOfPropertyName(rootCompilerOptions[1])
        ))
    end
    return {
        raw = json,
        options = compilerOptions,
        typeAcquisition = typeAcquisition,
        extendedConfigPath = extendedConfigPath,
    }, errors
end

-- TsConfigSourceFile: { extendedSourceFiles = []string, configFileSpecs = *configFileSpecs, sourceFile = *ast.SourceFile }
local TsConfigSourceFile = {}
TsConfigSourceFile.__index = TsConfigSourceFile
tsoptions.TsConfigSourceFile = TsConfigSourceFile

function tsoptions.NewTsConfigSourceFile(sourceFile)
    return setmetatable({ extendedSourceFiles = nil, configFileSpecs = nil, sourceFile = sourceFile }, TsConfigSourceFile)
end

function tsoptions.tsconfigToSourceFile(tsconfigSourceFile)
    if tsconfigSourceFile == nil then
        return nil
    end
    return tsconfigSourceFile.sourceFile
end

function tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, configPath, configSourceText)
    local sourceFile = parser.ParseSourceFile(ast.NewSourceFileParseOptions(configFileName, configPath), configSourceText, core.ScriptKind.JSON)
    return tsoptions.NewTsConfigSourceFile(sourceFile)
end

-- jsonConversionNotifier: { rootOptions = *CommandLineOption,
--   onPropertySet = function(keyText, value, propertyAssignment, parentOption, option) -> value, errors }

-- Returns value, errors.
function tsoptions.convertConfigFileToObject(
    sourceFile,
    jsonConversionNotifier
)
    local rootExpression = nil
    if #sourceFile.statements.nodes > 0 then
        rootExpression = sourceFile.statements.nodes[1]:Expression()
    end
    if rootExpression ~= nil and rootExpression.kind ~= Kind.ObjectLiteralExpression then
        local baseFileName = "tsconfig.json"
        if tspath.GetBaseFileName(sourceFile:FileName()) == "jsconfig.json" then
            baseFileName = "jsconfig.json"
        end
        local errors = { tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile, rootExpression, diagnostics.The_root_value_of_a_0_file_must_be_an_object, baseFileName) }
        -- Last-ditch error recovery. Somewhat useful because the JSON parser will recover from some parse errors by
        -- synthesizing a top-level array literal expression. There's a reasonable chance the first element of that
        -- array is a well-formed configuration object, made into an array element by stray characters.
        if ast.IsArrayLiteralExpression(rootExpression) then
            local firstObject = core.Find(rootExpression:Elements(), ast.IsObjectLiteralExpression)
            if firstObject ~= nil then
                return tsoptions.convertToJson(sourceFile, firstObject, true --[[returnValue]], jsonConversionNotifier)
            end
        end
        return newOrderedMap(), errors
    end
    return tsoptions.convertToJson(sourceFile, rootExpression, true, jsonConversionNotifier)
end

function tsoptions.isCompilerOptionsValue(option, value)
    if option ~= nil then
        if value == nil then
            return not option:DisallowNullOrUndefined()
        end
        if option.kind == "list" then
            return isSlice(value)
        end
        if option.kind == "listOrElement" then
            if isSlice(value) then
                return true
            else
                return tsoptions.isCompilerOptionsValue(option:Elements(), value)
            end
        end
        if option.kind == "string" then
            return type(value) == "string"
        end
        if option.kind == "boolean" then
            return type(value) == "boolean"
        end
        if option.kind == "number" then
            return type(value) == "number"
        end
        if option.kind == "object" then
            return isOrderedMap(value)
        end
        if option.kind == "enum" and type(value) == "string" then
            return true
        end
    end
    return false
end

-- Returns value, errors.
function tsoptions.validateJsonOptionValue(
    opt,
    val,
    valueExpression,
    sourceFile
)
    if val == nil then
        return nil, nil
    end

    local errors = nil

    if opt.extraValidation == tsoptions.extraValidationSpec then
        local diag = tsoptions.specToDiagnostic(val, false)
        if diag ~= nil then
            errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diag))
        end
    elseif opt.extraValidation == tsoptions.extraValidationLocale then
        local _, ok = locale.Parse(val)
        if not ok then
            errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diagnostics.Locale_must_be_an_IETF_BCP_47_language_tag_Examples_Colon_0_1, "en", "ja-jp"))
        end
    end

    if core.Len(errors) > 0 then
        return nil, errors
    end
    return val, nil
end

-- Returns values, errors.
function tsoptions.convertJsonOptionOfListType(
    option,
    values,
    basePath,
    propertyAssignment,
    valueExpression,
    sourceFile
)
    local expression = nil
    local errors = nil
    if values == tsoptions.NilSlice then
        return tsoptions.NilSlice, errors
    end
    if isSlice(values) then
        local mappedValues = {}
        for index1, v in ipairs(values) do
            if valueExpression ~= nil then
                expression = valueExpression:Elements()[index1]
            end
            local result, err = tsoptions.convertJsonOption(option:Elements(), v, basePath, propertyAssignment, expression, sourceFile)
            errors = appendAll(errors, err)
            mappedValues[index1] = result
        end
        -- mappedValues may contain nil holes (Go nil); compact while filtering.
        local filteredValues = {}
        for i = 1, #values do
            local v = mappedValues[i]
            if option.listPreserveFalsyValues then
                if v ~= nil then
                    filteredValues[#filteredValues + 1] = v
                end
            elseif v ~= nil and v ~= false and not (math.type(v) == "integer" and v == 0) and v ~= "" then
                filteredValues[#filteredValues + 1] = v
            end
        end
        return filteredValues, errors
    end
    return nil, errors
end

tsoptions.configDirTemplate = "${configDir}"

function tsoptions.startsWithConfigDirTemplate(value)
    if type(value) ~= "string" then
        return false
    end
    return strings.HasPrefix(strings.ToLower(value), strings.ToLower(tsoptions.configDirTemplate))
end

function tsoptions.normalizeNonListOptionValue(option, basePath, value)
    if option.isFilePath then
        value = tspath.NormalizeSlashes(value)
        if not tsoptions.startsWithConfigDirTemplate(value) then
            value = tspath.GetNormalizedAbsolutePath(value, basePath)
        end
        if value == "" then
            value = "."
        end
    end
    return value
end

-- Returns value, errors.
function tsoptions.convertJsonOption(
    opt,
    value,
    basePath,
    propertyAssignment,
    valueExpression,
    sourceFile
)
    if opt.isCommandLineOnly then
        local nodeValue = nil
        if propertyAssignment ~= nil then
            nodeValue = propertyAssignment:Name()
        end
        if sourceFile == nil and nodeValue == nil then
            return nil, { ast.NewCompilerDiagnostic(diagnostics.Option_0_can_only_be_specified_on_command_line, opt.name) }
        else
            return nil, { tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, nodeValue, diagnostics.Option_0_can_only_be_specified_on_command_line, opt.name) }
        end
    end
    if tsoptions.isCompilerOptionsValue(opt, value) then
        if opt.kind == CommandLineOptionKind.CommandLineOptionTypeList then
            return tsoptions.convertJsonOptionOfListType(opt, value, basePath, propertyAssignment, valueExpression, sourceFile) -- as ArrayLiteralExpression | undefined
        elseif opt.kind == CommandLineOptionKind.CommandLineOptionTypeListOrElement then
            if isSlice(value) then
                return tsoptions.convertJsonOptionOfListType(opt, value, basePath, propertyAssignment, valueExpression, sourceFile)
            else
                return tsoptions.convertJsonOption(opt:Elements(), value, basePath, propertyAssignment, valueExpression, sourceFile)
            end
        elseif opt.kind == CommandLineOptionKind.CommandLineOptionTypeEnum then
            if value == nil then
                return nil, nil
            end
            return tsoptions.convertJsonOptionOfEnumType(opt, value, valueExpression, sourceFile)
        end

        local validatedValue, errors = tsoptions.validateJsonOptionValue(opt, value, valueExpression, sourceFile)
        if core.Len(errors) > 0 or validatedValue == nil then
            return validatedValue, errors
        else
            return tsoptions.normalizeNonListOptionValue(opt, basePath, validatedValue), errors
        end
    else
        return nil, { tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diagnostics.Compiler_option_0_requires_a_value_of_type_1, opt.name, tsoptions.getCompilerOptionValueTypeString(opt)) }
    end
end

-- Returns []string (possibly nil), errors.
function tsoptions.getExtendsConfigPathOrArray(
    value,
    host,
    basePath,
    configFileName,
    propertyAssignment,
    valueExpression,
    sourceFile
)
    local extendedConfigPathArray = nil
    local newBase = basePath
    if configFileName ~= "" then
        newBase = tsoptions.directoryOfCombinedPath(configFileName, basePath)
    end
    if value == nil then
        local _, errors = tsoptions.convertJsonOption(tsoptions.extendsOptionDeclaration, value, basePath, propertyAssignment, valueExpression, sourceFile)
        return extendedConfigPathArray, errors
    end
    if type(value) == "string" then
        local val, err = tsoptions.getExtendsConfigPath(value, host, newBase, valueExpression, sourceFile)
        if val ~= "" then
            extendedConfigPathArray = core.Append(extendedConfigPathArray, val)
        end
        return extendedConfigPathArray, err
    end
    local errors = nil
    if isSlice(value) then
        for index1, fileName in ipairs(value) do
            local expression = nil
            if valueExpression ~= nil then
                expression = valueExpression:Elements()[index1]
            end
            if type(fileName) == "string" then
                local val, err = tsoptions.getExtendsConfigPath(fileName, host, newBase, expression, sourceFile)
                if val ~= "" then
                    extendedConfigPathArray = core.Append(extendedConfigPathArray, val)
                end
                errors = appendAll(errors, err)
            else
                local _, err = tsoptions.convertJsonOption(tsoptions.extendsOptionDeclaration:Elements(), value, basePath, propertyAssignment, expression, sourceFile)
                errors = appendAll(errors, err)
            end
        end
    else
        local _
        _, errors = tsoptions.convertJsonOption(tsoptions.extendsOptionDeclaration, value, basePath, propertyAssignment, valueExpression, sourceFile)
    end
    return extendedConfigPathArray, errors
end

-- Returns path, errors.
function tsoptions.getExtendsConfigPath(
    extendedConfig,
    host,
    basePath,
    valueExpression,
    sourceFile
)
    extendedConfig = tspath.NormalizeSlashes(extendedConfig)
    local errors = nil
    local errorFile = nil
    if sourceFile ~= nil then
        errorFile = sourceFile
    end
    if tspath.IsRootedDiskPath(extendedConfig) or strings.HasPrefix(extendedConfig, "./") or strings.HasPrefix(extendedConfig, "../") then
        local extendedConfigPath = tspath.GetNormalizedAbsolutePath(extendedConfig, basePath)
        if not host:FS():FileExists(extendedConfigPath) and not strings.HasSuffix(extendedConfigPath, tspath.ExtensionJson) then
            extendedConfigPath = extendedConfigPath .. tspath.ExtensionJson
            if not host:FS():FileExists(extendedConfigPath) then
                errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.File_0_not_found, extendedConfig))
                return "", errors
            end
        end
        return extendedConfigPath, errors
    end
    -- If the path isn't a rooted or relative path, resolve like a module
    local resolverHost = tsoptions.newResolverHost(host)
    local resolved = module.ResolveConfig(extendedConfig, tspath.CombinePaths(basePath, "tsconfig.json"), resolverHost)
    if resolved:IsResolved() then
        return resolved.resolvedFileName, errors
    end
    if extendedConfig == "" then
        errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.Compiler_option_0_cannot_be_given_an_empty_string, "extends"))
    else
        errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.File_0_not_found, extendedConfig))
    end
    return "", errors
end

-- tsConfigOptions: { prop = map[string][]string, references = []*core.ProjectReference, notDefined = string }

-- CommandLineOptionNameMap is a Go map[string]*CommandLineOption: a plain Lua table.
function tsoptions.CommandLineOptionNameMap_Get(m, name)
    local opt = m[name]
    if opt == nil then
        opt = m[strings.ToLower(name)]
    end
    return opt
end

function tsoptions.CommandLineOptionNameMap_GetSpellingSuggestion(m, name)
    local candidates = {}
    for _, option in pairs(m) do
        candidates[#candidates + 1] = option
    end
    -- Go iterates the map in random order; GetSpellingSuggestion breaks ties with the comparer.
    table.sort(candidates, function(a, b) return a.name < b.name end)
    return core.GetSpellingSuggestion(
        name,
        candidates,
        function(option) return option.name end,
        function(a, b) return strings.Compare(a.name, b.name) end
    )
end

function tsoptions.commandLineOptionsToMap(compilerOptions)
    local result = {}
    for i = 0, #compilerOptions - 1 do
        result[compilerOptions[i + 1].name] = compilerOptions[i + 1]
        result[strings.ToLower(compilerOptions[i + 1].name)] = compilerOptions[i + 1]
    end
    return result
end

tsoptions.CommandLineCompilerOptionsMap = tsoptions.commandLineOptionsToMap(tsoptions.OptionsDeclarations)

function tsoptions.convertMapToOptions(compilerOptions, result)
    -- this assumes any `key`, `value` pair in `options` will have `value` already be the correct type. this function should no error handling
    for key, value in compilerOptions:Entries() do
        result:ParseOption(key, value)
    end
    return result
end

-- Returns result, errors.
function tsoptions.convertOptionsFromJson(optionsNameMap, jsonOptions, basePath, result)
    if jsonOptions == nil then
        return result, nil
    end
    if not isOrderedMap(jsonOptions) then
        -- !!! probably should be an error
        return result, nil
    end
    local jsonMap = jsonOptions
    local errors = nil
    for key, value in jsonMap:Entries() do
        local opt = tsoptions.CommandLineOptionNameMap_Get(optionsNameMap, key)
        if opt ~= nil and opt.name ~= key then
            -- Case-insensitive match found but exact case doesn't match - provide "did you mean" suggestion
            errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(nil, nil, result:UnknownDidYouMeanDiagnostic(), key, opt.name))
        elseif opt == nil then
            errors = core.Append(errors, tsoptions.createUnknownOptionError(key, result:UnknownOptionDiagnostic(), "", nil, nil, nil, result:UnknownDidYouMeanDiagnostic(), optionsNameMap))
        else
            local convertJson, err = tsoptions.convertJsonOption(opt, value, basePath, nil, nil, nil)
            errors = appendAll(errors, err)
            local compilerOptionsErr = result:ParseOption(key, convertJson)
            errors = appendAll(errors, compilerOptionsErr)
        end
    end
    return result, errors
end

-- Returns value, errors.
function tsoptions.convertArrayLiteralExpressionToJson(
    sourceFile,
    elements,
    elementOption,
    returnValue
)
    if not returnValue then
        for _, element in ipairs(elements or {}) do
            tsoptions.convertPropertyValueToJson(sourceFile, element, elementOption, returnValue, nil)
        end
        return nil, nil
    end
    -- Filter out invalid values
    if core.Len(elements) == 0 then
        -- Always return an empty array, even if elements is nil.
        -- The parser will produce nil slices instead of allocating empty ones.
        return {}, nil
    end
    local errors = nil
    local value = nil
    for _, element in ipairs(elements) do
        local convertedValue, err = tsoptions.convertPropertyValueToJson(sourceFile, element, elementOption, returnValue, nil)
        errors = appendAll(errors, err)
        if convertedValue ~= nil then
            value = core.Append(value, convertedValue)
        end
    end
    -- A nil Go []any returned as `any` is a typed nil, not a JSON null.
    return value or tsoptions.NilSlice, errors
end

function tsoptions.directoryOfCombinedPath(fileName, basePath)
    -- Use the `getNormalizedAbsolutePath` function to avoid canonicalizing the path, as it must remain noncanonical
    -- until consistent casing errors are reported
    return tspath.GetDirectoryPath(tspath.GetNormalizedAbsolutePath(fileName, basePath))
end

-- ParseConfigFileTextToJson parses the text of the tsconfig.json file
-- fileName is the path to the config file
-- jsonText is the text of the config file
-- Returns value, errors.
function tsoptions.ParseConfigFileTextToJson(fileName, path, jsonText)
    local jsonSourceFile = parser.ParseSourceFile(ast.NewSourceFileParseOptions(fileName, path), jsonText, core.ScriptKind.JSON)
    local config, errors = tsoptions.convertConfigFileToObject(jsonSourceFile, nil --[[jsonConversionNotifier]])
    if core.Len(jsonSourceFile:Diagnostics()) > 0 then
        errors = { jsonSourceFile:Diagnostics()[1] }
    end
    return config, errors
end

-- ParseConfigHost interface: host:FS() (vfs.FS), host:GetCurrentDirectory().

-- resolverHost embeds ParseConfigHost and adds Trace.
function tsoptions.newResolverHost(host)
    local r = {}
    function r:FS()
        return host:FS()
    end
    function r:GetCurrentDirectory()
        return host:GetCurrentDirectory()
    end
    function r:Trace(msg)
    end
    return r
end

function tsoptions.ParseJsonSourceFileConfigFileContent(
    sourceFile,
    host,
    basePath,
    existingOptions,
    existingOptionsRaw,
    configFileName,
    resolutionStack,
    extendedConfigCache
)
    -- tracing?.push(tracing.Phase.Parse, "parseJsonSourceFileConfigFileContent", { path: sourceFile.fileName });
    local result = tsoptions.parseJsonConfigFileContentWorker(nil --[[json]], sourceFile, host, basePath, existingOptions, existingOptionsRaw, configFileName, resolutionStack, extendedConfigCache)
    -- tracing?.pop();
    return result
end

-- Returns *OrderedMap (or nil when not returnValue), errors.
function tsoptions.convertObjectLiteralExpressionToJson(
    sourceFile,
    returnValue,
    node,
    objectOption,
    jsonConversionNotifier
)
    local result = nil
    if returnValue then
        result = newOrderedMap()
    end
    local errors = nil
    for _, element in ipairs(node.properties.nodes) do
        if element.kind ~= Kind.PropertyAssignment then
            errors = core.Append(errors, ast.NewDiagnostic(sourceFile, element.loc, diagnostics.Property_assignment_expected))
            goto continue
        end

        do
            local token = element:QuestionToken()
            if token ~= nil then
                errors = core.Append(errors, ast.NewDiagnostic(sourceFile, token.loc, diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, "?"))
            end
            local textOfKey = ""
            if not ast.IsComputedNonLiteralName(element:Name()) then
                textOfKey = ast.TryGetTextOfPropertyName(element:Name())
            end
            local keyText = textOfKey
            local option = nil
            if keyText ~= "" and objectOption ~= nil and objectOption.elementOptions ~= nil then
                option = tsoptions.CommandLineOptionNameMap_Get(objectOption.elementOptions, keyText)
                if option ~= nil and option.name ~= keyText then
                    option = nil
                end
            end
            local value, err = tsoptions.convertPropertyValueToJson(sourceFile, element.initializer, option, returnValue, jsonConversionNotifier)
            errors = appendAll(errors, err)
            if keyText ~= "" then
                if returnValue then
                    result:Set(keyText, value)
                end
                -- Notify key value set, if user asked for it
                if jsonConversionNotifier ~= nil then
                    local _, err2 = jsonConversionNotifier.onPropertySet(keyText, value, element, objectOption, option)
                    errors = appendAll(errors, err2)
                end
            end
        end
        ::continue::
    end
    return result, errors
end

-- convertToJson converts the json syntax tree into the json value and report errors
-- This returns the json value (apart from checking errors) only if returnValue provided is true.
-- Otherwise it just checks the errors and returns undefined
function tsoptions.convertToJson(
    sourceFile,
    rootExpression,
    returnValue,
    jsonConversionNotifier
)
    if rootExpression == nil then
        if returnValue then
            return tsoptions.emptyStruct, nil
        else
            return nil, nil
        end
    end
    local rootOptions = nil
    if jsonConversionNotifier ~= nil then
        rootOptions = jsonConversionNotifier.rootOptions
    end
    return tsoptions.convertPropertyValueToJson(sourceFile, rootExpression, rootOptions, returnValue, jsonConversionNotifier)
end

function tsoptions.isDoubleQuotedString(node)
    return ast.IsStringLiteral(node)
end

-- Returns value, errors.
function tsoptions.convertPropertyValueToJson(sourceFile, valueExpression, option, returnValue, jsonConversionNotifier)
    local kind = valueExpression.kind
    if kind == Kind.TrueKeyword then
        return true, nil
    elseif kind == Kind.FalseKeyword then
        return false, nil
    elseif kind == Kind.NullKeyword then -- todo: how to manage null
        return nil, nil
    elseif kind == Kind.StringLiteral then
        if not tsoptions.isDoubleQuotedString(valueExpression) then
            return valueExpression:Text(), { ast.NewDiagnostic(sourceFile, valueExpression.loc, diagnostics.String_literal_with_double_quotes_expected) }
        end
        return valueExpression:Text(), nil
    elseif kind == Kind.NumericLiteral then
        return jsnum.FromString(valueExpression:Text()) + 0.0, nil
    elseif kind == Kind.PrefixUnaryExpression then
        if valueExpression.operator == Kind.MinusToken and valueExpression.operand.kind == Kind.NumericLiteral then
            return -(jsnum.FromString(valueExpression.operand:Text()) + 0.0), nil
        end
        -- not valid JSON syntax
    elseif kind == Kind.ObjectLiteralExpression then
        -- Currently having element option declaration in the tsconfig with type "object"
        -- determines if it needs onSetValidOptionKeyValueInParent callback or not
        -- At moment there are only "compilerOptions", "typeAcquisition" and "typingOptions"
        -- that satisfies it and need it to modify options set in them (for normalizing file paths)
        -- vs what we set in the json
        -- If need arises, we can modify this interface and callbacks as needed
        return tsoptions.convertObjectLiteralExpressionToJson(sourceFile, returnValue, valueExpression, option, jsonConversionNotifier)
    elseif kind == Kind.ArrayLiteralExpression then
        local result, errors = tsoptions.convertArrayLiteralExpressionToJson(
            sourceFile,
            valueExpression:Elements(),
            option,
            returnValue
        )
        return result, errors
    end
    -- Not in expected format
    local errors
    if option ~= nil then
        errors = { ast.NewDiagnostic(sourceFile, valueExpression.loc, diagnostics.Compiler_option_0_requires_a_value_of_type_1, option.name, tsoptions.getCompilerOptionValueTypeString(option)) }
    else
        errors = { ast.NewDiagnostic(sourceFile, valueExpression.loc, diagnostics.Property_value_can_only_be_string_literal_numeric_literal_true_false_null_object_literal_or_array_literal) }
    end
    return nil, errors
end

-- ParseJsonConfigFileContent parses the contents of a config file (tsconfig.json).
-- jsonNode: The contents of the config file to parse
-- host: Instance of ParseConfigHost used to enumerate files in folder.
-- basePath: A root directory to resolve relative path entries in the config file to. e.g. outDir
function tsoptions.ParseJsonConfigFileContent(json, host, basePath, existingOptions, configFileName, resolutionStack, extendedConfigCache)
    local normalized = tsoptions.normalizeJsonValue(json)
    local jsonObject = normalized
    if not isOrderedMap(normalized) then
        jsonObject = newOrderedMap()
    end
    local result = tsoptions.parseJsonConfigFileContentWorker(jsonObject, nil --[[sourceFile]], host, basePath, existingOptions, nil --[[existingOptionsRaw]], configFileName, resolutionStack, extendedConfigCache)
    return result
end

-- Plain Lua tables stand for both Go map[string]any and []any: a table whose keys are exactly
-- 1..n (or that is empty) is a slice, anything else is a map.
local function isPlainArray(t)
    local n = #t
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count == n
end

function tsoptions.normalizeJsonValue(value)
    if value == tsoptions.NilSlice then
        return {}
    end
    if isOrderedMap(value) then
        local updates = {}
        for key, child in value:Entries() do
            updates[#updates + 1] = { key, tsoptions.normalizeJsonValue(child) }
        end
        for _, u in ipairs(updates) do
            value:Set(u[1], u[2])
        end
        return value
    elseif type(value) == "table" and getmetatable(value) == nil then
        if isPlainArray(value) then
            local result = {}
            for i, child in ipairs(value) do
                result[i] = tsoptions.normalizeJsonValue(child)
            end
            return result
        end
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        local result = newOrderedMap()
        for _, key in ipairs(keys) do
            result:Set(key, tsoptions.normalizeJsonValue(value[key]))
        end
        return result
    end
    return value
end

-- convertToObject converts the json syntax tree into the json value
function tsoptions.convertToObject(sourceFile)
    local rootExpression = nil
    if #sourceFile.statements.nodes ~= 0 then
        rootExpression = sourceFile.statements.nodes[1]:Expression()
    end
    return tsoptions.convertToJson(sourceFile, rootExpression, true --[[returnValue]], nil --[[jsonConversionNotifier]])
end

function tsoptions.getDefaultCompilerOptions(configFileName)
    local options = core.NewCompilerOptions()
    if configFileName ~= "" and tspath.GetBaseFileName(configFileName) == "jsconfig.json" then
        local depth = 2
        options = core.NewCompilerOptions({
            allowJs = core.Tristate.TSTrue,
            maxNodeModuleJsDepth = depth,
            skipLibCheck = core.Tristate.TSTrue,
            noEmit = core.Tristate.TSTrue,
        })
    end
    return options
end

function tsoptions.getDefaultTypeAcquisition(configFileName)
    local options = core.NewTypeAcquisition()
    if configFileName ~= "" and tspath.GetBaseFileName(configFileName) == "jsconfig.json" then
        options.enable = core.Tristate.TSTrue
    end
    return options
end

function tsoptions.convertCompilerOptionsFromJsonWorker(jsonOptions, basePath, configFileName)
    local options = tsoptions.getDefaultCompilerOptions(configFileName)
    local _, errors = tsoptions.convertOptionsFromJson(tsoptions.CommandLineCompilerOptionsMap, jsonOptions, basePath, tsoptions.newCompilerOptionsParser(options))
    if configFileName ~= "" then
        options.configFilePath = tspath.NormalizeSlashes(configFileName)
    end
    return options, errors
end

function tsoptions.convertTypeAcquisitionFromJsonWorker(jsonOptions, basePath, configFileName)
    local options = tsoptions.getDefaultTypeAcquisition(configFileName)
    local _, errors = tsoptions.convertOptionsFromJson(tsoptions.typeAcquisitionDeclaration.elementOptions, jsonOptions, basePath, tsoptions.newTypeAcquisitionParser(options))
    return options, errors
end

function tsoptions.parseOwnConfigOfJson(
    json,
    host,
    basePath,
    configFileName
)
    local errors = nil
    if json:Has("excludes") then
        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Unknown_option_excludes_Did_you_mean_exclude))
    end
    local options, err = tsoptions.convertCompilerOptionsFromJsonWorker(json:GetOrZero("compilerOptions"), basePath, configFileName)
    local typeAcquisition, err2 = tsoptions.convertTypeAcquisitionFromJsonWorker(json:GetOrZero("typeAcquisition"), basePath, configFileName)
    errors = appendAll(appendAll(errors, err), err2)
    local compileOnSave, ok = json:Get("compileOnSave")
    if ok then
        local converted, compileOnSaveErrors = tsoptions.convertJsonOption(tsoptions.compileOnSaveCommandLineOption, compileOnSave, basePath, nil, nil, nil)
        errors = appendAll(errors, compileOnSaveErrors)
        json:Set("compileOnSave", converted)
    end
    local extendedConfigPath = nil
    local extends = json:GetOrZero("extends")
    if extends ~= nil and extends ~= "" then
        extendedConfigPath, err = tsoptions.getExtendsConfigPathOrArray(extends, host, basePath, configFileName, nil, nil, nil)
        errors = appendAll(errors, err)
    end
    local parsedConfig = {
        raw = json,
        options = options,
        typeAcquisition = typeAcquisition,
        extendedConfigPath = extendedConfigPath,
    }
    return parsedConfig, errors
end

-- readFile(fileName) -> text, ok. Returns *TsConfigSourceFile, errors.
function tsoptions.readJsonConfigFile(fileName, path, readFile)
    local text, diagnostic = tsoptions.tryReadFile(fileName, readFile, {})
    if text ~= "" then
        return tsoptions.NewTsConfigSourceFile(
            parser.ParseSourceFile(ast.NewSourceFileParseOptions(fileName, path), text, core.ScriptKind.JSON)
        ), diagnostic
    else
        local factory = ast.NewNodeFactory(nil)
        local file = tsoptions.NewTsConfigSourceFile(
            factory:NewSourceFile(ast.NewSourceFileParseOptions(fileName, path), "", factory:NewNodeList({}), factory:NewToken(Kind.EndOfFile)):AsSourceFile()
        )
        file.sourceFile:SetDiagnostics(diagnostic)
        return file, diagnostic
    end
end

function tsoptions.getExtendedConfig(
    sourceFile,
    extendedConfigFileName,
    host,
    resolutionStack,
    extendedConfigCache,
    result
)
    local errors = nil
    local extendedConfigPath = tspath.ToPath(extendedConfigFileName, host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames())

    local cacheEntry
    -- Bypass the cache when we detect a cycle in the resolution stack.
    -- The cache locks entries during parsing, and a cycle would cause the same goroutine
    -- to re-lock the same entry, resulting in a deadlock. Let parseConfig handle the
    -- circularity error via its own resolution stack check.
    if extendedConfigCache ~= nil and not strings.SliceContains(resolutionStack, extendedConfigPath) then
        cacheEntry = extendedConfigCache:GetExtendedConfig(extendedConfigFileName, extendedConfigPath, resolutionStack, host)
    else
        cacheEntry = tsoptions.ParseExtendedConfig(extendedConfigFileName, extendedConfigPath, resolutionStack, host, extendedConfigCache)
    end

    if core.Len(cacheEntry.errors) > 0 then
        errors = appendAll(errors, cacheEntry.errors)
    end

    if cacheEntry.extendedResult ~= nil then
        if sourceFile ~= nil then
            result.extendedSourceFiles[cacheEntry.extendedResult.sourceFile:FileName()] = true
            for _, extendedSourceFile in ipairs(cacheEntry.extendedResult.extendedSourceFiles or {}) do
                result.extendedSourceFiles[extendedSourceFile] = true
            end
        end
    end
    return cacheEntry.extendedConfig, errors
end

function tsoptions.ParseExtendedConfig(
    fileName,
    path,
    resolutionStack,
    host,
    extendedConfigCache
)
    local extendedResult, readErrors = tsoptions.readJsonConfigFile(fileName, path, function(name)
        return host:FS():ReadFile(name)
    end)
    local entry = setmetatable({
        extendedResult = extendedResult,
        extendedConfig = nil,
        errors = nil,
    }, ExtendedConfigCacheEntry)

    if core.Len(readErrors) > 0 then
        entry.errors = readErrors
        return entry
    end

    local parseDiagnostics = extendedResult.sourceFile:Diagnostics()
    if core.Len(parseDiagnostics) > 0 then
        entry.errors = parseDiagnostics
        return entry
    end

    local parseErrors
    entry.extendedConfig, parseErrors = tsoptions.parseConfig(nil, extendedResult, host, tspath.GetDirectoryPath(fileName), tspath.GetBaseFileName(fileName), resolutionStack, extendedConfigCache)
    entry.errors = parseErrors
    return entry
end

local function omSize(m)
    if m == nil then
        return 0
    end
    return m:Size()
end

local function compareStrings(a, b)
    return strings.Compare(a, b)
end

-- parseConfig just extracts options/include/exclude/files out of a config file.
-- It does not resolve the included files.
-- Returns *parsedTsconfig, errors.
function tsoptions.parseConfig(
    json,
    sourceFile,
    host,
    basePath,
    configFileName,
    resolutionStack,
    extendedConfigCache
)
    basePath = tspath.NormalizeSlashes(basePath)
    local resolvedPath = tspath.ToPath(configFileName, basePath, host:FS():UseCaseSensitiveFileNames())
    local errors = nil
    if strings.SliceContains(resolutionStack, resolvedPath) then
        local result
        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Circularity_detected_while_resolving_configuration_Colon_0))
        if omSize(json) == 0 then
            result = { raw = json }
        else
            local rawResult, err = tsoptions.convertToObject(sourceFile.sourceFile)
            errors = appendAll(errors, err)
            result = { raw = rawResult }
        end
        return result, errors
    end

    local ownConfig, err
    if json ~= nil then
        ownConfig, err = tsoptions.parseOwnConfigOfJson(json, host, basePath, configFileName)
    else
        ownConfig, err = tsoptions.parseOwnConfigOfJsonSourceFile(tsoptions.tsconfigToSourceFile(sourceFile), host, basePath, configFileName)
    end
    errors = appendAll(errors, err)
    if ownConfig.options ~= nil and ownConfig.options.paths ~= nil then
        -- If we end up needing to resolve relative paths from 'paths' relative to
        -- the config file location, we'll need to know where that config file was.
        -- Since 'paths' can be inherited from an extended config in another directory,
        -- we wouldn't know which directory to use unless we store it here.
        ownConfig.options.pathsBasePath = basePath
    end

    local function applyExtendedConfig(result, extendedConfigPath)
        local extendedConfig, extendedErrors = tsoptions.getExtendedConfig(sourceFile, extendedConfigPath, host, resolutionStack, extendedConfigCache, result)
        errors = appendAll(errors, extendedErrors)
        if extendedConfig ~= nil and extendedConfig.options ~= nil then
            local extendsRaw = extendedConfig.raw
            local relativeDifference = ""
            local function setPropertyValue(propertyName)
                if isOrderedMap(ownConfig.raw) and ownConfig.raw:Has(propertyName) then
                    return
                end
                if propertyName == "include" or propertyName == "exclude" or propertyName == "files" then
                    if isOrderedMap(extendsRaw) and extendsRaw:Has(propertyName) then
                        local slice = tsoptions.asAnySlice(extendsRaw:GetOrZero(propertyName))
                        if slice ~= nil then
                            local value = core.Map(slice, function(path)
                                if type(path) ~= "string" then
                                    return path
                                end
                                local pathStr = path
                                if tsoptions.startsWithConfigDirTemplate(path) or tspath.IsRootedDiskPath(pathStr) then
                                    return pathStr
                                else
                                    if relativeDifference == "" then
                                        local t = tspath.NewComparePathsOptions(
                                            host:FS():UseCaseSensitiveFileNames(),
                                            basePath
                                        )
                                        relativeDifference = tspath.ConvertToRelativePath(tspath.GetDirectoryPath(extendedConfigPath), t)
                                    end
                                    return tspath.CombinePaths(relativeDifference, pathStr)
                                end
                            end)
                            if propertyName == "include" then
                                result.include = value
                            elseif propertyName == "exclude" then
                                result.exclude = value
                            elseif propertyName == "files" then
                                result.files = value
                            end
                        end
                    end
                end
            end

            setPropertyValue("include")
            setPropertyValue("exclude")
            setPropertyValue("files")
            if isOrderedMap(extendsRaw) and extendsRaw:Has("contentMappers") then
                result.contentMappers = tsoptions.asAnySlice(extendsRaw:GetOrZero("contentMappers"))
            end
            if isOrderedMap(extendsRaw) and extendsRaw:Has("compileOnSave") then
                local compileOnSave = extendsRaw:GetOrZero("compileOnSave")
                if type(compileOnSave) == "boolean" then
                    result.compileOnSave = compileOnSave
                end
            end
            tsoptions.mergeCompilerOptions(result.options, extendedConfig.options, extendsRaw)
        end
    end

    if ownConfig.extendedConfigPath ~= nil then
        -- copy the resolution stack so it is never reused between branches in potential diamond-problem scenarios.
        resolutionStack = core.Append(core.Slice(resolutionStack, 0), resolvedPath)
        local result = {
            options = core.NewCompilerOptions(),
            include = nil,
            exclude = nil,
            files = nil,
            contentMappers = nil,
            compileOnSave = false,
            extendedSourceFiles = {},
        }
        if type(ownConfig.extendedConfigPath) == "string" then
            applyExtendedConfig(result, ownConfig.extendedConfigPath)
        elseif isSlice(ownConfig.extendedConfigPath) then
            for _, extendedConfigPath in ipairs(ownConfig.extendedConfigPath) do
                applyExtendedConfig(result, extendedConfigPath)
            end
        end
        if result.include ~= nil then
            ownConfig.raw:Set("include", result.include)
        end
        if result.exclude ~= nil then
            ownConfig.raw:Set("exclude", result.exclude)
        end
        if result.files ~= nil then
            ownConfig.raw:Set("files", result.files)
        end
        if result.contentMappers ~= nil and not ownConfig.raw:Has("contentMappers") then
            ownConfig.raw:Set("contentMappers", result.contentMappers)
        end
        if result.compileOnSave and not ownConfig.raw:Has("compileOnSave") then
            ownConfig.raw:Set("compileOnSave", result.compileOnSave)
        end
        if sourceFile ~= nil then
            for extendedSourceFile in pairs(result.extendedSourceFiles) do
                sourceFile.extendedSourceFiles = core.InsertSorted(sourceFile.extendedSourceFiles, extendedSourceFile, compareStrings)
            end
        end
        ownConfig.options = tsoptions.mergeCompilerOptions(result.options, ownConfig.options, ownConfig.raw)
    end
    return ownConfig, errors
end

tsoptions.defaultIncludeSpec = "**/*"

-- propOfRaw: { sliceValue = []any or nil, wrongValue = string }

function tsoptions.isStringValue(value)
    return type(value) == "string"
end

local function isObjectValue(element)
    return isOrderedMap(element)
end

-- parseJsonConfigFileContentWorker parses the contents of a config file from json or json source file (tsconfig.json).
-- json: The contents of the config file to parse
-- sourceFile: sourceFile corresponding to the Json
-- host: Instance of ParseConfigHost used to enumerate files in folder.
-- basePath: A root directory to resolve relative path entries in the config file to. e.g. outDir
-- resolutionStack: Only present for backwards-compatibility. Should be empty.
function tsoptions.parseJsonConfigFileContentWorker(
    json,
    sourceFile,
    host,
    basePath,
    existingOptions,
    existingOptionsRaw,
    configFileName,
    resolutionStack,
    extendedConfigCache
)
    debug.Assert((json == nil and sourceFile ~= nil) or (json ~= nil and sourceFile == nil))
    configFileName = configFileName or ""

    local basePathForFileNames
    if configFileName ~= "" then
        basePathForFileNames = tspath.NormalizePath(tsoptions.directoryOfCombinedPath(configFileName, basePath))
    else
        basePathForFileNames = tspath.NormalizePath(basePath)
    end

    local parsedConfig, errors = tsoptions.parseConfig(json, sourceFile, host, basePath, configFileName, resolutionStack, extendedConfigCache)
    tsoptions.mergeCompilerOptions(parsedConfig.options, existingOptions, existingOptionsRaw)
    tsoptions.handleOptionConfigDirTemplateSubstitution(parsedConfig.options, basePathForFileNames)
    local rawConfig = tsoptions.parseJsonToStringKey(parsedConfig.raw)
    if configFileName ~= "" and parsedConfig.options ~= nil then
        parsedConfig.options.configFilePath = tspath.NormalizeSlashes(configFileName)
    end
    local function getPropFromRaw(prop, validateElement, elementTypeName)
        local value, exists = rawConfig:Get(prop)
        if exists and value ~= nil then
            if isSlice(value) then
                local result = rawConfig:GetOrZero(prop)
                if tsoptions.asAnySlice(result) ~= nil or result == tsoptions.NilSlice then
                    if sourceFile == nil and not core.Every(result, validateElement) then
                        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, prop, elementTypeName))
                    end
                end
                return { sliceValue = tsoptions.asAnySlice(result), wrongValue = "" }
            elseif sourceFile == nil then
                errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Compiler_option_0_requires_a_value_of_type_1, prop, "Array"))
                return { sliceValue = nil, wrongValue = "not-array" }
            end
        end
        return { sliceValue = nil, wrongValue = "no-prop" }
    end
    local referencesOfRaw = getPropFromRaw("references", isObjectValue, "object")
    local fileSpecs = getPropFromRaw("files", tsoptions.isStringValue, "string")
    if fileSpecs.sliceValue ~= nil or fileSpecs.wrongValue == "" then
        local hasZeroOrNoReferences = false
        if referencesOfRaw.wrongValue == "no-prop" or referencesOfRaw.wrongValue == "not-array" or core.Len(referencesOfRaw.sliceValue) == 0 then
            hasZeroOrNoReferences = true
        end
        local hasExtends = rawConfig:GetOrZero("extends")
        if fileSpecs.sliceValue ~= nil and #fileSpecs.sliceValue == 0 and hasZeroOrNoReferences and hasExtends == nil then
            if sourceFile ~= nil then
                local fileName
                if configFileName ~= "" then
                    fileName = configFileName
                else
                    fileName = "tsconfig.json"
                end
                local diagnosticMessage = diagnostics.The_files_list_in_config_file_0_is_empty
                local nodeValue = tsoptions.ForEachTsConfigPropArray(sourceFile.sourceFile, "files", function(property) return property.initializer end)
                errors = core.Append(errors, tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile.sourceFile, nodeValue, diagnosticMessage, fileName))
            else
                errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.The_files_list_in_config_file_0_is_empty, configFileName))
            end
        end
    end
    local includeSpecs = getPropFromRaw("include", tsoptions.isStringValue, "string")
    local excludeSpecs = getPropFromRaw("exclude", tsoptions.isStringValue, "string")
    local isDefaultIncludeSpec = false
    if excludeSpecs.wrongValue == "no-prop" and parsedConfig.options ~= nil then
        local outDir = parsedConfig.options.outDir
        local declarationDir = parsedConfig.options.declarationDir
        if outDir ~= "" or declarationDir ~= "" then
            local values = nil
            if outDir ~= "" then
                values = core.Append(values, outDir)
            end
            if declarationDir ~= "" then
                values = core.Append(values, declarationDir)
            end
            excludeSpecs = { sliceValue = values, wrongValue = "" }
        end
    end
    if fileSpecs.sliceValue == nil and includeSpecs.sliceValue == nil then
        includeSpecs = { sliceValue = { tsoptions.defaultIncludeSpec }, wrongValue = "" }
        isDefaultIncludeSpec = true
    end
    local validatedIncludeSpecs = nil
    local validatedIncludeSpecsBeforeSubstitution = nil
    local validatedExcludeSpecs = nil
    local validatedFilesSpec = nil
    local validatedFilesSpecBeforeSubstitution = nil
    -- The exclude spec list is converted into a regular expression, which allows us to quickly
    -- test whether a file or directory should be excluded before recursively traversing the
    -- file system.
    if includeSpecs.sliceValue ~= nil then
        local err
        validatedIncludeSpecsBeforeSubstitution, err = tsoptions.validateSpecs(includeSpecs.sliceValue, true --[[disallowTrailingRecursion]], tsoptions.tsconfigToSourceFile(sourceFile), "include")
        errors = appendAll(errors, err)
        validatedIncludeSpecs = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(validatedIncludeSpecsBeforeSubstitution, basePathForFileNames)
        if validatedIncludeSpecs == nil then
            validatedIncludeSpecs = validatedIncludeSpecsBeforeSubstitution
        end
    end
    if excludeSpecs.sliceValue ~= nil then
        local err
        validatedExcludeSpecs, err = tsoptions.validateSpecs(excludeSpecs.sliceValue, false --[[disallowTrailingRecursion]], tsoptions.tsconfigToSourceFile(sourceFile), "exclude")
        errors = appendAll(errors, err)
        local validatedExcludeSpecsWithSubstitution = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(validatedExcludeSpecs, basePathForFileNames)
        if validatedExcludeSpecsWithSubstitution ~= nil then
            validatedExcludeSpecs = validatedExcludeSpecsWithSubstitution
        end
    end
    if fileSpecs.sliceValue ~= nil then
        local specs = core.Filter(fileSpecs.sliceValue, tsoptions.isStringValue)
        for _, spec in ipairs(specs) do
            if type(spec) == "string" then
                validatedFilesSpecBeforeSubstitution = core.Append(validatedFilesSpecBeforeSubstitution, spec)
            end
        end
        validatedFilesSpec = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(validatedFilesSpecBeforeSubstitution, basePathForFileNames)
        if validatedFilesSpec == nil then
            validatedFilesSpec = validatedFilesSpecBeforeSubstitution
        end
    end
    local specs = setmetatable({
        filesSpecs = fileSpecs.sliceValue,
        includeSpecs = includeSpecs.sliceValue,
        excludeSpecs = excludeSpecs.sliceValue,
        validatedFilesSpec = validatedFilesSpec,
        validatedIncludeSpecs = validatedIncludeSpecs,
        validatedExcludeSpecs = validatedExcludeSpecs,
        validatedFilesSpecBeforeSubstitution = validatedFilesSpecBeforeSubstitution,
        validatedIncludeSpecsBeforeSubstitution = validatedIncludeSpecsBeforeSubstitution,
        isDefaultIncludeSpec = isDefaultIncludeSpec,
    }, configFileSpecs)

    if sourceFile ~= nil then
        sourceFile.configFileSpecs = specs
    end

    local contentMapperSourceFile = nil
    if sourceFile ~= nil then
        contentMapperSourceFile = sourceFile.sourceFile
    end
    local contentMappers = nil
    local contentMapperIndices = nil
    local contentMappersOfRaw = getPropFromRaw("contentMappers", isObjectValue, "object")
    for i1, element in ipairs(contentMappersOfRaw.sliceValue or {}) do
        local i = i1 - 1
        local mapper, mapperErrors = tsoptions.parseContentMapper(element)
        for _, mapperError in ipairs(mapperErrors or {}) do
            errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(mapperError, contentMapperSourceFile, tsoptions.getContentMapperSyntax(contentMapperSourceFile, i, "")))
        end
        if mapper ~= nil then
            contentMappers = core.Append(contentMappers, mapper)
            contentMapperIndices = core.Append(contentMapperIndices, i)
        end
    end
    local seenContentMapperExtensions = {}
    local contentMapperExtensions = {}
    local nativeExtensions = core.Flatten(tspath.AllSupportedExtensionsWithJson)
    for j1, mapper in ipairs(contentMappers or {}) do
        local validExtensions = {}
        for _, ext in ipairs(mapper.definition.extensions or {}) do
            local extNode = tsoptions.getContentMapperExtensionSyntax(contentMapperSourceFile, contentMapperIndices[j1], ext)
            if not strings.HasPrefix(ext, ".") then
                errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(ast.NewCompilerDiagnostic(diagnostics.Content_mapper_file_extension_0_must_begin_with_a, ext), contentMapperSourceFile, extNode))
            elseif strings.SliceContains(nativeExtensions, ext) then
                errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(ast.NewCompilerDiagnostic(diagnostics.Content_mapper_file_extension_0_is_a_built_in_extension_and_cannot_be_registered_by_a_content_mapper, ext), contentMapperSourceFile, extNode))
            else
                if seenContentMapperExtensions[ext] then
                    errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(ast.NewCompilerDiagnostic(diagnostics.Content_mapper_file_extension_0_is_registered_by_more_than_one_content_mapper, ext), contentMapperSourceFile, extNode))
                else
                    seenContentMapperExtensions[ext] = true
                    contentMapperExtensions[#contentMapperExtensions + 1] = ext
                    validExtensions[#validExtensions + 1] = ext
                end
            end
        end
        mapper.definition.extensions = validExtensions
    end
    if core.Len(contentMappers) > 0 and not (parsedConfig.options ~= nil and core.Tristate_IsTrue(parsedConfig.options.runExternalCode)) then
        errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(ast.NewCompilerDiagnostic(diagnostics.Content_mappers_require_the_runExternalCode_command_line_flag_to_be_enabled), contentMapperSourceFile, tsoptions.getContentMappersKeySyntax(contentMapperSourceFile)))
        -- Without the flag the mappers are not trusted to run, so drop them entirely: their extensions are
        -- not registered and their files are not intercepted (they are treated as unknown foreign files).
        contentMappers = nil
        contentMapperExtensions = nil
    elseif core.Len(contentMappers) > 0 then
        -- Resolve each mapper's package.json now so its name, version, and run command are available to
        -- everything downstream (diagnostics, build-info staleness) without executing anything.
        local containingFile = configFileName
        if containingFile == "" then
            containingFile = tspath.CombinePaths(basePathForFileNames, "tsconfig.json")
        end
        local resolvedContentMappers = {}
        for j1, mapper in ipairs(contentMappers) do
            local manifest, packageDirectory, diagnostic = tsoptions.resolveContentMapperManifest(host, containingFile, mapper.package)
            mapper.packageDirectory = packageDirectory
            if diagnostic ~= nil then
                errors = core.Append(errors, tsoptions.setContentMapperDiagnosticLocation(diagnostic, contentMapperSourceFile, tsoptions.getContentMapperSyntax(contentMapperSourceFile, contentMapperIndices[j1], "package")))
            else
                mapper.manifest = manifest
                resolvedContentMappers[#resolvedContentMappers + 1] = mapper
            end
        end
        contentMappers = resolvedContentMappers
        contentMapperExtensions = core.FlatMap(contentMappers, function(m)
            return m.definition.extensions
        end)
    end

    local function getFileNames(base)
        local parsedConfigOptions = parsedConfig.options
        local fileNames, literalFileNamesLen = tsoptions.getFileNamesFromConfigSpecs(specs, base, parsedConfigOptions, host:FS(), contentMapperExtensions)
        if tsoptions.shouldReportNoInputFiles(fileNames, tsoptions.canJsonReportNoInputFiles(rawConfig), resolutionStack) then
            local includeSpecsValue = specs.includeSpecs
            local excludeSpecsValue = specs.excludeSpecs
            if includeSpecsValue == nil then
                includeSpecsValue = {}
            end
            if excludeSpecsValue == nil then
                excludeSpecsValue = {}
            end
            errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.No_inputs_were_found_in_config_file_0_Specified_include_paths_were_1_and_exclude_paths_were_2, configFileName, core.Must(core.StringifyJson(includeSpecsValue, "", "")), core.Must(core.StringifyJson(excludeSpecsValue, "", ""))))
        end
        return fileNames, literalFileNamesLen
    end

    local function getProjectReferences(base)
        local projectReferences = nil
        local newReferencesOfRaw = getPropFromRaw("references", isObjectValue, "object")
        if newReferencesOfRaw.sliceValue ~= nil then
            projectReferences = {}
            for index1, reference in ipairs(newReferencesOfRaw.sliceValue) do
                local index = index1 - 1
                local ref = tsoptions.parseProjectReference(reference)
                if ref ~= nil then
                    if not ref.hasPath or not ref.pathValid then
                        errors = core.Append(errors, tsoptions.createDiagnosticAtProjectReferenceProperty(sourceFile, index, "path", diagnostics.Compiler_option_0_requires_a_value_of_type_1, "reference.path", "string"))
                    elseif ref.reference.path == "" then
                        errors = core.Append(errors, tsoptions.createDiagnosticAtProjectReferenceProperty(sourceFile, index, "path", diagnostics.Compiler_option_0_cannot_be_given_an_empty_string, "reference.path"))
                    else
                        if ref.hasCircular and not ref.circularValid then
                            errors = core.Append(errors, tsoptions.createDiagnosticAtProjectReferenceProperty(sourceFile, index, "circular", diagnostics.Compiler_option_0_requires_a_value_of_type_1, "reference.circular", "boolean"))
                        end
                        projectReferences[#projectReferences + 1] = core.NewProjectReference({
                            path = tspath.GetNormalizedAbsolutePath(ref.reference.path, base),
                            originalPath = ref.reference.path,
                            circular = ref.reference.circular,
                        })
                    end
                end
            end
        end
        return projectReferences
    end

    local fileNames, literalFileNamesLen = getFileNames(basePathForFileNames)
    local compileOnSave = false
    if isOrderedMap(parsedConfig.raw) then
        local value = parsedConfig.raw:GetOrZero("compileOnSave")
        if type(value) == "boolean" then
            compileOnSave = value
        end
    end
    local parsedOptions = tsoptions.NewParsedOptions({
        compilerOptions = parsedConfig.options,
        typeAcquisition = parsedConfig.typeAcquisition,
        fileNames = fileNames,
        projectReferences = getProjectReferences(basePathForFileNames),
        contentMappers = contentMappers,
    })
    local result = tsoptions.newParsedCommandLineStruct({
        parsedConfig = parsedOptions,
        configFile = sourceFile,
        raw = parsedConfig.raw,
        errors = errors,
        compileOnSave = compileOnSave,

        comparePathsOptions = tspath.NewComparePathsOptions(
            host:FS():UseCaseSensitiveFileNames(),
            basePathForFileNames
        ),
        literalFileNamesLen = literalFileNamesLen,
    })
    return result
end

function tsoptions.canJsonReportNoInputFiles(rawConfig)
    local filesExists = rawConfig:Has("files")
    local referencesExists = rawConfig:Has("references")
    return not filesExists and not referencesExists
end

function tsoptions.shouldReportNoInputFiles(fileNames, canJsonReportNoInputFiles, resolutionStack)
    return core.Len(fileNames) == 0 and canJsonReportNoInputFiles and core.Len(resolutionStack) == 0
end

-- Returns specs, errors.
function tsoptions.validateSpecs(specs, disallowTrailingRecursion, jsonSourceFile, specKey)
    local function createDiagnostic(message, spec)
        local element = tsoptions.GetTsConfigPropArrayElementValue(jsonSourceFile, specKey, spec)
        local node = nil
        if element ~= nil then
            node = element
        end
        return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(jsonSourceFile, node, message, spec)
    end
    local errors = nil
    local finalSpecs = nil
    for _, value in ipairs(specs) do
        if type(value) == "string" then
            local spec = value
            local diag = tsoptions.specToDiagnostic(spec, disallowTrailingRecursion)
            if diag ~= nil then
                errors = core.Append(errors, createDiagnostic(diag, spec))
            else
                finalSpecs = core.Append(finalSpecs, spec)
            end
        end
    end
    return finalSpecs, errors
end

function tsoptions.specToDiagnostic(spec, disallowTrailingRecursion)
    if disallowTrailingRecursion and tsoptions.invalidTrailingRecursion(spec) then
        return diagnostics.File_specification_cannot_end_in_a_recursive_directory_wildcard_Asterisk_Asterisk_Colon_0
    end
    if tsoptions.invalidDotDotAfterRecursiveWildcard(spec) then
        return diagnostics.File_specification_cannot_contain_a_parent_directory_that_appears_after_a_recursive_directory_wildcard_Asterisk_Asterisk_Colon_0
    end
    return nil
end

function tsoptions.invalidTrailingRecursion(spec)
    -- Matches **, /**, **/, and /**/, but not a**b.
    -- Strip optional trailing slash, then check if it ends with /** or is just **
    local s = strings.TrimSuffix(spec, "/")
    return s == "**" or strings.HasSuffix(s, "/**")
end

function tsoptions.invalidDotDotAfterRecursiveWildcard(s)
    -- We used to use the regex /(^|\/)\*\*\/(.*\/)?\.\.($|\/)/ to check for this case, but
    -- in v8, that has polynomial performance because the recursive wildcard match - **/ -
    -- can be matched in many arbitrary positions when multiple are present, resulting
    -- in bad backtracking (and we don't care which is matched - just that some /.. segment
    -- comes after some **/ segment).
    local wildcardIndex
    if strings.HasPrefix(s, "**/") then
        wildcardIndex = 0
    else
        wildcardIndex = strings.Index(s, "/**/")
    end
    if wildcardIndex == -1 then
        return false
    end
    local lastDotIndex
    if strings.HasSuffix(s, "/..") then
        lastDotIndex = #s
    else
        lastDotIndex = strings.LastIndex(s, "/../")
    end
    return lastDotIndex > wildcardIndex
end

function tsoptions.GetTsConfigPropArrayElementValue(tsConfigSourceFile, propKey, elementValue)
    local callback = tsoptions.GetCallbackForFindingPropertyAssignmentByValue(elementValue)
    return tsoptions.ForEachTsConfigPropArray(tsConfigSourceFile, propKey, function(property)
        local value = callback(property)
        if value ~= nil then
            return value:AsStringLiteral()
        end
        return nil
    end)
end

function tsoptions.ForEachTsConfigPropArray(tsConfigSourceFile, propKey, callback)
    if tsConfigSourceFile ~= nil then
        return tsoptions.ForEachPropertyAssignment(tsoptions.getTsConfigObjectLiteralExpression(tsConfigSourceFile), propKey, callback)
    end
    return nil
end

function tsoptions.CreateDiagnosticAtReferenceSyntax(config, index, message, ...)
    local args = table.pack(...)
    return tsoptions.ForEachTsConfigPropArray(config.configFile.sourceFile, "references", function(property)
        if ast.IsArrayLiteralExpression(property.initializer) then
            local value = property.initializer:Elements()
            if #value > index then
                return tsoptions.CreateDiagnosticForNodeInSourceFile(config.configFile.sourceFile, value[index + 1], message, table.unpack(args, 1, args.n))
            end
        end
        return nil
    end)
end

function tsoptions.createDiagnosticAtProjectReferenceProperty(sourceFile, index, propertyName, message, ...)
    local node = nil
    if sourceFile ~= nil then
        node = tsoptions.ForEachTsConfigPropArray(sourceFile.sourceFile, "references", function(property)
            if ast.IsArrayLiteralExpression(property.initializer) then
                local elements = property.initializer:Elements()
                if #elements > index and ast.IsObjectLiteralExpression(elements[index + 1]) then
                    local propertyNode = tsoptions.ForEachPropertyAssignment(elements[index + 1]:AsObjectLiteralExpression(), propertyName, function(p)
                        return p.initializer
                    end)
                    if propertyNode ~= nil then
                        return propertyNode
                    end
                    return elements[index + 1]
                end
            end
            return nil
        end)
    end
    return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(tsoptions.tsconfigToSourceFile(sourceFile), node, message, ...)
end

function tsoptions.GetCallbackForFindingPropertyAssignmentByValue(value)
    return function(property)
        if ast.IsArrayLiteralExpression(property.initializer) then
            return core.Find(property.initializer:Elements(), function(element)
                return ast.IsStringLiteral(element) and element:Text() == value
            end)
        end
        return nil
    end
end

function tsoptions.GetOptionsSyntaxByArrayElementValue(objectLiteral, propKey, elementValue)
    return tsoptions.ForEachPropertyAssignment(objectLiteral, propKey, tsoptions.GetCallbackForFindingPropertyAssignmentByValue(elementValue))
end

-- getContentMapperSyntax returns the tsconfig JSON node to attribute a diagnostic about the content
-- mapper at index to: the value of subKey within that mapper's object (when subKey is non-empty),
-- falling back to the mapper element, then to the "contentMappers" array. An index outside the array
-- (e.g. -1) yields the array itself. Returns nil when there is no source file (JSON API).
function tsoptions.getContentMapperSyntax(sourceFile, index, subKey)
    if sourceFile == nil then
        return nil
    end
    return tsoptions.ForEachTsConfigPropArray(sourceFile, "contentMappers", function(property)
        if not ast.IsArrayLiteralExpression(property.initializer) then
            return property.initializer
        end
        local elements = property.initializer:Elements()
        if index < 0 or index >= #elements then
            return property.initializer
        end
        local element = elements[index + 1]
        if subKey ~= "" and ast.IsObjectLiteralExpression(element) then
            local node = tsoptions.ForEachPropertyAssignment(element:AsObjectLiteralExpression(), subKey, function(p)
                return p.initializer
            end)
            if node ~= nil then
                return node
            end
        end
        return element
    end)
end

-- path: []contentmapper.OptionPathSegment { isIndex = bool, index = int, property = string }.
-- Returns sourceFile, core.TextRange.
function tsoptions.GetContentMapperOptionDiagnosticLocation(config, mapper, path)
    if config == nil or config.configFile == nil then
        return nil, core.UndefinedTextRange()
    end
    local index = core.FindIndex(config:ContentMappers(), function(m) return m == mapper end)
    local mapperNode = tsoptions.getContentMapperSyntax(config.configFile.sourceFile, index, "")
    local node = tsoptions.getContentMapperSyntax(config.configFile.sourceFile, index, "options")
    if node == nil then
        node = mapperNode
    end
    for _, segment in ipairs(path or {}) do
        local nextNode = nil
        if segment.isIndex and ast.IsArrayLiteralExpression(node) then
            local elements = node:Elements()
            if segment.index < #elements then
                nextNode = elements[segment.index + 1]
            end
        elseif not segment.isIndex and ast.IsObjectLiteralExpression(node) then
            nextNode = tsoptions.ForEachPropertyAssignment(node:AsObjectLiteralExpression(), segment.property, function(p)
                return p.initializer
            end)
        end
        if nextNode == nil then
            break
        end
        node = nextNode
    end
    if node == nil then
        return nil, core.UndefinedTextRange()
    end
    local file = config.configFile.sourceFile
    return file, core.NewTextRange(scanner.SkipTrivia(file:Text(), node:Pos()), node:End())
end

-- getContentMappersKeySyntax returns the "contentMappers" property key node, used to attribute a
-- diagnostic about the setting as a whole rather than a specific mapper.
function tsoptions.getContentMappersKeySyntax(sourceFile)
    if sourceFile == nil then
        return nil
    end
    return tsoptions.ForEachTsConfigPropArray(sourceFile, "contentMappers", function(property)
        return property:Name()
    end)
end

-- getContentMapperExtensionSyntax returns the node for a specific extension string within the content
-- mapper at index, falling back to the "extensions" array or the mapper element.
function tsoptions.getContentMapperExtensionSyntax(sourceFile, index, ext)
    local node = tsoptions.getContentMapperSyntax(sourceFile, index, "extensions")
    if node ~= nil and ast.IsArrayLiteralExpression(node) then
        local element = core.Find(node:Elements(), function(e)
            return ast.IsStringLiteral(e) and e:Text() == ext
        end)
        if element ~= nil then
            return element
        end
    end
    return node
end

-- setContentMapperDiagnosticLocation attaches a source location to a content mapper diagnostic when a
-- tsconfig source file and node are available (the jsonSourceFile API), leaving it as a location-less
-- compiler diagnostic otherwise (the JSON API).
function tsoptions.setContentMapperDiagnosticLocation(diagnostic, sourceFile, node)
    if sourceFile ~= nil and node ~= nil then
        diagnostic:SetFile(sourceFile)
        diagnostic:SetLocation(core.NewTextRange(scanner.SkipTrivia(sourceFile:Text(), node:Pos()), node:End()))
    end
    return diagnostic
end

function tsoptions.ForEachPropertyAssignment(objectLiteral, key, callback, key2)
    if objectLiteral ~= nil then
        for _, property in ipairs(objectLiteral.properties.nodes) do
            if ast.IsPropertyAssignment(property) then
                local propName, ok = ast.TryGetTextOfPropertyName(property:Name())
                if ok then
                    if propName == key or (key2 ~= nil and key2 == propName) then
                        return callback(property)
                    end
                end
            end
        end
    end
    return nil
end

function tsoptions.getTsConfigObjectLiteralExpression(tsConfigSourceFile)
    if tsConfigSourceFile ~= nil and tsConfigSourceFile.statements ~= nil and #tsConfigSourceFile.statements.nodes > 0 then
        local expression = tsConfigSourceFile.statements.nodes[1]:Expression()
        if ast.IsObjectLiteralExpression(expression) then
            return expression:AsObjectLiteralExpression()
        end
    end
    return nil
end

function tsoptions.getSubstitutedPathWithConfigDirTemplate(value, basePath)
    return tspath.GetNormalizedAbsolutePath(strings.Replace(value, tsoptions.configDirTemplate, "./", 1), basePath)
end

function tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(list, basePath)
    local result = nil
    for i1, element in ipairs(list or {}) do
        if tsoptions.startsWithConfigDirTemplate(element) then
            if result == nil then
                result = core.Slice(list, 0)
            end
            result[i1] = tsoptions.getSubstitutedPathWithConfigDirTemplate(element, basePath)
        end
    end
    if result ~= nil then
        return result
    end
    return nil
end

function tsoptions.handleOptionConfigDirTemplateSubstitution(compilerOptions, basePath)
    if compilerOptions == nil then
        return
    end

    -- !!! don't hardcode this; use options declarations?

    local paths = nil
    if compilerOptions.paths ~= nil then
        local original = compilerOptions.paths
        for k, v in original:Entries() do
            local substitution = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(v, basePath)
            if substitution ~= nil then
                if paths == nil then
                    paths = original:Clone()
                    compilerOptions.paths = paths
                end
                paths:Set(k, substitution)
            end
        end
    end

    local rootDirs = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(compilerOptions.rootDirs, basePath)
    if rootDirs ~= nil then
        compilerOptions.rootDirs = rootDirs
    end
    local typeRoots = tsoptions.getSubstitutedStringArrayWithConfigDirTemplate(compilerOptions.typeRoots, basePath)
    if typeRoots ~= nil then
        compilerOptions.typeRoots = typeRoots
    end
    for _, field in ipairs({ "generateCpuProfile", "generateTrace", "outFile", "outDir", "rootDir", "tsBuildInfoFile", "baseUrl", "declarationDir" }) do
        if tsoptions.startsWithConfigDirTemplate(compilerOptions[field]) then
            compilerOptions[field] = tsoptions.getSubstitutedPathWithConfigDirTemplate(compilerOptions[field], basePath)
        end
    end
end

-- hasFileWithHigherPriorityExtension determines whether a literal or wildcard file has already been included that has a higher extension priority.
-- file is the path to the file.
function tsoptions.hasFileWithHigherPriorityExtension(file, extensions, hasFile)
    local extensionGroup = {}
    for _, group in ipairs(extensions) do
        if tspath.FileExtensionIsOneOf(file, group) then
            for _, e in ipairs(group) do
                extensionGroup[#extensionGroup + 1] = e
            end
        end
    end
    if #extensionGroup == 0 then
        return false
    end
    for _, ext in ipairs(extensionGroup) do
        -- d.ts files match with .ts extension and with case sensitive sorting the file order for same files with ts tsx and dts extension is
        -- d.ts, .ts, .tsx in that order so we need to handle tsx and dts of same same name case here and in remove files with same extensions
        -- So dont match .d.ts files with .ts extension
        if tspath.FileExtensionIs(file, ext) and (ext ~= tspath.ExtensionTs or not tspath.FileExtensionIs(file, tspath.ExtensionDts)) then
            return false
        end
        if hasFile(tspath.ChangeExtension(file, ext)) then
            if ext == tspath.ExtensionDts and (tspath.FileExtensionIs(file, tspath.ExtensionJs) or tspath.FileExtensionIs(file, tspath.ExtensionJsx)) then
                -- LEGACY BEHAVIOR: An off-by-one bug somewhere in the extension priority system for wildcard module loading allowed declaration
                -- files to be loaded alongside their js(x) counterparts. We regard this as generally undesirable, but retain the behavior to
                -- prevent breakage.
            else
                return true
            end
        end
    end
    return false
end

-- Removes files included via wildcard expansion with a lower extension priority that have already been included.
-- file is the path to the file.
function tsoptions.removeWildcardFilesWithLowerPriorityExtension(file, wildcardFiles, extensions, keyMapper)
    local extensionGroup = nil
    for _, group in ipairs(extensions) do
        if tspath.FileExtensionIsOneOf(file, group) then
            extensionGroup = appendAll(extensionGroup, group)
        end
    end
    if extensionGroup == nil then
        return
    end
    for i = #extensionGroup - 1, 0, -1 do
        local ext = extensionGroup[i + 1]
        if tspath.FileExtensionIs(file, ext) then
            return
        end
        local lowerPriorityPath = keyMapper(tspath.ChangeExtension(file, ext))
        wildcardFiles:Delete(lowerPriorityPath)
    end
end

-- getFileNamesFromConfigSpecs gets the file names from the provided config file specs that contain, files, include, exclude and
-- other properties needed to resolve the file names
-- configFileSpecs is the config file specs extracted with file names to include, wildcards to include/exclude and other details
-- basePath is the base path for any relative file specifications.
-- options is the Compiler options.
-- host is the host used to resolve files and directories.
-- extraExtensions are additional file extensions (e.g. from content mappers) to treat as supported.
-- Returns fileNames, literalFileNamesLen.
function tsoptions.getFileNamesFromConfigSpecs(
    specs,
    basePath, -- considering this is the current directory
    options,
    host,
    extraExtensions
)
    basePath = tspath.NormalizePath(basePath)
    local function keyMappper(value)
        return tspath.GetCanonicalFileName(value, host:UseCaseSensitiveFileNames())
    end
    -- Literal file names (provided via the "files" array in tsconfig.json) are stored in a
    -- file map with a possibly case insensitive key. We use this map later when when including
    -- wildcard paths.
    local literalFileMap = newOrderedMap()
    -- Wildcard paths (provided via the "includes" array in tsconfig.json) are stored in a
    -- file map with a possibly case insensitive key. We use this map to store paths matched
    -- via wildcard, and to handle extension priority.
    local wildcardFileMap = newOrderedMap()
    -- Wildcard paths of json files (provided via the "includes" array in tsconfig.json) are stored in a
    -- file map with a possibly case insensitive key. We use this map to store paths matched
    -- via wildcard of *.json kind
    local wildCardJsonFileMap = newOrderedMap()
    local validatedFilesSpec = specs.validatedFilesSpec
    local validatedIncludeSpecs = specs.validatedIncludeSpecs
    local validatedExcludeSpecs = specs.validatedExcludeSpecs
    -- Rather than re-query this for each file and filespec, we query the supported extensions
    -- once and store it on the expansion context.
    local supportedExtensions = tsoptions.GetSupportedExtensions(options, extraExtensions)
    local supportedExtensionsWithJsonIfResolveJsonModule = tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(options, supportedExtensions)
    -- Literal files are always included verbatim. An "include" or "exclude" specification cannot
    -- remove a literal file.
    for _, fileName in ipairs(validatedFilesSpec or {}) do
        local file = tspath.GetNormalizedAbsolutePath(fileName, basePath)
        literalFileMap:Set(keyMappper(fileName), file)
    end

    local jsonOnlyIncludeMatchers = nil
    if core.Len(validatedIncludeSpecs) > 0 then
        local files = vfsmatch.ReadDirectory(host, basePath, basePath, core.Flatten(supportedExtensionsWithJsonIfResolveJsonModule), validatedExcludeSpecs, validatedIncludeSpecs, vfsmatch.UnlimitedDepth)
        for _, file in ipairs(files or {}) do
            if tspath.FileExtensionIs(file, tspath.ExtensionJson) then
                if jsonOnlyIncludeMatchers == nil then
                    local includes = core.Filter(validatedIncludeSpecs, function(include) return strings.HasSuffix(include, tspath.ExtensionJson) end)
                    jsonOnlyIncludeMatchers = vfsmatch.NewSpecMatcher(includes, basePath, vfsmatch.Usage.Files, host:UseCaseSensitiveFileNames())
                end
                local includeIndex = -1
                if jsonOnlyIncludeMatchers ~= nil then
                    includeIndex = jsonOnlyIncludeMatchers:MatchIndex(file)
                end
                if includeIndex ~= -1 then
                    local key = keyMappper(file)
                    if not literalFileMap:Has(key) and not wildCardJsonFileMap:Has(key) then
                        wildCardJsonFileMap:Set(key, file)
                    end
                end
                goto continue
            end
            -- If we have already included a literal or wildcard path with a
            -- higher priority extension, we should skip this file.
            --
            -- This handles cases where we may encounter both <file>.ts and
            -- <file>.d.ts (or <file>.js if "allowJs" is enabled) in the same
            -- directory when they are compilation outputs.
            if tsoptions.hasFileWithHigherPriorityExtension(file, supportedExtensions, function(fileName)
                local canonicalFileName = keyMappper(fileName)
                return literalFileMap:Has(canonicalFileName) or wildcardFileMap:Has(canonicalFileName)
            end) then
                goto continue
            end
            -- We may have included a wildcard path with a lower priority
            -- extension due to the user-defined order of entries in the
            -- "include" array. If there is a lower priority extension in the
            -- same directory, we should remove it.
            tsoptions.removeWildcardFilesWithLowerPriorityExtension(file, wildcardFileMap, supportedExtensions, keyMappper)
            do
                local key = keyMappper(file)
                if not literalFileMap:Has(key) and not wildcardFileMap:Has(key) then
                    wildcardFileMap:Set(key, file)
                end
            end
            ::continue::
        end
    end
    local files = {}
    for file in literalFileMap:Values() do
        files[#files + 1] = file
    end
    for file in wildcardFileMap:Values() do
        files[#files + 1] = file
    end
    for file in wildCardJsonFileMap:Values() do
        files[#files + 1] = file
    end
    return files, literalFileMap:Size()
end

function tsoptions.GetSupportedExtensions(compilerOptions, extraExtensions)
    local needJSExtensions = compilerOptions:GetAllowJS()
    local builtins
    if needJSExtensions then
        builtins = tspath.AllSupportedExtensions
    else
        builtins = tspath.SupportedTSExtensions
    end
    if core.Len(extraExtensions) == 0 then
        return builtins
    end
    local flatBuiltins = core.Flatten(builtins)
    local result = nil
    for _, ext in ipairs(extraExtensions) do
        if not strings.SliceContains(flatBuiltins, ext) then
            result = core.Append(result, { ext })
        end
    end
    if core.Len(result) == 0 then
        return builtins
    end
    return appendAll(core.Slice(builtins, 0), result)
end

function tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(compilerOptions, supportedExtensions)
    if compilerOptions == nil or not compilerOptions:GetResolveJsonModule() then
        return supportedExtensions
    end
    if core.Same(supportedExtensions, tspath.AllSupportedExtensions) then
        return tspath.AllSupportedExtensionsWithJson
    end
    if core.Same(supportedExtensions, tspath.SupportedTSExtensions) then
        return tspath.SupportedTSExtensionsWithJson
    end
    return appendAll(core.Slice(supportedExtensions, 0), { { tspath.ExtensionJson } })
end

-- Reads the config file and reports errors.
-- Returns *ParsedCommandLine, errors.
function tsoptions.GetParsedCommandLineOfConfigFile(
    configFileName,
    options,
    optionsRaw,
    sys,
    extendedConfigCache
)
    configFileName = tspath.GetNormalizedAbsolutePath(configFileName, sys:GetCurrentDirectory())
    return tsoptions.GetParsedCommandLineOfConfigFilePath(configFileName, tspath.ToPath(configFileName, sys:GetCurrentDirectory(), sys:FS():UseCaseSensitiveFileNames()), options, optionsRaw, sys, extendedConfigCache)
end

function tsoptions.GetParsedCommandLineOfConfigFilePath(
    configFileName,
    path,
    options,
    optionsRaw,
    sys,
    extendedConfigCache
)
    local errors = {}
    local configFileText
    configFileText, errors = tsoptions.tryReadFile(configFileName, function(name)
        return sys:FS():ReadFile(name)
    end, errors)
    if #errors > 0 then
        -- these are unrecoverable errors--exit to report them as diagnostics
        return nil, errors
    end

    local tsConfigSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, path, configFileText)
    -- tsConfigSourceFile.resolvedPath = tsConfigSourceFile.FileName()
    -- tsConfigSourceFile.originalFileName = tsConfigSourceFile.FileName()
    return tsoptions.ParseJsonSourceFileConfigFileContent(
        tsConfigSourceFile,
        sys,
        tspath.GetDirectoryPath(configFileName),
        options,
        optionsRaw,
        configFileName,
        nil,
        extendedConfigCache
    ), nil
end

-- Package-level vars that depend on declstypeacquisition.lua; init.lua calls this after loading it
-- (Go initializes package vars in dependency order).
function tsoptions.initTsconfigparsingVars()
    tsoptions.compilerOptionsDeclaration = tsoptions.newCommandLineOption({
        name = "compilerOptions",
        kind = CommandLineOptionKind.CommandLineOptionTypeObject,
        elementOptions = tsoptions.CommandLineCompilerOptionsMap,
    })

    tsoptions.compileOnSaveCommandLineOption = tsoptions.newCommandLineOption({
        name = "compileOnSave",
        kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
        defaultValueDescription = false,
    })

    tsoptions.extendsOptionDeclaration = tsoptions.newCommandLineOption({
        name = "extends",
        kind = CommandLineOptionKind.CommandLineOptionTypeListOrElement,
        category = diagnostics.File_Management,
        elementOptions = tsoptions.commandLineOptionsToMap({
            tsoptions.newCommandLineOption({ name = "extends", kind = CommandLineOptionKind.CommandLineOptionTypeString }),
        }),
    })

    tsoptions.tsconfigRootOptionsMap = tsoptions.newCommandLineOption({
        name = "undefined", -- should never be needed since this is root
        kind = CommandLineOptionKind.CommandLineOptionTypeObject,
        elementOptions = tsoptions.commandLineOptionsToMap({
            tsoptions.compilerOptionsDeclaration,
            tsoptions.typeAcquisitionDeclaration,
            tsoptions.extendsOptionDeclaration,
            tsoptions.newCommandLineOption({
                name = "references",
                kind = CommandLineOptionKind.CommandLineOptionTypeList, -- should be a list of projectReference
                -- Category: diagnostics.Projects,
            }),
            tsoptions.newCommandLineOption({
                name = "contentMappers",
                kind = CommandLineOptionKind.CommandLineOptionTypeList, -- list of content mapper objects
            }),
            tsoptions.newCommandLineOption({
                name = "files",
                kind = CommandLineOptionKind.CommandLineOptionTypeList,
                -- Category: diagnostics.File_Management,
            }),
            tsoptions.newCommandLineOption({
                name = "include",
                kind = CommandLineOptionKind.CommandLineOptionTypeList,
                -- Category: diagnostics.File_Management,
                -- DefaultValueDescription: diagnostics.if_files_is_specified_otherwise_Asterisk_Asterisk_Slash_Asterisk,
            }),
            tsoptions.newCommandLineOption({
                name = "exclude",
                kind = CommandLineOptionKind.CommandLineOptionTypeList,
                -- Category: diagnostics.File_Management,
                -- DefaultValueDescription: diagnostics.Node_modules_bower_components_jspm_packages_plus_the_value_of_outDir_if_one_is_specified,
            }),
            tsoptions.compileOnSaveCommandLineOption,
        }),
    })
end
