local internal = {}
package.loaded["tslua.vfs.internal"] = internal
for k, v in pairs(require("tslua.vfs.internal.consts_generated")) do
    internal[k] = v
end
require("tslua.vfs.internal.internal")
return internal
