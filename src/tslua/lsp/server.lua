local lsp = require("tslua.lsp")
local collections = require("tslua.collections")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local fswatch = require("tslua.fswatch")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local locale = require("tslua.locale")
local ls = require("tslua.ls")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local lspwatcher = require("tslua.lsp.lspwatcher")
local logging = require("tslua.project.logging")
local project = require("tslua.project")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local ErrorCode = lsproto.ErrorCode
local Method = lsproto.Method
local MessageKind = jsonrpc.MessageKind

-- Concurrency model of the sequential port.
--
-- Go runs three loops concurrently: readLoop (reads messages; answers initialize; routes
-- responses to server->client requests; queues everything else), dispatchLoop (handles queued
-- requests, running their asynchronous part on goroutines) and writeLoop (writes queued outgoing
-- messages). Here a single loop (Server:loop) reads a message only when no request is queued,
-- dispatches requests in arrival order and runs the asynchronous part of a handler right after
-- its synchronous part. Outgoing messages are written as soon as they are queued
-- (Server:flushOutgoing, the writeLoop body). A server->client request (sendClientRequest) keeps
-- reading messages until its response arrives; requests and notifications read meanwhile are
-- queued and handled afterwards, like Go's readLoop does while dispatch is blocked.
-- Before blocking on input with nothing queued, the server lets the session finish its
-- background tasks (Go: they run concurrently while the server waits) and polls the progress
-- display timer (Server:idle).

-- ServerOptions: { in_ = Reader, out = Writer, err = io.Writer, cwd, fs, defaultLibraryPath,
--   typingsLocation, parseCache, npmInstall = function(cwd, args) -> output, err,
--   spawn = function(command, dir, stderr) -> rwc, err (nil when the host cannot spawn processes;
--     currently used for content mappers),
--   progressDelay = seconds (delay before showing progress UI; 0 means no delay),
--   setParentProcessID = function(parentPID) }

local Server = {}
Server.__index = Server
lsp.Server = Server

function lsp.NewServer(opts)
    if opts.cwd == nil or opts.cwd == "" then
        error("Cwd is required", 0)
    end

    local s = setmetatable({
        r = opts.in_,
        w = opts.out,
        backgroundCtx = nil,
        stderr = opts.err,
        logger = nil,
        initStarted = false,
        clientSeq = 0,
        requestQueue = lsp.newDynamicQueue(),
        outgoingQueue = lsp.newDynamicQueue(),
        pendingClientRequests = {},
        pendingServerRequests = {},
        cwd = opts.cwd,
        fs = opts.fs,
        defaultLibraryPath = opts.defaultLibraryPath or "",
        typingsLocation = opts.typingsLocation or "",
        initializeParams = nil,
        initializationOptions = nil,
        clientCapabilities = lsproto.ClientCapabilities.Resolve(nil),
        positionEncoding = "",
        locale = locale.Default,
        initLocale = locale.Default,
        watchEnabled = false,
        telemetryEnabled = false,
        watcherID = 0,
        watchers = collections.NewSet(),
        contentMapperExtensionsRegistered = false,
        builtinWatcher = nil,
        lastRequestTimeMs = 0,
        session = nil,
        apiSessions = nil,
        client = nil,
        initCompleted = false,
        compilerOptionsForInferredProjects = nil,
        parseCache = opts.parseCache,
        npmInstall = opts.npmInstall,
        spawn = opts.spawn,
        cpuProfiler = nil,
        progressDelay = opts.progressDelay or 0,
        projectProgress = nil,
        startWatchdog = opts.setParentProcessID,
        flakeLogging = lsproto.DiagnosticFlakeLogLevel.Off,
        -- Lua-only state of the sequential loops.
        flushing = false,
        fatalErr = nil,
    }, Server)
    s.logger = lsp.newLogger(s)

    return s
end

lsp.fileRenameFilters = {
    lsproto.FileOperationFilter({
        scheme = "file",
        pattern = lsproto.FileOperationPattern({
            glob = "**/*.{ts,tsx,js,jsx,cts,cjs,mts,mjs,json}",
        }),
    }),
}

-- pendingClientRequest: { req, cancel }

-- Reader: an object with Read() -> (*lsproto.Message, err).
-- Writer: an object with Write(msg *lsproto.Message) -> err.

local lspReader = {}
lspReader.__index = lspReader
lsp.lspReader = lspReader

local lspWriter = {}
lspWriter.__index = lspWriter
lsp.lspWriter = lspWriter

local messageMarshalError = {}
messageMarshalError.__index = messageMarshalError
lsp.messageMarshalError = messageMarshalError

function lsp.newMessageMarshalError(err)
    local e = setmetatable({ err = err }, messageMarshalError)
    e.unwrapAll = { ErrorCode.InternalError, err }
    return e
end

function messageMarshalError:Error()
    return "failed to marshal message: " .. jsonrpc.ErrorString(self.err)
end

-- Returns (msg, err).
function lspReader:Read()
    local data, err = self.r:Read()
    if err ~= nil then
        return nil, err
    end

    local req = lsproto.NewMessage()
    err = req:UnmarshalJSON(data)
    if err ~= nil then
        if jsonrpc.ErrorsIs(err, ErrorCode.InvalidParams) then
            return req, lsproto.newCodeError(ErrorCode.InvalidParams, jsonrpc.ErrorString(err), err)
        end
        return nil, lsproto.newCodeError(ErrorCode.InvalidRequest, jsonrpc.ErrorString(err), err)
    end

    return req, nil
end

function lsp.ToReader(r)
    return setmetatable({ r = lsproto.NewBaseReader(r) }, lspReader)
end

-- Returns err.
function lspWriter:Write(msg)
    local ok, data, err = pcall(json.Marshal, msg)
    if not ok then
        err = data
    end
    if err ~= nil then
        return lsp.newMessageMarshalError(err)
    end
    return self.w:Write(data)
end

function lsp.ToWriter(w)
    return setmetatable({ w = lsproto.NewBaseWriter(w) }, lspWriter)
end

function Server:Session()
    return self.session
end

-- InitComplete reports whether the server has finished processing the initialized notification,
-- including the initial configuration exchange with the client (Go: a channel closed then).
function Server:InitComplete()
    return self.initCompleted
end

-- WatchFiles implements project.Client.
function Server:WatchFiles(ctx, id, watchers)
    if self.builtinWatcher ~= nil then
        local err = self.builtinWatcher:WatchFiles(id, watchers)
        if err ~= nil then
            return jsonrpc.NewError("failed to register file watcher: " .. jsonrpc.ErrorString(err), err)
        end
        self.watchers:Add(id)
        return nil
    end
    local _, err = lsp.sendClientRequest(ctx, self, lsproto.ClientRegisterCapabilityInfo, lsproto.RegistrationParams({
        registrations = {
            lsproto.Registration({
                id = id,
                registerOptions = lsproto.RegisterOptions({
                    workspaceDidChangeWatchedFiles = lsproto.DidChangeWatchedFilesRegistrationOptions({
                        watchers = watchers,
                    }),
                }),
            }),
        },
    }))
    if err ~= nil then
        return jsonrpc.NewError("failed to register file watcher: " .. jsonrpc.ErrorString(err), err)
    end

    self.watchers:Add(id)
    return nil
end

-- UnwatchFiles implements project.Client.
function Server:UnwatchFiles(ctx, id)
    if self.builtinWatcher ~= nil then
        if not self.watchers:Has(id) then
            return jsonrpc.NewError("no file watcher exists with ID " .. id)
        end
        local err = self.builtinWatcher:UnwatchFiles(id)
        if err ~= nil then
            return jsonrpc.NewError("failed to unregister file watcher: " .. jsonrpc.ErrorString(err), err)
        end
        self.watchers:Delete(id)
        return nil
    end
    if self.watchers:Has(id) then
        local _, err = lsp.sendClientRequest(ctx, self, lsproto.ClientUnregisterCapabilityInfo, lsproto.UnregistrationParams({
            unregisterations = {
                lsproto.Unregistration({
                    id = id,
                    method = Method.WorkspaceDidChangeWatchedFiles,
                }),
            },
        }))
        if err ~= nil then
            return jsonrpc.NewError("failed to unregister file watcher: " .. jsonrpc.ErrorString(err), err)
        end

        self.watchers:Delete(id)
        return nil
    end

    return jsonrpc.NewError("no file watcher exists with ID " .. id)
end

lsp.contentMapperDidOpenRegistrationID = "content-mapper-did-open"
lsp.contentMapperDidChangeRegistrationID = "content-mapper-did-change"
lsp.contentMapperDidCloseRegistrationID = "content-mapper-did-close"
lsp.contentMapperDiagnosticRegistrationID = "content-mapper-diagnostic"
lsp.contentMapperHoverRegistrationID = "content-mapper-hover"
lsp.contentMapperSignatureHelpRegistrationID = "content-mapper-signature-help"
lsp.contentMapperDefinitionRegistrationID = "content-mapper-definition"
lsp.contentMapperTypeDefinitionRegistrationID = "content-mapper-type-definition"
lsp.contentMapperImplementationRegistrationID = "content-mapper-implementation"
lsp.contentMapperReferencesRegistrationID = "content-mapper-references"
lsp.contentMapperDocumentHighlightRegistrationID = "content-mapper-document-highlight"
lsp.contentMapperCompletionRegistrationID = "content-mapper-completion"
lsp.contentMapperRenameRegistrationID = "content-mapper-rename"
lsp.contentMapperSemanticTokensRegistrationID = "content-mapper-semantic-tokens"
lsp.contentMapperDocumentSymbolRegistrationID = "content-mapper-document-symbol"
lsp.contentMapperFoldingRangeRegistrationID = "content-mapper-folding-range"
lsp.contentMapperSelectionRangeRegistrationID = "content-mapper-selection-range"
lsp.contentMapperInlayHintRegistrationID = "content-mapper-inlay-hint"
lsp.contentMapperCodeLensRegistrationID = "content-mapper-code-lens"
lsp.contentMapperCodeActionRegistrationID = "content-mapper-code-action"
lsp.contentMapperFormattingRegistrationID = "content-mapper-formatting"
lsp.contentMapperRangeFormattingRegistrationID = "content-mapper-range-formatting"
lsp.contentMapperOnTypeFormattingRegistrationID = "content-mapper-on-type-formatting"
lsp.contentMapperLinkedEditingRegistrationID = "content-mapper-linked-editing"
lsp.contentMapperCallHierarchyRegistrationID = "content-mapper-call-hierarchy"
lsp.contentMapperWillRenameFilesRegistrationID = "content-mapper-will-rename-files"

function Server:supportsContentMapperRegistration(id)
    local td = self.clientCapabilities.textDocument
    if id == lsp.contentMapperDidOpenRegistrationID or id == lsp.contentMapperDidChangeRegistrationID or id == lsp.contentMapperDidCloseRegistrationID then
        return td.synchronization.dynamicRegistration
    elseif id == lsp.contentMapperDiagnosticRegistrationID then
        return td.diagnostic.dynamicRegistration
    elseif id == lsp.contentMapperHoverRegistrationID then
        return td.hover.dynamicRegistration
    elseif id == lsp.contentMapperSignatureHelpRegistrationID then
        return td.signatureHelp.dynamicRegistration
    elseif id == lsp.contentMapperDefinitionRegistrationID then
        return td.definition.dynamicRegistration
    elseif id == lsp.contentMapperTypeDefinitionRegistrationID then
        return td.typeDefinition.dynamicRegistration
    elseif id == lsp.contentMapperImplementationRegistrationID then
        return td.implementation.dynamicRegistration
    elseif id == lsp.contentMapperReferencesRegistrationID then
        return td.references.dynamicRegistration
    elseif id == lsp.contentMapperDocumentHighlightRegistrationID then
        return td.documentHighlight.dynamicRegistration
    elseif id == lsp.contentMapperCompletionRegistrationID then
        return td.completion.dynamicRegistration
    elseif id == lsp.contentMapperRenameRegistrationID then
        return td.rename.dynamicRegistration
    elseif id == lsp.contentMapperSemanticTokensRegistrationID then
        return td.semanticTokens.dynamicRegistration
    elseif id == lsp.contentMapperDocumentSymbolRegistrationID then
        return td.documentSymbol.dynamicRegistration
    elseif id == lsp.contentMapperFoldingRangeRegistrationID then
        return td.foldingRange.dynamicRegistration
    elseif id == lsp.contentMapperSelectionRangeRegistrationID then
        return td.selectionRange.dynamicRegistration
    elseif id == lsp.contentMapperInlayHintRegistrationID then
        return td.inlayHint.dynamicRegistration
    elseif id == lsp.contentMapperCodeLensRegistrationID then
        return td.codeLens.dynamicRegistration
    elseif id == lsp.contentMapperCodeActionRegistrationID then
        return td.codeAction.dynamicRegistration
    elseif id == lsp.contentMapperFormattingRegistrationID then
        return td.formatting.dynamicRegistration
    elseif id == lsp.contentMapperRangeFormattingRegistrationID then
        return td.rangeFormatting.dynamicRegistration
    elseif id == lsp.contentMapperOnTypeFormattingRegistrationID then
        return td.onTypeFormatting.dynamicRegistration
    elseif id == lsp.contentMapperLinkedEditingRegistrationID then
        return td.linkedEditingRange.dynamicRegistration
    elseif id == lsp.contentMapperCallHierarchyRegistrationID then
        return td.callHierarchy.dynamicRegistration
    elseif id == lsp.contentMapperWillRenameFilesRegistrationID then
        return self.clientCapabilities.workspace.fileOperations.dynamicRegistration and
            self.clientCapabilities.workspace.fileOperations.willRename
    end
    return false
