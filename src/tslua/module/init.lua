local module = {}
package.loaded["tslua.module"] = module
for k, v in pairs(require("tslua.module.consts_generated")) do
    module[k] = v
end
require("tslua.module.luahelpers")
require("tslua.module.types")
require("tslua.module.cache")
require("tslua.module.util")
require("tslua.module.resolver")
return module
