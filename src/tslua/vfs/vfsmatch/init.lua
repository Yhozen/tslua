local vfsmatch = {}
package.loaded["tslua.vfs.vfsmatch"] = vfsmatch
for k, v in pairs(require("tslua.vfs.vfsmatch.consts_generated")) do
    vfsmatch[k] = v
end
require("tslua.vfs.vfsmatch.stringer_generated")
require("tslua.vfs.vfsmatch.vfsmatch")
return vfsmatch
