local iovfs = {}
package.loaded["tslua.vfs.iovfs"] = iovfs
for k, v in pairs(require("tslua.vfs.iovfs.consts_generated")) do
    iovfs[k] = v
end
require("tslua.vfs.iovfs.iofs")
return iovfs
