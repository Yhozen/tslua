-- Lua-only stand-in (no Go counterpart file) for net.Pipe plus the goroutine that serves the far end.
-- Pipe returns two connected in-memory endpoints usable as the io.ReadWriteCloser of a connection:
-- they follow the tslua.jsonrpc stream contract (read("L") / read(n) with Lua file semantics, nil at
-- end of input; Write(s) -> (n, err); Close() -> err).
-- GoPeer runs a function on its own coroutine as the owner of one endpoint: whenever the other endpoint
-- reads with nothing buffered, the peer coroutine is resumed until it produces data, blocks reading an
-- empty pipe (yields), or returns. This reproduces the interleaving of a goroutine serving the far end
-- of a synchronous pipe without threads.
local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")

ipc.ErrClosedPipe = jsonrpc.NewError("io: read/write on closed pipe")

local pipeEnd = {}
pipeEnd.__index = pipeEnd
ipc.pipeEnd = pipeEnd

local function newPipeEnd()
    return setmetatable({ buf = "", closed = false, other = nil, peer = nil, isPeerSide = false }, pipeEnd)
end

-- Pipe creates a synchronous, in-memory, full duplex connection. Returns (a, b).
function ipc.Pipe()
    local a, b = newPipeEnd(), newPipeEnd()
    a.other, b.other = b, a
    return a, b
end

-- GoPeer runs fn() on a coroutine that owns endpoint `owned`, the far end of `driven`. Reads on
-- `driven` resume the coroutine while no data is available.
function ipc.GoPeer(driven, owned, fn)
    driven.peer = coroutine.create(fn)
    owned.isPeerSide = true
end

-- resumePeer resumes the peer coroutine once. Returns false when it has already finished.
function pipeEnd:resumePeer()
    local co = self.peer
    if co == nil or coroutine.status(co) ~= "suspended" then
        return false
    end
    local ok, err = coroutine.resume(co)
    if not ok then
        -- A panicking goroutine crashes a Go program; surface it to the driver.
        error(err, 0)
    end
    return true
end

-- fill waits until data is buffered. Returns false at end of input (the other side closed or exited).
function pipeEnd:fill()
    while self.buf == "" do
        if self.closed then
            error(ipc.ErrClosedPipe, 0)
        end
        if self.other.closed then
            return false
        end
        if self.isPeerSide then
            -- The serving goroutine blocks until the driver writes or closes.
            coroutine.yield()
        else
            if not self:resumePeer() then
                -- The peer exited (or never started) without writing: the far end is gone.
                return false
            end
            if self.buf == "" and coroutine.status(self.peer) == "suspended" then
                -- The peer only yields once it has drained its input, so it is waiting on this side,
                -- which is itself waiting on the peer: a deadlock in Go.
                error(jsonrpc.NewError("ipc: pipe deadlock: both endpoints are waiting to read"), 0)
            end
        end
    end
    return true
end

-- read implements Lua file:read for "L" (a line including "\n", or the rest of the input) and n
-- (up to n bytes). Returns nil at end of input.
function pipeEnd:read(format)
    if format == "L" or format == "l" then
        local parts = {}
        while true do
            if not self:fill() then
                break
            end
            local nl = string.find(self.buf, "\n", 1, true)
            if nl ~= nil then
                parts[#parts + 1] = string.sub(self.buf, 1, nl)
                self.buf = string.sub(self.buf, nl + 1)
                break
            end
            parts[#parts + 1] = self.buf
            self.buf = ""
        end
        local line = table.concat(parts)
        if line == "" then
            return nil
        end
        if format == "l" and string.sub(line, -1) == "\n" then
            line = string.sub(line, 1, -2)
        end
        return line
    end
    local n = format
    if not self:fill() then
        return nil
    end
    local chunk = string.sub(self.buf, 1, n)
    self.buf = string.sub(self.buf, n + 1)
    return chunk
end

-- Write appends data to the other endpoint's buffer. Returns (n, err).
function pipeEnd:Write(data)
    if self.closed or self.other.closed then
        return 0, ipc.ErrClosedPipe
    end
    self.other.buf = self.other.buf .. data
    return #data, nil
end

-- Close closes this endpoint; the other endpoint then reads end of input. A peer blocked reading stays
-- suspended (like a goroutine nobody wakes up) and is collected with the pipe.
function pipeEnd:Close()
    if self.closed then
        return nil
    end
    self.closed = true
    return nil
end
