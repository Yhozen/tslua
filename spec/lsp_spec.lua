-- Ports of the internal/lsp tests that do not need real concurrency: dynamic_queue_test,
-- stack_sanitizer_test, progress_test (with a fake clock instead of testing/synctest),
-- server_test, server_contentmapper_internal_test, server_projectinfo_test (through
-- lsptestutil) and the fake-backend tests of lspwatcher/lspwatcher_test.
local lsp = require("tslua.lsp")
local lspwatcher = require("tslua.lsp.lspwatcher")
local lsproto = require("tslua.lsp.lsproto")
local lsptestutil = require("tslua.testutil.lsptestutil")
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local fswatch = require("tslua.fswatch")
local jsonrpc = require("tslua.jsonrpc")
local locale = require("tslua.locale")
local logging = require("tslua.project.logging")
local vfstest = require("tslua.vfs.vfstest")

local function stringWriter()
    local w = { parts = {} }
    function w:WriteString(s)
        self.parts[#self.parts + 1] = s
        return #s, nil
    end
    function w:String()
        return table.concat(self.parts)
    end
    return w
end

local discard = { Write = function(_, s)
    return #s, nil
end }

describe("lsp dynamicQueue #slow", function()
    it("is FIFO", function()
        local q = lsp.newDynamicQueue()
        for i = 0, 999 do
            assert.is_nil(q:Put(nil, i))
        end
        for i = 0, 999 do
            local got, err = q:Get(nil)
            assert.is_nil(err)
            assert.are.equal(i, got)
        end
    end)

    it("Get fails on a canceled context", function()
        local ctx, cancel = core.WithCancel(nil)
        cancel()
        local q = lsp.newDynamicQueue()
        local got, err = q:Get(ctx)
        assert.is_true(jsonrpc.ErrorsIs(err, core.Canceled))
        assert.is_nil(got)
    end)
end)

describe("lsp stack sanitizer #slow", function()
    local dir = "vendor/typescript-go/testdata/baselines/reference/lsp/stackSanitizer/"
    for _, name in ipairs({ "completionsDebugStackTrace.md", "completionsReleaseStackTrace.md", "genericSecretWorkaround.md" }) do
        it(name, function()
            local f = assert(io.open(dir .. name, "rb"))
            local baseline = f:read("a")
            f:close()
            local input, output = string.match(baseline, "# Unsanitized input:\n\n````\n(.-)\n````\n\n# Sanitized output:\n\n````\n(.-)\n````\n$")
            assert.is_not_nil(input)
            assert.are.equal(output, lsp.sanitizeStackTrace(input))
        end)
    end

end)

describe("lsp progress #slow", function()
    local function newReporter()
        local ctx, cancel = core.WithCancel(nil)
        local r = { calls = {}, clock = 0, ctx = ctx, cancel = cancel }
        function r:done()
            return core.ContextErr(self.ctx) ~= nil
        end
        function r:localize(msg, ...)
            return msg:Localize(locale.Default, ...)
        end
        function r:createWorkDoneProgress(token)
            self.calls[#self.calls + 1] = { method = "create", token = token }
        end
        function r:sendProgress(token, value)
            if value.begin ~= nil then
                self.calls[#self.calls + 1] = { method = "begin", token = token, title = value.begin.title, msg = value.begin.message or "" }
            elseif value.report ~= nil then
                self.calls[#self.calls + 1] = { method = "report", token = token, msg = value.report.message or "" }
            elseif value.end_ ~= nil then
                self.calls[#self.calls + 1] = { method = "end", token = token }
            end
        end
        function r:now()
            return self.clock
        end
        return r
    end

    -- time.Sleep(d); synctest.Wait()
    local function sleep(r, p, d)
        r.clock = r.clock + d
        p:poll()
    end

    it("StartFinishBeforeDelay", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.5)
        p:start(diagnostics.Project_0, "myProject")
        p:finish(diagnostics.Project_0, "myProject")
        sleep(r, p, 0.6)
        assert.are.equal(0, #r.calls)
    end)

    it("ShowsAfterDelay", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.5)
        p:start(diagnostics.Project_0, "myProject")
        sleep(r, p, 0.5)
        assert.are.equal(2, #r.calls)
        assert.are.equal("create", r.calls[1].method)
        assert.are.equal("begin", r.calls[2].method)
        assert.are.equal(diagnostics.Loading:String(), r.calls[2].title)
        p:finish(diagnostics.Project_0, "myProject")
        assert.are.equal("end", r.calls[#r.calls].method)
    end)

    it("ReportsMultipleOperations", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.1)
        p:start(diagnostics.Project_0, "projA")
        p:start(diagnostics.Project_0, "projB")
        sleep(r, p, 0.1)
        assert.are.equal("create", r.calls[1].method)
        assert.are.equal("begin", r.calls[2].method)
        p:finish(diagnostics.Project_0, "projA")
        local found = false
        for _, c in ipairs(r.calls) do
            found = found or c.method == "report"
        end
        assert.is_true(found)
        p:finish(diagnostics.Project_0, "projB")
        assert.are.equal("end", r.calls[#r.calls].method)
    end)

    it("RefCounting", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.1)
        p:start(diagnostics.Project_0, "proj")
        p:start(diagnostics.Project_0, "proj")
        sleep(r, p, 0.1)
        p:finish(diagnostics.Project_0, "proj")
        for _, c in ipairs(r.calls) do
            assert.are_not.equal("end", c.method)
        end
        p:finish(diagnostics.Project_0, "proj")
        assert.are.equal("end", r.calls[#r.calls].method)
    end)

    it("NewTokenAfterEnd", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.1)
        p:start(diagnostics.Project_0, "proj")
        sleep(r, p, 0.1)
        local firstToken = r.calls[1].token
        p:finish(diagnostics.Project_0, "proj")
        p:start(diagnostics.Project_0, "proj2")
        sleep(r, p, 0.1)
        local secondToken
        for _, c in ipairs(r.calls) do
            if c.method == "create" and c.token ~= firstToken then
                secondToken = c.token
                break
            end
        end
        assert.is_not_nil(secondToken)
        p:finish(diagnostics.Project_0, "proj2")
    end)

    it("StartBeforeDelayThenMoreAfterDelay", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.2)
        p:start(diagnostics.Project_0, "projA")
        sleep(r, p, 0.2)
        assert.is_true(#r.calls >= 2)
        p:start(diagnostics.Project_0, "projB")
        assert.are.equal("report", r.calls[#r.calls].method)
        p:finish(diagnostics.Project_0, "projA")
        p:finish(diagnostics.Project_0, "projB")
    end)

    it("FinishWithNoActiveToken", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.1)
        p:finish(diagnostics.Project_0, "proj")
        assert.are.equal(0, #r.calls)
    end)

    it("ShutdownDuringStartAndFinish", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.1)
        r.cancel()
        p:start(diagnostics.Project_0, "proj")
        p:finish(diagnostics.Project_0, "proj")
        assert.are.equal(0, #r.calls)
    end)

    it("ZeroDelay", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0)
        p:start(diagnostics.Project_0, "proj")
        assert.are.equal(2, #r.calls)
        assert.are.equal("create", r.calls[1].method)
        assert.are.equal("begin", r.calls[2].method)
        assert.are.equal("Project 'proj'", r.calls[2].msg)
        p:finish(diagnostics.Project_0, "proj")
        assert.are.equal("end", r.calls[#r.calls].method)
    end)

    it("FinishBeforeDelayNoBegun", function()
        local r = newReporter()
        local p = lsp.newProjectLoadingProgressFromReporter(r, 0.5)
        p:start(diagnostics.Project_0, "proj")
        p:finish(diagnostics.Project_0, "proj")
        for _, c in ipairs(r.calls) do
            assert.are_not.equal("end", c.method)
        end
    end)
end)

describe("lsp server #slow", function()
    local function shutdownTestReader()
        return { Read = function()
            return nil, jsonrpc.EOF
        end }
    end

    it("outgoing queue does not block without a writer", function()
        local server = lsp.NewServer({
            in_ = shutdownTestReader(),
            out = { Write = function()
                return nil
            end },
            err = discard,
            cwd = "/test",
        })
        local msg = lsproto.WindowLogMessageInfo:NewNotificationMessage(lsproto.LogMessageParams({
            type = lsproto.MessageType.Info,
            message = "queued",
        })):Message()
        for _ = 1, 1000 do
            assert.is_nil(server:send(msg))
        end
    end)

    it("write loop recovers from an unserializable response", function()
        local written = {}
        local server = lsp.NewServer({
            in_ = shutdownTestReader(),
            out = lsp.ToWriter({ Write = function(_, s)
                written[#written + 1] = s
                return #s, nil
            end }),
            err = discard,
            cwd = "/test",
        })

        -- A selection range whose parent chain is far deeper than the JSON encoder's nesting limit.
        local deep
        for _ = 1, 20000 do
            deep = { parent = deep }
        end
        local badID = jsonrpc.NewIDString("bad")
        assert.is_nil(server:send(lsproto.NewResponseMessage(badID, { deep }, nil, "*[]*SelectionRange"):Message()))
        local goodID = jsonrpc.NewIDString("good")
        assert.is_nil(server:send(lsproto.NewResponseMessage(goodID, lsproto.SelectionRangesOrNull({}), nil, "*SelectionRangesOrNull"):Message()))

        local r = lsproto.NewBaseReader((function()
            local data = table.concat(written)
            local pos = 1
            return { read = function(_, fmt)
                if pos > #data then
                    return nil
                end
                if fmt == "L" then
                    local nl = string.find(data, "\n", pos, true) or #data
                    local line = string.sub(data, pos, nl)
                    pos = nl + 1
                    return line
                end
                local chunk = string.sub(data, pos, pos + fmt - 1)
                pos = pos + #chunk
                return chunk
            end }
        end)())
        local sawError, sawGood = false, false
        for _ = 1, 2 do
            local data, err = r:Read()
            assert.is_nil(err)
            local msg = lsproto.NewMessage()
            assert.is_nil(msg:UnmarshalJSON(data))
            local resp = msg:AsResponse()
            if resp.id:String() == "bad" then
                assert.is_not_nil(resp.error)
                assert.are.equal(lsproto.ErrorCode.InternalError, resp.error.code)
                sawError = true
            elseif resp.id:String() == "good" then
                assert.is_nil(resp.error)
                sawGood = true
            end
        end
        assert.is_true(sawError)
        assert.is_true(sawGood)
        assert.is_nil(server.fatalErr)
    end)

    it("content mapper logger requires trace", function()
        local output = stringWriter()
        local server = setmetatable({ stderr = output, initStarted = false }, lsp.Server)
        server.logger = lsp.newLogger(server)
        local logger = server:contentMapperLogger()
        logger("hidden")
        assert.are.equal("", output:String())
        server.logger:SetVerbosity(lsproto.LogVerbosity.Trace)
        logger("visible")
        assert.is_truthy(string.find(output:String(), "visible", 1, true))
    end)

    it("parses content mapper contributions", function()
        local contributions, err = lsp.parseContentMapperContributions({
            lsproto.ContentMapperContribution({
                contributorId = "publisher.extension",
                extensions = { ".vue" },
                inferredProjectContribution = lsproto.InferredProjectContentMapperContribution({
                    options = { mode = "embedded" },
                    manifest = lsproto.ContentMapperManifest({
                        name = "Vue mapper",
                        version = "2.3.4",
                        exec = { "node", "mapper.js" },
                        cwd = "/workspace/mapper",
                        compilerOptions = { "strict" },
                    }),
                }),
            }),
            lsproto.ContentMapperContribution({
                contributorId = "publisher.extension",
                extensions = { ".svelte" },
            }),
        })
        assert.is_nil(err)
        assert.are.equal(1, #contributions.mappers)
        assert.are.same({ ".vue" }, contributions.extensions)
        local mapper = contributions.mappers[1]
        assert.are.equal("publisher.extension[0] (Vue mapper@2.3.4)", mapper:Identity())
        assert.are.equal("/workspace/mapper", mapper.packageDirectory)
        assert.are.equal('{"mode":"embedded"}', mapper.options)
    end)

    it("rejects conflicting inline content mappers", function()
        local function inferred(name)
            return lsproto.InferredProjectContentMapperContribution({ manifest = lsproto.ContentMapperManifest({ name = name, exec = { name } }) })
        end
        local _, err = lsp.parseContentMapperContributions({
            lsproto.ContentMapperContribution({ contributorId = "first", extensions = { ".vue" }, inferredProjectContribution = inferred("first") }),
            lsproto.ContentMapperContribution({ contributorId = "second", extensions = { ".vue" }, inferredProjectContribution = inferred("second") }),
        })
        assert.is_truthy(string.find(jsonrpc.ErrorString(err), 'both claim extension ".vue"', 1, true))
    end)

    it("defaults content mapper options to an object", function()
        local contributions, err = lsp.parseContentMapperContributions({
            lsproto.ContentMapperContribution({
                contributorId = "publisher.extension",
                extensions = { ".vue" },
                inferredProjectContribution = lsproto.InferredProjectContentMapperContribution({
                    manifest = lsproto.ContentMapperManifest({ name = "mapper", exec = { "mapper" } }),
                }),
            }),
        })
        assert.is_nil(err)
        assert.are.equal("{}", contributions.mappers[1].options)
    end)
end)

describe("lsp server end to end #slow", function()
    local function initProjectInfoClient(files)
        local fs = bundled.WrapFS(vfstest.FromMap(files, false))
        local function onServerRequest(_, req)
            if req.method == lsproto.Method.ClientRegisterCapability or req.method == lsproto.Method.ClientUnregisterCapability or req.method == lsproto.Method.WindowWorkDoneProgressCreate then
                return lsproto.NewResponseMessage(req.id, lsproto.Null, nil, "Null")
            end
            return nil
        end
        local client, closeClient = lsptestutil.NewLSPClient(nil, {
            err = discard,
            cwd = "/home/projects",
            fs = fs,
            defaultLibraryPath = bundled.LibPath(),
        }, onServerRequest)
        local initMsg, _, ok = lsptestutil.SendRequest(nil, client, lsproto.InitializeInfo, lsproto.InitializeParams({
            capabilities = lsproto.ClientCapabilities({}),
        }))
        assert.is_true(ok)
        assert.is_nil(initMsg:AsResponse().error)
        lsptestutil.SendNotification(nil, client, lsproto.InitializedInfo, lsproto.InitializedParams({}))
        client:Drain()
        assert.is_true(client.Server:InitComplete())
        return client, closeClient
    end

    local function projectInfo(files)
        local client, closeClient = initProjectInfoClient(files)
        local uri = "file:///home/projects/index.ts"
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = uri, languageId = "typescript", text = "export const x = 1;" }),
        }))
        local msg, resp, ok = lsptestutil.SendRequest(nil, client, lsproto.CustomProjectInfoInfo, lsproto.ProjectInfoParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = uri }),
        }))
        assert.is_true(ok)
        assert.is_nil(msg:AsResponse().error)
        assert.is_nil(closeClient())
        return resp
    end

    it("project info for a configured project", function()
        local resp = projectInfo({
            ["/home/projects/tsconfig.json"] = "{}",
            ["/home/projects/index.ts"] = "export const x = 1;",
        })
        assert.are.equal("/home/projects/tsconfig.json", resp.configFilePath)
    end)

    it("project info for an inferred project", function()
        local resp = projectInfo({
            ["/home/projects/index.ts"] = "export const x = 1;",
        })
        assert.are.equal("", resp.configFilePath)
    end)

    it("rejects requests before initialize and unknown methods", function()
        local client, closeClient = lsptestutil.NewLSPClient(nil, {
            err = discard,
            cwd = "/home/projects",
            fs = bundled.WrapFS(vfstest.FromMap({}, false)),
            defaultLibraryPath = bundled.LibPath(),
        }, nil)
        local reqID = jsonrpc.NewIDInt(client:NextID())
        local resp, ok = client:SendRequestWorker(nil, lsproto.ShutdownInfo:NewRequestMessage(reqID, lsproto.NoParams), reqID)
        assert.is_true(ok)
        assert.are.equal(lsproto.ErrorCode.ServerNotInitialized, resp.error.code)
        assert.are.equal("ServerNotInitialized", resp.error.message)
        assert.is_nil(closeClient())
    end)
end)

describe("lsp language features end to end #slow", function()
    local lsutil = require("tslua.ls.lsutil")
    local lsconv = require("tslua.ls.lsconv")

    local function initClient(files, caps, prefs)
        local fs = bundled.WrapFS(vfstest.FromMap(files, false))
        local function onServerRequest(_, req)
            if req.method == lsproto.Method.WorkspaceConfiguration then
                return lsproto.NewResponseMessage(req.id, { prefs }, nil)
            elseif req.method == lsproto.Method.ClientRegisterCapability or req.method == lsproto.Method.ClientUnregisterCapability then
                return lsproto.NewResponseMessage(req.id, lsproto.Null, nil, "Null")
            end
            return nil
        end
        local client, closeClient = lsptestutil.NewLSPClient(nil, {
            err = discard,
            cwd = "/home/projects",
            fs = fs,
            defaultLibraryPath = bundled.LibPath(),
        }, onServerRequest)
        local initMsg, _, ok = lsptestutil.SendRequest(nil, client, lsproto.InitializeInfo, lsproto.InitializeParams({
            capabilities = caps or lsproto.ClientCapabilities({}),
        }))
        assert.is_true(ok and initMsg:AsResponse().error == nil)
        lsptestutil.SendNotification(nil, client, lsproto.InitializedInfo, lsproto.InitializedParams({}))
        client:Drain()
        assert.is_true(client.Server:InitComplete())
        if prefs ~= nil then
            lsptestutil.SendNotification(nil, client, lsproto.WorkspaceDidChangeConfigurationInfo, lsproto.DidChangeConfigurationParams({
                settings = { typescript = prefs },
            }))
        end
        return client, closeClient
    end

    it("semantic tokens with CRLF overlay (TestSemanticTokensCRLF)", function()
        local fileOnDisk = "var x\nvar x\nvar x\nvar x\nvar x\nvar x\nconst a = 1\n"
        local fileFromEditor = string.gsub(fileOnDisk, "\n", "\r\n")
        local files = {
            ["/home/projects/tsconfig.json"] = "{}",
            ["/home/projects/test.ts"] = fileOnDisk,
            ["/home/projects/other.ts"] = "export {}",
        }
        local client, closeClient = initClient(files, lsproto.ClientCapabilities({
            textDocument = lsproto.TextDocumentClientCapabilities({
                semanticTokens = lsproto.SemanticTokensClientCapabilities({
                    requests = lsproto.ClientSemanticTokensRequestOptions({
                        full = lsproto.BooleanOrClientSemanticTokensRequestFullDelta({ boolean = true }),
                    }),
                    tokenTypes = { "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator" },
                    tokenModifiers = { "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary", "local" },
                    formats = {},
                }),
            }),
        }))
        local otherUri = "file:///home/projects/other.ts"
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = otherUri, languageId = "typescript", text = files["/home/projects/other.ts"] }),
        }))
        local msg1 = lsptestutil.SendRequest(nil, client, lsproto.TextDocumentSemanticTokensFullInfo, lsproto.SemanticTokensParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = otherUri }),
        }))
        assert.is_nil(msg1:AsResponse().error)
        local uri = "file:///home/projects/test.ts"
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = uri, languageId = "typescript", text = fileFromEditor }),
        }))
        local msg, resp = lsptestutil.SendRequest(nil, client, lsproto.TextDocumentSemanticTokensFullInfo, lsproto.SemanticTokensParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = uri }),
        }))
        assert.is_nil(msg:AsResponse().error)
        assert.is_not_nil(resp.semanticTokens)
        assert.is_nil(closeClient())
    end)

    it("auto-import completion after file close (TestCompletionAfterFileClose)", function()
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.includeCompletionsForModuleExports = core.Tristate.TSTrue
        prefs.includeCompletionsForImportStatements = core.Tristate.TSTrue
        local client, closeClient = initClient({
            ["/home/projects/tsconfig.json"] = [[{"compilerOptions": {"module": "esnext", "target": "esnext"}}]],
            ["/home/projects/a.ts"] = "export const someVar = 10;",
            ["/home/projects/b.ts"] = "s",
        }, nil, prefs)
        local aURI = lsconv.FileNameToDocumentURI("/home/projects/a.ts")
        local bURI = lsconv.FileNameToDocumentURI("/home/projects/b.ts")
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = aURI, languageId = "typescript", text = "export const someVar = 10;" }),
        }))
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = bURI, languageId = "typescript", text = "s" }),
        }))
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidCloseInfo, lsproto.DidCloseTextDocumentParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = bURI }),
        }))
        local msg, resp, ok = lsptestutil.SendRequest(nil, client, lsproto.TextDocumentCompletionInfo, lsproto.CompletionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = bURI }),
            position = lsproto.Position({ line = 0, character = 1 }),
            context = lsproto.CompletionContext({}),
        }))
        assert.is_true(ok)
        assert.is_nil(msg:AsResponse().error)
        local items = resp.list ~= nil and resp.list.items or resp.items or {}
        local item
        for _, it in ipairs(items) do
            if it.label == "someVar" then
                item = it
            end
        end
        assert.is_not_nil(item)
        assert.is_not_nil(item.data and item.data.autoImport)
        assert.are.equal("./a", item.data.autoImport.moduleSpecifier)
        assert.is_nil(closeClient())
    end)
