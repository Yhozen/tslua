local change = {}
package.loaded["tslua.ls.change"] = change
for k, v in pairs(require("tslua.ls.change.consts_generated")) do
    change[k] = v
end
-- Tracker is extended by tracker, delete and trackerimpl; tracker.lua sets its __index.
change.Tracker = {}
change.Tracker.__index = change.Tracker
-- tracker defines the Tracker class that delete and trackerimpl add methods to.
require("tslua.ls.change.tracker")
require("tslua.ls.change.delete")
require("tslua.ls.change.trackerimpl")
return change
