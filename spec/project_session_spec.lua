-- Ported from internal/project/session_test.go (TestSession).
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local projecttestutil = require("tslua.testutil.projecttestutil")

local TS = lsproto.LanguageKind.TypeScript

local function clone(m)
    local c = {}
    for k, v in pairs(m) do
        c[k] = v
    end
    return c
end

local function partialChange(startLine, startChar, endLine, endChar, text)
    return {
        partial = {
            range = {
                start = { line = startLine, character = startChar },
                ["end"] = { line = endLine, character = endChar },
                end_ = { line = endLine, character = endChar },
            },
            text = text,
        },
    }
end

local function getProgram(session, uri)
    local ls, err = session:GetLanguageService(nil, uri)
    assert.is_nil(err)
    return ls:GetProgram()
end

local function fileEvent(changeType, uri)
    return { type = changeType, uri = uri }
end

local defaultFiles = {
    ["/home/projects/TS/p1/tsconfig.json"] = [[{
			"compilerOptions": {
				"noLib": true,
				"module": "nodenext",
				"strict": true
			},
			"include": ["src"]
		}]],
    ["/home/projects/TS/p1/src/index.ts"] = 'import { x } from "./x";',
    ["/home/projects/TS/p1/src/x.ts"] = "export const x = 1;",
    ["/home/projects/TS/p1/config.ts"] = "let x = 1, y = 2;",
}

