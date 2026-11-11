-- Port of execute/tsc/init.go (the file name avoids clashing with the package's init.lua).
local tsc = require("tslua.execute.tsc")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local json = require("tslua.json")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

function tsc.WriteConfigFile(sys, locale, reportDiagnostic, options)
    local getCurrentDirectory = sys:GetCurrentDirectory()
    local file = tspath.NormalizePath(tspath.CombinePaths(getCurrentDirectory, "tsconfig.json"))
    if sys:FS():FileExists(file) then
        reportDiagnostic(ast.NewCompilerDiagnostic(diagnostics.A_tsconfig_json_file_is_already_defined_at_Colon_0, file))
    else
        sys:FS():WriteFile(file, tsc.generateTSConfig(options, locale))
        local output = { "\n" }
        for _, s in ipairs(tsc.getHeader(sys, "Created a new tsconfig.json")) do
            output[#output + 1] = s
        end
        output[#output + 1] = "You can learn more at https://aka.ms/tsconfig"
        output[#output + 1] = "\n"
        sys:Writer():WriteString(table.concat(output, ""))
    end
end

function tsc.generateTSConfig(options, locale)
    local tab = "  "
    local result = {}

    local allSetOptions = {}
    for k in options:Keys() do
        if k ~= "init" and k ~= "help" and k ~= "watch" then
            allSetOptions[#allSetOptions + 1] = k
        end
    end

    local function emitHeader(header)
        result[#result + 1] = tab .. tab .. "// " .. header:Localize(locale)
    end
    local function newline()
        result[#result + 1] = ""
    end
    local function push(...)
        for i = 1, select("#", ...) do
            result[#result + 1] = (select(i, ...))
        end
    end

    local function formatSingleValue(value, enumMap)
        if enumMap ~= nil then
            local found = false
            for k, v in enumMap:Entries() do
                if value == v then
                    value = k
                    found = true
                    break
                end
            end
            if not found then
                error("No matching value of " .. tostring(value), 0)
            end
        end

        local b, err = json.MarshalIndent(value, "", "")
        if err ~= nil then
            error("should not happen: " .. tostring(err), 0)
        end
        return b
    end

    local function formatValueOrArray(settingName, value)
        local option = nil
        for _, decl in ipairs(tsoptions.OptionsDeclarations) do
            if decl.name == settingName then
                option = decl
            end
        end
        if option == nil then
            error("No option named " .. settingName, 0)
        end

        if type(value) == "table" and getmetatable(value) == nil then
            local enumMap = nil
            local elemOption = option:Elements()
            if elemOption ~= nil then
                enumMap = elemOption:EnumMap()
            end

            local elems = {}
            for _, v in ipairs(value) do
                elems[#elems + 1] = formatSingleValue(v, enumMap)
            end
            return "[" .. table.concat(elems, ", ") .. "]"
        else
            return formatSingleValue(value, option:EnumMap())
        end
    end

    -- commentedNever': Never comment this out
    -- commentedAlways': Always comment this out, even if it's on commandline
    -- commentedOptional': Comment out unless it's on commandline
    local commentedNever = 0
    local commentedAlways = 1
    local commentedOptional = 2
    local function emitOption(setting, defaultValue, commented)
        if commented > 2 then
            error("should not happen: invalid `commented`, must be a bug.", 0)
        end

        for i, s in ipairs(allSetOptions) do
            if s == setting then
                table.remove(allSetOptions, i)
                break
            end
        end

        local comment
        if commented == commentedAlways then
            comment = true
        elseif commented == commentedNever then
            comment = false
        else
            comment = not options:Has(setting)
        end

        local value, ok = options:Get(setting)
        if not ok then
            value = defaultValue
        end

        if comment then
            push(tab .. tab .. '// "' .. setting .. '": ' .. formatValueOrArray(setting, value) .. ",")
        else
            push(tab .. tab .. '"' .. setting .. '": ' .. formatValueOrArray(setting, value) .. ",")
        end
    end

    push("{")
    push(tab .. "// " .. diagnostics.Visit_https_Colon_Slash_Slashaka_ms_Slashtsconfig_to_read_more_about_this_file:Localize(locale))
    push(tab .. '"compilerOptions": {')

    emitHeader(diagnostics.File_Layout)
    emitOption("rootDir", "./src", commentedOptional)
    emitOption("outDir", "./dist", commentedOptional)

    newline()

    emitHeader(diagnostics.Environment_Settings)
    emitHeader(diagnostics.See_also_https_Colon_Slash_Slashaka_ms_Slashtsconfig_Slashmodule)
    emitOption("module", core.ModuleKind.NodeNext, commentedNever)
    emitOption("target", core.ScriptTarget.ESNext, commentedNever)
    emitOption("types", {}, commentedNever)
    local lib, hasLib = options:Get("lib")
    if hasLib then
        emitOption("lib", lib, commentedNever)
    end
    emitHeader(diagnostics.For_nodejs_Colon)
    push(tab .. tab .. '// "lib": ["esnext"],')
    push(tab .. tab .. '// "types": ["node"],')
    emitHeader(diagnostics.X_and_npm_install_D_types_Slashnode)

    newline()

    emitHeader(diagnostics.Other_Outputs)
    emitOption("sourceMap", true, commentedNever)
    emitOption("declaration", true, commentedNever)
    emitOption("declarationMap", true, commentedNever)

    newline()

    emitHeader(diagnostics.Stricter_Typechecking_Options)
    emitOption("noUncheckedIndexedAccess", true, commentedNever)
    emitOption("exactOptionalPropertyTypes", true, commentedNever)

    newline()

    emitHeader(diagnostics.Style_Options)
    emitOption("noImplicitReturns", true, commentedOptional)
    emitOption("noImplicitOverride", true, commentedOptional)
    emitOption("noUnusedLocals", true, commentedOptional)
    emitOption("noUnusedParameters", true, commentedOptional)
    emitOption("noFallthroughCasesInSwitch", true, commentedOptional)
    emitOption("noPropertyAccessFromIndexSignature", true, commentedOptional)

    newline()

    emitHeader(diagnostics.Recommended_Options)
    emitOption("strict", true, commentedNever)
    emitOption("jsx", core.JsxEmit.ReactJSX, commentedNever)
    emitOption("verbatimModuleSyntax", true, commentedNever)
    emitOption("isolatedModules", true, commentedNever)
    emitOption("noUncheckedSideEffectImports", true, commentedNever)
    emitOption("moduleDetection", core.ModuleDetectionKind.Force, commentedNever)
    emitOption("skipLibCheck", true, commentedNever)

    -- Write any user-provided options we haven't already
    if #allSetOptions > 0 then
        newline()
        while #allSetOptions > 0 do
            emitOption(allSetOptions[1], options:GetOrZero(allSetOptions[1]), commentedNever)
        end
    end

    push(tab .. "}")
    push("}")
    push("")

    return table.concat(result, "\n")
end
