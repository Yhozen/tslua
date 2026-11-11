local wrapvfs = {}
package.loaded["tslua.vfs.wrapvfs"] = wrapvfs
for k, v in pairs(require("tslua.vfs.wrapvfs.consts_generated")) do
    wrapvfs[k] = v
end
require("tslua.vfs.wrapvfs.wrapvfs")
return wrapvfs
