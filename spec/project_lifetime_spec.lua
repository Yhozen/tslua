-- Ported from internal/project/projectlifetime_test.go (the "./"-prefixed include scenario needs
-- the ESNext/DOM libraries and is not ported because of its cost in the Lua port).
local lsproto = require("tslua.lsp.lsproto")
local projecttestutil = require("tslua.testutil.projecttestutil")

local TS = lsproto.LanguageKind.TypeScript
local Created, Deleted = lsproto.FileChangeType.Created, lsproto.FileChangeType.Deleted

local function projects(session)
    return session:Snapshot().projectCollection
end

local function getProgram(session, uri)
    local ls, err = session:GetLanguageService(nil, uri)
    assert.is_nil(err)
    return ls:GetProgram()
end

describe("project lifetime #slow", function()
    it("configured project", function()
        local config = [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true
				},
				"include": ["src"]
			}]]
        local files = {}
        for _, p in ipairs({ "p1", "p2", "p3" }) do
            files["/home/projects/TS/" .. p .. "/tsconfig.json"] = config
            files["/home/projects/TS/" .. p .. "/src/index.ts"] = 'import { x } from "./x";'
            files["/home/projects/TS/" .. p .. "/src/x.ts"] = "export const x = 1;"
            files["/home/projects/TS/" .. p .. "/config.ts"] = "let x = 1, y = 2;"
        end
        local session, utils = projecttestutil.Setup(files)
        assert.are.equal(0, #projects(session):Projects())

        -- Open files in two projects
        local uri1 = "file:///home/projects/TS/p1/src/index.ts"
        local uri2 = "file:///home/projects/TS/p2/src/index.ts"
        session:DidOpenFile(nil, uri1, 1, files["/home/projects/TS/p1/src/index.ts"], TS)
        session:DidOpenFile(nil, uri2, 1, files["/home/projects/TS/p2/src/index.ts"], TS)
        session:WaitForBackgroundTasks()
        local snapshot = session:Snapshot()
        assert.are.equal(2, #snapshot.projectCollection:Projects())
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p2/tsconfig.json"))
        assert.are.equal(1, #utils:Client():WatchFilesCalls())
        assert.is_not_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p2/tsconfig.json"))

        -- Close p1 file and open p3 file
        session:DidCloseFile(nil, uri1)
        local uri3 = "file:///home/projects/TS/p3/src/index.ts"
        session:DidOpenFile(nil, uri3, 1, files["/home/projects/TS/p3/src/index.ts"], TS)
        session:WaitForBackgroundTasks()
        -- Should still have two projects, but p1 replaced by p3
        snapshot = session:Snapshot()
        assert.are.equal(2, #snapshot.projectCollection:Projects())
        assert.is_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p2/tsconfig.json"))
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p3/tsconfig.json"))
        assert.is_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p2/tsconfig.json"))
        assert.is_not_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p3/tsconfig.json"))
        assert.are.equal(1, #utils:Client():WatchFilesCalls())
        assert.are.equal(0, #utils:Client():UnwatchFilesCalls())

        -- Close p2 and p3 files, open p1 file again
        session:DidCloseFile(nil, uri2)
        session:DidCloseFile(nil, uri3)
        session:DidOpenFile(nil, uri1, 1, files["/home/projects/TS/p1/src/index.ts"], TS)
        session:WaitForBackgroundTasks()
        -- Should have one project (p1)
        snapshot = session:Snapshot()
        assert.are.equal(1, #snapshot.projectCollection:Projects())
        assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p1/tsconfig.json"))
        assert.is_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p2/tsconfig.json"))
        assert.is_nil(snapshot.configFileRegistry:GetConfig("/home/projects/ts/p3/tsconfig.json"))
        assert.are.equal(1, #utils:Client():WatchFilesCalls())
        assert.are.equal(0, #utils:Client():UnwatchFilesCalls())
    end)

    it("file moves from inferred to configured project", function()
        local files = {
            ["/home/projects/ts/foo.ts"] = "export const foo = 1;",
            ["/home/projects/ts/p1/tsconfig.json"] = [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true
				},
				"include": ["main.ts"]
			}]],
            ["/home/projects/ts/p1/main.ts"] = 'import { foo } from "../foo"; console.log(foo);',
        }
        local session = projecttestutil.Setup(files)

        -- Open foo.ts first - should create inferred project since no tsconfig found initially
        local fooUri = "file:///home/projects/ts/foo.ts"
        session:DidOpenFile(nil, fooUri, 1, files["/home/projects/ts/foo.ts"], TS)

        assert.are.equal(1, #projects(session):Projects())
        assert.is_not_nil(projects(session):InferredProject())
        assert.is_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))

        -- Now open main.ts - should trigger discovery of tsconfig.json and move foo.ts to configured project
        local mainUri = "file:///home/projects/ts/p1/main.ts"
        session:DidOpenFile(nil, mainUri, 1, files["/home/projects/ts/p1/main.ts"], TS)

        assert.are.equal(1, #projects(session):Projects())
        assert.is_nil(projects(session):InferredProject())
        assert.is_not_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
        assert.is_not_nil(session:Snapshot().configFileRegistry:GetConfig("/home/projects/ts/p1/tsconfig.json"))

        -- Close main.ts - configured project should remain because foo.ts is still open
        session:DidCloseFile(nil, mainUri)
        assert.are.equal(1, #projects(session):Projects())
        assert.is_not_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))

        -- Close foo.ts - configured project should be retained until next file open
        session:DidCloseFile(nil, fooUri)
        assert.are.equal(1, #projects(session):Projects())
        assert.is_not_nil(session:Snapshot().configFileRegistry:GetConfig("/home/projects/ts/p1/tsconfig.json"))
    end)

    it("file move from inferred to configured via didOpen/didClose sequence", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{\n "compilerOptions": {\n "noLib": true\n },\n "include": ["src"]\n }',
            ["/home/projects/TS/p1/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)

        local indexUri = "file:///home/projects/TS/p1/index.ts"
        session:DidOpenFile(nil, indexUri, 1, files["/home/projects/TS/p1/index.ts"], TS)

        assert.are.equal(1, #projects(session):Projects())
        assert.is_not_nil(projects(session):InferredProject())
        assert.is_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))

        -- Simulate file move: create src/index.ts on disk
        assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/index.ts", files["/home/projects/TS/p1/index.ts"]))
        assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/index.ts"))

        local srcIndexUri = "file:///home/projects/TS/p1/src/index.ts"
        session:DidOpenFile(nil, srcIndexUri, 1, files["/home/projects/TS/p1/index.ts"], TS)
        session:DidCloseFile(nil, indexUri)
        session:DidChangeWatchedFiles(nil, {
            { uri = srcIndexUri, type = Created },
            { uri = indexUri, type = Deleted },
        })

        -- Should now have one configured project only (file is now under src/)
        getProgram(session, srcIndexUri)
        assert.are.equal(1, #projects(session):Projects())
        assert.is_nil(projects(session):InferredProject())
        assert.is_not_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
    end)

    it("tsconfig move from subdirectory to parent via didChangeWatchedFiles", function()
        local files = {
            ["/home/projects/TS/p1/src/tsconfig.json"] = '{\n "compilerOptions": {\n "noLib": true\n },\n "include": ["src"]\n }',
            ["/home/projects/TS/p1/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)

        local indexUri = "file:///home/projects/TS/p1/src/index.ts"
        session:DidOpenFile(nil, indexUri, 1, files["/home/projects/TS/p1/src/index.ts"], TS)

        assert.are.equal(1, #projects(session):Projects())
        assert.is_not_nil(projects(session):InferredProject())
        assert.is_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/src/tsconfig.json"))

        -- Simulate tsconfig.json move: create tsconfig.json at parent level, delete from src/
        assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/tsconfig.json", files["/home/projects/TS/p1/src/tsconfig.json"]))
        assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/tsconfig.json"))

        session:DidChangeWatchedFiles(nil, {
            { uri = "file:///home/projects/TS/p1/tsconfig.json", type = Created },
            { uri = "file:///home/projects/TS/p1/src/tsconfig.json", type = Deleted },
        })

        getProgram(session, indexUri)
        assert.are.equal(1, #projects(session):Projects())
        assert.is_nil(projects(session):InferredProject())
        assert.is_not_nil(projects(session):ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
    end)

    it("deleted open file remains in project until closed", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{\n "compilerOptions": {\n "noLib": true\n },\n "include": ["src"]\n }',
            ["/home/projects/TS/p1/src/index.ts"] = "",
            ["/home/projects/TS/p1/src/x.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)

        -- Step 1: Open both files
        local indexUri = "file:///home/projects/TS/p1/src/index.ts"
        local xUri = "file:///home/projects/TS/p1/src/x.ts"
        session:DidOpenFile(nil, indexUri, 1, files["/home/projects/TS/p1/src/index.ts"], TS)
        session:DidOpenFile(nil, xUri, 1, files["/home/projects/TS/p1/src/x.ts"], TS)

        local program = getProgram(session, indexUri)
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/index.ts"))
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))

        -- Step 2: delete x.ts from disk (but leave it open), create y.ts
        assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/x.ts"))
        assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/y.ts", "export const y = 2;"))

        session:DidChangeWatchedFiles(nil, {
            { uri = xUri, type = Deleted },
            { uri = "file:///home/projects/TS/p1/src/y.ts", type = Created },
        })

        -- Step 3 & 4: Request LS for the deleted but still open file
        program = getProgram(session, xUri)
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/index.ts"))
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/y.ts"))

        -- Step 5: Close the deleted file
        session:DidCloseFile(nil, xUri)

        -- Step 6: On next LS request, x.ts should be excluded
        program = getProgram(session, indexUri)
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/index.ts"))
        assert.is_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
        assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/y.ts"))
    end)
end)
