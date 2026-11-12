local project = require("tslua.project")
local contentmapper = require("tslua.contentmapper")
local locale = require("tslua.locale")
local xxh3 = require("tslua.xxh3")
local logging = require("tslua.project.logging")

local LogTree = logging.LogTree

-- compilerHost implements compiler.CompilerHost.
local compilerHost = {}
compilerHost.__index = compilerHost
project.compilerHost = compilerHost

function project.newCompilerHost(currentDirectory, p, builder, logger)
    return setmetatable({
        configFilePath = p.configFilePath,
        currentDirectory = currentDirectory,
        sessionOptions = builder.sessionOptions,

        sourceFS = project.newSourceFS(true, builder.fs, builder.toPath),
        configFileRegistry = nil,

        project = p,
        builder = builder,
        logger = logger,
        contentMapperProject = nil,
        contentMapperOnce = false,
    }, compilerHost)
end

-- freeze clears references to mutable state to make the compilerHost safe for use
-- after the snapshot has been finalized. See the usage in snapshot.go for more details.
function compilerHost:freeze(snapshotFS, configFileRegistry)
    if self.builder == nil then
        error("freeze can only be called once", 0)
    end
    self.sourceFS.source = snapshotFS
    self.sourceFS:DisableTracking()
    self.configFileRegistry = configFileRegistry
    self.builder = nil
    self.project = nil
    self.logger = nil
end

function compilerHost:ensureAlive()
    if self.builder == nil or self.project == nil then
        error("method must not be called after snapshot initialization", 0)
    end
end

-- DefaultLibraryPath implements compiler.CompilerHost.
function compilerHost:DefaultLibraryPath()
    return self.sessionOptions.defaultLibraryPath
end

-- FS implements compiler.CompilerHost.
function compilerHost:FS()
    return self.sourceFS
end

-- GetCurrentDirectory implements compiler.CompilerHost.
function compilerHost:GetCurrentDirectory()
    return self.currentDirectory
end

-- GetResolvedProjectReference implements compiler.CompilerHost.
function compilerHost:GetResolvedProjectReference(fileName, path)
    if self.builder == nil then
        return self.configFileRegistry:GetConfig(path)
    else
        -- acquireConfigForProject will bypass sourceFS, so track the file here.
        self.sourceFS:Track(fileName)
        return self.builder.configFileRegistryBuilder:acquireConfigForProject(fileName, path, self.project, self.logger)
    end
end

-- GetSourceFile implements compiler.CompilerHost. Files are cached in parseCache
-- and acquired immediately for the in-progress program.
function compilerHost:GetSourceFile(opts)
    self:ensureAlive()
    local fh = self.sourceFS:GetFileByPath(opts.fileName, opts.path)
    if fh ~= nil then
        local key = project.NewParseCacheKey(opts, fh:Hash(), fh:Kind())
        return self.builder.parseCache:Acquire(key, fh)
    end
    return nil
end

-- GetContentMappedSourceFiles implements compiler.CompilerHost. Returns (SourceFiles, error).
function compilerHost:GetContentMappedSourceFiles(parseOptions, mapper)
    self:ensureAlive()
    local fh = self.sourceFS:GetFileByPath(parseOptions.fileName, parseOptions.path)
    if fh == nil then
        return { canonical = nil, supplemental = nil }, nil
    end
    local diagnosticLocale = locale.Default
    if self.builder.client ~= nil then
        diagnosticLocale = self.builder.client:GetLocale()
    end
    self:ensureContentMapperProject()
    if self.contentMapperProject == nil then
        return { canonical = nil, supplemental = nil }, contentmapper.ErrProjectUnavailable
    end
    local identity, err = self.contentMapperProject:Identity(mapper)
    if err ~= nil then
        return { canonical = nil, supplemental = nil }, contentmapper.NewTransformError(contentmapper.TransformErrorKind.Project, err)
    end
    local transformIdentity = xxh3.Hash128(identity):Hex()
    local key = project.contentMappedParseCacheKey(parseOptions, fh:Hash(), transformIdentity, diagnosticLocale)
    local files
    files, err = self.builder.contentMappedParseCache:AcquireOrError(key, function()
        local mapped, transformErr = contentmapper.TransformAndParse(parseOptions, fh:Content(), mapper, self.contentMapperProject)
        if transformErr ~= nil then
            return { canonical = nil, supplemental = nil }, transformErr
        end
        mapped.canonical.hash = key.hash
        for _, supplemental in ipairs(mapped.supplemental or {}) do
            supplemental.hash = key.hash
        end
        return mapped, nil
    end)
    if err == nil then
        err = contentmapper.CheckSupplementalFileNameCollisions(files, function(p)
            return self:FS():FileExists(p)
        end)
        if err ~= nil then
            self.builder.contentMappedParseCache:Deref(key)
            return { canonical = nil, supplemental = nil }, err
        end
    end
    return files, err
end

function compilerHost:ensureContentMapperProject()
    if self.contentMapperOnce then
        return
    end
    self.contentMapperOnce = true
    if self.builder.contentMapperHost == nil then
        return
    end
    local commandLine = self.project:getCommandLineWithTypingsFiles()
    self.contentMapperProject = self.builder.contentMapperHost:Project({
        configFileName = commandLine:ConfigName(),
        mappers = commandLine:ContentMappers(),
        compilerOptions = commandLine:CompilerOptions(),
    })
end

function compilerHost:ContentMapperProject()
    return self.contentMapperProject
end

-- Trace implements compiler.CompilerHost.
function compilerHost:Trace(msg, ...)
    LogTree.Log(self.logger, msg:Localize(locale.Default, ...))
end
