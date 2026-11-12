local api = require("tslua.api")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local encoder = require("tslua.api.encoder")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local ls = require("tslua.ls")
local lsproto = require("tslua.lsp.lsproto")
local sourcemap = require("tslua.sourcemap")
local transpile = require("tslua.transpile")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Method = api.Method

-- Errors: Go fmt.Errorf("%w: ...", ErrX, ...) -> jsonrpc.NewError(message, wrapped...).
local function clientError(msg, ...)
    return jsonrpc.NewError(api.ErrClientError:Error() .. ": " .. msg, api.ErrClientError, ...)
end
api.clientError = clientError

-- fmt %v of a DocumentIdentifier value (struct): {fileName uri}.
local function formatDocumentIdentifier(d)
    return "{" .. (d.fileName or "") .. " " .. (d.uri or "") .. "}"
end
api.formatDocumentIdentifier = formatDocumentIdentifier

api.sessionIDCounter = 0

-- snapshotData holds the per-snapshot state including the snapshot itself
-- and symbol/type registries scoped to this snapshot.
-- Multiple clients may hold references to the same snapshot via ref counting;
-- the registries are cleaned up when refCount reaches zero.
--
-- Symbol IDs come from ast.GetSymbolId, a global counter, so the same symbol always has the same
-- unique ID across all projects in the snapshot. Symbols are registered snapshot-wide to ensure
-- identity semantics: querying the same symbol from two different projects returns the same handle.
--
-- symbolCanonicalProjects records, for each registered symbol, the project it was first observed
-- in. Because symbols are shared snapshot-wide (binder symbols are attached to source files, which
-- can be shared across projects), lookups that need a project context (e.g. member/export ordering,
-- node handle resolution) but don't receive one from the caller default to this canonical project.
-- First-writer wins so the choice is stable.
local snapshotData = {}
snapshotData.__index = snapshotData
api.snapshotData = snapshotData

function api.newSnapshotData(snapshot, refCount)
    return setmetatable({
        snapshot = snapshot,
        refCount = refCount or 0,
        symbolRegistry = {},
        symbolCanonicalProjects = {},
        projectRegistries = {},
    }, snapshotData)
end

-- projectRegistryData holds per-project type and signature registries.
-- Types and signatures use per-checker sequential IDs, so the same local ID
-- can appear in multiple projects. Separate maps per project prevent collisions
-- and allow clean teardown when a project is removed.
-- { typeRegistry = map[TypeID]*checker.Type, signatureRegistry = map[SignatureID]*checker.Signature }

-- getProgram looks up a program from a project handle within this snapshot. Returns (program, err).
function snapshotData:getProgram(projectHandle)
    local proj, err = self:getProject(projectHandle)
    if err ~= nil then
        return nil, err
    end

    local program = proj:GetProgram()
    if program == nil then
        return nil, clientError("project has no program")
    end

    return program, nil
end

-- getProject looks up a project from a project handle within this snapshot. Returns (project, err).
function snapshotData:getProject(projectHandle)
    local projectName = api.parseProjectHandle(projectHandle)
    local proj = self.snapshot.projectCollection:GetProjectByPath(projectName)
    if proj == nil then
        return nil, clientError("project " .. projectName .. " not found")
    end
    return proj, nil
end

-- nodeHandleFrom creates an index-based node handle (index.kind.path), building a node index table
-- for the file on-demand if needed.
function snapshotData:nodeHandleFrom(node)
    local sourceFile = ast.GetSourceFileOfNode(node)
    local path = sourceFile:Path()
    local tbl = encoder.GetNodeIndexTable(sourceFile)
    local idx = tbl:GetIndex(node)
    return tostring(idx) .. "." .. tostring(node.kind) .. "." .. path
end

-- getOrCreateProjectRegistry returns the registry for the given project, creating it if needed.
function snapshotData:getOrCreateProjectRegistry(projectID)
    if projectID == "" then
        error("getOrCreateProjectRegistry: empty project ID", 0)
    end
    local reg = self.projectRegistries[projectID]
    if reg ~= nil then
        return reg
    end
    if self.projectRegistries[projectID] == nil then
        self.projectRegistries[projectID] = {
            typeRegistry = {},
            signatureRegistry = {},
        }
    end
    return self.projectRegistries[projectID]
end

-- newSymbolResponse registers a symbol in the snapshot's registry and returns the response.
-- canonicalProject is the project the symbol was observed in and must be non-empty; it is recorded
-- as the symbol's canonical project (first writer wins) and returned to the client so it can default
-- project-scoped follow-up lookups (members/exports, node resolution) to it.
function snapshotData:newSymbolResponse(symbol, canonicalProject)
    if symbol == nil then
        return nil
    end

    local id, proj = self:registerSymbol(symbol, canonicalProject)
    local resp = setmetatable({
        id = id,
        project = proj,
        name = ast.EscapeSymbolName(symbol.name),
        flags = symbol.flags & 0xFFFFFFFF,
        checkFlags = symbol.checkFlags & 0xFFFFFFFF,
    }, api.SymbolResponse)

    if core.Len(symbol.declarations) > 0 then
        resp.declarations = {}
        for i, decl in ipairs(symbol.declarations) do
            resp.declarations[i] = self:nodeHandleFrom(decl)
        end
    end

    if symbol.valueDeclaration ~= nil then
        resp.valueDeclaration = self:nodeHandleFrom(symbol.valueDeclaration)
    end

    if symbol.parent ~= nil then
        resp.parent = api.SymbolHandle(symbol.parent)
    end

    if symbol.exportSymbol ~= nil then
        resp.exportSymbol = api.SymbolHandle(symbol.exportSymbol)
    end

    return resp
end

-- registerSymbol registers a symbol in the snapshot's registry and returns its handle along with
-- its canonical project. The canonical project is the project the symbol was first observed in
-- (first writer wins for stability) and is always non-empty: every symbol handed to a client must
-- carry a project so that project-scoped follow-up lookups (members/exports, parent, node
-- resolution) have a default context. Callers must supply a non-empty project.
-- Returns (SymbolID, ProjectID).
function snapshotData:registerSymbol(symbol, canonicalProject)
    if symbol == nil then
        return 0, ""
    end
    if canonicalProject == "" then
        error("registerSymbol requires a non-empty canonical project", 0)
    end
    local id = api.SymbolHandle(symbol)
    local existing = self.symbolRegistry[id]
    if existing ~= nil then
        if existing ~= symbol then
            error("duplicate symbol", 0)
        end
    else
        self.symbolRegistry[id] = symbol
    end
    local proj = self.symbolCanonicalProjects[id]
    if proj == nil then
        self.symbolCanonicalProjects[id] = canonicalProject
        proj = canonicalProject
    end
    return id, proj
end

-- newTypeResponse registers a type in the project's registry and returns the response.
function snapshotData:newTypeResponse(projectID, t)
    if t == nil then
        return nil
    end
    return api.newTypeResponse(t, self:registerType(projectID, t))
end

function snapshotData:registerType(projectID, t)
    if t == nil then
        return 0
    end
    local id = api.TypeHandle(t)
    local reg = self:getOrCreateProjectRegistry(projectID)
    local existing = reg.typeRegistry[id]

    if existing ~= nil then
        if existing ~= t then
            error("duplicate type", 0)
        end
        return id
    end
    reg.typeRegistry[id] = t
    return id
end

-- resolveSymbolHandle resolves a symbol handle within the snapshot's registry. Returns (symbol, err).
function snapshotData:resolveSymbolHandle(handle)
    if handle == 0 then
        return nil, clientError("empty symbol handle")
    end

    local symbol = self.symbolRegistry[handle]

    if symbol == nil then
        return nil, clientError("symbol handle " .. tostring(handle) .. " not found in snapshot registry")
    end

    return symbol, nil
