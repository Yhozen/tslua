local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")

local strings = require("tslua.module").strings
local CommandLineOptionKind = tsoptions.CommandLineOptionKind

function tsoptions.createDiagnosticForInvalidEnumType(opt, sourceFile, node)
    local namesOfType = {}
    for k in opt:EnumMap():Keys() do
        namesOfType[#namesOfType + 1] = k
    end
    local stringNames = tsoptions.formatEnumTypeKeys(opt, namesOfType)
    local optName = "--" .. opt.name
    return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, node, diagnostics.Argument_for_0_option_must_be_Colon_1, optName, stringNames)
end

function tsoptions.formatEnumTypeKeys(opt, keys)
    if opt:DeprecatedKeys() ~= nil then
        keys = core.Filter(keys, function(key) return not opt:DeprecatedKeys():Has(key) end)
    end
    return "'" .. strings.Join(keys, "', '") .. "'"
end

function tsoptions.getCompilerOptionValueTypeString(option)
    if option.kind == CommandLineOptionKind.CommandLineOptionTypeListOrElement then
        return tsoptions.getCompilerOptionValueTypeString(option:Elements()) .. " or Array"
    elseif option.kind == CommandLineOptionKind.CommandLineOptionTypeList then
        return "Array"
    else
        return option.kind
    end
end

function tsoptions.commandLineParser:createUnknownOptionError(
    unknownOption,
    unknownOptionErrorText,
    node,
    sourceFile
)
    return tsoptions.createUnknownOptionError(
        unknownOption,
        self:UnknownOptionDiagnostic(),
        unknownOptionErrorText,
        node,
        sourceFile,
        self:AlternateMode(),
        self:UnknownDidYouMeanDiagnostic(),
        tsoptions.commandLineOptionsToMap(self.workerDiagnostics.didYouMean.optionDeclarations)
    )
end

-- createUnknownOptionError creates a diagnostic for an unknown option. If
-- unknownDidYouMeanDiagnostic and optionsNameMap are provided, it also checks
-- for a spelling suggestion and emits a "did you mean" diagnostic instead.
function tsoptions.createUnknownOptionError(
    unknownOption,
    unknownOptionDiagnostic,
    unknownOptionErrorText, -- optional
    node, -- optional
    sourceFile, -- optional
    alternateMode, -- optional
    unknownDidYouMeanDiagnostic, -- optional; nil skips suggestion
    optionsNameMap -- optional; nil skips suggestion
)
    if alternateMode ~= nil and alternateMode.optionsNameMap ~= nil then
        local otherOption = alternateMode.optionsNameMap:Get(strings.ToLower(unknownOption))
        if otherOption ~= nil then
            -- tscbuildoption
            local diagnostic = alternateMode.diagnostic
            if otherOption.name == "build" then
                diagnostic = diagnostics.Option_build_must_be_the_first_command_line_argument
            end
            return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, node, diagnostic, unknownOption)
        end
    end
    if unknownOptionErrorText == nil or unknownOptionErrorText == "" then
        unknownOptionErrorText = unknownOption
    end
    if unknownDidYouMeanDiagnostic ~= nil and optionsNameMap ~= nil then
        local possibleOption = tsoptions.CommandLineOptionNameMap_GetSpellingSuggestion(optionsNameMap, unknownOption)
        if possibleOption ~= nil then
            return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, node, unknownDidYouMeanDiagnostic, unknownOptionErrorText, possibleOption.name)
        end
    end
    return tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, node, unknownOptionDiagnostic, unknownOptionErrorText)
end

function tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile, node, message, ...)
    return ast.NewDiagnostic(sourceFile, core.NewTextRange(scanner.SkipTrivia(sourceFile:Text(), node.loc:Pos()), node:End()), message, ...)
end

function tsoptions.CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, node, message, ...)
    if sourceFile ~= nil and node ~= nil then
        return tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile, node, message, ...)
    end
    return ast.NewCompilerDiagnostic(message, ...)
end

function tsoptions.extraKeyDiagnostics(s)
    if s == "compilerOptions" then
        return diagnostics.Unknown_compiler_option_0
    elseif s == "watchOptions" then
        return diagnostics.Unknown_watch_option_0
    elseif s == "typeAcquisition" then
        return diagnostics.Unknown_type_acquisition_option_0
    elseif s == "buildOptions" then
        return diagnostics.Unknown_build_option_0
    else
        return nil
    end
end

function tsoptions.extraKeyDidYouMeanDiagnostics(s)
    if s == "compilerOptions" then
        return diagnostics.Unknown_compiler_option_0_Did_you_mean_1
    elseif s == "watchOptions" then
        return diagnostics.Unknown_watch_option_0_Did_you_mean_1
    elseif s == "typeAcquisition" then
        return diagnostics.Unknown_type_acquisition_option_0_Did_you_mean_1
    elseif s == "buildOptions" then
        return diagnostics.Unknown_build_option_0_Did_you_mean_1
    else
        return nil
    end
end
