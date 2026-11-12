-- Lua-only support code (no Go counterpart file): a growable byte buffer standing in for Go's
-- []byte / strings.Builder in the encoder. Bytes are kept as string chunks; Len() is the byte
-- length (Go len(buf)). Bytes() concatenates them into a Lua string.
local encoder = require("tslua.api.encoder")

local ByteBuf = {}
ByteBuf.__index = ByteBuf
encoder.ByteBuf = ByteBuf

function encoder.newByteBuf()
    return setmetatable({ parts = {}, n = 0 }, ByteBuf)
end

function ByteBuf:Len()
    return self.n
end

-- WriteString appends raw bytes.
function ByteBuf:WriteString(s)
    if #s > 0 then
        self.parts[#self.parts + 1] = s
        self.n = self.n + #s
    end
end

-- WriteByte appends the given byte values (each 0..255).
function ByteBuf:WriteByte(...)
    self:WriteString(string.char(...))
end

-- AppendUint32 appends little-endian uint32 values (binary.LittleEndian.AppendUint32).
function ByteBuf:AppendUint32(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = string.pack("<I4", (select(i, ...)) & 0xFFFFFFFF)
    end
    self:WriteString(table.concat(parts))
end

function ByteBuf:String()
    if #self.parts > 1 then
        self.parts = { table.concat(self.parts) }
    end
    return self.parts[1] or ""
end

function ByteBuf:Bytes()
    return self:String()
end

-- sliceStore implements Go's `s[i] = v` on a slice whose length is #s (0-based i): it panics
-- when i is out of range, like Go.
function encoder.sliceStore(s, i, v)
    if i < 0 or i >= #s then
        error("runtime error: index out of range [" .. tostring(i) .. "] with length " .. tostring(#s), 0)
    end
    s[i + 1] = v
end
