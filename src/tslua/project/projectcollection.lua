local project = require("tslua.project")
local collections = require("tslua.collections")
local core = require("tslua.core")

-- ProjectCollection:
--   toPath, configFileRegistry
--   fileDefaultProjects: a map of file paths to the config file path (the key
--     into `configuredProjects`) of the default project for that file. If the file
--     belongs to the inferred project, the value is `inferredProjectName`. This map
--     contains quick lookups for only the associations discovered during the latest
--     snapshot update.
--   configuredProjects: the set of loaded projects associated with a tsconfig
--     file, keyed by the config file path.
--   openFiles: the set of open file paths associated with the snapshot that owns
--     this project collection.
--   inferredProject: a fallback project that is used when no configured
--     project can be found for an open file.
--   apiState: tracks the projects and files that API clients have explicitly
--     opened so they are kept loaded across snapshots.
local ProjectCollection = {}
ProjectCollection.__index = ProjectCollection
project.ProjectCollection = ProjectCollection

function project.newProjectCollection(fields)
    return setmetatable({
        toPath = fields.toPath,
        configFileRegistry = fields.configFileRegistry,
        fileDefaultProjects = fields.fileDefaultProjects,
        configuredProjects = fields.configuredProjects,
        openFiles = fields.openFiles or collections.NewSet(),
        inferredProject = fields.inferredProject,
        apiState = fields.apiState or project.newAPIState(),
        openConfiguredProjectsOnce = false,
        openConfiguredProjects = nil,
    }, ProjectCollection)
end

-- APIState tracks the projects and files that API clients have explicitly opened.
-- Opens and closes are ref-counted so multiple API clients don't clobber each
-- other, and it is carried across snapshots so API-opened resources stay loaded.
--   openProjects: the ref-counted set of projects to keep open for API
--     clients, keyed by config file path. The value is the number of outstanding
--     API opens.
--   openFiles: the ref-counted set of files to keep open for API clients,
--     keyed by file path. Files with no configured project are loaded into the
--     inferred project. Values are apiOpenedFile { fileName, refCount } (immutable).
function project.newAPIState(openProjects, openFiles)
    return { openProjects = openProjects, openFiles = openFiles }
end

function project.APIState_clone(s)
    return project.newAPIState(project.cloneMap(s.openProjects), project.cloneMap(s.openFiles))
end

local function apiOpenedFilesEqual(a, b)
    for k, v in pairs(a or {}) do
        local w = b ~= nil and b[k] or nil
        if w == nil or w.fileName ~= v.fileName or w.refCount ~= v.refCount then
            return false
        end
    end
    for k in pairs(b or {}) do
        if a == nil or a[k] == nil then
            return false
        end
    end
    return true
end

function project.APIState_equals(s, other)
    return project.mapsEqual(s.openProjects, other.openProjects) and apiOpenedFilesEqual(s.openFiles, other.openFiles)
end

function ProjectCollection:ConfigFileRegistry()
    return self.configFileRegistry
end

function ProjectCollection:ConfiguredProject(path)
    return self.configuredProjects ~= nil and self.configuredProjects[path] or nil
end

function ProjectCollection:GetProjectByPath(projectPath)
    local p = self.configuredProjects ~= nil and self.configuredProjects[projectPath] or nil
    if p ~= nil then
        return p
    end

    if projectPath == project.inferredProjectName then
        return self.inferredProject
    end

    return nil
end

-- ConfiguredProjects returns all configured projects in a stable order.
function ProjectCollection:ConfiguredProjects()
    local projects = {}
    self:fillConfiguredProjects(projects)
    return projects
end

