local contentmapper = require("tslua.contentmapper")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local ipc = require("tslua.ipc")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local locale = require("tslua.locale")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")
local xxh3 = require("tslua.xxh3")

-- Lua runs the host sequentially: mapper connections are driven synchronously (see ipc.AsyncConn) and
-- mutexes are dropped. A blocking read cannot be interrupted, so the initialize timeout is not
-- enforced (a mapper that never answers blocks); cancellation is observed between messages.

local codec = contentmapper.codec
local PositionEncoding = contentmapper.PositionEncoding
local DiagnosticDirectivePolicy = contentmapper.DiagnosticDirectivePolicy
local DiagnosticDirectiveErrorKind = contentmapper.DiagnosticDirectiveErrorKind
local InitializeErrorKind = contentmapper.InitializeErrorKind
local ProjectErrorKind = contentmapper.ProjectErrorKind
local TransformErrorKind = contentmapper.TransformErrorKind

-- ProtocolVersion is the content mapper protocol version this host speaks (generated constant).

contentmapper.initializeTimeoutSeconds = 5

contentmapper.initializeTimeout = contentmapper.initializeTimeoutSeconds

local function newError(msg, ...)
    return jsonrpc.NewError(msg, ...)
end

local function errorString(err)
    return jsonrpc.ErrorString(err)
end

local function quote(s)
    return jsonrpc.goQuote(s)
end

-- define creates a protocol struct type whose MarshalJSON is encode(self).
local function define(name, encode)
    local T = {}
    T.__index = T
    T.MarshalJSON = encode
    contentmapper[name] = T
    return T
end

-- InitializeParams is the parameter object for the initialize request:
-- { protocolVersion = int, locale = BCP 47 locale for mapper-authored diagnostic messages (omitempty),
--   positionEncodings = []PositionEncoding the host accepts }.
local InitializeParams = define("InitializeParams", function(self)
    local b = codec.NewObject()
    b:Int("protocolVersion", self.protocolVersion)
    if self.locale ~= "" then
        b:String("locale", self.locale)
    end
    b:Array("positionEncodings", self.positionEncodings, codec.EncodeString)
    return b:Result()
end)

function contentmapper.NewInitializeParams(t)
    return setmetatable({ protocolVersion = t.protocolVersion or 0, locale = t.locale or "", positionEncodings = t.positionEncodings }, InitializeParams)
end

