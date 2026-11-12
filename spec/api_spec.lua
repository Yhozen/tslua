-- Port of the internal/api tests: proto_test.go, jsonvalue_test.go, session_textedit_test.go,
-- session_temporary_test.go, session_completion_test.go, session_apistate_test.go, plus
-- protocol-level checks of the msgpack transport.
local api = require("tslua.api")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local ipc = require("tslua.ipc")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local lsproto = require("tslua.lsp.lsproto")
local packagejson = require("tslua.packagejson")
local parser = require("tslua.parser")
local projecttestutil = require("tslua.testutil.projecttestutil")

local function doc(fileName)
    return api.NewDocumentIdentifier(fileName)
end

-- P builds a params struct of the given Go type with Go zero values for omitted fields.
local function P(typeName, fields)
    local v = api.zeroValue(api.parseType(typeName))
    for k, x in pairs(fields or {}) do
        v[k] = x
    end
    return v
end

local function contains(list, x)
    for _, y in ipairs(list or {}) do
        if y == x then
            return true
        end
    end
    return false
end

describe("api proto", function()
    it("TestDocumentIdentifierUnmarshalJSON", function()
        local tests = {
            { name = "plain string", input = '"foo.ts"', fileName = "foo.ts" },
            { name = "uri object", input = '{"uri":"file:///foo.ts"}', uri = "file:///foo.ts" },
            { name = "uri object with unknown fields", input = '{"uri":"file:///foo.ts","extra":true}', uri = "file:///foo.ts" },
            { name = "empty object", input = "{}" },
            { name = "invalid type", input = "42", err = "expected string or object, got number" },
        }
        for _, tt in ipairs(tests) do
            local d, err = api.UnmarshalAs("DocumentIdentifier", tt.input)
            if tt.err ~= nil then
                assert.is_not_nil(err, tt.name)
                assert.is_truthy(string.find(jsonrpc.ErrorString(err), tt.err, 1, true), tt.name)
            else
                assert.is_nil(err, tt.name)
                assert.are.equal(tt.fileName or "", d.fileName, tt.name)
                assert.are.equal(tt.uri or "", d.uri, tt.name)
            end
        end
    end)

    it("TestNewDiagnosticResponseUsesUTF16Offsets", function()
        local text = "const 💩 = 1;"
        local file = parser.ParseSourceFile(ast.NewSourceFileParseOptions("/unicode.ts", "", ast.NewExternalModuleIndicatorOptions(false, false)), text, core.ScriptKind.TS)
        local pos = string.find(text, "=", 1, true) - 1
        assert.is_true(pos > 0)
        local end_ = pos + 1

        local diag = ast.NewDiagnostic(file, core.NewTextRange(pos, end_), diagnostics.Expression_expected)
        local resp = api.NewDiagnosticResponse(diag)

        assert.are.equal(9, resp.pos)
        assert.are.equal(10, resp.end_)
        assert.are.equal(file:GetPositionMap():UTF8ToUTF16(pos), resp.pos)
        assert.are.equal(file:GetPositionMap():UTF8ToUTF16(end_), resp.end_)
    end)

    it("TestJSONValueToAny", function()
        local value, err = api.UnmarshalAs("packagejson.JSONValue", '{"z":1,"a":{"y":2,"x":3},"m":[{"b":4,"a":5},null],"e":[]}')
        assert.is_nil(err)
        assert.are.equal(packagejson.JSONValueType.Object, value.type)

        local root = api.jsonValueToAny(value)
        assert.are.equal(collections.OrderedMap, getmetatable(root))
        assert.are.same({ "z", "a", "m", "e" }, root.keys)
        assert.are.equal(1.0, root:GetOrZero("z"))

        local nested = root:GetOrZero("a")
        assert.are.same({ "y", "x" }, nested.keys)

        local array = root:GetOrZero("m")
        local arrayObject = array[1]
        assert.are.same({ "b", "a" }, arrayObject.keys)
        assert.are.equal(json.Null, array[2])

        local empty = root:GetOrZero("e")
        assert.is_not_nil(empty)
        assert.are.equal(0, #empty)
    end)

    it("TestToAPITextEditsUsesOriginalCoordinates", function()
        local sourceFile = parser.ParseSourceFile(ast.NewSourceFileParseOptions("/app.vue", "/app.vue", ast.NewExternalModuleIndicatorOptions(false, false)), "const transformed = true;", core.ScriptKind.TS)
        sourceFile:SetContentMapperInfo({
            originalText = "😀\nabc",
            contentMapper = "mapper",
        })

        local edits = api.toAPITextEdits(sourceFile, { {
            range = { start = { line = 1, character = 1 }, end_ = { line = 1, character = 2 } },
            newText = "x",
        } })

        assert.are.equal(1, #edits)
        assert.are.equal(4, edits[1].pos)
        assert.are.equal(5, edits[1].end_)
        assert.are.equal("x", edits[1].newText)
    end)

    it("marshals structs with json/v2 omitempty and omitzero semantics", function()
        local s, err = api.MarshalAs("*TypeResponse", setmetatable({ id = 3, flags = 1 }, api.TypeResponse))
        assert.is_nil(err)
        assert.are.equal('{"id":3,"flags":1,"objectFlags":0,"value":null,"isThisType":false}', s)
        s = api.MarshalAs("[]*SymbolResponse", nil)
        assert.are.equal("[]", s)
        s = api.MarshalAs("[]*SymbolResponse", { json.Null })
        assert.are.equal("[null]", s)
    end)
end)

describe("api session", function()
    local function rpc(session, method, params)
        local raw = nil
        if params ~= nil then
            raw = jsonrpc.NewValue(params)
        end
        local result, err = session:HandleRequest(nil, method, raw)
        if err ~= nil then
            return nil, err
        end
        return json.Marshal(result)
    end

    it("TestUpdateTemporarySnapshot", function()
        local fileName = "/home/projects/p/src/index.ts"
        -- Valid content: no type errors.
        local content = "export const x: number = 1;"
        local projectSession = projecttestutil.Setup({
            ["/home/projects/p/tsconfig.json"] = '{ "compilerOptions": { "strict": true } }',
            [fileName] = content,
        })
        local session = api.NewSession(projectSession, nil)

        local baseResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
        assert.is_nil(err)
        assert.is_true(#baseResp.projects > 0)
        local projectID = baseResp.projects[1].id

        -- The base snapshot should be the session's latest snapshot.
        local baseHandle = baseResp.snapshot
        assert.are.equal(baseHandle, session.latestSnapshot)

        local function semanticDiags(snapshot, project)
            return session:handleGetSemanticDiagnostics(nil, P("GetDiagnosticsParams", {
                snapshot = snapshot, project = project, files = { doc(fileName) },
            }))
        end

        -- Sanity: the original content type-checks cleanly.
        local baseDiags
        baseDiags, err = semanticDiags(baseHandle, projectID)
        assert.is_nil(err)
        assert.are.equal(0, core.Len(baseDiags))

        -- Create a temporary snapshot whose content introduces a type error.
        local tempResp
        tempResp, err = session:handleUpdateTemporarySnapshot(nil, P("UpdateTemporarySnapshotParams", {
            snapshot = baseHandle, file = doc(fileName), newText = "export const x: string = 1;",
        }))
        assert.is_nil(err)
        assert.are_not.equal(baseHandle, tempResp.snapshot)

        -- The temporary snapshot must NOT become the session's latest snapshot.
        assert.are.equal(baseHandle, session.latestSnapshot)

        -- The temporary snapshot reflects the overridden content and reports the error.
        local tempDiags
        tempDiags, err = semanticDiags(tempResp.snapshot, tempResp.projects[1].id)
        assert.is_nil(err)
        assert.is_true(core.Len(tempDiags) > 0)

        -- The original snapshot is unaffected: still no errors.
        local again
        again, err = semanticDiags(baseHandle, projectID)
        assert.is_nil(err)
        assert.are.equal(0, core.Len(again))

        -- Releasing the temporary snapshot cleans it up without affecting the base.
        local _
        _, err = session:handleRelease(nil, P("ReleaseParams", { snapshot = tempResp.snapshot }))
        assert.is_nil(err)

        local final
        final, err = semanticDiags(baseHandle, projectID)
        assert.is_nil(err)
        assert.are.equal(0, core.Len(final))

        session:Close()
        projectSession:Close()
    end)

    it("TestUpdateTemporarySnapshotAddsUnopenedFile", function()
        local existingFileName = "/home/projects/p/src/index.ts"
        local temporaryFileName = "/home/projects/p/src/temporary.ts"
        local projectSession = projecttestutil.Setup({
            ["/home/projects/p/tsconfig.json"] = '{ "include": ["src/**/*.ts"] }',
            [existingFileName] = "export const existing = 1;",
        })
        local session = api.NewSession(projectSession, nil)

        local baseResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(existingFileName) } }))
        assert.is_nil(err)
        assert.are.equal(1, #baseResp.projects)
        assert.is_false(contains(baseResp.projects[1].rootFiles, temporaryFileName))

        local tempResp
        tempResp, err = session:handleUpdateTemporarySnapshot(nil, P("UpdateTemporarySnapshotParams", {
            snapshot = baseResp.snapshot, file = doc(temporaryFileName), newText = "export const temporary = 1;",
        }))
        assert.is_nil(err)
        assert.are.equal(1, #tempResp.projects)
        assert.is_true(contains(tempResp.projects[1].rootFiles, temporaryFileName))
        assert.is_false(contains(baseResp.projects[1].rootFiles, temporaryFileName))

        local _
        _, err = session:handleRelease(nil, P("ReleaseParams", { snapshot = tempResp.snapshot }))
        assert.is_nil(err)
        session:Close()
        projectSession:Close()
    end)

    it("TestUpdateTemporarySnapshotRejectsUnsupportedExtension", function()
        local projectSession = projecttestutil.Setup({})
        local session = api.NewSession(projectSession, nil)

        local baseResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams"))
        assert.is_nil(err)
        local _
        _, err = session:handleUpdateTemporarySnapshot(nil, P("UpdateTemporarySnapshotParams", {
            snapshot = baseResp.snapshot, file = doc("/home/projects/p/src/temporary.custom"), newText = "export const temporary = 1;",
        }))
        assert.is_not_nil(err)
        assert.is_truthy(string.find(jsonrpc.ErrorString(err), "unsupported file extension", 1, true))
        session:Close()
        projectSession:Close()
    end)

    it("TestUpdateTemporarySnapshotUsesClientSnapshotAsBase", function()
        local fileName = "/home/projects/p/src/index.ts"
        local laterFileName = "/home/projects/p/src/later.ts"
        local projectSession = projecttestutil.Setup({
            ["/home/projects/p/tsconfig.json"] = '{ "include": ["src/**/*.ts"] }',
            [fileName] = "export const existing = 1;",
        })
        local session = api.NewSession(projectSession, nil)

        local baseResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
        assert.is_nil(err)

        local laterURI = doc(laterFileName):ToURI(projectSession:GetCurrentDirectory())
        projectSession:DidOpenFile(nil, laterURI, 1, "export const later = 1;", lsproto.LanguageKind.TypeScript)

        local tempResp
        tempResp, err = session:handleUpdateTemporarySnapshot(nil, P("UpdateTemporarySnapshotParams", {
            snapshot = baseResp.snapshot, file = doc(fileName), newText = "export const existing = 2;",
        }))
        assert.is_nil(err)
        assert.are.equal(1, #tempResp.projects)
        assert.is_false(contains(tempResp.projects[1].rootFiles, laterFileName))

        local _
        _, err = session:handleRelease(nil, P("ReleaseParams", { snapshot = tempResp.snapshot }))
        assert.is_nil(err)
        session:Close()
        projectSession:Close()
    end)

    it("TestCompletionSymbolTypeIsResolvable", function()
        local fileName = "/home/projects/p/src/index.ts"
        -- The caret sits right after `people.`, requesting members of `string[]`.
        local content = "declare const people: string[];\npeople."
        local projectSession = projecttestutil.Setup({
            ["/home/projects/p/tsconfig.json"] = '{ "compilerOptions": { "strict": true } }',
            [fileName] = content,
        })
        local session = api.NewSession(projectSession, nil)

        local snapshotResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
        assert.is_nil(err)

        local proj
        proj, err = session:handleGetDefaultProjectForFile(nil, P("GetDefaultProjectForFileParams", {
            snapshot = snapshotResp.snapshot, file = doc(fileName),
        }))
        assert.is_nil(err)
        assert.is_not_nil(proj)

        local completions
        completions, err = session:handleGetCompletionsAtPosition(nil, P("GetCompletionsAtPositionParams", {
            snapshot = snapshotResp.snapshot, project = proj.id, file = doc(fileName),
            position = #content, includeSymbol = true,
        }))
        assert.is_nil(err)
        assert.is_not_nil(completions)

        local sawSymbol, sawPush = false, false
        for _, entry in ipairs(completions.entries) do
            if entry.symbol ~= nil then
                sawSymbol = true
                local typeResp
                typeResp, err = session:handleGetTypeOfSymbol(nil, P("GetTypeOfSymbolParams", {
                    snapshot = snapshotResp.snapshot, project = proj.id, symbol = entry.symbol.id,
                }))
                assert.is_nil(err)
                assert.is_not_nil(typeResp)
                if entry.name == "push" then
                    sawPush = true
                end
            end
        end
        assert.is_true(sawSymbol)
        assert.is_true(sawPush)
        session:Close()
        projectSession:Close()
    end)

    it("TestCompletionOnInferredProject", function()
        local fileName = "/home/projects/p/src/index.ts"
        local content = "declare const people: string[];\npeople."
        local projectSession = projecttestutil.Setup({ [fileName] = content })
        local session = api.NewSession(projectSession, nil)

        local snapshotResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
        assert.is_nil(err)

        local proj
        proj, err = session:handleGetDefaultProjectForFile(nil, P("GetDefaultProjectForFileParams", {
            snapshot = snapshotResp.snapshot, file = doc(fileName),
        }))
        assert.is_nil(err)
        assert.is_not_nil(proj)

        local completions
        completions, err = session:handleGetCompletionsAtPosition(nil, P("GetCompletionsAtPositionParams", {
            snapshot = snapshotResp.snapshot, project = proj.id, file = doc(fileName), position = #content,
        }))
        assert.is_nil(err)
        assert.is_not_nil(completions)
        session:Close()
        projectSession:Close()
    end)

    describe("TestSessionTracksAndReleasesAPIRefs", function()
        it("project opens are idempotent and released on close", function()
            local configFileName = "/home/projects/p/tsconfig.json"
            local projectSession = projecttestutil.Setup({
                [configFileName] = '{ "compilerOptions": { "strict": true } }',
                ["/home/projects/p/src/index.ts"] = "export const x = 1;",
            })
            local session = api.NewSession(projectSession, nil)

            local _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openProjects = { doc(configFileName) } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openProjects:Len())

            -- Opening the same project again must not take an additional ref.
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openProjects = { doc(configFileName) } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openProjects:Len())

            assert.is_not_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))

            -- Closing the session releases the single API ref, so the project is no
            -- longer kept loaded.
            session:Close()
            assert.are.equal(0, session.openProjects:Len())
            assert.is_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))
            projectSession:Close()
        end)

        it("explicit close releases the project ref", function()
            local configFileName = "/home/projects/p/tsconfig.json"
            local projectSession = projecttestutil.Setup({
                [configFileName] = '{ "compilerOptions": { "strict": true } }',
                ["/home/projects/p/src/index.ts"] = "export const x = 1;",
            })
            local session = api.NewSession(projectSession, nil)

            local _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openProjects = { doc(configFileName) } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openProjects:Len())
            assert.is_not_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))

            -- Closing a project we hold releases the ref and unloads the project.
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { closeProjects = { doc(configFileName) } }))
            assert.is_nil(err)
            assert.are.equal(0, session.openProjects:Len())
            assert.is_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))

            -- Closing a project we don't hold is a no-op (never over-releases).
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { closeProjects = { doc(configFileName) } }))
            assert.is_nil(err)
            assert.are.equal(0, session.openProjects:Len())
            session:Close()
            projectSession:Close()
        end)

        it("file opens are idempotent and released on close", function()
            local fileName = "/home/projects/p/src/index.ts"
            local configFileName = "/home/projects/p/tsconfig.json"
            local projectSession = projecttestutil.Setup({
                [configFileName] = '{ "compilerOptions": { "strict": true } }',
                [fileName] = "export const x = 1;",
            })
            local session = api.NewSession(projectSession, nil)

            local _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openFiles:Len())

            -- Re-opening the same file must not take an additional ref.
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc(fileName) } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openFiles:Len())

            -- The file should resolve to the configured project via ancestor search.
            assert.is_not_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))

            -- Closing a file we don't hold is a no-op (never over-releases).
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { closeFiles = { doc("/home/projects/p/other.ts") } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openFiles:Len())

            -- Explicitly closing the held file releases the ref.
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { closeFiles = { doc(fileName) } }))
            assert.is_nil(err)
            assert.are.equal(0, session.openFiles:Len())

            -- Closing the file also tears down the configured project that was
            -- auto-loaded to serve it, instead of leaking it.
            assert.is_nil(projectSession:Snapshot().projectCollection:ConfiguredProject(configFileName))

            session:Close()
            assert.are.equal(0, session.openFiles:Len())
            projectSession:Close()
        end)

        it("relative file paths normalize consistently for open and close", function()
            local projectSession = projecttestutil.Setup({
                ["/src/tsconfig.json"] = '{ "compilerOptions": { "strict": true } }',
                ["/src/index.ts"] = "export const x = 1;",
            })
            local session = api.NewSession(projectSession, nil)

            -- Open via a relative path; it should be tracked under the absolute path
            -- and resolve to the containing configured project.
            local openResp, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc("src/index.ts") } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openFiles:Len())
            assert.is_true(session.openFiles:Has("/src/index.ts"))
            assert.is_not_nil(projectSession:Snapshot().projectCollection:ConfiguredProject("/src/tsconfig.json"))

            -- getDefaultProjectForFile must also resolve a relative path to the same
            -- configured project (it builds a URI from the identifier internally).
            local proj
            proj, err = session:handleGetDefaultProjectForFile(nil, P("GetDefaultProjectForFileParams", {
                snapshot = openResp.snapshot, file = doc("src/index.ts"),
            }))
            assert.is_nil(err)
            assert.is_not_nil(proj)
            assert.are.equal("/src/tsconfig.json", proj.configFileName)

            -- Re-opening via the absolute path must match the relative open (no new ref).
            local _
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openFiles = { doc("/src/index.ts") } }))
            assert.is_nil(err)
            assert.are.equal(1, session.openFiles:Len())

            -- Closing via a relative path must match the path stored when opening.
            _, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { closeFiles = { doc("src/index.ts") } }))
            assert.is_nil(err)
            assert.are.equal(0, session.openFiles:Len())
            assert.is_nil(projectSession:Snapshot().projectCollection:ConfiguredProject("/src/tsconfig.json"))
            session:Close()
            projectSession:Close()
        end)
    end)

    it("TestUpdateSnapshotResponseSkipsUnloadedAncestorProject", function()
        local nestedConfigFileName = "/repo/packages/app/tsconfig.json"
        local ancestorConfigFileName = "/repo/packages/tsconfig.json"
        local fileName = "/repo/packages/app/src/index.ts"
        local files = {
            [ancestorConfigFileName] = '{ "files": [] }',
            [nestedConfigFileName] = '{\n\t\t\t"compilerOptions": { "composite": true },\n\t\t\t"include": ["**/*"]\n\t\t}',
            [fileName] = "let s: string = 1234;",
        }
        local projectSession = projecttestutil.Setup(files)

        projectSession:DidOpenFile(nil, "file://" .. fileName, 1, files[fileName], lsproto.LanguageKind.TypeScript)
        local snapshot = projectSession:Snapshot()
        local nestedProject = snapshot.projectCollection:ConfiguredProject(nestedConfigFileName)
        assert.is_not_nil(nestedProject)
        assert.is_not_nil(nestedProject.commandLine)
        local ancestorProject = snapshot.projectCollection:ConfiguredProject(ancestorConfigFileName)
        assert.is_not_nil(ancestorProject)
        assert.is_nil(ancestorProject.commandLine)

        local session = api.NewSession(projectSession, nil)

        local response, err = session:handleUpdateSnapshot(nil, P("UpdateSnapshotParams", { openProjects = { doc(nestedConfigFileName) } }))
        assert.is_nil(err)

        local foundNestedProject, foundAncestorProject = false, false
        for _, p in ipairs(response.projects) do
            if p.configFileName == nestedConfigFileName then
                foundNestedProject = true
                assert.is_not_nil(p.rootFiles)
                assert.is_not_nil(p.compilerOptions)
            elseif p.configFileName == ancestorConfigFileName then
                foundAncestorProject = true
            end
        end
        assert.is_true(foundNestedProject)
        assert.is_false(foundAncestorProject)
        session:Close()
        projectSession:Close()
    end)

    it("serves checker queries through HandleRequest", function()
        local fileName = "/home/projects/p/src/index.ts"
        local projectSession = projecttestutil.Setup({
            ["/home/projects/p/tsconfig.json"] = '{ "compilerOptions": { "strict": true } }',
            [fileName] = "export const x: number = 1;\nexport function f(a: string) { return a; }",
        })
        local session = api.NewSession(projectSession, nil)

        assert.are.equal('"pong"', (rpc(session, "ping")))
        local init = json.Unmarshal((rpc(session, "initialize")))
        assert.are.equal("/", init.currentDirectory)

        local snap = json.Unmarshal((rpc(session, "updateSnapshot", '{"openFiles":["' .. fileName .. '"]}')))
        local pid = snap.projects[1].id
        local base = string.format('"snapshot":%d,"project":"%s"', math.tointeger(snap.snapshot), pid)

        local sym = json.Unmarshal((rpc(session, "getSymbolAtPosition", "{" .. base .. ',"file":"' .. fileName .. '","position":13}')))
        assert.are.equal("x", sym.name)
        local ty = json.Unmarshal((rpc(session, "getTypeOfSymbol", "{" .. base .. ',"symbol":' .. math.tointeger(sym.id) .. "}")))
        assert.are.equal("number", ty.intrinsicName)
        assert.are.equal('"number"', (rpc(session, "typeToString", "{" .. base .. ',"type":' .. math.tointeger(ty.id) .. "}")))

        -- Node handles round-trip through resolveNodeHandle.
        local declType = json.Unmarshal((rpc(session, "getTypeAtLocation", "{" .. base .. ',"location":"' .. sym.declarations[1] .. '"}')))
        assert.are.equal(ty.id, declType.id)

        local names = json.Unmarshal((rpc(session, "getSourceFileNames", "{" .. base .. "}")))
        assert.is_true(contains(names, fileName))

        local sf = json.Unmarshal((rpc(session, "getSourceFile", "{" .. base .. ',"file":"' .. fileName .. '"}')))
        assert.is_true(#sf.data > 0)

        local _, err = rpc(session, "getSymbolAtLocation", "{" .. base .. ',"location":"bogus"}')
        assert.is_truthy(string.find(jsonrpc.ErrorString(err), "api: client error: invalid node handle", 1, true))
        _, err = rpc(session, "noSuchMethod", "{}")
        assert.is_truthy(string.find(jsonrpc.ErrorString(err), "api: invalid request: unknown API method", 1, true))

        session:Close()
        projectSession:Close()
    end)
end)