function ProjectCollection:fillConfiguredProjects(projects)
    for _, p in pairs(self.configuredProjects or {}) do
        projects[#projects + 1] = p
    end
    table.sort(projects, function(a, b)
        return a:Name() < b:Name()
    end)
end

-- ProjectsByPath returns an ordered map of configured projects keyed by their config file path,
-- plus the inferred project, if it exists, with the key `inferredProjectName`.
function ProjectCollection:ProjectsByPath()
    local projects = collections.NewOrderedMapWithSizeHint(
        project.mapLen(self.configuredProjects) + core.IfElse(self.inferredProject ~= nil, 1, 0)
    )
    for _, p in ipairs(self:ConfiguredProjects()) do
        projects:Set(p.configFilePath, p)
    end
    if self.inferredProject ~= nil then
        projects:Set(project.inferredProjectName, self.inferredProject)
    end
    return projects
end

-- Projects returns all projects, including the inferred project if it exists, in a stable order.
function ProjectCollection:Projects()
    if self.inferredProject == nil then
        return self:ConfiguredProjects()
    end
    local projects = {}
    self:fillConfiguredProjects(projects)
    projects[#projects + 1] = self.inferredProject
    return projects
end

function ProjectCollection:InferredProject()
    return self.inferredProject
end

function ProjectCollection:GetProjectsContainingFile(path)
    local projects = nil
    for _, p in ipairs(self:ConfiguredProjects()) do
        if p:containsFile(path) then
            projects = projects or {}
            projects[#projects + 1] = p
        end
    end
    if self.inferredProject ~= nil and self.inferredProject:containsFile(path) then
        projects = projects or {}
        projects[#projects + 1] = self.inferredProject
    end
    return projects
end

-- GetOpenConfiguredProjects returns configured projects containing at least one open file.
function ProjectCollection:GetOpenConfiguredProjects()
    if not self.openConfiguredProjectsOnce then
        self.openConfiguredProjectsOnce = true
        local openProjects = collections.NewSetWithSizeHint(project.mapLen(self.configuredProjects))
        for path in pairs(project.setKeys(self.openFiles)) do
            local projectPath = self.fileDefaultProjects ~= nil and self.fileDefaultProjects[path] or nil
            if projectPath ~= nil and projectPath ~= project.inferredProjectName then
                if self.configuredProjects ~= nil and self.configuredProjects[projectPath] ~= nil then
                    openProjects:Add(projectPath)
                    goto continue
                end
            end

            for _, p in pairs(self.configuredProjects or {}) do
                if p:containsFile(path) then
                    openProjects:Add(p.configFilePath)
                end
            end
            ::continue::
        end
        self.openConfiguredProjects = openProjects
    end
    return self.openConfiguredProjects
end

function project.openFilePaths(overlays)
    local openFiles = collections.NewSetWithSizeHint(project.mapLen(overlays))
    for path in pairs(overlays or {}) do
        openFiles:Add(path)
    end
    return openFiles
end

-- !!! result could be cached
function ProjectCollection:GetDefaultProject(path)
    local result = self.fileDefaultProjects ~= nil and self.fileDefaultProjects[path] or nil
    if result ~= nil then
        if result == project.inferredProjectName then
            return self.inferredProject
        end
        return self.configuredProjects ~= nil and self.configuredProjects[result] or nil
    end

    local containingProjects = {}
    local firstConfiguredProject = nil
    local firstNonSourceOfProjectReferenceRedirect = nil
    local multipleDirectInclusions = false
    for _, p in ipairs(self:ConfiguredProjects()) do
        if p:containsFile(path) then
            containingProjects[#containingProjects + 1] = p
            if not multipleDirectInclusions and not p:IsSourceFromProjectReference(path) then
                if firstNonSourceOfProjectReferenceRedirect == nil then
                    firstNonSourceOfProjectReferenceRedirect = p
                else
                    multipleDirectInclusions = true
                end
            end
            if firstConfiguredProject == nil then
                firstConfiguredProject = p
            end
        end
    end
    if #containingProjects == 1 then
        return containingProjects[1]
    end
    if #containingProjects == 0 then
        if self.inferredProject ~= nil and self.inferredProject:containsFile(path) then
            return self.inferredProject
        end
        return nil
    end
    if not multipleDirectInclusions then
        if firstNonSourceOfProjectReferenceRedirect ~= nil then
            -- Multiple projects include the file, but only one is a direct inclusion.
            return firstNonSourceOfProjectReferenceRedirect
        end
        -- Multiple projects include the file, and none are direct inclusions.
        return firstConfiguredProject
    end
    -- Multiple projects include the file directly.
    local defaultProject = self:findDefaultConfiguredProject(path)
    if defaultProject ~= nil then
        return defaultProject
    end
    return firstConfiguredProject
end

function ProjectCollection:findDefaultConfiguredProject(path)
    local configFileName = self.configFileRegistry:GetConfigFileName(path)
    if configFileName ~= "" then
        return self:findDefaultConfiguredProjectWorker(path, configFileName, nil, nil)
    end
    return nil
end

function ProjectCollection:findDefaultConfiguredProjectWorker(path, configFileName, visited, fallback)
    local configFilePath = self.toPath(configFileName)
    local p = self.configuredProjects ~= nil and self.configuredProjects[configFilePath] or nil
    if p == nil then
        return nil
    end
    if visited == nil then
        visited = collections.NewSyncSet()
    end

    -- Look in the config's project and its references recursively.
    local search = core.BreadthFirstSearchParallelEx(
        p,
        function(proj)
            if proj.commandLine == nil then
                return nil
            end
            -- A referenced project may not be loaded if `disableReferencedProjectLoad` is true.
            return core.MapNonNil(proj.commandLine:ResolvedProjectReferencePaths() or {}, function(refConfigFileName)
                return self.configuredProjects[self.toPath(refConfigFileName)]
            end)
        end,
        function(proj)
            if proj:containsFile(path) then
                return true, not proj:IsSourceFromProjectReference(path)
            end
            return false, false
        end,
        { visited = visited },
        core.Identity
    )

    if search.stopped then
        -- If we found a project that directly contains the file, return it.
        return search.path[1]
    end
    if core.Len(search.path) > 0 and fallback == nil then
        -- If we found a project that contains the file, but it is a source from
        -- a project reference, record it as a fallback.
        fallback = search.path[1]
    end

    -- Look for tsconfig.json files higher up the directory tree and do the same. This handles
    -- the common case where a higher-level "solution" tsconfig.json contains all projects in a
    -- workspace.
    local config = self.configFileRegistry:GetConfig(path)
    if config ~= nil and core.Tristate_IsTrue(config:CompilerOptions().disableSolutionSearching) then
        return fallback
    end
    local ancestorConfigName = self.configFileRegistry:GetAncestorConfigFileName(path, configFileName)
    if ancestorConfigName ~= "" then
        return self:findDefaultConfiguredProjectWorker(path, ancestorConfigName, visited, fallback)
    end
    return fallback
end

-- clone creates a shallow copy of the project collection.
function ProjectCollection:clone()
    return project.newProjectCollection({
        toPath = self.toPath,
        configFileRegistry = self.configFileRegistry,
        configuredProjects = self.configuredProjects,
        openFiles = self.openFiles,
        inferredProject = self.inferredProject,
        fileDefaultProjects = self.fileDefaultProjects,
        apiState = self.apiState,
    })
end

-- findDefaultConfiguredProjectFromProgramInclusion finds the default configured project for a file
-- based on the file's inclusion in existing projects. The projects should be sorted, as ties will
-- be broken by slice order. `getProject` should return a project with an up-to-date program.
-- Along with the resulting project path, a boolean is returned indicating whether there were multiple
-- direct inclusions of the file in different projects, indicating that the caller may want to perform
-- additional logic to determine the best project.
-- Returns (result, multipleCandidates).
function project.findDefaultConfiguredProjectFromProgramInclusion(fileName, path, projectPaths, getProject)
    local containingProjects = {}
    local firstConfiguredProject = ""
    local firstNonSourceOfProjectReferenceRedirect = ""
    local multipleDirectInclusions = false

    for _, projectPath in ipairs(projectPaths) do
        local p = getProject(projectPath)
        if p:containsFile(path) then
            containingProjects[#containingProjects + 1] = projectPath
            if not multipleDirectInclusions and not p:IsSourceFromProjectReference(path) then
                if firstNonSourceOfProjectReferenceRedirect == "" then
                    firstNonSourceOfProjectReferenceRedirect = projectPath
                else
                    multipleDirectInclusions = true
                end
            end
            if firstConfiguredProject == "" then
                firstConfiguredProject = projectPath
            end
        end
    end

    if #containingProjects == 1 then
        return containingProjects[1], false
    end
    if not multipleDirectInclusions then
        if firstNonSourceOfProjectReferenceRedirect ~= "" then
            -- Multiple projects include the file, but only one is a direct inclusion.
            return firstNonSourceOfProjectReferenceRedirect, false
        end
        -- Multiple projects include the file, and none are direct inclusions.
        return firstConfiguredProject, false
    end
    -- Multiple projects include the file directly.
    return firstConfiguredProject, true
end
