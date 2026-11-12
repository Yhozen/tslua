local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")

-- Transport is an interface for accepting connections from API clients:
--   Accept() -> (io.ReadWriteCloser, err)   waits for and returns the next connection
--   Close() -> err                          stops the transport from accepting new connections

-- PipeTransport accepts connections on a Unix domain socket or Windows named pipe. Pure Lua has
-- no socket API, so it is not available.
function ipc.NewPipeTransport(path)
    return nil, jsonrpc.NewError("not implemented: ipc.NewPipeTransport (Unix domain sockets / named pipes)")
end

-- StdioTransport wraps stdin/stdout as a single connection transport.
-- It only accepts one connection. stdin is read with read(n) / read("L") (Lua file semantics);
-- stdout is written with write and flushed after each message.
local StdioTransport = {}
StdioTransport.__index = StdioTransport
ipc.StdioTransport = StdioTransport

-- NewStdioTransport creates a transport using the given stdin/stdout.
function ipc.NewStdioTransport(stdin, stdout)
    return setmetatable({ stdin = stdin, stdout = stdout, used = false }, StdioTransport)
end

-- Accept implements Transport.
function StdioTransport:Accept()
    if self.used then
        return nil, jsonrpc.EOF
    end
    self.used = true
    return ipc.newStdioConn(self.stdin, self.stdout), nil
end

-- Close implements Transport.
function StdioTransport:Close()
    return nil
end

local stdioConn = {}
stdioConn.__index = stdioConn
ipc.stdioConn = stdioConn

function ipc.newStdioConn(stdin, stdout)
    return setmetatable({ stdin = stdin, stdout = stdout }, stdioConn)
end

function stdioConn:read(format)
    return self.stdin:read(format)
end

-- Write implements io.Writer. Returns (n, err).
function stdioConn:Write(data)
    local w = self.stdout
    if type(w.Write) == "function" then
        return w:Write(data)
    end
    local ok, res, msg = pcall(w.write, w, data)
    if not ok then
        return 0, res
    end
    if res == nil then
        return 0, msg
    end
    if w.flush ~= nil then
        w:flush()
    end
    return #data, nil
end

function stdioConn:Close()
    local err1, err2
    if self.stdin.close ~= nil then
        local ok, e = pcall(self.stdin.close, self.stdin)
        if not ok then
            err1 = e
        end
    elseif self.stdin.Close ~= nil then
        err1 = self.stdin:Close()
    end
    if self.stdout.close ~= nil then
        local ok, e = pcall(self.stdout.close, self.stdout)
        if not ok then
            err2 = e
        end
    elseif self.stdout.Close ~= nil then
        err2 = self.stdout:Close()
    end
    if err1 ~= nil then
        return err1
    end
    return err2
end

-- GeneratePipePath returns a platform-appropriate pipe path for the given name.
function ipc.GeneratePipePath(name)
    local tmp = os.getenv("TMPDIR")
    if tmp == nil or tmp == "" then
        tmp = "/tmp"
    end
    return (string.gsub(tmp, "/+$", "")) .. "/" .. name
end
