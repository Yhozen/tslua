-- Ported from internal/project/snapshot_test.go and internal/project/refcountcache_test.go.
local bundled = require("tslua.bundled")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local vfstest = require("tslua.vfs.vfstest")

local TS = lsproto.LanguageKind.TypeScript

local function setup(files)
    local fs = bundled.WrapFS(vfstest.FromMap(files, false))
    return project.NewSession({
        backgroundCtx = nil,
        options = project.NewSessionOptions({
            currentDirectory = "/",
            defaultLibraryPath = bundled.LibPath(),
            typingsLocation = "/home/src/Library/Caches/typescript",
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = false,
            loggingEnabled = false,
        }),
        fs = fs,
    })
end

local function getLS(session, uri)
    local ls, err = session:GetLanguageService(nil, uri)
    assert.is_nil(err)
    return ls
end

local function whole(text)
    return { { wholeDocument = { text = text } } }
end

local function partial(sl, sc, el, ec, text)
    return { {
        partial = {
            range = { start = { line = sl, character = sc }, end_ = { line = el, character = ec } },
            text = text,
        },
    } }
end

local function entryFor(session, file)
    local key = project.NewParseCacheKey(file:ParseOptions(), file.hash, file.scriptKind)
    return session.parseCache.entries:Load(key.cacheKey)
end

describe("project.Snapshot", function()
    it("compilerHost gets frozen with snapshot's FS only once", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p1/index.ts"] = "console.log('Hello, world!');",
        }
        local session = setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"], TS)
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        local snapshotBefore = session:Snapshot()

        session:DidChangeFile(nil, "file:///home/projects/TS/p1/index.ts", 2, partial(0, 24, 0, 24, "\n"))
        getLS(session, "file:///home/projects/TS/p1/index.ts")
        local snapshotAfter = session:Snapshot()

        -- Configured project was updated by a clone
        assert.are.equal(project.ProgramUpdateKind.Cloned, snapshotAfter.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json").programUpdateKind)
        -- Inferred project wasn't updated last snapshot change, so its program update kind is still NewFiles
        assert.are.equal(snapshotBefore.projectCollection:InferredProject(), snapshotAfter.projectCollection:InferredProject())
        assert.are.equal(project.ProgramUpdateKind.NewFiles, snapshotAfter.projectCollection:InferredProject().programUpdateKind)
        -- host for inferred project should not change
        assert.are.equal(snapshotBefore.fs, snapshotAfter.projectCollection:InferredProject().host.sourceFS.source)
    end)

    it("cached disk files are cleaned up", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p1/index.ts"] = "import { a } from './a'; console.log(a);",
            ["/home/projects/TS/p1/a.ts"] = "export const a = 1;",
            ["/home/projects/TS/p2/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p2/index.ts"] = "import { b } from './b'; console.log(b);",
            ["/home/projects/TS/p2/b.ts"] = "export const b = 2;",
        }
        local session = setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"], TS)
        session:DidOpenFile(nil, "file:///home/projects/TS/p2/index.ts", 1, files["/home/projects/TS/p2/index.ts"], TS)
        local snapshotBefore = session:Snapshot()

        -- a.ts and b.ts are cached
        assert.is_not_nil(snapshotBefore.fs.diskFiles["/home/projects/ts/p1/a.ts"])
        assert.is_not_nil(snapshotBefore.fs.diskFiles["/home/projects/ts/p2/b.ts"])

        -- Close p1's only open file
        session:DidCloseFile(nil, "file:///home/projects/TS/p1/index.ts")
        -- Next open file is unrelated to p1, triggers p1 closing and file cache cleanup
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        local snapshotAfter = session:Snapshot()

        -- a.ts is cleaned up, b.ts is still cached
        assert.is_nil(snapshotAfter.fs.diskFiles["/home/projects/ts/p1/a.ts"])
        assert.is_not_nil(snapshotAfter.fs.diskFiles["/home/projects/ts/p2/b.ts"])
    end)

    it("GetFile returns nil for non-existent files", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p1/index.ts"] = "console.log('Hello, world!');",
        }
        local session = setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"], TS)
        local snapshot = session:Snapshot()

        assert.is_nil(snapshot:GetFile("/home/projects/TS/p1/nonexistent.ts"))
        local _, ok = snapshot:ReadFile("/home/projects/TS/p1/nonexistent.ts")
        assert.is_false(ok)
    end)

    it("auto-import snapshot is adopted when session snapshot is unchanged", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p1/index.ts"] = "const value = foo;",
            ["/home/projects/TS/p1/foo.ts"] = "export const foo = 1;",
        }
        local session = setup(files)
        local uri = "file:///home/projects/TS/p1/index.ts"

        session:DidOpenFile(nil, uri, 1, files["/home/projects/TS/p1/index.ts"], TS)
        getLS(session, uri)

        local baseSnapshot = session:Snapshot()
        local preparedSnapshot = session:GetSnapshotWithAutoImports(nil, baseSnapshot, uri)

        session:WaitForBackgroundTasks()
        assert.are.equal(preparedSnapshot, session:Snapshot())
        preparedSnapshot:Deref(session)
        session:Close()
    end)

    it("no-op watch change does not rebuild program", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/TS/p1/index.ts"] = "import { a } from './a'; console.log(a);",
            ["/home/projects/TS/p1/a.ts"] = "export const a = 1;",
        }
        local session = setup(files)
        local uri = "file:///home/projects/TS/p1/index.ts"
        local configPath = "/home/projects/ts/p1/tsconfig.json"

        session:DidOpenFile(nil, uri, 1, files["/home/projects/TS/p1/index.ts"], TS)
        getLS(session, uri)

        local programBefore = session:Snapshot().projectCollection:ConfiguredProject(configPath).program

        -- Send a watch change event for a project file whose content on disk is unchanged.
        session.pendingFileChanges = session.pendingFileChanges or {}
        table.insert(session.pendingFileChanges, project.NewFileChange({ kind = project.FileChangeKind.WatchChange, uri = "file:///home/projects/TS/p1/a.ts" }))
        getLS(session, uri)

        assert.are.equal(programBefore, session:Snapshot().projectCollection:ConfiguredProject(configPath).program)

        -- A watch change that reflects an actual content change on disk must still rebuild the program.
        assert.is_nil(session.fs.fs:WriteFile("/home/projects/TS/p1/a.ts", "export const a = 2;"))
        session.pendingFileChanges = session.pendingFileChanges or {}
        table.insert(session.pendingFileChanges, project.NewFileChange({ kind = project.FileChangeKind.WatchChange, uri = "file:///home/projects/TS/p1/a.ts" }))
        getLS(session, uri)

        assert.are_not.equal(programBefore, session:Snapshot().projectCollection:ConfiguredProject(configPath).program)
        session:Close()
    end)
