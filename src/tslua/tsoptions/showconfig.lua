local tsoptions = require("tslua.tsoptions")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local json = require("tslua.json")
local tspath = require("tslua.tspath")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind
local Tristate = core.Tristate

-- computeFn wraps a typed getter method so it can be stored in an impliedOption's
-- compute field (which has type func(*core.CompilerOptions) any).
function tsoptions.computeFn(fn)
    return function(opts)
        return fn(opts)
    end
end

-- impliedOption describes a compiler option whose effective value can be derived from
-- other options. This mirrors TypeScript's computedOptions concept used in convertToTSConfig.
-- { name = Go struct field name of the CompilerOptions field (e.g., "Module"),
--   dependencies = Go struct field names that this option depends on,
--   compute = returns the effective value of this option given compiler options }

local function method(name)
    return tsoptions.computeFn(function(opts)
        return core.CompilerOptions[name](opts)
    end)
end

-- impliedOptions lists the compiler options that may be implied by other options,
-- mirroring TypeScript's computedOptions used in convertToTSConfig.
-- Each compute function delegates directly to an existing core.CompilerOptions getter.
tsoptions.impliedOptions = {
    { name = "Module", dependencies = { "Target" }, compute = method("GetEmitModuleKind") },
    { name = "ModuleResolution", dependencies = { "Module", "Target" }, compute = method("GetModuleResolutionKind") },
    { name = "ModuleDetection", dependencies = { "Module", "Target" }, compute = method("GetEmitModuleDetectionKind") },
    { name = "IsolatedModules", dependencies = { "VerbatimModuleSyntax" }, compute = method("GetIsolatedModules") },
    { name = "PreserveConstEnums", dependencies = { "IsolatedModules", "VerbatimModuleSyntax" }, compute = method("ShouldPreserveConstEnums") },
    { name = "Declaration", dependencies = { "Composite" }, compute = method("GetEmitDeclarations") },
    { name = "DeclarationMap", dependencies = { "Declaration", "Composite" }, compute = method("GetAreDeclarationMapsEnabled") },
    { name = "Incremental", dependencies = { "Composite" }, compute = method("IsIncremental") },
    { name = "UseDefineForClassFields", dependencies = { "Target", "Module" }, compute = method("GetUseDefineForClassFields") },
    { name = "ResolvePackageJsonExports", dependencies = { "ModuleResolution", "Module", "Target" }, compute = method("GetResolvePackageJsonExports") },
    { name = "ResolvePackageJsonImports", dependencies = { "ModuleResolution", "ResolvePackageJsonExports", "Module", "Target" }, compute = method("GetResolvePackageJsonImports") },
    { name = "ResolveJsonModule", dependencies = { "ModuleResolution", "Module", "Target" }, compute = method("GetResolveJsonModule") },
    { name = "AllowJs", dependencies = { "CheckJs" }, compute = method("GetAllowJS") },
    { name = "AllowImportingTsExtensions", dependencies = { "RewriteRelativeImportExtensions" }, compute = method("GetAllowImportingTsExtensions") },
}

-- TSConfig represents the output structure for --showConfig
-- { compilerOptions = OrderedMap, references, files, include, exclude (nil-able slices),
--   compileOnSave (nil or true) }
local TSConfig = {}
TSConfig.__index = TSConfig
tsoptions.TSConfig = TSConfig

