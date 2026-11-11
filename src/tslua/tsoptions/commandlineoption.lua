local tsoptions = require("tslua.tsoptions")
local collections = require("tslua.collections")
local core = require("tslua.core")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind

local CommandLineOption = {}
CommandLineOption.__index = CommandLineOption
tsoptions.CommandLineOption = CommandLineOption

-- extraValidation (unexported Go string type; not in the generated constants)
tsoptions.extraValidationNone = ""
tsoptions.extraValidationSpec = "spec"
tsoptions.extraValidationLocale = "locale"

-- Go `&CommandLineOption{...}` literal: every field starts at its Go zero value.
function tsoptions.newCommandLineOption(init)
    local o = setmetatable({
        name = "",
        shortName = "",
        kind = "",
        -- used in parsing
        isFilePath = false,
        isTSConfigOnly = false,
        isCommandLineOnly = false,
        -- used in output
        description = nil,
        defaultValueDescription = nil,
        showInSimplifiedHelpView = false,
        -- used in output in serializing and generate tsconfig
        category = nil,
        -- What kind of extra validation `validateJsonOptionValue` should do
        extraValidation = tsoptions.extraValidationNone,
        -- checks that option with number type has value >= minValue
        minValue = 0,
        -- true or undefined
        -- used for configDirTemplateSubstitutionOptions
        allowConfigDirTemplateSubstitution = false,
        -- used for filter in compilerrunner
        affectsDeclarationPath = false,
        affectsProgramStructure = false,
        affectsSemanticDiagnostics = false,
        affectsBuildInfo = false,
        affectsBindDiagnostics = false,
        affectsSourceFile = false,
        affectsModuleResolution = false,
        affectsEmit = false,
        allowJsFlag = false,
        strictFlag = false,
        -- used in transpileoptions worker
        -- todo: revisit to see if this can be reduced to boolean
        transpileOptionValue = core.Tristate.TSUnknown,
        -- used for CommandLineOptionTypeList
        listPreserveFalsyValues = false,
        -- used for compilerOptionsDeclaration
        elementOptions = nil,
    }, CommandLineOption)
    if init ~= nil then
        for k, v in pairs(init) do
            o[k] = v
        end
    end
    return o
end

function CommandLineOption:DeprecatedKeys()
    if self.kind ~= CommandLineOptionKind.CommandLineOptionTypeEnum then
        return nil
    end
    return tsoptions.commandLineOptionDeprecated[self.name]
end

function CommandLineOption:EnumMap()
    if self.kind ~= CommandLineOptionKind.CommandLineOptionTypeEnum then
        return nil
    end
    return tsoptions.commandLineOptionEnumMap[self.name]
end

function CommandLineOption:Elements()
    if self.kind ~= CommandLineOptionKind.CommandLineOptionTypeList and self.kind ~= CommandLineOptionKind.CommandLineOptionTypeListOrElement then
        return nil
    end
    return tsoptions.commandLineOptionElements[self.name]
end

function CommandLineOption:DisallowNullOrUndefined()
    return self.name == "extends"
end

-- CommandLineOption.Elements()
tsoptions.commandLineOptionElements = {
    ["lib"] = tsoptions.newCommandLineOption({
        name = "lib",
        kind = CommandLineOptionKind.CommandLineOptionTypeEnum, -- libMap,
        defaultValueDescription = core.Tristate.TSUnknown,
    }),
    ["rootDirs"] = tsoptions.newCommandLineOption({
        name = "rootDirs",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
        isFilePath = true,
    }),
    ["typeRoots"] = tsoptions.newCommandLineOption({
        name = "typeRoots",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
        isFilePath = true,
    }),
    ["types"] = tsoptions.newCommandLineOption({
        name = "types",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["moduleSuffixes"] = tsoptions.newCommandLineOption({
        name = "moduleSuffixes",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["customConditions"] = tsoptions.newCommandLineOption({
        name = "condition",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["plugins"] = tsoptions.newCommandLineOption({
        name = "plugin",
        kind = CommandLineOptionKind.CommandLineOptionTypeObject,
    }),
    -- For tsconfig root options
    ["references"] = tsoptions.newCommandLineOption({
        name = "references",
        kind = CommandLineOptionKind.CommandLineOptionTypeObject,
    }),
    ["contentMappers"] = tsoptions.newCommandLineOption({
        name = "contentMappers",
        kind = CommandLineOptionKind.CommandLineOptionTypeObject,
    }),
    ["files"] = tsoptions.newCommandLineOption({
        name = "files",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["include"] = tsoptions.newCommandLineOption({
        name = "include",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["exclude"] = tsoptions.newCommandLineOption({
        name = "exclude",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    ["extends"] = tsoptions.newCommandLineOption({
        name = "extends",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
    -- For Watch options
    ["excludeDirectories"] = tsoptions.newCommandLineOption({
        name = "excludeDirectory",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
        isFilePath = true,
        extraValidation = tsoptions.extraValidationSpec,
    }),
    ["excludeFiles"] = tsoptions.newCommandLineOption({
        name = "excludeFile",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
        isFilePath = true,
        extraValidation = tsoptions.extraValidationSpec,
    }),
    -- Test infra options
    ["libFiles"] = tsoptions.newCommandLineOption({
        name = "libFiles",
        kind = CommandLineOptionKind.CommandLineOptionTypeString,
    }),
}

-- CommandLineOption.EnumMap()
tsoptions.commandLineOptionEnumMap = {
    ["lib"] = tsoptions.LibMap,
    ["moduleResolution"] = tsoptions.moduleResolutionOptionMap,
    ["module"] = tsoptions.moduleOptionMap,
    ["target"] = tsoptions.targetOptionMap,
    ["moduleDetection"] = tsoptions.moduleDetectionOptionMap,
    ["jsx"] = tsoptions.jsxOptionMap,
    ["newLine"] = tsoptions.newLineOptionMap,
    ["watchFile"] = tsoptions.watchFileEnumMap,
    ["watchDirectory"] = tsoptions.watchDirectoryEnumMap,
    ["fallbackPolling"] = tsoptions.fallbackEnumMap,
}

-- CommandLineOption.DeprecatedKeys()
tsoptions.commandLineOptionDeprecated = {
    ["module"] = collections.NewSetFromItems("none", "amd", "system", "umd"),
    ["moduleResolution"] = collections.NewSetFromItems("node", "classic", "node10"),
    ["target"] = collections.NewSetFromItems("es5"),
}

-- todo: revisit to see if this can be improved
-- CompilerOptionsValue is `any`.
