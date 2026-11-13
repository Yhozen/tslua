local contentmapper = require("tslua.contentmapper")

local ProjectErrorKind = contentmapper.ProjectErrorKind
local InitializeErrorKind = contentmapper.InitializeErrorKind

-- TransformError reports a failure while preparing, requesting, or decoding a transform.
-- { kind = TransformErrorKind, err = error } (err is also the `unwrap` link).
local TransformError = {}
TransformError.__index = TransformError
contentmapper.TransformError = TransformError

-- NewTransformError creates a transform error for the given stage and underlying error.
function contentmapper.NewTransformError(kind, err)
    return setmetatable({ kind = kind, err = err, unwrap = err }, TransformError)
end

-- goErrorValue formats an error like Go's %v (nil prints as <nil>).
local function goErrorValue(err)
    if err == nil then
        return "<nil>"
    end
    return require("tslua.jsonrpc").ErrorString(err)
end

function TransformError:Error()
    return "content mapper transform failed: " .. goErrorValue(self.err)
end

function TransformError:Unwrap()
    return self.err
end

-- DiagnosticDirectiveError reports an invalid diagnostic directive in a transform response.
-- { kind = DiagnosticDirectiveErrorKind, index = int, supplementalIndex = int, policy = DiagnosticDirectivePolicy }
local DiagnosticDirectiveError = {}
DiagnosticDirectiveError.__index = DiagnosticDirectiveError
contentmapper.DiagnosticDirectiveError = DiagnosticDirectiveError

function contentmapper.NewDiagnosticDirectiveError(t)
    return setmetatable({
        kind = t.kind or 0,
        index = t.index or 0,
        supplementalIndex = t.supplementalIndex or 0,
        policy = t.policy or 0,
    }, DiagnosticDirectiveError)
end

function DiagnosticDirectiveError:Error()
    return string.format("invalid content mapper diagnostic directive %d", self.index)
end

-- InvalidVirtualExtensionError reports an unsupported or missing virtual extension on a mapped output.
local InvalidVirtualExtensionError = {}
InvalidVirtualExtensionError.__index = InvalidVirtualExtensionError
contentmapper.InvalidVirtualExtensionError = InvalidVirtualExtensionError

function contentmapper.NewInvalidVirtualExtensionError(extension)
    return setmetatable({ extension = extension }, InvalidVirtualExtensionError)
end

function InvalidVirtualExtensionError:Error()
    return "invalid virtual extension " .. require("tslua.jsonrpc").goQuote(self.extension)
end

-- ProjectError reports an invalid mapper openProject response.
local ProjectError = {}
ProjectError.__index = ProjectError
contentmapper.ProjectError = ProjectError

function contentmapper.NewProjectError(kind)
    return setmetatable({ kind = kind }, ProjectError)
end

function ProjectError:Error()
    local k = self.kind
    if k == ProjectErrorKind.MalformedResponse then
        return "content mapper returned a malformed project response"
    elseif k == ProjectErrorKind.MissingConfigIdentity then
        return "content mapper did not return configIdentity for dynamic configuration"
    elseif k == ProjectErrorKind.NonAbsoluteWatchedFile then
        return "content mapper returned a non-absolute path in watchedFiles"
    elseif k == ProjectErrorKind.UnexpectedConfigIdentity then
        return "content mapper returned configIdentity without declaring dynamicConfig"
    elseif k == ProjectErrorKind.UnexpectedWatchedFiles then
        return "content mapper returned watchedFiles without declaring dynamicConfig"
    end
    return "content mapper returned an invalid project response"
end

-- InitializeError reports an invalid or unsupported mapper initialize response.
-- { kind, mapperName, command, detail, exitCode, timeoutSeconds, protocolVersion, positionEncoding, diagnosticSource }
local InitializeError = {}
InitializeError.__index = InitializeError
contentmapper.InitializeError = InitializeError

function contentmapper.NewInitializeError(t)
    return setmetatable({
        kind = t.kind or 0,
        mapperName = t.mapperName or "",
        command = t.command or "",
        detail = t.detail or "",
        exitCode = t.exitCode or 0,
        timeoutSeconds = t.timeoutSeconds or 0,
        protocolVersion = t.protocolVersion or 0,
        positionEncoding = t.positionEncoding or "",
        diagnosticSource = t.diagnosticSource or "",
    }, InitializeError)