end

-- resolveTypeHandle resolves a type handle within the project's registry. Returns (type, err).
function snapshotData:resolveTypeHandle(projectID, handle)
    if handle == 0 then
        return nil, clientError("empty type handle")
    end
    if projectID == "" then
        return nil, clientError("empty project ID for type handle " .. tostring(handle))
    end

    local reg = self.projectRegistries[projectID]

    if reg == nil then
        return nil, clientError("type handle " .. tostring(handle) .. " not found (no registry for project " .. projectID .. ")")
    end

    local t = reg.typeRegistry[handle]

    if t == nil then
        return nil, clientError("type handle " .. tostring(handle) .. " not found in project registry")
    end

    return t, nil
end

-- resolveSignatureHandle resolves a signature handle within the project's registry. Returns (sig, err).
function snapshotData:resolveSignatureHandle(projectID, handle)
    if handle == 0 then
        return nil, clientError("empty signature handle")
    end
    if projectID == "" then
        return nil, clientError("empty project ID for signature handle " .. tostring(handle))
    end

    local reg = self.projectRegistries[projectID]

    if reg == nil then
        return nil, clientError("signature handle " .. tostring(handle) .. " not found (no registry for project " .. projectID .. ")")
    end

    local sig = reg.signatureRegistry[handle]

    if sig == nil then
        return nil, clientError("signature handle " .. tostring(handle) .. " not found in project registry")
    end

    return sig, nil
end

-- newSignatureResponse registers a signature in the project's registry and returns the response.
function snapshotData:newSignatureResponse(projectID, sig)
    if sig == nil then
        return nil
    end
    local resp = setmetatable({
        id = self:registerSignature(projectID, sig),
        flags = sig:Flags() & 0xFFFFFFFF,
    }, api.SignatureResponse)

    if sig:Declaration() ~= nil then
        resp.declaration = self:nodeHandleFrom(sig:Declaration())
    end

    if core.Len(sig:TypeParameters()) > 0 then
        resp.typeParameters = api.typeHandles(sig:TypeParameters())
    end

    if core.Len(sig:Parameters()) > 0 then
        resp.parameters = api.symbolHandles(sig:Parameters())
    end

    if sig:ThisParameter() ~= nil then
        resp.thisParameter = api.SymbolHandle(sig:ThisParameter())
    end

    if sig:Target() ~= nil then
        resp.target = api.SignatureHandle(sig:Target())
    end

    return resp
end

function snapshotData:registerSignature(projectID, sig)
    if sig == nil then
        return 0
    end
    local id = api.SignatureHandle(sig)
    local reg = self:getOrCreateProjectRegistry(projectID)
    local existing = reg.signatureRegistry[id]

    if existing ~= nil then
        if existing ~= sig then
            error("duplicate signature", 0)
        end
        return id
    end
    reg.signatureRegistry[id] = sig
    return id
end

-- Session represents an API session that provides programmatic access
-- to TypeScript language services through the LSP server.
-- It implements the Handler interface to process incoming API requests.
-- The session supports multiple active snapshots, each with their own
-- symbol and type registries for maintaining object identity.
--
-- Fields: id, projectSession, useBinaryResponses (set when using MessagePackProtocol),
-- snapshots (map SnapshotID -> snapshotData), latestSnapshot (the most recently created
-- snapshot, used as the diff base for the next update), openProjects / openFiles (the projects
-- and files this session currently holds open in the project session's API state; at most one
-- ref per project/file, so it can release exactly those refs on Close). Go's mutexes are dropped:
-- requests are handled sequentially.
local Session = {}
Session.__index = Session
api.Session = Session

-- SessionOptions configures an API session: { useBinaryResponses = bool } (enables binary
-- responses for msgpack protocol).

-- NewSession creates a new API session with the given project session.
function api.NewSession(projectSession, options)
    api.sessionIDCounter = api.sessionIDCounter + 1
    local id = api.sessionIDCounter
    local s = setmetatable({
        id = api.formatSessionID(id),
        projectSession = projectSession,
        useBinaryResponses = false,
        snapshots = {},
        latestSnapshot = 0,
        openProjects = collections.NewSet(),
        openFiles = collections.NewSet(),
    }, Session)
    if options ~= nil then
        s.useBinaryResponses = options.useBinaryResponses == true
    end
    return s
end

-- ID returns the unique identifier for this session.
function Session:ID()
    return self.id
end

-- ProjectSession returns the underlying project session.
function Session:ProjectSession()
    return self.projectSession
end

-- snapshotHandle creates a snapshot handle from a snapshot's ID.
function api.snapshotHandle(snapshot)
    return snapshot:ID()
end

-- getSnapshotData looks up snapshot data by handle. Returns (snapshotData, err).
function Session:getSnapshotData(handle)
    local sd = self.snapshots[handle]
    if sd == nil then
        return nil, clientError("snapshot " .. tostring(handle) .. " not found")
    end
    return sd, nil
end

-- retainSnapshotData pins snapshot data while an operation builds a derived snapshot.
function Session:retainSnapshotData(handle)
    local sd = self.snapshots[handle]
    if sd == nil then
        return nil, clientError("snapshot " .. tostring(handle) .. " not found")
    end
    sd.refCount = sd.refCount + 1
    return sd, nil
end

function Session:releaseSnapshot(handle)
    local sd = self.snapshots[handle]
    if sd == nil then
        return clientError("snapshot " .. tostring(handle) .. " not found")
    end
    sd.refCount = sd.refCount - 1
    if sd.refCount <= 0 then
        self.snapshots[handle] = nil
        sd.snapshot:Deref(self.projectSession)
    end
    return nil
end

-- checkerSetup holds the common context needed by handlers that require a type checker:
-- { sd, program, checker, done, projectID }.
local checkerSetup = {}
checkerSetup.__index = checkerSetup
api.checkerSetup = checkerSetup

function checkerSetup:newTypeResponse(t)
    return self.sd:newTypeResponse(self.projectID, t)
end

function checkerSetup:newSymbolResponse(sym)
    return self.sd:newSymbolResponse(sym, self.projectID)
end

function checkerSetup:newSignatureResponse(sig)
    return self.sd:newSignatureResponse(self.projectID, sig)
end

function checkerSetup:resolveTypeHandle(id)
    return self.sd:resolveTypeHandle(self.projectID, id)
end

function checkerSetup:resolveSymbolHandle(id)
    return self.sd:resolveSymbolHandle(id)
end

function checkerSetup:resolveSignatureHandle(id)
    return self.sd:resolveSignatureHandle(self.projectID, id)
end

-- resolveLocation resolves an optional location, given either as a node handle or as a
-- file and position. Returns nil when neither is provided. Returns (node, err).
function checkerSetup:resolveLocation(handle, file, position)
    if handle ~= "" then
        return self.sd:resolveNodeHandle(self.program, handle)
    end
    if file ~= nil and position ~= nil then
        local sourceFile = self.program:GetSourceFile(file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(file))
        end
        return astnav.GetTouchingPropertyName(sourceFile, sourceFile:GetPositionMap():UTF16ToUTF8(position)), nil
    end
    return nil, nil
end

-- run calls fn() and then setup.done (Go: defer setup.done()), also when fn raises.
function checkerSetup:run(fn)
    local res = table.pack(pcall(fn))
    if self.done ~= nil then
        self.done()
    end
    if not res[1] then
        error(res[2], 0)
    end
    return table.unpack(res, 2, res.n)
end

