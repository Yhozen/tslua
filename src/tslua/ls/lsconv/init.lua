local lsconv = {}
package.loaded["tslua.ls.lsconv"] = lsconv
for k, v in pairs(require("tslua.ls.lsconv.consts_generated")) do
    lsconv[k] = v
end
require("tslua.ls.lsconv.converters")
require("tslua.ls.lsconv.linemap")
return lsconv
