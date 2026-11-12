local change = {}
package.loaded["tslua.ls.change"] = change
for k, v in pairs(require("tslua.ls.change.consts_generated")) do
    change[k] = v
end
require("tslua.ls.change.delete")
require("tslua.ls.change.tracker")
require("tslua.ls.change.trackerimpl")
return change
