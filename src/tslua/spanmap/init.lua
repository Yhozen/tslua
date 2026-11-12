local spanmap = {}
package.loaded["tslua.spanmap"] = spanmap
for k, v in pairs(require("tslua.spanmap.consts_generated")) do
    spanmap[k] = v
end
require("tslua.spanmap.spanmap")
return spanmap