end)

describe("lsp progress end to end #slow", function()
    it("sends progress notifications (TestProgressNotificationsEndToEnd)", function()
        local fs = bundled.WrapFS(vfstest.FromMap({
            ["/home/projects/tsconfig.json"] = "{}",
            ["/home/projects/index.ts"] = "export const x = 1;",
        }, false))
        local function onServerRequest(_, req)
            if req.method == lsproto.Method.ClientRegisterCapability or req.method == lsproto.Method.ClientUnregisterCapability or req.method == lsproto.Method.WindowWorkDoneProgressCreate then
                return lsproto.NewResponseMessage(req.id, lsproto.Null, nil, "Null")
            end
            return nil
        end
        local client, closeClient = lsptestutil.NewLSPClient(nil, {
            err = discard,
            cwd = "/home/projects",
            fs = fs,
            defaultLibraryPath = bundled.LibPath(),
        }, onServerRequest)
        local notifications = {}
        client.OnServerNotification = function(_, req)
            if req.method == lsproto.Method.Progress then
                local params, err = lsproto.UnmarshalParams(lsproto.ProgressInfo.paramsType, req)
                if err == nil and params ~= nil then
                    notifications[#notifications + 1] = params
                end
            end
        end
        local initMsg, _, ok = lsptestutil.SendRequest(nil, client, lsproto.InitializeInfo, lsproto.InitializeParams({
            capabilities = lsproto.ClientCapabilities({
                window = lsproto.WindowClientCapabilities({ workDoneProgress = true }),
            }),
        }))
        assert.is_true(ok and initMsg:AsResponse().error == nil)
        lsptestutil.SendNotification(nil, client, lsproto.InitializedInfo, lsproto.InitializedParams({}))
        client:Drain()
        local uri = "file:///home/projects/index.ts"
        lsptestutil.SendNotification(nil, client, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
            textDocument = lsproto.TextDocumentItem({ uri = uri, languageId = "typescript", text = "export const x = 1;" }),
        }))
        local msg, resp, ok2 = lsptestutil.SendRequest(nil, client, lsproto.CustomProjectInfoInfo, lsproto.ProjectInfoParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = uri }),
        }))
        assert.is_true(ok2)
        assert.is_nil(msg:AsResponse().error)
        assert.are.equal("/home/projects/tsconfig.json", resp.configFilePath)
        client:Drain()
        assert.is_true(#notifications >= 2)
        assert.is_not_nil(notifications[1].value.begin)
        assert.are.equal("Loading", notifications[1].value.begin.title)
        assert.is_not_nil(notifications[#notifications].value.end_)
        local firstToken = notifications[1].token.string
        assert.is_not_nil(firstToken)
        for _, n in ipairs(notifications) do
            assert.are.equal(firstToken, n.token.string)
        end
        assert.is_nil(closeClient())
    end)
end)

describe("lspwatcher #slow", function()
    it("rootFromGlob", function()
        for _, c in ipairs({
            { "/abs/path/**/*", "/abs/path" },
            { "/abs/path/", "/abs/path" },
            { "/abs/path/?.ts", "/abs/path" },
            { "/abs/path/{a,b}/*", "/abs/path" },
        }) do
            assert.are.equal(c[2], lspwatcher.rootFromGlob(c[1]))
        end
    end)

    local function newFakeBackend()
        local f = { byDir = {}, closed = {}, optCount = {}, failDirs = {} }
        function f:WatchDirectory(dir, fn, ...)
            if self.failDirs[dir] ~= nil then
                return nil, self.failDirs[dir]
            end
            self.byDir[dir] = fn
            self.optCount[dir] = select("#", ...)
            return { Close = function()
                self.byDir[dir] = nil
                self.closed[dir] = (self.closed[dir] or 0) + 1
                return nil
            end }, nil
        end
        function f:watchedDirs()
            local dirs = {}
            for d in pairs(self.byDir) do
                dirs[#dirs + 1] = d
            end
            table.sort(dirs)
            return dirs
        end
        function f:isWatching(dir)
            return self.byDir[dir] ~= nil
        end
        function f:emit(dir, events, err)
            local cb = self.byDir[dir]
            if cb ~= nil then
                cb(events, err)
            end
        end
        function f:emitAll(events, err)
            for _, d in ipairs(self:watchedDirs()) do
                self.byDir[d](events, err)
            end
        end
        return f
    end

    local function pattern(p, kind)
        return lsproto.FileSystemWatcher({ globPattern = lsproto.PatternOrRelativePattern({ pattern = p }), kind = kind })
    end

    local logger = logging.NewLogger(discard)

    it("filters by kind", function()
        local fs = vfstest.FromMap({ ["/dir/x.ts"] = "" }, false)
        local backend = newFakeBackend()
        local got = {}
        local w = lspwatcher.newWithBackend(fs, backend, function(changes)
            for _, c in ipairs(changes) do
                got[#got + 1] = c
            end
        end, logger)
        assert.is_nil(w:WatchFiles("test", { pattern("/dir/**/*", lsproto.WatchKind.Delete) }))
        backend:emitAll({
            fswatch.NewEvent(fswatch.EventKind.EventUpdate, "/dir/x.ts"),
            fswatch.NewEvent(fswatch.EventKind.EventDelete, "/dir/x.ts"),
        }, nil)
        w:Poll(true)
        assert.are.equal(1, #got)
        assert.are.equal(lsproto.FileChangeType.Deleted, got[1].type)
        w:Close()
    end)

    it("bookkeeping and overflow", function()
        local fs = vfstest.FromMap({ ["/dir/a.ts"] = "" }, false)
        local backend = newFakeBackend()
        local got = {}
        local w = lspwatcher.newWithBackend(fs, backend, function(changes)
            for _, c in ipairs(changes) do
                got[#got + 1] = c
            end
        end, logger)
        assert.is_nil(w:WatchFiles("id", { pattern("/dir/**/*") }))
        assert.is_not_nil(w:WatchFiles("id", { pattern("/dir/**/*") }))
        backend:emitAll({ fswatch.NewEvent(fswatch.EventKind.EventUpdate, "/dir/a.ts") }, fswatch.ErrOverflow)
        w:Poll(true)
        assert.is_true(#got > 0)
        assert.is_not_nil(w:UnwatchFiles("missing"))
        assert.is_nil(w:UnwatchFiles("id"))
        assert.is_nil(w:WatchFiles("id2", nil))
        w:Close()
        assert.is_not_nil(w:WatchFiles("id3", nil))
    end)

    it("non-recursive glob is not recursive", function()
        local fs = vfstest.FromMap({ ["/dir/sub/a.ts"] = "" }, false)
        local backend = newFakeBackend()
        local w = lspwatcher.newWithBackend(fs, backend, function() end, logger)
        assert.is_nil(w:WatchFiles("id", { pattern("/dir/**/*"), pattern("/dir/sub/*") }))
        assert.are.equal(1, backend.optCount["/dir"])
        assert.are.equal(0, backend.optCount["/dir/sub"])
        w:Close()
    end)

    it("missing directory tracks ancestor, promotes on create and descends", function()
        local fs = vfstest.FromMap({ ["/base/x.ts"] = "" }, false)
        local backend = newFakeBackend()
        local got = {}
        local w = lspwatcher.newWithBackend(fs, backend, function(changes)
            for _, c in ipairs(changes) do
                got[#got + 1] = c
            end
        end, logger)
        assert.is_nil(w:WatchFiles("id", { pattern("/base/a/pkg/*", lsproto.WatchKind.Create | lsproto.WatchKind.Change | lsproto.WatchKind.Delete) }))
        assert.are.same({ "/base" }, backend:watchedDirs())

        fs:WriteFile("/base/a/keep.ts", "")
        backend:emit("/base", { fswatch.NewEvent(fswatch.EventKind.EventUpdate, "/base/a") }, nil)
        assert.are.same({ "/base/a" }, backend:watchedDirs())

        fs:WriteFile("/base/a/pkg/index.ts", "export {}")
        backend:emit("/base/a", { fswatch.NewEvent(fswatch.EventKind.EventUpdate, "/base/a/pkg") }, nil)
        assert.is_true(backend:isWatching("/base/a/pkg"))
        w:Poll(true)
        local sawDir, sawChild = false, false
        for _, e in ipairs(got) do
            if e.type == lsproto.FileChangeType.Created then
                sawDir = sawDir or string.sub(e.uri, -4) == "/pkg"
                sawChild = sawChild or string.sub(e.uri, -13) == "/pkg/index.ts"
            end
        end
        assert.is_true(sawDir)
        assert.is_true(sawChild)

        assert.is_nil(w:UnwatchFiles("id"))
        assert.are.same({}, backend:watchedDirs())
        w:Close()
    end)

    it("genuine failure rolls back for retry", function()
        local fs = vfstest.FromMap({ ["/a/x.ts"] = "", ["/b/y.ts"] = "" }, false)
        local backend = newFakeBackend()
        backend.failDirs["/b"] = jsonrpc.NewError("too many open files")
        local w = lspwatcher.newWithBackend(fs, backend, function() end, logger)
        assert.is_not_nil(w:WatchFiles("id", { pattern("/a/**/*"), pattern("/b/**/*") }))
        assert.are.same({}, backend:watchedDirs())
        backend.failDirs["/b"] = nil
        assert.is_nil(w:WatchFiles("id", { pattern("/a/**/*"), pattern("/b/**/*") }))
        assert.are.same({ "/a", "/b" }, backend:watchedDirs())
        w:Close()
    end)
end)
