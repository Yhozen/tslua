local osvfs = {}
package.loaded["tslua.vfs.osvfs"] = osvfs
for k, v in pairs(require("tslua.vfs.osvfs.consts_generated")) do
    osvfs[k] = v
end
require("tslua.vfs.osvfs.os")
return osvfs