end

-- slices.DeleteFunc(registrations, func(r) bool { return !s.supportsContentMapperRegistration(r.Id) })
function Server:filterSupportedContentMapperRegistrations(registrations)
    local result = {}
    for _, r in ipairs(registrations) do
        if self:supportsContentMapperRegistration(r.id) then
            result[#result + 1] = r
        end
    end
    return result
end

-- RegisterContentMapperExtensions implements project.Client. It dynamically registers text document
-- synchronization and pull diagnostics for the given otherwise unsupported file extensions so the editor forwards their
-- open/change/close notifications to the server and requests diagnostics for them. It is called with the
-- full desired set each time it changes; an empty slice removes any prior registration.
function Server:RegisterContentMapperExtensions(ctx, extensions)
    if not self.clientCapabilities.textDocument.synchronization.dynamicRegistration then
        return nil
    end

    if self.contentMapperExtensionsRegistered then
        local function unreg(id, method)
            return lsproto.Unregistration({ id = id, method = method })
        end
        local unregistrations = {
            unreg(lsp.contentMapperDidOpenRegistrationID, Method.TextDocumentDidOpen),
            unreg(lsp.contentMapperDidChangeRegistrationID, Method.TextDocumentDidChange),
            unreg(lsp.contentMapperDidCloseRegistrationID, Method.TextDocumentDidClose),
            unreg(lsp.contentMapperDiagnosticRegistrationID, Method.TextDocumentDiagnostic),
            unreg(lsp.contentMapperHoverRegistrationID, Method.TextDocumentHover),
            unreg(lsp.contentMapperSignatureHelpRegistrationID, Method.TextDocumentSignatureHelp),
            unreg(lsp.contentMapperDefinitionRegistrationID, Method.TextDocumentDefinition),
            unreg(lsp.contentMapperTypeDefinitionRegistrationID, Method.TextDocumentTypeDefinition),
            unreg(lsp.contentMapperImplementationRegistrationID, Method.TextDocumentImplementation),
            unreg(lsp.contentMapperReferencesRegistrationID, Method.TextDocumentReferences),
            unreg(lsp.contentMapperDocumentHighlightRegistrationID, Method.TextDocumentDocumentHighlight),
            unreg(lsp.contentMapperCompletionRegistrationID, Method.TextDocumentCompletion),
            unreg(lsp.contentMapperRenameRegistrationID, Method.TextDocumentRename),
            unreg(lsp.contentMapperSemanticTokensRegistrationID, Method.TextDocumentSemanticTokens),
            unreg(lsp.contentMapperDocumentSymbolRegistrationID, Method.TextDocumentDocumentSymbol),
            unreg(lsp.contentMapperFoldingRangeRegistrationID, Method.TextDocumentFoldingRange),
            unreg(lsp.contentMapperSelectionRangeRegistrationID, Method.TextDocumentSelectionRange),
            unreg(lsp.contentMapperInlayHintRegistrationID, Method.TextDocumentInlayHint),
            unreg(lsp.contentMapperCodeLensRegistrationID, Method.TextDocumentCodeLens),
            unreg(lsp.contentMapperCodeActionRegistrationID, Method.TextDocumentCodeAction),
            unreg(lsp.contentMapperFormattingRegistrationID, Method.TextDocumentFormatting),
            unreg(lsp.contentMapperRangeFormattingRegistrationID, Method.TextDocumentRangeFormatting),
            unreg(lsp.contentMapperOnTypeFormattingRegistrationID, Method.TextDocumentOnTypeFormatting),
            unreg(lsp.contentMapperLinkedEditingRegistrationID, Method.TextDocumentLinkedEditingRange),
            unreg(lsp.contentMapperCallHierarchyRegistrationID, Method.TextDocumentPrepareCallHierarchy),
            unreg(lsp.contentMapperWillRenameFilesRegistrationID, Method.WorkspaceWillRenameFiles),
        }
        unregistrations = self:filterSupportedContentMapperRegistrations(unregistrations)
        local _, err = lsp.sendClientRequest(ctx, self, lsproto.ClientUnregisterCapabilityInfo, lsproto.UnregistrationParams({
            unregisterations = unregistrations,
        }))
        if err ~= nil then
            return jsonrpc.NewError("failed to unregister content mapper text document sync: " .. jsonrpc.ErrorString(err), err)
        end
        self.contentMapperExtensionsRegistered = false
    end

    if extensions == nil or #extensions == 0 then
        return nil
    end

    local filters = {}
    for _, ext in ipairs(extensions) do
        filters[#filters + 1] = lsproto.TextDocumentFilterLanguageOrSchemeOrPattern({
            pattern = lsproto.TextDocumentFilterPattern({
                pattern = lsproto.PatternOrRelativePattern({ pattern = "**/*" .. ext }),
            }),
        })
    end
    local selector = lsproto.DocumentSelectorOrNull({ documentSelector = filters })
    local contentMapperFileRenameFilters = {}
    for _, extension in ipairs(extensions) do
        contentMapperFileRenameFilters[#contentMapperFileRenameFilters + 1] = lsproto.FileOperationFilter({
            scheme = "file",
            pattern = lsproto.FileOperationPattern({
                glob = "**/*" .. extension,
            }),
        })
    end

    local function reg(id, options)
        return lsproto.Registration({ id = id, registerOptions = lsproto.RegisterOptions(options) })
    end
    local registrations = {
        reg(lsp.contentMapperDidOpenRegistrationID, {
            textDocumentDidOpen = lsproto.TextDocumentRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperDidChangeRegistrationID, {
            textDocumentDidChange = lsproto.TextDocumentChangeRegistrationOptions({
                documentSelector = selector,
                syncKind = lsproto.TextDocumentSyncKind.Incremental,
            }),
        }),
        reg(lsp.contentMapperDidCloseRegistrationID, {
            textDocumentDidClose = lsproto.TextDocumentRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperDiagnosticRegistrationID, {
            textDocumentDiagnostic = lsproto.DiagnosticRegistrationOptions({
                documentSelector = selector,
                identifier = "typescript",
                interFileDependencies = true,
            }),
        }),
        reg(lsp.contentMapperHoverRegistrationID, {
            textDocumentHover = lsproto.HoverRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperSignatureHelpRegistrationID, {
            textDocumentSignatureHelp = lsproto.SignatureHelpRegistrationOptions({
                documentSelector = selector,
                triggerCharacters = ls.SignatureHelpTriggerCharacters,
                retriggerCharacters = ls.SignatureHelpRetriggerCharacters,
            }),
        }),
        reg(lsp.contentMapperDefinitionRegistrationID, {
            textDocumentDefinition = lsproto.DefinitionRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperTypeDefinitionRegistrationID, {
            textDocumentTypeDefinition = lsproto.TypeDefinitionRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperImplementationRegistrationID, {
            textDocumentImplementation = lsproto.ImplementationRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperReferencesRegistrationID, {
            textDocumentReferences = lsproto.ReferenceRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperDocumentHighlightRegistrationID, {
            textDocumentDocumentHighlight = lsproto.DocumentHighlightRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperCompletionRegistrationID, {
            textDocumentCompletion = lsproto.CompletionRegistrationOptions({
                documentSelector = selector,
                triggerCharacters = ls.CompletionTriggerCharacters,
                resolveProvider = true,
                completionItem = lsproto.ServerCompletionItemOptions({
                    labelDetailsSupport = true,
                }),
            }),
        }),
        reg(lsp.contentMapperRenameRegistrationID, {
            textDocumentRename = lsproto.RenameRegistrationOptions({
                documentSelector = selector,
                prepareProvider = true,
            }),
        }),
        reg(lsp.contentMapperSemanticTokensRegistrationID, {
            textDocumentSemanticTokens = lsproto.SemanticTokensRegistrationOptions({
                documentSelector = selector,
                legend = ls.SemanticTokensLegend(self.clientCapabilities.textDocument.semanticTokens),
                full = lsproto.BooleanOrSemanticTokensFullDelta({
                    boolean = true,
                }),
                range = lsproto.BooleanOrEmptyObject({
                    boolean = true,
                }),
            }),
        }),
        reg(lsp.contentMapperDocumentSymbolRegistrationID, {
            textDocumentDocumentSymbol = lsproto.DocumentSymbolRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperFoldingRangeRegistrationID, {
            textDocumentFoldingRange = lsproto.FoldingRangeRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperSelectionRangeRegistrationID, {
            textDocumentSelectionRange = lsproto.SelectionRangeRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperInlayHintRegistrationID, {
            textDocumentInlayHint = lsproto.InlayHintRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperCodeLensRegistrationID, {
            textDocumentCodeLens = lsproto.CodeLensRegistrationOptions({
                documentSelector = selector,
                resolveProvider = true,
            }),
        }),
        reg(lsp.contentMapperCodeActionRegistrationID, {
            textDocumentCodeAction = lsproto.CodeActionRegistrationOptions({
                documentSelector = selector,
                codeActionKinds = {
                    lsproto.CodeActionKind.QuickFix,
                    lsproto.CodeActionKind.SourceOrganizeImports,
                    lsproto.CodeActionKind.SourceRemoveUnusedImports,
                    lsproto.CodeActionKind.SourceSortImports,
                    lsproto.CodeActionKind.SourceFixAll,
                },
            }),
        }),
        reg(lsp.contentMapperFormattingRegistrationID, {
            textDocumentFormatting = lsproto.DocumentFormattingRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperRangeFormattingRegistrationID, {
            textDocumentRangeFormatting = lsproto.DocumentRangeFormattingRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperOnTypeFormattingRegistrationID, {
            textDocumentOnTypeFormatting = lsproto.DocumentOnTypeFormattingRegistrationOptions({
                documentSelector = selector,
                firstTriggerCharacter = "{",
                moreTriggerCharacter = { "}", ";", "\n" },
            }),
        }),
        reg(lsp.contentMapperLinkedEditingRegistrationID, {
            textDocumentLinkedEditingRange = lsproto.LinkedEditingRangeRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperCallHierarchyRegistrationID, {
            textDocumentPrepareCallHierarchy = lsproto.CallHierarchyRegistrationOptions({ documentSelector = selector }),
        }),
        reg(lsp.contentMapperWillRenameFilesRegistrationID, {
            workspaceWillRenameFiles = lsproto.FileOperationRegistrationOptions({ filters = contentMapperFileRenameFilters }),
        }),
    }
    registrations = self:filterSupportedContentMapperRegistrations(registrations)
    local _, err = lsp.sendClientRequest(ctx, self, lsproto.ClientRegisterCapabilityInfo, lsproto.RegistrationParams({
        registrations = registrations,
    }))
    if err ~= nil then
        return jsonrpc.NewError("failed to register content mapper text document sync: " .. jsonrpc.ErrorString(err), err)
    end

    self.contentMapperExtensionsRegistered = true
    return nil
end

-- RefreshDiagnostics implements project.Client.
function Server:RefreshDiagnostics(ctx)
    if not self.clientCapabilities.workspace.diagnostics.refreshSupport then
        return nil
    end

    local err = core.ContextErr(ctx)
    if err ~= nil then
        return err
    end

    -- Fire-and-forget: the client always returns null, and waiting for the response
    -- can cause the server to hang if the client is slow or unresponsive.
    -- Any response from the client will be silently ignored by the read loop.
    err = lsp.sendClientRequestFireAndForget(self, lsproto.WorkspaceDiagnosticRefreshInfo, lsproto.NoParams)
    if err ~= nil then
        return jsonrpc.NewError("failed to refresh diagnostics: " .. jsonrpc.ErrorString(err), err)
    end

    return nil
end

-- PublishDiagnostics implements project.Client.
function Server:PublishDiagnostics(ctx, params)
    return lsp.sendNotification(self, lsproto.TextDocumentPublishDiagnosticsInfo, params)
end

-- SendTelemetry implements project.Client.
function Server:SendTelemetry(ctx, telemetry)
    if not self.telemetryEnabled then
        error("SendTelemetry called with telemetry disabled", 0)
    end
    return lsp.sendNotification(self, lsproto.TelemetryEventInfo, telemetry)
end

-- time.Now().UnixMilli()
function lsp.nowMillis()
    return math.floor(project.now() * 1000)
end

-- IsActive implements project.Client.
function Server:IsActive()
    local last = self.lastRequestTimeMs
    return last == 0 or lsp.nowMillis() - last <= 60 * 1000
end

function Server:RefreshInlayHints(ctx)
    if not self.clientCapabilities.workspace.inlayHint.refreshSupport then
        return nil
    end

    local err = lsp.sendClientRequestFireAndForget(self, lsproto.WorkspaceInlayHintRefreshInfo, lsproto.NoParams)
    if err ~= nil then
        return jsonrpc.NewError("failed to refresh inlay hints: " .. jsonrpc.ErrorString(err), err)
    end
    return nil
end

function Server:RefreshCodeLens(ctx)
    if not self.clientCapabilities.workspace.codeLens.refreshSupport then
        return nil
    end

    local err = lsp.sendClientRequestFireAndForget(self, lsproto.WorkspaceCodeLensRefreshInfo, lsproto.NoParams)
    if err ~= nil then
        return jsonrpc.NewError("failed to refresh code lens: " .. jsonrpc.ErrorString(err), err)
    end
    return nil
end

-- ProgressStart implements project.Client.
function Server:ProgressStart(message, ...)
    if self.projectProgress ~= nil then
        self.projectProgress:start(message, ...)
    end
end

-- ProgressFinish implements project.Client.
function Server:ProgressFinish(message, ...)
    if self.projectProgress ~= nil then
        self.projectProgress:finish(message, ...)
    end
end

-- GetLocale implements project.Client.
function Server:GetLocale()
    return self.locale
end

-- SetLocale implements project.Client.
function Server:SetLocale(localeString)
    local newLocale = self.initLocale
    if localeString ~= "auto" then
        local parsed, ok = locale.Parse(localeString)
        if not ok then
            return
        end
        newLocale = parsed
    end
    self.locale = newLocale
end

-- %T of a decoded JSON value.
function lsp.goTypeName(v)
    local t = type(v)
    if t == "table" then
        if getmetatable(v) == json.Object or next(v) ~= nil and v[1] == nil then
            return "map[string]interface {}"
        end
        return "[]interface {}"
    elseif t == "string" then
        return "string"
    elseif t == "number" then
        return "float64"
    elseif t == "boolean" then
        return "bool"
    end
    return "<nil>"
end

-- Whether a decoded `any` value is a JSON object (Go: v.(map[string]any)).
function lsp.isJSONObject(v)
    if type(v) ~= "table" then
        return false
    end
    if getmetatable(v) == json.Object then
        return true
    end
    return getmetatable(v) == nil and (next(v) == nil or v[1] == nil)
end

-- Returns (lsutil.UserPreferences, err).
function Server:RequestConfiguration(ctx)
    local caps = lsproto.GetClientCapabilities(ctx)
    if not caps.workspace.configuration then
        local opts = self.initializationOptions
        if opts.userPreferences ~= nil then
            local userPrefs = opts.userPreferences
            self.logger:Logf(
                "received formatting options from initialization: %s\n%v",
                lsp.goTypeName(userPrefs),
                userPrefs
            )
            if lsp.isJSONObject(userPrefs) then
                return lsutil.ParseUserPreferences({ ["js/ts"] = userPrefs }), nil
            end
        end
        return lsutil.NewDefaultUserPreferences(), nil
    end
    local configs, err = lsp.sendClientRequest(ctx, self, lsproto.WorkspaceConfigurationInfo, lsproto.ConfigurationParams({
        items = {
            lsproto.ConfigurationItem({
                section = "js/ts",
            }),
            lsproto.ConfigurationItem({
                section = "typescript",
            }),
            lsproto.ConfigurationItem({
                section = "javascript",
            }),
            lsproto.ConfigurationItem({
                section = "editor",
            }),
        },
    }))
    if err ~= nil then
        return lsutil.NewDefaultUserPreferences(), jsonrpc.NewError("configure request failed: " .. jsonrpc.ErrorString(err), err)
    end
    local configMap = {}
    for i1, config in ipairs(configs or {}) do
        local i = i1 - 1
        if config == json.Null then
            config = nil
        end
        if i == 0 then
            configMap["js/ts"] = config
        elseif i == 1 then
            configMap["typescript"] = config
        elseif i == 2 then
            configMap["javascript"] = config
        elseif i == 3 then
            configMap["editor"] = config
        end
    end
    self.logger:Logf(
        "received options from workspace/configuration request:\njs/ts: %v\n\ntypescript: %v\n\njavascript: %v\n\neditor: %v\n",
        configMap["js/ts"],
        configMap["typescript"],
        configMap["javascript"],
        configMap["editor"]
    )
    return lsutil.ParseUserPreferences(configMap), nil
end

function Server:Run(ctx)
    -- errgroup.WithContext: the context is canceled once the loop returns.
    local groupCtx, cancel = core.WithCancel(ctx)
    self.backgroundCtx = groupCtx
    local err = self:loop(groupCtx)
    cancel()

    if err ~= nil and not jsonrpc.ErrorsIs(err, jsonrpc.EOF) and core.ContextErr(groupCtx) ~= nil then
        return err
    end
    return nil
end

-- loop is the sequential combination of readLoop and dispatchLoop (see the top of this file).
function Server:loop(ctx)
    local dispatchCtx, lspExit = core.WithCancel(ctx)
    while true do
        if self.fatalErr ~= nil then
            lspExit()
            return self.fatalErr
        end
        local err = core.ContextErr(dispatchCtx)
        if err ~= nil then
            return err
        end
        if self.requestQueue:Len() == 0 then
            self:idle()
        end
        if self.requestQueue:Len() == 0 then
            err = self:readOne(ctx)
            if err ~= nil then
                lspExit()
                return err
            end
        else
            self:dispatchOne(dispatchCtx, lspExit)
        end
    end
end

-- idle runs the work that proceeds concurrently in Go while the server waits for input.
function Server:idle()
    if self.session ~= nil then
        self.session:WaitForBackgroundTasks()
    end
    if self.projectProgress ~= nil then
        self.projectProgress:poll()
    end
end

-- readLoop reads and routes messages until an error ends it. In the sequential port it is not
-- run as a loop; Server:loop and sendClientRequest call readOne for each message.
function Server:readLoop(ctx)
    while true do
        local err = self:readOne(ctx)
        if err ~= nil then
            return err
        end
    end
end

-- readOne is one iteration of Go's readLoop. Returns a non-nil error when the read loop would end.
function Server:readOne(ctx)
    local err = core.ContextErr(ctx)
    if err ~= nil then
        return err
    end
    local msg
    msg, err = self:read()
    if err ~= nil then
        if jsonrpc.ErrorsIs(err, ErrorCode.InvalidRequest) or jsonrpc.ErrorsIs(err, ErrorCode.InvalidParams) then
            local id
            if jsonrpc.ErrorsIs(err, ErrorCode.InvalidParams) then
                if msg ~= nil and msg.kind == MessageKind.Request then
                    id = msg:AsRequest().id
                end
            end
            local sendErr = self:sendError(id, err)
            if sendErr ~= nil then
                return sendErr
            end
            return nil
        end
        return err
    end

    if self.initializeParams == nil and msg.kind == MessageKind.Request then
        local req = msg:AsRequest()
        if req.method == Method.Initialize then
            local params
            params, err = lsproto.UnmarshalParams(lsproto.InitializeInfo.paramsType, req)
            if err ~= nil then
                local sendErr = self:sendError(req.id, err)
                if sendErr ~= nil then
                    return sendErr
                end
                return nil
            end
            local resp
            resp, err = self:handleInitialize(ctx, params, req)
            if err ~= nil then
                return err
            end
            err = self:sendResult(req.id, resp, lsproto.InitializeInfo.resultType)
            if err ~= nil then
                return err
            end
        else
            err = self:sendError(req.id, ErrorCode.ServerNotInitialized)
            if err ~= nil then
                return err
            end
        end
        return nil
    end

    if msg.kind == MessageKind.Response then
        local resp = msg:AsResponse()
        local key = resp.id:Key()
        local pending = self.pendingServerRequests[key]
        if pending ~= nil then
            pending.resp = resp
            self.pendingServerRequests[key] = nil
        end
    else
        local req = msg:AsRequest()
        if req.method == Method.CancelRequest then
            local params, perr = lsproto.UnmarshalParams(lsproto.CancelRequestInfo.paramsType, req)
            if perr == nil and params ~= nil then
                self:cancelRequest(params.id)
            end
        else
            err = self.requestQueue:Put(ctx, req)
            if err ~= nil then
                return err
            end
        end
    end
    return nil
end

function Server:cancelRequest(rawID)
    local id = lsproto.NewID(rawID)
    local pendingReq = self.pendingClientRequests[id:Key()]
    if pendingReq ~= nil then
        pendingReq.cancel()
        self.pendingClientRequests[id:Key()] = nil
    end
end

-- Returns (msg, err).
function Server:read()
    return self.r:Read()
end

-- dispatchLoop handles queued requests until its context ends. In the sequential port it is not
-- run as a loop; Server:loop calls dispatchOne for each queued request.
function Server:dispatchLoop(ctx)
    local dispatchCtx, lspExit = core.WithCancel(ctx)
    while true do
        local err = core.ContextErr(dispatchCtx)
        if err ~= nil or self.requestQueue:Len() == 0 then
            lspExit()
            return err
        end
        self:dispatchOne(dispatchCtx, lspExit)
    end
end

-- dispatchOne is one iteration of Go's dispatchLoop; asynchronous work runs before it returns.
function Server:dispatchOne(ctx, lspExit)
    local req, err = self.requestQueue:Get(ctx)
    if err ~= nil then
        lspExit()
        return
    end

    self.lastRequestTimeMs = lsp.nowMillis()
    local requestCtx = locale.WithLocale(ctx, self:GetLocale())
    local cancel
    if req.id ~= nil then
        requestCtx, cancel = core.WithCancel(core.WithRequestID(requestCtx, req.id:String()))
        self.pendingClientRequests[req.id:Key()] = {
            req = req,
            cancel = cancel,
        }
    end

    local function handleError(handlerErr)
        if jsonrpc.ErrorsIs(handlerErr, core.Canceled) then
            if self:sendError(req.id, ErrorCode.RequestCancelled) ~= nil then
                lspExit()
            end
        elseif jsonrpc.ErrorsIs(handlerErr, jsonrpc.EOF) then
            lspExit()
        else
            if self:sendError(req.id, handlerErr) ~= nil then
                lspExit()
            end
        end
    end

    local function removeRequest()
        if req.id ~= nil then
            self.pendingClientRequests[req.id:Key()] = nil
            cancel()
        end
    end

    local doAsyncWork
    doAsyncWork, err = self:handleRequestOrNotification(requestCtx, req)
    if err ~= nil then
        handleError(err)
        removeRequest()
    elseif doAsyncWork ~= nil then
        -- Go runs the asynchronous work on its own goroutine.
        local lsError = doAsyncWork()
        if lsError ~= nil then
            handleError(lsError)
        end
        removeRequest()
    else
        removeRequest()
    end
end

-- writeLoop writes queued outgoing messages. In the sequential port messages are written as
-- soon as they are queued (flushOutgoing); this drains what is queued.
function Server:writeLoop(ctx)
    self:flushOutgoing()
    return self.fatalErr
end

-- flushOutgoing is the body of Go's writeLoop, run until the outgoing queue is empty. A write
-- error that ends the write loop is kept in fatalErr and ends Server:loop.
function Server:flushOutgoing()
    if self.flushing or self.fatalErr ~= nil then
        return
    end
    self.flushing = true
    while self.outgoingQueue:Len() > 0 do
        local msg = self.outgoingQueue:Get(nil)
        local err = self.w:Write(msg)
        if err ~= nil then
            local handled = false
            if type(err) == "table" and getmetatable(err) == messageMarshalError and msg.kind == MessageKind.Response then
                local resp = msg:AsResponse()
                if resp.id ~= nil and resp.error == nil then
                    self.logger:Errorf("failed to marshal response for request %s: %v", resp.id:String(), err)
                    local sendErr = self:sendError(resp.id, err)
                    if sendErr ~= nil then
                        self.fatalErr = sendErr
                        break
                    end
                    handled = true
                end
            end
            if not handled then
                self.fatalErr = jsonrpc.NewError("failed to write message: " .. jsonrpc.ErrorString(err), err)
                break
            end
        end
    end
    self.flushing = false
end

-- WARNING: this should only be called in the async portion of a request handler,
-- otherwise a deadlock can occur.
-- Returns (Resp, err). While waiting, further messages are read: responses are routed and
-- requests/notifications are queued for the dispatch loop.
function lsp.sendClientRequest(ctx, s, info, params)
    s.clientSeq = s.clientSeq + 1
    local id = jsonrpc.NewIDString("ts" .. tostring(s.clientSeq))
    local req = info:NewRequestMessage(id, params)

    local pending = { resp = nil }
    s.pendingServerRequests[id:Key()] = pending

    local function cleanup()
        s.pendingServerRequests[id:Key()] = nil
    end

    local err = s:send(req:Message())
    if err ~= nil then
        cleanup()
        return lsproto.Zero(info.resultType), err
    end

    while pending.resp == nil do
        err = core.ContextErr(ctx)
        if err ~= nil then
            cleanup()
            return lsproto.Zero(info.resultType), err
        end
        if s.fatalErr ~= nil then
            cleanup()
            return lsproto.Zero(info.resultType), s.fatalErr
        end
        err = s:readOne(s.backgroundCtx)
        if err ~= nil then
            -- The read loop has ended; Go's errgroup cancels the server context.
            s.fatalErr = err
            cleanup()
            return lsproto.Zero(info.resultType), err
        end
    end
    cleanup()

    local resp = pending.resp
    if resp.error ~= nil then
        return lsproto.Zero(info.resultType), jsonrpc.NewError("request failed: " .. resp.error:String())
    end
    return info:UnmarshalResult(resp.result)
end

-- sendClientRequestFireAndForget sends a request to the client without waiting for a response.
-- The response, if any, will be silently ignored by the read loop since no pending channel is registered.
-- This means any error returned by the client will not be observed. Use only for requests where the
-- response value is not needed (e.g., the client always returns null).
function lsp.sendClientRequestFireAndForget(s, info, params)
    s.clientSeq = s.clientSeq + 1
    local id = jsonrpc.NewIDString("ts" .. tostring(s.clientSeq))
    local req = info:NewRequestMessage(id, params)
    return s:send(req:Message())
end

-- resultType (Lua-only) is the Go type string of result (the handler's Resp type parameter).
function Server:sendResult(id, result, resultType)
    return self:sendResponse(lsproto.NewResponseMessage(id, result, nil, resultType))
end

-- userFacingRequestFailedError is a string error that unwraps to ErrorCode.RequestFailed.
local userFacingRequestFailedError = {}
userFacingRequestFailedError.__index = userFacingRequestFailedError
lsp.userFacingRequestFailedError = userFacingRequestFailedError

function lsp.newUserFacingRequestFailedError(message)
    return setmetatable({ message = message, unwrap = ErrorCode.RequestFailed }, userFacingRequestFailedError)
end

function userFacingRequestFailedError:Error()
    return self.message
end

-- errors.AsType[userFacingRequestFailedError](err): (err, ok).
function lsp.asUserFacingRequestFailedError(err)
    local found = jsonrpc.ErrorsFind(err, function(e)
        return type(e) == "table" and getmetatable(e) == userFacingRequestFailedError
    end)
    return found, found ~= nil
end

function Server:sendError(id, err)
    -- Do not send error response for notifications,
    -- except for parse errors which may occur before determining if the message is a request or notification.
    if id == nil and not jsonrpc.ErrorsIs(err, ErrorCode.InvalidRequest) then
        self.logger:Errorf("error handling notification: %s", jsonrpc.ErrorString(err))
        return nil
    end
    local code = ErrorCode.InternalError
    local errCode = jsonrpc.ErrorsFind(err, function(e)
        return math.type(e) == "integer"
    end)
    if errCode ~= nil then
        code = errCode
    end
    -- TODO(jakebailey): error data
    return self:sendResponse(lsproto.NewResponseMessage(id, nil, jsonrpc.NewResponseError(code, jsonrpc.ErrorString(err))))
end

function lsp.sendNotification(s, info, params)
    return s:send(info:NewNotificationMessage(params):Message())
end

function Server:sendResponse(resp)
    return self:send(resp:Message())
end

-- send writes a message to the outgoing queue, respecting context cancellation.
function Server:send(msg)
    local err = self.outgoingQueue:Put(self.backgroundCtx, msg)
    if err ~= nil then
        return err
    end
    self:flushOutgoing()
    return nil
end

-- Calls f(); a Lua error raised by f is a Go panic recovered by s.recover(req) (`defer s.recover(req)`).
-- Returns f's results, or nothing after a recovered panic (Go's zero results).
function Server:withRecover(req, f)
    local results
    local ok, perr = xpcall(function()
        results = table.pack(f())
    end, function(e)
        return { value = e, stack = debug.traceback(nil, 2) }
    end)
    if not ok then
        self:recover(req, perr.value, perr.stack)
        return
    end
    return table.unpack(results, 1, results.n)
end

-- handleRequestOrNotification looks up the handler for the given request or notification, executes its synchronous work
-- and returns any asynchronous work as a function to be executed by the caller.
-- Returns (asyncWork, err).
function Server:handleRequestOrNotification(ctx, req)
    ctx = lsproto.WithClientCapabilities(ctx, self.clientCapabilities)

    local handler = lsp.handlers()[req.method]
    if handler ~= nil then
        local start = project.now()
        local doAsyncWork, err = handler(self, ctx, req)
        local idStr = ""
        if req.id ~= nil then
            idStr = " (" .. req.id:String() .. ")"
        end
        if err ~= nil then
            local resp, ok = lsp.contentMapperFallbackResponse(req.method, err)
            if ok then
                if not self.logger:IsTracing() then
                    self.logger:Info("handled method '", req.method, "'", idStr, " in ", project.since(start))
                end
                return nil, self:sendResult(req.id, resp.value, resp.goType)
            end
            local _, isUserFacing = lsp.asUserFacingRequestFailedError(err)
            if not isUserFacing then
                self.logger:Error("error handling method '", req.method, "'", idStr, ": ", jsonrpc.ErrorString(err))
            elseif not self.logger:IsTracing() then
                self.logger:Info("handled method '", req.method, "'", idStr, " in ", project.since(start))
            end
            return nil, err
        end
        if doAsyncWork ~= nil then
            return function()
                -- note: ctx.Err() has to be checked in the async work to allow async handlers to cleanup resources correctly
                local asyncWorkErr = doAsyncWork()
                local _, isUserFacing = lsp.asUserFacingRequestFailedError(asyncWorkErr)
                local isRealError = asyncWorkErr ~= nil and not isUserFacing
                if isRealError then
                    self.logger:Info("error handling method '", req.method, "'", idStr, " in ", project.since(start))
                elseif not self.logger:IsTracing() then
                    self.logger:Info("handled method '", req.method, "'", idStr, " in ", project.since(start))
                end
                return asyncWorkErr
            end, nil
        end
        if not self.logger:IsTracing() then
            self.logger:Info("handled method '", req.method, "'", idStr, " in ", project.since(start))
        end
        return nil, nil
    end
    self.logger:Warn("unknown method '", req.method, "'")
    if req.id ~= nil then
        return nil, self:sendError(req.id, ErrorCode.InvalidRequest)
    end
    return nil, nil
end

-- contentMapperFallbackResponse returns an empty response for requests made for
-- unknown file types not handled by any content mapper. This typically serves a
-- short window in time between when the server has unregistered content mapper
-- extensions and when the client has stopped sending requests for those file types.
-- Returns ({ value, goType }, ok).
function lsp.contentMapperFallbackResponse(method, err)
    if not jsonrpc.ErrorsIs(err, project.ErrNoProjectForUnknownScriptKind) then
        return nil, false
    end
    if method == Method.TextDocumentDiagnostic then
        return {
            value = lsproto.DocumentDiagnosticResponse({
                fullDocumentDiagnosticReport = lsproto.RelatedFullDocumentDiagnosticReport({
                    items = {},
                }),
            }),
            goType = "DocumentDiagnosticResponse",
        }, true
    elseif method == Method.TextDocumentHover or
        method == Method.TextDocumentSignatureHelp or
        method == Method.TextDocumentDefinition or
        method == Method.TextDocumentTypeDefinition or
        method == Method.TextDocumentImplementation or
        method == Method.TextDocumentReferences or
        method == Method.TextDocumentDocumentHighlight or
        method == Method.TextDocumentCompletion or
        method == Method.TextDocumentRename then
        return { value = lsproto.Null, goType = "Null" }, true
    end
    return nil, false
end

-- handlerMap maps LSP method to a handler function. The handler function executes any work that must be done synchronously
-- before other requests/notifications can be processed, and returns any additional work as a function to be executed
-- asynchronously after the synchronous work is complete.
--   handler(s, ctx, req) -> (asyncWork, err)

-- handlers is a sync.OnceValue.
function lsp.handlers()
    if lsp.handlersValue ~= nil then
        return lsp.handlersValue
    end
    local handlers = {}
    local S = Server

    lsp.registerRequestHandler(handlers, lsproto.InitializeInfo, S.handleInitialize)
    lsp.registerNotificationHandler(handlers, lsproto.InitializedInfo, S.handleInitialized)
    lsp.registerRequestHandler(handlers, lsproto.ShutdownInfo, S.handleShutdown)
    lsp.registerNotificationHandler(handlers, lsproto.ExitInfo, S.handleExit)

    lsp.registerNotificationHandler(handlers, lsproto.WorkspaceDidChangeConfigurationInfo, S.handleDidChangeWorkspaceConfiguration)
    lsp.registerNotificationHandler(handlers, lsproto.TextDocumentDidOpenInfo, S.handleDidOpen)
    lsp.registerNotificationHandler(handlers, lsproto.TextDocumentDidChangeInfo, S.handleDidChange)
    lsp.registerNotificationHandler(handlers, lsproto.TextDocumentDidSaveInfo, S.handleDidSave)
    lsp.registerNotificationHandler(handlers, lsproto.TextDocumentDidCloseInfo, S.handleDidClose)
    lsp.registerNotificationHandler(handlers, lsproto.WorkspaceDidChangeWatchedFilesInfo, S.handleDidChangeWatchedFiles)
    lsp.registerNotificationHandler(handlers, lsproto.SetTraceInfo, S.handleSetTrace)
    lsp.registerNotificationHandler(handlers, lsproto.CustomSetLogVerbosityInfo, S.handleSetLogVerbosity)
    lsp.registerRequestHandler(handlers, lsproto.WorkspaceWillRenameFilesInfo, S.handleWillRenameFiles)

    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentDiagnosticInfo, S.handleDocumentDiagnostic)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentHoverInfo, S.handleHover)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentDefinitionInfo, S.handleDefinition)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.CustomTextDocumentSourceDefinitionInfo, S.handleSourceDefinition)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentTypeDefinitionInfo, S.handleTypeDefinition)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentSignatureHelpInfo, S.handleSignatureHelp)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentFormattingInfo, S.handleDocumentFormat)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentRangeFormattingInfo, S.handleDocumentRangeFormat)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentOnTypeFormattingInfo, S.handleDocumentOnTypeFormat)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentDocumentSymbolInfo, S.handleDocumentSymbol)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentDocumentHighlightInfo, S.handleDocumentHighlight)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.CustomTextDocumentMultiDocumentHighlightInfo, S.handleMultiDocumentHighlight)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentSelectionRangeInfo, S.handleSelectionRange)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentInlayHintInfo, S.handleInlayHint)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentCodeLensInfo, S.handleCodeLens)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentCodeActionInfo, S.handleCodeAction)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentPrepareCallHierarchyInfo, S.handlePrepareCallHierarchy)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentFoldingRangeInfo, S.handleFoldingRange)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentPrepareRenameInfo, S.handlePrepareRename)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentLinkedEditingRangeInfo, S.handleLinkedEditingRange)

    lsp.registerLanguageServiceWithAutoImportsRequestHandler(handlers, lsproto.TextDocumentCompletionInfo, S.handleCompletion)
    lsp.registerLanguageServiceWithAutoImportsRequestHandler(handlers, lsproto.TextDocumentCodeActionInfo, S.handleCodeAction)

    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentVSOnAutoInsertInfo, S.handleVSOnAutoInsert)

    lsp.registerMultiProjectReferenceRequestHandler(handlers, lsproto.TextDocumentReferencesInfo, ls.LanguageService.ProvideReferences)
    lsp.registerMultiProjectReferenceRequestHandler(handlers, lsproto.TextDocumentVSReferencesInfo, ls.LanguageService.ProvideVSReferences)
    lsp.registerRequestHandler(handlers, lsproto.TextDocumentRenameInfo, S.handleRename)
    lsp.registerMultiProjectReferenceRequestHandler(handlers, lsproto.TextDocumentImplementationInfo, ls.LanguageService.ProvideImplementations)

    lsp.registerRequestHandler(handlers, lsproto.CallHierarchyIncomingCallsInfo, S.handleCallHierarchyIncomingCalls)
    lsp.registerRequestHandler(handlers, lsproto.CallHierarchyOutgoingCallsInfo, S.handleCallHierarchyOutgoingCalls)

    lsp.registerRequestHandler(handlers, lsproto.WorkspaceSymbolInfo, S.handleWorkspaceSymbol)
    lsp.registerRequestHandler(handlers, lsproto.CompletionItemResolveInfo, S.handleCompletionItemResolve)
    lsp.registerRequestHandler(handlers, lsproto.CodeLensResolveInfo, S.handleCodeLensResolve)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentSemanticTokensFullInfo, S.handleSemanticTokensFull)
    lsp.registerLanguageServiceDocumentRequestHandler(handlers, lsproto.TextDocumentSemanticTokensRangeInfo, S.handleSemanticTokensRange)

    -- Developer/debugging commands
    lsp.registerRequestHandler(handlers, lsproto.CustomRunGCInfo, S.handleRunGC)
    lsp.registerRequestHandler(handlers, lsproto.CustomSaveHeapProfileInfo, S.handleSaveHeapProfile)
    lsp.registerRequestHandler(handlers, lsproto.CustomSaveAllocProfileInfo, S.handleSaveAllocProfile)
    lsp.registerRequestHandler(handlers, lsproto.CustomStartCPUProfileInfo, S.handleStartCPUProfile)
    lsp.registerRequestHandler(handlers, lsproto.CustomStopCPUProfileInfo, S.handleStopCPUProfile)

    lsp.registerRequestHandler(handlers, lsproto.CustomInitializeAPISessionInfo, S.handleInitializeAPISession)
    lsp.registerRequestHandler(handlers, lsproto.CustomProjectInfoInfo, S.handleProjectInfo)
    lsp.registerRequestHandler(handlers, lsproto.CustomSetContentMapperContributionsInfo, S.handleSetContentMapperContributions)
    lsp.handlersValue = handlers
    return handlers
