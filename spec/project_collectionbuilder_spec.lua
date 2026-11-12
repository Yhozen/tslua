-- Ported from internal/project/projectcollectionbuilder_test.go (solution/reference cases) and
-- internal/project/configfilechanges_test.go. "noLib": true is added to the configured projects
-- since the library is irrelevant to these tests and slow to load in the Lua port.
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local projecttestutil = require("tslua.testutil.projecttestutil")

local TS = lsproto.LanguageKind.TypeScript
local root = "/user/username/projects/myproject/"

local function filesForSolutionConfigFile(solutionRefs, compilerOptions, ownFiles)
    local refs = {}
    for i, ref in ipairs(solutionRefs) do
        refs[i] = '{ "path": "' .. ref .. '" }'
    end
    local opts = '"noLib": true'
    if compilerOptions ~= "" then
        opts = opts .. ", " .. compilerOptions
    end
    return {
        [root .. "tsconfig.json"] = '{\n "compilerOptions": { ' .. opts .. ' },\n "files": [' .. table.concat(ownFiles or {}, ",") ..
            '],\n "references": [\n ' .. table.concat(refs, ",") .. '\n ]\n }',
        [root .. "tsconfig-src.json"] = '{\n "compilerOptions": {\n "composite": true,\n "noLib": true,\n "outDir": "./target",\n },\n "include": ["./src/**/*"]\n }',
        [root .. "src/main.ts"] = "\n import { foo } from './helpers/functions';\n export { foo };",
        [root .. "src/helpers/functions.ts"] = "export const foo = 1;",
    }
end

local function applyIndirectProjectFiles(files, projectIndex, compilerOptions)
    local opts = '"composite": true, "noLib": true, "outDir": "./target/"'
    if compilerOptions ~= "" then
        opts = opts .. ", " .. compilerOptions
    end
    files[root .. "tsconfig-indirect" .. projectIndex .. ".json"] = '{\n "compilerOptions": { ' .. opts ..
        ' },\n "files": [\n "./indirect' .. projectIndex .. '/main.ts"\n ],\n "references": [\n { "path": "./tsconfig-src.json" }\n ]\n }'
    files[root .. "indirect" .. projectIndex .. "/main.ts"] = "export const indirect = 1;"
end

local uri = "file://" .. root .. "src/main.ts"
local dummyUri = "file:///user/username/workspaces/dummy/dummy.ts"

local function config(snapshot, name)
    return snapshot.configFileRegistry:GetConfig(root .. name)
end

