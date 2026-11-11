local harnessutil = require("tslua.testutil.harnessutil")
local ast = require("tslua.ast")
local bundled = require("tslua.bundled")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local outputpaths = require("tslua.outputpaths")
local parser = require("tslua.parser")
local repo = require("tslua.repo")
local sourcemap = require("tslua.sourcemap")
local testutil = require("tslua.testutil")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")
local osvfs = require("tslua.vfs.osvfs")
local vfstest = require("tslua.vfs.vfstest")

local Tristate = core.Tristate
local CommandLineOptionKind = tsoptions.CommandLineOptionKind
local fstest = vfs.iofs.fstest

-- Posix-style path to additional test libraries
harnessutil.testLibFolder = "/.lib"

-- TestFile: { unitName = "", content = "" }
function harnessutil.NewTestFile(unitName, content)
    return { unitName = unitName or "", content = content or "" }
end

-- TestConfiguration maps a compiler setting to its string value, after splitting by commas,
-- handling inclusions and exclusions, and deduplicating (a Lua table name -> value).
-- For example, if a test file contains:
--
--	// @target: esnext, es2015
--
-- Then the map will map "target" to "esnext", and another map will map "target" to "es2015".

-- NamedTestConfiguration: { name = "", config = TestConfiguration }

-- HarnessOptions (Go struct literal with zero values).
function harnessutil.NewHarnessOptions(init)
    local o = {
        useCaseSensitiveFileNames = false,
        baselineFile = "",
        includeBuiltFile = "",
        fileName = "",
        libFiles = nil,
        noImplicitReferences = false,
        currentDirectory = "",
        symlink = "",
        link = "",
        noTypesAndSymbols = false,
        fullEmitPaths = false,
        reportDiagnostics = false,
        captureSuggestions = false,
        typescriptVersion = "",
    }
    for k, v in pairs(init or {}) do
        o[k] = v
    end
    return o
end

local function copyHarnessOptions(o)
    return harnessutil.NewHarnessOptions(o)
end

local function strEqualFold(a, b)
    return string.lower(a) == string.lower(b)
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end
harnessutil.sortedKeys = sortedKeys

-- tsoptions.ParsedCommandLine literal { ParsedConfig, ConfigFile, Errors }.
function harnessutil.newParsedCommandLine(parsedConfig, configFile, errors)
    return setmetatable({
        parsedConfig = parsedConfig,
        configFile = configFile,
        errors = errors,
    }, tsoptions.ParsedCommandLine)
end

-- tsoptions.ParsedOptions literal { CompilerOptions, FileNames, ContentMappers }.
function harnessutil.newParsedOptions(compilerOptions, fileNames, contentMappers)
    local o = {
        compilerOptions = compilerOptions,
        fileNames = fileNames,
        contentMappers = contentMappers,
    }
    if tsoptions.ParsedOptions ~= nil and type(tsoptions.ParsedOptions) == "table" and tsoptions.ParsedOptions.__index ~= nil then
        setmetatable(o, tsoptions.ParsedOptions)
    end
    return o
end

function harnessutil.CompileFiles(t, inputFiles, otherFiles, testConfig, tsconfig, currentDirectory, symlinks)
    local compilerOptions
    if tsconfig ~= nil then
        compilerOptions = tsconfig.parsedConfig.compilerOptions:Clone()
    end
    if compilerOptions == nil then
        compilerOptions = core.NewCompilerOptions()
    end
    -- Set default options for tests
    if compilerOptions.newLine == core.NewLineKind.None then
        compilerOptions.newLine = core.NewLineKind.CRLF
    end
    if compilerOptions.skipDefaultLibCheck == Tristate.TSUnknown then
        compilerOptions.skipDefaultLibCheck = Tristate.TSTrue
    end
    compilerOptions.noErrorTruncation = Tristate.TSTrue
    local harnessOptions = harnessutil.NewHarnessOptions({ useCaseSensitiveFileNames = true, currentDirectory = currentDirectory })

    -- Parse harness and compiler options from the test configuration
    if testConfig ~= nil then
        harnessutil.SetOptionsFromTestConfig(t, testConfig, compilerOptions, harnessOptions, currentDirectory, false --[[allowUnknownOptions]])
    end

    return harnessutil.CompileFilesEx(t, inputFiles, otherFiles, harnessOptions, compilerOptions, currentDirectory, symlinks, tsconfig)
end

