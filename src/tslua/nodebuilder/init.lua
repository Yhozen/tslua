local nodebuilder = {}
package.loaded["tslua.nodebuilder"] = nodebuilder
for k, v in pairs(require("tslua.nodebuilder.consts_generated")) do
    nodebuilder[k] = v
end
require("tslua.nodebuilder.types")
return nodebuilder
