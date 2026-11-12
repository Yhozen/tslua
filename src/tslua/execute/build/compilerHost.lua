local build = require("tslua.execute.build")

-- compilerHost implements compiler.CompilerHost for one project of the build.
--   host: *host
--   trace: func(msg *diagnostics.Message, args ...any)
--   contentMapperProject: contentmapper.Project
local compilerHost = {}
compilerHost.__index = compilerHost
build.compilerHost = compilerHost

function build.newCompilerHost(h, trace, contentMapperProject)
    return setmetatable({ host = h, trace = trace, contentMapperProject = contentMapperProject }, compilerHost)
end

function compilerHost:FS()
    return self.host:FS()
end

function compilerHost:DefaultLibraryPath()
    return self.host:DefaultLibraryPath()
end

function compilerHost:GetCurrentDirectory()
    return self.host:GetCurrentDirectory()
end

function compilerHost:Trace(msg, ...)
    self.trace(msg, ...)
end

function compilerHost:GetSourceFile(opts)
    return self.host:GetSourceFile(opts)
end

-- Returns (contentmapper.SourceFiles, err).
function compilerHost:GetContentMappedSourceFiles(parseOptions, mapper)
    local contentmapper = require("tslua.contentmapper")
    if self.contentMapperProject == nil then
        return { canonical = nil, supplemental = nil }, contentmapper.ErrProjectUnavailable
    end
    local content, ok = self:FS():ReadFile(parseOptions.fileName)
    if not ok then
        return { canonical = nil, supplemental = nil }, nil
    end
    local files, err = contentmapper.TransformAndParse(parseOptions, content, mapper, self.contentMapperProject)
    if err == nil then
        err = contentmapper.CheckSupplementalFileNameCollisions(files, function(f) return self:FS():FileExists(f) end)
    end
    return files, err
end

function compilerHost:ContentMapperProject()
    return self.contentMapperProject
end

function compilerHost:GetResolvedProjectReference(fileName, path)
    return self.host:GetResolvedProjectReference(fileName, path)
end
