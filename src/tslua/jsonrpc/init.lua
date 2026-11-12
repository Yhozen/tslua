local jsonrpc = {}
package.loaded["tslua.jsonrpc"] = jsonrpc
for k, v in pairs(require("tslua.jsonrpc.consts_generated")) do
    jsonrpc[k] = v
end
require("tslua.jsonrpc.goerrors")
require("tslua.jsonrpc.baseproto")
require("tslua.jsonrpc.jsonrpc")
return jsonrpc