-- Go struct tags: `json:"compilerOptions"` and `json:"<name>,omitzero"` for the rest (a nil slice or
-- pointer is omitted; a non-nil empty slice is not).
function TSConfig:MarshalJSON()
    local parts = {}
    local function add(name, value)
        local s, err = json.Marshal(value)
        if err ~= nil then
            return err
        end
        parts[#parts + 1] = json.QuoteString(name) .. ":" .. s
        return nil
    end
    local err = add("compilerOptions", self.compilerOptions)
    for _, name in ipairs({ "references", "files", "include", "exclude", "compileOnSave" }) do
        if err ~= nil then
            return nil, err
        end
        if self[name] ~= nil then
            err = add(name, self[name])
        end
    end
    if err ~= nil then
        return nil, err
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end

-- ConvertToTSConfig generates a complete tsconfig representation for --showConfig output,
-- matching the behavior of TypeScript's convertToTSConfig function.
function tsoptions.ConvertToTSConfig(configParseResult, configFileName)
    if configFileName == "" then
        configFileName = "tsconfig.json"
    end
    local normalizedConfigPath = tspath.GetNormalizedAbsolutePath(configFileName, configParseResult:GetCurrentDirectory())
    local comparePathsOptions = tspath.NewComparePathsOptions(
        configParseResult:UseCaseSensitiveFileNames(),
        configParseResult:GetCurrentDirectory()
    )

    -- Build the list of all resolved files as relative paths from the config file.
    local files = nil
    for _, f in ipairs(configParseResult:FileNames() or {}) do
        local normalizedFilePath = tspath.GetNormalizedAbsolutePath(f, configParseResult:GetCurrentDirectory())
        local relativePath = tspath.GetRelativePathFromFile(normalizedConfigPath, normalizedFilePath, comparePathsOptions)
        files = core.Append(files, relativePath)
    end

    -- Serialize compiler options
    local optionMap = tsoptions.serializeCompilerOptions(configParseResult:CompilerOptions(), normalizedConfigPath, comparePathsOptions)

    -- Remove command-line-only options from the output
    for _, name in ipairs({
        "showConfig", "configFile", "configFilePath", "help", "init",
        "listFilesOnly", "listEmittedFiles", "project", "build", "version",
    }) do
        optionMap:Delete(name)
    end

    -- Add implied compiler options (options that are derived from explicitly set options,
    -- such as moduleResolution implied by module, or useDefineForClassFields implied by target).
    -- This mirrors TypeScript's convertToTSConfig computedOptions logic.
    tsoptions.addImpliedOptions(optionMap, configParseResult:CompilerOptions(), normalizedConfigPath, comparePathsOptions)

    local config = setmetatable({
        compilerOptions = optionMap,
    }, TSConfig)

    -- Add references
    local refs = configParseResult:ProjectReferences()
    if core.Len(refs) > 0 then
        local references = nil
        for _, r in ipairs(refs) do
            local ref = collections.NewOrderedMap()
            ref:Set("path", r.originalPath)
            if r.circular then
                ref:Set("circular", true)
            end
            references = core.Append(references, ref)
        end
        config.references = references
    end

    -- Add files
    if core.Len(files) > 0 then
        config.files = files
    end

    -- Add include/exclude from configFileSpecs
    if configParseResult.configFile ~= nil and configParseResult.configFile.configFileSpecs ~= nil then
        local specs = configParseResult.configFile.configFileSpecs
        local include = tsoptions.filterSameAsDefaultInclude(specs.validatedIncludeSpecs)
        if core.Len(include) > 0 then
            config.include = include
        end
        config.exclude = specs.validatedExcludeSpecs
    end

    -- Add compileOnSave
    if configParseResult.compileOnSave ~= nil and configParseResult.compileOnSave then
        config.compileOnSave = true
    end

    return config
end

-- filterSameAsDefaultInclude returns nil if specs is the default include spec ["**/*"]
function tsoptions.filterSameAsDefaultInclude(specs)
    if core.Len(specs) == 0 then
        return nil
    end
    if #specs == 1 and specs[1] == tsoptions.defaultIncludeSpec then
        return nil
    end
    return specs
end

-- getNameOfCompilerOptionValue returns the string key for a given enum value by
-- searching the option's enum map.
function tsoptions.getNameOfCompilerOptionValue(value, enumMap)
    for k, v in enumMap:Entries() do
        if v == value then
            return k
        end
    end
    return ""
end

-- reflect.Value.IsZero for a core.CompilerOptions field value (see core.CompilerOptions.Fields).
local function isZeroField(field, value)
    if value == nil then
        return true
    end
    if field.kind == "tristate" then
        return value == Tristate.TSUnknown
    elseif field.kind == "string" then
        return value == ""
    elseif string.sub(field.kind, 1, 5) == "enum:" then
        return value == 0
    end
    -- slices, maps and pointers: only nil is zero
    return false
end

-- serializeCompilerOptions converts CompilerOptions to an ordered map with
-- string names as keys and serialized values (enums as strings, paths as
-- relative paths, etc.) matching the output of tsc --showConfig.
function tsoptions.serializeCompilerOptions(options, configFilePath, comparePathsOptions)
    local result = collections.NewOrderedMapWithSizeHint(32)
    local configDir = tspath.GetDirectoryPath(configFilePath)

    -- Every exported field of core.CompilerOptions, in declaration order.
    for _, field in ipairs(core.CompilerOptions.Fields) do
        local optionDecl = tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, field.name)
        if optionDecl == nil then
            goto continue
        end

        -- Skip command-line-only and output formatting options
        if optionDecl.category == diagnostics.Command_line_Options or optionDecl.category == diagnostics.Output_Formatting then
            goto continue
        end

        do
            local value = options[field.name]

            -- Skip zero values (unset options)
            if isZeroField(field, value) then
                goto continue
            end

            local name = optionDecl.name

            local enumMap = optionDecl:EnumMap()
            if enumMap ~= nil then
                -- Enum option - convert numeric value to string name
                local serialized = tsoptions.serializeEnumValue(value, enumMap)
                if serialized ~= "" then
                    result:Set(name, serialized)
                end
                goto continue
            end

            local kind = optionDecl.kind
            if kind == CommandLineOptionKind.CommandLineOptionTypeListOrElement then
                debug.Assert(false, "listOrElement option should not reach serialization")
            elseif kind == CommandLineOptionKind.CommandLineOptionTypeList then
                local elem = optionDecl:Elements()
                if elem ~= nil and elem.isFilePath then
                    -- List of file paths - make relative
                    if field.kind == "stringlist" then
                        local relPaths = {}
                        for j, s in ipairs(value) do
                            local absPath = tspath.GetNormalizedAbsolutePath(s, configDir)
                            relPaths[j] = tspath.GetRelativePathFromFile(configFilePath, absPath, comparePathsOptions)
                        end
                        result:Set(name, relPaths)
                        goto continue
                    end
                end
                if elem ~= nil and elem:EnumMap() ~= nil then
                    -- List of enum values (e.g., lib)
                    local elemMap = elem:EnumMap()
                    if field.kind == "stringlist" then
                        local serialized = {}
                        for _, s in ipairs(value) do
                            -- lib values are already stored as the d.ts filename, need to find original key
                            local found = tsoptions.getNameOfCompilerOptionValue(s, elemMap)
                            if found ~= "" then
                                serialized[#serialized + 1] = found
                            else
                                serialized[#serialized + 1] = s
                            end
                        end
                        result:Set(name, serialized)
                        goto continue
                    end
                end
                result:Set(name, value)
            elseif kind == CommandLineOptionKind.CommandLineOptionTypeString then
                if optionDecl.isFilePath then
                    -- File path option - make relative to config
                    if field.kind == "string" and value ~= "" then
                        local absPath = tspath.GetNormalizedAbsolutePath(value, configDir)
                        result:Set(name, tspath.GetRelativePathFromFile(configFilePath, absPath, comparePathsOptions))
                        goto continue
                    end
                end
                result:Set(name, value)
            elseif kind == CommandLineOptionKind.CommandLineOptionTypeBoolean then
                if field.kind == "tristate" then
                    if core.Tristate_IsTrue(value) then
                        result:Set(name, true)
                    elseif core.Tristate_IsFalse(value) then
                        result:Set(name, false)
                    end
                else
                    result:Set(name, value)
                end
            else
                result:Set(name, value)
            end
        end
        ::continue::
    end

    return result
end

-- serializeEnumValue converts an enum field value to its corresponding string key
-- using the option's enum map. It handles int32-based enum types.
function tsoptions.serializeEnumValue(value, enumMap)
    -- The enum maps store values as core.ModuleKind, core.ScriptTarget, etc.
    -- But those are all int32 underneath. We need to compare by the underlying int32 value.
    if math.type(value) == "integer" then
        for k, v in enumMap:Entries() do
            if math.type(v) == "integer" and v == value then
                return k
            end
        end
    end
    -- Fallback: direct comparison
    return tsoptions.getNameOfCompilerOptionValue(value, enumMap)
end

-- addImpliedOptions adds compiler options that are implied by other explicitly-set options,
-- mirroring TypeScript's convertToTSConfig behavior for computedOptions.
-- For example, when module: nodenext is set, moduleResolution: nodenext is implied.
function tsoptions.addImpliedOptions(optionMap, options, _, _)
    -- Build the set of explicitly provided option JSON names (e.g., "module", "target").
    local provided = {}
    for k in optionMap:Keys() do
        provided[k] = true
    end

    local defaultOpts = core.NewCompilerOptions()

    for _, entry in ipairs(tsoptions.impliedOptions) do
        -- Get the option declaration for this implied option (using case-insensitive lookup).
        local optionDecl = tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, entry.name)
        if optionDecl == nil then
            goto continue
        end

        -- Skip if this option is already explicitly provided.
        if provided[optionDecl.name] then
            goto continue
        end

        -- Check if any direct dependency is in the provided set.
        -- This mirrors TypeScript's optionDependsOn check.
        if not tsoptions.anyDependencyProvided(entry.dependencies, provided) then
            goto continue
        end

        do
            -- Compute the effective value with current options and the default value with empty options.
            local implied = entry.compute(options)
            local defaultVal = entry.compute(defaultOpts)

            -- If the implied value equals the default, this option doesn't add useful information.
            if implied == defaultVal then
                goto continue
            end

            -- Serialize the implied value and add it to the option map.
            local serialized = tsoptions.serializeImpliedOptionValue(optionDecl, implied)
            if serialized == nil then
                goto continue
            end
            optionMap:Set(optionDecl.name, serialized)
        end
        ::continue::
    end
end

-- anyDependencyProvided returns true if any of the given dependency names
-- (using Go field names like "Target") corresponds to an option in the provided set.
function tsoptions.anyDependencyProvided(dependencies, provided)
    for _, dep in ipairs(dependencies) do
        local depDecl = tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, dep)
        if depDecl ~= nil and provided[depDecl.name] then
            return true
        end
    end
    return false
end

-- serializeImpliedOptionValue converts a computed implied option value to its serializable form.
-- For enum options, it converts numeric values to their string names.
-- For boolean options, it returns the bool directly.
-- The getters used by impliedOptions return enum values (integers) or bools, never Tristates.
function tsoptions.serializeImpliedOptionValue(optionDecl, value)
    if value == nil then
        return nil
    end
    local enumMap = optionDecl:EnumMap()
    if enumMap ~= nil then
        local s = tsoptions.serializeEnumValue(value, enumMap)
        if s ~= "" then
            return s
        end
        return nil
    end
    return value
end