-- setupChecker resolves snapshot, program, and type checker for a project.
-- Callers must run their body through setup:run (Go: defer setup.done()). Returns (setup, err).
function Session:setupChecker(ctx, snapshot, projectHandle)
    local sd, err = self:getSnapshotData(snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(projectHandle)
    if err ~= nil then
        return nil, err
    end

    local c, done = program:GetTypeChecker(core.WithCheckerLifetime(ctx, core.CheckerLifetime.API))
    return setmetatable({
        sd = sd,
        program = program,
        checker = c,
        done = done,
        projectID = projectHandle,
    }, checkerSetup), nil
end

-- withChecker is setupChecker followed by setup:run(body(setup)); returns (result, err).
function Session:withChecker(ctx, snapshot, projectHandle, body)
    local setup, err = self:setupChecker(ctx, snapshot, projectHandle)
    if err ~= nil then
        return nil, err
    end
    return setup:run(function()
        return body(setup)
    end)
end

-- setupLanguageService creates a LanguageService for the given snapshot/project.
-- Unlike setupChecker, this does NOT acquire a checker from the pool, so callers that
-- only need an LS (and not a Checker) can avoid blocking on / holding a pooled checker.
--
-- The LS acquires its own checker internally (keyed by the ctx's checker lifetime).
-- If a handler returns symbol/type/signature handles the client may later re-query
-- on the API checker (e.g. completion with IncludeSymbol -> GetTypeOfSymbol), wrap
-- ctx with core.WithCheckerLifetime(ctx, core.CheckerLifetimeAPI) so those handles
-- are produced on the persistent API checker and stay resolvable. Only safe when the
-- LS operation acquires a checker exactly once; nested acquisitions (e.g. find-all-
-- references) would deadlock on the single-slot persistent checker.
function Session:setupLanguageService(sd, program, projectHandle, activeFile)
    local projectName = api.parseProjectHandle(projectHandle)
    local proj = sd.snapshot.projectCollection:GetProjectByPath(projectName)
    if proj == nil then
        return nil, clientError("project " .. projectName .. " not found")
    end
    return ls.NewLanguageService(proj:ID(), program, sd.snapshot, activeFile), nil
end

-- requestHandlers maps method -> { handler(s, ctx, parsed), resultType }. resultType is the Go
-- result type for slice results (nil slices marshal as [], nil elements as null).
local requestHandlers = {}
api.requestHandlers = requestHandlers

local function handle(method, fn, resultType)
    requestHandlers[method] = { fn = fn, resultType = resultType }
end

-- HandleRequest implements Handler. params is a jsonrpc.Value or nil. Returns (result, err).
function Session:HandleRequest(ctx, method, params)
    -- Handle simple methods that don't need param parsing
    if method == "echo" then
        -- Return raw binary for msgpack protocol compatibility
        if self.useBinaryResponses then
            return api.NewRawBinary(params ~= nil and params.data or ""), nil
        end
        return params, nil
    elseif method == "ping" then
        return "pong", nil
    end

    local parsed, err = api.unmarshalPayload(method, params)
    if err ~= nil then
        return nil, jsonrpc.NewError(api.ErrInvalidRequest:Error() .. ": " .. jsonrpc.ErrorString(err), api.ErrInvalidRequest, err)
    end

    local entry = requestHandlers[method]
    if entry == nil then
        return nil, jsonrpc.NewError("unknown method: " .. method)
    end
    local result
    result, err = entry.fn(self, ctx, parsed)
    if err == nil and entry.resultType ~= nil then
        result = api.Typed(entry.resultType, result)
    end
    return result, err
end

handle(Method.Release, function(s, ctx, p) return s:handleRelease(ctx, p) end)
handle(Method.Initialize, function(s, ctx) return s:handleInitialize(ctx) end)
handle(Method.UpdateSnapshot, function(s, ctx, p) return s:handleUpdateSnapshot(ctx, p) end)
handle(Method.UpdateTemporarySnapshot, function(s, ctx, p) return s:handleUpdateTemporarySnapshot(ctx, p) end)
handle(Method.ParseCommandLine, function(s, ctx, p) return s:handleParseCommandLine(ctx, p) end)
handle(Method.ReadConfigFile, function(s, ctx, p) return s:handleReadConfigFile(ctx, p) end)
handle(Method.ParseJsonConfigFile, function(s, ctx, p) return s:handleParseJsonConfigFileContent(ctx, p) end)
handle(Method.ParseConfigFile, function(s, ctx, p) return s:handleParseConfigFile(ctx, p) end)
handle(Method.TranspileModule, function(s, ctx, p) return s:handleTranspile(ctx, p, false) end)
handle(Method.TranspileModuleFromFile, function(s, ctx, p) return s:handleTranspileFromFile(ctx, p, false) end)
handle(Method.TranspileDeclaration, function(s, ctx, p) return s:handleTranspile(ctx, p, true) end)
handle(Method.TranspileDeclarationFromFile, function(s, ctx, p) return s:handleTranspileFromFile(ctx, p, true) end)
handle(Method.GetDefaultProjectForFile, function(s, ctx, p) return s:handleGetDefaultProjectForFile(ctx, p) end)
handle(Method.GetSourceFile, function(s, ctx, p) return s:handleGetSourceFile(ctx, p) end)
handle(Method.GetSourceFileNames, function(s, ctx, p) return s:handleGetSourceFileNames(ctx, p) end, "[]string")
handle(Method.GetSourceFileMetadata, function(s, ctx, p) return s:handleGetSourceFileMetadata(ctx, p) end)
handle(Method.GetConfigFileNames, function(s, ctx, p) return s:handleGetConfigFileNames(ctx, p) end, "[]string")
handle(Method.GetConfigSourceFile, function(s, ctx, p) return s:handleGetConfigSourceFile(ctx, p) end)
handle(Method.GetSymbolAtPosition, function(s, ctx, p) return s:handleGetSymbolAtPosition(ctx, p) end)
handle(Method.GetSymbolsAtPositions, function(s, ctx, p) return s:handleGetSymbolsAtPositions(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetSymbolAtLocation, function(s, ctx, p) return s:handleGetSymbolAtLocation(ctx, p) end)
handle(Method.GetSymbolsAtLocations, function(s, ctx, p) return s:handleGetSymbolsAtLocations(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetSymbolOfSourceFile, function(s, ctx, p) return s:handleGetSymbolOfSourceFile(ctx, p) end)
handle(Method.GetSymbolsOfSourceFiles, function(s, ctx, p) return s:handleGetSymbolsOfSourceFiles(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetTypeOfSymbol, function(s, ctx, p) return s:handleGetTypeOfSymbol(ctx, p) end)
handle(Method.GetTypesOfSymbols, function(s, ctx, p) return s:handleGetTypesOfSymbols(ctx, p) end, "[]*TypeResponse")
handle(Method.GetDeclaredTypeOfSymbol, function(s, ctx, p) return s:handleGetDeclaredTypeOfSymbol(ctx, p) end)
handle(Method.ResolveName, function(s, ctx, p) return s:handleResolveName(ctx, p) end)
handle(Method.GetSymbolsInScope, function(s, ctx, p) return s:handleGetSymbolsInScope(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetSignaturesOfType, function(s, ctx, p) return s:handleGetSignaturesOfType(ctx, p) end, "[]*SignatureResponse")
handle(Method.GetResolvedSignature, function(s, ctx, p) return s:handleGetResolvedSignature(ctx, p) end)
handle(Method.GetTypeAtLocation, function(s, ctx, p) return s:handleGetTypeAtLocation(ctx, p) end)
handle(Method.GetTypeAtLocations, function(s, ctx, p) return s:handleGetTypeAtLocations(ctx, p) end, "[]*TypeResponse")
handle(Method.GetTypeAtPosition, function(s, ctx, p) return s:handleGetTypeAtPosition(ctx, p) end)
handle(Method.GetTypesAtPositions, function(s, ctx, p) return s:handleGetTypesAtPositions(ctx, p) end, "[]*TypeResponse")
handle(Method.GetParentOfSymbol, function(s, ctx, p) return s:handleGetParentOfSymbol(ctx, p) end)
handle(Method.GetMembersOfSymbol, function(s, ctx, p) return s:handleGetMembersOfSymbol(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetExportsOfSymbol, function(s, ctx, p) return s:handleGetExportsOfSymbol(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetExportSymbolOfSymbol, function(s, ctx, p) return s:handleGetExportSymbolOfSymbol(ctx, p) end)
handle(Method.GetSymbolOfType, function(s, ctx, p) return s:handleGetSymbolOfType(ctx, p) end)
handle(Method.GetTargetOfType, function(s, ctx, p) return s:handleGetTargetOfType(ctx, p) end)
handle(Method.GetFreshTypeOfType, function(s, ctx, p) return s:handleGetFreshTypeOfType(ctx, p) end)
handle(Method.GetRegularTypeOfType, function(s, ctx, p) return s:handleGetRegularTypeOfType(ctx, p) end)
handle(Method.GetTypesOfType, function(s, ctx, p) return s:handleGetTypesOfType(ctx, p) end, "[]*TypeResponse")
handle(Method.GetTypeParametersOfType, function(s, ctx, p) return s:handleGetTypeParametersOfType(ctx, p) end, "[]*TypeResponse")
handle(Method.GetOuterTypeParametersOfType, function(s, ctx, p) return s:handleGetOuterTypeParametersOfType(ctx, p) end, "[]*TypeResponse")
handle(Method.GetLocalTypeParametersOfType, function(s, ctx, p) return s:handleGetLocalTypeParametersOfType(ctx, p) end, "[]*TypeResponse")
handle(Method.GetAliasTypeArgumentsOfType, function(s, ctx, p) return s:handleGetAliasTypeArgumentsOfType(ctx, p) end, "[]*TypeResponse")
handle(Method.GetAliasSymbolOfType, function(s, ctx, p) return s:handleGetAliasSymbolOfType(ctx, p) end)
handle(Method.GetObjectTypeOfType, function(s, ctx, p) return s:handleGetObjectTypeOfType(ctx, p) end)
handle(Method.GetIndexTypeOfType, function(s, ctx, p) return s:handleGetIndexTypeOfType(ctx, p) end)
handle(Method.GetCheckTypeOfType, function(s, ctx, p) return s:handleGetCheckTypeOfType(ctx, p) end)
handle(Method.GetExtendsTypeOfType, function(s, ctx, p) return s:handleGetExtendsTypeOfType(ctx, p) end)
handle(Method.GetBaseTypeOfType, function(s, ctx, p) return s:handleGetBaseTypeOfType(ctx, p) end)
handle(Method.GetConstraintOfType, function(s, ctx, p) return s:handleGetConstraintOfType(ctx, p) end)
handle(Method.GetTrueTypeOfConditionalType, function(s, ctx, p) return s:handleGetTrueTypeOfConditionalType(ctx, p) end)
handle(Method.GetFalseTypeOfConditionalType, function(s, ctx, p) return s:handleGetFalseTypeOfConditionalType(ctx, p) end)
handle(Method.GetTypeParametersOfSignature, function(s, ctx, p) return s:handleGetTypeParametersOfSignature(ctx, p) end, "[]*TypeResponse")
handle(Method.GetParametersOfSignature, function(s, ctx, p) return s:handleGetParametersOfSignature(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetThisParameterOfSignature, function(s, ctx, p) return s:handleGetThisParameterOfSignature(ctx, p) end)
handle(Method.GetTargetOfSignature, function(s, ctx, p) return s:handleGetTargetOfSignature(ctx, p) end)
handle(Method.GetContextualType, function(s, ctx, p) return s:handleGetContextualType(ctx, p) end)
handle(Method.GetBaseTypeOfLiteralType, function(s, ctx, p) return s:handleGetBaseTypeOfLiteralType(ctx, p) end)
handle(Method.GetNonNullableType, function(s, ctx, p) return s:handleGetNonNullableType(ctx, p) end)
handle(Method.GetTypeFromTypeNode, function(s, ctx, p) return s:handleGetTypeFromTypeNode(ctx, p) end)
handle(Method.GetWidenedType, function(s, ctx, p) return s:handleGetWidenedType(ctx, p) end)
handle(Method.GetParameterType, function(s, ctx, p) return s:handleGetParameterType(ctx, p) end)
handle(Method.GetTypeParameterAtPosition, function(s, ctx, p) return s:handleGetTypeParameterAtPosition(ctx, p) end)
handle(Method.IsArrayLikeType, function(s, ctx, p) return s:handleIsArrayLikeType(ctx, p) end)
handle(Method.IsTypeAssignableTo, function(s, ctx, p) return s:handleIsTypeAssignableTo(ctx, p) end)
handle(Method.GetShorthandAssignmentValueSymbol, function(s, ctx, p) return s:handleGetShorthandAssignmentValueSymbol(ctx, p) end)
handle(Method.GetTypeOfSymbolAtLocation, function(s, ctx, p) return s:handleGetTypeOfSymbolAtLocation(ctx, p) end)
handle(Method.TypeToTypeNode, function(s, ctx, p) return s:handleTypeToTypeNode(ctx, p) end)
handle(Method.SignatureToSignatureDeclaration, function(s, ctx, p) return s:handleSignatureToSignatureDeclaration(ctx, p) end)
handle(Method.TypeToString, function(s, ctx, p) return s:handleTypeToString(ctx, p) end)
handle(Method.PrintNode, function(s, ctx, p) return s:handlePrintNode(ctx, p) end)
handle(Method.FormatNodeForInsertion, function(s, ctx, p) return s:handleFormatNodeForInsertion(ctx, p) end)
handle(Method.Emit, function(s, ctx, p) return s:handleEmit(ctx, p) end)
handle(Method.EmitToString, function(s, ctx, p) return s:handleEmitToString(ctx, p) end)
handle(Method.GetJavaScriptEmit, function(s, ctx, p) return s:handleSelectedFilesEmit(ctx, p, compiler.EmitOnly.Js) end)
handle(Method.GetDeclarationEmit, function(s, ctx, p) return s:handleSelectedFilesEmit(ctx, p, compiler.EmitOnly.Dts) end)
handle(Method.IsContextSensitive, function(s, ctx, p) return s:handleIsContextSensitive(ctx, p) end)
handle(Method.GetReturnTypeOfSignature, function(s, ctx, p) return s:handleGetReturnTypeOfSignature(ctx, p) end)
handle(Method.GetRestTypeOfSignature, function(s, ctx, p) return s:handleGetRestTypeOfSignature(ctx, p) end)
handle(Method.GetTypePredicateOfSignature, function(s, ctx, p) return s:handleGetTypePredicateOfSignature(ctx, p) end)
handle(Method.GetBaseTypes, function(s, ctx, p) return s:handleGetBaseTypes(ctx, p) end, "[]*TypeResponse")
handle(Method.GetPropertiesOfType, function(s, ctx, p) return s:handleGetPropertiesOfType(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetApparentPropertiesOfType, function(s, ctx, p) return s:handleGetApparentPropertiesOfType(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetApparentType, function(s, ctx, p) return s:handleGetApparentType(ctx, p) end)
handle(Method.GetPropertyOfType, function(s, ctx, p) return s:handleGetPropertyOfType(ctx, p) end)
handle(Method.GetIndexInfosOfType, function(s, ctx, p) return s:handleGetIndexInfosOfType(ctx, p) end, "[]*IndexInfoResponse")
handle(Method.GetConstraintOfTypeParameter, function(s, ctx, p) return s:handleGetConstraintOfTypeParameter(ctx, p) end)
handle(Method.GetBaseConstraintOfType, function(s, ctx, p) return s:handleGetBaseConstraintOfType(ctx, p) end)
handle(Method.GetDefaultFromTypeParameter, function(s, ctx, p) return s:handleGetDefaultFromTypeParameter(ctx, p) end)
handle(Method.GetTypeArguments, function(s, ctx, p) return s:handleGetTypeArguments(ctx, p) end, "[]*TypeResponse")
handle(Method.GetImportAdderEdits, function(s, ctx, p) return s:handleGetImportAdderEdits(ctx, p) end, "[]*TextEdit")
handle(Method.GetConstantValue, function(s, ctx, p) return s:handleGetConstantValue(ctx, p) end)
handle(Method.GetSignatureFromDeclaration, function(s, ctx, p) return s:handleGetSignatureFromDeclaration(ctx, p) end)
handle(Method.GetExportSpecifierLocalTarget, function(s, ctx, p) return s:handleGetExportSpecifierLocalTargetSymbol(ctx, p) end)
handle(Method.GetAliasedSymbol, function(s, ctx, p) return s:handleGetAliasedSymbol(ctx, p) end)
handle(Method.GetImmediateAliasedSymbol, function(s, ctx, p) return s:handleGetImmediateAliasedSymbol(ctx, p) end)
handle(Method.GetFullyQualifiedName, function(s, ctx, p) return s:handleGetFullyQualifiedName(ctx, p) end)
handle(Method.GetExportsOfModule, function(s, ctx, p) return s:handleGetExportsOfModule(ctx, p) end, "[]*SymbolResponse")
handle(Method.GetMemberInModuleExports, function(s, ctx, p) return s:handleGetMemberInModuleExports(ctx, p) end)
handle(Method.GetJSDocTags, function(s, ctx, p) return s:handleGetJSDocTags(ctx, p) end, "[]*JSDocTagInfo")
handle(Method.GetDocumentationComment, function(s, ctx, p) return s:handleGetDocumentationComment(ctx, p) end)
handle(Method.IsArrayType, function(s, ctx, p) return s:handleIsArrayType(ctx, p) end)
handle(Method.IsTupleType, function(s, ctx, p) return s:handleIsTupleType(ctx, p) end)
local intrinsicGetters = {
    { Method.GetAnyType, "GetAnyType" },
    { Method.GetStringType, "GetStringType" },
    { Method.GetNumberType, "GetNumberType" },
    { Method.GetBooleanType, "GetBooleanType" },
    { Method.GetVoidType, "GetVoidType" },
    { Method.GetUndefinedType, "GetUndefinedType" },
    { Method.GetNullType, "GetNullType" },
    { Method.GetNeverType, "GetNeverType" },
    { Method.GetUnknownType, "GetUnknownType" },
    { Method.GetBigIntType, "GetBigIntType" },
    { Method.GetESSymbolType, "GetESSymbolType" },
    { Method.GetNonPrimitiveType, "GetNonPrimitiveType" },
}
for _, g in ipairs(intrinsicGetters) do
    local getterName = g[2]
    handle(g[1], function(s, ctx, p)
        return s:handleGetIntrinsicType(ctx, p, function(c)
            return c[getterName](c)
        end)
    end)
end
handle(Method.GetWellKnownSymbols, function(s, ctx, p) return s:handleGetWellKnownSymbols(ctx, p) end)
handle(Method.GetWellKnownSignatures, function(s, ctx, p) return s:handleGetWellKnownSignatures(ctx, p) end)
handle(Method.GetSyntacticDiagnostics, function(s, ctx, p) return s:handleGetSyntacticDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetBindDiagnostics, function(s, ctx, p) return s:handleGetBindDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetSemanticDiagnostics, function(s, ctx, p) return s:handleGetSemanticDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetSuggestionDiagnostics, function(s, ctx, p) return s:handleGetSuggestionDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetDeclarationDiagnostics, function(s, ctx, p) return s:handleGetDeclarationDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetProgramDiagnostics, function(s, ctx, p) return s:handleGetProgramDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetGlobalDiagnostics, function(s, ctx, p) return s:handleGetGlobalDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.GetConfigFileParsingDiagnostics, function(s, ctx, p) return s:handleGetConfigFileParsingDiagnostics(ctx, p) end, "[]*DiagnosticResponse")
handle(Method.StartCPUProfile, function(s, ctx, p) return s:handleStartCPUProfile(ctx, p) end)
handle(Method.StopCPUProfile, function(s, ctx) return s:handleStopCPUProfile(ctx) end)
handle(Method.SaveHeapProfile, function(s, ctx, p) return s:handleSaveHeapProfile(ctx, p) end)
handle(Method.GetReferencesToSymbolInFile, function(s, ctx, p) return s:handleGetReferencesToSymbolInFile(ctx, p) end, "[]NodeHandle")
handle(Method.GetReferencedSymbolsForNode, function(s, ctx, p) return s:handleGetReferencedSymbolsForNode(ctx, p) end, "[]ReferencedSymbolEntry")
handle(Method.GetSignatureUsages, function(s, ctx, p) return s:handleGetSignatureUsages(ctx, p) end, "[]SignatureUsageResponse")
handle(Method.GetCompletionsAtPosition, function(s, ctx, p) return s:handleGetCompletionsAtPosition(ctx, p) end)

-- CPU and heap profiling (pprof) are out of scope for the Lua port (see docs/PORTING.md); the
-- handlers report a client error instead of writing a profile.
function Session:handleStartCPUProfile(_, params)
    if params == nil or params.dir == "" then
        return nil, clientError("dir is required")
    end
    return nil, clientError("failed to start CPU profile: not implemented: pprof.StartCPUProfile")
end

function Session:handleStopCPUProfile(_)
    return nil, clientError("failed to stop CPU profile: not implemented: pprof.StopCPUProfile")
end

function Session:handleSaveHeapProfile(_, params)
    if params == nil or params.dir == "" then
        return nil, clientError("dir is required")
    end
    return nil, clientError("failed to save heap profile: not implemented: pprof.SaveHeapProfile")
end

-- HandleNotification implements Handler.
function Session:HandleNotification(ctx, method, params)
    -- TODO: Implement notification handling
    return nil
end

function Session:handleInitialize(ctx)
    return setmetatable({
        useCaseSensitiveFileNames = self.projectSession:FS():UseCaseSensitiveFileNames(),
        currentDirectory = self.projectSession:GetCurrentDirectory(),
    }, api.InitializeResponse), nil
end

local function buildProjectResponses(snapshot)
    local projects = snapshot.projectCollection:Projects()
    local projectResponses = {}
    for _, proj in ipairs(projects) do
        if proj.commandLine ~= nil then
            projectResponses[#projectResponses + 1] = api.NewProjectResponse(proj)
        end
    end
    return projectResponses
end

-- handleUpdateSnapshot creates a new snapshot, optionally opening or closing
-- projects and files. With no args, it adopts the latest LSP state. Opens and
-- closes are ref-counted per session: the session holds at most one ref per
-- project/file, so repeated opens are idempotent and a close only releases a ref
-- the session is actually holding.
function Session:handleUpdateSnapshot(ctx, params)
    -- Go fully serializes updates with updateMu; requests are sequential here.
    local fileChanges = self:toFileChangeSummary(params.fileChanges)

    local apiRequest = {} -- project.APISnapshotRequest
    local cwd = self.projectSession:GetCurrentDirectory()

    -- Open projects: only take a new ref for projects we aren't already holding open.
    local openedProjects = {}
    for _, p in ipairs(params.openProjects or {}) do
        local configFileName = p:ToAbsoluteFileName(cwd)
        local configPath = self:toPath(configFileName)
        if not self.openProjects:Has(configPath) then
            if apiRequest.openProjects == nil then
                apiRequest.openProjects = collections.NewSetWithSizeHint(#params.openProjects)
            end
            apiRequest.openProjects:Add(configFileName)
            openedProjects[#openedProjects + 1] = configPath
        end
    end

    -- Close projects: only release a ref we currently hold.
    local closedProjects = {}
    for _, p in ipairs(params.closeProjects or {}) do
        local configPath = self:toPath(p:ToAbsoluteFileName(cwd))
        if self.openProjects:Has(configPath) then
            if apiRequest.closeProjects == nil then
                apiRequest.closeProjects = collections.NewSetWithSizeHint(#params.closeProjects)
            end
            apiRequest.closeProjects:Add(configPath)
            closedProjects[#closedProjects + 1] = configPath
        end
    end

    -- Open files: only open files we aren't already holding open, so each file is
    -- held by at most one API ref from this session.
    local openedFiles = {}
    for _, f in ipairs(params.openFiles or {}) do
        local uri = f:ToURI(cwd)
        local path = self:toPath(lsproto.DocumentUri_FileName(uri))
        if not self.openFiles:Has(path) then
            if apiRequest.openFiles == nil then
                apiRequest.openFiles = collections.NewSetWithSizeHint(#params.openFiles)
            end
            apiRequest.openFiles:Add(uri)
            openedFiles[#openedFiles + 1] = path
        end
    end

    -- Close files: only release a ref we currently hold.
    local closedFiles = {}
    for _, f in ipairs(params.closeFiles or {}) do
        local path = self:toPath(lsproto.DocumentUri_FileName(f:ToURI(cwd)))
        if self.openFiles:Has(path) then
            if apiRequest.closeFiles == nil then
                apiRequest.closeFiles = collections.NewSetWithSizeHint(#params.closeFiles)
            end
            apiRequest.closeFiles:Add(path)
            closedFiles[#closedFiles + 1] = path
        end
    end

    -- Even when nothing is opened or closed, APIUpdate ensures all projects and
    -- files opened by the API are up to date. For an API connected to an LSP server,
    -- this brings the API state up to date with the LSP state and ensures projects
    -- the API cares about are ready to be queried.
    local snapshot, err = self.projectSession:APIUpdate(ctx, fileChanges, apiRequest)
    if err ~= nil then
        -- APIUpdate returns a ref'd snapshot even on error; release it.
        snapshot:Deref(self.projectSession)
        return nil, clientError("failed to update snapshot: " .. jsonrpc.ErrorString(err), err)
    end

    -- Commit ref tracking now that the update succeeded.
    for _, configPath in ipairs(openedProjects) do
        self.openProjects:Add(configPath)
    end
    for _, configPath in ipairs(closedProjects) do
        self.openProjects:Delete(configPath)
    end
    for _, path in ipairs(openedFiles) do
        self.openFiles:Add(path)
    end
    for _, path in ipairs(closedFiles) do
        self.openFiles:Delete(path)
    end

    -- Create or ref-count snapshot data, then read the previous latest snapshot (the diff
    -- base) and advance latestSnapshot to the new handle.
    -- If the same snapshot ID is returned (no changes), we increment the ref count
    -- so each client-side Snapshot can be disposed independently.
    local handleID = api.snapshotHandle(snapshot)
    local sd = self.snapshots[handleID]
    if sd ~= nil then
        -- Same snapshot already stored — release the caller's ref since
        -- the stored snapshot already has one, and bump the API refcount.
        snapshot:Deref(self.projectSession)
        sd.refCount = sd.refCount + 1
    else
        sd = api.newSnapshotData(snapshot, 1)
        self.snapshots[handleID] = sd
    end
    local prevSD = self.snapshots[self.latestSnapshot]
    self.latestSnapshot = handleID

    -- Build projects list
    local projectResponses = buildProjectResponses(snapshot)

    -- Compute changes from the previous latest snapshot
    local changes
    if prevSD ~= nil then
        changes = api.computeSnapshotChanges(prevSD.snapshot, snapshot)
    end

    return setmetatable({
        snapshot = handleID,
        projects = projectResponses,
        changes = changes,
    }, api.UpdateSnapshotResponse), nil
end

-- handleUpdateTemporarySnapshot creates a temporary snapshot that overrides the
-- content of a single file, without opening/closing any projects or files and
-- without advancing the session's latest snapshot.
function Session:handleUpdateTemporarySnapshot(ctx, params)
    local baseSD, err = self:retainSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end
    local ok, result, resultErr = pcall(function()
        local uri = params.file:ToURI(self.projectSession:GetCurrentDirectory())

        local snapshot, uerr = self.projectSession:APIUpdateTemporary(ctx, baseSD.snapshot, uri, params.newText)
        if uerr ~= nil then
            return nil, clientError("failed to update temporary snapshot: " .. jsonrpc.ErrorString(uerr), uerr)
        end

        local handleID = api.snapshotHandle(snapshot)
        local sd = self.snapshots[handleID]
        if sd ~= nil then
            snapshot:Deref(self.projectSession)
            sd.refCount = sd.refCount + 1
        else
            sd = api.newSnapshotData(snapshot, 1)
            self.snapshots[handleID] = sd
        end

        -- Build projects list
        local projectResponses = buildProjectResponses(snapshot)

        -- Compute changes from the requested base snapshot so the client can retain
        -- cached source files for unchanged files.
        local changes = api.computeSnapshotChanges(baseSD.snapshot, snapshot)

        return setmetatable({
            snapshot = handleID,
            projects = projectResponses,
            changes = changes,
        }, api.UpdateSnapshotResponse), nil
    end)
    self:releaseSnapshot(params.snapshot)
    if not ok then
        error(result, 0)
    end
    return result, resultErr
end

-- handleRelease decrements the ref count for a snapshot.
-- The snapshot and its registries are only cleaned up when the ref count reaches zero.
function Session:handleRelease(ctx, params)
    if params == nil or params.snapshot == 0 then
        return nil, clientError("empty handle")
    end

    local err = self:releaseSnapshot(params.snapshot)
    if err ~= nil then
        return nil, err
    end
    return true, nil
end

-- handleGetDefaultProjectForFile returns the default project for a given file,
-- or nil if no project currently contains the file.
function Session:handleGetDefaultProjectForFile(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local uri = params.file:ToURI(self.projectSession:GetCurrentDirectory())
    local proj = sd.snapshot:GetDefaultProject(uri)
    if proj == nil then
        return nil, nil
    end

    return api.NewProjectResponse(proj), nil
end

-- handleParseCommandLine parses command-line arguments.
function Session:handleParseCommandLine(ctx, params)
    return api.NewConfigFileResponse(tsoptions.ParseCommandLine(params.commandLine or {}, self.projectSession)), nil
end

-- handleReadConfigFile reads and parses a JSON configuration file.
function Session:handleReadConfigFile(ctx, params)
    local configFileName = params.file:ToAbsoluteFileName(self.projectSession:GetCurrentDirectory())
    local configFileContent, ok = self.projectSession:FS():ReadFile(configFileName)
    if not ok then
        return setmetatable({
            config = json.NewObject({}),
            error_ = api.NewDiagnosticResponse(ast.NewCompilerDiagnostic(diagnostics.Cannot_read_file_0, configFileName)),
        }, api.ReadConfigFileResponse), nil
    end

    local config, parseErrors = tsoptions.ParseConfigFileTextToJson(
        configFileName,
        self:toPath(configFileName),
        configFileContent
    )
    local response = setmetatable({ config = config }, api.ReadConfigFileResponse)
    if core.Len(parseErrors) > 0 then
        response.error_ = api.NewDiagnosticResponse(parseErrors[1])
    end
    return response, nil
end

-- handleParseJsonConfigFileContent parses an in-memory JSON configuration.
function Session:handleParseJsonConfigFileContent(ctx, params)
    if (params.configDirectory == nil) == (params.configFileName == nil) then
        return nil, clientError("exactly one of configDirectory or configFileName is required")
    end

    local basePath = ""
    local configFileName = ""
    if params.configDirectory ~= nil then
        basePath = tspath.GetNormalizedAbsolutePath(params.configDirectory, self.projectSession:GetCurrentDirectory())
    else
        configFileName = params.configFileName:ToAbsoluteFileName(self.projectSession:GetCurrentDirectory())
        basePath = tspath.GetDirectoryPath(configFileName)
    end

    local parsedCommandLine = tsoptions.ParseJsonConfigFileContent(
        api.jsonValueToAny(params.json or { type = 0 }),
        self.projectSession,
        basePath,
        nil, --[[existingOptions]]
        configFileName,
        nil, --[[resolutionStack]]
        nil --[[extendedConfigCache]]
    )
    return api.NewConfigFileResponse(parsedCommandLine), nil
end

-- handleParseConfigFile parses a tsconfig.json file and returns its contents.
function Session:handleParseConfigFile(ctx, params)
    local configFileName = params.file:ToAbsoluteFileName(self.projectSession:GetCurrentDirectory())
    local configFileContent, ok = self.projectSession:FS():ReadFile(configFileName)
    if not ok then
        return nil, clientError("could not read file " .. json.QuoteString(configFileName))
    end

    local configDir = tspath.GetDirectoryPath(configFileName)
    local tsConfigSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(
        configFileName,
        self:toPath(configFileName),
        configFileContent
    )
    local parsedCommandLine = tsoptions.ParseJsonSourceFileConfigFileContent(
        tsConfigSourceFile,
        self.projectSession,
        configDir,
        nil, --[[existingOptions]]
        nil, --[[existingOptionsRaw]]
        configFileName,
        nil, --[[resolutionStack]]
        nil --[[extendedConfigCache]]
    )
    return api.NewConfigFileResponse(parsedCommandLine), nil
end

function Session:handleTranspile(ctx, params, declaration)
    return api.transpileOutput(ctx, params.input, params.options, declaration)
end

function Session:handleTranspileFromFile(ctx, params, declaration)
    local fileName = tspath.GetNormalizedAbsolutePath(params.fileName, self.projectSession:GetCurrentDirectory())
    local input, ok = self.projectSession:FS():ReadFile(fileName)
    if not ok then
        return nil, clientError("could not read file " .. json.QuoteString(fileName))
    end
    -- Go copies the TranspileOptions value struct.
    local options = {}
    for k, v in pairs(params.options or {}) do
        options[k] = v
    end
    options.fileName = fileName
    return api.transpileOutput(ctx, input, options, declaration)
end

function api.transpileOutput(ctx, input, options, declaration)
    options = options or {}
    local transpileOptions = transpile.NewOptions({
        compilerOptions = options.compilerOptions,
        fileName = options.fileName or "",
        reportDiagnostics = options.reportDiagnostics == true,
    })
    local output
    if declaration then
        output = transpile.TranspileDeclaration(ctx, input, transpileOptions)
    else
        output = transpile.TranspileModule(ctx, input, transpileOptions)
    end
    if output == nil then
        local err = core.ContextErr(ctx)
        if err ~= nil then
            return nil, err
        end
        return nil, jsonrpc.NewError("transpilation produced no output")
    end
    return setmetatable({
        outputText = output.outputText,
        diagnostics = api.NewDiagnosticResponses(output.diagnostics),
        sourceMapText = output.sourceMapText,
    }, api.TranspileOutputResponse), nil
end

-- handleGetSourceFile returns a source file from a project within a snapshot.
function Session:handleGetSourceFile(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    return self:encodeSourceFileResponse(program:GetSourceFile(params.file:ToFileName()))
end

-- handleGetConfigFileNames returns tsconfig file names associated with the project's command line.
function Session:handleGetConfigFileNames(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local commandLine = program:CommandLine()
    if commandLine == nil or commandLine.configFile == nil or commandLine.configFile.sourceFile == nil then
        return nil, nil
    end

    local extendedFiles = commandLine:ExtendedSourceFiles()
    local configFiles = {}
    configFiles[#configFiles + 1] = commandLine.configFile.sourceFile:FileName()
    for _, f in ipairs(extendedFiles or {}) do
        configFiles[#configFiles + 1] = f
    end
    return configFiles, nil
end

-- handleGetConfigSourceFile returns a tsconfig source file associated with the project's command line.
function Session:handleGetConfigSourceFile(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local commandLine = program:CommandLine()
    if commandLine == nil or commandLine.configFile == nil or commandLine.configFile.sourceFile == nil then
        return self:encodeSourceFileResponse(nil)
    end

    local requestedPath = tspath.ToPath(params.file:ToFileName(), program:GetCurrentDirectory(), program:UseCaseSensitiveFileNames())
    local rootConfigSourceFile = commandLine.configFile.sourceFile
    if rootConfigSourceFile:Path() == requestedPath then
        return self:encodeSourceFileResponse(rootConfigSourceFile)
    end

    for _, configFileName in ipairs(commandLine:ExtendedSourceFiles() or {}) do
        if tspath.ToPath(configFileName, program:GetCurrentDirectory(), program:UseCaseSensitiveFileNames()) == requestedPath then
            local configFileContent, ok = sd.snapshot:ReadFile(configFileName)
            if not ok then
                return self:encodeSourceFileResponse(nil)
            end

            local configSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, requestedPath, configFileContent)
            return self:encodeSourceFileResponse(configSourceFile.sourceFile)
        end
    end

    return self:encodeSourceFileResponse(nil)
end

function Session:encodeSourceFileResponse(sourceFile)
    if sourceFile == nil then
        if self.useBinaryResponses then
            return api.NewRawBinary(""), nil
        end
        return nil, nil
    end

    -- Encode the full source file.
    local data, _, err = encoder.EncodeSourceFile(sourceFile)
    if err ~= nil then
        return nil, jsonrpc.NewError("failed to encode source file: " .. jsonrpc.ErrorString(err), err)
    end

    if self.useBinaryResponses then
        return api.NewRawBinary(data), nil
    end
    return setmetatable({
        data = sourcemap.base64StdEncode(data),
    }, api.SourceFileResponse), nil
end

-- handleGetSourceFileNames returns file names of all source files in a project.
function Session:handleGetSourceFileNames(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local sourceFiles = program:GetSourceFiles()
    local result = {}
    for i, sourceFile in ipairs(sourceFiles) do
        result[i] = sourceFile:FileName()
    end
    return result, nil
end

-- handleGetSourceFileMetadata returns program-stored metadata for a single source file.
-- The client fetches this lazily per file and caches it.
function Session:handleGetSourceFileMetadata(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local sourceFile = program:GetSourceFile(params.file:ToFileName())
    if sourceFile == nil then
        return nil, nil
    end

    local metaData = program:GetSourceFileMetaData(sourceFile:Path())
    return setmetatable({
        isDefaultLibrary = program:IsSourceFileDefaultLibrary(sourceFile:Path()),
        isFromExternalLibrary = program:IsSourceFileFromExternalLibrary(sourceFile),
        packageJsonType = metaData.packageJsonType,
        packageJsonDirectory = metaData.packageJsonDirectory,
        impliedNodeFormat = metaData.impliedNodeFormat,
    }, api.SourceFileMetadata), nil
end

-- handleGetSymbolAtPosition returns the symbol at a position in a file.
function Session:handleGetSymbolAtPosition(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local positionMap = sourceFile:GetPositionMap()
        local node = astnav.GetTouchingPropertyName(sourceFile, positionMap:UTF16ToUTF8(params.position))
        if node == nil then
            return nil, nil
        end

        local symbol = setup.checker:GetSymbolAtLocation(node)
        if symbol == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(symbol), nil
    end)
end

-- handleGetSymbolOfSourceFile returns the module symbol for a source file, if any.
-- For non-module (script) files, returns nil.
function Session:handleGetSymbolOfSourceFile(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local symbol = setup.checker:GetSymbolAtLocation(sourceFile)
        if symbol == nil then
            return nil, nil
        end
        return setup:newSymbolResponse(symbol), nil
    end)
end

-- nilSlice returns a Lua array of n json.Null elements (Go make([]*T, n)).
local function nilSlice(n)
    local s = {}
    for i = 1, n do
        s[i] = json.Null
    end
    return s
end
api.nilSlice = nilSlice

-- handleGetSymbolsOfSourceFiles returns the module symbols for multiple source files.
function Session:handleGetSymbolsOfSourceFiles(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local files = params.files or {}
        local results = nilSlice(#files)
        for i, file in ipairs(files) do
            local sourceFile = setup.program:GetSourceFile(file:ToFileName())
            if sourceFile == nil then
                return nil, clientError("source file not found: " .. formatDocumentIdentifier(file))
            end
            local symbol = setup.checker:GetSymbolAtLocation(sourceFile)
            if symbol ~= nil then
                results[i] = setup:newSymbolResponse(symbol)
            end
        end
        return results, nil
    end)
end

-- handleGetSymbolsAtPositions returns symbols at multiple positions in a file.
function Session:handleGetSymbolsAtPositions(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local positionMap = sourceFile:GetPositionMap()
        local positions = params.positions or {}
        local results = nilSlice(#positions)
        for i, pos in ipairs(positions) do
            local node = astnav.GetTouchingPropertyName(sourceFile, positionMap:UTF16ToUTF8(pos))
            if node ~= nil then
                local symbol = setup.checker:GetSymbolAtLocation(node)
                if symbol ~= nil then
                    results[i] = setup:newSymbolResponse(symbol)
                end
            end
        end

        return results, nil
    end)
end

-- handleGetSymbolAtLocation returns the symbol at a node location.
function Session:handleGetSymbolAtLocation(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end
        if node == nil then
            return nil, nil
        end

        local symbol = setup.checker:GetSymbolAtLocation(node)
        if symbol == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(symbol), nil
    end)
end

-- handleGetSymbolsAtLocations returns symbols at multiple node locations.
function Session:handleGetSymbolsAtLocations(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local locations = params.locations or {}
        local results = nilSlice(#locations)
        for i, loc in ipairs(locations) do
            local node, err = setup.sd:resolveNodeHandle(setup.program, loc)
            if err ~= nil then
                return nil, err
            end
            if node ~= nil then
                local symbol = setup.checker:GetSymbolAtLocation(node)
                if symbol ~= nil then
                    results[i] = setup:newSymbolResponse(symbol)
                end
            end
        end

        return results, nil
    end)
end

-- handleGetTypeOfSymbol returns the type of a symbol.
function Session:handleGetTypeOfSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetTypeOfSymbol(symbol)), nil
    end)
end

-- handleGetTypesOfSymbols returns the types of multiple symbols.
function Session:handleGetTypesOfSymbols(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbols = params.symbols or {}
        local results = nilSlice(#symbols)
        for i, symHandle in ipairs(symbols) do
            local symbol, err = setup:resolveSymbolHandle(symHandle)
            if err ~= nil then
                return nil, err
            end
            -- resolveSymbolHandle errors on an unresolvable handle and GetTypeOfSymbol
            -- never returns nil, so every element resolves to a type (error type at worst).
            results[i] = setup:newTypeResponse(setup.checker:GetTypeOfSymbol(symbol))
        end

        return results, nil
    end)
end

-- handleGetDeclaredTypeOfSymbol returns the declared type of a symbol (e.g. the type alias body for type alias symbols).
function Session:handleGetDeclaredTypeOfSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetDeclaredTypeOfSymbol(symbol)), nil
    end)
end

-- handleResolveName resolves a name to a symbol at a given location.
function Session:handleResolveName(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        -- Resolve location node - either from node handle or from fileName+position
        local location, err = setup:resolveLocation(params.location, params.file, params.position)
        if err ~= nil then
            return nil, err
        end

        local symbol = setup.checker:ResolveName(params.name, location, params.meaning, params.excludeGlobals)
        if symbol == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(symbol), nil
    end)
end

-- handleGetSymbolsInScope returns all symbols with the given meaning that are visible at a location.
function Session:handleGetSymbolsInScope(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local location, err = setup:resolveLocation(params.location, params.file, params.position)
        if err ~= nil then
            return nil, err
        end
        if location == nil then
            return nil, clientError("getSymbolsInScope requires a location")
        end

        local symbols = setup.checker:GetSymbolsInScope(location, params.meaning)
        local results = {}
        for i, symbol in ipairs(symbols or {}) do
            results[i] = setup:newSymbolResponse(symbol)
        end

        return results, nil
    end)
end

-- handleGetSignaturesOfType returns the call or construct signatures of a type.
function Session:handleGetSignaturesOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local sigs = setup.checker:GetSignaturesOfType(t, params.kind)
        local results = {}
        for i, sig in ipairs(sigs or {}) do
            results[i] = setup:newSignatureResponse(sig)
        end

        return results, nil
    end)
end

-- handleGetResolvedSignature returns the resolved signature of a call-like expression.
function Session:handleGetResolvedSignature(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end

        return setup:newSignatureResponse(setup.checker:GetResolvedSignature(node)), nil
    end)
end

-- handleGetTypeAtLocation returns the type at a node location.
function Session:handleGetTypeAtLocation(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetTypeAtLocation(node)), nil
    end)
end

-- handleGetTypeAtLocations returns types at multiple node locations.
function Session:handleGetTypeAtLocations(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local locations = params.locations or {}
        local results = nilSlice(#locations)
        for i, loc in ipairs(locations) do
            local node, err = setup.sd:resolveNodeHandle(setup.program, loc)
            if err ~= nil then
                return nil, err
            end
            -- resolveNodeHandle errors on an unresolvable handle and GetTypeAtLocation
            -- never returns nil, so every element resolves to a type (error type at worst).
            results[i] = setup:newTypeResponse(setup.checker:GetTypeAtLocation(node))
        end

        return results, nil
    end)
end

-- handleGetTypeAtPosition returns the type at a position in a file.
function Session:handleGetTypeAtPosition(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local positionMap = sourceFile:GetPositionMap()
        local node = astnav.GetTouchingPropertyName(sourceFile, positionMap:UTF16ToUTF8(params.position))
        if node == nil then
            return nil, nil
        end

        local t = setup.checker:GetTypeAtLocation(node)
        if t == nil then
            return nil, nil
        end

        return setup:newTypeResponse(t), nil
    end)
end

-- handleGetTypesAtPositions returns types at multiple positions in a file.
function Session:handleGetTypesAtPositions(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local positionMap = sourceFile:GetPositionMap()
        local positions = params.positions or {}
        local results = nilSlice(#positions)
        for i, pos in ipairs(positions) do
            local node = astnav.GetTouchingPropertyName(sourceFile, positionMap:UTF16ToUTF8(pos))
            if node ~= nil then
                local t = setup.checker:GetTypeAtLocation(node)
                if t ~= nil then
                    results[i] = setup:newTypeResponse(t)
                end
            end
        end

        return results, nil
    end)
end

