local jsonrpc = require("tslua.jsonrpc")

-- Base protocol for JSON-RPC with Content-Length headers (as used by LSP).
-- https://microsoft.github.io/language-server-protocol/specifications/base/0.9/specification/
--
-- io.Reader / io.Writer contracts: a reader is a Lua file handle or any object with Lua file
-- read semantics (r:read("L") returns the next line including "\n", r:read(n) returns up to n
-- bytes; nil at end of input). A writer is a Lua file handle (w:write(s), w:flush()) or an
-- io.Writer-like object with w:Write(s) returning (n, err) (optionally w:Flush()). Since Lua
-- handles are already buffered, bufio.Reader/Writer are not modeled separately.

jsonrpc.ErrInvalidHeader = jsonrpc.NewError("jsonrpc: invalid header")
jsonrpc.ErrInvalidContentLength = jsonrpc.NewError("jsonrpc: invalid content length")
jsonrpc.ErrNoContentLength = jsonrpc.NewError("jsonrpc: no content length")

-- Go %q formatting of a byte string (strconv.Quote).
function jsonrpc.goQuote(s)
    local out = { '"' }
    for i = 1, #s do
        local c = string.byte(s, i)
        if c == 0x22 then
            out[#out + 1] = '\\"'
        elseif c == 0x5C then
            out[#out + 1] = "\\\\"
        elseif c == 0x0A then
            out[#out + 1] = "\\n"
        elseif c == 0x0D then
            out[#out + 1] = "\\r"
        elseif c == 0x09 then
            out[#out + 1] = "\\t"
        elseif c == 0x07 then
            out[#out + 1] = "\\a"
        elseif c == 0x08 then
            out[#out + 1] = "\\b"
        elseif c == 0x0C then
            out[#out + 1] = "\\f"
        elseif c == 0x0B then
            out[#out + 1] = "\\v"
        elseif c < 0x20 or c == 0x7F then
            out[#out + 1] = string.format("\\x%02x", c)
        else
            out[#out + 1] = string.char(c)
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

-- strconv.ParseInt(s, 10, 64). Returns (value, err).
function jsonrpc.parseInt(s)
    local syntax = "strconv.ParseInt: parsing " .. jsonrpc.goQuote(s) .. ": invalid syntax"
    if not string.match(s, "^[-+]?%d+$") then
        return 0, jsonrpc.NewError(syntax)
    end
    local v = math.tointeger(tonumber(s))
    if v == nil or #string.gsub(s, "^[-+]?0*", "") > 19 then
        return 0, jsonrpc.NewError("strconv.ParseInt: parsing " .. jsonrpc.goQuote(s) .. ": value out of range")
    end
    return v, nil
end

-- Reader reads JSON-RPC messages with Content-Length framing.
local Reader = {}
Reader.__index = Reader
jsonrpc.Reader = Reader

-- NewReader creates a new Reader.
function jsonrpc.NewReader(r)
    return setmetatable({ r = r }, Reader)
end

local function trimSpace(s)
    return (string.gsub(string.gsub(s, "^[ \t\r\n\v\f]+", ""), "[ \t\r\n\v\f]+$", ""))
end

-- Read reads the next message payload. Returns (data, err).
function Reader:Read()
    local contentLength = 0

    while true do
        local ok, line = pcall(self.r.read, self.r, "L")
        if not ok then
            return nil, jsonrpc.NewError("jsonrpc: read header: " .. tostring(line), line)
        end
        if line == nil or string.sub(line, -1) ~= "\n" then
            return nil, jsonrpc.EOF
        end

        if line == "\r\n" then
            break
        end

        local colon = string.find(line, ":", 1, true)
        if colon == nil then
            return nil, jsonrpc.NewError(jsonrpc.ErrInvalidHeader:Error() .. ": " .. jsonrpc.goQuote(line), jsonrpc.ErrInvalidHeader)
        end
        local key, value = string.sub(line, 1, colon - 1), string.sub(line, colon + 1)

        if key == "Content-Length" then
            local n, err = jsonrpc.parseInt(trimSpace(value))
            if err ~= nil then
                return nil, jsonrpc.NewError(jsonrpc.ErrInvalidContentLength:Error() .. ": parse error: " .. err:Error(), jsonrpc.ErrInvalidContentLength, err)
            end
            contentLength = n
            if contentLength < 0 then
                return nil, jsonrpc.NewError(jsonrpc.ErrInvalidContentLength:Error() .. ": negative value " .. tostring(contentLength), jsonrpc.ErrInvalidContentLength)
            end
        end
    end

    if contentLength <= 0 then
        return nil, jsonrpc.ErrNoContentLength
    end

    local parts = {}
    local remaining = contentLength
    while remaining > 0 do
        local ok, chunk = pcall(self.r.read, self.r, remaining)
        if not ok then
            return nil, jsonrpc.NewError("jsonrpc: read content: " .. tostring(chunk), chunk)
        end
        if chunk == nil or #chunk == 0 then
            local e = jsonrpc.EOF
            if remaining < contentLength then
                -- io.ReadFull: a partial read ends with io.ErrUnexpectedEOF.
                e = jsonrpc.ErrUnexpectedEOF
            end
            return nil, jsonrpc.NewError("jsonrpc: read content: " .. e:Error(), e)
        end
        parts[#parts + 1] = chunk
        remaining = remaining - #chunk
    end

    return table.concat(parts), nil
end

-- io.ErrUnexpectedEOF
jsonrpc.ErrUnexpectedEOF = jsonrpc.NewError("unexpected EOF")

-- Writer writes JSON-RPC messages with Content-Length framing.
local Writer = {}
Writer.__index = Writer
jsonrpc.Writer = Writer

-- NewWriter creates a new Writer.
function jsonrpc.NewWriter(w)
    return setmetatable({ w = w }, Writer)
end

local function writeTo(w, s)
    if type(w.Write) == "function" then
        local _, err = w:Write(s)
        return err
    end
    local ok, res, msg = pcall(w.write, w, s)
    if not ok then
        return res
    end
    if res == nil then
        return msg
    end
    return nil
end

local function flush(w)
    if type(w.Flush) == "function" then
        return w:Flush()
    elseif type(w.Write) ~= "function" and w.flush ~= nil then
        local ok, res, msg = pcall(w.flush, w)
        if not ok then
            return res
        end
        if res == nil then
            return msg
        end
    end
    return nil
end

-- Write writes a message payload with Content-Length header. Returns err.
function Writer:Write(data)
    -- Header and payload are written together, like the single bufio.Writer flush in Go.
    local err = writeTo(self.w, "Content-Length: " .. tostring(#data) .. "\r\n\r\n" .. data)
    if err ~= nil then
        return err
    end
    return flush(self.w)
end
