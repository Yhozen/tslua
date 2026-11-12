-- Ports of internal/lsp/lsproto/{baseproto_test,lsp_test,lsp_json_test}.go.
local lsproto = require("tslua.lsp.lsproto")
local jsonrpc = require("tslua.jsonrpc")

local function stringReader(s)
    local pos = 1
    return {
        read = function(_, fmt)
            if pos > #s then
                return nil
            end
            if fmt == "L" then
                local nl = string.find(s, "\n", pos, true)
                local e = nl or #s
                local line = string.sub(s, pos, e)
                pos = e + 1
                return line
            end
            local chunk = string.sub(s, pos, pos + fmt - 1)
            pos = pos + #chunk
            return chunk
        end,
    }
end

local function bufferWriter()
    local w = { parts = {} }
    function w:Write(s)
        self.parts[#self.parts + 1] = s
        return #s, nil
    end
    function w:String()
        return table.concat(self.parts)
    end
    return w
end

local function errString(err)
    return jsonrpc.ErrorString(err)
end

local function unmarshal(goType, input)
    return lsproto.UnmarshalAs(goType, input)
end

local function marshal(goType, v)
    local s, err = lsproto.MarshalAs(goType, v)
    assert.is_nil(err)
    return s
end

describe("lsproto base protocol", function()
    local tests = {
        { name = "empty", input = "Content-Length: 0\r\n\r\n", err = "jsonrpc: no content length" },
        { name = "early end", input = "oops", err = "EOF" },
        { name = "negative length", input = "Content-Length: -1\r\n\r\n", err = "jsonrpc: invalid content length: negative value -1" },
        { name = "invalid content", input = "Content-Length: 1\r\n\r\n{", value = "{" },
        { name = "valid content", input = "Content-Length: 2\r\n\r\n{}", value = "{}" },
        { name = "extra header values", input = "Content-Length: 2\r\nExtra: 1\r\n\r\n{}", value = "{}" },
        { name = "too long content length", input = "Content-Length: 100\r\n\r\n{}", err = "jsonrpc: read content: unexpected EOF" },
        {
            name = "missing content length",
            input = "Content-Length: \r\n\r\n{}",
            err = 'jsonrpc: invalid content length: parse error: strconv.ParseInt: parsing "": invalid syntax',
        },
        { name = "invalid header", input = "Nope\r\n\r\n{}", err = 'jsonrpc: invalid header: "Nope\\r\\n"' },
    }
    for _, tt in ipairs(tests) do
        it("BaseReader " .. tt.name, function()
            local r = lsproto.NewBaseReader(stringReader(tt.input))
            local out, err = r:Read()
            if tt.err ~= nil then
                assert.are.equal(tt.err, errString(err))
            end
            assert.are.equal(tt.value, out)
        end)
    end

    it("BaseReader multiple reads", function()
        local r = lsproto.NewBaseReader(stringReader("Content-Length: 4\r\n\r\n1234" .. "Content-Length: 2\r\n\r\n{}"))
        local v1, err1 = r:Read()
        assert.is_nil(err1)
        assert.are.equal("1234", v1)
        local v2, err2 = r:Read()
        assert.is_nil(err2)
        assert.are.equal("{}", v2)
        local _, err3 = r:Read()
        assert.are.equal("EOF", errString(err3))
        assert.is_true(jsonrpc.ErrorsIs(err3, jsonrpc.EOF))
    end)

    it("BaseWriter", function()
        for _, tt in ipairs({
            { value = "{}", input = "Content-Length: 2\r\n\r\n{}" },
            { value = '{"key":"value"}', input = 'Content-Length: 15\r\n\r\n{"key":"value"}' },
        }) do
            local b = bufferWriter()
            local w = lsproto.NewBaseWriter(b)
            assert.is_nil(w:Write(tt.value))
            assert.are.equal(tt.input, b:String())
        end
    end)

    it("BaseWriter write error", function()
        local w = lsproto.NewBaseWriter({
            Write = function()
                return 0, "test error"
            end,
        })
        assert.are.equal("test error", errString(w:Write("{}")))
    end)
end)

describe("lsproto JSON", function()
    it("unmarshals CompletionItem", function()
        local message = [[{
    "label": "pageXOffset",
    "insertTextFormat": 1,
    "textEdit": {
        "newText": "pageXOffset",
        "insert": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 4}},
        "replace": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 4}}
    },
    "kind": 6,
    "sortText": "15",
    "commitCharacters": [".", ",", ";"]
}]]
        local result, err = unmarshal("CompletionItem", message)
        assert.is_nil(err)
        assert.are.equal("pageXOffset", result.label)
        assert.are.equal(lsproto.InsertTextFormat.PlainText, result.insertTextFormat)
        assert.are.equal(lsproto.CompletionItemKind.Variable, result.kind)
        assert.are.equal("15", result.sortText)
        assert.are.same({ ".", ",", ";" }, result.commitCharacters)
        local ire = result.textEdit.insertReplaceEdit
        assert.is_nil(result.textEdit.textEdit)
        assert.are.equal("pageXOffset", ire.newText)
        assert.are.same({ line = 4, character = 0 }, { line = ire.insert.start.line, character = ire.insert.start.character })
        assert.are.equal(4, ire.replace.end_.character)
        assert.are.equal(0, lsproto.Range.Compare(ire.insert, ire.replace))
    end)

    local rejectsNull = {
        { "InlayHint", '{"position": {"line": 0, "character": 0}, "label": "foo", "kind": null}', 'null value is not allowed for field "kind"' },
        { "InlayHint", '{"position": {"line": 0, "character": 0}, "label": "foo", "textEdits": null}', 'null value is not allowed for field "textEdits"' },
        { "InlayHint", '{"position": {"line": 0, "character": 0}, "label": "foo", "paddingLeft": null}', 'null value is not allowed for field "paddingLeft"' },
        { "FoldingRange", '{"startLine": 0, "endLine": 10, "kind": null}', 'null value is not allowed for field "kind"' },
        { "FoldingRange", '{"startLine": 0, "endLine": 10, "startCharacter": null}', 'null value is not allowed for field "startCharacter"' },
        { "CompletionItem", '{"label": "test", "insertTextFormat": null}', 'null value is not allowed for field "insertTextFormat"' },
        { "Hover", '{"contents": {"kind": "plaintext", "value": "hi"}, "range": null}', 'null value is not allowed for field "range"' },
        { "WorkDoneProgressOptions", '{"workDoneProgress": null}', 'null value is not allowed for field "workDoneProgress"' },
        { "CallHierarchyIncomingCallsParams", '{"item": null}', 'null value is not allowed for field "item"' },
        { "CallHierarchyIncomingCall", '{"from": null, "fromRanges": []}', 'null value is not allowed for field "from"' },
        { "InitializeParams", '{"processId": null, "rootUri": null, "capabilities": null}', 'null value is not allowed for field "capabilities"' },
        { "InitializeResult", '{"capabilities": null}', 'null value is not allowed for field "capabilities"' },
        { "SemanticTokens", '{"data": null}', 'null value is not allowed for field "data"' },
        { "TextDocumentEdit", '{"textDocument": {"uri": "file:///a.ts", "version": 1}, "edits": null}', 'null value is not allowed for field "edits"' },
        { "InlayHint", '{"label": "test"}', "missing required properties: position" },
        { "InlayHint", '{"position": {"line": 0, "character": 0}}', "missing required properties: label" },
        { "Location", '{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}}', "missing required properties: uri" },
        { "Location", "{}", "missing required properties: uri, range" },
        { "TextEdit", '{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}', "missing required properties" },
        { "Range", '{"start":{"line":0,"character":0}}', "missing required properties" },
        { "Position", '{"line":0}', "missing required properties" },
    }
    for _, tt in ipairs(rejectsNull) do
        it("rejects " .. tt[1] .. " " .. tt[2], function()
            local _, err = unmarshal(tt[1], tt[2])
            assert.is_not_nil(err)
            assert.is_truthy(string.find(errString(err), tt[3], 1, true))
        end)
    end

    local accepts = {
        { "InitializeParams", '{"processId": null, "rootUri": null, "capabilities": {}}' },
        { "InitializeParams", '{"processId": null, "rootUri": null, "capabilities": {}, "workspaceFolders": null}' },
        { "InitializationOptions", '{"userPreferences": null}' },
        { "InitializeParams", '{"processId": null, "rootUri": null, "capabilities": {}, "initializationOptions": null}' },
        { "Location", '{"uri": "file:///test.ts", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "someUnknownField": 42, "anotherUnknown": {"nested": true}}' },
        { "InlayHint", '{"position": {"line": 0, "character": 0}, "label": "x", "futureField": [1, 2, 3]}' },
        { "WorkDoneProgressOptions", "{}" },
        { "InitializationOptions", "{}" },
        { "ClientCapabilities", "{}" },
        { "ServerCapabilities", "{}" },
    }
    for _, tt in ipairs(accepts) do
        it("accepts " .. tt[1] .. " " .. tt[2], function()
            local _, err = unmarshal(tt[1], tt[2])
            assert.is_nil(err)
        end)
    end

    local wrongTypes = {
        { "Location", "[]" },
        { "Location", '"not an object"' },
        { "Location", "42" },
        { "Location", "null" },
        { "FoldingRange", "true" },
        { "IntegerOrString", "true" },
        { "IntegerOrString", "null" },
        { "IntegerOrString", "{}" },
        { "IntegerOrString", "[]" },
        { "StringOrInlayHintLabelParts", "42" },
        { "StringOrInlayHintLabelParts", "true" },
        { "BooleanOrHoverOptions", '"nope"' },
        { "WorkDoneProgressBeginOrReportOrEnd", '{"kind": "invalid"}' },
        { "StringLiteralCreate", '"delete"' },
        { "StringLiteralCreate", "42" },
        { "TextEdit", '"oops"' },
    }
    for _, tt in ipairs(wrongTypes) do
        it("rejects wrong type " .. tt[1] .. " " .. tt[2], function()
            local _, err = unmarshal(tt[1], tt[2])
            assert.is_not_nil(err)
        end)
    end

    it("accepts omitted optional fields", function()
        local hint, err = unmarshal("InlayHint", '{"position": {"line": 1, "character": 5}, "label": "test"}')
        assert.is_nil(err)
        assert.is_nil(hint.kind)
        assert.is_nil(hint.textEdits)
        assert.is_nil(hint.tooltip)
        assert.is_nil(hint.paddingLeft)
        assert.is_nil(hint.data)
        assert.are.equal(1, hint.position.line)
        assert.are.equal(5, hint.position.character)
        local fr = unmarshal("FoldingRange", '{"startLine": 5, "endLine": 10}')
        assert.is_nil(fr.kind)
        assert.is_nil(fr.startCharacter)
        assert.are.equal(5, fr.startLine)
        assert.are.equal(10, fr.endLine)
    end)

    it("unions", function()
        local v = unmarshal("IntegerOrString", "42")
        assert.are.equal(42, v.integer)
        assert.is_nil(v.string)
        v = unmarshal("IntegerOrString", '"hello"')
        assert.are.equal("hello", v.string)
        v = unmarshal("IntegerOrNull", "null")
        assert.is_nil(v.integer)
        v = unmarshal("DocumentUriOrNull", '"file:///test.ts"')
        assert.are.equal("file:///test.ts", v.documentUri)
        assert.are.equal("42", marshal("IntegerOrNull", { integer = 42 }))
        assert.are.equal("null", marshal("IntegerOrNull", {}))
        assert.are.equal("7", marshal("IntegerOrString", { integer = 7 }))
        assert.are.equal('"tok"', marshal("IntegerOrString", { string = "tok" }))
        assert.has_error(function()
            lsproto.MarshalAs("IntegerOrString", {})
        end, "exactly one element of IntegerOrString should be set")

        v = unmarshal("BooleanOrHoverOptions", "false")
        assert.are.equal(false, v.boolean)
        assert.is_nil(v.hoverOptions)
        v = unmarshal("BooleanOrHoverOptions", "{}")
        assert.is_nil(v.boolean)
        assert.is_not_nil(v.hoverOptions)

        v = unmarshal("WorkDoneProgressBeginOrReportOrEnd", '{"kind": "begin", "title": "Indexing"}')
        assert.are.equal("Indexing", v.begin.title)
        v = unmarshal("WorkDoneProgressBeginOrReportOrEnd", '{"kind": "report", "message": "50%"}')
        assert.are.equal("50%", v.report.message)
        v = unmarshal("WorkDoneProgressBeginOrReportOrEnd", '{"kind": "end"}')
        assert.is_not_nil(v["end_"])

        v = unmarshal("TextEditOrInsertReplaceEdit", '{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "newText": "x"}')
        assert.are.equal("x", v.textEdit.newText)
        v = unmarshal("TextEditOrInsertReplaceEdit", '{"insert": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "replace": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 2}}, "newText": "y"}')
        assert.are.equal("y", v.insertReplaceEdit.newText)

        v = unmarshal("StringOrInlayHintLabelParts", '[{"value": "param"}, {"value": ": "}, {"value": "string"}]')
        assert.are.equal(3, #v.inlayHintLabelParts)
        assert.are.equal("param", v.inlayHintLabelParts[1].value)

        v = unmarshal("TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile", '{"textDocument": {"uri": "file:///a.ts", "version": 1}, "edits": [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "x"}]}')
        assert.is_not_nil(v.textDocumentEdit)
        v = unmarshal("TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile", '{"kind": "create", "uri": "file:///new.ts"}')
        assert.are.equal("file:///new.ts", v.createFile.uri)
        v = unmarshal("TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile", '{"kind": "rename", "oldUri": "file:///old.ts", "newUri": "file:///new.ts"}')
        assert.are.equal("file:///old.ts", v.renameFile.oldUri)
        v = unmarshal("TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile", '{"kind": "delete", "uri": "file:///gone.ts"}')
        assert.are.equal("file:///gone.ts", v.deleteFile.uri)
    end)

    it("omits zero optional fields", function()
        local s = marshal("*InlayHint", lsproto.InlayHint({ label = { string = "x" } }))
        assert.are.equal('{"position":{"line":0,"character":0},"label":"x"}', s)
        s = marshal("*FoldingRange", { startLine = 1, endLine = 10 })
        assert.are.equal('{"startLine":1,"endLine":10}', s)
    end)

    it("literal types and enums", function()
        assert.are.equal('"create"', marshal("StringLiteralCreate", lsproto.StringLiteralCreate{}))
        assert.is_nil(select(2, unmarshal("StringLiteralCreate", '"create"')))
        assert.are.equal("Type", lsproto.InlayHintKind_String(lsproto.InlayHintKind.Type))
        assert.are.equal("Parameter", lsproto.InlayHintKind_String(lsproto.InlayHintKind.Parameter))
        assert.are.equal("File", lsproto.SymbolKind_String(lsproto.SymbolKind.File))
        assert.are.equal("Function", lsproto.SymbolKind_String(lsproto.SymbolKind.Function))
        assert.are.equal("InlayHintKind(999)", lsproto.InlayHintKind_String(999))
        assert.are.equal("Create|Delete", lsproto.WatchKind_String(lsproto.WatchKind.Create | lsproto.WatchKind.Delete))
        assert.are.equal("RequestCancelled", errString(lsproto.ErrorCode.RequestCancelled))
    end)

    local roundTrips = {
        { "*InlayHint", { position = { line = 1, character = 5 }, label = { string = "param" }, kind = lsproto.InlayHintKind.Parameter } },
        { "*FoldingRange", { startLine = 1, startCharacter = 0, endLine = 10, endCharacter = 5, kind = lsproto.FoldingRangeKind.Region, collapsedText = "..." } },
        { "*Location", { uri = "file:///test.ts", range = { start = { line = 1, character = 2 }, end_ = { line = 3, character = 4 } } } },
        { "*InitializeParams", { processId = {}, rootUri = { documentUri = "file:///workspace" }, capabilities = {} } },
        { "*TextEdit", { range = { start = { line = 1, character = 2 }, end_ = { line = 3, character = 4 } }, newText = "hello" } },
        { "*MarkupContent", { kind = lsproto.MarkupKind.Markdown, value = "**x**" } },
        { "*DidChangeConfigurationParams", { settings = { ["js/ts"] = { x = 1.0 } } } },
        { "*DidChangeConfigurationParams", { settings = nil } },
        { "*CompletionItem", { label = "pageXOffset", kind = lsproto.CompletionItemKind.Field, sortText = "15", insertTextFormat = lsproto.InsertTextFormat.PlainText } },
        { "*ParameterInformation", { label = { string = "p: number" } } },
        { "*ParameterInformation", { label = { tuple = { 0, 4 } } } },
    }
    for i, tt in ipairs(roundTrips) do
        it("round trips " .. tt[1] .. " #" .. i, function()
            local data = marshal(tt[1], tt[2])
            local got, err = unmarshal(tt[1], data)
            assert.is_nil(err)
            assert.are.equal(data, marshal(tt[1], got))
        end)
    end

    it("UnmarshalParams requires params", function()
        for _, tt in ipairs({
            { nil, false },
            { "", false },
            { "null", true },
            { "{}", true },
        }) do
            local params = tt[1] and jsonrpc.NewValue(tt[1]) or nil
            local _, err = lsproto.UnmarshalParams("NoParams", lsproto.NewRequestMessage(nil, "", params))
            if tt[2] then
                assert.is_true(jsonrpc.ErrorsIs(err, lsproto.ErrorCode.InvalidParams))
            else
                assert.is_nil(err)
            end
        end
        for _, tt in ipairs({
            { nil, true },
            { "", true },
            { "null", true },
            { "5", true },
            { '"x"', true },
            { '{"settings":{"x":1}}', false },
        }) do
            local params = tt[1] and jsonrpc.NewValue(tt[1]) or nil
            local got, err = lsproto.UnmarshalParams("*DidChangeConfigurationParams", lsproto.NewRequestMessage(nil, "", params))
            if tt[2] then
                assert.is_true(jsonrpc.ErrorsIs(err, lsproto.ErrorCode.InvalidParams))
            else
                assert.is_nil(err)
                assert.is_not_nil(got.settings)
            end
        end
    end)

    it("messages", function()
        local m = lsproto.NewMessage()
        assert.is_nil(m:UnmarshalJSON('{"jsonrpc":"2.0","id":3,"method":"shutdown"}'))
        assert.are.equal(jsonrpc.MessageKind.Request, m.kind)
        assert.are.equal("3", m:AsRequest().id:String())
        m = lsproto.NewMessage()
        assert.is_nil(m:UnmarshalJSON('{"jsonrpc":"2.0","id":"ts1","result":[{"a":1}]}'))
        assert.are.equal(jsonrpc.MessageKind.Response, m.kind)
        local result = lsproto.WorkspaceConfigurationInfo:UnmarshalResult(m:AsResponse().result)
        assert.are.equal(1, #result)
        m = lsproto.NewMessage()
        local err = m:UnmarshalJSON('{"jsonrpc":"1.0","method":"x"}')
        assert.is_true(jsonrpc.ErrorsIs(err, lsproto.ErrorCode.InvalidRequest))
        assert.is_true(jsonrpc.ErrorsIs(err, jsonrpc.ErrInvalidJSONRPCVersion))

        local req = lsproto.TextDocumentPublishDiagnosticsInfo:NewNotificationMessage({ uri = "file:///a.ts", diagnostics = {} })
        assert.are.equal('{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.ts","diagnostics":[]}}', (req:Message():MarshalJSON()))
        local shutdown = lsproto.ShutdownInfo:NewRequestMessage(jsonrpc.NewIDString("ts2"), lsproto.NoParams)
        assert.are.equal('{"jsonrpc":"2.0","id":"ts2","method":"shutdown"}', (shutdown:MarshalJSON()))
        local resp = lsproto.NewResponseMessage(jsonrpc.NewIDInt(1), nil, jsonrpc.NewResponseError(-32601, "nope"))
        assert.are.equal('{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}', (resp:MarshalJSON()))
    end)

    it("Registration", function()
        local reg = lsproto.Registration({
            id = "1",
            registerOptions = { workspaceDidChangeWatchedFiles = { watchers = { { globPattern = { pattern = "**/*.ts" } } } } },
        })
        local s = marshal("*Registration", reg)
        assert.are.equal('{"id":"1","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.ts"}]}}', s)
        local back, err = unmarshal("*Registration", s)
        assert.is_nil(err)
        assert.are.equal("**/*.ts", back.registerOptions.workspaceDidChangeWatchedFiles.watchers[1].globPattern.pattern)
    end)

    it("DocumentUri", function()
        assert.are.equal("/a/b.ts", lsproto.DocumentUri_FileName("file:///a/b.ts"))
        assert.are.equal("c:/foo/bar.ts", lsproto.DocumentUri_FileName("file:///c%3A/foo/bar.ts"))
        assert.are.equal("//server/share/x.ts", lsproto.DocumentUri_FileName("file://server/share/x.ts"))
        assert.are.equal("^/untitled/ts-nul-authority/Untitled-1", lsproto.DocumentUri_FileName("untitled:Untitled-1"))
        assert.are.equal("^/vscode-vfs/github/a/b.ts", lsproto.DocumentUri_FileName("vscode-vfs://github/a/b.ts"))
    end)

    it("resolves client capabilities", function()
        local caps = unmarshal("ClientCapabilities", '{"textDocument":{"completion":{"completionItem":{"snippetSupport":true}}}}')
        local resolved = lsproto.ClientCapabilities.Resolve(caps)
        assert.is_true(resolved.textDocument.completion.completionItem.snippetSupport)
        assert.is_false(resolved.textDocument.hover.dynamicRegistration)
        assert.are.equal("{}", marshal("ResolvedClientCapabilities", lsproto.ClientCapabilities.Resolve(nil)))
    end)
end)
