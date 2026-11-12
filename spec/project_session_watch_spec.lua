-- Ported from internal/project/session_test.go (TestSession/DidChangeWatchedFiles and the
-- preference, closed-file and jsconfig cases).
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local project = require("tslua.project")
local projecttestutil = require("tslua.testutil.projecttestutil")
local vfstest = require("tslua.vfs.vfstest")

local TS = lsproto.LanguageKind.TypeScript
local Created, Changed, Deleted = lsproto.FileChangeType.Created, lsproto.FileChangeType.Changed, lsproto.FileChangeType.Deleted

local function getProgram(session, uri)
    local ls, err = session:GetLanguageService(nil, uri)
    assert.is_nil(err)
    return ls:GetProgram()
end

local function semanticDiagnosticCount(program, fileName)
    local ctx = projecttestutil.WithRequestID(core.WithCancel(nil))
    return core.Len(program:GetSemanticDiagnostics(ctx, program:GetSourceFile(fileName)))
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then
            return true
        end
    end
    return false
end

local function events(...)
    local result = {}
    for _, e in ipairs({ ... }) do
        result[#result + 1] = { type = e[1], uri = e[2] }
    end
    return result
end

describe("project.Session DidChangeWatchedFiles", function()
    it("delete explicitly included file", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					"files": ["src/index.ts", "src/x.ts"]
				}]],
            ["/home/projects/TS/p1/src/x.ts"] = "export declare const x: number | undefined;",
            ["/home/projects/TS/p1/src/index.ts"] = 'import { x } from "./x";',
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

        local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
        assert.is_true(contains(program:CommandLine().parsedConfig.fileNames, "/home/projects/TS/p1/src/x.ts"))
        assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))

        assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/x.ts"))

        session:DidChangeWatchedFiles(nil, events({ Deleted, "file:///home/projects/TS/p1/src/x.ts" }))

        program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
        -- File name is still in the command line, was explicitly included
        assert.is_true(contains(program:CommandLine().parsedConfig.fileNames, "/home/projects/TS/p1/src/x.ts"))
        assert.are.equal(1, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))
        assert.is_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))

        -- Open file to trigger cleanup
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        assert.is_nil(session:Snapshot():GetFile("/home/projects/TS/p1/src/x.ts"))
    end)

    it("delete wildcard included file", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					"include": ["src"]
				}]],
            ["/home/projects/TS/p1/src/index.ts"] = "let x = 2;",
            ["/home/projects/TS/p1/src/x.ts"] = "let y = x;",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, files["/home/projects/TS/p1/src/x.ts"], TS)

        local program = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")
        assert.is_true(contains(program:CommandLine().parsedConfig.fileNames, "/home/projects/TS/p1/src/index.ts"))
        assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/x.ts"))

        assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/index.ts"))

        session:DidChangeWatchedFiles(nil, events({ Deleted, "file:///home/projects/TS/p1/src/index.ts" }))

        program = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")
        -- File name is gone from the command line, was originally included via wildcard
        assert.is_false(contains(program:CommandLine().parsedConfig.fileNames, "/home/projects/TS/p1/src/index.ts"))
        assert.are.equal(1, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/x.ts"))

        -- Open file to trigger cleanup
        session:DidOpenFile(nil, "untitled:Untitled-1", 1, "", TS)
        assert.is_nil(session:Snapshot():GetFile("/home/projects/TS/p1/src/index.ts"))
    end)

    for _, case in ipairs({
        { name = "delete directory with wildcard included files", spec = '"include": ["src"]' },
        { name = "delete directory with program-only files", spec = '"files": ["src/index.ts"]' },
    }) do
        it(case.name, function()
            local files = {
                ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					]] .. case.spec .. [[
				}]],
                ["/home/projects/TS/p1/src/index.ts"] = 'import { x } from "./sub/x";',
                ["/home/projects/TS/p1/src/sub/x.ts"] = "export const x = 1;",
            }
            local session, utils = projecttestutil.Setup(files)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/sub/x.ts"))
            assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))

            -- Delete the entire subdirectory from the file system.
            assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/sub"))

            -- Send a delete event for the directory URI.
            session:DidChangeWatchedFiles(nil, events({ Deleted, "file:///home/projects/TS/p1/src/sub" }))

            program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_false(contains(program:CommandLine().parsedConfig.fileNames, "/home/projects/TS/p1/src/sub/x.ts"))
            assert.is_nil(program:GetSourceFile("/home/projects/TS/p1/src/sub/x.ts"))
            -- The import should now be an error since the module is missing.
            assert.are.equal(1, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))
        end)
    end

    for _, case in ipairs({ "close content file", "open third file" }) do
        it("delete sibling folder schedules diagnostics refresh (" .. case .. ")", function()
            local files = {
                ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					"files": ["index.ts", "third.ts"]
				}]],
                ["/home/projects/TS/p1/index.ts"] = 'import { content } from "./f/content";\n\nexport const value = content;',
                ["/home/projects/TS/p1/f/content.ts"] = "export const content = 1;",
                ["/home/projects/TS/p1/third.ts"] = "export const third = 3;",
            }
            local session, utils = projecttestutil.Setup(files)
            local contentURI = "file:///home/projects/TS/p1/f/content.ts"
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"], TS)
            session:DidOpenFile(nil, contentURI, 1, files["/home/projects/TS/p1/f/content.ts"], TS)

            getProgram(session, "file:///home/projects/TS/p1/index.ts")
            session:WaitForBackgroundTasks()

            local baselineRefreshCount = #utils:Client():RefreshDiagnosticsCalls()

            assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/f"))

            session:DidChangeWatchedFiles(nil, events({ Deleted, "file:///home/projects/TS/p1/f" }))
            if case == "close content file" then
                session:DidCloseFile(nil, contentURI)
            else
                session:DidOpenFile(nil, "file:///home/projects/TS/p1/third.ts", 1, files["/home/projects/TS/p1/third.ts"], TS)
            end
            session:WaitForBackgroundTasks()

            assert.is_true(#utils:Client():RefreshDiagnosticsCalls() > baselineRefreshCount)
        end)
    end

    for _, case in ipairs({
        { name = "create explicitly included file", spec = '"files": ["src/index.ts", "src/y.ts"]', import = 'import { y } from "./y";', file = "src/y.ts", content = "export const y = 1;" },
        { name = "create failed lookup location", spec = '"files": ["src/index.ts"]', import = 'import { z } from "./z";', file = "src/z.ts", content = "export const z = 1;" },
        { name = "create wildcard included file", spec = '"include": ["src"]', import = "a;", file = "src/a.ts", content = "const a = 1;" },
        { name = "create file in non-existent directory", spec = '"files": ["src/index.ts"]', import = 'import { helper } from "./lib/helper";', file = "src/lib/helper.ts", content = "export const helper = 1;" },
    }) do
        it(case.name, function()
            local files = {
                ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					]] .. case.spec .. [[
				}]],
                ["/home/projects/TS/p1/src/index.ts"] = case.import,
            }
            local session, utils = projecttestutil.Setup(files)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            -- Initially should have an error because the file is missing
            assert.are.equal(1, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/" .. case.file, case.content))

            session:DidChangeWatchedFiles(nil, events({ Created, "file:///home/projects/TS/p1/" .. case.file }))

            -- Error should be resolved and the new file should be included in the program
            program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/TS/p1/src/index.ts"))
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/" .. case.file))
        end)
    end

    it("irrelevant extension changes are filtered out", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					"include": ["src"]
				}]],
            ["/home/projects/TS/p1/src/index.ts"] = "export const x = 1;",
            ["/home/projects/TS/p1/src/data.txt"] = "some text",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

        local oldProgram = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
        assert.are.equal(0, semanticDiagnosticCount(oldProgram, "/home/projects/TS/p1/src/index.ts"))

        assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/data.txt", "updated text"))

        session:DidChangeWatchedFiles(nil, events(
            { Changed, "file:///home/projects/TS/p1/src/data.txt" },
            { Created, "file:///home/projects/TS/p1/src/styles.css" },
            { Created, "file:///home/projects/TS/p1/src/image.png" }
        ))

        -- The program should not have been rebuilt since all events had irrelevant extensions.
        assert.are.equal(oldProgram, getProgram(session, "file:///home/projects/TS/p1/src/index.ts"))
    end)

    it("pnpm install links local package", function()
        local files = {
            ["/home/projects/pnpm/pnpm-workspace.yaml"] = "packages:\n  - 'packages/*'",
            ["/home/projects/pnpm/packages/alpha/package.json"] = '{ "name": "@repo/alpha", "main": "index.ts" }',
            ["/home/projects/pnpm/packages/alpha/tsconfig.json"] = '{\n "compilerOptions": { "noLib": true, "composite": true }\n }',
            ["/home/projects/pnpm/packages/alpha/index.ts"] = "export const alpha = 1;",
            ["/home/projects/pnpm/packages/beta/package.json"] = '{ "name": "@repo/beta" }',
            ["/home/projects/pnpm/packages/beta/tsconfig.json"] = '{\n "compilerOptions": { "noLib": true }\n }',
            ["/home/projects/pnpm/packages/beta/index.ts"] = 'import { alpha } from "@repo/alpha";',
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/pnpm/packages/beta/index.ts", 1, files["/home/projects/pnpm/packages/beta/index.ts"], TS)

        -- Before pnpm install: the import is unresolved because node_modules/@repo/alpha doesn't exist.
        local program = getProgram(session, "file:///home/projects/pnpm/packages/beta/index.ts")
        assert.are.equal(1, semanticDiagnosticCount(program, "/home/projects/pnpm/packages/beta/index.ts"))

        -- Simulate pnpm install: create a symlink from beta's node_modules/@repo/alpha to packages/alpha.
        local mapFS = utils:FsFromFileMap():FSys()
        assert.is_nil(mapFS:MkdirAll("home/projects/pnpm/packages/beta/node_modules/@repo", tonumber("777", 8)))
        mapFS:AddSymlink("home/projects/pnpm/packages/beta/node_modules/@repo/alpha", "home/projects/pnpm/packages/alpha")

        -- Fire watch events mimicking what VS Code sends for a pnpm install.
        session:DidChangeWatchedFiles(nil, events(
            { Created, "file:///home/projects/pnpm/packages/beta/node_modules" },
            { Created, "file:///home/projects/pnpm/packages/beta/node_modules/%40repo" },
            { Created, "file:///home/projects/pnpm/packages/beta/node_modules/%40repo/alpha" },
            { Created, "file:///home/projects/pnpm/pnpm-lock.yaml" },
            { Changed, "file:///home/projects/pnpm/packages/beta/node_modules/.bin/tsc" },
            { Changed, "file:///home/projects/pnpm/packages/beta/node_modules/.bin/tsserver" }
        ))

        -- After pnpm install: the import should resolve.
        program = getProgram(session, "file:///home/projects/pnpm/packages/beta/index.ts")
        assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/pnpm/packages/beta/index.ts"))
    end)

    it("symlinked node_modules package.json change invalidates resolution", function()
        local files = {
            ["/home/projects/myproject/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true,
						"module": "nodenext",
						"moduleResolution": "nodenext"
					},
					"files": ["src/index.ts"]
				}]],
            ["/home/projects/myproject/src/index.ts"] = 'import { foo } from "mylib";',
            -- The real package lives as a sibling directory
            ["/home/projects/mylib/package.json"] = '{\n "name": "mylib",\n "main": "dist/index.js"\n }',
            ["/home/projects/mylib/dist/index.js"] = "exports.foo = function() { return 1; };",
            ["/home/projects/mylib/dist/index.d.ts"] = "export declare function foo(): number;",
            -- node_modules/mylib is a symlink to the sibling
            ["/home/projects/myproject/node_modules/mylib"] = vfstest.Symlink("/home/projects/mylib"),
        }

        local session, utils = projecttestutil.SetupWithOptions(files, project.NewSessionOptions({
            currentDirectory = "/home/projects/myproject",
            defaultLibraryPath = bundled.LibPath(),
            typingsLocation = projecttestutil.TestTypingsLocation,
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = true,
            loggingEnabled = true,
        }))
        session:DidOpenFile(nil, "file:///home/projects/myproject/src/index.ts", 1, files["/home/projects/myproject/src/index.ts"], TS)

        -- Initial state: import resolves successfully via package.json main -> dist/index.d.ts
        local program = getProgram(session, "file:///home/projects/myproject/src/index.ts")
        session:WaitForBackgroundTasks()
        assert.are.equal(0, semanticDiagnosticCount(program, "/home/projects/myproject/src/index.ts"))

        -- Assert: watched file globs cover the realpath of package.json and dist/index.d.ts.
        assert.is_true(utils:WatchesFile("/home/projects/mylib/package.json"))
        assert.is_true(utils:WatchesFile("/home/projects/mylib/dist/index.d.ts"))

        -- Edit package.json to remove "main" field
        assert.is_nil(utils:FS():WriteFile("/home/projects/mylib/package.json", '{\n "name": "mylib"\n }'))

        session:DidChangeWatchedFiles(nil, events({ Changed, "file:///home/projects/mylib/package.json" }))

        -- After removing "main" from package.json, the import should no longer resolve.
        program = getProgram(session, "file:///home/projects/myproject/src/index.ts")
        assert.is_true(semanticDiagnosticCount(program, "/home/projects/myproject/src/index.ts") > 0)
    end)

    it("create symlink directory matching include pattern", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true
					},
					"include": ["src"]
				}]],
            ["/home/projects/TS/p1/src/index.ts"] = "export const x = 1;",
            ["/home/projects/TS/shared/utils.ts"] = 'export const util = "hello";',
            ["/home/projects/TS/shared/helpers.ts"] = "export const helper = 42;",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

        local fileNames = getProgram(session, "file:///home/projects/TS/p1/src/index.ts"):CommandLine().parsedConfig.fileNames
        assert.is_true(contains(fileNames, "/home/projects/TS/p1/src/index.ts"))
        assert.is_false(contains(fileNames, "/home/projects/TS/p1/src/linked/utils.ts"))

        -- Create a symlink directory inside src/ that points to the shared directory.
        utils:FsFromFileMap():FSys():AddSymlink("home/projects/TS/p1/src/linked", "home/projects/TS/shared")

        session:DidChangeWatchedFiles(nil, events({ Created, "file:///home/projects/TS/p1/src/linked" }))

        fileNames = getProgram(session, "file:///home/projects/TS/p1/src/index.ts"):CommandLine().parsedConfig.fileNames
        assert.is_true(contains(fileNames, "/home/projects/TS/p1/src/index.ts"))
        assert.is_true(contains(fileNames, "/home/projects/TS/p1/src/linked/utils.ts"))
        assert.is_true(contains(fileNames, "/home/projects/TS/p1/src/linked/helpers.ts"))
    end)

    it("skips irrelevant extensions", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{\n "compilerOptions": { "noLib": true },\n "include": ["src"]\n }',
            ["/home/projects/TS/p1/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)

        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)
        session:WaitForBackgroundTasks()

        local function refreshCount()
            return #utils:Client():RefreshDiagnosticsCalls()
        end
        local baseline = refreshCount()

        -- Scenario A: irrelevant .svg
        session:DidChangeWatchedFiles(nil, events({ Created, "file:///home/projects/TS/p1/icon.svg" }))
        session:WaitForBackgroundTasks()
        assert.are.equal(baseline, refreshCount())

        -- Scenario B: relevant .ts
        session:DidChangeWatchedFiles(nil, events({ Created, "file:///home/projects/TS/p1/src/new.ts" }))
        session:WaitForBackgroundTasks()
        assert.is_true(refreshCount() > baseline)
        baseline = refreshCount()

        -- Scenario C: tsconfig.json
        session:DidChangeWatchedFiles(nil, events({ Changed, "file:///home/projects/TS/p1/tsconfig.json" }))
        session:WaitForBackgroundTasks()
        assert.is_true(refreshCount() > baseline)
        baseline = refreshCount()

        -- Scenario D: directory creation (no extension)
        assert.is_nil(utils:FsFromFileMap():FSys():MkdirAll("home/projects/TS/p1/node_modules/@types", tonumber("777", 8)))
        session:DidChangeWatchedFiles(nil, events({ Created, "file:///home/projects/TS/p1/node_modules/@types" }))
        session:WaitForBackgroundTasks()
        assert.is_true(refreshCount() > baseline)
        baseline = refreshCount()

        -- Scenario E: mixed batch
        session:DidChangeWatchedFiles(nil, events(
            { Created, "file:///home/projects/TS/p1/icon.png" },
            { Changed, "file:///home/projects/TS/p1/src/index.ts" }
        ))
        session:WaitForBackgroundTasks()
        assert.is_true(refreshCount() > baseline)
        baseline = refreshCount()

        -- Scenario F: package install noise
        session:DidChangeWatchedFiles(nil, events(
            { Created, "file:///home/projects/TS/p1/node_modules/pkg/LICENSE" },
            { Created, "file:///home/projects/TS/p1/README.md" },
            { Created, "file:///home/projects/TS/p1/LICENSE.txt" },
            { Created, "file:///home/projects/TS/p1/style.css" }
        ))
        session:WaitForBackgroundTasks()
        assert.are.equal(baseline, refreshCount())
    end)
