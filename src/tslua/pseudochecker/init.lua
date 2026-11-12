local pseudochecker = {}
package.loaded["tslua.pseudochecker"] = pseudochecker
for k, v in pairs(require("tslua.pseudochecker.consts_generated")) do
    pseudochecker[k] = v
end
require("tslua.pseudochecker.checker")
require("tslua.pseudochecker.type")
require("tslua.pseudochecker.lookup")
return pseudochecker
