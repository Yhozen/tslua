local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local strings = require("tslua.module").strings

local commandLineParser = {}
commandLineParser.__index = commandLineParser
tsoptions.commandLineParser = commandLineParser

function commandLineParser:AlternateMode()
    return self.workerDiagnostics.didYouMean.alternateMode
end

function commandLineParser:OptionsDeclarations()
    return self.workerDiagnostics.didYouMean.optionDeclarations
end

function commandLineParser:UnknownOptionDiagnostic()
    return self.workerDiagnostics.didYouMean.unknownOptionDiagnostic
end

function commandLineParser:UnknownDidYouMeanDiagnostic()
    return self.workerDiagnostics.didYouMean.unknownDidYouMeanDiagnostic
end

-- commandLineParser fields: workerDiagnostics, optionsMap, fs, currentDirectory,
-- options (OrderedMap[string, any]), fileNames, errors, responseFileStack (set of paths).

function tsoptions.ParseCommandLine(
    commandLine,
    host
)
    if commandLine == nil then
        commandLine = {}
    end
    local parser = tsoptions.parseCommandLineWorker(tsoptions.CompilerOptionsDidYouMeanDiagnostics, commandLine, host:FS(), host:GetCurrentDirectory())
    local options = tsoptions.convertToOptionsWithAbsolutePaths(parser.options:Clone(), tsoptions.CommandLineCompilerOptionsMap, host:GetCurrentDirectory())
    local compilerOptions = tsoptions.convertMapToOptions(options, tsoptions.newCompilerOptionsParser(core.NewCompilerOptions())).CompilerOptions
    local watchOptions = tsoptions.convertMapToOptions(options, tsoptions.newWatchOptionsParser(core.NewWatchOptions())).WatchOptions
    local result = tsoptions.NewParsedCommandLine(compilerOptions, parser.fileNames, tspath.NewComparePathsOptions(
        host:FS():UseCaseSensitiveFileNames(),
        host:GetCurrentDirectory()
    ))
    result.parsedConfig.watchOptions = watchOptions
    result.errors = parser.errors
    result.raw = parser.options
    return result
end