end

function lsp.registerNotificationHandler(handlers, info, fn)
    handlers[info.Method] = function(s, ctx, req)
        if s.session == nil and req.method ~= Method.Initialized then
            return nil, ErrorCode.ServerNotInitialized
        end

        local params, err = lsproto.UnmarshalParams(info.paramsType, req)
        if err ~= nil then
            return nil, err
        end
        err = fn(s, ctx, params)
        if err ~= nil then
            return nil, err
        end
        return nil, core.ContextErr(ctx)
    end
end

function lsp.registerRequestHandler(handlers, info, fn)
    handlers[info.Method] = function(s, ctx, req)
        if s.session == nil and req.method ~= Method.Initialize then
            return nil, ErrorCode.ServerNotInitialized
        end

        local params, err = lsproto.UnmarshalParams(info.paramsType, req)
        if err ~= nil then
            return nil, err
        end
        local resp
        resp, err = fn(s, ctx, params, req)
        if err ~= nil then
            return nil, err
        end
        if core.ContextErr(ctx) ~= nil then
            return nil, core.ContextErr(ctx)
        end
        return nil, s:sendResult(req.id, resp, info.resultType)
    end
end

function lsp.registerLanguageServiceDocumentRequestHandler(handlers, info, fn)
    handlers[info.Method] = function(s, ctx, req)
        local params, err = lsproto.UnmarshalParams(info.paramsType, req)
        if err ~= nil then
            return nil, err
        end
        local languageService
        languageService, err = s.session:GetLanguageService(ctx, params:TextDocumentURI())
        if err ~= nil then
            return nil, err
        end
        return function()
            return s:withRecover(req, function()
                local resp, lsErr = fn(s, ctx, languageService, params)
                -- After any language service request, check if new global diagnostics were
                -- discovered during checking and push updated tsconfig diagnostics if so.
                s.session:EnqueuePublishGlobalDiagnostics()
                if lsErr ~= nil then
                    return lsErr
                end
                if core.ContextErr(ctx) ~= nil then
                    return core.ContextErr(ctx)
                end
                return s:sendResult(req.id, resp, info.resultType)
            end)
        end, nil
    end