describe("api msgpack protocol", function()
    local function bin(s)
        assert(#s < 256)
        return string.char(0xC4, #s) .. s
    end

    it("round-trips requests and responses over a sync connection", function()
        local projectSession = projecttestutil.Setup({})
        local session = api.NewSession(projectSession, { useBinaryResponses = true })
        local client, server = ipc.Pipe()
        local input = table.concat({
            string.char(0x93, api.MessageType.Request) .. bin("ping") .. bin(""),
            string.char(0x93, api.MessageType.Request) .. bin("echo") .. bin("raw\0bytes"),
        })
        client:Write(input)
        local conn = ipc.NewSyncConn(server, api.NewMessagePackProtocol(server), session)
        local err = conn:Run(nil)
        assert.is_nil(err)
        local out = client.buf
        local expected = string.char(0x93, api.MessageType.Response) .. bin("ping") .. bin('"pong"') ..
            string.char(0x93, api.MessageType.Response) .. bin("echo") .. bin("raw\0bytes")
        assert.are.equal(expected, out)
        session:Close()
        projectSession:Close()
    end)

    it("rejects malformed tuples", function()
        local client, server = ipc.Pipe()
        client:Write(string.char(0x92, 1))
        client:Close()
        local _, err = api.NewMessagePackProtocol(server):ReadMessage()
        assert.is_true(jsonrpc.ErrorsIs(err, api.ErrInvalidRequest))
    end)
end)