function tsoptions.ParseBuildCommandLine(
    commandLine,
    host
)
    if commandLine == nil then
        commandLine = {}
    end
    local parser = tsoptions.parseCommandLineWorker(tsoptions.buildOptionsDidYouMeanDiagnostics, commandLine, host:FS(), host:GetCurrentDirectory())
    local compilerOptions = core.NewCompilerOptions()
    for key, value in parser.options:Entries() do
        local buildOption = tsoptions.BuildNameMap:Get(key)
        if buildOption == tsoptions.TscBuildOption or buildOption == tsoptions.CompilerNameMap:Get(key) then
            tsoptions.ParseCompilerOptions(key, value, compilerOptions)
        end
    end
    local result = setmetatable({
        buildOptions = tsoptions.convertMapToOptions(parser.options, tsoptions.newBuildOptionsParser(core.NewBuildOptions())).BuildOptions,
        compilerOptions = compilerOptions,
        watchOptions = tsoptions.convertMapToOptions(parser.options, tsoptions.newWatchOptionsParser(core.NewWatchOptions())).WatchOptions,
        projects = parser.fileNames,
        errors = parser.errors,
        raw = parser.options,

        comparePathsOptions = tspath.NewComparePathsOptions(
            host:FS():UseCaseSensitiveFileNames(),
            host:GetCurrentDirectory()
        ),
        resolvedProjectPaths = nil,
        resolvedProjectPathsOnce = false,
        locale = nil,
        localeOnce = false,
    }, tsoptions.ParsedBuildCommandLine)

    if #result.projects == 0 then
        -- tsc -b invoked with no extra arguments; act as if invoked with "tsc -b ."
        result.projects[#result.projects + 1] = "."
    end

    -- Nonsensical combinations
    if core.Tristate_IsTrue(result.buildOptions.clean) and core.Tristate_IsTrue(result.buildOptions.force) then
        result.errors = core.Append(result.errors, ast.NewCompilerDiagnostic(diagnostics.Options_0_and_1_cannot_be_combined, "clean", "force"))
    end
    if core.Tristate_IsTrue(result.buildOptions.clean) and core.Tristate_IsTrue(result.buildOptions.verbose) then
        result.errors = core.Append(result.errors, ast.NewCompilerDiagnostic(diagnostics.Options_0_and_1_cannot_be_combined, "clean", "verbose"))
    end
    if core.Tristate_IsTrue(result.buildOptions.clean) and core.Tristate_IsTrue(result.compilerOptions.watch) then
        result.errors = core.Append(result.errors, ast.NewCompilerDiagnostic(diagnostics.Options_0_and_1_cannot_be_combined, "clean", "watch"))
    end
    if core.Tristate_IsTrue(result.compilerOptions.watch) and core.Tristate_IsTrue(result.buildOptions.dry) then
        result.errors = core.Append(result.errors, ast.NewCompilerDiagnostic(diagnostics.Options_0_and_1_cannot_be_combined, "watch", "dry"))
    end

    return result
end

function tsoptions.parseCommandLineWorker(
    parseCommandLineWithDiagnostics,
    commandLine,
    fs,
    currentDirectory
)
    local parser = setmetatable({
        fs = fs,
        currentDirectory = currentDirectory,
        workerDiagnostics = parseCommandLineWithDiagnostics,
        fileNames = {},
        options = collections.NewOrderedMapWithSizeHint(0),
        errors = {},
        responseFileStack = {},
    }, commandLineParser)
    parser.optionsMap = tsoptions.GetNameMapFromList(parser:OptionsDeclarations())
    parser:parseStrings(commandLine)
    return parser
end

function commandLineParser:parseStrings(args)
    local i = 0
    while i < #args do
        local s = args[i + 1]
        i = i + 1
        if s == "" then
            goto continue
        end
        do
            local c = string.sub(s, 1, 1)
            if c == "@" then
                self:parseResponseFile(string.sub(s, 2))
            elseif c == "-" then
                local inputOptionName = tsoptions.getInputOptionName(s)
                local opt = self.optionsMap:GetOptionDeclarationFromName(inputOptionName, true --[[allowShort]])
                if opt ~= nil then
                    i = self:parseOptionValue(args, i, opt, self.workerDiagnostics.optionTypeMismatchDiagnostic)
                else
                    local watchOpt = tsoptions.WatchNameMap:GetOptionDeclarationFromName(inputOptionName, true --[[allowShort]])
                    if watchOpt ~= nil then
                        i = self:parseOptionValue(args, i, watchOpt, tsoptions.watchOptionsDidYouMeanDiagnostics.optionTypeMismatchDiagnostic)
                    else
                        self.errors[#self.errors + 1] = self:createUnknownOptionError(inputOptionName, s, nil, nil)
                    end
                end
            else
                self.fileNames[#self.fileNames + 1] = s
            end
        end
        ::continue::
    end
end

function tsoptions.getInputOptionName(input)
    -- removes at most two leading '-' from the input string
    return strings.TrimPrefix(strings.TrimPrefix(input, "-"), "-")
end

function commandLineParser:parseResponseFile(fileName)
    fileName = tspath.GetNormalizedAbsolutePath(fileName, self.currentDirectory)
    local path = tspath.ToPath(fileName, self.currentDirectory, self.fs:UseCaseSensitiveFileNames())
    if self.responseFileStack[path] then
        return
    end
    self.responseFileStack[path] = true

    local fileContents, errors = tsoptions.tryReadFile(fileName, function(name)
        if self.fs == nil then
            return "", false
        end
        local read, ok = self.fs:ReadFile(name)
        return read, ok
    end, self.errors)
    self.errors = errors

    if fileContents == "" then
        self.responseFileStack[path] = nil
        return
    end

    local args = {}
    local text = core.StringToRunes(fileContents)
    local textLength = #text
    local pos = 0
    local space = string.byte(" ")
    local quote = string.byte('"')
    while pos < textLength do
        while pos < textLength and text[pos + 1] <= space do
            pos = pos + 1
        end
        if pos >= textLength then
            break
        end
        local start = pos
        if text[pos + 1] == quote then
            pos = pos + 1
            while pos < textLength and text[pos + 1] ~= quote do
                pos = pos + 1
            end
            if pos < textLength then
                args[#args + 1] = core.RunesToString(core.Slice(text, start + 1, pos))
                pos = pos + 1
            else
                self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diagnostics.Unterminated_quoted_string_in_response_file_0, fileName)
            end
        else
            while pos < textLength and text[pos + 1] > space do
                pos = pos + 1
            end
            args[#args + 1] = core.RunesToString(core.Slice(text, start, pos))
        end
    end
    self:parseStrings(args)
    self.responseFileStack[path] = nil
end

-- Returns text, errors. readFile(fileName) -> text, ok.
function tsoptions.tryReadFile(fileName, readFile, errors)
    -- this function adds a compiler diagnostic if the file cannot be read
    local text, e = readFile(fileName)

    if not e then
        -- !!! Divergence: the returned error will not give a useful message
        -- errors = append(errors, ast.NewCompilerDiagnostic(diagnostics.Cannot_read_file_0_Colon_1, *e));
        text = ""
        errors = core.Append(errors, ast.NewCompilerDiagnostic(diagnostics.Cannot_read_file_0, fileName))
    end
    return text or "", errors
end

-- Go strconv.Atoi: optional sign followed by decimal digits, within int64 range.
local function atoi(s)
    if not string.match(s, "^[+-]?%d+$") then
        return nil
    end
    return math.tointeger(tonumber(s))
end

function commandLineParser:parseOptionValue(
    args,
    i,
    opt,
    diag
)
    if opt.isTSConfigOnly and i <= #args then
        local optValue = ""
        if i < #args then
            optValue = args[i + 1]
        end
        if optValue == "null" then
            self.options:Set(opt.name, nil)
            i = i + 1
        elseif opt.kind == "boolean" then
            if optValue == "false" then
                self.options:Set(opt.name, false)
                i = i + 1
            else
                if optValue == "true" then
                    i = i + 1
                end
                self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diagnostics.Option_0_can_only_be_specified_in_tsconfig_json_file_or_set_to_false_or_null_on_command_line, opt.name)
            end
        else
            self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diagnostics.Option_0_can_only_be_specified_in_tsconfig_json_file_or_set_to_null_on_command_line, opt.name)
            if #optValue ~= 0 and not strings.HasPrefix(optValue, "-") then
                i = i + 1
            end
        end
    else
        -- Check to see if no argument was provided (e.g. "--locale" is the last command-line argument).
        if i >= #args then
            if opt.kind ~= "boolean" then
                self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diag, opt.name, tsoptions.getCompilerOptionValueTypeString(opt))
                if opt.kind == "list" then
                    self.options:Set(opt.name, {})
                elseif opt.kind == "enum" then
                    self.errors[#self.errors + 1] = tsoptions.createDiagnosticForInvalidEnumType(opt, nil, nil)
                end
            else
                self.options:Set(opt.name, true)
            end
            return i
        end
        if args[i + 1] ~= "null" then
            local kind = opt.kind
            if kind == "number" then
                -- !!! Make sure this parseInt matches JS parseInt
                local num = atoi(args[i + 1])
                if num ~= nil then
                    if num >= opt.minValue then
                        self.options:Set(opt.name, num)
                    else
                        self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diagnostics.Option_0_requires_value_to_be_greater_than_1, opt.name, tostring(opt.minValue))
                    end
                else
                    self.errors[#self.errors + 1] = ast.NewCompilerDiagnostic(diag, opt.name, "number")
                end
                i = i + 1
            elseif kind == "boolean" then
                -- boolean flag has optional value true, false, others
                local optValue = args[i + 1]

                -- check next argument as boolean flag value
                if optValue == "false" then
                    self.options:Set(opt.name, false)
                else
                    self.options:Set(opt.name, true)
                end
                -- try to consume next argument as value for boolean flag; do not consume argument if it is not "true" or "false"
                if optValue == "false" or optValue == "true" then
                    i = i + 1
                end
            elseif kind == "string" then
                local val, err = tsoptions.validateJsonOptionValue(opt, args[i + 1], nil, nil)
                if err == nil then
                    self.options:Set(opt.name, val)
                else
                    self.errors = core.AppendAll(self.errors, err)
                end
                i = i + 1
            elseif kind == "list" then
                local result, err = self:parseListTypeOption(opt, args[i + 1])
                self.options:Set(opt.name, result)
                self.errors = core.AppendAll(self.errors, err)
                if core.Len(result) > 0 or core.Len(err) > 0 then
                    i = i + 1
                end
            elseif kind == "listOrElement" then
                -- If not a primitive, the possible types are specified in what is effectively a map of options.
                error("listOrElement not supported here", 0)
            else
                local val, err = tsoptions.convertJsonOptionOfEnumType(opt, strings.TrimFunc(args[i + 1], stringutil.IsWhiteSpaceLike), nil, nil)
                self.options:Set(opt.name, val)
                self.errors = core.AppendAll(self.errors, err)
                i = i + 1
            end
        else
            self.options:Set(opt.name, nil)
            i = i + 1
        end
    end
    return i
end

function commandLineParser:parseListTypeOption(opt, value)
    return tsoptions.ParseListTypeOption(opt, value)
end

-- Returns values, errors.
function tsoptions.ParseListTypeOption(opt, value)
    value = strings.TrimSpace(value)
    local errors = nil
    if strings.HasPrefix(value, "-") then
        return {}, errors
    end
    if opt.kind == "listOrElement" and not strings.Contains(value, ",") then
        local val, err = tsoptions.validateJsonOptionValue(opt, value, nil, nil)
        if err ~= nil then
            return {}, err
        end
        return { val }, errors
    end
    if value == "" then
        return {}, errors
    end
    local values = strings.Split(value, ",")
    local elementKind = opt:Elements().kind
    if elementKind == "string" then
        local elements = core.MapFiltered(values, function(v)
            local val, err = tsoptions.validateJsonOptionValue(opt:Elements(), v, nil, nil)
            if type(val) == "string" and core.Len(err) == 0 and val ~= "" then
                return val, true
            end
            errors = core.AppendAll(errors, err)
            return "", false
        end)
        return elements, errors
    elseif elementKind == "boolean" or elementKind == "object" or elementKind == "number" then
        -- do nothing: only string and enum/object types currently allowed as list entries
        -- 				!!! we don't actually have number list options, so I didn't implement number list parsing
        error("List of " .. elementKind .. " is not yet supported.", 0)
    else
        local result = core.MapFiltered(values, function(v)
            local val, err = tsoptions.convertJsonOptionOfEnumType(opt:Elements(), strings.TrimFunc(v, stringutil.IsWhiteSpaceLike), nil, nil)
            if type(val) == "string" and core.Len(err) == 0 and val ~= "" then
                return val, true
            end
            errors = core.AppendAll(errors, err)
            return "", false
        end)
        return result, errors
    end
end

-- Returns value, errors.
function tsoptions.convertJsonOptionOfEnumType(
    opt,
    value,
    valueExpression,
    sourceFile
)
    if value == "" then
        return nil, nil
    end
    local key = strings.ToLower(value)
    local typeMap = opt:EnumMap()
    if typeMap == nil then
        return nil, nil
    end
    local val, ok = typeMap:Get(key)
    if ok then
        return tsoptions.validateJsonOptionValue(opt, val, valueExpression, sourceFile)
    end
    return nil, { tsoptions.createDiagnosticForInvalidEnumType(opt, sourceFile, valueExpression) }
end