end)

describe("project.Session preferences", function()
    local noLibFiles = {
        ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
        ["/src/index.ts"] = "export const x = 1;",
    }

    it("refreshes code lenses and inlay hints when relevant user preferences change", function()
        local session, utils = projecttestutil.Setup(noLibFiles)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, noLibFiles["/src/index.ts"], TS)
        getProgram(session, "file:///src/index.ts")

        session:Configure(lsutil.NewDefaultUserPreferences())
        -- Change user preferences for code lens and inlay hints.
        local newPrefs = session:Config()
        newPrefs.codeLens.referencesCodeLensEnabled = core.Tristate.TSTrue
        newPrefs.inlayHints.includeInlayFunctionLikeReturnTypeHints = core.Tristate.TSTrue

        session:Configure(newPrefs)

        assert.are.equal(1, #utils:Client():RefreshCodeLensCalls())
        assert.are.equal(1, #utils:Client():RefreshInlayHintsCalls())
    end)

    it("sets locale when configured", function()
        local session, utils = projecttestutil.Setup({})
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.locale = "fr"

        session:Configure(prefs)

        local setLocaleCalls = utils:Client():SetLocaleCalls()
        assert.are.equal(1, #setLocaleCalls)
        assert.are.equal("fr", setLocaleCalls[1].localeMoqParam)
    end)

    it("locale change invalidates programs", function()
        local session = projecttestutil.Setup(noLibFiles)
        local uri = "file:///src/index.ts"
        local configPath = "/src/tsconfig.json"
        session:DidOpenFile(nil, uri, 1, noLibFiles["/src/index.ts"], TS)
        getProgram(session, uri)
        local initialProgram = session:Snapshot().projectCollection:ConfiguredProject(configPath).program

        local preferences = session:Config()
        preferences.codeLens.referencesCodeLensEnabled = core.Tristate.TSTrue
        session:Configure(preferences)
        getProgram(session, uri)
        assert.are.equal(initialProgram, session:Snapshot().projectCollection:ConfiguredProject(configPath).program)

        preferences = project.copyValue(preferences)
        preferences.locale = "fr"
        session:Configure(preferences)
        getProgram(session, uri)
        assert.are_not.equal(initialProgram, session:Snapshot().projectCollection:ConfiguredProject(configPath).program)
        session:Close()
    end)

    it("adds locale to background contexts", function()
        local session, utils = projecttestutil.Setup({})
        local fr, ok = locale.Parse("fr")
        assert.is_true(ok)
        utils:Client().getLocaleFunc = function()
            return fr
        end
        local seen = nil
        utils:Client().refreshCodeLensFunc = function(ctx)
            seen = locale.FromContext(ctx)
            return nil
        end
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.codeLens.referencesCodeLensEnabled = core.Tristate.TSTrue

        session:Configure(prefs)

        assert.are.equal(1, #utils:Client():RefreshCodeLensCalls())
        assert.are.equal(fr, seen)
    end)

    it("schedules diagnostics refresh when reportStyleChecksAsWarnings changes", function()
        local session, utils = projecttestutil.Setup(noLibFiles)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, noLibFiles["/src/index.ts"], TS)
        getProgram(session, "file:///src/index.ts")
        session:WaitForBackgroundTasks()

        local baselineRefreshCount = #utils:Client():RefreshDiagnosticsCalls()

        -- Toggle reportStyleChecksAsWarnings (default is true, so set it to false).
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.reportStyleChecksAsWarnings = core.Tristate.TSFalse
        session:Configure(prefs)
        session:WaitForBackgroundTasks()

        assert.is_true(#utils:Client():RefreshDiagnosticsCalls() > baselineRefreshCount)
    end)
end)

describe("project.Session language service for closed files", function()
    it("closed file in configured project not yet opened", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true,
						"strict": true
					},
					"include": ["src"]
				}]],
            ["/home/projects/TS/p1/src/index.ts"] = "export const x: number = 1;",
        }
        local session = projecttestutil.Setup(files)

        local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
        local sourceFile = program:GetSourceFile("/home/projects/TS/p1/src/index.ts")
        assert.is_not_nil(sourceFile)
        assert.are.equal("export const x: number = 1;", sourceFile:Text())
    end)

    it("jsconfig.json used for JS files when tsconfig.json exists in same directory", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = '{\n "compilerOptions": {\n "noLib": true,\n "strict": true\n }\n }',
            ["/home/projects/TS/p1/jsconfig.json"] = '{\n "compilerOptions": {\n "noLib": true,\n "checkJs": true\n }\n }',
            ["/home/projects/TS/p1/index.ts"] = "export const x: number = 1;",
            ["/home/projects/TS/p1/app.js"] = '/** @type {number} */ var y = "not a number";',
        }
        local session = projecttestutil.Setup(files)

        -- Open the JS file - it should be assigned to the jsconfig.json project, not tsconfig.json
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/app.js", 1, files["/home/projects/TS/p1/app.js"], lsproto.LanguageKind.JavaScript)

        local defaultProject = session:Snapshot():GetDefaultProject("file:///home/projects/TS/p1/app.js")
        assert.is_not_nil(defaultProject)
        assert.are.equal("/home/projects/TS/p1/jsconfig.json", defaultProject:Name())

        -- Open the TS file - it should be assigned to tsconfig.json project
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"], TS)

        local defaultTSProject = session:Snapshot():GetDefaultProject("file:///home/projects/TS/p1/index.ts")
        assert.is_not_nil(defaultTSProject)
        assert.are.equal("/home/projects/TS/p1/tsconfig.json", defaultTSProject:Name())
    end)
end)
