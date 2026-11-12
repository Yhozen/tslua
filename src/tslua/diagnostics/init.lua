local diagnostics = {}
package.loaded["tslua.diagnostics"] = diagnostics
for k, v in pairs(require("tslua.diagnostics.consts_generated")) do
    diagnostics[k] = v
end
require("tslua.diagnostics.diagnostics")
require("tslua.diagnostics.messages_generated")(diagnostics, diagnostics.Message, diagnostics.Category)
require("tslua.diagnostics.loc_generated")
require("tslua.diagnostics.stringer_generated")
return diagnostics
