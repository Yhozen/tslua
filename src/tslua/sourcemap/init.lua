local sourcemap = {}
package.loaded["tslua.sourcemap"] = sourcemap
for k, v in pairs(require("tslua.sourcemap.consts_generated")) do
    sourcemap[k] = v
end
require("tslua.sourcemap.decoder")
require("tslua.sourcemap.generator")
require("tslua.sourcemap.lineinfo")
require("tslua.sourcemap.source")
require("tslua.sourcemap.source_mapper")
require("tslua.sourcemap.util")
return sourcemap
