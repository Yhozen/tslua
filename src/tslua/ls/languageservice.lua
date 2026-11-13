local ls = require("tslua.ls")
local autoimport = require("tslua.ls.autoimport")
local lsproto = require("tslua.lsp.lsproto")
local sourcemap = require("tslua.sourcemap")
local tspath = require("tslua.tspath")
local vfsmatch = require("tslua.vfs.vfsmatch")

-- LanguageService: { projectPath, host, activeConfig (lsutil.UserPreferences), program,
--   converters, documentPositionMappers (map fileName -> *sourcemap.DocumentPositionMapper) }
-- The class table is created in init.lua (other files add methods to it).
local LanguageService = ls.LanguageService

function ls.NewLanguageService(projectPath, program, host, activeFile)
    return setmetatable({
        projectPath = projectPath,
        host = host,
        program = program,
        converters = host:Converters(),
        activeConfig = host:GetPreferences(activeFile),
        documentPositionMappers = {},
    }, LanguageService)
end

function LanguageService:toPath(fileName)
    return tspath.ToPath(fileName, self.program:GetCurrentDirectory(), self:UseCaseSensitiveFileNames())
end

function LanguageService:GetProgram()
    return self.program
end

function LanguageService:UserPreferences()
    return self.activeConfig
end

function LanguageService:FormatOptions()
    return self.activeConfig.formatCodeSettings
end

-- Returns (*compiler.Program, *ast.SourceFile).
function LanguageService:tryGetProgramAndFile(fileName)
    local program = self:GetProgram()
    local file = program:GetSourceFile(fileName)
    return program, file
end

function LanguageService:getProgramAndFile(documentURI)
    local fileName = lsproto.DocumentUri_FileName(documentURI)
    local program, file = self:tryGetProgramAndFile(fileName)
    if file == nil then
        error("file not found: " .. fileName, 0)
    end
    return program, file
end

function LanguageService:GetDocumentPositionMapper(fileName)
    local d = self.documentPositionMappers[fileName]
    if d == nil and self.documentPositionMappers[fileName] == nil then
        d = sourcemap.GetDocumentPositionMapper(self, fileName)
        -- Go stores nil results too; false marks a cached nil.
        self.documentPositionMappers[fileName] = d or false
    end
    return d or nil
end

-- Returns (string, bool).
function LanguageService:ReadFile(fileName)
    return self.host:ReadFile(fileName)
end

function LanguageService:UseCaseSensitiveFileNames()
    return self.host:UseCaseSensitiveFileNames()
end

function LanguageService:GetECMALineInfo(fileName)
    return self.host:GetECMALineInfo(fileName)
end

-- getPreparedAutoImportView returns an auto-import view for the given file if the registry is prepared
-- to provide up-to-date auto-imports for it. If not, it returns ErrNeedsAutoImports.
-- Returns (*autoimport.View, error).
function LanguageService:getPreparedAutoImportView(fromFile)
    local registry = self.host:AutoImportRegistry()
    local registryFile = fromFile
    local canonical = fromFile:CanonicalSourceFile()
    if canonical ~= nil then
        registryFile = canonical
    end
    -- Go: nil-receiver method; a nil registry is "not prepared".
    if not autoimport.Registry.IsPreparedForImportingFile(registry, registryFile:FileName(), self.projectPath, self:UserPreferences()) then
        return nil, ls.ErrNeedsAutoImports
    end

    local view = autoimport.NewView(registry, fromFile, self.projectPath, self.program, self:UserPreferences():ModuleSpecifierPreferences())
    return view, nil
end

-- getCurrentAutoImportView returns an auto-import view for the given file, based on the current state
-- of the auto-import registry, which may or may not be up-to-date.
function LanguageService:getCurrentAutoImportView(fromFile)
    return autoimport.NewView(
        self.host:AutoImportRegistry(),
        fromFile,
        self.projectPath,
        self.program,
        self:UserPreferences():ModuleSpecifierPreferences()
    )
end

-- Used for module specifier completions.
function LanguageService:DirectoryExists(path)
    return self.host:DirectoryExists(path)
end

-- Used for module specifier completions.
function LanguageService:ReadDirectory(path, extensions, includes)
    return self.host:ReadDirectory(self.program:GetCurrentDirectory(), path, extensions, nil --[[excludes]], includes, vfsmatch.UnlimitedDepth)
end

function LanguageService:GetDirectories(path)
    return self.host:GetDirectories(path)
end
