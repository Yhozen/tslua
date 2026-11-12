local lsp = require("tslua.lsp")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local logging = require("tslua.project.logging")

local LogVerbosity = lsproto.LogVerbosity
local MessageType = lsproto.MessageType

-- logger implements logging.Logger by sending window/logMessage notifications.
local logger = {}
logger.__index = logger
lsp.logger = logger

function lsp.newLogger(server)
    return setmetatable({
        server = server,
        verbosity = LogVerbosity.Info,
    }, logger)
end

-- maxVerbosityForMessageType returns the least-verbose log level at which
-- messages of the given LSP MessageType should still be sent.
function lsp.maxVerbosityForMessageType(msgType)
    if msgType == MessageType.Error then
        return LogVerbosity.Error
    elseif msgType == MessageType.Warning then
        return LogVerbosity.Warning
    elseif msgType == MessageType.Info then
        return LogVerbosity.Info
    elseif msgType == MessageType.Debug then
        return LogVerbosity.Debug
    end
    return LogVerbosity.Info
end

-- isValidLogVerbosity reports whether v is one of the defined LogVerbosity values.
function lsp.isValidLogVerbosity(v)
    return v >= LogVerbosity.Off and v <= LogVerbosity.Error
end

-- fmt.Fprintln(w, s) for an io.Writer (Write or WriteString) or a Lua file handle.
function lsp.fprintln(w, s)
    if w == nil then
        return
    end
    if type(w.WriteString) == "function" then
        w:WriteString(s .. "\n")
    elseif type(w.Write) == "function" then
        w:Write(s .. "\n")
    elseif w.write ~= nil then
        w:write(s .. "\n")
    end
end

function logger:sendLogMessage(msgType, message)
    if not self.server.initStarted then
        lsp.fprintln(self.server.stderr, message)
        return
    end

    -- Don't send messages that the client will filter out anyway.
    local verbosity = self.verbosity
    if verbosity == LogVerbosity.Off or verbosity > lsp.maxVerbosityForMessageType(msgType) then
        return
    end

    local notification = lsproto.WindowLogMessageInfo:NewNotificationMessage(lsproto.LogMessageParams({
        type = msgType,
        message = message,
    }))

    local err = self.server.outgoingQueue:Put(self.server.backgroundCtx, notification:Message())
    if err ~= nil then
        if core.ContextErr(self.server.backgroundCtx) ~= nil then
            lsp.fprintln(self.server.stderr, message)
        end
        return
    end
    self.server:flushOutgoing()
end

function logger:Log(...)
    self:sendLogMessage(MessageType.Info, logging.Sprint(...))
end

function logger:Logf(format, ...)
    self:sendLogMessage(MessageType.Info, logging.Sprintf(format, ...))
end

function logger:Verbose()
    if self.verbosity == LogVerbosity.Off or self.verbosity > LogVerbosity.Debug then
        return nil
    end
    return self
end

function logger:IsVerbose()
    return self.verbosity >= LogVerbosity.Trace and self.verbosity <= LogVerbosity.Debug
end

function logger:SetVerbose(verbose)
    if verbose then
        self.verbosity = LogVerbosity.Debug
    else
        self.verbosity = LogVerbosity.Info
    end
end

function logger:IsTracing()
    return self.verbosity == LogVerbosity.Trace
end

function logger:SetVerbosity(verbosity)
    self.verbosity = verbosity
end

function logger:Error(...)
    self:sendLogMessage(MessageType.Error, logging.Sprint(...))
end

function logger:Errorf(format, ...)
    self:sendLogMessage(MessageType.Error, logging.Sprintf(format, ...))
end

function logger:Warn(...)
    self:sendLogMessage(MessageType.Warning, logging.Sprint(...))
end

function logger:Warnf(format, ...)
    self:sendLogMessage(MessageType.Warning, logging.Sprintf(format, ...))
end

function logger:Info(...)
    self:sendLogMessage(MessageType.Info, logging.Sprint(...))
end

function logger:Infof(format, ...)
    self:sendLogMessage(MessageType.Info, logging.Sprintf(format, ...))
end
