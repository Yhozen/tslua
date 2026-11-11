local tsc = require("tslua.execute.tsc")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")

local Kind = tsoptions.CommandLineOptionKind

-- Go fmt width counts runes.
local function runeLen(s)
    return utf8.len(s) or #s
end

-- fmt.Sprintf("%-*s", width, s)
local function padRight(s, width)
    local n = runeLen(s)
    if n >= width then
        return s
    end
    return s .. string.rep(" ", width - n)
end

-- fmt.Sprintf("%*s", width, s)
local function padLeft(s, width)
    local n = runeLen(s)
    if n >= width then
        return s
    end
    return string.rep(" ", width - n) .. s
end

local function appendAll(xs, ...)
    for i = 1, select("#", ...) do
        xs[#xs + 1] = (select(i, ...))
    end
    return xs
end

local function appendList(xs, ys)
    for _, y in ipairs(ys or {}) do
        xs[#xs + 1] = y
    end
    return xs
end

function tsc.PrintVersion(sys, locale)
    sys:Writer():WriteString(diagnostics.Version_0:Localize(locale, core.Version()) .. "\n")
end

function tsc.PrintHelp(sys, locale, commandLine)
    if core.Tristate_IsFalseOrUnknown(commandLine:CompilerOptions().all) then
        tsc.printEasyHelp(sys, locale, tsc.getOptionsForHelp(commandLine))
    else
        tsc.printAllHelp(sys, locale, tsc.getOptionsForHelp(commandLine))
    end
end

function tsc.getOptionsForHelp(commandLine)
    -- Sort our options by their names, (e.g. "--noImplicitAny" comes before "--watch")
    local opts = core.Slice(tsoptions.OptionsDeclarations)
    opts[#opts + 1] = tsoptions.TscBuildOption

    if core.Tristate_IsTrue(commandLine:CompilerOptions().all) then
        local decorated = {}
        for i, o in ipairs(opts) do
            decorated[i] = { o = o, key = string.lower(o.name), i = i }
        end
        table.sort(decorated, function(a, b)
            if a.key ~= b.key then
                return a.key < b.key
            end
            return a.i < b.i
        end)
        for i, d in ipairs(decorated) do
            opts[i] = d.o
        end
        return opts
    else
        return core.Filter(opts, function(opt)
            return opt.showInSimplifiedHelpView
        end)
    end
end

function tsc.getHeader(sys, message)
    local colors = tsc.createColors(sys)
    local header = {}
    local terminalWidth = sys:GetWidthOfTerminal()
    local tsIcon = "     "
    local tsIconTS = "  TS "
    local tsIconLength = #tsIcon

    local tsIconFirstLine = colors:blueBackground(tsIcon)
    local tsIconSecondLine = colors:blueBackground(colors:brightWhite(tsIconTS))
    -- If we have enough space, print TS icon.
    if terminalWidth >= #message + tsIconLength then
        -- right align of the icon is 120 at most.
        local rightAlign = terminalWidth > 120 and 120 or terminalWidth
        local leftAlign = rightAlign - tsIconLength
        appendAll(header, padRight(message, leftAlign), tsIconFirstLine, "\n")
        appendAll(header, string.rep(" ", leftAlign), tsIconSecondLine, "\n")
    else
        appendAll(header, message, "\n", "\n")
    end
    return header
end

function tsc.printEasyHelp(sys, locale, simpleOptions)
    local colors = tsc.createColors(sys)
    local output = {}
    local function example(examples, desc)
        for _, ex in ipairs(examples) do
            appendAll(output, "  ", colors:blue(ex), "\n")
        end
        appendAll(output, "  ", desc:Localize(locale), "\n", "\n")
    end

    local msg = diagnostics.X_tsc_Colon_The_TypeScript_Compiler:Localize(locale) .. " - " .. diagnostics.Version_0:Localize(locale, core.Version())
    appendList(output, tsc.getHeader(sys, msg))

    appendAll(output, colors:bold(diagnostics.COMMON_COMMANDS:Localize(locale)), "\n", "\n")

    example({ "tsc" }, diagnostics.Compiles_the_current_project_tsconfig_json_in_the_working_directory)
    example({ "tsc app.ts util.ts" }, diagnostics.Ignoring_tsconfig_json_compiles_the_specified_files_with_default_compiler_options)
    example({ "tsc -b" }, diagnostics.Build_a_composite_project_in_the_working_directory)
    example({ "tsc --init" }, diagnostics.Creates_a_tsconfig_json_with_the_recommended_settings_in_the_working_directory)
    example({ "tsc -p ./path/to/tsconfig.json" }, diagnostics.Compiles_the_TypeScript_project_located_at_the_specified_path)
    example({ "tsc --help --all" }, diagnostics.An_expanded_version_of_this_information_showing_all_possible_compiler_options)
    example({ "tsc --noEmit", "tsc --target esnext" }, diagnostics.Compiles_the_current_project_with_additional_settings)

    local cliCommands = {}
    local configOpts = {}
    for _, opt in ipairs(simpleOptions) do
        if opt.isCommandLineOnly or opt.category == diagnostics.Command_line_Options then
            cliCommands[#cliCommands + 1] = opt
        else
            configOpts[#configOpts + 1] = opt
        end
    end

    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.COMMAND_LINE_FLAGS:Localize(locale), cliCommands, false, nil, nil))

    local after = diagnostics.You_can_learn_about_all_of_the_compiler_options_at_0:Localize(locale, "https://aka.ms/tsc")
    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.COMMON_COMPILER_OPTIONS:Localize(locale), configOpts, false, nil, after))

    local w = sys:Writer()
    for _, chunk in ipairs(output) do
        w:WriteString(chunk)
    end
end

function tsc.printAllHelp(sys, locale, options)
    local output = {}
    local msg = diagnostics.X_tsc_Colon_The_TypeScript_Compiler:Localize(locale) .. " - " .. diagnostics.Version_0:Localize(locale, core.Version())
    appendList(output, tsc.getHeader(sys, msg))

    -- ALL COMPILER OPTIONS section
    local afterCompilerOptions = diagnostics.You_can_learn_about_all_of_the_compiler_options_at_0:Localize(locale, "https://aka.ms/tsc")
    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.ALL_COMPILER_OPTIONS:Localize(locale), options, true, nil, afterCompilerOptions))

    -- WATCH OPTIONS section
    local beforeWatchOptions = diagnostics.Including_watch_w_will_start_watching_the_current_project_for_the_file_changes_Once_set_you_can_config_watch_mode_with_Colon:Localize(locale)
    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.WATCH_OPTIONS:Localize(locale), tsoptions.OptionsForWatch, false, beforeWatchOptions, nil))

    -- BUILD OPTIONS section
    local beforeBuildOptions = diagnostics.Using_build_b_will_make_tsc_behave_more_like_a_build_orchestrator_than_a_compiler_This_is_used_to_trigger_building_composite_projects_which_you_can_learn_more_about_at_0:Localize(locale, "https://aka.ms/tsc-composite-builds")
    local buildOptions = core.Filter(tsoptions.OptionsForBuild, function(option)
        return option ~= tsoptions.TscBuildOption
    end)
    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.BUILD_OPTIONS:Localize(locale), buildOptions, false, beforeBuildOptions, nil))

    local w = sys:Writer()
    for _, chunk in ipairs(output) do
        w:WriteString(chunk)
    end
