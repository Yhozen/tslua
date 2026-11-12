local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")

-- Message is an alias for jsonrpc.Message for convenience.
ipc.Message = jsonrpc.Message

-- Protocol defines the interface for reading and writing API messages:
--   ReadMessage() -> (*Message, err)
--   WriteRequest(id, method, params) -> err
--   WriteNotification(method, params) -> err
--   WriteResponse(id, result) -> err
--   WriteError(id, responseError) -> err