end

function lsp.registerLanguageServiceWithAutoImportsRequestHandler(handlers, info, fn)
    handlers[info.Method] = function(s, ctx, req)
        local params, err = lsproto.UnmarshalParams(info.paramsType, req)
        if err ~= nil then
            return nil, err
        end
        return s.session:WithLanguageServiceAndSnapshot(ctx, params:TextDocumentURI(), function(languageService, snapshot)
            return function()
                return s:withRecover(req, function()
                    local resp, lsErr = fn(s, ctx, languageService, params)
                    if jsonrpc.ErrorsIs(lsErr, ls.ErrNeedsAutoImports) then
                        languageService, lsErr = s.session:GetLanguageServiceWithAutoImports(ctx, snapshot, params:TextDocumentURI())
                        if lsErr ~= nil then
                            return lsErr
                        end
                        if core.ContextErr(ctx) ~= nil then
                            return core.ContextErr(ctx)
                        end
                        resp, lsErr = fn(s, ctx, languageService, params)
                        if jsonrpc.ErrorsIs(lsErr, ls.ErrNeedsAutoImports) then
                            error(info.Method .. " returned ErrNeedsAutoImports even after enabling auto imports", 0)
                        end
                    end
                    if lsErr ~= nil then
                        return lsErr
                    end
                    if core.ContextErr(ctx) ~= nil then
                        return core.ContextErr(ctx)
                    end
                    return s:sendResult(req.id, resp, info.resultType)
                end)
            end, nil
        end)
    end
