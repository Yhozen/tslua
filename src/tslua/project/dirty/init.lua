local dirty = {}
package.loaded["tslua.project.dirty"] = dirty
for k, v in pairs(require("tslua.project.dirty.consts_generated")) do
    dirty[k] = v
end
require("tslua.project.dirty.box")
require("tslua.project.dirty.cloneablemap")
require("tslua.project.dirty.entry")
require("tslua.project.dirty.interfaces")
require("tslua.project.dirty.map")
require("tslua.project.dirty.mapbuilder")
require("tslua.project.dirty.syncmap")
require("tslua.project.dirty.util")
return dirty