describe("project.Session", function()
    describe("DidOpenFile", function()
        it("create configured project", function()
            local session = projecttestutil.Setup(defaultFiles)
            local snapshot = session:Snapshot()
            assert.are.equal(0, #snapshot.projectCollection:Projects())

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, defaultFiles["/home/projects/TS/p1/src/index.ts"], TS)

            snapshot = session:Snapshot()
            assert.are.equal(1, #snapshot.projectCollection:Projects())

            local configuredProject = snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json")
            assert.is_not_nil(configuredProject)

            -- Get language service to access the program
            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
            assert.are.equal("export const x = 1;", program:GetSourceFile("/home/projects/TS/p1/src/x.ts"):Text())
        end)

        it("create inferred project", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/config.ts", 1, defaultFiles["/home/projects/TS/p1/config.ts"], TS)

            -- Find tsconfig, load, notice config.ts is not included, create inferred project
            local snapshot = session:Snapshot()
            assert.are.equal(2, #snapshot.projectCollection:Projects())

            -- Should have both configured project (for tsconfig.json) and inferred project
            assert.is_not_nil(snapshot.projectCollection:ConfiguredProject("/home/projects/ts/p1/tsconfig.json"))
            assert.is_not_nil(snapshot.projectCollection:InferredProject())
        end)

        it("inferred project for in-memory files", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/config.ts", 1, defaultFiles["/home/projects/TS/p1/config.ts"], TS)
            session:DidOpenFile(nil, "untitled:Untitled-1", 1, "x", TS)
            session:DidOpenFile(nil, "untitled:Untitled-2", 1, "y", TS)

            local snapshot = session:Snapshot()

            assert.are.equal(1, #snapshot.projectCollection:Projects())
            assert.is_not_nil(snapshot.projectCollection:InferredProject())
        end)

        it("inferred project JS file", function()
            local jsFiles = {
                ["/home/projects/TS/p1/index.js"] = 'import { x } from "./x";',
            }
            local session = projecttestutil.Setup(jsFiles)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/index.js", 1, jsFiles["/home/projects/TS/p1/index.js"], lsproto.LanguageKind.JavaScript)

            local snapshot = session:Snapshot()
            assert.are.equal(1, #snapshot.projectCollection:Projects())

            local program = getProgram(session, "file:///home/projects/TS/p1/index.js")
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/index.js"))
        end)

        it("inferred project extensionless file", function()
            local files = {
                ["/home/projects/TS/p1/script"] = "const x = 1;",
            }
            local session = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/script", 1, files["/home/projects/TS/p1/script"], "plaintext")

            local snapshot = session:Snapshot()
            assert.are.equal(1, #snapshot.projectCollection:Projects())
            assert.is_not_nil(snapshot.projectCollection:InferredProject())

            local program = getProgram(session, "file:///home/projects/TS/p1/script")
            local file = program:GetSourceFile("/home/projects/TS/p1/script")
            assert.is_not_nil(file)
            assert.are.equal(core.ScriptKind.TS, file.scriptKind)
        end)
    end)

    it("watchChange and didOpen in same batch rebuilds program", function()
        local files = {
            ["/home/projects/TS/p1/tsconfig.json"] = [[{
				"compilerOptions": {
					"noLib": true,
					"strict": true
				}
			}]],
            ["/home/projects/TS/p1/src/a.ts"] = "export const a = 1;\n",
            ["/home/projects/TS/p1/src/b.ts"] = "export const b = 1;\n",
        }
        local session, utils = projecttestutil.Setup(files)
        local oldContent = files["/home/projects/TS/p1/src/a.ts"]

        -- Open b.ts to create the project; a.ts is included via tsconfig.
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/b.ts", 1, files["/home/projects/TS/p1/src/b.ts"], TS)

        -- Verify a.ts is in the program with the original content.
        assert.are.equal(oldContent, getProgram(session, "file:///home/projects/TS/p1/src/b.ts"):GetSourceFile("/home/projects/TS/p1/src/a.ts"):Text())

        -- Modify a.ts on disk (simulate a build tool or git checkout).
        local newContent = "export const a = 2;\nexport const extra = true;\n"
        assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/a.ts", newContent))

        -- Queue a watch event for the disk change (not flushed yet).
        session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/src/a.ts") })

        -- Open a.ts in the editor—flushes both watch event and didOpen together.
        session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/a.ts", 1, newContent, TS)

        -- The program's SourceFile must reflect the overlay (new) content.
        assert.are.equal(newContent, getProgram(session, "file:///home/projects/TS/p1/src/a.ts"):GetSourceFile("/home/projects/TS/p1/src/a.ts"):Text())
    end)

    describe("DidChangeFile", function()
        it("update file and program", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, defaultFiles["/home/projects/TS/p1/src/x.ts"], TS)

            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")

            session:DidChangeFile(nil, "file:///home/projects/TS/p1/src/x.ts", 2, { partialChange(0, 17, 0, 18, "2") })

            local programAfter = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")

            -- Program should change due to the file content change
            assert.are_not.equal(programBefore, programAfter)
            assert.are.equal("export const x = 2;", programAfter:GetSourceFile("/home/projects/TS/p1/src/x.ts"):Text())
        end)

        it("update untitled file", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "untitled:Untitled-1", 1, "let x = 1;", TS)

            local programBefore = getProgram(session, "untitled:Untitled-1")
            local untitledFileName = lsproto.DocumentUri_FileName("untitled:Untitled-1")
            assert.are.equal("let x = 1;", programBefore:GetSourceFile(untitledFileName):Text())

            session:DidChangeFile(nil, "untitled:Untitled-1", 2, { partialChange(0, 8, 0, 9, "2") })

            local programAfter = getProgram(session, "untitled:Untitled-1")

            assert.are_not.equal(programBefore, programAfter)
            assert.are.equal("let x = 2;", programAfter:GetSourceFile(untitledFileName):Text())
        end)

        it("unchanged source files are reused", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, defaultFiles["/home/projects/TS/p1/src/x.ts"], TS)

            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")
            local indexFileBefore = programBefore:GetSourceFile("/home/projects/TS/p1/src/index.ts")

            session:DidChangeFile(nil, "file:///home/projects/TS/p1/src/x.ts", 2, { partialChange(0, 0, 0, 0, ";") })

            local programAfter = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")

            -- Unchanged file should be reused
            assert.are.equal(indexFileBefore, programAfter:GetSourceFile("/home/projects/TS/p1/src/index.ts"))
        end)

        it("change can pull in new files", function()
            local files = clone(defaultFiles)
            files["/home/projects/TS/p1/y.ts"] = "export const y = 2;"
            local session = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            -- Verify y.ts is not initially in the program
            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_nil(programBefore:GetSourceFile("/home/projects/TS/p1/y.ts"))

            session:DidChangeFile(nil, "file:///home/projects/TS/p1/src/index.ts", 2, { partialChange(0, 0, 0, 0, 'import { y } from "../y";\n') })

            local programAfter = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")

            -- y.ts should now be included in the program
            assert.is_not_nil(programAfter:GetSourceFile("/home/projects/TS/p1/y.ts"))
        end)

        it("single-file change followed by config change reloads program", function()
            local files = clone(defaultFiles)
            files["/home/projects/TS/p1/tsconfig.json"] = [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true
				},
				"include": ["src/index.ts"]
			}]]
            local session, utils = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.are.equal(2, #programBefore:GetSourceFiles())

            session:DidChangeFile(nil, "file:///home/projects/TS/p1/src/index.ts", 2, { partialChange(0, 0, 0, 0, "\n") })

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/tsconfig.json", [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true
				},
				"include": ["./**/*"]
			}]]))

            session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/tsconfig.json") })

            local programAfter = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.are.equal(3, #programAfter:GetSourceFiles())
        end)
    end)

    describe("DidCloseFile", function()
        it("configured projects: delete a file, close it, recreate it", function()
            local files = clone(defaultFiles)
            local session, utils = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, files["/home/projects/TS/p1/src/x.ts"], TS)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/x.ts"))

            session:DidCloseFile(nil, "file:///home/projects/TS/p1/src/x.ts")
            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/x.ts", ""))

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, "", TS)

            program = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
            assert.are.equal("", program:GetSourceFile("/home/projects/TS/p1/src/x.ts"):Text())
        end)

        it("inferred projects: delete a file, close it, recreate it", function()
            local files = clone(defaultFiles)
            files["/home/projects/TS/p1/tsconfig.json"] = nil
            local session, utils = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, files["/home/projects/TS/p1/src/x.ts"], TS)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            assert.is_nil(utils:FS():Remove("/home/projects/TS/p1/src/x.ts"))

            session:DidCloseFile(nil, "file:///home/projects/TS/p1/src/x.ts")

            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.is_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/x.ts", ""))

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, "", TS)

            program = getProgram(session, "file:///home/projects/TS/p1/src/x.ts")
            assert.is_not_nil(program:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
            assert.are.equal("", program:GetSourceFile("/home/projects/TS/p1/src/x.ts"):Text())
        end)

        it("close untitled file", function()
            local session = projecttestutil.Setup(defaultFiles)

            session:DidOpenFile(nil, "untitled:Untitled-1", 1, "let x = 1;", TS)
            session:DidCloseFile(nil, "untitled:Untitled-1")
            session:DidOpenFile(nil, "untitled:Untitled-2", 1, "", TS)
        end)
    end)

    describe("DidSaveFile", function()
        for _, order in ipairs({ "save event first", "watch event first" }) do
            it(order, function()
                local session = projecttestutil.Setup(defaultFiles)
                session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, defaultFiles["/home/projects/TS/p1/src/index.ts"], TS)

                local snapshot = session:Snapshot()
                assert.are.equal(1, snapshot:ID())

                if order == "save event first" then
                    session:DidSaveFile(nil, "file:///home/projects/TS/p1/src/index.ts")
                end
                session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/src/index.ts") })
                if order == "watch event first" then
                    session:DidSaveFile(nil, "file:///home/projects/TS/p1/src/index.ts")
                end

                session:WaitForBackgroundTasks()
                snapshot = session:Snapshot()
                -- We didn't need a snapshot change, but the session overlays should be updated.
                assert.are.equal(1, snapshot:ID())

                -- Open another file to force a snapshot update so we can see the changes.
                session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, defaultFiles["/home/projects/TS/p1/src/x.ts"], TS)
                snapshot = session:Snapshot()
                assert.is_true(snapshot:GetFile("/home/projects/TS/p1/src/index.ts"):MatchesDiskText())
            end)
        end
    end)

    describe("Source file sharing", function()
        it("projects with similar options share source files", function()
            local files = clone(defaultFiles)
            files["/home/projects/TS/p2/tsconfig.json"] = [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true,
					"noCheck": true
				}
			}]]
            files["/home/projects/TS/p2/src/index.ts"] = 'import { x } from "../../p1/src/x";'
            local session = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)
            session:DidOpenFile(nil, "file:///home/projects/TS/p2/src/index.ts", 1, files["/home/projects/TS/p2/src/index.ts"], TS)

            local snapshot = session:Snapshot()
            assert.are.equal(2, #snapshot.projectCollection:Projects())

            local program1 = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            local program2 = getProgram(session, "file:///home/projects/TS/p2/src/index.ts")

            assert.are.equal(program1:GetSourceFile("/home/projects/TS/p1/src/x.ts"), program2:GetSourceFile("/home/projects/TS/p1/src/x.ts"))
        end)

        it("projects with different options do not share source files", function()
            local files = clone(defaultFiles)
            files["/home/projects/TS/p2/tsconfig.json"] = [[{
				"compilerOptions": {
					"noLib": true,
					"module": "nodenext",
					"strict": true,
					"moduleDetection": "auto"
				},
				"include": ["src"]
			}]]
            files["/home/projects/TS/p2/src/index.ts"] = 'import { x } from "../../p1/src/x";'
            local session = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)
            session:DidOpenFile(nil, "file:///home/projects/TS/p2/src/index.ts", 1, files["/home/projects/TS/p2/src/index.ts"], TS)

            local snapshot = session:Snapshot()
            assert.are.equal(2, #snapshot.projectCollection:Projects())

            local program1 = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            local program2 = getProgram(session, "file:///home/projects/TS/p2/src/index.ts")

            local x1 = program1:GetSourceFile("/home/projects/TS/p1/src/x.ts")
            local x2 = program2:GetSourceFile("/home/projects/TS/p1/src/x.ts")
            assert.is_not_nil(x1)
            assert.is_not_nil(x2)
            assert.are_not.equal(x1, x2)
        end)
    end)

    describe("DidChangeWatchedFiles", function()
        it("change open file", function()
            local files = clone(defaultFiles)
            local session, utils = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/x.ts", 1, files["/home/projects/TS/p1/src/x.ts"], TS)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/x.ts", "export const x = 2;"))

            session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/src/x.ts") })

            -- Program should remain the same since the file is open and changes are handled through DidChangeTextDocument
            assert.are.equal(programBefore, getProgram(session, "file:///home/projects/TS/p1/src/index.ts"))
        end)

        it("change closed program file", function()
            local files = clone(defaultFiles)
            local session, utils = projecttestutil.Setup(files)

            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/src/x.ts", "export const x = 2;"))

            session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/src/x.ts") })

            assert.are_not.equal(programBefore, getProgram(session, "file:///home/projects/TS/p1/src/index.ts"))
        end)

        for _, workspaceDir in ipairs({ "/", "/home/projects/TS/p1", "/somewhere/else/entirely" }) do
            it("change program file not in tsconfig root files (workspaceDir=" .. workspaceDir .. ")", function()
                local files = {
                    ["/home/projects/TS/p1/tsconfig.json"] = [[{
							"compilerOptions": {
								"noLib": true,
								"module": "nodenext",
								"strict": true
							},
							"files": ["src/index.ts"]
						}]],
                    ["/home/projects/TS/p1/src/index.ts"] = 'import { x } from "../../x";',
                    ["/home/projects/TS/x.ts"] = "export const x = 1;",
                }

                local session, utils = projecttestutil.SetupWithOptions(files, project.NewSessionOptions({
                    currentDirectory = workspaceDir,
                    defaultLibraryPath = bundled.LibPath(),
                    typingsLocation = projecttestutil.TestTypingsLocation,
                    positionEncoding = lsproto.PositionEncodingKind.UTF8,
                    watchEnabled = true,
                    loggingEnabled = true,
                }))
                session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)
                local programBefore = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
                session:WaitForBackgroundTasks()

                assert.is_true(utils:WatchesFile("/home/projects/ts/x.ts"))

                assert.is_nil(utils:FS():WriteFile("/home/projects/TS/x.ts", "export const x = 2;"))

                session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/x.ts") })

                assert.are_not.equal(programBefore, getProgram(session, "file:///home/projects/TS/p1/src/index.ts"))
            end)
        end

        it("change config file", function()
            local files = {
                ["/home/projects/TS/p1/tsconfig.json"] = [[{
					"compilerOptions": {
						"noLib": true,
						"strict": false
					}
				}]],
                ["/home/projects/TS/p1/src/x.ts"] = "export declare const x: number | undefined;",
                ["/home/projects/TS/p1/src/index.ts"] = [[
					import { x } from "./x";
					let y: number = x;]],
            }

            local session, utils = projecttestutil.Setup(files)
            session:DidOpenFile(nil, "file:///home/projects/TS/p1/src/index.ts", 1, files["/home/projects/TS/p1/src/index.ts"], TS)

            local program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            local ctx = projecttestutil.WithRequestID(core.WithCancel(nil))
            assert.are.equal(0, core.Len(program:GetSemanticDiagnostics(ctx, program:GetSourceFile("/home/projects/TS/p1/src/index.ts"))))

            assert.is_nil(utils:FS():WriteFile("/home/projects/TS/p1/tsconfig.json", [[{
				"compilerOptions": {
					"noLib": false,
					"strict": true
				}
			}]]))

            session:DidChangeWatchedFiles(nil, { fileEvent(lsproto.FileChangeType.Changed, "file:///home/projects/TS/p1/tsconfig.json") })

            program = getProgram(session, "file:///home/projects/TS/p1/src/index.ts")
            assert.are.equal(1, core.Len(program:GetSemanticDiagnostics(ctx, program:GetSourceFile("/home/projects/TS/p1/src/index.ts"))))
        end)
    end)
end)