end

-- fn is a LanguageService method: fn(languageService, ctx, params, orchestrator) -> (Resp, err).
function lsp.registerMultiProjectReferenceRequestHandler(handlers, info, fn)
    handlers[info.Method] = function(s, ctx, req)
        local params, err = lsproto.UnmarshalParams(info.paramsType, req)
        if err ~= nil then
            return nil, err
        end
        -- !!! sheetal: multiple projects that contain the file through symlinks
        local defaultLs, orchestrator
        defaultLs, orchestrator, err = s:getLanguageServiceAndCrossProjectOrchestrator(ctx, params:TextDocumentURI(), req)
        if err ~= nil then
            return nil, err
        end
        return function()
            return s:withRecover(req, function()
                local resp, lsErr = fn(defaultLs, ctx, params, orchestrator)
                if lsErr ~= nil then
                    return lsErr
                end
                if core.ContextErr(ctx) ~= nil then
                    return core.ContextErr(ctx)
                end
                return s:sendResult(req.id, resp, info.resultType)
            end)
        end, nil
    end
end

local crossProjectOrchestrator = {}
crossProjectOrchestrator.__index = crossProjectOrchestrator
lsp.crossProjectOrchestrator = crossProjectOrchestrator

function crossProjectOrchestrator:GetDefaultProject()
    return self.defaultProject
end

function crossProjectOrchestrator:GetAllProjectsForInitialRequest()
    return self.allProjects
end

function crossProjectOrchestrator:GetLanguageServiceForProjectWithFile(ctx, p, uri)
    return self.server.session:GetLanguageServiceForProjectWithFile(ctx, p, uri)
end

-- Returns ([]ls.Project, err).
function crossProjectOrchestrator:GetProjectsForFile(ctx, uri)
    return self.server.session:GetProjectsForFile(ctx, uri)
end

