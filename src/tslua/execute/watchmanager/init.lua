local watchmanager = {}
package.loaded["tslua.execute.watchmanager"] = watchmanager
for k, v in pairs(require("tslua.execute.watchmanager.consts_generated")) do
    watchmanager[k] = v
end
require("tslua.execute.watchmanager.watchbackend")
require("tslua.execute.watchmanager.watchmanager")
return watchmanager
