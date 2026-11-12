local projecttestutil = require("tslua.testutil.projecttestutil")
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local glob = require("tslua.glob")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local logging = require("tslua.project.logging")
local tspath = require("tslua.tspath")
local osvfs = require("tslua.vfs.osvfs")
local vfstest = require("tslua.vfs.vfstest")

-- TypingsInstallerOptions: { typesRegistry []string, packageToFile map[string]string }

-- SessionUtils: { currentDirectory, fsFromFileMap, fs, client, npmExecutor, tiOptions, logger }
local SessionUtils = {}
SessionUtils.__index = SessionUtils
projecttestutil.SessionUtils = SessionUtils

function SessionUtils:FsFromFileMap()
    return self.fsFromFileMap
end

function SessionUtils:Client()
    return self.client
end

function SessionUtils:NpmExecutor()
    return self.npmExecutor
end

local function goErrorf(format, ...)
    return project.errorf(format, ...)
end

function SessionUtils:SetupNpmExecutorForTypingsInstaller()
    if self.tiOptions == nil then
        return
    end

    self.npmExecutor.npmInstallFunc = function(cwd, packageNames)
        -- packageNames is actually npmInstallArgs due to interface misnaming
        local npmInstallArgs = packageNames
        local lenNpmInstallArgs = #npmInstallArgs
        if lenNpmInstallArgs < 3 then
            return nil, goErrorf("unexpected npm install: %s %v", cwd, npmInstallArgs)
        end

        if lenNpmInstallArgs == 3 and npmInstallArgs[3] == "types-registry@latest" then
            -- Write typings file
            local err = self.fs:WriteFile(cwd .. "/node_modules/types-registry/index.json", self:createTypesRegistryFileContent())
            return nil, err
        end

        -- Find the packages: they start at index 2 and continue until we hit a flag starting with --
        local packageEnd = lenNpmInstallArgs
        for i = 2, lenNpmInstallArgs - 1 do
            if project.hasPrefix(npmInstallArgs[i + 1], "--") then
                packageEnd = i
                break
            end
        end

        for i = 2, packageEnd - 1 do
            local atTypesPackageTs = npmInstallArgs[i + 1]
            -- @types/packageName@TsVersionToUse
            local atTypesPackage = atTypesPackageTs
            -- Remove version suffix
            local versionIndex = -1
            for j = #atTypesPackage, 1, -1 do
                if string.sub(atTypesPackage, j, j) == "@" then
                    versionIndex = j - 1
                    break
                end
            end
            if versionIndex > 6 then -- "@types/".length is 7, so version @ must be after
                atTypesPackage = string.sub(atTypesPackage, 1, versionIndex)
            end
            -- Extract package name from @types/packageName
            local packageBaseName = string.sub(atTypesPackage, 8) -- Remove "@types/" prefix
            local content = self.tiOptions.packageToFile ~= nil and self.tiOptions.packageToFile[packageBaseName] or nil
            if content == nil then
                return nil, goErrorf("content not provided for %s", packageBaseName)
            end
            local err = self.fs:WriteFile(cwd .. "/node_modules/@types/" .. packageBaseName .. "/index.d.ts", content)
            if err ~= nil then
                return nil, err
            end
        end
        return nil, nil
    end
end

function SessionUtils:ToPath(fileName)
    return tspath.ToPath(fileName, self.currentDirectory, self.fs:UseCaseSensitiveFileNames())
end

function SessionUtils:FS()
    return self.fs
end

