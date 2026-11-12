local build = require("tslua.execute.build")
local collections = require("tslua.collections")
local incremental = require("tslua.execute.incremental")
local tsc = require("tslua.execute.tsc")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

-- host implements compiler.CompilerHost, incremental.BuildInfoReader and incremental.Host.
--   orchestrator: *Orchestrator
--   host: compiler.CompilerHost
-- Caches that last only for build cycle and then cleared out:
--   extendedConfigCache: tsc.ExtendedConfigCache
--   sourceFiles: parseCache[ast.SourceFileParseOptions, *ast.SourceFile]
--   configTimes: SyncMap[tspath.Path, time.Duration]
-- caches that stay as long as they are needed:
--   resolvedReferences: parseCache[tspath.Path, *tsoptions.ParsedCommandLine]
--   mTimes: SyncMap[tspath.Path, time.Time]
local host = {}
host.__index = host
build.host = host

-- ast.SourceFileParseOptions is a comparable Go struct used as a map key.
function build.sourceFileParseOptionsKey(opts)
    local emi = opts.externalModuleIndicatorOptions
    return opts.fileName .. "\0" .. opts.path .. "\0" .. tostring(emi ~= nil and emi.jsx) .. "\0" .. tostring(emi ~= nil and emi.force)
end

function build.newHost(orchestrator, compilerHost, mTimes)
    return setmetatable({
        orchestrator = orchestrator,
        host = compilerHost,
        extendedConfigCache = tsc.NewExtendedConfigCache(),
        sourceFiles = build.newParseCache(build.sourceFileParseOptionsKey),
        configTimes = collections.NewSyncMap(),
        resolvedReferences = build.newParseCache(nil),
        mTimes = mTimes,
    }, host)
end

function host:FS()
    return self.host:FS()
end

function host:DefaultLibraryPath()
    return self.host:DefaultLibraryPath()
end

function host:GetCurrentDirectory()
    return self.host:GetCurrentDirectory()
end

function host:Trace(msg, ...)
    error("build.Orchestrator.host does not support tracing; use a different host for tracing", 0)
end

function host:GetSourceFile(opts)
    if tspath.IsDeclarationFileName(opts.fileName) or tspath.FileExtensionIs(opts.fileName, tspath.ExtensionJson) then
        -- Cache dts and json files as they will be reused
        return self.sourceFiles:loadOrStore(opts, function(o) return self.host:GetSourceFile(o) end, false --[[ allowZero ]])
    end
    return self.host:GetSourceFile(opts)
end

-- Returns (contentmapper.SourceFiles, err).
function host:GetContentMappedSourceFiles(parseOptions, mapper)
    local contentmapper = require("tslua.contentmapper")
    return { canonical = nil, supplemental = nil }, contentmapper.ErrProjectUnavailable
end

function host:ContentMapperProject()
    error("build.Orchestrator.host does not support content mapper project; use an individual project's compiler host instead", 0)
end

function host:GetResolvedProjectReference(fileName, path)
    return self.resolvedReferences:loadOrStore(path, function(p)
        local configStart = self.orchestrator.opts.sys:Now()
        -- Wrap command line options in "compilerOptions" key to match tsconfig.json structure
        local commandLineRaw = nil
        local raw = self.orchestrator.opts.command.raw
        if raw ~= nil and getmetatable(raw) == collections.OrderedMap then
            local wrapped = collections.NewOrderedMapWithSizeHint(1)
            wrapped:Set("compilerOptions", raw)
            commandLineRaw = wrapped
        end
        local commandLine = tsoptions.GetParsedCommandLineOfConfigFilePath(fileName, p, self.orchestrator.opts.command.compilerOptions, commandLineRaw, self, self.extendedConfigCache)
        local configTime = self.orchestrator.opts.sys:Now() - configStart
        self.configTimes:Store(p, configTime)
        return commandLine
    end, true --[[ allowZero ]])
end

function host:ReadBuildInfo(config)
    local configPath = self.orchestrator:toPath(config:ConfigName())
    local task = self.orchestrator:getTask(configPath)
    local buildInfo = task:loadOrStoreBuildInfo(self.orchestrator, self.orchestrator:toPath(config:ConfigName()), config:GetBuildInfoFileName())
    return buildInfo
end

function host:GetMTime(file)
    return self:loadOrStoreMTime(file, nil, true)
end

function host:SetMTime(file, mTime)
    return self:FS():Chtimes(file, 0, mTime)
end

function host:loadOrStoreMTime(file, oldCache, store)
    local path = self.orchestrator:toPath(file)
    local existing, loaded = self.mTimes:Load(path)
    if loaded then
        return existing
    end
    local found = false
    local mTime = 0
    if oldCache ~= nil then
        local v, ok = oldCache:Load(path)
        if ok then
            mTime, found = v, true
        end
    end
    if not found then
        mTime = incremental.GetMTime(self.host, file)
    end
    if store then
        mTime = self.mTimes:LoadOrStore(path, mTime)
    end
    return mTime
end

function host:storeMTime(file, mTime)
    local path = self.orchestrator:toPath(file)
    self.mTimes:Store(path, mTime)
end

function host:storeMTimeFromOldCache(file, oldCache)
    local path = self.orchestrator:toPath(file)
    local mTime, found = oldCache:Load(path)
    if found then
        self.mTimes:Store(path, mTime)
    end
end