function contentmapper.UnmarshalInitializeParams(raw)
    local f, err = codec.DecodeFields(raw, {
        { "protocolVersion", codec.DecodeInt },
        { "locale", codec.DecodeString },
        { "positionEncodings", codec.DecodeStringSlice },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewInitializeParams(f), nil
end

-- InitializeResult is the mapper's response to the initialize request:
-- { protocolVersion, positionEncoding = coordinate space for all mappings and diagnostics,
--   diagnosticSource = prefix used for every mapper-authored diagnostic code }.
local InitializeResult = define("InitializeResult", function(self)
    local b = codec.NewObject()
    b:Int("protocolVersion", self.protocolVersion)
    b:String("positionEncoding", self.positionEncoding)
    b:String("diagnosticSource", self.diagnosticSource)
    return b:Result()
end)

function contentmapper.NewInitializeResult(t)
    return setmetatable({ protocolVersion = t.protocolVersion or 0, positionEncoding = t.positionEncoding or "", diagnosticSource = t.diagnosticSource or "" }, InitializeResult)
end

function contentmapper.UnmarshalInitializeResult(raw)
    local f, err = codec.DecodeFields(raw, {
        { "protocolVersion", codec.DecodeInt },
        { "positionEncoding", codec.DecodeString },
        { "diagnosticSource", codec.DecodeString },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewInitializeResult(f), nil
end

-- OpenProjectParams is the parameter object for the openProject request:
-- { configFileName = absolute project configuration file name, or "" when there is none,
--   projectHandle = opaque, process-local handle assigned by the host,
--   options = raw JSON of the mapper entry's options from the project's contentMappers configuration ("" when absent),
--   compilerOptions = raw JSON of the project's effective compiler options }.
local OpenProjectParams = define("OpenProjectParams", function(self)
    local b = codec.NewObject()
    b:String("configFileName", self.configFileName)
    b:String("projectHandle", self.projectHandle)
    if self.options ~= "" then
        b:Raw("options", self.options)
    end
    b:Raw("compilerOptions", codec.EncodeRaw(self.compilerOptions))
    return b:Result()
end)

function contentmapper.NewOpenProjectParams(t)
    return setmetatable({ configFileName = t.configFileName or "", projectHandle = t.projectHandle or "", options = t.options or "", compilerOptions = t.compilerOptions or "" }, OpenProjectParams)
end

function contentmapper.UnmarshalOpenProjectParams(raw)
    local f, err = codec.DecodeFields(raw, {
        { "configFileName", codec.DecodeString },
        { "projectHandle", codec.DecodeString },
        { "options", codec.DecodeRaw },
        { "compilerOptions", codec.DecodeRaw },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewOpenProjectParams(f), nil
end

-- OptionDiagnosticResult: { path = []json.Value (raw texts), messageText = string, code = int32 (omitempty) }.
local OptionDiagnosticResult = define("OptionDiagnosticResult", function(self)
    local b = codec.NewObject()
    b:Array("path", self.path, codec.EncodeRaw)
    b:String("messageText", self.messageText)
    if self.code ~= 0 then
        b:Int("code", self.code)
    end
    return b:Result()
end)

function contentmapper.NewOptionDiagnosticResult(t)
    return setmetatable({ path = t.path, messageText = t.messageText or "", code = t.code or 0 }, OptionDiagnosticResult)
end

function contentmapper.UnmarshalOptionDiagnosticResult(raw)
    local f, err = codec.DecodeFields(raw, {
        { "path", codec.DecodeRawSlice },
        { "messageText", codec.DecodeString },
        { "code", codec.DecodeInt32 },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewOptionDiagnosticResult(f), nil
end

-- OpenProjectResult is the mapper's response to an openProject request. ConfigIdentity and WatchedFiles
-- may only be returned by mappers that declare dynamicConfig:
-- { configIdentity = stable fingerprint of all dynamic configuration that can affect transforms,
--   watchedFiles = absolute files whose changes may alter configIdentity or transform output (omitempty),
--   optionDiagnostics = invalid mapper options, paths relative to the mapper entry's options object (omitempty) }.
local OpenProjectResult = define("OpenProjectResult", function(self)
    local b = codec.NewObject()
    b:String("configIdentity", self.configIdentity)
    if core.Len(self.watchedFiles) ~= 0 then
        b:Array("watchedFiles", self.watchedFiles, codec.EncodeString)
    end
    if core.Len(self.optionDiagnostics) ~= 0 then
        b:Array("optionDiagnostics", self.optionDiagnostics, json.Marshal)
    end
    return b:Result()
end)

function contentmapper.NewOpenProjectResult(t)
    return setmetatable({ configIdentity = t.configIdentity or "", watchedFiles = t.watchedFiles, optionDiagnostics = t.optionDiagnostics }, OpenProjectResult)
end

function contentmapper.UnmarshalOpenProjectResult(raw)
    local f, err = codec.DecodeFields(raw, {
        { "configIdentity", codec.DecodeString },
        { "watchedFiles", codec.DecodeStringSlice },
        { "optionDiagnostics", codec.SliceOf(contentmapper.UnmarshalOptionDiagnosticResult) },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewOpenProjectResult(f), nil
end

-- CloseProjectParams is the parameter object for the closeProject request: { projectHandle }.
local CloseProjectParams = define("CloseProjectParams", function(self)
    local b = codec.NewObject()
    b:String("projectHandle", self.projectHandle)
    return b:Result()
end)

function contentmapper.NewCloseProjectParams(t)
    return setmetatable({ projectHandle = t.projectHandle or "" }, CloseProjectParams)
end

function contentmapper.UnmarshalCloseProjectParams(raw)
    local f, err = codec.DecodeFields(raw, { { "projectHandle", codec.DecodeString } })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewCloseProjectParams(f), nil
end

-- PositionEncoding is the coordinate space a mapper uses for mappings and diagnostics (generated
-- constants PositionEncoding.UTF8 / UTF16).

-- TransformParams is the parameter object for the transform request:
-- { fileName = absolute name of the content-mapped source file being transformed,
--   content = the content-mapped source file's text,
--   projectHandle = identifies the mapper project configuration opened for this transform }.
local TransformParams = define("TransformParams", function(self)
    local b = codec.NewObject()
    b:String("fileName", self.fileName)
    b:String("content", self.content)
    b:String("projectHandle", self.projectHandle)
    return b:Result()
end)

function contentmapper.NewTransformParams(t)
    return setmetatable({ fileName = t.fileName or "", content = t.content or "", projectHandle = t.projectHandle or "" }, TransformParams)
end

function contentmapper.UnmarshalTransformParams(raw)
    local f, err = codec.DecodeFields(raw, {
        { "fileName", codec.DecodeString },
        { "content", codec.DecodeString },
        { "projectHandle", codec.DecodeString },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewTransformParams(f), nil
end

-- DiagnosticDirectivePolicy is the numeric policy stored in a mapped diagnostic directive tuple
-- (generated constants DiagnosticDirectivePolicy.Ignore / Expect).

-- UnusedExpectDirectiveDiagnostic: { code = int32, messageText = string }.
local UnusedExpectDirectiveDiagnostic = define("UnusedExpectDirectiveDiagnostic", function(self)
    local b = codec.NewObject()
    b:Int("code", self.code)
    b:String("messageText", self.messageText)
    return b:Result()
end)

function contentmapper.NewUnusedExpectDirectiveDiagnostic(t)
    t = t or {}
    return setmetatable({ code = t.code or 0, messageText = t.messageText or "" }, UnusedExpectDirectiveDiagnostic)
end

function contentmapper.UnmarshalUnusedExpectDirectiveDiagnostic(raw)
    local f, err = codec.DecodeFields(raw, {
        { "code", codec.DecodeInt32 },
        { "messageText", codec.DecodeString },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewUnusedExpectDirectiveDiagnostic(f), nil
end

-- MappedDiagnosticDirective is encoded as
-- [originalStart, originalLength, virtualStart, virtualEnd, policy, unusedExpectDirectiveIndex?].
-- An omitted index selects the only unused-expect diagnostic and is invalid when there is not exactly one.
-- { originalStart, originalLength, virtualStart, virtualEnd, policy, unusedExpectDirectiveIndex = int or nil }
local MappedDiagnosticDirective = define("MappedDiagnosticDirective", function(d)
    local tuple = { d.originalStart, d.originalLength, d.virtualStart, d.virtualEnd, d.policy }
    if d.unusedExpectDirectiveIndex ~= nil then
        tuple[#tuple + 1] = d.unusedExpectDirectiveIndex
    end
    local parts = {}
    for i, v in ipairs(tuple) do
        parts[i] = string.format("%d", v)
    end
    return "[" .. table.concat(parts, ",") .. "]", nil
end)

function contentmapper.NewMappedDiagnosticDirective(t)
    t = t or {}
    return setmetatable({
        originalStart = t.originalStart or 0,
        originalLength = t.originalLength or 0,
        virtualStart = t.virtualStart or 0,
        virtualEnd = t.virtualEnd or 0,
        policy = t.policy or 0,
        unusedExpectDirectiveIndex = t.unusedExpectDirectiveIndex,
    }, MappedDiagnosticDirective)
end

function contentmapper.UnmarshalMappedDiagnosticDirective(raw)
    local tuple, err = codec.DecodeRawSlice(raw)
    if err ~= nil then
        return nil, err
    end
    if core.Len(tuple) ~= 5 and core.Len(tuple) ~= 6 then
        return nil, newError(string.format("diagnostic directive tuple must contain 5 or 6 elements, got %d", core.Len(tuple)))
    end
    local d = contentmapper.NewMappedDiagnosticDirective()
    local fields = { "originalStart", "originalLength", "virtualStart", "virtualEnd", "policy" }
    for i1, field in ipairs(fields) do
        local v, ferr
        if field == "policy" then
            v, ferr = codec.DecodeUint8(tuple[i1])
        else
            v, ferr = codec.DecodeInt(tuple[i1])
        end
        if ferr ~= nil then
            return nil, newError(string.format("invalid diagnostic directive tuple element %d: %s", i1 - 1, errorString(ferr)), ferr)
        end
        d[field] = v
    end
    if #tuple == 6 then
        local index, ierr = codec.DecodeInt(tuple[6])
        if ierr ~= nil then
            return nil, newError("invalid diagnostic directive tuple element 5: " .. errorString(ierr), ierr)
        end
        d.unusedExpectDirectiveIndex = index
    end
    return d, nil
end

-- DiagnosticDirectives shares unused-expect diagnostics across compact directive tuples:
-- { unusedExpectDirectiveDiagnostics = []UnusedExpectDirectiveDiagnostic, directives = []MappedDiagnosticDirective }.
local DiagnosticDirectives = define("DiagnosticDirectives", function(self)
    local b = codec.NewObject()
    b:Array("unusedExpectDirectiveDiagnostics", self.unusedExpectDirectiveDiagnostics, json.Marshal)
    b:Array("directives", self.directives, json.Marshal)
    return b:Result()
end)

function contentmapper.NewDiagnosticDirectives(t)
    return setmetatable({ unusedExpectDirectiveDiagnostics = t.unusedExpectDirectiveDiagnostics, directives = t.directives }, DiagnosticDirectives)
end

function contentmapper.UnmarshalDiagnosticDirectives(raw)
    if codec.IsNull(raw) then
        return nil, nil
    end
    local f, err = codec.DecodeFields(raw, {
        { "unusedExpectDirectiveDiagnostics", codec.SliceOf(contentmapper.UnmarshalUnusedExpectDirectiveDiagnostic) },
        { "directives", codec.SliceOf(contentmapper.UnmarshalMappedDiagnosticDirective) },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewDiagnosticDirectives(f), nil
end

-- MappedOutput is virtual source text and its mapping to an original input:
-- { text = the virtual JavaScript or TypeScript source text,
--   extension = determines the virtual source file's syntax,
--   mappings = the span map's tuple-array JSON (see spanmap.Marshal), expressed in the selected
--              position encoding. Absent or empty ("") means the output is fully synthesized,
--   diagnosticDirectives = *DiagnosticDirectives (omitempty) }.
-- SupplementalOutput embeds MappedOutput (no other fields), so it uses the same representation.
local function encodeMappedOutputFields(b, self)
    b:String("text", self.text)
    b:String("extension", self.extension)
    if self.mappings ~= nil and self.mappings ~= "" then
        b:Raw("mappings", self.mappings)
    end
    if self.diagnosticDirectives ~= nil then
        b:Value("diagnosticDirectives", self.diagnosticDirectives)
    end
end

local MappedOutput = define("MappedOutput", function(self)
    local b = codec.NewObject()
    encodeMappedOutputFields(b, self)
    return b:Result()
end)
contentmapper.SupplementalOutput = MappedOutput

function contentmapper.NewMappedOutput(t)
    t = t or {}
    return setmetatable({ text = t.text or "", extension = t.extension or "", mappings = t.mappings or "", diagnosticDirectives = t.diagnosticDirectives }, MappedOutput)
end

contentmapper.NewSupplementalOutput = contentmapper.NewMappedOutput

local mappedOutputSpec = {
    { "text", codec.DecodeString },
    { "extension", codec.DecodeString },
    { "mappings", codec.DecodeRaw },
    { "diagnosticDirectives", contentmapper.UnmarshalDiagnosticDirectives },
}

function contentmapper.UnmarshalMappedOutput(raw)
    local f, err = codec.DecodeFields(raw, mappedOutputSpec)
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewMappedOutput(f), nil
end

-- Diagnostic is an error reported by a mapper in original-source coordinates:
-- { messageText, start, length (in the selected position encoding), code = int32 (omitempty) }.
local Diagnostic = define("Diagnostic", function(self)
    local b = codec.NewObject()
    b:String("messageText", self.messageText)
    b:Int("start", self.start)
    b:Int("length", self.length)
    if self.code ~= 0 then
        b:Int("code", self.code)
    end
    return b:Result()
end)

function contentmapper.NewDiagnostic(t)
    return setmetatable({ messageText = t.messageText or "", start = t.start or 0, length = t.length or 0, code = t.code or 0 }, Diagnostic)
end

function contentmapper.UnmarshalDiagnostic(raw)
    local f, err = codec.DecodeFields(raw, {
        { "messageText", codec.DecodeString },
        { "start", codec.DecodeInt },
        { "length", codec.DecodeInt },
        { "code", codec.DecodeInt32 },
    })
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewDiagnostic(f), nil
end

-- TransformResult is the canonical output for one input file. MappedOutput is embedded (its fields are
-- flattened); additionally { diagnostics = []Diagnostic mapper-authored errors in original-source
-- coordinates (omitempty), supplemental = []SupplementalOutput additional unnamed compiler inputs (omitempty) }.
local TransformResult = define("TransformResult", function(self)
    local b = codec.NewObject()
    encodeMappedOutputFields(b, self)
    if core.Len(self.diagnostics) ~= 0 then
        b:Array("diagnostics", self.diagnostics, json.Marshal)
    end
    if core.Len(self.supplemental) ~= 0 then
        b:Array("supplemental", self.supplemental, json.Marshal)
    end
    return b:Result()
end)

function contentmapper.NewTransformResult(t)
    local r = contentmapper.NewMappedOutput(t)
    r.diagnostics = t.diagnostics
    r.supplemental = t.supplemental
    return setmetatable(r, TransformResult)
end

function contentmapper.UnmarshalTransformResult(raw)
    local spec = {}
    for i, field in ipairs(mappedOutputSpec) do
        spec[i] = field
    end
    spec[#spec + 1] = { "diagnostics", codec.SliceOf(contentmapper.UnmarshalDiagnostic) }
    spec[#spec + 1] = { "supplemental", codec.SliceOf(contentmapper.UnmarshalMappedOutput) }
    local f, err = codec.DecodeFields(raw, spec)
    if err ~= nil then
        return nil, err
    end
    return contentmapper.NewTransformResult(f), nil
end

-- dialFunc establishes a running connection to a mapper. In production it spawns the mapper's process;
-- tests substitute an in-memory connection. It returns the connection and a closer that tears it down:
--   dial(ctx, mapper, diagnosticLocale) -> (ipc.Conn, closer, PositionEncoding, diagnosticSource, err)

-- host manages one child process per mapper identity. It is the production implementation of Host.
local host = {}
host.__index = host
contentmapper.host = host

-- projectEntry: { mapper, spec, projectHandle, opened, configIdentity, watchedFiles, optionDiagnostics }.

-- mapperConn: { conn, closer, err (cached spawn failure, so we do not repeatedly try and fail to spawn a
-- broken mapper), positionEncoding, diagnosticSource, refs = number of active Acquire calls retaining this identity }.
local function newMapperConn()
    return { conn = nil, closer = nil, err = nil, positionEncoding = "", diagnosticSource = "", refs = 0 }
end

local operationTiming = {}
operationTiming.__index = operationTiming

local function newOperationTiming()
    return setmetatable({ count = 0, duration = 0 }, operationTiming)
end

function operationTiming:record(start)
    self.count = self.count + 1
    self.duration = self.duration + (ipc.now() - start)
end

function operationTiming:snapshot()
    return contentmapper.NewOperationTiming(self.count, self.duration)
end

local timingCollector = {}
timingCollector.__index = timingCollector
contentmapper.timingCollector = timingCollector

function contentmapper.newTimingCollector()
    return setmetatable({ mappers = {}, activeRequests = 0, requestWaitStart = 0, requestWaitElapsed = 0 }, timingCollector)
end

local mapperTimingCollector = {}
mapperTimingCollector.__index = mapperTimingCollector

function timingCollector:mapper(identity)
    local timing = self.mappers[identity]
    if timing ~= nil then
        return timing
    end
    timing = setmetatable({
        spawn = newOperationTiming(),
        initialize = newOperationTiming(),
        openProject = newOperationTiming(),
        closeProject = newOperationTiming(),
        transform = newOperationTiming(),
        owner = self,
    }, mapperTimingCollector)
    self.mappers[identity] = timing
    return timing
end

function timingCollector:snapshot()
    local requestWait = self.requestWaitElapsed
    if self.activeRequests ~= 0 then
        requestWait = requestWait + (ipc.now() - self.requestWaitStart)
    end
    local result = { mappers = {}, requestWait = requestWait }
    for identity, timing in pairs(self.mappers) do
        result.mappers[identity] = {
            spawn = timing.spawn:snapshot(),
            initialize = timing.initialize:snapshot(),
            openProject = timing.openProject:snapshot(),
            closeProject = timing.closeProject:snapshot(),
            transform = timing.transform:snapshot(),
        }
    end
    return result
end

function mapperTimingCollector:startRequest()
    if self.owner.activeRequests == 0 then
        self.owner.requestWaitStart = ipc.now()
    end
    self.owner.activeRequests = self.owner.activeRequests + 1
    return ipc.now()
end

function mapperTimingCollector:finishRequest(operation, start)
    operation:record(start)
    self.owner.activeRequests = self.owner.activeRequests - 1
    if self.owner.activeRequests == 0 then
        self.owner.requestWaitElapsed = self.owner.requestWaitElapsed + (ipc.now() - self.owner.requestWaitStart)
    end
end

-- Spawner starts a child process, returning its stdio as an io.ReadWriteCloser (read is the
-- process's stdout, Write is its stdin) whose Close tears the process down:
--   Spawn(command, dir, stderr) -> (rwc, err)
-- The returned stream follows the tslua.jsonrpc stream contract (read("L") / read(n) / Write / Close)
-- and may implement ExitCode() -> (code, exited) (processExitState). This seam keeps process handling
-- out of this package: production hosts spawn a real process, tests supply an in-process pipe.

local SpawnerFunc = {}
SpawnerFunc.__index = SpawnerFunc
contentmapper.SpawnerFunc = SpawnerFunc

-- NewSpawnerFunc adapts a spawn function to the Spawner interface.
function contentmapper.NewSpawnerFunc(f)
    return setmetatable({ f = f }, SpawnerFunc)
end

function SpawnerFunc:Spawn(command, dir, stderr)
    return self.f(command, dir, stderr)
end

-- Logger receives content mapper protocol and process output as complete log lines: func(message).
-- HostOptions configures optional content mapper process logging: { logger = Logger }.

local loggingProtocol = {}
loggingProtocol.__index = loggingProtocol

local function newLoggingProtocol(protocol, mapperName, logger)
    return setmetatable({ protocol = protocol, mapperName = mapperName, logger = logger }, loggingProtocol)
end

function loggingProtocol:log(direction, message)
    local data, err = json.Marshal(message)
    if err ~= nil then
        self.logger("[content mapper: " .. self.mapperName .. "] " .. direction .. ": <failed to serialize: " .. errorString(err) .. ">")
        return
    end
    self.logger("[content mapper: " .. self.mapperName .. "] " .. direction .. ": " .. data)
end

function loggingProtocol:ReadMessage()
    local message, err = self.protocol:ReadMessage()
    if err == nil then
        self:log("receive", message)
    end
    return message, err
end

function loggingProtocol:WriteRequest(id, method, params)
    local message = setmetatable({ id = id, method = method, params = params }, jsonrpc.RequestMessage)
    self:log("send", message)
    return self.protocol:WriteRequest(id, method, params)
end

function loggingProtocol:WriteNotification(method, params)
    local message = setmetatable({ method = method, params = params }, jsonrpc.RequestMessage)
    self:log("send", message)
    return self.protocol:WriteNotification(method, params)
end

function loggingProtocol:WriteResponse(id, result)
    local message = setmetatable({ id = id, result = result }, jsonrpc.ResponseMessage)
    self:log("send", message)
    return self.protocol:WriteResponse(id, result)
end

function loggingProtocol:WriteError(id, responseError)
    local message = setmetatable({ id = id, error = responseError }, jsonrpc.ResponseMessage)
    self:log("send", message)
    return self.protocol:WriteError(id, responseError)
end

local stderrLogger = {}
stderrLogger.__index = stderrLogger

local function newStderrLogger(mapperName, logger)
    return setmetatable({ mapperName = mapperName, logger = logger, pending = "" }, stderrLogger)
end

function stderrLogger:Write(data)
    self.pending = self.pending .. data
    while true do
        local index = string.find(self.pending, "\n", 1, true)
        if index == nil then
            break
        end
        local line = string.sub(self.pending, 1, index - 1)
        if string.sub(line, -1) == "\r" then
            line = string.sub(line, 1, -2)
        end
        self:log(line)
        self.pending = string.sub(self.pending, index + 1)
    end
    return #data, nil
end

function stderrLogger:flush()
    if self.pending ~= "" then
        local line = self.pending
        if string.sub(line, -1) == "\r" then
            line = string.sub(line, 1, -2)
        end
        self:log(line)
        self.pending = ""
    end
end

function stderrLogger:log(message)
    self.logger("[content mapper: " .. self.mapperName .. "] stderr: " .. message)
end

-- discardWriter is io.Discard.
local discardWriter = {
    Write = function(_, data)
        return #data, nil
    end,
}

-- wrappedStream forwards the stream contract to an inner ReadWriteCloser; loggedProcess and
-- closeOnceReadWriteCloser specialize Close.
local function forwardStream(T)
    function T:read(format)
        return self.inner:read(format)
    end
    function T:Write(data)
        return self.inner:Write(data)
    end
    function T:ExitCode()
        if type(self.inner.ExitCode) == "function" then
            return self.inner:ExitCode()
        end
        return 0, false
    end
end

local loggedProcess = {}
loggedProcess.__index = loggedProcess
forwardStream(loggedProcess)

function loggedProcess:Close()
    local err = self.inner:Close()
    self.stderr:flush()
    return err
end

local closeOnceReadWriteCloser = {}
closeOnceReadWriteCloser.__index = closeOnceReadWriteCloser
forwardStream(closeOnceReadWriteCloser)

function closeOnceReadWriteCloser:Close()
    if not self.closed then
        self.closed = true
        self.err = self.inner:Close()
    end
    return self.err
end

-- NewHost creates a Host that spawns each mapper's process via the given spawner and drives it over a
-- JSON-RPC connection. The host's lifetime is bound to ctx: cancelling it (e.g. the CLI's signal context
-- on SIGINT, or a build/watch session ending) tears every mapper process down, so owners of a session
-- context need not close the host explicitly. Close does the same synchronously.
function contentmapper.NewHost(ctx, spawner, diagnosticLocale)
    return contentmapper.NewHostWithOptions(ctx, spawner, diagnosticLocale, {})
end

-- NewHostWithOptions creates a Host with optional protocol and process logging.
function contentmapper.NewHostWithOptions(ctx, spawner, diagnosticLocale, options)
    local logger = options and options.logger
    local timing = contentmapper.newTimingCollector()
    return contentmapper.newWithDial(ctx, diagnosticLocale, timing, function(dialCtx, mapper, dialLocale)
        if core.Len(mapper.exec) == 0 then
            return nil, nil, "", "", newError("content mapper " .. quote(mapper.package) .. " declares no command to run")
        end
        local mapperTiming = timing:mapper(mapper:Identity())
        local diagnosticName = mapper:DiagnosticName()
        local spawnStart = ipc.now()
        local stderr = discardWriter
        local stderrLog = nil
        if logger ~= nil then
            stderrLog = newStderrLogger(diagnosticName, logger)
            stderr = stderrLog
        end
        local rwc, err = spawner:Spawn(mapper.exec, mapper.packageDirectory, stderr)
        mapperTiming.spawn:record(spawnStart)
        if err ~= nil then
            return nil, nil, "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.ProcessStart, mapperName = diagnosticName, command = mapper.exec[1], detail = errorString(err) })
        end
        if stderrLog ~= nil then
            rwc = setmetatable({ inner = rwc, stderr = stderrLog }, loggedProcess)
        end
        rwc = setmetatable({ inner = rwc, closed = false, err = nil }, closeOnceReadWriteCloser)
        local protocol = ipc.NewJSONRPCProtocol(rwc)
        if logger ~= nil then
            protocol = newLoggingProtocol(protocol, diagnosticName, logger)
        end
        local conn = ipc.NewAsyncConnWithProtocol(rwc, protocol, contentmapper.rejectHandler)
        conn:RunInBackground(dialCtx, function()
            rwc:Close()
        end)
        local initializeStart = mapperTiming:startRequest()
        local positionEncoding, diagnosticSource
        positionEncoding, diagnosticSource, err = contentmapper.handshake(dialCtx, conn, dialLocale)
        mapperTiming:finishRequest(mapperTiming.initialize, initializeStart)
        if err ~= nil then
            local exitCode, exited = rwc:ExitCode()
            rwc:Close()
            local initializeError, ok = contentmapper.ErrorsAsType(err, contentmapper.InitializeError)
            if ok then
                initializeError.mapperName = diagnosticName
                return nil, nil, "", "", initializeError
            end
            if exited then
                return nil, nil, "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.ProcessExit, mapperName = diagnosticName, exitCode = exitCode })
            end
            if jsonrpc.ErrorsIs(err, core.Canceled) or jsonrpc.ErrorsIs(err, ipc.ErrRequestTimeout) then
                return nil, nil, "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.NoResponse, mapperName = diagnosticName, timeoutSeconds = contentmapper.initializeTimeoutSeconds })
            end
            return nil, nil, "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.Request, mapperName = diagnosticName, detail = errorString(err) })
        end
        return conn, rwc, positionEncoding, diagnosticSource, nil
    end)
end

function contentmapper.newWithDial(ctx, diagnosticLocale, timing, dial)
    local hostCtx, cancel = core.WithCancel(ctx)
    local h = setmetatable({
        ctx = hostCtx,
        cancel = cancel,
        dial = dial,
        timing = timing,
        diagnosticLocale = diagnosticLocale or locale.Default,
        conns = {},
        projects = {},
        projectLeases = {},
        nextProjectID = 0,
    }, host)
    h.stop = core.AfterFunc(ctx, function()
        h:Close()
    end)
    return h
end

function host:Timings()
    return self.timing:snapshot()
end

function host:SetLocale(diagnosticLocale)
    if locale.Locale_String(self.diagnosticLocale) == locale.Locale_String(diagnosticLocale) then
        return
    end
    self.diagnosticLocale = diagnosticLocale

    local closers = {}
    for _, identity in ipairs(contentmapper.sortedKeys(self.conns)) do
        local entry = self.conns[identity]
        if entry.closer ~= nil then
            closers[#closers + 1] = entry.closer
        end
        entry.conn = nil
        entry.closer = nil
        entry.err = nil
        entry.positionEncoding = ""
        entry.diagnosticSource = ""
    end
    for _, project in pairs(self.projects) do
        project.opened = false
    end
    for _, closer in ipairs(closers) do
        closer:Close()
    end
end

function host:Project(spec)
    local key = contentmapper.projectSpecKey(spec)
    if self.projects == nil then
        return nil
    end
    local existing = self.projectLeases[key]
    if existing ~= nil then
        return existing:retainLocked()
    end
    local lease = setmetatable({ host = self, key = key, mappers = core.Slice(spec.mappers, 0), entries = {}, refs = 1, closed = false }, contentmapper.projectLease)
    for _, mapper in ipairs(spec.mappers or {}) do
        local entryKey = mapper:Identity() .. ":" .. string.format("%d", self.nextProjectID)
        self.nextProjectID = self.nextProjectID + 1
        local entry = { mapper = mapper, spec = spec, projectHandle = entryKey, opened = false, configIdentity = "", watchedFiles = nil, optionDiagnostics = nil }
        self.projects[entryKey] = entry
        local connEntry = self.conns[mapper:Identity()]
        if connEntry == nil then
            connEntry = newMapperConn()
            self.conns[mapper:Identity()] = connEntry
        end
        connEntry.refs = connEntry.refs + 1
        lease.entries[mapper] = entryKey
    end
    self.projectLeases[key] = lease
    return lease
end

-- pointerIDs assigns stable identities to tables, standing in for Go's %p formatting of pointers.
contentmapper.pointerIDs = setmetatable({}, { __mode = "k" })
contentmapper.nextPointerID = 0

function contentmapper.pointerID(v)
    if v == nil then
        return "0x0"
    end
    local id = contentmapper.pointerIDs[v]
    if id == nil then
        contentmapper.nextPointerID = contentmapper.nextPointerID + 1
        id = string.format("0x%x", contentmapper.nextPointerID)
        contentmapper.pointerIDs[v] = id
    end
    return id
end

function contentmapper.projectSpecKey(spec)
    local key = { spec.configFileName or "", "\0", contentmapper.pointerID(spec.compilerOptions) }
    for _, mapper in ipairs(spec.mappers or {}) do
        key[#key + 1] = "\0" .. contentmapper.pointerID(mapper)
    end
    return table.concat(key)
end

function contentmapper.combinedIdentity(mapper, configIdentity, compilerOptions)
    local transformIdentity = mapper:TransformIdentity(compilerOptions):Bytes()
    local buf = { mapper:Identity(), "\0", mapper.options or "", "\0", configIdentity, "\0", transformIdentity }
    local hash = xxh3.Hash128(table.concat(buf))
    return mapper:Identity() .. ":" .. hash:Hex()
end

function host:openProjectLocked(ctx, entry)
    if entry.opened then
        return nil
    end
    local conn, _, diagnosticSource, err = self:connForLocked(entry.mapper)
    if err ~= nil then
        return err
    end
    local compilerOptions = "null"
    if entry.spec.compilerOptions ~= nil then
        compilerOptions, err = entry.spec.compilerOptions:MarshalJSON()
        if err ~= nil then
            return err
        end
    end
    local mapperTiming = self.timing:mapper(entry.mapper:Identity())
    local start = mapperTiming:startRequest()
    local raw
    raw, err = conn:Call(ctx, contentmapper.MethodOpenProject, contentmapper.NewOpenProjectParams({
        configFileName = entry.spec.configFileName,
        projectHandle = entry.projectHandle,
        options = entry.mapper.options,
        compilerOptions = compilerOptions,
    }))
    mapperTiming:finishRequest(mapperTiming.openProject, start)
    if err ~= nil then
        return err
    end
    local result
    result, err = contentmapper.UnmarshalOpenProjectResult(codec.RawString(raw))
    if err ~= nil then
        return contentmapper.NewProjectError(ProjectErrorKind.MalformedResponse)
    end
    if entry.mapper.dynamicConfig and result.configIdentity == "" then
        return contentmapper.NewProjectError(ProjectErrorKind.MissingConfigIdentity)
    end
    if not entry.mapper.dynamicConfig and result.configIdentity ~= "" then
        return contentmapper.NewProjectError(ProjectErrorKind.UnexpectedConfigIdentity)
    end
    if not entry.mapper.dynamicConfig and core.Len(result.watchedFiles) ~= 0 then
        return contentmapper.NewProjectError(ProjectErrorKind.UnexpectedWatchedFiles)
    end
    entry.configIdentity = result.configIdentity
    for _, fileName in ipairs(result.watchedFiles or {}) do
        if not tspath.PathIsAbsolute(fileName) then
            return contentmapper.NewProjectError(ProjectErrorKind.NonAbsoluteWatchedFile)
        end
    end
    entry.watchedFiles = core.Slice(result.watchedFiles, 0)
    entry.optionDiagnostics = {}
    for i1, diagnostic in ipairs(result.optionDiagnostics or {}) do
        local path = {}
        for j1, rawSegment in ipairs(diagnostic.path or {}) do
            local segment = { property = "", index = 0, isIndex = false }
            local kind = codec.RawKind(rawSegment)
            if kind == '"' then
                local property, perr = codec.DecodeString(rawSegment)
                if perr ~= nil then
                    return contentmapper.NewProjectError(ProjectErrorKind.MalformedResponse)
                end
                segment.property = property
            elseif kind == "0" then
                local index, ierr = codec.DecodeInt(rawSegment)
                if ierr ~= nil or index < 0 then
                    return contentmapper.NewProjectError(ProjectErrorKind.MalformedResponse)
                end
                segment.index = index
                segment.isIndex = true
            else
                return contentmapper.NewProjectError(ProjectErrorKind.MalformedResponse)
            end
            path[j1] = segment
        end
        entry.optionDiagnostics[i1] = {
            mapper = entry.mapper,
            path = path,
            source = diagnosticSource,
            code = diagnostic.code,
            messageText = diagnostic.messageText,
        }
    end
    entry.opened = true
    return nil
end

function host:closeProject(mapper, conn, projectHandle)
    local mapperTiming = self.timing:mapper(mapper:Identity())
    local start = mapperTiming:startRequest()
    local _, err = conn:Call(self.ctx, contentmapper.MethodCloseProject, contentmapper.NewCloseProjectParams({ projectHandle = projectHandle }))
    mapperTiming:finishRequest(mapperTiming.closeProject, start)
    return err
end

-- Acquire retains the processes for the given mapper identities until the returned release function
-- is called (at most once takes effect).
function host:Acquire(mappers)
    local seen = {}
    local identities = {}
    if self.conns ~= nil then
        for _, mapper in ipairs(mappers or {}) do
            local identity = mapper:Identity()
            if not seen[identity] then
                seen[identity] = true
                identities[#identities + 1] = identity
                local entry = self.conns[identity]
                if entry == nil then
                    entry = newMapperConn()
                    self.conns[identity] = entry
                end
                entry.refs = entry.refs + 1
            end
        end
    end
    local released = false
    return function()
        if not released then
            released = true
            self:release(identities)
        end
    end
end

-- Transform sends the file's content to the mapper's process and decodes the transformed result.
function host:Transform(mapper, request)
    local project = self:Project({
        mappers = { mapper },
        compilerOptions = core.NewCompilerOptions(),
    })
    local result, err = project:Transform(mapper, request)
    project:Close()
    return result, err
end

function host:transformLocked(mapper, request, projectHandle)
    if projectHandle == "" then
        return contentmapper.NewResult(), newError("content mapper project handle is required")
    end
    local conn, positionEncoding, diagnosticSource, err = self:connFor(mapper)
    if err ~= nil then
        return contentmapper.NewResult(), contentmapper.NewTransformError(TransformErrorKind.Initialize, err)
    end
    local mapperTiming = self.timing:mapper(mapper:Identity())
    local start = mapperTiming:startRequest()
    local raw
    raw, err = conn:Call(self.ctx, contentmapper.MethodTransform, contentmapper.NewTransformParams({
        fileName = request.fileName,
        content = request.content,
        projectHandle = projectHandle,
    }))
    mapperTiming:finishRequest(mapperTiming.transform, start)
    if err ~= nil then
        return contentmapper.NewResult(), contentmapper.NewTransformError(TransformErrorKind.Request, err)
    end
    local decoded
    decoded, err = contentmapper.decodeTransformResult(codec.RawString(raw), request.content, positionEncoding, diagnosticSource)
    if err ~= nil then
        return contentmapper.NewResult(), contentmapper.NewTransformError(TransformErrorKind.Response, err)
    end
    return decoded, nil
end

-- sortedKeys returns the string keys of t in sorted order (deterministic iteration over Go maps).
function contentmapper.sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- Close shuts down every mapper process. It is safe to call more than once and is invoked automatically
-- when the context passed to New is cancelled.
function host:Close()
    self.stop()
    self.cancel()
    local closers = {}
    for _, identity in ipairs(contentmapper.sortedKeys(self.conns or {})) do
        local mc = self.conns[identity]
        if mc.closer ~= nil then
            closers[#closers + 1] = mc.closer
        end
    end
    self.conns = nil
    self.projects = nil
    self.projectLeases = nil
    local errs = {}
    for _, closer in ipairs(closers) do
        local err = closer:Close()
        if err ~= nil then
            errs[#errs + 1] = err
        end
    end
    return contentmapper.errorsJoin(errs)
end

-- errorsJoin is errors.Join for an array of non-nil errors.
function contentmapper.errorsJoin(errs)
    if #errs == 0 then
        return nil
    end
    local messages = {}
    for i, e in ipairs(errs) do
        messages[i] = errorString(e)
    end
    return newError(table.concat(messages, "\n"), table.unpack(errs))
end

-- connFor returns the connection for a mapper's identity, spawning its process on first use. Mappers
-- sharing an identity share a single process.
function host:connFor(mapper)
    return self:connForLocked(mapper)
end

function host:connForLocked(mapper)
    if self.conns == nil then
        return nil, "", "", newError("content mapper host is closed")
    end
    local identity = mapper:Identity()
    local entry = self.conns[identity]
    if entry == nil then
        entry = newMapperConn()
        self.conns[identity] = entry
    end
    if entry.conn ~= nil or entry.err ~= nil then
        return entry.conn, entry.positionEncoding, entry.diagnosticSource, entry.err
    end
    local conn, closer, positionEncoding, diagnosticSource, err = self.dial(self.ctx, mapper, self.diagnosticLocale)
    entry.conn = conn
    entry.closer = closer
    entry.err = err
    entry.positionEncoding = positionEncoding
    entry.diagnosticSource = diagnosticSource
    return conn, positionEncoding, diagnosticSource, err
end

-- projectLease: { host, key, mappers, entries = map[*Mapper]projectHandle, refs, closed }.
local projectLease = {}
projectLease.__index = projectLease
contentmapper.projectLease = projectLease

-- retainedProject is an additional reference to a projectLease with its own Close-once.
local retainedProject = {}
retainedProject.__index = function(t, k)
    local v = retainedProject[k]
    if v ~= nil then
        return v
    end
    local method = projectLease[k]
    if type(method) == "function" then
        return function(self, ...)
            return method(self.projectLease, ...)
        end
    end
    return rawget(t, "projectLease")[k]
end
contentmapper.retainedProject = retainedProject

function projectLease:retainLocked()
    self.refs = self.refs + 1
    return setmetatable({ projectLease = self, closed = false }, retainedProject)
end

function retainedProject:Close()
    if self.closed then
        return nil
    end
    self.closed = true
    return self.projectLease:release()
end

-- orderedEntries iterates the lease's entries in mapper order (Go iterates the map in random order).
function projectLease:orderedEntryKeys()
    local keys = {}
    for _, mapper in ipairs(self.mappers) do
        local key = self.entries[mapper]
        if key ~= nil then
            keys[#keys + 1] = key
        end
    end
    return keys
end

function projectLease:Refresh()
    if self.host.projects == nil then
        return nil
    end
    local errs = {}
    for _, key in ipairs(self:orderedEntryKeys()) do
        local entry = self.host.projects[key]
        if entry ~= nil and entry.opened then
            local connEntry = self.host.conns[entry.mapper:Identity()]
            if connEntry ~= nil and connEntry.conn ~= nil then
                local err = self.host:closeProject(entry.mapper, connEntry.conn, entry.projectHandle)
                if err ~= nil then
                    errs[#errs + 1] = err
                end
            end
            entry.opened = false
        end
    end
    return contentmapper.errorsJoin(errs)
end

function projectLease:Identities()
    if self.host.projects == nil then
        return nil, nil
    end
    local identities = {}
    for _, mapper in ipairs(self.mappers) do
        local key = self.entries[mapper]
        local entry = key ~= nil and self.host.projects[key] or nil
        if entry ~= nil then
            if mapper.dynamicConfig then
                local err = self.host:openProjectLocked(self.host.ctx, entry)
                if err ~= nil then
                    return nil, err
                end
                identities[#identities + 1] = contentmapper.combinedIdentity(mapper, entry.configIdentity, entry.spec.compilerOptions)
            else
                local hash = mapper:TransformIdentity(entry.spec.compilerOptions)
                identities[#identities + 1] = mapper:Identity() .. ":" .. hash:Hex()
            end
        end
    end
    return identities, nil
end

function projectLease:Identity(mapper)
    if self.host.projects == nil then
        return "", nil
    end
    local key = self.entries[mapper]
    if key == nil then
        return "", nil
    end
    local entry = self.host.projects[key]
    if entry == nil then
        return "", nil
    end
    if mapper.dynamicConfig then
        local err = self.host:openProjectLocked(self.host.ctx, entry)
        if err ~= nil then
            return "", err
        end
        return contentmapper.combinedIdentity(mapper, entry.configIdentity, entry.spec.compilerOptions), nil
    end
    local hash = mapper:TransformIdentity(entry.spec.compilerOptions)
    return mapper:Identity() .. ":" .. hash:Hex(), nil
end

function projectLease:WatchedFiles()
    if self.host.projects == nil then
        return nil, nil
    end
    local files = nil
    for _, key in ipairs(self:orderedEntryKeys()) do
        local entry = self.host.projects[key]
        if entry ~= nil then
            if entry.mapper.dynamicConfig then
                local err = self.host:openProjectLocked(self.host.ctx, entry)
                if err ~= nil then
                    return nil, err
                end
            end
            files = core.AppendAll(files, entry.watchedFiles)
        end
    end
    if files == nil then
        return nil, nil
    end
    table.sort(files)
    -- slices.Compact
    local compacted = {}
    for _, f in ipairs(files) do
        if compacted[#compacted] ~= f then
            compacted[#compacted + 1] = f
        end
    end
    return compacted, nil
end

function projectLease:Diagnostics()
    if self.host.projects == nil then
        return nil
    end
    local result = nil
    for _, mapper in ipairs(self.mappers) do
        local key = self.entries[mapper]
        local entry = key ~= nil and self.host.projects[key] or nil
        if entry ~= nil and entry.opened then
            result = core.AppendAll(result, entry.optionDiagnostics)
        end
    end
    return result
end

function projectLease:Transform(mapper, request)
    local key = self.entries[mapper]
    local entry = nil
    if self.host.projects ~= nil and key ~= nil then
        entry = self.host.projects[key]
    end
    if entry == nil then
        return contentmapper.NewResult(), newError("content mapper project is closed")
    end
    local err = self.host:openProjectLocked(self.host.ctx, entry)
    if err ~= nil then
        local _, ok = contentmapper.ErrorsAsType(err, contentmapper.InitializeError)
        if ok then
            return contentmapper.NewResult(), contentmapper.NewTransformError(TransformErrorKind.Initialize, err)
        end
        return contentmapper.NewResult(), contentmapper.NewTransformError(TransformErrorKind.Project, err)
    end
    local handle = entry.projectHandle
    return self.host:transformLocked(mapper, request, handle)
end

function projectLease:Close()
    if self.closed then
        return nil
    end
    self.closed = true
    return self:release()
end

function projectLease:release()
    local errs = {}
    local releasedIdentities = {}
    self.refs = self.refs - 1
    if self.refs < 0 then
        error("content mapper project reference count below zero", 0)
    end
    if self.refs ~= 0 then
        return nil
    end
    if self.host.projectLeases ~= nil and self.host.projectLeases[self.key] == self then
        self.host.projectLeases[self.key] = nil
    end
    for _, key in ipairs(self:orderedEntryKeys()) do
        local entry = self.host.projects ~= nil and self.host.projects[key] or nil
        if entry ~= nil then
            if entry.opened then
                local connEntry = self.host.conns[entry.mapper:Identity()]
                if connEntry ~= nil and connEntry.conn ~= nil then
                    local err = self.host:closeProject(entry.mapper, connEntry.conn, entry.projectHandle)
                    if err ~= nil then
                        errs[#errs + 1] = err
                    end
                end
            end
            self.host.projects[key] = nil
            releasedIdentities[#releasedIdentities + 1] = entry.mapper:Identity()
        end
    end
    self.host:release(releasedIdentities)
    return contentmapper.errorsJoin(errs)
end

function host:release(identities)
    local closers = {}
    if self.conns ~= nil then
        for _, identity in ipairs(identities) do
            local entry = self.conns[identity]
            if entry ~= nil then
                entry.refs = entry.refs - 1
                if entry.refs == 0 then
                    self.conns[identity] = nil
                    if entry.closer ~= nil then
                        closers[#closers + 1] = entry.closer
                    end
                end
            end
        end
    end
    for _, closer in ipairs(closers) do
        closer:Close()
    end
end

-- handshake returns (PositionEncoding, diagnosticSource, err).
function contentmapper.handshake(ctx, conn, diagnosticLocale)
    local raw, err = conn:Call(ctx, contentmapper.MethodInitialize, contentmapper.NewInitializeParams({
        protocolVersion = contentmapper.ProtocolVersion,
        locale = locale.Locale_String(diagnosticLocale),
        positionEncodings = { PositionEncoding.UTF8, PositionEncoding.UTF16 },
    }))
    if err ~= nil then
        return "", "", err
    end
    local res
    res, err = contentmapper.UnmarshalInitializeResult(codec.RawString(raw))
    if err ~= nil then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.InvalidResponse, detail = errorString(err) })
    end
    if res.protocolVersion ~= contentmapper.ProtocolVersion then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.ProtocolVersion, protocolVersion = res.protocolVersion })
    end
    if res.positionEncoding ~= PositionEncoding.UTF8 and res.positionEncoding ~= PositionEncoding.UTF16 then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.PositionEncoding, positionEncoding = res.positionEncoding })
    end
    if string.match(res.diagnosticSource, "^%s*$") then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.EmptyDiagnosticSource })
    end
    local lowered = string.lower(res.diagnosticSource)
    if lowered == "typescript" or lowered == "tsc" then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.ReservedDiagnosticSource, diagnosticSource = res.diagnosticSource })
    end
    local nativeExtensions = core.Flatten(tspath.AllSupportedExtensionsWithJson)
    if core.Some(nativeExtensions, function(extension)
        local trimmed = extension
        if string.sub(trimmed, 1, 1) == "." then
            trimmed = string.sub(trimmed, 2)
        end
        return lowered == string.lower(trimmed)
    end) then
        return "", "", contentmapper.NewInitializeError({ kind = InitializeErrorKind.ReservedDiagnosticSource, diagnosticSource = res.diagnosticSource })
    end
    return res.positionEncoding, res.diagnosticSource, nil
end

-- decodeTransformResult returns (Result, err).
function contentmapper.decodeTransformResult(raw, originalText, positionEncoding, diagnosticSource)
    local res, err = contentmapper.UnmarshalTransformResult(raw)
    if err ~= nil then
        return contentmapper.NewResult(), err
    end
    local mapped, originalPositions
    mapped, originalPositions, err = contentmapper.decodeMappedOutput(res, originalText, positionEncoding, diagnosticSource)
    if err ~= nil then
        return contentmapper.NewResult(), err
    end
    local result = contentmapper.NewResult({
        text = mapped.text,
        virtualExtension = mapped.virtualExtension,
        mappings = mapped.mappings,
        diagnosticDirectives = mapped.diagnosticDirectives,
    })
    for supplementalIndex1, supplemental in ipairs(res.supplemental or {}) do
        local supplementalMapped, _, serr = contentmapper.decodeMappedOutput(supplemental, originalText, positionEncoding, diagnosticSource)
        if serr ~= nil then
            local directiveError, ok = contentmapper.ErrorsAsType(serr, contentmapper.DiagnosticDirectiveError)
            if ok then
                directiveError.supplementalIndex = supplementalIndex1 - 1
            end
            return contentmapper.NewResult(), serr
        end
        result.supplemental = core.Append(result.supplemental, supplementalMapped)
    end
    for _, d in ipairs(res.diagnostics or {}) do
        if d.start < 0 or d.length < 0 or d.start > math.maxinteger - d.length then
            return contentmapper.NewResult(), newError(string.format("invalid content mapper diagnostic range [%d, %d)", d.start, d.start + d.length))
        end
        local start, serr = originalPositions:normalize(d.start)
        if serr ~= nil then
            return contentmapper.NewResult(), newError("invalid content mapper diagnostic start: " .. errorString(serr), serr)
        end
        local end_, eerr = originalPositions:normalize(d.start + d.length)
        if eerr ~= nil then
            return contentmapper.NewResult(), newError("invalid content mapper diagnostic end: " .. errorString(eerr), eerr)
        end
        result.diagnostics = core.Append(result.diagnostics, ast.NewExternalDiagnostic(
            nil,
            core.NewTextRange(start, end_),
            diagnosticSource,
            diagnostics.Category.Error,
            d.code,
            d.messageText
        ))
    end
    return result, nil
end

-- decodeMappedOutput returns (MappedResult, *positionNormalizer, err).
function contentmapper.decodeMappedOutput(output, originalText, positionEncoding, diagnosticSource)
    if not contentmapper.IsSupportedVirtualExtension(output.extension) then
        return contentmapper.NewMappedResult(), nil, contentmapper.NewInvalidVirtualExtensionError(output.extension)
    end
    local result = contentmapper.NewMappedResult({
        text = output.text,
        virtualExtension = output.extension,
    })
    local virtualPositions, err = contentmapper.newPositionNormalizer(output.text, positionEncoding)
    if err ~= nil then
        return contentmapper.NewMappedResult(), nil, err
    end
    local originalPositions
    originalPositions, err = contentmapper.newPositionNormalizer(originalText, positionEncoding)
    if err ~= nil then
        return contentmapper.NewMappedResult(), nil, err
    end
    -- A successful transform always carries a span map. Absent or empty mappings describe fully
    -- synthesized output (no segment corresponds to the original), so decode to an empty map rather than
    -- nil, which would mean "not content-mapped".
    if output.mappings ~= nil and #output.mappings > 0 then
        local mappings, unmarshalErr = spanmap.Unmarshal(output.mappings)
        if unmarshalErr ~= nil then
            if type(unmarshalErr) == "string" then
                unmarshalErr = newError(unmarshalErr)
            end
            return contentmapper.NewMappedResult(), nil, unmarshalErr
        end
        result.mappings, err = contentmapper.normalizeMappings(mappings, virtualPositions, originalPositions)
        if err ~= nil then
            return contentmapper.NewMappedResult(), nil, err
        end
    else
        result.mappings = spanmap.New(nil)
    end
    result.diagnosticDirectives, err = contentmapper.normalizeDiagnosticDirectives(output.diagnosticDirectives, virtualPositions, originalPositions, diagnosticSource)
    if err ~= nil then
        return contentmapper.NewMappedResult(), nil, err
    end
    return result, originalPositions, nil
end

-- ast.MappedDiagnosticDirective: { originalRange, virtualRange, policy, unusedCode, unusedMessageText, source }.
local function newASTMappedDiagnosticDirective(source)
    return {
        originalRange = core.NewTextRange(0, 0),
        virtualRange = core.NewTextRange(0, 0),
        policy = ast.MappedDiagnosticDirectivePolicy.Ignore,
        unusedCode = 0,
        unusedMessageText = "",
        source = source,
    }
end

function contentmapper.normalizeDiagnosticDirectives(diagnosticDirectives, virtualPositions, originalPositions, diagnosticSource)
    if diagnosticDirectives == nil then
        return nil, nil
    end
    local directives = diagnosticDirectives.directives or {}
    local unused = diagnosticDirectives.unusedExpectDirectiveDiagnostics or {}
    local result = {}
    for i1, directive in ipairs(directives) do
        local i = i1 - 1
        local function directiveError(kind)
            return contentmapper.NewDiagnosticDirectiveError({
                kind = kind,
                index = i,
                supplementalIndex = -1,
            })
        end
        local normalized = newASTMappedDiagnosticDirective(diagnosticSource)
        if directive.policy == DiagnosticDirectivePolicy.Ignore then
            normalized.policy = ast.MappedDiagnosticDirectivePolicy.Ignore
        elseif directive.policy == DiagnosticDirectivePolicy.Expect then
            local unusedDiagnosticIndex = 0
            if directive.unusedExpectDirectiveIndex ~= nil then
                unusedDiagnosticIndex = directive.unusedExpectDirectiveIndex
            elseif #unused ~= 1 then
                return nil, directiveError(DiagnosticDirectiveErrorKind.ExpectMissingUnusedDiagnostic)
            end
            if unusedDiagnosticIndex < 0 or unusedDiagnosticIndex >= #unused then
                return nil, directiveError(DiagnosticDirectiveErrorKind.InvalidUnusedDiagnosticIndex)
            end
            local unusedDiagnostic = unused[unusedDiagnosticIndex + 1]
            normalized.policy = ast.MappedDiagnosticDirectivePolicy.Expect
            normalized.unusedCode = unusedDiagnostic.code
            normalized.unusedMessageText = unusedDiagnostic.messageText
        else
            local validationError = directiveError(DiagnosticDirectiveErrorKind.InvalidPolicy)
            validationError.policy = directive.policy
            return nil, validationError
        end
        if directive.virtualStart < 0 or directive.virtualEnd < directive.virtualStart then
            return nil, directiveError(DiagnosticDirectiveErrorKind.InvalidRange)
        end
        local virtualStart, err = virtualPositions:normalize(directive.virtualStart)
        if err ~= nil then
            return nil, directiveError(DiagnosticDirectiveErrorKind.InvalidRange)
        end
        local virtualEnd
        virtualEnd, err = virtualPositions:normalize(directive.virtualEnd)
        if err ~= nil then
            return nil, directiveError(DiagnosticDirectiveErrorKind.InvalidRange)
        end
        normalized.virtualRange = core.NewTextRange(virtualStart, virtualEnd)
        local validOriginalRange = directive.originalStart >= 0 and directive.originalLength >= 0 and directive.originalStart <= math.maxinteger - directive.originalLength
        if validOriginalRange then
            local originalStart, startErr = originalPositions:normalize(directive.originalStart)
            local originalEnd, endErr = originalPositions:normalize(directive.originalStart + directive.originalLength)
            if startErr == nil and endErr == nil then
                normalized.originalRange = core.NewTextRange(originalStart, originalEnd)
            else
                validOriginalRange = false
            end
        end
        if normalized.policy == ast.MappedDiagnosticDirectivePolicy.Expect and not validOriginalRange then
            return nil, directiveError(DiagnosticDirectiveErrorKind.InvalidRange)
        end
        result[i1] = normalized
    end
    local sorted = {}
    for i1, directive in ipairs(result) do
        sorted[i1] = { directive = directive, index = i1 - 1 }
    end
    core.SortFunc(sorted, function(a, b)
        return a.directive.virtualRange:Pos() - b.directive.virtualRange:Pos()
    end)
    for i = 2, #sorted do
        if sorted[i].directive.virtualRange:Pos() < sorted[i - 1].directive.virtualRange:End() then
            return nil, contentmapper.NewDiagnosticDirectiveError({ kind = DiagnosticDirectiveErrorKind.Overlap, index = sorted[i].index, supplementalIndex = -1 })
        end
    end
    return result, nil
end

function contentmapper.normalizeMappings(mappings, virtualPositions, originalPositions)
    local segments = mappings:Segments()
    for i1, segment in ipairs(segments) do
        local i = i1 - 1
        local virtualStart, err = virtualPositions:normalize(segment.virtualStart)
        if err ~= nil then
            return nil, newError(string.format("invalid content mapper mapping %d virtual start: %s", i, errorString(err)), err)
        end
        local virtualEnd
        virtualEnd, err = virtualPositions:normalize(segment.virtualEnd)
        if err ~= nil then
            return nil, newError(string.format("invalid content mapper mapping %d virtual end: %s", i, errorString(err)), err)
        end
        local originalStart
        originalStart, err = originalPositions:normalize(segment.originalStart)
        if err ~= nil then
            return nil, newError(string.format("invalid content mapper mapping %d original start: %s", i, errorString(err)), err)
        end
        local originalEnd
        originalEnd, err = originalPositions:normalize(segment.originalEnd)
        if err ~= nil then
            return nil, newError(string.format("invalid content mapper mapping %d original end: %s", i, errorString(err)), err)
        end
        segments[i1] = spanmap.NewSegment({
            virtualStart = virtualStart,
            virtualEnd = virtualEnd,
            originalStart = originalStart,
            originalEnd = originalEnd,
            kind = segment.kind,
            features = segment.features,
        })
    end
    return spanmap.New(segments), nil
end

local positionNormalizer = {}
positionNormalizer.__index = positionNormalizer
contentmapper.positionNormalizer = positionNormalizer

-- newPositionNormalizer returns (*positionNormalizer, err).
function contentmapper.newPositionNormalizer(text, encoding)
    local normalizer = setmetatable({ text = text, encoding = encoding, positionMap = nil, length = 0 }, positionNormalizer)
    if encoding == PositionEncoding.UTF8 then
        normalizer.length = #text
    elseif encoding == PositionEncoding.UTF16 then
        normalizer.positionMap = ast.ComputePositionMap(text)
        normalizer.length = normalizer.positionMap:UTF8ToUTF16(#text)
    else
        return nil, newError("unsupported position encoding " .. quote(encoding))
    end
    return normalizer, nil
end

function positionNormalizer:normalizeTextPos(position)
    return self:normalize(position)
end

-- normalize returns (bytePosition, err).
function positionNormalizer:normalize(position)
    if position < 0 then
        return 0, newError(string.format("position %d is negative", position))
    end
    if position > self.length then
        return 0, newError(string.format("position %d exceeds %s length %d", position, self.encoding, self.length))
    end
    local bytePosition = 0
    if self.encoding == PositionEncoding.UTF8 then
        bytePosition = position
    elseif self.encoding == PositionEncoding.UTF16 then
        bytePosition = self.positionMap:UTF16ToUTF8(position)
    end
    if bytePosition < #self.text then
        local b = string.byte(self.text, bytePosition + 1)
        -- utf8.RuneStart: not a continuation byte
        if b & 0xC0 == 0x80 then
            return 0, newError(string.format("position %d splits a Unicode code point", position))
        end
    end
    return bytePosition, nil
end

-- rejectHandler rejects any request initiated by the mapper. The content mapper protocol is currently
-- parent-driven only; a request from the child is a protocol violation.
contentmapper.rejectHandler = {
    HandleRequest = function(_, ctx, method, params)
        return nil, newError("content mapper sent an unexpected request: " .. method)
    end,
    HandleNotification = function(_, ctx, method, params)
        return nil
    end,
}
