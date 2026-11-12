local trackingvfs = {}
package.loaded["tslua.vfs.trackingvfs"] = trackingvfs
for k, v in pairs(require("tslua.vfs.trackingvfs.consts_generated")) do
    trackingvfs[k] = v
end
require("tslua.vfs.trackingvfs.trackingvfs")
return trackingvfs
