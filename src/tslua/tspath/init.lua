local tspath = {}
package.loaded["tslua.tspath"] = tspath
for k, v in pairs(require("tslua.tspath.consts_generated")) do
    tspath[k] = v
end
require("tslua.tspath.extension")
require("tslua.tspath.ignoredpaths")
require("tslua.tspath.path")
return tspath
