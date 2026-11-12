local project = require("tslua.project")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local ata = require("tslua.project.ata")
local logging = require("tslua.project.logging")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Kind = project.Kind
local ProgramUpdateKind = project.ProgramUpdateKind
local Tristate = core.Tristate
local LogTree = logging.LogTree

project.inferredProjectName = "/dev/null/inferred" -- lowercase so toPath is a no-op regardless of settings
project.hr = "-----------------------------------------------"

-- Project represents a TypeScript project.
-- If changing struct fields, also update the Clone method.
--   kind, currentDirectory, configFileName, configFilePath, dirty, dirtyFilePath, host,
--   commandLine, commandLineWithTypingsFiles, commandLineWithTypingsFilesOnce, program,
--   programUpdateKind: the kind of update that was performed on the program last time it was updated.
--   programLastUpdate: the ID of the snapshot that created the program stored in this project.
--   potentialProjectReferences: set of projects that this project could be referencing.
--     Only set before actually loading config file to get actual project references
--   programFilesWatch, typingsWatch, contentMapperWatch, contentMapperWatchedFiles, checkerPool,
--   installedTypingsInfo: the value of `project.ComputeTypingsInfo()` that was
--     used during the most recently completed typings installation.
--   typingsFiles: the root files added by the typings installer.
local Project = {}
Project.__index = Project
project.Project = Project

function project.NewConfiguredProject(configFileName, configFilePath, builder, logger)
    return project.NewProject(configFileName, Kind.Configured, tspath.GetDirectoryPath(configFileName), builder, logger)
end

function project.NewInferredProject(currentDirectory, compilerOptions, rootFileNames, contentMappers, builder, logger)
    local p = project.NewProject(project.inferredProjectName, Kind.Inferred, currentDirectory, builder, logger)
    if compilerOptions == nil then
        compilerOptions = core.NewCompilerOptions({
            allowJs = Tristate.TSTrue,
            module = core.ModuleKind.ESNext,
            moduleResolution = core.ModuleResolutionKind.Bundler,
            target = core.ScriptTarget.LatestStandard,
            jsx = core.JsxEmit.ReactJSX,
            allowImportingTsExtensions = Tristate.TSTrue,
            strictNullChecks = Tristate.TSTrue,
            strictFunctionTypes = Tristate.TSTrue,
            sourceMap = Tristate.TSTrue,
            allowNonTsExtensions = Tristate.TSTrue,
            resolveJsonModule = Tristate.TSTrue,
        })
    end
    p.commandLine = project.newInferredProjectCommandLine(
        compilerOptions,
        rootFileNames,
        contentMappers,
        {
            useCaseSensitiveFileNames = builder.fs.fs:UseCaseSensitiveFileNames(),
            currentDirectory = currentDirectory,
        }
    )
    return p
end

function project.newInferredProjectCommandLine(compilerOptions, rootFileNames, contentMappers, comparePathsOptions)
    local commandLine = tsoptions.NewParsedCommandLine(compilerOptions, rootFileNames, comparePathsOptions)
    commandLine.parsedConfig.contentMappers = contentMappers
    return commandLine
end

local function newProjectStruct(fields)
    return setmetatable({
        kind = fields.kind,
        currentDirectory = fields.currentDirectory or "",
        configFileName = fields.configFileName or "",
        configFilePath = fields.configFilePath or "",

        dirty = fields.dirty or false,
        dirtyFilePath = fields.dirtyFilePath or "",

        host = fields.host,
        commandLine = fields.commandLine,
        commandLineWithTypingsFiles = fields.commandLineWithTypingsFiles,
        commandLineWithTypingsFilesOnce = false,
        program = fields.program,
        programUpdateKind = fields.programUpdateKind or ProgramUpdateKind.None,
        programLastUpdate = fields.programLastUpdate or 0,
        potentialProjectReferences = fields.potentialProjectReferences,

        programFilesWatch = fields.programFilesWatch,
        typingsWatch = fields.typingsWatch,
        contentMapperWatch = fields.contentMapperWatch,
        contentMapperWatchedFiles = fields.contentMapperWatchedFiles,

        checkerPool = fields.checkerPool,

        installedTypingsInfo = fields.installedTypingsInfo,
        typingsFiles = fields.typingsFiles,
    }, Project)
end

