local compiler = require("tslua.compiler")
local core = require("tslua.core")

local projectReferenceParseTask = {}
projectReferenceParseTask.__index = projectReferenceParseTask
compiler.projectReferenceParseTask = projectReferenceParseTask

function projectReferenceParseTask:parse(projectReferenceParser)
    local loader = projectReferenceParser.loader
    self.resolved = loader.opts.host:GetResolvedProjectReference(self.configName, loader:toPath(self.configName))
    if self.resolved == nil then
        return
    end
    self.resolved:ParseInputOutputNames()
    local subReferences = self.resolved:ResolvedProjectReferencePaths()
    if core.Len(subReferences) > 0 then
        self.subTasks = compiler.createProjectReferenceParseTasks(subReferences)
    end
end

function compiler.createProjectReferenceParseTasks(projectReferences)
    return core.Map(projectReferences, function(configName)
        return setmetatable({
            configName = configName,
            resolved = nil,
            subTasks = nil,
        }, projectReferenceParseTask)
    end)
end

local projectReferenceParser = {}
projectReferenceParser.__index = projectReferenceParser
compiler.projectReferenceParser = projectReferenceParser

function compiler.newProjectReferenceParser(loader, wg)
    return setmetatable({
        loader = loader,
        wg = wg,
        tasksByFileName = {},
        tasksByFileNameSize = 0,
    }, projectReferenceParser)
end

function projectReferenceParser:parse(tasks)
    self.loader.projectReferenceFileMapper.loader = self.loader
    self:start(tasks)
    self.wg:RunAndWait()
    self:initMapper(tasks)
end

function projectReferenceParser:start(tasks)
    for i1, task in ipairs(tasks or {}) do
        local path = self.loader:toPath(task.configName)
        local loadedTask = self.tasksByFileName[path]
        if loadedTask ~= nil then
            -- dedup tasks to ensure correct file order, regardless of which task would be started first
            tasks[i1] = loadedTask
        else
            self.tasksByFileName[path] = task
            self.tasksByFileNameSize = self.tasksByFileNameSize + 1
            self.wg:Queue(function()
                task:parse(self)
                self:start(task.subTasks)
            end)
        end
    end
end

function projectReferenceParser:initMapper(tasks)
    local mapper = self.loader.projectReferenceFileMapper
    mapper.configToProjectReference = {}
    mapper.configToProjectReferencePresent = {}
    mapper.referencesInConfigFile = {}
    mapper.sourceToProjectReference = {}
    mapper.outputDtsToProjectReference = {}
    mapper.referencesInConfigFile[self.loader.opts.config.configFile.sourceFile:Path()] = self:initMapperWorker(tasks, {})
    if mapper.opts:canUseProjectReferenceSource() and next(mapper.outputDtsToProjectReference) ~= nil then
        mapper.host = compiler.newProjectReferenceDtsFakingHost(self.loader)
    end
end

function projectReferenceParser:initMapperWorker(tasks, seen)
    if core.Len(tasks) == 0 then
        return nil
    end
    local mapper = self.loader.projectReferenceFileMapper
    local results = {}
    for _, task in ipairs(tasks) do
        local path = self.loader:toPath(task.configName)
        results[#results + 1] = path
        -- ensure we only walk each task once
        if seen[task] then
            goto continue
        end
        seen[task] = true
        mapper.configToProjectReference[path] = task.resolved
        mapper.configToProjectReferencePresent[path] = true
        if task.resolved ~= nil and mapper.opts.config.configFile ~= task.resolved.configFile then
            -- Map current task's files first, before recursing into subtasks.
            -- This matches TypeScript's behavior where child project references
            -- overwrite parent entries when a file belongs to multiple projects.
            for k, v in pairs(task.resolved:SourceToProjectReference() or {}) do
                mapper.sourceToProjectReference[k] = v
            end
            for k, v in pairs(task.resolved:OutputDtsToProjectReference() or {}) do
                mapper.outputDtsToProjectReference[k] = v
            end
            if mapper.opts:canUseProjectReferenceSource() then
                local declDir = task.resolved:CompilerOptions().declarationDir
                if declDir == "" then
                    declDir = task.resolved:CompilerOptions().outDir
                end
                if declDir ~= "" then
                    self.loader.dtsDirectories[self.loader:toPath(declDir)] = true
                end
            end
        end
        do
            local referencesInConfig = self:initMapperWorker(task.subTasks, seen)
            mapper.referencesInConfigFile[path] = referencesInConfig
        end
        ::continue::
    end
    return results
end
