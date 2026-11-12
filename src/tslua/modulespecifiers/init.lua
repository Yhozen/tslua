local modulespecifiers = {}
package.loaded["tslua.modulespecifiers"] = modulespecifiers
for k, v in pairs(require("tslua.modulespecifiers.consts_generated")) do
    modulespecifiers[k] = v
end
require("tslua.modulespecifiers.types")
require("tslua.modulespecifiers.compare")
require("tslua.modulespecifiers.preferences")
require("tslua.modulespecifiers.util")
require("tslua.modulespecifiers.specifiers")
return modulespecifiers
