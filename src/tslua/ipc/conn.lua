local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")

-- Errors follow the tslua.jsonrpc conventions (jsonrpc.NewError, jsonrpc.ErrorsIs, jsonrpc.ErrorString);
-- json.Value is jsonrpc.Value.
ipc.ErrConnClosed = jsonrpc.NewError("ipc: connection closed")
ipc.ErrRequestTimeout = jsonrpc.NewError("ipc: request timeout")

-- Handler processes incoming API requests and notifications:
--   HandleRequest(ctx, method, params) -> (result, err)    params is a jsonrpc.Value or nil
--   HandleNotification(ctx, method, params) -> err

-- Conn represents a bidirectional connection for API communication:
--   Run(ctx) -> err                       processes messages until the connection closes
--   Call(ctx, method, params) -> (jsonrpc.Value, err)  sends a request and waits for its response
--   Notify(ctx, method, params) -> err    sends a notification (no response expected)

-- UnmarshalParams is a helper to unmarshal params into a typed struct; decode(rawString) -> (value, err).
-- Returns (value or nil, err).
function ipc.UnmarshalParams(params, decode)
    if params == nil or params:Len() == 0 then
        return nil, nil
    end
    return decode(params.data)
end
