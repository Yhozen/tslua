local ast = require("tslua.ast")
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local core = require("tslua.core")
local module = require("tslua.module")
local parser = require("tslua.parser")
local vfstest = require("tslua.vfs.vfstest")
local autoimport = require("tslua.ls.autoimport")

-- index_test.go

local testEntry = {}
testEntry.__index = testEntry

local function newTestEntry(name, package_)
    return setmetatable({ name = name, package_ = package_ }, testEntry)
end

function testEntry:Name()
    return self.name
end

describe("autoimport Index.Clone", function()
    it("filters entries by package", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("fooBar", "pkg-a"))
        idx:insertAsWords(newTestEntry("bazQux", "pkg-b"))
        idx:insertAsWords(newTestEntry("fooQux", "pkg-a"))

        -- Clone excluding pkg-b
        local cloned = idx:Clone(function(e)
            return e.package_ ~= "pkg-b"
        end)

        -- Original should have all 3 entries
        assert.are.equal(3, #idx.entries)

        -- Cloned should have 2 entries (only pkg-a)
        assert.are.equal(2, #cloned.entries)

        -- Search should work on cloned index
        local results = cloned:Find("fooBar", true)
        assert.are.equal(1, core.Len(results))
        assert.are.equal("fooBar", results[1].name)

        -- bazQux should not be in cloned index
        results = cloned:Find("bazQux", true)
        assert.are.equal(0, core.Len(results))

        -- Word prefix search should work
        results = cloned:SearchWordPrefix("foo")
        assert.are.equal(2, core.Len(results))
    end)

    it("handles nil index", function()
        local cloned = autoimport.Index.Clone(nil, function() return true end)
        assert.is_nil(cloned)
    end)

    it("handles empty index", function()
        local idx = autoimport.NewIndex()
        local cloned = idx:Clone(function() return true end)
        assert.are.equal(0, #cloned.entries)
    end)

    it("filters all entries", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("fooBar", "pkg-a"))
        idx:insertAsWords(newTestEntry("bazQux", "pkg-b"))

        local cloned = idx:Clone(function() return false end)
        assert.are.equal(0, #cloned.entries)
        assert.are.equal(nil, next(cloned.index))
    end)
end)

describe("autoimport Index search", function()
    it("finds case-insensitive and word-prefix matches", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("readFileSync", ""))
        idx:insertAsWords(newTestEntry("ReadStream", ""))
        idx:insertAsWords(newTestEntry("createReadStream", ""))
        assert.are.equal(1, core.Len(idx:Find("readfilesync", false)))
        assert.are.equal(0, core.Len(idx:Find("readfilesync", true)))
        local names = {}
        for _, e in ipairs(idx:SearchWordPrefix("rs") or {}) do
            names[#names + 1] = e.name
        end
        assert.are.same({ "readFileSync", "ReadStream", "createReadStream" }, names)
        assert.are.equal(3, core.Len(idx:SearchWordPrefix("")))
    end)
end)

-- util_test.go

describe("autoimport wordIndices", function()
    local tests = {
        -- Basic camelCase
        { input = "camelCase", expectedWords = { "camelCase", "Case" } },
        -- snake_case
        { input = "snake_case", expectedWords = { "snake_case", "case" } },
        -- ParseURL - uppercase sequence followed by lowercase
        { input = "ParseURL", expectedWords = { "ParseURL", "URL" } },
        -- XMLHttpRequest - multiple uppercase sequences
        { input = "XMLHttpRequest", expectedWords = { "XMLHttpRequest", "HttpRequest", "Request" } },
        -- Single word lowercase
        { input = "hello", expectedWords = { "hello" } },
        -- Single word uppercase
        { input = "HELLO", expectedWords = { "HELLO" } },
        -- Mixed with numbers
        { input = "parseHTML5Parser", expectedWords = { "parseHTML5Parser", "HTML5Parser", "Parser" } },
        -- Underscore variations
        { input = "__proto__", expectedWords = { "__proto__", "proto__" } },
        { input = "_private_member", expectedWords = { "_private_member", "member" } },
        -- Single character
        { input = "a", expectedWords = { "a" } },
        { input = "A", expectedWords = { "A" } },
        -- Consecutive underscores
        { input = "test__double__underscore", expectedWords = { "test__double__underscore", "double__underscore", "underscore" } },
    }

    for _, tt in ipairs(tests) do
        it(tt.input, function()
            local indices = autoimport.wordIndices(tt.input)

            -- Convert indices to actual word slices for comparison
            local actualWords = {}
            for _, idx in ipairs(indices) do
                actualWords[#actualWords + 1] = string.sub(tt.input, idx + 1)
            end

            assert.are.same(tt.expectedWords, actualWords)
        end)
    end
end)

-- TestGetPackageRealpathFuncs_FollowsNodeModulesSymlinks tests that toRealpath correctly
-- follows symlinks for files outside the package directory (e.g. node_modules entries).
describe("autoimport getPackageRealpathFuncs", function()
    it("follows node_modules symlinks", function()
        -- Simulate a layout where the package directory is itself a symlink (e.g. Bazel's
        -- convenience symlinks or pnpm's virtual store):
        --   /symlink-bin/pkg/              -> symlink to /real/bin/pkg/
        --   /real/bin/pkg/node_modules/dep -> symlink to /real/dep/
        local fs = vfstest.FromMap({
            ["/symlink-bin/pkg"] = vfstest.Symlink("/real/bin/pkg"),
            ["/real/bin/pkg/index.d.ts"] = "export declare const a: number;",
            ["/real/bin/pkg/node_modules/dep"] = vfstest.Symlink("/real/dep"),
            ["/real/dep/index.d.ts"] = "export declare const b: number;",
            ["/real/dep/src/utils/helper.d.ts"] = "export declare const c: number;",
        }, true)

        local toRealpath = autoimport.getPackageRealpathFuncs(fs, "/symlink-bin/pkg")

        -- Files inside the package should be converted via string replacement (fast path).
        assert.are.equal("/real/bin/pkg/index.d.ts", toRealpath("/symlink-bin/pkg/index.d.ts"))

        -- Files outside the package (e.g. node_modules symlinks) should be resolved via
        -- fs.Realpath so the cache key is the canonical realpath, not the symlink path.
        assert.are.equal("/real/dep/index.d.ts", toRealpath("/real/bin/pkg/node_modules/dep/index.d.ts"))

        -- Files in subdirectories of an already-resolved external package should
        -- use the cached prefix mapping without additional realpath calls.
        assert.are.equal("/real/dep/src/utils/helper.d.ts", toRealpath("/real/bin/pkg/node_modules/dep/src/utils/helper.d.ts"))
    end)

    -- TestGetPackageRealpathFuncs_DuplicateCacheKeys
    it("gives the same cache key to a dependency reached through different symlinks", function()
        local fs = vfstest.FromMap({
            ["/workspace/packages/app-a"] = vfstest.Symlink("/store/app-a"),
            ["/workspace/packages/app-b"] = vfstest.Symlink("/store/app-b"),
            ["/store/app-a/index.d.ts"] = "export declare const a: number;",
            ["/store/app-b/index.d.ts"] = "export declare const b: number;",
            ["/store/app-a/node_modules/shared-lib"] = vfstest.Symlink("/store/shared-lib"),
            ["/store/app-b/node_modules/shared-lib"] = vfstest.Symlink("/store/shared-lib"),
            ["/store/shared-lib/index.d.ts"] = "export declare const shared: string;",
        }, true)

        local toRealpathA = autoimport.getPackageRealpathFuncs(fs, "/workspace/packages/app-a")
        local toRealpathB = autoimport.getPackageRealpathFuncs(fs, "/workspace/packages/app-b")

        local resolvedA = toRealpathA("/store/app-a/node_modules/shared-lib/index.d.ts")
        local resolvedB = toRealpathB("/store/app-b/node_modules/shared-lib/index.d.ts")

        -- Both should resolve to the same canonical realpath so the module resolver
        -- uses a single cache key for the shared dependency, avoiding duplicate loads.
        assert.are.equal("/store/shared-lib/index.d.ts", resolvedA)
        assert.are.equal("/store/shared-lib/index.d.ts", resolvedB)
    end)

    -- TestGetPackageRealpathFuncs_NonSymlinkedPackageWithSymlinkedDeps
    it("follows symlinked deps of a non-symlinked package", function()
        local fs = vfstest.FromMap({
            ["/real/my-pkg/index.d.ts"] = "export declare const a: number;",
            ["/real/my-pkg/node_modules/dep"] = vfstest.Symlink("/real/dep"),
            ["/real/dep/index.d.ts"] = "export declare const b: number;",
        }, true)

        local toRealpath = autoimport.getPackageRealpathFuncs(fs, "/real/my-pkg")

        -- Files inside the (non-symlinked) package should be returned unchanged.
        assert.are.equal("/real/my-pkg/index.d.ts", toRealpath("/real/my-pkg/index.d.ts"))

        -- Files outside the package reached via symlinked node_modules should still be resolved.
        assert.are.equal("/real/dep/index.d.ts", toRealpath("/real/my-pkg/node_modules/dep/index.d.ts"))
    end)
end)

-- aliasresolver_crash_test.go

local fakeCloneHost = {}
fakeCloneHost.__index = fakeCloneHost

function fakeCloneHost:FS() return self.fs end
function fakeCloneHost:GetCurrentDirectory() return "/" end
function fakeCloneHost:GetDefaultProject() return "", nil end
function fakeCloneHost:GetProgramForProject() return nil end
function fakeCloneHost:GetPackageJson() return nil end
function fakeCloneHost:GetSourceFile() return nil end
function fakeCloneHost:Dispose() end

describe("autoimport aliasResolver", function()
    -- Regression test for microsoft/typescript-go#4322.
    --
    -- During auto-import export extraction, the checker is built on top of an
    -- aliasResolver standing in for a real program. This file has a type error, and
    -- extracting exports should still complete without crashing.
    it("GetDiagnostics does not panic", function()
        local fileName = "/pkg/index.ts"
        local text = "declare function f(arg: { a: string }): () => void;\nexport const x = f({ a: 1 });\n"

        local fs = vfstest.FromMap({ [fileName] = text }, true --[[useCaseSensitiveFileNames]])
        local host = setmetatable({ fs = fs }, fakeCloneHost)

        local sourceFile = parser.ParseSourceFile(ast.NewSourceFileParseOptions(fileName, fileName), text, core.ScriptKind.TS)
        binder.BindSourceFile(sourceFile)

        local resolver = module.NewResolver(host, core.EmptyCompilerOptions, "", "", nil)
        local r = autoimport.newAliasResolver(
            { sourceFile },
            nil,
            host,
            resolver,
            function(f) return f end,
            function() end
        )

        local ch = checker.NewChecker(r, nil)

        -- Type-checking this file's diagnostics must not panic.
        ch:GetDiagnostics(nil, sourceFile)
    end)
end)

-- registry_test.go (needs tslua.project and tslua.testutil.projecttestutil)

local function tryRequire(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    return nil
end

local projecttestutil = tryRequire("tslua.testutil.projecttestutil")
local project = tryRequire("tslua.project")
local hasSession = projecttestutil ~= nil and project ~= nil and projecttestutil.Setup ~= nil

local lifecycleProjectRoot = "/home/src/autoimport-lifecycle"
local monorepoProjectRoot = "/home/src/autoimport-monorepo"

describe("autoimport registry lifecycle", function()
    if not hasSession then
        pending("tslua.project / tslua.testutil.projecttestutil not available")
        return
    end

    local autoimporttestutil = require("tslua.testutil.autoimporttestutil")
    local bundled = require("tslua.bundled")
    local collections = require("tslua.collections")
    local lsconv = require("tslua.ls.lsconv")
    local lsproto = require("tslua.lsp.lsproto")
    local lsutil = require("tslua.ls.lsutil")
    local tspath = require("tslua.tspath")

    local TypeScript = lsproto.LanguageKind.TypeScript
    local JavaScript = lsproto.LanguageKind.JavaScript

    local function autoImportStats(session)
        local snapshot = session:Snapshot()
        local registry = snapshot:AutoImportRegistry()
        assert(registry ~= nil, "auto import registry not initialized")
        return registry:GetCacheStats()
    end

    local function singleBucket(buckets)
        assert(#buckets == 1, string.format("expected 1 bucket, got %d", #buckets))
        return buckets[1]
    end

    local function wholeDocument(text)
        return { { wholeDocument = { text = text } } }
    end

    local function noError(_, err)
        assert.is_nil(err)
    end

    local function defaultPreferences()
        local preferences = lsutil.NewDefaultUserPreferences()
        preferences.includeCompletionsForModuleExports = core.Tristate.TSTrue
        preferences.includeCompletionsForImportStatements = core.Tristate.TSTrue
        return preferences
    end

    it("builds project and node_modules buckets", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)

        local stats = autoImportStats(session)
        local projectBucket = singleBucket(stats.projectBuckets)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(true, projectBucket.state:Dirty())
        assert.are.equal(0, projectBucket.fileCount)
        assert.are.equal(true, nodeModulesBucket.state:Dirty())
        assert.are.equal(0, nodeModulesBucket.fileCount)

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        stats = autoImportStats(session)
        projectBucket = singleBucket(stats.projectBuckets)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, projectBucket.state:Dirty())
        assert.is_true(projectBucket.exportCount > 0)
        assert.are.equal(false, nodeModulesBucket.state:Dirty())
        assert.is_true(nodeModulesBucket.exportCount > 0)
        session:Close()
    end)

    it("bucket does not rebuild on same-file change", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 2)
        local session = fixture:Session()
        local utils = fixture:Utils()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        local secondaryFile = proj:File(1)
        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        session:DidOpenFile(nil, secondaryFile:URI(), 1, secondaryFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        local updatedContent = mainFile:Content() .. "// change\n"
        session:DidChangeFile(nil, mainFile:URI(), 2, wholeDocument(updatedContent))

        noError(session:GetLanguageService(nil, mainFile:URI()))

        local stats = autoImportStats(session)
        local projectBucket = singleBucket(stats.projectBuckets)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(true, projectBucket.state:Dirty())
        assert.are.equal(utils:ToPath(mainFile:FileName()), projectBucket.state:DirtyFile())
        assert.are.equal(false, nodeModulesBucket.state:Dirty())
        assert.are.equal("", nodeModulesBucket.state:DirtyFile())

        -- Bucket should not recompute when requesting same file changed
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        stats = autoImportStats(session)
        projectBucket = singleBucket(stats.projectBuckets)
        assert.are.equal(true, projectBucket.state:Dirty())
        assert.are.equal(utils:ToPath(mainFile:FileName()), projectBucket.state:DirtyFile())

        -- Bucket should recompute when other file has changed
        session:DidChangeFile(nil, secondaryFile:URI(), 1, wholeDocument("// new content"))
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        stats = autoImportStats(session)
        projectBucket = singleBucket(stats.projectBuckets)
        assert.are.equal(false, projectBucket.state:Dirty())
        session:Close()
    end)

    it("bucket updates on same-file change when new files added to the program", function()
        local projectRoot = "/home/src/explicit-files-project"
        local files = {
            [projectRoot .. "/tsconfig.json"] = [[{
				"compilerOptions": {
					"module": "esnext",
					"target": "esnext",
					"strict": true
				},
				"files": ["index.ts"]
			}]],
            [projectRoot .. "/index.ts"] = "",
            [projectRoot .. "/utils.ts"] = "export const foo = 1;\nexport const bar = 2;",
        }
        local session = projecttestutil.Setup(files)

        local indexURI = "file://" .. projectRoot .. "/index.ts"

        -- Open the index.ts file
        session:DidOpenFile(nil, indexURI, 1, "", TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
        local stats = autoImportStats(session)
        local projectBucket = singleBucket(stats.projectBuckets)
        assert.are.equal(1, projectBucket.fileCount)

        -- Edit index.ts to import foo from utils.ts
        session:DidChangeFile(nil, indexURI, 2, wholeDocument([[import { foo } from "./utils";]]))

        -- Bucket should be rebuilt because new files were added
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
        stats = autoImportStats(session)
        projectBucket = singleBucket(stats.projectBuckets)
        assert.are.equal(2, projectBucket.fileCount)
        session:Close()
    end)

    it("package.json dependency changes invalidate node_modules buckets", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local sessionUtils = fixture:Utils()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        local nodePackage = proj:NodeModules()[1]
        local packageJSON = proj:PackageJSONFile()

        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        local stats = autoImportStats(session)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, nodeModulesBucket.state:Dirty())

        local fs = sessionUtils:FS()
        local updatePackageJSON = function(content)
            assert.is_nil(fs:WriteFile(packageJSON:FileName(), content))
            session:DidChangeWatchedFiles(nil, {
                { type = lsproto.FileChangeType.Changed, uri = packageJSON:URI() },
            })
        end

        local sameDepsContent = string.format("{\n  \"name\": \"local-project-stable\",\n  \"dependencies\": {\n    \"%s\": \"*\"\n  }\n}\n", nodePackage.name)
        updatePackageJSON(sameDepsContent)
        noError(session:GetLanguageService(nil, mainFile:URI()))
        stats = autoImportStats(session)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, nodeModulesBucket.state:Dirty())

        local differentDepsContent = string.format("{\n  \"name\": \"local-project-stable\",\n  \"dependencies\": {\n    \"%s\": \"*\",\n    \"newpkg\": \"*\"\n  }\n}\n", nodePackage.name)
        updatePackageJSON(differentDepsContent)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        stats = autoImportStats(session)
        assert.is_true(singleBucket(stats.nodeModulesBuckets).dependencyNames:Has("newpkg"))
        session:Close()
    end)

    it("node_modules buckets get deleted when no open files can reference them", function()
        local fixture = autoimporttestutil.SetupMonorepoLifecycleSession(nil, {
            root = monorepoProjectRoot,
            name = "monorepo",
            nodeModuleNames = { "pkg-root" },
            packages = {
                { fileCount = 1, name = "package-a", nodeModuleNames = { "pkg-a" } },
                { fileCount = 1, name = "package-b", nodeModuleNames = { "pkg-b" } },
            },
        })
        local session = fixture:Session()
        local monorepo = fixture:Monorepo()
        local pkgA = monorepo:Package(0)
        local pkgB = monorepo:Package(1)
        local fileA = pkgA:File(0)
        local fileB = pkgB:File(0)

        -- Open file in package-a, should create buckets for root and package-a node_modules
        session:DidOpenFile(nil, fileA:URI(), 1, fileA:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, fileA:URI()))

        -- Open file in package-b, should also create buckets for package-b
        session:DidOpenFile(nil, fileB:URI(), 1, fileB:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, fileB:URI()))
        local stats = autoImportStats(session)
        assert.are.equal(3, #stats.nodeModulesBuckets)
        assert.are.equal(2, #stats.projectBuckets)

        -- Close file in package-a, package-a's node_modules bucket and project bucket should be removed
        session:DidCloseFile(nil, fileA:URI())
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, fileB:URI()))
        stats = autoImportStats(session)
        assert.are.equal(2, #stats.nodeModulesBuckets)
        assert.are.equal(1, #stats.projectBuckets)
        session:Close()
    end)

    it("deleting node_modules leaves the registry prepared for importing", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local sessionUtils = fixture:Utils()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        local preferences = defaultPreferences()

        -- Build auto-imports once so both buckets are clean and prepared.
        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        local snapshot = session:Snapshot()
        local defaultProject = snapshot:GetDefaultProject(mainFile:URI())
        assert.is_not_nil(defaultProject)
        local projectPath = defaultProject:ConfigFilePath()
        assert.is_true(snapshot:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, preferences))
        assert.are.equal(1, #autoImportStats(session).nodeModulesBuckets)

        -- Simulate the user deleting node_modules: remove the directory from disk
        -- and notify the session of the deletion, which marks the node_modules
        -- bucket dirty.
        local nodeModulesDir = tspath.CombinePaths(proj:Root(), "node_modules")
        assert.is_nil(sessionUtils:FS():Remove(nodeModulesDir))
        session:DidChangeWatchedFiles(nil, {
            { type = lsproto.FileChangeType.Deleted, uri = lsconv.FileNameToDocumentURI(nodeModulesDir) },
        })

        -- Re-preparing auto-imports must succeed and leave the registry prepared.
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        snapshot = session:Snapshot()
        assert.is_true(snapshot:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, preferences),
            "registry should be prepared after node_modules is deleted")
        -- The node_modules bucket should be removed entirely, not left behind as an
        -- empty bucket.
        assert.are.equal(0, #autoImportStats(session).nodeModulesBuckets)
        session:Close()
    end)

    it("deleting node_modules alongside a package.json change removes the bucket", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local sessionUtils = fixture:Utils()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        local packageJSON = proj:PackageJSONFile()
        local preferences = defaultPreferences()

        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        local snapshot = session:Snapshot()
        local defaultProject = snapshot:GetDefaultProject(mainFile:URI())
        assert.is_not_nil(defaultProject)
        local projectPath = defaultProject:ConfigFilePath()
        assert.are.equal(1, #autoImportStats(session).nodeModulesBuckets)

        -- In a single changeset, edit package.json AND delete node_modules. The
        -- package.json change must not prevent the now-missing node_modules bucket
        -- from being removed.
        assert.is_nil(sessionUtils:FS():WriteFile(packageJSON:FileName(), [[{"name": "app", "dependencies": {}}]]))
        local nodeModulesDir = tspath.CombinePaths(proj:Root(), "node_modules")
        assert.is_nil(sessionUtils:FS():Remove(nodeModulesDir))
        session:DidChangeWatchedFiles(nil, {
            { type = lsproto.FileChangeType.Changed, uri = packageJSON:URI() },
            { type = lsproto.FileChangeType.Deleted, uri = lsconv.FileNameToDocumentURI(nodeModulesDir) },
        })

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        snapshot = session:Snapshot()
        assert.is_true(snapshot:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, preferences))
        assert.are.equal(0, #autoImportStats(session).nodeModulesBuckets)
        session:Close()
    end)

    it("deleting a package directory inside node_modules invalidates the bucket", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local sessionUtils = fixture:Utils()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)
        local nodePackage = proj:NodeModules()[1]

        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        assert.is_true(singleBucket(autoImportStats(session).nodeModulesBuckets).exportCount > 0)

        -- Delete just the package directory, leaving node_modules itself in place. The
        -- package's files are read transiently by the registry, so they are never tracked
        -- in diskFiles/diskDirectories; only the directory deletion event is reported, and
        -- it must survive snapshotfs filtering to invalidate the bucket.
        assert.is_nil(sessionUtils:FS():Remove(nodePackage.directory))
        session:DidChangeWatchedFiles(nil, {
            { type = lsproto.FileChangeType.Deleted, uri = lsconv.FileNameToDocumentURI(nodePackage.directory) },
        })

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))
        assert.are.equal(0, singleBucket(autoImportStats(session).nodeModulesBuckets).exportCount)
        session:Close()
    end)

    it("node_modules bucket dependency selection changes with open files", function()
        local monorepoRoot = "/home/src/monorepo"
        local packageADir = tspath.CombinePaths(monorepoRoot, "packages", "a")
        local monorepoIndex = tspath.CombinePaths(monorepoRoot, "index.js")
        local packageAIndex = tspath.CombinePaths(packageADir, "index.js")

        local fixture = autoimporttestutil.SetupMonorepoLifecycleSession(nil, {
            root = monorepoRoot,
            name = "monorepo",
            nodeModuleNames = { "pkg1", "pkg2", "pkg3" },
            dependencyNames = { "pkg1" },
            packages = {
                { fileCount = 0, name = "a", dependencyNames = { "pkg1", "pkg2" } },
            },
            extraFiles = {
                { path = monorepoIndex, content = "export const monorepoIndex = 1;\n" },
                { path = packageAIndex, content = "export const pkgA = 2;\n" },
            },
        })
        local session = fixture:Session()
        local monorepoHandle = fixture:ExtraFile(monorepoIndex)
        local packageAHandle = fixture:ExtraFile(packageAIndex)

        -- Open monorepo root file: expect dependencies restricted to pkg1
        session:DidOpenFile(nil, monorepoHandle:URI(), 1, monorepoHandle:Content(), JavaScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, monorepoHandle:URI()))
        local stats = autoImportStats(session)
        assert.is_true(singleBucket(stats.nodeModulesBuckets).dependencyNames:Equals(collections.NewSetFromItems("pkg1")))

        -- Open package-a file: pkg2 should be added to existing bucket
        session:DidOpenFile(nil, packageAHandle:URI(), 1, packageAHandle:Content(), JavaScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, packageAHandle:URI()))
        stats = autoImportStats(session)
        assert.is_true(singleBucket(stats.nodeModulesBuckets).dependencyNames:Equals(collections.NewSetFromItems("pkg1", "pkg2")))

        -- Close package-a file; only monorepo bucket should remain
        session:DidCloseFile(nil, packageAHandle:URI())
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, monorepoHandle:URI()))
        stats = autoImportStats(session)
        assert.is_true(singleBucket(stats.nodeModulesBuckets).dependencyNames:Equals(collections.NewSetFromItems("pkg1")))

        -- Close monorepo file; no node_modules buckets should remain
        session:DidCloseFile(nil, monorepoHandle:URI())
        session:DidOpenFile(nil, "untitled:Untitled-1", 0, "", TypeScript)
        noError(session:GetLanguageService(nil, "untitled:Untitled-1"))
        stats = autoImportStats(session)
        assert.are.equal(0, #stats.nodeModulesBuckets)
        session:Close()
    end)

    it("node_modules bucket includes resolved packages from all projects", function()
        -- This test verifies that when multiple projects share a node_modules directory,
        -- the node_modules bucket includes resolved package names from ALL projects,
        -- not just the currently requested file's project.
        local monorepoRoot = "/home/src/cross-project-deps"
        local packageADir = tspath.CombinePaths(monorepoRoot, "packages", "a")
        local packageBDir = tspath.CombinePaths(monorepoRoot, "packages", "b")
        local packageAIndex = tspath.CombinePaths(packageADir, "index.ts")
        local packageBIndex = tspath.CombinePaths(packageBDir, "index.ts")

        local fixture = autoimporttestutil.SetupMonorepoLifecycleSession(nil, {
            root = monorepoRoot,
            name = "monorepo",
            -- Both pkg-listed and pkg-unlisted exist in node_modules
            nodeModuleNames = { "pkg-listed", "pkg-unlisted" },
            -- But only pkg-listed is in the root package.json dependencies
            dependencyNames = { "pkg-listed" },
            packages = {
                -- package-a only lists pkg-listed in its package.json
                { fileCount = 0, name = "a", dependencyNames = { "pkg-listed" } },
                -- package-b also only lists pkg-listed in its package.json
                { fileCount = 0, name = "b", dependencyNames = { "pkg-listed" } },
            },
            extraFiles = {
                -- project-a directly imports pkg-unlisted (not in package.json)
                { path = packageAIndex, content = "import { pkg_unlisted_value } from \"pkg-unlisted\";\nexport const a = pkg_unlisted_value;\n" },
                -- project-b does not import pkg-unlisted
                { path = packageBIndex, content = "export const b = 1;\n" },
            },
        })
        local session = fixture:Session()
        local packageAHandle = fixture:ExtraFile(packageAIndex)
        local packageBHandle = fixture:ExtraFile(packageBIndex)

        -- Open file in project-a (which imports pkg-unlisted)
        session:DidOpenFile(nil, packageAHandle:URI(), 1, packageAHandle:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, packageAHandle:URI()))

        -- Open file in project-b (which does not import pkg-unlisted)
        session:DidOpenFile(nil, packageBHandle:URI(), 1, packageBHandle:Content(), TypeScript)
        -- Request auto-imports for project-b
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, packageBHandle:URI()))

        local stats = autoImportStats(session)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.is_true(nodeModulesBucket.dependencyNames:Has("pkg-listed"), "pkg-listed should be in dependencies")
        assert.is_true(nodeModulesBucket.dependencyNames:Has("pkg-unlisted"), "pkg-unlisted should be in dependencies because project-a imports it")
        session:Close()
    end)

    it("symlinked monorepo invalidates on source file change", function()
        local monorepoRoot = "/home/src/symlinked-monorepo-invalidation"
        local projectADir = tspath.CombinePaths(monorepoRoot, "packages", "project-a")
        local projectBDir = tspath.CombinePaths(monorepoRoot, "packages", "project-b")
        local projectAIndex = tspath.CombinePaths(projectADir, "src", "index.ts")
        local projectBSrcIndex = tspath.CombinePaths(projectBDir, "src", "index.ts")
        local projectBDistIndex = tspath.CombinePaths(projectBDir, "dist", "index.d.ts")
        local otherPkgDir = tspath.CombinePaths(projectADir, "node_modules", "other-pkg")

        local files = {
            -- project-b: the library package
            [tspath.CombinePaths(projectBDir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"composite": true,
					"outDir": "./dist",
					"rootDir": "./src",
					"declaration": true,
					"module": "esnext",
					"strict": true
				},
				"include": ["src"]
			}]],
            [tspath.CombinePaths(projectBDir, "package.json")] = [[{
				"name": "project-b",
				"version": "1.0.0",
				"main": "dist/index.js",
				"types": "dist/index.d.ts"
			}]],
            [projectBSrcIndex] = "export function projectBFunction(): string { return \"hello\"; }\nexport const projectBValue: number = 42;",
            [projectBDistIndex] = "export declare function projectBFunction(): string;\nexport declare const projectBValue: number;",
            -- other-pkg: a regular (non-symlinked) package
            [tspath.CombinePaths(otherPkgDir, "package.json")] = [[{
				"name": "other-pkg",
				"version": "1.0.0",
				"main": "index.js",
				"types": "index.d.ts"
			}]],
            [tspath.CombinePaths(otherPkgDir, "index.d.ts")] = "export declare function otherFunction(): void;\nexport declare const otherValue: string;",
            -- project-a: the consumer package
            [tspath.CombinePaths(projectADir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"strict": true,
					"outDir": "./dist",
					"rootDir": "./src"
				},
				"include": ["src"],
				"references": [{ "path": "../project-b" }]
			}]],
            [tspath.CombinePaths(projectADir, "package.json")] = [[{
				"name": "project-a",
				"dependencies": { "project-b": "*", "other-pkg": "*" }
			}]],
            [projectAIndex] = "console.log(\"hello\");\n",
            -- Symlink: project-b is accessible via node_modules
            [tspath.CombinePaths(projectADir, "node_modules", "project-b")] = vfstest.Symlink(projectBDir),
        }

        local session = projecttestutil.Setup(files)

        -- Open project-a's index file and get initial auto-imports
        local projectAURI = lsconv.FileNameToDocumentURI(projectAIndex)
        session:DidOpenFile(nil, projectAURI, 1, files[projectAIndex], TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, projectAURI))

        -- Verify initial state: bucket is clean with files
        local stats = autoImportStats(session)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        local initialFileCount = nodeModulesBucket.fileCount
        assert.are.equal(false, nodeModulesBucket.state:Dirty(), "bucket should be clean initially")
        assert.is_true(initialFileCount > 0, "bucket should have files initially")

        -- Open project-b's source file
        local projectBURI = lsconv.FileNameToDocumentURI(projectBSrcIndex)
        session:DidOpenFile(nil, projectBURI, 1, files[projectBSrcIndex], TypeScript)

        -- Modify the file (delete one export)
        session:DidChangeFile(nil, projectBURI, 2, wholeDocument("export const projectBValue: number = 42;"))

        -- Check that the node_modules bucket is now dirty
        noError(session:GetLanguageService(nil, projectAURI))
        stats = autoImportStats(session)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(true, nodeModulesBucket.state:Dirty(), "bucket should be dirty after source file change")

        -- Verify that only project-b is marked for update, not other-pkg.
        local dirtyPackages = nodeModulesBucket.state:DirtyPackages()
        assert.is_not_nil(dirtyPackages, "dirty packages should be tracked")
        assert.is_true(dirtyPackages:Has("project-b"), "project-b should be in dirty packages")
        assert.is_false(dirtyPackages:Has("other-pkg"), "other-pkg should NOT be in dirty packages")
        assert.are.equal(1, dirtyPackages:Len(), "only one package should be dirty")

        -- Rebuild by requesting auto-imports again.
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, projectAURI))

        -- Verify bucket is clean again after rebuild
        stats = autoImportStats(session)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, nodeModulesBucket.state:Dirty(), "bucket should be clean after rebuild")
        session:Close()
    end)

    it("pnpm-style symlinks only grant granular updates to workspace packages", function()
        local monorepoRoot = "/home/src/pnpm-monorepo"
        local projectADir = tspath.CombinePaths(monorepoRoot, "packages", "project-a")
        local projectBDir = tspath.CombinePaths(monorepoRoot, "packages", "project-b")
        local projectAIndex = tspath.CombinePaths(projectADir, "src", "index.ts")
        local projectBSrcIndex = tspath.CombinePaths(projectBDir, "src", "index.ts")
        local projectBDistIndex = tspath.CombinePaths(projectBDir, "dist", "index.d.ts")
        -- Simulated pnpm virtual store for a registry package (inside project-a's node_modules).
        local pnpmStoreDir = tspath.CombinePaths(projectADir, "node_modules", ".pnpm-store", "other-pkg@1.0.0")
        local otherPkgIndex = tspath.CombinePaths(pnpmStoreDir, "index.d.ts")

        local files = {
            -- project-b: a local workspace package
            [tspath.CombinePaths(projectBDir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"composite": true,
					"outDir": "./dist",
					"rootDir": "./src",
					"declaration": true,
					"module": "esnext",
					"strict": true
				},
				"include": ["src"]
			}]],
            [tspath.CombinePaths(projectBDir, "package.json")] = [[{
				"name": "project-b",
				"version": "1.0.0",
				"main": "dist/index.js",
				"types": "dist/index.d.ts"
			}]],
            [projectBSrcIndex] = "export function projectBFunction(): string { return \"hello\"; }\nexport const projectBValue: number = 42;",
            [projectBDistIndex] = "export declare function projectBFunction(): string;\nexport declare const projectBValue: number;",
            -- other-pkg: a registry package in pnpm's virtual store
            [tspath.CombinePaths(pnpmStoreDir, "package.json")] = [[{
				"name": "other-pkg",
				"version": "1.0.0",
				"main": "index.js",
				"types": "index.d.ts"
			}]],
            [otherPkgIndex] = "export declare function otherFunction(): void;\nexport declare const otherValue: string;",
            -- project-a: the consumer package
            [tspath.CombinePaths(projectADir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"strict": true,
					"outDir": "./dist",
					"rootDir": "./src"
				},
				"include": ["src"],
				"references": [{ "path": "../project-b" }]
			}]],
            [tspath.CombinePaths(projectADir, "package.json")] = [[{
				"name": "project-a",
				"dependencies": { "project-b": "*", "other-pkg": "*" }
			}]],
            [projectAIndex] = "console.log(\"hello\");\n",
            -- Symlink: local workspace package (realpath outside node_modules)
            [tspath.CombinePaths(projectADir, "node_modules", "project-b")] = vfstest.Symlink(projectBDir),
            -- Symlink: pnpm-style registry package (realpath inside node_modules/.pnpm)
            [tspath.CombinePaths(projectADir, "node_modules", "other-pkg")] = vfstest.Symlink(pnpmStoreDir),
        }

        local session = projecttestutil.SetupWithOptions(files, project.NewSessionOptions({
            currentDirectory = monorepoRoot,
            defaultLibraryPath = bundled.LibPath(),
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = true,
            loggingEnabled = true,
            pushDiagnosticsEnabled = true,
        }))

        -- Open project-a's index file and build auto-imports
        local projectAURI = lsconv.FileNameToDocumentURI(projectAIndex)
        session:DidOpenFile(nil, projectAURI, 1, files[projectAIndex], TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, projectAURI))

        -- Verify initial state: bucket is clean
        local stats = autoImportStats(session)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, nodeModulesBucket.state:Dirty(), "bucket should be clean initially")

        -- Modify project-b's source file (local workspace package)
        local projectBURI = lsconv.FileNameToDocumentURI(projectBSrcIndex)
        session:DidOpenFile(nil, projectBURI, 1, files[projectBSrcIndex], TypeScript)
        session:DidChangeFile(nil, projectBURI, 2, wholeDocument("export const projectBValue: number = 42;"))

        -- project-b should get a granular update (tracked in dirtyPackages)
        noError(session:GetLanguageService(nil, projectAURI))
        stats = autoImportStats(session)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(true, nodeModulesBucket.state:Dirty(), "bucket should be dirty after workspace package change")
        local dirtyPackages = nodeModulesBucket.state:DirtyPackages()
        assert.is_not_nil(dirtyPackages, "dirty packages should be tracked for workspace package")
        assert.is_true(dirtyPackages:Has("project-b"), "project-b should be in dirty packages")
        assert.are.equal(1, dirtyPackages:Len(), "only project-b should be dirty")

        -- Rebuild to clear dirty state
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, projectAURI))
        stats = autoImportStats(session)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, nodeModulesBucket.state:Dirty(), "bucket should be clean after rebuild")

        -- Now modify other-pkg (pnpm registry package, realpath inside node_modules/.pnpm)
        local otherPkgURI = lsconv.FileNameToDocumentURI(otherPkgIndex)
        session:DidOpenFile(nil, otherPkgURI, 1, files[otherPkgIndex], TypeScript)
        session:DidChangeFile(nil, otherPkgURI, 2, wholeDocument("export declare function otherFunction(): void;"))

        -- other-pkg should trigger a full rebuild (multipleFilesDirty), not a granular update.
        local _, err = session:WithLanguageServiceAndSnapshot(nil, projectAURI, function(_, snapshot)
            stats = snapshot:AutoImportRegistry():GetCacheStats()
            return nil, nil
        end)
        assert.is_nil(err)
        nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(true, nodeModulesBucket.state:Dirty(), "bucket should be dirty after registry package change")
        dirtyPackages = nodeModulesBucket.state:DirtyPackages()
        -- A full rebuild means dirtyPackages is nil (multipleFilesDirty takes precedence)
        -- or dirtyPackages doesn't contain "other-pkg" as a granular entry
        if dirtyPackages ~= nil then
            assert.is_false(dirtyPackages:Has("other-pkg"), "other-pkg should NOT be in dirty packages (should trigger full rebuild)")
        end
        session:Close()
    end)

    it("circular workspace symlinks do not exclude local project files", function()
        local monorepoRoot = "/home/src/circular-workspaces"
        local packageADir = tspath.CombinePaths(monorepoRoot, "packages", "pkg-a")
        local packageBDir = tspath.CombinePaths(monorepoRoot, "packages", "pkg-b")
        local consumerA = tspath.CombinePaths(packageADir, "consumer.ts")
        local helperA = tspath.CombinePaths(packageADir, "helper.ts")

        local files = {
            [tspath.CombinePaths(packageADir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"strict": true
				}
			}]],
            [tspath.CombinePaths(packageADir, "package.json")] = [[{
				"name": "pkg-a",
				"dependencies": { "pkg-b": "*" }
			}]],
            [tspath.CombinePaths(packageADir, "index.ts")] = "import { b } from \"pkg-b\";\nexport const a = b;\n",
            [consumerA] = "export const usesHelper = uniqueHelperValueFromHelperA;\n",
            [helperA] = "export const uniqueHelperValueFromHelperA = 1;\n",
            [tspath.CombinePaths(packageBDir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"strict": true
				}
			}]],
            [tspath.CombinePaths(packageBDir, "package.json")] = [[{
				"name": "pkg-b",
				"dependencies": { "pkg-a": "*" }
			}]],
            [tspath.CombinePaths(packageBDir, "index.ts")] = "import { a } from \"pkg-a\";\nexport const b = a;\n",
            -- Circular workspace links
            [tspath.CombinePaths(packageADir, "node_modules", "pkg-b")] = vfstest.Symlink(packageBDir),
            [tspath.CombinePaths(packageBDir, "node_modules", "pkg-a")] = vfstest.Symlink(packageADir),
        }

        local session = projecttestutil.Setup(files)
        local consumerAURI = lsconv.FileNameToDocumentURI(consumerA)
        session:DidOpenFile(nil, consumerAURI, 1, files[consumerA], TypeScript)

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, consumerAURI))

        local stats = autoImportStats(session)
        local projectBucket = singleBucket(stats.projectBuckets)
        assert.are.equal(3, projectBucket.fileCount, "expected all pkg-a project files despite circular workspace symlinks")
        session:Close()
    end)

    it("changed fileExcludePatterns triggers bucket rebuild", function()
        local fixture = autoimporttestutil.SetupLifecycleSession(nil, lifecycleProjectRoot, 1)
        local session = fixture:Session()
        local proj = fixture:SingleProject()
        local mainFile = proj:File(0)

        -- Open file and build auto-imports initially
        session:DidOpenFile(nil, mainFile:URI(), 1, mainFile:Content(), TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        -- Verify buckets are clean after initial build
        local stats = autoImportStats(session)
        local projectBucket = singleBucket(stats.projectBuckets)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)
        assert.are.equal(false, projectBucket.state:Dirty())
        assert.are.equal(false, nodeModulesBucket.state:Dirty())

        -- IsPreparedForImportingFile should return true with no exclude patterns
        local snapshot = session:Snapshot()
        local defaultProject = snapshot:GetDefaultProject(mainFile:URI())
        assert.is_not_nil(defaultProject)
        local projectPath = defaultProject:ConfigFilePath()
        local preferences = defaultPreferences()
        assert.is_true(snapshot:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, preferences))

        -- Change the file exclude patterns preference
        local newPreferences = defaultPreferences()
        newPreferences.autoImportFileExcludePatterns = { "**/node_modules/**/*.d.ts" }
        session:Configure(newPreferences)

        -- IsPreparedForImportingFile should return false since exclude patterns changed
        local snapshot2 = session:Snapshot()
        assert.is_false(snapshot2:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, newPreferences))

        -- After GetCurrentLanguageServiceWithAutoImports, buckets should be rebuilt
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainFile:URI()))

        -- IsPreparedForImportingFile should return true now that buckets are rebuilt
        local snapshot3 = session:Snapshot()
        assert.is_true(snapshot3:AutoImportRegistry():IsPreparedForImportingFile(mainFile:FileName(), projectPath, newPreferences),
            "IsPreparedForImportingFile should return true after bucket rebuild with new fileExcludePatterns")
        session:Close()
    end)

    it("dedupes packages that resolve to same realpath across ancestor node_modules buckets", function()
        local repoRoot = "/home/src/autoimport-realpath-dedupe"
        local appDir = tspath.CombinePaths(repoRoot, "apps", "web")
        local sharedPkgDir = tspath.CombinePaths(repoRoot, "node_modules", "shared")
        local appIndex = tspath.CombinePaths(appDir, "src", "index.ts")

        local files = {
            [tspath.CombinePaths(repoRoot, "package.json")] = [[{
				"name": "repo-root",
				"private": true,
				"dependencies": { "shared": "*" }
			}]],
            [tspath.CombinePaths(repoRoot, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"target": "esnext",
					"strict": true
				},
				"include": ["apps/**/*"]
			}]],
            [tspath.CombinePaths(appDir, "package.json")] = [[{
				"name": "web",
				"private": true,
				"dependencies": { "shared": "*" }
			}]],
            [tspath.CombinePaths(appDir, "tsconfig.json")] = [[{
				"compilerOptions": {
					"module": "esnext",
					"target": "esnext",
					"strict": true
				},
				"include": ["src"]
			}]],
            [appIndex] = "export const app = 1;\n",
            [tspath.CombinePaths(sharedPkgDir, "package.json")] = [[{
				"name": "shared",
				"version": "1.0.0",
				"types": "index.d.ts"
			}]],
            [tspath.CombinePaths(sharedPkgDir, "index.d.ts")] = "export declare const sharedValue: 1;\n",
            [tspath.CombinePaths(appDir, "node_modules", "shared")] = vfstest.Symlink(sharedPkgDir),
        }

        local session = projecttestutil.Setup(files)

        local appURI = lsconv.FileNameToDocumentURI(appIndex)
        session:DidOpenFile(nil, appURI, 1, files[appIndex], TypeScript)

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, appURI))

        local stats = autoImportStats(session)
        assert.are.equal(2, #stats.nodeModulesBuckets, "expected both app and repo node_modules buckets")
        assert.are.equal(1, stats.uniquePackageCount, "expected one unique package after realpath dedup")
        session:Close()
    end)

    it("content-mapped node_modules file uses the project bucket", function()
        -- Blocked on content mapper support in tslua.project/tsoptions
        -- (project.collectConfiguredContentMappers: mapper.definition is nil).
        if os.getenv("TSLUA_CONTENT_MAPPER_TESTS") == nil then
            pending("content mapper configuration not supported yet")
            return
        end
        local contentmappertest = require("tslua.testutil.contentmappertest")
        local files = {
            ["/home/project/tsconfig.json"] = [[{
			"compilerOptions": { "module": "esnext", "moduleResolution": "bundler", "strict": true, "skipLibCheck": true },
			"contentMappers": [ { "package": "mapper", "extensions": [".vue"] } ]
		}]],
            ["/home/project/node_modules/mapper/package.json"] = contentmappertest.PackageJSON(contentmappertest.ComponentMapper),
            ["/home/project/node_modules/profile-package/ProfileCard.vue"] = "<component name=\"ProfileCard\">\n<script lang=\"ts\">\nexport const profileTitle = \"Profile\";\n</script>",
            ["/home/project/node_modules/profile-package/HiddenCard.vue"] = "<component name=\"HiddenCard\">\n<script lang=\"ts\">\nexport const hiddenTitle = \"Hidden\";\n</script>",
            ["/home/project/node_modules/profile-package/ordinary.ts"] = "export const ordinary = true;",
            ["/home/project/load.ts"] = "import \"profile-package/ProfileCard.vue\";\nimport \"profile-package/ordinary\";",
            ["/home/project/main.ts"] = "profileTitle;",
        }
        local init = projecttestutil.GetSessionInitOptions(files, project.NewSessionOptions({
            currentDirectory = "/home/project",
            defaultLibraryPath = bundled.LibPath(),
            typingsLocation = projecttestutil.TestTypingsLocation,
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            runExternalCode = true,
        }), nil)
        init.spawner = contentmappertest.NewSpawner()
        local session = project.NewSession(init)

        local mainURI = "file:///home/project/main.ts"
        session:DidOpenFile(nil, mainURI, 1, files["/home/project/main.ts"], TypeScript)
        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, mainURI))
        session:WaitForBackgroundTasks()

        local projectBucket = singleBucket(autoImportStats(session).projectBuckets)
        assert.are.equal(3, projectBucket.fileCount, "expected the two project roots and referenced mapped package file")
        session:Close()
    end)

    it("hidden directories in node_modules: deep import through subdirectory package.json in hidden store", function()
        -- See https://github.com/microsoft/typescript-go/issues/2780
        local projectRoot = "/home/src/fuse-project"
        local storeDir = projectRoot .. "/node_modules/.yarn-store"
        local pkgStoreDir = storeDir .. "/some-pkg-npm-1.0.0-abc123/package"

        local files = {
            [projectRoot .. "/tsconfig.json"] = [[{
				"compilerOptions": {
					"module": "commonjs",
					"target": "es2020",
					"strict": true
				}
			}]],
            [projectRoot .. "/package.json"] = [[{
				"name": "test-project",
				"dependencies": {
					"some-pkg": "*",
					"real-package": "*"
				}
			}]],
            -- Deep import: "some-pkg/debug" — resolves through the subdirectory package.json
            [projectRoot .. "/index.ts"] = [[import { debug } from "some-pkg/debug";]],

            -- Real package that should be indexed normally
            [projectRoot .. "/node_modules/real-package/package.json"] = [[{"name":"real-package","version":"1.0.0","types":"index.d.ts"}]],
            [projectRoot .. "/node_modules/real-package/index.d.ts"] = "export declare const realExport: number;\n",

            -- Symlink: node_modules/some-pkg -> .yarn-store/.../package/
            [projectRoot .. "/node_modules/some-pkg"] = vfstest.Symlink(pkgStoreDir),

            -- Root package.json with name+version but NO "exports" field.
            [pkgStoreDir .. "/package.json"] = [[{"name":"some-pkg","version":"1.0.0","types":"index.d.ts"}]],
            [pkgStoreDir .. "/index.d.ts"] = "export declare const something: number;\n",
            -- Subdirectory package.json for the deep import — no name or version.
            [pkgStoreDir .. "/debug/package.json"] = [[{"main":"./debug.js","types":"./debug.d.ts"}]],
            [pkgStoreDir .. "/debug/debug.d.ts"] = "export declare function debug(msg: string): void;\n",
            [pkgStoreDir .. "/debug/debug.js"] = "exports.debug = function(msg) { console.log(msg); };\n",

            -- Other content in the hidden store that should never be crawled
            [storeDir .. "/other-pkg-npm-2.0.0-def456/package/package.json"] = [[{"name":"other-pkg","version":"1.0.0","types":"index.d.ts"}]],
            [storeDir .. "/other-pkg-npm-2.0.0-def456/package/index.d.ts"] = "export declare const other: string;\n",
        }

        local session = projecttestutil.Setup(files)
        local indexURI = "file://" .. projectRoot .. "/index.ts"
        session:DidOpenFile(nil, indexURI, 1, files[projectRoot .. "/index.ts"], TypeScript)

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))

        local stats = autoImportStats(session)
        local nodeModulesBucket = singleBucket(stats.nodeModulesBuckets)

        -- .yarn-store must not appear as a dependency name.
        assert.is_not_nil(nodeModulesBucket.dependencyNames, "DependencyNames should not be nil")
        for name in pairs(nodeModulesBucket.dependencyNames:Keys() or {}) do
            assert.is_true(string.byte(name, 1) ~= 0x2E, string.format("hidden directory %q should not appear as a dependency name", name))
        end
        session:Close()
    end)

    describe("autoImportEntrypointDirectorySearch", function()
        local projectRoot = "/home/src/entrypoint-search"
        local nodeModulesDir = projectRoot .. "/node_modules"
        local pkgDir = nodeModulesDir .. "/my-pkg"

        local files = {
            [projectRoot .. "/tsconfig.json"] = [[{
			"compilerOptions": {
				"module": "commonjs",
				"target": "es2020"
			}
		}]],
            [projectRoot .. "/package.json"] = [[{
			"name": "test-project",
			"dependencies": { "my-pkg": "*" }
		}]],
            [projectRoot .. "/index.ts"] = [[import { main } from "my-pkg";]],
            -- Package with NO "exports" field and multiple files.
            [pkgDir .. "/package.json"] = [[{"name":"my-pkg","version":"1.0.0","types":"index.d.ts"}]],
            [pkgDir .. "/index.d.ts"] = "export declare const main: number;\n",
            [pkgDir .. "/extra.d.ts"] = "export declare const extra: string;\n",
            [pkgDir .. "/nested/deep.d.ts"] = "export declare const deep: boolean;\n",
            [pkgDir .. "/nested/deeper.d.ts"] = "export declare const deeper: boolean;\n",
        }
        local indexURI = "file://" .. projectRoot .. "/index.ts"

        it("default limits to main entrypoint", function()
            local session = projecttestutil.Setup(files)
            session:DidOpenFile(nil, indexURI, 1, files[projectRoot .. "/index.ts"], TypeScript)
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            local nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            -- Without the preference, only the main entrypoint (index.d.ts) should be found
            assert.are.equal(1, nodeModulesBucket.fileCount, "expected only 1 file (main entrypoint) by default")
            session:Close()
        end)

        it("autoImportEntrypointDirectorySearch enables all files", function()
            local session = projecttestutil.Setup(files)
            local prefs = lsutil.NewDefaultUserPreferences()
            prefs.autoImportEntrypointDirectorySearch = core.Tristate.TSTrue
            session:Configure(prefs)
            session:DidOpenFile(nil, indexURI, 1, files[projectRoot .. "/index.ts"], TypeScript)
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            local nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            -- With the preference, all 4 .d.ts files should be found via directory search
            assert.is_true(nodeModulesBucket.fileCount >= 4, string.format("expected at least 4 files from directory search, got %d", nodeModulesBucket.fileCount))
            session:Close()
        end)

        it("changing preference triggers rebuild", function()
            local session = projecttestutil.Setup(files)
            session:DidOpenFile(nil, indexURI, 1, files[projectRoot .. "/index.ts"], TypeScript)

            -- Build auto-imports with default preferences (directory search disabled)
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            local nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            assert.are.equal(1, nodeModulesBucket.fileCount, "expected only 1 file initially")

            -- Now enable directory search
            local prefs = lsutil.NewDefaultUserPreferences()
            prefs.autoImportEntrypointDirectorySearch = core.Tristate.TSTrue
            session:Configure(prefs)

            -- Registry should report not prepared (preference changed)
            local snapshot = session:Snapshot()
            local defaultProject = snapshot:GetDefaultProject(indexURI)
            assert.is_not_nil(defaultProject)
            local projectPath = defaultProject:ConfigFilePath()
            assert.is_false(snapshot:AutoImportRegistry():IsPreparedForImportingFile(projectRoot .. "/index.ts", projectPath, prefs),
                "registry should not be prepared after preference change")

            -- Rebuild
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            assert.is_true(nodeModulesBucket.fileCount >= 4, string.format("expected at least 4 files after rebuild with directory search enabled, got %d", nodeModulesBucket.fileCount))
            session:Close()
        end)

        it("deep import from program update enables recursive search for that package", function()
            local session = projecttestutil.Setup(files)
            session:DidOpenFile(nil, indexURI, 1, files[projectRoot .. "/index.ts"], TypeScript)

            -- Initial build with top-level import only ("my-pkg", not a deep import)
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            local nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            assert.are.equal(1, nodeModulesBucket.fileCount, "expected only 1 file (main entrypoint) before deep import")

            -- Now update the program to add a deep import from the same package
            local newContent = "import { main } from \"my-pkg\";\nimport { deep } from \"my-pkg/nested/deep\";\n"
            session:DidChangeFile(nil, indexURI, 2, wholeDocument(newContent))

            -- After the program update, auto-imports should detect the deep import and
            -- enable recursive directory search for my-pkg, finding all .d.ts files.
            noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))
            nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
            assert.is_true(nodeModulesBucket.fileCount >= 4, string.format("expected at least 4 files after deep import triggers recursive search, got %d", nodeModulesBucket.fileCount))
            session:Close()
        end)
    end)

    it("updateIndexes: @types fallback for many packages", function()
        local projectRoot = "/home/src/autoimport-fallback-race"
        local packageCount = 40

        local files = {
            [projectRoot .. "/tsconfig.json"] = [[{
			"compilerOptions": { "module": "esnext", "target": "esnext", "strict": true }
		}]],
            [projectRoot .. "/index.ts"] = "export {};\n",
        }
        for i = 0, packageCount - 1 do
            local dir = string.format("%s/node_modules/pkg%d", projectRoot, i)
            files[dir .. "/package.json"] = string.format([[{"name":"pkg%d","version":"1.0.0","main":"index.js"}]], i)
            files[dir .. "/index.js"] = "module.exports = {};\n"
            local typesDir = string.format("%s/node_modules/@types/pkg%d", projectRoot, i)
            files[typesDir .. "/package.json"] = string.format([[{"name":"@types/pkg%d","version":"1.0.0","types":"index.d.ts"}]], i)
            files[typesDir .. "/index.d.ts"] = string.format("export declare const foo%d: number;\n", i)
        end

        local session = projecttestutil.Setup(files)
        local indexURI = "file://" .. projectRoot .. "/index.ts"
        session:DidOpenFile(nil, indexURI, 1, "export {};\n", TypeScript)

        noError(session:GetCurrentLanguageServiceWithAutoImports(nil, indexURI))

        local nodeModulesBucket = singleBucket(autoImportStats(session).nodeModulesBuckets)
        assert.are.equal(packageCount, nodeModulesBucket.exportCount)
        session:Close()
    end)
end)
