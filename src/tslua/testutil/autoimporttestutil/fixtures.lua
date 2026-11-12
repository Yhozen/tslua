local autoimporttestutil = require("tslua.testutil.autoimporttestutil")
local lsconv = require("tslua.ls.lsconv")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

-- tslua.testutil.projecttestutil is loaded lazily: it pulls in the whole project package.
local function projecttestutil()
    return require("tslua.testutil.projecttestutil")
end

local function clone(xs)
    if xs == nil then
        return nil
    end
    return table.move(xs, 1, #xs, 1, {})
end

-- t.Cleanup(session.Close); the Lua testing.T stand-in may not support cleanups.
local function cleanup(t, session)
    if t ~= nil and t.Cleanup ~= nil then
        t:Cleanup(function()
            session:Close()
        end)
    end
end

-- FileHandle represents a file created for an autoimport lifecycle test.
local FileHandle = {}
FileHandle.__index = FileHandle
autoimporttestutil.FileHandle = FileHandle

function autoimporttestutil.newFileHandle(fileName, content)
    return setmetatable({ fileName = fileName or "", content = content or "" }, FileHandle)
end

function FileHandle:FileName() return self.fileName end
function FileHandle:Content() return self.content end
function FileHandle:URI() return lsconv.FileNameToDocumentURI(self.fileName) end

-- ProjectFileHandle adds export metadata for TypeScript source files.
-- (Embeds FileHandle.)
local ProjectFileHandle = setmetatable({}, { __index = FileHandle })
ProjectFileHandle.__index = ProjectFileHandle
autoimporttestutil.ProjectFileHandle = ProjectFileHandle

-- NodeModulesPackageHandle describes a generated package under node_modules.
-- { name, directory, packageJSON, declaration }
local NodeModulesPackageHandle = {}
NodeModulesPackageHandle.__index = NodeModulesPackageHandle
autoimporttestutil.NodeModulesPackageHandle = NodeModulesPackageHandle

function NodeModulesPackageHandle:PackageJSONFile() return self.packageJSON end
function NodeModulesPackageHandle:DeclarationFile() return self.declaration end

-- MonorepoHandle exposes the generated monorepo layout including root and packages.
local MonorepoHandle = {}
MonorepoHandle.__index = MonorepoHandle
autoimporttestutil.MonorepoHandle = MonorepoHandle

function MonorepoHandle:Root() return self.root end
function MonorepoHandle:RootNodeModules()
    return clone(self.rootNodeModules)
end
function MonorepoHandle:RootDependencies() return clone(self.rootDependencies) end
function MonorepoHandle:Packages() return clone(self.packages) end
function MonorepoHandle:Package(index)
    if index < 0 or index >= #self.packages then
        error(string.format("package index %d out of range", index), 0)
    end
    return self.packages[index + 1]
end
function MonorepoHandle:RootTSConfig() return self.rootTSConfig end
function MonorepoHandle:RootPackageJSONFile() return self.rootPackageJSON end

-- ProjectHandle exposes the generated project layout for a fixture project root.
local ProjectHandle = {}
ProjectHandle.__index = ProjectHandle
autoimporttestutil.ProjectHandle = ProjectHandle

function ProjectHandle:Root() return self.root end
function ProjectHandle:Files() return clone(self.files) end
-- index is 0-based, like Go.
function ProjectHandle:File(index)
    if index < 0 or index >= #self.files then
        error(string.format("file index %d out of range", index), 0)
    end
    return self.files[index + 1]
end
function ProjectHandle:TSConfig() return self.tsconfig end
function ProjectHandle:PackageJSONFile() return self.packageJSON end
function ProjectHandle:NodeModules()
    return clone(self.nodeModules)
end
function ProjectHandle:Dependencies() return clone(self.dependencies) end

function ProjectHandle:NodeModuleByName(name)
    for _, nm in ipairs(self.nodeModules or {}) do
        if nm.name == name then
            return nm
        end
    end
    return nil
end

-- Fixture encapsulates a fully-initialized auto import lifecycle test session.
local Fixture = {}
Fixture.__index = Fixture
autoimporttestutil.Fixture = Fixture

function Fixture:Session() return self.session end
function Fixture:Utils() return self.utils end
function Fixture:Projects() return clone(self.projects) end
function Fixture:Project(index)
    if index < 0 or index >= #self.projects then
        error(string.format("project index %d out of range", index), 0)
    end
    return self.projects[index + 1]
end
function Fixture:SingleProject() return self:Project(0) end

-- MonorepoFixture encapsulates a fully-initialized monorepo lifecycle test session.
local MonorepoFixture = {}
MonorepoFixture.__index = MonorepoFixture
autoimporttestutil.MonorepoFixture = MonorepoFixture

function MonorepoFixture:Session() return self.session end
function MonorepoFixture:Utils() return self.utils end
function MonorepoFixture:Monorepo() return self.monorepo end
function MonorepoFixture:ExtraFiles() return clone(self.extra) end
function MonorepoFixture:ExtraFile(path)
    local normalized = autoimporttestutil.normalizeAbsolutePath(path)
    for _, handle in ipairs(self.extra) do
        if handle.fileName == normalized then
            return handle
        end
    end
    error("extra file not found: " .. path, 0)
end

-- MonorepoPackageTemplate captures the reusable settings for a package.json scope:
-- the node_modules packages that exist alongside the package.json and the dependency
-- names that should be written into that package.json. When DependencyNames is empty,
-- all available node_modules packages in scope are used.
-- { name, nodeModuleNames, dependencyNames }

-- MonorepoSetupConfig describes the monorepo root and packages to create.
-- The embedded MonorepoPackageTemplate describes the monorepo root package located at
-- Root. DependencyNames defaults to NodeModuleNames when empty.
-- Package.MonorepoPackageTemplate.DependencyNames defaults to the union of the root
-- node_modules packages and the package's own NodeModuleNames when empty.
-- { root, name, nodeModuleNames, dependencyNames (embedded template, flattened),
--   packages (array of MonorepoPackageConfig { fileCount, name, nodeModuleNames, dependencyNames }),
--   extraFiles (array of TextFileSpec { path, content }),
--   symlinks (array of SymlinkSpec { link, target }) }

-- SetupMonorepoLifecycleSession builds a monorepo workspace with root-level node_modules
-- and multiple packages, each potentially with their own node_modules.
-- The structure is:
--
--	root/
--	├── tsconfig.json (base config)
--	├── package.json
--	├── node_modules/
--	│   └── <rootNodeModuleCount packages>
--	└── packages/
--	    ├── package-a/
--	    │   ├── tsconfig.json
--	    │   ├── package.json
--	    │   ├── node_modules/
--	    │   │   └── <package-specific packages>
--	    │   └── *.ts files
--	    └── package-b/
--	        └── ...
function autoimporttestutil.SetupMonorepoLifecycleSession(t, config)
    local builder = autoimporttestutil.newFileMapBuilder(nil)

    local monorepoRoot = autoimporttestutil.normalizeAbsolutePath(config.root)
    local monorepoName = config.name or ""
    if monorepoName == "" then
        monorepoName = "monorepo"
    end

    -- Add root tsconfig.json
    local rootTSConfigPath = tspath.CombinePaths(monorepoRoot, "tsconfig.json")
    local rootTSConfigContent = "{\n  \"compilerOptions\": {\n    \"module\": \"esnext\",\n    \"target\": \"esnext\",\n    \"strict\": true,\n    \"baseUrl\": \".\",\n    \"allowJs\": true,\n    \"checkJs\": true\n  }\n}\n"
    builder:AddTextFile(rootTSConfigPath, rootTSConfigContent)
    local rootTSConfig = autoimporttestutil.newFileHandle(rootTSConfigPath, rootTSConfigContent)

    -- Add root node_modules
    local rootNodeModulesDir = tspath.CombinePaths(monorepoRoot, "node_modules")
    local rootNodeModules = builder:AddNodeModulesPackagesWithNames(rootNodeModulesDir, config.nodeModuleNames)

    -- Add root package.json with dependencies (default to all root node_modules if unspecified)
    local rootDependencies = autoimporttestutil.selectPackagesByName(rootNodeModules, config.dependencyNames)
    local rootPackageJSON = builder:addRootPackageJSON(monorepoRoot, monorepoName, rootDependencies)
    local rootDependencyNames = autoimporttestutil.packageNames(rootDependencies)

    -- Build each package in packages/
    local packagesDir = tspath.CombinePaths(monorepoRoot, "packages")
    local packageHandles = {}
    for _, pkg in ipairs(config.packages or {}) do
        local pkgDir = tspath.CombinePaths(packagesDir, pkg.name)
        builder:AddLocalProject(pkgDir, pkg.fileCount or 0)

        local pkgNodeModules = nil
        if #(pkg.nodeModuleNames or {}) > 0 then
            local pkgNodeModulesDir = tspath.CombinePaths(pkgDir, "node_modules")
            pkgNodeModules = builder:AddNodeModulesPackagesWithNames(pkgNodeModulesDir, pkg.nodeModuleNames)
        end

        local availableDeps = clone(rootNodeModules) or {}
        for _, d in ipairs(pkgNodeModules or {}) do
            availableDeps[#availableDeps + 1] = d
        end
        local selectedDeps = autoimporttestutil.selectPackagesByName(availableDeps, pkg.dependencyNames)
        if #selectedDeps > 0 then
            builder:AddPackageJSONWithDependenciesNamed(pkgDir, pkg.name, selectedDeps)
        end
    end

    -- Add arbitrary extra files
    local extraHandles = {}
    for _, extra in ipairs(config.extraFiles or {}) do
        builder:AddTextFile(extra.path, extra.content)
        extraHandles[#extraHandles + 1] = autoimporttestutil.newFileHandle(autoimporttestutil.normalizeAbsolutePath(extra.path), extra.content)
    end

    -- Add symlinks
    for _, symlink in ipairs(config.symlinks or {}) do
        builder:AddSymlink(symlink.link, symlink.target)
    end

    -- Build project handles after all packages are created
    for _, pkg in ipairs(config.packages or {}) do
        local pkgDir = tspath.CombinePaths(packagesDir, pkg.name)
        local record = builder.projects[pkgDir]
        if record ~= nil then
            packageHandles[#packageHandles + 1] = record:toHandles()
        end
    end

    local session, sessionUtils = projecttestutil().Setup(builder:Files())
    cleanup(t, session)

    -- Build root node_modules handle by looking at the project record for the workspace root
    -- (created as side effect of AddNodeModulesPackages)
    local rootNodeModulesHandles = nil
    local rootRecord = builder.projects[monorepoRoot]
    if rootRecord ~= nil then
        rootNodeModulesHandles = rootRecord.nodeModules
    end

    return setmetatable({
        session = session,
        utils = sessionUtils,
        monorepo = setmetatable({
            root = monorepoRoot,
            rootNodeModules = rootNodeModulesHandles,
            rootDependencies = rootDependencyNames,
            packages = packageHandles,
            rootTSConfig = rootTSConfig,
            rootPackageJSON = rootPackageJSON,
        }, MonorepoHandle),
        extra = extraHandles,
    }, MonorepoFixture)
end

-- SetupLifecycleSession builds a basic single-project workspace configured with the
-- requested number of TypeScript files and a single synthetic node_modules package.
function autoimporttestutil.SetupLifecycleSession(t, projectRoot, fileCount)
    local builder = autoimporttestutil.newFileMapBuilder(nil)
    builder:AddLocalProject(projectRoot, fileCount)
    local nodeModulesDir = tspath.CombinePaths(projectRoot, "node_modules")
    local deps = builder:AddNodeModulesPackages(nodeModulesDir, 1)
    builder:AddPackageJSONWithDependencies(projectRoot, deps)
    local session, sessionUtils = projecttestutil().Setup(builder:Files())
    cleanup(t, session)
    return setmetatable({
        session = session,
        utils = sessionUtils,
        projects = builder:projectHandles(),
    }, Fixture)
end

-- fileMapBuilder { files, nextPackageID, nextProjectID, projects }
local fileMapBuilder = {}
fileMapBuilder.__index = fileMapBuilder
autoimporttestutil.fileMapBuilder = fileMapBuilder

-- projectRecord { root, sourceFiles, tsconfig, packageJSON, nodeModules, dependencies }
local projectRecord = {}
projectRecord.__index = projectRecord
autoimporttestutil.projectRecord = projectRecord

-- projectFile { fileName, exportIdentifier, content }

function autoimporttestutil.newFileMapBuilder(initial)
    local b = setmetatable({
        files = {},
        nextPackageID = 0,
        nextProjectID = 0,
        projects = {},
    }, fileMapBuilder)
    if initial == nil or next(initial) == nil then
        return b
    end
    for path, content in pairs(initial) do
        b.files[autoimporttestutil.normalizeAbsolutePath(path)] = content
    end
    return b
end

function fileMapBuilder:ensureProjectRecord(root)
    local record = self.projects[root]
    if record ~= nil then
        return record
    end
    record = setmetatable({
        root = root,
        sourceFiles = {},
        tsconfig = autoimporttestutil.newFileHandle("", ""),
        packageJSON = nil,
        nodeModules = {},
        dependencies = nil,
    }, projectRecord)
    self.projects[root] = record
    return record
end

function fileMapBuilder:projectHandles()
    local keys = {}
    for k in pairs(self.projects) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local result = {}
    for _, key in ipairs(keys) do
        result[#result + 1] = self.projects[key]:toHandles()
    end
    return result
end

function projectRecord:toHandles()
    local files = {}
    for i, file in ipairs(self.sourceFiles) do
        files[i] = setmetatable({
            fileName = file.fileName,
            content = file.content,
            exportIdentifier = file.exportIdentifier,
        }, ProjectFileHandle)
    end
    local packageJSON = autoimporttestutil.newFileHandle("", "")
    if self.packageJSON ~= nil then
        packageJSON = self.packageJSON
    end
    return setmetatable({
        root = self.root,
        files = files,
        tsconfig = self.tsconfig,
        packageJSON = packageJSON,
        nodeModules = clone(self.nodeModules) or {},
        dependencies = clone(self.dependencies),
    }, ProjectHandle)
end

function fileMapBuilder:Files()
    local m = {}
    for k, v in pairs(self.files) do
        m[k] = v
    end
    return m
end

function fileMapBuilder:AddTextFile(path, contents)
    self:ensureFiles()
    self.files[autoimporttestutil.normalizeAbsolutePath(path)] = contents
end

-- AddSymlink creates a symlink from linkPath to targetPath.
-- The targetPath should be an absolute path.
function fileMapBuilder:AddSymlink(linkPath, targetPath)
    self:ensureFiles()
    self.files[autoimporttestutil.normalizeAbsolutePath(linkPath)] = vfstest.Symlink(autoimporttestutil.normalizeAbsolutePath(targetPath))
end

function fileMapBuilder:AddNodeModulesPackages(nodeModulesDir, count)
    local packages = {}
    for _ = 1, count do
        packages[#packages + 1] = self:AddNodeModulesPackage(nodeModulesDir)
    end
    return packages
end

function fileMapBuilder:AddNodeModulesPackagesWithNames(nodeModulesDir, names)
    if names == nil or #names == 0 then
        return nil
    end
    local packages = {}
    for _, name in ipairs(names) do
        packages[#packages + 1] = self:AddNamedNodeModulesPackage(nodeModulesDir, name)
    end
    return packages
end

function fileMapBuilder:AddNodeModulesPackage(nodeModulesDir)
    return self:AddNamedNodeModulesPackage(nodeModulesDir, "")
end

function fileMapBuilder:AddNamedNodeModulesPackage(nodeModulesDir, name)
    self:ensureFiles()
    local normalizedDir = autoimporttestutil.normalizeAbsolutePath(nodeModulesDir)
    if tspath.GetBaseFileName(normalizedDir) ~= "node_modules" then
        error("nodeModulesDir must point to a node_modules directory: " .. nodeModulesDir, 0)
    end
    self.nextPackageID = self.nextPackageID + 1
    local resolvedName = name
    if resolvedName == "" then
        resolvedName = string.format("pkg%d", self.nextPackageID)
    end
    local exportName = autoimporttestutil.sanitizeIdentifier(resolvedName) .. "_value"
    local pkgDir = tspath.CombinePaths(normalizedDir, resolvedName)
    local packageJSONPath = tspath.CombinePaths(pkgDir, "package.json")
    local packageJSONContent = string.format("{\"name\":\"%s\",\"types\":\"index.d.ts\"}", resolvedName)
    self.files[packageJSONPath] = packageJSONContent
    local declarationPath = tspath.CombinePaths(pkgDir, "index.d.ts")
    local declarationContent = string.format("export declare const %s: number;\n", exportName)
    self.files[declarationPath] = declarationContent
    local packageHandle = setmetatable({
        name = resolvedName,
        directory = pkgDir,
        packageJSON = autoimporttestutil.newFileHandle(packageJSONPath, packageJSONContent),
        declaration = autoimporttestutil.newFileHandle(declarationPath, declarationContent),
    }, NodeModulesPackageHandle)
    local projectRoot = tspath.GetDirectoryPath(normalizedDir)
    local record = self:ensureProjectRecord(projectRoot)
    record.nodeModules[#record.nodeModules + 1] = packageHandle
    return packageHandle
end

function fileMapBuilder:AddLocalProject(projectDir, fileCount)
    self:ensureFiles()
    if fileCount < 0 then
        error("fileCount must be non-negative", 0)
    end
    local dir = autoimporttestutil.normalizeAbsolutePath(projectDir)
    local record = self:ensureProjectRecord(dir)
    self.nextProjectID = self.nextProjectID + 1
    local tsConfigPath = tspath.CombinePaths(dir, "tsconfig.json")
    local tsConfigContent = "{\n  \"compilerOptions\": {\n    \"module\": \"esnext\",\n    \"target\": \"esnext\",\n    \"strict\": true,\n    \"allowJs\": true,\n    \"checkJs\": true\n  }\n}\n"
    self.files[tsConfigPath] = tsConfigContent
    record.tsconfig = autoimporttestutil.newFileHandle(tsConfigPath, tsConfigContent)
    for i = 1, fileCount do
        local path = tspath.CombinePaths(dir, string.format("file%d.ts", i))
        local exportName = string.format("localExport%d_%d", self.nextProjectID, i)
        local content = string.format("export const %s = %d;\n", exportName, i)
        self.files[path] = content
        record.sourceFiles[#record.sourceFiles + 1] = { fileName = path, exportIdentifier = exportName, content = content }
    end
end

function fileMapBuilder:AddPackageJSONWithDependencies(projectDir, deps)
    self.nextProjectID = self.nextProjectID + 1
    return self:AddPackageJSONWithDependenciesNamed(projectDir, string.format("local-project-%d", self.nextProjectID), deps)
end

local function dependencyBlock(deps)
    local dependencyLines = {}
    for _, dep in ipairs(deps or {}) do
        dependencyLines[#dependencyLines + 1] = string.format("\"%s\": \"*\"", dep.name)
    end
    if #dependencyLines > 0 then
        return ",\n  \"dependencies\": {\n    " .. table.concat(dependencyLines, ",\n    ") .. "\n  }\n"
    end
    return "\n"
end

function fileMapBuilder:AddPackageJSONWithDependenciesNamed(projectDir, packageName, deps)
    self:ensureFiles()
    local dir = autoimporttestutil.normalizeAbsolutePath(projectDir)
    local packageJSONPath = tspath.CombinePaths(dir, "package.json")
    local name = packageName
    if name == "" then
        self.nextProjectID = self.nextProjectID + 1
        name = string.format("local-project-%d", self.nextProjectID)
    end
    local content = string.format("{\n  \"name\": \"%s\"", name) .. dependencyBlock(deps) .. "}\n"
    self.files[packageJSONPath] = content
    local record = self:ensureProjectRecord(dir)
    local packageHandle = autoimporttestutil.newFileHandle(packageJSONPath, content)
    record.packageJSON = packageHandle
    record.dependencies = autoimporttestutil.packageNames(deps)
    return packageHandle
end

-- addRootPackageJSON creates a root package.json for a monorepo without creating a project record.
-- This is used to set up the root workspace config without treating it as a project.
function fileMapBuilder:addRootPackageJSON(rootDir, packageName, deps)
    self:ensureFiles()
    local dir = autoimporttestutil.normalizeAbsolutePath(rootDir)
    local packageJSONPath = tspath.CombinePaths(dir, "package.json")
    local pkgName = packageName
    if pkgName == "" then
        pkgName = "monorepo-root"
    end
    local content = string.format("{\n  \"name\": \"%s\",\n  \"private\": true", pkgName) .. dependencyBlock(deps) .. "}\n"
    self.files[packageJSONPath] = content
    return autoimporttestutil.newFileHandle(packageJSONPath, content)
end

function autoimporttestutil.selectPackagesByName(available, names)
    if names == nil or #names == 0 then
        return clone(available) or {}
    end
    local result = {}
    for _, name in ipairs(names) do
        local found = false
        for _, candidate in ipairs(available or {}) do
            if candidate.name == name then
                result[#result + 1] = candidate
                found = true
                break
            end
        end
        if not found then
            error("dependency not found: " .. name, 0)
        end
    end
    return result
end

function autoimporttestutil.packageNames(deps)
    if deps == nil or #deps == 0 then
        return nil
    end
    local names = {}
    for _, dep in ipairs(deps) do
        names[#names + 1] = dep.name
    end
    return names
end

function autoimporttestutil.sanitizeIdentifier(name)
    local sanitized = string.gsub(name, "[^%w_%-]", "")
    sanitized = string.gsub(sanitized, "[_%-]", "_")
    if sanitized == "" then
        return "pkg"
    end
    return sanitized
end

function fileMapBuilder:ensureFiles()
    if self.files == nil then
        self.files = {}
    end
end

function autoimporttestutil.normalizeAbsolutePath(path)
    local normalized = tspath.NormalizePath(path)
    if not tspath.PathIsAbsolute(normalized) then
        error("paths used in lifecycle tests must be absolute: " .. path, 0)
    end
    return normalized
end