function harnessutil.CompileFilesEx(t, inputFiles, otherFiles, harnessOptions, compilerOptions, currentDirectory, symlinks, tsconfig)
    local programFileNames = {}
    for _, file in ipairs(inputFiles or {}) do
        local fileName = tspath.GetNormalizedAbsolutePath(file.unitName, currentDirectory)

        if not tspath.FileExtensionIs(fileName, tspath.ExtensionJson) and
            not tspath.FileExtensionIs(fileName, tspath.ExtensionTsBuildInfo) then
            programFileNames[#programFileNames + 1] = fileName
        end
    end

    -- !!! Note: lib files are not going to be in `built/local`.
    -- In addition, not all files that used to be in `built/local` are going to exist.
    -- Files from built\local that are requested by test "@includeBuiltFiles" to be in the context.
    -- Treat them as library files, so include them in build, but not in baselines.

    -- Performance optimization; avoid copying in the /.lib folder if the test doesn't need it.
    local includeLibDir = core.Some(inputFiles or {}, function(file)
        return string.find(file.content, harnessutil.testLibFolder .. "/", 1, true) ~= nil
    end)

    -- Files from testdata\lib that are requested by "@libFiles"
    if core.Len(harnessOptions.libFiles) > 0 then
        for _, libFile in ipairs(harnessOptions.libFiles) do
            if libFile == "lib.d.ts" and compilerOptions.noLib ~= Tristate.TSTrue then
                -- We used to override lib with a custom lib.d.ts for some reason. Skip this unless it becomes necessary.
                goto continue
            end
            programFileNames[#programFileNames + 1] = tspath.CombinePaths(harnessutil.testLibFolder, libFile)
            includeLibDir = true
            ::continue::
        end
    end

    if includeLibDir then
        repo.SkipIfNoTypeScriptSubmodule(t)
    end

    -- !!!
    -- ts.assign(options, ts.convertToOptionsWithAbsolutePaths(options, path => ts.getNormalizedAbsolutePath(path, currentDirectory)));
    if compilerOptions.outDir ~= "" then
        compilerOptions.outDir = tspath.GetNormalizedAbsolutePath(compilerOptions.outDir, currentDirectory)
    end
    if compilerOptions.project ~= "" then
        compilerOptions.project = tspath.GetNormalizedAbsolutePath(compilerOptions.project, currentDirectory)
    end
    if compilerOptions.rootDir ~= "" then
        compilerOptions.rootDir = tspath.GetNormalizedAbsolutePath(compilerOptions.rootDir, currentDirectory)
    end
    if compilerOptions.tsBuildInfoFile ~= "" then
        compilerOptions.tsBuildInfoFile = tspath.GetNormalizedAbsolutePath(compilerOptions.tsBuildInfoFile, currentDirectory)
    end
    if compilerOptions.baseUrl ~= "" then
        compilerOptions.baseUrl = tspath.GetNormalizedAbsolutePath(compilerOptions.baseUrl, currentDirectory)
    end
    if compilerOptions.declarationDir ~= "" then
        compilerOptions.declarationDir = tspath.GetNormalizedAbsolutePath(compilerOptions.declarationDir, currentDirectory)
    end
    for i, rootDir in ipairs(compilerOptions.rootDirs or {}) do
        compilerOptions.rootDirs[i] = tspath.GetNormalizedAbsolutePath(rootDir, currentDirectory)
    end
    for i, typeRoot in ipairs(compilerOptions.typeRoots or {}) do
        compilerOptions.typeRoots[i] = tspath.GetNormalizedAbsolutePath(typeRoot, currentDirectory)
    end

    local contentMappers = nil
    if tsconfig ~= nil and tsconfig.parsedConfig ~= nil then
        contentMappers = tsconfig.parsedConfig.contentMappers
    end

    -- Create fake FS for testing
    local testfs = {}
    for _, file in ipairs(inputFiles or {}) do
        local fileName = tspath.GetNormalizedAbsolutePath(file.unitName, currentDirectory)
        testfs[fileName] = fstest.NewMapFile({ data = file.content })
    end
    for _, file in ipairs(otherFiles or {}) do
        local fileName = tspath.GetNormalizedAbsolutePath(file.unitName, currentDirectory)
        testfs[fileName] = fstest.NewMapFile({ data = file.content })
    end
    for _, src in ipairs(sortedKeys(symlinks)) do
        local target = symlinks[src]
        local srcFileName = tspath.GetNormalizedAbsolutePath(src, currentDirectory)
        local targetFileName = tspath.GetNormalizedAbsolutePath(target, currentDirectory)
        testfs[srcFileName] = vfstest.Symlink(targetFileName)
    end

    if includeLibDir then
        for k, v in pairs(harnessutil.testLibFolderMap()) do
            testfs[k] = v
        end
    end

    local fs = vfstest.FromMap(testfs, harnessOptions.useCaseSensitiveFileNames)
    fs = bundled.WrapFS(fs)
    fs = harnessutil.NewOutputRecorderFS(fs)

    -- Content mappers, when trusted, are served in-process by the test mapper (see contentmappertest).
    -- The host is shared by the pre- and post-emit programs and torn down when this compilation finishes.
    if core.Tristate_IsTrue(compilerOptions.runExternalCode) and core.Len(contentMappers) > 0 then
        error("not implemented: contentmapper.NewHost (content mappers are out of scope)", 0)
    end

    local configFile = nil
    local errors = nil
    if tsconfig ~= nil then
        configFile = tsconfig.configFile
        errors = tsconfig.errors
    end
    local config = harnessutil.newParsedCommandLine(
        harnessutil.newParsedOptions(compilerOptions, programFileNames, contentMappers),
        configFile,
        errors
    )
    local contentMapperProject = nil
    local host = harnessutil.createCompilerHost(fs, bundled.LibPath(), currentDirectory, contentMapperProject)
    local result = harnessutil.compileFilesWithHost(host, config, harnessOptions)
    result.symlinks = symlinks
    result.trace = host.tracer:String()
    result.repeat_ = function(testConfig)
        local newHarnessOptions = copyHarnessOptions(harnessOptions)
        local newCompilerOptions = compilerOptions:Clone()
        harnessutil.SetOptionsFromTestConfig(t, testConfig, newCompilerOptions, newHarnessOptions, currentDirectory, false --[[allowUnknownOptions]])
        return harnessutil.CompileFilesEx(t, inputFiles, otherFiles, newHarnessOptions, newCompilerOptions, currentDirectory, symlinks, tsconfig)
    end
    return result
end

local testLibFolderMapValue = nil

function harnessutil.testLibFolderMap()
    if testLibFolderMapValue == nil then
        local testfs = {}
        local root = repo.TypeScriptSubmodulePath() .. "/tests/lib"
        local osfs = osvfs.FS()
        local err = osfs:WalkDir(root, function(path, d, err)
            if err ~= nil then
                return err
            end
            if d:IsDir() then
                return nil
            end
            local content, ok = osvfs.osReadFile(path)
            if content == nil then
                return ok
            end
            local rel = string.sub(path, #root + 2)
            testfs[harnessutil.testLibFolder .. "/" .. rel] = fstest.NewMapFile({ data = content })
            return nil
        end)
        if err ~= nil then
            error(string.format("Failed to read lib dir: %s", err:Error()), 0)
        end
        testLibFolderMapValue = testfs
    end
    return testLibFolderMapValue
end

function harnessutil.SetOptionsFromTestConfig(t, testConfig, compilerOptions, harnessOptions, currentDirectory, allowUnknownOptions)
    for _, name in ipairs(sortedKeys(testConfig)) do
        local value = testConfig[name]
        if name == "typescriptversion" then
            goto continue
        end

        do
            local commandLineOption = harnessutil.getCommandLineOption(name)
            if commandLineOption ~= nil then
                local parsedValue = harnessutil.getOptionValue(t, commandLineOption, value, currentDirectory)
                local errors = tsoptions.ParseCompilerOptions(commandLineOption.name, parsedValue, compilerOptions)
                if core.Len(errors) > 0 then
                    t:Fatalf("Error parsing value '%s' for compiler option '%s'.", value, commandLineOption.name)
                end
                goto continue
            end
            local harnessOption = harnessutil.getHarnessOption(name)
            if harnessOption ~= nil then
                local parsedValue = harnessutil.getOptionValue(t, harnessOption, value, currentDirectory)
                harnessutil.parseHarnessOption(t, harnessOption.name, parsedValue, harnessOptions)
                goto continue
            end
            if not allowUnknownOptions then
                t:Fatalf("Unknown compiler option '%s'.", name)
            end
        end
        ::continue::
    end
end

local compilerOptionsValue = nil

-- Go package var compilerOptions: tsoptions.OptionsDeclarations plus harness-only options.
function harnessutil.compilerOptions()
    if compilerOptionsValue == nil then
        compilerOptionsValue = core.Concatenate(
            tsoptions.OptionsDeclarations,
            {
                tsoptions.newCommandLineOption({
                    name = "allowNonTsExtensions",
                    kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
                }),
                tsoptions.newCommandLineOption({
                    name = "noErrorTruncation",
                    kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
                }),
                tsoptions.newCommandLineOption({
                    name = "suppressOutputPathCheck",
                    kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
                }),
                tsoptions.newCommandLineOption({
                    name = "noCheck",
                    kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
                }),
            }
        )
    end
    return compilerOptionsValue
end

local harnessCommandLineOptionsValue = nil

function harnessutil.harnessCommandLineOptions()
    if harnessCommandLineOptionsValue == nil then
        local String = CommandLineOptionKind.CommandLineOptionTypeString
        local Boolean = CommandLineOptionKind.CommandLineOptionTypeBoolean
        local List = CommandLineOptionKind.CommandLineOptionTypeList
        harnessCommandLineOptionsValue = {
            tsoptions.newCommandLineOption({ name = "useCaseSensitiveFileNames", kind = Boolean }),
            tsoptions.newCommandLineOption({ name = "baselineFile", kind = String }),
            tsoptions.newCommandLineOption({ name = "includeBuiltFile", kind = String }),
            tsoptions.newCommandLineOption({ name = "fileName", kind = String }),
            tsoptions.newCommandLineOption({ name = "libFiles", kind = List }),
            tsoptions.newCommandLineOption({ name = "noImplicitReferences", kind = Boolean }),
            tsoptions.newCommandLineOption({ name = "currentDirectory", kind = String }),
            tsoptions.newCommandLineOption({ name = "symlink", kind = String }),
            tsoptions.newCommandLineOption({ name = "link", kind = String }),
            tsoptions.newCommandLineOption({ name = "noTypesAndSymbols", kind = Boolean }),
            -- Emitted js baseline will print full paths for every output file
            tsoptions.newCommandLineOption({ name = "fullEmitPaths", kind = Boolean }),
            -- used to enable error collection in `transpile` baselines
            tsoptions.newCommandLineOption({ name = "reportDiagnostics", kind = Boolean }),
            -- Adds suggestion diagnostics to error baselines
            tsoptions.newCommandLineOption({ name = "captureSuggestions", kind = Boolean }),
        }
    end
    return harnessCommandLineOptionsValue
end

function harnessutil.getHarnessOption(name)
    return core.Find(harnessutil.harnessCommandLineOptions(), function(option)
        return strEqualFold(option.name, name)
    end)
end

function harnessutil.parseHarnessOption(t, key, value, harnessOptions)
    if key == "useCaseSensitiveFileNames" then
        harnessOptions.useCaseSensitiveFileNames = value
    elseif key == "baselineFile" then
        harnessOptions.baselineFile = value
    elseif key == "includeBuiltFile" then
        harnessOptions.includeBuiltFile = value
    elseif key == "fileName" then
        harnessOptions.fileName = value
    elseif key == "libFiles" then
        harnessOptions.libFiles = {}
        for _, v in ipairs(value) do
            harnessOptions.libFiles[#harnessOptions.libFiles + 1] = v
        end
    elseif key == "noImplicitReferences" then
        harnessOptions.noImplicitReferences = value
    elseif key == "currentDirectory" then
        harnessOptions.currentDirectory = value
    elseif key == "symlink" then
        harnessOptions.symlink = value
    elseif key == "link" then
        harnessOptions.link = value
    elseif key == "noTypesAndSymbols" then
        harnessOptions.noTypesAndSymbols = value
    elseif key == "fullEmitPaths" then
        harnessOptions.fullEmitPaths = value
    elseif key == "reportDiagnostics" then
        harnessOptions.reportDiagnostics = value
    elseif key == "captureSuggestions" then
        harnessOptions.captureSuggestions = value
    elseif key == "typescriptVersion" then
        harnessOptions.typescriptVersion = value
    else
        t:Fatalf("Unknown harness option '%s'.", key)
    end
end

-- strconv.Atoi
local function atoi(s)
    if string.match(s, "^[+-]?%d+$") == nil then
        return nil
    end
    return math.tointeger(tonumber(s))
end

local function enumMapKeys(option)
    return core.Collect(option:EnumMap():Keys())
end

function harnessutil.getOptionValue(t, option, value, cwd)
    local kind = option.kind
    if kind == CommandLineOptionKind.CommandLineOptionTypeString then
        if option.isFilePath then
            return tspath.GetNormalizedAbsolutePath(value, cwd)
        end
        return value
    elseif kind == CommandLineOptionKind.CommandLineOptionTypeNumber then
        local numVal = atoi(value)
        if numVal == nil then
            t:Fatalf("Value for option '%s' must be a number, got: %v", option.name, value)
        end
        return numVal
    elseif kind == CommandLineOptionKind.CommandLineOptionTypeBoolean then
        local lower = string.lower(value)
        if lower == "true" then
            return true
        elseif lower == "false" then
            return false
        else
            t:Fatalf("Value for option '%s' must be a boolean, got: %v", option.name, value)
        end
    elseif kind == CommandLineOptionKind.CommandLineOptionTypeEnum then
        local enumVal, ok = option:EnumMap():Get(string.lower(value))
        if not ok then
            t:Fatalf("Value for option '%s' must be one of %s, got: %v", option.name, table.concat(enumMapKeys(option), ","), value)
        end
        return enumVal
    elseif kind == CommandLineOptionKind.CommandLineOptionTypeList or kind == CommandLineOptionKind.CommandLineOptionTypeListOrElement then
        local listVal, errors = tsoptions.ParseListTypeOption(option, value)
        if option:Elements().isFilePath then
            return core.Map(listVal, function(item)
                return tspath.GetNormalizedAbsolutePath(item, cwd)
            end)
        end
        if core.Len(errors) > 0 then
            t:Fatalf("Unknown value '%s' for compiler option '%s'", value, option.name)
        end
        return listVal
    elseif kind == CommandLineOptionKind.CommandLineOptionTypeObject then
        t:Fatalf("Object type options like '%s' are not supported", option.name)
    end
    return nil
end

-- cachedCompilerHost embeds a compiler.CompilerHost (field CompilerHost; its methods are
-- promoted through __index) and adds a tracer.
local cachedCompilerHost = {}
harnessutil.cachedCompilerHost = cachedCompilerHost
cachedCompilerHost.__index = function(self, key)
    local m = cachedCompilerHost[key]
    if m ~= nil then
        return m
    end
    local inner = rawget(self, "CompilerHost")
    local v = inner[key]
    if type(v) == "function" then
        return function(_, ...)
            return v(inner, ...)
        end
    end
    return v
end

-- sourceFileCache: SourceFileCacheKey -> *ast.SourceFile. Lua tables cannot use struct keys, so
-- the cache is nested: text -> scriptKind -> encoded parse options -> source file.
harnessutil.sourceFileCache = {}

-- SourceFileCacheKey: { opts = ast.SourceFileParseOptions, text = "", scriptKind = core.ScriptKind }
function harnessutil.GetSourceFileCacheKey(opts, text, scriptKind)
    return {
        opts = opts,
        text = text,
        scriptKind = scriptKind,
    }
end

local function encodeParseOptions(opts)
    local emi = opts.externalModuleIndicatorOptions or {}
    return table.concat({
        opts.fileName or "",
        opts.path or "",
        tostring(emi.jsx == true),
        tostring(emi.force == true),
    }, "\0")
end

local function cacheLoad(key)
    local byKind = harnessutil.sourceFileCache[key.text]
    if byKind == nil then
        return nil, false
    end
    local byOpts = byKind[key.scriptKind]
    if byOpts == nil then
        return nil, false
    end
    local v = byOpts[encodeParseOptions(key.opts)]
    return v, v ~= nil
end

local function cacheLoadOrStore(key, value)
    local existing, ok = cacheLoad(key)
    if ok then
        return existing, true
    end
    local byKind = harnessutil.sourceFileCache[key.text]
    if byKind == nil then
        byKind = {}
        harnessutil.sourceFileCache[key.text] = byKind
    end
    local byOpts = byKind[key.scriptKind]
    if byOpts == nil then
        byOpts = {}
        byKind[key.scriptKind] = byOpts
    end
    byOpts[encodeParseOptions(key.opts)] = value
    return value, false
end

function cachedCompilerHost:GetSourceFile(opts)
    local text, ok = self:FS():ReadFile(opts.fileName)
    if not ok then
        return nil
    end

    local scriptKind = core.GetScriptKindFromFileName(opts.fileName)
    if scriptKind == core.ScriptKind.Unknown then
        error("Unknown script kind for file  " .. opts.fileName, 0)
    end

    local key = harnessutil.GetSourceFileCacheKey(opts, text, scriptKind)

    local cached, found = cacheLoad(key)
    if found then
        return cached
    end

    local sourceFile = parser.ParseSourceFile(opts, text, scriptKind)
    local result = cacheLoadOrStore(key, sourceFile)
    return result
end

-- TracerForBaselining: { opts = tspath.ComparePathsOptions, packageJsonCache = map, builder = core.StringBuilder }
local TracerForBaselining = {}
TracerForBaselining.__index = TracerForBaselining
harnessutil.TracerForBaselining = TracerForBaselining

function harnessutil.NewTracerForBaselining(opts, builder)
    return setmetatable({
        opts = opts,
        packageJsonCache = {},
        builder = builder,
    }, TracerForBaselining)
end

function TracerForBaselining:Trace(msg, ...)
    self:TraceWithWriter(self.builder, msg:Localize(nil --[[locale.Default]], ...), true)
end

function TracerForBaselining:TraceWithWriter(w, msg, usePackageJsonCache)
    w:WriteString(self:sanitizeTrace(msg, usePackageJsonCache) .. "\n")
end

local function cutSuffix(s, suffix)
    if #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix then
        return string.sub(s, 1, #s - #suffix), true
    end
    return s, false
end

local function cutPrefix(s, prefix)
    if string.sub(s, 1, #prefix) == prefix then
        return string.sub(s, #prefix + 1), true
    end
    return s, false
end

-- strings.Replace(s, old, new, 1)
local function replaceOnce(s, old, new)
    local i = string.find(s, old, 1, true)
    if i == nil then
        return s
    end
    return string.sub(s, 1, i - 1) .. new .. string.sub(s, i + #old)
end

function TracerForBaselining:sanitizeTrace(msg, usePackageJsonCache)
    -- Version
    do
        local str = replaceOnce(msg, "'" .. core.Version() .. "'", "'" .. harnessutil.FakeTSVersion .. "'")
        if str ~= msg then
            return str
        end
    end
    -- caching of fs in trace to be replaces with non caching version
    do
        local str, ok = cutSuffix(msg, "' does not exist according to earlier cached lookups.")
        if ok then
            local file = cutPrefix(str, "File '")
            if usePackageJsonCache then
                local filePath = tspath.ToPath(file, self.opts.currentDirectory, self.opts.useCaseSensitiveFileNames)
                if self.packageJsonCache[filePath] ~= nil then
                    return msg
                else
                    self.packageJsonCache[filePath] = false
                end
            end
            return "File '" .. file .. "' does not exist."
        end
    end
    do
        local str, ok = cutSuffix(msg, "' exists according to earlier cached lookups.")
        if ok then
            local file = cutPrefix(str, "File '")
            if usePackageJsonCache then
                local filePath = tspath.ToPath(file, self.opts.currentDirectory, self.opts.useCaseSensitiveFileNames)
                if self.packageJsonCache[filePath] ~= nil then
                    return msg
                else
                    self.packageJsonCache[filePath] = true
                end
            end
            return "Found 'package.json' at '" .. file .. "'."
        end
    end
    if usePackageJsonCache then
        do
            local str, ok = cutSuffix(msg, "' does not exist.")
            if ok then
                local file = cutPrefix(str, "File '")
                local filePath = tspath.ToPath(file, self.opts.currentDirectory, self.opts.useCaseSensitiveFileNames)
                if self.packageJsonCache[filePath] == nil then
                    self.packageJsonCache[filePath] = false
                    return msg
                else
                    return "File '" .. file .. "' does not exist according to earlier cached lookups."
                end
            end
        end
        do
            local str, ok = cutPrefix(msg, "Found 'package.json' at '")
            if ok then
                local file = cutSuffix(str, "'.")
                local filePath = tspath.ToPath(file, self.opts.currentDirectory, self.opts.useCaseSensitiveFileNames)
                if self.packageJsonCache[filePath] == nil then
                    self.packageJsonCache[filePath] = true
                    return msg
                else
                    return "File '" .. file .. "' exists according to earlier cached lookups."
                end
            end
        end
    end
    return msg
end

function TracerForBaselining:String()
    return self.builder:String()
end

function TracerForBaselining:Reset()
    self.packageJsonCache = {}
end

function harnessutil.createCompilerHost(fs, defaultLibraryPath, currentDirectory, contentMapperProject)
    local tracer = harnessutil.NewTracerForBaselining({
        useCaseSensitiveFileNames = fs:UseCaseSensitiveFileNames(),
        currentDirectory = currentDirectory,
    }, core.NewStringBuilder())
    return setmetatable({
        CompilerHost = compiler.NewCompilerHost(currentDirectory, fs, defaultLibraryPath, nil, function(msg, ...)
            tracer:Trace(msg, ...)
        end, contentMapperProject),
        tracer = tracer,
    }, cachedCompilerHost)
end

local function appendAll(xs, ys)
    for _, y in ipairs(ys or {}) do
        xs[#xs + 1] = y
    end
    return xs
end

function harnessutil.compileFilesWithHost(host, config, harnessOptions)
    -- !!!
    -- if (compilerOptions.project || !rootFiles || rootFiles.length === 0) {
    -- 	const project = readProject(host.parseConfigHost, compilerOptions.project, compilerOptions);
    -- 	if (project) {
    -- 		if (project.errors && project.errors.length > 0) {
    -- 			return new CompilationResult(host, compilerOptions, /*program*/ undefined, /*result*/ undefined, project.errors);
    -- 		}
    -- 		if (project.config) {
    -- 			rootFiles = project.config.fileNames;
    -- 			compilerOptions = project.config.options;
    -- 		}
    -- 	}
    -- 	delete compilerOptions.project;
    -- }

    local ctx = nil -- context.Background()

    local preErrors = {}
    local preCompilerOptions = config:CompilerOptions():Clone()
    preCompilerOptions.traceResolution = Tristate.TSFalse
    local preConfig = harnessutil.newParsedCommandLine(
        harnessutil.newParsedOptions(preCompilerOptions, config:FileNames(), config:ContentMappers()),
        config.configFile,
        config.errors
    )
    local preProgram = harnessutil.createProgram(host, preConfig)
    appendAll(preErrors, preProgram:GetConfigFileParsingDiagnostics())
    appendAll(preErrors, preProgram:GetProgramDiagnostics())
    appendAll(preErrors, preProgram:GetSyntacticDiagnostics(ctx, nil))
    appendAll(preErrors, preProgram:GetSemanticDiagnostics(ctx, nil))
    appendAll(preErrors, preProgram:GetGlobalDiagnostics(ctx))
    if preProgram:Options():GetEmitDeclarations() then
        appendAll(preErrors, preProgram:GetDeclarationDiagnostics(ctx, nil))
    end
    if harnessOptions.captureSuggestions then
        appendAll(preErrors, preProgram:GetSuggestionDiagnostics(ctx, nil))
    end
    preErrors = compiler.SortAndDeduplicateDiagnostics(preErrors)

    local postProgram = harnessutil.createProgram(host, config)
    local emitResult = postProgram:Emit(ctx, compiler.NewEmitOptions({}))
    local postErrors = {}
    appendAll(postErrors, postProgram:GetConfigFileParsingDiagnostics())
    appendAll(postErrors, postProgram:GetProgramDiagnostics())
    appendAll(postErrors, postProgram:GetSyntacticDiagnostics(ctx, nil))
    appendAll(postErrors, postProgram:GetSemanticDiagnostics(ctx, nil))
    appendAll(postErrors, postProgram:GetGlobalDiagnostics(ctx))
    if postProgram:Options():GetEmitDeclarations() then
        appendAll(postErrors, postProgram:GetDeclarationDiagnostics(ctx, nil))
    end
    if harnessOptions.captureSuggestions then
        appendAll(postErrors, postProgram:GetSuggestionDiagnostics(ctx, nil))
    end
    postErrors = compiler.SortAndDeduplicateDiagnostics(postErrors)

    local errors = postErrors
    if #postErrors ~= #preErrors then
        local longerErrors = postErrors
        local shorterErrors = preErrors
        if #preErrors > #postErrors then
            longerErrors, shorterErrors = preErrors, postErrors
        end
        local diag = ast.NewCompilerDiagnostic(
            diagnostics.NewAdHocMessage(string.format("Pre-emit (%d) and post-emit (%d) diagnostic counts do not match! This can indicate that a semantic _error_ was added by the emit resolver - such an error may not be reflected on the command line or in the editor, but may be captured in a baseline here!", #preErrors, #postErrors))
        )
        diag = diag:AddRelatedInfo(ast.NewCompilerDiagnostic(diagnostics.NewAdHocMessage("The excess diagnostics are:")))
        for _, d in ipairs(longerErrors) do
            local matched = false
            for _, d2 in ipairs(shorterErrors) do
                local comparison = ast.CompareDiagnostics(d, d2)
                if comparison == 0 then
                    matched = true
                    break
                end
            end
            if not matched then
                diag = diag:AddRelatedInfo(d)
            end
        end
        errors = {}
        appendAll(errors, shorterErrors)
        errors[#errors + 1] = diag
    end

    return harnessutil.newCompilationResult(host, config:CompilerOptions(), postProgram, emitResult, errors, harnessOptions)
end

-- CompilationResult: { diagnostics, result (*compiler.EmitResult), program (compiler.ProgramLike),
-- options, harnessOptions, js, dts, maps (collections.OrderedMap unitName -> TestFile),
-- symlinks, repeat_ (func(TestConfiguration) *CompilationResult), outputs, inputs,
-- inputsAndOutputs (OrderedMap -> CompilationOutput), trace, host }
local CompilationResult = {}
CompilationResult.__index = CompilationResult
harnessutil.CompilationResult = CompilationResult

-- CompilationOutput: { inputs = []TestFile, js = TestFile, dts = TestFile, map = TestFile }

local function compareTestFilesLess(a, b)
    return a.unitName < b.unitName
end

local function sortedValues(m)
    local values = core.Collect(m:Values())
    table.sort(values, compareTestFilesLess)
    return values
end

function harnessutil.newCompilationResult(host, options, program, result, diags, harnessOptions)
    if program ~= nil then
        options = program:Options()
    end

    local c = setmetatable({
        diagnostics = diags,
        result = result,
        program = program,
        options = options,
        harnessOptions = harnessOptions,
        js = collections.NewOrderedMap(),
        dts = collections.NewOrderedMap(),
        maps = collections.NewOrderedMap(),
        symlinks = nil,
        repeat_ = nil,
        outputs = {},
        inputs = {},
        inputsAndOutputs = collections.NewOrderedMap(),
        trace = "",
        host = host,
    }, CompilationResult)

    local fs = host:FS()
    if getmetatable(fs) ~= harnessutil.OutputRecorderFS then
        fs = nil
    end
    if fs ~= nil and program ~= nil then
        -- Corsa, unlike Strada, can use multiple threads for emit. As a result, the order of outputs is non-deterministic.
        -- To make the order deterministic, we sort the outputs by the order of the inputs.
        local js, dts, maps = collections.NewOrderedMap(), collections.NewOrderedMap(), collections.NewOrderedMap()
        for _, document in ipairs(fs:Outputs()) do
            if tspath.HasJSFileExtension(document.unitName) or
                tspath.HasJSONFileExtension(document.unitName) then
                js:Set(document.unitName, document)
            elseif tspath.IsDeclarationFileName(document.unitName) then
                dts:Set(document.unitName, document)
            elseif tspath.FileExtensionIs(document.unitName, ".map") then
                maps:Set(document.unitName, document)
            end
        end

        -- using the order from the inputs, populate the outputs
        for _, sourceFile in ipairs(program:GetSourceFiles()) do
            local input = harnessutil.NewTestFile(sourceFile:FileName(), sourceFile:Text())
            c.inputs[#c.inputs + 1] = input
            if not tspath.IsDeclarationFileName(sourceFile:FileName()) then
                local extname = outputpaths.GetOutputExtension(sourceFile:FileName(), options.jsx)
                local outputs = {
                    inputs = { input },
                    js = js:GetOrZero(c:getOutputPath(sourceFile:FileName(), extname)),
                    dts = dts:GetOrZero(c:getOutputPath(sourceFile:FileName(), tspath.GetDeclarationEmitExtensionForPath(sourceFile:FileName()))),
                    map = maps:GetOrZero(c:getOutputPath(sourceFile:FileName(), extname .. ".map")),
                }
                c.inputsAndOutputs:Set(sourceFile:FileName(), outputs)
                if outputs.js ~= nil then
                    c.inputsAndOutputs:Set(outputs.js.unitName, outputs)
                    c.js:Set(outputs.js.unitName, outputs.js)
                    js:Delete(outputs.js.unitName)
                    c.outputs[#c.outputs + 1] = outputs.js
                end
                if outputs.dts ~= nil then
                    c.inputsAndOutputs:Set(outputs.dts.unitName, outputs)
                    c.dts:Set(outputs.dts.unitName, outputs.dts)
                    dts:Delete(outputs.dts.unitName)
                    c.outputs[#c.outputs + 1] = outputs.dts
                end
                if outputs.map ~= nil then
                    c.inputsAndOutputs:Set(outputs.map.unitName, outputs)
                    c.maps:Set(outputs.map.unitName, outputs.map)
                    maps:Delete(outputs.map.unitName)
                    c.outputs[#c.outputs + 1] = outputs.map
                end
            end
        end

        -- add any unhandled outputs, ordered by unit name
        for _, document in ipairs(sortedValues(js)) do
            c.js:Set(document.unitName, document)
        end
        for _, document in ipairs(sortedValues(dts)) do
            c.dts:Set(document.unitName, document)
        end
        for _, document in ipairs(sortedValues(maps)) do
            c.maps:Set(document.unitName, document)
        end
    end

    return c
end

function harnessutil.compareTestFiles(a, b)
    if a.unitName < b.unitName then
        return -1
    elseif a.unitName > b.unitName then
        return 1
    end
    return 0
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

function CompilationResult:getOutputPath(path, ext)
    path = tspath.ResolvePath(self.host:GetCurrentDirectory(), path)
    local outDir
    if ext == ".d.ts" or ext == ".d.mts" or ext == ".d.cts" or (hasSuffix(ext, ".ts") and string.find(ext, ".d.", 1, true) ~= nil) then
        outDir = self.options.declarationDir
        if outDir == "" then
            outDir = self.options.outDir
        end
    else
        outDir = self.options.outDir
    end
    if outDir ~= "" then
        local common = self.program:CommonSourceDirectory()
        if common ~= "" then
            path = tspath.GetRelativePathFromDirectory(common, path, {
                useCaseSensitiveFileNames = self.host:FS():UseCaseSensitiveFileNames(),
                currentDirectory = self.host:GetCurrentDirectory(),
            })
            path = tspath.CombinePaths(tspath.ResolvePath(self.host:GetCurrentDirectory(), self.options.outDir), path)
        end
    end
    if ext == tspath.GetDeclarationEmitExtensionForPath(path) then
        return outputpaths.ChangeToDeclarationExtension(path, self.program:Program())
    end
    return tspath.ChangeExtension(path, ext)
end

function CompilationResult:FS()
    return self.host:FS()
end

function CompilationResult:GetNumberOfJSFiles(includeJson)
    if includeJson then
        return self.js:Size()
    end
    local count = 0
    for file in self.js:Values() do
        if not tspath.FileExtensionIs(file.unitName, tspath.ExtensionJson) then
            count = count + 1
        end
    end
    return count
end

function CompilationResult:Inputs()
    return self.inputs
end

function CompilationResult:Outputs()
    return self.outputs
end

function CompilationResult:GetInputsAndOutputsForFile(path)
    return self.inputsAndOutputs:GetOrZero(tspath.ResolvePath(self.host:GetCurrentDirectory(), path))
end

function CompilationResult:GetInputsForFile(path)
    local outputs = self:GetInputsAndOutputsForFile(path)
    if outputs ~= nil then
        return outputs.inputs
    end
    return nil
end

function CompilationResult:GetOutput(path, kind --[["js" | "dts" | "map"]])
    local outputs = self:GetInputsAndOutputsForFile(path)
    if outputs ~= nil then
        if kind == "js" then
            return outputs.js
        elseif kind == "dts" then
            return outputs.dts
        elseif kind == "map" then
            return outputs.map
        end
    end
    return nil
end

function CompilationResult:GetSourceMapRecord()
    if self.result == nil or core.Len(self.result.sourceMaps) == 0 then
        return ""
    end

    local sourceMapRecorder = harnessutil.newWriterAggregator()
    for _, sourceMapData in ipairs(self.result.sourceMaps) do
        local prevSourceFile = nil
        local currentFile

        if tspath.IsDeclarationFileName(sourceMapData.generatedFile) then
            currentFile = self.dts:GetOrZero(sourceMapData.generatedFile)
        else
            currentFile = self.js:GetOrZero(sourceMapData.generatedFile)
        end

        local sourceMapSpanWriter = harnessutil.newSourceMapSpanWriter(sourceMapRecorder, sourceMapData.sourceMap, currentFile)
        local mapper = sourcemap.DecodeMappings(sourceMapData.sourceMap.mappings)
        for decodedSourceMapping in mapper:Values() do
            local currentSourceFile = nil
            if decodedSourceMapping:IsSourceMapping() then
                currentSourceFile = self.program:GetSourceFile(sourceMapData.inputSourceFileNames[decodedSourceMapping.sourceIndex + 1])
            end
            if currentSourceFile ~= prevSourceFile then
                if currentSourceFile ~= nil then
                    sourceMapSpanWriter:recordNewSourceFileSpan(decodedSourceMapping, currentSourceFile:Text())
                end
                prevSourceFile = currentSourceFile
            else
                sourceMapSpanWriter:recordSourceMapSpan(decodedSourceMapping)
            end
        end
        sourceMapSpanWriter:close()
    end
    return sourceMapRecorder:String()
end

-- testBuildInfoReader wraps an incremental.BuildInfoReader (incremental is out of scope).
function harnessutil.getTestBuildInfoReader(host)
    error("not implemented: getTestBuildInfoReader (incremental is out of scope)", 0)
end

function harnessutil.createProgram(host, config)
    local singleThreaded = Tristate.TSUnknown
    if testutil.TestProgramIsSingleThreaded() then
        singleThreaded = Tristate.TSTrue
    end

    local programOptions = compiler.NewProgramOptions({
        config = config,
        host = host,
        singleThreaded = singleThreaded,
    })
    local program = compiler.NewProgram(programOptions)
    if core.Tristate_IsTrue(config:CompilerOptions().incremental) then
        error("not implemented: incremental.NewProgram (incremental is out of scope)", 0)
    end
    return program
end

function harnessutil.EnumerateFiles(folder, testRegex, recursive)
    local files, err = harnessutil.listFiles(folder, testRegex, recursive)
    if err ~= nil then
        return nil, err
    end
    return core.Map(files, tspath.NormalizeSlashes), nil
end

function harnessutil.listFiles(path, spec, recursive)
    return harnessutil.listFilesWorker(spec, recursive, path)
end

-- spec is a regexp stand-in: an object with MatchString(s) (or nil).
function harnessutil.listFilesWorker(spec, recursive, folder)
    folder = tspath.GetNormalizedAbsolutePath(folder, repo.TestDataPath())
    local entries, err = osvfs.osReadDir(folder)
    if err ~= nil then
        return nil, err
    end
    local paths = {}
    for _, entry in ipairs(entries) do
        local path = tspath.NormalizePath(folder .. "/" .. entry:Name())
        if not entry:IsDir() then
            if spec == nil or spec:MatchString(path) then
                paths[#paths + 1] = path
            end
        elseif recursive then
            local subPaths, err2 = harnessutil.listFilesWorker(spec, recursive, path)
            if err2 ~= nil then
                return nil, err2
            end
            appendAll(paths, subPaths)
        end
    end
    return paths, nil
end

function harnessutil.getFileBasedTestConfigurationDescription(config)
    local output = {}
    local keys = sortedKeys(config)
    for i, key in ipairs(keys) do
        if i > 1 then
            output[#output + 1] = ","
        end
        output[#output + 1] = key .. "=" .. string.lower(config[key])
    end
    return table.concat(output)
end

function harnessutil.GetFileBasedTestConfigurations(t, settings, varyByOptions)
    local optionEntries = {} -- Each element array has the option name as the first element, and the values as the rest
    local variationCount = 1
    local nonVaryingOptions = {}
    -- (sorted iteration; Go iterates the map in random order)
    for _, option in ipairs(sortedKeys(settings)) do
        local value = settings[option]
        if varyByOptions[option] then
            local entries = harnessutil.splitOptionValues(t, value, option)
            if core.Len(entries) > 1 then
                variationCount = variationCount * #entries
                if variationCount > 25 then
                    t:Fatal("Provided test options exceeded the maximum number of variations")
                end
                local entry = { option }
                appendAll(entry, entries)
                optionEntries[#optionEntries + 1] = entry
            elseif core.Len(entries) == 1 then
                nonVaryingOptions[option] = entries[1]
            end
        else
            -- Variation is not supported for the option
            nonVaryingOptions[option] = value
        end
    end

    local configurations = {}
    if #optionEntries > 0 then
        -- Merge varying and non-varying options
        local varyingConfigurations = harnessutil.computeFileBasedTestConfigurationVariations(variationCount, optionEntries)
        for _, varyingConfig in ipairs(varyingConfigurations) do
            local description = harnessutil.getFileBasedTestConfigurationDescription(varyingConfig)
            for k, v in pairs(nonVaryingOptions) do
                varyingConfig[k] = v
            end
            configurations[#configurations + 1] = { name = description, config = varyingConfig }
        end
    elseif next(nonVaryingOptions) ~= nil then
        -- Only non-varying options
        configurations[#configurations + 1] = { name = "", config = nonVaryingOptions }
    end
    return configurations
end

-- Splits a string value into an array of strings, each corresponding to a unique value for the given option.
-- Also handles the `*` value, which includes all possible values for the option, and exclusions using `-` or `!`.
-- ```
--
--	splitOptionValues("esnext, es2015, es6", "target") => ["esnext", "es2015"]
--	splitOptionValues("*", "strict") => ["true", "false"]
--	splitOptionValues("*, -true", "strict") => ["false"]
--
-- ```
-- (The result keeps first-seen order; Go returns the map values in random order.)
function harnessutil.splitOptionValues(t, value, option)
    if #value == 0 then
        return nil
    end

    local star = false
    local includes = {}
    local excludes = {}
    for s in string.gmatch(value .. ",", "([^,]*),") do
        s = string.match(s, "^%s*(.-)%s*$")
        if #s == 0 then
            goto continue
        end
        if s == "*" then
            star = true
        elseif string.sub(s, 1, 1) == "-" or string.sub(s, 1, 1) == "!" then
            excludes[#excludes + 1] = string.sub(s, 2)
        else
            includes[#includes + 1] = s
        end
        ::continue::
    end

    if #includes == 0 and not star and #excludes == 0 then
        return nil
    end

    -- Dedupe the variations by their normalized values
    local variations = {}
    local order = {}

    local function add(v, include)
        if variations[v] == nil then
            variations[v] = include
            order[#order + 1] = v
        end
    end

    -- add (and deduplicate) all included entries
    for _, include in ipairs(includes) do
        add(harnessutil.getValueOfOptionString(t, option, include), include)
    end

    local allValues = harnessutil.getAllValuesForOption(option)
    if star and core.Len(allValues) > 0 then
        -- add all entries
        for _, include in ipairs(allValues) do
            add(harnessutil.getValueOfOptionString(t, option, include), include)
        end
    end

    -- remove all excluded entries
    for _, exclude in ipairs(excludes) do
        local v, ok = harnessutil.tryGetValueOfOptionString(option, exclude)
        if ok then
            variations[v] = nil
        end
        -- The excluded value is not recognized (e.g., a removed option like "es3").
        -- Just skip it since there's nothing to remove.
    end

    local result = {}
    for _, v in ipairs(order) do
        if variations[v] ~= nil then
            result[#result + 1] = variations[v]
        end
    end
    if #result == 0 then
        error(string.format("Variations in test option '@%s' resulted in an empty set.", option), 0)
    end
    return result
end

function harnessutil.getValueOfOptionString(t, option, value)
    local result, ok = harnessutil.tryGetValueOfOptionString(option, value)
    if not ok then
        t:Fatalf("Unknown value '%s' for option '%s'", value, option)
    end
    return result
end

function harnessutil.tryGetValueOfOptionString(option, value)
    local optionDecl = harnessutil.getCommandLineOption(option)
    if optionDecl == nil then
        return nil, false
    end
    if optionDecl.kind == CommandLineOptionKind.CommandLineOptionTypeEnum then
        local enumVal, ok = optionDecl:EnumMap():Get(string.lower(value))
        if not ok then
            return nil, false
        end
        return enumVal, true
    elseif optionDecl.kind == CommandLineOptionKind.CommandLineOptionTypeBoolean then
        local lower = string.lower(value)
        if lower == "true" then
            return true, true
        elseif lower == "false" then
            return false, true
        end
        return nil, false
    end
    return value, true
end

function harnessutil.getCommandLineOption(option)
    return core.Find(harnessutil.compilerOptions(), function(optionDecl)
        return strEqualFold(optionDecl.name, option)
    end)
end

function harnessutil.getAllValuesForOption(option)
    local optionDecl = harnessutil.getCommandLineOption(option)
    if optionDecl == nil then
        return nil
    end
    if optionDecl.kind == CommandLineOptionKind.CommandLineOptionTypeEnum then
        return core.Collect(optionDecl:EnumMap():Keys())
    elseif optionDecl.kind == CommandLineOptionKind.CommandLineOptionTypeBoolean then
        return { "true", "false" }
    end
    return nil
end

function harnessutil.computeFileBasedTestConfigurationVariations(variationCount, optionEntries)
    local configurations = {}
    harnessutil.computeFileBasedTestConfigurationVariationsWorker(configurations, optionEntries, 0, {})
    return configurations
end

function harnessutil.computeFileBasedTestConfigurationVariationsWorker(configurations, optionEntries, index, variationState)
    if index >= #optionEntries then
        local clone = {}
        for k, v in pairs(variationState) do
            clone[k] = v
        end
        configurations[#configurations + 1] = clone
        return
    end

    local optionKey = optionEntries[index + 1][1]
    for i = 2, #optionEntries[index + 1] do
        local entry = optionEntries[index + 1][i]
        -- set or overwrite the variation, then compute the next variation
        variationState[optionKey] = entry
        harnessutil.computeFileBasedTestConfigurationVariationsWorker(configurations, optionEntries, index + 1, variationState)
    end
end

function harnessutil.GetConfigNameFromFileName(filename)
    local basenameLower = string.lower(tspath.GetBaseFileName(filename))
    if basenameLower == "tsconfig.json" or basenameLower == "jsconfig.json" then
        return basenameLower
    end
    return ""
end

function harnessutil.SkipUnsupportedCompilerOptions(t, options)
    t:Helper()
    local ModuleKind = core.ModuleKind
    local ModuleResolutionKind = core.ModuleResolutionKind
    if options.module == ModuleKind.AMD or options.module == ModuleKind.UMD or options.module == ModuleKind.System then
        t:Skipf("unsupported module kind %s", core.ModuleKind_String(options.module))
    end
    if options.moduleResolution == ModuleResolutionKind.Node10 or options.moduleResolution == ModuleResolutionKind.Classic then
        t:Skipf("unsupported module resolution kind %d", options.moduleResolution)
    end
    if core.Tristate_IsFalse(options.esModuleInterop) then
        t:Skipf("esModuleInterop=false is unsupported")
    end
    if core.Tristate_IsFalse(options.allowSyntheticDefaultImports) then
        t:Skipf("allowSyntheticDefaultImports=false is unsupported")
    end
    if options.baseUrl ~= "" then
        t:Skipf("unsupported baseUrl %s", options.baseUrl)
    end
    if options.outFile ~= "" then
        t:Skipf("unsupported outFile %s", options.outFile)
    end
    if options.target == core.ScriptTarget.ES5 then
        t:Skipf("unsupported target %s", core.ScriptTarget_String(options.target))
    end
    if core.Tristate_IsFalse(options.alwaysStrict) then
        t:Skipf("alwaysStrict=false is unsupported")
    end
end

return harnessutil