end)

describe("project parse cache ref counting", function()
    -- Configured project with noLib (the Go test uses an inferred project, which loads the full
    -- default lib set; that is slow in the Lua port and does not change what is being tested).
    local files = {
        ["/user/username/projects/myproject/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
        ["/user/username/projects/myproject/src/main.ts"] = "const x = 1;",
        ["/user/username/projects/myproject/src/utils.ts"] = "export function util() {}",
    }
    local mainURI = "file:///user/username/projects/myproject/src/main.ts"
    local utilsURI = "file:///user/username/projects/myproject/src/utils.ts"
    local configPath = "/user/username/projects/myproject/tsconfig.json"

    local function openBoth(session)
        session:DidOpenFile(nil, mainURI, 1, files["/user/username/projects/myproject/src/main.ts"], TS)
        session:DidOpenFile(nil, utilsURI, 1, files["/user/username/projects/myproject/src/utils.ts"], TS)
        return session:Snapshot().projectCollection:ConfiguredProject(configPath).program
    end

    it("reuse unchanged file", function()
        local session = setup(files)
        local program = openBoth(session)
        local main = program:GetSourceFile("/user/username/projects/myproject/src/main.ts")
        local utils = program:GetSourceFile("/user/username/projects/myproject/src/utils.ts")
        local mainEntry = entryFor(session, main)
        local utilsEntry = entryFor(session, utils)
        assert.are.equal(1, mainEntry.refCount)
        assert.are.equal(1, utilsEntry.refCount)

        session:DidChangeFile(nil, mainURI, 2, partial(0, 0, 0, 12, "const x = 2;"))
        local ls = getLS(session, mainURI)
        session:WaitForBackgroundTasks()
        local newMain = ls:GetProgram():GetSourceFile("/user/username/projects/myproject/src/main.ts")
        local newMainEntry = entryFor(session, newMain)
        assert.are_not.equal(main, newMain)
        assert.are_not.equal(mainEntry, newMainEntry)
        assert.are.equal(utils, ls:GetProgram():GetSourceFile("/user/username/projects/myproject/src/utils.ts"))
        -- Old snapshot is deref'd immediately when replaced by UpdateSnapshot.
        assert.are.equal(0, mainEntry.refCount)
        assert.are.equal(1, newMainEntry.refCount)
        assert.are.equal(1, utilsEntry.refCount)
    end)

    it("release file on close", function()
        local inferredFiles = {
            ["/user/username/projects/myproject/src/main.ts"] = "const x = 1;",
            ["/user/username/projects/myproject/src/utils.ts"] = "export function util() {}",
        }
        local session = setup(inferredFiles)
        session:DidOpenFile(nil, mainURI, 1, inferredFiles["/user/username/projects/myproject/src/main.ts"], TS)
        session:DidOpenFile(nil, utilsURI, 1, inferredFiles["/user/username/projects/myproject/src/utils.ts"], TS)
        local program = session:Snapshot().projectCollection:InferredProject().program
        local main = program:GetSourceFile("/user/username/projects/myproject/src/main.ts")
        local utils = program:GetSourceFile("/user/username/projects/myproject/src/utils.ts")
        local mainEntry = entryFor(session, main)
        local utilsEntry = entryFor(session, utils)
        assert.are.equal(1, mainEntry.refCount)
        assert.are.equal(1, utilsEntry.refCount)

        session:DidCloseFile(nil, mainURI)
        getLS(session, utilsURI)
        session:WaitForBackgroundTasks()
        assert.are.equal(1, utilsEntry.refCount)
        assert.are.equal(0, mainEntry.refCount)
        local _, ok = entryFor(session, main)
        assert.is_false(ok)
    end)

    it("unchanged program does not over-ref", function()
        local session = setup(files)
        local program1 = openBoth(session)
        local main = program1:GetSourceFile("/user/username/projects/myproject/src/main.ts")
        assert.are.equal(1, entryFor(session, main).refCount)

        session:DidChangeFile(nil, utilsURI, 2, partial(0, 0, 0, 25, "export function util2() {}"))

        local ls = getLS(session, mainURI)
        session:WaitForBackgroundTasks()
        assert.are.equal(main, ls:GetProgram():GetSourceFile("/user/username/projects/myproject/src/main.ts"))
        assert.are.equal(1, entryFor(session, main).refCount)

        -- Close files to trigger cleanup
        session:DidCloseFile(nil, mainURI)
        session:DidCloseFile(nil, utilsURI)
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        session:WaitForBackgroundTasks()

        local _, ok = entryFor(session, main)
        assert.is_false(ok)
    end)

    it("fallback rebuild does not double-ref changed file", function()
        local testFiles = {
            ["/user/username/projects/myproject/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/user/username/projects/myproject/src/main.ts"] = "const x = 1;",
            ["/user/username/projects/myproject/src/utils.ts"] = "export const util = 1;",
        }
        local session = setup(testFiles)
        session:DidOpenFile(nil, mainURI, 1, testFiles["/user/username/projects/myproject/src/main.ts"], TS)
        getLS(session, mainURI)

        session:DidChangeFile(nil, mainURI, 2, whole('import { util } from "./utils";\nconst x = util;'))

        local lsAfter = getLS(session, mainURI)
        session:WaitForBackgroundTasks()

        local p = session:Snapshot().projectCollection:ConfiguredProject(configPath)
        assert.is_not_nil(p)

        local main = lsAfter:GetProgram():GetSourceFile("/user/username/projects/myproject/src/main.ts")
        local mainEntry, ok = entryFor(session, main)
        assert.is_true(ok)
        assert.are.equal(1, mainEntry.refCount)

        session:DidCloseFile(nil, mainURI)
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        session:WaitForBackgroundTasks()

        local _, okAfter = entryFor(session, main)
        assert.is_false(okAfter)
    end)
end)
