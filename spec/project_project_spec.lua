-- Ported from internal/project/project_test.go (TestProjectProgramUpdateKind, TestPushDiagnostics,
-- TestDisplayName, TestProgressNotifications). Configs add "noLib": true where the library is not
-- relevant to the test, since loading the default libraries is slow in the Lua port.
-- TestProject (typings installation) is not ported: automatic type acquisition is out of scope.
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local project = require("tslua.project")
local projecttestutil = require("tslua.testutil.projecttestutil")

local TS = lsproto.LanguageKind.TypeScript

local function getLS(session, uri)
    local ls, err = session:GetLanguageService(nil, uri)
    assert.is_nil(err)
    return ls
end

local function configured(session, path)
    return session:Snapshot().projectCollection:ConfiguredProject(path)
end

-- filterDiagnosticsByURI returns all PublishDiagnostics calls matching the given URI,
-- starting from the given (0-based) index.
local function filterDiagnosticsByURI(calls, uri, from)
    local result = {}
    for i = from + 1, #calls do
        if calls[i].params.uri == uri then
            result[#result + 1] = calls[i]
        end
    end
    return result
end

local function messageText(diag)
    local m = diag.message
    if type(m) == "string" then
        return m
    end
    if type(m) == "table" then
        if type(m.AsString) == "function" then
            return m:AsString()
        end
        return m.string or m.value or ""
    end
    return ""
end

local function hasMessage(diags, text)
    for _, d in ipairs(diags or {}) do
        if string.find(messageText(d), text, 1, true) then
            return true
        end
    end
    return false
end

describe("project ProgramUpdateKind #slow", function()
    it("NewFiles on initial build", function()
        local files = {
            ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        local p = configured(session, "/src/tsconfig.json")
        assert.is_not_nil(p)
        assert.are.equal(project.ProgramUpdateKind.NewFiles, p.programUpdateKind)
    end)

    it("Cloned on single-file change", function()
        local files = {
            ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/src/index.ts"] = "console.log('Hello');",
        }
        local session = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        session:DidChangeFile(nil, "file:///src/index.ts", 2, { {
            partial = { text = "\n", range = { start = { line = 0, character = 20 }, end_ = { line = 0, character = 20 } } },
        } })
        getLS(session, "file:///src/index.ts")
        assert.are.equal(project.ProgramUpdateKind.Cloned, configured(session, "/src/tsconfig.json").programUpdateKind)
    end)

    it("NewFiles when import resolution mode changes", function()
        local files = {
            ["/src/tsconfig.json"] = [[{
				"compilerOptions":{"module":"preserve","moduleResolution":"bundler","noEmit":true,"noLib":true},
				"files":["index.ts"]
			}]],
            ["/src/index.ts"] = 'import type { Value } from "pkg" with { "resolution-mode": "require" };\nconst value: Value = { mode: "require" };',
            ["/src/node_modules/pkg/package.json"] = [[{
				"name": "pkg",
				"version": "1.0.0",
				"exports": {
					".": {
						"import": "./index.mjs",
						"require": "./index.js"
					}
				}
			}]],
            ["/src/node_modules/pkg/index.d.mts"] = 'export interface Value { mode: "import" }',
            ["/src/node_modules/pkg/index.d.ts"] = 'export interface Value { mode: "require" }',
        }
        local session = projecttestutil.Setup(files)
        local uri = "file:///src/index.ts"
        local ctx = projecttestutil.WithRequestID(core.WithCancel(nil))
        session:DidOpenFile(nil, uri, 1, files["/src/index.ts"], TS)
        local program = getLS(session, uri):GetProgram()
        assert.are.equal(0, core.Len(program:GetSemanticDiagnostics(ctx, program:GetSourceFile("/src/index.ts"))))

        session:DidChangeFile(nil, uri, 2, { {
            wholeDocument = { text = 'import type { Value } from "pkg" with { "resolution-mode": "import" };\nconst value: Value = { mode: "require" };' },
        } })
        program = getLS(session, uri):GetProgram()
        local diags = program:GetSemanticDiagnostics(ctx, program:GetSourceFile("/src/index.ts"))
        assert.are.equal(1, core.Len(diags))
        assert.are.equal(diagnostics.Type_0_is_not_assignable_to_type_1:Code(), diags[1]:Code())

        assert.are.equal(project.ProgramUpdateKind.NewFiles, configured(session, "/src/tsconfig.json").programUpdateKind)
    end)

    it("SameFileNames on config change without root changes", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"strict": true, "noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        assert.is_nil(utils:FS():WriteFile("/src/tsconfig.json", '{"compilerOptions": {"strict": false, "noLib": true}}'))
        session:DidChangeWatchedFiles(nil, { { uri = "file:///src/tsconfig.json", type = lsproto.FileChangeType.Changed } })
        getLS(session, "file:///src/index.ts")
        assert.are.equal(project.ProgramUpdateKind.SameFileNames, configured(session, "/src/tsconfig.json").programUpdateKind)
    end)

    it("NewFiles on root addition", function()
        local files = {
            ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/src/index.ts"] = "export {}",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        local content = "export const y = 2;"
        assert.is_nil(utils:FS():WriteFile("/src/newfile.ts", content))
        session:DidChangeWatchedFiles(nil, { { uri = "file:///src/newfile.ts", type = lsproto.FileChangeType.Created } })
        session:DidOpenFile(nil, "file:///src/newfile.ts", 1, content, TS)
        getLS(session, "file:///src/newfile.ts")
        assert.are.equal(project.ProgramUpdateKind.NewFiles, configured(session, "/src/tsconfig.json").programUpdateKind)
    end)

    it("SameFileNames when adding an unresolvable import with multi-file change", function()
        local files = {
            ["/src/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/src/index.ts"] = "export const x = 1;",
            ["/src/other.ts"] = "export const z = 3;",
        }
        local session = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        session:DidChangeFile(nil, "file:///src/index.ts", 2, { {
            partial = { text = '\nimport "./does-not-exist";\n', range = { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } } },
        } })
        getLS(session, "file:///src/index.ts")
        assert.are.equal(project.ProgramUpdateKind.SameFileNames, configured(session, "/src/tsconfig.json").programUpdateKind)
    end)
end)

describe("project push diagnostics #slow", function()
    local tsconfigURI = "file:///src/tsconfig.json"

    local function openIndex(session, files)
        session:DidOpenFile(nil, "file:///src/index.ts", 1, files["/src/index.ts"], TS)
        getLS(session, "file:///src/index.ts")
        session:WaitForBackgroundTasks()
    end

    it("publishes program diagnostics on initial program creation", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"baseUrl": ".", "noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        local tsconfigCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, 0)
        assert.is_true(#tsconfigCalls > 0)
        assert.is_true(#tsconfigCalls[1].params.diagnostics > 0)
    end)

    it("publishes config parsing diagnostics on initial program creation", function()
        local files = {
            ["/src/tsconfig.json"] = '{\n "compilerOptions": {\n "target": "nope", "noLib": true\n }\n }',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        local tsconfigCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, 0)
        assert.is_true(#tsconfigCalls > 0)
        assert.is_true(hasMessage(tsconfigCalls[#tsconfigCalls].params.diagnostics, "Argument for '--target' option must be:"))
    end)

    it("clears diagnostics when project is removed", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"baseUrl": ".", "noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
            ["/src2/tsconfig.json"] = '{"compilerOptions": {"noLib": true}}',
            ["/src2/index.ts"] = "export const y = 2;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        -- Open a file in a different project to trigger cleanup of the first
        session:DidCloseFile(nil, "file:///src/index.ts")
        session:DidOpenFile(nil, "file:///src2/index.ts", 1, files["/src2/index.ts"], TS)
        getLS(session, "file:///src2/index.ts")
        session:WaitForBackgroundTasks()

        local firstProjectCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, 0)
        assert.is_true(#firstProjectCalls >= 2)
        -- Last call should clear diagnostics
        assert.are.equal(0, #firstProjectCalls[#firstProjectCalls].params.diagnostics)
    end)

    it("updates diagnostics when program changes", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"baseUrl": ".", "noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        local initialCallCount = #utils:Client():PublishDiagnosticsCalls()

        -- Change the tsconfig to remove baseUrl
        assert.is_nil(utils:FS():WriteFile("/src/tsconfig.json", '{"compilerOptions": {"noLib": true}}'))
        session:DidChangeWatchedFiles(nil, { { uri = tsconfigURI, type = lsproto.FileChangeType.Changed } })
        getLS(session, "file:///src/index.ts")
        session:WaitForBackgroundTasks()

        local calls = utils:Client():PublishDiagnosticsCalls()
        assert.is_true(#calls > initialCallCount)
        local tsconfigCalls = filterDiagnosticsByURI(calls, tsconfigURI, 0)
        -- After fixing the error, there should be no program diagnostics
        assert.are.equal(0, #tsconfigCalls[#tsconfigCalls].params.diagnostics)
    end)

    it("updates diagnostics when a config file changes on disk with no follow-up request", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        local callsBeforeChange = #utils:Client():PublishDiagnosticsCalls()

        assert.is_nil(utils:FS():WriteFile("/src/tsconfig.json", '{"compilerOptions": {"target": "nope", "noLib": true}}'))
        session:DidChangeWatchedFiles(nil, { { uri = tsconfigURI, type = lsproto.FileChangeType.Changed } })
        session:WaitForBackgroundTasks()

        local tsconfigCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, callsBeforeChange)
        assert.is_true(#tsconfigCalls > 0)
        assert.is_true(hasMessage(tsconfigCalls[#tsconfigCalls].params.diagnostics, "Argument for '--target' option must be:"))
    end)

    it("does not publish for inferred projects", function()
        local files = {
            ["/src/index.ts"] = "let x: number = 'not a number';",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)
        assert.are.equal(0, #utils:Client():PublishDiagnosticsCalls())
    end)

    it("does not publish when validation is disabled", function()
        local files = {
            ["/src/tsconfig.json"] = '{\n "compilerOptions": {\n "target": "nope", "noLib": true\n }\n }',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.enableValidation = core.Tristate.TSFalse
        session:Configure(prefs)
        openIndex(session, files)

        for _, call in ipairs(utils:Client():PublishDiagnosticsCalls()) do
            assert.are.equal(0, #call.params.diagnostics)
        end
    end)

    it("clears diagnostics when validation is disabled", function()
        local files = {
            ["/src/tsconfig.json"] = '{\n "compilerOptions": {\n "target": "nope", "noLib": true\n }\n }',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        openIndex(session, files)

        local tsconfigCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, 0)
        assert.is_true(#tsconfigCalls > 0)
        assert.is_true(#tsconfigCalls[#tsconfigCalls].params.diagnostics > 0)

        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.enableValidation = core.Tristate.TSFalse
        session:Configure(prefs)
        getLS(session, "file:///src/index.ts")
        session:WaitForBackgroundTasks()

        tsconfigCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, 0)
        assert.are.equal(0, #tsconfigCalls[#tsconfigCalls].params.diagnostics)
    end)

    it("cleans tsconfig diagnostics after TS files close and restores them after TS file is reopened", function()
        local files = {
            ["/src/tsconfig.json"] = '{"compilerOptions": {"baseUrl": ".", "noLib": true}}',
            ["/src/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        local uri = "file:///src/index.ts"
        openIndex(session, files)

        local calls = utils:Client():PublishDiagnosticsCalls()
        local tsconfigCalls = filterDiagnosticsByURI(calls, tsconfigURI, 0)
        assert.is_true(#tsconfigCalls > 0)
        assert.are.equal(1, #tsconfigCalls[1].params.diagnostics)

        local callsBeforeClose = #calls

        session:DidCloseFile(nil, uri)
        session:WaitForBackgroundTasks()

        -- Cleans up diagnostics after close
        calls = utils:Client():PublishDiagnosticsCalls()
        local clearCalls = filterDiagnosticsByURI(calls, tsconfigURI, callsBeforeClose)
        assert.is_true(#clearCalls > 0)
        assert.are.equal(0, #clearCalls[#clearCalls].params.diagnostics)

        local callsBeforeReopen = #calls

        session:DidOpenFile(nil, uri, 2, files["/src/index.ts"], TS)
        getLS(session, uri)
        session:WaitForBackgroundTasks()

        -- Restores diagnostics after reopen
        local reopenedCalls = filterDiagnosticsByURI(utils:Client():PublishDiagnosticsCalls(), tsconfigURI, callsBeforeReopen)
        assert.is_true(#reopenedCalls > 0)
        assert.are.equal(1, #reopenedCalls[#reopenedCalls].params.diagnostics)
    end)
end)

describe("project DisplayName #slow", function()
    it("configured project returns relative config path", function()
        local files = {
            ["/home/projects/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/index.ts"] = "export const x = 1;",
        }
        local session = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/index.ts", 1, "export const x = 1;", TS)
        getLS(session, "file:///home/projects/index.ts")
        local p = configured(session, "/home/projects/tsconfig.json")
        assert.is_not_nil(p)
        assert.are.equal("tsconfig.json", p:DisplayName("/home/projects"))
    end)

    it("configured project with nested config", function()
        local files = {
            ["/home/projects/sub/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/sub/index.ts"] = "export const x = 1;",
        }
        local session = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/sub/index.ts", 1, "export const x = 1;", TS)
        getLS(session, "file:///home/projects/sub/index.ts")
        local p = configured(session, "/home/projects/sub/tsconfig.json")
        assert.is_not_nil(p)
        assert.are.equal("sub/tsconfig.json", p:DisplayName("/home/projects"))
    end)

    it("inferred project returns directory base name", function()
        local files = {
            ["/home/projects/index.ts"] = "export const x = 1;",
        }
        local session = projecttestutil.SetupWithOptions(files, project.NewSessionOptions({
            currentDirectory = "/home/projects",
            defaultLibraryPath = bundled.LibPath(),
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            watchEnabled = true,
            loggingEnabled = true,
            pushDiagnosticsEnabled = true,
        }))
        session:DidOpenFile(nil, "file:///home/projects/index.ts", 1, "export const x = 1;", TS)
        getLS(session, "file:///home/projects/index.ts")
        local inferred = session:Snapshot().projectCollection:InferredProject()
        assert.is_not_nil(inferred)
        assert.are.equal("projects", inferred:DisplayName("/home"))
    end)
end)

describe("project progress notifications #slow", function()
    local function countProject0(calls)
        local n = 0
        for _, call in ipairs(calls) do
            if call.message == diagnostics.Project_0 then
                n = n + 1
            end
        end
        return n
    end

    it("emits progress for configured project loading", function()
        local files = {
            ["/home/projects/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/index.ts"] = "export const x = 1;",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/index.ts", 1, "export const x = 1;", TS)
        getLS(session, "file:///home/projects/index.ts")
        assert.is_true(countProject0(utils:Client():ProgressStartCalls()) > 0)
        assert.is_true(countProject0(utils:Client():ProgressFinishCalls()) > 0)
    end)

    it("each start has a matching finish", function()
        local files = {
            ["/home/projects/tsconfig.json"] = '{ "compilerOptions": { "noLib": true } }',
            ["/home/projects/a.ts"] = "export const a = 1;",
            ["/home/projects/b.ts"] = "export const b = 2;",
        }
        local session, utils = projecttestutil.Setup(files)
        session:DidOpenFile(nil, "file:///home/projects/a.ts", 1, "export const a = 1;", TS)
        getLS(session, "file:///home/projects/a.ts")
        assert.are.equal(countProject0(utils:Client():ProgressStartCalls()), countProject0(utils:Client():ProgressFinishCalls()))
    end)
end)