-- WatchesFile reports whether any registered file watcher would match the given
-- file path. It handles both absolute glob patterns and relative patterns with
-- a base URI. On case-insensitive file systems the paths in glob patterns are
-- lowercased, so callers should pass the lowercased path.
function SessionUtils:WatchesFile(filePath)
    for _, call in ipairs(self.client:WatchFilesCalls()) do
        for _, watcher in ipairs(call.watchers or {}) do
            if watcher.globPattern.pattern ~= nil then
                local g, err = glob.Parse(watcher.globPattern.pattern)
                if err == nil and g:Match(filePath) then
                    return true
                end
            elseif watcher.globPattern.relativePattern ~= nil then
                local rp = watcher.globPattern.relativePattern
                local baseUri = rp.baseUri.uri
                -- Convert base URI (e.g. "file:///home/projects") to a directory path
                -- with trailing separator for proper prefix matching on path boundaries.
                local baseDir = lsproto.DocumentUri_FileName(baseUri)
                baseDir = tspath.EnsureTrailingDirectorySeparator(baseDir)
                if project.hasPrefix(filePath, baseDir) then
                    local relativePath = string.sub(filePath, #baseDir + 1)
                    local g, err = glob.Parse(rp.pattern)
                    if err == nil and g:Match(relativePath) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function SessionUtils:Logs()
    return self.logger:String()
end

function SessionUtils:BaselineLogs(t)
    local baseline = require("tslua.testutil.baseline")
    baseline.Run(t, t:Name() .. ".log", self:Logs(), {
        subfolder = "project",
    })
end

projecttestutil.typesRegistryConfigText = nil

function projecttestutil.TypesRegistryConfigText()
    if projecttestutil.typesRegistryConfigText == nil then
        local result = core.NewStringBuilder()
        local config = projecttestutil.TypesRegistryConfig()
        for _, key in ipairs(project.sortedKeys(config)) do
            local value = config[key]
            if result:Len() ~= 0 then
                result:WriteString(",")
            end
            result:WriteString(string.format("\n      \"%s\": \"%s\"", key, value))
        end
        projecttestutil.typesRegistryConfigText = result:String()
    end
    return projecttestutil.typesRegistryConfigText
end

projecttestutil.typesRegistryConfig = nil

function projecttestutil.TypesRegistryConfig()
    if projecttestutil.typesRegistryConfig == nil then
        projecttestutil.typesRegistryConfig = {
            ["latest"] = "1.3.0",
            ["ts2.0"] = "1.0.0",
            ["ts2.1"] = "1.0.0",
            ["ts2.2"] = "1.2.0",
            ["ts2.3"] = "1.3.0",
            ["ts2.4"] = "1.3.0",
            ["ts2.5"] = "1.3.0",
            ["ts2.6"] = "1.3.0",
            ["ts2.7"] = "1.3.0",
        }
    end
    return projecttestutil.typesRegistryConfig
end

function SessionUtils:createTypesRegistryFileContent()
    local builder = core.NewStringBuilder()
    builder:WriteString("{\n  \"entries\": {")
    local typesRegistry = self.tiOptions.typesRegistry or {}
    for index1, entry in ipairs(typesRegistry) do
        self:appendTypesRegistryConfig(builder, index1 - 1, entry)
    end
    local index = #typesRegistry
    local inRegistry = {}
    for _, entry in ipairs(typesRegistry) do
        inRegistry[entry] = true
    end
    for _, key in ipairs(project.sortedKeys(self.tiOptions.packageToFile)) do
        if not inRegistry[key] then
            self:appendTypesRegistryConfig(builder, index, key)
            index = index + 1
        end
    end
    builder:WriteString("\n  }\n}")
    return builder:String()
end

function SessionUtils:appendTypesRegistryConfig(builder, index, entry)
    if index > 0 then
        builder:WriteString(",")
    end
    builder:WriteString(string.format("\n    \"%s\": {%s\n    }", entry, projecttestutil.TypesRegistryConfigText()))
end

-- Setup returns (session, sessionUtils).
function projecttestutil.Setup(files)
    return projecttestutil.SetupWithTypingsInstaller(files, {})
end

function projecttestutil.SetupWithRealFS()
    local fs = bundled.WrapFS(osvfs.FS())
    local clientMock = projecttestutil.NewClientMock()
    local npmExecutorMock = projecttestutil.NewNpmExecutorMock()
    local wd = osvfs.Getwd()

    local sessionUtils = setmetatable({
        currentDirectory = wd,
        fs = fs,
        client = clientMock,
        npmExecutor = npmExecutorMock,
        logger = logging.NewTestLogger(),
    }, SessionUtils)

    return project.NewSession({
        backgroundCtx = nil,
        fs = fs,
        client = clientMock,
        npmExecutor = npmExecutorMock,
        logger = sessionUtils.logger,
        options = project.NewSessionOptions({
            currentDirectory = wd,
            defaultLibraryPath = bundled.LibPath(),
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = true,
            loggingEnabled = true,
            pushDiagnosticsEnabled = true,
        }),
    }), sessionUtils
end

function projecttestutil.SetupWithOptions(files, options)
    return projecttestutil.SetupWithOptionsAndTypingsInstaller(files, options, {})
end

function projecttestutil.SetupWithTypingsInstaller(files, tiOptions)
    return projecttestutil.SetupWithOptionsAndTypingsInstaller(files, nil, tiOptions)
end

function projecttestutil.SetupWithOptionsAndTypingsInstaller(files, options, tiOptions)
    local init, sessionUtils = projecttestutil.GetSessionInitOptions(files, options, tiOptions)
    local session = project.NewSession(init)

    return session, sessionUtils
end

function projecttestutil.WithRequestID(ctx)
    return core.WithRequestID(ctx, "0")
end

-- GetSessionInitOptions returns (SessionInit, SessionUtils).
function projecttestutil.GetSessionInitOptions(files, options, tiOptions)
    local fsFromFileMap = vfstest.FromMap(files, false)
    local fs = bundled.WrapFS(fsFromFileMap)
    local clientMock = projecttestutil.NewClientMock()
    local npmExecutorMock = projecttestutil.NewNpmExecutorMock()
    local sessionUtils = setmetatable({
        currentDirectory = "/",
        fsFromFileMap = fsFromFileMap,
        fs = fs,
        client = clientMock,
        npmExecutor = npmExecutorMock,
        tiOptions = tiOptions,
        logger = logging.NewTestLogger(),
    }, SessionUtils)

    -- Configure the npm executor mock to handle typings installation
    sessionUtils:SetupNpmExecutorForTypingsInstaller()

    -- Use provided options or create default ones
    if options == nil then
        options = project.NewSessionOptions({
            currentDirectory = "/",
            defaultLibraryPath = bundled.LibPath(),
            typingsLocation = projecttestutil.TestTypingsLocation,
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = true,
            loggingEnabled = true,
            pushDiagnosticsEnabled = true,
        })
    end

    return {
        backgroundCtx = nil,
        options = options,
        fs = fs,
        client = clientMock,
        npmExecutor = npmExecutorMock,
        logger = sessionUtils.logger,
    }, sessionUtils
end