end

-- SupplementalFileCollisionError reports a compiler-assigned supplemental filename that already exists.
local SupplementalFileCollisionError = {}
SupplementalFileCollisionError.__index = SupplementalFileCollisionError
contentmapper.SupplementalFileCollisionError = SupplementalFileCollisionError

function contentmapper.NewSupplementalFileCollisionError(fileName)
    return setmetatable({ fileName = fileName }, SupplementalFileCollisionError)
end

function SupplementalFileCollisionError:Error()
    return "content mapper supplemental output file " .. require("tslua.jsonrpc").goQuote(self.fileName) .. " already exists"
end

function InitializeError:Error()
    local quote = require("tslua.jsonrpc").goQuote
    local k = self.kind
    if k == InitializeErrorKind.ProcessStart then
        return "could not start content mapper command " .. quote(self.command) .. ": " .. self.detail
    elseif k == InitializeErrorKind.ProcessExit then
        return string.format("content mapper process exited before initialization with code %d", self.exitCode)
    elseif k == InitializeErrorKind.NoResponse then
        return "content mapper did not respond to the initialize request"
    elseif k == InitializeErrorKind.InvalidResponse then
        return "content mapper returned an invalid initialize response: " .. self.detail
    elseif k == InitializeErrorKind.Request then
        return "content mapper initialize request failed: " .. self.detail
    elseif k == InitializeErrorKind.ProtocolVersion then
        return string.format("unsupported protocol version %d (expected %d)", self.protocolVersion, contentmapper.ProtocolVersion)
    elseif k == InitializeErrorKind.PositionEncoding then
        return "unsupported position encoding " .. quote(self.positionEncoding)
    elseif k == InitializeErrorKind.EmptyDiagnosticSource then
        return "diagnostic source must not be empty"
    elseif k == InitializeErrorKind.ReservedDiagnosticSource then
        return "diagnostic source " .. quote(self.diagnosticSource) .. " is reserved by TypeScript"
    end
    return "content mapper initialization failed"
end

-- Result is the outcome of transforming a content-mapped source file into virtual TypeScript:
-- {
--   text                 -- the virtual TypeScript source text that is parsed into the program.
--   virtualExtension     -- determines how text is parsed.
--   diagnostics          -- []*ast.Diagnostic: syntax errors in the original content.
--   mappings             -- *spanmap.SpanMap mapping positions in text back to the original content, so
--                           that diagnostics the compiler produces against the virtual text can be reported
--                           at their original locations. A successful transform must return a non-nil map;
--                           an empty map describes fully synthesized output.
--   diagnosticDirectives -- []ast.MappedDiagnosticDirective controlling TypeScript diagnostics in virtual ranges.
--   supplemental         -- []MappedResult: additional unnamed outputs associated with the canonical result.
-- }
function contentmapper.NewResult(t)
    t = t or {}
    return {
        text = t.text or "",
        virtualExtension = t.virtualExtension or "",
        diagnostics = t.diagnostics,
        mappings = t.mappings,
        diagnosticDirectives = t.diagnosticDirectives,
        supplemental = t.supplemental,
    }
end

-- MappedResult is one virtual source file and its mapping to the original input:
-- { text, virtualExtension, mappings, diagnosticDirectives }.
function contentmapper.NewMappedResult(t)
    t = t or {}
    return {
        text = t.text or "",
        virtualExtension = t.virtualExtension or "",
        mappings = t.mappings,
        diagnosticDirectives = t.diagnosticDirectives,
    }
end

-- Request carries the inputs for transforming one content-mapped source file:
-- { fileName = the content-mapped source file being transformed, content = its text }.
function contentmapper.NewRequest(fileName, content)
    return { fileName = fileName or "", content = content or "" }
end

