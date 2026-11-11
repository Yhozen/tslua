local vfs = {}
package.loaded["tslua.vfs"] = vfs
for k, v in pairs(require("tslua.vfs.consts_generated")) do
    vfs[k] = v
end
require("tslua.vfs.iofs")
require("tslua.vfs.vfs")
return vfs
