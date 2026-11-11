local cachedvfs = {}
package.loaded["tslua.vfs.cachedvfs"] = cachedvfs
for k, v in pairs(require("tslua.vfs.cachedvfs.consts_generated")) do
    cachedvfs[k] = v
end
require("tslua.vfs.cachedvfs.cachedvfs")
return cachedvfs
