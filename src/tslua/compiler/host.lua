local compiler = require("tslua.compiler")
local core = require("tslua.core")
local parser = require("tslua.parser")
local tsoptions = require("tslua.tsoptions")

-- CompilerHost interface: FS(), DefaultLibraryPath(), GetCurrentDirectory(), Trace(msg, ...),
-- GetSourceFile(opts), GetContentMappedSourceFiles(parseOptions, mapper), ContentMapperProject(),
-- GetResolvedProjectReference(fileName, path).

local compilerHost = {}
compilerHost.__index = compilerHost
compiler.compilerHost = compilerHost

function compiler.NewCachedFSCompilerHost(currentDirectory, fs, defaultLibraryPath, extendedConfigCache, trace, contentMapperProject)
    -- cachedvfs only memoizes lookups; when it is unavailable the uncached FS behaves identically.
    local ok, cachedvfs = pcall(require, "tslua.vfs.cachedvfs")
    if ok and cachedvfs ~= nil and cachedvfs.From ~= nil then
        fs = cachedvfs.From(fs)
    end
    return compiler.NewCompilerHost(currentDirectory, fs, defaultLibraryPath, extendedConfigCache, trace, contentMapperProject)
end

function compiler.NewCompilerHost(currentDirectory, fs, defaultLibraryPath, extendedConfigCache, trace, contentMapperProject)
    if trace == nil then
        trace = function(msg, ...) end
    end
    return setmetatable({
        currentDirectory = currentDirectory or "",
        fs = fs,
        defaultLibraryPath = defaultLibraryPath or "",
        extendedConfigCache = extendedConfigCache,
        trace = trace,
        contentMapperProject = contentMapperProject,
    }, compilerHost)
end

function compilerHost:FS()
    return self.fs
end

function compilerHost:DefaultLibraryPath()
    return self.defaultLibraryPath
end

function compilerHost:GetCurrentDirectory()
    return self.currentDirectory
end

function compilerHost:Trace(msg, ...)
    self.trace(msg, ...)
end

function compilerHost:GetSourceFile(opts)
    local text, ok = self:FS():ReadFile(opts.fileName)
    if not ok then
        return nil
    end
    return parser.ParseSourceFile(opts, text, core.EnsureScriptKindFromFileName(opts.fileName))
end

function compilerHost:GetContentMappedSourceFiles(parseOptions, mapper)
    error("not implemented: compilerHost.GetContentMappedSourceFiles (content mappers)")
end

function compilerHost:ContentMapperProject()
    return self.contentMapperProject
end

function compilerHost:GetResolvedProjectReference(fileName, path)
    local commandLine = tsoptions.GetParsedCommandLineOfConfigFilePath(fileName, path, nil, nil, self, self.extendedConfigCache)
    return commandLine
end