-- ProjectSpec describes the project configuration visible to its content mappers:
-- { configFileName = absolute project configuration file name, or "" for a project without one,
--   mappers = the resolved content mapper entries configured for the project,
--   compilerOptions = the project's effective compiler options }.

-- OptionPathSegment: { property = string, index = int, isIndex = bool }.
-- OptionDiagnostic: { mapper = *Mapper, path = []OptionPathSegment, source = string, code = int32, messageText = string }.

-- OperationTiming is the cumulative wall time (seconds) and invocation count for one mapper operation:
-- { count, duration }.
function contentmapper.NewOperationTiming(count, duration)
    return { count = count or 0, duration = duration or 0 }
end

-- MapperTimings is cumulative process and protocol activity for one resolved mapper identity:
-- { spawn, initialize, openProject, closeProject, transform } (each an OperationTiming).

-- Timings is a cumulative snapshot of content mapper process and protocol activity:
-- { mappers = map[identity]MapperTimings, requestWait = seconds }.

local Timings = {}
Timings.__index = Timings
contentmapper.Timings = Timings

function contentmapper.NewTimings(t)
    t = t or {}
    return setmetatable({ mappers = t.mappers or {}, requestWait = t.requestWait or 0 }, Timings)
end

-- Since returns the non-negative operation delta since previous.
function Timings:Since(previous)
    return contentmapper.Timings_Since(self, previous)
end

-- Timings_Since is Timings.Since callable on plain { mappers, requestWait } tables.
function contentmapper.Timings_Since(t, previous)
    local result = contentmapper.NewTimings({
        mappers = {},
        requestWait = math.max(t.requestWait - previous.requestWait, 0),
    })
    for identity, current in pairs(t.mappers or {}) do
        local before = (previous.mappers or {})[identity] or contentmapper.zeroMapperTimings()
        result.mappers[identity] = {
            spawn = contentmapper.operationTimingSince(current.spawn, before.spawn),
            initialize = contentmapper.operationTimingSince(current.initialize, before.initialize),
            openProject = contentmapper.operationTimingSince(current.openProject, before.openProject),
            closeProject = contentmapper.operationTimingSince(current.closeProject, before.closeProject),
            transform = contentmapper.operationTimingSince(current.transform, before.transform),
        }
    end
    return result
end

function contentmapper.zeroMapperTimings()
    return {
        spawn = contentmapper.NewOperationTiming(),
        initialize = contentmapper.NewOperationTiming(),
        openProject = contentmapper.NewOperationTiming(),
        closeProject = contentmapper.NewOperationTiming(),
        transform = contentmapper.NewOperationTiming(),
    }
end

function contentmapper.operationTimingSince(current, previous)
    return {
        count = current.count - math.min(current.count, previous.count),
        duration = math.max(current.duration - previous.duration, 0),
    }
end

-- Project is the project-scoped view of a Host. It owns mapper configuration handles and provides the
-- identities and watch dependencies needed for caching and incremental builds. Mapper projects are opened
-- lazily when a transform is requested, or earlier when dynamic configuration is needed.
--   Refresh() -> err
--       closes opened mapper projects so they are reopened on the next transform or configuration identity query.
--   Identities() -> ([]string, err)
--       sorted transform identities for all configured mappers. It returns an error if dynamic project
--       configuration cannot be opened or validated.
--   Identity(mapper) -> (string, err)
--       the transform identity for mapper, or "" if mapper is not in this project.
--   WatchedFiles() -> ([]string, err)
--       the absolute files reported by mappers whose package.json declares dynamicConfig.
--   Diagnostics() -> []OptionDiagnostic
--       option diagnostics cached by mapper projects that have already been opened.
--   Transform(mapper, request) -> (Result, err)
--       transforms one content-mapped source file using mapper in this project's configuration.
--   Close() -> err
--       releases this project reference and closes mapper project handles when no references remain.

-- Host transforms otherwise unsupported file content into virtual TypeScript during program construction, by driving the
-- configured content mappers. Create one with NewHost; Close tears down every mapper it spawned.
--   Timings() -> Timings
--   Project(spec) -> Project      a retained project-scoped view for spec; the caller must close it.
--   Acquire(mappers) -> release   retains the processes for the given mapper identities until released.
--   SetLocale(locale)             stops existing processes so they respawn lazily with the new locale.
--   Transform(mapper, request) -> (Result, err)
--       maps a content-mapped source file using a short-lived project with default compiler options. A
--       non-nil error indicates the mapper itself failed to produce a result — for example the host hit a
--       broken pipe, a process crash, or could not deserialize the mapper's response.
--   Close() -> err                shuts down every mapper process the host spawned.
