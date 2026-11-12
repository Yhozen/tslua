local lsproto = {}
package.loaded["tslua.lsp.lsproto"] = lsproto
for k, v in pairs(require("tslua.lsp.lsproto.consts_generated")) do
    lsproto[k] = v
end
require("tslua.lsp.lsproto.lsp")
require("tslua.lsp.lsproto.structcodec")
require("tslua.lsp.lsproto.baseproto")
require("tslua.lsp.lsproto.jsonrpc")
require("tslua.lsp.lsproto.lsp_generated")
require("tslua.lsp.lsproto.util")
return lsproto
