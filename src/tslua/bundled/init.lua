local bundled = {}
package.loaded["tslua.bundled"] = bundled
for k, v in pairs(require("tslua.bundled.consts_generated")) do
    bundled[k] = v
end
require("tslua.bundled.bundled")
require("tslua.bundled.embed")
require("tslua.bundled.libs_generated")
require("tslua.bundled.embed_generated")
return bundled
