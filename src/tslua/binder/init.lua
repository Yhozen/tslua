local binder = {}
package.loaded["tslua.binder"] = binder
for k, v in pairs(require("tslua.binder.consts_generated")) do
    binder[k] = v
end
require("tslua.binder.binder")
require("tslua.binder.nameresolver")
require("tslua.binder.referenceresolver")
return binder
