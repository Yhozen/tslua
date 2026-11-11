local collections = {}
package.loaded["tslua.collections"] = collections
for k, v in pairs(require("tslua.collections.consts_generated")) do
    collections[k] = v
end
require("tslua.collections.cow")
require("tslua.collections.multimap")
require("tslua.collections.ordered_map")
require("tslua.collections.ordered_set")
require("tslua.collections.set")
require("tslua.collections.syncmap")
require("tslua.collections.syncset")
return collections