end

function tsc.PrintBuildHelp(sys, locale, buildOptions)
    local output = {}
    appendList(output, tsc.getHeader(sys, diagnostics.X_tsc_Colon_The_TypeScript_Compiler:Localize(locale) .. " - " .. diagnostics.Version_0:Localize(locale, core.Version())))
    local before = diagnostics.Using_build_b_will_make_tsc_behave_more_like_a_build_orchestrator_than_a_compiler_This_is_used_to_trigger_building_composite_projects_which_you_can_learn_more_about_at_0:Localize(locale, "https://aka.ms/tsc-composite-builds")
    local options = core.Filter(buildOptions, function(option)
        return option ~= tsoptions.TscBuildOption
    end)
    appendList(output, tsc.generateSectionOptionsOutput(sys, locale, diagnostics.BUILD_OPTIONS:Localize(locale), options, false, before, nil))

    local w = sys:Writer()
    for _, chunk in ipairs(output) do
        w:WriteString(chunk)
    end
end

-- beforeOptionsDescription / afterOptionsDescription are strings or nil (Go *string).
function tsc.generateSectionOptionsOutput(sys, locale, sectionName, options, subCategory, beforeOptionsDescription, afterOptionsDescription)
    local output = {}
    appendAll(output, tsc.createColors(sys):bold(sectionName), "\n", "\n")

    if beforeOptionsDescription ~= nil then
        appendAll(output, beforeOptionsDescription, "\n", "\n")
    end
    if not subCategory then
        appendList(output, tsc.generateGroupOptionOutput(sys, locale, options))
        if afterOptionsDescription ~= nil then
            appendAll(output, afterOptionsDescription, "\n", "\n")
        end
        return output
    end
    local categoryMap = {}
    local categoryOrder = {}
    for _, option in ipairs(options) do
        if option.category ~= nil then
            local curCategory = option.category:Localize(locale)
            if categoryMap[curCategory] == nil then
                categoryOrder[#categoryOrder + 1] = curCategory
                categoryMap[curCategory] = {}
            end
            local list = categoryMap[curCategory]
            list[#list + 1] = option
        end
    end
    for _, key in ipairs(categoryOrder) do
        local value = categoryMap[key]
        appendAll(output, "### ", key, "\n", "\n")
        appendList(output, tsc.generateGroupOptionOutput(sys, locale, value))
    end
    if afterOptionsDescription ~= nil then
        appendAll(output, afterOptionsDescription, "\n", "\n")
    end

    return output
end

function tsc.generateGroupOptionOutput(sys, locale, optionsList)
    local maxLength = 0
    for _, option in ipairs(optionsList) do
        local curLenght = #tsc.getDisplayNameTextOfOption(option)
        maxLength = math.max(curLenght, maxLength)
    end

    -- left part should be right align, right part should be left align

    -- assume 2 space between left margin and left part.
    local rightAlignOfLeftPart = maxLength + 2
    -- assume 2 space between left and right part
    local leftAlignOfRightPart = rightAlignOfLeftPart + 2

    local lines = {}
    for _, option in ipairs(optionsList) do
        appendList(lines, tsc.generateOptionOutput(sys, locale, option, rightAlignOfLeftPart, leftAlignOfRightPart))
    end

    -- make sure always a blank line in the end.
    if #lines < 2 or lines[#lines - 1] ~= "\n" then
        lines[#lines + 1] = "\n"
    end

    return lines
end

local function isMessage(v)
    return type(v) == "table" and getmetatable(v) == diagnostics.Message
end

function tsc.generateOptionOutput(sys, locale, option, rightAlignOfLeft, leftAlignOfRight)
    local text = {}
    local colors = tsc.createColors(sys)

    -- name and description
    local name = tsc.getDisplayNameTextOfOption(option)

    -- value type and possible value
    local valueCandidates = tsc.getValueCandidate(sys, locale, option)

    local defaultValueDescription
    if isMessage(option.defaultValueDescription) then
        defaultValueDescription = option.defaultValueDescription:Localize(locale)
    else
        local formatOption = option
        if option.kind == Kind.CommandLineOptionTypeList or option.kind == Kind.CommandLineOptionTypeListOrElement then
            formatOption = option:Elements()
        end
        defaultValueDescription = tsc.formatDefaultValue(option.defaultValueDescription, formatOption)
    end

    local terminalWidth = sys:GetWidthOfTerminal()

    if terminalWidth >= 80 then
        local description = ""
        if option.description ~= nil then
            description = option.description:Localize(locale)
        end
        appendList(text, tsc.getPrettyOutput(colors, name, description, rightAlignOfLeft, leftAlignOfRight, terminalWidth, true))
        text[#text + 1] = "\n"
        if tsc.showAdditionalInfoOutput(valueCandidates, option) then
            if valueCandidates ~= nil then
                appendList(text, tsc.getPrettyOutput(colors, valueCandidates.valueType, valueCandidates.possibleValues, rightAlignOfLeft, leftAlignOfRight, terminalWidth, false))
                text[#text + 1] = "\n"
            end
            if defaultValueDescription ~= "" then
                appendList(text, tsc.getPrettyOutput(colors, diagnostics.X_default_Colon:Localize(locale), defaultValueDescription, rightAlignOfLeft, leftAlignOfRight, terminalWidth, false))
                text[#text + 1] = "\n"
            end
        end
        text[#text + 1] = "\n"
    else
        appendAll(text, colors:blue(name), "\n")
        if option.description ~= nil then
            text[#text + 1] = option.description:Localize(locale)
        end
        text[#text + 1] = "\n"
        if tsc.showAdditionalInfoOutput(valueCandidates, option) then
            if valueCandidates ~= nil then
                appendAll(text, valueCandidates.valueType, " ", valueCandidates.possibleValues)
            end
            if defaultValueDescription ~= "" then
                if valueCandidates ~= nil then
                    text[#text + 1] = "\n"
                end
                appendAll(text, diagnostics.X_default_Colon:Localize(locale), " ", defaultValueDescription)
            end

            text[#text + 1] = "\n"
        end
        text[#text + 1] = "\n"
    end

    return text
end

-- Go fmt.Sprint("%v") of an option default value.
local function sprintV(v)
    local t = type(v)
    if t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if math.type(v) == "integer" then
            return tostring(v)
        end
        return string.format("%g", v)
    elseif t == "table" then
        local parts = {}
        for i, x in ipairs(v) do
            parts[i] = sprintV(x)
        end
        return "[" .. table.concat(parts, " ") .. "]"
    end
    return tostring(v)
end

function tsc.formatDefaultValue(defaultValue, option)
    -- In Go a Tristate default is distinguishable from an int 0 by its type; here only
    -- non-number options can carry a Tristate default.
    if defaultValue == nil or (defaultValue == core.Tristate.TSUnknown and option.kind ~= Kind.CommandLineOptionTypeNumber) then
        return "undefined"
    end

    if option.kind == Kind.CommandLineOptionTypeEnum then
        -- e.g. ScriptTarget.ES2015 -> "es6/es2015"
        local names = {}
        for name, value in option:EnumMap():Entries() do
            if value == defaultValue then
                names[#names + 1] = name
            end
        end
        return table.concat(names, "/")
    end
    return sprintV(defaultValue)
end

-- valueCandidate: { valueType ("one or more" or "any of"), possibleValues }

function tsc.showAdditionalInfoOutput(valueCandidates, option)
    if option.category == diagnostics.Command_line_Options then
        return false
    end
    if valueCandidates ~= nil and valueCandidates.possibleValues == "string" and
        (option.defaultValueDescription == nil or
            option.defaultValueDescription == "false" or
            option.defaultValueDescription == "n/a") then
        return false
    end
    return true
end

function tsc.getValueCandidate(sys, locale, option)
    -- option.type might be "string" | "number" | "boolean" | "object" | "list" | Map<string, number | string>
    -- string -- any of: string
    -- number -- any of: number
    -- boolean -- any of: boolean
    -- object -- null
    -- list -- one or more: , content depends on `option.element.type`, the same as others
    -- Map<string, number | string> -- any of: key1, key2, ....
    if option.kind == Kind.CommandLineOptionTypeObject then
        return nil
    end

    local res = { valueType = "", possibleValues = "" }
    if option.kind == Kind.CommandLineOptionTypeListOrElement then
        -- assert(option.type !== "listOrElement")
        error("no value candidate for list or element", 0)
    end

    local kind = option.kind
    if kind == Kind.CommandLineOptionTypeString or
        kind == Kind.CommandLineOptionTypeNumber or
        kind == Kind.CommandLineOptionTypeBoolean then
        res.valueType = diagnostics.X_type_Colon:Localize(locale)
    elseif kind == Kind.CommandLineOptionTypeList then
        res.valueType = diagnostics.X_one_or_more_Colon:Localize(locale)
    else
        res.valueType = diagnostics.X_one_of_Colon:Localize(locale)
    end

    res.possibleValues = tsc.getPossibleValues(option)

    return res
end

function tsc.getPossibleValues(option)
    local kind = option.kind
    if kind == Kind.CommandLineOptionTypeString or
        kind == Kind.CommandLineOptionTypeNumber or
        kind == Kind.CommandLineOptionTypeBoolean then
        return kind
    elseif kind == Kind.CommandLineOptionTypeList or
        kind == Kind.CommandLineOptionTypeListOrElement then
        return tsc.getPossibleValues(option:Elements())
    elseif kind == Kind.CommandLineOptionTypeObject then
        return ""
    else
        -- Map<string, number | string>
        -- Group synonyms: es6/es2015
        local enumMap = option:EnumMap()
        local inverted = collections.NewOrderedMapWithSizeHint(enumMap:Size())
        local deprecatedKeys = option:DeprecatedKeys()

        for name, value in enumMap:Entries() do
            if deprecatedKeys == nil or not deprecatedKeys:Has(name) then
                local list = core.Slice(inverted:GetOrZero(value) or {})
                list[#list + 1] = name
                inverted:Set(value, list)
            end
        end
        local syns = {}
        for synonyms in inverted:Values() do
            syns[#syns + 1] = table.concat(synonyms, "/")
        end
        return table.concat(syns, ", ")
    end
end

function tsc.getPrettyOutput(colors, left, right, rightAlignOfLeft, leftAlignOfRight, terminalWidth, colorLeft)
    -- !!! How does terminalWidth interact with UTF-8 encoding? Strada just assumed UTF-16.
    local res = {}
    local isFirstLine = true
    local remainRight = right
    local rightCharacterNumber = terminalWidth - leftAlignOfRight
    while #remainRight > 0 do
        local curLeft
        if isFirstLine then
            curLeft = padLeft(left, rightAlignOfLeft)
            curLeft = padRight(curLeft, leftAlignOfRight)
            if colorLeft then
                curLeft = colors:blue(curLeft)
            end
        else
            curLeft = string.rep(" ", leftAlignOfRight)
        end

        local idx = math.min(rightCharacterNumber, #remainRight)
        local curRight = string.sub(remainRight, 1, idx)
        remainRight = string.sub(remainRight, idx + 1)
        appendAll(res, curLeft, curRight, "\n")
        isFirstLine = false
    end
    return res
end

function tsc.getDisplayNameTextOfOption(option)
    local short = ""
    if option.shortName ~= "" then
        short = ", -" .. option.shortName
    end
    return "--" .. option.name .. short
end
