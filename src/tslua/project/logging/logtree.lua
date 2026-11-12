local logging = require("tslua.project.logging")
local core = require("tslua.core")

logging.seq = 0

-- logEntry: { seq, time, message, child }
function logging.newLogEntry(child, message)
    logging.seq = logging.seq + 1
    return {
        seq = logging.seq,
        time = logging.timeNow(),
        message = message,
        child = child,
    }
end

-- LogTree methods tolerate a nil receiver like Go's: call them as logging.LogTree.Log(tree, ...)
-- when the tree may be nil.
local LogTree = {}
LogTree.__index = LogTree
logging.LogTree = LogTree

function logging.NewLogTree(name)
    local lc = setmetatable({
        name = name,
        logs = {},
        root = nil,
        level = 0,
        verbose = false,
        -- Only set on root
        count = 0,
        stringLength = 0,
    }, LogTree)
    lc.root = lc
    return lc
end

function LogTree:add(log)
    -- indent + header + message + newline
    self.root.stringLength = self.root.stringLength + (self.level + 15 + #log.message + 1)
    self.root.count = self.root.count + 1
    self.logs[#self.logs + 1] = log
end

function LogTree.Log(self, ...)
    if self == nil then
        return
    end
    local log = logging.newLogEntry(nil, logging.Sprint(...))
    self:add(log)
end

function LogTree.Logf(self, format, ...)
    if self == nil then
        return
    end
    local log = logging.newLogEntry(nil, logging.Sprintf(format, ...))
    self:add(log)
end

function LogTree.IsVerbose(self)
    return self.verbose
end

function LogTree.SetVerbose(self, verbose)
    if self == nil then
        return
    end
    self.verbose = verbose
end

function LogTree.Verbose(self)
    if self == nil or not self.verbose then
        return nil
    end
    return self
end

function LogTree.Error(self, ...)
    LogTree.Log(self, ...)
end

function LogTree.Errorf(self, format, ...)
    LogTree.Logf(self, format, ...)
end

function LogTree.Warn(self, ...)
    LogTree.Log(self, ...)
end

function LogTree.Warnf(self, format, ...)
    LogTree.Logf(self, format, ...)
end

function LogTree.Info(self, ...)
    LogTree.Log(self, ...)
end

function LogTree.Infof(self, format, ...)
    LogTree.Logf(self, format, ...)
end

function LogTree.Embed(self, logs)
    if self == nil then
        return
    end
    local count = logs.count
    self.root.stringLength = self.root.stringLength + logs.stringLength + count * self.level
    self.root.count = self.root.count + count
    local log = logging.newLogEntry(logs, logs.name)
    self:add(log)
end

function LogTree.Fork(self, message)
    if self == nil then
        return nil
    end
    local child = setmetatable({
        name = "",
        logs = {},
        level = self.level + 1,
        root = self.root,
        verbose = self.verbose,
        count = 0,
        stringLength = 0,
    }, LogTree)
    local log = logging.newLogEntry(child, message)
    self:add(log)
    return child
end

function LogTree:String()
    if self.root ~= self then
        error("can only call String on root LogTree", 0)
    end
    local builder = core.NewStringBuilder()
    local header = "======== " .. self.name .. " ========\n"
    builder:WriteString(header)
    self:writeLogsRecursive(builder, "")
    return builder:String()
end

function LogTree:writeLogsRecursive(builder, indent)
    for _, log in ipairs(self.logs) do
        builder:WriteString(indent)
        builder:WriteString(logging.formatTime(log.time))
        builder:WriteString(" ")
        builder:WriteString(log.message)
        builder:WriteString("\n")
        if log.child ~= nil then
            log.child:writeLogsRecursive(builder, indent .. "\t")
        end
    end
end