function project.NewProject(configFileName, kind, currentDirectory, builder, logger)
    if logger ~= nil then
        LogTree.Log(logger, "Creating " .. project.Kind_String(kind) .. "Project: " .. configFileName .. ", currentDirectory: " .. currentDirectory)
    end
    local p = newProjectStruct({
        configFileName = configFileName,
        kind = kind,
        currentDirectory = currentDirectory,
        dirty = true,
    })

    local hasRelativePatternSupport = project.hasRelativePatternSupport(builder.ctx)
    p.configFilePath = tspath.ToPath(configFileName, currentDirectory, builder.fs.fs:UseCaseSensitiveFileNames())
    p.programFilesWatch = project.NewWatchedFiles(
        "program files for " .. configFileName,
        lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete,
        hasRelativePatternSupport,
        project.createResolutionLookupGlobMapper(builder.sessionOptions.currentDirectory, builder.sessionOptions.defaultLibraryPath, p.currentDirectory, builder.fs.fs:UseCaseSensitiveFileNames())
    )
    if builder.sessionOptions.typingsLocation ~= "" then
        p.typingsWatch = project.NewWatchedFiles(
            "typings installer files",
            lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete,
            hasRelativePatternSupport,
            core.Identity
        )
    end
    p.contentMapperWatch = project.NewWatchedFilesForPaths(
        "content mapper configuration files for " .. configFileName,
        lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete,
        hasRelativePatternSupport,
        builder.sessionOptions.currentDirectory,
        builder.sessionOptions.currentDirectory,
        builder.fs.fs:UseCaseSensitiveFileNames()
    )
    return p
end

function Project:Name()
    return self.configFileName
end

-- DisplayName returns a short, human-readable name for the project,
-- relative to the given workspace root directory.
-- For configured projects, this is the config file path made relative.
-- For inferred projects, this is the last component of the current directory.
function Project:DisplayName(cwd)
    if self.kind == Kind.Inferred then
        return tspath.GetBaseFileName(self.currentDirectory)
    end
    return tspath.ConvertToRelativePath(self.configFileName, {
        currentDirectory = cwd,
        useCaseSensitiveFileNames = false,
    })
end

function Project:ID()
    return self.configFilePath
end

-- ConfigFileName panics if Kind() is not KindConfigured.
function Project:ConfigFileName()
    if self.kind ~= Kind.Configured then
        error("ConfigFileName called on non-configured project", 0)
    end
    return self.configFileName
end

-- ConfigFilePath panics if Kind() is not KindConfigured.
function Project:ConfigFilePath()
    if self.kind ~= Kind.Configured then
        error("ConfigFilePath called on non-configured project", 0)
    end
    return self.configFilePath
end

function Project:Id()
    return self.configFilePath
end

function Project:GetProgram()
    return self.program
end

