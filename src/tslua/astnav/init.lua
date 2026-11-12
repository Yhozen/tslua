local astnav = {}
package.loaded["tslua.astnav"] = astnav
for k, v in pairs(require("tslua.astnav.consts_generated")) do
    astnav[k] = v
end
require("tslua.astnav.tokens")
return astnav
