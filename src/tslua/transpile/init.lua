local transpile = {}
package.loaded["tslua.transpile"] = transpile
for k, v in pairs(require("tslua.transpile.consts_generated")) do
    transpile[k] = v
end
require("tslua.transpile.transpile")
return transpile
