-- Lua-only (no Go counterpart file): child processes with piped stdio, the counterpart of the
-- exec.Cmd + StdinPipe/StdoutPipe pair behind cmd/tsgo's spawnProcess (content mapper processes).
--
-- Pure Lua 5.4 has no bidirectional pipes (io.popen is one-way), so the child is started through a
-- POSIX shell with named pipes (mkfifo):
--   * io.popen(script, "w") is the child's stdin; the shell forwards it to the mapper through a FIFO
--     with `cat`, ignoring SIGPIPE and draining the rest of the input once the mapper is gone, so
--     writing to a dead mapper never raises SIGPIPE in this process;
--   * the mapper's stdout is a second FIFO opened here for reading (blocking reads, Lua file
--     semantics: read("L") / read(n), nil at end of input);
--   * stderr goes to a temporary file that is copied to the stderr writer when the process is closed
--     (Go streams it while the process runs).
-- Close kills the mapper (SIGKILL), then reaps the shell, whose exit status is the mapper's
-- (a signaled mapper reports 128+signal rather than Go's -1).
local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function readAll(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end

-- lookPath is exec.LookPath for names without a path separator. Returns (path, err).
function ipc.lookPath(file)
    if string.find(file, "/", 1, true) then
        return file, nil
    end
    for dir in string.gmatch(os.getenv("PATH") or "", "[^:]*") do
        if dir == "" then
            dir = "."
        end
        local path = dir .. "/" .. file
        local ok = os.execute("test -f " .. shellQuote(path) .. " -a -x " .. shellQuote(path))
        if ok == true or ok == 0 then
            return path, nil
        end
    end
    return "", jsonrpc.NewError("exec: " .. jsonrpc.goQuote(file) .. ": executable file not found in $PATH")
end

local childProcess = {}
childProcess.__index = childProcess
ipc.childProcess = childProcess

-- SpawnProcess launches command (argv) in dir (the current directory when "") and adapts its stdio to
-- an io.ReadWriteCloser following the tslua.jsonrpc stream contract (read is its stdout, Write is its
-- stdin) with ExitCode() -> (code, exited). stderr is an io.Writer (Write(data)). Returns (rwc, err).
function ipc.SpawnProcess(command, dir, stderr)
    if command == nil or #command == 0 then
        return nil, jsonrpc.NewError("exec: no command")
    end
    local _, err = ipc.lookPath(command[1])
    if err ~= nil then
        return nil, err
    end
    local base = os.tmpname()
    os.remove(base)
    local fifoIn, fifoOut, errFile, pidFile = base .. ".in", base .. ".out", base .. ".err", base .. ".pid"
    local ok = os.execute("mkfifo " .. shellQuote(fifoIn) .. " " .. shellQuote(fifoOut))
    if not (ok == true or ok == 0) then
        return nil, jsonrpc.NewError("mkfifo failed for " .. jsonrpc.goQuote(base))
    end
    local argv = {}
    for i, a in ipairs(command) do
        argv[i] = shellQuote(a)
    end
    local run = "exec " .. table.concat(argv, " ")
    if dir ~= nil and dir ~= "" then
        run = "cd " .. shellQuote(dir) .. " && " .. run
    end
    local script = "(" .. run .. ") < " .. shellQuote(fifoIn) .. " > " .. shellQuote(fifoOut) .. " 2> " .. shellQuote(errFile) .. " &\n" ..
        "pid=$!\n" ..
        "echo $pid > " .. shellQuote(pidFile) .. "\n" ..
        "(trap '' PIPE; cat > " .. shellQuote(fifoIn) .. "; cat > /dev/null)\n" ..
        "wait $pid\n" ..
        "exit $?\n"
    local stdin = io.popen(script, "w")
    if stdin == nil then
        os.remove(fifoIn)
        os.remove(fifoOut)
        return nil, jsonrpc.NewError("could not start " .. jsonrpc.goQuote(command[1]))
    end
    stdin:setvbuf("no")
    local stdout = io.open(fifoOut, "rb")
    if stdout == nil then
        stdin:close()
        os.remove(fifoIn)
        os.remove(fifoOut)
        return nil, jsonrpc.NewError("could not open the stdout of " .. jsonrpc.goQuote(command[1]))
    end
    return setmetatable({
        stdin = stdin,
        stdout = stdout,
        stderr = stderr,
        files = { fifoIn = fifoIn, fifoOut = fifoOut, errFile = errFile, pidFile = pidFile },
        exited = false,
        exitCode = 0,
        closed = false,
    }, childProcess), nil
end

function childProcess:read(format)
    if self.closed then
        return nil
    end
    return self.stdout:read(format)
end

-- Write returns (n, err).
function childProcess:Write(data)
    if self.closed then
        return 0, jsonrpc.NewError("write |1: file already closed")
    end
    local ok, err = self.stdin:write(data)
    if ok == nil then
        return 0, jsonrpc.NewError(tostring(err))
    end
    return #data, nil
end

-- ExitCode returns (code, exited); the state is known once the process has been reaped by Close.
function childProcess:ExitCode()
    return self.exitCode, self.exited
end

-- Close kills and reaps the process.
function childProcess:Close()
    if self.closed then
        return nil
    end
    self.closed = true
    local pid = readAll(self.files.pidFile)
    pid = pid and string.match(pid, "%d+")
    if pid ~= nil then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    local _, how, code = self.stdin:close()
    self.stdout:close()
    self.exited = true
    if how == "exit" then
        self.exitCode = code or 0
    else
        self.exitCode = -1
    end
    local errText = readAll(self.files.errFile)
    if errText ~= nil and errText ~= "" and self.stderr ~= nil then
        self.stderr:Write(errText)
    end
    for _, path in pairs(self.files) do
        os.remove(path)
    end
    return nil
end
