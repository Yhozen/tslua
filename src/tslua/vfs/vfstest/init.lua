local vfstest = {}
package.loaded["tslua.vfs.vfstest"] = vfstest
for k, v in pairs(require("tslua.vfs.vfstest.consts_generated")) do
    vfstest[k] = v
end
require("tslua.vfs.vfstest.vfstest")
return vfstest