-- GetProjectDiagnostics returns program diagnostics combined with any global
-- diagnostics discovered during checking. These are the diagnostics reported on
-- the tsconfig.json file.
function Project:GetProjectDiagnostics(ctx)
    local globalDiags = nil
    if self.checkerPool ~= nil then
        globalDiags = self.checkerPool:GetGlobalDiagnostics()
    end
    local all = {}
    for _, list in ipairs({
        self.program:GetConfigFileParsingDiagnostics() or {},
        self.program:GetProgramDiagnostics() or {},
        globalDiags or {},
    }) do
        for _, d in ipairs(list) do
            all[#all + 1] = d
        end
    end
    return compiler.SortAndDeduplicateDiagnostics(all)
end

function Project:HasFile(fileName)
    return self:containsFile(self:toPath(fileName))
end

function Project:containsFile(path)
    return self.program ~= nil and self.program:GetSourceFileByPath(path) ~= nil
end

function Project:IsSourceFromProjectReference(path)
    return self.program ~= nil and self.program:IsSourceFromProjectReference(path)
end

function Project:Clone()
    return newProjectStruct({
        kind = self.kind,
        currentDirectory = self.currentDirectory,
        configFileName = self.configFileName,
        configFilePath = self.configFilePath,

        dirty = self.dirty,
        dirtyFilePath = self.dirtyFilePath,

        host = self.host,
        commandLine = self.commandLine,
        commandLineWithTypingsFiles = self.commandLineWithTypingsFiles,
        program = self.program,
        programUpdateKind = ProgramUpdateKind.None,
        programLastUpdate = self.programLastUpdate,
        potentialProjectReferences = self.potentialProjectReferences,

        programFilesWatch = self.programFilesWatch,
        typingsWatch = self.typingsWatch,
        contentMapperWatch = self.contentMapperWatch,
        contentMapperWatchedFiles = self.contentMapperWatchedFiles,

        checkerPool = self.checkerPool,

        installedTypingsInfo = self.installedTypingsInfo,
        typingsFiles = self.typingsFiles,
    })
end

-- SetCommandLine reassigns the project's command line and resets all state derived
-- from it. Changing the command line always requires a full program rebuild, so the
-- project is marked fully dirty. It also resets:
--   - the memoized command line augmented with typings files (and its sync.Once, so
--     the augmented command line is rebuilt from the new command line on next access);
--   - potentialProjectReferences, the pre-load placeholder derived from the old
--     command line (always nil for inferred projects, which have no project references).
function Project:SetCommandLine(commandLine)
    self.commandLine = commandLine
    self.commandLineWithTypingsFiles = nil
    self.commandLineWithTypingsFilesOnce = false
    self.potentialProjectReferences = nil
    self.dirty = true
    self.dirtyFilePath = ""
end

-- getCommandLineWithTypingsFiles returns the command line augmented with typing files if ATA is enabled.
function Project:getCommandLineWithTypingsFiles()
    if core.Len(self.typingsFiles) == 0 then
        return self.commandLine
    end

    -- Check if ATA is enabled for this project
    local typeAcquisition = self:GetTypeAcquisition()
    if typeAcquisition == nil or not core.Tristate_IsTrue(typeAcquisition.enable) then
        return self.commandLine
    end

    if not self.commandLineWithTypingsFilesOnce then
        self.commandLineWithTypingsFilesOnce = true
        if self.commandLineWithTypingsFiles == nil then
            -- Create an augmented command line that includes typing files
            local originalRootNames = self.commandLine:FileNames()
            local newRootNames = {}
            for _, name in ipairs(originalRootNames or {}) do
                newRootNames[#newRootNames + 1] = name
            end
            for _, name in ipairs(self.typingsFiles) do
                newRootNames[#newRootNames + 1] = name
            end

            self.commandLineWithTypingsFiles = self.commandLine:WithFileNames(newRootNames)
        end
    end
    return self.commandLineWithTypingsFiles
end

function Project:setPotentialProjectReference(configFilePath)
    if self.potentialProjectReferences == nil then
        self.potentialProjectReferences = collections.NewSet()
    else
        self.potentialProjectReferences = self.potentialProjectReferences:Clone()
    end
    self.potentialProjectReferences:Add(configFilePath)
end

function Project:hasPotentialProjectReference(projectTreeRequest)
    if self.commandLine ~= nil then
        for _, path in ipairs(self.commandLine:ResolvedProjectReferencePaths() or {}) do
            if projectTreeRequest:IsProjectReferenced(self:toPath(path)) then
                return true
            end
        end
    elseif self.potentialProjectReferences ~= nil then
        for path in pairs(project.setKeys(self.potentialProjectReferences)) do
            if projectTreeRequest:IsProjectReferenced(path) then
                return true
            end
        end
    end
    return false
end

-- CreateProgramResult: { program, updateKind }
function Project:CreateProgram()
    local updateKind = ProgramUpdateKind.NewFiles
    local programCloned = false
    local newProgram = nil

    -- Define a fresh CreateCheckerPool closure for this call. Each invocation of
    -- CreateProgram must use its own closure so that concurrent goroutines cloning
    -- the same project never share a captured variable through a stale closure
    -- stored in the old program's options.
    local createCheckerPool = function(program)
        return project.newCheckerPool(self.host.sessionOptions.checkerPoolOptions, program, function(msg)
            self:log(msg)
        end)
    end

    -- Create the command line, potentially augmented with typing files
    local commandLine = self:getCommandLineWithTypingsFiles()
    if self.dirtyFilePath ~= "" and self.program ~= nil and self.program:CommandLine() == commandLine then
        local dirtyFile
        newProgram, dirtyFile, programCloned = self.program:UpdateProgram(self.dirtyFilePath, self.host, createCheckerPool)
        if programCloned then
            updateKind = ProgramUpdateKind.Cloned
            for _, file in ipairs(newProgram:SourceFiles()) do
                -- Use pointer identity: dirtyFile is the exact instance UpdateProgram acquired,
                -- and it is the only file whose refcount is already accounted for.
                if file ~= dirtyFile and not file:IsContentMapperFailureStub() and not file:IsContentMapperSupplemental() then
                    -- UpdateProgram acquired the changed file only, so we need to ref everything else
                    if file:ContentMapper() ~= "" then
                        self.host.builder.contentMappedParseCache:Ref(project.contentMappedParseCacheKeyForFile(file))
                    else
                        self.host.builder.parseCache:Ref(project.parseCacheKeyForFile(file))
                    end
                end
            end
            for _, file in ipairs(newProgram:DuplicateSourceFiles() or {}) do
                if not file.isContentMapperFailureStub then
                    if file.contentMapper ~= "" then
                        self.host.builder.contentMappedParseCache:Ref(project.contentMappedParseCacheKeyForDuplicate(file))
                    else
                        self.host.builder.parseCache:Ref(project.parseCacheKeyForDuplicate(file))
                    end
                end
            end
        elseif dirtyFile ~= nil then
            -- UpdateProgram always acquires the dirty file before deciding whether it can
            -- reuse the old program. If it falls back to a full rebuild, release that
            -- speculative acquire so the rebuilt program is the only remaining owner.
            if dirtyFile:ContentMapper() ~= "" then
                self.host.builder.contentMappedParseCache:Deref(project.contentMappedParseCacheKeyForFile(dirtyFile))
            else
                self.host.builder.parseCache:Deref(project.parseCacheKeyForFile(dirtyFile))
            end
        end
    else
        local typingsLocation = ""
        if core.Tristate_IsTrue(self:GetTypeAcquisition().enable) then
            typingsLocation = self.host.sessionOptions.typingsLocation
        end
        newProgram = compiler.NewProgram(
            compiler.NewProgramOptions({
                host = self.host,
                config = commandLine,
                useSourceOfProjectReference = true,
                typingsLocation = typingsLocation,
                createCheckerPool = createCheckerPool,
            })
        )
    end

    if not programCloned and self.program ~= nil and self.program:HasSameFileNames(newProgram) then
        updateKind = ProgramUpdateKind.SameFileNames
    end

    newProgram:BindSourceFiles()

    return {
        program = newProgram,
        updateKind = updateKind,
    }
end

function Project:CloneWatchers()
    return self.programFilesWatch:Clone(self.host.sourceFS.seenFiles)
end

function Project:log(msg)
    -- !!!
end

function Project:toPath(fileName)
    return tspath.ToPath(fileName, self.currentDirectory, self.host:FS():UseCaseSensitiveFileNames())
end

function Project:print(writeFileNames, writeFileExplanation, builder)
    builder:WriteString("\nProject '" .. self:Name() .. "'\n")
    if self.program == nil then
        builder:WriteString("\tFiles (0) NoProgram\n")
    else
        local sourceFiles = self.program:GetSourceFiles()
        builder:WriteString(string.format("\tFiles (%d)\n", #sourceFiles))
        if writeFileNames then
            for _, sourceFile in ipairs(sourceFiles) do
                builder:WriteString("\t\t")
                builder:WriteString(sourceFile:FileName())
                builder:WriteString("\n")
            end
            -- !!!
            -- if writeFileExplanation {}
        end
    end
    builder:WriteString(project.hr)
    return builder:String()
end

-- GetTypeAcquisition returns the type acquisition settings for this project.
function Project:GetTypeAcquisition()
    if self.kind == Kind.Inferred then
        -- For inferred projects, use default settings
        return core.NewTypeAcquisition({
            enable = Tristate.TSTrue,
            include = nil,
            exclude = nil,
            disableFilenameBasedTypeAcquisition = Tristate.TSFalse,
        })
    end

    if self.commandLine ~= nil then
        return self.commandLine:TypeAcquisition()
    end

    return nil
end

-- GetUnresolvedImports extracts unresolved imports from this project's program.
function Project:GetUnresolvedImports()
    if self.program == nil then
        return nil
    end

    return self.program:GetUnresolvedImports()
end

-- ShouldTriggerATA determines if ATA should be triggered for this project.
function Project:ShouldTriggerATA(snapshotID)
    if self.program == nil or self.commandLine == nil then
        return false
    end

    local typeAcquisition = self:GetTypeAcquisition()
    if typeAcquisition == nil or not core.Tristate_IsTrue(typeAcquisition.enable) then
        return false
    end

    if self.installedTypingsInfo == nil or self.programLastUpdate == snapshotID and self.programUpdateKind == ProgramUpdateKind.NewFiles then
        return true
    end

    return not self.installedTypingsInfo:Equals(self:ComputeTypingsInfo())
end

function Project:ComputeTypingsInfo()
    return ata.NewTypingsInfo({
        compilerOptions = self.commandLine:CompilerOptions(),
        typeAcquisition = self:GetTypeAcquisition(),
        unresolvedImports = self:GetUnresolvedImports(),
    })
end