-- closeAndOpenDummy closes the file and opens one in an inferred project, then checks that the
-- given configs were released.
local function closeAndOpenDummy(session, released)
    session:DidCloseFile(nil, uri)
    session:DidOpenFile(nil, dummyUri, 1, "const x = 1;", TS)
    local snapshot = session:Snapshot()
    assert.are.equal(1, #snapshot.projectCollection:Projects())
    assert.is_not_nil(snapshot.projectCollection:InferredProject())
    for _, name in ipairs(released) do
        assert.is_nil(config(snapshot, name), name .. " should be released")
    end
end

describe("project.ProjectCollectionBuilder", function()
    it("when project found is solution referencing default project directly", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-src.json" }, "", nil)
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json"))

        -- Ensure request can use existing snapshot
        local _, err = session:GetLanguageService(nil, uri)
        assert.is_nil(err)
        assert.are.equal(snapshot, session:Snapshot())

        -- Searched configs should be present while file is open
        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json" })
    end)

    it("when project found is solution referencing default project indirectly", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-indirect1.json", "./tsconfig-indirect2.json" }, "", nil)
        applyIndirectProjectFiles(files, 1, "")
        applyIndirectProjectFiles(files, 2, "")
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        local srcProject = snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json")
        assert.is_not_nil(srcProject)
        assert.are.equal(srcProject, snapshot:GetDefaultProject(uri))

        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-indirect1.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json", "tsconfig-indirect1.json", "tsconfig-indirect2.json" })
    end)

    it("when project found is solution with disableReferencedProjectLoad referencing default project directly", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-src.json" }, '"disableReferencedProjectLoad": true', nil)
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        assert.is_nil(snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json"))

        -- Should use inferred project instead
        local defaultProject = snapshot:GetDefaultProject(uri)
        assert.is_not_nil(defaultProject)
        assert.are.equal(project.Kind.Inferred, defaultProject.kind)

        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json" })
    end)

    it("when project found is solution referencing default project indirectly through disableReferencedProjectLoad", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-indirect1.json" }, "", nil)
        applyIndirectProjectFiles(files, 1, '"disableReferencedProjectLoad": true')
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        assert.is_nil(snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json"))
        assert.are.equal(project.Kind.Inferred, snapshot:GetDefaultProject(uri).kind)

        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-indirect1.json"))
        assert.is_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json", "tsconfig-indirect1.json" })
    end)

    it("when project found is solution referencing default project indirectly through disableReferencedProjectLoad in one but without it in another", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-indirect1.json", "./tsconfig-indirect2.json" }, "", nil)
        applyIndirectProjectFiles(files, 1, '"disableReferencedProjectLoad": true')
        applyIndirectProjectFiles(files, 2, "")
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        local srcProject = snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json")
        assert.is_not_nil(srcProject)
        assert.are.equal(srcProject, snapshot:GetDefaultProject(uri))

        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-indirect1.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-indirect2.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json", "tsconfig-indirect1.json", "tsconfig-indirect2.json" })
    end)

    it("when project found is project with own files referencing the file from referenced project", function()
        local files = filesForSolutionConfigFile({ "./tsconfig-src.json" }, "", { '"./own/main.ts"' })
        files[root .. "own/main.ts"] = "\n import { foo } from '../src/main';\n foo;\n export function bar() {}\n "
        local session = projecttestutil.Setup(files)

        session:DidOpenFile(nil, uri, 1, files[root .. "src/main.ts"], TS)
        local snapshot = session:Snapshot()
        assert.are.equal(2, #snapshot.projectCollection:Projects())
        local srcProject = snapshot.projectCollection:ConfiguredProject(root .. "tsconfig-src.json")
        assert.is_not_nil(srcProject)
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject(root .. "tsconfig.json"))
        assert.are.equal(srcProject, snapshot:GetDefaultProject(uri))

        assert.is_not_nil(config(snapshot, "tsconfig.json"))
        assert.is_not_nil(config(snapshot, "tsconfig-src.json"))

        closeAndOpenDummy(session, { "tsconfig.json", "tsconfig-src.json" })
    end)
end)

describe("project config file changes", function()
    local files = {
        ["/tsconfig.more-base.json"] = "{}",
        ["/tsconfig.base.json"] = '{"extends": "../tsconfig.more-base.json", "compilerOptions": {"strict": true}}',
        ["/src/tsconfig.json"] = '{"extends": "../tsconfig.base.json", "compilerOptions": {"target": "es6", "noLib": true}, "references": [{"path": "../utils"}]}',
        ["/src/index.ts"] = 'console.log("Hello, world!");',
        ["/src/subfolder/foo.ts"] = 'export const foo = "bar";',
        ["/utils/tsconfig.json"] = '{"compilerOptions": {"composite": true, "noLib": true}}',
        ["/utils/index.ts"] = 'console.log("Hello, test!");',
    }

    local function options(session, u)
        local ls, err = session:GetLanguageService(nil, u or "file:///src/index.ts")
        assert.is_nil(err)
        return ls:GetProgram():Options()
    end

    local function changed(session, path, changeType)
        session:DidChangeWatchedFiles(nil, { { uri = "file://" .. path, type = changeType or lsproto.FileChangeType.Changed } })
    end

    it("should update program options on config file change", function()
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)

        assert.is_nil(utils:FS():WriteFile("/src/tsconfig.json", '{"extends": "../tsconfig.base.json", "compilerOptions": {"target": "esnext", "noLib": true}, "references": [{"path": "../utils"}]}'))
        changed(session, "/src/tsconfig.json")

        assert.are.equal(core.ScriptTarget.ESNext, options(session).target)
    end)

    it("should update project on extended config file change", function()
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)

        assert.is_nil(utils:FS():WriteFile("/tsconfig.base.json", '{"compilerOptions": {"strict": false}}'))
        changed(session, "/tsconfig.base.json")

        assert.are.equal(core.Tristate.TSFalse, options(session).strict)
    end)

    it("should update project on doubly extended config file change", function()
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)

        assert.is_nil(utils:FS():WriteFile("/tsconfig.more-base.json", '{"compilerOptions": {"verbatimModuleSyntax": true}}'))
        changed(session, "/tsconfig.more-base.json")

        assert.are.equal(core.Tristate.TSTrue, options(session).verbatimModuleSyntax)
    end)

    it("should update project on referenced config file change", function()
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        local snapshotBefore = session:Snapshot()

        assert.is_nil(utils:FS():WriteFile("/utils/tsconfig.json", '{"compilerOptions": {"composite": true, "noLib": true, "target": "esnext"}}'))
        changed(session, "/utils/tsconfig.json")

        options(session)
        assert.are_not.equal(snapshotBefore, session:Snapshot())
    end)

    it("config file creation then deletion", function()
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/subfolder/foo.ts", 1, files["/src/subfolder/foo.ts"], TS)

        assert.is_nil(utils:FS():WriteFile("/src/subfolder/tsconfig.json", '{ "compilerOptions": { "noLib": true } }'))
        changed(session, "/src/subfolder/tsconfig.json", lsproto.FileChangeType.Created)

        options(session, "file:///src/subfolder/foo.ts")
        local snapshot = session:Snapshot()
        assert.are.equal(2, #snapshot.projectCollection:Projects())
        assert.are.equal("/src/subfolder/tsconfig.json", snapshot:GetDefaultProject("file:///src/subfolder/foo.ts"):Name())

        assert.is_nil(utils:FS():Remove("/src/subfolder/tsconfig.json"))
        changed(session, "/src/subfolder/tsconfig.json", lsproto.FileChangeType.Deleted)

        options(session, "file:///src/subfolder/foo.ts")
        snapshot = session:Snapshot()
        assert.are.equal("/src/tsconfig.json", snapshot:GetDefaultProject("file:///src/subfolder/foo.ts"):Name())
        assert.are.equal(2, #snapshot.projectCollection:Projects()) -- Old project will be cleaned up on next file open

        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        assert.are.equal(1, #session:Snapshot().projectCollection:Projects())
    end)

    it("should update project when missing extended config is created", function()
        local missingBaseFiles = {}
        for k, v in pairs(files) do
            if k ~= "/tsconfig.base.json" then
                missingBaseFiles[k] = v
            end
        end

        local session, utils = projecttestutil.Setup(missingBaseFiles)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, missingBaseFiles["/src/index.ts"], TS)

        assert.is_nil(utils:FS():WriteFile("/tsconfig.base.json", '{"compilerOptions": {"strict": true}}'))
        changed(session, "/tsconfig.base.json", lsproto.FileChangeType.Created)

        assert.are.equal(core.Tristate.TSTrue, options(session).strict)
    end)
end)
