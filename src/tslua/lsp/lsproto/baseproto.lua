local lsproto = require("tslua.lsp.lsproto")
local jsonrpc = require("tslua.jsonrpc")

-- https://microsoft.github.io/language-server-protocol/specifications/base/0.9/specification/

-- BaseReader wraps jsonrpc.Reader for backwards compatibility.
local BaseReader = setmetatable({}, { __index = jsonrpc.Reader })
BaseReader.__index = BaseReader
lsproto.BaseReader = BaseReader

-- NewBaseReader creates a new BaseReader.
function lsproto.NewBaseReader(r)
    local reader = jsonrpc.NewReader(r)
    return setmetatable(reader, BaseReader)
end

-- BaseWriter wraps jsonrpc.Writer for backwards compatibility.
local BaseWriter = setmetatable({}, { __index = jsonrpc.Writer })
BaseWriter.__index = BaseWriter
lsproto.BaseWriter = BaseWriter

-- NewBaseWriter creates a new BaseWriter.
function lsproto.NewBaseWriter(w)
    local writer = jsonrpc.NewWriter(w)
    return setmetatable(writer, BaseWriter)
end
