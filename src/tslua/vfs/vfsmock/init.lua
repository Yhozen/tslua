local vfsmock = {}
package.loaded["tslua.vfs.vfsmock"] = vfsmock
for k, v in pairs(require("tslua.vfs.vfsmock.consts_generated")) do
    vfsmock[k] = v
end
require("tslua.vfs.vfsmock.mock_generated")
require("tslua.vfs.vfsmock.wrapper")
return vfsmock
