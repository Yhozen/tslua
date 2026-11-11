local outputpaths = {}
package.loaded["tslua.outputpaths"] = outputpaths
for k, v in pairs(require("tslua.outputpaths.consts_generated")) do
    outputpaths[k] = v
end
require("tslua.outputpaths.commonsourcedirectory")
require("tslua.outputpaths.outputpaths")
return outputpaths