-- Returns an array of projects (Go: iter.Seq[ls.Project]); the snapshot is loaded once.
function crossProjectOrchestrator:GetProjectsLoadingProjectTree(ctx, requestedProjectTrees)
    local result = {}
    self.server.session:WithSnapshotLoadingProjectTree(ctx, requestedProjectTrees, function(snapshot)
        for _, p in ipairs(snapshot.projectCollection:Projects()) do
            result[#result + 1] = p
        end
    end)
    return result
end

-- Returns (languageService, orchestrator, err).
function Server:getLanguageServiceAndCrossProjectOrchestrator(ctx, uri, req)
    local defaultProject, defaultLs, allProjects, err = self.session:GetLanguageServiceAndProjectsForFile(ctx, uri)
    local orchestrator
    if err == nil then
        orchestrator = setmetatable({ server = self, req = req, defaultProject = defaultProject, allProjects = allProjects }, crossProjectOrchestrator)
    end
    return defaultLs, orchestrator, err
end

-- recover handles a recovered panic r (with its Lua traceback) while handling req.
function Server:recover(req, r, stack)
    if r ~= nil then
        stack = stack or ""
        self.logger:Errorf("panic handling request %s: %v\n%s", req.method, r, stack)
        if req.id ~= nil then
            self:sendError(req.id, jsonrpc.NewError(lsproto.ErrorCode_String(ErrorCode.InternalError) .. ": panic handling request " .. req.method .. ": " .. logging.fmtValue(r), ErrorCode.InternalError))
        else
            self.logger:Error("unhandled panic in notification", req.method, r)
        end

        if self.telemetryEnabled then
            lsp.sendNotification(self, lsproto.TelemetryEventInfo, lsproto.TelemetryEvent({
                requestFailureTelemetryEvent = lsproto.RequestFailureTelemetryEvent({
                    properties = lsproto.RequestFailureTelemetryProperties({
                        errorCode = lsproto.ErrorCode_String(ErrorCode.InternalError),
                        requestMethod = (string.gsub(req.method, "/", ".")),
                        stack = lsp.sanitizeStackTrace(stack),
                    }),
                }),
            }))
        end
    end
end

-- Returns (InitializeResponse, err).
function Server:handleInitialize(ctx, params, _)
    if self.initializeParams ~= nil then
        return nil, ErrorCode.InvalidRequest
    end

    self.initStarted = true

    self.initializeParams = params
    -- The spec types initializationOptions as nullable; treat both null and an
    -- absent value as empty options so the rest of the server can read fields
    -- off s.initializationOptions without nil-checking the container.
    if params.initializationOptions ~= nil and params.initializationOptions.initializationOptions ~= nil then
        self.initializationOptions = params.initializationOptions.initializationOptions
    else
        self.initializationOptions = lsproto.InitializationOptions({})
    end
    if self.initializationOptions.logVerbosity ~= nil then
        local v = self.initializationOptions.logVerbosity
        if lsp.isValidLogVerbosity(v) then
            self.logger:SetVerbosity(v)
        end
    end
    if self.initializationOptions.trackFlakyDiagnostics ~= nil then
        self.flakeLogging = self.initializationOptions.trackFlakyDiagnostics
    end
    self.clientCapabilities = lsproto.ClientCapabilities.Resolve(params.capabilities)
    if self.clientCapabilities.window.workDoneProgress then
        self.projectProgress = lsp.newProjectLoadingProgress(self, self.progressDelay)
    end

    local capabilitiesJSON, err = json.MarshalIndent(self.clientCapabilities, "", "\t")
    if err ~= nil then
        return nil, err
    end
    self.logger:Info("Resolved client capabilities: " .. capabilitiesJSON)

    self.positionEncoding = lsproto.PositionEncodingKind.UTF16
    for _, enc in ipairs(self.clientCapabilities.general.positionEncodings or {}) do
        if enc == lsproto.PositionEncodingKind.UTF8 then
            self.positionEncoding = lsproto.PositionEncodingKind.UTF8
            break
        end
    end

    if self.initializeParams.locale ~= nil then
        self.locale = locale.Parse(self.initializeParams.locale)
    end
    self.initLocale = self.locale

    if self.startWatchdog ~= nil and params.processId.integer ~= nil then
        self.startWatchdog(params.processId.integer)
    end

    local response = lsproto.InitializeResult({
        serverInfo = lsproto.ServerInfo({
            name = "typescript-go",
            version = core.Version(),
        }),
        capabilities = lsproto.ServerCapabilities({
            positionEncoding = self.positionEncoding,
            textDocumentSync = lsproto.TextDocumentSyncOptionsOrKind({
                options = lsproto.TextDocumentSyncOptions({
                    openClose = true,
                    change = lsproto.TextDocumentSyncKind.Incremental,
                    save = lsproto.BooleanOrSaveOptions({
                        boolean = true,
                    }),
                }),
            }),
            hoverProvider = lsproto.BooleanOrHoverOptions({
                boolean = true,
            }),
            definitionProvider = lsproto.BooleanOrDefinitionOptions({
                boolean = true,
            }),
            typeDefinitionProvider = lsproto.BooleanOrTypeDefinitionOptionsOrTypeDefinitionRegistrationOptions({
                boolean = true,
            }),
            referencesProvider = lsproto.BooleanOrReferenceOptions({
                boolean = true,
            }),
            implementationProvider = lsproto.BooleanOrImplementationOptionsOrImplementationRegistrationOptions({
                boolean = true,
            }),
            diagnosticProvider = lsproto.DiagnosticOptionsOrRegistrationOptions({
                options = lsproto.DiagnosticOptions({
                    identifier = "typescript",
                    interFileDependencies = true,
                }),
            }),
            completionProvider = lsproto.CompletionOptions({
                triggerCharacters = ls.CompletionTriggerCharacters,
                resolveProvider = true,
                completionItem = lsproto.ServerCompletionItemOptions({
                    labelDetailsSupport = true,
                }),
            }),
            signatureHelpProvider = lsproto.SignatureHelpOptions({
                triggerCharacters = ls.SignatureHelpTriggerCharacters,
                retriggerCharacters = ls.SignatureHelpRetriggerCharacters,
            }),
            documentFormattingProvider = lsproto.BooleanOrDocumentFormattingOptions({
                boolean = true,
            }),
            documentRangeFormattingProvider = lsproto.BooleanOrDocumentRangeFormattingOptions({
                boolean = true,
            }),
            documentOnTypeFormattingProvider = lsproto.DocumentOnTypeFormattingOptions({
                firstTriggerCharacter = "{",
                moreTriggerCharacter = { "}", ";", "\n" },
            }),
            workspaceSymbolProvider = lsproto.BooleanOrWorkspaceSymbolOptions({
                boolean = true,
            }),
            documentSymbolProvider = lsproto.BooleanOrDocumentSymbolOptions({
                boolean = true,
            }),
            foldingRangeProvider = lsproto.BooleanOrFoldingRangeOptionsOrFoldingRangeRegistrationOptions({
                boolean = true,
            }),
            renameProvider = lsproto.BooleanOrRenameOptions({
                renameOptions = lsproto.RenameOptions({
                    prepareProvider = true,
                }),
            }),
            documentHighlightProvider = lsproto.BooleanOrDocumentHighlightOptions({
                boolean = true,
            }),
            selectionRangeProvider = lsproto.BooleanOrSelectionRangeOptionsOrSelectionRangeRegistrationOptions({
                boolean = true,
            }),
            linkedEditingRangeProvider = lsproto.BooleanOrLinkedEditingRangeOptionsOrLinkedEditingRangeRegistrationOptions({
                boolean = true,
            }),
            inlayHintProvider = lsproto.BooleanOrInlayHintOptionsOrInlayHintRegistrationOptions({
                boolean = true,
            }),
            codeLensProvider = lsproto.CodeLensOptions({
                resolveProvider = true,
            }),
            codeActionProvider = lsproto.BooleanOrCodeActionOptions({
                codeActionOptions = lsproto.CodeActionOptions({
                    codeActionKinds = {
                        lsproto.CodeActionKind.QuickFix,
                        lsproto.CodeActionKind.SourceOrganizeImports,
                        lsproto.CodeActionKind.SourceRemoveUnusedImports,
                        lsproto.CodeActionKind.SourceSortImports,
                        lsproto.CodeActionKind.SourceFixAll,
                    },
                }),
            }),
            callHierarchyProvider = lsproto.BooleanOrCallHierarchyOptionsOrCallHierarchyRegistrationOptions({
                boolean = true,
            }),
            experimental = lsproto.ExperimentalServerCapabilities({
                customSourceDefinitionProvider = true,
                customMultiDocumentHighlightProvider = true,
            }),
            vsReferencesProvider = true,
            vsOnAutoInsertProvider = lsproto.VSOnAutoInsertOptions({
                vsTriggerCharacters = { ">" },
            }),
            workspace = lsproto.WorkspaceOptions({
                fileOperations = lsproto.FileOperationOptions({
                    willRename = lsproto.FileOperationRegistrationOptions({
                        filters = lsp.fileRenameFilters,
                    }),
                }),
            }),
            semanticTokensProvider = lsproto.SemanticTokensOptionsOrRegistrationOptions({
                options = lsproto.SemanticTokensOptions({
                    legend = ls.SemanticTokensLegend(self.clientCapabilities.textDocument.semanticTokens),
                    full = lsproto.BooleanOrSemanticTokensFullDelta({
                        boolean = true,
                    }),
                    range = lsproto.BooleanOrEmptyObject({
                        boolean = true,
                    }),
                }),
            }),
        }),
    })

    return response, nil
end

function Server:handleInitialized(ctx, params)
    local disablePushDiagnostics = false
    local enableTelemetry = false
    if self.initializationOptions.disablePushDiagnostics ~= nil then
        disablePushDiagnostics = self.initializationOptions.disablePushDiagnostics
    end
    if self.initializationOptions.enableTelemetry ~= nil then
        enableTelemetry = self.initializationOptions.enableTelemetry
    end
    local runExternalCode = false
    if self.initializationOptions.runExternalCode ~= nil then
        runExternalCode = self.initializationOptions.runExternalCode
    end
    local hasDynamicWatchRegistration = self.clientCapabilities.workspace.didChangeWatchedFiles.dynamicRegistration
    if hasDynamicWatchRegistration then
        self.logger:Logf("file watching: using LSP client-side watching (client supports dynamic registration)")
        self.watchEnabled = true
    elseif fswatch.Default():HasFastRecursiveBackend() then
        -- The client cannot watch files itself, but the builtin watcher has a
        -- backend with efficient recursive watching (Windows or FSEvents), so
        -- fall back to watching files in-process.
        self.logger:Logf("file watching: using builtin in-process watcher (client lacks dynamic watch registration)")
        self.watchEnabled = true
        self.builtinWatcher = lspwatcher.New(self.fs, function(changes)
            if self.session ~= nil then
                self.session:DidChangeWatchedFiles(self.backgroundCtx, changes)
            end
        end, self.logger)
    else
        -- The client cannot watch files and the builtin watcher backend lacks
        -- efficient recursive watching, so file watching is disabled.
        self.logger:Logf("file watching: disabled (client lacks dynamic watch registration and builtin watcher backend is not fast-recursive)")
    end

    local cwd = self.cwd
    local initParams = self.initializeParams
    if self.clientCapabilities.workspace.workspaceFolders and
        initParams.workspaceFolders ~= nil and
        initParams.workspaceFolders.workspaceFolders ~= nil and
        #initParams.workspaceFolders.workspaceFolders == 1 then
        cwd = lsproto.DocumentUri_FileName(initParams.workspaceFolders.workspaceFolders[1].uri)
    elseif initParams.rootUri.documentUri ~= nil then
        cwd = lsproto.DocumentUri_FileName(initParams.rootUri.documentUri)
    elseif initParams.rootPath ~= nil and initParams.rootPath.string ~= nil then
        cwd = initParams.rootPath.string
    end
    if not tspath.PathIsAbsolute(cwd) then
        cwd = self.cwd
    end

    self.telemetryEnabled = enableTelemetry

    self.session = project.NewSession({
        backgroundCtx = lsproto.WithClientCapabilities(self.backgroundCtx, self.clientCapabilities),
        options = project.NewSessionOptions({
            currentDirectory = cwd,
            defaultLibraryPath = self.defaultLibraryPath,
            typingsLocation = self.typingsLocation,
            positionEncoding = self.positionEncoding,
            watchEnabled = self.watchEnabled,
            loggingEnabled = true,
            telemetryEnabled = enableTelemetry,
            debounceDelay = 0.5,
            pushDiagnosticsEnabled = not disablePushDiagnostics,
            runExternalCode = runExternalCode,
        }),
        fs = self.fs,
        logger = self.logger,
        client = self,
        npmExecutor = self,
        spawner = self:contentMapperSpawner(),
        contentMapperLogger = self:contentMapperLogger(),
        parseCache = self.parseCache,
    })

    local userPreferences, err = self:RequestConfiguration(ctx)
    if err ~= nil then
        return err
    end
    self.session:InitializeWithUserConfig(userPreferences)

    local _
    _, err = lsp.sendClientRequest(ctx, self, lsproto.ClientRegisterCapabilityInfo, lsproto.RegistrationParams({
        registrations = {
            lsproto.Registration({
                id = "typescript-config-watch-id",
                registerOptions = lsproto.RegisterOptions({
                    workspaceDidChangeConfiguration = lsproto.DidChangeConfigurationRegistrationOptions({
                        section = lsproto.StringOrStrings({
                            strings = { "js/ts", "typescript", "javascript", "editor" },
                        }),
                    }),
                }),
            }),
        },
    }))
    if err ~= nil then
        return jsonrpc.NewError("failed to register configuration change watcher: " .. jsonrpc.ErrorString(err), err)
    end

    -- !!! temporary.
    -- Remove when we have `handleDidChangeConfiguration`/implicit project config support
    -- derived from 'js/ts.implicitProjectConfig.*'.
    if self.compilerOptionsForInferredProjects ~= nil then
        self.session:DidChangeCompilerOptionsForInferredProjects(ctx, self.compilerOptionsForInferredProjects)
    end

    self.session:StartPerformanceTelemetry()

    self.initCompleted = true
    return nil
end

function Server:handleShutdown(ctx, _, _)
    if self.builtinWatcher ~= nil then
        self.builtinWatcher:Close()
    end
    self.session:Close()
    return lsproto.Null, nil
end

function Server:handleExit(ctx, _)
    return jsonrpc.EOF
end

function Server:handleDidChangeWorkspaceConfiguration(ctx, params)
    if params.settings == nil then
        return nil
    elseif lsp.isJSONObject(params.settings) then
        self.session:Configure(lsutil.ParseUserPreferences(params.settings))
    end
    return nil
end

function Server:handleDidOpen(ctx, params)
    self.session:DidOpenFile(ctx, params.textDocument.uri, params.textDocument.version, params.textDocument.text, params.textDocument.languageId)
    return nil
end

function Server:handleDidChange(ctx, params)
    self.session:DidChangeFile(ctx, params.textDocument.uri, params.textDocument.version, params.contentChanges)
    return nil
end

function Server:handleDidSave(ctx, params)
    self.session:DidSaveFile(ctx, params.textDocument.uri)
    return nil
end

function Server:handleDidClose(ctx, params)
    self.session:DidCloseFile(ctx, params.textDocument.uri)
    return nil
end

function Server:handleDidChangeWatchedFiles(ctx, params)
    self.session:DidChangeWatchedFiles(ctx, params.changes)
    return nil
end

function Server:handleSetTrace(_, _)
    -- $/setTrace is sent by vscode-languageclient when trace settings change.
    -- Server log verbosity is controlled separately by custom/setLogVerbosity,
    -- so this handler is intentionally a no-op.
    return nil
end

function Server:handleSetLogVerbosity(_, params)
    if not lsp.isValidLogVerbosity(params.verbosity) then
        return lsproto.newCodeError(ErrorCode.InvalidParams, "invalid log verbosity " .. tostring(params.verbosity))
    end
    self.logger:SetVerbosity(params.verbosity)
    return nil
end

function Server:handleDocumentDiagnostic(ctx, languageService, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    if self.flakeLogging == lsproto.DiagnosticFlakeLogLevel.Off then
        return languageService:ProvideDiagnostics(ctx, params.textDocument.uri)
    end
    local direct, err = languageService:ProvideDiagnostics(ctx, params.textDocument.uri)
    if err ~= nil then
        return direct, err
    end
    languageService:GetProgram():Emit(ctx, {
        writeFile = function(fileName, text, data)
            -- do nothing
            return nil
        end,
    })
    local secondary, err2 = languageService:ProvideDiagnostics(ctx, params.textDocument.uri)
    if err2 ~= nil then
        return direct, err
    end
    local missingFromPre, missingFromPost = lsproto.CompareDiagnostics(direct.fullDocumentDiagnosticReport.items, secondary.fullDocumentDiagnosticReport.items)
    if #missingFromPre == 0 and #missingFromPost == 0 then
        return direct, err
    end

    local diff = lsp.generateDiagnosticDiffString(missingFromPre, missingFromPost, lsproto.Diagnostic.AsString)

    self.logger:Error(diff)

    if self.telemetryEnabled then
        local sanitizedDiff = lsp.generateDiagnosticDiffString(missingFromPre, missingFromPost, lsproto.Diagnostic.CodeAsString)
        lsp.sendNotification(self, lsproto.TelemetryEventInfo, lsproto.TelemetryEvent({
            requestFailureTelemetryEvent = lsproto.RequestFailureTelemetryEvent({
                properties = lsproto.RequestFailureTelemetryProperties({
                    errorCode = lsproto.ErrorCode_String(ErrorCode.InternalError),
                    requestMethod = "textDocument.diagnostic.flakeLog",
                    stack = sanitizedDiff,
                }),
            }),
        }))
    end

    if self.flakeLogging == lsproto.DiagnosticFlakeLogLevel.Panic then
        error("flaky diagnostic(s) logged:\n" .. diff, 0)
    end
    return direct, err
end

function lsp.generateDiagnosticDiffString(missingFromPre, missingFromPost, stringifier)
    local b = {}
    for _, elem in ipairs(missingFromPre) do
        b[#b + 1] = "Diagnostic " .. stringifier(elem) .. " was present after emit but not before emit\n"
    end
    for _, elem in ipairs(missingFromPost) do
        b[#b + 1] = "Diagnostic " .. stringifier(elem) .. " was present before emit but not after emit\n"
    end
    return table.concat(b)
end

function Server:handleHover(ctx, languageService, params)
    return languageService:ProvideHover(ctx, params)
end

function Server:handlePrepareRename(ctx, languageService, params)
    local info = languageService:GetRenameInfo(ctx, "" --[[newName]], params.textDocument.uri, params.position)
    if not info.canRename then
        return lsproto.PrepareRenameResponse({}), lsp.newUserFacingRequestFailedError(info.localizedErrorMessage)
    end
    return lsproto.PrepareRenameResponse({
        prepareRenamePlaceholder = lsproto.PrepareRenamePlaceholder({
            range = info.triggerSpan,
            placeholder = info.displayName,
        }),
    }), nil
end

function Server:handleRename(ctx, params, req)
    local defaultLs, orchestrator, err = self:getLanguageServiceAndCrossProjectOrchestrator(ctx, params.textDocument.uri, req)
    if err ~= nil then
        return lsproto.RenameResponse({}), err
    end
    local info = defaultLs:GetRenameInfo(ctx, params.newName, params.textDocument.uri, params.position)
    if info.canRename and info.fileToRename ~= "" then
        -- We send a `willRenameFiles` request if the client allows;
        -- otherwise we directly compute the edits for renaming the file.
        if ls.ClientSupportsWillRenameFiles(ctx) then
            local documentChanges = {
                lsproto.TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile({
                    renameFile = lsproto.RenameFile({
                        kind = lsproto.StringLiteralRename,
                        oldUri = lsconv.FileNameToDocumentURI(info.fileToRename),
                        newUri = lsconv.FileNameToDocumentURI(info.newFileName),
                    }),
                }),
            }
            return lsproto.WorkspaceEditOrNull({
                workspaceEdit = lsproto.WorkspaceEdit({
                    documentChanges = documentChanges,
                }),
            }), nil
        end
        local renameFilesParams = lsproto.RenameFilesParams({
            files = {
                lsproto.FileRename({
                    oldUri = lsconv.FileNameToDocumentURI(info.fileToRename),
                    newUri = lsconv.FileNameToDocumentURI(info.newFileName),
                }),
            },
        })
        return self:handleWillRenameFilesWorker(ctx, renameFilesParams, req, true --[[sendRenameFile]])
    end

    return defaultLs:ProvideRename(ctx, params, orchestrator)
end

function Server:handleWillRenameFiles(ctx, params, msg)
    return self:handleWillRenameFilesWorker(ctx, params, msg, false --[[sendRenameFile]])
end

-- If `sendRenameFile` is true, the original `willRenameFiles` request is being handled as part of a rename operation
-- where the client doesn't support `willRenameFiles`,
-- so we should include the file rename in the edits we return
function Server:handleWillRenameFilesWorker(ctx, params, _, sendRenameFile)
    if params.files == nil or #params.files == 0 then
        return lsproto.WillRenameFilesResponse({}), nil
    end

    local uris = {}
    for _, file in ipairs(params.files) do
        uris[#uris + 1] = file.oldUri
    end

    if #uris == 0 then
        return lsproto.WillRenameFilesResponse({}), nil
    end

    local services = self.session:GetLanguageServicesForDocumentsLoadingProjectTree(ctx, uris)

    -- editKey { uri, range_ } is encoded as a string map key.
    local function editKey(uri, r)
        return uri .. "\0" .. r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
    end
    local seenEdits = {}
    local seenRenames = {}
    local documentChanges = {}

    for _, languageService in ipairs(services or {}) do
        for _, file in ipairs(params.files) do
            local changes = languageService:GetEditsForFileRename(ctx, file.oldUri, file.newUri)
            for _, change in ipairs(changes or {}) do
                if change.renameFile ~= nil then
                    if not seenRenames[change.renameFile.oldUri] then
                        seenRenames[change.renameFile.oldUri] = true
                        documentChanges[#documentChanges + 1] = change
                    end
                elseif change.textDocumentEdit ~= nil then
                    local uri = change.textDocumentEdit.textDocument.uri
                    local deduped = {}
                    for _, edit in ipairs(change.textDocumentEdit.edits or {}) do
                        local skip = false
                        if edit.textEdit ~= nil then
                            local key = editKey(uri, edit.textEdit.range)
                            local prev = seenEdits[key]
                            if prev ~= nil and prev == edit.textEdit.newText then
                                skip = true
                            else
                                seenEdits[key] = edit.textEdit.newText
                            end
                        end
                        if not skip then
                            deduped[#deduped + 1] = edit
                        end
                    end
                    if #deduped > 0 then
                        documentChanges[#documentChanges + 1] = lsproto.TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile({
                            textDocumentEdit = lsproto.TextDocumentEdit({
                                textDocument = change.textDocumentEdit.textDocument,
                                edits = deduped,
                            }),
                        })
                    end
                end
            end
        end
    end

    if sendRenameFile then
        for _, file in ipairs(params.files) do
            documentChanges[#documentChanges + 1] = lsproto.TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile({
                renameFile = lsproto.RenameFile({
                    kind = lsproto.StringLiteralRename,
                    oldUri = file.oldUri,
                    newUri = file.newUri,
                }),
            })
        end
    end

    if #documentChanges == 0 then
        return lsproto.WillRenameFilesResponse({}), nil
    end

    if ls.ClientSupportsDocumentChanges(ctx) then
        return lsproto.WillRenameFilesResponse({
            workspaceEdit = lsproto.WorkspaceEdit({
                documentChanges = documentChanges,
            }),
        }), nil
    end

    local changes = {}
    for _, change in ipairs(documentChanges) do
        if change.textDocumentEdit ~= nil then
            local uri = change.textDocumentEdit.textDocument.uri
            for _, edit in ipairs(change.textDocumentEdit.edits or {}) do
                if edit.textEdit ~= nil then
                    changes[uri] = changes[uri] or {}
                    table.insert(changes[uri], edit.textEdit)
                end
            end
        end
    end

    return lsproto.WillRenameFilesResponse({
        workspaceEdit = lsproto.WorkspaceEdit({
            changes = changes,
        }),
    }), nil
end

function Server:handleSignatureHelp(ctx, languageService, params)
    return languageService:ProvideSignatureHelp(
        ctx,
        params.textDocument.uri,
        params.position,
        params.context
    )
end

function Server:handleFoldingRange(ctx, languageService, params)
    return languageService:ProvideFoldingRange(ctx, params.textDocument.uri)
end

function Server:handleVSOnAutoInsert(ctx, languageService, params)
    return languageService:ProvideOnAutoInsert(ctx, params)
end

function Server:handleLinkedEditingRange(ctx, languageService, params)
    return languageService:ProvideLinkedEditingRange(ctx, params)
end

function Server:handleDefinition(ctx, languageService, params)
    return languageService:ProvideDefinition(ctx, params.textDocument.uri, params.position)
end

function Server:handleSourceDefinition(ctx, languageService, params)
    local resp, err = languageService:ProvideSourceDefinition(ctx, params.textDocument.uri, params.position)
    if err ~= nil then
        return nil, err
    end
    return resp, nil
end

function Server:handleTypeDefinition(ctx, languageService, params)
    return languageService:ProvideTypeDefinition(ctx, params.textDocument.uri, params.position)
end

function Server:handleCompletion(ctx, languageService, params)
    return languageService:ProvideCompletion(
        ctx,
        params.textDocument.uri,
        params.position,
        params.context
    )
end

function Server:handleCompletionItemResolve(ctx, params, reqMsg)
    local data = params.data
    if data == nil then
        return nil, jsonrpc.NewError("completion item data is nil")
    end
    local languageService, err = self.session:GetLanguageService(ctx, lsconv.FileNameToDocumentURI(data.fileName))
    if err ~= nil then
        return nil, err
    end
    return self:withRecover(reqMsg, function()
        return languageService:ResolveCompletionItem(ctx, params, data)
    end)
end

function Server:handleDocumentFormat(ctx, languageService, params)
    return languageService:ProvideFormatDocument(
        ctx,
        params.textDocument.uri,
        params.options
    )
end

function Server:handleDocumentRangeFormat(ctx, languageService, params)
    return languageService:ProvideFormatDocumentRange(
        ctx,
        params.textDocument.uri,
        params.options,
        params.range
    )
end

function Server:handleDocumentOnTypeFormat(ctx, languageService, params)
    return languageService:ProvideFormatDocumentOnType(
        ctx,
        params.textDocument.uri,
        params.options,
        params.position,
        params.ch
    )
end

function Server:handleWorkspaceSymbol(ctx, params, reqMsg)
    local resp = lsproto.WorkspaceSymbolResponse({})
    local lsErr
    local function provideSymbols(snapshot, programs)
        self:withRecover(reqMsg, function()
            resp, lsErr = ls.ProvideWorkspaceSymbols(
                ctx,
                programs,
                snapshot:Converters(),
                snapshot:UserPreferences(),
                params.query
            )
        end)
    end
    if params.textDocument ~= nil and self.session:Config().workspaceSymbolsScope == lsutil.WorkspaceSymbolsScope.CurrentProject then
        local uri = params.textDocument.uri
        self.session:WithSnapshotForDocument(ctx, uri, function(snapshot)
            local programs = core.Map(snapshot:GetProjectsContainingFile(uri), function(p)
                return p:GetProgram()
            end)
            provideSymbols(snapshot, programs)
        end)
    else
        self.session:WithSnapshotLoadingProjectTree(ctx, nil, function(snapshot)
            local programs = core.Map(snapshot.projectCollection:Projects(), function(p)
                return p:GetProgram()
            end)
            provideSymbols(snapshot, programs)
        end)
    end
    return resp, lsErr
end

function Server:handleDocumentSymbol(ctx, languageService, params)
    return languageService:ProvideDocumentSymbols(ctx, params.textDocument.uri)
end

function Server:handleDocumentHighlight(ctx, languageService, params)
    return languageService:ProvideDocumentHighlights(ctx, params.textDocument.uri, params.position)
end

function Server:handleMultiDocumentHighlight(ctx, languageService, params)
    return languageService:ProvideMultiDocumentHighlights(ctx, params.textDocument.uri, params.position, params.filesToSearch)
end

function Server:handleSelectionRange(ctx, languageService, params)
    return languageService:ProvideSelectionRanges(ctx, params)
end

function Server:handleCodeAction(ctx, languageService, params)
    return languageService:ProvideCodeActions(ctx, params)
end

function Server:handleInlayHint(ctx, languageService, params)
    return languageService:ProvideInlayHint(ctx, params)
end

function Server:handleCodeLens(ctx, languageService, params)
    return languageService:ProvideCodeLenses(ctx, params.textDocument.uri)
end

function Server:handleCodeLensResolve(ctx, codeLens, reqMsg)
    local defaultLs, orchestrator, err = self:getLanguageServiceAndCrossProjectOrchestrator(ctx, codeLens.data.uri, reqMsg)
    if core.ContextErr(ctx) ~= nil then
        return nil, core.ContextErr(ctx)
    end
    if err ~= nil then
        -- This can happen if a codeLens/resolve request comes in after a program change.
        -- While it's true that handlers should latch onto a specific snapshot
        -- while processing requests, we just set `Data.Uri` based on
        -- some older snapshot's contents. The content could have been modified,
        -- or the file itself could have been removed from the session entirely.
        -- Note this won't bail out on every change, but will prevent crashing
        -- based on non-existent files and line maps from shortened files.
        return codeLens, ErrorCode.ContentModified
    end
    return self:withRecover(reqMsg, function()
        return defaultLs:ResolveCodeLens(
            ctx,
            codeLens,
            self.initializationOptions.codeLensShowLocationsCommandName,
            orchestrator
        )
    end)
end

function Server:handlePrepareCallHierarchy(ctx, languageService, params)
    return languageService:ProvidePrepareCallHierarchy(ctx, params.textDocument.uri, params.position)
end

function Server:handleCallHierarchyIncomingCalls(ctx, params, reqMsg)
    local defaultLs, orchestrator, err = self:getLanguageServiceAndCrossProjectOrchestrator(ctx, params.item.uri, reqMsg)
    if err ~= nil then
        return lsproto.CallHierarchyIncomingCallsOrNull({}), err
    end
    return defaultLs:ProvideCallHierarchyIncomingCalls(ctx, params.item, orchestrator)
end

function Server:handleCallHierarchyOutgoingCalls(ctx, params, _)
    local languageService, err = self.session:GetLanguageService(ctx, params.item.uri)
    if err ~= nil then
        return lsproto.CallHierarchyOutgoingCallsOrNull({}), err
    end
    return languageService:ProvideCallHierarchyOutgoingCalls(ctx, params.item)
end

function Server:handleSemanticTokensFull(ctx, languageService, params)
    return languageService:ProvideSemanticTokens(ctx, params.textDocument.uri)
end

function Server:handleSemanticTokensRange(ctx, languageService, params)
    return languageService:ProvideSemanticTokensRange(ctx, params.textDocument.uri, params.range)
end

-- The API session accepts its connection on a background goroutine while the server keeps
-- serving requests; the sequential port cannot run both.
function Server:handleInitializeAPISession(ctx, params, _)
    error("not implemented: Server.handleInitializeAPISession (needs a concurrent pipe accept loop)", 0)
end

function Server:generateAPIPipePath()
    error("not implemented: Server.generateAPIPipePath", 0)
end

function Server:removeAPISession(id)
    if self.apiSessions ~= nil then
        self.apiSessions[id] = nil
    end
end

-- !!! temporary; remove when we have `handleDidChangeConfiguration`/implicit project config support
function Server:SetCompilerOptionsForInferredProjects(ctx, options)
    self.compilerOptionsForInferredProjects = options
    if self.session ~= nil then
        self.session:DidChangeCompilerOptionsForInferredProjects(ctx, options)
    end
end

-- NpmInstall implements ata.NpmExecutor. Returns (output, err).
function Server:NpmInstall(cwd, args)
    return self.npmInstall(cwd, args)
end

-- contentMapperSpawner adapts the server's spawn callback to a content mapper spawner, or returns nil when
-- the server cannot spawn processes.
function Server:contentMapperSpawner()
    if self.spawn == nil then
        return nil
    end
    return contentmapper.NewSpawnerFunc(self.spawn)
end

function Server:contentMapperLogger()
    return function(message)
        if self.logger:IsTracing() then
            self.logger:Info(message)
        end
    end
end

-- Developer/debugging command handlers. Profiling (pprof) is out of scope for the Lua port; the
-- profile requests fail like a failing pprof call would.

function Server:handleRunGC(_, _, _)
    collectgarbage("collect")
    self.logger:Info("GC triggered")
    return lsproto.Null, nil
end

function Server:handleSaveHeapProfile(_, params, _)
    return nil, jsonrpc.NewError("not implemented: pprof.SaveHeapProfile")
end

function Server:handleSaveAllocProfile(_, params, _)
    return nil, jsonrpc.NewError("not implemented: pprof.SaveAllocProfile")
end

function Server:handleStartCPUProfile(_, params, _)
    return lsproto.Null, jsonrpc.NewError("not implemented: pprof.CPUProfiler.StartCPUProfile")
end

function Server:handleStopCPUProfile(_, _, _)
    return nil, jsonrpc.NewError("not implemented: pprof.CPUProfiler.StopCPUProfile")
end

function Server:handleProjectInfo(ctx, params, _)
    local uri = params.textDocument.uri
    local defaultProject, _, _, err = self.session:GetLanguageServiceAndProjectsForFile(ctx, uri)
    if err ~= nil then
        return nil, err
    end
    local configFilePath = ""
    if defaultProject ~= nil and defaultProject.kind == project.Kind.Configured then
        configFilePath = defaultProject:Name()
    end
    return lsproto.ProjectInfoResult({
        configFilePath = configFilePath,
    }), nil
end

function Server:handleSetContentMapperContributions(ctx, params, _)
    local contributions, err = lsp.parseContentMapperContributions(params.contributions)
    if err ~= nil then
        return lsproto.Null, err
    end
    local documents = core.Map(params.openDocuments, function(document)
        return document.uri
    end)
    self.session:SetContentMapperContributions(ctx, contributions, documents)
    return lsproto.Null, nil
end

-- Returns (project.ContentMapperContributions { mappers, extensions }, err).
function lsp.parseContentMapperContributions(values)
    local result = { mappers = nil, extensions = nil }
    local claimedExtensions = collections.NewSet()
    for index1, value in ipairs(values or {}) do
        local index = index1 - 1
        if value == nil or value == json.Null or value.contributorId == "" then
            return result, jsonrpc.NewError("content mapper contribution requires a contributorId")
        end
        local identity = value.contributorId .. "[" .. tostring(index) .. "]"
        local validExtensions = {}
        for _, extension in ipairs(value.extensions or {}) do
            if not lsp.isValidContributedContentMapperExtension(extension) then
                return result, jsonrpc.NewError("content mapper contribution " .. jsonrpc.goQuote(identity) .. " has invalid extension " .. jsonrpc.goQuote(extension))
            end
            validExtensions[#validExtensions + 1] = extension
        end
        if value.inferredProjectContribution ~= nil then
            local inferredProject = value.inferredProjectContribution
            local manifest = inferredProject.manifest
            if manifest.name == "" or manifest.exec == nil or #manifest.exec == 0 then
                return result, jsonrpc.NewError("content mapper contribution " .. jsonrpc.goQuote(identity) .. " requires a manifest name and exec")
            end
            for _, option in ipairs(lsp.valueOrZero(manifest.compilerOptions) or {}) do
                if tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, option) == nil then
                    return result, jsonrpc.NewError("content mapper contribution " .. jsonrpc.goQuote(identity) .. " requests unknown compiler option " .. jsonrpc.goQuote(option))
                end
            end
            for _, extension in ipairs(validExtensions) do
                if not claimedExtensions:AddIfAbsent(extension) then
                    return result, jsonrpc.NewError("content mapper contributions both claim extension " .. jsonrpc.goQuote(extension))
                end
                result.extensions = result.extensions or {}
                result.extensions[#result.extensions + 1] = extension
            end
            local options = "{}"
            if inferredProject.options ~= nil then
                local marshaled, merr = lsproto.MarshalAs("map[string]any", inferredProject.options)
                if merr ~= nil then
                    return result, jsonrpc.NewError("content mapper contribution " .. jsonrpc.goQuote(identity) .. " has invalid options")
                end
                options = marshaled
            end
            local mapper = contentmapper.NewMapper({
                package = identity,
                extensions = validExtensions,
                options = options,
                name = manifest.name,
                version = lsp.valueOrZero(manifest.version) or "",
                exec = core.Slice(manifest.exec, 0, #manifest.exec),
                compilerOptions = manifest.compilerOptions ~= nil and core.Slice(manifest.compilerOptions, 0, #manifest.compilerOptions) or nil,
                dynamicConfig = lsp.valueOrZero(manifest.dynamicConfig) or false,
                contributionID = identity,
            })
            if manifest.cwd ~= nil then
                if not tspath.PathIsAbsolute(manifest.cwd) then
                    return result, jsonrpc.NewError("content mapper contribution " .. jsonrpc.goQuote(identity) .. " has non-absolute cwd")
                end
                mapper.packageDirectory = manifest.cwd
            end
            result.mappers = result.mappers or {}
            result.mappers[#result.mappers + 1] = mapper
        end
    end
    if result.extensions ~= nil then
        table.sort(result.extensions)
    end
    return result, nil
end

function lsp.isValidContributedContentMapperExtension(extension)
    if #extension <= 1 or string.sub(extension, 1, 1) ~= "." or tspath.GetAnyExtensionFromPath("file" .. extension, nil, false) ~= extension then
        return false
    end
    for _, ext in ipairs(core.Flatten(tspath.AllSupportedExtensionsWithJson)) do
        if ext == extension then
            return false
        end
    end
    return true
end

-- valueOrZero: Lua stores *T fields as the value or nil; callers apply the zero value.
function lsp.valueOrZero(value)
    return value
end
